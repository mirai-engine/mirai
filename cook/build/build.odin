package build

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// Builds of a project. A job generates the world and the main package of
// its target and runs the compiler without blocking; whoever started it polls
// it. The compiler writes into files named after the job, so nothing a
// running program has loaded is touched, and a build that succeeds replaces
// the output of the target in one rename. Everything lives under
// <project>/.mirai:
//
//   gen/                 the generated packages: game_world, editor_world, editor, play, game
//   editor, play         the libraries of the project the editor and the player load (.dll, .so, .dylib)
//   game/                the shipped game, unless another folder is asked for
//   build/               files of the jobs, and of each target the sources
//                        and the fingerprint of its last build

Status :: enum u8 {
    Running,
    Up_To_Date, // nothing the last build read has changed: its output stands
    Built,
    Failed,
}

Failure :: enum u8 {
    None,
    Engine_Missing,   // the project was opened without the root of the engine
    Engine_Incomplete, // an installed engine lacks some of its binaries: Result.text names their folder
    Generate,         // the attributes of the project's packages are wrong: Result.text says how
    Compiler_Missing, // no Odin compiler in MIRAI_ODIN or in PATH
    Shaders,          // the shaders of the engine were not generated: Result.text says why
    Compiler_Failed,  // it could not be started or waited for
    Write_Failed,     // a generated source or a file of the job
    Compile,          // diagnostics, or text when what failed says nothing structured (the linker)
    Out_Of_Memory,    // the compiler went past compiler_memory: Result.text has what it said
    Output_Locked,    // the new file could not replace the previous one
    Output_Invalid,   // Game: the folder asked for is the project
    Engine_Time_Code, // Game: engine-time packages are in the build: Result.engine_time
    Copy_Failed,      // Game: what goes next to the executable
    Settings_Invalid, // Game: a settings file of the engine or of the project cannot be read: Result.text says where
    Cook_Failed,      // Game: the assets could not be cooked: Result.cook says why
    Tests,            // Test: a test failed or the tests did not finish: Result.tests says which
    Cancelled,
}

// What a job does with its target.
Action :: enum u8 {
    Build,
    Check, // the types of the target with its plugins as declared: nothing is compiled, and only generated sources are written
    Test,  // runs the @(test) procedures of a package of the project, compiled against the libraries the target links
}

// What the tests of a Test job did.
Test_Report :: struct {
    compiled:bool,
    total,passed:int,
    failed:[]Test_Failure,
}

Test_Failure :: struct {
    package_name,name:string,
    messages:[]string, // what the test logged at error level and above, with where
}

Desc :: struct {
    project:^project.Project,    // only read by job_start
    target:Target,
    compiler:string,             // empty: compiler_find
    flags:[]string,              // more flags of the compiler, after the ones of platform_flags
    output:string,               // Game: the folder of the shipped game. Empty: <project>/.mirai/game, or <project>/.mirai/server
    server:bool,                 // Game: a dedicated server, the same executable without what is only shown or heard: no icon or shaders, and its cook leaves those kinds behind
    force:bool,                  // build even when nothing changed
    dev:bool,                   // -o:minimal whatever the manifest says: for checking a change, not for shipping
    incremental:bool,           // Game: the engine and its plugins come from one library compiled once per version (shipped.odin), next to the executable; the game alone compiles. Not for what ships: unset, they compile whole with the game
    engine:Engine_Mode,          // the binaries of the engine a library is built against. Keep: ENGINE_MODE_HERE
    action:Action,               // Check and Test: of the Editor or Play target
    test_package:string,         // Test: the folder of the package, absolute
    test_names:[]string,         // Test: the tests to run, by name; empty: all of them
    allocator:runtime.Allocator, // of the job. Unset: context.allocator
}

// Everything it points to belongs to the job.
Result :: struct {
    status:Status,
    failure:Failure,
    output:string,            // the library or the executable, also when it was already built
    diagnostics:[]Diagnostic,
    text:string,              // what the compiler printed besides its diagnostics
    engine_time:[]string,     // .Engine_Time_Code: the folders of the engine-time packages the game reached
    cook:Cook_Report,         // Game: the assets it ships (cook.odin)
    plugins_built:int,        // libraries of plugins it compiled or copied from the shared cache: a program that loaded the previous ones starts again to use them
    plugins_restored:int,     // of those, the ones copied from the cache
    plugins_relinked:int,     // of those, the ones whose objects were linked again (relink.odin)
    relinked:bool,            // the output was linked again from the objects of its last compile
    shipped_engine:Shipped_Engine_State, // Game with Desc.incremental: what became of its engine library
    tests:Test_Report,        // Test
    seconds:f64,
}

Job :: struct {
    result:Result,
    allocator:runtime.Allocator,
    arena:virtual.Arena,
    target:Target,
    action:Action,
    test_package:string,
    test_names:[]string,
    test_report:string,         // Test: the JSON the runner writes
    root,engine_root:string,
    compiler:string,
    flags:[]string,             // what identifies the build besides its sources
    staged:string,              // what the compiler writes
    published:string,           // what a build that succeeds replaces
    work:string,                // <project>/.mirai/build
    prefix:string,              // of the files of this job in work
    stream_files:[2]string,     // the error and the output streams of the compiler of the target
    sources_staged,sources_file,stamp_file:string,
    copies:[]Copy,              // Game: what goes next to the executable
    settings:string,            // Game: its settings file: those of the engine and of the project merged, since it ships without the engine
    cook:Cook_Desc,             // Game: the assets it ships; without assets, a project that has none
    plugin_assets:[dynamic]project.Asset_Folder, // Game: the folders of assets of its active plugins, in cook.plugins
    development:[dynamic]string, // Game: the folders of the active development plugins, which it must not reach
    plugins:[]Plugin_Library,    // the plugin libraries the target links (plugins.odin)
    plugin_hashes:[]u64,
    plugin_compile_hashes:[]u64, // into plugins: what their objects are compiled from (plugin_library_compile_hash), of those that do not stand
    plugin_relink:[]bool,        // into plugins: it links the objects of its last compile again (relink.odin)
    plugin_published:[]bool,     // into plugins: it stands as built, so what links against it may compile
    plugin_queue:[dynamic]int,   // into plugins: the ones to compile that have not started, in order
    plugin_limit:int,            // how many of them compile at once
    link_limit:int,              // how many of them link again at once: a linker takes little memory
    plugin_flags:[]string,
    plugin_cache:bool,           // the libraries go to and come from the shared cache: without debug information, which names the build that made it
    plugin_stored:bool,          // it stored libraries in the shared cache, which it trims once they are all published
    engine_decl:string,
    shipped:Shipped_Engine,      // Game with Desc.incremental (shipped.odin)
    masked:string,               // the declarations of the plugin libraries, which the target reads with their names masked (relink.odin)
    link_file:string,            // the record of the last compile of the target
    compiled:bool,               // linking the target again failed, and it compiles
    force:bool,
    compiles:[dynamic]Compile,   // the compilers running
    started:time.Time,
    tick:time.Tick,
}

