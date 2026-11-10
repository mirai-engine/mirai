package mirai_audio

import "core:math"
import mm "mirai:std/math"

// Positional audio. Right-handed, Y up, meters: a listener with no rotation
// looks down -Z and has +X at its right.

Attenuation_Model :: enum u8 {
    None,        // the same level at any distance
    Inverse,     // min/(min+rolloff*(d-min)): halves at twice the minimum distance with rolloff 1
    Linear,      // 1-rolloff*(d-min)/(max-min): silent at the maximum distance with rolloff 1
    Exponential, // (d/min)^-rolloff
}
// The distance is clamped to [min_distance,max_distance] before the model
// is applied: nearer than the minimum the gain is 1, beyond the maximum it
// stops falling.
Attenuation :: struct {
    model:Attenuation_Model,
    min_distance,max_distance:f32,
    rolloff:f32,
}
ATTENUATION_DEFAULT :: Attenuation{model=.Inverse,min_distance=1,max_distance=100,rolloff=1}

// What the output plays on. Speakers pan each spatial voice between them;
// headphones hear it through the HRTF of its direction, which tells ahead from
// behind and above from below. A mono output plays every voice centered.
Output_Kind :: enum u8 {Speakers,Headphones}

@(private)
Listener :: struct {
    position,velocity:[3]f32,
    rotation:quaternion128,
}

attenuation_gain :: proc "contextless" (a:Attenuation,distance:f32) -> f32 {
    low:=max(a.min_distance,1e-4)
    high:=max(a.max_distance,low)
    d:=clamp(distance,low,high)
    switch a.model {
    case .None:return 1
    case .Inverse:return low/(low+a.rolloff*(d-low))
    case .Linear:
        if high<=low {return 1}
        return clamp(1-a.rolloff*(d-low)/(high-low),0,1)
    case .Exponential:return math.pow(d/low,-a.rolloff)
    }
    return 1
}

// Constant power: the two gains always add up to the same energy, so a sound
// is as loud at the center (0.707 on each side) as hard to one side (1 and 0).
pan_gains :: proc "contextless" (pan:f32) -> [2]f32 {
    angle:=(clamp(pan,-1,1)+1)*(math.PI/4)
    return {math.cos(angle),math.sin(angle)}
}
// Balance of a stereo sound: the side it moves away from is turned down, the
// other one stays as it is.
balance_gains :: proc "contextless" (pan:f32) -> [2]f32 {
    p:=clamp(pan,-1,1)
    return {min(1,1-p),min(1,1+p)}
}

// Where a source is for a listener: the unit direction in the listener's
// space (+X right, +Y up, -Z ahead) and the distance. A source at the
// listener comes from above.
listener_direction :: proc "contextless" (listener_position:[3]f32,listener_rotation:quaternion128,source:[3]f32) -> (direction:[3]f32,distance:f32) {
    offset:=source-listener_position
    distance=math.sqrt(offset.x*offset.x+offset.y*offset.y+offset.z*offset.z)
    if !(distance>1e-5) || !finite(distance) {return {0,1,0},0}
    return mm.quat_rotate(conj(quat_unit(listener_rotation)),offset/distance),distance
}

// Factor on the pitch of a source heard by a listener, both moving. factor
// scales the effect: 0 turns it off, 1 is the physical one.
doppler_pitch :: proc "contextless" (listener_position,listener_velocity,source_position,source_velocity:[3]f32,factor,speed_of_sound:f32) -> f32 {
    if !(factor>0) || !(speed_of_sound>0) {return 1}
    to_listener:=listener_position-source_position
    distance:=math.sqrt(to_listener.x*to_listener.x+to_listener.y*to_listener.y+to_listener.z*to_listener.z)
    if !(distance>=1e-5) {return 1}
    direction:=to_listener/distance
    // Speeds along the line from the source to the listener; neither reaches the speed of sound.
    limit:=speed_of_sound/factor*0.99
    listener_speed:=clamp(listener_velocity.x*direction.x+listener_velocity.y*direction.y+listener_velocity.z*direction.z,-limit,limit)
    source_speed:=clamp(source_velocity.x*direction.x+source_velocity.y*direction.y+source_velocity.z*direction.z,-limit,limit)
    return clamp((speed_of_sound-factor*listener_speed)/(speed_of_sound-factor*source_speed),0.25,4)
}

// The gains of a spatial voice as those of a voice panned on two speakers:
// its volume by the gain of its direct path, between the speakers on Speakers
// (PanningEffect::stereoPanningWeight: the side once brought to the horizontal
// plane, so ahead and behind both sit in the middle) and centered otherwise.
@(private)
spatial_gains :: proc "contextless" (m:^Mixer,v:^Mix_Voice) -> [4]f32 {
    if v.spatial_dirty || v.listener_serial!=m.listener_serial {
        l:=m.listener
        direction,distance:=listener_direction(l.position,l.rotation,v.position)
        directivity:=directivity_gain(v.directivity,v.position,v.rotation,l.position)
        v.direct_gain,v.eq_target=direct_gain_eq(attenuation_gain(v.attenuation,distance),directivity,air_absorption(distance),v.occlusion,v.transmission)
        v.direction=direction
        v.spatial_pitch=doppler_pitch(l.position,l.velocity,v.position,v.velocity,v.doppler,m.speed_of_sound)
        v.spatial_dirty=false;v.listener_serial=m.listener_serial
    }
    pan:=f32(0)
    if horizontal:=math.sqrt(v.direction.x*v.direction.x+v.direction.z*v.direction.z);m.output_now==.Speakers && m.channels==2 && horizontal>1e-6 {pan=v.direction.x/horizontal}
    sides:=pan_gains(pan)*(v.volume*v.direct_gain)
    // A stereo sound that has a place in the world is heard as one source.
    if v.source.channels==2 {return {sides[0]*0.5,sides[1]*0.5,sides[0]*0.5,sides[1]*0.5}}
    return {sides[0],sides[1],0,0}
}

