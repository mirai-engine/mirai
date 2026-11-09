# UI inspector

Plugin `ui_inspector` (`Editor` only, enabled in the demo): it opens a `.ui` as an editor
document, with its tab like that of a material, shows it as the game builds it and edits
everything the file stores. Code in `plugins/ui_inspector/editor/`: the provider and the reading
and writing of the file in `ui_inspector_editor.odin`, each operation on the records in
`records.odin` and `records_ux.odin`, the hierarchy, the stage, the properties, the states, the
texts and the paths in their own file, and the authoring API in `api_tree.odin`.

## Document

- Its provider (`editor.Asset_Document_Provider`) declares the type and that it has its own
  hierarchy. Each change enters the document's history (`editor.file_write`) and Save writes the
  file with `host.ui_tree_save`; records that `ui.tree_load` rejects are not saved, and the
  warning says why. An undo or a redo reads the file again and chooses the node that changed
  (`records_changed_row`); the file is re-read only when its size and time or the history cursor
  change, not after its own write.
- What a gesture leaves pending goes to its document's history (`inspector_flush`) before another
  document comes to the front, on Play and on each API call that reads or writes a `.ui`.
- On writing, the keys of each track are left in time order and the rows that nothing uses go away
  (`records_tidy`); named styles, the file's animations and named images (for `<img=...>`) stay.
- What the person does without changing the file (folds, selection, rename in progress, filter,
  gesture on the stage) lives in `Ui_Inspector.ux`; what is folded is stored per document and per
  node name, and each open `.ui` stores its chosen node, its scrolls and its stage.
- The chosen node is the AI chat's context while the document is in front
  (`editor.asset_document_pick`).

### Hierarchy

- The list button of the left panel shows the nodes of the `.ui` in front (or the entities of the
  scene if the front is a scene). **+ Add** offers the node types and the other `.ui`s as an
  instance, except a widget that has this `.ui` inside (`widget_reaches`): it would contain
  itself. The nodes of an unfolded instance are read-only (their own document changes them).
- Copy, Paste, Duplicate and Delete act on all the chosen ones (a node inside another chosen one
  goes with it). **Make widget** moves a Box and what it has into a new `.ui` next to the file,
  unsaved, with a parameter per named text or binding, and puts a use in its place: what is
  reusable is another `.ui`.
- Copy stores the nodes as records of their own (`Clip_Nodes`) with the rows and texts that they
  use, so they paste into any `.ui` (`records_paste_rows`, `merge_put`): a named style of the same
  family, an animation with the same name, a font or a widget are those of the destination if it
  has them; images and node animations are copied per node, so that the copy is edited on its own.
  A `.ui` does not paste itself as an instance.
- **Rename** rejects a name that another node has, because names find nodes (overrides, focus,
  events). What named it follows it: the focus and the ghost of the other nodes and, on writing,
  the overrides of the `.ui`s that instance it, also through other widgets, one step per file
  (`records_rename`, `widget_rename_follow`). Deleting a node empties the focus and the ghost that
  named it.
- Dragging a row moves the node (and the chosen ones with it): before, after or, in the center of
  a container, inside.

### Preview

- It builds the tree with `ui.tree_load` and `ui.tree_build` at the chosen reference resolution,
  scaled to the stage, which acts as the safe area (`Tree_Build_Desc.area`).
- There is no world to read: the paths read samples of the game types (`Preview_Samples`) and each
  node type shows something legible (`samples_shown`). If the game does not have a path of the
  `.ui`, the tree is built without values: a bound text shows the last name of its path between
  braces and a bound list three elements.
- Fonts are loaded as in the game; what falls outside the preview is clipped
  (`ui.Box.clip_floats`), and the game floats over the background so that the checkerboard does
  not cover what the tree puts in the flow.

### Properties

- A panel like Details (`editor.asset_workspace_details`) edits the chosen node in cards with the
  Details rows (`editor.held_field_row`), only the sections that its type uses, with what few
  interfaces change in the **Advanced** of each card, and closes with the file's animations,
  styles and fonts.
- A row's arrow returns the value of a new node of its type (`node_default`). A node of an
  instance shows the records of its widget, disabled (`Pane.readonly`).

### Styles

- A node has a named style, which the nodes that choose it share, or **None**: a look of its own.
  Name and family (box, text or control) go in `ui.Tree_Style_Info`, which the game does not read.
  A look of its own that other nodes have (generated `.ui`s share unnamed rows) or row 0 is copied
  on the node's first change.
- **The file says which style the new nodes of each type take** (`Tree_Style_Info.defaults`, a type
  in one style at most, of its family): the **Default** row of the Style card, or `defaults` of
  `ui.style.set`. Without one, the first node of a type brings the look of its type
  (`node_default_look`) and that look stays as that of the following ones; a box has no look and
  is left without style. Nothing is deduced from the neighboring nodes, and pasting into another
  file does not bring the `defaults` of the source.
- A named style does not change from a node: the first change makes the node an override (a row
  with `base`, marked with `*`). **Apply to style** writes it into the style, with its variants,
  and its nodes return to it (`records_style_save`); **Revert** discards it. Save only writes the
  file.
