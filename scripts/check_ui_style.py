# /// script
# requires-python = ">=3.11"
# ///
"""Warns when the UI code of the editor writes by hand what the theme defines.

The colors, heights and font sizes of the controls come from `ui.Theme`
(`ui/theme.odin`) and buttons take a `Button_Style`, not a look of their own; a menu is `menu_button`
or `popup` with `menu_item`. Each pattern has a maximum: the existing code that
has not moved to the theme yet. A new line that goes past it fails; when code
is migrated, the maximum goes down.

Usage: uv run scripts/check_ui_style.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Pattern, current maximum and what to use instead.
RULES = [
    (re.compile(r"(?<!:: )ui\.Color\{\d"), 4,
     "a color of ui.Theme, or a named constant of the palette of the domain"),
    (re.compile(r"ui\.button\(.*look=&"), 14,
     "a Button_Style (Ghost, Field, Accent, Tab, Well)"),
    (re.compile(r"(?:ui\.button|ui\.text_field|action_button)\(.*height=2[5-7][,}]"), 0,
     "height=ctx.theme.control"),
    (re.compile(r"(?:ui\.label\(.*,|size=)(?:13\.5|9\.5)[,)}]"), 0,
     "ctx.theme.font_heading or ctx.theme.font_caption"),
    (re.compile(r"ui\.popup\(ctx,[^)]*padding=(?!12\b)[^)]*\)"), 0,
     "the default popup padding (a menu) or 12 (a panel with controls)"),
]


def sources():
    for folder in ("editor", "plugins"):
        for path in sorted((ROOT / folder).rglob("*.odin")):
            if path.name.endswith("_test.odin"):
                continue
            if folder == "plugins" and "editor" not in path.parts:
                continue
            yield path


def main() -> int:
    found = [[] for _ in RULES]
    for path in sources():
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for index, (pattern, _, _) in enumerate(RULES):
                if pattern.search(line):
                    found[index].append(f"{path.relative_to(ROOT).as_posix()}:{number}")
    failed = False
    for (pattern, limit, instead), places in zip(RULES, found):
        if len(places) > limit:
            failed = True
            print(f"{len(places)} uses of /{pattern.pattern}/ (maximum {limit}); use {instead}:")
            for place in places:
                print(f"  {place}")
        elif len(places) < limit:
            print(f"{len(places)} uses of /{pattern.pattern}/: lower its maximum from {limit} to {len(places)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
