# Networking: current behavior

Descriptors, defaults and statistics (`Host_Desc`, `Replication_Desc`, `Object_Desc`,
`Channel_Desc`, `Sim_Conditions`, `Clock`, `Host_Stats`) are commented in `net/`.

## Bitstream (`std/serial/bitstream.odin`)

- `Bit_Writer` and `Bit_Reader` work over a `[]u8`, least significant bit first, one 64-bit word at
  a time. A writer with no room sets `overflow` and ignores what follows;
  `bit_writer_init_measure` creates one that only counts bits, and a copy of the writer taken
  beforehand serves to undo what was written afterwards.
- A reader asked for more than it has sets `error` and returns zeros: it never reads outside the
  buffer. An integer with a range outside the range is an error.
- Values: single bits, bool, ranged integers, varuint and zigzag varint, raw floats or floats by
  range and precision, octahedral unit vectors, smallest-three quaternions, and bytes and strings
  with a length. `quantize_*`/`dequantize_*` do the conversions without a stream.

## Transport

`Transport` is two non-blocking procedures, `send` and `receive`; `PACKET_BYTES` is the largest
datagram.

- **`Udp`**: a non-blocking UDP socket from `core:net` (port 0: the system chooses). Bound to
  `address_any6` it is dual-stack: it turns off `IPV6_V6ONLY` before the bind (`udp_dual_stack`, one
  signature per system) and receives both IPv6 and IPv4 peers. An IPv4 peer arrives as
  `::ffff:a.b.c.d` and `address_from_endpoint` returns it as IPv4; sending to it from that socket
  maps it again.
- **Names**: `resolve_start` resolves in its own thread, `resolve_poll` answers without waiting
  (IPv6 first) and `resolve_end` releases the thread. A literal address does not query the
  resolver; `address_parse` does not accept host names.
- **`Sim_Network`**: an in-memory network with a seed, deterministic and suitable for several
  threads; time only advances with `sim_network_advance`. Tests use it and it serves to play in
  one process. `sim_endpoint_conditions` sets what the sends of an endpoint suffer, including a
  bandwidth-limited link with its queue.
- **`Conditioner`**: a transport over another (a `Udp`) that applies the same `Sim_Conditions` to
  what it sends and to what it receives, so the RTT is twice `latency`. It stores datagrams in
  preallocated queues and drops what does not fit (`dropped_full`). It serves to play in two
  processes over a link worse than the real one.

## Host: two halves

The [automatic port opening](port-mapping.md) obtains candidate endpoints without blocking the
frame; `net.Host` is what verifies and establishes a real connection with its handshake.

A `Host` is a server or a client with one connection, and must not be moved after `host_init`. A
`Host_Desc` that `host_init` rejects with `Invalid` leaves in `Host.refused` the field (its path,
like `replication.hysteresis`) and the values it admits.

- **Simulation half**: what the game calls; each call adds an operation to the frame being
  prepared. `host_publish(h,tick)` quantizes the dirty objects or those on their turn, closes the
  frame and queues it; `host_poll(h)` delivers the received commands (valid until the next one)
  and updates statistics, replicas, the input buffer and the clock.
- **Network half**: `host_update(h,now)` in the calling thread, or `worker_start(h)` in its own
  thread. It applies the frames, receives, evaluates scope, packs and sends. It never reads game
  memory: the frame carries copies of the quantized state.
- The two halves only touch when swapping buffers under a mutex, with preallocated frames and
  command buffers. If the network falls behind, the frame keeps filling and goes out with the next
  publication (`publish_stalls`); if the command buffer has no reserve for what one datagram can
  produce, reading stops until the next `host_poll` (`receive_stalls`).
- Order of a tick: `host_poll` → simulate → `host_publish(tick)` → `host_update(now)` (without a
  worker).

## Connections

