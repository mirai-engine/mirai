# Server, protocol and CLI

Code: `editor/api/` (package `api`: server, JSON-RPC, MCP, schemas, client),
`editor/api_server.odin` (the editor's server and guards), the methods (`editor/api_*.odin` and the
`editor` part of plugins) and `tools/mirai/rpc.odin`, `mcp.odin`, `session.odin`, `capture.odin`.

## The server

- It listens on `127.0.0.1:api.DEFAULT_PORT`; `--api-port N` chooses another and `--no-api` does
  not open it. Without `--api-port`, a busy port makes it choose a free one, which the editor
  prints on stderr; with a busy `--api-port`, or another failure, it continues without an API and
  says so. `--api-port 0` takes a free one and never the default: every `mirai session start`
  passes it unless its arguments name a port or `--no-api`, so the default port stays that of
  the user's editor and a tool reaches a session only through its project's `api.json`. If a
  method does not fit in the registry it does not open the API and names `API_METHOD_CAPACITY`.
- When it opens it writes `<project>/.mirai/api.json` (`api.Port_File`) and deletes it on close:
  `rpc`, `mcp` and `capture` take the port from there, and `session` knows which binaries and
  library it runs.
- Only `POST /rpc` (JSON-RPC 2.0) and `POST /mcp`, with `Content-Type: application/json` and
  `Content-Length`, without `Origin` (a web page) and with a loopback `Host`; an HTTP rejection
  carries a JSON-RPC envelope with the error.
- Limits: those of `api.Server_Desc`, with the response that `api_server.odin` sets. Buffers are
  reserved on open and a request does not make them grow: a response that does not fit is
  `-32000` and a request without temporary memory, `-32603`. What the socket does not absorb goes
  out in the following polls.
- It is served **once per frame**, between frames, in the main thread; a **manual** editor
  (`--headless` without `--frames`) does not draw on its own and advances when a method asks. With
  no calls it waits on the API sockets (`api.server_wait`), not in a `sleep`: a request wakes it on
  arrival, without waiting for the Windows timer tick.
- A request without `id` is a notification (202 without a body); an empty batch is `-32600`.
  `API_VERSION` (`editor/api_server.odin`), the one in `serverInfo` and `engine.describe`, rises
  with an incompatible change of methods.

## AI turn context

