package platform

import sdl "vendor:sdl3"

// Monotonic clock in nanoseconds. Its origin is arbitrary: only differences mean anything.
clock_ns :: proc "contextless" () -> u64 {return sdl.GetTicksNS()}
clock_seconds :: proc "contextless" () -> f64 {return f64(sdl.GetTicksNS())/1e9}

// Waits with the precision of the clock: the system sleeps most of the time
// and the rest is spun, so the caller wakes up within microseconds of the end.
sleep_precise :: proc "contextless" (nanoseconds:u64) {
    if nanoseconds>0 {sdl.DelayPrecise(nanoseconds)}
}
// Gives the time back to the system: cheap, and late by up to a scheduler quantum.
sleep_coarse :: proc "contextless" (nanoseconds:u64) {
    if nanoseconds>0 {sdl.DelayNS(nanoseconds)}
}

// limit: frames per second, 0 for no limit. vsync: the swapchain waits for
// the display; the GPU backend applies it, the pacing only accounts for it.
Frame_Pacing :: struct {limit:u32,vsync:bool}
FRAME_PACING_DEFAULT :: Frame_Pacing{limit=60}
FRAME_DT_MAX :: f32(0.1)
// A frame that shows nothing (minimized, hidden, not presented) still polls
// its events at this rate instead of spinning.
IDLE_FRAME_NS :: u64(1_000_000_000/30)

// Time a frame has to last. With vsync on and a limit at or above the
// refresh rate of the display (or none), a presented frame lasts one refresh
// period: the swapchain alone can let the loop go unevenly (through the
// compositor of Windows, frames in pairs 28 and 5 ms apart at 60 Hz), and
// the input and the motion of each frame would follow it.
pacing_budget_ns :: proc "contextless" (pacing:Frame_Pacing,presented:bool,refresh_hz:f32) -> u64 {
    budget:=u64(0)
    if pacing.limit>0 {budget=1_000_000_000/u64(pacing.limit)}
    if !presented {return max(budget,IDLE_FRAME_NS)}
    if pacing.vsync && refresh_hz>0 && (pacing.limit==0 || f32(pacing.limit)>=refresh_hz-0.5) {return refresh_period_ns(refresh_hz)}
    return budget
}
refresh_period_ns :: proc "contextless" (refresh_hz:f32) -> u64 {return u64(1e9/f64(refresh_hz)+0.5)}
// When the frame that ends now should end. Frames are spaced from the end
// the previous one aimed at, so the error of a sleep does not accumulate; a
// frame that ran long owes nothing to the next ones.
pacing_target_ns :: proc "contextless" (previous_target,now,budget:u64) -> u64 {
    if budget==0 {return now}
    target:=previous_target+budget
    if target<now {return now}
    if target>now+budget {return now+budget}
    return target
}

// The time a frame stands for, from the clock time since the previous one.
// With vsync a presented frame reaches the screen on a vertical blank, so it
// stands for a whole number of refresh periods, at least one; the clock only
// says when the swapchain let the loop go, which jitters, and motion scaled
// by it would not be even on the screen. carry holds how far the clock is
// ahead of the periods given and pays for the next ones, so their sum keeps
// up with the clock; a frame that would leave it more than a period behind
// takes the clock time instead.
frame_dt_ns :: proc "contextless" (elapsed:u64,pacing:Frame_Pacing,presented:bool,refresh_hz:f32,carry:^i64) -> u64 {
    if !pacing.vsync || !presented || refresh_hz<=0 {
        carry^=0
        return elapsed
    }
    period:=i64(refresh_period_ns(refresh_hz))
    total:=i64(elapsed)+carry^
    snapped:=max(total/period,1)*period
    if total-snapped < -period {
        carry^=0
        return elapsed
    }
    carry^=total-snapped
    return u64(snapped)
}

@(private)
Frame_Clock :: struct {
    last:u64,        // start of the previous frame, live frames included
    pace_target:u64, // when the previous frame was meant to end
    shown:bool,      // the previous frame was presented on a visible window
    carry:i64,       // of frame_dt_ns
}

@(private)
frame_clock_dt :: proc(p:^Platform,now:u64,presented:bool) -> f32 {
    if p.fixed_dt>0 {return p.fixed_dt}
    elapsed:=frame_dt_ns(now-p.clock.last,p.pacing,presented,p.window.refresh_hz,&p.clock.carry)
    return min(f32(f64(elapsed)/1e9),FRAME_DT_MAX)
}

pacing :: proc(p:^Platform) -> Frame_Pacing {return p.pacing}
set_pacing :: proc(p:^Platform,pacing:Frame_Pacing) {p.pacing=pacing}
// The rate a window without focus goes at, at most: an application that does
// not need to run behind others (an editor out of Play) lowers what it costs.
set_background :: proc(p:^Platform,limit:u32) {p.background=limit}

// Ends the frame: sleeps what is left of its budget. presented is false when
// nothing was drawn, so the loop idles instead of spinning. The first frame
// that presents puts the window on the screen. images: those the frame shows,
// two when it generated one: the limit and vsync count the images.
frame_end :: proc(p:^Platform,presented:=true,images:=u32(1)) {
    if p.window.veil>0 {window_veil_frame(&p.window,presented)}
    shown:=presented
    if !p.headless {
        w:=&p.input.frame.window
        shown=presented && w.visible && !w.minimized
    }
    budget:=pacing_budget_ns(p.pacing,shown,p.window.refresh_hz)
    if shown && images>1 {budget*=u64(images)}
    if !p.headless && p.background>0 && !p.input.frame.window.focused {budget=max(budget,1_000_000_000/u64(p.background))}
    now:=clock_ns()
    target:=pacing_target_ns(p.clock.pace_target,now,budget)
    if target>now {
        sleep_precise(target-now)
        p.stats.paced_ns+=target-now
    }
    p.clock.pace_target=target
    p.clock.shown=shown
}
