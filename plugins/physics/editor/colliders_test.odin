package physics_editor

import "mirai:editor"
import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import "mirai:std/geom"

@(private="file")
Collider_World :: struct {
    using world:core.Test_World,
    using physics:phys.Test_Physics,
    ids:core.Table(core.Id),
}

@(private="file")
Collider_Editor :: struct {preview:Collider_Preview}

// A physics world, what the application holds for its step and the session that draws its colliders.
@(private="file")
Collider_Test :: struct {
    using w:Collider_World,
    using application:phys.Test_Physics_Host,
    info:core.World_Info,
    tools:^Collider_Editor,
    selection:history.Selection,
    session:editor.Session,
}

@(private="file")
collider_test_init :: proc(t:^testing.T,f:^Collider_Test) -> bool {
    f.info=core.test_info(t,Collider_World,core.Test_None,Collider_Editor,test_types) or_return
    if !testing.expect(t,core.world_init(&f.info,.World,&f.w,context.allocator)) {
        collider_test_destroy(f)
        return false
    }
    f.tools=new(Collider_Editor)
    f.whole=true
    f.gravity=sim.world_desc_default().gravity
    f.session={app=&f.app,info=&f.info,editor_world=f.tools,selection=&f.selection}
    return true
}

@(private="file")
collider_test_destroy :: proc(f:^Collider_Test) {
    delete(f.selection.entities)
    free(f.tools)
    phys.test_host_destroy(&f.application)
    core.world_destroy(&f.info,.World,&f.w)
    core.test_info_destroy(&f.info)
}

@(private="file")
collider_test_settle :: proc(f:^Collider_Test) {core.settle(&f.info,&f.w,nil)}

@(private="file")
collider_test_step :: proc(f:^Collider_Test) {phys.test_step(&f.physics,&f.application,0)}

@(test)
selected_colliders_show_their_physics_shape_even_with_the_grid_hidden :: proc(t:^testing.T) {
    f:Collider_Test
    if !collider_test_init(t,&f) {return}
    defer collider_test_destroy(&f)
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=8,8,16,0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=0,0,0,0
    desc.character_capacity=0
    testing.expect(t,sim.world_init(&f.state.world,desc))
    f.state.ready=true
    owner,selected,other:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    core.add(&f.rigids,owner,phys.RIGID_BODY_STATIC)
    core.add(&f.transforms,owner,core.Transform{position={5,0,0},rotation=1,scale={2,2,2}})
    core.add(&f.transforms,selected,core.Transform{position={1,2,3},rotation=1,scale={1,1,1}})
    core.add(&f.transforms,other,core.TRANSFORM_IDENTITY)
    core.add(&f.colliders,selected,phys.COLLIDER_DEFAULT)
    core.add(&f.colliders,other,phys.collider_sphere(2))
    core.add(&f.parents,selected,core.Parent{entity=owner})
    collider_test_settle(&f)
    collider_test_step(&f)
    testing.expect_value(t,f.problems.count,0)
    testing.expect(t,phys.body_of({&f.state},selected)==phys.body_of({&f.state},owner))
    history.selection_set(&f.selection,{selected})
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,2)
    lines:=f.app.extras.debug[0]
    faint:=f.app.extras.debug[1]
    testing.expect(t,lines.depth_test && lines.count==24 && lines.dropped==0,"in sight: hidden behind what is in front")
    testing.expect(t,!faint.depth_test && faint.count==24 && faint.vertices[0].position==lines.vertices[0].position && faint.vertices[0].color>>24==lines.vertices[0].color>>24/4,"the same lines at a quarter of their opacity, through everything")
    for vertex in lines.vertices[:lines.count] {
        testing.expect(t,abs(vertex.position.x-7)==1 && abs(vertex.position.y-4)==1 && abs(vertex.position.z-6)==1)
    }
    f.app.extras.debug_count=0
    core.edit(&f.transforms,selected).position.x=2
    collider_test_step(&f)
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,2)
    for vertex in f.app.extras.debug[0].vertices[:f.app.extras.debug[0].count] {
        testing.expect(t,abs(vertex.position.x-9)==1 && abs(vertex.position.y-4)==1 && abs(vertex.position.z-6)==1)
    }
    f.app.extras.debug_count=0
    history.selection_clear(&f.selection)
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,0)
    history.selection_set(&f.selection,{selected})
    f.session.mode=.Play
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,0)
    f.session.mode=.Paused
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,0)
}

