#!/usr/bin/env bash
#
# Drive one CareLink token renewal from start to finish.
#
#   1. bring up the virtual display + VNC chain
#   2. run the browser login in a clean working directory
#   3. install the resulting token for the proxy, root-owned, 0600
#   4. tear everything down again and destroy every other copy
#
# A household member does nothing but open the printed URL and solve the
# CAPTCHA. Everything else, including making sure the listener does not
# outlive the renewal, happens here.
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/carelink-renewal}"
TOKEN_FILE="${TOKEN_FILE:-/var/lib/carelink/logindata.json}"
PROXY_SERVICE="${PROXY_SERVICE:-carelink2-proxy.service}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
DEADLINE_S="${DEADLINE_S:-900}"          # 15 min for someone to find the link and log in
EXTRA_ARGS="${EXTRA_ARGS:-}"             # e.g. --us for a US account

WORKDIR=""
LOGIN_PID=""
STARTED_CHAIN=0

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# A pid and all its descendants, deepest first. Killing the parent alone is
# not enough: geckodriver is its child and Firefox is geckodriver's, and
# because the login is killed rather than allowed to call driver.quit(),
# both get reparented to init and survive - one leaked browser per failed
# renewal, still holding a display that no longer exists.
descendants() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    descendants "$child"
  done
  printf '%s\n' "$pid"
}

cleanup() {
  local rc=$?
  # Order matters: kill the login first so it cannot write into a directory
  # that is about to be shredded.
  if [[ -n "$LOGIN_PID" ]] && kill -0 "$LOGIN_PID" 2>/dev/null; then
    # It does NOT exit on success either: selenium-wire's proxy thread is
    # non-daemon, so the process lingers holding a mitm proxy open. Reaping
    # it is not optional.
    log "stopping login process tree $LOGIN_PID"
    mapfile -t tree < <(descendants "$LOGIN_PID")
    kill -TERM "${tree[@]}" 2>/dev/null
    sleep 3
    kill -KILL "${tree[@]}" 2>/dev/null
  fi
  # Safety net for a tree that was already broken when we got here. This is a
  # single-purpose appliance: the only browser on it is the one we start.
  if pgrep -u "$(id -u)" -x geckodriver >/dev/null 2>&1 || pgrep -u "$(id -u)" -x firefox-esr >/dev/null 2>&1; then
    log "cleaning up orphaned browser processes"
    pkill -u "$(id -u)" -x geckodriver 2>/dev/null
    pkill -u "$(id -u)" -x firefox-esr 2>/dev/null
    sleep 2
    pkill -9 -u "$(id -u)" -x firefox-esr 2>/dev/null
  fi
  if [[ $STARTED_CHAIN -eq 1 ]]; then
    log "stopping display chain"
    sudo systemctl stop xvfb.service 2>/dev/null   # PartOf drops all four
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    # The working copy of the token, plus anything else left behind.
    find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null
    rmdir "$WORKDIR" 2>/dev/null
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

[[ -f "$INSTALL_DIR/carelink_carepartner_api_login.py" ]] || {
  log "ERROR: $INSTALL_DIR is not provisioned - run provision.sh first"; exit 1; }

# A stale token in the working directory makes the login script print
# "token data file already exists" and do nothing at all - no renewal, no
# error, no clue. A fresh mktemp dir makes that impossible by construction.
WORKDIR="$(mktemp -d /tmp/carelink-renew.XXXXXX)"
chmod 700 "$WORKDIR"

log "starting display chain"
sudo systemctl start novnc.service || { log "ERROR: could not start the chain"; exit 1; }
STARTED_CHAIN=1
sleep 2

HOSTNAME_FQDN="$(hostname).local"
cat <<BANNER

  ------------------------------------------------------------------
   Open this on a phone or laptop on the SAME home network:

       http://${HOSTNAME_FQDN}:${NOVNC_PORT}/vnc.html

   Enter the VNC password, then sign in to CareLink and solve the
   CAPTCHA. Notes for whoever is doing it:
     - a red "without HTTPS" warning is expected and harmless here
     - the screen is grey until the browser appears; give it a moment
     - when the sign-in succeeds the browser window VANISHES.
       That is the success signal, not a crash.
  ------------------------------------------------------------------

BANNER

log "launching browser login (deadline ${DEADLINE_S}s)"
( cd "$WORKDIR" && exec "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/renew_login.py" $EXTRA_ARGS ) \
  >"$WORKDIR/login.log" 2>&1 &
LOGIN_PID=$!

# Wait on the TOKEN FILE, not on the process: on success the process stays
# alive, and on failure it dies. Both have to end the wait.
deadline=$(( SECONDS + DEADLINE_S ))
while (( SECONDS < deadline )); do
  if [[ -s "$WORKDIR/logindata.json" ]]; then
    sleep 1                                   # let write_datafile finish
    log "token written"
    break
  fi
  if ! kill -0 "$LOGIN_PID" 2>/dev/null; then
    log "ERROR: login exited without producing a token"
    grep -viE "pkg_resources|UserWarning" "$WORKDIR/login.log" | tail -15
    exit 1
  fi
  sleep 2
done

[[ -s "$WORKDIR/logindata.json" ]] || { log "ERROR: timed out after ${DEADLINE_S}s"; exit 1; }

# Validate before installing: replacing a working token with a malformed one
# would take the monitor down until somebody noticed.
python3 - "$WORKDIR/logindata.json" <<'PY' || exit 1
import json, sys
required = ["access_token", "refresh_token", "scope", "client_id"]
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("ERROR: token file is not valid json: %s" % e); sys.exit(1)
missing = [f for f in required if f not in d]
if missing:
    print("ERROR: token file is missing %s" % ", ".join(missing)); sys.exit(1)
print("token looks well formed (%d fields)" % len(d))
PY

log "installing token to $TOKEN_FILE"
sudo install -D -m 0600 -o root -g root "$WORKDIR/logindata.json" "$TOKEN_FILE"

if systemctl list-unit-files "$PROXY_SERVICE" >/dev/null 2>&1 \
   && systemctl is-enabled "$PROXY_SERVICE" >/dev/null 2>&1; then
  log "restarting $PROXY_SERVICE"
  sudo systemctl restart "$PROXY_SERVICE"
  sleep 5
  systemctl is-active "$PROXY_SERVICE" >/dev/null \
    && log "proxy is active" || log "WARNING: proxy did not come back - check journalctl"
else
  log "$PROXY_SERVICE not enabled here; token installed but proxy not started"
fi

log "renewal complete"
