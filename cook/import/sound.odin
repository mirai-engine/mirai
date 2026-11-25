package importer

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import audio "mirai:audio"
import "mirai:std/base"
import "mirai:std/serial"

// Sounds: a WAV or an Ogg Vorbis file becomes a .sound, which the mixer keeps
// as it is stored and decodes a little ahead of what plays. Its 16 bit samples
// are coded without loss (audio.lossless_encode) at audio.MIXER_RATE
// (resample), so a voice at its own pitch copies them; or it keeps its file,
// at its own rate, which a voice resamples as it plays at no cost that shows.
// Sound_Coding.Smallest, the default of Import_Settings.sound, keeps the file
// of an Ogg Vorbis where it is the smaller, as it is for most sounds but the
// mostly silent; Lossless and File choose either. Where a loop of it goes back
// to is what its file says, the first loop of the smpl chunk of a WAV or the
// LOOPSTART comment of a Vorbis, in the frames of what it holds.

// What a .sound of the bytes of a WAV or Ogg Vorbis file holds, coded as
// coding says. lossless belongs to allocator; file is the bytes given.
sound_build :: proc(bytes:[]u8,coding:=Sound_Coding.Smallest,allocator:=context.allocator) -> (desc:asset.Sound_Desc,error:audio.Error) {
    bytes:=bytes
    ogg:=len(bytes)>=4 && string(bytes[:4])=="OggS"
    if ogg {
        // The file keeps only the pages the decoder will open: those that are whole and intact.
        bytes=bytes[:audio.ogg_whole_pages(bytes)]
        if len(bytes)==0 {return {},.Invalid_Data}
    }
    pcm:=audio.decode(bytes,allocator) or_return
    defer audio.pcm_destroy(&pcm,allocator)
    if len(pcm.samples)==0 {return {},.Invalid_Data}
    kept:=asset.Sound_Desc{channels=pcm.channels,sample_rate=pcm.sample_rate,frames=len(pcm.samples)/pcm.channels,loop_start=pcm.loop_start,file=bytes}
    if coding==.File {return kept,.None}
    values,loop_start:=pcm.samples,pcm.loop_start
    resampled:=pcm.sample_rate!=audio.MIXER_RATE
    if resampled {values,loop_start=resample(pcm.samples,pcm.channels,pcm.sample_rate,audio.MIXER_RATE,pcm.loop_start,allocator) or_return}
    defer if resampled {delete(values,allocator)}
    desc={channels=pcm.channels,sample_rate=audio.MIXER_RATE,frames=len(values)/pcm.channels,loop_start=loop_start}
    samples,failed:=make([]i16,len(values),allocator)
    if failed!=nil {return {},.Out_Of_Memory}
    defer delete(samples,allocator)
    for sample,i in values {samples[i]=audio.sample_pcm16(sample)}
    desc.lossless=audio.lossless_encode(samples,pcm.channels,audio.MIXER_RATE,allocator) or_return
    if coding==.Smallest && ogg && len(bytes)<len(desc.lossless) {
        delete(desc.lossless,allocator)
        return kept,.None
    }
    return desc,.None
}

// Imports a sound file as <name>.sound, coded as options.sound says unless
// the settings its package keeps say otherwise. The sound is the root of the
// import: importing the file again gives the asset its package lists
// (identity.odin).
import_sound :: proc(path:string,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    options:=options
    if !options.ignore_stored {
        stored,found,settings_error:=settings_load(options,path)
        if settings_error.code!=.None {return {},settings_error}
        if found {options.settings=stored}
    }
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)

    if unsafe_path(path) {return {},error_make(.Not_Found,"%s does not exist",path,allocator=caller)}
    bytes,read_error:=serial.file_read(path,context.temp_allocator,limit=MAX_SOURCE_BYTES)
    if read_error!=.None {
        return {},error_make(read_error==.Not_Found?Error_Code.Not_Found:Error_Code.Read,"%s could not be read: %v",path,read_error,allocator=caller)
    }
    desc,build_error:=sound_build(bytes,options.sound,context.temp_allocator)
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
    report.settings=options.settings
    w:Writer
    ok:=writer_init(&w,path,"",options,&report,allocator)
    defer writer_close(&w)
    if ok {
        source:=w.source
        name:=filepath.stem(path)
        info:=import_info(source,name,0,u64(len(bytes)),base.hash64(bytes),u64(options.sound),import_version(0))
        target:string
        output:int
        desc.id,target,output=root_take(&w,asset.KIND_SOUND,name,".sound")
        desc.source=&info
        if save_error:=asset.sound_save(target,&w.types,desc,context.temp_allocator);save_error!=.None {
            ok=save_failed(&w,save_error,target)
        } else if ok=writer_put(&w,output,target);ok {
            record(&w,output,name)
            ok=writer_finish(&w,name,"sound")
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
