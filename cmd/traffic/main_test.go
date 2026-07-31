package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestUpdateInterfaceFirstSample(t *testing.T) {
	got := updateInterface(interfaceState{}, counters{RX: 100, TX: 200}, "boot-a", false)
	if got.RXTotal != 100 || got.TXTotal != 200 || got.LastRX != 100 || got.LastTX != 200 {
		t.Fatalf("unexpected first sample: %+v", got)
	}
}

func TestUpdateInterfaceAddsDelta(t *testing.T) {
	previous := interfaceState{RXTotal: 1000, TXTotal: 2000, LastRX: 100, LastTX: 200, BootID: "boot-a"}
	got := updateInterface(previous, counters{RX: 150, TX: 275}, "boot-a", true)
	if got.RXTotal != 1050 || got.TXTotal != 2075 {
		t.Fatalf("unexpected totals: %+v", got)
	}
}

func TestUpdateInterfaceContinuesAfterReboot(t *testing.T) {
	previous := interfaceState{RXTotal: 1000, TXTotal: 2000, LastRX: 900, LastTX: 1800, BootID: "boot-a"}
	got := updateInterface(previous, counters{RX: 30, TX: 40}, "boot-b", true)
	if got.RXTotal != 1030 || got.TXTotal != 2040 {
		t.Fatalf("unexpected reboot totals: %+v", got)
	}
}

func TestUpdateInterfaceHandlesCounterReset(t *testing.T) {
	previous := interfaceState{RXTotal: 1000, TXTotal: 2000, LastRX: 900, LastTX: 1800, BootID: "boot-a"}
	got := updateInterface(previous, counters{RX: 25, TX: 35}, "boot-a", true)
	if got.RXTotal != 1025 || got.TXTotal != 2035 {
		t.Fatalf("unexpected reset totals: %+v", got)
	}
}

func TestCollectorPersistsSamples(t *testing.T) {
	root := t.TempDir()
	sysPath := filepath.Join(root, "sys", "class", "net")
	statsPath := filepath.Join(sysPath, "ens17", "statistics")
	if err := os.MkdirAll(statsPath, 0755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(statsPath, "rx_bytes"), "1073741824\n")
	writeFile(t, filepath.Join(statsPath, "tx_bytes"), "536870912\n")
	writeFile(t, filepath.Join(sysPath, "ens17", "operstate"), "up\n")
	bootIDPath := filepath.Join(root, "boot_id")
	writeFile(t, bootIDPath, "boot-a\n")

	c := collector{
		sysPath:     sysPath,
		bootIDPath:  bootIDPath,
		statePath:   filepath.Join(root, "state.json"),
		interfaceID: "ens17",
	}
	if err := c.collectOnce(); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(statsPath, "rx_bytes"), "2147483648\n")
	writeFile(t, filepath.Join(statsPath, "tx_bytes"), "1073741824\n")
	if err := c.collectOnce(); err != nil {
		t.Fatal(err)
	}

	s, err := c.loadState()
	if err != nil {
		t.Fatal(err)
	}
	got := s.Interfaces["ens17"]
	if got.RXTotal != 2147483648 || got.TXTotal != 1073741824 {
		t.Fatalf("unexpected persisted totals: %+v", got)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}
