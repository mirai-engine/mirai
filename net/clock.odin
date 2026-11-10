package mirai_net

import "core:math"
import "mirai:std/serial"

// Ticks are numbered alike on both ends: the client simulates tick T before
// the server does, far enough ahead that the input of T is waiting when the
// server gets there. Every datagram of the server carries its tick and how
// many ticks of input it has in hand for the connection. The client follows
// an estimate of the server's tick and says how its own tick, which its
// caller keeps, should go on: up to a tenth faster or slower than real time,
// and in one jump forward when it is far behind. It never goes back.
//
// The server's clock may be paused or run its ticks faster or slower than real
// time (a scale): it goes with every tick, and the estimate of the server's
// tick follows it, standing still while it is paused.
//
// Remote objects are shown at a server tick behind the newest one by a delay
// that grows with the jitter. That display moves with the client's tick,
// steered the same way, so what is shown at each tick is a fixed distance
// behind it.
//
// Inputs go in every datagram of the client, the newest ones not yet
// acknowledged together, each written as its difference to the one before.

Clock :: struct {
    synced:bool,
    placed:bool,       // the client's tick was put where it should be since synced
    rate:f64,          // ticks per second
    lead:f64,          // ticks of input the server should have in hand
    input_delay:f64,   // ticks ahead of its own the client submits its input for (Replication_Desc.input_delay)
    delay:f64,         // ticks behind the server that remote objects are shown, besides the jitter
    now:f64,           // seconds, as last given to clock_advance
    server:f64,        // estimate of the server's tick now
    target:f64,        // the client's tick should be here now, smoothed
    local:f64,         // the client's tick, as clock_advance left it
    display:f64,       // server tick, with fraction, at which remote objects are shown now
    rtt,jitter:f64,    // seconds
    bias:f64,          // ticks added to the lead to correct what the server reports
    dilation:f64,      // how much faster than real time the client's ticks run
    display_dilation:f64, // how much faster than the client's ticks the display runs
    jumps:u32,         // times the client's tick or the display jumped forward instead of running faster
    paused:bool,       // the server's clock, as it said last
    scale:f32,         // its ticks per tick at real time
    margin:f64,        // ticks of input the server last said it had in hand
    margin_low:f64,    // the fewest it said since clock_margin_take; max(f64): none
    display_jump:f64,  // ticks the display may fall behind before it jumps (Replication_Desc.display_jump)
    display_max:f64,   // its largest dilation (Replication_Desc.display_dilation)
}

CLOCK_SCALE_LIMIT :: f32(64)

@(private) CLOCK_JUMP_TICKS :: 30
@(private) CLOCK_MAX_DILATION :: 0.1
@(private) CLOCK_GAIN :: 0.05   // dilation per tick of error
@(private) CLOCK_SETTLE :: 0.5  // seconds the target takes to follow 1-1/e of a change

@(private)
clock_init :: proc(c:^Clock,h:^Host) {
    d:=&h.desc.replication
    c^={rate=f64(h.desc.tick_rate),lead=f64(d.input_lead),input_delay=f64(d.input_delay),delay=f64(d.interpolation_delay),scale=1,margin_low=max(f64)}
    c.display_jump=f64(d.display_jump)*c.rate
    c.display_max=f64(d.display_dilation)
}
@(private)
clock_reset :: proc(c:^Clock) {
    c.synced,c.placed,c.bias,c.dilation,c.display_dilation,c.jumps=false,false,0,0,0,0
}
// Ticks of the server per second of real time: none while it is paused.
@(private)
clock_pace :: #force_inline proc(c:^Clock) -> f64 {
    return c.paused?0:c.rate*f64(c.scale)
}
@(private)
clock_target :: #force_inline proc(c:^Clock) -> f64 {
    return c.server+(c.rtt*0.5+c.jitter*2)*clock_pace(c)+c.lead+c.bias-c.input_delay
}
@(private)
clock_display_target :: #force_inline proc(c:^Clock) -> f64 {
    return c.server-(c.rtt*0.5+c.jitter*2)*clock_pace(c)-c.delay
}
@(private)
clock_sync :: proc(c:^Clock,sample:Sync_Sample) {
    c.rtt,c.jitter=sample.rtt,sample.jitter
    c.paused,c.scale=sample.paused,sample.scale>0?sample.scale:1
    // For the moment of the last clock_advance: the next one adds the time since.
    estimate:=f64(sample.server_tick)+(sample.rtt*0.5+clamp(c.now-sample.time,-0.25,0.25))*clock_pace(c)
    if !c.synced || abs(estimate-c.server)>CLOCK_JUMP_TICKS {
        c.server=estimate
        c.synced=true
        return
    }
    c.server+=(estimate-c.server)*0.1
    if sample.has_margin {
        c.margin=f64(sample.margin)
        c.margin_low=min(c.margin_low,c.margin)
    }
    if sample.has_margin {c.bias=clamp(c.bias+(c.lead-f64(sample.margin))*0.02,-CLOCK_JUMP_TICKS,CLOCK_JUMP_TICKS)}
}

