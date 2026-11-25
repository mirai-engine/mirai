package echo

import "mirai:core"
import audio "mirai:engine/audio"

// The echo of a bus, a canyon or a radio: what comes in plays at once and
// again seconds later, each echo feedback times the last (miniaudio's
// ma_delay with its decay as feedback). A project gives it to the buses that
// want it in its Bus_Echoes; it runs as an effect of the bus
// (audio.bus_effect_set), after its filters, and a bus without one reserves
// nothing and runs nothing for it. The line of each is reserved when the
// settings ask for it, long enough for its seconds: a change of settings is a
// transaction. A change of time crossfades from the old tap to the new one
// over a chunk, and wet and feedback ramp across it, so it never clicks;
// taken out, its echoes fade over a chunk before the line is freed.

ECHO_CAPACITY :: 4
ECHO_SECONDS_MAX :: f32(2)
ECHO_FEEDBACK_MAX :: f32(0.95)
// What the effect of a bus says it is, the same across reloads of this code.
ECHO_EFFECT :: u64(0x6563686f) // "echo"

Echo :: struct {
    bus:audio.Audio_Bus,
    seconds:f32 `mirai:"min=0,max=2,unit=s"`, // between the sound and its first echo
    feedback:f32 `mirai:"min=0,max=0.95"`,    // share of each echo that echoes again
    wet:f32 `mirai:"min=0"`,                  // gain of the echoes; 0: none
}

// One entry per bus with an echo, the first of a bus being the one that counts.
@(storage,setting)
Bus_Echoes :: struct {
    echoes:[ECHO_CAPACITY]Echo `mirai:"trim"`,
}

@(storage,host)
Echo_Applied :: struct {
    world:core.World_Id,
    settings:core.Seen,
    set:bool, // the mixer has what the settings say
}

// The state of an echo: its line, then 2*frames f32 of it.
@(private)
Line :: struct {
    frames:int,            // stereo frames, a power of two
    write:int,
    tap:int,               // frames of the tap at the end of the last chunk; 0 before the first
    wet,feedback:f32,      // reached at the end of the last chunk
}
#assert(size_of(Line)%8==0)

@(step="late",stage="end")
echo_buses :: proc(echoes:core.Ref(Bus_Echoes),stamp:core.Stamp(Bus_Echoes),applied:^Echo_Applied,m:^audio.Mixer,id:core.World_Id,problems:^core.Problems) {
    if m==nil || applied==nil {return}
    changed:=core.touched(stamp,&applied.settings)
    if applied.set && applied.world==id && !changed {return}
    applied.set,applied.world=echoes_apply(m,echoes.ptr,problems),id
}

// Gives every bus the echo the settings say, or none; false while what the
// mixer has is not that yet, which a later frame finishes.
echoes_apply :: proc(m:^audio.Mixer,echoes:^Bus_Echoes,problems:^core.Problems) -> (done:bool) {
    done=true
    for bus in 0..<audio.AUDIO_BUS_CAPACITY {
        bus:=audio.Audio_Bus(bus)
        wanted:Echo
        if echoes!=nil {
            for e in echoes.echoes {
                if e.bus==bus && e.wet>0 {wanted=e;break}
            }
        }
        slot,free:=-1,-1
        for at in 0..<audio.BUS_EFFECT_SLOTS {
            effect:=audio.bus_effect(m,bus,at)
            if effect.id==ECHO_EFFECT {slot=at} else if effect.process==nil && free<0 {free=at}
        }
        params:=[audio.BUS_EFFECT_PARAMS]f32{clamp(wanted.seconds,0,ECHO_SECONDS_MAX),clamp(wanted.feedback,0,ECHO_FEEDBACK_MAX),wanted.wet if wanted.wet<=max(f32) else 0,0}
        if !(params[0]>=0) {params[0]=0}
        if !(params[1]>=0) {params[1]=0}
        current:=audio.bus_effect(m,bus,slot) if slot>=0 else {}
        if !(params[2]>0) {
            if slot<0 {continue}
            // Its echoes fade out first, and it goes on a later frame.
            done=false
            if current.params[2]!=0 {audio.bus_effect_params_set(m,bus,slot,{current.params[0],current.params[1],0,0})} else {audio.bus_effect_set(m,bus,slot,{})}
            continue
        }
        bytes:=line_bytes(params[0],m.sample_rate)
        if slot>=0 && current.process==echo_run && len(current.state)>=bytes {
            if current.params!=params && !audio.bus_effect_params_set(m,bus,slot,params) {done=false}
            continue
        }
        if slot<0 {slot=free}
        if slot<0 {
            core.report(problems,core.NONE,"echo.slots","Bus_Echoes: bus %d has no free effect slot for its echo: take another effect out of it",int(bus))
            continue
        }
        state,failed:=make([]u8,bytes,m.allocator)
        if failed!=nil {
            core.report(problems,core.NONE,"echo.memory","Bus_Echoes: the echo of bus %d did not start: out of memory for its line of %d bytes; free memory or shorten it",int(bus),bytes)
            done=false
            continue
        }
        (^Line)(raw_data(state))^={frames=(bytes-size_of(Line))/8}
        if !audio.bus_effect_set(m,bus,slot,{id=ECHO_EFFECT,process=echo_run,state=state,params=params}) {
            delete(state,m.allocator)
            done=false
        }
    }
    return
}

// Bytes of the state of an echo of seconds: its line past the time by a chunk, a power of two of frames.
@(private)
line_bytes :: proc "contextless" (seconds:f32,sample_rate:int) -> int {
    frames:=audio.BUS_EFFECT_FRAMES
    for frames<int(seconds*f32(sample_rate))+audio.BUS_EFFECT_FRAMES {frames*=2}
    return size_of(Line)+frames*2*size_of(f32)
}

// Adds the echoes of a bus to its n frames, in place: params are seconds,
// feedback and wet.
@(private)
echo_run :: proc "contextless" (state:[]u8,params:[audio.BUS_EFFECT_PARAMS]f32,buffer:[^]f32,n,sample_rate:int) {
    line:=(^Line)(raw_data(state))
    memory:=([^]f32)(raw_data(state[size_of(Line):]))
    tap:=clamp(int(params[0]*f32(sample_rate)+0.5),1,line.frames-audio.BUS_EFFECT_FRAMES)
    old:=line.tap if line.tap!=0 else tap
    mask:=line.frames-1
    wet0,feedback0:=line.wet,line.feedback
    dwet,dfeedback:=(params[2]-wet0)/f32(n),(params[1]-feedback0)/f32(n)
    #no_bounds_check for k in 0..<n {
        t:=f32(k)/f32(n)
        wet,feedback:=wet0+dwet*f32(k),feedback0+dfeedback*f32(k)
        w:=(line.write+k)&mask
        r:=(line.write+k-tap)&mask
        o:=(line.write+k-old)&mask
        for c in 0..<2 {
            echo:=memory[r*2+c]
            if old!=tap {
                before:=memory[o*2+c]
                echo=before+(echo-before)*t
            }
            x:=buffer[k*2+c]
            memory[w*2+c]=x+feedback*echo
            buffer[k*2+c]=x+wet*echo
        }
    }
    line.write=(line.write+n)&mask
    line.tap,line.wet,line.feedback=tap,params[2],params[1]
}
