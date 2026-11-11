package mirai_physics

import "core:testing"
import cmath "core:math"

@(private="file")
Test_Triangles :: struct {
    vertices:[1024]Vec3,
    indices:[3072]u32,
    shapes:[1024]Shape_Handle,
    vertex_count,index_count:int,
    complete:bool,
}

@(private="file")
test_triangles :: proc(w:^World,box:Aabb,out:^Test_Triangles,filter:=QUERY_FILTER_DEFAULT) {
    out.vertex_count,out.index_count,out.complete=shapes_triangles(w,box,out.vertices[:],out.indices[:],filter,out.shapes[:])
}

@(private="file")
test_static_box :: proc(w:^World,position:Vec3,filter:=FILTER_DEFAULT,type:=Body_Type.Static,half:=Vec3{1,1,1}) -> (Body_Handle,Shape_Handle) {
    desc:=BODY_DESC_DEFAULT
    desc.type,desc.position=type,position
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape.filter=filter
    return body,shape_create(w,body,shape)
}

@(private="file")
test_bounds :: proc(out:^Test_Triangles) -> Aabb {
    box:=Aabb{out.vertices[0],out.vertices[0]}
    for v in out.vertices[:out.vertex_count] {box={vmin(box.min,v),vmax(box.max,v)}}
    return box
}

// Every index names a written vertex and every triangle of a convex shape faces away from its center.
@(private="file")
expect_outward :: proc(t:^testing.T,out:^Test_Triangles,center:Vec3,loc:=#caller_location) {
    for index in out.indices[:out.index_count] {
        if !testing.expect(t,int(index)<out.vertex_count,loc=loc) {return}
    }
    for i:=0;i<out.index_count;i+=3 {
        a,b,c:=out.vertices[out.indices[i]],out.vertices[out.indices[i+1]],out.vertices[out.indices[i+2]]
        n:=cross(b-a,c-a)
        if !testing.expectf(t,length(n)>1e-6 && dot(n,(a+b+c)/3-center)>0,"triangle %v faces in",i/3,loc=loc) {return}
    }
}

@(test)
static_triangles_cover_each_convex_shape_whole_on_its_surface_and_facing_out :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    prism,_:=test_prism(&w,4,cmath.sqrt(f32(2)),1)
    sphere:=test_static_shape(&w,Sphere{1},{0,0,0})
    capsule:=test_static_shape(&w,Capsule{0.5,1},{10,0,0})
    cylinder:=test_static_shape(&w,Cylinder{1,0.5},{20,0,0})
    box:=test_static_shape(&w,Box{{1,2,3}},{30,0,0})
    hull:=test_static_shape(&w,prism,{40,0,0})
    out:=new(Test_Triangles)
    defer free(out)
    shape:[1]Shape_Handle

    // A box that only touches the top of the sphere still gives all of it.
    test_triangles(&w,{{-0.1,0.9,-0.1},{0.1,2,0.1}},out)
    testing.expect(t,out.complete)
    testing.expect_value(t,out.vertex_count,2+(2*TRIANGLE_BANDS-1)*TRIANGLE_SEGMENTS)
    testing.expect_value(t,out.index_count,3*(4*TRIANGLE_BANDS-2)*TRIANGLE_SEGMENTS)
    for v in out.vertices[:out.vertex_count] {expect_near(t,length(v),1)}
    expect_outward(t,out,{})
    body_shapes(&w,sphere,shape[:])
    testing.expect_value(t,out.shapes[0],shape[0])
    testing.expect_value(t,out.shapes[out.index_count/3-1],shape[0])

    test_triangles(&w,{{9,-2,-1},{11,2,1}},out)
    testing.expect_value(t,out.vertex_count,2+2*TRIANGLE_BANDS*TRIANGLE_SEGMENTS)
    testing.expect_value(t,out.index_count,3*4*TRIANGLE_BANDS*TRIANGLE_SEGMENTS)
    for v in out.vertices[:out.vertex_count] {
        expect_near(t,length(v-Vec3{10,clamp(v.y,-1,1),0}),0.5)
    }
    expect_outward(t,out,{10,0,0})
    body_shapes(&w,capsule,shape[:])
    testing.expect_value(t,out.shapes[0],shape[0])

    test_triangles(&w,{{19,-1,-1},{21,1,1}},out)
    testing.expect_value(t,out.vertex_count,2+2*TRIANGLE_SEGMENTS)
    testing.expect_value(t,out.index_count,3*4*TRIANGLE_SEGMENTS)
    for v in out.vertices[:out.vertex_count] {
        expect_near(t,abs(v.y),0.5)
        radial:=length(Vec3{v.x-20,0,v.z})
        testing.expect(t,abs(radial)<1e-4 || abs(radial-1)<1e-4)
    }
    expect_outward(t,out,{20,0,0})
    body_shapes(&w,cylinder,shape[:])
    testing.expect_value(t,out.shapes[0],shape[0])

    test_triangles(&w,{{29,1,2},{29.5,5,5}},out)
    testing.expect_value(t,out.vertex_count,8)
    testing.expect_value(t,out.index_count,36)
    bounds:=test_bounds(out)
    expect_near3(t,bounds.min,{29,-2,-3})
    expect_near3(t,bounds.max,{31,2,3})
    expect_outward(t,out,{30,0,0})
    body_shapes(&w,box,shape[:])
    testing.expect_value(t,out.shapes[11],shape[0])

    // The square prism: four sides and two caps of four vertices.
    test_triangles(&w,{{39,-1,-1},{41,1,1}},out)
    testing.expect_value(t,out.vertex_count,8)
    testing.expect_value(t,out.index_count,36)
    expect_outward(t,out,{40,0,0})
    body_shapes(&w,hull,shape[:])
    testing.expect_value(t,out.shapes[0],shape[0])

    // Boxes that meet no shape, and boxes that are not valid, give nothing.
    for empty in ([3]Aabb{{{2,2,2},{3,3,3}},{{1,1,1},{0,0,0}},{{0,0,0},{cmath.inf_f32(1),1,1}}}) {
        test_triangles(&w,empty,out)
        testing.expect(t,out.complete && out.vertex_count==0 && out.index_count==0)
    }
}

