package physics

import "core:strings"
import "core:testing"
import "core:math/linalg"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// A physics world whose application holds the assets its colliders are made from.
@(private)
Geometry_Test :: struct {
    assets:host.Assets, // before f, whose field host hides the package in the fields after it
    using f:Physics_Test,
}

@(private)
geometry_test_init :: proc(t:^testing.T,g:^Geometry_Test) -> bool {
    if !physics_test_init(t,&g.f) {return false}
    g.settings={bodies=8,shapes=8,contacts=32,joints=1,characters=1,hulls=2,meshes=2,heightfields=2}
    g.gravity=sim.world_desc_default().gravity
    g.whole=true
    g.app.assets=&g.assets
    if !testing.expect(t,host.assets_init(&g.assets,{root="assets",capacity=8})) {
        physics_test_destroy(&g.f)
        return false
    }
    return true
}

@(private)
geometry_test_destroy :: proc(g:^Geometry_Test) {
    physics_test_destroy(&g.f)
    host.assets_destroy(&g.assets)
}

@(private)
geometry_test_step :: proc(g:^Geometry_Test) {
    physics_test_settle(&g.f)
    physics_test_run(&g.f,0)
}

@(private)
geometry_test_mesh :: proc(g:^Geometry_Test,heights:[]f32=nil,origin:[3]f32={},cell:[3]f32={1,1,1},disabled_borders:[]u8=nil) -> (base.Asset_Id,bool) {
    positions:=[4]geom.Vec3{origin,origin+{cell.x,0,0},origin+{0,0,cell.z},origin+{cell.x,0,cell.z}}
    for &p,index in positions {if len(heights)==4 {p.y+=heights[index]*cell.y}}
    indices:=[6]u32{0,2,1,1,2,3}
    options:=host.Mesh_Generate_Options{no_lods=true,collision=len(heights)==0}
    field:=host.Assets_Heightfield{heights=heights,columns=2,rows=2,cell=cell,origin=origin,disabled_borders=disabled_borders}
    if len(heights)>0 {options.heightfield=&field}
    return host.assets_mesh_generate(&g.assets,{positions=positions[:],indices=indices[:]},options=options)
}

@(private)
geometry_test_volume :: proc(g:^Geometry_Test,grid:geom.Scalar_Grid,low,high:[3]int,seam_x:Maybe(f32)=nil) -> (base.Asset_Id,bool) {
    raw,welded:geom.Mesh_Buffer
    geom.mesh_buffer_init(&raw);geom.mesh_buffer_init(&welded)
    defer geom.mesh_buffer_destroy(&raw);defer geom.mesh_buffer_destroy(&welded)
    if geom.isosurface(grid,low,high,&raw)!=.None {return {},false}
    geom.mesh_weld(geom.mesh_buffer_view(&raw),0,&welded)
    if len(welded.indices)==0 {return {},true}
    disabled:=make([]u8,len(welded.indices)/3)
    defer delete(disabled)
    if plane,has_plane:=seam_x.?;has_plane {
        for &mask,triangle in disabled {
            for edge in 0..<3 {
                a:=welded.positions[welded.indices[3*triangle+edge]]
                b:=welded.positions[welded.indices[3*triangle+(edge+1)%3]]
                if a.x==plane && b.x==plane {mask|=u8(1<<u32(edge))}
            }
        }
    }
    return host.assets_mesh_generate(&g.assets,geom.mesh_buffer_view(&welded),options={no_lods=true,collision=true,disabled_edges=disabled})
}

@(test)
generated_heightfield_colliders_preserve_origin_scale_and_the_render_diagonal :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    heights:=[4]f32{0,0,0,2}
    mesh,ok:=geometry_test_mesh(&g,heights[:],{-1,2,-1},{2,1,3})
    testing.expect(t,ok)
    e:=core.create(&g.entities)
    collider:=collider_heightfield()
    collider.center={0.5,1,-0.25}
    core.add(&g.colliders,e,collider)
    core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
    core.add(&g.transforms,e,core.Transform{position={10,1,20},rotation=1,scale={2,3,4}})
    geometry_test_step(&g)
    l:=link_find(&g.state,e)
    testing.expect(t,l!=nil && l.heightfield!={} && l.mesh=={})
    testing.expect_value(t,sim.shape_type(&g.state.world,l.shape),sim.Shape_Type.Heightfield)
    for point in ([2][3]f32{{10,10,18},{12,13,24}}) {
        hit,hit_ok:=raycast({&g.state},{point.x,30,point.z},{0,-1,0})
        testing.expect(t,hit_ok && hit.entity==e)
        testing.expectf(t,abs(hit.point.y-point.y)<1e-4,"heightfield ray at %v returned %v",point,hit.point)
    }
    snapshot:Physics_State
    defer state_destroy(&snapshot)
    state_copy(&snapshot,&g.state)
    core.remove(&g.colliders,e)
    geometry_test_step(&g)
    testing.expect(t,host.assets_mesh_release(&g.assets,mesh))
    hit,hit_ok:=raycast({&snapshot},{12,30,24},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-13)<1e-4)
    testing.expect(t,l.heightfield=={})
    state_copy(&g.state,&snapshot)
    core.add(&g.colliders,e,collider)
    geometry_test_step(&g)
    hit,hit_ok=raycast({&g.state},{12,30,24},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-13)<1e-4)
    testing.expect_value(t,g.problems.count,0)
}

@(test)
a_compound_heightfield_rotates_its_grid_origin_and_ignores_unrelated_asset_changes :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    heights:=[4]f32{0,0,0,0}
    mesh,ok:=geometry_test_mesh(&g,heights[:],{2,0,3})
    testing.expect(t,ok)
    owner,e:=core.create(&g.entities),core.create(&g.entities)
    core.add(&g.rigids,owner,RIGID_BODY_STATIC)
    core.add(&g.transforms,owner,core.Transform{position={10,5,0},rotation=1,scale={2,1,3}})
    core.add(&g.parents,e,core.Parent{entity=owner})
    core.add(&g.transforms,e,core.Transform{position={1,0,0},rotation=mm.quat_axis_angle({0,1,0},mm.PI/2),scale={1,1,1}})
    core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
    core.add(&g.colliders,e,collider_heightfield())
    geometry_test_step(&g)
    hit,hit_ok:=raycast({&g.state},{21.75,20,-4.5},{0,-1,0})
    testing.expect(t,hit_ok && hit.entity==owner && abs(hit.point.y-5)<1e-4)
    shape:=link_find(&g.state,e).shape
    unused,unused_ok:=geometry_test_mesh(&g)
    testing.expect(t,unused_ok)
    geometry_test_step(&g)
    testing.expect(t,host.assets_mesh_release(&g.assets,unused))
    geometry_test_step(&g)
    testing.expect_value(t,link_find(&g.state,e).shape,shape)
    testing.expect_value(t,g.state.stats.shapes_created,u64(1))
}

