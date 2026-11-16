package platform

import "base:runtime"
import "core:testing"

@(private)
test_headless :: proc(t:^testing.T,desc:Platform_Desc={}) -> ^Platform {
    desc:=desc
    desc.headless=true
    if desc.fixed_dt==0 {desc.fixed_dt=1.0/60}
    if desc.pacing==nil {desc.pacing=Frame_Pacing{}}
    p,error:=create(desc)
    testing.expect_value(t,error,Error.None)
    return p
}
// An allocator that gives nothing and counts who asked.
@(private)
test_no_allocator :: proc(count:^int) -> runtime.Allocator {
    refuse :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {(cast(^int)data)^+=1}
        return nil,.Out_Of_Memory
    }
    return {refuse,count}
}

@(test)
headless_platform_reports_the_window_of_its_desc :: proc(t:^testing.T) {
    p:=test_headless(t,{window={size={800,600},density=2,title="Mirai"}})
    defer destroy(p)
    frame_begin(p)
    f:=input_frame(p)
    testing.expect_value(t,f.window.size,[2]i32{800,600})
    testing.expect_value(t,f.window.pixel_size,[2]i32{1600,1200})
    testing.expect_value(t,f.window.density,f32(2))
    testing.expect(t,f.window.focused && f.window.visible && !f.window.resized)
    testing.expect(t,!f.mouse_inside)
    testing.expect_value(t,f.mouse_position,MOUSE_OUTSIDE)
    testing.expect_value(t,f.dt,f32(1.0/60))
    testing.expect_value(t,f.index,u64(0))
    testing.expect_value(t,window_title(p),"Mirai")
    testing.expect(t,window_native(p)==nil && metal_layer(p)==nil && vulkan_instance_extensions(p)==nil)
    frame_end(p)
    frame_begin(p)
    testing.expect_value(t,input_frame(p).index,u64(1))
    testing.expect_value(t,stats(p).frames,u64(2))
}

@(test)
headless_platform_takes_the_default_window_size :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    testing.expect_value(t,input_frame(p).window.size,WINDOW_SIZE_DEFAULT)
    testing.expect_value(t,pacing(p),Frame_Pacing{})
    q,error:=create({headless=true})
    defer destroy(q)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,pacing(q),FRAME_PACING_DEFAULT)
}

@(test)
injected_events_arrive_with_the_next_frame_in_order :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    frame_begin(p)
    testing.expect(t,input_inject(p,Key_Event{key=.W,down=true}))
    testing.expect(t,input_inject(p,Mouse_Motion_Event{position={10,20}}))
    // Nothing changes in the frame that is already being drawn.
    testing.expect(t,input_frame(p).keys_down=={})
    testing.expect_value(t,len(input_events(p)),0)
    frame_begin(p)
    events:=input_events(p)
    testing.expect_value(t,len(events),2)
    if len(events)==2 {
        key,is_key:=events[0].(Key_Event)
        testing.expect(t,is_key && key.key==.W && key.down)
        motion,is_motion:=events[1].(Mouse_Motion_Event)
        testing.expect(t,is_motion && motion.position==[2]f32{10,20})
    }
    frame_begin(p)
    testing.expect_value(t,len(input_events(p)),0)
}

@(test)
key_press_lasts_one_frame_and_stays_down :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    input_inject(p,Key_Event{key=.A,down=true})
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,f.keys_down==Keys{.A} && f.keys_pressed==Keys{.A} && f.keys_repeated==Keys{.A} && f.keys_released=={})
    frame_begin(p)
    testing.expect(t,f.keys_down==Keys{.A} && f.keys_pressed=={} && f.keys_repeated=={})
    input_inject(p,Key_Event{key=.A,down=true,repeat=true})
    frame_begin(p)
    testing.expect(t,f.keys_down==Keys{.A} && f.keys_pressed=={} && f.keys_repeated==Keys{.A})
    input_inject(p,Key_Event{key=.A,down=false})
    frame_begin(p)
    testing.expect(t,f.keys_down=={} && f.keys_released==Keys{.A})
    frame_begin(p)
    testing.expect(t,f.keys_released=={})
    // Letting go of a key that was never down is not a release.
    input_inject(p,Key_Event{key=.B,down=false})
    frame_begin(p)
    testing.expect(t,f.keys_released=={})
}