@(test)
static_triangles_follow_the_local_transform_the_body_pose_and_the_size :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    turn:=q_axis_angle({0,1,0},cmath.PI/2)
    body:=body_create(&w,{type=.Static,position={5,0,0},rotation=turn})
    desc:=SHAPE_DESC_DEFAULT
    desc.geometry=Box{{2,0.5,1}}
    desc.transform={{1,0,0},QUAT_IDENTITY}
    shape_create(&w,body,desc)
    out:=new(Test_Triangles)
    defer free(out)
    // The local X of the box, 2 m from its center, turns to world -Z.
    test_triangles(&w,{{0,-1,-5},{10,1,5}},out)
    testing.expect_value(t,out.index_count,36)
    bounds:=test_bounds(out)
    expect_near3(t,bounds.min,{4,-0.5,-3})
    expect_near3(t,bounds.max,{6,0.5,1})
    expect_outward(t,out,{5,0,-1})

    // A triangle of a mesh, lifted by its shape and turned with its body, keeps its winding.
    vertices:=[3]Vec3{{0,0,0},{0,0,1},{1,0,0}}
    indices:=[3]u32{0,1,2}
    mesh,ok:=mesh_create(&w,{vertices=vertices[:],indices=indices[:]})
    testing.expect(t,ok)
    floor:=body_create(&w,{type=.Static,position={0,0,50},rotation=turn})
    desc.geometry=mesh
    desc.transform={{0,1,0},QUAT_IDENTITY}
    shape_create(&w,floor,desc)
    test_triangles(&w,{{-1,0,48},{2,2,52}},out)
    testing.expect_value(t,out.index_count,3)
    expect_near3(t,out.vertices[out.indices[0]],{0,1,50})
    expect_near3(t,out.vertices[out.indices[1]],{1,1,50})
    expect_near3(t,out.vertices[out.indices[2]],{0,1,49})
}