@(test)
copying_physics_replaces_divergent_meshes_and_heightfields_with_equal_generations :: proc(t:^testing.T) {
    worlds:[2]Physics_State
    defer for &state in worlds {state_destroy(&state)}
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=4,4,8,0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.character_capacity=0,1,1,0
    for &state,index in worlds {
        testing.expect(t,sim.world_init(&state.world,desc))
        state.ready=true
        heights:=[4]f32{f32(index)*2,f32(index)*2,f32(index)*2,f32(index)*2}
        field,ok:=sim.heightfield_create(&state.world,{heights=heights[:],columns=2,rows=2,cell={1,1,1}})
        testing.expect(t,ok)
        body_desc:=sim.BODY_DESC_DEFAULT
        body_desc.type=.Static
        body:=sim.body_create(&state.world,body_desc)
        shape:=sim.SHAPE_DESC_DEFAULT
        shape.geometry=field
        sim.shape_create(&state.world,body,shape)
        y:=f32(4+index*2)
        positions:=[4][3]f32{{10,y,0},{11,y,0},{10,y,1},{11,y,1}}
        indices:=[6]u32{0,2,1,1,2,3}
        mesh,mesh_ok:=sim.mesh_create(&state.world,{vertices=positions[:],indices=indices[:]})
        testing.expect(t,mesh_ok)
        shape.geometry=mesh
        sim.shape_create(&state.world,body,shape)
    }
    state_copy(&worlds[1],&worlds[0])
    state_destroy(&worlds[0])
    for point in ([2][3]f32{{0.25,0,0.25},{10.25,4,0.25}}) {
        hit,ok:=raycast({&worlds[1]},{point.x,10,point.z},{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y-point.y)<1e-4)
    }
}

@(test)
copying_physics_gives_the_copy_its_own_heightfield_holes :: proc(t:^testing.T) {
    worlds:[2]Physics_State
    defer for &state in worlds {state_destroy(&state)}
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=4,4,8,0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.character_capacity=0,0,1,0
    for &state,index in worlds {
        testing.expect(t,sim.world_init(&state.world,desc))
        state.ready=true
        // The same heights and generation, a hole only in the first cell of the source.
        heights:=[6]f32{}
        holes:=[2]u8{index==0?1:0,0}
        field,ok:=sim.heightfield_create(&state.world,{heights=heights[:],columns=3,rows=2,cell={1,1,1},holes=holes[:]})
        testing.expect(t,ok)
        body_desc:=sim.BODY_DESC_DEFAULT
        body_desc.type=.Static
        shape:=sim.SHAPE_DESC_DEFAULT
        shape.geometry=field
        sim.shape_create(&state.world,sim.body_create(&state.world,body_desc),shape)
    }
    state_copy(&worlds[1],&worlds[0])
    state_destroy(&worlds[0])
    _,in_hole:=raycast({&worlds[1]},{0.5,10,0.5},{0,-1,0})
    _,beside:=raycast({&worlds[1]},{1.5,10,0.5},{0,-1,0})
    testing.expect(t,!in_hole && beside)
}

@(test)
generated_mesh_collision_cache_prunes_released_chunks_and_reuses_geometry_slots :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    e:=core.create(&g.entities)
    core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
    for _ in 0..<20 {
        mesh,ok:=geometry_test_mesh(&g)
        testing.expect(t,ok)
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
        core.add(&g.colliders,e,collider_mesh())
        geometry_test_step(&g)
        hit,hit_ok:=raycast({&g.state},{0.25,3,0.25},{0,-1,0})
        testing.expect(t,hit_ok && abs(hit.point.y)<1e-5)
        testing.expect_value(t,len(g.meshes.entries),1)
        core.remove(&g.colliders,e)
        geometry_test_step(&g)
        testing.expect(t,host.assets_mesh_release(&g.assets,mesh))
        geometry_test_step(&g)
        testing.expect_value(t,len(g.meshes.entries),0)
    }
    testing.expect_value(t,g.meshes.built,u64(20))
    testing.expect_value(t,g.problems.count,0)
}

@(test)
a_rejected_heightfield_shape_releases_its_geometry_and_an_explicit_edit_can_retry :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    g.settings.shapes=1
    heights:=[4]f32{0,0,0,0}
    mesh,ok:=geometry_test_mesh(&g,heights[:])
    testing.expect(t,ok)
    a,b:=core.create(&g.entities),core.create(&g.entities)
    for e in ([2]core.Entity{a,b}) {
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
        core.add(&g.colliders,e,collider_heightfield())
        core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
    }
    geometry_test_step(&g)
    refused:=core.problem_find(&g.problems,b,"physics.shapes")
    testing.expect(t,g.problems.count==1 && refused!=nil && refused.count==1,"the second chunk has no room for its shape")
    live:=0
    for field in g.state.world.heightfields {if field.generation&1!=0 {live+=1}}
    testing.expect_value(t,live,1)
    testing.expect(t,link_find(&g.state,b).heightfield=={})
    core.remove(&g.colliders,a)
    geometry_test_step(&g)
    core.edit(&g.colliders,b).center.x=0.1
    geometry_test_step(&g)
    testing.expect(t,link_find(&g.state,b).heightfield!={})
    hit,hit_ok:=raycast({&g.state},{0.35,3,0.25},{0,-1,0})
    testing.expect(t,hit_ok && hit.entity==b)
}

