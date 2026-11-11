package shaders

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import "mirai:render/abi"
import "mirai:std/serial"

// What a generation read of the file system, each path once: the bytes of a
// source with the line endings of the repository, the paths an include was
// looked for at and not found, and the files of the folders it listed. It is
// everything the generation was made from: stamp.odin keeps it, and a later
// generation that finds all of it as it was has nothing to do.
Sources :: struct {
    lock:     sync.Mutex,
    allocator:runtime.Allocator,
    files:    map[string]Source_File,
    listings: map[string]Listing,
    overlay:  map[string]Overlay, // by the path of the source: read instead of its file
}

Source_File :: struct {
    data: []u8,
    hash: string, // of data; "" for a path that is not a file
    compilation_hash:string, // parameter metadata does not change code or reflected layout
    macros:Extension_Features, // the macros of extensions.slang its text names
    found:bool,
}

Listing :: struct {
    directory:string,
    recursive:bool,
    files:    []string, // sorted
    hash:     string,   // of their names; "" for a folder that does not exist
}

sources_init :: proc(s:^Sources,allocator:runtime.Allocator,overlay:[]Overlay={}) {
    s.allocator=allocator
    s.files=make(map[string]Source_File,allocator)
    s.listings=make(map[string]Listing,allocator)
    s.overlay=make(map[string]Overlay,allocator)
    for entry in overlay {s.overlay[path_clean(entry.path,allocator)]=entry}
}

// What a source holds: what the overlay gives for it, else its file.
@(private)
source_read :: proc(overlay:map[string]Overlay,path:string,allocator:=context.allocator) -> (data:[]u8,ok:bool) {
    entry,overlaid:=overlay[path]
    if !overlaid {return source_bytes(path,allocator)}
    if entry.removed {return nil,false}
    data=make([]u8,len(entry.data),allocator)
    copy(data,entry.data)
    if strings.has_suffix(path,".slang-module") {return data,true}
    return lf_bytes(data),true
}

@(private)
sources_file :: proc(s:^Sources,path:string) -> Source_File {
    sync.guard(&s.lock)
    if file,known:=s.files[path];known {return file}
    file:Source_File
    file.data,file.found=source_read(s.overlay,path,s.allocator)
    if file.found {
        file.hash=sha_of(file.data,s.allocator)
        file.compilation_hash=sha_of(compilation_source_bytes(path,file.data,context.temp_allocator),s.allocator)
        file.macros=extension_macros(string(file.data))
    }
    s.files[strings.clone(path,s.allocator)]=file
    return file
}

// Only complete parameter annotations in line comments are authoring data.
// Keep newlines for __LINE__; unfamiliar raw strings and continued physical
// lines retain the full source rather than risk interpreting their contents.
@(private)
compilation_source_bytes :: proc(path:string,data:[]u8,allocator:=context.allocator) -> []u8 {
    text:=string(data)
    if strings.has_suffix(path,".slang-module") || !utf8.valid_string(text) || strings.contains(text,"R\"") || strings.contains(text,"\\\n") {return data}
    State :: enum {Code,Block,String,Character}
    state:=State.Code
    out:=make([dynamic]u8,0,len(data),allocator)
    start,i:=0,0
    for i<len(data) {
        if i==start && state==.Code {
            end:=i
            for end<len(data) && data[end]!='\n' {end+=1}
            if _,_,annotation:=parameter_metadata(string(data[i:end]));annotation {
                i=end
                if i<len(data) {append(&out,'\n');i+=1}
                start=i
                continue
            }
        }
        c:=data[i]
        switch state {
        case .Code:
            if c=='/' && i+1<len(data) && data[i+1]=='/' {
                for i<len(data) && data[i]!='\n' {append(&out,data[i]);i+=1}
                continue
            }
            if c=='/' && i+1<len(data) && data[i+1]=='*' {state=.Block;append(&out,c);i+=1;c=data[i]}
            else if c=='"' {state=.String}
            else if c=='\'' {state=.Character}
        case .Block:
            if c=='*' && i+1<len(data) && data[i+1]=='/' {state=.Code;append(&out,c);i+=1;c=data[i]}
        case .String,.Character:
            if c=='\\' && i+1<len(data) {append(&out,c);i+=1;c=data[i]}
            else if (state==.String && c=='"') || (state==.Character && c=='\'') {state=.Code}
        }
        append(&out,c)
        i+=1
        if c=='\n' {start=i}
    }
    return out[:]
}

