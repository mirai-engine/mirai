package behavior_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/ai"
import "mirai:std/base"
import "mirai:std/serial"
import behavior "plugins:behavior/runtime"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

@(storage)
Behavior_Api :: struct {provider:editor.Api_Provider}

BEHAVIOR_API_DEFAULT :: Behavior_Api{provider={register=register}}

Entity_Params :: struct {
    entity:base.Entity_Id,
}

Query_Params :: struct {
    entity:base.Entity_Id `mirai:"label=The querier"`,
    layout:behavior.Place_Layout `mirai:"optional"`,
    around:base.Entity_Id `mirai:"optional,label=Around this entity; omitted: around the querier, or point"`,
    point:[3]f32 `mirai:"optional"`,
    inner:f32 `mirai:"optional,min=0,unit=m"`,
    outer:f32 `mirai:"optional,min=0,unit=m"`,
    rings:u8 `mirai:"optional,min=1,max=16"`,
    per_ring:u8 `mirai:"optional,min=1,max=64"`,
    spacing:f32 `mirai:"optional,min=0.1,unit=m"`,
    entities:[behavior.PLACE_ENTITIES]base.Entity_Id `mirai:"optional,label=The candidates of the layout Entities"`,
    teams:behavior.Teams `mirai:"optional,label=The teams whose Perceivables are the candidates of the layout Perceivables"`,
    use:behavior.Smart_Use `mirai:"optional,label=The use whose offers of smart objects are the candidates of the layout Offers"`,
    from:base.Entity_Id `mirai:"optional,label=Whom the tests measure from; omitted: the querier"`,
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

@(private)
register :: proc(s:^editor.Session) {
    query_defaults:=Query_Params{inner=2,outer=8,rings=3,per_ring=12,spacing=1,keep=5}
    editor.api_method_register(s,{name="behavior.minds",summary="The minds the game ticks (behavior.minds_tick): their names, their actions and how many Mind_Agents of the shown world run each.",flags={.Read_Only},result_schema=`{"type":"object"}`,run=minds})
    editor.api_method_register(s,{name="behavior.inspect",summary="What the mind of a Mind_Agent does and why: the action and the step it runs by name, its stage and since when, its commit, the best proposals of its last decision with their scores, its last exits with their cause and what interrupted them, and what it holds of the claims. Use it in Play to see why an agent decides what it does.",params=Entity_Params,params_info=type_info_of(Entity_Params),flags={.Read_Only},result_schema=`{"type":"object"}`,run=inspect})
    editor.api_method_register(s,{name="behavior.perception",summary="What a Perceiver remembers: each subject it saw or heard, where, by which senses this tick, how sure it still is and since when.",params=Entity_Params,params_info=type_info_of(Entity_Params),flags={.Read_Only},result_schema=`{"type":"object"}`,run=perception})
    editor.api_method_register(s,{name="behavior.offers",summary="The offers of a Smart_Object: each use, where its user stands, who may take it, how many at once, how many times and how often, how many times it was used, when it is offered again and who holds it now.",params=Entity_Params,params_info=type_info_of(Entity_Params),flags={.Read_Only},result_schema=`{"type":"object"}`,run=offers})
    editor.api_method_register(s,{name="behavior.influence",summary="The influence maps at a point of the shown world: the influence of each team there (threat or allies, as an agent reads it) and how covered the point is from 'from'.",params=Influence_Params,params_info=type_info_of(Influence_Params),flags={.Read_Only},result_schema=`{"type":"object"}`,run=influence})
    editor.api_method_register(s,{name="behavior.query",summary="Runs a query of places now, for an agent of the shown world: candidates on rings, a grid or the points of its navigation mesh joined to it (around it, another entity or a point), entities (those given, or the Perceivables of some teams) or the offers of a use of smart objects, kept on its navigation mesh and scored by what is asked (nearer, hidden from, seen by or covered from 'from', reachable, low threat, many allies); returns the best with their scores. What a game asks with behavior.place_query.",params=Query_Params,params_info=type_info_of(Query_Params),defaults=&query_defaults,flags={.Read_Only},result_schema=`{"type":"object"}`,run=query})
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
entity_of :: proc(s:^editor.Session,call:^api.Call,id:base.Entity_Id,$T:typeid,what:string) -> (w:core.World_Ref,e:core.Entity,table:^core.Table(T),ok:bool) {
    w=editor.shown_world(s)
    e=core.entity_of(core.world_entities(w),id)
    table=core.world_table_of(w,T)
    if e==core.NONE || table==nil || !core.has(core.read(table),e) {
        api.call_failf(call,api.INVALID_PARAMS,"%x is not an entity with a %s in the shown world",id,what)
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
    if ids:=core.world_table_of(world,core.Id);ids!=nil {if value,has:=core.get(core.read(ids),e);has {return value.value}}
    return 0
}

@(private)
minds :: proc(s:^editor.Session,call:^api.Call) {
    registry:=minds_of(s)
    w:=call.out
    serial.text_write_raw(w,`{"minds":[`)
    if registry!=nil {
        agents:=core.world_table_of(editor.shown_world(s),behavior.Mind_Agent)
        for &entry,i in registry.entries[:clamp(registry.count,0,behavior.MINDS_CAPACITY)] {
            running:=0
            if agents!=nil {for agent in agents.values[:core.count(agents)] {if agent.mind==entry.name {running+=1}}}
            if i>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            api.write_text(w,"name",name_text(entry.name),true)
            api.write_key(w,"actions")
            serial.text_write_raw(w,"[")
            listed:=0
            for k in 0..<ai.MIND_ACTIONS {
                name:=behavior.mind_action_name(&entry,u16(k))
                if name=="" {continue}
                if listed>0 {serial.text_write_raw(w,",")}
                serial.text_write_string(w,name)
                listed+=1
            }
            serial.text_write_raw(w,"]")
            api.write_int(w,"agents",i64(running))
            serial.text_write_raw(w,"}")
        }
    }
    serial.text_write_raw(w,"]}")
}

@(private)
inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    world,_,agents,ok:=entity_of(s,call,p.entity,behavior.Mind_Agent,"Mind_Agent")
    if !ok {return}
    agent:=&agents.values[core.row_of(agents,core.entity_of(core.world_entities(world),p.entity))]
    entry:=behavior.mind_of(minds_of(s),agent.mind)
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"mind",name_text(agent.mind),true)
    if entry==nil {
        api.write_text(w,"note","no mind is registered by this name: the game ticks it with behavior.minds_tick, which registers it")
        serial.text_write_raw(w,"}")
        return
    }
    m:=&agent.state
    now:f64
    if t:=core.world_storage_of(world,core.Time);t!=nil {now=t.seconds}
    api.write_uint(w,"ticks",u64(m.ticks))
    action,step:=ai.mind_running(m)
    frame_write :: proc(w:^serial.Writer,world:core.World_Ref,key:string,entry:^behavior.Mind_Entry,action:u16,frame:^ai.Act_Frame,now:f64) {
        api.write_key(w,key)
        if action==ai.MIND_NONE {serial.text_write_raw(w,"null");return}
        serial.text_write_raw(w,"{")
        api.write_text(w,"action",action_name(entry,action),true)
        api.write_int(w,"stage",i64(frame.stage))
        api.write_key(w,"seconds");api.write_number(w,f32(now-frame.entered))
        api.write_key(w,"stage_seconds");api.write_number(w,f32(now-frame.staged))
        if frame.reserved.target!=0 {
            api.write_key(w,"holds")
            serial.text_write_raw(w,"{")
            api.write_key(w,"target",true);api.write_id(w,id_of(world,core.Entity(frame.reserved.target)))
            api.write_int(w,"what",i64(frame.reserved.what))
            serial.text_write_raw(w,"}")
        }
        serial.text_write_raw(w,"}")
    }
    frame_write(w,world,"running",entry,action,&m.main,now)
    frame_write(w,world,"step",entry,step,&m.step,now)
    api.write_key(w,"score");api.write_number(w,m.score)
    api.write_key(w,"commit");api.write_number(w,m.commit)
    api.write_key(w,"proposals")
    serial.text_write_raw(w,"[")
    for proposal,i in m.proposals {
        if !(proposal.score>0) {break}
        if i>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_text(w,"action",action_name(entry,proposal.action),true)
        api.write_key(w,"score");api.write_number(w,proposal.score)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"exits")
    serial.text_write_raw(w,"[")
    for back in 0..<ai.MIND_TRACE {
        exit,found:=ai.mind_exit_trace(m,back)
        if !found {break}
        if back>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_text(w,"action",action_name(entry,exit.action),true)
        api.write_text(w,"cause",fmt.tprintf("%v",exit.cause))
        if exit.by!=ai.MIND_NONE {api.write_text(w,"interrupted_by",action_name(entry,exit.by))}
        api.write_bool(w,"step",exit.step)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]}")
}

