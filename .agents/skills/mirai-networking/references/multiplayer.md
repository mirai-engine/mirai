# Plugin `multiplayer`

Connects the data world with the [`net`](networking.md) library: authoritative server, client-side
prediction and rollback. It is the `multiplayer` plugin (`package multiplayer` in
`plugins/multiplayer/runtime`); import it with `import multiplayer "plugins:multiplayer/runtime"`
and the low-level package as `wire "mirai:net"`. It knows nothing about physics: it talks to it
through [`core` tables](#what-another-library-simulates). Types, settings and their defaults
(`Replicate`, `Net_Settings`, `Net_Events`) are commented in `types.odin`.

Its functions wrap the tick. Its session (`Net_Session`, with its socket and port) is
`@(storage,host,by_world)`: one per `World`, held outside it. A correction restores the `World` and
keeps the session that is talking; a world made by copy opens its own, so several worlds of a
process (the editor's runs) serve or join different games. The session closes when its world is
released; from outside the loop, `host.app_world_storage(app, world, Net_Session)` gives the one of
a world.

## What the game declares

Nothing is registered: the game declares with attributes and components, and the protocol comes out
of the catalog the generator builds, identical at both ends of a build (the hash they compare when
connecting confirms it).

**Entities.** An entity with `Replicate` exists on the server and on the clients that must see it.
Usually its prefab carries it: everything that appears from that prefab is replicated.

- What travels is what the entity has when it is first replicated:
  - its pose (position to 1 mm, rotation of 15 bits per component, scale), preceded by the
    entity's persistent `Id`, the prefab it came from (`scene.Prefab_Source`) and the
    [section](#sections) it hangs from;
  - its motion (`Motion_State`, linear and angular velocity to 1 mm/s) if a simulation moves it
    (it has `core.Motion`);
  - its driver (its `input.Move_Input`, published when it changes) if it has `Move_Input`;
  - each of its `@(component,replicated)` components, on or off.
- Each distinct set is a protocol type that both ends compose from the list its creation carries
  ([types](networking.md#protocol-and-descriptors)). A component added later does not travel.
- `replicated="owner"` sends it only to the owner, `replicated="others"` to everyone but the owner.
  The `local` field does not travel; `precision`, `bits`, `min` and `max` of the tag choose the
  serializer ([serial](networking.md)).
- The pose carries one bit per component turned off by itself (`Pose.off`): whoever receives it
  turns it off or on, without losing its values. A `single` component (`Sky`, `Sun`) does not carry
  the bit: which one is on belongs to each end, so each player sees the sky of where they are.
- **A disabled entity stays replicated.** If the server disables it with its own `core.Disabled`
  or one from something above (a distant agent, a seat that is waiting), its object continues and
  the pose says so (`Pose.disabled`).
  - The client gives the replica `core.Disabled` and removes it when the server enables it, also
    if it had it from its scene: it keeps everything, including what only it gave.
  - What disabled its section on the client (`scene.Section_Held`) stays as the section says, and
    what the network enabled in a section that is loaded and disabled there is enabled with it.
  - The pose goes once when it is disabled; what changes while it is disabled goes when it is
    enabled, except the position of the scope, which follows it.
  - What disables a server section (`scene.Section_Held`: loaded and disabled, or unloaded) ends
    the object, like what is disabled before having one, which is created when it is enabled.
  - What a client holds or each end simulates carries only the bit of its creation.
  - It occupies its place in `max_objects` and `state_words` while it is disabled.
- A client makes the entity from the prefab of the pose (`scene.spawn`, `transient`), takes it from
  the scene if it has that `Id`, or makes it empty; the one of a section it has not loaded waits
  for it to load.
- A replicated component that names an entity the other end does not have (it has not arrived yet,
  or it is not replicated) is removed from the replica until it arrives: it would name something
  else. A `Joint` toward something that is not there is not anchored to the world.
- What does not fit in an object (more than `COMPONENTS` replicated components, a state larger than
  `MAX_STATE_WORDS` or more than `wire.TYPE_CAPACITY` sets) is not replicated and is the
  `net.object` problem. A component or a message the protocol cannot describe does not open the
  network (`net.protocol`).
- `update_hz` limits the server's state frequency to whole intervals of ticks, kept like the
  [object turns](networking.md#replication): entities of the same frequency publish on different
  ticks. `simulation` says who simulates (`Server`, the owner predicts; `Lent`, lendable to a
  client; `Each`, only the creation is replicated) and `audience` who sees it (`Near`, `Always`,
  `Owner`, `Custom`). `radius` is added to the view radius for `Near`; changing it does not rebuild
  cells or resend components.
- `Custom` leaves relevance to the game: `multiplayer.relevance_set` (server) says whether a
  connection sees the entity, and it is the only per entity-connection primitive; fog of war, teams
  or what is private to a player are resolved with it when it changes, without a call per object on
  every tick. What is requested before the network makes the object waits in the session until the
  end of the tick, in order (if the entity is not replicated by then, it is `net.relevance`). A new
  entity, one that is replicated again and a connection that arrives start with none; with another
  audience what was requested is kept without counting.
- **Network parent.** The one of a replicated entity is its closest ancestor with `Replicate` in
  the hierarchy, even if there are entities without `Replicate` between the two; an object that is
  seen somewhere else without hanging from it (an item in someone else's inventory) is `Custom`.
  - The child follows the visibility of that ancestor, above its own audience, and arrives after
    it: while the ancestor has no object, the child is not created and one that already existed is
    seen by nobody.
  - If the ancestor is destroyed, loses `Replicate` or the child changes place, the parent becomes
    the next replicated ancestor, or none: always the one the hierarchy of that tick says. It is
    recomputed when publishing, only when `core.Hierarchy` or the layout of `Replicate` changes.

**Collections.** A replicated component can contain `multiplayer.Collection(Item,capacity)`:
preallocated slots with stable `u32` ids, where zero is a free slot, without importing `net`.

```odin
@(component,replicated)
Inventory :: struct {items:multiplayer.Collection(Item,16)}

error:=multiplayer.collection_set(&inventory.items,42,item)
value,found:=multiplayer.collection_get(&inventory.items,42)
```

- `collection_set` inserts or replaces and returns `Invalid` for id zero or `Full` without a free
  slot; it does not allocate. Removing an id frees its slot for another.
- The row is written with `core.get` or replaced with `core.add`, so that its stamp advances.
  Quantization and deltas: those of the
  [collection contract](networking.md#protocol-and-descriptors).

**Messages.** A struct of up to `EVENT_BYTES` declared `@(net_message)` is a message: the server
sends it; `from="client"` lets a client send it to the server, and `from="owner"` does too, but
only about entities it owns. `reliable` delivers it once and in order.

```odin
@(net_message,from="client",reliable)
Ask :: struct {id:base.Entity_Id}
```

- It is sent with `multiplayer.send(&outbox, time, value, about?, to?)` and read with
  `multiplayer.event_read(item, T)` from `Net_Events.received`. `send` returns `false` and does not
  enqueue while `time.resimulating`: the tick being repeated already sent it.
- `Net_Outbox` (`copy=false`) is not copied with the world: a correction does not lose what is
  waiting. A `reliable` message the host rejects because the queue is full (`Full`) waits there,
  with the ones that follow, until the next frame; the other rejections are the `net.event_send`
  problem.
- An `Entity` field of the value names a replicated entity.

**Settings.** `Net_Settings` (`host` storage) tunes the session and is read when it opens; zero
takes the default:

- `max_clients` 32, `max_objects` 1024, `timeout` 10 s, `connect_timeout` 5 s, `view_radius`
  128 m.
- `replication.history_seconds`: how far back the session goes, the same at every tick rate
  ([history](networking.md#time-and-inputs)); a client takes the server's. `session_history` gives
  it in ticks.
- `port` (`DEFAULT_PORT`): the game's UDP port. A server without `--server <port>` opens it, an
  address without a port takes it, and networked Play looks for a free one starting from it
  (`settings_port`). One that is not a UDP port does not open the network: it is `net.settings`.
- Tolerances: position 0.05 m, velocity 0.5 m/s and rad/s, rotation 0.07 rad, scale 0.001.
- `max_resimulate`: ticks repeated in one frame, 0.3 s of ticks (at most the history).
  `resimulate_budget`: one second of ticks per second. `critical_ticks`: half a second.
- `correction_time`: 0.1 s. `sync_test`: 0 (off).
- `absent_seconds`: 300 s that the seat of a player who left waits for them; negative, none.

## What another library simulates

The network and physics share only `core` tables, each with one writer:

- **`core.Pose_Target`**, written by the network: on a client, what the server simulates; on the
  server, what a client that has it lent simulates. It carries the pose and velocities of the other
  end and a number that grows with each request to place. Without `follow` it is simulated here and
  put where the network says when it corrects (the predicted); with `follow` it goes toward the
  pose on each tick as a kinematic body, pushing what it touches (the interpolated).
- Whoever owns the `Transform` takes it at the start of the tick without knowing it comes from the
  network: physics for its bodies, characters and proxies (`physics_pose_targets`), and
  `core.pose_targets_place` for a free `Transform`. A body that has not been made yet is made at
  the pose, with the velocities of the target.
- Until the simulation takes it, for the network the replica is where it asked: a correction that
  follows another in the same frame starts from the last one requested (`replica_now`).
- **`core.Motion`**, written by physics: velocities, center of mass and step group. The network
  publishes the velocities, compares positions where the mass is and takes as critical the replicas
  that share a group with what this client drives.
- **`core.Simulation_Hash`**: with `sync_test`, the network turns on `core.Sync_Check` and physics
  leaves there the hash of its simulation after each tick.
- `Collider`, `Joint` and `Joint_State` are replicated components of physics, which detects by
  itself a change made by another and redoes its own with the frames the server took
  ([networked joints](../../mirai-physics/references/engine.md#for-networking-and-saves)).

`destruct_multiplayer` replicates fractures
([networked destruction](../../mirai-physics/references/engine-destruct.md#network)),
`foliage_multiplayer` the foliage instances taken out in play
([foliage](../../mirai-world/references/foliage.md#instances-removed-in-play)) and
`terrain_multiplayer` terrain edits
([terrain](../../mirai-world/references/terrain.md#network)). The `behavior` minds decide only on
the server, and clients see what each agent does in its replicated `Mind_Presentation`, without
predicting it ([minds](../../mirai-world/references/behavior.md#minds)).

## Authority and players

- The network keeps the role of [`core.Network`](../../mirai-core/references/core.md#network)
  according to the session (`authority_follow`, which removes every `core.Remote` when the role
  changes) and `core.Remote` on what another end decides: on a server, what a client has lent now
  (`Simulation.Lent`), when who has it changes; on a client, the replicas it neither predicts nor
  has lent, when classifying them. What the server simulates is decided by the server even if its
  owner predicts it: the game moves its body with the actions of the seat of that connection.
  Libraries that replicate nothing ask with `core.owned`, without importing the network.
- A server seats the player of each connection (`net_seats`) when its client says who it is
  (`Net_Player`, on connecting): an `input.Seat` with its `peer` and its `player`, whose actions
  are the input the connection sent for the tick.
  - The seat is replicated to all clients (`Replicate` with `Always` and a `Transform`) with what
    the game hangs from it: the state of each player (score, team) lives in it and survives its
    body. `player` is `local`: a player's id does not reach the others.
  - It carries `core.Keep`: it passes with its player to the world of the next scene.
  - The client presents once, on connecting, its player's secret (128 random bits); the server
    keeps in the seat only its hash (SHA-256), which says nothing about the secret: nobody takes
    another's seat without its secret, even knowing its id.
  - The secret is the one of the player's profile (`Net_Identity`, `@(storage,persist)`): the
    network makes it the first time a client connects and asks to write the profile
    ([saves](../../mirai-gameplay/references/libraries.md#save)), so the player recovers their
    seat after closing the game. `--new-player` of the player or `Open_Request.new_player` give one
    only for that world: several clients of one machine, like the online ones of the editor's Play,
    are different players. Accounts of a platform are not there.
  - A connection presents one player, and one that is somebody: an empty secret or a second
    `Net_Player` closes it with `Denied_Player`.
  - When the connection leaves, the seat waits for its player disabled (`core.Disabled` and
    `Seat_Absent`) for `absent_seconds`, and then leaves with what hangs from it; the same player
    who connects recovers it, like Unreal's inactive PlayerState, enabled if the network disabled
    it: what the game disabled stays disabled. Another connection of the same player, while the
    previous one continues, closes that one with `Replaced`.
  - The seats of a saved game wait for their players without limit.
  - The body belongs to whoever gave it: the `spawn` plugin marks its own with `Seat_Body` and
    destroys them with their seat (`spawn_seat_bodies`): a seat that is waiting keeps its own,
    still. A game that gives its own decides what to do with them.
- The owner of a body is the connection of the seat that drives it, and that of a seat its
  connection ([seats](../../mirai-gameplay/references/control.md)): the server reads it when
  publishing (`owner_of`), without copying it into `Replicate`; what a remote seat does not drive
  has no owner. The view of a connection follows what it owns in the world, not its seat.
- A client has the server's seats as replicas, which are neither its own nor of this machine;
  `own_connection(session)` gives the `peer` of its own.
  A client drives with its first local seat the body the server lets it predict and releases the
  one it no longer predicts (`net_driving`).

## Opening and closing

`net_begin` (`input`, stage `begin`) opens the session the first time, according to, in this order:

- what its `Session_Request` storage asks (its `open`, an `Open_Request` that serves or connects),
  written before the first frame (the editor, for each run, through the `open` of its network
  provider);
- if nobody asked, the player arguments the plugin takes from `app.launch` with
  `host.launch_flag` and `host.launch_value` ([plugin
  arguments](../../mirai-core/references/host.md#plugin-arguments)): `--server [port]`
  (`Net_Settings.port` without a port), `--dedicated` (serves like `--server`, in a player without
  the phases of whoever watches), `--invite [token]`, `--connect <invitation or address>`,
  `--new-player`, `--until-empty`, `--status <file>`, `--latency`, `--jitter` and `--loss`.
  A value that does not work,
  or `--server` with `--connect`, says why and ends the player with `host.PLAYER_USAGE`. Without
  them, the game runs alone.
- A session launched this way switches the application to real time (`host.app_real_time`): a
  windowless player that took fixed steps follows the clock while it talks to other processes.

A session launched this way switches the application to real time (`host.app_real_time`), so that
a windowless player that took fixed steps follows the clock while it talks to other processes; it
makes the input script of a client wait until it joins (`app.script_hold`), and prints for a person
what happens (joining, serving, invitation, connections, rejections, the reason for a disconnect).
It ends the player with `PLAYER_NET` if a server cannot open the network, a client fails to join or
a windowless one loses its server; a client with a window that lost it continues and shows the
reason, and with `--until-empty` a server that emptied ends normally.

- `timeout` replaces those of `Net_Settings` for a world that advances only when asked.
- `Net_Session` keeps the mode, the `net` host, the protocol (its hash travels in the handshake and
  the server rejects a client with another), statistics and, on the client, the history.
- The session opened from `app.launch` informs whoever launched the player: it prints on joining,
  on serving (port and protocol), the invitation, the connections, the rejections and the reason
  for a disconnect (text for a person: port in use, invalid address, different protocol, full
  server, timeout, a `Net_Settings` field out of its range...).
- It ends the player with `host.app_exit` and its `PLAYER_NET`: a server that cannot open the
  network, a client that fails to join and a windowless one that loses its server. A client with a
  window that lost it continues and shows the reason. With `--until-empty`, a server that emptied
  ends normally.
- The input script of a client waits until it joins: the session sets `app.script_hold` on opening
  and clears it on joining.
- `--status <file>` appends the state of the session (with `rtt_ms` on a client, and `sent` and
  `received`, the UDP bytes of the host) and of each object every second of ticks, or every
  `--status-ticks <n>`. The blocks fall on multiples of that step, so those of a client and of its
  server compare one to one.
- `--latency <ms>`, `--jitter <ms>` and `--loss <percentage>` put a
  [`Conditioner`](networking.md#transport) between the socket and the host. Each direction is
  delayed `latency`: the ping is double.
- The editor's Play serves the game from its own world and opens its online players this way
  ([networked Play](#networked-play)).
- `invite_code(session)` gives the invitation code of a server, when the router answered: one
  code from the internet, its network and its machine (a client with a code asks nearby too).
- A server saves and loads its world with `save`; a client does not (`Unavailable`). Loading with
  clients is a [scene change](#scene-change).

## Scene change

The world of a session is the scene of its server (`scene.Scene_Root`). When a scene replaces the
world of an end, what the session knew about its entities belongs to a world that is no longer
there, and the new one numbers its entities from zero ([core](../../mirai-core/SKILL.md)):

- **Server.** The objects of the previous world end, detached from their entities so that none
  names one of the new world while it leaves, and those of the new one are made again. The
  connections continue, their seats pass as `Keep` and `Remote_Inputs` is `keep`. Each connection
  is held (it sees no objects and hears no game messages, [scope](networking.md#replication)) and
  hears the scene and the number of that change (`Net_World`, reliable). When it says it is in that
  world (`Net_World_Ready`) it is released, it enters (`Entered` in `Net_Connections`) and the new
  world reaches it. A connection that arrives hears the same, held from the handshake.
- **Client.** When it is not loading any scene, it asks for the one it heard (`scene.request`),
  unless it is already in it on arrival; when a scene replaced its world it forgets its replicas
  and its history and notifies.
  A change that repeats the scene loads it again. One that cannot load it leaves with
  `Scene_Missing` and a reason that names the scene and asks for the server's assets (`net.scene`).
- What the world brings from the network (`Net_Link`, `core.Remote`, `core.Pose_Target` of the
  entities that cross, or of a saved game) is removed: it belongs to the previous world.
- A saved game remembers its scene (`save`): loading it on the server is a scene change toward that
  scene, with what the server had of what was lent to a client.
- A scene that replaces the world of a client that was already in the server's one is the
  `net.scene` problem: the scene is decided by the server.
- What the game sends belongs to a world: each end discards the game messages that arrive from
  another that is not in its own (a client that has not yet said it is in, or a server that already
  changed). What a library knows about the previous world outside of it is forgotten with the
  change ([networked destruction](../../mirai-physics/references/engine-destruct.md#network)).

### Sections

Each end loads its sections (`scene.Scene_Reference`; with `streaming`, around its players; the
server, around those of each connection) and what is in a section reaches a client only while it
has it loaded.

- The section of a replicated entity is the closest reference upward in the hierarchy; without any,
  the root. If it hangs from one, it is also in each other one whose box has its position in the
  world, except those that surround its own. Its pose carries the `Id` of those references, first
  the one it hangs from, and its object belongs to the host groups the server gives to those
  sections ([groups](networking.md#replication)): any client that has one receives it once. It is
  recomputed when the hierarchy, the references, their boxes or the entity's position change, over
  the boxes of the sections that the server redoes when they change; in more sections than
  `OBJECT_GROUPS` it is the `net.sections` problem and it stays in its own.
- Each client tells the server which sections it has loaded and which it releases (`Net_Section`,
  with the scene change number), and the server gives it or removes its group. On a scene change
  the server removes the groups of all connections and each client says its own again.
- More sections than `Net_Settings.replication.groups` is the `net.sections` problem: what is in
  the extra ones reaches all the connections its audience reaches.
- A replica takes the entity with its `Id` of the section it hangs from while the client has it
  loaded; if it has only another of its sections, or its own no longer has that entity, it makes
  one of its own, which it leaves for the one of its section when that loads. The own one is a copy
  without `Id` of that entity and what hangs from it, read from the scene of its section
  (`scene.spawn_member`), with what is not replicated (mesh, material); without that scene, from
  its prefab, and otherwise, empty. Without any of its sections (it arrived before its notice) it
  waits without an entity. If the section releases the entity it took, asleep or not, the replica
  leaves it without what came from the network; if the server took it out of a section loaded
  here, it goes away.
- **What the server keeps of a section wins.** The state of what is replicated arrives whole with
  the creation of each replica. What of the scene of a section is no longer in it (destroyed or
  gone to another) is said by the server through `Net_Gone`, with the world's `Id`
  (`scene.section_gone`: the tombstones of the unloaded section, or what its registry knows it no
  longer has; without a registry, loaded from a saved game, what its scene has and it does not): to
  a client when it loads the section, and to those that have it loaded when something replicated
  leaves it, whether they see it or not (the server keeps which sections each connection has; a
  section without a group says it to all). The client removes it from that section if it has it
  loaded, except what has a replica.

## Networked Play

The editor part of the plugin (`plugins/multiplayer/editor`) provides the editor's networked game
through its `Play_Provider` ([extensions][ext]); the editor supplies the local players, the player
processes, their screen and their input
([networked Play of the editor](../../mirai-editor/references/editor.md#networked-play)). Without
this plugin the editor shows nothing of networking.

[ext]: ../../mirai-editor/references/extensions.md#a-plugins-game-and-player-processes

- With **Online** players (run menu or `play.start` with `online` and `ping_ms`), or while it
  shares its scene as host, Play serves the game from its own world; without online it serves only
  guests. With unsaved assets, the bar asks and the API fails listing them, except `saved_only`.
- Serving: the scene is written to `.mirai/play/play.scene` and the world of Play opens a server
  (`Session_Request.open`) on the first free UDP port from `Net_Settings.port`, with a new token;
  its local players play in it and, as soon as the server listens, one `mirai-player` is opened per
  online player (`--connect` through `127.0.0.1`, `--players 1` and `--latency` equal to half the
  ping) over the editor's library, without compiling anything
  ([player processes](../../mirai-editor/references/editor.md#networked-play)). Server and clients
  run the same library this way; the protocol hash still rejects a client of another build, like an
  external player or a guest with other code.
- `play.network.status` reports the state of `Net_Play`, with `invite`, the code to enter from an
  external player. Stop ends Play, the session and the online players; a paused Play keeps its
  connections.
- Agents: `play.start` with `online` creates one client run per online player, with its session and
  its port, without compiling or opening processes. They wait up to `NET_PLAY_STEPPED_TIMEOUT`
  before treating a connection as lost, because they advance only when the turn asks. Several turns
  and the user play online at the same time.
- Collaborators: the host's presence offers the game it serves, and with the shared session the
  host asks the router for the port of its server. A guest joins with `play.join` with its own
  player over the scene the server runs (`.mirai/play/host.scene`,
  [collaboration](../../mirai-editor/references/collaboration.md#the-hosts-networked-games)); a
  client of a different build is rejected by the protocol hash.

## The tick

```text
input  -1000     opens the network; datagrams are changes to the world; a client compares the
                 server's states with what it predicted and, if they differ, goes back and
                 repeats; it keeps the world clock with that of the connection
input  -800      client: goes back to the oldest tick a library asked for (rewind) and repeats
fixed  -100000   who arrived and who left since the previous tick (Net_Connections)
                 server: the input each connection sent for this tick
                 client: copy of the world as the tick found it; interpolated replicas go to
                 where they are shown at that tick
fixed   100000   publishes what the tick left; the host sends
frame  -10000    client: the error a correction left in the predicted ones fades
late    100000   the host sends and receives; the player is informed
```

**Client clock.**

- The world clock (`Time.tick` and what `Frame_Time.accumulator` has not yet simulated) is the
  client's tick. `net_begin` gives it to [`clock_advance`](networking.md#time-and-inputs) and
  writes `Frame_Time.dilation`, which `host` uses in the next frame to count its time faster or
  slower. This way the frame runs the ticks of the network clock and `alpha`, in [0, 1), is the
  fraction of its tick: what is predicted at constant speed is always drawn forward.
- On synchronizing, `Time.tick` is set to the target; afterward it only jumps forward and the
  history is emptied. Until the server answers `dilation` is -1 and no tick runs; when the session
  closes it returns to 0.
- A world that advances only when asked (`host.app_game_frame(..., step=true)`, an agent's steps)
  runs one tick per step, without dilation.
- The server pauses and scales the session's time: it serves the `core.Clock_Requests` of its game
  and its `core.Clock` travels with the tick ([time](networking.md#time-and-inputs)). The client
  asks for it for its own through `core.Clock_Requests` (with `server`; `net_begin` runs before
  `core.clock_requests`, which takes it in the same frame), and its estimate of the server does not
  advance while the server is paused. The game's requests on a client are the
  `core.clock_network` problem; when the session closes it asks for its clock back.

A paused game runs no phases: whoever pauses it calls `pump` every frame (the editor, in
`game_tick`) so that connections continue. It opens the requested session (`Session_Request`) if no
frame has opened it yet. It takes what was received as the input phase, without the correction or
the client clock, and the host sends and receives; a pumped server tells its clients that its clock
is paused, because its ticks do not advance, so their estimate does not run ahead; what it left in
`Net_Events` waits for the next frame that runs, up to `PAUSED_EVENTS` messages: those that arrive
later are discarded (`Net_Stats.events_dropped`) and are the `net.events_paused` problem. A
windowless editor that drives the API (`mirai session`) calls `pump` of each run between its steps,
so a player who joins while no frame runs gets an answer.

**Server.**

- Each `Replicate` with `Transform` becomes a network object (`Net_Link` on the entity), of the type
  of what it has. If it loses `Replicate`, is disabled or dies, the object is destroyed; when
  enabled it is created again with its state.
- On its turn it publishes the pose and the components whose row stamps or layouts changed, the
  motion of what moves and the final transition to rest; disabling or enabling a replicated
  component publishes the pose with its bits. Changing another entity of the same table does not
  publish this row again. Changes of `owner`, `priority` and scope are resent.
- What the full frame rejects keeps its stamp or its previous value and is retried on the next
  turn.
- A new connection starts with an unbounded spatial view, keeping the owner and parent filters. The
  view follows the first body its seat drives, or the game gives it one with `multiplayer.view_set`.
- The input of each client is the actions of its first local seat (`input.Remote_Actions` in
  `Input_Packet`); it arrives as `Remote_Inputs`, is read with `multiplayer.remote_input`, and
  `net_seats` gives it to the seat of the connection with `input.seat_receive`, which derives
  `pressed`, `released`, taps and holds against the previous tick
  ([networking in control](../../mirai-gameplay/references/control.md#networking)). Its layout
  enters the protocol hash. A `Repeated` input (the tick's did not arrive in time) leaves what was
  held as it was, so a held button is neither let go nor pressed again when the next one comes; it
  repeats neither a tap nor what the mouse moved, which belong to the tick they were sent for. More
  axis actions away from zero than `input.REMOTE_AXES` in one tick are reported as
  `net.input_axes`.
- Two more values travel with the input ([lag compensation](#lag-compensation)):
  - the look of the `Move_Input` of the body the local seat of the client drives, with the yaw
    wrapped to a turn; the server applies it to that body in the `intent` stage (`remote_look`,
    `server.odin`), after the seat and before locomotion, by the shortest turn, so the body keeps
    its whole turns;
  - how many ticks before its own the client showed the others (`Clock.display`), which becomes
    `Remote_Input.view` as a tick of the server.
- `phys.Collider` travels whole: a change of collision, of per-contact rules or of shape on the
  server replaces the client's and physics applies it as a local change. While the `target` of a
  joint (or the `group` of a collider) names an entity the client does not have, the component
  leaves the replica and the joint is suspended: a destination the server does not replicate (a
  static wall of the scene) leaves it suspended, and an explicit attachment to the world
  (`target=core.NONE`) stays active.
- The `Entity` references of replicated components are kept as network handles and re-evaluated
  when creating, linking or destroying objects, even if the row does not change. A destroyed
  destination stays as `core.NONE`; a new generation does not satisfy an old reference.

**Client.** Each new replica receives an entity (the one from the scene with its `Id`, if no other
replicates it; otherwise an instance of the prefab of its pose; otherwise an empty one), which on
ending or leaving the view is destroyed with the pieces its prefab brought (`core.destroy_tree`).
It carries `Replicate`, `Net_Link`, `core.Pose_Target` and the components the server said. Its rows
are written where they wait for the end of the function (`core.raw_staged`, `core.staged`), which
settles once at the end.

A library that makes on the client the entity of what a replica represents (a group of a broken
destructible, with the `Id` both ends compute) asks for it with `multiplayer.adopt` in
`^multiplayer.Net_Adoptions`: at the end of the tick that entity takes the place of the replica's,
which is destroyed.

How it lives depends on its role (`wire.Role`) and on who simulates it:

- **Interpolated** (`core.Pose_Target` with `follow`): another's, shown between the server's
  states.
  - On each tick it goes to the state of the display tick of that tick (`clock_interpolation_tick`)
    minus its delay, which shows it further back if its states arrive more spaced out (a low
    `update_hz`), and the frame draws it between the last two ticks like everything. The tick's
    copy keeps the display tick and the delay of each replica: a correction repeats each tick with
    its own.
  - Without new states it continues for a while with its last velocity and then stays still.
  - A body is kinematic, reaches the pose in the tick and pushes what it touches (a large jump is
    placed); a character stays at the pose after every step; without a body,
    `core.pose_targets_place` writes its `Transform`.
  - Following goes before a manipulation by the game (an animated ragdoll, a tool): the server
    already applied it and the client shows what resulted. The manipulation is kept and grips the
    body again when this client simulates it.
- **Predicted** (`core.Pose_Target` without `follow`): one's own (`Predicted`) and what a simulation
  moves on the server (`Server`). The client simulates it ahead of the server, which corrects it;
  it carries `render.Draw_Offset` to hide corrections.
- **Simulated here** (without `core.Pose_Target`): `Each` or `Held`. It is not corrected.

**Prediction and correction.**

- On each tick the client keeps a copy of the `World` in a ring as deep as the history, with the
  tick's input and the pose and quantized state of each predicted replica.
  - Each slot copies again only the tables that changed since it was written, and of those the rows
    whose stamp differs, also after a rollback, and of the storages those a function received to
    write or code outside the loop asked for
    ([copy of what changed](../../mirai-core/references/core.md#world-reflection)). Physics copies
    its state block by block without comparing again the geometry the slot already has, in pools
    of the size of what it uses (`copy_kept`); a slot of a replaced world copies everything again.
  - The comparison buffers and the authoritative history are reserved on opening, and made again
    only when the server announces a different history on connecting; quantization reuses the
    previous record when the row, the layout or its links do not change.
- It compares position, rotation and scale of all the predicted ones, velocities of bodies and the
  quantized words of joints and components, with the tolerances of `Net_Settings`.
- If it differs and the replica is **critical**, the world goes back to the copy of the next tick
  and applies the available authoritative base, if the ticks to repeat fit in what remains of
  `max_resimulate` in the frame, in `resimulate_budget` and in the history.
  - Critical: one's own, or one that shared a simulation group (`core.Motion`) with what the client
    drives in the last `critical_ticks`: what touched it or is joined to it by a joint.
  - The return is `host.app_world_replace` with the marks of that copy, which copies into a
    separate world what changed since and swaps it; without memory the world does not change, the
    correction is deferred and it is the `net.rollback` problem.
  - The `fixed` loop runs again with the saved local input and, at the end of each tick, the pose,
    components and joints of that authoritative tick are applied. Physics takes the pose at the
    start of the next tick, and the record of that tick is the server's state.
  - Each repeated tick is `host.app_tick_replay`. `core.Time` returns with the copy and each tick
    advances it, so it ends where it was; `core.Frame_Time` is not part of the copy, and of the
    present only the frame's `Input` is kept by hand.
  - The latest components of the non-predicted replicas are restored at the end: a component
    received after the copy does not disappear nor is used ahead of time.
- What else differs is **closed** in the present without simulating, and also the critical that
  does not fit:
  - the velocity takes its error immediately, as an impulse;
  - the pose error, brought to the present with the velocity one, is closed before each tick that
    runs for the first time, a part `dt/correction_time` of what remains, without suddenly crossing
    what it touches;
  - the records after the compared tick are shifted by the error, and those taken while it closes
    include what is missing: the server's next state does not find it again;
  - a body the server has at rest is put at that pose and put to sleep, and an error larger than
    the distance at which smoothing gives up is applied at once.
- A rollback leaves to the correction what the replicas it repeats were closing. A state older than
  the history cannot be compared (`unverified`). The pose jump of a predicted one in a rollback or
  when placing it accumulates in a smoothing that `Draw_Offset` draws without touching what is
  simulated; what is closed tick by tick does not pass through the smoothing.
- A library that learns that already simulated ticks were different because of something the
  network does not compare (a server fracture) asks for it with `multiplayer.rewind` in
  `^Net_Rewinds`: `net_rewind` goes back in that same frame to the copy of the oldest and repeats
  like a rollback, if it fits; if not, the library applies its own in the present.
- **SyncTest** (`sync_test`, for debugging): at the start of each frame the client reruns its last
  ticks from the copy it started with, with its input and without the server's states, and
  compares a hash per table and that of physics with those of the last time it ran (the first, or a
  correction); after the last tick, row by row, to name the entity. It compares only the ticks to
  which the network gave the same on both times (it keeps a hash of what it writes in each), and
  the storages only through the physics simulation. A difference is the `net.sync_test` problem;
  afterward the world of the first time returns, so the test does not change the save.
- During resimulation `send` does not enqueue and `net_tick_tail` does not publish; sounds, UI
  events and what remains in the `World` follow the rule of
  [`core.Time.resimulating`](../../mirai-core/references/core.md#core-storages).

Body intent and inputs: the driver fragment carries only the `input.Move_Input` of the body, and
for the replicas of others the client uses the last historical one not later than the tick it
simulates (without it, the last received). Device input goes only to the server, and its
transitions are computed once per tick even if the player owns several bodies. The
[locomotion](../../mirai-physics/references/engine.md#locomotion) runs the same at both ends, and
the rollback repeats the whole world, not a solver island.

## Lag compensation

`rewind.odin`. The server sees the world as a player saw it, to judge an instant hit (a shot, a
melee swing) where that player aimed.

**What a client shows of the others.** There are two models:

- **By default, it predicts them.** What the server simulates with motion (`simulation=.Server`) is
  shown simulated up to the client's tick, with the last known input of each: it is where it
  probably is now, and it misses when the other changes direction. A hit is judged in the present;
  compensating does not apply, because the rewound pose was never on screen.
- **With `Net_Settings.interpolate_others`, it interpolates them.** What the client does not drive
  is shown interpolated at `Clock.display` (half the round trip, two jitters and
  `interpolation_delay` behind the server): it is where it was, without missing, but in the past,
  and a hit is judged in that past.

**How it works.**

- Every input says how many ticks before its own the client showed the others: what the last tick
  before the frame that took the input left, the same for every tick of that frame
  ([the tick](#the-tick)). The server keeps it in `Remote_Input.view` as a tick of its own.
- If that is further than `Net_Settings.rewind_tolerance` seconds from what the round trip, the
  jitter, `input_lead` and `interpolation_delay` of the connection give, the server takes the
  latter and counts it in `views_corrected`: a client does not choose how much past it sees.
  Negative, the client is believed within `REWIND_SECONDS`.
- At the end of every tick, under its number, the server keeps in `Rewind_History` the `Transform`
  it publishes of each entity with the `Rewind` component, in a ring as deep as the history,
  made when the session opens, and `REWIND_ENTITIES` entities per tick; those that do not fit are a
  problem. `rewind_record` writes
  it before `net_tick_tail`, only on the server; it is not copied with the world.
- It keeps the pose of the entity, not that of its bones: a hit is tested against shapes placed
  from that pose.
- With no entity with `Rewind`, a client does not work out its view, and a game that does not
  compensate pays nothing per tick.

**API.**

- `rewind_tick(inputs, connection, time, max_seconds=REWIND_SECONDS)`: the tick the client of that
  connection showed when it sent the input of the tick being simulated. Never later than that tick
  nor earlier than `max_seconds`. `false` without an input that says it.
- `rewind_pose(history, e, tick)`: the pose of `e` at that tick with fraction, interpolated between
  the two ticks around it. If it moved more than `REWIND_TELEPORT` between them, the first one's,
  because it was a teleport. `false` if the history does not have it.

**What the game does.**

- It marks with `Rewind` what can be hit (the bodies of the players).
- When firing on the server, it finds the shooter's connection (`Seat.peer` of its seat), asks for
  `rewind_tick` and tests the shot against `rewind_pose` of each target.
- Nothing moves: the world never goes back and physics does not notice.

## What it demands of the rest of the game

- **What is simulated in `fixed` is a function of the `World` and the `Input`.** A state outside
  the `World` (a `host` storage, a counter in a variable) does not go back with the correction.
  What must be repeatable goes in components or in `World` storages.
- **What leaves the `World` from `fixed`** (a sound, a message, something a `host` storage
  remembers) passes through a sink that does not act while `core.Time.resimulating`; a new sink
  respects it the same, like the `destruct` state request, which only records the request if
  `send` enqueued it.
- **The server decides.** A function that decides an outcome (damage, grant, drive) does so only if
  this end is the owner: `core.owned(remotes, e)`. Without network always; on the server, what no
  connection owns; on a client, what it owns, what it has lent and what is not replicated.
  `destruct` damages only on the server (by role), seats change only bodies this end owns and
  the clip of a cinematic follows the end that owns the timeline.
- The game tells its role with `core.Network` (`Standalone`, `Server`, `Client`), or with
  `is_server` and `is_client` where it already has the session.
- A client does not save games: `save` answers `Unavailable` on a client.

## Delegated authority

A `Lent` object is simulated by the server until a client asks for it or the server lends it
(`authority_grant(session, e, connection)`; 0 recovers it); `authority_release` returns it. While a
client has it, that client simulates and uploads pose, velocity and components when they change,
and the others interpolate it. The server puts what arrives in `core.Pose_Target` (without
`follow`) and simulates it as it says; on recovering it, it removes it.

## Connection events

- `Net_Connections.events` brings `Connected`/`Disconnected` with the connection and the reason,
  and on the server `Entered` when a connection enters its world (on arriving and after each scene
  change): from then on what the game sends reaches it. `fixed` functions read it directly: at the
  start of each tick the network leaves there what happened since the previous one. A frame without
  ticks keeps it for the next and of a frame with several only the first has it; a tick that
  repeats has the ones it had.
- The identity of a player between one connection and the next is that of its seat
  ([players](#authority-and-players)).

## Problems

What the network could not do is a `net.*` [problem](../../mirai-core/references/core.md#problems)
of the world or the entity, with the cause and the fix; `Net_Session.stats` keeps statistics.
`net_begin`, `net_tick_head` and `net_tick_tail` receive `^core.Problems` and leave it in
`Net_Session.problems` while they run, for the functions they call; outside them it is nil (or the
one set by whoever tests those functions by hand).

- Server: `net.object` (a `Replicate` without `Transform`, or with more than an object carries).
  Without room for its object, according to the capacity that is missing (`wire.object_room`):
  `net.objects_full` (`Net_Settings.max_objects`), `net.states_full`
  (`Net_Settings.replication.state_words`) or `net.frame_full` (what the host takes per tick; it is
  retried on the next).
- On opening: `net.settings`, a `Net_Settings` value the host rejects, with the field and its range
  (`Host.refused`); the reason for the player says the same.
- Client: `net.replicas` (what the server replicates does not fit), `net.predicted` (a replica that
  does not fit in `predicted_capacity` is interpolated), `net.snapshot` and `net.rollback` (history
  memory) and `net.sync_test` (a tick that, repeated, leaves something else).
- Messages: `net.event` (a type that is not `@(net_message)`), `net.event_about` (about an entity
  that is not replicated) and `net.event_send` (the host rejected it).
- Relevance: `net.relevance` (`relevance_set` named an entity that is not replicated).
- Scene: `net.scene` (a client that could not load the server's scene, or whose world was replaced
  by a scene the server did not ask for) and `net.sections` (more sections than groups).
- The player's status line (`--status`) reports `problems=` with the world's count.

## Verification

```sh
./mirai check plugins/multiplayer/runtime
./mirai play templates/game --headless --frames 600 --server --until-empty \
  --status bin/server.status
./mirai play templates/game --headless --frames 300 --connect 127.0.0.1 --input <script> \
  --status bin/client.status
./mirai play templates/game --headless --no-gpu --frames 3000 --connect 127.0.0.1 \
  --latency 100 --status bin/client.status
```

- `mirai test plugins/multiplayer/runtime` covers input, authoritative components with real physics
  (physics and the network understand each other through `core.Pose_Target` and `core.Motion`, as
  in a game), deferred and destroyed references, stamps per object and frequency, remote character
  replay and the replicated `Collider` of a body
  (`a_body_replicates_the_collision_and_contact_rules_of_its_collider`).
- Types by fragment list:
  `a_replicated_component_that_does_not_fit_the_protocol_is_refused_with_its_fix` and
  `an_entity_with_more_replicated_components_than_an_object_carries_is_not_replicated`; in `net`,
  `a_client_composes_the_type_of_a_creation_from_its_fragments`.
- Scope of a correction: `replicas_joined_to_any_of_many_driven_bodies_are_critical`.
- Lag compensation (`rewind_test.odin`):
  `rewind_pose_interpolates_between_ticks_and_not_across_a_teleport`,
  `rewind_tick_is_what_the_client_showed_within_the_limit` and
  `interpolate_others_shows_bodies_of_others_in_the_past`; in `input_packet_test.odin`,
  `a_claimed_view_far_from_the_latency_takes_the_expected_one`; a state older than the history:
  `a_state_older_than_the_history_puts_the_replica_where_the_server_had_it`; in `physics`,
  `a_following_target_leads_a_character_where_it_says`.
- Entity disabled on the server (the replica continues, disabled, with its mesh, and returns where
  the server enabled it; what a section disables ends its object):
  `an_entity_off_on_the_server_stays_off_on_the_clients_and_comes_back_where_it_got`.
- `scope_test.odin`: `Custom` relevance with requests before the object and the `net.relevance`
  problem
  (`custom_relevance_replicates_an_entity_only_to_the_connections_the_game_names`) and staggered
  turns of `update_hz`
  (`entities_of_the_same_frequency_take_turns_instead_of_publishing_together`).
- Network parent: `the_parent_on_the_network_is_the_closest_replicated_ancestor` (intermediate
  ancestor without `Replicate`, the one that gains or loses it, parent change, ancestor lower in the
  table) and, with a client,
  `object_scope_controls_relevance_radius_and_follows_the_replicated_ancestor`.
- Rollback: `a_rollback_replays_its_ticks_and_leaves_the_clock_and_the_frame_where_they_were` (the
  clock, the repeated ticks with `resimulating`), `a_tick_that_runs_again_sends_nothing`,
  `rollback_copy_failure_keeps_live_world_and_warm_publication_does_not_allocate`,
  `history_copies_of_what_changed_equal_whole_copies_through_writes_layout_changes_and_corrections`
  and `a_tick_a_library_asks_to_go_back_to_runs_again_from_the_copy_it_started_from` (rewind).
- Correction without simulating:
  `an_error_too_deep_for_the_frame_is_closed_over_the_next_ticks_without_a_teleport` and
  `an_error_of_a_body_out_of_reach_is_closed_over_the_next_ticks_and_its_records_follow`. With a
  `Conditioner` of 100 ms per direction, 20 ms of jitter and 5% loss, a client pushes boxes while
  the server pushes another body:
  `corrections_on_a_damaged_link_fit_the_frame_and_are_closed_without_teleports`; the tolerance
  sweep, optional, `corrections_on_a_conditioned_link_by_tolerance`
  (`-define:NET_CORRECTION_SWEEP=true`).
- Interpolation delay in a correction:
  `a_rollback_places_interpolated_replicas_as_far_behind_as_each_tick_did`.
- SyncTest:
  `sync_test_names_what_a_fixed_function_reading_outside_the_world_changes`,
  `sync_test_leaves_out_the_ticks_that_states_arriving_late_change` (late states, and it still
  finds the nondeterministic function) and
  `sync_test_after_a_correction_compares_with_what_the_correction_left`.
- Capacities and configuration: `an_object_the_host_has_no_room_for_names_the_capacity_to_raise`
  and `settings_the_host_refuses_name_their_field_and_its_range` (`publish_test.odin`).
- Cost of the history, optional: `cost_of_the_history_of_a_client` (`--release
  -define:NET_HISTORY_BENCH=true`).
- Clock and drawing (`timing_test.odin`: server and client in memory, the client through the `host`
  loop): `a_client_at_144_hz_draws_what_it_predicts_always_forward` and
  `a_client_whose_frames_jitter_a_millisecond_draws_what_it_predicts_always_forward` (alpha in
  [0, 1), the ticks the world clock counts and what is predicted always forward);
  `an_interpolated_replica_that_moves_steadily_is_drawn_steadily_at_144_hz`,
  `an_interpolated_replica_published_ten_times_a_second_keeps_moving` and
  `an_interpolated_replica_over_a_jittery_link_keeps_moving` (even frame steps and without
  stopping); `an_interpolated_body_is_kinematic_until_this_client_simulates_it` and
  `an_interpolated_body_follows_the_server_over_a_manipulation_of_the_game_and_gives_it_back`.
- Convergence with in-memory transport (60 ms delay per direction, jitter, 20% loss and 10%
  duplicates and reordering; no sockets or destruction):
  `physical_joints_inputs_and_components_converge_on_a_damaged_network`.
- Convergence with two real UDP sockets on `127.0.0.1` and without GPU (two worlds in a process; it
  does not run the player binaries nor add loss to the socket):
  `authoritative_physics_joints_and_inputs_converge_over_real_udp_localhost`.
- `authority_test.odin` and `players_test.odin`: the role, `core.Remote` on the server and on the
  client, the seat of each connection and its body, and the owner of each body by its seat
  (`a_server_owns_each_body_to_the_connection_of_its_seat`).
- Players (`players_test.odin`):
  `a_seat_waits_for_its_player_and_is_given_back_when_it_connects_again`,
  `the_seats_of_a_saved_game_wait_for_their_players`, `a_client_keeps_the_seats_of_the_server` and
  `a_seat_the_game_turned_off_stays_off_when_its_player_comes_back`.
- Identity (`identity_test.odin`, one server and two clients in memory):
  `a_client_that_presents_the_id_of_another_player_does_not_take_its_seat`,
  `a_player_that_comes_back_with_its_secret_gets_its_seat_back` (the profile's secret, `Replaced`
  and `new_player`) and `a_connection_that_presents_no_player_or_two_is_closed`.
- Scene change and clock (`world_test.odin`, server and client in memory with the session's
  messages):
  `a_scene_change_keeps_the_players_and_replicates_the_new_world_once_the_client_loaded_it`
  (replicated seat, hold until the notice, nothing of the previous world names the new one),
  `a_client_without_the_scene_of_its_server_leaves_saying_so`,
  `a_client_follows_the_pause_and_the_time_scale_of_its_server` and
  `the_connections_that_come_and_go_reach_the_first_tick_after_them`. Sections:
  `what_is_in_a_section_reaches_a_client_while_it_has_the_section_loaded`,
  `a_replica_of_a_section_that_is_not_loaded_waits_for_it`,
  `what_is_in_sections_that_overlap_reaches_a_client_that_has_either` and
  `what_the_server_keeps_of_a_section_wins_over_what_a_client_kept`; in `net`,
  `an_object_of_several_groups_reaches_a_connection_that_has_any_of_them_once`, and in
  `engine/scene`, `a_section_says_which_entities_of_its_scene_are_gone`.
  `plugins/destruct_multiplayer` has its own.
- `mirai test plugins/multiplayer/runtime/api_test` covers the consumption of collections from
  another package that imports only `multiplayer`. The tests of deltas and convergence with loss of
  collections are in `net`.
- The player is exercised with the template's server and clients without a window, an input script
  and comparing the `--status`. A client with `--latency 100` reports an `rtt_ms` about 200 ms
  higher than without it. Connection loss, port in use, a client without a server and a different
  protocol end the player with `PLAYER_NET` and its reason.
- `mirai test plugins/multiplayer/runtime`, with physics and the network understanding each other
  through `core.Pose_Target` and `core.Motion` as in a game. Focal tests per file:
  - `publish_test.odin`: references that wait for the object's turn, joints with an absent
    destination, what a full frame rejects, the replicated `Collider`, the missing capacity and the
    settings the host rejects; a change of references, joints or retries with the full queue keeps
    its cases.
  - `authority_test.odin` and `players_test.odin`: role, `core.Remote`, components that do not fit
    in the protocol or in an object, seats of the connections and owners by seat. In `net`,
    `a_client_composes_the_type_of_a_creation_from_its_fragments`.
  - `scope_test.odin`: `Custom` relevance with requests before the object, `update_hz` turns and
    network parent (intermediate ancestor without `Replicate`, the one that gains or loses it,
    parent change).
  - `world_copy_test.odin`: rollback (the clock and the frame where they were, a repeated tick does
    not send, a copy that fails, the history of what changed, a library's rewind, the delay of the
    interpolated ones) and SyncTest (the function that reads outside the world, late states, after a
    correction).
  - `correction_test.odin`: errors closed over the following ticks without a teleport, also with a
    damaged `Conditioner` while client and server push bodies; the tolerance sweep is optional
    (`corrections_on_a_conditioned_link_by_tolerance`, `-define:NET_CORRECTION_SWEEP=true`).
  - `timing_test.odin` (the client through the `host` loop): alpha in [0, 1) and what is predicted
    always forward at 144 Hz and with irregular frames; interpolated ones that move evenly and do
    not stop with a low `update_hz` or a link with jitter; kinematic interpolated bodies and over a
    manipulation by the game.
  - `integration_test.odin`: authoritative components with real physics, comparison of what is
    predicted, references after linking and destroying, publication of what changed at the object's
    frequency, remote character replay, joints that wait for their destination, criticality with
    several driven bodies, scope that follows the replicated ancestor and in-memory convergence
    with loss, duplicates and reordering, and with two real UDP sockets on `127.0.0.1` without GPU.
  - `api_test`: collections from a package that imports only `multiplayer`; their deltas and their
    convergence with loss are in `net`.
  - Cost of the history, optional: `cost_of_the_history_of_a_client`
    (`--release -define:NET_HISTORY_BENCH=true`).
- `plugins/destruct_multiplayer` has its own. The `netpublish` scenario of
  `scripts/bench_compare.py` measures publication without a solver or clients.
