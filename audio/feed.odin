package mirai_audio

import "core:sync"
import "core:thread"
import "core:time"

// Feeds: rings of decoded 16 bit frames that a voice of a loaded sound plays
// from while a decoder fills them ahead. Each voice takes one from the pool,
// with its own decoder; the decoder thread of the mixer fills them, or,
// without one, voice_play and mixer_update on the calling thread. Every pass
// first decodes FEED_START_FRAMES of each voice that has fewer, so many
// voices that start at once all have their first frames before any is
// filled further. The audio thread only reads what was decoded: a voice
// whose first frames are not decoded yet waits for them, silent, and starts
// late from its first frame; one whose ring runs dry goes silent (underruns)
// and resumes with the frame it stopped at.
//
// The phase of a feed says who touches it: the game thread prepares a Free
// feed and hands it over as Starting; the decoder seeks, fills it while it is
// Running and leaves it Done once the audio thread has let it go; the game
// thread takes a Done feed back as Free.

// Source frames a voice that plays from a feed may consume per output frame:
// its pitch times the ratio of the sample rates is clamped to this.
@(private) FEED_STEP_MAX :: ONE*8
// How often the decoder thread looks at the feeds while some voice plays from one.
@(private) FEEDER_PERIOD :: 2*time.Millisecond
// Frames a start decodes before the decoder fills further: more than a
// device asks for at a time. A lossless block is decoded whole.
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

// Readies a Free feed for a play that begins at offset. The audio thread may
// see the voice before the decoder sees the feed: it then finds nothing to play.
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
// Hands a prepared feed to the decoder: filled at once without a decoder
// thread, else the thread is woken.
@(private)
feed_hand_over :: proc(m:^Mixer,f:^Feed) {
    feed_phase_set(f,.Starting)
    if m.feeder==nil {
        pump_lock(m)
        feed_pump(m,f,FEED_START_FRAMES)
        pump_unlock(m)
        return
    }
    sync.atomic_add_explicit((^u32)(&m.feeder_wake),1,.Release)
    sync.futex_signal(&m.feeder_wake)
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

// Fills every feed it can, the first frames of all of them first; true while
// some feed is in play.
@(private)
feeds_pump :: proc(m:^Mixer) -> (busy:bool) {
    for &f in m.feeds {feed_pump(m,&f,FEED_START_FRAMES)}
    for &f in m.feeds {
        if feed_pump(m,&f,int(f.capacity)) {busy=true}
    }
    return
}
// Decodes until the ring holds ahead frames that were not played, or is full.
@(private)
feed_pump :: proc(m:^Mixer,f:^Feed,ahead:int) -> (busy:bool) {
    switch feed_phase(f) {
    case .Free,.Done:return false
    case .Starting:
        // A decoder that does not open plays nothing.
        if !decoder_start(&f.decoder) {sync.atomic_store_explicit(&f.ended,1,.Release)}
        else {decoder_seek(&f.decoder,f.offset-min(f.offset,1))}
        feed_phase_set(f,.Running)
    case .Running:
    }
    if sync.atomic_load_explicit(&f.released,.Acquire)!=0 {
        feed_phase_set(f,.Done)
        return false
    }
    feed_fill(m,f,u64(ahead))
    return true
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
// played. A lossless block is decoded whole, into the planes of the mixer,
// once the rest of it fits; the ring holds two blocks at least. A WAV or a
// Vorbis file is decoded to f32 in the floats of the mixer and rounded.
@(private)
feed_fill :: proc(m:^Mixer,f:^Feed,ahead:u64) {
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
                lossless_block(l,block,m.feed_planes)
                split:=min(rest,int(run))
                lossless_convert_i16(m.feed_planes,l.block_frames,channels,first,split,f.ring[int(at)*channels:])
                lossless_convert_i16(m.feed_planes,l.block_frames,channels,first+split,rest-split,f.ring)
                got=rest
                d.cursor+=rest
            }
        } else {
            floats:=m.feed_floats[:int(min(run,FEED_FLOAT_FRAMES))*channels]
            got=decoder_read(d,floats)
            ring:=f.ring[int(at)*channels:]
            for x,i in floats[:got*channels] {ring[i]=sample_pcm16(x)}
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
