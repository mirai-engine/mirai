package mirai_render

import "core:mem"
import "core:testing"
import "mirai:rhi"

@(test)
overlays_gpu_order_depth_coverage_and_single_ray_instance :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false;settings.reflections=false
    f:Fixture
    if !fixture_init(t,&f,32,32,settings) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    base,red,blue,green:=DEFAULT_MATERIAL,DEFAULT_MATERIAL,DEFAULT_MATERIAL,DEFAULT_MATERIAL
    base.base_color={};red.base_color={};blue.base_color={};green.base_color={}
    red.emission={1,0,0};red.opacity=.5
    blue.emission={0,0,1};blue.opacity=.5
    green.emission={0,1,0}
    materials_set(r,{base,red,blue,green})
    vertices:=[4]Mesh_Vertex{
        {position={-1,0,-1},normal={0,1,0},uv={0,0},color={1,1,1}},
        {position={1,0,-1},normal={0,1,0},uv={1,0},color={1,1,1}},
        {position={1,0,1},normal={0,1,0},uv={1,1},color={1,1,1}},
        {position={-1,0,1},normal={0,1,0},uv={0,1},color={1,1,1}},
    }
    indices:=[6]u32{0,2,1,0,3,2}
    mesh,added:=mesh_add(r,vertices[:],indices[:]);testing.expect(t,added,r.error);if !added {return}
    camera:=Camera{position={0,2,0},forward={0,-2,0},up={0,0,-1},fov_y=60,near=.05,far=100,exposure=UNIT_EXPOSURE}
    desc:=Instance_Desc{object_id=1,mesh=mesh,material=1,transform=Mat4(1),tint={1,1,1},overlays={count=2,entries={0={id=10,material=2,blend=.Alpha,enabled=true},1={id=20,material=3,blend=.Alpha,enabled=true}}}}
    read_center :: proc(t:^testing.T,r:^Renderer) -> Vec3 {
        pixels: [32*32*4]f16
        ok:=golden_read_texture(r.device,r.targets.display,mem.slice_data_cast([]u8,pixels[:]))
        testing.expect(t,ok,rhi.device_error(r.device))
        at:=(16*32+16)*4;return {f32(pixels[at]),f32(pixels[at+1]),f32(pixels[at+2])}
    }
    scene_set(r,{desc},nil,{},Environment{})
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    first:=read_center(t,r)
    testing.expectf(t,first.z>first.x+.15 && first.x>.1,"Blue is the top alpha layer: %v",first)
    testing.expect_value(t,len(r.scene.instances),1)
    testing.expect_value(t,len(r.scene.hw_instances),1)
    testing.expect_value(t,len(r.scene.tlas_items),1)
    desc.overlays.entries[0],desc.overlays.entries[1]=desc.overlays.entries[1],desc.overlays.entries[0]
    scene_set(r,{desc},nil,{},Environment{})
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    second:=read_center(t,r)
    testing.expectf(t,second.x>second.z+.15 && second.z>.1,"Reordering changes color without changing stable IDs: %v",second)
    wall:=Instance_Desc{object_id=2,mesh=mesh,material=4,transform=Mat4(1),tint={1,1,1}}
    wall.transform[1,3]=.1
    scene_set(r,{desc,wall},nil,{},Environment{})
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    hidden:=read_center(t,r)
    testing.expectf(t,hidden.y>.8 && hidden.x<.01 && hidden.z<.01,"An occluder rejects the lower surface's layers: %v",hidden)
    // Multiply takes the color of its surface over the base, with no light on it.
    lit,filter:=DEFAULT_MATERIAL,DEFAULT_MATERIAL
    lit.base_color={};lit.emission={1,1,1}
    filter.base_color={.5,.25,1};filter.metallic=0
    materials_set(r,{lit,red,blue,green,filter})
    multiplied:=Instance_Desc{object_id=1,mesh=mesh,material=1,transform=Mat4(1),tint={1,1,1},overlays={count=1,entries={0={id=10,material=5,blend=.Multiply,enabled=true}}}}
    scene_set(r,{multiplied},nil,{},Environment{})
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    filtered:=read_center(t,r)
    testing.expectf(t,abs(filtered.x-.5)<.05 && abs(filtered.y-.25)<.05 && abs(filtered.z-1)<.08,"Multiply filters the base by its color: %v",filtered)
    base.alpha_mode=.Mask;base.opacity=0;base.alpha_cutoff=.5
    materials_set(r,{base,red,blue,green});scene_set(r,{desc},nil,{},Environment{})
    testing.expect(t,renderer_frame(r, {camera = camera}),r.error)
    hole:=read_center(t,r)
    testing.expectf(t,hole.x<.01 && hole.z<.01,"Overlays preserve holes in the base: %v",hole)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"Validation: %s",rhi.device_validation_message(device))
}
