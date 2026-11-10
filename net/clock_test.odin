package mirai_net

import "core:math"
import "core:testing"

// A client that keeps its tick as the engine does: each frame adds its time,
// faster or slower by the dilation the clock asked for, and the clock jumps
// it when it says so. The server is at tick 1000 at time 0.
@(private="file")
Follower :: struct {
    h:^Host,
    local:f64,
    dilation:f64,
    last:i64,          // the last tick simulated
    shown:f64,         // server tick shown in the state of the last tick simulated
    backward:int,      // calls that moved the tick back once it was placed
    display_back:int,  // ticks shown at an older server tick than the one before
    largest_dilation:f64,
}

@(private="file")
follower_init :: proc(f:^Follower) {
    f^={h=new(Host)}
    f.h.front.clock={rate=60,lead=2,delay=2.5,display_jump=CLOCK_JUMP_TICKS,display_max=CLOCK_MAX_DILATION}
}

@(private="file")
follower_frame :: proc(f:^Follower,now,dt,rtt,jitter:f64) {
    clock_sync(&f.h.front.clock,{valid=true,server_tick=u32(1000+(now-rtt*0.5)*60),rtt=rtt,jitter=jitter,time=now})
    f.local+=dt*60*max(1+f.dilation,0)
    placed:=f.h.front.clock.placed
    shift,dilation:=clock_advance(f.h,now,f.local)
    if placed && shift<0 {f.backward+=1}
    f.local+=f64(shift)
    f.last+=shift
    f.dilation=dilation
    if !placed {return}
    f.largest_dilation=max(f.largest_dilation,abs(dilation))
    for f.last<i64(f.local) {
        f.last+=1
        shown:=clock_interpolation_tick(f.h,u32(f.last))
        if shown<f.shown {f.display_back+=1}
        f.shown=shown
    }
}

// The round trip and the jitter the connection measures rise with a spike and
// fall after it, an eighth and a sixteenth a sample.
@(test)
the_tick_of_the_client_never_goes_back_when_a_jitter_spike_ends :: proc(t:^testing.T) {
    f:Follower
    follower_init(&f);defer free(f.h)
    rtt,jitter:=0.1,0.004
    for frame in 0..<2400 {
        spike:=frame>=300 && frame<900
        rtt+=((spike?0.3:0.1)-rtt)*0.125
        jitter+=((spike?0.3:0.004)-jitter)*0.0625
        follower_frame(&f,f64(frame)/60,1.0/60,rtt,jitter)
    }
    c:=clock_state(f.h)
    testing.expect_value(t,f.backward,0)
    testing.expect_value(t,f.display_back,0)
    // The lead the spike asks for rises faster than running faster follows, and the display catches
    // up with its end the same way: a jump forward each.
    testing.expect(t,c.jumps<=2)
    testing.expect(t,f.largest_dilation<=CLOCK_MAX_DILATION)
    // Settled again: ahead of the server by half the trip, twice the jitter and the lead.
    lead:=f64(f.last)-(1000+2399)
    testing.expectf(t,lead>=4 && lead<=7,"lead %v",lead)
    behind:=c.server-c.display
    testing.expectf(t,behind>=5 && behind<=7,"remote objects shown %v ticks behind the server",behind)
}

// The frames stop for a second: the client is far behind, and goes on from
// where it should be in one jump forward.
@(test)
a_client_far_behind_jumps_forward_and_never_back :: proc(t:^testing.T) {
    f:Follower
    follower_init(&f);defer free(f.h)
    for frame in 0..<600 {follower_frame(&f,f64(frame)/60,1.0/60,0.1,0.004)}
    before:=f.last
    for frame in 600..<660 {
        now:=f64(frame)/60
        clock_sync(&f.h.front.clock,{valid=true,server_tick=u32(1000+(now-0.05)*60),rtt=0.1,jitter=0.004,time=now})
    }
    for frame in 660..<1200 {follower_frame(&f,f64(frame)/60,1.0/60,0.1,0.004)}
    c:=clock_state(f.h)
    testing.expect_value(t,f.backward,0)
    testing.expect_value(t,f.display_back,0)
    testing.expect(t,c.jumps>=1 && c.jumps<=2)
    testing.expect(t,f.last-before>=595)
    lead:=f64(f.last)-(1000+1199)
    testing.expectf(t,lead>=4 && lead<=7,"lead %v",lead)
}

