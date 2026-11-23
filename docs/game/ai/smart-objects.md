# Smart objects, fences and place queries

A fixed step binds `behavior.Smart_Offers` and combines it with a reference to `Claims` in
`Smart_View{offers=offers, claims=core.ref(claims)}`. Minds use `behavior.mind_smart_view`.
Bind `^behavior.Smart_Uses` to spend an offer.

## An object that offers a use

```odin
USE_AMMO :: behavior.Smart_Use(1) // the game's ids; 0 is none
ours := behavior.Teams(1 << u32(TEAM_ENEMY))
core.commands_add(c, crate, behavior.Smart_Object{offers = {
    0 = {use=USE_AMMO, at={0,0,1.1}, users=1, uses=4, cooldown=8, teams=ours},
}})
```

`at` is where the user stands, in the object's frame; `yaw` is which way it faces there, from the
object's front; `enter` is where it comes to `at` from, relative to `at` (zero: straight to it);
`uses` 0 is unlimited; `teams` none is open to anyone. `Smart_Object` is also a component to add
to an entity in a scene. Give each independently reservable position its own offer.

## Going to use it

`think` proposes the trip only if one is open; the action does the whole trip (take the nearest,
claim it, walk to `enter` and then to `at`, face `yaw`, wait) with `offer_act` and applies the
effect. It walks after an object that moves, and fails if the offer is gone or closed before it is
used. `Smart_User.priority` is the priority of its claims (the game declares its levels as
constants): a higher one takes an offer from a user still walking to it, whose `offer_act` then
fails; once a user is using it (`offer_act` facing it, `cross_act` crossing, or `ai.claim_use`)
nobody takes it:

```odin
user := behavior.Smart_User{entity=behavior.agent(t), team=TEAM_ENEMY}
if _, open := behavior.smart_nearest(behavior.mind_smart_view(t), USE_AMMO, here, 60, user); open {
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
reaches it, its `Nav_Path` is `Crossing` with `manual` and names the link entity. Set the
link's capacity to one for an exclusive crossing. `cross_act` waits its turn, takes the time it
says and calls `nav.nav_crossing_skip`, which puts the agent at the end of the link. For a custom
animated crossing, enable passthrough, move the character with the animation or a pose target
(the `Crossing` `nav.Nav_Event` gives the ends), and call `nav.nav_crossing_done` when it reaches
the other end.

```odin
if p, ok := behavior.agent_path(t); ok && p.state == .Crossing && p.manual && p.kind == LINK_VAULT {
    ai.propose(t, .Vault, 1)
}
@(act="Vault")
vault :: proc(a:^ai.Act(Act)) -> ai.Status {
    if ai.entering(a) {ai.commit(a, 1)}
    user := behavior.Smart_User{entity=behavior.agent(a), team=TEAM_ENEMY}
    return behavior.cross_act(a, USE_VAULT, user, 0.6)
}
```

## Choosing a place (cover, flank)

An action runs a query now with `place_pick`, binding `behavior.Place_World`: it answers within
the queries of the tick (`Behavior_Settings.queries`), or says `Waiting` when they are spent, to
ask again at the next tick. A fixed step submits a query with `place_query`, and the answer
arrives in the querier's `Place_Result`: bind `^behavior.Place_Requests` to submit and
`^core.Table(behavior.Place_Result,.Read)` to read it. Layouts and tests are also available via
`behavior.query`. Layout
`Remembered` takes what the agent remembers (the enemies of the teams asked and the noises with no
maker), where it last perceived it, so it does not flank someone it never saw; `arc` (radians)
keeps `Rings` to a span around where the center faces.
Order the tests freely. Rays and path searches run only where they can change the answer.
Set `Place_Test.sight_layers` to choose the blockers for a visibility test. For influence or
cover scores, set `Behavior_Settings.influence_enabled` in project settings.

```odin
@(act="Take_Cover")
cover :: proc(a:^ai.Act(Act), places:behavior.Place_World) -> ai.Status {
    if ai.stage(a) == 0 {
        q := behavior.Place_Query{center=.Querier, layout=.Offers, use=USE_COVER, outer=14, keep=1}
        falling := ai.Response{kind=.Linear, slope=-1, shift_y=1}
        q.tests[0] = {measure=.Visible, from=.Target, target=enemy, min=0, max=1, response=falling}
        q.tests[1] = {measure=.Path, from=.Querier, min=0, max=30, response=falling}
        q.test_count = 2
        r := behavior.place_pick(a, places, q) // the querier is the agent
        if r.status == .Waiting {return .Running}
        if r.status != .Found {return .Failure}
        // r.points[0] is the best place; r.entities[0] and r.offers[0] name its object and offer
    }
}
```

Set the query's `priority` to the querier's `Smart_User.priority`. With the answer, use
`smart_offer_at` with the returned entity and offer index to check whether it can still be taken.
Claim it with `smart_claim` and walk to the result point. Check `ai.claim_held(a)` while walking
and call `ai.claim_use(a)` when the agent starts using it.

## Perception and reservations from a step

Add `behavior.Perceiver` to an observer and `behavior.Perceivable` to subjects it can see.
Set `Perceiver.sight_layers` for the collision layers that should block sight. Read observations
through `behavior.perceived` or `behavior.perception_best`. Observations carry the senses that
detected the subject and a confidence that decays as the observation ages.

A fixed server step can bind `^behavior.Claims` and take a slot with `claim_take`.
Use `attack_token(target)` for an attack slot or `smart_key(found)` for an offer. Check with
`claim_open` or `claim_held`. Renew each tick while the holder needs its slot and release it with
`claim_release` when it is done. Call `claim_use` to protect a holder once it starts using a slot.
