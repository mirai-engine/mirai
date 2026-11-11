package behavior

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// Queries of places: where to take cover, where to flank, where to flee, whom
// to go to, which smart object to use. A query lays out candidates around a
// point (rings, a grid, the points of the navigation mesh joined to it) or
// takes entities or the offers of smart objects as them,
// keeps those on the navigation mesh of the querier, measures each by its
// tests and scores them with their considerations; the best come
// back in the Place_Result of the querier, with the request it answers.
// Queries run in order of arrival, Behavior_Settings.queries of them a tick.
// The score is a product, so a ray or a search is spent only on a candidate
// the cheaper measures left above zero that can still be among the kept.

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
    Remembered,   // where the querier last perceived those of the teams of the query, within outer of the center
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
    arc:f32,              // radians of the rings, centered on where the center faces; 0: all around
    spacing:f32,          // m, of a grid or of the points of the mesh
    entities:[PLACE_ENTITIES]core.Entity, // of the layout Entities
    entity_count:u8,
    teams:Teams,          // of the layouts Perceivables and Remembered
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
@(component,derived,description="The best places of the last query of places of this agent, best first, with their scores.")
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
    worlds:^core.Table(core.World_Transform,.Read),perceivers:^core.Table(Perceiver,.Read),perceptions:^core.Table(Perception,.Read),perceivables:^core.Table(Perceivable,.Read),paths:^core.Table(nav.Nav_Path,.Read),
    agents:^core.Table(nav.Nav_Agent,.Read),characters:^core.Table(phys.Character,.Read),walks:^core.Table(locomotion.Walk,.Read),swims:^core.Table(locomotion.Swim,.Read),
    navigation:core.Ref(nav.Navigation),physics:core.Ref(phys.Physics_State),
    smart:Smart_View,influence:core.Ref(Influence),problems:^core.Problems,
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
        filter:=place_filter(navigation,query.querier,paths,agents,characters,walks,swims,physics)
        if _,memory:=place_run(places,query,&result,worlds,perceivers,perceptions,perceivables,paths,navigation,physics,&filter,smart,agents,influence.ptr);!memory {
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
place_filter :: proc(navigation:core.Ref(nav.Navigation),querier:core.Entity,paths:^core.Table(nav.Nav_Path,$A),agents:^core.Table(nav.Nav_Agent,$B),characters:^core.Table(phys.Character,$E),walks:^core.Table(locomotion.Walk,$C),swims:^core.Table(locomotion.Swim,$D),physics:core.Ref(phys.Physics_State)) -> ai.Nav_Filter {
    if navigation.ptr==nil || !navigation.ready || navigation.count==0 {return {}}
    class:=0
    if p,found:=core.get(paths,querier);found && p.class>=0 && int(p.class)<navigation.count {class=int(p.class)}
    agent,_:=core.get(agents,querier)
    walk,_:=core.get(walks,querier)
    character,_:=core.get(characters,querier)
    return nav.agent_filter(navigation.ptr,class,agent,walk,core.has(swims,querier),nav.agent_gravity(physics,querier,character))
}

// The candidates of a query, laid one after another.
@(private)
Place_Candidates :: struct {
    points:[PLACE_CANDIDATES]mm.Vec3,
    refs:[PLACE_CANDIDATES]ai.Nav_Ref,
    sources:[PLACE_CANDIDATES]core.Entity, // the entity a candidate was laid out from
    offers:[PLACE_CANDIDATES]i8,           // and its offer
    inputs:[PLACE_CANDIDATES*PLACE_TESTS]f32, // the measures of each, stride apart
    count,stride:int,
}

// Runs one query into a result; evals counts the rays and searches it took.
place_run :: proc(places:^Places,query:Place_Query,result:^Place_Result,worlds:^core.Table(core.World_Transform,$A),perceivers:^core.Table(Perceiver,$B),perceptions:^core.Table(Perception,$F),perceivables:^core.Table(Perceivable,$C),paths:^core.Table(nav.Nav_Path,$D),navigation:core.Ref(nav.Navigation),physics:core.Ref(phys.Physics_State),filter:^ai.Nav_Filter,smart:Smart_View,agents:^core.Table(nav.Nav_Agent,$E),influence:^Influence) -> (evals:int,memory:bool) {
    query:=query
    memory=true
    result^={request=query.request,status=.Empty,offers=-1}
    at_context :: proc(worlds:^core.Table(core.World_Transform,$A),querier:core.Entity,from:Place_Context,target:core.Entity,point:[3]f32) -> (pose:mm.Transform,ok:bool) {
        switch from {
        case .Querier: if p,found:=core.get(worlds,querier);found {return p.transform,true}
        case .Target: if p,found:=core.get(worlds,target);found {return p.transform,true}
        case .Point: return {position=point,rotation=1,scale=1},true
        }
        return
    }
    center:=at_context(worlds,query.querier,query.center,query.target,query.point) or_return
    tests:=query.tests[:min(int(query.test_count),PLACE_TESTS)]
    // A test measured from an entity that is gone has nothing to measure: no place is good.
    froms:[PLACE_TESTS]mm.Transform
    for test,k in tests {froms[k]=at_context(worlds,query.querier,test.from,test.target,test.point) or_return}
    mesh:^ai.Nav_Mesh
    volume:^ai.Nav_Volume
    class:=0
    if p,found:=core.get(paths,query.querier);found && p.class>=0 {class=int(p.class)}
    if navigation.ptr!=nil && navigation.ready && class<navigation.count {
        if nav.class_in_volume(navigation.ptr,class) {volume=&navigation.ptr.classes[class].volume} else {mesh=&navigation.ptr.classes[class].mesh}
    }
    c:Place_Candidates
    c.stride=max(len(tests),1)
    for &o in c.offers {o=-1}
    add :: proc(c:^Place_Candidates,at:mm.Vec3,source:core.Entity,offer:i8=-1) {
        if c.count>=PLACE_CANDIDATES {return}
        c.points[c.count],c.sources[c.count],c.offers[c.count]=at,source,offer
        c.count+=1
    }
    switch query.layout {
    case .Rings: c.count=ai.places_rings(center.position,query.inner,query.outer,int(query.rings),int(query.per_ring),c.points[:],mm.quat_forward(center.rotation),query.arc)
    case .Grid: c.count=ai.places_grid(center.position,query.outer,query.spacing,c.points[:])
    case .Mesh:
        if mesh==nil {
            c.count=ai.places_grid(center.position,query.outer,query.spacing,c.points[:])
            break
        }
        from,_,on:=ai.nav_find_nearest_any(mesh,center.position,{0.5,2,0.5})
        if !on || len(places.query.points)==0 && !ai.nav_query_init(&places.query,4096) {break}
        c.count=ai.places_mesh(&places.query,mesh,from,center.position,query.inner,query.outer,query.spacing,filter,c.points[:])
    case .Entities:
        for e in query.entities[:min(int(query.entity_count),PLACE_ENTITIES)] {
            if pose,found:=core.get(worlds,e);found {add(&c,pose.position,e)}
        }
    case .Perceivables:
        for row in 0..<core.count(perceivables) {
            e:=core.entity_at(perceivables,row)
            if e==query.querier || u32(query.teams)&(1<<u32(perceivables.values[row].team))==0 {continue}
            pose,found:=core.get(worlds,e)
            if !found || linalg.length(pose.position-center.position)>query.outer {continue}
            add(&c,pose.position,e)
        }
    case .Remembered:
        perception,found:=core.get(perceptions,query.querier)
        if !found {break}
        for o in perception.memory.items[:clamp(perception.memory.count,0,ai.PERCEPTION_CAPACITY)] {
            e:=core.Entity(o.subject)
            p,perceivable:=core.get(perceivables,e)
            if e==query.querier || !perceivable || u32(query.teams)&(1<<u32(p.team))==0 {continue}
            if !(linalg.length(o.position-center.position)<=query.outer) {continue}
            add(&c,o.position,e)
        }
    case .Offers:
        user:=Smart_User{entity=query.querier}
        if p,found:=core.get(perceivables,query.querier);found {user.team=p.team}
        if a,found:=core.get(agents,query.querier);found {user.abilities=a.abilities}
        for row in 0..<core.count(smart.objects) {
            e:=core.entity_at(smart.objects,row)
            object:=smart.objects.values[row]
            for offer,i in object.offers {
                if offer.use!=query.use {continue}
                state,_:=core.get(smart.states,e)
                pose,found:=core.get(worlds,e)
                if !found || !smart_open(smart,e,i,offer,state,user) {continue}
                at:=mm.transform_point(pose.transform,offer.at)
                if linalg.length(at-center.position)>query.outer {continue}
                add(&c,at,e,i8(i))
            }
        }
    }
    // Onto the mesh of the querier's class, or into its volume when it flies; those off it go.
    keep:[PLACE_CANDIDATES]bool
    if volume!=nil || mesh!=nil {
        for i in 0..<c.count {
            if volume!=nil {_,c.points[i],keep[i]=ai.nav_volume_find_nearest(volume,c.points[i],{0.5,1,0.5})}
            if mesh!=nil {c.refs[i],c.points[i],keep[i]=ai.nav_find_nearest_any(mesh,c.points[i],{0.5,2,0.5})}
        }
        place_sift(&c,keep[:])
    }
    considerations:[PLACE_TESTS]ai.Consideration
    for test,i in tests {considerations[i]={input=u16(i),min=test.min,max=test.max,response=test.response}}
    rule:=considerations[:len(tests)]
    // A ray, or a search through a volume, is one for each candidate; the
    // other measures read numbers, and the search over a mesh serves all.
    costly,measured:[PLACE_TESTS]bool
    expensive:=false
    for test,k in tests {
        costly[k]=test.measure==.Visible || test.measure==.Path && volume!=nil
        if costly[k] {expensive=true}
    }
    // First what reads numbers, then the search over the mesh: a candidate one
    // of them vetoes is not kept, whatever the rest measure.
    for search in ([]bool{false,true}) {
        for test,k in tests {
            if costly[k] || (test.measure==.Path)!=search || c.count==0 {continue}
            measured[k]=true
            if test.measure!=.Path {
                for i in 0..<c.count {c.inputs[i*c.stride+k]=place_measure(test,froms[k],c.points[i],query.querier,perceivers,physics,influence)}
                continue
            }
            if mesh!=nil {evals+=1}
            if !place_paths(places,froms[k].position,c.points[:c.count],c.refs[:c.count],mesh,nil,filter,c.inputs[k:],c.stride) {memory=false}
        }
        for i in 0..<c.count {keep[i]=place_bound(rule,measured[:],c.inputs[i*c.stride:][:c.stride])>0}
        place_sift(&c,keep[:])
    }
    // Then the costly ones, candidate by candidate from the highest score the
    // others allow down, until no candidate left can be among the kept.
    wanted:=clamp(int(query.keep),1,PLACE_KEPT)
    if expensive && c.count>0 {
        bounds:[PLACE_CANDIDATES]f32
        order:[PLACE_CANDIDATES]u8
        for i in 0..<c.count {
            bounds[i]=place_bound(rule,measured[:],c.inputs[i*c.stride:][:c.stride])
            at:=i
            for at>0 && bounds[order[at-1]]<bounds[i] {order[at]=order[at-1];at-=1}
            order[at]=u8(i)
        }
        keep={}
        top:[PLACE_KEPT]f32
        tops:=0
        candidates: for o in order[:c.count] {
            i:=int(o)
            if tops==wanted && place_below(bounds[i],top[wanted-1]) {break}
            row:=c.inputs[i*c.stride:][:c.stride]
            for measure in ([]Place_Measure{.Visible,.Path}) {
                for test,k in tests {
                    if !costly[k] || test.measure!=measure {continue}
                    evals+=1
                    if measure==.Path {
                        if !place_paths(places,froms[k].position,c.points[i:][:1],c.refs[i:][:1],nil,volume,filter,row[k:],c.stride) {memory=false}
                    } else {row[k]=place_measure(test,froms[k],c.points[i],query.querier,perceivers,physics,influence)}
                    if !(ai.consideration_score(rule[k],row)>0) {continue candidates}
                }
            }
            keep[i]=true
            score:=ai.score_considerations(rule,1,row)
            if tops<wanted {tops+=1} else if !(score>top[wanted-1]) {continue}
            at:=tops-1
            for at>0 && top[at-1]<score {top[at]=top[at-1];at-=1}
            top[at]=score
        }
        place_sift(&c,keep[:])
    }
    best:[PLACE_KEPT]ai.Place_Score
    kept:=ai.places_best(rule,c.inputs[:c.count*c.stride],c.stride,best[:wanted])
    for score,i in best[:kept] {
        result.points[i]=c.points[score.index]
        result.scores[i]=score.score
        result.entities[i]=c.sources[score.index]
        result.offers[i]=c.offers[score.index]
    }
    result.count=u8(kept)
    result.status=.Found if kept>0 else .Empty
    return
}

// Keeps the candidates of keep, in their order.
@(private)
place_sift :: proc(c:^Place_Candidates,keep:[]bool) {
    kept:=0
    for i in 0..<c.count {
        if !keep[i] {continue}
        c.points[kept],c.refs[kept],c.sources[kept],c.offers[kept]=c.points[i],c.refs[i],c.sources[i],c.offers[i]
        copy(c.inputs[kept*c.stride:][:c.stride],c.inputs[i*c.stride:][:c.stride])
        kept+=1
    }
    c.count=kept
}

// The highest score a candidate can reach once the tests not yet measured
// are: theirs taken as 1, since each multiplies it by at most that.
@(private)
place_bound :: proc(rule:[]ai.Consideration,measured:[]bool,row:[]f32) -> f32 {
    product:f32=1
    for c,k in rule {if measured[k] {product*=ai.consideration_score(c,row)}}
    return ai.score_product(product,len(rule),1)
}

// Whether a score from a product no greater than that of bound stays below
// top: the f32 rounding of the compensation can lift a lower product by a few
// ulps, relative to the score or, near zero, absolute.
@(private)
place_below :: proc "contextless" (bound,top:f32) -> bool {return bound+bound*1e-5+1e-37<top}

@(private)
place_measure :: proc(test:Place_Test,from:mm.Transform,candidate:mm.Vec3,querier:core.Entity,perceivers:^core.Table(Perceiver,$A),physics:core.Ref(phys.Physics_State),influence:^Influence) -> f32 {
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
