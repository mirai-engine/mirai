package behavior

import "base:runtime"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:std/ai"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// Counts what is asked of it and gives nothing: a tick that must not allocate runs with it.
@(private="file")
refusing_allocator :: proc(calls:^int) -> runtime.Allocator {
    return {procedure=proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        if mode==.Query_Features || mode==.Query_Info {return nil,.Mode_Not_Implemented}
        (^int)(data)^+=1
        return nil,.Out_Of_Memory
    },data=calls}
}

// Serves the requests left in served from the allocator of the test and refuses the rest.
@(private="file")
serving_allocator :: proc(served:^int,owner:runtime.Allocator) -> runtime.Allocator {
    Serving :: struct {served:^int,owner:runtime.Allocator}
    serving:=new(Serving,context.temp_allocator)
    serving^={served,owner}
    return {procedure=proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        serving:=(^Serving)(data)
        if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
            if serving.served^<=0 {return nil,.Out_Of_Memory}
            serving.served^-=1
        }
        return serving.owner.procedure(serving.owner.data,mode,size,alignment,old_memory,old_size,loc)
    },data=serving}
}

@(private="file")
Count_Act :: enum u8 {Count}

@(private="file")
Counting :: struct {
    w:Act_World,
    near,far,entered:int,
}

@(private="file")
counting_think :: proc(t:^ai.Think(Count_Act)) {ai.propose(t,.Count,1)}

// Counts its entries, near and far, asks to look and for an animation, and
// ends on its first Update.
@(private="file")
counting_act :: proc(a:^ai.Act(Count_Act)) -> ai.Status {
    c:=(^Counting)(a.user)
    if a.phase!=.Enter {return .Success}
    c.entered+=1
    if c.w.far {c.far+=1} else {c.near+=1}
    present_look(&c.w,core.NONE,{1,2,3})
    present_animation(&c.w,9)
    return .Running
}

@(private="file")
COUNTING_ACTS := [Count_Act]proc(a:^ai.Act(Count_Act)) -> ai.Status{.Count=counting_act}

// A mind registers by name when its agents tick, after its check: every
// action has a procedure and there is a think procedure; one that does not
// is a problem that says what to fix, and so are agents of a name nobody
// ticks.
@(test)
minds_register_by_name_check_and_tick_their_agents :: proc(t:^testing.T) {
    minds:=new(Minds)
    defer free(minds)
    missing:=[Count_Act]proc(a:^ai.Act(Count_Act)) -> ai.Status{}
    Case :: struct{name:string,acts:^[Count_Act]proc(a:^ai.Act(Count_Act)) -> ai.Status,think:proc(t:^ai.Think(Count_Act)),problem:Mind_Problem}
    cases:=[?]Case{
        {"counter",&COUNTING_ACTS,counting_think,.None},
        {"counter",&COUNTING_ACTS,counting_think,.None},
        {"",&COUNTING_ACTS,counting_think,.Name},
        {"a name far too long for a mind",&COUNTING_ACTS,counting_think,.Name},
        {"broken",&missing,counting_think,.Missing_Action},
        {"thoughtless",&COUNTING_ACTS,nil,.No_Think},
    }
    for c in cases {
        problem,_:=mind_register(minds,c.name,c.acts,c.think)
        testing.expectf(t,problem==c.problem,"%q: %v, expected %v",c.name,problem,c.problem)
        testing.expect(t,c.problem==.None || mind_problem_text(c.problem)!="")
    }
    testing.expect(t,minds.count==1 && mind_of(minds,mind_name("counter")).actions==Count_Act && mind_of(minds,mind_name("other"))==nil)
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    agents:core.Table(Mind_Agent)
    core.table_init(&agents,"Mind_Agent")
    defer core.table_destroy(&agents)
    a,b,lost:=core.create(&es),core.create(&es),core.create(&es)
    core.add(&agents,a,Mind_Agent{mind=mind_name("counter")})
    core.add(&agents,b,Mind_Agent{mind=mind_name("counter")})
    core.add(&agents,lost,Mind_Agent{mind=mind_name("nobody")})
    core.table_settle(&agents,&es)
    c:Counting
    ctx:=ai.Mind_Context{user=&c}
    problems:core.Problems
    minds_tick(minds,&agents,"counter",&COUNTING_ACTS,counting_think,&ctx,&c.w,{tick=1,dt=1.0/60,playing=true},&problems)
    testing.expect(t,c.entered==2 && c.w.entity==b && ctx.holder==u64(b))
    minds_tick(minds,&agents,"broken",&missing,counting_think,&ctx,&c.w,{tick=1,dt=1.0/60,playing=true},&problems)
    testing.expect(t,core.problem_find(&problems,core.NONE,"behavior.mind")!=nil)
    minds_unknown(minds,&agents,&problems)
    testing.expect(t,core.problem_find(&problems,lost,"behavior.mind")!=nil && core.problem_find(&problems,a,"behavior.mind")==nil)
}

