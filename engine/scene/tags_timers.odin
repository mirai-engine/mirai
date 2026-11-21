package scene

import "mirai:core"

@(component,shared,description="A set of up to 64 game-defined tags.")
Tags :: struct {bits:u64}

tag_has :: proc "contextless" (tags:Tags,tag:int) -> bool {
    return tag>=0 && tag<64 && tags.bits&(u64(1)<<uint(tag))!=0
}

tag_has_all :: proc "contextless" (tags,required:Tags) -> bool {
    return tags.bits&required.bits==required.bits
}

tag_has_any :: proc "contextless" (tags,choices:Tags) -> bool {
    return tags.bits&choices.bits!=0
}

tag_set :: proc "contextless" (tags:^Tags,tag:int) -> bool {
    if tags==nil || tag<0 || tag>=64 {return false}
    tags.bits|=u64(1)<<uint(tag)
    return true
}

tag_clear :: proc "contextless" (tags:^Tags,tag:int) -> bool {
    if tags==nil || tag<0 || tag>=64 {return false}
    tags.bits&=~(u64(1)<<uint(tag))
    return true
}

@(component,shared,description="Four fixed-tick cooldowns whose deadlines survive rollback.")
Cooldowns :: struct {deadlines:[4]u64 `mirai:"hidden"`}

cooldown_start :: proc "contextless" (cooldowns:^Cooldowns,slot:int,time:core.Time,seconds:f32) -> bool {
    if cooldowns==nil || slot<0 || slot>=len(cooldowns.deadlines) {return false}
    cooldowns.deadlines[slot]=core.deadline(time,seconds)
    return true
}

cooldown_ready :: proc "contextless" (cooldowns:Cooldowns,slot:int,time:core.Time) -> bool {
    return slot>=0 && slot<len(cooldowns.deadlines) && core.due(time,cooldowns.deadlines[slot])
}

cooldown_remaining :: proc "contextless" (cooldowns:Cooldowns,slot:int,time:core.Time) -> f32 {
    if slot<0 || slot>=len(cooldowns.deadlines) || cooldown_ready(cooldowns,slot,time) {return 0}
    return core.seconds_of(time,cooldowns.deadlines[slot]-time.tick)
}

Timer :: struct {started,deadline:u64}

@(component,shared,description="Three fixed-tick timers with a start and a deadline.")
Timers :: struct {
    slots:[3]Timer `mirai:"hidden"`,
    active:u8 `mirai:"hidden"`,
}

timer_start :: proc "contextless" (timers:^Timers,slot:int,time:core.Time,seconds:f32) -> bool {
    if timers==nil || slot<0 || slot>=len(timers.slots) {return false}
    timers.slots[slot]={time.tick,core.deadline(time,seconds)}
    timers.active|=u8(1)<<uint(slot)
    return true
}

@(private)
timer_active :: proc "contextless" (timers:^Timers,slot:int) -> bool {
    return timers!=nil && slot>=0 && slot<len(timers.slots) && timers.active&(u8(1)<<uint(slot))!=0
}

timer_elapsed :: proc "contextless" (timers:^Timers,slot:int,time:core.Time) -> f32 {
    if !timer_active(timers,slot) {return 0}
    return core.elapsed(time,timers.slots[slot].started)
}

timer_due :: proc "contextless" (timers:^Timers,slot:int,time:core.Time) -> bool {
    return timer_active(timers,slot) && core.due(time,timers.slots[slot].deadline)
}
