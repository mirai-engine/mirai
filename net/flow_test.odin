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
        channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=1<<20}}
        replication:=Replication_Desc{max_objects=128,baseline_interval=-1}
        server:=test_host(&w,{mode=.Server,protocol=&tp.protocol,channels=channels,replication=replication})
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
// counts it once, and no measure grows a window past what the rate sends in its span nor past
// what the channel holds, nor shrinks it below where it starts.
@(test)
hostile_acknowledgements_are_refused_and_never_push_a_window_past_its_bounds :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=256<<10}}
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
    testing.expect_value(t,c.acked,1)

    Case :: struct {start,acked,bytes:int,span,rate:f64,low,high:int}
    nan:=math.nan_f64()
    cases:=[]Case{
        {start=64,acked=max(int)/2,span=1e9,rate=1e30,low=1024,high=1024},
        {start=64,acked=1<<20,bytes=(1<<20)*CHUNK_BYTES,span=0.1,rate=1<<20,low=1,high=409},
        {start=64,acked=max(int)/2,bytes=max(int)/2,span=0.1,rate=1<<20,low=1,high=1024},
        {start=512,acked=0,span=0.1,rate=16<<20,low=512,high=512},
        {start=512,acked=1<<20,span=nan,rate=1<<20,low=512,high=512},
        {start=512,acked=1<<20,span=0.1,rate=nan,low=512,high=512},
        {start=512,acked=1<<20,span=-1,rate=1<<20,low=512,high=512},
        {start=512,acked=1<<20,span=1e-9,rate=0,low=512,high=512},
        {start=512,acked=1<<20,span=1e-9,rate=1,low=CHUNK_WINDOW,high=CHUNK_WINDOW},
    }
    for k in cases {
        c.window,c.acked,c.acked_bytes=k.start,k.acked,k.bytes
        channel_window(c,k.span,k.rate)
        testing.expectf(t,c.window>=k.low && c.window<=k.high && c.acked==0 && c.acked_bytes==0,"%v gives a window of %d",k,c.window)
    }

    wr:serial.Bit_Writer
    buffer:[64]u8
    serial.bit_writer_init(&wr,buffer[:])
    serial.bit_write_bool(&wr,true)
    serial.bit_write(&wr,u64(p.send_seq+10),16)
    serial.bit_write(&wr,0,ACK_COUNT_BITS)
    serial.bit_write_bool(&wr,false)
    serial.bit_write(&wr,0,8)
    rd:serial.Bit_Reader
    serial.bit_reader_init(&rd,serial.bit_writer_flush(&wr))
    testing.expect(t,!peer_receive(server,p,&rd,p.recv_counter+1),"an acknowledgement of what was never sent is malformed")
}

