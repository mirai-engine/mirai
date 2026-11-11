package mirai_audio

import "core:math"
import mm "mirai:std/math"

// Positional audio. Right-handed, Y up, meters: a listener with no rotation
// looks down -Z and has +X at its right.

Attenuation_Model :: enum u8 {
    None,        // the same level until it fades out before max_distance
    Inverse,     // min/(min+rolloff*(d-min)): halves at twice the minimum distance with rolloff 1
    Linear,      // 1-rolloff*(d-min)/(max-min): silent at the maximum distance with rolloff 1
    Exponential, // (d/min)^-rolloff
}
// Nearer than min_distance the gain is 1; over the last ATTENUATION_FADE of
// the way to max_distance the gain of the model fades to 0, and beyond it the
// voice is not heard.
Attenuation :: struct {
    model:Attenuation_Model,
    min_distance,max_distance:f32,
    rolloff:f32,
    // Nearer than this a voice is heard less and less from its direction and
    // at the listener from no side, so passing through it does not jump between
    // ears: the share of its direction rises as a smootherstep from 0 at the
    // listener to 1 here, flat at both ends. 0: always from its direction.
    near_radius:f32,
    // Of a stereo sound: how far apart its two channels are heard, in meters
    // across the source, so it is wide up close and narrows to a point far
    // away. 0: one source, the average of its channels.
    spread:f32,
    delay:bool, // starts later by its distance over the speed of sound, as thunder after its flash
}
// The HRTF is measured 1 m from the head: nearer, it no longer tells where a source is. A
// stereo recording keeps the width of a pair of speakers 2 m apart (Unreal's default spread).
ATTENUATION_DEFAULT :: Attenuation{model=.Inverse,min_distance=1,max_distance=100,rolloff=1,near_radius=1,spread=2}
ATTENUATION_FADE :: f32(0.25)

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
    if !(distance<high) {return 0}
    if high<=low {return 1}
    d:=max(distance,low)
    gain:=f32(1)
    switch a.model {
    case .None:
    case .Inverse:gain=low/(low+a.rolloff*(d-low))
    case .Linear:gain=clamp(1-a.rolloff*(d-low)/(high-low),0,1)
    case .Exponential:gain=math.pow(d/low,-a.rolloff)
    }
    return gain*min((high-d)/(ATTENUATION_FADE*(high-low)),1)
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
// Within its near radius the pan goes toward the middle by its blend. On
// speakers each channel of a stereo voice is placed at its own azimuth, half
// the angle its spread subtends to either side of it, as Unreal places the
// two of a stereo source (the idea only); headphones widen it in binaural_add.
@(private)
spatial_gains :: proc "contextless" (m:^Mixer,v:^Mix_Voice) -> [4]f32 {
    if v.spatial_dirty || v.listener_serial!=m.listener_serial {
        l:=m.listener
        direction,distance:=listener_direction(l.position,l.rotation,v.position)
        directivity:=directivity_gain(v.directivity,v.position,v.rotation,l.position)
        v.direct_gain,v.eq_target=direct_gain_eq(attenuation_gain(v.attenuation,distance),directivity,air_absorption(distance),v.occlusion,v.transmission)
        v.direction=direction
        v.blend=1
        if r:=v.attenuation.near_radius;distance<r {s:=distance/r;v.blend=s*s*s*(s*(6*s-15)+10)}
        v.spread=math.atan(0.5*max(v.attenuation.spread,0)/max(distance,1e-4))
        v.spatial_pitch=doppler_pitch(l.position,l.velocity,v.position,v.velocity,v.doppler,m.speed_of_sound)
        v.spatial_dirty=false;v.listener_serial=m.listener_serial
    }
    stereo:=v.source.channels==2
    pan:[2]f32
    if horizontal:=math.sqrt(v.direction.x*v.direction.x+v.direction.z*v.direction.z);m.output_now==.Speakers && m.channels==2 && horizontal>1e-6 {
        x,z:=v.direction.x/horizontal,v.direction.z/horizontal
        c,s:=f32(1),f32(0)
        if stereo {c,s=math.cos(v.spread),math.sin(v.spread)}
        pan={v.blend*(x*c+z*s),v.blend*(x*c-z*s)}
    }
    gain:=v.volume*v.direct_gain
    if !stereo {
        sides:=pan_gains(pan[0])*gain
        return {sides[0],sides[1],0,0}
    }
    left,right:=pan_gains(pan[0])*(gain*0.5),pan_gains(pan[1])*(gain*0.5)
    return {left[0],left[1],right[0],right[1]}
}

