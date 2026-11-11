package build

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// The demo's engine plugins build one library per part: the runtime parts in
// the order of the plugins, dependencies first, then the editor parts for the
// editor; each compiles against the parts of its plugin and of those it
// depends on.
@(test)
plugin_libraries_follow_the_parts_and_their_dependencies :: proc(t:^testing.T) {
    root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    p,error:=project.open(project.path(root,"demo",allocator=context.temp_allocator),root,context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"the demo opens: %v",error) {return}
    editor:=plugin_libraries(&p,true,context.temp_allocator)
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
    runtime_parts:=0
    for lib in editor {
        if lib.part==.Runtime && !lib.project {runtime_parts+=1}
    }
    for lib,i in editor {
        if lib.part==.Editor {testing.expectf(t,i>=runtime_parts,"%s builds after every runtime part",lib.path)}
    }
    testing.expect(t,index_of(editor,"profiler/editor")>=0)
    // The game of the demo is a library of its own, after the engine plugins it may use.
    game:=editor[len(editor)-1]
    testing.expect(t,game.project && game.path=="game" && slice.contains(game.needs,"animation/runtime") && !slice.contains(game.needs,"previews/editor"),"the game compiles against the runtime parts")
    testing.expect(t,plugins_mode(&p,true)=="minimal" && plugins_mode(&p,false)=="speed")
    // Optimized, a library of a plugin or of the project is one module, as the
    // game that ships compiles it; unoptimized, one module per package.
    cases:=[]struct{optimization:project.Optimization,dev:bool,level:string,split:bool}{
        {.Speed,true,"-o:minimal",true},
        {.Minimal,false,"-o:minimal",true},
        {.None,false,"-o:none",true},
        {.Size,false,"-o:size",false},
        {.Speed,false,"-o:speed",false},
        {.Aggressive,false,"-o:aggressive",false},
    }
    for c in cases {
        p.manifest.build.optimization=c.optimization
        libraries:=[?][]string{
            plugin_flags(&p,c.dev,context.temp_allocator),
            target_flags(&p,.Editor,nil,context.temp_allocator,c.dev),
        }
        for flags,i in libraries {
            testing.expectf(t,slice.contains(flags,c.level) && slice.contains(flags,"-use-separate-modules")==c.split,"library %d at %v (dev %v): %v",i,c.optimization,c.dev,flags)
        }
    }
}

