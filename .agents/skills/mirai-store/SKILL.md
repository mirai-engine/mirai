---
name: mirai-store
description: Mirai machine-wide content-addressed store (the `store` package) - chunks in
  append-only packs, objects as trees of chunks read by group and offset, refs, commits and
  batches, index generations, the sweep that compacts packs beside running writers, the scrub,
  leases and the default root - and the `exchange` package that moves blobs and refs between peers
  over `net` (wants, priorities, several sources, lying peers, blocking fetch). Use when storing or
  sharing heavy content between projects or peers, building an asset library or a derived data
  cache on top of it, fetching a blob from another machine, or diagnosing a corrupt, missing,
  slow or growing store.
---

# Mirai store

`store` (layer 1) imports only `base`, `core` and `std`: a plain library a game binary may link.
It knows chunks, objects and refs and interprets none of them: the transport, the library and the
derived data cache that use it decide what a ref means and what is live.

## Map

- Root, layout, errors, file operations and their test hooks: `store/store.odin`; what differs per
  system (sharing and deleting on Windows, mapping, a full volume, whether a process runs):
  `store/system_*.odin`.
- Cutting bytes into chunks: `store/chunk.odin`; node records, building an object's tree into a
  sink and resolving a byte or a group offset to a leaf: `store/node.odin`.
- Packs, frames, the writer, commit and seal, scanning a pack: `store/pack.odin`.
- What a `Store` value knows (generation, table of chunks, folded refs) and reading the root again:
  `store/index.odin`.
- Putting and reading objects and chunks: `store/object.odin`; refs: `store/refs.odin`.
- Sweep, compaction, generations, scrub and the sweep's claims: `store/sweep.odin`; leases:
  `store/leases.odin`. The sweep a long-running owner calls, with what is live on the machine:
  `asset.store_sweep` (`asset/collect.odin`).
- Blobs, the whole-file address the consumers still use, and receiving them in pieces:
  `store/bridge.odin`, `store/receive.odin`.
