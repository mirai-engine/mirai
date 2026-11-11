package platform

import "core:testing"
import sdl "vendor:sdl3"
import audio "mirai:audio"

// SDL keeps one video subsystem and one event queue per process, and tests
// run on several threads: everything that needs them runs from this one
// test, one check after another. The dummy video driver opens no window on
// the desktop; the native checks that follow it create windows that never
// reach the screen.
@(test)
windowed_platform_works_through_sdl :: proc(t:^testing.T) {
    sdl_window_reports_its_state_and_translates_events(t)
    sdl_events_beyond_the_capacity_still_change_the_state(t)
    sdl_pen_pressure_reaches_the_frame_while_the_tip_touches(t)
    sdl_live_frames_run_while_the_window_system_holds_the_poll(t)
    sdl_virtual_gamepad_connects_reports_and_disconnects(t)
    sdl_audio_device_pulls_from_the_mixer(t)
    native_hidden_window_checks(t)
    native_veiled_window_checks(t)
}

@(private="file")
test_windowed :: proc(t:^testing.T,desc:Platform_Desc={}) -> ^Platform {
    desc:=desc
    desc.video_driver="dummy"
    desc.window.no_surface=true
    if desc.pacing==nil {desc.pacing=Frame_Pacing{}}
    p,error:=create(desc)
    testing.expect_value(t,error,Error.None)
    return p
}
@(private="file")
push :: proc(t:^testing.T,event:^sdl.Event) {
    testing.expect(t,sdl.PushEvent(event))
}

