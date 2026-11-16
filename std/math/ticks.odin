package mirai_math

import "core:math"

// The fixed ticks of dt seconds that last `seconds`, to the nearest one: 0
// when seconds or dt is not above 0, max(u64) when they are more than a tick
// counts.
ticks_of :: proc "contextless" (seconds:f64,dt:f32) -> u64 {
    if !(seconds>0) || !(dt>0) {return 0}
    ticks:=math.round(seconds/f64(dt))
    return ticks<f64(max(u64))?u64(ticks):max(u64)
}
