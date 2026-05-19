#!/usr/bin/env bash
set -euo pipefail

PANEL_USER="${1:-}"
PANEL_PASS="${2:-}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
  echo "Usage: bash deploy_warp_route.sh <panel_user> <panel_password>" >&2
  exit 1
fi

APP_DIR="/opt/warp-route"
CONFIG_DIR="/etc/warp-route"
STATE_DIR="/var/lib/warp-route"
LOG_DIR="/var/log/warp-route"
WGCF_DIR="/etc/wireguard"
WGCF_PROFILE="${WGCF_DIR}/wgcf.conf"
WG_INTERFACE="wgcf"
IPSET_NAME="WARP_IPS"
MARK_HEX="0xca6c"
MARK_DEC="51820"
ROUTE_TABLE="51820"
PANEL_PORT="8080"
WGCF_VERSION="2.2.22"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/miliyao/warp/main}"
INSTALL_SOURCE="${INSTALL_SOURCE:-auto}"
SCRIPT_VERSION="2026-05-19.4"

require_command() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates curl iproute2 iptables ipset wireguard-tools python3 \
    dnsutils
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

install_wgcf() {
  if require_command wgcf; then
    return
  fi

  local arch tmp
  arch="$(detect_arch)"
  tmp="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${arch}" \
    -o "${tmp}/wgcf"
  install -m 0755 "${tmp}/wgcf" /usr/local/bin/wgcf
  rm -rf "${tmp}"
}

prepare_dirs() {
  mkdir -p "$APP_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$WGCF_DIR"
  chmod 0750 "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
}

copy_app_files() {
  install_app_file "panel.py" "${APP_DIR}/panel.py" "0755"
  install_app_file "warp-route-apply" /usr/local/sbin/warp-route-apply "0755"
}

install_app_file() {
  local name="$1"
  local target="$2"
  local mode="$3"
  local script_dir source

  if [[ "$INSTALL_SOURCE" != "remote" ]]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || true)"
    source="${script_dir}/${name}"

    if [[ -n "$script_dir" && -f "$source" && "$source" != "$target" ]]; then
      install -m "$mode" "$source" "$target"
      return
    fi
  fi

  curl -fsSL "${RAW_BASE_URL}/${name}" -o "$target"
  chmod "$mode" "$target"
}

write_config() {
  local escaped_user escaped_pass
  escaped_user="$(escape_env_value "$PANEL_USER")"
  escaped_pass="$(escape_env_value "$PANEL_PASS")"

  cat >"${CONFIG_DIR}/panel.env" <<EOF
PANEL_USER=${escaped_user}
PANEL_PASS=${escaped_pass}
PANEL_PORT=${PANEL_PORT}
APP_DIR=${APP_DIR}
CONFIG_DIR=${CONFIG_DIR}
STATE_DIR=${STATE_DIR}
LOG_DIR=${LOG_DIR}
WG_INTERFACE=${WG_INTERFACE}
IPSET_NAME=${IPSET_NAME}
MARK_HEX=${MARK_HEX}
MARK_DEC=${MARK_DEC}
ROUTE_TABLE=${ROUTE_TABLE}
EOF
  chmod 0600 "${CONFIG_DIR}/panel.env"
}

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_default_rules() {
  if [[ -f "${CONFIG_DIR}/rules.json" ]]; then
    return
  fi

  cat >"${CONFIG_DIR}/rules.json" <<'EOF'
{
  "domains": [
    "accounts.google.com",
    "fonts.gstatic.com",
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtubei.googleapis.com",
    "youtube.googleapis.com",
    "googlevideo.com",
    "redirector.googlevideo.com",
    "ytimg.com",
    "i.ytimg.com",
    "s.ytimg.com",
    "google.com",
    "www.google.com",
    "googleapis.com",
    "gstatic.com"
  ],
  "ips": [
    "8.8.8.8",
    "8.8.4.4"
  ],
  "optional_domains": {
    "openai": [
      "chatgpt.com",
      "openai.com"
    ]
  }
}
EOF
}

generate_warp_profile() {
  if [[ -f "$WGCF_PROFILE" ]]; then
    return
  fi

  local tmp
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  wgcf register --accept-tos
  wgcf generate
  popd >/dev/null

  install -m 0600 "${tmp}/wgcf-profile.conf" "$WGCF_PROFILE"
  rm -rf "$tmp"
}

patch_warp_profile() {
  python3 - "$WGCF_PROFILE" <<'PY'
import ipaddress
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = []

for line in path.read_text().splitlines():
    if line.startswith("DNS = "):
        continue

    if line.startswith("Address = "):
        values = [value.strip() for value in line.split("=", 1)[1].split(",")]
        values = [value for value in values if ipaddress.ip_interface(value).version == 4]
        if not values:
            raise SystemExit("WARP profile has no IPv4 Address entry")
        line = "Address = " + ", ".join(values)

    if line.startswith("AllowedIPs = "):
        values = [value.strip() for value in line.split("=", 1)[1].split(",")]
        values = [value for value in values if ipaddress.ip_network(value, strict=False).version == 4]
        if not values:
            values = ["0.0.0.0/0"]
        line = "AllowedIPs = " + ", ".join(values)

    lines.append(line)

path.write_text("\n".join(lines) + "\n")
PY

  if ! grep -q '^Table = off$' "$WGCF_PROFILE"; then
    sed -i '/^\[Interface\]/a Table = off' "$WGCF_PROFILE"
  fi

  if ! grep -q '^MTU = ' "$WGCF_PROFILE"; then
    sed -i '/^\[Interface\]/a MTU = 1280' "$WGCF_PROFILE"
  fi
}

write_systemd_units() {
  cat >/etc/systemd/system/warp-route-panel.service <<EOF
[Unit]
Description=WARP policy routing web panel
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONFIG_DIR}/panel.env
ExecStart=/usr/bin/python3 ${APP_DIR}/panel.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/warp-route-refresh.service <<EOF
[Unit]
Description=Refresh WARP policy routing ipset
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${CONFIG_DIR}/panel.env
ExecStart=/usr/local/sbin/warp-route-apply
EOF

  cat >/etc/systemd/system/warp-route-refresh.timer <<'EOF'
[Unit]
Description=Refresh WARP policy routing ipset periodically

[Timer]
OnBootSec=30
OnUnitActiveSec=30min
Unit=warp-route-refresh.service

[Install]
WantedBy=timers.target
EOF
}

enable_services() {
  systemctl daemon-reload
  systemctl enable "wg-quick@${WG_INTERFACE}.service"
  systemctl restart "wg-quick@${WG_INTERFACE}.service" || true

  if ! systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service"; then
    echo
    echo "Failed to start wg-quick@${WG_INTERFACE}.service." >&2
    echo "Run these commands for details:" >&2
    echo "  systemctl status wg-quick@${WG_INTERFACE}.service" >&2
    echo "  journalctl -xeu wg-quick@${WG_INTERFACE}.service" >&2
    exit 1
  fi
  /usr/local/sbin/warp-route-apply
  systemctl enable --now warp-route-refresh.timer
  systemctl enable --now warp-route-panel.service
}

main() {
  echo "warp-route installer ${SCRIPT_VERSION}"
  install_packages
  install_wgcf
  prepare_dirs
  copy_app_files
  write_config
  write_default_rules
  generate_warp_profile
  patch_warp_profile
  write_systemd_units
  enable_services

  echo
  echo "WARP policy routing is installed."
  echo "Panel: http://SERVER_IP:${PANEL_PORT}"
  echo "User: ${PANEL_USER}"
}

main "$@"
