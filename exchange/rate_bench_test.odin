package exchange

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// Opt-in: mirai test exchange objects_over_udp_loopback -define:EXCHANGE_BENCHMARK=true
// Two stores, each with a host on 127.0.0.1 whose worker thread runs the socket
// and a thread that pumps its exchange. The receiver wants one large object,
// then many small ones; it prints the rate and the CPU of each side per GiB,
// counting the pump and the worker of each, and asserts no speed.
@(test)
objects_over_udp_loopback :: proc(t:^testing.T) {
    when #config(EXCHANGE_BENCHMARK,false) {
        testing.set_fail_timeout(t,20*time.Minute)
        folder:=base.test_folder(t,"exchange-bench")
        if folder=="" {return}
        stores:[2]store.Store
        for &s,i in stores {
            opened,error:=store.open(fmt.tprintf("%s/side-%d",folder,i))
            if !testing.expect_value(t,error,store.Error.None) {return}
            s=opened
        }
        defer for &s in stores {store.close(&s)}
        large:=[1]store.Hash{bench_large(&stores[0],2<<30 if #config(EXCHANGE_BENCHMARK_LARGE,true) else 1<<20)}
        small:=make([]store.Hash,5000)
        defer delete(small)
        small_bytes:=0
        state:=u64(9)
        buffer:=make([]u8,64<<10)
        defer delete(buffer)
        for &a,k in small {
            size:=1024+int(base.splitmix_next(&state)%(63<<10))
            for i:=0;i+8<=size;i+=8 {(^u64)(&buffer[i])^=base.splitmix_next(&state)}
            a,_=store.put(&stores[0],buffer[:size])
            small_bytes+=size
            _=k
        }
        store.commit(&stores[0])
        if #config(EXCHANGE_BENCHMARK_LARGE,true) {bench_case(t,stores[:],large[:],2<<30,"large")}
        bench_case(t,stores[:],small,small_bytes,"small")
    }
}

when #config(EXCHANGE_BENCHMARK,false) {

// An object of size bytes of noise, committed.
@(private="file")
bench_large :: proc(s:^store.Store,size:int) -> store.Hash {
    p,_:=store.put_begin(s)
    block:=make([]u8,4<<20)
    defer delete(block)
    state:=u64(5)
    for done:=0;done<size;done+=len(block) {
        for i:=0;i<len(block);i+=8 {(^u64)(&block[i])^=base.splitmix_next(&state)}
        store.put_write(&p,block[:min(len(block),size-done)])
    }
    root,_,_:=store.put_finish(&p)
    store.commit(s)
    return root
}

@(private="file")
Bench_Side :: struct {
    x:^Exchange,
    host:^wire.Host,
    wants:[]store.Hash,
    stop:^bool,
    done:bool,
    cpu:f64,
    jobs_cpu:f64, // of the job threads of its pump
}

@(private="file")
bench_case :: proc(t:^testing.T,stores:[]store.Store,wants:[]store.Hash,bytes:int,name:string) {
    sockets:[2]wire.Udp
    for &socket in sockets {
        if !testing.expect(t,wire.udp_open(&socket,wire.address_loopback(0)),"cannot bind a UDP socket on 127.0.0.1") {return}
    }
    defer for &socket in sockets {wire.udp_close(&socket)}
    hosts:[2]^wire.Host
    exchanges:[2]Exchange
    for &h,i in hosts {
        h=new(wire.Host)
        desc:=wire.Host_Desc{mode=i==0?.Server:.Client,transport=wire.udp_transport(&sockets[i]),channels=CHANNEL_DESCS,protocol_id=7,seed=u64(i+1),frame_bytes=8<<20,command_bytes=8<<20,command_count=1<<16}
        if !testing.expect_value(t,wire.host_init(h,desc),wire.Error.None) {return}
        testing.expect_value(t,init(&exchanges[i],{store=&stores[i],channel=0,wants=len(wants)+16}),Error.None)
    }
    defer for h,i in hosts {
        destroy(&exchanges[i])
        wire.host_destroy(h)
        free(h)
    }
    testing.expect(t,wire.worker_start(hosts[0]) && wire.worker_start(hosts[1]))
    wire.host_connect(hosts[1],sockets[0].address)
    connected:[2]bool
    for _ in 0..<2000 {
        for h,i in hosts {
            for command in wire.host_poll(h) {
                if command.kind==.Connected {
                    peer_add(&exchanges[i],h,command.connection)
                    connected[i]=true
                }
            }
        }
        if connected[0] && connected[1] {break}
        time.sleep(time.Millisecond)
    }
    if !testing.expect(t,connected[0] && connected[1],"the hosts connect") {return}
    stop:=false
    sides:=[2]Bench_Side{{x=&exchanges[0],host=hosts[0],stop=&stop},{x=&exchanges[1],host=hosts[1],wants=wants,stop=&stop}}
    worker_before:=[2]f64{bench_thread_cpu(hosts[0].worker),bench_thread_cpu(hosts[1].worker)}
    fmt.println("BENCH_START");os.flush(os.stdout)
    started:=time.tick_now()
    threads:[2]^thread.Thread
    for &side,i in sides {threads[i]=thread.create_and_start_with_data(&side,proc(data:rawptr) {bench_pump((^Bench_Side)(data))})}
    for !sync.atomic_load(&sides[1].done) && time.duration_seconds(time.tick_since(started))<900 {time.sleep(5*time.Millisecond)}
    seconds:=time.duration_seconds(time.tick_since(started))
    worker:=[2]f64{bench_thread_cpu(hosts[0].worker)-worker_before[0],bench_thread_cpu(hosts[1].worker)-worker_before[1]}
    sync.atomic_store(&stop,true)
    for th in threads {thread.join(th);thread.destroy(th)}
    wire.worker_stop(hosts[0]);wire.worker_stop(hosts[1])
    gib:=f64(bytes)/f64(1<<30)
    // The exchange's own CPU: its pump and its jobs; the worker is net's.
    fmt.printfln("EXCHANGE_RATE,case=%s,objects=%d,MiB=%d,seconds=%.2f,MiB_per_s=%.1f,objects_per_s=%.0f,sender_cpu_s_per_GiB=%.2f,receiver_cpu_s_per_GiB=%.2f,sender_exchange_s_per_GiB=%.2f,receiver_exchange_s_per_GiB=%.2f,sender_net_worker_s_per_GiB=%.2f,receiver_net_worker_s_per_GiB=%.2f,sender_pump_s=%.2f,sender_jobs_s=%.2f,receiver_pump_s=%.2f,receiver_jobs_s=%.2f",
        name,len(wants),bytes>>20,seconds,f64(bytes)/f64(1<<20)/seconds,f64(len(wants))/seconds,
        (sides[0].cpu+sides[0].jobs_cpu+worker[0])/gib,(sides[1].cpu+sides[1].jobs_cpu+worker[1])/gib,
        (sides[0].cpu+sides[0].jobs_cpu)/gib,(sides[1].cpu+sides[1].jobs_cpu)/gib,worker[0]/gib,worker[1]/gib,
        sides[0].cpu,sides[0].jobs_cpu,sides[1].cpu,sides[1].jobs_cpu)
    testing.expectf(t,sides[1].done,"%s: everything arrives",name)
}

// The pump of one side: polls its host and updates its exchange; the receiver
// wants its objects and stops once all are complete.
@(private="file")
bench_pump :: proc(s:^Bench_Side) {
    // The pump owns the job system its exchange hands reading, hashing and storing to.
    js:jobs.Job_System
    jobs.system_init(&js,{threads=#config(BENCH_THREADS,2)})
    s.x.desc.worker={system=&js,worker=jobs.OWNER}
    defer {
        sync.mutex_lock(&s.x.lock)
        work_wait_all(s.x)
        s.x.desc.worker={}
        sync.mutex_unlock(&s.x.lock)
        for &w in js.workers[1:] {s.jobs_cpu+=bench_thread_cpu(w.thread)}
        jobs.system_destroy(&js)
        s.cpu=bench_own_cpu()
    }
    for w in s.wants {want(s.x,w)}
    start:=time.tick_now()
    next:=0
    for !sync.atomic_load(s.stop) {
        for command in wire.host_poll(s.host) {
            if command.kind==.Message {receive(s.x,s.host,command)}
        }
        update(s.x,time.duration_seconds(time.tick_since(start)))
        for next<len(s.wants) {
            if p,_:=progress(s.x,s.wants[next]);p.state!=.Complete {break}
            next+=1
        }
        if len(s.wants)>0 && next==len(s.wants) {sync.atomic_store(&s.done,true)}
        free_all(context.temp_allocator)
        time.sleep(100*time.Microsecond)
    }
}

@(private="file")
bench_own_cpu :: proc() -> f64 {
    spec:posix.timespec
    posix.clock_gettime(.THREAD_CPUTIME_ID,&spec)
    return f64(spec.tv_sec)+f64(spec.tv_nsec)*1e-9
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
bench_thread_cpu :: proc(th:^thread.Thread) -> f64 {
    if th==nil {return 0}
    when ODIN_OS==.Darwin {
        info:Thread_Basic_Info
        count:=u32(size_of(info)/4)
        if thread_info(pthread_mach_thread_np(th.unix_thread),3,&info,&count)!=0 {return 0}
        return f64(info.user_s+info.system_s)+f64(info.user_us+info.system_us)*1e-6
    } else {
        return 0
    }
}

}
