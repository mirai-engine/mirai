package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"

// The game that ships, without the release path: a game-only change compiles
// the game alone. The engine and the active engine plugins that ship are one
// library compiled once per SHIPPED_ENGINE key at -o:speed in one module, and
// the game compiles against their declarations (declare.odin): what is inline
// or generic is copied there and still inlines, and what crosses into the
// library does not inline. --release and the editor's Build compile everything
// together. <project>/.mirai/shipped holds the stage, the declarations, the
// library and the key it was built from; the library is shared between
// checkouts through the cache, the rest every checkout writes from its sources.

@(private)
SHIPPED_ENGINE_NAME :: "mirai-shipped"

@(private)
SHIPPED_ENGINE_ENTRY :: "__mirai_shipped"

// Compile.library of the compiler of this library.
@(private)
SHIPPED_ENGINE_COMPILE :: -2

// How many builds of the library the shared cache keeps, the last used first.
@(private)
SHIPPED_ENGINE_CACHE_ENTRIES :: 16

// What became of the library in a job, for whoever reports it.
Shipped_Engine_State :: enum u8 {None,Current,Restored,Built}

@(private)
Shipped_Engine :: struct {
    stage,stage_plugins,decl,decl_plugins:string,
    library,linked:string,   // the library, and what the game links against
    stamp:string,            // holds the key of what is there
    packages:[]string,       // of the active engine plugins that ship, relative to <engine>/plugins
    flags:[]string,
    key:u64,
    loads:[]string,          // what the key counts as read by #load
    sources_staged:string,
}

@(private)
shipped_engine_paths :: proc(root:string,allocator:=context.allocator) -> (s:Shipped_Engine) {
    context.allocator=allocator
    folder:=project.path(project.folder_path(root,.Generated,context.temp_allocator),"shipped")
    s.stage,s.stage_plugins=project.path(folder,"stage"),project.path(folder,"stage-plugins")
    s.decl,s.decl_plugins=project.path(folder,"decl"),project.path(folder,"decl-plugins")
    s.library=project.path(folder,project.library_file(SHIPPED_ENGINE_NAME,context.temp_allocator))
    s.linked=project.path(folder,library_import_file(SHIPPED_ENGINE_NAME,context.temp_allocator))
    s.stamp=project.path(folder,"engine.key")
    return
}

// The packages of the runtime parts of the active engine plugins a shipped
// game keeps: the development plugins stay out, as they do of its world.
@(private)
shipped_engine_plugins :: proc(p:^project.Project,allocator:=context.allocator) -> []string {
    packages:=make([dynamic]string,allocator)
    parts:=project.PART_NAMES
    sources:=project.path(p.engine_root,"plugins",allocator=context.temp_allocator)
    for index in p.active {
        plugin:=&p.plugins[index]
        if plugin.origin!=.Engine || plugin.manifest.development || .Runtime not_in plugin.manifest.parts {continue}
        part_packages(sources,fmt.tprintf("%s/%s",base.text_get(plugin.manifest.name[:]),parts[.Runtime]),&packages,allocator)
    }
    return packages[:]
}

// What the library is compiled with besides its collections and its output.
@(private)
shipped_engine_flags :: proc(p:^project.Project,allocator:=context.allocator) -> []string {
    flags:=make([dynamic]string,allocator)
    append(&flags,"-build-mode:dll","-o:speed",fmt.aprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES,allocator=allocator))
    for &define in p.manifest.build.defines {
        if text:=base.text_get(define[:]);text!="" {append(&flags,fmt.aprintf("-define:%s",text,allocator=allocator))}
    }
    platform_flags(p.engine_root,&flags,true,allocator)
    environment_flags(&flags,allocator)
    file:=project.library_file(SHIPPED_ENGINE_NAME,context.temp_allocator)
    when ODIN_OS==.Linux {linker_flags_append(&flags,fmt.tprintf("-Wl,-soname,%s",file),allocator)}
    else when ODIN_OS==.Darwin {linker_flags_append(&flags,fmt.tprintf("-Wl,-install_name,@rpath/%s",file),allocator)}
    return flags[:]
}

