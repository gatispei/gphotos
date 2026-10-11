#!/usr/bin/env python3
"""Serves an unzipped Google Takeout export to the GPhotos TV app.

Why this exists: Google removed full-library API read access on 2025-03-31, so
the only way to browse a *complete* Google Photos library is from a Takeout
export. This indexes one and serves it over the LAN with no quotas.

Usage:
    python3 server.py --root ~/Downloads/Takeout --port 8099

Endpoints:
    GET /collections                      -> albums and years
    GET /items?collection=&pageToken=&pageSize=
    GET /media/<id>?w=<px>&crop=1         -> JPEG/video bytes
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import mimetypes
import os
import re
import socket
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    from PIL import Image, ImageOps
except ImportError:
    Image = None

PHOTO_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tif", ".tiff", ".bmp"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".3gp", ".webm", ".mpg", ".mts"}
# Takeout writes sidecar JSON next to each file; skip those and Google's extras.
SKIP_NAMES = {"metadata.json", "print-subscriptions.json", "shared_album_comments.json",
              "user-generated-memory-titles.json"}

ID_RE = re.compile(r"^[0-9a-f]{16}$")


class Library:
    """Scans a Takeout tree once and keeps an in-memory index."""

    def __init__(self, root: str):
        self.root = os.path.abspath(os.path.expanduser(root))
        self.items: dict[str, dict] = {}
        self.albums: dict[str, list[str]] = {}
        self.years: dict[str, list[str]] = {}
        self.order: list[str] = []
        self._thumb_dir = os.path.join(self.root, ".gphotostv-thumbs")

    # -- indexing ---------------------------------------------------------

    def scan(self) -> None:
        print(f"Indexing {self.root} …", flush=True)
        photos_root = self._find_photos_root()

        for dirpath, dirnames, filenames in os.walk(photos_root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            album = os.path.basename(dirpath)
            for filename in filenames:
                ext = os.path.splitext(filename)[1].lower()
                if ext not in PHOTO_EXT and ext not in VIDEO_EXT:
                    continue
                path = os.path.join(dirpath, filename)
                item_id = hashlib.sha1(
                    os.path.relpath(path, self.root).encode("utf-8")
                ).hexdigest()[:16]

                meta = self._sidecar(path)
                taken = meta.get("taken") or self._mtime(path)
                self.items[item_id] = {
                    "id": item_id,
                    "path": path,
                    "filename": filename,
                    "mimeType": mimetypes.guess_type(filename)[0]
                                or ("video/mp4" if ext in VIDEO_EXT else "image/jpeg"),
                    "isVideo": ext in VIDEO_EXT,
                    "createdAt": taken,
                    "width": meta.get("width"),
                    "height": meta.get("height"),
                }
                # "Photos from 2019" folders are Takeout's year buckets, not albums.
                if album.lower().startswith("photos from "):
                    self.years.setdefault(album[len("Photos from "):], []).append(item_id)
                else:
                    self.albums.setdefault(album, []).append(item_id)

        # Newest first, matching how Google Photos presents a library.
        self.order = sorted(
            self.items,
            key=lambda i: self.items[i]["createdAt"] or "",
            reverse=True,
        )
        for bucket in (self.albums, self.years):
            for key, ids in bucket.items():
                bucket[key] = sorted(
                    ids, key=lambda i: self.items[i]["createdAt"] or "", reverse=True
                )

        print(
            f"Indexed {len(self.items)} items · "
            f"{len(self.albums)} albums · {len(self.years)} years",
            flush=True,
        )

    def _find_photos_root(self) -> str:
        """Takeout nests everything under 'Google Photos' (localised on some exports)."""
        for candidate in os.listdir(self.root) if os.path.isdir(self.root) else []:
            full = os.path.join(self.root, candidate)
            if os.path.isdir(full) and "google" in candidate.lower() and "photo" in candidate.lower():
                return full
            nested = os.path.join(full, "Google Photos")
            if os.path.isdir(nested):
                return nested
        return self.root

    @staticmethod
    def _sidecar(path: str) -> dict:
        """Reads the Takeout JSON sidecar, which carries the real capture time."""
        for suffix in (".json", ".supplemental-metadata.json"):
            candidate = path + suffix
            if not os.path.exists(candidate):
                continue
            try:
                with open(candidate, "r", encoding="utf-8") as handle:
                    raw = json.load(handle)
            except (OSError, ValueError):
                continue
            taken = None
            for key in ("photoTakenTime", "creationTime"):
                stamp = raw.get(key, {}).get("timestamp")
                if stamp:
                    taken = datetime.fromtimestamp(int(stamp), tz=timezone.utc).isoformat()
                    break
            return {
                "taken": taken,
                "width": _int(raw.get("width")),
                "height": _int(raw.get("height")),
            }
        return {}

    @staticmethod
    def _mtime(path: str) -> str:
        return datetime.fromtimestamp(os.path.getmtime(path), tz=timezone.utc).isoformat()

    # -- queries ----------------------------------------------------------

    def collections(self) -> list[dict]:
        entries = [
            {"id": f"album:{name}", "title": name, "count": len(ids)}
            for name, ids in sorted(self.albums.items())
        ]
        entries += [
            {"id": f"year:{year}", "title": year, "count": len(ids)}
            for year, ids in sorted(self.years.items(), reverse=True)
        ]
        return entries

    def ids_for(self, collection: str | None) -> list[str]:
        if not collection:
            return self.order
        kind, _, key = collection.partition(":")
        if kind == "album":
            return self.albums.get(key, [])
        if kind == "year":
            return self.years.get(key, [])
        return []

    # -- rendering --------------------------------------------------------

    def thumbnail(self, item: dict, width: int, crop: bool) -> tuple[bytes, str] | None:
        if item["isVideo"] or Image is None:
            return None
        os.makedirs(self._thumb_dir, exist_ok=True)
        cache = os.path.join(self._thumb_dir, f"{item['id']}-{width}{'c' if crop else ''}.jpg")
        if os.path.exists(cache):
            with open(cache, "rb") as handle:
                return handle.read(), "image/jpeg"
        try:
            with Image.open(item["path"]) as image:
                image = ImageOps.exif_transpose(image).convert("RGB")
                if crop:
                    image = ImageOps.fit(image, (width, width), Image.LANCZOS)
                else:
                    image.thumbnail((width, width), Image.LANCZOS)
                buffer = io.BytesIO()
                image.save(buffer, "JPEG", quality=86, optimize=True)
        except Exception as error:  # unreadable or unsupported (e.g. HEIC without plugin)
            print(f"thumbnail failed for {item['filename']}: {error}", flush=True)
            return None
        data = buffer.getvalue()
        with open(cache, "wb") as handle:
            handle.write(data)
        return data, "image/jpeg"


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


class Handler(BaseHTTPRequestHandler):
    library: Library = None  # injected below
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter console
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        route = parsed.path.rstrip("/") or "/"

        if route == "/collections":
            return self._json({"collections": self.library.collections()})
        if route == "/items":
            return self._items(query)
        if route.startswith("/media/"):
            return self._media(route[len("/media/"):], query)
        if route == "/":
            return self._json({
                "name": "gphotostv-takeout-server",
                "items": len(self.library.items),
                "collections": len(self.library.collections()),
            })
        self.send_error(404, "Unknown endpoint")

    def _items(self, query):
        collection = query.get("collection", [None])[0]
        page_size = max(1, min(int(query.get("pageSize", ["100"])[0]), 500))
        token = int(query.get("pageToken", ["0"])[0] or 0)

        ids = self.library.ids_for(collection)
        window = ids[token:token + page_size]
        items = []
        for item_id in window:
            item = self.library.items[item_id]
            items.append({
                "id": item["id"],
                "filename": item["filename"],
                "mimeType": item["mimeType"],
                "width": item["width"],
                "height": item["height"],
                "createdAt": item["createdAt"],
                "isVideo": item["isVideo"],
                "url": f"/media/{item['id']}",
            })
        next_token = token + page_size
        return self._json({
            "items": items,
            "nextPageToken": str(next_token) if next_token < len(ids) else None,
        })

    def _media(self, item_id, query):
        if not ID_RE.match(item_id or ""):
            return self.send_error(400, "Bad id")
        item = self.library.items.get(item_id)
        if not item:
            return self.send_error(404, "No such item")

        width = _int(query.get("w", [None])[0])
        crop = query.get("crop", ["0"])[0] == "1"
        if width and not item["isVideo"]:
            rendered = self.library.thumbnail(item, width, crop)
            if rendered:
                data, content_type = rendered
                return self._bytes(data, content_type)
        return self._file(item)

    # -- responses --------------------------------------------------------

    def _json(self, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bytes(self, data: bytes, content_type: str):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        self.wfile.write(data)

    def _file(self, item):
        """Streams the original file, honouring Range so video seeking works."""
        path = item["path"]
        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200

        header = self.headers.get("Range")
        if header and header.startswith("bytes="):
            raw = header[len("bytes="):].split("-")
            if raw[0]:
                start = int(raw[0])
            if len(raw) > 1 and raw[1]:
                end = min(int(raw[1]), size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", item["mimeType"])
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

        with open(path, "rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                chunk = handle.read(min(1024 * 256, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return  # player seeked away
                remaining -= len(chunk)


def local_ip() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="Path to the unzipped Takeout folder")
    parser.add_argument("--port", type=int, default=8099)
    args = parser.parse_args()

    if Image is None:
        print("warning: Pillow is not installed — originals will be sent unresized.")
        print("         pip3 install Pillow")

    library = Library(args.root)
    if not os.path.isdir(library.root):
        sys.exit(f"No such directory: {library.root}")
    library.scan()
    if not library.items:
        sys.exit("No photos or videos found. Point --root at the unzipped Takeout folder.")

    Handler.library = library
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    address = f"http://{local_ip()}:{args.port}"
    print(f"\nServing on {address}")
    print(f"Enter that address in the Apple TV app under Settings → Takeout archive server.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
