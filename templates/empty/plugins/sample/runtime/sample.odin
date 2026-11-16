package sample

import "mirai:core"

// How long its entity has been simulated.
@(component)
Lifetime :: struct {seconds:f32 `mirai:"unit=s,readonly"`}

@(step="fixed")
sample_age :: proc(lifetimes:^core.Table(Lifetime),time:core.Time) {
    for &lifetime in core.writable(lifetimes) {lifetime.seconds+=time.dt}
}
