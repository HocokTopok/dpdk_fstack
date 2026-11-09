#!/usr/bin/env bash

# //
SERVER_IP="${SERVER_IP:-192.168.1.103}"
MAC_IFACE="${MAC_IFACE:-en0}"
ETH_IFACE="${ETH_IFACE:-enp44s0}"
WIFI_IFACE="${WIFI_IFACE:-wlp0s20f3}"
PCI_ADDR="${PCI_ADDR:-0000:2c:00.0}"
FSTACK_SRC="${FSTACK_SRC:-$HOME/C++Project/f-stack}"
DPDK_PREFIX="${DPDK_PREFIX:-$HOME/C++Project/build/dpdk-install}"
DEVBIND="${DEVBIND:-$HOME/C++Project/build/dpdk/usertools/dpdk-devbind.py}"
FSTACK_CONF="${FSTACK_CONF:-$HOME/C++Project/f-stack-install-26/etc/f-stack.conf}"
MEASUREMENTS="${MEASUREMENTS:-1000}"
HUGE_TARGET="${HUGE_TARGET:-1024}"
RUN_TIMEOUT="${RUN_TIMEOUT:-120}"
# //
