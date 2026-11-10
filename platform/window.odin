package platform

import "core:c"
import "core:strings"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// System: the decorations of the window system. Custom: a borderless window
// whose bar the application draws; it tells the platform every frame which
// rectangles move the window (window_set_regions) and the platform turns
// them, and the edges, into native dragging and resizing.
Window_Chrome :: enum u8 {System,Custom}

Window_Desc :: struct {
    title:string,
    version,identifier:string, // of the application with the title, as the system names it (SDL_SetAppMetadata); empty: none
    size:[2]i32,         // points; WINDOW_SIZE_DEFAULT when zero
    minimum_size:[2]i32, // WINDOW_MINIMUM_SIZE_DEFAULT when zero
    chrome:Window_Chrome,
    fixed_size:bool,
    hidden:bool, // created without being shown; window_show shows it. Otherwise it appears with the first presented frame
    maximized,fullscreen:bool,
    no_surface:bool, // no Vulkan or Metal support: SDL's dummy driver has none
    density:f32, // headless: pixels per point, 1 when zero
    rect:[4]i32, // x, y, width and height in screen coordinates, the frame of the system included; zero: centered at size
}
WINDOW_SIZE_DEFAULT :: [2]i32{1440,900}
WINDOW_MINIMUM_SIZE_DEFAULT :: [2]i32{640,400}

// Where the caption buttons of a custom chrome go on this system.
Window_Controls :: enum u8 {Right,Left_Traffic_Lights}
WINDOW_CONTROLS :: Window_Controls.Left_Traffic_Lights when ODIN_OS==.Darwin else Window_Controls.Right

Rect :: struct {x,y,w,h:f32} // window points

Window_Region_Kind :: enum u8 {
    Client,  // ordinary input, even at the edge of the window
    Control, // a caption button: ordinary input, but its outermost WINDOW_CONTROL_RESIZE points still resize
    Drag,    // moves the window; the window system maximizes it on a double click
}
Window_Region :: struct {rect:Rect,kind:Window_Region_Kind}

// Points from the edge that resize a custom window, independent of the density.
WINDOW_RESIZE_MARGIN :: 10
WINDOW_RESIZE_CORNER :: 24
WINDOW_CONTROL_RESIZE :: 4

// Same order as sdl.HitTestResult.
Window_Hit :: enum u8 {
    Client,Drag,
    Resize_Top_Left,Resize_Top,Resize_Top_Right,Resize_Right,
    Resize_Bottom_Right,Resize_Bottom,Resize_Bottom_Left,Resize_Left,
}
#assert(int(Window_Hit.Drag)==int(sdl.HitTestResult.DRAGGABLE))
#assert(int(Window_Hit.Resize_Left)==int(sdl.HitTestResult.RESIZE_LEFT))

Cursor :: enum u8 {
    Default,Text,Pointer,Crosshair,Move,
    Resize_Horizontal,Resize_Vertical,Resize_Diagonal_Down,Resize_Diagonal_Up, // down: from the top left to the bottom right
    Not_Allowed,Wait,Progress,
    Hidden,
}

// What a GPU backend needs to present to the window, without knowing SDL:
// Vulkan calls vulkan_create(instance,vulkan_user) for a VkSurfaceKHR; Metal
// takes the CAMetalLayer.
Surface_Source :: struct {
    vulkan_create:proc(instance:rawptr,user:rawptr) -> (surface:u64,ok:bool),
    vulkan_user:rawptr,
    metal_layer:rawptr,
    width,height:u32, // drawable pixels
}

