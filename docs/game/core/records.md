# Records: catalogs of rows

A catalog (items, enemy kinds, waves, dialogue lines) is a struct the code declares and rows that
live in `.records` files. Designers and agents edit rows; code reads them. Rows are read-only at
run time and are not part of the world: a save keeps only the components that name them.

## Declare and read

```odin
@(record,description="A kind of item: how many fit a slot and what it is worth.")
Item :: struct {
    stack:i32 `mirai:"min=1"`,
    value:f32,
    label:core.Text,              // a localized text of the row
}
ITEM_DEFAULT :: Item{stack=1}

@(component)
Pickup :: struct {item:core.Record(Item)}   // names a row: its table and its row id

@(step="fixed")
game_pickups :: proc(pickups:core.Read(Pickup),items:core.Records(Item),problems:^core.Problems) {
    for row in 0..<core.count(pickups) {
        ref:=core.at(pickups,row).item
        item,found:=core.record(items,ref,problems,core.entity_at(pickups,row))
        if !found {continue}
        // item.stack, item.value
    }
}
```

- A record is plain data like a `persist` storage: no `Entity`, strings, pointers or dynamic
  arrays; references to other rows are `core.Record(T)` fields, texts are `core.Text`.
- `core.record` reports `records.missing` on the entity when the table or row is gone; the zero
  reference names no row and reports nothing. `core.record_get` looks without reporting.
- Walk every row: `core.records_count(items)` and `core.records_at(items, i)` (value and ref).
- Text of a row: `core.record_text(items, item.label, language)`; `language` is
  `base.name_hash("en")`, or 0 for the language the game is written in.
- Rows load the first time a function asks and again when a file changes, also during Play.
  `core.records_generation(items)` changes on each load: rebuild what you derived from rows then.

## Author the rows

With an editor session (`engine.describe` for fields): `records.types` lists the record types,
`records.create` (or `asset.create` kind `records`) makes a table, `records.add` and
`records.set` write rows by field name, `records.import` and `records.export` move a CSV whose
header is `name` and the paths of the fields, then `asset.save`.

## Pitfalls that fail silently

- State that changes in play (stock, flags, progress) is a component that names rows, never a
  write into a row.
- A field added to a record starts at its `NAME_DEFAULT` in old rows; a renamed one starts over.
- Writing to the copy `core.record` returns changes nothing: rows are shared by all worlds.
- A record type must be declared once per package; two with the same name are a generator error.
