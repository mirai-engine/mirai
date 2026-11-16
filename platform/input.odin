package platform

import si "mirai:std/input"

// Input of the application as flat data. Every event, from the window system
// or injected, goes through input_apply, which keeps two views of it: the
// frame (UI and editor) and the fixed tick (gameplay).

Key :: si.Key
Keys :: si.Keys
Mouse_Button :: si.Mouse_Button
Mouse_Buttons :: si.Mouse_Buttons
GAMEPAD_CAPACITY :: si.GAMEPAD_CAPACITY
Gamepad_Button :: si.Gamepad_Button
Gamepad_Buttons :: si.Gamepad_Buttons
Gamepad_Axis :: si.Gamepad_Axis
Gamepad_State :: si.Gamepad
Gamepad_Family :: si.Gamepad_Family
Device :: si.Device

Key_Event :: struct {key:Key,down:bool,repeat:bool}
Text_Event :: struct {codepoint:rune}
// delta is what the device moved; left at zero it is the distance from the previous position.
Mouse_Motion_Event :: struct {position,delta:[2]f32}
Mouse_Button_Event :: struct {button:Mouse_Button,down:bool,clicks:u8,position:[2]f32}
Mouse_Wheel_Event :: struct {delta:[2]f32}
Gamepad_Device_Event :: struct {gamepad:u8,connected:bool,family:Gamepad_Family}
Gamepad_Button_Event :: struct {gamepad:u8,button:Gamepad_Button,down:bool}
Gamepad_Axis_Event :: struct {gamepad:u8,axis:Gamepad_Axis,value:f32}
Window_Event_Kind :: enum u8 {
    Resized,Close_Requested,Focus_Gained,Focus_Lost,Mouse_Entered,Mouse_Left,
    Minimized,Maximized,Restored,Fullscreen_Entered,Fullscreen_Left,Shown,Hidden,
}
// size and pixel_size belong to Resized; a zero pixel_size is the size times the density.
Window_Event :: struct {kind:Window_Event_Kind,size,pixel_size:[2]i32}
// A file dropped on the window; its path is input_dropped(index). position:
// where on the window it fell, in points; MOUSE_OUTSIDE when not known.
Drop_Event :: struct {index:u16,position:[2]f32}
// The tip of a tablet pen: down while it touches, with the eraser end or not;
// pressure from 0 to 1. Where it is comes with the mouse events of the system.
Pen_Event :: struct {down,eraser:bool,pressure:f32}

Input_Event :: union {
    Key_Event,Text_Event,Mouse_Motion_Event,Mouse_Button_Event,Mouse_Wheel_Event,
    Gamepad_Device_Event,Gamepad_Button_Event,Gamepad_Axis_Event,Window_Event,Drop_Event,Pen_Event,
}

TEXT_CAPACITY :: 64
// What makes a device the one used last: the mouse moves this many points in
// one event; a stick or a trigger goes past this part of its travel.
DEVICE_MOTION :: f32(2)
DEVICE_AXIS :: f32(0.5)
// Position of a pointer that is outside the window: nothing is under it.
MOUSE_OUTSIDE :: [2]f32{-100000,-100000}

Window_Frame :: struct {
    size:[2]i32,       // points: what the UI lays out and hit tests in
    pixel_size:[2]i32, // drawable pixels
    density:f32,       // device pixels per UI point
    pixel_density:f32, // device pixels per native window coordinate
    focused,minimized,maximized,fullscreen,visible:bool,
    resized,focus_gained,focus_lost,close_requested:bool, // true for the frame in which it happened
}

