package physics

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

@(private="file")
box_near :: proc(a,b:mm.Aabb) -> bool {
    for i in 0..<3 {
        if abs(a.min[i]-b.min[i])>1e-4 || abs(a.max[i]-b.max[i])>1e-4 {return false}
    }
    return true
}

// The box around the triangles of one collider.
@(private="file")
triangles_bounds :: proc(vertices:[][3]f32,indices:[]u32,colliders:[]core.Entity,e:core.Entity) -> (box:mm.Aabb,count:int) {
    box={max(f32),-max(f32)}
    for collider,i in colliders[:len(indices)/3] {
        if collider!=e {continue}
        count+=1
        for index in indices[3*i:][:3] {box={mm.vec3_min(box.min,vertices[index]),mm.vec3_max(box.max,vertices[index])}}
    }
    return
}

@(test)
static_triangles_and_changes_come_from_the_static_colliders_of_the_world :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    physics:=core.ref(&f.state)
    vertices:[64][3]f32
    indices:[192]u32
    colliders:[64]core.Entity
    boxes:[8]mm.Aabb
    everything:=mm.Aabb{{-10,-10,-10},{10,10,10}}

    // Before the simulation is made there is nothing to read.
    v,i,complete:=static_triangles(physics,everything,vertices[:],indices[:],colliders=colliders[:])
    testing.expect(t,v==0 && i==0 && complete)
    cursor,count,overflow:=static_changes(physics,{},boxes[:])
    testing.expect(t,cursor==Static_Cursor{} && count==0 && !overflow)

    floor:=physics_test_box(&f,{0,-0.5,0},{5,0.5,5})
    wide:=core.create(&f.entities)
    core.add(&f.transforms,wide,core.Transform{{0,3,0},1,{2,1,1}})
    core.add(&f.colliders,wide,collider_box({1,1,1}))
    crate:=physics_test_box(&f,{0,6,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    sensor:=core.create(&f.entities)
    trigger:=collider_box({0.5,0.5,0.5})
    trigger.preset=PRESET_TRIGGER
    core.add(&f.transforms,sensor,core.Transform{{3,1,3},1,{1,1,1}})
    core.add(&f.colliders,sensor,trigger)
    physics_test_step(&f,0)

    // The floor and the box scaled along X; neither the crate nor the sensor.
    v,i,complete=static_triangles(physics,everything,vertices[:],indices[:],colliders=colliders[:])
    testing.expect(t,v==16 && i==72 && complete)
    bounds,triangles:=triangles_bounds(vertices[:v],indices[:i],colliders[:],floor)
    testing.expect(t,triangles==12 && box_near(bounds,{{-5,-1,-5},{5,0,5}}))
    bounds,triangles=triangles_bounds(vertices[:v],indices[:i],colliders[:],wide)
    testing.expect(t,triangles==12 && box_near(bounds,{{-2,2,-1},{2,4,1}}))
    // Only what blocks the filter, within the box, and as many as the colliders hold.
    v,i,complete=static_triangles(physics,everything,vertices[:],indices[:],query_hits(collision_layers(Collision_Category(3))))
    testing.expect(t,v==0 && i==0 && complete)
    v,i,complete=static_triangles(physics,{{-1,-1,-1},{1,1,1}},vertices[:],indices[:],colliders=colliders[:])
    testing.expect(t,v==8 && i==36 && complete && colliders[0]==floor)
    v,i,complete=static_triangles(physics,everything,vertices[:],indices[:],colliders=colliders[:10])
    testing.expect(t,i==0 && !complete)

    // The two static colliders were made, not the sensor, which blocks nothing; then the floor moves and the
    // crate falls in place without a change.
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==2 && !overflow)
    found:=0
    for box in boxes[:2] {
        if box_near(box,{{-5,-1,-5},{5,0,5}}) || box_near(box,{{-2,2,-1},{2,4,1}}) {found+=1}
    }
    testing.expect_value(t,found,2)
    core.add(&f.transforms,floor,core.Transform{{0,-1.5,0},1,{1,1,1}})
    core.add(&f.transforms,crate,core.Transform{{0,4,0},1,{1,1,1}})
    physics_test_step(&f,0)
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==2 && !overflow)
    testing.expect(t,box_near(boxes[0],{{-5,-1,-5},{5,0,5}}) && box_near(boxes[1],{{-5,-2,-5},{5,-1,5}}))
    core.remove(&f.colliders,wide)
    physics_test_step(&f,0)
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==1 && !overflow && box_near(boxes[0],{{-2,2,-1},{2,4,1}}))
    // The sensor moved and removed leaves the log as it was.
    core.add(&f.transforms,sensor,core.Transform{{-3,1,-3},1,{1,1,1}})
    physics_test_step(&f,0)
    core.remove(&f.colliders,sensor)
    physics_test_step(&f,0)
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==0 && !overflow)

    // A simulation made again leaves the cursors of the last one behind.
    state_reset(&f.state)
    next,_,_:=static_changes(physics,cursor,boxes[:])
    testing.expect_value(t,next,cursor)
    physics_test_step(&f,0)
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==0 && overflow && cursor.epoch==f.state.epoch)
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==0 && !overflow)
}

