# Plan: the save model (write-through, git index as the base)

Work in progress. The design is the owner's of 2026-11-11: every step writes the real file, no
recovery log, git mandatory with its index as the base, undo in memory per author, the git panel
shows the changed entities of a scene. Four stacked branches (each from the one before, or from
`main` once that one is merged); each leaves the editor working and its touched packages green.

## Contracts between the stages

1. **A step ends, its files are written.** One place, `files_flush`: at the end of a frame and of
   an API call, when no gesture is open (scene edits, every asset history) and no game plays, the
   asset files a step changed are written, then the document if its history state is not the one
   its file holds. Atomic per file; a step of several files is not atomic across them. A write
   that fails is told once and tried again.
2. **Inside an open gesture an asset file lives in the registry** (`asset.registry_memory_*`,
   which `cook/author` also uses): a foliage brush writes its asset every frame, paint every
   80 ms, the navmesh at every revision, and what draws them reads through the registry. It is a
   write buffer, not a state: nothing lists it, saves it or discards it, and the flush empties
   it, 100 ms after the file last changed. The Slang source of a program is written at once.
3. **Play never writes.** The flush waits while a game plays; asset edits made meanwhile are
   written when it stops.
4. **The file wins.** A document whose file changes outside the editor (git, a tool, a discard) is
   read again at the next flush with a new history (`document_file_follow`); the editor knows its
   own writes by the stamp of what it wrote. Undo and redo are steps: they rewrite the file.
5. **A document without a file is not written.** File > New asks for the file first; `scene.new`
   takes a `path`. A document without one (no start scene, the last tab closed, `scene.new`
   without `path`) asks a person once at its first step; File > Keep in a file gives it one.
6. **A guest of a shared session writes nothing**: its host does. What the session gave the
   guest stays in its registry while it is in and goes when it leaves.
7. **Pending is what git says** (stage 2 on): worktree differs from the index, or untracked.
   Nothing else in the editor says whether a file has changes.

## Stages

### 1. `save-write-through`
Adds `files_flush`, `document_file_follow`, `document_file_give`, a restart that carries only
the tab list. Deletes the recovery log and its copies, the unsaved state of assets with its API
(`asset.unsaved`, `asset.save`, `asset.discard`), `editor.recover`, `scene.save`,
`editor.save_all`, every dirty mark and `dirty` field, the Recovery and Save_Changes dialogs
and the questions about unsaved changes, Save and Save As, the shader source overlay of
`cook/shaders`, `saved_only` and the question before a network Play, the `Dirty` refusal of a
join, "Save first" of commit, pull and discard, `session_unsaved` and `--discard` of
`mirai session` (`--force` ends an editor that does not answer). Ctrl+S comes back in stage 2.

### 2. `save-git-base`
A project is a repository: creating one initializes it (editor, `mirai`, templates); opening one
without it, or without git installed, shows what to do (Initialize repository in the editor; the
command in a headless start) and edits nothing until then. `git.Change` says pending and kept;
Keep (Ctrl+S: the document in front with the files its steps wrote; Keep all) is `git add`;
Discard is `git restore` from the index, an untracked file goes to the trash; tabs show the dot
of a pending file. Commit takes what is kept and, with nothing kept, keeps everything first; the
"leave out" checkbox goes (Unkeep is `git restore --staged`). On open with pending files and on
close of the window: the list, keep or discard per document or all. `engine.shutdown` and
`mirai session stop` leave what is pending as it is. Deletes: `left_out`, discard to `HEAD`,
`init_later` as an option.

### 3. `save-entity-tree`
The git panel opens a pending scene as a tree of entities added, changed and removed against
`git show :path`, by entity id, with the removed ones where the index had them; revert on a
node puts that subtree back from the index as a step of whoever asks (undoable). API:
`git.changes {path}` and `git.revert {path, entities, subtree, author}`; with `author`, only
what that author's steps of the in-memory history did to them. Reuses `asset.scene_merge`'s
reading of documents by id and `history.Change_Set`.

### 4. `save-agent-review`
The review of a turn is its steps in the history (`Ai_Review.states`), not copies. Accept ends
it and stages nothing. Reject validates per entity: firm when another author touched it after;
a created entity stays when another author parented under it or references it; what stays is
listed with why. Deletes: the copied transactions, the review files on disk (`Ai_Review_Disk`,
save, load, reconcile), the field-level keep. Removes this plan.

## Open

- `.git` growth: every Keep of a changed binary leaves a loose object until `git gc`. Nothing is
  done at close for now; decided after the measurement of stage 2.

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
`mirai-assets`, `mirai-agent-api` (methods, api), terrain, foliage, ui-inspector, shaders; the
`docs/game` pages that say Save; `AGENTS.md` (the line about working against an open editor);
the project memory after stage 2.

## Not verified by this work

macOS and Linux runs; a shared session over the network between two machines; GPU tests and
captures while the owner uses the GPU.
