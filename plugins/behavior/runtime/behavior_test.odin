package behavior

import "base:runtime"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:engine/volume"
import "mirai:std/ai"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import locomotion "plugins:locomotion/runtime"
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

// What the tests of this file tick: the tables and the storages of a World
// that the minds, the perception, the places and the smart objects read.
@(private)
@(test_world)
Behavior_World :: struct {
    using world:Test_World,
    mind_agents:core.Table(Mind_Agent),
    perceivers:core.Table(Perceiver),
    perceptions:core.Table(Perception),
    perceivables:core.Table(Perceivable),
    results:core.Table(Place_Result),
    objects:core.Table(Smart_Object),
    states:core.Table(Smart_State),
    worlds:core.Table(core.World_Transform),
    paths:core.Table(nav.Nav_Path),
    fars:core.Table(nav.Nav_Far),
    agents:core.Table(nav.Nav_Agent),
    characters:core.Table(phys.Character),
    patrols:core.Table(Patrol),
    splines:core.Table(volume.Spline),
    walks:core.Table(locomotion.Walk),
    swims:core.Table(locomotion.Swim),
    turns:Perceiving,
    noises:Noises,
    events:Perception_Events,
    settings:Behavior_Settings,
    requests:Place_Requests,
    uses:Smart_Uses,
    claims:Claims,
    moves:nav.Nav_Requests,
    navigation:nav.Navigation,
    physics:phys.Physics_State,
}

// A world whose perceivers look: with what the application keeps for them.
@(private="file")
Sight_World :: struct {
    using behavior:Behavior_World,
    sight:Sight,
    problems:core.Problems,
}

@(private="file")
sight_world_destroy :: proc(f:^Sight_World) {
    sight_free(&f.sight)
    test_world_destroy(&f.behavior)
}

@(private="file")
Count_Act :: enum u8 {Count}

// The context of a mind, as the generated step of a mind makes it: Mind_World first.
@(private="file")
Counting :: struct {
    world:Mind_World,
    near,far,entered:int,
}

@(private="file")
counting_think :: proc(t:^ai.Think(Count_Act)) {ai.propose(t,.Count,1)}

// Counts its entries, near and far (what it claims lasts longer), and ends on
// its first Update.
@(private="file")
counting_act :: proc(a:^ai.Act(Count_Act)) -> ai.Status {
    c:=(^Counting)(a.user)
    if a.phase!=.Enter {return .Success}
    c.entered+=1
    if a.lease>1 {c.far+=1} else {c.near+=1}
    return .Running
}

@(private="file")
COUNTING_ACTS := [Count_Act]proc(a:^ai.Act(Count_Act)) -> ai.Status{.Count=counting_act}

// A mind registers by name when its agents tick; a name it cannot hold
// registers nothing, and the agents of a name no mind declares are a problem
// that says what to fix.
@(test)
minds_register_by_name_and_tick_their_agents :: proc(t:^testing.T) {
    minds:=new(Minds)
    defer free(minds)
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    a,b,lost:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.mind_agents,a,Mind_Agent{mind=mind_name("counter")})
    core.add(&world.mind_agents,b,Mind_Agent{mind=mind_name("counter")})
    core.add(&world.mind_agents,lost,Mind_Agent{mind=mind_name("nobody")})
    test_world_settle(&world)
    c:=Counting{world={minds=minds,agents=&world.mind_agents,time={tick=1,dt=1.0/60,playing=true}}}
    minds_tick(&c.world,"counter",&COUNTING_ACTS,counting_think)
    testing.expect_value(t,c.entered,2)
    for name in ([]string{"counter","","a name far too long for a mind"}) {mind_register(minds,name,Count_Act)}
    testing.expect(t,minds.count==1 && mind_of(minds,mind_name("counter")).actions==Count_Act && mind_of(minds,mind_name("other"))==nil)
    problems:core.Problems
    minds_unknown(core.ref(minds),core.read(&world.mind_agents),c.world.time,&problems)
    testing.expect(t,core.problem_find(&problems,lost,"behavior.mind")!=nil && core.problem_find(&problems,a,"behavior.mind")==nil)
}

// A mind decides in a world that plays; a world that does not play, or a tick
// that runs again, decides nothing.
@(test)
the_mind_of_an_agent_does_not_tick_again_in_a_resimulation :: proc(t:^testing.T) {
    minds:=new(Minds)
    defer free(minds)
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    e:=core.create(&world.entities)
    core.add(&world.mind_agents,e,Mind_Agent{mind=mind_name("hunter")})
    test_world_settle(&world)
    c:=Counting{world={minds=minds,agents=&world.mind_agents,time={tick=1,dt=1.0/60,playing=true}}}
    minds_tick(&c.world,"hunter",&COUNTING_ACTS,counting_think)
    testing.expect(t,c.entered==1)
    // It ends and enters again.
    c.world.time.tick=2
    minds_tick(&c.world,"hunter",&COUNTING_ACTS,counting_think)
    testing.expect_value(t,c.entered,2)
    ticks:=world.mind_agents.values[0].state.ticks
    for time in ([]core.Time{{tick=3,dt=1.0/60,playing=true,resimulating=true},{tick=3,dt=1.0/60}}) {
        c.world.time=time
        minds_tick(&c.world,"hunter",&COUNTING_ACTS,counting_think)
        testing.expect_value(t,world.mind_agents.values[0].state.ticks,ticks)
        testing.expect_value(t,c.entered,2)
    }
}

// An agent far from the players is off with its rows, and its mind decides
// on, at the steps of what is far, holding what it claims until its next
// tick; its move actions read where navigation took it.
@(test)
the_mind_of_an_agent_far_ticks_at_the_steps_of_what_is_far :: proc(t:^testing.T) {
    minds:=new(Minds)
    defer free(minds)
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    near,far,dormant:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    for e in ([3]core.Entity{near,far,dormant}) {
        core.add(&world.mind_agents,e,Mind_Agent{mind=mind_name("counter")})
        core.add(&world.paths,e,nav.Nav_Path{state=.Arrived,class=-1})
    }
    core.add(&world.fars,far,nav.Nav_Far{arrived=true})
    test_world_settle(&world)
    // Off: the far one as navigation leaves it, the dormant one as a section that sleeps.
    for e in ([2]core.Entity{far,dormant}) {core.disable(&world.mind_agents,e);core.disable(&world.paths,e)}
    core.disable(&world.fars,far)
    test_world_settle(&world)
    c:=Counting{world={minds=minds,agents=&world.mind_agents,paths=core.read(&world.paths),fars=core.read(&world.fars),claims=&world.claims}}
    calls:=0
    for tick in u64(0)..<60 {
        // Its ticks after the first, which registers the mind, do not allocate.
        saved:=context.allocator
        if tick>0 {context.allocator=refusing_allocator(&calls)}
        c.world.time={tick=tick,dt=1.0/60,seconds=f64(tick)/60,playing=true}
        minds_tick(&c.world,"counter",&COUNTING_ACTS,counting_think)
        context.allocator=saved
    }
    testing.expect_value(t,calls,0)
    testing.expect_value(t,c.near,60)
    testing.expect_value(t,c.far,2)
    // Its actions read its path, off as it is: navigation says it arrived.
    ctx:=ai.Mind_Context{user=&c.world,holder=u64(far),reservations=&world.claims.reservations}
    testing.expect_value(t,path_status(&ctx),ai.Status.Success)
    testing.expect_value(t,world.mind_agents.values[core.raw_row(core.raw(&world.mind_agents),dormant)].state.ticks,0)
    // What a far agent claims lasts until its next decision, half a second later.
    a:=ai.Act(Count_Act){ctx=&ctx,frame=&world.mind_agents.values[0].state.main}
    ctx.tick,ctx.lease=100,31
    testing.expect(t,ai.claim(&a,7,1,1))
    testing.expect(t,!ai.reserve_open(&world.claims.reservations,{7,1},u64(near),1,130) && ai.reserve_open(&world.claims.reservations,{7,1},u64(near),1,132))
}

@(private="file")
Move_Act :: enum u8 {Move}

