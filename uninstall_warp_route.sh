#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

APP_DIR="/opt/warp-route"
CONFIG_DIR="/etc/warp-route"
STATE_DIR="/var/lib/warp-route"
LOG_DIR="/var/log/warp-route"
WG_INTERFACE="wgcf"
IPSET_NAME="WARP_IPS"
MARK_HEX="0xca6c"
MARK_DEC="51820"
ROUTE_TABLE="51820"

if [[ -f "${CONFIG_DIR}/panel.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${CONFIG_DIR}/panel.env"
  set +a
fi

systemctl disable --now warp-route-panel.service 2>/dev/null || true
systemctl disable --now warp-route-refresh.timer 2>/dev/null || true
systemctl stop warp-route-refresh.service 2>/dev/null || true
systemctl disable --now "wg-quick@${WG_INTERFACE}.service" 2>/dev/null || true

iptables -t mangle -D OUTPUT -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_HEX" 2>/dev/null || true
ip rule del fwmark "$MARK_HEX" table "$ROUTE_TABLE" 2>/dev/null || true
ip rule del fwmark "$MARK_DEC" table "$ROUTE_TABLE" 2>/dev/null || true
ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
ipset destroy "$IPSET_NAME" 2>/dev/null || true
ipset destroy "${IPSET_NAME}_TMP" 2>/dev/null || true

rm -f /etc/systemd/system/warp-route-panel.service
rm -f /etc/systemd/system/warp-route-refresh.service
rm -f /etc/systemd/system/warp-route-refresh.timer
rm -f /usr/local/sbin/warp-route-apply
rm -rf "$APP_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"

systemctl daemon-reload

echo "WARP policy routing has been removed."
echo "WireGuard profile /etc/wireguard/wgcf.conf was left in place intentionally."
