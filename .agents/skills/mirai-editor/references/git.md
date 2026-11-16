# Git in the editor

Version control with the installed `git`, without branches: the Git tab of the left panel
(`editor/git_panel.odin`), the commands and what they print (package `editor/git`, which knows
nothing of the session), what the operations need of the session (`editor/git.odin`) and the
`git.*` methods of the API (`editor/api_git.odin`). Which assets git merges and diffs through
`mirai`, the `.gitattributes` and the drivers of a clone:
[git and assets](../../mirai-assets/references/cli.md#git).

## Operations

- An operation is a list of git commands that run one at a time as child processes
  ([`subprocess.start`](../../mirai-std/references/subprocess.md) with pipes); `git_poll` follows
  them between frames and in a headless editor's
  loop, without blocking. On finishing, the state is read again (`status --porcelain=v2`, `log`,
  the remote).
- Without anyone asking (`git_schedule`) these run: the first check on opening the project; a
  `fetch` every `GIT_FETCH_SECONDS` in an editor with a window, with a remote and outside a merge,
  silent if it fails and without opening the credential manager (`GCM_INTERACTIVE=never`), so that
  ↓N says what arrived; and a state read when something it shows may have changed (a file that
  changed, an agent review, the window regaining focus, the tab opening): at once with the tab in
  view, and at most every `GIT_STATUS_SECONDS` with it hidden, since the tabs of the documents
  show what is pending.
- Commands run with `GIT_TERMINAL_PROMPT=0`: git does not ask for credentials on the console; a
  missing authentication is an error of the operation and the system's credential manager provides
  them.
- Paths are relative to the repository root and the scope is the project folder
  (`git rev-parse --show-prefix`): a project inside another repository, like `demo` inside the
  engine, sees and commits only its own.
- **Initialize** writes `.gitignore` (`.mirai/`) if missing and the `.gitattributes` with the
  kinds of the engine and of the project's plugins (`build.git_attributes`, with LFS when ticked);
  then `git init -b main`, the drivers in the local configuration (`build.git_settings`),
  `git lfs install --local` and the `origin` remote; last it keeps everything the project holds,
  which is the base from then on: nothing of a new repository is pending. A project created on the
  [projects](panels.md#projects) screen runs it when the first read finishes (`git_init_later`),
  and `mirai new` makes its project a repository the same way when it is in none.
- Each state read sets in the local configuration the drivers that are missing or are not this
  engine's (a clone, an engine that moved).
- **Commit** first writes what the editor holds (`files_flush`) and takes what is kept; with
  nothing kept it keeps every change under the project first. **Push** sets the upstream the first
  time.
- A state read yields to what the user asks: Pull, Push, Commit or Abort cut it and the state is
  read again on finishing (`git_working` says whether something that changes the repository runs).
- **Pull** (`pull --no-rebase`) requires everything committed: so every conflict is between two
  commits and the asset merge resolves it. What the driver could not join leaves the repository in
  merge and the editor in merge mode, with the Git tab marked.

## Pending and kept

The index of git is the base of what the editor wrote; nothing else in the editor says whether a
file has changes.

- A file is **pending** while the work tree has what the index does not (changed, removed, or not
  tracked) and **kept** while the index has what the last commit does not; a file kept and changed
  again is both. The tab lists them under CHANGES and KEPT, and the tab of a document shows a dot
  while its file is pending (`git_pending`).
- **Keep** adds to the index (`git add`), **Unkeep** takes out of it and leaves the file as it is,
  **Discard** asks and puts the file back from the index (`git restore`); a file git does not
  track goes to the trash, and a document whose file is gone closes. Each takes paths or, with
  none, everything under the project; it reads the changes first (`git.takes`), so a path that has
  nothing to do is skipped. They write what the editor holds first and do not run in a merge.
  The documents follow their files with the next flush
  ([the file wins](document.md#the-file-is-the-editors-state)).
- Ctrl+S keeps the document in front and the files its steps wrote (`git_keep_front`);
  Ctrl+Shift+S keeps everything.
- The editor lists the pending changes it finds when it opens, to keep or discard them before
  starting, and again before it ends (`git_read`, `git_quit_ask`, `Modal.Pending`); the editor
  ends once what the dialog asked succeeded, and what git refused is told and the editor stays.
  The API ends the editor without asking: what is pending stays pending.
- The paths of a command go to git on its stdin, never on its command line, which holds few.
- **A project in no repository edits nothing**: a window shows Initialize repository or Quit
  (`Modal.No_Repository`), a headless editor says so once on stderr, and the methods that edit
  fail saying `git.init` (`git_missing`).

## The entities of a pending scene

`editor/git_entities.odin`.

- A pending scene unfolds in the tab into the entities that differ from what the index holds of
  it (`git show :path`), by their ids: added, changed (with the components that differ) and
  removed, under those they hang from. The document in front is compared as the World has it
  (`document_capture`), another scene as its file; `asset.document_diff` matches the rows, so two
  layouts of a component compare by the names of their fields. The place of an entity among its
  siblings alone is no change: it moves when a sibling comes or goes.
- **Revert** on a node puts that entity back as the index holds it, with what hangs from it in
  either version: what was changed takes the kept values, what was removed comes back with its
  id, what was added goes. It is one step of whoever asks (`scene.update` with the kept rows of
  the subtree), so undo takes it back and the flush writes the file.
- `git.changes` and `git.revert` are the same for an agent; with `author`, `git.revert` takes
  back instead what the steps of that author still hold of those entities in the history of the
  session (`history_revert_author`), keeping what others wrote since.
- What it does not reach: the content of a section, which is in its own scene; components of a
  plugin the project lacks; a scene whose kept version git no longer gives whole (over
  `git.OUTPUT_LIMIT`).

## Merge mode

`editor/git_merge.odin` (state, computation and resolution) and `editor/git_review.odin`
(Details).

- On detecting `U` files, the editor reads their three versions from git (`git show :1:`, `:2:`,
  `:3:`) and merges again in memory the assets of a document kind (`asset.scene_merge`). What
  remains are **items**: the conflicts of an entity of a file, or a file merged whole (code,
  textures, an asset that could not be read).
- **Each conflict takes what arrived (theirs)** until one's own is chosen. The open scene shows the
  choices instantly: the document is built in memory with them and replaces the world
  (`git_scene_show`), without writing the file until the merge finishes. The entities of unaccepted
  items are outlined (`GIT_CONFLICT_LEVEL`).
- Choosing something from an accepted item leaves it pending again. ✕ takes one's own for the
  whole item and accepts it; ✓ accepts what was chosen. Both move to the next pending one.
- A row that one side removed and the other changed is chosen whole. An entity that returns brings
  what theirs has of it.
- **Finish merge** is enabled with everything accepted: it writes each file as it ended up (a whole
  file, the chosen version or what is in the folder), adds them and commits the merge; the open
  scene is read again from the file. **Abort** returns to the commit from before the pull.
- **AI:** "Resolve all with AI" and a text file's AI button ask the chat to resolve through
  `git.conflicts`, `git.choose` and `git.accept`; the AI does not finish the merge.

## Verification

- `mirai test editor/git` runs the installed git in a scratch repository: keep, discard from the
  index and unkeep.
- `mirai test editor the_entities_that_differ_from_what_git_keeps_revert_by_subtree`: the tree
  and the revert of a subtree, without git.
- `mirai check editor`; with a session of a new project (`mirai new`) and a bare remote:
  `git.init`, `git.commit` with push, a second clone that changes the scene and `git.pull`, with a
  different field (clean merge) and the same field (merge mode, `UU` file with ours and what did
  not collide already joined).
- Merge mode: `git.conflicts`, `scene.inspect` with theirs by default, `git.choose` with ours,
  `git.accept` (with and without `reject`) and `git.finish`; with a row removed by one side and
  changed by the other. The UI: `editor.view` with `Git` and `capture` with `ui`.