// Walking and chasing ask navigation, read where the agent got and stop it
// when they end; a chase follows the new target when it changes.
@(test)
move_actions_ask_navigation_and_read_where_the_agent_got :: proc(t:^testing.T) {
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    e,prey,other:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.paths,e,nav.Nav_Path{state=.Waiting})
    test_world_settle(&world)
    w:=Mind_World{requests=&world.moves,paths=core.read(&world.paths)}
    ctx:=ai.Mind_Context{user=&w,holder=u64(e)}
    memory:[ai.MIND_WORDS]u64
    a:=ai.Act(Move_Act){ctx=&ctx,phase=.Enter,memory=memory[:]}
    last :: proc(world:^Behavior_World) -> nav.Nav_Request {return world.moves.queue.items[len(world.moves.queue.items)-1]}
    testing.expect_value(t,move_act(&a,{1,2,3}),ai.Status.Running)
    testing.expect(t,len(world.moves.queue.items)==1 && last(&world).kind==.Move_To && last(&world).point=={1,2,3})
    a.phase=.Update
    testing.expect_value(t,move_act(&a,{}),ai.Status.Running)
    core.edit(&world.paths,e).state=.Arrived
    testing.expect_value(t,move_act(&a,{}),ai.Status.Success)
    core.edit(&world.paths,e).partial=true
    testing.expect_value(t,path_status(&a),ai.Status.Failure)
    a.phase,a.cause=.Exit,.Aborted
    move_act(&a,{})
    testing.expect(t,last(&world).kind==.Stop)
    // A chase follows its target, and the other one when the target changes.
    core.edit(&world.paths,e)^={state=.Moving}
    Chase :: struct {phase:ai.Phase,target:core.Entity,status:ai.Status,asks:bool,kind:nav.Nav_Request_Kind,of:core.Entity}
    asked:=len(world.moves.queue.items)
    for c in ([]Chase{{.Enter,prey,.Running,true,.Follow,prey},{.Update,prey,.Running,false,{},{}},{.Update,other,.Running,true,.Follow,other},{.Update,core.NONE,.Failure,false,{},{}},{.Exit,other,.Success,true,.Stop,{}}}) {
        a.phase=c.phase
        testing.expect_value(t,chase_act(&a,c.target,1),c.status)
        if !c.asks {
            testing.expect_value(t,len(world.moves.queue.items),asked)
            continue
        }
        asked=len(world.moves.queue.items)
        testing.expect(t,last(&world).kind==c.kind && (c.of==core.NONE || last(&world).target==c.of))
    }
    core.edit(&world.paths,e).state=.Failed
    a.phase=.Update
    testing.expect_value(t,chase_act(&a,other,1),ai.Status.Failure)
}

// A patrol walks the points of a Spline from the one after where it is
// nearest, on to the next when it arrives or cannot get there, back and forth,
// around or once; it follows the path when it moves or is edited, stands at a
// path of one point, keeps a crossing when it is interrupted and fails with a
// problem without a path to walk. An agent without a mind walks it by itself.
@(test)
patrols_walk_the_points_of_their_spline :: proc(t:^testing.T) {
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    e,route:=core.create(&world.entities),core.create(&world.entities)
    line:=volume.Spline{count=3,points={0={position={0,0,0},width=1},1={position={0,0,-4},width=1},2={position={0,0,-8},width=1}}}
    core.add(&world.paths,e,nav.Nav_Path{})
    core.add(&world.worlds,e,core.World_Transform{transform={{5,0,3},mm.QUAT_IDENTITY,{1,1,1}}})
    core.add(&world.worlds,route,core.World_Transform{transform={{5,0,0},mm.QUAT_IDENTITY,{1,1,1}}})
    core.add(&world.splines,route,line)
    core.add(&world.patrols,e,Patrol{path=route,mode=.Back_And_Forth})
    test_world_settle(&world)
    problems:core.Problems
    w:=Mind_World{requests=&world.moves,paths=core.read(&world.paths),worlds=core.read(&world.worlds),patrols=&world.patrols,splines=core.read(&world.splines),problems=&problems}
    ctx:=ai.Mind_Context{user=&w,holder=u64(e)}
    memory:[ai.MIND_WORDS]u64
    a:=ai.Act(Move_Act){ctx=&ctx,memory=memory[:]}
    Step :: struct {name:string,phase:ai.Phase,state:nav.Nav_State,edit:proc(w:^Behavior_World,e,route:core.Entity),status:ai.Status,goal:[3]f32,asks:bool}
    move :: proc(w:^Behavior_World,e,route:core.Entity) {core.edit(&w.worlds,route).position.x=6}
    once :: proc(w:^Behavior_World,e,route:core.Entity) {core.edit(&w.patrols,e).mode=.Once}
    loop :: proc(w:^Behavior_World,e,route:core.Entity) {core.edit(&w.patrols,e).mode=.Loop}
    shorten :: proc(w:^Behavior_World,e,route:core.Entity) {core.edit(&w.splines,route).count=1}
    lost :: proc(w:^Behavior_World,e,route:core.Entity) {
        nan:=f32(0)
        core.edit(&w.splines,route).points[0].position.y=nan/nan
    }
    for c in ([]Step{
        {"from the nearest, the next",.Enter,.Idle,nil,.Running,{5,0,-4},true},
        {"walking",.Update,.Moving,nil,.Running,{},false},
        {"its path moved",.Update,.Moving,move,.Running,{6,0,-4},true},
        {"there",.Update,.Arrived,nil,.Running,{6,0,-8},true},
        {"and back",.Update,.Arrived,nil,.Running,{6,0,-4},true},
        {"one it cannot get to",.Update,.Failed,nil,.Running,{6,0,0},true},
        {"and forth again",.Update,.Arrived,nil,.Running,{6,0,-4},true},
        {"around",.Update,.Arrived,loop,.Running,{6,0,-8},true},
        {"from the last to the first",.Update,.Arrived,nil,.Running,{6,0,0},true},
        {"once to the last",.Update,.Arrived,once,.Running,{6,0,-4},true},
        {"at the end",.Update,.Arrived,nil,.Running,{6,0,-8},true},
        {"ended",.Update,.Arrived,nil,.Success,{},false},
        {"edited to one point: to it",.Update,.Arrived,shorten,.Running,{6,0,0},true},
        {"and stands there",.Update,.Arrived,loop,.Running,{},false},
        {"a point not a number",.Update,.Arrived,lost,.Failure,{},false},
    }) {
        if c.edit!=nil {c.edit(&world,e,route)}
        core.edit(&world.paths,e).state=c.state
        core.edit(&world.paths,e).goal=world.moves.queue.items[len(world.moves.queue.items)-1].point if len(world.moves.queue.items)>0 else {}
        asked:=len(world.moves.queue.items)
        a.phase=c.phase
        testing.expectf(t,patrol_act(&a)==c.status,"%s: its status",c.name)
        asks:=len(world.moves.queue.items)>asked
        testing.expectf(t,asks==c.asks && (!asks || world.moves.queue.items[asked].point==c.goal),"%s: asked %v",c.name,world.moves.queue.items[asked:])
    }
    testing.expect_value(t,problems.count,1)
    // An interrupted patrol stops the agent, but not in the middle of a crossing.
    for state in ([]nav.Nav_State{.Crossing,.Moving}) {
        core.edit(&world.paths,e).state=state
        asked:=len(world.moves.queue.items)
        a.phase,a.cause=.Exit,.Aborted
        patrol_act(&a)
        testing.expectf(t,(len(world.moves.queue.items)>asked)==(state==.Moving),"%v",state)
    }
    // Without a mind it walks by itself; with one, only while the mind patrols.
    core.edit(&world.splines,route)^=line
    core.edit(&world.paths,e).state=.Idle
    for minded in ([]bool{false,true}) {
        if minded {
            core.add(&world.mind_agents,e,Mind_Agent{})
            test_world_settle(&world)
        }
        asked:=len(world.moves.queue.items)
        patrols_walk(&world.patrols,core.read(&world.mind_agents),core.read(&world.paths),core.read(&world.splines),core.read(&world.worlds),&world.moves,&problems,{playing=true,dt=1.0/60})
        testing.expectf(t,(len(world.moves.queue.items)>asked)!=minded,"with a mind: %v",minded)
    }
    // Without a path it fails, as one without its Patrol.
    core.edit(&world.patrols,e).path=core.NONE
    a.phase=.Enter
    testing.expect_value(t,patrol_act(&a),ai.Status.Failure)
    core.remove(&world.patrols,e)
    test_world_settle(&world)
    testing.expect_value(t,patrol_act(&a),ai.Status.Failure)
}

// The clock at `seconds` of a run at hz ticks a second.
@(private="file")
clock_at :: proc(hz,seconds:f64) -> core.Time {return {tick=u64(seconds*hz+0.5),seconds=seconds,dt=f32(1/hz),playing=true}}

