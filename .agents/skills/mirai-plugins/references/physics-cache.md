# Recorded geometry playback

`physics_cache` is an optional runtime plugin (`import cache "plugins:physics_cache/runtime"`).
It records rigid geometry with its poses and piece changes in `.physics_cache` (`PCAC`), a
[portable asset](../../mirai-assets/references/formats.md), and playback draws it without creating
bodies or repeating the solver, fracture events or gameplay. The `physics` snapshots are the
world's rollback mechanism and do not use this format.

## Recording

`Cache_Recorder` (`record.odin`) belongs to an explicit transaction: `record_init` reserves its
capacities and its scratch, and recording poses within them reuses memory; only preparing new
geometry allocates. A rejected frame is not added.

- `record_mesh(&r,object,piece,mesh,materials)` registers an immutable geometry: the pair
  `object,piece` identifies it and a new geometry receives another identity. No entities, bodies
  or runtime pointers are stored.
- `record_frame(&r,time,samples)` records the visible pieces, sorted by track, with strictly
  increasing times from zero and poses relative to the recording origin. An absent piece is not
  drawn in that frame and can come back.
- The automatic bridge `physics_cache_destruct`, there when a project has this plugin and
  `destruct`, records destructibles: `capture_destructible`, with the scratch of its `Capture`,
  uses the [public destruction queries][destruct], keeps each new geometry (also the halves of a
  cut) and converts the world poses to the origin. With `Geometry_Unavailable` the piece is not
  prepared yet and the caller retries off the stable path. The cache itself knows neither `destruct`
  nor `physics`.
- `cache_save` writes atomically (`cache_document` builds the document without a file); the heavy
  tables go in LZ and the materials generate the asset's dependencies. All ranges are validated
  on opening, without the `.fracture`, the handles or the world that produced the recording.
- It also serves authored animated geometry: register the rigid meshes once and bake their
  transformations with `record_frame`. It is a bake of rigid pieces, not a cache of deformable
  vertices or skinning; for fixed meshes with authored motion there is the
  [animation plugin](../../mirai-animation/references/animation.md).

## Relation with animation

`Animation` and `Geometry_Playback` are separate components, storages and plugins, and neither
depends on the other.

- `Animation` animates properties of existing targets (entities, bones) with layers, blends,
  graphs, markers and root motion; creating or removing targets is a matter for content and
  gameplay.
- `Geometry_Playback` brings in the same asset the geometry, the materials, the poses and the
  presence of each piece per frame: a clock and controls, visual instances without entities per
  piece, and an interpolated TRS only where the piece is still present. It can show the final
  frame at `duration` and has no physical events or root motion.
- `cache_sample` uses rotation slerp; the general TRS interpolator uses nlerp and does not
  replace it.
- The time of `Geometry_Playback` is not copied to `animation.Playback`: each table has its
  writer.

## Playback

An entity with `Transform` and `Geometry_Playback` (start from `GEOMETRY_PLAYBACK_DEFAULT`) plays
an asset; its transform places the whole recording in the world and `rate<0` plays it in reverse.
The time lives in `World`: it is copied with Play and rollback.

- The game only needs the component and `Geometry_Requests`; it receives no files, buffers,
  `Cache_Library` or `host.App`. The sole writer of `Geometry_Playback` during the loop is
  `physics_cache_update`, and the game asks it for changes:

```odin
cache.play(requests,e,rate=-1,restart=true)
cache.pause(requests,e)
cache.seek(requests,e,0.75)
cache.rate(requests,e,0.5)
```

- `restart` starts at zero with a positive rate and at the duration with a negative rate. Without
  loop it stops at one end; with loop it returns to the opposite one. The inspector and the
  component API author those same values.
- Loading a source or replacing an asset whose revision changed is a transaction that frees the
  previous geometry; loaded sources are kept until the library is destroyed, up to
  `CACHE_SOURCES`. Loading prepares all the meshes and the sampling buffer: stable playback and
  reverse do not allocate or rebuild geometry.
- The geometry comes out as render instances of the frame. `physics_cache_draw` runs in the game
  and editor loops: in editing it shows the pose of the authored time (editing does not advance the
  clock) and in Play it draws the same as the player.
- A player that does not draw is a `physics_cache.*`
  [problem](../../mirai-core/references/core.md#problems) of its entity.
- Tools: `cache_view` opens the view of an asset, `cache_sample` interpolates the pieces present
  in both frames (being born and retiring happen in their frame, without blending topologies) and
  returns the total even if the output is short, and `cache_mesh` copies a geometry.

## Verification

- `mirai test plugins/physics_cache/runtime`: portable file, interpolation and reverse, topology
  changes, capacity, truncated files, asset reload and public controls.
- `mirai test plugins/physics_cache_destruct/runtime`:
  `destructible_geometry_and_detached_group_poses_play_after_the_source_world_is_destroyed`
  records a real destructible, cuts it, persists and plays it after destroying the source world.
- The tests are CPU and do not verify the image. Build and run a gallery that enables the plugin
  in the player and in the editor's editing and Play: the editor draws with its editor loop, so a
  player capture does not vouch for that path.

[destruct]: ../../mirai-physics/references/engine-destruct.md#reflection-queries-and-events
