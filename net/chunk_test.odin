package mirai_net

import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") CHUNK_QUEUE :: 64<<10

// A chunk as a hostile peer could write it, after an acknowledgement of nothing: its channel,
// sequence, length and place, and then bytes, which may be fewer than the length says.
@(private="file")
Crafted :: struct {channel,seq,length,place:int,bytes:[]u8,inputs:bool}

@(private="file")
crafted_read :: proc(h:^Host,p:^Peer,c:Crafted) -> bool {
    buffer:[PACKET_BYTES]u8
    w:serial.Bit_Writer
    serial.bit_writer_init(&w,buffer[:])
    serial.bit_write_bool(&w,false)
    serial.bit_write(&w,0,16)
    serial.bit_write(&w,0,ACK_COUNT_BITS)
    serial.bit_write_bool(&w,false)
    serial.bit_write(&w,0,8)
    if c.inputs {serial.bit_write(&w,0,4)}
    serial.bit_write_bool(&w,true)
    serial.bit_write(&w,u64(c.channel),3)
    serial.bit_write(&w,u64(c.seq),16)
    serial.bit_write(&w,u64(c.length),11)
    serial.bit_write(&w,u64(c.place),p.channels[c.channel].place_bits)
    serial.bit_write_align(&w)
    serial.bit_write_bytes(&w,c.bytes)
    serial.bit_write_bool(&w,false)
    r:serial.Bit_Reader
    serial.bit_reader_init(&r,serial.bit_writer_flush(&w))
    return peer_receive(h,p,&r,p.recv_counter+1)
}

// A stream of messages on the wire: each its size and its bytes.
@(private="file")
framed :: proc(out:[]u8,messages:..[]u8) -> []u8 {
    at:=0
    for message in messages {
        size:=u32le(len(message))
        at+=copy(out[at:],([^]u8)(&size)[:4])
        at+=copy(out[at:],message)
    }
    return out[:at]
}

// What a chunk says about itself is checked before it is kept: no length, one longer than the queue or
// the datagram, a place outside the queue, a channel that is not there and a size of a message of the
// library past what it allows close the connection; a chunk beyond the window or seen before is
// dropped; one whose place wraps around the end of the queue arrives whole, after the one before it.
// Random chunks never crash nor allocate.
@(test)
hostile_chunks_are_refused_and_a_chunk_across_the_end_of_the_queue_arrives :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=CHUNK_QUEUE},{kind=.Reliable,queue_bytes=1000}}
    server:=test_host(&w,{mode=.Server,channels=channels})
    client:=test_host(&w,{mode=.Client,channels=channels})
    on_server,_:=test_connect(&w,server,client)
    p:=peer_from(server,on_server)
    if !testing.expect(t,p!=nil) {return}
    c:=&p.channels[0]
    host_poll(server)

    bytes:[1100]u8
    refused:=[]Crafted{
        {seq=0,length=0,place=0},
        {channel=1,seq=0,length=1010,place=0,bytes=bytes[:1010]},
        {channel=1,seq=0,length=8,place=1010,bytes=bytes[:8]},
        {seq=0,length=600,place=0,bytes=bytes[:64]},
        {channel=3,seq=0,length=8,place=0,bytes=bytes[:8]},
    }
    for k in refused {testing.expectf(t,!crafted_read(server,p,k),"%v is refused",k)}

    // The second chunk of a message lies across the end of the queue and comes first; then the first.
    message:[100]u8
    for &b,i in message {b=u8(i+1)}
    stream:[128]u8
    whole:=framed(stream[:],message[:])
    split:=40
    testing.expect(t,crafted_read(server,p,{seq=1,length=len(whole)-split,place=CHUNK_QUEUE-20,bytes=whole[split:]}))
    testing.expect(t,crafted_read(server,p,{seq=1,length=len(whole)-split,place=CHUNK_QUEUE-20,bytes=whole[split:]}),"one seen before is dropped")
    testing.expect(t,crafted_read(server,p,{seq=int(c.recv_base)+len(c.recv_chunks),length=8,place=0,bytes=bytes[:8]}),"one beyond the window is dropped")
    testing.expect(t,crafted_read(server,p,{seq=0,length=split,place=CHUNK_QUEUE-20-split,bytes=whole[:split]}))
    got:=0
    host_update(server,w.now)
    for command in host_poll(server) {
        if command.kind!=.Message {continue}
        got+=1
        testing.expect(t,!command.more && string(command.data)==string(message[:]),"the message arrives whole and in order")
    }
    testing.expect_value(t,got,1)

    // The system channel of a protocol takes no message larger than it allows.
    {
        tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
        pw:Test_World;test_world_init(&pw,2);defer test_world_destroy(&pw)
        ps:=test_host(&pw,{mode=.Server,protocol=&tp.protocol,replication={max_objects=8}})
        pc:=test_host(&pw,{mode=.Client,protocol=&tp.protocol,replication={max_objects=8}})
        on,_:=test_connect(&pw,ps,pc)
        pp:=peer_from(ps,on)
        if !testing.expect(t,pp!=nil) {return}
        size:=u32le(RELIABLE_EVENT_MAX_BYTES+17)
        testing.expect(t,!crafted_read(ps,pp,{channel=CHANNEL_SYSTEM,seq=0,length=4,place=0,bytes=([^]u8)(&size)[:4],inputs=true}),"a library message past its size is refused")
    }

    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator=mem.tracking_allocator(&track)
    state:=u64(31)
    noise:[1100]u8
    for _ in 0..<4000 {
        for &b in noise {b=u8(base.splitmix_next(&state))}
        k:=Crafted{
            seq=int(base.splitmix_next(&state)%0x10000),
            length=int(base.splitmix_next(&state)%2048),
            place=int(base.splitmix_next(&state)%(CHUNK_QUEUE+64)),
        }
        k.bytes=noise[:min(int(base.splitmix_next(&state)%len(noise)),k.length+8)]
        crafted_read(server,p,k)
        host_update(server,w.now)
        host_poll(server)
    }
    testing.expect_value(t,track.total_allocation_count,0)
}

