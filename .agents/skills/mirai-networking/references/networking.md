# Networking: current behavior

Descriptors, defaults, and stats (`Host_Desc`, `Replication_Desc`, `Object_Desc`, `Channel_Desc`,
`Sim_Conditions`, `Clock`, `Host_Stats`) are documented in `net/`.

## Bitstream (`std/serial/bitstream.odin`)

- `Bit_Writer` and `Bit_Reader` operate LSB-first over `[]u8` (64-bit word staging). Overflowing
  sets `overflow` and drops later writes; `bit_writer_init_measure` counts bits only; copying a
  writer value checkpoints for rollback.
- Reading past end or outside an integer range sets `error` and returns zeros (never OOB).
- Primitives: bits, bool, ranged ints, varuint, zigzag varint, raw/ranged/precision floats,
  octahedral unit vectors, smallest-three quats, length-prefixed bytes/strings, and standalone
  `quantize_*`/`dequantize_*`. `bit_write_align`/`bit_read_align` copy aligned bytes whole;
  `bit_read_view` returns a zero-copy slice.

```odin
import "mirai:std/serial"

buf: [64]u8
w: serial.Bit_Writer
serial.bit_writer_init(&w, buf[:])
saved := w
serial.bit_write_ranged(&w, 12, 0, 100)
serial.bit_write_float_precision(&w, 1.5, -10, 10, 0.01)
if w.overflow {w = saved} // rollback writes
bytes := serial.bit_writer_flush(&w)
```

## Transport

`Transport` moves batched datagrams (`PACKET_BYTES` max). `send`/`receive` never block;
`wait`/`wake` are required only when using `worker_start`.

- **`Udp`:** Non-blocking `core:net` socket (port 0 = ephemeral). Batched syscalls on macOS
  (`sendmsg_x`/`recvmsg_x`) and Linux (`sendmmsg`/`recvmmsg`), loop on Windows behind
  `udp_send_batch`/`udp_receive_batch`. `wait` polls socket + `127.0.0.1` waker. Binding
  `address_any6` disables `IPV6_V6ONLY` (`udp_dual_stack`); IPv4-mapped peers normalize to IPv4 via
  `address_from_endpoint`.
- **`Relay` & IPv6 addresses:** `address_relay(node, peer_dh)` / `address_relay_node` address a peer
  behind a relay node; `address_global` / `address_global6` detect globally routable endpoints.
- **DNS:** Async `resolve_start` / `resolve_poll` (IPv6 first) / `resolve_end`. `address_parse`
  accepts literal IPs only.
- **`Sim_Network`:** Deterministic, thread-safe in-memory transport driven by `sim_network_advance`;
  `sim_endpoint_conditions` adds latency, jitter, loss, reordering, and bandwidth limits.
- **`Conditioner`:** Wraps any `Transport` (e.g. `Udp`) with symmetric `Sim_Conditions` (RTT =
  `2 * latency`) in preallocated queues (`dropped_full` on overflow).

## Host: two halves

[Port mapping](port-mapping.md) yields candidate endpoints; `net.Host` establishes authenticated
connections. A `Host` must not move after `host_init`; `Invalid` populates `Host.refused` (field
path and allowed range).

- **Simulation half (`Front`):** Game calls append ops to staging frame. `host_publish(h, tick)`
  quantizes dirty/due objects and queues the frame; `host_poll(h)` swaps in received `[]Command`
  (valid until next poll) and updates stats, replicas, inputs, and clock.
- **Network half (`Back`):** `host_update(h, now)` or `worker_start(h)` applies queued frames,
  receives, runs scope, packs, and sends without touching game memory. Worker sleeps in `wait`
  until datagram arrival, queued frame, drained command buffer, or next due timer (<=1 ms while
  in-flight/unacked, else keepalive/handshake).
- **Backpressure:** Buffer swap is the only mutex point. Behind network merges into staging frame
  (`publish_stalls`); low command buffer reserve pauses socket reads (`receive_stalls`).
- **Tick order:** `host_poll` -> simulate -> `host_publish(tick)` -> `host_update(now)` (no
  worker).

```odin
import wire "mirai:net"

udp: wire.Udp
if !wire.udp_open(&udp, wire.address_any6(27500)) {return}
defer wire.udp_close(&udp)

host: wire.Host
if wire.host_init(&host, {
    mode=.Server, transport=wire.udp_transport(&udp),
    protocol=&proto, protocol_id=0x4d495241, version=1,
}) != .None {return}
defer wire.host_destroy(&host)

for cmd in wire.host_poll(&host) { /* handle commands */ }
wire.host_publish(&host, tick)
wire.host_update(&host, wire.host_time(&host))
```

