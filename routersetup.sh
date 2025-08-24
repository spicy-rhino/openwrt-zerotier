#!/bin/ash
# OpenWrt 24.10.0 (RPi5) — LuCI + extras + ZeroTier
# Baseline 1.2 = Baseline 1.1 + fetch zerotiersetup.sh via curl
#              + tiny hardening: ensure a ZeroTier UCI section exists & enabled
#              + ORIGINAL USB adapter set (no extra chipsets)

set -eu

PKGS_LUCI="luci luci-ssl luci-compat luci-app-opkg"
PKGS_ZT="zerotier"
# Original USB/Ethernet + Wi-Fi driver set
PKGS_USB="\
kmod-rt2800-lib kmod-rt2800-usb kmod-rt2x00-lib kmod-rt2x00-usb \
kmod-usb-core kmod-usb-uhci kmod-usb-ohci kmod-usb2 \
usbutils nano \
kmod-usb-net-asix-ax88179 kmod-usb-net-cdc-ether kmod-usb-net-rndis \
kmod-usb-net-rtl8152"
PKGS="$PKGS_LUCI $PKGS_ZT $PKGS_USB"

ZTCLI=""
RETRIES=3
VERSION="baseline-1.2"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[~] %s\n' "$*" >&2; }
err()  { printf '[!] %s\n' "$*" >&2; }

retry() { _t="$1"; shift; n=1; while :; do if "$@"; then return 0; fi; [ $n -ge $_t ] && return 1; n=$((n+1)); sleep 2; done; }
is_installed() { opkg list-installed | grep -q "^$1 -"; }
pkg_available() { opkg info "$1" >/dev/null 2>&1; }

ensure_time_sync() {
  [ -x /etc/init.d/sysntpd ] && { /etc/init.d/sysntpd enable >/dev/null 2>&1 || true; /etc/init.d/sysntpd start >/dev/null 2>&1 || true; }
}

# WWAN DNS override (only if network.wwan exists)
configure_wwan_dns() {
  if uci -q show network.wwan >/dev/null 2>&1; then
    uci set network.wwan.peerdns='0'
    uci -q delete network.wwan.dns || true
    uci add_list network.wwan.dns='1.1.1.1'
    uci commit network
    /etc/init.d/network reload >/dev/null 2>&1 || true
    log "WWAN DNS set to 1.1.1.1 (peerdns=0)."
  else
    warn "WWAN interface not found; skipping WWAN DNS change."
  fi
}

get_lan_ip() {
  if ip -4 addr show br-lan >/dev/null 2>&1; then
    ip -4 addr show br-lan | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1; return
  fi
  ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 \
    | awk '/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/{print; exit}'
}

