# `mirai asset`

Reads and edits binary assets of any type through the schema each file carries: it has no
per-format code, so a new type or a plugin's type works unchanged. Implementation:
`tools/mirai/asset.odin` over `asset.Document`; `mirai asset` without arguments lists the
subcommands with their usage.

- Results go to **stdout** in stable forms for parsing; errors to **stderr** as
  `mirai asset <subcommand>: <file>: <reason>`.
- **Exit codes:** 0 done; 1 failed, found differences (`diff`) or problems (`ls`, `verify`,
  `deps`); 2 incorrect usage (in `diff`, also a file that cannot be read).

## Subcommands

- `info` says whether the hash matches (`ok` or `MISMATCH`); `ls` reads only headers and appends
  the problems at the end (`! broken`, `! duplicate`, `! missing`); `dump` does not show the data of
  `Bulk` tables ([JSON shape](formats.md#text)).
- **`verify`** checks container, hash, decompression, schema and tables, that the stored
  dependencies are the derived ones and that each value meets its schema. For the engine's types it
  checks their version (for one the build does not read, the reason is `version_message`, with the
  `mirai import` that rebuilds it; one older than the build's that it migrates passes, with
  `version_notice` after `ok`) and their rules (`*_check`). For a `.ui` it only checks the tree's structure
  (`asset.ui_check`): the rest is validated on loading it ([interface](kinds.md#interface)).
- **`set`** rewrites the file atomically, with the dependencies recomputed; if an assignment fails
  nothing is written. The value is JSON of the field's type; from a shell, texts, enum members and
  ids need no quotes, and in a struct the unnamed fields are kept. A number must fit exactly in its
  field. It neither adds nor removes rows: for that, `unpack`, edit and `pack`.

  ```sh
  mirai asset set level.scene 'Light[@0x20].value.intensity=7.5' 'entities[@0x20].name=Lamp'
  mirai asset set level.scene 'Transform[@0x30].value={"position": [9, 8, 7]}'
  mirai asset set leaf.mat material.alpha_mode=Blend material.maps.normal.uv_set=1
  ```

- **`diff`** pairs rows by key (or by the key of the referenced row), not by position, and fields
  by name through each file's schema, comparing values as text: two scenes with the same entities
  in another order, or two files with different layouts and the same values, do not differ. `Bulk`
  tables are compared whole.

## Paths

```text
mesh.bounds_min[0]                     one-row table: field and element
levels[1].triangle_count               row by position
entities[@0x1f].name                   row by key
Transform[@0x1f].value.position        row by the key of the row it refers to (the entity)
Light                                  whole table
Light[0]                               whole row
mesh.flags.Skinned                     a bit set member, as bool
```

- After the row goes the column name, except when the table has a single unnamed column (`mesh`,
  `levels`, `triangles`).
- The key is written in hexadecimal with or without `0x` (entity ids and integers), with 32 digits
  (asset ids) or as text (text columns). Component tables have no key of their own: `[@id]` finds
  the row whose `entity` column points to that entity.
- Path and value errors give the column of the character with the problem.

## `merge`

It is the git merge driver for assets: `.gitattributes` with `*.scene merge=mirai` and
`merge.mirai.driver = "<engine>/mirai" asset merge %O %A %B` in the repository configuration. It
writes the result to `<ours>` (or `--out`) and one line `! <type> <path>` per conflict. Code 1 with
conflicts; 2 if a file is not an asset or the result is not valid, and then `<ours>` stays as it
was.

- Rows are paired as in `diff` and values field by field: a field that one side left as it was in
  `<base>` takes the other's. A vector is a whole value. A column whose type only theirs changed
  (a component that gained or lost a field) takes theirs' type first, so a field only theirs added
  keeps its values.
- In a conflict, ours stays; git leaves the file as unresolved with the three versions in the
  index.
- A row that one side removed goes away if the other did not change it; if it changed it, or hung
  rows from it, it stays and is a conflict. What the other side added under something ours removed
  does not enter.
- Without a key, a table is a set of rows; a `Bulk` table is compared whole. An empty `<base>` is a
  file both added: every difference is a conflict.
- In scenes and prefabs (`asset.scene_merge`): a removed parent leaves the child at the root, a
  cycle between the two sides is opened with ours' parent, the instances theirs added with an id
  that ours already gave take a new one (with their members and overrides), and the `Scene_Info`
  counters end at the larger.

## Editing by `unpack`/`pack`

`asset.json` is the complete asset (with schema), next to one file per bulk column: rows of `data`
can be added or removed, values or columns changed. `pack` of an unedited `unpack` gives the same
bytes.

- Read order: `"schema"` before `"tables"`; in a table, `"name"`, then `"columns"`, then `"data"`.
- `"rows"` must match the rows; a bulk file must measure rows × size. Bulk file names are names,
  never paths.
- Errors come out as `asset.json:<line>:<column>: <reason>`.
