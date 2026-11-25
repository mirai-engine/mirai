# stb_vorbis

stb_vorbis **1.22**, from <https://github.com/nothings/stb>, as Odin ships it in
`vendor/stb/src/stb_vorbis.c` (Odin commit `9a6991685ddf663956d9836602eb421e141fc443`), copied
unmodified. SHA-256 with LF line breaks:

- `stb_vorbis.c`: `038be19482188a9730869923d5f58ce21dab3c7c612e714419799b68397d4588`

`shared.c` is Mirai's: it includes `stb_vorbis.c` and adds a decoder that shares the setup of
another one (`stb_vorbis_open_shared`, `stb_vorbis_shared_memory_required`), and the place of the
audio of an open decoder (`stb_vorbis_get_place`). The audio keeps one decoder per distinct setup
header, never decoded with, and gives every voice a shared decoder in a workspace of its feed:
the codebooks, floors, residues, mappings and transform tables of the setup are only read after
it is opened, so many decoders read them at once. A shared decoder holds the channel buffers, the
previous window and the floor of each channel and the workspace of a packet.

`mirai deps` builds the host's static C library from `shared.c` alone, without stdio, the push
API or the integer conversions, and with two channels at most (`tools/mirai/deps.odin`). `audio`
uses it, so it enters the binary of a game.

`stb_vorbis.odin` binds by hand the functions the audio calls. When updating stb_vorbis, the file
is copied, `shared.c` is checked against the fields of `struct stb_vorbis` it sets, the binding
against the declarations, and this note is updated.

License: stb_vorbis is available under the MIT license or in the public domain, at the user's
choice (the end of `stb_vorbis.c`); Mirai uses the MIT.
