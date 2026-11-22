# Particles: the `vfx` plugin

`plugins/vfx` (`Runtime`, `Editor`, `Shaders`): GPU-simulated, lit, and drawn particles extending
the renderer only via [`engine/render`][ext]. Editor tooling (`particle.*`, document, inspector)
lives in [vfx-editor.md](vfx-editor.md).

[ext]: ../../mirai-rendering/references/views.md#extension-stages

## Format

`plugins/vfx/runtime/effect` (`effect.PARTICLE_KIND` `PART`, `.particle`,
`effect.PARTICLE_VERSION`). Tables: `particle` (primary + additional layers of `Particle_Info` in
`effect.odin`), `parameters` (`Particle_Parameter`, 1–4 components or texture), `hidden` (primary
instance hidden fields).

- **Emission & motion**: constant `rate` (custom via program `births`), `Surface`/`Bones` shapes,
  `gravity`/`drag` sample world `Gravity`/`Wind` [volumes][vol] on GPU (`GRAVITY` in effect views).
- **Renderers**: `Mesh` picks from `meshes` by `mesh_weights` (program `particle.mesh` may change
  it; `facing` = `Tumble` or `Velocity` along `-Z` above `PARTICLE_MESH_FACING_SPEED`; sorted mesh
  effects allow 1 mesh). `Beam` draws a camera-facing strip with optional +Y arc.
- **Curves & gradients**: non-decreasing active times in `[0, 1]`; trailing zeros unused; sampling
  past the last key holds its value.
- **Paths & validation**: dot paths (`rate`, `colors.1`, `bursts.0.count`,
  `size_over_life.values.2`) via `particle_fields`, `particle_value_at`, and alloc-free
  `particle_value_find` (program text is not overridable). `particle_validate` / `particle_check`
  report the first error; `particle_view` rejects invalid files (`host.assets_document_refuse`).

[vol]: ../../mirai-gameplay/references/libraries.md#volume

## Game

- `Particle_Emitter` runs one clock per layer (`Particle_Clocks`, copied on Play/rollback).
  `active` gates emission in Play, `preview` in Edit; `loop` repeats; stopping lets live particles
  finish; `destroy_when_done` destroys the subtree in Play once every layer and sub effect ends.
  Without an asset, `preset` selects `effect.particle_preset` defaults.
- `Particle_Override` overrides primary-layer fields or `parameters.<name>` (`value_set`,
  `value_remove`, `error_message`; assets/program are `Effect_Field`). Resolved via
  `particle_resolve` / `particle_resolve_checked` and `particle_program` (`erender.program_find`),
  using `asset/overrides.odin` (`value_leaves`, `overrides_mark`, `override_keep`).
- `particles_tick` (`fixed`, game+editor) advances clocks (`time.dt` in Play, `frame.dt` in Edit;
  mode change restarts) and applies `Particle_Requests` (`start`, `stop`, `restart`, `pause`,
  `resume`, `burst`, `request_value`, `request_value_remove`, `request_values_clear`; invalid
  requests report `vfx.request`). `PARTICLE_BIRTHS` merges oldest groups on overflow.
- `particles_sync` (`render`, after `render_sync`) updates `Particle_Sync` (`host, by_world`) with
  only unstarted clock births (safe across rollback). `Particle_Settings.capacity` rejections keep
  the old pool and report `vfx.capacity`; `sort`/`Ribbon` cap at `SORT_MAX`. Sub effect capacity
  reserves 1/live particle (or `TRAILS_PER_SECOND` × sub life for `Trail`).

```odin
// Burst an emitter, override a field and program parameter, and push a channel birth.
vfx.burst(requests, emitter_entity, 32)
_ = vfx.request_value(requests, emitter_entity, "colors.0", [4]f32{1, 0.4, 0.1, 1})
_ = vfx.request_value(requests, emitter_entity, "parameters.speed", f32(6.0))
core.push(&births.queue, core.Birth{
    channel = core.birth_channel("impacts"), position = hit_pos, normal = hit_n, count = 12,
})
```

## Surfaces, bones and resources

