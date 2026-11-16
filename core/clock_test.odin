package core

import "core:testing"

// The game pauses, resumes and scales its clock, also on a server; a scale out
// of range and a request on a client leave it as it was and say why.
@(test)
the_clock_follows_what_the_game_asks_and_refuses_the_rest :: proc(t:^testing.T) {
    requests:Clock_Requests
    defer delete(requests.queue.items)
    clock:=CLOCK_DEFAULT
    network:Network
    problems:Problems

    pause(&requests)
    time_scale(&requests,0.25)
    clock_requests(&requests,&clock,{&network},&problems)
    testing.expect(t,clock.paused)
    testing.expect_value(t,clock.scale,f32(0.25))

    resume(&requests)
    time_scale(&requests,0)
    time_scale(&requests,CLOCK_SCALE_MAX*2)
    clock_requests(&requests,&clock,{&network},&problems)
    testing.expect(t,!clock.paused)
    testing.expect_value(t,clock.scale,f32(0.25))
    testing.expect_value(t,problems.count,1)

    network.role=.Server
    pause(&requests)
    clock_requests(&requests,&clock,{&network},&problems)
    testing.expect(t,clock.paused,"the server keeps the clock of every end")
    resume(&requests)
    clock_requests(&requests,&clock,{&network},&problems)

    network.role=.Client
    pause(&requests)
    clock_requests(&requests,&clock,{&network},&problems)
    testing.expect(t,!clock.paused)
    testing.expect_value(t,problems.count,2)

    // The network of a client follows the clock of the server.
    clock_follow(&requests,true,0.5)
    clock_requests(&requests,&clock,{&network},&problems)
    testing.expect(t,clock.paused && clock.scale==0.5)
    clock_follow(&requests,false,0)
    clock_requests(&requests,&clock,{&network},&problems)
    testing.expect(t,clock.paused && clock.scale==0.5)
    testing.expect_value(t,problem_find(&problems,NONE,"core.clock_scale").count,u64(3))
}
