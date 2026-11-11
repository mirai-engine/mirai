---
name: world
description: Author an outdoor or indoor scene in a Mirai game - terrain, foliage, water, sky, sun,
  fog, lights, exposure, and what to do when an image is too dark or too bright.
---

# Game world

A scene is entities with components, a file of `assets/` written through `mirai rpc` or in the
editor.

## Map

- A whole scene in one `--batch` file: [whole-scene.md](assets/whole-scene.md).
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

```json
{"method":"scene.add","params":{"name":"Sky","components":{"Sky":{}}}}
{"method":"scene.add","params":{"preset":"sun"}}
{"method":"scene.add","params":{"name":"Look","components":{"View_Volume":{"exposure":{"compensation":0.5}}}}}
```

A component starts from its defaults and takes the fields named. The `sun` preset aims it like the
editor's sun, shining toward its -Z; a `View_Volume` without a `Volume` is the whole scene.

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

Auto by default, and a sunny scene needs nothing else: it meters the light, and in the sun a shadow
in view does not brighten what is lit. A camera's own `Exposure` replaces everything; otherwise
the `View_Volume` where it stands; otherwise the default. Details, and an image too dark or too
bright, step by step: [exposure.md](world/exposure.md).

## Pitfalls that fail silently

- No enabled `Sky` and `Sun` (or a `Sun` with `illuminance` 0): a black image, not an error.
- A zeroed `Sky`, `Sun` or `View_Volume` literal is not the default: copy the `*_DEFAULT`.
- A camera `Exposure` added to fix one scene stays when the scene changes.
- Terrain, foliage and edited assets stay unsaved until `asset.save` and `scene.save`.
