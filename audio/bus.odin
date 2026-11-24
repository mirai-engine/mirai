package mirai_audio

import "core:math"
import "core:sync"

// Buses: every voice plays into one, every bus but the master plays into
// the one it sends to (the master unless bus_set_send says another), and the
// master, through its limiter, is what mixer_render writes out. A bus has a
// reverb, BUS_FILTERS filters, a delay, a volume and a mute, in that order,
// can be ducked by another bus and soloed, and meters what it plays.

Bus :: distinct u16
BUS_MASTER :: Bus(0)

// While the source bus is louder than threshold, the bus is turned down by
// amount (0 does nothing, 1 silences it), getting there in attack seconds
// and coming back in release seconds. The level of the source is taken after
// its own volume and filters.
Duck :: struct {
    source:Bus,
    threshold:f32, // linear peak
    amount:f32,
    attack,release:f32,
}

// A meter falls this many dB a second from the last peak it held.
METER_FALL :: f32(20)

@(private)
Bus_Shadow :: struct {
    volume:f32,
    muted,soloed:bool,
    silent:bool, // what the audio thread was told: muted, or left out by a solo
    filters:[BUS_FILTERS]Filter,
    delay:Delay,
    duck:Duck,reverb:Reverb,send:Bus,
}
@(private)
Mix_Bus :: struct {
    volume:f32,silent:bool,
    gain:f32, // applied at the end of the last chunk
    filters:[BUS_FILTERS]Biquad_Fade,
    delay:Delay_Line,
    duck:Duck,
    duck_gain,duck_gain_now:f32,
    peak:f32, // of the last chunk, before ducking
    meter:[2]f32, // per channel: the peak, falling METER_FALL dB a second
    send:Bus,
}

// The master is held under LIMITER_CEILING (Godot's AudioEffectHardLimiter
// without its lookahead, so the mix keeps no latency): a sample that would
// pass it brings the gain down to it at once, the gain holds for LIMITER_HOLD
// and comes back to 1 over LIMITER_RELEASE.
LIMITER_CEILING :: f32(1)     // full scale
LIMITER_HOLD :: f32(0.02)    // s
LIMITER_RELEASE :: f32(0.1)  // s

@(private)
Limiter :: struct {
    gain,floor:f32, // now, and where its release started
    hold:int,       // frames left before it releases
}

// Reserves a bus. Buses are never destroyed.
bus_create :: proc(m:^Mixer) -> (bus:Bus,ok:bool) {
    if m.bus_count>=len(m.bus_shadows) {return 0,false}
    m.bus_count+=1
    return Bus(m.bus_count-1),true
}
@(private)
bus_valid :: proc(m:^Mixer,bus:Bus) -> bool {return int(bus)<m.bus_count}
// The buses reserved, the master included: Bus(0) to Bus(count-1).
bus_count :: proc(m:^Mixer) -> int {return m.bus_count}

