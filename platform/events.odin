package platform

import sdl "vendor:sdl3"

// A poll that has not returned for this long is being held by the window system.
POLL_HELD_NS :: u64(30_000_000)
// Several events tell of one change of the window: live frames are no closer than this.
LIVE_FRAME_NS :: u64(4_000_000)

@(private)
window_pump :: proc(p:^Platform,now:u64) {
    w:=&p.window
    window_refresh(p,&p.input.frame.window)
    w.resize_input=w.resize.hit!=.NORMAL
    p.live.poll_start=now
    event:sdl.Event
    for sdl.PollEvent(&event) {
        if w.resize_input && (event.type==.MOUSE_MOTION || event.type==.MOUSE_BUTTON_DOWN || event.type==.MOUSE_BUTTON_UP) {continue}
        window_translate(p,&event)
    }
    p.live.poll_start=0
    if w.toggle_maximize {
        w.toggle_maximize=false
        window_set_maximized(p,.MAXIMIZED not_in sdl.GetWindowFlags(w.handle))
    }
}

@(private)
window_translate :: proc(p:^Platform,event:^sdl.Event) {
    w:=&p.window
    #partial switch event.type {
    // SDL also sends QUIT for Cmd+Q in the macOS menu and for SIGINT and SIGTERM.
    case .QUIT,.WINDOW_CLOSE_REQUESTED:input_apply(p,Window_Event{kind=.Close_Requested})
    case .AUDIO_DEVICE_ADDED,.AUDIO_DEVICE_REMOVED:audio_device_event(p,event.adevice)
    case .WINDOW_FOCUS_GAINED:input_apply(p,Window_Event{kind=.Focus_Gained})
    case .WINDOW_FOCUS_LOST:
        if w.resize.hit!=.NORMAL {w.resize.hit=.NORMAL;_=sdl.CaptureMouse(false)}
        input_apply(p,Window_Event{kind=.Focus_Lost})
    case .WINDOW_MOUSE_ENTER:input_apply(p,Window_Event{kind=.Mouse_Entered})
    case .WINDOW_MOUSE_LEAVE:input_apply(p,Window_Event{kind=.Mouse_Left})
    case .WINDOW_MINIMIZED:input_apply(p,Window_Event{kind=.Minimized})
    case .WINDOW_MAXIMIZED:input_apply(p,Window_Event{kind=.Maximized})
    case .WINDOW_RESTORED:input_apply(p,Window_Event{kind=.Restored})
    case .WINDOW_ENTER_FULLSCREEN:input_apply(p,Window_Event{kind=.Fullscreen_Entered})
    case .WINDOW_LEAVE_FULLSCREEN:input_apply(p,Window_Event{kind=.Fullscreen_Left})
    case .WINDOW_SHOWN:input_apply(p,Window_Event{kind=.Shown})
    case .WINDOW_HIDDEN:input_apply(p,Window_Event{kind=.Hidden})
    case .WINDOW_RESIZED,.WINDOW_PIXEL_SIZE_CHANGED,.WINDOW_DISPLAY_SCALE_CHANGED:
        window_refresh(p,&p.input.frame.window)
        frame:=p.input.frame.window
        input_apply(p,Window_Event{kind=.Resized,size=frame.size,pixel_size=frame.pixel_size})
    case .WINDOW_DISPLAY_CHANGED,.DISPLAY_CURRENT_MODE_CHANGED:window_refresh_rate_read(p)
    case .KEY_DOWN,.KEY_UP:
        if key,ok:=key_from_scancode(event.key.scancode);ok {
            input_apply(p,Key_Event{key=key,down=event.key.down,repeat=event.key.repeat})
        }
    case .TEXT_INPUT:
        for codepoint in string(event.text.text) {input_apply(p,Text_Event{codepoint})}
    case .MOUSE_MOTION:
        delta:=[2]f32{event.motion.xrel,event.motion.yrel}
        if !w.relative_mouse {delta=window_point(p,delta)}
        input_apply(p,Mouse_Motion_Event{position=window_point(p,{event.motion.x,event.motion.y}),delta=delta})
    case .MOUSE_BUTTON_DOWN,.MOUSE_BUTTON_UP:
        button:Mouse_Button
        switch event.button.button {
        case sdl.BUTTON_LEFT:button=.Left
        case sdl.BUTTON_RIGHT:button=.Right
        case sdl.BUTTON_MIDDLE:button=.Middle
        case sdl.BUTTON_X1:button=.X1
        case sdl.BUTTON_X2:button=.X2
        case:return
        }
        input_apply(p,Mouse_Button_Event{button=button,down=event.button.down,clicks=event.button.clicks,position=window_point(p,{event.button.x,event.button.y})})
    case .MOUSE_WHEEL:input_apply(p,Mouse_Wheel_Event{delta={event.wheel.x,event.wheel.y}})
    // SDL also turns the pen into mouse events: its position and clicks come from those.
    case .PEN_DOWN,.PEN_UP:input_apply(p,Pen_Event{down=event.ptouch.down,eraser=event.ptouch.eraser,pressure=w.pen_pressure})
    case .PEN_AXIS:
        if event.paxis.axis!=.PRESSURE {return}
        w.pen_pressure=event.paxis.value
        if .DOWN in event.paxis.pen_state {input_apply(p,Pen_Event{down=true,eraser=.ERASER_TIP in event.paxis.pen_state,pressure=w.pen_pressure})}
    case .PEN_PROXIMITY_OUT:w.pen_pressure=1
    case .DROP_FILE:
        if event.drop.data==nil {return}
        if index,ok:=drop_store(p,&p.input.drops[p.input.drop_active],string(event.drop.data));ok {
            input_apply(p,Drop_Event{index,window_point(p,{event.drop.x,event.drop.y})})
        }
    case .GAMEPAD_ADDED:
        id:=event.gdevice.which
        if _,known:=gamepad_slot(w,id);known {return}
        slot,free:=gamepad_slot(w,0)
        if !free {p.stats.gamepads_ignored+=1;return}
        handle:=sdl.OpenGamepad(id)
        if handle==nil {return}
        w.gamepads[slot]={id,handle}
        input_apply(p,Gamepad_Device_Event{gamepad=u8(slot),connected=true,family=gamepad_family(sdl.GetGamepadType(handle))})
    case .GAMEPAD_REMOVED:
        if slot,known:=gamepad_slot(w,event.gdevice.which);known {
            sdl.CloseGamepad(w.gamepads[slot].handle)
            w.gamepads[slot]={}
            input_apply(p,Gamepad_Device_Event{gamepad=u8(slot),connected=false})
        }
    case .GAMEPAD_BUTTON_DOWN,.GAMEPAD_BUTTON_UP:
        slot,known:=gamepad_slot(w,event.gbutton.which)
        if !known || int(event.gbutton.button)>=len(Gamepad_Button) {return}
        input_apply(p,Gamepad_Button_Event{gamepad=u8(slot),button=Gamepad_Button(event.gbutton.button),down=event.gbutton.down})
    case .GAMEPAD_AXIS_MOTION:
        slot,known:=gamepad_slot(w,event.gaxis.which)
        if !known || int(event.gaxis.axis)>=len(Gamepad_Axis) {return}
        input_apply(p,Gamepad_Axis_Event{gamepad=u8(slot),axis=Gamepad_Axis(event.gaxis.axis),value=max(f32(event.gaxis.value)/32767,-1)})
    }
}
#assert(int(sdl.GamepadButton.DPAD_RIGHT)==int(Gamepad_Button.Dpad_Right))
#assert(int(sdl.GamepadAxis.RIGHT_TRIGGER)==int(Gamepad_Axis.Right_Trigger))

