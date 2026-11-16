package mirai_net

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:time"

// A transport over another that holds what it sends and what it receives by
// the conditions of a slow or lossy link: a real socket that behaves like a
// distant one. The conditions apply in each direction, so a round trip takes
// about twice the latency.
Conditioner :: struct {
    inner:Transport,
    conditions:Sim_Conditions,
    lock:sync.Mutex,
    rng:u64,
    order:u64,
    clock:proc(data:rawptr) -> f64, // seconds; time since conditioner_init when nil
    clock_data:rawptr,
    start:time.Tick,
    out,back:Delay_Line, // what goes to inner, and what came from it
    link_free:f64,
    stats:Sim_Stats,
    allocator:runtime.Allocator,
}

Conditioner_Desc :: struct {
    seed:u64,
    packets:int, // datagrams each direction holds at once; 1024 when zero
    clock:proc(data:rawptr) -> f64,
    clock_data:rawptr,
    allocator:runtime.Allocator,
}

@(private)
Delayed :: struct {time:f64,order:u64,address:Address,size:u16}

// Datagrams waiting for their time, earliest first.
@(private)
Delay_Line :: struct {
    packets:[]Delayed,
    data:[]u8,
    heap,free:[]u32,
    count,free_count:int,
}

conditioner_init :: proc(c:^Conditioner,inner:Transport,conditions:Sim_Conditions,desc:Conditioner_Desc={}) -> bool {
    allocator:=desc.allocator.procedure==nil?context.allocator:desc.allocator
    packets:=desc.packets>0?desc.packets:1024
    c^={inner=inner,conditions=conditions,rng=desc.seed,clock=desc.clock,clock_data=desc.clock_data,start=time.tick_now(),allocator=allocator}
    if !line_init(&c.out,packets,allocator) || !line_init(&c.back,packets,allocator) {conditioner_destroy(c);return false}
    return true
}
// What it still holds to send goes out now, before its time: the last thing a
// closing end sends is its goodbye, and lost here the other end only learns it
// by the timeout (and meanwhile repeats its last input). Call it while inner
// still sends.
conditioner_destroy :: proc(c:^Conditioner) {
    if c.inner.send!=nil && c.out.packets!=nil {
        sync.mutex_guard(&c.lock)
        conditioner_flush(c,max(f64))
    }
    line_destroy(&c.out,c.allocator);line_destroy(&c.back,c.allocator)
    c^={}
}
conditioner_transport :: proc "contextless" (c:^Conditioner) -> Transport {return {c,conditioner_send,conditioner_receive}}
conditioner_stats :: proc(c:^Conditioner) -> Sim_Stats {
    sync.mutex_guard(&c.lock)
    return c.stats
}

@(private)
conditioner_now :: proc(c:^Conditioner) -> f64 {
    if c.clock!=nil {return c.clock(c.clock_data)}
    return time.duration_seconds(time.tick_since(c.start))
}

// Holds a datagram for the latency and jitter of the link, or loses it.
@(private)
conditioner_hold :: proc(c:^Conditioner,line:^Delay_Line,now:f64,address:Address,bytes:[]u8,send:bool) {
    k:=c.conditions
    c.stats.sent+=1
    if rng_unit(&c.rng)<f64(k.loss) {c.stats.lost+=1;return}
    queued:f64
    if send && k.bandwidth>0 {
        start:=max(now,c.link_free)
        if start-now>(k.queue>0?k.queue:0.2) {c.stats.dropped_queue+=1;return}
        c.link_free=start+f64(len(bytes))/k.bandwidth
        queued=c.link_free-now
    }
    delay:=queued+k.latency+k.jitter*(rng_unit(&c.rng)*2-1)
    if rng_unit(&c.rng)<f64(k.reorder) {delay+=k.reorder_delay;c.stats.reordered+=1}
    if !line_push(line,now+max(delay,0),c.order,address,bytes) {c.stats.dropped_full+=1}
    c.order+=1
    if rng_unit(&c.rng)<f64(k.duplicate) {
        c.stats.duplicated+=1
        if !line_push(line,now+max(k.latency+k.jitter*(rng_unit(&c.rng)*2-1),0),c.order,address,bytes) {c.stats.dropped_full+=1}
        c.order+=1
    }
}