bus_volume :: proc(m:^Mixer,bus:Bus) -> f32 {return m.bus_shadows[bus].volume if bus_valid(m,bus) else 0}
bus_set_volume :: proc(m:^Mixer,bus:Bus,volume:f32) -> bool {
    if !bus_valid(m,bus) || !finite(volume) || !command_push(m,{kind=.Bus_Volume,index=u32(bus),value=max(volume,0)}) {return false}
    m.bus_shadows[bus].volume=max(volume,0)
    return true
}
// A muted bus keeps its volume for when it comes back.
bus_muted :: proc(m:^Mixer,bus:Bus) -> bool {return bus_valid(m,bus) && m.bus_shadows[bus].muted}
bus_set_mute :: proc(m:^Mixer,bus:Bus,muted:bool) -> bool {
    if !bus_valid(m,bus) {return false}
    m.bus_shadows[bus].muted=muted
    return buses_silence(m)
}
// While any bus is soloed only the soloed ones are heard, with the buses
// that play into them and those they play into on their way to the master
// (Godot's solo, which also keeps what plays into a soloed bus). The master
// cannot be soloed.
bus_soloed :: proc(m:^Mixer,bus:Bus) -> bool {return bus_valid(m,bus) && m.bus_shadows[bus].soloed}
bus_set_solo :: proc(m:^Mixer,bus:Bus,soloed:bool) -> bool {
    if !bus_valid(m,bus) || bus==BUS_MASTER {return false}
    m.bus_shadows[bus].soloed=soloed
    return buses_silence(m)
}
// Whether a bus is silent: muted, or left out by a solo.
bus_silent :: proc(m:^Mixer,bus:Bus) -> bool {return bus_valid(m,bus) && m.bus_shadows[bus].silent}
// The bus a bus plays into: the master, or a bus created before it, so what
// sends never loops back.
bus_send :: proc(m:^Mixer,bus:Bus) -> Bus {return m.bus_shadows[bus].send if bus_valid(m,bus) else BUS_MASTER}
bus_set_send :: proc(m:^Mixer,bus,to:Bus) -> bool {
    if !bus_valid(m,bus) || bus==BUS_MASTER || to>=bus || !command_push(m,{kind=.Bus_Send,index=u32(bus),frames=u32(to)}) {return false}
    m.bus_shadows[bus].send=to
    return buses_silence(m)
}
// Filter band of a bus, 0 to BUS_FILTERS-1; they run in that order.
bus_filter :: proc(m:^Mixer,bus:Bus,band:int) -> Filter {
    if !bus_valid(m,bus) || band<0 || band>=BUS_FILTERS {return {}}
    return m.bus_shadows[bus].filters[band]
}
// False for a band or a filter out of range (filter_valid).
bus_set_filter :: proc(m:^Mixer,bus:Bus,band:int,filter:Filter) -> bool {
    if !bus_valid(m,bus) || band<0 || band>=BUS_FILTERS || !filter_valid(filter) {return false}
    if !command_push(m,{kind=.Bus_Filter,index=u32(bus),frames=u32(band),filter=filter}) {return false}
    m.bus_shadows[bus].filters[band]=filter
    return true
}
bus_delay :: proc(m:^Mixer,bus:Bus) -> Delay {return m.bus_shadows[bus].delay if bus_valid(m,bus) else {}}
// Reserves the line of the bus the first time it is given a delay (a
// transaction): false without memory for it, or for a value that is not a number.
bus_set_delay :: proc(m:^Mixer,bus:Bus,delay:Delay) -> bool {
    if !bus_valid(m,bus) || !finite(delay.seconds) || !finite(delay.feedback) || !finite(delay.wet) {return false}
    delay:=delay_clamp(delay)
    if m.delay_memory[bus]==nil && delay.wet>0 {
        memory,failed:=make([]f32,delay_line_frames(m.sample_rate)*2,m.allocator)
        if failed!=nil {return false}
        m.delay_memory[bus]=memory
    }
    if !command_push(m,{kind=.Bus_Delay,index=u32(bus),vectors={{delay.seconds,delay.feedback,delay.wet},{},{}},delay_memory=m.delay_memory[bus]}) {return false}
    m.bus_shadows[bus].delay=delay
    return true
}
bus_duck :: proc(m:^Mixer,bus:Bus) -> Duck {return m.bus_shadows[bus].duck if bus_valid(m,bus) else {}}
// A Duck with amount 0 stops the ducking. The master cannot be ducked, and a
// bus cannot duck itself.
bus_set_duck :: proc(m:^Mixer,bus:Bus,duck:Duck) -> bool {
    if !bus_valid(m,bus) || !bus_valid(m,duck.source) || bus==BUS_MASTER || duck.source==bus {return false}
    duck:=duck
    duck.amount=clamp(duck.amount,0,1)
    if !command_push(m,{kind=.Bus_Duck,index=u32(bus),duck=duck}) {return false}
    m.bus_shadows[bus].duck=duck
    return true
}
// The level of each output channel of a bus, linear, after its volume: the
// peak of what it played, falling METER_FALL dB a second. Any thread may read
// it; the audio thread writes it every chunk.
bus_meter :: proc "contextless" (m:^Mixer,bus:Bus) -> (meter:[2]f32) {
    if int(bus)>=len(m.bus_meters) {return}
    for &level,c in meter {level=transmute(f32)sync.atomic_load_explicit(&m.bus_meters[bus][c],.Relaxed)}
    return
}

// Tells the audio thread which buses are silent, by their mutes and solos;
// false when the queue was full for one of them, which a later change sends.
@(private)
buses_silence :: proc(m:^Mixer) -> bool {
    shadows:=m.bus_shadows[:m.bus_count]
    solo:=false
    for shadow in shadows[1:] {solo||=shadow.soloed}
    ok:=true
    for &shadow,i in shadows {
        silent:=shadow.muted || solo && i!=0 && !bus_on_solo(m,Bus(i))
        if silent==shadow.silent {continue}
        if !command_push(m,{kind=.Bus_Mute,index=u32(i),flag=silent}) {ok=false;continue}
        shadow.silent=silent
    }
    return ok
}
// Whether a bus is soloed, plays into a soloed one, or a soloed one plays through it.
@(private)
bus_on_solo :: proc(m:^Mixer,bus:Bus) -> bool {
    for at:=bus;;at=m.bus_shadows[at].send {
        if m.bus_shadows[at].soloed {return true}
        if at==BUS_MASTER {break}
    }
    for shadow,i in m.bus_shadows[1:m.bus_count] {
        if !shadow.soloed {continue}
        for at:=Bus(i+1);at!=BUS_MASTER; {
            at=m.bus_shadows[at].send
            if at==bus {return true}
        }
    }
    return false
}