- Moving blobs and refs between peers (`exchange`): what its owner calls →
  [exchange](references/exchange.md#what-the-owner-calls), its rules →
  [invariants](references/exchange.md#invariants), its tests →
  [verification](references/exchange.md#verification).
- Sharing a whole project over the exchange (`mirai share`, `mirai join`):
  [sharing](../mirai-projects/references/projects.md#sharing-a-project).

## Workflow

1. A writer puts objects (bytes, or a native asset's container chunks as groups) and refs into a
   batch, and commits once when the batch is done; a batch that grows past its bound commits on
   its own.
2. A reader opens an object by its root and reads a group from an offset; a chunk of a sealed pack
   is a slice of its mapping.
3. A long-running owner sweeps with what is live on the machine and scrubs at a byte budget.

## Invariants

- A chunk is 1 to `CHUNK_MAX` bytes named by the standard BLAKE3 of its bytes; an object is a tree
  of nodes over its chunks and its address is its root node's. The root's `LAYOUT` carries the
  layout of packs, frames, generations, nodes and the cut: a root of another layout, or one of the
  store before packs, is refused, never read or migrated.
- Every chunk lives in a pack, appended only by the writer that made it, whose lease (`w-` and its
  id) says it runs. A put reserves its range of the pack under the lock and writes outside it, so
  threads write at once; a small object is one write, and nothing is created, renamed or flushed
  per put, because a file and a flush per blob cost far more than an append.
- A commit flushes the batch, then writes the commit frame that makes it visible: one flush per
  batch. Readers take a pack's frames only up to its last commit whose count and sum of heads
  match, so a torn tail is never read; a ref is a frame of the same pack written after the chunks
  it reaches, so no reader sees a ref before what it names is durable. The commit frame itself
  reaches the disk with the next flush or the seal: a machine that crashes loses at most a
  writer's last batch.
- A pack is never written again once its writer stops: it is sealed (a trailer of its chunks
  sorted by address) at its size bound or when its writer closes, and a sweep seals at its last
  commit the pack of a writer whose lease is gone.
- Duplicates are allowed and harmless: a writer names a chunk it finds already stored instead of
  writing it, and two writers may store the same chunk at once; compaction keeps one copy. A
  chunk found with a copy older than a quarter of `GRACE` gets a Touch frame, so a sweep keeps it.
- A `Store` value reads the root again when a lookup misses and before `has`, `chunk_has`,
  `ref_get` and listing refs, which must see what other values committed; nothing polls. The
  state of a value, shared by its copies and the threads that use it, lives on the heap: it
  outlives the calls and crosses threads, so the allocator a store is opened with, also an
  arena, serves only its root and what a call returns.
- Only a sweep writes a generation, one sweep at a time by the claim it creates in `tmp/sweep`. It
  marks what refs, leases and its caller name and what was written or touched within `GRACE`;
  copies the live chunks of sealed packs that are mostly dead, or small, into its own pack; writes
  the next generation of every sealed pack, refs folded, synced and renamed into `index/`; and
  retires the replaced packs only after that. Active packs of live writers are never touched.
- A sweep never loses a committed put beside writers of other processes, which it cannot stop as
  an in-process collector would: a writer that committed before the mark is in the mark; one that
  committed after it is rechecked, and what it touched or named that is only in a retired pack is
  copied back and published again; one whose lookups predate a generation published before its
  commit looks its found chunks up again at commit and copies back from the retired pack what was
  dropped, or drops the batch (`Missing`) when that pack is gone too. So a retired pack is deleted
  at once only when no other writer runs, else by the next sweep, which deletes it before writing
  anything so it frees space on a full volume.
- A blob of another process's open pack, and its alias, stay until that pack is sealed: a sweep
  folds only sealed packs.
- A ref is folded into a generation by the newest frame of its name; a removed ref stays there as
  a record while a pack still being written could hold an older frame of it.
- Nothing is checked on a local read or a serve: a scrub checks the chunks of sealed packs against
  their addresses at a byte budget and a Tombstone frame stops every value reading a damaged copy,
  which a sweep then drops; a receiver checks what it receives.
- A full volume is `No_Space`, never `Io`; a pack that will not delete (one a process maps on
  Windows) is skipped, counted and deleted by a later sweep.
- The store never decides what is live: refs, leases and what its caller names are, and what was
  written or touched within `GRACE`. A process that uses addresses holds a lease that names its
  machine, pid and process start: on that machine it holds while the process runs, whatever the
  clock or a suspend did, and stops at once when the process ends; one of another machine on a
  shared root holds while it is younger than `LEASE_MAX_AGE`.
- On Windows every file of the store is opened sharing delete, and replacing or removing one uses
  POSIX semantics, so a reader, another process or an antivirus holding it does not stop it;
  sharing violations are retried briefly.
- Ref namespaces and names are lowercase ASCII, digits, `.`, `_` and `-`, the same on every
  system; the empty namespace is the store's own.
- External bytes are cut with FastCDC 2020, normalized at level 1 (`CHUNK_MIN`, `CHUNK_AVG`,
  `CHUNK_MAX`); the cut function and its gear table are part of the layout, since changing either
  changes every address. A cut is decided only with `CHUNK_MAX` bytes ahead or at the end, so a
  stream fed in any split cuts as the whole does, holding two `CHUNK_MAX` windows and allocating
  nothing per chunk. A container chunk of a native asset is cut where its writer says, never on
  content: consecutive pieces merge up to `CHUNK_MAX`, and a larger piece is cut at `CHUNK_MAX`
  offsets from its start, its remainder merging with the pieces after it.
- A node is a chunk: a `Node` record, its entries (address and data bytes under it), and in the
  root only its groups (runs of leaves, one per container chunk; a plain file has one) and meta,
  which the store does not read. Every object has a root, also an empty one. Each node has one
  encoding: reserved bytes are zero and the parser checks every count, size and sum against the
  bytes, the level against `NODE_LEVEL_MAX`, and each child against its parent's level and entry,
  so hostile nodes return `Corrupt` and a walk is bounded by the root's level.
- Nodes are grouped with content-defined boundaries over their entries' addresses, so an edit
  rewrites one node per level. The level that ends as one node is the root; when the groups and
  meta do not fit beside its entries, a root of one entry goes above it. A builder holds one open
  node per level and hands every chunk, data before the nodes naming it and the root last, to the
  sink its caller gives. A root's groups follow each other from leaf 0 and byte 0, each with the
  leaf and the byte where it begins.
- Until the consumers move to objects, a blob (the standard BLAKE3 of a whole file) is an object
  of one group and an alias, a ref of the empty namespace named by the blob's hex. A blob's file
  path is a copy written once into `tmp/blobs`, and its piece table is hashed from its bytes and
  checked against its address when served, so the old wire keeps working; a blob being received
  in pieces lives in `tmp/partial` until whoever finds every piece claims, checks and puts it.
- No input terminates the process: damaged, truncated or hostile packs and generations, random
  tables and pieces, out-of-range indices and memory that runs out return an `Error`; a pack that
  does not read is skipped and a generation that does not read refuses the root.

## Verification

- `mirai check store` (it runs the allocation lint) and `mirai test store`.
- Focal tests: `writers_of_several_processes_and_threads_share_one_root`,
  `a_pack_cut_anywhere_in_its_tail_opens_to_its_last_commit`,
  `a_ref_is_never_visible_before_what_it_names_is_durable`,
  `a_small_put_writes_once_and_a_batch_flushes_once`,
  `an_object_of_several_groups_reads_by_group_and_offset`,
  `a_sweep_beside_writers_loses_no_committed_put`,
  `compaction_keeps_every_live_chunk_and_drops_the_dead`,
  `a_full_volume_is_no_space_and_a_sweep_frees_it`, `a_scrub_tombstones_a_damaged_chunk`,
  `hostile_packs_and_generations_are_refused`, `hostile_inputs_return_errors` and
  `fresh_leases_keep_their_current_addresses`; for blobs
  `address_is_the_same_through_put_bytes_put_file_and_receiving` and
  `receiving_resumes_after_reopening_and_reads_the_pieces_it_has`; for chunks and nodes
  `chunks_are_the_same_streamed_in_any_split_and_whole`,
  `an_edit_changes_two_data_chunks_and_one_node_per_level`, `hostile_nodes_return_errors` and
  `groups_resolve_at_every_boundary`.