@(private)
Copy :: struct {from,to:string,folder:bool}

// A compiler a job runs: of a plugin library, or with library -1 of the target.
@(private)
Compile :: struct {
    process:os.Process,
    library:int,
    staged:string,     // what it writes
    folder:string,     // of a library: where its objects stay (relink.odin)
    relink:bool,       // it links again the objects of folder
    streams:[2]string, // its error and output streams
}

// How long job_wait waits on one compiler before it looks at the others.
@(private)
WAIT_STEP :: 50*time.Millisecond

// Files of jobs that did not finish are removed by a later one once they are this old.
@(private)
STALE_AFTER :: 5*time.Minute

@(private)
OPTIMIZATION_FLAGS :: [project.Optimization]string{
    .Minimal="-o:minimal",.None="-o:none",.Size="-o:size",.Speed="-o:speed",.Aggressive="-o:aggressive",
}

// Generates the root package of the target and starts the compiler, unless
// the output of the last build still stands. Never blocks on the compiler:
// job_poll says when it is done.
job_start :: proc(desc:Desc) -> ^Job {
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    job:=new(Job,allocator)
    job.allocator=allocator
    _=virtual.arena_init_growing(&job.arena)
    a:=virtual.arena_allocator(&job.arena)
    p:=desc.project
    job.target=desc.target
    job.action=desc.action
    job.test_package=strings.clone(desc.test_package,a)
    job.test_names=make([]string,len(desc.test_names),a)
    for name,i in desc.test_names {job.test_names[i]=strings.clone(name,a)}
    job.tick=time.tick_now()
    job.root,job.engine_root=strings.clone(p.root,a),strings.clone(p.engine_root,a)
    names:=TARGET_NAMES
    name:=names[desc.target]
    job.work=project.path(project.folder_path(p.root,.Generated,context.temp_allocator),"build",allocator=a)
    job.prefix=fmt.aprintf("%s-%x-%d",name,u64(time.to_unix_nanoseconds(time.now())),os.get_pid(),allocator=a)
    job.test_report=project.path(job.work,fmt.tprintf("%s.tests.json",job.prefix),allocator=a)
    job.sources_file=project.path(job.work,fmt.tprintf("%s.sources.json",name),allocator=a)
    job.stamp_file=project.path(job.work,fmt.tprintf("%s.stamp",name),allocator=a)
    job.sources_staged=project.path(job.work,fmt.tprintf("%s.sources.json",job.prefix),allocator=a)
    job.link_file=project.path(job.work,fmt.tprintf("%s.link",name),allocator=a)
    job.masked=plugins_decl(p.root,plugins_mode(p,desc.dev),a)
    job.stream_files={
        project.path(job.work,fmt.tprintf("%s.err",job.prefix),allocator=a),
        project.path(job.work,fmt.tprintf("%s.out",job.prefix),allocator=a),
    }

    if p.engine_root=="" || desc.action!=.Build && desc.target==.Game {return job_fail(job,.Engine_Missing)}
    generated,written:=generated_write(p,desc.target)
    if !written {
        if len(generated.errors)>0 {
            job.result.text=strings.join(generated.errors,"\n",a)
            return job_fail(job,.Generate)
        }
        return job_fail(job,.Write_Failed)
    }
    job.published=target_output(p,desc.target,desc.output,a,desc.server)
    if desc.target==.Game && project.path_same(job.published[:strings.last_index_byte(job.published,'/')],p.root) {return job_fail(job,.Output_Invalid)}
    job.staged=project.path(job.work,strings.concatenate({job.prefix,desc.target==.Game?project.EXECUTABLE_SUFFIX:project.LIBRARY_SUFFIX},context.temp_allocator),allocator=a)
    job.result.output=job.published

    if desc.compiler!="" {job.compiler=slashes(desc.compiler,a)}
    else if found,ok:=compiler_find(p.engine_root,a);ok {job.compiler=found}
    else {return job_fail(job,.Compiler_Missing)}
    if desc.target==.Game {
        folder:=job.published[:strings.last_index_byte(job.published,'/')]
        settings_error:project.Error
        layer:project.Settings_Layer
        if job.settings,settings_error,layer=project.settings_merge(p.root,p.engine_root,generated.machine_settings,a);settings_error.code!=.None {
            file:=project.settings_file(layer,p.root,p.engine_root,context.temp_allocator)
            job.result.text=settings_error.code==.Text?fmt.aprintf("%s(%d:%d): %s",file,settings_error.line,settings_error.column,settings_error.detail,allocator=a):fmt.aprintf("%s could not be read",file,allocator=a)
            return job_fail(job,.Settings_Invalid)
        }
        job.copies=game_copies(p,folder,job.compiler,a,desc.server)
        if desc.incremental {
            job.shipped=shipped_engine_paths(p.root,a)
            job.copies=shipped_engine_copies(&job.shipped,folder,job.copies,a)
        }
        job.development=make([dynamic]string,a)
        for index in p.active {
            if p.plugins[index].manifest.development {append(&job.development,strings.clone(p.plugins[index].folder,a))}
        }
        if assets:=project.folder_path(p.root,.Assets,a);os.is_dir(assets) {
            job.cook={assets=assets,output=project.folder_path(folder,.Assets,a),manifest=project.path(p.root,COOK_FILE,allocator=a),texture_cache=project.cache_path(p.root,project.TEXTURE_CACHE,allocator=a),mesh_cache=project.cache_path(p.root,project.MESH_CACHE,allocator=a),root=p.root,server=desc.server,quick=desc.dev,import_program=engine_paths(p.engine_root,desc.engine==.Keep?ENGINE_MODE_HERE:desc.engine,a).import_program,allocator=a}
            job.plugin_assets=make([dynamic]project.Asset_Folder,a)
            for found in project.asset_folders(p,a) {
                if found.prefix!="" {append(&job.plugin_assets,found)}
            }
            job.cook.plugins=job.plugin_assets[:]
        }
    }

    job.flags=target_flags(p,desc.target,desc.flags,a,desc.dev,desc.engine,desc.incremental)
    job.force=desc.force
    job.compiles=make([dynamic]Compile,a)
    if desc.target!=.Game {
        if failure:=job_plugins_plan(job,p,desc);failure!=.None {return job_fail(job,failure)}
    } else if desc.incremental {
        if failure:=job_shipped_start(job,p,desc.force);failure!=.None {return job_fail(job,failure)}
    }
    return job_schedule(job)
}

