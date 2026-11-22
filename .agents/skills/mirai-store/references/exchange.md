# Exchange: objects and refs between peers

`exchange` (layer 3) moves the chunks of a `store`'s objects and its refs between peers over the
connections of `net` hosts its owner already runs. It imports `store` and `net` and nothing
engine-time, so a headless peer and the editor link the same code. Its messages (protocol 5) are
in `exchange/wire.odin`.

## What the owner calls

- `CHANNEL_DESCS` gives the two reliable channels the exchange needs; the owner puts them in the
  `Host_Desc.channels` of every host at the same index and passes that index as `Desc.channel`.
- `init` sizes every buffer, table and job slot from the `Desc`; nothing is sized by an object, so
  an object of any size moves. `Desc.worker` is the job system and worker of the thread that
  pumps: reading, hashing, storing, walking, serving and committing run as its jobs; without one
  they run on the pump. `destroy` waits for them, so it is called from that thread.
- Per host poll: `peer_add` on `Connected`, `peer_remove` on `Disconnected`, `receive` on every
  `Message` (it says whether the message was its own). Then `update(now)` before `host_update`.
- A connection is given from its start: a message that began before `peer_add` is not read from
  its middle, so a restarted exchange takes new connections.
- `want` takes an object's root; asking again raises the priority. `forget`, `progress`,
  `peer_progress`; `ref_ask`, `names_ask`, `query_result`, `query_end`.
- `want_addresses` gives the root of every want, in progress or kept: the owner puts
  them in its store lease so a sweep keeps them and everything already received under them; the
  exchange holds no lease.
- `fetch` and `fetch_ref` block a job thread until what they name is complete in the store, or
  return `Missing` once no connected peer has it; the owner keeps pumping meanwhile, since every
  procedure takes the exchange's lock. `fetch_all` and `fetch_refs` do the same for a set, asked
  together: a caller that needs many objects or refs waits on the set, since each blocking call
  costs at least a round trip. Success is what the store says now: a kept want whose object was
  swept is asked again. `destroy` wakes every waiter with `Closed` and frees once none is left.
  A blocking call given a `cancel` flag returns `Cancelled` as soon as `fetch_cancel` sets it,
  letting go of what only it wanted; `cook/share` `package_take` cancels so
  (`package_take_cancel`).

## Invariants

- Asks are stateless, by chunk address with a byte budget; there is no session or fetch id. Any
  peer that holds a chunk answers, also one still receiving the object, and a chunk is atomic, so
  a peer has it or lacks it. The answer to an entry is its chunk, then its descendants depth first
  while their bytes fit the budget, stopping at the first one missing; then `Done` ends the ask.
- The receiver walks the tree of each want over what its store holds and asks only what it lacks:
  a chunk already stored is never asked, so a changed object costs its new chunks and the nodes
  above them. A root not here is asked with `ROOT_BUDGET`, so a small object comes whole in one
  round trip; the chunks and nodes the walk finds missing are asked with no budget, since the
  receiver may hold what is under them. A missing node stops the walk of its want until it
  arrives, and the next missing nodes are asked meanwhile.
- Priority belongs to the receiver: it asks for the most important wants first and nothing about
  priority goes on the wire beyond the order of the entries. At most `BATCHES` asks are in flight
  per peer, each sized to what the peer delivers in a round trip, so they keep twice that
  outstanding without queueing a low priority want ahead of a later high one. A root not here
  counts only against the entries of an ask, since most objects are small. A want keeps at most
  `WALK_AHEAD` chunks found and not asked, so many wants share the table of needs. What a full
  table does not take is never dropped: a walk that passed it walks again from the root once its
  needs arrived, and a root waits for room; a want is `Complete` only once its whole tree is here.
- Chunks are spread among the connected peers; a peer that lacks one is not asked for it again for
  a while, and a want that no peer can be asked for, or one of whose chunks no peer has, is
  `Missing`, asked again when a peer joins. What a peer was asked stays reserved to it only while
  it makes progress on that want; otherwise it goes to others, that peer is not asked for the
  want for a while, and its late answers release nothing a second time.
- A chunk travels as stored in its frame (`store.chunk_read_frame`), either plain or MDC2.
  The receiver verifies the decoded bytes against the address and keeps the received frame
  (`store.chunk_put_frame`). A compressed chunk asked for decodes once.
- Nothing is checked on serve. Nothing unverified reaches the store: a chunk is taken only as the
  answer to an entry asked of that peer or as a descendant of the entry it is answering within its
  budget, and only once it hashes to the address the ask or its parent named. A node is parsed and
  checked against its parent's level and entry before its entries are asked. A chunk that fails
  its address is reported with `Bad` and marks that peer wrong for that want, never the want; the
  peer checks its copy and tombstones it if damaged, so it lacks it from then on and fetches it
  again when it wants it. A tree whose chunks make their addresses but do not hold together fails
  the want, since every peer would send the same. Marks are per peer and leave with it, never
  passing to the next peer in its slot.
