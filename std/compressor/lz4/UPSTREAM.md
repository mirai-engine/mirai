# LZ4

The Odin files of this folder are a translation of LZ4 **1.10.0**, from
<https://github.com/lz4/lz4>, tag `v1.10.0`, commit
`ebb370ca83af193212df4dcbadcc5d87bc0de2f0`. `lib/LICENSE` is kept as `LICENSE.txt`.

It holds `LZ4_decompress_safe` and `LZ4_compress_HC` for levels 3 to 12, whose blocks are the same,
byte for byte, as the original's. `lz4.odin` comes from `lib/lz4.c` and `lz4hc.odin` from
`lib/lz4hc.c`.

To update it, compare the new upstream files with this tag and carry the changes over.

License: the files of `lib/` are distributed under the BSD 2-Clause license.
