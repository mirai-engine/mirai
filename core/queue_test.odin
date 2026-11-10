package core

import "core:strings"
import "core:testing"

// A queue of requests keeps the room its owner reserved: what does not fit is
// counted, reported once with what raises it, and never grows the queue.
@(test)
a_full_request_queue_drops_counts_and_reports_once :: proc(t:^testing.T) {
    q:Queue(int);defer delete(q.items)
    problems:Problems
    queue_serve(&q,2,&problems,"test.requests","numbers","Test_Settings.room","it is a number")
    testing.expect_value(t,cap(q.items),2)
    for i in 0..<3 {offer(&q,i)}
    refuse(&q)
    testing.expect_value(t,len(q.items),2)
    testing.expect_value(t,q.dropped,1)
    testing.expect_value(t,q.refused,1)
    queue_serve(&q,2,&problems,"test.requests","numbers","Test_Settings.room","it is a number")
    testing.expect_value(t,q.dropped,0)
    testing.expect_value(t,q.refused,0)
    testing.expect_value(t,cap(q.items),2)
    p:=problem_find(&problems,NONE,"test.requests")
    if testing.expect(t,p!=nil) {testing.expect(t,strings.contains(problem_text(p),"Test_Settings.room"))}
    queue_serve(&q,2,&problems,"test.requests","numbers","Test_Settings.room","it is a number")
    testing.expect_value(t,p.count,u64(2))
}

// Asked before its owner served it, a queue still takes what is asked.
@(test)
a_request_queue_takes_what_comes_before_its_owner_reserves_room :: proc(t:^testing.T) {
    q:Queue(int);defer delete(q.items)
    offer(&q,7)
    testing.expect_value(t,len(q.items),1)
    testing.expect_value(t,q.dropped,0)
}
