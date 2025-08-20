#!/bin/ash
# ZeroTier bridge setup for OpenWrt 24.10.0 (RPi5)
# Assumes: Router Setup Baseline 1.1 is complete AND node is approved in ZeroTier.
set -eu

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[~] %s\n' "$*" >&2; }
err()  { printf '[!] %s\n' "$*" >&2; }

# Find a zt* device, prefer one with IPv4 assigned
detect_zt_device() {
  # List zt* devices
  ZT_DEVS="$(ip -o link show | awk -F': ' '/: zt[0-9a-f]{10}:/{print $2}' || true)"
  [ -n "${ZT_DEVS:-}" ] || { err "No zt* device found. Is ZeroTier up and authorized?"; exit 1; }

  # Prefer a zt* that already has an IPv4 address
  for d in $ZT_DEVS; do
    if ip -4 addr show "$d" | grep -q 'inet '; then
      echo "$d"
      return 0
    fi
  done

  # Fallback to the first zt* if none have IPv4 (not ideal for step 2)
  echo "$(printf '%s\n' $ZT_DEVS | head -n1)"
}

# Return first IPv4 CIDR on a device (e.g., 10.0.0.5/24)
get_ipv4_cidr() {
  dev="$1"
  ip -4 addr show "$dev" | awk '/inet /{print $2; exit}'
}

# Convert prefix length to netmask (BusyBox-safe)
prefix_to_netmask() {
  pfx="$1"
  case "$pfx" in
    0)  echo "0.0.0.0" ;;
    1)  echo "128.0.0.0" ;;
    2)  echo "192.0.0.0" ;;
    3)  echo "224.0.0.0" ;;
    4)  echo "240.0.0.0" ;;
    5)  echo "248.0.0.0" ;;
    6)  echo "252.0.0.0" ;;
    7)  echo "254.0.0.0" ;;
    8)  echo "255.0.0.0" ;;
    9)  echo "255.128.0.0" ;;
    10) echo "255.192.0.0" ;;
    11) echo "255.224.0.0" ;;
    12) echo "255.240.0.0" ;;
    13) echo "255.248.0.0" ;;
    14) echo "255.252.0.0" ;;
    15) echo "255.254.0.0" ;;
    16) echo "255.255.0.0" ;;
    17) echo "255.255.128.0" ;;
    18) echo "255.255.192.0" ;;
    19) echo "255.255.224.0" ;;
    20) echo "255.255.240.0" ;;
    21) echo "255.255.248.0" ;;
    22) echo "255.255.252.0" ;;
    23) echo "255.255.254.0" ;;
    24) echo "255.255.255.0" ;;
    25) echo "255.255.255.128" ;;
    26) echo "255.255.255.192" ;;
    27) echo "255.255.255.224" ;;
    28) echo "255.255.255.240" ;;
    29) echo "255.255.255.248" ;;
    30) echo "255.255.255.252" ;;
    31) echo "255.255.255.254" ;;
    32) echo "255.255.255.255" ;;
    *)  err "Invalid prefix: $pfx"; exit 1 ;;
  esac
}

# Create/update interface 'zerotier' with proto none and device = zt*
ensure_interface_zerotier() {
  dev="$1"
  if uci -q show network.zerotier >/dev/null 2>&1; then
    uci set network.zerotier.proto='none'
    uci set network.zerotier.device="$dev"
  else
    sec="$(uci add network interface)"
    uci set "network.$sec.proto='none'"
    uci set "network.$sec.device=$dev"
    uci -q rename "network.$sec=zerotier"
  fi
  log "Configured interface 'zerotier' (proto none, device $dev)."
}

# Set LAN IPv4/mask to match the zt* IPv4
sync_lan_to_zt() {
  cidr="$1"   # e.g., 10.0.0.5/24
  ipaddr="${cidr%/*}"
  pfx="${cidr#*/}"
  netmask="$(prefix_to_netmask "$pfx")"

  # Sanity
  [ -n "$ipaddr" ] && [ -n "$netmask" ] || { err "Failed to parse ZeroTier IPv4 CIDR."; exit 1; }

  # Ensure LAN exists and is static (do not flip proto if you don't want to)
  if ! uci -q show network.lan >/dev/null 2>&1; then
    err "network.lan not found; aborting LAN IP change."
    exit 1
  fi
  uci set network.lan.ipaddr="$ipaddr"
  uci set network.lan.netmask="$netmask"
  log "Set LAN IPv4 to $ipaddr/$pfx (netmask $netmask) to match ZeroTier."
}

# Add zt* device to br-lan bridge ports
bridge_zt_into_brlan() {
  dev="$1"
  idx="$(uci show network | sed -n "s/^network\.@device\[\([0-9]\+\)\]\.name='br-lan'.*/\1/p" | head -n1 || true)"
  if [ -z "${idx:-}" ]; then
    warn "No device section for br-lan found; skipping bridge port add."
    return 0
  fi

  # Check if already present
  if uci -q show "network.@device[$idx]" | grep -q "ports='$dev'"; then
    log "br-lan already includes port '$dev'; skipping."
    return 0
  fi

  uci add_list "network.@device[$idx].ports=$dev"
  log "Added '$dev' to br-lan bridge ports."
}

apply_network() {
  uci commit network
  /etc/init.d/network reload >/dev/null 2>&1 || true
  log "Applied changes (committed + network reload)."
}

main() {
  ZT_DEV="$(detect_zt_device)"
  log "ZeroTier device: $ZT_DEV"

  # 1) Interface zerotier (unmanaged, device = zt*)
  ensure_interface_zerotier "$ZT_DEV"

  # 2) Sync LAN IPv4/mask to ZeroTier device IPv4
  ZT_CIDR="$(get_ipv4_cidr "$ZT_DEV" || true)"
  if [ -z "${ZT_CIDR:-}" ]; then
    err "ZeroTier device has no IPv4 address yet. Is the network managed DHCP/assignments enabled and this node authorized?"
  fi
  sync_lan_to_zt "$ZT_CIDR"

  # 3) Add zt* as a port on br-lan
  bridge_zt_into_brlan "$ZT_DEV"

  # 4) Apply
  apply_network
}

main "$@"
