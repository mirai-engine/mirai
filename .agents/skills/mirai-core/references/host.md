# `host`: the application

`host` (layer 4) owns the application (`^host.App`) and runs generated loops via
`core.World_Info`. It imports `core`, `asset`, `audio`, `platform`, `project`, `render`, `rhi`,
`ui`, `std/*`, and never imports `engine/*` or `editor`. Steps receive only the parts they need
([parameters](generator.md#parameters)).

## The application

`app_create(App_Desc)` initializes in order only what is requested: platform (SDL3), `std/jobs`
(`threads = jobs.THREADS_AUTO`), GPU device + renderer, mixer (`audio`: `None`/`Device`/
`Memory`), assets, and project `Shared`. Modes: window, GPU-only offscreen, or no-GPU (tests,
servers).

- **Config:** `fixed_dt > 0` runs unpaced deterministic frames; `max_ticks_per_frame` (0 -> 8);
  `core.Simulation_Settings.tick_rate` is captured per created world; `root`, `engine_root`
  (empty in shipped builds), `options` (`project.user_folder` in player, empty in editor),
  `assets_root`, `shaders_root`, `gpu_validation`, `asset_mounts`.
- **Store & plugins:** `store_root` (empty = machine default) backs packages in `root` and
  active plugins mounted under `plugins/<name>`; list failures go to `assets_package_problems`;
  cooked indices open no store (`Assets.store`). Missing chunks yield `Not_Here` stand-ins
  without error.
- **Clocks & control:** `app.seconds` sums frame `dt` (render clock outside Play); `app_seconds`
  is real wall clock (network). `app_exit(app, code)` ends player at frame end (first caller
  wins, [open and close](../../mirai-networking/references/multiplayer.md#opening-and-closing));
  `script_hold` pauses `--input` scripts; `app_real_time(app)` switches headless fixed-step runs
  to real-time pacing.
- **Worlds:** multiple worlds share `Shared` with independent
  [`core.Time`](core.md#core-storages). `app_world_create` allocates an initialized world +
  `core.World_Id` + `by_world` attachments (`nil` on OOM); `app_world_free` runs `release`
  phase, detaches `by_world`, and frees. Helpers: `app_world_id`, `app_world_of`,
  `app_world_count`, `app_world_storage`, `app_world_ref`, `app_editor_create`/`free`.
- **Atomic replace:** `app_world_replace(app, dst, src, marks) -> bool` copies into
  `app.scratch` and swaps with `dst` without allocating (`copy=false` stays in `dst`; `false` on
  OOM leaves `dst` intact; `app_world_scratch_free` releases scratch). With
  `core.world_copy_changed` `marks`, `core.world_restore` restores only delta—flat unchanged-
  layout tables update changed rows in place; layout-changed/pointer tables and written storages
  copy and swap whole.
- **Input & capture:** `app_input_add`; `app_capture`/`app_capture_pixels`; async PNG via
  `app_png_write_start`/`poll`/`wait`; offscreen `app_capture_world`/`app_world_draw`
  ([rendering](../../mirai-rendering/references/views.md#frame-and-views)). User folder holds
  saves and pipeline cache
  ([project](../../mirai-projects/references/projects.md#the-project-package)).

```odin
app, err := host.app_create({
    info = &info, fixed_dt = 1.0 / 60.0, root = project_dir,
})
assert(err == .None)
defer host.app_destroy(app)
world := host.app_world_create(app)
defer host.app_world_free(app, world)
if host.app_frame_begin(app) {
    host.app_game_frame(app, world)
    host.app_frame_end(app)
}
```

### GPU that stops working

On [device loss](../../mirai-rendering/references/rhi.md#device-loss), frames keep ticking
without GPU calls. `app_gpu_failure` formats the cause (including recently reloaded shaders
within `GPU_FAILURE_SHADER_FRAMES`), logs once, and reports problem `gpu.failure` on the
player's world:

- Player prints and exits `PLAYER_GPU_LOST`. Editor restarts with documents and exits if it
  recurs immediately ([editor](../../mirai-editor/references/editor.md#gpu-that-stops-working)).
- Device, renderer and GPU resources are never rebuilt in-process.

## The frame

```text
app_frame_begin   platform events, resize, asset/shader watch, releases, content/font adopt
app_game_frame    game loop for one world: input, fixed ticks, frame, late, ui, render
app_editor_frame  editor loop for one world and its Editor
app_frame_end     mixer, drawing, pacing
```

`app_frame` runs begin/game/end for `app.world`. Steps run sequentially per phase in
[generator order](generator.md#order); heavy steps fan out with `std/jobs` (`jobs.OWNER`).

- **Game loop:** accumulates `dt * (1 + Frame_Time.dilation) * Clock` (0 if paused), capped at
  `max_ticks_per_frame` (overflow counted in `ticks_dropped`), requires `core.Time` and
  `core.Frame_Time`. `ticks_steady` smooths jitter within half a tick (`Frame_Time.lag` keeps
  `alpha` smooth); `step=true` runs one tick without dilation. Runs `Input` once, `Fixed` per
  tick (`core.time_advance`; transient input edges/deltas clear between ticks), then `Frame`,
  `Late`, `Ui`, `Render`. `app_tick_replay` replays `Fixed` (rollback) without touching
  `Frame_Time` and sets `Problems.resimulating`.
- **Input filtering:** `Frame_Input` fills even on 0-tick frames. `game_input_blocked` and
  `game_input_excluded` apply to both `Input` and `Frame_Input`; `app_input_add` delivers once
  to next frame and once to next tick.
- **Editor loop:** runs all phases once with `dt = 0`, `Time.playing = false`, `alpha = 1` (Play
  worlds keep game `Time`/`Frame_Time`/`Fixed`).
- **Frame extras & views:** `^host.Frame_Extras` (`extras_*`: layers, world panels, debug lines,
  visual instances, offscreen UI/particle textures, texture views, depth probes,
  [offscreen UI](../../mirai-rendering/references/ui.md#offscreen-ui)) lasts one frame with
  fixed capacity (`dropped`). `host` reads camera/time from `core.View`/`Time`/`Frame_Time`.
  Also: `app.inspection` ([modes](../../mirai-rendering/references/settings.md#inspection-modes)),
  `app_views_set`, `app_player_rect` (`app.player_tiles`), `app.scene` viewport sub-rect.
- **Profiling (`profile.odin`):** `profile_start(app, frames, memory)` captures main/worker
  zones, renderer stats, and per-pass GPU timestamps (completed `rhi.MAX_FRAMES_IN_FLIGHT`
  submissions later; zero-alloc after first reserve; overflow in `lost`). Live readers call
  `profile_request` each frame. Optional `memory` samples `core.world_memory` (container
  capacities, not string bytes or non-storage allocs), `platform.process_memory`, and device
  memory ([`profile.*`](../../mirai-agent-api/references/methods.md#profiling)).
- **Load profiling (`load_profile.odin`):** always-on last load per kind (`load_open`,
  `load_ready`, `load_report`, `Load_Tally`, `LOAD_NO_ZONE`). Resident after first drawn frame
  with no asset/pipeline/anim/library work busy (+1 game tick if game loop ran). Player logs
  `Startup` and loads to stderr.

## The player

`player_run(info, project_folder, engine_root, args) -> code` is the `main` of shipped games and
`host.launch` (`mirai-player`). Applies `engine_root` settings layer under project settings
([settings](../../mirai-projects/references/projects.md#project-settings)) and opens window from
`project.mirai` (bad icon warns on stderr and continues).

### Arguments

Defined in `PLAYER_USAGE_TEXT` (`host/player.odin`). Extra semantics:

- `--scene` accepts asset-relative path or absolute `.scene` path
  ([networked play](../../mirai-editor/references/editor.md#networked-play)).
- `--input` frames count after `app.script_hold` clears. `--surface` implies `--attached`.
- `--players` sets local split-screen count (server defaults to 0 without it).
- `--validation` prints last API error to stderr and exits `PLAYER_VALIDATION` (6).
- `--dedicated`: headless server—no window, renderer, mixer, `ui` or `render` phases
  ([rules](generator.md#dedicated-server)); forwarded to `multiplayer` plugin (usage error
  without it; incompatible with visual/local-player flags).

```sh
mirai-player --project demo --scene scenes/main.scene --frames 60 \
  --capture bin/frame.png --validation
```

### Plugin arguments

Unrecognized flags stay in `host.Launch`. Libraries claim them with `launch_flag`/`launch_value`;
any untaken flag after frame 1 prints usage and exits `PLAYER_USAGE` (2). Network flags live in
`multiplayer`
([open and close](../../mirai-networking/references/multiplayer.md#opening-and-closing)).

```odin
if idx, ok := host.launch_flag(&app.launch, "--port"); ok {
    if val, has_val := host.launch_value(&app.launch, idx); has_val {
        port_arg = val
    }
}
```

### Image in another process

`--surface` (`host/player_surface.odin`) renders into a shared texture ring for the parent
process (editor), reads input from stdin, mutes audio when unfocused, and exits on stdin EOF.

### Exit and window

- Exit codes: `PLAYER_*` (`host/player.odin`); code 5 is reserved for library `app_exit`
  (`multiplayer.PLAYER_NET`).
- Windowed runs pace with vsync (`App.game_window` overridden by `Display_Settings`,
  [render](../../mirai-gameplay/references/libraries.md#render)); headless runs fixed steps
  until `app_real_time`.

## Project libraries

`host/library.odin` loads project dynamic libraries exporting `mirai_project_info`:

- `project_library_load(path, generation)` copies to `<name>-live-<pid>-<generation>` so
  rebuilds never lock the output (gen 0 cleans dead PID copies). `project_library_unload` is
  only safe once no `World_Info` pointers remain in use (editor keeps old libs until exit,
  [reload](../../mirai-editor/references/editor.md#build-and-reload)).
- `World`/`Shared`/`Editor` reserve `WORLD_RESERVE` virtual space; `app_worlds_migrate(app, m,
  editor)` migrates in place without moving addresses (fails atomically if reserve exceeded,
  [migration](core.md#world-reflection)).
- `host.launch`/`editor.launch` load `.mirai/editor` (exit 2 on fail) with absolute `--project`;
  player instantiates only game `World` (editor packages contribute nothing to game).

## Loaded assets

`Assets` (`^host.Assets`, `host/assets.odin`) loads by `base.Asset_Id` (0 = none) between
frames; tables reserve `Assets_Desc.capacity` (default 1M) virtual space so steady frames never
allocate.

- **Lookups:** `assets_mesh`/`assets_shape` (`ASSETS_MESH_NONE` without renderer),
  `assets_texture`, `assets_material`/`assets_material_row`, `assets_scene`, `assets_file` (any
  Fourcc, checks memory overlay then disk/store parts,
  [registry](../../mirai-assets/references/formats.md#registry),
  [container](../../mirai-assets/references/formats.md#container)).
- **Runtime textures & geometry:** `assets_texture_generate`/`release` (not unloaded/reloaded;
  release bumps `revision`), `assets_geometry` (level 0 cluster-decoded, no UV1),
  `assets_collision`, `assets_mesh_collides`, `App.collision_cache`
  ([pieces](../../mirai-assets/references/kinds.md#mesh)).
- **Job prep & budget (`assets_loading.odin`):** `assets_source`/`assets_source_open` +
  `assets_prepare` (incl. `render.mesh_ahead_make`, `assets_mesh_rigged`,
  `assets_limits(tail=true)`) + `assets_take` (no-op if loaded/changed). Active loads share
  `LOAD_FRAME_SECONDS` and `LOAD_FRAME_BYTES` (`assets_load_share`/`alone`/`whole` with
  `LOAD_WHOLE_FRAME_SECONDS`, `load_under_way`). Oversized textures (`over_frames=true`,
  `TEXTURE_TAIL`) and meshes upload over frames
  ([residency](../../mirai-rendering/references/materials.md#residency-by-sampling),
  [several frames](../../mirai-rendering/references/scene.md#geometry-over-several-frames),
  `app_assets_uploading`); far meshes publish whole via `assets_mesh_publish` +
  `assets_render_geometry_rays`.
- **Arrival streaming (`assets_streaming.odin`):** with jobs + renderer (`Assets.arrive`),
  materials/meshes stream in background (`ASSET_ARRIVALS`, `assets_arrivals_settle`,
  `assets_mesh_shown`, `app_assets_arriving`) without blocking a frame; direct `assets_texture`/
  `assets_mesh` loads whole.
- **Job release (`assets_release.odin`):** `app_assets_take`/`release`/`release_file`/
  `app_release` free prepared data in background (`app_assets_releases_step` in
  `app_frame_begin`, waiting for in-flight GPU uploads).
- **Mutation & mounts:** `app_asset_changed`, `assets_material_set`, `assets_reload` (keeps old
  on error), `assets_scan`/`assets_refresh`, `assets_mount`/`assets_unmount` (guest mounts,
  unwatched, never shadow shipped ids).
- **Derived material rows:** `assets_material_derive`/`values`/`overlays`/`postprocess` share
  equal rows; `assets_appearance_begin`/`end` GC unused rows; `assets_commit` uploads dirty rows
  (or whole table past `ASSETS_ROWS_DIRTY` / program / texture / unload change); base material
  edits with derived users advance `structure`.

### Generated meshes

`assets_mesh_generate(a, geom.Mesh, slots, uv1s, options)` registers an immutable runtime mesh
id (never reused; input buffers freeable on return):

- Builds single-level clusters + ray cuts via `asset.mesh_build`; jobs can prebuild
  `Mesh_Render_Geometry` via `assets_render_geometry_make`.
- CPU copies are opt-in (`collision`, `collision_mesh`, `disabled_edges`, `heightfield` matching
  [physics heightfield](../../mirai-physics/references/physics.md#geometry), `hull_points`/
  `hull_sizes` via `assets_collision_hulls`
  ([colliders](../../mirai-physics/references/engine.md#collider-fields))). Query with
  `assets_mesh_generated`, `assets_heightfield`, `assets_mesh_disabled_edges`.
- `assets_mesh_release` frees CPU/GPU ranges and advances `revision` and `structure` (call
  before frame sync; consumers track `assets_structure_changes`). RHI defers native destruction
  ([contract](../../mirai-rendering/references/rhi.md#rhi-contract)).

### Failures, unloading and watching

- **Failures:** recorded in `assets_errors(a)` with visible stand-ins (cube, magenta material,
  checkerboard); not retried until `assets_reload`. Without renderer, missing textures are
  ignored (dedicated servers cook without textures).
- **Counters:** `revision` (reload/unload), `structure` (bounded per-asset history for instance
  resync; id-less refreshes all), `appearance` (derived row rounds).
- **Scope GC:** up to 16 `Assets_Scope`s; `world_asset_ids` (structs/arrays/slices/dynarrays,
  not pointers/maps) and `world_owned_asset_ids` (`owned` tag) feed `app_assets_mark` +
  `assets_collect` (rebuilt per world only when columns/storages change; jobs mark worlds with
  `app_assets_building`).
- **Watching & textures:** `assets_root` watched recursively (plugins/guest mounts unwatched;
  `Watch_Stats.untracked` falls back to full scan; `assets_cache` persists registry).
  Unsupported BC decodes to RGBA8/RGBA16F; array/cube sampled as 2D returns `Unsupported`
  (`assets_texture_image`); single-layer mip streaming runs via `app_textures_stream`.

## Content

`Content` (`app_content(app)`, `host/content.odin`) lazily loads `.ui`, `.anim`, `.sound`,
`.sound_set`, `.font`, `.prompts` (`.strings` lives in `host/texts.odin`). Each entry carries a
`generation` that bumps on reload.

- `content_sound_pick` selects from `.sound`/`.sound_set`; streamed sounds stay open until exit.
  `.ui` re-resolves images/programs on `Assets.revision`. `prompts_find` maps key/mouse to
  `Keyboard`.
- **Fonts:** `content_font` registers into `App.ui_font` (`app_ui_fonts_apply` before UI
  frames); never unloaded by `content_collect`. Missing font fails its `.ui` load.
- **Animations (`host/content_animation.odin`):** compressed via `asset.animation_compress`
  ([storage](../../mirai-std/references/anim-storage.md)) and cached under
  `App_Desc.animation_cache` (`project.ANIMATION_CACHE`), keyed by `.anim`, skeletons,
  `asset.VERSION`, `asset.ANIMATION_VERSION`, `anim.COMPRESS_VERSION` and config.
- With >= 2 workers, compression runs in a job and adopts only at `app_frame_begin`
  (`app_content_adopt`; pending first load returns `nil` + `content_animation_pending` without a
  problem; `content_animation_wait` blocks when needed). `content_animations_start`/
  `content_animations_pending` preload data-referenced `.anim` dependencies before scene load/
  Play ([scene](../../mirai-gameplay/references/libraries.md#scene),
  [play](../../mirai-editor/references/editor.md#play)); code-only ids load lazily and are not
  cooked.
- Replay consistency: `Frame_Record.content` pins `Content.generations` for `app_game_frame`
  `replay` and `app_tick_replay`; `content_reloaded_after` flags post-load reloads.

## Shaders at run time

Engine shaders ship in the binary; project Slang generations (`<project>/.mirai/shaders`)
compile on a background thread and swap atomically between frames
([loading in host](../../mirai-rendering/references/shaders.md#loading-in-host)). Mismatched
engine shaders stay `Stale`; failed reloads keep the running generation.

## Bridge with `ui`

- `ui_frame_split` emits screen layers, world panels, and `offscreen` `render.Ui_Texture_Draw`
  (`app_ui_texture_capture` renders/reads one standalone).
- `ui_input_camera` builds UI rays (clamped to split-screen rect; `app_views_set` caches per-
  view cameras in `App.local_cameras`).
- `app_ui_context_create` borrows the shared `App.ui_font` atlas; `app_ui_font_sync` uploads
  newly rasterized glyphs after each UI frame.

## Changing `host`

- Persistent state lives in `App`; asset loads, world creation and shader reloads are
  transactional between frames.
- Never import `engine/*` or `editor`; expose capabilities via `App` fields or `host` procs.
- `player_run` (generated `main`) and `mirai_project_info`/`core.World_Info` are binary/layout
  contracts—update generator and engine declarations together.