// What a mind does shows in the Mind_Presentation of its agent, which it
// gets before its first tick and whose row is written only when it changes;
// a tick that runs again decides nothing.
@(test)
the_mind_of_an_agent_presents_what_it_does_and_does_not_tick_again_in_a_resimulation :: proc(t:^testing.T) {
    minds:=new(Minds)
    defer free(minds)
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    agents:core.Table(Mind_Agent)
    shows:core.Table(Mind_Presentation)
    core.table_init(&agents,"Mind_Agent");defer core.table_destroy(&agents)
    core.table_init(&shows,"Mind_Presentation");defer core.table_destroy(&shows)
    e:=core.create(&es)
    core.add(&agents,e,Mind_Agent{mind=mind_name("hunter")})
    core.table_settle(&agents,&es)
    c:Counting
    c.w.presentations=&shows
    ctx:=ai.Mind_Context{user=&c}
    problems:core.Problems
    minds_tick(minds,&agents,"hunter",&COUNTING_ACTS,counting_think,&ctx,&c.w,{tick=1,dt=1.0/60,playing=true},&problems)
    core.table_settle(&shows,&es)
    shown,found:=core.get(core.read(&shows),e)
    testing.expect(t,found && c.entered==1)
    testing.expect(t,shown.action==u16(Count_Act.Count) && shown.step==ai.MIND_NONE)
    testing.expect(t,shown.look==core.NONE && shown.look_point=={1,2,3} && shown.animation==9 && shown.animations==1)
    // It ends and enters again: the same action, a new animation asked.
    minds_tick(minds,&agents,"hunter",&COUNTING_ACTS,counting_think,&ctx,&c.w,{tick=2,dt=1.0/60,playing=true},&problems)
    core.table_settle(&shows,&es)
    shown,_=core.get(core.read(&shows),e)
    testing.expect(t,c.entered==2 && shown.animations==2)
    version:=core.version(core.read(&shows))
    ticks:=agents.values[0].state.ticks
    // A tick that runs again (a rollback) neither ticks nor presents.
    minds_tick(minds,&agents,"hunter",&COUNTING_ACTS,counting_think,&ctx,&c.w,{tick=3,dt=1.0/60,playing=true,resimulating=true},&problems)
    testing.expect_value(t,agents.values[0].state.ticks,ticks)
    testing.expect_value(t,core.version(core.read(&shows)),version)
    c.w.entity=e
    present_look(&c.w,e)
    core.table_settle(&shows,&es)
    shown,_=core.get(core.read(&shows),e)
    testing.expect(t,shown.look==e && shown.look_point=={})
    testing.expect_value(t,problems.count,0)
}

// An agent far from the players is off with its rows, and its mind decides
// on, at the steps of what is far, holding what it claims until its next
// tick; its move actions read where navigation took it.
@(test)
the_mind_of_an_agent_far_ticks_at_the_steps_of_what_is_far :: proc(t:^testing.T) {
    minds:=new(Minds)
    defer free(minds)
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    agents:core.Table(Mind_Agent)
    paths:core.Table(nav.Nav_Path)
    fars:core.Table(nav.Nav_Far)
    core.table_init(&agents,"Mind_Agent");defer core.table_destroy(&agents)
    core.table_init(&paths,"Nav_Path");defer core.table_destroy(&paths)
    core.table_init(&fars,"Nav_Far");defer core.table_destroy(&fars)
    near,far,dormant:=core.create(&es),core.create(&es),core.create(&es)
    for e in ([3]core.Entity{near,far,dormant}) {
        core.add(&agents,e,Mind_Agent{mind=mind_name("counter")})
        core.add(&paths,e,nav.Nav_Path{state=.Arrived,class=-1})
    }
    core.add(&fars,far,nav.Nav_Far{arrived=true})
    core.table_settle(&agents,&es);core.table_settle(&paths,&es);core.table_settle(&fars,&es)
    // Off: the far one as navigation leaves it, the dormant one as a section that sleeps.
    for e in ([2]core.Entity{far,dormant}) {core.disable(&agents,e);core.disable(&paths,e)}
    core.disable(&fars,far)
    core.table_settle(&agents,&es);core.table_settle(&paths,&es);core.table_settle(&fars,&es)
    c:Counting
    c.w.paths,c.w.fars=core.read(&paths),core.read(&fars)
    claims:Claims
    ctx:=ai.Mind_Context{user=&c,reservations=&claims.reservations}
    problems:core.Problems
    calls:=0
    for tick in u64(0)..<60 {
        // Its ticks after the first, which registers the mind, do not allocate.
        saved:=context.allocator
        if tick>0 {context.allocator=refusing_allocator(&calls)}
        minds_tick(minds,&agents,"counter",&COUNTING_ACTS,counting_think,&ctx,&c.w,{tick=tick,dt=1.0/60,seconds=f64(tick)/60,playing=true},&problems)
        context.allocator=saved
    }
    testing.expect_value(t,calls,0)
    testing.expect_value(t,c.near,60)
    testing.expect_value(t,c.far,2)
    testing.expect(t,!c.w.far && ctx.lease==1)
    // Its actions read its path, off as it is: navigation says it arrived.
    c.w.entity,c.w.far=far,true
    testing.expect_value(t,path_status(&c.w),ai.Status.Success)
    testing.expect_value(t,agents.values[core.raw_row(core.raw(&agents),dormant)].state.ticks,0)
    testing.expect_value(t,problems.count,0)
    // What a far agent claims lasts until its next decision, half a second later.
    a:=ai.Act(Count_Act){ctx=&ctx,frame=&agents.values[0].state.main}
    ctx.tick,ctx.holder,ctx.lease=100,u64(far),31
    testing.expect(t,ai.claim(&a,7,1,1))
    testing.expect(t,!ai.reserve_open(&claims.reservations,{7,1},u64(near),1,130) && ai.reserve_open(&claims.reservations,{7,1},u64(near),1,132))
}

@(private="file")
Move_Act :: enum u8 {Move}

@(test)
move_actions_ask_navigation_and_read_where_the_agent_got :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    paths:core.Table(nav.Nav_Path)
    core.table_init(&paths,"Nav_Path")
    defer core.table_destroy(&paths)
    requests:nav.Nav_Requests
    defer delete(requests.queue.items)
    e:=core.create(&es)
    core.add(&paths,e,nav.Nav_Path{state=.Waiting})
    core.table_settle(&paths,&es)
    w:=Act_World{entity=e,requests=&requests,paths=core.read(&paths)}
    a:=ai.Act(Move_Act){phase=.Enter}
    testing.expect_value(t,move_act(&w,&a,{1,2,3}),ai.Status.Running)
    testing.expect(t,len(requests.queue.items)==1 && requests.queue.items[0].kind==.Move_To && requests.queue.items[0].point=={1,2,3})
    a.phase=.Update
    testing.expect_value(t,move_act(&w,&a,{}),ai.Status.Running)
    core.get(&paths,e).state=.Arrived
    testing.expect_value(t,move_act(&w,&a,{}),ai.Status.Success)
    core.get(&paths,e).partial=true
    testing.expect_value(t,path_status(&w),ai.Status.Failure)
    a.phase,a.cause=.Exit,.Aborted
    move_act(&w,&a,{})
    testing.expect(t,requests.queue.items[len(requests.queue.items)-1].kind==.Stop)
    core.get(&paths,e).state=.Failed
    a.phase=.Update
    testing.expect_value(t,follow_act(&w,&a,e,1),ai.Status.Failure)
}

