#!/usr/bin/env bash
#
# Turn a stock Raspberry Pi OS Lite install into a CareLink proxy appliance
# with a browser-based token renewal path.
#
# Idempotent: safe to re-run, and re-running is how you upgrade. It never
# generates or handles the VNC password, and it never enables the display
# chain at boot - both are deliberate, see README.md.
set -euo pipefail

RENEW_USER="${RENEW_USER:-$(id -un)}"
INSTALL_DIR="${INSTALL_DIR:-/opt/carelink-renewal}"
PROXY_DIR="${PROXY_DIR:-/usr/local/carelink}"
TOKEN_DIR="${TOKEN_DIR:-/var/lib/carelink}"
DISPLAY_NUM="${DISPLAY_NUM:-:1}"
GEOMETRY="${GEOMETRY:-1280x800x24}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_WEB="${NOVNC_WEB:-/usr/share/novnc}"
GECKODRIVER_VERSION="${GECKODRIVER_VERSION:-v0.37.1}"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VNCPASSWD="/home/${RENEW_USER}/.vnc/passwd"
WIFI_COUNTRY="${WIFI_COUNTRY:-BE}"   # regulatory domain; the radio stays off without one
AP_DIR="/opt/carelink-setup-ap"
AP_PSK_FILE="/etc/carelink/setup-ap.psk"

say() { printf '\n== %s\n' "$*"; }

[[ $EUID -ne 0 ]] || { echo "Run as the ordinary user (it calls sudo itself), not as root."; exit 1; }
id "$RENEW_USER" >/dev/null || { echo "No such user: $RENEW_USER"; exit 1; }

say "packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xvfb openbox x11vnc firefox-esr novnc websockify python3-venv python3-pip

[[ -d "$NOVNC_WEB" ]] || { echo "noVNC web root $NOVNC_WEB missing - check the novnc package"; exit 1; }

say "geckodriver"
# Selenium Manager has no linux/aarch64 build, so the driver cannot be
# fetched on demand. Pre-installing it also means no download at the moment
# someone is waiting to log in.
if ! command -v geckodriver >/dev/null || ! geckodriver --version | grep -q "${GECKODRIVER_VERSION#v}"; then
  case "$(uname -m)" in
    aarch64) GD_ARCH=linux-aarch64 ;;
    armv7l)  GD_ARCH=linux32 ;;
    x86_64)  GD_ARCH=linux64 ;;
    *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
  esac
  TMP="$(mktemp -d)"
  curl -sfL -o "$TMP/gd.tar.gz" \
    "https://github.com/mozilla/geckodriver/releases/download/${GECKODRIVER_VERSION}/geckodriver-${GECKODRIVER_VERSION}-${GD_ARCH}.tar.gz"
  tar xzf "$TMP/gd.tar.gz" -C "$TMP"
  sudo install -m 0755 "$TMP/geckodriver" /usr/local/bin/geckodriver
  rm -rf "$TMP"
fi
geckodriver --version | head -1

say "python environment"
sudo install -d -o "$RENEW_USER" -g "$RENEW_USER" "$INSTALL_DIR"
[[ -d "$INSTALL_DIR/venv" ]] || python3 -m venv "$INSTALL_DIR/venv"
# These three pins are not cosmetic. selenium-wire has been unmaintained
# since 2023 and breaks in a different place without each one:
#   setuptools<81   - newer setuptools drops pkg_resources, which
#                     selenium-wire's bundled mitmproxy imports
#   pyOpenSSL 24    - 26 removed X509.get_extension(), called when it mints
#                     the CA it needs to see inside TLS
#   selenium 4.35   - upstream's tested pairing
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip wheel
"$INSTALL_DIR/venv/bin/pip" install -q \
    "setuptools<81" "selenium==4.35.0" "selenium-wire==5.1.0" \
    "pyOpenSSL==24.0.0" "cryptography==42.0.8" "blinker==1.7" \
    "curlify==2.2.1" requests
