#!/usr/bin/env bash
#
# Plan B for the display: a private hotspot, carelink-travel, that the Pi
# runs next to its own WiFi connection.
#
# The display (an M5Stack Core Ink) normally reaches the proxy over the
# household network - plan A. Some networks never let it: a holiday-house
# router may keep its clients apart, or the display may not know that WiFi.
# The display then falls back to this hotspot, which is always there wherever
# the Pi is, and returns to plan A once that works again.
#
# The Pi's radio (brcmfmac, Pi 4) allows one station plus one access point,
# but on ONE channel: `iw list` says "#{ managed } <= 1, #{ AP } <= 1,
# #channels <= 1". And the display is 2.4 GHz only. So the hotspot follows the
# channel of the Pi's own WiFi connection, and that connection is moved to
# 2.4 GHz if it is on 5 GHz. Measured 2026-11-02 at a holiday house: the
# router offered the same network on 5 GHz channel 44 and 2.4 GHz channel 1;
# pinned to 2.4 GHz the Pi kept its internet, and both ran on channel 1.
#
# Run every minute by carelink-travel-ap.timer; idempotent. It stands aside
# while the setup hotspot runs (the radio has room for one access point),
# and while the Pi's WiFi is looking for a network, so as not to pin the
# channel under it.
set -uo pipefail

STA="${STA:-wlan0}"
AP_IF="${AP_IF:-uap0}"
CON="carelink-travel"
SETUP_UNIT="carelink-setup-ap.service"
IDLE_CHANNEL="${IDLE_CHANNEL:-1}"   # when the Pi is on Ethernet and WiFi is unused
STATE_DIR="/run/carelink-travel-ap"

log() { echo "travel-ap: $*"; }

ap_down() {
  if nmcli -t -f NAME con show --active 2>/dev/null | grep -qx "$CON"; then
    nmcli con down "$CON" >/dev/null 2>&1
    log "hotspot down: $*"
  fi
}

nmcli con show "$CON" >/dev/null 2>&1 || { log "ERROR: no $CON profile - run provision.sh"; exit 1; }
mkdir -p "$STATE_DIR"

# The setup hotspot is active from boot until it decides (90 s) and while it
# is up. It needs the radio's one access point.
if systemctl is-active --quiet "$SETUP_UNIT"; then
  ap_down "the setup hotspot has the radio"
  exit 0
fi

# "channel 1 (2412 MHz)" -> "1 2412"
sta_channel() {
  iw dev "$STA" info 2>/dev/null | sed -n 's/.*channel \([0-9]*\) (\([0-9]*\) MHz.*/\1 \2/p' | head -1
}

devs="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null)"
sta_line="$(awk -F: -v d="$STA" '$1==d' <<<"$devs")"
IFS=: read -r _ _ sta_state sta_con <<<"$sta_line"
on_ethernet=0
awk -F: '$2=="ethernet" && $3=="connected" {f=1} END {exit !f}' <<<"$devs" && on_ethernet=1

if [[ "$sta_state" == "connected" ]]; then
  read -r ch freq <<<"$(sta_channel)"
  if [[ -n "${freq:-}" && "$freq" -gt 3000 ]]; then
    # 5 GHz. Try the same network on 2.4 GHz - once per boot per network, so
    # a network with no 2.4 GHz radio is not disturbed every minute.
    tried="$STATE_DIR/tried-24-$(printf '%s' "$sta_con" | md5sum | cut -c1-12)"
    if [[ -e "$tried" ]]; then
      ap_down "'$sta_con' is 5 GHz only here"
      exit 0
    fi
    touch "$tried"
    log "'$sta_con' is on 5 GHz; moving it to 2.4 GHz for the hotspot"
    nmcli con modify "$sta_con" 802-11-wireless.band bg
    if ! nmcli --wait 45 con up "$sta_con" ifname "$STA" >/dev/null 2>&1; then
      log "'$sta_con' has no 2.4 GHz radio here; back to 5 GHz, no hotspot"
      nmcli con modify "$sta_con" 802-11-wireless.band ""
      nmcli --wait 45 con up "$sta_con" ifname "$STA" >/dev/null 2>&1
      exit 0
    fi
    read -r ch freq <<<"$(sta_channel)"
  fi
  want="$ch"
elif [[ "$on_ethernet" == 1 && "$sta_state" != connecting* ]]; then
  want="$IDLE_CHANNEL"
else
  # No network, or WiFi busy finding one: no hotspot to pin its channel.
  ap_down "$STA is ${sta_state:-absent}"
  exit 0
fi
[[ -n "$want" ]] || { log "could not read $STA's channel"; exit 0; }

# The second interface. Gone after every reboot; NetworkManager manages it
# once it exists.
if ! iw dev "$AP_IF" info >/dev/null 2>&1; then
  iw dev "$STA" interface add "$AP_IF" type __ap || { log "ERROR: cannot add $AP_IF"; exit 1; }
  sleep 2
fi

# Isolation, in place before the hotspot accepts anyone: DHCP, mDNS (the
# display looks the proxy up as <host>.local) and the proxy only. No DNS -
# the setup hotspot's captive-portal rule in dnsmasq-shared.d would answer
# every name with 10.42.0.1 here too - and nothing forwarded: the hotspot is
# for the display, not a way onto the internet or this Pi.
nft -f - <<NFT
table inet carelink_travel_ap
flush table inet carelink_travel_ap
table inet carelink_travel_ap {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "$AP_IF" udp dport { 67, 5353 } accept
    iifname "$AP_IF" tcp dport 8081 accept
    iifname "$AP_IF" ip protocol icmp accept
    iifname "$AP_IF" drop
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "$AP_IF" drop
    oifname "$AP_IF" drop
  }
}
NFT

restart=0
if [[ "$(nmcli -g 802-11-wireless.channel con show "$CON")" != "$want" ]]; then
  nmcli con modify "$CON" 802-11-wireless.channel "$want"
  restart=1
fi
if ! nmcli -t -f NAME con show --active | grep -qx "$CON"; then
  restart=1
fi
if [[ "$restart" == 1 ]]; then
  if nmcli --wait 30 con up "$CON" ifname "$AP_IF" >/dev/null 2>&1; then
    log "hotspot up on channel $want"
  else
    log "ERROR: hotspot did not come up on channel $want"
  fi
fi
exit 0
