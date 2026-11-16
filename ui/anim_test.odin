package ui

import "core:math"
import "core:testing"
import std_anim "mirai:std/anim"

@(test)
a_track_interpolates_its_keys_and_holds_its_ends :: proc(t:^testing.T) {
    lib:Anim_Library
    testing.expect(t,anim_library_init(&lib))
    defer anim_library_destroy(&lib)
    clip:=anim_clip(&lib,{
        {.Offset,{{time=0.5,value={0,0,0,0}},{time=1.5,value={100,-50,0,0}},{time=2,value={100,0,0,0},ease=.Quad_In}}},
        {.Opacity,{{time=0,value={0,0,0,0}},{time=1,value={1,0,0,0},interpolation=.Step}}},
        {.Color,{{time=0,value={1,0,0,1}},{time=2,value={0,0,1,1}}}},
    })
    testing.expect(t,clip!=0)
    testing.expect_value(t,anim_duration(&lib,clip),f32(2))
    sample :: proc(lib:^Anim_Library,anim:Anim,time:f32) -> Anim_Value {
        value:=ANIM_IDENTITY
        anim_sample(lib,anim,time,&value)
        return value
    }
    testing.expect_value(t,sample(&lib,clip,0).offset,[2]f32{0,0})
    testing.expect_value(t,sample(&lib,clip,0.5).offset,[2]f32{0,0})
    testing.expect_value(t,sample(&lib,clip,1).offset,[2]f32{50,-25})
    testing.expect_value(t,sample(&lib,clip,1.5).offset,[2]f32{100,-50})
    testing.expect_value(t,sample(&lib,clip,1.75).offset,[2]f32{100,-37.5})
    testing.expect_value(t,sample(&lib,clip,2).offset,[2]f32{100,0})
    testing.expect_value(t,sample(&lib,clip,50).offset,[2]f32{100,0})
    testing.expect_value(t,sample(&lib,clip,0.99).opacity,f32(0))
    testing.expect_value(t,sample(&lib,clip,1).opacity,f32(1))
    testing.expect_value(t,sample(&lib,clip,1).color,[4]f32{0.5,0,0.5,1})
    // What has no track keeps what the value held.
    value:=sample(&lib,clip,1)
    testing.expect(t,value.scale==[2]f32{1,1} && value.rotation==0)
    testing.expect_value(t,anim_duration(&lib,0),f32(0))
    anim_sample(&lib,0,1,&value)
    anim_sample(&lib,99,1,&value)
    testing.expect_value(t,value.offset,[2]f32{50,-25})
}

@(test)
sequences_play_one_after_another_and_groups_together :: proc(t:^testing.T) {
    lib:Anim_Library
    testing.expect(t,anim_library_init(&lib))
    defer anim_library_destroy(&lib)
    slide:=anim_tween(&lib,.Offset,{0,0,0,0},{100,0,0,0},1,.Linear)
    grow_:=anim_tween(&lib,.Scale,{1,1,0,0},{2,2,0,0},1,.Linear)
    fade:=anim_tween(&lib,.Opacity,{1,0,0,0},{0,0,0,0},0.5,.Linear,0.25)
    testing.expect_value(t,anim_duration(&lib,fade),f32(0.75))
    sequence:=anim_sequence(&lib,{slide,grow_,fade})
    testing.expect_value(t,anim_duration(&lib,sequence),f32(2.75))
    value:=ANIM_IDENTITY
    anim_sample(&lib,sequence,0.5,&value)
    testing.expect(t,value.offset=={50,0} && value.scale=={1,1} && value.opacity==1,"Later steps have not begun")
    anim_sample(&lib,sequence,1.5,&value)
    testing.expect(t,value.offset=={100,0} && value.scale=={1.5,1.5},"A step that ended keeps its last value")
    anim_sample(&lib,sequence,2.5,&value)
    testing.expect(t,value.scale=={2,2} && test_near(value.opacity,0.5))
    anim_sample(&lib,sequence,10,&value)
    testing.expect(t,value.offset=={100,0} && value.scale=={2,2} && value.opacity==0)
    together:=anim_parallel(&lib,{slide,grow_,fade})
    testing.expect_value(t,anim_duration(&lib,together),f32(1))
    value=ANIM_IDENTITY
    anim_sample(&lib,together,0.5,&value)
    testing.expect(t,value.offset=={50,0} && value.scale=={1.5,1.5} && test_near(value.opacity,0.5))
    // Groups nest.
    both:=anim_sequence(&lib,{together,anim_tween(&lib,.Rotation,{0,0,0,0},{math.PI,0,0,0},1,.Linear)})
    value=ANIM_IDENTITY
    anim_sample(&lib,both,1.5,&value)
    testing.expect(t,value.scale=={2,2} && test_near(value.rotation,math.PI/2))
    testing.expect_value(t,anim_sequence(&lib,{slide,0}),Anim(0))
}

