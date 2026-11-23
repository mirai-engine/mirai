package navigation_editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"

@(private)
@(test_world,host="Agent_Shared")
Agent_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    agents:core.Table(nav.Nav_Agent),
    paths:core.Table(nav.Nav_Path),
    fars:core.Table(nav.Nav_Far),
    navigation:nav.Navigation,
}

@(private)
Agent_Shared :: struct {run:core.By_World(nav.Navigation_Agents),problems:core.By_World(core.Problems)}

// What the application keeps for the world of a test: its agents' routes and its problems.
@(private)
Agent_App :: struct {app:host.App,shared:Agent_Shared,run:nav.Navigation_Agents,problems:core.Problems}

@(private)
agent_app_open :: proc(a:^Agent_App,world:^Agent_World) {
    a.app={info=test_world_info(world),shared=&a.shared,allocator=context.allocator}
    append(&a.app.worlds,host.World_Slot{data=world,generation=1})
    append(&a.shared.run.entries,core.By_World_Entry(nav.Navigation_Agents){world={0,1},value=&a.run})
    append(&a.shared.problems.entries,core.By_World_Entry(core.Problems){world={0,1},value=&a.problems})
}

@(private)
agent_app_close :: proc(a:^Agent_App) {
    core.entity_map_destroy(&a.run.routes)
    delete(a.shared.run.entries)
    delete(a.shared.problems.entries)
    delete(a.app.worlds)
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

// An agent that failed, or stops short, says why: the problems navigation reported on it, and
// not those of others; one that walks a whole path has no note.
@(test)
nav_agent_notes_the_problems_of_a_failed_agent :: proc(t:^testing.T) {
    world:Agent_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    a:=new(Agent_App);defer free(a)
    agent_app_open(a,&world)
    defer agent_app_close(a)
    session:=editor.Session{info=test_world_info(&world),edit_world=&world,app=&a.app}
    failed,walking,other,short:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    for e,i in ([]core.Entity{failed,walking,other,short}) {
        core.add(&world.ids,e,core.Id{base.Entity_Id(i+1)})
        core.add(&world.agents,e,nav.NAV_AGENT_DEFAULT)
        path:=nav.NAV_PATH_DEFAULT
        path.state=.Failed if e==failed else .Moving
        path.partial=e==short
        core.add(&world.paths,e,path)
    }
    test_world_settle(&world)
    core.report(&a.problems,failed,"navigation.goal_off_mesh","The goal is not near the mesh")
    core.report(&a.problems,failed,"physics.other","Not of navigation")
    core.report(&a.problems,other,"navigation.off_mesh","Not this agent")
    core.report(&a.problems,walking,"navigation.blocked","Blocked once, walks now")
    note :: proc(t:^testing.T,session:^editor.Session,id:string) -> string {
        params:Agent_Params;copy(params.entity[:],id)
        result:Nav_Agent_Result
        method:=api.Method{params_id=Agent_Params,result_id=Nav_Agent_Result}
        call:=api.Call{method=&method,params=&params,result=&result,allocator=context.temp_allocator}
        agent(session,&call)
        testing.expect(t,!call.failed,call.error.message)
        return result.note
    }
    text:=note(t,&session,"0000000000000001")
    testing.expectf(t,strings.has_prefix(text,"no path toward the goal") && strings.has_suffix(text,"; navigation.goal_off_mesh: The goal is not near the mesh"),"failed: %q",text)
    testing.expect_value(t,note(t,&session,"0000000000000002"),"")
    short_note:=note(t,&session,"0000000000000004")
    testing.expectf(t,strings.has_prefix(short_note,"its path ends short of the goal") && !strings.contains(short_note,"navigation."),"partial: %q",short_note)
}

// The overlay navigation of capture draws the mesh and the path of every agent, selected or not.
@(test)
the_navigation_overlay_draws_the_mesh_and_the_paths_of_the_agents :: proc(t:^testing.T) {
    world:Agent_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    a:=new(Agent_App);defer free(a)
    agent_app_open(a,&world)
    defer agent_app_close(a)
    session:=editor.Session{info=test_world_info(&world),edit_world=&world,app=&a.app}
    testing.expect_value(t,NAVIGATION_CAPTURE_DEFAULT.provider.name,"navigation")
    n:=&world.navigation
    mesh:=&n.classes[0].mesh
    if !testing.expect(t,ai.nav_mesh_init(mesh,{tile_width=8,climb=0.3,max_tiles=4})) {return}
    vertices:=[]mm.Vec3{{0,0,0},{8,0,0},{8,0,8},{0,0,8}}
    indices:=[]u32{0,1,2,0,2,3}
    tile,made:=ai.nav_tile_from_triangles({0,0},{{0,-100,0},{8,100,8}},vertices,indices)
    if !testing.expect(t,made && ai.nav_mesh_add_tile(mesh,tile)) {return}
    n.count,n.ready=1,true
    e:=core.create(&world.entities)
    core.add(&world.agents,e,nav.NAV_AGENT_DEFAULT)
    path:=nav.NAV_PATH_DEFAULT
    path.state,path.class,path.goal=.Moving,0,{7,0,7}
    core.add(&world.paths,e,path)
    test_world_settle(&world)
    ref,start,found:=ai.nav_find_nearest_any(mesh,{1,0,1},{0.5,1,0.5})
    if !testing.expect(t,found) {return}
    route,put:=core.entity_map_put(&a.run.routes,e,nav.Nav_Route{})
    if !testing.expect(t,put) {return}
    ai.nav_corridor_reset(&route.corridor,ref,start)
    route.corridor.target={7,0,7}
    storage:[4096]erender.Debug_Vertex
    lines:=erender.debug_lines_make(storage[:],depth_test=false)
    navigation_capture_draw(&session,core.world_ref(&world,test_world_info(&world)),&lines)
    edges,corridor,agent_path:=0,0,0
    for vertex in storage[:lines.count] {
        switch vertex.color {
        case mm.rgba8_pack(TILE_COLOR),mm.rgba8_pack(PORTAL_COLOR),mm.rgba8_pack(area_color(ai.NAV_AREA_WALKABLE,true)): edges+=1
        case mm.rgba8_pack(CORRIDOR_COLOR): corridor+=1
        case mm.rgba8_pack(AGENT_COLOR): agent_path+=1
        }
    }
    // The tile and the edges of its polygons, the outline of the corridor and the way to the goal.
    testing.expectf(t,edges>0 && corridor>0 && agent_path>0,"mesh %d, corridor %d, path %d",edges,corridor,agent_path)
}