// Filters, delay, volume, peak and meter of one bus over n frames of its buffer.
@(private)
bus_process :: proc "contextless" (m:^Mixer,index:int,buffer:[^]f32,n:int) {
    bus:=&m.buses[index]
    for &f in bus.filters {
        if f.on || f.fading {biquad_fade_run(&f,buffer,0,n)}
    }
    delay_run(&bus.delay,buffer,n)
    target:=f32(0) if bus.silent else bus.volume
    gain,step:=bus.gain,(target-bus.gain)/f32(n)
    peaks:[2]f32
    #no_bounds_check for k in 0..<n {
        g:=gain+step*f32(k)
        left,right:=buffer[k*2]*g,buffer[k*2+1]*g
        buffer[k*2]=left;buffer[k*2+1]=right
        peaks={max(peaks[0],abs(left)),max(peaks[1],abs(right))}
    }
    bus.gain=target
    bus.peak=max(peaks[0],peaks[1])
    fall:=m.meter_fall if n==CHUNK_FRAMES else math.pow(10,-METER_FALL*f32(n)/(20*f32(m.sample_rate)))
    for c in 0..<2 {
        bus.meter[c]=max(peaks[c],bus.meter[c]*fall)
        if bus.meter[c]<1e-6 {bus.meter[c]=0}
        sync.atomic_store_explicit(&m.bus_meters[index][c],transmute(u32)bus.meter[c],.Relaxed)
    }
}

// Sums each bus into the one it sends to, the last created first, and writes
// the master to out. A bus ducked by one created before it hears the peak of
// that one in the last chunk.
@(private)
buses_mix :: proc "contextless" (m:^Mixer,out:[]f32,n:int) {
    master:=raw_data(m.bus_buffers)
    #no_bounds_check {
        for i:=len(m.buses)-1;i>=1;i-=1 {
            bus:=&m.buses[i]
            buffer:=master[i*CHUNK_FRAMES*2:]
            reverb_run(&m.bus_reverbs[i],buffer,buffer,n)
            bus_process(m,i,buffer,n)
            to:=master[int(bus.send)*CHUNK_FRAMES*2:]
            target:=f32(1)
            if bus.duck.amount>0 {
                wanted:=1-bus.duck.amount if m.buses[bus.duck.source].peak>bus.duck.threshold else 1
                seconds:=bus.duck.attack if wanted<bus.duck_gain else bus.duck.release
                // The whole swing takes the attack or the release time.
                reach:=bus.duck.amount*f32(n)/(seconds*f32(m.sample_rate)) if seconds>0 else 1
                target=bus.duck_gain+clamp(wanted-bus.duck_gain,-reach,reach)
            }
            bus.duck_gain=target
            if bus.peak==0 && target==bus.duck_gain_now {continue}
            gain,step:=bus.duck_gain_now,(target-bus.duck_gain_now)/f32(n)
            for k in 0..<n {
                g:=gain+step*f32(k)
                to[k*2]+=buffer[k*2]*g
                to[k*2+1]+=buffer[k*2+1]*g
            }
            bus.duck_gain_now=target
        }
        reverb_run(&m.bus_reverbs[0],master,master,n)
        bus_process(m,0,master,n)
        if m.channels==2 {
            for i in 0..<n*2 {out[i]=master[i]}
        } else {
            // Constant power: a centered mono sound comes out of the one speaker as loud as it was played.
            for k in 0..<n {out[k]=(master[k*2]+master[k*2+1])*(math.SQRT_TWO/2)}
        }
    }
    limiter_run(&m.limiter,out,m.channels,m.sample_rate)
}

@(private)
limiter_run :: proc "contextless" (l:^Limiter,out:[]f32,channels,sample_rate:int) {
    hold,release:=int(LIMITER_HOLD*f32(sample_rate)),LIMITER_RELEASE*f32(sample_rate)
    #no_bounds_check for k in 0..<len(out)/channels {
        frame:=out[k*channels:][:channels]
        peak:=f32(0)
        for x in frame {peak=max(peak,abs(x))}
        if l.hold>0 {
            l.hold-=1
        } else if l.gain<1 {
            l.gain=min(l.gain+(1-l.floor)/release,1)
        }
        if peak*l.gain>LIMITER_CEILING {
            l.gain=LIMITER_CEILING/peak
            l.floor,l.hold=l.gain,hold
        }
        for &x in frame {x*=l.gain}
    }
}
