# `ui` package

Layer-1 UI library (`std/base`, `std/math`, `std/serial`, `core:`, `third_party/freetype`). Knows
nothing of editor, renderer or window: host passes per-frame `Input` and consumes a draw list.
File map: [SKILL.md](../SKILL.md#map).

## Units

Layout runs in layout units; `Input.scale` maps to window points (1 in editor, `scale_to_fit` in
games), and `context_set_density` maps points to device pixels (UI content scale, not SDL
`pixel_density`; [platform](../../mirai-platform/references/platform.md#display-scale)). Input and
draw vertices/scissors use points; `widget_rect` returns layout units.

## Context and frame

- `context_init` allocates fixed capacities (`Context_Desc` `max_*` in `context.odin`), fonts,
  optional [sheet](#sheet), navigation and callbacks (`clipboard`, `draw_user`).
- `frame_begin(ctx, input)` .. `frame_end` emits draw slices valid until next `frame_begin`, plus
  `pointer_consumed`, `keyboard_consumed` and `overflow` (`ctx.stats`). `Input` holds printable
  ASCII text and `host.ui_stick` axes. Contexts are single-surface, not thread-safe.

### Retained subtrees

`retained_begin(ctx, id, key)` replays cached draw/hit data for floating subtrees while `key` is
unchanged and no pointer/focus/key/popup/edit/drag reaches them (ineligible if in flow, layered,
transformed, or world-panel). `engine/gui` uses this per unchanged screen.

## Ids and layout

- `id` / `id_push` / `id_derive` generate non-zero `Id`s; `widget_rect` reads last frame's rect
  for interactive widgets and `track`/`block` boxes.
- `Box` (`layout.odin`): `Row`/`Column`, `Grid` (equal columns or `grid_tracks_add`, `span`,
  `row_span`, `row_tracks`; overflow -> `Stats.dropped_tracks`), `Wrap`, `Stack`, `GROW`, `aspect`,
  `self_x`/`self_y` (`Stretch`), `align_y=.Baseline`.
- Floating surfaces (`float` + `contain`/`inset`/`from`) flip/shift within surface bounds on their
  very first frame (used by all popups, menus, submenus and tooltips; clipped only by
  `clip_floats`; ordered by `LAYER_*`, `Parent` inherits parent layer).

### How it resolves

Modified Odin port of Clay v0.14 (`layout_tree.odin`), resolved in `frame_end`:
1. Bottom-up content sizing (clipped axes ask 0).
2. Width distribution (`percent`, weighted `GROW` smallest-first, shrink largest-first to min).
3. `aspect` heights, text line-wrapping, bottom-up height, then height distribution.
4. Layer-sorted float placement and draw-command emission.
5. Pixel rounding of edges/sizes (disabled during transitions; text sizes round up so boxes never
   clip; borders snap to whole device pixels). Text spans cache across two swapping frames.

### Text

Single layout leaf (`text.odin`) shared by `label`, `text` (`prose`), `rich_text`, `markdown`,
tooltips and controls: `text_begin` -> `text_span`/`text_link`/`text_box`/`text_space` ->
`text_end`. `FIT` width requests single line; wrapped text breaks down to widest word; `text_height`
measures off-screen rows identically without building them.

## Draw list

- `Vertex` matches renderer layout (`types.odin`, sRGB straight alpha). `quad_pack` / `quad_user`
  tag host quads (thumbnails, material spheres). `Draw_Command` splits on scissor/surface
  (`Begin_Layer`/`End_Layer` index `Frame.layers`).
- Screen containers emit scissor rects; `clip_push`/`clip_pop` clips triangle geometry directly
  (always used in world panels).
- `draw_*` (`draw.odin`) emits analytic SDF `Shape` quads (rounded rect, ellipse, ring, border,
  shadow), `draw_text_decorated` (shadow/outline/italic/bold/underline/strike), `color2` text
  gradients, and `draw_program` (renderer UI shaders + optional masked image). Overflow drops whole
  and increments stats.

### Screen composition

`Box.layer` (`Layer_Style`, `composition_begin`/`_end`) isolates subtrees in transparent surfaces
with group opacity, rounded clip and optional `backdrop_blur` (up to `COMPOSITION_DEPTH`; requires
screen or `offscreen` panel without rotation; dropped on scene world panels or `max_paints`
overflow). Floats escape parent composition.

## Font

FreeType R8 atlas per `(font, em_size * density)` (1:1 device pixels; `on_demand` fonts request
missing faces/glyphs via `font_ask` and grow only in `font_update` between frames; `font.revision`
signals re-upload). Defaults: embedded Inter 4.1 + italics + JetBrains Mono (`FONT_DEFAULTS`,
`FONT_FACES_EDITOR`; missing glyphs fall back to `FONT_REGULAR`, then `?`). Uses light auto-hinter,
subpixel horizontal phases for small sizes, GPOS kerning (`font_kerning.odin`, no ligatures),
linear-contrast alpha compensation (`ui.frag`), CSS line-box leading (`TEXT_LINE`, `text_leading`),
and unified `layout_walk` word breaking (`text_edit_lines` for carets).

## Interaction

`interact(ctx, id, flags)` tracks `ctx.hot` (top layer, last registered, clipped), `ctx.active`
(pointer capture), `ctx.focus` (`clicked` on press or release with `release_activates`). With
`navigation`: Tab/`order`, directional arrows/gamepad, `Focus_Link`, `Focus_Group`, `nav_group`,
`unfocusable`, popup/modal layer lock, and click-outside hiding only the focus ring (editor clears
focus). `escape(ctx)` fires once if no field/popup consumed Escape/`Pad.Cancel`.

## Widgets

- `canvas` (`draw_user`), `label`/`text`, 16-grid vector `Icon`s (`icons.odin`, `icon_custom_set`
  for plugin icons; one icon per concept everywhere).
- `markdown`: streaming zero-alloc parser (headings, lists, quotes, fenced code with copy button,
  inline bold/code/links/pills via `Markdown_Style.resolve`, lazy row heights via `rows_begin`).
- `button` (`ghost`/`well`/`toggle`/`field`/`accent`; disabled draws at 40% opacity). Editor-only
  controls live in `editor/kit` (`kit.column_label` enforces `label_width`).
  `disabled_begin`/`_end` disables subtrees and cancels active edits.

### Text fields

`text_edit.odin`: editor first-click selects all (game field places caret); Enter/Tab/blur commit,
Escape discards; `multiline` draws visible lines only; `password` masks display; single active
`ctx.edit` (`TEXT_EDIT_CAPACITY`) with per-edit undo/redo (`Primary+Z`/`Y`/`Shift+Z`) and word nav.

### Number fields

`number_field` (click types, drag scrubs, Escape reverts, `began`/`ended` delimit undo), `slider`,
`slider_field` (finite range), `vector_field` (axis color strips), `stepper` (snaps to `step`).

### Popups and scroll

- `panel` (floating or `docked`), nested `popup.odin` (up to `POPUP_DEPTH`, auto-flipping via
  `float`, optional `Popup.search`, `dropdown` cursor navigation without stealing focus,
  `menu_button`, `TOOLTIP_DELAY` tooltips, click-outside dismissal, `modal`).
- `scroll.odin`: caller-owned offset, virtualized `list_begin`/`rows_begin`, innermost-scrollable
  wheel routing (horizontal fallback, Ctrl/Cmd+wheel `zoom`), focus auto-scroll, `Scroll.bar`.

### Sheet

Context default look loaded from a `.ui` style sheet (`context_sheet_set`, `tone`, `metric`,
`sheet_look`; editor uses `assets/editor/theme.ui` via `kit.theme_set`: stepped grays
bar -> canvas -> `panel` -> `card` -> `raised`, darker `well`, violet accent only for primary).

## Game interfaces

- `image` (tint/9-slice/`Image.fit`/`image_frame`), `text` (`reveal` typewriter without reflow),
  `anchored` (safe area), `skin_look`, and style-driven game controls (`game.odin`: radio,
  selector, dropdown with `Options` `|`/`Label=Value`, slider, checkbox, button).
- **Animation (`anim.odin`):** `Anim_Library` (`std/anim` `Keyframe` + `Ease`/`Loop`), caller-owned
  `Anim_Player`/`Anim_State` (`anim_react`). Animates visuals (`Value`, `Frame`, `Reveal`,
  `animated` transform/tint), never layout size (use `layout_transition`); hover/focus states use
  style `transition`.

## Data tree

`Widget_Tree` (`tree.odin`, `tree_data.odin`): flat preorder arrays loaded atomically via
`tree_load` (rejects OOB refs, bad preorder, NaN, invalid anims). `tree_build` emits `Tree_Event`s
and `animating`.
- **Controls & `Draw`:** storage bindings commit via `Bind_Host.commits`; component bindings wait
  for tick events. `Draw` invokes `Context.draw_user` with raw bound bytes (`Bound_Want.Data`).
- **Containers:** `Scroll`, virtualized `List` (`bind_key` preserves per-item focus/hover/
  `layout_transition` slots across reorders), container `Button` (`choice` -> `selected` for tabs +
  `Switcher`), `Popup`, `Modal`, `Radial` (stick/arrow/pointer aim).
- **Paths & templates (`tree_bind.odin`):** dotted paths over components/storages/arrays/`Entity`
  hops (`@` for widget `data`), resolved at `tree_instance_init` against `serial.Schema`.
  `tree_values_refresh` copies only stamped/visibly-changed fields (thresholded by decimals/pixels).
  Supports locale numbers, times, CLDR plurals, `Localized` `.strings` keys, `Collapsed`/
  `Invisible`, action `Button`s, `Action_Bar`, `Draggable`/`Drop`, `Prompt`, `Rich_Text` tags, and
  `ui.Game_Source`.

### Styles and variants

`Style_Patch` overrides per field; `Style_Variant` matches `(variant, states)` (named beats
wildcard, last wins; `Focused` is nav focus only). Supports `transition` (colors/shadow/move/scale)
and `layout_transition` (Clay-style `Cubic_Out` rect glide, `Frame.transitioning`). `tree_settle`
(`tree_names.odin`) resolves tokens/`extends`/layout inheritance at write/link time (`STYLE_KEYS`).

### Widget files

Component `.ui` files expand statically at `tree_link`/`tree_load` into flat arrays (no runtime
virtuals; validates cycles/paths/`TREE_EXPANDED_NODES`). Uses namespace child names (`menu/action`),
bind `@` to `data`, pass `params` as overrides, and insert children into `Slot`.

### World panels

`world_panel` opens a 3D surface (`Frame.placements`, meter or constant screen-point sizing,
optional `Billboard`). `Input.ray` hit-tests nearest non-occluded (`depth_test`, `World_Ray.scene`)
panel when no screen widget captures pointer; `offscreen` panels render to texture
(`world_panel_aim`). No nesting or tooltips.

## Known limits

- Virtualized `List` assumes uniform item height (`Wrap`/`Stack` build all items).
- Clipboard and system cursor go through host callbacks (`ctx.cursor`).
- Texts rebuild per frame; virtualize long lists with `text_height` / `rows_begin`.
- `markdown` link text does not nest bold or inline code.
- `.ui` Grid sets `columns` only (explicit tracks/`row_span` are code-only).
