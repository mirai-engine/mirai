# Method catalog

Methods of the `editor` package, of the active plugins and `engine.describe`, which belongs to the
server (`editor/api/rpc.odin`). **The schema of each method gives its params and its result**
(types, ranges, defaults, units, flags and the label of each field), and its `summary` says what it
is for: `mirai rpc describe <method|prefix>` shows it ([describe](api.md#mirai-rpc-describe)).
This catalog keeps only what the schema does not say: behavior, rejections, effects on undo, what
advances frames, what waits for Edit and common errors. Conventions, errors and concurrency:
[protocol](api.md).

## Server and execution

- `engine.describe`: without params it is the index: the core methods with a short summary, the
  names of the others by plugin, and which plugins the project uses and finds. Schemas come out
  with `methods`, the names of the ones a task needs in one call; `plugin` and `prefix`, which
  combine, give the summaries and guides of an area, and the schema when one method is left.
  `methods` goes alone; unknown names (all of them, in the error), a `prefix` that leaves none or
  a `plugin` without methods is `-32602`, and the last one names the plugins that have methods.
- `engine.diagnostics`: after a failed capture, test or Play, read it before repeating.
  - `since` with the previous `console.serial` reads only what is new.
  - A repeated id is an `asset_errors` entry with `problem:"Duplicate_Id"`: `detail:"Reassigned"`
    is a copy made outside the editor that received an id of its own in memory, which is kept with
    `asset.save` or left by deleting the file; `"Unresolved"`, a pair with an unsaved file, which
    is resolved by saving it or discarding it. For an asset of another version, `message` gives the
    `mirai import` that redoes it.
  - `problems` has one per world, the edited one and each Play
    ([problems](../../mirai-core/references/core.md#problems)). To know whether something still
    fails after fixing it: save `serial`, advance (`engine.step`, `play.step`) and read again;
    what has `last` greater than that `serial` is still happening. Opening a document clears those
    of its world; a Play starts without problems.
  - Classification of the validation messages:
    [rhi](../../mirai-rendering/references/rhi.md#device).
- `engine.status`: state of the editor, the document and the frame.
  - `cpu`: milliseconds of each part of the frame: platform, asset watching, game, editor and its
    four steps, render preparation, wait, recording and closing.
  - `gpu_timings`: per pass, in frame order. `counters`: what the plugin passes counted on the GPU
    two frames ago, by name, with four values each (`vfx`: `particles`, with the live particles and
    the emitters that have any).
  - `ev100`: the one the viewport exposes, before its compensation: the one the light meter took,
    read one or two frames later, or the manual one.
  - `functions`: the 16 most expensive loop functions per frame since the previous
    `engine.status`, with their settle.
  - `geometry`: memory of the pools (with the free ranges between their meshes and the largest
    one) and of the ray structures, and the
    [page](../../mirai-rendering/references/scene.md#scene-and-instances) slots with what the last
    frame requested, loaded, released and discarded.
  - `assets`: meshes, textures, materials and scenes loaded now, and how many assets were unloaded
    that no world names
    ([unloading](../../mirai-core/references/host.md#failures-unloading-and-watching)).
- `engine.step`: only in a manual editor; advances whole editor, game and render frames with a
  fixed `dt`.
- `engine.shutdown`: stops a Play and exits after replying. Fails with unsaved changes, of scenes
  or assets, unless `discard`, and with an open file dialog.
- `engine.gpu_lose`: the next submission to the GPU reports the device lost, as after a reset; the
  editor restarts with its documents
  ([GPU that stops working](../../mirai-editor/references/editor.md#gpu-that-stops-working)). After
  the restart, `engine.diagnostics` shows in the console what stopped it.

## Editor and viewport

- `editor.inspect`: selection, tool, snap, document, camera, interactions (capture, modal, popups,
  text being edited, pending dialog, hover), window, layout and `commands`: every entry of the
  menus, shortcuts and buttons of the editor and of its plugins, with the method it calls, its
  params and whether it is off or checked for the person now
  ([commands](../../mirai-editor/references/editor.md#commands-and-shortcuts)).
  - Rectangles are `[x,y,width,height]` in window points.
  - `layout.widgets` brings those of `command.<name>`, `menu.file|edit|view|help`, `stats` and
    `share` that are on screen.
  - `camera` is `{position,target,yaw,pitch,distance,fov}` (`fov` in vertical degrees).
  - `snap` is that of Move; Rotate and Scale have their own state and increments
    ([gizmo](../../mirai-editor/references/panels.md#viewport)).
- What a menu does, an agent does by calling the method of its entry with values of its own in
  place of what the entry takes from the person (`$roots`, `$toggle`, `$ask`): there is no method
  that runs entries by name.
  - `editor.tool` sets the mode of the gizmo or turns the tool of a plugin on and off;
    `editor.view` shows a dialog, a popup, a tab of the left panel, the name field or the studio
    light; the panels and the options of the viewport the editor remembers are `preferences.set`
    (`Layout`, `Viewport_Preferences`).
  - `scene.new`, `scene.group`, `scene.thumbnail`, `editor.copy`, `editor.save_all`, `play.release`
    and `camera.preview` are what the File menu, Ctrl+G, View, Ctrl+C, Save all, F1 and the camera
    preview do.
  - The prefab actions use the scope of the UI; `prefab.apply` and `prefab.revert`, that of their
    entity ([operations](../../mirai-editor/references/prefabs.md#operations)).
- `editor.section_edit`: `entity` with `Scene_Reference`: its section is edited in the
  world of the open scene, `scene.save` also writes its scene (and that of each section edited
  this way that changed) and the rest stays read-only; without `entity` it ends. Only in Edit and in
  a scene. Returns `{editing,unsaved}`: `unsaved` is the section it stopped editing with unsaved
  changes.
- `editor.sections`: the map of the World tab: each section with its rule, what it asks for
  (`asked`), what the view asks for (`view`, `Auto` with nothing), what it shows (`shown`, with
  `Loading`), its box in the world and its cost (`entities`, `meshes`, `textures`, `gpu_bytes` of
  its assets on the GPU now and `file_bytes`); the streaming sources and the camera.
- `editor.section_view`: `entity` and `state` (`Active`, `Loaded`, `Unloaded` or `Auto`): turns it
  on, off or back to the default in the editor view, without editing. It answers once it is loaded.
- `editor.section_travel`: `entity`: takes the camera to the section and turns it on in the view if
  what asks for it does not ask for it active, loaded when it answers.
- `editor.section_preview`: `entity` with `Scene_Reference`: the editor draws the `Sky`
  and the `Sun` of its section instead of the enabled ones, and the view takes the look of the
  inside of its box; without `entity` it goes back. Only in Edit; returns the `{sky,sun}` drawn (0
  where the section has none).
- `editor.select`: selects `entities`; the last one becomes active and none clears. What names no
  entity is `-32602`. A different selection is an undo step of the caller
  ([selection in undo](../../mirai-editor/references/document.md#selection-in-undo)).
- `editor.material`: opens and brings to the front the
  [document](../../mirai-editor/references/panels.md#material-document) of `material`, picks
  `parameters` (material values by name, up to 16; one it does not have is `-32602`) and sets
  `channel` in the preview, which the next chat message carries as context. Without `material` it
  closes the front material document. Only in Edit. Result
  `{open,program,source_revision,picked,channel}`.
- `editor.material.variants`: replaces the variants of the document of `material` (or of the front
  one) with `variants` `[{label,values}]`, up to six; an empty array removes them. The values are
  those of `material.set` by name and are checked against the parameters of the program and their
  ranges; the material does not change until the user picks one. Result `{count}`.
- `editor.input`: only in a manual editor. Each event runs a frame through the path of real input;
  returns what `editor.inspect` gives after the last one.
  - Held keys and buttons replace those of the previous event.
  - `mouse_position` and `mouse_delta` do not go together; `text` is printable ASCII.
  - Keys by `core.Key` name (`W`, `Left_Control`, `F5`); the Mac Cmd is `Left_Super`.
- `capture`: the only image of the editor and the game; requires a GPU. Draws `frames` frames (0:
  what the image needs) and writes a PNG. With `frames` at 0 it keeps drawing while textures stream
  in, up to a bounded wait. Only when nothing was drawn or textures were left, the result adds
  `textures_pending` and `instances_drawn`, `instances_culled` and `instances_occluded`, which tell
  a camera that sees nothing from a scene with nothing in it. A failure says the cause: the
  renderer's or the system's. What it shows:
  - `ui:true`: the last frame of the window with the editor around what it shows, as the user sees
    it; with a `.ui` in front (`editor.document`) the image is its document. `width`, `height` and
    `of` do not go with it. A turn's own run is never in the window.
  - Without `ui`, the image alone. `of` is `Game` (the caller's game through its camera with its
    game UI, drawn offscreen; a turn's run and the user's Play alike), `Scene` (what the viewport
    shows through its camera, the editor's in Edit and Simulate and the game's in a Play that has
    one, with the inspection mode of the tab and without panels, gizmos, lines, grid, selection or
    game UI) or `Auto`, by default: `Game` while the caller has one playing, otherwise `Scene`.
  - The image alone is `width` x `height` (0 to 4096): one side at 0 keeps the proportion of what
    it shows and both at 0 give its size. Drawn offscreen, the temporal effects of a game start
    over in that view (`frames` lets them settle): to measure stability frame to frame, use
    `ui:true`.
  - `path`: absolute (`C:/x.png`, or `/c/x.png` as Git Bash writes it) or relative to the folder of
    the project the editor opened, never to that of the process. The folder is created. The result
    brings the absolute path written and the size, with no image data; without `path` the PNG goes
    in `.mirai/captures/` and over MCP it comes back as an image.
  - Before drawing it opens the file for writing without changing it: if it cannot, it fails with
    the path and the system reason (`permission denied`...), or `-32602` if the path is a folder or
    has a root without a drive (`/tmp/x.png` on Windows).
  - `region` `[x, y, width, height]` keeps that part, in pixels from the top left of the image. A
    part outside the image is `-32602` with its size. `width` and `height` of the result are those
    of the part.
  - `seconds` (0 or more) sets the window clock, the one the renderer draws, when the frames
    start: a scene loaded anew and captured at the same seconds draws the same. Without it the
    clock keeps running. A game runs by its ticks, so `dt` and `seconds` do not go with it.
  - Filmstrip (`every`, and `count`): steps the caller's own run like
    `play.step` (pausing the user's Play), with `segments` as its input and nothing held after
    them, and draws a cell before the first tick and every `every` ticks: the whole image, a
    `region` in points, or a cell of `size` centered where the `follow` entity (its name, id or
    handle) projects through the game camera (with `ui`, inside the viewport). One PNG, cells left
    to right and top to bottom with their tick in the corner, scaled down past a sheet width;
    the result gives each cell's tick.
  - It changes neither the document nor the history.
  - A job compresses and writes the PNG: with a window the editor keeps drawing; a manual one
    waits without advancing frames.
- `view.viewport`: the snapshot saved when the message of the caller's turn was sent (`request`
  names another of its folder under `.mirai/ai`, and outside a turn it is required), without
  advancing frames or recapturing; fails if it does not exist.
- `editor.view_mode.list` and `editor.view_mode.set`: the core
  [inspection modes](../../mirai-editor/references/panels.md#inspection-mode),
  `collision` and `collision.<layer>` per object layer, and those the plugins declare in that frame
  (`nested` of `portals`).
  - The name is case-insensitive except for the layer. An unknown or unavailable one, or a prefab
    document, is `-32602` with the reason.
  - In Play the lit image of the game is shown; the mode comes back on returning to Edit. A mode of
    a plugin that stops being declared goes back to `lit`.
  - `collision` are lines: `capture` without `ui` does not include them.
- `editor.recover`: what an editor left when it ended waits set aside: loading, editing, saving
  and Play go on, and `editor.inspect` says so with `recovery_offered`. With nothing offered it
  answers `resolved:false`, so a retry after a timeout is no error; what could not be put back
  stays offered with `reason`, a failure of every part fails with that cause
  ([recovery](../../mirai-editor/references/document.md#recovery-and-failures)).
- `camera.set` (`idempotent`): returns `{position, target, yaw, pitch, distance, fov_y, exposure,
  ev100}`; all params are optional.
  - `position` and `target` are 3 numbers and must differ; `yaw` and `pitch`, radians.
  - `fov`: vertical degrees from 1 to 170. It is editor camera state: it starts at 50 and is kept
    with the camera of each document and on returning from Play.
  - `entity` (one with a perspective `Camera`) copies its position, where it looks and
    its FOV without modifying the scene; it excludes `position`, `target`, `yaw` and `pitch`, and
    `fov` and `distance` apply on top. It takes its `Exposure` (`exposure:"Camera"`); without one,
    that of the scene.
  - `exposure`: `scene` (the enabled `Sky`), `camera` (that of `entity`, given in the same call) or
    `manual`. `ev100` (from -10 to 24) is that of `manual` and only picks it. Moving the camera
    without `entity` stops exposing like the camera
    ([viewport exposure](../../mirai-editor/references/panels.md#viewport-exposure)).
  - The editor camera has no roll: for a camera looking almost vertically it keeps the position
    with the pitch at its limit. The other values are clamped to the camera limits.
- `editor.watch`: switches to `mode:"Watch"` watching the run of `task`, without stopping or
  editing it; without one it stops watching
  ([watching another run](../../mirai-editor/references/editor.md#watching-another-run)).

## Collision

The names are those the code declares (`Collision_Category`, `Collision_Preset`) and are
case-sensitive. `default` is the initial category and preset; `trigger`, the sensor preset;
`custom`, that of a collider with its own collision. Discover them with
`physics.collision.inspect` before editing, without computing bits or copying numbers between
projects; `names.create` declares a new one. Categories, sensors, presets and groups:
[collision model](../../mirai-physics/references/engine.md#collision-categories-and-presets).

- A mask is a list of names; `["*"]`, all of them. `Collision_Settings` is written with
  `settings.set`, by name.
- `physics.collision.get` reads the shown world (the document in Edit, the copy in Play or
  Simulate) and gives what rules: from the preset or its own.
- Without `component`, get and set take the only collision component of the entity; with several
  or none, the error lists them.
- `physics.collision.set`: on the document, in a single undo; keeps `group` and the other fields.
  `preset` makes it follow that preset and `custom` saves as its own what rules; `sensor`,
  `belongs` and `collides` make the collider custom starting from what rules. An unknown name or an
  incompatible combination fail with their cause without changing the document.
- `prefix` picks the collision inside the component. Without it, the root (`preset`, `sensor`,
  `belongs`, `collides` with their types) or its nested `filter` of type `Query_Filter`; with it, a
  struct path (`region.filter`); `""` is the root. The fields must have the collision types, not
  just the name; hidden, transient or read-only ones are not edited with these methods.

## Animation

The `animation.*` and `skeleton.*` methods of the animation plugin are in
[its reference](../../mirai-animation/references/animation-api.md). To animate, declare the intent
(`animation.character.setup`, `animation.request`, `animation.clip.edit`) and look at the result
with `animation.analyze` and `animation.capture` before touching keys.

## Cinematics

The `cinematics.*` methods of the `cinematics` plugin build and play timelines without `scene.write`
on their components; the keys and markers of a timeline (its shots and actions are markers on its
cameras and actors) are those of its clip, which the `animation.*` methods write. In Edit,
`cinematics.control` moves the head of the Tracks tool on the timeline (`animation.tracks.show` for
any clip): the document does not change and the image shows in the next frame (`capture`); in Play
it queues the command in the running world. Contract:
[cinematics](../../mirai-gameplay/references/cinematics.md#editor-and-api).

## Ragdoll

`ragdoll.setup` (plugin `ragdoll`) builds the bodies, colliders, joints and the `Ragdoll` of a rig
from the body of its `.skeleton`, detected in memory if it stores none: on the document and in a
single undo, which also replaces the ragdoll the rig had. Parts, shapes and joints:
[setup](../../mirai-plugins/references/ragdoll.md#setup-by-api).

## Interfaces

The `ui.*` methods of the `ui_inspector` plugin edit the `.ui` files of the project like the
document: each write is a step of the file history, which waits for Save, and one that would leave
a tree that does not load changes nothing and says why. A new `.ui` is created with
`ui.write` with a path that does not exist yet (or `asset.create {kind:"ui"}`) and written whole,
or a part of it, with `ui.write` (`document=@file`, `save=true`); `ui.capture` shows
it alone, at its size, as a PNG.
Contract: [the inspector](../../mirai-plugins/references/ui-inspector.md#api).

## Painting and shapes

Viewport tools through the API, on the document whatever plays and with the scene in front; each
call is an undo step and an error leaves nothing. Contract:
[paint](../../mirai-plugins/references/plugins.md#paint).

- `paint.stroke`: the points are world points and need not be on the surface; paints the vertices
  within `radius` of the stroke. A stroke that reaches no vertex is `-32602` and does not write the
  copy. Each stroke writes a new unsaved `.mesh` copy; `paint.clear` goes back to what the entity
  showed before the first one.
- `shapes.stamp` and `shapes.corner`: the Stamp and Corners modes of the Shapes tool at world
  points ([shapes tool](../../mirai-world/references/shapes.md#shapes-tool)). A cut that touches
  no outline shape, a refused stamp or a corner move that would cross edges is `-32602`. The
  brushes of a Solid are child entities with `Shape_Brush`, edited with the `scene.*` methods.

## Profiling

A capture records whole frames ([recorder](../../mirai-core/references/host.md#the-frame)): one zone
per part of the frame, one per loop function with its name from `info.steps`, a `job` or `range`
per `std/jobs` task on the thread that ran it and, per frame, the renderer's wait for a GPU slot,
the GPU passes and the conditions of the measurement. The editor keeps the last `PROFILE_CAPTURES`
(`editor/profile.odin`).

- `profile.capture` with `advance` runs the frames inside the call, holding the server like
  `engine.step`, and measures only between checkouts: if another measurement or a `mirai` build is
  running, it queues for them up to `wait` and then fails saying who
  ([turns](../../mirai-projects/references/build.md#turns-between-processes)). With
  `advance:false` it records the frames the loop runs afterwards (those of a window, or those of
  `engine.step`, `editor.input` and
  `play.step` in a manual editor); fails while another one is recording.
- With `advance`, once it has the turn, it runs frames until they stop speeding up and only then
  records: a GPU that was idle starts at a lower clock and raises it in steps, and lowers it again
  after a while without frames. The frames the API ran back to back right before count
  (`engine.step`, another capture): after a warmup of its own it runs none, so the frame of a later
  image capture is the same whether measuring or not. `notes` says how many it ran, or that they
  were still speeding up when the wait ran out (another load on the GPU or a scene getting
  cheaper).
- It refuses to measure with graphics API validation or, in a window, with VSync or a frame limit:
  the frame would last the limit and not the cost. The error says how to turn each off
  (`settings.set` or open without `--validation`). `allow_limited:true` measures anyway and the
  summary says `comparable:false`; a headless editor waits for neither the display nor a limit.
- `profile.compare` gives `comparable:false` with a blocking difference in conditions or if either
  of the two is not `comparable`.
- `profile.load` answers about the last load of the document (`scene.open`, a scene a game asks
  for), of Play (`play.start`) and of a section, without recording anything first
  ([loads](../../mirai-core/references/host.md#the-frame)): `ready_ms` until it was the document
  or the world, `resident_ms` until the end of the first frame after that which drew with nothing
  busy. While it is not, its state is `Loading` with what the last frame waited for; in a manual
  editor that needs frames (`engine.step`).

Reading a load:

- **Before and after ready.** The phases up to `ready_ms` are the call (documents read,
  instantiated, settled; for Play the copy and the plugins); what comes after is in `waits`, the
  one that ended last first, and in the assets with `after_ready`: in the editor the meshes,
  textures and materials load on demand in the first frame that draws them.
- **Where to look.** `phases` and `assets` give the costliest first; `slowest` names files. The
  physics, collision and navigation phases happen in the ticks, inside `physics_step` and
  `navigation_build`, which `functions` lists with the other loop functions of those frames.
  `Prepare` and `Nav_Tiles` are summed over the job workers and can exceed the wall time.
- **A section** counts what its own load did until it joined, and also adds it to the scene or Play
  that was loading then.

Reading a capture:

- **What limits the frame.** `paced` if pacing (`frame_limit` or vsync) took at least a quarter of
  the frame; `gpu` if the wait for a GPU slot took it (with vsync it includes the display's wait);
  `cpu` otherwise. If most are `gpu`, saving CPU does not shorten the frame; if `paced`, the cost
  is given by `cpu_ms`.
- **Presentation.** `presentation` counts the images that went to the display, generated ones
  included ([frame generation](../../mirai-rendering/references/views.md#frame-generation)):
  per second, the mean interval between two and its deviation (how even the pace is) and the
  latency from the start of a frame to its image. With generation there are twice as many images as
  frames.
- **Own time.** `self_ms` excludes the zones inside: a function that waits for its tasks has them
  as children (`job`, `range`); what the workers run appears with `thread:"workers"`.
- **Conditions.** `notes` warns about what invalidates a reading: engine at `-o:minimal`,
  validation, pacing, few frames, lost zones. Metal does not measure passes: its `gpu` is only the
  whole frame.
- **An optimization.** Capture, change, another capture under the same conditions and
  `profile.compare`; `profile.frames` and `profile.zone` explain a spike or a function.
- **Against `main`.** `mirai bench compare [project] [--scene S] [--camera x,y,z,tx,ty,tz]`,
  without pair scripts or a hand-built base. It builds head and the base (`--base`: `main`, a ref
  or a checkout with its editor already built) alike, dev unless `--release`, since two
  builds of the same mode compare; the base goes in the worktree of
  [`render check`](../../mirai-rendering/references/verification.md#render-check). With
  `measure.lock` taken it opens the two headless editors (no pacing, VSync or validation) and
  alternates `--pairs` captures: head, base, base, head… It prints a Markdown table for the final
  report of the task with the median and the spread of each build and the difference per pair with
  its range, warns if another engine program was open or the GPU had another load, and leaves the
  JSON in `--out`.

## History

- `history.undo` and `history.redo` are the caller's own, an AI turn or the API outside a turn
  ([undo by author](../../mirai-editor/references/document.md#undo-by-author)). They fail with
  `Nothing to undo`/`Nothing to redo` (the caller has no steps of its own) or with a step that only
  goes in order (a change of linked prefabs with steps of others after it: the error says what to
  do).
- In a manual editor they run a frame before replying:
  what the plugins derive from the history (the file of a terrain takes the revision of its
  owners) is already there when it replies.

## Scene

An entity is named as [the API names it](api.md#method-conventions). Each edit is a transaction
([protocol](api.md#concurrency-transactions-and-undo)).

- `scene.inspect` (`read_only`): free-form result
  `{path,dirty,playing,total,offset, entities[],shown,matched,omitted,left_out}`.
  - Filters: `entity` (only that one); `name` (exact name; `*` stands for any sequence and case is
    significant); `component` (only the entities that have it, by its name as
    [names of the API](api.md#method-conventions) take it; an unknown one is `-32602`).
  - Each entity gives `id`, `name`, `parent`, its `position` and the names of its components.
    `components` is `true` (every value, with the rest of the entity) or a list of names (only
    those); `include_runtime` also names those of runtime state.
  - Page: `offset` and `limit` (up to 4096; omitted, 256 when `entity`, `name` or `component`
    narrow it and a few otherwise, and `left_out` says what stayed out; `storage` or `storages`
    without those give only storages). `total` counts the live entities of the world,
    `matched` those that pass the filters, `offset` is counted over them and `omitted` says how
    many remain after the page (the next one starts at `offset` + `shown`).
  - `root` gives that entity and what hangs from it as the document `scene.write` takes: nested by
    `children` in their order, each with what differs from a new entity (its place local to the
    parent when it is not the identity, `visible` and `enabled` only when false, `off`) and its
    components with the fields that differ from the value they start with; a member of an
    instance gives `prefab:{asset,root}`, and `components:[]` gives only the shape of the tree.
    No filters nor page: a subtree of more than `limit` entities fails. Entities
    without an `Id` and what a section holds are left out.
- `play.inspect` (`read_only`): the same over the world of the caller's Play, with the params and
  the default `limit` of `scene.inspect` plus `player`, which picks the run of that player in a
  networked game of a turn. Its entities may have no id (those of a spawned prefab) and are named
  by `entity` (the handle in hexadecimal); their `parent` and the `Entity` fields of their
  components also give the handle. Without a game of the caller, `playing:false` and nothing else,
  as every method that only reads a game; what must advance or change one fails asking for
  `play.start`.
  - `storages` adds `storages`, the value of each storage of the world that is plain data (score,
    game state, queues), by name; `storage` filters with `*` and already requests them, and with
    no `entity`, `name` or `component` it answers no entities. Those of `scene.inspect` are the
    document's.
- On a large game, `name` or `component`, and `components` for the values of those; `omitted`
  says how many were left out.
- `scene.write` is the one way to change the entities of the scene, for an agent and for the
  entries of the editor (Delete, Duplicate and Paste call it): it makes the scene say what
  `entities` declares, nested by `children`, in one step. The document is read, matched and
  applied by `cook/author/scene_document.odin`, the same code `mirai scene write` runs on a file
  ([`mirai scene`](api.md#mirai-ui-and-mirai-scene)); the editor gives it the rows of the world
  (`editor/api_scene_write.odin`).
  - Without `root`, `entities` are those at the top of the scene; with it, the one entity is
    `root`. It matches by `id`, else by `name` among those of its parent, else by place among
    those left; it makes the others, and what the document does not declare goes with what
    hangs from it.
  - What an entity does not give is that of a new one: identity place, visible, enabled and
    without components. A component is its starting value with the fields it gives (keeping the
    hidden, `transient` and `read_only` ones); those it does not name are removed, also the one
    the editor adds beside another (the `Collider` of a `Character`). Siblings end up in the
    order of the document.
  - `merge:true` keeps what the document leaves out, so it names only what it adds or changes:
    an entity is matched by `id` or `name` and never by place, one at the top named by `id`
    stays under the parent it has, a component takes the fields given over the value it has,
    `null` removes it, `off` turns components the entity has off (and with `off` given, on those
    it declares and does not list), siblings keep their order, and `"delete":true` takes an
    entity away. `{"root":"Lamp","merge":true,"entities":[{"position":[0,2,0]}]}` moves one
    entity; a member of an instance that says `delete` is turned off.
  - `preset` names a [recipe](../../mirai-editor/references/document.md#recipes) of the engine or
    of an active plugin by the name of its file, case-insensitive; it stands for the components
    of its entity, whose values are the starting ones of the fields `components` does not name;
    without `rotation_deg` or `scale` the entity takes those of the recipe, and without `name`
    its name, with a number if a sibling has it. It also holds when rewriting an entity;
    `scene.inspect` gives its components, not the preset. Lights shine toward their -Z; `sun`
    looks from `render.SUN_DIRECTION` and `spot_light` downward. Adding, showing or turning on a
    `Sun` turns off the `Sun` that was on, in the same step
    ([one sun](../../mirai-editor/references/document.md#world-edit-procedures)).
  - A member of an instance of a prefab that is not its root keeps its parent: declaring it under
    another fails, and leaving it out turns it off (`disabled` of the result).
  - A new entity with `prefab` (the path or the id of a prefab) is placed as a
    linked instance, in the step of the write: what it and the entities under it leave out stays
    as the prefab gives it, also in a later write that names it the same way, and what the
    document says of its members, by their names, are overrides. With `{asset, root}`, as
    `scene.inspect` gives it, an instance declares all it has. A write changes no link of an
    entity that is there.
  - A new entity with `copy` (an entity by its name, a path or its id) is a copy of it and of
    what hangs from it, with new ids, beside it unless the document nests it under another
    entity; what the document says of it and of what it holds, by their names, changes the copy.
    The editor makes copies; a file written with no editor declares the entity in full.
  - A `core.Entity` field names an entity that already exists. An error says where
    (`entities[0].children[2].components.Light: …`) and changes nothing.
  - The result names what it made: `created` has the `{id,name}` of each entity of the document
    that is new, in its order, and of a prefab it placed the root of the instance, under which
    its members are.
- `batch`: 1 to 256 `{method,params}` of any methods, run in order (`editor/api/batch.odin`).
  A param that is exactly `"$N"` or `"$N.path"` (the paths of `--select`) is the result of call N
  or that field of it, and `"$$"` begins a text that starts with `$`. It stops at the first call
  that fails: the error says `calls[N] <method>:` and its `data` holds what the ones before
  answered. `transaction:true` makes what the calls edit of the scene one step of undo, taken
  back whole when one fails (their edits join the edit the batch holds open,
  `Api_State.transaction`); what they write to files stays.
- `scene.save`: `path` is a file or a path under `assets/` (by default, the document's); a new path
  becomes the document's file. Fails with a Play, as a guest of a session, or without a path in a
  scene never saved.
- `scene.open`: opens a scene, a prefab too, in the active document, with an empty history; without
  `path` it rereads the document's file. Fails as a guest.

**Entity of `scene.inspect`** with `components` true or a list of names; without it, `id`, `name`,
`parent`, `position` and the names of its `components`.

- `enabled` is `false` if the entity has its own `Disabled`; `active`, if it or something above it
  has it ([turned off](../../mirai-core/references/core.md#disabled-entities)). `off` lists the
  components turned off by themselves, which `components` shows with their values.
- `parent` is an id or `null` in what it returns; a param `parent` names an entity as any other.
  `prefab`, if it is a member of an instance:
  `{instance,asset,source,root}`, with `instance` the id of the root of the instance.
- `components` is `{Name:{fields}}` with those the scene stores and the inspector lists; not
  `Transform`, `Name`, `Id`, `Parent`, `Hidden` or `Disabled`, which have fields of their own.
- It omits `hidden` and `transient` fields. `include_runtime:true` adds those fields and the
  components of runtime state (also the diagnostics hidden in Play or Simulate) without making
  them editable or persistent.

**Values of `components`** (`{"Point_Light":{"intensity":40}}`):

- A `core.Entity` field is the id of an entity of the scene.
- An unknown name, a component derived by the engine, an out-of-range field or a value that changes
  a `read_only` field of `component.list` fail with `-32602` and the path of the field.
- `"enabled":false` turns off the entity and what hangs from it (`core.Disabled`). A base
  component (`Transform`, `Name`, `Id`, `Parent`) has a key of its own and fails as a component,
  with how to say it.

**Prefab hierarchy.** Creating, placing or moving something under an entity of an instance makes it
an added entity; deleting or duplicating a member, and moving it inside its instance, are overrides
of the instance. Moving a member that is not the root out of it (without a parent, or under a
member of another instance) fails with a message that says so
([prefabs](../../mirai-editor/references/prefabs.md#hierarchy-of-an-instance)).

## Spatial queries

`scene.raycast`, `scene.bounds` and `scene.ground` work on the document whatever plays; the game
world is read with `play.inspect`. They count the
meshes the viewport picking chooses (`Mesh_Renderer`, without physics or batch instances such as
foliage) at the place the locals give them, with the edits of the same frame.

- `scene.raycast` and the surfaces of `scene.ground` see only what is shown; the boxes of
  `scene.bounds` and `scene.ground` also count what is hidden or turned off, which the editor draws
  as a ghost. The `id` of the hit is that of the nearest entity with an id that has the mesh.
- `scene.ground` moves each entity vertically until the bottom of the box of it and what hangs from
  it touches the highest surface below it, with rays from its footprint; what hangs keeps its local
  place and the rays go through it. It rises at most its height or `GROUND_RISE`. Each one rests on
  the scene as it was before the call, and one that hangs from another of the list fails. `align`
  rotates the entity about its origin. It is an undo step; if one has nothing below it, it fails
  with its index and changes nothing.

## Editor documents

- `editor.document`: a document goes by its `path`, as `editor.documents` lists tabs and asset
  documents; without it `Activate` and `Preview_Sun` are the active tab and `Close` the asset
  document in front when one is.
  - Opening an already open file activates its tab; activating or opening a scene brings it to the
    front. `Open` of an asset that is no scene opens its
    [document](../../mirai-editor/references/document.md#asset-documents); one of a type
    without a document is `-32602`. `Close` of an unsaved asset that no open scene uses asks for
    `discard`, which gives back what the file has.
  - Switching scene document stops Play; a guest leaves the shared session first. `Preview_Sun`
    requires a prefab and touches neither its history nor its file.
- `scene.open` replaces the active document; `scene.save` and `history.*` act on it, also with an
  asset document in front. `engine.shutdown` requires saving or discarding if any tab has changes
  or any asset is left unsaved.

## Play

Play and Simulate run in the editor process, each run on its copy of the world and with its clock
([Play](../../mirai-editor/references/editor.md#play)). The user's and one per AI turn coexist. A
native failure of the process also ends its API.

**The caller's run**: that of its turn by the `X-Mirai-Ai-Task` header, or the user's outside a
turn. A turn that started inside the user's Play and did not open its own reads the user's. In the
result of `play.status`, `paused`, `simulating` and `input_released` are the user's;
`input_released`: F1 or the chat released the input, or Simulate reserves it for the editor.

- `play.start`: saves a recovery copy if there are changes and clones the world; fails if the copy
  is not saved or the world is not created.
  - Outside a turn it opens the user's Play, which the editor shows; a game already playing answers
    its state while the document is as it was when it started, and starts again when it changed.
    `from` `Camera` or `Point` (with `point`) is Play from camera or from here: player 1 appears
    there before at a spawn point; in a turn or with `simulate` it fails.
  - In a turn it opens a run of the turn even if others play: the editor does not change, it
    advances with `play.step`, ends with the turn and repeating `play.start` returns the same one
    unless the document changed since it started, when it starts again.
  - `online` without the `multiplayer` plugin fails. Outside a turn it is the user's networked
    Play, which returns while it compiles (`play.network.status` until `Running`) and also works
    without `online` while the editor shares its scene as host; in a turn it also creates a run per
    online player (`player` 1 onward) that joins it inside the editor.
- `play.stop`: outside a turn it also ends the networked game. A turn does not stop, pause or
  override the user's Play.
- `play.pause`: only the user's Play; fails without a run and on that of a turn. Resuming goes back
  to the newest tick it played; with `here`, it continues from the tick `play.seek` went to, with
  what was edited there, and discards the later ones.
- `play.step`: pauses the user's Play, or takes the run of the turn. Input reaches only that run;
  between steps the viewport keeps the game's camera and builds its UI without advancing time, so
  a step can hover and click the game UI and the game reads those events on its next tick;
  in a networked game of a turn all its runs advance and the input goes to that of `player`.
  - Input: keys, buttons, `mouse_position`, `text` and gamepads arrive through the path of real
    input. The pointer stays where a step leaves it and the game UI takes it with its clicks
    (window points: the image of `capture` over the density). The UI of a turn's run sees
    only what its steps give, never the user's pointer.
  - Local seats (`play.start players`): gamepad `slot` i belongs to seat i; keyboard and mouse go
    to the focused seat, which `focus` changes like `input.focus`.
  - `until`: up to 8 conditions of `play.check`; runs until the first tick after which all are met,
    with `for` as the maximum (`ran` and `met` say so). A badly written condition fails before
    running; if it becomes invalid later, it fails saying after how many ticks.
  - `segments`: a timeline in one call, each segment holding its input for its `for`
    and its pointer, wheel, text and taps in its first tick; the
    mouse motion is spread over its ticks. It replaces `for` and the input fields, which fail
    beside it, and its ticks add up to at most those of a step.
  - Edges are against what the previous tick held, so a press is a segment with the key and a
    release the next one without it. A tap (`tap_keys`, `tap_buttons`, a gamepad's `tapped`) is
    pressed and released inside one tick and never down, like a press shorter than a tick.
  - `trace`: up to 4 entities (selected as in `play.inspect`), a storage or `view`, and the values
    as [`play.get`](#play) names them (or paths inside the storage or the view). Its rows are read
    between ticks, before the first, every `every` and after the last, so the rows of a long step
    need a larger `every`. In the first row a path that is not there fails, unless it names a
    component the entity does not have yet; later, what is gone is `null`. With `view` the
    entities named are its `points`.
- A duration is one param, `for`, in every method: a number is ticks, exact, and a text ending in
  `s` is seconds (`{"for": 120}`, `{"for": "1.5s"}`); a place of the past takes the same form.
- One syntax names a value in Play, for `play.get`, `play.check`, `until` and `trace`:
  `Component.field.0.field` (`a[0].b` reads as `a.0.b`), or a key of the document of the entity
  (`world_position.2`).
- `play.check` (`read_only`): each condition reads a value (`field`) of an `entity`, of a storage
  or of the `view`, as `play.inspect` or `play.view` write them, and compares it with `number` or
  `text`; without `field`, the entity gives its `world_position`. With `view` the entity named is
  `points.0`.
  `Exists` and `Gone` say whether the entity, the component or the field is there: what is not
  there is a reading, not an error. A name or a field the game does not have is `-32602` with what
  exists. A `passed:false` is a result, not a failure.
- `play.view` (`read_only`): what the player sees, read from the run's `core.View` and the camera
  of the focused local slot of `engine/camera`: the camera with its place and lens, its mode and
  the blend into it (`progress` of the time, `weight` after the ease; 1 when it does not blend),
  what its `Camera_Follow` follows and how far, and where each of `points` shows (normalized from
  the top left of the view and in its pixels, `in_front`, `on_screen`). An entity projects its
  middle (the center of mass of a body, or the middle of what hangs from it), not its feet. The
  view is that of the last frame the run drew or stepped.
- `play.set`, `play.spawn`, `play.destroy` and `play.push` change the caller's run between two
  ticks, as the game would, without the document or the history; a turn does not touch the user's
  Play.
  - `play.set`: component values on top of the current ones, with `Entity` fields as handles;
    `null` removes one. `position` and `rotation_deg` are world values and teleport with
    `core.place`: a free `Transform` changes now and one owned by a library (a physics body) jumps
    on the next tick. It reads everything before changing anything.
  - `play.spawn`: the prefab appears now (`scene.spawn`), with `Prefab_Instance` on its root, which
    it returns as a handle.
  - `play.push`: requests to a storage with a `core.Queue` (`Seat_Requests`, `Spawns`, `Places` or
    one of the game), with the schema of the type of its elements; the functions of the next tick
    read them.
- `play.input`: holds actions of a seat by name
  ([holds](../../mirai-gameplay/references/control.md#seats)), never keys, so rebinding changes
  nothing; the kind comes from the run's input map and a value
  that does not fit it is `-32602`. They act from the next tick for whole ticks: `play.input` and
  then `play.step` give the same game every time, paused or not. The seat is the focused local
  one, another by `slot`. In a networked game a player is held in the
  run of its client (`player`), whose seat sends the held actions to the server with the others;
  the seat of a connection in the server's run is refused, since it takes what its client sends.
  An action is held for its `for`.
  Typical test: hold `jump` for 1 tick, `play.step` 30 ticks with a `trace` of the height (or
  `capture` with a filmstrip that follows the body), `play.check` the height.
- `play.record`: requires a GPU. Deletes the previous sequence in the folder, pauses the run,
  advances it `1/fps` of game time per frame (with its `Clock`), draws the world alone through the
  camera of its `View`, without screen UI, and writes `frame_000000.png` (16 bits, after the
  tonemap) or `.exr` (half, before the tonemap, linear) and `audio.wav` (32-bit floats, at the
  sample of each frame). It ends paused; the recording holds the server.
  - Reviewing a run costs one image: read `manifest.json` first (a header line, then a line per
    frame with its file, the `tick` it shows, the game `seconds`, the camera and the `inputs` that
    `play.input` held in its ticks), then look at `sheet.png`, `sheet` tiles of evenly spaced
    frames from the first to the last, left to right and top to bottom, each with its tick in the
    corner; the manifest's `sheet.frames` gives the frame of each tile and each frame its `tile`.
    Open a full frame only for a tile that looks wrong, and `play.seek` to its tick to inspect it.
  - The sheet is 8-bit sRGB: from `Exr` it is the linear image encoded and clipped at 1, without
    the tonemap. `sheet:0` writes none.
- `play.history` and `play.seek`: the past the run keeps (not networked) and the jump to one of its
  ticks, paused, playing the frames again from the previous copy; `matches` false says that what
  was played again is not what was seen. Fails with the range if the tick is older
  ([history](../../mirai-editor/references/editor.md#play)).
  - Both act on the caller's run or else the user's last Play kept after Stop (`stopped`), which
    `play.seek` opens again paused outside a turn. `to` of `play.seek` and `from` and `to` of
    `play.history` are a tick or a game time, as a duration is.
  - Both `trace` and `verify` play the kept frames again on the run's World and put it back after:
    the game, paused or playing, stays as it was. A trace takes the syntax of `play.step`'s and
    gives a row per kept frame that reached `every` ticks past the previous row (a frame that ran
    several ticks shows the last); past `API_TRACE_ROWS` rows, `next` is the `from` that goes on.
  - `verify` replays each span between keyframes and compares the transforms hash of every frame
    and, at the next keyframe, every entity and storage as `play.inspect` writes them, stopping at
    the first span that differs. A keyframe made from an edit while paused is not compared.
- `play.observe`, `play.qa.*` and `play.explore` belong to the `playtest` plugin.
- `play.observe`: one small answer for one decision; the rounded numbers are what a model reads.
  `problems` lists what is new since the caller last observed this run; `stuck` comes from the
  monitors when `play.qa.start` armed them, else from comparing the place between two observes
  while the body asks to move. With `step` it first runs `play.step` with those params and adds
  its `ran`, `met` and `trace`, so one call is act plus observe.
- `play.qa.*` and `play.explore`: [explore and QA](../../../../docs/game/testing/explore-qa.md).
  The first call of the API on a run reserves the log of its inputs, which a tick writes into; a
  run the API never touched tests one pointer per tick.
- `play.player`: fails without a run. The seat is that of the focused local player
  (`input.focused`); its body is `Seat.body` and the camera `render.View_Camera`, or else the one
  under the body. The AI context
  reads the player with the same `play_player_snapshot`.
- `play.ui`: what the last `engine/gui` frame built; without `all`, only what is seen, which is
  what can be clicked. Names come from the `.ui` (those of a widget, `instance/node`); the `rect`
  of a screen node is in points of the game window, for `play.step`, and that of a `World_Widget`
  is not given: it lives in its panel. Inside a `List`, state of any copy and `rect` of the first
  element.
- `play.audio`: the voices of `Voices`, with volume and pitch given before bus and distance. The
  mixer is the editor's, shared by all runs; it reports no pause.
- `play.scenario.run`: plays scenario files one after the other in the caller's run and answers
  one report per file ([scenarios](../../../../docs/game/testing/scenario.md)).

**Networked game**
([networked Play](../../mirai-networking/references/multiplayer.md#networked-play)).
`play.join` and `play.network.status` are registered by the `multiplayer` plugin: without it they
do not exist. Only outside a turn. Their players read the saved files: with unsaved assets,
`play.join` and `play.start` with `online` (or while it shares the scene) fail with the list of
`assets_unsaved_paths` and the fix (save them with `asset.save` or pass `saved_only:true`, which
plays with what the files have), like the question of the UI's networked Play. `play.join` fails
if the host does not serve a game.

## Simulation

Runs the whole scene with the editor's camera and controls, without player input
([contract](../../mirai-editor/references/editor.md#simulate)).

- `play.start {simulate:true}` starts the copy; fails if a Play or Simulate already exists (and
  keeps that run), from a turn (a turn simulates with its own run and `play.step` without keys) and
  with `players` or `online`. `play.stop`, `play.pause`, `play.status` and `play.inspect` act on
  it; `play.step` rejects non-empty player input.
- `simulation.move`: the movement pushes dynamic bodies and a large one can take several ticks;
  `release` leaves zero velocity on arrival. Rejects characters and children of a compound body:
  the entity that owns the body is moved.
- `simulation.apply`: the `entities` must be distinct and exist in the copy and the document. It
  does not include created entities or component changes.
- `physics.settle`, only in Edit: the
  [Simulate limited](../../mirai-editor/references/editor.md#simulate) to its `entities`, which
  need a `Collider`. Dropping a pile is `scene.write` of the objects
  above where they fall, then `physics.settle` of them; the poses are one undo step. An entity that
  cannot fall is `-32602` naming its index; `rested` false and `reason` say what the tick limit cut.
  `physics.drop` only ends the Drop gesture a person holds open (`Confirm` or `Cancel`).

During Simulate, `editor.select`, `editor.inspect`, `editor.input`, `camera.set` and the viewport
actions act on the copy; `editor.input` still requires a manual editor and `capture` with `ui`
captures the image with the editor. `scene.inspect` reads the document. On stopping, the original
camera and selection return. The actions are `simulate` and `apply_simulation`; `pause`, `step` and
`stop` work in both modes.

## Saves

The slots of the project's saves folder, the same as the shipped game's on that machine
([save](../../mirai-gameplay/references/libraries.md#save)).

- `save.list` reads only headers, in Edit and in Play; with `slot`, that one. It also gives the
  slots that do not load (corrupt or of another version) with their `error`.
- `save.delete`: with a run of its own of the caller, it asks the game, which first writes what is
  pending (it could create the slot again); without it, it deletes the file. It is not an undo
  step.
- `save.write` and `save.load` act on the caller's run; without it they fail and ask for
  `play.start`, and a turn without a run of its own does not touch the user's. They push the
  request in `Save_Requests` and advance until its `Result`, as when the game asks for it:
  - the user's running Play advances frames until the slot is written with its thumbnail;
  - a paused one or the run of a turn advances one tick (like `play.step` without new keys) and
    writes without a thumbnail.
- `save.load` replaces the world of the run: the handles of `play.inspect` change.

## Build

`build.start` compiles the project's `editor` library, also during a Play, and answers when it
ends, with `phase` and each error with its file and line in `diagnostics`; the editor goes on
drawing meanwhile. It fails if one already runs. If it succeeds, the editor loads the new code
without closing: the API, the scene, the history, the Play and the agents' turns continue, also
with a new or changed component or storage
([reload](../../mirai-editor/references/editor.md#build-and-reload)). Only when the migration cannot
leave the engine's data in place does the editor restart with the open scene (`restarting`) and
the API disappear for a few seconds (`mirai rpc --wait-until` keeps waiting for it). `build.status`
says the same at any moment; `target:"shaders"` publishes the shaders of the project and answers
when the viewport draws with them, which `mirai shaders` asks for.

- `play.start` compiles first if an Odin source of the project or its manifest changed since the
  last build that remains and answers when the game plays; if the build fails, it fails with the
  first error and the rest in `data.diagnostics`.
- `build.check` checks the types of the project code (game, editor and plugins, with the generated
  world) without compiling or loading anything, and replies when done with each error and its file
  and line. `build.test` compiles and runs the `@(test)`s of a project package (`package_folder`,
  `game` if missing; `tests` by name) against the libraries the editor loads, without loading them,
  with the runner and the executable of `mirai test` of that package
  ([checks and tests](../../mirai-projects/references/projects.md#checks-and-tests)) and replies
  when they end with each test that failed and what it logged. Every `build.*` method waits until
  its action ends; the editor keeps drawing frames meanwhile, since the one job slot runs off the
  frame. None runs while another does.

- With `target:"game"` it compiles the shipped game like `mirai build game`: first the saved
  shaders (without the editor's unsaved programs), then the game with its cooked assets in `out`
  (relative to the project; empty, `.mirai/game`). It does not restart the editor; `build.status`
  says `game`, the executable it left.
- `player.start` opens the game in a window of its own, like `mirai play`: it compiles the `play`
  library first (`building` meanwhile) and runs `mirai-player --project`; with `shipped`, it runs
  the executable of the last build of the game (or the one in `.mirai/game`). It reads the saved
  files (with unsaved assets it fails and names them), its output goes to the console and it ends
  with the editor. `player.stop` closes it; `player.status` says whether it runs and with which
  code it ended (`-1`: stopped or not started). There is one at a time; while it compiles there is
  no Build, which generates the project's world in the same folder.

## Project

`project.get` returns `project.mirai` as the file writes it and each plugin the project sees:
`active`, `named` (the manifest names it; an active one not named is a dependency or automatic) and
`needed_by` ([manifests](../../mirai-projects/references/projects.md#manifests)).

- `project.set` receives the manifest fields that change (`window` and `build` field by field;
  `defines` replaces the list) and `plugins: {"<plugin>": true|false}`. Everything is validated
  before writing: an invalid field, a plugin that does not exist, an automatic one, turning off one
  that another active one needs, an `icon`, a `thumbnail` or a `start_scene` that do not exist are
  `-32602` with what failed and how to fix it, and the file stays the same.
- It answers only `building` and `active_plugins`; `project.get` gives the manifest and every
  plugin.
- A change of `plugins` or `build` launches an editor Build (`building`), which restarts it like
  the dialog's switch; the rest applies when the game is opened.

## Prefabs

A prefab is a scene whose kind is Prefab, with exactly one root, named by `asset` as any asset
is: a path under `assets/` or its id. `scene.new` and `asset.create` make one with `kind`
`Prefab` (`prefab`), `kind` in a document of `scene.write` changes the kind of the document, and
`editor.documents` says the kind of each tab. `asset.list` says `prefab` of every scene and
`prefab.list` lists them. Those that edit are transactions. Unknown id, no id, prefab not found
(a scene that is not a prefab is none: the error says so), nonexistent override and "is not part
of an instance" are `-32602`; the rest, `-32000`
([errors](../../mirai-editor/references/prefabs.md#errors)).

- An instance is named by its `root`. `prefab.create`, `prefab.variant.create` and `prefab.apply`
  leave the prefab files they write unsaved, as any asset an edit changes: `scene.save` or
  `asset.save` writes them.
- `prefab.list`: the instances the document placed, not those its prefabs place. A `stale`
  instance is not up to date with its prefab as its files give it now, that file or the file of a
  prefab it places having changed; `prefab.refresh` updates it, and nothing is stale after it.
- `prefab.inspect` with `entity`: `kind` of an override is `field`, `added`, `removed`, `turned` or
  `child` (the entity was added by the instance); a turned-off member is an `added` of `Disabled`.
  The overrides are derived then, by comparing with the prefab as the instance was last brought up
  to date with it; `stale` says the same as in `prefab.list`. `links` names the instance that
  placed the entity and then each instance inside it that the entity is of (the crate of a placed
  shelf), with the `root` of each among the entities of the document.
  With `asset` it gives the prefab with its own instances up to date, and its `base` and
  `chain` if it is a [variant](../../mirai-editor/references/prefabs.md#variants) (zero and empty
  if not).
- `prefab.variant.create`: `prefab` is the base by file, path or asset id; writes the variant at
  `path` and places nothing.
- `prefab.apply` with `target:"Base"` writes to the instance's variant and from it to its base; if
  the prefab is not a variant, `-32602`.

## Components and assets

- `component.list`: free-form result `{components:[…]}`. Without `name` or `names` an index: each
  component with `name` and a short `description`, and `left_out`. With them, up to 16 in one call,
  each with `name`, `library`, `description` (empty if the type does not declare one), `default`
  and `fields`.
  - Field: `path`, `type` and, where applicable, `element`, `count`, `options`, `min`, `max`,
    `unit`, `label`, `read_only:true` (missing if false) and `description`, the comment on the
    field's line ([generator](../../mirai-core/references/generator.md#attributes)).
  - `type` is `Color` for a color, `Quaternion` for a rotation and `Text` for a text; the other
    arrays are `Array` with `element` and `count`. An angle carries `unit:"rad"`.
  - `default`: the value it starts with when added.
  - A component that is not plain data brings `plain_data:false`, without `default` or `fields`.
  - A component declared `@(component,derived)` and hidden and transient fields appear only
    with `include_runtime:true`; asking for a derived one by `name` without it
    fails saying so. A component with no saved field (a marker) is listed, added and saved.
- `asset.list`: rescans the registry. `kind` filters by the name of the type as the result gives it
  (`mesh`, `sound set`, case-insensitive and with `_` for a space; that of a plugin type is the
  extension of its files, `particle`); empty or `all`, all of them. Free-form result
  `{root,assets:[{path,asset,kind,prefab,size,dependencies,used_by,owner}],total,offset,shown,
  broken,duplicates,missing}`; `prefab`, only on a scene, says whether it is one; `used_by` counts
  the files that depend on the asset (the inverse index of the
  [registry](../../mirai-assets/references/formats.md#registry)) and `owner`, only on a part of
  another asset (that of an imported prefab), is its owner.
- `asset.import`: what the Import button of the content browser does with any source it imports
  ([import](../../mirai-editor/references/panels.md#import)), wherever it is on disk: the
  editor reads it and writes only in the assets folder. `folder` replaces the folder of its type; a
  source that a plugin imports whole (a map) does not accept it. It imports, writing to disk (it
  is an operation on files) while the editor goes on, and answers when it ends: whether it wrote
  (`ok`), its message, the scene of a map and the assets it wrote (`kept`: its file was already
  the one it gives). `asset.import_status` gives the same, and whether one runs (`importing`), at
  any moment. While it runs, another import and whatever writes assets fail saying what is being
  imported. Reimporting keeps ids and files, which the sidecar of the source lists
  ([identity](../../mirai-imports/references/imports.md#identity-and-reimport)).
  `image` (`color`, `data`, `normal`, `normal_green_down`) says what an image imported on
  its own holds, over its settings and its name (a packed metallic-roughness or a mask is `data`); a
  source in the project keeps the choice in its settings
- `asset.detach`: `asset` (path or id) is a part that leaves its owner: it is left without `owner`
  and shown alone; the import keeps writing it and leaves it out
  ([parts](../../mirai-imports/references/imports.md#parts)). It is an unsaved edit, with undo;
  returns `{asset,path,owner,unsaved}`. One that is not part of anything fails saying so.
- `asset.create`: what Create of the
  [content browser](../../mirai-editor/references/panels.md#content-browser) does: `kind`
  (`folder`, `scene`, `material`, `sound_set`, `strings`, `font`, `particle` or a type a plugin
  creates, such as `ui`), `folder` under the assets folder and `name` without extension; without a
  name it takes a numbered "New <Type>". A folder and a scene go to disk at once; the rest is an
  unsaved edit, with undo, and that of a plugin is written by its plugin in a frame the method
  runs. Returns `{id,path,unsaved}`; an unknown type fails naming the valid ones, and a taken or
  invalid name says why.
- `asset.delete`: `asset` (path or id) goes to the system trash with the import parts it owns, like
  Delete of the [content browser](../../mirai-editor/references/panels.md#content-browser): at
  once, without undo or `asset.save`. Returns `{moved,used_by}`; those that use it keep the
  reference. Fails saying why with an asset of a plugin, of the engine or of the editor, a scene
  open in a tab or outside Edit.
- `asset.move {asset, folder?, name?, copy?}` takes an asset by path or id, or a folder by path,
  and writes at once, without undo or `asset.save`; it returns the resulting path and id
  ([rename, move and duplicate](../../mirai-editor/references/panels.md#content-browser)). No
  `folder` keeps the one it is in and `/` is the root. Moving keeps the id and takes the parts
  along; what has unsaved changes fails asking for `asset.save` or `asset.discard`. With `copy` it
  copies with new ids and the copy is not an output of the import; without `name` it takes a free
  one.
- `asset.users`: `asset` (path or id). Returns `{used_by}`, the files that reference it or a part
  it owns, the same as the delete modal lists. A reference is the id of the header: moving the
  asset does not break it and deleting it does.
- **Sound**:
  - `audio.status`: the editor's mixer, its counters, its buses (by the name of `Audio_Bus`, with
    volume, mute, low pass and ducking) and what sounds through `audio.play`. Without a window
    there is no mixer and `mixer` is `false`.
  - `audio.play`: makes a `.sound` or a `.sound_set` sound (path with or without extension, or id)
    to hear it, outside every world, on the master bus and in place of what was sounding, like
    Play sound of the content browser. A set picks one of its sounds each time; `seconds` is the
    length of the sound, or of the longest of the set. `audio.stop` cuts it.
  - `sound_set.inspect`: `{sound_set,path,values,sounds}`; `values` is the text of
    `asset.Sound_Set_Info` with the sounds by id and `sounds` their paths.
  - `sound_set.set` (with `path`, a new one over `SOUND_SET_DEFAULTS`, which fails if the file
    exists): `values.sounds` carries `.sound` paths or ids; one that is
    not a `.sound` of the registry or an inverted range is `-32602` and says which field to fix.
    They leave the file unsaved, in an undo step.
- **Game data** (`records.*`, `api_records.odin`): `.records` tables of the `@(record)` types
  ([game data](../../mirai-core/references/core.md#game-data)). A table is `records` (its path
  with or without extension, or its id) and a row, its name. Each change is an undo step and leaves
  the file unsaved; a change the table does not admit fails with the row, the field or the column
  and what value is expected.
  - `records.types`: each type as `library.Name`, with its description, its fields (type, options
    of an enum, `records` of the type a `core.Record` names, description) and its tables.
  - `records.create {path,type}` creates an empty table of that type, the only method that does;
    Create of the content browser has one entry per type.
  - `records.inspect {records,rows?}`: `{records,path,type,rows:[{id,name,values}]}`; `id` is
    a JSON number (ids have 53 bits).
  - `records.set {records,row,values?,name?}` and `records.add {records,name,values?,
    after?}`: each key of `values` is a field of the row or the path of a part of one
    (`input.hold`, `windows[2].to`), and its value is that part whole: an object or a list leaves
    what it does not give at the default of the type (zeros where it has none), while what no
    key names keeps its value (a new row starts at the default). To
    change one nested field, name its path. A `core.Record` is given as `{table,row}`, as the name
    of a row or as `table/row`; a `core.Text`, as `{key}`, the key of the `.strings` it shows
    (`texts.set` writes what a key says, `texts.missing` lists the keys without a text:
    [texts](../../mirai-assets/references/kinds.md#texts)).
  - `records.remove {records,rows}` and `records.move {records,row,after}`: the row it goes right
    after, `""` for first. A row is renamed with `name` of `records.set`.
  - `records.import {records,file}` reads a CSV (RFC 4180, UTF-8) whose header is `name` and paths
    of leaf fields (`damage`, `stats.speed`, `position[1]`; `title.key` is the key of a
    `core.Text`): each row changes the one of the same name or is added, an empty cell changes
    nothing and there are no formulas. It is one step; returns
    `{updated,added,rejected:[{line,row,reason}]}`, and an invalid header writes nothing.
    `records.export {records,file}` writes that CSV.
- **Unsaved assets.** The methods that edit assets (`material.*`, `particle.*`, `sound_set.*`,
  `records.*`) and programs (`material.program.create` and `edit`) change them in memory, in an
  undo step attributed to the AI turn that calls:
  - `asset.unsaved`: `{assets:[{path,removed,asset,kind}],scene:[path]}`; `scene` are those the
    document's scene uses, also through dependencies and through the programs of its materials. A
    program has `kind:"program"`, without `asset`, and `path` is the path of its `.slang` under the
    project (`engine/...` for one of the engine).
  - `asset.save`: `assets` (paths under the assets folder, ids or the path of a program) or
    `all:true`; without either, the unsaved assets of the turn of the caller, or every one outside
    a turn. Writes their files and returns `{saved}`; a file that cannot be written is named with
    its cause; like Save, it waits for Edit (a running
    game reads those files). With `folder` (inside the project's `.mirai/tmp/`) it writes copies
    there, with the same paths, and leaves them unsaved: this is how an agent tests without
    touching the project.
  - `asset.discard`: the same, and gives them back what their files have; one that existed only in
    memory disappears. An AI turn cannot discard.

## Graphics and settings

- `graphics.status` (read-only): the graphics of the game while one plays, else of the edited
  world, with every option of the popup and its choices; the size the scene is drawn at is in
  `engine.status`.
- `settings.get` (read-only): the effective values per section and what the engine and project
  files set over the code, narrowed to `sections`
  ([settings](../../mirai-projects/references/projects.md#project-settings)); the shape is in
  `engine.describe`.
- `settings.set {layer, settings, graphics_preset}`: `layer` is `"project"` (default) or
  `"engine"`; `settings` are sections with the fields that change
  (`{"Particle_Settings":{"capacity":100000}}`), and `graphics_preset` sets the quality fields of
  `Graphics_Settings` as that preset of the Graphics popup does, before `settings`. Answers as
  `settings.get` does, for the sections it changed; `preferences.set` too, with `sections` as the
  filter of its get.
  - `engine` admits only `machine` sections; another is `-32602` with those it admits.
  - The edited world and the games that play take the values instantly; the layer's file stores
    what differs.
  - A section the engine refuses is `-32602` with the fix: an entry of `Input_Settings` that names
    an action the code does not declare, or a binding its kind does not read, names the action.
  - In `engine`, a field that the project overrides does not change.
  - A section that is not a setting or a field the type does not have is `-32602` with those that
    exist (the file, on the other hand, may store fields the type no longer has, and they are
    skipped).
  - An unknown key, an out-of-range value or `engine` without an engine root is `-32602` and
    changes nothing.
- `preferences.get` (read-only): the
  [editor preferences](../../mirai-editor/references/panels.md#preferences) by area, with what the
  file stores over the code. Without a `file` the editor does not save (`--headless` without
  `--preferences`) and a change lasts until it closes.
- `preferences.set {preferences}`: the areas with the fields that change
  (`{"Viewport_Preferences":{"snap":true}}`); they apply instantly and are written. An area or
  field that does not exist or an out-of-range value is `-32602` with those that exist, and changes
  nothing.
- **Particle effects** (`.particle`): registered by the `vfx` plugin with its `Api_Provider`;
  without it they do not exist ([vfx in the editor](../../mirai-world/references/vfx-editor.md)).
  - `particle.inspect`: `{particle,path,values,parameters,hidden,problem}`. `values` is the text
    of `effect.Particle_Info` (enums by name, ids in hexadecimal); `parameters`, those of the Vfx
    program by name; `hidden`, the fields its instances do not show; `problem`, why its program
    would not run (empty if it runs or has none).
  - `particle.set` with `path`: `values` are the fields that change over `PARTICLE_DEFAULTS`. Fails
    if the file exists.
  - `particle.set`: changes the effect for all the entities that show it; `hidden` replaces the
    list.
  - In both, `parameters` is `{name: value}` as the program declares it: a number, a list of two to
    four, `true`/`false` or a texture by path or id; `null` removes one. An out-of-range value, of
    another type or a parameter the program does not have is `-32602` and writes nothing; a program
    the shaders do not have yet is named all the same.
  - `particle.programs`: the Vfx programs of the shaders, with `attributes` (bytes per particle),
    their parameters (`kind`, `components`, `default`, `min`, `max`), their resources (`name`,
    `kind` `Surface`, `Channel`, `Bones` or `Grid`) and their stages (`name`, `over`: `particles`
    or a grid, `iterations`, `neighbors`).
  - `particle.set` leaves the `.particle` in an undo step (`history.undo`), attributed to the AI
    turn that calls them.
  - `particle.grid.bake` (`entity` with `Particle_Grid`, `path`): holds the call until
    the cells come back from the GPU, writes the `.grid` in an undo step of its own and returns
    `{path,grid}`, or fails if they do not come back. A grid the world did not take (another with
    its name, invalid cells or layers) is
    `-32602` with the `vfx.grid` problem that rejected it.
- **Emitters** (`entity`; `world` `Edit`, the document, or `Play`, the caller's):
  - `particle.instance.inspect` (`world` `Edit` by default): `values` (what it shows), `overrides`
    (its own values by path), `parameters` (its own), `problem` and `status` (`state` `Idle`,
    `Playing`, `Paused`, `Finishing` or `Done`, `seconds`, `generation`, `births`).
  - `particle.instance.set` (Edit, one undo step): of `values` (as inspect gives them) what differs
    from the effect becomes its own and `parameters` is added to its own, up to 16 together
    (`Particle_Override`); its assets and its program are the effect's (`-32602`).
  - `particle.instance.revert` and `particle.instance.apply` (Edit): give their values back to the
    effect, or write them into it and revert them, the file and the entity in one undo step.
  - `particle.instance.control` (`world` `Play` by default): `action` `Start` or `Stop` (they set
    its `active`; Play only, `-32602` in Edit), `Restart`, `Pause`, `Resume` or `Burst` with
    `count`; the emitter takes it on its next fixed step (in Edit, the next frame of the preview).
    Returns `{id,queued}`.
- `material.inspect`: `{material,path,values}`. `values` is the text of `asset.Material_Info`: the
  base, the layers (`coat`, `fuzz`, `anisotropy`, `unlit`), the maps with their textures by id and
  the program ([model](../../mirai-rendering/references/materials.md#layers-openpbr)). For an
  imported material it adds `imported` (what the source gave on the last import, the same text) and
  `overrides`, the paths of the fields that differ from that
  (`["roughness","maps.normal.texture"]`): those that importing again keeps
  ([layers](../../mirai-assets/references/kinds.md#what-was-imported-and-what-was-changed)).
- `material.set` with `path`: `values` are the fields that change over `MATERIAL_DEFAULTS`, also
  those of a block (`{"coat":{"weight":1}}` leaves the other coat fields). Fails if the file
  exists.
- `material.set`: changes a material for all the entities that show it: its `values` and, by name,
  the `parameters` and `textures` of its Surface program (those of the program its values name after
  the call) and its `overlays`, which replace the ones it has; what it is not given stays. An
  out-of-range value, a field the type does not have or a name its program does not have is `-32602`
  and changes nothing. What a single entity changes is its `Material_Values`, which the inspector
  edits. `material.set` leaves the `.mat` in memory, unsaved, in an undo step attributed to the AI
  turn that calls them. In an imported material, a field that ends up different from what was
  imported goes to `overrides`.
- `material.instance.*`: what an entity with `Mesh_Renderer` shows of the material of a slot
  (`slot`, 0 if missing), its `Material_Values`, as the inspector edits it; the overlays are the
  first slot's. `set` takes `values` (as `inspect` gives them: those that differ from the material
  become the entity's), `parameters` of the program, `textures` by map (`maps.base_color`) or
  program texture, and `overlays` (`null` gives back those of the material); the material does not
  change. `revert` removes the slot's from it. `apply` writes it to the slot's material and removes
  it from the entity, in one undo step and in memory like every edit (`asset.save` writes the file);
  a slot the entity changes nothing of, or with the default material, which has no file, is
  `-32602`.
- `material.revert`: `material` and `paths` (comma-separated paths, as `overrides` gives them, or a
  whole part: `coat`, `maps.normal`; empty: the whole material). Those parts take what the source
  gave and stop being overrides, in an undo step and unsaved, and the result is that of
  `material.inspect`. A material that was not imported or a path that is not part of
  `Material_Info` is `-32602` and changes nothing.

## Input

[Actions](../../mirai-gameplay/references/control.md#actions) of the project layer, as edited by
Project Settings > Input
([panel](../../mirai-editor/references/panels.md#project-settings)).

- `input.get` (read-only): each action the code declares with what drives it, as an entry of
  `Input_Settings` writes it, `changed` with the actions the project's setting changes, and the
  seconds of a tap and of a hold. An entry it gives, changed, is what `settings.set` takes in
  `Input_Settings.actions`; an entry equal to the code's default stays in the file, and Project
  Settings > Input removes it.

## Material programs

The methods serve the programs of all domains (Surface, PostProcess, Vfx and UI); `kind` of the
result is the one the source declares. A program is named by `program` (name or path of the
`.slang`) or, a Surface one, by `material` (the `.mat` that uses it). It is looked up in the
project's `shaders/`, in those of its active plugins and in the engine's `shaders/materials`, also
among those created unsaved. The methods read the source the editor has: the unsaved one or the
file's.

- `material.program.check` compiles it without publishing where it runs (a Surface in a raster
  stage and in a ray one; the others in the engine stages that evaluate them), with the project's
  extensions, and reads the source with the rules of the
  [check](../../mirai-rendering/references/shaders.md#check-of-a-program). In a diagnostic, an
  empty `stage` is of the rules and `node` is the id of the graph of that line.
- `material.program.create`: a new program in the project's `shaders/<name in lowercase>.slang`,
  with `source` or the template of its `kind` (without `kind`, the one `source` declares, or
  `surface`). A name that a program of the project, its plugins or the engine already has, one that
  is not an identifier or `pbr`, and a source that does not declare `//! mirai <kind> <program>` are
  `-32602`. After that it goes on like `edit`: check, the `.slang` in memory as an undo step and
  publishing.
- `material.program.edit`: with `source` it replaces the whole file; the last one wins
  ([concurrency](api.md#concurrency-transactions-and-undo)).
  It does the check first: with errors it does not write and the `-32602` carries the result of the
  check in `data`. Then it changes the `.slang` in memory, as an undo step (part of the turn's
  revision), and publishes the project's programs with that source: first the stages of the
  previews, then those that run the frames and finally the idle ones
  ([publishing](../../mirai-rendering/references/shaders.md#publication-from-the-editor)).
  Another edit while publishing cancels the previous publication. It does not change the declared
  name or domain.
- `material.program.inspect`: the
  [graph](../../mirai-rendering/references/materials.md#derived-graph) is read-only.
- `material.preview.capture`: measures only the pixels the sphere covers. A program
  gives its values as it writes them, before the renderer limits them; a NaN is magenta in the
  image and counts in `nan_count`. If publishing fails or the renderer rejects the stages of the
  previews, the error says so. Two captures are compared with `mirai image diff`.

## Collaboration

[Collaboration](../../mirai-editor/references/collaboration.md). In `peers` of `collab.status`,
`playing` says that editor is in a Play or Simulate of its own and `serving`, that it serves a
networked game; `unsent` lists the asset files changed in the session that the others do not have
because they are too large to travel. `collab.join` fails with unsaved changes unless `discard`;
an invalid code is `-32602`.

## Project panels

Editor interfaces saved in `panels/<id>.mirai`
([project panels](../../mirai-editor/references/panels.md#project-panels)).

- `panel.save` replaces the panel with that id. It checks each target against the project
  (component or setting, field, entity, fields and values of `where`) and each value before
  writing; the error names the button or the row and, if a field is missing, those that exist. A
  component that no entity has yet is accepted.
- `panel.open` and `panel.close` do not write the file.
- `panel.apply`: the scene fields are an undo step attributed to the turn that calls and the
  settings go to the file of their layer. Rejects a Play.

## AI

The `ai.*` methods and `finish` are in
[AI tasks](../../mirai-editor/references/ai-tasks.md#api-methods).
