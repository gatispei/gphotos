#!/usr/bin/env python3
"""Generates the tvOS asset catalog: a layered (parallax) app icon and top shelf art.

tvOS icons are "image stacks": three PNG layers that the system shifts apart as
the user moves focus. Run this to regenerate GPhotosTV/Assets.xcassets.
"""
import json
import math
import os
import shutil

from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CATALOG = os.path.join(ROOT, "GPhotosTV", "Assets.xcassets")
INFO = {"author": "xcode", "version": 1}

ACCENT = (66, 133, 244)   # Google blue
WARM = (234, 67, 53)      # Google red
GREEN = (52, 168, 83)
YELLOW = (251, 188, 5)


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2)


def gradient(size, top, bottom):
    w, h = size
    image = Image.new("RGBA", size)
    draw = ImageDraw.Draw(image)
    for y in range(h):
        t = y / max(1, h - 1)
        draw.line(
            [(0, y), (w, y)],
            fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,),
        )
    return image


def pinwheel(size, scale, alpha):
    """The four-petal shape, evoking a photo library without copying any logo."""
    w, h = size
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    cx, cy = w / 2, h / 2
    r = min(w, h) * scale
    petals = [
        ((cx - r, cy - r, cx + r * 0.15, cy + r * 0.15), ACCENT),
        ((cx - r * 0.15, cy - r, cx + r, cy + r * 0.15), WARM),
        ((cx - r * 0.15, cy - r * 0.15, cx + r, cy + r), YELLOW),
        ((cx - r, cy - r * 0.15, cx + r * 0.15, cy + r), GREEN),
    ]
    for box, colour in petals:
        draw.ellipse(box, fill=colour + (alpha,))
    return image


def back_layer(size):
    return gradient(size, (18, 22, 32), (8, 10, 16))


def middle_layer(size):
    w, h = size
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    # Soft concentric glow so the parallax shift reads as depth.
    for i in range(6, 0, -1):
        r = min(w, h) * 0.06 * i
        draw.ellipse(
            (w / 2 - r, h / 2 - r, w / 2 + r, h / 2 + r),
            fill=(66, 133, 244, 10),
        )
    image.alpha_composite(pinwheel(size, 0.22, 120))
    return image


def front_layer(size):
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    image.alpha_composite(pinwheel(size, 0.17, 255))
    return image


LAYERS = [("Front", front_layer), ("Middle", middle_layer), ("Back", back_layer)]


def imageset(path, entries):
    """entries: list of (idiom, scale, size, builder)"""
    images = []
    for idiom, scale, size, builder in entries:
        name = f"{os.path.basename(path).split('.')[0]}-{idiom}-{scale}.png"
        builder(size).resize(size, Image.LANCZOS).save(os.path.join(path, name))
        images.append({"idiom": idiom, "scale": scale, "filename": name})
    write_json(os.path.join(path, "Contents.json"), {"images": images, "info": INFO})


def imagestack(path, base_size, idiom, scales):
    write_json(
        os.path.join(path, "Contents.json"),
        {"layers": [{"filename": f"{n}.imagestacklayer"} for n, _ in LAYERS], "info": INFO},
    )
    for name, builder in LAYERS:
        layer = os.path.join(path, f"{name}.imagestacklayer")
        write_json(os.path.join(layer, "Contents.json"), {"info": INFO})
        content = os.path.join(layer, "Content.imageset")
        os.makedirs(content, exist_ok=True)
        entries = [
            (idiom, scale, (base_size[0] * mult, base_size[1] * mult), builder)
            for scale, mult in scales
        ]
        imageset(content, entries)


def main():
    if os.path.exists(CATALOG):
        shutil.rmtree(CATALOG)
    os.makedirs(CATALOG)
    write_json(os.path.join(CATALOG, "Contents.json"), {"info": INFO})

    brand = os.path.join(CATALOG, "App Icon & Top Shelf Image.brandassets")
    os.makedirs(brand)
    write_json(
        os.path.join(brand, "Contents.json"),
        {
            "assets": [
                {"size": "1280x768", "idiom": "tv-marketing",
                 "filename": "App Icon - App Store.imagestack", "role": "primary-app-icon"},
                {"size": "400x240", "idiom": "tv",
                 "filename": "App Icon.imagestack", "role": "primary-app-icon"},
                {"size": "1920x720", "idiom": "tv",
                 "filename": "Top Shelf Image.imageset", "role": "top-shelf-image"},
                {"size": "2320x720", "idiom": "tv",
                 "filename": "Top Shelf Image Wide.imageset", "role": "top-shelf-image-wide"},
            ],
            "info": INFO,
        },
    )

    imagestack(os.path.join(brand, "App Icon.imagestack"), (400, 240), "tv",
               [("1x", 1), ("2x", 2)])
    imagestack(os.path.join(brand, "App Icon - App Store.imagestack"), (1280, 768),
               "tv-marketing", [("1x", 1)])

    def shelf(size):
        image = back_layer(size)
        image.alpha_composite(pinwheel(size, 0.09, 230))
        return image

    for name, base in [("Top Shelf Image", (1920, 720)), ("Top Shelf Image Wide", (2320, 720))]:
        path = os.path.join(brand, f"{name}.imageset")
        os.makedirs(path, exist_ok=True)
        imageset(path, [
            ("tv", "1x", base, shelf),
            ("tv", "2x", (base[0] * 2, base[1] * 2), shelf),
        ])

    # Accent colour drives button tints across the app.
    accent = os.path.join(CATALOG, "AccentColor.colorset")
    write_json(os.path.join(accent, "Contents.json"), {
        "colors": [{"idiom": "universal", "color": {
            "color-space": "srgb",
            "components": {"red": "0.259", "green": "0.522", "blue": "0.957", "alpha": "1.000"},
        }}],
        "info": INFO,
    })
    print("wrote", CATALOG)


if __name__ == "__main__":
    main()