// The input of one drawn frame. pressed, released, repeated, clicks, deltas,
// wheel, text and the window edges describe this frame alone.
Input_Frame :: struct {
    index:u64,
    dt:f32, // seconds since the previous frame, at most FRAME_DT_MAX
    keys_down,keys_pressed,keys_released:Keys,
    keys_repeated:Keys, // pressed this frame, including keyboard auto-repeat (text editing)
    mouse_down,mouse_pressed,mouse_released:Mouse_Buttons,
    mouse_clicks:[Mouse_Button]u8, // clicks the system counted for this frame's press: 2 on a double click
    mouse_inside:bool,
    mouse_position:[2]f32, // window points, origin at the top left; MOUSE_OUTSIDE when not inside
    mouse_delta:[2]f32,
    wheel:[2]f32, // steps; y positive away from the user
    pressure:f32, // of the pen tip while it touches, 0 to 1; 1 with the mouse or without a pen
    eraser:bool,  // the eraser end of the pen touches
    text:[TEXT_CAPACITY]rune,text_count:int,
    gamepads:[GAMEPAD_CAPACITY]Gamepad_State,
    device:Device, // used last: DEVICE_MOTION and DEVICE_AXIS say what counts
    window:Window_Frame,
    drop_count:int,
    // Of this frame: events that did not fit in the list (stats.events_dropped
    // counts them all) and characters that did not fit in text.
    events_dropped,text_dropped:int,
}

// The input of one fixed tick. pressed and released are true for the single
// tick that follows the change, however many frames were drawn meanwhile;
// mouse_delta and wheel are what accumulated since the previous tick.
Input_Tick :: struct {
    keys_down,keys_pressed,keys_released:Keys,
    mouse_down,mouse_pressed,mouse_released:Mouse_Buttons,
    mouse_position,mouse_delta:[2]f32,
    wheel:[2]f32,
    pressure:f32,eraser:bool, // as in Input_Frame
    gamepads:[GAMEPAD_CAPACITY]Gamepad_State,
    window_size:[2]f32,
    device:Device,
}

@(private)
Drop_Path :: struct {offset,length:u32}
@(private)
Drop_Store :: struct {bytes:[]u8,used:int,paths:[]Drop_Path,count:int}
@(private)
Input :: struct {
    frame:Input_Frame,
    live:Input_Frame, // what a live frame sees: the state of frame without its edges
    tick:Input_Tick,  // edges and deltas not yet taken by a tick
    events:[]Input_Event,event_count:int,
    pending:[]Input_Event,pending_count:int, // injected, applied by the next frame
    // Paths dropped in the current frame, and those injected for the next one.
    drops:[2]Drop_Store,drop_active:int,
}

// The frame being drawn. The pointer stays valid for the life of the Platform.
input_frame :: proc(p:^Platform) -> ^Input_Frame {
    return &p.input.live if p.live.running else &p.input.frame
}
// The events of the frame in the order they happened. Events beyond the
// capacity are missing from this list but not from the state.
input_events :: proc(p:^Platform) -> []Input_Event {
    if p.live.running {return nil}
    return p.input.events[:p.input.event_count]
}
input_text :: proc(p:^Platform) -> []rune {
    frame:=input_frame(p)
    return frame.text[:frame.text_count]
}
// Path of a file dropped in this frame; valid until the next frame begins.
input_dropped :: proc(p:^Platform,index:int) -> string {
    store:=&p.input.drops[p.input.drop_active]
    if p.live.running || index<0 || index>=store.count {return ""}
    path:=store.paths[index]
    return string(store.bytes[path.offset:][:path.length])
}

// Hands the accumulated edges and deltas to one fixed tick and starts over.
// A tick that runs later in the same frame sees none of them. A paused
// simulation takes and discards them so they are not replayed on resume.
input_tick_take :: proc(p:^Platform) -> Input_Tick {
    f:=&p.input.frame;t:=&p.input.tick
    t.keys_down=f.keys_down;t.mouse_down=f.mouse_down;t.mouse_position=f.mouse_position
    t.pressure,t.eraser=f.pressure,f.eraser
    t.window_size={f32(f.window.size.x),f32(f.window.size.y)}
    t.device=f.device
    for &g,i in t.gamepads {
        g.connected=f.gamepads[i].connected;g.down=f.gamepads[i].down;g.axes=f.gamepads[i].axes;g.family=f.gamepads[i].family
    }
    result:=t^
    t.keys_pressed={};t.keys_released={};t.mouse_pressed={};t.mouse_released={}
    t.mouse_delta={};t.wheel={}
    for &g in t.gamepads {g.pressed={};g.released={}}
    return result
}

