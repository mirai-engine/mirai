package mirai_audio

import "core:sync"
import "mirai:std/base"

// Voices: one playing instance of a sound. The handle is valid from
// voice_play until a mixer_update finds that the voice has ended, or until
// the voice is stolen to make room for another.

Voice :: distinct base.Handle

// Start from VOICE_DEFAULT: a zeroed desc is silent (volume 0).
Voice_Desc :: struct {
    bus:Bus,
    volume:f32, // linear gain
    pitch:f32,  // rate of playback; 1 is the sound as recorded, 0 is taken as 1. Clamped to [PITCH_MIN,PITCH_MAX]
    pan:f32,    // -1 left to 1 right: constant power for a mono sound, balance for a stereo one. Ignored when spatial
    loop:bool,
    paused:bool,  // created paused; voice_set_paused starts it
    priority:u8,  // when no voice is free, the one of lowest priority is stolen, the oldest among equals; never one of higher priority
    fade_in:f32,  // seconds
    offset:f32,   // seconds into the sound where it starts; a loop starts over from the beginning
    // Mixer clock (mixer_clock) of the frame in which the first sample
    // plays. 0, or a frame already rendered, starts as soon as possible.
    start_frame:u64,
    // Placed in the world and heard from the listener: attenuated, dulled by
    // the air over distance, and through the HRTF on headphones or panned on
    // speakers.
    spatial:bool,
    position,velocity:[3]f32,
    rotation:quaternion128, // where its directivity faces; 0 is no rotation
    attenuation:Attenuation,
    directivity:Directivity,
    doppler:f32, // 0: none; 1: the physical effect
    // How hidden it is from the listener, 0 in sight to 1 hidden, and the part
    // of each band (low, mid, high) what hides it lets through.
    occlusion:f32,
    transmission:[BANDS]f32,
    reverb:f32, // share of the voice sent to the reverb of the mixer, after its gains
}
VOICE_DEFAULT :: Voice_Desc{volume=1,pitch=1,rotation=1,attenuation=ATTENUATION_DEFAULT,directivity={power=1},transmission=TRANSMISSION_DEFAULT}

// Frames of the ramp to silence of a voice that is stopped without a fade
// are those left in the chunk being mixed: at most CHUNK_FRAMES.

@(private)
Voice_Shadow :: struct {
    generation:u32,
    active:bool,
    priority:u8,
    sequence:u64, // order of creation
    feed:i32,     // the feed it plays from; -1 for a sound decoded in memory
    stream:bool,  // it plays a stream
}

@(private)
voice_shadow :: proc(m:^Mixer,voice:Voice) -> (index:u32,shadow:^Voice_Shadow) {
    index=base.handle_index(base.Handle(voice))
    if voice==0 || int(index)>=len(m.shadows) {return 0,nil}
    shadow=&m.shadows[index]
    if !shadow.active || shadow.generation!=base.handle_generation(base.Handle(voice)) {return 0,nil}
    return index,shadow
}
@(private)
voice_shadow_free :: proc(m:^Mixer,index:u32) {
    shadow:=&m.shadows[index]
    shadow.active=false
    shadow.generation+=1
    m.free_voices[m.free_count]=index;m.free_count+=1
}

// Plays a sound. Returns 0 when it cannot: the sound is not valid, a place in
// the world with a value that is not a number, a stream that is already
// playing, no voice or feed to use or steal, or a full command queue.
voice_play :: proc(m:^Mixer,sound:Sound,desc:Voice_Desc=VOICE_DEFAULT) -> Voice {
    slot:=sound_slot(m,sound)
    if slot==nil || !bus_valid(m,desc.bus) || desc.spatial && !voice_desc_finite(desc) {return 0}
    feed:=slot.feed
    if feed>=0 && feed_phase(&m.feeds[feed])!=.Free {m.counters.streams_busy+=1;return 0}
    if feed<0 && slot.source.kind!=.None {
        if m.free_feed_count==0 {m.counters.feeds_busy+=1;return 0}
        feed=i32(m.free_feeds[m.free_feed_count-1])
    }
    index:u32
    stolen:=false
    if m.free_count>0 {
        m.free_count-=1
        index=m.free_voices[m.free_count]
    } else {
        victim:=-1
        for shadow,i in m.shadows {
            // A voice that plays a stream is not stolen: its stream would have to be handed over too.
            if !shadow.active || shadow.stream {continue}
            if victim<0 || shadow.priority<m.shadows[victim].priority || (shadow.priority==m.shadows[victim].priority && shadow.sequence<m.shadows[victim].sequence) {victim=i}
        }
        if victim<0 || m.shadows[victim].priority>desc.priority {m.counters.voices_rejected+=1;return 0}
        index=u32(victim)
        stolen=true
    }
    shadow:=&m.shadows[index]
    generation:=shadow.generation+1 if stolen else shadow.generation
    handle:=Voice(base.handle_make(index,generation))
    rate:=f64(slot.rate)
    sound_index:=base.handle_index(base.Handle(sound))
    start:=Voice_Start{
        generation=generation,
        sound=sound_index,
        source={samples=raw_data(slot.samples),frames=slot.frames,channels=slot.channels,rate=slot.rate,feed=feed},
        bus=u16(desc.bus),
        volume=max(desc.volume,0),pitch=desc.pitch,pan=desc.pan,
        loop=desc.loop,paused=desc.paused,spatial=desc.spatial,
        fade_in=u32(max(f64(desc.fade_in),0)*f64(m.sample_rate)+0.5),
        start_frame=desc.start_frame,
        position=desc.position,velocity=desc.velocity,rotation=quat_unit(desc.rotation),
        attenuation=desc.attenuation,directivity={clamp(desc.directivity.weight,0,1),max(desc.directivity.power,0)},doppler=max(desc.doppler,0),
        occlusion=clamp(desc.occlusion,0,1),transmission=transmission_clamp(desc.transmission),
        reverb=max(desc.reverb,0),
    }
    frames:=slot.frames
    offset:=frames>0?u32(min(max(f64(desc.offset),0)*rate,f64(frames-1))):0
    start.offset=offset
    if feed>=0 {feed_prepare(m,&m.feeds[feed],slot.source,sound_index,int(offset),desc.loop)}
    if !command_push(m,{kind=.Voice_Play,index=index,start=start}) {
        if !stolen {m.free_voices[m.free_count]=index;m.free_count+=1}
        return 0
    }
    shadow.generation=generation
    shadow.active=true
    shadow.priority=desc.priority
    shadow.sequence=m.sequence;m.sequence+=1
    shadow.feed=feed
    shadow.stream=slot.feed>=0
    m.counters.voices_played+=1
    if stolen {m.counters.voices_stolen+=1}
    if feed>=0 {
        f:=&m.feeds[feed]
        if !f.stream {m.free_feed_count-=1}
        f.owner=handle
        feed_hand_over(m,f)
    }
    return handle
}

