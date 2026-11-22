# The editor

`editor.launch` loads the project library, calls `mirai_project_info` and `editor.run` (session
open, frame loop, close; see
[binaries](../../mirai-projects/references/projects.md#engine-binaries)). The editor holds no game
types: it acts through `core.World_Info` over `World` and `Editor_World`.

## The session

`Session` is an `Editor_World` `@(storage)` linking per-area storages (`session_init` fails if any
is missing). Outside it (`core.world_storage_of`): `Prefabs` ([prefabs](prefabs.md)), `Collab`
([collaboration](collaboration.md)), and `Api` ([API](../../mirai-agent-api/references/api.md)).

- Worlds: `edit_world` (document), `runs` (`Run`: world, owner, step, input), `watch` (`Watch`
  target, return mode, camera). `shown_world(s)` returns watched, Play, or edited world;
  `edited_world(s)` is always the document; `status(s)` summarizes mode, document, undo, and Build.
- `mode`: `Edit`, `Play`, `Paused`, `Simulate`, `Simulation_Paused`, `Watch` (predicates:
  `playing`, `simulating`, `play_paused`, `play_shown`, `watching`).
- `edit_orbit` and `edit_selection` restore camera/selection on Stop. Paths are absolute with `/`;
  empty `engine_root` disables Build. `view_cut` discards temporal render history.

## Arguments

Unknown arguments print `USAGE_TEXT`. Exit codes: `EDITOR_*` in `editor/editor.odin`.

- **Manual headless:** `--headless` without `--frames` serves the API and advances only when asked
  while polling Build, `Play_Provider.poll`, and collaboration (no draw between calls). `--frames n`
  runs `n` frames and exits.
- **Window handoff:** launching a windowed editor on a project whose manual headless session runs
  from the same binary folder calls `editor.show` and exits, upgrading that session to a window
  with real-time frames and preferences (`engine.step`/`editor.input` end). If busy past
  `SHOW_WAIT_MS`, exits with error instead of stealing the port file. `--launcher`, `--frames`,
  `--share`, and `--join` always open their own process.
- `--no-gpu` and `--density` require `--headless`. `--hidden` runs a hidden continuous window;
  `--width`/`--height` set size in points (omitted = maximized).
- Internal flags: `--documents` (restart manifest), `--gpu-lost`, `--view`, `--select`,
  `--launcher` ([projects](panels.md#projects)), `--git-init`, `--git-lfs`, `--git-remote`
  ([git](git.md#operations)).

```sh
mirai-editor --project ./demo --scene main.scene --headless --density 1.5 --frames 8 \
  --capture bin/shot.png
```

## The editor loop

`advance`: `host.app_frame_begin` -> `game_frame` -> `host.app_editor_frame` -> `host.app_frame_end`
-> `between_frames` -> `services_poll`. In Play, the editor runs all phases except `fixed`; in Edit,
`dt` is 0.

- Unfocused outside Play/Simulate and idle (`> API_ACTIVE`) throttles to `EDITOR_BACKGROUND_FPS`
  (`platform.set_background`), unless `awake` transferring peer chunks.
- Ordered editor steps (plugin `after` targets, [package rules](extensions.md#package-rules)):
  `ai_input` (`input`, `begin`), `editor_begin` (`input`), `editor_tools` (`frame`, `begin`),
  `editor_panels` (`ui`), `editor_end` (`ui`, `end`), `editor_services` (`ui`, `end`), `ai_frame`
  (`ui`).

## Play

In-process `core.world_copy` on the same GPU/library. `play_start` ends open edits, runs
`files_flush`, waits for `.anim` first compression
([content](../../mirai-core/references/host.md#content)), copies `edit_world` (clock at 0), and
saves camera/selection. Nothing writes to disk during Play
([the file is the state](document.md#the-file-is-the-editors-state)). Bounds checks stay active.

- **Input & layout:** F1 releases mouse/keyboard; scene click recaptures (`inp.focus` selects
  split-screen view). F5/Shift+F5/Esc stop; F6 pauses; Tab toggles chat only in `Paused` (where
  clicks select paused entities). `Paused` uses editor camera; `play.step` steps exact ticks while
  networking continues ([tick](../../mirai-networking/references/multiplayer.md#the-tick)). Open,
  New, Import, and prefab ops require `Edit`; API scene edits still write the document.
- **Agent runs (`Session.runs`, cap `EDITOR_RUNS`):** `play.start` inside an AI turn creates a
  detached offscreen run (`play.status` `detached`; `simulate` and `play.pause` rejected; advances
  only via `play.step` with `Run.ui`/`Run.pointer`; renders via `host.app_capture_world`). Leaving
  user Play transfers it to an active turn lacking its own. `app.quit` stops Play, not editor;
  unshown run extras are dropped (`extras_mark`/`extras_drop`). All runs end on document change
  (`runs_stop`).
- **History & recording (`editor/play_history.odin`, non-networked):** `Run_History` records
  `host.Frame_Record` + `Transform` hash + `copy_changed` keyframes (`Play_History.seconds`,
  `megabytes`). `play.seek` replays from prior keyframe with `Time.resimulating` (no audio/net/
  duplicate problems) between frames (`play_history_seek`), returning `matches`. Paused edits or
  reloaded content (`host.content_reloaded_after`) update that keyframe and drop later history
  (`history_before`). Resume jumps to newest unless `here` (`play.pause` `here`, Play from here).
  Right-clicking a time strip (`timeline_strip`) sets `Ai_Range` for Copy range / AI chip
  ([ranges](ai-tasks.md#assets-of-a-message)). Stop retains `Session.replay` for `play.history` /
  `play.seek` (`play_review`). `play_input_update` discards paused per-tick input. `play.record`
  clears prior output, steps `1/fps` (`Run.frame_dt`) into `host.World_Recording`, and manually
  mixes audio (`dummy` driver headless). View options: Output frame (game camera only) and
  `game_detail` (`Session.paused_view` LODs while paused).
- **Play from a place:** `Layout.run_kind` remembers Play/Simulate/Play from camera.
  `Session.play_asked` (Play from here/camera, `play.start` `from`) feeds `scene.Play_Origin`
  (`asked` or camera fallback;
  [spawn points](../../mirai-gameplay/references/control.md#spawn-points)).

```sh
mirai rpc play.start '{"from":"Camera"}'
mirai rpc play.seek '{"to":"15"}'
mirai rpc play.history '{"verify":true}'
mirai rpc play.pause '{"paused":false,"here":true}'
```

## Watching another run

`Watch` mode (`watch_start(s, task)`) views a turn's run without stopping any run. `watch_stop`,
Stop, Esc, F5, or the bar chip restore prior mode, camera, and `edit_selection`.

- User Play keeps running unseen without input (`watch.from`; returns to Edit if it ended).
- Read-only: [edit procedures](document.md#world-edit-procedures), gizmo, tools, Details, and
  mutating commands are disabled; camera, selection, Hierarchy, and API document edits work.
- `watch_update` exits with a toast when the run ends; document change or user `play_start` stops
  watching.

## Networked Play

Provided by `multiplayer` via `Play_Provider`
([extensions](extensions.md#a-plugins-game-and-player-processes),
[multiplayer](../../mirai-networking/references/multiplayer.md#networked-play)). `play.start` with
`online` fails naming `multiplayer` if absent.

- **Local players:** `Run_Players.count` (`Play_Players`) overrides scene count
  ([seats](../../mirai-gameplay/references/control.md#seats),
  [cameras](../../mirai-gameplay/references/control.md#cameras)).
- **Player processes (`editor/player_processes.odin`):** spawns `mirai-player --attached` sharing
  the editor's loaded library (no recompile;
  [project libraries](../../mirai-core/references/host.md#project-libraries)), scene copies in
  `.mirai/play/` (`play_copy_file`). Tiles via `app.player_tiles` + `--surface`
  (`gpu.texture_add_shared`) or `--window` fallback
  ([host](../../mirai-core/references/host.md#the-player)); process-only uses `app.ui_only`. Click
  focuses stdin forwarding; F1 releases; Esc stops; `player_processes_poll` logs output/exit.
- **Turn & collab:** `Play_Provider.turn` creates in-process `Run.player >= 1` runs stepped
  together by `play.step`. Collab shares `Play_Provider.offer`, `host_menu`, and scene copy
  ([collaboration](collaboration.md#the-hosts-networked-games)).

## Simulate

`play.start` with `simulate:true` runs a full local copy with neutral input (screen UI and camera
views discarded; world panels kept). `Simulation_Paused` supports `play.step`; Stop discards copy
(does not revert external files/services).

- With `physics` (`Simulation_Provider`), move/rotate gizmos drive bodies kinematically (restoring
  type without residual velocity on release; Esc reverts gesture; resizing asks to stop; compound
  colliders select owner; characters keep controller).
- **Apply transforms:** captures existing selected poses between frames, stops Simulate, and writes
  local transforms in one undo (distinct IDs, finite poses; drops runtime entities/velocities).
- **Limited settle:** drops selected entities on a copy with other bodies frozen until rest or tick
  cap: `simulate_until_rest` (`physics.settle`, Drop to rest) or per-frame `settle_begin`..
  `settle_write` inside a [cancelable preview](extensions.md#cancelable-previews). See
  [extensions](extensions.md#simulation-and-pose-confirmation) and
  [API](../../mirai-agent-api/references/methods.md#simulation).

## Camera preview

`editor/camera_preview.odin`. Runs like Simulate without player input through a document camera
(`camera_preview_frame` seat override; no grid, disks, gizmo, outlines, or gestures). Bottom bar
switches document cameras with transitions; Details edits copy without undo; Keep (`camera_keep`)
commits changed lens/`Camera_Follow`/`Camera_Activation` in one step; Discard (`camera_discard`)
or Stop reverts.

## Figures of whoever works

`editor/presence.odin`. Shared transient visual instance (`host.extras_instance_add`,
`PRESENCE_OWNER`, no entity) for [agents](ai-tasks.md#agents-in-scene-and-review) and
[collaborators](collaboration.md#what-travels).

- Dog mesh (`editor/assets/presence`), yaw-only facing -Z. Fur, dark lenses, and neutral parts keep
  materials; harness, stripe, screen, and stars tint with figure color (stars also emission).
  `AGENT_COLORS`, `AGENT_LEVEL`, `AI_CONTEXT_LEVEL`; overhead glyph/name. Click/right-click opens
  chat or `presence_menu.odin` (Go to, Follow, Join game, Open chat, Watch).
- Moves via `presence_follow` / `PRESENCE_SNAP`; agents route around colliders via
  `core.World_Query` (`presence_route`); collaborators follow camera. Rebuilds only on
  `Presence_Key` change (0 allocs at rest). Hidden in Play/Paused/Watch (`presence_in_scene`),
  shown in Simulate.
- **Editor assets:** `editor/assets` mounts at `.editor` (`EDITOR_ASSETS_PREFIX`), hidden from
  listings (`asset.registry_listed`), not hot-reloaded. Uncommitted source `pup.glb` (0.9 m,
  +Z->-Z, primitives 0-5 fur/harness/stripe/screen/lenses/stars) imports via
  `mirai import --root editor/assets`.

### Pings

Middle-click without dragging marks hit point (or ground/camera target) for `PING_SECONDS`,
broadcasts to collab peers, and replaces the sender's prior ping.

## Between frames

`requests_run` drains `Session.requests` in fixed order (and after non-manual API actions). New and
Open stop runs before replacing worlds; scene replacement confirms (`confirm_resolve`) when agents
work or collab is active (API skips confirm).

## Build and reload

Explicit (`Ctrl+B`, `build.start`, `cook/build` `Editor` target); `target:"built"` loads external
engine/project builds in place.

- **Auto-build on Play:** compiles first if `game/`, `editor/`, `plugins/`, or manifest changed
  (`code_fingerprint` vs `Build_State.sources`, `Build_State.play`); shaders publish separately.
  Failed builds keep editor running and show diagnostics.
- **`library_reload` (`editor/reload.odin`):** runs when idle, compares `core.world_layout_hash`
  (loaded libraries stay until exit):
  - **Same layout:** swaps `Session.info` in place; worlds, history, and Play continue.
  - **Different layout:** stops networked Play/Watch/collab/previews, confirms open gesture,
    migrates worlds (`host.app_worlds_migrate`, `core.place_migrate`) and histories/records/sections
    (`editor/relayout.odin`); ACP workers keep running.
  - **Restart (`restart`):** only when engine library ABI/storage layout changes or a struct exceeds
    reserve. Stops Play, flushes tabs (`document_flush`), writes `restart-documents.json`, spawns
    `mirai-editor --project ... --documents ...`; deletes snapshot on full restore. Histories and
    collab reset.

### GPU that stops working

`editor/gpu_failure.odin`. On `host.app_gpu_failure`, restarts with `--gpu-lost <text>` (work stays
in files). Failing again within `GPU_FAILURE_AGAIN_NS` exits `EDITOR_GPU_LOST`. Test with
`engine.gpu_lose`.

## Commands and shortcuts

`editor/commands.odin`. API methods are the sole command catalog (`Binding` via `command_bind`,
`command_run`, `command_call`, queued between frames). Commands run during an open user gesture
merge into that undo step (`command_join`, `api_edit_begin`).

- **Context tokens (`binding_params`):** `$selection`, `$roots`, `$copied`, `$active`, `$shown`,
  `$document`, `$card`. Methods never inspect who called them.
- **View-only / confirmation actions** (dialogs, tabs, selection, camera, New/Open/Import/Quit) use
  `Binding.view` without an API method.
- **Single availability source (`binding_state`):** checks active library generation, target
  (`scene`, `document`, `card`), `modes`, context presence, `Api_Method.can` (`-32001`,
  `engine.describe` `unavailable`), `tool`/`preference`, and `Binding.state`. Exposed in
  `editor.inspect`.
- **Shortcuts:** `Ctrl`=`Cmd` on macOS; keys may be shared when mutually exclusive (F5 Play/Stop,
  F6 Pause/Resume); blocked during text edit, popups, modals, or tool capture; only `in_game` runs
  during Play; Esc deselects last. Copy stores root IDs (`Session.copied`); Paste duplicates living
  ones (`"$shown"` in game, disabled in Watch).

```odin
editor.command_bind(s, {
    name = "profiler.toggle", label = "Profiler", menu = .View,
    group = editor.MENU_GROUP_PLUGINS, view = profiler_toggle, state = profiler_state,
})
```
