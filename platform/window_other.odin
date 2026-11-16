#+build !darwin
package platform

import sdl "vendor:sdl3"

@(private)
window_native_chrome :: proc(p:^Platform) {}

// The window system drags, resizes, shows the resize cursors and maximizes
// on a double click of a drag region by itself.
@(private)
window_native_hit :: proc(p:^Platform,hit:sdl.HitTestResult) -> sdl.HitTestResult {return hit}

// The frame the window system draws around the content, once it knows it.
@(private)
window_frame_borders :: proc(w:^Window) -> (top,left,bottom,right:i32,ok:bool) {
    ok=sdl.GetWindowBordersSize(w.handle,&top,&left,&bottom,&right)
    return
}
