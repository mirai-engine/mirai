# FreeType

FreeType **2.14.3**, from
[freetype-2.14.3.tar.xz](https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz).
SHA-256 of the downloaded file:
`36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f`. The signature
`freetype-2.14.3.tar.xz.sig` verifies with Werner Lemberg's key
(`E30674707856409FF1948010BE6C3AAC63AD8E3F`).

`include/`, the modules `src/base`, `src/sfnt`, `src/truetype`, `src/cff`, `src/psaux`,
`src/pshinter`, `src/psnames`, `src/smooth` and `src/autofit`, `LICENSE.TXT` and `docs/FTL.TXT`
(as `FTL.TXT`) are copied unmodified. The rest of the package is not used.

`config/freetype/config/` replaces the configuration of `include/`, because it comes first in the
include path:

- `ftmodule.h` registers only the auto-hinter, the TrueType and CFF drivers (OpenType with
  PostScript outlines, which needs `psaux`, `pshinter` and `psnames`), `sfnt` and the `smooth`
  rasterizer.
- `ftoption.h` is that of 2.14.3 with these options commented out: `FT_CONFIG_OPTION_*`
  `ENVIRONMENT_PROPERTIES`, `USE_LZW`, `USE_ZLIB`, `ADOBE_GLYPH_LIST`,
  `MAC_FONTS`, `GUESSING_EMBEDDED_RFORK`, `INCREMENTAL` and `SVG`, and `TT_CONFIG_OPTION_*`
  `EMBEDDED_BITMAPS`, `COLOR_LAYERS`, `BYTECODE_INTERPRETER`,
  `SUBPIXEL_HINTING`, `GX_VAR_SUPPORT` and `BDF`. Without a bytecode interpreter, the TrueType
  driver does not hint and its glyphs go through the auto-hinter; those of CFF, through the CFF
  hinter in light mode. `FT_CONFIG_OPTION_POSTSCRIPT_NAMES` and
  `TT_CONFIG_OPTION_POSTSCRIPT_NAMES`, which `sfnt` asks for with the first one, stay active: the
  CFF driver does not open a font without the `psnames` service.

License: FreeType is distributed under the FreeType License (`FTL.TXT`) or the GPL v2, at the
user's choice; Mirai uses the FTL.

`mirai deps` builds the host's static C library with `FT2_BUILD_LIBRARY`. `ui` uses it, so it
enters the binary of a game; `freetype.odin` is the binding of the part of the API that the atlas
uses.
