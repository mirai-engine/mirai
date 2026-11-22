# Render plugins

Seven engine plugins extend the renderer via [`engine/render`][stages] ([hooks/views][ext]) without
importing `render` or `rhi`. They own no GPU resources: each frame requests stage pipelines,
per-view `pass_texture`s, and uploads frame data built in world space and shifted to `Pass.origin`
per pass. Shared shader includes live in `engine/render/shaders` (e.g. `nested_face.slang` +
`pass_nested_faces`). Each plugin's `Editor` part adds its Logic [Create card][cards], selection
gizmos, and `portals` adds the `nested` inspection mode.

| Plugin | Component / Setting | Renderer hooks |
| --- | --- | --- |
| `decals` | `Decal` | `Surface` stage |
| `deform` | `Deform` | Deformable meshes + `Geometry` stage |
| `monitors` | `Screen` | [Texture views][vtex] |
| `portals` | `Portal`, `Traveler` | [Nested views][nested], `Mask` stage, ray/light/probe hooks |
| `fog` | `Fog_Volume`, `Fog_Settings` | `Lit` stage, 3D view history textures, traced shadows |
| `fsr` | `Fsr_Settings` | Custom [pipeline][pipelines] replacing `Resolve` |
| `lens` | `Lens`, `Lens_Volume` | `Post` stage, mipped view textures |

## Decals

`Decal` projects color, emission, normal map, and optional `overrides` (`Roughness`, `Metallic`)
along local `+Y` inside its entity's scale box (`order` low-to-high; `fade` uses original surface
normal; normal map maps R->local X, G->local Z).

- `Surface` stage reconstructs receiver from resolved depth. Color/emission-only decals blend
  directly; material-property decals tile-gather (`DECAL_TILE`), compose in order in world space,
  and repack the G-buffer (lowering metallic on metal falls back to dielectric reflectance).
- Mip level uses `frame.footprint` + box texels/m (avoids reconstructed-depth edge derivatives).
- Not drawn on nested-view pixels or glass.

## Deform

`Deform` deforms an entity's mesh on the GPU (`deform_render`: `deformable_create` + `posed_set` +
`Geometry` pass writing `render.Gpu_Posed_Vertex` via `pass_deformable`), so raster, shadows,
reflections, and motion vectors follow the shape. `speed == 0` rewrites only on parameter/VB change.
Normals come from finite differences over the rest surface. Requires subdivided geometry
(primitives `Cube`/`Plane`/`Cylinder` lack vertices); conservative bounds expand by `reach`;
colliders stay at rest.

Custom equation: add `name.comp.slang` in project/plugin `shaders/` (set `Deform.shape = "name"`):

```slang
// Example: demo/shaders/pulse.comp.slang
#include "programs/plugins/deform/deform.slang"

float3 deform_shape(float3 p, Deform_Shape shape) {
    float h = deform_height(shape, p);
    float3 r = deform_radial(shape, p);
    float len = length(r);
    if (len < 1e-5) return p;
    float wave = sin((h - shape.phase) * 6.2831853 * max(shape.values.x, 1.0));
    float held = shape.pin > 0.0 ? smoothstep(0.0, shape.pin, h) : 1.0;
    return p + (r / len) * (shape.amplitude * wave * held);
}
```

## Monitors

`Screen` displays `camera` (an entity with `Camera`, `active = false` if not main view) on mesh
material `slot` as emitted light (`brightness` nits).

- Screens sharing `(camera, aspect)` share one **feed** at the max size/cadence/quality requested.
- `monitors_render` sets `render.material_screen` on `Material_Live` (derived row via
  `host.assets_material_derive`) and picks the coarsest mip level giving >= 1 texel/pixel (with
  shrink hysteresis). New levels render `WARM_IMAGES` frames before display so history settles;
  off-screen feeds drop to smallest level and slower cadence (kept alive for reflections/portals);
  unreferenced cameras do not render.
- To emit real scene light, pair with `Rect_Light` + `Light_Emission` on the same `slot` ([local
  lights][lights]; keep cover glass thin so shadow rays clear the rect plane).

## Portals

`Portal{exit, mirror, ellipse, layers, wall}` opens the entity's local unit square facing `+Z`
(inscribed ellipse when `ellipse = true`). Front continues behind `exit` rotated 180 deg around Y
without scale (`through_of`). `mirror = true` reflects its own plane (`reflection`), ignoring
`exit`, blocking travel, cutting no wall, and carrying no lights.

