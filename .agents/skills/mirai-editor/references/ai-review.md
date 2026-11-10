# Review of agent changes

Each unit (the main chat and each subagent) has its own record of scene and project file changes,
`Ai_Task.review`, of its last turn:

- The server attributes each request by the turn's `X-Mirai-Ai-Task` header and, after the
  handler, copies only the rows of its new undo steps
  ([protocol](../../mirai-agent-api/references/api.md#ai-turn-context)): it reads the
  [journal](document.md#edits-and-undo) from its cursor, the state from before the call. The
  frame's global changes are not attributed to the running agent.
- The record keeps its own before and after of those rows, canonical: it survives the undo
  history, which discards steps, and is saved with the chat. The steps of a turn's calls belong to
  the turn: the agent's `history.undo` undoes only its own
  ([undo by author](document.md#undo-by-author)).
- Handlers run one at a time on the main thread; the ACP workers work in parallel.
- Each recorded transaction also says who last changed every entity and asset it touched
  (`ai_provenance_record`), which [Details](panels.md#ai-panel) and `ai.provenance` read.
- Per authoring component it keeps the previous and the later value, whether it was off by itself
  before and after, the entity's `core.Id`, the component's name and the hash of its schema.
  Turning a component off or on without changing its value is a change of the turn. Turning the
  entity off is the row of its `core.Disabled`, like that of any component
  ([disabled entities](../../mirai-core/references/core.md#disabled-entities)).
- `core.Entity` references are kept as authoring ids and resolved against the current world on
  restoring.
- `changed_ids`: the ids the turn really changed. `pending` keeps the outlines until the user
  resolves the review.
- Derived rows and transient fields do not enter.
- **Files.** The turn's steps bring the files its calls wrote through the API (`.mat`, `.slang`,
  `.particle`, animation assets: [files in the history](document.md#edits-and-undo)). Per
  transaction the project path is kept and what the file had before and after (or that it did not
  exist); `changed_files` lists them in the order the turn changed them. An asset or a program is in
  memory, unsaved: Revert and Restore change that memory (a program publishes again) and the project
  does not change until Save.
- **Code.** The project files the agent changes with its own tools (code, shaders, the manifest;
  everything but `assets/`, which belongs to the API, and the dot folders) enter when the turn
  ends, as one more transaction (`editor/ai_code.odin`): at the start each file is taken by path,
  size and date, with its content once in `Ai.code` for all the running turns, and at the end they
  are compared. They are reverted one by one or with the turn, and each reversion is an undo step.
  If another turn later changed the same file, the one that ends second notes it in its chat, and
  reverting the file in the first is rejected naming the other while the file has what the second
  left. A file larger than `AI_CODE_FILE_BYTES`, or beyond the record's capacity, stays out:
  `files_changed` and the turn is not reverted whole.
- The AI panel's walkthrough passes, after the entities, through the files of the turn awaiting
  review, one at a time, with revert and accept ([AI panel](panels.md#ai-panel)).

## Change sets

`editor/history/changes.odin`, shared with the undo of an author who reverts a step of theirs
after steps of others; `editor/changes.odin` puts the files of a set, which are edits of the
session:

- `Change_Set` (`state`, `rows`, `files`) is a transaction: `Change_Row` by id and component and
  `Change_File` by project path. `change_set_take(s, set, step, history, limit)` adds to it what a
  step did: the first step that changes a row or a file gives the before and the last the after. It
  partly fails with a component that is not plain data or beyond `limit`.
- `change_sets_apply(s, sets, forward, label)` puts the scene before the sets (`forward` false,
  from newest to oldest) or as they left it, inside the open gesture, and counts what stayed as
  another left it. `entities_named_keep` is the dependency rule, the same one `step_exact` uses.

## Finish, Revert and Retry

**Finish.** The `finish` MCP tool closes the agent's work. The Finish action confirms the result:
it keeps the scene, releases the record and outlines and keeps the chat, without asking the model
anything or creating an undo step. Resolving a review lets the main chat take the reports that
waited for it ([deliveries](ai-tasks.md#deliveries-and-reports)). `ai.review.accept` confirms
without changing the chosen conversation; a question without changes is also confirmed.

**Revert** declines the turn, walking its transactions in reverse order (`ai_review_apply`
backward):

- It restores only the fields the turn changed and whose current value matches the one it left. A
  field another wrote afterwards is kept and counts as a skipped conflict; the other fields of the
  same component are restored. If the agent wrote a field before and after another writer, it
  restores its last write up to the other's value and skips the earlier one.
- A component's off state is reverted like a field (`core.raw_disable` or `raw_enable`, on the next
  settle). A component the turn added is removed only if it keeps the value and off state it left;
  one it removed returns with its own.
- An entity created by the turn is deleted only if all its authoring components match the recorded
  creation and no kept entity depends on it. A deleted one is recreated with its authoring id if
  that id does not exist, without replacing an entity that reused its index: first the identities
  are created and then `Parent` and the other references are resolved.
- A file returns to what it was before (or is deleted if the turn created it) only if it keeps
  what the transaction left; otherwise it is kept and counts as skipped.
- The complete reversion, scene and files, is one undo step. It removes outlines and indicator even
  with conflicts and keeps the record: the turn is left declined (`declined`) and the chat adds
  `AI_DECLINED_NOTE` with **Restore** (`ai.restore`).

**Restore** (`ai_task_restore`) walks the record forward with the same rules: it writes the
agent's value where the earlier one remains, recreates what it created, deletes again what it
deleted if it remains as it was and keeps what others wrote afterwards. It is an undo step and the
changes are pending again, with outlines and figure (`AI_RESTORED_NOTE`). Accepting releases the
record; a new message or a new change of the same turn discards the declined one. `declined` is
saved with the chat.

**Partial resolution:**

- An entity is accepted or reverted alone. Reverting it (`ai_review_entity_revert`) walks its rows
  from newest to oldest with the Revert rules. A field returns, from its before row in Details, to
  the value from before the turn's first step, even if the turn changed it several times; what
  another wrote afterwards is kept and counts as skipped.
- Resolving removes rows from the record: accepting an entity deletes its rows (also those of one
  created or deleted by the turn), reverting a field stops recording it and a row without
  differences leaves. An entity without rows leaves `changed_ids` and loses its outline; a turn
  without entities or files stops requesting review. The review file is rewritten on the next save.
- A file is accepted (`ai_review_file_accept`) or reverted (`ai_review_file_revert`: it returns to
  what it was before the turn's first step if it keeps what the last one left, in one undo step); in
  both cases it leaves the record.
- An entity created by the turn is not reverted alone: it belongs to the turn's Revert.

**Deletions:**

- What a turn deletes is deleted: the agent, the saved scene and the Play no longer have it. With
  the review pending it is drawn where it was, only as an outline of the agent's color
  (`ai_scene_ghosts`: one `outline_only` instance per deleted entity with `Mesh_Renderer`, with the
  previous values and its parent), rebuilt when a review or the scene changes. The agent's figure
  is placed next to the last thing it deleted.
- Details shows the entity as it was, read-only (`ai_review_deleted_details`), as long as the
  selection remains as the walkthrough left it (`Ai.review_shown` and the selection's serial). Its
  bar **accepts** it (it stays deleted and leaves the record) or **returns** it
  (`ai_review_entity_restore`: it recreates it with its id and previous components, off as they
  were, in one undo step). Its parent must be in the scene: what hung from it is returned
  afterwards, one at a time.

**Walkthrough and marks:**

- `Ai.marks` keeps the rows of the entity Details shows; it is rebuilt only when that entity or
  `scene_serial` change, which advances with each change of a review.
- The walkthrough passes through `changed_ids` and then through the files (`ai_review_walk`,
  forward and backward).
- **Details of an entity a turn changed** (`editor/ai_review_details.odin`) is the usual Details
  with the entity as it is, which is what allows accepting it: its name above and not what Details
  does not list (`Name`, `Id`, `Parent`), with the fields the turn changed in its agent's color and
  their arrow back (`ai_review_field`). On top, a strip with a line of the agent's color, the
  walkthrough arrows with which of the changes it is, ✕ (reverts the entity) and ✓ (accepts it).
- Accepting or reverting the entity in view moves to the next change (`ai_review_resolved`);
  without more changes, a returned deletion stays selected.
- **Over the composer**, the review of the unit shown, folded, says how many changes remain, with
  Revert all and Accept all. A finished subagent also offers it in its report card, and the
  status line, the bar and the expanded chat count it. Unfolded, one row per change with git's
  letter (A created, M changed, D deleted), up to `AI_CHANGE_ROWS` and the rest with scroll. A click on a row walks to it; with the
  pointer over the row or with the walkthrough on it appear its ↶, which reverts only that change,
  and its ✓, which accepts it. Reverting an entity the turn created takes it out of the scene with
  what hangs from it. Without changes to review the review is not shown and ends as with Accept
  all.
- On finishing, the thread says how: `Reviewed · N kept · M reverted` (or only one of the counts),
  with what was accepted and reverted one by one (`Ai_Task.kept`, `rejected`) plus what remained on
  accepting all; Revert all leaves "Rejected changes" with Restore.
- The unit's row in the status line says how many changes await review; while the agent works, it
  carries the beating dot.

**Retry**, API-only: it reverts an unconfirmed review and repeats the request in the same chat; if
it was already confirmed, it repeats without reverting. It also reverts the record's files; with
`files_changed` it is rejected and asks to resolve them.

- `files_changed` combines an ACP `kind=edit` tool event with a change of the source fingerprint
  (`game/`, `editor/`, `plugins/` or `shaders/`) at the end; it is not a filesystem record.
  `needs_build` reports a code change (`game/`, `editor/`, `plugins/`); one in `shaders/` does not
  ask for Build: the editor publishes the project's programs when the turn ends, as when the API
  writes them.
- Restoring scene changes requires `Edit`, the original document and a complete record.

## Persistence and capacity

- The last turn of each chat is saved atomically in
  `.mirai/ai/chats/<conversation-id>.review.json`, versioned (`AI_REVIEW_VERSION`; another version
  is not read): the record (rows with presence, value and off state of each side, and files with
  their content and a relative path inside the project), terminal or interrupted state,
  confirmation, last request, region, ids of the sent context, icon, color and position of the
  indicator.
- The turn's name must match the sequence of the last request: an earlier record is not attached to
  a newer request. The sequence is recovered from the `user_message` annotation of the history,
  also after several visual turns in a row without a text answer.
- On reopening, components are resolved by name and their hash is checked; a layout change or an
  invalid row is reported without applying bytes over another type. A row is invalid if its bytes
  do not match its presence, or if it turns a side off without the component or a component of the
  entity's base.
- `ai_review_reconcile`, on loading and on each `document_opened`, follows the scene (values and off
  state) and the files it is read with: with what the turn had before (it was closed without
  saving) it is left declined with `AI_UNSAVED_NOTE` and Restore; with what the turn left it
  returns to review even if it was declined; with part, it stays as the record says.
- A `running` or `queued` turn returns as `failed` and starts no process; a subagent the editor
  closed on returns `interrupted` ([reopening](ai-tasks.md#compaction-and-handoff)). If the editor
  closed with the dialog, its changes reach as far as Save or Discard stopped it
  ([exiting](document.md#exiting-with-changes-or-agents-working)).
- The record has a cap of rows and bytes (`AI_REVIEW_ROW_CAPACITY`, `AI_REVIEW_BYTE_CAPACITY`; a
  file counts as one row). On reaching it the review is left incomplete, and the turn keeps the
  history states of each step it confirmed (`Ai_Review.states`): Revert and Restore take those
  steps from the undo history, without the record's cap, one per step and by ids, like the
  [undo by author](document.md#undo-by-author). If the history already released any, or the
  incomplete record was read from disk, Revert does not undo a part and says so. The per-entity
  review walks what entered the record.
- Reservations and serialization happen in transactions or loads; the stable frame only consumes
  prepared ids and states. The saved JSON has a cap and is checked before reading. Each read, poll
  and write uses its own virtual scratch (`AI_REVIEW_SCRATCH_CAPACITY`), released on finishing,
  outside the frame's temporary allocator. The initial load stops polling on filling the
  conversation cache.
