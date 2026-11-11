package mirai_render

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:math"
import "core:testing"
import "core:time"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import mm "mirai:std/math"

@(test)
gpu_skin_preview_reuses_compute_and_buffers_without_mutating_the_scene :: proc(t:^testing.T) {
    f:Fixture
    if !skin_fixture(t,&f,false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    vertices,indices,given:=skin_test_geometry()
    given[0]={joints={0,0,0,0,0,0,0,1},weights={0,0,0,0,0,0,0,255}}
    g,origins,slot_words,built:=test_geometry(vertices[:],indices[:])
    if !testing.expect(t,built) {return}
    influences:=test_by_cluster(origins,given[:])
    // As a skinned mesh read from its file gives it, with no joints.
    g.flags+={.Skinned}
    source,created:=mesh_add_geometry(r,g,slot_words)
    if !testing.expect(t,created) {return}
    rest:=test_rest(r,source)
    main_skin,created_skin:=skin_create(r,source,influences,2)
    if !testing.expect(t,created_skin) {return}
    palette:=[2]Mat4{Mat4(1),Mat4(1)}
    testing.expect(t,skin_update(r,main_skin,palette[:]))
    scene_given(r,{{object_id=1,mesh=main_skin,transform=Mat4(1),tint={1,1,1}}},nil,{},Environment{})
    camera:=Camera{position={0,3,5},forward={0,-2,-5},up={0,1,0},fov_y=50,near=0.1,far=100,exposure=UNIT_EXPOSURE}
    if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
    record:=r.scene.meshes[main_skin]
    before,read_before:=test_posed(device,r,main_skin)
    testing.expect(t,read_before)
    preview:Skin_Preview_GPU
    defer skin_preview_destroy(device,&preview)
    if !testing.expect(t,skin_preview_init(r,&preview,g,influences,2)) {return}
    baseline:=rhi.device_stats(device)
    frame,mesh_count,view:=r.frame,len(r.scene.meshes),r.prev_view_proj
    state:=record.skin^
    joints:=[2]Skin_Joint{state.joints[0],state.joints[1]}
    actual:=make([]Gpu_Posed_Vertex,len(rest),context.temp_allocator)
    palette[1]=mm.transform_matrix({position={0.3,0.5,-0.2},rotation=mm.quat_axis_angle({0,0,1},0.35),scale={1.1,0.7,1.3}})
    start:=time.tick_now()
    for sample in 0..<8 {
        palette[1][0,3]+=0.02
        if !testing.expect(t,skin_preview_sample(r,&preview,palette[:],actual),r.error) {return}
        for vertex,i in rest {
            expected:=skin_test_sample(vertex,influences[i],palette[:])
            testing.expect(t,linalg.length(actual[i].position-expected.position)<1e-5)
            testing.expect(t,linalg.length(mm.normal_unpack(actual[i].normal)-expected.normal)<0.0002)
        }
    }
    fmt.printfln("preview skin 4 vertices: %.3f ms/sample (8 blocking samples)",time.duration_milliseconds(time.tick_since(start))/8)
    testing.expect_value(t,r.frame,frame);testing.expect_value(t,len(r.scene.meshes),mesh_count);testing.expect_value(t,r.prev_view_proj,view)
    testing.expect_value(t,record.skin.dirty,state.dirty);testing.expect_value(t,record.skin.settle,state.settle)
    testing.expect_value(t,record.skin.joints[0],joints[0]);testing.expect_value(t,record.skin.joints[1],joints[1])
    after,read_after:=test_posed(device,r,main_skin)
    testing.expect(t,read_after)
    for v,i in after {testing.expect_value(t,v,before[i])}
    resources:=rhi.device_stats(device)
    testing.expect_value(t,resources.buffers,baseline.buffers);testing.expect_value(t,resources.accels,baseline.accels)
    palette[0][3,0]=1
    testing.expect(t,!skin_preview_sample(r,&preview,palette[:],actual))
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

@(private)
skin_fixture :: proc(t:^testing.T,f:^Fixture,hardware:bool,allocator:=context.allocator,programs:=false,loc:=#caller_location)->bool {
    settings:=DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    // Images are compared pixel by pixel: every pixel traces its own rays,
    // to a sun with no size.
    settings.reference_lights=true
    settings.sun_radius=0
    settings.trace_mode=.Hardware if hardware else .Software
    return fixture_init(t,f,160,120,settings,desc={allocator=allocator},programs=programs,loc=loc)
}

@(private)
skin_test_grid :: proc(cells:int)->(vertices:[]Mesh_Vertex,indices:[]u32,influences:[]Skin_Influence) {
    vertices=make([]Mesh_Vertex,(cells+1)*(cells+1))
    influences=make([]Skin_Influence,len(vertices))
    indices=make([]u32,cells*cells*6)
    for &vertex,i in vertices {
        x,z:=f32(i%(cells+1))/f32(cells),f32(i/(cells+1))/f32(cells)
        vertex={position={(x-0.5)*2,0.5,(z-0.5)*2},normal={0,1,0},color={1,1,1}}
        influences[i]=test_two_joints(x)
    }
    for y in 0..<cells {for x in 0..<cells {
        first:=u32(y*(cells+1)+x)
        quad:=[6]u32{first,first+u32(cells)+1,first+1,first+1,first+u32(cells)+1,first+u32(cells)+2}
        copy(indices[(y*cells+x)*6:][:6],quad[:])
    }}
    return
}

@(test)
gpu_skin_refits_inner_nodes_after_a_large_deformation :: proc(t:^testing.T) {
    f:Fixture
    if !skin_fixture(t,&f,false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    // Trees of different depths share the passes of the frame.
    cells:=[2]int{32,5}
    skins:[2]Mesh_Handle
    descs:[2]Instance_Desc
    for count,i in cells {
        vertices,indices,influences:=skin_test_grid(count)
        defer delete(vertices);defer delete(indices);defer delete(influences)
        source,origins,_:=test_mesh_add(r,vertices,indices)
        created:bool
        skins[i],created=skin_create(r,source,test_by_cluster(origins,influences),2)
        if !testing.expect(t,created,r.error) {return}
        palette:=[2]Mat4{Mat4(1),Mat4(1)}
        palette[0][0,3]=3;palette[1][0,3]=3;palette[1][1,3]=2+f32(i)
        testing.expect(t,skin_update(r,skins[i],palette[:],true))
        descs[i]={object_id=u64(i+1),mesh=skins[i],transform=Mat4(1),tint={1,1,1}}
    }
    depths:[2]int
    for skin,i in skins {for level,depth in r.scene.meshes[skin].skin.binding.levels {if level.count>0 {depths[i]=depth}}}
    testing.expectf(t,depths[0]>depths[1],"depths %v",depths)
    scene_given(r,descs[:],nil,{},Environment{})
    testing.expect(t,renderer_frame(r,{camera={position={3,5,6},forward={0,-4,-6},up={0,1,0},fov_y=50,near=0.1,far=100,exposure=UNIT_EXPOSURE}}),r.error)
    for skin,i in skins {
        record:=r.scene.meshes[skin]
        nodes,triangles,read:=test_tree(device,r,skin)
        testing.expect(t,read)
        for node,i in nodes {if node.count==0 && i!=BVH_UNUSED_NODE {
            left,right:=nodes[node.left_first],nodes[node.left_first+1]
            testing.expect_value(t,node.bounds_min,linalg.min(left.bounds_min,right.bounds_min))
            testing.expect_value(t,node.bounds_max,linalg.max(left.bounds_max,right.bounds_max))
        }}
        distance,primitive:=bvh_ray_triangles(nodes,triangles,{3.01,5,0.03},{0,-1,0},10)
        expected:=4.5-(2+f32(i))*0.505
        // Weights are 255ths: one step of them moves the lift of 2+i metres by (2+i)/255.
        testing.expectf(t,primitive>=0 && abs(distance-expected)<(2+f32(i))/255,"pose %d: hit %d at %f, expected %f",i,primitive,distance,expected)
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

SKIN_BENCHMARK :: #config(SKIN_BENCHMARK,false)
@(test)
gpu_skin_benchmark_reports_skinning_and_refit_time :: proc(t:^testing.T) {
    shared_device.hold(t)
    when !SKIN_BENCHMARK {return} else {
        device,message:=rhi.device_create({app_name="mirai skin benchmark",allow_hardware_ray_tracing=true,upload_bytes_per_frame=16<<20})
        if !testing.expect(t,device!=nil,message) {return}
        defer rhi.device_destroy(device)
        r:Renderer
        settings:=DEFAULT_SETTINGS;settings.gi_enabled,settings.taa=false,false
        if !testing.expect(t,renderer_init(&r,{device=device,width=640,height=360,settings=settings}),r.error) {return}
        defer renderer_destroy(&r)
        vertices,indices,influences:=skin_test_grid(128)
        defer delete(vertices);defer delete(indices);defer delete(influences)
        source,origins,_:=test_mesh_add(&r,vertices,indices)
        skins:[8]Mesh_Handle
        instances:[8]Instance_Desc
        for &skin,i in skins {
            created:bool;skin,created=skin_create(&r,source,test_by_cluster(origins,influences),2)
            if !testing.expect(t,created,r.error) {return}
            transform:=Mat4(1);transform[0,3]=f32(i%4)*2.5-4;transform[2,3]=f32(i/4)*2.5
            instances[i]={object_id=u64(i+1),mesh=skin,transform=transform,tint={1,1,1}}
        }
        scene_given(&r,instances[:],nil,{direction={0.5,1,0.5},color={1,1,1},illuminance=1 * math.PI,enabled=true},{})
        camera:=Camera{position={0,6,10},forward={0,-6,-10},up={0,1,0},fov_y=50,near=0.1,far=100,exposure=UNIT_EXPOSURE}
        for hardware in ([2]bool{false,true}) {
            settings.trace_mode=.Hardware if hardware else .Software
            if !renderer_apply_settings(&r,settings) {continue}
            if hardware && !r.hardware_rt {continue}
            elapsed,gpu_time:f64
            for frame in 0..<220 {
                start:=time.tick_now()
                palette:=[2]Mat4{Mat4(1),Mat4(1)}
                palette[1][1,3]=0.5*math.sin(f32(frame)*0.02)
                for skin in skins {skin_update(&r,skin,palette[:])}
                if !testing.expect(t,renderer_frame(&r,{camera=camera}),r.error) {return}
                if frame>=100 {
                    elapsed+=time.duration_milliseconds(time.tick_since(start))
                    for timing in r.stats.timings {if timing.name=="skinning" {gpu_time+=f64(timing.ms)}}
                }
            }
            fmt.printfln("skin benchmark %s native=%v: %d vertices, %d triangles, 8 instances: GPU skin+BLAS %.3f ms; CPU wall frame %.3f ms",rhi.device_info(device).name,hardware,len(vertices)*8,len(indices)/3*8,gpu_time/120,elapsed/120)
        }
    }
}

@(private)
skin_test_geometry :: proc()->([4]Mesh_Vertex,[6]u32,[4]Skin_Influence) {
    normal:=linalg.normalize(Vec3{0,1,1})
    vertices:=[4]Mesh_Vertex{
        {position={-1,0.5,0.5},normal=normal,color={1,1,1}},
        {position={1,0.5,0.5},normal=normal,color={1,1,1}},
        {position={-1,1.5,-0.5},normal=normal,color={1,1,1}},
        {position={1,1.5,-0.5},normal=normal,color={1,1,1}},
    }
    influences:=[4]Skin_Influence{test_two_joints(0),test_two_joints(1),test_two_joints(0.25),test_two_joints(0.75)}
    return vertices,{0,2,1,1,2,3},influences
}

@(private)
skin_test_sample :: proc(v:Mesh_Vertex,influence:Skin_Influence,palette:[]Mat4)->Mesh_Vertex {
    blend:Mat4
    for weight,i in influence.weights {for row in 0..<4 {for column in 0..<4 {blend[row,column]+=palette[influence.joints[i]][row,column]*f32(weight)/255}}}
    p:=blend*Vec4{v.position.x,v.position.y,v.position.z,1}
    n:=linalg.transpose(linalg.inverse(blend))*Vec4{v.normal.x,v.normal.y,v.normal.z,0}
    result:=v;result.position=p.xyz;result.normal=linalg.normalize(n.xyz)
    return result
}

@(test)
gpu_skin_gets_its_software_tree_when_rays_go_back_to_software :: proc(t:^testing.T) {
    f:Fixture
    if !skin_fixture(t,&f,true) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    if !r.hardware_rt {fmt.println("skin native RT skipped: device has no ray queries");return}
    vertices,indices,given:=skin_test_geometry()
    source,origins,added:=test_mesh_add(r,vertices[:],indices[:])
    if !testing.expect(t,added) {return}
    rest:=test_rest(r,source)
    influences:=test_by_cluster(origins,given[:])
    skin,created:=skin_create(r,source,influences,2)
    if !testing.expect(t,created,r.error) {return}
    testing.expect(t,r.scene.meshes[source].rays[0].bvh_node_count==0 && r.scene.meshes[skin].rays[0].bvh_node_count==0,"rays traced by hardware keep no software tree")
    // The pose builds its own: the source is gone.
    testing.expect(t,mesh_remove(r,source))
    palette:=[2]Mat4{Mat4(1),Mat4(1)}
    palette[1][0,3]=0.5;palette[1][1,3]=0.4
    testing.expect(t,skin_update(r,skin,palette[:],true))
    scene_given(r,{{object_id=1,mesh=skin,transform=Mat4(1),tint={1,1,1}}},nil,{},Environment{})
    camera:=Camera{position={3,4,6},forward={-3,-3.2,-6},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    settings:=r.settings
    settings.trace_mode=.Software
    testing.expect(t,renderer_apply_settings(r,settings),r.error)
    record:=r.scene.meshes[skin]
    testing.expect(t,!r.hardware_rt && record.rays[0].bvh_node_count>0)
    for _ in 0..<2 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
    rhi.device_wait_idle(device)
    nodes,triangles,read:=test_tree(device,r,skin)
    testing.expect(t,read)
    target:=test_centroid(rest,origins,influences,palette[:])
    ray,primitive:=bvh_ray_triangles(nodes,triangles,target+Vec3{0,5,0},{0,-1,0},10)
    testing.expectf(t,primitive>=0 && abs(ray-5)<1e-4,"the tree refit to the pose: hit %d at %f",primitive,ray)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

@(test)
gpu_skin_preserves_bind_source_motion_normals_bounds_and_refits_both_ray_paths :: proc(t:^testing.T) {
    for hardware in ([2]bool{false,true}) {
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        defer mem.tracking_allocator_destroy(&tracker)
        f:Fixture
        if !skin_fixture(t,&f,hardware,mem.tracking_allocator(&tracker)) {return}
        defer fixture_destroy(&f)
        r,device:=f.renderer,f.device
        if hardware && !r.hardware_rt {fmt.println("skin native RT skipped: device has no ray queries");continue}
        vertices,indices,given:=skin_test_geometry()
        source,origins,added:=test_mesh_add(r,vertices[:],indices[:])
        if !testing.expect(t,added) {return}
        rest:=test_rest(r,source)
        influences:=test_by_cluster(origins,given[:])
        skin,created:=skin_create(r,source,influences,2)
        if !testing.expect(t,created,r.error) {return}
        first_resources:=rhi.device_stats(device)
        independent,created_second:=skin_create(r,source,influences,2)
        if !testing.expect(t,created_second,r.error) {return}
        testing.expect_value(t,rhi.device_stats(device).buffers,first_resources.buffers)
        testing.expect_value(t,r.scene.meshes[skin].slab_axes,u32(0))
        testing.expect(t,mesh_remove(r,source))
        ground:=[4]Mesh_Vertex{
            {position={-5,0,-5},normal={0,1,0},color={1,1,1}},
            {position={5,0,-5},normal={0,1,0},color={1,1,1}},
            {position={-5,0,5},normal={0,1,0},color={1,1,1}},
            {position={5,0,5},normal={0,1,0},color={1,1,1}},
        }
        floor,_:=mesh_add(r,ground[:],indices[:])
        descs:=[2]Instance_Desc{
            {object_id=1,mesh=floor,transform=Mat4(1),tint={0.7,0.7,0.7}},
            {object_id=2,mesh=skin,transform=Mat4(1),tint={0.8,0.2,0.1}},
        }
        sun:=Sun_Desc{direction={-0.5,1,0.2},color={1,1,1},illuminance=2 * math.PI,enabled=true}
        environment:=Environment{}
        scene_given(r,descs[:],nil,sun,environment)
        camera:=Camera{position={3,4,6},forward={-3,-3.2,-6},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
        palette:=[2]Mat4{Mat4(1),Mat4(1)}
        palette[1][0,3]=0.5;palette[1][1,1]=1.4;palette[1][2,2]=0.6
        testing.expect(t,skin_update(r,skin,palette[:],true))
        r.scene.changes={}
        skins_bounds(r)
        testing.expect(t,r.scene.changes.count>0 || r.scene.changes.all,"deformation must wake indirect lighting")
        if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
        prior:=palette
        palette[0][0,3]=-0.3;palette[1][0,3]=1.4;palette[1][1,3]=0.4
        testing.expect(t,skin_update(r,skin,palette[:]))
        if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
        record:=r.scene.meshes[skin]
        actual,read_actual:=test_posed(device,r,skin)
        previous,read_previous:=test_posed(device,r,skin,true)
        testing.expect(t,read_actual && read_previous)
        reference:[4]Mesh_Vertex
        for v,i in rest {
            expected:=skin_test_sample(v,influences[i],palette[:])
            old:=skin_test_sample(v,influences[i],prior[:])
            reference[origins[i]]=expected
            testing.expectf(t,linalg.length(actual[i].position-expected.position)<1e-5,"skin position %d: %v != %v",i,actual[i].position,expected.position)
            testing.expectf(t,linalg.dot(mm.normal_unpack(actual[i].normal),expected.normal)>0.99999,"skin normal %d",i)
            testing.expectf(t,linalg.length(previous[i].position-old.position)<1e-5,"previous skin position %d",i)
            for axis in 0..<3 {testing.expect(t,expected.position[axis]>=record.bounds_min[axis]-1e-5 && expected.position[axis]<=record.bounds_max[axis]+1e-5)}
        }
        unchanged,read_unchanged:=test_posed(device,r,independent)
        testing.expect(t,read_unchanged)
        for v,i in rest {testing.expectf(t,linalg.length(unchanged[i].position-v.position)<1e-5,"a pose never updated keeps vertex %d at rest",i)}
        if hardware {
            testing.expect(t,record.rays[0].bvh_node_count==0,"rays traced by hardware keep no software tree")
        } else {
            nodes,triangles,read:=test_tree(device,r,skin)
            testing.expect(t,read)
            target:=(reference[0].position+reference[1].position+reference[2].position)/3
            ray,primitive:=bvh_ray_triangles(nodes,triangles,target+Vec3{0,5,0},{0,-1,0},10)
            testing.expectf(t,primitive>=0 && abs(ray-5)<1e-4,"GPU refitted BLAS hit: %d %f",primitive,ray)
        }
        for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        actual,read_actual=test_posed(device,r,skin)
        previous,read_previous=test_posed(device,r,skin,true)
        testing.expect(t,read_actual && read_previous)
        for v,i in actual {testing.expect_value(t,v.position,previous[i].position)}
        image,_,_,captured:=golden_capture(r);defer delete(image)
        if !testing.expect(t,captured,r.error) {return}
        ref_mesh,_:=mesh_add(r,reference[:],indices[:])
        descs[1].mesh=ref_mesh
        scene_given(r,descs[:],nil,sun,environment)
        for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        expected_image,_,_,captured_reference:=golden_capture(r);defer delete(expected_image)
        if !testing.expect(t,captured_reference,r.error) {return}
        difference:=0
        for value,i in image {if abs(int(value)-int(expected_image[i]))>2 {difference+=1}}
        testing.expectf(t,difference<12,"skinned raster and shadow image differs from deformed geometry (%d channels; hardware %v)",difference,hardware)
        descs[1].mesh=skin;scene_given(r,descs[:],nil,sun,environment)
        for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        if r.hardware_rt {
            r.scene.meshes[skin].skin.refits=SKIN_REBUILD_INTERVAL
            testing.expect(t,skin_update(r,skin,palette[:],true))
            for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
            testing.expect_value(t,r.scene.meshes[skin].skin.refits,0)
            rebuilt,_,_,captured_rebuilt:=golden_capture(r);defer delete(rebuilt)
            if !testing.expect(t,captured_rebuilt,r.error) {return}
            difference=0
            for value,i in rebuilt {if abs(int(value)-int(expected_image[i]))>2 {difference+=1}}
            testing.expectf(t,difference<12,"image over the rebuilt native BLAS differs from deformed geometry (%d channels)",difference)
        }
        before:=rhi.device_stats(device)
        allocations:=tracker.total_allocation_count
        {
            context.allocator=mem.tracking_allocator(&tracker)
            for i in 0..<8 {palette[1][0,3]+=0.01;testing.expect(t,skin_update(r,skin,palette[:]));testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        }
        testing.expect_value(t,tracker.total_allocation_count,allocations)
        after:=rhi.device_stats(device)
        testing.expect_value(t,after.buffers,before.buffers);testing.expect_value(t,after.accels,before.accels)
        testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
        testing.expect(t,mesh_remove(r,skin));testing.expect(t,mesh_remove(r,independent))
    }
}

// A pose with a part draws it collapsed in a view that does not draw its
// layers, and in a view that leaves them out of its own body when the pose is
// of that body; every other view draws it whole, from the same skinning.
@(test)
a_view_that_leaves_out_the_layers_of_a_skinned_part_draws_it_collapsed :: proc(t:^testing.T) {
    f:Fixture
    if !skin_fixture(t,&f,false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    red:=DEFAULT_MATERIAL
    red.base_color={1,0,0}
    materials_set(r,{red})
    // The left half on joint 0; the right half, the part, on joint 1.
    vertices:[8]Mesh_Vertex
    influences:[8]Skin_Influence
    xs:=[4]f32{-3,0,0,3}
    for i in 0..<8 {
        quad,corner:=i/4,i%4
        z:=f32(-3) if corner<2 else 3
        vertices[i]={position={xs[quad*2+corner%2],0,z},normal={0,1,0},tangent={1,0,0,1},color={1,1,1},material=1}
        influences[i]={joints={u16(quad),0,0,0,0,0,0,0},weights={255,0,0,0,0,0,0,0}}
    }
    indices:=[12]u32{0,2,1,1,2,3, 4,6,5,5,6,7}
    source,origins,added:=test_mesh_add(r,vertices[:],indices[:])
    if !testing.expect(t,added) {return}
    pose,created:=skin_create(r,source,test_by_cluster(origins,influences[:]),2,{},true)
    if !testing.expect(t,created,r.error) {return}
    PART :: u32(1)<<15
    collapse:=Mat4{}
    collapse[0,3],collapse[3,3]=9,1
    palette:=[2]Mat4{Mat4(1),Mat4(1)}
    part:=[2]Mat4{Mat4(1),collapse}
    testing.expect(t,skin_update(r,pose,palette[:],true,nil,{palette=part[:],layers=PART}),r.error)
    scene_given(r,{{object_id=1,mesh=pose,transform=Mat4(1),tint={1,1,1},owner=1}},nil,{},{})
    Case :: struct {own:u8,own_hidden,layers:u32,right:bool}
    cases:=[?]Case{
        {0,0,0,true},        // a view that draws every layer
        {0,0,~PART,false},   // a view that does not draw the layer of the part
        {1,PART,0,false},    // the view of the player whose body it is
        {2,PART,0,true},     // the view of another player
    }
    width,height:=int(r.targets.width),int(r.targets.height)
    pixels:=make([]u8,width*height*4,context.temp_allocator)
    for c in cases {
        camera:=Camera{position={0,2,0},forward={0,-2,0},up={0,0,-1},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE,own=c.own,own_hidden=c.own_hidden,layers=c.layers}
        for _ in 0..<2 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        rhi.device_wait_idle(device)
        testing.expect(t,golden_read_texture(device,r.targets.albedo,pixels),rhi.device_error(device))
        left,right:=0,0
        for y in 0..<height {for x in 0..<width {if pixels[(y*width+x)*4]>200 {if x<width/2 {left+=1} else {right+=1}}}}
        half:=width*height/2
        testing.expectf(t,left==half,"own %d, own_hidden %#x, layers %#x: the rest is drawn whole (%d of %d)",c.own,c.own_hidden,c.layers,left,half)
        testing.expectf(t,(right==half)==c.right && (right==0)==!c.right,"own %d, own_hidden %#x, layers %#x: %d pixels of the part",c.own,c.own_hidden,c.layers,right)
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// The software tree of level 0 of a mesh, as the GPU holds it.
@(private)
test_tree :: proc(device:^rhi.Device,r:^Renderer,handle:Mesh_Handle)->(nodes:[]Gpu_Bvh_Node,triangles:[]Gpu_Bvh_Triangle,ok:bool) {
    ray:=r.scene.meshes[handle].rays[0]
    nodes=make([]Gpu_Bvh_Node,int(ray.bvh_node_count),context.temp_allocator)
    triangles=make([]Gpu_Bvh_Triangle,int(ray.triangle_count),context.temp_allocator)
    ok=rhi.buffer_read_slice(device,r.scene.blas_node_buffer,u64(ray.bvh_root)*size_of(Gpu_Bvh_Node),nodes) &&
       rhi.buffer_read_slice(device,r.scene.blas_triangle_buffer,u64(ray.triangle_offset)*size_of(Gpu_Bvh_Triangle),triangles)
    return
}

// The centre of the first triangle of skin_test_geometry, posed by the palette.
@(private)
test_centroid :: proc(rest:[]Mesh_Vertex,origins:[]u32,influences:[]Skin_Influence,palette:[]Mat4)->(center:Vec3) {
    for origin in ([3]u32{0,2,1}) {
        for given,v in origins {if given==origin {center+=skin_test_sample(rest[v],influences[v],palette).position/3}}
    }
    return
}

// A program that moves vertices moves a skin where its skin posed it, now
// and in the frame before, without moving it twice when the skin poses it
// again; its box grows by the reach of the program.
@(test)
gpu_a_program_moves_a_skin_after_its_skin_now_and_before :: proc(t:^testing.T) {
    f:Fixture
    if !skin_fixture(t,&f,false,programs=true) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    pieces:=program_find(r,"Pieces",.Surface)
    if !testing.expect(t,pieces!=nil,"the tests have the Pieces program") {return}
    moving:=DEFAULT_MATERIAL
    moving.program_id=pieces.id
    moving.custom_params=program_defaults(pieces)
    Value :: struct {name:string,value:[4]f64}
    // Its one piece goes 3 m along +X at progress 0, without turning.
    for v in ([]Value{{"progress",{}},{"spread",{}},{"turn",{}},{"direction",{1,0,0,0}},{"distance",{3,0,0,0}},{"reach",{3,0,0,0}}}) {
        testing.expectf(t,program_parameter_set(&moving.custom_params,program_parameter(pieces,v.name),v.value),"Pieces takes %s",v.name)
    }
    materials_set(r,{moving})
    vertices,indices,_:=skin_test_geometry()
    source,_,added:=test_mesh_add(r,vertices[:],indices[:])
    if !testing.expect(t,added) {return}
    rest:=test_rest(r,source)
    influences:=make([]Skin_Influence,len(rest),context.temp_allocator)
    for &influence in influences {influence.weights[0]=255}
    skin,created:=skin_create(r,source,influences,1)
    if !testing.expect(t,created,r.error) {return}
    scene_given(r,{{object_id=1,mesh=skin,transform=Mat4(1),material=1,tint={1,1,1}}},nil,{},{})
    camera:=Camera{position={3,4,6},forward={-3,-3.2,-6},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    lifted:=[1]Mat4{Mat4(1)}
    lifted[0][1,3]=1
    testing.expect(t,skin_update(r,skin,lifted[:],true))
    if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
    lifted[0][1,3]=2
    testing.expect(t,skin_update(r,skin,lifted[:]))
    if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
    s:=&r.scene
    testing.expect(t,s.instances[0].meta.x&INSTANCE_MESH_MASK==u32(skin) && s.meshes[skin].skin.moves,"a skin is moved in place")
    testing.expect(t,s.instances[0].bounds_max.x>=s.meshes[skin].bounds_max.x+3-1e-4,"its box grows by the reach")
    now,read_now:=test_posed(device,r,skin)
    before,read_before:=test_posed(device,r,skin,true)
    if !testing.expect(t,read_now && read_before) {return}
    for v,i in rest {
        testing.expectf(t,linalg.length(now[i].position-(v.position+{3,2,0}))<1e-4,"vertex %d moved after its skin: %v",i,now[i].position)
        testing.expectf(t,linalg.length(before[i].position-(v.position+{3,1,0}))<1e-4,"vertex %d where it was the frame before: %v",i,before[i].position)
    }
    for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
    now,_=test_posed(device,r,skin)
    before,_=test_posed(device,r,skin,true)
    for v,i in rest {
        testing.expectf(t,linalg.length(now[i].position-(v.position+{3,2,0}))<1e-4,"vertex %d is moved once: %v",i,now[i].position)
        testing.expectf(t,linalg.length(before[i].position-now[i].position)<1e-5,"vertex %d at rest draws no motion",i)
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
