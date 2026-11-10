---
name: mirai-editor
description: The Mirai editor (package `editor`, with `editor/acp`, `editor/ai_store`,
  `editor/git`, `editor/history` and `editor/records`) - session, Play, Simulate and networked
  Play, undo (`edits_*`, the journal), viewport and tools (`tool_set`/`tool_on`), inspector,
  content browser, prefabs, collaboration (`--share`, `--join`), AI chats and extensions. Use when
  changing the editor, adding a tool or panel of a plugin, editing the scene from editor code or
  driving an open editor.
---

# Mirai editor

Engine-time package `editor` over the same generated world as the game: its data are `@(storage)`
of the `Editor_World` and its functions are `@(step)` of the `editor` loop, like those of a plugin
([architecture](../../../docs/ARCHITECTURE.md)). There is no extension registry.

## Map

- **Session, loop, arguments, Play, Watch, networked Play, Simulate, Build and reload, shortcuts**:
  [session](references/editor.md#the-session), [arguments](references/editor.md#arguments),
  [loop](references/editor.md#the-editor-loop), [Play](references/editor.md#play),
  [Watch](references/editor.md#watching-another-run),
  [networked Play](references/editor.md#networked-play), [Simulate](references/editor.md#simulate),
  [Build and reload](references/editor.md#build-and-reload) and
  [commands and shortcuts](references/editor.md#commands-and-shortcuts) (what a menu entry, a
  shortcut and a button run, and how a plugin adds its own); the past of a Play, going back to a
  tick and recording it at fixed fps: [history and recording](references/editor.md#play).
- **Documents, tabs, recovery, undo, edit procedures, selection**:
  [documents](references/document.md#document-and-scenes),
  [recovery](references/document.md#recovery-and-failures),
  [edits and undo](references/document.md#edits-and-undo),
  [edit procedures](references/document.md#world-edit-procedures) and
  [selection](references/document.md#selection); the selection as an undo step:
  [selection in undo](references/document.md#selection-in-undo).
- **Bar and panels, AI panel, viewport, picking, gizmo, outliner, Create, content browser,
  previews, import, Graphics, Project settings, Find**: [layout](references/panels.md#layout),
  [AI panel](references/panels.md#ai-panel), [viewport](references/panels.md#viewport),
  [outliner](references/panels.md#outliner), [Create](references/panels.md#create),
  [content browser](references/panels.md#content-browser),
  [previews](references/panels.md#previews), [import](references/panels.md#import),
  [Graphics](references/panels.md#graphics) and
  [Project settings](references/panels.md#project-settings).
- **World panel** (map of the sections from above and from the side, turning them on and off in
  the view, traveling, cost per section): [world](references/panels.md#world); what belongs to the
  view and does not edit: [section view](references/document.md#section-view).
- **Viewport inspection modes** (menu, Collision, mode per tab, Lit in Play):
  [inspection mode](references/panels.md#inspection-mode).
- **Project panels** (interfaces the chat agent builds, `panels/`, Tools menu):
  [project panels](references/panels.md#project-panels).
- **Viewport exposure** (Scene, Camera, manual EV100):
  [exposure](references/panels.md#viewport-exposure).
- **Studio light in a scene** (viewport option, without writing the scene):
  [studio light](references/panels.md#studio-light).
- **Editor preferences** (the machine's `editor.mirai`, one section per area, `--headless`):
  [preferences](references/panels.md#preferences).
- **Projects and launcher** (Projects screen, `--launcher`, New project, opening another project):
  [projects](references/panels.md#projects).
- **Asset documents** (tabs next to the scenes, own history, material document with preview,
  values and derived graph): [view](references/panels.md#asset-documents),
  [tabs and history](references/document.md#asset-documents); those of a plugin:
  [extensions](references/extensions.md#an-asset-document).
- **Details, rows by reflection, tags, copy and paste, collision, material**:
  [details](references/inspector.md#details),
  [reversion and review](references/inspector.md#reversion-and-review),
  [rows by reflection](references/inspector.md#rows-by-reflection),
  [copying and pasting](references/inspector.md#copying-and-pasting-values),
  [collision](references/inspector.md#collision) and [material](references/inspector.md#material);
  the particles section belongs to the `vfx` plugin
  ([vfx in the editor](../mirai-world/references/vfx-editor.md#particle_emitter-section)).
- **Connections, the main chat, workers, steering, what a turn sends, `chat.db` and its search,
  context and AI figures**: [connections](references/ai-tasks.md#connections-and-installation),
  [chat flow](references/ai-tasks.md#chat-flow),
  [what a turn sends](references/ai-tasks.md#what-a-turn-sends) and
  [project data](references/ai-tasks.md#project-data); the steps of the agent's own tools, in
  [end of the turn](references/ai-tasks.md#chat-flow).
- **Subagents, their defaults, reports and deliveries**:
  [subagents](references/ai-tasks.md#subagents),
  [deliveries](references/ai-tasks.md#deliveries-and-reports).
- **Memory, notes, compaction, handoff and reopening**:
  [memory](references/ai-tasks.md#memory),
  [compaction](references/ai-tasks.md#compaction-and-handoff).
- **Pins, annotations, provenance**:
  [pins](references/ai-tasks.md#pins-annotations-and-provenance); how the panel shows all of it
  (status line, report cards, subagent view, expanded chat, popups, marks):
  [AI panel](references/panels.md#ai-panel).
- **Attribution, Finish, Revert, Restore, Retry, persistence of the review**:
  [change sets](references/ai-review.md#change-sets),
  [finish, revert and retry](references/ai-review.md#finish-revert-and-retry) and
  [persistence](references/ai-review.md#persistence-and-capacity).
- **Git** (Git tab, init, commit, push, pull, merge mode, `git.*` methods):
  [operations](references/git.md#operations) and [merge mode](references/git.md#merge-mode).
- **Tools, panels, cards, inspection modes, API methods, inspector, asset types and thumbnails of
  a plugin**: [package rules](references/extensions.md#package-rules),
  [viewport tool](references/extensions.md#a-viewport-tool),
  [panel](references/extensions.md#a-panel),
  [asset types](references/extensions.md#asset-types-of-a-plugin),
  [create cards](references/extensions.md#create-cards),
  [inspection mode](references/extensions.md#an-inspection-mode),
  [API methods](references/extensions.md#api-methods) and
  [component with an inspector](references/extensions.md#a-component-with-an-inspector).
- **What physics and networking give the editor** (simulation providers, inspector and components;
  `core.Network` contract):
  [extensions](references/extensions.md#simulation-and-pose-confirmation).
- **The game of a plugin from Play, player processes and preferences of a plugin**:
  [extensions](references/extensions.md#a-plugins-game-and-player-processes).
- **Importing a file and the whole formats or sources a plugin adds**:
  [import](references/panels.md#import) and
  [importers](references/extensions.md#importers-of-a-plugin).
- **Linked prefabs**: [operations](references/prefabs.md#operations),
  [overrides](references/prefabs.md#overrides) and [nested](references/prefabs.md#nested-prefabs);
  variants and Apply to base, in
  [variants](references/prefabs.md#variants).
- **Shared session and the host's networked game**:
  [entering and leaving](references/collaboration.md#entering-and-leaving),
  [the host's networked games](references/collaboration.md#the-hosts-networked-games) and
  [where each one plays](references/collaboration.md#where-each-one-plays).
- **Figure of agents and editors, glyph menu, Follow, palette, pings, the editor's own assets
  (`.editor`)**: [figures](references/editor.md#figures-of-whoever-works).
- **What travels of an edit (by field), what another editor selected, agents of other editors**:
  [collaboration](references/collaboration.md#what-travels).
- **ACP transport**: [ACP client](../../../editor/acp/README.md). **Agent API**:
  [mirai-agent-api](../mirai-agent-api/SKILL.md). **Plugins**:
  [mirai-plugins](../mirai-plugins/SKILL.md).

## Workflow: changing the scene from the editor

1. Every edit of the edited world goes through an edit procedure (`entity_create`,
   `entities_delete`, `entities_duplicate`, `entity_rename`, `entity_reparent`,
   `entity_order_set`, `entity_hidden_set`, `transform_set`, `component_add`, `component_remove`,
   `field_write`, `material_assign`). Without an open gesture it is an undo step of its own; with
   one open it joins it ([edits and undo](references/document.md#edits-and-undo)).
2. A gesture (dragging a field, typing a value, moving the gizmo) goes between `edits_begin` and
   `edits_end`, of the package `editor/history` like the rest of the journal; `edits_flush`
   records it at the end of the frame. Outside the loop, `edits_commit` records immediately.
   `edits_cancel` restores the last copy only with a gesture open or pending.
3. A new edit procedure starts with `if watching(s) {return}`: what is being watched is not
   edited. What another editor of the session has selected is edited like the rest.
4. A created or copied entity has `core.Id` (`core.id_new` with `Session.id_state`), `core.Name`
   (`name_free`) and `core.Transform`; its other components appear when the loop function
   finishes.
5. A project file that an edit writes (materials, programs, particles, animation assets) enters
   its step with `file_write` and its bytes; an asset or the source of a program stays in memory,
   unsaved, until Save ([files](references/document.md#edits-and-undo),
   [programs](references/document.md#unsaved-programs)). The world of a Play, components
   whose fields are all `transient` and derived rows without `Id` do not enter the undo. Painting
   and terrain leave in the undo the reference to a revision of the asset, not the file.
6. Apply the [tables](../mirai-core/references/core.md#tables) contract from editor tools too.
7. A change to an API method, a field tag or the scene format updates `editor/api`, plugins, the
   demo and this skill in the same task.

## Invariants

- The methods of the API are the only catalog of commands: a menu entry, a shortcut and a button
  are an entry that names a method and its params, a gesture runs the handler of the method, and a
  plugin gives its method its entry ([commands](references/editor.md#commands-and-shortcuts)).
- Asset folders are thematic, never by type (the browser filters by type): what the editor
  imports or creates goes where the user is, and it creates no folder named after a type.
- State located according to [the session](references/editor.md#the-session). `Api` keeps only a
  pointer because the server must stay where it was born.
- A procedure takes the storage it reads and writes (`^Ai`, the chat store, `^Git`, `^Edits`),
  not the `Session`, when it needs nothing else. What does not need the `Session` is its own
  package under `editor/` (`acp`, `ai_store`, `diff`, `git`, `history`, `records`), and `editor`
  keeps the thin part that reaches the session; `history` declares the storages `Edits` and
  `Selection`. Files outside `ai_*.odin` do not reach the
  fields of `Ai`: they go through `editor/ai_outside.odin` and the procedures of the tasks.
- `edited_world` is the document (undo, scenes, Build); `shown_world` is that of the Play while it
  runs or what is watched in `Watch`. UI edits during a Play go to the Play's world and are not
  saved; the edit API always writes to the document.
- What is watched is not edited
  ([watching another run](references/editor.md#watching-another-run)).
- The editor has no network logic: networked play is provided by `multiplayer` through its
  `Play_Provider`; the network session lives in the world of each run and online players are
  editor player processes that the plugin opens
  ([networked Play](references/editor.md#networked-play)).
- Inspector, scenes, collaboration and API work by reflection (`core.World_Info`): a new component
  of a game or plugin appears without touching the editor.
- Notices are one-line toasts (`notify`) with the result.
- Edit tools reuse the inspector widgets: the same fields, per-property revert arrows and folded
  material parameters.
- A plugin tool is declared with `tool_set`/`tool_on`; when on, left clicks in the scene are
  its own ([extensions](references/extensions.md#a-viewport-tool)).
- A temporary result pending confirmation uses
  [cancelable previews](references/extensions.md#cancelable-previews) and checks
  `tool_preview_active` before writing each frame.
- Derived geometry without `Id` delegates selection to its owner (`entity_author`); Outliner,
  Hierarchy and duplication skip it and `entity_children` keeps it.
- A configured connection and a process are distinct states: reading connections or history does
  not start agents; installing requires an explicit action. Mirai stores no credentials: agents
  use the user's program and session, and what the editor knows about them belongs to the machine,
  not to the project ([chats and agents](references/ai-tasks.md#connections-and-installation)).
- Each turn has its worker and its review; API handlers run one at a time. Transactions (scene
  rows and project files) are attributed by the turn's header and Revert keeps later edits
  ([review](references/ai-review.md)).
- A project has one continuous chat, and the user only talks to it: no sessions to open, pick or
  start, and the word session is not in the UI. Subagents are tasks of the editor, started only
  by the main agent and never by another subagent, and one worker is never taken by them.
- Enter while an agent works steers it without interrupting and without a queue to manage; Stop
  is the only way to cut a turn. A message that cannot join the turn waits and is the next one.
- The stable instructions go once per native session and the per-turn data in a delta; the chat
  outlives its native context through the handoff, which Mirai builds without calling a model.
- Memory is two levels and never the same fact in both: Markdown for what is durable and
  versioned, `chat.db` for what Mirai queries and updates. A database that is corrupt or of
  another version is reported and never deleted.
- The agent never names its turn: its MCP server and the commands it runs carry it
  ([attribution](references/ai-tasks.md#project-data)).
- An agent outside the editor is shown and reviewed as a chat of its own, and works only while the
  editor is open ([outside the editor](references/ai-tasks.md#agents-outside-the-editor)).
- What the sections load and unload in the edited world is not an edit: it enters the journal image
  without a step, except the section that loads a reference made in a step, which belongs to that
  step ([section view](references/document.md#section-view)). What belongs to a section is
  read and not changed, except the one edited in its world.
- The figures of agents and of other editors are transient visual instances, without authoring
  entities. The editor's assets (`editor/assets`, mounted under `.editor`) do not appear in any
  project list: a new listing filters with `asset.registry_listed`.
- Undo by author: each history step has an author (the user, an AI turn by its task id, or the API
  outside a turn) and keeps both sides, what it left in the world and what was there before; undo
  and redo are per author, swapped in order when the step is the last one made and the world has
  exactly what it left, and otherwise reverted by ids in a new step of the author. The user's
  Ctrl+Z never undoes a step of another author nor overwrites a value written afterwards.
- The selection is an undo step: each distinct selection of the user (or of the API caller) is a
  step of its own author, without collapsing consecutive ones; they live in their own list of
  `Edits`, outside the journal, and are ordered against its steps by the history state they were
  made in. A new selection step discards the redo of its author, edits included.
- The agents are the user's: Mirai signs in to no agent and stores no credentials; Codex and
  Claude use the user's program and session, connecting means asking the program whether there is
  a session, and the ACP adapter is the one the user installed (Download fetches it into the
  user's folder if there is none).
- A section is edited in its world: inside the world that contains it, in the same document, with
  everything else dimmed and read-only; Save also writes the section's scene and undo is one for
  both ([sections](references/document.md#sections)).
- A guest's Play is either solo or in the host's game: in a collaboration session each editor plays
  their own copy, which does not travel, affects nobody and is shown to nobody else, or a guest
  joins as a network client of the game the host serves (Join game, `play.join`) with their seat
  and `multiplayer` prediction, and leaves whenever they want.
- Online players run the editor's library: the player processes the editor opens for a networked
  Play load the `editor` library the editor already loaded (`--library editor`) and run only the
  game's world, so a networked Play compiles nothing and server and clients run the same code.

## Verification

- `mirai check editor` and the `editor/` of the affected plugin; `mirai test editor <names>` with
  the tests of the touched `<file>_test.odin`; transport: `mirai test editor/acp`; git commands
  and what they print: `mirai test editor/git`; the journal and undo without a session:
  `mirai test editor/history`; the rows and texts of a table of game data:
  `mirai test editor/records`; the line diff: `mirai test editor/diff`. The editor's tests need
  more memory than the default limit (`MIRAI_COMPILER_MEMORY=14`).
- Commands: `editor/commands_test.odin` (every entry calls a registered method with params it
  takes, a gesture runs between frames as a step of the person, the selection is no param of an
  agent); the entry a plugin gives with its method, in `editor/api_provider_test.odin`.
- AI panel: `editor/ai_chat_test.odin` (one status line, the answers as one Markdown message with
  pills, the cards of subagents, the settings of the header gear); its image, `editor.view` with
  `Chat` and `capture` with the UI in a session, also expanded. The steps of the agent's tools,
  the models and the connections of the machine: `editor/ai_runtime_test.odin`; the popup of the
  check of connections (Linux and macOS only): `editor/ai_connections_test.odin`.
- Chat database and its search: `mirai test editor/ai_store` (reopening, search ranked and kept up
  to date, a corrupt database left alone, each table, kinds and parents, a second store on the
  same project, writes kept while another editor holds the database); the frames of a streaming
  answer with the database held, in `editor/ai_runtime_test.odin`; live, `ai.history.search` in a
  session for a word of the chat.
- Single chat, in `editor/ai_subagents_test.odin` (`mirai test editor <names>`): the main chat and
  its subagents, what a turn sends (the stable block and the delta), pins, annotations and memory,
  compaction, handoff and reopening. Steering and compaction in the transport:
  `editor/acp/client_test.odin`.
- Attribution of the agent's commands: `editor/ai_lifecycle_test.odin` and, in `tools/mirai`,
  `rpc_test.odin`; live, a command agent added with `ai.agent.add` whose turn runs `mirai rpc`,
  then `ai.status` and `ai.revert` of that turn.
- The rail, the left panel and a docked Details: `editor/shell_dock_test.odin`; its image,
  `preferences.set` of the `Layout` and `capture` with the UI.
- Project panels: `editor/panels_test.odin`. Delete permissions and the rules that Codex and Claude
  read: `editor/ai_permissions_test.odin`.
- Own conditions: `editor/ai_scene_test.odin` (GPU and validation; loads the dog of
  `editor/assets`); in `editor/acp`, the optional smoke test `editor/acp/smoke_test.odin` (real
  account, `-define:ACP_SMOKE=true` and `MIRAI_ACP_SMOKE_ADAPTER`, `_BUN`, `_CWD`, `_CODEX`).
- Sections: `editor/sections_test.odin` (the view without edits and its returned rule, the lock by
  each path and by `scene.set`, traveling, saving what changed and staying unsaved if one is not
  written, the reference a step makes and what hangs from one that left, the map and its API); its
  panel, `capture` with the UI in the World tab.
- Picking: `editor/pick_test.odin`; a click builds only what its ray reaches and the cache stays
  while other meshes change.
- Thumbnails: `editor/thumbnails_test.odin` (key, read, write and invalidation when saving the
  asset or a dependency; a provider's image between frames) and
  `editor/thumbnail_subjects_test.odin` (the stored view of a scene at each size); those of a
  plugin, in its skill ([previews](../mirai-plugins/references/previews.md#verification)); their
  image, `capture` with the UI and the content browser filtered by Animation, Prefab and Scene.
- The first undo of a stroke is tested from `plugins/terrain/editor/terrain_history_test.odin`; a
  material imported unsaved on reimport and its per-field reversion: `editor/materials_test.odin`.
- Recovery: `editor/recovery_test.odin` (the copy written by a job) and
  `editor/recovery_log_test.odin` (the chain over the saved file, a truncated log, the replay by
  `Id`, the copy that deletes the previous one, one chain per tab and all of them at startup, what
  is offered staying aside while the document is edited and saved); recovery after killing the
  process, by API in an open editor.
- Journal, undo and transactions: `editor/history/journal_test.odin` (each reader's cursors,
  steps that grow with what changed, cancellation and undo without allocating) and
  `editor/history/edits_memory_test.odin`; through the API and the inspector,
  `editor/edits_memory_test.odin`; undo by author and selection steps: `editor/history_test.odin`.
  Memory with a large scene: `journal_memory_of_a_large_scene` in
  `editor/journal_bench_test.odin` with `-define:EDITOR_JOURNAL_BENCH=true`.
- Collaboration: `editor/collab_journal_test.odin` (the journal is read and not echoed, undo at
  each end, the fields several editors change in one row, a gesture left open) and
  `editor/collab_edit_test.odin` (what another editor selected, a file too large to travel, the
  scene a guest receives when the host fails halfway).
- Prefabs: `editor/prefabs_test.odin` (an operation as one step of the rows of an instance,
  overrides derived, reverted and applied with the file unsaved, added entities and turned-off
  members, unlink and variants, a document opened after its prefab changed, an instance without
  its base, instances in collaboration); the document written onto a world:
  `engine/scene/update_test.odin`; the overrides and the node the prefab leaves:
  `asset/prefab_overrides_test.odin` and `asset/scene_test.odin`. The time of a Save and of placing
  one instance in a scene of many: `prefab_save_and_placing_in_a_scene_of_many_instances` in
  `editor/prefabs_bench_test.odin` with `-define:EDITOR_PREFAB_BENCH=true`.
- Content browser: `editor/content_test.odin`, and its image with `capture` with the UI and
  `editor.input` in a session. Create and `asset.create`: `editor/asset_create_test.odin`; rename,
  move and duplicate: `editor/asset_move_test.odin`; the empty `.ui`:
  `cook/author/records_test.odin`.
- Asset documents: `editor/edits_files_test.odin` (the files a document writes are steps of its
  own history, the tab another asset of the kind takes) and `editor/material_document_test.odin`
  (the program a material document reads, its picks for the next message, the values of a
  variant); their view in an open editor, `editor.document` (`Open` with the asset's path) and
  `capture` with the UI.
- Build and reload, recovery, networked Play (`templates/game`) and collaboration
  (`--share`/`--join`) are checked by API in an open editor. Images:
  [rendering](../mirai-rendering/SKILL.md#verification); protocol:
  [API](../mirai-agent-api/SKILL.md#verification); extensions:
  [plugins](../mirai-plugins/SKILL.md#verification).
