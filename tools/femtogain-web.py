#!/usr/bin/env python3
"""femtogain-web — tiny web UI for the Femto Gain Controller Rev.2 IOC (stdlib only).

Serves one HTML page plus a JSON API.  Every action is delegated to
`femtogainctl`, so validation and behaviour are identical to the CLI.
Runs as root (netplan / hostname / systemd need it) under femtogain-web.service.

Config: iocBoot/iocfemtogain/web.conf   (WEB_PORT, WEB_PASSWORD, WEB_USER)
"""
import base64
import crypt
import hmac
import json
import os
import re
import subprocess
import spwd
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOP = "/usr/local/epics/iocs/femtogain"
BOOT = f"{TOP}/iocBoot/iocfemtogain"
IOC_CONF = f"{BOOT}/ioc.conf"
WEB_CONF = f"{BOOT}/web.conf"
HTML = f"{TOP}/tools/femtogain-web.html"
CTL = f"{TOP}/tools/femtogainctl"
CA_BIN = "/usr/local/epics/base/bin/linux-aarch64"
CA_ENV = dict(os.environ, EPICS_CA_ADDR_LIST="127.0.0.1", EPICS_CA_AUTO_ADDR_LIST="NO",
              PATH=f"{CA_BIN}:{os.environ.get('PATH', '')}")


def read_conf(path):
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return conf


def prefix():
    return read_conf(IOC_CONF).get("PREFIX", "GC01:")


def login_user():
    return read_conf(WEB_CONF).get("WEB_USER") or read_conf(IOC_CONF).get("DEFAULT_USER", "root")


def check_login(user, password):
    """Verify against /etc/shadow — the same password SSH uses."""
    try:
        h = spwd.getspnam(user).sp_pwdp
    except (KeyError, PermissionError):
        return False
    if not h or h[0] in "!*":
        return False
    try:
        return hmac.compare_digest(crypt.crypt(password, h), h)
    except Exception:  # noqa
        return False


def run(args, timeout=30):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as e:  # noqa
        return 1, str(e)


def ctl(*args, timeout=30):
    return run([CTL, *args], timeout=timeout)


def caget(*pvs):
    rc, out = run([f"{CA_BIN}/caget", "-t", "-w", "1", *pvs], timeout=5)
    vals = out.splitlines() if rc == 0 else []
    if len(vals) != len(pvs):
        return {pv: None for pv in pvs}
    return dict(zip(pvs, (v.strip() for v in vals)))


def service_active(name):
    return run(["systemctl", "is-active", name], timeout=5)[1]


def net_info():
    rc, out = ctl("ip", timeout=10)
    info = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k.strip()] = v.strip()
    return info


CH_DEFAULT = ("Io", "It", "If", "Ir")
CH_FIELDS = ("Gain", "Gain-RB", "Overload", "OverloadLatch", "OverloadCount")
_net_cache = {"t": 0.0, "v": {}}


def ch_names():
    c = read_conf(IOC_CONF)
    return [c.get(f"CH{i}_NAME") or CH_DEFAULT[i - 1] for i in (1, 2, 3, 4)]


def net_info_cached(max_age=5.0):
    """The page polls every second for overload; netplan is read less often."""
    now = time.monotonic()
    if now - _net_cache["t"] > max_age:
        _net_cache["v"], _net_cache["t"] = net_info(), now
    return _net_cache["v"]


def status():
    p = prefix()
    names = ch_names()
    svc = service_active("femtogain-ioc.service")
    pvs = [f"{p}Info:Heartbeat"]
    pvs += [f"{p}{n}{f}" for n in names for f in CH_FIELDS]
    v = caget(*pvs) if svc == "active" else {pv: None for pv in pvs}
    return {
        "hostname": os.uname().nodename,
        "prefix": p,
        "service": svc,
        "heartbeat": v[pvs[0]],
        "channels": [{"ch": i + 1, "name": n,
                      "gain": v[f"{p}{n}Gain"], "gain_rb": v[f"{p}{n}Gain-RB"],
                      "ovl": v[f"{p}{n}Overload"], "latch": v[f"{p}{n}OverloadLatch"],
                      "count": v[f"{p}{n}OverloadCount"]}
                     for i, n in enumerate(names)],
        "autosave": None, "autosave_boot": None,
        "net": net_info_cached(),
        "user": login_user(),
        "default_password": check_login(login_user(), read_conf(IOC_CONF).get("DEFAULT_PASSWORD", "femto")),
    }


