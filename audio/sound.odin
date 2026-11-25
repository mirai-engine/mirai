package mirai_audio

import "base:runtime"
import "mirai:std/base"

// Sounds: mono or stereo, at the sample rate they were recorded at. A sound
// loaded from a file (WAV, Ogg Vorbis or the lossless coding of
// lossless.odin) keeps its bytes as they came and every voice decodes it as
// it plays, a little ahead (feed.odin): memory holds the file, and a start
// decodes its first frames, not the sound. A sound made in memory
// (sound_create) holds its f32 samples and is mixed from them.

Sound :: distinct base.Handle

// Decoded audio: len(samples)/channels frames, interleaved. loop_start is
// the frame a loop of it goes back to, as its file says; 0 when it does not.
Pcm :: struct {samples:[]f32,channels,sample_rate,loop_start:int}

// The sample rates a sound plays at: what is outside is refused.
SOUND_RATE_MIN :: 1000
SOUND_RATE_MAX :: 384000

pcm_destroy :: proc(pcm:^Pcm,allocator:=context.allocator) {
    delete(pcm.samples,allocator)
    pcm^={}
}

@(private)
Sound_State :: enum u8 {Free,Ready,Releasing}
@(private)
Sound_Slot :: struct {
    generation:u32,
    state:Sound_State,
    release_sent:bool,
    samples:[]f32,  // owned: a sound made in memory
    encoded:[]u8,   // owned: the bytes of a file, or of a WAV its samples
    source:Decoder, // how a voice decodes them
    primed:[]i16,   // owned: its first FEED_START_FRAMES frames decoded, or all of them (feed.odin)
    setup:i32,      // the Vorbis_Setup it decodes with; -1 for none
    frames:u32,
    loop_start:u32, // the frame a loop goes back to
    channels,rate:u32,
}

@(private)
sound_slot :: proc(m:^Mixer,sound:Sound) -> ^Sound_Slot {
    index:=base.handle_index(base.Handle(sound))
    if sound==0 || int(index)>=len(m.sounds) {return nil}
    slot:=&m.sounds[index]
    if slot.state!=.Ready || slot.generation!=base.handle_generation(base.Handle(sound)) {return nil}
    return slot
}
@(private)
sound_slot_take :: proc(m:^Mixer) -> (index:int,error:Error) {
    for slot,i in m.sounds {
        if slot.state==.Free {return i,.None}
    }
    return -1,.Capacity_Exhausted
}
@(private)
sound_slot_bytes :: proc(slot:^Sound_Slot) -> int {
    return len(slot.samples)*size_of(f32)+len(slot.encoded)+len(slot.primed)*size_of(i16)
}
@(private)
sound_slot_free :: proc(m:^Mixer,slot:^Sound_Slot) {
    m.counters.sound_bytes-=sound_slot_bytes(slot)
    if slot.setup>=0 {vorbis_setup_release(m,int(slot.setup))}
    delete(slot.samples,m.allocator)
    delete(slot.encoded,m.allocator)
    delete(slot.primed,m.allocator)
    slot^={generation=slot.generation+1}
    m.counters.sounds-=1
}
// Some feed still decodes the sound, or may: its memory stays.
@(private)
sound_feeds_busy :: proc(m:^Mixer,index:u32) -> bool {
    for &f in m.feeds {
        if f.sound==index && feed_phase(&f)!=.Free {return true}
    }
    return false
}