// Declares the plugin libraries that do not stand and queues their compiles,
// in order: a library's declarations are written before those that compile
// against them are looked at. Those declarations do not wait for the library.
@(private)
job_plugins_plan :: proc(job:^Job,p:^project.Project,desc:Desc) -> Failure {
    a:=virtual.arena_allocator(&job.arena)
    job.plugins=plugin_libraries(p,desc.target,desc.dev,a)
    job.plugin_queue=make([dynamic]int,a)
    job.plugin_hashes=make([]u64,len(job.plugins),a)
    job.plugin_compile_hashes=make([]u64,len(job.plugins),a)
    job.plugin_relink=make([]bool,len(job.plugins),a)
    job.plugin_published=make([]bool,len(job.plugins),a)
    job.plugin_limit=compilers_at_once()
    job.link_limit=links_at_once()
    decl:=plugins_decl(p.root,plugins_mode(p,desc.dev),context.temp_allocator)
    if os.make_directory_all(decl)!=nil && !os.is_dir(decl) {return .Write_Failed}
    libraries:=plugins_libraries_folder(p.root,context.temp_allocator)
    if os.make_directory_all(libraries)!=nil && !os.is_dir(libraries) {return .Write_Failed}
    if len(job.plugins)==0 {return .None}
    job.plugin_flags=plugin_flags(p,desc.dev,a)
    job.plugin_cache=!p.manifest.build.debug
    engine:=engine_paths(p.engine_root,desc.engine==.Keep?ENGINE_MODE_HERE:desc.engine,context.temp_allocator)
    job.engine_decl=strings.clone(engine.decl,a)
    for &lib,i in job.plugins {
        job.plugin_hashes[i]=plugin_library_hash(p,&lib,job.compiler,job.plugin_flags,engine)
        plugin_library_name(p.root,&lib,job.plugin_hashes[i],a)
        saved,_,stamped:=stamp_read(lib.stamp)
        if !desc.force && stamped && saved==job.plugin_hashes[i] && os.is_file(lib.library) {
            job.plugin_published[i]=true
            continue
        }
        if errors:=plugin_library_prepare(p,&lib);len(errors)>0 {
            job.result.text=strings.join(errors,"\n",a)
            return .Generate
        }
        // A check reads the declarations just written; it links nothing.
        if desc.action==.Check {
            job.plugin_published[i]=true
            continue
        }
        // Another checkout built it from the same sources: its declarations
        // are the ones just written, and the library is copied.
        if !desc.force && job.plugin_cache && job_plugin_restore(job,i) {continue}
        // The declarations of what it links against are written by now.
        job.plugin_compile_hashes[i]=plugin_library_compile_hash(p,&lib,job.compiler,job.plugin_flags,engine)
        if !desc.force {
            record,recorded:=link_record_read(plugin_link_file(&lib),context.temp_allocator)
            job.plugin_relink[i]=recorded && link_record_stands(record,job.plugin_compile_hashes[i])
        }
        append(&job.plugin_queue,i)
    }
    return .None
}

// Publishes the library the shared cache has for a part, with its stamp.
// False when it has none or it cannot be published: the part is compiled.
@(private)
job_plugin_restore :: proc(job:^Job,index:int) -> bool {
    lib:=&job.plugins[index]
    if os.make_directory_all(job.work)!=nil && !os.is_dir(job.work) {return false}
    staged:=project.path(job.work,strings.concatenate({job_plugin_name(job,index),project.LIBRARY_SUFFIX},context.temp_allocator),allocator=context.temp_allocator)
    if !plugin_cache_take(job.engine_root,lib,job.plugin_hashes[index],staged) || !job_plugin_publish(job,lib,staged) {return false}
    job_plugin_stamp(job,index)
    job.plugin_published[index]=true
    job.result.plugins_built+=1
    job.result.plugins_restored+=1
    return true
}

// What the job compiles of a library of a plugin is named after the job and
// the index of the library, not its file: the compiler names the object of
// each module after it, and its link does not find an object whose path
// reaches MAX_PATH on Windows (see ODIN_WORKAROUNDS).
@(private)
job_plugin_name :: proc(job:^Job,index:int) -> string {
    return fmt.tprintf("%s-p%d",job.prefix,index)
}

// Puts a library the job left at staged, with its import library on Windows,
// where it is published. A library a program has loaded is renamed out of the
// way first, and removed once it is free.
@(private)
job_plugin_publish :: proc(job:^Job,lib:^Plugin_Library,staged:string) -> bool {
    from:=[2]string{staged,""}
    published:=[2]string{lib.library,""}
    when ODIN_OS==.Windows {
        // What links against the library is a file of its own.
        from[1]=plugin_import_staged(staged)
        published[1]=lib.linked
    }
    for file,i in from {
        if file=="" {continue}
        if os.rename(file,published[i])!=nil {
            retired:=project.path(job.work,fmt.tprintf("%s-%s-%d.old",job.prefix,lib.file,i),allocator=context.temp_allocator)
            if os.rename(published[i],retired)!=nil || os.rename(file,published[i])!=nil {return false}
        }
    }
    return true
}