// A plugin library is built from the same things in every project of an
// engine: with the same flags they share it through the cache, and those a
// package of the engine brings serve any of them.
@(test)
a_plugin_library_is_the_same_in_every_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=slashes(project.path_absolute(#directory+"../.."),context.temp_allocator)
    engine:=Engine_Paths{stamp=project.path(root,".mirai","engine","none",ENGINE_STAMP)}
    hashes:[2]u64
    for &hash in hashes {
        folder:=base.test_folder(t,"plugin-project")
        if folder=="" {return}
        testing.expect(t,os.write_entire_file(project.path(folder,project.PROJECT_FILE),`{"name": "Shared", "plugins": ["ragdoll"]}`)==nil)
        p,open_error:=project.open(folder,root)
        if !testing.expectf(t,open_error.code==.None,"the project opens: %v",open_error) {return}
        libraries:=plugin_libraries(&p,true)
        found:=-1
        for lib,i in libraries {if lib.path=="ragdoll/runtime" {found=i}}
        if !testing.expect(t,found>=0 && len(libraries[found].needs)>0) {return}
        hash,_=plugin_library_hashes(&p,libraries,found,"odin",plugin_flags(&p,true),engine,nil)
    }
    testing.expect_value(t,hashes[1],hashes[0])
}

// On Windows what links against a library links against an import library
// made from the module definition declare writes, before the library
// compiles: it names the file the library is published as and what it
// exports, and the library, here under a folder with spaces, compiles
// without one of its own.
@(test)
a_plugin_library_is_linked_against_an_import_library_made_ahead :: proc(t:^testing.T) {
    when IMPORT_LIBRARIES_AHEAD {
        context.allocator=context.temp_allocator
        root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
        compiler,found:=compiler_find(root,context.temp_allocator)
        if !testing.expect(t,found,"no Odin compiler") {return}
        folder:=base.test_folder(t,"plugin-spaces")
        if folder=="" {return}
        sources:=project.path(folder,"a folder","plugins")
        testing.expect(t,os.make_directory_all(project.path(sources,"thing/runtime"))==nil)
        testing.expect(t,os.write_entire_file(project.path(sources,"thing/runtime/answer.odin"),"package thing\n\nanswer :: proc() -> i32 {return 42}\n")==nil)
        lib:=Plugin_Library{name="thing",path="thing/runtime",packages={"thing/runtime"},root=sources,file="plugin-thing-runtime-minimal-00000001",
            stage=project.path(folder,"a folder","minimal","stage-thing-runtime"),linked=project.path(folder,"a folder","lib","plugin-thing-runtime-minimal-00000001.lib")}
        testing.expect(t,os.make_directory_all(project.path(folder,"a folder","lib"))==nil)
        if failed:=plugin_library_prepare(&lib);!testing.expectf(t,len(failed)==0,"%v",failed) {return}
        testing.expect_value(t,import_libraries_make(compiler,{{plugin_definition(&lib),lib.linked}}),"")
        import_library,read:=os.read_entire_file(lib.linked,context.temp_allocator)
        testing.expect(t,read==nil && strings.contains(string(import_library),"plugin-thing-runtime-minimal-00000001.dll") && strings.contains(string(import_library),"plugins.thing.runtime.answer"),"the import library names the published file and what it exports")
        staged:=project.path(folder,"a folder","staged.dll")
        command:=plugin_command(&lib,compiler,lib.stage,staged,{"-build-mode:dll","-o:minimal"})
        memory,_:=compiler_memory()
        state,_,errors,error:=subprocess.exec({command=command,env=child_environment(root,context.temp_allocator)},context.temp_allocator,{memory=memory})
        if !testing.expectf(t,error==nil && state.exit_code==0,"the library does not link:\n%s",string(errors)) {return}
        testing.expect(t,os.is_file(staged) && !os.is_file(project.path(folder,"a folder","staged.lib")),"the library leaves no import library of its own")
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
@(private)
plugin_job :: proc(p:^project.Project,compiler:string) -> ^Job {
    job:=new(Job,context.temp_allocator)
    job.allocator=context.temp_allocator
    _=virtual.arena_init_growing(&job.arena)
    a:=virtual.arena_allocator(&job.arena)
    job.target=.Editor
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
    folder:=base.test_folder(t,"plugin-split")
    if folder=="" {return}
    engine,game:=split_plugin_write(t,folder)
    p,error:=project.open(game,engine)
    if !testing.expectf(t,error.code==.None,"the project opens: %v",error) {return}
    world:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(world.errors)==0,"%v",world.errors) {return}
    testing.expect(t,strings.contains(world.game_world,`"plugins:thing/runtime/sim"`),"the world reads the attributes of the package of the folder")
    testing.expect(t,!strings.contains(world.game_world,"testdata"))
    libraries:=plugin_libraries(&p,true)
    if !testing.expect_value(t,len(libraries),1) {return}
    testing.expect_value(t,len(libraries[0].packages),2)
    testing.expect(t,slice.contains(libraries[0].packages,"thing/runtime") && slice.contains(libraries[0].packages,"thing/runtime/sim"))
    testing.expect(t,os.make_directory_all(engine_paths(engine,.Dev).decl)==nil)

    job:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&job.arena)
    if !testing.expect_value(t,job_plugins_plan(job,&p,{project=&p,target=.Editor,dev=true,engine=.Dev}),Failure.None) {return}
    if !testing.expect_value(t,len(job.plugin_queue),1) {return}
    job_plugins_start(job)
    if !testing.expect_value(t,len(job.compiles),1) {return}
    compile:=pop(&job.compiles)
    state,_:=subprocess.wait(&compile.process)
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
    executable:=project.path(plugins_libraries_folder(p.root),strings.concatenate({"split",project.EXECUTABLE_SUFFIX}))
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
    testing.expect(t,base.remove_all(project.folder_path(p.root,.Generated))==nil)
    again:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&again.arena)
    if !testing.expect_value(t,job_plugins_plan(again,&p,{project=&p,target=.Editor,dev=true,engine=.Dev}),Failure.None) {return}
    testing.expect_value(t,len(again.plugin_queue),0)
    testing.expect_value(t,again.result.plugins_restored,1)
    testing.expect_value(t,again.result.plugins_built,1)
    testing.expect(t,os.is_file(lib.library) && os.is_file(lib.linked))
    testing.expect(t,plugins_current(&p,compiler,true,.Dev),"the library copied stands as built")
    declaration:=project.path(plugins_decl(p.root,"minimal"),"thing","runtime","sim","sim.odin")
    testing.expect(t,os.is_file(declaration),"its declarations are written")

    // A part whose sources changed and whose library did not build has no
    // stamp: its declarations name a library that is not there. With the
    // sources back they are written again, for the library that stands.
    source:=project.path(engine,"plugins","thing","runtime","sim","sim.odin")
    before,_:=os.read_entire_file(source,context.temp_allocator)
    declared_before,_:=os.read_entire_file(declaration,context.temp_allocator)
    testing.expect(t,os.write_entire_file(source,strings.concatenate({string(before),"\nmore :: proc() -> i32 {return 1}\n"}))==nil)
    changed:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&changed.arena)
    testing.expect_value(t,job_plugins_plan(changed,&p,{project=&p,target=.Editor,dev=true,engine=.Dev}),Failure.None)
    testing.expect_value(t,len(changed.plugin_queue),1)
    testing.expect(t,os.write_entire_file(source,before)==nil)
    testing.expect(t,!plugins_current(&p,compiler,true,.Dev),"what was declared and not built does not stand")
    back:=plugin_job(&p,compiler)
    defer virtual.arena_destroy(&back.arena)
    testing.expect_value(t,job_plugins_plan(back,&p,{project=&p,target=.Editor,dev=true,engine=.Dev}),Failure.None)
    declared_after,_:=os.read_entire_file(declaration,context.temp_allocator)
    testing.expect(t,string(declared_after)==string(declared_before),"the declarations are those of the library that stands")
    testing.expect(t,plugins_current(&p,compiler,true,.Dev))
}