// Manual resize of a window whose system ignores the resize regions (macOS).
@(private)
Window_Resize :: struct {
    hit:sdl.HitTestResult,
    rect:sdl.Rect,
    mouse:[2]f32,
    minimum:[2]i32,
    time:f64,
}
@(private)
Gamepad_Slot :: struct {id:sdl.JoystickID,handle:^sdl.Gamepad}
@(private)
Window :: struct {
    handle:^sdl.Window,
    rect:[4]i32,     // asked for in the desc, until the frame of the system is known
    rect_tries:int,
    video,gamepad_events:bool, // SDL subsystems this Platform started
    driver_chosen:bool,        // the video driver hint is the one of the desc
    metal_view:sdl.MetalView,
    metal_layer:rawptr,
    chrome:Window_Chrome,
    fixed_size:bool,
    regions:[]Window_Region,region_count:int,
    resizable:bool, // as of the last window_set_regions
    cursors:[Cursor]^sdl.Cursor,
    cursor:Cursor,
    relative_mouse:bool,
    pen_pressure:f32, // the last one the pen in range reported; 1 until it reports one
    coordinate_scale:f32,
    minimum:[2]i32,
    refresh_hz:f32,
    gamepads:[GAMEPAD_CAPACITY]Gamepad_Slot,
    resize:Window_Resize,
    resize_input:bool,    // mouse events of this pump belong to a manual resize
    click_time:f64,
    toggle_maximize:bool, // asked from inside the hit test, done after the pump
    veil:int, // >0: shown at its size but kept off the screen, for at most this many frames that do not present
}

// A window appears with its first image instead of empty: the window system
// shows it, maximized or in full screen if asked, and the screen does not
// until a frame presents to it. An application that presents nothing in
// WINDOW_VEIL_FRAMES frames gets it on the screen anyway.
WINDOW_VEIL_FRAMES :: 120

// What a point of a custom window does. Client and Control regions go first,
// so widgets at the edge keep their clicks; then the edges resize; then Drag
// regions move the window.
window_hit :: proc(point:[2]f32,size:[2]i32,regions:[]Window_Region,resizable:bool) -> Window_Hit {
    x,y:=point.x,point.y
    width,height:=f32(size.x),f32(size.y)
    for region in regions {
        if region.kind==.Drag || !rect_contains(region.rect,point) {continue}
        if region.kind==.Control && resizable && (y<WINDOW_CONTROL_RESIZE || x<WINDOW_CONTROL_RESIZE || x>=width-WINDOW_CONTROL_RESIZE) {continue}
        return .Client
    }
    if resizable {
        left,right:=x<WINDOW_RESIZE_CORNER,x>=width-WINDOW_RESIZE_CORNER
        top,bottom:=y<WINDOW_RESIZE_CORNER,y>=height-WINDOW_RESIZE_CORNER
        if left && top {return .Resize_Top_Left}
        if right && top {return .Resize_Top_Right}
        if left && bottom {return .Resize_Bottom_Left}
        if right && bottom {return .Resize_Bottom_Right}
        if y<WINDOW_RESIZE_MARGIN {return .Resize_Top}
        if y>=height-WINDOW_RESIZE_MARGIN {return .Resize_Bottom}
        if x<WINDOW_RESIZE_MARGIN {return .Resize_Left}
        if x>=width-WINDOW_RESIZE_MARGIN {return .Resize_Right}
    }
    for region in regions {
        if region.kind==.Drag && rect_contains(region.rect,point) {return .Drag}
    }
    return .Client
}
rect_contains :: proc "contextless" (r:Rect,point:[2]f32) -> bool {
    return point.x>=r.x && point.x<r.x+r.w && point.y>=r.y && point.y<r.y+r.h
}

// Keeps the opposite edges where they are when the minimum size clamps a drag.
@(private)
window_resize_rect :: proc "contextless" (rect:sdl.Rect,hit:sdl.HitTestResult,delta:[2]f32,minimum:[2]i32) -> sdl.Rect {
    result:=rect
    left:=hit==.RESIZE_LEFT || hit==.RESIZE_TOPLEFT || hit==.RESIZE_BOTTOMLEFT
    right:=hit==.RESIZE_RIGHT || hit==.RESIZE_TOPRIGHT || hit==.RESIZE_BOTTOMRIGHT
    top:=hit==.RESIZE_TOP || hit==.RESIZE_TOPLEFT || hit==.RESIZE_TOPRIGHT
    bottom:=hit==.RESIZE_BOTTOM || hit==.RESIZE_BOTTOMLEFT || hit==.RESIZE_BOTTOMRIGHT
    if left {result.w=max(rect.w-i32(delta.x),minimum[0]);result.x=rect.x+rect.w-result.w}
    if right {result.w=max(rect.w+i32(delta.x),minimum[0])}
    if top {result.h=max(rect.h-i32(delta.y),minimum[1]);result.y=rect.y+rect.h-result.h}
    if bottom {result.h=max(rect.h+i32(delta.y),minimum[1])}
    return result
}

