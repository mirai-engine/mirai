package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/subprocess"

// The demo's engine plugins build one library per part: the runtime parts in
// the order of the plugins, dependencies first, then the editor parts for the
// editor; each compiles against the parts of its plugin and of those it
// depends on. Play links the runtime parts and the game none.
@(test)
plugin_libraries_follow_the_parts_and_their_dependencies :: proc(t:^testing.T) {
    root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    p,error:=project.open(project.path(root,"demo",allocator=context.temp_allocator),root,context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"the demo opens: %v",error) {return}
    editor:=plugin_libraries(&p,.Editor,true,context.temp_allocator)
    play:=plugin_libraries(&p,.Play,true,context.temp_allocator)
    testing.expect_value(t,len(plugin_libraries(&p,.Game,true,context.temp_allocator)),0)
    index_of :: proc(list:[]Plugin_Library,path:string) -> int {
        for lib,i in list {if lib.path==path {return i}}
        return -1
    }
    animation,ragdoll:=index_of(editor,"animation/runtime"),index_of(editor,"ragdoll/runtime")
    previews:=index_of(editor,"previews/editor")
    if !testing.expect(t,animation>=0 && ragdoll>=0 && previews>=0) {return}
    testing.expect(t,animation<ragdoll,"a dependency builds first")
    testing.expect(t,slice.contains(editor[ragdoll].needs,"animation/runtime"))
    testing.expect(t,slice.contains(editor[previews].needs,"animation/runtime") && slice.contains(editor[previews].needs,"animation/editor"))
    testing.expect(t,slice.contains(editor[index_of(editor,"terrain/editor")].needs,"terrain/runtime"),"an editor part compiles against its runtime")
    for lib,i in editor {
        if lib.part==.Editor {testing.expectf(t,i>=len(play),"%s builds after every runtime part",lib.path)}
    }
    for lib in play {testing.expect_value(t,lib.part,project.Plugin_Part.Runtime)}
    testing.expect(t,index_of(play,"profiler/editor")<0 && index_of(editor,"profiler/editor")>=0)
    testing.expect(t,plugins_mode(&p,true)=="minimal" && plugins_mode(&p,false)=="speed")
    // Optimized, a library is one module, as the game that ships compiles it.
    dev,release:=plugin_flags(&p,true,context.temp_allocator),plugin_flags(&p,false,context.temp_allocator)
    testing.expect(t,slice.contains(dev,"-use-separate-modules") && slice.contains(dev,"-o:minimal"))
    testing.expect(t,!slice.contains(release,"-use-separate-modules") && slice.contains(release,"-o:speed"))
}

