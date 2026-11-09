#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$APP_DIR/source"
source "$SCRIPT_DIR/settings.sh"
export LC_ALL=C
SYSFS_ROOT="${DPDK_DEMO_SYSFS:-/sys}"
PROCFS_ROOT="${DPDK_DEMO_PROCFS:-/proc}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null || fail "Missing command: $tool"
    done
}

require_linux() {
    [[ "$(uname -s)" == Linux ]] || fail 'Run this script on Ubuntu.'
    (( EUID != 0 )) || fail 'Run as your normal user; the script calls sudo when needed.'
}

start_log() {
    RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
    RUN_DIR="$APP_DIR/results/${1}_$RUN_ID"
    mkdir -p "$RUN_DIR"
    exec > >(tee "$RUN_DIR/terminal.log") 2>&1
    printf 'RUN=%s\nLOG=%s/terminal.log\n' "$RUN_ID" "$RUN_DIR"
}

ipv4() {
    ip -4 -o addr show dev "$1" scope global | awk 'NR == 1 {split($4,a,"/"); print a[1]}'
}

check_ip() {
    python3 - "$SERVER_IP" <<'PY'
import ipaddress
import sys
ipaddress.IPv4Address(sys.argv[1])
PY
}

lock_ubuntu() {
    mkdir -p "$APP_DIR/results"
    exec 9> "$APP_DIR/results/.ubuntu.lock"
    flock -n 9 || fail 'Another Ubuntu test is running.'
}
