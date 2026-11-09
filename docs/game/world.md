---
name: world
description: Author an outdoor or indoor scene in a Mirai game - terrain, foliage, water, sky, sun,
  fog, lights, exposure, and what to do when an image is too dark or too bright.
---

# Game world

A scene is entities with components, written by a content tool
([assets](assets.md)) or in an open editor session (`mirai session start .`,
then `mirai rpc --project . <method> '<json>'`; params: `mirai rpc --project . describe
<method>`). Fields and defaults of a component: `engine.describe`.

## Map

- Ground, hills, paths, trees and grass: [terrain-foliage.md](world/terrain-foliage.md).
  **Use the terrain and foliage plugins for natural ground and vegetation; never build them
  from cubes, planes or hand-made meshes.**
- Sea, lakes, fog and haze: [water-fog.md](world/water-fog.md).
- Sun, sky, indoor lights: [Light](#light). Brightness of the image: [Exposure](#exposure). Its
  color on the display: [display transform](world/exposure.md#display-transform).
- An image that is too dark or too bright, step by step: [exposure.md](world/exposure.md).
- Walking on it, swimming in it: [character](character.md).

## Plugins

In `project.mirai`: `"plugins": ["spawn","physics","terrain","foliage","water","fog"]`.
`foliage_terrain` (foliage standing on terrain) turns itself on when both are listed; `water`
brings `fog`. A plugin not listed skips its components in a scene without an error.

## Light

A new scene starts with a `Sky` and a `Sun`. Sky luminance is in nits, the sun in lux (a clear
noon is 100000), point and spot lights in candelas, rect lights in nits.

```odin
sky:=render.SKY_DEFAULT                 // start from the defaults: a zeroed Sky is black
sun:=render.SUN_DEFAULT
look:=render.VIEW_VOLUME_DEFAULT        // a zeroed View_Volume has a black tint
look.exposure.compensation=0.5
aim:=linalg.quaternion_between_two_vector3([3]f32{0,0,1},linalg.normalize(render.SUN_DIRECTION))
asset.scene_set(&s,sky_entity,"Sky",&sky)
asset.scene_set(&s,sun_entity,"Sun",&sun)
asset.scene_set(&s,sun_entity,"Transform",&core.Transform{{},aim,{1,1,1}})   // shines toward -Z
asset.scene_set(&s,look_entity,"View_Volume",&look)                          // whole scene
```

- Sky: `luminance` and an `image` (a 2:1 equirectangular HDR), or `atmosphere=true` for the air
  lit by the sun: turning the sun entity then changes the whole day. One `Sky` is on at a time;
  without one there is no sky light and the background is black. One `Sun` is on at a time.
- API: `scene.add {"preset":"sun"}` aims it like the editor's sun; `scene.set {"entity":"Sun",
  "components":{"Sky":{"atmosphere":true}}}` changes only the fields named.
- Indoor: turn the `Sun` off (`"enabled":false`) when the room has no window, keep the `Sky` if
  a window shows it, and light with `Point_Light`, `Spot_Light` and `Rect_Light` (`range` in
  metres; spot and rect lights shine toward their -Z). Emission of materials is in nits.
- Zones: a `View_Volume` or `Fog_Volume` with a `volume.box(half,blend)` or
  `volume.sphere(radius,blend)` applies only inside it, with `blend` metres of edge and a
  `priority`; without a `Volume` it is the world's. A `Volume` with `extents` and no `shape` is the
  whole world: the problem `volume.unbounded_extents` says so.

## Exposure

The image is exposed per view: a camera's own `Exposure` replaces everything; otherwise the
`View_Volume` where it stands; otherwise the default. `Auto` meters the light (a white room does
not turn gray, a dark one is not lifted by what it reflects) between `min_ev100` and `max_ev100`
and adapts over `adaptation` seconds; `Manual` uses `aperture`, `shutter` and `iso` (f/16, 1/125,
ISO 100 is a sunny day). `compensation` adds EV to both: +1 doubles the light of the image.

- Fix brightness in the `View_Volume` of the whole scene, not in the camera.
- A night or a lamp-lit scene meters whatever lamps are in view: use `Manual`, or a narrow range.
- Check with `mirai capture . --out shot.png` (its `stats`) before and after each change.

## Pitfalls that fail silently

- No enabled `Sky` and `Sun` (or a `Sun` with `illuminance` 0): a black image, not an error.
- A zeroed `Sky`, `Sun` or `View_Volume` literal is not the default: copy the `*_DEFAULT`.
- A camera `Exposure` added to fix one scene stays when the scene changes.
- `Fog_Volume` defaults are a heavy fog: lower `density` for haze.
- Terrain, foliage and edited assets stay unsaved until `asset.save` and `scene.save`.
