package shaders

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// What the last generation of a cache was made from and what it published:
// the request, the tools, every source it read or looked for, the folders it
// listed and the files it left. While all of it is as the stamp says, the
// next generation of the same request has nothing to do: it starts no
// compiler and leaves the output alone.
STAMP_FILE :: "generation.json"
@(private)
STAMP_VERSION :: 2

@(private)
Stamp_File :: struct {path:string,size,time:i64}

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
    for text in ([]string{GENERATOR_CONTRACT,abi_text(),material_schema(),shared_constants(),g.root,g.project,g.output,"odin" if odin else "","vulkan" if .Vulkan in g.backends else "","metal" if .Metal in g.backends else ""}) {
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
    data,readable:=read_json(path_join(g.cache,STAMP_FILE,allocator=context.temp_allocator),context.temp_allocator)
    if !readable {return}
    if version,_:=json_int(data["version"]);version!=STAMP_VERSION || json_text(data["request"])!=request {return}
    same_file :: proc(value:json.Value,path:string="") -> bool {
        object,is_object:=value.(json.Object)
        if !is_object {return false}
        size,has_size:=json_int(object["size"])
        modified,has_time:=json_int(object["time"])
        if !has_size || !has_time || (path!="" && json_text(object["path"])!=path) {return false}
        state:=file_state(json_text(object["path"]))
        return state.size==i64(size) && state.size>=0 && state.time==i64(modified)
    }
    tools,_:=data["tools"].(json.Array)
    if len(tools)!=len(Tool) {return}
    for path,tool in g.tools {
        if !same_file(tools[int(tool)],path) {return}
    }
    outputs,_:=data["outputs"].(json.Array)
    if len(outputs)==0 {return}
    for value in outputs {
        if !same_file(value) {return}
    }
    listings,_:=data["listings"].(json.Array)
    for value in listings {
        object,is_object:=value.(json.Object)
        if !is_object {return}
        recursive,_:=object["recursive"].(json.Boolean)
        if listing_read(json_text(object["path"]),recursive,context.temp_allocator,g.sources.overlay).hash!=json_text(object["hash"]) {return}
    }
    files,_:=data["files"].(json.Array)
    for value in files {
        object,is_object:=value.(json.Object)
        if !is_object {return}
        bytes,found:=source_read(g.sources.overlay,json_text(object["path"]),context.temp_allocator)
        wanted:=json_text(object["hash"])
        if found!=(wanted!="") || (found && sha_of(bytes,context.temp_allocator)!=wanted) {return}
    }
    stamp.slang=strings.clone(json_text(data["slang"]),allocator)
    stamp.metal_tools=strings.clone(json_text(data["metal_tools"]),allocator)
    stamp.engine=strings.clone(json_text(data["engine"]),allocator)
    stamp.shipped=data["shipped"].(json.Boolean) or_else false
    counts:=[3]^int{&stamp.shaders,&stamp.tests,&stamp.programs}
    for key,i in ([3]string{"shaders","tests","programs"}) {
        valid:bool
        if counts[i]^,valid=json_int(data[key]);!valid {return}
    }
    return stamp,stamp.engine!="" && stamp.shaders>0 && slang_version_at_least(stamp.slang,SLANG_VERSION)
}

// Writes the stamp of a generation that was published. excluded: the staging
// folder, whose files are made from the others. outputs: what was published.
@(private)
stamp_write :: proc(g:^Generation,request,excluded:string,outputs:[]string,stamp:Stamp) -> bool {
    writer:=json_writer(context.temp_allocator)
    file_to_json :: proc(writer:^Json_Writer,state:Stamp_File) {
        json_object_begin(writer)
        json_key(writer,"path");json_string(writer,state.path)
        json_key(writer,"size");json_integer(writer,state.size)
        json_key(writer,"time");json_integer(writer,state.time)
        json_object_end(writer)
    }
    json_object_begin(&writer)
    json_key(&writer,"version");json_integer(&writer,STAMP_VERSION)
    json_key(&writer,"request");json_string(&writer,request)
    json_key(&writer,"slang");json_string(&writer,stamp.slang)
    json_key(&writer,"metal_tools");json_string(&writer,stamp.metal_tools)
    json_key(&writer,"engine");json_string(&writer,stamp.engine)
    json_key(&writer,"shaders");json_integer(&writer,i64(stamp.shaders))
    json_key(&writer,"tests");json_integer(&writer,i64(stamp.tests))
    json_key(&writer,"programs");json_integer(&writer,i64(stamp.programs))
    json_key(&writer,"shipped");json_bool(&writer,stamp.shipped)
    json_key(&writer,"tools");json_array_begin(&writer)
    for path in g.tools {file_to_json(&writer,file_state(path))}
    json_array_end(&writer)
    json_key(&writer,"outputs");json_array_begin(&writer)
    for path in outputs {
        state:=file_state(path)
        if state.size<0 {return false}
        file_to_json(&writer,state)
    }
    json_array_end(&writer)
    paths:=make([dynamic]string,context.temp_allocator)
    for path in g.sources.listings {append(&paths,path)}
    slice.sort(paths[:])
    json_key(&writer,"listings");json_array_begin(&writer)
    for key in paths {
        listing:=g.sources.listings[key]
        if path_inside(listing.directory,excluded) || listing.directory==excluded {continue}
        json_object_begin(&writer)
        json_key(&writer,"path");json_string(&writer,listing.directory)
        json_key(&writer,"recursive");json_bool(&writer,listing.recursive)
        json_key(&writer,"hash");json_string(&writer,listing.hash)
        json_object_end(&writer)
    }
    json_array_end(&writer)
    clear(&paths)
    for path in g.sources.files {append(&paths,path)}
    slice.sort(paths[:])
    json_key(&writer,"files");json_array_begin(&writer)
    for path in paths {
        if path_inside(path,excluded) {continue}
        json_object_begin(&writer)
        json_key(&writer,"path");json_string(&writer,path)
        json_key(&writer,"hash");json_string(&writer,g.sources.files[path].hash)
        json_object_end(&writer)
    }
    json_array_end(&writer)
    json_object_end(&writer)
    return write_file_atomic(path_join(g.cache,STAMP_FILE,allocator=context.temp_allocator),json_finish(&writer))
}
