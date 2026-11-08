# Players, seats and visibility

A seat (`inp.Seat`) is one player, of this machine or of a connection (`peer`). The server makes
one per connection and feeds it the actions its client sent, never its devices; read them like any
seat (`inp.Input_Of(Action)`, `inp.pressed`). A seat that leaves waits, off, for the same player to
connect again; the player's secret is kept in their profile, so a returning client recovers it.

## Bodies

A seat drives a body that carries `inp.Drivable`. With `Spawn_Settings.players` on in
`settings.mirai`, the `spawn` plugin gives each seat, local or remote, the prefab of a
`Spawn_Point` and destroys it with the seat. Without it, the server asks:

```odin
@(step="fixed",server)
give_bodies :: proc(seats:core.Read(inp.Seat),drivables:core.Read(inp.Drivable),
    requests:^spawn.Spawn_Requests) {
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        if inp.body_of(drivables,seat)==core.NONE {spawn.spawn(requests,seat,PLAYER_PREFAB)}
    }
}
```

`PLAYER_PREFAB` is the path in the assets of a prefab that carries `multiplayer.Replicate`.
`inp.seat_of(drivables,body)` gives the seat of a body. A client takes only bodies it predicts;
`spawn.spawn` on a client is refused (`spawn.client_spawn`).

## Which connection is a seat

`multiplayer.Connection(seat.peer)` is its connection: pass it as `to=` to `send`, or to
`relevance_set`. `peer` is 0 for the seat of this machine.

## Who sees what

`Replicate.audience`: `Near` (connections whose view reaches it; `radius` widens it), `Always`,
`Owner` (the connection of the seat that drives it) or `Custom`. For `Custom` the server says
which connections see an entity:

```odin
@(step="fixed",server)
reveal :: proc(session:^multiplayer.Net_Session,e:core.Entity,peer:u64) {
    multiplayer.relevance_set(session,e,multiplayer.Connection(peer),true)   // false hides it
}
```

A new entity or connection starts hidden. `multiplayer.view_set(session,connection,position,
radius)` sets where a connection without a body looks from, for `Near`.

## Who simulates

`Replicate.simulation`: `Server` (the server simulates; its owner predicts it), `Lent` (a client
may take over with `multiplayer.authority_request`; the server gives with `authority_grant`),
`Each` (only its creation travels).

## Pitfalls

- A seat is replicated to every client; its `player` is local and never reaches the others.
- The server decides the body of a player: a client that drives something else is corrected.
- Per-player state (score, team) belongs in a `replicated` component of the body prefab, or
  `replicated="owner"` when only that player needs it.
