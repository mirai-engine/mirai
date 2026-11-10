# Persistent physics fields

`plugins/physics_fields` is optional, has Runtime and Editor and depends on `physics` alone: a
field breaks what is breakable without knowing `destruct`. It declares `Physics_Field` and a fixed
step that emits requests to [physics](../../mirai-physics/references/engine.md#requests). It does
not import the low-level model nor has another implementation of falloff or queries.

## Component

`Physics_Field` is plain data (start from `PHYSICS_FIELD_DEFAULT`). The entity needs a Transform
and can have a Parent: transforming the parent moves the region on later ticks.

- It emits requests while the component is on: `core.disable` and `core.enable` turn it off and on
  without losing its values.
- Sphere, Box or Plane; Plane is a box whose local +Y face is the plane, with the maximum weight
  on it and falling with depth. The radius is multiplied by the largest absolute scale axis; the
  box and the plane, by each axis.
- Radial force (negative attracts; in Plane, along the plane's normal) or directional, in N, with
  the `Radial_Falloff` curve of the
  [physics API](../../mirai-physics/references/physics.md#volume-forces), its range and a
  noise fixed to the field's frame that scales the force of each body by its center of mass.
- `strain` (N·s per second) is independent of `force` and is multiplied by dt; `weakening`
  accumulates rest strain without releasing pieces, and without it the strain is external damage.
- `filter` is the `Query_Filter` of the
  [queries](../../mirai-physics/references/engine.md#queries): by default all object categories;
  `ignore_body` excludes that body from force and strain.
- The range, the noise and the plane's weight by depth apply to the force: the strain uses the
  region's sphere or box with the curve over the full range, because the replicated fracture
  event carries neither range nor noise.
- No graphical field expressions, boolean compositions or structural solver.

## Fixed step

`physics_fields_step` runs in `fixed`, before `physics_prepare`.

- The force is a continuous request per tick to the volume forces of physics, which detect the
  shapes, deduplicate bodies and evaluate the weight at their center of mass, without the shape
  limit of the overlap helpers.
- The strain is one `strain_region` request with the same region and filter: physics gives it,
  after the step, to each body of the breakables whose pieces the filter sees, but
  `ignore_body`, also when it is a detached fragment. Cosmetic debris receives no strain, and it
  does not depend on the force impulse.
- On a network client it emits no strain (the server decides it, by the role of `core.Network`);
  forces continue on clients for their prediction. The stable path reuses the request capacity once
  warmed up.

## Selection preview

- In Edit and Simulate (also paused), selecting a `Physics_Field` shows its volume and direction
  over the scene, even with the grid hidden, with the same composition of hierarchy, scale and
  direction as the fixed step. Simulate uses the shown world without modifying it.
- The arrows follow the direction of the force (reversed if negative) and their length indicates
  direction, not newtons. A field that is off looks gray, and its arrows too with zero force.
- The preview is removed on deselecting or starting Play. `Physics_Field_Preview` lives only in the
  editor world with preallocated vertices and is rebuilt when selection, world, fields, transforms
  or parents change; shapes that do not fit are omitted whole and counted.

## Verification

- `plugins/physics_fields/runtime` (plugins collection):
  `persistent_fields_transform_filter_and_accumulate_strain_independent_of_force`,
  `steady_persistent_fields_reuse_request_capacity_and_disabled_fields_do_nothing`,
  `plane_and_noise_fields_send_their_region_direction_range_and_noise`.
- `plugins/physics_fields/editor` (plugins collection):
  `selected_physics_fields_preview_world_regions_force_direction_and_parent_changes`,
  `physics_field_preview_reuses_vertices_without_allocations_and_omits_incomplete_regions`,
  `a_plane_field_preview_crosses_its_plane_face_and_points_along_its_normal`.
- `plugins/physics/runtime/sim`:
  `a_strain_over_a_region_reaches_each_body_of_the_breakables_its_filter_meets`.
- Presentation: generate and build the demo world and verify by API and capture the selection of a
  field with graphics validation; the field stations of `physics.scene` enable them by input or
  API. The effects of the forces are verified in their owner package.
