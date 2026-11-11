package behavior

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"

// Smart objects: what the place offers to the agents that use it. An entity
// with a Smart_Object publishes up to SMART_OFFERS offers: a use (the game's
// id: ammo, health, cover, a turret, an alarm, a fence to vault), where its
// user stands, who may take it, how many at once, how many times and how
// often, which way its user faces there and where it comes from. An agent
// finds them by the place queries (layout Offers), near a point
// (smart_nearest) or among what it perceives (smart_offer of a subject), and
// its think adds what it found to its proposals. The action that goes for it
// claims the offer for its whole life (smart_claim, an ai.claim kept in
// Claims) and the mind releases it at its Exit; a claim of a higher priority
// takes it from one that does not use it yet. One that uses it up says so
// (smart_used), and behavior, the only writer of Smart_State, counts the use
// and starts its cooldown. An offer on a Nav_Link (a door, a fence) is what an
// agent claims to cross it, one at a time (cross_act).

SMART_OFFERS :: 4
SMART_MOVED :: f32(0.5) // m the place of an offer moves before its user, walking to it, heads for the new one

// The use of an offer: the game declares its ids as constants (USE_AMMO :: behavior.Smart_Use(1)).
@(names="USE_")
Smart_Use :: distinct u8
USE_NONE :: Smart_Use(0)

Smart_Offer :: struct {
    use:Smart_Use,                         // USE_NONE: no offer
    at:[3]f32 `mirai:"unit=m"`,            // where its user stands, in the frame of the object
    yaw:f32 `mirai:"angle"`,               // which way its user faces there, from the front of the object
    enter:[3]f32 `mirai:"unit=m"`,         // where its user comes to `at` from, from `at` in the frame of the object; zero: straight
    users:u8 `mirai:"max=4"`,              // at once; 0 counts as 1
    uses:i32 `mirai:"min=0"`,              // before it is spent; 0: for ever
    cooldown:f32 `mirai:"min=0,unit=s"`,   // after each use before it is offered again
    teams:Teams,                           // whose Perceivables may take it; none: anybody
    abilities:nav.Nav_Abilities,           // its user needs them all (Nav_Agent.abilities)
}

@(component,description="Offers uses to the agents: ammo to pick, health, cover, a turret to man, an alarm, a fence to vault. Each offer says where its user stands, who may take it, how many at once, how many times and how often.")
Smart_Object :: struct {
    offers:[SMART_OFFERS]Smart_Offer,
}

// What is left of the offers of a smart object. Behavior adds it to every
// Smart_Object and is its only writer.
@(component,derived,description="How many times each offer of the smart object was used and when it is offered again.")
Smart_State :: struct {
    used:[SMART_OFFERS]i32 `mirai:"readonly,transient"`,
    ready:[SMART_OFFERS]u64 `mirai:"readonly,transient"`, // the tick it is offered again at
}

// Who holds what: the attack tokens and the claims of the offers of the
// agents of a world. Written by the steps of the minds (ctx.reservations).
@(storage,shared)
Claims :: struct {
    using reservations:ai.Reservations,
}

Smart_Used :: struct {object:core.Entity,offer:u8}

@(storage,queue)
Smart_Uses :: struct {
    using queue:core.Queue(Smart_Used),
    shapes:[2]core.Shape, // of the objects and the states when the objects last got their Smart_State
}

// The offer was used: it counts once and starts its cooldown at the next step.
smart_used :: proc(uses:^Smart_Uses,found:Smart_Found) {
    if found.object!=core.NONE {core.push(&uses.queue,Smart_Used{found.object,u8(found.offer)})}
}

@(step="fixed",stage="react",server)
smart_update :: proc(objects:^core.Table(Smart_Object,.Read),states:^core.Table(Smart_State),uses:^Smart_Uses,time:core.Time) {
    if core.reshaped(objects,&uses.shapes[0]) | core.reshaped(states,&uses.shapes[1]) {
        for row in 0..<core.count(objects) {
            e:=core.entity_at(objects,row)
            if !core.has(states,e) {core.add(states,e,Smart_State{})}
        }
    }
    for used in core.take(&uses.queue) {
        object,found:=core.get(objects,used.object)
        state:=core.staged(states,used.object)
        if !found || state==nil || int(used.offer)>=SMART_OFFERS {continue}
        state.used[used.offer]+=1
        state.ready[used.offer]=core.deadline(time,object.offers[used.offer].cooldown)
    }
}