## Connections

- **Handshake (`net/secure.odin`):** Noise `NKpsk0` (`Noise_NKpsk0_25519_ChaChaPoly_SHA256`),
  2 datagrams with 0-RTT data on invite:
  - *Initiate* (`-> psk, e, es`): header prologue + client datagram 0 (`message_send` to conn 0
    after `host_connect`), sent to all candidate addresses until *Response* (`<- e, ee`, sealed
    capacity/history/slot). Denials end the attempt only after every candidate denies.
  - Without invite: padded *Hello* -> stateless *Key* (`s`, version, SipHash cookie) -> *Initiate*
    with cookie and zero PSK.
  - **Identity (`host_connect_identity`):** Noise `IK` (`Noise_IK_25519_ChaChaPoly_SHA256`) using
    `Host_Desc.identity` (`Dh_Key`), keyed MAC (`BLAKE3("kai-1/mac" || server identity)`), and
    `Host_Desc.authorize` (`Refuse` / `Pending` / `Accept`) run only after client confirmation;
    `host_authorize` re-evaluates live peers (`Revoked` on refusal).
- **Anti-DoS & replay:** Trailing HMAC-SHA256 filters strays without DH (invited servers ignore
  unauthenticated packets and *Hello*). Server stores seen `e` keys in Bloom filters (lifetime of
  `s` without cookie; rotating `COOKIE_SECONDS` generations with cookie, cap `SEEN_LIMIT`). Full
  filter, false positive, or `BUSY_SECONDS` after DH budget exhaustion (`handshakes_per_update`)
  sends compact *Retry* cookie. Padded `HANDSHAKE_BYTES` prevents amplification. Wrong-MAC
  Initiates rate-limit per IPv4/IPv6-`/64` (`handshakes_deferred`); denials (`Denied_Version`,
  `Denied_Protocol`, `Denied_Full`) count in `handshakes_refused`, silent drops in
  `handshakes_dropped`. Server traffic waits until client sends a sealed data datagram
  (`Connect_Timeout` otherwise).
- **Sealing & roaming:** Mandatory AEGIS-128L (AES-NI or portable) using split keys, 64-bit
  sequence nonce, and type/seq/slot AAD (rekey every `REKEY_INTERVAL`; handshake uses keyed XXH3).
  Missing OS CSPRNG fails `host_init` (`security`) and `invite_key`. Forward secrecy via `ee`;
  ephemeral `s` stays in RAM. Authentic newer data datagram from a new address roams the connection
  (WireGuard-style).
- **Invitations (`net/invite.odin`):** `invite_make` packs LAN (`address_lan`) + mapped IPv4
  endpoints; `invite_encode` outputs unpadded Base64url with version, endpoints, public key,
  secret, and CRC-16 (`invite_decode` -> `host_connect`).
- **Acks & loss:** Data headers carry Elias-gamma ack runs up to `ACK_WINDOW` (from `ack_known`)
  plus newest-received timestamp for RTT. Ack within `ACK_DELAY`, immediately every `ACK_EVERY`
  reliable/late packets. RACK/QUIC loss: `REORDER_COUNT` newer packets acked AND elapsed >
  `loss_delay`; spurious losses undo rate impact and widen window. Late in-window packets take
  only safe payloads (reliable game chunks, ordered game messages, newer server inputs; never
  server time, objects, or library channels) and are acked only if nothing was skipped.
- **Pacing & congestion:** Token bucket (`send_burst` = 1 tick, max `RECORD_WINDOW` in-flight,
  keepalive probe past window). Starts at `CC_START_RATE`, doubles until queue delay exceeds
  `CC_QUEUE_DELAY` + 2 packets, then drops below delivery rate and increases additively (equal
  sharing). Loss cuts rate only with queue or past `CC_OVERRUN_SHARE`; floor `CC_MIN_RATE`.
- **Close:** `host_disconnect` sends `Disconnect_Reason` (`host.odin`); silence -> `Timeout`,
  corrupt authentic packet -> `Protocol_Error`.

## Channels

Game channels (`Host_Desc.channels`, matching at both ends) use `message_send` and `Message`.
Datagram priority: library channels -> unreliable/sequenced -> reliable game channels round-robin
(leaving half a datagram while objects wait).

