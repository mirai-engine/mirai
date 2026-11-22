# Identity, orgs and the signed logs

Who a person, a device and an org are, how a machine proves it, and why no server is needed to agree
on who may do what. The code is `kai/machine.odin`, `kai/log.odin`, `kai/team.odin`, `kai/pair.odin`
and `kai/refs_ddc.odin`.

## Keys

- A **user** is a log (`User_Log`), not an account: no email, no password, no OAuth. Its genesis
  holds a recovery key `R`, the first device and its name.
- A **device** (a machine, a node or a browser's passkey) has an Ed25519 signing key and an X25519
  key. A machine makes them the first time it opens its store and keeps the seeds in owner-only
  files at the store's root, beside the objects they sign for; a copy of the store is a copy of the
  device, so a store is never shared between machines.
- The **recovery key** is an Ed25519 key shown once as Crockford Base32 with a checksum, to be kept
  offline. It is never stored and never crosses an API: no result of a method or a route carries it,
  an editor with no window refuses to make or rotate one before making anything, and `mirai kai
  identity` does it in a terminal. It may sign the entry that links a device when no device is
  active, and rotating it (`Recovery_Rotate`) needs the one in force.
- There is no org key. An org is a log folded from its members' signatures, and its **discovery
  secret** `D` is derived from the org's genesis, each valid removal of a member or a node in it
  and each revocation of a member's device, so only members and nodes know it and it changes when
  any of them goes: the one that went cannot follow the LAN beacons any more.
- A device proves it holds its key when it joins a log: the genesis and each `Device_Add` carry the
  device's signature over the recovery key or the log it joins, so a key cannot be added without its
  holder. A name is given where a device is made (the host's name when none is).

## The signed logs

- `User_Log`, `Org_Log`, `Project_Log`, `Proposal_Log` and `Keyring_Log` share one entry format, one
  DAG and one fold. An entry names up to eight parents by address (the BLAKE3 of its bytes); a log's
  id is the address of its genesis. An entry has its author's key and the head of the author's user
  log when it signed (`author_ctx`), so a peer can tell whether the device was active then.
- The entries of a log are kept as one object under `kai-log/<id>` (`kai-user/<id>` for a user,
  because a peer not admitted yet must read it to prove who it is). Peers merge by union of verified
  entries: an entry that does not verify is skipped and the rest are taken.
- Every kind of entry has a body whose fixed part is a packed struct and whose tail holds strings;
  whether a body is well formed is checked before the fold sees it. `GET /api/entries` on a node
  lays the bytes out for clients that sign in a browser.
- `Sig_Kind` is Ed25519 or WebAuthn. A WebAuthn entry carries the passkey's assertion; its author is
  the web key id (the BLAKE3 of the COSE key and the relying party), which the user's log records
  with `Web_Key_Add`. An entry therefore verifies alone and the fold says whose it is.
- The org, project, proposal and keyring logs are read only by members, nodes and grant holders: the
  roster, policies and scopes are not for anonymous readers, who get what a public project's shared
  bookmarks reach alone ([access](mesh.md#who-reads-what)).
- Adding to a log is always: build the entry, sign it with this device, fold the log again, keep the
  entry only when the fold takes it, save, and tell the mesh. An entry the fold refuses names what
  this device lacks (a role, a policy), through `m.why`.

## Folding and revocation

- Every peer folds the same entries to the same state: a topological walk, ties by address. An entry
  counts only if its author held the right in the state of its causal past. The walk runs again
  while a void changes who holds a right, which ends because the voided set only grows.
- A removal voids what its subject wrote concurrently, and the removal itself is never voided, so
  two admins who remove each other both go (`concurrent_admin_removals_fold_deterministically`).
- A `Device_Revoke` names, for each log the device signed in, the heads whose causal past its
  entries must be in. Whatever the device signs later, backdated or not, is outside that past and
  counts nowhere (`revocation_horizon_rejects_backdated_entries`). That is how a stolen device is
  stopped with no clock and no server; a revoked device stays in the log so it cannot be added
  again.
- An org's member removal is in the org's own DAG, so its causal past is its horizon. A policy
  guards the moves outside the causal past of the project heads its `Policy_Set` names; the moves
  inside keep the rules they were made under.
- What is void is decided by the fold and never by arrival time: a peer that was offline merges what
  it missed and finds the same state every other peer has.

## Roles and rights

- Roles are reader, writer, admin and owner. A role's rights: a reader reads; a writer also writes
  refs, publishes derived data and signs checks; an admin and the owner also run a relay. The rights
  of a grant are the same names and never exceed its issuer's.
- Only an admin adds a member, sets a role at or below their own, adds a project, a scope, a policy,
  a node, a public path or a grant, and revokes grants. A member can always remove themselves; the
  owner cannot be removed and hands the org over with `Owner_Transfer` first.
- A project is public or the org's alone. Anyone who reaches a member or a node reads a public
  project's closure; a private one only an org member does.
- A node is a key the org's log names (`Node_Add`) with the modes it serves and the addresses it
  listens at. An org serves only the nodes its log names.

## Pairing

- Pairing links a second device to a user (`Device_Add`), adds a member (`Member_Add`) or adds a
  node (`Node_Add`). The responder offers a ticket (base64url with a checksum): which pairing,
  against which responder key, until when, and where the responder listens. The logs, envelopes and
  keyrings the new end needs come through the mesh once it connects.
- The handshake is `Noise_XX_25519_ChaChaPoly_SHA256` with a commitment: the initiator commits to
  its static key and nonce in its first message and reveals them only after the responder showed its
  own; the responder checks the commitment before any code exists. The eight digits both screens
  show hash only values each side fixed before it saw the other's nonce: no label, no info and no
  transcript hash enter them, so a man in the middle has nothing left to vary
  (`pairing_rejects_mitm_label_grinding`).
- A person must approve the request on the responder: nothing is the default, an unanswered request
  is denied after a timeout, and several denials in a row pause pairing for a while. One request is
  open at a time. A code given to `mirai kai pair approve` must be the one shown or the request is
  denied, and the editor's dialog has no default: Enter and Escape answer nothing.
- A pairing needs a runner on the offering machine ([the runner](mesh.md#the-runner)); the command
  says so when none runs.

## Grants

- A grant gives a key outside the org some rights for at most thirty days: org, org head, issuer,
  the subject's X25519 key, rights (read, write, ddc, check, relay), project, a path scope and its
  end. It is verified against the org's log (issued by an admin at that head and still one, within
  the issuer's rights, not expired, not revoked), so a revoked or expired grant cuts its holder off
  at that moment, with `Revoked` on the connection.
- The issuer hands it over as text with its agent's X25519 key and addresses; the holder's agent
  reaches the issuer first and is admitted as `Grant`. A holder is never a member, so it connects to
  every peer itself.
- The path scope is a pattern as `Scope_Add` takes; empty is the whole project. What a holder is
  served is a set of addresses made as the public closure is: its project's changes and, of each
  tree, only the files the scope covers with the folders on the way to them; with the ddc right, the
  untainted derived data. It writes refs only under the write right and only changes it signed that
  touch paths inside its scope (`a_grant_holder_reads_and_writes_only_its_scope_until_it_ends`).

## Device refs

- A device writes only its own ref, `kai-refs-<project>/<device>`, naming a record it signed with a
  sequence number: bookmark names and their targets. A peer takes a newer record only when it is
  signed, its device may write the project now and its sequence is higher than the one held, so a
  peer or a seed cannot roll a device's bookmarks back (`device_refs_reject_rollback`).
- Ref names stay in the store's character set; what people read, `<handle>/<device>:<bookmark>`,
  comes from the logs.
- The bookmarks of a workspace publish as its device's refs after each operation that changed them,
  and in a public project the publish scanner reads what each bookmark adds first
  ([guardrails](private.md#leak-guardrails)).
- Shared bookmarks such as `main` are entries of the project's log, moved for the whole org
  (`Bookmark_Move`); moves that diverge become conflict terms with the same algebra as files.
