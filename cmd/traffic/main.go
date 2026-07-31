package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultStateFile = "/var/lib/traffic/state.json"
	defaultInterval  = 30 * time.Second
)

var version = "dev"

type counters struct {
	RX uint64
	TX uint64
}

type interfaceState struct {
	RXTotal uint64 `json:"rx_total"`
	TXTotal uint64 `json:"tx_total"`
	LastRX  uint64 `json:"last_rx"`
	LastTX  uint64 `json:"last_tx"`
	BootID  string `json:"boot_id"`
}

type state struct {
	Version    int                       `json:"version"`
	UpdatedAt  time.Time                 `json:"updated_at"`
	Interfaces map[string]interfaceState `json:"interfaces"`
}

type collector struct {
	sysPath     string
	bootIDPath  string
	statePath   string
	interfaceID string
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	command := "show"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command = args[0]
		args = args[1:]
	}

	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	interfaceID := flags.String("interface", "", "network interface to monitor")
	statePath := flags.String("state", defaultStateFile, "persistent state file")
	interval := flags.Duration("interval", defaultInterval, "collection interval")
	if err := flags.Parse(args); err != nil {
		return err
	}

	c := &collector{
		sysPath:     "/sys/class/net",
		bootIDPath:  "/proc/sys/kernel/random/boot_id",
		statePath:   *statePath,
		interfaceID: *interfaceID,
	}

	switch command {
	case "show":
		return c.show(stdout)
	case "collect":
		return c.collectOnce()
	case "daemon":
		if *interval <= 0 {
			return errors.New("interval must be greater than zero")
		}
		return c.daemon(*interval)
	case "reset":
		return c.reset(stdout)
	case "version":
		fmt.Fprintf(stdout, "traffic %s\n", version)
		return nil
	case "help":
		printUsage(stdout)
		return nil
	default:
		printUsage(stderr)
		return fmt.Errorf("unknown command %q", command)
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: traffic [show|collect|daemon|reset|version] [options]")
	fmt.Fprintln(w, "Options:")
	fmt.Fprintln(w, "  -interface NAME   monitor a specific network interface")
	fmt.Fprintln(w, "  -state PATH       persistent state file")
	fmt.Fprintln(w, "  -interval VALUE   daemon collection interval")
}

func (c *collector) daemon(interval time.Duration) error {
	if err := c.collectOnce(); err != nil {
		return err
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)

	for {
		select {
		case <-ticker.C:
			if err := c.collectOnce(); err != nil {
				return err
			}
		case <-signals:
			return c.collectOnce()
		}
	}
}

func (c *collector) collectOnce() error {
	unlock, err := acquireFileLock(c.statePath + ".lock")
	if err != nil {
		return err
	}
	defer unlock()
	return c.update()
}

func (c *collector) show(w io.Writer) error {
	if err := c.collectOnce(); err != nil {
		return err
	}
	s, err := c.loadState()
	if err != nil {
		return err
	}

	names := make([]string, 0, len(s.Interfaces))
	for name := range s.Interfaces {
		names = append(names, name)
	}
	sort.Strings(names)

	var totalRX, totalTX uint64
	for _, name := range names {
		entry := s.Interfaces[name]
		totalRX += entry.RXTotal
		totalTX += entry.TXTotal
		fmt.Fprintf(w, "Interface:  %s\n", name)
		fmt.Fprintf(w, "Download:   %s\n", formatBytes(entry.RXTotal))
		fmt.Fprintf(w, "Upload:     %s\n", formatBytes(entry.TXTotal))
		fmt.Fprintf(w, "Total:      %s\n", formatBytes(entry.RXTotal+entry.TXTotal))
		if len(names) > 1 {
			fmt.Fprintln(w)
		}
	}
	if len(names) > 1 {
		fmt.Fprintln(w, "All interfaces:")
		fmt.Fprintf(w, "Download:   %s\n", formatBytes(totalRX))
		fmt.Fprintf(w, "Upload:     %s\n", formatBytes(totalTX))
		fmt.Fprintf(w, "Total:      %s\n", formatBytes(totalRX+totalTX))
	}
	return nil
}

func (c *collector) reset(w io.Writer) error {
	unlock, err := acquireFileLock(c.statePath + ".lock")
	if err != nil {
		return err
	}
	defer unlock()

	if err := os.Remove(c.statePath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove state: %w", err)
	}
	if err := c.update(); err != nil {
		return err
	}
	fmt.Fprintln(w, "Traffic totals reset to current kernel counters.")
	return nil
}

