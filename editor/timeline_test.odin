package editor

import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:ui"

@(test)
the_strip_keeps_its_view_and_range_inside_the_duration :: proc(t:^testing.T) {
    strip:Timeline
    start,end:=timeline_view(&strip,60)
    testing.expect(t,start==0 && end==60,"A view never set shows the whole duration")
    strip.start,strip.end=50,80
    start,end=timeline_view(&strip,60)
    testing.expect(t,start==30 && end==60,"A view past the end slides back inside it")
    strip.start,strip.end=10,11
    start,end=timeline_view(&strip,60)
    testing.expect(t,end-start==TIMELINE_MIN_FRAMES,"The view shows at least a few frames")
    lo,hi:=timeline_bounds(&strip,60)
    testing.expect(t,lo==0 && hi==60,"A range that is off bounds nothing")
    strip.range,strip.range_in,strip.range_out=true,12,90
    lo,hi=timeline_bounds(&strip,60)
    testing.expect(t,lo==12 && hi==60,"A range that is on bounds what plays, inside the duration")
}

@(test)
a_range_turned_on_starts_at_the_head :: proc(t:^testing.T) {
    strip:Timeline
    timeline_range_start(&strip,12,60)
    testing.expect(t,strip.range_in==12 && strip.range_out==60)
    strip.range_out=40
    timeline_range_start(&strip,20,60)
    testing.expect(t,strip.range_in==20 && strip.range_out==40,"It keeps an end after the head")
    timeline_range_start(&strip,60,60)
    testing.expect(t,strip.range_in==59 && strip.range_out==60,"At the last frame it still spans one")
}

@(test)
an_end_of_the_range_set_at_a_frame_keeps_the_other_before_or_after_it :: proc(t:^testing.T) {
    Case :: struct {
        name:string,
        range:bool,
        range_in,range_out:f32,
        frame,head:f32,
        end:bool,
        lo,hi:f32,
    }
    cases:=[?]Case{
        {"no range: the start runs to the head after it",false,0,0,20,45,false,20,45},
        {"no range: the start runs to the end with the head before it",false,0,0,20,10,false,20,60},
        {"no range: the end runs from the head before it",false,0,0,40,15,true,15,40},
        {"no range: the end runs from the start with the head after it",false,0,0,40,50,true,0,40},
        {"a range off is no range",false,10,30,20,45,false,20,45},
        {"the start keeps the end after it",true,10,30,5,50,false,5,30},
        {"the end keeps the start before it",true,10,30,50,0,true,10,50},
        {"a start past the end takes the head",true,10,30,40,55,false,40,55},
        {"an end before the start takes the start of the duration",true,10,30,5,20,true,0,5},
        {"a start at the end leaves a frame",false,0,0,60,60,false,59,60},
        {"an end at the start leaves a frame",false,0,0,0,0,true,0,1},
        {"a frame out of the duration is clamped and rounded",false,0,0,80.4,10,true,10,60},
    }
    for c in cases {
        strip:=Timeline{range=c.range,range_in=c.range_in,range_out=c.range_out}
        timeline_range_set(&strip,60,c.frame,c.head,c.end)
        lo,hi:=timeline_bounds(&strip,60)
        testing.expectf(t,strip.range && lo==c.lo && hi==c.hi,"%s: %v to %v",c.name,lo,hi)
    }
    strip:Timeline
    timeline_range_set(&strip,0,10,0,false)
    testing.expect(t,!strip.range,"Nothing plays: no range")
}

