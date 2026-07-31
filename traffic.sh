#!/usr/bin/env bash

set -euo pipefail

readonly REPOSITORY="abai569/sh"
readonly BINARY_PATH="/usr/local/bin/traffic"
readonly SERVICE_PATH="/etc/systemd/system/traffic.service"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        printf 'Error: this command must be run as root.\n' >&2
        exit 1
    fi
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64 | amd64) printf 'amd64\n' ;;
        aarch64 | arm64) printf 'arm64\n' ;;
        *)
            printf 'Error: unsupported architecture: %s\n' "$(uname -m)" >&2
            exit 1
            ;;
    esac
}

download() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$destination" "$url"
    else
        printf 'Error: curl or wget is required.\n' >&2
        exit 1
    fi
}

install_traffic() {
    require_root
    command -v systemctl >/dev/null 2>&1 || {
        printf 'Error: systemd is required.\n' >&2
        exit 1
    }

    local architecture
    local temporary
    local url
    architecture="$(detect_architecture)"
    temporary="$(mktemp)"
    trap "rm -f '$temporary'" EXIT
    url="https://github.com/${REPOSITORY}/releases/latest/download/traffic-linux-${architecture}"

    printf 'Downloading traffic for linux/%s...\n' "$architecture"
    download "$url" "$temporary"
    install -m 0755 "$temporary" "$BINARY_PATH"
    mkdir -p /var/lib/traffic

    cat >"$SERVICE_PATH" <<'EOF'
[Unit]
Description=Persistent network traffic counter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/traffic daemon
Restart=on-failure
RestartSec=5s
StateDirectory=traffic
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable traffic.service
    systemctl restart traffic.service
    printf 'Installed successfully. Run: traffic show\n'
}

uninstall_traffic() {
    require_root
    systemctl disable --now traffic.service 2>/dev/null || true
    rm -f "$SERVICE_PATH" "$BINARY_PATH"
    systemctl daemon-reload
    printf 'Uninstalled. Persistent data remains in /var/lib/traffic.\n'
}

case "${1:-install}" in
    install) install_traffic ;;
    uninstall) uninstall_traffic ;;
    *)
        printf 'Usage: %s [install|uninstall]\n' "$0" >&2
        exit 1
        ;;
esac
