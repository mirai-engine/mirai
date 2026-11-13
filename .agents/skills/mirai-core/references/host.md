# `host`: the application

`host` (layer 4) is the application: the loop functions receive the part of it they reach
(`^host.Assets`, `^host.Frame_Extras`, the renderer, the mixer, the job system, its allocator:
[parameters](generator.md#parameters)) or, for the application itself, `^host.App`, and it runs the
loops that the generator wrote. It imports `core`, `asset`, `audio`, `platform`, `project`,
`render`, `rhi`, `ui` and `std/*`; the `engine/*` libraries import it, never the other way around.
It does not know which components exist: it works with `core.World_Info`.

## The application

`app_create(App_Desc)` builds, in this order and only what is requested, the platform (SDL3, with or
without a window), tasks (`std/jobs`), device and renderer, mixer, assets and the `Shared` of the
project: with a window to play and edit, GPU without a window for captures and graphics tests,
without GPU for simulation, tests and dedicated servers. `fixed_dt` makes each frame last that long,
without pacing (deterministic runs).

- `app.seconds` adds the `dt` of the frames: the time the render gives a world outside Play.
  `app_seconds` is the real clock, the network's.
- `app_exit(app, code)` ends the player at the end of the frame; the first library that asks for it
  decides ([open and close](../../mirai-networking/references/multiplayer.md#opening-and-closing)).
  `script_hold` holds the `--input` script while what it drives is not ready (a client that has not
  joined), and `app_real_time` switches to real-clock frames a windowless player that was doing
  fixed steps (a library that talks to other processes asks for it).

**Worlds.** Several run in one process, each with its own clock
([`core.Time`](core.md#core-storages)), sharing the `Shared`.

`App_Desc`:

- `info`: the generated `World_Info`.
- `threads`: `jobs.THREADS_AUTO` is one thread per remaining core.
- `fixed_dt`: >0 makes each frame last that long, without pacing (deterministic runs).
- `max_ticks_per_frame` (0: 8). The fixed step is the `tick_rate` of `core.Simulation_Settings`, a
  project setting in `Shared`: each world that is created takes the one the application has at that
  moment, so a change in Project Settings applies from the next Play.
- `audio`: `None`, `Device` or `Memory`.
- `root`: project folder (manifest and bindings); `engine_root`: engine root, or empty (project
  settings only); `options`: folder of the player options, which the player provides
  (`app_user_folder`) and the editor does not; `assets_root`, `shaders_root`. `root`, `engine_root`
  and `options` are copied into the application.
- `asset_mounts`: plugin assets mounted under `plugins/<name>`.
- `gpu_validation`.

`App` stores the platform, `jobs`, `info`, `shared` (the `Shared` of the application), `world` (the
`World` of the player), `renderer`, `device`, `drawable`, `density`, `camera` (that of the frame),
`mixer`, `assets`, `shaders`, `launch` (what the command line requested,
[`Launch`](#plugin-arguments), with the initial scene that the `scene` library takes), `stats`
(frame times), `seconds` (the sum of the `dt` of its frames, the fixed one with `fixed_dt`: the time
the render gives a world outside Play; `app_seconds` is the real clock, the network's), `quit` with
its `exit_code` and `script_hold`.

- `app_exit(app, code)` ends the player at the end of the frame with that exit code; the first
  library that asks for it decides. This is how the network ends a player that cannot continue
  ([open and close](../../mirai-networking/references/multiplayer.md#opening-and-closing)).
- `script_hold` holds the input script (`--input`) while what it drives is not ready: the network
  sets it when opening a client and clears it when it joins.
- `app_real_time(app)` makes frames from then on last what the clock says, at its own pace: a
  library that talks to other processes (a network session) asks for it in a windowless player that
  was doing fixed steps.

- `app_world_create(app)` creates an initialized `World` with its id (`core.World_Id`); `nil` if it
  could not be initialized, leaving nothing half done. `app.worlds` (`World_Slot`) stores each world
  at the index of its id; a free slot keeps the generation of the last one, so the id of a released
  world does not name another. `app_editor_create/free` do the same with the `Editor`, without an
  id. Several worlds run in one process, each with its own clock (its
  [`core.Time`](core.md#core-storages)), sharing the `Shared`.
- `app_world_free(app, data)` runs the `release` phase of the world (the `Shared` storages release
  what they kept for it) and frees it.
- `app_world_id(app, data)`, `app_world_of(app, id)` (`nil` if it was already released) and
  `app_world_count`.
- Creating a world also gives it its values of the `by_world` storages (`core.world_attach`); if
  there is no memory, it is not created. Releasing it removes them after its `release`.
- `app_world_storage(app, data, T)`: the storage `T` of a world as its functions receive it: in the
  `World`, or its value of a `by_world` of the `Shared` (the network session of a run, its
  [problems](core.md#problems)). `nil` without it or without a loaded game (`app.info` empty).
- `app_world_replace(app, dst, src, marks) -> bool`: `dst` becomes a copy of `src`, whole or
  nothing. It copies into a separate `World` of the application (made the first time) and swaps it
  with `dst` without allocating; what is not copied (`copy=false`) stays in `dst`. `false` without
  memory, with `dst` as it was. Opening a document and the network rollback use it. The swapped-out
  content stays in that world for the next replacement, which does not allocate if it fits;
  `app_world_scratch_free` releases it when the next one is far off (opening a scene).
  - With the `marks` of a `src` that `core.world_copy_changed` keeps as a copy of `dst` (a tick of
    the rollback history), only what `dst` changed since that copy comes back
    (`core.world_restore`): the rest stays where it is, and its readers see no change. A table of
    flat values that still holds the rows of the copy, on and off, takes back in place the rows
    whose value or whose being added differs, with new stamps, and its readers see those rows
    alone; a table whose rows were added, removed or turned since, or whose values hold a
    pointer, and the storages written, are copied and swapped, and their readers read them whole.
    That separate world is then left with parts of several, and is cleared before it is released.
- `app_world_ref(app, data)` gives the `core.World_Ref`.
- `app_user_folder(root)`: `<user data>/Mirai/<project name>`, created if missing; empty without a
  project. It stores the saves (`save`) and `pipelines.bin`, the pipeline cache that `app_create`
  passes to the device so as not to recompile them on every start.
- `app_input_add(app, input)` adds input for the next tick (scripts and agents).
- `app_capture(app, path)` writes the last frame as PNG; `app_capture_pixels` gives the pixels.
  `app_png_write_start` compresses and writes RGBA8 in a job of `app.jobs` (`Png_Write`);
  `app_png_write_poll`/`app_png_write_wait` collect it and release the pixels: the frame does not
  wait for the compression.
- `app_capture_world` draws offscreen a world that the window does not show and returns its pixels;
  `app_world_draw` draws it into a texture, frames that each advance one `dt`
  ([rendering](../../mirai-rendering/references/views.md#frame-and-views)).

### GPU that stops working

A GPU that stops working ([device
loss](../../mirai-rendering/references/rhi.md#device-loss)) does not end the
application by itself: frames keep going without drawing or waiting for the GPU and the worlds keep
ticking. `app_gpu_failure` gives the failure and its text, which names the call that saw it, where
the GPU stopped, and the project shaders if they were replaced recently
(`GPU_FAILURE_SHADER_FRAMES`). The first time it is reported in the log and as the
problem `gpu.failure` of the player's world.

- The player prints the text and exits with `PLAYER_GPU_LOST`.
- The editor restarts with its documents, and ends if the failure repeats right away
  ([editor](../../mirai-editor/references/editor.md#gpu-that-stops-working)).
- The device, the renderer and their resources are not rebuilt in the same process.

## The frame

```text
app_frame_begin   platform events, resize, asset and shader watching
app_game_frame    game loop for one world: input, fixed ticks, frame, late, ui, render
app_editor_frame  editor loop for one world and its Editor
app_frame_end     mixer, drawing, pacing
```

`app_frame` does the three for the player's world.

Each phase calls its functions one after another on the thread of the loop, in
[the order of the generator](generator.md#order). The workers of `app.jobs` sleep until a function
spreads its work with `std/jobs`, as their owner (`jobs.OWNER`).

**Game loop.**

- It adds the `dt` of the frame times `1 + Frame_Time.dilation` and times the `core.Clock` of the
  world (zero when paused) to `Frame_Time.accumulator` and simulates the ticks it completes, at
  most `max_ticks_per_frame`; the rest is discarded and counted in `ticks_dropped`. A world
  without `core.Time` or without `core.Frame_Time` does not run the game loop. After each tick it
  subtracts `tick_dt` and advances the clock with `core.time_advance`.
- The count of ticks per frame is kept steady (`ticks_steady`, after Godot's `MainTimerSync`):
  while the last frames ran a typical count and the clock is within half a tick of it, a tick runs
  that much early or late instead of frames alternating 0 and 2 ticks under timer jitter. Time is
  never lost: the accumulator keeps the truth and `Frame_Time.lag` shifts the shown time so
  `alpha` advances evenly between the last two ticks. Every world runs it, a server's too: what a
  tick computes never depends on when it runs, and a recorded frame replays its count of ticks.
- With `step=true`, `app_game_frame` runs one tick however long the frame lasts and without
  dilation: a world that advances only when asked (the steps of the editor and of agents).
- The input of the ticks (`input_from_platform` plus that of the script) goes to `core.Input`: the
  first is already seen in the `input` phase; `pressed`, `released`, `mouse_delta` and `wheel` are
  cleared between ticks.
- It runs `Input` once, `Fixed` per tick (with `Time.tick`, `seconds` and `dt` of the tick) and
  `Frame`, `Late`, `Ui` and `Render` once, with `Frame_Time.alpha` between the last two ticks.
  `Frame_Time.phase` is the phase that is running and `Frame_Time.dt` the `dt` of the frame.
- `app_tick_replay(app, world, content)` runs the `Fixed` phase of a world again from the phase
  that is running and advances its clock as a tick; on return, the phase is still the one from
  before. The network rollback uses it, which does not touch `Frame_Time`. While it runs it sets
  `Problems.resimulating` according to `Time.resimulating`: a problem that the tick repeats does not
  count again.
- Before `Input` it fills `core.Frame_Input` with the events of the frame, whether or not ticks run.
- `game_input_blocked` neutralizes the game input when the owner of the application blocks it, also
  without a tick; the explicit script input is combined afterwards, for test steps.
- `game_input_excluded` removes reserved keys from the held, pressed and released states after
  combining platform and script, also without a tick. Blocking and reserved keys apply to
  `Frame_Input` too.
- `app_input_add` delivers a script sample once to each domain: in the next frame and in the next
  tick, without repeating it in frames without a tick.

**Editor loop.** It runs all the phases once with `dt = 0`, `Time.playing = false` and
`Frame_Time.alpha = 1`, with the input of the frame. A world that also plays (Play) keeps its
`Time`, its `Frame_Time` and its input, and its `Fixed` phase is only that of the game.

**What a frame adds.** `host` does not know what an editor is: the owner of the application adds its
own through the `extras_*` of `Frame_Extras` (screen layers, panels in the world, debug lines,
visual instances, panels and particles in textures, views into a texture, pixels whose depth is
read: [offscreen UI](../../mirai-rendering/references/ui.md#offscreen-ui)); a function that adds to
the frame receives `^host.Frame_Extras`. They last one frame with fixed capacity; what does not fit
adds to `Frame_Extras.dropped`. Visual instances create no
entities or persistent data.

- When running the `render` phase of a world, `host` takes the camera and the frame time from its
  `core.View`, its `core.Time` and its `core.Frame_Time`; no library writes them.
- `app.inspection` is what the view shows in the next frame instead of its lit image
  ([modes](../../mirai-rendering/references/settings.md#inspection-modes)).
- `app_views_set` replaces the camera with several views, each in its rectangle of the drawable,
  which are composed before drawing the screen UI once. `app_player_rect` gives the part of a local
  player: `app.player_tiles` if someone split the screen (the editor, with players from other
  processes) or, if not, halves or quarters.
- `app.scene` is the part of the drawable in which the camera alone draws (zero: all of it): what is
  always covered, like the editor bars, is not drawn.

**Profiling (`profile.odin`).** `profile_start(app, frames)` records the following frames: zones of
the main thread, one per loop function, the tasks of each worker and what the renderer
measures. The first `profile_start` reserves the memory: recording does
not allocate, without recording a zone costs one branch and what does not fit is counted in `lost`.
Whoever reads the zones as they happen (a profiling plugin) calls `profile_request` in every frame
and reads them with its own cursor; without a recording or a request, the device writes no
per-pass timestamps. The editor exposes it with
[`profile.*`](../../mirai-agent-api/references/methods.md#profiling).

**Loads (`load_profile.odin`).** `app.load_profile` keeps the last load of each kind (scene, Play,
section) with its phases, its assets by kind and the slowest of them, always on: a phase costs two
clock reads, an asset an insertion among the slowest, and nothing allocates per entity or per
asset. Whoever starts a load opens its record (`load_open`) and says when it is the document or the
world (`load_ready`) or that it failed; the record is the current one until it is resident or
another opens, and receives what happens meanwhile wherever it happens: the assets that load at once
(`Assets.load_profile`), the phases of the loop functions (physics, navigation) and what the loop
functions took, from `app.step_ns`. It is resident at the end of the first frame after it was ready
that drew with nothing busy: no asset loaded in that frame, none uploading over frames, no pipeline
being made and no `.anim` compressing, and no library that reported busy with `load_report` (its
state stays until it reports again, so it reports every time it runs); when a game loop runs, after
one of its ticks too. A load in phases and a section count what their jobs do in a `Load_Tally`
they give when they end. Phases on the main thread or a job worker are also zones of the profiler
while it records; those inside a loop function pass `LOAD_NO_ZONE`, since its own zone holds them.
The player prints each load once it ends, on stderr, with what it took to start before its first
frame (`Startup`).

## The player

`player_run(info, project_folder, engine_root, args) -> code` is the whole `main` of a game: the
generated `main` of the shipped game and `host.launch` from `mirai-player` call it. It opens the
project, creates the application and the world, loads the initial scene and runs the loop until
exit. The engine root puts the general layer of
[settings](../../mirai-projects/references/projects.md#project-settings) under that of the
project (`host.launch` passes that of `project.engine_root_find`, the same one the editor looks
for; the shipped game, empty). The window comes from `window` in `project.mirai`, with its `version`
and `identifier` for the system and its `icon`; an icon that is not a readable PNG is warned about
on stderr and the game runs without it.

### Arguments

`PLAYER_USAGE_TEXT` (`host/player.odin`) describes them, and the player prints it on an argument it
does not understand. What it does not say:

- `--scene` also takes the absolute path of a `.scene` outside the assets: the copy that an
  [editor network game](../../mirai-editor/references/editor.md#networked-play) runs.
- The frames of `--input` count from when `app.script_hold` turns off.
- Without `--players`, the local players come from the scene, or none if the role of the world is
  `Server`; with it, a server also has local players.
- `--surface` implies `--attached` ([image in another process](#image-in-another-process)).
- `--validation` with errors prints the last one on stderr and exits with `PLAYER_VALIDATION`,
  unless it already failed with another code.
- `--dedicated` is a server nobody plays on: no window, renderer or mixer, frames at the pace of
  the tick and neither the `ui` nor the `render` phase (`app_frame` with its phases). The generator
  keeps the game from depending on those phases ([rules](generator.md#dedicated-server)). The
  argument is also left to the network plugin, which opens the server; without that plugin nobody
  takes it and it is a usage error. It does not go with what asks for an image or a local player.

### Plugin arguments

The player knows neither the network nor any other library: what it does not read stays in
`host.Launch`, and each library takes its own with `launch_flag` and `launch_value`, which mark them
as taken. An argument that none took after the first frame is a usage error: the player names it,
prints the help and exits with `PLAYER_USAGE`. The network ones (`--server`, `--connect`,
`--invite` and others) belong to the `multiplayer` plugin
([open and close](../../mirai-networking/references/multiplayer.md#opening-and-closing)).

### Image in another process

With `--surface`, the player draws each frame into the next one of a ring of shared textures that
the process that opened it (the editor) displays, and receives input over stdin; the protocol is in
`host/player_surface.odin`. It opens the audio muted and it only sounds with focus: only the focused
player is heard. The end of stdin terminates it.

### Exit and window

- The exit codes are the `PLAYER_*` of `host/player.odin`; 5 is left for a library that ends the
  player with `app_exit` for a reason of its own (`multiplayer.PLAYER_NET`).
- With a window, the frame is paced with vsync; without a window it does fixed steps until a library
  asks for `app_real_time`. Title, mode and size of the window come from `project.mirai`; with a
  window and without `--window` it is the game's (`App.game_window`) and the player's
  `Display_Settings` overrides it
  ([render](../../mirai-gameplay/references/libraries.md#render)).
- Assets come from `<project>/assets` and from the active plugins, mounted; shaders, from the
  project generation if it exists.

## Project libraries

`host/library.odin` loads the library of a project (`mirai_project_info`).

- `project_library_load(path, generation)` loads a copy (`<name>-live-<pid>-<generation>`) next to
  the original: a build can replace the file while it is loaded and a new version is loaded
  alongside. With `generation` 0 it first deletes the copies of processes that no longer run and
  keeps those of live processes (another editor or player of the same project).
- `project_library_unload` is only valid when nothing of its world is still in use: names and
  procedures of the `World_Info` point inside the library. The editor leaves them loaded until it
  ends ([editor](../../mirai-editor/references/editor.md#build-and-reload)).
- Each struct of a place that the application makes (`World`, `Shared`, `Editor_World`) reserves
  `WORLD_RESERVE` of address space and commits what it occupies. `app_worlds_migrate(app, m,
  editor)` takes them to the layout of another library without moving them in address and makes it
  their `World_Info` ([migration](core.md#world-reflection)); it fails without changing anything
  if one does not fit in its reserve.
- `host.launch` is the `main` of `mirai-player` and `editor.launch` that of `mirai-editor`; both
  load `.mirai/editor` and, if the library does not load, print the reason and exit with 2. From
  its `World_Info` the player makes the game world alone: an editor package declares nothing of
  the `World` or of the `Shared`, nor steps of the game loop (the generator rejects it), and the
  `Editor` place is not created outside the editor.
  The `--project` folder is made absolute: once it is said where its dependencies are, Windows does
  not look for a relative library in the current folder.

## Loaded assets

`Assets` (a function receives it as `^host.Assets`; `host/assets.odin`) loads by `base.Asset_Id`
meshes, textures, materials and scenes, and the primitives (`Shape`). An asset is loaded
the first time it is asked for, as a transaction between frames; asking again is a lookup. Id zero
is "none". The tables of each type reserve address space for `Assets_Desc.capacity` (by default, a
million) and take memory as loads fill them: the quantity a world asks for (a terrain of thousands
of pieces) is not a fixed cap, and a frame that does not load does not allocate.

- `assets_mesh(a, id)`, `assets_shape(a, shape)`: `^Assets_Mesh` with a renderer handle
  (`ASSETS_MESH_NONE` without a renderer), bounds, counts, slots and the material of each slot.
- `assets_texture(a, id)`: `^Assets_Texture`.
- `assets_material(a, id)`, `assets_material_row(a, id)`: `^Assets_Material` or its row in the
  renderer's material table.
- `assets_scene(a, id)`: the open `^asset.Asset` of a `.scene`.
- `assets_mesh_generate(a, geom.Mesh, slots, uv1s, options)`, `assets_mesh_release`: a mesh made at
  run time, with its own id and no file ([generated meshes](#generated-meshes)).
- `assets_mesh_generated`, `assets_heightfield`, `assets_mesh_disabled_edges`: whether a generated
  id is still alive, its height descriptor and its CPU edge masks, lent until retirement.
- `assets_texture_generate(a, RGBA8 pixels, width, height)`, `assets_texture_release`: a texture
  made at run time from an image the game read (the thumbnail of a save), with its own id and no
  file, which a UI image or a material shows as an asset. It is not unloaded, not reloaded and does
  not follow distance; releasing it advances `revision`.
- `assets_geometry`, `assets_collision`: positions and indices of what a `Mesh_Renderer` shows (to
  fracture), and the geometry of a `Hull` or `Mesh` collider (the colliders stored in the mesh, with
  boxes, spheres and capsules as their hulls, or their geometry). Of a `.mesh` it is its level 0
  decoded from the clusters (`asset.mesh_level_decode`): a vertex that two clusters share comes once
  per cluster.
- `assets_mesh_collides`: whether a mesh asset stores colliders of its source, what a placed mesh
  collides with. `App.collision_cache` is the folder where the convex pieces of a mesh file that
  stores none are kept
  ([`asset.mesh_collision_pieces`](../../mirai-assets/references/kinds.md#mesh)); physics asks for
  them in a job.
- `assets_file(a,id,kind,&Asset)`: transactional load of any type by Fourcc, validating identity and
  hash; the caller closes with `asset_close`. It serves plugin formats without adding them to the
  GPU caches. It reads with `registry_read`: what the registry has in memory before the disk
  ([in-memory files](../../mirai-assets/references/formats.md#registry)); likewise the `content_*`.
- **Loading in jobs.** `assets_source` gives, on the assets thread, where a job reads the file of an
  asset from (its path, or a copy of what the registry has in memory); `assets_source_open` opens it
  as `assets_file` on any thread. `assets_prepare` does in a job what loading a mesh, a texture or a
  material does before the renderer (read, verify, decompress, decode the levels that the device
  takes), with the same code as the direct load, and `assets_take` installs it between frames as if
  it had been requested; it does nothing if the asset was loaded in the meantime or its file changed
  (whoever asks for it loads it). For a mesh, the job also does what the renderer derives from it
  (`render.mesh_ahead_make`): the cuts that trace its rays, with their trees when
  `Assets_Limits.software_rays` says the renderer traces in software, the verification of its
  geometry and the stream of its pages; the frame that takes it does not walk its geometry, and the
  renderer builds the cuts if they are missing or the trace mode changed. The entry of a mesh says
  whether it has skin or morphs: without them, `assets_mesh_rigged` lets whoever looks for its rig
  not read the file again. `Assets_Prepared.cost` is the bytes it gives the renderer right away (of
  a mesh, what the pools take when adding it: the pages of its root, its tables and those trees,
  `render.mesh_add_bytes`; the other pages arrive with the frames that show them) and `level`, the
  first level of a texture it reads. `assets_limits(a,tail=true)` brings only the small levels of
  the textures: those of what loads far away, like a section.
- **Load budget** (`assets_loading.odin`): the loads in progress share each frame
  `LOAD_FRAME_SECONDS` of the main thread and `LOAD_FRAME_BYTES` for the renderer
  (`assets_load_share`); each takes its part of what the previous ones left, and its first asset of
  the frame passes if its bytes fit, even if it goes over time. A load whose next asset does not fit
  without having taken anything asks for the next frame for itself alone (`assets_load_alone`): a
  large asset goes alone and no load waits forever behind the others. The first scene of the
  player has nothing on the screen to keep smooth: it has the frames, `LOAD_WHOLE_FRAME_SECONDS`
  of each, and every job worker (`assets_load_whole`). `load_under_way` says whether a load is
  not resident yet.
  - A texture of more than `LOAD_FRAME_BYTES` that a load takes over several frames
    (`assets_take(..., over_frames=true)`) costs in its frame only its levels of side
    `TEXTURE_TAIL` (`assets_prepared_cost`); the others go up with the renderer's uploads
    ([residency](../../mirai-rendering/references/materials.md#residency-by-sampling)) and the
    load ends when they have gone up (`app_assets_uploading`). Without room in that queue, it waits
    a frame. Whoever needs the result right away takes it whole.
  - A mesh that gives the pools more than `LOAD_FRAME_BYTES` right away (with skeleton, morphs,
    `Levels`, or a large root) costs nothing in its frame: the renderer registers it and uploads its
    geometry over the following frames, with the textures
    ([several frames](../../mirai-rendering/references/scene.md#geometry-over-several-frames)), and
    nothing draws it until all of it went up. Its copy in the CPU pools is written with that upload,
    from what was prepared, which stays until it went up. The load waits for it as for the
    textures, and without room in the queue it waits a frame. A far mesh made in memory
    (`assets_mesh_publish`) does not go through here and goes whole in its frame, with what its job
    did (`assets_render_geometry_rays`).
- **Textures of materials and meshes that draw arrive** (`assets_streaming.odin`). In an
  application with job workers and a renderer (`Assets.arrive`), a material that names a texture
  that is not loaded does not read it: its row goes without it, a job reads its levels of side
  `TEXTURE_TAIL` (`ASSET_ARRIVALS` reads at once) and the frames give them to the renderer in
  the part of the load budget, before more levels of others; the rows of the materials that
  waited take it (`assets_arrivals_settle`) and what the GPU samples asks for its larger levels.
  A mesh render sync draws arrives so too (`assets_mesh_shown`), its geometry over frames when
  it is large; a structure change names it, and only the entities that waited for it are drawn
  again. No frame reads, decodes or uploads a whole texture for a material or a mesh for what
  draws it. `assets_texture` and `assets_mesh` of an arriving asset load it whole in the call
  (`assets_arriving`). While `app_assets_arriving` counts any, a load is not resident and a
  capture that waits for its textures waits.
- **What was read is released in jobs** (`assets_release.odin`): `app_assets_take` installs and
  keeps what was prepared, and `app_assets_release` and `app_assets_release_file` receive what
  nobody takes; between frames (`app_assets_releases_step`, in `app_frame_begin`) one job at a time
  releases files, levels and trees, and what a library read in jobs and hands over (`app_release`,
  like the far shape of a section). What the renderer is still uploading (the levels of a texture,
  the geometry of a mesh) waits until it has gone up. Without job threads it is released in the
  call.
- `app_asset_changed(app, path)` rereads what is loaded from a file that changed on disk or in
  memory, as when the watcher sees it.
- `assets_material_derive`, `assets_material_values`, `assets_material_overlays`,
  `assets_postprocess`: derived rows of the material table, with the
  values of a material as an entity or a layer shows it; equal values share a row.
- `assets_appearance_begin/end`: a round; it releases the derived rows that nobody asked for.
- `assets_commit`: delivers to the renderer the rows that changed, alone (`materials_update`), or
  the whole table after a change of programs, textures or unloads, or past `ASSETS_ROWS_DIRTY` rows;
  whoever asked for materials calls it before the frame.
- `assets_material_set(a, id, info, parameters)`: changes in memory the values and parameters of a
  loaded material, without reading or writing its file; only its row goes to the renderer.
- `assets_reload(a, id)`: rereads a loaded asset and replaces it in place; `false` if the new file
  does not load (the previous one stays). A material only sends its row if its values changed.
- `assets_scan`: looks at the folder again; `assets_refresh(a, paths)`, only those paths of the
  registry ([refresh](../../mirai-assets/references/formats.md#registry)). With a packaged index
  neither looks at the folder; a refresh still sees the paths of the guest mounts.
- `assets_mount(a, folder, prefix)`, `assets_unmount(a, prefix)`: a folder the game did not ship
  (levels a player saved or downloaded, mods) found by id and path at once, also in a shipped game,
  as a [guest mount](../../mirai-assets/references/formats.md#registry) that never takes an id the
  game has. It is not watched: whoever writes in it refreshes those paths. Unmounting takes its
  files out of the registry; what loaded from them stays until no world names it.

**Derived rows.** The values of a material as an entity or a layer shows it
(`assets_material_derive` and similar) are derived rows of the material table; equal values share a
row.

- They are immutable while they have users; an appearance round (`assets_appearance_begin/end`)
  keeps those in use and releases the others.
- `assets_commit` delivers to the renderer only the rows that changed, or the whole table after a
  change of programs, textures or unloads, or past `ASSETS_ROWS_DIRTY`; whoever asked for materials
  calls it before the frame. The renderer reclassifies instances only if the class of a row changed
  (alpha, program, reflectance, layers).
- A material that changes values with derived rows in use advances `structure` with its id:
  `render_sync` derives again only the instances that show it.

### Generated meshes

`assets_mesh_generate` registers a mesh made at run time, with its own id and no file
(`Mesh_Generate_Options` and `Assets_Heightfield` in `host/assets.odin`).

- It copies the geometry to the renderer as a transaction, without touching an already registered
  mesh; the input buffers may be released on return. Each generated id is an immutable version that
  is never reused.
- The geometry the renderer takes goes through the `asset` builder (`asset.mesh_build`): one vertex
  per vertex, slot and tangent, in single-level clusters, with the cuts of their rays. Whoever
  builds the mesh in a job (the terrain chunks) builds that `Mesh_Render_Geometry` there with
  `assets_render_geometry_make` and the `Assets_Limits` of the assets thread, and passes it in
  `render_geometry`; between frames only giving each slot the row of its material remains.
- By default it keeps no CPU buffers. With `collision` it copies what `assets_geometry` and
  `assets_collision` need (with `collision_mesh`, another mesh: a coarse level over the collider of
  another), `disabled_edges` and the heightfield, which are lent until retirement, with the
  convention of the
  [physics heightfield](../../mirai-physics/references/physics.md#geometry).
- `hull_points` and `hull_sizes` give the convex pieces a `Hull` collider of the mesh is made of,
  copied and lent like `collision`; `assets_collision_hulls` returns them
  ([colliders](../../mirai-physics/references/engine.md#collider-fields)).
- `assets_geometry` appends to the consumer's buffer; with `slots`, the material of each slot read
  from the file without loading it into the renderer (the editor thumbnails). It does not deliver
  UV1. It validates and reserves before appending: on an error it returns `false` and keeps values
  and lengths.
- `assets_mesh_release` releases the CPU copies, the entry and the GPU ranges and advances
  `revision` and `structure`; it is done before syncing the frame, never after delivering an
  instance that still uses it. With `assets_structure_changes`, a consumer that fell outside the
  history refreshes everything.
- GPU handles are reused: the current id is stored, not a retired handle. The RHI defers native
  destruction until the frames that might use it finish
  ([contract](../../mirai-rendering/references/rhi.md#rhi-contract)).

### Failures, unloading and watching

- **Failures.** What does not load leaves an entry in `assets_errors(a)` and a visible substitute
  (the cube, an emissive magenta material, a checkerboard). It is not retried until `assets_reload`.
  Without a renderer, a texture the registry lacks is not a failure: nobody shows it, and a
  dedicated server is cooked without textures.
- **Counters.** `revision` advances with each reload or unload; `structure`, when scene instances
  must be revised, with bounded history; `appearance` numbers the rounds of derived rows.
- **Scope and unloading.** `Assets_Scope` is whoever uses what is loaded (up to 16).
  `world_asset_ids` finds by type every `base.Asset_Id` of the tables and storages of a world (with
  `shared` and its id, also of its `by_world` storages), in structs, arrays, enumerated arrays,
  slices and dynamic arrays, not behind pointers or in maps; `world_owned_asset_ids`, by the world's
  schema, those under a field tagged `owned`; `assets_collect` unloads what no scope
  reaches. `app_assets_mark` (at the start of each frame) maintains a scope with what all worlds
  mark and unloads when it changed: changing scene or unloading a section releases what nobody
  uses. An asset that the game uses must be named by a world (a component, a setting); the editor
  retains the documents it has open. A world that a job writes is not read: whoever builds it says
  so with `app_assets_building` while the job runs, and what it names counts from the next mark.
  Where each type stores ids is computed once per `World_Info`; a table without `Asset_Id` is not
  marked, and what is marked of a world is rebuilt only if one of its columns or its storages
  changed.
- **Watching.** With `assets_root`, the application watches that folder (recursively) at a fixed
  rate, refreshes in the registry the files that changed and reloads them in place; if the folder
  has more files than the watcher remembers (`Watch_Stats.untracked`), it scans it whole. Without
  system watching it does not reload and runs the same. The asset folder of a mounted plugin is not
  watched. `assets_cache` is the registry cache file; the editor passes that of its project.
- BC textures on a device that does not sample them are decoded to RGBA8, and BC6H to RGBA16F. An
  array or a cube is loaded whole; where a 2D image is sampled (material, program parameter, UI,
  decal, sky) it is `Unsupported` (`assets_texture_image`). The levels of a single-layer texture
  follow what the GPU samples of it
  ([residency](../../mirai-rendering/references/materials.md#residency-by-sampling)):
  `app_textures_stream` reads them from its file in jobs between frames and shares with the loads
  their part of each frame.

## Content

`Content` (`app_content(app)`, `host/content.odin`) loads on demand what is not meshes or materials:
`.ui`, `.anim`, `.sound`, `.sound_set`, `.font` and `.prompts`. The `.strings` are one table of
the application, as the rows of the records (`host/texts.odin`).

- Each entry carries a `generation` that changes with each load: whoever stores state made for the
  previous one rebuilds it.
- `content_sound_pick` chooses what sounds by a `.sound` or a `.sound_set`, with the generator of
  `Content`.
- A `.ui` resolves its images and its UI programs again when `Assets.revision` advances, which also
  advances when shaders are reloaded.
- A streamed sound keeps its file open until the application ends.
- **A font is a font of `App.ui_font` until the application ends.** `content_font` gives it on
  load the index it will have (that of `Text_Style.font`); `app_ui_fonts_apply`, at the start of
  the application frame and before any context starts its own, adds it or gives it the new bytes
  when its file changes. `content_collect` does not unload it; without a renderer the fonts wait. A
  font of a `.ui` that does not load makes the load of the `.ui` fail.
- `prompts_find` gives the `ui.Prompt` of the texture part of the pack; keys and mouse are of the
  `Keyboard` family whichever one is asked for.
- An `.anim` is published compressed with `asset.animation_compress` (a cooked one, as it comes);
  if the preparation fails, the previous load stays ([animation
  storage](../../mirai-std/references/anim-storage.md)).
- **An `.anim` is compressed once per input** (`host/content_animation.odin`).
  `App_Desc.animation_cache` (the editor and the player pass `project.ANIMATION_CACHE` of the
  project) keeps the compression as the cooked document a shipped game carries, named by the asset
  and a hash of the `.anim`, the skeletons its clips name, the container `asset.VERSION`,
  `asset.ANIMATION_VERSION`, `anim.COMPRESS_VERSION` and the config. A load takes it only when it
  is whole and of that asset with the clips, tracks and markers of the `.anim` (by name, place,
  root and skeleton); else it compresses and writes it, removing the other entries of the asset.
  Authoring reads the source `.anim`, never the cache.
- **A compression runs in a job** with two workers or more, at once otherwise: the main thread
  reads the `.anim` and its skeletons, the job builds the library, and the main thread takes it and
  writes the cache at the start of the frame after the job ended (`app_content_adopt` in
  `app_frame_begin`). Meanwhile a first load is pending:
  `content_animation` gives nil, `content_animation_pending` says so and the animation runtime
  plays the entity on the sources it played, or, having played none, as one without asset (a rig
  holds its rest pose), without a problem; a reload keeps the previous library.
  `content_animation_wait` waits and takes it, for whoever needs the library now (an API call,
  between frames). Unloading, reloading again or ending the application waits for the job; a
  compression that ended is still written.
- **A world does not start playing while its animations compress.** `content_animations_start`
  starts the first load of every `.anim` some ids name, directly or through the assets they
  depend on in the registry (a spawner's prefab, its `.character`), without following scenes, and
  `content_animations_pending` says whether one still compresses or waits for them. A
  [scene load](../../mirai-gameplay/references/libraries.md#scene) ends once those of its World
  are loaded; the [editor](../../mirai-editor/references/editor.md#play) starts those of a scene
  when it opens it and Play waits for them before its first tick. Only data is followed: an
  `.anim` that only code names (a constant written into `Animation.library`) loads at its first
  use, is unloaded when no world names it and is not cooked, so data names it (a field of a
  component of the entity or its weapon, `kind=.anim`).
- **What a job loads changes only at the start of a frame**, never on a lookup: a frame sees the
  same content from start to end. `Frame_Record.content` keeps `Content.generations` when the frame
  began, and a frame played again (`app_game_frame` with `replay`) finds pending a first load a job
  made after that; so does a tick run again (`app_tick_replay` with the `content_generation` it
  saw). A reload is not undone in a replay: `content_reloaded_after` says that the
  frames before it read what it replaced.

## Shaders at run time

The executable carries the engine shaders. If the project has Slang programs, `mirai build`
publishes a generation (`<project>/.mirai/shaders`) that `host` loads at start and reloads when its
manifest changes: the driver compiles the pipelines on a thread while frames continue, and between
frames they are replaced whole or not replaced
([loading in host](../../mirai-rendering/references/shaders.md#loading-in-host)). A generation
compiled from other engine shaders stays `Stale` until a build, and one that fails leaves what was
running.

## Bridge with `ui`

- `ui_frame_split` passes a `ui.Frame` to the layers and panels of the renderer: the commands
  followed by a panel whose vertices continue are one panel, and those of an `offscreen` panel are
  the layer of a `render.Ui_Texture_Draw`, with their layers isolated. `app_ui_texture_capture`
  draws one like that in its own frame, without the scene or the window, and reads it.

- `ui_input_camera` builds the UI input from a camera; with a rectangle it limits the ray to the
  part of a player without changing the screen UI coordinates. `app_views_set` stores the camera of
  each view in `App.local_cameras` until the next frame: the UI of each player places and aims its
  panels with it.
- `app_ui_context_create` creates contexts that borrow the application's font: one atlas serves all.
  A context asks for the glyphs it lacks while drawing and `app_ui_font_sync`, after its frame,
  grows the atlas and passes the region that changed to the renderer.

## Changing `host`

- What lasts lives in `App` or in what `App` points to; loading assets, creating worlds and
  reloading shaders are transactions between frames.
- `host` imports neither `engine/*` nor `editor`. What a library needs from the application is a
  field of `App` or a procedure of `host`.
- `player_run` and its generated `main` are the contract of the game binary: if the signature
  changes, the generator changes.
- `mirai_project_info` and `core.World_Info` are the contract of the libraries: a new field of the
  `World_Info` changes the layout hash and the engine declarations.
