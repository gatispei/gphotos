# Takeout archive server

Serves an unzipped Google Takeout export to the GPhotos TV app, giving the Apple
TV access to a **complete** photo library — which the Google Photos API itself
no longer permits.

## Usage

```bash
pip3 install Pillow            # optional, but needed for fast thumbnails
python3 server.py --root ~/Downloads/Takeout --port 8099
```

Point the app at the printed LAN address under
**Settings → Takeout archive server**.

## Endpoints

| Route | Purpose |
|---|---|
| `GET /` | Health check and index stats |
| `GET /collections` | Albums and year buckets |
| `GET /items?collection=&pageToken=&pageSize=` | A page of media, newest first |
| `GET /media/<id>?w=<px>&crop=1` | Resized JPEG, or the original bytes |

## Notes

- Capture dates come from Takeout's `.json` sidecars, not file mtimes.
- Folders named `Photos from <year>` become year buckets; everything else is
  treated as an album.
- Thumbnails are cached in `<root>/.gphotostv-thumbs`.
- `/media` serves only indexed ids, so paths outside the export are unreachable.
- Video responses support HTTP `Range`, so seeking works in the tvOS player.
