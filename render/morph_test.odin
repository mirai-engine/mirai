package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import mm "mirai:std/math"

// A vertex of the bind shape moved by one target at a weight: the normal made
// unit length again, and the tangent made orthogonal to it.
@(private="file")
morph_test_shape :: proc(v:Mesh_Vertex,delta:Morph_Delta,weight:f32)->Mesh_Vertex {
    result:=v
    result.position+=asset.morph_position(delta.position,TEST_MORPH_STEP)*weight
    result.normal=linalg.normalize(v.normal+asset.morph_normal(delta.normal)*weight)
    tangent:=v.tangent.xyz+asset.morph_tangent(delta.tangent)*weight
    tangent-=result.normal*linalg.dot(result.normal,tangent)
    result.tangent.xyz=linalg.normalize(tangent)
    return result
}

@(private="file")
morph_test_tangent :: proc(tangent:Vec3,influence:Skin_Influence,palette:[]Mat4)->Vec3 {
    blend:Mat4
    for weight,i in influence.weights {for row in 0..<4 {for column in 0..<4 {blend[row,column]+=palette[influence.joints[i]][row,column]*f32(weight)/255}}}
    return linalg.normalize((blend*Vec4{tangent.x,tangent.y,tangent.z,0}).xyz)
}

@(test)
gpu_morphs_move_the_bind_shape_before_the_skin_with_motion_tangents_bounds_and_both_ray_paths :: proc(t:^testing.T) {
    for hardware in ([2]bool{false,true}) {
        tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
        f:Fixture
        if !skin_fixture(t,&f,hardware,mem.tracking_allocator(&tracker)) {return}
        defer fixture_destroy(&f)
        r,device:=f.renderer,f.device
        if hardware && !r.hardware_rt {fmt.println("morph native RT skipped: device has no ray queries");continue}
        vertices,indices,given:=skin_test_geometry()
        for &vertex in vertices {vertex.tangent={1,0,0,1}}
        source,origins,added:=test_mesh_add(r,vertices[:],indices[:])
        if !testing.expect(t,added) {return}
        rest:=test_rest(r,source)
        influences:=test_by_cluster(origins,given[:])
        ranges:=[4]Morph_Range{{0,1},{1,1},{2,1},{3,1}}
        deltas:[4]Morph_Delta
        for &delta,i in deltas {delta=test_morph_delta(0,{.4*f32(i),.3,0},{.15,0,0},{0,.2,.1})}
        data:=test_morph_by_cluster(origins,{ranges=ranges[:],deltas=deltas[:],count=1,step=TEST_MORPH_STEP})
        skin,created:=skin_create(r,source,influences,2,data)
        if !testing.expect(t,created,r.error) {return}
        other,created_other:=skin_create(r,source,influences,2,data)
        if !testing.expect(t,created_other,r.error) {return}
        testing.expect(t,r.scene.meshes[skin].skin.binding==r.scene.meshes[other].skin.binding,"poses of one source and the same targets share their binding")
        broken:=deltas;broken[1].target=1
        _,refused:=skin_create(r,source,influences,2,test_morph_by_cluster(origins,{ranges=ranges[:],deltas=broken[:],count=1,step=TEST_MORPH_STEP}))
        testing.expect(t,!refused,"a delta of a target the pose does not have is refused")
        _,stepless:=skin_create(r,source,influences,2,test_morph_by_cluster(origins,{ranges=ranges[:],deltas=deltas[:],count=1}))
        testing.expect(t,!stepless,"deltas without a step are refused")
        testing.expect(t,mesh_remove(r,source))
        palette:=[2]Mat4{Mat4(1),Mat4(1)}
        palette[1][1,1]=1.3;palette[1][0,3]=.25
        sun:=Sun_Desc{direction={-.4,1,.3},color={1,1,1},illuminance=2*math.PI,enabled=true}
        scene_set(r,{{object_id=1,mesh=skin,transform=Mat4(1),tint={1,.5,.2}}},nil,sun,{})
        camera:=Camera{position={3,4,6},forward={-3,-3.2,-6},up={0,1,0},fov_y=50,near=.05,far=100,exposure=UNIT_EXPOSURE}
        testing.expect(t,skin_update(r,skin,palette[:],true,{.75}))
        if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
        testing.expect(t,skin_update(r,skin,palette[:],false,{-1.5}))
        if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
        record:=r.scene.meshes[skin]
        actual,read_actual:=test_posed(device,r,skin)
        before,read_before:=test_posed(device,r,skin,true)
        testing.expect(t,read_actual && read_before)
        reference:[4]Mesh_Vertex
        for vertex,i in rest {
            delta:=deltas[origins[i]]
            current:=morph_test_shape(vertex,delta,-1.5)
            expected:=skin_test_sample(current,influences[i],palette[:])
            previous:=skin_test_sample(morph_test_shape(vertex,delta,.75),influences[i],palette[:])
            reference[origins[i]]=expected
            testing.expectf(t,linalg.length(actual[i].position-expected.position)<1e-5,"morph and skin position %d",i)
            testing.expectf(t,linalg.dot(mm.normal_unpack(actual[i].normal),expected.normal)>.99999,"morph and skin normal %d",i)
            tangent,_:=mm.tangent_unpack(actual[i].tangent)
            testing.expectf(t,linalg.dot(tangent,morph_test_tangent(current.tangent.xyz,influences[i],palette[:]))>.9999,"morph and skin tangent %d",i)
            testing.expectf(t,linalg.length(before[i].position-previous.position)<1e-5,"previous position %d takes the previous weight",i)
            for axis in 0..<3 {testing.expect(t,expected.position[axis]>=record.bounds_min[axis]-1e-5 && expected.position[axis]<=record.bounds_max[axis]+1e-5)}
        }
        if !hardware {
            nodes,triangles,read:=test_tree(device,r,skin)
            testing.expect(t,read)
            target:=(reference[0].position+reference[1].position+reference[2].position)/3
            distance,primitive:=bvh_ray_triangles(nodes,triangles,target+Vec3{0,5,0},{0,-1,0},10)
            testing.expectf(t,primitive>=0 && abs(distance-5)<1e-4,"the tree refits to the morphed pose: hit %d at %f",primitive,distance)
        }
        for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        image,_,_,captured:=golden_capture(r);defer delete(image)
        if !testing.expect(t,captured,r.error) {return}
        shape,_:=mesh_add(r,reference[:],indices[:])
        scene_set(r,{{object_id=1,mesh=shape,transform=Mat4(1),tint={1,.5,.2}}},nil,sun,{})
        for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        expected_image,_,_,captured_reference:=golden_capture(r);defer delete(expected_image)
        if !testing.expect(t,captured_reference,r.error) {return}
        difference:=0
        for value,i in image {if abs(int(value)-int(expected_image[i]))>2 {difference+=1}}
        testing.expectf(t,difference<12,"the morphed raster and its rays differ from the shape they make (%d channels; hardware %v)",difference,hardware)
        scene_set(r,{{object_id=1,mesh=skin,transform=Mat4(1),tint={1,.5,.2}}},nil,sun,{})
        for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        // What did not change is not made again.
        testing.expect(t,skin_update(r,skin,palette[:],false,{-1.5}))
        testing.expect(t,!r.scene.meshes[skin].skin.dirty && !r.scene.meshes[skin].skin.bounds_dirty)
        resources:=rhi.device_stats(device)
        allocations:=tracker.total_allocation_count
        {
            context.allocator=mem.tracking_allocator(&tracker)
            for k in 0..<8 {testing.expect(t,skin_update(r,skin,palette[:],false,{f32(k)*.2-1}));testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        }
        testing.expect_value(t,tracker.total_allocation_count,allocations)
        testing.expect_value(t,rhi.device_stats(device).buffers,resources.buffers)
        testing.expect_value(t,rhi.device_stats(device).accels,resources.accels)
        testing.expect(t,!skin_update(r,skin,palette[:],false,{transmute(f32)u32(0x7fc00000)}))
        testing.expect(t,!skin_update(r,skin,palette[:],false,{1,2}))
        testing.expect(t,mesh_remove(r,skin) && mesh_remove(r,other) && mesh_remove(r,shape))
        testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
    }
}

@(test)
gpu_skins_with_influences_of_every_level_pose_each_level_and_keep_its_history_and_bounds :: proc(t:^testing.T) {
    f:Fixture
    if !skin_fixture(t,&f,false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    high:=[4]Mesh_Vertex{
        {position={-.8,-.8,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
        {position={.8,-.8,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
        {position={.8,.8,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
        {position={-.8,.8,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
    }
    low:=[3]Mesh_Vertex{
        {position={-.7,-.7,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
        {position={.7,-.7,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
        {position={0,1.3,0},normal={0,0,1},color={1,1,1},tangent={1,0,0,1}},
    }
    // Level 0 the square, level 1 a triangle, one cluster each.
    vertices:[7]Mesh_Vertex
    for vertex,i in high {vertices[i]=vertex}
    for vertex,i in low {vertices[4+i]=vertex}
    indices:=[9]u32{0,1,2,0,2,3,4,5,6}
    levels:=[2]asset.Level_Source{{0,6,0},{6,3,.03}}
    // A mesh removed before leaves a hole where the source lands: the pose goes elsewhere.
    filler:[20]Mesh_Vertex
    for &vertex,i in filler {vertex=high[i%len(high)]}
    filler_indices:=[18]u32{0,1,2,0,2,3,0,1,2,0,2,3,0,1,2,0,2,3}
    hole,hole_added:=mesh_add(r,filler[:],filler_indices[:])
    if !testing.expect(t,hole_added) {return}
    source,origins,source_added:=test_mesh_add(r,vertices[:],indices[:],levels[:])
    if !testing.expect(t,source_added && mesh_remove(r,hole)) {return}
    rest:=test_rest(r,source)
    given:[7]Skin_Influence
    for &influence,i in given {influence.joints[0]=0 if i<4 else 1;influence.weights[0]=255}
    influences:=test_by_cluster(origins,given[:])
    ranges:[7]Morph_Range
    deltas:[7]Morph_Delta
    for &range,i in ranges {range={first=u32(i),count=1};deltas[i]=test_morph_delta(0,{0,.1*f32(i+1),.1},{.1,0,0})}
    single,_,_:=test_mesh_add(r,vertices[:],indices[:],levels[:])
    level0,_:=level0_vertices(&r.scene,r.scene.meshes[single])
    level_zero,level_zero_ok:=skin_create(r,single,influences[:level0],2)
    testing.expect(t,level_zero_ok && r.scene.meshes[level_zero].flags&MESH_FLAG_LEVEL0!=0,"influences of level 0 pose that level alone")
    skin,created:=skin_create(r,source,influences,2,test_morph_by_cluster(origins,{ranges=ranges[:],deltas=deltas[:],count=1,step=TEST_MORPH_STEP}))
    if !testing.expect(t,created,r.error) {return}
    testing.expect(t,mesh_remove(r,source) && mesh_remove(r,single) && mesh_remove(r,level_zero))
    record:=r.scene.meshes[skin]
    testing.expect(t,record.level_count==2 && record.flags&MESH_FLAG_LEVEL0==0 && record.vertices_posed==record.vertex_count,"the levels follow the pose")
    testing.expect_value(t,gpu_mesh(record).previous_word,record.posed_word+record.vertices_posed*POSED_WORDS)
    coarse,_:=record_level(&r.scene,record,1)
    scene_set(r,{{object_id=1,mesh=skin,transform=Mat4(1),tint={1,1,1}}},nil,{},{})
    camera:=Camera{position={0,0,5},forward={0,0,-5},up={0,1,0},fov_y=50,near=.1,far=100,exposure=UNIT_EXPOSURE}
    previous_palette:=[2]Mat4{Mat4(1),Mat4(1)}
    previous_weight:f32
    for frame in 0..<3 {
        palette:=[2]Mat4{Mat4(1),Mat4(1)}
        palette[0][0,3]=f32(frame)*.1;palette[1][1,3]=f32(frame)*.2
        weight:=f32(frame)*-.75+.5
        settings:=r.settings
        settings.lod_error_pixels=0 if frame==0 else 100
        testing.expect(t,renderer_apply_settings(r,settings))
        testing.expect(t,skin_update(r,skin,palette[:],frame==0,{weight}))
        if !testing.expect(t,renderer_frame(r,{camera=camera}),r.error) {return}
        if frame==0 {previous_palette,previous_weight=palette,weight}
        actual,read_actual:=test_posed(device,r,skin)
        before,read_before:=test_posed(device,r,skin,true)
        if !testing.expect(t,read_actual && read_before) {return}
        bounds:=r.scene.meshes[skin]
        for influence,i in influences {
            vertex,delta:=rest[i],deltas[origins[i]]
            expected:=skin_test_sample(morph_test_shape(vertex,delta,weight),influence,palette[:])
            previous:=skin_test_sample(morph_test_shape(vertex,delta,previous_weight),influence,previous_palette[:])
            testing.expectf(t,linalg.length(actual[i].position-expected.position)<1e-5,"vertex %d of its level at frame %d",i,frame)
            testing.expectf(t,linalg.length(before[i].position-previous.position)<1e-5,"previous vertex %d at frame %d",i,frame)
            for axis in 0..<3 {testing.expect(t,expected.position[axis]>=bounds.bounds_min[axis]-1e-5 && expected.position[axis]<=bounds.bounds_max[axis]+1e-5)}
        }
        state:[1]Gpu_Cull_State
        visible:[1][2]u32
        testing.expect(t,rhi.buffer_read_slice(device,r.scene.cull_state_buffer,0,state[:]) && rhi.buffer_read_slice(device,r.scene.visible_buffer,0,visible[:]))
        testing.expectf(t,state[0].draws[0].instance_count+state[0].draws[1].instance_count==1,"one cluster of one level at frame %d",frame)
        testing.expectf(t,visible[0][1]==record.cluster_word+(0 if frame==0 else coarse)*CLUSTER_WORDS,"the GPU chooses among the posed levels at frame %d",frame)
        previous_palette,previous_weight=palette,weight
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// The cost of the compute of the poses: of level 0 alone, of every level, and
// of every level with four targets that move every vertex.
@(test)
gpu_skin_benchmark_reports_the_cost_of_posing_every_level_and_morph_targets :: proc(t:^testing.T) {
    shared_device.hold(t)
    when !SKIN_BENCHMARK {return} else {
        device,message:=rhi.device_create({app_name="mirai morph benchmark",allow_hardware_ray_tracing=true,upload_bytes_per_frame=32<<20})
        if !testing.expect(t,device!=nil,message) {return}
        defer rhi.device_destroy(device)
        r:Renderer
        settings:=DEFAULT_SETTINGS;settings.gi_enabled,settings.reflections,settings.taa=false,false,false
        if !testing.expect(t,renderer_init(&r,{device=device,width=640,height=360,settings=settings}),r.error) {return}
        defer renderer_destroy(&r)
        vertices,indices,grid:=skin_test_grid(128)
        defer delete(vertices);defer delete(indices);defer delete(grid)
        // Level 1 every other quad of level 0.
        all:=make([dynamic]u32,0,len(indices)*2,context.temp_allocator)
        append(&all,..indices)
        for q:=0;q<len(indices)/6;q+=2 {append(&all,..indices[q*6:][:6])}
        grid_levels:=[]asset.Level_Source{{0,u32(len(indices)),0},{u32(len(indices)),u32(len(all)-len(indices)),0.02}}
        grid_indices:=all[:]
        Variant :: struct {name:string,levels,morphs:bool}
        variants:=[3]Variant{{"level 0",false,false},{"every level",true,false},{"every level, 4 targets",true,true}}
        camera:=Camera{position={0,6,10},forward={0,-6,-10},up={0,1,0},fov_y=50,near=0.1,far=100,exposure=UNIT_EXPOSURE}
        sun:=Sun_Desc{direction={0.5,1,0.5},color={1,1,1},illuminance=math.PI,enabled=true}
        for variant in variants {
            source,_,_:=test_mesh_add(&r,vertices,grid_indices,grid_levels)
            record:=r.scene.meshes[source]
            if !testing.expect(t,record.level_count>1,"the grid has levels") {return}
            level0,_:=level0_vertices(&r.scene,record)
            count:=int(record.vertex_count if variant.levels else level0)
            influences:=make([]Skin_Influence,count);defer delete(influences)
            rest:=test_rest(&r,source)
            for &influence,i in influences {influence=test_two_joints(clamp(rest[i].position.x*0.5+0.5,0,1))}
            morph:Morph_Data
            ranges:=make([]Morph_Range,count if variant.morphs else 0);defer delete(ranges)
            deltas:=make([]Morph_Delta,count*4 if variant.morphs else 0);defer delete(deltas)
            if variant.morphs {
                for &range,i in ranges {
                    range={u32(i*4),4}
                    for target in 0..<4 {deltas[i*4+target]=test_morph_delta(u32(target),{0,0.05*f32(target+1),0},{0.01,0,0},{0,0.01,0})}
                }
                morph={ranges=ranges,deltas=deltas,count=4,step=TEST_MORPH_STEP}
            }
            skins:[8]Mesh_Handle
            instances:[8]Instance_Desc
            for &skin,i in skins {
                created:bool;skin,created=skin_create(&r,source,influences,2,morph)
                if !testing.expect(t,created,r.error) {return}
                transform:=Mat4(1);transform[0,3]=f32(i%4)*2.5-4;transform[2,3]=f32(i/4)*2.5
                instances[i]={object_id=u64(i+1),mesh=skin,transform=transform,tint={1,1,1}}
            }
            scene_set(&r,instances[:],nil,sun,{})
            weights:[4]f32
            for hardware in ([2]bool{false,true}) {
                settings.trace_mode=.Hardware if hardware else .Software
                if !renderer_apply_settings(&r,settings) {continue}
                if hardware && !r.hardware_rt {continue}
                gpu_time:f64
                for frame in 0..<220 {
                    palette:=[2]Mat4{Mat4(1),Mat4(1)}
                    palette[1][1,3]=0.5*math.sin(f32(frame)*0.02)
                    for &weight,k in weights {weight=0.5+0.5*math.sin(f32(frame)*0.03+f32(k))}
                    for skin in skins {skin_update(&r,skin,palette[:],false,weights[:] if variant.morphs else nil)}
                    if !testing.expect(t,renderer_frame(&r,{camera=camera}),r.error) {return}
                    if frame>=100 {for timing in r.stats.timings {if timing.name=="skinning" {gpu_time+=f64(timing.ms)}}}
                }
                fmt.printfln("morph benchmark %s native=%v %s: %d vertices posed of %d drawn at level 0, 8 instances: GPU skinning %.3f ms",rhi.device_info(device).name,hardware,variant.name,count,level0,gpu_time/120)
            }
            for skin in skins {mesh_remove(&r,skin)}
            mesh_remove(&r,source)
        }
    }
}
