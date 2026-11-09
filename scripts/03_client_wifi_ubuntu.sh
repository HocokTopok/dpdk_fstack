#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_linux
need sudo ip g++ timeout flock
[[ "$RUN_TIMEOUT" =~ ^[0-9]+$ ]] && (( RUN_TIMEOUT > 0 )) || fail 'Invalid RUN_TIMEOUT.'
lock_ubuntu
start_log plain_wifi
[[ -d "$SYSFS_ROOT/class/net/$WIFI_IFACE/wireless" ]] || fail "Not a Wi-Fi interface: $WIFI_IFACE"
WIFI_IP="$(ipv4 "$WIFI_IFACE")"
[[ -n "$WIFI_IP" ]] || fail 'Connect Ubuntu to Wi-Fi before running this script.'
ip -4 route get "$SERVER_IP" from "$WIFI_IP" oif "$WIFI_IFACE"
g++ -std=c++17 -O2 -Wall -Wextra -pthread "$SOURCE_DIR/client_plain.cpp" -o "$APP_DIR/client_plain"
printf 'BUILD_OK\nCLIENT_INTERFACE=%s\nWIFI_IP=%s\nSERVER_IP=%s\n' "$WIFI_IFACE" "$WIFI_IP" "$SERVER_IP"
sudo -v
sudo timeout --signal=TERM --kill-after=5s "${RUN_TIMEOUT}s" \
    env SERVER_IP="$SERVER_IP" CLIENT_INTERFACE="$WIFI_IFACE" "$APP_DIR/client_plain"
printf 'PLAIN_WIFI_OK\n'
