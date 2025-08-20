cat > /root/routersetup.sh <<'SH'
#!/bin/ash
# OpenWrt 24.10.0 (RPi5) — LuCI + extras + ZeroTier (ash-safe)

set -eu

PKGS_LUCI="luci luci-ssl luci-compat luci-app-opkg"
PKGS_ZT="zerotier"
PKGS_USB="kmod-rt2800-lib kmod-rt2800-usb kmod-rt2x00-lib kmod-rt2x00-usb \
kmod-usb-core kmod-usb-uhci kmod-usb-ohci kmod-usb2 usbutils nano \
kmod-usb-net-asix-ax88179 kmod-usb-net-cdc-ether kmod-usb-net-rndis"
PKGS="$PKGS_LUCI $PKGS_ZT $PKGS_USB"

ZTCLI="/usr/sbin/zerotier-cli"

log()  { printf '[+] %s\n' "$*"; }
err()  { printf '[!] %s\n' "$*" >&2; }

retry() { # retry <times> <cmd...>
  _tries="$1"; shift
  _n=1
  while :; do
    if "$@"; then return 0; fi
    [ "$_n" -ge "$_tries" ] && return 1
    _n=$((_n+1))
    sleep 2
  done
}

is_installed() { opkg list-installed | grep -q "^$1 -"; }

ensure_time_sync() {
  [ -x /etc/init.d/sysntpd ] && {
    /etc/init.d/sysntpd enable >/dev/null 2>&1 || true
    /etc/init.d/sysntpd start  >/dev/null 2>&1 || true
  }
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
    if ! read ZT_NETWORK_ID < /dev/tty; then
      err "No TTY available for input. Re-run from an interactive shell."
      exit 2
    fi
    # normalize (strip whitespace, lowercase A-F)
    ZT_NETWORK_ID="$(printf '%s' "$ZT_NETWORK_ID" | tr -d ' \t\r\n' | tr 'A-F' 'a-f')"

    case "$ZT_NETWORK_ID" in
      *[!0-9a-f]*|"")
        echo "Invalid network ID. Must be 16 hex chars (0-9, a-f). Try again." > /dev/tty
        ;;
      *)
        if [ ${#ZT_NETWORK_ID} -ne 16 ]; then
          echo "Invalid network ID. Must be exactly 16 characters. Try again." > /dev/tty
        else
          export ZT_NETWORK_ID
          break
        fi
        ;;
    esac
  done
}

ensure_zerotier_running() {
  [ -x "$ZTCLI" ] || { err "zerotier-cli not found at $ZTCLI"; return 1; }
  [ -x /etc/init.d/zerotier ] && {
    /etc/init.d/zerotier enable || true
    /etc/init.d/zerotier restart || /etc/init.d/zerotier start || true
  }
  retry 5 "$ZTCLI" info >/dev/null 2>&1 || {
    err "ZeroTier service not responding to 'zerotier-cli info'"
    return 1
  }
  return 0
}

join_zerotier() {
  log "Joining ZeroTier network: $ZT_NETWORK_ID"
  ensure_zerotier_running || { err "ZeroTier isn't running; cannot join."; return 1; }
  retry 3 "$ZTCLI" join "$ZT_NETWORK_ID" || { err "Failed to join $ZT_NETWORK_ID"; return 1; }

  # brief status info
  sleep 2
  $ZTCLI listnetworks | grep "$ZT_NETWORK_ID" || true
  echo
  echo "If the network requires controller authorization, approve this node in the ZeroTier web UI."
  echo "Leave later:  $ZTCLI leave $ZT_NETWORK_ID"
  echo
}

main() {
  log "Ensuring time sync..."
  ensure_time_sync

  log "Updating package lists..."
  retry 3 opkg update || { err "opkg update failed"; exit 1; }

  [ -f /var/lock/opkg.lock ] && { err "Another opkg process is running (opkg.lock present)."; exit 1; }

  for p in $PKGS; do
    if is_installed "$p"; then
      log "Package '$p' already installed; skipping."
    else
      log "Installing '$p'..."
      retry 3 opkg install "$p" || { err "Failed to install '$p'"; exit 1; }
    fi
  done

  # Web UI services
  [ -x /etc/init.d/uhttpd ] && { /etc/init.d/uhttpd enable || true; /etc/init.d/uhttpd restart || /etc/init.d/uhttpd start || true; }
  [ -x /etc/init.d/rpcd ]   && { /etc/init.d/rpcd   enable || true; /etc/init.d/rpcd   restart || /etc/init.d/rpcd   start || true; }

  # Prompt & join ZT
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
