package physics_editor

import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:host"
import volume "mirai:engine/volume"
import gpu "mirai:render"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(private="file")
Preview_World :: struct {
    using world:core.Test_World,
    fields:core.Table(phys.Force_Field),
    volumes:core.Table(volume.Volume),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
}

@(private="file")
preview_run :: proc(w:^Preview_World,session:^editor.Session,preview:^Force_Field_Preview,app:^host.App) {
    force_field_preview(session,preview,{},core.read(&w.fields),core.read(&w.volumes),core.read(&w.transforms),core.read(&w.parents),&app.extras)
}

// The arrows of the selected fields follow the entity, its parent and its
// Volume, in Edit and in Simulate and not in Play, and are drawn again only
// when something they are made of changes.
@(test)
selected_force_fields_show_where_they_push_in_their_volume :: proc(t:^testing.T) {
    w:Preview_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    parent,entity,other:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    field:=phys.FORCE_FIELD_DEFAULT
    field.force,field.along=-20,{1,0,0}
    core.add(&w.fields,entity,field);core.add(&w.fields,other,phys.FORCE_FIELD_DEFAULT)
    core.add(&w.volumes,entity,volume.box({1,2,3}))
    core.add(&w.transforms,parent,core.Transform{{3,4,5},mm.quat_axis_angle({0,1,0},mm.PI*.5),{2,1,.5}})
    core.add(&w.transforms,entity,core.Transform{{1,0,0},1,{1,2,3}})
    core.add(&w.transforms,other,core.TRANSFORM_DEFAULT);core.add(&w.parents,entity,{entity=parent})
    core.test_world_settle(&w)
    selection:history.Selection;defer delete(selection.entities)
    history.selection_set(&selection,{entity})
    session:=editor.Session{selection=&selection}
    preview:=new(Force_Field_Preview);defer free(preview)
    app:host.App
    preview_run(&w,&session,preview,&app)
    testing.expect_value(t,app.extras.debug_count,1)
    lines:=app.extras.debug[0]
    testing.expect(t,!lines.depth_test && lines.count==10 && lines.dropped==0)
    pose,placed:=core.world_of(core.read(&w.transforms),core.read(&w.parents),entity);testing.expect(t,placed)
    // Against its direction, for its force pulls: as long as half its box along it.
    testing.expect_value(t,lines.vertices[0].position,pose.position)
    direction:=mm.quat_rotate(pose.rotation,mm.Vec3{-1,0,0})
    testing.expect(t,linalg.length(lines.vertices[1].position-pose.position-direction*2)<1e-4)
    app.extras.debug_count=0
    core.get(&w.transforms,parent).position.x+=10
    preview_run(&w,&session,preview,&app)
    testing.expect_value(t,app.extras.debug[0].vertices[0].position,pose.position+mm.Vec3{10,0,0})
    // Away from the center of a sphere: six arrows, toward it by its negative force.
    app.extras.debug_count=0
    core.get(&w.fields,entity).along={}
    core.get(&w.volumes,entity)^=volume.sphere(2)
    preview_run(&w,&session,preview,&app)
    lines=app.extras.debug[0]
    testing.expect_value(t,lines.count,60)
    pose,_=core.world_of(core.read(&w.transforms),core.read(&w.parents),entity)
    for arrow in 0..<6 {
        from,to:=lines.vertices[arrow*10].position,lines.vertices[1+arrow*10].position
        testing.expect(t,abs(linalg.length(from-pose.position)-3)<1e-4 && abs(linalg.length(to-pose.position)-1)<1e-4)
    }
    app.extras.debug_count=0
    history.selection_clear(&selection)
    preview_run(&w,&session,preview,&app)
    testing.expect_value(t,app.extras.debug_count,0)
    history.selection_set(&selection,{entity})
    versions:=[3]u64{w.fields.version,w.transforms.version,w.volumes.version}
    for mode in ([2]editor.Mode{.Simulate,.Simulation_Paused}) {
        session.mode=mode
        app.extras.debug_count=0
        preview_run(&w,&session,preview,&app)
        testing.expect(t,app.extras.debug_count==1 && app.extras.debug[0].count==60)
        testing.expect_value(t,([3]u64{w.fields.version,w.transforms.version,w.volumes.version}),versions)
    }
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    previous:=context.allocator;context.allocator=mem.tracking_allocator(&tracking)
    for _ in 0..<64 {
        app.extras.debug_count=0
        preview_run(&w,&session,preview,&app)
    }
    context.allocator=previous
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
    app.extras.debug_count=0
    for mode in ([2]editor.Mode{.Play,.Paused}) {
        session.mode=mode
        preview_run(&w,&session,preview,&app)
        testing.expect_value(t,app.extras.debug_count,0)
    }
}

// By the shape of the volume: along the up of a plane, one arrow up in the
// whole world, none in a volume without size; gray when off, and counted
// whole when they do not fit.
@(test)
the_arrows_of_a_force_field_go_by_the_shape_of_its_volume :: proc(t:^testing.T) {
    storage:[64]gpu.Debug_Vertex
    field:=phys.FORCE_FIELD_DEFAULT
    field.force=10
    pose:=mm.Transform{{1,2,3},mm.quat_axis_angle({0,0,1},mm.PI*.5),{1,1,1}}
    normal:=mm.quat_rotate(pose.rotation,mm.Vec3{0,1,0})
    for area in ([2]volume.Volume{volume.plane(),volume.world()}) {
        lines:=gpu.debug_lines_make(storage[:],false)
        force_field_arrows(&lines,field,area,pose)
        testing.expect_value(t,lines.count,10)
        testing.expect(t,linalg.length(lines.vertices[0].position-pose.position)<1e-4)
        testing.expect(t,linalg.length(lines.vertices[1].position-pose.position-normal*FORCE_ARROW_LENGTH)<1e-4)
    }
    lines:=gpu.debug_lines_make(storage[:],false)
    force_field_arrows(&lines,field,volume.sphere(0),pose)
    force_field_arrows(&lines,field,volume.box({1,0,1}),pose)
    testing.expect_value(t,lines.count,0)
    force_field_arrows(&lines,field,volume.sphere(2),pose,on=false)
    testing.expect_value(t,lines.count,60)
    testing.expect_value(t,lines.vertices[0].color,mm.rgba8_pack({.65,.65,.65,.8}))
    force_field_arrows(&lines,field,volume.sphere(2),pose)
    testing.expect(t,lines.count==60 && lines.dropped==30)
}