func (c *collector) update() error {
	interfaceID, err := c.detectInterface()
	if err != nil {
		return err
	}
	current, err := c.readCounters(interfaceID)
	if err != nil {
		return err
	}
	bootID, err := readTrimmed(c.bootIDPath)
	if err != nil {
		return fmt.Errorf("read boot ID: %w", err)
	}

	s, err := c.loadState()
	if err != nil {
		return err
	}
	entry, exists := s.Interfaces[interfaceID]
	entry = updateInterface(entry, current, bootID, exists)
	s.Interfaces[interfaceID] = entry
	s.UpdatedAt = time.Now().UTC()
	return c.saveState(s)
}

func updateInterface(previous interfaceState, current counters, bootID string, exists bool) interfaceState {
	if !exists {
		return interfaceState{
			RXTotal: current.RX,
			TXTotal: current.TX,
			LastRX:  current.RX,
			LastTX:  current.TX,
			BootID:  bootID,
		}
	}

	if previous.BootID != bootID || current.RX < previous.LastRX {
		previous.RXTotal += current.RX
	} else {
		previous.RXTotal += current.RX - previous.LastRX
	}
	if previous.BootID != bootID || current.TX < previous.LastTX {
		previous.TXTotal += current.TX
	} else {
		previous.TXTotal += current.TX - previous.LastTX
	}
	previous.LastRX = current.RX
	previous.LastTX = current.TX
	previous.BootID = bootID
	return previous
}

func (c *collector) detectInterface() (string, error) {
	if c.interfaceID != "" {
		if _, err := os.Stat(filepath.Join(c.sysPath, c.interfaceID)); err != nil {
			return "", fmt.Errorf("network interface %q is unavailable", c.interfaceID)
		}
		return c.interfaceID, nil
	}

	if output, err := exec.Command("ip", "-o", "route", "show", "default").Output(); err == nil {
		fields := strings.Fields(string(output))
		for i := 0; i+1 < len(fields); i++ {
			if fields[i] == "dev" {
				return fields[i+1], nil
			}
		}
	}

	entries, err := os.ReadDir(c.sysPath)
	if err != nil {
		return "", fmt.Errorf("list network interfaces: %w", err)
	}
	for _, entry := range entries {
		if entry.Name() == "lo" {
			continue
		}
		operstate, err := readTrimmed(filepath.Join(c.sysPath, entry.Name(), "operstate"))
		if err == nil && operstate == "up" {
			return entry.Name(), nil
		}
	}
	return "", errors.New("no active network interface found")
}

func (c *collector) readCounters(interfaceID string) (counters, error) {
	statsPath := filepath.Join(c.sysPath, interfaceID, "statistics")
	rx, err := readUint(filepath.Join(statsPath, "rx_bytes"))
	if err != nil {
		return counters{}, fmt.Errorf("read RX counter for %s: %w", interfaceID, err)
	}
	tx, err := readUint(filepath.Join(statsPath, "tx_bytes"))
	if err != nil {
		return counters{}, fmt.Errorf("read TX counter for %s: %w", interfaceID, err)
	}
	return counters{RX: rx, TX: tx}, nil
}

func (c *collector) loadState() (state, error) {
	s := state{Version: 1, Interfaces: make(map[string]interfaceState)}
	data, err := os.ReadFile(c.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return state{}, fmt.Errorf("read state: %w", err)
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return state{}, fmt.Errorf("decode state: %w", err)
	}
	if s.Version != 1 {
		return state{}, fmt.Errorf("unsupported state version %d", s.Version)
	}
	if s.Interfaces == nil {
		s.Interfaces = make(map[string]interfaceState)
	}
	return s, nil
}

func (c *collector) saveState(s state) error {
	directory := filepath.Dir(c.statePath)
	if err := os.MkdirAll(directory, 0755); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("encode state: %w", err)
	}
	data = append(data, '\n')

	temporary, err := os.CreateTemp(directory, ".state-*")
	if err != nil {
		return fmt.Errorf("create temporary state: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)

	if err := temporary.Chmod(0644); err != nil {
		temporary.Close()
		return fmt.Errorf("set state permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("write state: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync state: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close state: %w", err)
	}
	if err := os.Rename(temporaryName, c.statePath); err != nil {
		return fmt.Errorf("replace state: %w", err)
	}
	return nil
}

func readTrimmed(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func readUint(path string) (uint64, error) {
	value, err := readTrimmed(path)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(value, 10, 64)
}

func formatBytes(value uint64) string {
	const gib = 1024 * 1024 * 1024
	return fmt.Sprintf("%.2f GiB", float64(value)/gib)
}
