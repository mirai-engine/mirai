package mirai_math

import "core:math"
import "core:math/ease"

// Easing curves: they take t from 0 to 1 and return the eased progress, which
// starts at 0 and ends at 1. Back and elastic leave that range on the way.
// The polynomial, sine, exponential and circular curves are core's; back,
// elastic and bounce are Penner's, which core's are not.

ease_quad_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quadratic_in(t)}
ease_quad_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quadratic_out(t)}
ease_quad_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quadratic_in_out(t)}
ease_cubic_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.cubic_in(t)}
ease_cubic_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.cubic_out(t)}
ease_cubic_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.cubic_in_out(t)}
ease_quart_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quartic_in(t)}
ease_quart_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quartic_out(t)}
ease_quart_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quartic_in_out(t)}
ease_quint_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quintic_in(t)}
ease_quint_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quintic_out(t)}
ease_quint_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.quintic_in_out(t)}
ease_sine_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.sine_in(t)}
ease_sine_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.sine_out(t)}
ease_sine_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.sine_in_out(t)}
ease_expo_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.exponential_in(t)}
ease_expo_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.exponential_out(t)}
ease_expo_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.exponential_in_out(t)}
ease_circ_in :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.circular_in(t)}
ease_circ_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.circular_out(t)}
ease_circ_in_out :: #force_inline proc "contextless" (t:f32) -> f32 {return ease.circular_in_out(t)}

@(private) BACK_OVERSHOOT :: 1.70158
@(private) BACK_OVERSHOOT_IN_OUT :: BACK_OVERSHOOT*1.525

ease_back_in :: proc "contextless" (t:f32) -> f32 {return t*t*((BACK_OVERSHOOT+1)*t-BACK_OVERSHOOT)}
ease_back_out :: proc "contextless" (t:f32) -> f32 {
    u:=t-1
    return 1+u*u*((BACK_OVERSHOOT+1)*u+BACK_OVERSHOOT)
}
ease_back_in_out :: proc "contextless" (t:f32) -> f32 {
    if t<0.5 {
        u:=2*t
        return 0.5*u*u*((BACK_OVERSHOOT_IN_OUT+1)*u-BACK_OVERSHOOT_IN_OUT)
    }
    u:=2*t-2
    return 0.5*(u*u*((BACK_OVERSHOOT_IN_OUT+1)*u+BACK_OVERSHOOT_IN_OUT)+2)
}
ease_elastic_in :: proc "contextless" (t:f32) -> f32 {
    if t<=0 {return 0}
    if t>=1 {return 1}
    return -math.pow(2,10*t-10)*math.sin((10*t-10.75)*(TAU/3))
}
ease_elastic_out :: proc "contextless" (t:f32) -> f32 {
    if t<=0 {return 0}
    if t>=1 {return 1}
    return math.pow(2,-10*t)*math.sin((10*t-0.75)*(TAU/3))+1
}
ease_elastic_in_out :: proc "contextless" (t:f32) -> f32 {
    if t<=0 {return 0}
    if t>=1 {return 1}
    wave:=math.sin((20*t-11.125)*(TAU/4.5))
    if t<0.5 {return -0.5*math.pow(2,20*t-10)*wave}
    return 0.5*math.pow(2,-20*t+10)*wave+1
}

ease_bounce_out :: proc "contextless" (t:f32) -> f32 {
    STRENGTH :: 7.5625
    SPAN :: 2.75
    switch {
    case t<1/SPAN:
        return STRENGTH*t*t
    case t<2/SPAN:
        u:=t-1.5/SPAN
        return STRENGTH*u*u+0.75
    case t<2.5/SPAN:
        u:=t-2.25/SPAN
        return STRENGTH*u*u+0.9375
    }
    u:=t-2.625/SPAN
    return STRENGTH*u*u+0.984375
}
ease_bounce_in :: proc "contextless" (t:f32) -> f32 {return 1-ease_bounce_out(1-t)}
ease_bounce_in_out :: proc "contextless" (t:f32) -> f32 {
    if t<0.5 {return 0.5*(1-ease_bounce_out(1-2*t))}
    return 0.5*(1+ease_bounce_out(2*t-1))
}

// The curves by number, for data: a tween or an animation track stores one of
// these. The values are part of saved data and never change.
Ease :: enum u8 {
    Linear         = 0,
    Quad_In        = 1,
    Quad_Out       = 2,
    Quad_In_Out    = 3,
    Cubic_In       = 4,
    Cubic_Out      = 5,
    Cubic_In_Out   = 6,
    Quart_In       = 7,
    Quart_Out      = 8,
    Quart_In_Out   = 9,
    Quint_In       = 10,
    Quint_Out      = 11,
    Quint_In_Out   = 12,
    Sine_In        = 13,
    Sine_Out       = 14,
    Sine_In_Out    = 15,
    Expo_In        = 16,
    Expo_Out       = 17,
    Expo_In_Out    = 18,
    Circ_In        = 19,
    Circ_Out       = 20,
    Circ_In_Out    = 21,
    Back_In        = 22,
    Back_Out       = 23,
    Back_In_Out    = 24,
    Elastic_In     = 25,
    Elastic_Out    = 26,
    Elastic_In_Out = 27,
    Bounce_In      = 28,
    Bounce_Out     = 29,
    Bounce_In_Out  = 30,
}

ease_apply :: proc "contextless" (kind:Ease,t:f32) -> f32 {
    switch kind {
    case .Linear:         return t
    case .Quad_In:        return ease_quad_in(t)
    case .Quad_Out:       return ease_quad_out(t)
    case .Quad_In_Out:    return ease_quad_in_out(t)
    case .Cubic_In:       return ease_cubic_in(t)
    case .Cubic_Out:      return ease_cubic_out(t)
    case .Cubic_In_Out:   return ease_cubic_in_out(t)
    case .Quart_In:       return ease_quart_in(t)
    case .Quart_Out:      return ease_quart_out(t)
    case .Quart_In_Out:   return ease_quart_in_out(t)
    case .Quint_In:       return ease_quint_in(t)
    case .Quint_Out:      return ease_quint_out(t)
    case .Quint_In_Out:   return ease_quint_in_out(t)
    case .Sine_In:        return ease_sine_in(t)
    case .Sine_Out:       return ease_sine_out(t)
    case .Sine_In_Out:    return ease_sine_in_out(t)
    case .Expo_In:        return ease_expo_in(t)
    case .Expo_Out:       return ease_expo_out(t)
    case .Expo_In_Out:    return ease_expo_in_out(t)
    case .Circ_In:        return ease_circ_in(t)
    case .Circ_Out:       return ease_circ_out(t)
    case .Circ_In_Out:    return ease_circ_in_out(t)
    case .Back_In:        return ease_back_in(t)
    case .Back_Out:       return ease_back_out(t)
    case .Back_In_Out:    return ease_back_in_out(t)
    case .Elastic_In:     return ease_elastic_in(t)
    case .Elastic_Out:    return ease_elastic_out(t)
    case .Elastic_In_Out: return ease_elastic_in_out(t)
    case .Bounce_In:      return ease_bounce_in(t)
    case .Bounce_Out:     return ease_bounce_out(t)
    case .Bounce_In_Out:  return ease_bounce_in_out(t)
    }
    return t
}
