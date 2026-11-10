package behavior_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/ai"
import "mirai:std/base"
import behavior "plugins:behavior/runtime"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

@(storage)
Behavior_Api :: struct {provider:editor.Api_Provider}

BEHAVIOR_API_DEFAULT :: Behavior_Api{provider={register=register}}

Entity_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
}

Query_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The querier"`,
    layout:behavior.Place_Layout `mirai:"optional"`,
    around:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Around this entity; omitted: around the querier, or point"`,
    point:[3]f32 `mirai:"optional"`,
    inner:f32 `mirai:"optional,min=0,unit=m"`,
    outer:f32 `mirai:"optional,min=0,unit=m"`,
    rings:u8 `mirai:"optional,min=1,max=16"`,
    per_ring:u8 `mirai:"optional,min=1,max=64"`,
    spacing:f32 `mirai:"optional,min=0.1,unit=m"`,
    entities:[behavior.PLACE_ENTITIES]editor.Api_Entity_Text `mirai:"text,entity,optional,label=The candidates of the layout Entities"`,
    teams:behavior.Teams `mirai:"optional,label=The teams whose Perceivables are the candidates of the layout Perceivables"`,
    use:behavior.Smart_Use `mirai:"optional,label=The use whose offers of smart objects are the candidates of the layout Offers"`,
    from:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Whom the tests measure from; omitted: the querier"`,
    nearer:bool `mirai:"optional,label=Prefer places nearer to the querier"`,
    hidden:bool `mirai:"optional,label=Prefer places 'from' does not see (cover by a ray)"`,
    seen:bool `mirai:"optional,label=Prefer places 'from' sees"`,
    covered:bool `mirai:"optional,label=Prefer places the influence maps measure as covered from 'from'"`,
    reachable:bool `mirai:"optional,label=Only places the querier can walk to, nearer by the way first"`,
    threat:behavior.Teams `mirai:"optional,label=Prefer places where the influence of these teams is low"`,
    allies:behavior.Teams `mirai:"optional,label=Prefer places where the influence of these teams is high"`,
    keep:u8 `mirai:"optional,min=1,max=8"`,
}

Influence_Params :: struct {
    point:[3]f32,
    from:[3]f32 `mirai:"optional,label=Whom the cover is measured from"`,
}

Minds_Result :: struct {minds:[]Mind_Result}
Mind_Result :: struct {
    name:string,
    actions:[]string,
    agents:int `mirai:"label=Mind_Agents of the shown world that run it"`,
}

Inspect_Result :: struct {
    mind:string,
    note:string `mirai:"optional,label=Why nothing else is told"`,
    ticks:u64 `mirai:"optional"`,
    running:Frame_Result `mirai:"optional,label=The action it runs; left out with none"`,
    step:Frame_Result `mirai:"optional,label=The step of the action it runs; left out with none"`,
    score,commit:f32 `mirai:"optional"`,
    proposals:[]Proposal_Result `mirai:"optional,label=The best of its last decision"`,
    exits:[]Exit_Result `mirai:"optional,label=Its last exits, the most recent first"`,
}
Frame_Result :: struct {
    action:string,
    stage:int,
    seconds,stage_seconds:f32 `mirai:"unit=s"`,
    holds:Holds_Result `mirai:"optional,label=What it holds of the claims"`,
}
Holds_Result :: struct {
    target:base.Entity_Id,
    what:int,
}
Proposal_Result :: struct {
    action:string,
    score:f32,
}
Exit_Result :: struct {
    action,cause:string,
    interrupted_by:string `mirai:"optional"`,
    step:bool,
}

Perception_Result :: struct {remembers:[]Perceived_Result}
Perceived_Result :: struct {
    subject:base.Entity_Id,
    position:[3]f32,
    senses:string,
    confidence:f32,
    seconds:f32 `mirai:"unit=s,label=Since it first perceived it"`,
    last_seconds:f32 `mirai:"unit=s,label=Since it last perceived it"`,
}

Offers_Result :: struct {offers:[]Offer_Result}
Offer_Result :: struct {
    offer,use:int,
    at:[3]f32,
    users,uses,used:int,
    cooldown:f32 `mirai:"unit=s"`,
    ready_seconds:f32 `mirai:"unit=s,label=Until it is offered again"`,
    held:int `mirai:"optional,label=Users that hold it now"`,
}