// The regions of a custom chrome for the frames that follow, in window
// points. resizable=false keeps the edges from resizing, for instance while
// the application is dragging something of its own. False when they do not
// fit in the region capacity: the rest are left out.
window_set_regions :: proc(p:^Platform,regions:[]Window_Region,resizable:=true) -> bool {
    w:=&p.window
    w.region_count=min(len(regions),len(w.regions))
    copy(w.regions,regions[:w.region_count])
    w.resizable=resizable
    if w.region_count<len(regions) {p.stats.regions_dropped+=u64(len(regions)-w.region_count);return false}
    return true
}
// What the window system is told about a point of the window right now.
window_hit_at :: proc(p:^Platform,point:[2]f32) -> Window_Hit {
    w:=&p.window;f:=&p.input.frame.window
    if w.chrome!=.Custom && !p.headless {return .Client}
    resizable:=w.resizable && !w.fixed_size && !f.maximized && !f.fullscreen
    return window_hit(point,f.size,w.regions[:w.region_count],resizable)
}

@(private)
window_open :: proc(p:^Platform,desc:Platform_Desc) -> Error {
    w:=&p.window
    w.pen_pressure=1
    // The application decides when the window closes: it may ask to save first.
    _=sdl.SetHint(sdl.HINT_QUIT_ON_LAST_WINDOW_CLOSE,"0")
    if desc.video_driver!="" {
        driver:=strings.clone_to_cstring(desc.video_driver,context.temp_allocator)
        _=sdl.SetHint(sdl.HINT_VIDEO_DRIVER,driver)
        w.driver_chosen=true
    }
    if desc.window.version!="" || desc.window.identifier!="" {
        _=sdl.SetAppMetadata(strings.clone_to_cstring(desc.window.title,context.temp_allocator),strings.clone_to_cstring(desc.window.version,context.temp_allocator),desc.window.identifier!=""?strings.clone_to_cstring(desc.window.identifier,context.temp_allocator):nil)
    }
    if !sdl.InitSubSystem({.VIDEO}) {return .Video_Unavailable}
    w.video=true
    if desc.gamepads {w.gamepad_events=sdl.InitSubSystem({.GAMEPAD})}
    // High density: on scaled displays the drawable has more pixels than the
    // window has points, so UI and text are drawn sharp instead of upscaled.
    flags:sdl.WindowFlags={.HIGH_PIXEL_DENSITY,.HIDDEN}
    if !desc.window.fixed_size {flags+={.RESIZABLE}}
    if desc.window.chrome==.Custom && (ODIN_OS!=.Darwin || desc.window.no_surface) {flags+={.BORDERLESS}}
    if desc.window.maximized {flags+={.MAXIMIZED}}
    if desc.window.fullscreen {flags+={.FULLSCREEN}}
    if !desc.window.no_surface {
        when ODIN_OS==.Darwin {flags+={.METAL}} else {flags+={.VULKAN}}
    }
    size:=desc.window.size
    if size.x<=0 || size.y<=0 {size=WINDOW_SIZE_DEFAULT}
    title:=strings.clone_to_cstring(desc.window.title,context.temp_allocator)
    w.handle=sdl.CreateWindow(title,size.x,size.y,flags)
    if w.handle==nil {return .Window_Failed}
    w.chrome=desc.window.chrome
    w.fixed_size=desc.window.fixed_size
    if w.chrome==.Custom && !desc.window.no_surface {window_native_chrome(p)}
    minimum:=desc.window.minimum_size
    if minimum.x<=0 || minimum.y<=0 {minimum=WINDOW_MINIMUM_SIZE_DEFAULT}
    w.minimum={min(minimum.x,size.x),min(minimum.y,size.y)}
    scale:=window_scale(w.handle)
    w.coordinate_scale=scale.coordinate
    if scale.coordinate!=1 && !desc.window.maximized && !desc.window.fullscreen {
        _=sdl.SetWindowSize(w.handle,window_native_extent(size.x,scale.coordinate),window_native_extent(size.y,scale.coordinate))
    }
    _=sdl.SetWindowMinimumSize(w.handle,window_native_extent(w.minimum.x,scale.coordinate),window_native_extent(w.minimum.y,scale.coordinate))
    if w.chrome==.Custom {_=sdl.SetWindowHitTest(w.handle,window_hit_callback,p)}
    when ODIN_OS==.Darwin {
        if !desc.window.no_surface {
            w.metal_view=sdl.Metal_CreateView(w.handle)
            w.metal_layer=sdl.Metal_GetLayer(w.metal_view)
            if w.metal_layer==nil {return .Surface_Failed}
        }
    }
    if r:=desc.window.rect;r.z>0 && r.w>0 && !desc.window.maximized && !desc.window.fullscreen {
        w.rect=r
        _=sdl.SetWindowMinimumSize(w.handle,min(r.z,window_native_extent(w.minimum.x,scale.coordinate)),min(r.w,window_native_extent(w.minimum.y,scale.coordinate)))
        window_rect_apply(w)
    } else {
        _=sdl.SetWindowPosition(w.handle,sdl.WINDOWPOS_CENTERED,sdl.WINDOWPOS_CENTERED)
    }
    if !desc.window.hidden {
        window_veil(w,true)
        _=sdl.ShowWindow(w.handle)
        w.veil=WINDOW_VEIL_FRAMES
    }
    _=sdl.StartTextInput(w.handle)
    window_refresh_rate_read(p)
    return .None
}