@(test)
volume_mesh_replacement_excavation_empty_chunks_and_parent_motion_keep_collision_current :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    g.settings.meshes=1
    values:[5*5*5]f32
    for z in 0..<5 {for y in 0..<5 {for x in 0..<5 {values[x+5*(y+5*z)]=f32(y)-2+0.35}}}
    grid:=geom.Scalar_Grid{samples={5,5,5},cell={1,1,1},origin={-2,-2,-2},values=values[:]}
    mesh,ok:=geometry_test_volume(&g,grid,{},{4,4,4})
    testing.expect(t,ok && mesh!={})
    owner,e:=core.create(&g.entities),core.create(&g.entities)
    core.add(&g.transforms,owner,core.Transform{position={7,2,-5},rotation=1,scale={1,1,1}})
    core.add(&g.parents,e,core.Parent{entity=owner})
    core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
    core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
    core.add(&g.colliders,e,collider_mesh())
    geometry_test_step(&g)
    before,before_ok:=raycast({&g.state},{7,10,-5},{0,-1,0})
    testing.expect(t,before_ok && abs(before.point.y-1.65)<1e-4)
    saved:Physics_State
    defer state_destroy(&saved)
    state_copy(&saved,&g.state)
    for z in 0..<5 {for y in 0..<5 {for x in 0..<5 {
        p:=[3]f32{f32(x)-2,f32(y)-2,f32(z)-2}
        sphere:=linalg.length(p-[3]f32{0,-0.35,0})-1.1
        index:=x+5*(y+5*z)
        values[index]=max(values[index],-sphere)
    }}}
    excavated,excavated_ok:=geometry_test_volume(&g,grid,{},{4,4,4})
    testing.expect(t,excavated_ok && excavated!={} && excavated!=mesh)
    core.add(&g.statics,e,render.Mesh_Renderer{mesh=excavated})
    testing.expect(t,host.assets_mesh_release(&g.assets,mesh))
    geometry_test_step(&g)
    after,after_ok:=raycast({&g.state},{7,10,-5},{0,-1,0})
    testing.expectf(t,after_ok && before.point.y-after.point.y>0.7,"excavation from %v to %v",before.point,after.point)
    old,old_ok:=raycast({&saved},{7,10,-5},{0,-1,0})
    testing.expect(t,old_ok && abs(old.point.y-1.65)<1e-4)
    core.edit(&g.transforms,owner).position={20,4,7}
    geometry_test_step(&g)
    _,ghost:=raycast({&g.state},{7,10,-5},{0,-1,0})
    testing.expect(t,!ghost)
    moved,moved_ok:=raycast({&g.state},{20,12,7},{0,-1,0})
    testing.expect(t,moved_ok && abs(moved.point.y-after.point.y-2)<1e-4)
    for &value in values {value=1}
    empty,empty_ok:=geometry_test_volume(&g,grid,{},{4,4,4})
    testing.expect(t,empty_ok && empty=={})
    core.remove(&g.statics,e);core.remove(&g.colliders,e)
    testing.expect(t,host.assets_mesh_release(&g.assets,excavated))
    geometry_test_step(&g)
    _,still_solid:=raycast({&g.state},{20,12,7},{0,-1,0})
    testing.expect(t,!still_solid)
    testing.expect_value(t,len(g.meshes.entries),0)
    testing.expect_value(t,g.problems.count,0)
    for slot in g.state.world.meshes {testing.expect(t,slot.generation&1==0)}
}

@(test)
adjacent_heightfield_chunks_with_distinct_origins_share_the_boundary_after_parent_motion :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    left:=[4]f32{-1,1,-1,1}
    right:=[4]f32{1,3,1,3}
    a,a_ok:=geometry_test_mesh(&g,left[:],{-2,0,-1},{2,1,2})
    b,b_ok:=geometry_test_mesh(&g,right[:],{0,0,-1},{2,1,2})
    testing.expect(t,a_ok && b_ok)
    owner:=core.create(&g.entities)
    core.add(&g.transforms,owner,core.Transform{position={6,4,10},rotation=1,scale={2,3,1}})
    chunks:=[2]core.Entity{core.create(&g.entities),core.create(&g.entities)}
    for e,index in chunks {
        core.add(&g.parents,e,core.Parent{entity=owner})
        core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&g.colliders,e,collider_heightfield())
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=index==0?a:b})
    }
    for pass in 0..<2 {
        if pass==1 {core.edit(&g.transforms,owner).position={20,4,-10}}
        geometry_test_step(&g)
        center:=pass==0?[3]f32{6,7,10}:[3]f32{20,7,-10}
        for offset in ([3]f32{-0.001,0,0.001}) {
            hit,ok:=raycast({&g.state},{center.x+offset,30,center.z+0.25},{0,-1,0})
            expected:=center.y+offset*1.5
            testing.expectf(t,ok && abs(hit.point.y-expected)<1e-4,"boundary %v: %v expected %v",center,hit.point,expected)
            if offset<0 {testing.expect_value(t,hit.entity,chunks[0])}
            if offset>0 {testing.expect_value(t,hit.entity,chunks[1])}
        }
    }
    _,ghost:=raycast({&g.state},{6,30,10.25},{0,-1,0})
    testing.expect(t,!ghost)
    testing.expect_value(t,g.state.stats.shapes_created,u64(2))
    testing.expect_value(t,g.problems.count,0)
}

