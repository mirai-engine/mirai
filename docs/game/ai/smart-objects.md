# Smart objects, fences and place queries

Every mind reads the smart objects already: the helpers below take only the `think` or the action
of [a mind](mind.md). What else an action uses it receives as a parameter:
`uses:^behavior.Smart_Uses`, `places:^behavior.Place_Requests`,
`results:^core.Table(behavior.Place_Result,.Read)`, `links:^core.Table(nav.Nav_Link,.Read)`,
`placer:core.Placer` to move the agent.

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
claim it, walk, wait) with `offer_act` and applies the effect. It walks after an object that
moves, and fails if the offer is gone or closed before it is used:

```odin
user := behavior.Smart_User{entity=behavior.agent(t), team=TEAM_ENEMY}
if _, ok := behavior.smart_nearest(t, USE_AMMO, here, 60, user); ok {
    ai.propose(t, .Get_Ammo, 0.85)
}

@(act="Get_Ammo")
get_ammo :: proc(a:^ai.Act(Act), uses:^behavior.Smart_Uses) -> ai.Status {
    user := behavior.Smart_User{entity=behavior.agent(a), team=TEAM_ENEMY}
    status, found := behavior.offer_act(a, USE_AMMO, user, 60, 1) // radius, wait s
    if a.phase == .Enter {ai.commit(a, 0.8)} // a trip is not left half done
    if a.phase == .Exit || status != .Success {return status}
    // ...refill the agent's own component here...
    behavior.smart_used(uses, found) // counts the use and starts the cooldown
    return .Success
}
```

## A fence or door the game crosses

A `nav.Nav_Link` whose kind the game declares (`LINK_VAULT :: nav.Nav_Link_Kind(7)`; the agent
lists it in `Nav_Agent.manual`) plus a `Smart_Object` offer on the same entity. When the agent
reaches it, its `Nav_Path` is `Crossing` with `manual`: propose the crossing above everything else.

```odin
if p, ok := behavior.agent_path(t); ok && p.state == .Crossing && p.manual && p.kind == LINK_VAULT {
    ai.propose(t, .Vault, 1)
}
@(act="Vault")
vault :: proc(a:^ai.Act(Act),links:^core.Table(nav.Nav_Link,.Read),placer:core.Placer)
              -> ai.Status {
    if ai.entering(a) {ai.commit(a, 1)} // one agent at a time
    user := behavior.Smart_User{entity=behavior.agent(a), team=TEAM_ENEMY}
    return behavior.cross_act(a, links, placer, USE_VAULT, user, 0.6)
}
```

## Choosing a place (cover, flank)

A query is asked on `Enter`; the answer arrives in the agent's `Place_Result` a tick or more
later. Candidate layouts, tests and responses: the params of `behavior.query`.

```odin
case .Enter:
    q := behavior.Place_Query{querier=behavior.agent(a), center=.Querier,
        layout=.Offers, use=USE_COVER, outer=14, keep=1}
    falling := ai.Response{kind=.Linear, slope=-1, shift_y=1}
    q.tests[0] = {measure=.Visible, from=.Target, target=enemy, min=0, max=1, response=falling}
    q.tests[1] = {measure=.Path, from=.Querier, min=0, max=30, response=falling}
    q.test_count = 2
    a.memory[0] = u64(behavior.place_query(places, q)) // the number the result answers with
    return .Running
case .Update:
    r, ok := core.get(results, behavior.agent(a))
    if !ok || r.request != u32(a.memory[0]) || r.status == .Waiting {return .Running}
    if r.status != .Found {return .Failure}
    // r.points[0] is the best place; r.entities[0] and r.offers[0] name the object and its offer
```

To use an offer that a query found, build a `behavior.Smart_Found` (`object`, `offer`, `at`,
`users`) and claim it with `behavior.smart_claim(a, found)` before walking to `at`.
