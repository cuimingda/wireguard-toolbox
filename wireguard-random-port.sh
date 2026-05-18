#!/usr/bin/env bash

set -e

# 固定检查和修改 wg0
WG_IFACE="wg0"
CONFIG_FILE="/etc/wireguard/${WG_IFACE}.conf"
CLIENT_CONFIG_FILE="/root/wg0-client.conf"
SERVICE="wg-quick@${WG_IFACE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_CHECK_SCRIPT="${SCRIPT_DIR}/wireguard-port-check.sh"

# 颜色（绿色）
GREEN="\033[0;32m"
NC="\033[0m"

die() {
  echo "Error: $*" >&2
  exit 1
}

check_config_file() {
  local file="$1"

  [[ -f "$file" ]] || die "config file not found: $file"
  [[ -r "$file" ]] || die "config file is not readable: $file"
  [[ -w "$file" ]] || die "config file is not writable: $file"
}

get_server_port() {
  local file="$1"
  local port

  port=$(sed -nE 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$file" | head -n 1)
  [[ -n "$port" ]] || die "failed to parse ListenPort from $file"

  echo "$port"
}

run_port_check() {
  [[ -f "$PORT_CHECK_SCRIPT" ]] || die "port check script not found: $PORT_CHECK_SCRIPT"
  [[ -r "$PORT_CHECK_SCRIPT" ]] || die "port check script is not readable: $PORT_CHECK_SCRIPT"

  bash "$PORT_CHECK_SCRIPT" || die "WireGuard port audit failed"
}

generate_port() {
  while true; do
    PORT=$(shuf -i 20000-60000 -n 1)
    if ! ss -uln | grep -q ":$PORT "; then
      echo "$PORT"
      return
    fi
  done
}

check_config_file "$CONFIG_FILE"
check_config_file "$CLIENT_CONFIG_FILE"

run_port_check

OLD_PORT=$(get_server_port "$CONFIG_FILE")

NEW_PORT=$(generate_port)

echo "Old port: $OLD_PORT"
echo "New port: $NEW_PORT"

echo "Stopping service..."
systemctl stop "$SERVICE"

echo "Updating config..."

sed -i -E "s#^([[:space:]]*ListenPort[[:space:]]*=[[:space:]]*)${OLD_PORT}([[:space:]]*)\$#\1${NEW_PORT}\2#" "$CONFIG_FILE" \
  || die "failed to update ListenPort in $CONFIG_FILE"
sed -i -E "s/(--dport[[:space:]]+)${OLD_PORT}/\1${NEW_PORT}/g" "$CONFIG_FILE" \
  || die "failed to update firewall port in $CONFIG_FILE"
sed -i -E "s/(--add-port(=|[[:space:]]+))${OLD_PORT}\/udp/\1${NEW_PORT}\/udp/g" "$CONFIG_FILE" \
  || die "failed to update firewalld add port in $CONFIG_FILE"
sed -i -E "s/(--remove-port(=|[[:space:]]+))${OLD_PORT}\/udp/\1${NEW_PORT}\/udp/g" "$CONFIG_FILE" \
  || die "failed to update firewalld remove port in $CONFIG_FILE"
sed -i -E "s#^([[:space:]]*Endpoint[[:space:]]*=[[:space:]]*.+):${OLD_PORT}([[:space:]]*)\$#\1:${NEW_PORT}\2#" "$CLIENT_CONFIG_FILE" \
  || die "failed to update Endpoint in $CLIENT_CONFIG_FILE"

grep -Eq "^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*${NEW_PORT}[[:space:]]*$" "$CONFIG_FILE" \
  || die "ListenPort was not updated in $CONFIG_FILE"
run_port_check

echo "Starting service..."
systemctl start "$SERVICE"

echo "Service status:"
systemctl status "$SERVICE" --no-pager

echo "Checking port binding..."
if ss -ulnp | grep -q ":$NEW_PORT "; then
  echo -e "${GREEN}Done. New port is $NEW_PORT${NC}"
else
  echo "Warning: port $NEW_PORT not found in ss output!"
fi

echo "$NEW_PORT"
