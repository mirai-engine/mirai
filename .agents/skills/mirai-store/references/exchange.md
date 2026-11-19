# Exchange: blobs and refs between peers

`exchange` (layer 3) moves the blobs and refs of a `store` between peers over the connections of
`net` hosts its owner already runs. It imports `store` and `net` and nothing engine-time, so a
headless peer and the editor link the same code. Its messages are in `exchange/wire.odin`.

## What the owner calls

- `channels()` gives the two reliable channels the exchange needs; the owner puts them in the
  `Host_Desc.channels` of every host at the same index and passes that index as `Desc.channel`.
- `init` sizes every buffer from the `Desc`; `Desc.max_blob_bytes` decides the largest table, and a
  table of that size is held per peer to send and to receive.
- Per host poll: `peer_add` on `Connected`, `peer_remove` on `Disconnected`, `receive` on every
  `Message` (it says whether the message was its own). Then `update(now)` before `host_update`.
- A connection is given from its start: a message that began before `peer_add` is not read from
  its middle, so a restarted exchange takes new connections.
- `want` (asking again raises the priority), `forget`, `progress`, `peer_progress`; `ref_ask`,
  `names_ask`, `query_result`, `query_end`.
- `want_addresses` gives the addresses of every want, in progress or kept: the owner puts them in
  its store lease so a sweep keeps them; the exchange holds no lease.
- `fetch` and `fetch_ref` block a job thread until the blob is complete in the store, or return
  `Missing` once no connected peer has it; the owner keeps pumping meanwhile, since every procedure
  takes the exchange's lock. `fetch_all` and `fetch_refs` do the same for a set, asked together:
  a caller that needs many blobs or refs waits on the set, since each blocking call costs at least
  a round trip. Success is what the store says now: a kept want whose blob was swept
  is asked again. `destroy` wakes every waiter with `Closed` and frees once none is left.

## Invariants

- Requests are stateless, by address and runs of pieces; there is no session or fetch id. Any peer
  that has the pieces answers, also from a blob it is still receiving (`store.read` and
  `store.blob_table` work on partial blobs).
- A blob is asked with its first `FIRST_PIECES` pieces. A blob of no more comes back whole, taken
  once its bytes hash to its address, so it needs no table and no partial blob; a larger one
  comes back as its size, its table and those pieces, and a table of `FIRST_PIECES` pieces or
  fewer is a lie. Adjacent pieces nobody was asked for go as one run. A request is bounded by
  `REQUEST_ENTRIES` and `REQUEST_BYTES`.
- Priority belongs to the receiver: it asks for the most important wants first and nothing about
  priority goes on the wire beyond the order of the entries. At most `BATCHES` requests are in
  flight per peer, each sized to what the peer delivers in a round trip, so they keep twice that
  outstanding without queueing a low priority want ahead of a later high one. A blob whose size is
  not known yet counts only against the limits of a request, since most blobs are small: a
  request carries as many of them as fit.
- Pieces are spread among the connected peers that do not lack the blob; a peer that lacks it is
  not asked again for a while, and a want with no peer left to ask is `Missing`, asked again when
  a peer joins. What a peer was asked stays reserved to it only while it makes progress on that
  want; otherwise it goes to others, that peer is not asked for the want for a while, and its late
  answers release nothing a second time.
- A request addresses at most `MAX_BLOB_BYTES` and never depends on the server's own cap: a blob
  above the server's `max_blob_bytes` is answered as lacking.
- Nothing unverified reaches a reader: tables and pieces go through `receive_begin` and
  `receive_piece`. A table or piece is taken only from the peer it was asked of; anything else
  counts against that peer. A table that does not match its address, claims a size this end does
  not hold, or a piece that does not match its table, marks that peer wrong for that blob, never
  the want; a true last piece that proves the size wrong (`Wrong_Size`) marks whoever gave the
  table, and the store drops only the partial blob. A whole blob that does not hash to its address
  marks the peer that sent it. Marks are per peer and leave with it, never passing to the next
  peer in its slot.
- What a peer exposes is the owner's `Desc.expose`; without one no namespace is read. Names come
  sorted, a page at a time after the last one seen.
- Hostile input: a malformed message, a request beyond the limits or an answer nobody could have
  asked for in that form marks the peer bad, and it is neither asked nor served again; a well formed
  message about something not asked for is ignored. A request that does not fit the room for
  `BATCHES` requests is refused, and answers to questions find room only while the asker keeps a
  few waiting, so a peer cannot make another send without bound. A question its owner ended stays
  until every peer asked answered or left, so late answers return their credits.
- Serving and receiving do not allocate after `init`, except listing a namespace, for which the
  store reads a folder.

## Verification

- `mirai check exchange` and `mirai test exchange` (no GPU): every test runs peers on `net`'s
  `Sim_Network` in virtual time with temporary stores.
- Focal tests:
  `blobs_around_the_piece_boundaries_and_a_large_one_arrive_verified_under_loss_and_jitter`,
  `a_high_priority_want_asked_later_completes_before_a_large_low_one`,
  `a_transfer_resumes_after_the_connection_drops_and_after_the_store_reopens`,
  `a_liar_in_the_table_a_piece_or_the_size_is_marked_and_the_blob_still_arrives`,
  `a_peer_still_receiving_a_blob_serves_its_pieces_to_a_third`,
  `refs_are_asked_and_listed_and_a_namespace_not_exposed_gives_nothing`,
  `the_blocking_form_returns_for_a_hit_a_miss_and_a_disconnect`,
  `the_batch_blocking_forms_return_for_a_hit_a_partial_miss_and_a_disconnect`,
  `many_small_blobs_wanted_together_take_round_trips_that_do_not_grow_with_their_count`,
  `hostile_messages_are_refused_without_a_crash`,
  `a_game_channel_keeps_its_delay_small_during_a_transfer`,
  `a_wrong_size_found_after_another_process_published_the_blob_keeps_it`,
  `a_peer_that_holds_a_want_without_progress_loses_it`,
  `a_peer_in_a_freed_slot_is_not_blamed_for_its_predecessor`,
  `late_ref_answers_return_their_credits`,
  `a_late_done_does_not_release_what_another_peer_was_asked`, `destroy_wakes_a_waiting_fetch` and
  `a_server_with_the_smallest_cap_serves_an_honest_request`.
