package physics_fields

import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

@(private="file")
Fields_World :: struct {
    using world:core.Test_World,
    fields:core.Table(Physics_Field),
    poses:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    requests:phys.Body_Requests,
}

@(test)
persistent_fields_transform_filter_and_accumulate_strain_independent_of_force :: proc(t:^testing.T) {
    w:Fields_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    authority:core.Network
    field:=core.create(&w.entities)
    config:=PHYSICS_FIELD_DEFAULT;config.shape=.Box;config.direction=.Directional;config.half_extents={1,2,3};config.vector={1,0,0};config.force=10;config.strain=120;config.weakening=true;config.filter.objects=4
    config.filter.ignore_body=17
    core.add(&w.fields,field,config);core.add(&w.poses,field,core.Transform{{3,4,5},mm.quat_axis_angle({0,1,0},mm.PI*.5),{2,1,.5}})
    core.test_world_settle(&w)
    for _ in 0..<3 {physics_fields_step(core.read(&w.fields),core.read(&w.poses),core.read(&w.parents),core.ref(&authority),&w.requests,{playing=true,dt=.25})}
    // Each tick sends the force and, to the breakables its filter meets, the strain of that tick.
    testing.expect_value(t,len(w.requests.queue.items),6)
    force:=w.requests.queue.items[0]
    testing.expect_value(t,force.kind,phys.Body_Request_Kind.Box_Force);testing.expect_value(t,force.position,mm.Vec3{3,4,5})
    testing.expect_value(t,force.half_extents,mm.Vec3{2,2,1.5});testing.expect(t,abs(force.linear.x)<.001 && abs(abs(force.linear.z)-10)<.001)
    strain:=w.requests.queue.items[1]
    testing.expect_value(t,strain.kind,phys.Body_Request_Kind.Strain);testing.expect(t,strain.override,"a weakening field breaks nothing")
    testing.expect_value(t,strain.strength,f32(30));testing.expect_value(t,strain.linear,mm.Vec3{})
    testing.expect_value(t,strain.filter,config.filter)
    testing.expect_value(t,strain.position,mm.Vec3{3,4,5});testing.expect_value(t,strain.half_extents,mm.Vec3{2,2,1.5})
    core.queue_clear(&w.requests.queue)
    authority.role=.Client
    physics_fields_step(core.read(&w.fields),core.read(&w.poses),core.read(&w.parents),core.ref(&authority),&w.requests,{playing=true,dt=.25})
    testing.expect_value(t,len(w.requests.queue.items),1)
    testing.expect_value(t,w.requests.queue.items[0].kind,phys.Body_Request_Kind.Box_Force)
}

@(test)
steady_persistent_fields_reuse_request_capacity_and_disabled_fields_do_nothing :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    previous:=context.allocator;context.allocator=mem.tracking_allocator(&tracking);defer {context.allocator=previous}
    w:Fields_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    authority:core.Network
    e:=core.create(&w.entities);config:=PHYSICS_FIELD_DEFAULT;config.force=10
    core.add(&w.fields,e,config);core.add(&w.poses,e,core.TRANSFORM_DEFAULT)
    core.test_world_settle(&w)
    physics_fields_step(core.read(&w.fields),core.read(&w.poses),core.read(&w.parents),core.ref(&authority),&w.requests,{playing=true,dt=.1})
    before:=tracking.total_allocation_count
    for _ in 0..<128 {
        core.queue_clear(&w.requests.queue)
        physics_fields_step(core.read(&w.fields),core.read(&w.poses),core.read(&w.parents),core.ref(&authority),&w.requests,{playing=true,dt=.1})
    }
    testing.expect_value(t,tracking.total_allocation_count,before)
    core.disable(&w.fields,e);core.test_world_settle(&w);core.queue_clear(&w.requests.queue)
    physics_fields_step(core.read(&w.fields),core.read(&w.poses),core.read(&w.parents),core.ref(&authority),&w.requests,{playing=true,dt=.1})
    testing.expect_value(t,len(w.requests.queue.items),0)
}

@(test)
plane_and_noise_fields_send_their_region_direction_range_and_noise :: proc(t:^testing.T) {
    w:Fields_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    authority:core.Network
    turn:=mm.quat_axis_angle({0,0,1},mm.PI*.5)
    noise:=phys.Field_Noise{scale=2,seed=5,range={.5,1.5}}
    radial,directional,noisy:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    plane:=PHYSICS_FIELD_DEFAULT;plane.shape=.Plane;plane.half_extents={1,2,3};plane.force=40;plane.strain=10;plane.falloff=.Squared;plane.falloff_range={.2,1}
    core.add(&w.fields,radial,plane)
    plane.direction,plane.vector,plane.strain=.Directional,{0,0,2},0
    core.add(&w.fields,directional,plane)
    sphere:=PHYSICS_FIELD_DEFAULT;sphere.force=-5;sphere.falloff=.Inverse;sphere.noise=noise
    core.add(&w.fields,noisy,sphere)
    for e in ([3]core.Entity{radial,directional,noisy}) {core.add(&w.poses,e,core.Transform{{1,2,3},turn,{1,1,1}})}
    core.test_world_settle(&w)
    physics_fields_step(core.read(&w.fields),core.read(&w.poses),core.read(&w.parents),core.ref(&authority),&w.requests,{playing=true,dt=.5})
    testing.expect_value(t,len(w.requests.queue.items),4)
    first,strain,second,third:=w.requests.queue.items[0],w.requests.queue.items[1],w.requests.queue.items[2],w.requests.queue.items[3]
    // A radial plane pushes along its normal, the local +Y turned by the pose.
    testing.expect_value(t,first.kind,phys.Body_Request_Kind.Plane_Force)
    testing.expect_value(t,first.half_extents,mm.Vec3{1,2,3})
    testing.expect(t,linalg.length(first.linear-mm.Vec3{-40,0,0})<1e-4)
    testing.expect_value(t,first.falloff,phys.Radial_Falloff.Squared)
    testing.expect_value(t,first.falloff_range,phys.Weight_Range{.2,1})
    testing.expect_value(t,second.kind,phys.Body_Request_Kind.Plane_Force)
    testing.expect(t,linalg.length(second.linear-mm.Vec3{0,0,40})<1e-4)
    testing.expect_value(t,third.kind,phys.Body_Request_Kind.Radial_Force)
    testing.expect_value(t,third.noise,noise)
    testing.expect_value(t,third.falloff,phys.Radial_Falloff.Inverse)
    // Strain takes the box of the plane.
    testing.expect_value(t,strain.kind,phys.Body_Request_Kind.Strain)
    testing.expect_value(t,strain.half_extents,mm.Vec3{1,2,3})
    testing.expect_value(t,strain.falloff,phys.Radial_Falloff.Squared)
    testing.expect_value(t,strain.strength,f32(5))
}