// A plugin library is built from the same things in every project of an
// engine: with the same flags they share it through the cache, and those a
// package of the engine brings serve any of them.
@(test)
a_plugin_library_is_the_same_in_every_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=slashes(project.path_absolute(#directory+"../.."),context.temp_allocator)
    stamp:=project.path(root,".mirai","engine","none",ENGINE_STAMP)
    hashes:[2]u64
    for &hash in hashes {
        directory,error:=os.make_directory_temp("","mirai-plugin-project-*",context.temp_allocator)
        if !testing.expect(t,error==nil) {return}
        folder:=project.path_absolute(directory)
        defer os.remove_all(folder)
        testing.expect(t,os.write_entire_file(project.path(folder,project.PROJECT_FILE),`{"name": "Shared", "plugins": ["ragdoll"]}`)==nil)
        p,open_error:=project.open(folder,root)
        if !testing.expectf(t,open_error.code==.None,"the project opens: %v",open_error) {return}
        libraries:=plugin_libraries(&p,.Play,true)
        found:^Plugin_Library
        for &lib in libraries {if lib.path=="ragdoll/runtime" {found=&lib}}
        if !testing.expect(t,found!=nil && len(found.needs)>0) {return}
        // The declarations of what it compiles against, as each project writes them.
        for need in found.needs {
            decl:=project.path(plugins_decl(p.root,"minimal"),need)
            testing.expect(t,os.make_directory_all(decl)==nil)
            testing.expect(t,os.write_entire_file(project.path(decl,"declared.odin"),need)==nil)
        }
        hash=plugin_library_hash(&p,found,"odin",plugin_flags(&p,true),stamp)
    }
    testing.expect_value(t,hashes[1],hashes[0])
}

@(private="file")
spaced_library :: proc(folder:string) -> Plugin_Library {
    stage:=project.path(folder,"a folder","stage-thing-runtime",allocator=context.temp_allocator)
    return {name="thing",path="thing/runtime",file="plugin-thing-runtime-minimal",stage=stage}
}

// The library of a project under a folder with spaces links with its definition
// and the import library names the file it is published as.
@(test)
a_plugin_library_under_a_folder_with_spaces_links_with_its_definition :: proc(t:^testing.T) {
    when ODIN_OS==.Windows {
        context.allocator=context.temp_allocator
        root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
        compiler,found:=compiler_find(root,context.temp_allocator)
        if !testing.expect(t,found,"no Odin compiler") {return}
        directory,directory_error:=os.make_directory_temp("","mirai-plugin-spaces-*",context.temp_allocator)
        if !testing.expect(t,directory_error==nil) {return}
        folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
        defer os.remove_all(folder)
        lib:=spaced_library(folder)
        testing.expect(t,os.make_directory_all(lib.stage)==nil)
        entry_write(lib.stage,PLUGIN_ENTRY,{},"plugins")
        testing.expect(t,os.write_entire_file(project.path(lib.stage,PLUGIN_ENTRY,"answer.odin"),"package __plugin\n\n@(export)\nanswer :: proc \"c\" () -> i32 {return 42}\n")==nil)
        testing.expect(t,plugin_definition_write(&lib))
        staged:=project.path(folder,"a folder","staged.dll")
        command:=plugin_command(&lib,compiler,lib.stage,staged,{"-build-mode:dll","-o:minimal"})
        memory,_:=compiler_memory()
        state,_,errors,error:=subprocess.exec({command=command,working_dir=lib.stage,env=child_environment(root,context.temp_allocator)},context.temp_allocator,{memory=memory})
        if !testing.expectf(t,error==nil && state.exit_code==0,"the library does not link:\n%s",string(errors)) {return}
        testing.expect(t,os.is_file(staged))
        import_library,read:=os.read_entire_file(project.path(folder,"a folder","staged.lib"),context.temp_allocator)
        testing.expect(t,read==nil && strings.contains(string(import_library),project.library_file(lib.file,context.temp_allocator)),"the import library names the published file")
    }
}

// An engine of a test with a core and a plugin whose runtime part has a
// package in a folder of its own, beside a test and a testdata folder that
// are not packages of it, and a project that activates the plugin.
@(private="file")
split_plugin_write :: proc(t:^testing.T,folder:string) -> (engine,game:string) {
    files:=[][2]string{
        {"engine/core/data.odin","package core\n"},
        {"engine/plugins/thing/plugin.mirai",`{"name": "thing", "version": "1.0.0", "parts": ["Runtime"]}`},
        {"engine/plugins/thing/runtime/thing.odin","package thing\n\nimport \"plugins:thing/runtime/sim\"\n\ndoubled :: proc(value:i32) -> i32 {return sim.answer()*value}\n"},
        {"engine/plugins/thing/runtime/sim/sim.odin","package sim\n\n@(component)\nSim_Probe :: struct {value:f32}\n\nanswer :: proc() -> i32 {return 21}\n"},
        {"engine/plugins/thing/runtime/sim/sim_test.odin","package sim\n"},
        {"engine/plugins/thing/runtime/testdata/ignored.odin","package ignored\n"},
        {"game/project.mirai",`{"name": "Split", "plugins": ["thing"]}`},
    }
    for file in files {
        path:=project.path(folder,file[0],allocator=context.temp_allocator)
        directory:=path[:strings.last_index_byte(path,'/')]
        testing.expect(t,os.make_directory_all(directory)==nil || os.is_dir(directory))
        testing.expect(t,os.write_entire_file(path,file[1])==nil,path)
    }
    return project.path(folder,"engine",allocator=context.temp_allocator),project.path(folder,"game",allocator=context.temp_allocator)
}

// A job that builds only the plugin libraries of a project.
@(private="file")
plugin_job :: proc(p:^project.Project,compiler:string) -> ^Job {
    job:=new(Job,context.temp_allocator)
    job.allocator=context.temp_allocator
    _=virtual.arena_init_growing(&job.arena)
    a:=virtual.arena_allocator(&job.arena)
    job.target=.Play
    job.root,job.engine_root=strings.clone(p.root,a),strings.clone(p.engine_root,a)
    job.compiler=compiler
    job.work=project.path(project.folder_path(p.root,.Generated,context.temp_allocator),"build",allocator=a)
    job.prefix="play-test"
    job.stream_files={project.path(job.work,"play-test.err",allocator=a),project.path(job.work,"play-test.out",allocator=a)}
    job.compiles=make([dynamic]Compile,a)
    return job
}

// Every folder with sources under a part is a package of its library: it is
// declared, staged and compiled into it, the world reads its attributes, and
// what imports it through the declarations links against the library. The
// library goes to the cache the checkouts share, and a checkout that has not
// built it copies it from there instead of compiling it.
@(test)
a_part_with_folders_is_one_library_that_the_shared_cache_keeps :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repository:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(repository,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    directory,directory_error:=os.make_directory_temp("","mirai-plugin-split-*",context.temp_allocator)
    if !testing.expect(t,directory_error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    engine,game:=split_plugin_write(t,folder)
    p,error:=project.open(game,engine)
    if !testing.expectf(t,error.code==.None,"the project opens: %v",error) {return}
    world:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(world.errors)==0,"%v",world.errors) {return}
    testing.expect(t,strings.contains(world.game_world,`"plugins:thing/runtime/sim"`),"the world reads the attributes of the package of the folder")
    testing.expect(t,!strings.contains(world.game_world,"testdata"))
    libraries:=plugin_libraries(&p,.Play,true)
    if !testing.expect_value(t,len(libraries),1) {return}
    testing.expect_value(t,len(libraries[0].packages),2)
    testing.expect(t,slice.contains(libraries[0].packages,"thing/runtime") && slice.contains(libraries[0].packages,"thing/runtime/sim"))
    testing.expect(t,os.make_directory_all(engine_paths(engine,.Dev).decl)==nil)

    job:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&job.arena)
    if !testing.expect_value(t,job_plugins_plan(job,&p,{project=&p,target=.Play,dev=true,engine=.Dev}),Failure.None) {return}
    if !testing.expect_value(t,len(job.plugin_queue),1) {return}
    job_plugins_start(job)
    if !testing.expect_value(t,len(job.compiles),1) {return}
    compile:=pop(&job.compiles)
    state,_:=os.process_wait(compile.process)
    job_plugin_finish(job,compile,state.exit_code)
    if !testing.expectf(t,job.result.status==.Running,"the library builds: %v %s",job.result.diagnostics,job.result.text) {return}
    lib:=&job.plugins[0]
    linked,_:=os.read_entire_file(lib.linked,context.temp_allocator)
    testing.expect(t,strings.contains(string(linked),"plugins.thing.runtime.sim.answer"),"the package of the folder is in the library")
    testing.expect(t,cache_entry_complete(plugin_cache_entry(engine,lib,job.plugin_hashes[0])),"the library is kept in the shared cache")

    // A program that imports the packages through the declarations links against the library.
    program:=project.path(folder,"program")
    testing.expect(t,os.make_directory_all(program)==nil)
    testing.expect(t,os.write_entire_file(project.path(program,"main.odin"),"package main\n\nimport \"core:os\"\nimport thing \"plugins:thing/runtime\"\nimport \"plugins:thing/runtime/sim\"\n\nmain :: proc() {os.exit(int(thing.doubled(2))-int(sim.answer())+21)}\n")==nil)
    executable:=project.path(plugins_libraries_folder(p.root),strings.concatenate({"split",EXECUTABLE_EXTENSION}))
    command:=make([dynamic]string)
    append(&command,compiler,"build",program,fmt.tprintf("-collection:plugins=%s",plugins_decl(p.root,"minimal")),fmt.tprintf("-collection:mirai=%s",engine_paths(engine,.Dev).decl),fmt.tprintf("-out:%s",executable),"-o:minimal",fmt.tprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES))
    when ODIN_OS==.Linux {linker_flags_append(&command,"-Wl,-rpath,$ORIGIN")}
    else when ODIN_OS==.Darwin {linker_flags_append(&command,"-Wl,-rpath,@executable_path")}
    memory,_:=compiler_memory()
    built,_,errors,built_error:=subprocess.exec({command=command[:],env=child_environment(repository,context.temp_allocator)},context.temp_allocator,{memory=memory})
    if testing.expectf(t,built_error==nil && built.exit_code==0,"the program does not build:\n%s",string(errors)) {
        ran,_,_,ran_error:=subprocess.exec({command={executable}},context.temp_allocator)
        testing.expectf(t,ran_error==nil && ran.exit_code==42,"the program calls into the library: %v %v",ran_error,ran.exit_code)
    }

    // A checkout that has not built it copies it.
    testing.expect(t,os.remove_all(project.folder_path(p.root,.Generated))==nil)
    again:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&again.arena)
    if !testing.expect_value(t,job_plugins_plan(again,&p,{project=&p,target=.Play,dev=true,engine=.Dev}),Failure.None) {return}
    testing.expect_value(t,len(again.plugin_queue),0)
    testing.expect_value(t,again.result.plugins_restored,1)
    testing.expect_value(t,again.result.plugins_built,1)
    testing.expect(t,os.is_file(lib.library) && os.is_file(lib.linked))
    testing.expect(t,plugins_current(&p,.Play,compiler,true,.Dev),"the library copied stands as built")
    testing.expect(t,os.is_file(project.path(plugins_decl(p.root,"minimal"),"thing","runtime","sim","sim.odin")),"its declarations are written")
}