// Sends what is due.
@(private)
conditioner_flush :: proc(c:^Conditioner,now:f64) {
    buffer:[PACKET_BYTES]u8
    for {
        size,to,due:=line_pop(&c.out,now,buffer[:])
        if !due {return}
        c.inner.send(c.inner.data,to,buffer[:size])
        c.stats.delivered+=1
    }
}

@(private)
conditioner_send :: proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
    c:=(^Conditioner)(data)
    sync.mutex_guard(&c.lock)
    if len(bytes)>PACKET_BYTES {return false}
    now:=conditioner_now(c)
    conditioner_hold(c,&c.out,now,to,bytes,true)
    conditioner_flush(c,now)
    return true
}

@(private)
conditioner_receive :: proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
    c:=(^Conditioner)(data)
    sync.mutex_guard(&c.lock)
    now:=conditioner_now(c)
    conditioner_flush(c,now)
    incoming:[PACKET_BYTES]u8
    for {
        count,sender,received:=c.inner.receive(c.inner.data,incoming[:])
        if !received {break}
        conditioner_hold(c,&c.back,now,sender,incoming[:count],false)
    }
    size,from,ok=line_pop(&c.back,now,buffer)
    if ok {c.stats.delivered+=1}
    return
}

@(private)
line_init :: proc(l:^Delay_Line,packets:int,allocator:runtime.Allocator) -> bool {
    error:mem.Allocator_Error
    if l.packets,error=make([]Delayed,packets,allocator);error!=nil {return false}
    if l.data,error=make([]u8,packets*PACKET_BYTES,allocator);error!=nil {return false}
    if l.heap,error=make([]u32,packets,allocator);error!=nil {return false}
    if l.free,error=make([]u32,packets,allocator);error!=nil {return false}
    for &slot,i in l.free {slot=u32(packets-1-i)}
    l.free_count=packets
    return true
}
@(private)
line_destroy :: proc(l:^Delay_Line,allocator:runtime.Allocator) {
    delete(l.packets,allocator);delete(l.data,allocator);delete(l.heap,allocator);delete(l.free,allocator)
    l^={}
}
@(private)
line_before :: proc "contextless" (l:^Delay_Line,a,b:u32) -> bool {
    pa,pb:=l.packets[a],l.packets[b]
    return pa.time<pb.time || (pa.time==pb.time && pa.order<pb.order)
}
@(private)
line_push :: proc(l:^Delay_Line,at:f64,order:u64,address:Address,bytes:[]u8) -> bool {
    if l.free_count==0 || len(bytes)>PACKET_BYTES {return false}
    l.free_count-=1
    slot:=l.free[l.free_count]
    l.packets[slot]={time=at,order=order,address=address,size=u16(len(bytes))}
    copy(l.data[int(slot)*PACKET_BYTES:],bytes)
    i:=l.count
    l.count+=1
    for i>0 {
        parent:=(i-1)/2
        if !line_before(l,slot,l.heap[parent]) {break}
        l.heap[i]=l.heap[parent]
        i=parent
    }
    l.heap[i]=slot
    return true
}
// The earliest datagram whose time came, into buffer.
@(private)
line_pop :: proc(l:^Delay_Line,now:f64,buffer:[]u8) -> (size:int,address:Address,ok:bool) {
    if l.count==0 {return}
    slot:=l.heap[0]
    packet:=l.packets[slot]
    if packet.time>now {return}
    l.count-=1
    last:=l.heap[l.count]
    i:=0
    for {
        child:=i*2+1
        if child>=l.count {break}
        if child+1<l.count && line_before(l,l.heap[child+1],l.heap[child]) {child+=1}
        if !line_before(l,l.heap[child],last) {break}
        l.heap[i]=l.heap[child]
        i=child
    }
    if l.count>0 {l.heap[i]=last}
    l.free[l.free_count]=slot
    l.free_count+=1
    size=min(int(packet.size),len(buffer))
    copy(buffer,l.data[int(slot)*PACKET_BYTES:][:size])
    return size,packet.address,true
}
