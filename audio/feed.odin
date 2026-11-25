package mirai_audio

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

// Feeds: rings of decoded 16 bit frames that a voice of a loaded sound plays
// from while a decoder fills them ahead. Each voice takes one from the pool,
// with its own decoder. Before the audio thread hears of a voice its ring
// holds what its first chunk plays (FEED_START_FRAMES at least), so it sounds
// at the sample it was scheduled for whatever the decoder thread is doing: a
// start from the beginning copies the first frames every loaded sound keeps
// decoded (Sound_Slot.primed), and the decoder opens and goes on from there;
// any other start (an offset, a pitch whose first chunk plays more) decodes
// them on the thread that calls voice_play. The decoder thread of the mixer
// fills the rest ahead, or, without one, mixer_update. A voice whose ring
// runs dry later goes silent (underruns) and resumes with the frame it
// stopped at.
//
// The phase of a feed says who touches it: the game thread prepares a Free
// feed and fills its first frames; it hands it over as Starting when the
// decoder still has to open, or as Running; the decoder fills it and leaves
// it Done once the audio thread has let it go; the game thread takes a Done
// feed back as Free.

// Source frames a voice that plays from a feed may consume per output frame:
// its pitch times the ratio of the sample rates is clamped to this.
@(private) FEED_STEP_MAX :: ONE*8
// How often the decoder thread looks at the feeds while some voice plays from one.
@(private) FEEDER_PERIOD :: 2*time.Millisecond
// Frames a start decodes at least, more if its first chunk plays more at its
// pitch: more than a device asks for at a time. A lossless block is decoded whole.
@(private) FEED_START_FRAMES :: 1024
// Frames of a WAV or Vorbis file decoded at a time, as f32 before they are rounded to 16 bits.
@(private) FEED_FLOAT_FRAMES :: 1024

@(private)
Feed_Phase :: enum u32 {Free,Starting,Running,Done}

@(private)
Feed :: struct {
    // Written by the game thread while the feed is Free; then the decoder's.
    decoder:Decoder,
    offset:int,   // the frame the play begins at; its ring begins a frame before, which interpolates it
    loop_start:int, // the frame a loop goes back to
    sound:u32,    // slot of the sound it decodes
    owner:Voice,  // the voice it was handed to last; game thread
    workspace:[]u8, // of a Vorbis decoder, grown when the game thread loads a sound that asks for more
    ring:[]i16,   // interleaved; a mono sound uses the first half
    capacity:u64, // frames of the ring, a power of two
    // Atomic.
    phase:Feed_Phase,
    loop:u32,     // written by the game thread, read when the decoder reaches the end
    write:u64,    // frames decoded since the play began; written by the decoder
    read:u64,     // frames played; written by the audio thread
    ended:u32,    // the decoder reached the end: what the ring holds is all there is
    released:u32, // the audio thread let go of it
}

@(private)
feed_phase :: #force_inline proc "contextless" (f:^Feed) -> Feed_Phase {
    return Feed_Phase(sync.atomic_load_explicit((^u32)(&f.phase),.Acquire))
}
@(private)
feed_phase_set :: #force_inline proc "contextless" (f:^Feed,phase:Feed_Phase) {
    sync.atomic_store_explicit((^u32)(&f.phase),u32(phase),.Release)
}

// Readies a Free feed for a play that begins at offset.
@(private)
feed_prepare :: proc(f:^Feed,sound:u32,offset,loop_start:int,loop:bool) {
    f.offset,f.loop_start=offset,loop_start
    f.sound=sound
    sync.atomic_store_explicit(&f.loop,u32(loop),.Relaxed)
    sync.atomic_store_explicit(&f.write,0,.Relaxed)
    sync.atomic_store_explicit(&f.read,0,.Relaxed)
    sync.atomic_store_explicit(&f.ended,0,.Relaxed)
    sync.atomic_store_explicit(&f.released,0,.Release)
}
// Gives a prepared feed ahead frames and hands it to the decoder, waking its
// thread: the primed frames of the sound for a start from its beginning that
// they cover, which the decoder goes on from once it opens; else, decoded
// now with the scratch of the game thread (no decoder touches a Free feed).
// A decoder that does not open plays nothing more.
@(private)
feed_hand_over :: proc(m:^Mixer,f:^Feed,primed:[]i16,ahead:int) {
    if f.offset==0 && (len(primed)>=ahead*f.decoder.channels || len(primed)==f.decoder.frames*f.decoder.channels) {
        copy(f.ring,primed)
        sync.atomic_store_explicit(&f.write,u64(len(primed)/f.decoder.channels),.Relaxed)
        feed_phase_set(f,.Starting)
    } else {
        if decoder_start(&f.decoder) {
            decoder_seek(&f.decoder,f.offset-min(f.offset,1))
            feed_fill(f,u64(ahead),m.start_planes,m.start_floats)
        } else {
            sync.atomic_store_explicit(&f.ended,1,.Relaxed)
        }
        feed_phase_set(f,.Running)
    }
    if m.feeder==nil {return}
    sync.atomic_add_explicit((^u32)(&m.feeder_wake),1,.Release)
    sync.futex_signal(&m.feeder_wake)
}
// What the first chunk of a voice plays at step, and the frames around them,
// FEED_START_FRAMES at least.
@(private)
feed_start_frames :: proc "contextless" (step:u64) -> int {
    return max(FEED_START_FRAMES,int((u64(CHUNK_FRAMES)*min(step,FEED_STEP_MAX))>>32)+4)
}
// The audio thread lets go of the feed of a voice that ends or is dropped.
@(private)
feed_release :: #force_inline proc "contextless" (m:^Mixer,start:^Voice_Start) {
    if start.source.feed<0 {return}
    sync.atomic_store_explicit(&m.feeds[start.source.feed].released,1,.Release)
    start.source.feed=-1
}

