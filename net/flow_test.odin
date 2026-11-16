package mirai_net

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") FLOW_RTT :: 0.05
@(private="file") FLOW_CAPACITY :: 1<<20 // bytes per second the server's link carries
@(private="file") FLOW_PART :: 4<<20
@(private="file") FLOW_OBJECTS :: 96

// A part of 4 MiB streamed on a reliable channel over a link of 50 ms of round trip arrives whole in a
// time near what the link carries, also with 5% loss, while the state of objects that change every tick
// keeps reaching the client at the rate it had, with a send rate that is all the link carries.
@(test)
a_large_reliable_part_streams_at_what_the_path_carries_and_the_state_keeps_its_rate :: proc(t:^testing.T) {
    Case :: struct {loss:f32,slack:f64}
    cases:=[]Case{{0,1.5},{0.05,2.5}}
    blob:=make([]u8,FLOW_PART);defer delete(blob)
    state:=u64(9)
    for &b in blob {b=u8(base.splitmix_next(&state))}
    for c in cases {
        tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
        w:Test_World;test_world_init(&w,2,seed=21,packets=16384);defer test_world_destroy(&w)
        channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=1<<20,window=1024}}
        replication:=Replication_Desc{max_objects=128,baseline_interval=-1}
        server:=test_host(&w,{mode=.Server,protocol=&tp.protocol,channels=channels,replication=replication,send_rate=FLOW_CAPACITY,packets_per_update=64})
        client:=test_host(&w,{mode=.Client,protocol=&tp.protocol,channels=channels,replication=replication})
        on_server,on_client:=test_connect(&w,server,client)
        if !testing.expect(t,on_server!=0 && on_client!=0) {return}
        sim_endpoint_conditions(&w.sim,0,{latency=FLOW_RTT/2,bandwidth=FLOW_CAPACITY,loss=c.loss})
        sim_endpoint_conditions(&w.sim,1,{latency=FLOW_RTT/2,loss=c.loss})
        transforms:[FLOW_OBJECTS]Test_Transform
        vitals:[FLOW_OBJECTS]Test_Vitals
        secrets:[FLOW_OBJECTS]Test_Secret
        for i in 0..<FLOW_OBJECTS {object_create(server,{type=tp.actor,sources={0=&transforms[i],1=&vitals[i],2=&secrets[i]},poll=true})}
        tick:=u32(0)
        updates:=0
        sent,got,steps:=0,0,0
        whole:=false
        step :: proc(t:^testing.T,w:^Test_World,server,client:^Host,tick:^u32,transforms:[]Test_Transform,vitals:[]Test_Vitals,updates,got:^int,whole:^bool,blob:[]u8) -> bool {
            tick^+=1
            for &transform,i in transforms {transform.position+={0.25,f32(i)*0.01,0};transform.velocity.y+=0.5}
            for &v in vitals {v.health=(v.health+7)%1000;v.energy=f32(v.health%100);v.big+=0x9e3779b97f4a7c15}
            host_publish(server,tick^)
            host_publish(client,tick^)
            test_step(w)
            host_poll(server)
            for command in host_poll(client) {
                #partial switch command.kind {
                case .Disconnected: testing.expect(t,false,"the connection holds");return false
                case .Object_Updated: updates^+=1
                case .Message:
                    if got^+len(command.data)>len(blob) || string(command.data)!=string(blob[got^:][:len(command.data)]) {
                        testing.expect(t,false,"the pieces are the part, in order")
                        return false
                    }
                    got^+=len(command.data)
                    whole^=!command.more && got^==len(blob)
                }
            }
            return true
        }
        SECONDS :: 2
        for _ in 0..<60*SECONDS {if !step(t,&w,server,client,&tick,transforms[:],vitals[:],&updates,&got,&whole,blob) {return}}
        alone:=updates
        updates=0
        for !whole && steps<60*40 {
            if sent<len(blob) {message_send(server,on_server,0,blob,&sent)}
            if !step(t,&w,server,client,&tick,transforms[:],vitals[:],&updates,&got,&whole,blob) {return}
            steps+=1
        }
        seconds:=f64(steps)*TEST_STEP
        ideal:=f64(FLOW_PART)/FLOW_CAPACITY
        fmt.printfln("loss %.0f%%: %d bytes in %.2f s over %.0f ms of round trip, %.2f s at the link's capacity; state %d updates a second alone, %.0f while streaming",
            c.loss*100,got,seconds,FLOW_RTT*1000,ideal,alone/SECONDS,f64(updates)/max(seconds,TEST_STEP))
        testing.expectf(t,whole,"loss %v: the part arrives whole (%d of %d bytes)",c.loss,got,len(blob))
        testing.expectf(t,seconds<c.slack*ideal,"loss %v: %.2f s, more than %.1f times the %.2f s the link needs",c.loss,seconds,c.slack,ideal)
        testing.expectf(t,f64(updates)/seconds>=0.9*f64(alone)/SECONDS,"loss %v: the state reaches the client %.0f times a second while the part streams, %d alone",c.loss,f64(updates)/seconds,alone/SECONDS)
    }
}

