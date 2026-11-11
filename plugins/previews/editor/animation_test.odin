package previews_editor

import "core:mem"
import "core:testing"
import "mirai:editor"
import "mirai:editor/kit"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

@(test)
animation_details_show_the_clip_in_cards_that_fold :: proc(t:^testing.T) {
    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{}) && kit.theme_set(&ctx)) {return}
    defer ui.context_destroy(&ctx)
    g:=editor.Editor_Ui{ctx=&ctx}
    inspector:editor.Inspector
    app:host.App
    s:=new(editor.Session)
    defer free(s)
    s.gui,s.inspector,s.app=&g,&inspector,&app
    clips:=[1]Clip_Info{{duration=7.57,tracks=3,keys=40,marker_count=2}}
    base.text_set(clips[0].name[:],"idle")
    base.text_set(clips[0].root.bone[:],"root")
    clips[0].root.translation=true
    p:Animation
    p.clips=clips[:]
    models:Thumbnail_Models
    frame :: proc(t:^testing.T,ctx:^ui.Context,s:^editor.Session,p:^Animation,models:^Thumbnail_Models,input:ui.Input) {
        ui.frame_begin(ctx,input)
        if ui.box(ctx,{width=ui.fixed(300),height=ui.FIT,direction=.Column}) {animation_details(s,p,models,nil,1,300,800)}
        output:=ui.frame_end(ctx)
        testing.expect(t,!output.overflow)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
        stats:=ctx.stats
        testing.expect(t,stats.dropped_elements==0 && stats.dropped_widgets==0 && stats.dropped_paints==0 && stats.dropped_text==0 && stats.dropped_clips==0)
    }
    still:=ui.Input{size={400,900},pointer_absent=true,dt=1.0/60}
    for _ in 0..<3 {frame(t,&ctx,s,&p,&models,still)}
    _,subject:=ui.widget_rect(&ctx,ui.id(&ctx,"subject"))
    testing.expect(t,subject,"Preview shows Subject")
    // A frame that changes nothing allocates nothing.
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator=mem.tracking_allocator(&track)
        frame(t,&ctx,s,&p,&models,still)
    }
    testing.expect_value(t,track.total_allocation_count,i64(0))
    // A click on the band of Clip folds it; Preview stays open.
    band,found:=ui.widget_rect(&ctx,ui.id(&ctx,"card",int(Animation_Card.Clip)+1))
    if !testing.expect(t,found) {return}
    for phase in 0..<3 {
        input:=ui.Input{size={400,900},pointer=ui.rect_center(band),dt=1.0/60}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        frame(t,&ctx,s,&p,&models,input)
    }
    testing.expect(t,p.folded=={.Clip})
    frame(t,&ctx,s,&p,&models,still)
    _,subject=ui.widget_rect(&ctx,ui.id(&ctx,"subject"))
    testing.expect(t,subject,"Preview stays open")
}

@(test)
the_animation_document_says_the_clip_its_time_and_how_it_plays :: proc(t:^testing.T) {
    p:Animation
    clips:=[2]Clip_Info{}
    base.text_set(clips[1].name[:],"walk")
    p.clips=clips[:]
    p.time,p.speed=0.5,1
    d:editor.Asset_Document
    animation_say(&d,&p,2,2,"Mirai robot")
    testing.expect_value(t,base.text_get(d.shown[:]),"clip walk at frame 15 of 60 (0.500 s of 2.000 s at 30 frames per second), paused on Mirai robot")
    p.playing,p.loop,p.speed=true,true,0.5
    p.strip.range,p.strip.range_in,p.strip.range_out=true,10,40
    animation_say(&d,&p,2,2,"")
    testing.expect_value(t,base.text_get(d.shown[:]),"clip walk at frame 15 of 60 (0.500 s of 2.000 s at 30 frames per second), playing at 0.5x in a loop within frames 10 to 40")
    animation_say(&d,&p,0,0,"")
    testing.expect_value(t,base.text_get(d.shown[:]),"the asset without a clip")
}

@(test)
playback_loops_and_stops_inside_the_range_of_its_strip :: proc(t:^testing.T) {
    p:=editor.Asset_Playback{time=1,speed=1,loop=true,playing=true}
    p.strip.range,p.strip.range_in,p.strip.range_out=true,30,45 // 1 s to 1.5 s at editor.ASSET_PLAYBACK_RATE
    editor.asset_playback_advance(&p,2,0.6)
    testing.expectf(t,abs(p.time-1.1)<1e-4,"Looping wraps inside the range: %v",p.time)
    p.loop=false
    editor.asset_playback_advance(&p,2,0.6)
    testing.expect(t,p.time==1.5 && !p.playing,"Without loop it stops at the end of the range")
}
