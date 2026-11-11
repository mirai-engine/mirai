package shaders

import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:std/jobs"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"
import lz_optimal "mirai:cook/compressor/lz"

// The code the executables embed: that of the stages of the engine and then of
// its program stages, in the order of the Odin table of render, as one LZ
// stream per backend that render decodes once when it starts. A generation
// packs it as an edit; one asked to ship (Options.ship, the release builds of
// the engine) packs it as lz_optimal.SHIP, which takes far longer and leaves a
// smaller executable. Each stream stays in the shared cache under the hashes
// of the code it holds, and a generation takes the shipped one whenever the
// cache has it.
EMBEDDED_NAMES :: [Backend]string{.Vulkan="shaders.spv.lz",.Metal="shaders.metal.lz"}
@(private)
CACHE_EMBEDDED :: "embedded"

// The stream of one backend for the code of the staged stages of groups, one
// group after the other: from the shared cache when it holds it, else packed
// now. sizes: of the code of each stage. shipped: it is the one a generation
// asked to ship wants.
@(private)
embedded_pack :: proc(g:^Generation,groups:[2][]Job,backend:Backend,ship:bool,allocator:=context.allocator) -> (packed:[]u8,sizes:[]int,shipped:bool,problem:string) {
    hash:Sha256
    sha_begin(&hash)
    sha_text(&hash,GENERATOR_CONTRACT)
    sha_text(&hash,"\n")
    raw:=make([dynamic]u8)
    defer delete(raw)
    sizes=make([]int,len(groups[0])+len(groups[1]),allocator)
    at:=0
    for jobs in groups do for job in jobs {
        name,code_hash:=job.result.spv,job.result.spv_hash
        if backend==.Metal {name,code_hash=job.result.msl,job.result.msl_hash}
        data,err:=os.read_entire_file(path_join(job.staging,name,allocator=context.temp_allocator),context.allocator)
        if err!=nil {return nil,nil,false,strings.concatenate({"could not read ",name," to embed it"},allocator)}
        append(&raw,..data)
        sizes[at]=len(data)
        at+=1
        delete(data)
        sha_text(&hash,code_hash)
        sha_text(&hash,"\n")
    }
    if len(raw)==0 {return nil,sizes,ship,""}
    digest:=sha_hex(&hash,context.temp_allocator)
    folder:=path_join(g.shared,CACHE_EMBEDDED,allocator=context.temp_allocator)
    names:=EMBEDDED_NAMES
    // <digest>.edit.spv.lz, <digest>.ship.spv.lz
    entries:[2]string
    for &entry,shipped in entries {
        level:="ship" if shipped==1 else "edit"
        entry=path_join(folder,strings.concatenate({digest,".",level,strings.trim_prefix(names[backend],"shaders")},context.temp_allocator),allocator=context.temp_allocator)
    }
    decoder:compressor.Decoder
    if compressor.decoder_init(&decoder)!=.None {return nil,nil,false,strings.clone("out of memory to embed the shaders",allocator)}
    defer compressor.decoder_destroy(&decoder)
    check:=make([]u8,len(raw))
    defer delete(check)
    // An entry is taken only when it decodes to this code.
    for shipped in ([2]int{1,0}) {
        if shipped==0 && ship {break}
        stored,err:=os.read_entire_file(entries[shipped],allocator)
        if err!=nil {continue}
        if asset.unpack(&decoder,stored,check)==.None && string(check)==string(raw[:]) {
            cache_touch(entries[shipped])
            return stored,sizes,shipped==1,""
        }
        delete(stored,allocator)
    }
    encoder:lz.Encoder
    lz.encoder_init(&encoder)
    defer lz.encoder_destroy(&encoder)
    pack:=lz_optimal.SHIP if ship else asset.PACK_EDIT
    packed=make([]u8,asset.pack_bound(len(raw)),allocator)
    // Its pieces compress at once on a job system of its own.
    js:jobs.Job_System
    on:jobs.Worker_Ref
    if len(raw)>asset.PACK_PIECE && jobs.system_init(&js,{threads=jobs.THREADS_AUTO}) {on={&js,jobs.OWNER,nil}}
    defer if on.system!=nil {jobs.system_destroy(&js)}
    written,pack_error:=asset.pack(&encoder,pack,raw[:],packed,on)
    if pack_error!=.None {
        delete(packed,allocator)
        return nil,nil,false,strings.clone("could not compress the shaders to embed",allocator)
    }
    packed=packed[:written]
    // A failure to store only costs packing it again.
    write_file_atomic(entries[int(ship)],packed)
    return packed,sizes,ship,""
}
