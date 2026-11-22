# Plan: Kai (Phase 2 — Native VCS, Orgs, P2P Sync and Repo Server)

Design blueprint for **Kai**, Mirai's native, data-oriented, zero-legacy version control and
peer-to-peer distribution system built on `store`, `net` and `exchange`. Everything here is
proposed design; facts about current code are cited by file.

---

## 1. Scope and Phase Boundary

### Phase 2 (this plan)
- **Mirai projects move 100% to Kai.** Git support for Mirai projects is deleted completely with
  zero backward compatibility.
- **Engine-agnostic core from day one.** `std/diff` (layer 0) and `kai` (layer 4) import nothing
  from `core`, `asset`, `project` or `editor`. Mirai-specific merge drivers and project filters
  live in `cook/kai` (layer 7); UI, live authorship and collaboration live in `editor` (layer 7).
- **Zero-server default, optional ARM64 node.** Works locally and on LAN without any server; an
  optional single-binary ARM64 Odin node (`mirai kai serve`) adds NAT traversal/relay, always-on
  seed/DDC hosting and a GitHub-like web view over Proposals and Changes.

### Deferred to Phase 3 (general code and the Mirai engine itself)
- Standalone `kai` binary distributed independently of `mirai`.
- Generic `.kaiignore` globs and POSIX symlink tracking (Phase 2 uses `project.own_path`, which
  excludes `.mirai/` and rejects symlinks).
- Power-user terminal CLI: revset query language, interactive hunk `split`, `bisect`, `absorb`,
  terminal `blame`, pager and shell completions.
- Arbitrary external CI script runners (Phase 2 signs `Check` events from Mirai peers running
  `mirai test`, `mirai scene check` and `mirai build`).
- Moving the Mirai engine repository, `cook/workspace` worktrees and `cook/install` plugin catalog
  off Git, plus any optional `kai git import/export` bridge.

---

## 2. Legacy and Non-DoD Audit (Deleted, Zero Backward Compatibility)

### Code deleted from Mirai in Phase 2

- **Subprocess Git client and text parsing** (the old `editor/git` package and the Git files of
  `editor`): replaced by in-process `kai` over `store` + `kai.*` API; `git.*` becomes
  unknown.
- **Fixed-width path/hash structs** (`[260]u8`, `[16]u8` in the old `editor/git`): replaced by
  string pools (`offset`, `len`) and full 32-byte `store.Hash`.
