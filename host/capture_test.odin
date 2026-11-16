package host

import "core:testing"
import "core:time"

@(test)
a_capture_goes_on_while_textures_are_pending_until_its_wait_runs_out :: proc(t:^testing.T) {
    wait:=time.Second
    cases:=[?]struct{count,frame,pending:int,waited:time.Duration,expected:int}{
        {count=8,frame=7,pending=3,expected=16},   // settle frames follow the last that found one pending
        {count=16,frame=8,pending=1,expected=17},
        {count=16,frame=9,pending=0,expected=16},  // nothing pending: as many as it had
        {count=8,frame=7,pending=3,waited=wait,expected=8}, // the wait ran out
    }
    for c in cases {
        testing.expect_value(t,capture_frames_streaming(c.count,c.frame,8,c.pending,c.waited,wait),c.expected)
    }
}