@(private)
perception :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    world,e,_,ok:=entity_of(s,call,p.entity,behavior.Perceiver,"Perceiver")
    if !ok {return}
    w:=call.out
    serial.text_write_raw(w,`{"remembers":[`)
    perceptions:=core.world_table_of(world,behavior.Perception)
    if perceptions!=nil {
        if mine,found:=core.get(core.read(perceptions),e);found {
            for o,i in mine.memory.items[:clamp(mine.memory.count,0,ai.PERCEPTION_CAPACITY)] {
                if i>0 {serial.text_write_raw(w,",")}
                serial.text_write_raw(w,"{")
                api.write_key(w,"subject",true)
                api.write_id(w,id_of(world,core.Entity(o.subject)))
                api.write_numbers(w,"position",o.position)
                api.write_text(w,"senses",fmt.tprintf("%v",o.senses))
                api.write_key(w,"confidence");api.write_number(w,o.confidence)
                api.write_key(w,"since");api.write_number(w,f32(o.first))
                api.write_key(w,"last");api.write_number(w,f32(o.last))
                serial.text_write_raw(w,"}")
            }
        }
    }
    serial.text_write_raw(w,"]}")
}

@(private)
offers :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    world,e,objects,ok:=entity_of(s,call,p.entity,behavior.Smart_Object,"Smart_Object")
    if !ok {return}
    object,_:=core.get(core.read(objects),e)
    state:behavior.Smart_State
    if states:=core.world_table_of(world,behavior.Smart_State);states!=nil {state,_=core.get(core.read(states),e)}
    claims:=core.world_storage_of(world,behavior.Claims)
    tick:u64
    if t:=core.world_storage_of(world,core.Time);t!=nil {tick=t.tick}
    w:=call.out
    serial.text_write_raw(w,`{"offers":[`)
    first:=true
    for offer,i in object.offers {
        if offer.use==behavior.USE_NONE {continue}
        if !first {serial.text_write_raw(w,",")}
        first=false
        serial.text_write_raw(w,"{")
        api.write_int(w,"offer",i64(i),true)
        api.write_int(w,"use",i64(offer.use))
        api.write_numbers(w,"at",offer.at)
        api.write_int(w,"users",i64(max(offer.users,1)))
        api.write_int(w,"uses",i64(offer.uses))
        api.write_int(w,"used",i64(state.used[i]))
        api.write_key(w,"cooldown");api.write_number(w,offer.cooldown)
        api.write_key(w,"ready");api.write_number(w,f32(state.ready[i]))
        if claims!=nil {
            api.write_int(w,"held",i64(ai.reserve_count(&claims.reservations,{u64(e),u16(i+1)},tick)))
        }
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]}")
}

