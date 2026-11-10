package navigation_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/ai"
import nav "plugins:navigation/runtime"

@(private="file")
Agent_World :: struct {
    using world:core.Test_World,
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
    if !core.test_world_init(t,&world,nav.test_types) {return}
    defer core.test_world_destroy(&world)
    session:=editor.Session{info=core.test_world_info(&world),edit_world=&world}
    e:=core.create(&world.entities)
    core.add(&world.ids,e,core.Id{7})
    core.add(&world.agents,e,nav.NAV_AGENT_DEFAULT)
    path:=nav.NAV_PATH_DEFAULT
    path.state,path.goal=.Moving,{30,0,0}
    core.add(&world.paths,e,path)
    far:=nav.Nav_Far{count=2,next=1,speed=3,complete=true}
    far.route[0],far.route[1]={10,0,0},{30,0,0}
    core.add(&world.fars,e,far)
    core.test_world_settle(&world)
    core.disable(&world.agents,e);core.disable(&world.paths,e);core.disable(&world.fars,e)
    core.test_world_settle(&world)
    testing.expect(t,!core.has(&world.agents,e))
    params:Agent_Params;copy(params.entity[:],"0000000000000007")
    result:Nav_Agent_Result
    method:=api.Method{params_id=Agent_Params,result_id=Nav_Agent_Result}
    call:=api.Call{method=&method,params=&params,result=&result,allocator=context.temp_allocator}
    agent(&session,&call)
    testing.expect(t,!call.failed,call.error.message)
    testing.expectf(t,result.state=="Moving" && result.far,"%v",result)
    testing.expectf(t,len(result.corners)==1 && result.corners[0].position=={30,0,0},"%v",result.corners)
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

// What git and the tools know of the kinds of the plugin without loading it.
@(test)
the_manifest_declares_the_asset_kinds_the_plugin_registers :: proc(t:^testing.T) {
    m,error:=project.plugin_read(#directory+"../plugin.mirai")
    testing.expect_value(t,error.code,project.Error_Code.None)
    testing.expect_value(t,editor.asset_kinds_differ(NAV_KINDS_DEFAULT.provider,&m),"")
}
