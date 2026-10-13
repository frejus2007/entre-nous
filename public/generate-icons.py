#!/usr/bin/env python3
"""Génère les icônes PNG de la PWA sans dépendance externe (zlib + struct).

Dessine un cœur crème sur un fond dégradé corail/rose, aux tailles
192x192, 512x512 et 180x180 (apple-touch-icon).
"""
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def in_heart(nx, ny):
    """Équation implicite du cœur, ny orienté vers le haut."""
    x, y = nx, -ny
    return (x * x + y * y - 1) ** 3 - x * x * (y ** 3) <= 0


def render(size):
    # Couleurs — ambiance claire, chaleureuse et intime.
    corail_haut = (224, 104, 92)    # #E0685C
    rose_bas = (217, 122, 156)      # #D97A9C
    creme = (255, 246, 240)         # #FFF6F0
    rose_clair = (251, 227, 236)    # #FBE3EC

    rows = bytearray()
    for py in range(size):
        rows.append(0)  # filtre PNG type 0
        for px in range(size):
            # Fond : dégradé diagonal corail -> rose
            t = (px + py) / (2 * (size - 1))
            r, g, b = lerp(corail_haut, rose_bas, t)

            # Coordonnées normalisées centrées
            nx = (px - size / 2) / (size * 0.34)
            ny = (py - size / 2) / (size * 0.34)

            if in_heart(nx, ny):
                th = max(0.0, min(1.0, (ny + 1.0) / 2.0))
                r, g, b = lerp(rose_clair, creme, th)

            rows += bytes((r, g, b, 255))
    return bytes(rows)


def write_png(path, size):
    raw = render(size)
    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)
    print(f"écrit {path.name} ({len(png)} octets)")


if __name__ == "__main__":
    write_png(OUT / "pwa-192x192.png", 192)
    write_png(OUT / "pwa-512x512.png", 512)
    write_png(OUT / "apple-touch-icon.png", 180)