- **Staging index** (`Keep`/`Unkeep`, `pending`/`kept`, `git_keep_front`): replaced by working
  copy as a change (`@`) and post-hoc `split` by whole files (`kai.change_split`, one operation;
  the first half keeps the change's id). No persistent marks; picking hunks stays in Phase 3.
- **Blocking merge mode** (the old merge and review of the Git tab, `git show :N:`):
  replaced by algebraic `Conflict` values stored in trees that never block work.
- **External merge/diff drivers, `.gitattributes`, LFS** (the old Git setup of `cook/build`,
  `mirai setup git`): replaced by in-process `Driver` procedures in `cook/kai` and FastCDC in
  `store`.
- **Git-required and pending-quit modals** (`git_missing_modal`, `git_pending_modal`): deleted;
  working copy snapshots automatically.
- **`COLLAB_FILE_BYTES` (32 MiB cap) and Git fallback** (`editor/collab_files.odin`): `File` sends
  `{path, address, size}` fetched over `exchange`.
- **Duplicate 3-way merge and `map[string]Known` stat cache** (`cook/share/join.odin`,
  `.mirai/share/index`): replaced by `kai.merge` and chunked `Stat_Row` workspace index in `store`.
- **Capped Myers diff** (the old `editor/diff` package, `max_edits=2048`, O(D^2) trace): replaced
  by `std/diff` Histogram diff + 3-way merge in O(n+m) memory.

### Legacy patterns explicitly refused
- **Accounts and central auth:** email/password, OAuth/OIDC/Google, SAML, magic links, TOTP/SMS,
  long-lived PATs/deploy keys, or a server deciding membership or branch protection.
- **SSH and ECO leftovers:** `authorized_keys`/`CLIENTS` text files, TOFU `known_hosts`, agent
  forwarding, algorithm negotiation, KCP/TCP-bulk hacks, C platform wrappers, or static IP env
  vars.
- **Git/GitHub leftovers:** loose objects, SHA-1, LFS pointers, `git-crypt` per-file leaks,
  `.gitignore` as a security boundary, mutable-branch PRs that lose anchors on force-push, and
  Unison-style AST-only storage (code stays files + 3-way text merge; Mirai assets use structural
  drivers).
- **Secret-handling traps:** convergent encryption, single eternal repo key, or scanning secrets
  only after publish.
- **Deployment bloat:** Kubernetes, Helm, sidecars, Postgres, Redis, heavy SSR/microservice
  stacks, third-party analytics, or relying on overlayfs/NFS for `store`.

---

## 3. Layers and Package Boundaries

Additions to [ARCHITECTURE.md](ARCHITECTURE.md#package-map):

- **Layer 0 `std/diff`** (no imports): Histogram diff over interned `u32` line ids, 3-way merge,
  view rows.
- **Layer 4 `kai`** (imports `std/*`, `store`, `exchange`, `net`, `core:crypto/*`): records, trees
  (moved from `cook/share`), conflict algebra, op log, workspaces, graph index, unified DAG logs,
  identity/pairing, encrypted overlays, P2P sync and `Driver` interface.
- **Layer 7 `cook/kai`** (imports `kai`, `asset`, `project`, `cook/cache`): Mirai structural merge
  drivers (`asset.document_merge` / `scene_merge`) and project filter (`project.own_path`).
- **Layer 7 `cook/share`** (imports `kai`): one-off share offer/library transport reusing `kai`
  trees and merge.
- **Layer 7 `editor`** (imports `cook/kai`): Kai panel, `kai.*` API, conflict UI, `Kai_Authorship`
  queue and address-based collab files.
- **No layer `tools/mirai`** (imports `cook/kai`): `mirai kai ...` and headless `mirai kai serve`
  (with web view).

A test enforces that `kai` never imports `core`, `asset`, `project`, `host`, `engine/*`, `cook/*`
or `editor`.

---

## 4. Data-Oriented Model in `store`

Every Kai object is one `store` object with `KAI_MAGIC`, kind and version in its root meta, a
`#packed` little-endian head, count-prefixed flat arrays and a trailing string pool. Zero pointers
in stored structs; reserved bytes are zero; hostile inputs return `Corrupt`; older/other versions
are refused without migration. Signatures cover all preceding bytes and are verified on peer import
and `kai verify`, never on local reads.

### 4.1 Core VCS objects

```odin
Change_Id   :: distinct [16]u8   // random at creation; preserved across rewrites
Revision    :: store.Hash        // content address of one Change object
Key         :: distinct [32]u8   // Ed25519 public key
Dh_Key      :: distinct [32]u8   // X25519 static public key
Signature   :: distinct [64]u8

Change_Head :: struct #packed {
    magic: u32, version: u16, reserved: u16,
    id:          Change_Id,
    tree:        store.Hash,     // root Folder (public tree only; never references overlays)
    author:      Key,            // accountable device/user signing key
    created:     i64,            // ns, kept across rewrites
    written:     i64,            // ns, this revision
    parents:     u8,             // <= PARENTS_MAX (255)
    coauthors:   u8,             // <= COAUTHORS_MAX (64)
    turns:       u8,             // <= TURNS_MAX (64)
    reserved2:   u8,
    description: u32,            // UTF-8 byte length
} // + [parents]Revision, [coauthors]Key, [turns]Turn_Ref, description, Signature

Turn_Ref :: struct #packed {
    agent:  store.Hash,          // Identity object
    record: store.Hash,          // public review record (never private chat transcript)
    task:   u64,
}
```

- **Tree:** `cook/share/snapshot.odin` format 2 moved into `kai` and versioned. Folder entries are
  sorted by name: `{kind: Entry_Kind, name_len: u8, name, address, size: u64, files: u32,
  conflicts: u32}`. `Entry_Kind :: enum u8 {File, Executable, Folder, Conflict}`. Checking whether
  a tree has conflicts is O(1): `root.conflicts == 0`.
- **Algebraic Conflict (Jujutsu-style):**
  ```odin
  Term :: struct #packed {address: store.Hash, size: u64, kind: Entry_Kind, reserved: [7]u8}
  Conflict_Head :: struct #packed {
      magic: u32, version: u16, sides: u8, reserved: u8, driver: u32,
  } // + alternating terms: side0, base0, side1, base1, ..., side_n (sides <= 16)
  ```
  Equal `(side, base)` pairs cancel on write; a single remaining side collapses to a plain entry;
  all-folder terms recurse; rebasing composes terms without losing information.
- **Operation Log and Views:**
  - `Op_Kind :: enum u8 {Snapshot, New, Describe, Rewrite, Merge, Abandon, Restore, Bookmark,
    Workspace, Import, Undo, Proposal}`.
  - Each `Operation` points to parent ops, a `View` (sorted `heads`, `workspaces`, and `bookmarks`
    where diverged bookmarks use the same conflict algebra) and `rewrites: []{from, to: Revision}`.
  - One op = one `store` batch commit (single flush, atomic).
  - `Undo` writes a new op whose view applies a 3-way inverse of the undone op; undo itself can be
    undone.
  - Predecessor history lives in `Operation.rewrites`, never in `Change`, keeping change hashes
    purely content-addressed.
- **Workspaces (multiple working copies, no FS CoW required):**
  - `<root>/.mirai/kai/workspace` stores `{repo, id, op}` and carries an OS file lock per workspace.
  - Stat index is a chunked `store` object of sorted `#packed` `Stat_Row{size, mtime_ns, inode,
    address, path_at, path_len, flags}` + path pool, respecting `SETTLED_NANOSECONDS` (no racy
    clean).
  - Materializing writes from mapped packs to temp + atomic rename; optional `file_clone` in
    build-tagged `kai/system_*.odin` uses APFS `clonefile` / Btrfs `FICLONE` / ReFS
    `FSCTL_DUPLICATE_EXTENTS` when copying a clean file from a sibling workspace, falling back to
    copy when unsupported.
- **Graph Index:** Derived `store` object with dense arrays (`revisions`, `parent_ranges`,
  `generation: []u32`, `change_id`) extended incrementally for bounded BFS ancestry and merge-base
  queries.

### 4.2 Unified Signed DAG Logs (One Structure for All Governance and Reviews)

`User_Log`, `Org_Log`, `Project_Log`, `Proposal_Log` and `Keyring_Log` share one signed DAG object
format and one deterministic fold algorithm:

```odin
Entry_Head :: struct #packed {
    magic: u32, version: u16, kind: u8, parents: u8, // <= 8; genesis has 0
    log_id:     store.Hash,
    author:     Key,          // device ds, recovery R, or web key id
    author_ctx: store.Hash,   // head of author's User_Log when signing
    time:       i64,
    body_len:   u32,
    sig_kind:   u8,           // 0: Ed25519, 1: WebAuthn (for browser reviews)
    reserved:   [3]u8,
} // + [parents]store.Hash, body, signature
```

- **Deterministic fold:** Topological walk breaking ties by entry address. Each entry applies only
  if `author` held the required right at that point. Concurrent remove vs any write on the same
  subject: remove wins. Two admins removing each other concurrently: both removed.
- **Revocation horizon (stops backdating without a server):** `Device_Revoke{device,
  horizon: [](log_id, heads)}` invalidates any entry by that device outside the causal past of the
  named heads. `Member_Remove` lives in the org DAG itself, so its causal past is its horizon.
- **Log kinds:**
  - `User_Log`: `Genesis{R_pub, first_device}`, `Device_Add{ds, dh, name}`, `Device_Revoke`,
    `Recovery_Rotate{R'}`, `Web_Key_Add{credential_id, cose_pub, rp_id}`.
  - `Org_Log` (readable only by org members/nodes): `Genesis`, `Member_Add`, `Member_Remove`,
    `Role_Set` (`owner > admin > writer > reader`), `Owner_Transfer`, `Project_Add{public|org}`,
    `Scope_Add{project_id, scope_id, patterns[], readers, history}`, `Scope_Remove`,
    `Policy_Set{project_id, bookmark, approvals, required_checks[], project_heads[]}`, `Grant`,
    `Grant_Revoke`, `Node_Add{ds, dh, addrs[], modes}`, `Node_Remove`,
    `Public_Add{project_id, path, leak_fingerprint?}`.
  - `Project_Log`: `Bookmark_Move{bookmark, from[], to, proposal_head?}` (shared bookmarks like
    `main`; conflicts use the same algebra; every peer verifies `Policy_Set` locally). A policy
    guards the moves outside the causal past of the project heads its `Policy_Set` names; those
    inside keep the rules they were made under.
  - `Proposal_Log` (replaces GitHub PRs): `Open{project, target, title, text}`,
    `Revise{stack[change_id -> revision]}`, `Comment{anchor, reply_to, text}`,
    `Verdict{approve|changes|withdraw, revision}`, `Check{revision, name, state, log_root}`,
    `Land{revision, bookmark_move}`, `Close`, `Reopen`.
  - `Anchor` supports `File`, `Lines` (re-anchored across rewrites by `std/diff` Histogram) and
    `Structural` (`key: u64` e.g. `Entity_Id` + table/field, re-anchored by the Mirai driver).
    Comments follow `Change_Id` across rewrites; approvals carry over only when the interdiff is
    empty; landing requires `root.conflicts == 0`, approvals and signed `Check` events on final
    revisions.
- **Signed Device Refs (store-charset safe, rollback-proof):**
  - Store ref names allow only `[a-z0-9._-]`. Display names (`<handle>/<device>:<bookmark>`) are
    resolved from logs.
  - Each device writes only its own ref `kai-refs-<project hex>/<ds hex[:32]>` pointing to a signed
    `Device_Refs{project_id, device, seq: u64, prev, refs[]{bookmark, target}, sig}`.
  - Peers accept a newer `Device_Refs` only if signature verifies, device has write authority, and
    `seq` strictly increases (blocks peer/seed rollback).
  - Local-only state (workspace op heads, stat indices, local private overlays) lives in
    `kai-local-<project hex>`, never exposed by `exchange`.

---

## 5. Diff, Merge and Performance

- **`std/diff`:** Interns lines to `u32` ids in a single hash table sized to the inputs, runs
  Histogram LCS (high-frequency regions collapse to one replace hunk for guaranteed O(n+m) memory),
  and implements 3-way merge (`merge3`). Derived from Apache-2.0 `jj-lib`/`imara-diff` (never GPL
  `git` xdiff), recorded in `THIRD_PARTY_NOTICES.md`.
- **In-process `Driver` interface (`kai`):**
  - Pure, deterministic procedures run on `std/jobs`: `merge(terms, reader, put) ->
    Resolved|Conflicted|Unsupported|Error` and `anchor(from, to, ^Anchor) -> bool`.
  - `cook/kai` registers the Mirai asset driver over `asset.document_merge` / `scene_merge`
    (row-by-id, field-by-field) and caches results in `cook/cache` by `(driver, version, terms)`.
  - **Non-blocking conflict resolution:** Checkout writes the driver's partial result (document
    with conflicts defaulted or text diff3 markers) and records `{path, conflict, written_hash}`.
    On snapshot, if the file still hashes to `written_hash`, it remains a `Conflict`; any edit by a
    human, the editor's per-field picker or an AI agent resolves it automatically.
- **Performance & Memory Invariants:**
  - Zero child processes; stable editor frames do not allocate (status/diff reuse workspace
    buffers).
  - Editor pushes touched paths via `kai.workspace_touched` (O(changed paths), no polling).
  - Snapshot cuts and hashes only changed files in parallel (`std/jobs` + BLAKE3 + FastCDC) and
    flushes once per op batch into append-only `store` packs.
  - Tree diff/merge prunes equal folder hashes and unchanged subtrees; switch writes only differing
    files from mapped packs.

---

## 6. Identity, Pairing, Capabilities and `mirai:net`

### 6.1 Keys and Pairing (Fixing ECO's Pairing Vulnerability)
- **Keys:** Offline Ed25519 Recovery key `R` (printed Base32 with checksum); per-device Ed25519
  `ds` + X25519 `dh` stored in an owner-only file; node keys (`ds`, `dh`); scope epoch keys `K`;
  org discovery secret `D`, derived from the org's genesis and its valid `Member_Remove`s, which
  only members and nodes read. No org private key, no email, no passwords.
- **Security audit finding in external ECO's pairing:** ECO derived its 8-digit verification code
  from the `Noise_XX` transcript hash after message 3, letting a MITM grind the 64-byte label in
  message 3 (~10^8 tries, feasible in seconds on multi-core/GPU) to force matching codes on both
  screens.
- **Kai commitment-hardened pairing (`Noise_XX_25519_ChaChaPoly_SHA256`):**
  ```text
  P1 I->R: ticket_id | e_I | commit            commit = BLAKE3("kai-1/pair-commit" || s_I || N_I)
  P2 R->I: ticket_id | e_R | enc(s_R) | enc(N_R || R_info)
  P3 I->R: ticket_id | enc(s_I) | enc(N_I || I_info)   (R verifies commit before showing code)
  code   = BLAKE3("kai-1/pair-code" || e_I || e_R || s_I || s_R || N_I || N_R) mod 10^8 -> dddd-dddd
  P4 R->I: sealed Pending|Approved|Denied (+ the ids of the user and orgs joined)
  ```
  The ticket also carries the addresses R listens at. The logs, envelopes and keyrings the new
  device, member or node needs come through the mesh once it connects to R.
  Every input to `code` is fixed before seeing the other side's nonce; mutable labels stay out of
  `code`. One request at a time, 5-minute timeout, No default, 5 denials pause 10 minutes.
  - Same flow links a user's second device (`Device_Add` + `Envelope_Add`), pairs a new org member
    (`Member_Add`), or pairs an ARM64 node (`Node_Add`).
- **Scoped Grants (non-members / CI / contractors):**
  `Grant{org_id, org_head, issuer, subject_dh, rights(read|write|ddc|check|relay), project_id,
  path_scope, not_after <= 30d, sig}` verified against `Org_Log` and `Grant_Revoke`. The issuer
  hands it over as text with its agent's X25519 key and addresses; the holder's agent reaches the
  issuer first and is admitted as `Grant`: it reads the user and org logs, and the refs of its
  project when it holds read, write or check.

### 6.2 `mirai:net` Contract Extensions
- Extend [net/secure.odin](../net/secure.odin) with Noise `IK` (`Noise_IK_25519_ChaChaPoly_SHA256`)
  for identity connections alongside existing `NKpsk0` (invitations and anonymous public reads).
  Evaluate migrating handshake state onto `.deps/odin/core/crypto/noise` only if verified
  zero-allocation per handshake; keep AEGIS-128L transport and rekeying, token-bucket rate limits,
  seen-filters and Retry cookies unchanged.
- `Host_Desc` adds `identity: Dh_Key` and `authorize(user, peer_dh, claim) ->
  Refuse|Pending|Accept(Member|Node|Grant|Anonymous)`. `Pending` lets peers with older `Org_Log`
  sync log entries before re-checking; membership revocation disconnects active peers with
  `Revoked`.
- `Address` adds `.Relay{node, peer_dh}` and global IPv6 discovery alongside IPv4.

---

## 7. Automatic P2P Mesh, Relay/Seed and DDC

- **One local agent per machine** (owned by the open editor or `mirai kai agent` exiting when idle)
  sharing one UDP socket over the machine `store`: one sync agent per org, routed by a hash of the
  org's id in front of each datagram. A lock file in the store keeps it to one runner per store;
  other processes of the user reach it over loopback with a token from an owner-only file.
- **Connection ladder (parallel race, seamless upgrade on better path):**
  `Encrypted LAN beacon -> global IPv6 -> portmap (existing PCP/NAT-PMP/UPnP) -> rendezvous UDP
  hole punch -> E2E encrypted relay -> seed`.
- **LAN Beacon (no mDNS):** IPv4 broadcast every 30 s, and at once when an org's `D` changes,
  with rotating keyed tags `org_tag = BLAKE3(D || "org" || bucket)[:12]` and `dev_tag`
  (`bucket = unix/600`). Unlinkable noise to non-members; `D` rotates on member removal. The
  device that does not dial (the higher `dh`) answers a beacon with its own.
- **Stateless Rendezvous & Relay (`relay` mode):** Holds org logs only; observes reflexive IP:port
  on 2 ports to detect hard/symmetric NATs (skipping futile punching); coordinates simultaneous UDP
  hole punching (lower `dh` initiates), and plans for a device asked about once it greets the node;
  otherwise relays opaque E2E-encrypted `net` datagrams with per-device byte quotas (and TCP 443
  length-prefixed fallback when UDP is blocked, no TLS/HTTP). Device and node authenticate their
  rendezvous messages with a key from `X25519(dh, dh)`.
- **Immediate propagation (no polling):** `exchange` gains `Ref_Changed{namespace, name, address}`
  hint; on connect peers query `names_ask`/`ref_ask`, then react to hints.
- **Signed DDC:** `DDC_Record{key, output_root, producer, tainted_scopes[], sig}` under
  `kai-ddc-<org hex>/<key hex>`. Accepted only from writers or `ddc`-grant holders; differing
  outputs for the same key are both kept and flagged as nondeterminism; lookups batch LAN peers
  before seed.

---

## 8. Public Repos with Private Files (Encrypted Overlays)

- **Zero metadata leak to public readers:** `Scope_Add` patterns (e.g. `.env`, `secrets/**`,
  `assets/licensed/**`) live only in the private `Org_Log`. Matching paths are routed at snapshot
  time into a separate encrypted overlay (`kai-ovl-<project>-<scope>/<commit hex>`); plaintext
  never touches `store.put`, and public `Change` objects never reference overlays.
- **Keyring epochs (`Keyring_Log`):** Each scope epoch holds a random 32-byte key `K` wrapped per
  authorized device (`X25519(e, dh)` -> `HKDF` -> `AEGIS-256`, ~80 B/device) plus optional
  `wrap_prev` for history. A write after any member/device removal is refused until a reader
  rotates to a new epoch (lazy rotation).
- **Chunk sealing (no convergent encryption):** Each private file gets a random `file_id[16]` kept
  across edits. `(k_enc, k_nonce) = HKDF(K_epoch, "kai-1/file" || file_id)`. Each FastCDC chunk is
  compressed with MDC2, padded with Padme (~1.5% avg overhead), and sealed with `AEGIS-256` using
  keyed nonce `BLAKE3(k_nonce || q)` — deduplicates edits within the same file/epoch while
  preventing confirmation attacks. Rebasing re-signs `Overlay_Record` without re-encrypting chunks.
- **Zero-knowledge seeds:** Seeds store and serve overlay ciphertext and keyrings without holding
  any scope key.
- **`exchange` anonymous chunk filter (critical audit fix):** Today `exchange/serve.odin` `on_ask`
  serves any chunk address in the machine store. `exchange.Desc` adds `serve(user, peer, address)
  -> bool` checked for `Anonymous` peers against a per-project `Public_Closure` (sorted addresses
  reachable from `public` bookmarks).
- **Leak guardrails:** Built-in deny set (`.env*`, `*.pem`, `*.key`, `id_*`, `*.p12`) refused at
  snapshot unless scoped or kept public by an admin's `Public_Add` (`mirai kai public add <path>`);
  WIP refs never exposed anonymously; publish-to-public diff scanner blocks keys/PEM/high-entropy
  assignments unless an admin's `Public_Add` waives that leak (`mirai kai public add
  <path>:<line>`); DDC outputs inherit input scopes. A device that may no longer read a scope
  loses its files from its working copy on the next move and keeps its last copy out of its
  snapshots.

---

## 9. Live Collaboration and AI Agents

- **Clean separation:** `editor/history` stays the bounded, real-time, per-author in-memory journal
  (12–60 Hz); `kai` is the persistent file-level VCS. Only the collab host writes files and
  snapshots changes (one writer); guests keep a read-only workspace on the host's change.
- **Co-authorship via queue:** `Kai_Authorship :: @(storage, queue)` receives `{key, turn}` from
  both local history commits and host collab apply (Hello adds the editor's identity `Key`). The
  snapshot owner drains it into `Change.coauthors` and `Change.turns`.
- **No `COLLAB_FILE_BYTES`:** Collab `File` messages send `{path, address, size, present}` and
  peers fetch chunks over the session's existing `exchange` node. `File_Unsent` and Git-dirty file
  listing on join are deleted.
- **AI agents:** Short in-editor turns stay in `editor/history` and attach `Turn_Ref` to snapshots.
  Long/parallel agent tasks get their own sibling `Workspace` and land via `Proposal` + signed
  `Check` events.

---

## 10. `mirai kai serve`: ARM64 Linux Server and Web Repo View

### Deployment: ARM64 Linux VM (not Kubernetes/Docker bridge)
- **Primary target:** Single static headless `linux_arm64` Odin binary (`mirai kai serve`, no SDL,
  GPU, editor, Postgres, Redis or Node) running directly under `systemd` on a small ARM64 Linux VM
  (e.g. Hetzner CAX / Graviton / Raspberry Pi) confined with Linux Landlock + seccomp.
- **Why VM over container bridge:** Rendezvous needs a stable public IP:port and real UDP source
  addresses (Docker bridge NAT breaks hole punching); `store` uses mmap, `fsync` and PID leases
  requiring local ext4/xfs (not overlayfs/NFS); ARM64 provides native AES/PMULL for AEGIS and NEON
  for BLAKE3.
- **Optional OCI packaging:** Supported only as `FROM scratch` + binary + `--network host` +
  bind-mounted local volume (no base distro, no orchestrator).
- **Modes:** `--mode relay` (logs + hole punch/relay only), `--mode seed` (+ full project closures,
  anonymous public read, web view), `--mode seed+ddc` (+ LRU-swept DDC cache with `--ddc-quota`).
  Orgs served come strictly from signed `Node_Add` entries.

### Web Repo and Review View (`KaiHub`, Replaces GitHub PRs)
- **Peer vs browser transport:** All peer-to-peer traffic (editor, CLI, seed, relay, DDC) runs
  exclusively over `mirai:net` UDP (Noise `IK` + AEGIS-128L, zero TCP/TLS handshake overhead).
  HTTPS is used **only** for web browsers hitting KaiHub.
- **Transport for browsers:** HTTP over TLS 1.3 (1-RTT, early data refused; HTTP/3 over QUIC
  optional via a thin edge proxy like Caddy) serving a static **Vue** frontend plus a clean
  JSON/binary API straight from `mirai kai serve` (no Postgres, Redis or Node backend).
- **Views:**
  - Public: project overview, public bookmarks, README, file tree/viewer (including Mirai asset
    inspection summary + DDC preview thumbnails), change list, change diff (`std/diff`) and
    **change evolution** (interdiffs across rewrites of a `Change_Id`).
  - Members: stacks (`<handle>/<device>:<bookmark>`), Proposals & Reviews, org members/roles, DDC
    hit/miss/nondeterminism dashboard, node peer/relay/store stats. Private overlays remain
    zero-knowledge on the server.
- **Zero-CLI browser auth (passkey-first, server never signs for users):**
  - Users open KaiHub directly in the browser and sign in with a **WebAuthn passkey** (Touch ID,
    Face ID, Windows Hello, hardware key, or phone QR via hybrid transport) — no terminal command,
    no `kai web login`, no email and no password.
  - Fallback for any PC without passkeys or a phone handy (e.g. bare Linux desktop): an **Approve
    in Mirai** button (`kai://...` deep link to the local editor/agent holding the device Ed25519
    key) that prompts one click to approve, still with zero terminal commands.
  - First-time web users create a passkey directly in the browser (creating or linking a
    `User_Log` via `Web_Key_Add`); linking an editor/CLI device uses QR or the commitment-hardened
    8-digit code.
  - Read sessions are authenticated by a signed WebAuthn challenge (`__Host-` HttpOnly cookie);
    writes (comments, approvals, verdicts, org actions) are WebAuthn signatures over the BLAKE3
    of the entry's signed bytes (head, parents and body, so a relay cannot change its author,
    log or kind), verified offline by every peer.
  - Optional client-side viewing of private overlays (`.env`) in the browser uses the WebAuthn
    **PRF** extension when supported to derive a local decryption key inside the browser while
    keeping the server 100% zero-knowledge.

