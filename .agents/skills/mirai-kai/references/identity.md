# Identity, orgs and the signed logs

Who a person, a device and an org are, how a machine proves it, and why no server is needed to agree
on who may do what. The code is `kai/machine.odin`, `kai/log.odin`, `kai/team.odin`, `kai/pair.odin`
and `kai/refs_ddc.odin`.

## Keys

- A **user** is a log (`User_Log`), not an account: no email, no password, no OAuth. Its genesis
  holds a recovery key `R`, the first device and its name; or, for a user born in a browser
  (`Passkey_Genesis`), only the passkey that signs it.
- A user born of a passkey has no recovery key and no device: the page that makes it generates
  no key. Its passkey may link devices and passkeys (`Device_Add`, `Web_Key_Add`) while it has no
  recovery key, and nothing else of the user's log; its first device sets the recovery key
  (`Recovery_Rotate` signed by a device when the user has none). Until then the user acts with at
  most a writer's rights in any org: it reads, comments, approves and signs checks, and holds no
  admin or owner right, whatever role an admin gives it.
- A **device** (a machine, a node or a browser's passkey) has an Ed25519 signing key and an X25519
  key, and a machine also an ML-KEM-768 key the [epoch keys](private.md#keyrings-and-epochs) are
  wrapped to. A machine makes them together the first time it opens its store and keeps the seeds in
  owner-only files at the store's root, beside the objects they sign for (a node reads them before
  its sandbox closes); a copy of the store is a copy of the device, so a store is never shared
  between machines. The user's log records the device's public keys where it adds it (the
  device-born genesis and `Device_Add`; a passkey has none), and an ML-KEM key that is no
  encapsulation key makes the entry `Corrupt`.
- The **recovery key** is an Ed25519 key shown once as Crockford Base32 with a checksum, to be kept
  offline. It is never stored and never crosses an API: no result of a method or a route carries it,
  an editor with no window refuses to make or rotate one before making anything, and `mirai kai
  identity` does it in a terminal. It may sign the entry that links a device when no device is
  active, and rotating it (`Recovery_Rotate`) needs the one in force. A rotated key signs nothing
  beside its rotation: what it signs on parents that skip the rotation is void.
- **Recovering** a user after every device is lost: on a fresh store, its user's log comes from a
  machine of one of its orgs through a `recover` pairing (nothing is signed: the new machine
  reaches the org as a peer not admitted, which reads the user logs alone; a user alone in its org
  needs a node of it), and `mirai kai identity recover <user>` (or the editor's Team view) takes
  the recovery key as printed: it signs this device into the log and revokes every device still
  active; passkeys stay. A mistyped key says what is wrong with it (a character, the count of
  digits, the checksum) and never echoes it. What the lost devices signed stands (they are
  witnessed on every head, below), so the user still owns its orgs, projects, proposals and
  keyrings; once the agent fetched the orgs' logs, the recovery key gives the new device the keys
  of the scopes the user reads ([the recovery key reads](private.md#keyrings-and-epochs)), and
  running the command again does that for what came since
  (`a_user_recovers_onto_a_new_device_with_its_recovery_key`).
- There is no org key. An org is a log folded from its members' signatures, and its **discovery
  secret** `D` is derived from the org's genesis, each valid removal of a member or a node in it
  and each revocation of a member's device, so only members and nodes know it and it changes when
  any of them goes: the one that went cannot follow the LAN beacons any more.
- A device proves it holds its key when it joins a log: the genesis and each `Device_Add` carry the
  device's signature over the recovery key or the log it joins, its X25519 key and the BLAKE3 of
  its ML-KEM key, so no key of a device can be added or swapped without its holder. A name is given
  where a device is made (the host's name when none is).

## The signed logs

- `User_Log`, `Org_Log`, `Project_Log`, `Proposal_Log` and `Keyring_Log` share one entry format, one
  DAG and one fold. An entry names up to eight parents by address (the BLAKE3 of its bytes); a log's
  id is the address of its genesis. An entry has its author's key and the head of the author's user
  log when it signed (`author_ctx`), so a peer can tell whether the device was active then.
- An entry of a project's, a proposal's or a keyring's log also names the entry of the org's log
  it was signed under (`org_ctx`): its author's rights are judged there, never in the org's state
  of now.
- A log is kept as pages of a trie by entry address under a small index (kind, count, root page,
  heads) that the ref `kai-log/<id>` names (`kai-user/<id>` for a user, because a peer not
  admitted yet must read it to prove who it is). A leaf of more than `LOG_PAGE_ENTRIES` entries
  splits by the next byte, so the pages are a function of the entries alone: peers holding the
  same entries hold the same index, and an append rewrites one leaf, the branches above it and
  the index. A peer fetches the pages it lacks and merges by union of verified entries: an entry
  that does not verify is skipped and the rest are taken.
- Every kind of entry has a body whose fixed part is a packed struct and whose tail holds strings;
  whether a body is well formed is checked before the fold sees it.
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

- Every peer folds the same entries to the same state: one walk of a topological order, ties by
  address. In a user's or the org's log an entry counts only if its author held the right in the
  state of its causal past, which the walk replays per subject from the entries before it.
  Ancestry is a lookup in chain clocks, so a log folds in near-linear time; the worst case is a
  removal that voids entries the walk passed, which walks again from the first of them.
- A removal voids what its subject wrote concurrently, and the removal itself is never voided, so
  two admins who remove each other both go (`concurrent_admin_removals_fold_deterministically`).
- In a project's, a proposal's or a keyring's log an entry holds if its author held the right at
  its `org_ctx`, lowered by each removal or lowering `Role_Set` of the author that `org_ctx` does
  not hold and that the entry does not stand against.
- **Witnesses.** A removal says nothing of other logs: a `User_Log` names no org, project or
  proposal. What it affects in another log (a `Device_Revoke` there, a `Member_Remove`, a lowering
  `Role_Set` or a `Grant_Revoke` in the org's other logs) reaches that log as a `Witness` entry,
  written by a key that holds a right there when it first sees the removal: the machine that
  removes, with every head it knows, and any member's agent that finds a removal a log lacks,
  on what other keys signed; a device of the user whose device was revoked builds on every head
  it knows, as the machine that revoked: the user vouches for what its devices signed until then,
  and where they signed the whole log, as a lone owner's did, nothing else is there to build on. In
  that log an entry by the affected key stands if and only if it is in the causal past of a valid
  witness; with none yet, the removal has not reached the log and its entries stand
  (`revocation_witness_rejects_backdated_entries`, `a_removed_writer_keeps_its_past`,
  `removing_a_keyring_signer_keeps_its_epochs`).
- A removal is witnessed in every log of the org where the key held a right when it came, signed
  there or not: the org's for a device, each project and keyring for a writer, each open proposal
  for any member. So a removed key has no log to sign first in. A log born after the removal (its
  genesis signed under an org entry that holds it, or for a device a witness of its revocation in
  the org's log) takes none: every entry of it is judged with the removal. A closed or landed
  proposal takes none either: it counts for nothing until it is reopened, a landed move reads it
  only at the heads the move names, and the agents that load it once it is open again witness what
  it lacks, with parents that leave out what the removed keys signed.
  The org's own witness of a device's revocation also lets the org's heads carry it to a peer
  that lacks it.
- A witness is valid when it names a valid removal, its author is not affected by it and holds a
  right in the log (a member in the org's and a proposal's log, a writer in a project's and a
  keyring's), and no valid witness of that removal is in its causal past. Witnesses unite: a
  dishonest one written on old heads cannot void what an honest one holds, and an entry signed
  after every witness counts nowhere. An agent's witness builds on what other keys signed, so an
  entry of the removed key that no one built on stays out; an entry signed after the removal gets
  in only if a key holding a right there builds on it before it sees the removal, as it could sign
  its own. A dishonest member's witness gains it nothing: on heads that hold a removed key's late
  entries it lets them stand, which the member could do by signing those entries itself, and on
  old heads it voids nothing an honest witness holds.
- A revoked device stays in its user's log so it cannot be added again; there, its entries count
  only in the causal past of the revocation.
- A policy guards the moves outside the causal past of the project heads its `Policy_Set` names;
  the moves inside keep the rules they were made under.
- An entry's time is the signer's, but never before its causal past or its `org_ctx`: what the
  fold reads as its time is the latest of them.
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

- Pairing links a second device to a user (`Device_Add`), adds a member (`Member_Add`), adds a node
  (`Node_Add`) or lets a machine with no user reach an org to recover its user (`recover`). The
  responder offers a ticket (base64url with a checksum): which pairing, against which responder key,
  until when, and where the responder listens. The logs, envelopes and keyrings the new end needs
  come through the mesh once it connects, and a reader's agent wraps the newest key of each scope
  the new device or member reads for it, with no rotation
  ([keyrings](private.md#keyrings-and-epochs)).
- The handshake is `Noise_XX_25519_ChaChaPoly_SHA256` with a commitment: the initiator commits to
  its static key and nonce in its first message and reveals them only after the responder showed its
  own; the responder checks the commitment before any code exists. A device's ML-KEM key does not
  fit the third message: its info carries the key's BLAKE3, and the key follows in two frames
  sealed under the keys the handshake split; the responder shows the request only once they hash
  to what the info said. The code covers what it covered before, and a middle that swaps the key
  must swap the hash too, which only an end of the session writes, so the two screens' codes
  differ (`pairing_links_a_device_and_adds_a_member`). The eight digits both screens
  show hash only values each side fixed before it saw the other's nonce: no label, no info and no
  transcript hash enter them, so a man in the middle has nothing left to vary
  (`pairing_rejects_mitm_label_grinding`).
- The initiator dials the ticket's addresses. A responder none of them reaches (it is behind a
  router and the initiator is not) is given the initiator's address and knocks there: a datagram
  with a tag keyed from the ticket's id, never the id, answered by nothing. The initiator only
  adds the knock's source to the addresses it dials, so a knock gives no more than a ticket
  address does and the handshake, the commitment and the code are what they were
  (`a_node_no_ticket_address_reaches_is_paired_through_knocks`).
- A person must approve the request on the responder: nothing is the default, an unanswered request
  is denied after a timeout, and several denials in a row pause pairing for a while. One request is
  open at a time. A code given to `mirai kai pair approve` must be the one shown or the request is
  denied, and the editor's dialog has no default: Enter and Escape answer nothing.
- A pairing needs a runner on the offering machine ([the runner](mesh.md#the-runner)); the command
  says so when none runs.

## Grants

- A grant gives a key outside the org some rights for at most thirty days: org, org head, issuer,
  the subject's X25519 key, rights (read, write, ddc, check, relay), project, a path scope and its
  end. For a connection or a record it is verified against the org's log now (issued by an admin
  at that head and still one, within the issuer's rights, not expired, not revoked), so a revoked
  or expired grant cuts its holder off at that moment, with `Revoked` on the connection.
- An entry a holder signs under a grant (a check) is judged as of its signing: the grant is in the
  causal past of the entry's `org_ctx` with its issuer an admin there, the entry's time (never
  before its causal past) is inside the grant, and a revocation of the grant, or a removal of its
  issuer, voids it only through a witness as above (`a_grant_signs_checks_only_while_it_holds`).
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
  sequence number: bookmark names and their targets, and the heads of the org's log its store had,
  by which a peer fed a stale org log learns it is [behind](mesh.md#behind). A peer takes a newer
  record only when it is signed, its device may write the project now and its sequence is higher
  than the one held, so a peer or a seed cannot roll a device's bookmarks back
  (`device_refs_reject_rollback`).
- Ref names stay in the store's character set; what people read, `<handle>/<device>:<bookmark>`,
  comes from the logs.
- The bookmarks of a workspace publish as its device's refs after each operation that changed them,
  and in a public project the publish scanner reads what each bookmark adds first
  ([guardrails](private.md#leak-guardrails)).
- Shared bookmarks such as `main` are entries of the project's log, moved for the whole org
  (`Bookmark_Move`); moves that diverge become conflict terms with the same algebra as files.
