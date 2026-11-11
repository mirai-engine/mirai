package kit

import "base:runtime"
import "core:hash"
import "core:mem"
import "core:testing"
import "core:thread"
import "mirai:ui"
import std_anim "mirai:std/anim"

// A scene with a little of everything: the panels of the editor, a world
// panel and an animated element.
Test_Everything :: struct {
    editor:Test_Editor,
    library:ui.Anim_Library,
    pulse:ui.Anim_Player,
    world_value:f64,
}
test_everything_build :: proc(ctx:^ui.Context,user:rawptr) {
    s:=cast(^Test_Everything)user
    test_editor_build(ctx,&s.editor)
    ui.anim_update(&s.library,&s.pulse,ctx.input.dt)
    if ui.anchored(ctx,ui.id(ctx,"hud_corner"),.Bottom_Left,{20,-20},{direction=.Column}) {
        if ui.animated(ctx,ui.id(ctx,"pulse"),s.pulse.value) {
            ui.text(ctx,"Checkpoint reached",{size=16,color={255,255,255,255},outline=1,outline_color={0,0,0,255}},ui.FIT,ui.FIT,ui.id(ctx,"pulse"))
        }
    }
    if ui.world_panel(ctx,ui.id(ctx,"sign"),{position={0,2,0},size={200,100},unit=0.01,pivot=.Center,direction=.Column,padding=ui.padding_all(10),gap=4,fill={10,10,10,255}}) {
        ui.label(ctx,"Storage room")
        ui.number_field(ctx,ui.id(ctx,"sign_value"),&s.world_value,{width=ui.fixed(80)})
    }
}
test_everything_init :: proc(t:^testing.T,s:^Test_Everything) {
    s.editor=test_editor_default()
    testing.expect(t,ui.anim_library_init(&s.library))
    keys:=[3]std_anim.Keyframe{{time=0,value={1,1,0,0}},{time=0.5,value={1.2,1.2,0,0},ease=.Cubic_Out},{time=1,value={1,1,0,0},ease=.Cubic_In}}
    ui.anim_play(&s.pulse,ui.anim_clip(&s.library,{{.Scale,keys[:]}},.Loop))
}
test_everything_destroy :: proc(s:^Test_Everything) {
    ui.anim_library_destroy(&s.library)
}

@(test)
frames_allocate_nothing_once_the_context_exists :: proc(t:^testing.T) {
    owned,ambient,scratch:Test_Counter
    s:Test_Everything
    test_everything_init(t,&s)
    defer test_everything_destroy(&s)
    ctx:ui.Context
    desc:=TEST_FONT
    desc.max_vertices=262144
    desc.allocator=test_counter(&owned,context.allocator)
    testing.expect(t,test_context_init(&ctx,desc))
    defer ui.context_destroy(&ctx)
    testing.expect(t,owned.requests>0)
    input:=test_input(1440,900)
    input.view={position={0,2,5},fov_y=1.5,viewport_height=900}
    input.ray={origin={-0.5,1.9,5},direction={0,0,-1},valid=true}
    test_frame(&ctx,&input,test_everything_build,&s)
    name:=test_rect(t,&ctx,ui.id(&ctx,"name"))
    field:=test_rect(t,&ctx,ui.id_derive(&ctx,ui.id(&ctx,"position"),"axis",1))
    owned.requests=0
    {
        context.allocator=test_counter(&ambient,context.allocator)
        context.temp_allocator=test_counter(&scratch,context.temp_allocator)
        // Hovering, typing, scrubbing, scrolling and a menu: the frames of an editor in use.
        for step in 0..<60 {
            switch step {
            case 2:test_point(&input,name)
            case 4:test_press(&input)
            case 5:test_release(&input)
            case 6:test_type(&input,"Crate 02")
            case 8:test_key(&input,.Enter)
            case 10:test_point(&input,field)
            case 12:test_press(&input)
            case 13..=20:input.pointer.x+=7
            case 21:test_release(&input)
            case 24:input.wheel={0,-2}
            case 30:test_point(&input,ui.Rect{10,6,40,26})
            case 32:test_press(&input)
            case 33:test_release(&input)
            case 40:test_key(&input,.Escape)
            case 44:s.editor.tab=2
            }
            frame:=test_frame(&ctx,&input,test_everything_build,&s)
            testing.expect(t,!frame.overflow)
        }
    }
    testing.expect_value(t,owned.requests,0)
    testing.expect_value(t,ambient.requests,0)
    testing.expect_value(t,scratch.requests,0)
    testing.expect_value(t,string(s.editor.name[:s.editor.name_length]),"Crate 02")
    testing.expect(t,s.editor.position.x>1,"The frames did what an editor does")
    testing.expect(t,ctx.stats.panels==1 && ctx.stats.scopes>=1 && ctx.stats.vertices>1000 && ctx.stats.shapes>20)
}