gamepad_family :: proc "contextless" (type:sdl.GamepadType) -> Gamepad_Family {
    #partial switch type {
    case .PS3,.PS4,.PS5: return .PlayStation
    case .NINTENDO_SWITCH_PRO,.NINTENDO_SWITCH_JOYCON_LEFT,.NINTENDO_SWITCH_JOYCON_RIGHT,.NINTENDO_SWITCH_JOYCON_PAIR: return .Nintendo
    }
    return .Xbox
}

// Slot of the gamepad with this SDL id; id 0 finds a free slot.
@(private)
gamepad_slot :: proc(w:^Window,id:sdl.JoystickID) -> (slot:int,found:bool) {
    for candidate,i in w.gamepads {
        if candidate.id==id && (id!=0 || candidate.handle==nil) {return i,true}
    }
    return 0,false
}

@(private)
window_hit_callback :: proc "c" (window:^sdl.Window,area:^sdl.Point,data:rawptr) -> sdl.HitTestResult {
    p:=cast(^Platform)data
    context=p.frame_context
    w:=&p.window
    width,height:i32
    _=sdl.GetWindowSize(window,&width,&height)
    flags:=sdl.GetWindowFlags(window)
    resizable:=w.resizable && !w.fixed_size && flags&{.MAXIMIZED,.FULLSCREEN}=={}
    scale:=window_scale(window).coordinate
    hit:=window_hit({f32(area.x)/scale,f32(area.y)/scale},{i32(f32(width)/scale+0.5),i32(f32(height)/scale+0.5)},w.regions[:w.region_count],resizable)
    return window_native_hit(p,sdl.HitTestResult(hit))
}

