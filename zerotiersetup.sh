#!/bin/ash
# ZeroTier bridge setup for OpenWrt 24.10.0 (RPi5)
# Focus: add the single OK zt* device to br-lan (no LAN IP edits)

set -eu

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[~] %s\n' "$*" >&2; }
err()  { printf '[!] %s\n' "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

# Parse zerotier-cli listnetworks and output "NWID DEV" for OK networks only
list_ok_nwid_dev() {
  zerotier-cli listnetworks | awk '
    $1=="200" && $2=="listnetworks" {
      ok=0; dev=""; nwid="";
      for (i=1;i<=NF;i++) if ($i=="OK") ok=1;
      if (ok) {
        for (i=1;i<=NF;i++) if ($i ~ /^zt[[:alnum:]]+$/) dev=$i;
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-f]{16}$/) { nwid=$i; break }
        if (nwid!="" && dev!="") print nwid " " dev;
      }
    }'
}

# Choose exactly one OK network (fail if 0 or >1)
choose_ok_network() {
  OK_LIST="$(list_ok_nwid_dev || true)"
  COUNT=$(printf '%s\n' "$OK_LIST" | sed '/^$/d' | wc -l)
  if [ "$COUNT' " = "0 " ] || [ "$COUNT" -eq 0 ]; then
    err "No OK ZeroTier networks found. (Statuses: $(zerotier-cli listnetworks | awk '$1=="200"{print $5}' | tr '\n' ' '))"
    exit 1
  fi
  if [ "$COUNT" -gt 1 ]; then
    err "Found $COUNT OK networks; expected exactly 1. Leave extras first."
    printf '%s\n' "$OK_LIST" | nl -ba >&2
    exit 1
  fi
  NWID="$(printf '%s\n' "$OK_LIST" | awk '{print $1}')"
  ZT_DEV="$(printf '%s\n' "$OK_LIST" | awk '{print $2}')"
  printf '%s %s\n' "$NWID" "$ZT_DEV"
}

# Create/Update interface 'zerotier' with proto none and the zt* device
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

# Add zt* to br-lan bridge ports
bridge_zt_into_brlan() {
  dev="$1"
  # Find the device section whose name is br-lan
  idx="$(uci show network | sed -n "s/^network\.@device\[\([0-9]\+\)\]\.name='br-lan'.*/\1/p" | head -n1 || true)"
  if [ -z "${idx:-}" ]; then
    err "No 'config device' section named 'br-lan' found in /etc/config/network; aborting to avoid breaking LAN."
    exit 1
  fi
  ports="$(uci -q get network.@device[$idx].ports || echo '')"
  case " $ports " in
    *" $dev "*) log "br-lan already includes '$dev'; skipping." ;;
    *) uci add_list "network.@device[$idx].ports=$dev"; log "Added '$dev' to br-lan ports." ;;
  esac
}

apply_network() {
  uci commit network
  /etc/init.d/network reload >/dev/null 2>&1 || true
  log "Applied changes (commit + reload)."
}

main() {
  need_cmd zerotier-cli
  need_cmd uci
  need_cmd ip

  SEL="$(choose_ok_network)"
  NWID="$(printf '%s\n' "$SEL" | awk '{print $1}')"
  ZT_DEV="$(printf '%s\n' "$SEL" | awk '{print $2}')"
  log "Using OK network $NWID on device $ZT_DEV"

  ensure_interface_zerotier "$ZT_DEV"
  bridge_zt_into_brlan "$ZT_DEV"
  apply_network
}

main "$@"
