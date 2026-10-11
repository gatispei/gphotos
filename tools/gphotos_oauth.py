"""Shared OAuth 2.0 device-flow helper for the Google Photos probe tools.

Keeps the TV/limited-input grant, token storage and TLS setup in one place so
each probe only has to describe the API it exercises.
"""
from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import secrets
import socket
import ssl
import threading
import webbrowser
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def ssl_context() -> ssl.SSLContext:
    """Python.org builds on macOS ship without a CA bundle; prefer certifi's."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


CONTEXT = ssl_context()


def load_credentials() -> tuple[str, str]:
    """Reads the same Config.local.xcconfig the tvOS app uses."""
    client_id = os.environ.get("GPTV_CLIENT_ID")
    secret = os.environ.get("GPTV_CLIENT_SECRET")
    if client_id and secret:
        return client_id, secret

    path = os.path.join(ROOT, "Config.local.xcconfig")
    values: dict[str, str] = {}
    if os.path.exists(path):
        with open(path) as handle:
            for line in handle:
                line = line.split("//")[0].strip()
                if "=" in line:
                    key, _, value = line.partition("=")
                    values[key.strip()] = value.strip()

    client_id = values.get("GPTV_CLIENT_ID")
    secret = values.get("GPTV_CLIENT_SECRET")
    if not client_id or not secret:
        sys.exit(
            "No credentials found.\n"
            "Add GPTV_CLIENT_ID and GPTV_CLIENT_SECRET to Config.local.xcconfig "
            "(copy Config.example.xcconfig), or set them as environment variables."
        )
    return client_id, secret


def post_form(url: str, fields: dict) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(request, context=CONTEXT) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode()
        try:
            return json.loads(body)
        except ValueError:
            sys.exit(f"HTTP {error.code} from {url}: {body}")


def call(url: str, token: str, method: str = "GET", body: dict | None = None,
         query: dict | None = None) -> dict:
    if query:
        url += "?" + urllib.parse.urlencode(query)
    payload = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if payload:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, context=CONTEXT) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code} on {method} {url}:\n{error.read().decode()}")


def show_qr(data: str) -> None:
    try:
        import qrcode
    except ImportError:
        print("  (pip3 install qrcode for a scannable code)")
        return
    code = qrcode.QRCode(border=2)
    code.add_data(data)
    code.make(fit=True)
    code.print_ascii(invert=True)


class Session:
    """Holds a device-flow token for one scope set, cached on disk."""

    def __init__(self, name: str, scopes: str, flow: str = "device"):
        self.scopes = scopes
        self.flow = flow
        # Separate file per probe: the scopes differ, so tokens are not shared.
        self.path = os.path.join(ROOT, f".{name}-state.json")
        self.state: dict = {}
        if os.path.exists(self.path):
            with open(self.path) as handle:
                self.state = json.load(handle)
        self.client_id, self.secret = load_credentials()

    def save(self) -> None:
        with open(self.path, "w") as handle:
            json.dump(self.state, handle, indent=2)
        os.chmod(self.path, 0o600)  # contains a refresh token

    def reset(self) -> None:
        if os.path.exists(self.path):
            os.remove(self.path)

    def authorize(self) -> dict:
        grant = post_form("https://oauth2.googleapis.com/device/code",
                          {"client_id": self.client_id, "scope": self.scopes})
        if "error" in grant:
            sys.exit(f"Device-code request failed: {grant}")

        url = grant.get("verification_url") or grant.get("verification_uri")
        print("\n" + "=" * 62)
        print("  Sign in on your phone or laptop")
        print("=" * 62)
        print(f"\n  1. Go to : {url}")
        print(f"  2. Enter : {grant['user_code']}\n")
        show_qr(url)

        interval = grant.get("interval", 5)
        deadline = time.time() + grant.get("expires_in", 1800)
        print("  Waiting for approval…", end="", flush=True)

        while time.time() < deadline:
            time.sleep(interval)
            print(".", end="", flush=True)
            token = post_form("https://oauth2.googleapis.com/token", {
                "client_id": self.client_id,
                "client_secret": self.secret,
                "device_code": grant["device_code"],
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            })
            error = token.get("error")
            if error == "authorization_pending":
                continue
            if error == "slow_down":
                interval += 5
                continue
            if error:
                sys.exit(f"\nAuthorization failed: {error}")
            print(" approved.\n")
            token["obtained_at"] = time.time()
            return token
        sys.exit("\nThe code expired.")

    # ------------------------------------------------------------- loopback

    def authorize_loopback(self) -> dict:
        """Browser-based grant for scopes the device flow refuses.

        Google rejects some scopes (the Photos Picker among them) in the TV
        device flow, but an "installed" client may redirect to localhost. This
        only works where a browser is available — on a Mac, not on an Apple TV.
        """
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        redirect_uri = f"http://127.0.0.1:{port}"

        verifier = secrets.token_urlsafe(64)[:128]
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()
        ).decode().rstrip("=")
        state = secrets.token_urlsafe(16)
        received: dict = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                query = urllib.parse.urlparse(self.path).query
                params = urllib.parse.parse_qs(query)
                received.update({k: v[0] for k, v in params.items()})
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                ok = "code" in received and received.get("state") == state
                self.wfile.write(
                    b"<html><body style='font-family:-apple-system;padding:3rem'>"
                    + (b"<h2>Authorized.</h2><p>Return to the terminal.</p>"
                       if ok else b"<h2>Authorization failed.</h2>")
                    + b"</body></html>"
                )

        server = http.server.HTTPServer(("127.0.0.1", port), Handler)
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()

        auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
            "client_id": self.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": self.scopes,
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        })

        print("\n" + "=" * 62)
        print("  Authorize in your browser")
        print("=" * 62)
        print(f"\n  {auth_url}\n")
        webbrowser.open(auth_url)
        print("  Waiting for the browser redirect…", flush=True)

        thread.join(timeout=300)
        server.server_close()

        if received.get("state") != state:
            sys.exit("State mismatch — aborting.")
        if "code" not in received:
            sys.exit(f"Authorization failed: {received.get('error', 'no code returned')}")

        token = post_form("https://oauth2.googleapis.com/token", {
            "client_id": self.client_id,
            "client_secret": self.secret,
            "code": received["code"],
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri,
        })
        if "error" in token:
            sys.exit(f"Token exchange failed: {token}")
        print("  Authorized.\n")
        token["obtained_at"] = time.time()
        return token

    def begin(self) -> dict:
        return self.authorize_loopback() if self.flow == "loopback" else self.authorize()

    def token(self) -> str:
        """A valid access token, authorizing or refreshing as needed."""
        if "token" not in self.state:
            self.state["token"] = self.begin()
            self.save()

        token = self.state["token"]
        if time.time() - token.get("obtained_at", 0) < token.get("expires_in", 3600) - 120:
            return token["access_token"]

        refreshed = post_form("https://oauth2.googleapis.com/token", {
            "client_id": self.client_id,
            "client_secret": self.secret,
            "refresh_token": token["refresh_token"],
            "grant_type": "refresh_token",
        })
        if "error" in refreshed:
            # Testing-mode refresh tokens die after 7 days; re-authorize.
            self.state["token"] = self.begin()
            self.save()
            return self.state["token"]["access_token"]
        token.update(refreshed)
        token["obtained_at"] = time.time()
        self.save()
        return token["access_token"]
