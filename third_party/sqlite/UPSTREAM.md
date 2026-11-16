# SQLite

SQLite **3.54.1**, the amalgamation `sqlite-amalgamation-3540100.zip` from
<https://www.sqlite.org/download.html>, whose SHA3-256 is
`92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`. `sqlite3.c` and `sqlite3.h`
are copied unmodified. SHA-256 with LF line breaks:

- `sqlite3.c`: `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52`
- `sqlite3.h`: `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c`

`mirai deps` builds the host's static C library with FTS5, multi-thread mode (each connection is
used by one thread, and tests open several at once) and without loadable extensions, deprecated
functions or the shared cache. The editor uses it for the search index of the project chats, so it
lives only in the editor: it does not enter the binary of a game.

`sqlite.odin` binds by hand the functions the editor calls. When updating SQLite, the two files
are copied, the binding is checked against `sqlite3.h` and this note is updated.

License: SQLite is in the public domain.