prompt_network_id_blocking() {
  echo
  echo "==============================================================" > /dev/tty
  echo "   ACTION REQUIRED: Enter ZeroTier NETWORK ID to continue      " > /dev/tty
  echo "   (Find it at https://my.zerotier.com under your network.)    " > /dev/tty
  echo "   Expected format: 16 hex characters (e.g., 8056c2e21c000001) " > /dev/tty
  echo "==============================================================" > /dev/tty
  echo > /dev/tty
  while :; do
    printf "ZeroTier Network ID: " > /dev/tty
    if ! read ZT_NETWORK_ID < /dev/tty; then err "No TTY available for input."; exit 2; fi
    ZT_NETWORK_ID="$(printf '%s' "$ZT_NETWORK_ID" | tr -d ' \t\r\n' | tr 'A-F' 'a-f')"
    case "$ZT_NETWORK_ID" in
      *[!0-9a-f]*|"") echo "Invalid network ID. Must be 16 hex chars." > /dev/tty ;;
      *) if [ ${#ZT_NETWORK_ID} -ne 16 ]; then echo "Must be exactly 16 chars." > /dev/tty; else export ZT_NETWORK_ID; break; fi ;;
    esac
  done
}

detect_ztcli() {
  if command -v zerotier-cli >/dev/null 2>&1; then
    ZTCLI="$(command -v zerotier-cli)"
  elif [ -x /usr/bin/zerotier-cli ]; then
    ZTCLI="/usr/bin/zerotier-cli"
  elif [ -x /usr/sbin/zerotier-cli ]; then
    ZTCLI="/usr/sbin/zerotier-cli"
  else
    ZTCLI=""
  fi
  export ZTCLI
}

# Tiny hardening: ensure a zerotier section exists and is enabled
uci_force_enable_zerotier() {
  uci -q show zerotier >/dev/null 2>&1 || uci add zerotier zerotier >/dev/null
  if ! uci -q get zerotier.@zerotier[0].enabled >/dev/null 2>&1; then
    [ -n "$(uci -q show zerotier | sed -n 's/^zerotier\.\([^.]*\)=zerotier.*/\1/p' | head -n1)" ] || uci add zerotier zerotier >/dev/null
  fi
  uci set zerotier.@zerotier[0].enabled='1'
  uci commit zerotier
}

ensure_zerotier_running() {
  detect_ztcli
  if [ -z "$ZTCLI" ]; then
    log "Installing ZeroTier..."
    retry "$RETRIES" opkg update || true
    retry "$RETRIES" opkg install zerotier || { err "Failed to install 'zerotier'."; return 1; }
    detect_ztcli
  fi
  [ -n "$ZTCLI" ] || { err "zerotier-cli not found."; return 1; }
  uci_force_enable_zerotier
  [ -x /etc/init.d/zerotier ] && { /etc/init.d/zerotier enable || true; /etc/init.d/zerotier restart || /etc/init.d/zerotier start || true; }
  retry 5 "$ZTCLI" info >/dev/null 2>&1 || { err "ZeroTier service not responding to '$ZTCLI info'."; return 1; }
  return 0
}

join_zerotier() {
  log "Joining ZeroTier network: $ZT_NETWORK_ID"
  ensure_zerotier_running || { err "ZeroTier isn't running; cannot join."; return 1; }
  retry "$RETRIES" "$ZTCLI" join "$ZT_NETWORK_ID" || { err "Failed to join $ZT_NETWORK_ID"; return 1; }
  sleep 2
  "$ZTCLI" listnetworks | grep "$ZT_NETWORK_ID" || true
  echo
  echo "If the network requires controller authorization, approve this node in the ZeroTier web UI."
  echo "Leave later:  $ZTCLI leave $ZT_NETWORK_ID"
  echo
}

# Fetch zerotiersetup.sh and make it executable
fetch_zt_setup() {
  if ! command -v curl >/dev/null 2>&1; then
    log "Installing curl + CA certs for HTTPS fetch..."
    retry "$RETRIES" opkg install curl ca-bundle ca-certificates || {
      err "Failed to install curl/CA certs; cannot fetch zerotiersetup.sh automatically."
      return 1
    }
  fi
  log "Downloading zerotiersetup.sh..."
  retry "$RETRIES" sh -c 'curl -fsSLO https://raw.githubusercontent.com/spicy-rhino/openwrt-zerotier/main/zerotiersetup.sh' || {
    err "curl download failed."
    return 1
  }
  chmod +x zerotiersetup.sh
  log "zerotiersetup.sh downloaded and made executable."
}

main() {
  log "Version: $VERSION"
  log "Ensuring time sync..."; ensure_time_sync

  configure_wwan_dns
  
  log "Configuring WAN on eth1..."
  uci set network.wan.device='eth1'
  uci set network.wan.proto='dhcp'
  uci set network.wan.metric='10'
  if uci -q show network.wwan >/dev/null 2>&1; then
    uci set network.wwan.metric='100'
  fi
  uci commit network
  /etc/init.d/network restart >/dev/null 2>&1 || true
  log "WAN bound to eth1 (metric 10), WWAN fallback (metric 100 if present)."

  log "Updating package lists..."; retry "$RETRIES" opkg update || { err "opkg update failed"; exit 1; }
  [ -f /var/lock/opkg.lock ] && { err "Another opkg process is running (opkg.lock present)."; exit 1; }

  for p in $PKGS; do
    if is_installed "$p"; then
      log "Package '$p' already installed; skipping."
    else
      if pkg_available "$p"; then
        log "Installing '$p'..."
        retry "$RETRIES" opkg install "$p" || { err "Failed to install '$p'"; exit 1; }
      else
        warn "Package '$p' not available for this target; skipping."
      fi
    fi
# --- Single USB WAN preferred over WWAN (no mwan3, no hotplug) ---

set -eu

# 1) Detect the first USB-backed ethernet (falls back to eth1 if none found yet)
USB_DEV="${USB_WAN_DEV:-}"
if [ -z "${USB_DEV}" ]; then
  for p in /sys/class/net/eth*; do
    [ -e "$p" ] || continue
    IF="$(basename "$p")"
    if readlink -f "/sys/class/net/$IF/device" 2>/dev/null | grep -q '/usb'; then
      USB_DEV="$IF"
      break
    fi
  done
fi
USB_DEV="${USB_DEV:-eth1}"
echo "[+] USB WAN device: $USB_DEV"

# 2) Create/refresh a single USB WAN interface (DHCP), preferred via low metric
uci -q get network.wan_usb1 >/dev/null || { uci add network interface; uci rename network.@interface[-1]='wan_usb1'; }
uci set network.wan_usb1.proto='dhcp'
uci set network.wan_usb1.device="$USB_DEV"
uci set network.wan_usb1.peerdns='1'
uci set network.wan_usb1.defaultroute='1'
uci set network.wan_usb1.metric='10'
uci set network.wan_usb1.hostname='openwrt'

# 3) Make WWAN a fallback if it exists (higher metric)
if uci -q show network.wwan >/dev/null 2>&1; then
  uci set network.wwan.metric='100'
fi
uci commit network

# 4) Ensure exactly ONE firewall zone named 'wan'; merge duplicates; attach wan, wan_usb1, (wwan if present)
WAN_ZONES="$(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone.*/\1/p' \
  | while read s; do [ "$(uci -q get firewall.$s.name)" = "wan" ] && echo "$s"; done || true)"
PRIMARY_WAN_ZONE="$(echo "$WAN_ZONES" | head -n1)"
EXTRA_WAN_ZONES="$(echo "$WAN_ZONES" | tail -n +2)"

if [ -z "${PRIMARY_WAN_ZONE}" ]; then
  PRIMARY_WAN_ZONE="$(uci add firewall zone)"
  uci set firewall.$PRIMARY_WAN_ZONE.name='wan'
  uci set firewall.$PRIMARY_WAN_ZONE.input='REJECT'
  uci set firewall.$PRIMARY_WAN_ZONE.forward='REJECT'
  uci set firewall.$PRIMARY_WAN_ZONE.output='ACCEPT'
fi

if [ -n "${EXTRA_WAN_ZONES}" ]; then
  for z in $EXTRA_WAN_ZONES; do
    for n in $(uci -q get firewall.$z.network 2>/dev/null | tr ' ' '\n'); do
      uci add_list firewall.$PRIMARY_WAN_ZONE.network="$n" 2>/dev/null || true
    done
    uci delete firewall.$z
  done
fi

# Attach networks to the single WAN zone (idempotent), then de-dup
uci add_list firewall.$PRIMARY_WAN_ZONE.network='wan'        2>/dev/null || true
uci add_list firewall.$PRIMARY_WAN_ZONE.network='wan_usb1'   2>/dev/null || true
uci -q show network.wwan >/dev/null 2>&1 && uci add_list firewall.$PRIMARY_WAN_ZONE.network='wwan' 2>/dev/null || true

NLIST="$(uci -q get firewall.$PRIMARY_WAN_ZONE.network 2>/dev/null | tr ' ' '\n' | awk ' !seen[$0]++ ')"
uci -q delete firewall.$PRIMARY_WAN_ZONE.network
for n in $NLIST; do uci add_list firewall.$PRIMARY_WAN_ZONE.network="$n"; done
uci commit firewall
/etc/init.d/firewall restart || true

# 5) Restart network so DHCP runs on the USB NIC if present; show default routes
/etc/init.d/network restart || true
sleep 2
echo "=== default routes (lower metric preferred) ==="
ip -4 route show default || true

  done

  [ -x /etc/init.d/uhttpd ] && { /etc/init.d/uhttpd enable || true; /etc/init.d/uhttpd restart || /etc/init.d/uhttpd start || true; }
  [ -x /etc/init.d/rpcd ]   && { /etc/init.d/rpcd   enable || true; /etc/init.d/rpcd   restart || /etc/init.d/rpcd   start || true; }

  prompt_network_id_blocking
  join_zerotier || true

  fetch_zt_setup || true

  LAN_IP="$(get_lan_ip || true)"
  log "Done."
  echo
  if [ -n "${LAN_IP:-}" ]; then
    echo "LuCI Web UI (HTTP):  http://${LAN_IP}/"
    echo "LuCI Web UI (HTTPS): https://${LAN_IP}/"
    echo "Next: run ./zerotiersetup.sh to bridge ZeroTier into br-lan."
  else
    echo "LuCI Web UI is up on LAN (IP not auto-detected)."
  fi
}

main "$@"