@(test)
physics_geometry_budgets_are_applied_once_and_exhausted_heightfields_can_be_reused :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    g.settings.hulls,g.settings.meshes,g.settings.heightfields=3,4,1
    // Two chunks of different heights: the same one would share its slot.
    flat,raised:=[4]f32{0,0,0,0},[4]f32{0,0,0,1}
    meshes:[2]base.Asset_Id
    for heights,at in ([2][4]f32{flat,raised}) {
        heights:=heights
        made,ok:=geometry_test_mesh(&g,heights[:])
        testing.expect(t,ok)
        meshes[at]=made
    }
    chunks:=[2]core.Entity{core.create(&g.entities),core.create(&g.entities)}
    for e,at in chunks {
        core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&g.colliders,e,collider_heightfield())
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=meshes[at]})
    }
    geometry_test_step(&g)
    used,capacity:=geometry_budget({&g.state},.Heightfield)
    testing.expect(t,used==1 && capacity==1)
    testing.expect(t,collider_ready({&g.state},chunks[0]) && !collider_ready({&g.state},chunks[1]))
    testing.expect_value(t,g.state.world.desc.hull_capacity,3)
    testing.expect_value(t,g.state.world.desc.mesh_capacity,4)
    testing.expect_value(t,g.state.world.desc.heightfield_capacity,1)
    testing.expect_value(t,sim.world_stats(&g.state.world).geometry_capacity_exhausted,1)
    budget:=core.problem_find(&g.problems,chunks[1],"physics.geometry_budget")
    if testing.expect(t,g.problems.count==1 && budget!=nil && budget.count==1) {
        testing.expect(t,strings.contains(core.problem_text(budget),"1 of the 1 of Physics_Settings.heightfields") && strings.contains(core.problem_text(budget),"raise heightfields"),core.problem_text(budget))
    }
    g.settings.heightfields=8
    core.remove(&g.colliders,chunks[0])
    geometry_test_step(&g)
    testing.expect_value(t,g.state.world.desc.heightfield_capacity,1)
    testing.expect(t,link_find(&g.state,chunks[1]).heightfield=={})
    core.edit(&g.colliders,chunks[1]).center.x=0.1
    geometry_test_step(&g)
    testing.expect(t,link_find(&g.state,chunks[1]).heightfield!={})
    testing.expect(t,collider_ready({&g.state},chunks[1]))
    testing.expect(t,g.problems.count==1 && budget.count==1,"a shape that waits for a change is not refused again")
}

@(test)
sliding_across_resident_volume_chunk_boundaries_keeps_horizontal_velocity :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    values:[17*3*5]f32
    for z in 0..<5 {for y in 0..<3 {for x in 0..<17 {values[x+17*(y+3*z)]=f32(y)-1+0.35}}}
    grid:=geom.Scalar_Grid{samples={17,3,5},cell={1,1,1},origin={-8,-1,-2},values=values[:]}
    for index in 0..<2 {
        mesh,ok:=geometry_test_volume(&g,grid,{index*8,0,0},{(index+1)*8,2,4},f32(0))
        testing.expect(t,ok)
        e:=core.create(&g.entities)
        core.add(&g.transforms,e,core.Transform{position={10,4,-5},rotation=1,scale={1,1,1}})
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
        collider:=collider_mesh();collider.friction=0
        core.add(&g.colliders,e,collider)
    }
    geometry_test_step(&g)
    body_desc:=sim.BODY_DESC_DEFAULT
    body_desc.position={5,3.95,-4.3}
    body_desc.sleep_disabled=true
    body:=sim.body_create(&g.state.world,body_desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Sphere{0.3};shape.friction=0
    sim.shape_create(&g.state.world,body,shape)
    sim.body_set_velocity(&g.state.world,body,{2,0,0},{})
    for _ in 0..<180 {
        sim.world_step(&g.state.world,1.0/60)
        velocity:=sim.body_linear_velocity(&g.state.world,body)
        if !testing.expectf(t,abs(velocity.x-2)<0.02 && abs(velocity.y)<0.02 && abs(velocity.z)<0.02,"volume seam deflected %v at %v",velocity,sim.body_position(&g.state.world,body)) {break}
    }
}

@(test)
sliding_across_resident_heightfield_chunk_boundaries_keeps_horizontal_velocity :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    heights:=[4]f32{}
    masks:=[2][4]u8{{0,1,0,0},{1,0,0,0}}
    for index in 0..<2 {
        mesh,ok:=geometry_test_mesh(&g,heights[:],{f32(index*4)-4,0,-2},{4,1,4},masks[index][:])
        testing.expect(t,ok)
        e:=core.create(&g.entities)
        core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
        collider:=collider_heightfield();collider.friction=0
        core.add(&g.colliders,e,collider)
    }
    geometry_test_step(&g)
    body_desc:=sim.BODY_DESC_DEFAULT
    body_desc.position={-2,0.3,0.13};body_desc.sleep_disabled=true
    body:=sim.body_create(&g.state.world,body_desc)
    shape:=sim.SHAPE_DESC_DEFAULT;shape.geometry=sim.Sphere{0.3};shape.friction=0
    sim.shape_create(&g.state.world,body,shape)
    sim.body_set_velocity(&g.state.world,body,{2,0,0},{})
    for _ in 0..<120 {
        sim.world_step(&g.state.world,1.0/60)
        velocity:=sim.body_linear_velocity(&g.state.world,body)
        if !testing.expectf(t,abs(velocity.x-2)<0.02 && abs(velocity.y)<0.02 && abs(velocity.z)<0.02,"heightfield seam deflected %v at %v",velocity,sim.body_position(&g.state.world,body)) {break}
    }
}

@(test)
physics_copy_replaces_border_metadata_when_heights_vertices_and_generations_match :: proc(t:^testing.T) {
    worlds:[2]Physics_State
    defer for &state in worlds {state_destroy(&state)}
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=1,1,4,0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.character_capacity=0,1,1,0
    heights:=[4]f32{}
    borders:=[2][4]u8{{0,1,0,0},{1,0,0,0}}
    masks:=[2][1]u8{{1},{2}}
    vertices:=[3][3]f32{{0,0,0},{0,0,1},{1,0,0}}
    indices:=[3]u32{0,1,2}
    for &state,index in worlds {
        testing.expect(t,sim.world_init(&state.world,desc));state.ready=true
        _,ok:=sim.heightfield_create(&state.world,{heights=heights[:],columns=2,rows=2,cell={1,1,1},disabled_borders=borders[index][:]})
        testing.expect(t,ok)
        _,mesh_ok:=sim.mesh_create(&state.world,{vertices=vertices[:],indices=indices[:],disabled_edges=masks[index][:]})
        testing.expect(t,mesh_ok)
    }
    state_copy(&worlds[1],&worlds[0])
    testing.expect(t,sliced_equal(worlds[1].world.heightfields[0].field.disabled_borders,borders[0][:]))
    testing.expect_value(t,worlds[1].world.meshes[0].mesh.flags[0],u8(6))
    state_destroy(&worlds[0])
    testing.expect(t,sliced_equal(worlds[1].world.heightfields[0].field.disabled_borders,borders[0][:]))
}

