package kit

import "core:log"
import "core:testing"
import "core:time"
import "mirai:ui"

// -define:UI_BENCHMARK=true measures a frame of a large panel; run it with --release.
UI_BENCHMARK :: #config(UI_BENCHMARK,false)

@(test)
benchmark_a_frame_of_a_large_panel :: proc(t:^testing.T) {
    if !UI_BENCHMARK {return}
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    // The panels of the editor with 300 more rows of three number fields in
    // Details: about a fifth of them in sight, the rest behind its scroll.
    e:=test_editor_default()
    e.rows=300
    input:=test_input(1440,2400)
    for _ in 0..<10 {test_frame(&ctx,&input,test_editor_build,&e)}
    FRAMES :: 500
    build,finish:time.Duration
    for _ in 0..<FRAMES {
        start:=time.tick_now()
        ui.frame_begin(&ctx,input)
        test_editor_build(&ctx,&e)
        middle:=time.tick_now()
        frame:=ui.frame_end(&ctx)
        finish+=time.tick_since(middle)
        build+=time.tick_diff(start,middle)
        testing.expect(t,!frame.overflow)
    }
    s:=ctx.stats
    log.infof("large panel: %d elements, %d widgets, %d vertices, %d commands",s.elements,s.widgets,s.vertices,s.commands)
    log.infof("large panel: %.3f ms per frame (widgets %.3f ms, layout and draw list %.3f ms)",
        time.duration_milliseconds(build+finish)/FRAMES,time.duration_milliseconds(build)/FRAMES,time.duration_milliseconds(finish)/FRAMES)
}

@(test)
benchmark_a_frame_of_a_long_transcript :: proc(t:^testing.T) {
    if !UI_BENCHMARK {return}
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    // A conversation as the AI panel builds it: 512 wrapped messages, measured
    // once, of which only those in sight are laid out.
    MESSAGE :: "The agent changed the material of the cube and moved the sphere half a metre to the right so that both sit on the grid; the light was left as it was because nothing in the request asked for it."
    Transcript :: struct {offset:f32,heights:[512]f32}
    build :: proc(ctx:^ui.Context,user:rawptr) {
        s:=cast(^Transcript)user
        area:=ui.id(ctx,"transcript")
        first,last:=ui.rows_begin(ctx,area,&s.offset,s.heights[:],ui.fixed(300),ui.fixed(600))
        for i in first..<last {
            if ui.box(ctx,{id=ui.id(ctx,"message",i+1),width=ui.GROW,height=ui.fixed(s.heights[i]),direction=.Column}) {ui.text(ctx,MESSAGE,ui.prose(ctx))}
        }
        ui.rows_end(ctx,area,&s.offset,s.heights[:],last)
    }
    s:Transcript
    for &h in s.heights {h=ui.text_height(&ctx,MESSAGE,ui.prose(&ctx),300)}
    input:=test_input(1440,900)
    for _ in 0..<10 {test_frame(&ctx,&input,build,&s)}
    FRAMES :: 500
    total:time.Duration
    for i in 0..<FRAMES {
        s.offset=f32(i*37)
        start:=time.tick_now()
        test_frame(&ctx,&input,build,&s)
        total+=time.tick_since(start)
    }
    log.infof("long transcript: %.3f ms per frame, %d elements",time.duration_milliseconds(total)/FRAMES,ctx.stats.elements)
}

@(test)
benchmark_rebuilding_the_atlas :: proc(t:^testing.T) {
    if !UI_BENCHMARK {return}
    for density in ([3]f32{1,1.75,2}) {
        // The fastest of several rounds: the least disturbed by other work.
        ROUNDS :: 9
        fastest:=max(time.Duration)
        height:int
        for _ in 0..<ROUNDS {
            font:ui.Font
            start:=time.tick_now()
            testing.expect(t,ui.font_init(&font,nil,nil,density))
            fastest=min(fastest,time.tick_since(start))
            height=font.height
            ui.font_destroy(&font)
        }
        log.infof("atlas at density %.2f: %.2f ms, %d x %d texels",density,time.duration_milliseconds(fastest),ui.FONT_ATLAS_WIDTH,height)
    }
}

