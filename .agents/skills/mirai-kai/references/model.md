# The model of Kai: changes, conflicts and operations

What `std/diff`, `kai` and `cook/kai` keep of a project's history, and why each rule exists. The
bounds of every record are constants of `kai/types.odin`; past one is `Too_Large`, never a cut.

## Records

- Every Kai object is one object of the [store](../../mirai-store/SKILL.md): its kind and
  version in the meta of its root, then a `#packed` little-endian head, count-prefixed flat arrays
  and a string pool. A stored struct has no pointers and its reserved bytes are zero, so one
  content has one address and a record can be copied in blocks.
- What a decode reads is checked in full. Hostile bytes are `Corrupt`; a record of another
  version is refused and never migrated: an incompatible change updates all its consumers in the
  same task.
- A signature covers every byte before it. It is verified when a record comes from a peer
  (`change_verify`, `org_accept`, `repo_refs_accept`, `ddc_accept`), never on a local read: the
  store already holds only what was accepted.
- A change keeps its `Change_Id` across rewrites; its revision is the address of its object. The
  operation that rewrote it records the predecessor, never the change, so a revision is
  content-addressed and never depends on the history of rewrites.
- A change is signed by its author's device key. Who else made it goes in its coauthors; the
  author is accountable, coauthors only record.