Influence_Result :: struct {
    note:string `mirai:"optional,label=Why there is no value"`,
    teams:[]f32 `mirai:"optional,label=The influence of each team at the point"`,
    cover:f32 `mirai:"optional"`,
    passes:u64 `mirai:"optional"`,
}

Query_Result :: struct {
    status:string,
    places:[]Place_Result,
}
Place_Result :: struct {
    position:[3]f32,
    score:f32,
    entity:base.Entity_Id `mirai:"optional"`,
    offer:int `mirai:"label=The offer of the smart object it names; -1 for none"`,
}

@(private)
register :: proc(s:^editor.Session) {
    query_defaults:=Query_Params{inner=2,outer=8,rings=3,per_ring=12,spacing=1,keep=5}
    editor.api_method_register(s,{name="behavior.minds",summary="The minds the game ticks (behavior.minds_tick): their names, their actions and how many Mind_Agents of the shown world run each.",flags={.Read_Only},result=Minds_Result,result_info=type_info_of(Minds_Result),run=minds})
    editor.api_method_register(s,{name="behavior.inspect",summary="What the mind of a Mind_Agent does and why: the action and the step it runs by name, its stage and since when, its commit, the best proposals of its last decision with their scores, its last exits with their cause and what interrupted them, and what it holds of the claims. Use it in Play to see why an agent decides what it does.",params=Entity_Params,params_info=type_info_of(Entity_Params),flags={.Read_Only},result=Inspect_Result,result_info=type_info_of(Inspect_Result),run=inspect})
    editor.api_method_register(s,{name="behavior.perception",summary="What a Perceiver remembers: each subject it saw or heard, where, by which senses this tick, how sure it still is, and the seconds since it first and last perceived it.",params=Entity_Params,params_info=type_info_of(Entity_Params),flags={.Read_Only},result=Perception_Result,result_info=type_info_of(Perception_Result),run=perception})
    editor.api_method_register(s,{name="behavior.offers",summary="The offers of a Smart_Object: each use, where its user stands, who may take it, how many at once, how many times and how often, how many times it was used, when it is offered again and who holds it now.",params=Entity_Params,params_info=type_info_of(Entity_Params),flags={.Read_Only},result=Offers_Result,result_info=type_info_of(Offers_Result),run=offers})
    editor.api_method_register(s,{name="behavior.influence",summary="The influence maps at a point of the shown world: the influence of each team there (threat or allies, as an agent reads it) and how covered the point is from 'from'.",params=Influence_Params,params_info=type_info_of(Influence_Params),flags={.Read_Only},result=Influence_Result,result_info=type_info_of(Influence_Result),run=influence})
    editor.api_method_register(s,{name="behavior.query",summary="Runs a query of places now, for an agent of the shown world: candidates on rings, a grid or the points of its navigation mesh joined to it (around it, another entity or a point), entities (those given, or the Perceivables of some teams) or the offers of a use of smart objects, kept on its navigation mesh and scored by what is asked (nearer, hidden from, seen by or covered from 'from', reachable, low threat, many allies); returns the best with their scores. What a game asks with behavior.place_query.",params=Query_Params,params_info=type_info_of(Query_Params),defaults=&query_defaults,flags={.Read_Only},result=Query_Result,result_info=type_info_of(Query_Result),run=query})
}

// The Minds of the application: a storage of Shared, which the world reflection does not give.
@(private)
minds_of :: proc(s:^editor.Session) -> ^behavior.Minds {
    w:=editor.shown_world(s)
    if w.info==nil || s.app==nil || s.app.shared==nil {return nil}
    for &info in w.info.storages {
        if info.type==behavior.Minds && info.place==.Shared {return (^behavior.Minds)(uintptr(s.app.shared)+info.offset)}
    }
    return nil
}

// The Influence of a world: by world, in the Shared.
@(private)
influence_of :: proc(s:^editor.Session,world:core.World_Ref) -> ^behavior.Influence {
    if s.app==nil {return nil}
    return host.app_world_storage(s.app,world.data,behavior.Influence)
}

