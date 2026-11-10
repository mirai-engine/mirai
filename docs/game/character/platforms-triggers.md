# Moving floors, triggers and overlaps

## A platform that carries the character

A platform is a kinematic body: `phys.RIGID_BODY_KINEMATIC` and a `Collider`. A character
standing on it travels with it and turns with it. Request its pose every tick:

```odin
@(component)
Lift :: struct {from,to:[3]f32, seconds:f32}

@(step="fixed")
game_lifts :: proc(lifts:core.Read(Lift),bodies:^phys.Body_Requests,time:core.Time) {
    for row in 0..<core.count(lifts) {
        lift:=core.at(lifts,row)
        along:=0.5-0.5*math.cos(f32(time.seconds)/lift.seconds*2*math.PI)   // 0 to 1 and back
        phys.move_kinematic(bodies,core.entity_at(lifts,row),lift.from+(lift.to-lift.from)*along)
    }
}
```

`phys.move_kinematic(bodies,e,position,rotation)` takes a rotation too (default none). The scene
entity has a mesh, a `Collider` (`phys.collider_box({0.5,0.5,0.5})` on a scaled cube fits it)
and `Rigid_Body` set to `phys.RIGID_BODY_KINEMATIC`. A conveyor belt needs no code:
`Collider.surface_speed` carries what stands on it.

- `phys.Character_State` says what the character stands on: `standing`, `ground_velocity`,
  `ground_turn`. With `move_relative_to=.Game`, add `ground_turn` to the `look_yaw` you write, or
  the body rides the platform without turning with it.

## Trigger zones

A zone is an entity with a `Collider` whose `preset` is `trigger` (`phys.PRESET_TRIGGER`): it
blocks nothing and reports what overlaps it. Scale the entity to size it. `Heal_Zone` is a
component of the game, `@(component) Heal_Zone :: struct {amount:f32}`.

```json
{"method":"scene.add","params":{"name":"Heal zone","scale":[4,2,4],
 "components":{"Collider":{"preset":"trigger"},"Heal_Zone":{"amount":10}}}}
```

Read the events in `stage="react"`; each pair gives one event per side:

```odin
@(step="fixed",stage="react")
game_zones :: proc(zones:core.Read(Heal_Zone),players:core.Read(Player),
                   events:core.Ref(phys.Physics_Events),healths:^core.Table(Health)) {
    for event in events.overlap_begin.items {
        if !core.has(zones,event.collider) || !core.has(players,event.other) {continue}
        zone,_:=core.get(zones,event.collider)
        if health:=core.edit(healths,event.other);health!=nil {health.hp+=zone.amount}
    }
}
```

`event.collider` is the entity of the collider on this side and `event.entity` its body (the same
unless the collider is a child of a body); `other` and `other_collider` are the other side's.
`phys.Physics_Events` also has `overlap_end`, `contact_begin` and `contact_end` (a solid touch,
with `point`, `normal`, `impulse`), `sleep`, `wake` and `joint_break`.

## Who is inside now

Events fire on entry and exit, not every tick. Keep a list or count of occupants from
`overlap_begin` and `overlap_end`, or ask:

```odin
found:[16]core.Entity
filter:=phys.QUERY_FILTER_DEFAULT
filter.overlaps=true                      // a query only sees sensors with this
// physics:core.Ref(phys.Physics_State), a parameter of the step
count,complete:=phys.overlap_sphere(physics,center,2,found[:],filter)
```

`overlap_box`, `overlap_capsule` and `overlap_cylinder` are the other shapes; `complete` is
false if more touched than `found` holds. `phys.raycast(physics,from,direction,max,ignore)`
returns `(hit,ok)` with `hit.entity`, `hit.point`, `hit.normal`.

## Pitfalls that fail silently

- A body that crosses a thin trigger within one tick, and is not a `bullet`, gives no event.
- A `bullet` gives `overlap_begin` and `overlap_end` in the same tick (`crossed`): handle begin
  before end when counting occupants.
- Two static colliders never report each other; a zone over a sleeping dynamic body reports
  only once it wakes (a `Character` never sleeps).
- A new `Collider` blocks (preset `Default`): a zone must be given the trigger preset.
- `PRESET_TRIGGER` sees every category. To see only players, declare a category and a preset in
  code and in `Collision_Settings`, and name it in the zone's `Collider`.
