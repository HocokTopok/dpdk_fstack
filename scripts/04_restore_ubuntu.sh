#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_linux
[[ $# == 1 && -f "$1/state.env" ]] || fail 'Usage: bash scripts/04_restore_ubuntu.sh results/.../state'
STATE_DIR="$1"
[[ ! -f "$STATE_DIR/restored" ]] || exit 0
source "$STATE_DIR/state.env"
sudo -v
if [[ -s "$STATE_DIR/../client.pid" ]]; then
    CLIENT_PID="$(cat "$STATE_DIR/../client.pid")"
    COMMAND="$(sudo ps -p "$CLIENT_PID" -o args= 2>/dev/null || true)"
    [[ "$COMMAND" != *"$APP_DIR/client_fstack"* ]] || fail 'The F-Stack client is still running. Stop it before restoring.'
fi
ERRORS=0
restore_step() {
    "$@" || { printf 'RESTORE_ERROR: %s\n' "$*" >&2; ERRORS=1; }
}
printf 'RESTORE_START\n'
if (( NETWORK_CHANGED )); then
    DRIVER_NOW="$(basename "$(readlink -f "$SYSFS_ROOT/bus/pci/devices/$PCI_ADDR/driver")")"
    if [[ "$DRIVER_NOW" != "$ORIGINAL_DRIVER" ]]; then
        restore_step sudo modprobe "$ORIGINAL_DRIVER"
        restore_step sudo python3 "$DEVBIND" --bind="$ORIGINAL_DRIVER" "$PCI_ADDR"
    fi
    if [[ -n "$ORIGINAL_UUID" ]]; then
        restore_step sudo ip link set "$ETH_IFACE" up
        restore_step sudo nmcli --wait 30 connection up uuid "$ORIGINAL_UUID" ifname "$ETH_IFACE"
    else
        restore_step sudo nmcli device set "$ETH_IFACE" autoconnect no
        if nmcli -g connection.uuid connection show "$TEMP_PROFILE" >/dev/null 2>&1; then
            restore_step sudo nmcli connection delete "$TEMP_PROFILE"
        fi
        if (( ORIGINAL_UP )); then
            restore_step sudo ip link set "$ETH_IFACE" up
        else
            restore_step sudo ip link set "$ETH_IFACE" down
        fi
    fi
    restore_step sudo nmcli device set "$ETH_IFACE" autoconnect "$ORIGINAL_AUTOCONNECT"
fi

if [[ "$PREFIX" =~ ^dpdk_demo_[0-9]+_[0-9]+$ ]]; then
    if mountpoint -q "$HUGE_DIR"; then
        restore_step sudo find "$HUGE_DIR" -maxdepth 1 -type f -name "${PREFIX}*" -delete
    fi
    restore_step sudo rm -rf -- "$RUNTIME_ROOT/$PREFIX"
else
    printf 'RESTORE_ERROR: unexpected DPDK prefix\n' >&2
    ERRORS=1
fi
if (( MOUNT_CREATED )); then
    restore_step sudo umount "$HUGE_DIR"
fi
if (( DIRECTORY_CREATED )); then
    restore_step sudo rmdir "$HUGE_DIR"
fi
if (( HUGE_CHANGED )); then
    if ! printf '%s\n' "$HUGE_ORIGINAL" | sudo tee "$HUGE_PATH"; then
        ERRORS=1
    elif [[ "$(cat "$HUGE_PATH")" != "$HUGE_ORIGINAL" ]]; then
        printf 'RESTORE_ERROR: hugepages count differs from the initial count\n' >&2
        ERRORS=1
    fi
fi
for MODULE in vfio_pci vfio_pci_core vfio_iommu_type1 vfio; do
    if ! grep -q "^${MODULE} " "$STATE_DIR/modules.before" && [[ -d "$SYSFS_ROOT/module/$MODULE" ]]; then
        restore_step sudo modprobe -r "$MODULE"
    fi
done
ip -br addr
if [[ "$(basename "$(readlink -f "$SYSFS_ROOT/bus/pci/devices/$PCI_ADDR/driver")")" != "$ORIGINAL_DRIVER" ]]; then
    printf 'RESTORE_ERROR: kernel driver differs from the initial driver\n' >&2
    ERRORS=1
fi
if (( ERRORS == 0 )); then
    touch "$STATE_DIR/restored"
    printf 'RESTORE_OK\n'
else
    exit 1
fi
