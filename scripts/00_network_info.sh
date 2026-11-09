#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" == Darwin ]]; then
    need ipconfig networksetup
    networksetup -listallhardwareports
    printf '\nMAC_IFACE=%s\nSERVER_IP=%s\n' "$MAC_IFACE" "$(ipconfig getifaddr "$MAC_IFACE")"
else
    need ip nmcli readlink
    ip -br addr
    ip route
    nmcli device status
    printf '\nETH_IFACE=%s\nWIFI_IFACE=%s\n' "$ETH_IFACE" "$WIFI_IFACE"
    printf 'PCI_ADDR=%s\n' "$(basename "$(readlink -f "$SYSFS_ROOT/class/net/$ETH_IFACE/device")")"
    printf 'ETH_IP=%s\nWIFI_IP=%s\n' "$(ipv4 "$ETH_IFACE")" "$(ipv4 "$WIFI_IFACE")"
fi
