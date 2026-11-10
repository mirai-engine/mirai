package multiplayer

import "core:math"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:std/serial"

// With an input delay of three ticks, a button pressed in tick 5 is what the
// client sends for tick 8, and its seat acts on it in tick 8, with the edge
// of that tick; a tick that runs again acts on the same.
@(test)
an_input_delay_acts_on_what_the_devices_gave_that_many_ticks_ago :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    w:Net_Test_World
    net_test_init(&w,&info)
    defer core.world_destroy(&info,.World,&w)
    seat:=net_test_player(&w,&info)
    s:Net_Session
    s.host_ready,s.mode,s.desc.input_delay=true,.Client,3
    s.client.taken=make([]Taken,16);defer delete(s.client.taken)
    fire :: proc(w:^Net_Test_World,seat:core.Entity) -> inp.Action_State {return inp.seat_action(core.read(&w.seats),seat,NET_TEST_FIRE)}
    tick :: proc(s:^Net_Session,w:^Net_Test_World,at:u64,down:bool,again:=false) {
        w.time.tick,w.time.resimulating=at,again
        w.input.gamepads[0]={connected=true,down=down?{.South}:{}}
        net_input_take(s,&w.seats,w.time)
        net_test_feed(w)
        net_input_delay(s,&w.seats,core.ref(&w.bindings),w.time)
    }
    for at in u64(1)..=12 {
        tick(&s,&w,at,at==5 || at==6)
        state:=fire(&w,seat)
        testing.expectf(t,state.down==(at==8 || at==9) && state.pressed==(at==8) && state.released==(at==10),"tick %d: down %v, pressed %v, released %v",at,state.down,state.pressed,state.released)
        sent:=s.client.taken[at%16].actions
        testing.expectf(t,(sent.down&inp.action_bit(NET_TEST_FIRE)!=0)==(at==5 || at==6),"tick %d sends %v for tick %d",at,sent.down,at+3)
    }
    // Tick 12 again, as a correction runs it, with other devices: it acts on what it acted on, and takes nothing.
    before,taken:=fire(&w,seat),s.client.taken[12]
    tick(&s,&w,12,true,again=true)
    testing.expect(t,fire(&w,seat)==before && s.client.taken[12]==taken)
}

// The look a client sends is the one it had look_behind ticks before the tick
// of its input: the server compares it with the look it had then, so a turn
// the server lost is put right once, and the turns since stay.
@(test)
a_look_of_some_ticks_ago_corrects_the_look_of_the_server_once :: proc(t:^testing.T) {
    for behind in ([2]u8{0,3}) {
        info,described:=net_test_info(t)
        if !described {return}
        defer core.test_info_destroy(&info)
        w:Net_Test_World
        net_test_init(&w,&info)
        defer core.world_destroy(&info,.World,&w)
        connection:=Connection(base.handle_make(1,1))
        body:=core.create(&w.entities)
        core.add(&w.move_inputs,body,inp.Move_Input{})
        net_test_own(&w,body,connection)
        core.settle(&info,&w,nil)
        resize(&w.remote.entries,2)
        entry:=&w.remote.entries[1]
        entry^={connection=connection}
        s:=Net_Session{mode=.Server}
        // Both ends turn 0.01 rad a tick; from tick 8 on the client is 0.2 rad further, a turn the server lost.
        client :: proc(at:int) -> f32 {return 0.01*f32(at)+(at>=8?0.2:0)}
        for at in 1..=20 {
            w.time.tick=u64(at)
            move:=core.get(&w.move_inputs,body)
            move.look_yaw+=0.01
            entry.look,entry.look_behind,entry.has_look={client(at-int(behind)),0.1},behind,at>int(behind)
            remote_look(core.ref(&s),&w.remote,core.read(&w.seats),core.read(&w.drivables),&w.move_inputs,w.time)
            wanted:=0.01*f32(at)+(at-int(behind)>=8?0.2:0)
            testing.expectf(t,math.abs(move.look_yaw-wanted)<1e-5 && (at<=int(behind) || math.abs(move.look_pitch-0.1)<1e-6),"%d ticks behind, tick %d: the server looks at %.3f, and should at %.3f",behind,at,move.look_yaw,wanted)
        }
    }
}

// The actions a client sends fit an input of the protocol, every axis slot
// and mask included.
@(test)
input_packet_fits_the_input_of_the_protocol :: proc(t:^testing.T) {
    schema:serial.Schema
    serial.schema_init(&schema)
    defer serial.schema_destroy(&schema)
    protocol:wire.Protocol
    wire.protocol_init(&protocol)
    defer wire.protocol_destroy(&protocol)
    type,added:=serial.schema_add(&schema,Input_Packet)
    testing.expect(t,added)
    if !added {return}
    testing.expect(t,wire.input_register(&protocol,&schema,type))
}

// The server takes the view a client says it saw unless it is farther than
// the tolerance from the one its latency gives.
@(test)
a_claimed_view_far_from_the_latency_takes_the_expected_one :: proc(t:^testing.T) {
    h:wire.Host
    h.desc.tick_rate=128
    h.desc.replication.input_lead=5
    h.desc.replication.interpolation_delay=2.5
    expected:=expected_behind(&h,{rtt=0.15,jitter=0.003})
    tolerance:=0.2*128.0
    behind,corrected:=view_checked(expected+3,expected,tolerance)
    testing.expect(t,behind==expected+3 && !corrected)
    behind,corrected=view_checked(expected+tolerance+1,expected,tolerance)
    testing.expect(t,behind==expected && corrected)
    behind,corrected=view_checked(0,expected,tolerance)
    testing.expect(t,behind==expected && corrected)
}