// What the queries of offers read: a step receives it, and a mind reads it
// from its Mind_World.
@(params)
Smart_View :: struct {
    objects:^core.Table(Smart_Object,.Read),
    states:^core.Table(Smart_State,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    claims:core.Ref(Claims),
    time:core.Time,
}

// An offer an agent can take: the object, which offer, where to stand, how
// many may hold it, which way to face there and where to come to it from.
Smart_Found :: struct {
    object:core.Entity,
    offer:int,
    at:[3]f32,
    users:int,
    yaw:f32,      // in the world
    enter:[3]f32, // in the world: at when the offer has no way in
}

// Who looks for offers: the holder of the claims, what the offers ask of it
// and the priority of its claims (the game declares its levels as constants).
Smart_User :: struct {
    entity:core.Entity,
    team:Team,
    abilities:nav.Nav_Abilities,
    priority:u8,
}

// The first offer of `use` on `object` that `user` can take now, for the
// think procedure or the action `a` of a mind: not spent, not cooling down,
// of its team and abilities, and with room for it, or already its own.
smart_offer :: proc(a:^$T,object:core.Entity,use:Smart_Use,user:Smart_User) -> (found:Smart_Found,ok:bool) {
    return offer_open(smart_view(a),object,use,user)
}

@(private)
smart_view :: proc(a:^$T) -> Smart_View {
    w:=world_of(a)
    return {objects=w.objects,states=w.states,worlds=w.worlds,claims=core.ref(w.claims),time=w.time}
}

@(private)
offer_open :: proc(v:Smart_View,object:core.Entity,use:Smart_Use,user:Smart_User) -> (found:Smart_Found,ok:bool) {
    o,has:=core.get(v.objects,object)
    if !has || use==USE_NONE {return}
    state,_:=core.get(v.states,object)
    pose,placed:=core.get(v.worlds,object)
    if !placed {return}
    for offer,i in o.offers {
        if offer.use!=use || !smart_open(v,object,i,offer,state,user) {continue}
        return offer_found(object,i,offer,pose.transform),true
    }
    return
}

// Where the user of an offer of an object posed so stands, faces and comes from.
@(private)
offer_found :: proc(object:core.Entity,i:int,offer:Smart_Offer,pose:mm.Transform) -> Smart_Found {
    s,c:=math.sincos(offer.yaw)
    facing:=mm.quat_rotate(pose.rotation,{-s,0,-c})
    yaw:=offer.yaw
    if linalg.length(facing.xz)>1e-4 {yaw=mm.yaw_of_direction(facing)}
    return {
        object=object,offer=i,users=max(int(offer.users),1),yaw=yaw,
        at=mm.transform_point(pose,offer.at),enter=mm.transform_point(pose,mm.Vec3(offer.at)+mm.Vec3(offer.enter)),
    }
}

// The offer of `use` nearest to `from` within `radius` that `user` can take
// now: every Smart_Object is looked at, so for many of them a game uses the
// place queries.
smart_nearest :: proc(a:^$T,use:Smart_Use,from:[3]f32,radius:f32,user:Smart_User) -> (found:Smart_Found,ok:bool) {
    v:=smart_view(a)
    best:=radius
    for row in 0..<core.count(v.objects) {
        object:=core.entity_at(v.objects,row)
        candidate,open:=offer_open(v,object,use,user)
        if !open {continue}
        d:=linalg.length(mm.Vec3(candidate.at)-mm.Vec3(from))
        if !(d<=best) {continue}
        best,found,ok=d,candidate,true
    }
    return
}

// Claims the offer for the action (or step) that asks, until it exits, at the
// priority of its user: false when as many others as it takes hold it and
// none of a lower priority has started to use it (ai.claim_use).
smart_claim :: proc(a:^ai.Act($A),found:Smart_Found,user:Smart_User) -> bool {
    if found.object==core.NONE || found.offer<0 || found.offer>=SMART_OFFERS {return false}
    return ai.claim(a,u64(found.object),u16(found.offer+1),found.users,user.priority)
}

// Whether the offer is open to the user: ready for it, and held by it or with
// room for it at its priority.
@(private)
smart_open :: proc(v:Smart_View,object:core.Entity,i:int,offer:Smart_Offer,state:Smart_State,user:Smart_User) -> bool {
    if !offer_ready(v,i,offer,state,user) {return false}
    if v.claims.ptr==nil || user.entity==core.NONE {return true}
    return ai.reserve_open(&v.claims.ptr.reservations,{u64(object),u16(i+1)},u64(user.entity),max(int(offer.users),1),v.time.tick,user.priority)
}

// Not spent, not cooling down, and of the team and the abilities of the user.
@(private)
offer_ready :: proc(v:Smart_View,i:int,offer:Smart_Offer,state:Smart_State,user:Smart_User) -> bool {
    if offer.use==USE_NONE {return false}
    if offer.uses>0 && state.used[i]>=offer.uses {return false}
    if !core.due(v.time,state.ready[i]) {return false}
    if offer.teams!=0 && u32(offer.teams)&(1<<u32(user.team))==0 {return false}
    return u32(offer.abilities)&~u32(user.abilities)==0
}

// Crosses the link the agent waits at (Nav_Path.state Crossing, of a kind the
// game crosses), claiming the offer of `use` on the entity of the link: it
// waits while others hold it (stage 0), takes `seconds` (1), lands at the
// other end and waits for navigation to take it from there (2). Success once
// across; Failure when it is not at such a link.
cross_act :: proc(a:^ai.Act($A),links:^core.Table(nav.Nav_Link,$B),placer:core.Placer,use:Smart_Use,user:Smart_User,seconds:f64) -> ai.Status {
    if a.phase==.Exit {return .Success}
    w,e,v:=world_of(a),agent(a),smart_view(a)
    p,ok:=agent_path(a)
    crossing:=ok && p.state==.Crossing && p.manual
    if ai.stage(a)==2 {return .Running if crossing else .Success}
    if !crossing {return .Failure}
    if ai.stage(a)==0 {
        found,open:=smart_at_link(v,links,p.from,use,user)
        if !open || !smart_claim(a,found,user) {return .Running}
        ai.claim_use(a)
        ai.next_stage(a)
    }
    if ai.stage_elapsed(a)<seconds {return .Running}
    rotation:=mm.Quat(1)
    if pose,placed:=core.get(v.worlds,e);placed {rotation=pose.rotation}
    core.place(placer,e,p.to,rotation)
    nav.nav_crossing_done(w.requests,e)
    return ai.next_stage(a)
}

// The offer of `use` on the link with an end at `from`.
@(private)
smart_at_link :: proc(v:Smart_View,links:^core.Table(nav.Nav_Link,$A),from:[3]f32,use:Smart_Use,user:Smart_User) -> (found:Smart_Found,ok:bool) {
    for row in 0..<core.count(v.objects) {
        object:=core.entity_at(v.objects,row)
        link,linked:=core.get(links,object)
        pose,placed:=core.get(v.worlds,object)
        if !linked || !placed {continue}
        end:=mm.transform_point(pose.transform,link.end)
        if link.target!=core.NONE {if other,there:=core.get(v.worlds,link.target);there {end=other.position}}
        if min(linalg.length(pose.position-mm.Vec3(from)),linalg.length(end-mm.Vec3(from)))>1.5 {continue}
        if found,ok=offer_open(v,object,use,user);ok {return}
    }
    return
}

// Goes for an offer of `use` and uses it: on Enter it takes the nearest one
// `user` can take within `radius` of the agent and claims it, or fails; it
// walks to where its user comes from and then to where it stands (stage 0),
// after it if the object moves, uses it facing its way for `seconds` (stage
// 1), and succeeds with the offer, whose effect the caller applies, with
// smart_used when it spends it. It fails when the offer is gone or closed to
// it (the object destroyed, disabled or spent) or a claim of a higher priority
// took it before it started to use it. It keeps the offer in the first three
// words of its memory.
offer_act :: proc(a:^ai.Act($A),use:Smart_Use,user:Smart_User,radius:f32,seconds:f64) -> (status:ai.Status,found:Smart_Found) {
    w,e,v:=world_of(a),agent(a),smart_view(a)
    switch a.phase {
    case .Enter:
        pose,placed:=core.get(v.worlds,e)
        ok:bool
        if placed {found,ok=smart_nearest(a,use,pose.position,radius,user)}
        if !ok || !smart_claim(a,found,user) {return .Failure,{}}
        a.memory[0],a.memory[1],a.memory[2]=u64(found.object),u64(found.offer),0
        nav.nav_move_to(w.requests,e,found.enter)
        return .Running,found
    case .Update:
        found=offer_held(v,a,user)
        if found.offer<0 {return .Failure,{}}
        if ai.stage(a)==0 {
            goal:=found.enter if a.memory[2]==0 else found.at
            if p,ok:=agent_path(a);ok && linalg.length(mm.Vec3(goal)-mm.Vec3(p.goal))>SMART_MOVED {
                nav.nav_move_to(w.requests,e,goal)
                return .Running,found
            }
            #partial switch path_status(a) {
            case .Running: return .Running,found
            case .Failure: return .Failure,found
            }
            if a.memory[2]==0 && found.enter!=found.at {
                a.memory[2]=1
                nav.nav_move_to(w.requests,e,found.at)
                return .Running,found
            }
            ai.claim_use(a)
            s,c:=math.sincos(found.yaw)
            nav.nav_look_at(w.requests,e,mm.Vec3(found.at)+{-s,0,-c})
            ai.next_stage(a)
        }
        if ai.stage_elapsed(a)<seconds {return .Running,found}
        return .Success,found
    case .Exit:
        if a.cause==.Aborted && ai.stage(a)==0 {nav.nav_stop(w.requests,e)}
        if ai.stage(a)==1 {nav.nav_look_along(w.requests,e)}
    }
    return .Success,{}
}

// The offer an offer_act holds, while it still holds it and the offer is
// ready for its user; offer -1 when not.
@(private)
offer_held :: proc(v:Smart_View,a:^ai.Act($A),user:Smart_User) -> (found:Smart_Found) {
    object:=core.Entity(a.memory[0])
    offer:=int(a.memory[1])
    o,has:=core.get(v.objects,object)
    pose,placed:=core.get(v.worlds,object)
    if !has || !placed || offer<0 || offer>=SMART_OFFERS {return {offer=-1}}
    state,_:=core.get(v.states,object)
    if !offer_ready(v,offer,o.offers[offer],state,user) {return {offer=-1}}
    if !ai.claim_held(a) {return {offer=-1}}
    return offer_found(object,offer,o.offers[offer],pose.transform)
}