---

## 11. Contract-First Milestones and Verification

- **M0 — Contracts:** `std/diff` (Histogram + merge3); `net` IK + `authorize` + `.Relay` + IPv6;
  `exchange` peer-aware `Expose`, `serve` filter (`Public_Closure`) and `Ref_Changed` hint.
  - Focal tests: `histogram_diff_and_merge3_cases`, `net_ik_authorize_and_revoke`,
    `anonymous_peer_cannot_fetch_unexposed_chunks`, `ref_changed_hint_wakes_peer`.
- **M1 — Local Kai:** `kai` records, moved tree format, conflict algebra, op log + undo, workspace
  stat index + optional reflink, graph index, `Driver` interface, `cook/kai` Mirai asset driver.
  - Focal tests: `a_snapshot_rehashes_only_changed_files`, `hostile_kai_records_are_refused`,
    `conflicts_simplify_and_resolve_by_edit`, `every_operation_undoes`,
    `op_heads_of_two_workspaces_merge`, `a_scene_merges_by_field_through_the_driver`,
    `a_switch_cut_midway_recovers_on_status`, `kai_imports_stay_engine_agnostic`.
- **M2 — Editor, Collab and Git Deletion:** replace `editor/git*` with Kai panel and `kai.*` API;
  `Kai_Authorship` queue; collab files by address (delete `COLLAB_FILE_BYTES`); `cook/share` join
  on `kai.merge`; delete all Git project support (the Git setup of `cook/build`, `git.*`,
  `.gitattributes`, LFS).
  - Focal tests: `editor_kai_snapshot_diff_conflict_and_undo`,
    `a_large_file_travels_in_a_session_by_address`,
    `collab_coauthorship_and_agent_turns_record_in_change`.
