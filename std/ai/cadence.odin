package ai

// A cadence spaces out what an agent runs by how far it is from whoever
// looks: plain arithmetic on the tick, with no state, so a world and a copy
// of it run the same ticks.

// Whether what runs every `period` ticks runs at `tick`: the phase (the index
// of the agent) spreads those of one period over its ticks. A period of 0 or
// 1 is every tick.
cadence_due :: #force_inline proc "contextless" (tick,phase,period:u64) -> bool {
    return period<=1 || (tick+phase)%period==0
}

// The ticks between two runs of what is `distance` m from the nearest viewer:
// one more for each `near` m, from 1 below 2*near up to `slowest`. A distance
// that is not a number is the farthest; a near not above 0 is every tick.
cadence_period :: proc "contextless" (distance,near:f32,slowest:u64) -> u64 {
    if !(near>0) || near>max(f32) || slowest<=1 || distance<near {return 1}
    if !(distance<near*f32(slowest)) {return slowest}
    return max(u64(distance/near),1)
}
