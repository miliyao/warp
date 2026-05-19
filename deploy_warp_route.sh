#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

CONFIG_DIR="/etc/warp-route"
STATE_DIR="/var/lib/warp-route"
LOG_DIR="/var/log/warp-route"
WGCF_DIR="/etc/wireguard"
WGCF_PROFILE="${WGCF_DIR}/wgcf.conf"
WG_INTERFACE="wgcf"
IPSET_NAME="WARP_IPS"
GOOGLE_IPSET_NAME="WARP_GOOGLE"
MARK_HEX="0xca6c"
MARK_DEC="51820"
ROUTE_TABLE="51820"
WGCF_VERSION="2.2.22"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/miliyao/warp/main}"
INSTALL_SOURCE="${INSTALL_SOURCE:-auto}"
SCRIPT_VERSION="2026-05-19.10"

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
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$WGCF_DIR"
  chmod 0750 "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
}

copy_app_files() {
  install_app_file "warp-route-apply" /usr/local/sbin/warp-route-apply "0755"
  install_app_file "warp-route-status" /usr/local/sbin/warp-route-status "0755"
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
  cat >"${CONFIG_DIR}/warp-route.env" <<EOF
CONFIG_DIR=${CONFIG_DIR}
STATE_DIR=${STATE_DIR}
LOG_DIR=${LOG_DIR}
WG_INTERFACE=${WG_INTERFACE}
IPSET_NAME=${IPSET_NAME}
GOOGLE_IPSET_NAME=${GOOGLE_IPSET_NAME}
MARK_HEX=${MARK_HEX}
MARK_DEC=${MARK_DEC}
ROUTE_TABLE=${ROUTE_TABLE}
EOF
  chmod 0600 "${CONFIG_DIR}/warp-route.env"
}

write_default_rules() {
  if [[ -f "${CONFIG_DIR}/rules.json" ]]; then
    return
  fi

  cat >"${CONFIG_DIR}/rules.json" <<'EOF'
{
  "domains": [
    "accounts.google.com",
    "ai.google.dev",
    "fonts.gstatic.com",
    "gemini.google.com",
    "generativelanguage.googleapis.com",
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

migrate_rules() {
  python3 - "${CONFIG_DIR}/rules.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
defaults = {
    "accounts.google.com",
    "ai.google.dev",
    "fonts.gstatic.com",
    "gemini.google.com",
    "generativelanguage.googleapis.com",
    "google.com",
    "googleapis.com",
    "googlevideo.com",
    "gstatic.com",
    "i.ytimg.com",
    "m.youtube.com",
    "music.youtube.com",
    "redirector.googlevideo.com",
    "s.ytimg.com",
    "www.google.com",
    "www.youtube.com",
    "youtube.com",
    "youtube.googleapis.com",
    "youtubei.googleapis.com",
    "ytimg.com",
}
domains = {str(item).strip().lower().rstrip(".") for item in data.get("domains", []) if str(item).strip()}
data["domains"] = sorted(domains | defaults)
ips = {str(item).strip() for item in data.get("ips", []) if str(item).strip()}
data["ips"] = sorted(ips | {"8.8.8.8", "8.8.4.4"})
data.setdefault("optional_domains", {}).setdefault("openai", ["chatgpt.com", "openai.com"])
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
}

profile_has_ipv4_address() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
from pathlib import Path

path = Path(sys.argv[1])
for line in path.read_text(errors="replace").splitlines():
    if not line.startswith("Address = "):
        continue
    for value in (item.strip() for item in line.split("=", 1)[1].split(",")):
        if not value:
            continue
        try:
            if ipaddress.ip_interface(value).version == 4:
                raise SystemExit(0)
        except ValueError:
            continue
raise SystemExit(1)
PY
}

generate_warp_profile() {
  local tmp backup

  if [[ -f "$WGCF_PROFILE" ]]; then
    if profile_has_ipv4_address "$WGCF_PROFILE"; then
      return
    fi

    backup="${WGCF_PROFILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "Existing WARP profile has no IPv4 Address; backing up to ${backup} and regenerating." >&2
    systemctl stop "wg-quick@${WG_INTERFACE}.service" 2>/dev/null || true
    cp -a "$WGCF_PROFILE" "$backup"
    rm -f "$WGCF_PROFILE"
  fi

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
original = path.read_text().splitlines()
ipv4_addresses = []
ipv4_allowed = []
output = []
section = None
interface_written = False
allowed_written = False

def ipv4_interfaces(raw):
    values = []
    for value in (item.strip() for item in raw.split(",")):
        if not value:
            continue
        try:
            parsed = ipaddress.ip_interface(value)
        except ValueError:
            continue
        if parsed.version == 4:
            values.append(value)
    return values

def ipv4_networks(raw):
    values = []
    for value in (item.strip() for item in raw.split(",")):
        if not value:
            continue
        try:
            parsed = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if parsed.version == 4:
            values.append(value)
    return values

for line in original:
    if line.startswith("Address = "):
        ipv4_addresses.extend(ipv4_interfaces(line.split("=", 1)[1]))
    if line.startswith("AllowedIPs = "):
        ipv4_allowed.extend(ipv4_networks(line.split("=", 1)[1]))

if not ipv4_addresses:
    raise SystemExit("WARP profile has no IPv4 Address entry")
if not ipv4_allowed:
    ipv4_allowed = ["0.0.0.0/0"]

ipv4_addresses = list(dict.fromkeys(ipv4_addresses))
ipv4_allowed = list(dict.fromkeys(ipv4_allowed))

def write_interface_settings():
    global interface_written
    if interface_written:
        return
    output.append("Address = " + ", ".join(ipv4_addresses))
    output.append("Table = off")
    output.append("MTU = 1280")
    interface_written = True

for line in path.read_text().splitlines():
    stripped = line.strip()

    if stripped == "[Interface]":
        section = "Interface"
        output.append(line)
        continue

    if stripped == "[Peer]":
        if section == "Interface":
            write_interface_settings()
        section = "Peer"
        output.append(line)
        continue

    if stripped.startswith("[") and stripped.endswith("]"):
        if section == "Interface":
            write_interface_settings()
        section = stripped.strip("[]")
        output.append(line)
        continue

    if section == "Interface" and line.startswith(("Address = ", "DNS = ", "Table = ", "MTU = ")):
        continue

    if section == "Peer" and line.startswith("AllowedIPs = "):
        if allowed_written:
            continue
        output.append("AllowedIPs = " + ", ".join(ipv4_allowed))
        allowed_written = True
        continue

    output.append(line)

if section == "Interface":
    write_interface_settings()

if not allowed_written:
    output.append("AllowedIPs = " + ", ".join(ipv4_allowed))

path.write_text("\n".join(output) + "\n")
PY
}

write_systemd_units() {
  cat >/etc/systemd/system/warp-route-refresh.service <<EOF
[Unit]
Description=Refresh WARP policy routing ipset
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${CONFIG_DIR}/warp-route.env
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
  systemctl disable --now warp-route-panel.service 2>/dev/null || true
  rm -f /etc/systemd/system/warp-route-panel.service
  rm -f "${CONFIG_DIR}/panel.env"
  rm -rf /opt/warp-route
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
}

main() {
  echo "warp-route installer ${SCRIPT_VERSION}"
  install_packages
  install_wgcf
  prepare_dirs
  copy_app_files
  write_config
  write_default_rules
  migrate_rules
  generate_warp_profile
  patch_warp_profile
  write_systemd_units
  enable_services

  echo
  echo "WARP policy routing is installed."
  echo "Run: warp-route-status"
}

main "$@"