@(private="file")
sdl_window_reports_its_state_and_translates_events :: proc(t:^testing.T) {
    p:=test_windowed(t,{window={title="Mirai test",size={800,600},chrome=.Custom}})
    if p==nil {return}
    defer destroy(p)
    testing.expect(t,window_native(p)!=nil)
    testing.expect_value(t,string(sdl.GetCurrentVideoDriver()),"dummy")
    frame_begin(p)
    f:=input_frame(p)
    testing.expect_value(t,f.window.size,[2]i32{800,600})
    testing.expect_value(t,f.window.pixel_size,[2]i32{800,600})
    testing.expect_value(t,f.window.density,f32(1))
    testing.expect(t,f.window.visible && !f.window.minimized && !f.window.fullscreen)
    testing.expect_value(t,string(sdl.GetWindowTitle(p.window.handle)),"Mirai test")
    testing.expect(t,.BORDERLESS in sdl.GetWindowFlags(p.window.handle))
    testing.expect(t,.RESIZABLE in sdl.GetWindowFlags(p.window.handle))
    minimum:[2]i32
    testing.expect(t,sdl.GetWindowMinimumSize(p.window.handle,&minimum.x,&minimum.y))
    testing.expect_value(t,minimum,WINDOW_MINIMUM_SIZE_DEFAULT)

    // The dummy driver has one display, where the window is.
    displays:=display_names(p,context.temp_allocator)
    testing.expect(t,len(displays)>=1)
    testing.expect_value(t,window_display(p),0)
    testing.expect(t,window_set_display(p,0) && !window_set_display(p,len(displays)) && !window_set_display(p,-1))

    window_set_title(p,"main.scene * - Mirai")
    testing.expect_value(t,string(sdl.GetWindowTitle(p.window.handle)),"main.scene * - Mirai")
    testing.expect_value(t,window_title(p),"main.scene * - Mirai")

    // Shown, it waits for a frame that presents before it reaches the screen.
    testing.expect_value(t,p.window.veil,WINDOW_VEIL_FRAMES)
    frame_end(p,false)
    testing.expect_value(t,p.window.veil,WINDOW_VEIL_FRAMES-1)
    frame_end(p,true)
    testing.expect_value(t,p.window.veil,0)

    // Keys, text, the mouse and a dropped file as SDL delivers them.
    event:sdl.Event
    event.key={type=.KEY_DOWN,scancode=.W,down=true}
    push(t,&event)
    event={};event.key={type=.KEY_DOWN,scancode=.W,down=true,repeat=true}
    push(t,&event)
    event={};event.key={type=.KEY_DOWN,scancode=.KP_ENTER,down=true}
    push(t,&event)
    event={};event.key={type=.KEY_DOWN,scancode=.CAPSLOCK,down=true} // not in the key set
    push(t,&event)
    event={};event.text={type=.TEXT_INPUT,text="wé"}
    push(t,&event)
    event={};event.button={type=.MOUSE_BUTTON_DOWN,button=sdl.BUTTON_RIGHT,down=true,clicks=1,x=120,y=80}
    push(t,&event)
    event={};event.motion={type=.MOUSE_MOTION,x=130,y=85,xrel=10,yrel=5}
    push(t,&event)
    event={};event.wheel={type=.MOUSE_WHEEL,x=0,y=-1}
    push(t,&event)
    event={};event.drop={type=.DROP_FILE,data="C:/models/ship.glb"}
    push(t,&event)
    event={};event.window={type=.WINDOW_CLOSE_REQUESTED}
    push(t,&event)
    frame_begin(p)
    testing.expect(t,f.keys_down==Keys{.W,.Enter} && f.keys_pressed==Keys{.W,.Enter} && f.keys_repeated==Keys{.W,.Enter})
    text:=input_text(p)
    testing.expect(t,len(text)==2 && text[0]=='w' && text[1]=='é')
    testing.expect(t,f.mouse_down==Mouse_Buttons{.Right} && f.mouse_pressed==Mouse_Buttons{.Right})
    testing.expect_value(t,f.mouse_position,[2]f32{130,85})
    testing.expect_value(t,f.mouse_delta,[2]f32{10,5})
    testing.expect_value(t,f.wheel,[2]f32{0,-1})
    testing.expect_value(t,f.drop_count,1)
    testing.expect_value(t,input_dropped(p,0),"C:/models/ship.glb")
    testing.expect(t,f.window.close_requested)
    testing.expect_value(t,len(input_events(p)),10)
    // Injected events share the frame with those of the window system.
    event={};event.key={type=.KEY_UP,scancode=.W,down=false}
    push(t,&event)
    testing.expect(t,input_inject(p,Key_Event{key=.Q,down=true}))
    frame_begin(p)
    testing.expect(t,f.keys_down==Keys{.Enter,.Q} && f.keys_released==Keys{.W} && f.keys_pressed==Keys{.Q})
    testing.expect(t,!f.window.close_requested)
    tick:=input_tick_take(p)
    testing.expect(t,tick.keys_pressed==Keys{.W,.Enter,.Q} && tick.keys_released==Keys{.W} && tick.mouse_pressed==Mouse_Buttons{.Right})
    testing.expect_value(t,tick.mouse_delta,[2]f32{10,5})
    // QUIT asks the application to close the same way the window does.
    event={};event.quit={type=.QUIT}
    push(t,&event)
    frame_begin(p)
    testing.expect(t,f.window.close_requested)

    window_set_size(p,{1024,640})
    frame_begin(p)
    testing.expect_value(t,f.window.size,[2]i32{1024,640})
    testing.expect(t,f.window.resized)
    frame_begin(p)
    testing.expect(t,!f.window.resized)

    // The dummy driver keeps the clipboard inside SDL: the system one is not touched.
    testing.expect(t,clipboard_set(p,"copied text"))
    text_copy,ok:=clipboard_get(p)
    testing.expect(t,ok)
    testing.expect_value(t,text_copy,"copied text")

    window_set_cursor(p,.Text)
    window_set_cursor(p,.Hidden)
    window_set_cursor(p,.Default)
    testing.expect_value(t,window_cursor(p),Cursor.Default)
    window_set_relative_mouse(p,true)
    testing.expect(t,window_relative_mouse(p))
    window_set_relative_mouse(p,false)

    // Regions are answered from the size the window has now.
    testing.expect(t,window_set_regions(p,{{{0,0,1024,36},.Drag}}))
    testing.expect_value(t,window_hit_at(p,{500,20}),Window_Hit.Drag)
    testing.expect_value(t,window_hit_at(p,{1020,300}),Window_Hit.Resize_Right)
    source:=surface_source(p)
    testing.expect(t,source.vulkan_create!=nil && source.vulkan_user==rawptr(p))
    testing.expect(t,source.width==1024 && source.height==640)
    // No surface without a window flagged for it, and no Vulkan on the dummy driver.
    _,created:=vulkan_surface_create(nil,p)
    testing.expect(t,!created)
}