@(private="file")
Sight_Test :: struct {
    es:core.Entities,
    perceivers:core.Table(Perceiver),
    perceptions:core.Table(Perception),
    perceivables:core.Table(Perceivable),
    worlds:core.Table(core.World_Transform),
    turns:Perceiving,
    noises:Noises,
    events:Perception_Events,
    settings:Behavior_Settings,
    physics:phys.Physics_State,
}

@(private="file")
sight_init :: proc(f:^Sight_Test) {
    core.entities_init(&f.es)
    core.table_init(&f.perceivers,"Perceiver")
    core.table_init(&f.perceptions,"Perception")
    core.table_init(&f.perceivables,"Perceivable")
    core.table_init(&f.worlds,"World_Transform")
    f.settings=BEHAVIOR_SETTINGS_DEFAULT
}

@(private="file")
sight_destroy :: proc(f:^Sight_Test) {
    core.table_destroy(&f.perceivers);core.table_destroy(&f.perceptions);core.table_destroy(&f.perceivables);core.table_destroy(&f.worlds)
    delete(f.noises.queue.items);delete(f.events.queue.items)
    core.entities_destroy(&f.es)
}

@(private="file")
sight_tick :: proc(f:^Sight_Test,seconds:f64) {
    core.table_settle(&f.perceivers,&f.es);core.table_settle(&f.perceptions,&f.es);core.table_settle(&f.perceivables,&f.es);core.table_settle(&f.worlds,&f.es)
    perception_update(core.read(&f.perceivers),&f.perceptions,core.read(&f.perceivables),core.read(&f.worlds),core.ref(&f.settings),&f.turns,&f.noises,&f.events,core.ref(&f.physics),{},core.ref(&f.es),{seconds=seconds,dt=1.0/60,playing=true})
    core.table_settle(&f.perceptions,&f.es)
}

@(private="file")
placed :: proc(f:^Sight_Test,position:mm.Vec3) -> core.Entity {
    e:=core.create(&f.es)
    core.add(&f.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale=1}})
    return e
}

@(test)
perceivers_see_the_teams_they_notice_in_their_cone_hear_noises_and_forget :: proc(t:^testing.T) {
    f:Sight_Test
    sight_init(&f)
    defer sight_destroy(&f)
    // A guard at the origin looking down -Z (its front), noticing team 1.
    guard:=placed(&f,{})
    watch:=PERCEIVER_DEFAULT
    watch.notices=Teams(1<<1)
    watch.forget=2
    core.add(&f.perceivers,guard,watch)
    ahead:=placed(&f,{0,0,-5})
    core.add(&f.perceivables,ahead,Perceivable{team=1,point=1})
    friend:=placed(&f,{1,0,-5})
    core.add(&f.perceivables,friend,Perceivable{team=2,point=1})
    behind:=placed(&f,{0,0,5})
    core.add(&f.perceivables,behind,Perceivable{team=1,point=1})
    sight_tick(&f,0) // gives the guard its Perception
    sight_tick(&f,0.1)
    mine:=core.get(&f.perceptions,guard)
    testing.expect(t,mine!=nil && mine.memory.count==1 && ai.memory_find(&mine.memory,u64(ahead))!=nil)
    testing.expect(t,len(f.events.queue.items)==1 && f.events.queue.items[0].kind==.Noticed && f.events.queue.items[0].subject==ahead)
    // A noise behind it is heard; out of hearing, not.
    noise(&f.noises,{0,0,4},10,behind)
    noise(&f.noises,{0,0,40},10,friend)
    sight_tick(&f,0.2)
    mine=core.get(&f.perceptions,guard)
    heard:=ai.memory_find(&mine.memory,u64(behind))
    testing.expect(t,heard!=nil && heard.senses=={.Hearing} && ai.memory_find(&mine.memory,u64(friend))==nil)
    // What it no longer perceives is forgotten after `forget` seconds.
    core.get(&f.worlds,ahead).position={0,0,-50}
    sight_tick(&f,1.2)
    sight_tick(&f,2.5)
    mine=core.get(&f.perceptions,guard)
    testing.expect(t,ai.memory_find(&mine.memory,u64(behind))==nil)
    forgot:=false
    for event in f.events.queue.items {forgot|=event.kind==.Forgot && event.subject==behind}
    testing.expect(t,forgot)
}

// A subject remembered and then destroyed is forgotten at once, with its
// event; its handle is not taken for the entity that reuses its slot, and a
// noise remembered without a maker stays.
@(test)
a_remembered_subject_that_is_destroyed_is_forgotten_at_once :: proc(t:^testing.T) {
    f:Sight_Test
    sight_init(&f)
    defer sight_destroy(&f)
    guard:=placed(&f,{})
    watch:=PERCEIVER_DEFAULT
    watch.forget=100
    core.add(&f.perceivers,guard,watch)
    seen:=placed(&f,{0,0,-5})
    core.add(&f.perceivables,seen,Perceivable{point=1})
    sight_tick(&f,0)
    noise(&f.noises,{3,0,0},10)
    sight_tick(&f,0.1)
    mine:=core.get(&f.perceptions,guard)
    testing.expect(t,mine!=nil && ai.memory_find(&mine.memory,u64(seen))!=nil && ai.memory_find(&mine.memory,0)!=nil)
    core.destroy(&f.es,seen)
    core.table_settle(&f.perceivables,&f.es);core.table_settle(&f.worlds,&f.es)
    core.entities_settle(&f.es)
    again:=placed(&f,{0,0,-50})
    sight_tick(&f,0.2)
    mine=core.get(&f.perceptions,guard)
    testing.expect(t,ai.memory_find(&mine.memory,u64(seen))==nil,"the destroyed subject is forgotten")
    testing.expect(t,ai.memory_find(&mine.memory,u64(again))==nil)
    testing.expect(t,ai.memory_find(&mine.memory,0)!=nil,"the place of a noise without a maker stays")
    forgot:=false
    for event in f.events.queue.items {forgot|=event.kind==.Forgot && event.subject==seen}
    testing.expect(t,forgot)
}

