#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Restore network config from <network-file>_backup
# and remove extra IPv4 addresses / source-routing rules
# added by setup.sh.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INTERFACE="${INTERFACE:-eth0}"
IP_FILE="${IP_FILE:-$SCRIPT_DIR/ip.txt}"

ROUTING_TABLE_START=100
ROUTING_PRIORITY_START=1000

NETWORK_FILE="${NETWORK_FILE:-/etc/network/interfaces.d/50-cloud-init}"
NETWORK_BACKUP="${NETWORK_FILE}_backup"
THREEPROXY_SERVICE="3proxy"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

if [ ! -f "$NETWORK_BACKUP" ]; then
    echo "Backup not found: $NETWORK_BACKUP"
    echo "Nothing to restore."
    exit 1
fi

cp -a "$NETWORK_BACKUP" "$NETWORK_FILE"
echo "Restored $NETWORK_FILE from $NETWORK_BACKUP"

if [ -f "$IP_FILE" ]; then
    i=0
    while read -r address gateway extra; do
        address="${address//$'\r'/}"
        [ -z "${address:-}" ] && continue
        [[ "$address" == \#* ]] && continue

        ipaddr="${address%/*}"
        table=$((ROUTING_TABLE_START + i))
        priority=$((ROUTING_PRIORITY_START + i))

        ip rule del from "$ipaddr/32" table "$table" priority "$priority" 2>/dev/null || true
        ip route flush table "$table" 2>/dev/null || true
        ip addr del "$address" dev "$INTERFACE" 2>/dev/null || true

        i=$((i + 1))
    done < "$IP_FILE"
    echo "Removed extra IPv4 addresses and policy routes from $INTERFACE"
else
    echo "ip.txt not found ($IP_FILE). Extra addresses may remain until reboot."
fi

if systemctl stop "$THREEPROXY_SERVICE" 2>/dev/null; then
    echo "Stopped $THREEPROXY_SERVICE (network IPs it used were removed)."
fi

echo
echo "Network restore completed."
echo "Live config: $NETWORK_FILE"
echo "Backup left in place: $NETWORK_BACKUP"
echo