- **M3 — Identity, Orgs and P2P Mesh:** unified `Entry` DAG + fold + revocation horizon;
  commitment-hardened `Noise_XX` pairing; signed `Device_Refs` and `Grant`; local agent, rotating
  LAN beacon, rendezvous/hole-punch/relay, seed, signed DDC.
  - Focal tests: `pairing_rejects_mitm_label_grinding`,
    `revocation_horizon_rejects_backdated_entries`,
    `concurrent_admin_removals_fold_deterministically`,
    `org_members_sync_refs_and_ddc_over_sim_network`, `device_refs_reject_rollback`.
- **M4 — Private Overlays:** `Scope_Add` routing, `Keyring_Log` epochs and lazy rotation,
  AEGIS-256 + Padme chunk sealing, zero-knowledge seed, leak guardrails and publish scanner.
  - Focal tests: `scoped_plaintext_never_enters_public_store`,
    `removed_member_cannot_decrypt_post_rotation_epoch`,
    `public_peer_sees_zero_overlay_metadata_or_chunks`,
    `deny_set_and_publish_scanner_block_leaks`.
- **M5 — Proposals, ARM64 Server and KaiHub Web View:** `Proposal_Log` with structural/line
  re-anchoring and signed `Check` events; headless `linux_arm64` `mirai kai serve` (TLS 1.3 +
  ACME + Landlock/seccomp, JSON API + static Vue frontend); passkey-first WebAuthn login/signing
  (+ optional WebAuthn PRF client-side overlay decryption); `mirai-kai` skill and `ARCHITECTURE.md`
  update.
  - Focal tests: `proposal_comments_reanchor_across_rewrites`,
    `landing_enforces_policy_and_zero_conflicts`,
    `webauthn_login_and_signed_verdict_verify_offline`,
    `headless_arm64_server_builds_and_serves_public_and_member_views`.

