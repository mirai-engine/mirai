# AI chats and agents

Code: `editor/ai*.odin`, `editor/acp/` and `tools/mirai/agent.odin`; the UI is in
[AI panel](panels.md#ai-panel).

- The editor is a native ACP v1 client in Odin. Transport, capabilities, errors and permissions in
  [the ACP client](../../../../editor/acp/README.md).
- `Ai.connections` (index `Ai_Provider`, up to `AI_CONNECTION_CAPACITY`) has one connection per
  agent, of an `Ai_Agent` type. Codex and Claude, always the first two, run the official adapters
  (`AI_AGENT_PACKAGES`), the user's or the one Mirai installs, and keep the tools and sessions of
  the provider's agent. `Command` is any agent that speaks ACP over stdio, added with a name,
  command and arguments (`ai_connection_add`).

## Connections and installation

Mirai signs in to no agent and stores no credentials: it uses the user's program and session
(`editor/ai_agents.odin`).

- **Connected** is a configured connection, not a resident process or a verified account: an
  expired session gives an error on sending and keeps the configuration to reconnect.
- **What belongs to the machine's user.** Adapters installed by Mirai, a private Bun, whether Codex
  and Claude are connected and what each adapter announced live in the user's folder
  (`project.agents_folder`, `<user data>/Mirai/Editor agents`, with `agents.json`), outside any
  project, checkout and build: updating or recompiling the engine and changing worktree do not lose
  them. The project's are the model and effort of each connection and the command agents
  (`<project>/.mirai/ai/connections.json`, without secrets).
- **The user's adapter first.** `ai_agents_refresh` looks for `codex-acp` and `claude-agent-acp` in
  the PATH and in the installers' folders (npm, Bun, pnpm, `~/.local/bin`, Homebrew); on Windows
  the npm script is started with Node and its package's JavaScript. If there is none, it uses the
  one Mirai installed. A user installation is neither updated nor uninstalled from Mirai: Update
  gives its command (`npm install -g`, `bun add -g` or `pnpm add -g` according to its folder), and
  is offered when the version it announced is older than the known one (`AI_AGENT_VERSIONS`) or
  than that of Check for updates.
- **What `initialize` announces** (`ai_agent_announced`): version and capabilities
  (`Ai_Capabilities`) are stored with the adapter that announced them, on each start. Connecting
  first starts a user adapter that has not yet announced anything, and Check for updates starts each
  of the user's: only until its answer (`ai_probe_start`); if it does not respond as ACP, the
  connection says so.
- Nothing is downloaded on opening the editor, reading connections, starting a chat or detecting an
  absent installation: installing is always an explicit action (Download, Update, `ai.install`).
  Download uses Bun, Node or pnpm, whichever exists, unless the runtime selector fixes one; with
  none it offers a private Bun. Update reuses the runtime of the previous installation.
  Uninstalling keeps the chats.
- Download and Update start with the click, on the agent's card: its line says how it goes and the
  button becomes Cancel (`ai_connections_install`). Only Uninstall asks for confirmation and shows
  its page. Commands and requirements in
  [projects](../../mirai-projects/references/projects.md#commands).
- Mirai never talks to a provider's API outside its official adapter: turns, models, permissions
  and spend go through ACP.
- **Connecting Codex or Claude** is asking its program whether there is a session, with the user's
  environment: `codex login status` (the user's Codex or, if absent, the one the adapter brings,
  which uses the same session) and `claude auth status --json`. Without a session, the error asks
  for `codex login` or `claude auth login` in a terminal (a Codex outside the PATH is named by its
  path). The adapter runs that same program (`CODEX_PATH`, `CLAUDE_CODE_EXECUTABLE`) without
  credentials from Mirai: an API key is configured in the agent (`ANTHROPIC_API_KEY`,
  `codex login --with-api-key`). If Claude Code is missing, the connection shows as not installed
  and Download first runs Anthropic's installer (`--claude-code`); with Bun and Node the adapter is
  installed without optional dependencies, without the SDK's copy of Claude Code.
- A command agent is not installed by Mirai: `installed` says whether the program is found. It
  starts without a shell, in the project folder and with the editor's environment; it is marked
  connected (Use existing sign-in) or signs in with the first method it announces. Removing its
  connection keeps its chats, but continuing one fails.
- Model and effort of the connection are those of a new session; each conversation keeps its own.
  The composer's selector changes those of the open session and its connection; `ai.task` chooses
  them for a turn without changing either. The adapter must announce exactly those values: an
  absent one fails and is not substituted. Codex admits only `AI_CODEX_MODELS`; Claude and the
  command agents discover them in the ACP options of a session.

## Chat flow

1. On sending, the turn keeps up to `AI_ENTITY_CAPACITY` selected authoring ids for its outlines,
   even if the selection changes afterwards. The capture uses the viewport's free area.
2. Enter or Send continue the chosen conversation; New session starts another. While the agent
   works, the button stops it; with something typed it corrects course: it stops the turn and, when
   it ended, sends what was typed in the same chat (`ai_chat_send`, `Ai.steer`). Each document keeps
   draft, provider, region, conversation and scroll; History lists its conversations without
   needing an agent.
3. The turn is prepared at the start of the next frame with the last capture of the region and the
   chat visible; without a renderer it goes without an image.
4. Editor instructions and user message go as separate text blocks in `session/prompt`, followed by
   the [reference images](#reference-images). The message is written to the turn's folder on
   sending and read on starting: the editor's state keeps no copy, and its only cap is that of the
   field that edits it (`AI_MESSAGE_BYTES`). What the user saw is not attached: the instructions
   ask to answer in English and name `view_viewport`, which knows the turn of the caller.
5. A free worker takes the turn; what exceeds the workers stays queued and starts on the active
   document. A conversation does not receive another turn while the previous one continues.

Workers:

- `AI_WORKER_CAPACITY` independent workers, each with its own ACP client: they generate several
  conversations at once, even of the same provider with different models. A worker keeps its
  process between turns and closes it for another provider or after `AI_IDLE_SECONDS` without
  turns; a later message restarts it and recovers the session.
- Before opening or recovering another session on a Ready client, it closes the previous one if the
  agent announces it and waits for the response: it keeps the native history and renews the turn's
  MCP headers. A close error does not start the next session
  ([cycle](../../../../editor/acp/README.md#cycle)).
- Up to `AI_TASK_CAPACITY` conversations in memory; to make room a finished one with nothing
  pending review is withdrawn, which stays in the history.

End of the turn:

- The instructions require calling `finish` once; the editor knows the turn by its header. Only
  its `response` is shown
  and saved as the assistant's answer, in Markdown; the messages arriving through ACP are not. Each
  entity goes as `[Name](entity:ID)` and an asset the agent created or changed as
  `[Name](asset:path)`, which the thread shows as pills. A scene for the user to try goes as
  `[What to try](play:path)`, which the thread draws as a button: it opens the scene if it is not
  the open one (what Open asks, like saving, goes first) and plays it once it is in place
  (`ai_play_scene`, `Ai.play_after`). `prompt.md` and the `finish` schema ask for it this way.
- `finish_called` records the request, but the turn stays `running` until the final ACP response;
  if that arrives without `finish`, the turn fails with the reason visible.
- The prompt has no timeout: after `AI_SILENT_SECONDS` without updates the transcript says so once.
  The last line the agent printed on stderr (`Ai_Task.said`) is added to the reason of an error or
  an exit, and Codex's retries and errors (`session_info_update` with `_meta.codex.error`) enter as
  notes.
- Without `question` or `response`, `finish` closes the turn without writing in the chat: it is a
  result visible in the editor. A question leaves its choice as the next message; it is saved with
  the review, returns on reopening and is removed by the next turn or by confirming the
  conversation.

Permissions: the `mirai` tools are never asked about, because what they change is reviewed and
reverted in the editor. Codex follows a fixed policy (`ai_permission_policy`): it allows them and
rejects the rest (commands outside the sandbox, files outside the project) with a failed step.
Claude opens the session with `_meta.claudeCode.options.allowedTools` in `mcp__mirai`; whatever
else it asks for, like the command agents, presents its official options and waits for an explicit
answer in its session's thread, through the worker of the running turn. Stop or a correction answer
`cancelled` to what keeps waiting, so the turn ends without that answer.

Plan: the ACP `plan` update replaces the turn's steps (`Ai_Task.plan`, up to `AI_PLAN_ENTRIES`,
each in its first line), which the thread shows under the last message until the conversation's
next turn. It is not saved with the chat.

Deleting a file is asked of the user with both providers; moving is not (`ai_permissions.odin`):

- Claude receives in `session/new`, `load` and `resume` rules for its session
  (`_meta.claudeCode.options.settings`, `AI_CLAUDE_SESSION_META`): `ask` for the commands that
  delete and for `asset_delete`, `panel_delete` and `git_discard`, and `allow` for `mv`. An `ask`
  rule beats the `allow` ones and the user's default mode.
- Codex runs without asking what its sandbox permits, so the editor writes
  `.codex/rules/mirai.rules` in the project (`prefix_rule` with `decision="prompt"`) and marks it
  trusted in `CODEX_CONFIG` so that Codex reads it. The request this causes, and the approval of
  an editor tool that deletes, go to the user instead of the policy (`ai_permission_deletes`). A
  tool approval may name it only by its call's id: the worker keeps the title of the last one.
- A Codex `apply_patch` deletion and a command Codex launches in Git Bash by its full path on
  Windows do not go through the rules: those are not asked about. Approving a Codex deletion runs
  it outside the sandbox, also outside the project: the user sees the command.

Each API call with the turn is left as a note saved with the chat (`ai_tool_note`): they are the
turn's steps in the thread, and the gaps between notes are model time. What it worked on is taken
from the parameters before running it, so a deleted entity keeps its name. The ids of the
entities and the whole paths of the assets the call names (`ai_call_refs`) go after the target as
`· ref ...`, so that the [search of the chats](#project-data) finds the turns that touched them.

The agent's own tools (a command, a file it reads or edits) arrive through ACP as `tool_call` and
`tool_call_update`; the worker follows those in progress (`Ai_Worker.calls`) and each is a step
when it ends or fails, with its `kind` as the method and its last title as what it worked on
(`ai_tool_call_receive`). Those of the editor's MCP server (`mcp.mirai.*` in Codex, `mcp__mirai__*`
in Claude, or `rawInput.server` `mirai`) are already steps through the API and are not repeated; if
an adapter named them differently, the step would only appear twice. While it runs, the most recent
one in progress is what the thread says it does now.

Document and rejections:

- Changing document cancels the active and queued turns; a conversation of another document or
  provider is not continued on the current one. Continuing a chat confirms the review of its
  previous turn and opens another. Reverting asks for the document that originated the changes.
- A task is not created without a message, with one of `AI_PROMPT_BYTES` or more, with `--no-api`,
  without a project, with an invalid region, with an unsupported model or effort or without room in
  the cache. An unconfigured connection, an agent not installed, an absent runtime or an ACP
  failure leave the turn `failed` with the reason.

## Project data

History in `<project>/.mirai/ai/chats/` (`editor/ai_store.odin`), three files per conversation,
without credentials:

- `<id>.json`, the metadata, is replaced whole atomically. `<id>.log` are JSON records per line that
  are only appended: a message one fixes the type and text of its sequence, an annotation completes
  an already saved message and the last record of a sequence replaces the previous ones. A line cut
  by an abrupt close is ignored and the next write finishes it. `<id>.review.json` is the
  [turn's review](ai-review.md).
- On opening the project only the `.json` are read and the index stays in memory: History filters
  and sorts without reading files. Messages are read on recovering a conversation or requesting a
  page, up to `AI_STORE_LOG_BYTES` per conversation; the visible transcript is a bounded cache
  (`AI_TRANSCRIPT_*`). A new id is reserved by creating its `.log` exclusively: another editor of
  the same project does not repeat it.
- The initial title is the beginning of the first request. Those of `session_info_update` update
  the conversation, also after the turn; they are not messages, and Mirai does not call the model
  to summarize them. In Codex the title is confirmed before the prompt with the
  [negotiated rename](../../../../editor/acp/README.md), because `codex-acp` generates titles with
  a fixed model outside the supported ones; without that capability the turn fails before the
  prompt. Claude keeps the initial one and ignores its own (`ai_session_title_update`):
  `claude-agent-acp` summarizes them from the start of the prompt, which is the editor's
  instructions, and although it announces renaming, a user's Claude Code 2.1 does not implement it
  (`rename_session`) and the turn would fail.
- The search index, `.mirai/ai/search.db` (`editor/ai_search.odin`), is SQLite with FTS5 and a
  cache derived from the `.log` files, which stay the only source: only the editor writes it, each
  chat keeps how many bytes of its log are indexed, and a save or an open reads what came after
  (also what another editor of the project appended). A database that is missing, is not one, is
  corrupt or is of another `AI_INDEX_VERSION` is deleted and built again from the logs, with no
  migration; a busy lock or another failure leaves it as it is and the search says why. Every line
  is indexed, prompts, answers and notes, by its latest record. A query is words, each a quoted
  phrase so that no character is syntax (an asset path or a method is the phrase of its parts), all
  in the line, `OR` between two taking either; History searches the titles and, by prefix of the
  last word, the lines, and a chat found by its lines shows what matched in place of its last
  answer.
- Spend is what the adapter reports through ACP, without estimating it: tokens with the `usage` of
  the `session/prompt` response (unstable in ACP) and the context window and cost with
  `usage_update`. Codex reports no cost.

Each turn has its folder `.mirai/ai/<conversation-id>-<sequence>/` (`AI_FILE_*`): `prompt.md` with
the editor's instructions (`ai_prompt_write`), `message.md` with the user's message, which Retry
puts back in the composer and which is rebuilt from the chat if the folder lost it, `context.json`
with mode, region, camera, selection, document and the region's entities (in Play, the live
player), `state.json` (only from the pause, with a selection) with the selected entities and the
values of their components at the paused tick, `region.png` with the region on sending, without
panels and at half the drawable's pixels (`ai_half_pixels`), written by a job that `view_viewport`
waits for, and `mcp.json`
with the `mirai` server and the turn's header.

MCP and attribution:

- The ACP session receives the open editor's `mirai` MCP HTTP server with the header
  `X-Mirai-Ai-Task: <conversation-id>-<sequence>`, which attributes to the turn the transactions of
  each request even if other workers generate
  ([protocol](../../mirai-agent-api/references/api.md#ai-turn-context)).
- Without `X-Mirai-Plugins`: the agent sees the editor's core and `call`, and asks for the rest (the
  plugins' methods and the less common ones of the editor) with `call` and their schemas with
  `engine_describe`, as `prompt.md` says
  ([MCP](../../mirai-agent-api/references/api.md#mcp-over-http)). This way a turn does not load the
  schema of every method into its context.
- The header of a closed or replaced turn is rejected; after `finish` only reads are allowed.
- The commands the agent runs carry its turn without naming it: its process starts with
  `MIRAI_AI_TASK=agent-<serial>` (`Ai_Worker.agent`) and `MIRAI_API_PORT`, `mirai rpc` sends them,
  and the editor attributes each call to the turn that agent runs when it arrives
  ([protocol](../../mirai-agent-api/references/api.md#ai-turn-context)). For many calls the
  instructions ask for a script with `mirai rpc`; a raw HTTP request without the header is not
  attributed.

Agent scope, fixed by `prompt.md`:

- It works on the game, not the engine: it edits the scene through the API, plays when asked to
  test and writes game code in the project folder, which it compiles itself (`build_start`,
  `build_status`, `engine_diagnostics`, `build_check`, `build_test`); the user does not compile. It
  neither reads nor changes the engine nor writes outside the project. From the engine it receives
  the declarations the project compiles against, its public API (`.mirai/engine/<mode>/decl/` of the
  engine and `.mirai/plugins/<mode>/decl/` of the project,
  [binaries](../../mirai-projects/references/projects.md#engine-binaries)), and the gameplay
  skill if the engine brings it.
- It names the tools as they are called (`scene_batch`) and includes the schemas of
  `AI_PROMPT_SCHEMAS` from the live registry, the scene review on sending and the entities in view,
  the selected ones first.
- For an interface of the user's own it points it to `panel_save`, not editor code: buttons per
  variant (with `where` for all the entities that match) without rows for what they change, and
  rows for what is adjusted by hand ([project panels](panels.md#project-panels)).
- How to use the methods of a plugin (animation, cinematics, collision, painting) or an editor
  family (material programs) is a guide (`AI_GUIDES`, `editor/ai_guides.odin`): `engine_describe`
  gives it together with those methods, and `prompt.md` brings it only if the message goes out from
  a document of that plugin (`ai_guide_topic_in_front`). A turn does not load what it does not use.
- The memory of the project is the agent's: it does not see the engine, so it keeps how the game
  is made in the `AGENTS.md` of the project (`AI_PROJECT_MEMORY`, read when a chat starts) and the
  procedures it repeats as skills in its `.agents/skills` (`AI_PROJECT_SKILLS`), versioned with the
  game, replacing what changes instead of appending, and only with what matters beyond a task:
  nothing trivial nor what the code already says.
- Mirai implements no other skill executor or harness.

The Codex session is isolated from the user's configuration (`AI_CODEX_SESSION_CONFIG`, in the
adapter's `CODEX_CONFIG`): without skills, `AGENTS.md`, plugins, apps, browser or computer use, even
with the global account, and without touching `~/.codex`; the project is trusted so that it reads
its rules, and with that also its `.codex/config.toml`. It runs in the adapter's `workspace-write`
mode (`INITIAL_AGENT_MODE`), without an automatic reviewer: the sandbox writes only in the project
and what it asks to do outside reaches Mirai, which rejects it.

### Assets of a message

- An asset of the Content Browser dropped on the chat goes with the next message (an entity of
  Hierarchy joins the selection, which also goes) (up to `AI_ATTACHMENTS`), as a chip with its type's icon; removing it
  releases it (`ai_attachments.odin`).
- On sending it passes to the turn (`Ai_Task.attachments`); `context.json` lists them by path in
  `assets` and `prompt.md` says their paths and types: the agent reads and changes them through the
  API. One that is no longer in the registry is not named.
- A range chosen on a time strip goes the same way: a chip, `Ai_Task.range`, `range` in
  `context.json` (what Copy range says) and a line of `prompt.md`; for a Play, it reads the ticks
  with `play.history`.

### Reference images

- An image dropped on the chat, or chosen with the composer's button, goes with the next message
  (up to `AI_REFERENCES`) instead of being imported; the composer shows it as a chip.
- On sending, each is written to the turn's folder as `reference-<n>.jpg`, shrunk without changing
  its aspect ratio until it fits in `AI_REFERENCE_SIDE` (`ai_fit_pixels`: each pixel is the average
  of those it covers) and compressed in a job (`Ai_Task.reference_writes`). A reference shows an
  aspect, not detail: so it costs few tokens and the prompt fits in the ACP client's send buffer.
- They go in the same `session/prompt` as the message, as `image` blocks after its text: the agent
  sees them without asking. `context.json` lists them in `references` and `prompt.md` says how many
  there are. An agent whose `promptCapabilities.image` is false does not receive them: the turn
  fails and says so.

`view_viewport` (`view.viewport` through MCP) answers the image saved for the message of the
caller's turn (`request` names an older one); it does not recapture the current camera nor depend on the cache, and an absent
capture or one too large for the MCP response is a tool error. The agent receives it only if it
asks.

### Context of a document

With an asset document in front, what the chat shows and sends is not the scene: the composer shows
as chips what the document's plugin says was chosen in it (`editor.asset_document_pick`), and
`context.json` adds `asset` without entities, with what the document shows at that moment
(`editor.asset_document_show_say`). `prompt.md` says which document the message comes from, what it
showed and what the user chose.

### Context of a material

- A message sent with the [material document](panels.md#material-document) in front carries
  `Ai_Task.material`: the `.mat`, its program, the chosen values, the channel if it is not Lit and
  the last variant put; removing a chip deselects the value, returns to Lit or forgets the variant.
  `context.json` adds `material` with all the material's values on sending, the chosen ones marked,
  and the source revision; `region.png` is the preview.
- The program flow of all domains (`material.program.create`, `inspect`, `check`, `edit`, never the
  agent's file tools, which are neither reviewed nor reverted; `material.preview.capture` and
  `mirai image diff`, with the units and limits of a program) is the `material.program` guide: it
  goes in the instructions with the material document in front and, otherwise, `engine_describe`
  gives it with that prefix.

Entities in the context:

- Derived geometries without `Id` are grouped by authoring owner ([viewport](panels.md#viewport)):
  one entry per owner, with the union of their visible rectangles.
- A partial region keeps the complete rectangle with `inside=false`. The selected ones have priority
  within `AI_ENTITY_CAPACITY`, even off camera or without visible geometry, with an empty `rect`
  and `inside=false`.

## Play

The turns' runs are in [Play](editor.md#play).

- A turn that starts inside the user's Play reads it and keeps that run if the user leaves it
  without the turn having one of its own. The user sends it from the pause: the entities they
  select there go with their values at that tick (`ai_state_write`), which the game changes once
  it resumes.
- The turn carries a snapshot of the live world: local seat, the body it drives, camera, transforms
  and clock. `play.player` shares that function; its live handles allow inspecting entities created
  in the game without `Id`. The instructions ask for read-only observations with `play.player`,
  `play.status` and `play.inspect` with `include_runtime:true`.
- Scene editing by API writes to the document even if Play runs
  ([API](../../mirai-agent-api/references/methods.md#play)).

## Agents in scene and review

`Show agents in scene` starts enabled, is saved in the project and controls figures, glyphs and
their picking.

- Each agent is the [figure](editor.md#figures-of-whoever-works) in its color, with its glyph and
  the name of its connection; it creates no entities nor enters the saved scene, and stays visible
  on switching to Content or minimizing the panel.
- A turn appears when it has something in the scene: the context selected on sending or a change.
  Once it appeared (`figure_shown`), it continues in the conversation's next turns until the agent
  finishes, and a message without new context does not move it.
- It is placed next to the gizmo of what the turn works on, outside its handles and the context's
  bounds, and looks toward it; without a selection it uses the camera target. Each attributed
  transaction relocates it next to the last live entity of its record or where the last one it
  deleted was ([review](ai-review.md#finish-revert-and-retry)): the position is recomputed in those
  transactions, not in stable frames; a turn in Play places it by the live player, and it shows
  once the game stops ([figures](editor.md#figures-of-whoever-works)).
- The other editors of a shared session see the figures and the outlines of what changed
  ([collaboration](collaboration.md#what-travels)).

Outlines, without fill and with the priority of the selection ones, until the turn is confirmed or
reverted even if the figures are hidden: what the turn changed and what hangs from it, in the
agent's color; the sent context, in its color while working and, when it finished, with a faint
neutral outline under the selection.

Each MCP edit is a normal history transaction; the header allows also saving the turn's record,
which Finish, Revert and Retry use ([change review](ai-review.md)).

## Agents outside the editor

An agent the user runs outside the editor (Claude Code, Codex, Claude or any MCP client) calls with
the name of its client (`X-Mirai-Client`,
[protocol](../../mirai-agent-api/references/api.md#ai-turn-context)); `editor/ai_external.odin`.

- Its calls are the turn of a chat of its own (`Ai_Task.agent` `external:<client>`), with no
  worker: it has a row in the panel with the mark of Claude or Codex, the dot while it works, its
  figure, its steps and the same review as the agents of the editor; its edits are steps of that
  turn, and its `history.undo` undoes them. Otherwise it acts as the user does: it plays the
  user's Play, chooses what is watched and is not refused the user's unsaved work.
- The turn ends with `ai.turn_end`, which the `Stop` hook of Claude Code in the
  [templates](../../mirai-gameplay/references/demo.md#templates) calls, or after
  `AI_EXTERNAL_IDLE` without calls; its answer stays in its own app, and it does not see `finish`,
  which is only for a turn of the agents of the editor. `ai.turn_end` leaves those turns as they
  are, so the hook of a Claude Code the editor runs changes nothing, and ending twice is one end.
  An end because the agent asks the user something is not an answer: its next call opens the
  same turn again while the review waits, and once the user resolved it the next call starts the
  next turn of the chat. A turn that changed nothing is done with on ending.
- Stop on its row ends the turn without stopping the agent; a message written in its chat starts a
  chat of the editor; it has no Retry. Two instances of the same client share the turn.
- A call without a turn or a client belongs to no agent (`EDIT_AUTHOR_API`).

## API methods

Parameters and results of `ai.*` and `finish` are given by `engine.describe`; what their schema
does not say:

**Task**: `{id,state,prompt,agent,model,effort,native_session,play,folder,files,region,
entities,image,pid,exit_code,seconds,steps,revertible,undone,needs_build,files_changed,
review_finished,review_pending,changed,changed_files,icon,color,skipped,
finish_called,lines}`;
requested by `id` it adds `first` and `transcript:[{kind,text}]` (`kind`: `prompt`, `output`,
`note`).

- `id` is the conversation; continuing it adds a turn and confirms the previous review.
- `state`: `queued`, `running`, `done`, `failed`, `cancelled`; a reverted one stays `declined`.
- `steps` counts the current record's transactions; `changed` has its authoring ids,
  `changed_files` the project paths it wrote through the API and `skipped`, the conflicts kept on
  reverting.
- `review_finished`: the user confirmed; `review_pending`: there are pending scene or file changes.
- `finish_called`: the agent asked to finish; the turn stays `running` until ACP confirms.
- `icon` and `color` are indices of the agent's appearance.

Methods:

- `ai.task`: draws a frame with the chat visible, writes the turn's files in `.mirai/ai/` and
  starts or queues it; up to three conversations generate at once. It returns the task.
  - `region` in window points; `conversation` continues a saved ID.
  - Without `agent` it continues with the saved provider; a new chat uses the selected one or the
    first configured. Omitted `model` and `effort` use those of the conversation it continues, or
    those of the connection in a new chat, without modifying it.
  - Codex admits `AI_CODEX_MODELS` (`gpt-6-luna`, `gpt-6.1-sol`, `gpt-6-astra`). `effort`: `low`,
    `medium`, `high`, or empty in a command agent, which keeps its own.
  - It delivers instructions and message as separate blocks, exposes skills and gives MCP with the
    turn's header; in Play it includes the live player. In a manual editor, advance frames.
- `ai.status`: `{running,capacity,process_running,show_agents_in_scene,permissions,chat,tasks}`.
  `running` is the array of conversations with an active worker; `process_running`, that some
  process remains open, also between turns. With `id`, the task and its transcript from `from`. It
  starts no processes nor advances frames.
- `finish`: the agent calls it once on finishing. `response` is the final answer in English to a
  question or explanation; it is omitted for a visible change. `question` (`text`, `single`,
  `multi`, `confirm`) asks the user instead of closing, with the question in `response` and, for
  `single`/`multi`, `options` as a list of strings. It finishes the turn its header names
  (`Method_Flag.Turn`: `tools/list` gives it only to such a request) and rejects a request without
  one, a turn that is not running and a second call. It does not mark `done` before ACP nor confirm the
  review.
- `ai.cancel`: cancels the generation or removes it from the queue.
- `ai.turn_end`: ends the turn of the agent outside the editor that calls
  ([outside the editor](#agents-outside-the-editor)); `ended` says whether one was running.
- `ai.revert`: reverts the turn's scene changes by fields and its files, keeping what others wrote
  afterwards, and leaves an undo step; `skipped` gives the conflicts. It removes figure and
  outlines and keeps the record. It rejects an active turn, another document, an incomplete record
  or `files_changed`; it requires Edit.
- `ai.restore`: resumes the changes of a `declined` task keeping what others wrote afterwards and
  leaves them pending review. It requires Edit and its document; it leaves an undo step.
- `ai.review.accept`: confirms a finished result and releases record, indicator and outlines; it
  does not call the model nor create an undo.
- `ai.retry`: reverts the pending review and repeats the original message in the same
  conversation, with the same glyph and color; already confirmed, it only repeats. It rejects a
  missing message, another document or busy capacity. It advances two frames.
- `ai.history`: without `id`, up to 64 project conversations from `offset`
  (`{id,title,document,provider,model,effort,updated_at}`). With `id`, up to 128 messages before the
  exclusive cursor `before` (0: the most recent), in chronological order
  (`{sequence,kind,text,role,event_type,tool,context}`; `context` is JSON as text). It reads the
  history even if the conversation is not in memory.
- `ai.history.search`: the lines of the project chats that match `query` (see the
  [search index](#project-data)), the best first by BM25, `limit` up to 50, only those of
  `conversation` when given. Each hit is short (`{conversation,title,sequence,kind,snippet,
  updated_at}`, the matches of `snippet` between `**`): the agent reads the context of one with
  `ai.history` of its `conversation` and `before` the hit's `sequence` plus one, and the whole
  chat by paging back. A query without words fails with `INVALID_PARAMS`.
- `ai.permission`: answers the pending permission `index` of `ai.status` with `option` (official
  ID), or rejects it with `cancel:true`. A nonexistent index or option fails.
- `ai.connections`: `{runtime,instructions,connections,operation:{busy,status,error}}`.
  - Connection: `provider` (its id), `name`, `agent` (`codex`, `claude` or `command`, the latter
    with `command` and `arguments`), `installed`, `version`, `latest`, `connected`, `runtime`,
    `model`, `effort`; Codex and Claude add `user`, `adapter`, `capabilities` and, in a user
    installation with `latest`, `update` with its command.
  - `installed` of a command agent: its program was found. `connected`: there is a saved
    configuration; it does not verify the account nor start agents.
- The following return the state of `ai.connections`:
  - `ai.connect`: requires the installation, or the program of a command agent. Codex and Claude
    connect only if their program reports a session (first it starts its adapter if it announced
    nothing); a command agent is marked connected with `existing:true` or signs in with the first
    method it announces. Query `ai.connections` until `operation.busy` is false.
  - `ai.agent.add`: adds an agent that speaks ACP over stdio, started by `command` without a shell
    in the project folder; `arguments` separated by spaces. The id comes from the name (lowercase,
    digits and hyphens) and is not repeated. Mirai does not install it; up to 8 connections.
  - `ai.agent.remove`: removes a connection made by `ai.agent.add`; its chats stay in the history.
    Codex and Claude are not removed.
  - `ai.disconnect`: disconnects; keeps installation and history and does not close the agent's
    session.
  - `ai.install`: explicit `operation`; query `ai.connections` and, in a manual editor, advance
    frames. `check` queries all the installed ones without updating and starts each user adapter
    up to its `initialize`; `download`, `update` and `uninstall` require Codex or Claude, and in a
    user installation they fail with its command; `runtime` installs a private Bun without a
    provider; `cancel` keeps the previous installation. `runtime` `automatic` chooses among the
    available ones.
  - `ai.configure`: saves for the next message `model`, `effort` and the project's `instructions`;
    omitted ones are kept and `instructions:""` clears them. The instructions are
    `.mirai/ai/instructions.md`, which is read when preparing each turn and when answering
    `ai.connections`: they do not live in the editor's state nor in `connections.json`. Model and
    effort are validated against the session's ACP options on sending, without substituting values.