@(test)
the_ruler_asks_for_its_menu_at_a_frame_and_the_agent_button_needs_a_range :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    s:=Session{gui=&g}
    strip:Timeline
    clock:=Timeline_Clock{frame=10,frames=60,rate=30,ask=true}
    frame :: proc(s:^Session,strip:^Timeline,c:Timeline_Clock,input:ui.Input) -> Timeline_Result {
        ui.frame_begin(s.gui.ctx,input)
        r:=timeline_strip(s,strip,c,nil,ui.id(s.gui.ctx,"strip"))
        ui.frame_end(s.gui.ctx)
        return r
    }
    idle:=ui.Input{size={800,200},pointer_absent=true}
    frame(&s,&strip,clock,idle);frame(&s,&strip,clock,idle)
    ui.id_push(&ctx,ui.id(&ctx,"strip"))
    ruler,ask:=ui.id(&ctx,"ruler"),ui.id(&ctx,"ask")
    ui.id_pop(&ctx)
    _,shown:=ui.widget_rect(&ctx,ask)
    testing.expect(t,!shown,"Without a range there is nothing to ask about")
    rect,found:=ui.widget_rect(&ctx,ruler)
    testing.expect(t,found)
    at:=[2]f32{rect.x+TIMELINE_PAD+(rect.w-2*TIMELINE_PAD)*0.5,rect.y+rect.h*0.5}
    r:=frame(&s,&strip,clock,{size={800,200},pointer=at,pressed={.Right},down={.Right}})
    testing.expect(t,r.ruler && strip.pointed==30,"The right button opens the menu at its frame")
    frame(&s,&strip,clock,idle);frame(&s,&strip,clock,idle)
    ui.id_push(&ctx,ui.id(&ctx,"strip"))
    end:=ui.id(&ctx,"range_end")
    ui.id_pop(&ctx)
    item,listed:=ui.widget_rect(&ctx,end)
    testing.expect(t,listed,"Every strip has the menu of its range")
    click:=[2]f32{item.x+item.w*0.5,item.y+item.h*0.5}
    frame(&s,&strip,clock,{size={800,200},pointer=click,pressed={.Left},down={.Left}})
    frame(&s,&strip,clock,{size={800,200},pointer=click,released={.Left}})
    testing.expect(t,strip.range && strip.range_in==10 && strip.range_out==30,"Set range end ends it there, from the head")
    frame(&s,&strip,clock,idle);frame(&s,&strip,clock,idle)
    _,shown=ui.widget_rect(&ctx,ask)
    testing.expect(t,shown,"With a range the button asks the agent about it")
    clock.ask=false
    frame(&s,&strip,clock,idle);frame(&s,&strip,clock,idle)
    _,shown=ui.widget_rect(&ctx,ask)
    testing.expect(t,!shown,"A document without an agent has no button")
}

@(test)
copy_range_names_the_time_and_what_plays_and_nothing_else :: proc(t:^testing.T) {
    document:Document
    s:=Session{document=&document}
    run:=Run{id=3}
    strip:=Timeline{range=true,range_in=30,range_out=90}
    hidden:=Timeline{range_in=30,range_out=90}
    _,off:=play_range_of(&s,&run,&hidden,120,100)
    testing.expect(t,!off,"A range that is off is no range")
    r,ok:=play_range_of(&s,&run,&strip,120,1000)
    testing.expect(t,ok && r.from==1030 && r.to==1090,"Frames count from the oldest tick")
    testing.expect_value(t,ai_range_text(&r),"Range: ticks 1030 to 1090\nRun: 3\nScene: unsaved")
    document_name(&document,"levels/arena.scene","C:/games/demo/assets/levels/arena.scene")
    r,_=play_range_of(&s,&run,&strip,120,1000)
    testing.expect_value(t,ai_range_text(&r),"Range: ticks 1030 to 1090\nRun: 3\nScene: levels/arena.scene")
    others:=[?]struct{range:Ai_Range,path,name,text:string}{
        {{kind=.Asset,from=12,to=40,rate=30},"hero/moves.anim","jump","Range: frames 12 to 40 at 30 fps\nAsset: hero/moves.anim\nClip: jump"},
        {{kind=.Asset,from=0,to=9,rate=30},"fx/smoke.particle","","Range: frames 0 to 9 at 30 fps\nAsset: fx/smoke.particle"},
        {{kind=.Clip,from=60,to=120},"levels/arena.scene","Intro","Range: ticks 60 to 120\nClip of: Intro\nScene: levels/arena.scene"},
    }
    for &c in others {
        base.text_set(c.range.path[:],c.path);base.text_set(c.range.name[:],c.name)
        testing.expect_value(t,ai_range_text(&c.range),c.text)
    }
}

@(test)
the_ruler_spaces_its_ticks_and_labels_by_the_zoom :: proc(t:^testing.T) {
    tick,label:=timeline_steps(10,30)
    testing.expect(t,tick==1 && label==10,"Ten points a frame: a tick each frame, a label each ten")
    tick,label=timeline_steps(1,30)
    testing.expect(t,tick==10 && label==60,"A point a frame: a tick each ten and a label each two seconds")
    tick,label=timeline_steps(2,30)
    testing.expect(t,label==30,"A label lands on each second when one fits")
}