@(private="file")
sdl_events_beyond_the_capacity_still_change_the_state :: proc(t:^testing.T) {
    p:=test_windowed(t,{event_capacity=4})
    if p==nil {return}
    defer destroy(p)
    frame_begin(p)
    codes:=[?]sdl.Scancode{.A,.B,.C,.D,.E,.F}
    for code in codes {
        event:sdl.Event
        event.key={type=.KEY_DOWN,scancode=code,down=true}
        push(t,&event)
    }
    before:=stats(p).events_dropped
    frame_begin(p)
    testing.expect_value(t,len(input_events(p)),4)
    testing.expect(t,input_frame(p).keys_down==Keys{.A,.B,.C,.D,.E,.F})
    testing.expect_value(t,stats(p).events_dropped-before,u64(2))
}

@(private="file")
sdl_pen_pressure_reaches_the_frame_while_the_tip_touches :: proc(t:^testing.T) {
    p:=test_windowed(t)
    if p==nil {return}
    defer destroy(p)
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,f.pressure==1 && !f.eraser)
    event:sdl.Event
    event.paxis={type=.PEN_AXIS,axis=.PRESSURE,value=0} // hovering
    push(t,&event)
    event={};event.ptouch={type=.PEN_DOWN,eraser=true,down=true}
    push(t,&event)
    event={};event.paxis={type=.PEN_AXIS,pen_state={.DOWN,.ERASER_TIP},axis=.PRESSURE,value=0.25}
    push(t,&event)
    event={};event.paxis={type=.PEN_AXIS,pen_state={.DOWN,.ERASER_TIP},axis=.XTILT,value=40}
    push(t,&event)
    frame_begin(p)
    testing.expect(t,f.pressure==0.25 && f.eraser)
    testing.expect_value(t,len(input_events(p)),2)
    event={};event.ptouch={type=.PEN_UP}
    push(t,&event)
    frame_begin(p)
    testing.expect(t,f.pressure==1 && !f.eraser)
    // The pen that comes back is pressed as hard as it last said.
    event={};event.ptouch={type=.PEN_DOWN,down=true}
    push(t,&event)
    frame_begin(p)
    testing.expect(t,f.pressure==0.25 && !f.eraser)
    event={};event.ptouch={type=.PEN_UP}
    push(t,&event)
    event={};event.pproximity={type=.PEN_PROXIMITY_OUT}
    push(t,&event)
    event={};event.ptouch={type=.PEN_DOWN,down=true}
    push(t,&event)
    frame_begin(p)
    testing.expect_value(t,f.pressure,f32(1))
}

@(private="file")
Live_Test :: struct {p:^Platform,t:^testing.T,frames:int,size:[2]i32,dt:f32}

