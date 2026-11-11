package mirai_audio

import "base:runtime"

// Reverbs, as Freeverb makes them (Jezar at Dreampoint, public domain): eight
// damped comb filters in parallel and four all-pass filters in series per
// output, the right ones a little longer. The mixer has two kinds:
//
//   - The room: voices send it a share of what they play (Voice_Desc.reverb)
//     and what it returns plays in a bus. One for the mixer: the room the
//     listener is in.
//   - One per bus, on what the bus plays before its filter and its volume: a
//     song in its own bus, made to sound in a hall.

Reverb :: struct {
    room_size:f32 `mirai:"min=0,max=1"`, // how long its tail lasts
    damping:f32 `mirai:"min=0,max=1"`,   // how fast the highs of its tail die
    wet:f32 `mirai:"min=0"`,             // gain of what it returns; 0 turns it off
    width:f32 `mirai:"min=0,max=1"`,     // from mono to wide stereo
}

@(private) REVERB_COMBS :: [8]int{1116,1188,1277,1356,1422,1491,1557,1617} // frames at 44100 Hz
@(private) REVERB_ALLPASSES :: [4]int{556,441,341,225}
@(private) REVERB_SPREAD :: 23
@(private) REVERB_INPUT :: f32(0.015)

@(private)
Delay :: struct {
    buffer:[]f32,
    at:int,
    store:f32, // what the damping of a comb kept
}

@(private)
Reverb_Unit :: struct {
    params:Reverb,
    wet_now:f32,  // reached at the end of the last chunk
    silent:bool,  // its delays hold zeros
    combs:[2][len(REVERB_COMBS)]Delay,
    allpasses:[2][len(REVERB_ALLPASSES)]Delay,
    memory:[]f32,
}

@(private)
Reverb_Shadow :: struct {params:Reverb,bus:Bus}

@(private)
reverb_init :: proc(m:^Mixer,u:^Reverb_Unit) -> Error {
    scale:=f64(m.sample_rate)/44100
    length :: proc(frames:int,scale:f64) -> int {return max(int(f64(frames)*scale+0.5),1)}
    total:=0
    for side in 0..<2 {
        for frames in REVERB_COMBS {total+=length(frames+side*REVERB_SPREAD,scale)}
        for frames in REVERB_ALLPASSES {total+=length(frames+side*REVERB_SPREAD,scale)}
    }
    failed:runtime.Allocator_Error
    if u.memory,failed=make([]f32,total,m.allocator);failed!=nil {return .Out_Of_Memory}
    at:=0
    for side in 0..<2 {
        for frames,i in REVERB_COMBS {
            count:=length(frames+side*REVERB_SPREAD,scale)
            u.combs[side][i].buffer=u.memory[at:][:count]
            at+=count
        }
        for frames,i in REVERB_ALLPASSES {
            count:=length(frames+side*REVERB_SPREAD,scale)
            u.allpasses[side][i].buffer=u.memory[at:][:count]
            at+=count
        }
    }
    u.silent=true
    return .None
}

@(private)
reverb_clamp :: proc "contextless" (r:Reverb) -> Reverb {
    return {clamp(r.room_size,0,1),clamp(r.damping,0,1),max(r.wet,0),clamp(r.width,0,1)}
}

// The room reverb of the mixer and the bus its return plays in. A wet of 0
// turns it off; its tail fades over a chunk.
reverb_set :: proc(m:^Mixer,reverb:Reverb,bus:Bus=BUS_MASTER) -> bool {
    if !bus_valid(m,bus) {return false}
    r:=reverb_clamp(reverb)
    if !command_push(m,{kind=.Reverb,index=u32(bus),vectors={{r.room_size,r.damping,r.wet},{}},value=r.width}) {return false}
    m.reverb_shadow={r,bus}
    return true
}
reverb_get :: proc(m:^Mixer) -> (reverb:Reverb,bus:Bus) {return m.reverb_shadow.params,m.reverb_shadow.bus}

// The reverb of a bus, on all it plays; what it returns adds to what the bus
// plays dry. A wet of 0 turns it off.
bus_set_reverb :: proc(m:^Mixer,bus:Bus,reverb:Reverb) -> bool {
    if !bus_valid(m,bus) {return false}
    r:=reverb_clamp(reverb)
    if !command_push(m,{kind=.Bus_Reverb,index=u32(bus),vectors={{r.room_size,r.damping,r.wet},{}},value=r.width}) {return false}
    m.bus_shadows[bus].reverb=r
    return true
}
bus_reverb :: proc(m:^Mixer,bus:Bus) -> Reverb {return m.bus_shadows[bus].reverb if bus_valid(m,bus) else {}}

@(private)
reverb_command :: proc "contextless" (command:^Command) -> Reverb {
    return {command.vectors[0][0],command.vectors[0][1],command.vectors[0][2],command.value}
}

// Adds to out what a reverb makes of n stereo frames of input; out may be input.
@(private)
reverb_run :: proc "contextless" (u:^Reverb_Unit,input,out:[^]f32,n:int) {
    if u.params.wet<=0 && u.wet_now<=0 {
        if !u.silent {
            for &sample in u.memory {sample=0}
            for &side in u.combs {for &comb in side {comb.store=0}}
            u.silent=true
        }
        return
    }
    u.silent=false
    feedback:=u.params.room_size*0.28+0.7
    damp:=u.params.damping*0.4
    wet0,dw:=u.wet_now,(u.params.wet-u.wet_now)/f32(n)
    width:=u.params.width
    #no_bounds_check for k in 0..<n {
        x:=(input[k*2]+input[k*2+1])*REVERB_INPUT
        sides:[2]f32
        for side in 0..<2 {
            sum:=f32(0)
            for &comb in u.combs[side] {
                y:=comb.buffer[comb.at]
                comb.store=y*(1-damp)+comb.store*damp
                comb.buffer[comb.at]=x+comb.store*feedback
                comb.at+=1
                if comb.at==len(comb.buffer) {comb.at=0}
                sum+=y
            }
            for &allpass in u.allpasses[side] {
                delayed:=allpass.buffer[allpass.at]
                allpass.buffer[allpass.at]=sum+delayed*0.5
                sum=delayed-sum
                allpass.at+=1
                if allpass.at==len(allpass.buffer) {allpass.at=0}
            }
            sides[side]=sum
        }
        wet:=wet0+dw*f32(k)
        same,other:=wet*(width*0.5+0.5),wet*((1-width)*0.5)
        out[k*2]+=sides[0]*same+sides[1]*other
        out[k*2+1]+=sides[1]*same+sides[0]*other
    }
    u.wet_now=u.params.wet
}