- **`Unreliable` / `Sequenced`:** Single send; `Sequenced` overwrites unsent queued message.
- **`Reliable`:** Byte stream sliced into chunks up to `chunk_longest` (fits beside max
  clock/input + `ACK_KEPT` ack bits so resends always fit). Zero-copy ring queue holds bytes until
  acked. `message_send` returns `Full` if any target lacks `Connection_Stats.queue_free`; pass
  `sent: ^int` for unbounded single-peer streaming. Messages `<= PIECE_BYTES` arrive whole; larger
  arrive in `Command.more` pieces.
- **Window & flow control:** Congestion-controlled window bounded by `queue_bytes`
  (`channel_chunks`, up to `MAX_WINDOW`); losses resend ahead of new chunks without shrinking
  window. Command-buffer pressure pauses socket reads before acking. Library channels return `Full`
  instead of dropping (`Reliable_Overflow` only if a message cannot ever fit).

```odin
sent := 0
for sent < len(payload) {
    if wire.message_send(&host, conn, 0, payload, &sent) == .Full {break}
}
```

## Protocol and descriptors

Register fragments, events, and input in identical order on both ends, then `protocol_seal` (fixes
handshake hash; reserves `TYPE_CAPACITY` types and `TYPE_LEAVES` leaves).

- **Fragments & composition:** `fragment_register` takes a `serial.Schema` type and
  `Fragment_Condition` (`All`, `Owner`, `Not_Owner`). `type_compose` builds/reuses an object type
  from a `[]Fragment_Id` list (sent on creation so ends need not agree on `Type_Id` order). Only
  server `Front` and client `Back` compose. `type_register` pre-composes before seal.
- **Field encoding:** Non-`local` fields map via tags (`bits`, `min`/`max`, `precision`, `text`).
  Byte arrays/`text`/raw quats pack 4 bytes/word (trimmed trailing zeros; delta sends changed
  span). `base.Entity` travels as network `Object` (`object_bind` resolves on client; missing
  targets stay pending in `object_references_pending`, non-replicated travel as `UNREPLICATED`).
- **State & masks:** Quantized state is `[]u32` (max `MAX_STATE_WORDS`), identical across peers,
  with a 64-bit change mask (units share bits within a fragment if >64, never across audiences).
  Any single change bit must fit in `MAX_STATE_BYTES`.
- **`Collection(T, capacity)`:** Fixed `{id, value}` slots (id 0 = empty, no alloc/shift); edits
  dirty only their change group.
- **Re-typing (`object_retype`):** Changes a live object's fragment list with full state, drops
  baselines, bumps epoch, and delivers `Object_Created` with `Command.retyped=true` keeping client
  bindings.
- **Large states (`Object_Type.large`):** States exceeding `MAX_STATE_BYTES` split across mask bits
  (`state_fit`, max 1 datagram/update, no baseline per partial). `event_register`/`input_register`
  use the same descriptors.

```odin
proto: wire.Protocol
wire.protocol_init(&proto)
defer wire.protocol_destroy(&proto)
frag_id, _ := wire.fragment_register(&proto, "Pose", {schema=&schema, type=pose_ti})
_, _ = wire.protocol_seal(&proto)
type_id, _ := wire.type_compose(&proto, {frag_id})
```

## Replication

- **Server objects:** `object_create` returns `Object` (shared index+gen; `Full` explained by
  `object_room`). Update via `object_mark_dirty`, `poll`, or `object_write`. `poll_interval`
  staggers object turns across ticks (`object_poll_due`). `object_set_dormant` pauses reads;
  `object_destroy` recycles slots after all peers confirm; `object_set_radius` skips grid rebuild.
- **Links & deltas:** Per-(conn, object) link goes `Pending_Create -> Creating -> Created ->
  Pending_Destroy -> Destroying` (no updates before create ack). Updates delta against active
  baseline; every `baseline_interval` ticks (<0 disables) requests a new shared refcounted
  baseline (tagged with link request count to ignore stale acks). Lost packets re-dirty fields and
  discard requested baselines.
- **Scope (`filter_interval` staggered):** `Always`, `Owner`, `None`, or `Spatial` (persistent
  `base.Hash_Map` grid around `connection_set_view`, with `leave_margin` + `hysteresis`).
  - *Visibility bits:* `Object_Desc.visibility` / `object_set_visibility` vs
    `connection_set_visibility` (inherited by children).
  - *Parent:* Child follows parent scope and spawns after it.
  - *Groups:* Up to `OBJECT_GROUPS` IDs in `1..Replication_Desc.groups` (`object_set_groups` vs
    `connection_set_group`/`connection_clear_groups`); single link across overlapping groups,
    immediate exit without hysteresis.
  - *Hold:* `connection_hold` / `Host_Desc.hold` hides all objects and non-`Held` events.
  - Re-entering scope before destroy leaves keeps replica and sends full state; after, recreates.
