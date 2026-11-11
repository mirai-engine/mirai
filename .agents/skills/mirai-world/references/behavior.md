# Plugin `behavior`

The decision services of a game over the world (`plugins/behavior`, `Runtime` and `Editor`;
depends on `physics` and `navigation`): minds by name, perception, smart objects, place queries,
influence maps and the `behavior.*` API. How an agent decides (proposals, actions, steps, commit,
reservations) belongs to
[std/ai](../../mirai-std/references/ai.md#decisions-minds-mindodin).

## Minds

- A mind is an enum of actions, an array with the procedure of each one
  (`[Enum]proc(^ai.Act(Enum)) -> ai.Status`) and a `think` that proposes them. The game runs
  those of its agents in a loop function of its own, `server`, with `minds_tick(minds, agents,
  "name", &ACTS, think, &ctx, &w, time, problems)`: it registers the mind by name the first time
  and checks it, and runs each `Mind_Agent` of that name. A repeated tick (`Time.resimulating`)
  does not decide.
- Registering (`mind_register`) rejects an empty or long name, an enum action without a
  procedure, a null `think` and a full registry, with the `behavior.mind` problem and how to fix
  it (`mind_problem_text`). `minds_unknown` reports, once per tick, the agents of a name that
  nobody runs. `Minds` (application storage, shared) stores the action names as bytes, for the
  editor, which does not know the game's enum.
- `Mind_Agent` carries the name and the `ai.Mind` of the agent, which is copied with the world. It
  is shared: each library that runs minds writes those of its agents.
- Before each tick, `w.entity` is the agent and `ctx.holder` too, owner of what it reserves.
  `Act_World` is the start of the actions' context (the game puts `Mind_Tick`, which holds it and
  what minds read, first with `using`, from the `Mind_World` params of its loop function):
  `move_act`, `follow_act`, `path_status` and `agent_path` request paths from `navigation` and
  read `Nav_Path`.