// A small message handed to a worker that waits goes at once, not when its next keepalive is due: the
// worker wakes for it, and the other worker wakes when it arrives. So it does while a stream fills the
// batches on another channel of the same connection.
@(test)
a_small_message_is_not_delayed_by_the_batch_path_or_the_wait_of_the_worker :: proc(t:^testing.T) {
    sockets:[2]Udp
    for &socket in sockets {
        if !testing.expect(t,udp_open(&socket,address_loopback(0)),"cannot bind a UDP socket on 127.0.0.1") {return}
    }
    defer for &socket in sockets {udp_close(&socket)}
    channels:=[]Channel_Desc{{kind=.Unreliable},{kind=.Reliable,queue_bytes=1<<20}}
    hosts:[2]^Host
    for &h,i in hosts {
        h=new(Host)
        desc:=Host_Desc{mode=i==0?.Server:.Client,transport=udp_transport(&sockets[i]),channels=channels,protocol_id=9,seed=u64(i+1),keepalive=2,command_bytes=4<<20}
        if !testing.expect_value(t,host_init(h,desc),Error.None) {return}
    }
    defer for h in hosts {host_destroy(h);free(h)}
    testing.expect(t,worker_start(hosts[0]) && worker_start(hosts[1]))
    host_connect(hosts[1],sockets[0].address)
    connections:[2]Connection
    for _ in 0..<2000 {
        for h,i in hosts {
            for command in host_poll(h) {
                if command.kind==.Connected {connections[i]=command.connection}
            }
        }
        if connections[0]!=0 && connections[1]!=0 {break}
        time.sleep(time.Millisecond)
    }
    if !testing.expect(t,connections[0]!=0 && connections[1]!=0,"the hosts connect") {return}

    Bulk :: struct {host:^Host,connection:Connection,stop:bool,blob:[]u8}
    blob:=make([]u8,64<<10);defer delete(blob)
    bulk:=Bulk{host=hosts[0],connection=connections[0],blob=blob}
    for streaming in ([]bool{false,true}) {
        streamer:^thread.Thread
        if streaming {
            sync.atomic_store(&bulk.stop,false)
            streamer=thread.create_and_start_with_data(&bulk,proc(data:rawptr) {
                b:=(^Bulk)(data)
                for !sync.atomic_load(&b.stop) {
                    for message_send(b.host,b.connection,1,b.blob)==.None {}
                    time.sleep(time.Millisecond)
                }
            })
        }
        // Long enough for both workers to settle into their wait.
        time.sleep(50*time.Millisecond)
        worst:f64
        MESSAGES :: 12
        for i in 0..<MESSAGES {
            stamp:=time.tick_now()
            sent:=host_time(hosts[1])
            message_send(hosts[1],connections[1],0,mem.ptr_to_bytes(&sent))
            host_poll(hosts[1])
            arrived:=false
            for !arrived && time.duration_seconds(time.tick_since(stamp))<1 {
                for command in host_poll(hosts[0]) {arrived||=command.kind==.Message && command.channel==0}
                if !arrived {time.sleep(100*time.Microsecond)}
            }
            worst=max(worst,time.duration_seconds(time.tick_since(stamp)))
            testing.expectf(t,arrived,"message %d arrives (streaming %v)",i,streaming)
            time.sleep(time.Duration(5+i*3)*time.Millisecond)
        }
        if streamer!=nil {
            sync.atomic_store(&bulk.stop,true)
            thread.join(streamer);thread.destroy(streamer)
        }
        // A keepalive is 2 s away and the old worker slept a millisecond at a time: waking takes far less.
        testing.expectf(t,worst<0.05,"the slowest of %d small messages took %.1f ms (streaming %v)",MESSAGES,worst*1000,streaming)
    }
}