// Places the window in the rectangle it was asked for, its frame inside. The
// system may not know the frame right after the window is created: until it
// does, the next frames place it again.
@(private)
window_rect_apply :: proc(w:^Window) {
    if w.rect.z<=0 || w.handle==nil {return}
    top,left,bottom,right,found:=window_frame_borders(w)
    known:=found && top+left+bottom+right>0
    if !found {top,left,bottom,right=0,0,0,0}
    r:=w.rect
    _=sdl.SetWindowSize(w.handle,max(r.z-left-right,1),max(r.w-top-bottom,1))
    _=sdl.SetWindowPosition(w.handle,r.x+left,r.y+top)
    w.rect_tries+=1
    if known || w.chrome==.Custom || w.rect_tries>=WINDOW_RECT_TRIES {w.rect={}}
}
@(private) WINDOW_RECT_TRIES :: 30

// The part of the display of the window that windows may take (without the
// menu bar or the dock), in screen coordinates. ok is false without a window.
display_usable :: proc(p:^Platform) -> (rect:[4]i32,ok:bool) {
    if p.headless || p.window.handle==nil {return}
    display:=sdl.GetDisplayForWindow(p.window.handle)
    if display==0 {return}
    r:sdl.Rect
    if !sdl.GetDisplayUsableBounds(display,&r) {return}
    return {r.x,r.y,r.w,r.h},true
}

// The names of the displays of the system, in the order it lists them, the
// order window_set_display takes; none headless.
display_names :: proc(p:^Platform,allocator:=context.allocator) -> []string {
    if p.headless || p.window.handle==nil {return nil}
    count:c.int
    displays:=sdl.GetDisplays(&count)
    if displays==nil {return nil}
    defer sdl.free(displays)
    names,error:=make([]string,int(count),allocator)
    if error!=nil {return nil}
    for &name,i in names {
        if name,error=strings.clone_from_cstring(sdl.GetDisplayName(displays[i]),allocator);error==nil {continue}
        for taken in names[:i] {delete(taken,allocator)}
        delete(names,allocator)
        return nil
    }
    return names
}

