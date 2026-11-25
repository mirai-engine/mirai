package mirai_audio

import "core:c"
import vorbis "mirai:third_party/stb_vorbis"

// How a voice decodes a sound kept as it came (sound_load): a WAV, an Ogg
// Vorbis or a lossless file, a little at a time into its feed (feed.odin). A
// sound holds one, at its start; each voice copies it into its feed.

@(private)
Decoder_Kind :: enum u8 {None,Wav,Vorbis,Lossless}
@(private)
Decoder :: struct {
    kind:Decoder_Kind,
    channels,sample_rate:int,
    frames:int,
    cursor:int,
    wav:Wav,
    lossless:Lossless,
    ogg:[]u8,              // complete, checked pages
    place:vorbis.Place,    // where the audio of ogg begins and ends
    setup:^vorbis.Vorbis,  // the decoder whose setup it shares (Vorbis_Setup)
    vorbis:^vorbis.Vorbis, // of a feed: its state of decoding, in memory
    memory:[]u8,           // the workspace of the feed when it was handed over
}

// Opens the decoder of a feed in its workspace; false when it cannot, as a
// workspace smaller than the setup asks or a file whose first page does not decode.
@(private)
decoder_start :: proc(d:^Decoder) -> bool {
    if d.kind!=.Vorbis {return true}
    alloc:=vorbis.Alloc{raw_data(d.memory),c.int(len(d.memory))}
    failed:c.int
    d.vorbis=vorbis.open_shared(d.setup,raw_data(d.ogg),c.int(len(d.ogg)),&d.place,&alloc,&failed)
    return d.vorbis!=nil
}
// Decodes up to len(out)/channels frames of a WAV or a Vorbis file and
// returns how many; fewer means the end.
@(private)
decoder_read :: proc(d:^Decoder,out:[]f32) -> int {
    count:=0
    #partial switch d.kind {
    case .Wav:count=wav_convert(&d.wav,d.cursor,out)
    case .Vorbis:
        wanted:=len(out)/d.channels
        for count<wanted {
            got:=int(vorbis.get_samples_float_interleaved(d.vorbis,c.int(d.channels),raw_data(out[count*d.channels:]),c.int((wanted-count)*d.channels)))
            if got<=0 {break}
            count+=got
        }
    }
    d.cursor+=count
    return count
}
// The next frame the decoder gives is frame; past the end, nothing is left.
@(private)
decoder_seek :: proc(d:^Decoder,frame:int) {
    frame:=max(frame,0)
    switch d.kind {
    case .None,.Lossless:
    case .Wav:frame=min(frame,d.wav.frames)
    case .Vorbis:
        if frame==0 || vorbis.seek(d.vorbis,c.uint(min(frame,int(max(u32)))))==0 {
            vorbis.seek_start(d.vorbis)
            frame=0
        }
    }
    d.cursor=frame
}

// The 16 bits a voice plays an f32 sample at: rounded to the nearest step,
// half away from zero, and held to full scale.
sample_pcm16 :: #force_inline proc "contextless" (sample:f32) -> i16 {
    scaled:=clamp(sample,-1,1)*32768
    return i16(clamp(scaled+(scaled<0?-0.5:0.5),-32768,32767))
}
