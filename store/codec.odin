package store

import "base:runtime"
import "core:sync"
import "compressor:data"

// How a chunk frame stores its data: CODEC_NONE as the chunk's bytes, or encoded by a format of
// the collection compressor, which a put chooses when it shrinks the chunk. An address is always
// of the bytes before the codec, so what is hashed and shared never depends on a compressor. A
// frame of a codec this value does not decode is, to it, a chunk that is not here: a lookup
// misses it, a put of its address appends a frame it reads, and a table keeps a readable copy
// over it. Nodes are stored as they are: a sweep of any build walks them.

CODEC_NONE :: 0
CODECS_MAX :: 16 // ids at or above it are damage

// A set of codec ids: what a value or a peer decodes.
Codecs :: bit_set[0..<CODECS_MAX;u16]

// Codec ids are persistent. Retired ids stay unassigned.
@(private) CODEC_MDC1 :: 4

// The formats of the ids; an id without one is the codec of no build.
@(private) CODEC_FORMATS :: [CODECS_MAX]data.Format{3=data.MLZ1,CODEC_MDC1=data.MDC1}
// What every build decodes: of several copies of a chunk, a sweep keeps one of these.
@(private) CODECS_OPEN :: Codecs{CODEC_NONE,CODEC_MDC1}

// A codec a test gives a value to act as a build with another compressor: the value writes its
// frames with it and decodes it besides the codecs of this build.
Codec_Hook :: struct {
    codec:u8,                           // 1 to CODECS_MAX-1
    encode:proc(src,dst:[]u8) -> int,   // into dst of data.bound(len(src)); 0: it does not shrink
    decode:proc(src,dst:[]u8) -> bool,  // into all of dst
}

// The encoder, the decoder and the scratch of one thread's frames, taken from a pool of the
// value. The compressor's types are behind pointers: their sizes are those of the compressor a
// binary was built with.
@(private)
Coder :: struct {
    encoder:^data.Encoder,
    decoder:^data.Decoder,
    scratch:[]u8, // data.bound(CHUNK_MAX): an encoded frame, or one read to decode
}

// The id of a format; CODEC_NONE for one without.
@(private)
codec_of :: proc "contextless" (format:data.Format) -> u8 {
    formats:=CODEC_FORMATS
    for f,id in formats {
        if f==format && f!=0 {return u8(id)}
    }
    return CODEC_NONE
}

// What this build decodes and writes with, found once when the value opens.
@(private)
codecs_init :: proc(s:^Store) {
    state:=s.state
    state.decodes={CODEC_NONE}
    d:data.Decoder
    if data.decoder_init(&d,state.allocator)!=.None {return}
    defer data.decoder_destroy(&d)
    formats:=CODEC_FORMATS
    for format,id in formats {
        // A format this build lacks is Unknown_Format whatever the bytes.
        if format!=0 && data.decode(&d,format,{},{})!=.Unknown_Format {state.decodes+={id}}
    }
    if write:=codec_of(data.format(.Fast));int(write) in state.decodes {state.write=write}
}

// The codecs this value decodes: what it tells a peer.
codecs_read :: proc(s:^Store) -> Codecs {
    if s==nil || s.state==nil {return {CODEC_NONE}}
    return s.state.decodes
}

// Gives a value a codec of a test (Codec_Hook): from now on it writes frames with it.
codec_hook :: proc(s:^Store,hook:Codec_Hook) -> Error {
    if s==nil || s.state==nil || hook.codec==CODEC_NONE || int(hook.codec)>=CODECS_MAX || hook.encode==nil || hook.decode==nil {return .Invalid_Argument}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    s.state.hook=hook
    s.state.decodes+={int(hook.codec)}
    s.state.write=hook.codec
    // What was found unreadable before may read now.
    state_rebuild_locked(s)
    return .None
}

// Whether a frame of a codec is one this value decodes.
@(private)
codec_readable :: #force_inline proc "contextless" (s:^Store,codec:u8) -> bool {
    return int(codec)<CODECS_MAX && int(codec) in s.state.decodes
}

// Which of two copies of a chunk a table keeps: one every build reads, then one this value reads.
@(private)
codec_rank :: proc "contextless" (codec:u8,decodes:Codecs) -> int {
    if int(codec)>=CODECS_MAX || int(codec) not_in decodes {return 0}
    return 2 if int(codec) in CODECS_OPEN else 1
}

@(private)
coder_take :: proc(s:^Store) -> (c:^Coder,error:Error) {
    state:=s.state
    sync.mutex_lock(&state.lock)
    if len(state.coders)>0 {c=pop(&state.coders)}
    sync.mutex_unlock(&state.lock)
    if c!=nil {return c,.None}
    return coder_new(s)
}

@(private)
coder_new :: proc(s:^Store) -> (c:^Coder,error:Error) {
    allocator:=s.state.allocator
    allocation:runtime.Allocator_Error
    if c,allocation=new(Coder,allocator);allocation!=nil {return nil,.Out_Of_Memory}
    defer if error!=.None {coder_free(s,c)}
    if c.scratch,allocation=make([]u8,data.bound(CHUNK_MAX),allocator);allocation!=nil {return c,.Out_Of_Memory}
    if c.encoder,allocation=new(data.Encoder,allocator);allocation!=nil {return c,.Out_Of_Memory}
    if data.encoder_init(c.encoder,allocator)!=.None {
        free(c.encoder,allocator)
        c.encoder=nil
        return c,.Out_Of_Memory
    }
    if c.decoder,allocation=new(data.Decoder,allocator);allocation!=nil {return c,.Out_Of_Memory}
    if data.decoder_init(c.decoder,allocator)!=.None {
        free(c.decoder,allocator)
        c.decoder=nil
        return c,.Out_Of_Memory
    }
    return c,.None
}

