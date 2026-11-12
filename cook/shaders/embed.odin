package shaders

import "core:encoding/endian"
import "core:os"
import "core:strings"
import "compressor:data"
import "mirai:asset"
import "mirai:std/jobs"

// The code the executables embed: that of the stages of the engine and then of
// its program stages, in the order of the Odin table of render, as one file
// per backend that render decodes once when it starts: how many stages it
// holds and the size of the code of each (u32, little endian), then their
// code as one stream (asset.unpack). The table of render says nothing of the code, so a
// change of code alone leaves it, and whatever was built from it, as they are.
// The stream is of the open compressor, which every build reads. A generation
// packs it with the profile Fast; one asked to ship (Options.ship, the release
// builds of the engine) with Ultra, which takes far longer and leaves a smaller
// executable. Each stream stays in the shared cache under the hashes of the
// code it holds, and a generation takes the shipped one whenever the cache has
// it.
EMBEDDED_NAMES :: [Backend]string{.Vulkan="shaders.spv.lz",.Metal="shaders.metal.lz"}
@(private)
CACHE_EMBEDDED :: "embedded"

// The sizes, then the stream.
@(private="file")
embedded_whole :: proc(sizes:[]int,stream:[]u8,allocator:=context.allocator) -> []u8 {
    file:=make([]u8,4*(len(sizes)+1)+len(stream),allocator)
    endian.unchecked_put_u32le(file,u32(len(sizes)))
    for size,at in sizes {endian.unchecked_put_u32le(file[4*(at+1):],u32(size))}
    copy(file[4*(len(sizes)+1):],stream)
    return file
}

// The file of one backend for the code of the staged stages of groups, one
// group after the other, its stream from the shared cache when it holds it,
// else packed now. shipped: file is the one a generation asked to ship wants.
@(private)
embedded_pack :: proc(g:^Generation,groups:[2][]Job,backend:Backend,ship:bool,allocator:=context.allocator) -> (file:[]u8,shipped:bool,problem:string) {
    hash:Sha256
    sha_begin(&hash)
    sha_text(&hash,GENERATOR_CONTRACT)
    sha_text(&hash,"\n")
    raw:=make([dynamic]u8)
    defer delete(raw)
    sizes:=make([]int,len(groups[0])+len(groups[1]),context.temp_allocator)
    at:=0
    for jobs in groups do for job in jobs {
        name,code_hash:=job.result.spv,job.result.spv_hash
        if backend==.Metal {name,code_hash=job.result.msl,job.result.msl_hash}
        // A stage of the rays traced by software has no Metal code: its size is 0.
        if name=="" {sha_text(&hash,"\n");at+=1;continue}
        data,err:=os.read_entire_file(path_join(job.staging,name,allocator=context.temp_allocator),context.allocator)
        if err!=nil {return nil,false,strings.concatenate({"could not read ",name," to embed it"},allocator)}
        append(&raw,..data)
        sizes[at]=len(data)
        at+=1
        delete(data)
        sha_text(&hash,code_hash)
        sha_text(&hash,"\n")
    }
    if len(raw)==0 {return embedded_whole(sizes,nil,allocator),ship,""}
    packed:=make([]u8,asset.pack_bound(len(raw)))
    defer delete(packed)
    digest:=sha_hex(&hash,context.temp_allocator)
    folder:=path_join(g.shared,CACHE_EMBEDDED,allocator=context.temp_allocator)
    names:=EMBEDDED_NAMES
    // <digest>.edit.spv.lz, <digest>.ship.spv.lz
    entries:[2]string
    for &entry,shipped in entries {
        level:="ship" if shipped==1 else "edit"
        entry=path_join(folder,strings.concatenate({digest,".",level,strings.trim_prefix(names[backend],"shaders")},context.temp_allocator),allocator=context.temp_allocator)
    }
    decoder:asset.Stream_Decoder
    if asset.stream_decoder_init(&decoder)!=.None {return nil,false,strings.clone("out of memory to embed the shaders",allocator)}
    defer asset.stream_decoder_destroy(&decoder)
    check:=make([]u8,len(raw))
    defer delete(check)
    // An entry is taken only when it decodes to this code.
    for shipped in ([2]int{1,0}) {
        if shipped==0 && ship {break}
        stored,err:=os.read_entire_file(entries[shipped],context.allocator)
        if err!=nil {continue}
        defer delete(stored)
        if asset.unpack(&decoder,stored,check)==.None && string(check)==string(raw[:]) {
            cache_touch(entries[shipped])
            return embedded_whole(sizes,stored,allocator),shipped==1,""
        }
    }
    encoder:asset.Stream_Encoder
    if asset.stream_encoder_init(&encoder)!=.None {return nil,false,strings.clone("out of memory to embed the shaders",allocator)}
    defer asset.stream_encoder_destroy(&encoder)
    profile:=data.Profile.Ultra if ship else .Fast
    // Its pieces compress at once on a job system of its own.
    js:jobs.Job_System
    on:jobs.Worker_Ref
    if len(raw)>asset.PACK_PIECE && jobs.system_init(&js,{threads=jobs.THREADS_AUTO}) {on={&js,jobs.OWNER,nil}}
    defer if on.system!=nil {jobs.system_destroy(&js)}
    written,pack_error:=asset.pack(&encoder,profile,.Open,raw[:],packed,on)
    if pack_error!=.None {return nil,false,strings.clone("could not compress the shaders to embed",allocator)}
    // A failure to store only costs packing it again.
    write_file_atomic(entries[int(ship)],packed[:written])
    return embedded_whole(sizes,packed[:written],allocator),ship,""
}
