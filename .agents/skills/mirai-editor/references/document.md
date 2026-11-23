# Document, edits and selection

Code: `editor/document.odin`, `editor/documents.odin`, `editor/documents_restore.odin`,
`editor/asset_documents.odin`, `editor/edits.odin`, `editor/edits_files.odin`,
`editor/history.odin`, `editor/selection.odin`, `editor/world.odin`, and session-free
`editor/history`.

## Document and scenes

`Document`: `path` (relative to `assets/`, empty = "Untitled"), `file` (absolute), `previous`
(`asset.Scene`, keeps root order and unknown library tables), `id`, and `written` (last flushed
history state).

- `scene_open(s, path)`: stops Play, resets history/selection, loads via `scene.replace` (world
  stays intact on failure); Prefab header opens [prefab document](prefabs.md#prefab-document).
- `scene_new(s, prefab)`: untitled scene (`Sky` with `SKY_DEFAULT` + `Sun` recipe) or 1-root prefab.
- `document_write(s, file, as_document)` writes document or copy. `file_new` asks path first
  (`scene.new` takes `path`); `file_open`/`file_open_path` activate existing tab. **Only one scene**
  stays open (`document_scene_tab`) beside any number of prefabs.
- Replacing scene confirms (`Pending.Open_Scene`/New) if agents work or collab is active
  (`scene_switch_interrupts`, `scene_switch_others`); API (`editor.document`) skips confirmation.
- `document_open_tab`/`document_activate` swap between frames; windowed loads start after first
  frame with beating dot + toast line; headless/hidden/`--frames` load on startup. `document_close`
  activates and closes; `platform.dialog_show` runs one system dialog at a time. Collab guests write
  nothing and leave session to open another scene ([collaboration](collaboration.md)).

### Tabs

Each `Document_Tab` owns world, document, history, selection, camera, inspector, hierarchy, and
prefab state. AI chat ([chats](ai-tasks.md)) and project settings (reread on activate) are shared.
Generated storages hold only the active tab (swapped between frames; stops Play). Closing the last
tab opens an untitled scene; x closes without activating. Activating updates changed prefab
instances and rereads clean open prefabs if changed on disk. Restart tabs:
[restart](editor.md#build-and-reload).

### Asset documents

`editor/asset_documents.odin`; UI in [asset documents](panels.md#asset-documents); plugins use
`Asset_Document_Provider` ([extensions](extensions.md#an-asset-document)).

- `Session.asset_documents` holds open `Asset_Document` tabs (id+kind, or lone program path) with
  their own `Asset_History` (cap `ASSET_HISTORY_BYTES`, lost on close). Opening same kind reuses a
  clean front tab (`asset_document_reusable`).
- Front document (`asset_shown`, `asset_document_active`) covers the scene while scene stays active
  for API/agents/`history.*`; bringing it front stops Play/Watch/tools/gestures.
- UI writes outside a scene gesture (`file_write` -> `asset_history_front`, `files_record`/
  `files_swap`, `gesture_begin`/`end`) enter its history; externally modified files keep disk
  content on undo/redo. Assets removed from registry auto-close (`asset_documents_prune`). Reopened
  on Build restart without history.

### Quitting, New and Open with agents working

`Pending.Quit` confirms while agents work; New/Open confirm while agents work or collab is active;
closing a tab never confirms; quitting asks nothing of files since the
[Kai](kai.md#working-copy) working copy holds them. Accepting runs `ai_working_stop` (API rejects
agent calls at once)
and ends [review records](ai-review.md#the-record-and-its-capacity).

## Sections

`editor/sections.odin`. Dropping a `.scene` calls `section_place` (`Scene_Reference` + children in
one undo; disallowed in prefabs or self-reference: `"A scene cannot hold itself"`; see
[scene references](../../mirai-gameplay/references/libraries.md#scene-references)). Double-click
opens a scene.

- Referenced children are read-only in the host scene (`section_refused`, `section_target_refused`,
  `scene.write` fails with notice, no gizmo `selection_section_locked`, excluded from parent file).
- Changing `Scene_Reference.scene` or creating/pasting a reference syncs in the same step
  (`sections_sync`); unresolved `Entity` fields show expected `Id`.
- **Edit in its world (`editor.section_edit`):** dims/locks everything else (`section_locked`);
  parentless creates go inside it; shares undo. Flush saves root + modified edited sections
  (`Document_Sections.edited`, `section_save`, `Capture_Desc.section`, `Section_Member` IDs) and
  reloads sibling references outside undo; unwritable sections warn and retry. Per-tab in
  `Document.sections`.
- **Environment preview (`editor.section_preview`, `render.Environment_Preview`):** editor-only
  override of Sky/Sun/unbounded volumes; unsaved, ignored in Play.

### Section view

`editor.section_view` ([World](panels.md#world)) writes `scene.Section_Views` (`Active`/`Loaded`/
`Unloaded`/`Auto`): editor-only, outside undo, unsaved, ignored by Play.

- Loads/unloads/proxies from `scene.scene_sections` enter the journal image without a step
  (`sections_watch`, `sections_watched`, `sections_take_in`, `journal_take`); resolved/cleared
  `Entity` refs enter field-by-field (`sections_resolved`, `journal_take_field`).
- Derived edits (`Bone_Attachment`) enter via `edits_take_derived` unless a gesture is open.
  Orphans under undone references drop outside undo (`sections_orphans_drop`).

```sh
mirai rpc editor.section_edit '{"entity":"<ref>"}'
mirai rpc editor.section_preview '{"entity":"<ref>"}'
mirai rpc history.undo '{}'
```

## The file is the editor's state

`editor/edits_files.odin`.

- **`files_flush`:** runs at frame end (after 100 ms `FLUSH_WINDOW`) and API call end (immediate)
  when no gesture is open and not playing: atomically writes changed assets first, then document
  (`document_flush`); failures warn once and retry (`FLUSH_RETRY`).
- Open gesture asset writes live in `asset.registry_memory_*` (write buffer); `.slang` writes
  immediately. Undo/redo rewrite affected files. Play never writes (flushes at Stop).
- **External disk edits win:** `document_file_follow` reloads externally modified documents with a
  fresh history. Untitled docs are not written (first windowed step asks once; `keep_file`/
  `document_file_give`). Collab guests write nothing. Restarts keep only tab metadata. Test against
  an open editor on `.mirai/tmp/` copies ([AGENTS.md](../../../../AGENTS.md#verification)).

## Failures

Crash report at `<project>/.mirai/editor-crash.txt` (or `MIRAI_CRASH_REPORT`,
[platform](../../mirai-platform/references/platform.md#crashes)) ends with oldest-first
`editor/events.odin` (`<project>/.mirai/editor-events.txt`: inputs, `command_run`, API calls, undo
steps). Bounds checks stay active; `MIRAI_CHECK_WRITES` catches unrequested row writes.

## Edits and undo

`editor/history/journal.odin`, `editor/edits.odin`, `editor/edits_files.odin`.

- **Journal image:** snapshots `type_saved` tables (rows + off flags) and entity generations/
  liveness. With an `Id` table, tracks authoring rows only (skips derived rows without `Id`). Diffs
  only `core.changes` since image (full scan if `> GONE_CAPACITY` or replaced table). Commit stores
  both sides (`Step_Rows` + `held`, `Entity_Changes`); cost scales with delta; `transient` fields
  stay intact on surviving rows.
- **Independent readers:** undo/redo (`cursor`), [AI review](ai-review.md),
  [prefabs](prefabs.md) (`Edits.turns`, `Edit_Step.turned`), and
  [collaboration](collaboration.md#what-travels) (`changes`).
- **Procedures:** `edits_begin`/`edits_end`/`edits_flush` (in `editor_end`); `edits_commit` =
  `edits_prepare` + `edits_commit_prepared` (`Stale` on mismatch, `No_Change` normal,
  `external_change` for prefab/file steps); `edits_cancel_prepare`/`edits_cancel`; `undo`/`redo` vs
  `history_undo`/`history_redo` (`History_Move`); `edits_reset`, `edits_sync_initial`,
  `edits_state`; `edit_open`/`edit_close`.
- **Project files (`editor/history/files.odin`):** `file_write(s, path, bytes, label, remove=false)`
  buffers assets in registry until flush (`.slang` immediate), keeping before/after up to
  `EDITS_FILE_BYTES` (larger skips history). Undo/redo preserves externally edited files with a
  toast (`file_set` bypasses history for revision tools). Reloads via `host.app_asset_changed` /
  `files_settle`; file-only steps skip `edits_scene_state`. API writes go inside `api_edit_begin`/
  `api_edit_end`.
- **Rules:** steps save before/after selection; caps `EDITS_STEP_CAPACITY`/`EDITS_BYTE_CAPACITY`;
  derived-only commits update image without steps; dead rows in non-saved tables drop; cancel/undo/
  redo pre-reserve and `core.raw_drop` before `core.raw_put` (cancel restores generation length;
  undo/redo never shrinks it); Play edits are unrecorded; `Edits.preview` backs
  [cancelable previews](extensions.md#cancelable-previews).

### Undo by author

`editor/history.odin`. `Edit_Step.author`: `EDIT_AUTHOR_USER` (0), AI turn task ID, or
`EDIT_AUTHOR_API` (`editor.input`/`capture`/`engine.*` run as user; `Edits.opener` owns gesture;
collab remote edits have no local author).

- **Undo:** takes author's newest standing step. If top and `step_exact` holds, swaps in order;
  else reverts by IDs in a new `Edit_Kind.Undo` step via [change sets](ai-review.md#change-sets),
  counting later edits by others in `kept` (created entity leaves only if whole/unreferenced;
  deleted entity returns only if ID free; deleted-by-other stays gone).
- **Redo:** restores author's newest undo (in order, exact undo of by-IDs undo, or new
  `Edit_Kind.Redo`). New edit drops author's redo; others' in-order undone steps flip (`swapped`)
  and redo by IDs.
- Steps writing prefab files or non-POD components undo/redo in order only (fail by IDs with
  recovery guidance). Mutating API methods commit pending user gestures and cancel active tools
  first.

### Selection in undo

`editor/history/edits_selection.odin`. `edits_select` records `Selection_Step`
(`EDITS_SELECTION_CAPACITY`) at frame end, before/after API methods, and in `edits_begin` (skipped
on unchanged selection, pruning, reset, Play/Simulate/Watch). Holds no rows, does not dirty
document/collab/review/prefabs; interleaves with world steps via `made`/`state` and `undone`/
`Edits.order`. New selection drops author's redo (`edits_redo_drop`) and vice versa. UI field
gestures open on `r.began` (`inspector_sweep` closes vanished fields); gizmo drags cancel on Esc.

### Programs

Writing `.slang` runs `programs_start` into `<project>/.mirai/shaders`; undo, redo, and AI review
rewrite and republish. External `mirai build` output stays loaded until next publish.

## World edit procedures

`editor/world.odin`. Act on shown world; each is an undo step outside an open gesture. Always guard
new edit procs with `if watching(s) {return}`.

- `entity_create(s, Create_Desc)` adds `Id`, `Name` (`name_free`), `Transform`, optional `recipe`.
- `entities_delete` destroys subtrees (protects prefab members); `entities_duplicate` copies
  authoring subtrees, remaps internal refs, skips derived children.
- `entity_enabled_set` (`core.Disabled`); `component_turn` toggles non-base components (not
  `Transform`/`Name`/`Id`/`Parent`; tracked in undo); `entity_reparent` (`core.NONE` = root,
  preserves world pose, rejects cycles/zero-scale/prefab lock); `transform_set` (respects body
  owners in Play); `component_add` (`component_default`); `field_write`; `selection_group`.
- Readers: `component_table(s, name)`, `entity_world`, `entity_hidden`, `entity_get`.
- **Identity:** `core.Id` (stable hex) vs. `core.Entity` (world-local handle, preserved by Play
  copy; serialized via `entity_offsets`).

```odin
opened, ready := editor.edit_open(s, "Add prop")
if !ready {return}
defer editor.edit_close(s, opened)
e := editor.entity_create(s, {
    recipe = "cube", name = "Crate",
    transform = {position = {0, 1, 0}, rotation = 1, scale = {1, 1, 1}},
})
editor.entity_reparent(s, e, core.NONE)
```

## Recipes

Single-entity `.scene` in engine/plugin `recipes/` (`Recipes` part, `project.recipe_folders`,
`author.recipes_read`, `author.recipe_parts`). Placed as a copy (components, default rotation,
multiplied scale, height-based surface offset; lights face -Z). Authored as data with
`mirai scene write` and moved into `recipes/`. Disks show only for `entity_marked` entities (not
groups, terrain, foliage, or volumes). Sky is not a recipe (`scene_new`).

## Selection

`Selection.entities` is ordered (last = active); `serial` keys caches; `selection_roots` returns
top-level selected entities; `selection_prune(w)` removes dead handles. Highlight
(`erender.Highlight`) marks selected + descendant levels (lowered to 0, off in Play, on in
Paused/Simulate). Gestures: [viewport](panels.md#viewport), [outliner](panels.md#outliner).
