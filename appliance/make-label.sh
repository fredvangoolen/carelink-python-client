#!/usr/bin/env bash
#
# Make the setup-hotspot label for a staged proxy, on the staging laptop.
#
#   appliance/make-label.sh <user@>carelink-<name>.local [--text]
#
# Reads the hotspot name and this Pi's password over SSH and writes
# <host>-setup-ap-label.png here: a WiFi QR code a phone camera joins by
# scanning. --text also prints the password, to write under the QR code for
# a laptop that cannot scan. Print the label, stick it on the Pi, then delete
# the PNG: it is the password.
set -euo pipefail

[[ $# -ge 1 ]] || { sed -n '4,11p' "$0"; exit 1; }
target="$1"; show_text="${2:-}"
# qrencode if it is installed, otherwise segno (pure Python, no image
# library) through uv - nothing gets installed into the system either way.
if command -v qrencode >/dev/null; then qr=qrencode
elif command -v uv >/dev/null; then qr=segno
else echo "Needs qrencode (sudo apt install qrencode) or uv on this machine"; exit 1
fi

# One SSH call, password on stdout only, never on a command line.
read -r name psk < <(ssh -o BatchMode=yes "$target" 'printf "%s " "$(hostname)"; sudo cat /etc/carelink/setup-ap.psk')
[[ -n "${psk:-}" ]] || { echo "No setup-hotspot password on $target - run provision.sh there first"; exit 1; }
ssid="${name}-setup"
out="${name}-setup-ap-label.png"

payload="WIFI:T:WPA;S:${ssid};P:${psk};;"
if [[ $qr == qrencode ]]; then
  qrencode -o "$out" -s 8 -m 2 "$payload"
else
  # Payload through the environment, not argv.
  QR_PAYLOAD="$payload" QR_OUT="$out" uv run --quiet --no-project --with segno python3 - <<'PY'
import os, segno
segno.make(os.environ["QR_PAYLOAD"], error="m").save(os.environ["QR_OUT"], scale=8, border=2)
PY
fi
chmod 600 "$out"
echo "Label: $out (network ${ssid})"
[[ "$show_text" == "--text" ]] && echo "Password: ${psk}"
echo "Print it, stick it on the Pi, then delete $out."