@(private)
window_watch_live :: proc(p:^Platform,watch:bool) {
    if p.live.watching==watch || p.window.handle==nil {return}
    p.live.watching=watch
    if watch {_=sdl.AddEventWatch(window_live_watch,p)} else {sdl.RemoveEventWatch(window_live_watch,p)}
}
// SDL still tells a watcher that the window changed or wants drawing while
// the window system holds the poll: the live frame runs from here.
@(private)
window_live_watch :: proc "c" (user:rawptr,event:^sdl.Event) -> bool {
    p:=cast(^Platform)user
    if event.type!=.WINDOW_EXPOSED && event.type!=.WINDOW_RESIZED && event.type!=.WINDOW_PIXEL_SIZE_CHANGED && event.type!=.WINDOW_DISPLAY_SCALE_CHANGED {return true}
    live:=&p.live
    if live.frame==nil || live.running || live.poll_start==0 {return true}
    now:=sdl.GetTicksNS()
    if now-live.poll_start<POLL_HELD_NS || now-p.clock.last<LIVE_FRAME_NS {return true}
    context=p.frame_context
    s:=&p.input
    s.live=s.frame
    f:=&s.live
    f.keys_pressed={};f.keys_released={};f.keys_repeated={}
    f.mouse_pressed={};f.mouse_released={};f.mouse_clicks={}
    f.mouse_delta={};f.wheel={};f.text_count=0;f.drop_count=0
    for &g in f.gamepads {g.pressed={};g.released={}}
    previous_size,previous_pixels:=f.window.size,f.window.pixel_size
    f.window.focus_gained=false;f.window.focus_lost=false;f.window.close_requested=false
    window_refresh(p,&f.window)
    f.window.resized=f.window.size!=previous_size || f.window.pixel_size!=previous_pixels
    f.dt=frame_clock_dt(p,now,false)
    p.clock.last=now
    f.index=p.stats.frames;p.stats.frames+=1;p.stats.live_frames+=1
    live.running=true
    live.frame(live.user)
    live.running=false
    // The frame that is being polled goes on from the size the live one drew.
    s.frame.window.size=f.window.size;s.frame.window.pixel_size=f.window.pixel_size;s.frame.window.density=f.window.density;s.frame.window.pixel_density=f.window.pixel_density
    return true
}

@(private)
key_from_scancode :: proc "contextless" (code:sdl.Scancode) -> (Key,bool) {
    #partial switch code {
    case .A:return .A,true
    case .B:return .B,true
    case .C:return .C,true
    case .D:return .D,true
    case .E:return .E,true
    case .F:return .F,true
    case .G:return .G,true
    case .H:return .H,true
    case .I:return .I,true
    case .J:return .J,true
    case .K:return .K,true
    case .L:return .L,true
    case .M:return .M,true
    case .N:return .N,true
    case .O:return .O,true
    case .P:return .P,true
    case .Q:return .Q,true
    case .R:return .R,true
    case .S:return .S,true
    case .T:return .T,true
    case .U:return .U,true
    case .V:return .V,true
    case .W:return .W,true
    case .X:return .X,true
    case .Y:return .Y,true
    case .Z:return .Z,true
    case ._0:return .Zero,true
    case ._1:return .One,true
    case ._2:return .Two,true
    case ._3:return .Three,true
    case ._4:return .Four,true
    case ._5:return .Five,true
    case ._6:return .Six,true
    case ._7:return .Seven,true
    case ._8:return .Eight,true
    case ._9:return .Nine,true
    case .F1:return .F1,true
    case .F2:return .F2,true
    case .F3:return .F3,true
    case .F4:return .F4,true
    case .F5:return .F5,true
    case .F6:return .F6,true
    case .F7:return .F7,true
    case .F8:return .F8,true
    case .F9:return .F9,true
    case .F10:return .F10,true
    case .F11:return .F11,true
    case .F12:return .F12,true
    case .ESCAPE:return .Escape,true
    case .RETURN,.KP_ENTER:return .Enter,true
    case .TAB:return .Tab,true
    case .SPACE:return .Space,true
    case .BACKSPACE:return .Backspace,true
    case .DELETE:return .Delete,true
    case .INSERT:return .Insert,true
    case .HOME:return .Home,true
    case .END:return .End,true
    case .PAGEUP:return .Page_Up,true
    case .PAGEDOWN:return .Page_Down,true
    case .LEFT:return .Left,true
    case .RIGHT:return .Right,true
    case .UP:return .Up,true
    case .DOWN:return .Down,true
    case .LSHIFT:return .Left_Shift,true
    case .RSHIFT:return .Right_Shift,true
    case .LCTRL:return .Left_Control,true
    case .RCTRL:return .Right_Control,true
    case .LALT:return .Left_Alt,true
    case .RALT:return .Right_Alt,true
    case .LGUI:return .Left_Super,true
    case .RGUI:return .Right_Super,true
    case .MINUS:return .Minus,true
    case .EQUALS:return .Equals,true
    case .LEFTBRACKET:return .Left_Bracket,true
    case .RIGHTBRACKET:return .Right_Bracket,true
    case .SEMICOLON:return .Semicolon,true
    case .APOSTROPHE:return .Apostrophe,true
    case .COMMA:return .Comma,true
    case .PERIOD:return .Period,true
    case .SLASH:return .Slash,true
    case .BACKSLASH:return .Backslash,true
    case .GRAVE:return .Grave,true
    }
    return {},false
}