// Which datagrams arrived reads back as written, whatever the pattern, and a record whose runs are
// empty, too long, past the count or cut short is refused; random bits never read past what they say.
@(test)
acknowledgement_runs_read_back_and_refuse_what_does_not_add_up :: proc(t:^testing.T) {
    state:=u64(17)
    Pattern :: enum {All,None,Alternate,Sparse_Loss,Random}
    for pattern in Pattern {
        for count in ([]int{0,1,63,64,65,700,ACK_WINDOW}) {
            bits:Ack_Bits
            for i in 0..<ACK_WINDOW {
                set:bool
                switch pattern {
                case .All:         set=true
                case .None:        set=false
                case .Alternate:   set=i%2==0
                case .Sparse_Loss: set=base.splitmix_next(&state)%50!=0
                case .Random:      set=base.splitmix_next(&state)&1==0
                }
                if set {bits[i/64]|=1<<uint(i%64)}
            }
            buffer:[PACKET_BYTES]u8
            w:serial.Bit_Writer
            serial.bit_writer_init(&w,buffer[:])
            ack_bits_write(&w,&bits,count,max(int))
            r:serial.Bit_Reader
            serial.bit_reader_init(&r,serial.bit_writer_flush(&w))
            got,got_count,ok:=ack_bits_read(&r)
            same:=ok && int(got_count)==count
            for behind in 1..=ACK_WINDOW {same&&=ack_bit(&got,u64(behind))==(behind<=count && ack_bit(&bits,u64(behind)))}
            testing.expectf(t,same && !w.overflow,"%v over %d datagrams reads back",pattern,count)
            // Within a budget it covers fewer datagrams, never more bits, and those read back.
            for budget in ([]int{0,ACK_COUNT_BITS,ACK_COUNT_BITS+3,200,1000}) {
                small:serial.Bit_Writer
                small_buffer:[PACKET_BYTES]u8
                serial.bit_writer_init(&small,small_buffer[:])
                ack_bits_write(&small,&bits,count,budget)
                serial.bit_reader_init(&r,serial.bit_writer_flush(&small))
                cut,cut_count,cut_ok:=ack_bits_read(&r)
                fits:=cut_ok && int(cut_count)<=count && (small.bits<=budget || cut_count==0 && small.bits==ACK_COUNT_BITS)
                for behind in 1..=int(cut_count) {fits&&=ack_bit(&cut,u64(behind))==ack_bit(&bits,u64(behind))}
                testing.expectf(t,fits,"%v over %d datagrams within %d bits: %d bits for %d",pattern,count,budget,small.bits,cut_count)
            }
            if pattern==.Sparse_Loss && count==ACK_WINDOW {testing.expectf(t,len(serial.bit_writer_flush(&w))<ACK_WINDOW/16,"a stream with few losses takes %d bytes",len(serial.bit_writer_flush(&w)))}
        }
    }

    // Each case: the count, the first run's kind, then raw gamma codes as (zeros, value bits).
    Code :: struct {zeros:int,low:u64}
    Case :: struct {name:string,count:u64,codes:[]Code}
    for c in ([]Case{
        {name="a run past the count",count=10,codes={{3,3}}},
        {name="runs past the count",count=10,codes={{2,1},{2,3}}},
        {name="a run that never ends its zeros",count=10,codes={{ACK_COUNT_BITS,0}}},
        {name="runs that stop short",count=10,codes={{1,1}}},
        {name="a code cut short",count=4095,codes={{11,0}}},
    }) {
        buffer:[64]u8
        w:serial.Bit_Writer
        serial.bit_writer_init(&w,buffer[:])
        serial.bit_write(&w,c.count,ACK_COUNT_BITS)
        serial.bit_write_bool(&w,true)
        for code in c.codes {
            serial.bit_write(&w,0,code.zeros)
            if code.zeros<ACK_COUNT_BITS {
                serial.bit_write(&w,1,1)
                serial.bit_write(&w,code.low,code.zeros)
            }
        }
        bytes:=serial.bit_writer_flush(&w)
        r:serial.Bit_Reader
        serial.bit_reader_init(&r,bytes,w.bits)
        _,_,ok:=ack_bits_read(&r)
        testing.expectf(t,!ok,"%s is refused",c.name)
    }

    for _ in 0..<20000 {
        buffer:[96]u8
        for &b in buffer {b=u8(base.splitmix_next(&state))}
        r:serial.Bit_Reader
        serial.bit_reader_init(&r,buffer[:int(base.splitmix_next(&state)%len(buffer))])
        bits,count,ok:=ack_bits_read(&r)
        if !ok {continue}
        clean:=count<=ACK_WINDOW && !r.error
        for behind in count+1..=ACK_WINDOW {clean&&=!ack_bit(&bits,behind)}
        if !testing.expectf(t,clean,"random bits read as %d datagrams with marks past them",count) {return}
    }
}

@(private="file") BULK_CHANNELS :: []Channel_Desc{{kind=.Reliable,queue_bytes=4<<20},{kind=.Unreliable}}
@(private="file") BULK_LINK :: 12.5e6 // bytes per second: 100 Mbit/s
@(private="file") BULK_PART :: 4<<20
@(private="file") BULK_WARM :: 4.0    // s before measuring: the rate has found the path

@(private="file")
Bulk_Result :: struct {
    delivered:[2]f64, // bytes per second each client received once warm
    game_mean,game_worst:f64, // s a 60 Hz unreliable message took above the latency, once warm
    game_sent,game_got:int,
    drop_share:f64,   // of the datagrams the server sent, those its link dropped for lack of queue
    resent_share:f64, // of the bytes the first client received once warm, those its server sent again
}