@(test)
selected_author_colliders_exclude_derived_geometry_and_never_draw_partial_shapes :: proc(t:^testing.T) {
    f:Collider_Test
    if !collider_test_init(t,&f) {return}
    defer collider_test_destroy(&f)
    owner:=core.create(&f.entities)
    core.add(&f.ids,owner,{value=1})
    core.add(&f.transforms,owner,core.TRANSFORM_IDENTITY)
    first:=core.NONE
    children:=editor.LINE_CAPACITY/24+2
    for index in 0..<children {
        e:=core.create(&f.entities)
        if index==0 {first=e}
        core.add(&f.ids,e,{value=base.Entity_Id(index+2)})
        core.add(&f.parents,e,core.Parent{entity=owner})
        core.add(&f.colliders,e,phys.COLLIDER_DEFAULT)
        core.add(&f.transforms,e,core.Transform{position={f32(index)*2,0,0},rotation=1,scale={1,1,1}})
    }
    unrelated:=core.create(&f.entities)
    core.add(&f.colliders,unrelated,phys.COLLIDER_DEFAULT)
    core.add(&f.transforms,unrelated,core.Transform{position={9000,0,0},rotation=1,scale={1,1,1}})
    collider_test_settle(&f)
    f.settings={bodies=i32(children+1),shapes=i32(children+1),contacts=16,joints=1,characters=1,hulls=1,meshes=1,heightfields=1}
    collider_test_step(&f)
    testing.expect_value(t,f.problems.count,0)
    history.selection_set(&f.selection,{first})
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,2)
    testing.expect_value(t,f.app.extras.debug[0].count,24)
    for vertex in f.app.extras.debug[0].vertices[:24] {testing.expect(t,abs(vertex.position.x)==0.5)}
    f.app.extras.debug_count=0
    history.selection_set(&f.selection,{owner,first})
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,2)
    testing.expect_value(t,f.app.extras.debug[0].count,editor.LINE_CAPACITY/24*24)
    testing.expect(t,f.app.extras.debug[0].dropped>0)
    for vertex in f.app.extras.debug[0].vertices[:f.app.extras.debug[0].count] {testing.expect(t,vertex.position.x<1000)}
    f.app.extras.debug_count=0
    for e in f.colliders.entities {core.remove(&f.ids,e)}
    collider_test_settle(&f)
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,0)
    physical:=sim.Debug_Draw{lines=f.tools.preview.scratch[:]}
    testing.expect(t,phys.collider_debug_draw({&f.state},first,&physical))
    testing.expect_value(t,physical.line_count,12)
    core.add(&f.ids,first,{value=2});collider_test_settle(&f)
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,2)
    testing.expect_value(t,f.app.extras.debug[0].count,24)
    f.app.extras.debug_count=0

    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=8})) {return}
    defer host.assets_destroy(&assets)
    f.app.assets=&assets
    geometry:geom.Mesh_Buffer;geom.mesh_buffer_init(&geometry);defer geom.mesh_buffer_destroy(&geometry)
    geom.plane_build(&geometry,{32,32},32,32)
    mesh,generated:=host.assets_mesh_generate(&assets,geom.mesh_buffer_view(&geometry),options={no_lods=true,collision=true})
    if !testing.expect(t,generated) {return}
    core.add(&f.statics,first,erender.Mesh_Renderer{mesh=mesh});collider_test_settle(&f)
    core.edit(&f.colliders,first)^=phys.collider_mesh()
    collider_test_step(&f)
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    if !testing.expect_value(t,f.app.extras.debug_count,2) {return}
    testing.expect_value(t,f.app.extras.debug[0].count,24)
    testing.expect(t,f.app.extras.debug[0].dropped>0)
    bounds,bounded:=phys.collider_bounds({&f.state},first)
    testing.expect(t,bounded)
    testing.expect_value(t,bounds.min,[3]f32{-16,0,-16});testing.expect_value(t,bounds.max,[3]f32{16,0,16})
    for vertex in f.app.extras.debug[0].vertices[:f.app.extras.debug[0].count] {
        for axis in 0..<3 {testing.expect(t,vertex.position[axis]==bounds.min[axis] || vertex.position[axis]==bounds.max[axis])}
    }
    _,invalid:=phys.collider_bounds({&f.state},core.NONE);testing.expect(t,!invalid)
    f.app.extras.debug_count=0
    history.selection_clear(&f.selection)
    collider_lines_draw(&f.session,core.world_ref(&f.w,&f.info))
    testing.expect_value(t,f.app.extras.debug_count,0)
}