- `X-Mirai-Ai-Task` identifies the AI turn: `<conversation-id>-<sequence>`, which Mirai sets in the
  MCP server of each ACP session, or `agent-<serial>`, the process of an agent, which stands for
  the turn that agent runs when the request arrives. The server delivers it as `Call.client_tag`
  (the turn's name once resolved) and clears it when the request ends, also in batches and
  notifications. HTTP 400: empty, not fitting in `api.Conn.client_tag`, with spaces or outside
  printable ASCII, or duplicated with another value.
- The agent never names its turn. Mirai starts each agent with `MIRAI_AI_TASK=agent-<serial>` and
  `MIRAI_API_PORT` (`api.*_VARIABLE`) and the commands it runs inherit them: `mirai rpc`, `mcp`
  and `texts` send that context to that port and to no other, and have no option to give another.
  The variable names the process and not the turn because a worker keeps its process between
  turns. A request of its own over HTTP without the header belongs to no turn.
- The turn must exist, still be Running and belong to the active document; one that is closed or
  replaced by another request of the same chat fails with `-32000`. After `finish`, reads continue
  until ACP completes the turn and a write fails. `finish` finishes the turn of its header and
  `agent.spawn` starts a subagent from it; both are listed only to a request that has one
  (`Method_Flag.Turn`), and `agent.spawn` fails unless the turn is the main chat's.
- A turn does not discard the user's unsaved work: `engine.shutdown`, `scene.load`,
  `editor.recover` with `discard` and closing a document with changes fail, asking it to ask.
- A tagged write closes the user's previous gesture and, if it succeeds, attributes to the turn
  only the new transactions of that request
  ([change review](../../mirai-editor/references/ai-review.md)); without the header, to no agent.
- `X-Mirai-Client` names an agent outside the editor (letters, digits, `.`, `_` and `-`, shorter
  than `api.CLIENT_NAME_BYTES`), delivered as `Call.client_name`; a tagged request does not send
  it. `mirai mcp` sends the `clientInfo.name` of the initialize of its client, lowercase; `mirai rpc`
  and `mcp` take `--client NAME` first, then `MIRAI_CLIENT`, and `claude-code` in a shell of Claude
  Code (`CLAUDECODE=1`). Its calls are the turn of its own chat in the editor
  ([outside the editor](../../mirai-editor/references/ai-tasks.md#agents-outside-the-editor)).

## Sessions

`mirai session start|restart|stop|status [project]` handles a headless (manual) editor in the
background, decoupled from whoever launches it and without a console
([`subprocess.detached`](../../mirai-std/references/subprocess.md)). The session is the editor
named by `.mirai/session.json` (pid, mode and arguments) and `api.json`; its log is
`.mirai/session.log`.

- `start` builds ([binaries](../../mirai-projects/references/projects.md#engine-binaries);
  `--no-build` does not) and waits for the API, or closes the editor after `--timeout`. `restart`
  closes the session and opens another with the mode and arguments of the last one, except those
  passed; if the build fails, it stays closed.
- With a live headless session, `start` and `capture` reuse it without building; if it runs
  binaries or a library older than the latest, they warn and continue with what it loaded until
  `restart`. An editor of the project with a window is not reused, trampled or closed (`start`,
  `restart` and `stop` fail with its pid); a headless one that does not respond is not trampled
  either: `stop --discard` closes it.
- **Build with an open session.** Windows does not replace loaded binaries, but it moves them: the
  build moves the ones a program runs to `.mirai/engine/<mode>/retired/` and writes in their place
  (`build.engine_unlock`), and a later build deletes them once nothing runs them. If `mirai build
  editor`, `edit`, `play` or `capture` rebuild the engine the project's session runs, they close it
  (with its players), build and reopen it on the new binaries; if the engine does not build, it
  stays closed. Every other program that runs them (another session, a person's editor) goes on
  with the binaries it started with and is named; it takes the new ones when it starts again. An
  editor whose engine was rebuilt restarts on the new one as soon as its next Build ends, a
  headless one too, between calls, instead of loading the library into the old one: it runs the
  program and reads the stamp of the folder it started from (`Session.program`), not where the
  system says its moved executable is, and the session record follows it to the new process, so
  the next call reaches it through the port file (`--wait` covers its start), its `build.status`
  says `Built`, and `mirai session` still knows it as the project's. `mirai build engine` does not restart sessions: it names them.
- `stop` never saves: unsaved changes (from `editor.documents` and `asset.unsaved`) are discarded
  automatically if all are copies under `.mirai/tmp/`; otherwise it fails listing them and
  `--discard` discards them.
- **Orphans**: editors that run from the checkout's `.mirai/engine/` and that the `api.json` of
  their project does not name. `status` (0 if the session responds) lists them and
  `stop --orphans [project]` closes the headless ones, never one with a window.
- **Orphan copies**: a run killed after `start --copy` leaves its copy. `start --copy` and
  `stop --orphans <project>` delete the project's copies that no start is making or opening
  (`SESSION_COPY_LOCK`, held from the copy's first file until its editor answers) and whose port
  file and record name no running process that opens them.

## `mirai capture`

`mirai capture [project] --out x.png` (options in `CAPTURE_USAGE`) uses the project's session or
opens one and closes it: it loads the scene, places the camera (`camera.set`), captures the world
without UI (`editor.capture` with `ui:false`), reads `engine.diagnostics` and measures the image.
It prints a JSON with the validation, the console, `stats` and, with `--reference`, `diff`
([`mirai image`](image.md)). It exits with 1 if there are validation errors or if the SSIM against
`--reference` is below `--threshold`. Each capture starts the window clock at zero (`seconds` of
`editor.capture`): a scene loaded again and captured again draws the same frames. `--repeat` loads
the scene again (that of `--scene` or the document's file, if it has no unsaved changes), returns
to the same camera, captures and gives its SSIM; what remains is what two renderers do not share
and, below `REPEAT_SSIM`, it warns that a higher threshold compares noise. `--view` shows a mode of
`editor.view_mode.list` and when done restores the one the session had; `collision` is not visible
because the capture carries no lines.

`mirai capture [project] --plan` captures each view of the project's `captures.mirai` (size,
frames and, per view, scene, camera and `threshold`) from its scene loaded again and compares it
with its reference from `--references` (the project's `bin/references`: images depend on the GPU
and are not versioned). `--write` makes the references with this build, `--repeat` captures each
one again and marks the threshold that sits above what repeats, and `--views` narrows. It exits
with 1 if a view brought validation errors, fell below its threshold or has no reference. Each
view's threshold is below the SSIM of its `--repeat`.

## `mirai record`

`mirai record [project]` (options in `RECORD_USAGE`) uses the project's session or opens one,
loads `--scene`, starts a Play if there is none and stops it when done, and calls `play.record`.
It prints its result with the editor's validation and exits with 1 if there are validation errors.

## `mirai play test`

`mirai play test [project] [scenario...]` plays [scenarios](methods.md#scenarios) in the project's
session or in one it opens and closes, one `play.scenario.run` per file: those named (a name of
`tests/scenarios`, or a path) or all of `tests/scenarios`. It prints a line per scenario and, for
one that fails, its failure and what the failing step answered; it exits with 0 when all pass, 1
when one fails and 2 when they cannot run. A session it opens builds the editor of the project
first when its code changed, as `mirai session start` does. A project runs it in its CI, on a
machine with a GPU.

## `mirai rpc`

```sh
mirai rpc <method> [json|-|--file F] [--select FIELDS] [--wait-until CONDITION [--every S]]
  [--project P] [--port N] [--timeout S] [--wait S]
mirai rpc describe [plugin|method|prefix|method...] [--project P|--port N]
mirai rpc --batch <calls.jsonl> [the same options]
```

- `json` is the params object (`{}` if missing; `-` from stdin). `--project P` takes the port from
  its `api.json`; without `--project` or `--port`, that of `MIRAI_API_PORT`, of the project of the
  current folder or the default one.
- `--wait S` retries while nobody is listening. `--timeout S` is the wait for the response or,
  with `--wait-until`, that of the whole wait: a method that advances many frames or a Build asks
  for it longer. A call to `MIRAI_API_PORT` sends `MIRAI_AI_TASK` ([context](#ai-turn-context)).
  `--batch` reads one `{"method","params"}` call per line and stops at the first error.
- Output: the result on stdout and code 0; an error, on stderr as `{"error":{...}}` and code 1;
  invalid arguments, `Usage:` and code 2. From the client: `-32099` with no editor listening,
  `-32097` with no response in time, `-32096` if it closed the connection without answering (it
  ended or restarted, maybe after running the call), `-32098` if the response is not JSON-RPC. `-32601` names the
  similar ones.

### Fields and waits

A field is a path in the result: names separated by dots and `[i]` for element `i` of an array,
from the end if `i` is negative (`entities[0].id`, `entities[-1]`).

- `--select a.b,c[0].d` prints those fields, one per line: a text without quotes, a number or
  `true`/`false`/`null` as is, and an object or array as JSON. A field that is not there is
  `-32602` with those that exist at that level and the whole result in `data.result`: the call was
  already made.
- `--wait-until '<field><op><value>'` repeats the call every `--every S` until it is met and
  prints that result. `op` is `=` (`==`), `!=`, `<`, `<=`, `>` or `>=`; the ordering ones need
  numbers. Numbers are compared as numbers (exact integers), a text by its content, with or
  without quotes, and the rest as JSON without spaces (`selection=[]`). An editor that does not
  respond or ends while it answers (`-32099`, `-32097`, `-32096`) keeps being waited for, because
  Build restarts it; another error, a
  field that is not there or a value that cannot be ordered end immediately. After `--timeout` it
  exits with `-32097`, the last value in the message and `data:{field,value}`. Example:
  `mirai rpc build.status --wait-until 'building=false' --timeout 600 --select phase,message`.

### `mirai rpc describe`

It reads `engine.describe`: with no argument, the methods grouped by plugin (`editor` first) with
their summary, and the plugins the project finds and does not use. With the name of a plugin (or
`editor`), the methods of that area; with a method, or with a prefix (`scene.` or `scene`), those
that start that way; with several methods, those (`methods` of `engine.describe`). For each, its flags and its summary, each param with its type (range, length,
unit, enum, id), `required` or its default value and its label, an example of valid params and
each field of the result with its type and its label. A name that lists none is `-32602` with the
similar ones.

## `mirai mcp`

`mirai mcp [--project P|--port N] [--timeout S] [--plugins A,B|*]` is an MCP server
over stdio: it forwards each JSON line (up to `MCP_MAX_LINE` bytes) to the `POST /mcp` of the
editor that the port picks like [`mirai rpc`](#mirai-rpc) and answers in one line; the task
context, also like `mirai rpc`, and `--plugins` go in all its messages. Without `--plugins` the
client receives the editor core and `call`; with it, also the tools of those plugins (`*`: all
methods). Which plugins exist is told by `engine.describe`.

- Without an editor it answers `initialize` itself (with `listChanged: true` and the instruction
  to open the editor), `ping` and an empty `tools/list`; a call or another request with `id` gives
  `-32099`. After an empty list it tries the editor every `BRIDGE_RETRY` seconds and, when it
  answers, sends `notifications/tools/list_changed` once.
- `.mcp.json` declares it: the engine's launches `bin/mirai mcp` relative to the root; a project's
  launches `mirai mcp` and requires the engine's `bin/` on the `PATH` (`mirai setup path`).

### MCP over HTTP

`/mcp` implements [MCP](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) in
the revisions of `MCP_VERSIONS` (the first if another is requested): one `POST` per message or
batch, without sessions or server events.

- `tools/list`: one tool per editor core method (flag `Core`, which `engine.describe` gives as
  `core`) and per method of the plugins named by the `X-Mirai-Plugins` header (comma-separated;
  `*`, all methods), with dots turned into underscores (the `tool` of `engine.describe`), its
  summary, `inputSchema` and annotations from its flags, and at the end `call` (`method` and
  `params`), which runs any method by its name. `tools/call` is not filtered: it also takes the
  name of a tool that was not listed.
- `engine.describe` with `methods`, `prefix` or `plugin` adds to `guides` the guides
  (`api.server_guides_set`) of the methods it gives: those of the plugin of any of them, that of
  the method or that of a prefix of its name ending in a dot. Without parameters it gives no
  guides. It paginates with `nextCursor`. `outputSchema` goes with a result declared with a type
  or with a `result_schema` of `type:"object"`.
- `tools/call`: the result as JSON text in `content` and, if it is an object, also in
  `structuredContent`; a method error is `isError:true` with `{"error":{...}}` in the text. With
  `mcp_content:true` it is an MCP content envelope (`view.viewport`, `play.capture`). A handler
  with a typed result attaches a PNG with `api.call_image` (`editor.capture`): MCP gives it as an
  image after the text and JSON-RPC returns only the result; if it does not fit in the response or
  cannot be read, a text with its path goes instead. A malformed JSON, or a non-object despite
  announcing an object, is `-32603`; an envelope that does not fit, `-32000`.

## Method conventions

Plugins add methods with
[API providers](../../mirai-editor/references/extensions.md#api-methods). They are registered
when the server opens; code reload rebuilds methods and schemas without closing connections.

- **Params and result are flat structs.** A field is required unless its tag carries `optional`;
  when absent, it takes the value from the method's `defaults`, or zero.
  - Text: `[N]u8` with tag `text`, up to N bytes.
  - `min`/`max` bound numbers and each element of an array; `label` is the schema description and
    `unit`, its unit (`x-unit`).
  - An array of numbers has exactly its length; another array, up to its length.
  - A fixed array with tag `trim` is written up to its last element with any non-zero byte
    (`engine.status` uses it in `gpu_timings` and `functions`); it does not change the binary
    schema.
  - An unknown field is `-32602`. The message of a badly written value, in params or in a value a
    method reads (settings, components, particles), says where it is
    (`View_Volume.exposure.adaptation_mode`), what fails and, for a name that does not exist, the
    fields or members that exist (`serial.text_error_message`), with the line and column.
- **Enums by name** (`"Edit"`), **bit sets as arrays of names** (`["W","Left_Shift"]`). A NaN or
  infinite float is written `"nan"`, `"inf"` or `"bits:0x…"`.
- **Hexadecimal ids.** An entity (`core.Id`) is a string of up to 16 digits
  (`"00a1b2c3d4e5f607"`, also with `0x`); an asset, of 32. They are returned with all their
  digits. A live `core.Entity` handle appears as `entity` (`play.inspect`, `play.player`).
- **Transforms local to the parent**: `rotation_deg` in Euler degrees, position in meters and
  scale in factors. `world_position` is read-only.
- **Free-form methods** (`scene.*`, `editor.input`, `camera.set`, `*.inspect`, `*.list`…) read or
  write the JSON by hand. They declare `params_schema` and, if the result has a known shape,
  `result_schema`.
- The values of a component are the JSON of its schema: fields in the order of the type, enums by
  name, entity references as Id. `transient` fields are neither written nor accepted.

## Concurrency, transactions and undo

- **Concurrency control belongs to the engine**: no method takes or returns revisions. A scene
  edit touches only the fields it names; if two authors write the same field, the last one's
  stays, and the user reverts it with the turn's change review or with undo.
- **Replacements of a whole file** (the animation `*.set` with `asset`, `pose.profile.set`,
  `skeleton.*`, `animation.clip.set`, `material.program.edit` with `source`): the last wins, as in
  the scene; each one is an undo step of the caller and, in an AI turn, enters its change review.
- Before editing, the server cancels the user's tools (a gizmo drag goes back) and records their
  pending gesture as their own step; `api_guard` fails with a pending recovery
  ([document](../../mirai-editor/references/document.md#edits-and-undo)).
- An edit is **one transaction** (`edits_begin`, the operations, `edits_commit`): if an operation
  fails, `edits_cancel` and nothing remains; otherwise it is a named undo step, with the project
  files it writes (`material.*`, `particle.*`). Each step belongs to whoever made it (an AI turn,
  the API outside a turn or the user) and `history.*` moves the caller's
  ([undo per author](../../mirai-editor/references/document.md#undo-by-author); `ai.revert`,
  `ai.review.accept` and `ai.retry`: [contract](../../mirai-editor/references/ai-review.md)).
- During Play or Simulate, scene edits and history **write into the document**: the game runs on
  its copy and does not see them until it stops. Saving and prefabs (`api_guard_edit`) wait for
  Edit (`A game is playing; this is done from Edit`); `simulation.apply` commits transforms into
  the document with one undo ([methods](methods.md#simulation)).
