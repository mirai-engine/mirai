---
name: cues
description: Bind animation markers to positional sound and particle births.
---

# Animation marker cues

Add `anim.Animation_Cues` to the entity playing a clip and fill its bindings with the marker
name, a sound or sound set, and/or a particle birth channel. The effect uses the animated
entity's position by default. Set a bone or socket anchor to use its final world pose instead.
Enable `align_up` to send the anchor's world-space up as the birth normal. A particle emitter
that listens to the channel supplies the effect. The cue runs for each crossed marker during
Play. Replayed ticks regenerate births and suppress one-shot audio.
