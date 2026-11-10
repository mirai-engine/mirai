package behavior

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// Queries of places: where to take cover, where to flank, where to flee, whom
// to go to, which smart object to use. A query lays out candidates around a
// point (rings, a grid, the points of the navigation mesh joined to it) or
// takes entities or the offers of smart objects as them,
// keeps those on the navigation mesh of the querier, measures each by its
// tests and scores them with their considerations; the best come
// back in the Place_Result of the querier, with the request it answers.
// Queries run in order of arrival, Behavior_Settings.queries of them a tick.

PLACE_TESTS :: 8
PLACE_CANDIDATES :: 128
PLACE_KEPT :: 8
PLACE_ENTITIES :: 16

Place_Layout :: enum u8 {
    Rings,        // rings from inner to outer around the center
    Grid,         // a square grid of spacing within outer
    Mesh,         // points of the mesh of the querier joined to the center, spacing apart, from inner to outer; a grid in a volume
    Entities,     // the entities of the query
    Perceivables, // the Perceivables of the teams of the query within outer of the center
    Offers,       // where the users of the offers of `use` stand, within outer of the center, those the querier can take now
}

Place_Measure :: enum u8 {
    Distance, // m from the candidate to the context
    Facing,   // cosine of the angle between where the context faces and the way to the candidate
    Visible,  // 1 when the eyes of the context see the candidate at a body's height, else 0
    Path,     // m of the way the querier walks there; PLACE_NO_PATH without one
    Influence,// of the teams of the test at the candidate (Influence): threat or allies
    Cover,    // 0 to 1, how covered the candidate is from the context (cover_at)
}
PLACE_NO_PATH :: f32(1e6)

// Whom a test measures from: the querier, an entity, or a point.
Place_Context :: enum u8 {Querier,Target,Point}

Place_Test :: struct {
    measure:Place_Measure,
    from:Place_Context,   // whom it measures from
    target:core.Entity,
    point:[3]f32,
    teams:Teams,          // of the measure Influence
    min,max:f32,          // of the measure, mapped to 0..1 for the response
    response:ai.Response,
}

Place_Query :: struct {
    querier:core.Entity,
    request:u32,          // place_query writes it: given back in the result
    center:Place_Context, // around whom: the querier, the target or the point
    target:core.Entity,
    point:[3]f32,
    layout:Place_Layout,
    inner,outer:f32,      // m
    rings,per_ring:u8,
    spacing:f32,          // m, of a grid or of the points of the mesh
    entities:[PLACE_ENTITIES]core.Entity, // of the layout Entities
    entity_count:u8,
    teams:Teams,          // of the layout Perceivables
    use:Smart_Use,        // of the layout Offers
    tests:[PLACE_TESTS]Place_Test,
    test_count:u8,
    keep:u8,              // best places kept, at most PLACE_KEPT
}

@(storage,queue)
Place_Requests :: struct {
    using queue:core.Queue(Place_Query),
    last:u32, // of the requests asked for so far: never 0
}

// Asks for places for the querier: the number its Place_Result answers with.
place_query :: proc(r:^Place_Requests,query:Place_Query) -> u32 {
    r.last+=1
    if r.last==0 {r.last=1}
    query:=query
    query.request=r.last
    core.push(&r.queue,query)
    return r.last
}

Place_Status :: enum u8 {None,Waiting,Found,Empty}

// The answer to the last query of an agent. Behavior is its only writer.
@(component,description="The best places of the last query of places of this agent, best first, with their scores.")
Place_Result :: struct {
    request:u32 `mirai:"readonly,transient"`,
    status:Place_Status `mirai:"readonly,transient"`,
    count:u8 `mirai:"readonly,transient"`,
    points:[PLACE_KEPT][3]f32 `mirai:"readonly,transient"`,
    scores:[PLACE_KEPT]f32 `mirai:"readonly,transient"`,
    entities:[PLACE_KEPT]core.Entity `mirai:"readonly,transient"`, // of each place laid out from an entity; none for a point
    offers:[PLACE_KEPT]i8 `mirai:"readonly,transient"`, // of each place laid out from an offer of a smart object; -1 for others
}

// What the queries keep between ticks: those that wait, and a search for the
// Path measure. Not the state of the world.
@(storage,host,by_world,free="places_free")
Places :: struct {
    waiting:[dynamic]Place_Query, // from head on, in order of arrival
    head:int,
    query:ai.Nav_Query,
    volume_query:ai.Nav_Volume_Query,
    refs:[dynamic]ai.Nav_Ref,
}

