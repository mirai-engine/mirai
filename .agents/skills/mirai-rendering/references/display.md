# Units, exposure and display

## Units

Each light source has the photometric unit of its type, as in `KHR_lights_punctual`:

- **Sun**: illuminance in lux on a surface facing it (`Sun.illuminance`).
- **Point and spot**: luminous intensity in candelas, what it gives far away on its axis, whatever
  its size (`intensity`).
- **Rectangle**: luminance of its face in nits (`Rect_Light.luminance`): a larger one gives more
  light. With `material`, the material emission tints it across its width; the brightness is that
  of the light.
- **Sky, background and emission**: luminance in nits; with an image, `Sky.luminance` is that of
  its white. The emission of materials, `Tint`, decals, unlit particles and `Screen.brightness` of
  `monitors` are also nits, except the [exposure-relative one](#exposure-relative-emission).

Render units:

- A luminance in nits times the **light scale** of the scene (`Scene.light_scale`). The
  irradiance of a light is stored as the luminance of the Lambert white it illuminates
  (lux / π): a diffuse of albedo `a` returns `a · D` and the specular lobe is multiplied by π
  ([BRDF](materials.md#brdf)).
- **A single place** converts: `scene_light_update` the local lights, `view_begin` the sun, the sky
  and the background, and the shaders the emission with `render_units` (`frame.sky_color.w` is the
  scale).
- The scale is a power of two that brings the strongest light close to one (`light_scale_of`),
  with hysteresis; without lights it is one. This way the half floats of the targets store a noon
  and a night equally well.
- A new scale is a change of units: the next frame carries the histories and the probe volume to
  it, without starting over ([light of each world](gi.md#light-of-each-world)).
- `firefly_clamp` and the absolute thresholds of the shaders are in render units: they hold the
  same by day and by night. The light that is not worth its shadow ray (`light_cutoff`) is
  measured exposed like the view: in render units, a distant light thousands of times stronger
  lowered the scale and cut the lamp of the room.
- Without GI, the light that arrives around is that of the sky (`indirect_irradiance`,
  `indirect_radiance`) with the occlusion of the material: there is no constant ambient floor.
- The previews and thumbnails studio has its own scale (`STUDIO_UNITS_PER_NIT` of
  `studio.slang`).

## Exposure

`Camera.exposure` (`render.Exposure`; in the world, the `Exposure` component of the camera)
decides how much the light of the view is worth on the display. With an EV100 exposure, the
luminance that a reflected-light meter calls average gives the mid gray, 0.18, raised by the bias
of the display transform (`exposure_of_ev100`).

- **Bias.** Every view is exposed `display_exposure_bias` EV above what its meter or its camera
  gives, by the display transform. Under ACES 2.0 it is `EXPOSURE_BIAS`, as Unreal's default
  exposure bias: ACES 2.0 shows the meter's mid gray dim on an SDR display. Another transform
  calibrates to show that gray with the same light, so choosing one changes the color of a scene
  and not how bright it is. `ev100` and `compensation` do not include it.

- **Manual.** `ev100` of the camera; the component computes it from `aperture`, `shutter` and
  `iso` (`ev100_of`).
- **Auto.** It measures the light, not what the surfaces reflect, like an incident-light meter: a
  white room does not drop to mid gray nor does a dark one rise to it.
  - `exposure_histogram.comp` counts, before TAA, the luminance that a mid-gray card would show
    at each pixel: what it shows minus its emission, over the reflectance given by
    `gbuffer_read`, times 0.18. An unlit does not reflect.
  - Physical emission counts as light; the relative one is subtracted beforehand and does not
    count.
  - The sky counts by the light it gives: each sky pixel, wherever it looks, is worth what a
    horizontal gray card shows under the sky and the sun with nothing in between (`sky_card` of
    `exposure_adapt.comp`). Looking up, down or from afar at the same place measures the same
    light. In a parallel projection (`frame.eye.w` 0) it does not count: all its pixels show a
    single direction.
  - The background (`use_background`), the pixels without light and the almost black surfaces do
    not count. A view that sees nothing that counts keeps its exposure; the first time it starts
    at mid gray under the strongest light.
  - **In daylight the shade does not count.** With the sun up and much of the view out of shade
    (lit by the sun or the open sky, as `sky_card` measures), the pixels in shade leave the meter:
    a tree's shadow in view does not burn what is lit. A dark room with a window stays below that
    share and meters as before.
  - `exposure_adapt.comp` brings to mid gray the geometric mean without the extremes of the
    histogram, limits it to `range` (`AUTO_EXPOSURE_RANGE`) and approaches according to
    `adaptation_mode`: `Time` (default) exponential in EV, 95 % of any change in `adaptation`
    seconds when the light drops and faster when it rises; `Speed` at fixed speed, like Unreal and
    Bevy. 0 in `adaptation`: at once. The model and its constants are in the shader.
  - **Discontinuities.** The first image of a view and the first after a discontinuity take the
    target at once: camera cut, another world or another scene in the same one (`scene_world`),
    another number of views, a shader reload that changes the scene image. `view_camera_cut`
    counts them (`exposure_generation`). Adaptation is left for light changes within a shot.
- `compensation` adds EV in both modes: +1 doubles the light of the image.
- **Who decides.** A single rule, from highest to lowest:
  1. The camera with its own exposure (the `Exposure` component; `Exposure.own` in `render`): it
     uses it entirely.
  2. The [`View_Volume`](../../mirai-gameplay/references/libraries.md#render) where the view is:
     a complete `Exposure` and a tint. The game cameras and those of each seat take it at their
     position; the free editor one, those of shared prefabs, captures and texture views, that of
     the main view (`scene_set_exposure`). With none, `EXPOSURE_DEFAULT`.
- **Tint.** `View_Exposure.tint` multiplies the image in the tonemap (`Gpu_Frame.tint`), after
  exposing it: it does not change what the meter measures.
- **Agreed tolerance.** The ACES 2.0 calibration is not touched: the brightness of a scene is
  decided by its exposure. A view of the demo or the template stays within half a step of the mean
  luminance its art direction gives it; if the meter moves it further away, it is corrected with
  the compensation of its scene (its `View_Volume` without bounds), never in its camera: the
  `Exposure` of a camera is for a view that exposes differently
  from its scene (a monitor, a cinematic), and the viewport does not use it except when looking
  through it.
- **Pools of light in the dark.** The meter brings to mid gray the light it sees, and in a night
  scene that light depends on how many lamps enter the view: in `night` it goes from EV100 −0.4
  looking at the stage to 4.2 under a streetlamp. A fixed compensation leaves the dark view right
  and turns off what is lit when looking at it. Such a scene carries fixed exposure (`Manual`), or
  a narrow range (`min_ev100` and `max_ev100`) if it must adapt a little. `engine.status` gives
  the `ev100` of the viewport.
- **A game without auto exposure.** In the `View_Volume` of each scene, `exposure.mode = Manual`
  with `aperture`, `shutter` and `iso` (f/16, 1/125 s and ISO 100 are EV 15, a sunny day): the
  editor, captures and the game expose the same. A camera that needs another exposure carries its
  own `Exposure`.
- The zero value of `Exposure` is Auto without adaptation and without its own exposure.
- The free editor view exposes like the scene. When it looks through a camera (`camera.set` with
  `entity`) it takes its `Exposure`, if it has one, until it moves or the scene changes; its menu
  also sets a manual EV100
  ([viewport](../../mirai-editor/references/panels.md#viewport-exposure)).

GPU flow:

- Each view has its `exposure` (`Gpu_Exposure`) and its histogram. The `exposure` pass, at the
  start of `Output`, measures and adapts; the tonemap of the same frame reads the buffer.
- `Gpu_Frame.exposure` is the one the GPU left the view in its previous frame
  (`frame_exposure_copy`), which the relative emission uses: while the exposure adapts, it stays
  one frame behind the tonemap. The CPU writes its own when there is no copy (manual exposure,
  after a discontinuity, when the compensation or the light scale changes): the last one it read
  from that generation or `exposure_first`.
- PostProcess before the tonemap sees the exposed image (the meter's mid gray at 0.18 raised by
  the bias). The debug views are not exposed.

### Exposure-relative emission

`Material_Info.emission_mode`: `Physical` (nits) or `Relative`, the value the exposed image shows
whatever the exposure: 1 is a white surface under the light the meter takes, before
the bias, and each doubling is one more EV. It is the one of unlits and the one that comes from
glTF.

- In render units it is worth `emission / frame.exposure` (`emission_render_units`); that of
  `Tint` takes the mode of its material. The G-buffer marks the pixel
  (`GBUFFER_EMISSION_RELATIVE`).
- **It does not illuminate:** the rays that gather light see it as zero (`hit_emission`);
  reflections and what the glass shows behind do (`MIRAI_HITS_SHOW_RELATIVE_EMISSION`).
- **It is not measured:** `exposure_histogram.comp` subtracts it, so that it does not feed back
  with the exposure.

Tests: `render/units_test.odin`. Those that read images use `UNIT_EXPOSURE` (one render unit is
one scene-linear unit) or `TUNED_EXPOSURE`, with which the light limits were set.

## Display transform

The tonemap takes the exposed image (scene-linear Rec.709) to the display with `display_encode`
and then the dither. The debug views show sRGB in [0, 1].

- **Choice.** `Display_Transform_Settings.transform` (`render` library), a setting of the project
  (`settings.set`, `settings.mirai`), never of the machine. The world step
  `display_transform_apply` brings the renderer to it when it changes.
- **Neutral** (default): Khronos PBR Neutral (`pbr_neutral`), which leaves the colors of a material
  as authored up to their highlights: what most games want. The pass computes it
  (`FRAME_FLAG_NEUTRAL`): its curve bends over the gray axis, and a LUT shows that in rings.
- **ACES_2**: the ACES 2.0 Output Transform (`aces.slang`, adapted from OpenColorIO:
  [license](../../../../THIRD_PARTY_NOTICES.md#adapted-code)) for a `Display_Desc` (`DISPLAY_SDR`:
  Rec.709, D65, 100 nits, sRGB): tone scale on the J of its CAM16 model, with the mid gray at 10
  nits, and chroma and gamut compression that preserves hue. A gray stays gray and a very bright
  color goes toward white: for filmic images and strong emissive light.
- **Baking.** `display_build` bakes ACES 2.0 on the GPU (`display_tables.comp`, `display_lut.comp`)
  into `Renderer.display_lut` once, when the renderer starts; the tonemap and the UI particles
  read it when the project chooses ACES 2.0. Its axes are log2 around the mid gray
  (`display_shaper`); outside its range it is clipped.
- **Grading.** A grading LUT would go in the shaper space, before the display LUT; none exists.
- **HDR.** The swapchain is SDR sRGB; PQ or scRGB are pending (issue #53). Another display is
  another `Display_Desc` and another bake.
- **Previews.** Thumbnails, document previews, their background and the UI studio do not go
  through the LUT: they use Khronos PBR Neutral (`preview_encode`), which leaves the base color
  as it is up to its highlights; ACES desaturates and darkens an isolated asset on a neutral
  background. The studio exposes by its main light (`STUDIO_EXPOSURE`); a preview with sun and
  sky, like its frame ([previews](materials.md#material-previews-and-thumbnails)).

Tests: `render/display_test.odin`, `render/display_calibration_test.odin` and
`engine/render/display_transform_test.odin`.
