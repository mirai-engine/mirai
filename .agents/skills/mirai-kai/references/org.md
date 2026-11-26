# The machine, the org and invites

Who a machine is, what an org records and how a machine joins one (`kai/team.odin`,
`kai/org.odin`), and why each rule exists. The bounds are constants of those files; past one is
`Too_Large` or `Invalid_Argument`, never a cut.

## The machine

- A machine is one Ed25519 device key: its seed is `kai-identity`, an owner-only file at the root
  of the store, made the first time a team opens (`machine_identity`). A file that is there and
  does not read is kept and refused, never replaced, so a permission problem never makes a new
  device (`an_unreadable_device_secret_is_kept`).
- There is no user key, recovery key or account. A person is a name the devices of that person
  share in each org; losing a machine is removing its key from the org and inviting the new one.
- The machine keeps for itself, under `kai-machine` refs that no peer is served: its profile (the
  person's and the machine's names, `team_profile_set`, which every org it makes or joins lists),
  the org repository each local repository is a workspace of (`team_link`) and the addresses each
  peer was last reached at. Open invites are `kai-invite` refs.
- `Team` is the open state the CLI, the editor and a server share; a failing procedure fills
  `t.why` with what failed and how to fix it. On a server `t.tenants` gives each org its own store
  ([server](server.md#the-server)).

## The org record

- An org is one `Org` record: its id, name, version, the address of the version before (`prev`),
  the signer, members sorted by key and repositories sorted by id. A member is a device key, a
  role, the person's and the device's names and an optional address (`host:port` where every
  member reaches it: a server's). A repository is an id, a name and whether it is public.
- Each version names `prev` and is signed by an admin of the version before, or by one of its
  writers when the members do not change (only repositories); the first is signed by an admin it
  lists (`org_signs`). An admin edits a copy of the newest and writes the next version
  (`team_org_edit`, `team_member_set`, `team_member_remove`, which keeps at least one admin,
  `team_repo_set`).
- A peer takes a record (`org_accept`) only once every version from it back to one it holds, or
  to the first, is in its store and each follows the one before: a forged or stale record never
  stands, and a removed admin cannot sign a version past its removal because the version that
  removed it is in every chain after. At most `ORG_CHAIN_MAX` versions lie past the one held.
- Two admins that sign the same version apart are settled alike everywhere: the higher version
  wins, then the lower address. Every version stays in the store (`store_live` keeps them), since
  a peer walks back through them.
- Why one record and no log: membership is small, changes rarely and is read whole by every peer
  at every connection; a record that names its predecessor gives the same tamper evidence as a
  signed log with one read and no fold.

## Roles

| Role | Reads | Signs |
| --- | --- | --- |
| `Reader` | every repository of the org | nothing |
| `Node` | every repository; keeps them whole and the derived data writers publish | nothing |
| `Writer` | every repository | shared bookmarks, derived data, versions that change only repositories |
| `Admin` | every repository | any version: members, roles, repositories; invites |

- Shared bookmarks and derived data are judged by the org record the peer holds now: a record a
  writer signed and a peer has not taken yet is refused once the writer lost the right.
- A public repository shows its shared bookmarks and their history to anyone on a server's web
  view; members read every repository either way.

## Shared bookmarks

- The shared bookmarks of a repository are one `Repo_Refs` record: org, repository, `seq`, the
  record before, the signer and its bookmarks sorted by name. Any writer signs the next one with a
  higher `seq` (`repo_refs_publish`, `team_publish`); a peer takes a record only when its signer
  writes the org now and its `seq` is newer than the one held, then the lower address
  (`repo_refs_accept`).
- They live under `kai-repo-<org hex>` refs, one per repository. A workspace's own bookmarks stay
  in its operations; a shared one is not an operation and moves for the whole org.
- `cook/kai`'s `publish` closes the working change when it changed a file or has a description and
  moves the bookmark (main by default) to what it closed, or to the working copy's parent when
  there was nothing to close; `bookmark_move` moves one to a given change (`mirai kai bookmarks
  move`). A publish to a public repository lists the paths named like secrets (`secret_paths`) so
  the person removes them and publishes again.
- `project_join` makes a workspace's repository a repository of an org in one version of its
  record, so no reader ever sees a repository without its public setting.
- `project_clone` makes a folder (empty, not there yet, or one a pull of the same repository left)
  a workspace of an org's repository at once; `clone_checkout` writes main's files the first time
  every object of it is here and says `Missing` until then.

## Invites

- Only an admin invites (`team_invite`): it keeps an `Invite` object with the org, the role, a
  random 32-byte secret, the expiry (`INVITE_HOURS`) and the person's name (this machine's with
  `--mine`, else whoever joins names itself), and prints one text, `kai2` and base32 of the org,
  the inviting device's key, the secret and the addresses to dial.
- The joining machine (`agent_join`) dials the addresses in order expecting that key: a machine
  that does not prove it is refused, so a beacon or a DNS lie cannot pose as the inviter. It
  proves the invite with an HMAC of the handshake hash under the secret in the last handshake
  message ([handshake](sync.md#the-handshake)), so the secret never travels and a recording of
  one handshake proves nothing in another.
- The inviting agent takes the invite (`team_invite_take`, which removes it: one invite, one
  device; expired ones go on the way), writes the next version of the org with the new member and
  sends `Welcome` with its address. The joining machine pulls the record back to the first version
  and holds only if it lists its key.
- A `Node` that names no `--public` address is listed at the address it dialed from and the port
  it listens on, so the org's machines dial the server without anyone typing it.
- Why no pairing code: the invite text is the secret and travels on a channel the people already
  trust (a chat, a call); the device key in it makes the first connection authenticated without a
  code to compare.
