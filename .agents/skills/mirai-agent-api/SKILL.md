---
name: mirai-agent-api
description: Mirai editor agent API - JSON-RPC and MCP on 127.0.0.1 (`editor/api`,
  `editor/api_*.odin`), the `mirai rpc` and `mirai mcp` commands and the method catalog. Use when
  driving an open editor from an agent or a script, when adding or changing a method or when
  investigating a protocol error.
---

# Mirai agent API

An open editor serves JSON-RPC 2.0 (`POST /rpc`) and MCP (`POST /mcp`) with the same methods, by
default on `127.0.0.1:7940`. Each scene change through the API is an ordinary undo step. **The
live source of the schemas is `engine.describe`** of the open editor: each method declares its
params and its result with the label of each field, and its `summary` says what it is for. On any
difference with the catalog, it rules.

## Map

- Connecting a client, limits, errors, MCP: [protocol and CLI](references/api.md).
- Calling from the terminal: [`mirai rpc`](references/api.md#mirai-rpc) (also `--batch`) and
  [`mirai mcp`](references/api.md#mirai-mcp); reading only some fields or waiting for a state
  without `sleep` loops: [`--select` and `--wait-until`](references/api.md#fields-and-waits); the
  params and result of a method, with an example, and the methods of a plugin:
  [`mirai rpc describe`](references/api.md#mirai-rpc-describe); the MCP tools of a plugin:
  [`--plugins`](references/api.md#mirai-mcp).
- Headless editor in the background and port file `.mirai/api.json`:
  [sessions](references/api.md#sessions).
- Recording a game sequence at fixed fps (16-bit PNG or EXR, and WAV), reviewing it in one
  contact sheet with a manifest of its frames, and going back to a Play tick:
  [`play.record`, `play.seek`](references/methods.md#play) and
  [`mirai record`](references/api.md#mirai-record).
- Checking a motion in one or two calls (an input timeline, a table of values per tick, one
  image of cells around an entity): [`play.step`](references/methods.md#play) and [`capture`](references/methods.md#editor-and-viewport).
- Testing a game as a person plays it (a click, a double click, a hold of some seconds, a look)
  and asserting on what the camera shows: [testing like a player](#testing-like-a-player).
- Letting a cheap model play with few tokens, finding bugs with monitors or a bot with no model,
  and a repro of a run as a scenario: `play.observe`, `play.qa.*` and `play.explore` in
  [Play](references/methods.md#play).
- Writing a gameplay test once as a file and playing it again after every change, from the API
  or from CI: [scenarios](references/methods.md#scenarios),
  [`mirai play test`](references/api.md#mirai-play-test).
- Values of entities at past ticks without changing the game, and whether replaying the past
  repeats it (first tick and field that differ): [`play.history`](references/methods.md#play).
- Capturing the world without UI and comparing it with a reference:
  [`mirai capture`](references/api.md#mirai-capture); measuring PNGs, cropping them, enlarging
  them or reading their pixels: [`mirai image`](references/image.md).
- Console text, validation and build errors, and the problems of each world (which entity failed,
  why and how to fix it) after a failure:
  [`engine.diagnostics`](references/methods.md#server-and-execution).
- What a method does and what its schema does not say: [catalog](references/methods.md).
  The animation ones are in `mirai-animation`
  ([animation-api.md](../mirai-animation/references/animation-api.md)); the AI ones, in
  `mirai-editor` ([ai-tasks.md](../mirai-editor/references/ai-tasks.md#api-methods)).
- Concurrency, transactions and undo:
  [protocol](references/api.md#concurrency-transactions-and-undo).
- AI turns and their header: [context](references/api.md#ai-turn-context) and
  [change review](../mirai-editor/references/ai-review.md).
- Methods of a plugin:
  [providers](../mirai-editor/references/extensions.md#api-methods).
- Profiling an open editor, and where the seconds of a load or a Play start went:
  [profiling](references/methods.md#profiling).
- Opening the editor and its arguments: [editor](../mirai-editor/references/editor.md#arguments).
- Detecting regressions in how well a cold agent uses the API (the tasks of `tests/agent_tasks/`,
  a table per task and model): [`scripts/agent_tasks.py`](../../../scripts/agent_tasks.py).

## Workflow

### Driving an open editor

1. Open it with `mirai edit` (window or manual mode and port per
   [arguments](../mirai-editor/references/editor.md#arguments)) or, without a window and in the
   background, with `mirai session start [project] --dev`, on a free port that is never 7940
   unless `--api-port` names one; `mirai rpc --project <project>` finds the port and starts that
   session when the project has none. If the user's
   windowed editor holds the project, `--copy` opens a session on a fresh copy under its
   `.mirai/tmp/`, whose path it prints; `mirai session stop <copy>` deletes it, and the next
   `--copy` (or `stop --orphans <project>`) deletes the copies a killed run left behind.
2. `mirai rpc describe` lists the methods by plugin and says which plugins exist and which the
   project uses; `mirai rpc describe <plugin>` gives those of an area. Before calling a method for
   the first time, `mirai rpc describe <method|prefix>` (several methods at once:
   `mirai rpc describe a b c`): names, params or result fields are not
   guessed. Read: `scene.inspect` (ids and values), `component.list` (components, fields, ranges
   and initial values), `asset.list`; a single field with `--select` (`_select` in a call of MCP),
   and a state that takes time (`play.network.status`) with `--wait-until` (`_wait_until`).
3. Edit: each edit touches only the fields it names. Edits that succeed or fail together go in
   `scene.batch`. Building or rewriting a group of entities: `scene.write` with a nested document,
   the one `scene.inspect` with `root` gives.
4. Verify with `scene.inspect` or `capture`; undo with `history.undo`. A method that fails
   changes nothing.
5. Debugging a game: `play.history` with `trace` reads what happened at past ticks, `verify`
   finds nondeterminism, and `play.seek` rewinds the run there to step it again.
6. After changing code of the project (its `game/`, `editor/` or `plugins/`), `build.start` (or
   `play.start`, which builds first) compiles it, answers when it ends with its errors and loads
   it into the running editor: the scene,
   the Play and the history stay, also with a new or changed component
   ([build](references/methods.md#build)). A large scene is not loaded again for each change.
   `mirai session restart [project]` is only for engine code: it builds and opens another
   session with the same arguments, and `mirai build editor` also restarts it if it has to
   replace the engine binaries it runs ([sessions](references/api.md#sessions)).
7. Close with `engine.shutdown` (`discard` to discard unsaved changes) or with
   `mirai session stop`.

### Testing like a player

A person's input has timing and a person looks at the screen; a check that sets actions and reads
positions misses both.

1. Give devices, not actions, when the test is about how input plays: `segments` of `play.input`
   or `play.step` go through the path of real input, so taps, holds, double-press windows and
   thresholds of the actions see them. Each press has its own length: one tick and three ticks are
   different inputs.
   - A click: `[{"ticks": 3, "mouse_buttons": ["Left"]}, {"ticks": 1}]`.
   - A double click: two presses with a gap inside the game's window,
     `[{"ticks": 3, "mouse_buttons": ["Left"]}, {"ticks": 5}, {"ticks": 3, "mouse_buttons":
     ["Left"]}, {"ticks": 1}]`.
   - A hold: `[{"seconds": 0.8, "keys": ["E"]}, {"ticks": 1}]`; a press shorter than a tick:
     `tap_keys`; a chord: the keys in one segment, or the modifier one segment earlier.
   - A look or a turn of the stick: `mouse_delta` (spread over its segment) or `gamepads` with a
     stick, in a segment as long as the motion.
2. Schedule them with `play.input` and step a few ticks at a time with `play.step` without input,
   reading `play.view` (or `capture`) between steps; or in one call, `play.step` with the
   `segments` and a `trace` with `view` that reads every tick.
3. Assert what a person checks: that the game did it (`play.check` on its components) and what is
   seen, with `view` conditions on `follow.distance`, `blend.weight` or `points.0.normalized` and
   `points.0.on_screen`; `until` with them waits for the moment. Look at one image at the moments
   that matter: values can pass while the picture is wrong.
4. Once the sequence passes, write it as a [scenario](references/methods.md#scenarios) in
   `tests/scenarios/` instead of a script: the same steps and params, played again with
   `play.scenario.run` or `mirai play test` after each change. A scenario holds one behavior;
   another setup is another file, not a script that runs part of another.

### Checking an image

1. `mirai capture [project] --out x.png` with the scene and the camera; without `--reference` it
   measures the image (`stats`).
2. If it exits with 1, read `validation_messages` and `console` of the JSON before repeating (or
   `engine.diagnostics`). If the image looks wrong, `textures_pending` above 0 is streaming that
   had not finished, and `instances_drawn` at 0 is a camera that sees nothing.
3. Against a reference: `--reference r.png --threshold 0.95` (SSIM); `mirai image diff
   --out diff.png` shows where it differs.

### Adding or changing a method

1. Register it with `api_register` in the editor or in a
   [plugin provider](../mirai-editor/references/extensions.md#api-methods), with flat structs
   for params and result ([conventions](references/api.md#method-conventions)). The `summary` is
   one sentence about what it is for; what each field is goes in its `label=`, without commas.
   A field that only bounds how much it answers takes the `clamp` tag.
2. If the handler writes the result by hand, declare its shape with `result=R` and
   `writes_result=true` (`list`, `any` and `key=` in the tags) and test what is written with
   `api.result_mismatch`; `params_schema` for params read by hand and `result_schema` written by
   hand only for what a struct does not describe.
3. Document it in the [catalog](references/methods.md) only with what the schema does not say.
4. A contract change (name, params, result, error code) updates its consumers in the same task:
   `editor/ai_context.odin` (instructions to the agent), plugins and this skill; an incompatible
   one raises `API_VERSION`.

## Invariants

- The caller names things as a person does: an entity by the text `entity` (name, path, id or
  handle) and an asset by its path. The engine resolves them and a name that fits several is an
  error, never the first match.
- What is written for the API is taken as it can only be meant, in one place, never per method
  ([conventions](references/api.md#method-conventions)); saved assets and binary data are read
  exactly.
- All handlers run in the main thread between frames, one at a time. One that advances frames
  (`engine.step`, `capture`, `editor.input`, `ai.task`, `play.step`, `profile.capture`) or waits
  for a job (`build.start`, `play.start`, `asset.import`) holds the server meanwhile; the editor
  goes on drawing, and a handler finishes what it asks of later frames before answering.
- What changes on disk is the editor's at the next call: assets are read again and shaders
  published, whoever wrote them (`assets_watch.odin`, `api_disk_sync`).
- A scene edit is a transaction: one undo step or none, the caller's. Beforehand, the user's
  pending gesture is recorded as their own step. `history.undo` undoes only the caller's steps.
- The caller does not pass revisions: a field edited by two authors keeps the last one's, and the
  user reverts it with the turn's change review or with undo; a replacement of a whole file, the
  same ([protocol](references/api.md#concurrency-transactions-and-undo)).
- Entities by `core.Id` (16 hexadecimal digits in a string); assets by `Asset_Id` (32).
- Methods and their schemas are server data; they are not duplicated by hand elsewhere.
- Each method belongs to the editor or to the plugin whose provider registers it. MCP lists only
  the editor core (the methods with the `Core` flag: the basics of a scene) and the `call` tool,
  which runs any other method by name; `X-Mirai-Plugins` adds those of those plugins (`*`: all
  methods), and `tools/call` calls any by name. Each listed tool costs its schema on every model
  turn: the editor chats do not send the header and ask for the rest with `call` and
  `engine.describe`.
- The server reserves its buffers on open; a request that does not fit fails, it does not make
  them grow.
- ACP workers are independent: `X-Mirai-Ai-Task` identifies the turn and only its successful
  transactions are recorded, never everything that changes while it is Running.
- Collision and animation are edited by project names, never by indices or bits:
  [collision](references/methods.md#collision) and
  [animation](../mirai-animation/references/animation-authoring.md#per-instance-control-and-preview).

## Verification

- `mirai check editor/api` and `mirai check editor`; `mirai test editor/api` covers server, HTTP,
  JSON-RPC, batches, limits, schemas, MCP and the CLI against test methods, not the editor's.
- What is written for the API as it can only be meant: `mirai test editor/api
  params_are_taken_in_the_singular_or_plural_and_as_a_value_or_a_list_of_one
  a_limit_past_its_maximum_takes_it_and_the_answer_says_so
  an_invalid_params_error_says_what_the_method_takes_and_only_it_does`; names of a registry:
  `mirai test std/base`, `mirai test std/serial
  a_reader_of_loose_names_takes_members_as_a_person_writes_them_and_no_other_does` and
  `mirai test editor a_name_of_a_component_or_a_key_resolves_as_it_is_written_or_says_the_nearest`.
- Declared results: `mirai test editor/api
  a_result_the_handler_writes_is_described_by_its_type
  the_description_of_the_methods_has_the_shape_it_declares`; those of an editor method, with
  `api_result_shape_expect` in its test (`ai_methods_write_the_results_they_declare`).
- Writers of a recording (EXR, 16-bit PNG, WAV): `mirai test cook/movie`; its contact sheet:
  `mirai test cook/image a_sheet_tiles_evenly_spaced_frames_in_order_each_with_its_number`; the
  held actions of its manifest: `mirai test engine/input
  a_held_action_reaches_its_seat_from_the_next_tick_whatever_its_bindings`; the Play history:
  `mirai test editor a_run_goes_to_any_frame_it_played_and_plays_on_from_there
  a_frame_changed_from_outside_its_input_while_it_plays_does_not_match_when_played_again
  an_edit_where_a_run_went_back_is_kept_as_a_keyframe_and_drops_the_frames_after_it
  a_paused_play_resumes_from_its_newest_frame_or_from_where_it_went_back
  what_the_mouse_does_while_a_play_is_paused_does_not_reach_it_when_it_resumes
  the_strip_plays_the_past_again_at_the_pace_of_the_clock_with_the_game_paused
  the_keyframes_of_a_history_fit_its_memory_and_span_its_time
  a_run_keeps_no_history_when_it_is_off_or_on_the_network
  the_history_reads_what_a_live_trace_read_and_a_rewound_run_steps_the_same_again
  verify_says_the_first_tick_and_field_where_playing_the_past_again_differs
  the_last_play_keeps_its_history_after_stop_until_the_next_play`, and the copy it keeps:
  `mirai test plugins/physics/runtime
  a_kept_copy_takes_what_the_simulation_uses_and_copies_back_to_the_same_steps`; the wide image
  before and after the tonemap, with GPU and validation:
  `a_recording_reads_its_frames_wide_before_and_after_the_tonemap`; `play.record`, live.
- The timeline, trace and filmstrip of a step: `mirai test editor
  a_step_holds_each_segment_for_its_ticks_in_order_with_its_edges_at_its_first
  a_trace_reads_a_row_before_the_first_tick_every_some_ticks_and_after_the_last
  a_filmstrip_cell_comes_before_the_first_tick_and_every_every_ticks_around_its_entity`;
  the input of a person and what the player sees: `mirai test editor
  play_input_schedules_the_devices_of_a_person_that_the_next_steps_play_tick_by_tick
  play_view_says_what_the_player_sees_and_where_things_show_on_the_screen`; scenarios:
  `mirai test editor
  a_scenario_plays_its_steps_in_order_from_the_first_tick_and_ends_at_the_first_that_fails
  a_scenario_step_holds_unless_its_check_fails_or_its_until_runs_out`, and a live run of
  `mirai play test demo`; and the grid of its
  cells, `mirai test cook/image
  a_sheet_of_given_columns_takes_regions_of_frames_black_outside_them`; the filmstrip with a GPU,
  live.
- What an agent plays with, the monitors and a repro replayed: `mirai test editor
  play_observe_says_in_one_small_answer_what_a_decision_needs
  the_monitors_report_a_violation_with_its_tick_place_and_severity
  a_repro_replays_the_inputs_of_a_run_and_fails_at_the_same_tick
  the_bot_explores_the_same_with_the_same_seed_and_a_quit_does_not_end_it
  the_bot_goes_toward_new_cells_and_presses_every_button_of_a_menu_once`; its filmstrip, live.
- `mirai image` and the measure of `mirai capture`: `mirai test cook/image`; `mirai capture`
  against a project with GPU and `mirai test tools/mirai` if the CLI changes.
- `mirai session`: `mirai test tools/mirai` covers options, the free API port, discarding copies
  of `.mirai/tmp/`, sweeping the copies whose editor ended and process roles
  (`tools/mirai/session_test.odin`); `restart`, the build with an open session and
  `stop --orphans` are tested with a real editor.
- `mirai rpc` (`--select`, `--wait-until`, `describe`): `mirai test tools/mirai` and
  `mirai test editor/api the_rpc_and_mcp_commands_drive_the_server`, which runs the tool against
  the test methods.
- The paths of `capture`: `mirai test editor
  capture_paths_take_git_bash_drives_and_are_relative_to_the_project
  a_capture_makes_its_folder_and_says_why_it_cannot_write`; its wait for textures: `mirai test
  host a_capture_goes_on_while_textures_are_pending_until_its_wait_runs_out`; what it counted, with
  GPU: `capture_without_ui_draws_the_world_alone_at_the_size_asked_for`.
- An editor method: the tests of its `editor/api_<topic>_test.odin` with
  `mirai test editor <test...>`; profiling, `editor/profile_test.odin` and the recorder in
  `std/base` and `std/jobs`, and for loads
  `mirai test engine/scene a_load_reports_its_phases_and_the_assets_that_finish_after_it`; a
  plugin method, those of its skill.
- `large_mcp_images_keep_the_complete_content_with_small_socket_buffers` (`editor/api`) shrinks
  the receiving socket buffer: run it when touching partial sends.
- Live: `mirai session start demo --dev` (`build.start` after changing project code,
  `mirai session restart demo` after changing engine code),
  repeat the change with `mirai rpc ... --project demo` checking `mirai rpc describe`,
  `scene.inspect`, `history.undo` and `capture`, and `mirai session stop demo`.
- Live AI attribution: two MCP sessions with different headers over the same entities;
  `ai.status.running` is an array; reverting one keeps the other; the header of a previous turn
  fails; after `finish` reading works and writing fails
  ([editor tests](../mirai-editor/SKILL.md#verification)).
- Profiling in an open editor: a capture of 60 frames or fewer with the frame limited
  (`allow_limited:true`).
