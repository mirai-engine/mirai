# What particles tell the game

Use it for a sound, a decal or a follow-up effect where a particle dies or hits something.

An effect whose `report` field is `Death` or `Collision` makes the GPU report those particles. The
reports of a frame arrive some frames later, once each, in `vfx.Particle_Reports`.

```odin
@(step="late")
sparks_react :: proc(reports:core.Ref(vfx.Particle_Reports), spawner:scene.Spawner) {
    for r in reports.reports {
        if r.kind != .Collision {continue}
        // r.entity (the emitter), r.position, r.velocity, r.normal of what it hit
        scene.spawn(spawner, "arena/Scorch.scene", {position=r.position}, transient=true)
    }
}
```

- Set `report` on the effect (`particle.set`, or `effect.Particle_Info.report` in a content tool).
- Sounds from a report: [audio](../audio.md).

## Pitfalls

- Reports are presentation: not deterministic, not rolled back, never a game decision (damage,
  score). A `fixed` function that receives `Particle_Reports` fails to generate.
- A frame keeps a limited number of reports; the rest are counted in `lost`.
- A `Collision` report is a bounce: a particle that lands reports each bounce once, and nothing
  while it rests or slides on the surface.