@(test)
tick_edges_last_exactly_one_tick_over_many_frames :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    input_inject(p,Key_Event{key=.Space,down=true})
    input_inject(p,Mouse_Button_Event{button=.Left,down=true,clicks=1,position={5,5}})
    frame_begin(p)
    // Three more frames are drawn before the simulation ticks: the frame
    // view has forgotten the press, the tick has not.
    frame_begin(p);frame_begin(p);frame_begin(p)
    testing.expect(t,input_frame(p).keys_pressed=={})
    tick:=input_tick_take(p)
    testing.expect(t,tick.keys_pressed==Keys{.Space} && tick.keys_down==Keys{.Space} && tick.keys_released=={})
    testing.expect(t,tick.mouse_pressed==Mouse_Buttons{.Left} && tick.mouse_down==Mouse_Buttons{.Left})
    testing.expect_value(t,tick.mouse_position,[2]f32{5,5})
    testing.expect_value(t,tick.window_size,[2]f32{f32(WINDOW_SIZE_DEFAULT.x),f32(WINDOW_SIZE_DEFAULT.y)})
    // A second tick in the same frame, and the ticks of later frames, see it held and no edge.
    tick=input_tick_take(p)
    testing.expect(t,tick.keys_pressed=={} && tick.keys_down==Keys{.Space} && tick.mouse_pressed=={})
    frame_begin(p)
    tick=input_tick_take(p)
    testing.expect(t,tick.keys_pressed=={} && tick.keys_down==Keys{.Space})
    input_inject(p,Key_Event{key=.Space,down=false})
    input_inject(p,Mouse_Button_Event{button=.Left,down=false,position={5,5}})
    frame_begin(p);frame_begin(p)
    tick=input_tick_take(p)
    testing.expect(t,tick.keys_released==Keys{.Space} && tick.keys_down=={})
    testing.expect(t,tick.mouse_released==Mouse_Buttons{.Left} && tick.mouse_down=={})
    tick=input_tick_take(p)
    testing.expect(t,tick.keys_released=={} && tick.mouse_released=={})
}

@(test)
pen_pressure_is_one_without_a_pen_and_follows_the_tip_while_it_touches :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,f.pressure==1 && !f.eraser)
    testing.expect(t,input_tick_take(p).pressure==1)
    input_inject(p,Pen_Event{down=true,pressure=0.4})
    frame_begin(p)
    testing.expect(t,f.pressure==0.4 && !f.eraser)
    tick:=input_tick_take(p)
    testing.expect(t,tick.pressure==0.4 && !tick.eraser)
    input_inject(p,Pen_Event{down=true,eraser=true,pressure=2})
    frame_begin(p)
    testing.expect(t,f.pressure==1 && f.eraser)
    input_inject(p,Pen_Event{down=false,eraser=true,pressure=0.3})
    frame_begin(p)
    testing.expect(t,f.pressure==1 && !f.eraser)
}

@(test)
key_tapped_between_two_ticks_is_pressed_and_released_but_not_down :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    input_inject(p,Key_Event{key=.E,down=true})
    input_inject(p,Key_Event{key=.E,down=false})
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,f.keys_pressed==Keys{.E} && f.keys_released==Keys{.E} && f.keys_down=={})
    tick:=input_tick_take(p)
    testing.expect(t,tick.keys_pressed==Keys{.E} && tick.keys_released==Keys{.E} && tick.keys_down=={})
}

