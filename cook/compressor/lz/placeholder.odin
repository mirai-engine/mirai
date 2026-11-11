package lz_optimal

import "mirai:std/compressor"
import "mirai:std/compressor/lz"

// See std/compressor/placeholder.odin.
// The packs of a cook name the levels the open codecs take theirs from (asset.codec_level).
when !#exists("implemented.odin") {
    IMPLEMENTED :: false
    SHIP :: lz.Mode{level=compressor.LEVEL_OPTIMAL5}
    QUICK :: lz.Mode{level=compressor.LEVEL_OPTIMAL1}
}
