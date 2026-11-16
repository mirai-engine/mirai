package host

import "mirai:core"
import "mirai:platform"

input_from_platform :: proc "contextless" (tick:$T) -> (input:core.Input) where T==platform.Input_Tick || T==platform.Input_Frame {
    input.keys_down,input.keys_pressed,input.keys_released=tick.keys_down,tick.keys_pressed,tick.keys_released
    input.mouse_down,input.mouse_pressed,input.mouse_released=tick.mouse_down,tick.mouse_pressed,tick.mouse_released
    input.mouse_position,input.mouse_delta=tick.mouse_position,tick.mouse_delta
    input.wheel=tick.wheel
    input.pressure,input.eraser=tick.pressure,tick.eraser
    when T==platform.Input_Frame {input.window_size={f32(tick.window.size.x),f32(tick.window.size.y)}}
    else {input.window_size=tick.window_size}
    input.gamepads,input.device=tick.gamepads,tick.device
    return
}
