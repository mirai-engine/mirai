# Method catalog

Methods of `editor`, active plugins and `engine.describe` (`editor/api/rpc.odin`). **Live schemas
come from `mirai rpc describe <method|prefix>`** ([describe](api.md#mirai-rpc-describe)); this
catalog records only non-obvious behavior, rejections, frame waits, undo rules and examples.
Protocol and errors: [api.md](api.md).

## Server and execution

- `engine.describe`: no params returns the index (core summaries, plugin method names, active
  plugins). `methods` fetches full schemas in one call; `plugin`/`prefix` narrow summaries and
  return the schema when one matches. Unknown name, empty `prefix`, or methodless `plugin` ->
  `-32602`.
- `engine.diagnostics`: inspect after any failed capture, test or Play before retrying.
  - `since` (previous `console.serial`) returns only new output.
  - `asset_errors` flags `Duplicate_Id` (`Reassigned` vs `Unresolved` while editing) and version
    mismatches with the `mirai import` command to redo them.
  - `problems` are per world ([problems](../../mirai-core/references/core.md#problems)): compare
    `last` against a saved `serial` after advancing to verify a fix. Opening a document or starting
    Play clears its problems. Validation classification:
    [rhi](../../mirai-rendering/references/rhi.md#device).
- `engine.status`: frame CPU breakdown (`cpu`), per-pass `gpu_timings`, GPU plugin `counters` (2
  frames behind, e.g. `vfx.particles`), viewport `ev100`, top-16 loop `functions`, `geometry` pool
  and page stats, `assets` counts, and `pending` (`programs`, `pipelines`, `assets` currently
  drawing stand-ins; wait with `--wait-until 'pending={"programs":0,"pipelines":0,"assets":0}'`).
- `engine.step`: manual editor only; advances editor, game and render by fixed `dt`.
- `engine.shutdown`: stops Play and exits after replying; fails if a file dialog is open.
- `engine.gpu_lose`: simulates device loss on next submission so the editor restarts
  ([recovery](../../mirai-editor/references/editor.md#gpu-that-stops-working)).

## Editor and viewport

- `editor.inspect`: selection, tool, snap, document, camera (`fov` vertical deg), interactions,
  window, `layout.widgets` (`[x,y,w,h]` window points) and `commands` (menus/shortcuts with method,
  params and enabled/checked state). Call a command's underlying method directly with explicit
  params; test UI-only entries via `editor.input` + `capture {ui:true}`.
- Unavailable calls fail with `-32001` and reason; `engine.describe` reports always-unavailable
  methods. `editor.tool` sets gizmo mode or plugin tool; `editor.select` replaces selection (undo
  step; bad entity -> `-32602`); `editor.watch` toggles watch mode on `task`.
- Sections: `editor.section_edit` edits a `Scene_Reference` in place (Edit only; flush writes all
  edited sections); `editor.sections` returns map/cost; `editor.section_view` (`Active`, `Loaded`,
  `Unloaded`, `Auto`) and `editor.section_travel` wait until loaded; `editor.section_preview`
  previews a section's `Sky`/`Sun`/box (Edit only).
- Material doc: `editor.material` opens/focuses a `.mat`, picks up to 16 `parameters` and sets
  preview `channel`; `editor.material.variants` sets up to 6 temporary `[{label,values}]` variants
  without editing the `.mat`.
- `editor.input`: manual editor only; each event runs one real-input frame and returns
  `editor.inspect`. Held keys/buttons replace previous event; `mouse_position` and `mouse_delta`
  are mutually exclusive; Mac Cmd is `Left_Super`.
- `capture` (GPU required; no document/history change): waits until `pending` clears and textures
  stream in (fails past timeout listing pending items). Adds `textures_pending`, `instances_drawn`,
  `instances_culled`, `instances_occluded` when nothing drew or textures remain.
  - `ui:true`: full window with editor chrome (forbids `width`, `height`, `of`).
  - Without `ui`: `of` is `Auto` (`Game` if caller has Play, else `Scene`), `Game` (offscreen game
    camera + game UI), or `Scene` (viewport camera + inspection mode, no chrome/gizmos/game UI).
    `width`/`height` in `0..4096`; `region` `[x,y,w,h]` in pixels (`-32602` if out of bounds);
    `seconds` sets window clock (Edit/Scene only, not Game).
  - `debug`: overlay names drawn over offscreen single captures and filmstrips (not with `ui`).
    The editor draws `bounds` and `trajectory` (filmstrips only); plugins register the rest with
    a `Capture_Overlay_Provider` (`name` + `draw`): `skeleton`, `match` (query vs chosen
    trajectory and root lag of motion matching), `collision`, `contacts`, `joints`, `hitboxes`
    (open ability windows; red once they hit) and `navigation` (navmesh, links, agent paths). An
    unknown name fails `-32602` listing those the project has.
  - Filmstrip (`every`, `count`): steps caller's Play with `segments` (nothing held after) and
    packs ticked cells into one PNG (`follow` centers each cell on an entity).
  - `path`: absolute or project-relative (pre-opened before drawing; bad/folder path -> `-32602`);
    omitted writes `.mirai/captures/` and returns inline MCP image.

```json
{"path": ".mirai/tmp/walk.png", "every": 6, "count": 8, "follow": "Player",
 "debug": ["skeleton", "bounds", "collision", "trajectory", "match"],
 "segments": [{"for": 48, "keys": ["W"]}]}
```

- `render.inspect_entity`: per-entity visibility/culling/skinning diagnosis without guessing.

```json
// Params:  {"entity": "Player", "world": "Game"}  // world: "Auto"|"Scene"|"Game"
// Result:  {"entity": "0x...", "name": "Player", "has_mesh": true, "mesh": "...",
//           "visible": true, "culled_reason": "None", "lod": 0, "levels": 4,
//           "aabb_min": [...], "aabb_max": [...], "distance": 4.2,
//           "textures_pending": 0, "materials": [...], "skinned": true, "skin_updated": true}
```

- `view.viewport`: returns the cached turn viewport snapshot without recapturing.
- `editor.view_mode.list`/`set`: core modes, `collision` / `collision.<layer>`, and active plugin
  modes (case-insensitive except layer; prefab -> `-32602`; Play forces Lit).
- `camera.set` (`idempotent`): `position` != `target`, `fov` 1..170 deg (no roll), or `entity`
  (copies camera pose/FOV/`Exposure`; excludes `position`/`target`/`yaw`/`pitch`). `exposure`:
  `scene`, `camera`, or `manual` (`ev100` -10..24).

## Collision

Case-sensitive project names (`Collision_Category`, `Collision_Preset`: `default`, `trigger`,
`custom`). Discover via `physics.collision.inspect`; declare via `names.create`. Contract:
[collision model](../../mirai-physics/references/engine.md#collision-categories-and-presets).

- Masks are name lists (`["*"]` = all). Write `Collision_Settings` via `settings.set`.
- Edit entity collision via `scene.write` (`Collider.preset`, or `sensor`/`belongs`/`collides` when
  `preset:"custom"`; `Query_Filter` via `filter.block`). Presets ignore custom fields; unknown name
  fails listing valid names. `prefix` targets nested collision fields; hidden/transient/read-only
  fields are rejected.

## Animation

Plugin methods live in [animation-api.md](../../mirai-animation/references/animation-api.md). Prefer
intent (`animation.character.setup`, `animation.request`, `animation.clip.edit`), check metrics with
`animation.analyze`, preview clips with `animation.capture`, and verify real Play with `capture`
filmstrips (`debug`) + `animation.inspect` (`Match`/`Pose`) + `animation.history`.

- `animation.inspect` part `Rig` adds `lod` (`period`, `wait`, `skip`, `plain`, `skipped`,
  `waited`; omitted when everything ran) to tell why a far rig stopped posing. Part `Match` and
  each `animation.history` row add `velocity`, `lag`, `travel`, `phase`, `fade_remaining` and
  `root_delta`. `trajectory:true` (default false: token budget) adds the `trajectory` the last
  search asked for and the `candidate_trajectory` of the row it chose.

## Cinematics

`cinematics.*` reads/plays timelines; create timelines (`preset:"cinematic"`) and actors
(`Animation_Target`) with `scene.write`, and edit tracks/markers with `animation.*`. In Edit,
`cinematics.control` moves the Tracks playhead without dirtying the document; in Play it queues a
runtime command ([cinematics](../../mirai-gameplay/references/cinematics.md#editor-and-api)).

## Ragdoll

`ragdoll.setup` (`ragdoll` plugin) builds bodies, colliders, joints and `Ragdoll` from `.skeleton`
body detection in one undo step, replacing any existing ragdoll
([ragdoll](../../mirai-plugins/references/ragdoll.md#setup-by-api)).

## Interfaces

`ui.*` (`ui_inspector` plugin) edits `.ui` files as undo steps, rejecting trees that fail to load.
Create via `ui.write` on a new path or `asset.create {kind:"ui"}`; render alone via `ui.capture`
([ui-inspector](../../mirai-plugins/references/ui-inspector.md#api)).

## Painting and shapes

Document viewport tools (Edit scene in front, one undo step, atomic on error):
- `paint.stroke` / `paint.clear`: world-space stroke paints vertices within `radius` across LODs
  into a new `.paint` referenced by `Painted`; hitting zero vertices -> `-32602`
  ([paint](../../mirai-plugins/references/plugins.md#paint)).
- `shapes.stamp` / `shapes.corner`: Stamp/Corners modes (`-32602` if missing outline or crossing
  edges); edit `Shape_Brush` children via `scene.*`
  ([shapes](../../mirai-world/references/shapes.md#shapes-tool)).

## Profiling

Records frame CPU zones, `std/jobs` tasks, GPU slot waits, GPU passes and measurement conditions
(last `PROFILE_CAPTURES` kept in `editor/profile.odin`).

- `profile.capture`: `advance:true` runs frames inside the call, acquires `measure.lock` up to
  `wait` ([turns](../../mirai-projects/references/build.md#turns-between-processes)), waits for
  `pending` to clear, warms GPU clocks, and records. `advance:false` records live/stepped frames
  (fails if already recording). Refuses validation, VSync or frame limits unless
  `allow_limited:true` (marks `comparable:false`); headless skips display pacing. `memory:true`
  samples world/process/GPU memory (leave off for timing).
- `profile.save` writes baselines to `.mirai/profiles/baselines` (versioned); `profile.compare`
  takes `base` or `baseline` (not both) and sets `comparable:false` on condition mismatch.
- `profile.load`: reports last document, Play or section load (`ready_ms`, `resident_ms`, `waits`,
  `phases`, `assets`, `slowest`, `pipelines.compiled` / `late_frames`).
- `profile.cost`: counts one viewport frame by mesh and material (instances, clusters, triangles,
  opaque/translucent pixels, shadow redraws); fails if viewport is occluded.
- `profile.gpu_memory`: groups all device buffers/textures/BLAS by name (`held_bytes`,
  `driver_bytes`, `outside_bytes`) without advancing a frame.
- Reading captures: limiter is `paced`, `gpu`, or `cpu`; `self_ms` excludes child zones; Metal
  reports whole-frame GPU only (`gpu_measured:false` frames are excluded from summaries).
- CLI benchmarks:
  - `mirai bench compare [project] --base main [--scene S] [--camera x,y,z,tx,ty,tz]`: builds head
    and base alike, acquires `measure.lock`, alternates `--pairs` captures and prints a Markdown
    table (JSON in `--out`).
  - `mirai bench flight [project] <flight> [--limit MS]`: runs `tests/flights/<flight>.mirai`
    segments through `editor.input` + `profile.capture`, printing hitch/settle tables (exit 1 past
    `--limit`, `rhi.WATCHDOG_EXIT_CODE` on GPU hang).
  - `mirai bench pipelines [project]`: cold/warm player runs checking pipeline cache hits.

## History

`history.undo` and `history.redo` act only on the caller's steps
([undo by author](../../mirai-editor/references/document.md#undo-by-author)). Fails with
`Nothing to undo`/`Nothing to redo` or when a linked-prefab step is blocked by later steps from
other authors. In a manual editor, runs one frame before replying so derived plugin state updates.

## Scene

Entity selectors and transactions: [api.md](api.md#method-conventions).

- `scene.audit`: static preflight check on the document or game world.

```json
// Params:  {"world": "Auto", "blend_ratio_warn": 0.25}  // world: "Auto"|"Document"|"Game"
// Result:  {"passed": false, "summary": {"entities": 42, "mesh_entities": 30, ...},
//           "flags": [{"severity": "Warn", "area": "Material", "code": "...",
//                      "entity": "Wall", "message": "...", "fix": "..."}]}
```

- `scene.inspect` (`read_only`): filters `entity`, `name` (`*` wildcard, case-sensitive),
  `component` (unknown -> `-32602`), `world:"Game"` (with `player` and `tick`; returns
  `playing:false` if no Play), `storages`/`storage`, `components` (`true` or list),
  `include_runtime:true`, pagination (`offset`, `limit` <= 4096). `root` returns a nested tree
  matching `scene.write` (omits default fields, un-IDed entities and sections).
  - Base fields (`Transform`, `Name`, `Id`, `Parent`, `Hidden`, `Disabled`) sit at top level
    (`enabled`, `active`, `off`, `prefab`), not inside `components` (writing them in `components`
    -> `-32602`). Runtime entities use hex handles.
- `scene.write`: unified document/game writer (`cook/author/scene_document.odin`,
  `editor/api_scene_write.odin`). Partial patch by default (matches by `id` or sibling `name`,
  `null` removes a component, `"delete":true` deletes entity or disables prefab member);
  `replace:true` declares the complete subtree under `root`.
  - Supports `preset` (recipe name; enabling a `Sun` disables the previous one), `prefab` (linked
    instance), and `copy` (deep clone with new ids). Prefab non-root members cannot reparent out of
    their instance. Returns `created: [{id, name}]`.
  - A rotation is `rotation_deg` (what the document of a scene shows) or `rotation`, the
    quaternion `[x, y, z, w]` kept to the last bit (`content.transform` writes it); never both.

```json
{"root": "Arena", "entities": [
  {"name": "Lamp", "preset": "point_light", "position": [0, 3, 0],
   "components": {"Point_Light": {"intensity": 40}}},
  {"name": "OldCrate", "delete": true}
]}
```

- `batch`: 1..256 calls in order (`editor/api/batch.odin`). `"$N"` / `"$N.path"` injects prior
  results (`"$$"` escapes literal `$`). Stops at first error (`calls[N] <method>:`, prior results
  in `data`). `transaction:true` groups scene edits into one atomic undo step (file writes remain).

```json
{"transaction": true, "calls": [
  {"method": "scene.write", "params": {"entities": [{"name": "Box", "preset": "cube"}]}},
  {"method": "scene.ground", "params": {"entities": ["$0.created[0].id"]}}
]}
```

- `scene.open`: opens a scene/prefab with empty history (omitted `path` reloads); fails as guest.

## Spatial queries

`scene.raycast`, `scene.bounds` and `scene.ground` query document `Mesh_Renderer` geometry (no
physics or foliage batches), including same-frame edits.

- `scene.raycast` and `scene.ground` surfaces ignore hidden/disabled entities; boxes include ghosts.
- `scene.ground` drops each entity vertically onto the highest surface below (rising at most entity
  height or `GROUND_RISE`), optionally `align`ing to surface normal, in one undo step. Fails with
  index if nothing is below or an entity descends from another in the list.

## Editor documents

- `editor.document`: `Open`, `Activate`, `Close`, `Preview_Sun` by `path` (default: active tab or
  front asset doc). Switching scenes stops Play; `Open` on unsupported asset -> `-32602`;
  `Close` drops history; `Preview_Sun` requires a prefab. `scene.open` replaces the active tab.

## Play

Play and Simulate run in-process on world copies
([Play](../../mirai-editor/references/editor.md#play)). The caller's run is its AI turn's
(`X-Mirai-Ai-Task`) or the user's outside a turn; turns never stop/pause the user's Play.

- `play.start`: flushes dirty edits, compiles changed project Odin first (build errors in
  `data.diagnostics`) and clones the world. Re-calling returns the same run unless the document
  changed. `from` (`Camera`/`Point`) fails in a turn or `simulate`. `online` needs `multiplayer`.
- `play.status`: also when nothing plays, `cursor` is what the pointer of the window shows, which
  no capture has: `shape` (`Hidden` while hidden), `image` (the `.tex` it shows; zero: the
  system's) and `relative`.
- `play.stop` / `play.pause`: `pause` is user Play only (`here:true` resumes from `play.seek` tick,
  discarding later history).
- `play.step`: pauses user Play or steps turn's run through real device input (`keys`, `tap_keys`,
  `mouse_buttons`, `mouse_position`, `mouse_delta`, `text`, `gamepads`, `press`, `drive`,
  `look_at`). `segments` replaces top-level `for`/input; `until` runs up to 8 `play.check`
  conditions; `trace` samples up to 4 entities/storages/`view` every `every` ticks. Duration `for`
  accepts ticks (`60`) or seconds (`"1.5s"`).

```json
{"segments": [{"for": 3, "keys": ["Space"]}, {"for": 30, "keys": ["W"]}],
 "until": [{"entity": "Player", "field": "world_position.1", "compare": "Above", "value": 1.2}],
 "trace": {"entities": ["Player"], "fields": ["world_position"], "every": 5}}
```

- `play.audit`: live health check (same result shape as `scene.audit`; adds live UI cursor-capture
  and keyboard-focus checks, NaN/stuck checks, GPU/CPU frame budget checks and the visual checks of
  the [audit gate](../../../../docs/game/testing/explore-qa.md#audit-gate)). CLI gate:
  `mirai play audit [project] [--ticks N] [--explore] [--copy]`.

```json
{"ticks": 60, "frame_ms_budget": 16.7, "blend_ratio_warn": 0.35}
```

- `play.check` (`read_only`): evaluates
  [conditions](../../../../docs/game/testing/scenario-assertions.md#scenario-assertion-reference);
  unknown name/field -> `-32602`; unmet condition -> `passed:false` with `failure`.
- `play.view` (`read_only`): active camera pose/lens/blend, `Camera_Follow`, and projected `points`
  (entity middle, not feet). `authority.kind` says who chose the camera (`Default` body camera,
  `Override`, `Activation`) with its `owner`, `order` and the playing `Camera_Modifier`s; `arm` is
  the Orbit spring arm (`desired`, `current`, `blocked` while short of desired, pulled in or
  going back out, `body_hidden`). `trace.view` and `view` conditions read the same fields.
- `play.events` (`read_only`): items of the `core.Events` fields of one storage (`Physics_Events`,
  `Ability_Events`, `Nav_Events`, `Perception_Events`, game ones) by reflection, filtered by
  `entity` (any `Entity` field). No `from`/`to`: what the log holds now (the last frame); with
  them, each frame of the history replayed, `limit` bounded (`dropped`, `next`). An unknown or
  event-less storage lists those that report events.
- Live mutations: `scene.write` with `world:"Game"` (partial patch, hex handles, teleports via
  `core.place`, spawns prefabs, atomic rollback on error; no `replace`/`kind`) and `play.push`
  (queues requests into `core.Queue` storages for the next tick).
- `play.input`: holds named seat actions for `for` ticks (rebind-safe; bad value -> `-32602`;
  networked server refuses client seat).
- `play.record` (GPU): fixed-fps 16-bit PNG or linear EXR + 32-bit float `audio.wav` +
  `manifest.json` + contact `sheet.png` (`sheet:0` disables). Ends paused.
- `play.history` & `play.seek`: inspects/rewinds non-networked run (or user's last stopped Play).
  `trace` and `verify` (detects first nondeterministic tick/field) replay without mutating current
  Play state.
- `playtest` plugin: `play.observe` (compact tick/player/UI/targets snapshot; optional `step` acts
  and observes in 1 call), `play.qa.start`/`report`, `play.explore`
  ([explore-qa](../../../../docs/game/testing/explore-qa.md)).
- `play.player`, `play.ui` (window-point `rect`s; omits `World_Widget`), `play.audio` (shared
  editor mixer), `play.scenario.run` ([scenarios](../../../../docs/game/testing/scenario.md)).
- `play.audio`: per voice `state` (`Playing`, `Virtual_Budget`, `Virtual_Silent`, `Fading`,
  `Unloaded`), `effective_gain` (the gain voices are ranked by), `distance`, `transmission`;
  `listeners` (at most 4); `one_shots`, the newest of the `audio.play` ring of fixed ticks
  (`Sounds_Played`, a host storage no world copy holds) with `outcome` (`Played`,
  `Culled_Distance`, `Rejected_Mixer`, `Missing_Asset`); `deduped`, asks of a rollback tick that
  found what it played.
- `play.audit` flags `ui.node_collapsed`: a shown content node (text with text, image, button,
  field...) laid out with no width or height; containers, spacers and prompts are exempt.
- `multiplayer` plugin: `play.join` (outside turns) and `play.network.status`, also inside a
  turn. Besides the editor's network game (`phase`, `invite`), `run` reads the run of the call
  (the turn's, or the user's Play), or `player` N, an online client of the turn's game: `role`
  (`Local` without a network), `links` (`rtt_ms`, `jitter_ms`, `loss`), `rollbacks`,
  `resimulated` ticks, `recent_resimulations` and the newest 32 `recent_corrections` (`tick`,
  `entity`, `field`: `Position`/`Rotation`/`Scale`/`Linear`/`Angular` or the component,
  `magnitude`, `placed`). A client diagnoses prediction; a server shows links only:
  `mirai rpc --project . play.network.status '{"player":1}' --select run`.

## Simulation

Runs the scene with editor camera and no player input
([contract](../../mirai-editor/references/editor.md#simulate)):
- `play.start {simulate:true}` fails if Play/Simulate is active, inside a turn, or with
  `players`/`online`. `play.step` rejects player input.
- `simulation.move` pushes dynamic bodies (`release` zeroes velocity; rejects characters and
  compound children); `simulation.apply` copies transforms of distinct existing entities back to
  document.
- `physics.settle` (Edit only): drops specified `Collider` entities in one undo step (`-32602` on
  un-droppable entity; `rested:false` + `reason` on tick limit).
- `physics.inspect {entity}` (Play/Simulate, read-only): only what `scene.inspect` cannot read:
  `awake`, `mass`, `inv_mass`; `contacts` per manifold (`other`, `sensor`, `normal` toward
  `other`, `points` with `separation` below 0 when overlapping and `impulse`); `joints` (`a`,
  `b`, world anchors, `separation`, `force`/`torque` of the last step vs
  `break_force`/`break_torque`, `broken`). `-32602` without a body or a running simulation.
- `abilities.inspect`: each candidate's `blocked` names exactly what fails (the status, the mode,
  `condition N`/`cost N` with the attribute's value against what it needs, the cooldown left);
  each open window's `hitbox` gives its world `center`, `rotation`, `size` and the `targets` it
  already hit.
- `nav.agent`: the `note` of a `Failed` agent or one with a partial path says why it stops short
  (no path, or a goal cut off from where it stands), then the `navigation.*` problems reported on
  it (`code: text`), such as `navigation.off_mesh` or `navigation.blocked`.

## Saves

Project saves folder ([save](../../mirai-gameplay/references/libraries.md#save)):
- `save.list`: reads headers (Edit/Play), reporting corrupt/version-mismatched slots with `error`.
- `save.delete`: queues on active Play or deletes file directly (no undo).
- `save.write` / `save.load`: require caller's Play (pushes `Save_Requests`; live Play captures
  thumbnail, paused/turn Play advances 1 tick without thumbnail). `save.load` replaces the world
  and invalidates entity handles.

## Build

- `build.start`: compiles `editor` library in background (even during Play) and hot-reloads in
  place keeping scene, Play, history and turns (restarts only when data migration cannot stay in
  place; `restarting:true`). `target:"shaders"` publishes project shaders; `target:"game"` builds
  shipped binary to `out` (default `.mirai/game`). One build job runs at a time.
- `build.check`: type-checks project packages without compiling/reloading.
- `build.test`: runs `@(test)`s of `package_folder` (default `game`, optional `tests` filter).
- `build.status`: current build phase, diagnostics and `game` path.
- `player.start` / `stop` / `status`: builds `play` library (or runs `shipped`) in standalone
  `mirai-player` (one at a time; blocks concurrent `build.*`).

## Project

- `project.get`: `project.mirai` fields and plugin states (`active`, `named`, `needed_by`).
- `project.set`: atomic validation before write (bad field/path, unknown/automatic plugin, or
  disabling a required dependency -> `-32602`). Returns `{building, active_plugins}`; changing
  `plugins` or `build` triggers an editor rebuild/restart.

## Prefabs

Prefabs are single-root `Prefab`-kind `.scene` assets (`asset` by path or id). Invalid id,
non-prefab scene, missing override, or non-instance entity -> `-32602`; other failures -> `-32000`
([errors](../../mirai-editor/references/prefabs.md#errors)).

- Instance operations target `root`. `prefab.list` lists top-level document instances with `stale`
  status (`prefab.refresh` updates stale ones).
- `prefab.inspect`: on `entity` derives overrides (`field`, `added`, `removed`, `turned`, `child`)
  and nested `links`; on `asset` returns `base` and variant `chain`.
- `prefab.variant.create` writes a variant without placing it; `prefab.apply {target:"Base"}`
  propagates through variant to base (`-32602` if not a variant).

## Components and assets

- `component.list`: no filter returns `{name, description}` index; `name`/`names` (up to 16) returns
  `library`, `default`, `fields` (`Color`/`Quaternion`/`Text`/`Array`, `unit:"rad"`, `read_only`,
  `opaque:true`). Derived/hidden/transient need `include_runtime:true`.
- `asset.list`: rescans registry; filters by `kind` (plugin types use extension, e.g. `particle`);
  returns `used_by`, `owner`, `prefab`, `broken`, `duplicates`, `missing`.
- `asset.import` / `asset.import_status`: ingests source into session store and pins in `folder`
  (blocks other asset writes while running). Reimport preserves ids; modified project documents
  fail unless `discard_changes:true`. `image` overrides channel use (`color`, `data`, `normal`,
  `normal_green_down`).
- `packages.list` / `packages.add` / `packages.peers` / `packages.peer_add`: browse and pin store
  or peer library packages into a folder.
- `asset.detach` (undo): clears `owner` on an import part. `asset.create` (`folder`/`scene` direct
  to disk; others undo steps). `asset.delete` (no undo, sends to trash with owned parts; package
  root unpins package; rejects open scenes and engine/plugin assets). `asset.move` (`copy:true`
  clones with fresh ids; no undo). `asset.users` lists dependent files.
- Sound: `audio.status` (`mixer:false` headless; meters, solos and filters per bus),
  `audio.play`/`stop` (`loop`, set `parameters`), `audio.snapshot` (blend to a snapshot outside
  Play), `sound_set.inspect`/`set`
  (undo; bad `.sound` or inverted range -> `-32602`).
- Game data (`records.*`, `api_records.odin`, undo steps): `records.types`, `records.create` (type
  declaration or `rows_of`), `records.column.add`/`set`/`remove`, `records.inspect` (53-bit numeric
  `id`), `records.set`/`add`/`remove`/`move` (dotted paths patch leaf fields; `core.Record` accepts
  `{table,row}`, `row`, or `table/row`; `core.Text` takes `{key}` with `texts.set`/`texts.missing`),
  and RFC 4180 CSV `records.import`/`export`.
- Every asset edit flushes to disk at step end: experiment on `mirai session start --copy` or
  `asset.move {copy:true}` ([AGENTS.md](../../../../AGENTS.md#verification)).

## Graphics and settings

- `graphics.status` (`read_only`): active graphics options/choices.
- `settings.get` / `settings.set {layer, settings, graphics_preset}`: `layer` is `"project"`
  (default) or `"engine"` (`machine` sections only; project overrides win). Applies immediately and
  persists diffs; unknown section/field, bad `Input_Settings` action/binding, or out-of-range value
  -> `-32602` atomically.
- `preferences.get` / `preferences.set`: editor preferences by area (`--headless` without
  `--preferences` is in-memory only; invalid key/range -> `-32602`).
- `vfx` plugin (`particle.*`, undo steps): `particle.inspect`/`set` (new path fails if exists;
  `parameters` typed against Vfx program; bad type/range -> `-32602`), `particle.programs`,
  `particle.instance.inspect` (one call: waits the frames its GPU readback takes; `layer`; `why`
  names the first broken link or the drawing pass; `space`, positions in the world; `gpu`
  & `not_finite`), `set` (up to 16
  overrides), `revert`/`apply`, `control` (`Start`/`Stop` Play-only; `Restart`/`Pause`/`Resume`/
  `Burst`), `particle.pool.inspect`.
- Materials (`material.*`, undo steps): `material.inspect` (includes `imported` and `overrides` on
  imported mats), `material.set` (new `path` fails if exists; edits `values`, program
  `parameters`/`textures`, `overlays`), `material.instance.*` (per-entity `Material_Values` per
  `slot`; `apply` writes to `.mat` in one undo step), `material.revert` (restores imported fields;
  non-imported or bad path -> `-32602`).

## Input

`input.get` (`read_only`): declared project actions, effective `Input_Settings` entries, `changed`
list, and tap/hold durations. Write overrides via `settings.set` on `Input_Settings.actions`
([actions](../../mirai-gameplay/references/control.md#actions)).

## Material programs

Serves all domains (Surface, PostProcess, Vfx, UI, Sky) by `program` name/path or `material`:
- `material.program.check`: compiles target stages without publishing and validates
  [rules](../../mirai-rendering/references/shaders.md#check-of-a-program).
- `material.program.create`: writes `shaders/<lower>.slang`, validates `//! mirai <kind> <name>`
  (rejects collisions, non-identifiers, `pbr` -> `-32602`), then checks/writes/publishes.
- `material.program.edit`: checks first (errors -> `-32602` with diagnostics in `data`, no write),
  writes `.slang` as undo step, publishes previews -> active -> idle stages (supersedes prior
  publish; cannot change name/domain).
- `material.program.inspect` (`read_only` derived graph); `material.preview.capture` (sphere pixels
  only, NaN rendered magenta and counted in `nan_count`).

## Collaboration

[Collaboration](../../mirai-editor/references/collaboration.md): `collab.status` reports `peers`
(`playing`, `serving`), `fetching` incoming changed files, `join` sync progress, `project` transfer
bytes and bad peers, and `offers`/`updates`. Invalid code -> `-32602`. `collab.join` returns
immediately.

## Project panels

`panels/<id>.mirai` ([panels](../../mirai-editor/references/panels.md#project-panels)):
- `panel.save` validates every component/setting/field/`where` target before writing (missing
  entity with existing component is allowed).
- `panel.open`/`close` do not write files; `panel.apply` writes scene fields in one undo step and
  settings to their layer (rejects Play).

## AI

`ai.*` and `finish`: [AI tasks](../../mirai-editor/references/ai-tasks.md#api-methods).
