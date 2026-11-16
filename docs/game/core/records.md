# Records: catalogs of rows

A catalog (items, enemy kinds, waves, dialogue lines) is a typed table: a `.records` file holds
its type (name, description and columns) and its rows. The build generates the Odin struct of the
rows from the columns; designers and agents edit columns and rows, code reads the rows. Rows are
read-only at run time and are not part of the world: a save keeps only the components that name
them.

## Declare the type

A `.records` that declares its type is the one declaration of it: one file, one table, one type.
Make it with Create > Record in the content browser (an empty table whose type is named from the
file) or with `records.create`, and give it columns in its document (the `+` after the last
header; a click on a header edits that column) or with `records.column.add`. A column has a name,
a kind and the options of its kind:

| Kind | Field the build writes | Options |
| --- | --- | --- |
| `int`, `float` | `i32`, `f32` | min, max, unit |
| `bool` | `bool` | |
| `enum` | an enum the build generates | its name and its values |
| `asset` | `base.Asset_Id` | the extensions it takes (`.tex`) |
| `text` | `core.Text`: a key of the `.strings` | |
| `string` | `[N]u8`, a text of the row itself | its bytes |
| `record` | `core.Record(T)`: a row of a table of `T` | the record type |
| `type` | a type the code of the package declares | the type |

Every kind takes a count (a fixed array of that many values), a default (what a new row holds)
and a description. The build writes `records_gen.odin` into the package the assets go with
(`game/` for the project, `runtime/` of a plugin): the struct, its `NAME_DEFAULT` and the enums.
Game code uses the type as if it were written by hand:

```odin
// items.records declares Item: stack (int, min 1, default 1), value (float), label (text)

@(component)
Pickup :: struct {item:core.Record(Item)}   // names a row: its table and its row id

@(step="fixed")
game_pickups :: proc(pickups:^core.Table(Pickup,.Read),items:core.Records(Item),
                     problems:^core.Problems) {
    for row in 0..<core.count(pickups) {
        ref:=core.at(pickups,row).item
        item,found:=core.record(items,ref,problems,core.entity_at(pickups,row))
        if !found {continue}
        // item.stack, item.value
    }
}
```

- A type of the code a `type` column holds is plain data like a `persist` storage: no `Entity`,
  strings, pointers or dynamic arrays.
- `core.record` reports `records.missing` on the entity when the table or row is gone; the zero
  reference names no row and reports nothing. `core.record_get` looks without reporting.
- Walk every row: `core.records_count(items)` and `core.records_at(items, i)` (value and ref).
- Text of a row: a `core.Text` holds a key of the `.strings` (`{"label":{"key":"item.sword"}}`
  in `records.set`), and `core.text(texts, item.label, language)` gives what it says, with
  `texts:^core.Texts` a parameter of the function: [texts](../ui/texts.md).
- Rows load the first time a function asks and again when a file changes, also during Play.
  `core.records_generation(items)` changes on each load: rebuild what you derived from rows then.

## Rows of a type another table declares

A plugin declares its record types in its own assets (the abilities plugin, `Ability`); a game
holds its rows in tables of its own: `records.create` with `rows_of`. Such a table has no columns:
its document shows those of the declaring table, which change there.

## Author with the API

With an editor session: `records.types` lists the record types with their columns and tables;
`records.create` makes a table; `records.column.add`, `records.column.set` and
`records.column.remove` change the columns; `records.add` and `records.set` write rows by field
name; `records.import` and `records.export` move a CSV whose header is `name` and the paths of
the fields.

## Pitfalls that fail silently

- State that changes in play (stock, flags, progress) is a component that names rows, never a
  write into a row.
- The editor edits a new column at once; the game sees it once the game library builds again.
- Renaming a column keeps its values: the file keeps the names it had. A new column starts at its
  default in the rows there are.
- Writing to the copy `core.record` returns changes nothing: rows are shared by all worlds.
- A record type name is unique in the project and its plugins: two tables that declare one name
  are a build error. A struct written by hand with `@(record)` is a build error too: its schema
  lives in its `.records`.
