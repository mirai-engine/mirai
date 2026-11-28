# A painted look

A stylized game keeps the lights, shadows and fog of the engine and changes how surfaces take
them, how the sky changes and how the image is graded. Nothing of it needs a `.Post` shader.

## Stylized surfaces

A material with `stylized` on reflects diffuse light alone, with no shine:

- `softness` is how wide the edge between light and shade is: 1 is the smooth falloff of a real
  surface, 0.05 a hard painted edge, and the side that faces a light is lit evenly.
- `shade` multiplies the light around it (sky and bounced light): the color and depth of its
  shadows. `[1,1,1]` keeps the light of the world; `[0.45,0.4,0.7]` is a deep violet shade.
- The shadows of the sun and the lights fall on it as on any surface; lights of spells light it.

```sh
$P material.set '{"material":"terrain/grass.mat","values":{"stylized":{"enabled":true,
  "softness":0.08,"shade":[0.55,0.5,0.8]}}}'
```

A Surface program sets `s.stylized=true`, `s.stylized_softness` and `s.stylized_shade` in its
`evaluate`; one entity changes them with `material_value` (`stylized`, `stylized_softness`,
`stylized_shade`, [look.md](look.md)). `unlit` is for what takes no light at all: it shows its
`emission` alone.

## Sky changes

A Sky program (`//! mirai sky`) draws the image of the whole sky once, when its material,
parameters or sun change: a few milliseconds, not something to do every frame.

- A change of mood (a spell darkens the sky): give `Sky.from` the look it leaves and drive
  `Sky.fade` from 1 to 0. Each look is drawn once and the frames blend them.
- Clouds that drift: turn the entity of the `Sky` slowly; turning it draws nothing again.
- A painted backdrop that does not light the world: `use_background` with a `background_image`.

## Haze

A `Fog_Volume` in a `Box` as large as the level gives haze by distance without the air of an
atmosphere. `color` `[0,0,0]` scatters no light, so the haze is the flat `glow` (nits) of its
own; `falloff` thins it upwards so the sky stays clear above the horizon. Give `glow` about the
luminance of the sky at its horizon: much less shows as a dark band. A `Manual` exposure keeps its
color the same everywhere ([exposure.md](exposure.md)).

```sh
$P scene.write '{"entities":[{"name":"Haze","position":[0,0,0],"components":{
  "Volume":{"shape":"Box","extents":[2000,200,2000]},"Fog_Volume":{"density":0.02,
  "color":[0,0,0],"glow":[3600,4000,4800],"falloff":0.02}}}]}'
```

## Grading

`ColorGrade` is a built-in PostProcess program: `tint`, `saturation`, `contrast` (around middle
gray) and `gamma`, for the whole image and again for its shadows, midtones and highlights. Make a
material with it and put it in a layer of the `View_Volume`; a layer off, or none, leaves the
image exactly as it was.

```sh
$P material.set '{"path":"looks/painted.mat","values":{"program":"ColorGrade"},
  "parameters":{"saturation":[1.25,1.25,1.25],"contrast":[1.15,1.15,1.15]}}'
$P scene.write '{"entities":[{"name":"Look","components":{"View_Volume":{
  "layers":[{"material":"looks/painted.mat","enabled":true}]}}}]}'
```

A `View_Volume` with a `Volume` grades only there (a cave, a dream), blended over `zone.blend`.
