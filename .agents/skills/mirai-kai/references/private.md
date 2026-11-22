# Private files in a shared project

A project can be public, or shared with an org, and still keep some files (a `.env`, licensed
assets) readable only by some members. The code is `kai/overlay.odin`, `kai/team.odin` and
`cook/kai/team_view.odin`; the tests are in `kai/overlay_test.odin`.

## Scopes and routing

- A scope is an entry of the org's log (`Scope_Add`): patterns, the lowest role that reads it
  (`readers`) and whether it keeps history. The patterns live only in the org's log, which public
  readers never get, so what a public reader can learn about private files is nothing, not even that
  they exist (`public_peer_sees_zero_overlay_metadata_or_chunks`).
- A pattern is `*` and `?` within one name, `**` across folders, `**/` for zero or more. One without
  `/` matches the last name of a path, one with `/` the whole path from the root, one ending in `/`
  everything under that folder. The first scope in the log's order whose pattern matches takes a
  path.
- A snapshot routes the paths a scope takes out of the public tree into one overlay per scope and
  commit, sealed under the scope's newest key. Their plaintext never reaches `store.put` and the
  public change never names an overlay (`scoped_plaintext_never_enters_public_store`), so a copy of
  the public tree, a seed or a web view cannot leak what a person kept private. Routing is part of
  the snapshot, never a pass after it, because a secret scanned only after publication is already
  published.
- A change holds the overlay written for its own commit or, before it has one, its first parent's.
  Every rewrite (a snapshot, describe, restore, rebase, split, the descendants it moves) carries the
  overlays to the new commit in its operation's commit by signing a new record over the same sealed
  tree and objects, so it needs no key and encrypts nothing again: a device that does not read a
  scope carries its records all the same and never leaves a rewritten change without them.
- A reader's working copy shows the private files of the scopes its device reads: a switch writes
  those of the change it moves to, and removes the ones the change it left held and that still hold
  what that change had, so a local edit is never deleted. A scope the device may no longer read
  takes its files away, except that a file whose last copy is this device's, unchanged, stays out of
  its snapshots so it is not lost to a revocation.
- A snapshot refuses, saying which path and how to fix it: a path of the deny set that no scope
  takes and no admin kept public, a scoped path whose scope needs a new key first, and a scoped path
  this device cannot read. The editor shows it at the head of CHANGES with the button that resolves
  it, and `mirai kai snapshot` prints it.

## Keyrings and epochs

- Each scope has a `Keyring_Log`. An epoch is a random 32-byte key wrapped for every active device
  of the members who may read the scope, under X25519 and ML-KEM-768 at once: a fresh X25519 share
  and an ML-KEM encapsulation to the device's key, both shared secrets through HKDF-SHA256 salted
  with the BLAKE3 of the KEM ciphertext, the share and the device's two public keys, then
  AEGIS-256 (`an_epoch_key_opens_only_with_both_device_secrets`). Both must be broken to open it,
  because sealed files stay for years with parties that hold no key (a seed's operator, members
  who do not read the scope, former members), and the per-device wrap is what a quantum computer
  would break. The rest of the sealing is symmetric and stays as it is.
- The envelopes of an epoch are one `Envelopes` object of the store, sorted by device, that the
  `Epoch_Add` names: a list of devices does not fit an entry's body. Whatever keeps a keyring
  alive (`store_live`, a member's set) and syncs it to a peer walks it with the log. When the
  scope keeps history, the entry holds the previous key under the new one (`previous`), so a
  reader who has the latest opens every earlier epoch; a scope that keeps none wraps nothing.
- Not hybrid, on purpose, one reason each:
  - the mesh's handshakes: a datagram cannot carry ML-KEM, and nothing stored depends on them;
  - pairing's key agreement: it lives seconds, and the ML-KEM key it carries is bound by the
    device's proof, which the log keeps;
  - TLS: a recorded session holds what the web view serves, never a scope key;
  - the logs' signatures: a signature must hold only until the peers hold the entry, and every
    peer keeps it then, so a forgery made later changes no log anyone holds.
- A write is refused while the newest epoch still wraps for a device that may no longer read the
  scope: after a member or a device leaves, any remaining reader rotates (`mirai kai scope rotate`,
  the editor's Rotate the key) and writing goes on. Rotation is lazy on purpose: nothing needs to be
  online when someone leaves, and a removed member cannot decrypt what is written after the epoch
  that follows their removal (`removed_member_cannot_decrypt_post_rotation_epoch`).
- What a removed member already downloaded stays readable by them: the keys of past epochs are
  theirs. Kai guarantees what happens after rotation, not retroactive secrecy.
- Only a device that reads the scope can wrap a key; a seed or relay has envelopes it cannot open.

## Sealing

- Each private file has a random file id kept across edits and renames, so a rename does not
  re-encrypt. Its keys come from the epoch key and the file id with HKDF. The file is cut into
  chunks, each compressed, padded to a length that leaks only a few bits of its size (Padme), and
  sealed with AEGIS-256 under a nonce that is a keyed hash of the padded chunk.
- The nonce is keyed on the plaintext and the file's own key on purpose: the same chunk of the same
  file in the same epoch seals to the same bytes, so an edit deduplicates within its file, and the
  key being per file and epoch, nobody can confirm a guessed plaintext against the store.
- The tree of an overlay (paths, file ids, sizes, objects) is sealed under its own key, so a node
  that mirrors the overlay learns no names. Every address in a record names ciphertext, which is
  what lets a seed mirror all of it without any key.
- An overlay record is signed by a device of a writer and is accepted only when it is newer than the
  one held (`seq`), so a peer cannot roll private content back. Whatever does not open, or opens to
  a shape no sealer writes, is `Corrupt`.

## Leak guardrails

- The deny set (`DENY_PATTERNS`: names that look like keys and environment files) is refused at
  snapshot unless a scope takes the path or an admin kept it public with a `Public_Add` (`mirai kai
  public add <path>`). The editor offers Keep public there.
- The **publish scanner** runs when bookmarks of a public project are published: it reads each text
  file a bookmark adds or changes and refuses a private key, a token with the prefix of a known
  issuer, or a long random value assigned to a secret-looking name. A binary file (a NUL in its
  first block) is not read. The publish names the file and the line, and an admin may waive one leak
  by its fingerprint, which does not contain the secret (`mirai kai public add <path>:<line>`).
- The scanner and the deny set are guardrails against mistakes, not a security boundary: what must
  not be public goes into a scope.
- In a public project what a shared bookmark reaches is public: anonymous peers read it and
  nothing a device's refs or a proposal alone name ([access](mesh.md#who-reads-what)). The scanner
  still runs on every publish, since a work in progress becomes public when a bookmark moves to
  it; what must stay private goes in a scope or a private project.
- `deny_set_and_publish_scanner_block_leaks` is the test of both.

## What a peer sees

- A member who does not read a scope sees ciphertext in the store and nothing in the tree. A node
  never sees a key: keyrings are wrapped for devices that read, and a node is not one of them.
- A public peer fetches only the public closure; the overlay namespace is not in its set.
- A cook's output built from private inputs is sealed under every input's scope at once and marked
  with those scopes as tainted ([derived data](mesh.md#derived-data)), so a derived cache never
  becomes the way a secret leaves its scope.
- A browser never reads an overlay: the web view serves only the public tree of a project, and
  routes leave out any path a scope of the project's org takes.
