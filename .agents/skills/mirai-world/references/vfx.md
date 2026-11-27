# Particles: the `vfx` plugin

`plugins/vfx` (`Runtime`, `Editor`, `Shaders`): GPU-simulated, lit, and drawn particles extending
the renderer only via [`engine/render`][ext]. Editor tooling (`particle.*`, document, inspector)
lives in [vfx-editor.md](vfx-editor.md).

[ext]: ../../mirai-rendering/references/views.md#extension-stages

## Format

`plugins/vfx/runtime/effect` (`effect.PARTICLE_KIND` `PART`, `.particle`,
`effect.PARTICLE_VERSION`). Tables: `particle` (primary + additional layers of `Particle_Info` in
`effect.odin`, up to `PARTICLE_LAYERS` (32) in all: a system of many emitters is one effect),
`parameters` (`Particle_Parameter`, 1–4 components or texture; `PARTICLE_MAX_PARAMETERS` per
layer, `PARTICLE_EFFECT_PARAMETERS` in all), `hidden` (primary instance hidden fields).

- **Emission & motion**: constant `rate` (custom via program `births`), `Surface` shape (skinned
  meshes move its triangles), `gravity`/`drag` sample world `Gravity`/`Wind` [volumes][vol] on GPU
  (`GRAVITY` in effect views). `max_instances`/`cull_distance` of the primary layer:
  [culling](#culling).
- **Renderers**: `Mesh` picks from `meshes` by `mesh_weights` (program `particle.mesh` may change
  it; `facing` = `Tumble`, `Velocity` along `-Z` above `PARTICLE_MESH_FACING_SPEED`, or `Emitter`,
  the emitter's turn at birth; sorted mesh effects allow 1 mesh). `Beam` draws a camera-facing
  strip with optional +Y arc. `scale` (0 on an axis: 1, `effect.particle_scale`) stretches quads
  in x/y, ribbon and beam width by x, meshes per axis; program `visual.scale` multiplies it per
  particle, and `visual.orientation` (world quaternion; zero keeps `facing`) turns a mesh.
- **Blending**: `blend` (`Additive`, `Alpha`, `Multiply`) is of sprites, ribbons and beams; a `Mesh`
  blends by its material's `alpha_mode` (`asset.alpha_blended`: `Blend`/`Additive` draw in `Blend`,
  `Additive` with alpha 0). `effect.particle_field_applies` hides what does not apply in the
  editor (`blend` of meshes, ribbon fields of others).
- **Curves & gradients**: non-decreasing active times in `[0, 1]`; trailing zeros unused; sampling
  past the last key holds its value.
- **Paths & validation**: dot paths (`rate`, `colors.1`, `bursts.0.count`,
  `size_over_life.values.2`) via `particle_fields`, `particle_value_at`, and alloc-free
  `particle_value_find` (program text is not overridable). Instances prefix `layers.N.` for
  layer `N` (`value_layer`; `Particle_Override.layers` keeps `N+1`). `particle_validate` /
  `particle_check` report the first error; `particle_view` rejects invalid files
  (`host.assets_document_refuse`).

[vol]: ../../mirai-gameplay/references/libraries.md#volume

## Game

- `Particle_Emitter` runs one clock per layer (`Particle_Clocks`, copied on Play/rollback).
  `active` gates emission in Play, `preview` in Edit; `loop` repeats; stopping lets live particles
  finish; `destroy_when_done` destroys the subtree in Play once every layer and sub effect ends.
  Without an asset, `preset` selects `effect.particle_preset` defaults.
- `Particle_Override` overrides fields (`rate`: primary layer; `layers.1.rate`: layer 1) or
  parameters (`parameters.heat`: every layer whose program declares it, a problem of the primary
  layer when none does; `layers.2.parameters.heat`: that layer) via `value_set`, `value_remove`,
  `error_message`; assets/program are `Effect_Field`. Resolved per layer by `particle_resolve` /
  `particle_resolve_checked` (`layer`) and `particle_program` (`erender.program_find`), using
  `asset/overrides.odin` (`value_leaves`, `overrides_mark`, `override_keep`).
- An emitter with values of its own owns its `Emitter_Info` (`emitter_info_own`), rewritten in
  place when they change; others share one interned by content. `pool_put` writes the row again
  when `Emitter_Desc.look` changes and groups the pool again (`pool.regroup`) only when
  `Emitter_Structure` (program, render, blending, view, event target, material, meshes) does: an
  animated value allocates nothing and keeps the spans of the programs.
- `Emitter_Clock.segment` counts stretches of emission: +1 when emission starts again (`emitting`)
  and, in Play, when `World_Transform.previous` is not where the clock saw it (`core.Jump`,
  `JUMP_DISTANCE`). Births carry it (`Particle_Birth.segment` -> `Particle_Spawn.ribbon`);
  `births_add` and `spawns_join` join groups of one segment first.
- `particles_tick` (`fixed`, game+editor) advances clocks (`time.dt` in Play, `frame.dt` in Edit;
  mode change restarts) and applies `Particle_Requests` (`start`, `stop`, `restart`, `pause`,
  `resume`, `burst` of every layer or of `layer`, `request_value`, `request_value_remove`,
  `request_values_clear`; invalid requests, a layer the effect lacks among them, report
  `vfx.request`). `PARTICLE_BIRTHS` merges oldest groups on overflow. `status` reads one layer
  (`layer`) or all (playing while one plays, done once all are, births added up).
- `particles_sync` (`render`, after `render_sync`) updates `Particle_Sync` (`host, by_world`) with
  only unstarted clock births (safe across rollback). `Particle_Settings.capacity` rejections keep
  the old pool and report `vfx.capacity`. Sub effect capacity reserves 1/live particle (or
  `TRAILS_PER_SECOND` × sub life for `Trail`).

```odin
// Burst an emitter, override fields and program parameters, and push a channel birth.
vfx.burst(requests, emitter_entity, 32)
_ = vfx.request_value(requests, emitter_entity, "colors.0", [4]f32{1, 0.4, 0.1, 1})
_ = vfx.request_value(requests, emitter_entity, "layers.1.rate", f32(40))
_ = vfx.request_value(requests, emitter_entity, "parameters.speed", f32(6.0)) // every layer
core.birth(births, core.Birth{
    channel = core.birth_channel("impacts"), position = hit_pos, normal = hit_n, count = 12,
})
```

## Particle lights

`Particle_Info.light` (`effect.Particle_Light`: `color`, `intensity`, `range`, `radius`,
`offset`, `shadows`, `indirect`, `scattering`) gives a layer one point light at the entity of its
emitter (`offset` in its axes), never per particle:

- **Resolved with the clock**: `emission_of` copies the light, its tint (`light.color`, or the
  midpoint of `colors`) and the `color_over_life` curve into `Emission.light`. The tick lists
  the emitters with a lit layer in `Particle_Clocks.lit`;
  `particles_lights` (`render`, before `render_sync`) visits only those and asks `is_hidden` only
  of one whose layer gives a light now.
- **Envelope**: at the mean age of the particles alive (`Emitter_Clock.births`, or the last birth
  of a program that starts them on the GPU or of a channel the emitter listens to)
  `color_over_life` scales intensity (alpha) and tints the color; no live particles, no light.
  `range` stays, so the slot keeps its reach class and the light tree only refits. It does not
  follow where particles fly: the light stays at the emitter.
- **Budget**: `min(Particle_Settings.max_lights, PARTICLE_LIGHTS_MAX)` (32) per world, nearest a
  `scene.Simulation_Sources` first; the dropped ones are reported (`vfx.lights_over`, and
  `vfx.light_dropped` when the frame's `host.FRAME_LIGHT_CAPACITY` is full).
- **Renderer slots**: the lights go to `host.Frame_Extras` (`erender.light_add`), which the
  renderer keeps in fixed slots that turn off instead of going
  ([extra lights](../../mirai-rendering/references/lights.md#local-lights)), so a flash that ends
  rebuilds no light tree.

## Animation spans

`plugins/vfx_animation` (`dependencies: ["vfx", "animation"]`, `"automatic": true`) bridges
`anim.Animation_Events` to `vfx.Particle_Requests` without coupling `vfx` or `animation`:

- Attach `vfx_animation.Particle_Animation_Span` to a `Particle_Emitter` entity (`source` `NONE`
  resolves self or nearest `core.Parent` ancestor with `anim.Animation`).
- Duration spans (`end_marker` empty) start on `.Span_Begin` and stop on `.Span_End` (reference-
  counted for overlapping spans); paired point markers (`end_marker` set, e.g.
  `FortMeleeAnimTrails_On` / `FortMeleeAnimTrails_Off`) start/stop on `.Marker`. Optional `action`
  filters to one action name; `restart_on_begin` restarts generation on start.
- `vfx_animation_spans` (`fixed`, `stage="react"`, after `animation_advance`, before
  `particles_tick`) applies requests in the same tick and stops active emitters on `.Interrupted`,
  `.Ended` (of the action that opened it; of an unnamed clip, of the same clip), span removal, or
  source entity destruction so trails never stick on. The source is found again only when spans,
  emitters, `core.Parent` or `anim.Animation` change (`Span_Active.resolved`).
- One-shot sounds and births at markers are cues of the `.character`, not spans
  ([cues](../../../../docs/game/audio/cues.md)).

## Culling

`cull_distance` and `max_instances` of the primary layer make whole emitters wait
(`Emitter_Clock.culled`): in `particles_tick`, past `cull_distance` from every
`scene.Simulation_Sources` source (`scene.sources_distance`; never the view, so every machine
decides the same), or past the `max_instances` nearest of their effect (`culls_rank`: by asset and
preset, then distance, then entity; scratch `Particle_Sync.culls` keeps its capacity). A waiting
clock does not advance; its slot stays with `FLAG_PAUSED` and `Emitter_Desc.culled`, which
`draw_list` skips; `status` says `Culled`.

## Surfaces and resources

Resource rows per emitter list the shape surface first, then `//! resource name
surface|channel|grid|bones|transform` in declaration order.

- **Surface**: rendered mesh (`Render_Sync`; skinned meshes move triangles with barycentrics).
  Triangle area CDF is built on GPU (`particle_surface.comp`, level-0 clusters via `geometry.slang`)
  once and rebuilt on `erender.vertices_made`.
- **Bones**: the world pose of the skeleton the bound entity shows (`mirai_vfx_bone`, `_count`,
  `_sample`: position, turn, signed scale, velocity, angular velocity, parent; `valid` false past
  the bones or unbound). `vfx_animation_bones` (render, after `animation_skin`) publishes into
  `Particle_Bones`, only for entities a `Particle_Binding` names, non-owning slices of
  `anim.animation_shown_pose` (the drawn skin pose, else the rig's last tick; every bone, sockets
  included, not the skinning deltas) without the pose's entity, with velocities from the previous
  pose (discrete tick poses keep smooth velocity across sub-tick render frames via pose tick
  epoch); `particles_sync` gathers each skeleton once into `Particle_Sync.bones`, uploaded once per
  frame in `particle_frame` as direct TRS + velocity + angular velocity + parent (`Gpu_Bone`, 80
  bytes). Steady frames allocate nothing; entries go after two idle frames.
- **Transform**: the world transform of any bound entity (including `Bone_Attachment` entities),
  with previous-frame history (`mirai_vfx_transform`, `mirai_vfx_transform_at(ctx, resource, t)`
  interpolating position, scale, and shortest-hemisphere rotation from `previous` at `t=0` to
  current at `t=1`; `valid` false when unbound or missing). Uses `Gpu_Resource`'s existing `world`
  and `previous` rows with zero per-frame allocations.
- **Bindings**: `Particle_Bindings` selects the shape surface (default: own entity).
  `Particle_Binding` binds a named program resource to an entity or grid; missing target reads
  nothing (no fallback). Unbound grids default to own entity's grid for the first walked grid, else
  world grid by name. Previous+current poses provide `inherit_velocity`.

## Grids and stages

- `Particle_Grid` (`name`, `cells`, `cell_size`, `layers`, `cached`, `follow_view`) wraps in place
  in whole cells (entering cells zeroed; outside reads 0; 2 ping-pong copies + per-step
  `mirai_vfx_grid_splat` cleared each step). Cap `GRID_CAPACITY`; overflow, duplicate name (keeps
  prior frame's owner), invalid values, or two emitters walking one grid report `vfx.grid`.
- `//! stage name over particles|grid [iterations N]` runs every step after emit and before `update`
  in declaration order, with a dispatch per iteration (sub effect stages do not run). Particle
  stages bin neighbors via `mirai_vfx_grid_word_add`. `initialize`, `update`, and stages support
  `mirai_vfx_trace` (`_hw` variant; declare `//! use trace` when helpers trace).

```slang
//! mirai vfx Spread
//! resource heat grid
//! stage give over particles
//! stage keep over heat
namespace Spread {
struct Parameters { float give; };
struct Attributes { float heat; };
void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle pt,
                inout Attributes a) {}
void give(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle pt, inout Attributes a) {
    mirai_vfx_grid_splat(ctx, heat, pt.position, 0u, float4(p.give, 0.0, 0.0, 0.0));
}
void keep(Mirai_Vfx_Cell cell, Parameters p) {
    float4 h = mirai_vfx_grid_load(cell.ctx, heat, cell.index, 0u);
    mirai_vfx_grid_store(cell, 0u, h + mirai_vfx_grid_splatted(cell.ctx, heat, cell.index, 0u));
}
void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle pt, inout Attributes a) {
    a.heat = mirai_vfx_grid_sample(ctx, heat, pt.position, 0u).x;
}
void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle pt, Attributes a,
            inout Mirai_Vfx_Visual visual) {}
}
```

## World textures

`Particle_World_Texture` on a flat-Y `Particle_Grid` exposes `layer` to materials (cap
`WORLD_TEXTURES`; non-flat or overflow reports `vfx.world_texture`). Packed to half-float after
steps and copied to the texture table (`erender.pass_table_texture_copy`); views read the previous
frame's steps.

```slang
//! mirai surface Count_Ground
//! parameter scale {"default":0.01,"min":0,"max":1}
#include "vfx_world_texture.slang"
namespace Count_Ground {
struct Parameters { float scale; };
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.base_color = float3(0.0);
    s.emission = float3(vfx_world_texture("counts", ctx.world_position).x * p.scale);
    return s; // or vfx_world_texture_uv("counts", ctx.uv0)
}
}
```

`follow_view` centers a grid on the view ray intersection at entity height clamped by
`VIEW_NEAR`. A grid whose last writer leaves the pool clears once.

## Volumes

`Particle_Volume` on a 3D `Particle_Grid` (flat grid reports `vfx.volume`) renders layer 0 as
density (`x`) and glow (`y`). Lit once/frame after steps via `shaders/include/media.slang` (no
temporal history) and raymarched in `Blend` before sprites in half-cell steps cut at scene/glass
depth.

## Channels

Game code pushes to `core.Births` without importing `vfx`. `Particle_Channel` listens by text name
(Cone aligns to nonzero birth normal); `silent` skips auto-spawn so programs read `channel` alone.
Non-silent emitters preview periodically in Edit (`channel_preview`). `particles_tick` keeps each
listened channel's births in a host ring (`Channel_Ring`, `CHANNEL_BIRTHS`, never rolled back,
allocated when the listeners change) with the tick that read them. A resimulated tick pairs its
births one to one with records of the same tick and channel (`channel_again`): the nearest of the
same `Birth.by` with no distance cap, or for `by` `NONE` the nearest of `NONE` within
`BIRTH_SAME_DISTANCE`. A pair is not started again and, if unstarted, takes the corrected birth;
an unpaired birth starts; an unpaired unstarted record is `gone`. A non-resimulated tick earlier
than the last (a load) empties the rings, as `audio_requests` forgets `Sounds_Played`. A record
that gives its place unstarted counts in `lost` (`vfx.births`), as do `core.Births.log.lost`.

## UI effects

`Particles` nodes in `.ui` push `gui.UI_Effects` each frame; `UI_Particles` advances clocks even
when world time is paused, draws in the texture's `Effect` stage only (no light, collision, or
fade), and drops unrequested effects.

## GPU

`plugins/vfx/runtime/gpu.odin` and `plugins/vfx/shaders`.

### Pools and emitters

- One pool/world (`pass_buffer`, freed in `particles_release`). `particles_sync` sends only changed
  or per-frame emitters; hidden emitters leave; removed world-space emitters finish in orphaned
  slots. Persistent `Pool_Buffer.Emitters` (`EMITTER_CAPACITY`, `Gpu_Frame`) allocates nothing in
  stable frames; arena growth preserves GPU state. Per-frame walks go over `pool.order` (live
  slots), never `0..<slot_end`.
- `emitter_bounds` boxes an emitter analytically: shape and size plus `(speed + inherited speed +
  a·life)·life`, `a` from acceleration, noise, attractor, `gravity` × the strongest gravity and
  `drag` × the strongest wind of the world (`fields_reach`, `pool.gravity_reach`/`wind_reach`;
  boxes are found again when they change). Drag and collisions only slow particles. Unbounded:
  Vfx programs, `Surface`, channel births and event targets.
- Particles never enter BVH/TLAS (no shadows/reflections/GI). Positions are renderer-origin
  relative (`render/origin.odin`): `shift` pass (`Geometry`) rebases surviving particles on origin
  moves (programs storing world points declare `//! rebase` with `void rebase(float3 origin_shift,
  inout Attributes a)`); `FLAG_VIEW` effect views are unshifted. `finish` updates `particles`
  counters (2-frame lag); 1 GPU timing interval per pass kind.

### Births and steps

- Up to `SPAWNS` `Particle_Spawn` groups per emitter (merges on overflow); deterministic seed from
  `(emitter, birth_index)`. Stale/prewarm births advance analytically. Each group's ribbon is in
  `Gpu_Emitter.ribbons` (Ribbon effects only); each channel birth starts its own ribbon.
- A birth stores its pose (`particle_birth_pose`: the emitter turn between `previous` and `world`,
  identity in local space; a cone aligned to a channel normal takes that frame) after its draw look
  (`POSE_AT` of `DRAW_LOOK_BYTES`). `inherit_velocity` in local space takes only the velocity
  relative to the emitter (`particle_inherited`). Each simulating frame runs
  `dt <= FRAME_MAX` in steps `<= STEP` (up to `STEPS`) on window/texture views (`ui_only` defers);
  `paused` freezes particles.

### Vfx programs

- Contract: `shaders/include/mirai_vfx.slang` ([Vfx domain][vfx-domain]); built-in `Orbit`
  (`plugins/vfx/shaders/orbit.slang`). `initialize` runs after effect defaults; `update` before
  effect forces; `render` writes draw records (`visual.data`/`given`/`random` -> sprite Surface
  program; `visual.scale`/`orientation` -> the vertex stages, at `TURN_AT`); `//! births`
  replaces effect births (emit mode 3) over the seconds of the frame its clock emitted in
  (`Emitter_Clock.program_until` -> `Gpu_Emitter.birth_limit`; none before it starts), and its
  effect says `max_particles` (`particle_program_check` refuses it otherwise).
- Each active program supplies emit, simulate, and stage pipelines (`_hw` when tracing); sprite and
  mesh vertex pipelines are shared. Editor [debugging](vfx-editor.md#debugging) reads
  `emitter_ranges`.

[vfx-domain]: ../../mirai-rendering/references/shaders.md#programs

### Passes

| Stage | Pass | Role |
| --- | --- | --- |
| `Simulate` (step) | `begin` / `emit` / `stage` / `simulate` | Reset/init ranges; spawn step+channel+event births; run program stages & grid swaps; forces, noise rotor, attractor, drag, `World` `trace_ray` (Coulomb friction, rest-speed hit gate), events, half-rate `lit` RGBE |
| `Simulate` (frame) | `surface` / `stage` clear / `volume light` / `finish` | Build new surface CDFs; clear entered grid cells; light volumes (`_hw`); indirect draws & tiled sort (ribbons, mesh runs) |
| `Blend` (view) | `volumes` / `sprites` | Raymarch volumes; draw sorted sprites (`Billboard`/`Velocity`/`Horizontal`/`Beam`/`Ribbon`) & blended `Mesh` (`particle_mesh_blend.vert`, mesh normal), Surface program or flipbook/disc, `soft`, `Additive`/`Alpha`/`Multiply` (unlit, `FLAG_MULTIPLY`), `.Glass_Depth` split |
| `Effect` / `Gbuffer` | `effects` / `meshes` | UI effect views; opaque/masked `Mesh` particles |

A Surface program on a sprite or a blended mesh has the last word on its color: it reads
`ctx.particle_color` and `ctx.particle_life` (the share of its life lived) with the `render` data,
and the color of the vertices of a mesh apart, in `ctx.vertex_color` (white on quads, ribbons and
beams). A G-buffer mesh gets none of them: the color of its particle tints what its program
returns.

An unlit sprite or blended mesh shows its color and the emission of its material or Surface
program in the units of its emitter (`Particle_Info.emission_mode`, `PARTICLE_FLAG_RELATIVE`;
Relative by default, so it shows by day and by night); a lit one takes the emission mode of its
material.

A lit (`Particle_Info.lit`) particle is lit by what the simulate pass gathers at its center every
other frame (local lights, probes) into its RGBE `light`. A sprite, ribbon or beam takes the sun
there too, as a puff with no surface. A blended `Mesh` takes the sun where it is drawn instead:
the traced sun visibility is the `SUN_SHIFT` bit of its flags, and `particle_sprite.frag` shades it
with the fragment normal (or that of its Surface program), base color, roughness and metallic by
`sun_radiance`, the term of the sun `direct_lighting` uses for the scene. Opaque mesh particles are
lit in the G-buffer like any surface; translucent scene meshes by `translucent.frag`.

## Ribbons

Particles join ribbons via `flags >> RIBBON_SHIFT` (`particle_own_ribbon` from event seed or
`particle.ribbon`). `Trail` emits every `1/TRAILS_PER_SECOND` plus a 1-step leader at frame end.
Sorted by `(ribbon, age, slot)`, adaptively subdivided to ~1 px cubic error in scratch; look cached
in `DRAW_LOOK_BYTES` per particle. Deaths auto-bridge next frame. The frame sort also writes, after
each pose, the metres from the ribbon head (segmented scan of chords) and the ribbon length; `v`
is those metres over `ribbon_tile` (0: over the length). `ribbon_axis` `Emitter_Up` widens along
the pose's +Y across the path, else toward the camera. Rate/distance births join the clock segment
(stop/start and jumps do not stitch).

## Mesh particles

Drawn in `Gbuffer` via `particle_mesh.vert` + engine/Surface fragment (1 draw/mesh/program via
`pass_mesh_programs`, `frame_gbuffer_mesh`, `MESH_DRAWS_AT`). `frame_mesh_whole` keeps all level-0
pages resident (read through `geometry.slang`); motion vectors use velocity. Of program `render`,
the look (color, size, `scale`, `orientation`) reaches G-buffer meshes; `visual.data` does not.
Local-space meshes take motion vectors from the emitter's `previous` rows
(`particle_mesh_vector_by`).

## Verification

- `mirai test plugins/vfx/runtime/effect`: format, validation, value paths.
- `mirai test plugins/vfx/runtime` (`MIRAI_VALIDATION=1`, `-define:ODIN_TEST_THREADS=1`): CPU
  (`vfx_test.odin`: animated values without allocations or regrouping, layer paths and parameter
  propagation over a device-less catalog, analytical bounds, culling) and GPU (`gpu_test.odin`,
  shaders in `.mirai/test-shaders/vfx`): births/steps/pause/events/pools/capacity, ribbons
  (`two_ribbons.slang`), `Surface` on a posed skin (`testdata/stick.slang`), `World`
  hits/friction, sprite Surface programs (`hand_over.slang`, `particle_data.slang`,
  `particle_seen.slang`: life, color, mesh vertex color, view direction), grid
  stages/splats (`tally.slang`, `spread.slang`), weighted velocity-facing meshes, stage rays
  (`probe.slang`), program births (`sprinkle.slang`), volumes (`puff.slang`), world textures
  (`count_ground.slang`), channel rollback (`testdata/gather.slang`), bones (`bone_probe.slang`,
  TRS + negative scale), transforms and degenerate `particle_turn_of` (`transform_probe.slang`),
  fog/glass sorting, zero-alloc frames, debugger (`glitch.slang`),
  additive meshes, `Multiply`, ribbon segments, `Emitter_Up` and tiles (`trail_stripes.slang`),
  `Emitter` facing with `scale`, program turn and scale of meshes (`lay_across.slang`),
  local-space motion vectors and inheritance.
- `mirai test plugins/vfx/editor -collection:plugins=<root>/plugins`: `document_test.odin`.
- `mirai test plugins/vfx_animation/runtime --no-gpu`: `span_test.odin` (duration spans, paired
  markers, action filtering, interruption, source destruction, zero-alloc steady ticks),
  `bones_test.odin` (published pose, parents, velocity, smooth tick-pose fallback across sub-tick
  render frames, render-interpolated velocity, zero-alloc steady frames, pruning).
- Demo editor (headless + validation): `physics_gallery/physics_burst.scene` (station 11),
  `particle.*`, and `Surface` + `Particle_Bindings` capture.
