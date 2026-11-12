# Zstandard

The Odin files of this folder are a translation of Zstandard **1.5.7**, from
<https://github.com/facebook/zstd>, tag `v1.5.7`, commit
`f8745da6ff1ad1e7bab384bd1f9d742439278e99`. `LICENSE` is kept as `LICENSE.txt`.

It holds the decoder of whole frames and the encoder of levels 3, 6 and 22 of the original. It
leaves out multithreading, dictionaries, legacy formats, streaming and long-distance matching, so
above 64 MiB level 22 does not write what the original does. Up to there the frames are the same,
byte for byte.

To update it, compare the new upstream files with this tag and carry the changes over.

License: Zstandard is distributed under the BSD license or the GPLv2, at the user's choice; Mirai
uses the BSD license.
