# Messages between server and clients

For what is not an action or replicated state: an announcement, a purchase, a vote. A `struct` of
plain data declared `@(net_message)` (an `Entity` field must name a replicated entity). A reliable
one larger than a datagram streams in pieces; one the protocol cannot carry is a problem that says
why as the session opens. Movement and buttons are not messages: they travel as the actions of the
seat.

- Only the server sends by default; `from="client"` lets a client send it to the server,
  `from="owner"` only about an entity it owns. `reliable` delivers once and in order.
- `multiplayer.send(outbox,value,about?,to?)`: without `to` a server sends to every connection
  that has `about` (or all), a client to the server.
- A `fixed` function that receives `core.Inbox(T)` reads the messages of type `T` that arrived
  since the tick before, each with its `value`, its `sender` (on a server, the connection) and the
  entity it is `about`.

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
results :: proc(overs:core.Inbox(Round_Over)) {
    for over in overs.items {}   // over.value.winner, on clients
}

@(step="fixed",server)
votes :: proc(votes:core.Inbox(Vote)) {
    for vote in votes.items {}   // vote.value.choice, from vote.sender
}
```

## Arrivals

`multiplayer.Net_Connections` is a `core.Events` of who connected, left or entered, pushed at the
start of each tick: a function that receives it gets each event once, whatever its cadence.
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
