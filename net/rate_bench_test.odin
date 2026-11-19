package mirai_net

import "core:fmt"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"

// Opt-in: mirai test net a_reliable_stream_on_udp_loopback -define:NET_BENCHMARK=true
// A server streams to a client on one reliable channel over UDP on 127.0.0.1, both hosts with their
// worker thread and a thread for their simulation half; the client checks every byte. It prints the
// rate, the CPU of each side per GiB and the datagrams and transport calls per GiB, and asserts no
// speed.
@(test)
a_reliable_stream_on_udp_loopback :: proc(t:^testing.T) {
    when #config(NET_BENCHMARK,false) {
        TOTAL :: 256<<20
        blob:=make([]u8,TOTAL+(64<<10));defer delete(blob)
        state:=u64(5)
        for i:=0;i<len(blob);i+=8 {(^u64)(&blob[i])^=base.splitmix_next(&state)}
        for size in ([?]int{1<<10,64<<10,0}) {rate_case(t,blob,TOTAL,size)}
    }
}

@(private="file")
Counted :: struct {inner:Transport,sends,receives,empty,waits:u64}

@(private="file")
counted_transport :: proc(c:^Counted) -> Transport {
    return {data=c,send=proc(data:rawptr,batch:[]Datagram) -> int {
        c:=(^Counted)(data)
        sync.atomic_add(&c.sends,1)
        return c.inner.send(c.inner.data,batch)
    },receive=proc(data:rawptr,batch:[]Datagram) -> int {
        c:=(^Counted)(data)
        sync.atomic_add(&c.receives,1)
        got:=c.inner.receive(c.inner.data,batch)
        if got==0 {sync.atomic_add(&c.empty,1)}
        return got
    },wait=proc(data:rawptr,seconds:f64) {
        c:=(^Counted)(data)
        sync.atomic_add(&c.waits,1)
        c.inner.wait(c.inner.data,seconds)
    },wake=proc(data:rawptr) {
        c:=(^Counted)(data)
        c.inner.wake(c.inner.data)
    }}
}

@(private="file")
Side :: struct {
    host:^Host,
    connection:Connection,
    blob:[]u8,
    total,size:int,
    moved:int, // sender: bytes given to message_send; receiver: bytes received and checked
    sent:int,  // streamed: what message_send took of the one message
    done,failed:bool,
    stop:^bool,
    cpu:f64,
}

@(private="file")
rate_case :: proc(t:^testing.T,blob:[]u8,total,size:int) {
    sockets:[2]Udp
    for &socket in sockets {
        if !testing.expect(t,udp_open(&socket,address_loopback(0)),"cannot bind a UDP socket on 127.0.0.1") {return}
    }
    defer for &socket in sockets {udp_close(&socket)}
    counted:=[2]Counted{{inner=udp_transport(&sockets[0])},{inner=udp_transport(&sockets[1])}}
    channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=4<<20}}
    hosts:[2]^Host
    for &h,i in hosts {
        h=new(Host)
        desc:=Host_Desc{mode=i==0?.Server:.Client,transport=counted_transport(&counted[i]),channels=channels,protocol_id=7,seed=u64(i+1),frame_bytes=8<<20,command_bytes=8<<20,command_count=1<<16}
        if !testing.expect_value(t,host_init(h,desc),Error.None) {return}
    }
    defer for h in hosts {host_destroy(h);free(h)}
    testing.expect(t,worker_start(hosts[0]) && worker_start(hosts[1]))
    host_connect(hosts[1],sockets[0].address)
    sides:[2]Side
    for _ in 0..<2000 {
        for &side,i in sides {
            for command in host_poll(hosts[i]) {
                if command.kind==.Connected {side.connection=command.connection}
            }
        }
        if sides[0].connection!=0 && sides[1].connection!=0 {break}
        time.sleep(time.Millisecond)
    }
    if !testing.expect(t,sides[0].connection!=0 && sides[1].connection!=0,"the hosts connect") {return}
    stop:=false
    before:[2]Host_Stats
    for &side,i in sides {
        side.host,side.blob,side.total,side.size,side.stop=hosts[i],blob,total,size,&stop
        before[i]=host_stats(hosts[i])
    }
    cpu_before:=[2]f64{thread_cpu(hosts[0].worker),thread_cpu(hosts[1].worker)}
    calls_before:=counted
    started:=time.tick_now()
    sender:=thread.create_and_start_with_data(&sides[0],proc(data:rawptr) {side_send((^Side)(data))})
    receiver:=thread.create_and_start_with_data(&sides[1],proc(data:rawptr) {side_receive((^Side)(data))})
    for !sync.atomic_load(&sides[1].done) && time.duration_seconds(time.tick_since(started))<60 {time.sleep(10*time.Millisecond)}
    seconds:=time.duration_seconds(time.tick_since(started))
    sync.atomic_store(&stop,true)
    thread.join(sender);thread.destroy(sender)
    thread.join(receiver);thread.destroy(receiver)
    cpu:=[2]f64{thread_cpu(hosts[0].worker)-cpu_before[0]+sides[0].cpu,thread_cpu(hosts[1].worker)-cpu_before[1]+sides[1].cpu}
    after:=[2]Host_Stats{host_stats(hosts[0]),host_stats(hosts[1])}
    worker_stop(hosts[0]);worker_stop(hosts[1])
    after[0]=host_stats(hosts[0])
    gib:=f64(sides[1].moved)/f64(1<<30)
    datagrams:=f64(after[0].packets_sent-before[0].packets_sent+after[1].packets_sent-before[1].packets_sent)
    calls:=[2]f64{
        f64(counted[0].sends-calls_before[0].sends+counted[0].receives-calls_before[0].receives),
        f64(counted[1].sends-calls_before[1].sends+counted[1].receives-calls_before[1].receives),
    }
    link,_:=connection_stats(hosts[0],sides[0].connection)
    fmt.printfln("NET_RATE_LINK,lost=%v,cuts=%v,resent=%v,rtt_ms=%.2f,limit_MiB_per_s=%.0f",link.packets_lost,link.send_limit_cuts,link.chunks_resent,link.rtt*1000,link.send_limit/(1<<20))
    waits:=f64(counted[0].waits-calls_before[0].waits+counted[1].waits-calls_before[1].waits)
    fmt.printfln("NET_RATE,message=%v,MiB=%v,seconds=%.2f,MiB_per_s=%.1f,sender_cpu_s_per_GiB=%.2f,receiver_cpu_s_per_GiB=%.2f,datagrams_per_GiB=%.0f,sender_calls_per_GiB=%.0f,receiver_calls_per_GiB=%.0f,empty_receives_per_GiB=%.0f,waits_per_GiB=%.0f",
        size==0?"streamed":fmt.tprintf("%v",size),sides[1].moved>>20,seconds,f64(sides[1].moved)/f64(1<<20)/seconds,cpu[0]/gib,cpu[1]/gib,datagrams/gib,calls[0]/gib,calls[1]/gib,
        f64(counted[0].empty-calls_before[0].empty+counted[1].empty-calls_before[1].empty)/gib,waits/gib)
    testing.expectf(t,sides[1].done && !sides[1].failed,"the client receives the %v bytes in order (%v)",total,sides[1].moved)
}