@(test)
static_triangles_take_the_mesh_triangles_and_heightfield_cells_in_the_box_without_holes :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // Cells of 1 m from -2 to 2 on X and Z.
    grid,grid_ok:=test_grid_mesh(&w,4,4)
    testing.expect(t,grid_ok)
    test_static_shape(&w,grid,{10,0,0})
    out:=new(Test_Triangles)
    defer free(out)
    test_triangles(&w,{{9.5,-1,-0.5},{10.5,1,0.5}},out)
    testing.expect(t,out.complete)
    testing.expect_value(t,out.index_count,3*8)
    testing.expect_value(t,out.vertex_count,24)
    bounds:=test_bounds(out)
    expect_near3(t,bounds.min,{9,0,-1})
    expect_near3(t,bounds.max,{11,0,1})
    expect_outward(t,out,{10,-1,0})
    // Partly outside the mesh: the column of cells at its edge.
    test_triangles(&w,{{11.5,-1,-0.5},{20,1,0.5}},out)
    testing.expect_value(t,out.index_count,3*4)
    // Above the plane of the mesh.
    test_triangles(&w,{{10,5,0},{11,6,1}},out)
    testing.expect_value(t,out.index_count,0)

    // Cells of 2 m by 2 m whose height grows 0.5 m per column, with a hole at column 1, row 1.
    heights:[25]f32
    for row in 0..<5 {
        for column in 0..<5 {heights[row*5+column]=f32(column)}
    }
    holes:[16]u8
    holes[1*4+1]=1
    field,field_ok:=heightfield_create(&w,{heights=heights[:],columns=5,rows=5,cell={2,0.5,2},holes=holes[:]})
    testing.expect(t,field_ok)
    test_static_shape(&w,field,{0,0,20})
    test_triangles(&w,{{0.5,-1,20.5},{5.5,10,25.5}},out)
    testing.expect_value(t,out.index_count,3*2*8)
    testing.expect_value(t,out.vertex_count,4*8)
    expect_outward(t,out,{0,-10,24})
    for i:=0;i<out.index_count;i+=6 {
        testing.expect(t,out.vertices[out.indices[i]]!=Vec3{2,0.5,22})
    }
    // The first cell, split along the diagonal from (column+1,row) to (column,row+1).
    first:=[6]Vec3{{0,0,20},{0,0,22},{2,0.5,20}, {2,0.5,20},{0,0,22},{2,0.5,22}}
    for expected,i in first {expect_near3(t,out.vertices[out.indices[i]],expected)}
    // Past the far side of the field: its last two columns of three rows.
    test_triangles(&w,{{5,-1,20.5},{100,10,25.5}},out)
    testing.expect_value(t,out.index_count,3*2*6)
    bounds=test_bounds(out)
    expect_near3(t,bounds.min,{4,1,20})
    expect_near3(t,bounds.max,{8,2,26})
    test_triangles(&w,{{-10,-1,20},{-1,10,28}},out)
    testing.expect_value(t,out.index_count,0)
    // A box of any size stays within the field.
    test_triangles(&w,{{-1e30,-1e30,-1e30},{1e30,1e30,1e30}},out)
    testing.expect(t,out.complete)
    testing.expect_value(t,out.index_count,3*(32+2*15))
}

@(test)
static_triangles_skip_dynamic_bodies_sensors_and_shapes_that_do_not_block_the_filter :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    wall,wall_shape:=test_static_box(&w,{0,0,0})
    test_static_box(&w,{3,0,0},{layers=2,block=~Collision_Layers(0)})
    test_static_box(&w,{6,0,0},{layers=1,overlap=~Collision_Layers(0)})
    test_static_box(&w,{9,0,0},{layers=1,block=0b10,overlap=1})
    test_static_box(&w,{12,0,0},type=.Dynamic)
    test_static_box(&w,{15,0,0},type=.Kinematic)
    everything:=Aabb{{-5,-5,-5},{20,5,5}}
    out:=new(Test_Triangles)
    defer free(out)

    // A character of layer 1 that layer 1 blocks.
    character:=Query_Filter{filter={layers=1,block=1}}
    test_triangles(&w,everything,out,character)
    testing.expect_value(t,out.index_count,36)
    for shape in out.shapes[:12] {testing.expect_value(t,shape,wall_shape)}
    character.overlaps=true
    test_triangles(&w,everything,out,character)
    testing.expect_value(t,out.index_count,36)
    character.ignore_body=wall
    test_triangles(&w,everything,out,character)
    testing.expect_value(t,out.index_count,0)

    // By object type every static shape of those layers but the sensor.
    test_triangles(&w,everything,out,{objects=~Collision_Layers(0)})
    testing.expect_value(t,out.index_count,3*36)
    testing.expect_value(t,out.vertex_count,24)
}

