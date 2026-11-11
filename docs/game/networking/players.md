# Players, seats and visibility

A seat (`inp.Seat`) is one player, of this machine or of a connection (`peer`). The server makes
one per connection and feeds it the actions its client sent, never its devices; read them like any
seat (`inp.Input_Of(Action)`, `inp.pressed`). A seat that leaves waits, off, for the same player to
connect again; the player's secret is kept in their profile, so a returning client recovers it.

## Bodies

A seat drives a body (`Seat.body`). With a player prefab (`Spawn_Settings.prefab` in
`settings.mirai`, or one on a `Spawn_Point` with `players` on) the `spawn` plugin gives each seat,
local or remote, a body of it at a point with `players` on and destroys it with the seat; a point
with `players` off is for what the game spawns, such as enemies
([prefabs](../core/prefabs.md#at-spawn-points)). Without one, the server asks:

```odin
@(step="fixed",server)
give_bodies :: proc(seats:^core.Table(inp.Seat,.Read),requests:^spawn.Spawn_Requests) {
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        if core.at(seats,row).body==core.NONE {spawn.spawn(requests,seat,PLAYER_PREFAB)}
    }
}
```

`PLAYER_PREFAB` is the path in the assets of a prefab that carries `multiplayer.Replicate`.
`inp.seat_of(seats,body)` gives the seat of a body. On a client the seat of its own player is the
replica of the one the server made for its connection, its local seat 0; the seats of the other
players are of another end. A client takes only bodies it predicts; `spawn.spawn` on a client is
refused (`spawn.client_spawn`).

## Which connection is a seat

`multiplayer.Connection(seat.peer)` is its connection: pass it as `to=` to `send`. `peer` is 0 for
the seat of this machine.

## Who sees what

`Replicate.audience`: `Near` (connections whose view reaches it; `radius` widens it), `Always` or
`Owner` (the connection of the seat that drives it). Teams, fog of war and what only some players
see are data, like collision layers: `multiplayer.Visibility` on the entity says with `mask` whose
it is, and on the seat of a player says with `sees` what that player sees. A connection gets the
entity when they share a bit; an entity without `Visibility`, or with `mask` 0, asks for none.

```odin
core.add(visibility,flag,multiplayer.Visibility{mask=TEAM_RED})           // only the red team
core.add(visibility,seat,multiplayer.Visibility{sees=TEAM_RED|SPECTATOR}) // what this player sees
```

`multiplayer.view_set(session,connection,position,radius)` sets where a connection without a body
looks from, for `Near`.

## What a client predicts

A client predicts the body it drives, and what that body touches or is joined to while it does;
everything else it shows interpolated, a little in the past, pose and components of one same
instant. `Replicate.predict` keeps an entity predicted always: a ball to intercept.

A spawn that should not wait a round trip (a projectile) is made by the same `fixed` function on
both ends, in the tick of the input that causes it, and marked with the seat that makes it:

```odin
e:=scene.spawn(spawner,ROCKET_PREFAB,at)     // on the server and on the shooter's client
multiplayer.predict_spawn(spawns,e,seat)     // spawns: ^multiplayer.Net_Spawns
```

The replica of the server's takes the one the client made; one the server never makes goes after
`Net_Settings.replication.history_seconds`.

A client acts on its input some ticks later, on both ends alike, as its round trip asks:
`Net_Settings.replication.input_delay` covers the first `cover` seconds of it with delay (at
least `min`), the next `predict` seconds with prediction and the rest with delay again, so a
correction never replays more than `predict`. A fast shooter that wants no delay sets `cover` and
`predict` to -1.

## Who simulates

`Replicate.simulation`: `Server` (the server simulates; its owner predicts it), `Lent` (a client
may take over with `multiplayer.authority_request`; the server gives with `authority_grant`),
`Each` (only its creation travels).

## Pitfalls

- A seat is replicated to every client; its `player` is local and never reaches the others.
- The server decides the body of a player: a client that drives something else is corrected.
- Per-player state (score, team) belongs in a `replicated` component of the body prefab, or
  `replicated="owner"` when only that player needs it.