// Voices voice_play can start without stealing one.
voices_free :: proc(m:^Mixer) -> int {return m.free_count}

// The voice has not ended, as far as the last mixer_update knows.
voice_valid :: proc(m:^Mixer,voice:Voice) -> bool {
    _,shadow:=voice_shadow(m,voice)
    return shadow!=nil
}

@(private)
voice_send :: proc(m:^Mixer,voice:Voice,command:Command) -> bool {
    index,shadow:=voice_shadow(m,voice)
    if shadow==nil {return false}
    command:=command
    command.index=index;command.generation=shadow.generation
    return command_push(m,command)
}

// Ends the voice, at once (ramped to silence over the chunk being mixed) or
// after fading out for fade seconds. The handle stays valid until the voice
// has gone quiet.
voice_stop :: proc(m:^Mixer,voice:Voice,fade:f32=0) -> bool {
    return voice_send(m,voice,{kind=.Voice_Stop,frames=u32(max(f64(fade),0)*f64(m.sample_rate)+0.5)})
}
voice_set_paused :: proc(m:^Mixer,voice:Voice,paused:bool) -> bool {
    return voice_send(m,voice,{kind=.Voice_Pause,flag=paused})
}
voice_set_volume :: proc(m:^Mixer,voice:Voice,volume:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Volume,value=max(volume,0)})
}
voice_set_pitch :: proc(m:^Mixer,voice:Voice,pitch:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Pitch,value=pitch})
}
voice_set_pan :: proc(m:^Mixer,voice:Voice,pan:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Pan,value=pan})
}
voice_set_loop :: proc(m:^Mixer,voice:Voice,loop:bool) -> bool {
    _,shadow:=voice_shadow(m,voice)
    if shadow==nil {return false}
    // A feed that went back to the pool, and maybe to another voice, is not this voice's any more.
    if shadow.feed>=0 && m.feeds[shadow.feed].owner==voice {sync.atomic_store_explicit(&m.feeds[shadow.feed].loop,u32(loop),.Relaxed)}
    return voice_send(m,voice,{kind=.Voice_Loop,flag=loop})
}
// Moves the envelope of the voice to level (1 is its volume, 0 silence) over
// seconds, linearly from where it is. A voice that is fading out to stop
// keeps doing so.
voice_fade :: proc(m:^Mixer,voice:Voice,level:f32,seconds:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Fade,value=max(level,0),frames=u32(max(f64(seconds),0)*f64(m.sample_rate)+0.5)})
}
voice_set_reverb :: proc(m:^Mixer,voice:Voice,send:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Reverb,value=max(send,0)})
}
// Where a spatial voice is, how fast it moves and where its directivity
// faces. False for a value that is not a number.
voice_set_position :: proc(m:^Mixer,voice:Voice,position:[3]f32,velocity:[3]f32={},rotation:quaternion128=1) -> bool {
    if !finite3(position) || !finite3(velocity) {return false}
    return voice_send(m,voice,{kind=.Voice_Place,vectors={position,velocity},rotation=quat_unit(rotation)})
}
// How hidden a spatial voice is, 0 in sight to 1 hidden, and the part of each
// band what hides it lets through. False for a value that is not a number.
voice_set_occlusion :: proc(m:^Mixer,voice:Voice,occlusion:f32,transmission:[BANDS]f32) -> bool {
    if !finite(occlusion) || !finite3(transmission) {return false}
    return voice_send(m,voice,{kind=.Voice_Occlusion,value=clamp(occlusion,0,1),vectors={transmission_clamp(transmission),{}}})
}

@(private)
transmission_clamp :: proc "contextless" (t:[BANDS]f32) -> [BANDS]f32 {
    return {clamp(t[0],0,1),clamp(t[1],0,1),clamp(t[2],0,1)}
}
@(private)
voice_desc_finite :: proc "contextless" (d:Voice_Desc) -> bool {
    a:=d.attenuation
    numbers:=[?]f32{d.doppler,d.occlusion,a.min_distance,a.max_distance,a.rolloff,d.directivity.weight,d.directivity.power,
        real(d.rotation),imag(d.rotation),jmag(d.rotation),kmag(d.rotation)}
    for x in numbers {
        if !finite(x) {return false}
    }
    return finite3(d.position) && finite3(d.velocity) && finite3(d.transmission)
}