Resource rows per emitter list shape surface/bones first, then `//! resource name
surface|channel|grid|emitter|data` in declaration order (`Bones` is shape-only).

- **Surface**: rendered mesh (`Render_Sync`; skinned meshes move triangles with barycentrics).
  Triangle area CDF is built on GPU (`particle_surface.comp`, level-0 clusters via `geometry.slang`)
  once and rebuilt on `erender.vertices_made`.
- **Bones**: parent-to-joint segments skipping non-deforming rig joints, posed each frame via
  current and previous `erender.skin_palette` (bind pose if unposed), sampled by summed length.
- **Bindings**: `Particle_Bindings` selects shape surface/bones (default: own entity).
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

## Grid states

`plugins/vfx/runtime/gridfile` (`gridfile.KIND` `VGRD`, `.grid`) stores cell layers (X fastest, then
Y, Z). `Particle_Grid.cached` initializes both copies on creation or asset change (size/layer
mismatch reports `vfx.grid`). `follow_view` centers on view ray intersection at entity height
clamped by `VIEW_NEAR`. A grid whose last writer leaves the pool clears once.

## Volumes

`Particle_Volume` on a 3D `Particle_Grid` (flat grid reports `vfx.volume`) renders layer 0 as
density (`x`) and glow (`y`). Lit once/frame after steps via `shaders/include/media.slang` (no
temporal history) and raymarched in `Blend` before sprites in half-cell steps cut at scene/glass
depth.

## Channels

Game code pushes to `core.Births` without importing `vfx`. `Particle_Channel` listens by text name
(Cone aligns to nonzero birth normal); `silent` skips auto-spawn so programs read `channel` alone.
Non-silent emitters preview periodically in Edit (`channel_preview`). `particles_tick` numbers
channel births for rollback dedup; host ring discards replaced future on replay and drops
unlistened channels.

## Data channels

`//! resource name data words` (`data.odin`) double-buffers GPU word entries frame-to-frame
(appends only in the last step; cap `DATA_CHANNELS` reports `vfx.data`). Games pass inputs via
`core.Birth.values` and read back asynchronously (presentation only, never in `fixed`):

```odin
vfx.data_watch(watch, "hits")
if entries, words := vfx.data_entries(read, "hits"); words > 0 {
    for i := 0; i+words <= len(entries); i += words { /* consume entries[i:i+words] */ }
}
```

## UI effects

`Particles` nodes in `.ui` push `gui.UI_Effects` each frame; `UI_Particles` advances clocks even
when world time is paused, draws in the texture's `Effect` stage only (no light, collision, or
fade), and drops unrequested effects.

## Reports

`report` (deaths/hits) writes into internal `REPORTS_CHANNEL` and reads back asynchronously into
`Particle_Reports` (`presentation` storage — rejected in `fixed` steps; `DATA_ENTRIES` cap,
overflow in `lost`).

## GPU

`plugins/vfx/runtime/gpu.odin` and `plugins/vfx/shaders`.

### Pools and emitters

- One pool/world (`pass_buffer`, freed in `particles_release`). `particles_sync` sends only changed
  or per-frame emitters; hidden emitters leave; removed world-space emitters finish in orphaned
  slots. Persistent `Pool_Buffer.Emitters` (`EMITTER_CAPACITY`, `Gpu_Frame`) allocates nothing in
  stable frames; arena growth preserves GPU state.
- Particles never enter BVH/TLAS (no shadows/reflections/GI). Positions are renderer-origin
  relative (`render/origin.odin`): `shift` pass (`Geometry`) rebases surviving particles on origin
  moves (programs storing world points declare `//! rebase` with `void rebase(float3 origin_shift,
  inout Attributes a)`); `FLAG_VIEW` effect views are unshifted. `finish` updates `particles`
  counters (2-frame lag); 1 GPU timing interval per pass kind.

### Births and steps

- Up to `SPAWNS` `Particle_Spawn` groups per emitter (merges on overflow); deterministic seed from
  `(emitter, birth_index)`. Stale/prewarm births advance analytically. Each simulating frame runs
  `dt <= FRAME_MAX` in steps `<= STEP` (up to `STEPS`) on window/texture views (`ui_only` defers);
  `paused` freezes particles.

