#+build linux, darwin
#+private
package platform

import sdl "vendor:sdl3"

// A transparent window is on the screen for the window system, which keeps
// giving it images to present; a system without window opacity shows it
// empty until the first one.
window_veil :: proc(w:^Window,veiled:bool) {
    _=sdl.SetWindowOpacity(w.handle,veiled?0:1)
}
