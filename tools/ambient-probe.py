#!/usr/bin/env python3
"""Exercises the Google Photos Ambient API from the terminal.

Lets you run the whole device flow — sign in, register a device, pick media
sources, list what comes back — without rebuilding the tvOS app. Useful for
answering questions the docs do not, such as whether albums shared *with* you
can be assigned to an ambient device.

Usage:
    python3 tools/ambient-probe.py            # full flow
    python3 tools/ambient-probe.py --sources  # just re-read the device
    python3 tools/ambient-probe.py --reset    # forget token and device
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import ssl
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_PATH = os.path.join(ROOT, ".ambient-probe-state.json")
SCOPES = "https://www.googleapis.com/auth/photosambient.mediaitems profile"
AMBIENT = "https://photosambient.googleapis.com/v1"


# ---------------------------------------------------------------- credentials

def load_credentials() -> tuple[str, str]:
    """Reads the same Config.local.xcconfig the app uses."""
    client_id = os.environ.get("GPTV_CLIENT_ID")
    secret = os.environ.get("GPTV_CLIENT_SECRET")
    if client_id and secret:
        return client_id, secret

    path = os.path.join(ROOT, "Config.local.xcconfig")
    values = {}
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


def load_state() -> dict:
    if os.path.exists(STATE_PATH):
        with open(STATE_PATH) as handle:
            return json.load(handle)
    return {}


def save_state(state: dict) -> None:
    with open(STATE_PATH, "w") as handle:
        json.dump(state, handle, indent=2)
    os.chmod(STATE_PATH, 0o600)  # contains a refresh token


# ----------------------------------------------------------------- transport

def ssl_context() -> ssl.SSLContext:
    """Python.org builds on macOS ship without a CA bundle, so prefer certifi's.

    Falls back to the default context when certifi is absent (Homebrew and
    system Pythons already trust the platform roots).
    """
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


CONTEXT = ssl_context()


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


def api(path: str, token: str, method: str = "GET", body: dict | None = None,
        query: dict | None = None) -> dict:
    url = f"{AMBIENT}/{path}"
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
        sys.exit(f"HTTP {error.code} on {method} {path}:\n{error.read().decode()}")


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


# ---------------------------------------------------------------------- flow

def authorize(client_id: str, secret: str) -> dict:
    grant = post_form("https://oauth2.googleapis.com/device/code",
                      {"client_id": client_id, "scope": SCOPES})
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
            "client_id": client_id,
            "client_secret": secret,
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


def refresh(client_id: str, secret: str, state: dict) -> str:
    token = state["token"]
    age = time.time() - token.get("obtained_at", 0)
    if age < token.get("expires_in", 3600) - 120:
        return token["access_token"]

    refreshed = post_form("https://oauth2.googleapis.com/token", {
        "client_id": client_id,
        "client_secret": secret,
        "refresh_token": token["refresh_token"],
        "grant_type": "refresh_token",
    })
    if "error" in refreshed:
        sys.exit(f"Refresh failed ({refreshed['error']}). Re-run with --reset.")
    token.update(refreshed)
    token["obtained_at"] = time.time()
    state["token"] = token
    save_state(state)
    return token["access_token"]


def describe_device(device: dict) -> None:
    sources = device.get("mediaSources") or []
    print("\n" + "=" * 62)
    print(f"  Device : {device.get('displayName')} ({device['id']})")
    print(f"  Sources set : {device.get('mediaSourcesSet')}")
    print("=" * 62)
    if not sources:
        print("\n  No media sources assigned yet.")
        return
    print(f"\n  {len(sources)} media source(s):\n")
    for index, source in enumerate(sources, 1):
        print(f"   {index:2}. {source.get('displayName') or '(untitled)'}")
        print(f"       id: {source.get('id')}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", action="store_true",
                        help="Re-read the device and list media sources only")
    parser.add_argument("--items", type=int, default=0, metavar="N",
                        help="List N media items per source (costs API quota)")
    parser.add_argument("--reset", action="store_true",
                        help="Forget the saved token and device")
    args = parser.parse_args()

    if args.reset:
        if os.path.exists(STATE_PATH):
            os.remove(STATE_PATH)
        print("Local probe state cleared.")
        return

    client_id, secret = load_credentials()
    state = load_state()

    if "token" not in state:
        state["token"] = authorize(client_id, secret)
        save_state(state)
    token = refresh(client_id, secret, state)

    # Register a device, or reuse the one from a previous run.
    if "device_id" not in state:
        import uuid
        device = api("devices", token, method="POST",
                     body={"displayName": "Ambient Probe"},
                     query={"requestId": str(uuid.uuid4())})
        state["device_id"] = device["id"]
        save_state(state)
        print(f"Registered device {device['id']}")
    else:
        device = api(f"devices/{state['device_id']}", token)

    if not device.get("mediaSourcesSet") and not args.sources:
        settings = device.get("settingsUri")
        print("\n" + "=" * 62)
        print("  Choose what this device may show")
        print("=" * 62)
        print("\n  Open this on your phone, then pick albums.")
        print("  >>> Try selecting an album someone SHARED WITH YOU. <<<\n")
        print(f"  {settings}\n")
        show_qr(settings)

        interval = 10
        polling = device.get("pollingConfig", {}).get("pollInterval", "10s")
        if polling.endswith("s"):
            interval = max(5, float(polling[:-1]))
        print("  Waiting for your selection…", end="", flush=True)
        for _ in range(120):
            time.sleep(interval)
            print(".", end="", flush=True)
            device = api(f"devices/{state['device_id']}", token)
            if device.get("mediaSourcesSet"):
                print(" done.")
                break
        else:
            print("\n  Timed out. Re-run with --sources once you have chosen.")
            return

    describe_device(device)

    if args.items:
        for source in (device.get("mediaSources") or []):
            page = api("mediaItems", token, query={
                "deviceId": state["device_id"],
                "mediaSourceId": source["id"],
                "pageSize": min(args.items, 100),
            })
            items = page.get("mediaItems") or []
            print(f"\n  {source.get('displayName')}: {len(items)} item(s) returned"
                  f"{' (more pages available)' if page.get('nextPageToken') else ''}")
            for item in items[:5]:
                media = item.get("mediaFile", {})
                print(f"     · {media.get('filename') or item['id']}"
                      f"  {media.get('mimeType') or ''}"
                      f"  {item.get('creationTime') or ''}")


if __name__ == "__main__":
    main()
