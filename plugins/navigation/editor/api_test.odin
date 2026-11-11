package navigation_editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/ai"
import "mirai:std/serial"
import nav "plugins:navigation/runtime"

@(private)
@(test_world)
Agent_World :: struct {
    using world:Test_World,
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
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    session:=editor.Session{info=test_world_info(&world),edit_world=&world}
    e:=core.create(&world.entities)
    core.add(&world.ids,e,core.Id{7})
    core.add(&world.agents,e,nav.NAV_AGENT_DEFAULT)
    path:=nav.NAV_PATH_DEFAULT
    path.state,path.goal=.Moving,{30,0,0}
    core.add(&world.paths,e,path)
    far:=nav.Nav_Far{count=2,next=1,speed=3,complete=true}
    far.route[0],far.route[1]={10,0,0},{30,0,0}
    core.add(&world.fars,e,far)
    test_world_settle(&world)
    core.disable(&world.agents,e);core.disable(&world.paths,e);core.disable(&world.fars,e)
    test_world_settle(&world)
    testing.expect(t,!core.has(&world.agents,e))
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    params:Agent_Params;copy(params.entity[:],"0000000000000007")
    method:=api.Method{params_id=Agent_Params}
    call:=api.Call{method=&method,params=&params,out=&out,allocator=context.temp_allocator}
    agent(&session,&call)
    testing.expect(t,!call.failed,call.error.message)
    text:=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,`"state":"Moving"`) && strings.contains(text,`"far":true`),"%s",text)
    testing.expectf(t,strings.contains(text,`"position":[30,0,0]`) && !strings.contains(text,`"position":[10,0,0]`),"%s",text)
}

// The way a drive takes is the first corner past where the body stands, with
// what is left of it; little left, the drive goes on by itself.
@(test)
a_route_is_the_next_corner_and_what_is_left :: proc(t:^testing.T) {
    corners:=[3]ai.Nav_Corner{{position={0.1,0,0}},{position={4,0,0}},{position={4,0,3}}}
    route:=route_of(corners[:],{})
    testing.expect_value(t,route.state,editor.Route_State.Found)
    testing.expect_value(t,route.next,[3]f32{4,0,0})
    testing.expectf(t,abs(route.left-7)<1e-3,"%v",route.left)
    near:=[1]ai.Nav_Corner{{position={0.1,0,0}}}
    testing.expect_value(t,route_of(near[:],{}).state,editor.Route_State.None)
    testing.expect_value(t,route_of(nil,{}).state,editor.Route_State.None)
}