IP_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")


class Handler(BaseHTTPRequestHandler):
    server_version = "femtogain-web/1.0"

    def log_message(self, fmt, *args):  # quieter journal
        if not self.path.startswith("/api/status"):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # ---- helpers
    def _auth_ok(self):
        hdr = self.headers.get("Authorization", "")
        if not hdr.startswith("Basic "):
            return False
        try:
            user, _, pw = base64.b64decode(hdr[6:]).decode().partition(":")
        except Exception:  # noqa
            return False
        return user == login_user() and check_login(user, pw)

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Femto Gain Controller"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa
            return {}

    # ---- GET
    def do_GET(self):
        if not self._auth_ok():
            return self._deny()
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            with open(HTML, "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if u.path == "/api/status":
            return self._send(200, status())
        if u.path == "/api/log":
            n = parse_qs(u.query).get("n", ["60"])[0]
            n = n if n.isdigit() and int(n) <= 500 else "60"
            rc, out = run(["tail", "-n", n, "/var/log/femtogain/ioc.log"], timeout=5)
            return self._send(200, {"log": out})
        if u.path == "/api/pvs":
            rc, out = ctl("pvs", timeout=5)
            return self._send(200, {"pvs": out.splitlines()})
        return self._send(404, {"error": "not found"})

    # ---- POST
    def do_POST(self):
        if not self._auth_ok():
            return self._deny()
        u = urlparse(self.path)
        b = self._body()
        try:
            if u.path == "/api/gain":
                # femtogainctl validates channel (1-4) and gain code (0-6)
                rc, out = ctl("gain", str(b.get("ch", "")).strip(), str(b.get("gain", "")).strip(), timeout=10)
            elif u.path == "/api/ovlreset":
                ch = str(b.get("ch", "")).strip()
                rc, out = ctl("ovl", "reset", *([ch] if ch else []), timeout=10)
            elif u.path == "/api/chnames":
                names = b.get("names", [])
                if not (isinstance(names, list) and len(names) == 4):
                    return self._send(400, {"error": "채널 이름 4개가 필요합니다"})
                # femtogainctl validates the characters and uniqueness
                rc, out = ctl("chname", *[str(n).strip() for n in names], timeout=40)
            elif u.path == "/api/prefix":
                rc, out = ctl("prefix", str(b.get("prefix", "")).strip(), timeout=40)
            elif u.path == "/api/hostname":
                rc, out = ctl("hostname", str(b.get("hostname", "")).strip(), timeout=10)
            elif u.path == "/api/ip":
                if b.get("mode") == "dhcp":
                    args = ["ip", "dhcp"]
                else:
                    ip, gw = str(b.get("ip", "")).strip(), str(b.get("gateway", "")).strip()
                    dns = str(b.get("dns", "")).strip() or "8.8.8.8"
                    mask = str(b.get("netmask", "")).strip() or "255.255.255.0"
                    if not (IP_RE.match(ip) and IP_RE.match(gw)):
                        return self._send(400, {"error": "IP / gateway 형식이 잘못되었습니다"})
                    args = ["ip", ip, gw, dns, mask]
                # the reply may never reach the browser if the address changes
                rc, out = ctl(*args, timeout=30)
            elif u.path == "/api/service":
                act = str(b.get("action", ""))
                if act not in ("start", "stop", "restart"):
                    return self._send(400, {"error": "bad action"})
                rc, out = ctl(act, timeout=40)
            elif u.path == "/api/password":
                rc, out = ctl("passwd", str(b.get("password", "")), timeout=10)
            else:
                return self._send(404, {"error": "not found"})
        except Exception as e:  # noqa
            return self._send(500, {"error": str(e)})
        _net_cache["t"] = 0.0   # settings may have changed
        return self._send(200 if rc == 0 else 400, {"ok": rc == 0, "output": out})


def main():
    conf = read_conf(WEB_CONF)
    port = int(conf.get("WEB_PORT", "8080"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.daemon_threads = True
    print(f"femtogain-web listening on :{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