@(private)
job_plugin_stamp :: proc(job:^Job,index:int) {
    lib:=&job.plugins[index]
    if os.write_entire_file(lib.stamp,fmt.tprintf("%x %s",job.plugin_hashes[index],lib.library))!=nil {_=os.remove(lib.stamp)}
    plugin_library_retire(job.root,lib)
}

// Starts the compiles of the plugin libraries whose dependencies stand, up to
// plugin_limit at once, and once every one stands the target, which may stand
// as it is.
@(private)
job_schedule :: proc(job:^Job) -> ^Job {
    if job.result.status!=.Running {return job}
    job_plugins_start(job)
    if job.result.status==.Running && len(job.compiles)==0 && len(job.plugin_queue)==0 {
        if job.plugin_stored {
            plugin_cache_trim(job.engine_root)
            job.plugin_stored=false
        }
        return job_project_start(job)
    }
    return job
}

// The plugins come dependencies first: with nothing running, the first queued
// has every library it links against.
@(private)
job_plugins_start :: proc(job:^Job) {
    for i:=0;i<len(job.plugin_queue); {
        index:=job.plugin_queue[i]
        compiling,linking:=0,0
        for compile in job.compiles {
            if compile.relink {linking+=1} else {compiling+=1}
        }
        room:=linking<job.link_limit if job.plugin_relink[index] else compiling<job.plugin_limit
        if len(job.compiles)>0 && (!room || !job_plugin_ready(job,index)) {
            i+=1
            continue
        }
        ordered_remove(&job.plugin_queue,i)
        if !job_plugin_spawn(job,index) {return}
    }
}

// Whether every library a plugin library links against is published: on
// Windows it links against their import libraries.
@(private)
job_plugin_ready :: proc(job:^Job,index:int) -> bool {
    needs:=job.plugins[index].needs
    for &other,i in job.plugins {
        if i==index || job.plugin_published[i] {continue}
        for path in other.packages {
            if slice.contains(needs,path) {return false}
        }
    }
    return true
}

@(private)
job_plugin_spawn :: proc(job:^Job,index:int) -> bool {
    lib:=&job.plugins[index]
    a:=virtual.arena_allocator(&job.arena)
    if os.make_directory_all(job.work)!=nil && !os.is_dir(job.work) {
        job_fail(job,.Write_Failed)
        return false
    }
    name:=job_plugin_name(job,index)
    streams:=[2]string{
        project.path(job.work,fmt.tprintf("%s.err",name),allocator=a),
        project.path(job.work,fmt.tprintf("%s.out",name),allocator=a),
    }
    // What it compiles to is what the last compile left but for the names
    // of what it links against: it links that again.
    if job.plugin_relink[index] {
        if record,ok:=link_record_read(plugin_link_file(lib),a);ok && link_record_stands(record,job.plugin_compile_hashes[index]) {
            compile:=Compile{library=index,staged=link_staged(record.folder,a),folder=record.folder,relink=true,streams=streams}
            link_outputs_remove(compile.staged)
            command:=link_command_args(link_command_rename(record.command,job_link_names(job),context.temp_allocator),context.temp_allocator)
            return job_spawn(job,compile,command,lib.stage)
        }
        job.plugin_relink[index]=false
    }
    folder:=project.path(objects_root(job.root,context.temp_allocator),name,allocator=a)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {
        job_fail(job,.Write_Failed)
        return false
    }
    compile:=Compile{library=index,staged=link_staged(folder,a),folder=folder,streams=streams}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,..plugin_command(lib,job.compiler,job.engine_decl,compile.staged,job.plugin_flags,context.temp_allocator))
    keep:=LINK_KEEP_FLAGS
    append(&command,..keep[:])
    return job_spawn(job,compile,command[:],lib.stage)
}

// The name of now of every plugin library of the job, by its family: what
// the command of a linker that ran before names otherwise.
@(private)
job_link_names :: proc(job:^Job) -> map[string]string {
    names:=make(map[string]string,context.temp_allocator)
    for &lib in job.plugins {
        if lib.file!="" {names[lib.family]=lib.file}
    }
    return names
}

// Removes what a link leaves before it links again: the library and its
// import library on Windows.
@(private)
link_outputs_remove :: proc(staged:string) {
    _=os.remove(staged)
    when ODIN_OS==.Windows {_=os.remove(plugin_import_staged(staged))}
}

// Runs a compiler with its streams, in working_dir (empty: where this process is).
@(private)
job_spawn :: proc(job:^Job,compile:Compile,command:[]string,working_dir:="",environment:[]string=nil) -> bool {
    streams:[2]^os.File
    for file,i in compile.streams {
        stream,error:=os.open(file,{.Write,.Create,.Trunc})
        if error!=nil {
            if i>0 {os.close(streams[0])}
            job_fail(job,.Write_Failed)
            return false
        }
        streams[i]=stream
    }
    if job.started=={} {job.started=time.now()}
    env:=environment!=nil?environment:child_environment(job.engine_root,context.temp_allocator)
    process,error:=subprocess.start({command=command,working_dir=working_dir,env=env,stderr=streams[0],stdout=streams[1]},compiler_limits(job.engine_root))
    os.close(streams[0]);os.close(streams[1])
    if error!=nil {
        job_fail(job,.Compiler_Failed)
        return false
    }
    running:=compile
    running.process=process
    append(&job.compiles,running)
    return true
}

