package mirai_anim

import "core:testing"

@(test)
marker_fractions_preserve_requested_time_through_clamps_loops_reverse_and_ping_pong :: proc(t:^testing.T) {
    lib:=make_library(t);defer library_destroy(&lib)
    once:=timed_clip(&lib,.Once,1,{{time=.9,id=1},{time=1,id=2}})
    player:=player_make(once);player.time=.75;player.fresh=false
    events:[16]Event;count,dropped:=player_advance(&lib,&player,1,events[:])
    testing.expect(t,count==2 && dropped==0 && near(events[0].fraction,.15) && near(events[1].fraction,.25))
    loop:=timed_clip(&lib,.Loop,1,{{time=.2,id=1},{time=.8,id=2}})
    player=player_make(loop);player.time=.8;player.fresh=false
    count,dropped=player_advance(&lib,&player,2.5,events[:]);testing.expect(t,count==5 && dropped==0)
    fractions:=[5]f32{.16,.4,.56,.8,.96}
    for event,i in events[:count] {testing.expect(t,near(event.fraction,fractions[i]))}
    player=player_make(loop,-1);player.time=.8;player.fresh=false
    count,dropped=player_advance(&lib,&player,1.5,events[:])
    testing.expect(t,count==2 && dropped==0 && near(events[0].fraction,.4) && near(events[1].fraction,2.0/3))
    ping:=timed_clip(&lib,.Ping_Pong,1,{{time=.2,id=1},{time=.8,id=2}})
    player=player_make(ping);player.time=.9;player.fresh=false
    count,dropped=player_advance(&lib,&player,1.5,events[:])
    testing.expect(t,count==3 && dropped==0 && near(events[0].fraction,.2) && near(events[1].fraction,.6) && near(events[2].fraction,13.0/15))
}

// A clip of one float track that goes from 0 to `duration`, with markers.
timed_clip :: proc(lib:^Library,loop:Loop,duration:f32,markers:[]Marker={}) -> Clip {
    clip,_:=clip_add(lib,{loop=loop,tracks={{target=1,property=.Float,keys={key(0,0),key(duration,duration)}}},markers=markers})
    return clip
}

advance_collect :: proc(lib:^Library,p:^Player,dt:f32,out:^[dynamic]u32) -> int {
    events:[16]Event
    written,dropped:=player_advance(lib,p,dt,events[:])
    for e in events[:written] {append(out,e.id)}
    return dropped
}

@(test)
player_once_stops_at_the_end_and_reports_it :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    clip:=timed_clip(&lib,.Once,2)
    p:=player_make(clip)
    player_advance(&lib,&p,1.5,nil)
    testing.expect(t,!p.done && near(player_time(&lib,p),1.5) && near(player_normalized(&lib,p),0.75))
    player_advance(&lib,&p,1.5,nil)
    testing.expect(t,p.done && near(player_time(&lib,p),2) && near(player_normalized(&lib,p),1))
    player_advance(&lib,&p,1,nil)
    testing.expect(t,near(player_time(&lib,p),2))
    player_restart(&lib,&p)
    testing.expect(t,!p.done && p.fresh && near(player_time(&lib,p),0))
}

@(test)
player_loop_wraps_and_ping_pong_turns_around :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    loop:=player_make(timed_clip(&lib,.Loop,2),2)
    player_advance(&lib,&loop,1.25,nil)
    testing.expect(t,near(player_time(&lib,loop),0.5) && !loop.done)
    ping:=player_make(timed_clip(&lib,.Ping_Pong,2))
    player_advance(&lib,&ping,2.5,nil)
    testing.expect(t,near(player_time(&lib,ping),1.5))
    player_advance(&lib,&ping,2,nil)
    testing.expect(t,near(player_time(&lib,ping),0.5))
    player_advance(&lib,&ping,100000,nil)
    testing.expect(t,player_time(&lib,ping)>=0 && player_time(&lib,ping)<=2)
}

@(test)
player_plays_backwards_with_a_negative_speed :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    p:=player_make(timed_clip(&lib,.Once,2),-1)
    player_restart(&lib,&p)
    testing.expect(t,near(player_time(&lib,p),2))
    player_advance(&lib,&p,0.5,nil)
    testing.expect(t,near(player_time(&lib,p),1.5) && !p.done)
    player_advance(&lib,&p,5,nil)
    testing.expect(t,near(player_time(&lib,p),0) && p.done)
    loop:=player_make(timed_clip(&lib,.Loop,2),-1)
    player_advance(&lib,&loop,0.5,nil)
    testing.expect(t,near(player_time(&lib,loop),1.5))
}