- **M6 — Running Mesh and Product Surface:** M3 to M5 give the logs, pairing, mesh, relay and
  proposals as state logic proved over a simulated network; M6 runs them. The agent over real
  UDP (`net` host with identity, LAN beacon, portmap, rendezvous and relay), the identity and
  logs of a machine persisted in its `store`, `mirai kai agent`, and the `mirai kai` commands and
  editor Kai panel for identity, pairing, orgs, grants, scopes, sync, DDC through `cook/cache` and
  proposals.
  - Focal tests: `two_agents_pair_and_sync_a_change_over_loopback_udp`,
    `a_relay_node_joins_two_agents_that_cannot_reach_each_other`,
    `runner_refuses_hostile_datagrams`, `a_cook_takes_derived_data_a_peer_built`,
    `editor_kai_pairs_and_lands_a_proposal`.

---

## 12. Open Decisions (with Defaults)

1. **`mirai share` / `mirai join` for one-off sharing outside an org:** Keep them (reusing `kai`
   trees and merge) for ad-hoc sharing without creating an org. *Default: keep.*
2. **Op log retention before sweep:** Retain 30 days of ops before `store` sweep may reclaim old
   revisions, with an explicit prune op. *Default: 30 days.*
3. **`core:crypto/noise` vs `net/secure.odin` handshakes:** Use Odin's `core:crypto/noise` only if
   benchmark/allocation checks confirm zero allocations per handshake; otherwise extend
   `net/secure.odin` directly. *Default: check first in M0.*
4. **Browser HTTPS / HTTP3 edge for `mirai kai serve`:** Built-in TLS 1.3 in Odin (`net/tls`, over
   `core:crypto`: no C library to cross-compile) inside `mirai kai serve` for single-binary
   deploys, with certificates by ACME TLS-ALPN-01 on the same port; optional HTTP/3 (QUIC) via a
   thin Caddy front when HTTP/3 is desired. *Decided: built-in TLS 1.3, HTTP/3 optional.*
5. **Pre-implementation checks:** Verify the static `linux_arm64` link of `mirai kai serve` and
   WebAuthn PRF browser support for optional client-side `.env` viewing in KaiHub.
