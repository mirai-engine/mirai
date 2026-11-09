---
name: mirai-editor
description: The Mirai editor (package `editor`, with `editor/acp`) - session, Play, Simulate and
  networked Play, undo (`edits_*`), viewport and tools (`tool_set`/`tool_on`), inspector, content
  browser, prefabs, collaboration (`--share`, `--join`), AI chats and extensions. Use when changing
  the editor, adding a tool or panel of a plugin, editing the scene from editor code or driving an
  open editor.
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
  [shortcuts](references/editor.md#shortcuts-and-actions); the past of a Play, going back to a
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
- **Shared session and the host's Play**:
  [entering and leaving](references/collaboration.md#entering-and-leaving),
  [watching the host's play](references/collaboration.md#watching-the-hosts-play) and
  [where each one plays](references/collaboration.md#where-each-one-plays).
- **Figure of agents and editors, glyph menu, Follow, palette, pings, the editor's own assets
  (`.editor`)**: [figures](references/editor.md#figures-of-whoever-works).
- **Lock on what another editor selected, agents of other editors**:
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
   `edits_end`; `edits_flush` records it at the end of the frame. Outside the loop,
   `edits_commit` records immediately. `edits_cancel` restores the last copy only with a gesture
   open or pending.
3. A new edit procedure starts with `if watching(s) || edit_held(s,e) {return}`: what is being
   watched and what another editor of the session has selected are not edited.
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

- Asset folders are thematic, never by type (the browser filters by type): what the editor
  imports or creates goes where the user is, and it creates no folder named after a type.
- State located according to [the session](references/editor.md#the-session). `Api` keeps only a
  pointer because the server must stay where it was born.
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
- A guest's Play is either solo or in the host's game: in a collaboration session each guest plays
  their own copy, which does not travel nor affect anyone, or joins as a network client of the
  game the host serves (Join game, `play.join`) with their seat and `multiplayer` prediction, and
  leaves whenever they want.
- Online players run the editor's library: the player processes the editor opens for a networked
  Play load the `editor` library the editor already loaded (`--library editor`) and run only the
  game's world, so a networked Play compiles nothing and server and clients run the same code.

## Verification

- `mirai check editor` and the `editor/` of the affected plugin; `mirai test editor <names>` with
  the tests of the touched `<file>_test.odin`; transport: `mirai test editor/acp`. The editor's
  tests need more memory than the default limit (`MIRAI_COMPILER_MEMORY=14`).
- AI panel: the line diff, `mirai test editor/diff`; the thread as Markdown and multi-line messages,
  `ai_answers_are_one_markdown_message_with_the_entities_they_name_as_pills`; the steps of the
  agent's tools,
  `ai_codex_models_are_restricted_and_tools_of_the_agent_are_steps_once_they_end`. Its image,
  `editor.action` `ai_chat` and `capture` with the UI in a session.
- Chat database and its search: the `ai_store_*` tests of `editor/ai_store_test.odin` (reopening,
  search ranked and kept up to date, a corrupt database left alone, the import of the files of
  before it, each table, kinds and parents, a second store on the same project); live,
  `ai.history.search` in a session for a word of the chat.
- Single chat, in `editor/ai_subagents_test.odin` (`mirai test editor <names>`):
  `the_main_chat_is_restored_with_its_transcript_and_never_evicted`,
  `a_subagent_runs_in_its_own_conversation_and_keeps_the_view_of_the_user`,
  `agent_spawn_works_only_from_a_running_turn_of_the_main_chat`,
  `what_a_subagent_runs_with_follows_the_explicit_values_and_the_default_of_the_project`,
  `a_finished_subagent_reports_and_what_waits_becomes_one_system_turn_of_the_idle_chat`,
  `a_message_to_a_working_chat_joins_its_turn_or_waits_for_the_next_one` and
  `one_worker_is_never_taken_by_a_subagent`.
- What a turn sends and its memory, in the same file:
  `the_stable_block_is_the_same_each_turn_and_goes_once_per_native_session`,
  `the_stable_block_goes_again_after_a_compaction`,
  `the_delta_has_what_waits_what_is_pinned_and_who_works`,
  `the_delta_names_pins_and_annotations_every_turn_without_images_even_after_a_compaction`,
  `a_pinned_chip_stays_over_the_composer_once_it_leaves_the_message`,
  `annotations_outlive_the_editor_and_the_agent_reads_and_clears_them`,
  `memory_save_stays_in_its_files_and_within_its_caps` and
  `the_memory_index_catches_what_is_edited_outside_the_editor`.
- Compaction, handoff and reopening, in the same file:
  `a_full_context_asks_for_notes_once_per_native_session`,
  `without_the_command_compacting_starts_a_new_native_session_with_a_handoff`,
  `the_compact_command_runs_as_a_turn_that_needs_no_finish_and_keeps_the_review`,
  `a_handoff_says_what_the_context_before_it_left` and
  `reopening_starts_a_clean_context_unless_a_build_restarted_the_editor`. Steering and compaction
  in the transport, in `editor/acp/client_test.odin`:
  `acp_initialize_announces_compaction_and_reads_steering`,
  `acp_steer_joins_the_running_turn_and_is_answered_by_id`,
  `acp_steer_failures_do_not_end_the_turn`, `acp_steer_requires_the_announcement` and
  `acp_session_commands_track_compact_until_a_session_opens`.
- The panel of the single chat, in `editor/ai_chat_test.odin`:
  `ai_chat_has_one_status_line_and_no_new_chat_button`,
  `ai_a_finished_subagent_is_a_card_in_the_thread_of_the_main_chat`,
  `ai_a_subagent_is_inspected_from_its_own_view_and_written_to` and
  `ai_chat_settings_use_the_header_gear_for_connections_and_scene_agents`; its image,
  `capture` with the UI in a session, also expanded.
- Attribution of the agent's commands: `an_agent_command_is_attributed_to_the_turn_its_agent_runs`
  and, in `tools/mirai`, `the_commands_of_an_agent_call_its_editor_in_its_context`; live, a command
  agent added with `ai.agent.add` whose turn runs `mirai rpc`, then `ai.status` and `ai.revert` of
  that turn.
- The rail, the left panel and a docked Details: `editor/shell_dock_test.odin`; its image, `preferences.set` of the
  `Layout` and `capture` with the UI.
- Project panels: `panels_read_back_what_they_write`,
  `panel_buttons_set_their_fields_as_one_step`,
  `panels_are_kept_in_the_project_and_deleted_with_their_file` and
  `panel_restore_puts_back_what_it_changed`. Import:
  `an_import_that_writes_programs_publishes_the_programs_of_the_project` and
  `a_source_outside_the_project_goes_into_the_folder_asked_for`. Delete permissions:
  `deleting_files_is_asked_of_the_user_and_moving_them_is_not` and
  `codex_trusts_the_project_to_read_its_rules_and_claude_gets_them_as_settings`.
- Connections: `ai_connections_of_codex_and_claude_belong_to_the_machine_and_stay_lazy` (two
  projects, a user folder, what an `initialize` announced);
  `codex_is_asked_for_the_sign_in_of_the_user_and_mirai_signs_in_to_nothing` and
  `ai_connections_check_keeps_its_popup_and_update_starts_without_confirmation` (Linux and macOS
  only).
- Own conditions: `ai_scene_figures_render_as_transient_geometry_and_reuse_descriptors` (GPU and
  validation; loads the dog of `editor/assets`); in `editor/acp`, the optional
  `acp_codex_smoke_uses_the_requested_model_and_existing_account` (real account,
  `-define:ACP_SMOKE=true` and `MIRAI_ACP_SMOKE_ADAPTER`, `_BUN`, `_CWD`, `_CODEX`).
- Sections: `editor/sections_test.odin` (the view without edits and its returned rule, the lock by
  each path and by `scene.set`, traveling, saving what changed and staying unsaved if one is not
  written, the reference a step makes and what hangs from one that left, the map and its API); its
  panel, `capture` with the UI in the World tab.
- Picking: `editor/pick_test.odin`; that a click builds only what its ray reaches and the cache
  stays while other meshes change,
  `a_pick_builds_only_what_its_ray_reaches_and_keeps_it_while_other_meshes_change`.
- Stored thumbnails: `stored_thumbnails_last_until_their_asset_or_what_it_needs_changes` (key,
  read, write and invalidation when saving the asset or a dependency); a provider's images between
  frames, `a_provider_image_is_drawn_between_frames_after_the_frame_that_asked`.
- `edits_sync_initial` is tested from `plugins/terrain/editor`:
  `terrain_initial_asset_revision_is_the_baseline_of_the_first_undo`.
- Imported material unsaved on reimport and its per-field reversion:
  `an_imported_material_keeps_unsaved_changes_over_an_import_and_goes_back_by_field`.
- Recovery: `recovery_copy_is_written_by_a_job_and_read_back` and
  `recovery_log_writes_each_step_over_the_saved_file_and_puts_them_back` (the chain over the saved
  file, a truncated log, the replay by `Id` and the copy that deletes the previous one); one chain
  per tab and all of them at startup,
  `every_tab_with_changes_keeps_its_chain_and_a_start_recovers_them_all`; what is offered stays
  aside while the document is edited and saved,
  `a_pending_recovery_stays_aside_while_the_document_is_edited_and_saved`; recovery after killing
  the process, by API in an open editor. Prefab records in collaboration:
  `prefab_records_of_one_editor_reach_the_others_in_the_order_of_the_host`.
- Journal, undo and transactions: `editor/journal_test.odin` (each reader's cursors, steps that
  grow with what changed, cancellation and undo without allocating,
  `collaboration_reads_the_journal_and_does_not_echo_what_it_applies`,
  `undo_at_each_end_keeps_what_the_other_end_wrote_since`) and `editor/edits_memory_test.odin`.
  Undo by author and selection steps: `editor/history_test.odin`. Memory with a large scene:
  `journal_memory_of_a_large_scene` with `-define:EDITOR_JOURNAL_BENCH=true`.
- The scene a guest receives:
  `a_scene_of_the_host_that_fails_halfway_leaves_the_world_as_it_was`.
- Prefabs: `editor/prefabs_test.odin`; the added entities and the turned-off members of an
  instance, incremental observation with undo and redo, refresh, apply and revert, in
  `prefab_instances_add_entities_and_turn_members_off_through_updates_apply_and_revert`; variants,
  in `prefab_variants_follow_their_base_and_apply_to_it`; records with undo and redo of each step,
  `prefab_records_follow_every_step_the_history_holds`; the edits of another editor,
  `prefab_edits_of_another_editor_mark_overrides`; the node the prefab leaves, in `asset`,
  `prefab_node_that_leaves_takes_what_hangs_from_it_and_what_named_it_names_none`.
- Thumbnails: the stored view of a scene,
  `the_view_of_a_scene_is_kept_at_each_size_and_shown_where_it_already_is`; those of a plugin, in
  its skill ([previews](../mirai-plugins/references/previews.md#verification)); their image,
  `capture` with the UI and the content browser filtered by Animation, Prefab and Scene.
- `edits_sync_initial`, from `plugins/terrain/editor`:
  `terrain_initial_asset_revision_is_the_baseline_of_the_first_undo`. A material imported unsaved
  on reimport:
  `an_imported_material_keeps_unsaved_changes_over_an_import_and_goes_back_by_field`.
- Journal, undo and transactions: `editor/journal_test.odin` (with
  `collaboration_reads_the_journal_and_does_not_echo_what_it_applies` and
  `undo_at_each_end_keeps_what_the_other_end_wrote_since`), `editor/edits_memory_test.odin` and,
  for undo by author, `editor/history_test.odin`. Memory with a large scene:
  `journal_memory_of_a_large_scene` with `-define:EDITOR_JOURNAL_BENCH=true`.
- Scene settings: `editor/scene_settings_test.odin`, with
  `a_change_to_the_sky_travels_to_the_other_editors_of_a_session` and
  `the_review_of_a_turn_keeps_and_reverts_the_settings_of_the_scene_it_changed`. The scene a guest
  receives: `a_scene_of_the_host_that_fails_halfway_leaves_the_world_as_it_was`.
- Prefabs: `editor/prefabs_test.odin`, with
  `prefab_instances_add_entities_and_turn_members_off_through_updates_apply_and_revert`. Content
  browser: `editor/content_test.odin`, and its image with `capture` with the UI and
  `editor.input` in a session. Create and `asset.create`: `editor/asset_create_test.odin`,
  `content_shows_empty_folders_and_the_line_of_create` and
  `a_right_click_on_a_folder_creates_an_asset_named_in_place`; rename, move and duplicate,
  `editor/asset_move_test.odin`; the empty `.ui`,
  `an_empty_interface_is_a_root_box_that_grows_to_the_surface` in `plugins/ui_inspector/editor`.
- Asset documents: `files_an_asset_document_writes_are_steps_of_its_own_history`,
  `another_asset_of_the_kind_in_front_takes_its_tab_while_it_has_no_history`,
  `the_document_of_a_material_reads_its_program_and_gives_its_picks_to_the_next_message` and
  `a_value_of_a_variant_is_a_number_a_bool_or_its_components`; their view in an open editor,
  `editor.document` (`Open` with the asset's path) and `capture` with the UI.
- Build and reload, recovery, networked Play (`templates/game`) and collaboration
  (`--share`/`--join`) are checked by API in an open editor. Images:
  [rendering](../mirai-rendering/SKILL.md#verification); protocol:
  [API](../mirai-agent-api/SKILL.md#verification); extensions:
  [plugins](../mirai-plugins/SKILL.md#verification).