// The cache keeps the entries used last and writes a whole one once.
@(test)
the_shared_cache_keeps_the_entries_used_last :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    directory,error:=os.make_directory_temp("","mirai-plugin-cache-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    entries:=[3]string{project.path(folder,"a"),project.path(folder,"b"),project.path(folder,"c")}
    for entry,i in entries {
        staging,fresh:=cache_entry_begin(entry)
        if !testing.expect(t,fresh) {return}
        testing.expect(t,os.write_entire_file(project.path(staging,"library"),"library")==nil)
        cache_entry_commit(entry,staging,2)
        time.sleep(20*time.Millisecond)
        // Used again after the second was written, the first is newer than it.
        if i==1 {
            cache_entry_used(entries[0])
            time.sleep(20*time.Millisecond)
        }
    }
    _,fresh:=cache_entry_begin(entries[2])
    testing.expect(t,!fresh,"a whole entry is not written again")
    testing.expect(t,cache_entry_complete(entries[0]) && cache_entry_complete(entries[2]))
    testing.expect(t,!os.exists(entries[1]),"the entry used the longest ago goes")
}

// A plugin imports only itself and the plugins it depends on, also through
// their dependencies; another one is an error that names what to declare.
@(test)
a_plugin_that_imports_a_plugin_it_does_not_depend_on_is_an_error :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    directory,directory_error:=os.make_directory_temp("","mirai-plugin-imports-*",context.temp_allocator)
    if !testing.expect(t,directory_error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    write :: proc(t:^testing.T,folder:string,files:[][2]string) {
        for file in files {
            path:=project.path(folder,file[0],allocator=context.temp_allocator)
            directory:=path[:strings.last_index_byte(path,'/')]
            testing.expect(t,os.make_directory_all(directory)==nil || os.is_dir(directory))
            testing.expect(t,os.write_entire_file(path,file[1])==nil,path)
        }
    }
    write(t,folder,{
        {"engine/core/data.odin","package core\n"},
        {"engine/plugins/base_thing/plugin.mirai",`{"name": "base_thing", "version": "1.0.0", "parts": ["Runtime"]}`},
        {"engine/plugins/base_thing/runtime/base.odin","package base_thing\n\nanswer :: proc() -> i32 {return 21}\n"},
        {"engine/plugins/middle/plugin.mirai",`{"name": "middle", "version": "1.0.0", "dependencies": ["base_thing"], "parts": ["Runtime"]}`},
        {"engine/plugins/middle/runtime/middle.odin","package middle\n\nimport base_thing \"plugins:base_thing/runtime\"\n\ntwice :: proc() -> i32 {return 2*base_thing.answer()}\n"},
        {"engine/plugins/user/plugin.mirai",`{"name": "user", "version": "1.0.0", "parts": ["Runtime"]}`},
        {"engine/plugins/user/runtime/user.odin","package user\n\nimport base_thing \"plugins:base_thing/runtime\"\n\nthrice :: proc() -> i32 {return 3*base_thing.answer()}\n"},
        {"game/project.mirai",`{"name": "Imports", "plugins": ["middle", "user"]}`},
    })
    engine,game:=project.path(folder,"engine"),project.path(folder,"game")
    p,error:=project.open(game,engine)
    if !testing.expectf(t,error.code==.None,"the project opens: %v",error) {return}
    world:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(world.errors),1) {return}
    testing.expectf(t,strings.contains(world.errors[0],"user.odin") && strings.contains(world.errors[0],`add "base_thing" to the dependencies`),"%s",world.errors[0])
    // Through a dependency of a dependency is a dependency too.
    write(t,folder,{{"engine/plugins/user/plugin.mirai",`{"name": "user", "version": "1.0.0", "dependencies": ["middle"], "parts": ["Runtime"]}`}})
    project.close(&p)
    p,error=project.open(game,engine)
    if !testing.expect(t,error.code==.None) {return}
    world=world_generate(&p,context.temp_allocator)
    testing.expectf(t,len(world.errors)==0,"%v",world.errors)
    user,_:=project.plugin_find(p.plugins,"user")
    testing.expect(t,project.plugin_reaches(p.plugins,user,"base_thing",false))
    testing.expect(t,!project.plugin_reaches(p.plugins,user,"absent",true))
}

