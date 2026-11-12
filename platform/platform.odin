package platform

import "base:runtime"
import sdl "vendor:sdl3"

// The operating system layer: window, input, clock and frame pacing,
// clipboard and dialogs, file watching, paths and the audio
// device. It knows nothing of the editor, the renderer or the world. A Platform belongs to the thread that created it; a windowed one
// must be created on the main thread, and a process holds at most one.

Error :: enum u8 {
    None,
    Out_Of_Memory,
    Video_Unavailable, // the window system could not be initialized
    Window_Failed,
    Surface_Failed,    // the window has no layer for the GPU backend
}

Platform_Desc :: struct {
    // No window and no window system: tests, servers, the headless editor.
    // Input is what gets injected and the window is the size given in window.
    headless:bool,
    window:Window_Desc,
    video_driver:string, // SDL video driver; "" lets SDL choose, "dummy" opens no real window
    gamepads:bool,       // windowed only
    pacing:Maybe(Frame_Pacing), // FRAME_PACING_DEFAULT when nil
    fixed_dt:f32,        // >0: every frame lasts this long whatever the clock says (deterministic runs)
    event_capacity:int,  // events listed per frame, and injected events queued for the next one; 256 when zero
    drop_capacity:int,   // dropped files per frame; 16 when zero
    drop_bytes:int,      // bytes of their paths; 8192 when zero
    region_capacity:int, // window regions; 1024 when zero
    clipboard_bytes:int, // headless clipboard; 65536 when zero
    watch_capacity:int,   // 8 when zero
    allocator:runtime.Allocator, // context.allocator when unset
}

// Counters since creation. The *_dropped and *_exhausted ones count requests
// that a capacity of the desc could not hold.
Stats :: struct {
    frames:u64,
    live_frames:u64,
    paced_ns:u64, // time slept by frame_end
    events_dropped:u64,
    injected_dropped:u64,
    text_dropped:u64,
    drops_dropped:u64,
    regions_dropped:u64,
    gamepads_ignored:u64,
    watches_exhausted:u64,
}

@(private)
Live_Frame :: struct {
    frame:proc(user:rawptr),
    user:rawptr,
    running:bool,
    watching:bool,
    poll_start:u64, // 0 outside the event pump
}

TITLE_CAPACITY :: 256

Platform :: struct {
    allocator:runtime.Allocator,
    headless:bool,
    stats:Stats,
    input:Input,
    clock:Frame_Clock,
    pacing:Frame_Pacing,
    background:u32, // frames per second at most while the window has no focus; 0: as with it
    fixed_dt:f32,
    window:Window,
    live:Live_Frame,
    frame_context:runtime.Context, // context of the last frame_begin, for what SDL calls back during the pump
    title:[TITLE_CAPACITY]u8,title_length:int,
    clipboard:[]u8,clipboard_length:int,
    dialog:Dialog,
    watches:Watch_Table,
    audio:Audio_Device,
}

create :: proc(desc:Platform_Desc) -> (p:^Platform,error:Error) {
    allocator:=desc.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    allocation_error:runtime.Allocator_Error
    p,allocation_error=new(Platform,allocator)
    if allocation_error!=nil {return nil,.Out_Of_Memory}
    p.allocator=allocator
    if error=platform_init(p,desc);error!=.None {
        destroy(p)
        return nil,error
    }
    return p,.None
}
@(private)
platform_init :: proc(p:^Platform,desc:Platform_Desc) -> Error {
    allocator:=p.allocator
    p.headless=desc.headless
    p.frame_context=context
    p.pacing=desc.pacing.? or_else FRAME_PACING_DEFAULT
    p.fixed_dt=desc.fixed_dt

    events:=desc.event_capacity if desc.event_capacity>0 else 256
    drops:=desc.drop_capacity if desc.drop_capacity>0 else 16
    drop_bytes:=desc.drop_bytes if desc.drop_bytes>0 else 8192
    s:=&p.input
    failed:runtime.Allocator_Error
    if s.events,failed=make([]Input_Event,events,allocator);failed!=nil {return .Out_Of_Memory}
    if s.pending,failed=make([]Input_Event,events,allocator);failed!=nil {return .Out_Of_Memory}
    for &store in s.drops {
        if store.bytes,failed=make([]u8,drop_bytes,allocator);failed!=nil {return .Out_Of_Memory}
        if store.paths,failed=make([]Drop_Path,drops,allocator);failed!=nil {return .Out_Of_Memory}
    }
    if p.window.regions,failed=make([]Window_Region,desc.region_capacity if desc.region_capacity>0 else 1024,allocator);failed!=nil {return .Out_Of_Memory}
    if !watch_table_init(p,desc.watch_capacity if desc.watch_capacity>0 else 8) {return .Out_Of_Memory}

    f:=&s.frame
    f.mouse_position=MOUSE_OUTSIDE
    f.pressure=1
    f.window.density=1
    f.window.pixel_density=1
    p.window.resizable=true
    title_store(p,desc.window.title)
    if desc.headless {
        if p.clipboard,failed=make([]u8,desc.clipboard_bytes if desc.clipboard_bytes>0 else 65536,allocator);failed!=nil {return .Out_Of_Memory}
        size:=desc.window.size
        if size.x<=0 || size.y<=0 {size=WINDOW_SIZE_DEFAULT}
        if desc.window.density>0 {f.window.density=desc.window.density}
        f.window.pixel_density=f.window.density
        f.window.size=size
        f.window.pixel_size={i32(f32(size.x)*f.window.density+0.5),i32(f32(size.y)*f.window.density+0.5)}
        f.window.focused=true
        f.window.visible=!desc.window.hidden
        f.window.maximized=desc.window.maximized
        f.window.fullscreen=desc.window.fullscreen
    } else {
        window_open(p,desc) or_return
        window_refresh(p,&f.window)
    }
    p.clock.last=clock_ns();p.clock.pace_target=p.clock.last
    return .None
}