- Choosing a sound in Events on a node whose style is shared asks whether it goes to the node (an
  override) or to the style, which sounds it in all its nodes.
- A style without nodes is deleted (`records_style_remove`); an override counts for its style.

### Variant and states

- What the style has equal in every variant and state (text alignment and fit, a bar's fill,
  **Transition**) goes first; layout does not change by variant or by state.
- **Variant** is the variant that the node shows (bindable); the rows below edit the box, the
  parts of a control and the text. Renaming it changes its rules and the variant of the nodes,
  templates and overrides of that style (`records_variant_rename`).
- Each state, and each combination of states, is a rule of the style for that variant that sets
  only the fields that differ from what the node has without it (`look_begin` resolves it with
  the other rules) and goes away when nothing changes. In a rule, each color chooses a theme color
  (`Style_Patch.tokens`) or a literal value.
- In Edit, the preview shows the selected node in the states of the last opened fold.

### Node, layout, events and image

- **Visibility** bound to a bool chooses with **When false** between Hidden (it keeps its place)
  and Collapsed; removing the binding returns to Visible (`node_unbind`). Each name between braces
  of a text (`{coins}`) has its row with the path it shows (`text_field_rows`).
- **Column widths** of a Grid go in a `grid_tracks` row of their own (`records_grid_tracks`, which
  copies the one it shares with another node).
- **Events** says what the node animates and what its style sounds on each event.

### Widgets and overrides

- An instance chooses its widget and its `Data` and, in Advanced, which of its own rows replace
  the widget's root; **Open** opens its `.ui`.
- Each override names a node of the widget (read with `host.ui_tree_imports`; inside another
  instance, as `slot/icon`) and each field it sets has its row. Turning a field on copies what the
  widget's node has (`records_override_field`), so nothing changes until a value is edited.

### Animations

**Animations of the file** creates clips and groups and deletes the chosen one
(`records_anim_remove`: the groups and events that named it lose it). A clip has tracks of one
property with keys whose value is edited as what the property means (`key_row`); a group plays in
sequence or together parts of earlier rows (`records_part_add`, `records_part_remove`).

### Texts

- The bubble of the text row says whether the node is localized and opens a window with one row
  per language of `UI_Settings.languages`: that of the language the interface is written in
  (`UI_Settings.source`) is the node's text, and the others its translations, which the `.ui`
  stores by the node's `text_id` (`records_translation`).
- A text is not reused between nodes: the widget is reused. Duplicating or pasting gives another
  id with copies of the translations (`records_texts_renew`); deleting takes them away
  (`records_texts_prune`).
- ASCII is typed, like all editable text; `ui.text.set` accepts any UTF-8. Languages that need an
  IME do not have their glyphs in the editor font.
- `ui.text.export` and `ui.text.import` (`mirai texts export|import <csv>`) carry the localized
  texts of all the `.ui`s to a CSV and back, as history steps. The import finds each row by the
  asset's and the text's id (so it follows a moved `.ui`), an empty cell changes nothing and it
  returns the rejected rows with their reason.
- A **Prompt** is just the prompts of its action. The action of a button or a prompt is chosen
  among the game's `Action` constants; one that the game no longer has is marked.

## Paths

