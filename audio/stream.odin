package mirai_audio

import "base:runtime"
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
    vorbis:^vorbis.vorbis,
    lossless:Lossless,
    held:int,    // the lossless block decoded in memory; -1 when none
    memory:[]u8, // everything the Vorbis decoder allocates
    planes:[]i32, // a decoded lossless block, channel after channel
}
@(private)
decoder_open :: proc(file:[]u8,allocator:runtime.Allocator) -> (d:Decoder,error:Error) {
    if len(file)>=12 && string(file[:4])=="RIFF" && string(file[8:12])=="WAVE" {
        d.wav=wav_parse(file) or_return
        d.kind=.Wav
        d.channels=d.wav.channels;d.sample_rate=d.wav.sample_rate;d.frames=d.wav.frames
        return d,.None
    }
    if len(file)>=4 && string(file[:4])=="OggS" {
        d.vorbis,d.memory=vorbis_open(file,allocator) or_return
        info:=vorbis.get_info(d.vorbis)
        d.kind=.Vorbis
        d.channels=int(info.channels);d.sample_rate=int(info.sample_rate)
        d.frames=int(vorbis.stream_length_in_samples(d.vorbis))
        return d,.None
    }
    if len(file)>=4 && string(file[:4])==LOSSLESS_MAGIC {
        d.lossless=lossless_parse(file) or_return
        failed:runtime.Allocator_Error
        if d.planes,failed=make([]i32,d.lossless.block_frames*d.lossless.channels,allocator);failed!=nil {return {},.Out_Of_Memory}
        d.kind=.Lossless
        d.channels=d.lossless.channels;d.sample_rate=d.lossless.sample_rate;d.frames=d.lossless.frames
        d.held=-1
        return d,.None
    }
    return {},.Invalid_Data
}
@(private)
decoder_close :: proc(d:^Decoder,allocator:runtime.Allocator) {
    if d.vorbis!=nil {vorbis.close(d.vorbis)}
    delete(d.memory,allocator)
    delete(d.planes,allocator)
    d^={}
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
// file is not copied: it must stay in memory until the sound is destroyed
// and a later mixer_update has freed it. One voice at a time can play it.
sound_stream :: proc(m:^Mixer,file:[]u8) -> (sound:Sound,error:Error) {
    index:=sound_slot_take(m) or_return
    feed:=-1
    for &candidate,i in m.feeds[m.pool_feeds:] {
        if !candidate.used {feed=m.pool_feeds+i;break}
    }
    if feed<0 {return 0,.Capacity_Exhausted}
    f:=&m.feeds[feed]
    f.decoder=decoder_open(file,m.allocator) or_return
    f.used=true;f.sound=u32(index)
    d:=&f.decoder
    return sound_slot_fill(m,index,{frames=u32(min(d.frames,int(max(u32)))),channels=u32(d.channels),rate=u32(d.sample_rate),feed=i32(feed)}),.None
}
// No voice plays it and the decoder no longer looks at it.
@(private)
stream_close :: proc(m:^Mixer,f:^Feed) {
    decoder_close(&f.decoder,m.allocator)
    f.used=false
}
