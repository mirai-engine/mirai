package host

import "core:testing"
import "core:time"

@(test)
a_capture_goes_on_while_textures_gi_or_exposure_are_settling_within_their_limits :: proc(t:^testing.T) {
    wait:=time.Second
    cases:=[?]struct{count,frame,pending:int,light:bool,limit:int,waited:time.Duration,expected,expected_limit:int}{
        {count=8,frame=7,pending=3,limit=CAPTURE_LIGHT_MAX,expected=16,expected_limit=16+CAPTURE_LIGHT_MAX}, // settle frames follow the last that found one pending
        {count=16,frame=8,pending=1,limit=64,expected=17,expected_limit=17+CAPTURE_LIGHT_MAX},
        {count=16,frame=9,pending=0,limit=64,expected=16,expected_limit=64},                           // nothing pending, light settled: as many as it had
        {count=8,frame=7,pending=3,limit=CAPTURE_LIGHT_MAX,waited=wait,expected=8,expected_limit=CAPTURE_LIGHT_MAX}, // texture wait ran out
        {count=8,frame=7,pending=0,light=true,limit=CAPTURE_LIGHT_MAX,expected=9,expected_limit=CAPTURE_LIGHT_MAX},     // GI or exposure still settling extends one frame at a time
        {count=48,frame=47,pending=0,light=true,limit=CAPTURE_LIGHT_MAX,expected=48,expected_limit=CAPTURE_LIGHT_MAX},  // the cap stops runaway loops
        {count=20,frame=19,pending=0,light=false,limit=CAPTURE_LIGHT_MAX,expected=20,expected_limit=CAPTURE_LIGHT_MAX}, // light settled stops immediately
    }
    for c in cases {
        limit:=c.limit
        testing.expect_value(t,capture_frames_settle(c.count,c.frame,8,c.pending,c.light,&limit,c.waited,wait),c.expected)
        testing.expect_value(t,limit,c.expected_limit)
    }
}
