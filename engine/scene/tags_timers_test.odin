package scene

import "core:testing"
import "mirai:core"

@(test)
tags_match_masks_and_reject_indices_outside_the_set :: proc(t:^testing.T) {
    tags:Tags
    testing.expect(t,tag_set(&tags,0) && tag_set(&tags,63))
    testing.expect(t,tag_has(tags,63) && tag_has_all(tags,{bits=1}))
    testing.expect(t,tag_has_any(tags,{bits=3}) && !tag_has_all(tags,{bits=3}))
    testing.expect(t,!tag_set(&tags,-1) && !tag_clear(&tags,64) && !tag_has(tags,-1))
    testing.expect(t,tag_clear(&tags,63) && tags.bits==1)
}

@(test)
timers_and_cooldowns_replay_from_fixed_tick_deadlines :: proc(t:^testing.T) {
    time:=core.Time{dt=0.125}
    timers:Timers
    cooldowns:Cooldowns
    testing.expect(t,!timer_due(&timers,0,time) && cooldown_ready(cooldowns,0,time))
    testing.expect(t,timer_start(&timers,0,time,0.5) && cooldown_start(&cooldowns,0,time,0.5))
    testing.expect(t,timer_start(&timers,1,time,0) && timer_due(&timers,1,time))
    saved:=timers
    kept_cooldowns:=cooldowns
    for tick in 0..=u64(5) {
        time.tick=tick
        testing.expect_value(t,timer_due(&timers,0,time),tick>=4)
        testing.expect_value(t,timer_elapsed(&timers,0,time),f32(tick)*time.dt)
        testing.expect_value(t,cooldown_remaining(cooldowns,0,time),max(0,0.5-f32(tick)*time.dt))
    }
    time.tick=2
    time.resimulating=true
    testing.expect_value(t,timers,saved)
    testing.expect_value(t,cooldowns,kept_cooldowns)
    testing.expect(t,!timer_due(&saved,0,time) && !cooldown_ready(kept_cooldowns,0,time))
    core.time_advance(&time)
    core.time_advance(&time)
    testing.expect(t,timer_due(&saved,0,time) && cooldown_ready(kept_cooldowns,0,time))
}
