#!/bin/ash
# OpenWrt 24.10.0 (RPi5) — LuCI + extras + ZeroTier
# Baseline 1.2 = Baseline 1.1 + fetch zerotiersetup.sh via curl
#              + tiny hardening: ensure a ZeroTier UCI section exists & enabled
#              + ORIGINAL USB adapter set (no extra chipsets)

set -eu

PKGS_LUCI="luci luci-ssl luci-compat luci-app-opkg"
PKGS_ZT="zerotier"
# Original USB/Ethernet + Wi-Fi driver set (includes Realtek RTL8152/8153)
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
  uci set zero
