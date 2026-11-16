package ui

import "core:testing"

@(test)
composition_layers_bracket_the_whole_layout_subtree :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL));defer context_destroy(&ctx)
    frame_begin(&ctx,test_input(200,200))
    if box(&ctx,{id=id(&ctx,"outer"),width=fixed(100),height=fixed(100),layer={enabled=true,opacity=0.5,radius=12,backdrop_blur=6},fill={10,10,10,255}}) {
        if box(&ctx,{id=id(&ctx,"inner"),width=fixed(80),height=fixed(60),layer={enabled=true,opacity=1,radius=8},fill={200,10,10,255}}) {
            spacer(&ctx,10,10)
        }
    }
    frame:=frame_end(&ctx)
    testing.expect(t,!frame.overflow)
    testing.expect_value(t,len(frame.layers),2)
    testing.expect_value(t,len(frame.commands),6)
    expected:=[6]Command_Kind{.Begin_Layer,.Triangles,.Begin_Layer,.Triangles,.End_Layer,.End_Layer}
    for command,i in frame.commands {testing.expect_value(t,command.kind,expected[i])}
    testing.expect_value(t,frame.commands[0].layer,frame.commands[5].layer)
    testing.expect_value(t,frame.commands[2].layer,frame.commands[4].layer)
    testing.expect_value(t,frame.layers[0].bounds,Rect{0,0,100,100})
}

@(test)
layer_capacity_discards_the_subtree_and_keeps_balanced_commands :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL;desc.max_layers=1;desc.max_commands=4
    testing.expect(t,test_context_init(&ctx,desc));defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    if composition(&ctx,{0,0,100,100},{enabled=true,opacity=1}) {
        draw_rect(&ctx,{0,0,10,10},{255,255,255,255})
        if composition(&ctx,{0,0,40,40},{enabled=true,opacity=1}) {
            draw_rect(&ctx,{0,0,40,40},{255,0,0,255})
            if composition(&ctx,{},{}) {draw_rect(&ctx,{0,0,10,10},{0,255,0,255})}
        }
    }
    draw_rect(&ctx,{120,0,10,10},{0,0,255,255})
    frame:=frame_end(&ctx)
    testing.expect(t,frame.overflow)
    testing.expect_value(t,len(frame.layers),1)
    testing.expect_value(t,len(frame.vertices),12)
    testing.expect_value(t,ctx.stats.dropped_layers,1)
    testing.expect_value(t,frame.commands[0].kind,Command_Kind.Begin_Layer)
    testing.expect_value(t,frame.commands[2].kind,Command_Kind.End_Layer)
    testing.expect_value(t,frame.commands[3].kind,Command_Kind.Triangles)
}

@(test)
rounded_layer_clips_the_pointer_as_well_as_its_children :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL));defer context_destroy(&ctx)
    input:=test_input(200,200)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"glass"),width=fixed(100),height=fixed(100),layer={enabled=true,opacity=1,radius=30},block=true}) {
            button(ctx,id(ctx,"button"),{width=160,height=100})
        }
    }
    test_frame(&ctx,&input,build)
    input.pointer={1,1}
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,Id(0))
    input.pointer={130,50}
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,Id(0))
    input.pointer={50,50}
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,id(&ctx,"button"))
}

@(test)
a_layer_without_a_paint_slot_discards_its_whole_layout_and_input_subtree :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL;desc.max_paints=1
    testing.expect(t,test_context_init(&ctx,desc));defer context_destroy(&ctx)
    input:=test_input(200,200)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{width=fixed(20),height=fixed(20),fill={0,255,0,255}}) {}
        if box(ctx,{id=id(ctx,"discarded"),width=fixed(100),height=fixed(100),layer={enabled=true,opacity=1},block=true}) {
            button(ctx,id(ctx,"discarded_button"),{width=100,height=30})
            label(ctx,"A child without its layer must not escape")
        }
    }
    frame:=test_frame(&ctx,&input,build)
    testing.expect(t,frame.overflow)
    testing.expect_value(t,len(frame.layers),0)
    testing.expect_value(t,len(frame.commands),1)
    testing.expect_value(t,len(frame.shapes),1)
    testing.expect_value(t,len(frame.vertices),6)
    input.pointer={50,25}
    frame=test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,Id(0))
    testing.expect_value(t,ctx.previous_count,0)
    testing.expect_value(t,ctx.stats.dropped_layers,2)
}

@(test)
shape_and_layer_frames_use_only_preallocated_memory :: proc(t:^testing.T) {
    owned,ambient,scratch:Test_Counter
    desc:=TEST_SMALL;desc.allocator=test_counter(&owned,context.allocator)
    ctx:Context
    testing.expect(t,test_context_init(&ctx,desc));defer context_destroy(&ctx)
    owned.requests=0
    {
        context.allocator=test_counter(&ambient,context.allocator)
        context.temp_allocator=test_counter(&scratch,context.temp_allocator)
        for _ in 0..<10 {
            frame_begin(&ctx,test_input())
            if composition(&ctx,{20,20,100,100},{enabled=true,opacity=0.6,radius=20,backdrop_blur=8}) {
                draw_rounded(&ctx,{20,20,100,100},20,{30,30,40,200})
                draw_blurred_shadow(&ctx,{30,30,20,20},4,3,{0,2},{0,0,0,120})
            }
            frame:=frame_end(&ctx)
            testing.expect(t,!frame.overflow)
        }
    }
    testing.expect_value(t,owned.requests,0)
    testing.expect_value(t,ambient.requests,0)
    testing.expect_value(t,scratch.requests,0)
}

