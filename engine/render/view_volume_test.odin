package render

import "core:fmt"
import "core:os"
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
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    looks:core.Table(View_Volume);core.table_init(&looks,"View_Volume");defer core.table_destroy(&looks)
    places:core.Table(volume.Volume);core.table_init(&places,"Volume");defer core.table_destroy(&places)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    level:=VIEW_VOLUME_DEFAULT
    level.exposure.compensation=-1
    tunnel:=VIEW_VOLUME_DEFAULT
    tunnel.exposure.compensation=2
    tunnel.tint={1,0,0}
    tunnel.layers[0]={material=base.Asset_Id{1,2},enabled=true,fade=0.25}
    a,b:=core.create(&es),core.create(&es)
    core.add(&looks,a,level)
    core.add(&looks,b,tunnel)
    core.add(&places,b,volume.Volume{shape=.Box,extents={4,4,4},blend=2})
    core.add(&worlds,b,core.World_Transform{transform={rotation=1,scale=1}})
    core.table_settle(&looks,&es);core.table_settle(&places,&es);core.table_settle(&worlds,&es)
    at :: proc(looks:^core.Table(View_Volume),places:^core.Table(volume.Volume),worlds:^core.Table(core.World_Transform),x:f32) -> View_Volume {
        return view_volume_at(core.read(looks),core.read(places),core.read(worlds),{x,0,0})
    }
    outside:=at(&looks,&places,&worlds,10)
    testing.expect_value(t,outside.exposure.compensation,f32(-1))
    testing.expect_value(t,outside.tint,[3]f32{1,1,1})
    inside:=at(&looks,&places,&worlds,0)
    testing.expect_value(t,inside.exposure.compensation,f32(2))
    testing.expect_value(t,inside.tint,[3]f32{1,0,0})
    testing.expect(t,inside.layers[0].enabled && inside.layers[0].fade==0.25,"its effects past half its weight, as faded")
    border:=at(&looks,&places,&worlds,3)
    testing.expect_value(t,border.exposure.compensation,f32(0.5))
    testing.expect(t,border.layers[0].enabled)
    view:=core.View{position={0,0,0}}
    view.exposure={mode=.Manual,ev100=12,own=true}
    view_volume_expose(&view,core.read(&looks),core.read(&places),core.read(&worlds))
    testing.expect_value(t,view.exposure.ev100,f32(12))
    view.exposure={}
    view_volume_expose(&view,core.read(&looks),core.read(&places),core.read(&worlds))
    testing.expect(t,view.exposure.own && view.exposure.compensation==2 && view.exposure.tint==[3]f32{1,0,0},"without its own, that of where it is")
}

// A local view gives the renderer the effects of where it is once, and again
// only when they change or the renderer holds others for its slot.
@(test)
a_local_view_gives_the_renderer_its_effects_when_they_change :: proc(t:^testing.T) {
    root:=fmt.tprintf("%s/mirai-view-effects-%d",os.get_env("TEMP",context.temp_allocator),os.get_pid())
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
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
