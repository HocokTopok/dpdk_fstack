# Запуск и проверка

Выполняй по одному блоку и присылай весь вывод перед переходом к следующему. Начни с блока 1. Сервер на Mac уже запущен — оставь его открытым.

## Блок 1 — Ubuntu: подключить Ethernet

```bash
cd "$HOME/dpdk_fstack"
export APP_DIR="$PWD"
export SERVER_IP="192.168.1.103"
export IFACE="enp44s0"
export PCI_ADDR="0000:2c:00.0"

sudo nmcli device connect "$IFACE"
ip -br addr
ip route get "$SERVER_IP"
```

## Блок 2 — Ubuntu: собрать и запустить обычный клиент

```bash
cd "$HOME/dpdk_fstack" &&
g++ -std=c++17 -O2 -Wall -Wextra -pthread client_plain.cpp -o client_plain &&
SERVER_IP="192.168.1.103" ./client_plain
```

## Блок 3 — Ubuntu: найти DPDK и F-Stack

```bash
uname -a
cat /etc/os-release
cat /proc/cmdline
find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d
grep -E 'HugePages|Hugepagesize|Hugetlb' /proc/meminfo
findmnt -t hugetlbfs
find "$HOME" -type f \( -name libdpdk.pc -o -name libfstack.a -o -name ff_api.h -o -name f-stack.conf -o -name dpdk-devbind.py \) -print 2>/dev/null
```
