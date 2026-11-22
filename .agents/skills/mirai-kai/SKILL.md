---
name: mirai-kai
description: Kai, the native version control and peer-to-peer distribution of Mirai - `std/diff`
  (line diff and three-way merge), `kai` (changes, trees, conflicts as values, the operation log and
  undo, workspaces, drivers), identity, orgs, pairing, grants and the signed logs, the mesh (LAN
  beacon, hole punching, relay, seed and derived-data nodes, derived data shared between machines),
  private files in encrypted overlays, proposals and review with policies and checks, `kai/hub`
  (the node `mirai kai serve`, its web view and passkey sign-in), `net/tls` (TLS 1.3 and ACME),
  `cook/kai` (the Mirai asset driver), the `mirai kai` commands and the `kai.*` methods. Use when
  versioning or sharing a project, merging or resolving a conflict, undoing, pairing a machine,
  creating an org, a grant, a private scope, a proposal or a check, running or deploying a node or
  its web view, serving HTTPS, or diagnosing why a change, a peer or a signature is refused.
---

# Mirai Kai

Kai is the version control of every Mirai project and how its teams reach each other: changes
and operations in the machine's [store](../mirai-store/SKILL.md), identities and orgs as signed
logs, and a mesh of the machines of an org that finds its peers, syncs by
[exchange](../mirai-store/references/exchange.md#what-the-owner-calls) and reviews work through
proposals.
There is no account, no central server and no Git: a node is an optional machine of the org that
is always on. It is used from the Kai tab of the [editor](../mirai-editor/references/kai.md), from
`mirai kai`, from the `kai.*` methods and, for review, from a browser.

- `std/diff` (layer 0): line diff and three-way merge; imports nothing of Mirai.
- `kai` (layer 4): records, trees, conflicts, operations, workspaces, the logs, pairing, the mesh,
  overlays and proposals. It imports `std/*`, `store`, `exchange`, `net` and `core:` alone.
- `kai/hub` (layer 5): the node's commands, HTTPS server, JSON API and web frontend. It imports
  `kai`, `net`, `net/tls`, `store` and `std/*`. `tools/kai` is `mirai-kai`, which imports
  `kai/hub` alone.
- `net/tls` (layer 2): TLS 1.3 and an ACME client, without I/O.
- `cook/kai` (layer 7): what Kai knows of Mirai, the asset driver and the project filter, and the
  operations that need a workspace. `editor` and `tools/mirai` call it and `kai` alike.

## Map

- Changes, trees, how records are stored and checked:
  [records](references/model.md#records) and [trees](references/model.md#trees).
- Conflicts, merging, the drivers and `std/diff`:
  [conflicts](references/model.md#conflicts) and
  [drivers](references/model.md#drivers-and-diff).
- Operations, undo, split, bookmarks, the graph, retention and `mirai kai prune`:
  [operations](references/model.md#operations-and-undo).
- Working copy, snapshots, checkout and what the editor pushes:
  [workspaces](references/model.md#workspaces); who calls what:
  [surfaces](references/model.md#surfaces).
- Users, devices, the recovery key, orgs, roles and rights:
  [keys](references/identity.md#keys), [the logs](references/identity.md#the-signed-logs),
  [folding](references/identity.md#folding-and-revocation) and
  [roles](references/identity.md#roles-and-rights).
- Pairing a device, a member or a node: [pairing](references/identity.md#pairing).
- Access for someone outside the org: [grants](references/identity.md#grants); what a device
  publishes: [device refs](references/identity.md#device-refs).
- The runner, who reads what, how peers find each other, relay, beacon and nodes:
  [runner](references/mesh.md#the-runner), [access](references/mesh.md#who-reads-what),
  [ladder](references/mesh.md#the-connection-ladder) and [nodes](references/mesh.md#nodes).
- Derived data a cook takes from a peer: [derived data](references/mesh.md#derived-data); the
  summaries, thumbnails and asset diffs of the web view: [previews](references/node.md#previews).
- Private files, scopes, keys, deny set and the publish scanner:
  [scopes](references/private.md#scopes-and-routing),
  [keys](references/private.md#keyrings-and-epochs), [sealing](references/private.md#sealing) and
  [guardrails](references/private.md#leak-guardrails).
- Proposals, comments, approvals, policies, checks and landing:
  [proposals](references/proposals.md#proposals) and
  [landing](references/proposals.md#policy-and-landing).
- The node `mirai kai serve`, its deployment and its web view:
  [node](references/node.md#the-node), [deployment](references/node.md#deployment),
  [API](references/node.md#the-api), [sign in](references/node.md#sign-in-and-writes) and
  [frontend](references/node.md#the-frontend).
- TLS 1.3, certificates and ACME: [TLS](references/tls.md#tls-13) and
  [ACME](references/tls.md#acme).
- The Kai tab and the editor's part: [editor](../mirai-editor/references/kai.md#working-copy);
  the commands:
  [common commands](../mirai-projects/references/projects.md#common-commands); merging assets:
  [merge](../mirai-assets/references/cli.md#merge); the ports and transports:
  [networking](../mirai-networking/SKILL.md).

## Workflow

### Start a project on Kai

1. `mirai new` makes the project a workspace of a repository in the machine's store; a folder that
   exists takes `mirai kai init`. The editor opens the project as a workspace or makes one.
2. Work in the files. `mirai kai status` snapshots and lists what changed; `new`, `describe`,
   `split`, `undo` and `conflicts` act on the working change `@`.
3. To share it: `mirai kai identity` makes this machine's user (the recovery key is shown once,
   keep it offline), `mirai kai org new <name> --project P` makes an org, `mirai kai org add
   public|org` puts the project in it.

### Pair a machine

1. A machine of the org runs a Kai agent (the open editor, or `mirai kai agent`).
2. `mirai kai pair offer device|member|node` prints a ticket; the other machine runs `mirai kai
   pair join <ticket>`. Both show the same eight digits: the person on the offering machine
   compares them and runs `mirai kai pair approve --code <digits>`, or `--deny`.
3. A node is paired the same way from its own machine (`mirai-kai pair join`).

### Review and land

1. Publish a stack: `mirai kai proposal open <target> -m title` on the working change's parent.
2. Reviewers `comment`, `approve` or `changes`; a check runs `mirai kai check <name> -- <command>`
   in a working copy of the final revision and signs what it found.
3. `mirai kai proposal land <proposal>` moves the target when its policy holds. A guarded
   bookmark moves by no other way (`mirai kai bookmarks policy <name> --approvals N --checks a,b`).

### Add a private scope

1. An admin runs `mirai kai scope add <pattern...> --readers writer [--history]` for the project.
2. The next snapshot of every reader routes the matching files into an encrypted overlay. A device
   that cannot read the scope keeps its last copy out of its snapshots and loses the files.
3. After a member or a device leaves, the next write waits for `mirai kai scope rotate <scope>`.

### Run a node

1. `mirai build kai --target linux_arm64`, copy `bin/mirai-kai-linux-arm64` to the machine and
   follow [deployment](references/node.md#deployment).
2. Pair it as a node (`pair offer node --org O --modes relay,seed,ddc`, then `pair join` there).
3. `mirai kai web approve <link>` signs a browser in or links a passkey from a device.

### Add a check

A check is a name a policy requires and a command a peer runs: `mirai kai bookmarks policy main
--checks test` requires `test`; any writer or holder of a `check` grant runs `mirai kai check
test -- mirai test <package>` against the proposal's final revision. Nothing runs on a node.

### Change Kai

1. A new kind of record or log entry changes the stored layout: bump `VERSION`, add its bounds to
   `kai/types.odin` and its hostile-input test; there is no migration.
2. An operation the CLI and the editor both need goes into `kai` (no workspace) or `cook/kai`
   (workspace), never into `editor` or `tools/mirai`; it reports through `m.why` what failed and
   how to fix it.
3. A route of the node goes into the table of `kai/hub/api.odin`, which dispatches and describes.
4. Update the reference that owns the topic in the same task.

## Invariants

- `kai` imports nothing of the engine (`core`, `asset`, `project`, `host`, `engine/*`, `cook/*`,
  `editor`): Mirai enters as a `Driver` and a `Filter` from `cook/kai`.
- A record is one object of the store with its kind and version in its meta; hostile bytes are
  `Corrupt`, another version is refused without migration. A signature is checked when a record
  comes from a peer and by `verify`, never on a local read.
- One operation is one store commit and one undo; each workspace writes only its own ref in the
  `kai-local-*` namespaces, which no peer is served.
- A conflict is a value in a tree, never a state that blocks work; a checkout writes its partial
  result and the next edit of the file resolves it.
- The editor, `mirai kai` and the `kai.*` methods run the same procedures; a refusal says what
  failed and how to fix it.
- Nothing is decided by a server. Membership, roles, policies and landings are folds of signed
  logs that every peer computes alike; a node holds no org key and signs for no user.
- The browser signs only what it computed: the server drafts the bytes of an entry and gives no
  challenge for a write, the page checks every field and signs the BLAKE3 of the bytes itself.
- A recovery key is shown once and never crosses an API or a result; a method of an editor with no
  window refuses to make or rotate one.
- A run of the editor that ends by itself (a check of a build, a capture) and a guest of a session
  open no workspace: only an editor someone drives records history.
- The plaintext of a scoped file never enters the public store, a public change never names an
  overlay, and a node or seed never holds a scope key.
- A peer reads a set of addresses and nothing else of the store: what its org reaches as a member
  or a node, the user logs while pending, what the shared bookmarks of public projects reach while
  anonymous (never a device's refs or a proposal), what its grant covers.
- Nothing polls: a ref that moved is told to the peers that may read it.
- A stable frame or tick allocates nothing; what peers, browsers and sockets send is bounded and
  refused with a reason, never trusted.
- A node on Linux runs confined, or refuses to start unless it is told `--no-sandbox`.
- Kai is the only version control of a project: its snapshots track what `project.own_path`
  accepts and nothing else decides which files are the project's.

## Verification

- `mirai check` of each touched package (`std/diff`, `kai`, `kai/hub`, `net/tls`, `cook/kai`,
  `tools/kai`) and `mirai test <package>` of it. A change of `tools/mirai/kai*.odin` or of the
  node also needs `mirai build kai --target linux_arm64` once.
- Model: `a_snapshot_rehashes_only_changed_files`, `hostile_kai_records_are_refused`,
  `conflicts_simplify_and_resolve_by_edit`, `every_operation_undoes`,
  `a_prune_drops_old_operations_and_the_sweep_reclaims_what_only_they_reached`,
  `op_heads_of_two_workspaces_merge`, `a_switch_cut_midway_recovers_on_status`,
  `a_change_splits_by_paths_and_undoes_in_one_operation` and `kai_imports_stay_engine_agnostic`
  in `kai`; `histogram_diff_and_merge3_cases` in `std/diff`;
  `a_scene_merges_by_field_through_the_driver` and
  `a_driver_result_is_kept_by_its_terms_and_version` in `cook/kai`.
- Identity: `revocation_horizon_rejects_backdated_entries`,
  `concurrent_admin_removals_fold_deterministically`, `pairing_rejects_mitm_label_grinding`,
  `grants_verify_against_the_org` and `device_refs_reject_rollback` in `kai`.
- Mesh: `org_members_sync_refs_and_ddc_over_sim_network`,
  `a_member_gets_only_what_its_org_reaches`, `anonymous_peer_gets_only_the_public_closure`,
  `a_grant_holder_reads_and_writes_only_its_scope_until_it_ends`,
  `two_agents_pair_and_sync_a_change_over_loopback_udp`,
  `a_relay_node_joins_two_agents_that_cannot_reach_each_other`,
  `runner_refuses_hostile_datagrams` and `a_ddc_node_drops_least_used_outputs_past_its_quota` in
  `kai`; `a_cook_takes_derived_data_a_peer_built` and
  `asset_summaries_are_stable_and_follow_their_bytes` in `cook/kai`.
- Private files: `scoped_plaintext_never_enters_public_store`,
  `removed_member_cannot_decrypt_post_rotation_epoch`,
  `public_peer_sees_zero_overlay_metadata_or_chunks` and `deny_set_and_publish_scanner_block_leaks`.
- Proposals: `proposal_comments_reanchor_across_rewrites`,
  `landing_enforces_policy_and_zero_conflicts` and
  `a_team_reviews_and_lands_a_proposal_through_the_shared_operations` (`cook/kai`).
- Node: `hub_serves_public_and_member_views`, `hub_api_describes_every_route`,
  `hub_http_refuses_hostile_requests`, `webauthn_login_and_signed_verdict_verify_offline`,
  `hub_web_modules_agree_with_the_node` (runs under the system's `node`, skipped without it),
  `hub_seccomp_program_refuses_what_the_node_does_not_do` and
  `headless_arm64_server_builds_and_serves_public_and_member_views` (builds the static
  executable and runs it where a linux/arm64 runtime exists).
- TLS: `tls13_known_answer_vectors`, `tls13_refuses_hostile_and_downgraded_input`,
  `tls13_interoperates_with_system_tools`,
  `acme_orders_a_certificate_by_tls_alpn_from_a_fake_directory` and
  `hub_serves_while_an_acme_order_dials` (skipped where no route makes a connect wait).
- Editor: [its focal tests](../mirai-editor/references/kai.md#verification).
- Documentation: `uv run scripts/check_docs.py`.