@(private="file") SENTINEL :: Vec3{7,7,7}

@(private="file")
reset :: proc(vertices:^[64]Vec3,indices:^[128]u32,shapes:^[32]Shape_Handle) {
    for &v in vertices {v=SENTINEL}
    for &i in indices {i=99}
    for &s in shapes {s=Shape_Handle(99)}
}

// Nothing was written from these positions on.
@(private="file")
untouched :: proc(t:^testing.T,vertices:^[64]Vec3,indices:^[128]u32,shapes:^[32]Shape_Handle,from_vertex,from_index,from_shape:int,loc:=#caller_location) {
    for v in vertices[from_vertex:] {if !testing.expect(t,v==SENTINEL,loc=loc) {return}}
    for i in indices[from_index:] {if !testing.expect(t,i==99,loc=loc) {return}}
    for s in shapes[from_shape:] {if !testing.expect(t,s==Shape_Handle(99),loc=loc) {return}}
}

@(test)
static_triangles_stop_when_the_buffers_are_full_without_writing_past_them :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    _,wall_shape:=test_static_box(&w,{0,0,0})
    box:=Aabb{{-2,-2,-2},{2,2,2}}
    vertices:[64]Vec3
    indices:[128]u32
    shapes:[32]Shape_Handle

    // The box needs 8 vertices, 36 indices and 12 shapes: one less of any writes nothing.
    reset(&vertices,&indices,&shapes)
    v,i,complete:=shapes_triangles(&w,box,vertices[:7],indices[:],shapes=shapes[:])
    testing.expect(t,v==0 && i==0 && !complete)
    untouched(t,&vertices,&indices,&shapes,0,0,0)
    v,i,complete=shapes_triangles(&w,box,vertices[:],indices[:35],shapes=shapes[:])
    testing.expect(t,v==0 && i==0 && !complete)
    untouched(t,&vertices,&indices,&shapes,0,0,0)
    v,i,complete=shapes_triangles(&w,box,vertices[:],indices[:],shapes=shapes[:11])
    testing.expect(t,v==0 && i==0 && !complete)
    untouched(t,&vertices,&indices,&shapes,0,0,0)
    v,i,complete=shapes_triangles(&w,box,vertices[:8],indices[:36],shapes=shapes[:12])
    testing.expect(t,v==8 && i==36 && complete)
    untouched(t,&vertices,&indices,&shapes,8,36,12)
    testing.expect_value(t,shapes[11],wall_shape)
    // Without shapes nothing limits the triangles but the indices.
    reset(&vertices,&indices,&shapes)
    v,i,complete=shapes_triangles(&w,box,vertices[:8],indices[:36])
    testing.expect(t,v==8 && i==36 && complete)
    untouched(t,&vertices,&indices,&shapes,8,36,0)

    // A mesh gives the triangles that fit, one by one.
    grid,ok:=test_grid_mesh(&w,4,4)
    testing.expect(t,ok)
    test_static_shape(&w,grid,{10,0,0})
    reset(&vertices,&indices,&shapes)
    v,i,complete=shapes_triangles(&w,{{8,-1,-2},{12,1,2}},vertices[:10],indices[:],shapes=shapes[:])
    testing.expect(t,v==9 && i==9 && !complete)
    untouched(t,&vertices,&indices,&shapes,10,9,3)
}

