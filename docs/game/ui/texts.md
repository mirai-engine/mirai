# Texts in several languages

Every text a player reads in their language is a key of the `.strings` of the project, whoever
shows it: a node of a `.ui`, a `core.Text` field of a row ([records](../core/records.md)) or the
code. The languages of a game and the one its texts are written in are in Project Settings > UI.

A node of a `.ui` shows a key with `key`, and says beside it, in `text`, what the key says in the
language texts are written in. It is part of the document of [writing-ui.md](writing-ui.md):

```json
{"name": "start_game", "kind": "Button", "text": "Start", "key": "menu.start"}
```

- Writing the document makes the key say that `text`, for everything that shows the key. A `key`
  without `text` shows what the key already says. A node without `key` is not localized: its
  `text` is the same in every language.
- `"key": ""` makes the key from the text: its ASCII letters and digits in lowercase, each run of
  anything else a `_`, a long one cut at a whole word (`"Score: {coins}"` is `score_coins`).
  Nodes that say the same text share that key. Where a key of that name already says another
  text, the name takes the next number: `start`, `start_2`. `ui.inspect` gives the key back, and
  it stays when the text changes; name the key yourself when one text needs two translations.
- A text with braces names the same fields in every language: `"Puntos: {coins}"` for
  `"Score: {coins}"`.
- A language that lacks a key shows what the key says in the first language of its `.strings`,
  the one texts are written in. A key no `.strings` has shows as the key itself.

```sh
mirai texts list --project .
mirai texts set menu.start es "Empezar" --project .
mirai texts missing --project .
mirai texts export texts.csv --project .
mirai texts import texts.csv --project .
```

- `set` adds a key or translates one; a key no `.strings` has goes to `texts.strings` at the root
  of the assets. A key is in one `.strings`: with two, the game reads the first by path.
- `missing` lists who shows a key no `.strings` has, with its document and its node or its row
  and field, and the keys that say nothing in a language of the game.
- The CSV has the column `key` and one per language by its code, the one texts are written in
  first; an import changes nothing where a cell is empty.
- With the editor open, `texts.list`, `texts.set`, `texts.missing`, `texts.export` and
  `texts.import` do the same on what it holds unsaved.

From code, a function of the loop receives `texts:^core.Texts` and asks with the language of the
player:

```odin
language:=gui.ui_language(ui_settings.ptr,preferences)
title,found:=core.text(texts,"menu.start",language)   // or a core.Text field of a row
```

What is made of a text is made again when `texts.generation` changes.
