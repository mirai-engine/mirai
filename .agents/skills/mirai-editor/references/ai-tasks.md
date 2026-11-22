# AI chats and agents

Code: `editor/ai*.odin`, `editor/ai_store/`, `editor/acp/`, `tools/mirai/agent.odin`; UI in
[AI panel](panels.md#ai-panel).

- One continuous **main chat** per project (`Ai.main`, 0 until first message); no sessions in UI.
  Parallel work uses editor [subagents](#subagents), not provider-native subagents. All visible
  threads are conversations in `chat.db` ([project data](#project-data)).
- Native ACP v1 client in Odin ([ACP client](../../../../editor/acp/README.md)).
- `Ai.connections` (`Ai_Provider`, cap `AI_CONNECTION_CAPACITY`): Codex and Claude first (official
  `AI_AGENT_PACKAGES` adapters), plus `Command` agents speaking ACP over stdio
  (`ai_connection_add`).

## Connections and installation

`editor/ai_agents.odin`. Mirai stores no credentials and never calls provider APIs outside official
ACP adapters.

- **Connected** means configured, not a live process or verified account; expired sign-in fails on
  send and keeps config.
- **Machine vs. project state:** Mirai-installed adapters, private Bun, Codex/Claude connection
  flags, and announced capabilities live in `project.agents_folder`
  (`<user data>/Mirai/Editor agents/agents.json`), surviving rebuilds and worktrees. Project
  `<project>/.mirai/ai/connections.json` holds model, effort, subagent default, and command agents
  (no secrets).
- **User adapter priority:** `ai_agents_refresh` prefers user-installed `codex-acp` /
  `claude-agent-acp` (PATH, npm, Bun, pnpm, `~/.local/bin`, Homebrew; Windows npm script runs via
  Node) over Mirai's copy. Mirai never updates/uninstalls user installs: Update prints the user's
  `npm install -g` / `bun add -g` / `pnpm add -g` command when older than `AI_AGENT_VERSIONS` or
  Check for updates.
- **Announced metadata (`ai_agent_announced`):** stores version and `Ai_Capabilities` on
  `initialize`. Connect and Check for updates probe unprobed user adapters (`ai_probe_start`) and
  report non-ACP binaries.
- **Explicit install only** (Download, Update, `ai.install`; see
  [projects](../../mirai-projects/references/projects.md#commands)): never downloads on open, read,
  or send. Picks Bun/Node/pnpm or offers private Bun; Update reuses prior runtime; Uninstall keeps
  chats. Missing Claude Code triggers `--claude-code` first; adapter installs omit optional deps.
- **Auth & models:** Codex/Claude check `codex login status` / `claude auth status --json` and ask
  for `codex login` / `claude auth login` if signed out (`CODEX_PATH`, `CLAUDE_CODE_EXECUTABLE`,
  `ANTHROPIC_API_KEY`, `codex login --with-api-key`). Command agents launch without a shell in
  project root (`existing:true` or first auth method); removing keeps chats, continuing fails.
  Switching main-chat agent opens a new native session with [handoff](#compaction-and-handoff).
  Model/effort must match adapter options (no substitution); Codex accepts only `AI_CODEX_MODELS`.

```sh
mirai agent install codex --runtime Automatic
mirai agent install claude --claude-code
mirai agent updates all
```

## Chat flow

1. Send captures up to `AI_ENTITY_CAPACITY` selected authoring IDs and queues a free-viewport
   region capture next frame (omitted without GPU). Composer, selection, region, and chosen agent
   are project-wide; main chat follows latest `conversation.document`, subagents stay bound to
   their origin document.
2. **Steering (`ai_chat_send`, `ai_task_steer`, `ai_steer_done`):** Enter while running injects at
   the next safe point without interrupting or queuing. Unconsumed steers (no steering capability,
   dead worker, stopping, `promptRequired`/`failed`) persist as `steer` deliveries (dashed outline)
   for the next turn. Stop is the only cut; Send becomes Stop only with an empty input.
3. **Workers (`AI_WORKER_CAPACITY`):** independent ACP clients; 1 worker stays reserved for main
   chat (`ai_subagent_workers`). Processes persist between turns until provider switch or
   `AI_IDLE_SECONDS`. On a Ready client, previous sessions close before opening/recovering another;
   close errors block the next session ([cycle](../../../../editor/acp/README.md#cycle)). Up to
   `AI_TASK_CAPACITY` conversations stay in memory; finished non-pending ones evict (never main).
4. **End of turn:** agent must call `finish` once (exempt: system delivery turns and `/compact`).
   `finish_called` keeps turn `running` until ACP completes; ACP completion without `finish` fails
   the turn. Only `finish.response` renders in Markdown with pills `[Name](entity:ID)`,
   `[Name](asset:path)`, and play button `[What to try](play:path)` (`ai_play_scene`,
   `Ai.play_after`). No prompt timeout: silent note after `AI_SILENT_SECONDS`; stderr tail
   (`Ai_Task.said`) appends to errors; `_meta.codex.error` logs notes. Empty `finish` closes
   silently; `question` persists with review until next turn or confirm.
5. **Permissions (`ai_permissions.odin`):** `mirai` tools auto-allow. Codex (`ai_permission_policy`)
   rejects outside-sandbox/project actions. Claude sets `_meta.claudeCode.options.allowedTools`
   (`mcp__mirai`) and `_meta.claudeCode.options.settings` (`AI_CLAUDE_SESSION_META`: `ask` on
   deletes, `asset_delete`, `panel_delete`, `git_discard`; `allow` on `mv`). Codex writes
   `.codex/rules/mirai.rules` (`prefix_rule` `decision="prompt"`) + trusts project in
   `CODEX_CONFIG` (`ai_permission_deletes`); `apply_patch` deletes and full-path Git Bash on
   Windows bypass rules; approving a Codex delete runs unsandboxed. Pending prompts answer
   `cancelled` on Stop/correction.
6. **Plan & tool steps:** ACP `plan` replaces transient `Ai_Task.plan` (`AI_PLAN_ENTRIES`). API
   calls save `ai_tool_note` with `· ref ...` (`ai_call_refs`) for search. ACP `tool_call` /
   `tool_call_update` (`ai_tool_call_receive`) record non-MCP steps (deduping `mcp.mirai.*`,
   `mcp__mirai__*`, `rawInput.server=="mirai"`).
7. **Rejections:** document switch cancels active/queued turns; subagents cannot continue on
   another document; continuing confirms prior review; revert requires origin document. Rejects
   empty message (non-system), `>= AI_MESSAGE_BYTES`, `--no-api`, no project, invalid region,
   unsupported model/effort, full cache, archived chat, or running chat via `ai.task`.

## Subagents

`agent.spawn` creates a parallel editor subagent (kind `Agent`, `parent` = main chat) with its own
worker and [review](ai-review.md).

- **Depth 1:** valid only from a running main-chat turn (via MCP header); calling from a subagent
  fails. Cross-provider spawning (Claude <-> Codex) is supported.
- **Isolation:** bound to origin document, `Ai_Turn.detached` (no composer/selection/view), knows
  only its prompt; `finish.response` becomes its report.
- **Defaults (`ai_subagent_resolve`):** `agent.spawn` overrides > `.mirai/ai/connections.json`
  default (`same` | `fixed` | `pick`). Never substitutes an unconfigured connection.
- Panel inspects thread/review/stop/composer; Reply attaches `Ai.about` (`ai_about_note`).

## Deliveries and reports

Persistent `deliveries` (`report`, `steer`) survive editor restart.

- Subagent settle (`ai_task_settle`) adds a `.Report` line to main chat + `report` delivery (count
  of review changes, question, answer). Held steers finish before reporting; editor-closed turns do
  not report.
- Main chat consumes deliveries on next turn, or automatically in one **system turn**
  (`ai_deliveries_advance`, no user line, no `finish` needed) once idle, with no subagents working,
  no pending main-chat review, and previous turn succeeded (after fail/Stop, waits for user
  message).
- Unconsumed subagent steers launch its next turn once idle.

## What a turn sends

Three text blocks in `session/prompt` (`ai_send_task_prompt`) + reference images; `prompt.md` saves
the first two:

- **Stable block (`ai_prompt_stable`):** role, rules, `AI_PROMPT_SCHEMAS` from live registry,
  project instructions, and 2-level [memory](#memory). Sent once per native session (and after
  compaction or instruction change) so prompt caches hit.
- **Delta (`ai_prompt_write`, `ai_delta_build`):** open document, region, visible entities (selected
  first within `AI_ENTITY_CAPACITY`; off-camera selected have empty `rect`, `inside=false`; derived
  geometry grouped by authoring owner, see [viewport](panels.md#viewport)), capture, attachments,
  range, active asset/material doc, Play state, pins, annotations, `about`, active subagents,
  deliveries, handoff, and one-time `AI_COMPACT_NOTES_AT` reminder.
- **User message:** own block (empty in system turns).

Turn folder `.mirai/ai/<conversation-id>-<sequence>/` (`AI_FILE_*`): `prompt.md`, `message.md`,
`context.json`, `state.json` (paused Play + selection), `region.png` (half-res `ai_half_pixels`),
`mcp.json`.

- **Asset/material document context:** replaces scene entities with `editor.asset_document_pick`,
  `editor.asset_document_show_say`, or `Ai_Task.material`
  ([material doc](panels.md#material-document)). Material docs inject the `material.program` guide
  (always edit via `material.program.*`, never file tools).

### Assets of a message

`ai_attachments.odin`. Dropped Content Browser assets attach as chips (`AI_ATTACHMENTS`,
`Ai_Task.attachments`, `context.json` `assets`, omitted if unregistered); dropped Hierarchy entities
join selection. Timeline ranges attach via `Ai_Task.range` (`context.json` `range`, `play.history`).

### Reference images

Up to `AI_REFERENCES` images attach as chips (not imported), downscaled to fit `AI_REFERENCE_SIDE`
(`ai_fit_pixels`) into `reference-<n>.jpg` (`Ai_Task.reference_writes`), and sent as `image` blocks
in `session/prompt`; fails if `promptCapabilities.image` is false. `view_viewport` (`view.viewport`)
returns the turn's saved `region.png` on demand (`request` names an older turn; error if missing or
oversized).

## Memory

Two non-overlapping levels: versioned Markdown (durable) and SQLite (`chat.db`, queryable).

- Stable block includes `AGENTS.md` (`AI_PROJECT_MEMORY`, cap `AI_MEMORY_INDEX_BYTES`) and
  `USER.md` (`AI_MEMORY_USER_FILE` in agents home, cap `AI_MEMORY_USER_BYTES`). Topics live in
  `.agents/memory/<topic>.md` (`AI_MEMORY_FOLDER`); skills in `.agents/skills`
  (`AI_PROJECT_SKILLS`).
- `memory.save` replaces a topic, index (empty `topic`), or `user` file atomically after slug/cap
  checks (outside undo/review). `memory.search` queries derived `memory_docs` (refreshed by
  `ai_memory_scan` on open and after turns). `memory.read` allows only topic files or `USER.md`.
- Transient working notes use `chat.note` (replace-all, survives compaction in handoff).

```sh
mirai rpc memory.save '{"scope":"project","topic":"combat","text":"Parry window is 120ms."}'
mirai rpc chat.note '{"text":"Next: wire parry SFX and verify in Play."}'
```

## Compaction and handoff

Chats outlive native agent contexts.

- **Auto-compaction:** provider-driven (`compaction_update`); completion logs `AI_COMPACTED_NOTE`
  and re-sends stable block next turn. Passing `AI_COMPACT_NOTES_AT` prompts saving notes once.
- **Compact now (`ai.compact`, idle chat):** runs agent `/compact` if worker holds session and
  advertises it (no `finish`, preserves review); else drops native session for handoff.
- **Handoff (`ai_handoff_build`, `AI_HANDOFF_HEADER`):** built from SQLite without LLM (notes,
  latest messages within byte budget, ended/interrupted subagents, pending review units).
- **Reopen vs. Build restart:** reopening starts a fresh native session + handoff after
  `AI_REOPENED_NOTE`; running subagents become `interrupted`. Build restart resumes native sessions
  once (`ai_resume_native_mark`) with `AI_BUILD_RESUME`. Closing while working confirms
  ([exiting](document.md#quitting-new-and-open-with-agents-working)).

## Project data

`<project>/.mirai/ai/chat.db` (`editor/ai_store`, SQLite WAL, shared across editors, no secrets).

- **Non-blocking frames:** saves on events only. Lock contention queues writes (`ai_persist_poll`,
  flushed on close); immediate-ID writes fail on busy.
- **Tables:** conversations (`Main`, `Agent`, `Archived`), messages (sequence-keyed, FTS5 kept by
  triggers, bounded cache `AI_TRANSCRIPT_*`), `deliveries`, `notes`, `pins`, `annotations`,
  `provenance`, `meta`, `memory_docs`. Corrupt or mismatched `PRAGMA user_version` DB is reported
  with recovery steps, never deleted.
- **Titles & spend:** Codex confirms title before prompt via negotiated rename (fails if missing);
  Claude keeps initial title (`ai_session_title_update`; Claude Code 2.1 lacks `rename_session`).
  Spend comes from ACP `usage`/`usage_update` (Codex reports no cost).
- **Search (`editor/ai_store/search.odin`):** quoted phrases (safe for paths/methods), AND default,
  `OR`, BM25, optional prefix. `ai.history.search` searches all chats; empty query returns
  `INVALID_PARAMS`.
- **Attribution & scope:** MCP HTTP sends `X-Mirai-Ai-Task: <conversation-id>-<sequence>` (without
  `X-Mirai-Plugins`; non-core tools use `call` + `engine_describe`, see
  [protocol](../../mirai-agent-api/references/api.md#ai-turn-context),
  [MCP](../../mirai-agent-api/references/api.md#mcp-over-http)). Closed turns reject writes;
  post-`finish` is read-only. Subprocesses receive `MIRAI_AI_TASK=agent-<serial>` and
  `MIRAI_API_PORT` for `mirai rpc`. Scope is game-only: `.mirai/engine/<mode>/decl/` and
  `.mirai/plugins/<mode>/decl/`
  ([binaries](../../mirai-projects/references/projects.md#engine-binaries)), `panel_save`
  ([project panels](panels.md#project-panels)), `AI_GUIDES` (`editor/ai_guides.odin`,
  `ai_guide_topic_in_front`). Codex runs isolated via `AI_CODEX_SESSION_CONFIG` (`workspace-write`).
- **Play context:** turns started in Play inherit live player snapshot (`ai_state_write`,
  `play.player`, `scene.inspect` `include_runtime:true`); API edits still write document
  ([Play](editor.md#play), [API](../../mirai-agent-api/references/methods.md#play)).

## Pins, annotations and provenance

- **Pins (`ai_pins.odin`, `pins`):** pin composer chips across messages; included in every delta
  (images by path), surviving compaction.
- **Annotations (`ai_annotations.odin`, `annotations`):** viewport Annotate tool drops pins on
  surfaces/entities (never saved in scene); listed one line each in delta; read/cleared via
  `annotation.list` and `annotation.remove` (id or group).
- **Provenance (`ai_provenance.odin`, `provenance`):** records last conversation/turn per entity
  and asset on review transactions; shown in Details/asset docs and via `ai.provenance`. Pending
  review assets show marks in Content Browser.

## Agents in scene and review

`Show agents in scene` (default on, project-saved) toggles figures, glyphs, and picking.

- Uses transient [figure](editor.md#figures-of-whoever-works) (no entity); appears once turn has
  context or edits (`figure_shown`), stands beside targets (`AI_SCENE_TARGETS`) clear of gizmo and
  colliders (`presence_free_place`), looks at `Ai_Task.look`. Shared in
  [collaboration](collaboration.md#what-travels).
- Outlines (agent color for changes, faint neutral for read context) remain until confirmed or
  reverted even when figures are hidden. Each MCP edit is a normal history transaction tracked for
  [change review](ai-review.md#finish-revert-and-retry).

## Agents outside the editor

`editor/ai_external.odin`. External MCP/RPC clients pass `X-Mirai-Client`
([protocol](../../mirai-agent-api/references/api.md#ai-turn-context)).

- Creates an `Archived` chat (`external:<client>`), no worker, with figure, steps, review, and
  per-author undo. Shares user's Play and Watch; two instances of one client share the turn.
- Ends via `ai.turn_end` (called by Claude Code `Stop` hook in
  [templates](../../mirai-gameplay/references/demo.md#templates)) or `AI_EXTERNAL_IDLE`; ignores
  editor-owned turns; no `finish` tool. Next call reopens a pending-review turn; no-op turns finish
  on end. Stop ends the turn without killing the external process; messages written in its view go
  to main chat; no Retry. Calls without turn or client use `EDIT_AUTHOR_API`.

## API methods

Schemas via `engine.describe`. Task states: `queued`, `running`, `done`, `failed`, `cancelled`,
`interrupted`, plus `declined` (reverted).

| Family | Methods & key semantics |
|---|---|
| Turns | `ai.task` (main chat or subagent `conversation`, rejects running), `ai.status` (`id`/`from` adds transcript), `ai.cancel`, `ai.compact`, `ai.permission` (`index`, `option` or `cancel:true`), `ai.turn_end` |
| Review | `ai.revert` (Edit + origin doc, rejects active/`files_changed`), `ai.restore` (`declined`), `ai.review.accept`, `ai.retry` (advances frames), `finish` (`Method_Flag.Turn`, `response`/`question`) |
| Subagents | `agent.spawn` (`Method_Flag.Turn`, main chat only), `agent.list`, `agent.message` (steers running or starts turn), `agent.stop` |
| History & refs | `ai.history` (conversations or `before` message page), `ai.history.search` (BM25, `INVALID_PARAMS` if empty), `ai.provenance`, `chat.note`, `memory.search`/`read`/`save`, `annotation.list`/`remove` |
| Connections | `ai.connections` (read-only), `ai.connect`, `ai.disconnect`, `ai.agent.add`/`remove`, `ai.install` (`check`/`download`/`update`/`uninstall`/`runtime`/`cancel`), `ai.configure` (`model`/`effort`/`instructions`/`subagent_*`, writes `.mirai/ai/instructions.md`) |

```sh
mirai rpc ai.agent.add '{"name":"Local","command":"my-acp","arguments":"--stdio"}'
mirai rpc ai.connect '{"provider":"local","existing":true}'
mirai rpc ai.task '{"prompt":"Add a point light above Origin","agent":"local"}'
mirai rpc ai.status '{"id":1}'
```
