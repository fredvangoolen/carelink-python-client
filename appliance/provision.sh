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
