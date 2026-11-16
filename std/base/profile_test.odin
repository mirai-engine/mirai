package base

import "core:testing"

@(test)
profile_read_since_drains_each_zone_once_and_counts_what_was_lost :: proc(t:^testing.T) {
    p:Profile
    testing.expect(t,profile_init(&p,{threads=2,zones_per_thread=4}))
    defer profile_destroy(&p)
    out:[8]Profile_Zone

    for _ in 0..<3 {profile_end(profile_begin(&p,1,"a"))}
    count,next,lost:=profile_read_since(&p,1,0,out[:])
    testing.expect_value(t,count,3)
    testing.expect_value(t,next,u64(3))
    testing.expect_value(t,lost,u64(0))
    testing.expect_value(t,out[0].name,"a")
    testing.expect_value(t,out[2].thread,u16(1))

    count,next,lost=profile_read_since(&p,1,next,out[:])
    testing.expect_value(t,count,0)
    testing.expect_value(t,next,u64(3))

    // The ring holds four: of six new zones the first two are gone.
    for _ in 0..<6 {profile_end(profile_begin(&p,1,"b"))}
    count,next,lost=profile_read_since(&p,1,3,out[:])
    testing.expect_value(t,count,4)
    testing.expect_value(t,next,u64(9))
    testing.expect_value(t,lost,u64(2))
    testing.expect_value(t,out[0].name,"b")

    // An out that is too short keeps the newest.
    for _ in 0..<3 {profile_end(profile_begin(&p,1,"c"))}
    count,next,lost=profile_read_since(&p,1,9,out[:2])
    testing.expect_value(t,count,2)
    testing.expect_value(t,next,u64(12))
    testing.expect_value(t,lost,u64(1))

    // Nested zones end inner first, one level deeper.
    outer:=profile_begin(&p,0,"outer")
    profile_end(profile_begin(&p,0,"inner"))
    profile_end(outer)
    count,next,lost=profile_read_since(&p,0,0,out[:])
    testing.expect_value(t,count,2)
    testing.expect_value(t,out[0].name,"inner")
    testing.expect_value(t,out[0].depth,u16(1))
    testing.expect_value(t,out[1].depth,u16(0))
    testing.expect(t,out[1].duration>=out[0].duration)

    count,next,lost=profile_read_since(&p,5,7,out[:])
    testing.expect_value(t,count,0)
    testing.expect_value(t,next,u64(7))
}
