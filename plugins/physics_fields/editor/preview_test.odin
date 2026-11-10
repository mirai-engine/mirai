package physics_fields_editor

import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import gpu "mirai:render"
import mm "mirai:std/math"
import fields "plugins:physics_fields/runtime"

@(private="file")
Preview_World :: struct {
    using world:core.Test_World,
    regions:core.Table(fields.Physics_Field),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
}

@(test)
selected_physics_fields_preview_world_regions_force_direction_and_parent_changes :: proc(t:^testing.T) {
    w:Preview_World
    if !core.test_world_init(t,&w,fields.test_types) {return}
    defer core.test_world_destroy(&w)
    parent,entity,other:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    field:=fields.PHYSICS_FIELD_DEFAULT
    field.shape,field.direction,field.force,field.half_extents,field.vector=.Box,.Directional,-20,{1,2,3},{1,0,0}
    core.add(&w.regions,entity,field);core.add(&w.regions,other,fields.PHYSICS_FIELD_DEFAULT)
    core.add(&w.transforms,parent,core.Transform{{3,4,5},mm.quat_axis_angle({0,1,0},mm.PI*.5),{2,1,.5}})
    core.add(&w.transforms,entity,core.Transform{{1,0,0},1,{1,2,3}})
    core.add(&w.transforms,other,core.TRANSFORM_DEFAULT);core.add(&w.parents,entity,{entity=parent})
    core.test_world_settle(&w)
    selection:editor.Selection;defer delete(selection.entities)
    editor.selection_set(&selection,{entity})
    session:=editor.Session{selection=&selection}
    preview:=new(Physics_Field_Preview);defer free(preview)
    app:host.App
    physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
    testing.expect_value(t,app.extras.debug_count,1)
    lines:=app.extras.debug[0]
    testing.expect(t,!lines.depth_test && lines.count==34 && lines.dropped==0)
    pose,placed:=core.world_of(core.read(&w.transforms),core.read(&w.parents),entity);testing.expect(t,placed)
    for vertex in lines.vertices[:24] {
        point:=mm.quat_rotate(conj(pose.rotation),vertex.position-pose.position)
        for extent,axis in (mm.Vec3{2,4,4.5}) {testing.expect(t,abs(abs(point[axis])-extent)<1e-4)}
    }
    testing.expect_value(t,lines.vertices[24].position,pose.position)
    direction:=mm.quat_rotate(pose.rotation,mm.Vec3{-1,0,0})
    testing.expect(t,linalg.length(lines.vertices[25].position-pose.position-direction*2)<1e-4)
    app.extras.debug_count=0
    core.get(&w.transforms,parent).position.x+=10
    physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
    testing.expect_value(t,app.extras.debug[0].vertices[24].position,pose.position+mm.Vec3{10,0,0})
    app.extras.debug_count=0
    field.shape,field.direction,field.radius=.Sphere,.Radial,2
    core.get(&w.regions,entity)^=field
    physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
    lines=app.extras.debug[0]
    testing.expect_value(t,lines.count,252)
    pose,_=core.world_of(core.read(&w.transforms),core.read(&w.parents),entity)
    for vertex in lines.vertices[:192] {testing.expect(t,abs(linalg.length(vertex.position-pose.position)-4)<1e-4)}
    for arrow in 0..<6 {
        from,to:=lines.vertices[192+arrow*10].position,lines.vertices[193+arrow*10].position
        testing.expect(t,abs(linalg.length(from-pose.position)-3)<1e-4 && abs(linalg.length(to-pose.position)-1)<1e-4)
    }
    app.extras.debug_count=0
    editor.selection_clear(&selection)
    physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
    testing.expect_value(t,app.extras.debug_count,0)
    editor.selection_set(&selection,{entity})
    versions:=[3]u64{w.regions.version,w.transforms.version,w.parents.version}
    for mode in ([2]editor.Mode{.Simulate,.Simulation_Paused}) {
        session.mode=mode
        app.extras.debug_count=0
        physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
        testing.expect_value(t,app.extras.debug_count,1)
        testing.expect_value(t,app.extras.debug[0].count,252)
        testing.expect_value(t,([3]u64{w.regions.version,w.transforms.version,w.parents.version}),versions)
    }
    app.extras.debug_count=0
    for mode in ([2]editor.Mode{.Play,.Paused}) {
        session.mode=mode
        physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
        testing.expect_value(t,app.extras.debug_count,0)
    }
}