@(test)
static_changes_log_static_shapes_made_destroyed_moved_retyped_and_refiltered_but_not_dynamic_ones :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    boxes:[8]Aabb
    cursor:u64
    read :: proc(w:^World,cursor:^u64,boxes:^[8]Aabb) -> int {
        next,count,overflow:=static_changes(w,cursor^,boxes[:])
        if overflow {return -1}
        cursor^=next
        return count
    }
    unit:=Aabb{{-1,-1,-1},{1,1,1}}
    moved:=Aabb{{9,-1,-1},{11,1,1}}

    testing.expect_value(t,read(&w,&cursor,&boxes),0)
    ground,ground_shape:=test_static_box(&w,{0,0,0})
    testing.expect_value(t,read(&w,&cursor,&boxes),1)
    testing.expect_value(t,boxes[0],unit)

    crate,crate_shape:=test_static_box(&w,{0,5,0},type=.Dynamic)
    body_set_transform(&w,crate,{0,6,0},QUAT_IDENTITY)
    shape_set_filter(&w,crate_shape,{layers=2,block=~Collision_Layers(0)})
    body_set_type(&w,crate,.Kinematic)
    shape_destroy(&w,crate_shape)
    body_destroy(&w,crate)
    test_steps(&w,3)
    testing.expect_value(t,read(&w,&cursor,&boxes),0)

    // Moving a static body logs where it was and where it is.
    body_set_transform(&w,ground,{10,0,0},QUAT_IDENTITY)
    testing.expect_value(t,read(&w,&cursor,&boxes),2)
    testing.expect_value(t,boxes[0],unit)
    testing.expect_value(t,boxes[1],moved)

    // A filter that changes, not one set again.
    shape_set_filter(&w,ground_shape,{layers=2,block=~Collision_Layers(0)})
    shape_set_filter(&w,ground_shape,{layers=2,block=~Collision_Layers(0)})
    testing.expect_value(t,read(&w,&cursor,&boxes),1)
    testing.expect_value(t,boxes[0],moved)

    // From static and back; kinematic to dynamic is not static on either side.
    body_set_type(&w,ground,.Kinematic)
    body_set_type(&w,ground,.Dynamic)
    body_set_type(&w,ground,.Static)
    testing.expect_value(t,read(&w,&cursor,&boxes),2)
    testing.expect_value(t,boxes[0],moved)
    testing.expect_value(t,boxes[1],moved)

    // A shape made and destroyed on the static body, then the body with two shapes: one box around both.
    desc:=SHAPE_DESC_DEFAULT
    desc.geometry=Box{{1,1,1}}
    desc.transform={{3,0,0},QUAT_IDENTITY}
    extra:=shape_create(&w,ground,desc)
    shape_destroy(&w,extra)
    extra=shape_create(&w,ground,desc)
    testing.expect_value(t,read(&w,&cursor,&boxes),3)
    testing.expect_value(t,boxes[0],Aabb{{12,-1,-1},{14,1,1}})
    body_destroy(&w,ground)
    testing.expect_value(t,read(&w,&cursor,&boxes),1)
    testing.expect_value(t,boxes[0],Aabb{{9,-1,-1},{14,1,1}})

    // A sensor is no collision: made, moved, refiltered among sensors or destroyed, it logs nothing; turned
    // to block and back, it does.
    sensor,sensor_shape:=test_static_box(&w,{0,0,0},{layers=1,overlap=~Collision_Layers(0)})
    body_set_transform(&w,sensor,{10,0,0},QUAT_IDENTITY)
    shape_set_filter(&w,sensor_shape,{layers=2,overlap=~Collision_Layers(0)})
    testing.expect_value(t,read(&w,&cursor,&boxes),0)
    shape_set_filter(&w,sensor_shape,{layers=2,block=~Collision_Layers(0)})
    shape_set_filter(&w,sensor_shape,{layers=2,overlap=~Collision_Layers(0)})
    testing.expect_value(t,read(&w,&cursor,&boxes),2)
    body_destroy(&w,sensor)
    testing.expect_value(t,read(&w,&cursor,&boxes),0)
}

