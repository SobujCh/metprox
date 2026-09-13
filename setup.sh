#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Debian Multi-IP 3proxy Setup
#
# Looks for auth.txt and ip.txt next to this script.
# If either is missing, prompts for it and writes the file.
# Backs up the live network file once as <file>_backup,
# writes a new config with extra IPv4s + source routing,
# applies it live (no networking restart), then installs 3proxy
# with one port per outgoing IPv4.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INTERFACE="${INTERFACE:-eth0}"
IP_FILE="${IP_FILE:-$SCRIPT_DIR/ip.txt}"
AUTH_FILE="${AUTH_FILE:-$SCRIPT_DIR/auth.txt}"

PROXY_START_PORT="${PROXY_START_PORT:-30000}"
ROUTING_TABLE_START=100
ROUTING_PRIORITY_START=1000

NETWORK_FILE="${NETWORK_FILE:-/etc/network/interfaces.d/50-cloud-init}"
NETWORK_BACKUP="${NETWORK_FILE}_backup"
THREEPROXY_CONFIG="/etc/3proxy/3proxy.cfg"
THREEPROXY_SERVICE="3proxy"

# ============================================================
# Root and required commands
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

for cmd in ip awk sed grep systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing command: $cmd"
        exit 1
    }
done

# ============================================================
# Interactive prompts
# ============================================================

read_tty() {
    if [ -r /dev/tty ]; then
        read -r "$@" < /dev/tty || return $?
    else
        read -r "$@" || return $?
    fi
}

prompt_auth() {
    local auth user pass
    echo
    echo "auth.txt not found. Enter proxy credentials as username:password"
    while true; do
        read_tty -p "Auth: " auth
        auth="${auth//$'\r'/}"
        user="${auth%%:*}"
        pass="${auth#*:}"
        if [ -z "$auth" ] || [ "$auth" = "$user" ] || [ -z "$user" ] || [ -z "$pass" ]; then
            echo "Invalid format. Example: myuser:S3cretPass"
            continue
        fi
        printf '%s\n' "$auth" > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
        echo "Saved $AUTH_FILE"
        break
    done
}

prompt_ips() {
    local line count=0
    echo
    echo "ip.txt not found. Paste the full IP list, one 'address/prefix gateway' per line."
    echo "Example: 103.174.50.4/24 103.174.50.1"
    echo "Finish with an empty line or Ctrl-D."
    : > "$IP_FILE"
    while true; do
        read_tty line || break
        line="${line//$'\r'/}"
        [ -z "$line" ] && break
        printf '%s\n' "$line" >> "$IP_FILE"
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        rm -f "$IP_FILE"
        echo "No IP lines received."
        exit 1
    fi
    echo "Saved $count line(s) to $IP_FILE"
}

if [ ! -f "$AUTH_FILE" ]; then
    prompt_auth
fi

if [ ! -f "$IP_FILE" ]; then
    prompt_ips
fi

chmod 600 "$AUTH_FILE" 2>/dev/null || true

# ============================================================
# Read credentials (username:password or legacy two-line)
# ============================================================

AUTH_LINE1="$(sed -n '1p' "$AUTH_FILE" | tr -d '\r')"
AUTH_LINE2="$(sed -n '2p' "$AUTH_FILE" | tr -d '\r')"

if [[ "$AUTH_LINE1" == *:* ]] && [ -z "$AUTH_LINE2" ]; then
    PROXY_USER="${AUTH_LINE1%%:*}"
    PROXY_PASSWORD="${AUTH_LINE1#*:}"
else
    PROXY_USER="$AUTH_LINE1"
    PROXY_PASSWORD="$AUTH_LINE2"
fi