// Identity of the library: the compiler, the flags (the defines and the
// target are among them), what declare writes, the sources of every package,
// what they load and the static libraries of their folders. The generated
// world and the game are not read: nothing of the engine imports them.
@(private)
shipped_engine_key :: proc(engine_root,compiler:string,flags,engine_packages,plugin_packages:[]string,allocator:=context.allocator) -> (key:u64,loads:[]string) {
    root:=slashes(engine_root,context.temp_allocator)
    plugins:=project.path(root,"plugins",allocator=context.temp_allocator)
    sources:=make([dynamic]string,context.temp_allocator)
    append(&sources,..engine_sources(root,engine_packages))
    append(&sources,..engine_sources(plugins,plugin_packages))
    loaded:=shipped_loads(sources[:],allocator)
    static:=make([dynamic]string,context.temp_allocator)
    for path in engine_packages {shipped_static_libraries(project.path(root,path,allocator=context.temp_allocator),&static)}
    for path in plugin_packages {shipped_static_libraries(project.path(plugins,path,allocator=context.temp_allocator),&static)}
    append(&sources,..loaded)
    append(&sources,..static[:])
    hashed:=make([dynamic]string,context.temp_allocator)
    append(&hashed,..flags)
    append(&hashed,fmt.tprintf("<declare %d>",DECLARE_VERSION))
    key,_=fingerprint(root,slashes(compiler,context.temp_allocator),hashed[:],sources[:])
    return key,loaded
}

// The files the sources name in a #load, resolved from the folder of each
// source and without repeats. A path that is not a literal is not found here:
// shipped_loads_covered says so after the compiler ran.
@(private)
shipped_loads :: proc(sources:[]string,allocator:=context.allocator) -> []string {
    found:=make(map[string]bool,context.temp_allocator)
    list:=make([dynamic]string,allocator)
    for source in sources {
        data,error:=os.read_entire_file(source,context.temp_allocator)
        if error!=nil {continue}
        rest:=string(data)
        for {
            at:=strings.index(rest,"#load")
            if at<0 {break}
            rest=rest[at+len("#load"):]
            open:=strings.index_byte(rest,'"')
            paren:=strings.index_byte(rest,'(')
            if open<0 || paren<0 || paren>open || strings.trim_space(rest[paren+1:open])!="" {continue}
            close:=strings.index_byte(rest[open+1:],'"')
            if close<0 {break}
            relative:=rest[open+1:open+1+close]
            clean,_:=filepath.clean(strings.concatenate({source[:strings.last_index_byte(source,'/')],"/",relative},context.temp_allocator),context.temp_allocator)
            file:=slashes(clean,context.temp_allocator)
            if found[file] {continue}
            found[file]=true
            append(&list,strings.clone(file,allocator))
        }
    }
    return list[:]
}

// Whether every file the compiler loaded besides those of the compiler is
// among those the key counted. When not, the library is good for this build
// and the key does not identify it: it is neither kept nor reused.
@(private)
shipped_loads_covered :: proc(read,loads:[]string,compiler:string) -> bool {
    counted:=make(map[string]bool,context.temp_allocator)
    for file in loads {counted[strings.to_lower(file,context.temp_allocator)]=true}
    folder:=compiler[:max(strings.last_index_byte(compiler,'/'),0)]
    for file in read {
        if strings.has_suffix(file,".odin") {continue}
        if folder!="" && len(file)>len(folder) && file[len(folder)]=='/' && path_equal(file[:len(folder)],folder) {continue}
        if !counted[strings.to_lower(slashes(file,context.temp_allocator),context.temp_allocator)] {return false}
    }
    return true
}

// The static libraries under a package: what its foreign imports link.
@(private="file")
shipped_static_libraries :: proc(folder:string,out:^[dynamic]string) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if entry.type==.Directory {
            if !strings.has_prefix(entry.name,".") && entry.name!="testdata" {shipped_static_libraries(slashes(entry.fullpath,context.temp_allocator),out)}
        } else if strings.has_suffix(entry.name,".lib") || strings.has_suffix(entry.name,".a") {
            append(out,slashes(entry.fullpath,context.temp_allocator))
        }
    }
}