@(private="file")
sight_tick :: proc(f:^Sight_World,seconds:f64) {
    test_world_settle(f)
    perception_update(core.read(&f.perceivers),&f.perceptions,core.read(&f.perceivables),core.read(&f.worlds),core.ref(&f.settings),&f.turns,&f.sight,&f.noises,&f.events,core.ref(&f.physics),core.read(&f.fars),core.ref(&f.entities),clock_at(60,seconds),&f.problems)
    test_world_settle(f)
}

@(private="file")
placed :: proc(f:^Behavior_World,position:mm.Vec3) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale=1}})
    return e
}

@(test)
perceivers_see_the_teams_they_notice_in_their_cone_hear_noises_and_forget :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
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
    mine:=core.edit(&f.perceptions,guard)
    testing.expect(t,mine!=nil && mine.memory.count==1 && ai.memory_find(&mine.memory,u64(ahead))!=nil)
    testing.expect(t,len(f.events.queue.items)==1 && f.events.queue.items[0].kind==.Noticed && f.events.queue.items[0].subject==ahead)
    // A noise behind it is heard; out of hearing, not.
    noise(&f.noises,{position={0,0,4},loudness=10,maker=behind,team=1})
    noise(&f.noises,{position={0,0,40},loudness=10,maker=friend,team=1})
    sight_tick(&f,0.2)
    mine=core.edit(&f.perceptions,guard)
    heard:=ai.memory_find(&mine.memory,u64(behind))
    testing.expect(t,heard!=nil && heard.senses=={.Hearing} && ai.memory_find(&mine.memory,u64(friend))==nil)
    // What it saw stays in sight a little past its range; what it did not is not noticed there.
    core.edit(&f.worlds,ahead).position={0,0,-21}
    beyond:=placed(&f,{1.5,0,-21})
    core.add(&f.perceivables,beyond,Perceivable{team=1,point=1})
    sight_tick(&f,0.3)
    mine=core.edit(&f.perceptions,guard)
    kept:=ai.memory_find(&mine.memory,u64(ahead))
    testing.expect(t,kept!=nil && kept.last==18 && .Sight in kept.senses && ai.memory_find(&mine.memory,u64(beyond))==nil)
    // What it no longer perceives is forgotten after `forget` seconds.
    core.edit(&f.worlds,ahead).position={0,0,-50}
    sight_tick(&f,1.2)
    sight_tick(&f,2.5)
    mine=core.edit(&f.perceptions,guard)
    testing.expect(t,ai.memory_find(&mine.memory,u64(behind))==nil)
    forgot:=false
    for event in f.events.queue.items {forgot|=event.kind==.Forgot && event.subject==behind}
    testing.expect(t,forgot)
}

// Within `aware` of its eyes a perceiver sees all around, not only in its cone.
@(test)
a_perceiver_sees_all_around_within_aware :: proc(t:^testing.T) {
    for c in ([]struct{aware:f32,seen:bool}{{0,false},{2,true},{0.5,false}}) {
        f:Sight_World
        if !test_world_init(t,&f.behavior) {return}
        defer sight_world_destroy(&f)
        guard:=placed(&f,{})
        watch:=PERCEIVER_DEFAULT
        watch.aware=c.aware
        core.add(&f.perceivers,guard,watch)
        behind:=placed(&f,{0,0,1})
        core.add(&f.perceivables,behind,Perceivable{point=1})
        sight_tick(&f,0)
        sight_tick(&f,0.1)
        mine:=core.edit(&f.perceptions,guard)
        testing.expectf(t,mine!=nil && (ai.memory_find(&mine.memory,u64(behind))!=nil)==c.seen,"aware %v",c.aware)
    }
}

// Asked about one subject, a perceiver says why it sees it or not: out of
// range, out of its cone or within `aware`, a team it does not notice, or the
// entity a ray from its eyes hits first.
@(test)
sight_why_names_what_hides_a_subject :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
    if !testing.expect(t,phys.test_state_make(&f.physics)) {return}
    guard:=placed(&f,{})
    watch:=PERCEIVER_DEFAULT
    watch.notices=Teams(1<<1)
    watch.aware=2
    core.add(&f.perceivers,guard,watch)
    wall:=core.create(&f.entities)
    body,_:=phys.owned_body_create(&f.physics,{1,wall,0},{2,1.5,-4},1)
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    phys.owned_shape_create(&f.physics,&collision,body,{collider=phys.collider_box({1,2,0.1}),rotation=1})
    Case :: struct {at:mm.Vec3,team:Team,reason:Sight_Reason,blocker:core.Entity}
    cases:=[]Case{
        {{0,0,-5},1,.Seen,core.NONE},
        {{0,0,1},1,.Aware,core.NONE},
        {{0,0,5},1,.Out_Of_Cone,core.NONE},
        {{0,0,-30},1,.Out_Of_Range,core.NONE},
        {{1,0,-5},2,.Team,core.NONE},
        {{4,0,-8},1,.Blocked,wall},
    }
    subjects:[6]core.Entity
    for c,i in cases {
        subjects[i]=placed(&f,c.at)
        core.add(&f.perceivables,subjects[i],Perceivable{team=c.team,point=1})
    }
    test_world_settle(&f)
    for c,i in cases {
        why:=sight_why(core.read(&f.perceivers),core.read(&f.perceptions),core.read(&f.perceivables),core.read(&f.worlds),core.read(&f.fars),core.ref(&f.physics),guard,subjects[i])
        testing.expectf(t,why.reason==c.reason && why.blocker==c.blocker,"%v: %v by %v, %v by %v expected",c.at,why.reason,why.blocker,c.reason,c.blocker)
    }
    // What it says is what its turn does: it remembers those it sees, not the hidden one.
    sight_tick(&f,0)
    sight_tick(&f,0.1)
    mine:=core.edit(&f.perceptions,guard)
    for c,i in cases {
        found:=mine!=nil && ai.memory_find(&mine.memory,u64(subjects[i]))!=nil
        testing.expectf(t,found==(c.reason==.Seen || c.reason==.Aware),"%v: remembered %v",c.at,found)
    }
}

// A noise reaches the perceivers that notice the team of its maker: by ear
// within their hearing, or only its listener wherever it is (a hit), without
// a ray; one of long ago is remembered as of then.
@(test)
a_noise_reaches_those_that_notice_its_team_or_only_its_listener :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
    f.settings.rays=0
    watch:=PERCEIVER_DEFAULT
    watch.notices=Teams(1<<1)
    guard,near:=placed(&f,{}),placed(&f,{0,0,40})
    core.add(&f.perceivers,guard,watch)
    core.add(&f.perceivers,near,watch)
    mate,enemy,hitter:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    sight_tick(&f,0)
    noise(&f.noises,{position={0,0,4},loudness=10,maker=mate,team=2})
    noise(&f.noises,{position={0,0,-4},loudness=10,maker=enemy,team=1})
    noise(&f.noises,{position={0,0,39},maker=hitter,team=1,listener=guard,age=30})
    noise(&f.noises,{position={0,0,39},maker=mate,team=2,listener=guard})
    sight_tick(&f,1)
    mine,other:=core.edit(&f.perceptions,guard),core.edit(&f.perceptions,near)
    testing.expect(t,ai.memory_find(&mine.memory,u64(mate))==nil,"a noise of a team it does not notice is not heard")
    testing.expect(t,ai.memory_find(&mine.memory,u64(enemy))!=nil)
    hit:=ai.memory_find(&mine.memory,u64(hitter))
    testing.expect(t,hit!=nil && hit.first==30 && hit.position=={0,0,39},"its listener perceives it, as long ago as its age")
    testing.expect(t,ai.memory_find(&other.memory,u64(hitter))==nil,"another perceiver beside it does not")
}

// A subject remembered and then destroyed is forgotten at once, with its
// event; its handle is not taken for the entity that reuses its slot, and a
// noise remembered without a maker stays.
@(test)
a_remembered_subject_that_is_destroyed_is_forgotten_at_once :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
    guard:=placed(&f,{})
    watch:=PERCEIVER_DEFAULT
    watch.forget=100
    core.add(&f.perceivers,guard,watch)
    seen:=placed(&f,{0,0,-5})
    core.add(&f.perceivables,seen,Perceivable{point=1})
    sight_tick(&f,0)
    noise(&f.noises,{position={3,0,0},loudness=10})
    sight_tick(&f,0.1)
    mine:=core.edit(&f.perceptions,guard)
    testing.expect(t,mine!=nil && ai.memory_find(&mine.memory,u64(seen))!=nil && ai.memory_find(&mine.memory,0)!=nil)
    core.destroy(&f.entities,seen)
    test_world_settle(&f)
    again:=placed(&f,{0,0,-50})
    sight_tick(&f,0.2)
    mine=core.edit(&f.perceptions,guard)
    testing.expect(t,ai.memory_find(&mine.memory,u64(seen))==nil,"the destroyed subject is forgotten")
    testing.expect(t,ai.memory_find(&mine.memory,u64(again))==nil)
    testing.expect(t,ai.memory_find(&mine.memory,0)!=nil,"the place of a noise without a maker stays")
    forgot:=false
    for event in f.events.queue.items {forgot|=event.kind==.Forgot && event.subject==seen}
    testing.expect(t,forgot)
}

