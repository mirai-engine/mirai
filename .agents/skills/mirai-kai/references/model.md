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
  (`change_verify`, `log_merge`, the accept procedures of refs, overlays and derived data) and by
  `mirai kai verify`, never on a local read: the store already holds only what was accepted.
- A change keeps its `Change_Id` across rewrites; its revision is the address of its object. The
  operation that rewrote it records the predecessor, never the change, so a revision is
  content-addressed and never depends on the history of rewrites.
- A change is signed by its author's device key. Who else made it goes in its coauthors; the
  author is accountable, coauthors only record.
- A change carries a short, bounded list of attachments: objects of the store its writer
  names with a type that writer owns (the editor attaches the record of an agent's turn). Kai
  never reads them; it serves, keeps and walks them as it does the change's tree, in the
  members', public and grant closures and in what a sweep keeps. The list is ascending and
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
- A tree never names a private overlay. What a scope takes is
  [sealed apart](private.md#scopes-and-routing), so the public change is readable by anyone it
  is shared with.
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
- A change with a conflict cannot land on a shared bookmark
  ([landing](proposals.md#policy-and-landing)); it can be described, rebased, split and undone
  like any other.

## Drivers and diff

- A driver merges the sides of one file and moves an anchor from one version of it to another. It
  is a pure, deterministic procedure of its inputs, so the same terms give the same bytes on
  every machine. The drivers given are asked in order, then the built-in text and binary ones; a
  driver that does not know the file says `Unsupported`, and no driver reads a file past
  `DRIVER_BYTES_MAX`.
- A driver has an `id`, recorded in the conflicts it judges, and a `version`, raised when its
  results change.
- Being pure, a driver's `Resolved` and `Conflicted` results are kept in `cook/cache` by its id,
  its version and the addresses of the three terms (`Cached_Driver` in `cook/kai`): the same
  merge runs once on a machine. They are not asked of peers, which takes longer than a merge. A
  raised version misses every earlier result.
- Text merges by lines with `std/diff`: a histogram diff over lines interned to ids in one table
  sized to the inputs, whose memory is linear in the lines. A range whose lines repeat too often
  to anchor becomes one replace hunk, so a hostile file costs a bounded search. The three-way
  merge keeps bytes and line breaks as they are. Binary files (a NUL in the first bytes) conflict
  when both sides changed them.
- Mirai assets merge in `cook/kai` through `asset.scene_merge`: a document by row id and field by
  field, a scene keeping its hierarchy valid, and what both sides changed apart a conflict whose
  partial result keeps ours. A result that does not read again as a scene is `Error`, not a
  result. Resolving a conflicted asset by field is `cook/kai/conflicts.odin`, shown in the
  [editor](../../mirai-editor/references/kai.md#conflicts); the merge rules of the asset are
  [asset merge](../../mirai-assets/references/cli.md#merge).
- An anchor of a comment is a file, lines or a structural key (an entity and a table or field).
  Lines follow the file's diff; a structural anchor follows the first driver that knows the file
  and stays while its entity does.
- A new driver is a `Driver` registered in `cook/kai` (or the project that owns the format). It
  needs hostile-input tests and, when its result changes, a raised `version`.

## Operations and undo

- Every change to what a repository shows is an operation: it points to its parent operations, to
  the view after it and to the changes it rewrote. One operation is one batch of the store made
  visible by one commit, with the records of the private overlays that follow what it wrote, so a
  cut midway leaves the repository and its overlays as they were, and one undo takes the whole
  operation back. Every rewrite carries its overlay records in the operation's commit: `tx_commit`
  gives each revision a transaction wrote the records of the one it replaced (the first half of a
  split and a new change, their first parent's that has them; a restore, the change it restores
  from), unless the operation sealed its own, so no operation can drop them.
- A view is the visible heads (no visible change descends from another), each workspace's working
  copy and the bookmarks; a bookmark two operations moved apart holds the terms of a conflict,
  with the same algebra as files.
- Each workspace writes only its own ref, in `kai-local-<repo>`, which no peer is served: its
  operation heads, stat index and private state are local. Operations two workspaces wrote apart
  are merged by the next one that reads both (`op_heads_merge`): each view merged against their
  common operation, so working in two folders of one repository needs no coordination.
- Undo is an operation. The view it writes takes back what the undone one did and keeps what came
  after, so an undo can be undone, and undoing is never the undo of the editor's document. An
  overlay record belongs to the revision it was written for and an operation writes only those of
  revisions it made, so the view an undo gives back reads its private files as they were.
- A rewrite (describe, rebase, restore, split) moves every descendant onto the new revision and
  rebases its tree; a bookmark on an abandoned change moves to its first parent. A split by whole
  files keeps the first half's id and its description and puts the rest in a new change on it that
  takes the working copy, whose files do not change.
- The graph index is derived: dense arrays extended as changes become visible, a topological order
  by construction, generations to stop a walk, and merge bases found from both sides.
- A shared bookmark is not an operation of a repository: it is an entry of the project's log
  ([identity](identity.md#the-signed-logs)), moved for the whole org.
- Retention: a prune is an operation whose parents are the one it follows and every operation a
  workspace's ref names. The log keeps what the workspaces' refs name and the operations not older
  than the newest prune's time less `OP_RETENTION`; undo does not cross a prune. The store's sweep
  follows refs and not the links inside Kai records, so whoever sweeps names as live what
  `store_live` names: the operations kept and their views, and everything any other ref reaches,
  walked by the kind of the object it names (`kai/reach.odin`): each log's pages and what their
  entries name (moves, proposals' stacks, a check's output, a keyring's envelopes), the closures
  of the changes they, the views and the devices' refs name, the sealed tree and files of the
  overlay record each ref names, and the derived data kept. That walker is the one place that
  says what a Kai object or entry names: the sweep and every set a peer is served read it, so a
  new kind is added there once. An overlay record belongs to its
  revision: the prune drops the ref of one whose revision nothing kept reaches once it is older
  than the operations kept, and the records an overlay ref replaced are never kept, since
  nothing reads them, so private history is bounded as the operation log is. A node prunes when
  it sweeps for its quota; on a machine `mirai kai prune` and `kai.prune` run `cook/kai`'s
  `prune`, which also names what the asset library holds.

## Workspaces

- A workspace is a folder whose files are the working copy of one change. What it keeps lives in
  `<root>/.mirai/kai` (its state and a lock one process holds while it works there: `Locked` for a
  second process) and never in the tree. Several workspaces of one repository are normal: a second
  agent works in its own folder and lands by proposal.
- The working copy is a change (`@`): there is nothing to stage. A snapshot records the files as
  they are; the stat index (size, time, inode and address per file) says which changed, so only
  those are read, hashed and put, in parallel, and one commit writes the operation. A file
  modified within `SETTLED_NANOSECONDS` of being read is racy and hashed again, because a second
  edit in the same tick of the file system's clock would not show.
- An editor pushes the paths it changed (`workspace_touched`), so a snapshot stats only those and
  never scans the folder; a watch that overflows makes the next snapshot read it whole.
- A switch (checkout) writes only the files that differ, through a temporary file and a rename,
  and records its target first, so one cut midway is finished by the next status or snapshot
  (`a_switch_cut_midway_recovers_on_status`). A file a sibling workspace's saved stat index says
  it holds, settled and still of the row's size, time and inode, is cloned without reading it
  where the volume can (APFS `clonefile`, `FICLONE`) and copied where it cannot; any other comes
  from the store. A snapshot takes its new index into memory only once it is saved.
- What a workspace tracks is a `Filter` its owner gives: for a project it is `project.own_path`,
  which leaves out the generated folder and the folders of version control. Kai has no ignore
  file: what is not the project's is decided where the project is defined.

## Surfaces

- `kai` has procedures for what needs no workspace (the machine, the logs, a team, pairing) and
  `cook/kai` for what does (opening a workspace over a project, snapshots with authors, switching
  with private files, splitting, conflicts, proposals of a workspace, the bookmarks it publishes).
  `mirai kai`, the editor and the `kai.*` methods call those alike; a procedure that one of them
  needs and the other does not have moves into one of the two packages.
- Whatever a procedure writes to a log tells the machine's runner (`Machine.changed`) so peers hear
  of it at once. A failure fills `m.why` with what failed and how to fix it, and that text is the
  one a person or an agent reads.
- The commands are in [common commands](../../mirai-projects/references/projects.md#common-commands)
  and `mirai kai` without arguments; the tab, the methods and what the editor pushes are in the
  [editor](../../mirai-editor/references/kai.md).