// The cache keeps the entries used last and writes a whole one once.
@(test)
the_shared_cache_keeps_the_entries_used_last :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"plugin-cache")
    if folder=="" {return}
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
    folder:=base.test_folder(t,"plugin-imports")
    if folder=="" {return}
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
    folder:=base.test_folder(t,"plugin-params")
    if folder=="" {return}
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
    if !testing.expect_value(t,job_plugins_plan(job,&p,{project=&p,target=.Editor,dev=true,engine=.Dev}),Failure.None) {return}
    if !testing.expect_value(t,len(job.plugin_queue),1) {return}
    job_plugins_start(job)
    if !testing.expect_value(t,len(job.compiles),1) {return}
    compile:=job.compiles[0]
    ordered_remove(&job.compiles,0)
    state,_:=subprocess.wait(&compile.process)
    job_plugin_finish(job,compile,state.exit_code)
    if !testing.expectf(t,job.result.status==.Running,"the library builds: %v %s",job.result.diagnostics,job.result.text) {return}

    program:=project.path(folder,"program")
    testing.expect(t,os.make_directory_all(program)==nil)
    testing.expect(t,os.write_entire_file(project.path(program,"main.odin"),"package main\n\nimport \"core:os\"\nimport \"mirai:core\"\nimport thing \"plugins:thing/runtime\"\n\nmain :: proc() {\n    probes:core.Table(core.Probe)\n    asks:core.Asks\n    thing.thing_probe(core.Prober{probes=&probes,asks=&asks})\n    os.exit(int(probes.values[1].value)+int(asks.count))\n}\n")==nil)
    executable:=project.path(plugins_libraries_folder(p.root),strings.concatenate({"params",project.EXECUTABLE_SUFFIX}))
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
    folder:=base.test_folder(t,"declare-any")
    if folder=="" {return}
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
    entry_write(stage,"__engine",{"mirai:thing"})
    testing.expect(t,os.make_directory_all(out)==nil || os.is_dir(out))
    memory,_:=compiler_memory()
    environment:=child_environment(repository,context.temp_allocator)
    built_library,_,library_errors,library_error:=subprocess.exec({command={compiler,"build",project.path(stage,"__engine"),"-build-mode:dll",fmt.tprintf("-collection:mirai=%s",stage),fmt.tprintf("-out:%s",library),"-o:minimal"},env=environment},context.temp_allocator,{memory=memory})
    if !testing.expectf(t,library_error==nil && built_library.exit_code==0,"the library does not build:\n%s",string(library_errors)) {return}

    program:=project.path(folder,"program")
    testing.expect(t,os.make_directory_all(program)==nil)
    main_text:="package main\n\nimport \"core:os\"\nimport \"mirai:thing\"\n\nKind :: enum u8 {Fire,Cancel,Section}\nRequest :: struct {kind:Kind,at:i32}\n\nmain :: proc() {\n    buffer:[128]u8\n    text:=thing.report(buffer[:],\"a %v of %v, %d\",Kind.Cancel,Request{.Section,7},thing.count(41))\n    os.write(os.stdout,transmute([]u8)text)\n}\n"
    testing.expect(t,os.write_entire_file(project.path(program,"main.odin"),main_text)==nil)
    executable:=project.path(out,strings.concatenate({"program",project.EXECUTABLE_SUFFIX}))
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

