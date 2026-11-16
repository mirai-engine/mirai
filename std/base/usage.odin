package base

// Occupancy of a fixed-capacity container. An insertion that finds it full is
// refused and counted.
Usage :: struct {
    count:int,
    peak:int,   // largest count since init
    capacity:int,
    failed:u64, // insertions refused for lack of room
}

@(private)
usage_add :: #force_inline proc "contextless" (u:^Usage) {
    u.count+=1
    if u.count>u.peak {u.peak=u.count}
}
