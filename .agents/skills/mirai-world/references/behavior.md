# Plugin `behavior`

The decision services of a game over the world (`plugins/behavior`, `Runtime` and `Editor`;
depends on `physics` and `navigation`): minds by name, perception, smart objects, place queries,
influence maps and the `behavior.*` API. How an agent decides (proposals, actions, steps, commit,
reservations) belongs to
[std/ai](../../mirai-std/references/ai.md#decisions-minds-mindodin).

## Minds

- A mind is an enum of actions, a procedure per value and a `think` that proposes them. The game
  marks its `think` with `@(mind="name")` and each action with `@(act="Value ...")`: the
  generator makes a `fixed`, `server` step named after the `think` that ticks every `Mind_Agent`
  of that name with `minds_tick` ([generator](../../mirai-core/references/generator.md#minds)).
  What a procedure receives after its `ai.Think` or `ai.Act` is bound as for a step; the step
  holds each datum once, after `Mind_World`. A world that does not play and a repeated tick
  (`Time.resimulating`) do not decide.
- The generator checks a mind when it builds (every value has one action, the shapes, the name
  and how many minds fit in `Minds`); `minds_tick` registers it by name in `Minds` (application
  storage, shared), which keeps the action names as bytes for the editor, which does not know the
  game's enum. `minds_unknown` (`fixed`, `apply`, `server`) reports the agents of a name no mind
  declares with the `behavior.mind` problem.
- `Mind_Agent` carries the name and the `ai.Mind` of the agent, which is copied with the world. It
  is shared: the step of each mind writes those of its agents.
- `Mind_World` is what every mind reads (its agents, paths, smart objects, claims, time); the
  procedures of a mind reach it through `ai.Mind_Context.user`, and `ctx.holder` is the agent
  (`agent(a)`). So the helpers take only the action or the think: `move_act`, `chase_act` (follows
  its target and the new one when it changes), `patrol_act`, `path_status`, `agent_path`,
  `smart_offer`, `smart_nearest`, `offer_act`, `cross_act`. An action shows what it does with
  `anim.play` and `anim.look`, taking `^anim.Animation_Requests` as any other parameter.
- An agent thinks less often the farther it is from the
  [simulation sources](../../mirai-gameplay/references/libraries.md#sources-and-residency) (the
  bodies the seats drive, each `Streaming_Source`, never the view): once every
  `ai.cadence_period` ticks by `Behavior_Settings.think_near`, up to `think_slowest`, on the ticks
  of its own phase (`ai.cadence_due`). Only `think` is spaced: its running action runs every tick,
  and it thinks too when that action ends, so a wait or an attack lasts what it says. Without
  sources, or with `think_near` 0, every agent decides every tick.
- What those actions request goes on when the agent's section unloads
  ([the far field](navigation.md#the-far-field)): `minds_tick` also runs the agents with
  `Nav_Far`, on the tick after each far step (`nav.nav_far_decide`), and what they reserve lasts
  until their next decision (`ctx.lease`). Their movement actions read their disabled `Nav_Path`;
  the rest of the agent is disabled. One asleep in a section that sleeps does not decide.
- **Over the network**: the minds decide only on the server and the clients do not predict their
  actions. What their actions play reaches the clients through the replicated state of the
  animation
  ([network](../../mirai-animation/references/animation-actions.md#requests-and-lifecycle)).

## Enemies with minds

Recipes over the [demo arenas](../../mirai-gameplay/references/demo.md#ai-arenas), each of
which writes them (`demo/game/ai_arena.odin`). What the agent knows lives in its components and in
what it perceives; `think` only reads and proposes, and the actions write.

- **Patrol, chase and attack** (zombie, guard): `Patrol` or `Wander` always with a low score,
  `Chase` with a higher one if it remembers someone (`ai.memory_best` of its `Perception`) and
  `Attack` with the highest if it is close. Walking is `move_act`; chasing, `chase_act`;
  attacking, `ai.after`. A patrol is a `Patrol` that names the entity of a `volume.Spline`, never
  points of its own: `patrol_act` walks it while the mind patrols, and `patrols_walk` walks the
  agents with a `Patrol` and no `Mind_Agent`. Each starts at the point after the span of the curve
  nearest the agent (`volume.spline_nearest`), so one pushed off its way goes back to it; it
  walks point to point and moves on when navigation arrives or fails; it asks again when the
  path moves; a path of one point is a post. Its progress (`next`, `back`) is in the `Patrol`, so
  an interrupted back and forth keeps its direction. `Patrol` is shared: every mind step writes
  it.
- **Hordes with tokens:** the attack takes a token of the target on entering (`ai.token_take(a,
  target, N)`) and `think` proposes it only if there is room (`ai.reserve_free`); the others
  propose surrounding it (`chase_act` at a greater distance) until one is released. The token is
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
  declares as `USE_*`), where the one who uses it stands (in the object's frame), which way it
  faces there (a yaw: a seat cannot pitch or roll), where it comes from (`enter`, from `at`), how
  many at a time, how many times, the cooldown after each use, the teams that can take it and the
  abilities (`Nav_Agent.abilities`) that it requires. One slot per entity: many seats are many
  entities, never one object with many slots or several ways in for one seat.
- An offer is open to a user (`smart_offer`) if it was not spent, is not in cooldown, is of its
  team and its abilities, and he holds it, there is room, or a holder of a lower priority
  (`Smart_User.priority`) has not started to use it. They are found among what the agent
  perceives (`smart_offer` of the subject), near a point (`smart_nearest`, which looks at each
  object) or with a place query of layout `Offers` (open at the query's `priority`), scored like
  the others.
- The action that uses it reserves it for its whole life (`smart_claim`, in `Claims` with the
  attack tokens) and the mind releases it in its `Exit`. A claim of a higher priority displaces
  one not in use; one in use (`ai.claim_use`) is never displaced, and the one displaced is not
  told: its next `Update` finds it no longer holds it and fails. `offer_act` does the whole trip:
  it takes the closest, reserves it, walks to `enter` and then to `at` (after it, if it moves),
  marks it in use, faces its yaw (`nav_look_at`, released on `Exit`) and waits, and fails when the
  offer is gone, closed to it or taken before; whoever spends it says so with `smart_used`, and
  `smart_update` (`fixed`, `react`, `server`), sole writer of `Smart_State`, counts the use and
  starts the cooldown.
- `Claims` belongs to the world and is written by the steps of the minds (`ctx.reservations`);
  the place queries read it through `Smart_View`.
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

- `Perceiver`: range and half angle of sight, eye height, hearing (meters per volume),
  forgetting time, the radius within which it sees all around (`aware`) and the teams (`Team`,
  named id) that it notices, for sight and for noises alike. `Perceivable`: its team and
  the height of the point that is looked at.
- `perception_update` (`fixed`, `input`, `server`) adds `Perception` to each `Perceiver` and is
  its sole writer. Sight sees what is in its cone, around the perceiver's -Z (its front), if a
  physics ray from the eyes does not hit something else first; the rays of a tick
  (`Behavior_Settings.rays`) are shared among the perceivers in turns, and one the rays cut short
  goes first in the next tick, on from where it stopped: every subject in sight is looked at again
  within as many ticks as there are candidates per ray. What it saw last stays in sight up to
  `SIGHT_KEEP` times its range and angle, so that at the edge it is not noticed and forgotten in
  turn. Hearing takes the noises of `Noises` (`noise`) within its range by volume, or the ones
  whose `listener` it is wherever they are, if it notices their team: that of the maker's
  `Perceivable`, else the noise's own; a noise of no team reaches everyone. A noise with an `age`
  is remembered as of that many ticks ago.
  Memory lowers confidence until forgetting, only on the perceiver's turn: what it could not look
  at it does not forget before looking at it again. A destroyed subject is forgotten at once.
- Each perceiver looks only at the `Perceivable`s around it: those of the tick are put in a
  [grid](../../mirai-std/references/spatial.md#grid-uniform-grid-and-spatial-hash) over the ground
  (`Sight`, of the application) and each takes those within its range, in the order of their table,
  so the turns of the rays and what a full memory keeps do not depend on the grid.
- With nobody to look at or hear and nothing remembered, the tick looks at no perceiver. The same
  holds for the place queries without a request and for the smart objects whose tables did not
  change.
- A far perceiver (`nav.Nav_Far`) perceives when its mind decides: what is in its cone and range,
  enabled or far as well, without rays (the collision there is not loaded), and the noises of
  that tick.
- `Perception_Events` reports what was noticed and what was forgotten in the tick.

## Places

- `place_query` asks for places for an agent: candidates around it, around another entity or
  around a point (in rings, all around or in an arc centered on where the center faces, in a grid
  or the points of its navmesh joined to that center, `ai.places_mesh`), entities (those of the
  request, the `Perceivable`s of some teams near the center, or with `Remembered` what the agent's
  `Perception` memory holds, where it last perceived it, a `Perceivable` only of those teams and a
  noise with no maker too: an unseen enemy is no candidate) or
  the open offers of a use of the smart objects, brought to its navmesh, measured by its tests
  (distance, angle, visibility from someone with a ray, path length over what the agent walks and
  crosses, influence of some teams and cover) and scored with utility; the best ones come back in
  its `Place_Result`, with the request number, the entity of each one that came from one and the
  offer. The path length of all the candidates comes from a single search from the one measuring
  (`ai.nav_costs`), with the filter with which navigation moves the agent
  (`nav.agent_filter`).
- Measures run by cost: those that read numbers on every candidate, then the search over the mesh,
  then rays (`Visible`) and searches through a volume one candidate at a time, from the highest
  score the measured tests allow down. The score is a product, so a candidate a measure vetoes
  takes no more of them, and one whose bound stays below the kept ones is not measured; the places
  found are exactly those of measuring everything.
- A query whose center or one of whose tests measures from an entity that no longer exists finds
  no places (`Empty`), and that of one who was destroyed while waiting is not answered. Of
  several queries of an agent that wait, only the last is answered.
- `places_run` (`fixed`, `react`, `server`) resolves in arrival order `Behavior_Settings.queries`
  per tick and is the sole writer of `Place_Result`.

## API

- `behavior.minds` (names, actions and agents of each one), `behavior.inspect` (the action and
  step they run, their stage and since when, the commit, the best proposals of the last decision
  with their scores, the latest exits with the seconds since each, the cause and what interrupted
  them, and what it has reserved), `behavior.perception`, `behavior.offers` (the offers of a
  smart object, their uses and who holds them), `behavior.influence` (the influence of each team
  and the cover at a point) and `behavior.query` (runs a query at once).
- Why, on request and never recorded: `behavior.perception` with `subject` says why it sees that
  one or not at this tick (`sight_why`, over the same `sight_reach` its turns use: range, cone or
  `aware`, team, the entity a ray hits first, no rays); `behavior.query` with `explain` gives every
  candidate with each test's input and response, its fate and the vetoing test, the first that
  scored 0 (`place_run` fills a `Place_Explain` only when given one). What was decided at an
  earlier tick is asked after `play.seek`.
- The viewport mode `behavior.perception` draws, for the selected `Perceiver`s, the cone, the
  reach within which it keeps what it saw, `aware` and a line to each subject it remembers, as
  bright as its confidence; only while the mode is on.
- There is no method that sends events: an event is a field of a game component, written like any
  other.
- The entities that the game creates at runtime need a `core.Id` for the API to name them.

## Verification

- `mirai test plugins/behavior/runtime`: registration by name and unknown names, agent tick without
  allocating, that it does not decide when resimulating or stopped, far agents and their lease, the
  cadence of a mind by its distance to the sources, movement, chase and patrol actions, sight by
  cone and team, noise, forgetting, a remembered subject that is destroyed, ray turns, random crowds
  that remember by the grid whom they would among every perceivable, why a subject is seen or not
  (`sight_why_names_what_hides_a_subject`), a tick with nothing to do that goes through no row,
  places by budget, from the navmesh, from entities, from memory and from offers, rays only where
  they change the answer, the explanation of each candidate
  (`a_query_explains_each_candidate_and_the_test_that_vetoed_it`), a place
  target that is destroyed, the offers by team, ability, capacity, uses and cooldown, the way in
  and the facing of `offer_act` and the claim of a higher priority before use, and the
  influence maps without allocating.
  `mirai test plugins/multiplayer/runtime
  a_mind_decides_on_the_server_and_the_client_plays_what_it_plays`: a mind in a session, the
  action it plays played on the client within the delay it shows the server by, and the snapshot
  of the server world. The wiring of `@(mind)` and its
  errors: `mirai test cook/build` (`minds_test.odin`).
- In the demo, the [AI arenas](../../mirai-gameplay/references/demo.md#ai-arenas) in Play, with
  `behavior.minds`, `behavior.inspect`, `behavior.offers`, `behavior.influence`, `nav.agent` and
  `engine.diagnostics`.
