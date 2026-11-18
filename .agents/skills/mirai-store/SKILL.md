---
name: mirai-store
description: Mirai machine-wide content-addressed store (the `store` package) - blobs named by their
  BLAKE2b address and cut in pieces, receiving a blob piece by piece with resume, range reads of
  partial blobs, refs that name an address, usage and sweep, and the default root. Use when
  storing or sharing heavy content between projects or peers, building a blob transport, an asset
  library or a derived data cache on top of it, or diagnosing a corrupt or missing blob.
---

# Mirai store

`store` (layer 1) imports only `base`, `core` and `std`: a plain library a game binary may link.
It knows two concepts, blobs and refs, and interprets neither: the transport, the library and the
derived data cache that use it decide what a ref means and what is live.

## Map

- Address, pieces and hex: `store/address.odin`.
- Root, layout version, errors and atomic writes: `store/store.odin`.
- Complete blobs, their kept tables and readers: `store/blobs.odin`.
- Receiving a blob piece by piece and range reads of a partial one: `store/receive.odin`.
- Refs and their names: `store/refs.odin`.
- Usage and sweep: `store/space.odin`.

## Workflow

1. A sender serves the piece table of a complete blob and its pieces; it reads ranges by path or
   with the range read.
2. A receiver begins from the address and the table, gives each piece as it arrives in any order,
   and asks which pieces are missing to request them again, also after a restart.
3. A layer that names content sets a ref in its own namespace; it sweeps with the set of addresses
   its refs and open work reach.

## Invariants

- The address is a pure function of the bytes: the length and the hash of every fixed-size piece,
  one rule for every size. Piece hashes and addresses are keyed apart so none is taken for another.
  A piece hash depends only on its piece and index, so pieces can be hashed in parallel; the
  address only orders them.
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
- A complete blob's piece table is kept beside it, written once and checked against the address
  whenever it is read, so serving a blob never rehashes it; a damaged kept table is rebuilt.
- A complete blob is a plain file of its raw bytes, never written in place: readers open it by
  path or hold it open with a `Reader`.
- The root carries its layout version; a root of another layout is refused, never read.
- The store never decides what is live: sweep removes the complete blobs outside the set it is
  given, and partial blobs only go through remove.
- Ref namespaces and names are lowercase ASCII, digits, `.`, `_` and `-`, so a ref is the same
  file on every system.
- No input terminates the process: damaged or truncated files of the root, random tables and
  pieces, out-of-range indices and memory that runs out return an `Error`.

## Verification

- `mirai check store` (it runs the allocation lint) and `mirai test store`.
- Focal tests: `address_is_the_same_through_put_bytes_put_file_and_receiving` (sizes around the
  piece boundaries), `receiving_resumes_after_reopening_and_reads_the_pieces_it_has`,
  `two_stores_on_one_root_put_and_receive_from_several_threads`,
  `completion_publishes_only_the_bytes_it_checked`,
  `a_failed_placement_loses_nothing_and_is_retried` and `hostile_inputs_return_errors`.
