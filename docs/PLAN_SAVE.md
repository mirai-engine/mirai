# Plan: the save model (write-through, git index as the base)

Work in progress. The design is the owner's of 2026-11-11: every step writes the real file, no
recovery log, git mandatory with its index as the base, undo in memory per author, the git panel
shows the changed entities of a scene. Four stacked branches (each from the one before, or from
`main` once that one is merged); each leaves the editor working and its touched packages green.

## Contracts between the stages

1. **A step ends, its files are written.** One place, `files_flush`: at the end of a frame and of
   an API call, when no gesture is open (scene edits, every asset history) and no game plays, the
   document is written if its history state is not the one its file holds, and so is every asset
   file a step changed. Atomic per file, the files a scene needs before the scene. A step of
   several files is not atomic across them. A write that fails is told and tried again.
2. **Inside an open gesture a file lives in the registry** (`asset.registry_memory_*`, which
   `cook/author` also uses): a foliage brush writes its asset every frame, paint every 80 ms, the
   navmesh at every revision, and what draws them reads through the registry. It is a write
   buffer, not a state: nothing lists it, saves it or discards it, and the flush empties it.
3. **Play never writes.** The flush waits while a game plays; asset edits made meanwhile are
   written when it stops. Players in other processes read the real files (no copy of the scene).
4. **The file wins.** A document whose file changes outside the editor (git, a tool, a discard) is
   read again at the next safe point with a new history; the editor knows its own writes by the
   stamp of what it wrote. Undo and redo are steps: they rewrite the file.
5. **Every document has a file.** No Untitled document (question 1).
6. **Pending is what git says** (stage 2 on): worktree differs from the index, or untracked.
   Nothing else in the editor says whether a file has changes.

## Stages

### 1. `save-write-through`
Adds `files_flush`, the reload of contract 4, a restart that carries only the tab list.
Deletes: `recovery.odin`, `recovery_log.odin`, the journal's `logging`; `assets_unsaved.odin`,
`api_unsaved.odin` (`asset.unsaved`, `asset.save`, `asset.discard`), `editor.recover`,
`scene.save`, `editor.save_all`; `Document.saved/unsaved` as dirty, `document_dirty` and every
dot, title star and `dirty` field of the API; the Recovery, Confirm and Save_Changes dialogs, the
Save As dialog and `Pending`; the snapshots and `--restore/--dirty` of a restart;
`shaders.Overlay` and `programs_overlay`; `play_unsaved`, `saved_only`, `Pending.Play_Plugin`, the
`play.scene` copy; the `Dirty` refusal and `collab_can_save` of collaboration; "Save first" of
commit, pull and discard; `asset_unsaved_refusal` of move; the dirty-documents loop of the delete
check (registry dependents are enough); `session_unsaved` and `--discard` of `mirai session`;
the Save and Discard hooks of terrain, foliage, paint and `ui.write save`, with their tests.
A copy with a repeated id gets its own id written to its file at once. The build refusal over
rows of a dropped component stays: the open documents are the files now.
The Save commands go; Ctrl+S comes back in stage 2 as Keep.

### 2. `save-git-base`
A project is a repository: creating one initializes it (editor, `mirai`, templates); opening one
without it, or without git installed, shows what to do (Initialize repository in the editor; the
command in a headless start) and edits nothing until then. `git.Change` says pending and kept;
Keep (Ctrl+S: the document in front with the files its steps wrote; Keep all) is `git add`;
Discard is `git restore` from the index, an untracked file goes to the trash; tabs show the dot
of a pending file. On open with pending files and on close: the list, keep or discard per
document or all. Deletes: `left_out`, discard to `HEAD`, `init_later` as an option.

### 3. `save-entity-tree`
The git panel opens a pending scene as a tree of entities added, changed and removed against
`git show :path`, by entity id, with the removed ones where the index had them; revert on a
node puts that subtree back from the index as a step of whoever asks (undoable). API:
`git.changes {path}` and `git.revert {path, entities, subtree, author}`; with `author`, only
what that author's steps of the in-memory history did to them. Reuses `asset.scene_merge`'s
reading of documents by id and `history.Change_Set`.

### 4. `save-agent-review`
The review of a turn is its steps in the history (`Ai_Review.states`), not copies. Accept ends
it. Reject validates per entity: firm when another author touched it after; a created entity
stays when another author parented under it or references it; what stays is listed with why.
Deletes: the copied transactions, the review files on disk (`Ai_Review_Disk`, save, load,
reconcile), the field-level keep. Removes this plan.

## Open questions (default first)

1. **New scene.** File > New and `scene.new` create `Untitled.scene` (numbered) beside the open
   scene at once; Save As becomes Duplicate in the browser. Other: ask for the name first.
2. **Collaboration guest.** Each peer writes through into its own checkout: the snapshot carries
   the path, a join is refused while the guest has that file pending. Other: the guest keeps
   everything in memory and only the host writes (keeps an overlay alive for guests).
3. **Commit.** It commits what is kept; with nothing kept it keeps everything first. The "leave
   out" checkbox goes: Unkeep is `git restore --staged`. Other: commit always takes everything.
4. **Close through the API** (`engine.shutdown`, `mirai session stop`): pending stays pending,
   no question, no `discard` flag. The window asks: Keep all, Discard all, Cancel, per document.
5. **Accept of an agent's turn** only ends the review; it does not stage (the file may hold the
   user's pending changes too). Other: accept stages the files the turn touched.
6. **`AGENTS.md`, the line about `scene.save`.** Proposed: "Against an open editor every edit is
   written to its file: work on a copy under `.mirai/tmp/` (`asset.move` with `copy`), never on
   a versioned asset."
7. **`.git` growth.** Every Keep of a changed binary leaves a loose object until `git gc`.
   Decided after measuring: nothing, or `git gc --prune=now` when the editor closes.

## Measurements (once, in the stage that brings them; dev build; table in the report)

- Stage 1: ms of a step's flush on the largest demo scene (capture, encode, write apart), and on
  a generated scene of 50 000 entities, since the demo scenes are about 20 KB; the hitch of the
  frame that flushes. Over a frame budget: capture on the frame, write in a job.
- Stage 2: ms of `git add` on the largest demo asset the editor writes and on the largest file
  of the demo (`sky_day.hdr`, 20 MB); bytes `.git` grows after 20 keeps of each; ms of the
  `git status` that feeds the tab dots.
- Stage 3: ms to read the index version of the largest scene and build its tree.

## Also updated

Skills `mirai-editor` (document, editor, panels, git, collaboration, prefabs, ai-review),
`mirai-assets`, `mirai-agent-api` (methods, api), terrain, foliage, ui-inspector, shaders;
the `docs/game` pages that say Save; `AGENTS.md` (question 6); the project memory after stage 2.

## Not verified by this work

macOS and Linux runs; a shared session over the network between two machines.
