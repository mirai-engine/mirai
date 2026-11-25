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
live source of schemas is `engine.describe`** of the open editor; on any difference with docs, it
rules.

## Map

- Copy-pasteable debugging, audit, animation, rendering, playtest and remote-session recipes:
  [debugging and verification cheatsheet](#debugging-and-verification-cheatsheet).
- Connecting a client, limits, errors, MCP: [the server](references/api.md#the-server),
  [method conventions](references/api.md#method-conventions) and
  [MCP over HTTP](references/api.md#mcp-over-http).
- Terminal calls (`mirai rpc`, `mirai rpc batch`, `--select`, `--wait-until`, `describe`,
  `mirai mcp --plugins`): [`mirai rpc`](references/api.md#mirai-rpc),
  [`--select` and `--wait-until`](references/api.md#fields-and-waits),
  [`mirai rpc describe`](references/api.md#mirai-rpc-describe) and
  [`mirai mcp`](references/api.md#mirai-mcp).
- Headless sessions & `.mirai/api.json`: [sessions](references/api.md#sessions).
- Recordings (`play.record`, `play.seek`, `mirai record`):
  [Play](references/methods.md#play) and [`mirai record`](references/api.md#mirai-record).
- Motion checks, input timelines, traces and filmstrips (`play.step`, `capture`):
  [Play](references/methods.md#play) and
  [editor and viewport](references/methods.md#editor-and-viewport).
- Botless navigation (`drive`, `look_at`): [drive](../../../docs/game/testing/scenario.md#drive).
- UI files (`ui.write`, `ui.inspect`) and offline CLI (`mirai ui`, `mirai scene`):
  [writing-ui](../../../docs/game/ui/writing-ui.md) and
  [`mirai ui` and `mirai scene`](references/api.md#mirai-ui-and-mirai-scene).
- Player-like testing, scenarios and assertions: [testing like a player](#testing-like-a-player),
  [scenarios](../../../docs/game/testing/scenario.md),
  [assertions](../../../docs/game/testing/scenario.md#conditions) and
  [`mirai play test`](references/api.md#mirai-play-test).
- Cheap playtester, QA monitors and bot (`playtest` plugin: `play.observe`, `play.qa.*`,
  `play.explore`): [Play](references/methods.md#play).
- Past-tick inspection & determinism (`play.history`): [Play](references/methods.md#play).
- Captures and image diff/crop/measure: [`mirai capture`](references/api.md#mirai-capture) and
  [`mirai image`](references/image.md#comparing-images-mirai-image).
- Diagnostics (`engine.diagnostics`), profiling (`profile.*`) and catalog by area:
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
  Animation methods:
  [animation-api.md](../mirai-animation/references/animation-api.md#animation-api-methods);
  AI methods: [ai-tasks.md](../mirai-editor/references/ai-tasks.md#api-methods).
- Concurrency, transactions, undo, AI turns and plugin providers:
  [protocol](references/api.md#concurrency-transactions-and-undo),
  [context](references/api.md#ai-turn-context),
  [change sets](../mirai-editor/references/ai-review.md#change-sets),
  [finish, revert and retry](../mirai-editor/references/ai-review.md#finish-revert-and-retry) and
  [providers](../mirai-editor/references/extensions.md#api-methods).
- Editor CLI arguments & agent task benchmarks:
  [editor](../mirai-editor/references/editor.md#arguments) and
  [`scripts/agent_tasks.py`](../../../scripts/agent_tasks.py).

## Debugging and verification cheatsheet

### 1. Preflight and live audit (1 call)

```bash
# CLI gate: headless Play + play.audit (+ optional --ticks, --explore, --copy)
mirai play audit . --ticks 60 --copy

# In an open session: static scene audit or live Play audit
mirai rpc --project . scene.audit '{"world":"Auto","blend_ratio_warn":0.35}'
mirai rpc --project . play.audit '{"ticks":60,"frame_ms_budget":16.7}'
```

Both return `{passed, flags: [{severity, area, code, entity, message, fix}], summary}`, including
missing programs, implausible scales and floating attachments. `play.audit` adds live UI/input,
NaN/stuck and frame budget checks and, with a GPU, a frame mostly clipped or crushed, an exposure
still adapting and an effect in view that draws no pixel. Codes and rules:
[audit gate](../../../docs/game/testing/explore-qa.md#audit-gate).

### 2. Animation verification in Play vs isolated preview

`animation.capture` renders an **isolated preview without physics or world collision**; to verify
real Play locomotion, skinning, ground contact and physics interaction, use `capture` filmstrips
with `debug` plus `animation.inspect` / `animation.history`:

```bash
# Real Play filmstrip with offscreen debug overlays (no ui:true needed)
mirai rpc --project . capture '{
  "path": ".mirai/tmp/loco_strip.png", "every": 6, "count": 8,
  "follow": "Player", "debug": ["skeleton", "bounds", "collision", "trajectory"],
  "segments": [{"for": 48, "keys": ["W"]}]
}' --select path,ticks

# Exact numerical pose, matching candidates, and multi-tick replay without captures
mirai rpc --project . animation.inspect '{"entity":"Player","parts":["Match","Pose"]}'
mirai rpc --project . animation.history '{"entity":"Player","from":0,"to":60,"every":5}'
mirai rpc --project . animation.analyze '{"asset":"anims/hero.anim","clip":"walk"}'
# Isolated clip/set preview only (no physics/world):
mirai rpc --project . animation.capture '{"entity":"Player","seconds":1.0,"frames":6}'
```

### 3. Per-entity visibility, culling, material and perf diagnosis

```bash
# Why is an entity invisible, culled, dark, or unskinned?
mirai rpc --project . render.inspect_entity '{"entity":"Player","world":"Game"}'
# -> {entity, name, has_mesh, mesh, visible, culled_reason, lod, aabb_min, aabb_max,
#     distance, textures_pending, materials, skinned, skin_updated}

# Console/validation/world problems + per-mesh/material draw cost + frame timings
mirai rpc --project . engine.diagnostics '{}' --select validation,problems
mirai rpc --project . profile.cost '{}' --select meshes,materials
mirai rpc --project . profile.capture '{"frames":30,"allow_limited":true}' --select summary
```

### 4. Cheap playtester and QA monitors

```bash
# Zero-token bot sweep + QA violation repros
mirai rpc --project . play.qa.start '{"frame_ms":33}'
mirai rpc --project . play.explore '{"mode":"World","seed":7,"for":"30s"}' \
  --select stopped,cells,passed,violations,repros
mirai rpc --project . play.qa.report '{"violation":0,"repro":true}' --select passed,repro

# Act + observe in 1 call (what .claude/agents/playtester.md runs over MCP or mirai rpc)
mirai rpc --project . play.observe \
  '{"step":{"for":20,"keys":["W"]},"targets":["Door*"],"nearest":3}'
```

Use `.claude/agents/playtester.md` (and `templates/common/.claude/agents/playtester.md`) when a
goal requires visual or gameplay judgment; it works over MCP or `mirai rpc`.

### 5. Remote Windows sessions (`eco`)

The Windows PC takes GPU captures, timings and Vulkan runs by default when it is reachable. `eco`
there runs Git Bash only, so recipes are POSIX shell like local ones; never PowerShell or
`cmd.exe` scripts, whose quoting and encoding mangle arguments. In Git Bash a Windows switch takes
a doubled slash (`cmd //c`), and POSIX paths in arguments convert
([paths](../mirai-projects/references/projects.md#paths-in-git-bash)).

```bash
# Client environment; ECO_HOME (~/.eco) keeps the PC's key for ECO_ADDR since pairing
export ECO_ADDR=192.168.1.40:8443 ECO_KEY=$HOME/.eco/client.key ECO_SOCKET=$HOME/.eco/run/pc.sock
# One program, no shell; several commands, one script whose arguments are $1, $2...
eco run -- git --version
eco run --sh --timeout-ms 600000 -- 'cd /c/Users/tzbk/CODIGOS/mirai && git status --short'
# Long work: a detached job that survives a dropped connection; every agent's jobs are listed
job=$(eco start --sh -- 'cd /c/Users/tzbk/CODIGOS/mirai/.worktrees/agents && ./mirai test render')
eco jobs
eco attach "$job"   # again with the stdout and stderr byte offsets to resume
# Files: the remote path is relative to the server root, C:/Users/tzbk/Documents, the only
# folder put and get reach: write there what comes back (capture --out /c/Users/tzbk/Documents/x)
eco put bin/fix.bundle fix.bundle    # lands in C:/Users/tzbk/Documents/fix.bundle
eco get captures/view.png bin/view.png
```

- **Socket.** One `ECO_SOCKET` per server and key, shared by every agent; the daemon starts on
  demand and exits after two minutes idle. A path under the scratchpad is too long for a socket.
  Leftover `~/.eco/run/*.sock.lock` files are harmless: the lock is an `flock` released when that
  daemon exits, so "client unavailable" is a live daemon, never a stale file, and no agent needs
  a socket of its own for that.
- **A branch on the PC.** Agents share one standing worktree with a warm dev build,
  `C:/Users/tzbk/CODIGOS/mirai/.worktrees/agents` (made once with `mirai worktree new agents`):
  bundle the commits the PC lacks, put the bundle, check out its commit there and build
  incrementally, never a new worktree and a cold build per agent. One agent holds it at a time:
  the coordinator assigns it, and `eco jobs` shows whether another agent's job runs there. Its
  GPU work queues with every worktree of that checkout in the
  [GPU turns](../mirai-projects/references/build.md#turns-between-processes).

```bash
git bundle create bin/fix.bundle HEAD ^origin/main && eco put bin/fix.bundle fix.bundle
eco run --sh --timeout-ms 900000 -- 'cd /c/Users/tzbk/CODIGOS/mirai/.worktrees/agents &&
  git fetch -q origin && git fetch -q /c/Users/tzbk/Documents/fix.bundle HEAD &&
  git checkout -q --detach FETCH_HEAD && ./mirai build editor demo'
```

- **Editor API.** Start a session there (it outlives the command and prints `{"port": N, ...}`),
  forward a free local port to `N` and call through it with the local `mirai`; `--project` names
  a local project, so remote calls take `--port`. The forward keeps the loopback-only API on
  loopback at both ends; the local port must not be one a local editor uses.

```bash
eco run --sh -- 'cd /c/Users/tzbk/CODIGOS/mirai/.worktrees/agents && ./mirai session start demo'
eco forward 127.0.0.1:17940 127.0.0.1:N &
mirai rpc --port 17940 engine.diagnostics '{}' --select problems
```

- A native crash shows as exit 127; the real code comes from
  `cmd //v:on //c "PROGRAM & echo !errorlevel!"`. End the session with `mirai session stop` there
  and a job only with `eco kill` of its own id.

## Workflow

### Driving an open editor

1. Open with `mirai edit` (window/manual) or headless with `mirai session start [project]` (free
   port, never 7940 unless `--api-port`). `mirai rpc --project <p>` and `mirai mcp` auto-start one.
   Use `--copy` when the user's editor holds the project (runs in `.mirai/tmp/`; `mirai session
   stop <copy>` deletes it; `stop --orphans` cleans killed runs and sessions whose agent ended).
2. Discover schemas with `mirai rpc describe [plugin|method...]` before calling a method for the
   first time. Read state with `scene.inspect`, `component.list`, `asset.list`; filter with
   `--select` (`_select` in MCP) and wait with `--wait-until` (`_wait_until`).
3. Edit entities with `scene.write` (partial patch by default; `replace:true` declares the full
   subtree under `root`). Group multi-method atomic edits in `batch` with `transaction:true`.
4. Verify with `scene.inspect`, `scene.audit`, `render.inspect_entity`, or `capture`; undo with
   `history.undo`. Failed calls change nothing.
5. Debug Play runs with `play.audit`, `play.history` (`trace`/`verify`), `play.events` (what a
   library reported, now or `from`/`to`) and `play.seek`.
6. After project Odin changes, `build.start` (or `play.start`) compiles and hot-reloads in place
   without losing scene, Play or history. After engine/shader edits, `mirai build editor` updates or
   restarts the open session; `mirai session restart [project]` restarts manually.
7. Close with `engine.shutdown` or `mirai session stop` (edits are already flushed to disk).

### Testing like a player

1. Send real device input via `play.step` `segments` so taps, holds, double-press windows and
   thresholds run through the real input path:
   - Click: `[{"for": 3, "mouse_buttons": ["Left"]}, {"for": 1}]`; UI button: `{"press": "start"}`.
   - Double click: two 3-tick presses separated by a 5-tick gap.
   - Hold: `[{"for": "0.8s", "keys": ["E"]}, {"for": 1}]`; short tap: `tap_keys`.
   - Camera look / stick turn: `mouse_delta` (spread across the segment) or `gamepads`.
2. Step with `play.view` / `capture`, or combine `segments` and `trace` (with `view`) in one call.
3. Assert both game state (`play.check`) and visibility (`view` conditions on `follow.distance`,
   `blend.weight`, `points.0.on_screen`), plus at least one real image at key moments.
4. Save passing checks as [scenarios](../../../docs/game/testing/scenario.md) under
   `tests/scenarios/` and run them with `play.scenario.run` or `mirai play test`.

### Checking an image

1. Run `mirai capture [project] --out x.png` (or `--camera NAME`); without `--reference` it prints
   image `stats`.
2. On exit 1, inspect `validation_messages`, `console` and `engine.diagnostics` before retrying.
   `textures_pending > 0` means unfinished streaming; `instances_drawn == 0` means an empty view
   (diagnose entities with `render.inspect_entity`).
3. Compare references with `--reference r.png --threshold 0.95` and `mirai image diff --out d.png`.

### Adding or changing a method

1. Register via `api_register` in `editor` or a
   [plugin provider](../mirai-editor/references/extensions.md#api-methods) with typed params/result
   structs ([conventions](references/api.md#method-conventions)). Put a one-sentence `summary`,
   field `label=` (last tag option), `clamp` on bounds, and `flags`.
2. Populate `call.result` using `call.allocator` for slices. Hand-written JSON requires
   `writes_result=true` and a test checking `api.result_mismatch`.
3. Add to [methods.md](references/methods.md) only what the schema does not say.
4. Update all consumers (`editor/ai_context.odin`, plugins, skills) in the same task; bump
   `API_VERSION` on incompatible changes.

## Invariants

- Methods act on the passed entity; selection is never an implicit precondition and is unchanged
  unless selection is the method's purpose.
- Entities accept name, path, id or live handle; assets accept path or id. Single-entity selectors
  require a unique match. Answers return `core.Id` (or `0x` + 16 hex handle for runtime entities)
  and 32-hex `Asset_Id`.
- Loose API input normalization lives in one shared layer, never per method; saved binary assets
  stay strict.
- Handlers run sequentially on the main thread between frames. Frame-stepping or job-waiting calls
  (`engine.step`, `capture`, `editor.input`, `ai.task`, `play.step`, `profile.capture`,
  `build.start`, `play.start`, `asset.import`) hold the server while the editor keeps rendering.
- Disk edits sync automatically before the next API call (`assets_watch.odin`, `api_disk_sync`).
- Each scene edit is one undo transaction attributed to its caller; `history.undo` only undoes the
  caller's steps. No revisions are passed: last writer wins; AI turns isolate attribution via
  `X-Mirai-Ai-Task`.
- Schemas are generated solely from Odin types (never hand-written JSON Schema). MCP exposes `Core`
  methods plus `call` (which invokes any method); `X-Mirai-Plugins` expands listed plugin schemas.
- Server request/response buffers are preallocated at open; oversized payloads fail rather than
  reallocate.
- Collision and animation are edited by project names, never raw indices or bitmasks.

## Verification

- `mirai check editor/api` and `mirai check editor`; `mirai test editor/api` covers server, HTTP,
  JSON-RPC, batches, limits, schemas, MCP and CLI.
- Input shaping & schema checks: `editor/api/shape_test.odin`, `editor/api/schema_test.odin`,
  `std/base`, `std/serial/text_test.odin`, `editor/api_runtime_inspect_test.odin`,
  `editor/api_result_shape_test.odin`, `editor/ai_api_test.odin`.
- Recordings & Play history: `mirai test cook/movie`, `cook/image/image_test.odin`,
  `engine/input/holds_test.odin`, `editor/play_history_test.odin`, `editor/api_play_test.odin`,
  `plugins/physics/runtime/copy_test.odin`, `editor/api_play_record_test.odin` (GPU+validation).
- Play steps, views, scenarios & playtest: `editor/api_play_test.odin`,
  `editor/api_play_view_test.odin`, `editor/api_play_scenario_test.odin`,
  `mirai test plugins/playtest/editor`, live `mirai play test demo` and `mirai play audit demo`.
- Captures, image CLI, sessions & rpc: `mirai test cook/image`, `mirai test tools/mirai`,
  `tools/mirai/session_test.odin`, `editor/api/cli_test.odin`, `editor/api_capture_test.odin`,
  `host/capture_test.odin`, `editor/api_viewport_test.odin` (GPU), `editor/api/mcp_test.odin`.
- Profiling & editor methods: `editor/api_<topic>_test.odin`, `editor/profile_test.odin`,
  `std/base`, `std/jobs`, `engine/scene/loading_test.odin`.
- Live check: `mirai session start --copy demo`, verify touched methods with `mirai rpc`,
  `scene.inspect`, `history.undo`, `capture` / `play.audit`, and `mirai session stop`.
- Live AI attribution: two MCP turns with distinct headers; `ai.status.running` is an array;
  reverting one keeps the other; finished turn stays readable and rejects writes
  ([editor tests](../mirai-editor/SKILL.md#verification)).