// The index of the display the window is on, in the order of display_names;
// -1 headless or when the system does not say.
window_display :: proc(p:^Platform) -> int {
    if p.headless || p.window.handle==nil {return -1}
    count:c.int
    displays:=sdl.GetDisplays(&count)
    if displays==nil {return -1}
    defer sdl.free(displays)
    current:=sdl.GetDisplayForWindow(p.window.handle)
    for i in 0..<int(count) {if displays[i]==current {return i}}
    return -1
}

// Moves the window to the display of that index in the order of
// display_names, centered on it; a maximized window is maximized there and
// one in full screen fills it. False headless or past the displays.
window_set_display :: proc(p:^Platform,index:int) -> bool {
    if p.headless || p.window.handle==nil || index<0 {return false}
    handle:=p.window.handle
    count:c.int
    displays:=sdl.GetDisplays(&count)
    if displays==nil {return false}
    defer sdl.free(displays)
    if index>=int(count) {return false}
    display:=displays[index]
    if sdl.GetDisplayForWindow(handle)==display {return true}
    // The system ignores where a maximized window goes.
    maximized:=.MAXIMIZED in sdl.GetWindowFlags(handle)
    if maximized {_=sdl.RestoreWindow(handle)}
    centered:=sdl.WINDOWPOS_CENTERED_DISPLAY(c.int(display))
    _=sdl.SetWindowPosition(handle,centered,centered)
    if maximized {_=sdl.MaximizeWindow(handle)}
    _=sdl.SyncWindow(handle)
    return true
}

@(private)
window_close :: proc(p:^Platform) {
    w:=&p.window
    window_watch_live(p,false)
    for &slot in w.gamepads {
        if slot.handle!=nil {sdl.CloseGamepad(slot.handle);slot={}}
    }
    for &cursor in w.cursors {
        if cursor!=nil {sdl.DestroyCursor(cursor);cursor=nil}
    }
    when ODIN_OS==.Darwin {
        if w.metal_view!=nil {sdl.Metal_DestroyView(w.metal_view);w.metal_view=nil}
    }
    if w.handle!=nil {sdl.DestroyWindow(w.handle);w.handle=nil}
    if w.gamepad_events {sdl.QuitSubSystem({.GAMEPAD});w.gamepad_events=false}
    if w.video {
        // What the window left in the queue must not reach whoever uses SDL next.
        sdl.FlushEvents(.FIRST,.LAST)
        sdl.QuitSubSystem({.VIDEO});w.video=false
    }
    if w.driver_chosen {_=sdl.ResetHint(sdl.HINT_VIDEO_DRIVER);w.driver_chosen=false}
}

// Size, density and state of the window as the window system has them now.
@(private)
window_refresh :: proc(p:^Platform,f:^Window_Frame) {
    handle:=p.window.handle
    if handle==nil {return}
    width,height,pixel_width,pixel_height:i32
    _=sdl.GetWindowSize(handle,&width,&height)
    _=sdl.GetWindowSizeInPixels(handle,&pixel_width,&pixel_height)
    window_metrics_apply(p,f,{width,height},{pixel_width,pixel_height},window_scale(handle))
    flags:=sdl.GetWindowFlags(handle)
    f.minimized=.MINIMIZED in flags
    f.maximized=.MAXIMIZED in flags
    f.fullscreen=.FULLSCREEN in flags
    f.visible=.HIDDEN not_in flags
    f.focused=.INPUT_FOCUS in flags
}
@(private)
window_refresh_rate_read :: proc(p:^Platform) {
    p.window.refresh_hz=0
    display:=sdl.GetDisplayForWindow(p.window.handle)
    if display==0 {return}
    if mode:=sdl.GetCurrentDisplayMode(display);mode!=nil {p.window.refresh_hz=mode.refresh_rate}
    p.window.refresh_hz=window_native_refresh_hz(p,p.window.refresh_hz)
}
// Refresh rate of the display the window is on, in Hz; 0 when unknown or headless.
window_refresh_rate :: proc(p:^Platform) -> f32 {return p.window.refresh_hz}