// Queues a synthetic event for the next frame, where it goes through the same
// path as the events of the window system. False when the queue is full.
input_inject :: proc(p:^Platform,event:Input_Event) -> bool {
    s:=&p.input
    if _,is_drop:=event.(Drop_Event);is_drop || event==nil {return false}
    if s.pending_count>=len(s.pending) {p.stats.injected_dropped+=1;return false}
    s.pending[s.pending_count]=event;s.pending_count+=1
    return true
}
input_inject_text :: proc(p:^Platform,text:string) -> bool {
    for codepoint in text {
        if !input_inject(p,Text_Event{codepoint}) {return false}
    }
    return true
}
input_inject_drop :: proc(p:^Platform,path:string,position:=MOUSE_OUTSIDE) -> bool {
    s:=&p.input
    if s.pending_count>=len(s.pending) {p.stats.injected_dropped+=1;return false}
    index,ok:=drop_store(p,&s.drops[1-s.drop_active],path)
    if !ok {return false}
    s.pending[s.pending_count]=Drop_Event{index,position};s.pending_count+=1
    return true
}

@(private)
drop_store :: proc(p:^Platform,store:^Drop_Store,path:string) -> (index:u16,ok:bool) {
    if store.count>=len(store.paths) || store.used+len(path)>len(store.bytes) {p.stats.drops_dropped+=1;return 0,false}
    copy(store.bytes[store.used:],path)
    store.paths[store.count]={u32(store.used),u32(len(path))}
    store.used+=len(path);store.count+=1
    return u16(store.count-1),true
}

// Clears what belongs to one frame and makes the drops injected since the
// last frame the drops of this one.
@(private)
input_frame_reset :: proc(p:^Platform) {
    s:=&p.input;f:=&s.frame
    f.keys_pressed={};f.keys_released={};f.keys_repeated={}
    f.mouse_pressed={};f.mouse_released={};f.mouse_clicks={}
    f.mouse_delta={};f.wheel={};f.text_count=0
    f.events_dropped,f.text_dropped=0,0
    for &g in f.gamepads {g.pressed={};g.released={}}
    f.window.resized=false;f.window.focus_gained=false;f.window.focus_lost=false;f.window.close_requested=false
    s.event_count=0
    s.drop_active=1-s.drop_active
    injected:=&s.drops[1-s.drop_active];injected.used=0;injected.count=0
    f.drop_count=s.drops[s.drop_active].count
}

