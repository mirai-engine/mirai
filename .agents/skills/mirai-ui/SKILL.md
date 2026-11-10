---
name: mirai-ui
description: Create and modify Mirai interfaces with the `ui` package (layout, fonts, widgets, data
  trees, animations and world panels). Use when touching `ui/` or `assets/fonts/`, and when
  building editor or game interfaces.
---

# Mirai UI

## Map

- Package contract (units, context, layout, drawing, font, widgets, data tree, world panels):
  [units](references/ui.md#units), [context and frame](references/ui.md#context-and-frame),
  [ids and layout](references/ui.md#ids-and-layout), [draw list](references/ui.md#draw-list),
  [font](references/ui.md#font), [interaction](references/ui.md#interaction),
  [widgets](references/ui.md#widgets), [game interfaces](references/ui.md#game-interfaces),
  [data tree](references/ui.md#data-tree), [world panels](references/ui.md#world-panels) and
  [known limits](references/ui.md#known-limits).
- Files of `ui/` by topic:
  - Frame and layout: `context.odin`, `layout.odin` (`Box`), `element.odin` (elements and their
    drawing in order), `layout_tree.odin` (sizes, text, placement and commands), `text.odin` (the
    text leaf: its spans and how its lines are drawn), `retain.odin` (subtrees that are drawn again
    without being built).
  - Drawing: `draw.odin` (shapes, geometry, scissor and clip), `composition.odin` (isolated
    layers), `paint.odin` (what each element draws), `font.odin` and `font_kerning.odin` (with
    `third_party/freetype`; the coverage correction is in `shaders/ui.frag.slang`).
  - Widgets: `interact.odin` (hot, active, focus, navigation), `widgets.odin`, `text_edit.odin`,
    `number.odin`, `popup.odin`, `scroll.odin`, `color.odin`, `icons.odin`, `markdown.odin`
    (Markdown text, like an agent's replies); theme and variants in `theme.odin` and `style.odin`.
  - Game: `game.odin`, `anim.odin`, `world.odin`, `prompt.odin` and `game_source.odin` (what the
    game gives the interface).
  - Data tree: `tree.odin` (instance and construction), `tree_widgets.odin` (each node type),
    `tree_bind.odin` (paths, copy plan and templates), `tree_data.odin` (records and loading),
    `component.odin` (how a use expands), `tree_link.odin` (what comes from the `.ui` it uses),
    `tree_names.odin` (what the names of a `.ui` leave in its records: `tree_settle`).
- How a game shows `.ui` interfaces (`UI_Screen`, `World_Widget`) and draws its own:
  [game libraries](../mirai-gameplay/references/libraries.md#gui). Bridge with the renderer:
  [host](../mirai-core/references/host.md#bridge-with-ui).
- Inspecting and editing a `.ui` in the editor: the
  [`ui_inspector`](../mirai-plugins/references/ui-inspector.md#document) plugin.
  Format of the `.ui` asset: [kinds.md](../mirai-assets/references/kinds.md#interface).

## Workflow

1. Read `references/ui.md` and the file of the topic to touch.
2. A new widget is a procedure: it takes the state by parameter, calls `interact` with the id of
   its element, fills a `Paint` with `paint_add` and declares its element with `element_leaf` or
   `element_open`/`element_close`. What it draws is one more case of `paint_draw`, not code of the
   widget itself.
3. Test `ui` (the package tests do not use the GPU).
4. If the editor's look changes, run `the_editor_widgets_match_the_current_reference`,
   `the_editor_panels_keep_the_metrics_of_the_editor` and
   `the_editor_panels_have_the_colors_of_the_editor`.
   - `-define:UI_DUMP_DIR=<folder>` writes the images as PNG to look at them.
   - On an intentional visual change, `-define:UI_UPDATE_REFERENCES=true` generates the reference
     crops: inspect them before replacing `ui/reference/*.png` and run again without that define.
   - The reference checks widgets and theme by CPU rasterization; the layout and integration of the
     real shell are tested in `editor/shell_test.odin`.
5. Update `references/ui.md` when a contract changes.
6. In the editor and its plugins, colors, heights and sizes come from the theme:
   `uv run scripts/check_ui_style.py` fails if a hand-written one appears above what is still left
   to migrate, and warns when to lower a maximum.

## Invariants

- Everything lives in `ui.Context`, created from `Context_Desc` with its capacities and its
  allocator; the package has no global state.
- **The layout is built again every frame** (immediate), when the frame opens its first element: a
  frame that only draws shapes and text builds no layout. The id and measure tables are emptied by
  generation, so starting a frame does not depend on how many ids the previous one had; the
  previous frame's rectangles live in the widget registry, which `frame_end` indexes by id: a
  lookup by id (`widget_rect`) does not go through the widgets.
- **The only thing the layout keeps between frames is the text measure**: a span of text that did
  not change is not measured again (`Stats.text_measured` and `text_reused`), and one that does not
  fit in `max_text_words` is measured again when split into lines, without being discarded.
- **Text goes into a box one way**: the text leaf, whose lines and height the layout computes in
  the frame that builds it ([text](references/ui.md#text)). No widget wraps text, counts its lines
  or reads last frame's width to do it.
- **One layout model**: sizes by intent in flows, plus floats. A floating surface is placed by the
  layout from what it hangs from, never by widget code from last frame's rectangle.
- **The layout keeps the behavior of Clay v0.14**, of which it is a modified version:
  `ui/layout_test.odin` stores the boxes, lines and draw order that Clay produced. Their changing is
  a behavior change that is decided, not a test to fix.
- **A stable frame does not allocate.** Text, paints, widgets, vertices and commands go to context
  arrays; what does not fit is discarded whole and counted in `Stats.dropped_*`. Only the
  transactions `tree_load`, `context_init`, `context_set_density`, `anim_library_init`, `tree_init`
  and `tree_instance_init` allocate.
- **`ui.Vertex` has the renderer's layout** (`#assert` in `types.odin`); `ui` imports neither
  `render` nor `rhi`.
- **The pointer is tested against the rectangles of the previous frame** (those that were on
  screen): a newly appeared widget responds the next frame.
- **Unique ids per frame.** Two elements with the same id produce `Stats.layout_errors`; a container
  derived from a widget uses `id_derive`.
- A `disabled_begin`/`disabled_end` scope does not confirm an edit in progress: text and numbers
  cancel it and leave the received value intact. It does not replace the document's permissions.
- **Containers with clip up to `Context_Desc.max_clips`**; the others are built without clip and
  counted in `dropped_clips`. Containers nest up to `LAYOUT_DEPTH`: a deeper one is discarded with
  its content and counted in `dropped_elements`.
- **No order of calls ends the process.** An id scope, a float, a layer, a clip or a scissor nested
  deeper than its stack holds is not applied and is counted (`dropped_nesting`, `dropped_clips`),
  and its end takes nothing off. An end without its begin does nothing, and `frame_end` closes what
  a frame left open and counts it in `layout_errors`.
- **Editable text is US-keyboard ASCII**, one line, without shaping or IME. Displayed text is UTF-8
  within the glyphs of `FONT_RANGES` (Latin, Greek, Cyrillic and `FONT_EXTRA`); the rest is shown
  as `?`. GPOS kerning moves the pen; nothing substitutes glyphs.
- **Sizes are em** (CSS px of the Vue prototype) and the box of a line measures `TEXT_LINE` em: a
  row centers the text with `text_leading`, not with the size.
- **The application font has a single writer:** its owner. The contexts that borrow it read it and
  ask it for the glyphs they lack (`font_ask`). `font_add`, `font_replace` and `font_faces_add` run
  only between frames, because they move the tables that the contexts copy in `frame_begin`, and the
  atlas grows only between frames. An added font or face is not removed.
- **The editor theme is not changed for a game**: a game passes its own `Theme` or uses the widgets
  with their own style (`text`, `image`, a control with a `look`, game controls, tree nodes).
- **One procedure per kind of control.** `button`, `checkbox`, `slider`, `number_field` and
  `dropdown` serve the editor and a game: each takes a `look`, the `Node_Style` resolved for the
  state it is in (`style_resolve` with `widget_states`, or `skin_look`), and without one draws what
  the theme gives it. A change to how one behaves reaches both.
- **A `.ui` is written by names**, by one route: the document `ui.inspect` gives and `ui.write`
  takes; the human edits the same file in the visual editor and neither regenerates over the other.
  Tokens, `extends`, states that extend states, the layout of a style and the parameters of a
  widget live in the file and resolve when it is written and linked (`tree_settle`,
  `tree_nodes_take_styles`, `tree_link`, at load): a stable frame reads the flat `Tree_Node`,
  `Node_Style` and `Tree_Style_Variant` rows as ever.
- **A component is a widget: a `.ui` of its own**, one root, with its `params` and its `slot`, used
  by `use` and named by its file. A local form does not exist; `component_nodes` and `first,count`
  are only what `tree_link` expands uses into, and no file holds them.
- **One component row per file a `.ui` uses**, whether nodes are uses of it or styles and tokens
  come from it; a file stays in `use` until someone removes it, also after its last use is removed.
- **The override of a style by a node is an unnamed style with `extends`**: it says what differs
  and follows later changes of the style in the rest.
- **The first control of each page takes the focus** when it shows (a flag set the first time a
  tree is built by `tree_pages_focus`, not inside a `List`); a node can still ask with
  `Focus_First`.

## Verification

- `mirai test ui` covers context, text, numbers, popups, scroll, navigation, tree, components,
  animation and world panels without a GPU. For GPU composition: `render/ui_composition_test.odin`.
- Font: `ui/font_test.odin` (glyphs and kerning of Latin, Greek and Cyrillic, hinting, subpixel
  phases, fonts added between frames, a font on demand) and, in `host`,
  `host/content_interface_test.odin` (the fonts of interfaces join the application's between
  frames). The editor's Latin text does not change: `ui/reference_test.odin`.
- Layout and scroll: `layout_flow_test.odin` (wrap, stack, own alignment, aspect, weights, tracks
  and span, floats inside the surface), `layout_text_test.odin` (a text at each kind of width in
  one frame, the lines that fit, a row on one baseline, row tracks and row spans, hostile numbers)
  and `scroll_axes_test.odin`. Where a popup lands in the frame that opens it: `popup_test.odin`.
- Game interfaces: `tree_kinds_test.odin`, `tree_containers_test.odin`, `tree_game_test.odin`,
  `tree_controls_test.odin`, `game_controls_test.odin`, `tree_names_test.odin` (tokens, extends,
  states, layouts of styles, the first control of a page) and `retain_test.odin`. Paths:
  `tree_kinds_test.odin` and, in `engine/gui`, `gui_test.odin`.
- Markdown: `markdown_test.odin` (height equal to what was built, each block, whole pills, click on
  a link, code split by characters, code copy and a stable frame without allocating).
- Cases with fine behavior: `password_test.odin`, `caret_test.odin` (the caret blinks and restarts
  without allocating), `number_test.odin`, `widgets_test.odin` (the height of running text) and
  `scroll_test.odin` (rows of different heights).
- The document of a `.ui` (`ui.inspect`, `ui.write`, tokens, roundtrip):
  `cook/author/ui_document_test.odin`; widgets (use, params, reach through, slot, cycles):
  `ui_files_test.odin` in that package; follow and Make widget: `project_files_test.odin` in
  `plugins/ui_inspector/editor`.
- `.ui` file, in `host`: `ui_check_test.odin` (roundtrip of `host.ui_tree_document` and
  `ui_tree_view`; `asset.ui_check` refuses what `ui.tree_load` refuses) and `ui_asset_test.odin`
  (a `.ui` written to its file reads back the same records and tree).
- Benchmark of a frame: `mirai test ui benchmark_a_frame_of_a_large_panel
  benchmark_a_frame_of_a_long_transcript --release -define:UI_BENCHMARK=true
  -define:ODIN_TEST_THREADS=1`. The atlas and the text are measured with
  `benchmark_rebuilding_the_atlas`, `benchmark_drawing_text` and
  `benchmark_a_font_on_demand_in_the_cases_of_an_application` (start, Play and another density).
