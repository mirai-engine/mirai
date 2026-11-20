package mirai_audio

import "base:runtime"
import "core:mem"
import "vendor:stb/vorbis"

// Decoders of WAV, Ogg Vorbis and lossless files that read a little at a
// time, and streamed sounds, which decode while they play (feed.odin).

@(private)
Decoder_Kind :: enum u8 {None,Wav,Vorbis,Lossless}
@(private)
Decoder :: struct {
    kind:Decoder_Kind,
    channels,sample_rate:int,
    frames:int, // total; 0 when the file does not say
    cursor:int,
    wav:Wav,
    ogg:[]u8,   // complete, checked pages
    vorbis:^vorbis.vorbis,
    lossless:Lossless,
    held:int,    // the lossless block decoded in memory; -1 when none
    memory:[]u8, // workspace borrowed from the stream feed
    planes:[]i32, // a decoded lossless block, channel after channel
}
@(private)
stream_source :: proc(file:[]u8,allocator:runtime.Allocator) -> (d:Decoder,bytes:int,error:Error) {
    if len(file)>=12 && string(file[:4])=="RIFF" && string(file[8:12])=="WAVE" {
        d.wav=wav_parse(file) or_return
        d.kind=.Wav
        d.channels=d.wav.channels;d.sample_rate=d.wav.sample_rate;d.frames=d.wav.frames
        return d,0,.None
    }
    if len(file)>=4 && string(file[:4])=="OggS" {
        d.ogg=file[:ogg_whole_pages(file)]
        vorbis_decoder,memory:=vorbis_open(d.ogg,allocator) or_return
        defer {vorbis.close(vorbis_decoder);delete(memory,allocator)}
        info:=vorbis.get_info(vorbis_decoder)
        d.kind=.Vorbis
        d.channels=int(info.channels);d.sample_rate=int(info.sample_rate)
        d.frames=int(vorbis.stream_length_in_samples(vorbis_decoder))
        return d,len(memory),.None
    }
    if len(file)>=4 && string(file[:4])==LOSSLESS_MAGIC {
        d.lossless=lossless_parse(file) or_return
        d.kind=.Lossless
        d.channels=d.lossless.channels;d.sample_rate=d.lossless.sample_rate;d.frames=d.lossless.frames
        d.held=-1
        return d,d.lossless.block_frames*d.channels*size_of(i32),.None
    }
    return {},0,.Invalid_Data
}
@(private)
stream_decoder_start :: proc(d:^Decoder,workspace:[]u8) -> bool {
    #partial switch d.kind {
    case .Vorbis:
        d.vorbis,_=vorbis_open_into(d.ogg,workspace)
        if d.vorbis==nil {return false}
        d.memory=workspace
    case .Lossless:
        d.planes=(cast([^]i32)raw_data(workspace))[:d.lossless.block_frames*d.channels]
        d.memory=workspace
    }
    return true
}
// Decodes up to len(out)/channels frames and returns how many; fewer means the end.
@(private)
decoder_read :: proc(d:^Decoder,out:[]f32) -> int {
    count:=0
    switch d.kind {
    case .None:
    case .Wav:count=wav_convert(&d.wav,d.cursor,out)
    case .Vorbis:
        wanted:=len(out)/d.channels
        for count<wanted {
            got:=int(vorbis.get_samples_float_interleaved(d.vorbis,i32(d.channels),raw_data(out[count*d.channels:]),i32((wanted-count)*d.channels)))
            if got<=0 {break}
            count+=got
        }
    case .Lossless:
        l:=&d.lossless
        wanted:=min(len(out)/d.channels,l.frames-d.cursor)
        for count<wanted {
            at:=d.cursor+count
            block:=at/l.block_frames
            if block!=d.held {
                // A damaged block plays as silence.
                lossless_block(l,block,d.planes)
                d.held=block
            }
            frames:=min(l.block_frames,l.frames-block*l.block_frames)
            first:=at-block*l.block_frames
            run:=min(wanted-count,frames-first)
            lossless_convert(d.planes,l.block_frames,d.channels,first,run,out[count*d.channels:])
            count+=run
        }
    }
    d.cursor+=count
    return count
}
// The next frame decoder_read gives is frame; past the end, nothing is left.
@(private)
decoder_seek :: proc(d:^Decoder,frame:int) {
    frame:=max(frame,0)
    switch d.kind {
    case .None,.Lossless:
    case .Wav:frame=min(frame,d.wav.frames)
    case .Vorbis:
        if frame==0 || vorbis.seek(d.vorbis,u32(min(frame,int(max(u32)))))==0 {
            vorbis.seek_start(d.vorbis)
            frame=0
        }
    }
    d.cursor=frame
}

// A sound that is decoded while it plays, for music and long ambiences. The
// file is borrowed and immutable until the sound is destroyed
// and a later mixer_update has freed it. Each voice takes its own decoder.
sound_stream :: proc(m:^Mixer,file:[]u8) -> (sound:Sound,error:Error) {
    index:=sound_slot_take(m) or_return
    source,bytes:=stream_source(file,m.allocator) or_return
    for &f in m.feeds[m.pool_feeds:] {
        if len(f.workspace)>=bytes {continue}
        workspace,failed:=mem.alloc_bytes_non_zeroed(bytes,align_of(u64),m.allocator)
        if failed!=nil {return 0,.Out_Of_Memory}
        // An active decoder keeps its old workspace until it is done.
        if raw_data(f.workspace)!=raw_data(f.decoder.memory) {delete(f.workspace,m.allocator)}
        f.workspace=workspace
    }
    frames:=u32(min(source.frames,int(max(u32))))
    return sound_slot_fill(m,index,{
        source=source,frames=frames,channels=u32(source.channels),rate=u32(source.sample_rate),
        stream=true,
    }),.None
}

@(private)
stream_decoder_close :: proc(m:^Mixer,f:^Feed) {
    d:=&f.decoder
    if d.vorbis!=nil {vorbis.close(d.vorbis)}
    m.counters.sound_bytes-=len(d.memory)
    if raw_data(d.memory)!=raw_data(f.workspace) {delete(d.memory,m.allocator)}
    d^={}
}