// Client: moves the clock to now (seconds, the same clock host_update or the
// worker use). local is the client's tick: the last one it simulated plus the
// part of the next one its time already covers. shift is the whole ticks to
// add to it now: once synced, wherever that puts it where it should be; after
// that only forward, when it is so far behind that running faster would take
// too long. dilation is how much faster than real time its ticks should run
// from now on, within a tenth either way; -1 until the clock heard the
// server, which runs none.
clock_advance :: proc(h:^Host,now:f64,local:f64) -> (shift:i64,dilation:f64) {
    c:=&h.front.clock
    elapsed:=clamp(now-c.now,0,0.25)
    c.now=now
    // The ticks run since the last call, as real time: they ran faster or slower by the dilation given then.
    ran:=c.placed?max(local-c.local,0)/max(1+c.dilation,0.5):0
    if !c.synced {
        c.local,c.placed,c.dilation=local,false,-1
        return 0,-1
    }
    c.server+=elapsed*clock_pace(c)
    wanted,shown:=clock_target(c),clock_display_target(c)
    c.target+=elapsed*clock_pace(c)
    if !c.placed {c.target=wanted} else {c.target+=(wanted-c.target)*(1-math.exp(-elapsed/CLOCK_SETTLE))}
    c.display+=ran*(1+c.display_dilation)
    if !c.placed {
        shift=i64(math.round(c.target-local))
        c.display=shown
        c.placed=true
    } else {
        if wanted-local>CLOCK_JUMP_TICKS {
            shift=i64(wanted-local)
            c.jumps+=1
        }
        if shown-c.display>c.display_jump {
            c.display=shown
            c.jumps+=1
        }
    }
    c.local=local+f64(shift)
    c.dilation=clamp((c.target-c.local)*CLOCK_GAIN,-CLOCK_MAX_DILATION,CLOCK_MAX_DILATION)
    c.display_dilation=clamp((shown-c.display)*CLOCK_GAIN,-c.display_max,c.display_max)
    return shift,c.dilation
}
clock_state :: proc(h:^Host) -> Clock {return h.front.clock}
// Client: the input margin the server said last and the fewest since the last call, which starts over.
clock_margin_take :: proc(h:^Host) -> (last,low:f64) {
    c:=&h.front.clock
    last,low=c.margin,c.margin_low
    c.margin_low=max(f64)
    if low==max(f64) {low=last}
    return
}
// Client: the server tick, with fraction, at which remote objects are shown in
// the state the client's tick leaves, as of the last clock_advance: one tick
// further for each tick after.
clock_interpolation_tick :: proc(h:^Host,tick:u32) -> f64 {
    c:=&h.front.clock
    return f64(tick)+1-(c.local-c.display)
}