@(test)
sight_shares_its_rays_among_perceivers_in_turns :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
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
        mine:=core.edit(&f.perceptions,g)
        testing.expect(t,mine!=nil && ai.memory_find(&mine.memory,u64(target))!=nil)
    }
    // Fewer rays than candidates: each perceiver goes on from where the rays
    // stopped it, so every subject in sight is looked at again within
    // ceil(candidates/rays) ticks, and none is forgotten.
    crowd:Sight_World
    if !test_world_init(t,&crowd.behavior) {return}
    defer sight_world_destroy(&crowd)
    crowd.settings.rays=3
    watchers:[2]core.Entity
    for &w,i in watchers {
        w=placed(&crowd,{f32(i)*2,0,0})
        watch:=PERCEIVER_DEFAULT
        watch.forget=8.0/60
        core.add(&crowd.perceivers,w,watch)
    }
    subjects:[8]core.Entity
    for &s,i in subjects {
        s=placed(&crowd,{f32(i)-2,0,-6})
        core.add(&crowd.perceivables,s,Perceivable{point=1})
    }
    WITHIN :: (2*8+2)/3 // ticks: ceil(candidates/rays)
    for tick in 0..=40 {
        sight_tick(&crowd,f64(tick)/60)
        if tick<=WITHIN {continue}
        for w in watchers {
            mine:=core.edit(&crowd.perceptions,w)
            for s in subjects {
                o:=ai.memory_find(&mine.memory,u64(s))
                testing.expectf(t,o!=nil && u64(tick)-o.last<=WITHIN,"tick %d: %v last looked at %v at tick %v",tick,w,s,o.last if o!=nil else 0)
            }
        }
        for event in crowd.events.queue.items {testing.expectf(t,event.kind!=.Forgot,"tick %d: %v forgot %v",tick,event.perceiver,event.subject)}
    }
}

@(test)
every_perceiver_gets_its_turn_and_forgets_only_in_it :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
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
        mine:=core.edit(&f.perceptions,g)
        testing.expect(t,mine!=nil && ai.memory_find(&mine.memory,u64(target))!=nil)
    }
    // Long after a subject was perceived, only the one whose turn it is forgets it.
    ghost:=u64(1<<40)
    for g in guards {ai.memory_perceive(&core.edit(&f.perceptions,g).memory,ghost,{},.Sight,1,0)}
    sight_tick(&f,5)
    forgot:=0
    for g in guards {if ai.memory_find(&core.edit(&f.perceptions,g).memory,ghost)==nil {forgot+=1}}
    testing.expect_value(t,forgot,1)
}

@(test)
places_are_answered_in_order_within_the_budget :: proc(t:^testing.T) {
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    a,b:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.worlds,a,core.World_Transform{transform={position={0,0,0},rotation=1,scale=1}})
    core.add(&world.worlds,b,core.World_Transform{transform={position={10,0,0},rotation=1,scale=1}})
    test_world_settle(&world)
    places:Places
    defer places_free(&places)
    world.settings=Behavior_Settings{queries=1}
    // Near the point (3,0,0): of a grid around the querier, the best is that point.
    q:=Place_Query{querier=a,center=.Querier,layout=.Grid,outer=4,spacing=1,keep=3}
    q.tests[0]={measure=.Distance,from=.Point,point={3,0,0},min=0,max=8,response={kind=.Linear,slope=-1,shift_y=1}}
    q.test_count=1
    place_query(&world.requests,q)
    q.querier=b
    place_query(&world.requests,q)
    problems:core.Problems
    places_run(&world.requests,&places,&world.results,core.ref(&world.settings),core.read(&world.worlds),core.read(&world.perceivers),core.read(&world.perceptions),{},core.read(&world.paths),core.read(&world.agents),core.read(&world.characters),core.read(&world.walks),core.read(&world.swims),core.ref(&world.navigation),core.ref(&world.physics),{},{},&problems)
    test_world_settle(&world)
    first,_:=core.get(&world.results,a)
    second,_:=core.get(&world.results,b)
    testing.expect(t,first.status==.Found && first.request==1 && first.count==3 && first.points[0]=={3,0,0} && first.scores[0]>=first.scores[1])
    testing.expect(t,second.status==.Waiting && second.request==2)
    places_run(&world.requests,&places,&world.results,core.ref(&world.settings),core.read(&world.worlds),core.read(&world.perceivers),core.read(&world.perceptions),{},core.read(&world.paths),core.read(&world.agents),core.read(&world.characters),core.read(&world.walks),core.read(&world.swims),core.ref(&world.navigation),core.ref(&world.physics),{},{},&problems)
    second,_=core.get(&world.results,b)
    testing.expect(t,second.status==.Found && linalg.distance(second.points[0],mm.Vec3{6,0,0})<1e-4)
    // Of two queries of one querier, the last one is answered and the first does not take its place.
    q.querier=a
    place_query(&world.requests,q)
    place_query(&world.requests,q)
    places_run(&world.requests,&places,&world.results,core.ref(&world.settings),core.read(&world.worlds),core.read(&world.perceivers),core.read(&world.perceptions),{},core.read(&world.paths),core.read(&world.agents),core.read(&world.characters),core.read(&world.walks),core.read(&world.swims),core.ref(&world.navigation),core.ref(&world.physics),{},{},&problems)
    first,_=core.get(&world.results,a)
    testing.expect(t,first.status==.Found && first.request==4)
}

@(private="file")
Places_Test :: struct {
    using w:Behavior_World,
    places:Places,
    problems:core.Problems,
}

// A query around a target, or measured from it, finds nothing once the
// target is destroyed, and the query of a querier destroyed while it waits
// takes nothing of the budget and gets no answer.
@(test)
places_of_a_target_that_is_destroyed_are_none :: proc(t:^testing.T) {
    f:Places_Test
    if !test_world_init(t,&f.w) {return}
    defer {
        places_free(&f.places)
        test_world_destroy(&f.w)
    }
    querier,target,gone:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    for e,i in ([]core.Entity{querier,target,gone}) {core.add(&f.worlds,e,core.World_Transform{transform={position={f32(i)*5,0,0},rotation=1,scale=1}})}
    test_world_settle(&f.w)
    f.settings=Behavior_Settings{queries=1}
    around:=Place_Query{querier=querier,center=.Target,target=target,layout=.Grid,outer=2,spacing=1,keep=1}
    around.tests[0]={measure=.Distance,from=.Querier,min=0,max=10,response={kind=.Linear,slope=-1,shift_y=1}}
    around.test_count=1
    from:=Place_Query{querier=querier,center=.Querier,layout=.Grid,outer=2,spacing=1,keep=1}
    from.tests[0]={measure=.Distance,from=.Target,target=target,min=0,max=10,response={kind=.Linear,slope=-1,shift_y=1}}
    from.test_count=1
    orphan:=Place_Query{querier=gone,center=.Querier,layout=.Grid,outer=2,spacing=1,keep=1}
    run :: proc(f:^Places_Test) {
        places_run(&f.requests,&f.places,&f.results,core.ref(&f.settings),core.read(&f.worlds),core.read(&f.perceivers),core.read(&f.perceptions),{},core.read(&f.paths),
            core.read(&f.agents),core.read(&f.characters),core.read(&f.walks),core.read(&f.swims),core.ref(&f.navigation),core.ref(&f.physics),Smart_View{objects=core.read(&f.objects),states=core.read(&f.states),worlds=core.read(&f.worlds),claims=core.ref(&f.claims)},{},&f.problems)
        test_world_settle(&f.w)
    }
    place_query(&f.requests,around)
    run(&f)
    result,_:=core.get(&f.results,querier)
    testing.expect(t,result.status==.Found && result.request==1,"around the target while it is there")
    core.destroy(&f.entities,target)
    core.destroy(&f.entities,gone)
    test_world_settle(&f.w)
    place_query(&f.requests,orphan)
    place_query(&f.requests,around)
    run(&f)
    result,_=core.get(&f.results,querier)
    testing.expectf(t,result.request==3 && result.status==.Empty,"around a target that is gone: %v",result)
    place_query(&f.requests,from)
    run(&f)
    result,_=core.get(&f.results,querier)
    testing.expectf(t,result.request==4 && result.status==.Empty,"measured from a target that is gone: %v",result)
    testing.expect_value(t,len(f.places.waiting),0)
    testing.expect_value(t,core.count(&f.results),1)
}

