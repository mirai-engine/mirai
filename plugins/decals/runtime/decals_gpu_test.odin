package decals

import "core:math/linalg"
import "core:mem"
import "core:testing"
import render "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
decals_blend_surface_properties_in_order :: proc(t:^testing.T) {
    shaders,problem:=gpu.shader_assets_load(#directory+"/../../../.mirai/test-shaders/decals")
    if !testing.expect(t,problem=="",problem) {return}
    device:=shared_device.take_or_skip(t)
    if device==nil {gpu.shader_assets_destroy(&shaders);return}
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    allocator:=mem.tracking_allocator(&tracker)
    r:=new(gpu.Renderer)
    defer free(r)
    defer gpu.renderer_destroy(r)
    settings:=gpu.DEFAULT_SETTINGS
    settings.taa=false
    if !testing.expect(t,gpu.renderer_init(r,{
        device=device,width=64,height=64,settings=settings,shaders=&shaders,allocator=allocator,
    }),r.error) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{
        root=base.test_folder(t,"decal-gpu"),renderer=r,
    })) {return}
    defer host.assets_destroy(&assets)
    cube:=host.assets_shape(&assets,.Cube)
    if !testing.expect(t,cube!=nil) {return}

    normal_map,ok:=gpu.texture_add(r,{
        pixels={204,128,0,255},width=1,height=1,normal_map=true,name="decal test normal",
    })
    if !testing.expect(t,ok,r.error) {return}
    mask,masked:=gpu.texture_add(r,{
        pixels={255,255,255,128},width=1,height=1,name="decal test opacity",
    })
    if !testing.expect(t,masked,r.error) {return}
    state:=new(Decals_Gpu)
    defer free(state)
    box:=mm.transform_matrix({scale={2,1,2},rotation=mm.TRANSFORM_IDENTITY.rotation})
    state.items[0]={
        to_box=mm.mat4_rows(linalg.inverse(box)),to_world=mm.mat4_rows(box),
        color={1,0,0,1},texture=render.texture_index(mask),
        normal_map=render.texture_index(normal_map),
        normal_density=1,roughness=0.2,metallic=1,
    }
    state.items[1]=state.items[0]
    state.items[1].color={0,0,1,0.5}
    state.items[1].texture=max(u32)
    state.items[1].normal_map,state.items[1].roughness,state.items[1].metallic=max(u32),-1,0
    state.count=2
    camera:=gpu.Camera{position={0,3,0},forward={0,-1,0},up={0,0,-1},height=4,
                       projection=.Orthographic,near=0.1,far=10}
    floor:=mm.transform_matrix({
        position={0,-0.5,0},rotation=mm.TRANSFORM_IDENTITY.rotation,scale={10,1,10},
    })
    r_material:=gpu.DEFAULT_MATERIAL
    r_material.roughness,r_material.metallic,r_material.base_color=0.8,0,{0,1,0}
    for custom_specular in ([2]bool{false,true}) {
        if custom_specular {r_material.specular_factor=0.5}
        gpu.materials_set(r,{r_material})
        gpu.scene_update(r,0,{
            {object_id=1,mesh=cube.handle,transform=floor,material=1,tint=1},
        },true)
        decals_submit(state,r,true)
        if !testing.expect(t,gpu.renderer_frame(r,{camera=camera}),r.error) {return}
        rhi.device_wait_idle(device)
        w,h:=int(r.targets.width),int(r.targets.height)
        albedo:=make([][4]u8,w*h,context.temp_allocator)
        normal:=make([][4]f16,w*h,context.temp_allocator)
        read :: proc(t:^testing.T,device:^rhi.Device,texture:rhi.Texture,bytes:[]u8) -> bool {
            return testing.expect(t,rhi.texture_read(device,texture,bytes),rhi.device_error(device))
        }
        if !read(t,device,r.targets.albedo,mem.slice_data_cast([]u8,albedo)) ||
           !read(t,device,r.targets.normal,mem.slice_data_cast([]u8,normal)) {return}
        center,outside:=h/2*w+w/2,h/2*w+w*7/8
        packed:=normal[center]
        n,roughness,_:=gpu.gbuffer_normal_decode({
            f32(packed.x),f32(packed.y),f32(packed.z),f32(packed.w),
        })
        testing.expectf(t,n.x>0.29 && n.y>0.9,"decal tilts the normal toward its U axis: %v",n)
        testing.expectf(t,abs(roughness-0.5)<0.01,
                        "roughness blends through half opacity: %f",roughness)
        testing.expectf(t,abs(f32(albedo[center].a)/255-0.25)<0.01,
                        "the upper decal lowers metallic in order: %v",albedo[center])
        testing.expectf(t,albedo[center].b>albedo[center].r && albedo[center].b>albedo[center].g,
                        "the upper decal is blue: %v",albedo[center])
        testing.expectf(t,abs(f32(normal[outside].z)-0.8)<0.01 && albedo[outside].a==0,
                        "the floor outside the box keeps its material: %v %v",
                        normal[outside],albedo[outside])
        testing.expect_value(t,r.targets.surface!=0,custom_specular)
        if custom_specular {
            reflectance:=make([][4]u8,w*h,context.temp_allocator)
            if !read(t,device,r.targets.surface,mem.slice_data_cast([]u8,reflectance)) {return}
            testing.expectf(t,abs(f32(reflectance[center].a)/255-0.625)<0.01 &&
                            reflectance[center].b>reflectance[center].r,
                            "the decal's metallic and base color affect stored reflectance: %v",
                            reflectance[center])
        }
    }
    for _ in 0..<3 {
        decals_submit(state,r,true)
        if !testing.expect(t,gpu.renderer_frame(r,{camera=camera}),r.error) {return}
    }
    rhi.device_wait_idle(device)
    before:=rhi.device_stats(device)
    allocations:=tracker.total_allocation_count
    {
        context.allocator=allocator
        decals_submit(state,r,true)
        testing.expect(t,gpu.renderer_frame(r,{camera=camera}),r.error)
    }
    testing.expect_value(t,tracker.total_allocation_count,allocations)
    testing.expect_value(t,rhi.device_stats(device),before)
}