@(test)
mouse_delta_and_wheel_add_up_per_frame_and_per_tick :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    input_inject(p,Mouse_Motion_Event{position={100,100}})
    frame_begin(p)
    f:=input_frame(p)
    // Entering the window is not a movement.
    testing.expect(t,f.mouse_inside)
    testing.expect_value(t,f.mouse_delta,[2]f32{0,0})
    input_inject(p,Mouse_Motion_Event{position={110,95}})
    input_inject(p,Mouse_Motion_Event{position={112,95},delta={2,0}})
    input_inject(p,Mouse_Wheel_Event{delta={0,1}})
    frame_begin(p)
    testing.expect_value(t,f.mouse_position,[2]f32{112,95})
    testing.expect_value(t,f.mouse_delta,[2]f32{12,-5})
    testing.expect_value(t,f.wheel,[2]f32{0,1})
    // Relative mode: the pointer stays where it is and the motion keeps arriving.
    input_inject(p,Mouse_Motion_Event{position={112,95},delta={3,4}})
    input_inject(p,Mouse_Wheel_Event{delta={0,-2}})
    frame_begin(p)
    testing.expect_value(t,f.mouse_delta,[2]f32{3,4})
    testing.expect_value(t,f.wheel,[2]f32{0,-2})
    tick:=input_tick_take(p)
    testing.expect_value(t,tick.mouse_delta,[2]f32{15,-1})
    testing.expect_value(t,tick.wheel,[2]f32{0,-1})
    tick=input_tick_take(p)
    testing.expect_value(t,tick.mouse_delta,[2]f32{0,0})
    testing.expect_value(t,tick.wheel,[2]f32{0,0})
}

@(test)
click_without_motion_happens_where_the_click_says :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    // A tap or an automated click: down and up in one frame, no motion before.
    input_inject(p,Mouse_Button_Event{button=.Left,down=true,clicks=2,position={40,30}})
    input_inject(p,Mouse_Button_Event{button=.Left,down=false,clicks=2,position={42,33}})
    frame_begin(p)
    f:=input_frame(p)
    testing.expect_value(t,f.mouse_position,[2]f32{42,33})
    testing.expect_value(t,f.mouse_delta,[2]f32{2,3})
    testing.expect(t,f.mouse_pressed==Mouse_Buttons{.Left} && f.mouse_released==Mouse_Buttons{.Left} && f.mouse_down=={})
    testing.expect_value(t,f.mouse_clicks[.Left],u8(2))
    frame_begin(p)
    testing.expect(t,f.mouse_pressed=={} && f.mouse_released=={})
    testing.expect_value(t,f.mouse_clicks[.Left],u8(0))
    testing.expect_value(t,f.mouse_delta,[2]f32{0,0})
}

@(test)
pointer_that_leaves_is_outside_unless_it_is_dragging :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    input_inject(p,Mouse_Button_Event{button=.Right,down=true,position={10,10}})
    input_inject(p,Window_Event{kind=.Mouse_Left})
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,f.mouse_inside)
    testing.expect_value(t,f.mouse_position,[2]f32{10,10})
    input_inject(p,Mouse_Button_Event{button=.Right,down=false,position={10,10}})
    input_inject(p,Window_Event{kind=.Mouse_Left})
    frame_begin(p)
    testing.expect(t,!f.mouse_inside)
    testing.expect_value(t,f.mouse_position,MOUSE_OUTSIDE)
}

@(test)
text_is_gathered_in_order_up_to_its_capacity :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    testing.expect(t,input_inject_text(p,"añ1"))
    frame_begin(p)
    text:=input_text(p)
    testing.expect_value(t,len(text),3)
    if len(text)==3 {testing.expect(t,text[0]=='a' && text[1]=='ñ' && text[2]=='1')}
    frame_begin(p)
    testing.expect_value(t,len(input_text(p)),0)
    for _ in 0..<TEXT_CAPACITY+5 {input_inject(p,Text_Event{'x'})}
    frame_begin(p)
    testing.expect_value(t,len(input_text(p)),TEXT_CAPACITY)
    testing.expect_value(t,stats(p).text_dropped,u64(5))
    testing.expect_value(t,input_frame(p).text_dropped,5)
    frame_begin(p)
    testing.expect_value(t,input_frame(p).text_dropped,0)
}

