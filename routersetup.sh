#!/bin/ash
# OpenWrt 24.10.0 (RPi5) — LuCI + extras + ZeroTier
# Baseline 1.2 = Baseline 1.1 + fetch zerotiersetup.sh via curl
#              + tiny hardening: ensure a ZeroTier UCI section exists & enabled
#              + ORIGINAL USB adapter set (no extra chipsets)

set -eu

PKGS_LUCI="luci luci-ssl luci-compat luci-app-opkg"
PKGS_ZT="zerotier"
# Original USB/Ethernet + Wi-Fi driver set (includes RTL8152/8153)
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

retry() {
  _t="$1"; shift
  n=1
  while :; do
    if "$@"; then return 0; fi
    if [ "$n" -ge "$_t" ]; then return 1; fi
    n=$((n+1))
    sleep 2
  done
}
is_installed() { opkg list-installed | grep -q "^$1 -"; }
pkg_available() { opkg info "$1" >/dev/null 2>&1; }

ensure_time_sync() {
  if [ -x /etc/init.d/sysntpd ]; then
    /etc/init.d/sysntpd enable >/dev/null 2>&1 || true
    /etc/init.d/sysntpd start  >/dev/null 2>&1 || true
  fi
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
    ip -4 addr show br-lan | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
    return
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
      *)
        if [ ${#ZT_NETWORK_ID} -ne 16 ]; then
          echo "Must be exactly 16 chars." > /dev/tty
        else
          export ZT_NETWORK_ID
          break
        fi
      ;;
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
  if [ -z "$ZTCLI" ]; then err "zerotier-cli not found."; return 1; fi
  uci_force_enable_zerotier
  if [ -x /etc/init.d/zerotier ]; then
    /etc/init.d/zerotier enable  || true
    /etc/init.d/zerotier restart || /etc/init.d/zerotier start || true
  fi
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

  # 1) Install packages FIRST (driver present & loaded)
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
  done
  # Try to load r8152 now (harmless if not present)
  if [ -e "/lib/modules/$(uname -r)/r8152.ko" ]; then
    (modprobe r8152 2>/dev/null || insmod /lib/modules/$(uname -r)/r8152.ko 2>/dev/null || true)
  fi

  # 2) Bind WAN to eth1; remove any old wan_usb1; set WWAN fallback
  log "Configuring WAN on eth1..."
  uci -q delete network.wan_usb1
  uci -q get network.wan >/dev/null || { uci add network interface >/dev/null; uci rename network.@interface[-1]='wan'; }
  uci set network.wan.proto='dhcp'
  uci set network.wan.device='eth1'
  uci set network.wan.metric='10'
  if uci -q show network.wwan >/dev/null 2>&1; then
    uci set network.wwan.metric='100'
  fi
  uci commit network

  # Ensure firewall 'wan' zone references 'wan'
  WAN_ZONE=""
  for sec in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone.*/\1/p'); do
    name="$(uci -q get firewall.$sec.name 2>/dev/null || echo '')"
    [ "$name" = "wan" ] && { WAN_ZONE="$sec"; break; }
  done
  if [ -z "$WAN_ZONE" ]; then
    WAN_ZONE="$(uci add firewall zone)"
    uci set firewall.$WAN_ZONE.name='wan'
    uci set firewall.$WAN_ZONE.input='REJECT'
    uci set firewall.$WAN_ZONE.forward='REJECT'
    uci set firewall.$WAN_ZONE.output='ACCEPT'
  fi
  uci add_list firewall.$WAN_ZONE.network='wan' 2>/dev/null
  uci -q delete_list firewall.$WAN_ZONE.network='wan_usb1'
  uci commit firewall

  # Bring up WAN ONLY (avoid full restart that kills SSH)
  ifup wan || ubus call network.interface.wan up >/dev/null 2>&1 || true
  sleep 2
  log "WAN ifup attempted on eth1."

  # 3) Bring up system services (no network restart)
  if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd enable  || true
    /etc/init.d/uhttpd restart || /etc/init.d/uhttpd start || true
  fi
  if [ -x /etc/init.d/rpcd ]; then
    /etc/init.d/rpcd enable  || true
    /etc/init.d/rpcd restart || /etc/init.d/rpcd start || true
  fi

  # 4) Fetch helper script
  fetch_zt_setup || true

  # 5) Prompt & join ZeroTier LAST (no restarts after this)
  prompt_network_id_blocking
  join_zerotier || true

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