- **Render (`gpu.odin`, up to `PORTAL_CAPACITY`):** `Mask` stage assigns a [nested view][nested]
  per facing portal (fullscreen scissored ray-plane mask via `nested_face.slang` avoids near-plane
  clipping). Ray hook forwards reflections/GI/probes/shadows across one gate (`frame.portals`).
  Mirrors place a 0-roughness metal backing behind the mask for secondary reflections. Probe hook
  (`portals_probes.slang`) weights exit irradiance by opening form factor (continuous across
  plane). Light hook brings up to `PORTAL_LIGHT_CAPACITY` exit-room lights
  (`sphere_desc`/`rect_desc`) with two-segment shadows.
- **Travel (`portals.odin`):** `portals_travel` (`fixed`, before `camera_drive`) moves `Traveler`
  physics bodies/characters whose `point` crossed from front via `core.place` ([jump][jump]) +
  `phys.set_velocity`, emitting `Portal_Crossings` (characters right via `character_through`;
  owned `Move_Input` rotates automatically; custom look state rotates by `Crossing.turn`).
- **Walls & half-crossed (`collision.odin`, `doubles.odin`):** Active `wall` gets a
  [`phys.Collider_Cuts`][cuts] hole (`RIM_WIDTH` margin, depth raycast up to `WALL_DEPTH_MAX`, min
  `RIM_DEPTH_MIN`) lined by 4 `Portal_Rim` boxes (`Portal_Frame`). Straddling travelers get a
  `phys.Body_Twin` on the exit side, a behind-wall cut, and frame-instanced mesh doubles
  (`portals_doubles`). `portals_view` projects eye-crossings between ticks, setting
  `core.View.carried` (keeps history) or `core.View.cut` and easing tilt over `RIGHTING_TIME`.
- **Limits:** No glass/particles/decals/overlays or recursive portals through portals; exit does
  not scale; flat mirror/wall frames only; rectangular wall hole even for `ellipse`; one twin per
  traveler (`sim.TWIN_CAPACITY`); covered portals still cost a nested view.

```odin
// In a step reading `crossings: core.Ref(portals.Portal_Crossings)`, rotate custom aim state:
for c in crossings.queue.items {
    if c.who == player { aim_dir = mm.quat_rotate(c.turn, aim_dir) }
}
```

## Fog

`Fog_Volume` is a [volume](../../mirai-gameplay/references/libraries.md#volume) medium (`Box`,
`Sphere`, `Plane`, or `Outline`; unbounded reports `fog.volume` and fills nothing—world haze is
`Sky` air Mie). `density` (1/m), `color` (albedo), `glow` (nits luminance per stopped meter),
`anisotropy` (Henyey-Greenstein ±0.95), height `falloff` above `base`, and `variable` wisps
(`WISP_OCTAVES`, `WISP_DRIFT`, `WISP_CHANGE`, mean = `density`, f64 `wisp_lattice` on CPU). Cap:
`CAPACITY` (16) visible volumes including plugin media (lowest world priorities drop first).
`Fog_Settings.turns`: `Every_Fourth` (default; cells with moved lights/casters/sun relight
immediately) or `Every_Frame`.

### Media from other plugins

Enqueue boxes into `Fog_Media` via `medium_add` before `fog_render` (used by
[water](../../mirai-world/references/water.md)): `dry` carves lower-priority `carved` media and
their sun shade; `sun_only` receives sun shafts only; `shade` (1/m) attenuates sun/ambient along
exit path (`fog_shade`).

```odin
fog.medium_add(media, {
    box = water_xform, density = 0.25, color = {0.2, 0.6, 0.7},
    anisotropy = 0.6, priority = 10, carved = true, sun_only = true, shade = 0.15,
})
```

