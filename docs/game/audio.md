---
name: audio
description: Sound in a game - `.sound` and `.sound_set`, `Audio_Source`, `audio.play_asset`,
  positional audio, headphones and speakers, buses, ducking, volume options, reverb volumes,
  occlusion, materials, music, ambience.
---

# Game audio

Package `audio "mirai:engine/audio"`. Code names a sound by its path in the assets, a field by
its `base.Asset_Id` (import: [assets](assets.md)).

## Map
- Entity sound (speaker, engine, music): [source](#a-source-on-an-entity); from code (hit,
  pickup): [one-shots](#one-shots-from-code); variations: [sets](#sets).
- Levels, ducking, options, headphones: [buses](#buses). Caves, walls:
  [rooms](#rooms-and-occlusion). Nothing is heard: [pitfalls](#pitfalls).

## A source on an entity
```odin
source := audio.AUDIO_SOURCE_DEFAULT
source.sound, source.loop, source.spatial = HUM, true, true
source.volume, source.max_distance = 0.7, 25
```

- Put it in the scene; the library starts, moves and stops the voice. `spatial` places it at the
  entity: attenuated, duller far away, heard from its direction; without it `pan` places it.
  `directivity` (0 to 1, `directivity_power` narrower) aims it toward -Z of the entity.
- The listener is the entity with `Audio_Listener` (the player's eyes), else the view. Game code
  writes `playing`, `volume`, `pitch`, `pan`, `loop` (`core.writable` on its table).

## One-shots from code
Only from a function that takes `app:^host.App` (it loads the sound) and `time:core.Time`:

```odin
@(step="fixed")
crash_sound :: proc(app:^host.App, time:core.Time, broken:core.Ref(destruct.Destruct_Events)) {
    for f in broken.fractured.items {audio.play_asset_at(app,time,"arena/crash.sound",f.point)}
}
```

- `play_asset` has no place (`pan`) nor room reverb; `play_asset_at` has both. Both take a path or
  an id and default to `BUS_EFFECTS`; `play_source(_at)` take a whole `Audio_Source`.
- They return a `Voice`; `audio.stop(mixer,voice,fade)`, `playing`, `source_place`, `source_tune`
  take `mixer:^audio.Mixer`. What loops or follows a thing is better as an `Audio_Source`.

## Sets
A `.sound_set` picks one sound (weights, volume and pitch ranges) each time it starts; use its
path or id where a sound goes. `sound_set.set` makes one (`path`, `values`, `.sound` ids from
`asset.list`); `sound_set.inspect` reads it.

## Buses
`BUS_MASTER`, `BUS_MUSIC`, `BUS_EFFECTS` (default), `BUS_VOICE`, `BUS_UI`. Add your own as
constants below `AUDIO_BUS_CAPACITY`: `BUS_AMBIENCE :: audio.Audio_Bus(5)`.

`Audio_Settings` (project setting) mixes a bus: `gain` in dB (0 as it comes; `volume` fields are
linear), `lowpass`, `reverb`, ducking (`duck_by`, `duck_amount`, `duck_threshold`). Edit it in
Project Settings, with `settings.set` (`settings.get` shows the shape) or
`audio.audio_bus_setting_set`.

`Audio_Volumes` is the player's choice per bus, 0 to 1 (`more[]` for added buses), kept with their
options: a slider bound to `Audio_Volumes.music` writes it itself; the game writes nothing. So is
`Audio_Output.kind`: `.Speakers` (default: panned) or `.Headphones` (ahead, behind, above).

## Rooms and occlusion
- `Audio_Reverb` on an entity with a `Volume` (`engine/volume`) is the room where the listener
  is; it blends over `blend`, higher `priority` on top. Without a `Volume` it is the level's.
  One reverb sounds at a time. `Audio_Source.reverb` is how much of a source goes to it.
- `Audio_Occlusion` beside a spatial `Audio_Source` muffles it behind solids (needs `physics`) as
  far as it is hidden (`radius`: its size). `Audio_Material` on a body says how much of its lows,
  mids and highs get through; without one, as a wall.

## Pitfalls
- A non-looping source that ended stays `ended` until `playing` is cleared: set false, then true.
  Changing `sound`, `bus` or the curve restarts the voice; the other fields tune it live. Zero
  `pitch` means 1.
- `play_asset*` return a zero `Voice` silently: no mixer (headless), a path the assets do not
  have, no free voice, bus over capacity, rollback replay.
- A source that cannot sound is a problem of its entity: see `engine.diagnostics` (`audio.*`).
- Hear it in an open editor session: `audio.play`; `audio.status` shows the buses.
