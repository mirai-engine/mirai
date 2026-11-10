# Messages between server and clients

For what is not an action or replicated state: an announcement, a purchase, a vote. A `struct` of
plain data no bigger than `multiplayer.EVENT_BYTES`, or `multiplayer.send` does not compile (an
`Entity` field must name a replicated entity). Movement and buttons
are not messages: they travel as the actions of the seat.

- Only the server sends by default; `from="client"` lets a client send it to the server,
  `from="owner"` only about an entity it owns. `reliable` delivers once and in order.
- `multiplayer.send(outbox,value,about?,to?)`: without `to` a server sends to every connection
  that has `about` (or all), a client to the server.
- `multiplayer.Net_Events` has, at the start of each tick, the messages that arrived since the tick
  before: read it in `fixed`.

```odin
@(net_message,reliable)
Round_Over :: struct {winner:u32}
@(net_message,from="client",reliable)
Vote :: struct {choice:u8}

@(step="fixed",server)
round_end :: proc(outbox:^multiplayer.Net_Outbox) {
    multiplayer.send(outbox,Round_Over{winner=2})
}

@(step="fixed")
messages :: proc(events:core.Ref(multiplayer.Net_Events),network:core.Ref(core.Network)) {
    for item in events.received.items {
        if over,ok:=multiplayer.event_read(item,Round_Over);ok {}   // on clients
        if vote,ok:=multiplayer.event_read(item,Vote);ok && network.role==.Server {} // item.sender
    }
}
```

## Arrivals

`multiplayer.Net_Connections` lists, at the start of each tick, who connected, left or entered.
`Entered` is when a connection is in the world; messages sent to it before are not heard.

```odin
@(step="fixed",server)
arrivals :: proc(connections:core.Ref(multiplayer.Net_Connections),outbox:^multiplayer.Net_Outbox) {
    for event in connections.events.items {
        if event.kind==.Entered {multiplayer.send(outbox,Round_Over{},to=event.connection)}
    }
}
```

## Pitfalls

- A tick that repeats after a correction has the messages it had, and `send` returns false in it:
  what a message makes outside the world (a sound, a counter in a host storage) checks
  `time.resimulating`.
- A type that is not a `net_message` is not sent: the problem `net.event`.
- A message about an entity that is not replicated is the problem `net.event_about`.
- A message from another world (before the client entered a new scene) is discarded.