// The window system holds the event loop while a window is resized: the
// poll does not return. SDL still reports the window to a watcher, and a
// frame runs from there instead of waiting.
@(private="file")
sdl_live_frames_run_while_the_window_system_holds_the_poll :: proc(t:^testing.T) {
    p:=test_windowed(t,{window={size={800,600}}})
    if p==nil {return}
    defer destroy(p)
    live:=Live_Test{p=p,t=t}
    frame :: proc(user:rawptr) {
        live:=cast(^Live_Test)user
        live.frames+=1
        f:=input_frame(live.p)
        live.size=f.window.size;live.dt=f.dt
        // A live frame sees what is held and none of the edges of the frame being polled.
        testing.expect(live.t,f.keys_down==Keys{.A} && f.keys_pressed=={})
        testing.expect_value(live.t,len(input_events(live.p)),0)
        // What the window reports while a frame runs does not start another inside it.
        event:sdl.Event
        event.window={type=.WINDOW_EXPOSED}
        _=sdl.PushEvent(&event)
    }
    event:sdl.Event
    event.key={type=.KEY_DOWN,scancode=.A,down=true}
    push(t,&event)
    frame_begin(p)
    testing.expect(t,input_frame(p).keys_pressed==Keys{.A})
    set_live_frame(p,frame,&live)
    exposed:sdl.Event
    exposed.window={type=.WINDOW_EXPOSED}
    // Outside a poll, and in one that has only just begun, the loop is not held.
    push(t,&exposed)
    p.live.poll_start=clock_ns()
    push(t,&exposed)
    testing.expect_value(t,live.frames,0)
    // A poll that has not returned for a while is held: the frame runs from the watcher.
    p.live.poll_start=clock_ns()-2*POLL_HELD_NS
    p.clock.last=p.live.poll_start
    _=sdl.SetWindowSize(p.window.handle,900,650)
    push(t,&exposed)
    testing.expect_value(t,live.frames,1)
    testing.expect_value(t,live.size,[2]i32{900,650})
    testing.expect(t,live.dt>0)
    // A new size counts as well, once the last frame is not this very change.
    resized:sdl.Event
    resized.window={type=.WINDOW_RESIZED,data1=900,data2=650}
    p.clock.last=clock_ns()
    push(t,&resized)
    testing.expect_value(t,live.frames,1)
    p.clock.last=clock_ns()-2*LIVE_FRAME_NS
    push(t,&resized)
    testing.expect_value(t,live.frames,2)
    // Other events draw nothing.
    motion:sdl.Event
    motion.motion={type=.MOUSE_MOTION,x=10,y=10}
    push(t,&motion)
    testing.expect_value(t,live.frames,2)
    testing.expect_value(t,stats(p).live_frames,u64(2))
    p.live.poll_start=0
    // The events left in the queue draw nothing more, and the polled frame goes on.
    frame_begin(p)
    testing.expect_value(t,live.frames,2)
    testing.expect(t,!p.live.running)
    testing.expect_value(t,input_frame(p).window.size,[2]i32{900,650})
    // Without a live frame the watcher is gone.
    set_live_frame(p,nil,nil)
    p.live.poll_start=clock_ns()-2*POLL_HELD_NS
    p.clock.last=p.live.poll_start
    push(t,&exposed)
    testing.expect_value(t,live.frames,2)
    p.live.poll_start=0
}

