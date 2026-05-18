#!/usr/bin/env bash

set -e

# 允许通过环境变量覆盖，默认 wg0
WG_IFACE="${WG_IFACE:-wg0}"
CONFIG_FILE="/etc/wireguard/${WG_IFACE}.conf"
SERVICE="wg-quick@${WG_IFACE}"

# 颜色（绿色）
GREEN="\033[0;32m"
NC="\033[0m"

generate_port() {
  while true; do
    PORT=$(shuf -i 20000-60000 -n 1)
    if ! ss -uln | grep -q ":$PORT "; then
      echo "$PORT"
      return
    fi
  done
}

OLD_PORT=$(grep -oP 'ListenPort\s*=\s*\K\d+' "$CONFIG_FILE")
NEW_PORT=$(generate_port)

echo "Old port: $OLD_PORT"
echo "New port: $NEW_PORT"

echo "Stopping service..."
systemctl stop "$SERVICE"

echo "Updating config..."

sed -i "s/ListenPort = $OLD_PORT/ListenPort = $NEW_PORT/g" "$CONFIG_FILE"
sed -i "s/--dport $OLD_PORT/--dport $NEW_PORT/g" "$CONFIG_FILE"

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
