package shaders

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
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
}

Source_File :: struct {
    data: []u8,
    hash: string, // of data; "" for a path that is not a file
    compilation_hash:string, // parameter metadata does not change code or reflected layout
    macros:Extension_Features, // the macros of extensions.slang its text names
    declarations:[]Declaration, // of the text the compilation hash is of (declarations.odin)
    found:bool,
}

Listing :: struct {
    directory:string,
    recursive:bool,
    files:    []string, // sorted
    hash:     string,   // of their names; "" for a folder that does not exist
}

sources_init :: proc(s:^Sources,allocator:runtime.Allocator) {
    s.allocator=allocator
    s.files=make(map[string]Source_File,allocator)
    s.listings=make(map[string]Listing,allocator)
}

@(private)
sources_file :: proc(s:^Sources,path:string) -> Source_File {
    sync.guard(&s.lock)
    if file,known:=s.files[path];known {return file}
    file:Source_File
    file.data,file.found=source_bytes(path,s.allocator)
    if file.found {file=source_record(path,file.data,s.allocator)}
    s.files[strings.clone(path,s.allocator)]=file
    return file
}

@(private)
source_record :: proc(path:string,data:[]u8,allocator:runtime.Allocator) -> (file:Source_File) {
    file.data,file.found=data,true
    file.hash=sha_of(data,allocator)
    code:=compilation_source_bytes(path,data,context.temp_allocator)
    file.compilation_hash=sha_of(code,allocator)
    file.macros=extension_macros(string(data))
    if !strings.has_suffix(path,".slang-module") && utf8.valid_string(string(code)) {
        file.declarations=declarations_of(string(code),allocator)
    }
    return
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
listing_read :: proc(directory:string,recursive:bool,allocator:runtime.Allocator) -> (listing:Listing) {
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
    if !os.is_directory(directory) {return}
    collect(directory,recursive,&found)
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
    listing:=listing_read(directory,recursive,s.allocator)
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
// folders of a macro include.
dependencies :: proc(
    source:string,include_dirs:[]string,allocator:=context.allocator,sources:^Sources=nil,
    literal:=false,inline_text:string="",
) -> []string {
    Scan :: struct {
        found:[dynamic]string,
        seen:map[string]bool,
        roots:[]string,
        sources:^Sources,
        literal:bool,
        root,text:string,
    }
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
        file:Source_File
        if path==scan.root && scan.text!="" {
            file={found=true,data=transmute([]u8)scan.text}
        } else {
            file=sources_file(scan.sources,path)
        }
        // The search folders of a macro include can hold binary assets too:
        // their bytes are hashed, and Slang rejects the invalid sources it uses.
        if !file.found || !utf8.valid_string(string(file.data)) {return}
        folder:=path_parent(path)
        text:=string(file.data)
        for line in strings.split_lines_iterator(&text) {
            if directive,found:=include_directive(line);found {
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
    scan:=Scan{found=make([dynamic]string,allocator),seen=make(map[string]bool,context.temp_allocator),sources=sources,literal=literal}
    if scan.sources==nil {
        sources_init(&local,context.temp_allocator)
        scan.sources=&local
    }
    roots:=make([]string,len(include_dirs),context.temp_allocator)
    for directory,i in include_dirs {roots[i]=path_clean(directory,context.temp_allocator)}
    scan.roots=roots
    scan.root,scan.text=path_clean(source,allocator),inline_text
    visit(&scan,scan.root)
    return scan.found[:]
}

// Identity of what a shader is compiled from: the configuration (compiler,
// flags, generator contract), the name of every dependency and of each the
// declarations the shader reaches (declarations.odin): its own source whole.
// A dependency the scan cannot read in declarations (a binary module) is
// taken whole.
fingerprint :: proc(
    source:string,include_dirs:[]string,bases:[]Base,configuration:[]u8,
    allocator:=context.allocator,sources:^Sources=nil,inline_text:string="",whole:=false,
) -> string {
    Named :: struct {name,path:string,file:Source_File}
    local:Sources
    s:=sources
    if s==nil {
        sources_init(&local,context.temp_allocator)
        s=&local
    }
    root:=path_clean(source,context.temp_allocator)
    paths:=dependencies(root,include_dirs,context.temp_allocator,s,inline_text=inline_text)
    named:=make([]Named,len(paths),context.temp_allocator)
    for path,i in paths {
        file:Source_File
        if path==root && inline_text!="" {
            file=source_record(root,transmute([]u8)inline_text,context.temp_allocator)
        } else {
            file=sources_file(s,path)
        }
        named[i]={stable_name(path,bases,context.temp_allocator),path,file}
    }
    slice.sort_by(named,proc(a,b:Named) -> bool {return a.name<b.name if a.name!=b.name else a.path<b.path})
    hash:Sha256
    sha_begin(&hash)
    sha_bytes(&hash,configuration)
    zero:=[1]u8{0}
    // Inline generated sources may declare fields or types inside includes.
    if whole || inline_text!="" {
        for entry in named {
            sha_text(&hash,entry.name)
            sha_bytes(&hash,zero[:])
            sha_text(&hash,entry.file.compilation_hash)
            sha_bytes(&hash,zero[:])
        }
        return sha_hex(&hash,allocator)
    }
    // What the shader takes: the unnamed declarations and its own source, then
    // each named one a name it takes names, until no name is new.
    taken:=make([][]bool,len(named),context.temp_allocator)
    by_name:=make(map[string][dynamic][2]int,context.temp_allocator)
    reached:=make(map[string]bool,context.temp_allocator)
    pending:=make([dynamic]string,context.temp_allocator)
    take :: proc(taken:[][]bool,declaration:Declaration,at:[2]int,reached:^map[string]bool,pending:^[dynamic]string) {
        if taken[at[0]][at[1]] {return}
        taken[at[0]][at[1]]=true
        for name in declaration.names {
            if reached[name] {continue}
            reached[name]=true
            append(pending,name)
        }
    }
    for entry,f in named {
        taken[f]=make([]bool,len(entry.file.declarations),context.temp_allocator)
        for declaration,d in entry.file.declarations {
            if declaration.name=="" || entry.path==root {continue}
            list:=by_name[declaration.name] or_else make([dynamic][2]int,context.temp_allocator)
            append(&list,[2]int{f,d})
            by_name[declaration.name]=list
        }
    }
    for entry,f in named {
        for declaration,d in entry.file.declarations {
            if declaration.name=="" || entry.path==root {take(taken,declaration,{f,d},&reached,&pending)}
        }
    }
    for len(pending)>0 {
        name:=pop(&pending)
        for at in by_name[name] {take(taken,named[at[0]].file.declarations[at[1]],at,&reached,&pending)}
    }
    for entry,f in named {
        sha_text(&hash,entry.name)
        sha_bytes(&hash,zero[:])
        if entry.file.declarations==nil {
            sha_text(&hash,entry.file.compilation_hash)
            sha_bytes(&hash,zero[:])
            continue
        }
        for declaration,d in entry.file.declarations {
            if !taken[f][d] {continue}
            sha_text(&hash,declaration.hash)
            sha_bytes(&hash,zero[:])
        }
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
//   stages/<digest>.reflected.json        a stage compiled only to be reflected
//                                         (reflected_only): its entry, without code
//   reflection/<digest>.json              the Parameters of a program
//   reflection/<digest>.attributes.json   the Attributes of a Vfx program
//   embedded/<digest>.<edit|ship>.spv.lz, .metal.lz
//                                         the code render embeds (embedded_pack)
//   peaks/<key>                           the bytes the last compilation of a stage
//                                         held at its peak, by its name (charge_of,
//                                         job_key)
//   compiling                             the compilations that run (ledger_update)
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
CACHE_PEAKS :: "peaks"
@(private)
CACHE_LEDGER :: "compiling"

// The peaks the shared cache keeps, by key.
@(private)
peaks_read :: proc(shared:string,allocator:runtime.Allocator) -> map[string]i64 {
    peaks:=make(map[string]i64,allocator)
    folder:=path_join(shared,CACHE_PEAKS,allocator=context.temp_allocator)
    files,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return peaks}
    for file in files {
        if strings.has_suffix(file.name,".tmp") {continue}
        data,read_error:=os.read_entire_file(file.fullpath,context.temp_allocator)
        if read_error!=nil {continue}
        if bytes,parsed:=strconv.parse_i64(strings.trim_space(string(data)));parsed && bytes>0 {peaks[strings.clone(file.name,allocator)]=bytes}
    }
    return peaks
}

// Where the peak of a compilation of key is kept.
@(private)
peak_path :: proc(shared,key:string,allocator:=context.allocator) -> string {
    return path_join(shared,CACHE_PEAKS,key,allocator=allocator)
}

@(private)
peak_write :: proc(path:string,bytes:i64) {
    _=write_file_atomic(path,transmute([]u8)fmt.tprintf("%d\n",bytes))
}
@(private)
CODE_EXTENSIONS :: [Backend]string{.Vulkan=".spv",.Metal=".metal"}

// The file of the entry of a digest for a generation of these backends: one
// that takes no code has its own, so an entry compiled only to be reflected
// is never taken or completed by one that takes code.
@(private)
cache_stage_path :: proc(shared,digest:string,backends:Backends) -> string {
    name:=strings.concatenate({digest,REFLECTED if reflected_only(backends) else "",".json"},context.temp_allocator)
    return path_join(shared,CACHE_STAGES,name,allocator=context.temp_allocator)
}

// The entry of a digest in the shared cache with the code of every backend
// asked for, each file what its hash says; false otherwise.
@(private)
cache_stage_read :: proc(shared,digest:string,backends:Backends,allocator:=context.allocator) -> (entry:Shader,files:[Backend][]u8,ok:bool) {
    folder:=path_join(shared,CACHE_STAGES,allocator=context.temp_allocator)
    path:=cache_stage_path(shared,digest,backends)
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
    path:=cache_stage_path(shared,shader.fingerprint,backends)
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
    for folder in ([]string{CACHE_STAGES,CACHE_REFLECTION,CACHE_EMBEDDED,CACHE_PEAKS}) {
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
