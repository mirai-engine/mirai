package audio

import "core:math"
import "mirai:asset"
import "mirai:host"
import mixer "mirai:audio"

// The voices a sound plays on: one for a .sound or a Random set, one per layer
// for a Layered set. Layers start in one batch of the mixer on one frame
// LAYER_LEAD ahead, so they play in step to the sample, and every change
// reaches all of them in the same chunk. The curves of the set shape each one
// by the values of its parameters (Audio_Source.parameters), which glide to
// what code sets as the set says (Kira's tweened parameters, without a graph).

LAYERS :: asset.SOUND_SET_CAPACITY
PARAMETERS :: asset.SOUND_SET_PARAMETERS
LAYER_LEAD :: 4*mixer.CHUNK_FRAMES // frames ahead of the mixer clock layers start on

Sound_Voices :: struct {
    voices:[LAYERS]Voice, // 0 for a layer that does not play: it ended, or the sound is virtual
    sounds:[LAYERS]mixer.Sound,
    layers:[LAYERS]u8, // the entry of the set each sound is
    gains:[LAYERS]f32, // per-entry gain of each layer
    pitches:[LAYERS]f32, // per-entry pitch of each layer
    delays:[LAYERS]f32, // per-entry start delay (s) of each layer
    count:int,
    volume,pitch:f32,  // drawn from the ranges of its set
}

// The voices of a pick, none started yet.
@(private)
voices_of :: proc "contextless" (pick:host.Sound_Pick) -> (v:Sound_Voices) {
    v.sounds,v.layers,v.count=pick.sounds,pick.layers,clamp(pick.count,0,LAYERS)
    v.gains,v.pitches,v.delays=pick.gains,pick.pitches,pick.delays
    v.volume,v.pitch=pick.volume,pick.pitch
    return
}

// Whether every sound of v is still held by the mixer.
@(private)
voices_sounds_valid :: proc(m:^Mixer,v:^Sound_Voices) -> bool {
    if m==nil || v==nil || v.count<=0 {return false}
    for sound in v.sounds[:v.count] {
        if !mixer.sound_valid(m,sound) {return false}
    }
    return true
}

// Whether any voice of a sound still plays.
sound_voices_valid :: proc(m:^Mixer,v:^Sound_Voices) -> bool {
    if m==nil || v==nil {return false}
    for voice in v.voices[:v.count] {
        if voice!={} && mixer.voice_valid(m,voice) {return true}
    }
    return false
}

// Stops every voice of a sound in one chunk.
sound_voices_stop :: proc(m:^Mixer,v:^Sound_Voices) {
    if m==nil || v==nil {return}
    mixer.mixer_batch_begin(m)
    for &voice in v.voices[:v.count] {
        if voice!={} {mixer.voice_stop(m,voice)}
        voice={}
    }
    mixer.mixer_batch_end(m)
}

// The voices of a sound take the values of their source and what the curves
// of its set give them at its parameters, all in one chunk: what the editor
// changes while it plays a sound to be heard.
sound_voices_tune :: proc(m:^Mixer,app:^host.App,v:^Sound_Voices,source:Audio_Source) {
    if m==nil || v==nil {return}
    shapes:=shapes_of(host.content_sound_set_info(app,source.sound),v,parameters_clean(source.parameters))
    voices_tune(m,v,source,&shapes,source.spatial,true)
}

// Sets a parameter of the .sound_set a source plays, by its name; the source
// glides to value over the glide of the parameter. False, and nothing changes,
// when its sound is not a set that loads, the set has no parameter of that
// name or value is not a number.
parameter_set :: proc(app:^host.App,source:^Audio_Source,name:string,value:f32) -> bool {
    if source==nil || !(abs(value)<=max(f32)) {return false}
    set:=host.content_sound_set_info(app,source.sound)
    if set==nil {return false}
    index,found:=asset.sound_set_parameter(set,name)
    if !found {return false}
    source.parameters[index]=value
    return true
}

// The values of the parameters as they are used: one that is not a number is 0.
@(private)
parameters_clean :: proc "contextless" (values:[PARAMETERS]f32) -> (clean:[PARAMETERS]f32) {
    for value,i in values {clean[i]=value if abs(value)<=max(f32) else 0}
    return
}

