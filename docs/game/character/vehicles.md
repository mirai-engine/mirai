# Vehicles, mounts and turrets

A boat, a submarine, a hovercraft or a turret is not a character: it is a body that steers itself.
Plugin `vehicles` in `project.mirai` (it brings `physics`); import `veh
"plugins:vehicles/runtime"` beside `inp "mirai:engine/input"`. A player gets into one through a
`inp.Mount`, which is in the engine: a bench a passenger sits on needs no plugin.

## Map

- The hull, its thrusters and its turn: [A vehicle](#a-vehicle).
- A turret ring and a barrel that follow the look: [Aim](#aim).
- Entering, driving from inside, getting off: [Mounts](#mounts) and [Entering](#entering).
- The camera while it drives: [Camera](#camera). An AI at the helm: [AI](#ai).

## A vehicle

The root entity is a dynamic `phys.Rigid_Body` with its `Collider`s, a `veh.Vehicle` and a
`inp.Move_Input` whose `frame` is `Body`: its `move` is in its own axes (x right, y up, z back),
each -1 to 1. Its children with a `veh.Thruster` push it.

```json
{"method":"scene.write","params":{"root":"Boat","entities":[{"components":{
   "Rigid_Body":{"type":"Dynamic","mass":2500},"Collider":{"kind":"Box","size":[0.9,0.4,2.2]},
   "Vehicle":{"smoothing":0.15,"facing":"Steer","turn_speed":0.8,"upright":2},
   "Move_Input":{"frame":"Body"}},
 "children":[{"name":"Propeller","transform":{"position":[0,-0.3,2.2]},
   "components":{"Thruster":{"force":15000,"top_speed":9,"axis":"Throttle","medium":"Fluid"}}}]}]}}
```

- `Thruster` pushes along its own -Z at its place by the control of its `axis` (`Throttle`,
  `Steer`, `Rise`); the force fades to nothing at `top_speed` along where it pushes, so that is
  the speed it reaches against little drag. `steer_angle` turns it with the steer, as a rudder.
  `medium` `Fluid`: it pushes only while its place is in a `phys.Fluid` (a propeller out of the
  water gives nothing).
- `Vehicle.facing`: `Steer` turns it at `turn_speed` for a whole steer, `Look` turns it toward the
  yaw of its look (a hovercraft that faces the camera), `None` leaves turning to its thrusters.
  `upright` is a spring that keeps it level; 0 lets it roll.
- Floating is physics: a hull lighter than the water it can displace floats
  ([swimming](swimming.md#floating-things)); a submarine as heavy as the water it displaces holds
  its depth, and `Rise` thrusters move it up and down.
- The actions `veh.Vehicle_Action` (`throttle` W/S, `steer` A/D, `rise` Space/C, the left stick
  and the triggers) are in their own input context, `veh.VEHICLE_CONTEXT`: they take those keys
  from walking only while the seat is in it.

## Aim

`veh.Aim` turns its entity about its up (`Yaw`) or its right (`Pitch`) toward where the body it
hangs from looks, at `speed` within `min` and `max` (both 0: no limit). A ring with a yaw `Aim`
and a barrel under it with a pitch `Aim` make a turret. `Aim.angle` is where it points now, of
the tick on every end: aim a shot from it, not from what is drawn. The `Aim` owns the rotation of
its entity, so orient the turret with its parent.

## Mounts

A `inp.Mount` is a place a body rides while its seat drives something else:

- `drives`: what the seat drives from here (the hull, the turret base); none: the mount itself, a
  passenger seat.
- `input_context`: the context the seat is in while it rides (`veh.VEHICLE_CONTEXT` at a helm).
- `hide`: the rider is not drawn; `keep_input`: its own abilities still read the seat's actions.
- `exits`: up to four places in the mount's axes, tried in order; a probe of the world finds the
  first with room. `rider` is written by the input library only.

`inp.mount(seat_requests,seat,mount)` and `inp.dismount(seat_requests,seat)` change who rides and
drives together, on a server or a game alone (a client is refused with
`input.server_decides`). The rider hangs from the mount at its place and is `core.Carried`:
physics makes no body of it and the network sends no pose of it; every end derives that from
`Mount.rider` and `Seat.body`. A destroyed mount leaves its rider where it was, and a player that
disconnects gets off. `inp.Mount_Events` says who mounted and dismounted, for sounds and doors.
Refusals are problems: `input.mount_taken`, `input.mount_blocked` (no exit with room),
`input.not_riding`.

## Entering

Who may enter and how is the game's. With an `Interactable` on the mount:

```odin
@(step="fixed",server)
boat_seats :: proc(
    used:core.Ref(scene.Interaction_Events),mounts:^core.Table(inp.Mount,.Read),
    seat_state:core.Ref(inp.Seats),seats:^core.Table(inp.Seat,.Read),
    actions:inp.Input_Of(Action),requests:^inp.Seat_Requests,
) {
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        riding,_:=inp.mount_of_driven(mounts,core.at(seats,row).body)
        if riding!=core.NONE && inp.seat_pressed(actions,seat,.Use) {inp.dismount(requests,seat)}
    }
    for event in used.items {
        if event.kind!=.Completed || !core.has(mounts,event.target) {continue}
        seat:=inp.driver_of(seat_state,event.actor)
        if seat!=core.NONE {inp.mount(requests,seat,event.target)}
    }
}
```

## Camera

The camera of a body is its active `render.Camera` (else the first), and what rides it is not
searched: the rider's own camera never becomes the boat's. A `Camera_Follow` with `frame`
`Heading` stays behind the hull as it turns; `Rotation` rolls with it (a turret's sight). Changing
the body a seat drives blends the view into the new camera (`cam.BODY_BLEND`) instead of cutting.
A camera under a turret without a `Camera_Follow` looks with it: the look action turns the look,
and the `Aim`s follow at their speed.

## AI

An AI writes the same input as a seat: `inp.move_set(moves,seat_state,boat,veh.move_toward(pose,
point))` steers toward a point and slows within `arrive` meters of it.

## Pitfalls that fail silently

- `Move_Input.frame` left at `View`: the seat writes a world move toward its camera and the
  vehicle actions write nothing.
- A mount without exits drops its rider where the mount is; exits inside the hull are blocked.
- A `Thruster` that is not under the `Vehicle` entity pushes nothing.