@(test)
identical_generated_replacements_preserve_contact_warmstart_and_resimulation :: proc(t:^testing.T) {
    for kind in ([2]Collider_Kind{.Heightfield,.Mesh}) {
        g:Geometry_Test
        if !geometry_test_init(t,&g) {return}
        defer geometry_test_destroy(&g)
        heights:=[4]f32{0.25,0.25,0.25,0.25}
        values:=kind==.Heightfield?heights[:]:nil
        origin:=kind==.Heightfield?[3]f32{-2,0,-2}:[3]f32{-2,0.25,-2}
        mesh,ok:=geometry_test_mesh(&g,values,origin,{4,1,4})
        testing.expect(t,ok)
        e:=core.create(&g.entities)
        core.add(&g.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
        collider:=kind==.Heightfield?collider_heightfield():collider_mesh();collider.friction=0
        core.add(&g.colliders,e,collider)
        geometry_test_step(&g)
        body_desc:=sim.BODY_DESC_DEFAULT;body_desc.position={0,1,0.13};body_desc.sleep_disabled=true
        body:=sim.body_create(&g.state.world,body_desc)
        shape:=sim.SHAPE_DESC_DEFAULT;shape.geometry=sim.Sphere{0.3};shape.friction=0
        sim.shape_create(&g.state.world,body,shape)
        sim.body_set_velocity(&g.state.world,body,{0.5,0,0},{})
        for _ in 0..<90 {sim.world_step(&g.state.world,1.0/60)}
        testing.expect(t,sim.world_stats(&g.state.world).contacts>0)
        saved:Physics_State
        defer state_destroy(&saved)
        state_copy(&saved,&g.state)
        handle:=link_find(&g.state,e).shape
        original:=sim.world_hash(&g.state.world)
        replacement,replacement_ok:=geometry_test_mesh(&g,values,origin,{4,1,4})
        testing.expect(t,replacement_ok && replacement!=mesh)
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=replacement})
        testing.expect(t,host.assets_mesh_release(&g.assets,mesh))
        geometry_test_step(&g)
        testing.expect_value(t,link_find(&g.state,e).shape,handle)
        testing.expect_value(t,g.state.stats.shapes_created,u64(1))
        testing.expect_value(t,sim.world_hash(&g.state.world),original)
        for step in 0..<90 {
            sim.world_step(&g.state.world,1.0/60);sim.world_step(&saved.world,1.0/60)
            if !testing.expectf(t,sim.world_hash(&g.state.world)==sim.world_hash(&saved.world),"%v resimulation diverged at %d",kind,step) {break}
            testing.expect_value(t,sim.body_linear_velocity(&g.state.world,body),sim.body_linear_velocity(&saved.world,body))
        }
    }
}

@(test)
cylinder_colliders_and_convex_radii_reach_the_simulation_at_the_scale_of_the_entity :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    post,box,hull,too_round:=core.create(&g.entities),core.create(&g.entities),core.create(&g.entities),core.create(&g.entities)
    cylinder:=collider_cylinder(0.4,0.5)
    cylinder.convex_radius=0.05
    core.add(&g.colliders,post,cylinder)
    core.add(&g.transforms,post,core.Transform{position={0,1,0},rotation=1,scale={2,3,2}})
    rounded:=collider_box({0.5,0.5,0.5})
    rounded.convex_radius=0.1
    core.add(&g.colliders,box,rounded)
    core.add(&g.transforms,box,core.Transform{position={5,0,0},rotation=1,scale={1,1,1}})
    rounded_hull:=collider_hull()
    rounded_hull.convex_radius=0.05
    core.add(&g.colliders,hull,rounded_hull)
    core.add(&g.statics,hull,render.Mesh_Renderer{shape=.Cube})
    core.add(&g.transforms,hull,core.Transform{position={-5,0,0},rotation=1,scale={1,1,1}})
    flat:=collider_box({0.5,0.2,0.5})
    flat.convex_radius=0.3
    core.add(&g.colliders,too_round,flat)
    core.add(&g.transforms,too_round,core.Transform{position={0,0,-5},rotation=1,scale={1,1,1}})
    geometry_test_step(&g)
    w:=&g.state.world
    l:=link_find(&g.state,post)
    testing.expect(t,l!=nil && sim.shape_type(w,l.shape)==.Cylinder)
    expect_close(t,sim.shape_convex_radius(w,l.shape),0.1)
    side,side_ok:=raycast({&g.state},{3,1.5,0},{-1,0,0})
    testing.expect(t,side_ok && side.entity==post)
    expect_close(t,side.point.x,0.8)
    top,top_ok:=raycast({&g.state},{0.2,5,0},{0,-1,0})
    testing.expect(t,top_ok && top.entity==post)
    expect_close(t,top.point.y,2.5)
    l=link_find(&g.state,box)
    testing.expect(t,l!=nil && sim.shape_type(w,l.shape)==.Box)
    expect_close(t,sim.shape_convex_radius(w,l.shape),0.1)
    corner,corner_ok:=raycast({&g.state},{7,2,2},linalg.normalize([3]f32{-1,-1,-1}))
    testing.expect(t,corner_ok && corner.entity==box)
    expect_close(t,corner.point.y,0.4+0.1/linalg.sqrt(f32(3)))
    l=link_find(&g.state,hull)
    testing.expect(t,l!=nil && sim.shape_type(w,l.shape)==.Hull)
    expect_close(t,sim.shape_convex_radius(w,l.shape),0.05)
    refused:=core.problem_find(&g.problems,too_round,"physics.convex_radius")
    testing.expect(t,refused!=nil && link_find(&g.state,too_round).shape=={},"a convex radius that leaves no core is a problem of the entity")
    if refused!=nil {testing.expect(t,strings.contains(core.problem_text(refused),"convex_radius"),core.problem_text(refused))}
}

