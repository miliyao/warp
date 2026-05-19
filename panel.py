#!/usr/bin/env python3
import base64
import html
import ipaddress
import json
import os
import secrets
import subprocess
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PANEL_USER = os.environ.get("PANEL_USER", "admin")
PANEL_PASS = os.environ.get("PANEL_PASS", "admin")
PANEL_PORT = int(os.environ.get("PANEL_PORT", "8080"))
CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/etc/warp-route"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/warp-route"))
LOG_DIR = Path(os.environ.get("LOG_DIR", "/var/log/warp-route"))
WG_INTERFACE = os.environ.get("WG_INTERFACE", "wgcf")
RULES_PATH = CONFIG_DIR / "rules.json"
RESOLVED_PATH = STATE_DIR / "resolved_ips.txt"
APPLY_LOG = LOG_DIR / "apply.log"


def run(command, timeout=8):
    try:
        result = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return result.returncode, result.stdout.strip()
    except Exception as exc:
        return 1, str(exc)


def load_rules():
    if not RULES_PATH.exists():
        return {"domains": [], "ips": [], "optional_domains": {}}
    return json.loads(RULES_PATH.read_text())


def save_rules(rules):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    RULES_PATH.write_text(json.dumps(rules, indent=2, sort_keys=True) + "\n")


def normalize_domain(value):
    value = value.strip().lower().rstrip(".")
    if not value or "/" in value or " " in value:
        raise ValueError("invalid domain")
    return value


def normalize_ip(value):
    return str(ipaddress.ip_network(value.strip(), strict=False))


def check_auth(header):
    if not header.startswith("Basic "):
        return False
    try:
        raw = base64.b64decode(header.split(" ", 1)[1]).decode()
        user, password = raw.split(":", 1)
    except Exception:
        return False
    return secrets.compare_digest(user, PANEL_USER) and secrets.compare_digest(password, PANEL_PASS)


def public_ip():
    code, output = run(["curl", "-4fsS", "--max-time", "5", "https://api.ipify.org"])
    return output if code == 0 and output else "unavailable"


def warp_ip():
    code, output = run(["curl", "-4fsS", "--max-time", "8", "--interface", WG_INTERFACE, "https://api.ipify.org"])
    return output if code == 0 and output else "unavailable"


def service_state(name):
    code, output = run(["systemctl", "is-active", name], timeout=4)
    return output if code == 0 else "inactive"


def wg_show():
    code, output = run(["wg", "show", WG_INTERFACE], timeout=4)
    return output if code == 0 and output else "unavailable"


def tail(path, limit=120):
    if not path.exists():
        return ""
    lines = path.read_text(errors="replace").splitlines()
    return "\n".join(lines[-limit:])


def resolved_rows():
    if not RESOLVED_PATH.exists():
        return []
    rows = []
    for line in RESOLVED_PATH.read_text(errors="replace").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2:
            rows.append((parts[0], parts[1]))
    return rows


def shell_escape(text):
    return html.escape(text, quote=True)


def env_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


