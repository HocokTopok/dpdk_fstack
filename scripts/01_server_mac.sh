#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[[ "$(uname -s)" == Darwin ]] || fail 'Run this script on the Mac.'
need c++ brew ipconfig
LABEL="${1:-fstack}"
[[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Invalid result name.'
[[ "$MEASUREMENTS" =~ ^[0-9]+$ ]] || fail 'Invalid MEASUREMENTS.'
start_log "$LABEL"
MAC_IP="$(ipconfig getifaddr "$MAC_IFACE")"
[[ -n "$MAC_IP" ]] || fail "No IPv4 on $MAC_IFACE"
printf 'SERVER_IP=%s\nPORT=3333\nMEASUREMENTS=%s\n' "$MAC_IP" "$MEASUREMENTS"
c++ -std=c++17 -O2 -Wall -Wextra \
    -I"$(brew --prefix boost)/include" "$SOURCE_DIR/server.cpp" -o "$APP_DIR/server"
"$APP_DIR/server" "$MEASUREMENTS" "$RUN_DIR/rtt.csv"
printf 'SERVER_OK\nCSV=%s/rtt.csv\n' "$RUN_DIR"
