#!/usr/bin/env python3
#
# The one page the fallback setup hotspot serves: pick or type a WiFi
# network, give its password, and the Pi joins it. Nothing else - the
# hotspot exists to get the Pi onto a network, not to configure it.
#
# Runs as root under carelink-setup-ap.sh, bound to the hotspot's address
# only. Every page answers any path, which together with the catch-all DNS
# entry makes phones open it by themselves (a captive portal).
#
# Exit 0 = joined a network, 1 = deadline passed.

import argparse, html, re, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

ap = argparse.ArgumentParser()
ap.add_argument("--addr", required=True)
ap.add_argument("--con", required=True)
ap.add_argument("--iface", required=True)
ap.add_argument("--scan", required=True)
ap.add_argument("--deadline", type=int, required=True)
args = ap.parse_args()

deadline = time.time() + args.deadline
state = {"joined": False, "busy": False, "error": ""}

def scanned():
    # nmcli -t escapes ':' inside fields as '\:'
    nets = {}
    try:
        for line in open(args.scan, encoding="utf-8", errors="replace"):
            f = [p.replace("\\:", ":") for p in re.split(r"(?<!\\):", line.rstrip("\n"))]
            if len(f) >= 3 and f[0]:
                sig = int(f[1]) if f[1].isdigit() else 0
                nets[f[0]] = max(sig, nets.get(f[0], 0))
    except OSError:
        pass
    return sorted(nets.items(), key=lambda kv: -kv[1])

PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CareLink proxy WiFi</title>
<style>body{{font-family:sans-serif;max-width:28em;margin:1em auto;padding:0 1em}}
label{{display:block;margin-top:1em}}select,input{{width:100%;font-size:1.1em;padding:.3em}}
button{{margin-top:1.2em;font-size:1.1em;padding:.5em 1em}}.err{{color:#b00}}</style></head>
<body><h2>Connect this proxy to WiFi</h2>{error}
<form method="post" action="/join">
<label>Network<select name="ssid">{options}<option value="">(other, type below)</option></select></label>
<label>Other network name<input name="ssid_manual" autocomplete="off"></label>
<label>Password<input name="password" type="password" autocomplete="off"></label>
<button type="submit">Connect</button></form>
<p>This setup network closes by itself within {left} minutes.</p></body></html>"""

DONE = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Connecting</title></head>
<body style="font-family:sans-serif;max-width:28em;margin:1em auto;padding:0 1em">
<h2>Connecting to {ssid}</h2><p>This setup network disappears now. If the proxy cannot join,
it comes back within a minute with the reason.</p></body></html>"""

def nmcli(*a, timeout=60):
    return subprocess.run(["nmcli", *a], capture_output=True, text=True, timeout=timeout)

def join(ssid, password):
    try:
        nmcli("con", "down", args.con)
        cmd = ["dev", "wifi", "connect", ssid, "ifname", args.iface]
        if password:
            cmd += ["password", password]
        r = nmcli(*cmd, timeout=60)
        if r.returncode == 0:
            print("joined %r" % ssid, flush=True)
            state["joined"] = True
            return
        state["error"] = "Could not join %s: %s" % (ssid, (r.stderr or r.stdout).strip()[:200])
        print(state["error"], flush=True)
    except subprocess.TimeoutExpired:
        state["error"] = "Joining %s timed out." % ssid
    finally:
        if not state["joined"]:
            nmcli("con", "up", args.con)
        state["busy"] = False

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass

    def reply(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        opts = "".join('<option value="%s">%s (%d%%)</option>' % (html.escape(s, True), html.escape(s), sig)
                       for s, sig in scanned())
        err = '<p class="err">%s</p>' % html.escape(state["error"]) if state["error"] else ""
        left = max(1, int((deadline - time.time()) // 60) + 1)
        self.reply(PAGE.format(options=opts, error=err, left=left))

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0 or n > 2048:
            return self.reply("Bad request", 400)
        q = parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        ssid = (q.get("ssid_manual", [""])[0].strip() or q.get("ssid", [""])[0].strip())
        password = q.get("password", [""])[0]
        if not (1 <= len(ssid.encode()) <= 32) or not (password == "" or 8 <= len(password) <= 63):
            state["error"] = "Network name needs 1-32 characters, a password 8-63."
            return self.do_GET()
        if state["busy"]:
            return self.do_GET()
        state["busy"], state["error"] = True, ""
        self.reply(DONE.format(ssid=html.escape(ssid)))
        # After the reply: taking the hotspot down cuts this very connection.
        threading.Timer(2.0, join, (ssid, password)).start()

srv = HTTPServer((args.addr, 80), Handler)
srv.timeout = 1
while time.time() < deadline and not state["joined"]:
    srv.handle_request()
while state["busy"]:        # a join started just before the deadline
    time.sleep(1)
srv.server_close()
sys.exit(0 if state["joined"] else 1)
