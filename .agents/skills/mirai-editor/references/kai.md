# Kai in the editor

The version control of a project is Kai, in process: the editor opens the project as a workspace
of its own repository in the machine's store, or makes one of its files when it has none
(`editor/kai.odin`). The Kai tab of the left panel (`editor/kai_panel.odin`) and the `kai.*`
methods (`editor/api_kai.odin`) act on it through `cook/kai`, as `mirai kai` does with no editor
([projects](../../mirai-projects/references/projects.md#common-commands)). Git is not involved: a
project has no repository of git, no index and no merge mode, and `git.*` methods are unknown.

## Working copy

- The working copy is a change (`@`): there is nothing to stage or keep. What the files hold is
  recorded by a snapshot, which reads only the files that changed.
- Leaving files out of a change is a split by whole files (`ka.split`, `kai.split`, `mirai kai
  split`): the first half keeps the change's id with the files picked, the second holds the rest
  and takes the working copy, whose files stay as they are. Each file of CHANGES has a check, all
  on by default; New change with some off splits instead, the description going to the closed
  half. Checks are kept by path, and the files are read again after the snapshot: a file that
  appeared since is checked. A conflict of the parents the change did not touch has no check.
- What the editor writes (history files, the registry's flush, a scene) and what the watch of
  the project folder sees are pushed as touched paths (`kai_touched`): a snapshot then stats only
  those. The working copy snapshots once the files are quiet (`KAI_QUIET`) and nothing is held in
  memory, a gesture open or a game playing. A watch that overflows makes the next snapshot read the
  folder.
- What the tab shows is read again after each operation into an arena (`kai_read`): a frame that
  changes nothing reads nothing of the repository and allocates nothing.
- An operation (new change, describe, undo, restore, resolve, bookmark) first writes what the
  editor holds and snapshots; the files it writes are read again where they are loaded, and the
  document in front whose file went closes.
- Undo takes back the newest operation of the repository and writes the files as the view after it
  has them; undoing an undo redoes it. It is not the undo of the document.
- A change is named by `@`, `@-`, a bookmark or a prefix of its id (`ka.revision_find`).
- A guest of a collaboration session opens no workspace: the host records the session's changes.

## Conflicts

- A change on several parents merges their trees with the drivers of `cook/kai` (an asset row by
  row and field by field, text by lines). What does not merge is a conflict in its file that never
  blocks: the file is written with ours where the sides disagree, and the tab lists it.
- A conflicted asset unfolds into its fields (`ka.conflict_fields`), ours and theirs, read from the
  sides of the conflict. Resolve writes it with theirs for the fields picked; Take ours and Take
  theirs write one side whole, which is how text and binary files resolve. The conflict then goes
  and a snapshot records the file (`ka.conflict_settle`); any other edit of the file resolves it
  too.

## Authors

- A change is signed by this machine's identity (`ka.identity_load`, in the store). Who else
  changed it goes through the queue `Kai_Authorship`: the steps of the history since the last
  snapshot push the turn of the agent that made them, and the host of a session pushes the key of
  each editor whose edits or files it applies (each says it in its Hello). A snapshot drains the
  queue into the coauthors and turns of the working change (`ka.snapshot_authored`).

## Verification

- `editor_kai_snapshot_diff_conflict_and_undo` (`editor/kai_test.odin`): snapshot, what a change
  shows, a merge with a conflict resolved by field, undo and redo.
- `editor_kai_new_change_takes_only_the_checked_files` (`editor/kai_test.odin`): `kai.split` and
  New change with files unchecked while the list changes; the split itself is
  `a_change_splits_by_paths_and_undoes_in_one_operation` in `kai`.
- `collab_coauthorship_and_agent_turns_record_in_change` (`editor/collab_share_test.odin`): the
  key of a guest and the turn of an agent recorded in the host's change.
- In a session: `kai.status`, `kai.new`, `kai.split`, `kai.conflicts`, `kai.resolve` and
  `kai.undo` once each, and `capture` with `ui` of the Kai tab.