// The library of the project, unless what its last build read is as it was.
@(private)
job_project_start :: proc(job:^Job) -> ^Job {
    if job.action!=.Build {return job_probe_start(job)}
    if !job.force {
        if saved,built,stamped:=stamp_read(job.stamp_file);stamped {
            if sources,listed:=dependencies_read(job.sources_file,context.temp_allocator);listed {
                current,_:=fingerprint(job.engine_root,job.compiler,job.flags,sources)
                present:=current==saved && os.is_file(job.published)
                // The game built for another folder is the same executable.
                if current==saved && !present && job.target==.Game && built!="" && !project.path_same(built,job.published) && os.is_file(built) {
                    folder:=job.published[:strings.last_index_byte(job.published,'/')]
                    present=(os.make_directory_all(folder)==nil || os.is_dir(folder)) && os.copy_file(job.published,built)==nil
                }
                if present {
                    job.result.status=.Up_To_Date
                    if job.target==.Game {
                        if failure:=job_ship(job);failure!=.None {return job_fail(job,failure)}
                    }
                    return job_done(job)
                }
                // What the library compiles to is what its last compile
                // left but for the names of the plugin libraries: it links that again.
                if job.target!=.Game && !job.compiled {
                    masked,_:=fingerprint(job.engine_root,job.compiler,job.flags,sources,masked=job.masked)
                    if record,ok:=link_record_read(job.link_file,virtual.arena_allocator(&job.arena));ok && link_record_stands(record,masked) {
                        a:=virtual.arena_allocator(&job.arena)
                        compile:=Compile{library=-1,staged=link_staged(record.folder,a),folder=record.folder,relink=true,streams=job.stream_files}
                        link_outputs_remove(compile.staged)
                        command:=link_command_args(link_command_rename(record.command,job_link_names(job),context.temp_allocator),context.temp_allocator)
                        job.started=time.now()
                        job_spawn(job,compile,command)
                        return job
                    }
                }
            }
        }
    }
    if os.make_directory_all(job.work)!=nil && !os.is_dir(job.work) {return job_fail(job,.Write_Failed)}
    compile:=Compile{library=-1,staged=job.staged,streams=job.stream_files}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,job.compiler)
    append(&command,..job.flags)
    // A library keeps its objects, to be linked again (relink.odin).
    if job.target!=.Game {
        a:=virtual.arena_allocator(&job.arena)
        compile.folder=project.path(objects_root(job.root,context.temp_allocator),job.prefix,allocator=a)
        if os.make_directory_all(compile.folder)!=nil && !os.is_dir(compile.folder) {return job_fail(job,.Write_Failed)}
        compile.staged=link_staged(compile.folder,a)
        keep:=LINK_KEEP_FLAGS
        append(&command,..keep[:])
    }
    append(&command,fmt.tprintf("-out:%s",compile.staged),"-json-errors","-export-dependencies:json",fmt.tprintf("-export-dependencies-file:%s",job.sources_staged))
    // What is saved from here on is not what this job builds.
    job.started=time.now()
    job_spawn(job,compile,command[:])
    return job
}

// The compiler that checks the target, or that builds and runs the tests of
// a package against what the target links.
@(private)
job_probe_start :: proc(job:^Job) -> ^Job {
    if os.make_directory_all(job.work)!=nil && !os.is_dir(job.work) {return job_fail(job,.Write_Failed)}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,job.compiler)
    environment:[]string
    if job.action==.Check {
        append(&command,"check",job.flags[1])
        // What only a build reads, odin check refuses.
        for flag in job.flags[2:] {
            if flag=="-build-mode:dll" || flag=="-use-separate-modules" || strings.has_prefix(flag,"-o:") {continue}
            append(&command,flag)
        }
        // The library has no main of its own.
        append(&command,"-no-entry-point","-json-errors")
    } else {
        append(&command,"test",job.test_package)
        for flag in job.flags[2:] {
            if flag=="-build-mode:dll" {continue}
            append(&command,flag)
        }
        _=os.remove(job.test_report)
        append(&command,fmt.tprintf("-out:%s",job.staged),"-json-errors",fmt.tprintf("-define:ODIN_TEST_JSON_REPORT=%s",job.test_report),"-define:ODIN_TEST_FANCY=false")
        if len(job.test_names)>0 {append(&command,fmt.tprintf("-define:ODIN_TEST_NAMES=%s",strings.join(job.test_names,",",context.temp_allocator)))}
        engine:=engine_paths(job.engine_root,.Keep,context.temp_allocator)
        environment=child_environment(job.engine_root,context.temp_allocator,{engine.folder,plugins_libraries_folder(job.root,context.temp_allocator)})
    }
    job.started=time.now()
    job_spawn(job,{library=-1,staged=job.staged,streams=job.stream_files},command[:],environment=environment)
    return job
}

// What a compiler left in the files of its streams: job.result.diagnostics,
// the text it wrote besides them, whether a diagnostic is an error and all it
// wrote to its error stream, for the frame. links: the text goes without the
// calls to the linker it printed.
@(private)
job_compile_read :: proc(job:^Job,files:[2]string,links:=false) -> (text:string,errors:bool,output:string) {
    a:=virtual.arena_allocator(&job.arena)
    streams:[2]string
    for file,i in files {
        data,_:=os.read_entire_file(file,context.temp_allocator)
        streams[i]=string(data)
    }
    rest:string
    job.result.diagnostics,rest=diagnostics_parse(streams[0],a)
    text=strings.trim_space(strings.concatenate({links?link_calls_strip(rest,context.temp_allocator):rest,rest!=""?"\n":"",strings.trim_space(streams[1])},a))
    for diagnostic in job.result.diagnostics {
        if diagnostic.severity==.Error {errors=true}
    }
    return text,errors,streams[0]
}

// Ends the job with what its compiler said, or says that it said nothing.
@(private)
job_compile_fail :: proc(job:^Job,exit_code:int) {
    if job.result.text=="" && len(job.result.diagnostics)==0 && exit_code!=0 {job.result.text=compiler_silent_failure(exit_code,virtual.arena_allocator(&job.arena))}
    job_fail(job,.Out_Of_Memory if compiler_out_of_memory(job.result.text) else .Compile)
}

