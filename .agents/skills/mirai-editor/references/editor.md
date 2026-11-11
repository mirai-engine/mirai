# The editor

- `editor.launch` loads the project library, calls `mirai_project_info` and `editor.run`, which
  opens the session, advances frames and closes; the previous build is in
  [projects](../../mirai-projects/references/projects.md#engine-binaries).
- The editor has no game types: it works through `core.World_Info` over the `World` and the
  `Editor_World` that the project generated.

## The session

`Session` is a `@(storage)` of the `Editor_World` that links the other storages, one per area;
`session_init` fails if one is missing. Outside it, with `core.world_storage_of`, are `Prefabs`
([prefabs](prefabs.md)), `Collab` ([collaboration](collaboration.md)) and `Api`
([API](../../mirai-agent-api/references/api.md)).

- `edit_world` is the document's world; `runs`, the runs (`Run`: world, owner, requested step and
  input); `watch`, what is watched in `Watch`, with the mode it returns to and its camera.
- `mode` is `Edit`, `Play`, `Paused`, `Simulate`, `Simulation_Paused` or `Watch`; it is queried
  with `playing`, `simulating`, `play_paused`, `play_shown` and `watching`.
- `edit_orbit` and `edit_selection` keep the camera and the selection from before Play or
  Simulate; Stop restores them.
- Paths are absolute with `/`; without `engine_root` there is no Build.
- `view_cut`: the shown world changed and the renderer discards the image history.
- `shown_world(s)` is what is watched in `Watch`, the Play while it runs or, otherwise, the edited
  world; `edited_world(s)`, always the document's. `status(s)` summarizes mode, document, undo and
  Build.

## Arguments

The editor prints its usage (`USAGE_TEXT`) on an unknown argument. What the usage does not say:

- `--headless` without `--frames` is the **manual mode**: it does not advance by itself, serves the
  API and advances when asked. While waiting it keeps up what runs in real time outside the world:
  the Build, the game of the plugin that plays one (`Play_Provider.poll`), collaboration and
  recovery. With `--frames n` it runs n frames, serves the API once per frame and ends.
- `--no-gpu` and `--density` require `--headless`. `--density` serves to see in a capture what only
  fails with fractional scale.
- `--hidden` opens the native window hidden with the continuous loop; `--width` and `--height`
  give it a size in points and without them it is maximized.
