#!/usr/bin/env bash
#
# Put a proxy on WiFi back on its network after NetworkManager gave up.
#
# On a headless Pi, NetworkManager treats a disconnect during the WPA key
# exchange as a wrong password, asks for a new one, finds nobody to ask
# ("no secrets: No agents were available") and stops connecting to that
# network until someone intervenes. A router hiccup is enough. carelink-piet
# sat offline for 10 hours on 2026-11-01 after its router steered it to a
# radio with an inconsistent WPA2/WPA3 announcement, with the working radio
# and a correct profile right there.
#
# Run every 2 minutes by carelink-wifi-watchdog.timer. Does nothing while
# the Pi is on Ethernet, already on WiFi, showing its setup hotspot, or has
# no saved WiFi network. Otherwise it brings the saved networks up by hand,
# most recently used first, which works where NetworkManager's own retry
# has been switched off.
set -uo pipefail

IFACE="${IFACE:-wlan0}"
AP_CON="carelink-setup-ap"
IGNORE_ETHERNET="${IGNORE_ETHERNET:-0}"   # 1 = act even on Ethernet (testing)

log() { echo "wifi-watchdog: $*"; }

devs="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null)"

if [[ "$IGNORE_ETHERNET" != 1 ]] && awk -F: '$2=="ethernet" && $3=="connected" {f=1} END {exit !f}' <<<"$devs"; then
  exit 0                                   # on the cable: WiFi is not needed
fi
wifi_line="$(awk -F: -v d="$IFACE" '$1==d' <<<"$devs")"
[[ -n "$wifi_line" ]] || exit 0            # no WiFi device
IFS=: read -r _ _ state con <<<"$wifi_line"
[[ "$con" == "$AP_CON" ]] && exit 0         # the setup hotspot is up
[[ "$state" == "connected" || "$state" == connecting* ]] && exit 0

# Saved WiFi networks, most recently used first; the hotspot is not one.
mapfile -t profiles < <(nmcli -t -f TIMESTAMP,TYPE,NAME con show 2>/dev/null |
  awk -F: -v ap="$AP_CON" '$2=="802-11-wireless" && $3!=ap {print $1":"$3}' |
  sort -t: -k1,1nr | cut -d: -f2-)
[[ ${#profiles[@]} -gt 0 ]] || exit 0

log "$IFACE is $state with no network; trying ${profiles[*]}"
nmcli radio wifi on
nmcli dev wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true
sleep 3
for p in "${profiles[@]}"; do
  if nmcli --wait 45 con up "$p" ifname "$IFACE" >/dev/null 2>&1; then
    log "back on '$p'"
    exit 0
  fi
  log "could not bring up '$p'"
done
exit 0