- **Priority & memory:** `f64` priority accumulators (2x owner, distance-attenuated) pack top
  `max_updates` up to `min(budget_bytes, tokens)` (`budget_starved` on overflow). Compacting block
  pools hold `state_words` and `baseline_words` (pool exhaustion: `baseline_failures` on server,
  `Capacity` disconnect on client).
- **Client replicas:** `Object_Created`, `Object_Updated`, `Object_Destroyed` (`ended`).
  `object_read` writes changed (or masked) fields. `object_pack` + `object_binding_revision`
  re-resolve pending references without resend.

## Events

`event_send(h, event, object, &payload, conn)` fans out from server (conn 0 = peers seeing object,
or all if object 0) or client (`From_Client`; `Owner_Only` verifies owner). `Reliable` uses system
reliable channel (`RELIABLE_EVENT_MAX_BYTES`); unreliable fits in `EVENT_MAX_BYTES`; both capped at
`MAX_STATE_WORDS`. Only `Held` reaches held connections. Server events carry send tick and set
`LINK_TICK` so the next update guarantees full tick state (`Command.complete`). Early reliable
events buffer up to 5 s awaiting replica creation. Read with `event_read`.

## Authority

- **`Server`:** Server simulates; owner gets `Role.Predicted`, others `Role.Shown`.
- **`Lent`:** Client calls `authority_request` (`Authority_Requested`, or auto-granted with
  `auto_authority`); server calls `authority_grant` (0 reclaims). Holder receives `Role.Held` and
  uploads state (`Object_Updated` with sender conn on server, replicated to non-holders). Holder
  changes bump epoch; `lease_ticks` silence, `authority_release`, or disconnect returns authority
  (`Authority_Changed`).
- **`Each`:** Replicates creation + initial state once to in-scope clients; may destroy same tick.

## Time and inputs

- Server datagrams carry tick, `clock_set(h, paused, scale)` (`Clock.paused`/`Clock.scale`), and
  client input margin. Client estimates `Clock.server` (10% smoothing, >30 tick jump) and targets
  `RTT/2 + 2*jitter + input_lead + bias - Clock.input_delay` (0.5 s smoothing).
- **Input delay (`Replication_Desc.input_delay`):** Delay covers RTT up to `cover` (at least
  `min`), prediction covers next `predict`, then delay up to `INPUT_DELAY_MAX` (whole-tick steps).
- **`clock_advance(h, now, local)`:** Returns `shift` (syncs once, then forward-only >30 tick
  `Clock.jumps` — **never backwards**) and `dilation` (clamped ±0.1; -1 before server reply).
- **Display time (`Clock.display`):** `RTT/2 + 2*jitter + interpolation_delay` behind server; ±0.1
  dilation, forward-only jumps (`clock_interpolation_tick(h, tick)`).
- **Inputs & history:** `input_submit(h, tick, &in)` repeats up to `input_redundancy` delta-encoded
  unacked inputs; `input_take(h, conn, tick, &out)` yields `Fresh`, `Repeated`, or `None`.
  `history_seconds` converts to ticks (`host_history`, cap `HISTORY_MAX_SECONDS`; mismatch
  disconnects `Capacity`); server buffers early inputs up to history ahead (`inputs_early`).

## Smoothing and interpolation (`interpolation.odin`)

- **`Smoothing`:** Decays visual pose error without touching simulated state (snaps past
  `snap_distance`); preserves slowest active half-life until decayed.
- **`Interpolation`:** Per-object tick snapshot ring; `interpolation_sample` returns `Between`,
  `Before`, or `After` (+ elapsed); `interpolation_entry` iterates oldest-first;
  `interpolation_spacing` tracks arrival cadence.

## Known limits

- Route RTT increases look like queues until the minimum window expires; shallow buffers drop
  packets until losses pass `CC_OVERRUN_SHARE`.
- Late datagrams with any skipped payload are not acked, triggering redundant reliable resends
  (safely deduplicated) and dropping their stale state/unreliable data.
- `Object_Type.large` updates assemble across multiple datagrams, exposing partial field arrival.
- `object_read` writes zero for unbound entity references; direct `net` users must re-read on
  binding changes.
- Delegated authority has no explicit reject message (observed via role); holder state travels
  whole without baselines.
