package build

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import si "core:sys/info"
import "core:time"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

Severity :: enum u8 {Error,Warning}

// A message of the compiler about a place in a source.
Diagnostic :: struct {
    severity:Severity,
    file:string, // absolute, with forward slashes
    line,column:int,
    message:string,
}

// What each process of the compiler may commit. Past it LLVM stops saying it
// ran out of memory, instead of taking the memory of the machine as a
// multiple assignment of a large value makes it do (odin-lang/Odin#7937).
// COMPILER_MEMORY_ENV sets it in GiB, 0 for none; by default it is half the
// memory of the machine within COMPILER_MEMORY_LEAST and COMPILER_MEMORY_MOST,
// above the 3.2 GB of the largest build (a library of the engine at -o:speed).
// macOS has no reliable cap for another process: there it is none.
COMPILER_MEMORY_ENV :: "MIRAI_COMPILER_MEMORY"
COMPILER_MEMORY_LEAST :: 4<<30
COMPILER_MEMORY_MOST :: 8<<30

// The cap of each process of the compiler, in bytes (0: none); ok is false
// when COMPILER_MEMORY_ENV is not a number of GiB, and bytes is then the default.
compiler_memory :: proc() -> (bytes:u64,ok:bool) {
    value,set:=os.lookup_env(COMPILER_MEMORY_ENV,context.temp_allocator)
    total,_,_,_,known:=si.ram_stats()
    bytes,ok=compiler_memory_of(value,set,known?total:0)
    when ODIN_OS==.Darwin {bytes=0}
    return
}

// What a compiler started now may use: compiler_memory, at low priority
// while a measurement this process is not part of runs
// (workspace.measurement_running), so that it disturbs it as little as it can.
compiler_limits :: proc(root:string) -> subprocess.Limits {
    memory,_:=compiler_memory()
    measured,_:=workspace.measurement_running(root,context.temp_allocator)
    return {memory=memory,priority=.Low if measured else .Normal}
}

@(private)
compiler_memory_of :: proc(value:string,set:bool,total_ram:i64) -> (bytes:u64,ok:bool) {
    bytes=COMPILER_MEMORY_MOST
    if total_ram>0 {bytes=clamp(u64(total_ram)/2,COMPILER_MEMORY_LEAST,COMPILER_MEMORY_MOST)}
    if !set || value=="" {return bytes,true}
    gib,parsed:=strconv.parse_f64(strings.trim_space(value))
    if !parsed || !(gib>=0) || gib>1<<20 {return bytes,false}
    return u64(gib*(1<<30)),true
}

// How many compilers a job runs at once, each a library of a plugin: one per
// physical core, as many as the memory available holds at COMPILER_MEMORY_EACH,
// at least one. COMPILERS_ENV sets it. Optimized, a library is one module that
// LLVM compiles on one thread.
COMPILERS_ENV :: "MIRAI_COMPILERS"
// Above what the largest library of a plugin takes at -o:speed.
COMPILER_MEMORY_EACH :: 2<<30

compilers_at_once :: proc() -> int {
    value,set:=os.lookup_env(COMPILERS_ENV,context.temp_allocator)
    physical,logical,counted:=si.cpu_core_count()
    total,free,_,_,known:=si.ram_stats()
    // macOS does not say what is free.
    available:=free>0?free:total/2
    count,_:=compilers_at_once_of(value,set,counted?(physical>0?physical:logical):1,known?available:0)
    return count
}

// cores: physical. available: bytes of memory free, 0 when unknown. ok is
// false when value is not a count, and count is then the default.
@(private)
compilers_at_once_of :: proc(value:string,set:bool,cores:int,available:i64) -> (count:int,ok:bool) {
    count=max(cores,1)
    if available>0 {count=clamp(int(available/COMPILER_MEMORY_EACH),1,count)}
    if !set || value=="" {return count,true}
    parsed,parsed_ok:=strconv.parse_int(strings.trim_space(value),10)
    if !parsed_ok || parsed<1 {return count,false}
    return parsed,true
}

// Whether what the compiler said is that it went past compiler_memory.
compiler_out_of_memory :: proc(text:string) -> bool {
    return strings.contains(text,COMPILER_OUT_OF_MEMORY)
}

// What LLVM says when an allocation fails.
COMPILER_OUT_OF_MEMORY :: "LLVM ERROR: out of memory"