// An acknowledgement of a datagram never sent closes the connection, one that comes again for a chunk
// counts it once, and no measure grows a window past twice what the rate sends in a round trip nor past
// what the channel holds, nor shrinks it below where it starts.
@(test)
hostile_acknowledgements_are_refused_and_never_push_a_window_past_its_bounds :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    channels:=[]Channel_Desc{{kind=.Reliable,window=1024}}
    server:=test_host(&w,{mode=.Server,channels=channels})
    client:=test_host(&w,{mode=.Client,channels=channels})
    on_server,_:=test_connect(&w,server,client)
    p:=peer_from(server,on_server)
    if !testing.expect(t,p!=nil) {return}
    c:=&p.channels[0]

    sim_endpoint_conditions(&w.sim,1,{latency=1})
    payload:[600]u8
    message_send(server,on_server,0,payload[:])
    for _ in 0..<10 {
        test_step(&w)
        if c.chunks[int(c.send_base)%len(c.chunks)].state==.Flight {break}
    }
    record:=Record{kind=.Chunk,flags=0,aux=c.send_base}
    testing.expect(t,c.chunks[int(c.send_base)%len(c.chunks)].state==.Flight)
    c.acked=0
    channel_resolve(p,record,true)
    channel_resolve(p,record,true)
    testing.expect_value(t,c.acked,CHUNK_BYTES)

    Case :: struct {start,acked:int,rtt,rate:f64,low,high:int}
    nan:=math.nan_f64()
    cases:=[]Case{
        {start=64,acked=max(int)/2,rtt=1e9,rate=1e30,low=1024,high=1024},
        {start=64,acked=max(int)/2,rtt=0.05,rate=1<<20,low=1,high=409},
        {start=512,acked=0,rtt=0.05,rate=16<<20,low=512,high=512},
        {start=512,acked=1<<20,rtt=nan,rate=1<<20,low=512,high=512},
        {start=512,acked=1<<20,rtt=0.05,rate=nan,low=512,high=512},
        {start=512,acked=1<<20,rtt=-1,rate=1<<20,low=512,high=512},
        {start=512,acked=1<<20,rtt=1e-9,rate=0,low=512,high=512},
        {start=512,acked=1<<20,rtt=1e-9,rate=1,low=CHUNK_WINDOW,high=CHUNK_WINDOW},
    }
    for k in cases {
        c.window,c.acked=k.start,k.acked
        channel_window(c,k.rtt,k.rate)
        testing.expectf(t,c.window>=k.low && c.window<=k.high && c.acked==0,"%v gives a window of %d",k,c.window)
    }

    wr:serial.Bit_Writer
    buffer:[64]u8
    serial.bit_writer_init(&wr,buffer[:])
    serial.bit_write_bool(&wr,true)
    serial.bit_write(&wr,u64(p.send_seq+10),16)
    serial.bit_write(&wr,0,8)
    serial.bit_write(&wr,0,8)
    rd:serial.Bit_Reader
    serial.bit_reader_init(&rd,serial.bit_writer_flush(&wr))
    testing.expect(t,!peer_receive(server,p,&rd,p.recv_counter+1),"an acknowledgement of what was never sent is malformed")
}
