# Animation API methods

The `animation.*`, `skeleton.*` and `pose.profile.*` methods belong to `plugins/animation/editor`
(and `animation.capture`, to the `previews` plugin) and exist with the plugin active. Fields,
defaults and results: `mirai rpc describe animation.` (or `skeleton.`, `pose.`); common conventions
(concurrency, errors, `engine.describe`): [method
catalog](../../mirai-agent-api/references/methods.md); flows and contracts:
[authoring](animation-authoring.md).

- **Intent**, first: `skeleton.body.detect/set`, `animation.character.setup`, `animation.request`,
  `animation.clip.edit` and `animation.analyze`. It is looked at with `animation.preview` and
  `animation.capture` and inspected with `animation.inspect` and `animation.asset.inspect`.
- **Expert layer**, for fine work: clips, tracks, keys and markers, skeletons and sockets, `.pose`
  profiles, blend spaces, graphs, `.motion`, `.action`, bakes, morphs and
  [timelines](animation-timeline.md).

## Common errors

- Asking for `plays`, targets, actions or intents in Edit: they require Play/Simulate, and the `fix`
  proposes `animation.preview` with the same fields
  ([control](animation-authoring.md#per-instance-control-and-preview)).
- Expecting the change on disk: what is published stays in the registry unsaved until `asset.save`
  ([files](animation-authoring.md#files-and-history)).
- Sending indices, slots or quantities: the API names parameters, operations, effectors, clips,
  modes, gestures and body parts, and derives the quantities from the lists.
- Expecting `locomote` to move the body: its controller moves it.
- Adding or removing nodes or masks with `animation.graph.patch`: that is `graph.set`.
- Looking for states, transitions or triggers in a graph: they do not exist; locomotion is a
  `.match` and the rest, actions and `plays` ([what replaces
  them](animation.md#what-replaces-the-state-machine)).
- A `.blend` as the asset of an entity: it is an aim offset or additive, under an `Additive` of an
  `.agraph` (`Additive_Space`).
- Editing a track longer than the capacity of `animation.track.set`: `animation.key.set` edits one
  key at a time.
- Testing blindly: `dry_run` validates every `create`, `set`, `patch`, bake and edit without
  writing.
- `animation.character.setup` over a large library: past the clips a `.match` or an `.action`
  takes it fails with `Capacity`; `clips` names the ones to classify.
- Importing a source again to get a library of chosen clips: `animation.clip.edit` with the `path`
  of an existing `.anim` of the same skeleton and no `edits` copies a clip there.
