package render

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:render/abi"
import "mirai:std/base"

// The level exposes a stop under the meter; a tunnel replaces it inside its
// box and fades over its border, its effects with their fade; a camera with its
// own Exposure keeps it.
@(test)
a_view_takes_the_look_of_the_volume_it_is_in :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    level:=VIEW_VOLUME_DEFAULT
    level.exposure.compensation=-1
    tunnel:=VIEW_VOLUME_DEFAULT
    tunnel.exposure.compensation=2
    tunnel.tint={1,0,0}
    tunnel.zone.blend=2
    tunnel.layers[0]={material=base.Asset_Id{1,2},enabled=true,fade=0.25}
    a,b:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.view_volumes,a,level)
    core.add(&w.view_volumes,b,tunnel)
    core.add(&w.volumes,b,volume.box({4,4,4}))
    core.add(&w.worlds,b,core.World_Transform{transform={rotation=1,scale=1}})
    test_world_settle(&w)
    at :: proc(w:^Render_World,x:f32) -> View_Volume {
        return view_volume_at(core.read(&w.view_volumes),{volumes=core.read(&w.volumes),worlds=core.read(&w.worlds)},{x,0,0})
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
    view_volume_expose(&view,core.read(&w.view_volumes),{volumes=core.read(&w.volumes),worlds=core.read(&w.worlds)})
    testing.expect_value(t,view.exposure.ev100,f32(12))
    view.exposure={}
    view_volume_expose(&view,core.read(&w.view_volumes),{volumes=core.read(&w.volumes),worlds=core.read(&w.worlds)})
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
    view_postprocess_sync(app.assets,app.renderer,2,layers,&last,nil,nil)
    testing.expect(t,r.view_postprocesses[1].count==0 && last.layers==layers,"a material without a PostProcess program runs nothing")
    // Unchanged, it does nothing: what it gave stays.
    last.given=other
    r.view_postprocesses[1]=other
    view_postprocess_sync(app.assets,app.renderer,2,layers,&last,nil,nil)
    testing.expect_value(t,r.view_postprocesses[1].count,u32(1))
    // Another list in the renderer, or other layers, give it again.
    r.view_postprocesses[1]={}
    view_postprocess_sync(app.assets,app.renderer,2,layers,&last,nil,nil)
    testing.expect(t,r.view_postprocesses[1].count==0 && last.given.count==0)
    r.view_postprocesses[1]=other
    last.given=other
    layers[1]={material=base.Asset_Id{3,4},enabled=true,after_tonemap=true}
    view_postprocess_sync(app.assets,app.renderer,2,layers,&last,nil,nil)
    testing.expect(t,r.view_postprocesses[1].count==0 && last.layers==layers)
    testing.expect(t,r.view_postprocesses[0].count==0 && r.postprocesses.count==0,"the other slots and the frame keep theirs")
}

// The effects of the main view follow their materials and programs: a reload
// that gives the program another id is given to the renderer again. An
// enabled layer that cannot draw is a problem of its View_Volume naming the
// layer; one that is off is not.
@(test)
the_effects_of_the_view_follow_their_programs_and_report_a_layer_that_cannot_draw :: proc(t:^testing.T) {
    root:=base.test_folder(t,"view-effects-programs")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    programs:=[3]string{"Grade","","Missing"}
    for program,i in programs {
        info:=asset.MATERIAL_DEFAULTS
        asset.text_set(info.program[:],program)
        testing.expect_value(t,asset.material_save(fmt.tprintf("%s/m%d.mat",root,i),&types,{id={9,u64(i)},info=info}),asset.Error.None)
    }
    f:=new(Sync_Fixture);defer free(f)
    if !sync_fixture_init(t,f,root) {return}
    defer sync_fixture_destroy(f)
    catalog :: proc(t:^testing.T,r:^gpu.Renderer,id:int) {
        text:=fmt.tprintf(`{{"version":%d,"programs":[{{"id":%d,"name":"Grade","domain":"Postprocess","size":0,"parameters":[]}}]}}`,abi.SHADER_CATALOG_VERSION,id)
        parsed,valid:=gpu.program_catalog_parse(transmute([]u8)text)
        testing.expect(t,valid,"the catalog is read")
        if r.programs.loaded {gpu.program_catalog_destroy(&r.programs)}
        r.programs=parsed
        r.programs.loaded=true
    }
    catalog(t,&f.renderer,1)
    look:=VIEW_VOLUME_DEFAULT
    look.layers[0]={material={9,0},enabled=true}
    look.layers[1]={material={9,1},enabled=true}
    look.layers[2]={material={9,2}}
    e:=core.create(&f.world.entities)
    core.add(&f.world.view_volumes,e,look)
    problems:core.Problems
    frame :: proc(f:^Sync_Fixture,problems:^core.Problems) {
        test_world_settle(&f.world)
        world_sync(&f.world,&f.sync,&f.app,{},problems=problems)
    }
    frame(f,&problems)
    given:=f.renderer.postprocesses
    testing.expectf(t,given.count==1 && given.entries[0].program==1,"the layer of Grade runs: %d effects, the first of program %d",given.count,given.entries[0].program)
    reported:=""
    for &p in problems.entries[:problems.count] {
        if p.entity==e && base.text_get(p.code[:])=="render.postprocess" {reported=base.text_get(p.text[:])}
    }
    testing.expectf(t,reported!="" && problems.count==1,"the enabled layer without a program is a problem of its View_Volume: %q (%d problems)",reported,problems.count)
    testing.expectf(t,len(reported)>0 && reported[:7]=="layer 1","naming the layer: %q",reported)
    // The programs are made again: Grade is another id.
    catalog(t,&f.renderer,4)
    host.assets_programs_refresh(&f.assets)
    frame(f,&problems)
    given=f.renderer.postprocesses
    testing.expectf(t,given.count==1 && given.entries[0].program==4,"the reloaded program is given again: %d effects, the first of program %d",given.count,given.entries[0].program)
}
