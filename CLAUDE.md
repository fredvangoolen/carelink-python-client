# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Python client for Medtronic's (undocumented, reverse-engineered) CareLink Cloud API, used to pull pump/CGM data for a Minimed 770G/780G insulin pump. Three ways to use it, all built on the `carelink_client2.CareLinkClient` library class:

- `carelink_client2_cli.py` — one-shot/repeating CLI that downloads data to a file.
- `carelink_client2_proxy.py` — long-running daemon that polls CareLink and re-serves the data over a local REST API, so LAN devices don't each need their own CareLink login/session. **This is the proxy that [`~/m5-minimed-monitor`](../m5-minimed-monitor) polls** (`GET /carelink/nohistory`) to drive its display — if that project's display breaks because a field changed shape, this is the repo to check for the actual current response format, and changes here to the JSON output shape are a breaking change for that consumer.
- Import `carelink_client2` directly as a library in your own script.

`client1/` is an earlier, superseded implementation (pre-OAuth CareLink API) kept for reference — new work should go in the top-level `carelink_client2*` files, not `client1/`.

`doc/carelink.md` has reverse-engineered notes on the undocumented CareLink Cloud API itself (endpoints, OAuth flow, PATIENT vs CARE_PARTNER role differences) — read it before changing anything in `carelink_client2.py`'s auth/request logic, since that logic encodes non-obvious, hard-won findings about how CareLink's API actually behaves rather than anything documented upstream. `doc/carelink-data.ods` documents the JSON data format returned by the proxy.

**Ignore `README_FVG.md`** — despite the name it isn't real documentation, it's stray leftover text describing a patch to `carelink_client2_proxy.py` that was never actually made (working tree is clean, no matching diff exists). Don't treat its claims as current state.

## Running

```
pip3 install -r requirements.txt
```

Auth is bootstrapped once via a browser login (opens Firefox, needs a human to solve the CareLink login + reCAPTCHA), which writes `logindata.json`:
```
python3 carelink_carepartner_api_login.py   # add --us for a US CareLink account
```
`carelink_client2.CareLinkClient` reads that token file and refreshes it automatically thereafter (must be refreshed at least once a week or it expires and needs a fresh browser login).

CLI, one-shot or repeating:
```
python3 carelink_client2_cli.py --data          # -r/--repeat, -w/--wait (minutes) for repeated polling
```

Proxy daemon (what the M5/PC monitor talks to):
```
python3 carelink_client2_proxy.py -t logindata.json   # -w/--wait seconds between CareLink polls, default 300
```
Serves `GET /` (status), `GET /carelink` (full data + last 24h history), `GET /carelink/nohistory` (current data only) on port 8081. For production deployment there's a systemd unit at `systemd/carelink2-proxy.service` (double-check the hardcoded script/token-file paths in it before installing — they assume `/usr/local/carelink/` and `/var/lib/carelink/`).

There's no test suite, linter, or build step in this repo.

## Sensitive files — never commit

`logindata.json` (live CareLink OAuth session/tokens) and `data-*.json` (dumped patient pump/CGM data from `carelink_client2_cli.py --data`) are real patient data / live credentials, already covered by `.gitignore` — don't remove those entries or force-add matching files.

## Architecture notes

- Auth model differs by CareLink account role (`PATIENT`, `PATIENT_OUS`, or `CARE_PARTNER`) — a `CARE_PARTNER` account must additionally look up `blePereodicDataEndpoint` from `/patient/countries/settings` and POST `{username, role}` there, whereas a `PATIENT`/`PATIENT_OUS` account reads `/patient/connect/data` directly. See `doc/carelink.md` for the full discovered flow; get this wrong and you silently get no data rather than an auth error.
- The proxy's web GUI (served when the token is invalid/expired) exists to let you recover from an expired token without SSH/redeploying — check the relevant `do_GET`/`do_POST` handling in `carelink_client2_proxy.py` before assuming a token refresh requires a restart.
