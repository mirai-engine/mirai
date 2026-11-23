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
// and starts its cooldown. An offer on a Nav_Link (a door, a fence) says who
// may cross it (cross_act); how many at once is the capacity of the link.

SMART_OFFERS :: 8
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

Smart_Used :: struct {object:core.Entity,offer:u8}

@(storage,queue)
Smart_Uses :: struct {
    using queue:core.Queue(Smart_Used),
    shapes:[2]core.Shape, // of the objects and the states when the objects last got their Smart_State
}

// The offer was used: it counts once and starts its cooldown at the next step.
smart_used :: proc(uses:^Smart_Uses,found:Smart_Found) {
    if uses!=nil && smart_key(found).target!=0 {core.push(&uses.queue,Smart_Used{found.object,u8(found.offer)})}
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

@(params)
Smart_Offers :: struct {
    objects:^core.Table(Smart_Object,.Read),
    index:core.Ref(Smart_Index),
    states:^core.Table(Smart_State,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    time:core.Time,
}

Smart_View :: struct {
    using offers:Smart_Offers,
    claims:core.Ref(Claims),
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

// The first open offer of this use on the object.
smart_offer :: proc(v:Smart_View,object:core.Entity,use:Smart_Use,user:Smart_User) -> (Smart_Found,bool) {
    if v.objects==nil || use==USE_NONE {return {},false}
    row:=core.row_of(v.objects,object)
    if row<0 {return {},false}
    for offer,i in v.objects.values[row].offers {
        if offer.use==use {
            if found,ok:=smart_offer_at(v,object,i,user);ok {return found,true}
        }
    }
    return {},false
}

// The same view for a mind, using its existing world bindings.
mind_smart_view :: proc(a:^$T) -> Smart_View {
    w:=world_of(a)
    return {
        offers={objects=w.objects,index=w.smart_index,states=w.states,worlds=w.worlds,time=w.time},
        claims=core.ref(w.claims),
    }
}

// An exact offer that is open to this user.
smart_offer_at :: proc(
    v:Smart_View,object:core.Entity,i:int,user:Smart_User,expected:=USE_NONE,
) -> (Smart_Found,bool) {
    offer,ok:=smart_offer_read(v,object,i,user)
    if !ok || v.worlds==nil || expected!=USE_NONE && offer.use!=expected {return {},false}
    if v.claims.ptr!=nil && user.entity!=core.NONE &&
        !claim_open(v.claims.ptr,{u64(object),u16(i+1)},user.entity,max(int(offer.users),1),v.time,user.priority) {
        return {},false
    }
    pose,placed:=core.get(v.worlds,object)
    if !placed {return {},false}
    return offer_found(object,i,offer,pose.transform),true
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

// The nearest open offer of use within radius.
smart_nearest :: proc(v:Smart_View,use:Smart_Use,from:[3]f32,radius:f32,user:Smart_User) -> (found:Smart_Found,ok:bool) {
    best:=radius
    for entry in smart_entries(v.index.ptr,use) {
        candidate,open:=smart_offer_at(v,entry.object,int(entry.offer),user,use)
        if !open {continue}
        d:=linalg.length(mm.Vec3(candidate.at)-mm.Vec3(from))
        if !(d<=best) {continue}
        best,found,ok=d,candidate,true
    }
    return
}

smart_claim :: proc(a:^ai.Act($A),found:Smart_Found,user:Smart_User) -> bool {
    key:=smart_key(found)
    return ai.claim(a,key.target,key.what,found.users,user.priority)
}

@(private)
smart_offer_read :: proc(v:Smart_View,object:core.Entity,i:int,user:Smart_User) -> (Smart_Offer,bool) {
    if v.objects==nil || i<0 || i>=SMART_OFFERS {return {},false}
    row:=core.row_of(v.objects,object)
    if row<0 {return {},false}
    offer:=v.objects.values[row].offers[i]
    if offer.use==USE_NONE || offer.teams!=0 && u32(offer.teams)&(1<<u32(user.team))==0 ||
        u32(offer.abilities)&~u32(user.abilities)!=0 {return {},false}
    if v.states!=nil {
        if state_row:=core.row_of(v.states,object);state_row>=0 {
            state:=&v.states.values[state_row]
            if offer.uses>0 && state.used[i]>=offer.uses || !core.due(v.time,state.ready[i]) {
                return {},false
            }
        }
    }
    return offer,true
}

// Crosses the link the agent waits at (Nav_Path.state Crossing, of a kind the
// game crosses) by the offer of `use` on the entity of the link: it waits while
// that offer is closed to it (stage 0), takes `seconds` (1), and navigation
// puts it at the other end (nav.nav_crossing_skip) and takes it from there
// (2). How many cross at once is Nav_Link.capacity alone: navigation starts a
// crossing only within it, so the offer is not claimed and its `users` does
// not count. Success once across; Failure when it is not at such a link.
cross_act :: proc(a:^ai.Act($A),use:Smart_Use,user:Smart_User,seconds:f64) -> ai.Status {
    if a.phase==.Exit {return .Success}
    w,e,v:=world_of(a),agent(a),mind_smart_view(a)
    v.claims={}
    p,ok:=agent_path(a)
    crossing:=ok && p.state==.Crossing && p.manual
    if ai.stage(a)==2 {return .Running if crossing else .Success}
    if !crossing {return .Failure}
    if ai.stage(a)==0 {
        if _,open:=smart_offer(v,p.link_entity,use,user);!open {return .Running}
        ai.next_stage(a)
    }
    if ai.stage_elapsed(a)<seconds {return .Running}
    nav.nav_crossing_skip(w.requests,e)
    return ai.next_stage(a)
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
    w,e,v:=world_of(a),agent(a),mind_smart_view(a)
    switch a.phase {
    case .Enter:
        pose,placed:=core.get(v.worlds,e)
        ok:bool
        if placed {found,ok=smart_nearest(v,use,pose.position,radius,user)}
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
    if !ai.claim_held(a) {return {offer=-1}}
    data,ok:=smart_offer_read(v,object,offer,user)
    pose,placed:=core.get(v.worlds,object)
    if !ok || !placed {return {offer=-1}}
    return offer_found(object,offer,data,pose.transform)
}