@(test)
loops_repeat_and_ping_pongs_come_back :: proc(t:^testing.T) {
    lib:Anim_Library
    testing.expect(t,anim_library_init(&lib))
    defer anim_library_destroy(&lib)
    keys:=[2]std_anim.Keyframe{{time=0,value={0,0,0,0}},{time=1,value={10,0,0,0}}}
    loop:=anim_clip(&lib,{{.Offset,keys[:]}},.Loop)
    pong:=anim_clip(&lib,{{.Offset,keys[:]}},.Ping_Pong)
    value:=ANIM_IDENTITY
    anim_sample(&lib,loop,2.25,&value)
    testing.expect(t,test_near(value.offset.x,2.5,0.001))
    anim_sample(&lib,pong,1.25,&value)
    testing.expect(t,test_near(value.offset.x,7.5,0.001))
    anim_sample(&lib,pong,2.25,&value)
    testing.expect(t,test_near(value.offset.x,2.5,0.001))
    // A looping player never stops; one that plays once stops at its end.
    player:Anim_Player
    anim_play(&player,loop)
    for _ in 0..<100 {testing.expect(t,anim_update(&lib,&player,0.1))}
    once:=anim_clip(&lib,{{.Offset,keys[:]}})
    anim_play(&player,once)
    testing.expect(t,anim_update(&lib,&player,0.25) && test_near(player.value.offset.x,2.5,0.001))
    testing.expect(t,anim_update(&lib,&player,0.5) && test_near(player.value.offset.x,7.5,0.001))
    testing.expect(t,!anim_update(&lib,&player,0.5) && player.value.offset.x==10 && !player.playing)
    testing.expect(t,!anim_update(&lib,&player,0.5) && player.value.offset.x==10)
    idle:Anim_Player
    testing.expect(t,!anim_update(&lib,&idle,0.1))
    testing.expect_value(t,idle.value,ANIM_IDENTITY)
}

@(test)
a_full_library_refuses_new_animations :: proc(t:^testing.T) {
    lib:Anim_Library
    testing.expect(t,anim_library_init(&lib,{max_keys=4,max_tracks=2,max_anims=3,max_children=2}))
    defer anim_library_destroy(&lib)
    keys:=[2]std_anim.Keyframe{{time=0},{time=1,value={1,0,0,0}}}
    a:=anim_clip(&lib,{{.Opacity,keys[:]}})
    b:=anim_clip(&lib,{{.Opacity,keys[:]}})
    testing.expect(t,a!=0 && b!=0)
    testing.expect_value(t,anim_clip(&lib,{{.Opacity,keys[:]}}),Anim(0))
    testing.expect_value(t,anim_sequence(&lib,{a,b,a}),Anim(0))
    group:=anim_sequence(&lib,{a,b})
    testing.expect(t,group!=0)
    testing.expect_value(t,anim_parallel(&lib,{a}),Anim(0))
    testing.expect_value(t,lib.node_count,3)
    testing.expect_value(t,lib.key_count,4)
}

@(test)
being_shown_hidden_and_clicked_play_the_animations_of_a_set :: proc(t:^testing.T) {
    lib:Anim_Library
    testing.expect(t,anim_library_init(&lib))
    defer anim_library_destroy(&lib)
    set:=Anim_Set{
        shown=anim_tween(&lib,.Opacity,{0,0,0,0},{1,0,0,0},0.5,.Linear),
        hidden=anim_tween(&lib,.Opacity,{1,0,0,0},{0,0,0,0},0.5,.Linear),
        clicked=anim_tween(&lib,.Scale,{1,1,0,0},{1.2,1.2,0,0},0.25,.Linear),
    }
    state:Anim_State
    testing.expect(t,!anim_react(&lib,&state,set,{},0.1),"What was never shown is not built")
    testing.expect(t,anim_react(&lib,&state,set,{shown=true},0.25))
    testing.expect(t,test_near(state.value.opacity,0.5) && state.anim==set.shown)
    testing.expect(t,anim_react(&lib,&state,set,{shown=true},0.25) && state.value.opacity==1)
    testing.expect(t,anim_react(&lib,&state,set,{shown=true},1) && state.value.opacity==1)
    // A click plays its own; what the previous one set stays.
    anim_react(&lib,&state,set,{shown=true,clicked=true},0.125)
    testing.expect(t,test_near(state.value.scale.x,1.1,0.001) && state.value.opacity==1)
    anim_react(&lib,&state,set,{shown=true},0.5)
    testing.expect(t,test_near(state.value.scale.x,1.2,0.001))
    // Hidden, it is still built while it fades out.
    testing.expect(t,anim_react(&lib,&state,set,{},0.25) && test_near(state.value.opacity,0.5))
    testing.expect(t,!anim_react(&lib,&state,set,{},0.25) && state.value.opacity==0)
    testing.expect(t,!anim_react(&lib,&state,set,{},1))
    // Without an animation for it, hiding is immediate.
    plain:Anim_State
    testing.expect(t,anim_react(&lib,&plain,{shown=set.shown},{shown=true},1))
    testing.expect(t,!anim_react(&lib,&plain,{shown=set.shown},{},0.01))
    // Shown and clicked at once, it plays how it is shown.
    together:Anim_State
    anim_react(&lib,&together,set,{shown=true,clicked=true},0.25)
    testing.expect(t,together.anim==set.shown && test_near(together.value.opacity,0.5))
}