@(test)
the_path_of_places_walks_only_what_the_querier_walks :: proc(t:^testing.T) {
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    world.navigation.classes[0].class=nav.NAVIGATION_SETTINGS_DEFAULT.classes[0]
    world.navigation.count,world.navigation.ready=1,true
    mesh:=&world.navigation.classes[0].mesh
    testing.expect(t,ai.nav_mesh_init(mesh,{tile_width=8,climb=0.3,max_tiles=1}))
    // A square of ground whose half beyond x=4 is under deep water.
    vertices:=[]mm.Vec3{{0,0,0},{4,0,0},{8,0,0},{0,0,8},{4,0,8},{8,0,8}}
    indices:=[]u32{0,1,4,0,4,3,1,2,5,1,5,4}
    data,made:=ai.nav_tile_from_triangles({0,0},{{0,-1e6,0},{8,1e6,8}},vertices,indices)
    for &poly,i in data.polys {if i>=2 {poly.area=u8(nav.AREA_WATER)}}
    testing.expect(t,made && ai.nav_mesh_add_tile(mesh,data))
    walker,swimmer:=core.create(&world.entities),core.create(&world.entities)
    for e in ([]core.Entity{walker,swimmer}) {
        core.add(&world.agents,e,nav.NAV_AGENT_DEFAULT)
        core.add(&world.walks,e,locomotion.Walk{max_speed=4,jump_height=1})
    }
    core.add(&world.swims,swimmer,locomotion.SWIM_DEFAULT)
    test_world_settle(&world)
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
    walking:=place_filter(core.ref(&world.navigation),walker,core.read(&world.paths),core.read(&world.agents),core.read(&world.characters),core.read(&world.walks),core.read(&world.swims),core.ref(&world.physics))
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
    swimming:=place_filter(core.ref(&world.navigation),swimmer,core.read(&world.paths),core.read(&world.agents),core.read(&world.characters),core.read(&world.walks),core.read(&world.swims),core.ref(&world.physics))
    testing.expect(t,swimming.excluded&(1<<u64(nav.AREA_WATER))==0)
    place_paths(&places,origin,candidates,refs[:],mesh,nil,&swimming,measures[:],1)
    testing.expectf(t,abs(measures[0]-linalg.distance(origin,candidates[0]))<1e-3 && abs(measures[1]-linalg.distance(origin,candidates[1]))<1e-3,"a swimmer measures %v",measures)
}