// Start of the payload of a data datagram: the server's tick and input margin, or the client's inputs.
@(private)
time_write :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,seq:u16) -> (wrote:bool) {
    protocol:=h.desc.protocol
    if protocol==nil {return false}
    pr:=&p.repl
    if h.desc.mode==.Server {
        serial.bit_write(w,u64(h.back.tick),32)
        serial.bit_write_bool(w,h.back.paused)
        scaled:=h.back.scale!=1
        serial.bit_write_bool(w,scaled)
        if scaled {serial.bit_write(w,u64(transmute(u32)h.back.scale),32)}
        serial.bit_write_bool(w,pr.input_any)
        if pr.input_any {serial.bit_write(w,u64(u8(i8(clamp(i32(pr.input_newest-h.back.tick),-127,127)))),8)}
        return false
    }
    count:=0
    if pr.input_any {
        limit:=h.desc.replication.input_redundancy
        if pr.input_has_ack {limit=min(limit,int(max(i32(pr.input_newest-pr.input_acked),0)))}
        for count<limit && pr.input_ticks[(pr.input_newest-u32(count))%INPUT_RING]==pr.input_newest-u32(count)+1 {count+=1}
    }
    if count>0 && !record_push(p,{kind=.Input,object=pr.input_newest}) {count=0}
    serial.bit_write(w,u64(count),4)
    if count==0 {return false}
    serial.bit_write(w,u64(pr.input_newest),32)
    words:=protocol.input.words
    previous:[]u32
    for i in 0..<count {
        tick:=pr.input_newest-u32(count-1-i)
        current:=pr.inputs[int(tick%INPUT_RING)*words:][:words]
        state_write(w,&protocol.input,protocol.input.all,current,previous)
        previous=current
    }
    wrote=pr.input_sent!=pr.input_newest
    pr.input_sent=pr.input_newest
    return
}

@(private)
// A late datagram only reads past the clock of the server, which is older than what arrived since; the
// inputs of a client keep only the ticks not seen yet either way.
time_read :: proc(h:^Host,p:^Peer,rd:^serial.Bit_Reader,late:=false) -> bool {
    protocol:=h.desc.protocol
    if protocol==nil {return true}
    r:=&h.back.repl
    pr:=&p.repl
    if h.desc.mode==.Client {
        tick:=u32(serial.bit_read(rd,32))
        paused:=serial.bit_read_bool(rd)
        scale:=f32(1)
        if serial.bit_read_bool(rd) {scale=transmute(f32)u32(serial.bit_read(rd,32))}
        has_margin:=serial.bit_read_bool(rd)
        margin:=has_margin?i32(i8(u8(serial.bit_read(rd,8)))):0
        if rd.error || !(scale>0 && scale<=CLOCK_SCALE_LIMIT) {return false}
        if late {return true}
        r.remote_tick=tick
        h.back.outbox.sync={valid=true,server_tick=tick,margin=margin,has_margin=has_margin,rtt=p.rtt,jitter=p.jitter,time=h.back.now,paused=paused,scale=scale}
        return true
    }
    count:=int(serial.bit_read(rd,4))
    if count==0 {return !rd.error}
    if count>8 || !protocol.has_input {return false}
    newest:=u32(serial.bit_read(rd,32))
    words:=protocol.input.words
    current,previous:=r.words[:words],r.previous[:words]
    for i in 0..<count {
        tick:=newest-u32(count-1-i)
        for &word in current {word=0}
        state_read(rd,&protocol.input,protocol.input.all,current,i==0?nil:previous) or_return
        copy(previous,current)
        if pr.input_any && i32(tick-pr.input_newest)<=0 {continue}
        // Further ahead would take the slot of a tick not yet simulated.
        if i32(tick-h.back.tick)>i32(h.history) {p.stats.inputs_early+=1;continue}
        if pr.input_any {p.stats.inputs_missed+=u64(max(i32(tick-pr.input_newest)-1,0))}
        pr.input_newest,pr.input_any=tick,true
        p.stats.inputs_received+=1
        if command:=command_push(h,{kind=.Input,connection=peer_handle(h,p),tick=tick},nil,words);command!=nil {copy(command.words,current)}
    }
    return !rd.error
}

