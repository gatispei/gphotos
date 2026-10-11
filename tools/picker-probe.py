#!/usr/bin/env python3
"""Exercises the Google Photos Picker API from the terminal.

The Picker API is the only live-library API open to ordinary developers: the
Ambient API is gated behind Google's Partner Program, and the Library API can
only see content your own app uploaded.

This probe answers two questions the docs do not:
  1. Can you select photos from albums shared *with* you?
  2. How many items can one session return, and with what metadata?

Usage:
    python3 tools/picker-probe.py                 # new picking session
    python3 tools/picker-probe.py --session <id>  # re-read an existing session
    python3 tools/picker-probe.py --reset         # forget the saved token
"""
from __future__ import annotations

import argparse
import collections
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from gphotos_oauth import Session, call, show_qr  # noqa: E402

PICKER = "https://photospicker.googleapis.com/v1"
SCOPES = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"


def poll_session(token: str, session_id: str, interval: float) -> dict:
    print("  Waiting for your selection…", end="", flush=True)
    for _ in range(240):
        time.sleep(interval)
        print(".", end="", flush=True)
        session = call(f"{PICKER}/sessions/{session_id}", token)
        if session.get("mediaItemsSet"):
            print(" done.\n")
            return session
    sys.exit("\n  Timed out waiting for a selection.")


def summarize(items: list[dict]) -> None:
    kinds = collections.Counter(item.get("type", "UNKNOWN") for item in items)
    print("\n" + "=" * 62)
    print(f"  {len(items)} item(s) returned   " +
          "  ".join(f"{kind}: {count}" for kind, count in kinds.items()))
    print("=" * 62 + "\n")

    for item in items[:25]:
        media = item.get("mediaFile", {})
        meta = media.get("mediaFileMetadata", {})
        size = f"{meta.get('width', '?')}x{meta.get('height', '?')}"
        print(f"  · {media.get('filename') or item.get('id')}")
        print(f"      {media.get('mimeType', '?')}  {size}  "
              f"created {item.get('createTime', '?')}")
    if len(items) > 25:
        print(f"\n  … and {len(items) - 25} more")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", help="Re-read an existing session id")
    parser.add_argument("--reset", action="store_true", help="Forget the saved token")
    args = parser.parse_args()

    session_store = Session("picker-probe", SCOPES, flow="loopback")
    if args.reset:
        session_store.reset()
        print("Local probe state cleared.")
        return

    token = session_store.token()

    if args.session:
        session = call(f"{PICKER}/sessions/{args.session}", token)
        if not session.get("mediaItemsSet"):
            sys.exit("That session has no selection yet.")
    else:
        session = call(f"{PICKER}/sessions", token, method="POST", body={})
        picker_uri = session.get("pickerUri")
        session_id = session["id"]

        print("\n" + "=" * 62)
        print("  Pick photos in Google Photos")
        print("=" * 62)
        print("\n  Open this on your phone:\n")
        print(f"  {picker_uri}\n")
        show_qr(picker_uri)
        print(f"  (session id: {session_id})\n")
        print("  >>> While picking, check whether albums SHARED WITH YOU <<<")
        print("  >>> appear and can be selected.                         <<<\n")

        interval = 5.0
        polling = (session.get("pollingConfig") or {}).get("pollInterval", "5s")
        if isinstance(polling, str) and polling.endswith("s"):
            interval = max(2.0, float(polling[:-1]))
        session = poll_session(token, session_id, interval)

    # Page through everything the user picked.
    items: list[dict] = []
    page_token = None
    while True:
        query = {"sessionId": session["id"], "pageSize": "100"}
        if page_token:
            query["pageToken"] = page_token
        page = call(f"{PICKER}/mediaItems", token, query=query)
        items.extend(page.get("mediaItems") or [])
        page_token = page.get("nextPageToken")
        if not page_token:
            break

    summarize(items)
    print(f"  Re-read later with:  python3 tools/picker-probe.py --session {session['id']}\n")


if __name__ == "__main__":
    main()