if [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASSWORD" ]; then
    echo "Username or password is empty in $AUTH_FILE"
    echo "Expected username:password (one line) or username on line 1 and password on line 2."
    exit 1
fi

# ============================================================
# Read and validate IP list
# ============================================================

declare -a IPS=()
declare -a GATEWAYS=()

while read -r address gateway extra; do
    address="${address//$'\r'/}"
    gateway="${gateway//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "${address:-}" ] && continue
    [[ "$address" == \#* ]] && continue

    if [ -z "${gateway:-}" ] || [ -n "${extra:-}" ]; then
        echo "Invalid line: $address $gateway ${extra:-}"
        exit 1
    fi

    if [[ ! "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "Invalid IPv4 address: $address"
        exit 1
    fi

    if [[ ! "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid gateway: $gateway"
        exit 1
    fi

    IPS+=("$address")
    GATEWAYS+=("$gateway")
done < "$IP_FILE"

if [ "${#IPS[@]}" -eq 0 ]; then
    echo "No IP addresses found in $IP_FILE"
    exit 1
fi

echo "Found ${#IPS[@]} proxy IPs."

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "Interface not found: $INTERFACE"
    exit 1
fi

if [ ! -f "$NETWORK_FILE" ]; then
    echo "Network config not found: $NETWORK_FILE"
    exit 1
fi

# ============================================================
# Install packages
# ============================================================

apt-get update
apt-get install -y 3proxy iproute2 python3

# ============================================================
# Backup current network config once
# ============================================================

if [ -e "$NETWORK_BACKUP" ]; then
    echo "Backup already exists, leaving it unchanged: $NETWORK_BACKUP"
else
    cp -a "$NETWORK_FILE" "$NETWORK_BACKUP"
    echo "Created backup: $NETWORK_BACKUP"
fi

# Always rebuild the live file from the original backup so re-runs
# do not stack duplicate address/routing lines.
NETWORK_SOURCE="$NETWORK_BACKUP"

# ============================================================
# Apply additional IPs and source routing live
# ============================================================

declare -a EXTRA_IFACE_LINES=()

for i in "${!IPS[@]}"; do
    address="${IPS[$i]}"
    gateway="${GATEWAYS[$i]}"
    ipaddr="${address%/*}"
    prefix="${address#*/}"
    table=$((ROUTING_TABLE_START + i))
    priority=$((ROUTING_PRIORITY_START + i))

    network="$(python3 - "$ipaddr" "$prefix" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False))
PY
)"

    if ! ip -4 addr show dev "$INTERFACE" | grep -qE "inet ${ipaddr}/"; then
        ip addr add "$address" dev "$INTERFACE"
    fi

    ip route replace "$network" dev "$INTERFACE" src "$ipaddr" table "$table"
    ip route replace default via "$gateway" dev "$INTERFACE" src "$ipaddr" table "$table"
    ip rule del from "$ipaddr/32" table "$table" priority "$priority" 2>/dev/null || true
    ip rule add from "$ipaddr/32" table "$table" priority "$priority"

    EXTRA_IFACE_LINES+=("    up ip addr add $address dev $INTERFACE")
    EXTRA_IFACE_LINES+=("    down ip addr del $address dev $INTERFACE 2>/dev/null || true")
    EXTRA_IFACE_LINES+=("    up ip route replace $network dev $INTERFACE src $ipaddr table $table")
    EXTRA_IFACE_LINES+=("    up ip route replace default via $gateway dev $INTERFACE src $ipaddr table $table")
    EXTRA_IFACE_LINES+=("    up ip rule add from $ipaddr/32 table $table priority $priority")
    EXTRA_IFACE_LINES+=("    down ip rule del from $ipaddr/32 table $table priority $priority 2>/dev/null || true")
done

# ============================================================
# Write new persistent network config from the backup
# ============================================================

NETWORK_TMP="$(mktemp)"
EXTRA_FILE="$(mktemp)"
printf '%s\n' "${EXTRA_IFACE_LINES[@]}" > "$EXTRA_FILE"
python3 - "$NETWORK_SOURCE" "$NETWORK_TMP" "$EXTRA_FILE" "$INTERFACE" <<'PY'
import sys

src, dst, extra_path, iface = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(extra_path, encoding="utf-8") as f:
    extra = [line.rstrip("\n") for line in f if line.strip()]

with open(src, encoding="utf-8", errors="replace") as f:
    lines = [line.rstrip("\n") for line in f]

out = []
in_target = False
inserted = False
marker = "# Additional IPv4 addresses and source routing (metprox)"

for line in lines:
    stripped = line.strip()
    is_target = (
        stripped.startswith(f"iface {iface} inet ")
        and not stripped.startswith(f"iface {iface} inet6")
    )
    if is_target:
        in_target = True
        out.append(line)
        continue
    if in_target and (stripped.startswith("iface ") or stripped.startswith("auto ")):
        if not inserted:
            out.append(f"    {marker}")
            out.extend(extra)
            inserted = True
        in_target = False
    out.append(line)

if in_target and not inserted:
    out.append(f"    {marker}")
    out.extend(extra)
    inserted = True

if not inserted:
    sys.exit(f"Could not find 'iface {iface} inet ...' in {src}")

with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
rm -f "$EXTRA_FILE"

mv "$NETWORK_TMP" "$NETWORK_FILE"
echo "Wrote new network config: $NETWORK_FILE"

# Stop cloud-init from regenerating the interfaces file on reboot.
if [ -d /etc/cloud/cloud.cfg.d ]; then
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
fi

# ============================================================
# Create 3proxy configuration (1 port per outgoing IPv4)
# ============================================================

mkdir -p /etc/3proxy

cat > "$THREEPROXY_CONFIG" <<EOF
daemon
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 1800 1800 15 60
users $PROXY_USER:CL:$PROXY_PASSWORD
auth strong
allow $PROXY_USER
EOF

for i in "${!IPS[@]}"; do
    ipaddr="${IPS[$i]%/*}"
    port=$((PROXY_START_PORT + i))
    cat >> "$THREEPROXY_CONFIG" <<EOF
proxy -p$port -i0.0.0.0 -e$ipaddr
EOF
done

chmod 600 "$THREEPROXY_CONFIG"

# ============================================================
# Enable and restart 3proxy
# ============================================================

systemctl enable "$THREEPROXY_SERVICE"
systemctl restart "$THREEPROXY_SERVICE"

# ============================================================
# Summary
# ============================================================

echo
echo "=========================================="
echo "3proxy setup completed"
echo "=========================================="
echo "Username: $PROXY_USER"
echo "Password: ********"
echo

for i in "${!IPS[@]}"; do
    ipaddr="${IPS[$i]%/*}"
    echo "$ipaddr:$((PROXY_START_PORT + i))"
done

echo
echo "Auth: $AUTH_FILE"
echo "IPs: $IP_FILE"
echo "Config: $THREEPROXY_CONFIG"
echo "Network: $NETWORK_FILE"
echo "Backup: $NETWORK_BACKUP"
echo "Restore: $SCRIPT_DIR/restore.sh"
echo