@(test)
gamepad_reports_buttons_axes_and_its_disconnection :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    // A device that is not connected sends nothing.
    input_inject(p,Gamepad_Button_Event{gamepad=1,button=.South,down=true})
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,!f.gamepads[1].connected && f.gamepads[1].down=={})
    input_inject(p,Gamepad_Device_Event{gamepad=1,connected=true})
    input_inject(p,Gamepad_Button_Event{gamepad=1,button=.South,down=true})
    input_inject(p,Gamepad_Axis_Event{gamepad=1,axis=.Left_X,value=-0.5})
    input_inject(p,Gamepad_Axis_Event{gamepad=1,axis=.Right_Trigger,value=3})
    frame_begin(p)
    g:=&f.gamepads[1]
    testing.expect(t,g.connected && g.down==Gamepad_Buttons{.South} && g.pressed==Gamepad_Buttons{.South})
    testing.expect_value(t,g.axes[.Left_X],f32(-0.5))
    testing.expect_value(t,g.axes[.Right_Trigger],f32(1))
    testing.expect(t,!f.gamepads[0].connected)
    frame_begin(p);frame_begin(p)
    testing.expect(t,g.pressed=={} && g.down==Gamepad_Buttons{.South})
    tick:=input_tick_take(p)
    testing.expect(t,tick.gamepads[1].connected && tick.gamepads[1].pressed==Gamepad_Buttons{.South} && tick.gamepads[1].down==Gamepad_Buttons{.South})
    testing.expect_value(t,tick.gamepads[1].axes[.Left_X],f32(-0.5))
    tick=input_tick_take(p)
    testing.expect(t,tick.gamepads[1].pressed=={})
    // Unplugged with a button held: the button is released with it.
    input_inject(p,Gamepad_Device_Event{gamepad=1,connected=false})
    frame_begin(p)
    testing.expect(t,!g.connected && g.down=={} && g.released==Gamepad_Buttons{.South})
    testing.expect_value(t,g.axes[.Left_X],f32(0))
    tick=input_tick_take(p)
    testing.expect(t,!tick.gamepads[1].connected && tick.gamepads[1].released==Gamepad_Buttons{.South})
    // A device beyond the capacity is ignored.
    input_inject(p,Gamepad_Device_Event{gamepad=GAMEPAD_CAPACITY,connected=true})
    frame_begin(p)
    testing.expect_value(t,len(input_events(p)),0)
}

@(test)
the_family_of_a_gamepad_and_the_device_used_last_reach_the_frame_and_the_tick :: proc(t:^testing.T) {
    testing.expect_value(t,gamepad_family(.PS5),Gamepad_Family.PlayStation)
    testing.expect_value(t,gamepad_family(.NINTENDO_SWITCH_JOYCON_PAIR),Gamepad_Family.Nintendo)
    testing.expect_value(t,gamepad_family(.STANDARD),Gamepad_Family.Xbox)
    p:=test_headless(t)
    defer destroy(p)
    input_inject(p,Gamepad_Device_Event{gamepad=2,connected=true,family=.PlayStation})
    input_inject(p,Key_Event{key=.W,down=true})
    frame_begin(p)
    f:=input_frame(p)
    testing.expect_value(t,f.gamepads[2].family,Gamepad_Family.PlayStation)
    testing.expect_value(t,f.device,Device{})
    // A stick that rests near its center, and a mouse that trembles, do not take the device.
    input_inject(p,Gamepad_Axis_Event{gamepad=2,axis=.Left_X,value=0.2})
    frame_begin(p)
    testing.expect_value(t,f.device,Device{})
    input_inject(p,Gamepad_Axis_Event{gamepad=2,axis=.Right_Trigger,value=0.8})
    frame_begin(p)
    testing.expect_value(t,f.device,Device{gamepad=true,slot=2})
    input_inject(p,Mouse_Motion_Event{position={10,10}})
    input_inject(p,Mouse_Motion_Event{position={10.5,10}})
    frame_begin(p)
    testing.expect_value(t,f.device,Device{gamepad=true,slot=2})
    tick:=input_tick_take(p)
    testing.expect(t,tick.device==Device{gamepad=true,slot=2} && tick.gamepads[2].family==.PlayStation)
    input_inject(p,Mouse_Motion_Event{position={40,10}})
    frame_begin(p)
    testing.expect_value(t,f.device,Device{})
    input_inject(p,Gamepad_Button_Event{gamepad=2,button=.South,down=true})
    frame_begin(p)
    testing.expect_value(t,f.device,Device{gamepad=true,slot=2})
    // Unplugging the device used last gives the keyboard back.
    input_inject(p,Gamepad_Device_Event{gamepad=2,connected=false})
    frame_begin(p)
    testing.expect_value(t,f.device,Device{})
}

