# An image too dark or too bright

Never guess a number: measure, change one thing, measure again.

## 1. Measure

```sh
mirai capture . --out shot.png                    # the scene's camera; or --scene S
mirai capture . --out shot.png --position 0,3,10 --target 0,1,0 --fov 60
mirai image stats shot.png                        # mean_luma, black_percent, saturated_percent
```

`mean_luma` is linear luminance 0 to 1; `black_percent` and `saturated_percent` are the share of
crushed and clipped pixels. In a played game, `capture` with a `path`. Look at the PNG too:
a good mean can still hide a black corner. `engine.status` gives the `ev100` the editor's view
uses.

## 2. Find the cause

- **Black, `black_percent` near 100:** no enabled `Sky` or `Sun`, a `Sun` with `illuminance` 0,
  or the plugin of a component missing. `scene.inspect` finds them; turn them on.
- **Dark everywhere though light is there:** a negative `compensation`, or `Manual` with an EV that
  is too high. Raise `compensation` in the `View_Volume` of the whole scene.
- **Sunlit, but shadows and rooms are black:** the sky is weak against the sun (lux against
  nits). Raise `Sky.luminance`, use `atmosphere`, or add lamps.
- **Washed out, `saturated_percent` high:** a positive `compensation`, or `Manual` with an EV that
  is too low. Lower `compensation`.
- **Brightness drifts as the camera turns:** `Auto` meters the lamps in view (night, interiors).
  Use `Manual`, or a narrow `min_ev100` to `max_ev100`.
- **Editor and game differ:** a camera has its own `Exposure`, or a `View_Volume` zone applies.
- **Wrong only for a moment after a cut:** adaptation; `adaptation` is the seconds it takes, and
  the first frame is metered at once.

Who decides, highest first: the `Exposure` of the camera; the `View_Volume` where the camera
stands (a `Volume` with `priority`; one that `Add`s adds its `compensation`); the default.

## 3. Fix

1. Brightness of the whole scene: `compensation` in EV on the `View_Volume` that has no `Volume`.
   +1 doubles the light of the image; move by half an EV or one, then capture. Set
   `exposure.compensation` of that `View_Volume` with `scene.set` or the inspector.
2. A game that must look the same everywhere: `exposure.mode` `Manual` in that `View_Volume`,
   with `aperture`, `shutter` and `iso` (f/16, 1/125 s and ISO 100 is a sunny day), and then
   adjust `compensation`.
3. Light that is out of balance (sun against sky, lamps against daylight) is fixed in the
   light, not the exposure: sun in lux (clear noon 100000), sky in nits, point and spot lights
   in candelas, rect lights in nits. A 1000 cd lamp is invisible at noon and lights a room at
   night.
4. A view that must expose differently from its scene (a monitor, a cinematic camera) carries
   its own `Exposure`; do not use it to fix a scene.

## Pitfalls that fail silently

- A zeroed `View_Volume` literal has a black tint: copy `render.VIEW_VOLUME_DEFAULT`.
- `compensation` on a camera `Exposure` replaces the scene's exposure for that camera only.
- Under `Auto`, a dark image means `compensation` is negative or the range (`min_ev100`,
  `max_ev100`) clamps it: check them before adding light.
- A change in the editor's view does not change the game: save the scene (`scene.save`).