@(private)
listing_read :: proc(directory:string,recursive:bool,allocator:runtime.Allocator,overlay:map[string]Overlay=nil) -> (listing:Listing) {
    listing.directory,listing.recursive=strings.clone(directory,allocator),recursive
    found:=make([dynamic]string,allocator)
    collect :: proc(directory:string,recursive:bool,found:^[dynamic]string) {
        entries,err:=os.read_all_directory_by_path(directory,context.temp_allocator)
        if err!=nil {return}
        for entry in entries {
            path:=path_join(directory,entry.name,allocator=found.allocator)
            if entry.type==.Directory {
                if recursive {collect(path,recursive,found)}
            } else {
                append(found,path)
            }
        }
    }
    exists:=os.is_directory(directory)
    if exists {collect(directory,recursive,&found)}
    // A source the overlay removed is not there, and one it adds is, also to a
    // folder the disk does not have yet.
    for path,entry in overlay {
        relative,inside:=path_relative(path,directory)
        if !inside || (!recursive && strings.contains_rune(relative,'/')) {continue}
        at,listed:=slice.linear_search(found[:],path)
        if entry.removed && listed {ordered_remove(&found,at)}
        if !entry.removed && !listed {append(&found,strings.clone(path,allocator))}
    }
    if !exists && len(found)==0 {return}
    slice.sort_by(found[:],path_less)
    hash:Sha256
    sha_begin(&hash)
    zero:=[1]u8{0}
    for path in found {
        relative,_:=path_relative(path,directory)
        sha_text(&hash,relative)
        sha_bytes(&hash,zero[:])
    }
    listing.files,listing.hash=found[:],sha_hex(&hash,allocator)
    return
}

@(private)
sources_listing :: proc(s:^Sources,directory:string,recursive:bool) -> Listing {
    sync.guard(&s.lock)
    key:=strings.concatenate({directory,"|r" if recursive else "|"},context.temp_allocator)
    if listing,known:=s.listings[key];known {return listing}
    listing:=listing_read(directory,recursive,s.allocator,s.overlay)
    s.listings[strings.clone(key,s.allocator)]=listing
    return listing
}

// Every file below a directory, sorted. A missing directory has none.
@(private)
sources_below :: proc(s:^Sources,directory:string) -> []string {return sources_listing(s,directory,true).files}

// The files of a directory itself whose name ends in suffix, sorted.
@(private)
sources_in :: proc(s:^Sources,directory,suffix:string,allocator:=context.allocator) -> []string {
    found:=make([dynamic]string,allocator)
    for path in sources_listing(s,directory,false).files {
        if strings.has_suffix(path,suffix) {append(&found,path)}
    }
    return found[:]
}

// A folder a source is named after, so a name does not depend on where the
// checkout is: "engine/shaders/cull.comp.slang".
Base :: struct {label,path:string}

@(private)
stable_name :: proc(path:string,bases:[]Base,allocator:=context.allocator) -> string {
    for base in bases {
        if relative,inside:=path_relative(path,base.path);inside {return strings.concatenate({base.label,"/",relative},allocator)}
    }
    // Dependencies outside the project and the engine still invalidate the cache.
    return strings.clone(path,allocator)
}

@(private)
is_space :: proc(c:u8) -> bool {return c==' ' || c=='\t' || c=='\r' || c=='\v' || c=='\f'}
@(private)
is_word :: proc(c:u8) -> bool {return c=='_' || (c>='0' && c<='9') || (c>='a' && c<='z') || (c>='A' && c<='Z') || c>=0x80}

@(private)
skip_spaces :: proc(text:string) -> string {
    rest:=text
    for len(rest)>0 && is_space(rest[0]) {rest=rest[1:]}
    return rest
}

// The rest of the line of a `# include` directive, or false.
@(private)
include_directive :: proc(line:string) -> (rest:string,ok:bool) {
    text:=skip_spaces(line)
    if !strings.has_prefix(text,"#") {return}
    text=skip_spaces(text[1:])
    if !strings.has_prefix(text,"include") {return}
    text=text[len("include"):]
    if len(text)==0 || !is_space(text[0]) {return}
    text=skip_spaces(text)
    return text,len(text)>0
}

// The file a directive names between quotes or angle brackets, or false for
// one that names it through a macro.
@(private)
include_target :: proc(directive:string) -> (name:string,ok:bool) {
    if len(directive)<3 || (directive[0]!='"' && directive[0]!='<') {return}
    end:=strings.index_any(directive[1:],"\">")
    if end<=0 {return}
    return directive[1:][:end],true
}

