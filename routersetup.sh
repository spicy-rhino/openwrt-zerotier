cat > /root/routersetup.sh <<'SH'
#!/bin/ash
# OpenWrt 24.10.0 (RPi5) — LuCI + extras + ZeroTier (ash-safe, auto-detect zerotier-cli, UCI enable)

set -eu

PKGS_LUCI="luci luci-ssl luci-compat luci-app-opkg"
PKGS_ZT="zerotier"
PKGS_USB="kmod-rt2800-lib kmod-rt2800-usb kmod-rt2x00-lib kmod-rt2x00-usb \
kmod-usb-core kmod-usb-uhci kmod-usb-ohci kmod-usb2 usbutils nano \
kmod-usb-net-asix-ax88179 kmod-usb-net-cdc-ether kmod-usb-net-rndis"
PKGS="$PKGS_LUCI $PKGS_ZT $PKGS_USB"

ZTCLI=""
RETRIES=3

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[~] %s\n' "$*" >&2; }
err()  { printf '[!] %s\n' "$*" >&2; }

retry() { _t="$1"; shift; n=1; while :; do if "$@"; then return 0; fi; [ $n -ge $_t ] && return 1; n=$((n+1)); sleep 2; done; }

is_installed() { opkg list-installed | grep -q "^$1 -"; }
pkg_available() { opkg info "$1" >/dev/null 2>&1; }

ensure_time_sync() {
  [ -x /etc/init.d/sysntpd ] && { /etc/init.d/sysntpd enable >/dev/null 2>&1 || true; /etc/init.d/sysntpd start >/dev/null 2>&1 || true; }
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
      *[!0-9a-f]*|"") echo "Invalid network ID. Must be 16 hex chars." > /dev/tty;;
      *) if [ ${#ZT_NETWORK_ID} -ne 16 ]; then echo "Must be exactly 16 chars." > /dev/tty; else export ZT_NETWORK_ID; break; fi;;
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

uci_enable_zerotier() {
  # Ensure at least one 'zerotier' section exists and set enabled=1 on all
  if ! uci show zerotier 2>/dev/null | grep -q '=zerotier'; then
    uci add zerotier zerotier >/dev/null
  fi
  for s in $(uci show zerotier | sed -n 's/^\(zerotier\.[^.]*\)=zerotier.*/\1/p'); do
    uci set $s.enabled='1'
  done
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

  uci_enable_zerotier
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

main() {
  log "Ensuring time sync..."; ensure_time_sync
  log "Updating package lists..."; retry "$RETRIES" opkg update || { err "opkg update failed"; exit 1; }
  [ -f /var/lock/opkg.lock ] && { err "Another opkg process is running (opkg.lock present)."; exit 1; }

  for p in $PKGS; do
    if is_installed "$p"; then log "Package '$p' already installed; skipping."
    else
      if pkg_available "$p"; then log "Installing '$p'..."; retry "$RETRIES" opkg install "$p" || { err "Failed to install '$p'"; exit 1; }
      else warn "Package '$p' not available for this target; skipping."; fi
    fi
  done

  [ -x /etc/init.d/uhttpd ] && { /etc/init.d/uhttpd enable || true; /etc/init.d/uhttpd restart || /etc/init.d/uhttpd start || true; }
  [ -x /etc/init.d/rpcd ]   && { /etc/init.d/rpcd   enable || true; /etc/init.d/rpcd   restart || /etc/init.d/rpcd   start || true; }

  prompt_network_id_blocking
  join_zerotier || true

  LAN_IP="$(get_lan_ip || true)"
  log "Done."
  echo
  if [ -n "${LAN_IP:-}" ]; then
    echo "LuCI Web UI (HTTP):  http://${LAN_IP}/"
    echo "LuCI Web UI (HTTPS): https://${LAN_IP}/"
  else
    echo "LuCI Web UI is up on LAN (IP not auto-detected)."
  fi
}

main "$@"
SH
chmod +x /root/routersetup.sh
ash -n /root/routersetup.sh   # syntax check (no output if OK)
sh /root/routersetup.sh