// Whether the compiler ended by a fault rather than by exiting: an exception
// on Windows, SIGABRT or SIGSEGV elsewhere. Out of memory outside LLVM it
// ends like this and says nothing.
compiler_crashed :: proc(exit_code:int) -> bool {
    when ODIN_OS==.Windows {return u32(exit_code)>=0xC0000000} else {return exit_code==6 || exit_code==11}
}

// What to tell of a compiler that failed without saying anything: how it
// ended and, when it crashed within a cap of memory, that the cap may be lower
// than what the build needs.
compiler_silent_failure :: proc(exit_code:int,allocator:=context.allocator) -> string {
    memory,_:=compiler_memory()
    if compiler_crashed(exit_code) && memory>0 {
        return fmt.aprintf("the compiler crashed without a message (exit 0x%X); within its cap of %.1f GiB it ends like this when it runs out of memory outside LLVM: raise %s if the build needs more",u32(exit_code),f64(memory)/(1<<30),COMPILER_MEMORY_ENV,allocator=allocator)
    }
    return fmt.aprintf("the compiler said nothing and exited with %d (0x%X)",exit_code,u32(exit_code),allocator=allocator)
}

// The release of the Odin compiler the engine is developed with.
ODIN_RELEASE :: "dev-2026-11"

// The Odin compiler as the mirai tool finds it: MIRAI_ODIN, which is a file
// or a name to look for in PATH; the one pinned under the deps of root
// (workspace.deps_folder: also from a worktree); or `odin` in PATH. An
// installed engine compiles with the one its binaries were built with,
// whatever MIRAI_ODIN says. With forward slashes.
compiler_find :: proc(root:string,allocator:=context.allocator) -> (path:string,ok:bool) {
    if project.engine_installed(root) {
        if pinned,pinned_found:=workspace.deps_compiler(root,allocator);pinned_found {return pinned,true}
    }
    name:="odin"
    if configured,found:=os.lookup_env("MIRAI_ODIN",context.temp_allocator);found && configured!="" {
        if strings.contains_any(configured,"/\\") {return slashes(configured,allocator),os.is_file(configured)}
        name=configured
    } else if root!="" {
        if pinned,pinned_found:=workspace.deps_compiler(root,allocator);pinned_found {return pinned,true}
    }
    search,_:=os.lookup_env("PATH",context.temp_allocator)
    directories,_:=os.split_path_list(search,context.temp_allocator)
    for directory in directories {
        if directory=="" {continue}
        for extension in ([2]string{"",project.EXECUTABLE_SUFFIX}) {
            candidate:=strings.concatenate({strings.trim_right(directory,"/\\"),"/",name,extension},context.temp_allocator)
            if os.is_file(candidate) {return slashes(candidate,allocator),true}
        }
    }
    return "",false
}

// Whether what links against a library links against an import library made
// from its declarations before it compiles, and so compiles beside it: on
// Windows. Elsewhere a shared library links against the others themselves
// and waits for them.
@(private)
IMPORT_LIBRARIES_AHEAD :: ODIN_OS==.Windows

// Makes the import libraries of libraries from the module definitions
// declare wrote, {definition, import library} each, with the linker the
// compiler carries, all at once. Returns the one that could not be made; ""
// when all were.
@(private)
import_libraries_make :: proc(compiler:string,made:[][2]string) -> string {
    when !IMPORT_LIBRARIES_AHEAD {return ""}
    linker:=strings.concatenate({compiler[:max(strings.last_index_byte(compiler,'/'),0)],"/bin/lld-link.exe"},context.temp_allocator)
    processes:=make([dynamic]subprocess.Process,0,len(made),context.temp_allocator)
    failed:=""
    for pair in made {
        process,error:=subprocess.start({command={linker,"/lib","/nologo","/machine:x64",fmt.tprintf("/def:%s",pair[0]),fmt.tprintf("/out:%s",pair[1])}})
        if error!=nil {
            failed=pair[1]
            break
        }
        append(&processes,process)
    }
    for &process,i in processes {
        state,error:=subprocess.wait(&process)
        if failed=="" && (error!=nil || state.exit_code!=0) {failed=made[i][1]}
    }
    return failed
}

@(private)
slashes :: proc(path:string,allocator:runtime.Allocator) -> string {
    result,_:=strings.replace_all(path,"\\","/",allocator)
    return strings.clone(result,allocator) if raw_data(result)==raw_data(path) else result
}

// Writes text to a file unless it already holds it: what did not change keeps
// its date. changed: the file was written.
@(private)
write_changed :: proc(path,text:string) -> (changed:bool,error:os.Error) {
    if data,read_error:=os.read_entire_file(path,context.temp_allocator);read_error==nil && string(data)==text {return false,nil}
    if error=os.write_entire_file(path,text);error!=nil {return false,error}
    return true,nil
}

