# `ui` package

`ui` is a layer 1 library: it imports only `std/base`, `std/math`, `std/serial`, `core:` and the
FreeType binding (`third_party/freetype`). It knows nothing of the editor, the renderer or the
window: the host hands it the input of each frame and receives a draw list. Each type and procedure
is documented in its file (the [Map](../SKILL.md#map) says which); here go the model, the contracts
between the parts and the design rules.

## Units

- Layout happens in layout units. `Input.scale` converts them to window points (1 in the editor;
  `scale_to_fit` for a game designed at a resolution) and the context density, from points to
  device pixels.
- Input arrives in points, the screen's vertices and scissors come out in points and the widget
  rectangles (`widget_rect`) are in layout units.
- The context owner applies `context_set_density` before the layout when the window density
  changes; a context that borrows its owner's font follows it. That density is the content scale for
  UI, not SDL's `pixel_density`
  ([platform](../../mirai-platform/references/platform.md#display-scale)).

## Context and frame

- `context_init` receives in `Context_Desc` the allocator, the capacities of a frame (`max_*`, with
  their defaults in `context.odin`), the fonts, the sheet ([sheet](#sheet)), the navigation and the
  host callbacks (clipboard and `draw_user`).
- A frame goes from `frame_begin(ctx, input)` to `frame_end`, which returns the draw list; its
  slices belong to the context and hold until the next `frame_begin`. `pointer_consumed` and
  `keyboard_consumed` tell the host whether the UI took the pointer or the keyboard, and
  `overflow`, that something did not fit (the detail is in `ctx.stats`).
- `Input` is flat state that the platform fills from its events (`input_next_frame`, `input_key`…);
  the sticks are filled by the host (`host.ui_stick`) and the text is printable ASCII.
- A context is one surface and is not thread-safe; different contexts can be used from different
  threads.

### Retained subtrees

`retained_begin(ctx, id, key)` says whether to build a subtree. When it is not built, the context
draws again what it drew the last time (vertices, shapes and widgets, in their layers) and the
pointer and navigation find their widgets where they were. It is built again when `key` changes
(what it shows) or when an input reaches it: the pointer enters, leaves or presses on it, the focus
enters or leaves, a key arrives with a focusable widget of its own, or there is a popup, an edit or
a drag in progress. Only what floats is retained: a subtree in the flow of another, or with
composition layers, transforms, effects or world panels, is built every frame. `engine/gui` retains
each screen that did not change this way.

## Ids and layout

- `id` gives an `Id` that is never zero within the scopes opened with `id_push`; `id_derive` gives
  the one it would have inside another. `widget_rect` gives the previous frame's rectangle of a
  registered element: every interactive widget and the boxes with `track` or `block`.
- A `Box` (`layout.odin`) describes a container; `if box(ctx, {...}) {...}` closes it at the end of
  the block. A `GROW` distributes what is left by its weight.
  - `Grid` places the children row by row in equal columns or in those of `grid_tracks_add`; a
    child occupies `span` columns and moves to the next row if it does not fit in what is left of
    its own. A child of `row_span` rows keeps its columns in the rows under it and the children
    after it flow around them. A row is as high as its highest child of one row, or what the row
    tracks say (`Box.row_tracks`, from `grid_tracks_add` too) with the same kinds of `Size`; a
    child of several rows that needs more gives the rest to its last one. The tracks that the
    frame cannot store are counted in `Stats.dropped_tracks` and their Grid is left with equal
    columns, or rows of their children.
  - `Wrap` continues on another row where the next child does not fit; `Stack` overlaps the
    children.
  - `self_x`/`self_y` align a child in its place; `Stretch` stretches it like a `GROW` (what is
    fixed is not stretched). `aspect` gives one axis from the other: the fixed one gives the one
    that is not and, if neither is, the width gives the height.
  - `align_y=.Baseline` on a `Row` puts the first line of text of each child on one baseline (a
    container gives that of its first child, a child without text stands on it) and the row is as
    high as what goes over the baseline plus what hangs under it. A child with a `self_y` keeps
    its own place.
  - A `float` with `contain` stays inside its surface (the world panel or a player's part), less
    its `inset`: if it does not fit on the side it hangs outside of, it goes to the other side of
    what it hangs from, and then shifts as much as needed; lined up with what it hangs from, it
    only shifts. With `from` it hangs from a rectangle instead of an element. **Every popup, menu,
    submenu and tooltip, of the editor and of the tree, is placed this way and by nothing else**:
    no widget computes where a floating surface goes, so its first frame is already in its place.
  - What floats is not cut by the clip of its ancestors, except inside a box with `clip_floats`.
- The layers (`LAYER_*` in `context.odin`) order the floating surfaces. A `Parent` float without
  `layer` stays in its parent's layer: the layout places each layer after the lower ones, and in
  another it would end up behind and far away.

### How it resolves

The layout (`layout_tree.odin`) is a modified version, in Odin, of Clay v0.14's, with the same
result. It is built every frame and resolved in `frame_end`, one axis at a time:

1. When closed, each container asks for what its children add up along its direction and the largest
   across, plus padding and gaps, within its minimum and maximum. A container that clips on an axis
   does not ask for its content on that axis.
2. The width is distributed: a `percent` takes its share of what is left without padding or gaps;
   the `GROW`s receive what is left starting with the smallest (by its size over its weight); if
   there is a shortfall, the largest is cut first, never below its minimum. A container that clips
   does not shrink its children: it shifts them. Across the direction, and on both axes of a Stack,
   a `GROW` fills its parent.
3. What has `aspect` takes its height from its width, every text is split into lines at the width
   it received and the heights rise to the roots. Afterwards the height is distributed like the
   width.
4. The floating roots are ordered by layer (within a layer, the one declared later stays on top) and
   placed against what they hang from; a `GROW` float takes the size of that and a `percent` one
   its share of it. Afterwards each element is placed and the commands are listed in draw order.
5. Each box is rounded to the device pixels of the screen: its edges, from where the layout put
   them, and its size between them, so neighbours share an edge. What transitions is not rounded
   while it moves, nor what it holds. An edge moves at most half a device pixel, a size at most
   one; what a text asks for (and a button measured from its text) is rounded up to whole device
   pixels first, so a box never ends narrower than the text it holds, and `text_height` gives the
   same. Pointer hits and `widget_rect` see the rounded boxes; a shape's border is whole device
   pixels wide.

The measure of a span of text is stored by text, size and face in two generations that swap
between frames: what a frame shows again is taken from the previous one without measuring it,
comparing the text and not only its hash.

### Text

**Text is one leaf of the layout** (`text.odin`), and there is no other way to put text in a box:
spans of words, each in the style of the text or in its own, with boxes in their line. The layout
measures each span once for what it says, breaks the leaf into lines at the width the width pass
gave it and takes the height of those lines in the same frame, whatever the width is.

- Only a `FIT` width asks for what the text says, on one line; a text that wraps breaks down to its
  widest word when its parent is narrower. Any other width is what the layout gives. A `FIT`
  height holds the lines; any other shows the lines that fit, aligned by the style.
- `label`, `text`, `rich_text`, `markdown`, the label of a column, a tooltip and the text of a
  game control are that leaf with different spans: `text_begin`, then `text_span` (words),
  `text_link` (words that take the pointer on every line they end up on), `text_box` (an image, a
  pill, a prompt) and `text_space`, then `text_end`. `prose` is the style of the editor's running
  text.
- A line is as high as the line box of the text, taller where a span of a larger size or a box
  needs it. Spans of words sit on one baseline; a box and a chip (a span with `pad`, such as
  inline code) are centered in the line.
- `text_height` gives the height of a text at a width through the same measure and the same
  breaks, without building it: what a list that builds only its rows in view asks.

## Draw list

- `Vertex` has the renderer's UI vertex layout (`#assert` in `types.odin`). Colors are screen values
  (sRGB) with straight alpha. `quad` packs a `Quad_Kind` and its data (`quad_pack`); the host types
  start at `User` (`quad_user`), and the editor uses them for material spheres and thumbnails.
- `Draw_Command` goes over a triangle list. `Begin_Layer` and `End_Layer` have no vertices and name
  a row of `Frame.layers`; `surface` 0 is the screen and `n` is `placements[n-1]`. The commands are
  cut when the scissor or the surface changes.
- Clipping:
  - The **scissor** (screen) is opened by containers with clip; it travels in the command, in
    points, and whole figures outside it are not emitted.
  - The **clip** (geometry) of `clip_push`/`clip_pop` cuts triangles and quads interpolating colors
    and UVs: text inside its box and the content of fields use it.
  - In a **world panel** the clips cut the geometry and everything stays inside its rectangle; its
    scissor is the whole panel and the renderer can ignore it.
- The `draw_*` primitives of `draw.odin` also serve `draw_user`. Rounded rectangles, ellipses,
  rings, borders and shadows emit a quad and a `Shape` record: the shader computes the shape's
  distance and the antialiasing with derivatives, also when the scope transforms it.
- `draw_text_decorated` adds shadow, outline and `Text_Decorations`: italic slants the glyph quads
  around the baseline (the clip cuts the rectangle without slanting), synthetic bold repeats the
  `TEXT_BOLD` line of its size to the right and underline and strikethrough are `TEXT_RULE`
  rectangles.
- `draw_program` paints a rounded rectangle with a renderer
  [UI program](../../mirai-rendering/references/shaders.md#programs), whose `ui` id it does not
  interpret; the scope tints it by the vertex color, like a shape. With `program` in a `Box`, a
  `Progress` or a `Paint`, the fill comes from the program instead of the fill and its gradient;
  shadow, border and track are still shapes.
- What does not fit in `max_vertices`, `max_commands` or `max_shapes` is discarded whole and
  counted.

### Screen composition

`Box.layer` (`Layer_Style`) isolates the box and its content in a transparent surface that is
composed only once with opacity and rounded clip; overlapping children share the group's opacity.
With `backdrop_blur` the layer takes a filtered copy of its parent's background.

- The layout opens the layer with the box's background command and closes it after the children: it
  adds no elements per child. For direct drawing, `composition` or `composition_begin`/`_end`: the
  close is mandatory even if the layer is discarded.
- A layer composes on screen and in an `offscreen` panel, which is drawn into a texture like the
  screen; in a scene panel it is discarded and its subtree is drawn without isolating.
- Layers nest up to `COMPOSITION_DEPTH` and close in reverse order. The markers reserve room for
  their closes before accepting a layer; if the box does not fit in `max_paints`, the whole layout
  and input subtree is omitted, so there are no drawings without their markers.
- A floating element belongs to its draw root and can leave the composition of its authoring
  parent.
- The pointer respects the rectangle and corners of the layers, also shifted or scaled. Invisible
  or rejected layers receive no focus; a visible focus ring is emitted inside its widget's
  composition.
- Only on screen, with shift and scale without rotation: a layer in a world panel or in a rotated
  scope is discarded and counted (shapes, images, widgets and text remain available). The effects
  are processed every frame; there is no incremental update.

## Font

`Font` is an R8 atlas with one face per font and size, rasterized with FreeType.

- **Sizes in em**, in layout units: a size is the CSS `font-size` in pixels. Each face is
  rasterized at its exact fractional size in device pixels, so at any density the glyphs land 1:1
  on screen. Another size scales the nearest face of the same font; in an on-demand font, if none
  is near, `draw_text` asks for a face of that size (`font_face_ask`), which its owner adds between
  frames (up to `FONT_FACES_MAX`). This way a game's text, of its own sizes and scaled to its
  reference, looks sharp.
- **Faces.** Without `fonts` there are `FONT_DEFAULTS` embedded fonts from `assets/fonts`: Inter 4.1
  Regular, Medium and SemiBold and JetBrains Mono (`FONT_MONO`, the code), with the faces of
  `FONT_FACES_EDITOR` (the sizes and weights of the editor's theme and those of the code). Measuring
  and drawing a text with different fonts misaligns it. `font_add` and `font_replace` keep the face
  and glyph indices that existed: the first font added is `FONT_DEFAULTS`.
- **Rasterization.** The light auto-hinter aligns heights vertically to the pixel grid and leaves
  widths and spacing as the font designed them. Small faces store several horizontal phases of the
  frequent glyphs, so that the pen lands near where the layout puts it.
- **Kerning** from the GPOS table (`font_kerning.odin`), applied to every measure and to drawing. It
  is positioning: there are no ligatures or substitutions.
- **Coverage.** `ui.frag` converts the coverage into the alpha that, blended in display space, gives
  what it would give blended in linear light over the luminance opposite to the text's; the test
  rasterizer does the same (`test_glyph_alpha`).
- **One font, one writer.** An own font rasterizes all its glyphs at each density, as a transaction:
  if it fails the previous atlas remains. An `on_demand` font rasterizes nothing when created: only
  its owner writes it, and the contexts that borrow it (`Context_Desc.font`) copy its header in
  `frame_begin` and read it. A missing glyph is asked for in `wanted` and through
  `Context_Desc.font_ask`, and the owner rasterizes it there without growing the atlas, so it is
  drawn in that frame. If the atlas is full, or without `font_ask`, it waits for the owner's
  `font_update` between frames, the only one that grows the atlas, because growing moves the
  coordinates of what was already drawn.
- `font.revision` changes when the atlas must be uploaded again. The bytes of each font must outlive
  the font; FreeType allocates with its allocator during a rebuild or while an on-demand font
  lives. The application font and its contexts:
  [host](../../mirai-core/references/host.md#bridge-with-ui).
- The text measures (`text_width`, `text_line`, `text_lines`, `text_index_at`…) are in layout units
  with the kerning and do not depend on the density. A text has no line limit.
- **One word breaker.** Every text that wraps at words walks them with `layout_walk` and breaks
  with one `Flow`, whatever its spans. A word ends at a space or after a mark (`text_mark`: a
  hyphen or a slash not followed by a digit, an en or em dash, a zero width space, a soft hyphen).
  A word goes to the next line unless it fits with the space after it; one wider than the line
  starts one and breaks after its last glyph that fits; a line gives up the space it breaks or
  ends at, and a soft hyphen it breaks at is drawn as a hyphen, which must fit; what no space or
  mark parts stays on one line. `text_line` is that break for the text a field edits, which keeps
  the spaces of its last line.
- **A glyph a font lacks** is measured and drawn from `FONT_REGULAR` (Inter in the fonts of the
  application), at the same size; `?` only when that one lacks it too (`font_glyph`).
- **Lines like CSS.** `TEXT_LINE` (Inter's ascent plus descent) is the `normal` line height and the
  box of a line; `text_leading` centers it in a height with half the excess above, like CSS. A row
  centers its text this way and `Text_Style.line_height` distributes the excess of each line;
  `prose` gives `PARAGRAPH_LINE`, that of running text such as the messages of the chat, in whole
  units. The
  baseline lands on a device pixel with the ascent rounded, as in Chrome.

## Interaction

`interact(ctx, id, flags)` registers the widget and returns its `Interaction`.

- `ctx.hot` is the widget under the pointer: the highest layer wins and, within it, the last
  registered; each widget is clipped by the container with clip that contains it.
- `ctx.active` holds the pointer from when it was pressed on it; while there is one no other is
  hot. `ctx.focus` is taken by the focusable widget that is pressed; a press that none takes leaves
  it at 0. `clicked` happens on press, or on release over it with `Context.release_activates`.
- With `Context_Desc.navigation`:
  - Tab traverses the focusable widgets of its group, first those with `order`; the arrows or the
    gamepad go to the nearest in that direction (the facing one first). `Focus_Link` fixes the
    neighbor on a side and a wrapping `Focus_Group` returns the focus from the opposite side.
  - `ctx.nav_group` is the group of the widgets registered afterwards: an interface tested inside
    another does not share the navigation. Inside `ctx.unfocusable` nothing is focusable.
  - A click that no focusable widget takes does not remove the focus: it only hides its ring,
    which returns with the keys or the gamepad. This way a game menu keeps its place while the
    mouse clicks around. Without navigation (the editor) that click does remove it.
  - With a popup or modal open the navigation stays in its layer.
- `escape(ctx)` returns true once per frame if no field or popup used Escape or `Pad.Cancel`.

## Widgets

All take the context, an id and their state by parameter.

- **Canvas.** `canvas` is an area that `Context.draw_user` draws as its `Draw_Node` says: the
  layout places it, the container with clip clips it and the pointer over it is its interaction.
- **Text and icons.** `label` is a line clipped to its box, which can fade out at its end, and
  `text` with `prose` is the running text ([text](#text)). The `Icon`s are drawn on a 16 vector
  grid.
  - **One icon per concept, everywhere**: `Scene` (a folded map) on the asset, the document tab and
    the scene configuration; `Prefab` (the cube with the top face filled) on the asset, an instance
    in the hierarchy and its actions; `Grid` only for the grid.
  - The objects of a scene (shapes, mesh, group, prefab, plane, lights) are line drawings with a
    stroke that grows with the icon and a faint fill on the top face.
  - An icon is also given as data (`icon_drawing`, `icons.odin`); `icon_custom_set` delivers it to
    the context and `icon_custom` is its `Icon`, which any widget accepts: this is how the editor
    draws the plugins' icons.
- **Markdown.** `markdown` builds Markdown text at a width (paragraphs, `#` to `###` headings,
  lists nested by indentation, quotes, fenced code, rules; inline bold, code, links and escapes).
  It is a parser: each paragraph and each heading is one [text](#text) whose spans are its words,
  its inline code (a chip), its links and its pills, and the layout breaks it. Its height is the
  one the layout gives what it builds: a list of replies keeps the height of the row each was built
  in, builds one that changed where nothing shows it when it is out of sight, and otherwise builds
  only those in view with `rows_begin` (the chat of the editor).
  - It is parsed line by line: it stores nothing between frames or allocates. What it does not
    recognize (HTML, tables) stays as text; italic has no face and its marks are removed. Bold and
    italic open and close on the same line.
  - A word longer than the line is cut where the line ends (`text_begin` with `cut`), and a line
    of fenced code is a `solid` span, which breaks at no space and is cut the same way, so its
    height does not depend on where the spaces fall. A tab is room up to the next stop of its line.
  - Each link goes through `Markdown_Style.resolve`, which must give the same answer for the same
    destination in a frame. A `pill` link is not
    split: it passes whole to the next line and, if it is wider than a line, it is cut to it; a
    `live` one lights up whole under the pointer, on every line it is on, and its destination is
    what `markdown` returns the frame of the click. The text that `resolve` writes in `buffer`
    holds until the end of its block. A pill can carry an icon before its text, which widens it,
    and be a `button`: the accent fill and its `on_accent` text, at the line height.
  - A code block shows, while the pointer is over it, a button that copies its code with
    `clipboard_set`; the button does not change the height. The ids of what it builds derive from
    the given id.
- **Buttons.** Without a `look`, `button` is the style `button` of the sheet in `Button.variant`
  (`ghost` when empty), with `active` as the state `Selected`: `well` is a value that is chosen,
  with the well and border of a field; `toggle` is like `ghost` off and `toggle_on` on (a tab that
  is shown, an open menu). `Button.padding` zero is the automatic inset, positive fixes it and
  negative removes it.
  - Disabled does not respond. `ghost` and `tab` show no fill, not even with the pointer over them;
    `field` and `accent` keep it, and everything is drawn at 40 % of its opacity (`color_faded`).
    `row` and the menu items too.
- **The editor kit** (`editor/kit`, engine-time: a game does not contain it) has the controls only
  the editor and its plugins use: sections, property rows, segments and tabs, switches, vector,
  slider and color fields and the color picker. `kit.column_label` is the label of a row: always of
  the width of the token `label_width`, so the controls of all rows start in the same column; one
  that does not fit ends in `…` and never pushes its controls.
- **Read-only scopes.** `disabled_begin`/`disabled_end` register the widgets as `Disabled`, without
  presses or navigation; the fields cancel an open edit or scrub without confirming their value. The
  editor uses it for Details and the entity inspectors reserved by another participant; the
  document's permissions remain the check outside the UI.

### Text fields

- In the editor the first click selects everything; afterwards a click places the cursor. Enter, Tab
  or a click outside apply and Escape discards. `multiline` keeps the line breaks, wraps the text
  and draws only the lines in view. The options of `Text_Field` (`live`, `bare`, `inline`,
  `password`…) are commented in `text_edit.odin`; `password` only masks the paint, and its owner
  controls showing it and clearing its buffers.
- A field is a well (the token `well`) with an outline; while editing it takes the accent outline.
- A game field (`style`) takes everything from the style and its first click places the cursor.
- There is only one field in edit per context (`ctx.edit`, up to `TEXT_EDIT_CAPACITY` bytes, what
  the AI chat message admits). The cursor blinks with `Input.dt` without allocating.
- Primary+Z undoes and Primary+Y or Primary+Shift+Z redoes, within the edit in progress: a run of
  typing, of Backspace or of Delete and a paste over a selection are one step each, and a caret
  moved ends a run. The steps live in `ctx.edit` (`TEXT_EDIT_STEPS`, `TEXT_EDIT_HISTORY`); the
  oldest go to make room. Primary with the arrows, Backspace or Delete goes by words.

### Number fields

- `number_field`: a click without dragging writes the value; dragging traverses it from the initial
  value and Escape returns it. `began` and `ended` delimit the edit for undo.
- `slider` is the slider of the editor and of a game: a drag moves it and Escape returns the value
  the drag began with; left and right step it with the focus. `slider_field` is one followed by the
  field that types its value and needs a finite range (otherwise it is the field alone).
  `vector_field` builds a field per component with the strip of its axis color, without a letter.
- A `stepper` number has two arrows that step it, as left and right do with the focus, and what is
  typed in it snaps to its `step`.

### Popups and scroll

- **Panels** (`panel`, `Panel_Float`): a panel floats over the surface and takes the pointer, with
  the theme's fill, border, corners and shadow; `docked` is one against an edge of the surface, only
  with its fill, without border or shadow and square, or with the radii of `corners` (whoever docks
  it draws the line of its inner edge).

- **Popups** (`popup.odin`, up to `POPUP_DEPTH` nested):
  - A popup is a float that hangs from the rectangle its opener gave `popup_open`, contained in its
    surface ([ids and layout](#ids-and-layout)): under it, or over it with `Popup.side`, and on the
    other side when it does not fit; a submenu beside its item. With `Popup.within` it lines up
    with a panel and not with its anchor. The frame that opens it draws it in its place.
  - `Popup.search` puts on top the only popup search box, which takes the keyboard on opening;
    `dropdown` and the inspector's asset lists use it.
  - **A `dropdown` list has one current row** (`Popup_Entry.cursor`), editor and game alike: the
    pointer moving onto a row makes it current, Up and Down (the d-pad, the stick) move it from
    there and Enter (accept) takes it; it opens on the chosen option, in sight, and only the rows in
    sight are built. Rows take no focus: it stays on the dropdown, which gets it back on choosing.
  - **Choosing a value is a single component:** `menu_button`, a `Ghost` button with an arrow that
    opens its menu; the chosen option goes with `checked`, the groups with `menu_header` and the
    destructive with `Menu_Item.danger`.
  - A bar menu measures at least `MENU_WIDTH`, each item measures the token `control` and the icon
    column (`MENU_ICON`) exists only if some item has an icon (according to the previous frame). A
    menu without icons starts its text where its titles start.
  - Every tooltip appears after the pointer rests `TOOLTIP_DELAY` on the same element, under the
    pointer, or over it where it does not fit under.
  - A click outside a popup only closes it; Escape closes the last (the submenu first).
  - A `modal` with `close` is dismissed with its cross or a click outside, and whoever opened it
    closes it. The questions (save, recover) are not dismissed.
- **Scroll** (`scroll.odin`): the offset belongs to the caller. `list_begin` and `rows_begin` build
  only the visible rows (equal ones, or of heights that the caller measured once).
  - An area that scrolls horizontally leaves its content as wide as it asks, so a paragraph is not
    split.
  - The wheel goes to the innermost area under the pointer that can still move its content that
    way (by last frame's rectangles of the area and its content), so one that fits or is at its
    end passes it outward; one whose content fits its height turns it sideways. An area without
    content of its own (one that pans or zooms) and Ctrl+wheel take it always. The page keys and
    the right stick go to the innermost area under the pointer or to the one that has the focus,
    if it has nothing focusable (otherwise they belong to the navigation). `zoom` takes the wheel
    with Ctrl (Cmd on macOS) before the area scrolls.
  - A content that shrinks leaves in place what was seen: the area stores below the missing place,
    which goes away when scrolling up and never when scrolling down with the wheel. The bar floats
    and takes no layout.
  - When the keyboard or the gamepad move the focus, the areas that contain it bring it into view
    from the inside out.

### Sheet

The look of what nothing else styles is the sheet of the context: the records of a style file, a
`.ui` of tokens and named styles like a game's, read by the same code (`context_sheet_set`,
`tree_load`). `tone` and `metric` give a token, `sheet_look` a style resolved for a variant and
states. A context without one (a game's) has none: its controls take their look from their nodes.
The editor's is `assets/editor/theme.ui`, which `kit.theme_set` gives its context; it is edited as
any `.ui`, with `mirai ui write` or the visual editor.

The theme is the editor's look and the direction Mirai follows: neutral grays, no boxes inside
boxes, violet only for what is active and primary. Each layer is one step lighter than the one
behind it (bar, document canvas, `panel`, `card`, `raised`) and a field (`well`) is darker than its
card, so that a panel stands out from what is behind it and a card from its panel without depending
on the border. `row` is the height of a property row and `control` that of a bar button, a menu row
and a search box; a `look` of its own on a button remains for what carries the color of a datum
(that of an agent). The package's shapes, layers, styles and components do not change the layout
or the controls of the editor panels:
[editor interface](../../mirai-editor/references/panels.md#layout).

## Game interfaces

- `image` (part of a texture with tint, or 9-slice) is placed with `Image.fit` according to the size
  in texels of the part; `image_frame` gives the frame of a sprite sheet. `text` ([text](#text))
  takes a `reveal` that draws a part of its characters where the whole text places them, so it does
  not reflow while it appears. `anchored` hangs a container from a screen point inside the safe
  area and `skin_look` gives a button images or colors per state.
- **Game controls**: a button, a checkbox, a slider, a number and a dropdown are the editor's with
  a `look`; a radio, a selector and a field are in `game.odin`. Every color and corner comes from
  the `Node_Style` resolved for its state (`widget_states`): neither the sheet nor constants.
  `fill`, `stroke`, corners and text are the box (and the list of a dropdown); `track` the track of
  a slider and the current row of a dropdown; `knob` the knob; `mark` the dot, the tick, the arrows
  and the chosen option.
  - Without a size, a control measures its text plus `GAME_PAD` and `GAME_WIDTH` sizes of width.
  - Left and right change a slider, a selector and a number with the focus; the slider writes only
    when the pointer or the keys move it, and what is written in a number is adjusted to the step
    and the range.
  - `Options` gives the options of a selector or a dropdown: one by one, a text separated by `|` or
    an array of texts or enums (by their name or by a text `Name=Text|...`), without a cap.

**Animation** (`anim.odin`). `Anim_Library` stores tracks and animations in flat arrays; its keys
are those of [std/anim](../../mirai-std/references/anim.md#tracks-keys-and-clips-trackodin-clipodin)
(`Keyframe`, with the `Ease` of `std/math` and `Loop`), read by its `track_evaluate`. The state
belongs to the caller (`Anim_Player` or `Anim_State` with `anim_react`, which plays those of an
`Anim_Set` when the element is shown, hidden or clicked and returns true while it must be built).
What an element looks like hovered, pressed, focused or selected is a state of its style, with its
`transition`: an `Anim_Set` has no animation for a state.

- An animation changes how a node is drawn, never its size: a size is what the layout computes, and
  a node goes to a new one with the `layout_transition` of its style. `Value`, `Frame` and `Reveal`
  give the value of a control, the frame of an image and the visible part of a text (typewriter).
- `anim_play` after another animation starts from the value that one left; the first of an element
  starts from its keys. In the tree, `clicked` arrives the frame after the click.
- `animated(ctx, id, value)` draws what is built inside moved, scaled, rotated and tinted around the
  element's center; the layout does not change and the pointer follows what is drawn. An outer clip
  cuts it by its transformed box: exact with shift and scale, approximate with rotation.

## Data tree

`Widget_Tree` is a flat array of `Node` in preorder with styles, variants, images, texts and
animations in neighboring arrays, without pointers. `tree_build` builds it with the same procedures
as code and says which events it wrote and lost and whether the next frame differs (`animating`).
The node types are in `Node_Kind` (`tree.odin`) and the events in `Tree_Event`.

- **Controls.** The tree's controls are the game ones, in the parts of the style that the node
  resolves. They write the copy of the value and emit `Changed` with what they ask for; the host
  says which sources they then write in the game (`Bind_Host.commits`, `tree_commit_event`): for
  `engine/gui`, the fields of a storage, so a settings screen and the page of a menu are data, and
  not those of a component, which the game writes and which show what was asked until it has had a
  tick to. A `Button` that binds a value writes its `choice` when clicked, as a `Radio` does, and
  emits `Changed` after `Clicked`.
- **Draw.** A `Draw` node is a leaf whose paint (`Paint_Kind.Draw`) calls `Context.draw_user` at
  `frame_end` with a `Draw_Node`: the rectangle, the colors and text of its style, and the bytes
  of the field its `bind_value` names, of any type (`Bound_Want.Data`, `draw_value`). `draw` names
  who draws it. It is replayed with its screen, so what it shows comes from what it binds. A
  `Selector` or a
  `Dropdown` written `Label=Value` binds the value of the option chosen (a number, a member of an
  enum, a text for a text field), not its index. A `Selector` or a
  `Dropdown` with `bind_items` takes its options from a game array.
- **Containers.**
  - A `Scroll` scrolls horizontally if its direction is `Row` and downward if it is another; with
    `clip`, on both axes.
  - `List` repeats its only child per element of the array it binds (or per row of a component's
    table, `Bind_Host.rows`). With `clip`, or inside a `Scroll` that scrolls along its direction, it
    builds only the elements in view and one more on each side: the step comes from what the
    previous frame built and, while it does not know it, it builds `TREE_LIST_PROBE`. The focus that
    code puts on a node of an element that was not built, outside another inner `List`, scrolls the
    list until it is shown.
  - **An item is told apart by its key**: `bind_key` names a field of the element (a whole number,
    an enum, an `Entity` or a text), and an array of entities keys itself; without one, its index.
    The id of an element comes from the hash of its key, and its slots (states, kept texts,
    animations) from a table of the list by that hash, where an item keeps its slot while it is in
    the list: an item that moves keeps its focus, hover and style fade, and its `layout_transition`
    carries it from its old row. An item that comes in takes a slot no item of the build holds and
    starts its states afresh; one that moved formats its texts again, because what the copy says
    changed is by place. Two items with one key are two elements with one id.
  - Each tab of a `Tabs` shows its option, like those of a `Selector` (its text separated by `|` or
    the array it binds), and without it the text of its node, its name or its number.
  - A `Popup` that the player closed stays closed until the game hides it; `Modal` takes all the
    input and Escape emits `Closed` so the game hides it. `Radial` gives the focus to the node in
    the direction of the left stick (`Input.aim`), of the arrows or of the pointer.
- **Paths.** The `.ui` says what it reads: a binding is a path that starts at a component of the
  interface entity or at a world storage and follows its fields (`Inventory.equipped.icon`); a
  number after an array names its element (`Hotbar.slots.2.count`). An `Entity` field leads to
  the component that the next segment names (`Hero.target.Health.value`).
  Inside a `List` the path starts at the element; in a widget of another `.ui`, one with `@` starts
  at the instance's `data`.
  - `ui` does not know the world: whoever creates the instance gives it a `Bind_Host` with the type
    and bytes of each source. `tree_instance_init` resolves each path against the `serial.Schema`
    and, if one does not exist or does not serve for that use, leaves in `failure` the node, the
    binding and whether it was in a template.
  - The instance copies only the bytes it reads: the ranges read from each region are joined and
    packed into `values`. `tree_values_refresh` copies only those ranges, skips what did not change
    according to its stamp and stores which ranges changed until the next build.
  - What changed is what a node shows: an f32 shown only by a number of a template is copied when
    it moves a shown step (its decimals, a second of a clock), and the value of a Progress when its
    fill moves a pixel; below that nothing is copied and no node is built. Games never round.
  - The formats after the colon are in `tree_bind.odin`: numbers with the separators of the
    language of `Game_Source.language` (`NUMBER_LOCALES`, a region writing as its language),
    times, texts by value and CLDR plurals (`{n:one=# coin|other=# coins}`). An enum name or a
    category that does not exist fails like a path.
  - A text with braces is a template of names (`{health:0}/{most}`): each name is a field of the
    node with its path, so the text names the same in every language without paths. It is
    interpreted when creating the instance and in the frame only what changed is formatted;
    `Tree_Build_Desc.changed` says that values that the refresh did not copy changed.
  - A `Collapsed` node is neither built nor takes place; an `Invisible` one takes its place but does
    not draw or take input. With `bind_visible`, the flag says what it is when the value is false.
- **Localized texts.** The text of a `Localized` node is a key of the texts of the game
  (`base.Texts`, every `.strings` of the assets as one table:
  [texts](../../mirai-assets/references/kinds.md#texts)). The instance asks `Game_Source.texts`
  what the key says in `Game_Source.language` when it is created and when the language or the
  generation of the texts changes; a key the texts lack shows as it is. Nodes, rows of game data
  and code that name one key show one text.
- **Input.** A `Button` with `action` is also pressed with that game action (with `hold`, only after
  holding it); `Action_Bar` lists the buttons with an action of its tree with their prompts. A
  The bar shows the buttons the last build found: a build that finds others, or their texts in
  another language, says `animating` so the next frame shows them. A
  `passive` tree takes no input; `order`, `nav`, `Focus_First` and `Wrap_X`/`Wrap_Y` build its
  navigation. Each `Tree_Event` carries the rect of its node, so the game can point at what was
  hovered or pressed.
- **Floats.** A node's `float` applies to every kind, also to one that holds no children (a
  `Button` over an icon and its name): it floats from its parent like a box would. A `Tooltip`
  opens where its node's float anchor, pivot and offset say.
- **Drag and drop.** A `Draggable` node is dragged past `DRAG_DISTANCE` with its `tag`; under the
  pointer goes the node that `ghost` names, even if the tree hides it, or a copy of the node. A
  `Drop` takes only what its `accepts` carries, has the `Over` state while something is over it and
  receives `Dropped` with the name, the element and the origin tree (`Context.owner`). Escape
  cancels.
- **Prompts and rich text.** `Prompt` shows the prompts of an action for the device family of
  `Game_Source.family`: the image the game gives or a drawing of its own. `Rich_Text` accepts `<b>`,
  `<i>`, `<u>`, `<s>`, `<color>`, `<size>`, `<link>`, `<prompt>` and `<img>`; it cuts its lines with
  the layout's algorithm (`layout_walk`). `<b>` uses the SemiBold face of the application font if
  the text is in Regular or Medium and, in another font, a synthetic bold; `<i>` is synthetic. A
  link takes the `mark` color and a click emits `Link`.
- **Game.** `ui.Game_Source` (in `Context.game`) is the only thing `ui` knows of the game: prompts,
  action state, texts, textures, camera views, particles (alive while their element is built) and
  sounds per state.
- `Tree_Build_Desc.area` names an element from which the `Surface` and `Safe` floats of the nodes
  hang instead of the surface: the part of a player's window. What floats from the widgets (popups,
  the copy being dragged) stays on the surface.
- What does not fit in the tree's limits (`TREE_BAR`, `TREE_TEXT_KEPT`, `RICH_SPANS`) is discarded
  and counted in `Stats.dropped_tree`.

**Tree as records.** `Tree_Data` (`tree_data.odin`) is the same tree in the form that a `.ui` asset
stores ([format](../../mirai-assets/references/kinds.md#interface)) and that a tool edits.
`tree_load` builds a `Widget_Tree` of the exact size of the expanded records; it is a transaction
that returns false, leaving no tree, on a row that refers outside its table, nodes out of preorder,
non-finite numbers, unterminated texts or invalid animations. `tree_node_record` gives the record
that `tree_node` takes: the loaded tree is, byte for byte, the one the same calls build.

### Styles and variants

- `Style_Patch.fields` chooses the fields it replaces, one by one also in text: a change of the
  style in what the rule does not fix reaches it.
- `Style_Variant` selects a style row by variant (zero is a wildcard) and states, which must all be
  active. `Focused` is the navigation focus with its ring, not the one a click gives: it does not
  look like hover.
- `style_resolve` applies the states in order; within the state, a named rule wins over the
  wildcard, and then the last row. A tree keeps its rules by style, in that order.
- With `Node_Style.transition`, a node's colors, its shadow and what `move` and `scale` give go from
  the style it showed to the new one when its state or variant changes; a change under way starts
  from where it was and a transparent end only fades.
- `Node_Style.layout_transition` carries the rectangle of the node to a new layout (an item inserted
  above it in a `List` with a key, a page that grows, a size that changes), as Clay's transitions
  do: the layout keeps the last rectangle of each element that asks (`layout_transition_ask`, in a
  table by id of `Context_Desc.max_transitions`), and the node goes from where it was drawn to
  where the layout puts it with the `Cubic_Out` ease. Its place is kept from the corner of its
  parent's content, so a parent that moves or scrolls carries it without starting it; a size on
  its way is fixed for a second layout, so what surrounds it follows. The first time, after a
  frame it was not asked for (a node shown again), and on a surface of another size, it is where
  the layout puts it at once.
  `Frame.transitioning` says the next frame differs, and `engine/gui` keeps no screen of that
  context. Only tree nodes ask: what code builds, as the editor, goes to its new place at once.
- `Node_Style.move` and `scale` draw a node through a scope around its center that the layout and
  the pointer do not see (`animated_begin` with `still`), so what lifts a button under the pointer
  does not lose it.
- A shadow without blur and with an offset is a solid copy of its shape; without blur or offset, the
  token `shadow` of the sheet.
- `tree_settle` (`tree_names.odin`) is where the names of a `.ui` resolve: what a token gives, what
  a style with `extends` takes (`Tree_Style_Info.sets` says what it sets itself), what a state with
  `extends` starts from, and the layout a node takes from its style (`Tree_Node.layout_own` says
  what is its own) at load. The file keeps the names in `Tree_Style_Info`, `Tree_Token_Use`,
  `Tree_Token` and `Tree_Param`; the frame reads the flat tables, and each name resolves when the
  file is written or links another (`tree_link`), so changing a token or a style reaches what names
  it without touching the frame. Game documentation: `docs/game/ui/styles.md`.
- A value a style or a state sets is a `Style_Key` with its row in `STYLE_KEYS`: copying,
  comparing, tokens and the document go by that row, so a new key is a new row.
- A node's variant is its own, that of its `bind_variant` or the one it inherits from its box; that
  of the root is given by whoever builds (`Tree_Build_Desc.variant`).

### Widget files

- A component is a widget: a `.ui` of its own, one root of any kind. A `Component` node is a use;
  `Tree_Component.widget` names the file and its name is the name of the file. A file that no node
  uses only lends its styles and tokens (`use` without a use); a style row with `from` is a named
  style of that file, copied into the row at link.
- `tree_link` expands each use into `component_nodes` (with the styles, variants, images, fonts
  and animations of the file, once per file) and `tree_load` into the flat arrays: the frame
  neither interprets uses nor allocates. There is no inheritance or virtual objects per widget.
- A file holds no `component_nodes`; `first,count` exist only once linked.
- `params` of a file: a name and a `node.field`, `field` of its root, or `node.param`, a parameter
  of the widget that a use it holds uses. `tree_link` makes them flat, a path and a field, as an
  override reaches them, and a use writes them as overrides.
- A node flagged `Slot`, the last of the file, holds what a use holds.
- The name of a use is mandatory and gives the root (`menu`); inner nodes become `menu/action` and
  nested ones `menu/nested/action`, the name that identifies elements and events. Paths of the
  widget read the sources of the interface that uses it; those that start with `@`, what the use's
  `data` names.
- `component_fields` chooses properties of the use that replace the root of its widget, and the
  overrides change fields of a node by its path. The load validates rows, preorder, depth, cycles,
  override targets and the `TREE_EXPANDED_NODES` budget; errors leave the tree empty.
- Examples: `templates/game/assets/menu/` (`panel.ui`, `select_row.ui`, `check_row.ui`, `button.ui`)
  and the interfaces in `demo/assets/interface/`.

### World panels

`world_panel` opens a virtual surface with its origin at the top left, placed in the world and sized
in meters per unit or in constant screen points (with `Input.view`): a context places its panels for
a camera.

- `Frame.placements` gives per panel the matrix from layout units to world and what the renderer
  needs to draw it; a `Billboard` one can turn toward each camera around the pivot.
- `Input.ray` is its pointer: it reaches the front of the nearest panel if no screen widget is under
  the pointer, and keeps giving position over the plane while a widget is active.
- **Occlusion.** `World_Ray.scene` says whether the scene covers the point where the ray touches a
  panel (without it, nothing covers). A `depth_test` panel that is covered does not receive the ray,
  with the same tolerance with which the renderer hides it; one without `depth_test` does.
- An `offscreen` panel is drawn by the host into a texture (a mesh) and not in the scene;
  `world_panel_aim`, between frames, says where the next frame's ray touches that surface.
- `world_panel_reached` gives the panel the ray reached: the host gives it the navigation, the keys
  and the actions. Panels do not nest and have no tooltips.

## Known limits

- A `List` that builds only what is in view assumes elements of the same size; `Wrap` and `Stack`
  build it whole.
- The clipboard and the system cursor are not its own: they arrive through the context callbacks
  and through `ctx.cursor`, which says what shape the widget under the pointer asks for and the host
  shows (the editor, when its tools did not ask for another).
- A text is built every frame: a long list of texts measures each one with `text_height`, with the
  same measure and the same breaks, or keeps the height a Markdown row was built with, and builds
  only the visible ones with `rows_begin`.
- The text of a `markdown` link does not take bold or code from inside.
- A `.ui` document names the `columns` of a Grid, not its tracks nor the spans of its children:
  those are set from code, and the rows of a `.ui` hold neither `row_span` nor row tracks.