// While the jitter rises the display falls behind slower than real time, and
// it catches up faster when the jitter falls, without going back.
@(test)
remote_objects_are_shown_further_behind_with_more_jitter :: proc(t:^testing.T) {
    f:Follower
    follower_init(&f);defer free(f.h)
    jitter:=0.004
    deepest:=0.0
    for frame in 0..<2400 {
        jitter+=((frame>=600 && frame<1500?0.04:0.004)-jitter)*0.0625
        follower_frame(&f,f64(frame)/60,1.0/60,0.1,jitter)
        if frame==1499 {deepest=clock_state(f.h).server-clock_state(f.h).display}
    }
    c:=clock_state(f.h)
    testing.expect_value(t,f.display_back,0)
    testing.expectf(t,deepest>=9 && deepest<=11,"with 40 ms of jitter, %v ticks behind",deepest)
    testing.expectf(t,c.server-c.display<=7,"%v ticks behind once the jitter fell",c.server-c.display)
}

// The server pauses, then runs at half speed: its tick as the client estimates
// it stands still while paused and goes at the server's pace after, and so
// does the tick the client should be at.
@(test)
the_estimate_of_the_server_stands_still_while_it_pauses_and_follows_its_scale :: proc(t:^testing.T) {
    h:=new(Host);defer free(h)
    h.front.clock={rate=60,lead=2,delay=2.5,scale=1}
    rtt:=0.1
    server,local,dilation:=1000.0,0.0,0.0
    frame :: proc(h:^Host,now,server,rtt:f64,local,dilation:^f64,paused:bool,scale:f32) {
        pace:=paused?0:60*f64(scale)
        clock_sync(&h.front.clock,{valid=true,server_tick=u32(server-rtt*0.5*pace),rtt=rtt,jitter=0.002,time=now,paused=paused,scale=scale})
        local^+=pace/60*max(1+dilation^,0)
        shift,next:=clock_advance(h,now,local^)
        local^+=f64(shift)
        dilation^=next
    }
    now:=0.0
    for _ in 0..<300 {
        now+=1.0/60
        server+=1
        frame(h,now,server,rtt,&local,&dilation,false,1)
    }
    paused_at:=server
    wanted:=clock_target(&h.front.clock)
    for _ in 0..<120 {
        now+=1.0/60
        frame(h,now,server,rtt,&local,&dilation,true,1)
        testing.expectf(t,h.front.clock.server<=paused_at+1,"the server stands at %v and is estimated at %v",paused_at,h.front.clock.server)
        testing.expect(t,clock_target(&h.front.clock)<=wanted+0.5,"the tick the client should be at does not run ahead")
    }
    for _ in 0..<240 {
        now+=1.0/60
        server+=0.5
        frame(h,now,server,rtt,&local,&dilation,false,0.5)
    }
    testing.expectf(t,abs(h.front.clock.server-server)<1,"at half speed the server is at %v and estimated at %v",server,h.front.clock.server)
    testing.expect(t,!h.front.clock.paused && h.front.clock.scale==0.5)
}

// A display that fell behind jumps at display_jump instead of 30 ticks, and
// catches up at display_dilation instead of a tenth.
@(test)
the_display_jumps_and_dilates_as_the_replication_asks :: proc(t:^testing.T) {
    h:=new(Host)
    defer free(h)
    h.desc.tick_rate=128
    h.desc.replication.input_lead=5
    h.desc.replication.interpolation_delay=2.5
    h.desc.replication.display_jump=0.15
    h.desc.replication.display_dilation=0.2
    clock_init(&h.front.clock,h)
    c:=&h.front.clock
    testing.expect(t,abs(c.display_jump-19.2)<1e-4 && abs(c.display_max-0.2)<1e-6)
    clock_sync(c,{valid=true,server_tick=1000,rtt=0.1,jitter=0,time=0})
    // The client's tick where the clock puts it, then still.
    shift,_:=clock_advance(h,0,0)
    local:=f64(shift)
    clock_advance(h,0.001,local)
    // 25 ticks behind: under the default 30, over these 19.2.
    c.display-=25
    jumps:=c.jumps
    clock_advance(h,0.002,local)
    testing.expect(t,c.jumps==jumps+1)
    c.display-=10
    clock_advance(h,0.003,local)
    testing.expectf(t,abs(c.display_dilation-0.2)<1e-6,"dilation %v",c.display_dilation)
}

// The input a client sends on each tick, and what the server does with it.
@(private="file")
Toy :: struct {position,velocity:[2]f32}
@(private="file")
toy_simulate :: proc(toy:^Toy,input:Test_Input) {
    toy.velocity+=(input.move*6-toy.velocity)*0.2
    if input.buttons&1!=0 {toy.velocity.y+=3}
    toy.position+=toy.velocity*f32(TEST_STEP)
}
@(private="file")
toy_input :: proc(tick:u32) -> Test_Input {
    return {move={math.sin(f32(tick)*0.05),math.cos(f32(tick)*0.031)},buttons=tick%97==0?1:0}
}