// Copies interleaved frames into a new sound. channels is 1 or 2.
sound_create :: proc(m:^Mixer,samples:[]f32,channels,sample_rate:int) -> (sound:Sound,error:Error) {
    if channels<1 || channels>2 || sample_rate<SOUND_RATE_MIN || sample_rate>SOUND_RATE_MAX || len(samples)%channels!=0 || len(samples)/channels>=int(max(u32)) {return 0,.Invalid_Desc}
    index:=sound_slot_take(m) or_return
    copied,failed:=make([]f32,len(samples),m.allocator)
    if failed!=nil {return 0,.Out_Of_Memory}
    copy(copied,samples)
    return sound_slot_pcm(m,index,copied,channels,sample_rate),.None
}
// A new sound of interleaved 16 bit frames, turned to f32 as they are copied.
sound_create_pcm16 :: proc(m:^Mixer,samples:[]i16,channels,sample_rate:int) -> (sound:Sound,error:Error) {
    if channels<1 || channels>2 || sample_rate<SOUND_RATE_MIN || sample_rate>SOUND_RATE_MAX || len(samples)%channels!=0 || len(samples)/channels>=int(max(u32)) {return 0,.Invalid_Desc}
    index:=sound_slot_take(m) or_return
    converted,failed:=make([]f32,len(samples),m.allocator)
    if failed!=nil {return 0,.Out_Of_Memory}
    for sample,i in samples {converted[i]=f32(sample)*(1.0/32768)}
    return sound_slot_pcm(m,index,converted,channels,sample_rate),.None
}
// A new sound from a whole file, kept as it came: its bytes are copied (of a
// WAV, its samples) and each voice decodes them. Loading checks the headers
// and decodes nothing; it refuses a file that is not a sound of one or two
// channels at SOUND_RATE_MIN to SOUND_RATE_MAX with frames, a lossless file
// whose block table points outside of it or whose blocks are longer than
// half a feed, and an Ogg Vorbis without whole pages to its setup. A damaged
// block or page inside plays as silence. The first Ogg Vorbis of a setup
// keeps the setup for all the sounds that share it, and may give every feed
// a larger decoder workspace (a transaction).
sound_load :: proc(m:^Mixer,file:[]u8) -> (sound:Sound,error:Error) {
    index:=sound_slot_take(m) or_return
    kept:=file
    kind:=Decoder_Kind.None
    switch {
    case len(file)>=4 && string(file[:4])==LOSSLESS_MAGIC:kind=.Lossless
    case len(file)>=12 && string(file[:4])=="RIFF" && string(file[8:12])=="WAVE":
        wav:=wav_parse(file) or_return
        kept,kind=wav.data,.Wav
    case len(file)>=4 && string(file[:4])=="OggS":
        kept,kind=file[:ogg_whole_pages(file)],.Vorbis
    case:return 0,.Invalid_Data
    }
    encoded,failed:=make([]u8,len(kept),m.allocator)
    if failed!=nil {return 0,.Out_Of_Memory}
    copy(encoded,kept)
    loaded:=false
    defer if !loaded {delete(encoded,m.allocator)}
    // The decoder reads the copy.
    source:Decoder
    setup:=-1
    switch kind {
    case .None:
    case .Lossless:
        l:=lossless_parse(encoded) or_return
        if !lossless_table_valid(&l) {return 0,.Invalid_Data}
        if l.block_frames*2>m.feed_frames {return 0,.Unsupported_Format}
        source={kind=.Lossless,channels=l.channels,sample_rate=l.sample_rate,frames=l.frames,lossless=l}
    case .Wav:
        wav:=wav_parse(file) or_return
        wav.data=encoded
        source={kind=.Wav,channels=wav.channels,sample_rate=wav.sample_rate,frames=wav.frames,wav=wav}
    case .Vorbis:
        source,setup=vorbis_source(m,encoded) or_return
    }
    defer if !loaded && setup>=0 {vorbis_setup_release(m,setup)}
    if source.sample_rate<SOUND_RATE_MIN || source.sample_rate>SOUND_RATE_MAX {return 0,.Unsupported_Format}
    if source.frames<=0 || source.frames>=int(max(u32)) {return 0,.Invalid_Data}
    if setup>=0 {feeds_workspace_reserve(m,m.setups[setup].shared_bytes) or_return}
    primed:=sound_prime(m,source,m.setups[setup].shared_bytes if setup>=0 else 0) or_return
    loaded=true
    return sound_slot_fill(m,index,{
        encoded=encoded,source=source,primed=primed,setup=i32(setup),frames=u32(source.frames),
        channels=u32(source.channels),rate=u32(source.sample_rate),
    }),.None
}
@(private)
sound_slot_pcm :: proc(m:^Mixer,index:int,samples:[]f32,channels,sample_rate:int) -> Sound {
    return sound_slot_fill(m,index,{
        samples=samples,setup=-1,frames=u32(len(samples)/channels),channels=u32(channels),rate=u32(sample_rate),
    })
}
@(private)
sound_slot_fill :: proc(m:^Mixer,index:int,fill:Sound_Slot) -> Sound {
    slot:=&m.sounds[index]
    generation:=slot.generation
    slot^=fill
    slot.generation=generation
    slot.state=.Ready
    m.sound_released[index]=0
    m.counters.sounds+=1
    m.counters.sound_bytes+=sound_slot_bytes(slot)
    return Sound(base.handle_make(u32(index),generation))
}

// The handle dies now and the voices that play the sound end; its memory is
// freed by a later mixer_update, once the audio thread has let go of it.
sound_destroy :: proc(m:^Mixer,sound:Sound) {
    slot:=sound_slot(m,sound)
    if slot==nil {return}
    slot.state=.Releasing
    slot.release_sent=command_push(m,{kind=.Sound_Release,index=base.handle_index(base.Handle(sound))})
}
sound_valid :: proc(m:^Mixer,sound:Sound) -> bool {return sound_slot(m,sound)!=nil}
// The frame a loop of the sound goes back to when it reaches the end, so an
// intro plays once and the body after it repeats; 0, the default, loops it
// whole. Voices that start afterwards follow it. False for a frame outside
// the sound.
sound_set_loop_start :: proc(m:^Mixer,sound:Sound,frame:int) -> bool {
    slot:=sound_slot(m,sound)
    if slot==nil || frame<0 || frame>=int(slot.frames) {return false}
    slot.loop_start=u32(frame)
    return true
}
// Length in frames at its own sample rate.
sound_frames :: proc(m:^Mixer,sound:Sound) -> int {
    slot:=sound_slot(m,sound)
    return int(slot.frames) if slot!=nil else 0
}
sound_sample_rate :: proc(m:^Mixer,sound:Sound) -> int {
    slot:=sound_slot(m,sound)
    return int(slot.rate) if slot!=nil else 0
}
sound_channels :: proc(m:^Mixer,sound:Sound) -> int {
    slot:=sound_slot(m,sound)
    return int(slot.channels) if slot!=nil else 0
}
sound_seconds :: proc(m:^Mixer,sound:Sound) -> f32 {
    rate:=sound_sample_rate(m,sound)
    return f32(sound_frames(m,sound))/f32(rate) if rate>0 else 0
}

// WAV, Ogg Vorbis or lossless, told apart by the first bytes of the file.
decode :: proc(file:[]u8,allocator:runtime.Allocator) -> (pcm:Pcm,error:Error) {
    if len(file)>=12 && string(file[:4])=="RIFF" && string(file[8:12])=="WAVE" {return wav_decode(file,allocator)}
    if len(file)>=4 && string(file[:4])=="OggS" {return vorbis_decode(file,allocator)}
    if len(file)>=4 && string(file[:4])==LOSSLESS_MAGIC {return lossless_decode(file,allocator)}
    return {},.Invalid_Data
}
