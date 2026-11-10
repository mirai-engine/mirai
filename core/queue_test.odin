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

// An occurrence reaches each reader once, whatever its cadence: a function of
// the tick, one of the frame and one of late that reads before the owner
// runs, with frames at half and at four times the pace of the ticks, with
// frames that run no tick, and in a World copied from this one, which goes on
// from its own cursor. What is filled outside the ticks waits for one.
@(test)
an_occurrence_reaches_each_reader_once_at_any_cadence :: proc(t:^testing.T) {
    Reader :: struct {cursor:u64,seen:[dynamic]int}
    read :: proc(r:^Reader,log:Events(int)) {
        view:=log
        events_read(&view,&r.cursor)
        append(&r.seen,..view.items[:])
    }
    exact :: proc(t:^testing.T,r:Reader,count:int,who:string,loc:=#caller_location) {
        testing.expectf(t,len(r.seen)==count,"%s saw %d of %d",who,len(r.seen),count,loc=loc)
        for value,i in r.seen {if value!=i {testing.expectf(t,false,"%s saw %d at %d",who,value,i,loc=loc);break}}
    }
    // ticks_per_frame: ticks a frame runs; frames_per_tick: frames for each of those.
    cadences:=[?][2]int{{1,1},{2,1},{5,1},{1,4},{0,1}}
    for cadence in cadences {
        ticked,framed:Events(int)
        fixed,frame,late,copied,waiting:Reader
        defer {delete(ticked.items);delete(framed.items);delete(fixed.seen);delete(frame.seen);delete(late.seen);delete(copied.seen);delete(waiting.seen)}
        pushed,asked,frames,at_copy:=0,0,0,0
        other:Events(int);defer delete(other.items)
        for frames<40 {
            ticks:=cadence[0]
            if cadence[1]>1 && frames%cadence[1]!=0 {ticks=0}
            read(&late,ticked) // before the owner: it reads what the frame before left
            for _ in 0..<ticks {
                read(&waiting,framed)
                push(&ticked,pushed);pushed+=1
                read(&fixed,ticked)
            }
            read(&frame,ticked)
            push(&framed,asked);asked+=1
            if frames==20 {
                testing.expect(t,value_copy(&other,&ticked,type_info_of(Events(int))))
                copied.cursor,at_copy=frame.cursor,pushed
                append(&copied.seen,..frame.seen[:])
            }
            events_age(&ticked)
            if ticks>0 {events_age(&framed)}
            frames+=1
        }
        read(&late,ticked);read(&copied,other)
        exact(t,fixed,pushed,"the function of the tick");exact(t,frame,pushed,"the function of the frame");exact(t,late,pushed,"the function of late")
        if cadence[0]>0 {
            read(&waiting,framed)
            testing.expect(t,len(waiting.seen)>=asked-cadence[1] && len(ticked.items)<=3*max(cadence[0],1),"a log holds what the last two frames pushed")
            for value,i in waiting.seen {testing.expect_value(t,value,i)}
        } else {
            testing.expect_value(t,len(framed.items),asked)
        }
        exact(t,copied,at_copy,"the function of the frame in the copy")
    }
}

// A log gives each reader every entry once, whatever trims it (a room, as the
// gone of a table and the moved of the Hierarchy, or the age of Events): one
// that reads after each push and one that reads less often than the log is
// trimmed get each entry; one that fell behind the trim, or holds a cursor of
// another log, reads it whole and goes on from the present, as one added late.
@(test)
a_log_gives_each_reader_every_entry_once :: proc(t:^testing.T) {
    Trim :: enum {Room,Age}
    for trim in Trim {
        log:Events(int);defer delete(log.items)
        each,slow,behind:u64
        seen:[dynamic]int;defer delete(seen)
        _,_=log_since(log.log,&behind)
        for i in 0..<100 {
            if trim==.Room {log_push(&log.log,i,8)} else {events_push(&log,i)}
            items,whole:=log_since(log.log,&each)
            testing.expectf(t,!whole && len(items)==1 && items[0]==i,"%v: the reader of each push got %v",trim,items)
            if i%3!=2 {continue}
            items,whole=log_since(log.log,&slow)
            testing.expect(t,!whole)
            append(&seen,..items)
            if trim==.Age {events_age(&log)}
        }
        for value,i in seen {if value!=i {testing.expectf(t,false,"%v: the slow reader got %d at %d",trim,value,i);break}}
        testing.expectf(t,len(seen)==99,"%v: the slow reader got %d",trim,len(seen))
        late:u64
        for cursor in ([2]^u64{&behind,&late}) {
            items,whole:=log_since(log.log,cursor)
            testing.expectf(t,whole && len(items)==len(log.items),"%v: one behind reads what it holds, whole",trim)
        }
        log_push(&log.log,100)
        for cursor in ([3]^u64{&behind,&late,&each}) {
            items,whole:=log_since(log.log,cursor)
            testing.expect(t,!whole && len(items)==1 && items[0]==100)
        }
        ahead:=max(u64)
        items,whole:=log_since(log.log,&ahead)
        testing.expect(t,whole && len(items)==0 && ahead==log_end(log.log),"a cursor past the end gets nothing and goes on from here")
        log_drop(&log.log,-1)
        log_drop(&log.log,1<<40)
        testing.expect(t,len(log.items)==0 && log.first==ahead)
        log_reset(&log.log,max(u64)-1)
        items,whole=log_since(log.log,&ahead)
        testing.expect(t,whole && len(items)==0)
    }
}