// The simulation half of the server: gives the channel what it has room for, every millisecond.
@(private="file")
side_send :: proc(s:^Side) {
    defer s.cpu=own_cpu()
    for !sync.atomic_load(s.stop) {
        host_poll(s.host)
        for s.moved<s.total {
            if s.size==0 {
                if message_send(s.host,s.connection,0,s.blob[:s.total],&s.sent)!=.None {break}
                s.moved=s.sent
            } else {
                if message_send(s.host,s.connection,0,s.blob[s.moved:][:s.size])!=.None {break}
                s.moved+=s.size
            }
        }
        time.sleep(time.Millisecond)
    }
}

// The simulation half of the client: checks each piece against the source, every millisecond.
@(private="file")
side_receive :: proc(s:^Side) {
    defer s.cpu=own_cpu()
    for !sync.atomic_load(s.stop) {
        for command in host_poll(s.host) {
            if command.kind!=.Message {continue}
            if s.moved+len(command.data)>s.total || string(command.data)!=string(s.blob[s.moved:][:len(command.data)]) {s.failed=true}
            s.moved+=len(command.data)
        }
        if s.moved>=s.total || s.failed {sync.atomic_store(&s.done,true)}
        time.sleep(time.Millisecond)
    }
}

@(private="file")
own_cpu :: proc() -> f64 {
    when ODIN_OS==.Darwin || ODIN_OS==.Linux {
        spec:posix.timespec
        posix.clock_gettime(.THREAD_CPUTIME_ID,&spec)
        return f64(spec.tv_sec)+f64(spec.tv_nsec)*1e-9
    } else {
        return 0
    }
}

when ODIN_OS==.Darwin {
    foreign import system "system:System.framework"
    @(private="file") Thread_Basic_Info :: struct {user_s,user_us,system_s,system_us,cpu_usage,policy,run_state,flags,suspend_count,sleep_time:i32}
    @(private="file",default_calling_convention="c")
    foreign system {
        pthread_mach_thread_np :: proc(thread:posix.pthread_t) -> u32 ---
        thread_info :: proc(thread:u32,flavor:i32,info:^Thread_Basic_Info,count:^u32) -> i32 ---
    }
}

// CPU seconds of another thread; 0 where the bench does not know how to ask.
@(private="file")
thread_cpu :: proc(th:^thread.Thread) -> f64 {
    if th==nil {return 0}
    when ODIN_OS==.Darwin {
        info:Thread_Basic_Info
        count:=u32(size_of(info)/4)
        if thread_info(pthread_mach_thread_np(th.unix_thread),3,&info,&count)!=0 {return 0}
        return f64(info.user_s+info.system_s)+f64(info.user_us+info.system_us)*1e-6
    } else when ODIN_OS==.Linux {
        clock:posix.clockid_t
        if posix.pthread_getcpuclockid(th.unix_thread,&clock)!=.NONE {return 0}
        spec:posix.timespec
        posix.clock_gettime(posix.Clock(clock),&spec)
        return f64(spec.tv_sec)+f64(spec.tv_nsec)*1e-9
    } else {
        return 0
    }
}
