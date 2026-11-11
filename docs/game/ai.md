---
name: ai
description: Enemies and NPCs in a Mirai game - minds, think and actions, scores, perception
  (sight, hearing, memory), navigation and nav agents, smart objects, patrol, chase, attack,
  tokens, bosses, cover. Use for zombies, guards, bots, hordes, drones; there are no FSMs or trees.
---

# Game AI

An agent decides with a **mind**: an enum of actions, one procedure per action and a `think`
that proposes actions with scores; the highest wins. No state machines, trees or planners.
Plugin `behavior` (brings `navigation`, `physics`) in `project.mirai`; import
`plugins:behavior/runtime`, `plugins:navigation/runtime` and `mirai:std/ai`.

## Map

- A mind: its `think` and its actions, which the engine runs: [mind.md](ai/mind.md).
- Smart objects (ammo, cover, turrets), fences the game crosses, place queries:
  [smart-objects.md](ai/smart-objects.md).
- Animation an agent asks for: [animation](animation.md); over the network:
  [networking](networking.md).

## What an enemy is

Components on one entity: `core.Transform`, a physics `Character` with a capsule collider and a
`Walk` (or `Fly`, `Swim`), `nav.Nav_Agent`, `behavior.Perceiver`, `behavior.Perceivable` (its
team), `behavior.Mind_Agent{mind=behavior.mind_name("zombie")}` and an `anim.Animation` to be seen.
The agent's navigation class is chosen from its capsule; with none that fits, the problem
`navigation.agent_class` says what size is missing.

- The navmesh builds itself from the world's static collision (a `Nav_Bounds` limits it). A mover
  that blocks ways is a `Nav_Obstacle`, a costlier or forbidden zone a `Nav_Area`: each a `Box`
  `Volume` on its entity ([regions](world/regions.md)). Jumps, ladders, doors: `Nav_Link`s.
- Perception: `Perceiver.notices` is a `Teams` mask; the subject has a `Perceivable` with a team
  and a collider, so the sight ray reaches it. Sight is a cone along the body's -Z.

## Recipes

- **Decide.** `think` reads and proposes: `ai.propose(t, .Chase, 0.5)`. A score of 0 or less does
  not propose. The running action wins over a rival unless the rival scores more than it plus
  `keep` (or its `ai.commit`). Patrol: low score always on; chase: higher if it remembers someone
  (`ai.memory_best(&perception.memory, here)`); attack: highest if close.
- **Act.** Each action procedure gets `Enter`, `Update`, `Exit` in `a.phase`. Walk with
  `behavior.move_act(a, goal)`, chase with `behavior.chase_act(a, target, distance)` (it follows a
  new target when it changes), wait with `ai.after(a, seconds)`,
  sequence with `ai.next_stage(a)` and `ai.stage(a)`, or `ai.steps(a, .A, .B)` for a combo.
  `a.memory` is zeroed on `Enter`. Return `.Running`, `.Success` or `.Failure`.
- **Events** (damage, stun): a field of your component, written by whoever causes it; `think`
  proposes the reaction above the rest and the action clears the field on `Enter`.
- **Boss phases:** health is data that changes what `think` proposes; an attack calls
  `ai.commit(a, score)` on `Enter` so it finishes; stun and death propose above everything.
- **Cooldowns:** in `think`, `ai.mind_ready(t.mind, .Slam, t.tick, t.dt, 5)`.
- **Hordes:** the attack takes `ai.token_take(a, u64(target), N)` and `think` proposes it only if
  `ai.reserve_free(t, target, N)`; the rest circle. Tokens release on `Exit`.
- **Hearing:** `behavior.noise(noises, position, loudness, maker)`; a `Perceiver` hears
  within `loudness` times its `hearing` meters, walls included; `maker` is whom it reveals.
  Both senses feed `Perception.memory`.
- **Use the world:** a smart object offers a use; `think` proposes going if one is open and
  the action does the trip ([smart-objects.md](ai/smart-objects.md)). A need the agent
  satisfies with an object (ammo, health) is this.
- **Move requests:** `nav.nav_move_to`, `nav_follow`, `nav_stop`, `nav_look_at`, `nav_look_along`
  on `Nav_Requests`. `Nav_Path.state` is `Idle`, `Waiting`, `Moving`, `Crossing`, `Arrived` or
  `Failed`; `partial`: it got as near as the mesh goes.
- **Show it:** an action that takes `requests:^anim.Animation_Requests` calls
  `anim.play(requests,behavior.agent(a),"Bite")` and `anim.look`. Minds run on the server, and every
  client plays what the server played, as far into it as the server is.

## Pitfalls that fail silently

- A `Mind_Agent` name that no `@(mind)` declares does nothing; `engine.diagnostics` lists the
  problem `behavior.mind`. A missing action, a wrong signature or a name too long fail the build
  with what to write.
- `Exit` must release what `Enter` requested. `move_act` and `chase_act` stop the agent on abort;
  an action that calls `nav.nav_move_to` itself must `nav_stop` when `a.cause == .Aborted`.
- `think` only reads and proposes; state changes go in the actions.
- `behavior.PERCEIVER_DEFAULT` notices every team, its own included; set `notices`.
- Agents that appear while playing: [at spawn points](core/prefabs.md#at-spawn-points).
- The navmesh builds in the background: an early `Nav_Path` is `Waiting`. `Failed`: see
  `engine.diagnostics` (`navigation.off_mesh`: the agent must start on walkable ground).
- To see why an agent chose, in Play: `behavior.inspect`, `behavior.perception`, `nav.agent`.