// A server streams reliable parts to each client over its 100 Mbit/s link with every setting at its
// default, the worker's cadence of 1 ms, and a 60 Hz unreliable message to each on the same connection.
@(private="file")
bulk_stream :: proc(t:^testing.T,rtt:f64,loss:f32,clients:int,seconds:f64,jitter:=0.0) -> (result:Bulk_Result,ok:bool) {
    blob:=make([]u8,BULK_PART);defer delete(blob)
    w:Test_World;test_world_init(&w,1+clients,seed=31,packets=1<<16);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=BULK_CHANNELS})
    hosts:[2]^Host
    on_server:[2]Connection
    for i in 0..<clients {
        hosts[i]=test_host(&w,{mode=.Client,channels=BULK_CHANNELS})
        on_server[i],_=test_connect(&w,server,hosts[i])
        if !testing.expect(t,on_server[i]!=0,"the client connects") {return}
    }
    sim_endpoint_conditions(&w.sim,0,{latency=rtt/2,jitter=jitter,loss=loss,bandwidth=BULK_LINK})
    for i in 1..=clients {sim_endpoint_conditions(&w.sim,i,{latency=rtt/2,jitter=jitter,loss=loss})}
    sent:[2]int
    got:[2]f64
    start:=w.now
    next_game:=start
    game_total:f64
    sim_before:=w.sim.stats
    resent_before:u64
    for w.now-start<seconds {
        w.now+=0.001
        sim_network_advance(&w.sim,w.now)
        host_update(server,w.now)
        for command in host_poll(server) {
            if command.kind==.Disconnected {testing.expect(t,false,"the connection holds");return}
        }
        warm:=w.now-start>=BULK_WARM
        if !warm {
            stats,_:=connection_stats(server,on_server[0])
            resent_before=stats.chunks_resent
        }
        for i in 0..<clients {
            if sent[i]==len(blob) {sent[i]=0}
            message_send(server,on_server[i],0,blob,&sent[i])
        }
        if w.now>=next_game {
            next_game+=1.0/60
            for i in 0..<clients {
                stamp:=w.now
                message_send(server,on_server[i],1,([^]u8)(&stamp)[:8])
                if warm {result.game_sent+=1}
            }
        }
        for i in 0..<clients {
            host_update(hosts[i],w.now)
            for command in host_poll(hosts[i]) {
                #partial switch command.kind {
                case .Disconnected: testing.expect(t,false,"the connection holds");return
                case .Message:
                    if command.channel==0 {
                        if warm {got[i]+=f64(len(command.data))}
                        continue
                    }
                    stamp:f64
                    copy(([^]u8)(&stamp)[:8],command.data)
                    if stamp-start<BULK_WARM {continue}
                    late:=w.now-stamp-rtt/2
                    result.game_got+=1
                    game_total+=late
                    result.game_worst=max(result.game_worst,late)
                }
            }
        }
    }
    for i in 0..<clients {result.delivered[i]=got[i]/(seconds-BULK_WARM)}
    result.game_mean=game_total/f64(max(result.game_got,1))
    sent_datagrams:=w.sim.stats.sent-sim_before.sent
    result.drop_share=f64(w.sim.stats.dropped_queue-sim_before.dropped_queue)/f64(max(sent_datagrams,1))
    stats,_:=connection_stats(server,on_server[0])
    result.resent_share=f64(stats.chunks_resent-resent_before)*CHUNK_BYTES/max(got[0],1)
    return result,true
}

// With every setting at its default, a reliable stream takes most of a 100 Mbit/s link at 40 ms of round
// trip and at 120 ms with 2% loss, overruns the link's queue for few of its datagrams, and a 60 Hz
// unreliable message on the same connection arrives with little more than the path's latency.
@(test)
a_bulk_stream_finds_the_rate_of_the_path_and_leaves_the_game_channel_on_time :: proc(t:^testing.T) {
    Case :: struct {rtt:f64,loss:f32}
    for c in ([]Case{{0.04,0},{0.04,0.01},{0.12,0.02}}) {
        r,ok:=bulk_stream(t,c.rtt,c.loss,1,12)
        if !ok {return}
        fmt.printfln("bulk %.0f ms %.0f%%: %.2f MB/s, game %.1f ms mean, %.1f ms worst, %d/%d, %.2f%% dropped",c.rtt*1000,c.loss*100,r.delivered[0]/1e6,r.game_mean*1000,r.game_worst*1000,r.game_got,r.game_sent,r.drop_share*100)
        testing.expectf(t,r.delivered[0]>0.6*BULK_LINK,"%v: %.0f B/s arrive over a link of %.0f",c,r.delivered[0],BULK_LINK)
        testing.expectf(t,r.drop_share<0.03,"%v: the link's queue drops %.1f%% of the datagrams",c,r.drop_share*100)
        testing.expectf(t,r.game_got>=int(0.95*(1-f64(c.loss))*f64(r.game_sent)),"%v: %d of %d game messages arrive",c,r.game_got,r.game_sent)
        testing.expectf(t,r.game_mean<0.03 && r.game_worst<0.08,"%v: game messages take %.0f ms more than the latency on average, %.0f at worst",c,r.game_mean*1000,r.game_worst*1000)
    }
}

