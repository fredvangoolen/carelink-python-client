#!/usr/bin/env bash
#
# Fallback setup hotspot: lets a phone give this Pi a WiFi network when it
# has none - a proxy taken somewhere with WiFi only.
#
# Runs once at boot. If the Pi gets a network within WAIT_S (Ethernet or a
# known WiFi), it exits and nothing is ever broadcast. Otherwise it raises a
# WPA2 hotspot with this Pi's own password (printed as a QR label at
# staging), serves one page that takes a WiFi name and password, and stops
# after AP_S - or as soon as the Pi has joined the new network.
#
# The hotspot is a door through the "household LAN is trusted" boundary, so
# it is kept small: only when there is no network, only for minutes, unique
# password, and while it is up its clients can reach the setup page and
# nothing else on the Pi (nftables table carelink_setup_ap).
set -uo pipefail

WAIT_S="${WAIT_S:-90}"         # how long to wait for a network after boot
AP_S="${AP_S:-300}"            # how long the hotspot stays up
FORCE="${FORCE:-0}"            # 1 = raise it even with a network (testing)
IFACE="${IFACE:-wlan0}"
CON="carelink-setup-ap"
AP_ADDR="10.42.0.1"
STATE_DIR="/run/carelink-setup-ap"
SERVER="/opt/carelink-setup-ap/setup_ap_server.py"

log() { echo "setup-ap: $*"; }

connected() {
  # Any Ethernet or WiFi device NetworkManager calls connected - except our
  # own hotspot, which also reads "connected".
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null |
    awk -F: -v con="$CON" '($2=="ethernet"||$2=="wifi") && $3=="connected" && $4!=con {f=1} END {exit !f}'
}

teardown() {
  nmcli con down "$CON" >/dev/null 2>&1
  nft delete table inet carelink_setup_ap 2>/dev/null
  rm -rf "$STATE_DIR"
}
trap teardown EXIT INT TERM

if [[ "$FORCE" != 1 ]]; then
  for ((i = 0; i < WAIT_S; i += 5)); do
    if connected; then log "network present, no hotspot"; exit 0; fi
    sleep 5
  done
  connected && { log "network present, no hotspot"; exit 0; }
fi

nmcli con show "$CON" >/dev/null 2>&1 || { log "ERROR: no $CON profile - run provision.sh"; exit 1; }
nmcli radio wifi on

# Scan BEFORE the hotspot is up: one radio cannot list networks while it is
# an access point, and the page offers what was found.
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list ifname "$IFACE" --rescan yes \
  2>/dev/null > "$STATE_DIR/scan" || true

# Isolation, in place before the hotspot accepts anyone: from the hotspot,
# DHCP, DNS (for the captive portal) and the setup page only; nothing is
# forwarded onward.
nft -f - <<NFT
table inet carelink_setup_ap {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "$IFACE" udp dport { 53, 67 } accept
    iifname "$IFACE" tcp dport { 53, 80 } accept
    iifname "$IFACE" ip protocol icmp accept
    iifname "$IFACE" drop
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "$IFACE" drop
    oifname "$IFACE" drop
  }
}
NFT

if ! nmcli con up "$CON" >/dev/null; then log "ERROR: hotspot did not come up"; exit 1; fi
log "hotspot $(nmcli -g 802-11-wireless.ssid con show "$CON") up for ${AP_S}s"

python3 "$SERVER" --addr "$AP_ADDR" --con "$CON" --iface "$IFACE" \
  --scan "$STATE_DIR/scan" --deadline "$AP_S"
rc=$?
[[ $rc == 0 ]] && log "joined a WiFi network, hotspot closed" || log "hotspot closed (timeout)"
exit 0