// What the curves of a set give each voice of a sound at values; nothing for a .sound.
@(private)
shapes_of :: proc(set:^asset.Sound_Set_Info,v:^Sound_Voices,values:[PARAMETERS]f32) -> (shapes:[LAYERS]asset.Sound_Shape) {
    for &shape in shapes {shape=asset.SOUND_SHAPE_NONE}
    if set==nil {return}
    for i in 0..<v.count {shapes[i]=asset.sound_set_shape(set,int(v.layers[i]),values)}
    return
}

// Starts the sounds of v together over desc, each with its shape and delay:
// in one batch. A layer whose sound ended without loop does not start. All or
// none: false, with none playing, when the mixer refused one or none started.
@(private)
voices_play :: proc(m:^Mixer,v:^Sound_Voices,desc:mixer.Voice_Desc,shapes:^[LAYERS]asset.Sound_Shape,time:f64,lengths:^[LAYERS]f32) -> bool {
    base:=desc
    pitch:=desc.pitch if desc.pitch>0 else 1
    mixer.mixer_batch_begin(m)
    defer mixer.mixer_batch_end(m)
    started:=0
    for i in 0..<v.count {
        v.voices[i]={}
        entry_gain:=v.gains[i] if v.gains[i]>0 else 1
        entry_pitch:=v.pitches[i] if v.pitches[i]>0 else 1
        delay:=v.delays[i]
        offset:=time
        if delay>0 {
            if offset>=f64(delay) {
                offset-=f64(delay)
                delay=0
            } else {
                delay-=f32(offset)
                offset=0
            }
        }
        if desc.loop && lengths[i]>0 {
            offset=math.mod(offset,f64(lengths[i]))
        } else if v.count>1 && offset>=f64(lengths[i]) {
            continue
        }
        layer:=base
        layer.volume*=entry_gain*shapes[i].gain
        layer.pitch=pitch*entry_pitch*shapes[i].pitch
        layer.lowpass=shapes[i].lowpass
        layer.delay=delay
        layer.offset=offset
        if v.voices[i]=mixer.voice_play(m,v.sounds[i],layer);v.voices[i]=={} {
            for &voice in v.voices[:i] {
                if voice!={} {mixer.voice_stop(m,voice)}
                voice={}
            }
            return false
        }
        started+=1
    }
    return started>0
}

// Gives the voices of a sound their gain, pitch and low-pass by their shapes
// and, with all, the loop, send and pan of the source, in one chunk.
@(private)
voices_tune :: proc(m:^Mixer,v:^Sound_Voices,source:Audio_Source,shapes:^[LAYERS]asset.Sound_Shape,spatial,all:bool) {
    mixer.mixer_batch_begin(m)
    defer mixer.mixer_batch_end(m)
    pitch:=(source.pitch if source.pitch>0 else 1)*v.pitch
    for voice,i in v.voices[:v.count] {
        if voice=={} {continue}
        entry_gain:=v.gains[i] if v.gains[i]>0 else 1
        entry_pitch:=v.pitches[i] if v.pitches[i]>0 else 1
        mixer.voice_set_volume(m,voice,source.volume*v.volume*entry_gain*shapes[i].gain)
        mixer.voice_set_pitch(m,voice,pitch*entry_pitch*shapes[i].pitch)
        mixer.voice_set_lowpass(m,voice,shapes[i].lowpass)
        if !all {continue}
        mixer.voice_set_loop(m,voice,source.loop)
        mixer.voice_set_reverb(m,voice,source.reverb)
        if !spatial {mixer.voice_set_pan(m,voice,source.pan)}
    }
}

// Aims the parameters of an entry at values: at once for a parameter that
// does not glide, else at the speed that gets there in its glide.
@(private)
parameters_aim :: proc(entry:^Voice_Entry,set:^asset.Sound_Set_Info,values:[PARAMETERS]f32) {
    for to,i in parameters_clean(values) {
        if to==entry.targets[i] {continue}
        entry.targets[i]=to
        glide:=set.parameters[i].glide if set!=nil else 0
        if glide>0 {
            entry.rates[i]=abs(to-entry.values[i])/glide
        } else {
            entry.values[i]=to
        }
    }
}

// Moves the parameters of an entry toward their targets over dt seconds;
// true when one moved.
@(private)
parameters_glide :: proc "contextless" (entry:^Voice_Entry,dt:f32) -> (moved:bool) {
    for &value,i in entry.values {
        to:=entry.targets[i]
        if value==to {continue}
        step:=entry.rates[i]*max(dt,0)
        if step<=0 {continue}
        if !(step<abs(to-value)) {
            value=to
        } else {
            value+=step if to>value else -step
        }
        moved=true
    }
    return
}
