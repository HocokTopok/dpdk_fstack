#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_linux
need sudo ip nmcli python3 pkg-config g++ flock timeout findmnt mountpoint readlink awk grep find wc tee modprobe mount umount
check_ip
CLIENT_RUNNER=()
if [[ "${FSTACK_GDB:-0}" == 1 ]]; then
    need gdb
    CLIENT_RUNNER=(gdb --batch --return-child-result
        -ex 'set pagination off' -ex 'set confirm off'
        -ex 'set disable-randomization off'
        -ex 'handle SIGPIPE nostop noprint pass'
        -ex run -ex 'bt 25' --args)
fi
[[ "$HUGE_TARGET" =~ ^[0-9]+$ && "$RUN_TIMEOUT" =~ ^[0-9]+$ ]] || fail 'Invalid numeric settings.'
(( HUGE_TARGET > 0 && RUN_TIMEOUT > 0 )) || fail 'Numeric settings must be positive.'
lock_ubuntu
start_log fstack
sudo -v

[[ -f "$DEVBIND" && -f "$FSTACK_CONF" ]] || fail 'Check DEVBIND and FSTACK_CONF in scripts/settings.sh'
[[ -f "$FSTACK_SRC/lib/libfstack.a" && -f "$FSTACK_SRC/lib/ff_api.h" ]] || fail 'F-Stack library/header not found.'
[[ -d "$SYSFS_ROOT/class/net/$ETH_IFACE" ]] || fail "Ethernet interface not found: $ETH_IFACE"
ACTUAL_PCI="$(basename "$(readlink -f "$SYSFS_ROOT/class/net/$ETH_IFACE/device")")"
[[ "$ACTUAL_PCI" == "$PCI_ADDR" ]] || fail "PCI mismatch: $ACTUAL_PCI != $PCI_ADDR"
DEVICE="$SYSFS_ROOT/bus/pci/devices/$PCI_ADDR"
[[ -d "$DEVICE/iommu_group/devices" ]] || fail 'No IOMMU group for the Ethernet device.'
GROUP_COUNT="$(find "$DEVICE/iommu_group/devices" -mindepth 1 -maxdepth 1 -type l | wc -l)"
(( GROUP_COUNT == 1 )) || fail 'The IOMMU group contains other devices.'
ORIGINAL_DRIVER="$(basename "$(readlink -f "$DEVICE/driver")")"
[[ -L "$DEVICE/driver" ]] || fail 'The Ethernet device has no kernel driver.'
[[ "$ORIGINAL_DRIVER" != vfio-pci && "$ORIGINAL_DRIVER" != driver ]] || fail 'Restore the Ethernet kernel driver before starting.'

PC_FILE="$(find "$DPDK_PREFIX" -name libdpdk.pc -print -quit)"
[[ -n "$PC_FILE" ]] || fail 'libdpdk.pc not found.'
export PKG_CONFIG_PATH="$(dirname "$PC_FILE")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
DPDK_LIB="$(pkg-config --variable=libdir libdpdk)"
printf 'DPDK=%s\nDPDK_LIB=%s\nDRIVER=%s\n' "$(pkg-config --modversion libdpdk)" "$DPDK_LIB" "$ORIGINAL_DRIVER"
[[ -f "$DPDK_LIB/librte_net_r8169.a" || -f "$DPDK_LIB/librte_net_r8169.so" ]] || fail 'Realtek PMD not found in this DPDK installation.'
grep -q '"file_prefix"' "$FSTACK_SRC/lib/ff_config.c" || fail 'This F-Stack version needs its file_prefix support checked.'
read -r -a DPDK_CFLAGS <<< "$(pkg-config --cflags libdpdk)"
read -r -a DPDK_LIBS <<< "$(pkg-config --static --libs libdpdk)"
g++ -std=c++17 -O2 -g -Wall -Wextra -pthread "$SOURCE_DIR/client.cpp" -o "$APP_DIR/client_fstack" \
    -I"$FSTACK_SRC/lib" "${DPDK_CFLAGS[@]}" \
    -Wl,--whole-archive "$FSTACK_SRC/lib/libfstack.a" -Wl,--no-whole-archive \
    "${DPDK_LIBS[@]}" -Wl,-rpath,"$DPDK_LIB" -lcrypto -lrt -ldl -lm
printf 'BUILD_OK\n'

