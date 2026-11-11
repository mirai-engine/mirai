# Document, edits and selection

Code: `document.odin`, `documents.odin`, `documents_restore.odin`, `asset_documents.odin`,
`edits.odin`, `edits_files.odin`, `history.odin`, `selection.odin` and `world.odin`; the journal,
the steps and the selection are the package `editor/history`, which knows nothing of the session.

## Document and scenes

`Document` is the open scene or prefab:

- `path`: relative to `assets/` if inside it; `file`: absolute. A document without a file has an
  empty `path` and is called "Untitled".
- `previous`: the `asset.Scene` it was read with or last wrote; it keeps what the `World` does
  not store (order of the roots, library tables the project does not have).
- The asset id and `written`, the history state its file holds.

Procedures:

- `scene_open(s, path)`: replaces the edited world with a scene, by file or by path under
  `assets/`; one whose header says Prefab is a
  [prefab document](prefabs.md#prefab-document). Stops a Play, starts a new history and
  deselects. It loads with `scene.replace`, like the game: if reading, instantiating or copying
  fails, memory included, the world stays as it was.
- `scene_new(s, prefab)`: a document without a file with two entities, `Sky` (with `SKY_DEFAULT`)
  and `Sun` (the sun recipe), or a prefab with one empty root, without history.
- `document_write(s, file, as_document)`: writes the world; with `as_document` it becomes its
  file; otherwise it is a copy (what the players of a game read).
- `file_new`: asks for the file first, then replaces the active document with a new one there
  (`scene.new` takes it as `path`).
- `file_open`, `file_open_path`: open a tab or activate the one that already has that file. **Only
  one scene** is open at a time, alongside any number of prefabs: another scene takes the tab of
  the open one (`document_scene_tab`), in the place of the one it replaces.
- Before replacing the scene it asks (`Pending.Open_Scene`, and `New` likewise) if agents are
  working (they are stopped) or if there is a shared session: the host's guests receive the new
  scene and lose what they were doing; a guest leaves the session (`scene_switch_interrupts`,
  `scene_switch_others`). The API (`editor.document`) does not ask.
- `document_open_tab`, `document_activate`: open or activate the document's world between frames.
- `document_close`: activates the tab and closes it; the file already holds what the document had.
- File dialogs are the system's (`platform.dialog_show`), one at a time. In collaboration a guest
  writes nothing and does not open another scene without leaving the session
  ([collaboration](collaboration.md)).

### Tabs

- Tabs share the window and the UI context. Each `Document_Tab` keeps world, document, history,
  selection, camera, inspector, hierarchy and prefab state. The AI chat is one per project, not
  per tab ([chats](ai-tasks.md)).
- The generated storages contain only those of the active document; the swap happens between
  frames. Changing document stops the Play.
- Undo acts on the front tab: each scene, a prefab too, has its `Edits`, with its selection
  steps, and each asset document its history. Closing the last tab leaves a new scene without a
  file.
- The active tab joins its background with the contextual toolbar; the inactive ones sit lower and
  separated. Hover lights the whole tab; the x adds a circular background.
- Closing has its own target and does not activate the tab.
- If they do not fit, the side arrows and the wheel scroll the strip. Activating a document
  reveals its tab; scrolling does not change the active one.
- Clipped controls take up only their visible part in the window's native regions; the rest of the
  bar keeps dragging the window.
- On activating a scene, the instances whose prefabs changed are updated, with their overrides. An
  open prefab without changes of its own is reread if its file changed; with changes it is kept.
- The project settings are shared and are reread on activating a world.
- The tabs a Build restarts the editor with are in [restart](editor.md#build-and-reload).

### Asset documents

`asset_documents.odin`; the view is in [asset documents](panels.md#asset-documents).

- `Session.asset_documents` has an `Asset_Document` per open asset (id and type, or the absolute
  path of the source of a lone program) with its `Asset_History`.
- **Replacement:** opening another asset of the type of the front document opens it in that tab if
  it has no steps or gesture (`asset_document_reusable`); otherwise it opens another. An already
  open asset brings its tab.
- One in front (`asset_shown`, `asset_document_active`) covers the scene, which remains the active
  one: the API, the agents and `history.*` act on it, and its agents keep working.
  Bringing it to the front stops the Play or what is watched, drops the tools and ends the
  gestures; a user Play, watching another run, New, Open, a Find result or a scene tab bring the
  scene.
- **Own history:** what its UI writes outside a scene gesture (`file_write`, by
  `asset_history_front`) is a step of its history, with the side of each file before and after the
  gesture, as in the scene (`files_record`, `files_swap`). An open scene gesture (the API, a tool)
  keeps its own. Field gestures (`gesture_begin`, `gesture_end`) open and close the document's.
  Undo and Redo walk that history; a file that another changed afterwards keeps its content. It has
  a cap (`ASSET_HISTORY_BYTES`) and is lost on closing.
- **Closing:** drops the history. Closing the front one brings the previous one and, without
  another, the scene. A document whose asset leaves the registry is closed
  (`asset_documents_prune`).
- The restart after Build reopens the asset tabs and the front one, without their history.
- A plugin opens its types with an `Asset_Document_Provider`
  ([extensions](extensions.md#an-asset-document)).

### Quitting, New and Open with agents working

- Quitting while an agent works asks first (`Pending.Quit`), and so do New and Open of a scene
  while agents work or a session is shared. Closing a tab asks nothing: its file holds it.
  Quitting with [pending changes](git.md#pending-and-kept) lists them, to keep or discard.
- The dialog says how many agents are working and how many changes await review. Accepting stops
  the agents first (`ai_working_stop`), and from that moment the API rejects their calls; Cancel
  lets them work. The review ends with the editor:
  [the record](ai-review.md#the-record-and-its-capacity).

## Sections

A `.scene` dropped into the scene is a
[reference](../../mirai-gameplay/references/libraries.md#scene-references) (`section_place`,
`sections.odin`): an entity with `Scene_Reference` and its section loaded below it, in one undo
step. In a prefab it cannot be done; a scene is not placed inside itself. Opening a scene is a
double click in the content browser.

- What hangs from a reference is edited in its scene: in this one it is read and not changed by
  any path. The edit procedures reject it (`section_refused`, and `section_target_refused` for
  what would go below a reference or something of its own) with a notice that names the section and
  its scene; `scene.write` fails with that text;
  the gizmo does not appear (`selection_section_locked`) and Details shows it disabled. The
  document's file leaves the section out.
- A loaded reference whose `scene` changes (inspector, API) reloads the section in the same step,
  and one that a step makes (paste, duplicate, add the component) loads its own in that step
  instead of what was copied with it: `sections_sync` runs before each commit of the gesture and
  of the API. While its step is not recorded, the view asks for it unloaded.
- An `Entity` field waiting for a section that did not load is shown as such, with the `Id` it
  expects; choosing another entity stops waiting for it.
- **Edit in its world** (the pencil of the Details header on the root of a section, or
  `editor.section_edit`): its entities are edited in the scene that contains it; everything else is
  dimmed in the outliner and read-only (`section_locked`), and what is created without a parent
  goes inside it. It stays on while edited. Undo is the scene's.
- **The flush** writes the root and the scene of each section edited in its world since the
  document was opened (`Document_Sections.edited`) whose capture differs from its file
  (`section_save`, `Capture_Desc.section`, with the `Id`s of that scene kept by `Section_Member`),
  also after stopping editing it. A section that cannot be written (turned off with dormant
  changes, loading) warns, and the next flush tries again. The other references to that scene load
  it again outside of undo.
- Sections belong to each document (`Document.sections`): changing tabs does not carry along the
  one being edited.
- **Environment preview** of a section: the sun of the Details header on its root (or
  `editor.section_preview`) draws its `Sky` and its `Sun` instead of the enabled ones and takes the
  look of the view (exposure, tint) from inside its box, where its unbounded volumes rule
  (`render.Environment_Preview`), only in the editor view: it is not an edit nor saved, and Play
  starts without it.

### Section view

Turning on, off or leaving loaded and off a section in the editor view (the
[World](panels.md#world) tab, `editor.section_view`) is not an edit: it does not enter undo, is not
saved and Play starts with what the references ask for.

- What the view asks for goes in `scene.Section_Views` of each tab's world, which
  `scene.scene_sections` reads before what the reference asks or transmits: the reference does not
  change, Play does not copy it and opening another scene empties it. The editor is its only
  writer: the view, the edited section (on while edited) and a reference that made a gesture, which
  waits unloaded until its step loads it (`sections_watch`, `sections_sync`).
- What the sections load, unload, turn off or wake in the edited world during
  `scene.scene_sections`, and their proxies, enters the journal image without a step
  (`sections_watched`, `sections_take_in`, `journal_take`): no user edit carries it along and
  collaboration does not send it. Edits do not happen during that step, so what the edited section
  loaded also enters.
- The document's `Entity` fields that the loading of a section resolves, or that its unloading
  leaves at `NONE` (`Unresolved_References.resolved`, from what the sections did in the frame),
  enter the image field by field (`sections_resolved`, `journal_take_field`): the user's next step
  does not contain them and their undo does not change them.
- What a library derives in Edit on a document entity (where a `Bone_Attachment` puts its entity)
  enters the image the same way (`edits_take_derived`), except with an open or pending gesture,
  which keeps it as the user's: the next step does not contain it and the document is not left
  with changes.
- What hung from a reference that no longer lives (an undo that did not have it) is destroyed
  outside undo, and the view forgets it (`sections_orphans_drop`).

## The file is the editor's state

What the editor has is what its files hold.

- **A step ends, its files are written** (`files_flush`, `edits_files.odin`, the one place): at the
  end of a frame and of an API call, when no gesture is open and no game plays, the asset files a
  step changed are written, then the document if its history state is not the one its file holds
  (`document_flush`). Each file is atomic; a step of several is not atomic across them. A write
  that fails is told once and tried again. At the end of a frame the document, like a file, waits
  a short window after it last changed, so steps that follow one another cost one capture of the
  world; the end of an API call does not wait.
- **Inside an open gesture an asset file lives in the registry of the assets**
  (`asset.registry_memory_*`): what draws it reads through the registry, and the flush writes it
  100 ms after it last changed, so what a tool keeps writing during a stroke reaches the disk
  once. It is a write buffer, not a state. The `.slang` source of a program is written at once.
- **Undo and redo are steps**: they rewrite the files they change.
- **Play never writes**: the flush waits while a game plays and writes at stop the asset edits
  made meanwhile. Players in other processes read the files as they are.
- **The file wins**: a document whose file changes outside the editor (git, a tool) is read again
  at the next flush, with a new history (`document_file_follow`); the editor knows its own writes
  by the stamp of what it wrote.
- **A document without a file is not written.** File > New asks for the file first and `scene.new`
  takes `path`, which must not exist; without it the document has none. In a window, the first
  step of a document without a file asks once where to keep it, and File > Keep in a file
  (`keep_file`, `document_file_give`) gives it one.
- **A guest of a shared session writes nothing**: its host does. What the session gave the guest
  goes when it leaves ([collaboration](collaboration.md)).
- **A restart** of the editor (after a Build, after a GPU loss) carries only the tabs, with their
  selection and camera; the files hold the documents
  ([restart](editor.md#build-and-reload)).
- To try or verify something against an open editor, work on a copy under `.mirai/tmp/`: every
  edit is written to its file ([AGENTS.md](../../../../AGENTS.md#verification)).

## Failures

- The launcher configures `<project>/.mirai/editor-crash.txt` as the crash report, unless
  `MIRAI_CRASH_REPORT` indicates another; it is kept on reopening and a later failure replaces it
  ([platform](../../mirai-platform/references/platform.md#crashes)).
- The report ends with the events before the failure, oldest first (`editor/events.odin`,
  `<project>/.mirai/editor-events.txt`): keys and buttons with their modifiers and where, the
  entries a person ran (`command_run`), the API methods and the document steps with their label
  and author, to relate an input to the method and the procedure that failed.
- Odin's bounds checks stay active in the build. `MIRAI_CHECK_WRITES` diagnoses world writes that
  did not request their row; it costs and is not for measuring.

## Edits and undo

`Edits` is the edited world's journal (`history/journal.odin`) and keeps rows, not operations
with an inverse:

- **Image.** What the world had the last time the journal took it: the rows of each table the
  scene stores (`type_saved`: some non-`transient` field, or none, like a tag), per entity and
  with whether they were turned off by themselves, and of the entities, the generation of each
  index and whether it lives. It is the only copy of the world the editor keeps.
- With an `Id` table the image has only the authors' rows: entities with a current `Id` or in the
  image (this keeps an author's deletion). Derived rows without `Id` do not enter the steps, even
  if they belong to serializable components like `Mesh_Renderer`. Without an `Id` table, all enter.
- **What changed** is told by `core.changes` of each table since what the image saw: the rows
  stamped since then and the entities whose row left or was turned off; only those are compared with
  their row in the image. A table with rows the image did not see (more than `GONE_CAPACITY` gone,
  a replaced table) is compared whole, per entity.
- A **commit** carries to a step both sides of what changed: the differing rows (`Step_Rows`: what
  they were, a value or no row, and what the step left, `held`), by index the born or gone
  entities (`Entity_Changes`: generation and whether it lives, of each side); the image takes what
  they are. The cost of a step and of the commit grows with what changed, not with the scene.
- Each step has an author and undo is per author ([undo by author](#undo-by-author)). Undo and
  redo in order swap the step's rows and entities with those of the world; a row that remains keeps
  its `transient` fields.
- **Readers**, each with its cursor: undo and redo (`cursor` in `steps`), the
  [review of an AI turn](ai-review.md), the [observation of prefabs](prefabs.md) (`Edits.turns`,
  `Edit_Step.turned`) and [collaboration](collaboration.md#what-travels) (its place in `changes`,
  which keep what each row held before the image took it while it reads).

Procedures:

- A gesture goes from `edits_begin(edits, selection, label)` to `edits_end`, and `edits_flush` (in
  `editor_end`) records it at the end of the frame.
  `edits_begin` returns `false` if it could not reserve the selection; opening another with one open
  keeps the first.
- `edits_commit` records immediately, in two phases: `edits_prepare` computes the delta and makes
  all reservations without moving anything, and `edits_commit_prepared` publishes without
  allocating if world, history and selection are as at preparation (otherwise, `Stale`). A failure
  leaves the gesture open to retry or cancel. `external_change` allows a step without differing
  rows when a prefab operation changes records or files. `edits.error` in `No_Change` is normal;
  the others are rejections.
- `edits_cancel_prepare` reserves what a cancellation needs before writing the world;
  `edits_cancel` returns it to the image with an open or pending gesture, and without a gesture
  keeps it.
- `undo` and `redo` are in order and of the author in `Edits.author`; `history_undo` and
  `history_redo` (`history.odin`) proceed by ids when in order is not possible and return a
  `History_Move`.
- `edits_reset` forgets the history after replacing the world. `edits_sync_initial` makes the image
  take the initial values resolved from assets and rejects any existing history. `edits_state` is
  the stamp that `Document.written` compares; a step that left the in-order redo does not count.
- `edit_open(s, label) -> (opened, ready)` and `edit_close(s, opened)` (`edits.odin`) are the
  pattern of an edit procedure: it opens a gesture only if there is none, prepares its
  cancellation and closes it only if it opened it; whoever writes checks `ready`. With the Play
  in view, edits go to that world without history.

**Project files** (`edits_files.odin`; what a step keeps of a file, `history/files.odin`). A
file that an edit writes or deletes (a `.mat`, the `.slang` source of a program, a `.particle`,
an animation asset) is part of the step of its gesture, with the same mechanism for all:

- `file_write(s, path, bytes, label, remove=false)` changes (or deletes) the file as an edit:
  inside the open gesture or in a step of its own. With an asset document in front and without an
  open scene gesture, the step belongs to that document ([asset documents](#asset-documents)).
  Whoever writes an asset serializes it to bytes (`asset.material_bytes`, `asset.document_bytes`,
  the `effect.particle_bytes` of `vfx`) and passes it that way.
- **An asset of the folder waits in the registry until its step ends**: it goes to the registry's
  in-memory files and what reads the file (`file_contents`, `file_read`, `asset_read`,
  `host.assets_file`) sees that content; the flush writes it
  ([the file is the state](#the-file-is-the-editors-state)). Content equal to the disk's is no
  change. `file_exists` answers with the same.
- The other files, such as the `.slang` source of a program, are written immediately.
- The step keeps, per file, what was there before the gesture's first write and what the last one
  left; one that ends up the same leaves the gesture and one larger than `EDITS_FILE_BYTES` is
  written without history. Cancelling the gesture returns its files.
- Undo and redo put the other side only if the file keeps the one the step left; one that another
  program changed afterwards keeps its content and a toast says so.
- `file_set` writes the same outside the history, for an editor that keeps the file's undo itself
  (the terrain revisions); from then on, the step that created that file puts its side even if the
  file has other content.
- After changing, the asset is reloaded where it is loaded (`host.app_asset_changed`) and a
  `.slang` publishes the project's programs in a job; what undo, redo and a cancellation change is
  taken in `files_settle`, at the end of the frame and of each API call.
- A step that only changed files does not count as a scene change: `edits_scene_state`, what
  `Document.written` and the prefabs compare, skips it.
- An API call that writes files registers them between `api_edit_begin` and `api_edit_end`: so the
  step exists when the call ends and is attributed to the AI turn. During a Play the files change
  without a step.

Rules:

- A step keeps the selection from before and after; undoing restores the previous one and prunes
  what no longer lives.
- The history has a cap of steps and bytes (`EDITS_STEP_CAPACITY`, `EDITS_BYTE_CAPACITY`) and
  discards the oldest first. A new step discards what its author undid.
- Tables the scene does not store have no step: after an undo or a cancellation the rows of the
  entities that no longer live are removed, only at the indices that changed, and their owners
  derive the rest. A `World_Transform` without a local `Transform` is withdrawn; with `Id`, the
  restored handles without any row are also released.
- With `Id`, a commit of only derived changes updates the image without creating a step or
  advancing the document's state. An author's undo keeps the live derived rows; it does not restore
  ids of generated meshes already withdrawn.
- A step without changes is not recorded. Without memory for its step, base, redo and serial stay
  as they were and the gesture remains open. An API method reserves the cancellation before writing
  and, if it cannot record the step, returns world and selection and answers the error.
- Cancelling, undoing and redoing reserve before restoring; the restoration does not allocate. On
  changing generations the rows of the old handles are removed (`core.raw_drop`) before putting
  the restored ones: there are never two rows of one entity. The cancellation puts the missing rows
  immediately (`core.raw_put`) and the generations return to the image's length. Undo and redo do
  not shorten generations: an index born in the step stays free with another, and an entity that
  leaves always changes generation.
- With a Play running, `edits_commit` does not record the edits of the Play's world.
- The [cancelable previews](extensions.md#cancelable-previews) use `Edits.preview`:
  finishing a field does not close the gesture; confirming leaves a step and cancelling
  also restores the selection.

### Undo by author

Ctrl+Z is `history.undo` as the user: it undoes the last step of whoever asks, even if others
edited afterwards, without overwriting what another wrote later.

- **Author** (`Edit_Step.author`). `Edits.author` is that of what changes now: `EDIT_AUTHOR_USER`
  (0) in the editor; while an API method runs, the task id of its AI turn (`X-Mirai-Ai-Task`) or
  `EDIT_AUTHOR_API`, and afterwards it returns to the user. `editor.input`, `capture` and
  `engine.*` run frames and editor input as the user and do not change it. It stays with the front
  document on changing tabs. A gesture belongs to whoever opened it (`Edits.opener`). What arrives
  from a collaborator is not a step of whoever receives it.
- **Undo.** Takes the author's newest step that is still standing (done, not reverted and not an
  undo).
  - If it is the last step done and the world has what it left, it is swapped as usual and the
    cursor goes down: the scene returns exact, also to "no changes". `step_exact` checks it: each
    row, off state and entity as its `held` side; the entities that leave, whole and without a
    remaining author naming them; those the other side names, alive afterwards.
  - Otherwise it reverts it by ids in a new step of the author (`Edit_Kind.Undo`, with the step's
    state in `target`), with the [change sets](ai-review.md#change-sets): a field, the
    presence of a component and its off state return only if they keep what the step left; what
    another wrote afterwards stays and is counted (`kept`). An entity the step created leaves only
    whole and without children or references of others; one it deleted returns with its id if it is
    free; one that another deleted afterwards does not return.
  - The step stays reverted (`reverted`) and in its author's redo (`undone`: the order of the
    undo).
- **Redo.** Brings the step taken by the author's newest undo: in order if it is the first undone
  (`steps[cursor]`), or by undoing in order the by-ids undo that reverted it if that undo is the
  last step done; otherwise by ids in a new step (`Edit_Kind.Redo`) that represents it from then
  on. A by-ids redo that changes nothing leaves the step standing again.
- **New steps.** A new edit by an author discards what that author could redo. What others undid in
  order stays before the new step, reverted and with the sides swapped (`swapped`), and its redo
  continues by ids. An undo or redo by ids does not discard anyone's redo.
- A step that wrote a prefab file, which the instances of the scene follow, or that changed
  components that are not plain data goes only in order: by ids it fails and says what to do
  instead.
- The labels and state of Undo and Redo, `status`, `editor.inspect` and the counters of `history.*`
  are the author's.
- Before an API method that can edit (all but the read-only ones, `engine.*`, `editor.input`,
  `capture`, `editor.select`, `camera.set` and `finish`), the user's pending gesture is
  recorded as a step of theirs, with its tools cancelled (a gizmo drag goes back); a gesture the
  method ended is recorded on return.

### Selection in undo

`history/edits_selection.odin`.

- `Edits.selected` is the selection as the history knows it. A step (`edits_publish_prepared`),
  undo, redo and cancel leave it there; `edits_select` makes a step of its author (`Selection_Step`)
  of what differs. It runs at the end of the frame, before and after each API method (what
  `editor.select` selects belongs to the caller) and in `edits_begin`: what was selected before a
  gesture is a step of its own, and what is selected inside the gesture is part of its step.
- It is not a step: the same selection again, one that only lost entities that left (pruning, a
  collaborator who deleted), the first after `edits_reset` (opening another scene), nor what is
  selected in the world of a Play, Simulate or what is watched.
- Selection steps have no rows: they do not change the document's state nor are they read by
  collaboration, the review of a turn or the prefabs. Own cap (`EDITS_SELECTION_CAPACITY`).
- Undo takes the author's selection step if it was made after the world step it would take (`made`,
  the `serial` of then, against the `state` of that step); redo, if its undo was later (`undone`,
  of the same `Edits.order`). A new selection step discards its author's redo (`edits_redo_drop`),
  and a new edit, the redo of their selections.

UI gestures: an inspector field opens its gesture on starting (`r.began` of the numeric field) and
closes it on finishing; `inspector_sweep` closes at the end of the frame that of a field that
stopped being built. The gizmo opens one per drag; Escape returns the initial transformations and
ends without a step.

### Programs

- A write of a `.slang` source publishes the project's programs in a job (`programs_start`, to
  `<project>/.mirai/shaders`); generation reads the files. Undo, redo and the review of a turn
  rewrite the file and publish.
- A `mirai build` of another process generates from the files and the editor loads that
  generation until the next publication.

## World edit procedures

In `world.odin`. They operate on the shown world (during a Play, the Play's); each is an undo step
except inside a gesture. What their signatures do not say:

- `entity_create(s, Create_Desc)` gives `Id`, `Name` and `Transform`; `recipe` puts the
  components, rotation and scale of [that recipe](#recipes). A repeated name takes the first free
  number (`name_free`, from the name's final number, in linear time).
- `entities_delete` also destroys what hangs from it and does not touch members of a prefab
  instance.
- `entities_duplicate` copies with the authoring children, with internal references pointing to the
  copy and the next free name (`Cube 3` gives `Cube 4`); it omits derived children without `Id`,
  which its library regenerates.
- `entity_enabled_set` adds or removes `core.Disabled`, which turns off the entity and what hangs
  from it; `component_turn` turns a component off or on without losing its values and does not act
  on the base (`Transform`, `Name`, `Id`, `Parent`). Undo keeps per row whether it was off by
  itself.
- `entity_reparent` (`core.NONE` for root) keeps the world pose; it fails if the parent is the
  entity or hangs from it, if a parent without size on an axis cannot contain it, or due to a
  prefab lock.
- `transform_set` writes the local `Transform`; during a Play it leaves to the owner the row that
  another component owns (a body).
- `component_add` without a value uses the initial one (`component_default`: `NAME_DEFAULT`,
  `name_default()` or zeros). `field_write` writes bytes into the field of each entity that has the
  component. `selection_group` puts the selected roots under a new group at their center.
- Reading: the `entity_*` and `component_table(s, name)`, the table by the name that scenes and API
  use. `entity_world` includes what moved this frame, `entity_hidden` also looks at ancestors and
  `entity_get` sees a turned-off component.

**Identity.** `core.Id` is the stable id of a scene entity (hexadecimal in API and files);
`core.Entity`, index and generation, is valid only inside a world. The selection keeps handles and
is valid between editing and playing because the Play's copy preserves them. The `core.Entity` of
components travel as `Id` in scenes, collaboration and API (`entity_offsets`).

## Recipes

A recipe is what Create, a `preset` of `scene.write` and `entity_create` make an entity of: a
`.scene` of one entity in `recipes/` of the engine or of an active plugin that declares the
`Recipes` part (`project.recipe_folders`, read by `author.recipes_read`). The name of its file is
the name a document gives; its entity's name is the label of its card and the name of what it
makes. What is placed is a copy of that entity, not a link: its components
(`author.recipe_parts`, the entity placed and taken away in the same world), its rotation unless
one is given, and its scale times the one given. Its height is how far above the surface Create
puts something with no body; the placed position is always the one given. Recipes are data: they
are written with `mirai scene write` and their files are moved into `recipes/`; a value computed
in code is not one, so the cameras hold the lens and follow of their `engine/camera` mode and the
sun the rotation from `SUN_DIRECTION` as numbers. Lights shine toward their -Z.

An entity without a body is seen and picked as a disk in the viewport only if its icon says what
it is (a light, a camera, a sound, a plugin's card; `entity_marked`). A group, or an entity whose
components show themselves (a terrain, a foliage, a volume), carries no disk, like an empty object
in other editors, and is picked in the outliner. The sky is not a recipe: a new scene is born with
a `Sky` entity and a `Sun` (`scene_new`).

## Selection

- `Selection.entities` keeps the order of choice; the last is the active one. `serial` advances
  with each change and is the key of what depends on the selection (highlight, inspector).
- `selection_roots` gives the selected ones without a selected ancestor, what is moved, duplicated
  or deleted as a whole; `selection_prune(w)` forgets what no longer lives.
- Selecting does not enter the history, but each step remembers the selection from before and
  after. Gestures in [viewport](panels.md#viewport) and [outliner](panels.md#outliner).
- Highlight in `erender.Highlight`: one level for what is selected and another for what hangs from
  it; it is added to the meshes and lowered to 0, not removed. During a Play nothing is
  highlighted; while paused and in Simulate it is.