- **Render (`fog_render`, `Lit` stage):** Frustum froxel grid (`GRID_PIXELS` 8 px up to
  `GRID_COLUMNS` 160 × `GRID_SLICES` 64 to `DISTANCE` 128 m, exponential `SLICE_SCALE`) +
  `FAR_SLICES` closed-form slices to `FAR_REACH` and sky. `fog_far.comp` / `fog_reach.comp` cull
  occluded cells (skipped on `Every_Frame`). `fog_light.comp` evaluates sun (maps + rays via
  `shaders/include/media.slang`), local lights (`MEDIA_LIGHT_BUDGET`), and probe ambient, blending
  temporal light history (`HISTORY`, reset on camera cut or moving shadow/light; wisps stay
  crisp). `fog_integrate.comp` writes `render.MEDIA_TEXTURE` (`render.media_grid`, shared with
  [`vfx`](../../mirai-world/references/vfx.md#volumes)). `fog_apply.comp` composites around the
  nearest glass layer (`FOG_FRONT_LEAST` floor).
- **Limits:** Particles/panels draw after without fog; only nearest glass splits fog; past
  `DISTANCE` no local lights/wisps and hard volume edges; point sun (no penumbra); portal lights
  excluded.

## FSR

AMD FSR 3.1 (`fsr3`, [antialiasing technique][techniques]): replaces `Resolve` with `Full`
pipeline passes from `shaders/fsr3` + `shaders/fsr3_*.comp.slang` (`jitter = .Upscale`, 1×1
`fsr3_exposure`, `Fsr_Settings.sharpness` enables RCAS). With `Graphics_Settings.frame_generation`
(requires `fsr3`), `runtime/framegen.odin` appends optical flow + interpolation after `Output`
reading UI-free `Ldr` into `Generated` ([frame generation][fg]). No FSR 1 or 2.2.

## Lens

Camera optics in `Post` stage (resolved output size, pre-tonemap, zero passes when all effects
off): `Lens` on camera overrides `Lens_Volume` (blends scalars by weight, toggles at `>= 0.5`).
Aperture and shutter come from the view's `Exposure`
([exposure](../../mirai-rendering/references/display.md#exposure)); focal length derives from FOV
and `Lens.sensor` (0.024 = full frame). Deterministic sampling (no per-frame jitter after TAA).

- **Pass order (`pass_image_write`):**
  1. **DoF:** thin-lens CoC capped at `COC_MAX`, half-res bokeh (`lens_dof_bokeh`) + `DOF_TILE`
     foreground dilation; sharp pixels keep full res. No ortho DoF or shaped blades.
  2. **Motion blur:** velocity scaled by `shutter / dt`, capped at `MOTION_MAX` (tile size); sky
     uses camera turn.
  3. **Bloom:** `BLOOM_LEVELS` downsample (Karis average on mip 0) + 3×3 tent upsample;
     energy-conserving blend by `bloom` (no threshold).
  4. **Final:** radial `distortion` (auto-scaled to fill), `chromatic_aberration`, `cos^4`
     `vignette`. GPU timers: `lens dof`, `lens motion`, `lens bloom`, `lens`.

## Verification

- Typecheck each `runtime/` and `editor/`, build demo, open scenes `--headless --validation
  --api-port` (zero validation errors): `decals/decals.scene`, `deform/deform.scene`,
  `monitors/monitors.scene`, `portals/portals.scene`, `portals/portal_chamber.scene` ([portal
  game][game]), `portals/portal_lab.scene`, `gallery/main.scene` (mirror), `church/church.scene`
  (hide `Haze` to isolate fog cost).
- Lens: `mirai test plugins/lens/runtime`, plus `--reference` and `--repeat` captures on
  `lights/night.scene` with `Lens_Volume`.

```sh
mirai rpc scene.write preset=portal
mirai rpc scene.write entity=Haze visible=false
mirai capture --project demo --scene lights/night.scene --reference ref.png --repeat 2
```

[ext]: ../../mirai-rendering/references/views.md#views-cameras-and-extensions
[stages]: ../../mirai-rendering/references/views.md#extension-stages
[cards]: ../../mirai-editor/references/extensions.md#create-cards
[vtex]: ../../mirai-rendering/references/views.md#texture-views
[lights]: ../../mirai-rendering/references/lights.md#local-lights
[jump]: ../../mirai-physics/references/engine.md
[cuts]: ../../mirai-physics/references/physics.md#twins-and-cuts
[nested]: ../../mirai-rendering/references/views.md#nested-views
[game]: ../../mirai-gameplay/references/demo.md#portal-game
[pipelines]: ../../mirai-rendering/references/views.md#render-pipelines
[techniques]: ../../mirai-rendering/references/views.md#antialiasing-techniques
[fg]: ../../mirai-rendering/references/views.md#frame-generation
