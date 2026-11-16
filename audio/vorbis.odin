package mirai_audio

import "base:runtime"
import "core:strconv"
import "core:strings"
import "vendor:stb/vorbis"

// Ogg Vorbis through stb_vorbis, mono or stereo.

// The pages of an Ogg stream that are whole and carry the checksum they
// state, from the first one: how many bytes they take. stb_vorbis reads what
// a page says without checking it, and a damaged page makes it read outside
// its memory; the checksum of every page is what tells. A file cut inside a
// page counts up to the page before. Every decoder of this package opens
// only those bytes.
ogg_whole_pages :: proc "contextless" (bytes:[]u8) -> (size:int) {
    table:[256]u32
    for &entry,at in table {
        entry=u32(at)<<24
        for _ in 0..<8 {entry=entry&0x80000000!=0?entry<<1~0x04c11db7:entry<<1}
    }
    for {
        page:=bytes[size:]
        if len(page)<27 || string(page[:4])!="OggS" || page[4]!=0 {return}
        segments:=int(page[26])
        if len(page)<27+segments {return}
        length:=27+segments
        for lacing in page[27:][:segments] {length+=int(lacing)}
        if len(page)<length {return}
        crc:u32
        for value,at in page[:length] {
            // The checksum is taken with its own four bytes as zero.
            crc=crc<<8~table[u8(crc>>24)~(at>=22 && at<26?0:value)]
        }
        if crc!=u32(page[22])|u32(page[23])<<8|u32(page[24])<<16|u32(page[25])<<24 {return}
        size+=length
    }
}

// Opens a decoder that takes all its memory from one block of the allocator.
// The decoder does not say how much it needs before it is open: the block
// starts at 256 KiB and grows while the decoder runs out of it.
@(private)
vorbis_open :: proc(file:[]u8,allocator:runtime.Allocator) -> (decoder:^vorbis.vorbis,memory:[]u8,error:Error) {
    file:=file[:ogg_whole_pages(file)]
    if len(file)==0 || len(file)>int(max(i32)) {return nil,nil,.Invalid_Data}
    size:=256*1024
    for _ in 0..<6 {
        failed:runtime.Allocator_Error
        if memory,failed=make([]u8,size,allocator);failed!=nil {return nil,nil,.Out_Of_Memory}
        block:=vorbis.vorbis_alloc{raw_data(memory),i32(len(memory))}
        code:vorbis.Error
        decoder=vorbis.open_memory(raw_data(file),i32(len(file)),&code,&block)
        if decoder!=nil {
            info:=vorbis.get_info(decoder)
            if info.channels>=1 && info.channels<=2 && info.sample_rate>0 {return decoder,memory,.None}
            vorbis.close(decoder)
            delete(memory,allocator)
            return nil,nil,.Unsupported_Format if info.channels>2 else .Invalid_Data
        }
        delete(memory,allocator)
        memory=nil
        if code!=.outofmem {return nil,nil,.Invalid_Data}
        size*=4
    }
    return nil,nil,.Out_Of_Memory
}

vorbis_decode :: proc(file:[]u8,allocator:runtime.Allocator) -> (pcm:Pcm,error:Error) {
    decoder,memory:=vorbis_open(file,allocator) or_return
    defer {vorbis.close(decoder);delete(memory,allocator)}
    info:=vorbis.get_info(decoder)
    channels:=int(info.channels)
    frames:=int(vorbis.stream_length_in_samples(decoder))
    samples,failed:=make([]f32,frames*channels,allocator)
    if failed!=nil {return {},.Out_Of_Memory}
    decoded:=0
    for decoded<frames {
        got:=int(vorbis.get_samples_float_interleaved(decoder,i32(channels),raw_data(samples[decoded*channels:]),i32(min((frames-decoded)*channels,1<<20))))
        if got<=0 {break}
        decoded+=got
    }
    // The comment LOOPSTART names the frame a loop goes back to.
    loop_start:=0
    comments:=vorbis.get_comment(decoder)
    for comment in comments.comment_list[:max(comments.comment_list_length,0)] {
        text:=string(comment)
        if len(text)>10 && strings.equal_fold(text[:10],"LOOPSTART=") {
            if frame,ok:=strconv.parse_int(text[10:],10);ok && frame>0 && frame<decoded {loop_start=frame}
        }
    }
    // A file cut short holds fewer frames than its last page claims.
    return {samples[:decoded*channels],channels,int(info.sample_rate),loop_start},.None
}
