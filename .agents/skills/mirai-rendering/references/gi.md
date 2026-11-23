# Global illumination and tracing

## Lighting techniques and optimization

- **Unified tracing.** `shaders/include/trace.slang` exposes `trace_ray` over software BVH or
  hardware ray queries; both return `Hit` (`t`, `instance`, `primitive`, `bary`) and rebuild
  surface attributes from the geometry pools.
- **Indirect scaling.** Diffuse indirect is [probe volume](#probe-volume) times
  [contact occlusion](#contact-occlusion). Per-light `indirect` (`LIGHTS_BOUNCED` in
  `direct_lighting`, [shares](lights.md#local-lights)) scales bounces per light.
  `scene_set_indirect` (`Bounce_Light`) scales volume/sky output at read time (probes gather
  unscaled so edits show immediately; world-scoped, not `View_Volume`).
- **Deterministic sampling.** Probes, contact occlusion and direct samples use fixed patterns—no
  per-frame random directions/lights and no boiling.

### BVH and acceleration structures

- **Software BVH** (`render/bvh.odin`): `std/spatial` SAH `bvh_build`, nearest-first compute
  traversal, early shadow exit, watertight triangle test.
- **BLAS / TLAS & ray cuts.** Persistent object-space BLAS per mesh ray cut (`ray_errors`);
  transform/material/visibility edits never rebuild BLAS. `ray_cuts_update` picks a cut per
  instance with hysteresis where error falls below origin bias, half sun penumbra and half cascade
  spacing.
  - `ray_cut_always` is cut 0, or the coarsest root cut for streamed meshes
    ([pages](scene.md#scene-and-instances)). Hardware builds finer cuts on demand and drops them
    `RAY_CUT_KEEP` frames unused; streamed cuts request pages at priority 0 and pin traced pages.
    Batches trace `ray_cut_always`. Cut switches mark light only if error delta > half cell.
  - Primitive id is `cluster << 7 | triangle` (via per-BLAS table in hw RT). TLAS rebuilds per
    scene revision. Ray classes separate `RAY_GLASS`, `RAY_SHADOW_ONLY` and `RAY_UNSHADOWED`;
    shadows request `RAY_SHADOWS`, surface rays `RAY_SEEN`.
- **Active-tracer-only.** Hardware RT skips software BVHs (`rays[k].bvh_node_count == 0`) and
  software TLAS (`Scene_State.tlas_off`). `tracer_settle` builds only active tracer pipelines
  (`tracer_missing` requires every `_hw` stage); `renderer_apply_settings` builds missing data on
  switch.
- **Hardware RT, hybrid & SDF.** `_hw` compute stages use inline ray queries (SPIRV-Cross -> Metal;
  Vulkan self-test + sw fallback, [RHI](rhi.md#hardware-ray-tracing)). Raster G-buffer + compute
  tracing. SDF/surface-cache tracers plug behind `trace.slang` (prepared).

### Other techniques

- No screen-space tracing, radiance cache, screen probes or ReSTIR. Fixed sampling + deterministic
  light-tree NEE ([lights](lights.md#local-lights)), GPU two-phase cull/LOD
  ([frame graph](frame-graph.md#passes)). Glass traces to `gi_max_distance`, then reads probes
  ([settings](settings.md#settings), [resolution](settings.md#scene-resolution)).

### Temporal and denoising

- Indirect keeps no screen-space history (only TAA does). `Scene_State.changes` wakes reached
  probes for `PROBE_AWAKE`.
- **Blackout** (`render/blackout.odin`): > 50% volume flux change warms over `GI_BLACKOUT_UPDATES`.

## Contact occlusion

`shaders/contact.comp.slang` (`pass_contact`, `Indirect`): tight contact darkening probes miss.

- Traces short hemisphere rays per 2x2 or 1x1 point (sees off-screen geometry; distance falloff),
  skipping thin transmissive surfaces (`trace_past_thin`). Uses `view_bias` (skips if bias >=
  reach). Fixed 4x4 rotation averaged by `contact_pixels.comp`; `contact_light.comp` evaluates
  diffuse/specular probe light. Nested views trace in world space without filtering across portals.
- **Beyond volume.** Rays trace full range for sky visibility (caves stay dark; no bounce gather).
- **Small instances** (< `SMALL_INSTANCE_REACH`): `RAY_SMALL`—seen by contact and
  direct light, skipped by `MIRAI_TRACE_PROBES` (moves never wake volume; emissives need
  `light_stands_for`). Resizing/posing updates class.

## Probe volume

`render/ddgi.odin`, `shaders/ddgi_*.comp.slang` (Lumen Lite style):

- **Cascades.** `probe_cascades` doubling cascades (`probe_grid` horizontal, half vertical),
  centered 1 cascade-0 spacing below first view's `core.View.focus` (or eye); toroidal scrolling,
  zero frame allocations.
- **Kept hits (`Probe_Hits`, `probe_hits.slang`).** Probes trace `probe_rays` fixed Fibonacci rays
  and cache hits (`PROBE_HIT_WORDS`/ray; shared via `probe_slots.slang` past `PROBE_HITS_BYTES`).
  Updates check `probe_changes_list`: retrace only rays crossing geometry boxes, relight only hits
  in changed light spheres or shadow paths, and re-read bounces otherwise. Global stamps
  (`lit_everywhere`/`seen_everywhere`) handle sky/sun/blackout/scale/world changes; removed
  textures dirty only referencing materials. Volume rays see swaying batches at rest
  (`MIRAI_TRACE_PROBES`). Time-reading Surface programs (`abi.Program.reads`), extension gates and
  extension lights are never cached; hidden worlds drop kept hits.
- **Convergence & priority.** Tracks bounce settling (`Probe.frames.w`), encodes fifth-root nearest
  half (`probe_light_encode`), blends mutually visible neighbors from `kept` (`ddgi_keep.comp`).
  `ddgi_select.comp` (`probe_budget`/frame) orders: unread pixel-read -> woken (nearest/reach) ->
  unread unseen (capped while moving, prioritized when still) -> aging/use (`ddgi_mark.comp`, fine
  first). Significant moves (`ddgi_irradiance.comp`) wake 6 neighbors; still `PROBE_PASSING` probes
  back off exponentially up to `1 << PROBE_WAIT_MOST` frames.
- **Relocation & reading (`probe_cascade_read`).** Bounded cell relocation only on traced updates;
  covered keeps old light (never-lit = 0). Wrapped cosine, floorless Chebyshev, `probe_light_root`,
  shrinking normal/view bias, back-plane rejection, `PROBE_HIDDEN_SHARE`. Cascades blend from
  `volume_center` (shared across views) into `probe_volume_beyond`.
- **Specular.** `sample_probes_around` reads normal, specular and coat together (`sample_probes`
  for normal). Gloss tiles (`PROBE_GLOSS_TILE`, `PROBE_GLOSS_POWER`) and sky share
  (`probe_specular`) provide blurred/sky reflections even with reflections `Off`.

```slang
#include "trace.slang"
#include "probe_light.slang"

Hit hit = trace_ray(origin, dir, 0.001, max_dist, false);
bool lit = trace_visible(origin, frame.sun_direction.xyz, max_dist);
Indirect ind = indirect_lobes(pos, normal, view_dir, shading,
    INDIRECT_DIFFUSE | INDIRECT_SPECULAR, contact_ao);
float3 sun = lit ? sun_light(pos) : float3(0.0);
```

## Glass in the indirect

Volume and probe-shadow rays cross glass uncolored ([glass in rays](materials.md#glass-in-rays)).

## Light of each world

`render/world_light.odin` retains up to `Renderer_Desc.worlds` probe volumes + light scales:

- `scene_world(r, world, fresh)` swaps worlds (LRU eviction), preserves returning worlds without
  marking changes, cuts histories, sets exposure immediately and keeps `delta_time`.
  `world_light_forget` drops a hidden world's volume.
- **Warm-up & rescale.** New worlds, `renderer_reset_history` and layout changes
  (`renderer_apply_settings`, resetting all worlds) warm over `GI_WARM_UPDATES` x
  `PROBE_WARM_BUDGET` probes (`ddgi_warm_frames`; blackouts: `GI_BLACKOUT_UPDATES`), max 1
  update/frame. Scale changes rescale via `history_scale.comp` (`light_cutoff` uses exposed units).
  Scene shader reloads call `world_light_stale`; preview-only reloads leave light intact.

## Indirect reference

Test-only path tracer (`render/reference_test.odin`, `render/testdata/gi_reference.comp.slang` in
`TEST_GENERATION`) replacing `Indirect` and writing `Gi` (`Targets.gi_given`,
[pipelines](views.md#render-pipelines)):

- `GI_REFERENCE_PATHS` cosine paths/pixel/frame, emission + `reference_lighting`, Russian roulette
  from bounce 3 to `GI_REFERENCE_BOUNCES`, geometric-normal sidedness. Resets on history loss or
  camera/settings/scene change.
- **Verification.** `mirai test render gi_reference_gives_the_light_of_a_white_furnace` (both
  tracers); metrics: [measuring GI](verification.md#measuring-gi).

```odin
gi_ref: render.Reference_Gi
ok := render.reference_frame(r, frame_desc, {.Gi}, &gi_ref)
```

## Sky and sun

`shaders/include/scene.slang` reads enabled
[`Sky`](../../mirai-gameplay/references/libraries.md#render) (`sky_environment`; disabled = black):

- `Sky.luminance` (nits): gradient or multiplier for equirectangular BC6H `Sky.image` (sun painted
  out; rotated by `Gpu_Frame.sky_orientation`, mip by `spread` up to `SKY_GATHER_LEVELS` before
  last). Transitions blend `sky_from`/`sky_from_map`.
- **Functions.** `sky_radiance(dir, spread)`, `sky_irradiance(normal)`, `sky_seen(dir)` (adds sun
  disc `Settings.sun_radius`, capped at `SUN_DISC_MAX`, + halo when `Sun.disc`),
  `sun_light(position)`.
- **Background.** `use_background` shows `background`/`background_image` in `sky_shown` and
  `sky_reflected` (lerped to `sky_radiance` by roughness) while `Sky` keeps lighting; suppressed
  under lit atmosphere; not blended in transitions. `background_image` without `use_background`
  reports `render.sky_background`. `background_behind` and `renderer_set_backdrop` show behind the
  scene only, not in reflections.

### Atmosphere

`air.slang`, `render/air.odin`: Hillaire 2020 physical air (`Sky.atmosphere`, `Sky.air` Rayleigh,
Mie, ozone tent, `AIR_EARTH`; `Air.altitude` = y=0 over ground). Needs an enabled `Sun` for light.

- **Tables (`AIR_*_TEXTURE` after DFG).** Created lazily, unit-sun normalized: transmittance +
  multi-scatter (`air_frame`, on air change); per-window-view sky row (`air_view`, texture views
  share row 0; rebuilds on sun height, air or eye altitude > `AIR_SKY_ALTITUDE_TOLERANCE`).
- **Sun & aerial.** `Sun.illuminance` is ground-overhead; above-air multiplies by `air_overhead`;
  `sun_light` applies altitude transmittance + horizon disc cut. `Targets.aerial`
  (`air_aerial.comp`, to `AIR_AERIAL_DISTANCE`) updates on camera/sun/air change, applies in
  composite (additive with `fog` plugin in `Lit`), skipped by glass/blends. Fixed integration steps.

```odin
render.scene_world(r, world_id, fresh = false)
render.scene_set_indirect(r, 1.0)
sun := render.Sun_Desc{
    direction = {0.4, 0.7, 0.5}, color = {1, 1, 1}, illuminance = 100_000,
    enabled = true, disc = true, indirect = 1, scattering = 1,
}
render.scene_set_environment(r, sun, {sky_atmosphere = true, air = render.AIR_EARTH})
```