places_free :: proc(p:^Places) {
    delete(p.waiting);delete(p.refs)
    ai.nav_query_destroy(&p.query)
    ai.nav_volume_query_destroy(&p.volume_query)
    p^={}
}

@(step="fixed",stage="react",server)
places_run :: proc(
    requests:^Place_Requests,places:^Places,results:^core.Table(Place_Result),settings:core.Ref(Behavior_Settings),
    worlds:core.Read(core.World_Transform),perceivers:core.Read(Perceiver),perceivables:core.Read(Perceivable),paths:core.Read(nav.Nav_Path),
    agents:core.Read(nav.Nav_Agent),walks:core.Read(phys.Walk),swims:core.Read(phys.Swim),
    navigation:core.Ref(nav.Navigation),physics:core.Ref(phys.Physics_State),
    objects:core.Read(Smart_Object),states:core.Read(Smart_State),claims:^Claims,influence:core.Ref(Influence),time:core.Time,problems:^core.Problems,
) {
    if len(requests.queue.items)==0 && len(places.waiting)==0 {return}
    for query in core.take(&requests.queue) {
        append(&places.waiting,query)
        result:=core.staged(results,query.querier)
        if result==nil {
            core.add(results,query.querier,Place_Result{request=query.request,status=.Waiting})
        } else {result^={request=query.request,status=.Waiting}}
    }
    budget:=int(settings.queries) if settings.ptr!=nil else 4
    for budget>0 && places.head<len(places.waiting) {
        query:=places.waiting[places.head]
        places.head+=1
        // A querier destroyed while it waited gets no answer.
        if _,alive:=core.get(worlds,query.querier);!alive {continue}
        // Only the last query of a querier is answered: one asked after it waits in its row.
        row:=core.staged(results,query.querier)
        if row!=nil && row.request!=query.request {continue}
        budget-=1
        result:Place_Result
        filter:=place_filter(navigation,query.querier,paths,agents,walks,swims,physics)
        smart:=Smart_View{objects=objects,states=states,worlds=worlds,claims=claims,time=time.seconds,tick=time.tick}
        if !place_run(places,query,&result,worlds,perceivers,perceivables,paths,navigation,physics,&filter,&smart,agents,influence.ptr) {
            core.report(problems,query.querier,"behavior.memory","no memory for the path search of a place query: its Path tests find no path to any place; free memory")
        }
        if row!=nil {row^=result}
    }
    if places.head==len(places.waiting) {
        clear(&places.waiting)
        places.head=0
    } else if places.head>=64 && places.head*2>=len(places.waiting) {
        copy(places.waiting[:],places.waiting[places.head:])
        base.truncate(&places.waiting,len(places.waiting)-places.head)
        places.head=0
    }
}

// What the querier walks and crosses, for the Path measure: as navigation moves it.
place_filter :: proc(navigation:core.Ref(nav.Navigation),querier:core.Entity,paths:core.Read(nav.Nav_Path),agents:core.Read(nav.Nav_Agent),walks:core.Read(phys.Walk),swims:core.Read(phys.Swim),physics:core.Ref(phys.Physics_State)) -> ai.Nav_Filter {
    if navigation.ptr==nil || !navigation.ready || navigation.count==0 {return {}}
    class:=0
    if p,found:=core.get(paths,querier);found && p.class>=0 && int(p.class)<navigation.count {class=int(p.class)}
    agent,_:=core.get(agents,querier)
    walk,_:=core.get(walks,querier)
    gravity:=linalg.length(phys.gravity_of_entity(physics,querier))
    return nav.agent_filter(navigation.ptr,class,agent,{walk.jump_height,walk.max_speed},core.has(swims,querier),gravity)
}