@(test)
sight_shares_its_rays_among_perceivers_in_turns :: proc(t:^testing.T) {
    f:Sight_Test
    sight_init(&f)
    defer sight_destroy(&f)
    f.settings.rays=1
    guards:[3]core.Entity
    for &g,i in guards {
        g=placed(&f,{f32(i)*2,0,0})
        core.add(&f.perceivers,g,PERCEIVER_DEFAULT)
    }
    target:=placed(&f,{2,0,-6})
    core.add(&f.perceivables,target,Perceivable{point=1})
    sight_tick(&f,0)
    for tick in 1..=3 {sight_tick(&f,f64(tick)*0.1)}
    for g in guards {
        mine:=core.get(&f.perceptions,g)
        testing.expect(t,mine!=nil && ai.memory_find(&mine.memory,u64(target))!=nil)
    }
}

@(test)
every_perceiver_gets_its_turn_and_forgets_only_in_it :: proc(t:^testing.T) {
    f:Sight_Test
    sight_init(&f)
    defer sight_destroy(&f)
    f.settings.rays=1
    guards:[4]core.Entity
    for &g,i in guards {
        g=placed(&f,{f32(i)*2,0,0})
        watch:=PERCEIVER_DEFAULT
        watch.forget=1
        core.add(&f.perceivers,g,watch)
    }
    target:=placed(&f,{3,0,-6})
    core.add(&f.perceivables,target,Perceivable{point=1})
    sight_tick(&f,0)
    for tick in 1..=4 {sight_tick(&f,f64(tick)*0.1)}
    for g in guards {
        mine:=core.get(&f.perceptions,g)
        testing.expect(t,mine!=nil && ai.memory_find(&mine.memory,u64(target))!=nil)
    }
    // Long after a subject was perceived, only the one whose turn it is forgets it.
    ghost:=u64(1<<40)
    for g in guards {ai.memory_perceive(&core.get(&f.perceptions,g).memory,ghost,{},.Sight,1,0)}
    sight_tick(&f,5)
    forgot:=0
    for g in guards {if ai.memory_find(&core.get(&f.perceptions,g).memory,ghost)==nil {forgot+=1}}
    testing.expect_value(t,forgot,1)
}

@(test)
places_are_answered_in_order_within_the_budget :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    worlds:core.Table(core.World_Transform)
    results:core.Table(Place_Result)
    perceivers:core.Table(Perceiver)
    paths:core.Table(nav.Nav_Path)
    agents:core.Table(nav.Nav_Agent)
    walks:core.Table(phys.Walk)
    swims:core.Table(phys.Swim)
    core.table_init(&worlds,"World_Transform");core.table_init(&results,"Place_Result");core.table_init(&perceivers,"Perceiver");core.table_init(&paths,"Nav_Path")
    core.table_init(&agents,"Nav_Agent");core.table_init(&walks,"Walk");core.table_init(&swims,"Swim")
    defer {core.table_destroy(&worlds);core.table_destroy(&results);core.table_destroy(&perceivers);core.table_destroy(&paths);core.table_destroy(&agents);core.table_destroy(&walks);core.table_destroy(&swims)}
    a,b:=core.create(&es),core.create(&es)
    core.add(&worlds,a,core.World_Transform{transform={position={0,0,0},rotation=1,scale=1}})
    core.add(&worlds,b,core.World_Transform{transform={position={10,0,0},rotation=1,scale=1}})
    core.table_settle(&worlds,&es)
    requests:Place_Requests
    places:Places
    defer {delete(requests.queue.items);places_free(&places)}
    settings:=Behavior_Settings{queries=1}
    // Near the point (3,0,0): of a grid around the querier, the best is that point.
    q:=Place_Query{querier=a,center=.Querier,layout=.Grid,outer=4,spacing=1,keep=3}
    q.tests[0]={measure=.Distance,from=.Point,point={3,0,0},min=0,max=8,response={kind=.Linear,slope=-1,shift_y=1}}
    q.test_count=1
    place_query(&requests,q)
    q.querier=b
    place_query(&requests,q)
    navigation:nav.Navigation
    physics:phys.Physics_State
    problems:core.Problems
    places_run(&requests,&places,&results,core.ref(&settings),core.read(&worlds),core.read(&perceivers),{},core.read(&paths),core.read(&agents),core.read(&walks),core.read(&swims),core.ref(&navigation),core.ref(&physics),{},{},nil,{},{},&problems)
    core.table_settle(&results,&es)
    first,_:=core.get(core.read(&results),a)
    second,_:=core.get(core.read(&results),b)
    testing.expect(t,first.status==.Found && first.request==1 && first.count==3 && first.points[0]=={3,0,0} && first.scores[0]>=first.scores[1])
    testing.expect(t,second.status==.Waiting && second.request==2)
    places_run(&requests,&places,&results,core.ref(&settings),core.read(&worlds),core.read(&perceivers),{},core.read(&paths),core.read(&agents),core.read(&walks),core.read(&swims),core.ref(&navigation),core.ref(&physics),{},{},nil,{},{},&problems)
    second,_=core.get(core.read(&results),b)
    testing.expect(t,second.status==.Found && linalg.distance(second.points[0],mm.Vec3{6,0,0})<1e-4)
    // Of two queries of one querier, the last one is answered and the first does not take its place.
    q.querier=a
    place_query(&requests,q)
    place_query(&requests,q)
    places_run(&requests,&places,&results,core.ref(&settings),core.read(&worlds),core.read(&perceivers),{},core.read(&paths),core.read(&agents),core.read(&walks),core.read(&swims),core.ref(&navigation),core.ref(&physics),{},{},nil,{},{},&problems)
    first,_=core.get(core.read(&results),a)
    testing.expect(t,first.status==.Found && first.request==4)
}

