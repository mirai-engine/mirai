# AI chats and agents

Code: `editor/ai*.odin`, `editor/acp/` and `tools/mirai/agent.odin`; the UI is in
[AI panel](panels.md#ai-panel).

- A project has **one continuous chat**, the main chat: the user only ever talks to it, there are
  no sessions to open or pick, and the word session does not appear in the UI. The main agent
  delegates parallel work to [subagents](#subagents), which are tasks of the editor, not the
  provider's native subagents. Everything the user sees of an agent is a conversation of
  `chat.db` ([project data](#project-data)).
- The editor is a native ACP v1 client in Odin. Transport, capabilities, errors, steering and
  compaction in [the ACP client](../../../../editor/acp/README.md).
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
- Nothing is downloaded on opening the editor, reading connections, sending a message or
  detecting an absent installation: installing is always an explicit action (Download, Update,
  `ai.install`).
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
- Model and effort of the connection are those of a new conversation; each conversation keeps its
  own. The composer's selector changes those of the main chat and its connection; `ai.task` chooses
  them for a turn without changing either. Choosing another agent for the main chat takes effect
  with its next turn, in a new native session with a [handoff](#compaction-and-handoff), in the
  same chat. The adapter must announce exactly those values: an absent one fails and is not
  substituted. Codex admits only `AI_CODEX_MODELS`; Claude and the command agents discover them in
  the ACP options of a session.

## Chat flow

1. On sending, the turn keeps up to `AI_ENTITY_CAPACITY` selected authoring ids for its outlines,
   even if the selection changes afterwards. The capture uses the viewport's free area.
2. Enter or Send writes to the main chat, or to the subagent being inspected; the first message
   creates the main chat (`Ai.main`, zero until then). Composer, draft, selection, region and the
   chosen agent are one per project, not per document: the main chat's `conversation.document`
   follows the document of its latest turn, and a subagent stays on the one it began on.
   Shift+Enter is a new line. A message written to an agent outside the editor goes to the main
   chat.
3. **Enter while the agent works does not interrupt it and leaves no queue to manage**
   (`ai_chat_send`, `ai_task_steer`): its line enters the thread at once and the message joins the
   running turn at its next safe point (ACP steering). The adapter answers what became of it
   (`ai_steer_done`): joined, or a turn started for it, or it was not consumed. What cannot join
   (the adapter does not announce steering, the worker is gone, the turn is being stopped or the
   adapter answers `promptRequired` or `failed`) is kept as a delivery of kind steer, drawn with a
   dashed outline until it reaches the agent, and goes with the chat's next turn; it survives
   closing the editor. Stop is the only way to cut a turn; the send button becomes Stop only
   with nothing written.
4. The turn is prepared at the start of the next frame with the last capture of the region and the
   chat visible; without a renderer it goes without an image.
5. What a turn sends is the [stable block, the delta and the user's message](#what-a-turn-sends),
   followed by the [reference images](#reference-images). The message is written to the turn's
   folder on sending and read on starting: the editor's state keeps no copy, and its only cap is
   that of the field that edits it (`AI_MESSAGE_BYTES`). What the user saw is not attached: the
   delta names `view_viewport`, which knows the turn of the caller.
6. A free worker takes the turn; what exceeds the workers stays queued and starts on the active
   document. A conversation does not receive another turn while the previous one continues.

Workers:

- `AI_WORKER_CAPACITY` independent workers, each with its own ACP client: they generate several
  conversations at once, even of the same provider with different models. One worker is never
  taken by a subagent (`ai_subagent_workers`), so the main chat can always answer. A worker keeps
  its process between turns and closes it for another provider or after `AI_IDLE_SECONDS` without
  turns; a later message restarts it and recovers the session.
- Before opening or recovering another session on a Ready client, it closes the previous one if the
  agent announces it and waits for the response: it keeps the native history and renews the turn's
  MCP headers. A close error does not start the next session
  ([cycle](../../../../editor/acp/README.md#cycle)).
- Up to `AI_TASK_CAPACITY` conversations in memory; to make room a finished one with nothing
  pending review is withdrawn, which stays in `chat.db`. The main chat is never withdrawn.

End of the turn:

- The instructions require calling `finish` once; the editor knows the turn by its header. Only
  its `response` is shown and saved as the assistant's answer, in Markdown; the messages arriving
  through ACP are not. For a subagent it is its report to the main chat. Each
  entity goes as `[Name](entity:ID)` and an asset the agent created or changed as
  `[Name](asset:path)`, which the thread shows as pills. A scene for the user to try goes as
  `[What to try](play:path)`, which the thread draws as a button: it opens the scene if it is not
  the open one (what Open asks, like saving, goes first) and plays it once it is in place
  (`ai_play_scene`, `Ai.play_after`). The stable block and the `finish` schema ask for it this way.
- `finish_called` records the request, but the turn stays `running` until the final ACP response;
  if that arrives without `finish`, the turn fails with the reason visible. A system turn (the
  main chat taking its [deliveries](#deliveries-and-reports)) and the compaction command are the
  exception: they have nothing to say and end without `finish`.
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

- Changing document cancels the active and queued turns. The main chat goes on in the document in
  front and takes it as its own; a subagent of another document is not continued on the current
  one. Continuing a chat confirms the review of its previous turn. Reverting asks for the document
  that originated the changes.
- A task is not created without a message (a system turn has none), with one of
  `AI_MESSAGE_BYTES` or more, with `--no-api`, without a project, with an invalid region, with an
  unsupported model or effort or without room in the cache; nor to continue an archived
  conversation or, through `ai.task`, one that still runs (a message to a working chat steers it:
  Enter, `agent.message`). An unconfigured connection, an agent not installed, an absent runtime or
  an ACP failure leave the turn `failed` with the reason.

## Subagents

The main agent delegates with `agent.spawn`, which starts a **subagent**: a task of the editor with
its own conversation (kind `Agent`, its `parent` the main chat), turns, worker and
[review](ai-review.md). The call returns at once and the work runs in parallel.

- Depth is one: `agent.spawn` works only from a running turn of the main chat, which its MCP header
  names, and a subagent that calls it fails with a message saying so. A Claude main chat may start
  a Codex subagent and the other way round.
- A subagent is bound to the document it began on, as a turn is. It takes nothing of the composer,
  the selection or the view of the user (`Ai_Turn.detached`) and knows nothing of the chat but its
  prompt: the stable block says what it is, and the `response` of its `finish` is its report.
- **What it runs with** (`ai_subagent_resolve`): what `agent.spawn` names (`agent`, `model`,
  `effort`) wins; what it leaves out comes from the project's default for subagents, which the gear
  of the panel and `ai.configure` set and `.mirai/ai/connections.json` keeps: `same` (the
  connection, model and effort of the main chat, the default), `fixed` (a connection, model and
  effort of its own) or `pick` (the agent chooses; what it omits is as `same`). Only a configured
  connection is chosen, and none takes the place of another.
- The user inspects one from the bar, the status line or the expanded chat
  ([panel](panels.md#ai-panel)): its thread, review, stop and a composer that writes to it. A
  message to a working subagent steers it; to an idle one it starts its next turn. `agent.message`
  and `agent.stop` do the same for the main agent.
- Reply on a report card attaches the unit to the next message of the main chat (`Ai.about`); the
  delta says which subagent the message replies to (`ai_about_note`).

## Deliveries and reports

`deliveries` hold text that has to reach a conversation, of kind `report` or `steer`; they survive
closing the editor.

- A subagent that ends a turn (`ai_task_settle`) leaves a `.Report` line in the thread of the main
  chat (its text is the subagent id) and a delivery of kind `report` with its id, title, state,
  how many changes wait for review, a question it asked and its answer. One that goes on with a
  held message reports when it is done with it; one the editor closed on does not report.
- The main chat takes what waits for it with its next turn, whoever starts it. When it is idle and
  nothing holds them, deliveries become **one system turn** of the main chat
  (`ai_deliveries_advance`): no line of the user, no message, and it may end without `finish`. It
  waits while a subagent works (so the reports arrive together), while the main chat has changes
  to review (a new turn would confirm them) and after a failed or stopped turn, when everything
  goes with the next message of the user.
- The steers of a subagent that could not join its turn go as its next turn once it is idle.

## What a turn sends

Three text blocks in `session/prompt` (`ai_send_task_prompt`), followed by the
[reference images](#reference-images). `prompt.md` of the turn's folder keeps the first two as
they went.

- **The stable block** (`ai_prompt_stable`): who the agent is, its rules and scope, the tools and
  the schemas of `AI_PROMPT_SCHEMAS` from the live registry, the editor instructions of the project
  and the memory of the [two levels](#memory). It is the same text every turn while the project
  does not change, so the provider's prompt cache holds, and it goes alone and first, **once per
  native session**, and again after a compaction completed or the instructions changed. A
  subagent adds what it is; the main chat, what the handoff header means and how to delegate.
- **The delta** (`ai_prompt_write`, `ai_delta_build`): only what is about this turn, as it stands
  when the message is sent: the open document, the region, the entities in view with the selected
  ones first, the capture, attachments, a range, an asset document or material in front, the
  Play state, the pinned references, the annotations of the document, the groups and the unit the
  message is about, the subagents still working with the document each touches, what waits in
  [deliveries](#deliveries-and-reports) and, in the first turn of a new native session, the
  [handoff](#compaction-and-handoff). When the context passes `AI_COMPACT_NOTES_AT`, it asks once
  per native session to save notes first.
- **The user's message**, as the text of its own block (empty in a system turn).

Entities in the delta:

- Derived geometries without `Id` are grouped by authoring owner ([viewport](panels.md#viewport)):
  one entry per owner, with the union of their visible rectangles.
- A partial region keeps the complete rectangle with `inside=false`. The selected ones have priority
  within `AI_ENTITY_CAPACITY`, even off camera or without visible geometry, with an empty `rect`
  and `inside=false`.

Each turn has its folder `.mirai/ai/<conversation-id>-<sequence>/` (`AI_FILE_*`): `prompt.md` with
the stable block and delta as sent (`ai_prompt_write`), `message.md` with the user's message, which
Retry puts back in the composer and which is rebuilt from the chat if the folder lost it,
`context.json` with mode, region, camera, selection, document and the region's entities (in Play,
the live player), `state.json` (only from the pause, with a selection) with the selected entities
and the values of their components at the paused tick, `region.png` with the region on sending,
without panels and at half the drawable's pixels (`ai_half_pixels`), written by a job that
`view_viewport` waits for, and `mcp.json` with the `mirai` server and the turn's header.

### Assets of a message

- An asset of the Content Browser dropped on the chat goes with the next message (an entity of
  Hierarchy joins the selection, which also goes) (up to `AI_ATTACHMENTS`), as a chip with its type's icon; removing it
  releases it (`ai_attachments.odin`).
- On sending it passes to the turn (`Ai_Task.attachments`); `context.json` lists them by path in
  `assets` and the delta says their paths and types: the agent reads and changes them through the
  API. One that is no longer in the registry is not named.
- A range chosen on a time strip goes the same way: a chip, `Ai_Task.range`, `range` in
  `context.json` (what Copy range says) and a line of the delta; for a Play, it reads the ticks
  with `play.history`.

### Reference images

- An image dropped on the chat, or chosen with the composer's button, goes with the next message
  (up to `AI_REFERENCES`) instead of being imported; the composer shows it as a chip.
- On sending, each is written to the turn's folder as `reference-<n>.jpg`, shrunk without changing
  its aspect ratio until it fits in `AI_REFERENCE_SIDE` (`ai_fit_pixels`: each pixel is the average
  of those it covers) and compressed in a job (`Ai_Task.reference_writes`). A reference shows an
  aspect, not detail: so it costs few tokens and the prompt fits in the ACP client's send buffer.
- They go in the same `session/prompt` as the message, as `image` blocks after its text: the agent
  sees them without asking. `context.json` lists them in `references` and the delta says how many
  there are. An agent whose `promptCapabilities.image` is false does not receive them: the turn
  fails and says so.

`view_viewport` (`view.viewport` through MCP) answers the image saved for the message of the
caller's turn (`request` names an older one); it does not recapture the current camera nor depend
on the cache, and an absent capture or one too large for the MCP response is a tool error. The
agent receives it only if it asks.

### Context of a document

With an asset document in front, what the chat shows and sends is not the scene: the composer shows
as chips what the document's plugin says was chosen in it (`editor.asset_document_pick`), and
`context.json` adds `asset` without entities, with what the document shows at that moment
(`editor.asset_document_show_say`). The delta says which document the message comes from, what it
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
  goes in the delta with the material document in front and, otherwise, `engine_describe`
  gives it with that prefix.

## Memory

Two levels, and never the same fact in both: Markdown for what is durable and versioned with the
game, SQLite for what Mirai queries and updates (the chats, their notes, deliveries, pins,
annotations and provenance).

- The short index `AGENTS.md` of the project (`AI_PROJECT_MEMORY`) and the user's `USER.md` in the
  memory folder of the agents home (`AI_MEMORY_USER_FILE`) go in the stable block, each with its
  cap (`AI_MEMORY_INDEX_BYTES`, `AI_MEMORY_USER_BYTES`). One file per topic in
  `.agents/memory/<topic>.md` (`AI_MEMORY_FOLDER`) is read on demand. The procedures the agent
  repeats are skills in the project's `.agents/skills` (`AI_PROJECT_SKILLS`); Mirai implements no
  other skill executor or harness.
- `memory.save` replaces a whole topic, the index (no topic) or the user's file (`scope` `project`
  or `user`) with how things are now, not a log; it checks the slug and the caps and writes the
  file at once, outside any undo step or review. `memory.search` finds topics by their words and
  `memory.read` reads a topic or the user's file, and no other path. `memory_docs` is derived:
  `ai_memory_scan` brings it up to the files by their modified time when the project opens and
  after each turn, so what was edited outside the editor is found too.
- Only what matters beyond a task goes there: nothing trivial and nothing the code or the scene
  already says. What only this chat needs, the work under way and what comes next, goes in its
  notes (`chat.note`): they replace the ones before, outlive the context and enter the handoff.
- The user reads and edits the same files from the gear of the panel
  ([settings](panels.md#ai-panel)); its dialog writes on Save.

## Compaction and handoff

The chat outlives any native context of its agent.

- **Compaction** is the provider's and automatic; the client opts in to its `compaction_update`.
  When one completes, the stable block goes again with the next turn and the thread notes it
  (`AI_COMPACTED_NOTE`). When the context passes `AI_COMPACT_NOTES_AT`, the delta asks once per
  native session to save what matters with `memory.save` and `chat.note` before it is summarized.
- **Compact now** (the popup of the context percent, and `ai.compact`) works on a chat that is not
  working. With the agent's `/compact` command when its worker still holds the session and the
  agent lists it: it runs as a turn that needs no `finish` and leaves the state and the review as
  they were. Otherwise the native session is dropped and the next turn opens a new one with a
  handoff. There is no field to say what to keep.
- **Handoff** (`ai_handoff_build`) is built by Mirai from the database, without calling a model,
  and goes in the delta of the first turn of a new native session, under `AI_HANDOFF_HEADER`:
  the notes of the chat, its latest messages up to a byte budget (`ai.history` reads the rest),
  the subagents that ended or were interrupted since the previous context, and the units whose
  changes wait for review.
- **Reopening the editor** continues the same visible chat with a clean context: a new native
  session with a handoff, after a divider (`AI_REOPENED_NOTE`). The restart that a Build causes
  resumes the same native session, once (`ai_resume_native_mark`). The subagents that were working
  come back `interrupted`: nothing starts them but a message to them, and the handoff lists them.
  Closing the editor with agents working still asks
  ([exiting](document.md#exiting-with-changes-or-agents-working)).

## Project data

One SQLite database, `<project>/.mirai/ai/chat.db` (`editor/ai_store.odin`, WAL, without
credentials), holds what Mirai queries and updates; several editors of the same project share it
and a write waits for another one. The review of each conversation
(`.mirai/ai/chats/<id>.review.json`, [review](ai-review.md#persistence-and-capacity)), the captures
and the turn folders stay files.

- **Conversations** have a kind: `Main` (the one chat), `Agent` (a subagent, with its `parent`) or
  `Archived` (the conversations of agents outside the editor). **Messages** are the lines of a
  conversation by sequence; a later write of a sequence replaces it and one that did not change is
  not written again. Messages are read on recovering a
  conversation or requesting a page; the visible transcript is a bounded cache
  (`AI_TRANSCRIPT_*`). Their search is an FTS5 table that triggers keep exact: there is no cache
  that can go stale.
- The other tables are the data of the features that follow: `deliveries` (text waiting to reach a
  conversation), `notes` (the working notes of the main chat), `pins`, `annotations`,
  `provenance`, `meta` (small markers such as the subagents that were working) and
  `memory_docs`, the derived index of the memory topics.
- `PRAGMA user_version` is the schema version. A database that is corrupt or of another version is
  reported with how to restore or move it, and is never deleted.
- The initial title is the beginning of the first request (a subagent's, the one `agent.spawn`
  gives). Those of `session_info_update` update the conversation, also after the turn; they are
  not messages, and Mirai does not call the model to summarize them. In Codex the title is
  confirmed before the prompt with the
  [negotiated rename](../../../../editor/acp/README.md), because `codex-acp` generates titles with
  a fixed model outside the supported ones; without that capability the turn fails before the
  prompt. Claude keeps the initial one and ignores its own (`ai_session_title_update`):
  `claude-agent-acp` summarizes them from the start of the prompt, which is the editor's
  instructions, and although it announces renaming, a user's Claude Code 2.1 does not implement it
  (`rename_session`) and the turn would fail.
- **Search** (`editor/ai_search.odin`): a query is words, each a quoted phrase so that no character
  is syntax (an asset path or a method is the phrase of its parts), all in the line, `OR` between
  two taking either; ranked by BM25, with a prefix option for a box being typed in. Every line is
  indexed, prompts, answers and notes. The search of the clock looks in the main chat, and
  `ai.history.search` in all the conversations; the memory topics have their own table and rules.
- Spend is what the adapter reports through ACP, without estimating it: tokens with the `usage` of
  the `session/prompt` response (unstable in ACP) and the context window and cost with
  `usage_update`. Codex reports no cost.

## Pins, annotations and provenance

- **Pins** (`ai_pins.odin`): a chip of the composer (an asset, entity, image, annotation group or
  unit) can be pinned, and it then stays over the composer across messages, in `pins`. The delta
  names every pin by identifier or path in every turn, images only by path, so a compaction loses
  nothing.
- **Annotations** (`ai_annotations.odin`): the Annotate tool of the viewport drops a pin on a
  surface or an entity, with a note and a group, in `annotations` and never in the scene. The delta
  lists the pins of the document one line each (number, group, world position, entity, note); the
  group of a pin goes with the next message as a chip. The agent reads them with `annotation.list`
  and clears them with `annotation.remove`, one pin or a whole group, when it is done.
- **Provenance** (`ai_provenance.odin`): each transaction a review records writes, for every entity
  and asset it touched, the conversation and the turn that changed it last, in `provenance`.
  Details and the asset document show it as a row that opens that turn, and `ai.provenance` gives
  it to an agent. An asset a unit changed that waits for review is marked in the Content Browser
  ([panel](panels.md#ai-panel)).

## Attribution and scope

MCP and attribution:

- The ACP session receives the open editor's `mirai` MCP HTTP server with the header
  `X-Mirai-Ai-Task: <conversation-id>-<sequence>`, which attributes to the turn the transactions of
  each request even if other workers generate
  ([protocol](../../mirai-agent-api/references/api.md#ai-turn-context)).
- Without `X-Mirai-Plugins`: the agent sees the editor's core and `call`, and asks for the rest (the
  plugins' methods and the less common ones of the editor) with `call` and their schemas with
  `engine_describe`, as the stable block says
  ([MCP](../../mirai-agent-api/references/api.md#mcp-over-http)). This way a turn does not load the
  schema of every method into its context.
- The header of a closed or replaced turn is rejected; after `finish` only reads are allowed.
- The commands the agent runs carry its turn without naming it: its process starts with
  `MIRAI_AI_TASK=agent-<serial>` (`Ai_Worker.agent`) and `MIRAI_API_PORT`, `mirai rpc` sends them,
  and the editor attributes each call to the turn that agent runs when it arrives
  ([protocol](../../mirai-agent-api/references/api.md#ai-turn-context)). For many calls the
  instructions ask for a script with `mirai rpc`; a raw HTTP request without the header is not
  attributed.

Agent scope, fixed by the stable block:

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
  gives it together with those methods, and the delta brings it only if the message goes out from
  a document of that plugin (`ai_guide_topic_in_front`). A turn does not load what it does not use.
- Its memory is [two levels](#memory): it keeps what it learns of the game, replacing what
  changes instead of appending.

The Codex session is isolated from the user's configuration (`AI_CODEX_SESSION_CONFIG`, in the
adapter's `CODEX_CONFIG`): without skills, `AGENTS.md`, plugins, apps, browser or computer use, even
with the global account, and without touching `~/.codex`; the project is trusted so that it reads
its rules, and with that also its `.codex/config.toml`. It runs in the adapter's `workspace-write`
mode (`INITIAL_AGENT_MODE`), without an automatic reviewer: the sandbox writes only in the project
and what it asks to do outside reaches Mirai, which rejects it.

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
  worker: it appears in the bar and in the status line of the panel with the mark of Claude or
  Codex, the dot while it works, its figure, its steps and the same review as the agents of the
  editor, and it is inspected like a subagent, but it is not one (`Archived` kind); its edits are
  steps of that turn, and its `history.undo` undoes them. Otherwise it acts as the user does: it plays the
  user's Play, chooses what is watched and is not refused the user's unsaved work.
- The turn ends with `ai.turn_end`, which the `Stop` hook of Claude Code in the
  [templates](../../mirai-gameplay/references/demo.md#templates) calls, or after
  `AI_EXTERNAL_IDLE` without calls; its answer stays in its own app, and it does not see `finish`,
  which is only for a turn of the agents of the editor. `ai.turn_end` leaves those turns as they
  are, so the hook of a Claude Code the editor runs changes nothing, and ending twice is one end.
  An end because the agent asks the user something is not an answer: its next call opens the
  same turn again while the review waits, and once the user resolved it the next call starts the
  next turn of the chat. A turn that changed nothing is done with on ending.
- Stop in its view ends the turn without stopping the agent; a message written there goes to the
  main chat; it has no Retry. Two instances of the same client share the turn.
- A call without a turn or a client belongs to no agent (`EDIT_AUTHOR_API`).

## API methods

Parameters and results of `ai.*`, `agent.*`, `chat.note`, `memory.*`, `annotation.*` and `finish`
are given by `engine.describe`; what their schema does not say:

**Task** (`ai.task`, `ai.status`, `ai.cancel` and the review methods):

- `id` is the conversation; `kind` says `main`, `agent` or `archived`, and `parent` is the main
  chat of a subagent. `held` counts the messages written to it that have not reached its agent.
- `state`: `queued`, `running`, `done`, `failed`, `cancelled` and `interrupted` (a subagent the
  editor closed on); a reverted one stays `declined`.
- `steps` counts the current record's transactions; `changed` has its authoring ids,
  `changed_files` the project paths it wrote through the API and `skipped`, the conflicts kept on
  reverting.
- `review_finished`: the user confirmed; `review_pending`: there are pending scene or file changes.
- `finish_called`: the agent asked to finish; the turn stays `running` until ACP confirms.
- `icon` and `color` are indices of the agent's appearance.
- Requested by `id` it adds `first` and a `transcript` of lines whose `kind` is `prompt`, `output`,
  `note`, `report` (a subagent with that id ended a turn) or `divider` (a new context began).

Methods:

- `ai.task`: draws a frame with the chat visible, writes the turn's files in `.mirai/ai/` and
  starts or queues it. It returns the task.
  - Without `conversation` it is a message to the main chat, which the first one creates; with
    the id of a subagent it is a message to it, taking nothing of the composer or the selection.
    It fails on a conversation that still runs: `agent.message` steers it.
  - `region` in window points. Without `agent` it continues with the saved provider; the first
    message uses the selected one or the first configured. Omitted `model` and `effort` use those
    of the conversation, or those of the connection for a new one, without modifying it.
  - Codex admits `AI_CODEX_MODELS`. `effort`: `low`, `medium`, `high`, or empty in a command
    agent, which keeps its own.
  - It delivers the [blocks of a turn](#what-a-turn-sends), exposes skills and gives MCP with the
    turn's header; in Play it includes the live player. In a manual editor, advance frames.
- `ai.status`: `running` is the array of conversations with an active worker; `process_running`,
  that some process remains open, also between turns; `chat.main` is the main chat and
  `chat.selected` the one shown. With `id`, the task and its transcript from `from`. It starts no
  processes nor advances frames.
- `finish`: the agent calls it once on finishing. `response` is the final answer in English to a
  question or explanation; it is omitted for a visible change. `question` (`text`, `single`,
  `multi`, `confirm`) asks the user instead of closing, with the question in `response` and, for
  `single`/`multi`, `options` as a list of strings. It finishes the turn its header names
  (`Method_Flag.Turn`: `tools/list` gives it only to such a request) and rejects a request without
  one, a turn that is not running and a second call. It does not mark `done` before ACP nor
  confirm the review.
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
- `ai.compact`: [Compact now](#compaction-and-handoff) of a chat that is not working; without `id`
  it compacts the main chat. It fails with the reason when there is nothing to compact.
- `ai.history`: without `id`, the conversations of the project from `offset`, of every kind. With
  `id`, a page of messages before the exclusive cursor `before` (0: the most recent), in
  chronological order (`context` is JSON as text). It reads `chat.db` even if the conversation is
  not in memory.
- `ai.history.search`: the lines of the conversations that match `query` (see
  [search](#project-data)), the best first by BM25, only those of `conversation` when given. Each
  hit is short (the matches of `snippet` between `**`): the agent reads the context of one with
  `ai.history` of its `conversation` and `before` the hit's `sequence` plus one, and the whole chat
  by paging back. A query without words fails with `INVALID_PARAMS`.
- `ai.provenance`: who last changed an entity or an asset (give one or the other, the asset by its
  path under the assets folder) through a turn: the conversation, its title, the prompt of that
  turn, the model, the effort and the date.
- `agent.spawn`, `agent.list`, `agent.message` and `agent.stop` are the main agent's
  [subagents](#subagents); `agent.spawn` is listed only to a request with a turn header
  (`Method_Flag.Turn`) and fails from a subagent. `agent.list` gives the answer of a finished one;
  `agent.message` steers a working one or starts the next turn of an idle one.
- `chat.note` replaces the notes of the main chat; `memory.search`, `memory.read` and
  `memory.save` are the [memory](#memory) of the project and of the user.
- `annotation.list` and `annotation.remove` read and clear the
  [pins](#pins-annotations-and-provenance) of a document; `remove` takes one by id or a whole
  group of the open document.
- `ai.permission`: answers the pending permission `index` of `ai.status` with `option` (official
  ID), or rejects it with `cancel:true`. A nonexistent index or option fails.
- `ai.connections`: a connection has a `provider` (its id) and an `agent` (`codex`, `claude` or
  `command`, the latter with `command` and `arguments`); Codex and Claude add `user`, `adapter`,
  `capabilities` and, in a user installation with `latest`, `update` with its command. `subagent`
  is the default of the subagents.
  - `installed` of a command agent: its program was found. `connected`: there is a saved
    configuration; it does not verify the account nor start agents.
- The following return the state of `ai.connections`:
  - `ai.connect`: requires the installation, or the program of a command agent. Codex and Claude
    connect only if their program reports a session (first it starts its adapter if it announced
    nothing); a command agent is marked connected with `existing:true` or signs in with the first
    method it announces. Query `ai.connections` until `operation.busy` is false.
  - `ai.agent.add`: adds an agent that speaks ACP over stdio, started by `command` without a shell
    in the project folder; `arguments` separated by spaces. The id comes from the name (lowercase,
    digits and hyphens) and is not repeated. Mirai does not install it.
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
    omitted ones are kept and `instructions:""` clears them. The `subagent_*` fields, without a
    `provider`, set the [default of the subagents](#subagents). The instructions are
    `.mirai/ai/instructions.md`, which is read when preparing each turn and when answering
    `ai.connections`: they do not live in the editor's state nor in `connections.json`. Model and
    effort are validated against the session's ACP options on sending, without substituting values.
