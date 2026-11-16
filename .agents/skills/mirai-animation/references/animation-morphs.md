# Morph targets

A mesh with targets (tables `morphs` and `morph_deltas` of the [mesh
format](../../mirai-assets/references/kinds.md#mesh)) is deformed with per-entity weights. The glTF
importer brings them with their weights and channels
([imports](../../mirai-imports/references/imports.md#gltf-morph-targets)).

## Weights

The weight of a target is, in order:

1. that of the mesh (`Morph_Target.weight`);
2. the `Default` of the entity, if it has one with that name;
3. the Float curve `"<path>/@morph/<target>"` of the animation that moves it, or without it the
   curve named as the target (as faces, their captures and curve drives name them), over the above
   by the weight of the curve;
4. plus the [correctives](animation-rigs.md#operations) of that rig whose `curve` is the name of the
   target;
5. the `Override` of the entity, which replaces it, or its `Additive`, which is added to it.

`Morph_Weights` is the component of the entity; a mesh with targets without it is deformed all the
same with the weights of its mesh and its animation.

- `source` is the entity whose animation gives the curves (without it, itself when it is a rig that
  follows another, the rig of its `Pose_Source` or the nearest animated ancestor, as `morph_source`
  resolves); the curves are its final ones, with those of its leader and its drives; `path`, that of
  its curves (empty,
  that of its `Animation_Target`). The prefab writes `path` only on an entity without
  `Animation_Target`, the mesh that a rig shows.
- Without either path (a rig built by code that shows its own mesh) each target takes the first
  curve of the animation whose name ends in `/@morph/<target>`, whatever its path: the content of
  an animation lists its morph curves by name. Two meshes of one animation with the same target
  names need a path to tell their curves apart.
- It stores up to `asset.MORPH_WEIGHTS` entries by name with value and mode: a small row that is
  copied in each snapshot; the curves move the other targets. `morph_weight_set` and
  `morph_weight_clear` write them.
- An entry that does not name a target of the mesh leaves `Unknown_Target` and the others are
  applied; a repeated name, a non-finite value or an invalid mode leave `Invalid_Weights` and none
  is applied (`morph_weights_check` validates the same as the binding).

## Runtime

- `animation_morph` (fixed, after `animation_advance`) stores in `Morph_Playback` the weights of
  this tick and of the previous one. It looks for meshes with targets only when meshes,
  `Morph_Weights`, animations, hierarchy, `Pose_Source`, `Animation_Target` or assets change; it
  rebinds an entity when its row, its mesh or the path of its curves changes.
- A stable tick does not allocate; binding reserves before changing anything, so without memory the
  previous weights remain.
- `animation_morph_state` gives the weights of the tick, the mesh, the entity that animates them and
  the error of the binding. `animation_evaluate` also composes the weights, for the preview and the
  tools.

## API

- `animation.inspect` part `Morphs` gives the targets of an instance with each layer of its weight,
  the last evaluated one and the curve that animates them, and the entity that animates them and how
  it was resolved; `diagnostics` adds the binding error, the entries without a target and the
  `animation.morph*` problems. It does not change the world.
- `animation.morph.set` writes or removes the entry of a target by name (`remove` also removes an
  entry without a target). A name that the mesh does not have gives `Unknown_Target` and full
  entries, `Capacity`. In Edit it is an undo step; in Play and Simulation it changes only the
  running world.
- [`animation.pose.bake`](animation-authoring.md#per-instance-control-and-preview) bakes the final
  weights as curves.

## Deformation

`animation_skin` takes each deformed mesh to the renderer through `engine/render`
([skinned meshes](../../mirai-rendering/references/views.md#skinned-meshes)):

- Influences and deltas cover the vertices of all the levels of the mesh: the renderer deforms each
  level and the GPU keeps choosing the one it draws. The deltas go before the skin.
- A mesh with targets and without skin is a one-joint pose.
- The drawn weights interpolate those of the last two ticks like the pose (a mesh just shown takes
  those of the tick); until the entity has its own, those of the mesh. Only those that changed go to
  the renderer, with the palette or, if the budget skips it, over the one the renderer has.

## Verification

- `mirai test plugins/animation/runtime`: composition (also by the name of the target and from the
  final curves of a rig), errors, binding without memory, search by changes and level packing.
- `mirai test render` with validation: morph and skin in both ray paths, and posed levels.
- `mirai test cook/import/gltf` and `cook/import`: targets, flat normals, tangents and levels.
- `mirai test plugins/animation/editor` (`morph_api_test.odin`, `pose_bake_test.odin`): API and
  bake.