// Leaves the library of the job's key in place, or starts its compile.
@(private)
job_shipped_start :: proc(job:^Job,p:^project.Project,force:bool) -> Failure {
    a:=virtual.arena_allocator(&job.arena)
    s:=&job.shipped
    runtime_packages:=ENGINE_RUNTIME_PACKAGES
    s.packages=shipped_engine_plugins(p,a)
    s.flags=shipped_engine_flags(p,a)
    s.key,s.loads=shipped_engine_key(p.engine_root,job.compiler,s.flags,runtime_packages[:],s.packages,a)
    saved,_,stamped:=stamp_read(s.stamp)
    if !force && stamped && saved==s.key && library_present(s.library,s.linked) && os.is_dir(s.decl) {
        job.result.shipped_engine=.Current
        return .None
    }
    _=os.remove(s.stamp)
    errors,_:=declare({root=p.engine_root,packages=runtime_packages[:],binary="mirai",library=s.linked,stage=s.stage,decl=s.decl})
    if len(errors)==0 && len(s.packages)>0 {
        errors,_=declare({root=project.path(p.engine_root,"plugins",allocator=context.temp_allocator),packages=s.packages,binary="plugins",library=s.linked,stage=s.stage_plugins,decl=s.decl_plugins})
    }
    if len(errors)>0 {
        job.result.text=strings.join(errors,"\n",a)
        return .Generate
    }
    if !shipped_entry_write(s,runtime_packages[:]) {return .Write_Failed}
    if !force && shipped_cache_take(job.engine_root,s) {
        if !shipped_stamp_write(s) {return .Write_Failed}
        job.result.shipped_engine=.Restored
        return .None
    }
    if os.make_directory_all(job.work)!=nil && !os.is_dir(job.work) {return .Write_Failed}
    streams:=[2]string{
        project.path(job.work,fmt.tprintf("%s-engine.err",job.prefix),allocator=a),
        project.path(job.work,fmt.tprintf("%s-engine.out",job.prefix),allocator=a),
    }
    s.sources_staged=project.path(job.work,fmt.tprintf("%s-engine.sources.json",job.prefix),allocator=a)
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,job.compiler,"build",project.path(s.stage,SHIPPED_ENGINE_ENTRY,allocator=context.temp_allocator))
    append(&command,fmt.tprintf("-collection:mirai=%s",s.stage),fmt.tprintf("-collection:plugins=%s",s.stage_plugins),fmt.tprintf("-out:%s",s.library))
    append(&command,..s.flags)
    append(&command,"-json-errors","-export-dependencies:json",fmt.tprintf("-export-dependencies-file:%s",s.sources_staged))
    job_spawn(job,{library=SHIPPED_ENGINE_COMPILE,staged=s.library,streams=streams},command[:])
    return .None
}

// The package the library is built from: it imports every other, of both collections.
@(private="file")
shipped_entry_write :: proc(s:^Shipped_Engine,engine_packages:[]string) -> bool {
    folder:=project.path(s.stage,SHIPPED_ENGINE_ENTRY,allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return false}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintfln(&b,"package %s\n",SHIPPED_ENGINE_ENTRY)
    for path in engine_packages {fmt.sbprintfln(&b,"import _ \"mirai:%s\"",path)}
    for path in s.packages {fmt.sbprintfln(&b,"import _ \"plugins:%s\"",path)}
    _,error:=write_changed(project.path(folder,"library.odin",allocator=context.temp_allocator),strings.to_string(b))
    return error==nil
}

@(private="file")
shipped_stamp_write :: proc(s:^Shipped_Engine) -> bool {
    return os.write_entire_file(s.stamp,fmt.tprintf("%x",s.key))==nil
}

