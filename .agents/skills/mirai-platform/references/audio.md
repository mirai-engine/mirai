# Package `audio`

SDL-free mixing library (`std/base`, `core:sync`, `core:thread`, `core:math`,
`vendor:stb/vorbis`). The output
device is in [`platform`](platform.md#audio-device).

## Mixer

`mixer_create(Mixer_Desc)` sets the sample rate, output channels (1 or 2), capacities and the speed
of sound. `mixer_render(m,out)` replaces `out` with interleaved f32 frames, under full scale
through the [limiter](#buses) of the master.

### Threads

`mixer_render` can run on an audio thread; everything else belongs to a single other thread (the
game thread), with no shared locks. With `decoder_thread`, the mixer has a third thread of its own
that decodes [feeds](#feeds):

- The game thread's requests enter a lock-free single-producer single-consumer queue; when full,
  the function returns false or a handle 0 and adds to `commands_dropped`.
- The audio thread drains the queue at the start of each chunk of `CHUNK_FRAMES` (or less, if the
  request is shorter) and ramps across the chunk the changes of volume, pan, position, pause and
  buses.
- What it reports (finished voices, released sounds and feeds, clock, underruns) comes back
  through atomics. `mixer_update`, once per frame on the game thread, frees what finished and,
  without a decoder thread, decodes the feeds ahead.
- As long as parameters do not change, one call or chunks of any size give the same samples.
- `mixer_destroy` requires that the audio thread is no longer rendering.

## Sounds

Mono or stereo, at its own sample rate. `sound_create` copies f32 samples. `sound_load` takes a
WAV, an Ogg Vorbis or a lossless file, told apart by their first bytes:

- **Kept encoded**: a lossless file whose blocks fit half a feed, and a WAV of 8 or 16 bits, are
  copied as they are; each voice decodes them from a feed. Loading decodes nothing: it checks the
  header and the block table (a file whose blocks point past its end is refused) and copies. A
  damaged block plays as silence.
- **Decoded whole** to interleaved f32 when it loads: any other WAV and every Ogg Vorbis (a Vorbis
  decoder per voice would weigh more than the decode of a short sound; long ones are streams).
- A WAV sample that is not a finite f32 decodes as 0.

- **Lossless** (`lossless.odin`, written by `lossless_encode`): 16 bit samples coded as FLAC codes
  them, in blocks that decode on their own, each indexed so that a stream starts at any frame.
  Decoding gives the same f32 as a 16-bit WAV of the same samples.

- `sound_stream` decodes while playing and does not copy the file: it must stay in memory until
  the sound is destroyed and a later `mixer_update` frees it.
- `sound_destroy` invalidates the handle at once and ends its voices; the memory is freed in a
  later `mixer_update`, once the audio thread let go of it and no decoder reads it.
- `decode`, `wav_decode` and `vorbis_decode` work without a mixer. WAV is read in Odin (integer and
  float PCM, also `WAVE_FORMAT_EXTENSIBLE`; a truncated file delivers the complete frames); Vorbis
  with `stb_vorbis`, with all its memory in one allocator block. More than two channels give
  `Unsupported_Format`.

### Feeds

A voice of a sound kept encoded, or of a stream, plays from a feed: a ring of decoded frames that a
decoder fills ahead and the audio thread reads without waits (`feed.odin`). Every voice of a sound
kept encoded takes a feed of a preallocated pool, with a decoder state of its own; a stream has one
feed, with its own decoder and a larger ring.

- **Who decodes.** The mixer's decoder thread wakes when a voice starts and every few milliseconds
  while a feed plays. Without one, `voice_play` fills the new feed and `mixer_update` the rest: it
  must then be called more often than a ring lasts. Whoever renders faster than real time (a
  recording) calls `mixer_decode` before each render. One decoder at a time fills the feeds.
- **Phases.** The game thread readies a free feed and hands it over; the decoder seeks and fills
  it until the audio thread lets go of it; `mixer_update` takes it back. Neither the game thread
  nor the audio thread touches a feed the decoder holds.
- A voice whose first frames are not decoded yet waits silent; one whose ring empties goes silent
  (`underruns`) and resumes where it was. With a decoder thread a voice may start a chunk late: a
  `start_frame` far enough ahead is kept exactly.
- A lossless block of a feed of the pool is decoded whole, once the rest of it fits the ring: a
  seek is block exact plus a discard.
- `offset` seeks before the ring fills; a loop starts over from the beginning and is sample exact,
  also for interpolating. `voice_set_loop(false)` ends at the next end of the sound, whatever was
  decoded ahead; turning a loop on applies at an end not decoded yet.
- The pitch of a voice that plays from a feed has a cap of source frames per output frame.
- No free feed: `voice_play` returns 0 (`feeds_busy`). A stolen voice holds its feed until the
  audio thread lets go of it, which is why the pool is larger than the voices.
- A stream plays in one voice at a time: another playback returns 0 (`streams_busy`) until a
  `mixer_update` sees its feed come back, and then it starts from the beginning. Its voice is not
  stolen.

## Voices

`voice_play(m,sound,desc)`: start from `VOICE_DEFAULT`, because a zeroed desc is silent. The handle
is valid until a `mixer_update` sees the voice finish or until it is stolen; operations on an
invalid one return false.

- **Resampling** linear; with a step of exactly 1 the samples are copied. In a loop, the frame
  after the last is the first, also for interpolating.
- **Pan.** Mono: constant power. Stereo: balance, lowers the side it moves away from.
- **Fades**: an exact linear envelope to the sample. A voice that is leaving to stop does not
  accept another fade.
- **Stop without fade and pause** drop to silence with a ramp in the current chunk and resuming
  rises with another; a paused voice keeps its position, and one that is paused or has not started
  yet is stopped at once.
- **Aligned start.** With `start_frame` (mixer clock) the first sample comes out exactly on that
  frame, even if it falls in the middle of a render.
- **Send.** A spatial voice, or one with a reverb send, is mixed apart: a spatial one goes through
  its [direct effect and its output](#positional-audio), then any voice through its send, ramped
  without clicks; a binaural voice is sent as one source, before its HRTF. Any other goes straight
  to its bus, at no extra cost.
- **Stealing.** Without free voices, `voice_play` takes the one with the lowest priority and,
  among equals, the oldest, if its priority does not exceed the new one's; if not, it returns 0.
  The stolen handle stops being valid at once and its sound drops to silence within a chunk.

## Buses

Every voice sounds on a bus and every bus on the one it sends to, the master (`BUS_MASTER`) by
default, which is what is written; buses are a fixed set, never a graph, and are not destroyed. A
game's named buses belong to [`engine/audio`](../../mirai-gameplay/references/libraries.md#audio).

- `bus_set_send`: a bus sends only to the master or to one created before it, so the buses mix
  from the last to the first without a loop. A bus ducked by one created before it hears that
  one's peak of the last chunk.
- **Limiter.** The master, after the mono downmix, goes through a limiter with no lookahead (Godot's
  hard limiter without its delay, so the mix adds no latency): a frame that would pass
  `LIMITER_CEILING` brings the gain down to it at once, which holds `LIMITER_HOLD` and comes back
  in `LIMITER_RELEASE`. A mix that never reaches full scale comes out as it is.

- Volume and mute are ramped within a chunk; a muted bus keeps its volume.
- `bus_set_duck`: while the peak of the `source` bus, measured after its volume and its filter,
  exceeds `threshold`, the bus drops to `1-amount` in `attack` and returns in `release`. The master
  is not ducked and a bus does not duck itself.

## Reverb

`reverb.odin` follows Freeverb; its memory is reserved when the mixer is created. There are two
kinds:

- **The room's**, one per mixer, to which voices send their signal after their gains and their
  filter: a distant or covered voice sends less. `reverb_set` chooses on which bus what it returns
  sounds (the master by default), after the voices and before processing the buses: the volume,
  filter and ducking of that bus reach it. `wet` 0 turns it off and clears its memory.
- **One per bus** (`bus_set_reverb`): it adds its tail to what the bus plays dry, before its
  filter and its volume; a song sounds in a room without depending on the room.

## Positional audio

Right-handed, Y up, meters: a listener without rotation looks toward -Z with +X to its right.
`spatial.odin`, `direct.odin`, `hrtf.odin` and `binaural.odin` translate Steam Audio's direct,
binaural and panning effects.

- Attenuation clamps the distance to [`min_distance`, `max_distance`]: closer than the minimum the
  gain is 1 and farther than the maximum it stops dropping.
- **Direct effect.** Per spatial voice, one gain (attenuation, directivity) and a three-band EQ
  (low shelf, peak, high shelf at 800 Hz and 8 kHz): air absorption over the distance, and
  `occlusion` blending each band toward `transmission`. The EQ is normalized to a peak of 1 with a
  floor of 24 dB, so distance and occlusion take highs first and never raise a band. A change of
  gains crossfades the old and the new cascade over the chunk. While every band is within 0.5 dB of
  unity (near and in sight) the EQ is left out, and on speakers the voice mixes into its bus as a
  panned voice; coming in or out, the EQ crossfades with the dry signal.
- **Output.** `Output_Kind` is one per mixer: on headphones each voice is convolved with the HRTF of
  its direction (bilinear blend of log magnitude and unwrapped phase of the four measurements around
  it), in blocks cut at the chunks whose shared samples crossfade a change of direction. Every voice
  is transformed once (none once it is silent) and its products with the HRTF add up per bus, which
  goes back to time once per chunk into one ring per bus; the output is `BINAURAL_OVERLAP` samples
  late whatever size the render has. A source that turned less than a quarter of the finest spacing
  of the measurements keeps its filters. On speakers the direction, brought to the horizontal plane,
  pans with constant power; a mono output plays it centered.
- The HRTF is the one Steam Audio ships (`audio/hrtf/cipic_124.hrtf`, CIPIC database), at
  `MIXER_RATE`, the one rate the mixer renders at; the device stream converts it to the rate of
  the output, so headphones work on any. It is loaded and transformed, and the binaural state of
  every voice slot reserved, the first time the output is headphones; speakers never pay for it.
- A source at the listener comes from above. A place, velocity, rotation or occlusion that is not
  a number is refused by `voice_play`, `voice_set_position`, `voice_set_occlusion` and
  `listener_set`.
- Doppler takes the velocities along the source-listener line and multiplies the pitch.
- A stereo sound with a position is heard as one source (average of its channels).
- The direct path and the pitch of a positional voice are recomputed on the audio thread when its
  place, its occlusion or the listener change; the HRTF only when its direction changed.

## What it does not do

Resampling better than linear, more than one room reverb, reflections, pathing, baked or
convolution reverb from geometry (a later plugin), ambisonics, a 2D/3D blend of a spatial voice,
propagation delay, other HRTFs than the one shipped, sounds or output of more than two channels,
and seeking or querying the position of a playing voice.