"$INSTALL_DIR/venv/bin/python" -c "from seleniumwire import webdriver" 2>/dev/null \
  && echo "selenium-wire imports cleanly" \
  || { echo "ERROR: selenium-wire will not import - the pins above need revisiting"; exit 1; }

say "application files"
install -m 0644 "$SRC/carelink_carepartner_api_login.py" "$INSTALL_DIR/"
install -m 0644 "$SRC/appliance/renew_login.py"          "$INSTALL_DIR/"
install -m 0755 "$SRC/appliance/renew.sh"                "$INSTALL_DIR/"
sudo install -d -m 0755 "$PROXY_DIR"
sudo install -m 0644 "$SRC/carelink_client2.py"       "$PROXY_DIR/"
sudo install -m 0644 "$SRC/carelink_client2_proxy.py" "$PROXY_DIR/"
sudo install -d -m 0700 "$TOKEN_DIR"
# Where the VNC password goes. x11vnc -storepasswd will not create the
# directory, and fails with "No such file or directory" on a fresh install.
sudo install -d -m 0700 -o "$RENEW_USER" -g "$RENEW_USER" "$(dirname "$VNCPASSWD")"

say "systemd units"
for unit in xvfb openbox-session x11vnc novnc; do
  sed -e "s|__USER__|${RENEW_USER}|g" \
      -e "s|__DISPLAY__|${DISPLAY_NUM}|g" \
      -e "s|__GEOMETRY__|${GEOMETRY}|g" \
      -e "s|__VNCPASSWD__|${VNCPASSWD}|g" \
      -e "s|__NOVNC_WEB__|${NOVNC_WEB}|g" \
      -e "s|__NOVNC_PORT__|${NOVNC_PORT}|g" \
      "$SRC/appliance/systemd/${unit}.service" | sudo tee "/etc/systemd/system/${unit}.service" >/dev/null
done
sudo install -m 0644 "$SRC/systemd/carelink2-proxy.service" /etc/systemd/system/
sudo systemctl daemon-reload
# On demand only. Nothing listens during the ~99.9% of the time when no
# renewal is happening, which is the entire security argument for this
# design; enabling them at boot throws it away.
sudo systemctl disable xvfb.service openbox-session.service x11vnc.service novnc.service >/dev/null 2>&1 || true