// Takes what the compiler of a check or of the tests left.
@(private)
job_probe_finish :: proc(job:^Job,exit_code:int) {
    a:=virtual.arena_allocator(&job.arena)
    streams:[2]string
    for file,i in job.stream_files {
        data,_:=os.read_entire_file(file,context.temp_allocator)
        streams[i]=string(data)
    }
    report:=&job.result.tests
    report.compiled=job.action==.Test && os.is_file(job.staged)
    if report.compiled {
        job.result.text=strings.trim_space(strings.concatenate({streams[0],streams[0]!=""?"\n":"",streams[1]},a))
        if !tests_report_read(job.test_report,job.result.text,report,a) || report.passed<report.total {
            job_fail(job,.Tests)
            return
        }
        job.result.status=.Built
        job_files_remove(job)
        job_done(job)
        return
    }
    errors:bool
    job.result.text,errors,_=job_compile_read(job,job.stream_files)
    if errors || exit_code!=0 {
        job_compile_fail(job,exit_code)
        return
    }
    job.result.status=.Built
    job_files_remove(job)
    job_done(job)
}

// Reads what the runner of core:testing wrote of every test and, for those
// that failed, the lines of its log at error level or above that name them.
// False when it wrote nothing: the tests did not finish.
@(private)
tests_report_read :: proc(path,log:string,report:^Test_Report,allocator:runtime.Allocator) -> bool {
    Test :: struct {name:string,success:bool}
    Written :: struct {packages:map[string][dynamic]Test,total,success:int}
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return false}
    written:Written
    if json.unmarshal(data,&written,allocator=context.temp_allocator)!=nil {return false}
    report.total,report.passed=written.total,written.success
    failed:=make([dynamic]Test_Failure,allocator)
    for package_name,tests in written.packages {
        for test in tests {
            if test.success {continue}
            messages:=make([dynamic]string,allocator)
            needle:=fmt.tprintf(":%s()]",test.name)
            rest:=log
            for line in strings.split_lines_iterator(&rest) {
                if !strings.contains(line,needle) || !(strings.contains(line,"[ERROR]") || strings.contains(line,"[FATAL]")) {continue}
                append(&messages,strings.clone(strings.trim_space(line),allocator))
            }
            append(&failed,Test_Failure{strings.clone(package_name,allocator),strings.clone(test.name,allocator),messages[:]})
        }
    }
    report.failed=failed[:]
    return true
}

// Takes what the compile of a plugin library left: its diagnostics, pointed
// at the sources, or the library in place with its stamp.
@(private)
job_plugin_finish :: proc(job:^Job,compile:Compile,exit_code:int) {
    a:=virtual.arena_allocator(&job.arena)
    lib:=&job.plugins[compile.library]
    text,errors,output:=job_compile_read(job,compile.streams,links=true)
    sources:=project.path(job.engine_root,"plugins",allocator=context.temp_allocator)
    failed:=errors || exit_code!=0 || !os.is_file(compile.staged)
    for &diagnostic in job.result.diagnostics {
        if strings.has_prefix(diagnostic.file,lib.stage) {diagnostic.file=project.path(sources,diagnostic.file[len(lib.stage):],allocator=a)}
    }
    if failed && compile.relink {
        // The objects do not link again: it compiles.
        job.result.diagnostics=nil
        job.plugin_relink[compile.library]=false
        link_record_remove(plugin_link_file(lib))
        inject_at(&job.plugin_queue,0,compile.library)
        return
    }
    if failed {
        remove_later({compile.folder})
        job.result.text=text
        job_compile_fail(job,exit_code)
        return
    }
    job.result.diagnostics=nil
    if !job_plugin_publish(job,lib,compile.staged) {
        job_fail(job,.Output_Locked)
        return
    }
    if compile.relink {
        job.result.plugins_relinked+=1
    } else if command,found:=link_command_find(output);found {
        link_folder_trim(compile.folder)
        link_record_write(plugin_link_file(lib),{hash=job.plugin_compile_hashes[compile.library],folder=compile.folder,command=command})
    } else {
        remove_later({compile.folder})
        link_record_remove(plugin_link_file(lib))
    }
    job_plugin_stamp(job,compile.library)
    job.plugin_published[compile.library]=true
    // What links again goes to the shared cache with the library it was
    // compiled as: linking it again takes less than storing it.
    if job.plugin_cache && !compile.relink {
        plugin_cache_store(job.engine_root,lib,job.plugin_hashes[compile.library])
        job.plugin_stored=true
    }
    job.result.plugins_built+=1
}

// Takes what every compiler that ended left and starts what may start then.
// wait: blocks until one ends. True once the job is over.
@(private)
job_advance :: proc(job:^Job,wait:bool) -> bool {
    if job.result.status!=.Running {return true}
    timeout:time.Duration
    if wait {timeout=len(job.compiles)==1?os.TIMEOUT_INFINITE:WAIT_STEP}
    for i:=0;i<len(job.compiles) && job.result.status==.Running; {
        state,error:=os.process_wait(job.compiles[i].process,i==0?timeout:0)
        if !state.exited {
            if general,is_general:=error.(os.General_Error);is_general && general==.Timeout {
                i+=1
                continue
            }
            job_fail(job,.Compiler_Failed)
            break
        }
        compile:=job.compiles[i]
        ordered_remove(&job.compiles,i)
        if compile.library==SHIPPED_ENGINE_COMPILE {job_shipped_finish(job,compile,state.exit_code)}
        else if compile.library<0 && job.action!=.Build {job_probe_finish(job,state.exit_code)}
        else if compile.library<0 {job_finish(job,compile,state.exit_code)}
        else {job_plugin_finish(job,compile,state.exit_code)}
    }
    job_schedule(job)
    return job.result.status!=.Running
}

// Where a build of the target leaves its output: the library, or the
// executable of the game, or of its dedicated server, in the folder asked for.
target_output :: proc(p:^project.Project,target:Target,output:string,a:runtime.Allocator,server:=false) -> string {
    if target!=.Game {
        names:=TARGET_NAMES
        return project.project_library(p.root,names[target],a)
    }
    folder:=output!=""?project.path_absolute(output,context.temp_allocator):project.path(project.folder_path(p.root,.Generated,context.temp_allocator),server?"server":"game",allocator=context.temp_allocator)
    buffer:[len(project.Name)]u8
    file:=strings.concatenate({project.executable_name(&p.manifest,buffer[:]),project.EXECUTABLE_SUFFIX},context.temp_allocator)
    return project.path(folder,file,allocator=a)
}

