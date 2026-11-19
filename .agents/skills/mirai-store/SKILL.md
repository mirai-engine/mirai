---
name: mirai-store
description: Mirai machine-wide content-addressed store (the `store` package) - blobs named by their
  BLAKE3 address and cut in pieces, receiving a blob piece by piece with resume, range reads of
  partial blobs, refs that name an address, usage and sweep, and the default root - and the
  `exchange` package that moves blobs and refs between peers over `net` (wants, priorities,
  several sources, lying peers, blocking fetch). Use when storing or sharing heavy content between
  projects or peers, building an asset library or a derived data cache on top of it, fetching a
  blob from another machine, or diagnosing a corrupt, missing or slow blob.
---

# Mirai store

`store` (layer 1) imports only `base`, `core` and `std`: a plain library a game binary may link.
It knows two concepts, blobs and refs, and interprets neither: the transport, the library and the
derived data cache that use it decide what a ref means and what is live.

## Map

- Address, pieces and hex: `store/address.odin`.
- Cutting bytes into chunks (content-defined and at a native asset's cut points):
  `store/chunk.odin`; node records, building an object's tree into a sink and resolving a byte
  or a group offset to a leaf: `store/node.odin`.
- Root, layout version, errors and atomic writes: `store/store.odin`; what differs per system
  (sharing on Windows, a full volume, whether a process runs): `store/system_*.odin`.
- Complete blobs, their kept tables and readers: `store/blobs.odin`.
- Receiving a blob piece by piece and range reads of a partial one: `store/receive.odin`.
- Refs and their names: `store/refs.odin`.
- Usage and sweep: `store/space.odin`; leases: `store/leases.odin`. The sweep a long-running
  owner calls, with what is live on the machine: `asset.store_sweep` (`asset/collect.odin`).
- Moving blobs and refs between peers (`exchange`): what its owner calls →
  [exchange](references/exchange.md#what-the-owner-calls), its rules →
  [invariants](references/exchange.md#invariants), its tests →
  [verification](references/exchange.md#verification).
- Sharing a whole project over the exchange (`mirai share`, `mirai join`):
  [sharing](../mirai-projects/references/projects.md#sharing-a-project).

## Workflow

1. A sender serves the piece table of a complete blob, or of one it is still receiving, and its
   pieces; it reads ranges by path or with the range read.
2. A receiver begins from the address and the table, gives each piece as it arrives in any order,
   and asks which pieces are missing to request them again, also after a restart.
3. A layer that names content sets a ref in its own namespace; it sweeps with the set of addresses
   its refs and open work reach.

## Invariants

- The address is the standard BLAKE3 hash of the bytes, so any BLAKE3 tool computes it. A piece is
  a BLAKE3 group: its value is the group's chaining value, and the address is the BLAKE3 root of
  the table; a blob of one piece has its hash as its only entry. A piece value depends only on
  its bytes and index, so pieces can be hashed in parallel. Hashing a file holds its table, 32
  bytes a piece, never its bytes. The root version carries the address rule: a root of another
  rule is refused, never migrated.
- A table does not carry the length of its last piece: a size with the right piece count passes
  the table check, and then the true last piece returns `Wrong_Size` instead of being kept: the
  partial folder is discarded (a complete blob never is) and the receiver begins again with the
  size the piece proves. A table of one piece is its own address and proves nothing, so
  `receive_begin` refuses it: such a blob is put whole once its bytes hash to the address.
- Only the two private procedures of `address.odin` (the value of a piece, the address of a table)
  touch the hash primitive; everything else, tests included, goes through them or the API, so the
  primitive can be replaced in one place.
- State lives in a `Store` value; several values and processes share one root without locks.
  Every file appears whole through a rename from the root's tmp folder; a receiver writes only its
  own piece and its own byte of the piece marks, so concurrent receivers of one blob agree.
- A table is checked against the address before anything is kept, a piece against the table
  before it is written and again before a range read returns it, and the whole blob against its
  address before it becomes complete; a piece that fails then is marked missing again.
- Completion publishes only bytes it checked: whoever finds every piece marked claims the partial
  folder by renaming it, checks it under the claim and places it from there. A completion that
  cannot finish (a damaged piece, a placement refused) gives the folder back with nothing lost,
  and the next receiver that finds it full retries.
- A complete blob of several pieces keeps its piece table beside it, written once and checked
  against the address whenever it is read, so serving a blob never rehashes it; a damaged kept
  table is rebuilt. A blob of one piece keeps none: its table is its address.
- A complete blob is a plain file of its raw bytes, never written in place: readers open it by
  path or hold it open with a `Reader`. A put or a completion that finds a file of another size in
  its place replaces it; a full check of what is there would read the whole file on every put, so
  content is checked where bytes are read anyway.
- `read`, a `Reader` and serving check every piece of a complete blob against its kept table
  (checked against the address when the reader opens): a piece that does not match proves the file
  damaged, is never returned, and the blob is removed so it is fetched or put again.
- The bytes of a received blob reach the disk before it is published, as those of a put do.
- A receiver holds a blob's partial files open across its pieces and reads the marks only from the
  first one it has not seen marked.
- The root carries its layout version; a root of another layout is refused, never read.
- The store never decides what is live: sweep removes the complete blobs outside the set it is
  given plus the addresses of every lease that holds, and the partial blobs outside them that took
  no piece for `PARTIAL_GRACE_AGE`. `asset.store_sweep` gives it every ref of every namespace and
  the outputs of the builds they name; nothing in the store sweeps on its own.
- A sweep judges what it claims in `tmp/sweep`, made with the root, so it frees space on a full
  volume; a sweep that stopped leaves its claims there, and the next one removes those old enough
  and gives back the rest. A full volume is `No_Space`, never `Io`.
- A sweep is safe beside writers of other processes: it never removes a blob younger than the
  grace age, a put of a blob already here refreshes its time, and the sweep claims an old blob by
  renaming it away before it judges its age again, giving it back if a put refreshed it. A put that
  succeeds is never lost to a sweep; a reader may find a blob missing for the instant of a claim,
  which is a miss like any other. A blob that will not delete is skipped and counted.
- A process that uses blobs holds a lease that names its machine, pid and process start: on that
  machine it holds while the process runs, whatever the clock or a suspend did, and stops at once
  when the process ends. A lease of another machine on a shared root holds while it is younger
  than `LEASE_MAX_AGE`.
- On Windows every file of the store is opened sharing delete, and replacing or removing one uses
  POSIX semantics, so a reader, another process or an antivirus holding it does not stop it;
  sharing violations are retried briefly.
- Ref namespaces and names are lowercase ASCII, digits, `.`, `_` and `-`, so a ref is the same
  file on every system.
- A chunk is 1 to `CHUNK_MAX` bytes named by the standard BLAKE3 of its bytes. External bytes are
  cut with FastCDC 2020, normalized at level 1 (`CHUNK_MIN`, `CHUNK_AVG`, `CHUNK_MAX`); the cut
  function and its gear table are part of the layout, since changing either changes every
  address. A cut is decided only with `CHUNK_MAX` bytes ahead or at the end, so a stream fed in
  any split cuts as the whole does, holding two `CHUNK_MAX` windows and allocating nothing per
  chunk.
- A container chunk of a native asset is cut where its writer says, never on content:
  consecutive pieces merge up to `CHUNK_MAX`, and a larger piece is cut at `CHUNK_MAX` offsets
  from its start, its remainder merging with the pieces after it.
- An object is a tree of nodes over its chunks, and its address is its root node's. A node is a
  chunk: a `Node` record, its entries (address and data bytes under it), and in the root only its
  groups (runs of leaves, one per container chunk; a plain file has one) and meta, which the
  store does not read. Every object has a root, also an empty one. Each node has one encoding:
  reserved bytes are zero and the parser checks every count, size and sum against the bytes, the
  level against `NODE_LEVEL_MAX`, and each child against its parent's level and entry, so hostile
  nodes return `Corrupt` and a walk is bounded by the root's level.
- Nodes are grouped with content-defined boundaries over their entries' addresses: an entry whose
  first four bytes, as a little-endian u32, are below `2^32 / NODE_ENTRIES_TARGET` is the last of
  its node once the node holds `NODE_ENTRIES_MIN` entries, and the entry `NODE_ENTRIES_MAX` always
  is, so an edit rewrites one node per level. The level that ends as one node is the root; when
  the groups and meta do not fit beside its entries, a root of one entry goes above it. A builder
  holds one open node per level and hands every chunk, data before the nodes naming it and the
  root last, to the sink its caller gives.
- A root's groups follow each other from leaf 0 and byte 0, each with the leaf and the byte where
  it begins; the parser checks the offsets exactly against a level-0 root's entries and, above
  it, against what leaves of 1 to `CHUNK_MAX` bytes allow up to the total. A byte of an object,
  or of a group from its offset, is found by descending with the entries' sizes.
- No input terminates the process: damaged or truncated files of the root, random tables and
  pieces, out-of-range indices and memory that runs out return an `Error`.

## Verification

- `mirai check store` (it runs the allocation lint) and `mirai test store`.
- Focal tests: `address_is_the_same_through_put_bytes_put_file_and_receiving` (sizes around the
  piece boundaries), `receiving_resumes_after_reopening_and_reads_the_pieces_it_has`,
  `two_stores_on_one_root_put_and_receive_from_several_threads`,
  `completion_publishes_only_the_bytes_it_checked`, `fresh_leases_keep_their_current_addresses`,
  `sweep_removes_old_partials_and_settles_what_a_stopped_sweep_claimed`,
  `a_failed_placement_loses_nothing_and_is_retried` and `hostile_inputs_return_errors`; for
  chunks and nodes `chunks_are_the_same_streamed_in_any_split_and_whole`,
  `an_edit_changes_two_data_chunks_and_one_node_per_level`, `hostile_nodes_return_errors` and
  `groups_resolve_at_every_boundary`.
