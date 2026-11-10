package previews_editor

import "core:fmt"
import "core:math/linalg"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import eanim "plugins:animation/runtime"

PREVIEW_MIRAI_AVATAR :: #config(PREVIEW_MIRAI_AVATAR,false)

@(private="file")
Avatar_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    skins:core.Table(eanim.Pose_Source),
    meshes:core.Table(erender.Mesh_Renderer),
}

@(private="file")
Avatar_Shared :: struct {skeletons:eanim.Skeleton_Assets}

@(test)
preview_loads_and_samples_the_imported_mirai_avatar_assets :: proc(t:^testing.T) {
    when !PREVIEW_MIRAI_AVATAR {return} else {
        device:=shared_device.take_or_skip(t,hardware_rt=false)
        if device==nil {return}
        renderer:gpu.Renderer
        settings:=gpu.DEFAULT_SETTINGS;settings.gi_enabled,settings.reflections=false,false
        if !testing.expect(t,gpu.renderer_init(&renderer,{device=device,width=64,height=64,settings=settings}),renderer.error) {return}
        defer gpu.renderer_destroy(&renderer)
        assets:host.Assets
        if !testing.expect(t,host.assets_init(&assets,{root="demo/assets",renderer=&renderer})) {return}
        defer host.assets_destroy(&assets)
        info,described:=core.test_info(t,Avatar_World,Avatar_Shared,core.Test_None,eanim.test_types)
        if !described {return}
        defer core.test_info_destroy(&info)
        shared:Avatar_Shared;defer info.destroy[.Shared](&shared)
        app:=host.App{assets=&assets,renderer=&renderer,allocator=context.allocator,shared=&shared}
        w:Avatar_World
        if !testing.expect(t,info.init[.World](&w,context.allocator)) {return}
        defer info.destroy[.World](&w)
        world:=core.world_ref(&w,&info)
        scene:=Scene{transforms=&w.transforms,parents=&w.parents,skins=&w.skins,meshes=&w.meshes}
        rig:=core.create(&w.entities)
        mesh,found:=asset.registry_find_path(&assets.registry,"characters/mirai/output_unwrapped.mesh")
        skeleton,found_skeleton:=asset.registry_find_path(&assets.registry,"characters/mirai/Armature.skeleton")
        animation,found_animation:=asset.registry_find_path(&assets.registry,"characters/mirai/mirai_locomotion.anim")
        if !testing.expect(t,found && found_skeleton && found_animation,"generate the Mirai gallery assets before this integration test") {return}
        core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.add(&w.meshes,rig,{mesh=mesh.id})
        core.settle(&info,&w,nil)
        p:=Animation{chosen=animation.id};defer animation_destroy(&p,context.allocator)
        start:=time.tick_now()
        animation_load(&assets,context.allocator,&p)
        subject_gather(&app,world,scene,&p.subject,rig,1)
        gathered_ms:=time.duration_milliseconds(time.tick_since(start))
        sub:=&p.subject
        if !testing.expect(t,len(p.lib.clips)>0 && !sub.short && len(sub.skins)==1 && len(sub.locals)>0) {return}
        testing.expect(t,len(sub.skins[0].rest)>0 && len(sub.skins[0].geometry.joints)>0)
        testing.expect(t,len(sub.locals)>0 && len(sub.locals)<=TRIANGLE_CAPACITY*3)
        base.text_set(p.clip_name[:],"walk")
        clip:=animation_clip(&p)
        start=time.tick_now();subject_fit(&p,clip)
        fit_ms:=time.duration_milliseconds(time.tick_since(start))
        testing.expect(t,!sub.short && sub.fit[1].y>sub.fit[0].y)
        subject_pose(&p,clip,0);subject_place(sub)
        if !testing.expect(t,subject_skins_place(&p)) {return}
        initial:=make([][3]f32,len(sub.posed));defer delete(initial)
        for vertex,i in sub.posed {initial[i]=vertex.position}
        start=time.tick_now()
        for frame in 0..<8 {
            subject_pose(&p,clip,f32(frame+1)*0.05);subject_place(sub)
            if !testing.expect(t,subject_skins_place(&p)) {return}
        }
        sample_ms:=time.duration_milliseconds(time.tick_since(start))/8
        changed:=false
        for vertex,i in sub.posed {if linalg.length(vertex.position-initial[i])>0.001 {changed=true;break}}
        testing.expect(t,changed)
        testing.expect_value(t,w.transforms.values[0],core.TRANSFORM_IDENTITY)
        testing.expect_value(t,w.entities.alive,1)
        testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
        fmt.printfln("Mirai preview: %d bones, %d vertices, %d triangles; gather %.2f ms; fit17 %.2f ms; sample+readback %.2f ms",len(sub.skins[0].rest),len(sub.skins[0].geometry.posed),len(sub.locals)/3,gathered_ms,fit_ms,sample_ms)
    }
}
