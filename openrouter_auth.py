"""OpenRouter's documented S256 PKCE flow with an ephemeral loopback callback."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import secrets
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit
import webbrowser

import requests


class AuthError(RuntimeError):
    pass


def pkce_pair():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
    return verifier, challenge


class OpenRouterLogin:
    def __init__(self, timeout=300, opener=None):
        self.timeout = timeout
        self.opener = opener or webbrowser.open
        self.cancelled = threading.Event()
        self.verifier, self.challenge = pkce_pair()
        # An unguessable callback path binds the response to this particular login.
        self.path = "/callback/" + secrets.token_urlsafe(32)
        self.code = None
        self.error = None

    def cancel(self):
        self.cancelled.set()

    def run(self, on_ready=None):
        login = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def log_message(self, *args):
                pass  # OAuth codes must never enter logs.

            def do_GET(self):
                parsed = urlsplit(self.path)
                allowed_hosts = {f"localhost:{self.server.server_port}", f"127.0.0.1:{self.server.server_port}"}
                if parsed.path != login.path or self.headers.get("Host") not in allowed_hosts:
                    self.send_error(404)
                    return
                params = parse_qs(parsed.query)
                code = params.get("code", [])
                if params.get("error"):
                    login.error = "Die Anmeldung wurde beim Anbieter abgebrochen."
                elif len(code) == 1 and 0 < len(code[0]) <= 4096:
                    login.code = code[0]
                else:
                    self.send_error(400, "Missing authorization code")
                    return
                content = ("<!doctype html><html lang='de'><meta charset='utf-8'><meta name='viewport' content='width=device-width'>"
                           "<title>TokenTracker · Anmeldung</title><body style='margin:0;background:#0E111A;color:#EEF2FA;"
                           "font:18px system-ui;display:grid;place-items:center;min-height:100vh'><div style='max-width:460px;padding:32px'>"
                           "<p style='color:#A99AFB'>TOKEN TRACKER</p><h1>Zurück zur App.</h1><p>Deine Antwort ist angekommen. "
                           "TokenTracker prüft jetzt die Verbindung. Dieses Fenster kannst du schließen.</p></div></body></html>").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

        with HTTPServer(("127.0.0.1", 0), Handler) as server:
            server.timeout = 0.25
            callback = f"http://localhost:{server.server_port}{self.path}"
            url = "https://openrouter.ai/auth?" + urlencode({"callback_url": callback,
                       "code_challenge": self.challenge, "code_challenge_method": "S256"})
            if not self.opener(url):
                raise AuthError("Der Standardbrowser konnte nicht geöffnet werden.")
            if on_ready:
                on_ready()
            deadline = time.monotonic() + self.timeout
            while not self.code and not self.error and not self.cancelled.is_set() and time.monotonic() < deadline:
                server.handle_request()
        if self.cancelled.is_set():
            raise AuthError("Anmeldung abgebrochen.")
        if self.error:
            raise AuthError(self.error)
        if not self.code:
            raise AuthError("Die Anmeldung ist abgelaufen. Bitte erneut versuchen.")
        try:
            response = requests.post("https://openrouter.ai/api/v1/auth/keys",
                                     json={"code": self.code, "code_verifier": self.verifier, "code_challenge_method": "S256"},
                                     timeout=(5, 20), allow_redirects=False)
            if response.status_code != 200:
                raise AuthError(f"OpenRouter konnte die Anmeldung nicht bestätigen (HTTP {response.status_code}).")
            key = response.json().get("key")
            if not isinstance(key, str) or not key.strip():
                raise AuthError("OpenRouter hat keinen gültigen Zugang zurückgegeben.")
            return key
        except (requests.RequestException, ValueError):
            raise AuthError("OpenRouter ist gerade nicht erreichbar. Bitte erneut versuchen.") from None