// Decodes ahead now, on the calling thread, for every voice that decodes as
// it plays. mixer_update does it when the mixer has no decoder thread; a game
// thread that renders the mixer itself faster than real time (a recording)
// calls it before every render.
mixer_decode :: proc(m:^Mixer) {
    pump_lock(m)
    feeds_pump(m)
    pump_unlock(m)
}

// One decoder at a time: the decoder thread or a caller of mixer_decode.
@(private)
pump_lock :: proc(m:^Mixer) {
    for {
        if _,ok:=sync.atomic_compare_exchange_weak_explicit(&m.pumping,0,1,.Acquire,.Relaxed);ok {return}
        thread.yield()
    }
}
@(private)
pump_unlock :: proc(m:^Mixer) {
    sync.atomic_store_explicit(&m.pumping,0,.Release)
}

// Fills every feed it can; true while some feed is in play.
@(private)
feeds_pump :: proc(m:^Mixer) -> (busy:bool) {
    for &f in m.feeds {
        phase:=feed_phase(&f)
        if phase==.Starting {
            // The ring holds the primed frames: the decoder goes on after them.
            if decoder_start(&f.decoder) {
                decoder_seek(&f.decoder,f.offset-min(f.offset,1)+int(sync.atomic_load_explicit(&f.write,.Relaxed)))
            } else {
                sync.atomic_store_explicit(&f.ended,1,.Release)
            }
            feed_phase_set(&f,.Running)
        } else if phase!=.Running {
            continue
        }
        if sync.atomic_load_explicit(&f.released,.Acquire)!=0 {
            feed_phase_set(&f,.Done)
            continue
        }
        feed_fill(&f,f.capacity,m.feed_planes,m.feed_floats)
        busy=true
    }
    return
}

@(private)
feeder_main :: proc(t:^thread.Thread) {
    m:=(^Mixer)(t.data)
    // The thread is the mixer's: nothing to restore.
    _=denormals_flush()
    for !sync.atomic_load_explicit(&m.feeder_quit,.Acquire) {
        wake:=sync.atomic_load_explicit((^u32)(&m.feeder_wake),.Acquire)
        pump_lock(m)
        busy:=feeds_pump(m)
        pump_unlock(m)
        if busy {
            sync.futex_wait_with_timeout(&m.feeder_wake,wake,FEEDER_PERIOD)
        } else {
            sync.futex_wait(&m.feeder_wake,wake)
        }
    }
}
@(private)
feeder_stop :: proc(m:^Mixer) {
    if m.feeder==nil {return}
    sync.atomic_store_explicit(&m.feeder_quit,true,.Release)
    sync.atomic_add_explicit((^u32)(&m.feeder_wake),1,.Release)
    sync.futex_signal(&m.feeder_wake)
    thread.destroy(m.feeder)
    m.feeder=nil
}

// Decodes into the free part of the ring until it holds ahead frames not
// played. A lossless block is decoded whole, into planes, once the rest of it
// fits; the ring holds two blocks at least. A WAV or a Vorbis file is decoded
// to f32 in floats and rounded. Each thread that decodes has its own planes
// and floats.
@(private)
feed_fill :: proc(f:^Feed,ahead:u64,planes:[]i32,floats:[]f32) {
    if sync.atomic_load_explicit(&f.ended,.Relaxed)!=0 {return}
    d:=&f.decoder
    channels:=d.channels
    mask:=f.capacity-1
    write:=f.write
    read:=sync.atomic_load_explicit(&f.read,.Acquire)
    free:=f.capacity-(write-read)
    rewound:=false
    fill: for free>0 && write-read<ahead {
        at:=write&mask
        run:=min(free,f.capacity-at)
        got:=0
        if d.kind==.Lossless {
            l:=&d.lossless
            if d.cursor<l.frames {
                block:=d.cursor/l.block_frames
                first:=d.cursor-block*l.block_frames
                rest:=min(l.block_frames,l.frames-block*l.block_frames)-first
                if u64(rest)>free {break fill}
                // A damaged block plays as silence.
                lossless_block(l,block,planes)
                split:=min(rest,int(run))
                lossless_convert_i16(planes,l.block_frames,channels,first,split,f.ring[int(at)*channels:])
                lossless_convert_i16(planes,l.block_frames,channels,first+split,rest-split,f.ring)
                got=rest
                d.cursor+=rest
            }
        } else {
            decoded:=floats[:int(min(run,FEED_FLOAT_FRAMES))*channels]
            got=decoder_read(d,decoded)
            ring:=f.ring[int(at)*channels:]
            for x,i in decoded[:got*channels] {ring[i]=sample_pcm16(x)}
        }
        write+=u64(got);free-=u64(got)
        sync.atomic_store_explicit(&f.write,write,.Release)
        if got>0 {rewound=false;continue}
        // The end of the sound: back to its loop start for a loop, unless nothing is left after it.
        if sync.atomic_load_explicit(&f.loop,.Relaxed)==0 || rewound {
            sync.atomic_store_explicit(&f.ended,1,.Release)
            return
        }
        decoder_seek(d,f.loop_start)
        rewound=true
    }
}

