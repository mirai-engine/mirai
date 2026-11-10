# Texts in several languages

The languages of a game and the one its interfaces are written in are in Project Settings > UI.
A node of a `.ui` says its `text` in that one and, in `translations`, in each other language by
its code, the codes a `.strings` uses. It is part of the document of
[writing-ui.md](writing-ui.md):

```json
{"name": "start_game", "kind": "Button", "text": "Start",
 "translations": {"es": "Empezar", "pt-BR": "Iniciar"}}
```

- A node with `translations` is localized, `{}` included: translators fill it in later. A language
  left out, or with an empty text, has none and shows `text`. A node without `translations` is
  not localized.
- A translation of a text with braces names the same fields: `"Puntos: {coins}"` for
  `"Score: {coins}"`.
- `ui.inspect` also gives `text_id`, 16 hexadecimal digits: the id a row of the CSV finds its text
  by. Leave it out when writing: the node keeps its own, and one that becomes localized gets one.
  A copy of a node does not take the `text_id` of the other: a text is not shared between nodes,
  and `ui.write` refuses two with one id.
- A code that is of no language a game can be in is refused, with the codes there are.

`mirai texts export|import <file.csv> --project .` moves every localized text of the project
through a CSV for translators, and `ui.text.set` changes one text in one language.

Texts that are not of a node (a name the code builds, a line of dialogue) go in a `.strings`,
by key and language: [assets](../assets.md).
