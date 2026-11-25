# Server, protocol and CLI

Code: `editor/api/` (`api`), `editor/api_server.odin`, `editor/api_*.odin`, plugin `editor/`
parts, and `tools/mirai/rpc.odin`, `mcp.odin`, `session.odin`, `capture.odin`.

## The server

- Listens on `127.0.0.1:api.DEFAULT_PORT` (`--api-port N`, `--no-api`). Busy default picks a free
  port; busy explicit port disables API. `--api-port 0` (used by `mirai session start`) always
  picks an ephemeral port so tools only reach sessions via `api.json`. Exceeding
  `API_METHOD_CAPACITY` disables API.
- Writes `<project>/.mirai/api.json` (`api.Port_File`) on open, deletes on close.
- Accepts only `POST /rpc` (JSON-RPC 2.0) and `POST /mcp` with `Content-Type: application/json`,
  `Content-Length`, loopback `Host`, and no `Origin`. HTTP rejections return a JSON-RPC error.
- Preallocated buffers (`api.Server_Desc`): response overflow -> `-32000`, temp OOM -> `-32603`.
  No `id` = 202 notification; empty batch -> `-32600`. `API_VERSION` (`editor/api_server.odin`)
  bumps on incompatible changes.
- Polled **once per frame** on main thread. Manual headless (`--headless` without `--frames`)
  waits on sockets (`api.server_wait`) and runs `api_jobs`/`ai_poll` between frames.

## AI turn context

- `X-Mirai-Ai-Task` (`<conversation-id>-<sequence>` or `agent-<serial>`) resolves to
  `Call.client_tag` and clears after each call (HTTP 400 if empty, oversized for
  `api.Conn.client_tag`, non-printable/spaced, or conflicting duplicate).
- Editor sets `MIRAI_AI_TASK` + `MIRAI_API_PORT` (`api.*_VARIABLE`); `mirai rpc`/`mcp`/`texts`
  forward the task only to that port.
- Turn must be Running on the active document (else `-32000`). After `finish`, reads succeed and
  writes fail. `finish` and `agent.spawn` (`Method_Flag.Turn`) are listed only when tagged
  (`agent.spawn` requires main chat). Turns cannot call `engine.shutdown`, `scene.open`,
  `scene.new`. Tagged writes close user gestures and attribute new transactions to the turn
  ([change review](../../mirai-editor/references/ai-review.md)).
