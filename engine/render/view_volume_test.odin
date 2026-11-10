package render

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"

// The level exposes a stop under the meter; a tunnel replaces it inside its
// box and fades over its border, its effects with their fade; a camera with its
// own Exposure keeps it.
@(test)
a_view_takes_the_look_of_the_volume_it_is_in :: proc(t:^testing.T) {
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    level:=VIEW_VOLUME_DEFAULT
    level.exposure.compensation=-1
    tunnel:=VIEW_VOLUME_DEFAULT
    tunnel.exposure.compensation=2
    tunnel.tint={1,0,0}
    tunnel.layers[0]={material=base.Asset_Id{1,2},enabled=true,fade=0.25}
    a,b:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.view_volumes,a,level)
    core.add(&w.view_volumes,b,tunnel)
    core.add(&w.volumes,b,volume.Volume{shape=.Box,extents={4,4,4},blend=2})
    core.add(&w.worlds,b,core.World_Transform{transform={rotation=1,scale=1}})
    core.test_world_settle(&w)
    at :: proc(w:^Render_World,x:f32) -> View_Volume {
        return view_volume_at(core.read(&w.view_volumes),core.read(&w.volumes),core.read(&w.worlds),{x,0,0})
    }
    outside:=at(&w,10)
    testing.expect_value(t,outside.exposure.compensation,f32(-1))
    testing.expect_value(t,outside.tint,[3]f32{1,1,1})
    inside:=at(&w,0)
    testing.expect_value(t,inside.exposure.compensation,f32(2))
    testing.expect_value(t,inside.tint,[3]f32{1,0,0})
    testing.expect(t,inside.layers[0].enabled && inside.layers[0].fade==0.25,"its effects past half its weight, as faded")
    border:=at(&w,3)
    testing.expect_value(t,border.exposure.compensation,f32(0.5))
    testing.expect(t,border.layers[0].enabled)
    view:=core.View{position={0,0,0}}
    view.exposure={mode=.Manual,ev100=12,own=true}
    view_volume_expose(&view,core.read(&w.view_volumes),core.read(&w.volumes),core.read(&w.worlds))
    testing.expect_value(t,view.exposure.ev100,f32(12))
    view.exposure={}
    view_volume_expose(&view,core.read(&w.view_volumes),core.read(&w.volumes),core.read(&w.worlds))
    testing.expect(t,view.exposure.own && view.exposure.compensation==2 && view.exposure.tint==[3]f32{1,0,0},"without its own, that of where it is")
}

// A local view gives the renderer the effects of where it is once, and again
// only when they change or the renderer holds others for its slot.
@(test)
a_local_view_gives_the_renderer_its_effects_when_they_change :: proc(t:^testing.T) {
    root:=base.test_folder(t,"view-effects")
    if root=="" {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    r:=new(gpu.Renderer);defer free(r)
    app:=host.App{assets=&assets,renderer=r,allocator=context.allocator}
    other:=gpu.Postprocess_List{count=1,entries={0={program=7,enabled=true}}}
    layers:[POST_PROCESS_CAPACITY]Post_Process_Layer
    layers[0]={material=base.Asset_Id{1,2},enabled=true}
    last:View_Postprocess
    r.view_postprocesses[1]=other
    view_postprocess_sync(app.assets,app.renderer,1,layers,&last)
    testing.expect(t,r.view_postprocesses[1].count==0 && last.layers==layers,"a material without a PostProcess program runs nothing")
    // Unchanged, it does nothing: what it gave stays.
    last.given=other
    r.view_postprocesses[1]=other
    view_postprocess_sync(app.assets,app.renderer,1,layers,&last)
    testing.expect_value(t,r.view_postprocesses[1].count,u32(1))
    // Another list in the renderer, or other layers, give it again.
    r.view_postprocesses[1]={}
    view_postprocess_sync(app.assets,app.renderer,1,layers,&last)
    testing.expect(t,r.view_postprocesses[1].count==0 && last.given.count==0)
    r.view_postprocesses[1]=other
    last.given=other
    layers[1]={material=base.Asset_Id{3,4},enabled=true,after_tonemap=true}
    view_postprocess_sync(app.assets,app.renderer,1,layers,&last)
    testing.expect(t,r.view_postprocesses[1].count==0 && last.layers==layers)
    testing.expect(t,r.view_postprocesses[0].count==0 && r.postprocesses.count==0,"the other slots and the frame keep theirs")
}
