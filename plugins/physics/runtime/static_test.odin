package physics

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

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

    // The three static colliders were made, the sensor too; then the floor moves and the crate falls in
    // place without a change.
    cursor,count,overflow=static_changes(physics,cursor,boxes[:])
    testing.expect(t,count==3 && !overflow)
    found:=0
    for box in boxes[:3] {
        if box_near(box,{{-5,-1,-5},{5,0,5}}) || box_near(box,{{-2,2,-1},{2,4,1}}) || box_near(box,{{2.5,0.5,2.5},{3.5,1.5,3.5}}) {found+=1}
    }
    testing.expect_value(t,found,3)
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
static_bounds_hold_every_static_collider :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    physics:=core.ref(&f.state)
    _,ok:=static_bounds(physics)
    testing.expect(t,!ok)
    physics_test_box(&f,{0,-0.5,0},{5,0.5,5})
    physics_test_box(&f,{20,3,0},{1,1,1})
    physics_test_box(&f,{0,40,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    physics_test_step(&f,0)
    box:mm.Aabb
    box,ok=static_bounds(physics)
    testing.expect(t,ok && box.min.x<=-5 && box.max.x>=21 && box.min.y<=-1 && box.max.y>=4 && box.max.y<10)
}
