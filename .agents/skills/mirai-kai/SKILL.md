---
name: mirai-kai
description: Kai, the native version control and peer-to-peer distribution of Mirai - `std/diff`
  (line diff and three-way merge), `kai` (changes, trees, conflicts as values, the operation log and
  undo, workspaces, drivers), the org as one signed record (members, roles, repositories), shared
  bookmarks, one-time invites, the sync agent over TCP with its post-quantum Noise handshake, LAN
  beacon and router port mapping, derived data shared between machines, `kai/hub` (the server
  `mirai kai serve` with per-org stores and its web view without script), `cook/kai` (the Mirai
  asset driver, publish and pull), the `mirai kai` commands and the `kai.*` methods. Use when
  versioning or sharing a project, merging or resolving a conflict, undoing, making an org,
  inviting or joining a machine, publishing to main or pulling a repository, running or deploying a
  Kai server or its web view, or diagnosing why a change, a peer, a record or a pull is refused or
  slow.
---

# Mirai Kai

Kai is the version control of a Mirai project and how its team reaches each other: changes and
operations in the machine's [store](../mirai-store/SKILL.md), an org as one record its admins
sign, and an agent on each machine that pulls what the org's other machines hold over TCP.
There is no account and no Git; a server (`mirai kai serve`) is an optional machine of the org
that is always on. Kai itself is optional per project: a project without `.mirai/kai` has no
history until it is [enabled](#start-a-project-on-kai). It is used from the Kai tab and the
org repositories of the launcher's All projects in the
[editor](../mirai-editor/references/kai.md), from `mirai kai`, from the `kai.*` methods and, to
read a server's repositories, from a browser.

- `std/diff` (layer 0): line diff and three-way merge; imports nothing of Mirai.
- `kai` (layer 4): records, trees, conflicts, operations, workspaces, the org record, shared
  bookmarks, invites, the handshake, the wire and the agent, and derived data. It imports
  `std/*`, `store`, `net` (port mapping alone) and `core:` alone.
- `kai/hub` (layer 5): the server `mirai kai serve`, its web accounts and its HTTP pages. It
  imports `kai`, `store`, `std/*` and `core:`. `tools/kai` is `mirai-kai`, which imports `kai/hub`
  alone so that it links statically for a Linux server.
- `cook/kai` (layer 7): what Kai knows of Mirai, the asset driver and the project filter, and the
  operations that need a workspace (publish, pull, derived data of imports and cooks). `editor`
  and `tools/mirai` call it and `kai` alike.

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
- The device key, the profile, the org record, its versions, roles and who may sign:
  [machine](references/org.md#the-machine), [org record](references/org.md#the-org-record) and
  [roles](references/org.md#roles).
- Shared bookmarks (`Repo_Refs`) and publishing to main:
  [shared bookmarks](references/org.md#shared-bookmarks).
- Inviting and joining a machine: [invites](references/org.md#invites).
- The handshake, the frames, the agent, who reads what, the beacon and the router:
  [handshake](references/sync.md#the-handshake), [wire](references/sync.md#the-wire),
  [agent](references/sync.md#the-agent), [access](references/sync.md#who-reads-what) and
  [reach](references/sync.md#how-machines-reach-each-other); how fast a pull goes:
  [pulls](references/sync.md#pulls).
- Derived data a cook takes from a peer: [derived data](references/sync.md#derived-data).
- What uploads or downloads now, by peer, with its speed: [transfers](references/sync.md#transfers).
- The server `mirai kai serve`, its stores, its web view and accounts, and its deployment:
  [server](references/server.md#the-server), [web view](references/server.md#the-web-view),
  [accounts](references/server.md#web-accounts) and
  [deployment](references/server.md#deployment).
- The Kai tab and the editor's part: [editor](../mirai-editor/references/kai.md#working-copy);
  the commands:
  [common commands](../mirai-projects/references/projects.md#common-commands); merging assets:
  [merge](../mirai-assets/references/cli.md#merge); port mapping:
  [port mapping](../mirai-networking/references/port-mapping.md#api-and-lifecycle).

## Workflow

### Start a project on Kai

1. `mirai new` makes the project a workspace of a repository in the machine's store, unless
   `--no-kai` (the editor's New Project dialog: "Version control (Kai)"). A project that has none
   takes `mirai kai init`, or in the editor the tab's Enable Kai or `kai.init`. The editor opens
   a project with `.mirai/kai` as its workspace and never makes one by itself.
2. Work in the files. `mirai kai status` snapshots and lists what changed; `new`, `describe`,
   `split`, `undo` and `conflicts` act on the working change `@`.
3. To share it: `mirai kai profile <name> <device>` names the person and the machine, `mirai kai
   org new <name>` makes an org with this machine its admin, and `mirai kai org add public|org
   --project P` puts the project in it. `mirai kai publish` moves main for the whole org. The
   editor's Publish to main (`kai.publish` with `org` and `visibility`) does both in one call.

### Bring in another machine

1. A machine of the org runs its agent (the open editor, or `mirai kai agent`).
2. `mirai kai invite <org> [--role reader|writer|admin|node] [--mine] [--at host:port]` prints one
   `kai2...` text; `--mine` makes it a second machine of the same person, `--at` names the
   host:port a router forwards when the other machine is on another network (the editor and
   `mirai kai agent` ask the router themselves).
3. The other machine runs `mirai kai join <invite>` (the editor: Team, Join), then `mirai kai pull
   <org> <repository> <folder>` (the launcher's All projects: Pull) to get main's files.

### Run a server

1. `mirai build kai --target linux_arm64`, copy `bin/mirai-kai-linux-arm64` to the machine and
   follow [deployment](references/server.md#deployment).
2. Org admins attach from the editor automatically on new orgs (or with Sync to server, bounded by
   `--max-orgs`, default 64); manual `--join` also works (`mirai kai invite <org> --role node`,
   then `mirai-kai serve --join <invite> --public <host:port>`). It keeps every repository of the
   org whole, redeems offline 1-use invites and mirrors derived data.
3. Each member that wants the web view sets its sign-in from its device: `mirai kai web-login
   <server host:port> <name>` (the password from `KAI_PASSWORD` or the terminal).

### Change Kai

1. A new kind of record changes the stored layout: raise the kind's line in `VERSIONS`
   (`kai/types.odin`), the one place an object of another version is refused, add its bounds, its
   case in `kai/reach.odin` if it names other objects, and its hostile-input test; there is no
   migration.
2. A new message of the wire is a `Msg` of `kai/wire.odin`, bounded by `FRAME_MAX`, read by the
   agent's reader, refused with the connection when it does not parse.
3. An operation the CLI and the editor both need goes into `kai` (no workspace) or `cook/kai`
   (workspace), never into `editor` or `tools/mirai`; it reports through `t.why` what failed and
   how to fix it.
4. Update the reference that owns the topic in the same task.

## Invariants

- `kai` imports nothing of the engine (`core`, `asset`, `project`, `host`, `engine/*`, `cook/*`,
  `editor`): Mirai enters as a `Driver` and a `Filter` from `cook/kai`.
- A record is one object of the store with its kind and version in its meta; hostile bytes are
  `Corrupt`, another version is refused without migration. A signature is checked when a record
  comes from a peer, never on a local read.
- One operation is one store commit and one undo; each workspace writes only its own ref in the
  `kai-local-*` namespaces, and the machine's own state lives under `kai-machine`; no peer is
  served either.
- A conflict is a value in a tree, never a state that blocks work; a checkout writes its partial
  result and the next edit of the file resolves it.
- The editor, `mirai kai` and the `kai.*` methods run the same procedures; a refusal says what
  failed and how to fix it.
- An org is one signed record. A peer takes a newer one only when every version back to one it
  holds follows the one before (signed by an admin of it, or a writer when only repositories
  changed); two versions signed apart settle alike everywhere, higher version then lower address.
- Every connection is TCP under Noise NNhfs with X25519 and ML-KEM-768, and each end proves its
  Ed25519 device key by signing the handshake hash: a recording stays closed unless both
  exchanges break, and a man in the middle holds no signature over its own hash.
- An invite is one device, one time, within `INVITE_HOURS`; its secret never travels, only an
  HMAC of the handshake hash under it.
- A peer reads only the heads and chunks of the orgs it is a member of; a server keeps each org in
  its own store, so no org reads another's objects.
- A pull is done only when every chunk of every object is here (`object_whole`), never when a root
  alone is.
- What peers, routers and browsers send is bounded and refused with a reason, never trusted.
- The server is trusted as a Git host is: it holds the org's repositories in the clear and decides
  what its web view shows, by the role of the device that set each sign-in.
- Kai is the only version control of a project that has it: its snapshots track what
  `project.own_path` accepts (never `.mirai` nor a `.git`, `.hg`, `.svn` or `.jj` at any depth)
  minus the checkouts `plugins/<name>` of the plugins from git its manifest names (`sources`,
  `cook/kai` `tracked_path`), and nothing else decides which files are the project's. A project
  without it records nothing.

## Verification

- `mirai check` of each touched package (`std/diff`, `kai`, `kai/hub`, `cook/kai`, `tools/kai`)
  and `mirai test <package> --no-gpu` of it. A change of `tools/mirai/kai*.odin` or of the server
  also needs `mirai build kai --target linux_arm64` once.
- Model: `a_snapshot_rehashes_only_changed_files`, `hostile_kai_records_are_refused`,
  `conflicts_simplify_and_resolve_by_edit`, `every_operation_undoes`,
  `a_prune_drops_old_operations_and_the_sweep_reclaims_what_only_they_reached`,
  `op_heads_of_two_workspaces_merge`, `a_switch_cut_midway_recovers_on_status`,
  `a_change_splits_by_paths_and_undoes_in_one_operation`, `kai_imports_stay_engine_agnostic`,
  `a_checkout_writes_nothing_outside_its_root_or_into_kai` and
  `an_unreadable_device_secret_is_kept` in `kai`; `histogram_diff_and_merge3_cases` and
  `diff_and_merge3_survive_hostile_inputs` in `std/diff`;
  `a_scene_merges_by_field_through_the_driver` and `a_merge_that_breaks_its_kind_conflicts_as_ours`
  in `cook/kai`.
- Org and sync: `noise_pq_handshake_proves_both_keys_and_refuses_tampering`,
  `org_records_hold_only_when_signed_by_who_may`,
  `offline_invite_records_enforce_signatures`,
  `a_closure_is_whole_only_when_every_chunk_is_here`,
  `two_machines_pair_by_invite_and_sync_over_tcp`,
  `a_joined_peer_reconnects_after_the_inviter_restarts` and
  `a_pull_over_loopback_runs_at_tcp_speed`
  (prints seconds and MB/s; `KAI_BENCH_MB` sets the megabytes, 16 by default) in `kai`;
  `a_project_publishes_to_main_and_a_paired_machine_pulls_it` in `cook/kai`;
  `a_cook_takes_derived_data_a_peer_built` in `cook/import/sources`;
  `port_mapping_pcp_and_natpmp_codecs_reject_mismatched_or_truncated_replies` in `net` for TCP
  mappings.
- Server: `a_server_keeps_an_org_and_its_web_view_shows_what_each_one_may_see`,
  `a_server_registers_an_org_and_admits_offline_invites`,
  `forged_or_replayed_offline_admissions_are_refused`,
  `the_web_view_answers_100_continue_and_stops_with_idle_clients` and
  `hub_http_refuses_hostile_requests` in `kai/hub`.
- Editor: [its focal tests](../mirai-editor/references/kai.md#verification).
- Documentation: `uv run scripts/check_docs.py`.