window_show :: proc(p:^Platform) {
    if p.headless {p.input.frame.window.visible=true;return}
    _=sdl.ShowWindow(p.window.handle)
}
@(private)
window_veil_frame :: proc(w:^Window,presented:bool) {
    w.veil-=1
    if !presented && w.veil>0 {return}
    w.veil=0
    window_veil(w,false)
}
window_hide :: proc(p:^Platform) {
    if p.headless {p.input.frame.window.visible=false;return}
    _=sdl.HideWindow(p.window.handle)
}
window_minimize :: proc(p:^Platform) {
    if p.headless {p.input.frame.window.minimized=true;return}
    _=sdl.MinimizeWindow(p.window.handle)
}
// Also brings a minimized window back.
window_set_maximized :: proc(p:^Platform,maximized:bool) {
    if p.headless {
        f:=&p.input.frame.window
        f.maximized=maximized;f.minimized=false
        return
    }
    if maximized {_=sdl.MaximizeWindow(p.window.handle)} else {_=sdl.RestoreWindow(p.window.handle)}
}
window_set_fullscreen :: proc(p:^Platform,fullscreen:bool) {
    if p.headless {p.input.frame.window.fullscreen=fullscreen;return}
    _=sdl.SetWindowFullscreen(p.window.handle,fullscreen)
}
// Size in points. The frame reports the size the window system settled on.
window_set_size :: proc(p:^Platform,size:[2]i32) {
    if size.x<=0 || size.y<=0 {return}
    if p.headless {
        _=input_inject(p,Window_Event{kind=.Resized,size=size})
        return
    }
    scale:=window_scale(p.window.handle).coordinate
    _=sdl.SetWindowSize(p.window.handle,window_native_extent(size.x,scale),window_native_extent(size.y,scale))
}

window_title :: proc(p:^Platform) -> string {return string(p.title[:p.title_length])}
// Cut to TITLE_CAPACITY-1 bytes. The window system is told only when it changes.
window_set_title :: proc(p:^Platform,title:string) {
    if title==window_title(p) {return}
    title_store(p,title)
    if p.window.handle!=nil {_=sdl.SetWindowTitle(p.window.handle,cstring(raw_data(p.title[:])))}
}
// The icon of the window in the taskbar, the dock and the switcher: width*height
// RGBA pixels, straight alpha. SDL copies them; false without a window.
window_set_icon :: proc(p:^Platform,pixels:[]u8,width,height:i32) -> bool {
    if p.window.handle==nil || width<=0 || height<=0 || len(pixels)<int(width*height*4) {return false}
    surface:=sdl.CreateSurfaceFrom(width,height,.RGBA32,raw_data(pixels),width*4)
    if surface==nil {return false}
    defer sdl.DestroySurface(surface)
    return sdl.SetWindowIcon(p.window.handle,surface)
}
@(private)
title_store :: proc(p:^Platform,title:string) {
    p.title_length=copy(p.title[:TITLE_CAPACITY-1],title)
    p.title[p.title_length]=0
}

