#+private
package mirai_audio

import "core:sync"

// The audio thread side of a voice: everything here runs inside mixer_render.

Voice_Source :: struct {
    samples:[^]f32, // interleaved
    frames:u32,
    channels:u32,   // 1 or 2
    rate:u32,
    feed:i32,       // the feed it plays from; -1 for a sound decoded in memory
}
// What a play command carries, and afterwards the current parameters of the voice.
Voice_Start :: struct {
    generation:u32,
    sound:u32,
    source:Voice_Source,
    bus:u16,
    volume,pitch,pan:f32,
    loop,paused,spatial:bool,
    fade_in:u32,     // frames
    offset:u32,      // frames into the sound; for a feed, where its ring begins
    start_frame:u64, // mixer clock
    position,velocity:[3]f32,
    rotation:quaternion128,
    attenuation:Attenuation,
    directivity:Directivity,
    doppler:f32,
    occlusion:f32,
    transmission:[BANDS]f32,
    reverb:f32,
}
Voice_Phase :: enum u8 {Free,Playing,Paused}
Mix_Voice :: struct {
    phase:Voice_Phase,
    using start:Voice_Start,
    cursor:u64, // 32.32 frames into the source
    // Gains from each source channel to each output: {left to left, left to
    // right, right to left, right to right}; a mono source uses the first two.
    // They are ramped from base to their new value over every chunk.
    base:[4]f32,base_valid:bool,
    // An envelope that multiplies the gains, exact to the sample.
    fade,fade_step,fade_target:f32,fade_left:u32,
    end_after_fade:bool,
    pausing,stopping:bool, // ramp to silence over this chunk, then pause or end
    orphan:bool,           // its handle was given to a voice that never started: it ends without a word
    spatial_pitch:f32,
    spatial_dirty:bool,listener_serial:u32,
    // The direct sound of a spatial voice: its gain and EQ, where it comes
    // from in the listener's space, and what the last chunk ended with.
    direct_gain:f32,
    eq_target,eq_gains:[BANDS]f32,
    eq:[2][BANDS]Biquad,eq_state:[2][BANDS]Biquad_State,eq_current:u8,
    eq_on:bool,
    direction:[3]f32,
    blend:f32, // share of its direction, below 1 within its near radius
    binaural_live,binaural_direction_valid:bool,
    binaural_clock:u64, // the chunk its next block continues from
    binaural_direction:[3]f32, // that of its HRTF
    binaural_blend:f32,        // that of its HRTF
    // A binaural voice that went silent adds one more block, and then ends
    // or, with tail_pause, pauses.
    tail,tail_pause:bool,
    reverb_now:f32, // the send, ramped over every chunk from where it was
    next:Voice_Start,has_next:bool,
}

voice_begin :: proc "contextless" (m:^Mixer,v:^Mix_Voice,start:Voice_Start) {
    v^={start=start}
    v.phase=.Paused if start.paused else .Playing
    v.cursor=u64(start.offset)<<32 if start.source.feed<0 else 0
    v.fade=1;v.fade_target=1
    if start.fade_in>0 {
        v.fade=0;v.fade_left=start.fade_in;v.fade_step=1/f32(start.fade_in)
    }
    v.spatial_dirty=true
    v.spatial_pitch=1
    v.reverb_now=start.reverb
    if start.spatial && start.attenuation.delay {
        // DirectSimulator::calcDelay, applied once to where the voice starts.
        _,distance:=listener_direction(m.listener.position,m.listener.rotation,start.position)
        frames:=min(f64(distance)/f64(m.speed_of_sound)*f64(m.sample_rate)+0.5,f64(max(u32)))
        v.start_frame=max(v.start_frame,m.clock)+u64(frames)
    }
}

// The game thread learns of the end through finished, unless the slot was
// stolen: then it has already been given to another voice.
voice_end :: proc "contextless" (m:^Mixer,index:u32) {
    v:=&m.voices[index]
    generation:=v.generation
    feed_release(m,&v.start)
    v.phase=.Free
    if v.has_next {
        next:=v.next
        voice_begin(m,v,next)
        return
    }
    if !v.orphan {sync.atomic_store_explicit(&m.finished[index],generation,.Release)}
}
// Cancels the voice that waits for a stolen slot. The one it replaced has
// no handle any more, so it leaves too.
voice_next_cancel :: proc "contextless" (m:^Mixer,index:u32) {
    v:=&m.voices[index]
    generation:=v.next.generation
    v.has_next=false
    feed_release(m,&v.next)
    if v.phase==.Playing && m.clock>=v.start_frame {
        v.orphan=true;v.stopping=true
    } else {
        feed_release(m,&v.start)
        v.phase=.Free
    }
    sync.atomic_store_explicit(&m.finished[index],generation,.Release)
}

