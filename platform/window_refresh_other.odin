#+build !windows
package platform

@(private)
window_native_refresh_hz :: proc(p:^Platform,sdl_hz:f32) -> f32 {return sdl_hz}