@(test)
dropped_files_are_readable_for_one_frame :: proc(t:^testing.T) {
    p:=test_headless(t,{drop_capacity=2,drop_bytes=32})
    defer destroy(p)
    testing.expect(t,input_inject_drop(p,"C:/models/a.glb"))
    testing.expect(t,input_inject_drop(p,"b.png",{12,34}))
    // Neither a third path nor one that does not fit in the bytes left.
    testing.expect(t,!input_inject_drop(p,"c.png"))
    frame_begin(p)
    f:=input_frame(p)
    testing.expect_value(t,f.drop_count,2)
    testing.expect_value(t,input_dropped(p,0),"C:/models/a.glb")
    testing.expect_value(t,input_dropped(p,1),"b.png")
    testing.expect_value(t,input_dropped(p,2),"")
    events:=input_events(p)
    testing.expect_value(t,len(events),2)
    if len(events)==2 {
        drop,is_drop:=events[1].(Drop_Event)
        testing.expect(t,is_drop && drop.index==1 && drop.position==[2]f32{12,34})
    }
    testing.expect_value(t,stats(p).drops_dropped,u64(1))
    testing.expect(t,input_inject_drop(p,"0123456789012345678901234567"))
    testing.expect(t,!input_inject_drop(p,"too long"))
    frame_begin(p)
    testing.expect_value(t,f.drop_count,1)
    testing.expect_value(t,input_dropped(p,0),"0123456789012345678901234567")
    frame_begin(p)
    testing.expect_value(t,f.drop_count,0)
    testing.expect_value(t,input_dropped(p,0),"")
}

@(test)
events_beyond_the_capacity_still_change_the_state :: proc(t:^testing.T) {
    p:=test_headless(t,{event_capacity=4})
    defer destroy(p)
    keys:=[?]Key{.A,.B,.C,.D}
    for key in keys {testing.expect(t,input_inject(p,Key_Event{key=key,down=true}))}
    // The queue of injected events has the same capacity.
    testing.expect(t,!input_inject(p,Key_Event{key=.E,down=true}))
    testing.expect_value(t,stats(p).injected_dropped,u64(1))
    frame_begin(p)
    testing.expect_value(t,len(input_events(p)),4)
    testing.expect(t,input_frame(p).keys_down==Keys{.A,.B,.C,.D})
    // Events that cannot be injected: none at all, and a drop without its path.
    testing.expect(t,!input_inject(p,nil))
    testing.expect(t,!input_inject(p,Drop_Event{index=0}))
}

@(test)
window_events_drive_the_window_of_a_headless_platform :: proc(t:^testing.T) {
    p:=test_headless(t,{window={size={640,480},density=1.5}})
    defer destroy(p)
    frame_begin(p)
    f:=input_frame(p)
    window_set_size(p,{1000,500})
    frame_begin(p)
    testing.expect(t,f.window.resized)
    testing.expect_value(t,f.window.size,[2]i32{1000,500})
    testing.expect_value(t,f.window.pixel_size,[2]i32{1500,750})
    frame_begin(p)
    testing.expect(t,!f.window.resized)
    input_inject(p,Window_Event{kind=.Focus_Lost})
    input_inject(p,Window_Event{kind=.Close_Requested})
    input_inject(p,Window_Event{kind=.Minimized})
    frame_begin(p)
    testing.expect(t,!f.window.focused && f.window.focus_lost && f.window.close_requested && f.window.minimized)
    input_inject(p,Window_Event{kind=.Focus_Gained})
    input_inject(p,Window_Event{kind=.Restored})
    frame_begin(p)
    testing.expect(t,f.window.focused && f.window.focus_gained && !f.window.focus_lost && !f.window.close_requested && !f.window.minimized)
    window_set_maximized(p,true)
    window_set_fullscreen(p,true)
    window_hide(p)
    testing.expect(t,f.window.maximized && f.window.fullscreen && !f.window.visible)
    window_set_maximized(p,false)
    window_set_fullscreen(p,false)
    window_show(p)
    window_minimize(p)
    testing.expect(t,!f.window.maximized && !f.window.fullscreen && f.window.visible && f.window.minimized)
}

