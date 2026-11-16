#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = ["numpy>=2", "pillow>=11"]
# [tool.uv]
# required-version = ">=0.13"
# ///
"""The stained glass of the windows of the demo's church
(demo/assets/church/church_glass_color.png): a lancet window of jewel
glass, as gothic windows are, in panes large enough that their colors
survive the average the haze and the bounced light make of them. A border of
small alternating panes, three medallions down the middle with a figure of
warm panes in each on a ground of ruby, and a ground of cobalt around them,
all held by dark leading. The color of a pane is what the glass lets through:
saturated and dark, as real pot metal glass. The same seed gives the same
image.

    uv run scripts/demo_church_glass.py [--out demo/assets/church/church_glass_color.png]
"""

import argparse
import math

import numpy as np
from PIL import Image

WIDTH, HEIGHT = 512, 1280  # the window is 1.6 m by 4 m
LEAD = 0.05  # what the leading lets through
SEED = 7

# Pot metal glass, as linear transmission.
RUBY = (0.78, 0.05, 0.05)
COBALT = (0.06, 0.16, 0.78)
AMBER = (0.95, 0.58, 0.07)
EMERALD = (0.07, 0.62, 0.22)
VIOLET = (0.45, 0.10, 0.70)
PALE = (0.92, 0.86, 0.62)
TURQUOISE = (0.08, 0.60, 0.62)


def voronoi_labels(width, height, points):
    ys, xs = np.mgrid[0:height, 0:width]
    best = np.full((height, width), np.inf)
    second = np.full((height, width), np.inf)
    label = np.zeros((height, width), dtype=np.int32)
    for i, (px, py) in enumerate(points):
        d = (xs - px) ** 2 + (ys - py) ** 2
        closer = d < best
        second = np.where(closer, best, np.minimum(second, d))
        label = np.where(closer, i, label)
        best = np.where(closer, d, best)
    # Distance to the edge between the two nearest panes, for the leading.
    edge = np.sqrt(second) - np.sqrt(best)
    return label, edge


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="demo/assets/church/church_glass_color.png")
    args = parser.parse_args()
    rng = np.random.default_rng(SEED)
    ys, xs = np.mgrid[0:HEIGHT, 0:WIDTH].astype(np.float64)
    image = np.zeros((HEIGHT, WIDTH, 3))

    # The ground: cobalt panes, a few turquoise and violet ones.
    points = [(rng.uniform(0, WIDTH), rng.uniform(0, HEIGHT)) for _ in range(70)]
    label, edge = voronoi_labels(WIDTH, HEIGHT, points)
    ground = [COBALT if rng.uniform() < 0.55 else (AMBER if rng.uniform() < 0.55 else (EMERALD if rng.uniform() < 0.5 else TURQUOISE)) for _ in points]
    image[:] = np.array(ground)[label]
    lead = edge < 3.0

    # Three medallions: a ring of amber, a ruby ground and a figure of warm panes.
    radius = WIDTH * 0.34
    for k, cy in enumerate((HEIGHT * 0.22, HEIGHT * 0.5, HEIGHT * 0.78)):
        cx = WIDTH / 2
        r = np.hypot(xs - cx, ys - cy)
        inside = r < radius
        ring = (r > radius - 22) & inside
        figure_points = [(cx + rng.uniform(-0.8, 0.8) * radius, cy + rng.uniform(-0.8, 0.8) * radius) for _ in range(18)]
        f_label, f_edge = voronoi_labels(WIDTH, HEIGHT, figure_points)
        palette = [AMBER, PALE, EMERALD, AMBER, RUBY, PALE, VIOLET]
        colors = np.array([palette[(i + k) % len(palette)] for i in range(len(figure_points))])
        # The figure: an upright body of warm panes in the middle of the medallion.
        body = inside & (np.abs(xs - cx) < radius * (0.32 + 0.25 * np.clip((ys - cy) / radius, 0, 1))) & (np.abs(ys - cy) < radius * 0.78)
        head = np.hypot(xs - cx, ys - (cy - radius * 0.52)) < radius * 0.17
        figure = body | head
        image[inside] = RUBY
        image[figure] = colors[f_label][figure]
        image[ring] = AMBER
        lead |= inside & figure & (f_edge < 2.5)
        lead |= inside & (np.abs(r - (radius - 22)) < 2.5)
        lead |= np.abs(r - radius) < 3.5
        lead |= head & (np.abs(np.hypot(xs - cx, ys - (cy - radius * 0.52)) - radius * 0.17) < 2.5)

    # The border: small squares of ruby and pale glass between two lines of leading.
    band = 30
    in_band = (xs < band) | (xs >= WIDTH - band) | (ys < band) | (ys >= HEIGHT - band)
    along = np.where((xs < band) | (xs >= WIDTH - band), ys, xs)
    squares = (along // band).astype(np.int32) % 2
    image[in_band] = np.where(squares[in_band, None] == 0, RUBY, PALE)
    lead |= in_band & ((along % band) < 3)
    lead |= (np.abs(xs - band) < 2.5) | (np.abs(xs - (WIDTH - band)) < 2.5)
    lead |= (np.abs(ys - band) < 2.5) | (np.abs(ys - (HEIGHT - band)) < 2.5)
    lead |= (xs < 4) | (xs >= WIDTH - 4) | (ys < 4) | (ys >= HEIGHT - 4)

    # Glass is never even: each pane a little lighter or darker across.
    wave = 1.0 + 0.08 * np.sin(xs * 0.031 + ys * 0.017) * np.sin(ys * 0.023 - xs * 0.011)
    image = np.clip(image * wave[..., None], 0.0, 1.0)
    image[lead] = LEAD

    srgb = np.where(image <= 0.0031308, image * 12.92, 1.055 * np.power(image, 1 / 2.4) - 0.055)
    Image.fromarray((np.clip(srgb, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(args.out)
    mean = image.reshape(-1, 3).mean(axis=0)
    print("%s: %dx%d, mean transmission %.3f %.3f %.3f" % (args.out, WIDTH, HEIGHT, *mean))


if __name__ == "__main__":
    main()