// Takes what the compiler of the library left: its diagnostics, pointed at
// the sources, or the key that says the library stands. A library whose
// loads the key does not cover is not stamped, so the next build compiles it.
@(private)
job_shipped_finish :: proc(job:^Job,compile:Compile,exit_code:int) {
    a:=virtual.arena_allocator(&job.arena)
    s:=&job.shipped
    streams:[2]string
    for file,i in compile.streams {
        data,_:=os.read_entire_file(file,context.temp_allocator)
        streams[i]=string(data)
    }
    rest:string
    job.result.diagnostics,rest=diagnostics_parse(streams[0],a)
    failed:=exit_code!=0 || !library_present(s.library,s.linked)
    plugins:=project.path(job.engine_root,"plugins",allocator=context.temp_allocator)
    for &diagnostic in job.result.diagnostics {
        if strings.has_prefix(diagnostic.file,s.stage_plugins) {diagnostic.file=project.path(plugins,diagnostic.file[len(s.stage_plugins):],allocator=a)}
        else if strings.has_prefix(diagnostic.file,s.stage) {diagnostic.file=project.path(job.engine_root,diagnostic.file[len(s.stage):],allocator=a)}
        if diagnostic.severity==.Error {failed=true}
    }
    if failed {
        job.result.text=strings.trim_space(strings.concatenate({rest,rest!=""?"\n":"",strings.trim_space(streams[1])},a))
        if job.result.text=="" && len(job.result.diagnostics)==0 && exit_code!=0 {job.result.text=compiler_silent_failure(exit_code,a)}
        job_fail(job,.Out_Of_Memory if compiler_out_of_memory(job.result.text) else .Compile)
        return
    }
    job.result.diagnostics=nil
    job.result.shipped_engine=.Built
    read,listed:=dependencies_read(s.sources_staged,context.temp_allocator)
    if listed && shipped_loads_covered(read,s.loads,job.compiler) {
        if !shipped_stamp_write(s) {
            job_fail(job,.Write_Failed)
            return
        }
        shipped_cache_store(job.engine_root,s)
    }
}

@(private)
shipped_cache_entry :: proc(engine_root:string,key:u64) -> string {
    return project.path(workspace.cache_folder(engine_root,"shipped-engine",context.temp_allocator),fmt.tprintf("%x",key),allocator=context.temp_allocator)
}

// The files of a cache entry and where they are published.
@(private="file")
shipped_cache_files :: proc(s:^Shipped_Engine) -> [2][2]string {
    return {
        {project.library_file(SHIPPED_ENGINE_NAME,context.temp_allocator),s.library},
        {library_import_file(SHIPPED_ENGINE_NAME,context.temp_allocator),s.linked},
    }
}

@(private)
shipped_cache_take :: proc(engine_root:string,s:^Shipped_Engine) -> bool {
    entry:=shipped_cache_entry(engine_root,s.key)
    if !cache_entry_complete(entry) {return false}
    parent:=s.library[:strings.last_index_byte(s.library,'/')]
    if os.make_directory_all(parent)!=nil && !os.is_dir(parent) {return false}
    for file in shipped_cache_files(s) {
        if file[0]==project.library_file(SHIPPED_ENGINE_NAME,context.temp_allocator) || ODIN_OS==.Windows {
            if os.copy_file(file[1],project.path(entry,file[0],allocator=context.temp_allocator))!=nil {return false}
        }
    }
    cache_entry_used(entry)
    return true
}

@(private)
shipped_cache_store :: proc(engine_root:string,s:^Shipped_Engine) {
    entry:=shipped_cache_entry(engine_root,s.key)
    staging,fresh:=cache_entry_begin(entry)
    if !fresh {return}
    for file in shipped_cache_files(s) {
        if file[0]!=project.library_file(SHIPPED_ENGINE_NAME,context.temp_allocator) && ODIN_OS!=.Windows {continue}
        if os.copy_file(project.path(staging,file[0],allocator=context.temp_allocator),file[1])!=nil {
            _=os.remove_all(staging)
            return
        }
    }
    cache_entry_commit(entry,staging,SHIPPED_ENGINE_CACHE_ENTRIES)
}

// The library next to the game: its executable loads it from there.
@(private)
shipped_engine_copies :: proc(s:^Shipped_Engine,folder:string,copies:[]Copy,a:=context.allocator) -> []Copy {
    list:=slice.to_dynamic(copies,a)
    append(&list,Copy{s.library,project.path(folder,project.library_file(SHIPPED_ENGINE_NAME,context.temp_allocator),allocator=a),false})
    return list[:]
}