@(private="file")
sdl_virtual_gamepad_connects_reports_and_disconnects :: proc(t:^testing.T) {
    // Only SDL's virtual joystick driver: devices plugged into this machine stay out of the test.
    hints:=[?]cstring{sdl.HINT_JOYSTICK_HIDAPI,sdl.HINT_JOYSTICK_RAWINPUT,sdl.HINT_XINPUT_ENABLED,sdl.HINT_JOYSTICK_DIRECTINPUT,sdl.HINT_JOYSTICK_WGI}
    for hint in hints {_=sdl.SetHint(hint,"0")}
    defer for hint in hints {_=sdl.ResetHint(hint)}
    p:=test_windowed(t,{gamepads=true})
    if p==nil {return}
    defer destroy(p)
    testing.expect(t,p.window.gamepad_events)
    frame_begin(p)
    f:=input_frame(p)
    for gamepad in f.gamepads {testing.expect(t,!gamepad.connected)}
    desc:sdl.VirtualJoystickDesc
    sdl.INIT_INTERFACE(&desc)
    desc.type=u16(sdl.JoystickType.GAMEPAD)
    desc.naxes=6;desc.nbuttons=15
    desc.name="Mirai test pad"
    id:=sdl.AttachVirtualJoystick(desc)
    testing.expect(t,id!=0)
    if id==0 {return}
    frame_begin(p)
    testing.expect(t,f.gamepads[0].connected)
    slot,known:=gamepad_slot(&p.window,id)
    testing.expect(t,known && slot==0)
    joystick:=sdl.GetGamepadJoystick(p.window.gamepads[0].handle)
    testing.expect(t,joystick!=nil)
    if joystick==nil {return}
    testing.expect(t,sdl.SetJoystickVirtualButton(joystick,i32(sdl.GamepadButton.SOUTH),true))
    testing.expect(t,sdl.SetJoystickVirtualButton(joystick,i32(sdl.GamepadButton.DPAD_LEFT),true))
    testing.expect(t,sdl.SetJoystickVirtualAxis(joystick,i32(sdl.GamepadAxis.LEFTX),-32768))
    testing.expect(t,sdl.SetJoystickVirtualAxis(joystick,i32(sdl.GamepadAxis.RIGHT_TRIGGER),32767))
    frame_begin(p)
    g:=&f.gamepads[0]
    testing.expect(t,g.down==Gamepad_Buttons{.South,.Dpad_Left} && g.pressed==Gamepad_Buttons{.South,.Dpad_Left})
    testing.expect_value(t,g.axes[.Left_X],f32(-1))
    testing.expect_value(t,g.axes[.Right_Trigger],f32(1))
    testing.expect(t,sdl.SetJoystickVirtualButton(joystick,i32(sdl.GamepadButton.SOUTH),false))
    frame_begin(p)
    testing.expect(t,g.down==Gamepad_Buttons{.Dpad_Left} && g.released==Gamepad_Buttons{.South} && g.pressed=={})
    tick:=input_tick_take(p)
    testing.expect(t,tick.gamepads[0].pressed==Gamepad_Buttons{.South,.Dpad_Left} && tick.gamepads[0].released==Gamepad_Buttons{.South})
    testing.expect(t,sdl.DetachVirtualJoystick(id))
    frame_begin(p)
    testing.expect(t,!g.connected && g.down=={} && g.released==Gamepad_Buttons{.Dpad_Left})
    _,known=gamepad_slot(&p.window,id)
    testing.expect(t,!known)
}

// Waits until the mixer clock has moved by frames, for a second at most.
@(private="file")
clock_advances :: proc(mixer:^audio.Mixer,frames:u64) -> bool {
    start:=audio.mixer_clock(mixer)
    deadline:=clock_ns()+1_000_000_000
    for clock_ns()<deadline {
        if audio.mixer_clock(mixer)-start>=frames {return true}
        sleep_coarse(2_000_000)
    }
    return false
}