### Vfx programs

- Contract: `shaders/include/mirai_vfx.slang` ([Vfx domain][vfx-domain]); built-in `Orbit`
  (`plugins/vfx/shaders/orbit.slang`). `initialize` runs after effect defaults; `update` before
  effect forces; `render` writes draw records (`visual.data`/`given`/`random` -> sprite Surface
  program); `//! births` replaces effect births (emit mode 3).
- Each active program supplies emit, simulate, and stage pipelines (`_hw` when tracing); sprite and
  mesh vertex pipelines are shared. Editor [debugging](vfx-editor.md#debugging) reads
  `emitter_ranges`.

[vfx-domain]: ../../mirai-rendering/references/shaders.md#programs

### Passes

| Stage | Pass | Role |
| --- | --- | --- |
| `Simulate` (step) | `begin` / `emit` / `stage` / `simulate` | Reset/init ranges; spawn step+channel+event births; run program stages & grid swaps; forces, noise rotor, attractor, drag, `World` `trace_ray` (Coulomb friction, rest-speed hit gate), events/reports, half-rate `lit` RGBE |
| `Simulate` (frame) | `surface` / `stage` clear / `volume light` / `finish` | Build new surface CDFs; clear entered grid cells; light volumes (`_hw`); indirect draws & tiled sort (ribbons, mesh runs) |
| `Blend` (view) | `volumes` / `sprites` | Raymarch volumes; draw sorted sprites (`Billboard`/`Velocity`/`Horizontal`/`Beam`/`Ribbon`) & blended `Mesh` (`particle_mesh_blend.vert`), Surface program or flipbook/disc, `soft`, `Additive`/`Alpha`, `.Glass_Depth` split |
| `Effect` / `Gbuffer` | `effects` / `meshes` | UI effect views; opaque/masked `Mesh` particles |

## Ribbons

Particles join ribbons via `flags >> RIBBON_SHIFT` (`particle_own_ribbon` from event seed or
`particle.ribbon`). `Trail` emits every `1/TRAILS_PER_SECOND` plus a 1-step leader at frame end.
Sorted by `(ribbon, age, slot)`, adaptively subdivided to ~1 px cubic error in scratch; look cached
in `RIBBON_LOOK_BYTES` after Attributes. Deaths auto-bridge next frame.

## Mesh particles

Drawn in `Gbuffer` via `particle_mesh.vert` + engine/Surface fragment (1 draw/mesh/program via
`pass_mesh_programs`, `frame_gbuffer_mesh`, `MESH_DRAWS_AT`). `frame_mesh_whole` keeps all level-0
pages resident (read through `geometry.slang`); motion vectors use velocity. Program `render` data
does not reach G-buffer meshes.

## Verification

- `mirai test plugins/vfx/runtime/effect`: format, validation, value paths.
- `mirai test plugins/vfx/runtime` (`MIRAI_VALIDATION=1`, `-define:ODIN_TEST_THREADS=1`): CPU
  (`vfx_test.odin`, `data_test.odin`) and GPU (`gpu_test.odin`, shaders in
  `.mirai/tmp/vfx-test-shaders`): births/steps/pause/events/pools/capacity, ribbons
  (`two_ribbons.slang`), `Surface`/`Bones` (`testdata/stick.slang`), `World` hits/friction, sprite
  Surface programs (`hand_over.slang`, `particle_data.slang`), grid stages/splats (`tally.slang`,
  `spread.slang`), weighted velocity-facing meshes, stage rays (`probe.slang`), volumes
  (`puff.slang`), world textures (`count_ground.slang`), channel rollback (`testdata/gather.slang`),
  reports, fog/glass sorting, zero-alloc frames, and debugger (`glitch.slang`).
- `mirai test plugins/vfx/editor -collection:plugins=<root>/plugins`: `document_test.odin`.
- Demo editor (headless + validation): `physics_gallery/physics_burst.scene` (station 11),
  `particle.*`, and `Surface` + `Particle_Bindings` capture.
