---
name: mirai-networking
description: Mirai networking - the `net` package (UDP and in-memory transport, connections,
  channels, delta replication, composite types made of fragments, scope and priority, messages,
  authority, clock, inputs, rollback and the bitstream), the `multiplayer` plugin that connects it
  with the data world (session, the player's `--server`/`--connect` arguments, connection seats) and
  the `destruct_multiplayer`, `terrain_multiplayer` and `foliage_multiplayer` bridges (networked
  fractures, terrain edits and removed foliage). Use when changing `net`, when declaring replicated
  entities or `@(net_message)` messages in a game, or when changing how the client predicts and
  corrects.
---

# Mirai networking

`net` is a standalone library: it imports `std/base`, `std/math` and `std/serial`, and knows
neither the data world nor physics. A replicated object is an opaque game id plus fragments (a
`serial.Schema` type and a pointer to its bytes); its type is the list of its fragments.

- The package is `package mirai_net` (`core:net` already uses `net`); it is imported with
  `import wire "mirai:net"`. It stays in the engine: editor collaboration uses it.
- Game networking is the `multiplayer` plugin (`plugins/multiplayer/runtime`). It does not know
  physics: the two share [`core` tables](references/multiplayer.md#what-another-library-simulates).
  Fractures are replicated by the automatic `destruct_multiplayer` bridge. The player does not know
  the network: the plugin takes its own arguments from `host.Launch`.
- A granted port mapping is only a candidate endpoint; the application handshake confirms the
  real reach.

## Map

- Bitstream, transport, host, connections and security, channels, protocol and types, replication,
  events, authority, clock, rollback →
  [bitstream](references/networking.md#bitstream-stdserialbitstreamodin),
  [transport](references/networking.md#transport), [host](references/networking.md#host-two-halves),
  [connections](references/networking.md#connections),
  [channels](references/networking.md#channels),
  [protocol](references/networking.md#protocol-and-descriptors),
  [replication](references/networking.md#replication), [events](references/networking.md#events),
  [authority](references/networking.md#authority),
  [clock and inputs](references/networking.md#time-and-inputs),
  [rollback](references/networking.md#prediction-rollbackodin) and
  [known limits](references/networking.md#known-limits)
- Opening a host's UDP port (`mapping_start`, `mapping_poll`, `mapping_stop`, `mapping_close`;
  PCP, NAT-PMP, UPnP) → [API and lifecycle](references/port-mapping.md#api-and-lifecycle),
  [protocols](references/port-mapping.md#protocols) and
  [scope and limits](references/port-mapping.md#scope-and-limits)
- Replicated entities, game messages and collections, session, tick, prediction and correction,
  lent simulation, connection events →
  [what the game declares](references/multiplayer.md#what-the-game-declares),
  [networked play](references/multiplayer.md#networked-play),
  [the tick](references/multiplayer.md#the-tick),
  [delegated authority](references/multiplayer.md#delegated-authority) and
  [connection events](references/multiplayer.md#connection-events); what the network could not
  do → [problems](references/multiplayer.md#problems)
- Lag compensation (`Rewind`, `rewind_tick`, `rewind_pose`, `rewind_tolerance`) and the absolute
  look in the input → [lag compensation](references/multiplayer.md#lag-compensation)
- Replicated bodies, `core.Pose_Target` and `core.Motion` →
  [what another library simulates](references/multiplayer.md#what-another-library-simulates)
- Role of this end, replicated seats, player identity and owners per seat →
  [multiplayer.md#authority-and-players](references/multiplayer.md#authority-and-players)
- Scene change with clients, scene on connect, saving on the server →
  [multiplayer.md#scene-change](references/multiplayer.md#scene-change); sections and streaming
  with networking → [sections](references/multiplayer.md#sections)
- Pause and time scale with networking →
  [client clock](references/multiplayer.md#the-tick) and
  [time](references/networking.md#time-and-inputs)
- Player arguments (`--server`, `--dedicated`, `--connect`, `--invite`, `--status`, simulated
  network), port and exit code →
  [multiplayer.md#opening-and-closing](references/multiplayer.md#opening-and-closing); dedicated
  server → [build](../mirai-projects/references/build.md#dedicated-server)
- Replicated fractures →
  [engine-destruct.md#red](../mirai-physics/references/engine-destruct.md#network)
- Networked terrain edits (`terrain_multiplayer`: brush, check and pages, client prediction, base
  on join) → [terrain.md#red](../mirai-world/references/terrain.md#network)

## Files

- `std/serial/bitstream.odin`: `Bit_Writer`, `Bit_Reader`, `quantize_*`/`dequantize_*`.
- `net/transport.odin`: `Address`, `Transport`, `Udp`, `Sim_Network`. `net/conditioner.odin`:
  `Conditioner`.
- `net/host.odin`: `Host`, the two halves, frames, commands, worker.
- `net/peer.odin`: handshake, headers, acks, RTT, send limit. `net/secure.odin`,
  `net/invite.odin`.
- `net/channel.odin`: channels and fragmentation.
- `net/protocol.odin`: `Protocol`, fragments, composite types, descriptors, state serialization.
  `net/collection.odin`: flat collections of slots with stable identity.
- `net/replication.odin`: simulation half (objects, publishing and turns, command reading).
  `net/back.odin`: network half (canonical state, links, baselines, reader).
- `net/scope.odin`: scope (filters, spatial grid, `Custom` relevance) and priority.
  `net/event.odin`: events and authority messages.
- `net/clock.odin`: client clock, time section and inputs. `net/rollback.odin`: `Rollback`,
  `Smoothing`, `Interpolation`.
- `net/portmap*.odin`: port opening.

In `plugins/multiplayer/runtime`:

- `types.odin`: what a game declares (`Replicate`, `Net_Link`, `Net_Settings`, `Net_Events`,
  `Net_Outbox`, `Remote_Inputs`, `send`, `event_read`), `DEFAULT_PORT` and `PLAYER_NET`.
- `session.odin`, `loop.odin`: `Net_Session`, the generator catalog protocol, composite types
  (`net_type`), opening and closing, the player arguments (`launch_read`), frame functions, what
  the player prints, helpers (`is_server`, `is_client`).
- `common.odin`: the type of an entity, components by reflection, `core.Pose_Target` and messages.
  `world.odin`: the session world follows the server scene, the sections each client has, player
  identity, own messages and the clock. `authority.odin`: the role of `core.Network`, which clears
  `core.Remote` on change. `players.odin`: connection seats and owners per seat.
- `server.odin`: entities with `Replicate` as objects, their network parent (the replicated
  ancestor), publishing by row stamps in the object's turns on the host, `Custom` relevance
  requested by the game, connection inputs.
- `client.odin`: replicas, interpolation, prediction with the world copy, correction, smoothing,
  rewind and SyncTest. `history.odin`: authoritative history of predicted replicas and their
  component records.
- `rewind.odin`: lag compensation; the server remembers the poses of what has `Rewind` and gives
  the tick each client saw (`rewind_tick`, `rewind_pose`).

`plugins/destruct_multiplayer/runtime/fracture.odin` replicates fractures and
`plugins/terrain_multiplayer/runtime/terrain_multiplayer.odin`, terrain edits.

## Workflow

1. Read the section of [networking.md](references/networking.md) for the area to touch and its
   tests (`*_test.odin` next to the code).
2. Decide which half the change lives in.
   - The simulation half (`Front`, what the game calls) only adds operations to the frame.
   - The network half (`Back`, `host_update` or the worker) is the only one that touches
     connections, canonical state and sockets.
   - New data crosses as a field of `Op` or `Command`, never by pointer.
3. A change to what travels on the wire is made in the writer and the reader at once, and enters
   the protocol hash if it depends on the configuration.
4. Run the area's tests and update the reference.

## Invariants

- Networking is an own implementation in Odin: `net` implements its own UDP transport and
  replication, with no third-party networking library.
- After `host_init`, every capacity comes from `Host_Desc`/`Replication_Desc`; exhausting one
  returns `Error` or counts in the statistics. Replicated traffic, even damaged, does not
  allocate.
- **Every byte from the network is hostile.** It is read with `Bit_Reader`, which never leaves the
  buffer; every index, type, mask and length is validated before use. A datagram that cannot be
  interpreted closes the connection with `Protocol_Error`; it is never half-applied over another
  connection.
- **Datagram acks and losses are final.** Late datagrams are not acked and only allow
  [the partial delivery described in connections](references/networking.md#connections). Do not
  extend that exception without reviewing channels, links and baselines.
- **Nothing changes until it is known that the entry fits.** `entry_write` writes, checks and only
  then modifies the link; if it does not fit, it restores the writer.
- **A baseline is used only after its ack**, and the receiver stores it from the state that results
  from applying the update that requests it, which carries every field changed since the active
  baseline. Changing who a fragment is sent to (owner) invalidates the link's baselines. A server
  baseline is a block shared with the canonical state at the moment it was taken: it is taken only
  from that state and released, never written. The ack or loss of a baseline request resolves it
  only if it carries the link's current request count.
- **An object index is not reused until all connections have released the previous one**: the
  network half returns it in `Command_Buffer.released`.
- **The bound expressions of a `for i in a..<b` are evaluated on every iteration**: do not put
  bitstream reads or calls with effects there.
- **`testing.fail_now` ends the test process on Windows** without showing the error: use
  `testing.expect` and `return`.
- **A correction restores the world: everything the network writes into it must be repeatable.**
  What comes back is the copy of the `World` that the client stores at every tick; state outside it
  (`host` storages, one per world: the session, `Destruct_Net`) does not come back, and keeps what
  it needs to reapply (the destruction journal with its `sequence`, the last received state).
- **The network does not call the library that simulates nor write its state.** It writes
  `core.Pose_Target`, `core.Remote`, `core.Network`, the `core.Disabled` of replicas
  ([switched off](references/multiplayer.md#what-the-game-declares)) and the replicated
  components, and reads `core.Motion`; whoever owns the `Transform` takes the target at the start
  of the tick. What it places outside the loop (a correction) is applied with the next tick, and
  its records store the server state, not what physics has not yet taken.
- **The protocol comes from the generator catalog.** Fragments (pose, motion, driver, each
  replicated component) and messages are registered in their order, the same at both ends of a
  build; a type is the list of fragments its creation carries. Nothing depends on the order in
  which a game registers something.
- **What travels from a driven body is its `Move_Input`**, not the actions of its seat, which go
  only to the server. A client sends actions, never devices: contexts, bindings and rebinding are
  evaluated on the client, and the server derives the edges. Locomotion runs the same at both ends
  from the `Move_Input`.
- **The network does not destroy player bodies.** When a connection leaves, its seat waits for its
  player or goes away; the body is destroyed by whoever gave it (`spawn`, through `Seat_Body`) or
  by the game.
- **No session handle survives a scene that replaces the world.** The session detects it through
  `scene.Scene_Root.changes` at the start of each network step: server objects are unbound and
  finish, the client's replicas and history are forgotten, and a client does not see the new world
  until it says it is in it.
- **What the game sends belongs to a world.** A held connection hears only `Held` events, and each
  end discards game messages from another world that is not its own; what a library keeps outside
  the `World` (`Destruct_Net`) is forgotten on scene change.
- **A player is the hash of their secret.** The server never takes as a player something the
  client presents as is nor derives it from a name; a connection presents only one.
- **The network does not write `core.Clock`:** a client requests the server's pause and scale
  through `core.Clock_Requests`.
- **The past is sized in seconds, by the server.** Every ring of the past (the client's copies and
  records, the server's input and lag compensation) is `history_seconds` at the tick rate plus the
  tick being written, made when the session opens or connects; none is a fixed count of ticks.
- **A correction is proportional to what is wrong.**
  - Each state is compared at its own tick and with per-field tolerances.
  - Only the critical (what is own and what shared a group with what the client drives)
    resimulates, within the `max_resimulate` ticks of the frame and the `resimulate_budget`
    budget.
  - The rest, and what does not fit, is closed in the present without teleporting: velocity at
    once and pose over the following ticks (`correction_time`).
  - Whoever moves a predicted replica outside the tick (`replica_put`, the closing of an error)
    corrects the later records (`records_shift`, what is left to close in the new ones); otherwise
    the next state finds the same error again.
  - What a library knows has changed in already simulated ticks comes back through `rewind`, not
    on its own.
- **The client tick never goes backwards** once synchronized: the clock corrects with a bounded
  dilation and only jumps forward; the display time of remote objects does not either
  ([time](references/networking.md#time-and-inputs)).
- **Rollback sets `core.Time.resimulating` and sinks respect it.** The clock comes back with the
  copy and the repeated ticks (`host.app_tick_replay`) advance it to the present;
  `core.Frame_Time` is not copied, so rollback neither stores nor restores anything of the clock.
  A repeated tick sees the content it saw the first time (the generation the ring keeps).
  `send` does not queue, `Net_Outbox` is not copied with the world (what it holds is not lost) and
  `net_tick_tail` neither publishes nor sends: messages are not repeated unless the game asks; the
  rest follows the rule of [`Time`](../mirai-core/references/core.md#core-storages)
  ([correction](references/multiplayer.md#the-tick)).
- In `bitstream.odin` and its test only `Bit_`, `bit_`, `quantize_` and `dequantize_` symbols are
  defined: the rest of `std/serial` belongs to another area.

## Verification

- `mirai test net [test...]`, `mirai test std/serial` (bitstream) and
  `mirai test plugins/multiplayer/runtime`. Run the `*_test.odin` of the touched area: `address`,
  `connection`, `secure`, `invite`, `congestion`, `conditioner`, `replication`,
  `descriptor_boundary`, `large_state`, `collection`, `references`, `convergence`, `grid`, `scope`,
  `authority`, `prediction`, `clock`, `worker`, `baseline` (pools and shared baselines),
  `packing` (packet fill) and `portmap` ([port-mapping](references/port-mapping.md)).
- `test_baselines_match` and `test_baselines_counted` check that each active baseline is the one
  the client stored and that the counts of shared ones are exact; the convergence tests compare
  the words of each replica with the server's (`test_replica_matches`).
- `multiplayer`: [multiplayer verification](references/multiplayer.md#verification).
- They are deterministic (`Sim_Network` with a fixed seed), except those that open UDP sockets on
  `127.0.0.1`.
- Optional benchmarks: the server with 64 clients,
  `mirai test net server_with_64_clients_and_2000_objects --release -define:NET_BENCHMARK=true`,
  and the frames of a client with interpolated replicas,
  `mirai test plugins/multiplayer/runtime bench_client_frames -define:NET_CLIENT_BENCH=true`.