// SDL's dummy audio driver plays to nowhere at the pace of a real device.
@(private="file")
sdl_audio_device_pulls_from_the_mixer :: proc(t:^testing.T) {
    mixer,mixer_error:=audio.mixer_create({channels=2})
    testing.expect_value(t,mixer_error,audio.Error.None)
    if mixer==nil {return}
    defer audio.mixer_destroy(mixer)
    p:=test_headless(t)
    // The device goes before the mixer: destroying the Platform closes it.
    defer destroy(p)
    testing.expect(t,!audio_device_is_open(p) && !audio_device_set_paused(p,true) && !audio_device_paused(p))
    testing.expect(t,audio_device_names(p,context.temp_allocator)==nil)
    switched,_:=audio_device_switch(p,"")
    testing.expect_value(t,switched,Audio_Error.Unavailable)
    // Headless there are no displays.
    testing.expect(t,display_names(p)==nil && window_display(p)==-1 && !window_set_display(p,0))
    testing.expect_value(t,audio_device_open(p,nil,{driver="dummy"}),Audio_Error.Device_Failed)
    testing.expect_value(t,audio_device_open(p,mixer,{driver="no-such-audio-driver"}),Audio_Error.Unavailable)
    testing.expect(t,!audio_device_is_open(p))
    testing.expect_value(t,audio_device_open(p,mixer,{driver="dummy",buffer_frames=256}),Audio_Error.None)
    testing.expect(t,audio_device_is_open(p) && !audio_device_paused(p))
    testing.expect_value(t,string(sdl.GetCurrentAudioDriver()),"dummy")
    testing.expect_value(t,audio_device_open(p,mixer,{driver="dummy"}),Audio_Error.Already_Open)
    // The audio thread asks for frames without anything else being done.
    testing.expect(t,clock_advances(mixer,4800),"The device did not pull from the mixer")
    device_stats:=audio_device_stats(p)
    testing.expect(t,device_stats.callbacks>0 && device_stats.frames>=4800)
    testing.expect(t,device_stats.frames<=audio.mixer_clock(mixer))
    // What the game thread plays reaches the mixer while the device runs.
    samples:[256]f32
    sound,_:=audio.sound_create(mixer,samples[:],2,48000)
    voice:=audio.voice_play(mixer,sound)
    testing.expect(t,voice!=0)
    testing.expect(t,clock_advances(mixer,2400))
    audio.mixer_update(mixer)
    testing.expect(t,!audio.voice_valid(mixer,voice))
    testing.expect_value(t,audio.mixer_stats(mixer).voices_played,u64(1))
    // Paused, the mixer stands still.
    testing.expect(t,audio_device_set_paused(p,true) && audio_device_paused(p))
    sleep_coarse(60_000_000)
    testing.expect(t,!clock_advances(mixer,48000/4),"A paused device kept pulling")
    testing.expect(t,audio_device_set_paused(p,false) && !audio_device_paused(p))
    testing.expect(t,clock_advances(mixer,2400))
    // Closed, nothing calls the mixer any more; it can be opened again.
    audio_device_close(p)
    testing.expect(t,!audio_device_is_open(p))
    closed_at:=audio.mixer_clock(mixer)
    sleep_coarse(60_000_000)
    testing.expect_value(t,audio.mixer_clock(mixer),closed_at)
    audio_device_close(p)
    testing.expect_value(t,audio_device_open(p,mixer,{driver="dummy"}),Audio_Error.None)
    testing.expect(t,clock_advances(mixer,2400))
    // Another output by its name; one the system does not list plays to the
    // default. The mixer goes on from where it was.
    for name in audio_device_names(p,context.temp_allocator) {
        error,found:=audio_device_switch(p,name)
        testing.expect(t,error==.None && found,name)
    }
    error,found:=audio_device_switch(p,"no such output")
    testing.expect(t,error==.None && !found && audio_device_is_open(p))
    testing.expect(t,clock_advances(mixer,2400))
    audio_device_close(p)
    testing.expect_value(t,audio_device_open(p,mixer,{driver="dummy",device="no such output"}),Audio_Error.None)
    testing.expect(t,clock_advances(mixer,2400))
    // An output of 44.1 kHz plays the mixer on headphones as on any other: the stream converts it.
    // The output runs at the rate of what opened it first.
    audio_device_close(p)
    testing.expect(t,sdl.SetHint(sdl.HINT_AUDIO_DRIVER,"dummy") && sdl.InitSubSystem({.AUDIO}))
    other:=sdl.AudioSpec{format=.F32,channels=2,freq=44100}
    first:=sdl.OpenAudioDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK,&other)
    defer {sdl.CloseAudioDevice(first);sdl.QuitSubSystem({.AUDIO})}
    testing.expect(t,audio.mixer_set_output(mixer,.Headphones) && audio.mixer_output(mixer)==.Headphones)
    testing.expect_value(t,audio_device_open(p,mixer,{driver="dummy"}),Audio_Error.None)
    played,device:sdl.AudioSpec
    testing.expect(t,sdl.GetAudioStreamFormat(p.audio.stream,&played,nil) && sdl.GetAudioDeviceFormat(sdl.GetAudioStreamDevice(p.audio.stream),&device,nil))
    testing.expectf(t,played.freq==audio.MIXER_RATE && device.freq==44100,"the mixer at %d Hz into a device of %d Hz",played.freq,device.freq)
    testing.expect(t,clock_advances(mixer,2400) && audio.mixer_output(mixer)==.Headphones)
}
