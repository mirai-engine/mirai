# Lag compensation

By default a client shows the other bodies predicted ahead of the server, so a shot is judged in
the present. To judge a shot where the shooter saw the target, show the others interpolated and
rewind them on the server:

```json
{"Net_Settings": {"interpolate_others": true}}
```

Put `multiplayer.Rewind` on what can be hit (the bodies of players). The server then remembers the
pose of each such entity every tick; more entities than it can remember are reported as a problem.

```odin
@(step="fixed",server)
shoot :: proc(inputs:core.Ref(multiplayer.Remote_Inputs),history:^multiplayer.Rewind_History,
    time:core.Time /* , the shooter's seat and the targets */) {
    connection:=multiplayer.Connection(seat.peer)         // the shooter's seat
    tick,ok:=multiplayer.rewind_tick(inputs,connection,time)
    if !ok {return}                                       // no input yet: judge in the present
    position,_,found:=multiplayer.rewind_pose(history,target,tick)
}
```

- `rewind_tick` gives the tick, with fraction, the shooter showed the others at, never older than
  its `max_seconds` argument. The server corrects a client that claims more past than its link can
  explain.
- `rewind_pose` gives the pose of `target` at that tick, interpolated; after a teleport it gives
  the pose before it. Test the shot against shapes you place at that pose; nothing in the world
  moves back.

## Pitfalls

- It remembers the pose of the entity, not of its bones.
- Without `interpolate_others` the rewound pose was never on screen: judge in the present.
- Not for your own body: the client predicts it, the server judges it as it is.