// What the compiler is given for a target besides where it writes: what
// identifies the build next to its sources.
@(private)
target_flags :: proc(p:^project.Project,target:Target,extra:[]string,a:runtime.Allocator,dev:=false,engine:=Engine_Mode.Keep,incremental:=false) -> []string {
    flags:=make([dynamic]string,a)
    append(&flags,"build",generated_folder(p.root,target,a))
    shipped:=shipped_engine_paths(p.root,context.temp_allocator)
    // A library sees the engine through its declarations; the game, whole, or through those of its library.
    mirai:=target==.Game?(incremental?shipped.decl:p.engine_root):engine_paths(p.engine_root,engine==.Keep?ENGINE_MODE_HERE:engine,context.temp_allocator).decl
    append(&flags,fmt.aprintf("-collection:mirai=%s",mirai,allocator=a),fmt.aprintf("-collection:project=%s",p.root,allocator=a))
    // A library sees the engine's plugins through the declarations of their libraries; the game, whole.
    plugins:=target==.Game?(incremental?shipped.decl_plugins:project.path(p.engine_root,"plugins",allocator=context.temp_allocator)):plugins_decl(p.root,plugins_mode(p,dev),context.temp_allocator)
    append(&flags,fmt.aprintf("-collection:plugins=%s",plugins,allocator=a))
    generated:=generated_flags(p.root,a)
    append(&flags,..generated[:])
    if target==.Game {
        append(&flags,dev?"-o:minimal":"-o:speed")
        if incremental {
            // What -o:minimal would split only costs the inlining of what the declarations copied.
            if dev {append(&flags,"-use-single-module")}
            when ODIN_OS==.Linux {linker_flags_append(&flags,`-Wl,-rpath,"\$ORIGIN"`,a)}
            else when ODIN_OS==.Darwin {linker_flags_append(&flags,"-Wl,-rpath,@executable_path",a)}
        }
    } else {
        // The engine runs optimized whole in its own binary; what a project
        // compiles is little, and one module per package builds it in parallel.
        append(&flags,"-build-mode:dll","-use-separate-modules")
        // The libraries of the engine's plugins.
        when ODIN_OS==.Linux {linker_flags_append(&flags,fmt.tprintf("-Wl,-rpath,$ORIGIN/%s %s",project.PLUGIN_LIBRARIES,LIBRARY_OWN_RUNTIME),a)}
        else when ODIN_OS==.Darwin {linker_flags_append(&flags,fmt.tprintf("-Wl,-rpath,@loader_path/%s %s",project.PLUGIN_LIBRARIES,LIBRARY_OWN_RUNTIME),a)}
        optimizations:=OPTIMIZATION_FLAGS
        append(&flags,dev?"-o:minimal":optimizations[p.manifest.build.optimization])
        if p.manifest.build.debug {append(&flags,"-debug")}
    }
    for &define in p.manifest.build.defines {
        if text:=base.text_get(define[:]);text!="" {append(&flags,fmt.aprintf("-define:%s",text,allocator=a))}
    }
    platform_flags(p.engine_root,&flags,target==.Game,a)
    environment_flags(&flags,a)
    for flag in extra {append(&flags,strings.clone(flag,a))}
    return flags[:]
}

Target_State :: enum u8 {
    Missing, // it has no output
    Stale,   // a build would compile: the project generates another root, or something the last build read changed
    Current,
}

// What job_start would find of a target, without writing anything: the game
// is the one of the default folder. dev and engine as in Desc.
target_state :: proc(p:^project.Project,target:Target,compiler:="",dev:=false,engine:=Engine_Mode.Keep) -> Target_State {
    temp:=context.temp_allocator
    published:=target_output(p,target,"",temp)
    if !os.is_file(published) {return .Missing}
    names:=TARGET_NAMES
    world_names:=[Target]string{.Editor="editor_world",.Play="game_world",.Game="shipped_world"}
    gen:=generated_root(p.root,temp)
    world_text,_:=os.read_entire_file(project.path(gen,world_names[target],"world.odin",allocator=temp),temp)
    main_text,_:=os.read_entire_file(project.path(gen,names[target],"main.odin",allocator=temp),temp)
    if strings.concatenate({string(world_text),string(main_text)},temp)!=generate(p,target,temp) {return .Stale}
    found:=compiler
    if found=="" {
        located:bool
        if found,located=compiler_find(p.engine_root,temp);!located {return .Stale}
    }
    work:=project.path(project.folder_path(p.root,.Generated,temp),"build",allocator=temp)
    saved,_,stamped:=stamp_read(project.path(work,fmt.tprintf("%s.stamp",names[target]),allocator=temp))
    sources,listed:=dependencies_read(project.path(work,fmt.tprintf("%s.sources.json",names[target]),allocator=temp),temp)
    if !stamped || !listed {return .Stale}
    hash,_:=fingerprint(p.engine_root,slashes(found,temp),target_flags(p,target,nil,temp,dev,engine),sources)
    if hash!=saved || !plugins_current(p,target,slashes(found,temp),dev,engine) {return .Stale}
    return .Current
}

// True once the job is over: job.result has how. Does not block.
job_poll :: proc(job:^Job) -> bool {
    return job_advance(job,false)
}

// Blocks until the job is over.
job_wait :: proc(job:^Job) -> ^Result {
    for !job_advance(job,true) {}
    return &job.result
}

// Stops the compilers of a running job. What the target had built stands.
job_cancel :: proc(job:^Job) {
    if job.result.status!=.Running {return}
    job_fail(job,.Cancelled)
}

job_destroy :: proc(job:^Job) {
    if job==nil {return}
    job_cancel(job)
    virtual.arena_destroy(&job.arena)
    free(job,job.allocator)
}

// The whole build of a target, waiting for the compiler.
job_run :: proc(desc:Desc) -> ^Job {
    job:=job_start(desc)
    job_wait(job)
    return job
}

@(private)
job_done :: proc(job:^Job) -> ^Job {
    job.result.seconds=time.duration_seconds(time.tick_since(job.tick))
    return job
}

