#!/usr/bin/env python3
"""Generate the original, opaque glass-window app icon with Python's standard library."""
import json
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "ComfyWorkbench/Assets.xcassets"
DESTINATION = ASSETS / "AppIcon.appiconset"


def blend(base, color, alpha):
    alpha = max(0.0, min(1.0, alpha))
    return tuple(a * (1 - alpha) + b * alpha for a, b in zip(base, color))


def rectangle(x, y, cx, cy, width, height, radius, angle):
    cosine, sine = math.cos(angle), math.sin(angle)
    px = (x - cx) * cosine + (y - cy) * sine
    py = -(x - cx) * sine + (y - cy) * cosine
    qx, qy = abs(px) - width / 2 + radius, abs(py) - height / 2 + radius
    distance = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    return distance, px, py


def cover(distance, scale):
    return max(0.0, min(1.0, 0.5 - distance * scale))


def pixel(x, y, scale):
    glow = math.exp(-((x - 0.18) ** 2 + (y - 0.78) ** 2) / 0.23)
    silver = math.exp(-((x - 0.85) ** 2 + (y - 0.12) ** 2) / 0.32)
    color = (8 + 13 * glow + 13 * silver, 21 + 69 * glow + 17 * silver, 31 + 68 * glow + 23 * silver)
    for cx, cy, angle, opacity in [(0.59, 0.42, -0.13, 0.22), (0.43, 0.57, 0.08, 0.32)]:
        distance, px, py = rectangle(x, y, cx, cy, 0.58, 0.46, 0.08, angle)
        shadow = math.exp(-max(distance, 0) * 55) * 0.20 * cover(-distance, scale)
        color = blend(color, (0, 8, 17), shadow)
        glass = cover(distance, scale)
        vertical = max(0, min(1, 0.5 - py / 0.46))
        color = blend(color, (124 + 91 * vertical, 194 + 43 * vertical, 205 + 40 * vertical), glass * opacity)
        rim = cover(abs(distance + 0.003) - 0.0035, scale)
        color = blend(color, (214, 250, 255), rim * (0.38 + 0.44 * vertical))
        if cx < 0.5:
            for dot in [-0.205, -0.163, -0.121]:
                dot_alpha = cover(math.hypot(px - dot, py + 0.145) - 0.009, scale)
                color = blend(color, (237, 254, 255), dot_alpha * 0.88)
            divider = cover(abs(py + 0.105) - 0.0013, scale) * glass
            color = blend(color, (202, 242, 245), divider * 0.26)
            for bx, by, width, opacity_bar in [(-0.061, -0.005, 0.29, 0.86), (-0.094, 0.055, 0.224, 0.46), (-0.132, 0.113, 0.148, 0.28)]:
                bar, _, _ = rectangle(px, py, bx, by, width, 0.016, 0.008, 0)
                color = blend(color, (230, 255, 255), cover(bar, scale) * opacity_bar)
            disc = cover(math.hypot(px - 0.153, py - 0.069) - 0.055, scale)
            color = blend(color, (121, 243, 230), disc * 0.62)
            inner = cover(math.hypot(px - 0.153, py - 0.069) - 0.026, scale)
            color = blend(color, (225, 255, 253), inner * 0.9)
    return bytes(max(0, min(255, round(channel))) for channel in color)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write_png(size):
    rows = bytearray()
    for row in range(size):
        rows.append(0)
        for column in range(size):
            rows.extend(pixel((column + 0.5) / size, (row + 0.5) / size, size))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    (DESTINATION / f"AppIcon{size}.png").write_bytes(data)


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    entries = []
    for points in [20, 29, 40, 60]:
        for density in [2, 3]:
            entries.append({"idiom": "iphone", "size": f"{points}x{points}", "scale": f"{density}x", "filename": f"AppIcon{points * density}.png"})
    entries.append({"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": "AppIcon1024.png"})
    for size in sorted({int(entry["filename"][7:-4]) for entry in entries}):
        write_png(size)
    (DESTINATION / "Contents.json").write_text(json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    (ASSETS / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n', encoding="utf-8")
    print("Generated original app icons in", DESTINATION)


if __name__ == "__main__":
    main()