- **Four-datagram handshake, always sealed.** The client's request and response are padded.
  - *Request*: the client salt, to every address `host_connect` got at once: one, or the two of
    an invitation. The client proves itself to each that answers and goes on with the one that
    accepts; answers from any other address are ignored. A denial or another version ends the
    attempt once every candidate gave one: the other may be the host while this one is another
    machine at a private address of the client's own network.
  - *Challenge*: a SipHash cookie of the address, the salt and the
    time, the server's version and its lasting X25519 key; every request gets it and the server
    stores nothing.
  - *Response*: the cookie, the protocol hash, the client's key for the attempt and its proof,
    sealed with a key from the exchange of that key with the server's lasting one and the
    invitation.
  - *Accepted*: the server's key for the connection and, sealed with the session keys, its salt,
    object capacity, history and the slot of the connection.
  - Nothing but the challenge answers an address that has not returned a valid cookie, and
    nothing at all a proof that does not open (a wrong invitation): both count in
    `handshakes_dropped`. Denials (`Denied_Protocol`, `Denied_Full`) go only to a returned cookie,
    and `Denied_Full` only to a proof that opened; they count in `handshakes_refused`. The idea
    is netcode's: answer only when necessary, and deny only a request that passed every check
    ([standard](https://raw.githubusercontent.com/mas-bandwidth/netcode/main/STANDARD.md)).
  - A wrong proof costs its address (the IP without the port, an IPv6 /64): a few back to back,
    then one per interval; what comes sooner is put off before the key exchange
    (`handshakes_deferred`). The allowance is a token bucket kept as one time per address in a
    fixed table of sets; a full set gives its slot that frees soonest to the newcomer, so a crowd
    of guessers never shuts out who brings the invitation, which joins with no added round trip.
- **Format.** Every datagram starts with a type byte. The handshake ends in an XXH3 checksum keyed
  with `protocol_id`, which only filters strays; data ends in the ChaCha20-Poly1305 tag, with the
  type, sequence and the slot of the connection at the receiver as associated data. The protocol
  hash includes fragments, events, input, channels and `TRANSPORT_VERSION`, which rises when the
  format of the handshake or of data datagrams changes.
- **Roaming.** A data datagram from an address no connection has goes to the connection of the
  slot it names; if it opens under that key and is newer than any the connection accepted, the
  connection moves to that address, as WireGuard roams: a router that changes the port, or a
  switch of network, loses nothing and costs no round trip. A forged datagram does not open, and
  one replayed from elsewhere is not newer, so neither moves a connection.
- **Sealing** (`net/secure.odin`, only with `core:crypto`; there is no unsealed mode): the session
  keys come from HKDF-SHA256 over the exchange of the two keys made for the connection and that of
  the client's key with the server's lasting one, salted with the key of the invitation. The
  client takes the server's key from the challenge, so only an active attacker on the path could
  pose as the server, and only knowing the invitation. One key per direction, with the 64-bit
  sequence as nonce, which every `REKEY_INTERVAL` datagrams is derived from the previous one; the
  receiver's only advances when a datagram with the new one turns out authentic. A tampered,
  truncated, repeated or older-than-the-last-accepted datagram is discarded. A system without
  secure random bytes cannot make a host (`host_init` refuses `invite`) nor an invitation
  (`invite_token` is not ok).
- **Two ways in.** By address: a server whose `Host_Desc.invite` is zero admits anyone who reaches
  it, and the client calls `host_connect` with that address. By invitation: `Host_Desc.invite` is
  in every key, so both ends must have the same one, and a client without it times out with
  `Connect_Timeout`. It is a 64-bit secret so that whoever received the code gets in, not a
  credential: nobody can try invitations from the server's answers, and neither the guesses the
  server lets through nor whoever poses as the server on the path, trying them against the
  client's proof offline, get near it.
- **Invitation codes** (`net/invite.odin`): the host says where it is, as ICE gathers a host and a
  reflexive candidate: `invite_make` takes its address on its network (`address_lan`) and, once
  the router mapped its port, the mapped one; `invite_encode` writes both with the token and a
  CRC-15 in Crockford base32, tolerant of case, separators and confusable characters, and the
  client passes both addresses of `invite_decode` to `host_connect`. On the host's network the LAN
  address answers; from outside, the mapped one; a router that does not loop its public address
  back does not matter, and the client asks no other address.
- **Amplification.** The Challenge is smaller than the padded request, and the server does X25519
  exchanges (two per accepted client, one per refused proof) only for whoever returned the cookie,
  `handshakes_per_update` at a time per update.
- **Acks.** Each data datagram carries its sequence, the last one received and a variable number of
  ack bits: from what the other end might not have resolved when reading the last ack this end
  received (`ack_known`), capped by `ACK_WINDOW`. Everything the sender has in flight arrives this
  way with its real fate, also after a receiver stall.
  - A datagram older than the last accepted is not acked: when a later one is acked, the fate of
    the earlier ones is final and what was in a lost one is resent.
  - If it arrives late (at most `LATE_WINDOW` behind) and had not been received, only what is safe
    out of order is taken (`packets_late`): the chunks of the game's reliable channels, which
    assemble only once, and on the server the inputs of ticks after the last received.
  - Skipped are unreliable and sequenced messages, the server time and the objects, because what
    arrived later is newer; and the library channels (reliable events and replication messages),
    because they talk about objects whose state in that datagram is discarded and delivering them
    earlier would change the order in which the game applies them.
  - With nothing to say it is sent anyway to ack, keep the connection alive or probe a queue with
    no ack.
- **Send limit**: a token bucket with the connection's rate that stores at most one tick of rate
  (`send_burst`), so a network half that updates more often than the tick spreads the datagrams.
  The object budget of each send is the lesser of `budget_bytes` and the tokens: replication
  follows the rate.
- **Congestion**: AIMD driven by the queue (the mean RTT of the interval above the lowest of the
  recent window), not by loss, to cut back before the path buffer overflows; a link that loses at
  random without a queue keeps its rate, which never drops below `min_send_rate`.
- **Close**: `host_disconnect` tells the other end with its reason; silence closes with `Timeout`,
  and an authentic datagram that cannot be interpreted, with `Protocol_Error`. The reasons for
  rejection and closing are `Disconnect_Reason` (`host.odin`).

## Channels

Game channels in `Host_Desc.channels`, the same at both ends; `message_send` and the `Message`
command. `budget` limits the bytes of a channel per update.

- `Unreliable` is sent once; `Sequenced` too, and a message that is still waiting is replaced by
  the next one.
- `Reliable` is resent until its ack, delivered in order and cut into chunks as the window draws
  them from the queue: the one fragmentation of the transport. `message_send` returns `Full` and
  sends nothing if the message does not fit in the queue of some destination connection (it knows
  from `Connection_Stats.queue_free` of the last `host_poll` minus what was queued since): the
  sender retries after `host_poll`. With `sent`, a message to one connection streams: each call
  queues what has room, and the channel takes nothing else until it is in, so a message has no
  size limit. A message longer than `PIECE_BYTES` arrives in pieces (`Command.more`), which the
  receiver joins; the library's own reliable channel takes only whole messages.
- **Window.** The chunks a reliable channel keeps in flight grow by what the path acknowledges
  (`channel_window`, each congestion interval), so they double each round trip while they hold the
  channel back. Twice what the connection's rate sends in a round trip bounds them,
  so congestion control and `send_rate` decide what a stream takes, and `Channel_Desc.window`, a
  power of two the same at both ends, is the most a channel holds and receives ahead. A loss does
  not shrink the window: its resend waits a round trip with the chunks after it acknowledged.
- While objects wait for the update, the reliable game channels leave half of each datagram to
  them: a part that streams does not starve the state.
- The library channels count their queue the same way: `event_send` of a `Reliable` event and the
  authority requests return `Full` and send nothing if they do not fit in the queue of some
  connection they may go to, and the sender retries. The connection is not closed;
  `Reliable_Overflow` is left for a reliable message that would not fit anyway, instead of losing
  it.

## Protocol and descriptors

A `Protocol` registers its fragments, events and input, is sealed with `protocol_seal` and from
then on only grows in types. The hash the ends compare is that of what was registered; both
register the same in the same order.

- `fragment_register` describes a fragment: a `serial.Schema` type with a condition (`All`,
  `Owner`, `Not_Owner`); its leaves are left as a template, with the owner field of each bit.
- An object type is a list of fragments: `type_compose` gives the already composed one or builds a
  new one from the templates. An object's creation carries its list (`kinds_write`) and whoever
  reads it composes the type the first time it sees it: there is no need to agree on type ids or
  order.
- Only one half of the host composes: on the server the simulation one, when creating the object;
  on the client the network one, when reading the creation. The other half reads a type after the
  command or operation that names it, and types do not move: sealing reserves `TYPE_CAPACITY`
  types and `TYPE_LEAVES` leaves. `type_register` registers and composes before sealing (tests).
- Each replicated field (without `local`) produces leaves with a serializer according to its type
  and its tags (`bits`, `min`/`max`, `precision`, `text`; an array inherits those of its field).
  - An array of one-byte values (a `text` too, and a `rotation` sent whole) is one field of its
    bytes, packed four to a word: whole it travels up to its last nonzero byte, and as a delta the
    run from the first to the last byte that changed. Its bytes must fit a part of a state.
  - A `base.Entity` travels as the network object of that game id, and the client receives its own
    id (`object_bind`). If the referenced replica does not exist yet it reads zero and the
    reference stays pending (`object_references_pending`); an entity that the sender does not
    replicate travels as `UNREPLICATED`, pending forever.
- The quantized state of an object is an array of 32-bit words (up to `MAX_STATE_WORDS`), the same
  for all connections. Each field and each entry of an array of structs has a bit in the 64-bit
  change mask; with more units they share bits within their fragment, never across fragments with
  different audiences. A fragment is not registered nor a type composed whose one-bit fields do
  not fit in a datagram (`MAX_STATE_BYTES`).
- `Collection(T, capacity)` is a flat collection of `{id,value}` slots with stable identity (id
  zero is empty): it does not shift entries, keeps no pointers and does not allocate, and
  inserting, changing or removing an entry dirties only its change group. The game declares its
  ids and writes the row of its component with the normal `core` operations.

**Re-typing.** `object_retype` gives a live object another type (another list of fragments) with
its whole state: the object, its parent, owner, scope and events go on.

- Each link that has the replica takes the creation again, which carries the list; the client
  reads the creation of a live object of the same generation as a re-typing and says so
  (`Command.retyped`), keeping what the game bound the replica to. A creation in flight is
  followed by the new one once it is acked, and a link that was leaving takes it if it returns.
- The baselines of the object are dropped: they are of the words of the type before.
- It bumps the epoch, and the server reads what an older epoch still sends (a client that held
  the object) with the type before, to drop it.

**Large states** (`Object_Type.large`, whose maximum encoding exceeds `MAX_STATE_BYTES`):

- They are sent in parts of whole mask bits, from the lowest to the highest, according to the
  bound of each bit (`state_fit`). What did not fit stays dirty and the ack by mask resends what is
  lost. A part does not create a baseline (the sender would store fields the receiver did not
  receive).
- The creation carries what fits; the rest follows as updates when it is acked, and meanwhile the
  replica has those fields at zero. A large state takes at most one datagram per update and does
  not hold back small ones. The client with authority splits what it sends the same way.
- `event_register` and `input_register` describe an event and the input in the same way.

## Replication

**Objects (server).**

- `object_create` returns an `Object` (index and generation, the same on the server and clients).
  State is updated with `object_mark_dirty` (reread at the next publication), `poll` (reread on
  each turn) or `object_write` (read now, without storing the pointer).
- **Turns.** An object has a turn every `poll_interval` ticks: the tick whose remainder by the
  interval is its phase. Objects with the same interval take consecutive phases, so their reads
  are spread across ticks, like Iris's `ObjectPollFrequencyLimiter`. An object with `poll` is only
  reread on its turn; a mark from `object_mark_dirty` does not wait. Whoever writes with
  `object_write` follows the same turns with `object_poll_due`
  ([multiplayer](multiplayer.md#the-tick)).
- `object_set_dormant` stops reading the object and on waking it what changed is sent;
  `object_destroy` frees the slot when all connections confirmed.
- `object_create` returns `Full` without room in `max_objects`, in `state_words` or in the frame
  being prepared (which fits after the next `host_publish`); `object_room` says which is missing.
- `object_set_radius` changes the relevance radius without rebuilding the spatial grid.

**Canonical state and links.** The network half compares the received words with the canonical
state and obtains the change mask. Per connection and object there is a link with the dirty fields
and up to two baselines (the active and the requested), each in a slot of the receiver, which goes
through `Pending_Create → Creating → Created → Pending_Destroy → Destroying`. No updates of an
object are sent until its creation was acked.

**Deltas.**

- An update carries the dirty fields; with an active baseline, each leaf as a difference from the
  baseline's. Every `baseline_interval` ticks an update asks the receiver to store the result as a
  new baseline and also carries everything changed since the active one; when acked it becomes the
  active one. The creation stores the first; a negative interval disables deltas.
- A baseline is a block of the object with a count of the links that have it as active or
  requested: all those that take it share it while the object keeps that state, and it is freed
  with the last. With few blocks, a link takes its own as soon as its turn comes; with several,
  links wait to share it (a block with the current state, the tick of the object's phase or a
  whole interval of lag), so blocks do not grow with connections nor with the spread of their
  RTTs.
- **Loss.** What was in a lost datagram becomes dirty again (or pending creation or destruction)
  and the baseline it requested is discarded. Each baseline request carries a count of the link,
  and its ack or loss only resolve it if it matches. A link that forgets its baselines (change of
  owner or role, a moment out of scope) requests slot 0 again, and the ack of an earlier update
  that requested that slot does not activate the new block.

**Scope** (every `filter_interval` ticks per connection, staggered):

- `Always`, `Owner` or `None` (no connection: in `multiplayer`, the object whose replicated
  ancestor does not have an object yet).
- `Spatial`: by distance to the view of `connection_set_view`; with no view it sees nothing, and
  with a negative radius the view reaches everyone. The persistent grid processes only additions,
  removals, and filter and cell changes, with slots reserved at start, and its cell table (a
  `base.Hash_Map`, without tombstones) does not degrade even if objects traverse new cells all
  session long.
- **Visibility bits**, like collision layers: an object with bits (`Object_Desc.visibility`,
  `object_set_visibility`) is seen, of the connections its filter and its groups let, only by
  those that share one (`connection_set_visibility`), and so its children. An object with none
  asks for none; a connection that arrives, even in another's slot, has none.
- A spatial object that is already seen keeps being seen until `leave_margin` beyond the view's
  reach and, past that margin, `hysteresis` more evaluations.
- An object with a parent follows its parent's scope and is never created before it.
- **Groups.** An object with groups (`Object_Desc.groups` or `object_set_groups`, up to
  `OBJECT_GROUPS`, from 1 to `Replication_Desc.groups`; 0: none) is seen only by a connection that
  has one of them (`connection_set_group`; `connection_clear_groups` removes all of them),
  whatever its filter, and the same goes for what follows it as a parent; with none it leaves at
  once, without hysteresis. It is a single link per connection, whether it has one or several of
  its groups: each change goes out once. A group is a part of the world that the connection may
  not have loaded: a section in `multiplayer`, and what is in several overlapping ones belongs to
  each. A connection that arrives has none, and a change evaluates its scope on the next update.
- A held connection (`connection_hold(h,connection,true)`) sees no object, whatever its filter,
  and only hears `Held` events, until it is released: what it saw leaves its scope.
  `Host_Desc.hold` holds each connection that arrives. Holding or releasing evaluates its scope on
  the next update, also with the server clock paused.
- Leaving scope sets the link to destroy, with its priority, and forgets its baselines: the
  destruction goes out with the next update or when its turn comes.
  - If the object returns before it goes out, the replica is kept and receives the role and the
    full state as an update, without an active baseline.
  - If it returns afterwards, it is created again with the full state.

**Priority and budget.**

- Each tick, each object with something to send adds its priority to its per-connection
  accumulator (double if the connection is the owner, less the farther from the view). The
  accumulator is an `f64`, ordered by its bits with the object index as tiebreaker: a finite
  priority does not overflow it and the order is the same at any scale.
- The `max_updates` highest accumulators are written until `budget_bytes` or the send limit is
  exhausted; being sent sets the accumulator to zero. An object that does not fit keeps its
  accumulator and the small ones that follow it fill the rest, until several in a row do not fit
  either; if another datagram follows, it starts with it. `budget_starved` counts the ticks in
  which something was left waiting.

**Memory.**

- States and baselines live in pools of blocks with an id (`state_words`, `baseline_words`) that
  reuse holes of the same size and, if there is no room, move the live blocks toward the start: a
  reservation fails only if the live ones and the new one do not fit. The server counts the words
  in `object_create`, which returns `Full` before the network half runs out of room.
- With no room for a baseline, the update goes against the active one or whole
  (`baseline_failures`); a client with no room for a replica closes the connection with
  `Capacity`.

**Client.**

- Replicas arrive as commands with the server tick: `Object_Created`, `Object_Updated` (mask of
  what changed and full state) and `Object_Destroyed` (`ended` says whether it ended on the server
  or only left scope). `object_read` writes into the game's structure only the changed fields, or
  those of the requested mask. On disconnect all replicas are forgotten.
- **Pending references.** `object_pack` quantizes a fragment without publishing; whoever holds
  words to apply them later rereads the pending references when `object_binding_revision` changes,
  without asking for another send. The handle's generation prevents resolving an old reference
  against a reused slot. The host republishes the fragments with references and a held source when
  the object registry changes, even if the row did not change. `multiplayer` does this tracking
  with entities ([multiplayer](multiplayer.md)).

## Events

- `event_send(h,event,object,&payload,connection)`: on the server it goes to one connection or,
  with zero, to all those that have the object (to all if the event is not about an object). On
  the client it goes to the server and requires `From_Client`.
- `Reliable` uses an internal reliable channel; the rest, an unreliable one. `Owner_Only` discards
  on the server those that do not come from the owner. Only `Held` ones reach a held connection:
  what the server says while it loads the world the connection will see.
- They arrive as an `Event` command and are read with `event_read`.
- An unreliable event encodes within `EVENT_MAX_BYTES`, a datagram; a reliable one within
  `RELIABLE_EVENT_MAX_BYTES`, which its channel cuts in chunks as for any reliable message, and
  every event within `MAX_STATE_WORDS`. `event_register` refuses one past them.
- They name their object by handle. A server event carries the tick it was sent in (the one after
  the last `host_publish`), and fanning it out about an object marks the link (`LINK_TICK`): the
  next update goes even without changes and carries every field changed since what the connection
  is known to have (`Command.complete`), so the receiver can wait for a state of that tick that a
  lost update before it cannot leave incomplete.
- A reliable event that arrives before its replica waits for it up to 5 s; one sent in the tick in
  which the object was created waits on the server for that tick's scope evaluation.

## Authority

Who simulates is a property of the object (`Object_Desc.simulation`); the role is what a
connection is for a replica.

- `Server`: the server simulates; the owner receives the `Predicted` role and the rest `Shown`.
- `Lent`: the server may lend the simulation to a connection.
  - `authority_request` arrives as `Authority_Requested`, except with `auto_authority`;
    `authority_grant` grants it or, with zero, withdraws it.
  - The holder receives the `Held` role and the full state, and publishes the state as the server
    would; the server applies it, delivers it as `Object_Updated` with the originating connection
    and replicates it to the rest, not to the holder.
  - Each change of holder advances an epoch that discards what the previous one had in flight.
    With no new state during `lease_ticks`, with `authority_release` or on disconnect, it returns
    to the server (`Authority_Changed`).
- `Each`: only the creation is replicated, with its initial state, to those that had it in scope
  at that moment; each client simulates and ends its copy. It may be destroyed in the same tick in
  which it is created.

## Time and inputs

- Ticks are numbered the same at both ends. Each server datagram carries its tick, its clock
  (paused and the scale of its ticks, set by `clock_set(h,paused,scale)` and heard by everyone at
  once) and how many ticks of input margin it has for the connection.
- Everything the client estimates about the server runs at the pace of its clock: still while
  paused, at the scale of its ticks afterwards (`Clock.paused`, `Clock.scale`).
- The client estimates the server tick (`Clock.server`, corrected 10 % per sample; the estimate
  jumps if it strays more than 30 ticks) and wants its own tick ahead: half the RTT, twice the
  jitter, `input_lead` ticks and `bias`, a slow correction according to the margin the server
  reports, less `Clock.input_delay`, the whole ticks ahead of its own it submits its input for.
  That target (`Clock.target`) is smoothed with a constant of 0.5 s.
- The input delay follows the round trip (`Replication_Desc.input_delay`, lightyear's
  `InputDelayConfig`): delay covers it up to `cover` (at least `min`), prediction the next
  `predict`, delay again the rest, up to `INPUT_DELAY_MAX`. It moves only once it is a whole tick
  off. A tick an increase skips takes the next input submitted; a tick submitted again keeps the
  first.
- The client tick is stored by whoever uses it, with a fraction (the last simulated plus what its
  time already covers of the next). `clock_advance(h,now,local)` returns:
  - `shift`: whole ticks to add to it now. On synchronizing, what puts it on the target (also
    backwards); afterwards only forward, when the unsmoothed target is more than 30 ticks ahead of
    it (`Clock.jumps`). **The client tick never goes backwards.**
  - `dilation`: how much faster than real time its ticks must run until the next call,
    proportional to the error against the target and bounded to ±0.1; -1 (none) while it has not
    heard the server. A target that falls, such as at the end of a jitter spike, keeps braking.
- Remote objects are shown at `Clock.display`, a server tick with a fraction: half the RTT, twice
  the jitter and `interpolation_delay` behind the server.
  - It advances with the client tick (without its dilation) and heads for that target with its own
    dilation of ±0.1; it jumps only forward, more than 30 ticks, and also counts in `Clock.jumps`.
    It never goes backwards.
  - `clock_interpolation_tick(h,tick)` is the server tick shown in the state left by client tick
    `tick`: one more for each tick, at a fixed distance within a frame.
- `input_submit(h,tick,&input)` (client): each datagram repeats the latest unacked inputs, up to
  `input_redundancy`, each as a difference from the previous.
- `input_take(h,connection,tick,&out)` (server) delivers the input of that tick (`Fresh`), the
  last earlier one if it did not arrive in time (`Repeated`) or zeros (`None`).
- **History.** `Replication_Desc.history_seconds` becomes ticks of `tick_rate` in `host_init`
  (`host_history`). Every ring of the past takes them and one slot more, the tick being written:
  the server keeps input up to that far ahead of the tick it published last and drops what comes
  further (`inputs_early`). The server announces its ticks in Accepted and a client takes them in
  place of its own, up to what `HISTORY_MAX_SECONDS` gives at its tick rate; more ends the
  attempt with `Capacity`.

## Smoothing and interpolation (`interpolation.odin`)

The client predicts with copies of the world and interpolates with `replica_blend`
([multiplayer](multiplayer.md)); these are the pieces of `net` it uses for that.

- **`Smoothing`** fades the difference between the displayed pose and the corrected one without
  touching the simulated state; beyond `snap_distance` it does not smooth. A correction may ask
  for its own half life (a change of timeline fades slower): the error under way fades as slowly
  as the slowest that made it up, until it is gone.
- **`Interpolation`**: ring of snapshots per tick and object. `interpolation_sample` gives the two
  that surround a tick (`Between`), the oldest (`Before`) or the newest and how much time has
  passed since it (`After`); `interpolation_entry` gives each one kept, from the oldest.
  `interpolation_spacing` gives the ticks between snapshots: a longer gap counts at once and a
  shorter one, gradually.

## Known limits

- Congestion control does not tell a queue from a path that lengthens: a route change to a higher
  RTT cuts the rate until the window forgets the previous minimum. A buffer smaller than the queue
  threshold overflows without the queue being seen, and then the rate does not drop.
- A late datagram is not acked: even though its reliable chunks were already delivered, the sender
  resends them (the receiver discards them), and its objects, unreliable messages and time are
  lost.
- A large state is built in the replica over several updates: the game sees its fields arrive in
  parts.
- `object_read` writes zero for a reference that has not been linked yet; whoever uses `net`
  directly rereads it when links change, and `Object_Desc.parent` orders creations.
- Delegated authority has no rejection message: the client learns from the role change. The state
  a holder sends travels whole, without baselines.
