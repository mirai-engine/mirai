---
name: audio
description: Sound in a game - `.sound`, `.sound_set` (random, layered, parameters), `Audio_Source`,
  `audio.play`, positional audio, buses, filters, EQ, delay, ducking, snapshots, limiter, volume
  options, reverb volumes, occlusion, materials, music, ambience, engines.
---

# Game audio

Package `audio "mirai:engine/audio"`. Code names a sound by its path in the assets, a field by
its `base.Asset_Id` (import: [assets](assets.md)).

## Map
- Entity sound: [source](#a-source-on-an-entity); from code: [one-shots](#one-shots-from-code);
  at a marker or an ability: [cues](audio/cues.md); variations, layers, parameters: [sets](#sets).
  Levels, filters, ducking, snapshots, options: [buses](#buses). Caves, walls:
  [rooms](#rooms-and-occlusion). Silence: [pitfalls](#pitfalls).

## A source on an entity
```odin
source := audio.AUDIO_SOURCE_DEFAULT
source.sound, source.loop, source.spatial = HUM, true, true
source.volume, source.max_distance = 0.7, 25
```

- Put it in the scene; the library starts, moves and stops it. `spatial` places it at the entity,
  quieter and duller far away, else `pan` does; `directivity` aims it at -Z; `near_radius` stops
  jumps between ears; `delay` starts it late by distance; `spread` (m) widens stereo, 0 a point.
- The listener is the entity with `Audio_Listener` (split screen: one per camera, up to 4, each
  sound heard from the nearest), else the view. Game code writes `playing`, `plays`, `volume`,
  `pitch`, `pan`, `loop` (`core.writable`); a loop restarts at its file's loop start (WAV, Ogg).
- Silent at `max_distance`. With more sources than voices, higher `priority` and then the loudest
  play; the rest keep their time and come back where they would be.

## One-shots from code
Push to `Sound_Requests`, from any step (what stops, loops or follows is an `Audio_Source`):

```odin
@(step="fixed")
crash_sound :: proc(sounds:^audio.Sound_Requests, broken:core.Ref(destruct.Destruct_Events)) {
    for f in broken.fractured.items {audio.play(sounds,"arena/crash.sound",at=f.point)}
}
```

- A path or an id; `at` places it. `bus` (default `BUS_EFFECTS`), `volume`, `pitch`; heard as its
  set's `hearing`, not started beyond its range. A tick plays it once per `by` (what makes it) or
  place: a rollback never plays it twice, yet plays what only the correction asks.

## Sets
A `.sound_set` goes where a sound goes: `Random` picks one (weights, ranges, per-entry `gain`/
`pitch`), `Layered` plays all in step (loops, stems, or delayed cues via `delay` s). `parameters`
drive `curves` (`Gain`/`Pitch`/`Lowpass`) per `layer` (`audio.parameter_set(app, src, "rpm", v)`).
`hearing` sets one-shot range; edit with `sound_set.set`/`inspect`.

## Buses
`BUS_MASTER`, `BUS_MUSIC`, `BUS_EFFECTS` (default), `BUS_VOICE`, `BUS_UI`, plus custom constants
below `AUDIO_BUS_CAPACITY` (`BUS_AMBIENCE :: audio.Audio_Bus(5)`). `Audio_Settings` sets per-bus
`gain` dB, `reverb`, 4 `filters` (`Lowpass`/`Highpass`/`Bandpass`/`Peak`), `delay`, ducking
(`duck_by`, `duck_amount`), `send`, `snapshots` (`audio.snapshot_blend(
mix,"pause",0.5)`; `water` blends `underwater` by listeners under it) and a master limiter. Edit in
Project Settings, View > Audio Mixer or `audio.audio_bus_setting_set`.

`Audio_Volumes` is the player's choice per bus, 0 to 1 (`more[]` for added buses), kept with their
options: a slider bound to `Audio_Volumes.music` writes it itself; the game writes nothing. So is
`Audio_Output.kind`: `.Speakers` (default: panned) or `.Headphones` (ahead, behind, above).

## Rooms and occlusion
- `Audio_Reverb` on an entity with a `Volume` (`engine/volume`) is the room where the listener
  is (several: their average); it blends over `blend`, higher `priority` on top. Without a
  `Volume` it is the level's. `Audio_Source.reverb` is how much of a source goes to it.
- `Audio_Occlusion` beside a spatial `Audio_Source` muffles it behind solids (needs `physics`) as
  far as it is hidden (`radius`: its size). `Audio_Material` on a body says how much of its lows,
  mids and highs get through; without one, as a wall.

## Pitfalls
- An ended one-shot stays `ended`; `plays += 1` plays it again (also while it sounds). `sound`,
  `bus` or the curve restart the voice; the other fields tune it live. Zero `pitch` means 1.
- A source that cannot sound is a problem of its entity, a request one of no entity: see
  `engine.diagnostics` (`audio.*`). Headless, nothing plays. In an editor: `audio.play`
  (`parameters`), `audio.snapshot`, `audio.status` (meters).
