#!/usr/bin/env bash
set -euo pipefail

HY2_DIR="/etc/hysteria"
HY2_BIN="/usr/local/bin/hysteria"
HY2_SERVICE="/etc/systemd/system/hysteria-server.service"
HY2_CONFIG="${HY2_DIR}/config.yaml"
HY2_PORT="${HY2_PORT:-443}"

# Set HY2_DOMAIN to enable a real certificate, otherwise self-signed is used.
# Example: HY2_DOMAIN=hy.example.com HY2_EMAIL=you@example.com bash hysteria2.sh install
HY2_DOMAIN="${HY2_DOMAIN:-}"
HY2_EMAIL="${HY2_EMAIL:-}"
HY2_SNI="${HY2_SNI:-bing.com}"
ACME_HOME="${HOME}/.acme.sh"

log() { echo -e "[*] $*"; }
ok()  { echo -e "[+] $*"; }
err() { echo -e "[x] $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Root is required."
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "arm" ;;
    i386|i686) echo "386" ;;
    *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

install_deps() {
  local need=0 c
  for c in curl openssl tar; do
    command -v "$c" >/dev/null 2>&1 || need=1
  done
  [[ "$need" -eq 0 ]] && return 0
  log "Installing dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl openssl tar ca-certificates socat >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl openssl tar ca-certificates socat >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl openssl tar ca-certificates socat >/dev/null 2>&1
  else
    err "No supported package manager found."
    exit 1
  fi
}

download_binary() {
  local arch asset prefix url tmp
  arch="$(detect_arch)"
  asset="hysteria-linux-${arch}"
  local prefixes=("" "https://gh-proxy.com/" "https://ghproxy.net/" "https://gh.llkk.cc/")
  tmp="$(mktemp)"
  for prefix in "${prefixes[@]}"; do
    url="${prefix}https://github.com/apernet/hysteria/releases/latest/download/${asset}"
    log "Downloading ${url}"
    if curl -fL --connect-timeout 10 --max-time 120 -o "$tmp" "$url" 2>/dev/null; then
      install -m 755 "$tmp" "$HY2_BIN"
      rm -f "$tmp"
      ok "Binary installed: $HY2_BIN"
      return 0
    fi
  done
  rm -f "$tmp"
  err "Failed to download hysteria binary."
  exit 1
}

generate_self_signed() {
  log "Generating self-signed certificate..."
  openssl ecparam -genkey -name prime256v1 -out "${HY2_DIR}/key.pem"
  openssl req -new -x509 -days 3650 -key "${HY2_DIR}/key.pem" \
    -out "${HY2_DIR}/cert.pem" -subj "/CN=${HY2_SNI}"
  chmod 600 "${HY2_DIR}/key.pem"
  chmod 644 "${HY2_DIR}/cert.pem"
}

check_dns() {
  local resolved
  resolved="$(getent hosts "$HY2_DOMAIN" | awk '{print $1; exit}' || true)"
  if [[ -z "$resolved" ]]; then
    err "Cannot resolve ${HY2_DOMAIN}. Create an A record first."
    exit 1
  fi
  log "DNS ${HY2_DOMAIN} -> ${resolved}"
  if ss -ltn 2>/dev/null | grep -q ':80 '; then
    err "TCP 80 is already in use. Close it before ACME standalone verification."
    exit 1
  fi
}

install_acme() {
  if [[ -x "${ACME_HOME}/acme.sh" ]]; then
    return 0
  fi
  log "Installing acme.sh..."
  if ! curl -fsSL https://get.acme.sh | sh -s "email=${HY2_EMAIL}" >/dev/null 2>&1; then
    err "acme.sh installation failed."
    exit 1
  fi
}

issue_cert() {
  check_dns
  install_acme
  log "Issuing certificate for ${HY2_DOMAIN}..."
  local rc=0
  "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "${ACME_HOME}/acme.sh" --issue -d "${HY2_DOMAIN}" --standalone --keylength ec-256 || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    err "Certificate issuance failed. Check TCP 80 and DNS."
    exit 1
  fi
  "${ACME_HOME}/acme.sh" --install-cert -d "${HY2_DOMAIN}" --ecc \
    --key-file "${HY2_DIR}/key.pem" \
    --fullchain-file "${HY2_DIR}/cert.pem" \
    --reloadcmd "systemctl restart hysteria-server" >/dev/null
  chmod 600 "${HY2_DIR}/key.pem"
  chmod 644 "${HY2_DIR}/cert.pem"
  ok "Certificate installed."
}

generate_password() {
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24
}

write_config() {
  local password="$1"
  cat > "$HY2_CONFIG" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${HY2_DIR}/cert.pem
  key: ${HY2_DIR}/key.pem

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF
  chmod 600 "$HY2_CONFIG"
}

write_service() {
  cat > "$HY2_SERVICE" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${HY2_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hysteria-server >/dev/null 2>&1
}

get_public_ip() {
  local ip
  ip="$(curl -4 -fsS --max-time 6 https://api.ip.sb/ip 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  echo "$ip"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${HY2_PORT}/udp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

enable_bbr() {
  if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
  fi
}

install_server() {
  require_root
  install_deps
  mkdir -p "$HY2_DIR"

  if [[ ! -x "$HY2_BIN" ]]; then
    download_binary
  else
    ok "Binary already exists: $HY2_BIN"
  fi

  local password host sni link link_suffix
  if [[ -n "$HY2_DOMAIN" ]]; then
    issue_cert
    host="$HY2_DOMAIN"
    sni="$HY2_DOMAIN"
    link_suffix=""
  else
    generate_self_signed
    host="$(get_public_ip)"
    [[ -z "$host" ]] && host="YOUR_SERVER_IP"
    sni="$HY2_SNI"
    link_suffix="&insecure=1"
  fi

  password="$(generate_password)"
  write_config "$password"
  write_service
  enable_bbr
  open_firewall

  log "Starting service..."
  systemctl restart hysteria-server
  sleep 2
  if ! systemctl is-active --quiet hysteria-server; then
    err "Service failed to start. Run: journalctl -u hysteria-server -n 50 --no-pager"
    exit 1
  fi

  link="hysteria2://${password}@${host}:${HY2_PORT}/?sni=${sni}${link_suffix}#Hysteria2"
  echo "$link" > "${HY2_DIR}/node.txt"
  chmod 600 "${HY2_DIR}/node.txt"

  ok "Hysteria2 installed."
  echo
  echo "Port (UDP): ${HY2_PORT}"
  echo "Password:   ${password}"
  echo "SNI:        ${sni}"
  echo
  echo "Client link:"
  echo "$link"
  echo
  echo "Open UDP ${HY2_PORT} in your cloud firewall."
  if [[ -n "$HY2_DOMAIN" ]]; then
    echo "Certificate auto-renew is handled by acme.sh cron."
  fi
}

uninstall_server() {
  require_root
  systemctl stop hysteria-server >/dev/null 2>&1 || true
  systemctl disable hysteria-server >/dev/null 2>&1 || true
  rm -f "$HY2_SERVICE"
  systemctl daemon-reload
  rm -f "$HY2_BIN"
  rm -rf "$HY2_DIR"
  ok "Hysteria2 removed."
}

show_info() {
  if [[ -f "${HY2_DIR}/node.txt" ]]; then
    cat "${HY2_DIR}/node.txt"
  else
    err "Hysteria2 is not installed."
    exit 1
  fi
}

case "${1:-install}" in
  install)   install_server ;;
  uninstall) uninstall_server ;;
  info)      show_info ;;
  *) echo "Usage: $0 [install|uninstall|info]"; exit 1 ;;
esac
