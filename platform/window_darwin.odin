#+build darwin
package platform

import CG "core:sys/darwin/CoreGraphics"
import NS "vendor:darwin/AppKit"
import sdl "vendor:sdl3"

@(private)
window_native_chrome :: proc(p:^Platform) {
    window:=cast(^NS.Window)sdl.GetPointerProperty(sdl.GetWindowProperties(p.window.handle),sdl.PROP_WINDOW_COCOA_WINDOW_POINTER,nil)
    if window==nil {return}
    style:=NS.WindowStyleMask{.Titled,.Closable,.Miniaturizable,.FullSizeContentView}
    if !p.window.fixed_size {style+={.Resizable}}
    NS.Window_setStyleMask(window,style)
    NS.Window_setTitleVisibility(window,.Hidden)
    NS.Window_setTitlebarAppearsTransparent(window,true)
}

// Cocoa consumes the clicks of a drag region before they reach SDL's queue,
// ignores the resize regions and shows no resize cursors for a borderless
// window. All three are done here, during the hit test, while the native
// event is the current one.
@(private)
window_native_hit :: proc(p:^Platform,hit:sdl.HitTestResult) -> sdl.HitTestResult {
    w:=&p.window
    if w.relative_mouse {return hit}
    shown:=w.cursor
    #partial switch hit {
    case .RESIZE_LEFT,.RESIZE_RIGHT:shown=.Resize_Horizontal
    case .RESIZE_TOP,.RESIZE_BOTTOM:shown=.Resize_Vertical
    case .RESIZE_TOPLEFT,.RESIZE_BOTTOMRIGHT:shown=.Resize_Diagonal_Down
    case .RESIZE_TOPRIGHT,.RESIZE_BOTTOMLEFT:shown=.Resize_Diagonal_Up
    }
    if shown!=.Hidden {
        if cursor:=window_cursor_handle(p,shown);cursor!=nil && cursor!=sdl.GetCursor() {_=sdl.SetCursor(cursor)}
    }
    event:=NS.Application_currentEvent(NS.Application_sharedApplication())
    if event==nil {return hit}
    native:=sdl.GetPointerProperty(sdl.GetWindowProperties(w.handle),sdl.PROP_WINDOW_COCOA_WINDOW_POINTER,nil)
    if rawptr(NS.Event_window(event))!=native {return hit}
    time:=f64(NS.Event_timestamp(event))
    kind:=NS.Event_type(event)
    resizing:=w.resize.hit!=.NORMAL
    if resizing || (kind==.LeftMouseDown && hit!=.NORMAL && hit!=.DRAGGABLE) {
        if time<=w.resize.time {return .NORMAL}
        if kind!=.LeftMouseDown && kind!=.LeftMouseDragged && kind!=.LeftMouseUp {return .NORMAL}
        w.resize.time=time;w.resize_input=true
        cg_event:=NS.Event_CGEvent(event)
        if cg_event==nil {return .NORMAL}
        // Quartz stores screen coordinates in the event: moving the window
        // does not change the delta of drag events already queued.
        point:=CG.EventGetLocation(cg_event)
        mouse:=[2]f32{f32(point.x),f32(point.y)}
        if !resizing {
            resize:=&w.resize
            resize.hit=hit;resize.mouse=mouse
            _=sdl.GetWindowPosition(w.handle,&resize.rect.x,&resize.rect.y)
            _=sdl.GetWindowSize(w.handle,&resize.rect.w,&resize.rect.h)
            _=sdl.GetWindowMinimumSize(w.handle,&resize.minimum[0],&resize.minimum[1])
            _=sdl.CaptureMouse(true)
        } else {
            rect:=window_resize_rect(w.resize.rect,w.resize.hit,mouse-w.resize.mouse,w.resize.minimum)
            _=sdl.SetWindowPosition(w.handle,rect.x,rect.y)
            _=sdl.SetWindowSize(w.handle,rect.w,rect.h)
            if kind==.LeftMouseUp {w.resize.hit=.NORMAL;_=sdl.CaptureMouse(false)}
        }
        return .NORMAL // a resize must not start the native dragging of the bar
    }
    if hit!=.DRAGGABLE || .FULLSCREEN in sdl.GetWindowFlags(w.handle) {return hit}
    if kind!=.LeftMouseUp || NS.Event_clickCount(event)!=2 {return hit}
    if time<=w.click_time {return hit} // Cocoa may hit test the same event again
    w.click_time=time
    w.toggle_maximize=true
    return hit
}

// The frame AppKit draws around the content: SDL does not report it on macOS.
@(private)
window_frame_borders :: proc(w:^Window) -> (top,left,bottom,right:i32,ok:bool) {
    window:=cast(^NS.Window)sdl.GetPointerProperty(sdl.GetWindowProperties(w.handle),sdl.PROP_WINDOW_COCOA_WINDOW_POINTER,nil)
    if window==nil {return}
    frame:=NS.Window_frame(window)
    content:=NS.Window_contentRectForFrameRect(window,frame)
    // AppKit measures up from the bottom of the screen.
    top=i32((frame.origin.y+frame.size.height)-(content.origin.y+content.size.height)+0.5)
    bottom=i32(content.origin.y-frame.origin.y+0.5)
    left=i32(content.origin.x-frame.origin.x+0.5)
    right=i32((frame.origin.x+frame.size.width)-(content.origin.x+content.size.width)+0.5)
    return top,left,bottom,right,true
}
