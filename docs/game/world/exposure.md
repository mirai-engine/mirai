# An image too dark or too bright

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

## How it is exposed

`Auto` meters the light between `min_ev100` and `max_ev100` and adapts over `adaptation` seconds;
`Manual` uses `aperture`, `shutter` and `iso` (f/16, 1/125, ISO 100 is a sunny day). `compensation`
adds EV to both: +1 doubles the light of the image. Set them in the `View_Volume` of the whole
scene, not in the camera; a night or a lamp-lit scene meters whatever lamps are in view, so give it
`Manual` or a narrow range.

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
- **Right brightness, but colors muted or gray:** not the exposure. The project's
  [display transform](#display-transform) is `ACES_2`, or the albedos are.
- **Wrong only for a moment after a cut:** adaptation; `adaptation` is the seconds it takes, and
  the first frame is metered at once.

## 3. Fix

1. Brightness of the whole scene: `compensation` in EV on the `View_Volume` that has no `Volume`.
   Move by half an EV or one, then capture. Set
   `exposure.compensation` of that `View_Volume` with `scene.write` or the inspector.
2. A game that must look the same everywhere: `exposure.mode` `Manual` in that `View_Volume`,
   with `aperture`, `shutter` and `iso`, and then adjust `compensation`.
3. Light that is out of balance (sun against sky, lamps against daylight) is fixed in the
   light, not the exposure ([units](../world.md#light)). A 1000 cd lamp is invisible at noon and
   lights a room at night.
4. A view that must expose differently from its scene (a monitor, a cinematic camera) carries
   its own `Exposure`; do not use it to fix a scene.

## Display transform

How the exposed image reaches the display is a choice of the project, in its settings, not of a
scene or of the machine:

```sh
mirai rpc --project . settings.set \
  '{"settings":{"Display_Transform_Settings":{"transform":"ACES_2"}}}'
```

- `Neutral`, the default: colors arrive as authored up to their highlights. What most games want,
  and stylized art above all.
- `ACES_2`: a filmic image whose colors soften as they brighten, with smooth highlights. For
  realistic or cinematic looks and strong emissive light.

Both show a gray card with the same light: changing one changes the color and contrast of a
scene, not how bright it is.

## Pitfalls that fail silently

- A change in the editor's view does not change the game: save the scene (`scene.save`).