// The audio thread side: lays the frames the chunk needs out in a row, mixes
// them like a sound in memory and gives back to the ring what was played.
@(private)
feed_voice_mix :: proc "contextless" (m:^Mixer,v:^Mix_Voice,out:[^]f32,from,to:int,step:u64,target:[4]f32,span:f32) -> (alive:bool) {
    f:=&m.feeds[v.source.feed]
    // In this order: once ended is set, write no longer moves.
    ended:=sync.atomic_load_explicit(&f.ended,.Acquire)!=0
    write:=sync.atomic_load_explicit(&f.write,.Acquire)
    read:=f.read
    frames:=u64(v.source.frames)
    if !v.loop && frames>0 {
        // The decoder may have gone round already: the sound ends at its next end all the same.
        first:=frames-u64(v.offset)+u64(min(v.offset,1))
        body:=frames-u64(v.source.loop_start)
        end:=first
        if read>first {end=first+(read-first+body-1)/body*body}
        if write>=end {write=end;ended=true}
    }
    mask:=f.capacity-1
    channels:=u64(v.source.channels)
    available:=write-read
    needed:=(v.cursor+step*u64(to-from))>>32+3
    count:=min(available,needed)
    // The frame played last, then in two runs of samples: up to the end of the ring, and from its start.
    for c in 0..<channels {m.scratch[c]=v.kept[c]}
    at:=read&mask
    first:=min(count,f.capacity-at)*channels
    rest:=count*channels-first
    dst:=raw_data(m.scratch[channels:])
    src:=raw_data(f.ring)
    #no_bounds_check {
        for i in 0..<first {dst[i]=f32(src[at*channels+i])*(1.0/32768)}
        for i in 0..<rest {dst[first+i]=f32(src[i])*(1.0/32768)}
    }
    // More of the sound is still to come after these frames, now or later.
    holds:=!ended || count<available
    mixed:int
    alive,mixed=segments_mix(v,dst,count,false,holds,true,out,from,to,max(step,1),target,span)
    if played:=v.cursor>>32;played>0 {
        for c in 0..<channels {v.kept[c]=dst[(played-1)*channels+c]}
    }
    sync.atomic_store_explicit(&f.read,read+v.cursor>>32,.Release)
    v.cursor&=ONE-1
    // Waiting for the first frames of a play is not running dry.
    if alive && holds && mixed<to-from && !ended && write>0 {
        sync.atomic_add_explicit(&m.underruns,1,.Relaxed)
    }
    return alive
}

// The first FEED_START_FRAMES frames of a loaded sound, or all of them,
// decoded once when it loads: what a voice that starts from its beginning
// copies. workspace: the bytes a decoder of a Vorbis setup takes.
@(private)
sound_prime :: proc(m:^Mixer,source:Decoder,workspace:int) -> (primed:[]i16,error:Error) {
    d:=source
    channels:=d.channels
    frames:=min(d.frames,FEED_START_FRAMES)
    failed:runtime.Allocator_Error
    if primed,failed=make([]i16,frames*channels,m.allocator);failed!=nil {return nil,.Out_Of_Memory}
    if d.kind==.Vorbis {
        if d.memory,failed=mem.alloc_bytes_non_zeroed(workspace,align_of(u64),m.allocator);failed!=nil {
            delete(primed,m.allocator)
            return nil,.Out_Of_Memory
        }
    }
    defer delete(d.memory,m.allocator)
    if !decoder_start(&d) {
        delete(primed,m.allocator)
        return nil,.Invalid_Data
    }
    at:=0
    for at<frames {
        got:=0
        if d.kind==.Lossless {
            l:=&d.lossless
            block:=at/l.block_frames
            first:=at-block*l.block_frames
            got=min(l.block_frames-first,frames-at)
            // A damaged block plays as silence.
            lossless_block(l,block,m.start_planes)
            lossless_convert_i16(m.start_planes,l.block_frames,channels,first,got,primed[at*channels:])
        } else {
            decoded:=m.start_floats[:min(frames-at,FEED_FLOAT_FRAMES)*channels]
            got=decoder_read(&d,decoded)
            for x,i in decoded[:got*channels] {primed[at*channels+i]=sample_pcm16(x)}
        }
        if got==0 {break}
        at+=got
    }
    // A file that holds fewer frames than it says keeps those it holds.
    return primed[:at*channels],.None
}
