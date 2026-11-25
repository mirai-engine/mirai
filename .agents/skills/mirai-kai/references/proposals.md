# Proposals, policies and checks

How work is reviewed before it moves a shared bookmark. A proposal replaces the pull request: it is
a signed log every peer folds alike and checks against the org's policy itself, so there is no
server that decides a merge. The code is `kai/proposal.odin`, the proposal part of `kai/log.odin`,
`kai/team.odin` and `cook/kai/review.odin`.

## Proposals

- A proposal is a `Proposal_Log`: `Open` on a target bookmark with a title and text, then
  `Revise` to a stack (change ids with the revision each has now, bottom first), `Comment`,
  `Verdict`, `Check`, `Land`, `Close` and `Reopen`. The default stack is the changes from the target
  to the working copy's parent, after a snapshot.
- Who may write what is the fold's, as for every log, with each author's role at the org entry it
  signed under: a writer opens one, the opener or a writer revises, any member comments, a writer
  gives a verdict and signs a check, the opener or an admin closes and reopens. A runner outside
  the org may sign a `Check` alone, under a grant of the check right. A member removed later keeps
  what it signed before ([folding](identity.md#folding-and-revocation)).
- A proposal is for a change that may be rewritten: a stack is revised as often as needed and
  rewrites keep every `Change_Id`, so comments and history survive a rebase or an amend, and the
  web view shows the *evolution* of a change: its revisions in order with the interdiff between
  each and the next.
- A proposal belongs to a project of an org and names its target by bookmark name. Every stack a
  proposal was revised to is part of what a node mirrors, so reviewers read it whether or not its
  author's device is online.

## Anchors and carrying over

- A comment is on the whole proposal, on a file of a change, on lines of a text file or on a
  structural place (an entity and a table or field of an asset). It names the change it was made
  on and follows that change across revisions: lines move by a line diff, a structural anchor by
  the driver that knows the file, a file anchor stays while the file does. A comment whose
  place is gone is marked outdated, not dropped.
- A verdict binds to a revision. It carries over to a later stack only when every change makes the
  same edits, the same files changed from their first parent the same way (an empty interdiff),
  as a rebase that touched none of their files does. Approval is for the edits the reviewer saw,
  never for a name (`proposal_comments_reanchor_across_rewrites`).
- Only the latest verdict of a user counts, and only an approval counts toward the policy's number.
- A check counts for the revision of the last `Revise` in its causal past, and only when it names
  that revision and that is the proposal's final one.

## Policy and landing

- A policy is set by an admin for a project's bookmark in the org's log: how many approvals, which
  named checks, and the heads of the project's log whose causal past it guards. A bookmark with a
  policy moves only by landing a proposal; an unguarded shared bookmark moves with
  `mirai kai bookmarks move` or the editor, by a writer.
- Landing is two entries: a `Bookmark_Move` in the project's log from the target's current targets
  to the stack's final revision, naming the proposal and the heads of its log it was checked at,
  and the proposal's `Land` naming that move. A peer that folds a move of a guarded bookmark folds
  and settles the proposal as it was at those heads and checks the policy against that, so a move
  that names none that meets it does not count, and what happens to the proposal later (a
  revise, other verdicts, a reopen) never changes a landed move. A peer that lacks those entries
  or their changes holds the move as not counting until they arrive; it does not guess.
- Those heads never change, so a machine keeps each verdict that held, by a key of the move, the
  policy entry it met and which org and user entries are void (a late removal may still void
  one), as one local object per project that no peer is served. A fold reads no proposal whose
  move it kept; a key that no longer matches is judged again from the proposal's log
  (`a_project_of_10000_landed_moves_folds_without_reading_its_proposals` prints both times).
- A proposal lands only when it is open with a stack, every entry is signed by its author, no
  change of the stack has a conflict (`root.conflicts == 0` of each tree), the approvals of the
  final revision reach the policy and every check the policy names has passed on it. The refusal
  says which of those fails and what to do (`landing_enforces_policy_and_zero_conflicts`).
- Two moves of one bookmark that diverge are conflict terms, like files.

## Checks

- A check is a signed statement: this runner found this state (pending, passed or failed) for this
  name on this revision, with its output kept as an object of the store and named by the entry. It
  counts under the same rules as any entry: its author must be a writer or hold a grant with the
  check right.
- `mirai kai check <name> -- <command...>` runs the command in the project's folder, whose working
  copy must hold the proposal's final revision, and signs `passed` when it exits 0. There is no
  runner service on a node: a check is run by a Mirai peer, a person's machine or an agent's
  workspace, and the same command is what a policy requires.
- A check that requires a build or a test is the command the project already has: `mirai test`,
  `mirai scene check`, `mirai build`. To require one, add its name to the policy
  (`mirai kai bookmarks policy <bookmark> --checks name`) and run it on each revision.
- A node never runs the code of a proposal; the browser reads checks and never starts one.
