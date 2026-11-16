package mirai_render

import "core:crypto/sha2"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:rhi"

// Comparison of every image the tests read back, between two builds on one
// machine. MIRAI_GOLDEN=write:<dir> stores each readback under its call site
// and the hash of its bytes; MIRAI_GOLDEN=compare:<dir> fails the test whose
// readback is not among the stored ones nor within GOLDEN_MEAN_LIMIT of one of
// them. Without the variable the readbacks pass through untouched.

// The mean difference of the values of an image over their mean that still
// passes: two runs of one build differ by up to 2.7 % (the light under the
// glass of glass_tints_the_indirect_light_with_its_mean, of eight runs) and
// 0.22 % (a_relative_emission_lights_nothing); the others repeat byte by byte.
GOLDEN_MEAN_LIMIT :: 0.04
@(private)
golden_capture :: proc(r:^Renderer,allocator:=context.allocator,loc:=#caller_location) -> (pixels:[]u8,width,height:int,ok:bool) {
    pixels,width,height,ok=renderer_capture(r,allocator)
    if ok {golden_check(pixels,.RGBA8_Unorm,loc)}
    return
}

@(private)
golden_read_texture :: proc(d:^rhi.Device,texture:rhi.Texture,out:[]u8,loc:=#caller_location) -> bool {
    if !rhi.texture_read(d,texture,out) {return false}
    desc:=rhi.texture_desc(d,texture)
    size:=int(desc.width)*int(desc.height)*rhi.format_size(desc.format)
    golden_check(out[:min(size,len(out))],desc.format,loc)
    return true
}

@(private)
golden_check :: proc(bytes:[]u8,format:rhi.Format,loc:=#caller_location) {
    setting,found:=os.lookup_env("MIRAI_GOLDEN",context.temp_allocator)
    if !found {return}
    write:=strings.has_prefix(setting,"write:")
    if !write && !strings.has_prefix(setting,"compare:") {log.errorf("MIRAI_GOLDEN is write:<dir> or compare:<dir>, not %s",setting);return}
    directory:=setting[strings.index_byte(setting,':')+1:]
    hash:sha2.Context_256
    sha2.init_256(&hash)
    sha2.update(&hash,bytes)
    digest:[32]u8
    sha2.final(&hash,digest[:])
    builder:=strings.builder_make(context.temp_allocator)
    for b in digest[:12] {fmt.sbprintf(&builder,"%02x",b)}
    suffix:=fmt.tprintf(".%s.bin",strings.to_string(builder))
    prefix:=fmt.tprintf("%s.",loc.procedure)
    path:=fmt.tprintf("%s/%s%d%s",directory,prefix,loc.line,suffix)
    if write {
        os.make_directory_all(directory)
        if os.write_entire_file(path,bytes)!=nil {log.errorf("golden: cannot write %s",path)}
        return
    }
    if os.exists(path) {return}
    entries,_:=os.read_all_directory_by_path(directory,context.temp_allocator)
    // The call site may have moved to another line since the images were stored.
    for entry in entries {if strings.has_prefix(entry.name,prefix) && strings.has_suffix(entry.name,suffix) {return}}
    closest,candidates:=max(f64),0
    for entry in entries {
        if !strings.has_prefix(entry.name,prefix) {continue}
        stored,read_error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if read_error!=nil || len(stored)!=len(bytes) {continue}
        candidates+=1
        closest=min(closest,golden_difference(stored,bytes,format))
    }
    if candidates==0 {
        // A call site added after the images were stored has nothing to compare with.
        log.warnf("golden: no stored image of %d bytes for %s",len(bytes),loc.procedure,location=loc)
    } else if closest>GOLDEN_MEAN_LIMIT {
        log.errorf("golden: the image differs from the %d stored for %s: by %.2f %% of its mean from the closest, more than %.0f %%",candidates,loc.procedure,closest*100,GOLDEN_MEAN_LIMIT*100,location=loc)
    }
}

// The mean difference of the values of two images over the mean of the stored
// one; of a format it does not read value by value, 0 for the same bytes and
// infinity for others.
@(private="file")
golden_difference :: proc(stored,bytes:[]u8,format:rhi.Format) -> f64 {
    difference,total:f64
    #partial switch format {
    case .R8_Unorm,.RG8_Unorm,.RGBA8_Unorm,.RGBA8_Srgb,.BGRA8_Unorm,.BGRA8_Srgb:
        for value,i in stored {difference+=abs(f64(value)-f64(bytes[i]));total+=f64(value)}
    case .R16_Float,.RG16_Float,.RGBA16_Float:
        a,b:=mem.slice_data_cast([]f16,stored),mem.slice_data_cast([]f16,bytes)
        for value,i in a {difference+=abs(f64(value)-f64(b[i]));total+=abs(f64(value))}
    case .R32_Float,.RG32_Float,.RGBA32_Float,.D32_Float:
        a,b:=mem.slice_data_cast([]f32,stored),mem.slice_data_cast([]f32,bytes)
        for value,i in a {difference+=abs(f64(value)-f64(b[i]));total+=abs(f64(value))}
    case:
        return 0 if string(stored)==string(bytes) else max(f64)
    }
    if difference!=difference {return max(f64)}
    return difference/max(total,1e-12)
}