@(test)
contexts_on_several_threads_do_not_disturb_each_other :: proc(t:^testing.T) {
    Work :: struct {checksum:u32,ok:bool,frames:int,scroll:f32}
    run :: proc(work:^Work) {
        ctx:ui.Context
        desc:=TEST_SMALL
        if !test_context_init(&ctx,desc) {return}
        defer ui.context_destroy(&ctx)
        e:=test_editor_default()
        e.rows=30;e.scroll=work.scroll
        input:=test_input(1440,900)
        frame:ui.Frame
        for _ in 0..<work.frames {frame=test_frame(&ctx,&input,test_editor_build,&e)}
        work.checksum=hash.fnv32a(mem.slice_to_bytes(frame.vertices))
        work.ok=!frame.overflow && ctx.stats.layout_errors==0
    }
    // The same scene alone, then four at once: each layout must come out the same.
    alone:=Work{frames=20}
    run(&alone)
    testing.expect(t,alone.ok)
    works:[4]Work
    threads:[4]^thread.Thread
    for &work,i in works {
        work={frames=20,scroll=0 if i%2==0 else 100}
        threads[i]=thread.create_and_start_with_poly_data(&work,proc(work:^Work) {
            context=runtime.default_context()
            run(work)
        })
    }
    for worker in threads {thread.join(worker);thread.destroy(worker)}
    scrolled:=Work{frames=20,scroll=100}
    run(&scrolled)
    for work,i in works {
        testing.expect(t,work.ok)
        testing.expect_value(t,work.checksum,alone.checksum if i%2==0 else scrolled.checksum)
    }
    testing.expect(t,alone.checksum!=scrolled.checksum)
}

@(test)
widgets_and_paints_beyond_the_capacity_are_dropped_and_counted :: proc(t:^testing.T) {
    ctx:ui.Context
    desc:=TEST_SMALL
    desc.max_widgets=8;desc.max_paints=12
    testing.expect(t,test_context_init(&ctx,desc))
    defer ui.context_destroy(&ctx)
    State :: struct {clicks:int}
    s:State
    build :: proc(ctx:^ui.Context,user:rawptr) {
        s:=cast(^State)user
        if ui.box(ctx,{direction=.Column}) {
            for i in 0..<20 {if ui.button(ctx,ui.id(ctx,"button",i+1),{label="Button",width=100,height=20}).clicked {s.clicks+=1}}
        }
    }
    input:=test_input()
    frame:=test_frame(&ctx,&input,build,&s)
    testing.expect(t,frame.overflow)
    testing.expect_value(t,ctx.stats.dropped_widgets,u32(12))
    testing.expect_value(t,ctx.stats.dropped_paints,u32(8))
    testing.expect_value(t,ctx.stats.widgets,u32(8))
    testing.expect_value(t,ctx.stats.paints,u32(12))
    testing.expect_value(t,ctx.stats.elements,u32(21))
    // The first eight still work; the rest are laid out, twelve of them drawn, and out of reach.
    last:=test_rect(t,&ctx,ui.id(&ctx,"button",8))
    testing.expect(t,test_rect_near(last,{0,140,100,20}))
    test_point(&input,last)
    test_frame(&ctx,&input,build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,1)
    input.pointer={50,170}
    frame=test_frame(&ctx,&input,build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.clicks==1 && !frame.pointer_consumed)
}