voice_command :: proc "contextless" (m:^Mixer,command:^Command) {
    v:=&m.voices[command.index]
    target:=&v.start
    if v.has_next && v.next.generation==command.generation {
        // Meant for the voice that waits for this slot.
        target=&v.next
        #partial switch command.kind {
        case .Voice_Stop:voice_next_cancel(m,command.index)
        case .Voice_Pause:target.paused=command.flag
        case .Voice_Volume:target.volume=command.value
        case .Voice_Pitch:target.pitch=command.value
        case .Voice_Pan:target.pan=command.value
        case .Voice_Loop:target.loop=command.flag
        case .Voice_Place:target.position=command.vectors[0];target.velocity=command.vectors[1];target.rotation=command.rotation
        case .Voice_Occlusion:target.occlusion=command.value;target.transmission=command.vectors[0]
        case .Voice_Reverb:target.reverb=command.value
        }
        return
    }
    if v.phase==.Free || v.generation!=command.generation {return}
    #partial switch command.kind {
    case .Voice_Stop:
        started:=m.clock>=v.start_frame
        if v.tail {v.tail_pause=false;return}
        if v.phase==.Paused || !started {voice_end(m,command.index);return}
        if command.frames==0 {v.stopping=true;return}
        v.fade_target=0;v.fade_left=command.frames;v.fade_step=-v.fade/f32(command.frames)
        v.end_after_fade=true
    case .Voice_Pause:
        if v.tail {
            // Resumed before its last block: it goes on from there.
            if !command.flag && v.tail_pause {v.tail,v.tail_pause=false,false}
            return
        }
        if command.flag {
            if v.phase==.Playing {
                if m.clock>=v.start_frame {v.pausing=true} else {v.phase=.Paused}
            }
        } else {
            v.pausing=false
            if v.phase==.Paused {
                v.phase=.Playing
                v.base={};v.base_valid=true // comes back from silence
            }
        }
    case .Voice_Volume:v.volume=command.value
    case .Voice_Pitch:v.pitch=command.value
    case .Voice_Pan:v.pan=command.value
    case .Voice_Loop:v.loop=command.flag
    case .Voice_Fade:
        if v.end_after_fade {return}
        v.fade_target=command.value
        if command.frames==0 {v.fade=command.value;v.fade_left=0;return}
        v.fade_left=command.frames;v.fade_step=(command.value-v.fade)/f32(command.frames)
    case .Voice_Place:
        v.position=command.vectors[0];v.velocity=command.vectors[1];v.rotation=command.rotation
        v.spatial_dirty=true
    case .Voice_Occlusion:
        v.occlusion=command.value;v.transmission=command.vectors[0]
        v.spatial_dirty=true
    case .Voice_Reverb:v.reverb=command.value
    }
}

// Gains of a voice before its fade: volume, and pan or place.
voice_gains :: proc "contextless" (m:^Mixer,v:^Mix_Voice) -> (gains:[4]f32) {
    sides:[2]f32
    if v.spatial {return spatial_gains(m,v)}
    if v.source.channels==2 {
        sides=balance_gains(v.pan)*v.volume
        return {sides[0],0,0,sides[1]}
    }
    sides=pan_gains(v.pan)*v.volume
    return {sides[0],sides[1],0,0}
}

// Mixes n frames of one voice into the buffer of its bus.
voice_mix :: proc "contextless" (m:^Mixer,index:u32,n:int,clock:u64) {
    v:=&m.voices[index]
    if v.has_next {
        // Stolen: the old sound leaves over this chunk and the new one starts in it.
        if v.phase==.Playing && clock+u64(n)>v.start_frame {
            v.stopping=true
            voice_mix_chunk(m,index,n,clock)
        }
        if v.has_next {
            // The old sound had not started, or was paused: it leaves without a sound.
            next:=v.next
            feed_release(m,&v.start)
            voice_begin(m,v,next)
        }
    }
    if v.phase==.Playing {voice_mix_chunk(m,index,n,clock)}
}

