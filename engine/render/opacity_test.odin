package render

import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import mm "mirai:std/math"

@(test)
tint_opacity_updates_only_dirty_instances_and_reuses_materials_without_allocating :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    context.allocator=mem.tracking_allocator(&tracking)
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.reflections,settings.taa=false,false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    gpu.renderer_set_display_transform(app.renderer,.ACES_2) // the pixels below are calibrated to it
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    meshes:core.Table(Mesh_Renderer);defer core.table_destroy(&meshes)
    tints:core.Table(Tint);defer core.table_destroy(&tints)
    hidden:core.Table(Hidden);defer core.table_destroy(&hidden)
    elsewhere:core.Table(Drawn_Elsewhere);defer core.table_destroy(&elsewhere)
    parents:core.Table(core.Parent);defer core.table_destroy(&parents)
    lights:Test_Lights;defer {core.table_destroy(&lights.suns);core.table_destroy(&lights.points);core.table_destroy(&lights.spots);core.table_destroy(&lights.rects)}
    emissions:core.Table(Light_Emission);defer core.table_destroy(&emissions)
    skies:core.Table(Sky);core.table_init(&skies,"Sky");defer core.table_destroy(&skies)
    posts:core.Table(View_Volume);defer core.table_destroy(&posts)
    overrides:core.Table(Material_Override);defer core.table_destroy(&overrides)
    highlights:core.Table(Highlight);defer core.table_destroy(&highlights)
    offsets:core.Table(Draw_Offset);defer core.table_destroy(&offsets)
    layers:core.Table(Layers);defer core.table_destroy(&layers)
    sync:Render_Sync;defer sync_free(&sync)
    view:=core.VIEW_DEFAULT;view.position,view.rotation,view.size={0,0,5},1,{160,120}
    entities:=[2]core.Entity{core.create(&es),core.create(&es)}
    for e,i in entities {
        pose:=mm.TRANSFORM_IDENTITY;pose.position.x=f32(i)*2-1
        core.add(&worlds,e,core.World_Transform{pose,pose})
        core.add(&meshes,e,Mesh_Renderer{shape=.Cube})
        core.add(&tints,e,Tint{color=i==0?[4]f32{1,0,0,1}:{0,1,0,1},emission=i==0?[3]f32{3,0,0}:{0,3,0}})
    }
    core.table_settle(&worlds,&es);core.table_settle(&meshes,&es);core.table_settle(&tints,&es)
    draw :: proc(sync:^Render_Sync,app:^host.App,view:core.View,worlds:^core.Table(core.World_Transform),meshes:^core.Table(Mesh_Renderer),tints:^core.Table(Tint),hidden:^core.Table(Hidden),elsewhere:^core.Table(Drawn_Elsewhere),parents:^core.Table(core.Parent),lights:^Test_Lights,emissions:^core.Table(Light_Emission),sky:^core.Table(Sky),posts:^core.Table(View_Volume),overrides:^core.Table(Material_Override),highlights:^core.Table(Highlight),offsets:^core.Table(Draw_Offset),layers:^core.Table(Layers)) {
        host.app_camera_set(app,host.camera_from_view(view),view.cut,view.carried)
        outlines:core.Table(Outline);defer core.table_destroy(&outlines)
        outline_styles:=OUTLINE_STYLES_DEFAULT
        render_sync(sync,app,{},core.FRAME_TIME_DEFAULT,{},core.read(worlds),core.read(meshes),core.read(tints),core.read(hidden),core.read(elsewhere),core.read(parents),{},core.read(&lights.suns),core.read(&lights.points),core.read(&lights.spots),core.read(&lights.rects),core.read(emissions),core.read(sky),core.read(posts),{},core.read(overrides),core.read(highlights),core.read(&outlines),{&outline_styles},core.read(offsets),core.read(layers),{},{},{},{})
    }
    alphas:=[9]f32{1,0.5,0,1,0.75,0.25,0.5,0,1}
    for alpha,pass in alphas {
        core.get(&tints,entities[0]).color.a=alpha
        sets:=sync.stats.scene_sets
        updates:=sync.stats.instance_updates
        host.app_frame_begin(app)
        draw(&sync,app,view,&worlds,&meshes,&tints,&hidden,&elsewhere,&parents,&lights,&emissions,&skies,&posts,&overrides,&highlights,&offsets,&layers)
        if pass>0 {
            testing.expect_value(t,sync.stats.scene_sets,sets)
            testing.expect_value(t,sync.stats.instance_updates,updates+1)
            if pass==5 || pass==6 || pass==7 {testing.expect(t,!app.renderer.scene.tlas_dirty && !app.renderer.scene.tlas_nodes_dirty && !app.renderer.scene.tlas_refs_dirty)}
        }
        testing.expect_value(t,len(app.renderer.scene.translucent),alpha<1?1:0)
        // A unit cube is small (gpu.SMALL_INSTANCE_REACH): opaque, it meets the rays of that class.
        hw:=app.renderer.scene.hw_instances[0].mask_flags
        testing.expect_value(t,hw&0xff,u32(alpha<1?gpu.RAY_GLASS:gpu.RAY_SMALL))
        testing.expect_value(t,hw&rhi.TLAS_ALPHA_TESTED!=0,alpha<1)
        testing.expect_value(t,instance_entity(&sync,0),entities[0])
        testing.expect_value(t,instance_entity(&sync,1),entities[1])
        host.app_frame_end(app)
        // The frame takes the tree of the instances as the updates left it, which rays traced by software walk.
        if !app.renderer.hardware_rt {
            testing.expect_value(t,app.renderer.scene.glass_node_count,alpha<1?1:0)
            for reference in app.renderer.scene.tlas_refs {
                if reference&~gpu.TLAS_REF_GLASS==0 {testing.expect_value(t,reference&gpu.TLAS_REF_GLASS!=0,alpha<1)}
            }
        }
        pixels,_,_,captured:=host.app_capture_pixels(app)
        if !testing.expect(t,captured) {delete(pixels);return}
        red,green:=0,0
        for at in 0..<len(pixels)/4 {
            color:=pixels[at*4:][:3]
            if int(color[0])>20 && int(color[0])>2*max(int(color[1]),int(color[2])) {red+=1}
            // ACES 2.0 takes a bright pure green toward white: it stays the strongest channel by half.
            if int(color[1])>20 && 2*int(color[1])>3*max(int(color[0]),int(color[2])) {green+=1}
        }
        testing.expectf(t,alpha==0?red==0:red>100,"alpha %f draws the fading entity (%d red pixels)",alpha,red)
        testing.expect(t,green>100,"the unchanged entity remains visible")
        host.app_frame_begin(app)
        gpu.scene_set(app.renderer,sync.instances[:],sync.lights[:],sync.sun,sync.environment)
        host.app_frame_end(app)
        reference,_,_,reference_ok:=host.app_capture_pixels(app)
        testing.expect(t,reference_ok && mem.compare(pixels,reference)==0,"incremental appearance matches a complete scene set")
        delete(pixels);delete(reference)
    }
    material_rows:=len(app.assets.material_descs)
    allocations:=tracking.total_allocation_count
    for pass in 0..<32 {
        core.get(&tints,entities[0]).color.a=f32(pass%7)/6
        host.app_frame_begin(app)
        draw(&sync,app,view,&worlds,&meshes,&tints,&hidden,&elsewhere,&parents,&lights,&emissions,&skies,&posts,&overrides,&highlights,&offsets,&layers)
        host.app_frame_end(app)
    }
    testing.expect_value(t,tracking.total_allocation_count,allocations)
    testing.expect_value(t,len(app.assets.material_descs),material_rows)
    testing.expect(t,app.assets.stats.derived<=1)
    core.remove(&meshes,entities[1]);core.table_settle(&meshes,&es)
    host.app_frame_begin(app)
    draw(&sync,app,view,&worlds,&meshes,&tints,&hidden,&elsewhere,&parents,&lights,&emissions,&skies,&posts,&overrides,&highlights,&offsets,&layers)
    host.app_frame_end(app)
    testing.expect_value(t,len(app.renderer.scene.instances),1)
    testing.expect_value(t,instance_entity(&sync,0),entities[0])
    core.add(&meshes,entities[1],Mesh_Renderer{shape=.Cube});core.table_settle(&meshes,&es)
    host.app_frame_begin(app)
    draw(&sync,app,view,&worlds,&meshes,&tints,&hidden,&elsewhere,&parents,&lights,&emissions,&skies,&posts,&overrides,&highlights,&offsets,&layers)
    host.app_frame_end(app)
    testing.expect_value(t,len(app.renderer.scene.instances),2)
    testing.expect_value(t,instance_entity(&sync,1),entities[1])
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}

@(private="file")
Test_Lights :: struct {
    suns:core.Table(Sun),
    points:core.Table(Point_Light),
    spots:core.Table(Spot_Light),
    rects:core.Table(Rect_Light),
}
