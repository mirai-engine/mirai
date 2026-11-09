package navigation_editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/serial"
import nav "plugins:navigation/runtime"

@(private="file")
Agent_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    agents:core.Table(nav.Nav_Agent),
    paths:core.Table(nav.Nav_Path),
    fars:core.Table(nav.Nav_Far),
    navigation:nav.Navigation,
}

// An agent far from the players is off, with its rows: nav.agent finds it,
// says it is far and lists what is left of its route.
@(test)
nav_agent_tells_what_a_far_agent_does :: proc(t:^testing.T) {
    world:Agent_World
    core.entities_init(&world.entities);defer core.entities_destroy(&world.entities)
    core.table_init(&world.ids,"Id");defer core.table_destroy(&world.ids)
    core.table_init(&world.agents,"Nav_Agent");defer core.table_destroy(&world.agents)
    core.table_init(&world.paths,"Nav_Path");defer core.table_destroy(&world.paths)
    core.table_init(&world.fars,"Nav_Far");defer core.table_destroy(&world.fars)
    tables:=[4]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Agent_World,ids)},
        {name="Nav_Agent",type=nav.Nav_Agent,info=type_info_of(nav.Nav_Agent),offset=offset_of(Agent_World,agents)},
        {name="Nav_Path",type=nav.Nav_Path,info=type_info_of(nav.Nav_Path),offset=offset_of(Agent_World,paths)},
        {name="Nav_Far",type=nav.Nav_Far,info=type_info_of(nav.Nav_Far),offset=offset_of(Agent_World,fars)},
    }
    storages:=[1]core.Storage_Info{{name="Navigation",type=nav.Navigation,info=type_info_of(nav.Navigation),place=.World,offset=offset_of(Agent_World,navigation)}}
    info:=core.World_Info{entities=offset_of(Agent_World,entities),tables=tables[:],storages=storages[:]}
    session:=editor.Session{info=&info,edit_world=&world}
    e:=core.create(&world.entities)
    core.add(&world.ids,e,core.Id{7})
    core.add(&world.agents,e,nav.NAV_AGENT_DEFAULT)
    path:=nav.NAV_PATH_DEFAULT
    path.state,path.goal=.Moving,{30,0,0}
    core.add(&world.paths,e,path)
    far:=nav.Nav_Far{count=2,next=1,speed=3,complete=true}
    far.route[0],far.route[1]={10,0,0},{30,0,0}
    core.add(&world.fars,e,far)
    core.table_settle(&world.ids,&world.entities)
    core.table_settle(&world.agents,&world.entities)
    core.table_settle(&world.paths,&world.entities)
    core.table_settle(&world.fars,&world.entities)
    core.disable(&world.agents,e);core.disable(&world.paths,e);core.disable(&world.fars,e)
    core.table_settle(&world.agents,&world.entities)
    core.table_settle(&world.paths,&world.entities)
    core.table_settle(&world.fars,&world.entities)
    core.entities_settle(&world.entities)
    testing.expect(t,!core.has(&world.agents,e))
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    params:=Agent_Params{entity=7}
    method:=api.Method{params_id=Agent_Params}
    call:=api.Call{method=&method,params=&params,out=&out,allocator=context.temp_allocator}
    agent(&session,&call)
    testing.expect(t,!call.failed,call.error.message)
    text:=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,`"state":"Moving"`) && strings.contains(text,`"far":true`),"%s",text)
    testing.expectf(t,strings.contains(text,`"position":[30,0,0]`) && !strings.contains(text,`"position":[10,0,0]`),"%s",text)
}

// A walk ends as its agent does, stuck when it moves without getting anywhere
// for a while, and never while it searches or crosses a link.
@(test)
a_walk_ends_arrived_failed_stopped_or_stuck :: proc(t:^testing.T) {
    ends:=[?]struct{state:nav.Nav_State,ended:Walk_State}{{.Arrived,.Arrived},{.Failed,.Failed},{.Idle,.Stopped}}
    for c in ends {
        w:Walk_Watch
        ended,done:=walk_watch(&w,c.state,{},0)
        testing.expect(t,done && ended==c.ended)
    }
    w:Walk_Watch
    tick :: 1.0/60
    seconds:f64
    for i in 0..<int(WALK_STUCK_SECONDS*60) {
        _,done:=walk_watch(&w,.Moving,{f32(i)*0.1,0,0},seconds)
        testing.expect(t,!done,"it gets somewhere")
        seconds+=tick
    }
    for state in ([2]nav.Nav_State{.Waiting,.Crossing}) {
        for _ in 0..<int(WALK_STUCK_SECONDS*90) {
            _,done:=walk_watch(&w,state,{0,0,0},seconds)
            testing.expect(t,!done,"a search or a crossing is not stuck")
            seconds+=tick
        }
    }
    stuck:=0
    for i in 0..<int(WALK_STUCK_SECONDS*90) {
        ended,done:=walk_watch(&w,.Moving,{0.001*f32(i),0,0},seconds)
        seconds+=tick
        if done {testing.expect_value(t,ended,Walk_State.Stuck);stuck=i;break}
    }
    testing.expectf(t,stuck>=int(WALK_STUCK_SECONDS*60)-1 && stuck<=int(WALK_STUCK_SECONDS*60)+1,"stuck after %d ticks",stuck)
}