- A want is complete only after the commit that holds its last chunk: received chunks join the
  store's batch and the exchange commits once for the wants that finished, at most every
  `COMMIT_SECONDS`, and every `COMMIT_IDLE` for what arrived meanwhile, so a restarted receiver
  walks again from what it committed without asking for it.
- A want names an object by its root, which is always a node: a root that hashes right but is no
  node fails the want, since every peer would send the same.
- What a peer exposes is the owner's `Desc.expose`; without one no namespace is read. Names come
  sorted, a page at a time after the last one seen. A ref is asked of every connected peer, or of
  one when only that peer may say it (the snapshot of an invitation, from the host it names):
  refs name content, and only content is verified by address.
- Hostile input: a malformed message, an ask beyond the limits, descendants past a budget or an
  answer nobody could have asked for in that form marks the peer bad, and it is neither asked nor
  served again; a well formed message about something not asked for is ignored. An ask that does
  not fit the room for `BATCHES` asks is refused, and answers to questions find room only while
  the asker keeps a few waiting, so a peer cannot make another send without bound. A peer that
  does not answer a question within `QUERY_SECONDS` is taken to know nothing of it and its credit
  comes back, so a silent or overloaded peer never holds a question or its slot; a question its
  owner ended stays until every peer asked answered, gave up or left.
- The pump keeps the bookkeeping: wants, needs, flights, peers and the order of answers. Each job
  owns a slot sized at `init` (a ring of received chunks and their bytes, walks, the commit, a
  ring of answers per peer, checks of reported damage) and touches nothing else; the pump hands
  work to a slot and applies its result under the lock, so a job never takes the lock and the
  pump may wait for one, helping, when a ring is full. Received chunks are applied in the order
  they came, so a node is parsed and its entries are needs before a descendant streamed after it
  is taken; a descendant that came first is hashed and waits for its parent. A received node is
  walked by its own job, as far as it names chunks, and the walk goes on with the store's nodes
  in a walk job.
- Serving and receiving do not allocate in the exchange after `init`, except listing a namespace,
  for which the store reads its root. Answers to ref and name questions are read on the pump.

## Verification

- `mirai check exchange` and `mirai test exchange` (no GPU): every test runs peers on `net`'s
  `Sim_Network` in virtual time with temporary stores. The rate over UDP on loopback is the opt-in
  `objects_over_udp_loopback` with `-define:EXCHANGE_BENCHMARK=true`; it prints the CPU of the
  exchange (pump and jobs) apart from that of `net`'s worker. Tests run the jobs on the pump, so
  virtual time steps fast; `-define:EXCHANGE_TEST_JOBS=true` runs them on a job system, each step
  waiting for them. The memory bound of
  `a_ten_gigabyte_object_moves_within_bounded_memory` is the process's footprint, checked when it
  runs alone with `-define:ODIN_TEST_THREADS=1`.
- Focal tests:
  `objects_of_every_size_arrive_verified_under_loss_and_jitter`,
  `a_high_priority_want_asked_later_completes_before_a_large_low_one`,
  `a_transfer_resumes_after_the_connection_drops_and_after_the_store_reopens`,
  `a_liar_is_marked_and_the_object_still_arrives`,
  `a_receivers_bad_makes_the_server_repair_or_lack`,
  `a_peer_still_receiving_an_object_serves_its_chunks_to_a_third`,
  `refs_are_asked_and_listed_and_a_namespace_not_exposed_gives_nothing`,
  `the_blocking_form_returns_for_a_hit_a_miss_and_a_disconnect`,
  `the_batch_blocking_forms_return_for_a_hit_a_partial_miss_and_a_disconnect`,
  `many_small_objects_wanted_together_take_round_trips_that_do_not_grow_with_their_count`,
  `a_one_byte_insert_sends_only_the_new_chunks`,
  `a_ten_gigabyte_object_moves_within_bounded_memory`,
  `hostile_messages_are_refused_without_a_crash`,
  `hostile_trees_fail_the_want_without_a_crash`, `a_peer_past_the_budget_of_an_ask_is_bad`,
  `a_game_channel_keeps_its_delay_small_during_a_transfer`,
  `a_peer_that_holds_a_want_without_progress_loses_it`,
  `a_peer_in_a_freed_slot_is_not_blamed_for_its_predecessor`,
  `late_ref_answers_return_their_credits`,
  `a_late_done_does_not_release_what_another_peer_was_asked`,
  `peers_exchange_compressed_objects_both_ways` and
  `destroy_wakes_a_waiting_fetch`.