// The libraries of plugins compile at once, each as soon as what it links
// against is there: on Windows the import libraries made ahead, so all of
// them start together; elsewhere the libraries, so one that depends on
// another waits for it, and one that does not starts beside it.
@(test)
a_plugin_library_compiles_once_those_it_links_against_are_published :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repository:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(repository,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    folder:=base.test_folder(t,"plugin-order")
    if folder=="" {return}
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
    if !testing.expect_value(t,job_plugins_plan(job,&p,{project=&p,target=.Editor,dev=true,engine=.Dev}),Failure.None) {return}
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
    testing.expect(t,running(job,middle_index)==IMPORT_LIBRARIES_AHEAD,"a library waits for the one it links against unless what it links was made ahead")
    for len(job.compiles)>0 {
        if running(job,middle_index) && !IMPORT_LIBRARIES_AHEAD {testing.expect(t,job.plugin_published[base_index],"it starts once that one is published")}
        compile:=job.compiles[0]
        ordered_remove(&job.compiles,0)
        state,_:=subprocess.wait(&compile.process)
        job_plugin_finish(job,compile,state.exit_code)
        if !testing.expectf(t,job.result.status==.Running,"%s builds: %v %s",job.plugins[compile.library].path,job.result.diagnostics,job.result.text) {return}
        job_plugins_start(job)
    }
    testing.expect_value(t,len(job.plugin_queue),0)
    testing.expect_value(t,job.result.plugins_built,3)
    for published in job.plugin_published {testing.expect(t,published)}
}