// A mesh mirrored by a negative scale collides where it is drawn, from the side it faces there. A collider
// turned under a scale that is not uniform across the turn is sheared: a problem of its entity.
@(test)
a_mirrored_mesh_collides_where_it_is_drawn :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    // A ledge at y 1 from x 0.5 to 2.5, facing up, drawn mirrored from x -2.5 to -0.5.
    corners:=[4]geom.Vec3{{0.5,1,-1},{2.5,1,-1},{0.5,1,1},{2.5,1,1}}
    order:=[6]u32{0,2,1, 1,2,3}
    mesh,made:=host.assets_mesh_generate(&g.assets,{positions=corners[:],indices=order[:]},options={no_lods=true,collision=true})
    if !testing.expect(t,made) {return}
    ledge:=core.create(&g.entities)
    core.add(&g.transforms,ledge,core.Transform{{},1,{-1,1,1}})
    core.add(&g.colliders,ledge,collider_mesh())
    core.add(&g.statics,ledge,render.Mesh_Renderer{mesh=mesh})
    ball:=core.create(&g.entities)
    core.add(&g.transforms,ball,core.Transform{{-1.5,2,0},1,{1,1,1}})
    core.add(&g.colliders,ball,collider_sphere(0.25))
    core.add(&g.rigids,ball,RIGID_BODY_DYNAMIC)
    parent:=core.create(&g.entities)
    core.add(&g.transforms,parent,core.Transform{{0,0,-6},1,{2,1,1}})
    turns:=[2]f32{0.25*linalg.PI,0.5*linalg.PI}
    turned:[2]core.Entity
    for &e,at in turned {
        e=core.create(&g.entities)
        core.add(&g.transforms,e,core.Transform{{f32(at)*3,0,0},mm.quat_axis_angle({0,1,0},turns[at]),{1,1,1}})
        core.add(&g.parents,e,core.Parent{entity=parent})
        core.add(&g.colliders,e,collider_box({0.5,0.5,0.5}))
    }
    for _ in 0..<90 {physics_test_step(&g.f)}
    rest:=physics_test_pose(&g.f,ball).position
    testing.expectf(t,abs(rest.y-1.25)<0.02 && abs(rest.x+1.5)<0.02,"the ball rests on the mirrored ledge: %v",rest)
    hit,hit_ok:=raycast({&g.state},{-1,4,0.6},{0,-1,0})
    testing.expectf(t,hit_ok && hit.entity==ledge && abs(hit.point.y-1)<1e-3,"a ray down on the mirrored ledge: %v",hit)
    _,beside:=raycast({&g.state},{1.5,4,0.6},{0,-1,0})
    testing.expect(t,!beside,"nothing is where the ledge would be unmirrored")
    testing.expect(t,core.problem_find(&g.problems,turned[0],"physics.collider_sheared")!=nil,"an eighth turn under a scale of (2,1,1) shears")
    testing.expect(t,core.problem_find(&g.problems,turned[1],"physics.collider_sheared")==nil,"a quarter turn does not")
}

@(private="file")
expect_close :: proc(t:^testing.T,value,expected:f32,loc:=#caller_location) {
    testing.expectf(t,abs(value-expected)<=1e-3,"got %v, expected %v",value,expected,loc=loc)
}

@(test)
colliders_of_the_same_mesh_and_scale_share_one_slot_of_geometry :: proc(t:^testing.T) {
    g:Geometry_Test
    if !geometry_test_init(t,&g) {return}
    defer geometry_test_destroy(&g)
    g.settings.bodies,g.settings.shapes,g.settings.hulls,g.settings.heightfields=16,16,2,1
    cube:geom.Mesh_Buffer
    geom.mesh_buffer_init(&cube,context.temp_allocator)
    geom.cube_build(&cube)
    mesh,ok:=host.assets_mesh_generate(&g.assets,{positions=cube.positions[:],indices=cube.indices[:]},options={no_lods=true,collision=true})
    testing.expect(t,ok)
    heights:=[4]f32{0,0,0,0}
    ground,ground_ok:=geometry_test_mesh(&g,heights[:])
    testing.expect(t,ground_ok)
    walls:[6]core.Entity
    for &e,at in walls {
        e=core.create(&g.entities)
        // The last one is twice as large: geometry of its own.
        size:f32=at==len(walls)-1?2:1
        core.add(&g.transforms,e,core.Transform{{f32(at)*3,0,0},1,{size,size,size}})
        core.add(&g.colliders,e,collider_hull())
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=mesh})
    }
    chunks:=[2]core.Entity{core.create(&g.entities),core.create(&g.entities)}
    for e,at in chunks {
        core.add(&g.transforms,e,core.Transform{{f32(at)*10,-5,0},1,{1,1,1}})
        core.add(&g.colliders,e,collider_heightfield())
        core.add(&g.statics,e,render.Mesh_Renderer{mesh=ground})
    }
    geometry_test_step(&g)
    testing.expect_value(t,g.problems.count,0)
    for e in walls {testing.expect(t,collider_ready({&g.state},e))}
    for e in chunks {testing.expect(t,collider_ready({&g.state},e))}
    hulls,_:=geometry_budget({&g.state},.Hull)
    fields,_:=geometry_budget({&g.state},.Heightfield)
    testing.expect_value(t,hulls,2)
    testing.expect_value(t,fields,1)
    testing.expect_value(t,link_find(&g.state,walls[0]).hull,link_find(&g.state,walls[4]).hull)

    // The copy of the world for Play or a rollback shares the same, and a snapshot of the solver keeps it.
    copy:Physics_State
    defer state_destroy(&copy)
    testing.expect(t,state_copy(&copy,&g.state))
    // What links the entities to the simulation is plain data: its copy is a copy of its bytes.
    testing.expect(t,core.value_flat(type_info_of(Link)) && core.value_flat(type_info_of(Joint_Link)) && core.value_flat(type_info_of(Fluid_Link)))
    for wall in walls {testing.expect(t,link_find(&copy,wall)!=nil && link_find(&copy,wall)^==link_find(&g.state,wall)^)}
    copied,_:=geometry_budget({&copy},.Hull)
    testing.expect_value(t,copied,2)
    buffer:sim.World
    defer sim.world_destroy(&buffer)
    testing.expect(t,sim.world_kept_init(&buffer,&g.state.world,context.allocator))
    _,saved:=sim.world_state_copy(&buffer,&g.state.world)
    _,restored:=sim.world_state_copy(&g.state.world,&buffer)
    testing.expect(t,saved && restored)

    // The slot goes with the last collider that uses it.
    for e in walls[:4] {core.remove(&g.colliders,e)}
    geometry_test_step(&g)
    hulls,_=geometry_budget({&g.state},.Hull)
    testing.expect_value(t,hulls,2)
    for e in walls[4:] {core.remove(&g.colliders,e)}
    for e in chunks {core.remove(&g.colliders,e)}
    geometry_test_step(&g)
    hulls,_=geometry_budget({&g.state},.Hull)
    fields,_=geometry_budget({&g.state},.Heightfield)
    testing.expect_value(t,hulls,0)
    testing.expect_value(t,fields,0)

    // Back from the copy, the shared slots are there again with their colliders gone from the rows: the next
    // step lets them go.
    testing.expect(t,state_copy(&g.state,&copy))
    hulls,_=geometry_budget({&g.state},.Hull)
    testing.expect_value(t,hulls,2)
    geometry_test_step(&g)
    hulls,_=geometry_budget({&g.state},.Hull)
    testing.expect_value(t,hulls,0)
}