// A path that reorders its datagrams by jitter, as internet paths do, neither slows a reliable stream
// nor makes it resend what arrived: with jitter alone it takes most of the link, with jitter and loss
// it keeps near what the same loss without jitter gives, and the 60 Hz unreliable game channel on the
// same connection stays on time and loses only what a later message of its own overtook.
@(test)
a_bulk_stream_keeps_its_rate_on_a_path_that_reorders :: proc(t:^testing.T) {
    Case :: struct {jitter:f64,loss:f32}
    steady:f64
    for c in ([]Case{{0.005,0},{0.02,0},{0,0.01},{0.005,0.01},{0.02,0.01}}) {
        r,ok:=bulk_stream(t,0.04,c.loss,1,12,c.jitter)
        if !ok {return}
        fmt.printfln("bulk 40 ms, %.0f ms jitter, %.0f%%: %.2f MB/s, %.2f%% resent, game %.1f ms mean, %.1f ms worst, %d/%d, %.2f%% dropped",c.jitter*1000,c.loss*100,r.delivered[0]/1e6,r.resent_share*100,r.game_mean*1000,r.game_worst*1000,r.game_got,r.game_sent,r.drop_share*100)
        if c.jitter==0 {steady=r.delivered[0];continue}
        if c.loss==0 {
            testing.expectf(t,r.delivered[0]>0.6*BULK_LINK,"%v: %.0f B/s arrive over a link of %.0f",c,r.delivered[0],BULK_LINK)
            testing.expectf(t,r.resent_share<0.02,"%v: %.1f%% of what arrived was sent again",c,r.resent_share*100)
        } else {
            testing.expectf(t,r.delivered[0]>0.8*steady,"%v: %.0f B/s arrive, %.0f with the same loss and no jitter",c,r.delivered[0],steady)
            testing.expectf(t,r.resent_share<4*f64(c.loss),"%v: %.1f%% of what arrived was sent again",c,r.resent_share*100)
        }
        // The channel keeps its order: a message that a later one overtook by jitter is dropped, which
        // happens to two consecutive ones when their spread of 2 jitter exceeds the 1/60 s between them.
        overtaken:=max(1-1.0/60/(2*c.jitter),0)
        overtaken=overtaken*overtaken/2
        testing.expectf(t,r.game_got>=int(0.9*(1-f64(c.loss))*(1-overtaken)*f64(r.game_sent)),"%v: %d of %d game messages arrive",c,r.game_got,r.game_sent)
        testing.expectf(t,r.game_mean<0.03 && r.game_worst<0.08+c.jitter,"%v: game messages take %.0f ms more than the latency on average, %.0f at worst",c,r.game_mean*1000,r.game_worst*1000)
    }
}

// Two connections that stream over the same link each get a fair share of it.
@(test)
two_bulk_streams_on_one_link_share_it :: proc(t:^testing.T) {
    r,ok:=bulk_stream(t,0.04,0,2,16)
    if !ok {return}
    fmt.printfln("shared: %.2f and %.2f MB/s",r.delivered[0]/1e6,r.delivered[1]/1e6)
    total:=r.delivered[0]+r.delivered[1]
    testing.expectf(t,total>0.6*BULK_LINK,"together %.0f B/s over a link of %.0f",total,BULK_LINK)
    testing.expectf(t,min(r.delivered[0],r.delivered[1])>0.3*total,"shares of %.0f and %.0f B/s",r.delivered[0],r.delivered[1])
}

