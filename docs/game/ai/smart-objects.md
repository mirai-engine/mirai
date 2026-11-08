# Smart objects, fences and place queries

`behavior.Mind_Tick` (the `Tick` of [mind.md](mind.md) begins with it) holds `smart`, `uses`,
`places`, `results`, `links` and `noises`, filled each tick from `behavior.Mind_World`. For the
actions that move an entity add `placer:core.Placer` to `Tick` and to the loop function.

## An object that offers a use

```odin
USE_AMMO :: behavior.Smart_Use(1) // the game's ids; 0 is none
ours := behavior.Teams(1 << u32(TEAM_ENEMY))
core.commands_add(c, crate, behavior.Smart_Object{offers = {
    0 = {use=USE_AMMO, at={0,0,1.1}, users=1, uses=4, cooldown=8, teams=ours},
}})
```

`at` is where the user stands, in the object's frame; `uses` 0 is unlimited; `teams` none is open
to anyone. `Smart_Object` is also a component to add to an entity in a scene.

## Going to use it

`think` proposes the trip only if one is open; the action does the whole trip (take the nearest,
claim it, walk, wait) with `offer_act` and applies the effect:

```odin
user := behavior.Smart_User{entity=w.entity, team=TEAM_ENEMY}
if _, ok := behavior.smart_nearest(&w.smart, USE_AMMO, here, 60, user); ok {
    ai.propose(t, .Get_Ammo, 0.85)
}

get_ammo :: proc(a:^ai.Act(Act)) -> ai.Status {
    w := (^Tick)(a.user)
    user := behavior.Smart_User{entity=w.entity, team=TEAM_ENEMY}
    status, found := behavior.offer_act(w, &w.smart, a, USE_AMMO, user, 60, 1) // radius, wait s
    if a.phase == .Enter {ai.commit(a, 0.8)} // a trip is not left half done
    if a.phase == .Exit || status != .Success {return status}
    // ...refill the agent's own component here...
    behavior.smart_used(w.uses, found) // counts the use and starts the cooldown
    return .Success
}
```

## A fence or door the game crosses

A `nav.Nav_Link` whose kind the game declares (`LINK_VAULT :: nav.Nav_Link_Kind(7)`; the agent
lists it in `Nav_Agent.manual`) plus a `Smart_Object` offer on the same entity. When the agent
reaches it, its `Nav_Path` is `Crossing` with `manual`: propose the crossing above everything else.

```odin
if p, ok := behavior.agent_path(w); ok && p.state == .Crossing && p.manual && p.kind == LINK_VAULT {
    ai.propose(t, .Vault, 1)
}
vault :: proc(a:^ai.Act(Act)) -> ai.Status { // one agent at a time
    w := (^Tick)(a.user)
    if ai.entering(a) {ai.commit(a, 1)}
    user := behavior.Smart_User{entity=w.entity, team=TEAM_ENEMY}
    return behavior.cross_act(w, &w.smart, a, w.links, w.placer, USE_VAULT, user, 0.6)
}
```

## Choosing a place (cover, flank)

A query is asked on `Enter`; the answer arrives in the agent's `Place_Result` a tick or more
later. Candidate layouts, tests and responses: `engine.describe` and `behavior.query`.

```odin
case .Enter:
    q := behavior.Place_Query{querier=w.entity, center=.Querier,
        layout=.Offers, use=USE_COVER, outer=14, keep=1}
    falling := ai.Response{kind=.Linear, slope=-1, shift_y=1}
    q.tests[0] = {measure=.Visible, from=.Target, target=enemy, min=0, max=1, response=falling}
    q.tests[1] = {measure=.Path, from=.Querier, min=0, max=30, response=falling}
    q.test_count = 2
    a.memory[0] = u64(behavior.place_query(w.places, q)) // the number the result answers with
    return .Running
case .Update:
    r, ok := core.get(w.results, w.entity)
    if !ok || r.request != u32(a.memory[0]) || r.status == .Waiting {return .Running}
    if r.status != .Found {return .Failure}
    // r.points[0] is the best place; r.entities[0] and r.offers[0] name the object and its offer
```

To use an offer that a query found, build a `behavior.Smart_Found` (`object`, `offer`, `at`,
`users`) and claim it with `behavior.smart_claim(a, found)` before walking to `at`.

## Noise

`behavior.noise(w.noises, position, loudness, maker)` is heard by every `Perceiver` within
`loudness` times its `hearing` meters, walls included; `maker` is whom it reveals.
