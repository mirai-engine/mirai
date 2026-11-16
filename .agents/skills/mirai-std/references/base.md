# std/base

Package `base` (`import "mirai:std/base"`). Each file documents its types and procedures; this
holds the common contracts and what cannot be seen from a single function.

- Each structure is initialized with `x_init(&x, capacity, allocator) -> bool` or, over caller
  memory, with `x_init_buffer` (with parallel arrays, the capacity is that of the shortest);
  `x_destroy` releases what `x_init` requested. `x_init` returns `false` with a capacity of zero,
  negative or whose bytes exceed `max(int)/2`, and never requests more than that.
- The occupancy counters are `Usage`, included with `using` in each container.

## What is used from `core` without wrapping

- Fixed-capacity arrays: the native `[dynamic; N]T` (an extra `append` adds nothing) and
  `core:container/small_array`. General sorting: `core:slice`. Log: `core:log`.
- Not used: `core:container/queue` (it grows, and over caller memory it carries no counters),
  `priority_queue` and `slice/heap` (they compare through a procedure pointer), `bit_array`, `lru`
  and `map` (they grow or allocate per entry).

## Allocators (`alloc.odin`)

- All operate over a fixed block, expose `runtime.Allocator` and count in `Alloc_Stats`. A request
  that does not fit, of negative size or with an alignment that is not a power of two returns
  `.Out_Of_Memory` and adds to `failed`.
- `Arena` (linear, with marks), `Stack` (release in reverse order), `Heap` (the TLSF of `core` over
  the block), `Frame_Allocator` and `Block_Pool` (blocks of one size). In `Stack` and `Heap`,
  releasing a pointer that does not correspond gives `.Invalid_Pointer`; in `Block_Pool`, `false`.
- The control of the `Heap` lives inside the block, so the `Heap` can be copied. It returns exactly
  the bytes requested, also with an alignment greater than 8, which consumes extra memory.
- `Frame_Allocator` is two arenas: what is allocated in a frame is valid until the end of the next
  one. Its allocator does not change with `frame_swap` and may stay in `context.temp_allocator`.

## Handles (`handle_pool.odin`)

- `Handle_Pool` hands out slots with a generation; the data live in caller arrays indexed by
  `handle_index`. The generation is odd while the slot is in use: validating is one comparison. A
  slot that exhausted its generations is retired instead of repeating a handle.
- The own types (`Entity`, bodies, network objects) are `distinct Handle` and are converted with a
  cast.
- `Slot_Map(T, H)` stores dense values behind handles; removing moves the last value into the gap,
  so pointers are valid until the next removal and the order changes.

## Containers

- `Sparse_Set`: `sparse_set_remove` returns the freed row and the last one, which the caller moves
  in its parallel columns.
- `Spsc_Queue(T)`: lock-free between one producer and one consumer.
- `Priority_Queue(K, V)`: min-heap with numeric keys; for descending order, negate the key.
- Bits (`bits.odin`) over a caller `[]u64`: an index outside the words reads as off and is not
  written.
- `Hash_Map(V)`: `u64` keys (all valid, including 0), open addressing without tombstones. Pointers
  are valid until the next removal; `hash_map_grow` moves the values and is a transaction.
- `Region`: reserved address space of which only the first or the last bytes take memory, in steps
  of `REGION_STEP`. It never moves or goes through an allocator. `region_dynamic` gives a
  fixed-capacity `[dynamic]T` over the region: `region_grow` commits room before each `append`,
  which without room fails instead of moving the list.
- `Interner`: `Symbol(0)` is the empty text. `Lru(V)`: `lru_put` returns what it evicts.
- Fixed text (`text.odin`): `[N]u8` UTF-8 zero-padded, the format of the `.Text` flag of the schema.
  It cuts at a code point boundary and returns `false` if it cut; equal texts give byte-for-byte
  equal arrays.

## Hashing, identities and randomness

- `hash64` and `hash128` are XXH3 of `core`; `name_hash` (FNV-1a, `ids.odin`) is the name hash.
  `hash_mix` folds one word into a hash and starts at `HASH_SEED`: the key that tells whether a
  list of values changed. No package types its own mixer.
- `asset_id_from_content` and `asset_id_named` give the same id every time: a content generator uses
  them. What an import writes has random ids that live in its files.
- `Rng` is PCG32 with explicit state: 16 flat bytes and the same sequence on all platforms. A zeroed
  `Rng` works, but its first two values are 0. The distributions are in `std/math`.
- `entity_id_next` is the sequence of new `Entity_Id`s and never gives zero; `core.id_new` uses it
  in a world and `asset.scene_new_id` in a document. It is `splitmix_next`, the SplitMix64 sequence
  over one word of state.
- The hex texts of `Entity_Id` and `Asset_Id` are written in lowercase and read in both cases with
  exact length.

## Radix sort (`sort.odin`)

`radix_sort32` and `radix_sort64` are stable, linear and without allocations; with a `scratch`
shorter than `items` they do not sort. `sort_key_*` give keys that sort like their numbers.

## Profile zones (`profile.odin`)

- Each thread that records uses its own ring. The name of a zone is not copied: it must be a
  literal.
- `profile_read` copies the zones of a thread while that thread is not recording.
  `profile_read_since` writes nothing of the thread: another thread may drain one that keeps
  recording, and a zone written while being read may come out broken.
- Disabled (`profile_set_enabled`) it costs two branches per zone; with
  `-define:MIRAI_PROFILE=false` it is not compiled.
- Clock: on x86-64, the cycle counter if its frequency is constant, calibrated against the monotonic
  clock; otherwise, and on other architectures, `time.tick_now`.
