package shaders

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:render/abi"
import "mirai:std/serial"

// What the last generation of a cache was made from and what it published:
// the request, the tools, every source it read or looked for, the folders it
// listed and the files it left. While all of it is as the stamp says, the
// next generation of the same request has nothing to do: it starts no
// compiler and leaves the output alone.
STAMP_FILE :: "generation.json"
@(private)
STAMP_VERSION :: 4

@(private)
Stamp_File :: struct {path:string,size,time:i64}

// The file of a stamp: what it says and what it checks.
@(private)
Stamp_Record :: struct {
    version:int,
    request:string,
    stamp:Stamp,
    tools,outputs:[]Stamp_File,
    listings:[]Stamp_Listing,
    files:[]Stamp_Source,
}
@(private)
Stamp_Listing :: struct {path:string,recursive:bool,hash:string}
@(private)
Stamp_Source :: struct {path,hash:string} // hash empty: no such file

@(private)
Stamp :: struct {
    slang,metal_tools:string,
    shaders,tests,programs:int,
    engine:string,
    shipped:bool, // the embedded code is encoded as Options.ship asks
}

// size<0: no such file.
@(private)
file_state :: proc(path:string) -> (state:Stamp_File) {
    state.path=path
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil || info.type!=.Regular {state.size=-1;return}
    state.size,state.time=info.size,time.to_unix_nanoseconds(info.modification_time)
    return
}

// Identity of what a generation was asked for.
@(private)
request_digest :: proc(g:^Generation,sources:[]Source,odin:bool,allocator:=context.allocator) -> string {
    hash:Sha256
    sha_begin(&hash)
    zero:=[1]u8{0}
    for text in ([]string{GENERATOR_CONTRACT,fmt.tprint(abi.SHADER_CATALOG_VERSION),abi_text(),material_schema(),shared_constants(),g.root,g.project,g.output,"odin" if odin else "","vulkan" if .Vulkan in g.backends else "","metal" if .Metal in g.backends else ""}) {
        sha_text(&hash,text)
        sha_bytes(&hash,zero[:])
    }
    for flags in ([][]string{SLANG_FLAGS,SLANG_OPTIMIZATION,SPIRV_FLAGS,VALIDATE_FLAGS,OPTIMIZE_FLAGS,METAL_FLAGS}) {
        sha_text(&hash,strings.join(flags," ",context.temp_allocator))
        sha_bytes(&hash,zero[:])
    }
    for source in sources {
        sha_text(&hash,source.name)
        sha_bytes(&hash,zero[:])
        sha_text(&hash,path_clean(source.folder,context.temp_allocator))
        sha_bytes(&hash,zero[:])
    }
    return sha_hex(&hash,allocator)
}

// The stamp of the cache when it is of this request, it was made with a Slang
// the engine accepts and everything it names is as it says.
@(private)
stamp_current :: proc(g:^Generation,request:string,allocator:=context.allocator) -> (stamp:Stamp,ok:bool) {
    data,unread:=os.read_entire_file(path_join(g.cache,STAMP_FILE,allocator=context.temp_allocator),context.temp_allocator)
    record:Stamp_Record
    if unread!=nil || serial.text_decode(string(data),&record,context.temp_allocator)!="" || record.version!=STAMP_VERSION || record.request!=request {return}
    same :: proc(file:Stamp_File) -> bool {
        state:=file_state(file.path)
        return state.size>=0 && state.size==file.size && state.time==file.time
    }
    if len(record.tools)!=len(Tool) || len(record.outputs)==0 {return}
    for path,tool in g.tools {
        if record.tools[int(tool)].path!=path || !same(record.tools[int(tool)]) {return}
    }
    for file in record.outputs {
        if !same(file) {return}
    }
    for listing in record.listings {
        if listing_read(listing.path,listing.recursive,context.temp_allocator).hash!=listing.hash {return}
    }
    for file in record.files {
        bytes,found:=source_bytes(file.path,context.temp_allocator)
        if found!=(file.hash!="") || (found && sha_of(bytes,context.temp_allocator)!=file.hash) {return}
    }
    stamp=record.stamp
    stamp.slang=strings.clone(stamp.slang,allocator)
    stamp.metal_tools=strings.clone(stamp.metal_tools,allocator)
    stamp.engine=strings.clone(stamp.engine,allocator)
    return stamp,stamp.engine!="" && stamp.shaders>0 && slang_version_at_least(stamp.slang,SLANG_VERSION)
}

// Writes the stamp of a generation that was published. excluded: the staging
// folder, whose files are made from the others. outputs: what was published.
@(private)
stamp_write :: proc(g:^Generation,request,excluded:string,outputs:[]string,stamp:Stamp) -> bool {
    record:=Stamp_Record{version=STAMP_VERSION,request=request,stamp=stamp}
    tools:=make([dynamic]Stamp_File,context.temp_allocator)
    for path in g.tools {append(&tools,file_state(path))}
    published:=make([dynamic]Stamp_File,context.temp_allocator)
    for path in outputs {
        state:=file_state(path)
        if state.size<0 {return false}
        append(&published,state)
    }
    listings:=make([dynamic]Stamp_Listing,context.temp_allocator)
    for _,listing in g.sources.listings {
        if path_inside(listing.directory,excluded) || listing.directory==excluded {continue}
        append(&listings,Stamp_Listing{listing.directory,listing.recursive,listing.hash})
    }
    files:=make([dynamic]Stamp_Source,context.temp_allocator)
    for path,file in g.sources.files {
        if !path_inside(path,excluded) {append(&files,Stamp_Source{path,file.hash})}
    }
    slice.sort_by(listings[:],proc(a,b:Stamp_Listing) -> bool {return a.path<b.path})
    slice.sort_by(files[:],proc(a,b:Stamp_Source) -> bool {return a.path<b.path})
    record.tools,record.outputs,record.listings,record.files=tools[:],published[:],listings[:],files[:]
    text,encoded:=serial.text_encode(record,.Pretty,context.temp_allocator)
    return encoded && write_file_atomic(path_join(g.cache,STAMP_FILE,allocator=context.temp_allocator),text)
}