// A generated mesh whose Hull collider is made of boxes, each given by its lowest and highest corner.
@(private="file")
pieces_mesh :: proc(assets:^host.Assets,boxes:[][2][3]f32) -> (base.Asset_Id,bool) {
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    for box in boxes {
        for corner in 0..<8 {append(&points,geom.Vec3{box[corner&1].x,box[corner>>1&1].y,box[corner>>2&1].z})}
        append(&sizes,8)
    }
    triangle:=[3]geom.Vec3{{0,0,0},{1,0,0},{0,0,1}}
    order:=[3]u32{0,2,1}
    return host.assets_mesh_generate(assets,{positions=triangle[:],indices=order[:]},options={no_lods=true,hull_points=points[:],hull_sizes=sizes[:]})
}

// An L of two boxes: its notch is the corner from x 1 to 2 above y 1.
@(private="file")
PIECES_L :: [2][2][3]f32{{{0,0,-1},{2,1,1}},{{0,1,-1},{1,2,1}}}

@(private="file")
pieces_test_init :: proc(t:^testing.T,f:^Physics_Test,assets:^host.Assets) -> bool {
    if !physics_test_init(t,f) {return false}
    f.app.assets=assets
    return host.assets_init(assets,{root="assets",capacity=8})
}

@(private="file")
pieces_entity :: proc(f:^Physics_Test,mesh:base.Asset_Id,position:[3]f32,rigid:Maybe(Rigid_Body)=nil) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,1,{1,1,1}})
    core.add(&f.colliders,e,collider_hull())
    core.add(&f.statics,e,render.Mesh_Renderer{mesh=mesh})
    if body,has:=rigid.?;has {core.add(&f.rigids,e,body)}
    return e
}

@(private="file")
hulls_used :: proc(f:^Physics_Test) -> int {
    used,_:=geometry_budget({&f.state},.Hull)
    return used
}

// An L whose Hull collider is made of two convex pieces holds a sphere in its notch, where the hull of all
// its points would be a slope, and its contacts and rays name it.
@(test)
a_hull_of_convex_pieces_holds_a_sphere_in_its_notch :: proc(t:^testing.T) {
    f:Physics_Test
    assets:host.Assets
    defer physics_test_destroy(&f)
    defer host.assets_destroy(&assets)
    if !testing.expect(t,pieces_test_init(t,&f,&assets)) {return}
    f.gravity={0,-9.81,0}
    boxes:=PIECES_L
    mesh,made:=pieces_mesh(&assets,boxes[:])
    if !testing.expect(t,made) {return}
    corner:=pieces_entity(&f,mesh,{})
    ball:=core.create(&f.entities)
    core.add(&f.transforms,ball,core.Transform{{1.5,2.5,0},1,{1,1,1}})
    core.add(&f.colliders,ball,collider_sphere(0.25))
    core.add(&f.rigids,ball,RIGID_BODY_DYNAMIC)
    touched:=false
    for _ in 0..<120 {
        physics_test_step(&f)
        for begin in f.events.contact_begin.items {
            touched||=begin.a==corner && begin.collider_a==corner && begin.b==ball || begin.b==corner && begin.collider_b==corner && begin.a==ball
        }
    }
    testing.expect_value(t,f.problems.count,0)
    l:=link_find(&f.state,corner)
    if !testing.expect(t,l!=nil && l.pieces.count==1 && collider_ready({&f.state},corner)) {return}
    testing.expect_value(t,hulls_used(&f),2)
    rest:=physics_test_pose(&f,ball).position
    testing.expectf(t,abs(rest.y-1.25)<0.02 && rest.x>1.2 && rest.x<1.8,"the ball rests in the notch: %v",rest)
    testing.expect(t,touched,"the contact names the L as body and collider")
    for probe in ([2][3]f32{{1.5,1,0.7},{0.5,2,0.7}}) {
        hit,hit_ok:=raycast({&f.state},probe+{0,4,0},{0,-1,0})
        testing.expectf(t,hit_ok && hit.entity==corner && hit.collider==corner && abs(hit.point.y-probe.y)<1e-3,"a ray down at %v: %v",probe,hit)
        alone,alone_ok:=collider_raycast({&f.state},corner,probe+{0,4,0},{0,-1,0},10)
        testing.expectf(t,alone_ok && abs(alone.point.y-probe.y)<1e-3,"a ray at the L alone at %v: %v",probe,alone)
    }
    bounds,bounded:=collider_bounds({&f.state},corner)
    testing.expectf(t,bounded && bounds.max.y>=2 && bounds.max.x>=2,"the bounds hold every piece: %v",bounds)
}

