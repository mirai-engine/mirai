package importer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import audio "mirai:audio"
import "mirai:std/base"
import "mirai:std/serial"

// Sounds: a WAV or an Ogg Vorbis file becomes a .sound. Its 16 bit samples
// are coded without loss (audio.lossless_encode) and decoded whole when it
// loads; one of SOUND_STREAM_SECONDS or more is streamed instead, so that it
// never sits decoded in memory. A long Ogg Vorbis keeps its file, which is
// smaller than its samples coded, and so does a long WAV with samples that
// 16 bits would round. Every sound is brought to audio.MIXER_RATE (resample),
// so a voice at its own pitch copies it; a stream keeps its file only when it
// already is at that rate. Where a loop of it goes back to is what its file
// says, the first loop of the smpl chunk of a WAV or the LOOPSTART comment of
// a Vorbis, moved with the rate.

SOUND_STREAM_SECONDS :: f32(10)

Sound_Storage :: enum u8 {
    Auto,    // by its length
    Decoded,
    Stream,
}
Sound_Options :: struct {
    storage:Sound_Storage,
    stream_seconds:f32, // 0: SOUND_STREAM_SECONDS
}

// What a .sound of the bytes of a WAV or Ogg Vorbis file holds. lossless
// belongs to allocator; file is the bytes given.
sound_build :: proc(bytes:[]u8,options:Sound_Options={},allocator:=context.allocator) -> (desc:asset.Sound_Desc,error:audio.Error) {
    bytes:=bytes
    ogg:=len(bytes)>=4 && string(bytes[:4])=="OggS"
    if ogg {
        // A stream keeps only the pages the decoder will open: those that are whole and intact.
        bytes=bytes[:audio.ogg_whole_pages(bytes)]
        if len(bytes)==0 {return {},.Invalid_Data}
    }
    pcm:=audio.decode(bytes,allocator) or_return
    defer audio.pcm_destroy(&pcm,allocator)
    if len(pcm.samples)==0 {return {},.Invalid_Data}
    resampled:=pcm.sample_rate!=audio.MIXER_RATE
    values,loop_start:=pcm.samples,pcm.loop_start
    if resampled {values,loop_start=resample(pcm.samples,pcm.channels,pcm.sample_rate,audio.MIXER_RATE,pcm.loop_start,allocator) or_return}
    defer if resampled {delete(values,allocator)}
    frames:=len(values)/pcm.channels
    limit:=options.stream_seconds>0?options.stream_seconds:SOUND_STREAM_SECONDS
    stream:=options.storage==.Stream || options.storage==.Auto && f32(frames)/f32(audio.MIXER_RATE)>=limit
    desc={channels=pcm.channels,sample_rate=audio.MIXER_RATE,frames=frames,loop_start=loop_start}
    if stream {desc.flags={.Stream}}
    samples,failed:=make([]i16,len(values),allocator)
    if failed!=nil {return {},.Out_Of_Memory}
    defer delete(samples,allocator)
    exact:=true
    for sample,i in values {
        scaled:=clamp(sample,-1,1)*32768
        samples[i]=i16(clamp(scaled+(scaled<0?-0.5:0.5),-32768,32767))
        if f32(samples[i])*(1.0/32768)!=sample {exact=false}
    }
    // A stream at the rate of the mixer plays its file as it is: coded, it has to be the same samples.
    if stream && !resampled && (ogg || !exact) {
        desc.file=bytes
        return desc,.None
    }
    desc.lossless=audio.lossless_encode(samples,pcm.channels,audio.MIXER_RATE,allocator) or_return
    return desc,.None
}

// Imports a sound file as <name>.sound. The sound is the root of the import:
// importing the file again writes the asset its sidecar lists (identity.odin).
import_sound :: proc(path:string,sound:Sound_Options={},options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)

    if unsafe_path(path) {return {},error_make(.Not_Found,"%s does not exist",path,allocator=caller)}
    bytes,read_error:=serial.file_read(path,context.temp_allocator,limit=MAX_SOURCE_BYTES)
    if read_error!=.None {
        return {},error_make(read_error==.Not_Found?Error_Code.Not_Found:Error_Code.Read,"%s could not be read: %v",path,read_error,allocator=caller)
    }
    desc,build_error:=sound_build(bytes,sound,context.temp_allocator)
    #partial switch build_error {
    case .None:
    case .Unsupported_Format:
        return {},error_make(.Unsupported,"%s has a sample format or a number of channels that is not played",path,allocator=caller)
    case .Out_Of_Memory:
        return {},error_make(.Limit,"%s does not fit in memory decoded",path,allocator=caller)
    case:
        return {},error_make(.Malformed,"%s is not a WAV or an Ogg Vorbis file that can be decoded",path,allocator=caller)
    }
    report_init(&report,allocator)
    w:Writer
    ok:=writer_init(&w,path,"",options,&report,allocator)
    defer asset.types_destroy(&w.types)
    if ok {
        source:=w.source
        name:=filepath.stem(path)
        info:=import_info(source,name,0,u64(len(bytes)),base.hash64(bytes),u64(.Stream in desc.flags),import_version(0))
        target:string
        desc.id,target=root_take(&w,asset.KIND_SOUND,name,".sound")
        desc.source=&info
        existed:=os.exists(target)
        if save_error:=asset.sound_save(target,&w.types,desc,context.temp_allocator);save_error!=.None {
            ok=save_failed(&w,save_error,target)
        } else {
            record(&w,desc.id,asset.KIND_SOUND,name,target,source,existed)
            ok=writer_finish(&w)
        }
    }
    if !ok {
        writer_rollback(&w)
        error=writer_error(&w,caller)
        report_destroy(&report)
        return {},error
    }
    return report,{}
}