// A spatial voice that goes through its EQ or its HRTF is mixed apart, its
// gains (base and target) losing their pan: at the level of its gains it
// holds its mid, the average of its channels, in the left channel and, for a
// stereo voice, its side, half their difference, in the right. Its pans, the
// gains of the mid and of the side into each speaker over that level, are
// what spatial_post applies. Any other is mixed as a panned voice.
@(private)
spatial_apart :: proc "contextless" (m:^Mixer,v:^Mix_Voice,base,target:^[4]f32) -> (pans:[2][4]f32,apart:bool) {
    // Its EQ is left out while all its bands are within EQ_FLAT of unity.
    if !(m.output_now==.Headphones && m.channels==2) && !v.eq_on && min(v.eq_target[0],v.eq_target[1],v.eq_target[2])>=EQ_FLAT {return}
    split :: proc "contextless" (g:^[4]f32,stereo:bool) -> (pan:[4]f32) {
        mid,side:=[2]f32{g[0],g[1]},[2]f32{}
        if stereo {mid,side={g[0]+g[2],g[1]+g[3]},{g[0]-g[2],g[1]-g[3]}}
        level:=math.sqrt(mid.x*mid.x+mid.y*mid.y)
        pan={math.SQRT_TWO/2,math.SQRT_TWO/2,0,0}
        if level>0 {pan={mid.x,mid.y,side.x,side.y}/level}
        g^={level*0.5,level*0.5,level*0.5,-level*0.5} if stereo else {level,0,0,0}
        return
    }
    stereo:=v.source.channels==2
    return {split(base,stereo),split(target,stereo)},true
}

// Places frames [from,to) of a voice mixed apart: its EQ on each channel
// while it is not flat, then on speakers the pans from pans[0] to pans[1]. On
// headphones it leaves the mid and the side where they are and returns true:
// the HRTF is applied with the other voices of its bus.
@(private)
spatial_post :: proc "contextless" (m:^Mixer,v:^Mix_Voice,out:[^]f32,from,to:int,pans:[2][4]f32,silent:bool) -> (binaural:bool) #no_bounds_check {
    count:=to-from
    channels:=int(v.source.channels)
    binaural=m.output_now==.Headphones && m.channels==2
    flat:=min(v.eq_target[0],v.eq_target[1],v.eq_target[2])>=EQ_FLAT
    if count<=0 || silent || binaural && !v.eq_on && flat && channels==1 {return}
    if v.eq_on || !flat {
        // EQEffect: a change crossfades over the chunk from old, the signal of
        // the filters before (the dry signal when the EQ comes in), to the new.
        current:=int(v.eq_current)
        moved:=false
        for i in 0..<BANDS {moved||=!(abs(v.eq_target[i]-v.eq_gains[i])<=EQ_GAIN_STEP*v.eq_gains[i])}
        Change :: enum u8 {Steady,In,Out,Moved}
        change:=Change.Steady
        switch {
        case !v.eq_on:
            change=.In
            v.eq_current,v.eq_gains,v.eq_state=0,v.eq_target,{}
            v.eq[0]=eq_filters(v.eq_gains,m.sample_rate)
            v.eq_on=true
        case flat:
            change=.Out
            v.eq_on=false
        case moved:
            change=.Moved
            v.eq_current=u8(1-current)
            v.eq[1-current],v.eq_state[1-current]=eq_filters(v.eq_target,m.sample_rate),v.eq_state[current]
            v.eq_gains=v.eq_target
        }
        for c in 0..<channels {
            x:=m.spatial_mono[c*CHUNK_FRAMES:][:count]
            old:=m.spatial_old[c*CHUNK_FRAMES:][:count]
            for i in 0..<count {x[i]=out[(from+i)*2+c]}
            switch change {
            case .Steady:eq_run(&v.eq[current],&v.eq_state[current][c],x)
            case .In:
                copy(old,x)
                eq_run(&v.eq[0],&v.eq_state[0][c],x)
            case .Out:
                copy(old,x)
                eq_run(&v.eq[current],&v.eq_state[current][c],old)
            case .Moved:
                copy(old,x)
                eq_run(&v.eq[current],&v.eq_state[current][c],old)
                eq_run(&v.eq[1-current],&v.eq_state[1-current][c],x)
            }
            for i in 0..<count {out[(from+i)*2+c]=x[i] if change==.Steady else old[i]+(x[i]-old[i])*(f32(i)/f32(count))}
        }
    }
    if binaural {return}
    dw:=(pans[1]-pans[0])/f32(count)
    for i in 0..<count {
        g:=pans[0]+dw*f32(i)
        mid,side:=out[(from+i)*2],out[(from+i)*2+1]
        out[(from+i)*2]=mid*g[0]+side*g[2]
        out[(from+i)*2+1]=mid*g[1]+side*g[3]
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
// False for headphones without memory for the HRTF.
mixer_set_output :: proc(m:^Mixer,kind:Output_Kind) -> bool {
    if kind!=.Headphones && kind!=.Speakers {return false}
    if kind==m.output {return true}
    if kind==.Headphones && binaural_init(m)!=.None {return false}
    if !command_push(m,{kind=.Output,index=u32(kind)}) {return false}
    m.output=kind
    return true
}
mixer_output :: proc(m:^Mixer) -> Output_Kind {return m.output}