@(private)
coder_give :: proc(s:^Store,c:^Coder) {
    if c==nil {return}
    sync.mutex_lock(&s.state.lock)
    _,e:=append(&s.state.coders,c)
    sync.mutex_unlock(&s.state.lock)
    if e!=nil {coder_free(s,c)}
}

@(private)
coder_free :: proc(s:^Store,c:^Coder) {
    allocator:=s.state.allocator
    if c.encoder!=nil {
        data.encoder_destroy(c.encoder)
        free(c.encoder,allocator)
    }
    if c.decoder!=nil {
        data.decoder_destroy(c.decoder)
        free(c.decoder,allocator)
    }
    delete(c.scratch,allocator)
    free(c,allocator)
}

// The frame of a chunk's bytes: encoded into the coder's scratch with the codec this value
// writes when that shrinks it, else the bytes as they are. A node stays as it is.
@(private)
frame_encode :: proc(s:^Store,c:^Coder,bytes:[]u8) -> (codec:u8,stored:[]u8) {
    state:=s.state
    if state.write==CODEC_NONE || len(bytes)<2 {return CODEC_NONE,bytes}
    if _,e:=node_parse(bytes);e==.None {return CODEC_NONE,bytes}
    size:int
    if state.hook.codec!=CODEC_NONE {
        size=state.hook.encode(bytes,c.scratch)
    } else {
        written,error:=data.encode(c.encoder,.Fast,bytes,c.scratch)
        if error!=.None {return CODEC_NONE,bytes}
        size=written
    }
    if size<=0 || size>=len(bytes) || size>len(c.scratch) {return CODEC_NONE,bytes}
    return state.write,c.scratch[:size]
}

// The bytes of a frame of codec into all of dst, the chunk's size. Missing for a codec this
// value does not decode, Corrupt for bytes that do not decode to it.
@(private)
frame_decode :: proc(s:^Store,c:^Coder,codec:u8,stored,dst:[]u8) -> Error {
    if codec==CODEC_NONE {
        if len(stored)!=len(dst) {return .Corrupt}
        copy(dst,stored)
        return .None
    }
    if !codec_readable(s,codec) {return .Missing}
    hook:=s.state.hook
    if hook.codec!=CODEC_NONE && codec==hook.codec {return .None if hook.decode(stored,dst) else .Corrupt}
    formats:=CODEC_FORMATS
    switch data.decode(c.decoder,formats[codec],stored,dst) {
    case .None: return .None
    case .Unknown_Format: return .Missing
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Corrupt,.Too_Large,.Output_Too_Small: return .Corrupt
    }
    return .Corrupt
}

// The bytes of a frame of codec into all of dst, the chunk's size, as a peer's chunk is
// checked against its address: Missing for a codec this value does not decode, Corrupt for
// bytes that do not decode to it.
chunk_decode :: proc(s:^Store,codec:u8,stored,dst:[]u8) -> Error {
    if s==nil || s.state==nil || len(dst)==0 || len(dst)>CHUNK_MAX || len(stored)==0 {return .Invalid_Argument}
    if codec==CODEC_NONE {return frame_decode(s,nil,codec,stored,dst)}
    c:=coder_take(s) or_return
    defer coder_give(s,c)
    return frame_decode(s,c,codec,stored,dst)
}

// The bytes of a stored copy at location, decoded when its frame encodes them, into raw of at
// least its size. With the lock held.
@(private)
location_raw_locked :: proc(s:^Store,pack:int,location:Location,stored_buffer,raw:[]u8) -> (bytes:[]u8,error:Error) {
    stored:=location_bytes_locked(s,pack,location,stored_buffer) or_return
    if location.codec==CODEC_NONE {return stored,.None}
    if len(raw)<int(location.raw) {return nil,.Invalid_Argument}
    c:=coder_locked(s) or_return
    defer coder_give_locked(s,c)
    frame_decode(s,c,location.codec,stored,raw[:location.raw]) or_return
    return raw[:location.raw],.None
}

// Whether a stored copy holds the bytes of its address: decoded first when its frame encodes
// them; one of a codec this value does not decode is taken as it is. With the lock held.
@(private)
location_holds_locked :: proc(s:^Store,pack:int,location:Location,address:Hash,buffer:[]u8) -> (stored:[]u8,holds:bool,error:Error) {
    stored=location_bytes_locked(s,pack,location,buffer) or_return
    if location.codec==CODEC_NONE {return stored,address_of_bytes(stored)==address,.None}
    if !codec_readable(s,location.codec) {return stored,true,.None}
    raw,e:=make([]u8,location.raw,context.temp_allocator)
    if e!=nil {return nil,false,.Out_Of_Memory}
    defer delete(raw,context.temp_allocator)
    c:=coder_locked(s) or_return
    defer coder_give_locked(s,c)
    if frame_decode(s,c,location.codec,stored,raw)!=.None {return stored,false,.None}
    return stored,address_of_bytes(raw)==address,.None
}

@(private)
coder_locked :: proc(s:^Store) -> (^Coder,Error) {
    if n:=len(s.state.coders);n>0 {return pop(&s.state.coders),.None}
    return coder_new(s)
}

@(private)
coder_give_locked :: proc(s:^Store,c:^Coder) {
    if _,e:=append(&s.state.coders,c);e!=nil {coder_free(s,c)}
}