// A plugin library follows the declarations of the packages of the engine it
// reaches and no other: those its sources import, those they import in turn,
// and those the declarations of the parts it compiles against import. A body
// only the library of the engine carries declares the same and builds none.
@(test)
a_plugin_library_follows_the_declarations_of_the_packages_it_reaches :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"plugin-decl")
    if folder=="" {return}
    write :: proc(t:^testing.T,root,file,text:string) {
        path:=project.path(root,file)
        parent:=path[:strings.last_index_byte(path,'/')]
        testing.expect(t,os.make_directory_all(parent)==nil || os.is_dir(parent))
        testing.expect(t,os.write_entire_file(path,text)==nil,path)
    }
    p:project.Project
    p.engine_root=project.path(folder,"engine")
    write(t,p.engine_root,"core/core.odin","package core\n\nvalue :: proc() -> i32 {return 1}\n\nhalf :: #force_inline proc(v:i32) -> i32 {return v/2}\n")
    write(t,p.engine_root,"render/render.odin","package render\n\nimport \"mirai:core\"\n\nFRAMES :: 4\n\nframes :: proc() -> i32 {return core.value()}\n")
    write(t,p.engine_root,"engine/render/view.odin","package engine_render\n\nimport \"mirai:render\"\n\nView :: struct {frames:[render.FRAMES]i32}\n")
    write(t,p.engine_root,"ui/ui.odin","package ui\n\nimport \"mirai:core\"\n\nBox :: struct {width:i32}\n")
    write(t,p.engine_root,"editor/editor.odin","package editor\n\nimport \"mirai:ui\"\n\nPanel :: struct {box:ui.Box}\n")
    write(t,p.engine_root,"plugins/plain/runtime/plain.odin","package plain\n\nimport \"mirai:core\"\n\nvalue :: proc() -> i32 {return core.half(core.value())}\n")
    write(t,p.engine_root,"plugins/drawn/runtime/drawn.odin","package drawn\n\nimport draw \"mirai:engine/render\"\n\nView :: struct {view:draw.View}\n")
    write(t,p.engine_root,"plugins/over/runtime/over.odin","package over\n\nimport drawn \"plugins:drawn/runtime\"\n\nOver :: struct {view:drawn.View}\n")
    write(t,p.engine_root,"plugins/tool/editor/tool.odin","package tool\n\nimport \"mirai:editor\"\n\nTool :: struct {panel:editor.Panel}\n")
    plugins:=project.path(folder,"plugins")
    Part :: enum {Plain,Drawn,Over,Tool}
    sources:=project.path(p.engine_root,"plugins")
    libraries:=[Part]Plugin_Library{
        .Plain={part=.Runtime,root=sources,packages={"plain/runtime"},stage=project.path(plugins,"stage-plain-runtime")},
        .Drawn={part=.Runtime,root=sources,packages={"drawn/runtime"},stage=project.path(plugins,"stage-drawn-runtime")},
        .Over={part=.Runtime,root=sources,packages={"over/runtime"},needs={"drawn/runtime"},stage=project.path(plugins,"stage-over-runtime")},
        .Tool={part=.Editor,root=sources,packages={"tool/editor"},stage=project.path(plugins,"stage-tool-editor")},
    }
    // drawn declares what over compiles against, as its build does.
    if errors:=plugin_library_prepare(&libraries[.Drawn]);!testing.expectf(t,len(errors)==0,"drawn declares: %v",errors) {return}
    built:=project.path(folder,"built")
    engine:=Engine_Paths{decl=project.path(built,"decl"),declared=project.path(built,"engine.declared"),stamp=project.path(built,ENGINE_STAMP)}
    keys :: proc(p:^project.Project,libraries:^[Part]Plugin_Library,engine:Engine_Paths) -> (keys:[Part]u64) {
        declared:=declared_read(engine.declared,context.temp_allocator)
        for &lib,part in libraries {
            keys[part],_=plugin_library_hashes(p,slice.enumerated_array(libraries),int(part),"",nil,engine,declared)
            plugin_library_declared(&lib,&declared)
        }
        return
    }
    // The engine declares its sources and what each declaration reaches, as its build does.
    declare_engine :: proc(t:^testing.T,root,built:string,engine:Engine_Paths) {
        errors,_:=declare({root=root,packages={"core","render","engine/render","ui","editor"},binary="mirai",library=project.path(built,"mirai-engine.lib"),stage=project.path(built,"stage"),decl=engine.decl,names=true})
        testing.expectf(t,len(errors)==0,"the engine declares: %v",errors)
        testing.expect(t,declared_write(engine.decl,engine.declared))
    }
    declare_engine(t,p.engine_root,built,engine)
    before:=keys(&p,&libraries,engine)
    cases:=[]struct{what,file,text:string,built_again:bit_set[Part]}{
        {"a body the library of the engine carries","core/core.odin","package core\n\nvalue :: proc() -> i32 {return 2}\n\nhalf :: #force_inline proc(v:i32) -> i32 {return v/2}\n",{}},
        {"a constant of a package reached through another","render/render.odin","package render\n\nimport \"mirai:core\"\n\nFRAMES :: 8\n\nframes :: proc() -> i32 {return core.value()}\n",{.Drawn,.Over}},
        {"a declaration of a package imported under another name","engine/render/view.odin","package engine_render\n\nimport \"mirai:render\"\n\nView :: struct {frames:[render.FRAMES]i32,layer:i32}\n",{.Drawn,.Over}},
        {"a field of a package the editor imports","ui/ui.odin","package ui\n\nimport \"mirai:core\"\n\nBox :: struct {width,height:i32}\n",{.Tool}},
        {"a declaration of the editor","editor/editor.odin","package editor\n\nimport \"mirai:ui\"\n\nPanel :: struct {box:ui.Box,open:bool}\n",{.Tool}},
        {"the body of an inline procedure, which only one of them calls","core/core.odin","package core\n\nvalue :: proc() -> i32 {return 2}\n\nhalf :: #force_inline proc(v:i32) -> i32 {return v>>1}\n",{.Plain}},
        {"a declaration of a package all import that none names","core/core.odin","package core\n\nvalue :: proc() -> i32 {return 2}\n\nhalf :: #force_inline proc(v:i32) -> i32 {return v>>1}\n\nSpare :: struct {x:i32}\n",{}},
    }
    for c in cases {
        write(t,p.engine_root,c.file,c.text)
        declare_engine(t,p.engine_root,built,engine)
        after:=keys(&p,&libraries,engine)
        for part in Part {
            testing.expectf(t,(after[part]!=before[part])==(part in c.built_again),"%s: %v built again %v",c.what,part,after[part]!=before[part])
        }
        before=after
    }
    // The libraries of the engine a part links against are others in each mode.
    other:=engine
    other.mode=.Dev if engine.mode==.Release else .Release
    linked:=keys(&p,&libraries,other)
    for part in Part {testing.expectf(t,linked[part]!=before[part],"%v against the libraries of another mode is another library",part)}
    // Without the index of the declarations, a library follows every build of the engine.
    testing.expect(t,os.remove(engine.declared)==nil)
    for build in ([2]string{"1","2"}) {
        testing.expect(t,os.write_entire_file(engine.stamp,build)==nil)
        after:=keys(&p,&libraries,engine)
        for part in Part {
            testing.expectf(t,after[part]!=before[part],"without the index: %v follows the build %s",part,build)
        }
        before=after
    }
}