// The flags of MIRAI_ODIN_FLAGS, which every build of the mirai tool carries.
@(private)
environment_flags :: proc(out:^[dynamic]string,allocator:runtime.Allocator) {
    extra,found:=os.lookup_env("MIRAI_ODIN_FLAGS",context.temp_allocator)
    if !found {return}
    for flag in strings.fields(extra,context.temp_allocator) {append(out,strings.clone(flag,allocator))}
}

// What `odin build -json-errors` wrote to its error stream: its diagnostics,
// and whatever else it printed there (the linker is not structured).
@(private)
diagnostics_parse :: proc(output:string,allocator:runtime.Allocator) -> (diagnostics:[]Diagnostic,rest:string) {
    Position :: struct {file:string,line,column:int}
    Entry :: struct {type:string,pos:Position,msgs:[]string}
    Report :: struct {errors:[]Entry}
    first:=strings.index(output,"{")
    last:=strings.last_index(output,"}")
    report:Report
    if first<0 || last<first || json.unmarshal_string(output[first:last+1],&report,allocator=context.temp_allocator)!=nil {
        return nil,strings.clone(strings.trim_space(output),allocator)
    }
    list:=make([dynamic]Diagnostic,0,len(report.errors),allocator)
    for entry in report.errors {
        message:=strings.join(entry.msgs,"\n",context.temp_allocator)
        append(&list,Diagnostic{
            severity=entry.type=="warning"?.Warning:.Error,
            file=strings.clone(entry.pos.file,allocator),
            line=entry.pos.line,column=entry.pos.column,
            message=strings.clone(strings.trim_space(message),allocator),
        })
    }
    outside:=strings.concatenate({output[:first],output[last+1:]},context.temp_allocator)
    return list[:],strings.clone(strings.trim_space(outside),allocator)
}

// The sources a build read, as the compiler exported them.
@(private)
dependencies_read :: proc(file:string,allocator:runtime.Allocator) -> (sources:[]string,ok:bool) {
    Export :: struct {source_files,load_files:[]string}
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return nil,false}
    export:Export
    if json.unmarshal(data,&export,allocator=context.temp_allocator)!=nil {return nil,false}
    list:=make([dynamic]string,0,len(export.source_files)+len(export.load_files),allocator)
    for group in ([2][]string{export.source_files,export.load_files}) {
        for source in group {append(&list,strings.clone(source,allocator))}
    }
    return list[:],true
}

// Whether an Odin file that is no test, of a folder under root that the build
// of output read a source from, or a file it loaded, changed after output was
// written, or a source it read is gone. known is false when the list the
// compiler exported for it cannot be read or output does not exist.
sources_newer :: proc(sources_file,output,root:string) -> (newer,known:bool) {
    // The compiler lists its sources with forward slashes, whatever the root was given with.
    root:=slashes(root,context.temp_allocator)
    built,stat_error:=os.modification_time_by_path(output)
    if stat_error!=nil {return false,false}
    sources:=dependencies_read(sources_file,context.temp_allocator) or_return
    inside :: proc(file,root:string) -> bool {
        return len(file)>len(root) && file[len(root)]=='/' && project.path_same(file[:len(root)],root)
    }
    folders:=make(map[string]bool,context.temp_allocator)
    for source in sources {
        if !inside(source,root) {continue}
        slash:=strings.last_index_byte(source,'/')
        if strings.has_suffix(source,".odin") {
            folders[source[:slash]]=true
            if !os.is_file(source) {return true,true}
        } else if changed,error:=os.modification_time_by_path(source);error!=nil || time.diff(built,changed)>0 {
            return true,true
        }
    }
    for folder in folders {
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {return true,true}
        for entry in entries {
            if !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
            if time.diff(built,entry.modification_time)>0 {return true,true}
        }
    }
    return false,true
}

