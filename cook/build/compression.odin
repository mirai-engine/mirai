package build

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strings"
import "mirai:asset"
import lz_optimal "mirai:cook/compressor/lz"
import "mirai:cook/shaders"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/codec"
import "mirai:std/jobs"
import "mirai:std/subprocess"

// What a cook compresses a game with, from the compression of its project.
Cook_Compression :: struct {
    none:bool,           // nothing is compressed
    open:bool,           // the codecs and the encoders the engine holds
    library:string,      // of the Cook part of the plugin that compresses. Nothing of these: the private codec
    api:^codec.Cook_Api, // in place of library: what a test cooks with
}

// How what a game embeds of its compression is made before it compiles. The library is a compile
// of the sources of a plugin alone, against no library of the engine, since the program that loads
// it was built apart.
@(private)
Compression_Build :: struct {
    command:[]string,
    library:string,
    plugin:string,
    open:bool,
    raw_shaders:string, // the code the engine embeds, as it is
    shaders:string,     // where it is left compressed, for the game to embed
    quick:bool,         // of a --dev game: lz_optimal.QUICK in place of SHIP
}

// What the compression of a project takes from the build of its game.
@(private)
compression_flags :: proc(p:^project.Project,flags:^[dynamic]string,dev:bool,allocator:runtime.Allocator) {
    no_lz,no_open:=false,false
    shaders:=""
    kind,plugin:=project.compression_kind(p)
    switch kind {
    case .Mirai: no_open=true
    case .None: no_lz,no_open=true,true
    case .Open:
        // Without the private codec what the engine embeds already is of the open ones.
        if asset.ASSET_LZ {
            no_lz=true
            shaders=compression_shaders_file(p,nil,dev,context.temp_allocator)
        }
    case .Plugin:
        no_lz,no_open=true,true
        shaders=compression_shaders_file(p,plugin,dev,context.temp_allocator)
    }
    if no_lz {append(flags,strings.clone("-define:ASSET_LZ=false",allocator))}
    if no_open {append(flags,strings.clone("-define:ASSET_OPEN=false",allocator))}
    if shaders!="" {append(flags,fmt.aprintf("-define:ASSET_SHADERS=%s",shaders,allocator=allocator))}
}

// The file of the code the engine embeds, stored as it is, for the platform of this build.
@(private="file")
compression_shaders_raw :: proc(engine_root:string,allocator:runtime.Allocator) -> string {
    names:=shaders.EMBEDDED_NAMES
    return project.path(engine_root,"shaders/build",shaders.embedded_plain(names[shaders.HOST_BACKEND]),allocator=allocator)
}

// Where the embedded shaders compressed by plugin, or by the open codecs without one, are left:
// named by the code and by what makes them, so that a game built before finds its own. "" without
// that code.
@(private="file")
compression_shaders_file :: proc(p:^project.Project,plugin:^project.Plugin,dev:bool,allocator:runtime.Allocator) -> string {
    data,error:=os.read_entire_file(compression_shaders_raw(p.engine_root,context.temp_allocator),context.temp_allocator)
    if error!=nil {return ""}
    hash:=base.hash_combine(xxhash.XXH3_64_default(data),plugin!=nil?compression_library_hash(p,plugin):u64(asset.OPEN_ZSTD))
    name:=fmt.tprintf("embedded-%s-%016x.shaders",dev?"quick":"ship",hash)
    return project.path(project.folder_path(p.root,.Generated,context.temp_allocator),"compression",name,allocator=allocator)
}

// What names the library of the Cook part of a plugin.
@(private="file")
compression_library_hash :: proc(p:^project.Project,plugin:^project.Plugin) -> u64 {
    compiler,_:=compiler_find(p.engine_root,context.temp_allocator)
    sources:=make([dynamic]string,context.temp_allocator)
    compression_sources(plugin.folder,&sources)
    flags:=[?]string{"-build-mode:dll","-o:speed"}
    hash,_:=fingerprint(plugin.folder,compiler,flags[:],sources[:])
    engine,_:=fingerprint(p.engine_root,compiler,nil,engine_sources(p.engine_root,[]string{"std/base","std/codec","std/jobs"}))
    return hash~engine
}

