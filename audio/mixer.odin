package mirai_audio

import "base:runtime"
import "core:math"
import "core:mem"
import "core:sync"
import "core:thread"

// A mixer of sounds held in memory or streamed, with voices, buses and
// positional audio, that renders interleaved f32 frames into a buffer of the
// caller. It knows no audio device: platform pulls from it.
//
// Two threads at most use a Mixer. mixer_render may run on an audio thread;
// everything else belongs to one other thread (the game thread). They share
// no lock: what the game thread asks for travels in a queue that the audio
// thread empties at the start of every chunk it renders, and what the audio
// thread has to tell comes back in atomics that mixer_update reads. Sounds
// that decode as they play are decoded by a third thread of the mixer, when
// it has one, into rings the audio thread reads without waiting (feed.odin).

Error :: enum u8 {
    None,
    Out_Of_Memory,
    Invalid_Desc,
    Capacity_Exhausted,
    Invalid_Data,       // not a WAV or Ogg Vorbis file, or a damaged one
    Unsupported_Format, // a sample format or channel count the mixer does not play
}

// Frames a second the mixer renders: those its HRTF was measured at. The
// device converts them to its own rate (platform.audio_device_open).
MIXER_RATE :: 48000

Mixer_Desc :: struct {
    channels:int,         // 1 or 2; 2 when zero
    voice_capacity:int,   // 64 when zero
    bus_capacity:int,     // the master included; 8 when zero
    sound_capacity:int,   // 256 when zero
    stream_capacity:int,  // streamed voices that play at once, up to STREAM_CAPACITY_MAX; STREAM_CAPACITY_DEFAULT (or fewer, with few voices) when zero; mixer_set_stream_capacity changes it
    stream_frames:int,    // frames buffered ahead for every stream, rounded up to a power of two; half a second when zero
    feed_capacity:int,    // voices that can play sounds kept encoded at once, those stolen and not yet let go included; a quarter more than voice_capacity when zero
    feed_frames:int,      // frames buffered ahead for each of them, rounded up to a power of two; two lossless blocks when zero. A lossless file of blocks longer than half of it is decoded whole when it loads
    decoder_thread:bool,  // decode on a thread of the mixer; false: voice_play and mixer_update decode on the calling thread
    command_capacity:int, // commands the game thread can queue between two chunks, rounded up to a power of two; 1024 when zero
    speed_of_sound:f32,   // meters per second, for Doppler and delay; 343 when zero
    output:Output_Kind,   // what the output plays on; mixer_set_output changes it
    allocator:runtime.Allocator, // context.allocator when unset
}

// Frames mixed at a time: commands and parameter changes take effect at the
// start of a chunk and are ramped across it.
CHUNK_FRAMES :: 256
// Bounds of a desc: past them the sizes of its memory would not be numbers.
MIXER_CAPACITY_MAX :: 1<<16
MIXER_RING_FRAMES_MAX :: 1<<24
PITCH_MIN :: f32(1.0/64)
PITCH_MAX :: f32(64)
STREAM_CAPACITY_DEFAULT :: 16
STREAM_CAPACITY_MAX :: 64

Mixer_Stats :: struct {
    frames_rendered:u64,
    voices_active:int,    // as of the last chunk rendered
    voices_played:u64,
    voices_stolen:u64,    // voices ended to make room for a new one
    voices_rejected:u64,  // voices not started: no room, and nothing of lower or equal priority to steal
    commands_dropped:u64, // requests lost because the command queue was full
    underruns:u64,        // chunks in which a voice that decodes as it plays had nothing decoded to play
    streams_busy:u64,     // plays refused because every stream feed was taken
    stream_capacity:int,  // streamed voices that play at once
    feeds_busy:u64,       // plays of a sound kept encoded refused because every feed was taken
    sounds:int,
    sound_bytes:int,      // memory the sounds hold: samples, encoded bytes and the decoders of streams
}

@(private) ONE :: u64(1)<<32 // a source frame in the 32.32 fixed point of a voice cursor