@(private)
entity_of :: proc(s:^editor.Session,call:^api.Call,named:[]u8,$T:typeid,what:string) -> (w:core.World_Ref,e:core.Entity,table:^core.Table(T),ok:bool) {
    w=editor.shown_world(s)
    e=editor.api_call_entity(call,w,named,game=s.mode!=.Edit) or_return
    table=core.world_table_of(w,T)
    if table==nil || !core.has(table,e) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a %s in the shown world",base.text_get(named),what)
        return
    }
    return w,e,table,true
}

@(private)
name_text :: proc(name:behavior.Mind_Name) -> string {
    name:=name
    return fmt.tprintf("%s",base.text_get(name[:]))
}

// The name of a value of the enum of a mind, or its number.
@(private)
action_name :: proc(entry:^behavior.Mind_Entry,action:u16) -> string {
    if name:=behavior.mind_action_name(entry,action);name!="" {return fmt.tprintf("%s",name)}
    return fmt.tprintf("%d",action)
}

@(private)
id_of :: proc(world:core.World_Ref,e:core.Entity) -> base.Entity_Id {
    if ids:=core.world_table_of(world,core.Id);ids!=nil {if value,has:=core.get(ids,e);has {return value.value}}
    return 0
}

@(private)
minds :: proc(s:^editor.Session,call:^api.Call) {
    registry:=minds_of(s)
    shown:=make([dynamic]Mind_Result,call.allocator)
    if registry!=nil {
        agents:=core.world_table_of(editor.shown_world(s),behavior.Mind_Agent)
        for &entry in registry.entries[:clamp(registry.count,0,behavior.MINDS_CAPACITY)] {
            running:=0
            if agents!=nil {for agent in agents.values[:core.count(agents)] {if agent.mind==entry.name {running+=1}}}
            actions:=make([dynamic]string,call.allocator)
            for k in 0..<ai.MIND_ACTIONS {
                if name:=behavior.mind_action_name(&entry,u16(k));name!="" {append(&actions,fmt.tprint(name))}
            }
            append(&shown,Mind_Result{name_text(entry.name),actions[:],running})
        }
    }
    api.call_result(call,Minds_Result).minds=shown[:]
}

@(private)
inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    world,agent_entity,agents,ok:=entity_of(s,call,p.entity[:],behavior.Mind_Agent,"Mind_Agent")
    if !ok {return}
    agent:=&agents.values[core.row_of(agents,agent_entity)]
    entry:=behavior.mind_of(minds_of(s),agent.mind)
    r:=api.call_result(call,Inspect_Result)
    r.mind=name_text(agent.mind)
    if entry==nil {
        r.note="no mind is registered by this name: the game ticks it with behavior.minds_tick, which registers it"
        return
    }
    m:=&agent.state
    now:core.Time
    if t:=core.world_storage_of(world,core.Time);t!=nil {now=t^}
    r.ticks=u64(m.ticks)
    action,step:=ai.mind_running(m)
    frame_of :: proc(world:core.World_Ref,entry:^behavior.Mind_Entry,action:u16,frame:^ai.Act_Frame,now:core.Time) -> (shown:Frame_Result) {
        if action==ai.MIND_NONE {return}
        shown={action=action_name(entry,action),stage=int(frame.stage),seconds=core.elapsed(now,frame.entered),stage_seconds=core.elapsed(now,frame.staged)}
        if frame.reserved.target!=0 {shown.holds={id_of(world,core.Entity(frame.reserved.target)),int(frame.reserved.what)}}
        return
    }
    r.running,r.step=frame_of(world,entry,action,&m.main,now),frame_of(world,entry,step,&m.step,now)
    r.score,r.commit=m.score,m.commit
    proposals:=make([dynamic]Proposal_Result,call.allocator)
    for proposal in m.proposals {
        if !(proposal.score>0) {break}
        append(&proposals,Proposal_Result{action_name(entry,proposal.action),proposal.score})
    }
    exits:=make([dynamic]Exit_Result,call.allocator)
    for back in 0..<ai.MIND_TRACE {
        exit,found:=ai.mind_exit_trace(m,back)
        if !found {break}
        append(&exits,Exit_Result{action_name(entry,exit.action),fmt.tprintf("%v",exit.cause),exit.by!=ai.MIND_NONE?action_name(entry,exit.by):"",exit.step})
    }
    r.proposals,r.exits=proposals[:],exits[:]
}