@(private="file")
Places_Test :: struct {
    es:core.Entities,
    worlds:core.Table(core.World_Transform),
    results:core.Table(Place_Result),
    perceivers:core.Table(Perceiver),
    paths:core.Table(nav.Nav_Path),
    agents:core.Table(nav.Nav_Agent),
    walks:core.Table(phys.Walk),
    swims:core.Table(phys.Swim),
    requests:Place_Requests,
    places:Places,
    settings:Behavior_Settings,
    navigation:nav.Navigation,
    physics:phys.Physics_State,
    objects:core.Table(Smart_Object),
    states:core.Table(Smart_State),
    claims:Claims,
    problems:core.Problems,
}

// A query around a target, or measured from it, finds nothing once the
// target is destroyed, and the query of a querier destroyed while it waits
// takes nothing of the budget and gets no answer.
@(test)
places_of_a_target_that_is_destroyed_are_none :: proc(t:^testing.T) {
    f:Places_Test
    core.entities_init(&f.es)
    core.table_init(&f.worlds,"World_Transform");core.table_init(&f.results,"Place_Result");core.table_init(&f.perceivers,"Perceiver");core.table_init(&f.paths,"Nav_Path")
    core.table_init(&f.agents,"Nav_Agent");core.table_init(&f.walks,"Walk");core.table_init(&f.swims,"Swim")
    defer {
        core.table_destroy(&f.worlds);core.table_destroy(&f.results);core.table_destroy(&f.perceivers);core.table_destroy(&f.paths);core.table_destroy(&f.agents);core.table_destroy(&f.walks);core.table_destroy(&f.swims)
        delete(f.requests.queue.items);places_free(&f.places)
        core.entities_destroy(&f.es)
    }
    querier,target,gone:=core.create(&f.es),core.create(&f.es),core.create(&f.es)
    for e,i in ([]core.Entity{querier,target,gone}) {core.add(&f.worlds,e,core.World_Transform{transform={position={f32(i)*5,0,0},rotation=1,scale=1}})}
    core.table_settle(&f.worlds,&f.es)
    f.settings=Behavior_Settings{queries=1}
    around:=Place_Query{querier=querier,center=.Target,target=target,layout=.Grid,outer=2,spacing=1,keep=1}
    around.tests[0]={measure=.Distance,from=.Querier,min=0,max=10,response={kind=.Linear,slope=-1,shift_y=1}}
    around.test_count=1
    from:=Place_Query{querier=querier,center=.Querier,layout=.Grid,outer=2,spacing=1,keep=1}
    from.tests[0]={measure=.Distance,from=.Target,target=target,min=0,max=10,response={kind=.Linear,slope=-1,shift_y=1}}
    from.test_count=1
    orphan:=Place_Query{querier=gone,center=.Querier,layout=.Grid,outer=2,spacing=1,keep=1}
    run :: proc(f:^Places_Test) {
        places_run(&f.requests,&f.places,&f.results,core.ref(&f.settings),core.read(&f.worlds),core.read(&f.perceivers),{},core.read(&f.paths),
            core.read(&f.agents),core.read(&f.walks),core.read(&f.swims),core.ref(&f.navigation),core.ref(&f.physics),core.read(&f.objects),core.read(&f.states),&f.claims,{},{},&f.problems)
        core.table_settle(&f.results,&f.es)
    }
    place_query(&f.requests,around)
    run(&f)
    result,_:=core.get(core.read(&f.results),querier)
    testing.expect(t,result.status==.Found && result.request==1,"around the target while it is there")
    core.destroy(&f.es,target)
    core.destroy(&f.es,gone)
    core.table_settle(&f.worlds,&f.es)
    core.entities_settle(&f.es)
    place_query(&f.requests,orphan)
    place_query(&f.requests,around)
    run(&f)
    result,_=core.get(core.read(&f.results),querier)
    testing.expectf(t,result.request==3 && result.status==.Empty,"around a target that is gone: %v",result)
    place_query(&f.requests,from)
    run(&f)
    result,_=core.get(core.read(&f.results),querier)
    testing.expectf(t,result.request==4 && result.status==.Empty,"measured from a target that is gone: %v",result)
    testing.expect_value(t,len(f.places.waiting),0)
    testing.expect_value(t,core.count(&f.results),1)
}

