---
name: mirai-agent-api
description: Mirai editor agent API - JSON-RPC and MCP on 127.0.0.1 (`editor/api`,
  `editor/api_*.odin`), the `mirai rpc`, `mirai mcp`, `mirai capture` and `mirai image` commands
  (`cook/image`), the recordings of a game (`cook/movie`), scenarios and the method catalog. Use
  when driving an open editor from an agent or a script, testing a game as a player, capturing and
  comparing frames, adding or changing a method or investigating a protocol error.
---

# Mirai agent API

An open editor serves JSON-RPC 2.0 (`POST /rpc`) and MCP (`POST /mcp`) with the same methods, by
default on `127.0.0.1:7940`. Each scene change through the API is an ordinary undo step. **The
live source of the schemas is `engine.describe`** of the open editor: each method declares its
params and its result with the label of each field, and its `summary` says what it is for. On any
difference with the catalog, it rules.

## Map

- Connecting a client, limits, errors, MCP: [the server](references/api.md#the-server),
  [method conventions](references/api.md#method-conventions) and
  [MCP over HTTP](references/api.md#mcp-over-http).
- Calling from the terminal: [`mirai rpc`](references/api.md#mirai-rpc) (`mirai rpc batch --file`: many
  calls as one request, whose calls can name the results of earlier ones) and
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
  image of cells around an entity): [`play.step`](references/methods.md#play) and
  [`capture`](references/methods.md#editor-and-viewport).
- Walking the player to a place, with no bot, and turning the view at something: `play.step` with
  `drive` or `look_at` ([drive](../../../docs/game/testing/scenario.md#drive)).
- Writing or changing a `.ui` (one nested document by name: `ui.write asset=<path>
  document=@<file>
  save=true`, `ui.inspect` reads it back): [writing-ui](../../../docs/game/ui/writing-ui.md).
- Reading, checking or writing the documents of interfaces and scenes with no editor,
  from files of text:
  [`mirai ui` and `mirai scene`](references/api.md#mirai-ui-and-mirai-scene).
- Testing a game as a person plays it (a click, a double click, a hold of some seconds, a look)
  and asserting on what the camera shows: [testing like a player](#testing-like-a-player).
- Letting a cheap model play with few tokens, finding bugs with monitors or a bot with no model,
  and a repro of a run as a scenario: the `playtest` plugin, `play.observe`, `play.qa.*` and
  `play.explore` in [Play](references/methods.md#play).
- Writing a gameplay test once as a file and playing it again after every change, from the API
  or from CI: [scenarios](../../../docs/game/testing/scenario.md),
  [`mirai play test`](references/api.md#mirai-play-test).
- Values of entities at past ticks without changing the game, and whether replaying the past
  repeats it (first tick and field that differ): [`play.history`](references/methods.md#play).
- Capturing the world without UI and comparing it with a reference:
  [`mirai capture`](references/api.md#mirai-capture); measuring PNGs, cropping them, enlarging
  them or reading their pixels: [`mirai image`](references/image.md#comparing-images-mirai-image).
- Console text, validation and build errors, and the problems of each world (which entity failed,
  why and how to fix it) after a failure:
  [`engine.diagnostics`](references/methods.md#server-and-execution).
- What a method does and what its schema does not say, by area of the catalog:
  [server and execution](references/methods.md#server-and-execution),
  [editor and viewport](references/methods.md#editor-and-viewport),
  [collision](references/methods.md#collision), [cinematics](references/methods.md#cinematics),
  [ragdoll](references/methods.md#ragdoll), [interfaces](references/methods.md#interfaces),
  [painting and shapes](references/methods.md#painting-and-shapes),
  [profiling](references/methods.md#profiling), [history](references/methods.md#history),
  [scene](references/methods.md#scene), [spatial queries](references/methods.md#spatial-queries),
  [editor documents](references/methods.md#editor-documents), [Play](references/methods.md#play),
  [simulation](references/methods.md#simulation), [saves](references/methods.md#saves),
  [build](references/methods.md#build), [project](references/methods.md#project),
  [prefabs](references/methods.md#prefabs),
  [components and assets](references/methods.md#components-and-assets),
  [graphics and settings](references/methods.md#graphics-and-settings),
  [input](references/methods.md#input),
  [material programs](references/methods.md#material-programs),
  [collaboration](references/methods.md#collaboration),
  [project panels](references/methods.md#project-panels) and [AI](references/methods.md#ai).
  The animation ones are in `mirai-animation`
  ([animation-api.md](../mirai-animation/references/animation-api.md#animation-api-methods)); the
  AI ones, in `mirai-editor` ([ai-tasks.md](../mirai-editor/references/ai-tasks.md#api-methods)).
- Concurrency, transactions and undo:
  [protocol](references/api.md#concurrency-transactions-and-undo).
- AI turns and their header: [context](references/api.md#ai-turn-context) and
  [change sets](../mirai-editor/references/ai-review.md#change-sets) and
  [finish, revert and retry](../mirai-editor/references/ai-review.md#finish-revert-and-retry).
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
   background, with `mirai session start [project]`, on a free port that is never 7940
   unless `--api-port` names one; `mirai rpc --project <project>` (and `mirai mcp`) finds the port
   and starts that session when the project has none. If the user's
   windowed editor holds the project, `--copy` opens a session on a fresh copy under its
   `.mirai/tmp/`, whose path it prints; `mirai session stop <copy>` deletes it, and the next
   `--copy` (or `stop --orphans <project>`) deletes the copies a killed run left behind.
2. `mirai rpc describe` lists the methods by plugin and says which plugins exist and which the
   project uses; `mirai rpc describe <plugin>` gives those of an area. Before calling a method for
   the first time, `mirai rpc describe <method|prefix>` (several methods at once:
   `mirai rpc describe a b c`): names, params or result fields are not
   guessed. Read: `scene.inspect` (ids, names, places and the names of the components; the values
   with `components`), `component.list` (components, fields, ranges
   and initial values), `asset.list`; a single field with `--select` (`_select` in a call of MCP),
   and a state that takes time (`play.network.status`) with `--wait-until` (`_wait_until`).
3. Edit the entities with `scene.write`, its `entities` the `tree` `scene.inspect` with `root`
   gives: it names only what it adds or changes; with `replace` it declares all there is under
   `root`, and what it leaves out goes. Calls of several methods that succeed or fail together go in `batch` with
   `transaction`.
4. Verify with `scene.inspect` or `capture`; undo with `history.undo`. A method that fails
   changes nothing.
5. Debugging a game: `play.history` with `trace` reads what happened at past ticks, `verify`
   finds nondeterminism, and `play.seek` rewinds the run there to step it again.
6. After changing code of the project (its `game/`, `editor/` or `plugins/`), `build.start` (or
   `play.start`, which builds first) compiles it, answers when it ends with its errors and loads
   it into the running editor: the scene,
   the Play and the history stay, also with a new or changed component
   ([build](references/methods.md#build)). A large scene is not loaded again for each change.
   After engine code or an engine shader, `mirai build editor` hands the build to the session:
   in place when only bodies or shader code changed, otherwise restarting it with its documents
   and the reason ([sessions](references/api.md#sessions)). `mirai session restart [project]`
   opens another session with the same arguments.
7. Close with `engine.shutdown` (`discard` to discard unsaved changes) or with
   `mirai session stop`.

### Testing like a player

A person's input has timing and a person looks at the screen; a check that sets actions and reads
positions misses both.

1. Give devices, not actions, when the test is about how input plays: `segments` of `play.step`
   go through the path of real input, so taps, holds, double-press windows and thresholds of the
   actions see them. Each press has its own length: one tick and three ticks are different inputs.
   - A click: `[{"for": 3, "mouse_buttons": ["Left"]}, {"for": 1}]`; on a button of the
     UI, by its name: `{"press": "start"}` in `play.step`.
   - A double click: two presses with a gap inside the game's window,
     `[{"for": 3, "mouse_buttons": ["Left"]}, {"for": 5}, {"for": 3, "mouse_buttons":
     ["Left"]}, {"for": 1}]`.
   - A hold: `[{"for": "0.8s", "keys": ["E"]}, {"for": 1}]`; a press shorter than a tick:
     `tap_keys`; a chord: the keys in one segment, or the modifier one segment earlier.
   - A look or a turn of the stick: `mouse_delta` (spread over its segment) or `gamepads` with a
     stick, in a segment as long as the motion.
2. Step a few ticks at a time, reading `play.view` (or `capture`) between steps; or in one call,
   `play.step` with the `segments` and a `trace` with `view` that reads every tick.
3. Assert what a person checks: that the game did it (`play.check` on its components) and what is
   seen, with `view` conditions on `follow.distance`, `blend.weight` or `points.0.normalized` and
   `points.0.on_screen`; `until` with them waits for the moment. Look at one image at the moments
   that matter: values can pass while the picture is wrong.
4. Once the sequence passes, write it as a [scenario](../../../docs/game/testing/scenario.md) in
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
   [plugin provider](../mirai-editor/references/extensions.md#api-methods), with a struct for
   its params and one for its result ([conventions](references/api.md#method-conventions)): they
   are its only description. The `summary` is one sentence about what it is for; what each field
   is goes in its `label=`, the last option of its tag. A field that only bounds how much it
   answers takes the `clamp` tag; what the method does to the editor is in its `flags`.
2. The handler reads `call.params` and fills `call.result`; a list of any length is a slice it
   makes in `call.allocator`. A handler that still writes its JSON itself says
   `writes_result=true`, and its test checks what it wrote against the result type with
   `api.result_mismatch`.
3. Document it in the [catalog](references/methods.md) only with what the schema does not say.
4. A contract change (name, params, result, error code) updates its consumers in the same task:
   `editor/ai_context.odin` (instructions to the agent), plugins and this skill; an incompatible
   one raises `API_VERSION`.

## Invariants

- A method acts on the entity it is given: the selection is never a precondition of a method, and
  a method does not change the selection of the user unless changing it is what it is for.
- The caller names things as a person does: an entity by its name, a path, an id or a handle,
  in every param that takes one (`entity`, or its role: `parent`, `target`...), and an asset by its
  path. The engine resolves them and a name that fits several is an error, never the first match.
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
- Answers name entities by `core.Id`, or a live one by its handle (`0x` and 16 hexadecimal digits
  in a string), and assets by `Asset_Id` (32 digits).
- Methods and their schemas are server data; they are not duplicated by hand elsewhere. The
  schema of a method is derived from the structs of its params and its result: nothing writes a
  JSON Schema by hand.
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
  `mirai test <package> --list <file>` prints the tests of a file to pass to `mirai test`.
- What is written for the API as it can only be meant (params in the singular or plural, a limit
  past its maximum, the text of an invalid-params error, a param that names an entity, the form of
  an example): `editor/api/shape_test.odin`; names of a registry: `mirai test std/base`,
  `std/serial/text_test.odin` (a reader of loose names) and
  `editor/api_runtime_inspect_test.odin` (a name of a component or a key resolves as it is
  written or says the nearest).
- Declared params and results: `editor/api/schema_test.odin` (a method is described by its types
  alone, lists of any length and any JSON included; a result the handler writes is described by
  its type; the description of the methods has the shape it declares); those of an editor
  method, with `api_result_shape_expect` of `editor/api_result_shape_test.odin` in its test, as
  `editor/ai_api_test.odin` does.
- Writers of a recording (EXR, 16-bit PNG, WAV): `mirai test cook/movie`; its contact sheet and
  the grid of its cells: `cook/image/image_test.odin`; the held actions of its manifest:
  `engine/input/holds_test.odin`; the Play history (any frame a run played, edits where a run went
  back, memory and span of the keyframes, no history off or on the network, the strip, `verify`
  naming the first tick and field that differ): `editor/play_history_test.odin` and
  `editor/api_play_test.odin`; the copy a history keeps: `plugins/physics/runtime/copy_test.odin`;
  the wide image before and after the tonemap, with GPU and validation:
  `editor/api_play_record_test.odin`; `play.record`, live.
- The timeline, trace and filmstrip of a step, what fails with no game, `play.start` again after an
  edit, the edit API while a game plays, the input of a person, `drive` and what the player sees:
  `editor/api_play_test.odin` and `editor/api_play_view_test.odin`; scenarios:
  `editor/api_play_test.odin` and `editor/api_play_scenario_test.odin`, and a live run of
  `mirai play test demo`; the filmstrip with a GPU, live.
- What an agent plays with, the monitors, a repro replayed and the bot:
  `mirai test plugins/playtest/editor`; its filmstrip, live.
- `mirai image` and the measure of `mirai capture`: `mirai test cook/image`; `mirai capture`
  against a project with GPU and `mirai test tools/mirai` if the CLI changes.
- `mirai session`: `mirai test tools/mirai` covers options, the free API port, discarding copies
  of `.mirai/tmp/`, sweeping the copies whose editor ended and process roles
  (`tools/mirai/session_test.odin`); `restart`, the build with an open session and
  `stop --orphans` are tested with a real editor.
- `mirai rpc` (`--select`, `--wait-until`, `describe`): `mirai test tools/mirai` and
  `editor/api/cli_test.odin`, which runs the tool against the test methods.
- The paths of `capture`: `editor/api_capture_test.odin`; its wait for textures:
  `host/capture_test.odin`; what it counted, with GPU: `editor/api_viewport_test.odin`.
- An editor method: the tests of its `editor/api_<topic>_test.odin` with
  `mirai test editor <test...>`; profiling, `editor/profile_test.odin` and the recorder in
  `std/base` and `std/jobs`, and for loads `engine/scene/loading_test.odin`; a plugin method,
  those of its skill.
- `editor/api/mcp_test.odin` shrinks the receiving socket buffer for large images: run it when
  touching partial sends.
- Live: `mirai session start demo` (`build.start` after changing project code,
  `mirai session restart demo` after changing engine code),
  repeat the change with `mirai rpc ... --project demo` checking `mirai rpc describe`,
  `scene.inspect`, `history.undo` and `capture`, and `mirai session stop demo`.
- Live AI attribution: two MCP sessions with different headers over the same entities;
  `ai.status.running` is an array; reverting one keeps the other; the header of a previous turn
  fails; after `finish` reading works and writing fails
  ([editor tests](../mirai-editor/SKILL.md#verification)).
- Profiling in an open editor: a capture of 60 frames or fewer with the frame limited
  (`allow_limited:true`).
