# Lag compensation

A client shows what it does not drive interpolated, a little in the past, so a shot must be judged
where the shooter saw the target: the server rewinds the targets.

Put `multiplayer.Rewind` on what can be hit (the bodies of players). The server then remembers the
pose of each such entity every tick; more entities than it can remember are reported as a problem.

```odin
import net_phys "plugins:physics_multiplayer/runtime"   // joins physics and multiplayer by itself

@(step="fixed",server)
shoot :: proc(inputs:core.Ref(multiplayer.Remote_Inputs),history:^multiplayer.Rewind_History,
    physics:core.Ref(phys.Physics_State),marked:core.Read(multiplayer.Rewind),
    time:core.Time /* , the shooter's seat and body, the aim */) {
    connection:=multiplayer.Connection(seat.peer)         // the shooter's seat
    tick,ok:=multiplayer.rewind_tick(inputs,connection,time)
    if !ok {return}                                       // no input yet: judge in the present
    hit,found:=net_phys.rewind_raycast(history,physics,marked,tick,origin,direction,100,shooter)
}
```

- `rewind_tick` gives the tick, with fraction, the shooter showed the others at, never older than
  its `max_seconds` argument. The server corrects a client that claims more past than its link can
  explain.
- `rewind_raycast` tests the ray against the colliders of every entity with `Rewind` where each was
  at that tick, and gives the nearest hit; nothing in the world moves back. For another test,
  `multiplayer.rewind_pose(history,target,tick)` gives the pose (the one before a teleport), and
  `phys.raycast_at` a ray against one entity as if it were at a pose.
- `Net_Settings.rewind_entities` is how many entities with `Rewind` a tick remembers.

## Pitfalls

- It remembers the pose of the entity, not of its bones.
- What the shooter's client predicted (what it was pushing, `Replicate.predict`) was on its screen
  in the present, not at the rewound pose: judge it in the present.
- Not for your own body: the client predicts it, the server judges it as it is.
