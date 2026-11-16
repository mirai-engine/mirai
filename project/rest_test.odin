package project

import "core:testing"

// A burst of changes writes once, after a look finds it rested; a value that
// never rests is written every REST_LOOKS looks; nothing is looked at while
// busy; a change back to what the file holds writes nothing; the flush writes
// what is left.
@(test)
a_file_is_written_once_a_burst_of_changes_rests :: proc(t:^testing.T) {
    r:Rest
    rest_init(&r,1)
    writes:=0
    step :: proc(r:^Rest,hash:u64,dt:f32,busy:=false) -> bool {return rest_look(r,dt,busy) && rest_due(r,hash)}

    testing.expect(t,!step(&r,1,REST_LOOK),"nothing changed")
    for hash in u64(2)..=8 {
        if step(&r,hash,REST_LOOK/4) {writes+=1}
    }
    testing.expect_value(t,writes,0)
    testing.expect(t,!step(&r,8,REST_LOOK,busy=true),"no look during a gesture")
    testing.expect(t,!step(&r,8,REST_LOOK),"the look that finds the last change waits")
    testing.expect(t,!step(&r,8,REST_LOOK/2),"not a look yet")
    testing.expect(t,step(&r,8,REST_LOOK/2),"the burst rested: written once")
    testing.expect(t,!step(&r,8,REST_LOOK),"once")

    for look in 0..<REST_LOOKS-1 {testing.expectf(t,!step(&r,u64(20+look),REST_LOOK),"look %d of a value that never rests",look)}
    testing.expect(t,step(&r,99,REST_LOOK),"a value that never rests is written all the same")

    testing.expect(t,!step(&r,50,REST_LOOK) && !step(&r,99,REST_LOOK) && !step(&r,99,REST_LOOK),"back to what the file holds")
    testing.expect(t,!rest_flush(&r,99))
    testing.expect(t,rest_flush(&r,7) && !rest_flush(&r,7))
}