// What the cook of a project needs of its compression, in allocator.
@(private)
compression_prepare :: proc(p:^project.Project,allocator:runtime.Allocator,dev:=false) -> (desc:Cook_Compression,build:Compression_Build) {
    kind,plugin:=project.compression_kind(p)
    switch kind {
    case .Mirai:
    case .None: desc.none=true
    case .Open:
        desc.open=true
        build.open=true
        if asset.ASSET_LZ {
            build.raw_shaders=compression_shaders_raw(p.engine_root,allocator)
            build.shaders=compression_shaders_file(p,nil,dev,allocator)
            build.quick=dev
        }
    case .Plugin:
        name:=base.text_get(plugin.manifest.name[:])
        compiler,_:=compiler_find(p.engine_root,context.temp_allocator)
        part:=project.PART_NAMES[.Cook]
        hash:=compression_library_hash(p,plugin)
        file:=fmt.tprintf("plugin-%s-%s-%08x",name,part,u32(hash~(hash>>32)))
        desc.library=project.path(plugins_libraries_folder(p.root,context.temp_allocator),project.library_file(file,context.temp_allocator),allocator=allocator)
        command:=make([dynamic]string,allocator)
        append(&command,strings.clone(compiler,allocator),"build",project.path(plugin.folder,part,allocator=allocator))
        append(&command,"-build-mode:dll","-o:speed",fmt.aprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES,allocator=allocator))
        append(&command,fmt.aprintf("-out:%s",desc.library,allocator=allocator))
        append(&command,fmt.aprintf("-collection:mirai=%s",p.engine_root,allocator=allocator))
        append(&command,fmt.aprintf("-collection:plugins=%s",project.path(p.engine_root,"plugins",allocator=context.temp_allocator),allocator=allocator))
        append(&command,fmt.aprintf("-collection:project=%s",p.root,allocator=allocator))
        build={command=command[:],library=desc.library,plugin=strings.clone(name,allocator),raw_shaders=compression_shaders_raw(p.engine_root,allocator),shaders=compression_shaders_file(p,plugin,dev,allocator),quick=dev}
    }
    return
}

// Every Odin source of a plugin, the folders of its build outputs aside.
@(private="file")
compression_sources :: proc(folder:string,out:^[dynamic]string) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if entry.type==.Directory {
            if !strings.has_prefix(entry.name,".") && entry.name!="testdata" {compression_sources(entry.fullpath,out)}
        } else if strings.has_suffix(entry.name,".odin") && !strings.has_suffix(entry.name,"_test.odin") {
            append(out,entry.fullpath)
        }
    }
}

// Builds the library unless it is there; "" or what the compiler said.
@(private)
compression_build :: proc(build:Compression_Build) -> (problem:string) {
    if build.command==nil || os.is_file(build.library) {return ""}
    slash:=strings.last_index_byte(build.library,'/')
    if os.make_directory_all(build.library[:slash])!=nil && !os.is_dir(build.library[:slash]) {return fmt.tprintf("the folder of %s could not be made",build.library)}
    state,output,errors,error:=subprocess.exec({command=build.command},context.temp_allocator)
    if error!=nil {return fmt.tprintf("the compiler could not run: %v",error)}
    if state.exit_code!=0 {return fmt.tprintf("the Cook part of %s does not compile: %s%s",build.plugin,string(output),string(errors))}
    return ""
}

// Compresses the shaders the game is about to embed, unless they are there. "" or why not.
@(private)
compression_shaders :: proc(build:Compression_Build) -> (problem:string) {
    if build.shaders=="" || os.is_file(build.shaders) {return ""}
    general:codec.Encode
    if build.open {
        general=asset.open_general()
    } else {
        api,loaded:=textures.compression_load(build.library)
        if loaded!="" {return loaded}
        general=api.general
    }
    file,error:=os.read_entire_file(build.raw_shaders,context.temp_allocator)
    if error!=nil {return fmt.tprintf("%s could not be read",build.raw_shaders)}
    // The sizes of the stages stay; their code goes from the stream that stores it to one of the codec.
    sizes,stored,total,whole:=shaders.embedded_split(file)
    raw:=make([]u8,total,context.temp_allocator)
    decoder:asset.Stream_Decoder
    if !whole || asset.stream_decoder_init(&decoder,context.temp_allocator)!=.None {return fmt.tprintf("%s is not the shaders the engine embeds: build the engine again",build.raw_shaders)}
    defer asset.stream_decoder_destroy(&decoder)
    if total>0 && asset.unpack(&decoder,stored,raw)!=.None {return fmt.tprintf("%s is not the shaders the engine embeds: build the engine again",build.raw_shaders)}
    packed:=make([]u8,len(sizes)+asset.codec_pack_bound(&general,len(raw)),context.temp_allocator)
    copy(packed,sizes)
    js:jobs.Job_System
    on:jobs.Worker_Ref
    if jobs.system_init(&js,{threads=jobs.THREADS_AUTO}) {on={&js,jobs.OWNER,nil}}
    defer if on.system!=nil {jobs.system_destroy(&js)}
    size,pack_error:=asset.codec_pack(&general,lz_optimal.QUICK if build.quick else lz_optimal.SHIP,raw,packed[len(sizes):],on)
    if pack_error!=.None {return "the embedded shaders could not be compressed"}
    size+=len(sizes)
    slash:=strings.last_index_byte(build.shaders,'/')
    if os.make_directory_all(build.shaders[:slash])!=nil && !os.is_dir(build.shaders[:slash]) {return fmt.tprintf("the folder of %s could not be made",build.shaders)}
    if os.write_entire_file(build.shaders,packed[:size])!=nil {return fmt.tprintf("%s could not be written",build.shaders)}
    return ""
}

// What a cook writes and decodes with, of a loaded library or of a test.
@(private)
compression_api :: proc(desc:Cook_Compression) -> (api:^codec.Cook_Api,problem:string) {
    if desc.api!=nil {return desc.api,""}
    if desc.library=="" {return nil,""}
    return textures.compression_load(desc.library)
}
