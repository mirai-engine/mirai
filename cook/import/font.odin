package importer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Fonts: a TrueType or OpenType file (TrueType or CFF outlines) becomes a
// .font that keeps its bytes. A collection of fonts (TTC) and a web font
// (WOFF) are refused with what to do instead. The font is opened as the
// interfaces open it, so what is imported loads.

// Imports a font file as <name>.font, the root of its import.
import_font :: proc(path:string,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
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
    outlines,found:=asset.font_outlines(bytes)
    if !found {
        head:=string(bytes[:min(len(bytes),4)])
        switch head {
        case "ttcf":
            return {},error_make(.Unsupported,"%s is a collection of fonts (TTC) and a .font holds one: extract the one to use, as with `fonttools ttLib -y 0 %s -o font.ttf`, and import that file",path,path,allocator=caller)
        case "wOFF","wOF2":
            return {},error_make(.Unsupported,"%s is a web font (WOFF): convert it to a .ttf or .otf file and import that",path,allocator=caller)
        }
        return {},error_make(.Malformed,"%s is not a TrueType or OpenType font",path,allocator=caller)
    }
    probe:ui.Font
    if !ui.font_init(&probe,{bytes},{16},1,context.temp_allocator,on_demand=true) {
        return {},error_make(.Malformed,"%s does not open as a scalable font: its tables are damaged or it has no outlines",path,allocator=caller)
    }
    glyphs:=0
    for available in probe.metrics[0].available {glyphs+=int(available)}
    ui.font_destroy(&probe)

    report_init(&report,allocator)
    w:Writer
    ok:=writer_init(&w,path,"",options,&report,allocator)
    defer asset.types_destroy(&w.types)
    if ok {
        source:=w.source
        name:=filepath.stem(path)
        info:=import_info(source,name,0,u64(len(bytes)),base.hash64(bytes),0,import_version(0))
        desc:=asset.Font_Desc{file=bytes,source=&info,compression=.Stream}
        target:string
        desc.id,target=root_take(&w,asset.KIND_FONT,name,".font")
        existed:=os.exists(target)
        if save_error:=asset.font_save(target,&w.types,desc,context.temp_allocator);save_error!=.None {
            ok=save_failed(&w,save_error,target)
        } else {
            record(&w,desc.id,asset.KIND_FONT,name,target,source,existed,fmt.tprintf("%v outlines, %d glyphs of the atlas",outlines,glyphs))
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
