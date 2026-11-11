# std/serial

Little-endian streams with varints (`stream.odin`), files with atomic writing (`file.odin`),
binary schemas (`schema_binary.odin`), value image and migration (`value.odin`), paths
(`path.odin`), references to entities and assets (`refs.odin`) and schema-guided JSON
(`text.odin`).

- `Writer` grows with its allocator or is fixed over a buffer; what does not fit is counted in
  `overflow`. `Reader` never reads outside: the first read that does not fit sets `failed` and the
  following return zero; `read_count` rejects a count that the remaining input cannot back.
- `text_write` omits `Transient` fields by default; `omit_fields={}` includes everything for
  inspection and `{.Transient,.Hidden}` gives the public view of components, also inside structs and
  arrays. Binary persistence does not change.

**Schema read from a file.** `schema_read` validates that a type only refers to earlier types (up
to `SCHEMA_MAX_DEPTH`), that fields follow one another without overlapping inside the struct, that
sizes and choices are those of real types (up to `SCHEMA_MAX_SIZE`) and that a 0-byte struct or
element has no fields: an accepted schema can be walked with values of the declared size without
leaving them. A schema read and written again gives the same bytes: the high nibble of the type
byte keeps how an integer names its values or its bits (`Named_Kind`) and whether it moves by
them (`by_name`), with its choices, and an empty list of fields or choices is written as 0,
wherever it points.

**Out of memory.** It is distinguished from an invalid file, so a load can be retried.
`schema_read`, `schema_validate` and `migration_init` return `Out_Of_Memory` and free what is
partial; `asset_open`/`asset_load` propagate it as `asset.Error.Out_Of_Memory`.
`schema_hashes_update` and `schema_import` fail without publishing an incomplete state, and the
types already copied are reused on retry. The caller calls `migration_destroy` also after a
failure; an existing column keeps its data if the preparation of its migration fails.

**Invalid inputs.** No `std/serial` function ends the process because of what it receives: a type
index foreign to the schema gives an empty result or an error, a size that overflows `int` is
counted in `overflow`, an alignment that is not a power of two fails without writing, and
`refs_visit` visits nothing if the data does not suffice. `hostile_test.odin` tests it with random
inputs.

**`requires`.** The tag `mirai:"requires=Camera"` on an `Entity` field keeps the hash of the
required component in `Field.required_component`; it travels in the binary schema, imports and
clones, and is invalid on another field type. It is authoring metadata: the document validates
assignments and the inspector filters candidates.

**Image.** The stored value is its memory under its schema, with padding, `transient` fields and
text tail at zero. If the stored type and the program's have the same `schema_layout_hash`, it is
copied as a block or used in place.

**Migration** (`Migration`, compiled once per pair of types and applied per row):

- Fields are paired by name, or by a name the destination field had: the tag `was=` lists them
  (`mirai:"was=strength power"`), so a value stored before a rename, or before several, is read.
  An earlier name that is another field of the struct is refused when the type is added. The
  names are in the binary schema (a struct with renames, or with renamed fields, carries them;
  any other is written as if there were none), so a source that had the destination's name
  pairs too: a file of a newer layout reads into an older one. `path_resolve` takes them as well.
- One without a source keeps the default given by whoever reads (zero if none is given). One
  without a destination is lost, and `Migration.removed` lists it by its path, as
  `Migration.incompatible` lists the fields whose shapes do not convert; whoever reads a document
  reports both (scene loads: `engine/scene` `Stored`).
- Numbers are converted by value and saturate in the destination's range (NaN to integer is 0);
  bool is nonzero.
- Enums and bit sets go by member name: a member the destination does not have leaves the default
  (enum) or is discarded (bit set). An integer is converted to the enum with that value, if it
  exists.
- An integer with names keeps its number, and its names are not its layout, unless its numbers are
  generated (`by_name`, the input actions and their masks): then its names are its layout and it
  goes by name like an enum or a bit set; a mask with every bit set (all the actions) stays full.
- Arrays keep the elements both lengths have. A text keeps the bytes that fit and the rest is left
  at zero.
- Incompatible shapes (struct against scalar, array against scalar, `Asset` against something else)
  leave the default. The destination's `transient` fields end at zero.

**Paths.** `"a.b[2].c"`; the name after a bit set is a member (bool). A text value is the member of
an enum or the text of a text field. `value_set` requires the number to fit exactly.

**Checking a value.** `value_check` names, by its path, the first part of a value the schema does
not allow: a float that is not finite, a number outside the `min`/`max` of its field (each element
of an array field), a bool, enum or bit set with no value of its type, or a reference its visitor
refuses. Whoever takes values from outside (an untrusted scene) checks them with it, after reading.

**Text.**

- Fields in schema order, enums by name, bit sets as a list of names, ids in hexadecimal (`"0x…"`
  of 16 digits; assets 32 digits), texts as strings. An array of texts (`[N][M]u8`,
  `type_is_texts`) is a list of strings (with `trim`, without the trailing empty ones), and the
  API's JSON Schema gives it as an `array` of `string`.
- What JSON cannot say exactly has a form of its own: floats `"nan"`, `"inf"`, `"-inf"` or
  `"bits:0x…"`; an enum without a member for its value is its number; a bit without a member is its
  index; a text that is not UTF-8 is the list of its bytes. Reading what was written returns the
  same bytes.
- On reading, an absent field keeps what it had and an unknown field is an error.
- **Read errors.** `Text_Error` keeps the code, the offset, where in the value (`path`;
  `text_error_within` prepends the field or section of whoever reads on their own) and, for a name
  the type does not have, those it has, copied into the reader. `text_error_message` is the only
  text for people and agents, in English (`exposure.adaptation_mode: "Slow" is not one of Time,
  Speed`), and leaves the position to `text_position`.
