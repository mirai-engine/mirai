package mirai_audio

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strconv"
import "core:strings"
import vorbis "mirai:third_party/stb_vorbis"

// Ogg Vorbis through stb_vorbis, mono or stereo.
//
// What a Vorbis setup header expands to (codebooks, floors, residues and the
// tables of its transforms, about 150 KB) is the same for every file encoded
// with the same identification and setup headers, as an encoder writes for
// one mode, rate and channel count. The mixer keeps it once for all the
// sounds that share it (Vorbis_Setup), and the decoder of each voice holds
// only its own state of decoding (third_party/stb_vorbis/shared.c).

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

// The identification and setup headers of whole pages, the first and third
// packets, one after the other: files with the same bytes decode with the
// same setup. nil when the pages end before them.
@(private)
ogg_setup_header :: proc(pages:[]u8,allocator:runtime.Allocator) -> (header:[]u8,error:Error) {
    size,packet:=0,0
    // Measured first, then copied.
    for pass in 0..<2 {
        at,written:=0,0
        packet=0
        walk: for at+27<=len(pages) {
            page:=pages[at:]
            segments:=int(page[26])
            body:=27+segments
            for lacing in page[27:][:segments] {
                if packet!=1 {
                    if pass==1 {copy(header[written:],page[body:][:lacing])}
                    written+=int(lacing)
                }
                body+=int(lacing)
                if lacing<255 {
                    packet+=1
                    if packet==3 {break walk}
                }
            }
            at+=body
        }
        if packet<3 {return nil,.Invalid_Data}
        if pass==0 {
            size=written
            failed:runtime.Allocator_Error
            if header,failed=make([]u8,size,allocator);failed!=nil {return nil,.Out_Of_Memory}
        }
    }
    return header,.None
}

// A setup a sound decodes with, kept while some sound loaded has it.
@(private)
Vorbis_Setup :: struct {
    header:[]u8,            // the identification and setup packets it was read from
    memory:[]u8,            // of decoder
    decoder:^vorbis.Vorbis, // opened from the first sound with it, never decoded with
    shared_bytes:int,       // the workspace of a decoder that shares it
    sounds:int,             // loaded with it
}

@(private)
vorbis_open_into :: proc(file,memory:[]u8) -> (decoder:^vorbis.Vorbis,code:c.int) {
    block:=vorbis.Alloc{raw_data(memory),c.int(len(memory))}
    decoder=vorbis.open_memory(raw_data(file),c.int(len(file)),&code,&block)
    return
}

// Opens checked pages with a decoder that takes all its memory from one allocation.
// The decoder does not say how much it needs before it is open: the block
// starts at 256 KiB and grows while the decoder runs out of it.
@(private)
vorbis_open :: proc(file:[]u8,allocator:runtime.Allocator) -> (decoder:^vorbis.Vorbis,memory:[]u8,error:Error) {
    if len(file)==0 || len(file)>int(max(i32)) {return nil,nil,.Invalid_Data}
    size:=256*1024
    for _ in 0..<6 {
        failed:runtime.Allocator_Error
        if memory,failed=mem.alloc_bytes_non_zeroed(size,align_of(u64),allocator);failed!=nil {
            return nil,nil,.Out_Of_Memory
        }
        code:c.int
        decoder,code=vorbis_open_into(file,memory)
        if decoder!=nil {
            info:=vorbis.get_info(decoder)
            if info.channels>=1 && info.channels<=2 && info.sample_rate>0 {return decoder,memory,.None}
            vorbis.close(decoder)
            delete(memory,allocator)
            return nil,nil,.Invalid_Data
        }
        delete(memory,allocator)
        memory=nil
        if code==vorbis.ERROR_TOO_MANY_CHANNELS {return nil,nil,.Unsupported_Format}
        if code!=vorbis.ERROR_OUT_OF_MEMORY {return nil,nil,.Invalid_Data}
        size*=4
    }
    return nil,nil,.Out_Of_Memory
}

// The decoder of a sound of pages, which the sound owns: its place, and the
// setup of the mixer it shares, taken now if no sound has it yet (a
// transaction: nothing is kept on an error). The sound lets go of it with
// vorbis_setup_release.
@(private)
vorbis_source :: proc(m:^Mixer,pages:[]u8) -> (d:Decoder,setup:int,error:Error) {
    header:=ogg_setup_header(pages,m.allocator) or_return
    kept:=false
    defer if !kept {delete(header,m.allocator)}
    decoder,memory:=vorbis_open(pages,m.allocator) or_return
    defer if !kept {vorbis.close(decoder);delete(memory,m.allocator)}
    info:=vorbis.get_info(decoder)
    d={kind=.Vorbis,channels=int(info.channels),sample_rate=int(info.sample_rate),ogg=pages}
    vorbis.get_place(decoder,&d.place)
    d.frames=int(d.place.total_samples) if d.place.total_samples!=max(u32) else 0
    setup=-1
    free:=-1
    for &s,i in m.setups {
        if s.decoder==nil {
            if free<0 {free=i}
        } else if string(s.header)==string(header) {
            setup=i
        }
    }
    if setup<0 {
        if free<0 {return {},-1,.Capacity_Exhausted}
        // Opened again in the memory it said it takes, which is kept while the setup is.
        need:=int(info.setup_memory_required)+int(max(info.setup_temp_memory_required,info.temp_memory_required))+64
        if need<len(memory) {
            if exact,failed:=mem.alloc_bytes_non_zeroed(need,align_of(u64),m.allocator);failed==nil {
                if again,_:=vorbis_open_into(pages,exact);again!=nil {
                    vorbis.close(decoder)
                    delete(memory,m.allocator)
                    decoder,memory=again,exact
                } else {
                    delete(exact,m.allocator)
                }
            }
        }
        setup=free
        m.setups[setup]={header=header,memory=memory,decoder=decoder,shared_bytes=int(vorbis.shared_memory_required(decoder))}
        m.counters.sound_bytes+=len(header)+len(memory)
        kept=true
    }
    d.setup=m.setups[setup].decoder
    m.setups[setup].sounds+=1
    return d,setup,.None
}

// A sound let go of its setup; the last one frees it.
@(private)
vorbis_setup_release :: proc(m:^Mixer,setup:int) {
    s:=&m.setups[setup]
    s.sounds-=1
    if s.sounds>0 {return}
    m.counters.sound_bytes-=len(s.header)+len(s.memory)
    vorbis.close(s.decoder)
    delete(s.memory,m.allocator)
    delete(s.header,m.allocator)
    s^={}
}

vorbis_decode :: proc(file:[]u8,allocator:runtime.Allocator) -> (pcm:Pcm,error:Error) {
    decoder,memory:=vorbis_open(file[:ogg_whole_pages(file)],allocator) or_return
    defer {vorbis.close(decoder);delete(memory,allocator)}
    info:=vorbis.get_info(decoder)
    channels:=int(info.channels)
    frames:=int(vorbis.stream_length_in_samples(decoder))
    samples,failed:=make([]f32,frames*channels,allocator)
    if failed!=nil {return {},.Out_Of_Memory}
    decoded:=0
    for decoded<frames {
        got:=int(vorbis.get_samples_float_interleaved(decoder,c.int(channels),raw_data(samples[decoded*channels:]),c.int(min((frames-decoded)*channels,1<<20))))
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