voice_mix_chunk :: proc "contextless" (m:^Mixer,index:u32,n:int,clock:u64) {
    v:=&m.voices[index]
    if clock+u64(n)<=v.start_frame {return}
    if v.tail {
        voice_tail(m,index,n,clock)
        return
    }
    offset:=0
    if clock<v.start_frame {offset=int(v.start_frame-clock)}
    target:=voice_gains(m,v)
    if v.pausing || v.stopping {target={}}
    if !v.base_valid {v.base=target;v.base_valid=true}
    mixed:=target
    pans:[2][2]f32
    placed:=false
    if v.spatial {pans,placed=spatial_apart(m,v,&v.base,&mixed)}
    silent:=placed && mixed=={} && v.base=={}
    pitch:=clamp((v.pitch if v.pitch>0 else 1)*(v.spatial_pitch if v.spatial else 1),PITCH_MIN,PITCH_MAX)
    step:=u64(f64(pitch)*f64(v.source.rate)/f64(m.sample_rate)*f64(ONE))
    bus:=raw_data(m.bus_buffers[int(v.bus)*CHUNK_FRAMES*2:])
    out:=bus
    // A voice that is placed or sent is mixed apart first.
    sent:=v.reverb>0 || v.reverb_now>0
    apart:=placed || sent
    if apart {
        out=raw_data(m.voice_scratch)
        #no_bounds_check for i in offset*2..<n*2 {out[i]=0}
    }
    span:=f32(n-offset)
    alive:=true
    if v.source.feed>=0 {
        alive=feed_voice_mix(m,v,out,offset,n,min(step,FEED_STEP_MAX),mixed,span)
    } else {
        alive,_=segments_mix(v,v.source.samples,u64(v.source.frames),v.loop,false,out,offset,n,max(step,1),mixed,span)
    }
    v.base=target
    if placed && spatial_post(m,v,out,offset,n,pans,silent) {
        // Binaural: sent as one source, then added to the sums of its bus; a
        // silent one adds nothing once its last block is complete.
        if sent {voice_post(m,v,out,nil,offset,n)}
        if !silent || v.binaural_live && v.binaural_clock==clock {
            x:=m.binaural_input[:n]
            #no_bounds_check for i in 0..<n {x[i]=out[i*2] if i>=offset else 0}
            binaural_add(m,v,index,x,v.direction,clock)
        }
    } else if apart {
        voice_post(m,v,out,bus,offset,n)
    }
    ended:=!alive || v.stopping
    if (ended || v.pausing) && v.binaural_live && m.output_now==.Headphones && m.channels==2 {
        // The samples its last block fell over still rise in one more block.
        v.tail=true
        v.tail_pause=!ended
        v.stopping,v.pausing=false,false
        return
    }
    if ended {voice_end(m,index);return}
    if v.pausing {v.pausing=false;v.phase=.Paused}
}

// Adds the silent block of a voice that went silent, which completes its last one.
voice_tail :: proc "contextless" (m:^Mixer,index:u32,n:int,clock:u64) {
    v:=&m.voices[index]
    silence:=m.binaural_input[:n]
    for &x in silence {x=0}
    binaural_add(m,v,index,silence,v.binaural_direction,clock)
    v.tail=false
    if !v.tail_pause {voice_end(m,index);return}
    v.tail_pause=false
    v.phase=.Paused
    v.binaural_live=false
}

// Sends frames [from,to) of a voice mixed apart to the reverb, and adds them
// to its bus when there is one.
voice_post :: proc "contextless" (m:^Mixer,v:^Mix_Voice,src,bus:[^]f32,from,to:int) {
    s0,ds:=v.reverb_now,(v.reverb-v.reverb_now)/f32(to-from)
    send:=raw_data(m.reverb_input)
    #no_bounds_check for k in from..<to {
        left,right:=src[k*2],src[k*2+1]
        if bus!=nil {
            bus[k*2]+=left
            bus[k*2+1]+=right
        }
        g:=s0+ds*f32(k-from)
        send[k*2]+=left*g
        send[k*2+1]+=right*g
    }
    v.reverb_now=v.reverb
}