// Runs one query into a result.
place_run :: proc(places:^Places,query:Place_Query,result:^Place_Result,worlds:core.Read(core.World_Transform),perceivers:core.Read(Perceiver),perceivables:core.Read(Perceivable),paths:core.Read(nav.Nav_Path),navigation:core.Ref(nav.Navigation),physics:core.Ref(phys.Physics_State),filter:^ai.Nav_Filter,smart:^Smart_View,agents:core.Read(nav.Nav_Agent),influence:^Influence) -> (memory:bool) {
    query:=query
    memory=true
    result^={request=query.request,status=.Empty,offers=-1}
    at_context :: proc(worlds:core.Read(core.World_Transform),querier:core.Entity,from:Place_Context,target:core.Entity,point:[3]f32) -> (pose:mm.Transform,ok:bool) {
        switch from {
        case .Querier: if p,found:=core.get(worlds,querier);found {return p.transform,true}
        case .Target: if p,found:=core.get(worlds,target);found {return p.transform,true}
        case .Point: return {position=point,rotation=1,scale=1},true
        }
        return
    }
    center,ok:=at_context(worlds,query.querier,query.center,query.target,query.point)
    if !ok {return}
    mesh:^ai.Nav_Mesh
    volume:^ai.Nav_Volume
    class:=0
    if p,found:=core.get(paths,query.querier);found && p.class>=0 {class=int(p.class)}
    if navigation.ptr!=nil && navigation.ready && class<navigation.count {
        if nav.class_in_volume(navigation.ptr,class) {volume=&navigation.ptr.classes[class].volume} else {mesh=&navigation.ptr.classes[class].mesh}
    }
    candidates:[PLACE_CANDIDATES]mm.Vec3
    sources:[PLACE_CANDIDATES]core.Entity // the entity a candidate was laid out from
    offers:[PLACE_CANDIDATES]i8           // and its offer
    for &o in offers {o=-1}
    count:int
    switch query.layout {
    case .Rings: count=ai.places_rings(center.position,query.inner,query.outer,int(query.rings),int(query.per_ring),candidates[:])
    case .Grid: count=ai.places_grid(center.position,query.outer,query.spacing,candidates[:])
    case .Mesh:
        if mesh==nil {
            count=ai.places_grid(center.position,query.outer,query.spacing,candidates[:])
            break
        }
        from,_,on:=ai.nav_find_nearest_any(mesh,center.position,{0.5,2,0.5})
        if !on || len(places.query.points)==0 && !ai.nav_query_init(&places.query,4096) {break}
        count=ai.places_mesh(&places.query,mesh,from,center.position,query.inner,query.outer,query.spacing,filter,candidates[:])
    case .Entities:
        for e in query.entities[:min(int(query.entity_count),PLACE_ENTITIES)] {
            if pose,found:=core.get(worlds,e);found && count<PLACE_CANDIDATES {
                candidates[count],sources[count]=pose.position,e
                count+=1
            }
        }
    case .Perceivables:
        for row in 0..<core.count(perceivables) {
            e:=core.entity_at(perceivables,row)
            if e==query.querier || u32(query.teams)&(1<<u32(perceivables.table.values[row].team))==0 || count>=PLACE_CANDIDATES {continue}
            pose,found:=core.get(worlds,e)
            if !found || linalg.length(pose.position-center.position)>query.outer {continue}
            candidates[count],sources[count]=pose.position,e
            count+=1
        }
    case .Offers:
        user:=Smart_User{entity=query.querier}
        if p,found:=core.get(perceivables,query.querier);found {user.team=p.team}
        if a,found:=core.get(agents,query.querier);found {user.abilities=a.abilities}
        for row in 0..<core.count(smart.objects) {
            e:=core.entity_at(smart.objects,row)
            object:=smart.objects.table.values[row]
            for offer,i in object.offers {
                if offer.use!=query.use || count>=PLACE_CANDIDATES {continue}
                state,_:=core.get(smart.states,e)
                pose,found:=core.get(worlds,e)
                if !found || !smart_open(smart,e,i,offer,state,user) {continue}
                at:=mm.transform_point(pose.transform,offer.at)
                if linalg.length(at-center.position)>query.outer {continue}
                candidates[count],sources[count],offers[count]=at,e,i8(i)
                count+=1
            }
        }
    }
    // Onto the mesh of the querier's class, or into its volume when it flies; those off it go.
    if volume!=nil {
        kept:=0
        for i in 0..<count {
            _,inside,found:=ai.nav_volume_find_nearest(volume,candidates[i],{0.5,1,0.5})
            if !found {continue}
            candidates[kept],sources[kept],offers[kept]=inside,sources[i],offers[i]
            kept+=1
        }
        count=kept
    }
    refs:[PLACE_CANDIDATES]ai.Nav_Ref
    if mesh!=nil {
        kept:=0
        for i in 0..<count {
            ref,on,found:=ai.nav_find_nearest_any(mesh,candidates[i],{0.5,2,0.5})
            if !found {continue}
            candidates[kept],refs[kept],sources[kept],offers[kept]=on,ref,sources[i],offers[i]
            kept+=1
        }
        count=kept
    }
    tests:=query.tests[:min(int(query.test_count),PLACE_TESTS)]
    considerations:[PLACE_TESTS]ai.Consideration
    for test,i in tests {considerations[i]={input=u16(i),min=test.min,max=test.max,response=test.response}}
    inputs:[PLACE_CANDIDATES*PLACE_TESTS]f32
    stride:=max(len(tests),1)
    // A test measured from an entity that is gone has nothing to measure: no place is good.
    for test in tests {
        if _,has:=at_context(worlds,query.querier,test.from,test.target,test.point);!has {return}
    }
    for test,k in tests {
        from,_:=at_context(worlds,query.querier,test.from,test.target,test.point)
        if test.measure==.Path {
            if !place_paths(places,from.position,candidates[:count],refs[:count],mesh,volume,filter,inputs[k:],stride) {memory=false}
            continue
        }
        for i in 0..<count {inputs[i*stride+k]=place_measure(test,from,candidates[i],query.querier,perceivers,physics,influence)}
    }
    best:[PLACE_KEPT]ai.Place_Score
    keep:=clamp(int(query.keep),1,PLACE_KEPT)
    kept:=ai.places_best(considerations[:len(tests)],inputs[:count*stride],stride,best[:keep])
    for score,i in best[:kept] {
        result.points[i]=candidates[score.index]
        result.scores[i]=score.score
        result.entities[i]=sources[score.index]
        result.offers[i]=offers[score.index]
    }
    result.count=u8(kept)
    result.status=.Found if kept>0 else .Empty
    return
}

