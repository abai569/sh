# Persistent Traffic Counter

`traffic` records Linux network interface byte counters and keeps the totals
across system restarts and interface counter resets.

## Install

Run the installer as root on a systemd-based Linux server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abai569/sh/main/traffic.sh)
```

The installer downloads the latest release for `linux/amd64` or
`linux/arm64`, installs it at `/usr/local/bin/traffic`, and enables the
`traffic.service` systemd unit.

## Usage

```bash
traffic show
traffic version
systemctl status traffic.service
```

The default route interface is selected automatically. To collect a specific
interface manually, use:

```bash
traffic collect -interface ens17
```

Persistent state is stored in `/var/lib/traffic/state.json`. The first sample
includes the interface counters accumulated since the current system boot.
Later samples add only the counter delta. After a reboot or counter reset, the
new kernel counter is added to the stored total.

Reset the total to the current kernel counters with:

```bash
systemctl stop traffic.service
traffic reset
systemctl start traffic.service
```

Uninstall the binary and service while retaining persistent data:

```bash
bash traffic.sh uninstall
```