@(test)
static_change_readers_keep_their_own_cursors_and_overflow_when_they_fall_behind :: proc(t:^testing.T) {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=16,16,16,0
    desc.static_change_capacity=4
    w:World
    testing.expect(t,world_init(&w,desc))
    defer world_destroy(&w)
    boxes:[2]Aabb
    for i in 0..<3 {test_static_box(&w,{f32(10*i),0,0})}

    // A reader with room for two reads the third at its next call.
    next,count,overflow:=static_changes(&w,0,boxes[:])
    testing.expect(t,next==2 && count==2 && !overflow)
    testing.expect_value(t,boxes[1].min.x,f32(9))
    next,count,overflow=static_changes(&w,next,boxes[:])
    testing.expect(t,next==3 && count==1 && !overflow)
    testing.expect_value(t,boxes[0].min.x,f32(19))
    reader:=next

    // Three more: the ring keeps the last four. The reader at 3 still has them; one at 0 fell behind.
    for i in 3..<6 {test_static_box(&w,{f32(10*i),0,0})}
    next,count,overflow=static_changes(&w,0,boxes[:])
    testing.expect(t,next==6 && count==0 && overflow)
    next,count,overflow=static_changes(&w,reader,boxes[:])
    testing.expect(t,next==5 && count==2 && !overflow)
    testing.expect_value(t,boxes[0].min.x,f32(29))
    testing.expect_value(t,boxes[1].min.x,f32(39))
    next,count,overflow=static_changes(&w,next,boxes[:])
    testing.expect(t,next==6 && count==1 && !overflow)
    testing.expect_value(t,boxes[0].min.x,f32(49))
    // A cursor that is not one of this log.
    next,count,overflow=static_changes(&w,100,boxes[:])
    testing.expect(t,next==6 && count==0 && overflow)

    // Without a ring every change leaves the readers behind, but one at the newest change reads nothing.
    desc.static_change_capacity=0
    bare:World
    testing.expect(t,world_init(&bare,desc))
    defer world_destroy(&bare)
    next,count,overflow=static_changes(&bare,0,boxes[:])
    testing.expect(t,next==0 && count==0 && !overflow)
    test_static_box(&bare,{0,0,0})
    next,count,overflow=static_changes(&bare,0,boxes[:])
    testing.expect(t,next==1 && count==0 && overflow)
    next,count,overflow=static_changes(&bare,next,boxes[:])
    testing.expect(t,next==1 && count==0 && !overflow)
}

@(test)
restoring_a_snapshot_or_copying_a_state_leaves_every_static_change_reader_behind :: proc(t:^testing.T) {
    w,other:World
    testing.expect(t,test_world(&w) && test_world(&other))
    defer world_destroy(&w)
    defer world_destroy(&other)
    boxes:[4]Aabb
    test_static_box(&w,{0,0,0})
    buffer:World
    defer world_destroy(&buffer)
    saved:=test_keep(&buffer,&w)
    testing.expect(t,saved)
    test_static_box(&w,{5,0,0})
    current,_,_:=static_changes(&w,0,boxes[:])
    testing.expect_value(t,current,u64(2))

    testing.expect(t,test_restore(&w,&buffer))
    count:int
    overflow:bool
    for since in ([2]u64{0,current}) {
        current,count,overflow=static_changes(&w,since,boxes[:])
        testing.expect(t,overflow && count==0)
    }
    test_static_box(&w,{9,0,0})
    _,count,overflow=static_changes(&w,current,boxes[:])
    testing.expect(t,count==1 && !overflow)
    testing.expect_value(t,boxes[0].min.x,f32(8))

    head,_,_:=static_changes(&other,0,boxes[:])
    _,copied:=world_state_copy(&other,&w)
    testing.expect(t,copied)
    _,count,overflow=static_changes(&other,head,boxes[:])
    testing.expect(t,overflow && count==0)
}

@(test)
the_static_change_log_changes_no_simulation_result :: proc(t:^testing.T) {
    a,b:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=256,256,2048,64
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=8,4,2,256
    testing.expect(t,world_init(&a,desc))
    desc.static_change_capacity=0
    testing.expect(t,world_init(&b,desc))
    defer world_destroy(&a)
    defer world_destroy(&b)
    test_scene(&a)
    test_scene(&b)
    boxes:[16]Aabb
    cursor:u64
    for step in 0..<120 {
        for w in ([2]^World{&a,&b}) {
            test_scene_edit(w,step)
            if step%10==4 {
                ledge,_:=test_static_box(w,{f32(step%3)-1,0.2,2},half={0.5,0.2,0.5})
                if step%20==4 {body_set_transform(w,ledge,{f32(step%3)-1,0.2,-2},QUAT_IDENTITY)}
            }
            world_step(w,1.0/60)
        }
        next,_,_:=static_changes(&a,cursor,boxes[:])
        cursor=next
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"the worlds diverged at step %v",step)
            return
        }
    }
}
