package store

import "base:runtime"
import "core:sync"
import "mirai:std/compressor/data"

// Persistent frame codec ids. Retired ids stay unassigned.
CODEC_NONE :: 0
CODEC_MDC2 :: 5

@(private)
Coder :: struct {
    encoder:data.Encoder,
    decoder:data.Decoder,
    scratch:[]u8, // data.bound(CHUNK_MAX): an encoded frame, or one read to decode
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
    if data.encoder_init(&c.encoder,allocator)!=.None {return c,.Out_Of_Memory}
    if data.decoder_init(&c.decoder,allocator)!=.None {return c,.Out_Of_Memory}
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
    data.encoder_destroy(&c.encoder)
    data.decoder_destroy(&c.decoder)
    delete(c.scratch,allocator)
    free(c,allocator)
}

// Encodes a chunk when that shrinks it. Nodes stay as they are.
@(private)
frame_encode :: proc(c:^Coder,bytes:[]u8) -> (codec:u8,stored:[]u8) {
    if len(bytes)<2 {return CODEC_NONE,bytes}
    if _,e:=node_parse(bytes);e==.None {return CODEC_NONE,bytes}
    size,error:=data.encode(&c.encoder,.Fast,bytes,c.scratch)
    if error!=.None || size<=0 || size>=len(bytes) {return CODEC_NONE,bytes}
    return CODEC_MDC2,c.scratch[:size]
}

@(private)
frame_decode :: proc(c:^Coder,codec:u8,stored,dst:[]u8) -> Error {
    if codec==CODEC_NONE {
        if len(stored)!=len(dst) {return .Corrupt}
        copy(dst,stored)
        return .None
    }
    if codec!=CODEC_MDC2 {return .Corrupt}
    switch data.decode(&c.decoder,data.MDC2,stored,dst) {
    case .None: return .None
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Unknown_Format,.Corrupt,.Too_Large,.Output_Too_Small: return .Corrupt
    }
    return .Corrupt
}

// Decodes a frame into all of dst, the chunk's size.
chunk_decode :: proc(s:^Store,codec:u8,stored,dst:[]u8) -> Error {
    if s==nil || s.state==nil || len(dst)==0 || len(dst)>CHUNK_MAX || len(stored)==0 {return .Invalid_Argument}
    if codec==CODEC_NONE {return frame_decode(nil,codec,stored,dst)}
    if codec!=CODEC_MDC2 {return .Corrupt}
    c:=coder_take(s) or_return
    defer coder_give(s,c)
    return frame_decode(c,codec,stored,dst)
}

// Whether a stored copy holds the bytes of its address: decoded first when its frame encodes
// them. With the lock held.
@(private)
location_holds_locked :: proc(s:^Store,pack:int,location:Location,address:Hash,buffer:[]u8) -> (stored:[]u8,holds:bool,error:Error) {
    stored=location_bytes_locked(s,pack,location,buffer) or_return
    if location.codec==CODEC_NONE {return stored,address_of_bytes(stored)==address,.None}
    raw,e:=make([]u8,location.raw,context.temp_allocator)
    if e!=nil {return nil,false,.Out_Of_Memory}
    defer delete(raw,context.temp_allocator)
    c:=coder_locked(s) or_return
    defer coder_give_locked(s,c)
    if frame_decode(c,location.codec,stored,raw)!=.None {return stored,false,.None}
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