// The points of the mesh around the querier are those joined to where it
// stands: an island across a gap gives none. Entities are candidates too,
// those of the query, the Perceivables of some teams or those the querier
// remembers, and the offers of a use of smart objects; each place found from
// one says which.
@(test)
places_come_from_the_mesh_joined_to_the_center_from_entities_and_from_offers :: proc(t:^testing.T) {
    f:Places_Test
    if !test_world_init(t,&f.w) {return}
    defer {
        places_free(&f.places)
        test_world_destroy(&f.w)
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
    querier,near,far,friend:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    spots:=[4]mm.Vec3{{5,0,2},{3,0,2},{10,0,2},{4,0,1}}
    for e,i in ([]core.Entity{querier,near,far,friend}) {
        at:=spots[i]
        core.add(&f.worlds,e,core.World_Transform{transform={position=at,rotation=1,scale=1}})
    }
    core.add(&f.perceivables,near,Perceivable{team=1})
    core.add(&f.perceivables,far,Perceivable{team=1})
    core.add(&f.perceivables,friend,Perceivable{team=2})
    test_world_settle(&f.w)
    f.settings=Behavior_Settings{queries=4}
    run :: proc(f:^Places_Test,q:Place_Query) -> Place_Result {
        place_query(&f.requests,q)
        places_run(&f.requests,&f.places,&f.results,core.ref(&f.settings),core.read(&f.worlds),core.read(&f.perceivers),core.read(&f.perceptions),core.read(&f.perceivables),core.read(&f.paths),
            core.read(&f.agents),core.read(&f.characters),core.read(&f.walks),core.read(&f.swims),core.ref(&f.navigation),core.ref(&f.physics),Smart_View{objects=core.read(&f.objects),states=core.read(&f.states),worlds=core.read(&f.worlds),claims=core.ref(&f.claims)},{},&f.problems)
        test_world_settle(&f.w)
        result,_:=core.get(&f.results,q.querier)
        return result
    }
    // Farthest from the querier first: on the ground it stands on, never on the island.
    away:=Place_Query{querier=querier,center=.Querier,layout=.Mesh,outer=8,spacing=1,keep=8}
    away.tests[0]={measure=.Distance,from=.Querier,min=0,max=16,response={kind=.Linear,slope=1}}
    away.test_count=1
    result:=run(&f,away)
    testing.expect(t,result.status==.Found && result.count==8)
    for p in result.points[:result.count] {testing.expectf(t,p.x<=6.01 && p.y==0,"%v is on the ground the querier stands on",p)}
    testing.expect(t,linalg.distance(result.points[0],mm.Vec3{5,0,2})>4.5,"the farthest of that ground")
    // The entities given, the nearest first.
    given:=Place_Query{querier=querier,center=.Querier,layout=.Entities,keep=2}
    given.entities[0],given.entities[1]=far,near
    given.entity_count=2
    given.tests[0]={measure=.Distance,from=.Querier,min=0,max=16,response={kind=.Linear,slope=-1,shift_y=1}}
    given.test_count=1
    result=run(&f,given)
    testing.expect(t,result.count==2 && result.entities[0]==near && result.entities[1]==far)
    // The Perceivables of team 1 within 4 m: the friend is of another team, the far one too far.
    seen:=given
    seen.layout,seen.outer,seen.teams,seen.entity_count=.Perceivables,4,Teams(1<<1),0
    result=run(&f,seen)
    testing.expect(t,result.count==1 && result.entities[0]==near && linalg.distance(result.points[0],mm.Vec3{3,0,2})<1e-3)
    // Within 8 m the far one on the island is a Perceivable of team 1 too, but the querier never
    // perceived it: of those it remembers, only the near one, where it last perceived it.
    remembers:Perception
    ai.memory_perceive(&remembers.memory,u64(near),{4,0,1},.Sight,1,0)
    ai.memory_perceive(&remembers.memory,u64(friend),{4,0,1.5},.Sight,1,0)
    // A forged memory: past its capacity, the far one nowhere, and someone made up.
    remembers.memory.items[2]={subject=u64(far),position={transmute(f32)u32(0x7fc00000),0,0},confidence=1}
    remembers.memory.items[3]={subject=1<<50,position={4,0,2},confidence=1}
    remembers.memory.count=99
    core.add(&f.perceptions,querier,remembers)
    test_world_settle(&f.w)
    seen.outer=8
    result=run(&f,seen)
    testing.expect(t,result.count==2 && result.entities[1]==far)
    seen.layout=.Remembered
    result=run(&f,seen)
    testing.expectf(t,result.count==1 && result.entities[0]==near && linalg.distance(result.points[0],mm.Vec3{4,0,1})<1e-3,"remembered: %v",result)
    // The offers of a use within 8 m: of the crate, its second offer, where its user stands; not those of another use.
    crate,box:=core.create(&f.entities),core.create(&f.entities)
    core.add(&f.worlds,crate,core.World_Transform{transform={position={1,0,2},rotation=1,scale=1}})
    core.add(&f.worlds,box,core.World_Transform{transform={position={2,0,2},rotation=1,scale=1}})
    stocked,other:Smart_Object
    stocked.offers[0]={use=2,users=1}
    stocked.offers[1]={use=1,at={0,0,1},users=1}
    other.offers[0]={use=2,users=1}
    core.add(&f.objects,crate,stocked)
    core.add(&f.objects,box,other)
    test_world_settle(&f.w)
    offered:=given
    offered.layout,offered.outer,offered.use,offered.entity_count=.Offers,8,1,0
    result=run(&f,offered)
    testing.expect(t,result.count==1 && result.entities[0]==crate && result.offers[0]==1 && linalg.distance(result.points[0],mm.Vec3{1,0,3})<1e-3)
    testing.expect_value(t,f.problems.count,0)
}

// A ray is cast only for a candidate that the cheaper measures left above
// zero and that can still be among the kept, and the places found are those
// of measuring every test on every candidate.
@(test)
places_cast_rays_only_where_they_can_change_the_answer :: proc(t:^testing.T) {
    f:Places_Test
    if !test_world_init(t,&f.w) {return}
    defer {
        places_free(&f.places)
        test_world_destroy(&f.w)
    }
    if !testing.expect(t,phys.test_state_make(&f.physics)) {return}
    // A wall 2 m ahead of the querier hides some of the places behind it.
    querier,wall:=placed(&f.w,{}),core.create(&f.entities)
    body,_:=phys.owned_body_create(&f.physics,{1,wall,0},{0,2,-2},1)
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    phys.owned_shape_create(&f.physics,&collision,body,{collider=phys.collider_box({1.2,2,0.1}),rotation=1})
    test_world_settle(&f.w)
    _,blocked:=phys.raycast(core.ref(&f.physics),{0,1.6,0},{0,-0.1,-1},4)
    testing.expect(t,blocked,"the wall blocks the way")
    falling:=ai.Response{kind=.Linear,slope=-1,shift_y=1}
    rising:=ai.Response{kind=.Linear,slope=1}
    Case :: struct {keep:u8,visible:ai.Response,fewer:bool} // fewer: rays than places near enough
    cases:=[]Case{{8,falling,false},{8,rising,false},{1,falling,true},{1,rising,true}}
    for c in cases {
        // Within 3 m of a point behind the wall, hidden from the querier or seen by it.
        q:=Place_Query{querier=querier,center=.Querier,layout=.Grid,outer=4,spacing=1,keep=c.keep}
        q.tests[0]={measure=.Visible,from=.Querier,min=0,max=1,response=c.visible}
        q.tests[1]={measure=.Distance,from=.Point,point={0,0,-4},min=0,max=3,response=falling}
        q.test_count=2
        result:Place_Result
        filter:ai.Nav_Filter
        evals,_:=place_run(&f.places,q,&result,core.read(&f.worlds),core.read(&f.perceivers),core.read(&f.perceptions),core.read(&f.perceivables),core.read(&f.paths),core.ref(&f.navigation),core.ref(&f.physics),&filter,{},core.read(&f.agents),nil)
        // Every test measured on every candidate, scored all at once.
        points:[PLACE_CANDIDATES]mm.Vec3
        count:=ai.places_grid({},4,1,points[:])
        inputs:[PLACE_CANDIDATES*2]f32
        near:=0
        for p,i in points[:count] {
            for test,k in q.tests[:2] {
                from:=mm.Transform{position=test.point,rotation=1,scale=1}
                inputs[i*2+k]=place_measure(test,from,p,querier,core.read(&f.perceivers),core.ref(&f.physics),nil)
            }
            if linalg.distance(p,mm.Vec3{0,0,-4})<3 {near+=1}
        }
        rule:=[2]ai.Consideration{{input=0,min=0,max=1,response=c.visible},{input=1,min=0,max=3,response=falling}}
        best:[PLACE_KEPT]ai.Place_Score
        kept:=ai.places_best(rule[:],inputs[:count*2],2,best[:c.keep])
        testing.expectf(t,kept>0 && int(result.count)==kept,"keep %d: %d places, %d expected",c.keep,result.count,kept)
        for b,i in best[:kept] {
            testing.expectf(t,result.points[i]==points[b.index] && result.scores[i]==b.score,"keep %d: place %d is %v %v, %v %v expected",c.keep,i,result.points[i],result.scores[i],points[b.index],b.score)
        }
        testing.expectf(t,evals<=near && (!c.fewer || evals<near),"keep %d: %d rays for %d places near enough",c.keep,evals,near)
    }
}

// Asked to explain, a query gives the same answer and every candidate with
// each test it measured: the vetoing test is the first that scored 0, and one
// a cheaper test vetoed takes no ray.
@(test)
a_query_explains_each_candidate_and_the_test_that_vetoed_it :: proc(t:^testing.T) {
    f:Places_Test
    if !test_world_init(t,&f.w) {return}
    defer {
        places_free(&f.places)
        test_world_destroy(&f.w)
    }
    if !testing.expect(t,phys.test_state_make(&f.physics)) {return}
    querier,wall:=placed(&f.w,{}),core.create(&f.entities)
    body,_:=phys.owned_body_create(&f.physics,{1,wall,0},{0,2,-2},1)
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    phys.owned_shape_create(&f.physics,&collision,body,{collider=phys.collider_box({1.2,2,0.1}),rotation=1})
    test_world_settle(&f.w)
    falling:=ai.Response{kind=.Linear,slope=-1,shift_y=1}
    // Near the querier, seen by it and near a point behind the wall: two cheap tests around a ray.
    q:=Place_Query{querier=querier,center=.Querier,layout=.Grid,outer=4,spacing=1,keep=2}
    q.tests[0]={measure=.Distance,from=.Querier,min=0,max=3,response=falling}
    q.tests[1]={measure=.Visible,from=.Querier,min=0,max=1,response={kind=.Linear,slope=1}}
    q.tests[2]={measure=.Distance,from=.Point,point={0,0,-3},min=0,max=3,response=falling}
    q.test_count=3
    run :: proc(f:^Places_Test,q:Place_Query,result:^Place_Result,explain:^Place_Explain) -> int {
        filter:ai.Nav_Filter
        evals,_:=place_run(&f.places,q,result,core.read(&f.worlds),core.read(&f.perceivers),core.read(&f.perceptions),core.read(&f.perceivables),core.read(&f.paths),core.ref(&f.navigation),core.ref(&f.physics),&filter,{},core.read(&f.agents),nil,explain)
        return evals
    }
    plain,explained:Place_Result
    explain:Place_Explain
    evals:=run(&f,q,&plain,nil)
    testing.expect(t,run(&f,q,&explained,&explain)==evals && explained==plain,"explaining changes nothing of the answer")
    points:[PLACE_CANDIDATES]mm.Vec3
    testing.expectf(t,explain.count==ai.places_grid({},4,1,points[:]),"%d candidates explained",explain.count)
    first_of_two,cheap_veto,ray_veto,kept:=false,false,false,0
    for e in explain.candidates[:explain.count] {
        first:=i8(-1)
        for k in 0..<3 {if k in e.measured && e.responses[k]==0 {first=i8(k);break}}
        testing.expectf(t,e.veto==first && (e.fate==.Vetoed)==(first>=0),"%v: veto %d, the first test with response 0 is %d",e.point,e.veto,first)
        testing.expectf(t,1 in e.measured || e.fate==.Vetoed || e.fate==.Below,"%v: %v without its ray",e.point,e.fate)
        first_of_two|=e.veto==0 && 2 in e.measured && e.responses[2]==0
        cheap_veto|=e.veto==2 && 1 not_in e.measured
        ray_veto|=e.veto==1
        if e.fate==.Kept {kept+=1}
    }
    testing.expect(t,first_of_two && cheap_veto && ray_veto && kept==int(plain.count))
}

@(private="file")
Smart_Act :: enum u8 {Use}

// An offer is open to the agents of its teams with its abilities, to as many
// at once as it takes, as many times as it lasts and once its cooldown
// passed; the nearest open one is found, and one claimed is open again for
// others once its holder exits.
@(test)
smart_objects_offer_their_uses_to_whom_may_take_them :: proc(t:^testing.T) {
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    USE_AMMO :: Smart_Use(1)
    USE_TURRET :: Smart_Use(2)
    crate,far_crate,turret,a,b:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    for e,i in ([]core.Entity{crate,far_crate,turret}) {
        core.add(&world.worlds,e,core.World_Transform{transform={position={f32(i)*10,0,0},rotation=1,scale=1}})
    }
    ammo:Smart_Object
    ammo.offers[0]={use=USE_AMMO,at={0,0,1},users=1,uses=2,cooldown=5,teams=Teams(1<<1)}
    core.add(&world.objects,crate,ammo)
    core.add(&world.objects,far_crate,ammo)
    gun:Smart_Object
    gun.offers[0]={use=USE_TURRET,users=1,abilities=nav.Nav_Abilities(1<<u32(nav.ABILITY_CLIMB))}
    core.add(&world.objects,turret,gun)
    test_world_settle(&world)
    smart_update(core.read(&world.objects),&world.states,&world.uses,{seconds=0})
    test_world_settle(&world)
    v:=Mind_World{objects=core.read(&world.objects),states=core.read(&world.states),worlds=core.read(&world.worlds),claims=&world.claims,time=clock_at(60,1.0/60)}
    looks:=ai.Mind_Context{user=&v}
    red:=Smart_User{entity=a,team=1}
    blue:=Smart_User{entity=b,team=2}
    found,ok:=smart_offer(&looks,crate,USE_AMMO,red)
    testing.expect(t,ok && found.offer==0 && found.users==1 && found.at=={0,0,1})
    _,ok=smart_offer(&looks,crate,USE_AMMO,blue)
    testing.expect(t,!ok,"of another team")
    _,ok=smart_offer(&looks,turret,USE_TURRET,red)
    testing.expect(t,!ok,"without the ability")
    _,ok=smart_offer(&looks,turret,USE_TURRET,{entity=a,abilities=nav.Nav_Abilities(1<<u32(nav.ABILITY_CLIMB))})
    testing.expect(t,ok)
    nearest,near_ok:=smart_nearest(&looks,USE_AMMO,{12,0,0},20,red)
    testing.expect(t,near_ok && nearest.object==far_crate)
    _,near_ok=smart_nearest(&looks,USE_AMMO,{30,0,0},5,red)
    testing.expect(t,!near_ok,"none within the radius")
    // Claimed by one, closed to the other until the holder exits.
    m:ai.Mind
    ctx:=ai.Mind_Context{tick=1,holder=u64(a),reservations=&world.claims.reservations}
    act:=ai.Act(Smart_Act){ctx=&ctx,mind=&m,frame=&m.main}
    testing.expect(t,smart_claim(&act,found))
    other:=Smart_User{entity=core.create(&world.entities),team=1}
    _,ok=smart_offer(&looks,crate,USE_AMMO,other)
    testing.expect(t,!ok,"claimed")
    _,ok=smart_offer(&looks,crate,USE_AMMO,red)
    testing.expect(t,ok,"its own")
    ai.reserve_release(&world.claims.reservations,m.main.reserved,u64(a))
    _,ok=smart_offer(&looks,crate,USE_AMMO,other)
    testing.expect(t,ok)
    // Used: closed until its cooldown passes, as long at 60 as at 120 Hz; spent after its uses.
    for hz in ([]f64{60,120}) {
        core.edit(&world.states,crate)^={}
        smart_used(&world.uses,found)
        smart_update(core.read(&world.objects),&world.states,&world.uses,clock_at(hz,1))
        test_world_settle(&world)
        v.time=clock_at(hz,5.95)
        _,ok=smart_offer(&looks,crate,USE_AMMO,red)
        testing.expectf(t,!ok,"cooling down at %v Hz",hz)
        v.time=clock_at(hz,6)
        _,ok=smart_offer(&looks,crate,USE_AMMO,red)
        testing.expectf(t,ok,"cooled down at %v Hz",hz)
    }
    smart_used(&world.uses,found)
    smart_update(core.read(&world.objects),&world.states,&world.uses,clock_at(60,6))
    test_world_settle(&world)
    v.time=clock_at(60,100)
    _,ok=smart_offer(&looks,crate,USE_AMMO,red)
    testing.expect(t,!ok,"spent")
    // One that walks to a kit walks after it as it moves, and fails once it is destroyed.
    USE_HEAL :: Smart_Use(3)
    kit,walker:=placed(&world,{0,0,20}),placed(&world,{0,0,15})
    heal:Smart_Object
    heal.offers[0]={use=USE_HEAL,users=1}
    core.add(&world.objects,kit,heal)
    core.add(&world.paths,walker,nav.Nav_Path{class=-1})
    core.test_world_settle(&world)
    smart_update(core.read(&world.objects),&world.states,&world.uses,v.time)
    core.test_world_settle(&world)
    v.requests,v.paths=&world.moves,core.read(&world.paths)
    walks:ai.Mind
    memory:[ai.MIND_WORDS]u64
    walking:=ai.Mind_Context{user=&v,tick=v.time.tick,dt=v.time.dt,holder=u64(walker),reservations=&world.claims.reservations}
    act=ai.Act(Smart_Act){ctx=&walking,mind=&walks,frame=&walks.main,phase=.Enter,memory=memory[:]}
    healer:=Smart_User{entity=walker}
    asked :: proc(world:^Behavior_World) -> nav.Nav_Request {return world.moves.queue.items[len(world.moves.queue.items)-1]}
    status,taken:=offer_act(&act,USE_HEAL,healer,10,1)
    testing.expect(t,status==.Running && taken.object==kit && asked(&world).kind==.Move_To && asked(&world).point==taken.at)
    core.edit(&world.paths,walker)^={state=.Moving,goal=taken.at,class=-1}
    act.phase=.Update
    requests:=len(world.moves.queue.items)
    status,_=offer_act(&act,USE_HEAL,healer,10,1)
    testing.expect(t,status==.Running && len(world.moves.queue.items)==requests)
    core.edit(&world.worlds,kit).position={3,0,20}
    core.test_world_settle(&world)
    status,_=offer_act(&act,USE_HEAL,healer,10,1)
    testing.expect(t,status==.Running && asked(&world).kind==.Move_To && asked(&world).point==[3]f32{3,0,20},"it walks to where the kit is now")
    core.destroy(&world.entities,kit)
    core.test_world_settle(&world)
    status,_=offer_act(&act,USE_HEAL,healer,10,1)
    testing.expect_value(t,status,ai.Status.Failure)
}

// The influence of each team is where its Perceivables are, less farther
// away; without a cell, or with nobody to stamp or read them, there is no map.
@(test)
influence_maps_follow_the_teams :: proc(t:^testing.T) {
    world:Behavior_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    influence:Influence
    defer influence_free(&influence)
    world.settings.influence_size,world.settings.influence_cells,world.settings.influence_rays=32,32*32*INFLUENCE_TEAMS,0
    calls:=0
    // A world with nobody to stamp the maps or to read them makes none: its ticks ask for no memory and leave no pass begun.
    for tick in 0..<3 {
        saved:=context.allocator
        context.allocator=refusing_allocator(&calls)
        influence_update(&influence,core.ref(&world.settings),core.read(&world.perceivables),core.read(&world.perceivers),core.read(&world.mind_agents),core.read(&world.results),core.read(&world.worlds),core.ref(&world.physics),{tick=u64(tick),dt=1.0/60,playing=true})
        context.allocator=saved
    }
    testing.expect_value(t,calls,0)
    testing.expect(t,!ai.influence_ready(&influence.grid) && influence.made=={} && influence.sweep==0)
    // A reader alone has them made.
    reader:=core.create(&world.entities)
    core.add(&world.perceivers,reader,Perceiver{})
    test_world_settle(&world)
    influence_update(&influence,core.ref(&world.settings),core.read(&world.perceivables),core.read(&world.perceivers),core.read(&world.mind_agents),core.read(&world.results),core.read(&world.worlds),core.ref(&world.physics),{tick=3,dt=1.0/60,playing=true})
    testing.expect(t,ai.influence_ready(&influence.grid))
    core.remove(&world.perceivers,reader)
    test_world_settle(&world)
    influence_update(&influence,core.ref(&world.settings),core.read(&world.perceivables),core.read(&world.perceivers),core.read(&world.mind_agents),core.read(&world.results),core.read(&world.worlds),core.ref(&world.physics),{tick=4,dt=1.0/60,playing=true})
    testing.expect(t,!ai.influence_ready(&influence.grid),"the maps nobody reads any more are freed")
    red,blue:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.perceivables,red,Perceivable{team=1})
    core.add(&world.perceivables,blue,Perceivable{team=2})
    core.add(&world.worlds,red,core.World_Transform{transform={position={-10,0,0},rotation=1,scale=1}})
    core.add(&world.worlds,blue,core.World_Transform{transform={position={10,0,0},rotation=1,scale=1}})
    test_world_settle(&world)
    for tick in 0..<20 {
        // Made on the first tick; the others do not allocate.
        saved:=context.allocator
        if tick>0 {context.allocator=refusing_allocator(&calls)}
        influence_update(&influence,core.ref(&world.settings),core.read(&world.perceivables),core.read(&world.perceivers),core.read(&world.mind_agents),core.read(&world.results),core.read(&world.worlds),core.ref(&world.physics),{tick=u64(tick),dt=1.0/60,playing=true})
        context.allocator=saved
    }
    testing.expect_value(t,calls,0)
    reds:=Teams(1<<1)
    testing.expect(t,influence_at(&influence,{-10,0,0},reds)>0.5)
    testing.expect(t,influence_at(&influence,{-10,0,0},reds)>influence_at(&influence,{-4,0,0},reds))
    testing.expect(t,influence_at(&influence,{10,0,0},reds)<0.05 && influence_at(&influence,{10,0,0},Teams(1<<2))>0.5)
    testing.expect(t,influence_at(&influence,{-10,0,0},reds|Teams(1<<2))>=influence_at(&influence,{-10,0,0},reds))
    testing.expect_value(t,cover_at(&influence,{-10,0,0},{10,0,0}),0)
    world.settings.influence_cell=0
    influence_update(&influence,core.ref(&world.settings),core.read(&world.perceivables),core.read(&world.perceivers),core.read(&world.mind_agents),core.read(&world.results),core.read(&world.worlds),core.ref(&world.physics),{tick=20,dt=1.0/60,playing=true})
    testing.expect_value(t,influence_at(&influence,{-10,0,0},reds),0)
}

