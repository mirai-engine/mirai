# Extending the editor

A plugin or a project extends the editor with an editor package (`plugins/<name>/editor/` or the
project's `editor/`) whose `@(storage)`, `@(component)` and `@(step)` the generator joins to the
`Editor_World` ([plugins](../../mirai-plugins/SKILL.md),
[generator](../../mirai-core/references/generator.md)). The package imports `mirai:editor` and may
import its `runtime/`; no game code imports it.

Each `*_Provider` on this page is an Editor storage whose only field is the provider, filled by its
default; the editor reads it from the current library, again on code reload, and keeps no pointers
to an unloaded library. Those of one type are looked up in a single place (`provided_all`, and
`provided` for the first).

## Package rules

- **Data.** A tool's state is a flat `@(storage)` (`Paint_Tool`, `Terrain_Tool`); with memory of its
  own, `@(storage,free="proc")`. A `@(component)` of the editor package lives in `Editor`, not in
  `World`: what must survive Play and saving goes in `runtime/`.
- **Functions.** They run by default in the `editor` loop and receive as parameters what they use:
  `^editor.Session`, its storage, `core.World_Ref` (the shown world), `core.Input`, `core.Time`, the
  part of the application they reach (`^host.Assets`, `^host.Frame_Extras`; `^host.App` for the
  application itself) and tables. The generator rejects an editor function in the `game` loop or
  with editor types in `fixed`.
- A step that builds UI starts with `if !g.begun || editor.playing(s) {return}`: `Editor_Ui.begun`
  says the `ctx` frame is open, and in Play the tools do not act.
- Order against the [editor steps](editor.md#the-editor-loop): reading the pointer or deciding
  whether a click belongs to the tool, in `input` `after="editor_begin"`; acting on the scene
  (picking, strokes, lines), in `frame` `after="editor_tools"`; drawing a panel, in `ui`
  `after="editor_panels"`, before `editor_end`.

## A viewport tool

Outline of `paint` and `terrain` (`plugins/*/editor/`):

1. **Turn on.** `editor.tool_button` presents an entry of the Tools menu and returns its click; the
   step calls `editor.tool_set(s, "paint", true)`, which keeps the name's hash in
   `Viewport.plugin_tool`, and rereads `editor.tool_on(s, "paint")`. `tool_set(s, name, false)`
   turns it off only if it is the active one.
2. A key is handled only if `ctx.edit.id == 0`, without modifiers, with `g.modal == .None` and
   `ctx.popup.count == 0`.
3. **Collect input** in `input`: `s.viewport.hovered` says the pointer is over the scene and no UI
   takes it. While `s.viewport.pick.active` waits for a reference, the click belongs to that
   choice. `editor.tool_pointer` gives the three things: on, over the scene and a click that starts
   its work (never in Play nor with the scene lent).
4. **Ask the scene.** `editor.pick_point` and `pick_ray` (a world ray, without disks) return a
   `Pick`. The ray under the pointer is `viewport_ray`: the scene starts under the bars, not at the
   window corner. With `batches=true` they also find the instances of the shown world's
   [batches](../../mirai-rendering/references/scene.md#instance-batches) (`render.batch_ray`),
   and the entity is the author of its `object_id`.
5. **Edit as a transaction**: `edits_begin` on starting, `edits_end` on releasing and `edits_cancel`
   with Escape or an error ([document](document.md#edits-and-undo)).
6. **Move what is not an entity.** `editor.tool_gizmo` is the selection's gizmo (handles, snaps,
   Local) over a transform the tool keeps, and returns `Began`, `Moved`, `Ended` or `Cancelled`
   (with Escape, which returns it); `tool_gizmo_draw` draws it. The tool records the step, and the
   mode is that of W, E and R, which do not turn it off. `editor.tool_keys` gives it keys the
   editor shortcuts stop taking while it is on (Delete for what it selected). A tool without a
   gizmo of its own (terrain) calls `editor.tool_lend`: while it has the scene, W, E and R are not
   shown active, and pressing them lends the scene to the gizmo and the selection without turning it
   off or closing its panel (`tool_aside`); choosing a brush takes it back with `tool_take`.
7. **Show.** Guides with `host.extras_debug_lines_add`; a ring of constant width on screen, with
   `viewport_screen` and `ui.draw_line` or `ui.draw_polyline`. The panel, only with the tool
   active: `if ui.panel(ctx, id, editor.tool_panel(g, id)) { controls }`. The result, with
   `editor.notify`. What a component draws over the selection (a mirror's face, a decal's box) goes
   through `editor.selection_gizmo`; `gizmo_face` is the outline of a face of side 1, ellipse or
   rectangle, with the arrow of its front.
8. **Brushes.** `editor/brush.odin` is what the tools' brushes share (terrain and foliage):
   `brush_ring_points` and `brush_ring_draw` draw the ring with its outline, in the `BRUSH_*` colors
   according to what a touch does, and `Brush_Adjust` with `brush_adjust_key`/`brush_adjust_frame`
   is F and Shift F dragging the radius and strength over the ground plane (Ctrl, fine; Escape or
   the right button, the value from before). `key_hint` writes at the end of a row the key that
   does the same. A pen's pressure and eraser tip arrive in `core.Input.pressure` and `eraser`.
9. **A source in its file** (terrain, foliage): the scene's undo keeps the revision of its owners,
   not the file. `editor/revision_history.odin` is the chain of revisions: the tool keeps the head
   of each source it edited (what the file has at the owners' revision) and steps between two
   revisions that undo and redo change with it. `revision_sync` takes each head to its owners'
   revision and writes it; if the file changed outside (Save, Discard), the revision takes what it
   has. A new step replaces what was undone since its revision; past `REVISION_STEPS_CAPACITY` the
   oldest goes. What a step keeps, how it changes with the head and how the source is read and
   written is given by the tool in a `Revision_Source`.

**Authoring geometry preview** (used by [terrain](../../mirai-world/references/terrain.md)):

- During a stroke it is shown with an immutable generated mesh (`host.assets_mesh_generate`) and a
  visual instance of the frame (`host.extras_instance_add`, `replace_source` to substitute the shown
  entity), without changing components or history. The mesh is released on replacing it, cancelling
  or finishing, before `render_sync`.
- To confirm, it writes the asset in the registry's memory, unsaved, and what is loaded reloads by
  itself. A new copy per stroke (`.mesh` of paint) is a file of the step (`editor.file_write`); a
  tool that keeps its own undo by revision (`.terrain`) writes it outside the history with
  `editor.file_set`, and the step restores the component that keeps the revision.

## Cancelable previews

A tool that keeps changes visible until confirmed uses an exclusive gesture tied to its `tool_set`
name:

- `tool_preview_begin(s, name, label)`, only in Edit and with that tool active, closes the previous
  gesture and opens the preview; it fails if there is already one. `tool_preview_active(s, name)`
  says whether it is still its own on the current document: check it before writing each frame.
  `tool_preview_end(s, name, apply)` confirms everything as a single undo or returns entities,
  components, poses and selection to the start.
- Inside the gesture the public edit procedures are used; `edits_end`, `edits_flush` and
  `edits_commit` do not confirm it.
- The plugin keeps its temporary resources in its storage and, if `tool_preview_active` stops being
  true, releases them without writing the document. It keeps no row pointers between functions.
- Changing tool, Play or Simulate, saving, replacing the scene, reloading code, closing the editor,
  selecting from Hierarchy or the API and a scene write by API cancel it. Escape and Ctrl+Z with
  the gesture open only cancel; after confirming, Ctrl+Z undoes the whole step.
- Details stays read-only while it lasts; confirming or cancelling leaves the tool on.

## A panel

- `editor.drawing(g, id, width, height, draw, user)` reserves an area of the panel that `draw`
  paints with the `ui.draw_*` primitives when the frame is painted, in the rectangle the layout
  gives it and under its container's clip; it returns the pointer interaction over the area.
  `Drawing_Proc` is its type; `user` lives until the frame is painted (a storage field). Up to
  `DRAWING_CAPACITY` (8) areas per frame. The `profiler` plugin draws its graphs this way.
- In a `ui` step `after="editor_panels"`, `editor.tool_panel(g, id)` gives the layout of the active
  tool's panel: the place and width of Details, which is not shown while the tool is active;
  `editor.details_build` draws it inside the panel (terrain puts it in a foldable section). Escape
  without a selection or Select of the Tools menu turn it off and Details returns. `editor.inspect`
  names the tool on in `plugin_tool`.
- It is passed to `ui.panel` and the controls are built inside the panel's positive block, which
  closes its scope on exit. `free_region` discounts these panels. An independent panel can use
  its own `anchor`/`pivot`.
- `editor.view_toggle(g, id, label, active)` adds an entry in View and returns its click; the
  plugin changes its state and builds the panel.
- `tool_button` and `view_toggle` pass data to the next frame in fixed arrays of `Editor_Ui` (16
  controls in total, copied strings, no allocations). A control that stops being presented
  disappears in the next frame. The click returns to the step that presented it, without keeping
  functions.
- Use the inspector widgets (`ui.section`, `ui.property`, `ui.number_field`, `ui.toggle`,
  `ui.color_field`) and a `ui.Id` of its own scope (`ui.id_derive(ctx, SCOPE, "panel")`). The
  Details cards are `editor.card_begin`, `section_band` and `card_body_begin`, with their open state
  in the plugin; `editor.row_begin` is a row with its label in the label column, `editor.fold_label`
  a label that unfolds an `editor.fold_band`, `editor.fold_section` the foldable section of a card
  (without a line, with its open state in the inspector), whose rows go in
  `editor.fold_band_begin`/`fold_band_end`, `editor.search_field` a field that filters, with
  `editor.scroll_shadow` over the list passing below, and `editor.row_description` the description
  of the name of a row of one's own.
- For values the panel keeps in its storage, `editor.held_field_row(s, h, field, label)` builds the
  Details rows of a struct field (`editor.Held_Values`: non-null `key`, `info`, `value` and
  `defaults`) and returns `true` if it changed:
  - `info` is `type_info_of` the struct in the plugin's library: each library has its own type table
    and the editor does not find that of a type it does not declare.
  - The field's type and tag choose the row: a color (`color`) is its swatch, which opens the
    picker, and its label unfolds the channels; a vector names its cells with `axes` (`axes=LTRB`,
    or words separated by spaces); the sides and corners of a box show arrows and unfold by name.
    With `width`, an enum of few short names is a segmented control; `icons=` gives the name of a
    `ui.Icon` per value, which its segment shows instead of the text. `description` appears on
    leaving the pointer on the name.
  - It writes in place, without an undo step; the arrow returns the field to `defaults`.
  - The asset lists and the color picker deliver the choice to the next frame, to the rows with the
    same `key`.
  - With `write` (a `Held_Writer`, and `user` while the rows are built), the rows do not write in
    place: they deliver the bytes and their offset to `write`, which keeps them where they live (the
    values of an effect shown by an entity, in `vfx`) as document steps named `name`. A drag or a
    color picker session is one step.
- Tool panels are hidden while an entity reference is being chosen.

## An asset document

A plugin opens asset types in tabs next to the scenes
([asset documents](panels.md#asset-documents)) with an `editor.Asset_Document_Provider`:

- **Declare and draw.** Its default names the types; `flat` marks those that draw no world (the bar
  leaves out Graphics). A `ui` step `after="editor_panels"` takes `editor.asset_document_active(s)`
  and, if it is of its type, builds `ui.panel(ctx, id, editor.asset_workspace(g))`; with Details on
  the right, `editor.asset_workspace_details` gives the two panels. `editor.asset_toolbar(g)` is
  the toolbar's place after Save, Undo and Redo, and `asset_toolbar_whole` the center of all of the
  bar after the tabs.
  The plugin's state follows the front document: on changing asset it rereads it.
- **Playing.** `editor.timeline_strip` is the time strip of a document that plays. It does not own
  time: it reads a `Timeline_Clock` and returns a `Timeline_Result` that the document applies to its
  data; view, range and unit live in a `Timeline` of the document, which is not saved with the
  asset. It is the base of a cinematics document: its tracks, takes and events would be lanes
  (`Timeline_Lane`).
- **Editing.** What the document writes through `editor.file_write` (or a procedure that uses it,
  like `vfx`'s `particle_write`) is a step of its history; it is best to write when the UI releases
  the gesture, not on every frame of a drag. A step can write another asset (the texts a `.ui`
  edits in its languages): the document's Save also writes those its steps changed, and the tab is
  marked while any is unsaved (`asset_document_paths`).
- **Between frames.** `Asset_Document_Provider.between(s, d)` runs between frames while one of its
  documents is in front: what needs frames of its own from the renderer, like a world drawn into a
  texture (`host.app_world_draw`, the
  [particle preview](../../mirai-world/references/vfx-editor.md#effect-preview)). The UI
  computes what to show and `between` draws it only when it changes.
- **Columns and playback.** `editor.asset_column_begin`/`asset_column_end` build a column with its
  header and `asset_column_divider` the line between two. What a document plays is an
  `editor.Asset_Playback` that `asset_playback_advance` advances within the range of its time strip
  (`asset_playback_strip`, with the mark lanes it is given); `asset_preview_sun` puts the preview
  sun in the toolbar.
- **Settings.** `editor.settings_open(s, name)` opens Project Settings at that storage's setting,
  like the File menu.
- The plugin's state follows the front document: on changing asset it rereads it.
- **Edit actions.** `Asset_Document_Provider.actions` says which edit actions (Copy, Paste,
  Duplicate, Delete...) its documents take: with one in front, their shortcuts do not run them on
  the scene, but leave them in `Asset_Document.request` with another `request_serial`, and the
  plugin runs each serial once.
- **Create.** `Asset_Document_Provider.creates` says which of its types (of `asset.KINDS`) offer
  the content browser's Create and `asset.create`. The editor chooses the path and id and calls
  `Asset_Document_Provider.create(s, kind, id)`, which returns the bytes of the empty file in the
  temporary allocator (nil if it could not); the editor writes them immediately like its own types,
  as an unsaved history step. This way no frame runs inside an API call. `ui_inspector` creates the
  `.ui` this way: a root Box that grows to the surface and style 0.
- **AI context.** `editor.asset_document_pick` says what the user chose in the document: the chat
  shows it and sends it instead of the scene's selection. `editor.asset_document_show_say` says in
  one line what the document shows at that moment, which the message also carries.
- **Toolbar.** `editor.held_asset_button` is an asset the plugin keeps, as a button with its
  thumbnail and the list of assets of the type. `editor.asset_pick_row` is the row of an asset in
  the rows of a setting or component the plugin draws, and says when it opened its list.
- **Part.** `Asset_Document.part` names what the document shows on coming to the front (the clip of
  a library opened from the content browser); the plugin takes it and empties it.
- **Drop.** An asset the editor does not know how to use, dropped on a viewport entity, stays in
  `Session.dropped`: the plugin of its type takes it with `editor.asset_drop_take(s, kind)` in that
  frame or the next (with `part`, the dragged clip) and applies it as an edit.
- `previews` opens animations, sounds and sound sets this way
  ([previews](../../mirai-plugins/references/previews.md)), and `vfx`, particle effects
  ([vfx](../../mirai-world/references/vfx-editor.md#particle-document)).

## Asset types of a plugin

An Editor storage whose only field is `editor.Asset_Kind_Provider` declares in its default the
plugin's asset types that the content browser lists (`kinds`, up to `ASSET_KINDS_OF_PROVIDER`, and
`count`), like the editor's types:

- `label`: the type as a row says it and the name of its filter. `color` and `icon`: those of its
  cards, fields, rows and tabs (`editor.asset_kind_color`, `asset_icon` and `asset_kind_label` read
  them with the session).
- `extension`: that of its files; `asset.list` names the type with it without the dot, and the
  `kind=` tag of a field, with it whole ([inspector](inspector.md#rows-by-reflection)).
- `field`: a word; an `Asset_Id` field whose name has it takes the type.
- The `asset_kinds` of the plugin's `plugin.mirai` list exactly these extensions
  ([manifests](../../mirai-projects/references/projects.md#manifests)); a test of the editor part
  holds it with `editor.asset_kinds_differ`.
- `clicked` (of the provider): what a click on one's card does, outside Play and with the scene in
  front (assigning it to the selection).

One whose only field is `editor.Asset_Menu_Provider` adds, with `menu(s, file)`, its entries
(`ui.menu_item`) to an asset card's menu. To show an asset of the type in a component like a
material:

- `editor.asset_box(s, name, index, label, quad, open, revert, kind, value)`: the box with its
  thumbnail, its name, the list arrow and the magnifier; it returns the click, where to anchor the
  list and an asset of the type dropped on it.
- `editor.asset_list_open(s, table, offset, kind, none, anchor)`: the list of assets of the type
  with their previews; what is chosen goes to that field of the selected entities that have the
  component, in one step. `none` is the first row (id zero); `asset_list_shown` says whether it is
  open for that field.
- `editor.asset_quad(s, kind, id, points)`: the preview of an asset of any type for a box or a row;
  with id zero, what a field without an asset shows (`preview_default`).
- `vfx` provides `.particle` this way ([vfx](../../mirai-world/references/vfx-editor.md)).

A panel that shows assets uses the browser's cards, at its size and in its mode (list or grid, with
or without names): `editor.asset_cards(s, width)` gives the columns and the side,
`asset_card_begin`/`asset_card_end` draw one and `asset_card_float` places what goes on top.
`editor.drag_dropped(g, rect)` takes an asset dropped on the panel.

## Thumbnails of an asset type

`editor.Thumbnail_Provider` gives the thumbnails of the types of its default
([thumbnails](panels.md#previews)), up to `THUMBNAIL_PROVIDERS` providers:

- `subject(s, file, clip, subject)` fills the `Thumbnail_Subject` of an asset or of its clip-th clip
  from 1; false: its icon. Without `file`, what a field of the type without an asset shows (a
  default); false: nothing. What the editor already draws (a mesh, a document and its root) it draws
  itself; with `provider` equal to the type, the provider draws it.
- `triangles(s, subject, vertices, materials)` adds the subject's triangles in the studio's space
  and the materials they index; it can start from `editor.triangles_append`.
- `image(s, subject, side, out)`, if present, draws it instead of the triangles, between frames (it
  can draw frames of a world of its own with `host.app_world_draw`): `side` squared premultiplied
  screen colors, from what the subject carries in `data` (`THUMBNAIL_DATA` bytes, part of its
  signature). `vfx` draws its particles this way.
- The provider's state lives in a plugin storage, which it reads with `core.world_storage_of` over
  `core.world_ref(s.editor_world, s.info, .Editor)`.
- Everything the subject names (`mesh`, `pose`, `document`, materials) enters the stored
  thumbnail's key; the rest of the subject, by its bytes.
- `previews` provides those of animations this way
  ([previews](../../mirai-plugins/references/previews.md#animation-thumbnails)).

## Create cards

An Editor storage whose only field is `editor.Card_Provider` adds cards to Create: its default
fills `cards` and `count`, up to `CARD_PROVIDER_CAPACITY` = 8 per provider and `CARD_CAPACITY` = 64
with the presets. `decals`, `monitors`, `portals` and `vfx` add Decal, Screen, Portal and Particles
this way.

Fields of `Card`:

- `label`: name of the card and of the entity. `scene.add` accepts it in `preset`, case-insensitive
  and with `_` for space.
- `group`: Create section: `"Logic"`, `"Shapes"` or one of its own, which goes after those of the
  editor (`CARD_GROUP_CAPACITY` = 8 sections). Empty: `Logic`.
- `icon`, `drawing`, `color`: an existing `ui.Icon` or, with empty `icon`, a drawing of its own
  ([icons as data](../../mirai-ui/references/ui.md#widgets)).
- `body`: primitive of the preview on placing (`None`: a mark). `scale`: the entity's scale. `lift`:
  meters above the support for what has no body.
- `make`: `proc(s, w, e)` that adds the components; the entity already has `Id`, `Name`, `Transform`
  and parent. It runs inside the undo step of the creation.
- `component`: the component of which the card is the icon; the entity that has it shows it in
  outliner, Find, slots and its viewport disk, and the component's section in its header.

Rules:

- `label` is the name of the card and of the entity; `scene.add` accepts it in `preset`,
  case-insensitive and with `_` for space. A `group` of its own goes after the editor's sections;
  empty, in Logic.
- `make` runs inside the creation's undo step, on an entity that already has `Id`, `Name`,
  `Transform` and parent.
- The entity that has the card's `component` carries its icon in outliner, Find, slots and its
  disk, and the component's section in its header.
- `cards(s)` returns the presets first (a preset's index is its value) and then the cards.
  Dragging, the placement click, Edit > Create and `scene.add` create the same:
  `entity_create` with `Create_Desc.card`.
- What a selected entity shows besides the icon (a decal's box, a portal's opening and the path to
  its exit) is drawn by a `frame` `after="editor_tools"` step of the plugin with
  `host.extras_debug_lines_add`, outside a Play.

## An inspection mode

A plugin adds modes to the [mode menu](panels.md#inspection-mode) and to
`editor.view_mode.list` by declaring them every frame from a `frame` step, before `ui`, with
`editor.view_mode_declare(s, View_Mode_Desc)`:

- `name` cannot be a core one nor one already declared in the frame; an empty `group` goes to
  `Plugins`; with non-empty `reason` the mode cannot be shown now and is not drawn.
- `record` is a pass of the [`Inspect`](../../mirai-rendering/references/views.md#extension-stages)
  stage that the renderer records only in the view that shows the mode, over its lit image: it
  requests its pipeline with `erender.stage_pipeline(renderer, {stage = .Inspect, shader})` (a
  `<shader>.comp.slang` of its `shaders/`), binds the image with `pass_image_bind` and dispatches. A
  lines mode delivers them itself while it is the one seen (`editor.view_mode_current`), with a
  `record` that does nothing.
- Up to `VIEW_MODE_PLUGIN_CAPACITY` per frame; the declarations are emptied in `input`, and a mode
  that stops being declared returns to Lit.
- `portals` declares `nested` (`plugins/portals/editor/view_mode.odin`) and `physics`, Collision
  ([inspection mode](panels.md#inspection-mode)).

## API methods

- `editor.Api_Provider` declares its registry in the default, for example
  `ANIMATION_API_DEFAULT :: Animation_Api{provider={register=register}}`. On opening the API the
  editor invokes that initializer, which the generator publishes in `World_Info`, and the provider
  calls `editor.api_method_register(s, descriptor)` per method, without running a frame. Reload
  rebuilds the registry between calls with those of the new library.
- The `Type_Info` of `params` and `result` must come from the package that declares the structs, to
  cross the loaded library; `engine.describe` and MCP expose those schemas.
- Handlers use `editor.shown_world`. A document write goes between
  `editor.api_edit_begin(s,call,label)` and `editor.api_edit_end(s,call,ok)`, which apply guards,
  cancellation and undo. An asset the plugin writes goes through `editor.file_write` inside that
  pair: it enters the same step and the review of the turn that requested it, and stays unsaved
  ([files](document.md#edits-and-undo)); to read it as it is, `editor.asset_read` or
  `host.assets_file`.
- A tool that confirms through its [cancelable preview](#cancelable-previews) does not
  use that pair: after `editor.api_guard_edit` it opens the gesture, advances it and confirms or
  cancels it inside the call, without leaving it open, and turns the tool that was on back on
  (`placement.drop`).
- The elements of a params array that the call does not give keep their default;
  `api.params_array_count` says how many it gave.
- An operation on the Play copy declares it in its contract. Evaluation stays in runtime: the
  handler validates, queues requests and presents results.
- [Protocol conventions](../../mirai-agent-api/references/api.md) and
  [animation methods](../../mirai-animation/references/animation-api.md).

## Runs the API drives

An Editor storage whose only field is `editor.Run_Provider` hears the runs the API advances tick by
tick (`play.step`, a scenario, a filmstrip, `editor.play_tick`): the input of a tick before it runs,
that it ticked, the methods that changed the run between ticks, a change of focus and that it
ended. What it keeps of a run goes in a storage of its own, keyed by `Run.id`. `editor.play_tick`
with an `Api_Step_Input` drives a run, and `editor.play_ui_screen` says what its screen on top shows
([`playtest`](../../mirai-plugins/references/plugins.md#first-party-plugins)).

What steers or watches a body in those runs asks the plugin that moves it, never a component by
its name: an Editor storage whose only field is `editor.Body_Provider` answers for the bodies of
its plugin (`physics`, for its characters), and `editor.play_stance` and `editor.play_body_measure`
read it. A body no provider answers for is `Unknown`, which each reader handles and is not taken as
standing, and is measured as `BODY_PERSON`.

A bot of a plugin walks a body with the drive of `play.step`, not with steering of its own:
`editor.play_drive_to` makes one to a place, `editor.play_drive_steer` runs before each
`editor.play_tick` until it says the drive ended, and `editor.play_drive_end` lets go of one left
before that. The way comes from the `editor.Route_Provider` of the project (`navigation`).

## Importers of a plugin

A plugin adds to the editor's import ([import](../../mirai-imports/SKILL.md)) with two providers;
the editor reads them from the current library with `provided_all` (`PROVIDER_CAPACITY` as the cap)
and joins them with the engine's.

- `editor.Import_Format_Provider{format}` gives one more `importer.Format`. It is imported like
  those of `sources.FORMATS`, with the same reading, writing, cache and identity
  ([plugin formats](../../mirai-imports/references/imports.md#plugin-formats)); its
  `Format.folder` chooses the folder of the import. Its extensions enter the dialog's Models
  filter and what the editor recognizes on dropping a file. With `prepare(s, allocator)`, the
  editor asks it in its thread, before importing a model, for the format's options for that import
  (`Format.data`, for example what other providers give), and `release(data, allocator)` releases
  them on finishing.
- `editor.Import_Source_Provider{source}` gives a `Source_Importer`, a source the plugin imports
  whole and that is not a model, without a folder. Its fields are `name` (the dialog's filter and
  the messages), `extensions`, `claims(path, head)` (claims the file by its extension and its first
  `importer.SNIFF_BYTES`; it is tried before the formats), `prepare(s, allocator)`,
  `run(state, source, options, allocator)` and `release(state, allocator)`.
  - `prepare` runs in the editor's thread, before starting: what `run` needs from the session (for
    example, what other providers give) is gathered there, in the received allocator, and is the
    `state`. `run` runs in the import's thread with a job system of its own in `options.worker` and
    returns the report, the scene it wrote (`""` if none) and the error; it does not touch the
    session. `release` releases `state` on finishing.
  - A plugin can define its own providers so that other plugins join it: the one that gives the
    source gathers them in `prepare` and passes them to `run` through the `state`. This way an
    import plugin delegates to automatic bridge plugins the actors of optional domains, without
    importing them.
- The import runs in a thread of its own while the editor continues, and on finishing the registry
  rereads what it wrote ([content browser](panels.md#content-browser)). A file that no provider
  claims and that the engine does not import is an error that says so.

## A component with an inspector

- A `@(component)` of `runtime/` appears without editor code in the inspector, in `component.list`
  and in the scene API, by reflection; it is refined with `mirai:"..."` tags and `NAME_DEFAULT`
  ([rows by reflection](inspector.md#rows-by-reflection)).
- A relation with another entity is a `core.Entity` field: the inspector shows it as a slot, scenes
  store it as `Id` and resolve it on loading, and a copy of several entities points it to the copy.
  Examples: `Portal.exit`, `Screen.camera`.
- The relation's parameters go in the component with the slot; the named entity needs no component.
- An editor storage whose only field is `Inspector_Provider` can define
  `component(Inspector_Context)->bool` and `field(Inspector_Context,info,offset,label)->bool`.
  `true` replaces that section or field; `false` leaves the reflection. For the types a plugin shows
  in any component or setting: `number` (a number in its row, like the collision categories by
  name), `array` (an array with its rows), `popup` (what it opens over the inspector), `valid`
  (whether the API accepts a setting, with the problem if not) and `within` (a component that
  another's section shows: without a section of its own, outside the scene API, Paste and Add
  component; `vfx` says it of an emitter's values).
- An editor storage whose only field is `Component_Provider` defines `added`: what the plugin adds
  with a component the editor added (the `Collider` of a new `Character`).
- The callbacks are read from the default of the current metadata, without pointers to a reloaded
  library. `Inspector_Context` delivers session, world, table, entities and width.
- `inspector_fields` reuses generic fields, gestures and resets for a struct inside the component.
  Writes go through `field_write`, with the common undo.
- The `animation` plugin uses it to choose `Bone_Ref` by path;
  `vfx`, for the `Particle_Emitter` section: its fields with `inspector_fields`, its effect's with
  `asset_box` and the instance's values with `held_field_row` and `write`.
- For controls of its own (a curve editor) a [panel](#a-panel) is added.

## Simulation and pose confirmation

- `Simulation_Provider` (given by `physics`): the body an entity is part of, taking it to a pose
  while held, releasing it and settling what was written without simulating time. Without it,
  Simulate runs the same and the gizmo does not drag bodies. The editor keeps the inspector's
  providers in its cache and does not call their defaults per field.
- The editor reads `core.Network` ([network](../../mirai-core/references/core.md#network)): a data
  contract that serves any network plugin.
- `simulation_start(s)` starts the [full simulation](editor.md#simulate) and `simulating(s)`
  distinguishes its two modes. A tool that acts inside the copy allows them in its guard:
  `shown_world` delivers the copy and `edited_world` the document, which is not written while it
  runs.
- `simulation_body_target` sends a world pose to the body during Simulate and
  `simulation_body_release` restores its type on reaching it, through the `Simulation_Provider`
  (false without it); the API offers `simulation.move` and the gizmo uses the same requests. A
  group with independent bodies asks to select each body; a character stays under its controller.
  Kinematic contact is discrete: a very fast displacement passes through a thin object.
- `simulation_apply(s, ids)`, between frames, confirms the transforms of existing entities and ends
  the simulation. `simulation_apply_poses(s, poses)`, only in Edit, receives world poses
  (`Simulation_Pose`, normalized quaternion), validates everything before changing, respects
  selected parents and records a single undo; it creates no entities nor applies components.
- To create and arrange entities in one gesture, a tool combines the
  [cancelable previews](#cancelable-previews) with the primitives of
  [physics](../../mirai-physics/SKILL.md): it computes the poses in a copy of its own and confirms
  through the document's gesture.

## A plugin's game and player processes

A plugin that plays a game of its own from Play (`multiplayer`: a networked game) gives a
`Play_Provider`. The editor queries it at fixed points and keeps nothing of the plugin:

- On requesting Play from Edit (`start`), the plugin takes Play for its game or lets it continue;
  with unsaved assets it asks with `confirm_open(s, .Play_Plugin, ...)` (the buttons carry their
  `verb`) and continues in `confirmed`.
- On the bar it gives its rows of the run menu (`menu`), its label (`label`) and Stop (`active`,
  `stop`); the run button keeps the mode's icon, with or without online players.
- The user's run starts and ends (`play_begin`, `play_end`), a paused one keeps what it has open
  (`pump`) and a turn with online players adds its own (`turn`). Between frames, also in the manual
  editor, `poll`.
- In a shared session: what the host's presence offers of its game (`offer`, bytes the editor does
  not interpret), the game whose scene the guests copy (`game`), the host menu's rows for a guest
  (`host_menu`) and the arrival of that scene (`scene_arrived`).

The player process service (`player_processes_*`) belongs to the editor: it opens a `mirai-player`
per player with the plugin's arguments, over the library the editor loaded, shows them in their
part of the viewport and passes them input ([networked Play](editor.md#networked-play)).

A plugin keeps its own preferences with a `Preferences_Provider` (name, type, where they are and its
default), which the editor reads and writes with its own ([preferences](panels.md#preferences)).
