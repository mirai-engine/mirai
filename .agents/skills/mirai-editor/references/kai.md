# Kai in the editor

Kai, the version control of a project and how its team syncs, is owned by
[mirai-kai](../../mirai-kai/SKILL.md): what a change, a conflict, an operation, an org or an invite
is, and why. This file is only the editor's part: the Kai tab of the left panel, named
Version Control (Kai) on its rail button and header (`editor/kai_panel.odin`,
`editor/kai_team_panel.odin`, `editor/kai_detail.odin`), the Repositories of the projects screen
(`editor/kai_launcher.odin`), what the editor pushes to a workspace and the `kai.*` methods
(`editor/api_kai.odin`, `editor/api_kai_team.odin`).
Everything the tab does goes through `cook/kai` and `kai`, as `mirai kai` does with no editor
([commands](../../mirai-projects/references/projects.md#common-commands)): a procedure the editor
needs from the command moves into `cook/kai`.

The editor opens a project that has `.mirai/kai` as a workspace of its own repository in the
machine's store (`editor/kai.odin`) and never makes one by itself: Kai is
[optional](../../mirai-kai/SKILL.md#start-a-project-on-kai). A project without one writes nothing
of Kai to it. Without one the tab shows "This project does not use version control." and Enable
Kai, which calls `kai.init`: it makes the workspace of the project's files and opens it, and is
refused when one is open or the editor has no store. The New Project dialog's "Version control
(Kai)" (on by default) is `mirai new`'s `--no-kai` when unchecked. A guest of a collaboration
session opens no workspace, and neither does a run that ends by itself after a count of frames (a
check of a build, a capture): only an editor someone drives records history, and a host records
what its guests do.

The tab has two views: Changes (the working copy, Publish to main, the bookmarks and the log) and
Team. Each button asks for its `kai.*` method, which runs between frames as a call of an agent
does; typing only changes what the person sees. A row of buttons that would cut a label side by
side at the tab's width stacks them, and a row of fields holds only what fits.

A file of a change opens in the tab where the view's list was (`editor/kai_detail.odin`), with
what the change did to it as `ka.file_detail` reads it, the same that `kai.log` gives with
`file`: a text by its lines with their numbers, the lines it did not touch folded; an asset by the
rows and fields its driver tells apart, each on its entity; a binary or oversized file by its
sizes. A detail keeps `ka.DETAIL_ROWS` rows and counts the rest, is read once into its own arena
when it opens, and draws only the rows in sight. Bytes not in the store yet say so: the agent
pulls what the shared bookmarks reach.

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
- New change closes the working change and starts an empty one on it; the text typed names the
  change that closes, never the one that starts, in the same operation (`closing` of
  `ka.new_change`). With no file changed, no description and none typed there is nothing to close
  and it says so. `kai.new` and `mirai kai new -m` describe the change they start.
- Each file of CHANGES has a check, all on by default; New change with some off splits instead
  (`ka.split`, `kai.split`, `mirai kai split`), the description going to the closed half. Checks
  are kept by path, and the files are read again after the snapshot: a file that appeared since is
  checked. A conflict of the parents the change did not touch has no check. The check of CHANGES is
  on while any file is: a click then unchecks them all, and with none checks them all.
- A change is named by `@`, `@-`, a bookmark or a prefix of its id (`ka.revision_find`). A click on
  a change of the log lists the files it changed, each of which opens its detail; the button of the
  row starts a new change on it.

## Team

- The team is the machine's, not the project's (`editor/kai_team.odin`): the Kai state of the
  editor's store (profile and orgs) and the machine's
  [agent](../../mirai-kai/references/sync.md#the-agent), which runs in this process on the
  editor's own store once the machine is in an org or joins one, asking the router to forward its
  port. A launcher with no project opens it too. A store
  whose Kai state does not open leaves Team saying why; the other views work.
- What the views show is read into the team's arena only when `vcs.agent_generation` moved, at
  most every `KAI_READ_EVERY` (a pull moves it at every batch), or this editor wrote
  (`kai_team_wrote`): a frame that changes nothing reads and allocates nothing. A pull writes its
  files once the agent says its repository came whole.
- THIS MACHINE names the person and the device (`kai.profile`), offered from `USER` (`USERNAME` on
  Windows) and the host name. JOIN AN ORG takes an invite (`kai.join`). Each org lists its members
  with role and device and its repositories with main and whether all of it is here; an admin sets a
  role or removes a member (`kai.org`) and makes an invite for a role, for another machine of the
  same person, and at a host:port when the other machine is on another network (`kai.invite`), to
  copy, shown under its own org, or revokes the open ones (`kai.invite` with `revoke`). NEW ORG
  makes one with this machine its admin. A server's web sign-in is set from here (`kai.web_login`);
  the password goes straight to the agent and is zeroed.
- A join and a web sign-in run on a thread of the agent (`kai_task_start`), so the frames go on:
  `kai.join` and `kai.web_login` start one and say its stage (none, waiting, done or failed, with
  why); called with no params they say how the last went (wait with `_wait_until`).
- Publish to main (Changes) closes the working change whole and moves main for the org
  (`kai.publish`). A project in no org yet goes into one in the same call, Public or Org only, after
  whatever may refuse (the bookmark, the role, the snapshot), so a refused publish leaves the org as
  it was; with more than one org, the first publish picks which; a public repository lists the files
  named like secrets it now shows. A publish that fails keeps the typed description.
- BOOKMARKS lists the workspace's bookmarks, then the repository's shared ones; a click starts a
  change on one and its arrow moves it to the working copy's parent for the whole org
  (`kai.bookmarks` with `move`).
- All projects of the projects screen lists, after the projects of this machine, the
  repositories of its orgs it has not pulled (the tab counts both), each pulled into a folder of
  the location with one click (`kai.clone`) and opened once main's files are written, with how
  far the pull is in chunks and bytes as the agent counts them; Cancel leaves a workspace a later
  pull goes on with. Team, beside the tabs, shows the Team view in place of the list, so a machine
  with no project names itself, joins or makes an org.
- `kai.peers` gives where the agent listens, the machines connected and each repository's pull.
- The imports of the editor take derived data the org's machines built on a miss and publish what
  they build (`ka.peers_open`), when the project is a workspace of an org's repository.

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
  New change with files unchecked while the list changes, and with all checked the text naming
  the change that closes; the split itself is
  `a_change_splits_by_paths_and_undoes_in_one_operation` in `kai`.
- `editor_kai_is_optional_until_enabled` and
  `editor_kai_methods_record_read_and_settle_the_working_copy` (`editor/kai_test.odin`).
- `collab_coauthorship_and_agent_turns_record_in_change` (`editor/collab_share_test.odin`): the
  key of a guest and the turn of an agent recorded in the host's change.
- `editor_kai_publishes_to_main_and_a_launcher_pulls_it` (`editor/kai_test.odin`): two editors
  with their stores and agents on 127.0.0.1 (`mesh_loopback`); the first names itself, makes an
  org and publishes into it in one call, and invites; the second, a launcher with no project,
  joins and pulls the repository from Repositories until its files are there.
- `editor_kai_team_view_reads_only_when_the_agent_moves` and
  `editor_kai_team_methods_refuse_hostile_params` (`editor/kai_test.odin`): a still frame reads and
  allocates nothing, the buttons ask for their methods, and every team method says how to fix
  params that do not fit.
- In a session: `kai.status`, `kai.new`, `kai.split`, `kai.conflicts`, `kai.resolve` and
  `kai.undo` once each, and `capture` with `ui` of the Kai tab in each of its views. The rest of
  Kai is verified by [its skill](../../mirai-kai/SKILL.md#verification).
