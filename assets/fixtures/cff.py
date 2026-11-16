#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools>=4.40"]
# ///
"""Writes cff.otf next to this file: an OpenType font with CFF outlines and a few glyphs of
rectangles, enough for the tests of the fonts of ui and of the .font importer.

A, H and ? are Latin, alpha Greek and Zhe Cyrillic. The kern feature has one pair for the Latin
script (A A) and one for the Cyrillic script (Zhe alpha), so that a reader that only takes the
lookups of 'latn' misses the second.

Usage: uv run assets/fixtures/cff.py
"""

import os

from fontTools.fontBuilder import FontBuilder
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.pens.t2CharStringPen import T2CharStringPen

GLYPHS = {
    # name: (code point, advance, rectangles x0, y0, x1, y1)
    ".notdef": (None, 500, [(50, 0, 450, 700)]),
    "space": (0x20, 250, []),
    "question": (0x3F, 500, [(100, 300, 400, 700), (200, 0, 300, 100)]),
    "A": (0x41, 600, [(50, 0, 150, 700), (450, 0, 550, 700), (150, 300, 450, 400)]),
    "H": (0x48, 700, [(50, 0, 150, 700), (550, 0, 650, 700), (150, 300, 550, 400)]),
    "alpha": (0x3B1, 550, [(50, 0, 500, 500)]),
    "Zhe": (0x416, 800, [(50, 0, 750, 100), (350, 0, 450, 700)]),
}


def charstring(advance, rectangles):
    pen = T2CharStringPen(advance, None)
    for x0, y0, x1, y1 in rectangles:
        pen.moveTo((x0, y0))
        pen.lineTo((x0, y1))
        pen.lineTo((x1, y1))
        pen.lineTo((x1, y0))
        pen.closePath()
    return pen.getCharString()


def main():
    order = list(GLYPHS)
    builder = FontBuilder(1000, isTTF=False)
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap(
        {code: name for name, (code, _, _) in GLYPHS.items() if code is not None})
    names = {"familyName": "Mirai CFF Test", "styleName": "Regular"}
    charstrings = {name: charstring(advance, shape) for name, (_, advance, shape) in GLYPHS.items()}
    builder.setupCFF("MiraiCFFTest-Regular", {"FullName": "Mirai CFF Test"}, charstrings, {})
    builder.setupHorizontalMetrics({name: (advance, 0) for name, (_, advance, _) in GLYPHS.items()})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable(names)
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    addOpenTypeFeaturesFromString(builder.font, """
        languagesystem DFLT dflt;
        languagesystem latn dflt;
        languagesystem cyrl dflt;
        feature kern {
            script latn;
            pos A A -50;
            script cyrl;
            pos Zhe alpha -120;
        } kern;
    """)
    builder.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cff.otf"))


if __name__ == "__main__":
    main()
