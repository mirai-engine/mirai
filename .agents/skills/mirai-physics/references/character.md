# Physical character: current behavior

`plugins/physics/runtime/sim/character.odin`. A character is a dynamic body with a capsule along
its [vertical](#the-vertical) that supports itself on walkable ground, climbs steps, pushes and is
pushed; it never teleports to walk. It does not know how to walk, jump or fly: it is driven by a
`Character_Move` written by whoever moves it ([locomotion](engine.md#locomotion) or a game step).
The same `world_step` serves the server, the predicting client and resimulation.

## Data and lifecycle

- `Character_Desc`: capsule (`radius`, `height` from feet to head), `mass`, ground (`max_slope`,
  `step_height`), the force caps (`traction_force` drives against the ground or the air,
  `adhesion_force` keeps the feet on ground that goes down, `push_force` bounds what is passed to a
  dynamic, [push](#push)), `gravity_scale`, the density and `Cd` of its body in a
  [fluid](#in-a-fluid), `up_speed` (how fast its [vertical](#the-vertical) turns), `filter` and
  `user_data`.
- `CHARACTER_DESC_DEFAULT` gives an 80 kg human that pushes a 100 kg box over a floor of friction
  0.6 and not a 200 kg one.
- `Character_Move`: what drives the character from the next step until it is changed.
  - `ground`: a `Drive` (velocity and force cap) relative to the ground and along it, valid while
    supported.
  - `air`: a `Drive` in the world, transverse to its vertical except with `Drive_Vertical`, valid
    in the air.
  - `launch`: m/s added at once; a supported character pushes the ground backwards.
  - `yaw`, the heading around its vertical, measured as a look (-Z at 0), and `flags`: `Airborne`
    (it does not
    support itself even if it could: a jump starting, a flight), `Drive_Vertical`, `No_Gravity` and
    `Float` (in a fluid, it holds the head `float_height` above the surface).
  - A `Drive` without force leaves the velocity as it is. A new character brakes against the ground
    with its traction.
- `Character_State`: what the last step left. Ground flags (`Hit`, `Walkable`, `Standing`,
  `Stale`), body, point, normal, velocity (`ground_velocity`, including that of its surface),
  `ground_surface`, `ground_distance` (feet above the ground; negative if sunk), `ground_turn` and
  the pending instant effect; how much it is in a fluid: `submersion`, `head_depth`, `depth` (above
  the feet), the current and the flags `In_Fluid` and `Underwater`; the wall it leans on
  (`wall_normal`, across its up and out of the wall, and `wall_push`, how fast its drive heads into
  it), found with the ground among what it touches and cannot push; and `up_frame`, the frame of its
  [vertical](#the-vertical).
- `character_landing(physics,e)` (a query of the plugin, not state the step keeps) predicts when a
  `Character` lands and how fast its feet then move down: a sphere a little narrower than the
  capsule, so a wall it brushes is not where it lands, sweeps in `LANDING_SEGMENTS` straight pieces
  the ballistic arc of its velocity under its gravity (that of the body times `gravity_scale`), down
  to `LANDING_REACH` below its feet; the time is along the arc to the first hit. Only who needs it
  asks, while it falls: animation plays its landing marker toward it.
- `Character` (private) gathers the three with the handles of the body and the shape, without
  padding or pointers.

## Lifecycle and reading

- `character_create(w,desc,position,rotation,frame)` receives the position of the feet and the
  rotation, whose +Y is its up, and returns `Character_Handle` (generational, zero is null). It
  returns null if the description is unusable (a capsule that does not fit in the height, a slope
  outside (0, π/2), non-positive mass or radius, negative or non-finite `push_force` or `up_speed`)
  or if `World_Desc.character_capacity` (adds to `Stats.character_capacity_exhausted`), bodies or
  shapes ran out.
- `character_destroy` also destroys the body.
- Reading: `character_state`, `character_move`, `character_desc`, `character_body`,
  `character_shape`, `character_position` (feet), `character_velocity`.
- `character_set_move` changes what drives it; `character_set_desc` changes how it supports itself
  (capsule, mass, `step_height` and filter stay as created); `character_set_filter` changes the
  filter of the capsule and its probes without recreating it. It is supported by and collides only
  with what both block ([pair rules](physics.md#filters)).
- `character_set_position` teleports the feet and keeps the velocity; `character_set_rotation`
  turns it ([vertical](#the-vertical)).
- `character_set_height(w,h,height) -> bool` changes the height with the feet in place (crouching
  and standing). When growing it first tests the new capsule against the world with the character's
  filter; if something touches it (a ceiling), or if it does not fit in that height, it returns
  `false` without changing anything.

## The body

- The capsule measures `height − step_height` and floats: its lower tip stays `step_height` from the
  feet, which are the origin of the body. What the character can climb passes under it without
  touching it; what touches it is an obstacle.
- It has no friction: traction comes from the ground constraint.
- The three angular axes are locked (it stays upright inside the solver), its rotation is
  `up_frame` times the turn of the move's `yaw` (`character_rotation`): its -Z faces the heading
  that the yaw gives to a look. It carries the `Character` flag.
- It sleeps standing still on what rests, out of fluids, with a move that does not drive it, so a
  step writes nothing of it. Another move, a launch, a teleport, a change of its description, an
  awake ground or a change of the world (`grounds_stale`) wakes it.
- `character_set_locks` adds linear locks in world axes, with the meaning of those of a body
  (`Character.locks`, as `Rigid_Body.locks`; its angular ones do nothing): no part of the step moves
  the feet along a locked axis, and its constraint and drive act only along the free ones, so the
  ground drive follows the line the locks leave on the ground. Only a teleport (`core.place`, a pose
  target) changes the locked coordinate, which is how a game moves it to another depth layer.
- In islands it acts as a kinematic: it does not join its island with that of what it touches.
  - Only while it moves (own velocity or drive velocity above `sleep_threshold`, or a launch) does
    it wake what it touches and what it stands on.
  - Standing still, it lets the dynamic it stands on sleep and rests on it as on a static one.
- Its contacts and fattened boxes look ahead the distance it travels in a step, to stop at a wall
  without penetrating it.

## The vertical

- It is character state: `Character_State.up_frame`, a frame whose +Y is its up and around which
  the move's `yaw` turns. It enters the snapshot with the rest of the character.
- At the start of each step it turns toward the opposite of the gravity it feels (that of its body
  through `gravity_scale`, also with `No_Gravity`), at most `up_speed` radians per second, by the
  shortest path (`up_frame_turn`). It follows a slower change without lag (walking around a planet)
  and turns smoothly when crossing from one field to another. Without gravity, or with `up_speed`
  zero, it stays still.
- It does not twist around the up: a yaw that is held follows the same heading over the ground (on a
  planet, a great circle). A frame chosen by the direction of the up does not work: at some point of
  the sphere it would have to turn abruptly.
- The capsule turns around the feet; if the turn takes it out of its fattened box, the box grows in
  the same step.
- Everything is measured against it: probe, step and slope, landing and launching, `ground_turn`,
  flattened contacts, push plane and air drive.
- `character_create` takes the given `frame` turned to the up of the rotation, and the yaw of
  where the rotation's -Z heads in it (`up_frame_yaw`); `character_set_rotation` does the same
  from the frame it has.

## Step

`world_step` runs in order:

1. `characters_update`, before the broad phase.
   - In parallel, per character: turns the vertical, applies the pending instant effect to the
     velocity, takes the ground, decides whether it is supported and chooses the drive (`ground` if
     supported, `air` if not).
   - Then, in slot order: writes state, velocity, gravity scale and body rotation; gives the dynamic
     ground the reaction of a launch and wakes it if the character is supported on it.
2. `characters_prepare`, with the awake bodies already numbered: builds the constraint and flattens
   the capsule contacts of the supported characters.
3. `characters_solve`, serial, twice per substep (with bias and in the relaxation), before joints
   and contacts: non-penetration has the last word over a bounded impulse.
4. `characters_ground`, with the final poses: probes the ground again for each character the step
   moved and leaves it in its state.

### The ground between two steps

- The ground at the end of a step is the one at the start of the next: whoever writes the
  `Character_Move` between the two decides on the same ground the step is going to use.
- At the start, the step probes again only if that ground became stale: an instant effect, a body or
  shape of the world that changed since the last probe (`World_State.grounds_stale`) or the
  character itself (`Ground_Flag.Stale`: just created, teleported or with another height). If not,
  it takes the stored one with the velocity its body has now.
- It is supported when its move is not `Airborne`, it was not launched upward, the ground is
  walkable and at most `step_height` away, and it was already supported or is descending onto it
  (lands). It leaves it when the ground goes away, when it is launched upward or when its move is
  `Airborne`.

### Ground probe

- A sphere 2 cm thinner than the capsule goes down its axis from its lower end to `step_height`
  below the feet (plus what it falls in the tick).
- The hit counts as ground only if it is at most `step_height` (plus `LINEAR_SLOP`) above the feet.
  The fallback ray, the same.
- If the hit normal exceeds `max_slope` (an edge or a steep face), a ray reads the neighboring face
  on the outside: if it is walkable, it is the edge of a step. If the hit is no good (a step that
  is too high, a steep face or an overlapped sphere), a ray along the axis looks for the floor.
- With no floor and not rising, a capsule that touches faces too steep to stand on whose normals
  differ and add up to walkable ground (a V, two rocks) stands where its feet are: it cannot slide
  off. The contacts are read in `characters_prepare`, before flattening changes their normals.
- The ground velocity is that of its body at the point plus the tangent part of the shape's
  `surface_speed`: a belt carries the standing character at its velocity.
- A `one_way` shape lets the capsule pass from below or from the side; the probe finds it from above
  like any ground.

### Instant effects

`character_launch` adds or replaces the velocity in the next step (knockback, trampoline); if it
pushes upward, the character leaves the ground in that tick. Radial impulses go through that same
effect and respect mass unless a velocity change is requested. A directional or radial force
accumulates in the body for one tick; the support constraint keeps its own adhesion and traction.

### Constraint

- **Supported** (`Standing`):
  - Along the ground normal it holds the height of the feet. Below, it pushes like a soft contact
    (the stiffness of statics): it climbs steps with no residual impulse. Above, it lets the
    distance close in the substep and pulls down with up to `adhesion_force`: it keeps the feet on
    steps and slopes that go down.
  - In the tangent plane it brings the velocity relative to the support point to that of the
    `ground` drive.
  - Both impulses are applied opposite to the ground body at the support point: the character
    pushes what it stands on and travels with platforms that move and turn (the target includes the
    half-step centripetal term).
  - The body faces the move's `yaw` with its -Z and nothing else. The ground turn stays in
    `ground_turn`;
    whoever writes the move adds it to the yaw every step so that body, walk and camera turn
    together. If it does not add it, the character travels with the platform without turning.
- **In the air**: it brings the velocity transverse to its up (or the three axes with
  `Drive_Vertical`) to that of the `air` drive with its cap; without force it does not touch the
  velocity.
- The accumulated impulses restart in each substep: there is no warm starting or solver state to
  keep.

### Push

- In `characters_prepare`, the capsule contacts with dynamics (also other characters) that have a
  point closer than `LINEAR_SLOP` give a push direction: the normal toward the other body,
  flattened if supported and projected onto the drive plane. `CHARACTER_PUSHES` fit; one more is
  averaged with the most similar.
- In each pass, the part of the drive impulse along each direction is cut to `push_force × h`;
  stepping aside or sliding along the body does not change. No effect if `push_force` is zero or not
  less than the drive force of the tick.
- The contact is still one between two bodies with their real masses: a collision transfers the
  character's momentum and a load resting on top is held by the ground constraint. The cap bounds
  the sustained effort, not the collision.
- Two characters pushing each other brake with their caps: the one with more `push_force` wins. If a
  [push rule](physics.md#contact-rules) bounds their contact below what they push, they yield and
  pass through each other (teammates, a crowd) and end up separated.
- **Flattened contacts**, in a supported character:
  - A capsule contact whose normal would lift it (component along the up between 0.05 and 0.95)
    becomes transverse to it and its separation is scaled.
  - A nearly vertical contact under the capsule also becomes horizontal if its point is more than
    `step_height` above the chosen ground (the edge of a step barely higher than allowed).
  - The capsule behaves like a cylinder: a step 1 cm higher than `step_height` or a steep ramp
    brakes it like a wall instead of climbing onto it.

### In a fluid

- Its volume is that of its body, the mass over its density (985 kg/m³ by default, a human), not
  that of the capsule it collides with. The submerged part is that of a vertical capsule from the
  feet to the head, with the radius of its own, under the fluid spans of its column, in closed form.
- Buoyancy at its center of mass (the angular axes are locked), the damping of the waterline and
  drag with its `Cd` and the area that capsule shows to the flow, by the submerged part: it walks
  slower in water up to the waist and the fall into water is slowed.
- `Float`, outside support: an implicit spring toward the height that leaves the head
  `float_height` above the surface, with the softness of contacts and `adhesion_force` as the cap.
  Only in the pass with bias: it has no rigid part for the relaxation to undo.
- The end of the step leaves in its state the depth of the head (`fluid_sample` over it; without
  fluid in its column, `-max(f32)`), that of the water over the feet and the submerged part. Oxygen
  or any similar rule belongs to the game.

## Snapshot and determinism

Characters are a block of the snapshot and enter `world_hash`, with their counters and
`grounds_stale` in `World_State`. Restoring in the middle of a jump and repeating the same moves and
calls reproduces the trajectory bit for bit, with any number of workers.

## Known limits

- A fluid measures along the world +Y: surface, depth, buoyancy and the submerged capsule.
- An orbiting or rotating planet is a moving reference frame: the character does not follow it.
- A drive that replaces the velocity on the three axes (a locomotion dash) floats in a straight
  line: it does not follow the terrain.
