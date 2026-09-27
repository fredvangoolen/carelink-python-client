# CareLink proxy appliance

Turns a Raspberry Pi into a CareLink proxy that a household can keep running
themselves. The hard part is not serving the data — it is what happens when
the CareLink session finally expires, because recovering it needs a browser,
a login and a CAPTCHA, and the household has no browser on the Pi and no
business using a terminal.

So the Pi grows a browser only when it needs one. A virtual display, a window
manager and Firefox are started on demand, shared read-write over noVNC, and
torn down the moment a token has been captured. A household member opens a
link, sees the real CareLink login page, solves the CAPTCHA, and the browser
disappears when it worked.

## Security model

The whole design is one claim: **nothing is listening unless a renewal is
actually in progress, and when it is, exactly one port is exposed.**

- `x11vnc` runs with `-localhost`, so it refuses anything but loopback.
  `websockify` is the only LAN-facing process. One point of exposure, not two.
- None of the four display units is enabled at boot. `renew.sh` starts them
  and its `EXIT` trap stops them, including when it fails or is interrupted.
- The token lives at `/var/lib/carelink/logindata.json`, `root:root 0600`.
  The renewal runs in a fresh `mktemp` directory that is shredded afterwards.
- `provision.sh` never generates, stores or prints the VNC password.

Verify the claim at any time:

```bash
ss -tlnp | grep -E ':6080|:5900'
```

Idle that prints nothing. Mid-renewal it must show **5900 on `127.0.0.1` only**
and 6080 on `0.0.0.0`. If 5900 shows `0.0.0.0`, `-localhost` did not take and
there are two exposed services instead of one.

Keep it LAN-only: do not forward 6080 or 5900 on the household router, and do
not put remote access in front of *this* service. It belongs in the same trust
boundary as the original CareLink login.

## Install

```bash
git clone <this repo> && cd carelink-python-client
./appliance/provision.sh
```

Idempotent — re-running is how you upgrade, and it converges an existing box
without touching an installed token.

Two steps are deliberately left to a human:

```bash
x11vnc -storepasswd ~/.vnc/passwd          # unique per household
sudo systemctl enable --now carelink2-proxy.service
```

The password is not automated because it should never pass through a script,
a log or a transcript. VNC auth truncates to 8 characters, so anything longer
is decoration; that is tolerable only because of how little is exposed and for
how short a time.

## Renewing a token

```bash
/opt/carelink-renewal/renew.sh
```

It prints the URL to hand to whoever is doing the login, waits up to 15
minutes (`DEADLINE_S`), validates the result, installs it and restarts the
proxy. Tell them three things, because all three look like faults and are not:

- a red **"Running without HTTPS"** banner is expected here (see below)
- the screen is **grey** until the browser appears
- the browser window **vanishes** when the login succeeds

That last one is the redirect: CareLink sends the browser to
`com.medtronic.carepartner:/sso?code=…`, the login script lifts the code out
of it and closes the browser immediately.

This is a rare path. The proxy refreshes the token on every poll and rotates
it as it goes, so a browser login is only needed once that chain breaks — the
Pi offline for more than about a week, or a server-side invalidation.

## Things that are not obvious

**The HTTPS warning does not apply.** noVNC prints it whenever the page is not
a secure context, without checking whether anything you use needs one. What
needs one is `ra2.js`/`aes.js`/`rsa.js` — the RSA-AES security types, which
call `crypto.subtle`. `x11vnc -rfbauth` offers **only** security type 2
(VncAuth/DES), noVNC's DES is pure JavaScript, and the only crypto on that
path is `crypto.getRandomValues`, which is *not* restricted to secure
contexts. noVNC also never calls `navigator.clipboard`. Serving this over a
self-signed certificate would replace a banner inside the page with a
full-page certificate interstitial shown to a non-technical person — strictly
worse. Explain it instead of hiding it.

**`selenium-wire` cannot simply be dropped.** The EU OAuth config sets
`redirect_uri = com.medtronic.carepartner:/sso`, a custom Android app scheme.
Firefox cannot navigate there, so the authorization code exists only inside a
302 the browser never follows, and no amount of `driver.current_url` polling
will find it. It has to be intercepted *below* the browser. That matters
because selenium-wire has been unmaintained since 2023 and is the main
dependability risk here; replacing it means replacing the interception (e.g.
Selenium BiDi network events), not just the driver.

**Three version pins are load-bearing**, each failing somewhere different on
Python 3.13: `setuptools<81` (newer drops `pkg_resources`, which
selenium-wire's bundled mitmproxy imports), `pyOpenSSL==24.0.0` (26 removed
`X509.get_extension()`, called when it mints its CA), `selenium==4.35.0`.

**Selenium Manager has no `linux/aarch64` build.** It raises
`Unsupported platform/architecture combination` before it even looks at PATH,
so geckodriver is installed by hand and `renew_login.py` names both binaries
explicitly. Pre-installing is right for an appliance anyway — no download at
the moment someone is waiting to log in.

**The login script does not exit when it succeeds.** selenium-wire's proxy
thread is non-daemon, so the process lingers holding a mitm proxy open.
`renew.sh` therefore waits on the *token file*, not on the process, and reaps
it either way.

**A stale `logindata.json` in the working directory makes it do nothing.** It
prints "token data file already exists" and exits — no renewal, no error, no
clue. `renew.sh` uses a fresh `mktemp` directory so that cannot happen.

**One account carries one live session.** A fresh browser login invalidates
every other machine holding a session for that CareLink account, so never
renew on a spare while a live set is running. Move the token instead.

The trap is that it does not look that way. Checked minutes after a login,
the old machine still serves data and the sessions appear to coexist - it is
simply running on an access token that has not expired yet. Hours later its
first `_do_refresh()` fails with `ERROR: failed to refresh token` and every
display goes blank at once. Observed exactly that, ten hours apart, on
2026-09-27. The proof that a move worked is the first successful REFRESH in
the journal, not the first successful fetch.

## Files

| | |
|---|---|
| `provision.sh` | idempotent installer |
| `renew.sh` | one renewal, start to finish, with teardown on every exit path |
| `renew_login.py` | runs the project login script on a board where Selenium cannot find its own binaries |
| `systemd/*.service` | the four display units, templated |

## Not done yet

`renew.sh` is triggered over SSH. The natural next step is the proxy's own
status page: it already detects the dead token (`STATUS_NEED_TKN`), already
serves a recovery form, and already waits on a flag that `save_params()`
clears — so a "renew now" button there is a small change, not a feature.
That page is also the right place to tell the household what to expect,
rather than suppressing the HTTPS banner.
