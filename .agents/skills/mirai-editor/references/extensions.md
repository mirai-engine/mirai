# Extending the editor

A plugin or project editor package (`plugins/<name>/editor/`, `editor/`) contributes `@(storage)`,
`@(component)`, and `@(step)` to `Editor_World` ([plugins](../../mirai-plugins/SKILL.md),
[generator](../../mirai-core/references/generator.md)). It imports `mirai:editor` (and optionally
its `runtime/`); game code never imports it.

Every `*_Provider` below is a single-field Editor storage populated by its default; the editor
re-reads it on code reload (`provided_all`, `provided`) and keeps no stale library pointers.

## Package rules

- **Data:** flat `@(storage)` (add `free="proc"` if owning heap memory). Editor `@(component)`
  lives in `Editor`, not `World`; scene/Play data belongs in `runtime/`.
- **Steps:** default to `editor` loop, receiving `^editor.Session`, storages, `core.World_Ref`,
  `core.Input`, `core.Time`, `^host.Assets`/`^host.Frame_Extras`/`^host.App`, and tables. Generator
  rejects editor steps in `game` loop or editor types in `fixed`.
- UI steps guard with `if !g.begun || editor.playing(s) {return}`.
- Order against [editor steps](editor.md#the-editor-loop): pointer/click handling in `input`
  `after="editor_begin"`; scene edits/picking/lines in `frame` `after="editor_tools"`; panels in
  `ui` `after="editor_panels"` (before `editor_end`).

## A viewport tool

1. **Register & toggle:** call `editor.tool_entry(s, name, label, icon, shortcut)` in
   `Api_Provider.register` ([commands](editor.md#commands-and-shortcuts)). Check `editor.tool_on`
   / `editor.tool_set` (`Viewport.plugin_tool`).
2. **Extra keys:** handle only when `ctx.edit.id == 0`, no modifiers, `g.modal == .None`, and
   `ctx.popup.count == 0`.
3. **Pointer & picking:** check `s.viewport.hovered`, `!s.viewport.pick.active`, or call
   `editor.tool_pointer`. Raycast via `editor.pick_point`, `pick_ray`, `viewport_ray`
   (`batches=true` hits
   [instance batches](../../mirai-rendering/references/scene.md#instance-batches) via
   `render.batch_ray`, authoring entity via `object_id`).
4. **Transactions:** bracket strokes with `edits_begin` / `edits_end` / `edits_cancel`
   ([document](document.md#edits-and-undo)).
5. **Gizmo & keys:** `editor.tool_gizmo` (`Began`/`Moved`/`Ended`/`Cancelled`) + `tool_gizmo_draw`
   manipulate non-entity transforms; `editor.tool_keys` claims keys (e.g. Delete);
   `editor.tool_lend` lets W/E/R lend the viewport to selection gizmo (`tool_aside`/`tool_take`)
   while keeping panel.
6. **Visuals & brushes:** `host.extras_debug_lines_add`, `viewport_screen` + `ui.draw_line`/
   `ui.draw_polyline`, `ui.panel(ctx, id, editor.tool_panel(g, id))`, `editor.notify`,
   `editor.selection_gizmo`, `gizmo_face`. Shared brushes (`editor/brush.odin`):
   `brush_ring_points`, `brush_ring_draw` (`BRUSH_*`), `Brush_Adjust` (`brush_adjust_key`/`frame`:
   F/Shift+F, Ctrl fine, Esc/RMB cancel), `key_hint`, pen `core.Input.pressure`/`eraser`.
7. **Revision-tracked files (`editor/revision_history.odin`):** `Revision_Source` + `revision_sync`
   (`REVISION_STEPS_CAPACITY`) sync external asset files (terrain, foliage) to component revisions
   on undo/redo; external disk changes update the revision.
8. **Geometry preview** ([terrain](../../mirai-world/references/terrain.md)): show strokes via
   `host.assets_mesh_generate` + `host.extras_instance_add` (`replace_source`), freeing before
   `render_sync`; confirm via `editor.file_write` (in undo) or `editor.file_set` (revision undo).

## Cancelable previews

Exclusive gesture tied to a `tool_set` name:

- `tool_preview_begin(s, name, label)` (Edit + active tool, fails if already active), check
  `tool_preview_active(s, name)` each frame before writing (release temp storage resources if
  false; keep no row pointers), `tool_preview_end(s, name, apply)` confirms as one undo or reverts.
- Inside preview: public edit procedures work; `edits_end`/`edits_flush`/`edits_commit` do not
  confirm; Details is read-only.
- Auto-cancelled (leaving tool active) by tool switch, Play/Simulate, scene replace, code reload,
  close, Hierarchy/API select, API write, Esc, or Ctrl+Z.

## A panel

- **Custom canvas:** `editor.drawing(g, id, width, height, draw, user)` (`Drawing_Proc`, cap
  `DRAWING_CAPACITY` = 8); `user` must live until paint (storage field).
- **Tool panel:** `editor.tool_panel(g, id)` in `ui` `after="editor_panels"` replaces Details
  (`editor.details_build` embeds Details; `free_region` discounts it; hidden during entity pick;
  `editor.inspect` exposes `plugin_tool`). Independent panels open from View via `command_bind`
  with `menu=.View`, `group=editor.MENU_GROUP_PLUGINS`, `view`, `state`.
- **Widgets:** `ui.section`, `ui.property`, `ui.number_field`, `ui.toggle`, `ui.color_field`,
  `ui.id_derive`, `editor.card_begin`, `section_band`, `card_body_begin`, `row_begin`,
  `fold_label`, `fold_band`, `fold_section`, `fold_band_begin`/`end`, `search_field`,
  `scroll_shadow`, `row_description`.
- **Storage fields:** `editor.held_field_row(s, h, field, label)` (`Held_Values`: `key`,
  `type_info_of` from plugin library, `value`, `defaults`) honors `color`, `axes`, `width`,
  `icons=`, `description`; writes in place unless `write: Held_Writer` + `user` records undo steps
  (one step per drag/picker session).

## An asset document

`editor.Asset_Document_Provider` opens plugin asset tabs next to scenes
([view](panels.md#asset-documents), [previews](../../mirai-plugins/references/previews.md),
[vfx](../../mirai-world/references/vfx-editor.md#particle-document)).

- **Fields:** `kinds`, `count`, `hierarchy` (outliner room), `flat` (omits Graphics in bar),
  `creates` + `create(s, kind, id) -> []u8` (temp allocator, nil on error, used by Create &
  `asset.create`), `between(s, d)` (between-frame offscreen render via `host.app_world_draw`, see
  [effect preview](../../mirai-world/references/vfx-editor.md#effect-preview)).
- **UI & edits:** `ui` `after="editor_panels"` checks `editor.asset_document_active(s)`, builds
  `asset_workspace` / `asset_workspace_details`, `asset_toolbar` / `asset_toolbar_whole`,
  `asset_column_begin`/`end`/`divider`, `held_asset_button`, `asset_pick_row`, `settings_open`.
  Write assets via `editor.file_write` on gesture release (reread on active-document change).
- **Playback, keys, AI, drop:** `timeline_strip` (`Timeline_Clock`/`Timeline_Result`/`Timeline`/
  `Timeline_Lane`), `Asset_Playback` (`asset_playback_advance`, `asset_playback_strip`,
  `asset_preview_sun`). Bind document shortcuts with `Binding.document` (`command_menu_item`).
  Report AI context via `asset_document_pick` and `asset_document_show_say`. Consume
  `Asset_Document.part` and viewport drops via `editor.asset_drop_take(s, kind)`.

```odin
@(storage)
My_Doc :: struct {provider: editor.Asset_Document_Provider}

MY_DOC_DEFAULT :: My_Doc{provider = {
    kinds = {0 = MY_KIND}, count = 1, flat = {0},
    creates = {0}, create = my_asset_create,
}}
```

## Asset types of a plugin

Declare `asset_kinds` in `plugin.mirai`
([manifests](../../mirai-projects/references/projects.md#manifests)) to generate `kinds_gen.odin`
constants: `label`, `color`, `icon` (`editor.asset_kind_color`, `asset_icon`, `asset_kind_label`),
`extension` (`asset.list` without dot; `kind=` tag with dot,
[inspector](inspector.md#rows-by-reflection)), and `field` (auto-infers kind on matching
`Asset_Id` fields).

- Providers: `editor.Asset_Click_Provider` (card click outside Play) and
  `editor.Asset_Menu_Provider` (`ui.menu_item` entries).
- Reusable pickers/cards: `editor.asset_box`, `asset_list_open`, `asset_list_shown`, `asset_quad`
  (`preview_default`), `asset_cards`, `asset_card_begin`/`end`/`float`, `drag_dropped`. Example:
  [vfx](../../mirai-world/references/vfx-editor.md).

## Thumbnails of an asset type

`editor.Thumbnail_Provider` (cap `THUMBNAIL_PROVIDERS`, [thumbnails](panels.md#previews)):

- `subject(s, file, clip, subject) -> bool`: fills `Thumbnail_Subject` (1-based `clip`; nil `file`
  = empty-field default; false = icon/none; set `subject.provider` for custom rendering).
- `triangles(s, subject, vertices, materials)` (`editor.triangles_append`) or `image(s, subject,
  side, out)` (between frames, `side*side` premultiplied RGBA from `subject.data` /
  `THUMBNAIL_DATA`).
- Read plugin storage via `core.world_storage_of` on
  `core.world_ref(s.editor_world, s.info, .Editor)`. Subject references and bytes form the cache
  key. Example: [previews](../../mirai-plugins/references/previews.md#animation-thumbnails).

## Create cards

`editor.Card_Provider` (`CARD_PROVIDER_CAPACITY` = 8, `CARD_CAPACITY` = 64,
`CARD_GROUP_CAPACITY` = 8, `EDITOR_CARDS`) exposes `recipes/` (`Recipes` part,
[recipes](document.md#recipes)) in Create.

- `Card`: `recipe` (omitted if missing; `label` from recipe entity), `group` (default `Logic`),
  `icon`/`drawing`/`color` ([icons](../../mirai-ui/references/ui.md#widgets)), `component` (entity
  icon), `chosen` (fills matching empty `Asset_Id` from browser), `facing` (faces camera),
  `surface` (+Y along surface normal on place and center-gizmo move).
- `cards(s)` lists editor then plugin cards; all placement paths run `entity_create` with
  `Create_Desc.recipe`. Selected gizmos draw in `frame` `after="editor_tools"` via
  `host.extras_debug_lines_add`.

```odin
@(storage)
Decals_Cards :: struct {provider: editor.Card_Provider}

decals_cards_default :: proc() -> (cards: Decals_Cards) {
    cards.provider.count = 1
    cards.provider.cards[0] = {
        recipe = "decal", group = "Logic", color = {245, 170, 120, 255},
        component = decals.Decal, surface = true,
    }
    return
}
```

## An inspection mode

Declare each frame in `frame` before `ui` with `editor.view_mode_declare(s, View_Mode_Desc)` (cap
`VIEW_MODE_PLUGIN_CAPACITY`, cleared in `input`, undeclared falls back to Lit;
[inspection mode](panels.md#inspection-mode)).

- Unique non-core `name`, default `group` `Plugins`, non-empty `reason` disables mode.
- `record` runs in [`Inspect`](../../mirai-rendering/references/views.md#extension-stages) over the
  lit image; lines-only modes check `editor.view_mode_current` with a no-op `record`. Example:
  `plugins/portals/editor/view_mode.odin`.

```odin
@(step="frame")
portals_view_mode :: proc(s: ^editor.Session, m: ^Portals_View_Mode, r: ^erender.Renderer) {
    m.pipeline = erender.stage_pipeline(r, {stage = .Inspect, shader = "portals_nested"})
    reason := "" if m.pipeline != 0 else "Generate project shaders for portals_nested.comp"
    editor.view_mode_declare(s, {
        name = "nested", label = "Nested views", group = "Advanced",
        icon = .Split, reason = reason, record = portals_nested_record, user = m,
    })
}
```

## API methods

`editor.Api_Provider` registers methods in its `register` proc via
`editor.api_method_register(s, desc)`. Pass `type_info_of` from the plugin's own library (each
library has its own type table); `mirai build editor` validates all registrations; reload rebuilds
the registry.

- Give UI-facing methods an `entry` (or extra `editor.command_bind` entries). Handlers use
  `editor.shown_world`, wrap document/file edits in `api_edit_begin`/`api_edit_end` + `file_write`
  (read via `asset_read`/`host.assets_file`), or guard preview tools with `api_guard_edit` and
  confirm/cancel inside the call. Use `api.params_array_count` for partial arrays. Keep evaluation
  in runtime ([API](../../mirai-agent-api/references/api.md),
  [animation API](../../mirai-animation/references/animation-api.md)).

```odin
@(storage)
My_Api :: struct {provider: editor.Api_Provider}

MY_API_DEFAULT :: My_Api{provider = {register = my_register}}

my_register :: proc(s: ^editor.Session) {
    editor.tool_entry(s, "paint", "Paint", .Brush, {key = .B, set = true})
    editor.api_method_register(s, {
        name = "my.op", summary = "Runs my op.",
        params = type_info_of(My_Params), result = type_info_of(My_Result), run = my_op,
    })
}
```

## Runs the API drives

- `editor.Run_Provider`: observes tick-driven runs (`input`, `ticked`, `call`, `focus`, `ended`),
  storing state keyed by `Run.id`. Drive runs via `editor.play_tick` (`Api_Step_Input`) and inspect
  UI via `editor.play_ui_screen`
  ([`playtest`](../../mirai-plugins/references/plugins.md#first-party-plugins)).
- `editor.Edit_Follow_Provider` (`follow`): derives changes into the current undo step before
  recording (`edits_follow`; skipped during undo).
- `editor.Body_Provider` (`standing`, `measure`), read by `editor.play_stance` /
  `editor.play_body_measure` (fallback: `Unknown`, `BODY_PERSON`).
- Bot navigation: `editor.play_drive_to`, `play_drive_steer`, `play_drive_end`, routed by
  `editor.Route_Provider`.

## Importers of a plugin

Read via `provided_all` (cap `PROVIDER_CAPACITY`), run on the import worker thread (and identically
in `import_library` builds), reading sources in place without copying
([import](../../mirai-imports/SKILL.md),
[plugin formats](../../mirai-imports/references/imports.md#plugin-formats),
[content browser](panels.md#content-browser)). Unclaimed unknown files return an error.

- `editor.Import_Format_Provider{format}`: adds `importer.Format` (`Format.folder`, optional
  `prepare(library, root, info, allocator) -> Format.data`, `release`). Uses `asset.root_packages`.
- `editor.Import_Source_Provider{source}`: `Source_Importer` (`name`, `extensions`,
  `claims(path, head)` with `importer.SNIFF_BYTES` tried before formats, `prepare` -> `state`,
  `run(state, source, options, allocator)` using `options.worker`, `release`). Supports gathering
  sub-providers in `prepare` to delegate optional domains without importing them.

## A component with an inspector

Runtime `@(component)` auto-appears in inspector, `component.list`, and scene API via reflection
(`mirai:"..."`, `NAME_DEFAULT`, [inspector](inspector.md#rows-by-reflection)). `core.Entity` fields
render as slots and serialize/remap as `Id` (e.g., `Portal.exit`, `Screen.camera`).

- `editor.Inspector_Provider`: `component`/`field` (`true` replaces reflection), plus `number`,
  `array`, `popup`, `valid`, `within` (embeds sub-component, hiding standalone section/API/Paste/
  Add). Draw remaining rows with `inspector_fields`; write via `field_write` using
  `Inspector_Context`.
- `editor.Component_Provider`: `added` (companion components) and `start` (entity-aware initial
  value, also used by scene API).

## Simulation and pose confirmation

- `editor.Simulation_Provider` (cached; provided by `physics`): `owner`, `move`, `release`, `step`,
  `limit`. Without it, Simulate still runs without gizmo body dragging or settling. Networking uses
  `core.Network` ([core](../../mirai-core/references/core.md#network)).
- `simulation_start`, `simulating` (use `shown_world` vs `edited_world`), `simulation_body_target`,
  `simulation_body_release` (`simulation.move`, discrete kinematic contact).
- `simulation_apply(s, ids)` (between frames) and `simulation_apply_poses(s, poses)` (Edit only,
  `Simulation_Pose` with normalized quat, validates all before write, respects selected parents,
  single undo, no new entities/components).
- `simulate_until_rest(s, moving, ticks, rested)` and `settle_begin`..`settle_write` run
  [limited Simulate](editor.md#simulate) for drop/placement tools.

## A plugin's game and player processes

- `editor.Play_Provider` (`multiplayer`): `start`, `menu`, `active`, `stop`, `label`, `poll`,
  `play_begin`, `play_end`, `pump`, `turn`, plus collab hooks `offer`, `game`, `host_menu`,
  `joined`, `scene_arrived`.
- Editor owns `player_processes_*` ([networked Play](editor.md#networked-play)).
- `editor.Preferences_Provider` (`name`, `info`, `value`, `default`) persists plugin preferences
  ([preferences](panels.md#preferences)).
