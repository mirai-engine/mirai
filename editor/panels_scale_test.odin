package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:store"
import "mirai:ui"

@(test)
editor_panels_bound_scratch_for_a_large_scene_and_library :: proc(t:^testing.T) {
    COUNT :: 10_001
    root:=base.test_folder(t,"panels-scale")
    if root=="" {return}
    kept,opened:=store.open(fmt.tprintf("%s/store",root))
    if !testing.expect_value(t,opened,store.Error.None) {return}
    defer store.close(&kept)
    p:=asset.Package{id={1,1},name="Scene assets"}
    p.assets=make([dynamic]asset.Package_Asset,0,COUNT,context.temp_allocator)
    b:=asset.Build{package_id=p.id,final=true}
    b.outputs=make([dynamic]asset.Build_Output,0,COUNT,context.temp_allocator)
    world:=new(Shell_Test_World);defer free(world)
    if !test_world_init(t,world) {return}
    defer test_world_destroy(world)
    folder:=fmt.tprintf("%s/assets",root)
    if !testing.expect(t,os.make_directory(folder)==nil) {return}
    assets:host.Assets
    asset.types_init(&assets.types);defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,folder);defer asset.registry_destroy(&assets.registry)
    pixels:[16]u8
    texture:asset.Document
    desc:=asset.Texture_Desc{id={2,1},width=2,height=2,format=.RGBA8,mips={pixels[:]}}
    made:=asset.texture_document(&texture,&assets.types,desc)
    if !testing.expect_value(t,made,asset.Error.None) {return}
    defer asset.document_destroy(&texture)
    write_scratch:base.Arena
    if !testing.expect(t,base.arena_init(&write_scratch,2<<20)) {return}
    defer base.arena_destroy(&write_scratch)
    for i in 0..<COUNT {
        id:=base.Asset_Id{2,u64(i)+1}
        name:=fmt.tprintf("Texture %d",i)
        append(&p.assets,asset.Package_Asset{id=id,kind=asset.KIND_TEXTURE,name=name})
        base.arena_reset(&write_scratch)
        texture.id=id
        {
            context.temp_allocator=base.arena_allocator(&write_scratch)
            bytes,encoded:=asset.document_bytes(&texture,context.temp_allocator)
            if !testing.expect_value(t,encoded,asset.Error.None) {return}
            object,stored:=asset.object_put(&kept,bytes)
            if !testing.expect_value(t,stored,asset.Error.None) {return}
            append(&b.outputs,asset.Build_Output{id=id,kind=asset.KIND_TEXTURE,
                kind_version=asset.TEXTURE_VERSION,object=object})
        }
        e:=core.create(&world.entities)
        core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)
    }
    test_world_settle(world)
    manifest,packed:=asset.package_put(&kept,&p)
    if !testing.expect_value(t,packed,asset.Error.None) {return}
    build,built:=asset.build_put(&kept,&b)
    if !testing.expect_value(t,built,asset.Error.None) {return}
    digits:[64]u8
    if !testing.expect_value(t,store.ref_set(&kept,asset.REF_BUILDS,
        store.hex(asset.build_select(manifest,&p),&digits),build),store.Error.None) {return}
    if !testing.expect_value(t,store.ref_set(&kept,asset.REF_PACKAGES,"scene-assets",manifest),
        store.Error.None) {return}

    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    os_platform:=new(platform.Platform);defer free(os_platform)
    app:=host.App{assets=&assets,platform=os_platform}
    fixture:=new(Test_Session);defer free(fixture)
    test_session_open(fixture,test_world_ref(world));defer test_session_close(fixture)
    s:=&fixture.s
    s.app,s.store,s.headless,s.project_root=&app,kept,true,root
    s.gui.ctx,s.gui.layout,s.gui.begun=&ctx,LAYOUT_DEFAULT,true
    inspector:Inspector
    defer core.value_free(&inspector,type_info_of(Inspector))
    materials:Materials
    finder:Finder
    outliner:Outliner
    defer core.value_free(&outliner,type_info_of(Outliner))
    ai:=new(Ai);defer free(ai)
    s.inspector,s.materials=&inspector,&materials
    s.finder,s.ai,s.outliner=&finder,ai,&outliner
    content:=CONTENT_DEFAULT
    defer core.value_free(&content,type_info_of(Content))
    defer if arena:=content.libraries.arena;arena!=nil {
        content.libraries={}
        mem.dynamic_arena_destroy(arena)
        free(arena,runtime.heap_allocator())
    }
    s.content=&content
    panel_scale_frame(t,s,128<<20)
    if !testing.expect_value(t,len(content.libraries.packages),1) {return}
    testing.expect(t,content.libraries.packages[0].here)
    testing.expect_value(t,len(assets.registry.files),COUNT)
    panel_scale_frame(t,s,8<<20)

    s.headless=false
    assets.registry.revision+=1
    panel_scale_frame(t,s,128<<20)
    s.gui.layout.library_tab=.Hierarchy
    history.selection_set(s.selection,{world.transforms.entities[0]})
    panel_scale_frame(t,s,8<<20)
    testing.expect_value(t,len(outliner.rows),COUNT)
    _,details:=ui.widget_rect(&ctx,shell_id(s.gui,"right"))
    testing.expect(t,details)
}

@(private="file")
panel_scale_frame :: proc(t:^testing.T,s:^Session,scratch_limit:i64) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    scratch:mem.Dynamic_Arena
    tracked:=mem.tracking_allocator(&track)
    mem.dynamic_arena_init(&scratch,tracked,tracked)
    defer mem.dynamic_arena_destroy(&scratch)
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,{size={1440,900},pointer_absent=true})
    started:=time.tick_now()
    {
        context.temp_allocator=base.dynamic_arena_allocator(&scratch)
        editor_panels(s,s.gui,shown_world(s),s.app)
    }
    elapsed:=time.duration_milliseconds(time.tick_since(started))
    frame:=ui.frame_end(ctx)
    fmt.printfln("editor_panels (%v, headless=%v): %.1f ms, %.1f MiB of scratch",
        s.gui.layout.library_tab,s.headless,elapsed,f64(track.peak_memory_allocated)/(1<<20))
    testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    testing.expect(t,track.peak_memory_allocated<scratch_limit,"the frame must keep bounded scratch")
    testing.expect(t,elapsed<5_000,"a large library must not stall the first frame")
}