Test_Animated :: struct {value,inner:Anim_Value,nested:bool,clicks:int}
test_animated_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Animated)user
    if box(ctx,{padding={100,100,0,0}}) {
        if animated(ctx,id(ctx,"card"),s.value) {
            if box(ctx,{id=id(ctx,"card"),width=fixed(200),height=fixed(100),fill={255,255,255,255}}) {
                if s.nested {
                    if animated(ctx,id(ctx,"go"),s.inner) {
                        if button(ctx,id(ctx,"go"),{label="Go",width=50,height=20,variant="accent"}).clicked {s.clicks+=1}
                    }
                }
            }
        }
    }
}

@(test)
an_animated_element_is_drawn_through_its_transform :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Animated{value=ANIM_IDENTITY,inner=ANIM_IDENTITY}
    input:=test_input()
    frame:=test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices),{100,100,200,100}))
    testing.expect_value(t,ctx.stats.scopes,u32(1))
    s.value.offset={30,-20}
    frame=test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices),{130,80,200,100}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"card")),{100,100,200,100}),"The layout does not move")
    // Scale and rotation turn around the center of the element.
    s.value=ANIM_IDENTITY
    s.value.scale={2,0.5}
    frame=test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices),{0,125,400,50}))
    s.value=ANIM_IDENTITY
    s.value.rotation=math.PI/2
    frame=test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices),{150,50,100,200},0.01))
    // Opacity and color multiply what is drawn.
    s.value=ANIM_IDENTITY
    s.value.opacity=0.5;s.value.color={1,0.5,0,1}
    frame=test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect_value(t,frame.vertices[0].color,[4]f32{1,0.5,0,0.5})
}

@(test)
nested_animations_compose_and_the_pointer_follows_them :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Animated{value=ANIM_IDENTITY,inner=ANIM_IDENTITY,nested=true}
    s.value.offset={300,0};s.value.opacity=0.5
    s.inner.scale={2,2};s.inner.opacity=0.5
    input:=test_input()
    test_frame(&ctx,&input,test_animated_build,&s)
    frame:=test_frame(&ctx,&input,test_animated_build,&s)
    // The button is laid out at (100,100) 50 by 20: doubled around its center and moved with its card.
    go:=test_rect(t,&ctx,id(&ctx,"go"))
    testing.expect(t,test_rect_near(go,{100,100,50,20}))
    button_vertices:=frame.vertices[6:]
    testing.expect(t,test_rect_near(test_drawn(frame,button_vertices),{375,90,100,40},0.01))
    testing.expect(t,test_near(button_vertices[0].color.a,0.25),"Opacities multiply down the tree")
    testing.expect_value(t,ctx.stats.scopes,u32(2))
    // Where it is drawn is where it is clicked.
    input.pointer={470,125}
    test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"go"))
    test_press(&input)
    test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect_value(t,s.clicks,1)
    test_release(&input)
    input.pointer={125,110}
    test_frame(&ctx,&input,test_animated_build,&s)
    testing.expect(t,ctx.hot==0,"Where it was laid out there is nothing")
}

@(test)
animated_subtrees_beyond_the_capacity_are_drawn_in_place_and_counted :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_scopes=3
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        value:=ANIM_IDENTITY
        value.offset={0,100}
        for i in 0..<4 {
            if animated(ctx,id(ctx,"box",i+1),value) {
                box_begin(ctx,{id=id(ctx,"box",i+1),width=fixed(10),height=fixed(10),fill={255,255,255,255}});box_end(ctx,{id=id(ctx,"box",i+1)})
            }
        }
    })
    testing.expect(t,frame.overflow)
    testing.expect_value(t,ctx.stats.dropped_scopes,u32(2))
    testing.expect_value(t,len(frame.vertices),24)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices[:12]),{0,100,20,10}))
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices[12:]),{20,0,20,10}))
}