// Mixes output frames [from,to) of a chunk from a source laid out in memory.
// Segments end where the fade ends and where the source ends or wraps.
// holds: the last frame of the source has no neighbour yet (a stream that
// is still being decoded), so it is not played. Returns false when the voice
// has ended.
segments_mix :: proc "contextless" (v:^Mix_Voice,samples:[^]f32,frames:u64,loop,holds:bool,out:[^]f32,from,to:int,step:u64,target:[4]f32,span:f32) -> (alive:bool,mixed:int) {
    at:=from
    stereo:=v.source.channels==2
    length:=frames<<32
    for at<to {
        if v.cursor>=length {
            if holds {return true,at-from}
            if !loop || frames==0 {return false,at-from}
            v.cursor%=length
        }
        segment:=to-at
        if v.fade_left>0 {segment=min(segment,int(v.fade_left))}
        index:=v.cursor>>32
        direct:=step==ONE && u32(v.cursor)==0
        count:=0
        if direct {
            count=int(min(u64(segment),frames-index))
        } else if limit:=(frames-1)<<32;v.cursor<limit {
            // Positions below limit have the frame after them in memory.
            count=int(min(u64(segment),(limit-1-v.cursor)/step+1))
        }
        slow:=count==0
        if slow {
            if holds {return true,at-from}
            count=1
        }
        fade_end:=v.fade+v.fade_step*f32(count) if v.fade_left>0 else v.fade
        if v.fade_left>0 && u32(count)==v.fade_left {fade_end=v.fade_target}
        g0:=(v.base+(target-v.base)*(f32(at-from)/span))*v.fade
        g1:=(v.base+(target-v.base)*(f32(at+count-from)/span))*fade_end
        dg:=(g1-g0)/f32(count)
        dst:=out[at*2:]
        switch {
        case slow:
            // The last frame of the source: its neighbour is the first frame of a loop, or silence.
            fraction:=f32(u32(v.cursor))*(1.0/4294967296.0)
            a,b:[2]f32
            if stereo {
                a={samples[index*2],samples[index*2+1]}
                if loop {b={samples[0],samples[1]}}
                left,right:=a[0]+(b[0]-a[0])*fraction,a[1]+(b[1]-a[1])*fraction
                dst[0]+=left*g0[0]+right*g0[2]
                dst[1]+=left*g0[1]+right*g0[3]
            } else {
                a[0]=samples[index]
                if loop {b[0]=samples[0]}
                sample:=a[0]+(b[0]-a[0])*fraction
                dst[0]+=sample*g0[0]
                dst[1]+=sample*g0[1]
            }
        case direct && stereo:mix_direct_stereo(dst,samples[index*2:],count,g0,dg)
        case direct:mix_direct_mono(dst,samples[index:],count,g0,dg)
        case stereo:mix_linear_stereo(dst,samples,count,v.cursor,step,g0,dg)
        case:mix_linear_mono(dst,samples,count,v.cursor,step,g0,dg)
        }
        v.cursor+=step*u64(count)
        at+=count
        if v.fade_left>0 {
            v.fade_left-=u32(count)
            v.fade=fade_end
            if v.fade_left==0 && v.end_after_fade {return false,at-from}
        }
    }
    // A sound that ends exactly with the chunk ends now, not a chunk later.
    if v.cursor>=length && !holds {
        if !loop || frames==0 {return false,at-from}
        v.cursor%=length
    }
    return true,at-from
}

mix_direct_mono :: proc "contextless" (out:[^]f32,src:[^]f32,count:int,g0,dg:[4]f32) {
    #no_bounds_check for k in 0..<count {
        ramp:=f32(k)
        sample:=src[k]
        out[k*2]+=sample*(g0[0]+dg[0]*ramp)
        out[k*2+1]+=sample*(g0[1]+dg[1]*ramp)
    }
}
mix_direct_stereo :: proc "contextless" (out:[^]f32,src:[^]f32,count:int,g0,dg:[4]f32) {
    #no_bounds_check for k in 0..<count {
        ramp:=f32(k)
        left,right:=src[k*2],src[k*2+1]
        out[k*2]+=left*(g0[0]+dg[0]*ramp)+right*(g0[2]+dg[2]*ramp)
        out[k*2+1]+=left*(g0[1]+dg[1]*ramp)+right*(g0[3]+dg[3]*ramp)
    }
}
// Linear interpolation between the two source frames around the cursor.
mix_linear_mono :: proc "contextless" (out:[^]f32,src:[^]f32,count:int,cursor,step:u64,g0,dg:[4]f32) {
    position:=cursor
    #no_bounds_check for k in 0..<count {
        ramp:=f32(k)
        index:=position>>32
        fraction:=f32(u32(position))*(1.0/4294967296.0)
        a:=src[index]
        sample:=a+(src[index+1]-a)*fraction
        out[k*2]+=sample*(g0[0]+dg[0]*ramp)
        out[k*2+1]+=sample*(g0[1]+dg[1]*ramp)
        position+=step
    }
}
mix_linear_stereo :: proc "contextless" (out:[^]f32,src:[^]f32,count:int,cursor,step:u64,g0,dg:[4]f32) {
    position:=cursor
    #no_bounds_check for k in 0..<count {
        ramp:=f32(k)
        index:=(position>>32)*2
        fraction:=f32(u32(position))*(1.0/4294967296.0)
        left:=src[index]+(src[index+2]-src[index])*fraction
        right:=src[index+1]+(src[index+3]-src[index+1])*fraction
        out[k*2]+=left*(g0[0]+dg[0]*ramp)+right*(g0[2]+dg[2]*ramp)
        out[k*2+1]+=left*(g0[1]+dg[1]*ramp)+right*(g0[3]+dg[3]*ramp)
        position+=step
    }
}