// A step of a plugin library receives a @(params) of core: the world builds
// it in the call, and through the declarations, which keep the attribute,
// what calls the library passes it by value to the step that writes through it.
@(test)
a_plugin_step_receives_a_params_struct_through_its_library :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repository:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(repository,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    directory,directory_error:=os.make_directory_temp("","mirai-plugin-params-*",context.temp_allocator)
    if !testing.expect(t,directory_error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    files:=[][2]string{
        {"engine/core/data.odin","package core\n\nTable :: struct($T:typeid) {values:[2]T}\nRead :: struct($T:typeid) {table:^Table(T)}\n\n@(component)\nProbe :: struct {value:i32}\n\n@(storage,queue)\nAsks :: struct {count:i32}\n\n@(params)\nProber :: struct {probes:^Table(Probe),asks:^Asks}\n"},
        {"engine/plugins/thing/plugin.mirai",`{"name": "thing", "version": "1.0.0", "parts": ["Runtime"]}`},
        {"engine/plugins/thing/runtime/thing.odin","package thing\n\nimport \"mirai:core\"\n\n@(step=\"fixed\")\nthing_probe :: proc(prober:core.Prober) {\n    prober.probes.values[1].value=40\n    prober.asks.count+=2\n}\n"},
        {"game/project.mirai",`{"name": "Params", "plugins": ["thing"]}`},
    }
    for file in files {
        path:=project.path(folder,file[0])
        testing.expect(t,os.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil || os.is_dir(path[:strings.last_index_byte(path,'/')]))
        testing.expect(t,os.write_entire_file(path,file[1])==nil,path)
    }
    engine,game:=project.path(folder,"engine"),project.path(folder,"game")
    p,error:=project.open(game,engine)
    if !testing.expectf(t,error.code==.None,"the project opens: %v",error) {return}
    world:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(world.errors)==0,"%v",world.errors) {return}
    testing.expect(t,strings.contains(world.game_world,"p_thing.thing_probe(p_core.Prober{probes=&w.probe,asks=&w.asks})"),world.game_world)
    decl:=engine_paths(engine,.Dev).decl
    declared,_:=declare({root=engine,packages={"core"},binary="mirai",library=project.path(folder,"runtime.lib"),stage=project.path(folder,"stage"),decl=decl})
    if !testing.expectf(t,len(declared)==0,"%v",declared) {return}
    core_decl,_:=os.read_entire_file(project.path(decl,"core","data.odin"),context.temp_allocator)
    testing.expect(t,strings.contains(string(core_decl),"@(params)\nProber :: struct"),"the declarations keep the attribute")

    job:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&job.arena)
    if !testing.expect_value(t,job_plugins_plan(job,&p,{project=&p,target=.Play,dev=true,engine=.Dev}),Failure.None) {return}
    if !testing.expect_value(t,len(job.plugin_queue),1) {return}
    job_plugins_start(job)
    if !testing.expect_value(t,len(job.compiles),1) {return}
    compile:=job.compiles[0]
    ordered_remove(&job.compiles,0)
    state,_:=os.process_wait(compile.process)
    job_plugin_finish(job,compile,state.exit_code)
    if !testing.expectf(t,job.result.status==.Running,"the library builds: %v %s",job.result.diagnostics,job.result.text) {return}

    program:=project.path(folder,"program")
    testing.expect(t,os.make_directory_all(program)==nil)
    testing.expect(t,os.write_entire_file(project.path(program,"main.odin"),"package main\n\nimport \"core:os\"\nimport \"mirai:core\"\nimport thing \"plugins:thing/runtime\"\n\nmain :: proc() {\n    probes:core.Table(core.Probe)\n    asks:core.Asks\n    thing.thing_probe(core.Prober{probes=&probes,asks=&asks})\n    os.exit(int(probes.values[1].value)+int(asks.count))\n}\n")==nil)
    executable:=project.path(plugins_libraries_folder(p.root),strings.concatenate({"params",EXECUTABLE_EXTENSION}))
    command:=make([dynamic]string)
    append(&command,compiler,"build",program,fmt.tprintf("-collection:plugins=%s",plugins_decl(p.root,"minimal")),fmt.tprintf("-collection:mirai=%s",decl),fmt.tprintf("-out:%s",executable),"-o:minimal",fmt.tprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES))
    when ODIN_OS==.Linux {linker_flags_append(&command,"-Wl,-rpath,$ORIGIN")}
    else when ODIN_OS==.Darwin {linker_flags_append(&command,"-Wl,-rpath,@executable_path")}
    memory,_:=compiler_memory()
    built,_,errors,built_error:=subprocess.exec({command=command[:],env=child_environment(repository,context.temp_allocator)},context.temp_allocator,{memory=memory})
    if testing.expectf(t,built_error==nil && built.exit_code==0,"the program does not build:\n%s",string(errors)) {
        ran,_,_,ran_error:=subprocess.exec({command={executable}},context.temp_allocator)
        testing.expectf(t,ran_error==nil && ran.exit_code==42,"the step writes through the struct it receives: %v %v",ran_error,ran.exit_code)
    }
}

