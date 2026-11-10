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

// What the output plays on. Headphones hear each spatial voice through the
// HRTF of its direction, which tells ahead from behind and above from below;
// speakers pan it between them. A mono output plays every voice centered.
Output_Kind :: enum u8 {Headphones,Speakers}

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

// The pan of a direction on two speakers (PanningEffect::stereoPanningWeight):
// its side once brought to the horizontal plane, so ahead and behind both sit
// in the middle.
speaker_pan :: proc "contextless" (direction:[3]f32) -> f32 {
    length:=math.sqrt(direction.x*direction.x+direction.z*direction.z)
    if !(length>1e-6) {return 0}
    return clamp(direction.x/length,-1,1)
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
    pitch:=clamp((speed_of_sound-factor*listener_speed)/(speed_of_sound-factor*source_speed),0.25,4)
    return pitch if finite(pitch) else 1
}

// The gain, EQ, direction and pitch of a spatial voice for the listener.
@(private)
direct_update :: proc "contextless" (m:^Mixer,v:^Mix_Voice) {
    l:=m.listener
    direction,distance:=listener_direction(l.position,l.rotation,v.position)
    attenuation:=attenuation_gain(v.attenuation,distance)
    directivity:=directivity_gain(v.directivity,v.position,v.rotation,l.position)
    v.direct_gain,v.eq_target=direct_gain_eq(attenuation,directivity,air_absorption(distance),v.occlusion,v.transmission)
    v.direction=direction
    v.spatial_pitch=doppler_pitch(l.position,l.velocity,v.position,v.velocity,v.doppler,m.speed_of_sound)
}

// Turns the mono signal a spatial voice left in the left channel of frames
// [from,to) of out into its place: the direct effect (EQ and gain), then the
// HRTF on headphones or the pan on speakers.
@(private)
spatial_post :: proc "contextless" (m:^Mixer,v:^Mix_Voice,index:u32,out:[^]f32,from,to:int) #no_bounds_check {
    count:=to-from
    if count<=0 {return}
    mono:=m.spatial_mono[:count]
    for i in 0..<count {mono[i]=out[(from+i)*2]}
    if !v.direct_ready {
        v.eq_gains=v.eq_target
        v.eq_current=0
        v.eq[0]=eq_filters(v.eq_gains,m.sample_rate)
        v.eq_state={}
        v.direct_gain_now=v.direct_gain
        v.direct_ready=true
    }
    current:=int(v.eq_current)
    if v.eq_target!=v.eq_gains {
        // EQEffect: the cascade of the old gains and that of the new ones, which
        // starts from its state, crossfade over the chunk.
        previous:=current
        current=1-current
        v.eq[current]=eq_filters(v.eq_target,m.sample_rate)
        v.eq_state[current]=v.eq_state[previous]
        old:=m.spatial_old[:count]
        copy(old,mono)
        eq_run(&v.eq[previous],&v.eq_state[previous],old)
        eq_run(&v.eq[current],&v.eq_state[current],mono)
        for i in 0..<count {
            w:=f32(i)/f32(count)
            mono[i]=w*mono[i]+(1-w)*old[i]
        }
        v.eq_current=u8(current)
        v.eq_gains=v.eq_target
    } else {
        eq_run(&v.eq[current],&v.eq_state[current],mono)
    }
    g0,dg:=v.direct_gain_now,(v.direct_gain-v.direct_gain_now)/f32(count)
    for i in 0..<count {mono[i]*=g0+dg*f32(i)}
    v.direct_gain_now=v.direct_gain
    if m.output_now==.Headphones && m.channels==2 {
        binaural_run(m,v,index,mono,out[from*2:],v.direction)
        return
    }
    weights:=pan_gains(speaker_pan(v.direction) if m.channels==2 else 0)
    if !v.pan_valid {v.pan_now,v.pan_valid=weights,true}
    dw:=(weights-v.pan_now)/f32(count)
    for i in 0..<count {
        g:=v.pan_now+dw*f32(i)
        out[(from+i)*2]=mono[i]*g[0]
        out[(from+i)*2+1]=mono[i]*g[1]
    }
    v.pan_now=weights
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