// The module of an `import a.b;` or `export import a.b;` line, or false.
@(private)
import_module :: proc(line:string) -> (name:string,ok:bool) {
    text:=skip_spaces(line)
    if strings.has_prefix(text,"export") && len(text)>6 && is_space(text[6]) {text=skip_spaces(text[6:])}
    if !strings.has_prefix(text,"import") || len(text)<=6 || !is_space(text[6]) {return}
    text=skip_spaces(text[6:])
    end:=0
    for end<len(text) && (is_word(text[end]) || text[end]=='.') {end+=1}
    if end==0 {return}
    rest:=skip_spaces(text[end:])
    if !strings.has_prefix(rest,";") {return}
    return text[:end],true
}

// The sources a shader is compiled from: itself and its literal includes and
// imports, recursively, found in the order the compiler searches them.
// Conditional branches are conservative: either branch invalidates its users.
// An include named through a macro brings every file of the search folders,
// rather than risk reusing output whose dependency the scan cannot resolve.
// sources: what the generation has read already; nil reads everything here.
// literal: only what the literal includes and imports reach, without the
// folders of a macro include. alpha: not the source of a program that the
// coverage include names by its alpha (ALPHA_INCLUDE), as a fingerprint
// counts it.
dependencies :: proc(source:string,include_dirs:[]string,allocator:=context.allocator,sources:^Sources=nil,literal:=false,alpha:=false) -> []string {
    Scan :: struct {found:[dynamic]string,seen:map[string]bool,roots:[]string,sources:^Sources,literal,alpha:bool}
    // The folder of the including file comes before the search folders.
    resolve :: proc(scan:^Scan,folder,name:string) -> (path:string,ok:bool) {
        candidate:=path_clean(path_join(folder,name,allocator=context.temp_allocator),scan.found.allocator)
        if sources_file(scan.sources,candidate).found {return candidate,true}
        for root in scan.roots {
            candidate=path_clean(path_join(root,name,allocator=context.temp_allocator),scan.found.allocator)
            if sources_file(scan.sources,candidate).found {return candidate,true}
        }
        return "",false
    }
    visit :: proc(scan:^Scan,path:string) {
        if scan.seen[path] {return}
        scan.seen[path]=true
        append(&scan.found,path)
        if strings.has_suffix(path,".slang-module") {return}
        file:=sources_file(scan.sources,path)
        // The search folders of a macro include can hold binary assets too:
        // their bytes are hashed, and Slang rejects the invalid sources it uses.
        if !file.found || !utf8.valid_string(string(file.data)) {return}
        folder:=path_parent(path)
        text:=string(file.data)
        for line in strings.split_lines_iterator(&text) {
            if directive,found:=include_directive(line);found {
                if scan.alpha && strings.contains(directive,ALPHA_INCLUDE) {continue}
                name,literal:=include_target(directive)
                if !literal {
                    if scan.literal {continue}
                    for other in sources_below(scan.sources,folder) {visit(scan,other)}
                    for root in scan.roots {for other in sources_below(scan.sources,root) {visit(scan,other)}}
                    continue
                }
                // An inactive conditional may name an optional include that is
                // absent; Slang reports the missing include of an active one.
                if resolved,exists:=resolve(scan,folder,name);exists {visit(scan,resolved)}
            } else if module,found:=import_module(line);found {
                relative,_:=strings.replace_all(module,".","/",context.temp_allocator)
                // The builtin modules of Slang are covered by the compiler version.
                resolved,exists:=resolve(scan,folder,strings.concatenate({relative,".slang"},context.temp_allocator))
                if !exists {resolved,exists=resolve(scan,folder,strings.concatenate({relative,".slang-module"},context.temp_allocator))}
                if exists {visit(scan,resolved)}
            }
        }
    }
    local:Sources
    scan:=Scan{found=make([dynamic]string,allocator),seen=make(map[string]bool,context.temp_allocator),sources=sources,literal=literal,alpha=alpha}
    if scan.sources==nil {
        sources_init(&local,context.temp_allocator)
        scan.sources=&local
    }
    roots:=make([]string,len(include_dirs),context.temp_allocator)
    for directory,i in include_dirs {roots[i]=path_clean(directory,context.temp_allocator)}
    scan.roots=roots
    visit(&scan,path_clean(source,allocator))
    return scan.found[:]
}

