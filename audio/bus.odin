package mirai_audio

import "core:math"

// Buses: every voice plays into one, every bus but the master plays into
// the one it sends to (the master unless bus_set_send says another), and the
// master, through its limiter, is what mixer_render writes out. A bus has a
// reverb, a low-pass filter, a volume and a mute, in that order, and can be
// ducked by another bus.

Bus :: distinct u16
BUS_MASTER :: Bus(0)

// While the source bus is louder than threshold, the bus is turned down by
// amount (0 does nothing, 1 silences it), getting there in attack seconds
// and coming back in release seconds. The level of the source is taken after
// its own volume and filter.
Duck :: struct {
    source:Bus,
    threshold:f32, // linear peak
    amount:f32,
    attack,release:f32,
}

@(private)
Bus_Shadow :: struct {volume:f32,muted:bool,lowpass:f32,duck:Duck,reverb:Reverb,send:Bus}
@(private)
Biquad :: struct {b0,b1,b2,a1,a2:f32}
@(private)
Mix_Bus :: struct {
    volume:f32,muted:bool,
    gain:f32, // applied at the end of the last chunk
    filter:Biquad,filtering:bool,
    filter_state:[2][2]f32, // per output channel
    duck:Duck,
    duck_gain,duck_gain_now:f32,
    peak:f32, // of the last chunk, before ducking
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
    if !bus_valid(m,bus) || !command_push(m,{kind=.Bus_Volume,index=u32(bus),value=max(volume,0)}) {return false}
    m.bus_shadows[bus].volume=max(volume,0)
    return true
}
bus_muted :: proc(m:^Mixer,bus:Bus) -> bool {return bus_valid(m,bus) && m.bus_shadows[bus].muted}
bus_set_mute :: proc(m:^Mixer,bus:Bus,muted:bool) -> bool {
    if !bus_valid(m,bus) || !command_push(m,{kind=.Bus_Mute,index=u32(bus),flag=muted}) {return false}
    m.bus_shadows[bus].muted=muted
    return true
}
// The bus a bus plays into: the master, or a bus created before it, so what
// sends never loops back.
bus_send :: proc(m:^Mixer,bus:Bus) -> Bus {return m.bus_shadows[bus].send if bus_valid(m,bus) else BUS_MASTER}
bus_set_send :: proc(m:^Mixer,bus,to:Bus) -> bool {
    if !bus_valid(m,bus) || bus==BUS_MASTER || to>=bus || !command_push(m,{kind=.Bus_Send,index=u32(bus),frames=u32(to)}) {return false}
    m.bus_shadows[bus].send=to
    return true
}
// Cutoff of the low-pass filter of the bus in Hz (12 dB per octave); 0 turns the filter off.
bus_lowpass :: proc(m:^Mixer,bus:Bus) -> f32 {return m.bus_shadows[bus].lowpass if bus_valid(m,bus) else 0}
bus_set_lowpass :: proc(m:^Mixer,bus:Bus,cutoff_hz:f32) -> bool {
    if !bus_valid(m,bus) || !command_push(m,{kind=.Bus_Lowpass,index=u32(bus),value=max(cutoff_hz,0)}) {return false}
    m.bus_shadows[bus].lowpass=max(cutoff_hz,0)
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

// Second order low-pass with no resonance (Butterworth), from the Audio EQ Cookbook.
@(private)
biquad_lowpass :: proc "contextless" (cutoff_hz,sample_rate:f32) -> Biquad {
    omega:=2*math.PI*cutoff_hz/sample_rate
    sine,cosine:=math.sin(omega),math.cos(omega)
    alpha:=sine/math.SQRT_TWO
    a0:=1+alpha
    return {b0=(1-cosine)/2/a0,b1=(1-cosine)/a0,b2=(1-cosine)/2/a0,a1=-2*cosine/a0,a2=(1-alpha)/a0}
}
@(private)
bus_lowpass_apply :: proc "contextless" (m:^Mixer,bus:^Mix_Bus,cutoff_hz:f32) {
    filtering:=cutoff_hz>0 && cutoff_hz<f32(m.sample_rate)*0.49
    if filtering {bus.filter=biquad_lowpass(cutoff_hz,f32(m.sample_rate))}
    if !filtering || !bus.filtering {bus.filter_state={}}
    bus.filtering=filtering
}

// Filter, volume and peak of one bus over n frames of its buffer.
@(private)
bus_process :: proc "contextless" (bus:^Mix_Bus,buffer:[^]f32,n:int) {
    #no_bounds_check {
        if bus.filtering {
            f:=bus.filter
            for channel in 0..<2 {
                z1,z2:=bus.filter_state[channel][0],bus.filter_state[channel][1]
                for k in 0..<n {
                    x:=buffer[k*2+channel]
                    y:=f.b0*x+z1
                    z1=f.b1*x-f.a1*y+z2
                    z2=f.b2*x-f.a2*y
                    buffer[k*2+channel]=y
                }
                bus.filter_state[channel]={z1,z2}
            }
        }
        target:=f32(0) if bus.muted else bus.volume
        gain,step:=bus.gain,(target-bus.gain)/f32(n)
        peak:=f32(0)
        for k in 0..<n {
            g:=gain+step*f32(k)
            left,right:=buffer[k*2]*g,buffer[k*2+1]*g
            buffer[k*2]=left;buffer[k*2+1]=right
            peak=max(peak,abs(left),abs(right))
        }
        bus.gain=target
        bus.peak=peak
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
            bus_process(bus,buffer,n)
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
        bus_process(&m.buses[0],master,n)
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
