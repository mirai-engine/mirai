---
name: mirai-store
description: Mirai machine-wide content-addressed store (the `store` package) - chunks in
  append-only packs, objects as trees of chunks read by group and offset, refs, commits and
  batches, index generations, the sweep that compacts packs beside running writers, the scrub,
  leases and the default root - and the `exchange` package that moves the chunks of objects and
  refs between peers over `net` (asks with a budget, wants as objects, priorities, several
  sources, lying peers, blocking fetch). Use when storing or sharing heavy content between
  projects or peers, building an asset library or a derived data cache on top of it, fetching an
  object from another machine, or diagnosing a corrupt, missing, slow or growing store.
---

# Mirai store

`store` (layer 1) imports only `base`, `core` and `std`, including `std/compressor/data`. A game
binary may link it.
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
- Frame encoding and scratch: `store/codec.odin`. The data codec is defined in
  [assets](../mirai-assets/references/formats.md#compression).
- Sweep, compaction, generations, scrub and the sweep's claims: `store/sweep.odin`; leases:
  `store/leases.odin`. The sweep a long-running owner calls, with what is live on the machine:
  `asset.store_sweep` (`asset/collect.odin`).
- Moving objects and refs between peers (`exchange`): what its owner calls →
  [exchange](references/exchange.md#what-the-owner-calls), its rules →
  [invariants](references/exchange.md#invariants), its tests →
  [verification](references/exchange.md#verification).
- Sharing a whole project over the exchange (`mirai share`, `mirai join`):
  [sharing](../mirai-projects/references/projects.md#sharing-a-project).
- The records, logs and derived data of Kai (version control and the mesh of an org), which keep
  their state as objects and refs of this store in namespaces of their own:
  [Kai](../mirai-kai/SKILL.md).

## Workflow

1. A writer puts objects (bytes, or a native asset's container chunks as groups) and refs into a
   batch, and commits once when the batch is done; a batch that grows past its bound commits on
   its own. A large stream is put with a worker of a job system: the caller cuts, jobs hash and
   append.
2. A reader opens an object by its root and reads a group from an offset; a chunk of a sealed pack
   is a slice of its mapping.
3. A long-running owner sweeps with what is live on the machine and scrubs at a byte budget.

## Invariants

- A chunk is 1 to `CHUNK_MAX` bytes named by the standard BLAKE3 of its bytes; an object is a tree
  of nodes over its chunks and its address is its root node's. What is hashed never depends on a
  compressor: a put encodes a chunk's frame with MDC2 when that shrinks it and
  records the codec in the frame (nodes stay as they are, so a sweep walks them directly), and
  a read decodes into the caller's buffer; a frame stored as it is is a slice of the mapped pack.
  The root's `LAYOUT` carries the layout of packs, frames, generations, nodes and the cut: a root
  of another layout, or one of the store before packs, is refused, never read or migrated.
- A frame a caller offers (`chunk_put_frame`) is decoded and checked against its address before
  it is kept. Invalid frames are refused, and a scrub tombstones damaged chunks it finds.
- Every chunk lives in a pack, appended only by the writer that made it, whose lease (`w-` and its
  id) says it runs. A put reserves its range of the pack under the lock and writes outside it, so
  threads write at once; a small object is one write, and nothing is created, renamed or flushed
  per put, because a file and a flush per object cost far more than an append. Cuts stay in order
  on one thread while jobs hash and append the chunks, and leaves join the tree in the order of
  the cuts, so an object is the same put on one thread or many.
- A commit writes the batch's frames and the commit frame that makes them visible, then flushes
  once: a commit that returns success is durable. Readers take a pack's frames only up to its
  last commit whose count and sum of heads match, so a torn tail is never read; a ref is a frame
  of the same pack written after the chunks it reaches. What a batch names in another writer's
  open pack is flushed before its commit frame is written, so a crash never keeps a ref and loses
  what it names.
- A pack is written only by its writer: it is sealed (a trailer of its chunks sorted by address)
  at its size bound or when its writer closes. A sweep never writes into another's pack: one whose
  writer's lease is gone is folded up to its last commit and retired, and a writer that is in fact
  alive (another machine's lease not refreshed in time) finds its lease gone after its commit
  frame and writes the batch again in a new pack under a new lease before the commit returns.
- Duplicates are allowed and harmless: a writer names a chunk it finds already stored instead of
  writing it, and two writers may store the same chunk at once; compaction keeps one copy. A
  chunk found with a copy older than a quarter of `GRACE` gets a Touch frame, so a sweep keeps it.
- A `Store` value reads the root again when a lookup misses and before `has`, `chunk_has`,
  `ref_get` and listing refs, which must see what other values committed; nothing polls. The
  state of a value, shared by its copies and the threads that use it, lives on the heap: it
  outlives the calls and crosses threads, so the allocator a store is opened with, also an
  arena, serves only its root and what a call returns.
- A read pass that looks up many refs or objects borrows the store with `read_index`. It reads
  the root once, or uses the index from `open` when the owner just opened it. The borrow shares
  the owner's index, so it sees local writes and must end before the owner closes the store.
- A value holds a descriptor per pack it loaded, and loads every pack no generation folds: only
  a sweep bounds them. `open` raises the process's limit of open files to what the system allows
  (`files_limit_raise`), since a shell or a desktop hands a process a few hundred.
- Only a sweep writes a generation, one sweep at a time by the claim it creates in `tmp/sweep`; a
  claim of a holder that ended is taken by moving it aside and checking it is the one judged, and
  a generation is published only where none of that number is, so exactly one sweep owns it. It
  marks what refs, leases and its caller name, every chunk under them at every level, and what
  was written or touched within `GRACE`;
  copies the live chunks of sealed packs that are mostly dead, or small, into its own pack; writes
  the next generation of every sealed pack, refs folded, synced and renamed into `index/`; and
  retires the replaced packs only after that. Active packs of live writers are never touched.
- A sweep never loses a committed put beside writers of other processes, which it cannot stop as
  an in-process collector would. A retired pack lives in `retired/` under the generation that
  dropped it, and a reader that misses everywhere else reads it there. A writer looks what its
  batch found stored up again when a newer generation appeared, before its commit frame and after
  it, and copies back what was retired; a lease update does the same for the addresses it adds.
  Each lease carries the generation its holder last checked against; a sweep copies back what a
  live root reaches that only a retired pack holds, and deletes a retired pack only once every
  other writer's lease carries its generation and every other lease does or is what the sweep
  marked from, deleting before it writes anything so it frees space on a full volume.
- What another process's open pack holds stays until that pack is sealed: a sweep folds only
  sealed packs.
- A ref is folded into a generation by the newest frame of its name; a removed ref stays there as
  a record while a pack still being written could hold an older frame of it.
- Nothing is checked on a local read or a serve: a scrub checks the chunks of sealed packs against
  their addresses at a byte budget and a Tombstone frame stops every value reading a damaged copy,
  which a sweep then drops; a receiver checks what it receives. A read never touches a mapping
  beyond the file's size now: a pack cut below a chunk is damaged, an error.
- A full volume is `No_Space`, never `Io`; a pack that will not delete (one a process maps on
  Windows) is skipped, counted and deleted by a later sweep.
- Slices of a mapping handed to a caller have no lifetime, so a pack a value lent stays mapped
  until it closes: a sweep reports what it deleted that its value lent as held, apart from what it
  freed, and a value closes the gone packs it never lent when it reads a new generation. What
  other processes map is invisible to it and stays on disk until they close it.
- The store never decides what is live: refs, leases and what its caller names are, and what was
  written or touched within `GRACE`. A sweep with `reclaim` (a ddc node over its quota) takes the
  bytes of the dead off the disk at once: it compacts every sealed pack holding a dead chunk and
  keeps what its own value wrote only when a root reaches it, so its caller names all it needs;
  other writers keep their `GRACE`. A process that uses addresses holds a lease that names its
  machine, pid and process start: on that machine it holds while the process runs, whatever the
  clock or a suspend did, and stops at once when the process ends; one of another machine on a
  shared root holds while it is younger than `LEASE_MAX_AGE`.
- On Windows every file of the store is opened sharing delete, and replacing or removing one uses
  POSIX semantics, so a reader, another process or an antivirus holding it does not stop it;
  sharing violations are retried briefly.
- Ref namespaces and names are lowercase ASCII, digits, `.`, `_` and `-`, the same on every
  system.
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
  leaf and the byte where it begins; above level 0 only the leaves say where those are, so opening
  such an object walks its leaf nodes once and refuses a group that does not begin on its leaf.
- No input terminates the process: damaged, truncated or hostile packs and generations, random
  tables and pieces, out-of-range indices and memory that runs out return an `Error`; a pack that
  does not read is skipped and a generation that does not read refuses the root.

## Verification

- `mirai check store` (it runs the allocation lint) and `mirai test store`.
- Focal tests: `writers_of_several_processes_and_threads_share_one_root`,
  `a_stream_put_on_workers_is_the_same_object`,
  `a_commit_paused_across_a_sweep_keeps_what_it_names`,
  `a_live_writer_whose_lease_went_stale_keeps_its_commits`,
  `two_sweeps_taking_a_stale_claim_publish_once`,
  `an_address_added_to_a_lease_during_a_sweep_is_kept`,
  `a_pack_cut_anywhere_in_its_tail_opens_to_its_last_commit`,
  `a_commit_that_returns_is_durable`,
  `a_small_put_writes_once_and_a_batch_flushes_once`,
  `an_object_of_several_groups_reads_by_group_and_offset`,
  `a_sweep_beside_writers_loses_no_committed_put`,
  `compaction_keeps_every_live_chunk_and_drops_the_dead`,
  `a_full_volume_is_no_space_and_a_sweep_frees_it`, `a_scrub_tombstones_a_damaged_chunk`,
  `hostile_packs_and_generations_are_refused`, `hostile_inputs_return_errors` and
  `fresh_leases_keep_their_current_addresses`, `a_chunk_check_tombstones_a_damaged_copy`,
  `opening_a_store_raises_the_limit_of_open_files`,
  `frames_compress_and_addresses_are_of_the_bytes`,
  `a_damaged_encoded_frame_is_a_damaged_chunk`, `hostile_chunk_frames_are_refused`; for
  chunks and nodes
  `chunks_are_the_same_streamed_in_any_split_and_whole`,
  `an_edit_changes_two_data_chunks_and_one_node_per_level`, `hostile_nodes_return_errors` and
  `groups_resolve_at_every_boundary`.