// Identity of a build: the compiler, its flags, and the non-test Odin files
// of every folder the last build read a source from, by name and content, so
// a file added to a package counts and a checkout or a merge that leaves the
// sources as they were does not. A path under root counts relative to it: the
// same sources in another checkout of the repository give the same identity.
// Flags that only change how fast the compiler runs do not count. The
// libraries next to the compiler are the compiler: their folders are not
// read. latest is the newest modification among those files. The sources
// under masked count with the names of the plugin libraries in their foreign
// imports masked (link_names_mask): what tells a compile from a link (relink.odin).
// tests: the build is of tests, which also reads the _test.odin files.
@(private)
fingerprint :: proc(root,compiler:string,flags:[]string,sources:[]string,masked:="",tests:=false) -> (hash:u64,latest:time.Time) {
    root:=slashes(root,context.temp_allocator)
    masked:=slashes(masked,context.temp_allocator)
    file_mix :: proc(hash:u64,name,path:string,latest:^time.Time,masked:string) -> u64 {
        hash:=base.hash_combine(hash,base.name_hash(name))
        if latest!=nil {
            if changed,error:=os.modification_time_by_path(path);error==nil && time.diff(latest^,changed)>0 {latest^=changed}
        }
        data,error:=os.read_entire_file(path,context.temp_allocator)
        if error!=nil {return base.hash_combine(hash,0)}
        // Checkouts of the same commit can differ in their line endings.
        kept:=0
        for b in data {
            if b!='\r' {data[kept]=b;kept+=1}
        }
        if masked!="" && len(path)>len(masked) && path[len(masked)]=='/' && project.path_same(path[:len(masked)],masked) {link_names_mask(data[:kept])}
        return base.hash_combine(hash,xxhash.XXH3_64_default(data[:kept]))
    }
    // The compiler counts by its file, wherever it is reached from.
    if info,error:=os.stat(compiler,context.temp_allocator);error==nil {
        hash=base.hash_combine(base.hash_combine(hash,u64(info.size)),compiler_date(root,compiler,info.modification_time))
    }
    for flag in flags {
        if strings.has_prefix(flag,"-thread-count:") {continue}
        hash=base.hash_combine(hash,base.name_hash(root_relative(flag,root)))
    }
    folders:=make(map[string]bool,context.temp_allocator)
    compiler_folder:=compiler[:max(strings.last_index_byte(compiler,'/'),0)]
    for source in sources {
        if compiler_folder!="" && len(source)>len(compiler_folder) && source[len(compiler_folder)]=='/' && project.path_same(source[:len(compiler_folder)],compiler_folder) {continue}
        if slash:=strings.last_index_byte(source,'/');slash>0 && strings.has_suffix(source,".odin") {
            folders[source[:slash]]=true
            continue
        }
        // What a source loads with #load.
        hash=file_mix(hash,root_relative(source,root),source,&latest,masked)
    }
    listed,_:=slice.map_keys(folders,context.temp_allocator)
    slice.sort(listed)
    for folder in listed {
        hash=base.hash_combine(hash,base.name_hash(root_relative(folder,root)))
        if !os.is_dir(folder) {continue}
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {continue}
        slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        for entry in entries {
            if strings.has_suffix(entry.name,".odin") && (tests || !strings.has_suffix(entry.name,"_test.odin")) {hash=file_mix(hash,entry.name,slashes(entry.fullpath,context.temp_allocator),&latest,masked)}
        }
    }
    return
}

// What tells one build of the compiler from another besides its size: its
// date, or, for the one an installed engine carries, the manifest of the
// engine. Unpacking a package dates its files anew, and the plugin libraries
// it brings were built with that compiler.
@(private)
compiler_date :: proc(root,compiler:string,modified:time.Time) -> u64 {
    if len(compiler)>len(root) && compiler[len(root)]=='/' && project.path_same(compiler[:len(root)],root) && project.engine_installed(root) {
        if manifest,error:=os.read_entire_file(project.path(root,project.ENGINE_FILE,allocator=context.temp_allocator),context.temp_allocator);error==nil {
            return xxhash.XXH3_64_default(manifest)
        }
    }
    return u64(time.to_unix_nanoseconds(modified))
}

// text with root written as <root> where it appears, so that what names a
// path of this checkout names the same one of another.
@(private)
root_relative :: proc(text,root:string) -> string {
    if root=="" {return text}
    slashed:=slashes(text,context.temp_allocator)
    when ODIN_OS==.Windows {
        at:=strings.index(strings.to_lower(slashed,context.temp_allocator),strings.to_lower(root,context.temp_allocator))
    } else {
        at:=strings.index(slashed,root)
    }
    if at<0 {return text}
    return strings.concatenate({slashed[:at],"<root>",slashed[at+len(root):]},context.temp_allocator)
}

// A compiler that runs, with the files its error and output streams go to:
// of a library, a program, the target of a job or a test executable.
@(private)
Compile :: struct {
    process:subprocess.Process,
    streams:[2]string, // its error and output streams
    staged:string,     // what it writes, which it must leave; "": it writes nothing (a check)
    library:int,       // of a job: a plugin library, -1 its target; of the engine: a library, -1 a program
    folder:string,     // of a library: where its objects stay (relink.odin)
    relink:bool,       // it links again the objects of folder
}