@(private)
input_apply :: proc(p:^Platform,event:Input_Event) {
    s:=&p.input;f:=&s.frame;t:=&s.tick
    switch e in event {
    case Key_Event:
        if e.down {
            f.device={}
            f.keys_repeated+={e.key}
            if !e.repeat {f.keys_pressed+={e.key};t.keys_pressed+={e.key}}
            f.keys_down+={e.key}
        } else if e.key in f.keys_down {
            f.keys_down-={e.key};f.keys_released+={e.key};t.keys_released+={e.key}
        }
    case Text_Event:
        if f.text_count>=TEXT_CAPACITY {p.stats.text_dropped+=1;f.text_dropped+=1;return}
        f.text[f.text_count]=e.codepoint;f.text_count+=1
    case Mouse_Motion_Event:
        delta:=e.delta
        if delta=={} && f.mouse_inside {delta=e.position-f.mouse_position}
        f.mouse_position=e.position;f.mouse_inside=true
        f.mouse_delta+=delta;t.mouse_delta+=delta
        if delta.x*delta.x+delta.y*delta.y>=DEVICE_MOTION*DEVICE_MOTION {f.device={}}
    case Mouse_Button_Event:
        // A click can arrive with no motion before it (a tap, automation): it
        // happens where it says, not where the pointer was last seen.
        if f.mouse_inside && !p.window.relative_mouse {
            delta:=e.position-f.mouse_position
            f.mouse_delta+=delta;t.mouse_delta+=delta
        }
        f.mouse_position=e.position;f.mouse_inside=true
        if e.down {
            f.device={}
            f.mouse_down+={e.button};f.mouse_pressed+={e.button};t.mouse_pressed+={e.button}
            f.mouse_clicks[e.button]=max(e.clicks,1)
        } else if e.button in f.mouse_down {
            f.mouse_down-={e.button};f.mouse_released+={e.button};t.mouse_released+={e.button}
        }
    case Mouse_Wheel_Event:
        f.wheel+=e.delta;t.wheel+=e.delta
        if e.delta!={} {f.device={}}
    case Gamepad_Device_Event:
        if int(e.gamepad)>=GAMEPAD_CAPACITY {return}
        g:=&f.gamepads[e.gamepad]
        if e.connected {
            g.connected,g.family=true,e.family
        } else {
            // What was held is let go with the device.
            g.released+=g.down;t.gamepads[e.gamepad].released+=g.down
            g.down={};g.axes={};g.connected=false
            if f.device==(Device{gamepad=true,slot=e.gamepad}) {f.device={}}
        }
    case Gamepad_Button_Event:
        if int(e.gamepad)>=GAMEPAD_CAPACITY || !f.gamepads[e.gamepad].connected {return}
        g:=&f.gamepads[e.gamepad]
        if e.down {
            if e.button not_in g.down {g.pressed+={e.button};t.gamepads[e.gamepad].pressed+={e.button}}
            g.down+={e.button}
            f.device={gamepad=true,slot=e.gamepad}
        } else if e.button in g.down {
            g.down-={e.button};g.released+={e.button};t.gamepads[e.gamepad].released+={e.button}
        }
    case Gamepad_Axis_Event:
        if int(e.gamepad)>=GAMEPAD_CAPACITY || !f.gamepads[e.gamepad].connected {return}
        f.gamepads[e.gamepad].axes[e.axis]=clamp(e.value,-1,1)
        if abs(e.value)>=DEVICE_AXIS {f.device={gamepad=true,slot=e.gamepad}}
    case Window_Event:
        w:=&f.window
        switch e.kind {
        case .Resized:
            w.size=e.size
            w.pixel_size=e.pixel_size
            if e.pixel_size=={} {w.pixel_size={i32(f32(e.size.x)*w.density+0.5),i32(f32(e.size.y)*w.density+0.5)}}
        case .Close_Requested:w.close_requested=true
        case .Focus_Gained:w.focused=true;w.focus_gained=true
        case .Focus_Lost:w.focused=false;w.focus_lost=true
        // Where the pointer entered is known with its first motion.
        case .Mouse_Entered:
        // Nothing stays lit under a pointer that left; a drag keeps its place.
        case .Mouse_Left:if f.mouse_down=={} {f.mouse_inside=false;f.mouse_position=MOUSE_OUTSIDE}
        case .Minimized:w.minimized=true
        case .Maximized:w.maximized=true;w.minimized=false
        case .Restored:w.minimized=false;w.maximized=false
        case .Fullscreen_Entered:w.fullscreen=true
        case .Fullscreen_Left:w.fullscreen=false
        case .Shown:w.visible=true
        case .Hidden:w.visible=false
        }
    case Drop_Event:
    case Pen_Event:
        f.pressure,f.eraser=1,false
        if e.down {f.pressure,f.eraser=clamp(e.pressure,0,1),e.eraser}
    }
    if s.event_count>=len(s.events) {p.stats.events_dropped+=1;s.frame.events_dropped+=1;return}
    s.events[s.event_count]=event;s.event_count+=1
}