// Random crowds of perceivers and perceivables, near and far apart, on both
// sides of the origin: what each remembers after a look through the grid is
// what looking at every perceivable in the order of their table gives, with
// rays for all and with rays for a few.
@(test)
perceivers_find_by_the_grid_whom_they_would_among_every_perceivable :: proc(t:^testing.T) {
    round :: proc(t:^testing.T,seed:u64,spread:f32,rays:i32) {
        f:Sight_World
        if !test_world_init(t,&f.behavior) {return}
        defer sight_world_destroy(&f)
        f.settings.rays=rays
        rng:=mm.rng_make(seed)
        somewhere :: proc(rng:^mm.Rng,spread:f32) -> mm.Vec3 {
            return {mm.random_range(rng,-spread,spread),mm.random_range(rng,-3,3),mm.random_range(rng,-spread,spread)}
        }
        for i in 0..<70 {
            e:=core.create(&f.entities)
            pose:=mm.Transform{position=somewhere(&rng,spread),rotation=mm.quat_axis_angle({0,1,0},mm.random_range(&rng,-4,4)),scale=1}
            core.add(&f.worlds,e,core.World_Transform{transform=pose})
            if i%3!=0 {core.add(&f.perceivables,e,Perceivable{team=Team(i%4),point=mm.random_range(&rng,0,2)})}
            if i%2==0 {
                watch:=PERCEIVER_DEFAULT
                watch.sight=mm.random_range(&rng,2,70)
                watch.angle=mm.random_range(&rng,0.2,3.5)
                watch.notices=Teams(1+u32(mm.random_range(&rng,0,15)))
                core.add(&f.perceivers,e,watch)
            }
        }
        sight_tick(&f,0) // gives them their Perception
        sight_tick(&f,0.1)
        left:=int(rays)
        seen:=0
        for row in 0..<core.count(&f.perceivers) {
            e:=core.entity_at(&f.perceivers,row)
            p:=f.perceivers.values[row]
            pose:=core.edit(&f.worlds,e)
            eye:=pose.position+mm.Vec3{0,p.eyes,0}
            expected:[ai.PERCEPTION_CAPACITY]core.Entity
            count,total:=0,0
            for target in 0..<core.count(&f.perceivables) {
                if left<=0 {break}
                subject:=core.entity_at(&f.perceivables,target)
                other:=f.perceivables.values[target]
                at:=core.edit(&f.worlds,subject)
                if subject==e || u32(p.notices)&(1<<u32(other.team))==0 || !ai.sight_in_cone(eye,mm.quat_forward(pose.rotation),at.position+mm.Vec3{0,other.point,0},p.sight,p.angle) {continue}
                left-=1
                total+=1
                if count<len(expected) {expected[count]=subject;count+=1}
            }
            seen+=total
            mine:=core.edit(&f.perceptions,e)
            if !testing.expect(t,mine!=nil) {return}
            testing.expectf(t,int(mine.memory.count)==count,"seed %d: perceiver %d remembers %d of the %d it sees",seed,row,mine.memory.count,total)
            for subject in expected[:count] {testing.expectf(t,ai.memory_find(&mine.memory,u64(subject))!=nil,"seed %d: perceiver %d does not remember %v, which it sees",seed,row,subject)}
        }
        testing.expectf(t,seen>10,"seed %d: the perceivers see %d in all: the scene shows little",seed,seen)
        testing.expect_value(t,f.problems.count,0)
    }
    spreads:=[?]f32{6,25,60,150,25,60}
    for spread,i in spreads {round(t,u64(40+i),spread,1<<20 if i<4 else 45)}
}