@(private)
Command_Kind :: enum u8 {
    Voice_Play,Voice_Stop,Voice_Pause,Voice_Volume,Voice_Pitch,Voice_Pan,Voice_Loop,Voice_Fade,Voice_Place,Voice_Occlusion,Voice_Reverb,Voice_Listener,Voice_Lowpass,
    Bus_Volume,Bus_Mute,Bus_Filter,Bus_Delay,Bus_Duck,Bus_Reverb,Bus_Send,
    Reverb,
    Listener,Listeners,
    Output,
    Sound_Release,
}
@(private)
Command :: struct {
    kind:Command_Kind,
    flag:bool,
    index:u32,      // voice, bus or sound
    generation:u32, // of the voice
    value:f32,
    frames:u32,
    vectors:[3][3]f32,
    rotation:quaternion128,
    duck:Duck,
    filter:Filter,
    delay_memory:[]f32,
    start:Voice_Start,
}
// One producer (the game thread) and one consumer (the audio thread).
@(private)
Command_Queue :: struct {
    items:[]Command,
    head:u64, // next to read; written by the audio thread
    tail:u64, // the audio thread reads up to it; written by the game thread
    written:u64, // next to write: ahead of tail while a batch is open
    batch_depth:u32,
}

Mixer :: struct {
    allocator:runtime.Allocator,
    sample_rate,channels:int,
    speed_of_sound:f32,
    commands:Command_Queue,
    clock:u64, // frames rendered; atomic

    // Game thread.
    sounds:[]Sound_Slot,
    shadows:[]Voice_Shadow,
    free_voices:[]u32,free_count:int,
    sequence:u64,
    bus_count:int,
    bus_shadows:[]Bus_Shadow,
    reverb_shadow:Reverb_Shadow,
    free_feeds:[]u32,free_feed_count,free_stream_count:int, // encoded first, then streams
    stream_capacity:int,  // stream feeds handed out, of the STREAM_CAPACITY_MAX after the pool
    stream_frames:int,    // of the ring of each
    stream_workspace:int, // bytes of decoder workspace of each, as the largest stream loaded asks
    counters:Mixer_Stats,
    output:Output_Kind,

    // Feeds: the pool for encoded sounds first, then STREAM_CAPACITY_MAX for
    // stream voices. A stream feed has its ring and workspace while it is one
    // of stream_capacity or still plays.
    feeds:[]Feed,
    pool_feeds:int,
    feed_frames:int,
    feed_rings:[]i16,  // the rings of the pool
    feed_planes:[]i32, // a lossless block of a feed of the pool, being decoded
    feeder:^thread.Thread,
    feeder_wake:sync.Futex,
    feeder_quit:bool,
    pumping:u32, // a decoder is filling the feeds

    // Audio thread.
    voices:[]Mix_Voice,
    buses:[]Mix_Bus,
    bus_buffers:[]f32, // CHUNK_FRAMES stereo frames per bus
    voice_scratch:[]f32, // CHUNK_FRAMES stereo frames: a voice before its filter and its send
    reverb_input:[]f32,  // CHUNK_FRAMES stereo frames: what the voices send to the reverb
    reverb:Reverb_Unit,  // the room
    reverb_bus:u16,      // where the room returns
    bus_reverbs:[]Reverb_Unit,
    delay_memory:[][]f32, // per bus: game-thread owned delay lines freed on destroy; passed to audio thread via Command
    meter_fall:f32,       // precomputed per-CHUNK_FRAMES decay factor for bus meters
    limiter:Limiter,
    scratch:[]f32,     // source frames of a voice that plays from a feed, laid out in a row
    listeners:[LISTENERS_MAX]Listener,
    listener_count:int, // those of the first slots hear
    listener_serial:u32, // grows when a listener changes
    output_now:Output_Kind,
    binaural_ready:bool, // binaural_init was done before output_now was ever headphones
    spatial_mono,spatial_old:[]f32, // CHUNK_FRAMES per channel: a spatial voice before it is placed
    hrtf:Hrtf,
    conv:Fft, // of the binaural convolution
    // Per voice slot (binaural.odin): the HRTF spectra of both ears and the last input.
    binaural_spectra:[]f32, // complex
    binaural_dry:[]f32,
    // Per bus and ear: what its voices add up to in the chunk (complex) and the
    // ring of binaural_ring frames still to play.
    binaural_sums,binaural_rings:[]f32,
    binaural_used:[]bool,
    binaural_left:[]i32, // per bus: frames of its rings that may still hold sound
    binaural_ring:int,
    binaural_read:int, // where the rings play from
    binaural_kept:int, // samples the last chunk fell over
    binaural_window:[]f32, // the rise over BINAURAL_OVERLAP samples
    binaural_windowed,binaural_wet,binaural_input:[]f32,
    binaural_dry_spectrum:[]f32, // complex

    // Written by the audio thread, read by the game thread; atomic.
    finished:[]u32,        // per voice slot: generation of the voice that last ended there
    sound_released:[]u32,  // per sound slot: 1 once no voice plays it any more
    voices_active:i32,
    underruns:u64,
    bus_meters:[][2]u32, // per bus and channel: Mix_Bus.meter, as the bits of an f32
}