say "sudo rights for renewal"
# Narrow and explicit: bring the chain up, take it down, restart the proxy.
# Nothing else, and no password prompt, so a future proxy-triggered renewal
# needs no root daemon.
#
# Note what is NOT here: installing the token itself. That would need a rule
# with a wildcard source path running `install` as root, and a root-write
# rule whose source someone else can influence is exactly the kind of
# footgun this appliance exists to avoid. renew.sh uses ordinary sudo for
# that one step, which the operator running it already has.
sudo tee /etc/sudoers.d/carelink-renewal >/dev/null <<EOF
${RENEW_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start novnc.service
${RENEW_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop xvfb.service
${RENEW_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart carelink2-proxy.service
EOF
sudo chmod 0440 /etc/sudoers.d/carelink-renewal
sudo visudo -c -f /etc/sudoers.d/carelink-renewal

say "security updates"
# An appliance nobody logs into must patch itself. Without this package the
# apt timers only refresh lists: a box staged in September was found 149
# updates behind in October. Debian-Security is in the package defaults; the
# Raspberry Pi archive (kernel, firmware, rpi-connect) is not, so it is added.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unattended-upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo tee /etc/apt/apt.conf.d/52carelink-unattended >/dev/null <<'EOF'
// CareLink appliance: security updates daily, unattended.
// Debian-Security comes from 50unattended-upgrades; the Raspberry Pi archive
// (kernel, firmware, rpi-connect) is not in Debian's defaults, so add it.
Unattended-Upgrade::Origins-Pattern {
        "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
};
// Reboot only when an update needs it, and then by day: overnight is when
// the monitor matters most.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "14:00";
EOF

say "persistent journal"
# Raspberry Pi OS keeps the journal in RAM (40-rpi-volatile-storage.conf, to
# spare the SD card), so everything before a reboot is lost - including WHY
# it rebooted. carelink-piet restarted once with no trace of the cause. Keep
# it on disk, capped, so a mystery restart can be explained afterwards.
sudo install -d -m 0755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/50-carelink-persistent.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
EOF
sudo systemctl restart systemd-journald
sudo journalctl --flush

say "fallback setup hotspot"
# When the Pi boots with no network at all - taken somewhere with WiFi only -
# it raises a WPA2 hotspot for 5 minutes so a phone can give it one. Never
# while it has a network. See appliance/setup-ap/carelink-setup-ap.sh.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    dnsmasq-base nftables
command -v raspi-config >/dev/null && sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
sudo install -d -m 0755 "$AP_DIR"
sudo install -m 0755 "$SRC/appliance/setup-ap/carelink-setup-ap.sh" "$AP_DIR/"
sudo install -m 0644 "$SRC/appliance/setup-ap/setup_ap_server.py"   "$AP_DIR/"
sudo install -m 0644 "$SRC/appliance/systemd/carelink-setup-ap.service" /etc/systemd/system/
# Captive portal: on the hotspot every name resolves to the Pi, so a phone
# opens the setup page by itself. Applies to NetworkManager "shared"
# connections only, which on this box is the hotspot alone.
sudo install -d -m 0755 /etc/NetworkManager/dnsmasq-shared.d
echo "address=/#/10.42.0.1" | sudo tee /etc/NetworkManager/dnsmasq-shared.d/carelink-setup-ap.conf >/dev/null
# One password per Pi, made once and kept across re-runs: it is on the
# label, and a re-run must not invalidate the label.
AP_SSID="$(hostname)-setup"
if ! sudo test -s "$AP_PSK_FILE"; then
  sudo install -d -m 0700 "$(dirname "$AP_PSK_FILE")"
  python3 -c 'import secrets; a="abcdefghjkmnpqrstuvwxyz23456789"; print("".join(secrets.choice(a) for _ in range(12)))' \
    | sudo tee "$AP_PSK_FILE" >/dev/null
  sudo chmod 0600 "$AP_PSK_FILE"
fi
AP_PSK="$(sudo cat "$AP_PSK_FILE")"
sudo nmcli con delete carelink-setup-ap >/dev/null 2>&1 || true
sudo nmcli con add type wifi ifname wlan0 con-name carelink-setup-ap autoconnect no \
    ssid "$AP_SSID" mode ap 802-11-wireless.band bg ipv4.method shared ipv6.method disabled \
    wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
    wifi-sec.psk "$AP_PSK" >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable carelink-setup-ap.service >/dev/null 2>&1
unset AP_PSK
# The label is made on the staging laptop, not here: the Pi needs no QR
# tool, and no image of the password is left lying in a home directory.
echo "Setup hotspot: ${AP_SSID}. Make its label from your laptop:"
echo "    appliance/make-label.sh $(hostname).local"

say "done"
cat <<EOF

Provisioned for user '${RENEW_USER}'.

Two steps are deliberately left to you:

 1. Set the VNC password. It must be unique per household and it must not
    pass through any automation or log:

        x11vnc -storepasswd ${VNCPASSWD}

    (VNC auth truncates to 8 characters - more is decoration.)

 2. Install a CareLink token, either by copying one in or by running:

        ${INSTALL_DIR}/renew.sh

Then enable the proxy itself:

        sudo systemctl enable --now carelink2-proxy.service

Check what is exposed at any time with:

        ss -tlnp | grep -E ':${NOVNC_PORT}|:5900'

    Idle, that prints nothing. During a renewal it must show 5900 on
    127.0.0.1 ONLY, and ${NOVNC_PORT} on 0.0.0.0.
EOF
