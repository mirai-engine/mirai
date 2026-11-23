# Culling emitters

Two fields of the primary layer of an effect make its emitters wait, whole (every layer):

- `cull_distance` (m, 0: none): those farther than it from every simulation source.
- `max_instances` (0: all): those past the nearest `max_instances` of the effect.

The simulation sources are the bodies the players drive and the `scene.Streaming_Source` entities,
never the camera, so every machine makes the same choice (ties go by entity). In the editor
without Play there are none: every emitter is near.

```odin
fx:=effect.particle_preset(.Fire)
fx.cull_distance, fx.max_instances = 40, 8 // torches: the 8 nearest within 40 m burn
err:=effect.particle_save("assets/particles/torch.particle", &types, {id=id, info=fx})
```

An emitter that waits keeps its particles as they are and does not draw them; its clock stands
still and resumes where it was. `vfx.status` gives `Culled`; `particle.instance.inspect` gives
`why` `culled`. Per entity, `request_value(requests, e, "cull_distance", f32(80))` overrides it.
