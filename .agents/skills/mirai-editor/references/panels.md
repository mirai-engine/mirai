# Interface, viewport and tools

The entire editor UI runs in one `ui.Context` per frame (`Editor_Ui.ctx`); `shell_build`
(`editor_panels`) builds bars/panels over the scene viewport. Notices use one-line toasts (`notify`)
or console; component/field help lives only in [inspector](inspector.md#descriptions).

## Layout

- The scene renders only in the unobscured area below the top bar and beside the rail/left panel
  (`App.scene`, `dock_scene_left`, `App.scene_shift`), saving GPU cost while keeping camera/pointer
  framing centered. `bars_snap` pixel-aligns edges. During Play, `Float_To.Safe` clears the bar.
  `Shell_Rects` caches frame rects; `free_region(g, size)` returns the scene area.
- **Top bar** (44 pt, draggable): Mirai menu (File), View (+ shortcuts), scrollable scene/prefab/
  asset tabs ([tabs](document.md#tabs)), toolbar (undo/redo, Move/Rotate/Scale, snap, World/Local,
  camera speed, **Tools** with plugin tools + [project panels](#project-panels), agent/collab
  avatars, Find, inspection mode, Graphics, Session, Play/Simulate/players/Apply). Non-macOS pins
  window controls top-right; narrow windows drop dividers/labels (`BAR_WIDE`, `BAR_ROOMY`). Prefabs
  omit scene graphics and add variants/Preview sunlight; Watch hides edit tools.
  `Graphics_Settings.show_fps` sits beside Graphics (top-right in standalone).
- **Rail (44 pt) & left panel (320 pt):** Create, Content Browser (startup default), Hierarchy
  (scene outliner or `Asset_Document_Provider.hierarchy`), World, AI, [Kai](kai.md#working-copy).
  Scene draws 16 pt behind rounded right corners. `DOCUMENT_LIBRARY_TABS` filters tabs per document
  type (prefab omits World; asset doc keeps Content/AI/Kai + optional Hierarchy). In Play the panel
  minimizes (only AI opens when paused).
- **Details (right panel):** shown on selection (or deleted-entity review); replaced by an active
  plugin tool or open project panel (`tool_panel_shown`, closed by Escape or selection change).
  **Floating** (default, 8 pt inset) or **Docked** (`Layout` preference, global or per doc type;
  resizable `DOCK_MIN`..40%, stays visible when empty to avoid viewport resize). Hidden during Play
  and entity-picker mode.
- **Drag** (`Drag`: Create card, asset or entity): `drag_dropped`/`drag_over` hit-test panels;
  dropping on the viewport calls `viewport_drop`.

## AI panel

Logic: [ai-tasks.md](ai-tasks.md); review: [ai-review.md](ai-review.md). Single continuous main chat
for the project; parallel subagents appear around it.

- **Top bar avatars** (`watch_bar_build`): main agent (always) + working/waiting/reviewable
  subagents with badges (`!` permission, `?` question, or change count); click inspects, right-click
  opens menu.
- **Panel header:** clock (chat search + finished subagents list), expand (full-width thread with
  right-side units column, hiding Details/docks/pins), and gear (**Agents** model/effort, **Memory**
  file editor, Connections, Show agents in scene).
- **Empty & active thread:** centered composer drops on first message (`AI_COMPOSER_DROP`). Status
  line appears only while units work/wait for review. Finished subagents post a report card
  (**N changes**, **Reply** chip, revert/accept); clicking title opens isolated subagent view.
- **Messages & controls:** shows final turn answer, errors, review summary, folded `Worked for`
  steps, and `entity:`/`asset:` clickable pills; answers render Markdown (`ui.markdown`). Below:
  live plan, active tool, inline permissions (no modal), `finish` options + `Other...`, and folded
  review bar (**Revert all** / **Accept all** / Build; Enter on empty composer accepts; Retry is
  API-only). Only visible lines are built/measured (`ai_transcript_touch`).
- **Composer:** Enter sends (steers mid-turn; dashed outline until delivered), Shift+Enter newline;
  selection chips (removable, pinnable), viewport capture on send, quiet model/effort picker,
  context-usage popup with **Compact now**, and **Annotate** tool (numbered viewport pins stored in
  DB, never scene). Details/asset docs show provenance row; Content Browser marks unreviewed assets
  with the agent's color dot.

## Viewport

Orbit camera (`Orbit`); `editor_tools` writes `core.View` (Play uses its own camera).

- **Controls:** RMB look + WASDQE fly; MMB pan; wheel zoom (click = [ping](editor.md#pings)); LMB
  gizmo/select/marquee; F focus. Stationary RMB opens context menu (`play_here.odin`): **Ask
  agent**, **Play from here/camera**, and `pick_through` depth-ordered entity list.
  `Viewport.capture` (`Look`, `Pan`, `Select`, `Gizmo`) steals pointer from UI until Escape.
- **Rectangle selection:** previews via `Highlight` without altering `Selection`/Details/AI context
  (enters if origin or projected AABB is inside; Shift/Ctrl append; recomputed only on change;
  derived nodes resolve to `entity_author`).
- **Debug overlays** (`gpu.Debug_Lines`, 4096 verts/frame, outside `World`): 1 m grid (X red,
  Z blue), depth-tested world-panel indicator disks for bodiless entities (distance-faded
  `INDICATOR_FADE`..`INDICATOR_REACH`, capped at `INDICATOR_CAPACITY`, occluded disks excluded from
  picking/AI context), light ranges/cones/sun arrows, audio min/max spheres, `Volume` bounds, drag
  preview boxes (`ghost.odin`), collab avatars.
- **Picking (`pick.odin`):** `pick_point` tests disks first, then mesh AABBs and renderer
  [`mesh_ray`](../../mirai-rendering/references/ui.md#offscreen-ui) (including posed skins; editor
  keeps no triangle trees). Ghosts (`ghost.odin`, `GHOST_LEVEL` `outline_only`, excluded from
  lighting/GI/rays) are pickable only when `ghosts_shown`.
- **Gizmo (`gizmo.odin`):** constant screen size, World/Local space (Scale always local), one undo
  step per drag, per-mode snap (`Viewport.snap`/`snap_rotate`/`snap_scale`, toggled by magnet or
  Ctrl). Zero-scale parent blocks child placement on that axis. Active `Viewport.plugin_tool` takes
  LMB and hides gizmo (W/E/R keep tool active; exit via Select, Escape with empty selection, or
  another tool).

### Inspection mode

`view_modes.odin`. Per-tab `Viewport.view_mode` (empty = `lit`), requested via `host.App.inspection`
(texture views, Play and prefabs stay lit). Includes core `VIEW_MODES` (`Debug_View`), plugin modes
([extensions](extensions.md#an-inspection-mode)), and `physics` `collision` / `collision.<category>`
(lines cached until physics/layer change; excluded from `capture` without `ui`). API:
`editor.view_mode.list`/`set`.

### Studio light

Per-tab View toggle (`Viewport.studio_light`, unsaved, Edit only): swaps `Sun`/`Sky` for
`PREVIEW_SUN`/`PREVIEW_ENVIRONMENT` after `render_sync` without touching world, history, or Play
(local lights remain). API read via `editor.inspect`.

### Viewport exposure

Menu/API (`camera.set` `exposure`/`ev100`): **Scene** (enabled `Sky`, default), **Camera** (from
`camera.set {entity}`'s `Exposure`, resets on scene change), or **Manual** (fixed EV100).

## Outliner

`Parent` tree of entities with `Transform`/`Name` (hides derived un-IDed children; builds visible
rows only). Double-click renames unlinked entities (F2 in Details for any); drag reparents keeping
world pose (prefab members stay inside instance). Prefab roots use prefab color;
[sections](document.md#sections) use `SECTION_COLOR` (`sections.odin`). Container rows offer Go to
root and View as tree (`Outliner.scope`).

## World

`world_map.odin`. Scene [sections](document.md#sections) map (absent in asset docs): Top (XZ) and
Side (height) views of `section_box` outlines colored by state (active, loaded, loading, unloaded),
streaming radii, and editor camera wedge. Click travels (`section_travel`, enabling section in view
if inactive); list shows GPU/file costs (`section_cost`, throttled by `MAP_COST_SECONDS`) and view
toggles. View-only (no undo/save). API: `editor.sections`, `editor.section_view`, `section_travel`.

## Create

Foldable preset sections (Logic, Shapes, Cameras, [plugin cards](extensions.md#create-cards)) using
Content Browser cards/grid/Ctrl+wheel zoom. Click arms repeated placement (Escape/RMB/tool cancels;
releases keyboard so Delete removes placed entity); drag places once. Placement preview renders
real geometry/prefab bounds without entities or undo. `.sound`/`.sound_set` places spatial looping
`Audio_Source` + `Audio_Occlusion`.

## Inspector

Details reflection rows, copy/paste, collision and material editing: [inspector.md](inspector.md);
emitter section:
[vfx-editor.md](../../mirai-world/references/vfx-editor.md#particle_emitter-section).

## Projects

`editor/projects.odin`. Machine recent list (`projects.mirai` / `project.Recent_Projects`). Dialog
in open project; full window in `--launcher` (`mirai edit` without project, unless "Open last
project"). Opening builds editor lib, packages and shaders on a background thread (cancellable) and
hands off (`--from-launcher` returns to launcher if shader compile is cancelled). New project copies
a template (`build.project_create`) and writes/installs chosen engine, catalog or git plugins. Rows
show manifest `thumbnail`, captured scene preview, or initial (`--headless` skips recent list).

## Content browser

`content.odin` shows the project + plugin registry.

- **Search & filters:** case-insensitive word search across name, path and clip names (flat scored
  results; typing while a card has focus searches without triggering shortcuts). Viewport-selection
  toggle filters to selected entities' assets (`host.entity_asset_ids`). Family icon strip (single
  active filter: Prefab, Model, Material, Scene, Texture, Animation, Sound, UI, Plugins); skeletons
  are hidden behind their meshes; `scene_data` (terrain/foliage/navmesh) shows only under Plugins
  or search. Ctrl+wheel zooms columns/list.
- **Layouts & navigation:** **Folders** (expandable tree, hover shows large preview), **Tabs**
  (top-level folder chips + grid), **Cards** (folder tiles + breadcrumb/back history). Virtual
  groups: Recent, Current scene (transitive deps), Favorites (`content.mirai`). Gear adds **Only
  unused assets** and **Show parts of imports**; Alt+click walks dependency graph (`Content.trail`).
- **File ops:** **Create** (`asset_create.odin`, `asset.create`: folders/scenes direct to disk;
  others undo steps; opens document if supported). **Delete** (`asset_delete.odin`, `asset.delete`:
  confirm modal -> `platform.trash`, no undo; package root unpins package; rejects open scenes and
  engine/plugin assets). **Rename/Move/Duplicate/Copy/Cut/Paste** (`asset_move.odin`, `asset.move`:
  immediate, no undo; preserves ids, moves owned parts, updates undo paths and `start_scene`;
  duplicates get fresh ids and strip import ownership).
- **Cards & gestures:** thumbnails with type color bar (`asset_color`), expandable `.anim` clips,
  import parts (`owner`), and prefab variants. Dragging places prefabs (linked), scenes
  (`Scene_Reference`), meshes, or assigns materials; clicking arms placement/assignment;
  double-click opens [asset document](#asset-documents). Find in Content Browser (`content_reveal`)
  clears filters and focuses the asset.

## Previews

- **Colliders** (`plugins/physics/editor/colliders.odin`): draws synced collider shapes of
  selection and authoring descendants in Edit (depth-tested + faint occluded pass), cached until
  pose/physics change; falls back to AABB if vertex budget fills.
- **Thumbnails (`asset_thumbnail`):** premultiplied-alpha studio renders in a 2048x1280 atlas (128
  at 64 px + 32 at 256 px), one render or load turn per frame, LRU eviction, keyed by
  `Thumbnail_Subject`. Reads mesh geometry directly from files (`triangles_append`, 400k tri
  budget); prefabs render visible meshes (`thumbnail_subjects.odin`); plugin types use
  `Thumbnail_Provider`.
- **Scenes (`preview_scene`):** first-open capture (after `THUMBNAIL_CAPTURE_WAIT` frames, 512x512
  via `host.app_capture_world`) or manual `scene.thumbnail`, saved in
  `.mirai/thumbs/<id>-<side>.thumb` (cleaned via `thumbnails_forget`).
- **Derived store cache:** mesh/prefab/texture/material/plugin thumbnails cache in the machine
  store under `THUMBNAIL_NAMESPACE` keyed by `THUMBNAIL_RENDERER` + dependency hashes (shared across
  projects and collab peers; Slang edits do not invalidate). Material spheres render in the
  renderer's material table (`UI_QUAD_MATERIAL_PREVIEW`).

## Asset documents

`asset_documents.odin`. Opens in tabs beside scenes (`App.ui_only` skips rendering the scene
underneath; Details/gizmo/Play disabled; shared left panel stays). Uses `Asset_Image` (up to 2
texels/pt, `Asset_View` orbit/zoom/pan, `PREVIEW_SUN`/`PREVIEW_ENVIRONMENT`).

### Material document

`material_document.odin`. Opens `.mat` (or bare `.slang` read-only). Preview redraws on change (or
every frame if `ctx.time` is read); toolbar picks channel (`thumbnail.frag` `debug_view`) and shape.
Agent variants (`editor.material.variants`) preview non-destructively with **Apply** (undo) and
**Save as new**. Details drags update in memory (`host.assets_material_set`) and flush `.mat` once
on release; imported fields offer revert. Feeds `Ai.material` context chips.

### Records document

`records_document.odin` over `editor/records`. Grid of `.records` rows/columns with inline editors
and right-side inspector (`held_schema_row`) for selected row, column or table. `rows_of` tables
show declaring columns read-only with jump link. Edits flush as one undo step when UI rests (bad
edits like duplicate names revert with warning). `Asset_Document.part` jumps to a row name.

Animation/sound documents: [previews](../../mirai-plugins/references/previews.md); particles:
[vfx-editor](../../mirai-world/references/vfx-editor.md#particle-document).

## Import

`import_file` (`sources.project_ingest`, Edit only) ingests files/folders into the machine store
(`--store` or `store.default_root`) and pins packages in `packages.mirai` without copying sources.
Runs on a background thread (`import_poll` applies results; blocks other asset writes with
`import_busy`). Detects type by content (`sources.source_kind`, including plugin formats/whole
sources); infers image usage (`sources.image_use`, overridable via `asset.import {image}`).

- Reimport keeps ids/settings and reuses texture/mesh caches; modified project documents prompt
  (`Modal.Import_Changes`) or fail in API unless `discard_changes:true`. New Surface programs
  auto-publish (`programs_publish_request`).
- **Parts & packages:** import parts carry `owner` (`asset.detach` clears with undo). Package
  members cannot be moved/renamed/deleted individually; act on the package root (moving updates
  `packages.mirai`, deleting unpins and trashes project documents/in-project source; store blobs
  remain).
- **Libraries (`content_library.odin`, `library.odin`):** This machine + collab peers appear as
  virtual roots (`packages.list`/`add`, `LIBRARY_MOUNT` for local thumbnails, `collab_thumbs_update`
  fetches peer thumbnails without fetching packages). `+` or drag pins folders, packages or assets
  with dependencies into the current folder.

## Graphics

Popup editing machine `Graphics_Settings` (Quality & Frame rate sections). Presets
(`GRAPHICS_PRESETS`) set quality fields (GPU default via `graphics_settings_for_device`);
Resolution and Antialiasing stay outside presets (unavailable AA falls back to TAA). Rows auto-bind
from `graphics=Label` / `choices=...` field tags. Applies instantly and saves to machine
`settings.mirai` (project overrides win on reload; no undo). API: `graphics.status`, `settings.set`.

## Project settings

File > Project settings lists `@(storage,setting)` by origin (Project, Engine, Plugins, Game),
sections (`section=`) and folded `advanced` fields. Left nav glides cards on section click. Edits
only the Project layer (Engine layer is written by Graphics, preferences, or `settings.set
{layer:"engine"}`); Editor category edits machine preferences. Project edits `project.mirai`
(Game/Window/Build; Build or Plugins toggles trigger editor rebuild/restart). **Input**
(`input_settings.odin`) edits `Input_Settings` per declared action with device menus and press-to-
bind listening (writes to active worlds immediately, removes entries matching defaults). API:
`settings.get`/`set`, `input.get`, `project.get`/`set`.

## Project panels

`panels.odin`, `api_panels.odin`. Data-driven custom controls in `panels/<id>.mirai` (versioned
JSON, excluded from shipped game; up to 12 buttons, 32 rows). Targets address component fields
(`entity` or `where` query, default first match) or project settings (dotted paths, no
hidden/transient). Buttons apply up to 12 target values atomically in one undo step ("Panel:
Button"); buttons touching the same target must set the exact same field set (`panel.save` enforces
this). Open from Tools (replaces Details, closes on Escape/selection change). **Restore** reverts
in-memory `Project_Panels.kept` values in reverse order. API: `panel.*`
([methods](../../mirai-agent-api/references/methods.md#project-panels)).

## Preferences

`preferences.odin`. Machine-wide `editor.mirai` (in `project.machine_folder`, outside git) stores
non-default flat structs (`Layout`, `Content_View`, `Viewport_Preferences`, plugin
`Preferences_Provider`) written when UI rests, on close, or before Build restart (never per frame
or during Play; `--headless` ignores unless `--preferences`). Per-project browser state (`Recent`,
`Favorites`, folder/filters; not search) saves to `.mirai/content.mirai`. API: `preferences.get`/
`set` (excludes `content.mirai`).
