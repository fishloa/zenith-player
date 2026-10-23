#!/usr/bin/env python3
"""Playlist server with standard auth, for checking Zenith Player's sign-in on a device.

usage: scripts/auth-test-server.py <dir> <port> device|basic
  device: 401 Bearer + RFC 9728/8414 metadata + RFC 8628 device grant; the
          device code is approved automatically 10 s after it is issued.
  basic:  401 Basic realm="test"; user "zenith", password "player".
The playlist is <dir>/playlist.m3u with every URL rewritten to this server and
?t=<token> appended, as zenith does. Streams accept ?t=. Every request is
logged as one line: METHOD PATH STATUS AUTH.
"""
import base64, json, os, secrets, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs

ROOT, PORT, MODE = sys.argv[1], int(sys.argv[2]), sys.argv[3]
TOKEN = secrets.token_hex(16)
CODES = {}
LOCK = threading.Lock()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def base(self):
        return f"http://{self.headers['Host']}"

    def send(self, status, body=b"", ctype="text/plain", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
        auth = self.headers.get("Authorization", "")
        kind = auth.split(" ")[0] if auth else ("?t" if "t=" in self.path else "-")
        print(f"{self.command} {urlsplit(self.path).path} {status} {kind}", flush=True)

    def authorized(self):
        q = parse_qs(urlsplit(self.path).query)
        if q.get("t", [""])[0] == TOKEN: return True
        a = self.headers.get("Authorization", "")
        if MODE == "device": return a == f"Bearer {TOKEN}"
        return a == "Basic " + base64.b64encode(b"zenith:player").decode()

    def challenge(self):
        if MODE == "device":
            h = f'Bearer realm="test", resource_metadata="{self.base()}/.well-known/oauth-protected-resource"'
        else:
            h = 'Basic realm="test"'
        self.send(401, b"sign in", headers=[("WWW-Authenticate", h)])

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/.well-known/oauth-protected-resource":
            return self.send(200, json.dumps({"resource": self.base(), "authorization_servers": [self.base()]}).encode(), "application/json")
        if path == "/.well-known/oauth-authorization-server":
            return self.send(200, json.dumps({"issuer": self.base(), "device_authorization_endpoint": f"{self.base()}/device",
                                              "token_endpoint": f"{self.base()}/token",
                                              "grant_types_supported": ["urn:ietf:params:oauth:grant-type:device_code"]}).encode(), "application/json")
        if not self.authorized(): return self.challenge()
        if path == "/playlist.m3u":
            text = open(os.path.join(ROOT, "playlist.m3u")).read()
            out = []
            for line in text.splitlines():
                if line.startswith("http"):
                    line = f"{self.base()}/{line.rsplit('/', 1)[1].split('?')[0]}?t={TOKEN}"
                out.append(line)
            return self.send(200, ("\n".join(out) + "\n").encode(), "audio/x-mpegurl")
        f = os.path.join(ROOT, os.path.basename(path))
        if os.path.isfile(f):
            return self.send(200, open(f, "rb").read(), "video/mp2t")
        self.send(404)

    def do_POST(self):
        path = urlsplit(self.path).path
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        if path == "/device" and MODE == "device":
            dc, uc = secrets.token_hex(8), "TEST-" + secrets.token_hex(2).upper()
            with LOCK: CODES[dc] = time.time() + 10
            print(f"DEVICE CODE {uc} for client {form.get('client_id', ['?'])[0]}", flush=True)
            return self.send(200, json.dumps({"device_code": dc, "user_code": uc, "verification_uri": f"{self.base()}/link",
                                              "expires_in": 300, "interval": 2}).encode(), "application/json")
        if path == "/token" and MODE == "device":
            dc = form.get("device_code", [""])[0]
            with LOCK: approved = CODES.get(dc)
            if approved is None: return self.send(400, b'{"error":"expired_token"}', "application/json")
            if time.time() < approved: return self.send(400, b'{"error":"authorization_pending"}', "application/json")
            print("TOKEN ISSUED", flush=True)
            return self.send(200, json.dumps({"access_token": TOKEN, "token_type": "Bearer"}).encode(), "application/json")
        self.send(404)

    do_HEAD = do_GET

ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()