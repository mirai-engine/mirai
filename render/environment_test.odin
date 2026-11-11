package mirai_render

import "core:mem"
import "core:math"
import "core:testing"
import "mirai:rhi"

@(test)
ground_grid_is_visible_on_the_background_and_occluded_by_geometry :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false
    f:Fixture
    if !fixture_init(t,&f,160,120,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    vertices:=[4]Mesh_Vertex{
        {position={-1,1,-1},normal={0,1,0}},
        {position={-1,1,1},normal={0,1,0}},
        {position={1,1,1},normal={0,1,0}},
        {position={1,1,-1},normal={0,1,0}},
    }
    indices:=[6]u32{0,1,2,0,2,3}
    mesh,created:=mesh_add(r,vertices[:],indices[:]);testing.expect(t,created,r.error);if !created {return}
    camera:=Camera{position={3,5,5},forward={-3,-4.5,-5},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    // A normalized prefab can extend below its origin. The background grid
    // must stay off its surfaces on either side of the reference plane.
    elevations:=[2]f32{0,-2}
    for elevation in elevations {
        transform:=Mat4(1);transform[1,3]=elevation
        scene_given(r,[]Instance_Desc{{object_id=1,mesh=mesh,transform=transform}},nil,{}, {background={0.025,0.029,0.035},use_background=true})
        testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
        plain,width,height,captured:=golden_capture(r);testing.expect(t,captured,r.error);if !captured {return};defer delete(plain)
        tlas_dirty,instances_dirty:=r.scene.tlas_dirty,r.scene.instances_dirty
        tlas_storage,instance_storage:=raw_data(r.scene.tlas_nodes),raw_data(r.scene.instances)
        environment:=r.scene.environment;environment.ground_grid=true
        scene_set_environment(r,{},environment)
        testing.expect(t,r.scene.tlas_dirty==tlas_dirty && r.scene.instances_dirty==instances_dirty && raw_data(r.scene.tlas_nodes)==tlas_storage && raw_data(r.scene.instances)==instance_storage,"The display grid leaves geometry untouched")
        testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
        grid,_,_,read:=golden_capture(r);testing.expect(t,read,r.error);if !read {return};defer delete(grid)
        changed,opaque,covered_changes:=0,0,0
        for y in 0..<int(height) {for x in 0..<int(width) {
            offset:=(y*int(width)+x)*4
            different:=plain[offset]!=grid[offset] || plain[offset+1]!=grid[offset+1] || plain[offset+2]!=grid[offset+2]
            if different {changed+=1}
            if plain[offset]==0 && plain[offset+1]==0 && plain[offset+2]==0 {opaque+=1;if different {covered_changes+=1}}
        }}
        testing.expectf(t,changed>500,"Grid/axes/quadrants are visible on the background (%d pixels)",changed)
        testing.expectf(t,opaque>100 && covered_changes==0,"The grid stays off opaque geometry at Y=%g (%d covered pixels changed)",elevation+1,covered_changes)
        testing.expect_value(t,len(r.scene.instances),1)
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

@(private="file")
grid_read_hdr :: proc(t:^testing.T,r:^Renderer,target:rhi.Texture)->[]f16 {
    rhi.device_wait_idle(r.device)
    pixels:=make([]f16,int(r.targets.width*r.targets.height)*4)
    testing.expect(t,golden_read_texture(r.device,target,mem.slice_data_cast([]u8,pixels)))
    return pixels
}

@(test)
ground_grid_blends_behind_transparency :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false
    f:Fixture
    if !fixture_init(t,&f,160,120,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    vertices:=[4]Mesh_Vertex{
        {position={-1,1,-1},normal={0,1,0}},
        {position={-1,1,1},normal={0,1,0}},
        {position={1,1,1},normal={0,1,0}},
        {position={1,1,-1},normal={0,1,0}},
    }
    indices:=[6]u32{0,1,2,0,2,3}
    mesh,created:=mesh_add(r,vertices[:],indices[:]);testing.expect(t,created,r.error);if !created {return}
    camera:=Camera{position={3,5,5},forward={-3,-4.5,-5},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    environment:=Environment{background={0.025,0.029,0.035},use_background=true}
    scene_given(r,nil,nil,{},environment)
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    plain:=grid_read_hdr(t,r,r.targets.display);defer delete(plain)
    environment.ground_grid=true;scene_set_environment(r,{},environment)
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    grid:=grid_read_hdr(t,r,r.targets.display);defer delete(grid)

    // With no lights or ambient radiance the sheet reflects black, making its
    // transmitted background independent of the material's shading model.
    glass:=DEFAULT_MATERIAL;glass.alpha_mode=.Blend
    materials_set(r,[]Material_Desc{glass})
    scene_given(r,[]Instance_Desc{{object_id=1,mesh=mesh,transform=Mat4(1),material=1}},nil,{},environment)
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    solid:=grid_read_hdr(t,r,r.targets.display);defer delete(solid)
    solid_ldr,_,_,captured:=golden_capture(r);testing.expect(t,captured,r.error);if !captured {return};defer delete(solid_ldr)
    glass.opacity=0.25;materials_set(r,[]Material_Desc{glass})
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    quarter_grid:=grid_read_hdr(t,r,r.targets.display);defer delete(quarter_grid)
    environment.ground_grid=false;scene_set_environment(r,{},environment)
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    quarter_plain:=grid_read_hdr(t,r,r.targets.display);defer delete(quarter_plain)
    covered,solid_changes,attenuated,wrong_attenuation:=0,0,0,0
    for pixel in 0..<int(r.targets.width*r.targets.height) {
        offset:=pixel*4
        if solid[offset]!=0 || solid[offset+1]!=0 || solid[offset+2]!=0 {continue}
        covered+=1
        if solid_ldr[offset]!=0 || solid_ldr[offset+1]!=0 || solid_ldr[offset+2]!=0 {solid_changes+=1}
        expected_size,largest_error:f32
        for channel in 0..<3 {
            expected:=(f32(grid[offset+channel])-f32(plain[offset+channel]))*0.75
            actual:=f32(quarter_grid[offset+channel])-f32(quarter_plain[offset+channel])
            expected_size+=abs(expected)
            largest_error=max(largest_error,abs(actual-expected))
        }
        if expected_size>0.001 {
            attenuated+=1
            if largest_error>0.0002 {wrong_attenuation+=1}
        }
    }
    testing.expectf(t,covered>100 && solid_changes==0,"Blend opacity 1 hides the grid (%d covered pixels, %d changed)",covered,solid_changes)
    testing.expectf(t,attenuated>100 && wrong_attenuation==0,"Blend opacity 0.25 transmits 75%% of the linear grid contrast (%d samples, %d incorrect)",attenuated,wrong_attenuation)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

@(test)
a_backdrop_is_shown_behind_the_scene_instead_of_the_sky_until_it_is_removed :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false
    f:Fixture
    if !fixture_init(t,&f,96,64,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    camera:=Camera{position={0,1,4},forward={0,0,-4},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    scene_given(r,nil,nil,{},{sky={0.5,0.6,0.9}})
    center:=(32*96+48)*4
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    sky,_,_,captured:=golden_capture(r);testing.expect(t,captured,r.error);if !captured {return};defer delete(sky)
    testing.expectf(t,sky[center+2]>40,"the sky of the environment shows (%d)",sky[center+2])
    renderer_set_backdrop(r,{0.0019,0.0026,0.0045})
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    dark,_,_,read:=golden_capture(r);testing.expect(t,read,r.error);if !read {return};defer delete(dark)
    testing.expectf(t,dark[center]<12 && dark[center+1]<12 && dark[center+2]<16,"the backdrop shows (%d %d %d)",dark[center],dark[center+1],dark[center+2])
    testing.expect(t,r.scene.environment.sky==Vec3{0.5,0.6,0.9} && !r.scene.environment.use_background,"the environment of the scene is left alone")
    renderer_set_backdrop(r,{},false)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    again,_,_,third:=golden_capture(r);testing.expect(t,third,r.error);if !third {return};defer delete(again)
    testing.expect_value(t,again[center+2],sky[center+2])
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
