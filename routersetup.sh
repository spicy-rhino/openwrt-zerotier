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

  # --- Option 1: Simple USB (eth1) -> WWAN failover via mwan3 ---

# 1) Install packages (LuCI app optional)
opkg update
opkg install mwan3 || true
opkg install luci-app-mwan3 || true

# 2) Ensure firewall 'wan' zone exists and includes interfaces
if ! uci -q get firewall.zone_wan.name >/dev/null; then
  uci add firewall zone
  uci set firewall.@zone[-1].name='wan'
  uci set firewall.@zone[-1].input='REJECT'
  uci set firewall.@zone[-1].forward='REJECT'
  uci set firewall.@zone[-1].output='ACCEPT'
  uci add_list firewall.@zone[-1].network='wan'
fi

# 3) Create a dedicated USB WAN on eth1 (DHCP). Harmless if eth1 not present yet.
if ! uci -q get network.wan_usb1 >/dev/null; then
  uci add network interface
  uci rename network.@interface[-1]='wan_usb1'
fi
uci set network.wan_usb1.proto='dhcp'
uci set network.wan_usb1.device='eth1'
uci set network.wan_usb1.peerdns='1'
uci set network.wan_usb1.defaultroute='1'
uci set network.wan_usb1.metric='10'
uci set network.wan_usb1.hostname='openwrt'

# Prefer USB over WWAN by metric (WWAN only if present)
if uci -q show network.wwan >/dev/null 2>&1; then
  uci set network.wwan.metric='100'
fi

# Put both into firewall wan zone (idempotent add_list)
uci add_list firewall.zone_wan.network='wan_usb1'
uci -q show network.wwan >/dev/null 2>&1 && uci add_list firewall.zone_wan.network='wwan'

uci commit network
uci commit firewall
service firewall reload || /etc/init.d/firewall reload || true

# 4) Minimal /etc/config/mwan3 for USB->WWAN failover
#    Writes once; later runs just update values.
if [ ! -s /etc/config/mwan3 ]; then
  cat >/etc/config/mwan3 <<'EOF'
config globals 'globals'
        option mmx_mask '0x3F00'
        option flush_conntrack_on_policy_switch '1'

config interface 'wan_usb1'
        option enabled '1'
        option family 'ipv4'
        list track_ip '1.1.1.1'
        list track_ip '8.8.8.8'
        option reliability '1'
        option interval '5'
        option down '3'
        option up '2'
        option initial_state 'online'
        option timeout '2'
        option failure_interval '5'
        option recovery_interval '5'

config interface 'wwan'
        option enabled '1'
        option family 'ipv4'
        list track_ip '1.1.1.1'
        list track_ip '8.8.4.4'
        option reliability '1'
        option interval '5'
        option down '3'
        option up '2'
        option initial_state 'online'
        option timeout '2'
        option failure_interval '5'
        option recovery_interval '5'

config member 'm_wan_usb1'
        option interface 'wan_usb1'
        option metric '10'
        option weight '1'

config member 'm_wwan'
        option interface 'wwan'
        option metric '20'
        option weight '1'

config policy 'usb_primary'
        list use_member 'm_wan_usb1'
        list use_member 'm_wwan'

config rule 'default_rule'
        option dest_ip '0.0.0.0/0'
        option proto 'all'
        option use_policy 'usb_primary'
EOF
else
  # Ensure the two interfaces exist/enabled in mwan3 if file already present
  uci -q set mwan3.globals.flush_conntrack_on_policy_switch='1'
  # wan_usb1 block
  uci -q show mwan3.wan_usb1 >/dev/null || uci add mwan3 interface && uci rename mwan3.@interface[-1]='wan_usb1'
  uci set mwan3.wan_usb1.enabled='1'
  uci set mwan3.wan_usb1.family='ipv4'
  uci -q delete mwan3.wan_usb1.track_ip
  uci add_list mwan3.wan_usb1.track_ip='1.1.1.1'
  uci add_list mwan3.wan_usb1.track_ip='8.8.8.8'
  uci set mwan3.wan_usb1.reliability='1'
  uci set mwan3.wan_usb1.interval='5'
  uci set mwan3.wan_usb1.down='3'
  uci set mwan3.wan_usb1.up='2'
  uci set mwan3.wan_usb1.initial_state='online'
  uci set mwan3.wan_usb1.timeout='2'
  uci set mwan3.wan_usb1.failure_interval='5'
  uci set mwan3.wan_usb1.recovery_interval='5'

  # wwan block (only if you actually have it)
  if uci -q show network.wwan >/dev/null 2>&1; then
    uci -q show mwan3.wwan >/dev/null || uci add mwan3 interface && uci rename mwan3.@interface[-1]='wwan'
    uci set mwan3.wwan.enabled='1'
    uci set mwan3.wwan.family='ipv4'
    uci -q delete mwan3.wwan.track_ip
    uci add_list mwan3.wwan.track_ip='1.1.1.1'
    uci add_list mwan3.wwan.track_ip='8.8.4.4'
    uci set mwan3.wwan.reliability='1'
    uci set mwan3.wwan.interval='5'
    uci set mwan3.wwan.down='3'
    uci set mwan3.wwan.up='2'
    uci set mwan3.wwan.initial_state='online'
    uci set mwan3.wwan.timeout='2'
    uci set mwan3.wwan.failure_interval='5'
    uci set mwan3.wwan.recovery_interval='5'
  fi

  # Members/policy/rule (create if missing)
  uci -q show mwan3.m_wan_usb1 >/dev/null || { uci add mwan3 member; uci rename mwan3.@member[-1]='m_wan_usb1'; }
  uci set mwan3.m_wan_usb1.interface='wan_usb1'
  uci set mwan3.m_wan_usb1.metric='10'
  uci set mwan3.m_wan_usb1.weight='1'

  if uci -q show network.wwan >/dev/null 2>&1; then
    uci -q show mwan3.m_wwan >/dev/null || { uci add mwan3 member; uci rename mwan3.@member[-1]='m_wwan'; }
    uci set mwan3.m_wwan.interface='wwan'
    uci set mwan3.m_wwan.metric='20'
    uci set mwan3.m_wwan.weight='1'
  fi

  uci -q show mwan3.usb_primary >/dev/null || { uci add mwan3 policy; uci rename mwan3.@policy[-1]='usb_primary'; }
  uci -q delete mwan3.usb_primary.use_member
  uci add_list mwan3.usb_primary.use_member='m_wan_usb1'
  uci -q show network.wwan >/dev/null 2>&1 && uci add_list mwan3.usb_primary.use_member='m_wwan'

  uci -q show mwan3.default_rule >/dev/null || { uci add mwan3 rule; uci rename mwan3.@rule[-1]='default_rule'; }
  uci set mwan3.default_rule.dest_ip='0.0.0.0/0'
  uci set mwan3.default_rule.proto='all'
  uci set mwan3.default_rule.use_policy='usb_primary'

  uci commit mwan3
fi

uci commit mwan3

# 5) Enable & start
/etc/init.d/mwan3 enable
/etc/init.d/mwan3 restart || true

# (Optional) bounce network so DHCP runs on wan_usb1 if NIC is present
/etc/init.d/network restart || true

# Debug hints:
echo "mwan3 status:"
mwan3 status 2>/dev/null || true
 
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
