# Plugin `physics`: the integration

`plugins/physics/runtime` (`phys "plugins:physics/runtime"`) bridges the data world and the solver
(`plugins/physics/runtime/sim`; [physics.md](physics.md), [character.md](character.md)). Games
never import `sim`. Destruction is [destruct](engine-destruct.md); editor tools live in
`plugins/physics/editor`. Component defaults/constructors live in `components.odin` and
`engine.describe`.

Rows own **existence** (`Rigid_Body`, `Collider`, `Character`, `Joint`); `sim.World` owns **pose**
(`Rigid_Body` and `Character` lock `core.Transform`; move via requests). Lone/compound `Collider`s
follow their entity's transform.

## Components

- `Rigid_Body`: `Static`/`Kinematic`/`Dynamic`, `mass` (0 = from collider density), damping,
  `gravity_scale`, per-axis `locks`, `bullet`.
- `Collider`: shape, surface, collision ([fields](#collider-fields)); constructors `collider_*`.
- `Character`: moves entity's `Capsule` `Collider` (feet at `Transform`, `+Y` vertical, `-Z` yaw;
  missing capsule -> `physics.character_capsule`, full -> `physics.characters`). Changing capsule
  size, `mass` or `step_height` recreates it; `up_speed`, `push_force`, `density` and filters update
  in place.
- `Character_Move` (`shared`): per-tick drive written by `locomotion` (or game mode), consumed by
  `physics_step`.
- `Character_State` & `core.Motion`: simulation outputs (support, ground normal/velocity/
  `ground_turn`, `wall_normal`, fluid state, velocity; restored on save; callers add `ground_turn`
  to yaw each tick). `core.Vertical` (`transient`) mirrors character up for cameras/gameplay.
- Disabling `Rigid_Body`/`Collider`/`Character` removes it from `sim.World` while retaining
  components and `core.Motion`; re-enabling rebuilds at current `Transform`/velocity.
- `Fluid` (`replicated`): `Plane`/`Box`/`Outline` `Volume` with density/current (zero density = dry
  box overriding lower `priority`).
- `Force_Field`: applies `apply_area` each tick in `force_fields_step` across its `Volume`.
- `Joint` & `Joint_State` (`replicated`): entity joining `a` (default parent) and `b` (default
  world); presets `joint_{fixed,spherical,revolute,prismatic,distance}`.
- `Body_Twin` & `Collider_Cuts`: portal twin colliders and box cutouts synced in `physics_twins`
  (errors: `physics.twin`, `physics.cuts`).

## `Collider` fields

- Static unless on a `Rigid_Body` entity or descendant. No physical material asset (friction =
  geometric mean, restitution = max; Heightfield cells use `Collision_Settings.surfaces` per
  material). Character capsules have zero friction (controlled by drive traction).
- `COLLIDER_DEFAULT` uses `Default` preset; editor/API adds `Auto` on entities with `Mesh_Renderer`,
  `collider_character()` with `Character`, and `collider_auto()` on placed meshes only when the
  mesh stores source colliders (`host.assets_mesh_collides`).
- `kind`: primitives, `Hull` (supports multi-piece `host.assets_collision_hulls`), `Mesh`,
  `Heightfield` (static only; compact `host.assets_heightfield` + holes/disabled borders),
  `External` (plugin-supplied shape, e.g. `shapes`), and `Auto` (authored mesh/hulls if stored, else
  triangles when static or cached convex decomposition `asset.mesh_collision_pieces` when moving;
  unreadable -> `physics.collider_mesh_unreadable`).
- Scales by abs world scale (negative scale mirrors geometry/normals; mirrored heightfield ->
  `physics.collider_mirrored`; sheared transform -> `physics.collider_sheared`; non-finite ->
  `physics.transform`). `convex_radius` must stay within shape bounds (`physics.convex_radius`).
- `group` entity suppresses self-collision (remapped across prefabs/saves/net). `drag`,
  `surface_speed` (conveyor), `one_way` (`+Y`) and `dominance` update via `shape_set_surface`
  without rebuilding shapes or dropping contacts.

## Collision: categories and presets

Two colliders interact when each `belongs` to a category the other `collides` with (`sensor` reports
overlaps without blocking). Named ids `Collision_Category` and `Collision_Preset` (`PRESET_CUSTOM`
last) are declared in code (`core/names.odin`) and configured in project `Collision_Settings`:
- Define a category + preset per actor kind in `Collision_Settings` and assign it on prefabs
  (never patch `belongs`/`collides` at runtime). `Collision_Settings` also holds soft `pushes`
  (yielding character/category pairs) and material `surfaces` (invalid -> `physics.collision_*`).
- Filter/preset/group changes update in place (`*_set_filter`, never rebuild). `collision_off`
  disables all collisions and queries.
- Overlaps (`overlap_begin`/`end`): emitted per side for awake non-static pairs; fast bodies
  crossing static triggers emit both with `crossed` (moving triggers require `bullet`).

## Binding and world step

- Static colliders without a `Rigid_Body` attach as shapes on the world static body (`body_of` is
  none; kinematic moves/manipulations/joints promote them to an owned static body).
- `Physics_Settings` fixes capacities at world creation (`hulls`, `meshes`, `heightfields`,
  `events`, `breakables`/`pieces`/`bonds`). `Physics_State` (`copy`/`swap`/`free`,
  `reset="state_reset"`, `shared`) stores `sim.World`, dense `Entity_Map` links, chunk-stamped copy
  state (`state_copy_kept` for history), and XXH3-hashed shared geometry slots (`Collider_Meshes`
  caches per-app mesh data).
- **Zero disk/BVH stalls on ticks:** `.mesh` reads and BVH builds run asynchronously in jobs
  (resimulation waits; bodies wait in reconciliation while load stays busy).
- `physics_prepare` creates `sim.World` and binds `World_Queries`. `physics_step` (`fixed`
  `simulate`):
  1. Clears events.
  2. Reconciles changed tables/assets/epoch/`Collision_Settings` (transform-only changes walk
     touched rows; throttled to `BODIES_PER_TICK` deterministic count, static first; pending target
     -> `physics.request_body`).
  3. Syncs `Fluid`s (`physics.fluid*`), applies `Body_Requests` and `Joint_Requests`.
  4. Feeds `Character_Move` to characters.
  5. Steps `sim.World` when `Time.playing` and writes back awake/changed `Transform`, `core.Motion`
     and `Character_State` (Editor loop only syncs `World_Transform`).
  6. Forwards `Physics_Events`.
- Rejections emit entity problems (`physics.{bodies,shapes,geometry_budget,collider_*,world}`).
  Swapping an identical generated geometry ID preserves shapes and warm-start contacts. Inspect via
  `collider_ready` and `geometry_budget`.

## Gravity

Reads `engine/volume` `Gravity` (`gravity.odin`): unbounded downward fields form world gravity;
bounded/planetary `Center` fields update awake bodies in parallel via `sim.world_set_body_gravity`
(waking sleeping bodies when fields change). Query with `gravity` / `gravity_of_entity`. Use
`Force_Field` or `apply_area` for mass-dependent forces.

## Requests

- **`Body_Requests`:** `move_kinematic`, `set_velocity`, `apply_impulse`, `apply_force`/`torque`,
  `apply_area` (volume force/impulse/velocity change, affects characters as `launch`; invalid ->
  `physics.request_area`), `strain_area` (strains breakables post-step). Teleports go solely through
  `core.place` (`physics_places`, sets `core.jump`). Invalid requests emit `physics.request_*`.
- **Manipulation:** `manipulation_target` pulls dynamic bodies via bounded soft spring
  (`PULL_WEIGHTS`) or steers static/kinematic/`follow` bodies kinematically (`manipulation_end`
  restores type/velocity; operates on `manipulation_owner`, not characters). `scene.Section_Held`
  holds bodies kinematic at rest until their section loads (`physics_section_holds`).
- **`Joint_Requests`:** configures joints, local/world drives, axis locks and `repair_joint` in
  order (repeating budgets keeps warm start; errors -> `physics.joint_request`, `physics.joints`).

## Locomotion

Optional `locomotion` plugin (`Character` + capsule `Collider` + `Walk`/`Swim`/`Fly` +
`Locomotion_State`, optional `Parkour_State`):
- **Modes (`Locomotion_Mode` named ids):** `MODE_FALLING`, `MODE_WALKING`, `MODE_FLYING`,
  `MODE_SWIMMING` + custom game modes (`@(name_requires="...")`), switched via `set_mode` in
  `Locomotion_Requests` (missing component -> `locomotion.mode_component`).
- **Walk / Jump / Parkour (`moves.odin`):** ground/air drive, sprint (`sprint_default` / 60 deg
  forward cone / `backward_slowdown`), coyote-time jump + variable rise hold (`jump_rise`),
  `Tactical_Sprint` (energy/ramps/grace), `Ledge_Jump` (`ledge_drop_ahead` forward boost without
  spending energy), and `Mantle` (`ledge_find` + `Override` layered move warped by
  `animation_physics`).
- **Fly & Swim:** 3D flight without gravity; swimming enters/exits at `Swim.depth` (`Float` at
  surface, 3D underwater with buoyancy/current, surface jump-out `Override`).
- **Layered moves (`Layered_Move`):** `add_move`/`remove_moves` (`Additive` velocity or `Override`
  replacing gravity/ground; carries animation root motion; bad request -> `locomotion.request`).
  Custom game modes write `Character_Move` before `locomotion_step`, which calls `layers_apply`.

### Own pace

With `core.Own_Pace`, `locomotion_move_paced` converts velocities to own time, steps at `dt * pace`,
and rescales drives, `launch`, forces (`pace^2`) and `Character_Move.pace` back to world time
without velocity jumps on pace changes.

### What drives it

Seats write `Move_Input` via `camera_drive`; AI/scripts call `locomotion.drive` (world velocity +
facing, overrides seat movement while preserving buttons). `set_speed_scale` scales top speed;
`set_suspended` freezes drive/gravity/collision for `core.place` animation. Actions: `move`/`look`
(`engine/input`; wrong type -> `camera.seat_actions`), `jump`/`sprint`/`crouch` (`locomotion`).

## Physics step outside the loop

`step_world(w, app, dt)` runs `physics_prepare` + `physics_step` on a `core.World_Ref` without
gameplay/network (`dt=0` reconciles only).

## Events (`Physics_Events`)

Cleared/filled each step and read in `react` stage. Names body/collider entities (`NONE` if
unowned; detached destructible -> group entity). Bounded box/sphere/outline `Volume`s without a
collider/body become static `Trigger` sensors (`zone_collider`, `zone_pieces`) emitting standard
overlaps.

## Queries

Read-only on `core.Ref(Physics_State)` (returns empty when `!ready`; starting inside returns
distance 0, zero normal): `raycast`, `raycast_all` (up to `QUERY_HIT_CAPACITY`), `sweep`,
`sweep_all`, `overlap_{sphere,box,capsule,cylinder}` (`complete` flag), `closest_point`,
`body_bounds`, `collider_raycast`, `fluid_at`, `fluids_in`, `fluid_bodies` (presentation only),
`static_triangles` and `static_changes` (`Static_Cursor` with epoch overflow for navmesh).
`query_hits(layers, include_sensors)` or collider-specific `Query_Filter`. `physics_prepare`
publishes `core.World_Queries` for physics-agnostic plugins; `collider_debug_draw`/`collider_bounds`
draw editor wireframes.

## Owned bodies

Libraries (`foliage`) create entity-less static bodies via `owned.odin` (`Body_Owner`,
`owned_body_create`/`place`/`destroy`, `owned_shape_create`/`destroy`, shared scaled `owned_hulls`
with `Shape_Desc.scale`, hit lookup via `owned_body_of`/`owned_shape_user`, `body_info`).
Destructibles use `breakable_*` (`breakables.odin`). Offline bakes use `state_make` + `simulate`.

## For networking and saves

- `core.Motion` persists/replicates velocities and awake state (`bodies_group` only with
  `Pose_Target`).
- `core.Pose_Target` (`targets.odin`, `physics_pose_targets`): snaps `placed` poses, steers non-
  character `follow` bodies kinematically (shared hold with manipulation, target wins), and pins
  followed characters at target pose/velocity (`step_followed`).
- `core.Simulation_Hash` (when `Sync_Check.on`) compares runs. `proxies.odin` (`proxy_set`/
  `remove`) links external bodies (destructibles). Replicated `Joint`/`Joint_State` rebuild on
  config/frame changes while motor updates keep warm starts.

## Editor part

`plugins/physics/editor` provides inspector preset/settings UI (editing a preset field auto-converts
to `Custom` in one undo step), `physics.collision.*` API, auto-colliders on Character/meshes,
Simulate gizmo drag, `physics.settle`, **Drop** tool (`P`, drops `Auto` meshes until Confirm or
Cancel), selection collider wireframes, `collision` / `collision.<category>` view modes, and fluid
guides.

## Changing these libraries

Follow [library invariants](../SKILL.md#library-invariants). Sync `Physics_State`/body-link changes
with `destruct`/`destruct_multiplayer`, and query changes with `core.World_Query`.

## Verification

- Tests: focal suites in [SKILL.md](../SKILL.md#verification), plus `templates/game` headless run,
  demo `destruction` and `control` scenes (captures + logs), and
  [multiplayer verification](../../mirai-networking/references/multiplayer.md#verification).