@(test)
floating_roots_detach_the_input_clip_of_their_authoring_layer :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL));defer context_destroy(&ctx)
    input:=test_input(300,200)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"hidden"),width=fixed(40),height=fixed(40),layer={enabled=true,opacity=0,radius=10}}) {
            if box(ctx,{id=id(ctx,"floating"),float={to=.Surface,offset={100,0}},width=fixed(80),height=fixed(30)}) {
                button(ctx,id(ctx,"outside"),{width=80,height=30,variant="field"})
            }
        }
    }
    test_frame(&ctx,&input,build)
    input.pointer={130,15}
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,id(&ctx,"outside"))
}

@(test)
a_rejected_child_layer_does_not_suppress_the_input_of_its_visible_parent :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL;desc.max_layers=1
    testing.expect(t,test_context_init(&ctx,desc));defer context_destroy(&ctx)
    input:=test_input(300,200)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"parent"),width=fixed(100),height=fixed(100),direction=.Column,layer={enabled=true,opacity=1}}) {
            button(ctx,id(ctx,"before"),{width=100,height=30,variant="field"})
            if box(ctx,{id=id(ctx,"rejected"),width=fixed(100),height=fixed(60),layer={enabled=true,opacity=1}}) {
                button(ctx,id(ctx,"discarded"),{width=100,height=30,variant="field"})
            }
        }
    }
    test_frame(&ctx,&input,build)
    input.pointer={50,15}
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,id(&ctx,"before"))
    input.pointer={50,45}
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.hot,Id(0))
}

@(test)
focus_rings_stay_inside_their_layer_and_disappear_with_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL));defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        opacity:=cast(^f32)user
        if box(ctx,{id=id(ctx,"group"),width=fixed(100),height=fixed(100),layer={enabled=true,opacity=opacity^,radius=10}}) {
            button(ctx,id(ctx,"focused"),{width=80,height=30,variant="field"})
        }
    }
    input:=test_input();opacity:=f32(1)
    ctx.focus=id(&ctx,"focused");ctx.focus_ring=true
    test_tone_set(&ctx,"focus",{255,255,255,255})
    frame:=test_frame(&ctx,&input,build,&opacity)
    testing.expect_value(t,frame.commands[len(frame.commands)-1].kind,Command_Kind.End_Layer)
    testing.expect_value(t,len(frame.shapes),2) // control and focus inside the same layer
    opacity=0
    frame=test_frame(&ctx,&input,build,&opacity)
    testing.expect_value(t,len(frame.shapes),1) // no visible ring over the invisible layer
}

@(test)
empty_scissors_hide_transformed_shapes_and_layer_composites :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL));defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    scissor_push(&ctx,{0,0,10,10});scissor_push(&ctx,{20,20,10,10})
    draw_transform(&ctx.draw,{1,0,30,0,1,0},{1,1,1,1},false)
    if composition(&ctx,{0,0,100,100},{enabled=true,opacity=1,backdrop_blur=4}) {
        draw_rounded(&ctx,{0,0,100,100},10,{255,255,255,255})
    }
    scissor_pop(&ctx);scissor_pop(&ctx)
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.vertices),0)
    testing.expect_value(t,len(frame.shapes),0)
    testing.expect_value(t,len(frame.commands),2)
    testing.expect(t,frame.commands[0].scissor.w<0 && frame.commands[1].scissor.h<0)
}

@(test)
a_layer_composes_in_a_panel_drawn_into_a_texture_and_not_in_one_of_the_scene :: proc(t:^testing.T) {
    for offscreen in ([2]bool{true,false}) {
        ctx:Context
        testing.expect(t,test_context_init(&ctx,TEST_SMALL))
        input:=test_input(400,400)
        input.view={position={0,2,5},fov_y=1.5,viewport_height=400}
        frame_begin(&ctx,input)
        if world_panel(&ctx,id(&ctx,"panel"),{position={0,2,0},size={200,100},unit=0.01,pivot=.Center,offscreen=offscreen}) {
            if box(&ctx,{id=id(&ctx,"card"),width=fixed(100),height=fixed(50),layer={enabled=true,opacity=0.5,radius=8},fill={200,10,10,255}}) {}
        }
        frame:=frame_end(&ctx)
        begun:=0
        for command in frame.commands {if command.kind==.Begin_Layer {begun+=1;testing.expect_value(t,command.surface,u32(1))}}
        testing.expectf(t,begun==(1 if offscreen else 0),"offscreen %v: %d layers begun",offscreen,begun)
        if offscreen {testing.expect_value(t,frame.layers[0].bounds,Rect{0,0,100,50})}
        context_destroy(&ctx)
    }
}