@(private="file")
Session :: struct {
    s:^Scene,
    server_tick:u32,
    server_toy:Toy,
    published:Test_Transform, // what the server replicates of its toy
    fresh,repeated,none:int,
    last_client_tick:u32,
    ticks:Test_Ticks,
}
// One 60 Hz frame: the server simulates its tick with the input it has, the client sends the ticks its clock asks for.
@(private="file")
session_frame :: proc(t:^testing.T,x:^Session) {
    s:=x.s
    server,client:=s.server,s.clients[0]
    for &command in host_poll(server) {}
    x.server_tick+=1
    input:Test_Input
    switch input_take(server,s.on_server[0],x.server_tick,&input) {
    case .Fresh:    x.fresh+=1
    case .Repeated: x.repeated+=1
    case .None:     x.none+=1
    }
    toy_simulate(&x.server_toy,input)
    x.published.position={x.server_toy.position.x,0,x.server_toy.position.y}
    x.published.velocity={x.server_toy.velocity.x,0,x.server_toy.velocity.y}
    host_publish(server,x.server_tick)
    for &command in host_poll(client) {}
    first,steps:=test_ticks(&x.ticks,client,s.w.now)
    for step in 0..<u32(steps) {
        tick:=first+step
        mine:=toy_input(tick)
        testing.expect_value(t,input_submit(client,tick,&mine),Error.None)
        host_publish(client,tick)
        x.last_client_tick=tick
    }
    test_step(&s.w)
}
@(private="file")
session_init :: proc(x:^Session,s:^Scene,conditions:Sim_Conditions) {
    x^={s=s}
    x.published.rotation=quaternion(w=1,x=0,y=0,z=0)
    object_create(s.server,{type=s.tp.prop,sources={0=&x.published},owner=s.on_server[0],poll=true})
    sim_endpoint_conditions(&s.w.sim,0,conditions)
    sim_endpoint_conditions(&s.w.sim,1,conditions)
}

@(test)
client_clock_runs_ahead_of_the_server_so_inputs_arrive_in_time :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=8},seed=9);defer scene_destroy(s)
    x:=new(Session);defer free(x)
    session_init(x,s,{latency=0.05,jitter=0.004})
    for _ in 0..<240 {session_frame(t,x)}
    clock:=clock_state(s.clients[0])
    testing.expect(t,clock.synced)
    x.fresh,x.repeated,x.none=0,0,0
    for _ in 0..<600 {session_frame(t,x)}
    testing.expect(t,x.fresh>=594)
    clock=clock_state(s.clients[0])
    // Ahead of the tick the server is on by the trip of an input, about three ticks, plus the margin.
    lead:=f64(x.last_client_tick)-f64(x.server_tick)
    testing.expectf(t,lead>=4 && lead<=8,"lead %v rtt %v bias %v",lead,clock.rtt,clock.bias)
    testing.expect(t,abs(clock.dilation)<0.03)
    testing.expect(t,abs(clock.rtt-0.1)<0.03)
    testing.expect(t,abs(clock.server-f64(x.server_tick))<2)
    testing.expect_value(t,clock.jumps,u32(0))
    behind:=clock.server-clock.display
    testing.expect(t,behind>4 && behind<8)
    stats,_:=connection_stats(s.server,s.on_server[0])
    testing.expect(t,stats.inputs_received>800 && stats.inputs_missed==0)

    // The link gets slower: the clock follows by running faster for a while, without jumping.
    sim_endpoint_conditions(&s.w.sim,0,{latency=0.11,jitter=0.004})
    sim_endpoint_conditions(&s.w.sim,1,{latency=0.11,jitter=0.004})
    for _ in 0..<600 {session_frame(t,x)}
    x.fresh,x.repeated=0,0
    for _ in 0..<300 {session_frame(t,x)}
    testing.expect(t,x.fresh>=297)
    testing.expectf(t,f64(x.last_client_tick)-f64(x.server_tick)>=lead+3,"lead %v after %v",f64(x.last_client_tick)-f64(x.server_tick),lead)
    testing.expect_value(t,clock_state(s.clients[0]).jumps,u32(0))

    // Redundancy covers lost datagrams.
    sim_endpoint_conditions(&s.w.sim,1,{latency=0.11,jitter=0.004,loss=0.2})
    x.fresh,x.repeated=0,0
    for _ in 0..<600 {session_frame(t,x)}
    testing.expect(t,x.fresh>=560)
}
