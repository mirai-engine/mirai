#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["openexr>=3.3", "numpy>=2", "pypng>=0.20220715"]
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Turns the brush alphas of Terrain3D (OpenEXR, MIT) into the 16-bit grayscale PNG of
plugins/terrain/editor/alphas, the shapes the terrain tool embeds.

Each one is the mean of its color channels, its range stretched to 0..1, and resized to SIZE on a
side by area averaging. The names stay those of Terrain3D.

Usage: uv run scripts/terrain_alphas.py <Terrain3D>/project/addons/terrain_3d/brushes
"""

import pathlib
import sys

import numpy
import OpenEXR
import png

SIZE = 128


def read(path: pathlib.Path) -> numpy.ndarray:
    with OpenEXR.File(str(path)) as file:
        channels = file.channels()
        planes = [numpy.asarray(channels[name].pixels, dtype=numpy.float64) for name in channels if name in "RGBY"]
        if not planes:
            planes = [numpy.asarray(next(iter(channels.values())).pixels, dtype=numpy.float64)]
    planes = [p if p.ndim == 2 else p.mean(axis=2) for p in planes]
    return sum(planes) / len(planes)


def resize(image: numpy.ndarray, side: int) -> numpy.ndarray:
    height, width = image.shape
    rows = (numpy.arange(side + 1) * height) // side
    columns = (numpy.arange(side + 1) * width) // side
    out = numpy.zeros((side, side))
    for y in range(side):
        band = image[rows[y] : max(rows[y + 1], rows[y] + 1)]
        for x in range(side):
            out[y, x] = band[:, columns[x] : max(columns[x + 1], columns[x] + 1)].mean()
    return out


def main() -> None:
    source = pathlib.Path(sys.argv[1])
    target = pathlib.Path(__file__).resolve().parent.parent / "plugins" / "terrain" / "editor" / "alphas"
    target.mkdir(parents=True, exist_ok=True)
    for path in sorted(source.glob("*.exr")):
        image = resize(read(path), SIZE)
        low, high = float(image.min()), float(image.max())
        image = (image - low) / (high - low) if high > low else numpy.zeros_like(image)
        values = numpy.clip(numpy.rint(image * 65535), 0, 65535).astype(numpy.uint16)
        with open(target / f"{path.stem}.png", "wb") as out:
            png.Writer(SIZE, SIZE, greyscale=True, bitdepth=16).write(out, values.tolist())
        print(f"{path.stem}: {low:.3f}..{high:.3f}")


if __name__ == "__main__":
    main()