@(private)
influence :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Influence_Params)
    world:=editor.shown_world(s)
    maps:=influence_of(s,world)
    w:=call.out
    serial.text_write_raw(w,"{")
    if maps==nil || !ai.influence_ready(&maps.grid) {
        api.write_text(w,"note","no influence maps: they are made in Play or Simulate, when Behavior_Settings.influence_cell is above 0",true)
        serial.text_write_raw(w,"}")
        return
    }
    if _,inside:=ai.influence_cell(&maps.grid,p.point);!inside {
        api.write_text(w,"note","the point is outside the influence maps: move Behavior_Settings.influence_center or grow influence_size",true)
        serial.text_write_raw(w,"}")
        return
    }
    values:[behavior.INFLUENCE_TEAMS]f32
    for &v,team in values {v=behavior.influence_at(maps,p.point,behavior.Teams(1<<u32(team)))}
    api.write_numbers(w,"teams",values[:],true)
    api.write_key(w,"cover");api.write_number(w,behavior.cover_at(maps,p.point,p.from))
    api.write_uint(w,"passes",maps.grid.passes)
    serial.text_write_raw(w,"}")
}

@(private)
query :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Query_Params)
    world,e,_,ok:=entity_of(s,call,p.entity,core.World_Transform,"place in the world")
    if !ok {return}
    entities:=core.world_entities(world)
    q:=behavior.Place_Query{querier=e,layout=p.layout,inner=p.inner,outer=max(p.outer,p.inner),rings=p.rings,per_ring=p.per_ring,spacing=p.spacing,teams=p.teams,use=p.use,keep=p.keep}
    for id in p.entities {
        if id==0 {continue}
        candidate:=core.entity_of(entities,id)
        if candidate==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"entities: %x is not an entity of the shown world",id);return}
        q.entities[q.entity_count]=candidate
        q.entity_count+=1
    }
    switch {
    case p.around!=0:
        q.center,q.target=.Target,core.entity_of(entities,p.around)
        if q.target==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"around %x is not an entity of the shown world",p.around);return}
    case p.point!={}:
        q.center,q.point=.Point,p.point
    }
    from:=behavior.Place_Context.Querier
    from_entity:=core.NONE
    if p.from!=0 {
        from_entity=core.entity_of(entities,p.from)
        if from_entity==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"from %x is not an entity of the shown world",p.from);return}
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
    smart:=behavior.Smart_View{objects=core.read(objects if objects!=nil else &empty_objects),states=core.read(states if states!=nil else &empty_states),worlds=core.read(worlds),claims=core.world_storage_of(world,behavior.Claims),time=time.seconds,tick=time.tick}
    filter:=behavior.place_filter(core.ref(navigation),e,paths_read,agents_read,core.read(walks if walks!=nil else &empty_walks),core.read(swims if swims!=nil else &empty_swims),core.ref(physics))
    behavior.place_run(&places,q,&result,core.read(worlds),core.read(perceivers if perceivers!=nil else &empty_perceivers),core.read(perceivables if perceivables!=nil else &empty_perceivables),paths_read,core.ref(navigation),core.ref(physics),&filter,&smart,agents_read,influence_of(s,world))
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"status",fmt.tprintf("%v",result.status),true)
    api.write_key(w,"places")
    serial.text_write_raw(w,"[")
    for i in 0..<int(result.count) {
        if i>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_numbers(w,"position",result.points[i],true)
        api.write_key(w,"score");api.write_number(w,result.scores[i])
        if result.entities[i]!=core.NONE {
            api.write_key(w,"entity");api.write_id(w,id_of(world,result.entities[i]))
        }
        if result.offers[i]>=0 {api.write_int(w,"offer",i64(result.offers[i]))}
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]}")
}