// With nobody to look at or hear and nothing remembered, perception looks at
// no perceiver and makes no grid; with no request and none waiting, the
// places touch nothing; and the smart objects are gone through only when
// their table or that of their states changed.
@(test)
a_tick_with_nothing_to_do_goes_through_no_row :: proc(t:^testing.T) {
    f:Sight_World
    if !test_world_init(t,&f.behavior) {return}
    defer sight_world_destroy(&f)
    guard:=placed(&f,{})
    watch:=PERCEIVER_DEFAULT
    watch.forget=1
    core.add(&f.perceivers,guard,watch)
    sight_tick(&f,0)
    sight_tick(&f,0.1)
    testing.expect(t,len(f.sight.grid.items)==0 && cap(f.sight.rows)==0 && f.turns.remembering==0)
    // A memory forged behind its back would be forgotten by a tick that looked at the perceiver.
    ghost:=u64(1<<40)
    ai.memory_perceive(&core.edit(&f.perceptions,guard).memory,ghost,{},.Sight,1,0)
    sight_tick(&f,50)
    testing.expect(t,ai.memory_find(&core.edit(&f.perceptions,guard).memory,ghost)!=nil && len(f.sight.grid.items)==0)
    ai.memory_remove(&core.edit(&f.perceptions,guard).memory,ghost)
    // Someone to look at, a noise or a memory: it works again, and the count of memories follows.
    target:=placed(&f,{0,0,-5})
    core.add(&f.perceivables,target,Perceivable{point=1})
    sight_tick(&f,60)
    mine:=core.edit(&f.perceptions,guard)
    testing.expect(t,ai.memory_find(&mine.memory,u64(target))!=nil && f.turns.remembering==1 && len(f.sight.grid.items)>0)
    core.remove(&f.perceivables,target)
    sight_tick(&f,60.1)
    testing.expect_value(t,f.turns.remembering,1)
    sight_tick(&f,70)
    testing.expect(t,core.edit(&f.perceptions,guard).memory.count==0 && f.turns.remembering==0)
    noise(&f.noises,{position={0,0,2},loudness=10})
    sight_tick(&f,71)
    testing.expect_value(t,f.turns.remembering,1)

    // No request and none waiting: no table is looked at, the results least of all.
    places:Places
    places_run(&f.requests,&places,nil,{},{},{},{},{},{},{},{},{},{},{},{},{},{},nil)

    // The objects get their state when they come; a tick after, with the tables as they were, none is gone through.
    box:=placed(&f,{})
    core.add(&f.objects,box,Smart_Object{})
    test_world_settle(&f.behavior)
    smart_update(core.read(&f.objects),&f.states,&f.uses,{seconds=0})
    test_world_settle(&f.behavior)
    testing.expect(t,core.has(&f.states,box))
    smart_update(core.read(&f.objects),&f.states,&f.uses,{seconds=1})
    test_world_settle(&f.behavior)
    shapes:=f.uses.shapes
    testing.expect(t,!core.reshaped(&f.objects,&shapes[0]) && !core.reshaped(&f.states,&shapes[1]))
    // One without its state is not looked for while the tables say nothing changed.
    other:=placed(&f,{})
    core.add(&f.objects,other,Smart_Object{})
    test_world_settle(&f.behavior)
    changed:=f.uses.shapes
    _=core.reshaped(&f.objects,&f.uses.shapes[0]) | core.reshaped(&f.states,&f.uses.shapes[1])
    smart_update(core.read(&f.objects),&f.states,&f.uses,{seconds=2})
    test_world_settle(&f.behavior)
    testing.expect(t,!core.has(&f.states,other))
    f.uses.shapes=changed
    smart_update(core.read(&f.objects),&f.states,&f.uses,{seconds=3})
    test_world_settle(&f.behavior)
    testing.expect(t,core.has(&f.states,other))
}