STATE_DIR="$RUN_DIR/state"
mkdir -m 700 "$STATE_DIR"
ORIGINAL_UUID="$(nmcli -g GENERAL.CON-UUID device show "$ETH_IFACE")"
[[ "$ORIGINAL_UUID" != -- ]] || ORIGINAL_UUID=''
ORIGINAL_AUTOCONNECT="$(nmcli -g GENERAL.AUTOCONNECT device show "$ETH_IFACE")"
[[ "$ORIGINAL_AUTOCONNECT" == yes || "$ORIGINAL_AUTOCONNECT" == no ]] || fail 'Cannot read the NetworkManager autoconnect state.'
[[ "$(nmcli -g GENERAL.NM-MANAGED device show "$ETH_IFACE")" == yes ]] || fail 'Ethernet must be managed by NetworkManager.'
ORIGINAL_UP=$(( $(cat "$SYSFS_ROOT/class/net/$ETH_IFACE/flags") & 1 ))
HUGE_PATH="$SYSFS_ROOT/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
HUGE_ORIGINAL="$(cat "$HUGE_PATH")"
HUGE_CHANGED=0
NETWORK_CHANGED=0
MOUNT_CREATED=0
DIRECTORY_CREATED=0
HUGE_DIR="${DPDK_DEMO_HUGE_DIR:-/dev/hugepages}"
PREFIX="dpdk_demo_${UID}_$$"
TEMP_PROFILE="dpdk-demo-$RUN_ID"
RUNTIME_ROOT="${DPDK_DEMO_RUNTIME_ROOT:-/var/run/dpdk}"
cp "$PROCFS_ROOT/modules" "$STATE_DIR/modules.before"
ip -j addr show dev "$ETH_IFACE" > "$STATE_DIR/address.before.json"
ip -j route show > "$STATE_DIR/routes.before.json"
nmcli device show "$ETH_IFACE" > "$STATE_DIR/network.before.txt"

save_state() {
    local key
    for key in ETH_IFACE PCI_ADDR DEVBIND ORIGINAL_DRIVER ORIGINAL_UUID ORIGINAL_UP ORIGINAL_AUTOCONNECT \
        HUGE_PATH HUGE_ORIGINAL HUGE_CHANGED NETWORK_CHANGED MOUNT_CREATED DIRECTORY_CREATED \
        HUGE_DIR PREFIX TEMP_PROFILE SYSFS_ROOT PROCFS_ROOT RUNTIME_ROOT; do
        printf '%s=%q\n' "$key" "${!key}"
    done > "$STATE_DIR/state.env.tmp"
    mv "$STATE_DIR/state.env.tmp" "$STATE_DIR/state.env"
}

CHILD_PID=''
finish() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$CHILD_PID" ]]; then
        if [[ -s "$RUN_DIR/client.pid" ]]; then
            local app_pid attempt
            app_pid="$(cat "$RUN_DIR/client.pid")"
            sudo kill -TERM "$app_pid" 2>/dev/null
            for (( attempt=0; attempt<50; attempt++ )); do
                sudo kill -0 "$app_pid" 2>/dev/null || break
                sleep 0.1
            done
            sudo kill -KILL "$app_pid" 2>/dev/null
        else
            kill -TERM "$CHILD_PID" 2>/dev/null
        fi
        wait "$CHILD_PID"
    fi
    bash "$SCRIPT_DIR/04_restore_ubuntu.sh" "$STATE_DIR"
    if (( $? != 0 )); then
        printf 'RESTORE_FAILED\nRECOVERY=bash scripts/04_restore_ubuntu.sh %q\n' "$STATE_DIR" >&2
        status=1
    fi
    exit "$status"
}
save_state
printf 'RECOVERY=bash scripts/04_restore_ubuntu.sh %q\n' "$STATE_DIR"
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

NETWORK_CHANGED=1
save_state
sudo nmcli device set "$ETH_IFACE" autoconnect no
sudo ip link set "$ETH_IFACE" up
for (( attempt=0; attempt<10; attempt++ )); do
    [[ "$(cat "$SYSFS_ROOT/class/net/$ETH_IFACE/carrier")" == 1 ]] && break
    sleep 1
done
[[ "$(cat "$SYSFS_ROOT/class/net/$ETH_IFACE/carrier")" == 1 ]] || fail 'No Ethernet carrier. Check the cable and router LAN port.'
printf 'CARRIER_OK\n'
if [[ -r "$SYSFS_ROOT/class/net/$ETH_IFACE/speed" ]]; then
    printf 'LINK_SPEED_MBPS=%s\n' "$(cat "$SYSFS_ROOT/class/net/$ETH_IFACE/speed")"
fi
if [[ -z "$ORIGINAL_UUID" ]]; then
    sudo nmcli connection add type ethernet ifname "$ETH_IFACE" con-name "$TEMP_PROFILE" \
        connection.autoconnect no ipv4.method auto ipv6.method disabled
    sudo nmcli --wait 30 connection up "$TEMP_PROFILE" ifname "$ETH_IFACE"
