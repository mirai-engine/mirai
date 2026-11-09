package api

import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(private="file")
Silent_Editor :: struct {listener:net.TCP_Socket, close:bool}

// Accepts one connection and reads the request. It never answers: it closes
// the connection when close is set, or keeps it open until the client leaves.
@(private="file")
silent_editor_run :: proc(t:^thread.Thread) {
    editor:=(^Silent_Editor)(t.data)
    socket,_,accept_error:=net.accept_tcp(editor.listener)
    if accept_error!=nil {return}
    defer net.close(socket)
    chunk:[4096]u8
    for {
        n,err:=net.recv_tcp(socket,chunk[:])
        if err!=nil || n==0 {return}
        if editor.close && strings.contains(string(chunk[:n]),"\r\n\r\n") {return}
    }
}

@(private="file")
silent_post :: proc(t:^testing.T,close:bool,timeout_ms:int,watch:=Client_Watch{}) -> (error:Error,elapsed:time.Duration,ok:bool) {
    listener,listen_error:=net.listen_tcp({address=net.IP4_Loopback,port=0},1)
    if !testing.expect(t,listen_error==nil) {return}
    defer net.close(listener)
    endpoint,endpoint_error:=net.bound_endpoint(listener)
    if !testing.expect(t,endpoint_error==nil) {return}
    editor:=Silent_Editor{listener,close}
    worker:=thread.create(silent_editor_run)
    worker.data=&editor
    thread.start(worker)
    defer thread.destroy(worker)
    started:=time.tick_now()
    status,response,post_error:=client_post(endpoint.port,"/rpc",`{}`,timeout_ms,context.temp_allocator,watch=watch)
    elapsed=time.tick_since(started)
    thread.join(worker)
    testing.expect_value(t,status,0)
    testing.expect(t,response==nil)
    return post_error,elapsed,true
}

// The wait goes on while the editor uses CPU and hung is the time without any:
// the moments are given, so the test does not wait them.
@(test)
a_wait_goes_on_while_the_process_works_and_a_silent_one_has_hung :: proc(t:^testing.T) {
    start:=time.tick_now()
    at :: proc(start:time.Tick,seconds:int) -> time.Tick {return time.tick_add(start,time.Duration(seconds)*time.Second)}
    waiting:Client_Waiting
    testing.expect(t,!client_hung(&waiting,7,start),"the first reading says nothing")
    testing.expect(t,!client_hung(&waiting,7,at(start,CLIENT_HUNG_SECONDS-1)),"not yet")
    testing.expect(t,!client_hung(&waiting,8,at(start,CLIENT_HUNG_SECONDS*2)),"it worked meanwhile: the count starts over")
    testing.expect(t,!client_hung(&waiting,8,at(start,CLIENT_HUNG_SECONDS*3-1)),"not yet again")
    testing.expect(t,client_hung(&waiting,8,at(start,CLIENT_HUNG_SECONDS*3)),"no CPU for the whole time")
}

// A build of minutes says so a few times, not every half minute.
@(test)
each_notice_of_a_long_wait_comes_twice_as_late_as_the_last :: proc(t:^testing.T) {
    noticed,interval,notices:=0,0,0
    for notices<8 && client_notice_next(noticed)<600 {
        next:=client_notice_next(noticed)
        if interval>0 {testing.expect_value(t,next-noticed,2*interval)}
        interval,noticed=next-noticed,next
        notices+=1
    }
    testing.expectf(t,notices>0 && notices<=4,"%d notices in ten minutes",notices)
}

@(test)
a_process_says_its_work_or_that_it_ended :: proc(t:^testing.T) {
    first:=process_sample(os.get_pid())
    testing.expect(t,first.known && !first.gone,"this process runs")
    start:=time.tick_now()
    spun:=0
    for time.tick_since(start)<100*time.Millisecond {spun+=1}
    second:=process_sample(os.get_pid())
    testing.expectf(t,second.work!=first.work && spun>0,"work grows while it runs: %d %d",first.work,second.work)
    testing.expect(t,process_sample(NO_PROCESS).gone,"nothing runs with that pid")
}

// An editor whose process died answers nothing: the wait ends at once, whatever its limit.
@(test)
a_wait_for_an_editor_whose_process_ended_ends_at_once_saying_so :: proc(t:^testing.T) {
    ended,elapsed,ok:=silent_post(t,false,60000,{pid=NO_PROCESS,log="session.log"})
    if !ok {return}
    testing.expect_value(t,ended.code,CLOSED)
    testing.expectf(t,strings.contains(ended.message,"ended before answering") && strings.contains(ended.message,"session.log"),"%s",ended.message)
    testing.expectf(t,elapsed<10*time.Second,"a process that ended does not wait for the limit: %v",elapsed)
}

@(private="file")
NO_PROCESS :: 0x7FFFFFF0

@(test)
an_editor_that_does_not_answer_in_time_is_a_timeout_and_one_that_closes_is_not :: proc(t:^testing.T) {
    silent,elapsed,ok:=silent_post(t,false,200)
    if !ok {return}
    testing.expect_value(t,silent.code,TIMEOUT)
    testing.expectf(t,strings.contains(silent.message,"did not answer in 200 ms"),"%s",silent.message)
    testing.expectf(t,elapsed>=150*time.Millisecond && elapsed<5*time.Second,"the timeout ends the wait: %v",elapsed)
    closed,closed_elapsed,closed_ok:=silent_post(t,true,5000)
    if !closed_ok {return}
    testing.expect_value(t,closed.code,CLOSED)
    testing.expectf(t,strings.contains(closed.message,"closed the connection without answering"),"%s",closed.message)
    testing.expectf(t,closed_elapsed<4*time.Second,"a closed connection does not wait for the timeout: %v",closed_elapsed)
}
