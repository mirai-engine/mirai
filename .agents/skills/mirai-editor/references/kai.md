# Kai in the editor

Kai, the version control of a project and the mesh of its team, is owned by
[mirai-kai](../../mirai-kai/SKILL.md): what a change, a conflict, an operation, an org or a proposal
is, and why. This file is only the editor's part: the Kai tab of the left panel, named
Version Control (Kai) on its rail button and header (`editor/kai_panel.odin`,
`editor/kai_team_panel.odin`, `editor/kai_detail.odin`), what the editor pushes to a workspace and
the `kai.*` methods (`editor/api_kai.odin`, `editor/api_kai_team.odin`).
Everything the tab does goes through `cook/kai` and `kai`, as `mirai kai` does with no editor
([commands](../../mirai-projects/references/projects.md#common-commands)): a procedure the editor
needs from the command moves into `cook/kai`.

The editor opens a project that has `.mirai/kai` as a workspace of its own repository in the
machine's store (`editor/kai.odin`) and never makes one by itself: Kai is
[optional](../../mirai-kai/SKILL.md#start-a-project-on-kai). A project without one writes nothing
of Kai, not even the machine's identity in the store. Without one the tab shows "This
project does not use version control." and Enable Kai, which calls `kai.init`: it makes the
workspace of the project's files and opens it, and is refused when one is open or the editor has
no store. The New Project dialog's "Version control (Kai)" (on by default) is `mirai new`'s
`--no-kai` when unchecked. A guest of a collaboration session opens no
workspace, and neither does a run that ends by itself after a count of frames (a check of a build,
a capture): only an editor someone drives records history, and a host records what its guests do.

The tab has three views: Changes (the working copy, the bookmarks and the log), Proposals and
Team. Each button of the team views asks for its `kai.*` method, which runs between frames as a
call of an agent does; opening a proposal, picking the file a comment hangs on and typing only
change what the person sees. A row of buttons that would cut a label side by side at the tab's
width stacks them, and a row of fields holds only what fits.

A file of a change opens in the tab where the view's list was (`editor/kai_detail.odin`), with
what the change did to it as `ka.file_detail` reads it, the same that `kai.log` and `kai.proposal`
give with `file`: a text by its lines with their numbers, the lines it did not touch folded; an
asset by the rows and fields its driver tells apart, each on its entity; a binary or oversized
file by its sizes. A detail keeps `ka.DETAIL_ROWS` rows and counts the rest, is read once into its
own arena when it opens, and draws only the rows in sight. Bytes a peer has are asked of the mesh:
the tab reads the detail again on the team's poll, a method waits for them.

## Working copy

- What the editor writes (history files, the registry's flush, a scene) and what the watch of the
  project folder sees are pushed as touched paths (`kai_touched`): a snapshot then stats only
  those. The working copy snapshots once the files are quiet (`KAI_QUIET`) and nothing is held in
  memory, a gesture open or a game playing. A watch that overflows makes the next snapshot read the
  folder.
- What the tab shows is read again after each operation into an arena (`kai_read`): a frame that
  changes nothing reads nothing of the repository and allocates nothing.
- An operation (new change, describe, undo, restore, resolve, bookmark) first writes what the
  editor holds and snapshots; the files it writes are read again where they are loaded, and the
  document in front whose file went closes.
- Undo takes back the newest operation of the repository, as
  [Kai defines it](../../mirai-kai/references/model.md#operations-and-undo); it is not the undo of
  the document.
- Each file of CHANGES has a check, all on by default; New change with some off splits instead
  (`ka.split`, `kai.split`, `mirai kai split`), the description going to the closed half. Checks
  are kept by path, and the files are read again after the snapshot: a file that appeared since is
  checked. A conflict of the parents the change did not touch has no check. The check of CHANGES is
  on while any file is: a click then unchecks them all, and with none checks them all.
- A change is named by `@`, `@-`, a bookmark or a prefix of its id (`ka.revision_find`). A click on
  a change of the log lists the files it changed, each of which opens its detail; the button of the
  row starts a new change on it.

## Team

- The editor owns the machine's runner while it is open (`editor/kai_team.odin`): once the
  machine has a user or an org, or a pairing starts, it runs it in a thread of its own. When a
  `mirai kai agent` or another editor already runs it for the store, the editor reaches that one.
  Either way the editor talks to it only through its control channel, and what the editor's
  machine writes tells it (`Machine.changed`); the runner itself is
  [the mesh's](../../mirai-kai/references/mesh.md#the-runner).
- A poll between frames looks at the runner, the pairing request that waits, how a pairing this
  machine joins goes, the peers, and the machine's refs and logs. When any changed, what the team
  views show is read again into their arena, and a change of the logs routes the workspace's
  snapshots again (`ka.project_route`); a frame that changes nothing reads and allocates nothing.
- A machine with no user is offered one by its handle. The recovery key is shown once in a dialog
  that only its button closes (not Escape nor a press outside), and is zeroed when it closes;
  rotating it asks for the key the user has now, and a user born of a passkey sets its first one
  from there. Recover asks for a user's id and its recovery key, which bring the user onto this
  machine once its log is here, and again, on that machine, open the private scopes the agent
  fetched since ([recovering](../../mirai-kai/references/identity.md#keys)). No
  result of a method carries a recovery key: an editor with no window refuses to make a user, set or
  rotate its key before making anything, and `mirai kai identity` does it in a terminal.
- A device is named where it is made: by the name given, or by the machine's host name
  (`vcs.device_name_of`).
- Pairing ([how it works](../../mirai-kai/references/identity.md#pairing)): a ticket is offered as a
  member, a second device, a node or for a recovery, and copied; another machine joins with it. The
  approving side gets one request at a time in a dialog: who asks as `<handle>/<device>` (the
  joining machine names itself from its user's log, `vcs.machine_pair_name`; a device with no user
  yet gives the name its user will know it by), the code, and Deny and Approve alike, neither the
  default: Enter and Escape answer nothing.
- The org of the project: making one, putting the open project in it (public or the org's alone),
  or working on one of its projects from this workspace (`link`); members with their roles and
  devices, nodes and projects with their policies; a role, a removal, a transfer and leaving.
- Shared work: BOOKMARKS lists the workspace's bookmarks, then the project's shared ones and every
  device's as `<handle>/<device>:<bookmark>`, which the log shows on their changes too; a click
  starts a change on one. A shared bookmark moves for the whole org to the working copy's parent,
  refused with the policy's reason when one guards it; a name typed shares that parent under it.
  The workspace's bookmarks publish as this device's refs after each operation that changed them.
- Proposals ([the model](../../mirai-kai/references/proposals.md#proposals)): one opens on a shared
  bookmark with the changes from it to the working copy's parent. Its view has the stack with what
  each change did to each file, the comments placed on the current stack (outdated ones marked),
  verdicts, checks and what keeps it from landing. A comment hangs on the proposal, on a file picked
  in the stack, on lines of a text file, or on the entity selected in the scene. A file of the stack
  opens its detail, with the comments on it under their lines or entities; a click on a line (a
  shift-click spans from the one before) or on an entity's row starts a comment there. A check runs
  its command in the project's folder, whose working copy must hold the proposal's final revision.
- Private files ([the model](../../mirai-kai/references/private.md#scopes-and-routing)): the scopes
  of the project with their patterns, readers and history, added, removed and rotated. What refused
  the last snapshot (a path of the deny set, a scope waiting for rotation, a scope with no keyring
  here) or the last publish (a leak the publish scanner found) heads CHANGES with the button that
  resolves it, Keep public or Rotate the key; it stays until a snapshot, or a publish, holds.
- The imports of the editor take derived data the org's peers built from the mesh on a miss and
  publish what they build (`ka.mesh_source`), while the runner runs and the project is the org's.

## Conflicts

- A conflicted asset unfolds into its fields (`ka.conflict_fields`), ours and theirs, read from the
  sides of the conflict. Resolve writes it with theirs for the fields picked; Take ours and Take
  theirs write one side whole, which is how text and binary files resolve. The conflict then goes
  and a snapshot records the file (`ka.conflict_settle`); any other edit of the file resolves it
  too. [What a conflict is](../../mirai-kai/references/model.md#conflicts) and how the asset driver
  merges are Kai's.

## Authors

- A change is signed by this machine's identity (`ka.identity_load`, in the store). Who else
  changed it goes through the queue `Kai_Authorship`: the steps of the history since the last
  snapshot push the turn of the agent that made them, and the host of a session pushes the key of
  each editor whose edits or files it applies (each says it in its Hello). A snapshot drains the
  queue into the coauthors of the working change and, for each agent's turn, an attachment of
  type `turn` naming a small object of the turn (`Kai_Turn`) the editor puts in the store
  (`ka.snapshot_authored`). What a turn is stays the editor's: Kai carries the attachment unread.

## Verification

- `editor_kai_snapshot_diff_conflict_and_undo` (`editor/kai_test.odin`): snapshot, what a change
  shows and the detail of each kind of file, a merge with a conflict resolved by field, undo and
  redo.
- `editor_kai_new_change_takes_only_the_checked_files` (`editor/kai_test.odin`): `kai.split` and
  New change with files unchecked while the list changes; the split itself is
  `a_change_splits_by_paths_and_undoes_in_one_operation` in `kai`.
- `collab_coauthorship_and_agent_turns_record_in_change` (`editor/collab_share_test.odin`): the
  key of a guest and the turn of an agent recorded in the host's change.
- `editor_kai_pairs_and_lands_a_proposal` (`editor/kai_test.odin`): two editors with their stores
  and runners on 127.0.0.1 pair with the code, work on one project, and comment, approve, check
  and land a proposal, reading a file's detail whose bytes the other has; a move around the
  policy answers it; a device named by its host; what one editor's import keeps through the mesh,
  the other's takes.
- `editor_kai_team_views_ask_their_methods_and_keep_still_frames` and
  `editor_kai_team_methods_refuse_hostile_params` (`editor/kai_test.odin`): each view's stable
  frame allocates nothing, its buttons ask for their methods, the dialogs have no default, and
  every team method says how to fix params that do not fit.
- In a session: `kai.status`, `kai.new`, `kai.split`, `kai.conflicts`, `kai.resolve` and
  `kai.undo` once each, and `capture` with `ui` of the Kai tab in each of its views. The rest of
  Kai is verified by [its skill](../../mirai-kai/SKILL.md#verification).