// The pieces of a Hull collider are shapes of the body of a static, kinematic, dynamic or compound entity:
// the mass is that of the pieces, not of the hull of all their points.
@(test)
the_pieces_of_a_hull_are_shapes_of_every_kind_of_body :: proc(t:^testing.T) {
    f:Physics_Test
    assets:host.Assets
    defer physics_test_destroy(&f)
    defer host.assets_destroy(&assets)
    if !testing.expect(t,pieces_test_init(t,&f,&assets)) {return}
    boxes:=PIECES_L
    mesh,made:=pieces_mesh(&assets,boxes[:])
    if !testing.expect(t,made) {return}
    rigids:=[3]Rigid_Body{RIGID_BODY_STATIC,RIGID_BODY_KINEMATIC,RIGID_BODY_DYNAMIC}
    entities:[4]core.Entity
    for rigid,at in rigids {entities[at]=pieces_entity(&f,mesh,{f32(at)*5,0,0},rigid)}
    holder:=core.create(&f.entities)
    core.add(&f.transforms,holder,core.Transform{{15,0,0},1,{1,1,1}})
    core.add(&f.rigids,holder,RIGID_BODY_DYNAMIC)
    entities[3]=pieces_entity(&f,mesh,{})
    core.add(&f.parents,entities[3],core.Parent{holder,0})
    physics_test_step(&f,0)
    testing.expect_value(t,f.problems.count,0)
    // Every L shares the two slots.
    testing.expect_value(t,hulls_used(&f),2)
    w:=&f.state.world
    for e,at in entities {
        l:=link_find(&f.state,e)
        if !testing.expect(t,l!=nil && l.pieces.count==1) {continue}
        shapes:[4]sim.Shape_Handle
        testing.expect_value(t,sim.body_shapes(w,l.body,shapes[:]),2)
        hit,hit_ok:=raycast({&f.state},{f32(at)*5+1.5,5,0},{0,-1,0})
        testing.expectf(t,hit_ok && hit.entity==(at==3?holder:e) && hit.collider==e && abs(hit.point.y-1)<1e-3,"the notch of entity %v: %v",at,hit)
    }
    for e in ([2]core.Entity{entities[2],holder}) {
        mass,_,_:=sim.body_mass_properties(w,body_of({&f.state},e))
        testing.expectf(t,abs(mass-6000)<1,"the mass of two boxes of 4 and 2 m3: %v",mass)
    }
}

// A change of the mesh makes the pieces again and the removal of the collider frees them all; a copy of the
// world keeps them, a full budget leaves the link without a shape and a piece without volume is refused.
@(test)
the_pieces_of_a_hull_follow_their_mesh_copies_and_budgets :: proc(t:^testing.T) {
    f:Physics_Test
    assets:host.Assets
    defer physics_test_destroy(&f)
    defer host.assets_destroy(&assets)
    if !testing.expect(t,pieces_test_init(t,&f,&assets)) {return}
    f.settings.hulls=3
    two:=PIECES_L
    three:=[3][2][3]f32{two[0],two[1],{{1,1,-1},{1.5,1.5,1}}}
    four:=[4][2][3]f32{two[0],two[1],three[2],{{3,0,-1},{4,1,1}}}
    flat:=[2][2][3]f32{two[0],{{0,1,-1},{1,1,1}}}
    l_mesh,_:=pieces_mesh(&assets,two[:])
    step_mesh,_:=pieces_mesh(&assets,three[:])
    big_mesh,_:=pieces_mesh(&assets,four[:])
    flat_mesh,made:=pieces_mesh(&assets,flat[:])
    if !testing.expect(t,made) {return}
    e:=pieces_entity(&f,l_mesh,{},RIGID_BODY_DYNAMIC)
    physics_test_step(&f,0)
    w:=&f.state.world
    shapes:[8]sim.Shape_Handle
    testing.expect_value(t,sim.body_shapes(w,body_of({&f.state},e),shapes[:]),2)

    copy:Physics_State
    defer state_destroy(&copy)
    testing.expect(t,state_copy(&copy,&f.state))

    core.edit(&f.statics,e).mesh=step_mesh
    physics_test_step(&f,0)
    l:=link_find(&f.state,e)
    testing.expect(t,l!=nil && l.pieces.count==2)
    testing.expect_value(t,sim.body_shapes(w,l.body,shapes[:]),3)
    testing.expect_value(t,hulls_used(&f),3)
    hit,hit_ok:=raycast({&f.state},{1.25,5,0},{0,-1,0})
    testing.expect(t,hit_ok && hit.entity==e && abs(hit.point.y-1.5)<1e-3)

    // Four pieces do not fit in three hulls: no shape, and nothing held.
    core.edit(&f.statics,e).mesh=big_mesh
    physics_test_step(&f,0)
    testing.expect(t,core.problem_find(&f.problems,e,"physics.geometry_budget")!=nil)
    l=link_find(&f.state,e)
    testing.expect(t,l!=nil && l.shape=={} && l.hull=={} && l.pieces==Piece_Run{})
    testing.expect_value(t,sim.body_shapes(w,l.body,shapes[:]),0)
    testing.expect_value(t,hulls_used(&f),0)
    for piece in f.state.pieces {testing.expect_value(t,piece,Piece{})}

    // A piece without volume is not a part of a body.
    core.edit(&f.statics,e).mesh=flat_mesh
    physics_test_step(&f,0)
    testing.expect(t,core.problem_find(&f.problems,e,"physics.collider_hull")!=nil)
    testing.expect(t,l.shape=={} && hulls_used(&f)==0)
    meshes,_:=geometry_budget({&f.state},.Mesh)
    testing.expect_value(t,meshes,0)

    // Removed, every slot is free; back from the copy, the L is there and collides.
    core.edit(&f.statics,e).mesh=l_mesh
    physics_test_step(&f,0)
    testing.expect_value(t,sim.body_shapes(w,link_find(&f.state,e).body,shapes[:]),2)
    core.remove(&f.colliders,e)
    physics_test_step(&f,0)
    testing.expect_value(t,hulls_used(&f),0)
    for piece in f.state.pieces {testing.expect_value(t,piece,Piece{})}
    testing.expect_value(t,f.state.stats.shapes_created,f.state.stats.shapes_destroyed)
    testing.expect(t,state_copy(&f.state,&copy))
    testing.expect_value(t,hulls_used(&f),2)
    hit,hit_ok=raycast({&f.state},{1.5,5,0},{0,-1,0})
    testing.expect(t,hit_ok && hit.entity==e && abs(hit.point.y-1)<1e-3)
    buffer:sim.World
    defer sim.world_destroy(&buffer)
    testing.expect(t,sim.world_kept_init(&buffer,w,context.allocator))
    _,saved:=sim.world_state_copy(&buffer,w)
    _,restored:=sim.world_state_copy(w,&buffer)
    testing.expect(t,saved && restored)
    // The rows lost the collider: the next step lets the copied pieces go.
    physics_test_step(&f,0)
    testing.expect_value(t,hulls_used(&f),0)
}
