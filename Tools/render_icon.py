"""Render the app icon (five colored wavy rings) into AppIcon.appiconset.

Mirrors the ring math in WaterEject/RingOrb.metal, frozen at a fixed pose.
Usage: python3 Tools/render_icon.py
"""

from pathlib import Path

import numpy as np
from PIL import Image

OUTPUT_SIZE = 1024
SUPERSAMPLE = 2
ICON_DIR = Path(__file__).resolve().parent.parent / "WaterEject/Assets.xcassets/AppIcon.appiconset"

PALETTE = np.array([
    [1.0, 0.25, 0.6],
    [0.55, 0.3, 1.0],
    [0.2, 0.5, 1.0],
    [0.2, 0.95, 0.95],
    [1.0, 0.55, 0.3],
])

BASE_RADIUS = 0.6
WAVE_AMPLITUDE = 0.05
PETAL_OFFSET = 0.045
# Half width of the solid line core, in icon units (-1...1).
LINE_WIDTH = 0.0135


def lobes(theta, k, phase):
    """Sine with a fractional lobe count, blended between neighbouring integers so the curve stays closed."""
    k0 = np.floor(k)
    return (1 - (k - k0)) * np.sin(k0 * theta + phase) + (k - k0) * np.sin((k0 + 1) * theta + phase)


def ramp(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def render_rings(n):
    coords = (np.arange(n) + 0.5) / n * 2 - 1
    px, py = np.meshgrid(coords, -coords)
    col = np.zeros((n, n, 3))

    for i in range(5):
        angle = i * 1.2566 + 0.4
        qx = px - PETAL_OFFSET * np.cos(angle)
        qy = py - PETAL_OFFSET * np.sin(angle)
        r = np.hypot(qx, qy)
        theta = np.arctan2(qy, qx)

        dev = 0.65 * lobes(theta, 4 + i * 0.5, i * 1.3 + 0.7) + 0.35 * lobes(theta, 6.4 + i, -i * 1.8)
        ring_radius = BASE_RADIUS + WAVE_AMPLITUDE * dev
        d = np.abs(r - ring_radius)

        blend = (0.5 + 0.5 * np.sin(theta + i))[..., None]
        tint = PALETTE[i] * (1 - blend) + PALETTE[(i + 1) % 5] * blend
        # Crisp, evenly lit core plus a faint halo; a wide gaussian reads as a cheap neon tube.
        intensity = ramp(LINE_WIDTH, LINE_WIDTH * 0.35, d) * 0.95 + np.exp(-d / 0.035) * 0.12
        col += tint * intensity[..., None]
        col += tint * (ramp(ring_radius, ring_radius - 0.5, r) * 0.03)[..., None]

    rings = 1 - np.exp(-col * 1.15)
    radial = np.clip(np.hypot(px, py) * 0.8, 0, 1)[..., None]
    return rings, radial


def to_image(rgb):
    pixels = (np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)
    image = Image.fromarray(pixels, "RGB")
    return image.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.LANCZOS)


def main():
    rings, radial = render_rings(OUTPUT_SIZE * SUPERSAMPLE)

    light_bg = np.array([0.05, 0.06, 0.1]) * (1 - radial) + np.array([0.01, 0.012, 0.02]) * radial
    dark_bg = light_bg * 0.6
    luminance = np.clip((rings @ np.array([0.3, 0.59, 0.11]))[..., None] * 1.6, 0, 1)

    # The light (default) icon must be opaque RGB without alpha.
    to_image(light_bg + rings).save(ICON_DIR / "AppIcon.png")
    to_image(dark_bg + rings).save(ICON_DIR / "AppIcon-Dark.png")
    to_image(np.repeat(luminance, 3, axis=2)).save(ICON_DIR / "AppIcon-Tinted.png")
    print(f"Wrote icons to {ICON_DIR}")


if __name__ == "__main__":
    main()