STYLE = """
body{margin:0;font:14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f6f7f9;color:#17202a}
header{background:#1f2937;color:white;padding:18px 28px}
main{max-width:1120px;margin:0 auto;padding:24px}
nav a{color:#dbeafe;margin-right:18px;text-decoration:none}
h1{font-size:20px;margin:0 0 8px}
h2{font-size:18px;margin:0 0 14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin-bottom:18px}
.card{background:white;border:1px solid #d9dee7;border-radius:8px;padding:16px}
.metric{font-size:22px;font-weight:650;word-break:break-all}
.muted{color:#5b6472}
textarea,input{width:100%;box-sizing:border-box;border:1px solid #cbd2dc;border-radius:6px;padding:10px;font:14px ui-monospace,SFMono-Regular,Menlo,monospace;background:white}
textarea{min-height:180px;resize:vertical}
button{border:0;border-radius:6px;background:#2563eb;color:white;font-weight:650;padding:9px 14px;cursor:pointer}
button.secondary{background:#4b5563}
table{border-collapse:collapse;width:100%;background:white}
td,th{border-bottom:1px solid #e5e7eb;padding:8px;text-align:left}
pre{white-space:pre-wrap;word-break:break-word;background:#111827;color:#f9fafb;border-radius:8px;padding:14px;overflow:auto}
.flash{border-left:4px solid #2563eb;background:#eff6ff;padding:10px 12px;margin-bottom:16px}
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "WarpRoutePanel/1.0"

    def do_AUTHHEAD(self):
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", 'Basic realm="warp-route"')
        self.end_headers()

    def authenticated(self):
        if check_auth(self.headers.get("Authorization", "")):
            return True
        self.do_AUTHHEAD()
        return False

    def send_html(self, title, body, status=HTTPStatus.OK):
        page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{shell_escape(title)}</title><style>{STYLE}</style></head>
<body><header><h1>WARP Policy Routing</h1><nav>
<a href="/">Dashboard</a><a href="/rules">Routing Rules</a><a href="/logs">Logs</a><a href="/settings">Settings</a>
</nav></header><main>{body}</main></body></html>"""
        data = page.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location):
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", location)
        self.end_headers()

    def read_form(self):
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length).decode()
        parsed = urllib.parse.parse_qs(data)
        return {key: values[-1] for key, values in parsed.items()}

    def do_GET(self):
        if not self.authenticated():
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self.dashboard()
        elif path == "/rules":
            self.rules()
        elif path == "/logs":
            self.logs()
        elif path == "/settings":
            self.settings()
        else:
            self.send_html("Not found", "<h2>Not found</h2>", HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self.authenticated():
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/rules":
            self.save_rules()
        elif path == "/refresh":
            run(["/usr/local/sbin/warp-route-apply"], timeout=60)
            self.redirect("/rules?updated=1")
        elif path == "/settings":
            self.apply_settings()
        else:
            self.send_html("Not found", "<h2>Not found</h2>", HTTPStatus.NOT_FOUND)

    def dashboard(self):
        body = f"""
<div class="grid">
  <section class="card"><h2>Direct Public IP</h2><div class="metric">{shell_escape(public_ip())}</div></section>
  <section class="card"><h2>WARP Public IP</h2><div class="metric">{shell_escape(warp_ip())}</div></section>
  <section class="card"><h2>WireGuard</h2><div class="metric">{shell_escape(service_state(f"wg-quick@{WG_INTERFACE}.service"))}</div></section>
  <section class="card"><h2>Panel</h2><div class="metric">{shell_escape(service_state("warp-route-panel.service"))}</div></section>
</div>
<section class="card"><h2>WireGuard Stats</h2><pre>{shell_escape(wg_show())}</pre></section>
"""
        self.send_html("Dashboard", body)

    def rules(self):
        rules = load_rules()
        domains = "\n".join(rules.get("domains", []))
        ips = "\n".join(rules.get("ips", []))
        rows = "\n".join(
            f"<tr><td>{shell_escape(ip)}</td><td>{shell_escape(source)}</td></tr>"
            for ip, source in resolved_rows()
        )
        if not rows:
            rows = '<tr><td colspan="2" class="muted">No resolved IPs yet. Refresh rules first.</td></tr>'
        body = f"""
<form method="post" class="grid">
  <section class="card"><h2>Domains</h2><textarea name="domains">{shell_escape(domains)}</textarea></section>
  <section class="card"><h2>IP / CIDR</h2><textarea name="ips">{shell_escape(ips)}</textarea></section>
  <section class="card"><h2>Apply</h2><p class="muted">One domain or IP range per line. Saving also refreshes ipset.</p><button type="submit">Save Rules</button></section>
</form>
<form method="post" action="/refresh" class="card"><h2>Resolved Entries</h2><p><button class="secondary" type="submit">Refresh Now</button></p>
<table><thead><tr><th>IP</th><th>Source</th></tr></thead><tbody>{rows}</tbody></table></form>
"""
        self.send_html("Routing Rules", body)

    def save_rules(self):
        form = self.read_form()
        try:
            domains = sorted({normalize_domain(x) for x in form.get("domains", "").splitlines() if x.strip()})
            ips = sorted({normalize_ip(x) for x in form.get("ips", "").splitlines() if x.strip()})
        except ValueError as exc:
            self.send_html("Invalid rules", f'<div class="flash">Invalid rule: {shell_escape(str(exc))}</div><p><a href="/rules">Back</a></p>', HTTPStatus.BAD_REQUEST)
            return

        old = load_rules()
        save_rules({"domains": domains, "ips": ips, "optional_domains": old.get("optional_domains", {})})
        run(["/usr/local/sbin/warp-route-apply"], timeout=60)
        self.redirect("/rules?updated=1")

    def logs(self):
        body = f"""
<section class="card"><h2>Route Refresh Log</h2><pre>{shell_escape(tail(APPLY_LOG))}</pre></section>
<section class="card"><h2>Panel Service Log</h2><pre>{shell_escape(run(["journalctl","-u","warp-route-panel.service","-n","120","--no-pager"], timeout=8)[1])}</pre></section>
"""
        self.send_html("Logs", body)

    def settings(self):
        body = """
<section class="card"><h2>Restart WARP</h2>
<form method="post"><input type="hidden" name="action" value="restart_warp">
<p class="muted">Restarts WireGuard and refreshes policy routing.</p><button type="submit">Restart WARP</button></form></section>
<section class="card"><h2>Change Panel Password</h2>
<form method="post"><input type="hidden" name="action" value="password">
<p><input name="password" type="password" placeholder="New password"></p><button type="submit">Update Password</button></form></section>
"""
        self.send_html("Settings", body)

    def apply_settings(self):
        form = self.read_form()
        action = form.get("action")
        if action == "restart_warp":
            run(["systemctl", "restart", f"wg-quick@{WG_INTERFACE}.service"], timeout=20)
            run(["/usr/local/sbin/warp-route-apply"], timeout=60)
            self.redirect("/settings?restarted=1")
            return
        if action == "password":
            password = form.get("password", "")
            if len(password) < 6:
                self.send_html("Settings", '<div class="flash">Password must be at least 6 characters.</div><p><a href="/settings">Back</a></p>', HTTPStatus.BAD_REQUEST)
                return
            env_path = CONFIG_DIR / "panel.env"
            lines = []
            for line in env_path.read_text().splitlines():
                if line.startswith("PANEL_PASS="):
                    lines.append(f"PANEL_PASS={env_quote(password)}")
                else:
                    lines.append(line)
            env_path.write_text("\n".join(lines) + "\n")
            run(["systemctl", "restart", "warp-route-panel.service"], timeout=8)
            self.redirect("/settings?password=1")
            return
        self.redirect("/settings")


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PANEL_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