// The EQ of a voice is left out while all its bands are within EQ_FLAT of unity.
@(private)
eq_flat :: proc "contextless" (gains:[BANDS]f32) -> bool {
    return gains[0]>=EQ_FLAT && gains[1]>=EQ_FLAT && gains[2]>=EQ_FLAT
}

// A spatial voice that goes through its EQ or its HRTF is mixed apart as one
// source into the left channel: its gains (base and target) lose their pan,
// which spatial_post applies. Any other is mixed as a panned voice.
@(private)
spatial_apart :: proc "contextless" (m:^Mixer,v:^Mix_Voice,base,target:^[4]f32) -> (pans:[2][2]f32,apart:bool) {
    if !(m.output_now==.Headphones && m.channels==2) && !v.eq_on && eq_flat(v.eq_target) {return}
    one :: proc "contextless" (g:^[4]f32,stereo:bool) -> [2]f32 {
        level:=math.sqrt(g[0]*g[0]+g[1]*g[1])
        pan:=[2]f32{math.SQRT_TWO/2,math.SQRT_TWO/2}
        if level>0 {pan={g[0]/level,g[1]/level}}
        g^={level,0,level if stereo else 0,0}
        return pan
    }
    stereo:=v.source.channels==2
    return {one(base,stereo),one(target,stereo)},true
}

// Places frames [from,to) of a voice mixed apart as one source: its EQ while
// it is not flat, then on speakers the pan from pans[0] to pans[1]. On
// headphones it leaves the signal in the left channel and returns true: the
// HRTF is applied with the other voices of its bus.
@(private)
spatial_post :: proc "contextless" (m:^Mixer,v:^Mix_Voice,out:[^]f32,from,to:int,pans:[2][2]f32,silent:bool) -> (binaural:bool) #no_bounds_check {
    count:=to-from
    binaural=m.output_now==.Headphones && m.channels==2
    flat:=eq_flat(v.eq_target)
    if count<=0 || silent || binaural && !v.eq_on && flat {return}
    mono:=m.spatial_mono[:count]
    for i in 0..<count {mono[i]=out[(from+i)*2]}
    if v.eq_on || !flat {
        // EQEffect: a change crossfades over the chunk from old, the signal of
        // the filters before (the dry signal when the EQ comes in), to mono.
        old:=m.spatial_old[:count]
        current:=int(v.eq_current)
        moved:=false
        for i in 0..<BANDS {moved||=!(abs(v.eq_target[i]-v.eq_gains[i])<=EQ_GAIN_STEP*v.eq_gains[i])}
        switch {
        case !v.eq_on:
            if v.placed {copy(old,mono)} else {old=nil}
            v.eq_current,v.eq_gains,v.eq_state=0,v.eq_target,{}
            v.eq[0]=eq_filters(v.eq_gains,m.sample_rate)
            eq_run(&v.eq[0],&v.eq_state[0],mono)
            v.eq_on=true
        case flat:
            // It goes out: from the EQ to the dry signal.
            copy(old,mono)
            eq_run(&v.eq[current],&v.eq_state[current],old)
            v.eq_on=false
        case moved:
            v.eq_current=u8(1-current)
            v.eq[1-current],v.eq_state[1-current]=eq_filters(v.eq_target,m.sample_rate),v.eq_state[current]
            v.eq_gains=v.eq_target
            copy(old,mono)
            eq_run(&v.eq[current],&v.eq_state[current],old)
            eq_run(&v.eq[1-current],&v.eq_state[1-current],mono)
        case:
            eq_run(&v.eq[current],&v.eq_state[current],mono)
            old=nil
        }
        for i in 0..<len(old) {
            w:=f32(i)/f32(count)
            mono[i]=w*mono[i]+(1-w)*old[i]
        }
    }
    if binaural {
        for i in 0..<count {out[(from+i)*2]=mono[i]}
        return
    }
    dw:=(pans[1]-pans[0])/f32(count)
    for i in 0..<count {
        g:=pans[0]+dw*f32(i)
        out[(from+i)*2]=mono[i]*g[0]
        out[(from+i)*2+1]=mono[i]*g[1]
    }
    return
}

// Where the listener is, how it is turned and how fast it moves. False for a
// position or velocity that is not a number.
listener_set :: proc(m:^Mixer,position:[3]f32,rotation:quaternion128,velocity:[3]f32={}) -> bool {
    if !finite3(position) || !finite3(velocity) {return false}
    return command_push(m,{kind=.Listener,vectors={position,velocity},rotation=quat_unit(rotation)})
}

// What the output plays on: the HRTF for headphones or the pan for speakers.
mixer_set_output :: proc(m:^Mixer,kind:Output_Kind) -> bool {
    if kind!=.Headphones && kind!=.Speakers {return false}
    if kind==m.output {return true}
    if !command_push(m,{kind=.Output,index=u32(kind)}) {return false}
    m.output=kind
    return true
}
mixer_output :: proc(m:^Mixer) -> Output_Kind {return m.output}