// Starts a compiler with its streams going to their files, in the root of the
// engine and within what it may use (compiler_limits). environment nil: that
// of this process. False when a stream cannot be written or it does not start.
@(private)
compile_start :: proc(c:^Compile,root:string,command:[]string,environment:[]string) -> bool {
    streams:[2]^os.File
    for file,i in c.streams {
        stream,error:=os.open(file,{.Write,.Create,.Trunc})
        if error!=nil {
            if i>0 {os.close(streams[0])}
            return false
        }
        streams[i]=stream
    }
    process,error:=subprocess.start({working_dir=root,command=command,env=environment,stderr=streams[0],stdout=streams[1]},compiler_limits(root))
    os.close(streams[0]);os.close(streams[1])
    if error!=nil {return false}
    c.process=process
    return true
}

// What a compiler that ended left in its streams, which it removes: its
// diagnostics, what it said besides them and how it failed: .Compile for an
// error among them, an exit code that is not 0 or no file where it writes,
// .Out_Of_Memory when it ran out. links: the text goes without the calls to
// the linker it printed; output: all it wrote to its error stream.
@(private)
compile_end :: proc(c:^Compile,exit_code:int,allocator:=context.allocator,links:=false) -> (diagnostics:[]Diagnostic,text:string,failure:Failure,output:string) {
    said:[2]string
    for file,i in c.streams {
        data,_:=os.read_entire_file(file,context.temp_allocator)
        said[i]=string(data)
        _=os.remove(file)
    }
    rest:string
    diagnostics,rest=diagnostics_parse(said[0],allocator)
    text=strings.trim_space(strings.concatenate({links?link_calls_strip(rest,context.temp_allocator):rest,"\n",strings.trim_space(said[1])},allocator))
    errors:=exit_code!=0
    for diagnostic in diagnostics {errors||=diagnostic.severity==.Error}
    switch {
    case errors:
        if text=="" && len(diagnostics)==0 && exit_code!=0 {text=compiler_silent_failure(exit_code,allocator)}
        failure=.Out_Of_Memory if compiler_out_of_memory(text) else .Compile
    case c.staged!="" && !os.is_file(c.staged):
        text=fmt.aprintf("the compiler succeeded and %s is missing%s",c.staged,ODIN_OS==.Windows?"; an antivirus may have quarantined it: exclude its folder from real-time scanning":"",allocator=allocator)
        failure=.Compile
    }
    return diagnostics,text,failure,said[0]
}

// Puts what a compiler wrote at staged in place of published. Windows does
// not replace a file a program has loaded, and lets it be renamed: the
// previous one goes to retired first. False when it cannot be replaced.
@(private)
publish :: proc(staged,published,retired:string) -> bool {
    if os.rename(staged,published)==nil {return true}
    return os.rename(published,retired)==nil && os.rename(staged,published)==nil
}

// What a published build is stamped with: the fingerprint of the sources its
// compiler read (fingerprint), with root, compiler, flags and tests.
@(private)
Stamp_Desc :: struct {
    file:string,           // the stamp: the fingerprint and what was published
    sources_file:string,   // what the last build that stamped read
    sources_staged:string, // what this compiler read, which takes the place of sources_file; "": sources_file stands (a link again)
    root,compiler:string,
    flags:[]string,
    tests:bool,
    started:time.Time,     // when the compiler started
}

// Publishes and stamps with what the compiler read. A source saved while it
// ran is not what was built: without the stamp the next build compiles again.
@(private)
publish_and_stamp :: proc(staged,published,retired:string,sources:[]string,stamp:Stamp_Desc) -> (published_ok,stamped:bool) {
    if !publish(staged,published,retired) {return false,false}
    hash,latest:=fingerprint(stamp.root,stamp.compiler,stamp.flags,sources,tests=stamp.tests)
    if stamp.sources_staged!="" {_=os.remove(stamp.sources_file)}
    stamped=len(sources)>0 && time.diff(latest,stamp.started)>0 && (stamp.sources_staged=="" || os.rename(stamp.sources_staged,stamp.sources_file)==nil)
    if stamped {stamped=os.write_entire_file(stamp.file,fmt.tprintf("%x %s",hash,published))==nil}
    if !stamped {
        _=os.remove(stamp.file)
        if stamp.sources_staged!="" {_=os.remove(stamp.sources_staged)}
    }
    return true,stamped
}