- The editor itself passes: `--documents` (manifest of all tabs after a Build), `--gpu-lost` (what
  stopped the GPU of the editor that restarted it:
  [GPU that stops working](#gpu-that-stops-working)), `--restore`, `--view`, `--select` and
  `--dirty` (recovery of a document), `--launcher` (only the
  [projects](panels.md#projects) screen) and `--git-init`, `--git-lfs` and `--git-remote` (the
  project becomes a repository as soon as git responds: [git](git.md#operations)).
- The exit codes are the `EDITOR_*` constants of `editor.odin`; that of a manual headless without
  the API driving it says why on stderr.

## The editor loop

One frame (`advance`): `host.app_frame_begin`, `game_frame` (the game loop of the Play, if there is
one), `host.app_editor_frame` (the editor loop over the shown world), `host.app_frame_end`,
`between_frames` and `services_poll` (collaboration and API). With a Play, the editor loop runs
all phases except `fixed`, which belongs to the game; while editing, all with `dt` 0.

With the window unfocused, outside Play and Simulate and without an agent driving it (a call in
progress or within the last `API_ACTIVE`), the editor drops to `EDITOR_BACKGROUND_FPS`
(`platform.set_background`): behind other windows it does not compete for the GPU with other
programs or with measurements. A manual headless does not draw between calls.

Editor steps, in order; a plugin step orders itself against them with `after`
([extensions](extensions.md#package-rules)):

- `ai_input` (`input`, stage `begin`): prepares the pending message, consumes ACP and dispatches
  the queue to the workers ([chats](ai-tasks.md)).
- `editor_begin` (`input`): opens the UI with the frame's input, computes `Viewport.hovered` and
  runs shortcuts.
- `editor_tools` (`frame`, stage `begin`): camera, gizmo and selection; writes the `core.View` of
  the shown world.
- `editor_panels` (`ui`): bar, panels, popups and dialogs.
- `editor_end` (`ui`, stage `end`): drawing over the scene, highlight, end of the UI and recording
  of the finished undo step.
- `editor_services` (`ui`, stage `end`): thumbnail atlas, graphics settings and imports.
- `ai_frame` (`ui`): marks the history state when the frame ends.

## Play

- Play and Simulate run a copy of the `World` in the editor process, with the same application,
  GPU and library. Each run has an owner: the user or an AI turn.
- `play_start` ends the open edit, writes the recovery copy if there are unsaved changes, creates
  the world with `core.world_copy` (which brings the clock of `edit_world`, at zero: the editor
  loop does not advance it) and keeps camera and selection for Stop. Document and history stay in
  `edit_world`. If it cannot write the recovery or create the world, memory included, it does not
  start ([recovery](document.md#recovery-and-failures)).
- Opening a scene starts the first compression of the `.anim` its world can play, and
  `play_start` waits for any that has not ended: no entity of a run plays a library still
  compressing ([content](../../mirai-core/references/host.md#content)).
- Bounds checks stay active; a native failure can end the editor, which does not continue on
  possibly corrupt memory.
- A Build with the same layout reloads the functions and keeps both worlds; another layout
  restarts the editor and ends the run ([Build and reload](#build-and-reload)).

Input and layout:

- F1 releases keyboard and mouse without pausing. A click in the scene gives them back to the game
  and does not reach it; with several local players, it chooses that of the view where it lands
  (`inp.focus`).
- Play minimizes the left panel and hides Details and the bottom panel. The chat opens only in
  `Paused` (Tab, or the AI action), where clicks in the scene select the paused entities it refers
  to; resuming closes it and gives the input back.
- With the Play running the shortcuts belong to the game except F5 and Shift+F5 (stop), F6
  (pause) and F1, which never reaches it; Tab is the game's. `Esc` asks for Stop. The viewport
  receives no edit gestures (`hovered` false). Stop restores the layout and the mouse from before
  the Play.
- `Paused` keeps the world and uses the editor camera; `play.step` runs exactly the ticks it
  asks for, and its network continues between steps
  ([network pause](../../mirai-networking/references/multiplayer.md#the-tick)). Outside the pause
  the camera is the editor's, unless the Play has a camera of its own (`core.View.camera`).
- Save, open, new scene, import and the prefab operations require `Edit`. Scene editing by API does
  not: it writes to the document, which the game does not see until stopped.

Agent runs:

- `Session.runs` keeps the user's, which is the shown one, and those of the AI turns
  (`EDITOR_RUNS`, with the client runs of a turn), each with its own copy of the world and its
  clock.
- `play.start` inside a turn creates the turn's run without changing the view, even if the user or
  other turns are playing. It does not advance by itself: one tick per `play.step`; `play.status`
  reports it with `detached` and `play.pause` does not apply. `play.start` with `simulate` from a
  turn is rejected: the turn simulates with `play.step` without keys.
- `game_frame` advances the user's game first, with the window's input, and then the ticks asked
  for by the turns, with input blocked except that of each `play.step` (`run_input_give`). The UI
  of a turn's game takes `Run.ui` and `Run.pointer` (`run_ui_input`) instead of the window's
  input, also when drawn with `capture`.
- A turn acts only on its own run: it reads the user's Play it started in, but does not pause,
  advance or stop it. If the user leaves that Play and the turn has no run of its own, the run
  passes to the agent: view, camera and selection return to Edit and the user can open another
  Play.
- A turn's run ends with the turn; all end with a document change (`runs_stop`).
- Turn runs are not drawn in the window unless the user [watches](#watching-another-run) them;
  `capture` from a turn draws its own off screen (`host.app_capture_world`).
- A game that asks to quit (`app.quit`) stops the Play, not the editor; while the user watches
  another run the request is discarded. What a run that is not shown adds to the frame (UI layers,
  panels, lines, instances, views) is discarded after its loop (`extras_mark`, `extras_drop`).

History and recording:

- Each run without network keeps its past (`Run_History`, `editor/play_history.odin`): for each
  frame, what it gave the world (`host.Frame_Record`: its dt, the clock accumulator, the ticks it
  ran, the input and the content it found loaded) and a hash of the `Transform`s it left; and
  every so often a copy of the world, a keyframe, made with `copy_changed` (storages with
  `copy_kept`, like physics, keep only what they use). The
  frames cover `Play_History.seconds`; the keyframes fit in `megabytes`, counting what their copies
  occupy, spaced to cover those seconds.
- Going to a tick (`play.seek`, or the strip of the past under the scene while the user's Play is
  paused) takes the previous keyframe, or continues from where it is if it lies before and after
  that keyframe, and plays the frames in between again with `Time.resimulating`, without sounds,
  network messages or repeated problems. If the hash of what they left differs from the one they
  kept, the game did not repeat or something outside its frames changed it (an edit, a Simulate
  movement): `matches` says so. The later past stays until the run plays a new frame. The UI asks
  for the tick and `play_history_seek` fulfills it between frames, never inside the loop that
  draws it.
- While paused, Details shows what is selected in the game and edits it on the copy, without undo.
  Before the frame following a pause (or each step of a turn), if the table versions changed since
  the frame it is at (`history_before`), the edited world becomes the keyframe of that frame and
  the later past is discarded: returning there finds the edit. An edit while the game runs does not
  enter. Content loaded again since that frame (`host.content_reloaded_after`) is such an edit,
  also while the game runs.
- The Play of the strip passes the past again at the clock's pace, with the game paused: each
  frame goes to the ticks the clock covered and stops at the newest, or returns to the oldest with
  Loop; Space does the same while the strip is shown and no text field is being edited
  (`editor_shortcuts`), and is the game's while it plays. Resuming (Pause on the bar,
  `play.pause`) returns to the newest frame it played and discards what was edited in the past;
  **Play from here**, among the strip controls when it went back (`play.pause` with `here`),
  continues from the frame it is at, edited or not, and discards the later ones.
- The right button on the ruler of any time strip (`timeline_strip`: Play, assets that play,
  the Tracks tool) sets an end of its range at that frame (the other end stays while start stays
  before end; otherwise, or without a range, it goes to the head or to the edge). Where the
  document describes its range (`Ai_Range`), Copy range puts a few lines on the clipboard, paths
  relative to the assets and never absolute: the ticks, the run (`Run.id`) and the scene of a Play;
  the frames, the asset and its clip; or the ticks, the entity whose clip it is and its scene. With
  a range, the AI button of the strip attaches the same to the next message of the chat
  ([ranges of a message](ai-tasks.md#assets-of-a-message)).
- Stop keeps the user's Play that has a history, with its World and voices stopped
  (`Session.replay`), until the next Play, a change of document or a reload of code: `play.history`
  reads it and `play.seek` opens it again paused (`play_review`). Edit never reads or writes it.
- While paused, what the mouse and keys do belongs to the editor: `play_input_update` discards
  each frame the window's per-tick input, and the game that continues does not receive it all
  together in its first tick (the look and the body's turn would jump).
- `play.record` advances the run with frames of `1/fps` (`Run.frame_dt`, the `dt` of
  `host.app_game_frame`), without the window's input, and after each one draws the world alone in
  a texture of its own that keeps TAA and exposure between frames (`host.World_Recording`). While
  recording, the audio device is paused and the editor mixes by hand what corresponds to the
  frame. An editor without a window with GPU opens audio with the `dummy` driver, to have
  something to mix.
- `play.record` first deletes the sequence that a previous recording left in the folder.
- **Output frame** (View menu) darkens outside the aspect ratio of the last recording, only while
  the viewport looks through a game camera (Play with its own camera or the camera preview): through
  the editor camera it would frame nothing of what is recorded.
- **Detail of the game camera** (View menu; `game_detail` of `Viewport_Preferences`): in a Play
  the user paused, the levels of the meshes and textures are those its camera saw at that tick
  (`Session.paused_view`, kept before the editor camera takes the `View`), wherever the editor
  looks from, so a wrong level seen while playing is seen up close.

### Play from a place

The run menu (the arrow of the Play button) chooses Play, Simulate or Play from camera: the button
keeps the chosen one (`Layout.run_kind`) and choosing it also runs it.

Play from here (the right-click menu, on the first body the ray touches) and Play from camera (the
run menu, the View one and that menu; `play.start from`) leave in `Session.play_asked` where player
1 goes, looking level toward where the camera looks. The next `play_start` passes it to
`scene.Play_Origin` with `asked` and discards it; without that, `Play_Origin` is the camera as a
fallback. How the game uses it:
[spawn points](../../mirai-gameplay/references/control.md#spawn-points).

## Watching another run

The `Watch` mode shows in the viewport the run of a turn without stopping any
(`watch_start(s, task)`). `watch_stop`, Stop, Esc, F5 and the bar chip return to the previous mode
and camera.

- From Edit it keeps the document's selection in `edit_selection` and restores it on return. From
  a user Play it releases input; that game keeps running without being seen or receiving input
  (`game_frame` advances it according to `watch.from`) and, if it ends in the meantime, on
  stopping watching it returns to Edit.
- What is watched receives no user input. A turn's run advances only with its `play.step` and is
  seen with its game camera or the editor's.
- What is watched is not edited: the
  [edit procedures](document.md#world-edit-procedures) do nothing, the gizmo and the
  tools do not act, Details is disabled and Paste, Duplicate, Delete, Group, Rename and Pause are
  turned off. Selection, Hierarchy and camera work on the watched world; document editing by API
  stays the same.
- `watch_update`, between frames, stops watching with a toast when the run ended. A document
  change ends the runs and what is watched; the user's `play_start` stops watching before starting.

## Networked Play

The editor knows nothing about networked games: `multiplayer` provides them through its
`Play_Provider` ([extensions](extensions.md#a-plugins-game-and-player-processes)), and the
networked game is in [multiplayer](../../mirai-networking/references/multiplayer.md#networked-play).
The editor provides the generic parts:

- **Local players.** The run selector chooses how many share the screen; `play_start` puts them in
  `Run_Players.count` of its run's world, instead of those of the scene
  ([seats](../../mirai-gameplay/references/control.md#seats)), and `engine/camera` splits the
  view ([cameras](../../mirai-gameplay/references/control.md#cameras)). `Play_Players` keeps them
  between sessions.
- **A plugin's game.** Play (F5, `play.start`) first asks the `Play_Provider` whether it starts its
  game; the plugin adds rows to the run menu, the icon, the bar label, Stop and the question about
  unsaved assets (`Pending.Play_Plugin`). While its game runs, Play and Simulate wait. Without a
  plugin that provides it, `play.start` with `online` fails saying `multiplayer` is missing.
- **Player processes** (`editor/player_processes.odin`): the plugin opens a `mirai-player` per
  player with the arguments that say what it plays; the editor adds `--attached` and how to show
  it: each process loads its copy of the `editor` library that the editor already loaded and runs
  only the game's world and its loop, like the editor's Play, so nothing is compiled for them. A
  Build while they run replaces the file: the processes continue with their copy
  ([project libraries](../../mirai-core/references/host.md#project-libraries)). The scene copies
  they run go to `.mirai/play/` (`play_copy_file`).

Screen and input of the processes:

- The screen is divided among the locals, in the parts the editor fixes in `app.player_tiles`
  ([host](../../mirai-core/references/host.md)), and the processes, which run without a window with
  `--surface` and draw into shared textures that the editor opens (`gpu.texture_add_shared`).
  Without shared textures (`rhi.device_shares_textures`), each opens its window in the usable area
  (`--window`; [player arguments](../../mirai-core/references/host.md#the-player)). A process alone,
  without locals, takes the whole viewport (`app.ui_only`) and the editor stays in Edit without
  panels.
- A click on a process gives it keyboard and mouse (the editor forwards the events over stdin); a
  click on a local returns them to the Play. F1 returns input to the editor; Esc ends the game.
  Only the one with focus is heard. Each process's output goes to the console with its name and the
  plugin reads how it ended (`player_processes_poll`).

A turn plays with online players inside the editor (`Play_Provider.turn`): the plugin creates a
run per player (`Run.player` from 1), without compiling or opening processes; `play.step` advances
them together and gives the input to that of `player`, which `scene.inspect`, `play.player` and
`capture` read.

In a shared session, the host's presence carries what its plugin offers of the game it serves
(`Play_Provider.offer`, opaque to the editor), and the menu of its figure, the plugin's rows for a
guest (`host_menu`); the game's scene travels to the guest
([collaboration](collaboration.md#the-hosts-networked-games)). No binaries travel: each one
compiles the same sources.

## Simulate

The **Simulate** button and `play.start` with `simulate` run the whole scene on the local copy:
neutral input, logic, physics and network ticks, animations and game UI. It exists with or without
physics; `physics` adds dragging bodies with the gizmo through its `Simulation_Provider`.

- The editor works on the copy with its camera, panels and tools; player input is also blocked
  when advancing by API. The game's screen UI layers are discarded after running and their camera
  views are withdrawn; the world panels are drawn.
- With `physics`, move and rotate drive the body with temporary kinematic requests (a `Collider`
  without `Rigid_Body` can push dynamic ones) and on release it recovers its type, without
  residual velocity. While paused it is repositioned and contacts are resolved on advancing.
  Escape returns the body to the start of the gesture; its effects on others are discarded with
  Stop. A collider child of a compound body selects the body's owner. Resizing a body asks to stop
  the simulation; the character keeps its controller.
- Pause and Stop work in Play and Simulate. `Simulation_Paused` keeps the world and allows
  navigating; `play.step` advances the ticks it asks for.
- **Stop discards the copy** and the camera used inside it; it keeps document, unsaved changes,
  selection and history. It does not revert files or external services the game writes.
- **Apply transforms** captures between frames the poses of the selected entities that already
  existed in the document, discards the copy and applies them in one transaction: it validates
  distinct ids and finite poses and computes local transforms under the original hierarchy.
  Without changes it adds no undo; it does not keep entities created at run time, components,
  velocities or other state.
- **Limited to some entities**: from Edit, a copy of the document advances only its simulation,
  at the project's tick rate, with those entities moving and every other body still, until they
  rest or the ticks run out; their poses are applied as Apply transforms does, and nothing else of
  the copy is kept. It is how objects are dropped onto the scene and onto each other: inside one
  call with `simulate_until_rest` (`physics.settle` and its **Drop to rest** entry on the
  selection), or a few ticks a frame with `settle_begin`, `settle_add`, `settle_tick` and
  `settle_write`, which show the poses inside a gesture's
  [cancelable preview](extensions.md#cancelable-previews) (the Drop tool of `physics`).

Public API for tools in [extensions](extensions.md#simulation-and-pose-confirmation); methods in
[API](../../mirai-agent-api/references/methods.md#simulation).

## Camera preview

`camera_preview.odin`. Preview, in the `Camera` card of a document camera, or the `camera_preview`
action on the selection, run the scene like Simulate, without the players' input, with the view
from that camera (one that follows, one that brings an action or one of a cinematic).

- The focused seat of the copy sees through that camera by a camera override whose owner is the
  seat (`camera_preview_frame`), whichever camera its body has. The viewport draws no grid,
  disks, gizmo or outlines and receives no gestures.
- A bar at the bottom offers the document's cameras; choosing one shows it with the transition of
  its activation, or that of the one it leaves, and selects it.
- Details edits the shown camera on the copy: it is seen immediately and is not an undo step. Keep
  (`camera_keep`) writes to the document, in one step, the lens, the `Camera_Follow` and the
  `Camera_Activation` of each camera that changed; Discard (`camera_discard`) or Stop leave them as
  they were. What exists only in the run is not offered.

## Figures of whoever works

Each agent ([in scene](ai-tasks.md#agents-in-scene-and-review)) and each other editor of the
session ([collaboration](collaboration.md#what-travels)) is drawn with the same figure
(`presence.odin`):

- The dog of `editor/assets/presence`, a transient visual instance (`host.extras_instance_add`,
  `copy_owner` `PRESENCE_OWNER`) without entities or a place in the scene. It faces -Z rotated only
  around +Y: without a rig, it does not look up or down.
- La malla separa pelaje, piezas neutras y los slots del arnés, la franja de la nave, la pantalla,
  los lentes y las estrellas. Cada figura deriva con su color los del arnés, la franja, la pantalla
  y las estrellas; en estas también cambia la emisión. El pelaje, los lentes oscuros y las piezas
  neutras conservan sus materiales.
- It carries the outline of its color without fill and, over the head, on screen, its glyph (that
  of the bar) and its name.
- A click on the glyph or the figure of an agent opens its chat; that of another editor, or the
  right click on a bar glyph, opens its menu (`presence_menu.odin`): **Go to**, **Follow** (follows
  its camera until one's own moves), **Join game** of the host for a guest, and **Open chat** and
  **Watch** of one's own agent.
- A palette, `AGENT_COLORS`, for agents and editors, with an outline level per color from
  `AGENT_LEVEL`; `AI_CONTEXT_LEVEL` is what a turn only read. The glyph and the name distinguish
  an agent and an editor of the same color.
- It moves toward where it is said to be, which arrives a few times per second, with exponential
  smoothing (`presence_follow`), and jumps if far (`PRESENCE_SNAP`). The instance is rebuilt only
  if the place, the rotation, the color, the assets or the round of derived rows change
  (`Presence_Key`); at rest, a frame does not allocate.
- A game is seen alone (`presence_in_scene`): in Play, paused or stepped, and in Watch no figure,
  glyph or name is drawn or clicked, nor enters a capture; they stay in the bar and the chat. In
  Simulate they stay, like the gizmo and the grid.

**Editor assets.** `editor/assets` is mounted in the registry of every project under `.editor`
(`EDITOR_ASSETS_PREFIX`). They are loaded by their path, but the content browser, `asset.list`,
`prefab.list` and the selectors omit them (`asset.registry_listed`): they are not dragged into a
scene nor enter a game. An open session does not reload them if they change.

The source `editor/assets/presence/source/pup.glb` is prepared in Blender as a single mesh, 0.9 m
tall, with its origin between the eyes and facing +Z of the file, which the import turns to -Z. Its
primitives 0 to 5 are fur, harness, stripe, screen, lenses and stars; the following ones keep the
neutral pieces. The source is not kept in git. `mirai import` with `--root editor/assets` uses the
settings next to it and writes the assets of the editor, reducing the mesh to `max_triangles`.

### Pings

A wheel click in the viewport, without dragging, marks the point under the pointer (what it
touches, otherwise the ground, otherwise the camera target) in the color of whoever marked it, with
their name in a shared session, for `PING_SECONDS`. It travels to the whole session; a new one from
the same editor replaces the previous.

## Between frames

- `requests_run`, called by `between_frames`, fulfills the requests of `Session.requests` in a
  fixed order. The API also calls it for actions in a non-manual editor; in a manual one the action
  advances a frame.
- New and Open stop the run before replacing the world: no UI action frees a world inside its
  loop.
- A scene with unsaved changes asks before being replaced or closed (Save, Discard, Cancel),
  resolved in `confirm_resolve`; the API uses `discard` instead of asking.

## Build and reload

**Build** (`Ctrl+B`, File > Build, `build.start`) rereads the project and launches in the
background the project's shaders and its `editor` library (`cook/build`, `Editor` target), also
during a Play. The engine binaries are updated by the
[external build](../../mirai-projects/references/projects.md#engine-binaries), and what it left
(`build.start` target `built`) is loaded the same way: first the engine libraries built again,
taken in place while what they declare stands, so the worlds, histories and Play go on
([taking a build in place](../../mirai-projects/references/projects.md#engine-binaries)); then the
library of the project and the shaders it published. Compiling on save does not exist: the build
is explicit.

- **Play compiles first** when an Odin source of the project's `game/`, `editor/` or `plugins/`,
  or its manifest, changed since the last build that remained (`code_fingerprint` against
  `Build_State.sources`, taken on opening and on starting each build): the Play waits in
  `Build_State.play` and starts when the library loads; if the build fails, it does not start and
  opens the Build tab. Shaders do not count: they are published by themselves.
- Diagnostics go to the Build tab, the console and `engine.diagnostics`; a failed build leaves the
  editor running. A successful one calls `library_reload` (`editor/reload.odin`) as soon as nothing
  holds the worlds (an API call that advances frames, a scene or a section loading): it loads the
  library with `host.project_library_load` and compares `core.world_layout_hash` with that of the
  loaded one. Libraries are not unloaded until closing.
- **Same layout**: `Session.info` is replaced in place and the library is added to
  `Session.libraries`. `World`, `Editor`, scene, history and Play stay in the same memory; the new
  functions run from the next frame.
- **Another layout** (a new, changed or removed component or storage, or a plugin enabled,
  disabled or recompiled): the worlds migrate in the process. Before that, networked Play,
  watching another run, the shared session and tool previews end, and the open gesture is
  confirmed. `host.app_worlds_migrate` moves each struct from each place in its direction
  (`core.place_migrate`): the user's Play, the agents' runs, the background tabs and the preview
  copies continue. Afterwards the history of each tab, the turn records, the sections and their
  pending references pass to the new indices and layout (`editor/relayout.odin`); the saved panel
  changes for Restore are discarded. The ACP workers are not touched: a live turn continues.
- **Restart** only if an engine library changed what it declares, or a `Shared` or `Editor`
  storage of the engine would change place or a struct does not fit in its reserve: the new
  library is unloaded and `Restart` is requested, with the reason in the log.

**Restart** (`restart`):

1. Stops the Play and saves each tab to `.mirai/restart-N.scene`.
2. Writes `restart-documents.json` with paths, selection, cameras, preview sun, pending changes
   and active tab; unsaved assets go to `.mirai/restart-assets/` (`assets_unsaved_store`) and
   return to memory before the scenes.
3. Starts the same `mirai-editor` with `--project`, `--documents` and the run arguments; the new
   process loads the compiled library and restores all documents.

- The original files are not modified. The snapshots are deleted when all were restored; on an
  error they remain.
- A restart starts new histories; a reload keeps them in all tabs. The shared session is not
  inherited.

### GPU that stops working

When `host.app_gpu_failure` reports a failure (`editor/gpu_failure.odin`), the editor does the
restart above with `--gpu-lost <text>`: a GPU reset costs a moment and none of the work; the new
one says so in the console and in a notification. If the one that started with `--gpu-lost` fails
again before `GPU_FAILURE_AGAIN_NS` since it became ready, the same work would stop it in a loop:
it leaves all its tabs and the unsaved assets (`recovery_tabs_keep`), which the next startup offers
to recover, and exits with `EDITOR_GPU_LOST` and a message that names the cause. `engine.gpu_lose`
causes the failure to test it.

## Commands and shortcuts

The methods of the API are the only catalog of commands (`editor/commands.odin`). A menu entry, a
shortcut and a button of the bar are an entry (`Binding`): the name of a method, its params as
JSON, a label, an icon, a shortcut and a menu. `command_run` runs an entry and `command_call` a
method with params the interface worked out (Play from here); both queue the call, which runs
between frames through the handler every call of an agent goes through, so the undo step, the
errors and what is refused are those of the method. What fails is said in a notice. A method the
person runs while a gesture of theirs is open records into that gesture's step
(`command_join`, `api_edit_begin`): one undo takes back both.

- **What is a command.** Whatever has a menu entry, a shortcut or a button. What a person does
  inside a panel with the pointer or the keyboard focus (a scroll, a hover, a fold, a splitter, a
  field being typed, the keys a focused card of the browser or an asset document takes) is the view
  of that panel and has no method. What the editor remembers of its view is a preference, and its
  entry calls `preferences.set`; what it does not (a dialog, a popup, a tab, the studio light) goes
  through `editor.view`.
- **The context stays out of the method.** The params of an entry name what the person has in front
  in place of values: `$roots`, `$selection`, `$active`, `$copied` and `$all` stand for entities
  (`api_context_entities`), `$toggle` for the opposite of what the entry shows checked, and `$ask`
  for a file the person picks in a dialog. They mean that only in a gesture: an agent names its
  entities and its paths.
- **A person and an agent.** `api_person` says the call that runs is a gesture. The method is the
  same; where it lacks a decision a person is asked (unsaved changes, the file of Open) and an agent
  is told what to pass, and a person does not wait for what goes on (a build, an import) while an
  agent gets the answer at its end.
- **What an entry shows** (`Binding.state`: off, checked, another label) is for the person at the
  editor now, and `editor.inspect` reports it with the method and the params of each entry. The
  methods of the scene write the document: with a game shown their entries are off, and Delete
  calls `play.destroy`.
- **Keys.** With `Ctrl` as `Cmd` on macOS; View > Keyboard shortcuts lists them, those of the
  plugins too. Two entries may share a key when they are never on together (Play and Stop on F5,
  Pause and Resume on F6). They do not run while a text field is editing, a popup or dialog is
  open or a tool has the pointer, and while a game has the keys only those of `in_game` do.
- F5 also stops the networked game and stops watching. Deselect (Esc) is the last thing that runs
  in a frame.
- Copy keeps the ids of the selected roots in `Session.copied`, not their data; Paste duplicates
  them like Duplicate, in one undo step, and selects the copies. What was copied and is no longer
  in the scene is not pasted. In Play and while watching, Copy and Paste are off.
- The Stats popup summarizes what `engine.status` gives in more detail.