- `X-Mirai-Client` -> `Call.client_name` (`< api.CLIENT_NAME_BYTES`, omitted when tagged):
  `--client` > `MIRAI_CLIENT` > `CLAUDECODE=1` (`claude-code`); `mirai mcp` takes `clientInfo.name`
  ([external agents](../../mirai-editor/references/ai-tasks.md#agents-outside-the-editor)).

## Sessions

`mirai session start|restart|stop|status|sync [project]` manages a detached headless manual editor
([`subprocess.detached`](../../mirai-std/references/subprocess.md)) via `.mirai/session.json`,
`api.json`, and `.mirai/session.log`.

- `start` builds (unless `--no-build`) and waits up to `--timeout`, counted again each time the
  `mirai: compiling shaders N/M` the editor logs on a cold driver cache rises (shown on stderr
  every 10 s); a stall names the count and asks for a larger `--timeout`. Live headless sessions are
  reused (warns if binaries/library are stale); windowed editors are never reused/closed (fails
  with pid); unresponsive headless needs `stop --force`. `restart` keeps prior mode/args.
- **Open-session builds**: `build.engine_unlock` retires running binaries to
  `.mirai/engine/<mode>/retired/`. `mirai build editor` invokes `build.start` target `built`
  (hot-swaps compatible libraries/shaders or restarts preserving docs; `Session.program` tracks
  launch stamp; [binaries](../../mirai-projects/references/projects.md#engine-binaries)). `mirai
  build engine` only lists running sessions.
- `stop` quits cleanly and deletes `--copy` copies (use `start --copy` for throwaway edits;
  [AGENTS.md](../../../../AGENTS.md#verification)). Sessions hold GPU turns
  ([turns](../../mirai-projects/references/build.md#turns-between-processes)) and self-exit after
  `api.SESSION_IDLE`.
- **Orphans**: `status` lists unowned `.mirai/engine/` editors; `stop --orphans [project]` kills
  headless orphans, closes the sessions whose owner ended (`Session_Record.owner`: the nearest
  ancestor of `session start` that is no shell or launcher, as the agent) and removes dead
  `--copy` dirs (guarded by `SESSION_COPY_LOCK`). It is what an agent runs instead of killing.

## `mirai capture`

`mirai capture [project]` (`CAPTURE_USAGE`; default `.mirai/captures`) reuses or opens+closes a
session, loads scene, sets camera, runs `capture` (`of:"Scene"`), reads `engine.diagnostics`, and
prints JSON (`validation`, `console`, `stats`, `diff` via [`mirai image`](image.md)). Exits 1 on
validation errors or SSIM < `--threshold`.

- Resets window clock (`seconds=0`) for determinism; `--repeat` reloads and compares against
  `REPEAT_SSIM`; `--view` sets/restores `editor.view_mode.list` (`collision` has no lines);
  `--frames 0` waits for texture streaming.
- **Named cameras (`captures.mirai`)**: `--camera NAME` uses view's scene/pose/plan size & frames.
  `--plan` captures all views (`--views`, `--references` default `bin/references`, `--write`,
  `--repeat`); exits 1 on validation error, missing ref, or SSIM below view `threshold`.

```sh
mirai capture demo --camera main_overview --reference demo/bin/references/main_overview.png
mirai capture demo --plan --views main_overview,church --repeat
```

## `mirai record`

`mirai record [project]` (`RECORD_USAGE`) borrows a session, loads `--scene`, starts/stops Play if
needed, calls `play.record`, prints result + validation, and exits 1 on validation errors.

## `mirai play test`

`mirai play test [project] [scenario...]` runs `play.scenario.run` for named
[scenarios](../../../../docs/game/testing/scenario.md) or all `tests/scenarios` (auto-building
editor if code changed). Exit: 0 pass, 1 fail, 2 cannot run.

## `mirai ui` and `mirai scene`

`mirai ui|scene read|write|check` (`UI_USAGE`, `SCENE_USAGE`) run `cook/author.command` via
`mirai-author` without an editor ([text sources](../../../../docs/game/assets/text-sources.md),
[`ui.inspect`/`ui.write`](../../mirai-plugins/references/ui-inspector.md#api),
[`scene.inspect`/`scene.write`](methods.md#scene)).

- **Single writer**: `scene write` runs `scene_apply` (`cook/author/scene_document.odin`,
  `cook/author/scene_file.odin`, `engine/scene.capture`) for byte parity with the editor. Writes
  are atomic, no-op when unchanged, assign path-derived ids to new assets, and propagate `.ui`
  `params` to dependent widgets.
- **Checks & library**: requires current project `editor` library (except `ui read`; stale exits 1
  naming `mirai build editor`). `ui check` validates `@(draw)` procs (node names checked at
  runtime via `gui.names`). `scene check` verifies lossless round-trip (tracked assets verified by
  `the_documents_of_the_tracked_assets_write_back_the_files_they_were_read_from`).
- **Scene doc**: `{"entities": [...]}` supports `preset`, `prefab` (`asset.scene_instantiate`,
  path/id alone or `{asset, root}`), overrides, and preserves unknown components.

```sh
mirai scene read demo/assets/control/control.scene --out /tmp/control.json
mirai scene write demo/assets/control/control.scene /tmp/control.json
mirai scene check demo && mirai ui check demo
```

## `mirai rpc`

```sh
mirai rpc camera.set position=[0,2,8] target=[0,1,0] --project demo
mirai rpc build.start --project demo
mirai rpc build.status --project demo --wait-until 'phase=Built' --select phase,ok
mirai rpc batch --project demo --file calls.json
```

- Params: `key=value` (JSON or string, dot-nested objects), JSON object, `-` (stdin), `--file F`.
- Port resolution: `--port` > `--project` (auto-starts headless session except
  `RPC_NEEDS_OPEN_EDITOR`) > `MIRAI_API_PORT` > enclosing project > `DEFAULT_PORT` outside
  projects. Crashed/hung editors are never auto-replaced (fails with pid + log tail).
- Waits while editor is alive and using CPU (`--timeout S` caps call/wait). Exit: 0 ok, 1 error
  (`{"error":{...}}` stderr), 2 usage. Client codes: `-32099` unreachable, `-32097` timeout,
  `-32096` closed/restarted, `-32095` hung (`api.CLIENT_HUNG_SECONDS`), `-32098` bad JSON-RPC,
  `-32601` unknown method.

### Fields and waits

Server reserved params (sent by `--select` and `--wait-until`):
- `_select` (`"a.b,c[0].d"`, negative indices, numeric array keys): returns only selected paths;
  missing paths appear in `note` (exit 0).
- `_wait_until` (`<field><op><value>`, ops `=`, `==`, `!=`, `<`, `<=`, `>`, `>=`) +
  `_wait_seconds` (max `api.WAIT_UNTIL_SECONDS`): read-only methods only (`-32602` on mutating or
  in batch); polls per connection without blocking other clients; cancelled via
  `notifications/cancelled` (`-32094`); survives `-32096` restarts; timeout returns `-32097` with
  `data:{field,value}`.

### `mirai rpc describe`

Calls `engine.describe`: no args -> core index + plugin list; plugin/`editor`/prefix -> area
summaries; method(s) -> flags, params (type/bounds/unit/default/required), example, result fields.
A name no method starts with -> the word search below.

- **No editor running:** with a project (`--project` or the current folder) and no open editor,
  the import program registers the methods over the project's library (built first if stale) and
  answers the same (`editor.describe_command`); nothing starts a session.
- **`--search <word>...`:** methods by what they do (`api.methods_doing`: the words of the query
  and those alike in names and summaries), then components, record types, named values, input
  actions and presets that say the words.
- **Unknown method** (RPC, MCP, `batch`): the message names the method that does what the name
  asks (`entity.create` -> `scene.write`) and `error.data.usage` carries its params with an
  example; bad params carry their own `usage` the same way.

## `mirai mcp`

`mirai mcp [--project P|--port N] [--timeout S] [--plugins A,B|*] [--client NAME]` bridges stdio
JSON lines (<= `MCP_MAX_LINE`) to `POST /mcp` (`X-Mirai-Plugins` selects plugin tools, `*` = all;
default = core + `call`).

- With `--project`, re-reads `api.json` per message; without an editor, answers `initialize`
  (`listChanged:true`), `docs`, and placeholder tool, auto-starting on first call and sending
  `notifications/tools/list_changed` when an editor appears. Without `--project`, retries every
  `BRIDGE_RETRY` s.
- `.mcp.json`: `bin/mirai mcp` in engine repo; `mirai mcp` in projects (`mirai setup path`).

### MCP over HTTP

`POST /mcp` implements [MCP](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
(`MCP_VERSIONS`, stateless).

- **Streaming & cancel**: `tools/call` with `_meta.progressToken` + `Accept: text/event-stream`
  streams `notifications/progress` then final answer. `notifications/cancelled` cancels waiting
  calls (`-32094`; aborts pending `play.start` while builds continue).
- **`initialize`**: `_meta` gives `engine_version`, `process_id`, `project`, `project_folder`.
- **`tools/list`**: `docs`, `Core` methods (dots -> `_`), `X-Mirai-Plugins` methods, and `call`
  (`tools/call` accepts unlisted tools too). `engine.describe` attaches `guides`
  (`api.server_guides_set`) and paginates (`nextCursor`). No `outputSchema`.
- **`tools/call`**: result as JSON text only (`isError:true` on error). `api.call_image` appends
  PNG (`capture`, `view.viewport`) or falls back to path. Malformed JSON -> `-32603`, overflow ->
  `-32000`.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
  "name":"call",
  "arguments":{"method":"scene.inspect","params":{"limit":5,"_select":"path,entities[0].id"}}
}}
```

## Method conventions

Plugins register via [API providers](../../mirai-editor/references/extensions.md#api-methods)
(rebuilt on reload without dropping sockets).

- **Entities & assets**: entity params (`Api_Entity_Text`, `x-entity`, `api_call_entity`) accept
  name, `Parent/Child`, id, or Play handle; ambiguous names error with candidates; results return
  `0x` + 16 hex digits. Asset fields accept relative path (with/without ext) or 32-hex id; results
  return ids.
- **Coercion & matching**: `api.params_shape` normalizes singular/plural keys, scalar <-> 1-item
  array, number/bool -> string. `base.name_find` fuzzy-matches components/enums/keys/presets
  (unique match only; API input only, binary assets exact).
- **Struct schema**: fields are required unless tagged `optional` (defaults/zero; empty optional
  result fields omitted). Supports `text`, `[]T`, `serial.Json`, `min`/`max`, `label`, `unit`
  (`x-unit`), `clamp` (marks `_clamped`), `trim`. Unknown keys/bad types return `-32602` with
  `serial.text_error_message`, `data.usage`, and `data.unknown_field`.
- **Values & flags**: enums by name, bitsets as name arrays, non-finite floats as
  `"nan"`/`"inf"`/`"bits:0x…"`, local transforms (`rotation_deg`, meters, scale; `world_position`
  read-only), no `transient` fields. `Call.raw` carries normalized JSON; `writes_result` for
  manual writers. Wrong editor mode -> `-32001` with `data.fix`. Flags live in `api.Method_Flag`.

## Concurrency, transactions and undo

- No revision tokens: field-level (or whole-file for `*.set`, `animation.modifier.set`,
  `skeleton.*`, `material.program.edit`) last-writer-wins.
- Before edits, server cancels active gizmos and closes user gestures
  ([document](../../mirai-editor/references/document.md#edits-and-undo)). Every edit is an atomic
  transaction (`edits_begin`/`edits_commit`/`edits_cancel`) creating 1 named per-author undo step
  (`history.*`, [undo per author](../../mirai-editor/references/document.md#undo-by-author);
  `ai.revert`/`ai.review.accept`/`ai.retry`:
  [review](../../mirai-editor/references/ai-review.md)).
- During Play/Simulate, edits target the document/assets (written on stop); viewport tools and
  `physics.settle` wait for Edit; `simulation.apply` commits transforms in one undo
  ([methods](methods.md#simulation)).