@(test)
the_path_of_places_walks_only_what_the_querier_walks :: proc(t:^testing.T) {
    navigation:nav.Navigation
    defer nav.navigation_free(&navigation)
    navigation.classes[0].class=nav.NAVIGATION_SETTINGS_DEFAULT.classes[0]
    navigation.count,navigation.ready=1,true
    mesh:=&navigation.classes[0].mesh
    testing.expect(t,ai.nav_mesh_init(mesh,{tile_width=8,climb=0.3,max_tiles=1}))
    // A square of ground whose half beyond x=4 is under deep water.
    vertices:=[]mm.Vec3{{0,0,0},{4,0,0},{8,0,0},{0,0,8},{4,0,8},{8,0,8}}
    indices:=[]u32{0,1,4,0,4,3,1,2,5,1,5,4}
    data,made:=ai.nav_tile_from_triangles({0,0},{{0,-1e6,0},{8,1e6,8}},vertices,indices)
    for &poly,i in data.polys {if i>=2 {poly.area=u8(nav.AREA_WATER)}}
    testing.expect(t,made && ai.nav_mesh_add_tile(mesh,data))
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    paths:core.Table(nav.Nav_Path)
    agents:core.Table(nav.Nav_Agent)
    walks:core.Table(phys.Walk)
    swims:core.Table(phys.Swim)
    core.table_init(&paths,"Nav_Path");core.table_init(&agents,"Nav_Agent");core.table_init(&walks,"Walk");core.table_init(&swims,"Swim")
    defer {core.table_destroy(&paths);core.table_destroy(&agents);core.table_destroy(&walks);core.table_destroy(&swims)}
    walker,swimmer:=core.create(&es),core.create(&es)
    for e in ([]core.Entity{walker,swimmer}) {
        core.add(&agents,e,nav.NAV_AGENT_DEFAULT)
        core.add(&walks,e,phys.Walk{max_speed=4,jump_height=1})
    }
    core.add(&swims,swimmer,phys.SWIM_DEFAULT)
    core.table_settle(&agents,&es);core.table_settle(&walks,&es);core.table_settle(&swims,&es)
    physics:phys.Physics_State
    places:Places
    defer places_free(&places)
    origin:=mm.Vec3{1,0,1}
    candidates:=[]mm.Vec3{{2,0,6},{6,0,2}}
    refs:[2]ai.Nav_Ref
    for c,i in candidates {
        ref,_,found:=ai.nav_find_nearest_any(mesh,c,{0.5,2,0.5})
        testing.expect(t,found)
        refs[i]=ref
    }
    measures:[2]f32
    walking:=place_filter(core.ref(&navigation),walker,core.read(&paths),core.read(&agents),core.read(&walks),core.read(&swims),core.ref(&physics))
    testing.expect(t,walking.excluded&(1<<u64(nav.AREA_WATER))!=0)
    // The first Path measure asks for the memory of its search: with it ending at each request
    // in turn the measure says so and finds no path, and with memory enough it goes through.
    owner:=context.allocator
    served,refused:=0,false
    for budget in 0..<64 {
        served=budget
        context.allocator=serving_allocator(&served,owner)
        enough:=place_paths(&places,origin,candidates,refs[:],mesh,nil,&walking,measures[:],1)
        context.allocator=owner
        if enough {break}
        refused=true
        testing.expectf(t,measures==[2]f32{PLACE_NO_PATH,PLACE_NO_PATH},"with %d requests served a refused measure found %v",budget,measures)
    }
    testing.expect(t,refused,"the search asks for memory")
    place_paths(&places,origin,candidates,refs[:],mesh,nil,&walking,measures[:],1)
    testing.expectf(t,abs(measures[0]-linalg.distance(origin,candidates[0]))<1e-3 && measures[1]==PLACE_NO_PATH,"a walker measures %v",measures)
    swimming:=place_filter(core.ref(&navigation),swimmer,core.read(&paths),core.read(&agents),core.read(&walks),core.read(&swims),core.ref(&physics))
    testing.expect(t,swimming.excluded&(1<<u64(nav.AREA_WATER))==0)
    place_paths(&places,origin,candidates,refs[:],mesh,nil,&swimming,measures[:],1)
    testing.expectf(t,abs(measures[0]-linalg.distance(origin,candidates[0]))<1e-3 && abs(measures[1]-linalg.distance(origin,candidates[1]))<1e-3,"a swimmer measures %v",measures)
}