// Identity of what a shader is compiled from: the configuration (compiler,
// flags, generator contract) and the name and bytes of every dependency.
fingerprint :: proc(source:string,include_dirs:[]string,bases:[]Base,configuration:[]u8,allocator:=context.allocator,sources:^Sources=nil) -> string {
    Named :: struct {name,path:string}
    local:Sources
    s:=sources
    if s==nil {
        sources_init(&local,context.temp_allocator)
        s=&local
    }
    paths:=dependencies(source,include_dirs,context.temp_allocator,s,alpha=true)
    named:=make([]Named,len(paths),context.temp_allocator)
    for path,i in paths {named[i]={stable_name(path,bases,context.temp_allocator),path}}
    slice.sort_by(named,proc(a,b:Named) -> bool {return a.name<b.name if a.name!=b.name else a.path<b.path})
    hash:Sha256
    sha_begin(&hash)
    sha_bytes(&hash,configuration)
    zero:=[1]u8{0}
    for entry in named {
        sha_text(&hash,entry.name)
        sha_bytes(&hash,zero[:])
        sha_text(&hash,sources_file(s,entry.path).compilation_hash)
        sha_bytes(&hash,zero[:])
    }
    return sha_hex(&hash,allocator)
}

// What one compiled stage is: an entry of the manifest of a generation and of
// the shared cache.
Stage :: abi.Shader_Stage
Binding :: abi.Shader_Binding
Shader :: abi.Shader_Entry

@(private)
json_text :: proc(value:json.Value) -> string {return value.(json.String) or_else ""}
@(private)
json_int :: proc(value:json.Value) -> (int,bool) {
    #partial switch v in value {
    case json.Integer: return int(v),true
    case json.Float: return int(v),f64(int(v))==v
    }
    return 0,false
}

@(private)
read_json :: proc(path:string,allocator:=context.allocator) -> (json.Object,bool) {
    data,err:=os.read_entire_file(path,allocator)
    if err!=nil {return nil,false}
    value,parse_error:=json.parse(data,parse_integers=true,allocator=allocator)
    object,is_object:=value.(json.Object)
    return object,parse_error==.None && is_object
}

// An entry read from text is a stage: named, with names for its constants.
@(private)
shader_valid :: proc(shader:Shader) -> bool {
    if shader.name=="" || shader.id=="" {return false}
    for constant in shader.constants {
        if constant=="" {return false}
    }
    return true
}

// The entry a file holds, in allocator; false when it holds none.
@(private)
shader_read :: proc(path:string,allocator:=context.allocator) -> (shader:Shader,ok:bool) {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil || serial.text_decode(string(data),&shader,allocator)!="" {return}
    return shader,shader_valid(shader)
}

// The code of an entry a generation of these backends has: the rest is not named.
@(private)
shader_trim :: proc(entry:Shader,backends:Backends) -> Shader {
    trimmed:=entry
    if .Vulkan not_in backends {trimmed.spv,trimmed.spv_hash="",""}
    if .Metal not_in backends {trimmed.msl,trimmed.msl_hash,trimmed.entry="","",""}
    return trimmed
}

// The code of every backend asked for, read from the files an entry names in
// folder: when the entry is of this fingerprint and each file is what its
// hash says. A name is a file of the folder, never a path.
@(private)
artifacts_read :: proc(entry:Shader,wanted_fingerprint,folder:string,backends:Backends) -> (files:[Backend][]u8,ok:bool) {
    if entry.fingerprint!=wanted_fingerprint || entry.fingerprint=="" {return}
    names:=[Backend]string{.Vulkan=entry.spv,.Metal=entry.msl}
    hashes:=[Backend]string{.Vulkan=entry.spv_hash,.Metal=entry.msl_hash}
    for backend in backends {
        name:=names[backend]
        if name=="" || path_name(name)!=name || strings.contains_rune(name,'\\') {return}
        data,err:=os.read_entire_file(path_join(folder,name,allocator=context.temp_allocator),context.temp_allocator)
        if err!=nil || sha_of(data,context.temp_allocator)!=hashes[backend] {return}
        files[backend]=data
    }
    return files,true
}

// Writes the code of every backend asked for into staging, under the names of the stage.
@(private)
artifacts_stage :: proc(files:[Backend][]u8,names:[Backend]string,staging:string,backends:Backends) -> bool {
    for backend in backends {
        if !write_file(path_join(staging,names[backend],allocator=context.temp_allocator),files[backend]) {return false}
    }
    return true
}