mixer_create :: proc(desc:Mixer_Desc) -> (m:^Mixer,error:Error) {
    allocator:=desc.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    channels:=desc.channels if desc.channels!=0 else 2
    if channels<1 || channels>2 {return nil,.Invalid_Desc}
    if desc.voice_capacity<0 || desc.bus_capacity<0 || desc.bus_capacity>int(max(u16)) || desc.sound_capacity<0 || desc.stream_capacity<0 || desc.feed_capacity<0 || desc.feed_capacity>MIXER_CAPACITY_MAX || desc.voice_capacity>MIXER_CAPACITY_MAX || desc.stream_capacity>STREAM_CAPACITY_MAX || desc.command_capacity>MIXER_CAPACITY_MAX {return nil,.Invalid_Desc}
    if desc.feed_frames<0 || desc.feed_frames>MIXER_RING_FRAMES_MAX || desc.stream_frames<0 || desc.stream_frames>MIXER_RING_FRAMES_MAX {return nil,.Invalid_Desc}
    failed:runtime.Allocator_Error
    if m,failed=new(Mixer,allocator);failed!=nil {return nil,.Out_Of_Memory}
    m.allocator=allocator
    m.sample_rate=MIXER_RATE
    m.channels=channels
    m.speed_of_sound=desc.speed_of_sound if desc.speed_of_sound>0 else 343
    if desc.output!=.Headphones && desc.output!=.Speakers {mixer_destroy(m);return nil,.Invalid_Desc}
    m.output,m.output_now=desc.output,desc.output
    if error=mixer_init(m,desc);error!=.None {
        mixer_destroy(m)
        return nil,error
    }
    if desc.decoder_thread {
        context.allocator=allocator
        if m.feeder=thread.create(feeder_main);m.feeder==nil {
            mixer_destroy(m)
            return nil,.Out_Of_Memory
        }
        m.feeder.data=m
        thread.start(m.feeder)
    }
    return m,.None
}
@(private)
mixer_init :: proc(m:^Mixer,desc:Mixer_Desc) -> Error {
    allocator:=m.allocator
    voices:=desc.voice_capacity if desc.voice_capacity>0 else 64
    buses:=desc.bus_capacity if desc.bus_capacity>0 else 8
    sounds:=desc.sound_capacity if desc.sound_capacity>0 else 256
    voice_feeds:=voices+voices/4+1
    streams:=desc.stream_capacity if desc.stream_capacity>0 else min(voice_feeds,STREAM_CAPACITY_DEFAULT)
    commands:=4
    for commands<(desc.command_capacity if desc.command_capacity>0 else 1024) {commands*=2}
    stream_frames:=CHUNK_FRAMES*4
    for stream_frames<(desc.stream_frames if desc.stream_frames>0 else m.sample_rate/2) {stream_frames*=2}
    pool:=desc.feed_capacity if desc.feed_capacity>0 else voice_feeds
    feed_frames:=CHUNK_FRAMES*4
    for feed_frames<(desc.feed_frames if desc.feed_frames>0 else LOSSLESS_BLOCK_FRAMES*2) {feed_frames*=2}
    m.feed_frames=feed_frames
    m.pool_feeds=pool
    m.stream_frames=stream_frames
    failed:runtime.Allocator_Error
    if m.commands.items,failed=make([]Command,commands,allocator);failed!=nil {return .Out_Of_Memory}
    if m.sounds,failed=make([]Sound_Slot,sounds,allocator);failed!=nil {return .Out_Of_Memory}
    if m.sound_released,failed=make([]u32,sounds,allocator);failed!=nil {return .Out_Of_Memory}
    if m.shadows,failed=make([]Voice_Shadow,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.free_voices,failed=make([]u32,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.voices,failed=make([]Mix_Voice,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.finished,failed=make([]u32,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.bus_shadows,failed=make([]Bus_Shadow,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.buses,failed=make([]Mix_Bus,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.bus_buffers,failed=make([]f32,buses*CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.delay_memory,failed=make([][]f32,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.bus_meters,failed=make([][2]u32,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.voice_scratch,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.reverb_input,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    reverb_init(m,&m.reverb) or_return
    if m.bus_reverbs,failed=make([]Reverb_Unit,buses,allocator);failed!=nil {return .Out_Of_Memory}
    for &unit in m.bus_reverbs {reverb_init(m,&unit) or_return}
    // The source frames of a chunk of a feed at its fastest, and the frame after them.
    if m.scratch,failed=make([]f32,(CHUNK_FRAMES*int(FEED_STEP_MAX>>32)+4)*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.feeds,failed=make([]Feed,pool+STREAM_CAPACITY_MAX,allocator);failed!=nil {return .Out_Of_Memory}
    if m.free_feeds,failed=make([]u32,pool+STREAM_CAPACITY_MAX,allocator);failed!=nil {return .Out_Of_Memory}
    if m.feed_rings,failed=make([]i16,pool*feed_frames*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.feed_planes,failed=make([]i32,feed_frames,allocator);failed!=nil {return .Out_Of_Memory}
    for &f,i in m.feeds[:pool] {
        f.ring16=m.feed_rings[i*feed_frames*2:][:feed_frames*2]
        f.capacity=u64(feed_frames)
        // The first feed is handed out first.
        m.free_feeds[i]=u32(pool-1-i)
    }
    m.free_feed_count=pool
    mixer_set_stream_capacity(m,streams) or_return
    for &slot in m.sounds {slot.generation=1}
    // Slot 0 is handed out first.
    for &shadow,i in m.shadows {
        shadow.generation=1
        m.free_voices[i]=u32(voices-1-i)
    }
    m.free_count=voices
    m.bus_count=1
    for &bus in m.bus_shadows {bus.volume=1}
    for &bus in m.buses {bus.volume=1;bus.gain=1;bus.duck_gain=1;bus.duck_gain_now=1}
    for &l in m.listeners {l.rotation,l.medium=1,{1,1,1}}
    m.listener_count=1
    m.limiter.gain=1
    m.meter_fall=math.pow(f32(10),-METER_FALL*f32(CHUNK_FRAMES)/(20*f32(m.sample_rate)))
    if m.spatial_mono,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.spatial_old,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if desc.output==.Headphones {
        binaural_init(m) or_return
        m.binaural_ready=true
    }
    return .None
}

// The HRTF and what binaural output needs per voice and bus, built the first
// time the output is headphones and kept after.
@(private)
binaural_init :: proc(m:^Mixer) -> (error:Error) {
    if m.conv.n>0 {return .None}
    defer if error!=.None {binaural_destroy(m)}
    allocator:=m.allocator
    failed:runtime.Allocator_Error
    voices,buses:=len(m.voices),len(m.buses)
    hrtf_load(&m.hrtf,MIXER_RATE,allocator) or_return
    fft_init(&m.conv,BINAURAL_WINDOW+m.hrtf.samples-1,allocator) or_return
    bins:=m.conv.n/2+1
    m.binaural_ring=next_pow2(m.conv.n+BINAURAL_OVERLAP)
    if m.binaural_spectra,failed=make([]f32,voices*2*bins*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_sums,failed=make([]f32,buses*2*bins*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_rings,failed=make([]f32,buses*2*m.binaural_ring,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_used,failed=make([]bool,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_left,failed=make([]i32,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_input,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_dry,failed=make([]f32,voices*2*BINAURAL_OVERLAP,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_window,failed=make([]f32,BINAURAL_OVERLAP,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_windowed,failed=make([]f32,m.conv.n,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_wet,failed=make([]f32,m.conv.n,allocator);failed!=nil {return .Out_Of_Memory}
    if m.binaural_dry_spectrum,failed=make([]f32,2*2*bins,allocator);failed!=nil {return .Out_Of_Memory}
    for &w,i in m.binaural_window {w=0.5*(1+math.cos(math.PI*(f32(i)/f32(BINAURAL_OVERLAP-1)-1)))}
    return .None
}

// The audio thread must have stopped rendering before this is called.
mixer_destroy :: proc(m:^Mixer) {
    if m==nil {return}
    feeder_stop(m)
    allocator:=m.allocator
    for &f in m.feeds {
        if f.ring32==nil {continue}
        stream_decoder_close(m,&f)
        stream_feed_close(m,&f)
    }
    for &slot in m.sounds {
        if slot.state!=.Free {sound_slot_free(m,&slot)}
    }
    delete(m.feeds,allocator);delete(m.free_feeds,allocator);delete(m.feed_rings,allocator);delete(m.feed_planes,allocator)
    delete(m.commands.items,allocator)
    delete(m.sounds,allocator);delete(m.sound_released,allocator)
    delete(m.shadows,allocator);delete(m.free_voices,allocator)
    delete(m.voices,allocator);delete(m.finished,allocator)
    delete(m.bus_shadows,allocator);delete(m.buses,allocator);delete(m.bus_buffers,allocator)
    for memory in m.delay_memory {delete(memory,allocator)}
    delete(m.delay_memory,allocator);delete(m.bus_meters,allocator)
    delete(m.voice_scratch,allocator);delete(m.reverb_input,allocator);delete(m.reverb.memory,allocator)
    for unit in m.bus_reverbs {delete(unit.memory,allocator)}
    delete(m.bus_reverbs,allocator)
    delete(m.scratch,allocator)
    delete(m.spatial_mono,allocator);delete(m.spatial_old,allocator)
    binaural_destroy(m)
    free(m,allocator)
}

@(private)
binaural_destroy :: proc(m:^Mixer) {
    allocator:=m.allocator
    hrtf_destroy(&m.hrtf,allocator)
    fft_destroy(&m.conv,allocator)
    delete(m.binaural_spectra,allocator);delete(m.binaural_rings,allocator);delete(m.binaural_dry,allocator)
    delete(m.binaural_window,allocator);delete(m.binaural_windowed,allocator);delete(m.binaural_wet,allocator)
    delete(m.binaural_dry_spectrum,allocator);delete(m.binaural_sums,allocator);delete(m.binaural_used,allocator)
    delete(m.binaural_left,allocator);delete(m.binaural_input,allocator)
    m.binaural_spectra,m.binaural_rings,m.binaural_dry,m.binaural_window,m.binaural_windowed,m.binaural_wet=nil,nil,nil,nil,nil,nil
    m.binaural_dry_spectrum,m.binaural_sums,m.binaural_used,m.binaural_left,m.binaural_input=nil,nil,nil,nil,nil
}

// Frames rendered since the mixer was created: the time base of Voice_Desc.start_frame.
mixer_clock :: proc "contextless" (m:^Mixer) -> u64 {
    return sync.atomic_load_explicit(&m.clock,.Acquire)
}
mixer_stats :: proc(m:^Mixer) -> Mixer_Stats {
    stats:=m.counters
    stats.frames_rendered=mixer_clock(m)
    stats.voices_active=int(sync.atomic_load_explicit(&m.voices_active,.Relaxed))
    stats.underruns=sync.atomic_load_explicit(&m.underruns,.Relaxed)
    stats.stream_capacity=m.stream_capacity
    return stats
}

// How many streamed voices play at once, 1 to STREAM_CAPACITY_MAX: a
// transaction of the game thread. The streams it adds take their rings now
// (Out_Of_Memory changes nothing); one it takes away while it plays goes on
// until it ends, and then lets go of its memory.
mixer_set_stream_capacity :: proc(m:^Mixer,count:int) -> Error {
    if count<1 || count>STREAM_CAPACITY_MAX {return .Invalid_Desc}
    streams:=m.feeds[m.pool_feeds:]
    was:=m.stream_capacity
    for i in was..<count {
        if stream_feed_open(m,&streams[i]) {continue}
        for j in was..<i {
            if feed_phase(&streams[j])==.Free {stream_feed_close(m,&streams[j])}
        }
        return .Out_Of_Memory
    }
    if count>was {
        // One that still plays from before a lower capacity comes back when it ends.
        for i in was..<count {
            if feed_phase(&streams[i])!=.Free {continue}
            m.free_feeds[m.pool_feeds+m.free_stream_count]=u32(m.pool_feeds+i)
            m.free_stream_count+=1
        }
    } else {
        kept:=0
        for at in 0..<m.free_stream_count {
            index:=m.free_feeds[m.pool_feeds+at]
            if int(index)<m.pool_feeds+count {
                m.free_feeds[m.pool_feeds+kept]=index
                kept+=1
            } else {
                stream_feed_close(m,&m.feeds[index])
            }
        }
        m.free_stream_count=kept
    }
    m.stream_capacity=count
    return .None
}

// The ring and the decoder workspace of a stream feed; true when it has them.
@(private)
stream_feed_open :: proc(m:^Mixer,f:^Feed) -> bool {
    if f.ring32!=nil {return true}
    ring,failed:=make([]f32,m.stream_frames*2,m.allocator)
    if failed!=nil {return false}
    if m.stream_workspace>0 {
        if f.workspace,failed=mem.alloc_bytes_non_zeroed(m.stream_workspace,align_of(u64),m.allocator);failed!=nil {
            delete(ring,m.allocator)
            return false
        }
    }
    f.ring32,f.capacity=ring,u64(m.stream_frames)
    return true
}
// Frees them, of a feed no decoder uses.
@(private)
stream_feed_close :: proc(m:^Mixer,f:^Feed) {
    delete(f.workspace,m.allocator)
    delete(f.ring32,m.allocator)
    f.workspace,f.ring32,f.capacity=nil,nil,0
}

// Once per frame on the game thread: frees the voices that ended, the feeds
// they let go of and the sounds that were destroyed, and, without a decoder
// thread, decodes ahead for the voices that decode as they play.
mixer_update :: proc(m:^Mixer) {
    for &shadow,i in m.shadows {
        if !shadow.active || sync.atomic_load_explicit(&m.finished[i],.Acquire)!=shadow.generation {continue}
        voice_shadow_free(m,u32(i))
    }
    if m.feeder==nil {mixer_decode(m)}
    for &f,i in m.feeds {
        if feed_phase(&f)!=.Done {continue}
        if i>=m.pool_feeds {
            stream_decoder_close(m,&f)
            if i<m.pool_feeds+m.stream_capacity {
                m.free_feeds[m.pool_feeds+m.free_stream_count]=u32(i);m.free_stream_count+=1
            } else {
                stream_feed_close(m,&f)
            }
        } else {
            m.free_feeds[m.free_feed_count]=u32(i);m.free_feed_count+=1
        }
        feed_phase_set(&f,.Free)
    }
    for &slot,i in m.sounds {
        if slot.state!=.Releasing {continue}
        if !slot.release_sent {
            slot.release_sent=command_push(m,{kind=.Sound_Release,index=u32(i)})
            continue
        }
        if sync.atomic_load_explicit(&m.sound_released[i],.Acquire)!=0 && !sound_feeds_busy(m,u32(i)) {sound_slot_free(m,&slot)}
    }
}

@(private)
command_push :: proc(m:^Mixer,command:Command) -> bool {
    q:=&m.commands
    head:=sync.atomic_load_explicit(&q.head,.Acquire)
    if q.written-head>=u64(len(q.items)) {m.counters.commands_dropped+=1;return false}
    q.items[q.written&u64(len(q.items)-1)]=command
    q.written+=1
    if q.batch_depth==0 {sync.atomic_store_explicit(&q.tail,q.written,.Release)}
    return true
}

// What the game thread asks between mixer_batch_begin and mixer_batch_end
// reaches the audio thread at once, so it takes effect in one chunk: the
// layers of a sound started, retuned or stopped together stay in step to the
// sample. A batch holds at most the capacity of the queue; batches may nest.
mixer_batch_begin :: proc(m:^Mixer) {m.commands.batch_depth+=1}
mixer_batch_end :: proc(m:^Mixer) {
    q:=&m.commands
    if q.batch_depth==0 {return}
    q.batch_depth-=1
    if q.batch_depth==0 {sync.atomic_store_explicit(&q.tail,q.written,.Release)}
}
@(private)
command_pop :: proc "contextless" (m:^Mixer,command:^Command) -> bool {
    q:=&m.commands
    head:=q.head
    tail:=sync.atomic_load_explicit(&q.tail,.Acquire)
    if head==tail {return false}
    command^=q.items[head&u64(len(q.items)-1)]
    sync.atomic_store_explicit(&q.head,head+1,.Release)
    return true
}

// Renders len(out)/channels frames, interleaved, replacing what out held,
// under LIMITER_CEILING.
// Safe to call from an audio thread: it takes no lock and allocates nothing.
mixer_render :: proc "contextless" (m:^Mixer,out:[]f32) {
    float_mode:=denormals_flush()
    defer denormals_restore(float_mode)
    frames:=len(out)/m.channels
    done:=0
    for done<frames {
        n:=min(frames-done,CHUNK_FRAMES)
        commands_apply(m)
        chunk_render(m,out[done*m.channels:][:n*m.channels],n)
        done+=n
        sync.atomic_add_explicit(&m.clock,u64(n),.Release)
    }
}

@(private)
commands_apply :: proc "contextless" (m:^Mixer) {
    command:Command
    for command_pop(m,&command) {
        switch command.kind {
        case .Voice_Play:
            v:=&m.voices[command.index]
            // A start already past begins whole in the chunk the play reaches, and
            // a delay counts from there: the voices of one batch keep their delays.
            command.start.start_frame=max(command.start.start_frame,m.clock)+u64(command.start.delay)
            command.start.delay=0
            if v.phase==.Free {
                voice_begin(m,v,command.start)
            } else {
                // The slot was stolen: what plays there fades out first.
                if v.has_next {feed_release(m,&v.next)}
                v.next=command.start;v.has_next=true
            }
        case .Voice_Stop,.Voice_Pause,.Voice_Volume,.Voice_Pitch,.Voice_Pan,.Voice_Loop,.Voice_Fade,.Voice_Place,.Voice_Occlusion,.Voice_Reverb,.Voice_Listener,.Voice_Lowpass:
            voice_command(m,&command)
        case .Bus_Volume:m.buses[command.index].volume=command.value
        case .Bus_Mute:m.buses[command.index].silent=command.flag
        case .Bus_Filter:
            b,on:=biquad_of(command.filter,f32(m.sample_rate))
            biquad_fade_set(&m.buses[command.index].filters[command.frames],b,on)
        case .Bus_Delay:
            d:=command.vectors[0]
            delay_apply(&m.buses[command.index].delay,{d[0],d[1],d[2]},command.delay_memory,m.sample_rate)
        case .Bus_Duck:
            bus:=&m.buses[command.index]
            bus.duck=command.duck
        case .Reverb:
            m.reverb.params=reverb_command(&command)
            m.reverb_bus=u16(command.index)
        case .Bus_Reverb:m.bus_reverbs[command.index].params=reverb_command(&command)
        case .Bus_Send:m.buses[command.index].send=Bus(command.frames)
        case .Listener:
            m.listeners[command.index]={command.vectors[0],command.vectors[1],command.rotation,command.vectors[2]}
            m.listener_serial+=1
        case .Listeners:
            m.listener_count=int(command.index)
            m.listener_serial+=1
        case .Output:
            m.output_now=Output_Kind(command.index)
            m.binaural_ready||=m.output_now==.Headphones
            // What a voice kept for the other output starts over.
            for &v in m.voices {v.binaural_live=false}
        case .Sound_Release:
            for &v,i in m.voices {
                if v.has_next && v.next.sound==command.index {voice_next_cancel(m,u32(i))}
                if v.phase!=.Free && v.sound==command.index {
                    // What takes its place may play the same sound.
                    voice_end(m,u32(i))
                    if v.phase!=.Free && v.sound==command.index {voice_end(m,u32(i))}
                }
            }
            sync.atomic_store_explicit(&m.sound_released[command.index],1,.Release)
        }
    }
}

@(private)
chunk_render :: proc "contextless" (m:^Mixer,out:[]f32,n:int) {
    #no_bounds_check {
        for i in 0..<len(m.buses)*CHUNK_FRAMES*2 {m.bus_buffers[i]=0}
        for i in 0..<CHUNK_FRAMES*2 {m.reverb_input[i]=0}
    }
    clock:=m.clock
    active:=i32(0)
    for &v,i in m.voices {
        if v.phase==.Free {continue}
        voice_mix(m,u32(i),n,clock)
        if v.phase!=.Free {active+=1}
    }
    sync.atomic_store_explicit(&m.voices_active,active,.Relaxed)
    binaural_flush(m,n)
    room:=raw_data(m.bus_buffers[int(m.reverb_bus)*CHUNK_FRAMES*2:])
    reverb_run(&m.reverb,raw_data(m.reverb_input),room,n)
    buses_mix(m,out,n)
}
