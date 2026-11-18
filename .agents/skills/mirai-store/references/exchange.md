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
- `fetch` and `fetch_ref` block a job thread until the blob is complete in the store, or return
  `Missing` once no connected peer has it; the owner keeps pumping meanwhile, since every procedure
  takes the exchange's lock.

## Invariants

- Requests are stateless, by address and runs of pieces; there is no session or fetch id. Any peer
  that has the pieces answers, also from a blob it is still receiving (`store.read` and
  `store.blob_table` work on partial blobs).
- The answer to a blob carries its size, its table and its first pieces; adjacent pieces nobody
  was asked for go as one run. A request is bounded by `REQUEST_ENTRIES` and `REQUEST_BYTES`.
- Priority belongs to the receiver: it asks for the most important wants first and nothing about
  priority goes on the wire beyond the order of the entries. At most `BATCHES` requests are in
  flight per peer, each sized to what the peer delivers in a round trip, so they keep twice that
  outstanding without queueing a low priority want ahead of a later high one.
- Pieces are spread among the connected peers that do not lack the blob; a peer that lacks it is
  not asked again for a while, and a want with no peer left to ask is `Missing`, asked again when
  a peer joins.
- Nothing unverified reaches a reader: tables and pieces go through `receive_begin` and
  `receive_piece`. A table that does not match its address, or a piece that does not match its
  table, marks that peer wrong for that blob; a true last piece that proves the size wrong
  (`Wrong_Size`) marks whoever gave the table, removes the partial blob and asks the table of
  others. A peer stays wrong for a blob until it leaves.
- What a peer exposes is the owner's `Desc.expose`; without one no namespace is read. Names come
  sorted, a page at a time after the last one seen.
- Hostile input: a malformed message, a request beyond the limits or an answer nobody could have
  asked for in that form marks the peer bad, and it is neither asked nor served again; a well formed
  message about something not asked for is ignored. A request that does not fit the room for
  `BATCHES` requests is refused, and answers to questions find room only while the asker keeps a
  few waiting, so a peer cannot make another send without bound.
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
  `hostile_messages_are_refused_without_a_crash` and
  `a_game_channel_keeps_its_delay_small_during_a_transfer`.
