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
  `Bulk` tables ([JSON shape](formats.md#text)), and `dump --textconv` prints the text
  [git diffs](#git).
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

It is the [git merge driver](#git) for assets. It writes the result to `<ours>` (or `--out`) and
one line `! <type> <path>` per conflict. Code 1 with conflicts; 2 if a file is not an asset or the
result is not valid, and then `<ours>` stays as it was.

- The result is checked as `verify` does when `<ours>` passed it: rows of a kind may name rows of
  another table by position or by what they hold, which a merge of rows does not follow, so a
  result that breaks the rules of its kind is not written.

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

## Git

**Document kinds merge and diff through `mirai`; the other kinds are whole files to git.** Which
is which is one fact per kind: `asset.Kind_Info.merged` for a kind of the engine and `merged` in
the `asset_kinds` of its `plugin.mirai` for one a plugin adds, which is read without loading the
plugin. A document is rows that a person or an agent edits; what an import, a bake or a recording
makes is kept whole.

- `build.git_attributes` (`cook/build/git.odin`) writes the `.gitattributes` from those facts: a
  document kind gets `merge=mirai diff=mirai -text`, the others `binary`, or the LFS filter with
  the sources of imports when the repository uses LFS. It keeps the lines of other files, so it
  can run over a file a person edited. The plugin kinds are those of the plugins the repository
  holds or uses (`build.git_plugin_kinds`): every plugin under `plugins/` of a checkout of the
  engine, the plugins a project uses. `mirai new`, `mirai setup git` and the editor's
  [Initialize](../../mirai-editor/references/git.md#operations) write it; after a project starts
  to use a plugin that adds a kind, `mirai setup git` adds its line and `mirai doctor` says when
  one is missing.
- The drivers live in the local configuration of each clone, so **every clone runs
  `mirai setup git [folder]` once** (`build.git_setup`): `merge.mirai.driver` is
  [`mirai asset merge`](#merge) and `diff.mirai.textconv` is `mirai asset dump --textconv`, so
  `git diff` and `git log -p` show the changed rows. It writes only what differs and can run
  again at any time. A clone without them still works: git takes those files whole, and
  `mirai doctor` says so.
- A driver names the tool as `./mirai` in a checkout of the engine, whose launcher is at the top
  git runs drivers from: one line serves every clone and worktree. In another repository it is the
  absolute path of the engine, so after moving the engine `mirai setup git` runs again; the editor
  does the same on each state read.
- `dump --textconv` differs from `dump` in what would change without a value changing: a row names
  the row it refers to by its key, not by its position, and a column leaves out the index of its
  type. A file the build does not read prints one line that says why and ends with 0, so a log
  that reaches one goes on. `pack` does not read this text.