// The cache every checkout of a repository shares, in
// workspace.cache_folder(root,CACHE_NAME). An entry is named by the digest of
// what it was made from, so branches, worktrees and projects find the work of
// the others and never replace it:
//
//   stages/<digest>.json, .spv, .metal    a compiled stage: its entry and its code
//   reflection/<digest>.json              the Parameters of a program
//   reflection/<digest>.attributes.json   the Attributes of a Vfx program
//   embedded/<digest>.<edit|ship>.spv.lz, .metal.lz
//                                         the code render embeds (embedded_pack)
//
// Each file is written whole and renamed into place, the entry of a stage
// last; a reader takes an entry only when every hash it names matches, and
// anything else is a miss, compiled and stored again. A use touches the entry.
CACHE_NAME :: "shaders"
@(private)
CACHE_UNUSED_DAYS :: 30
@(private)
CACHE_STAGES :: "stages"
@(private)
CACHE_REFLECTION :: "reflection"
@(private)
CODE_EXTENSIONS :: [Backend]string{.Vulkan=".spv",.Metal=".metal"}

// The entry of a digest in the shared cache with the code of every backend
// asked for, each file what its hash says; false otherwise.
@(private)
cache_stage_read :: proc(shared,digest:string,backends:Backends,allocator:=context.allocator) -> (entry:Shader,files:[Backend][]u8,ok:bool) {
    folder:=path_join(shared,CACHE_STAGES,allocator=context.temp_allocator)
    path:=path_join(folder,strings.concatenate({digest,".json"},context.temp_allocator),allocator=context.temp_allocator)
    stored,valid:=shader_read(path,allocator)
    if !valid {return}
    code,found:=artifacts_read(stored,digest,folder,backends)
    if !found {return}
    cache_touch(path)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    entry=stored
    return entry,code,true
}

// Stores a stage in the shared cache. An entry of its digest keeps the code
// of the backends it has and this one lacks: a backend compiles the same alone
// or with the other. A failure only costs a later compilation.
@(private)
cache_stage_write :: proc(shared:string,shader:Shader,files:[Backend][]u8,backends:Backends) -> bool {
    if shader.fingerprint=="" {return false}
    folder:=path_join(shared,CACHE_STAGES,allocator=context.temp_allocator)
    path:=path_join(folder,strings.concatenate({shader.fingerprint,".json"},context.temp_allocator),allocator=context.temp_allocator)
    entry:=shader_trim(shader,backends)
    if previous,valid:=shader_read(path,context.temp_allocator);valid && previous.fingerprint==shader.fingerprint {
        if .Vulkan not_in backends {entry.spv,entry.spv_hash=previous.spv,previous.spv_hash}
        if .Metal not_in backends {entry.msl,entry.msl_hash,entry.entry=previous.msl,previous.msl_hash,previous.entry}
    }
    extensions:=CODE_EXTENSIONS
    for backend in backends {
        name:=strings.concatenate({shader.fingerprint,extensions[backend]},context.temp_allocator)
        if !write_file_atomic(path_join(folder,name,allocator=context.temp_allocator),files[backend]) {return false}
        if backend==.Vulkan {entry.spv=name} else {entry.msl=name}
    }
    text,encoded:=serial.text_encode(entry,.Pretty,context.temp_allocator)
    return encoded && write_file_atomic(path,text)
}

// Marks an entry of the shared cache as used now.
@(private)
cache_touch :: proc(path:string) {
    now:=time.now()
    _=os.change_times(path,now,now)
}

// Removes the entries of the shared cache that no generation used in
// CACHE_UNUSED_DAYS, at most once a day: the file `pruned` says when it last
// ran. An entry is the files named by its digest; its last use is that of the
// newest one.
@(private)
cache_prune :: proc(shared:string,now:time.Time) {
    DAY :: 24*time.Hour
    marker:=path_join(shared,"pruned",allocator=context.temp_allocator)
    if info,err:=os.stat(marker,context.temp_allocator);err==nil && time.diff(info.modification_time,now)<DAY {return}
    if os.make_directory_all(shared)!=nil && !os.is_directory(shared) {return}
    if os.write_entire_file(marker,[]u8{})!=nil {return}
    oldest:=time.time_add(now,-CACHE_UNUSED_DAYS*DAY)
    digest :: proc(name:string) -> string {
        end:=strings.index_byte(name,'.')
        return name[:end] if end>=0 else name
    }
    for folder in ([]string{CACHE_STAGES,CACHE_REFLECTION,CACHE_EMBEDDED}) {
        files,err:=os.read_all_directory_by_path(path_join(shared,folder,allocator=context.temp_allocator),context.temp_allocator)
        if err!=nil {continue}
        newest:=make(map[string]time.Time,context.temp_allocator)
        for file in files {
            if last,seen:=newest[digest(file.name)];!seen || time.diff(last,file.modification_time)>0 {newest[digest(file.name)]=file.modification_time}
        }
        for file in files {
            if time.diff(newest[digest(file.name)],oldest)>0 {_=os.remove(file.fullpath)}
        }
    }
}
