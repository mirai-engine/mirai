---
name: audio
description: Sound in a game - `.sound` and `.sound_set`, `Audio_Source`, `audio.play_asset`,
  positional audio, buses, ducking, volume options, reverb volumes, occlusion, music, ambience.
---

# Game audio

Package `audio "mirai:engine/audio"`. Sounds are assets named by `base.Asset_Id` (import:
[assets](assets.md)).

## Map
- Entity sound (speaker, engine, music): [source](#a-source-on-an-entity); from code (hit,
  pickup): [one-shots](#one-shots-from-code); variations: [sets](#sets).
- Levels, ducking, options: [buses](#buses). Caves, walls: [rooms](#rooms-and-occlusion).
  Nothing is heard: [pitfalls](#pitfalls).

## A source on an entity
```odin
source := audio.AUDIO_SOURCE_DEFAULT
source.sound, source.loop, source.spatial = HUM, true, true
source.volume, source.max_distance = 0.7, 25
```

- Put it in the scene; the library starts, moves and stops the voice. `spatial` pans and
  attenuates from the entity; without it `pan` places it.
- The listener is the entity with `Audio_Listener` (the player's eyes), else the view.
- Game code drives it by writing `playing`, `volume`, `pitch`, `pan`, `loop` through
  `core.writable` on a `^core.Table(audio.Audio_Source)`.

## One-shots from code

Only from a function that takes `app:^host.App` and `time:core.Time`:

```odin
@(step="fixed")
crash_sound :: proc(app:^host.App, time:core.Time, broken:core.Ref(destruct.Destruct_Events)) {
    for f in broken.fractured.items {audio.play_asset_at(app, time, CRASH, f.point)}
}
```

- `play_asset` has no place (`pan`) and no room reverb; `play_asset_at` is positional with all
  of it. Both default to `BUS_EFFECTS`. `play_source(_at)` take a whole `Audio_Source`.
- They return a `Voice`: `audio.stop(app, voice, fade)`, `audio.playing`, `audio.source_place`,
  `audio.source_tune`. What loops or follows a thing is better as an `Audio_Source`.

## Sets
A `.sound_set` picks one sound (weights, volume and pitch ranges) each time it starts; use its
id where a sound id goes. `sound_set.set` makes one (`path`, `values`, `.sound` ids from
`asset.list`); `sound_set.inspect` reads it.

## Buses

`BUS_MASTER`, `BUS_MUSIC`, `BUS_EFFECTS` (default), `BUS_VOICE`, `BUS_UI`. Add your own as
constants below `AUDIO_BUS_CAPACITY`: `BUS_AMBIENCE :: audio.Audio_Bus(5)`.

`Audio_Settings` (project setting) mixes a bus: `gain` in dB (0 as it comes; `volume` fields
are linear), `lowpass`, `reverb`, ducking
(`duck_by`, `duck_amount`, `duck_threshold`). Edit it in Project Settings, with `settings.set`
(`settings.get` shows the shape) or `audio.audio_bus_setting_set`.

`Audio_Volumes` is the player's choice per bus, 0 to 1 (`more[]` for added buses), kept with their
options: a slider bound to `Audio_Volumes.music` writes it itself; the game writes nothing.

## Rooms and occlusion

- `Audio_Reverb` on an entity with a `Volume` (`engine/volume`) is the room where the listener
  is; it blends over `blend`, higher `priority` on top. Without a `Volume` it is the level's.
  One reverb sounds at a time. `Audio_Source.reverb` is how much of a source goes to it.
- `Audio_Occlusion` beside a spatial `Audio_Source` muffles it behind solids (needs `physics`).

## Pitfalls

- A zeroed `Audio_Source` is silent: start from `AUDIO_SOURCE_DEFAULT`. Zero `pitch` means 1.
- A non-looping source that ended stays `ended` until `playing` is cleared: set false, then true.
  Changing `sound`, `bus` or the curve restarts the voice; the other fields tune it live.
- `play_asset*` return a zero `Voice` silently: no mixer (headless), no free voice, bus over
  capacity, rollback replay.
- A source that cannot sound is a problem of its entity: see `engine.diagnostics` (`audio.*`).
- Hear it in an open editor session: `audio.play`; `audio.status` shows the buses.
