package mirai_net

import "core:testing"
import "mirai:std/serial"

@(private="file")
Big :: struct {a,b,c,d,e,f,g,h,i,j:[100]u32}
@(private="file")
Small :: struct {x,y:u32}

// A state of 4 KB at most, five datagrams, travels in parts of whole fields, with loss, while small
// objects created with it arrive as fast as they would alone.
@(test)
a_state_larger_than_a_datagram_arrives_in_parts_without_holding_back_small_ones :: proc(t:^testing.T) {
    schema:serial.Schema
    serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    protocol:Protocol
    protocol_init(&protocol);defer protocol_destroy(&protocol)
    big_index,_:=serial.schema_add(&schema,Big)
    small_index,_:=serial.schema_add(&schema,Small)
    big_type,big_ok:=type_register(&protocol,"Big",{{schema=&schema,type=big_index}})
    small_type,small_ok:=type_register(&protocol,"Small",{{schema=&schema,type=small_index}})
    testing.expect(t,big_ok && small_ok && protocol.types[big_type].large && !protocol.types[small_type].large)
    protocol_seal(&protocol)

    for loss in ([2]f32{0,0.2}) {
        w:Test_World;test_world_init(&w,2,seed=3)
        server:=test_host(&w,{mode=.Server,protocol=&protocol,replication={max_objects=64}})
        client:=test_host(&w,{mode=.Client,protocol=&protocol,replication={max_objects=64}})
        on_server,on_client:=test_connect(&w,server,client)
        testing.expect(t,on_server!=0 && on_client!=0)
        sim_endpoint_conditions(&w.sim,0,{latency=0.02,loss=loss})
        big:Big
        for &v,i in big.a {v=u32(i*2654435761)}
        big.b,big.c,big.d,big.e,big.f,big.g,big.h,big.i,big.j=big.a,big.a,big.a,big.a,big.a,big.a,big.a,big.a,big.a
        smalls:[20]Small
        heavy,_:=object_create(server,{type=big_type,sources={0=&big}})
        light:[20]Object
        for &s,i in smalls {
            s={u32(i+1),u32(i*7+1)}
            light[i],_=object_create(server,{type=small_type,sources={0=&s}})
        }
        tick:=u32(0)
        step :: proc(w:^Test_World,server,client:^Host,tick:^u32) {
            tick^+=1
            host_publish(server,tick^)
            host_publish(client,tick^)
            test_step(w)
            host_poll(server)
            host_poll(client)
        }
        all_light :: proc(server,client:^Host,light:[]Object) -> bool {
            for o in light {
                if !test_replica_matches(server,client,o,false) {return false}
            }
            return true
        }
        // The small ones as fast as without the large one: within a few round trips.
        small_ticks,big_ticks:=-1,-1
        for i in 0..<600 {
            step(&w,server,client,&tick)
            if small_ticks<0 && all_light(server,client,light[:]) {small_ticks=i}
            if big_ticks<0 && test_replica_matches(server,client,heavy,false) {big_ticks=i}
            if small_ticks>=0 && big_ticks>=0 {break}
        }
        testing.expectf(t,small_ticks>=0 && small_ticks<(loss>0?60:4),"loss %v: the small objects took %d ticks",loss,small_ticks)
        testing.expectf(t,loss>0 || big_ticks>small_ticks,"the large state (%d ticks) went before the small ones (%d)",big_ticks,small_ticks)
        testing.expectf(t,big_ticks>=0,"loss %v: the large state never arrived whole",loss)
        // A change of every field follows in parts too, and only the changed fields go.
        for &v in big.c {v+=1}
        for &v in big.f {v~=0xffff}
        object_mark_dirty(server,heavy)
        matched:=false
        for _ in 0..<600 {
            step(&w,server,client,&tick)
            if test_replica_matches(server,client,heavy,false) {matched=true;break}
        }
        testing.expectf(t,matched,"loss %v: the change never arrived whole",loss)
        stats,_:=connection_stats(server,on_server)
        testing.expect(t,stats.objects_sent>21)
        test_world_destroy(&w)
    }
}