// Steps a server and its clients at the worker's cadence of 1 ms, streaming parts to each client on
// its first len(sent)/len(clients) channels, and adds the bytes each received; false if a connection
// closed.
@(private="file")
bulk_steps :: proc(t:^testing.T,w:^Test_World,server:^Host,clients:[]^Host,on_server:[]Connection,blob:[]u8,sent:[]int,seconds:f64,got:[]int) -> bool {
    streams:=len(sent)/len(clients)
    start:=w.now
    for w.now-start<seconds {
        w.now+=0.001
        sim_network_advance(&w.sim,w.now)
        host_update(server,w.now)
        for command in host_poll(server) {
            if command.kind==.Disconnected {testing.expectf(t,false,"the server's connection closed: %v",command.reason);return false}
        }
        for &s,i in sent {
            if s==len(blob) {s=0}
            message_send(server,on_server[i/streams],i%streams,blob,&s)
        }
        for client,i in clients {
            host_update(client,w.now)
            for command in host_poll(client) {
                if command.kind==.Disconnected {testing.expectf(t,false,"the client's connection closed: %v",command.reason);return false}
                if command.kind==.Message && int(command.channel)<streams {got[i]+=len(command.data)}
            }
        }
    }
    return true
}

@(private="file") BULK_TWO :: []Channel_Desc{{kind=.Reliable,queue_bytes=4<<20},{kind=.Reliable,queue_bytes=4<<20}}

// Two streams on one connection over 120 ms of round trip keep more datagrams in flight than the
// connection may: when an outage loses all of them, the connection still probes the path and the
// streams resume by themselves once it returns.
@(test)
a_bulk_stream_resumes_after_an_outage :: proc(t:^testing.T) {
    blob:=make([]u8,BULK_PART);defer delete(blob)
    w:Test_World;test_world_init(&w,2,seed=41,packets=1<<16);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=BULK_TWO})
    client:=test_host(&w,{mode=.Client,channels=BULK_TWO})
    on_server,_:=test_connect(&w,server,client)
    if !testing.expect(t,on_server!=0) {return}
    sent:[2]int
    got:[1]int
    for loss in ([]f32{0,1,0}) {
        sim_endpoint_conditions(&w.sim,0,{latency=0.06,bandwidth=BULK_LINK,loss=loss})
        sim_endpoint_conditions(&w.sim,1,{latency=0.06})
        got[0]=0
        if !bulk_steps(t,&w,server,{client},{on_server},blob,sent[:],4,got[:]) {return}
        if loss==1 {
            p:=peer_from(server,on_server)
            testing.expectf(t,p!=nil && int(u16(p.send_seq-p.sent_tail))>=RECORD_WINDOW,"the outage fills what the connection keeps in flight")
        }
    }
    testing.expectf(t,f64(got[0])/4>0.3*BULK_LINK,"after the outage %.0f B/s arrive over a link of %.0f",f64(got[0])/4,BULK_LINK)
}

@(private="file")
Large_Input :: struct {bytes:[INPUT_MAX_BYTES-8]u8}

