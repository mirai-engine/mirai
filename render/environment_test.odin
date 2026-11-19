package mirai_render

import "core:math/linalg"
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

// The background of the sky is what the view and a mirror see, while the sky
// keeps lighting a diffuse surface as without it: a color, an image times its
// color, a studio's that shows only behind, and the editor's, which shows only
// behind and leaves the environment alone. Without one the view is as before.
@(test)
the_background_is_what_the_view_and_a_mirror_see_while_the_sky_lights :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false
    f:Fixture
    if !fixture_init(t,&f,96,64,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    quad::proc(r:^Renderer,x0,x1:f32,material:Material_Handle) -> (Mesh_Handle,bool) {
        vertices:=[4]Mesh_Vertex{{position={x0,-0.8,0},normal={0,0,1},color={1,1,1},material=material},{position={x1,-0.8,0},normal={0,0,1},color={1,1,1},material=material},{position={x1,0.8,0},normal={0,0,1},color={1,1,1},material=material},{position={x0,0.8,0},normal={0,0,1},color={1,1,1},material=material}}
        indices:=[6]u32{0,1,2,0,2,3}
        return mesh_add(r,vertices[:],indices[:])
    }
    diffuse,mirror:=DEFAULT_MATERIAL,DEFAULT_MATERIAL
    diffuse.base_color,diffuse.roughness=0.8,1
    mirror.base_color,mirror.metallic,mirror.roughness=1,1,0
    materials_set(r,{diffuse,mirror})
    left,made:=quad(r,-2,-0.4,1);testing.expect(t,made,r.error);if !made {return}
    right,added:=quad(r,0.4,2,2);testing.expect(t,added,r.error);if !added {return}
    red:[8*4*4]u8
    for i in 0..<8*4 {red[i*4],red[i*4+3]=255,255}
    image,loaded:=texture_add(r,{pixels=red[:],width=8,height=4,srgb=true,name="red background"});testing.expect(t,loaded,r.error);if !loaded {return}
    scene_given(r,{{object_id=1,mesh=left,transform=Mat4(1),material=1,tint={1,1,1}},{object_id=2,mesh=right,transform=Mat4(1),material=2,tint={1,1,1}}},nil,{},{})
    camera:=Camera{position={0,0,5},forward={0,0,-1},up={0,1,0},fov_y=50,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    at::proc(pixels:[]f16,width,x,y:int) -> Vec3 {i:=(y*width+x)*4;return {f32(pixels[i]),f32(pixels[i+1]),f32(pixels[i+2])}}
    sky:=Vec3{0.5,0.5,0.5}
    blue:=Vec3{0.05,0.05,0.5}
    Case::struct {name:string,environment:Environment,editor:bool,shown,mirrored:Vec3}
    cases:=[]Case{
        {name="no background",environment={sky=sky}},
        {name="a color",environment={sky=sky,background=blue,use_background=true},shown={0,0,1},mirrored={0,0,1}},
        {name="an image",environment={sky=sky,background={0.5,0.5,0.5},background_texture=image,use_background=true},shown={1,0,0},mirrored={1,0,0}},
        {name="a studio's",environment={sky=sky,background=blue,use_background=true,background_behind=true},shown={0,0,1}},
        {name="the editor's",environment={sky=sky},editor=true,shown={0,0,1}},
        {name="none again",environment={sky=sky}},
    }
    width:=int(r.targets.width)
    first:[3]Vec3 // sky, diffuse and mirror without a background
    for c,index in cases {
        scene_set_environment(r,{},c.environment)
        renderer_set_backdrop(r,blue,c.editor)
        for _ in 0..<2 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
        pixels:=grid_read_hdr(t,r,r.targets.display);defer delete(pixels)
        seen:=[3]Vec3{at(pixels,width,48,3),at(pixels,width,31,32),at(pixels,width,64,32)}
        if index==0 {first=seen}
        testing.expectf(t,seen[1]==first[1],"%s: the sky lights the diffuse surface as without a background: %v, %v",c.name,seen[1],first[1])
        for which in 0..<2 {
            pixel,hue:=seen[which*2],which==0?c.shown:c.mirrored
            if hue=={} {
                testing.expectf(t,pixel==first[which*2],"%s: %s the sky as without a background: %v, %v",c.name,which==0?"the view shows":"the mirror shows",pixel,first[which*2])
                continue
            }
            other:=Vec3{1,1,1}-hue
            testing.expectf(t,linalg.dot(pixel,hue)>2*linalg.dot(pixel,other) && linalg.dot(pixel,hue)>0.05,"%s: %s the background: %v",c.name,which==0?"the view shows":"the mirror shows",pixel)
        }
        if c.editor {testing.expect(t,r.scene.environment==c.environment,"the editor's background leaves the environment alone")}
    }
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