@(test)
player_with_an_invalid_clip_does_nothing :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    p:=player_make(0)
    events:[2]Event
    written,dropped:=player_advance(&lib,&p,1,events[:])
    testing.expect(t,written==0 && dropped==0 && player_time(&lib,p)==0 && player_normalized(&lib,p)==1)
    missing:=player_make(9)
    written,dropped=player_advance(&lib,&missing,1,events[:])
    testing.expect(t,written==0 && dropped==0)
}

@(test)
events_fire_once_when_playback_crosses_their_marker :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    clip:=timed_clip(&lib,.Once,1,{{0,1,0},{0.5,2,0},{1,3,0}})
    p:=player_make(clip,1,0.75)
    out:[dynamic]u32
    defer delete(out)
    advance_collect(&lib,&p,0.25,&out)
    testing.expect_value(t,len(out),1) // the start counts once
    advance_collect(&lib,&p,0,&out)
    testing.expect_value(t,len(out),1)
    advance_collect(&lib,&p,0.25,&out) // reaches 0.5 exactly
    testing.expect_value(t,len(out),2)
    advance_collect(&lib,&p,0.125,&out)
    testing.expect_value(t,len(out),2)
    events:[4]Event
    written,_:=player_advance(&lib,&p,5,events[:])
    testing.expect(t,written==1 && events[0].id==3 && events[0].clip==clip && near(events[0].time,1) && near(events[0].weight,0.75))
    written,_=player_advance(&lib,&p,5,events[:])
    testing.expect_value(t,written,0)
}

@(test)
loop_fires_the_markers_at_both_ends_once_per_pass :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    p:=player_make(timed_clip(&lib,.Loop,1,{{0,10,0},{0.5,11,0},{1,12,0}}))
    counts:[3]int
    for _ in 0..<24 {
        out:[dynamic]u32
        advance_collect(&lib,&p,0.125,&out)
        for id in out {counts[id-10]+=1}
        delete(out)
    }
    testing.expect_value(t,counts[0],4) // the start, and each wrap
    testing.expect_value(t,counts[1],3)
    testing.expect_value(t,counts[2],3)
}

@(test)
ping_pong_fires_each_marker_on_the_way_out_and_on_the_way_back :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    p:=player_make(timed_clip(&lib,.Ping_Pong,1,{{0,10,0},{0.25,11,0},{1,12,0}}))
    counts:[3]int
    order:[dynamic]u32
    defer delete(order)
    for _ in 0..<16 {
        events:[4]Event
        written,_:=player_advance(&lib,&p,0.125,events[:])
        for e in events[:written] {counts[e.id-10]+=1;if e.id==11 {append(&order,u32(e.time*100))}}
    }
    testing.expect_value(t,counts[0],2) // the start and the end of the second pass
    testing.expect_value(t,counts[1],2) // out at 0.25 and back at 1.75
    testing.expect_value(t,counts[2],1) // the turnaround counts once
    testing.expect_value(t,len(order),2)
}

@(test)
backward_playback_fires_markers_in_reverse_order :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    p:=player_make(timed_clip(&lib,.Once,1,{{0.25,1,0},{0.5,2,0},{0.75,3,0},{1,4,0}}),-1)
    player_restart(&lib,&p)
    out:[dynamic]u32
    defer delete(out)
    advance_collect(&lib,&p,0.5,&out)
    testing.expect(t,len(out)==3 && out[0]==4 && out[1]==3 && out[2]==2)
    advance_collect(&lib,&p,1,&out)
    testing.expect(t,len(out)==4 && out[3]==1 && p.done)
}

@(test)
one_long_advance_reports_every_pass_in_order_and_counts_what_does_not_fit :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    clip:=timed_clip(&lib,.Loop,1,{{0.5,5,0}})
    p:=player_make(clip)
    events:[8]Event
    written,dropped:=player_advance(&lib,&p,2.75,events[:])
    testing.expect(t,written==3 && dropped==0 && near(player_time(&lib,p),0.75))
    p=player_make(clip)
    written,dropped=player_advance(&lib,&p,2.75,events[:2])
    testing.expect(t,written==2 && dropped==1)
    p=player_make(clip)
    written,dropped=player_advance(&lib,&p,1e9,events[:])
    testing.expect(t,written==8 && dropped>=1000)
    testing.expect(t,player_time(&lib,p)>=0 && player_time(&lib,p)<1)
}
