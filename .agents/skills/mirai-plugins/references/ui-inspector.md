# UI inspector

Editor-only plugin `ui_inspector` (enabled in demo): opens `.ui` assets as editor documents with
hierarchy, live preview stage, inspector, and API (`plugins/ui_inspector/editor/`:
`ui_inspector_editor.odin`, `api_tree.odin`). Shared headless authoring lives in `cook/author`
(`records.odin`, `records_ux.odin`, `ui_document.odin`, `ui_bindings.odin`, `ui_follow.odin`), so
editor API and [`mirai ui`](../../mirai-agent-api/references/api.md#mirai-ui-and-mirai-scene) run
identical logic.

## Document

- `editor.Asset_Document_Provider` registers `.ui` with its own hierarchy. Every edit records to
  document history (`editor.file_write`); invalid trees (`ui.tree_load` failure) are refused with a
  reason. Undo/redo reloads and selects the changed row (`records_changed_row`); files reload only
  when size/mtime or history cursor change.
- Pending stage gestures flush (`inspector_flush`) on tab switch, Play, and every `.ui` API call.
- On save, track keys sort by time and unreferenced rows prune (`records_tidy`); named styles,
  file animations, and named images (`<img=...>`) stay.
- Transient view state (folds, selection, filter, scroll, stage) lives in `Ui_Inspector.ux`.
  Selected node is the AI chat context (`editor.asset_document_pick`).
- **Hierarchy:** **+ Add** offers node kinds and other `.ui` widgets excluding cyclic ancestors
  (`widget_reaches`). Unfolded instance children are read-only (`Pane.readonly`). **Make widget**
  extracts a `Box` subtree into a sibling `.ui` with parameters for named texts/bindings.
  Copy/paste (`Clip_Nodes`, `records_paste_rows`) reuses destination named styles/animations/fonts/
  widgets by name and copies images/node-anims per node (never self-instancing). **Rename**
  enforces unique node names and updates focus/ghost refs plus overrides in consumer `.ui`s
  (`records_rename`, `widget_rename_follow`); delete clears focus/ghost refs.
- **Preview & Properties:** Builds via `ui.tree_load` + `ui.tree_build` at reference resolution
  (`Tree_Build_Desc.area`) with `Preview_Samples` (missing paths fall back to `{leaf}` text / 3
  list items; floats clip via `ui.Box.clip_floats`). Properties show type-relevant cards, reset to
  `node_default`, grid `grid_tracks`, visibility `Hidden`/`Collapsed`, `{field}` text rows, widget
  overrides (`slot/icon`, copied on enable via `records_override_field`), file animations, and
  localized `.strings` keys ([texts](../../mirai-assets/references/kinds.md#texts), ASCII in
  editor, UTF-8 via `texts.set`; CSV round-trip via `texts.export`/`texts.import`).

### Styles

- Nodes use a named style (`ui.Tree_Style_Info`: name + family `Box`/`Text`/`Control`, ignored by
  game runtime) or **None** (private look; shared unnamed rows copy on first edit).
- Per-type defaults live in `Tree_Style_Info.defaults` (at most one style per node type, matching
  family; not copied on cross-file paste). Without one, first node uses `node_default_look` (boxes
  stay unstyled).
- Editing a node with a named style creates an unnamed override (`extends`, marked `*`); **Apply to
  style** (`records_style_save`) writes it back, **Revert** discards it. Event sounds on shared
  styles prompt node-override vs style. Unused styles delete (`records_style_remove`; overrides
  count as uses).
- Layout never changes per variant/state. State rules store only deltas over base (`look_begin`);
  renaming a variant updates rules/nodes/templates/overrides (`records_variant_rename`). In Edit,
  preview shows the selected node in the last opened state fold.

## Paths

`.ui` files name data paths directly ([data tree](../../mirai-ui/references/ui.md#data-tree)); no
entity-side bindings card exists.

- Pickers filter by `bind_kind`/`type_fits` (existing sources first, then game/engine components
  and storages; `List` starts at element; widgets use `@` for widget `Data`).
- `ui_bindings_check` validates `.ui`s against the open build (full on build change, incremental on
  asset change + consumers, cached widget imports in `imports_cached`), reporting up to
  `BIND_PROBLEMS` per file.

## API

Agents author `.ui` files via JSON documents without opening tabs; fields match `ui.Tree_Node`,
`ui.Node_Style`, and `ui.Tree_Image` (`engine.describe`). Nodes are addressed by name or `#row`.
Invalid writes change nothing and report location (`nodes[0].children[2]: ...`).

- `ui.inspect`: dumps whole `.ui` or `node` subtree as `ui.write`-compatible JSON (`use`, `params`,
  `tokens`, `styles`, `animations`, nested `nodes` with non-default fields).
- `ui.write`: applies document in one history step (creates file if absent; `document=@file` on
  CLI). Nodes match by `(name, kind)` (unnamed by slot) and keep instance overrides; omitted nodes
  delete; omitted fields reset to type default; omitting `nodes` edits only named tokens/styles/
  animations (`null` deletes unused ones). `look` defines inline style (with `extends` for
  override). `key` marks `Localized` (`""` auto-derives key from `text` and writes `.strings`;
  [texts](../../../../docs/game/ui/texts.md)). `use` adds/prunes imported `.ui` libraries (fails if
  still referenced). Paths (`bind_*`, `fields`, `data`, widget params) are validated against game
  types (`document_paths_check`, skipping `@` widget paths). Widget `Tree_Param` changes propagate
  via `widget_params_follow`.
- `ui.capture`: renders `.ui` offscreen at design size × density with `Scene`/`Checker`/`Color`
  background, forced `node` `states`, `variant`, `language`, `family`, and `seconds` elapsed.
- `ui.paths`, `ui.check`, `ui.path.rename`, and `texts.list`/`set`/`missing`/`export`/`import`.

```sh
mirai rpc ui.inspect asset=hud/hud.ui node=hud
mirai rpc ui.write asset=hud/hud.ui document=@hud.json
mirai rpc ui.capture asset=hud/hud.ui background=Checker \
  node=menu states='["Hovered"]' seconds=0.5
mirai texts export texts.csv && mirai texts import texts.csv
```

```json
{
  "styles": {"card": {"family": "Box", "radius": 8, "defaults": ["Box"]}},
  "nodes": [{
    "name": "hud", "kind": "Box", "style": "card",
    "children": [
      {"name": "title", "kind": "Text", "key": "hud.trips", "text": "Trips",
       "bind_text": "trips"},
      {"name": "fuel", "kind": "Progress", "bind_value": "fuel"}
    ]
  }]
}
```

## Document bar

- **Edit:** click selects; handles drag `float.offset` or fixed size with parent/sibling snapping
  (one undo step on release); double-click edits text inline in active stage language.
- **Try:** live pointer/keyboard/gamepad input isolated from editor (`ctx.nav_group`); **Play**
  replays selected node appear animations. Bar also switches background, prompt device, language,
  and reference resolution.

## Project Settings > UI

`UI_Settings` selects the prompt pack ([prompts](../../mirai-imports/references/imports.md#prompts))
and per-action texture overrides (`UI_Settings.prompt_images`, winning over pack).

## Create

Create cards **Interface** (`UI_Screen`), **Panel** (fixed `World_Widget`), and **Billboard**
(camera-facing `World_Widget`) spawn entities bound to the selected `.ui`.

## Verification

- `mirai test cook/author`: `ui_document_test.odin`, `ui_files_test.odin`, `command_test.odin`.
- `mirai test plugins/ui_inspector/editor`: paste, Make widget, preview, `project_files_test.odin`:
  - `a_renamed_node_renames_the_overrides_of_the_interfaces_that_use_its_widget`
  - `the_check_of_interfaces_reads_again_only_what_changed_and_finds_what_the_full_check_finds`
  - `a_write_refuses_the_paths_the_game_lacks_and_changes_nothing`
- Live check in demo editor: `editor.document` + `capture`; manual test for drag/inline edit/Try.