@(private)
place_measure :: proc(test:Place_Test,from:mm.Transform,candidate:mm.Vec3,querier:core.Entity,perceivers:core.Read(Perceiver),physics:core.Ref(phys.Physics_State),influence:^Influence) -> f32 {
    source,target:=test.from,test.target
    #partial switch test.measure {
    case .Distance:
        return linalg.length(candidate-from.position)
    case .Facing:
        forward:=mm.quat_forward(from.rotation)
        to:=candidate-from.position
        to.y,forward.y=0,0
        if linalg.length(to)<1e-4 || linalg.length(forward)<1e-4 {return 1}
        return linalg.dot(linalg.normalize(to),linalg.normalize(forward))
    case .Visible:
        eyes:=f32(1.6)
        who:=querier if source==.Querier else target
        if p,found:=core.get(perceivers,who);found {eyes=p.eyes}
        eye:=from.position+{0,eyes,0}
        point:=candidate+{0,1.2,0}
        to:=point-eye
        distance:=linalg.length(to)
        if distance<1e-4 {return 1}
        if _,blocked:=phys.raycast(physics,eye,to/distance,distance,who);blocked {return 0}
        return 1
    case .Influence:
        return influence_at(influence,candidate,test.teams)
    case .Cover:
        return cover_at(influence,candidate,from.position)
    }
    return 0
}

// The Path measure of every candidate from one origin, into out at the stride:
// on a mesh, one search from where the origin stands to all of them; through
// a volume, a search for each.
@(private)
place_paths :: proc(places:^Places,origin:mm.Vec3,candidates:[]mm.Vec3,refs:[]ai.Nav_Ref,mesh:^ai.Nav_Mesh,volume:^ai.Nav_Volume,filter:^ai.Nav_Filter,out:[]f32,stride:int) -> (memory:bool) {
    for i in 0..<len(candidates) {out[i*stride]=PLACE_NO_PATH}
    if volume!=nil {
        from_ref,start,ok:=ai.nav_volume_find_nearest(volume,origin,{0.5,1,0.5})
        if !ok {return true}
        if len(places.volume_query.points)==0 && !ai.nav_volume_query_init(&places.volume_query,4096) {return false}
        if len(places.refs)==0 && resize(&places.refs,1024)!=nil {return false}
        for candidate,i in candidates {
            to_ref,end,found:=ai.nav_volume_find_nearest(volume,candidate,{0.5,1,0.5})
            if !found {continue}
            _,status,partial:=ai.nav_volume_find_path(&places.volume_query,volume,from_ref,to_ref,start,end,places.refs[:])
            if status==.Found && !partial {out[i*stride]=ai.search_cost(&places.volume_query.search)}
        }
        return true
    }
    if mesh==nil {return true}
    from_ref,start,ok:=ai.nav_find_nearest_any(mesh,origin,{0.5,2,0.5})
    if !ok {return true}
    if len(places.query.points)==0 && !ai.nav_query_init(&places.query,4096) {return false}
    if !ai.nav_costs(&places.query,mesh,from_ref,start,filter,refs) {return true}
    for candidate,i in candidates {
        if cost,found:=ai.nav_cost_to(&places.query,mesh,refs[i],candidate);found {out[i*stride]=cost}
    }
    return true
}