- What those actions request goes on when the agent's section unloads
  ([the far field](navigation.md#the-far-field)): `minds_tick` also runs the agents with
  `Nav_Far`, on the tick after each far step (`nav.nav_far_decide`), with `Act_World.far`, and
  what they reserve lasts until their next decision (`ctx.lease`). Their movement actions read
  their disabled `Nav_Path`; the rest of the agent is disabled and the game actions that read it
  look at `far`. One asleep in a section that sleeps does not decide.
- **Over the network**: the minds decide only on the server and the clients do not predict their
  actions. What they see is `Mind_Presentation`, replicated, which `minds_tick` writes when it
  changes if the table is in `Act_World.presentations`: the action and step they run, and what
  their actions request with `present_look` and `present_animation`. An agent without it receives
  it before its first tick; it travels if it has it when it is first replicated, so its prefab
  carries it with the `Mind_Agent`.

## Enemies with minds

Recipes over the [demo arenas](../../mirai-gameplay/references/demo.md#ai-arenas), each of
which writes them (`demo/game/ai_arena.odin`). What the agent knows lives in its components and in
what it perceives; `think` only reads and proposes, and the actions write.

- **Patrol, chase and attack** (zombie, guard): `Patrol` or `Wander` always with a low score,
  `Chase` with a higher one if it remembers someone (`ai.memory_best` of its `Perception`) and
  `Attack` with the highest if it is close. Walking is `move_act`; following, `follow_act`;
  attacking, `ai.after`. The patrol stores its point in a component and moves to the next one on
  arrival.
- **Hordes with tokens:** the attack takes a token of the target on entering (`ai.token_take(a,
  target, N)`) and `think` proposes it only if there is room (`ai.reserve_free`); the others
  propose surrounding it (`follow_act` at a greater distance) until one is released. The token is
  released by itself on exit.
- **Phased bosses with combos:** the phase is data (the health) that changes what is proposed;
  each attack does `ai.commit` on entering so that it finishes; the next phase's combo is an
  action that chooses its list on entering and runs it with `ai.steps`; stunning is a field of
  the boss component that combat raises and the stunned action lowers, with a score that beats
  everything except dying.
- **Tactical bots:** shooting with a token per target; taking cover with a place query of layout
  `Offers` and cover use, scored by not being visible from the enemy, the path and little enemy
  influence; reloading; going for ammo or health with `offer_act`; operating a turret and
  sounding an alarm (a noise that its side hears). Going for something does `commit` so as not to
  leave it half done.
- **Use of the scenery:** each use is an offer of a [smart object](#smart-objects); a door or a
  fence is an offer on its `Nav_Link`, which the agent crosses with `cross_act`, one at a time.
- No state machines, trees or planners are written
  ([equivalences](../../mirai-std/references/ai.md#instead-of-fsm-trees-htn-and-goap)).

## Smart objects

- `Smart_Object` publishes up to `SMART_OFFERS` offers: the use (`Smart_Use`, ids that the game
  declares as `USE_*`), where the one who uses it stands (in the object's frame), how many at a
  time, how many times, the cooldown after each use, the teams that can take it and the abilities
  (`Nav_Agent.abilities`) that it requires.
- An offer is open to a user (`smart_offer`) if it was not spent, is not in cooldown, is of its
  team and its abilities, and he holds it or there is room. They are found among what the agent
  perceives (`smart_offer` of the subject), near a point (`smart_nearest`, which looks at each
  object) or with a place query of layout `Offers`, scored like the others.
- The action that uses it reserves it for its whole life (`smart_claim`, in `Claims` with the
  attack tokens) and the mind releases it in its `Exit`. `offer_act` does the whole trip: it takes
  the closest, reserves it, walks and waits; whoever spends it says so with `smart_used`, and
  `smart_update` (`fixed`, `react`, `server`), sole writer of `Smart_State`, counts the use and
  starts the cooldown.
- `Claims` belongs to the world and is written by the functions that run minds
  (`ctx.reservations`).
- A link that the game crosses (a kind of its own or one of `Nav_Agent.manual`) with an offer on
  its entity: the agent waits at its start in `Crossing`; `cross_act` reserves the offer, waits
  its turn, puts it on the other side (`core.place`) and notifies navigation, and finishes when
  navigation takes it from there.

## Influence maps

- `influence_update` (`fixed`, `input`, `server`, after perception) maintains `Influence` over
  `ai.Influence_Grid`, with what `Behavior_Settings` says: the cell size (0 turns the maps off),
  the cells per side and the center. A world with nobody to stamp the maps or to read them (no
  `Perceivable`, `Perceiver`, `Mind_Agent` or querier of places) has none: the step returns before
  making them and frees the ones it had.
- One layer for each of the first `INFLUENCE_TEAMS` teams: each pass stamps its `Perceivable`s
  and the influence spreads `influence_falloff` less per meter. `influence_cells` cells are
  processed per tick.
- Cover is measured with physics rays, `influence_rays` per tick: the ground of each cell from
  above and eight directions at the height of a body; first around each `Perceivable`, in turns,
  and then over the whole map.
- `influence_at(maps, point, teams)` is the threat (the teams the agent fears) or the allies
  (its own); `cover_at` says how covered a point is from another. Place queries measure them with
  `Influence` and `Cover`.

## Perception

- `Perceiver`: range and half angle of sight, eye height, hearing (meters per volume) and
  forgetting time, and the teams (`Team`, named id) that it notices. `Perceivable`: its team and
  the height of the point that is looked at.
- `perception_update` (`fixed`, `input`, `server`) adds `Perception` to each `Perceiver` and is
  its sole writer. Sight sees what is in its cone, around the perceiver's -Z (its front), if a
  physics ray from the eyes does not hit something else first; the rays of a tick
  (`Behavior_Settings.rays`) are shared among the
  perceivers in turns. Hearing takes the noises of `Noises` (`noise`) within its range by volume.
  Memory lowers confidence until forgetting, only on the perceiver's turn: what it could not look
  at it does not forget before looking at it again. A destroyed subject is forgotten at once.
- A far perceiver (`nav.Nav_Far`) perceives when its mind decides: what is in its cone and range,
  enabled or far as well, without rays (the collision there is not loaded), and the noises of
  that tick.
- `Perception_Events` reports what was noticed and what was forgotten in the tick.

## Places

- `place_query` asks for places for an agent: candidates around it, around another entity or
  around a point (in rings, in a grid or the points of its navmesh joined to that center,
  `ai.places_mesh`), entities (those of the request, or the `Perceivable`s of some teams near the
  center) or the open offers of a use of the smart objects, brought to its navmesh, measured by
  its tests (distance, angle, visibility from someone with a ray, path length over what the agent
  walks and crosses, influence of some teams and cover) and scored with utility; the best ones
  come back in its `Place_Result`, with the request number, the entity of each one that came from
  one and the offer. The path length of all the candidates comes from a single search from the
  one measuring (`ai.nav_costs`), with the filter with which navigation moves the agent
  (`nav.agent_filter`).
- A query whose center or one of whose tests measures from an entity that no longer exists finds
  no places (`Empty`), and that of one who was destroyed while waiting is not answered. Of
  several queries of an agent that wait, only the last is answered.
- `places_run` (`fixed`, `react`, `server`) resolves in arrival order `Behavior_Settings.queries`
  per tick and is the sole writer of `Place_Result`.

## API

- `behavior.minds` (names, actions and agents of each one), `behavior.inspect` (the action and
  step they run, their stage and since when, the commit, the best proposals of the last decision
  with their scores, the latest exits with the cause and what interrupted them, and what it has
  reserved), `behavior.perception`, `behavior.offers` (the offers of a smart object, their uses
  and who holds them), `behavior.influence` (the influence of each team and the cover at a point)
  and `behavior.query` (runs a query at once).
- There is no method that sends events: an event is a field of a game component, written like any
  other.
- The entities that the game creates at runtime need a `core.Id` for the API to name them.

## Verification

- `mirai test plugins/behavior/runtime`: registration and checking by name, agent tick without
  allocating, the presentation and that it does not decide when resimulating, far agents and their
  lease, movement actions, sight by cone and team, noise, forgetting, a remembered subject that is
  destroyed, ray turns, places by budget, from the navmesh, from entities and from offers, a place
  target that is destroyed, the offers by team, ability, capacity, uses and cooldown, and the
  influence maps without allocating.
  `mirai test plugins/multiplayer/runtime
  a_mind_decides_on_the_server_and_the_client_sees_its_presentation`: a mind in a session, its
  presentation on the client and the snapshot of the server world.
- In the demo, the [AI arenas](../../mirai-gameplay/references/demo.md#ai-arenas) in Play, with
  `behavior.minds`, `behavior.inspect`, `behavior.offers`, `behavior.influence`, `nav.agent` and
  `engine.diagnostics`.
