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
- A turn does not discard the user's unsaved work: `engine.shutdown`, `scene.open`,
  `editor.recover` with `discard` and closing a document with changes fail, asking it to ask.
- A tagged write closes the user's previous gesture and, if it succeeds, attributes to the turn
  only the new transactions of that request
  ([change review](../../mirai-editor/references/ai-review.md)); without the header, to no agent.
- `X-Mirai-Client` names an agent outside the editor (letters, digits, `.`, `_` and `-`, shorter
  than `api.CLIENT_NAME_BYTES`), delivered as `Call.client_name`; a tagged request does not send
  it. `mirai mcp` sends the `clientInfo.name` of the initialize of its client, lowercase;
  `mirai rpc`
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
  the next call reaches it through the port file, its `build.status`
  says `Built`, and `mirai session` still knows it as the project's. `mirai build engine` does not
  restart sessions: it names them.
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

`mirai capture [project] [--out x.png]` (options in `CAPTURE_USAGE`; without `--out`, under
`.mirai/captures` of the project, and the JSON says where) uses the project's session or
opens one and closes it: it loads the scene, places the camera (`camera.set`), captures the world
without UI (`capture` with `of:"Scene"`), reads `engine.diagnostics` and measures the image.
It prints a JSON with the counters of the `capture` when it gives them, the validation, the
console, `stats` and, with `--reference`, `diff`
([`mirai image`](image.md)). It exits with 1 if there are validation errors or if the SSIM against
`--reference` is below `--threshold`. Each capture starts the window clock at zero (`seconds` of
`capture`): a scene loaded again and captured again draws the same frames. `--repeat` loads
the scene again (that of `--scene` or the document's file, if it has no unsaved changes), returns
to the same camera, captures and gives its SSIM; what remains is what two renderers do not share
and, below `REPEAT_SSIM`, it warns that a higher threshold compares noise. `--view` shows a mode of
`editor.view_mode.list` and when done restores the one the session had; `collision` is not visible
because the capture carries no lines. `--frames 0` waits for the textures to stream in as
`capture` does; the frames it draws by default are exact, so two runs draw the same.

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

`mirai play test [project] [scenario...]` plays
[scenarios](../../../../docs/game/testing/scenario.md) in the project's
session or in one it opens and closes, one `play.scenario.run` per file: those named (a name of
`tests/scenarios`, or a path) or all of `tests/scenarios`. It prints a line per scenario and, for
one that fails, its failure and what the failing step answered; it exits with 0 when all pass, 1
when one fails and 2 when they cannot run. A session it opens builds the editor of the project
first when its code changed, as `mirai session start` does. A project runs it in its CI, on a
machine with a GPU.

## `mirai ui` and `mirai scene`

`mirai ui read|write|check` and `mirai scene read|write|check` (`UI_USAGE`, `SCENE_USAGE`) work on
the documents of [`ui.inspect` and `ui.write`](../../mirai-plugins/references/ui-inspector.md#api)
and of [`scene.inspect` with `root` and `scene.write`](methods.md#scene) with no editor: the tool
runs `cook/author.command` in the engine's `mirai-author` program
([binaries](../../mirai-projects/references/projects.md#engine-binaries)), building the engine
first when it is not current, as `mirai import` does. What a game-writing agent is told:
[text sources](../../../../docs/game/assets/text-sources.md).

- **Documents as files.** `source/<path>.ui.json` is the asset `assets/<path>.ui`, and so
  `.scene.json` and `.prefab.json`. `read <asset>` prints the document or writes it to `--out`;
  `read --sources` writes one per asset of the project (not of its plugins); `write` takes those
  files or a folder of them, or `<asset> <file>` for a file kept elsewhere, and tries again what
  failed while a round writes something, so a file may use one the same run makes.
- **A write** is the one of the API method: what it refuses is refused with its message and the
  file stays as it was; a file that already says the document is not written. An asset that does
  not exist is made with an id that follows from its path. A `.ui` written with other `params`
  takes along the files that use it as a widget, as the editor does.
- **`ui check` reads the code too.** Checking every `.ui`, it also parses the Odin of `game/`
  (`cook/author/ui_code_names.odin`): a literal a call of `gui.clicked` and its like names a node
  by is a node of some `.ui` of the project, a node inside a widget as `use/node`; and the `draw`
  of each `Draw` node is a `@(draw)` procedure of the built game.
- **Types of the game.** The paths an interface binds and the components of a scene are read
  against the `editor` library of the project, which also has the cards of its plugins. Only
  `ui read` runs without it: the tool refuses every other command, with the `mirai build editor`
  that fixes it and exit code 1, when the library is missing or older than the code of the
  project (`build.target_state`). Nothing is written or checked that nothing could check.
- **A scene document** is `{"entities": [...]}`, the entities at the top of the file, applied to
  the file of the asset with no world. `preset` runs its recipe on a world of the game made for
  it and keeps the components it gives; a new entity with `prefab` is placed with
  `asset.scene_instantiate`, and what the document changes of an entity of an instance is
  recorded as an override. An entity that names its prefab by path or id alone declares the
  instance as its prefab gives it, so the document that placed it writes nothing the next time;
  with `{asset, root}`, as `read` gives it, it declares all it has. An entity it makes takes the id
  the document gives when the file is
  new, and the components the game of this build does not know stay with the entities it keeps.
- **`check`** lists what would fail in the game and exits with 1: for interfaces what `ui.check`
  lists, for scenes each file whose document does not write it back unchanged, with the first
  thing that differs.
- **The tracked assets** of the game template and the demo are files their own documents write
  back byte by byte
  (`the_documents_of_the_tracked_assets_write_back_the_files_they_were_read_from`): an asset
  saved by an earlier layout is written again with `mirai ui write` before it is committed.

## `mirai rpc`

```sh
mirai rpc <method> [key=value...|json|-|--file F] [--select FIELDS]
  [--wait-until CONDITION]
  [--project P] [--port N] [--timeout S]
mirai rpc describe [plugin|method|prefix|method...] [--project P|--port N]
mirai rpc --batch <calls.jsonl|-> [the same options]
```

- Params are `key=value` arguments or one JSON object (`{}` if missing; `-` from stdin).
  `key=value` needs no quoting in any shell: a value that parses as JSON is that JSON and any
  other is text, and dots in a key make objects inside
  (`mirai rpc scene.set entity=Floor name=Ground position=[0,1,0]`); a number or a boolean goes as
  its text to a field that takes only a string. A value that a shell would split or that needs a
  list of texts goes in the object form.
- `--project P` takes the port from its `api.json` and, when the project has no editor open,
  starts its headless `--dev` session as `mirai session start` does and then makes the call,
  saying so on stderr; a method that only makes sense with an editor already open
  (`RPC_NEEDS_OPEN_EDITOR`) never starts one and fails without an editor. Without `--project` or
  `--port`, the port is that of `MIRAI_API_PORT` or the editor of the project at or above the
  current folder, failing when it has none and never starting one; the default port only outside
  any project.
- A call waits as long as the editor process is alive and working, saying on stderr that it still
  waits, less often the longer it takes; `--timeout S` limits it or, with
  `--wait-until`, the whole wait. An editor whose process ended is `-32096` at once, and one whose
  process is alive but uses no CPU for `api.CLIENT_HUNG_SECONDS` is `-32095`, naming its pid and
  its log. Knowing the process needs a port file: with `--port` only that of the project at or
  above the current folder. A call to `MIRAI_API_PORT` sends `MIRAI_AI_TASK`
  ([context](#ai-turn-context)). `--batch` reads one `{"method","params"}` call per line, from a
  file or from stdin (`-`), over one connection, so many calls cost one process; it prints a JSON
  array with the result of each and stops at the first error, whose entry says its `line`. A value
  of the params that is exactly `$N` or `$N.path` (the paths of
  `--select`, as `$0.id` or `$1.entities[0].id`) stands for the result of the call N or that field
  of it, and `$$` writes a literal `$`.
- Output: the result on stdout and code 0; an error, on stderr as `{"error":{...}}` and code 1;
  invalid arguments, `Usage:` and code 2. From the client: `-32099` with no editor listening,
  `-32097` when `--timeout` runs out, `-32096` if it closed the connection without answering (it
  ended or restarted, maybe after running the call), `-32095` if it hung, `-32098` if the response
  is not JSON-RPC. `-32601` names the similar ones.

### Fields and waits

The server handles the reserved params. Every method takes `_select` (`"a.b,c[0].d"`), which
answers only those fields, as an object by their paths. A read-only method (`read_only` in
`engine.describe`) also takes `_wait_until` (`"phase=Built"`), which calls the method again until
the condition holds, the editor going on meanwhile, for at most `api.WAIT_UNTIL_SECONDS`, or the
`_wait_seconds` that `--timeout` sends. A method that changes things refuses both with `-32602`,
as each call would change them again: it is called once, and the wait goes on a read-only method,
such as its status method (`build.start`, then `build.status`). Selecting reads the result of a
call that already ran, so a field that is not there is no error: the answer keeps the fields it
found and says briefly which are missing and which exist, in the `note` member of the JSON-RPC
response or in a second text of the MCP content. `--select` and `--wait-until` of `mirai rpc`
send these params: the server does both, and the client only calls again when the editor restarts
during the wait.

A field is a path in the result: names separated by dots and `[i]` for element `i` of an array,
from the end if `i` is negative (`entities[0].id`, `entities[-1]`); a name that is a number on an
array is that index (`entities.0.id`).

- `--select a.b,c[0].d` prints those fields, one per line: a text without quotes, a number or
  `true`/`false`/`null` as is, and an object or array as JSON. A field that is not there is left
  out, and one line on stderr says which is missing and which exist; the exit code is 0.
- `--wait-until '<field><op><value>'` is met in the server and prints that result. `op` is `=`
  (`==`), `!=`, `<`, `<=`, `>` or `>=`; the ordering ones need
  numbers. Numbers are compared as numbers (exact integers), a text by its content, with or
  without quotes, and the rest as JSON without spaces (`selection=[]`). An editor that restarts
  during the wait (`-32096`) keeps being waited for, because Build restarts it; another error, a
  field that is not there or a value that cannot be ordered end immediately. After `--timeout` it
  exits with `-32097`, the last value in the message and `data:{field,value}`. Example:
  `mirai rpc play.network.status --wait-until 'connected=true' --select connected`.

### `mirai rpc describe`

It reads `engine.describe`: with no argument, the index: the core methods with a short summary, the
names of the others by plugin and the plugins the project does not use. With the name of a plugin
(or `editor`) or a prefix (`scene.` or `scene`), the summaries of that area. With a method, or with
several methods (`methods` of `engine.describe`), for each its flags and its summary, each param
with its type (range, length,
unit, enum, id), `required` or its default value and its label, an example of valid params and
each field of the result with its type and its label. A name that lists none is `-32602` with the
similar ones.

## `mirai mcp`

`mirai mcp [--project P|--port N] [--timeout S] [--plugins A,B|*] [--client NAME]` is an MCP server
over stdio: it forwards each JSON line (up to `MCP_MAX_LINE` bytes) to the `POST /mcp` of the
editor that the port picks like [`mirai rpc`](#mirai-rpc) and answers in one line; the task
context, also like `mirai rpc`, and `--plugins` go in all its messages. Without `--plugins` the
client receives the editor core and `call`; with it, also the tools of those plugins (`*`: all
methods). Which plugins exist is told by `engine.describe`.

- A message waits like a call of [`mirai rpc`](#mirai-rpc): as long as the editor process is alive
  and working, up to `--timeout` or what the client allows; a process that ended or hung is a
  tool error at once.
- With `--project` the port is the one `.mirai/api.json` of that project names, read again on
  every message and never the fixed port, so it only reaches that project's editor, also after
  it restarts on another port. While the project has no editor it answers `initialize` itself
  (with `listChanged: true`), lists the `docs` tool and one placeholder tool, and a tool call starts
  the session like [`mirai rpc`](#mirai-rpc), by the same rule; what cannot start it says to run
  `mirai session start`. When an editor appears, or another replaces it, it sends
  `notifications/tools/list_changed` once that editor answers.
- Without `--project` and without an editor it answers `initialize` itself (with
  `listChanged: true` and the instruction to open the editor), `ping` and a `tools/list` with only
  the `docs` tool; a call or another request with `id` gives `-32099`. After that list it tries the
  editor every `BRIDGE_RETRY` seconds and, when it
  answers, sends `notifications/tools/list_changed` once.
- `.mcp.json` declares it: the engine's launches `bin/mirai mcp` relative to the root; a project's
  launches `mirai mcp` and requires the engine's `bin/` on the `PATH` (`mirai setup path`).

### MCP over HTTP

`/mcp` implements [MCP](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) in
the revisions of `MCP_VERSIONS` (the first if another is requested): one `POST` per message or
batch, without sessions.

- A `tools/call` with `_meta.progressToken` and an `Accept` of `text/event-stream` answers as a
  stream: `notifications/progress` while it works, its answer last. Without both it is one JSON.
  `mirai mcp` asks for the stream when a call brings a token and writes each notification to
  stdout as it comes.
- `notifications/cancelled` ends the wait of the call it names (`build.start`, a blocking
  `play.start`, `play.step`, `play.scenario.run`, what goes through `api_wait`) at a safe point,
  which answers code `-32094`. A `play.start` that waited for a build does not start its game
  later; a build or an import it waited for goes on. `mirai mcp` forwards it while the call runs.
- `initialize` gives `_meta` with `engine_version`, `process_id`, `project` and `project_folder`;
  `mirai mcp` with no editor gives what it knows.

- `tools/list`: `docs` (the game documentation of `docs/game`, as `mirai docs` reads it, and the
  same in `mirai mcp` without an editor; its index goes in the instructions), one tool per editor
  core method (flag `Core`, which `engine.describe` gives as `core`: what agents use most, since
  each one listed costs its schema every turn) and per method of the plugins named by the
  `X-Mirai-Plugins` header (comma-separated;
  `*`, all methods), with dots turned into underscores (the `tool` of `engine.describe`), its
  summary, `inputSchema` and annotations from its flags, and at the end `call` (`method` and
  `params`), which runs any method by its name. `tools/call` is not filtered: it also takes the
  name of a tool that was not listed.
- `engine.describe` with `methods`, `prefix` or `plugin` adds to `guides` the guides
  (`api.server_guides_set`) of the methods it gives: those of the plugin of any of them, that of
  the method or that of a prefix of its name ending in a dot. Without parameters it gives no
  guides. It paginates with `nextCursor`. Tools declare no `outputSchema`: `engine.describe` gives
  the shape of a result.
- `tools/call`: the result as JSON text in `content`, the only copy, since clients give models
  `structuredContent` in place of the text and it would undo `_select`; a method error is
  `isError:true` with `{"error":{...}}` in the text. A handler
  attaches a PNG with `api.call_image` (`capture`, `view.viewport`): MCP gives it as an image
  after the text and JSON-RPC returns only the result; if it does not fit in the response or
  cannot be read, a text with its path goes instead. A malformed JSON, or a non-object despite
  announcing an object, is `-32603`; an envelope that does not fit, `-32000`.

## Method conventions

Plugins add methods with
[API providers](../../mirai-editor/references/extensions.md#api-methods). They are registered
when the server opens; code reload rebuilds methods and schemas without closing connections.

- **An entity is named once, as `entity`.** Every param that names one (`entity`, `entities`, or
  by its role `parent`, `target`, `ground`, `around`...) takes its name, a path of names
  `Parent/Child`, its id or its handle, as text (`Api_Entity_Text`, tagged `entity`, so its schema
  says `x-entity`); the handler resolves it with `api_call_entity` in the world it acts on, where
  in Play a handle is a valid text. A name several entities have is an error that
  lists them and how to tell them apart; a text of 16 hexadecimal digits or starting with `0x` is
  tried as an id and a handle first; `scene.write` keeps `id` in its documents, which are what
  `scene.inspect` gives back. Results always give ids.
- **An asset field takes a path or an id.** Asset_Id params and component fields also take the path
  under the assets folder, with or without its extension, checked against the field's `kind`;
  results keep ids. A miss lists the nearest paths of that kind.
- **Params are taken as they can only be meant**, in one place before anything reads them
  (`api.params_shape`, over the JSON Schema of the method): a key that is
  the singular or the plural of one field, a
  single value where a list goes, a list of one where a single value goes, and a number or a
  boolean, as its text, where the schema takes only a string. A list of several for a single
  value fails saying so.
- **A key the params do not declare is `-32602`**; a method without a params type takes none.
  What only the world gives a shape (an object keyed by component name) is a `serial.Json` field,
  which takes any JSON.
- **A name of a registry is matched as a person writes it** (`base.name_find`): components, enum
  members of params and values, input keys and presets, without minding case, underscores, spaces
  or hyphens. It resolves only when exactly one candidate fits; otherwise the error says which
  fit or the nearest ones, when any is close for the length of the name. It is for what comes
  through the API: assets and binary data are read exactly.
- **Params and result are structs, and they are the only description of a method.** A field is
  required unless its tag carries `optional`; when absent or `null`, it takes the value from the
  method's `defaults`, or zero. A method without a result type answers `null`, and an optional
  field of a result that holds nothing (zero, empty) is left out of the answer.
  - Text: `[N]u8` with tag `text`, up to N bytes, or a `string` of any length.
  - A list of any length is a slice (`[]T`) and any JSON value a `serial.Json` field, which holds
    its text; both live in the scratch of the call, so a request that does not fit fails. A type
    does not hold itself: a nested document is a `serial.Json` field.
  - `min`/`max` bound numbers and each element of an array; `label` is the schema description and
    `unit`, its unit (`x-unit`).
  - An array of numbers has exactly its length; another array, up to its length.
  - `clamp` on an integer that only bounds how much a method answers: past its `max` it takes it,
    and the result says so in `_clamped`. Other ranges fail.
  - A fixed array with tag `trim` is written up to its last element with any non-zero byte
    (`engine.status` uses it in `gpu_timings` and `functions`); it does not change the binary
    schema.
  - An unknown field is `-32602`. The message of a badly written value, in params or in a value a
    method reads (settings, components, particles), says where it is
    (`View_Volume.exposure.adaptation_mode`), what fails and, for a name that does not exist, the
    fields or the nearest members that exist (`serial.text_error_message`), with the line and
    column. A `-32602` for the shape or the type of the params (unknown field, wrong type,
    missing required field) carries in `data.usage` its fields with their types and a valid
    example, when the answer has room for it; a name that names nothing and what a handler
    refuses do not.
- **Enums by name** (`"Edit"`), **bit sets as arrays of names** (`["W","Left_Shift"]`). A NaN or
  infinite float is written `"nan"`, `"inf"` or `"bits:0x…"`.
- **Hexadecimal ids.** An entity (`core.Id`) is taken as a string of up to 16 digits
  (`"00a1b2c3d4e5f607"`, also with `0x`) and answered with `0x` and all its digits; an asset, 32
  digits without it. A live `core.Entity` handle has the form of an id and appears as `entity`
  (`play.inspect`, `play.player`).
- **Transforms local to the parent**: `rotation_deg` in Euler degrees, position in meters and
  scale in factors. `world_position` is read-only.
- **`Call.raw` is the text of the params as their types say them**: a handler that reads a
  `serial.Json` field, or still reads its params from the text, gets the names of enums as the
  type has them. A handler that writes its result itself declares its type the same way
  (`writes_result`); a result whose type is `serial.Json` has no declared shape.
- **A method the state of the editor does not allow now** (no game plays, or one does) fails with
  `-32001`, whose `data.fix` names the method that changes it (`play.start`, `play.stop`).
- **What a method does to the editor is in its flags** (`api.Method_Flag`), which
  `engine.describe` lists: it only reads, it draws the scene, it runs as the user would, it
  changes the view and not the document.
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
  pending gesture as their own step
  ([document](../../mirai-editor/references/document.md#edits-and-undo)).
- An edit is **one transaction** (`edits_begin`, the operations, `edits_commit`): if an operation
  fails, `edits_cancel` and nothing remains; otherwise it is a named undo step, with the project
  files it writes (`material.*`, `particle.*`). Each step belongs to whoever made it (an AI turn,
  the API outside a turn or the user) and `history.*` moves the caller's
  ([undo per author](../../mirai-editor/references/document.md#undo-by-author); `ai.revert`,
  `ai.review.accept` and `ai.retry`: [contract](../../mirai-editor/references/ai-review.md)).
- During Play or Simulate, scene edits, history, saving, prefabs and asset authoring **work on the
  document and the assets**: the game runs on its copy and sees an asset that changes when it is
  read again, as with any write on disk. What opens a view over the viewport (a section, a material
  document) or simulates on the document (`placement.drop`) waits for Edit; `simulation.apply`
  commits transforms into the document with one undo ([methods](methods.md#simulation)).