// Gives a headless Platform the window desc describes, from the next frame
// on; its title is the one the Platform has. Injected input and the clipboard
// go on, the latter now that of the system. On an error it stays headless.
window_attach :: proc(p:^Platform,window:Window_Desc) -> Error {
    if !p.headless {return .None}
    desc:=Platform_Desc{window=window}
    desc.window.title=window_title(p)
    if error:=window_open(p,desc);error!=.None {
        window_close(p)
        return error
    }
    p.headless=false
    _=sdl.RaiseWindow(p.window.handle)
    window_refresh(p,&p.input.frame.window)
    if p.live.frame!=nil {window_watch_live(p,true)}
    return .None
}

// Closes the window window_attach gave: the Platform is headless again.
window_detach :: proc(p:^Platform) {
    if p.headless {return}
    window_close(p)
    p.headless=true
}

destroy :: proc(p:^Platform) {
    if p==nil {return}
    audio_device_close(p)
    watch_table_destroy(p)
    dialog_abandon(p)
    if !p.headless {window_close(p)}
    allocator:=p.allocator
    delete(p.input.events,allocator);delete(p.input.pending,allocator)
    for store in p.input.drops {delete(store.bytes,allocator);delete(store.paths,allocator)}
    delete(p.window.regions,allocator)
    delete(p.clipboard,allocator)
    free(p,allocator)
}

stats :: proc(p:^Platform) -> Stats {return p.stats}

// Starts a frame: gathers the events of the window system and those injected
// since the last frame, and measures the time since it.
frame_begin :: proc(p:^Platform) {
    p.frame_context=context
    input_frame_reset(p)
    s:=&p.input;f:=&s.frame
    previous_size,previous_pixels:=f.window.size,f.window.pixel_size
    now:=clock_ns()
    f.dt=frame_clock_dt(p,now,p.clock.shown)
    p.clock.last=now
    if !p.headless {
        window_rect_apply(&p.window)
        window_pump(p,now)
    } else if p.audio.subsystem {
        audio_device_pump(p)
    }
    for i in 0..<s.pending_count {input_apply(p,s.pending[i])}
    s.pending_count=0
    if !p.headless {window_refresh(p,&f.window)}
    f.window.resized=f.window.size!=previous_size || f.window.pixel_size!=previous_pixels
    f.drop_count=s.drops[s.drop_active].count
    dialog_collect(p)
    f.index=p.stats.frames;p.stats.frames+=1
}

// While an edge or the bar of the window is dragged, the window system may
// keep the event loop to itself: frame_begin does not return until the
// button is released, and nothing would be drawn at the sizes in between.
// The frame given here runs from inside that wait. It sees the current
// window and no input edges, and must not call frame_begin or frame_end.
set_live_frame :: proc(p:^Platform,frame:proc(user:rawptr),user:rawptr) {
    p.live.frame=frame;p.live.user=user
    if !p.headless {window_watch_live(p,frame!=nil)}
}