@(private)
perception :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    world,e,_,ok:=entity_of(s,call,p.entity[:],behavior.Perceiver,"Perceiver")
    if !ok {return}
    now:core.Time
    if t:=core.world_storage_of(world,core.Time);t!=nil {now=t^}
    remembers:=make([dynamic]Perceived_Result,call.allocator)
    if perceptions:=core.world_table_of(world,behavior.Perception);perceptions!=nil {
        if mine,found:=core.get(perceptions,e);found {
            for o in mine.memory.items[:clamp(mine.memory.count,0,ai.PERCEPTION_CAPACITY)] {
                append(&remembers,Perceived_Result{id_of(world,core.Entity(o.subject)),o.position,fmt.tprintf("%v",o.senses),o.confidence,core.elapsed(now,o.first),core.elapsed(now,o.last)})
            }
        }
    }
    api.call_result(call,Perception_Result).remembers=remembers[:]
}

@(private)
offers :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    world,e,objects,ok:=entity_of(s,call,p.entity[:],behavior.Smart_Object,"Smart_Object")
    if !ok {return}
    object,_:=core.get(objects,e)
    state:behavior.Smart_State
    if states:=core.world_table_of(world,behavior.Smart_State);states!=nil {state,_=core.get(states,e)}
    claims:=core.world_storage_of(world,behavior.Claims)
    now:core.Time
    if t:=core.world_storage_of(world,core.Time);t!=nil {now=t^}
    shown:=make([dynamic]Offer_Result,call.allocator)
    for offer,i in object.offers {
        if offer.use==behavior.USE_NONE {continue}
        o:=Offer_Result{offer=i,use=int(offer.use),at=offer.at,users=int(max(offer.users,1)),uses=int(offer.uses),used=int(state.used[i]),cooldown=offer.cooldown}
        o.ready_seconds=core.due(now,state.ready[i])?0:core.seconds_of(now,state.ready[i]-now.tick)
        if claims!=nil {o.held=int(ai.reserve_count(&claims.reservations,{u64(e),u16(i+1)},now.tick))}
        append(&shown,o)
    }
    api.call_result(call,Offers_Result).offers=shown[:]
}

@(private)
influence :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Influence_Params)
    world:=editor.shown_world(s)
    maps:=influence_of(s,world)
    r:=api.call_result(call,Influence_Result)
    if maps==nil || !ai.influence_ready(&maps.grid) {
        r.note="no influence maps: they are made in Play or Simulate, when Behavior_Settings.influence_cell is above 0"
        return
    }
    if _,inside:=ai.influence_cell(&maps.grid,p.point);!inside {
        r.note="the point is outside the influence maps: move Behavior_Settings.influence_center or grow influence_size"
        return
    }
    values:=make([]f32,behavior.INFLUENCE_TEAMS,call.allocator)
    for &v,team in values {v=behavior.influence_at(maps,p.point,behavior.Teams(1<<u32(team)))}
    r.teams,r.cover,r.passes=values,behavior.cover_at(maps,p.point,p.from),u64(maps.grid.passes)
}