// The points of the mesh around the querier are those joined to where it
// stands: an island across a gap gives none. Entities are candidates too,
// those of the query or the Perceivables of some teams, and the offers of a
// use of smart objects; each place found from one says which.
@(test)
places_come_from_the_mesh_joined_to_the_center_from_entities_and_from_offers :: proc(t:^testing.T) {
    f:Places_Test
    core.entities_init(&f.es)
    core.table_init(&f.worlds,"World_Transform");core.table_init(&f.results,"Place_Result");core.table_init(&f.perceivers,"Perceiver");core.table_init(&f.paths,"Nav_Path")
    core.table_init(&f.agents,"Nav_Agent");core.table_init(&f.walks,"Walk");core.table_init(&f.swims,"Swim")
    perceivables:core.Table(Perceivable)
    core.table_init(&perceivables,"Perceivable")
    defer {
        core.table_destroy(&f.worlds);core.table_destroy(&f.results);core.table_destroy(&f.perceivers);core.table_destroy(&f.paths);core.table_destroy(&f.agents);core.table_destroy(&f.walks);core.table_destroy(&f.swims)
        core.table_destroy(&perceivables)
        delete(f.requests.queue.items);places_free(&f.places)
        nav.navigation_free(&f.navigation)
        core.entities_destroy(&f.es)
    }
    f.navigation.classes[0].class=nav.NAVIGATION_SETTINGS_DEFAULT.classes[0]
    f.navigation.count,f.navigation.ready=1,true
    mesh:=&f.navigation.classes[0].mesh
    testing.expect(t,ai.nav_mesh_init(mesh,{tile_width=16,climb=0.3,max_tiles=1}))
    // Ground over x in [0, 6] and an island over x in [8, 12], both across z in [0, 4].
    vertices:=[]mm.Vec3{{0,0,0},{6,0,0},{6,0,4},{0,0,4},{8,0,0},{12,0,0},{12,0,4},{8,0,4}}
    indices:=[]u32{0,2,1,0,3,2,4,6,5,4,7,6}
    data,made:=ai.nav_tile_from_triangles({0,0},{{0,-1e6,0},{16,1e6,16}},vertices,indices)
    testing.expect(t,made && ai.nav_mesh_add_tile(mesh,data))
    querier,near,far,friend:=core.create(&f.es),core.create(&f.es),core.create(&f.es),core.create(&f.es)
    spots:=[4]mm.Vec3{{5,0,2},{3,0,2},{10,0,2},{4,0,1}}
    for e,i in ([]core.Entity{querier,near,far,friend}) {
        at:=spots[i]
        core.add(&f.worlds,e,core.World_Transform{transform={position=at,rotation=1,scale=1}})
    }
    core.add(&perceivables,near,Perceivable{team=1})
    core.add(&perceivables,far,Perceivable{team=1})
    core.add(&perceivables,friend,Perceivable{team=2})
    core.table_settle(&f.worlds,&f.es);core.table_settle(&perceivables,&f.es)
    f.settings=Behavior_Settings{queries=4}
    run :: proc(f:^Places_Test,perceivables:^core.Table(Perceivable),q:Place_Query) -> Place_Result {
        place_query(&f.requests,q)
        places_run(&f.requests,&f.places,&f.results,core.ref(&f.settings),core.read(&f.worlds),core.read(&f.perceivers),core.read(perceivables),core.read(&f.paths),
            core.read(&f.agents),core.read(&f.walks),core.read(&f.swims),core.ref(&f.navigation),core.ref(&f.physics),core.read(&f.objects),core.read(&f.states),&f.claims,{},{},&f.problems)
        core.table_settle(&f.results,&f.es)
        result,_:=core.get(core.read(&f.results),q.querier)
        return result
    }
    // Farthest from the querier first: on the ground it stands on, never on the island.
    away:=Place_Query{querier=querier,center=.Querier,layout=.Mesh,outer=8,spacing=1,keep=8}
    away.tests[0]={measure=.Distance,from=.Querier,min=0,max=16,response={kind=.Linear,slope=1}}
    away.test_count=1
    result:=run(&f,&perceivables,away)
    testing.expect(t,result.status==.Found && result.count==8)
    for p in result.points[:result.count] {testing.expectf(t,p.x<=6.01 && p.y==0,"%v is on the ground the querier stands on",p)}
    testing.expect(t,linalg.distance(result.points[0],mm.Vec3{5,0,2})>4.5,"the farthest of that ground")
    // The entities given, the nearest first.
    given:=Place_Query{querier=querier,center=.Querier,layout=.Entities,keep=2}
    given.entities[0],given.entities[1]=far,near
    given.entity_count=2
    given.tests[0]={measure=.Distance,from=.Querier,min=0,max=16,response={kind=.Linear,slope=-1,shift_y=1}}
    given.test_count=1
    result=run(&f,&perceivables,given)
    testing.expect(t,result.count==2 && result.entities[0]==near && result.entities[1]==far)
    // The Perceivables of team 1 within 4 m: the friend is of another team, the far one too far.
    seen:=given
    seen.layout,seen.outer,seen.teams,seen.entity_count=.Perceivables,4,Teams(1<<1),0
    result=run(&f,&perceivables,seen)
    testing.expect(t,result.count==1 && result.entities[0]==near && linalg.distance(result.points[0],mm.Vec3{3,0,2})<1e-3)
    // The offers of a use within 8 m: of the crate, its second offer, where its user stands; not those of another use.
    core.table_init(&f.objects,"Smart_Object");core.table_init(&f.states,"Smart_State")
    defer {core.table_destroy(&f.objects);core.table_destroy(&f.states)}
    crate,box:=core.create(&f.es),core.create(&f.es)
    core.add(&f.worlds,crate,core.World_Transform{transform={position={1,0,2},rotation=1,scale=1}})
    core.add(&f.worlds,box,core.World_Transform{transform={position={2,0,2},rotation=1,scale=1}})
    stocked,other:Smart_Object
    stocked.offers[0]={use=2,users=1}
    stocked.offers[1]={use=1,at={0,0,1},users=1}
    other.offers[0]={use=2,users=1}
    core.add(&f.objects,crate,stocked)
    core.add(&f.objects,box,other)
    core.table_settle(&f.worlds,&f.es);core.table_settle(&f.objects,&f.es)
    offered:=given
    offered.layout,offered.outer,offered.use,offered.entity_count=.Offers,8,1,0
    result=run(&f,&perceivables,offered)
    testing.expect(t,result.count==1 && result.entities[0]==crate && result.offers[0]==1 && linalg.distance(result.points[0],mm.Vec3{1,0,3})<1e-3)
    testing.expect_value(t,f.problems.count,0)
}

@(private="file")
Smart_Act :: enum u8 {Use}