- A change carries a short, bounded list of attachments: objects of the store its writer
  names with a type that writer owns (the editor attaches the record of an agent's turn). Kai
  never reads them; it serves, keeps and walks them as it does the change's tree, in what a pull
  fetches and in what a sweep keeps. The list is ascending and
  without repeats, so one change has one form; any other list is `Corrupt`.

## Trees

- A file is an object of its bytes, cut on content by the store, so an edited file shares every
  chunk the edit did not touch. A folder is an object whose entries are sorted by name; its meta
  carries the files, bytes and conflicts under it. The same files give the same tree, two trees
  that differ in one file share every folder off its path, and whether a tree has a conflict is
  one read of its root.
- A path must be valid on every system: relative, with `/`, no `.` or `..`, no reserved name,
  and two paths that differ only in case, or a file and a folder of one name, are refused at
  snapshot by `tree_build`, which compares the sorted names of each folder. Links and special
  files are never tracked.
- Tree diff and merge compare folder addresses first and read only folders that differ, so their
  cost follows what changed and not the size of the project.
- Wherever Kai assumes an order of paths (a diff, the stat index and its merge, a list a binary
  search reads, the files `tree_build` takes) it is the order of their bytes. A folder's walk
  gives `a/x` before `a-b`, so `tree_diff` sorts what it found; a path still comes before every
  path under it, which a checkout needs to remove a file before writing the folder of its name.

## Conflicts

- A conflict is a value, never a state that blocks work. Its terms alternate side, base, side,
  ..., side, as Jujutsu keeps them. A base equal to a side cancels with it on write, a conflict
  that comes down to one side is that side, and a conflict inside the terms of a merge is
  flattened into them: the stored terms are always simplified, so one conflict has one address,
  and rebasing composes conflicts without losing one.
- A tree merges folder by folder: equal subtrees are not read, an absent folder is an empty one,
  a folder left empty is absent. A file with more than one distinct side goes to the
  [drivers](#drivers-and-diff); one none resolves becomes a conflict entry.
- A checkout writes the driver's partial result at the path (text with markers, an asset with
  ours where the sides disagree) and records the address it wrote. While the file still holds
  those bytes a snapshot keeps the conflict; any edit, by a person, the editor's per-field
  picker or an agent, resolves it. Nothing asks to resolve before working, so a merge never
  stops an agent.
- A change with a conflict can be described, rebased, split, published and undone like any
  other.

## Drivers and diff

- A driver merges the sides of one file and moves an anchor from one version of it to another. It
  is a pure, deterministic procedure of its inputs, so the same terms give the same bytes on
  every machine. The drivers given are asked in order, then the built-in text and binary ones; a
  driver that does not know the file says `Unsupported`, and no driver reads a file past
  `DRIVER_BYTES_MAX`.
- Text merges by lines with `std/diff`: a histogram diff over lines interned to ids in one table
  sized to the inputs, whose memory is linear in the lines. A range whose lines repeat too often
  to anchor becomes one replace hunk, so a hostile file costs a bounded search. The three-way
  merge keeps bytes and line breaks as they are. Binary files (a NUL in the first bytes) conflict
  when both sides changed them.
- Mirai assets merge in `cook/kai` through `asset.scene_merge`: a document by row id and field by
  field, a scene keeping its hierarchy valid, and what both sides changed apart a conflict whose
  partial result keeps ours; a result that breaks the rules of its kind where ours kept them
  conflicts whole as ours. `Error` is a failure to merge (memory): its file conflicts too and
  materializes as ours, never stopping the rest of the tree. Resolving a conflicted asset by field
  is `cook/kai/conflicts.odin`, shown in the
  [editor](../../mirai-editor/references/kai.md#conflicts); the merge rules of the asset are
  [asset merge](../../mirai-assets/references/cli.md#merge).
- An anchor is a file, lines or a structural key (an entity and a table or field).
  Lines follow the file's diff; a structural anchor follows the first driver that knows the file
  and stays while its entity does.
- A new driver is a `Driver` registered in `cook/kai` (or the project that owns the format). It
  needs hostile-input tests.

## Operations and undo

- Every change to what a repository shows is an operation: it points to its parent operations, to
  the view after it and to the changes it rewrote. One operation is one batch of the store made
  visible by one commit, so a cut midway leaves the repository as it was, and one undo takes the
  whole operation back.
- A view is the visible heads (no visible change descends from another), each workspace's working
  copy and the bookmarks; a bookmark two operations moved apart holds the terms of a conflict,
  with the same algebra as files.
- Each workspace writes only its own ref, in `kai-local-<repo>`, which no peer is served: its
  operation heads, stat index and private state are local. Operations two workspaces wrote apart
  are merged by the next one that reads both (`op_heads_merge`): each view merged against their
  common operation, so working in two folders of one repository needs no coordination.
- Undo is an operation. The view it writes takes back what the undone one did and keeps what came
  after, so an undo can be undone, and undoing is never the undo of the editor's document.
- A rewrite (describe, rebase, restore, split) moves every descendant onto the new revision and
  rebases its tree; a bookmark on an abandoned change moves to its first parent. A split by whole
  files keeps the first half's id and its description and puts the rest in a new change on it that
  takes the working copy, whose files do not change.
- The graph index is derived: dense arrays extended as changes become visible, a topological order
  by construction, generations to stop a walk, and merge bases found from both sides.
- A shared bookmark is not an operation of a repository: it is in the repository's `Repo_Refs`
  record ([shared bookmarks](org.md#shared-bookmarks)), moved for the whole org.
- Retention: a prune is an operation whose parents are the one it follows and every operation a
  workspace's ref names. The log keeps what the workspaces' refs name and the operations not older
  than the newest prune's time less `OP_RETENTION`; undo does not cross a prune. The store's sweep
  follows refs and not the links inside Kai records, so whoever sweeps names as live what
  `store_live` names: the operations kept and their views, and everything any other ref reaches,
  walked by the kind of the object it names (`kai/reach.odin`): every version of each org
  record, the closures of the changes the views and the shared bookmarks name, and every object
  of the outputs of the derived data kept. That walker is the one place that says what a Kai
  object names: the sweep and every pull read it, so a new kind is added there once. A server
  sweeps when it drops derived data past its quota; on a machine `mirai kai prune` and
  `kai.prune` run `cook/kai`'s `prune`, which also names what the asset library holds.

## Workspaces

- A workspace is a folder whose files are the working copy of one change. What it keeps lives in
  `<root>/.mirai/kai` (its state and a lock one process holds while it works there: `Locked` for a
  second process) and never in the tree. Several workspaces of one repository are normal: a second
  agent works in its own folder.
- The working copy is a change (`@`): there is nothing to stage. A snapshot records the files as
  they are; the stat index (size, time, inode and address per file) says which changed, so only
  those are read, hashed and put, in parallel, and one commit writes the operation. A file
  modified within `SETTLED_NANOSECONDS` of being read is racy and hashed again, because a second
  edit in the same tick of the file system's clock would not show.
- An editor pushes the paths it changed (`workspace_touched`), so a snapshot stats only those and
  never scans the folder; a watch that overflows makes the next snapshot read it whole
  (`Touch_Mode.Full_Scan`, which no later report undoes until that snapshot).
- A switch (checkout) writes only the files that differ, through a temporary file and a rename,
  and records its target first, so one cut midway is finished by the next status or snapshot
  (`a_switch_cut_midway_recovers_on_status`); the conflicts it writes become the state's only
  once the state is saved, so one cut leaves the state in memory as on disk. A file a sibling
  workspace's saved stat index says it holds, settled and still of the row's size, time and
  inode, is cloned without reading it
  where the volume can (APFS `clonefile`, `FICLONE`) and copied where it cannot; any other comes
  from the store. A snapshot takes its new index into memory only once it is saved.
- What a workspace tracks is a `Filter` its owner gives: for a project it is `tracked_path`
  (`cook/kai`): `project.own_path`, which leaves out the generated folder and the folders of
  version control, and not the checkouts of the plugins from git the manifest names (read when the
  workspace opens and after a clone writes its files). Kai has no ignore file: what is not the
  project's is decided where the project is defined. A file the tree holds that the filter stops
  tracking stays in the snapshot as it was (`untracked_keep`), as a later ignore leaves a file
  git tracks; it leaves the changes only with a checked-out tree without it, and a checkout never
  writes or removes such a path.

## Surfaces

- `kai` has procedures for what needs no workspace (the machine, its orgs, invites, the agent)
  and `cook/kai` for what does (opening a workspace over a project, snapshots with authors,
  splitting, conflicts, publishing, pulling a repository into a folder).
  `mirai kai`, the editor and the `kai.*` methods call those alike; a procedure that one of them
  needs and the other does not have moves into one of the two packages.
- Whatever a procedure writes to an org's heads tells the process's agent (`agent_changed`) so
  peers hear of it at once. A failure fills `t.why` with what failed and how to fix it, and that
  text is the one a person or an agent reads.
- The commands are in [common commands](../../mirai-projects/references/projects.md#common-commands)
  and `mirai kai` without arguments; the tab, the methods and what the editor pushes are in the
  [editor](../../mirai-editor/references/kai.md).