// A job that fails leaves no compiler running.
@(private)
job_fail :: proc(job:^Job,failure:Failure) -> ^Job {
    job.result.status,job.result.failure=.Failed,failure
    for compile in job.compiles {
        _=os.process_kill(compile.process)
        _,_=os.process_wait(compile.process)
    }
    clear(&job.compiles)
    job_files_remove(job)
    return job_done(job)
}

// Removes what the job left in the work folder. The debug information of
// what it built stays, under the name the output refers to it by, until a
// later job builds the target again: only a job that built removes what
// other jobs of the target left, once it is old and the process its name
// carries ended. A replaced output goes as soon as nothing has it loaded.
@(private)
job_files_remove :: proc(job:^Job) {
    if !os.is_dir(job.work) {return}
    entries,error:=os.read_all_directory_by_path(job.work,context.temp_allocator)
    if error!=nil {return}
    names:=TARGET_NAMES
    target:=strings.concatenate({names[job.target],"-"},context.temp_allocator)
    built:=job.result.status==.Built
    for entry in entries {
        if !strings.has_prefix(entry.name,target) {continue}
        remove:bool
        debug:=strings.has_suffix(entry.name,".pdb") || strings.has_suffix(entry.name,".dSYM")
        if strings.has_prefix(entry.name,job.prefix) {
            remove=!built || !debug
        } else {
            stale:=built && time.diff(entry.modification_time,job.started)>STALE_AFTER
            remove=strings.has_suffix(entry.name,".old") || stale && (debug || !workspace.process_alive(job_file_pid(entry.name[len(target):])))
        }
        if !remove {continue}
        if entry.type==.Directory {_=os.remove_all(entry.fullpath)}
        else {_=os.remove(entry.fullpath)}
    }
}

// The process of the job that named a file "<hex>-<pid>..." after its target; 0 when none.
@(private)
job_file_pid :: proc(name:string) -> int {
    dash:=strings.index_byte(name,'-')
    if dash<0 {return 0}
    digits:=name[dash+1:]
    end:=0
    for end<len(digits) && digits[end]>='0' && digits[end]<='9' {end+=1}
    pid,_:=strconv.parse_int(digits[:end],10)
    return pid
}

@(private)
job_finish :: proc(job:^Job,compile:Compile,exit_code:int) {
    a:=virtual.arena_allocator(&job.arena)
    errors:bool
    output:string
    job.result.text,errors,output=job_compile_read(job,job.stream_files,links=true)
    failed:=errors || exit_code!=0 || !os.is_file(compile.staged)
    if failed && compile.relink {
        // The objects do not link again: it compiles.
        job.result.diagnostics,job.result.text=nil,""
        job.compiled=true
        link_record_remove(job.link_file)
        job_project_start(job)
        return
    }
    if failed {
        if compile.folder!="" {remove_later({compile.folder})}
        job_compile_fail(job,exit_code)
        return
    }
    sources,_:=dependencies_read(compile.relink?job.sources_file:job.sources_staged,context.temp_allocator)
    if job.target==.Game {
        if job.result.engine_time=engine_time_packages(sources,job.root,job.engine_root,job.development[:],a);len(job.result.engine_time)>0 {
            job_fail(job,.Engine_Time_Code)
            return
        }
    }
    folder:=job.published[:strings.last_index_byte(job.published,'/')]
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {
        job_fail(job,.Output_Locked)
        return
    }
    if os.rename(compile.staged,job.published)!=nil {
        // Windows does not replace a file a program has loaded, and lets it
        // be renamed: the previous one leaves, and is removed once it is free.
        retired:=project.path(job.work,fmt.tprintf("%s.old",job.prefix),allocator=context.temp_allocator)
        if os.rename(job.published,retired)!=nil || os.rename(compile.staged,job.published)!=nil {
            job_fail(job,.Output_Locked)
            return
        }
    }
    // A source saved while the compiler ran is not what was built: without
    // the fingerprint the next job builds again.
    hash,latest:=fingerprint(job.engine_root,job.compiler,job.flags,sources)
    stamped:=len(sources)>0 && time.diff(latest,job.started)>0 && (compile.relink || os.rename(job.sources_staged,job.sources_file)==nil)
    if stamped {stamped=os.write_entire_file(job.stamp_file,fmt.tprintf("%x %s",hash,job.published))==nil}
    if !stamped {_=os.remove(job.stamp_file)}
    job.result.relinked=compile.relink
    if compile.folder!="" && !compile.relink {
        command,found:=link_command_find(output)
        if stamped && found {
            masked,_:=fingerprint(job.engine_root,job.compiler,job.flags,sources,masked=job.masked)
            link_folder_trim(compile.folder)
            link_record_write(job.link_file,{hash=masked,folder=compile.folder,command=command})
        } else {
            remove_later({compile.folder})
            link_record_remove(job.link_file)
        }
    }
    job.result.status=.Built
    job_files_remove(job)
    objects_sweep(job.root,link_records(job.root))
    if job.target==.Game {
        if failure:=job_ship(job);failure!=.None {job.result.status,job.result.failure=.Failed,failure}
    }
    job_done(job)
}

// What the stamp of the last build of a target says: what a program that
// loaded its output compares to tell whether it has the last one. "" without one.
target_stamp_of :: proc(root:string,target:Target,allocator:=context.allocator) -> string {
    names:=TARGET_NAMES
    file:=project.path(project.folder_path(root,.Generated,context.temp_allocator),"build",fmt.tprintf("%s.stamp",names[target]),allocator=context.temp_allocator)
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return ""}
    return strings.clone(strings.trim_space(string(data)),allocator)
}

// The fingerprint of the last build and where it left its output.
@(private)
stamp_read :: proc(file:string) -> (hash:u64,output:string,ok:bool) {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return 0,"",false}
    text:=strings.trim_space(string(data))
    hex:=text
    if cut:=strings.index_byte(text,' ');cut>0 {hex,output=text[:cut],text[cut+1:]}
    hash,ok=strconv.parse_u64_of_base(hex,16)
    return
}