@(test)
static_bounds_hold_every_static_collider_but_the_sensors :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    physics:=core.ref(&f.state)
    _,ok:=static_bounds(physics)
    testing.expect(t,!ok)
    physics_test_box(&f,{0,-0.5,0},{5,0.5,5})
    far:=physics_test_box(&f,{20,3,0},{1,1,1})
    physics_test_box(&f,{0,40,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    sensor:=core.create(&f.entities)
    trigger:=collider_box({1,1,1})
    trigger.preset=PRESET_TRIGGER
    core.add(&f.transforms,sensor,core.Transform{{-30,0,0},1,{1,1,1}})
    core.add(&f.colliders,sensor,trigger)
    physics_test_step(&f,0)
    box:mm.Aabb
    box,ok=static_bounds(physics)
    testing.expect(t,ok && box.min.x<=-5 && box.min.x>-10 && box.max.x>=21 && box.min.y<=-1 && box.max.y>=4 && box.max.y<10)
    // Moved and removed, the sensor leaves them as they were; a solid collider that goes takes its part.
    core.add(&f.transforms,sensor,core.Transform{{0,30,0},1,{1,1,1}})
    physics_test_step(&f,0)
    moved,_:=static_bounds(physics)
    testing.expect_value(t,moved,box)
    core.remove(&f.colliders,sensor)
    core.destroy(&f.entities,far)
    physics_test_step(&f,0)
    box,ok=static_bounds(physics)
    testing.expect(t,ok && box.max.x<10)
}

// A Collider without a Rigid_Body is a shape of the static body of the world: a level of them takes one
// body. What hits it, touches it or ignores it names its entity; moved by its Transform, its shape moves
// where it is; moved as a body, it gets a body of its own.
@(test)
a_static_collider_is_a_shape_of_the_world_until_it_moves_as_a_body :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.settings={bodies=3,shapes=8,contacts=16,characters=1}
    f.gravity={0,-9.81,0}
    floors:[3]core.Entity
    for &e,i in floors {e=physics_test_box(&f,{f32(i)*4,0,0},{1,0.1,1})}
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.world.body_count,1)
    for e,i in floors {
        testing.expect_value(t,body_of(core.ref(&f.state),e),Body_Handle{})
        hit,found:=raycast(core.ref(&f.state),{f32(i)*4,5,0},{0,-1,0})
        testing.expect(t,found && hit.entity==e && hit.collider==e)
        _,found=raycast(core.ref(&f.state),{f32(i)*4,5,0},{0,-1,0},ignore=e)
        testing.expect(t,!found)
    }
    shapes:=f.state.stats.shapes_created
    core.edit(&f.transforms,floors[1]).position.z=10
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.stats.shapes_created,shapes)
    hit,found:=raycast(core.ref(&f.state),{4,5,10},{0,-1,0})
    testing.expect(t,found && hit.entity==floors[1])

    box:=physics_test_box(&f,{8,1,0},{0.2,0.2,0.2},RIGID_BODY_DYNAMIC)
    touched:=false
    for _ in 0..<60 {
        physics_test_step(&f)
        for c in f.events.contact_begin.items {touched||=c.a==floors[2] && c.b==box || c.b==floors[2] && c.a==box}
    }
    testing.expect(t,touched,"the box lands on the floor it names")

    move_kinematic(&f.requests,floors[0],{0,0,-6})
    physics_test_step(&f,0)
    body:=body_of(core.ref(&f.state),floors[0])
    testing.expect(t,body!={} && sim.body_type(&f.state.world,body)==.Static && f.state.world.body_count==3)
    hit,found=raycast(core.ref(&f.state),{0,5,-6},{0,-1,0})
    testing.expect(t,found && hit.entity==floors[0] && hit.body==body)
    testing.expect_value(t,f.problems.count,0)
}

// A static collider the shapes of Physics_Settings had no room for stays unmade: when a shape is let go,
// the next sync makes it, as streamed sections come and go.
@(test)
a_static_collider_refused_for_shapes_is_made_when_one_frees :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.settings={bodies=2,shapes=2,contacts=8,characters=1}
    floors:[3]core.Entity
    for &e,i in floors {e=physics_test_box(&f,{f32(i)*4,0,0},{1,0.1,1})}
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.world.shape_count,2)
    _,found:=raycast(core.ref(&f.state),{8,5,0},{0,-1,0})
    testing.expect(t,!found)
    testing.expect(t,f.problems.count>0)
    core.destroy(&f.entities,floors[0])
    physics_test_step(&f,0)
    hit:Hit
    hit,found=raycast(core.ref(&f.state),{8,5,0},{0,-1,0})
    testing.expect(t,found && hit.entity==floors[2])
    testing.expect_value(t,f.state.world.shape_count,2)
}