// What links against a library of the engine passes an `any` of its own types
// to it, as a plugin passes an enum to core.report: compiled where it is
// called, the procedure finds the type in the caller's type table and prints
// the enum, the struct and the formatting the library passes it on to; through
// the library, whose table does not have them, fmt would print nothing.
@(test)
an_any_of_a_type_of_what_links_against_a_library_formats_where_it_is_called :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repository:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(repository,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    directory,directory_error:=os.make_directory_temp("","mirai-declare-any-*",context.temp_allocator)
    if !testing.expect(t,directory_error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    files:=[][2]string{
        {"engine/thing/say.odin","package thing\n\nimport \"core:fmt\"\n\nsay :: proc(buffer:[]u8,format:string,args:..any) -> string {return fmt.bprintf(buffer,format,..args)}\n\ncount :: proc(n:int) -> int {return n+1}\n"},
        // Passes its arguments on, as core.report does to base.text_format.
        {"engine/thing/report.odin","package thing\n\nreport :: proc(buffer:[]u8,format:string,args:..any) -> string {return say(buffer,format,..args)}\n"},
    }
    for file in files {
        path:=project.path(folder,file[0])
        testing.expect(t,os.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil || os.is_dir(path[:strings.last_index_byte(path,'/')]))
        testing.expect(t,os.write_entire_file(path,file[1])==nil,path)
    }
    out:=project.path(folder,"out")
    library:=project.path(out,project.library_file("thing"))
    linked:=project.path(out,"thing.lib") when ODIN_OS==.Windows else library
    stage,decl:=project.path(folder,"stage"),project.path(folder,"decl")
    errors,_:=declare({root=project.path(folder,"engine"),packages={"thing"},binary="mirai",library=linked,stage=stage,decl=decl})
    if !testing.expectf(t,len(errors)==0,"%v",errors) {return}
    declared_say,_:=os.read_entire_file(project.path(decl,"thing","say.odin"),context.temp_allocator)
    testing.expectf(t,strings.contains(string(declared_say),"fmt.bprintf") && strings.contains(string(declared_say),"link_name=\"mirai.thing.count\""),"say is compiled where it is called and count through the library:\n%s",string(declared_say))
    entry_write(stage,"__engine",{"thing"})
    testing.expect(t,os.make_directory_all(out)==nil || os.is_dir(out))
    memory,_:=compiler_memory()
    environment:=child_environment(repository,context.temp_allocator)
    built_library,_,library_errors,library_error:=subprocess.exec({command={compiler,"build",project.path(stage,"__engine"),"-build-mode:dll",fmt.tprintf("-collection:mirai=%s",stage),fmt.tprintf("-out:%s",library),"-o:minimal"},env=environment},context.temp_allocator,{memory=memory})
    if !testing.expectf(t,library_error==nil && built_library.exit_code==0,"the library does not build:\n%s",string(library_errors)) {return}

    program:=project.path(folder,"program")
    testing.expect(t,os.make_directory_all(program)==nil)
    main_text:="package main\n\nimport \"core:os\"\nimport \"mirai:thing\"\n\nKind :: enum u8 {Fire,Cancel,Section}\nRequest :: struct {kind:Kind,at:i32}\n\nmain :: proc() {\n    buffer:[128]u8\n    text:=thing.report(buffer[:],\"a %v of %v, %d\",Kind.Cancel,Request{.Section,7},thing.count(41))\n    os.write(os.stdout,transmute([]u8)text)\n}\n"
    testing.expect(t,os.write_entire_file(project.path(program,"main.odin"),main_text)==nil)
    executable:=project.path(out,strings.concatenate({"program",EXECUTABLE_EXTENSION}))
    command:=make([dynamic]string)
    append(&command,compiler,"build",program,fmt.tprintf("-collection:mirai=%s",decl),fmt.tprintf("-out:%s",executable),"-o:minimal")
    when ODIN_OS==.Linux {linker_flags_append(&command,"-Wl,-rpath,$ORIGIN")}
    else when ODIN_OS==.Darwin {linker_flags_append(&command,"-Wl,-rpath,@executable_path")}
    built,_,program_errors,built_error:=subprocess.exec({command=command[:],env=environment},context.temp_allocator,{memory=memory})
    if !testing.expectf(t,built_error==nil && built.exit_code==0,"the program does not build:\n%s",string(program_errors)) {return}
    ran,printed,_,ran_error:=subprocess.exec({command={executable}},context.temp_allocator)
    testing.expect(t,ran_error==nil && ran.exit_code==0)
    testing.expect_value(t,string(printed),"a Cancel of Request{kind = \"Section\", at = 7}, 42")
}

// The libraries of plugins compile at once, each as soon as the libraries it
// links against are published: one that depends on another waits for it, and
// one that does not starts beside it.
@(test)
a_plugin_library_compiles_once_those_it_links_against_are_published :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repository:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(repository,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    directory,directory_error:=os.make_directory_temp("","mirai-plugin-order-*",context.temp_allocator)
    if !testing.expect(t,directory_error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    files:=[][2]string{
        {"engine/core/data.odin","package core\n"},
        {"engine/plugins/base_thing/plugin.mirai",`{"name": "base_thing", "version": "1.0.0", "parts": ["Runtime"]}`},
        {"engine/plugins/base_thing/runtime/base.odin","package base_thing\n\nanswer :: proc() -> i32 {return 21}\n"},
        {"engine/plugins/middle/plugin.mirai",`{"name": "middle", "version": "1.0.0", "dependencies": ["base_thing"], "parts": ["Runtime"]}`},
        {"engine/plugins/middle/runtime/middle.odin","package middle\n\nimport base_thing \"plugins:base_thing/runtime\"\n\ntwice :: proc() -> i32 {return 2*base_thing.answer()}\n"},
        {"engine/plugins/lone/plugin.mirai",`{"name": "lone", "version": "1.0.0", "parts": ["Runtime"]}`},
        {"engine/plugins/lone/runtime/lone.odin","package lone\n\nalone :: proc() -> i32 {return 1}\n"},
        {"game/project.mirai",`{"name": "Order", "plugins": ["middle", "lone"]}`},
    }
    for file in files {
        path:=project.path(folder,file[0])
        testing.expect(t,os.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil)
        testing.expect(t,os.write_entire_file(path,file[1])==nil,path)
    }
    engine,game:=project.path(folder,"engine"),project.path(folder,"game")
    p,error:=project.open(game,engine)
    if !testing.expectf(t,error.code==.None,"the project opens: %v",error) {return}
    testing.expect(t,os.make_directory_all(engine_paths(engine,.Dev).decl)==nil)

    job:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&job.arena)
    if !testing.expect_value(t,job_plugins_plan(job,&p,{project=&p,target=.Play,dev=true,engine=.Dev}),Failure.None) {return}
    if !testing.expect_value(t,len(job.plugin_queue),3) {return}
    index_of :: proc(job:^Job,path:string) -> int {
        for lib,i in job.plugins {if lib.path==path {return i}}
        return -1
    }
    base_index,middle_index,lone_index:=index_of(job,"base_thing/runtime"),index_of(job,"middle/runtime"),index_of(job,"lone/runtime")
    if !testing.expect(t,base_index>=0 && middle_index>=0 && lone_index>=0) {return}
    running :: proc(job:^Job,index:int) -> bool {
        for compile in job.compiles {if compile.library==index {return true}}
        return false
    }
    job.plugin_limit=3
    job_plugins_start(job)
    testing.expect(t,running(job,base_index) && running(job,lone_index),"what depends on nothing that is not published starts at once")
    testing.expect(t,!running(job,middle_index),"a library waits for the one it links against")
    for len(job.compiles)>0 {
        if running(job,middle_index) {testing.expect(t,job.plugin_published[base_index],"it starts once that one is published")}
        compile:=job.compiles[0]
        ordered_remove(&job.compiles,0)
        state,_:=os.process_wait(compile.process)
        job_plugin_finish(job,compile,state.exit_code)
        if !testing.expectf(t,job.result.status==.Running,"%s builds: %v %s",job.plugins[compile.library].path,job.result.diagnostics,job.result.text) {return}
        job_plugins_start(job)
    }
    testing.expect_value(t,len(job.plugin_queue),0)
    testing.expect_value(t,job.result.plugins_built,3)
    for published in job.plugin_published {testing.expect(t,published)}
}

// A runtime part of a plugin compiles against the declarations of the
// engine's runtime alone: a change of the declarations of the editor builds
// every editor part again and no runtime part; one of the runtime, both.
@(test)
a_declaration_of_the_editor_alone_builds_no_runtime_part_again :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    directory,directory_error:=os.make_directory_temp("","mirai-plugin-decl-*",context.temp_allocator)
    if !testing.expect(t,directory_error==nil) {return}
    folder:=slashes(project.path_absolute(directory,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    decl:=project.path(folder,"engine","decl")
    write :: proc(t:^testing.T,decl,package_path,text:string) {
        path:=project.path(decl,package_path)
        testing.expect(t,os.make_directory_all(path)==nil || os.is_dir(path))
        testing.expect(t,os.write_entire_file(project.path(path,"declared.odin"),text)==nil)
    }
    write(t,decl,"core","package core\n\nvalue :: proc() -> i32\n")
    write(t,decl,"editor","package editor\n\nopen :: proc() -> bool\n")
    runtime_packages,editor_packages:=[]string{"core"},[]string{"editor"}
    p:project.Project
    p.engine_root=project.path(folder,"engine")
    runtime_lib:=Plugin_Library{part=.Runtime,stage=project.path(folder,"plugins","stage-thing-runtime")}
    editor_lib:=Plugin_Library{part=.Editor,stage=project.path(folder,"plugins","stage-thing-editor")}
    stamp_file:=project.path(folder,"engine.stamp")
    hashes :: proc(t:^testing.T,p:^project.Project,runtime_lib,editor_lib:^Plugin_Library,stamp_file,decl:string,runtime_packages,editor_packages:[]string) -> (runtime,editor:u64) {
        stamp:=Engine_Stamp{decl_runtime=decl_hash(decl,runtime_packages,""),decl_editor=decl_hash(decl,editor_packages,""),declares=DECLARE_VERSION}
        testing.expect(t,engine_stamp_write(stamp_file,stamp)==nil)
        return plugin_library_hash(p,runtime_lib,"",nil,stamp_file),plugin_library_hash(p,editor_lib,"",nil,stamp_file)
    }
    runtime,editor:=hashes(t,&p,&runtime_lib,&editor_lib,stamp_file,decl,runtime_packages,editor_packages)
    write(t,decl,"editor","package editor\n\nopen :: proc(path:string) -> bool\n")
    runtime_after,editor_after:=hashes(t,&p,&runtime_lib,&editor_lib,stamp_file,decl,runtime_packages,editor_packages)
    testing.expect_value(t,runtime_after,runtime)
    testing.expect(t,editor_after!=editor,"an editor part compiles against the declarations of the editor")
    write(t,decl,"core","package core\n\nvalue :: proc() -> i64\n")
    runtime_last,editor_last:=hashes(t,&p,&runtime_lib,&editor_lib,stamp_file,decl,runtime_packages,editor_packages)
    testing.expect(t,runtime_last!=runtime_after && editor_last!=editor_after,"both compile against the declarations of the runtime")
}
