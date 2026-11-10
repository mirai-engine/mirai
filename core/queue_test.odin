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

// A request pushed for later is taken at its tick, after what was pushed
// before it, by the owner that takes with take_due. It is plain data of the
// World: a rollback to a copy taken before brings it back, with the clock. An
// owner that takes with take refuses it instead of keeping it for ever.
@(test)
a_request_pushed_for_later_is_taken_at_its_tick_and_rolls_back :: proc(t:^testing.T) {
    World :: struct {using world:Test_World,time:Time,requests:Clock_Requests}
    w,kept:World
    if !test_world_init(t,&w) || !test_world_init(t,&kept) {return}
    defer test_world_destroy(&w)
    defer test_world_destroy(&kept)
    w.time={tick=10,dt=1.0/60,playing=true}
    later(&w.requests.queue,w.time,1,Clock_Request{kind=.Scale,scale=2})
    later(&w.requests.queue,w.time,0.5,Clock_Request{kind=.Pause})
    push(&w.requests.queue,Clock_Request{kind=.Resume})
    if !testing.expect(t,test_world_copy(&kept,&w)) {return}
    for round in 0..<2 {
        taken:=make([dynamic]Clock_Request,context.temp_allocator)
        at:=make([dynamic]u64,context.temp_allocator)
        for w.time.tick<100 {
            for request in take_due(&w.requests.queue,w.time) {
                append(&taken,request)
                append(&at,w.time.tick)
            }
            time_advance(&w.time)
        }
        testing.expectf(t,len(taken)==3 && taken[0].kind==.Resume && taken[1].kind==.Pause && taken[2].kind==.Scale,"round %d: %v",round,taken[:])
        testing.expectf(t,len(at)==3 && at[0]==10 && at[1]==40 && at[2]==70,"round %d: %v",round,at[:])
        testing.expect_value(t,len(w.requests.queue.waiting),0)
        // Back to the copy: the clock and what waited come with it.
        if !testing.expect(t,test_world_copy(&w,&kept)) {return}
        testing.expect_value(t,w.time.tick,u64(10))
    }
    testing.expect_value(t,len(take(&w.requests.queue)),1)
    testing.expect_value(t,w.requests.queue.refused,2)
    testing.expect_value(t,len(w.requests.queue.waiting),0)
}