@(test)
headless_platform_keeps_title_cursor_mouse_mode_and_clipboard :: proc(t:^testing.T) {
    p:=test_headless(t,{clipboard_bytes=16})
    defer destroy(p)
    window_set_title(p,"scene * - Mirai")
    testing.expect_value(t,window_title(p),"scene * - Mirai")
    testing.expect_value(t,window_cursor(p),Cursor.Default)
    window_set_cursor(p,.Resize_Horizontal)
    testing.expect_value(t,window_cursor(p),Cursor.Resize_Horizontal)
    testing.expect(t,!window_relative_mouse(p))
    window_set_relative_mouse(p,true)
    testing.expect(t,window_relative_mouse(p))
    _,has:=clipboard_get(p)
    testing.expect(t,!has)
    testing.expect(t,clipboard_set(p,"copied"))
    text,ok:=clipboard_get(p)
    testing.expect(t,ok)
    testing.expect_value(t,text,"copied")
    testing.expect(t,!clipboard_set(p,"more than sixteen bytes"))
    text,_=clipboard_get(p)
    testing.expect_value(t,text,"copied")
    testing.expect_value(t,window_refresh_rate(p),f32(0))
}

@(test)
steady_frames_allocate_nothing :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    count:=0
    {
        context.allocator=test_no_allocator(&count)
        context.temp_allocator=test_no_allocator(&count)
        for i in 0..<100 {
            input_inject(p,Key_Event{key=.W,down=i%2==0})
            input_inject(p,Mouse_Motion_Event{position={f32(i),f32(i)}})
            input_inject_text(p,"w")
            input_inject_drop(p,"file.txt")
            input_inject(p,Window_Event{kind=.Resized,size={i32(800+i),600}})
            window_set_title(p,"title" if i%2==0 else "other")
            window_set_regions(p,{{{0,0,100,30},.Drag}})
            frame_begin(p)
            _=input_tick_take(p)
            _=input_events(p)
            _=window_hit_at(p,{10,10})
            frame_end(p)
        }
    }
    testing.expect_value(t,count,0)
    testing.expect_value(t,stats(p).frames,u64(100))
}

// Gives memory from the allocator of the test until it has been asked `allowed` times.
@(private)
Test_Failing_Allocator :: struct {backing:runtime.Allocator,allowed,asked:int}
@(private)
test_failing_allocator :: proc(state:^Test_Failing_Allocator) -> runtime.Allocator {
    limited :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        state:=cast(^Test_Failing_Allocator)data
        if mode==.Alloc || mode==.Alloc_Non_Zeroed {
            state.asked+=1
            if state.asked>state.allowed {return nil,.Out_Of_Memory}
        }
        return state.backing.procedure(state.backing.data,mode,size,alignment,old,old_size,loc)
    }
    return {limited,state}
}

@(test)
platform_that_runs_out_of_memory_while_it_is_created_leaves_nothing_behind :: proc(t:^testing.T) {
    // Every allocation of create fails in turn; the test runner reports what is not freed.
    for allowed in 0..<64 {
        state:=Test_Failing_Allocator{backing=context.allocator,allowed=allowed}
        p,error:=create({headless=true,allocator=test_failing_allocator(&state)})
        if error==.None {
            testing.expect(t,p!=nil && allowed>5)
            destroy(p)
            return
        }
        testing.expect(t,p==nil && error==.Out_Of_Memory)
    }
    testing.expect(t,false,"create never succeeded")
}