// An offer is open to the agents of its teams with its abilities, to as many
// at once as it takes, as many times as it lasts and once its cooldown
// passed; the nearest open one is found, and one claimed is open again for
// others once its holder exits.
@(test)
smart_objects_offer_their_uses_to_whom_may_take_them :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    objects:core.Table(Smart_Object)
    states:core.Table(Smart_State)
    worlds:core.Table(core.World_Transform)
    core.table_init(&objects,"Smart_Object");core.table_init(&states,"Smart_State");core.table_init(&worlds,"World_Transform")
    defer {core.table_destroy(&objects);core.table_destroy(&states);core.table_destroy(&worlds)}
    uses:Smart_Uses
    defer delete(uses.queue.items)
    claims:Claims
    USE_AMMO :: Smart_Use(1)
    USE_TURRET :: Smart_Use(2)
    crate,far_crate,turret,a,b:=core.create(&es),core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    for e,i in ([]core.Entity{crate,far_crate,turret}) {
        core.add(&worlds,e,core.World_Transform{transform={position={f32(i)*10,0,0},rotation=1,scale=1}})
    }
    ammo:Smart_Object
    ammo.offers[0]={use=USE_AMMO,at={0,0,1},users=1,uses=2,cooldown=5,teams=Teams(1<<1)}
    core.add(&objects,crate,ammo)
    core.add(&objects,far_crate,ammo)
    gun:Smart_Object
    gun.offers[0]={use=USE_TURRET,users=1,abilities=nav.Nav_Abilities(1<<u32(nav.ABILITY_CLIMB))}
    core.add(&objects,turret,gun)
    settle :: proc(es:^core.Entities,objects:^core.Table(Smart_Object),states:^core.Table(Smart_State),worlds:^core.Table(core.World_Transform)) {
        core.table_settle(objects,es);core.table_settle(states,es);core.table_settle(worlds,es)
    }
    settle(&es,&objects,&states,&worlds)
    smart_update(core.read(&objects),&states,&uses,{seconds=0})
    settle(&es,&objects,&states,&worlds)
    v:=Smart_View{objects=core.read(&objects),states=core.read(&states),worlds=core.read(&worlds),claims=&claims,time=0,tick=1}
    red:=Smart_User{entity=a,team=1}
    blue:=Smart_User{entity=b,team=2}
    found,ok:=smart_offer(&v,crate,USE_AMMO,red)
    testing.expect(t,ok && found.offer==0 && found.users==1 && found.at=={0,0,1})
    _,ok=smart_offer(&v,crate,USE_AMMO,blue)
    testing.expect(t,!ok,"of another team")
    _,ok=smart_offer(&v,turret,USE_TURRET,red)
    testing.expect(t,!ok,"without the ability")
    _,ok=smart_offer(&v,turret,USE_TURRET,{entity=a,abilities=nav.Nav_Abilities(1<<u32(nav.ABILITY_CLIMB))})
    testing.expect(t,ok)
    nearest,near_ok:=smart_nearest(&v,USE_AMMO,{12,0,0},20,red)
    testing.expect(t,near_ok && nearest.object==far_crate)
    _,near_ok=smart_nearest(&v,USE_AMMO,{30,0,0},5,red)
    testing.expect(t,!near_ok,"none within the radius")
    // Claimed by one, closed to the other until the holder exits.
    m:ai.Mind
    ctx:=ai.Mind_Context{tick=1,holder=u64(a),reservations=&claims.reservations}
    act:=ai.Act(Smart_Act){ctx=&ctx,mind=&m,frame=&m.main}
    testing.expect(t,smart_claim(&act,found))
    other:=Smart_User{entity=core.create(&es),team=1}
    _,ok=smart_offer(&v,crate,USE_AMMO,other)
    testing.expect(t,!ok,"claimed")
    _,ok=smart_offer(&v,crate,USE_AMMO,red)
    testing.expect(t,ok,"its own")
    ai.reserve_release(&claims.reservations,m.main.reserved,u64(a))
    _,ok=smart_offer(&v,crate,USE_AMMO,other)
    testing.expect(t,ok)
    // Used: closed until its cooldown passes; spent after its uses.
    smart_used(&uses,found)
    smart_update(core.read(&objects),&states,&uses,{seconds=1})
    settle(&es,&objects,&states,&worlds)
    v.time=3
    _,ok=smart_offer(&v,crate,USE_AMMO,red)
    testing.expect(t,!ok,"cooling down")
    v.time=6
    _,ok=smart_offer(&v,crate,USE_AMMO,red)
    testing.expect(t,ok)
    smart_used(&uses,found)
    smart_update(core.read(&objects),&states,&uses,{seconds=6})
    settle(&es,&objects,&states,&worlds)
    v.time=100
    _,ok=smart_offer(&v,crate,USE_AMMO,red)
    testing.expect(t,!ok,"spent")
}

// The influence of each team is where its Perceivables are, less farther
// away; without a cell there is no map.
@(test)
influence_maps_follow_the_teams :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    perceivables:core.Table(Perceivable)
    worlds:core.Table(core.World_Transform)
    core.table_init(&perceivables,"Perceivable");core.table_init(&worlds,"World_Transform")
    defer {core.table_destroy(&perceivables);core.table_destroy(&worlds)}
    influence:Influence
    defer influence_free(&influence)
    settings:=BEHAVIOR_SETTINGS_DEFAULT
    settings.influence_size,settings.influence_cells,settings.influence_rays=32,32*32*INFLUENCE_TEAMS,0
    physics:phys.Physics_State
    red,blue:=core.create(&es),core.create(&es)
    core.add(&perceivables,red,Perceivable{team=1})
    core.add(&perceivables,blue,Perceivable{team=2})
    core.add(&worlds,red,core.World_Transform{transform={position={-10,0,0},rotation=1,scale=1}})
    core.add(&worlds,blue,core.World_Transform{transform={position={10,0,0},rotation=1,scale=1}})
    core.table_settle(&perceivables,&es);core.table_settle(&worlds,&es)
    calls:=0
    for tick in 0..<20 {
        // Made on the first tick; the others do not allocate.
        saved:=context.allocator
        if tick>0 {context.allocator=refusing_allocator(&calls)}
        influence_update(&influence,core.ref(&settings),core.read(&perceivables),core.read(&worlds),core.ref(&physics),{tick=u64(tick),dt=1.0/60,playing=true})
        context.allocator=saved
    }
    testing.expect_value(t,calls,0)
    reds:=Teams(1<<1)
    testing.expect(t,influence_at(&influence,{-10,0,0},reds)>0.5)
    testing.expect(t,influence_at(&influence,{-10,0,0},reds)>influence_at(&influence,{-4,0,0},reds))
    testing.expect(t,influence_at(&influence,{10,0,0},reds)<0.05 && influence_at(&influence,{10,0,0},Teams(1<<2))>0.5)
    testing.expect(t,influence_at(&influence,{-10,0,0},reds|Teams(1<<2))>=influence_at(&influence,{-10,0,0},reds))
    testing.expect_value(t,cover_at(&influence,{-10,0,0},{10,0,0}),0)
    settings.influence_cell=0
    influence_update(&influence,core.ref(&settings),core.read(&perceivables),core.read(&worlds),core.ref(&physics),{tick=20,dt=1.0/60,playing=true})
    testing.expect_value(t,influence_at(&influence,{-10,0,0},reds),0)
}