fi
ETH_IP="$(ipv4 "$ETH_IFACE")"
[[ -n "$ETH_IP" ]] || fail 'Ethernet has no IPv4 address.'
[[ "$ETH_IP" != "$SERVER_IP" ]] || fail 'SERVER_IP points to Ubuntu, not the Mac.'
ip -4 route get "$SERVER_IP" oif "$ETH_IFACE"
printf 'ETH_IP=%s\nSERVER_IP=%s\n' "$ETH_IP" "$SERVER_IP"

python3 - "$FSTACK_CONF" "$RUN_DIR/f-stack.conf" "$ETH_IFACE" "$PCI_ADDR" "$PREFIX" "$SERVER_IP" <<'PY'
import configparser
import ipaddress
import json
import subprocess
import sys
source, target, interface, pci, prefix, server_ip = sys.argv[1:]
addresses = json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show", "dev", interface]))
address = next(a for a in addresses[0]["addr_info"] if a["family"] == "inet" and a["scope"] == "global")
network = ipaddress.IPv4Network(f'{address["local"]}/{address["prefixlen"]}', strict=False)
config = configparser.ConfigParser()
with open(source) as f:
    config.read_file(f)
routes = json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "get", server_ip, "oif", interface]))
gateway = next((r["gateway"] for r in routes if "gateway" in r), None)
if gateway is None:
    if ipaddress.IPv4Address(server_ip) not in network:
        raise SystemExit("No Ethernet gateway for a server outside the local subnet")
    candidate = ipaddress.IPv4Address(config.get("port0", "gateway", fallback="0.0.0.0"))
    gateway = str(candidate) if candidate in network and candidate not in (
        network.network_address, network.broadcast_address, ipaddress.IPv4Address(address["local"])
    ) else "0.0.0.0"
config["dpdk"].update(allow=pci, port_list="0", lcore_mask="1", idle_sleep="0", pkt_tx_delay="0", file_prefix=prefix)
config["port0"].update(addr=address["local"], netmask=str(network.netmask), broadcast=str(network.broadcast_address), gateway=gateway)
with open(target, "w") as f:
    config.write(f)
PY
cat "$RUN_DIR/f-stack.conf"
if (( HUGE_ORIGINAL < HUGE_TARGET )); then
    AVAILABLE_KB="$(awk '/^MemAvailable:/ {print $2}' "$PROCFS_ROOT/meminfo")"
    (( AVAILABLE_KB > (HUGE_TARGET-HUGE_ORIGINAL)*2048 + 262144 )) || fail 'Not enough available memory for hugepages.'
    HUGE_CHANGED=1
    save_state
    printf '%s\n' "$HUGE_TARGET" | sudo tee "$HUGE_PATH"
    (( $(cat "$HUGE_PATH") >= HUGE_TARGET )) || fail 'Not enough hugepages were allocated.'
fi
if ! mountpoint -q "$HUGE_DIR"; then
    if [[ ! -d "$HUGE_DIR" ]]; then
        DIRECTORY_CREATED=1
        save_state
        sudo mkdir -p "$HUGE_DIR"
    fi
    MOUNT_CREATED=1
    save_state
    sudo mount -t hugetlbfs -o pagesize=2M nodev "$HUGE_DIR"
fi
MOUNT_INFO="$(findmnt -n -o FSTYPE,OPTIONS --target "$HUGE_DIR")"
[[ "$MOUNT_INFO" == *hugetlbfs* && "$MOUNT_INFO" == *pagesize=2M* ]] || fail 'Expected a 2 MiB hugepage mount.'
grep -E 'HugePages|Hugepagesize|Hugetlb' "$PROCFS_ROOT/meminfo"
sudo modprobe vfio-pci
sudo nmcli device set "$ETH_IFACE" autoconnect no
sudo nmcli --wait 20 device disconnect "$ETH_IFACE"
sudo ip link set "$ETH_IFACE" down
sudo python3 "$DEVBIND" --bind=vfio-pci "$PCI_ADDR"
[[ "$(basename "$(readlink -f "$DEVICE/driver")")" == vfio-pci ]] || fail 'VFIO binding failed.'
python3 "$DEVBIND" --status
printf 'FSTACK_START\n'

sudo timeout --signal=TERM --kill-after=5s "${RUN_TIMEOUT}s" bash -c \
    'printf "%s\n" "$$" > "$1"; shift; exec "$@"' bash "$RUN_DIR/client.pid" \
    env SERVER_IP="$SERVER_IP" LD_LIBRARY_PATH="$DPDK_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "${CLIENT_RUNNER[@]}" "$APP_DIR/client_fstack" --conf "$RUN_DIR/f-stack.conf" --proc-type=primary --proc-id=0 &
CHILD_PID=$!
STATUS=0
wait "$CHILD_PID" || STATUS=$?
CHILD_PID=''
(( STATUS == 0 )) || fail "F-Stack client exited with status $STATUS"
printf 'FSTACK_OK\n'