@(private)
query :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Query_Params)
    world,e,_,ok:=entity_of(s,call,p.entity[:],core.World_Transform,"place in the world")
    if !ok {return}
    q:=behavior.Place_Query{querier=e,layout=p.layout,inner=p.inner,outer=max(p.outer,p.inner),rings=p.rings,per_ring=p.per_ring,spacing=p.spacing,teams=p.teams,use=p.use,keep=p.keep}
    for &text,i in p.entities {
        if text[0]==0 {continue}
        candidate,named:=editor.api_call_entity(call,world,text[:],fmt.tprintf("entities[%d]",i),s.mode!=.Edit)
        if !named {return}
        q.entities[q.entity_count]=candidate
        q.entity_count+=1
    }
    switch {
    case p.around[0]!=0:
        around,named:=editor.api_call_entity(call,world,p.around[:],"around",s.mode!=.Edit)
        if !named {return}
        q.center,q.target=.Target,around
    case p.point!={}:
        q.center,q.point=.Point,p.point
    }
    from:=behavior.Place_Context.Querier
    from_entity:=core.NONE
    if p.from[0]!=0 {
        named:bool
        if from_entity,named=editor.api_call_entity(call,world,p.from[:],"from",s.mode!=.Edit);!named {return}
        from=.Target
    }
    if p.layout==.Offers && p.use==behavior.USE_NONE {api.call_fail(call,api.INVALID_PARAMS,"the layout Offers needs the use whose offers it lays out: pass use");return}
    add :: proc(q:^behavior.Place_Query,test:behavior.Place_Test) {
        if int(q.test_count)<behavior.PLACE_TESTS {q.tests[q.test_count]=test;q.test_count+=1}
    }
    falling:=ai.Response{kind=.Linear,slope=-1,shift_y=1}
    rising:=ai.Response{kind=.Linear,slope=1}
    if p.nearer {add(&q,{measure=.Distance,from=.Querier,min=0,max=q.outer*2,response=falling})}
    if p.hidden {add(&q,{measure=.Visible,from=from,target=from_entity,min=0,max=1,response=falling})}
    if p.seen {add(&q,{measure=.Visible,from=from,target=from_entity,min=0,max=1,response=rising})}
    if p.covered {add(&q,{measure=.Cover,from=from,target=from_entity,min=0,max=1,response={kind=.Linear,slope=0.9,shift_y=0.1}})}
    if p.reachable {add(&q,{measure=.Path,from=.Querier,min=0,max=q.outer*4,response=falling})}
    if p.threat!=0 {add(&q,{measure=.Influence,teams=p.threat,min=0,max=2,response=falling})}
    if p.allies!=0 {add(&q,{measure=.Influence,teams=p.allies,min=0,max=2,response={kind=.Linear,slope=0.9,shift_y=0.1}})}
    if q.test_count==0 {add(&q,{measure=.Distance,from=.Querier,min=0,max=q.outer*2,response=falling})}
    worlds:=core.world_table_of(world,core.World_Transform)
    perceivers:=core.world_table_of(world,behavior.Perceiver)
    paths:=core.world_table_of(world,nav.Nav_Path)
    navigation:=core.world_storage_of(world,nav.Navigation)
    physics:=core.world_storage_of(world,phys.Physics_State)
    empty_perceivers:core.Table(behavior.Perceiver)
    perceivables:=core.world_table_of(world,behavior.Perceivable)
    empty_perceivables:core.Table(behavior.Perceivable)
    empty_paths:core.Table(nav.Nav_Path)
    objects:=core.world_table_of(world,behavior.Smart_Object)
    empty_objects:core.Table(behavior.Smart_Object)
    states:=core.world_table_of(world,behavior.Smart_State)
    empty_states:core.Table(behavior.Smart_State)
    places:behavior.Places
    defer behavior.places_free(&places)
    result:behavior.Place_Result
    agents:=core.world_table_of(world,nav.Nav_Agent)
    walks:=core.world_table_of(world,phys.Walk)
    empty_agents:core.Table(nav.Nav_Agent)
    empty_walks:core.Table(phys.Walk)
    swims:=core.world_table_of(world,phys.Swim)
    empty_swims:core.Table(phys.Swim)
    paths_read:=core.read(paths if paths!=nil else &empty_paths)
    agents_read:=core.read(agents if agents!=nil else &empty_agents)
    time:core.Time
    if t:=core.world_storage_of(world,core.Time);t!=nil {time=t^}
    smart:=behavior.Smart_View{objects=core.read(objects if objects!=nil else &empty_objects),states=core.read(states if states!=nil else &empty_states),worlds=core.read(worlds),claims=core.world_storage_of(world,behavior.Claims),time=time}
    filter:=behavior.place_filter(core.ref(navigation),e,paths_read,agents_read,core.read(walks if walks!=nil else &empty_walks),core.read(swims if swims!=nil else &empty_swims),core.ref(physics))
    if !behavior.place_run(&places,q,&result,core.read(worlds),core.read(perceivers if perceivers!=nil else &empty_perceivers),core.read(perceivables if perceivables!=nil else &empty_perceivables),paths_read,core.ref(navigation),core.ref(physics),&filter,&smart,agents_read,influence_of(s,world)) {api.call_fail(call,api.SERVER_ERROR,"no memory for the path search of the query: free memory and ask again");return}
    found:=make([]Place_Result,int(result.count),call.allocator)
    for &place,i in found {
        place={position=result.points[i],score=result.scores[i],offer=int(result.offers[i])}
        if result.entities[i]!=core.NONE {place.entity=id_of(world,result.entities[i])}
    }
    api.call_result(call,Query_Result)^={fmt.tprintf("%v",result.status),found}
}