window_cursor :: proc(p:^Platform) -> Cursor {return p.window.cursor}
window_set_cursor :: proc(p:^Platform,cursor:Cursor) {
    w:=&p.window
    if cursor==w.cursor {return}
    previous:=w.cursor
    w.cursor=cursor
    if w.handle==nil {return}
    if cursor==.Hidden {_=sdl.HideCursor();return}
    if handle:=window_cursor_handle(p,cursor);handle!=nil {_=sdl.SetCursor(handle)}
    if previous==.Hidden {_=sdl.ShowCursor()}
}
@(private)
window_cursor_handle :: proc(p:^Platform,cursor:Cursor) -> ^sdl.Cursor {
    SYSTEM :: [Cursor]sdl.SystemCursor{
        .Default=.DEFAULT,.Text=.TEXT,.Pointer=.POINTER,.Crosshair=.CROSSHAIR,.Move=.MOVE,
        .Resize_Horizontal=.EW_RESIZE,.Resize_Vertical=.NS_RESIZE,
        .Resize_Diagonal_Down=.NWSE_RESIZE,.Resize_Diagonal_Up=.NESW_RESIZE,
        .Not_Allowed=.NOT_ALLOWED,.Wait=.WAIT,.Progress=.PROGRESS,.Hidden=.DEFAULT,
    }
    w:=&p.window
    if w.cursors[cursor]==nil {
        system:=SYSTEM
        w.cursors[cursor]=sdl.CreateSystemCursor(system[cursor])
    }
    return w.cursors[cursor]
}

// Relative mode for a game that turns its camera with the mouse: the pointer
// is hidden and kept in the window, and motion keeps arriving as deltas.
window_relative_mouse :: proc(p:^Platform) -> bool {return p.window.relative_mouse}
window_set_relative_mouse :: proc(p:^Platform,enabled:bool) {
    w:=&p.window
    if w.relative_mouse==enabled {return}
    w.relative_mouse=enabled
    if w.handle!=nil {_=sdl.SetWindowRelativeMouseMode(w.handle,enabled)}
}

// Headless, the clipboard is a buffer of the Platform.
clipboard_set :: proc(p:^Platform,text:string) -> bool {
    if p.headless {
        if len(text)>len(p.clipboard) {return false}
        p.clipboard_length=copy(p.clipboard,text)
        return true
    }
    return sdl.SetClipboardText(strings.clone_to_cstring(text,context.temp_allocator))
}
// The text of the clipboard, in the temporary allocator.
clipboard_get :: proc(p:^Platform) -> (text:string,ok:bool) {
    if p.headless {
        if p.clipboard_length==0 {return "",false}
        return strings.clone(string(p.clipboard[:p.clipboard_length]),context.temp_allocator),true
    }
    if !sdl.HasClipboardText() {return "",false}
    raw:=sdl.GetClipboardText()
    if raw==nil {return "",false}
    defer sdl.free(raw)
    return strings.clone(string(cstring(raw)),context.temp_allocator),true
}

// The ^sdl.Window, nil when headless.
window_native :: proc(p:^Platform) -> rawptr {return p.window.handle}
// Instance extensions the window system needs to present with Vulkan. The
// names belong to SDL and live as long as the process.
vulkan_instance_extensions :: proc(p:^Platform) -> []cstring {
    if p.window.handle==nil || ODIN_OS==.Darwin {return nil}
    count:u32
    names:=sdl.Vulkan_GetInstanceExtensions(&count)
    if names==nil {return nil}
    return names[:count]
}
// Creates the VkSurfaceKHR of the window for a VkInstance. user is the
// ^Platform; the instance destroys the surface with vkDestroySurfaceKHR.
vulkan_surface_create :: proc(instance:rawptr,user:rawptr) -> (surface:u64,ok:bool) {
    p:=cast(^Platform)user
    if p==nil || p.window.handle==nil {return 0,false}
    handle:vk.SurfaceKHR
    if !sdl.Vulkan_CreateSurface(p.window.handle,vk.Instance(instance),nil,&handle) {return 0,false}
    return u64(handle),true
}
// The CAMetalLayer of the window; nil when headless or not on macOS.
metal_layer :: proc(p:^Platform) -> rawptr {return p.window.metal_layer}
surface_source :: proc(p:^Platform) -> Surface_Source {
    size:=p.input.frame.window.pixel_size
    if p.window.handle!=nil {
        width,height:i32
        _=sdl.GetWindowSizeInPixels(p.window.handle,&width,&height)
        size={max(width,0),max(height,0)}
    }
    return {vulkan_create=vulkan_surface_create,vulkan_user=p,metal_layer=p.window.metal_layer,width=u32(size.x),height=u32(size.y)}
}
