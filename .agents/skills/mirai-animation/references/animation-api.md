# Animation API methods

The `animation.*` and `skeleton.*` methods belong to `plugins/animation/editor`
(and `animation.capture`, to the `previews` plugin) and exist with the plugin active. Fields,
defaults and results: `mirai rpc describe animation.` (or `skeleton.`); common conventions
(concurrency, errors, `engine.describe`): [method
catalog](../../mirai-agent-api/references/methods.md); flows and contracts:
[authoring](animation-authoring.md).

- **Intent**, first: `skeleton.body.detect/set`, `animation.character.setup`, `animation.request`,
  `animation.clip.edit` and `animation.analyze`. It is looked at with `animation.preview` and
  `animation.capture`, inspected with `animation.inspect` and `animation.asset.inspect`, and read
  across the ticks of a Play with `animation.history`.
- **Expert layer**, for fine work: clips, tracks, keys, markers and spans, skeletons and sockets,
  the tables of a `.character` (`animation.action.set`, `animation.space.set`,
  `animation.motion.set`, `animation.modifier.set`), bakes, morphs and
  [timelines](animation-timeline.md).

## Common errors

- Asking for parameters, targets, actions or intents in Edit: they require Play/Simulate, and
  the `fix` proposes `animation.preview` with the same fields
  ([control](animation-authoring.md#per-instance-control-and-preview)).
- Expecting the change on disk at once: the file is written when the step ends
  ([files](animation-authoring.md#files-and-history)).
- Sending indices, slots or quantities: the API names parameters, operations, effectors, clips,
  modes, gestures and body parts, and derives the quantities from the lists.
- Expecting `locomote` to move the body: its controller moves it.
- Looking for a graph, states, transitions or triggers: they do not exist; locomotion is a
  the match of a `.character` and the rest, its layers and actions ([what replaces
  them](animation.md#what-replaces-the-state-machine)).
- Playing a match clip by its name: `actions` plays an action of the set; add one for the clip
  with `animation.action.set` (no layer: the whole body).
- Writing the seconds of a section or a window into the set: they are spans of the clip
  (`animation.marker.set` with a `duration`), and the set names them.
- Editing a track longer than the capacity of `animation.track.set`: `animation.key.set` edits one
  key at a time.
- Testing blindly: `dry_run` validates every `create`, `set`, bake and edit without writing.
- `animation.character.setup` over a large library: past the clips a `.character` takes it fails
  with `Capacity`; `clips` names the ones to classify.
- Importing a source again to get a library of chosen clips: `animation.clip.edit` with the `path`
  of an existing `.anim` of the same skeleton and no `edits` copies a clip there.