@(test)
physics_field_preview_reuses_vertices_without_allocations_and_omits_incomplete_regions :: proc(t:^testing.T) {
    w:Preview_World
    if !core.test_world_init(t,&w,fields.test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    field:=fields.PHYSICS_FIELD_DEFAULT;field.force=10
    core.add(&w.regions,entity,field);core.add(&w.transforms,entity,core.TRANSFORM_DEFAULT)
    core.test_world_settle(&w)
    selection:editor.Selection;defer delete(selection.entities)
    editor.selection_set(&selection,{entity})
    session:=editor.Session{selection=&selection}
    preview:=new(Physics_Field_Preview);defer free(preview)
    app:host.App
    physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    previous:=context.allocator;context.allocator=mem.tracking_allocator(&tracking)
    for _ in 0..<128 {
        app.extras.debug_count=0
        physics_fields_preview(&session,preview,{},core.read(&w.regions),core.read(&w.transforms),core.read(&w.parents),&app.extras)
        testing.expect_value(t,app.extras.debug_count,1)
        testing.expect_value(t,app.extras.debug[0].count,252)
    }
    context.allocator=previous
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
    storage:[251]gpu.Debug_Vertex
    lines:=gpu.debug_lines_make(storage[:],false)
    field_preview_draw(&lines,field,mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,lines.count,0);testing.expect_value(t,lines.dropped,126)
    field.radius=0
    field_preview_draw(&lines,field,mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,lines.count,0)
    field.shape,field.half_extents=.Box,{1,2,3}
    field_preview_draw(&lines,field,mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,lines.count,84)
    lines=gpu.debug_lines_make(storage[:],false)
    field.direction,field.vector=.Directional,{}
    field_preview_draw(&lines,field,mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,lines.count,24)
    lines=gpu.debug_lines_make(storage[:],false)
    field_preview_draw(&lines,field,mm.TRANSFORM_IDENTITY,on=false)
    testing.expect_value(t,lines.vertices[0].color,mm.rgba8_pack({.55,.55,.55,.7}))
}

@(test)
a_plane_field_preview_crosses_its_plane_face_and_points_along_its_normal :: proc(t:^testing.T) {
    storage:[64]gpu.Debug_Vertex
    lines:=gpu.debug_lines_make(storage[:],false)
    field:=fields.PHYSICS_FIELD_DEFAULT
    field.shape,field.half_extents,field.force=.Plane,{1,2,3},10
    pose:=mm.Transform{{1,2,3},mm.quat_axis_angle({0,0,1},mm.PI*.5),{1,1,1}}
    field_preview_draw(&lines,field,pose)
    testing.expect_value(t,lines.count,38)
    for vertex in lines.vertices[24:28] {
        local:=mm.quat_rotate(conj(pose.rotation),vertex.position-pose.position)
        testing.expect(t,abs(local.y-2)<1e-4 && abs(abs(local.x)-1)<1e-4 && abs(abs(local.z)-3)<1e-4)
    }
    normal:=mm.quat_rotate(pose.rotation,mm.Vec3{0,1,0})
    testing.expect(t,linalg.length(lines.vertices[28].position-pose.position)<1e-4)
    testing.expect(t,linalg.length(lines.vertices[29].position-pose.position-normal*2)<1e-4)
    lines=gpu.debug_lines_make(storage[:],false)
    field.force=-10
    field_preview_draw(&lines,field,pose)
    testing.expect(t,linalg.length(lines.vertices[29].position-pose.position)<1e-4)
    lines=gpu.debug_lines_make(storage[:],false)
    field.direction,field.vector=.Directional,{1,0,0}
    field_preview_draw(&lines,field,pose)
    testing.expect_value(t,lines.count,38)
}
