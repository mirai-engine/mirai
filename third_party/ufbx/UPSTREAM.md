# ufbx

ufbx **0.23.1**, from <https://github.com/ufbx/ufbx>, tag `v0.23.1`, commit
`26a482ae66871d7de36eb722aa060bce95bce274`. `ufbx.c`, `ufbx.h` and `LICENSE` (as `LICENSE.txt`)
are copied unmodified. SHA-256 with LF line breaks, as the repository stores them:

- `ufbx.c`: `4a956c26a708e40d82ecb0aeaee54da709d5ba7c144c9642174970059bda7e1d`
- `ufbx.h`: `f787be529af577efc04f3e3e735844a08556718dbb613d1211c2b313d72895dc`
- `LICENSE.txt`: `0dd48ebadf52273c736256325c8f078c03c8bb4facee22a4122de0ad3f615391`

`mirai deps` builds the host's static C library without own definitions. `cook/import/fbx` uses
it, so it lives only in the editor and in `mirai-import`: it does not enter the binary of a game.
The editor exports every procedure of a `foreign` block, so the library is built whole, without
the `UFBX_NO_*` options that remove functions.

`ufbx.odin` is the binding of the whole API and is not edited: it is written by
`uv run scripts/ufbx_binding.py <ufbx checkout>` with the bindgen of that checkout
(`bindgen/ufbx_parser.py` and `bindgen/ufbx_ir.py`), which must be of the version in this folder.
When updating ufbx, the three files are copied, the binding and its `#assert` of sizes and offsets
are generated, and this note is updated.

License: ufbx is distributed under the MIT or as public domain (Unlicense), at the user's choice;
Mirai uses the MIT.