The `.ui` names what it reads ([contract](../../mirai-ui/references/ui.md#data-tree)); there
is no bindings card or source to choose on the entity.

- Each property that can come from the game has the link icon; with a path, the row shows the path
  instead of the value. Those that exist only bound (a control's value, the items of a `List`, the
  camera of a `View`, the `Data` of a widget) show the path or the button to choose it.
- The game list offers only what that property takes (`bind_kind`, `type_fits`): first the fields
  of the sources the `.ui` already reads, then the components and storages of the game and the
  engine that have something it takes (`entry_offers`). Inside a `List` it starts at its element;
  in a widget, **Data of this widget** puts a path with `@`.
- `ui_bindings_check` checks the project's `.ui`s against the world of the open build: all of them
  when the build changes and, when the assets change, those that changed and those that use them
  through their widgets. Each `.ui` gives its problems up to `BIND_PROBLEMS`: each path that the
  game does not have and, if it does not load, why. The document in front is checked at the end of
  each gesture and shows each problem with **Show** to choose its node. The widgets it reads are
  kept while their files do not change (`imports_cached`).

## API

An agent authors an interface without opening the document: it reads and writes it as a document,
or changes a part with one method per part. The methods read free parameters: the fields go by the
names of `ui.Tree_Node`, `ui.Node_Style` and `ui.Tree_Image` (`engine.describe` gives the schemas).
A node is named by its name or by `#row`. Each write enters the document's history as a change
made by hand, nothing is saved until Save, and one that would leave a tree that does not load
changes nothing and says why.

- `ui.inspect` gives the `.ui`, or with `node` that node and what it has, as the document that
  `ui.write` takes back (`api_document.odin`): tokens, the files it `use`s, its `params`, named
  styles with `extends` and their states, layouts, named animations, and the nodes
  nested by `children`, each with what differs from a new node of its type and what its style does
  not give. Reading back names: what is written and read back is the same, and what the visual
  editor changed reads back by name too.
- `ui.write` makes the file, or `node`, say what the document declares, in one step; a path that
  does not exist yet makes the `.ui` and `save=true` writes the file (what an agent passes; a
  person saves with Save). On the command line `document=@file` reads it from a file:
  - The document's nodes replace those of the part: they are matched by name and type (an unnamed
    one, by place among the unnamed ones of its type in the same container) and keep what ties
    them to the file (translations by `text_id`, the overrides of an instance); the others are
    made and those that the document does not declare go away. What a node does not give is that
    of a new node of its type; without `style` or `look` it takes the style of its type
    ([styles](#styles)), and an empty `style` is none.
  - The tokens, styles and animations it names become what it says, `null` removes them
    (a style that some node takes is not removed) and those it does not name stay. Without
    `nodes`, no node changes.
  - A name of the part cannot be outside it, and a name that resolves to nothing (style, token,
    component, parameter) fails: an error says where (`nodes[0].children[2]: …`) and changes
    nothing. `ui.check` says the same for every `.ui` of the project.
  - A use says the parameters of its widget by name (`Tree_Param`, flat after `tree_link`): one
    that goes to a node of it, also past another use, is an override of that node, one that goes
    to its root is the use's; a use that does not say one takes it away. The visual editor shows
    them in the Widget card and the widget's own in the Parameters card of its root (add, rename,
    remove, the node and field each drives, the slot); a parameter moved or removed follows in the
    files that use it (`widget_params_follow`).
- `ui.node.*` changes a node and what the call does not name stays. `fields` does not accept what
  has another key or its own method (parent, type, text, style, image, events): the error says
  which to use. `children` of `ui.node.add` adds a whole subtree in the same call: each child
  carries the keys of `ui.node.add` except `asset`, `parent` and `before`, and goes last inside its
  own; an error says through which child it passes (`children[1]: children[0]: …`).
- `ui.capture` draws a `.ui` alone, as the stage builds it (game samples, device prompts and
  language chosen) but in a context of its own at the size at which the game designs it, in a UI
  texture and in a frame without the scene, and writes a PNG with the pixels of that size times the
  editor's density. With a `Scene` background it first draws what the viewport camera sees and
  puts it underneath as an image; with `Checker` or `Color` it does not draw the scene. It can
  show a node in states and choose the screen's variant; what the nodes touch when appearing runs
  `seconds` before. It is what an agent looks at after writing an interface: the document's stage
  shows it scaled to its place.
- `ui.style.set`, `ui.variant.set` and `ui.anim.set` create or change a named style, a variant and
  states rule, or an animation (the keys are sorted by time); what they do not name stays.
- `ui.paths` lists what a node can take at a point of the path; `ui.bind` binds or removes and
  rejects a path that does not work saying what it takes; `ui.check` returns the problems of all
  the `.ui`s; `ui.path.rename` rewrites a path prefix in all of them, also in the templates.
- The per-language texts: `ui.texts`, `ui.text.set` and the CSV ones.

## Document bar

- **Edit**: the pointer chooses nodes over the preview. The chosen node's handles move its
  `float.offset` if it floats and change the width or height it has fixed, snapping to its parent
  and siblings; each gesture is one step on release. A double click edits a text in place, in the
  language that the stage shows.
- **Try**: the interface takes pointer, keys and gamepad as in the game, with its navigation apart
  from the editor's (`ctx.nav_group`). **Play** touches again what the chosen node touches when
  appearing.
- The bar also chooses background, prompt device, language and reference resolution.

## Project Settings > UI

`UI_Settings` chooses the prompt pack (none: drawn) and shows one row for each entry that the
game's actions bind, by family, with the pack's image. Choosing a texture in a row stores it in
`UI_Settings.prompt_images`, which wins over the pack. A pack is built by importing its folder
([prompts](../../mirai-imports/references/imports.md#prompts)).

## Create

The **Interface** (`UI_Screen`), **Panel** (fixed `World_Widget`) and **Billboard** (`World_Widget`
that faces the camera) cards create the entity with the `.ui` chosen in the content browser.

## Verification

`mirai test plugins/ui_inspector/editor`: insertion, deletion and drag in preorder, overrides that
follow their instances, duplicating and pasting into another `.ui` with its rows, Make widget,
unused rows, keys in order, renames, override fields, problems of a check and the preview.
Over a project in the registry's memory, `project_files_test.odin`: the texts CSV
(`texts_go_to_a_csv_and_back_with_commas_quotes_and_lines`,
`a_csv_of_texts_says_why_it_refuses_a_language_the_game_lacks_and_rows_of_no_text`), the rename in
the `.ui`s that use the widget
(`a_renamed_node_renames_the_overrides_of_the_interfaces_that_use_its_widget`) and the incremental
check
(`the_check_of_interfaces_reads_again_only_what_changed_and_finds_what_the_full_check_finds`).
The document is checked in the demo editor by API: `editor.document` opens a `.ui`,
`capture` shows it; the gestures (choosing in the preview, editing in place, Try) are tested
by a person.