@(test)
benchmark_drawing_text :: proc(t:^testing.T) {
    if !UI_BENCHMARK {return}
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,{density=1.75}))
    defer ui.context_destroy(&ctx)
    // Two thousand short labels, as many as a dense editor window shows.
    LABELS :: [?]string{"Transform","Position","Rotation","Scale","Static Mesh","AVATAR","Material","Point Light"}
    labels:=LABELS
    draw :: proc(ctx:^ui.Context,user:rawptr) {
        labels:=cast(^[len(LABELS)]string)user
        for i in 0..<2000 {
            text:=labels[i%len(labels)]
            x:=f32(i%8)*170+ui.text_width(&ctx.font,text,11)*0.01
            ui.draw_text(ctx,text,x,f32(i/8)*3,11,{241,242,247,255})
        }
    }
    input:=test_input(1440,900)
    for _ in 0..<10 {test_frame(&ctx,&input,draw,&labels)}
    FRAMES :: 500
    total:time.Duration
    fastest:=max(time.Duration)
    for _ in 0..<FRAMES {
        start:=time.tick_now()
        test_frame(&ctx,&input,draw,&labels)
        elapsed:=time.tick_since(start)
        total+=elapsed;fastest=min(fastest,elapsed)
    }
    log.infof("text: %.3f ms per frame of 2000 labels (fastest %.3f ms), %d vertices",
        time.duration_milliseconds(total)/FRAMES,time.duration_milliseconds(fastest),ctx.stats.vertices)
}

@(test)
benchmark_a_font_on_demand_in_the_cases_of_an_application :: proc(t:^testing.T) {
    if !UI_BENCHMARK {return}
    // The fastest of several rounds of each case, at the density of a 175 % display.
    ROUNDS :: 9
    Case :: enum {Whole,Init,Startup,Play,Density}
    fastest:[Case]time.Duration
    for &d in fastest {d=max(time.Duration)}
    glyphs,height:int
    game :: proc(ctx:^ui.Context,user:rawptr) {
        ui.text(ctx,"60 FPS",{size=14,color={255,255,255,255}})
        ui.text(ctx,"Score 1200  Lives 3",{size=16,color={255,255,255,255}})
    }
    for _ in 0..<ROUNDS {
        whole:ui.Font
        start:=time.tick_now()
        testing.expect(t,ui.font_init(&whole,nil,nil,1.75))
        fastest[.Whole]=min(fastest[.Whole],time.tick_since(start))
        ui.font_destroy(&whole)
        owner:ui.Font
        start=time.tick_now()
        testing.expect(t,ui.font_init(&owner,nil,nil,1.75,on_demand=true))
        fastest[.Init]=min(fastest[.Init],time.tick_since(start))
        desc:=TEST_FONT
        desc.font=&owner
        editor,play:ui.Context
        testing.expect(t,test_context_init(&editor,desc))
        e:=test_editor_default()
        input:=test_input(1440,900)
        // The first frame of the editor and the glyphs it asks for.
        test_frame(&editor,&input,test_editor_build,&e)
        start=time.tick_now()
        ui.font_update(&owner)
        fastest[.Startup]=min(fastest[.Startup],time.tick_since(start))
        test_frame(&editor,&input,test_editor_build,&e)
        // Play: a context of the game and its text.
        start=time.tick_now()
        testing.expect(t,test_context_init(&play,desc))
        test_frame(&play,&input,game,nil)
        ui.font_update(&owner)
        fastest[.Play]=min(fastest[.Play],time.tick_since(start))
        // The window moves to a display of density 2.
        start=time.tick_now()
        ui.font_set_density(&owner,2)
        test_frame(&editor,&input,test_editor_build,&e)
        test_frame(&play,&input,game,nil)
        ui.font_update(&owner)
        fastest[.Density]=min(fastest[.Density],time.tick_since(start))
        glyphs=0
        for &face in owner.faces {for glyph in face.glyphs {if glyph.phases>0 {glyphs+=1}}}
        height=owner.height
        ui.context_destroy(&play);ui.context_destroy(&editor)
        ui.font_destroy(&owner)
    }
    log.infof("font on demand at 1.75: whole atlas %.2f ms; init %.2f ms; first frame of the editor %.2f ms; Play %.2f ms; density 2 %.2f ms (%d glyphs, %d rows)",
        time.duration_milliseconds(fastest[.Whole]),time.duration_milliseconds(fastest[.Init]),time.duration_milliseconds(fastest[.Startup]),
        time.duration_milliseconds(fastest[.Play]),time.duration_milliseconds(fastest[.Density]),glyphs,height)
}