// A client whose acknowledgement covers thousands of datagrams, half of them lost, while it repeats its
// largest inputs, still sends datagrams the server reads: the acknowledgement takes what is left.
@(test)
a_long_acknowledgement_never_overflows_a_datagram :: proc(t:^testing.T) {
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    protocol:Protocol;protocol_init(&protocol);defer protocol_destroy(&protocol)
    input,_:=serial.schema_add(&schema,Large_Input)
    testing.expect(t,input_register(&protocol,&schema,input))
    protocol_seal(&protocol)
    blob:=make([]u8,BULK_PART);defer delete(blob)
    w:Test_World;test_world_init(&w,2,seed=43,packets=1<<16);defer test_world_destroy(&w)
    replication:=Replication_Desc{input_redundancy=8}
    server:=test_host(&w,{mode=.Server,protocol=&protocol,channels=BULK_TWO,replication=replication})
    client:=test_host(&w,{mode=.Client,protocol=&protocol,channels=BULK_TWO,replication=replication})
    on_server,_:=test_connect(&w,server,client)
    if !testing.expect(t,on_server!=0) {return}
    state:=u64(5)
    tick:=u32(0)
    sent:[2]int
    got:[1]int
    Phase :: struct {seconds:f64,forward,back:f32}
    longest:=0
    for phase in ([]Phase{{3,0,0},{3,0.5,1},{3,0,0}}) {
        sim_endpoint_conditions(&w.sim,0,{latency=0.06,bandwidth=BULK_LINK,loss=phase.forward})
        sim_endpoint_conditions(&w.sim,1,{latency=0.06,loss=phase.back})
        got[0]=0
        for step in 0..<int(phase.seconds*60) {
            tick+=1
            sample:Large_Input
            for &b in sample.bytes {b=u8(base.splitmix_next(&state))}
            input_submit(client,tick,&sample)
            host_publish(client,tick)
            host_publish(server,tick)
            if !bulk_steps(t,&w,server,{client},{on_server},blob,sent[:],1.0/60,got[:]) {return}
            if p:=peer_from(client,client.back.peers[0].state==.Connected?peer_handle(client,&client.back.peers[0]):0);p!=nil && p.recv_counter>p.ack_known {longest=max(longest,int(p.recv_counter-p.ack_known))}
            _=step
        }
    }
    testing.expectf(t,longest>=3000,"the acknowledgement covers %d datagrams",longest)
    testing.expectf(t,f64(got[0])/3>0.3*BULK_LINK,"after the lossy spell %.0f B/s arrive",f64(got[0])/3)
}

// Drops the datagram of a connection numbered drop among those its host sends, once.
@(private="file")
Drop_Once :: struct {inner:Transport,count,drop:int}
@(private="file")
drop_once_transport :: proc(d:^Drop_Once) -> Transport {
    return {d,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        d:=(^Drop_Once)(data)
        if len(bytes)>0 && bytes[0]==u8(Packet_Type.Data) {
            d.count+=1
            if d.count==d.drop {return true}
        }
        return d.inner.send(d.inner.data,to,bytes)
    },proc(data:rawptr,buffer:[]u8) -> (int,Address,bool) {
        d:=(^Drop_Once)(data)
        return d.inner.receive(d.inner.data,buffer)
    }}
}

// Thousands of tiny reliable messages held behind one lost chunk all arrive, in order, when the gap
// closes: what the receiver cannot take in one poll waits for the next.
@(test)
tiny_messages_held_behind_a_gap_arrive_without_overflowing_the_receiver :: proc(t:^testing.T) {
    COUNT :: 60000
    w:Test_World;test_world_init(&w,2,seed=47,packets=1<<16);defer test_world_destroy(&w)
    drop:=Drop_Once{inner=sim_endpoint_transport(&w.sim,0),drop=120}
    server:=new(Host)
    if !testing.expect(t,host_init(server,{mode=.Server,transport=drop_once_transport(&drop),protocol_id=77,seed=3,channels=BULK_CHANNELS,frame_ops=1<<16})==.None) {free(server);return}
    w.hosts[0]=server;w.count=1
    client:=test_host(&w,{mode=.Client,channels=BULK_CHANNELS})
    on_server,_:=test_connect(&w,server,client)
    if !testing.expect(t,on_server!=0) {return}
    sim_endpoint_conditions(&w.sim,0,{latency=0.05})
    sim_endpoint_conditions(&w.sim,1,{latency=0.05})
    queued,arrived:=0,0
    for step:=0;arrived<COUNT && step<20000;step+=1 {
        w.now+=0.001
        sim_network_advance(&w.sim,w.now)
        for queued<COUNT {
            value:=u8(queued)
            if message_send(server,on_server,0,([^]u8)(&value)[:1])!=.None {break}
            queued+=1
        }
        host_update(server,w.now)
        for command in host_poll(server) {
            if command.kind==.Disconnected {testing.expectf(t,false,"the server's connection closed: %v",command.reason);return}
        }
        host_update(client,w.now)
        for command in host_poll(client) {
            if command.kind==.Disconnected {testing.expectf(t,false,"the client's connection closed: %v",command.reason);return}
            if command.kind!=.Message {continue}
            if !testing.expect(t,len(command.data)==1 && command.data[0]==u8(arrived),"the messages arrive in order") {return}
            arrived+=1
        }
    }
    testing.expectf(t,arrived==COUNT,"%d of %d messages arrive",arrived,COUNT)
}
