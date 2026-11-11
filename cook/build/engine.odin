package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/shaders"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"

// The binaries of the engine, each built once per version of what it is
// built from, under <engine>/.mirai/engine/<mode>: those of dev and of
// release stand side by side, so going from one mode to the other builds
// nothing, and every checkout of the repository shares the libraries through
// a cache.
//
//   mirai-<library>  the libraries (engine_libraries), each linked against the ones it needs
//   decl/            the declarations projects compile against instead of those sources
//   engine.declared  what each declaration is with what it reaches (declared.odin)
//   mirai-editor, mirai-player  the programs that load the library of a project
//   mirai-import     the program of mirai import and of the sync of builds, on the libraries of the editor
//   mirai-author     the program of mirai ui and mirai scene, on the libraries of the editor
//   stage/           the copy the libraries are built from (declare.odin)
//
// What is rebuilt is a library, so the mode decides how the packages are cut
// into libraries. Release has one per layer: the compiler optimizes across
// the packages of each. Dev has one per unit: a package that is edited often
// is one of its own, so the body of a procedure compiles its package again and
// nothing else, and those that change little share one, since every library
// pays a compile of the runtime and a link. A package that binds a C library
// linked into it is a unit by itself: the library keeps what a second copy of
// it would not have, so nothing else shares the unit that is never swapped
// (engine_swap).
//
// Each part is built again only for what it reads: a library for its sources
// and for the declarations they name in other libraries, so a change in the
// body of a procedure builds its library and no other, and one of a
// declaration builds, besides, the libraries and the programs that name it or
// something that reaches it.
//
// A project then compiles its generated world, its game and its plugins
// alone, into a library the editor or the player loads.

// The layers of the packages, cut where no import goes up: the libraries of release.
Engine_Layer :: enum u8 {
    Base,   // what needs no renderer: the standard library, the system, the device and the data core
    Engine, // the rest of what a game or a plugin can import
    Cook,   // engine-time: what imports, cooks and builds
    Editor, // engine-time: the editor
}

@(private)
ENGINE_LAYER_NAMES :: [Engine_Layer]string{.Base="base",.Engine="engine",.Cook="cook",.Editor="editor"}

Engine_Package :: struct {
    layer:Engine_Layer,
    path:string, // relative to the root and to the collection: core, engine/scene
    unit:string, // Dev: the library it shares with the packages beside it. "": one of its own
}

// Every package of the engine with a declaration, each after the ones it
// imports, with its layer. A package goes in the lowest layer that has what
// it imports; a C library, with the package that binds it. The packages of a
// layer, and those of a unit, stand together.
ENGINE_PACKAGES :: [?]Engine_Package{
    {.Base,"std/base","std"},{.Base,"std/subprocess","std"},{.Base,"std/math","std"},{.Base,"std/geom","std"},{.Base,"std/serial","std"},
    {.Base,"std/spatial","std"},{.Base,"std/jobs","std"},{.Base,"std/anim","std"},{.Base,"std/ai","std"},{.Base,"std/input","std"},
    {.Base,"std/ui_format","std"},{.Base,"std/compressor","std"},{.Base,"std/compressor/bc7split","std"},{.Base,"std/compressor/lz/entropy","std"},{.Base,"std/compressor/lz/match","std"},
    {.Base,"std/compressor/lz/parse","std"},{.Base,"std/compressor/lz","std"},{.Base,"audio","system"},{.Base,"platform","system"},{.Base,"rhi","system"},
    {.Base,"project","system"},{.Base,"core",""},

    {.Engine,"asset",""},{.Engine,"net",""},{.Engine,"render/abi","render"},{.Engine,"render","render"},{.Engine,"third_party/freetype","freetype"},
    {.Engine,"ui","ui"},{.Engine,"host",""},{.Engine,"engine/volume","engine"},{.Engine,"engine/input","engine"},{.Engine,"engine/scene","engine"},
    {.Engine,"engine/render","engine"},{.Engine,"engine/audio","engine"},{.Engine,"engine/gui","engine"},{.Engine,"engine/camera","engine"},{.Engine,"engine/save","engine"},

    {.Cook,"third_party/ufbx","ufbx"},{.Cook,"cook/workspace","cook"},{.Cook,"cook/cache","cook"},{.Cook,"cook/far","cook"},{.Cook,"cook/compressor/lz","cook"},{.Cook,"cook/compressor/bc7split","cook"},{.Cook,"cook/compressor/texture/common","cook"},
    {.Cook,"cook/compressor/texture/bc67","cook"},{.Cook,"cook/compressor/texture/bc1","cook"},{.Cook,"cook/compressor/texture/bc4","cook"},{.Cook,"cook/compressor/texture/bc6","cook"},{.Cook,"cook/compressor/texture/bc7","cook"},
    {.Cook,"cook/compressor/texture","cook"},{.Cook,"cook/textures","cook"},{.Cook,"cook/image","cook"},{.Cook,"cook/movie","cook"},{.Cook,"cook/rig","cook"},
    {.Cook,"cook/import","cook"},{.Cook,"cook/import/obj","cook"},{.Cook,"cook/import/gltf","cook"},{.Cook,"cook/import/usd","cook"},
    {.Cook,"cook/import/fbx","cook"},{.Cook,"cook/shaders","cook"},{.Cook,"cook/prefab","cook"},{.Cook,"cook/import/sources","cook"},{.Cook,"cook/author","cook"},
    {.Cook,"cook/install","cook"},{.Cook,"cook/build",""},

    {.Editor,"third_party/sqlite","sqlite"},{.Editor,"editor/api","editor-parts"},{.Editor,"editor/acp","editor-parts"},{.Editor,"editor/diff","editor-parts"},{.Editor,"editor/ai_store","editor-parts"},
    {.Editor,"editor/git","editor-parts"},{.Editor,"editor/history","editor-parts"},{.Editor,"editor/records","editor-parts"},{.Editor,"editor",""},
}

@(private)
ENGINE_PACKAGE_COUNT :: len(ENGINE_PACKAGES)

@(private)
engine_package :: proc(index:int) -> string {
    packages:=ENGINE_PACKAGES
    return packages[index].path
}

@(private)
engine_package_index :: proc(path:string) -> (index:int,found:bool) {
    packages:=ENGINE_PACKAGES
    for entry,at in packages {
        if entry.path==path {return at,true}
    }
    return
}

// The packages a game binary can contain: those of the layers that are not engine-time.
engine_runtime_packages :: proc(allocator:=context.allocator) -> []string {
    packages:=ENGINE_PACKAGES
    list:=make([dynamic]string,allocator)
    for entry in packages {
        if entry.layer<.Cook {append(&list,entry.path)}
    }
    return list[:]
}

// A library of the engine in a mode.
Engine_Library :: struct {
    name:string,       // stage/__mirai_<name> the package it is built from
    file:string,       // mirai-<name>, without its extension
    packages:[]string, // in the order of ENGINE_PACKAGES, where they stand together
    first:int,         // the index of the first one: a library imports only packages before its own
}

// The libraries of a mode, each after the ones it needs.
engine_libraries :: proc(mode:Engine_Mode,allocator:=context.allocator) -> []Engine_Library {
    packages,layers:=ENGINE_PACKAGES,ENGINE_LAYER_NAMES
    list:=make([dynamic]Engine_Library,allocator)
    paths:=make([dynamic]string,0,len(packages),allocator)
    previous:=""
    for entry,index in packages {
        name:=layers[entry.layer]
        if mode==.Dev {
            name=entry.unit
            if name=="" {name,_=strings.replace_all(entry.path,"/","-",allocator)}
        }
        append(&paths,entry.path)
        if index>0 && name==previous {
            last:=&list[len(list)-1]
            last.packages=paths[last.first:len(paths)]
            continue
        }
        previous=name
        append(&list,Engine_Library{name=name,file=strings.concatenate({"mirai-",name},allocator),packages=paths[index:index+1],first=index})
    }
    return list[:]
}

// Changes when what declare writes changes, so that binaries built by an
// earlier version are built again.
@(private)
DECLARE_VERSION :: 12

// The collection a stage is compiled as (Declare_Desc.staged): of the engine, and of a plugin library.
@(private)
STAGE_COLLECTION :: "staged"

Engine_Paths :: struct {
    mode:Engine_Mode,                 // of the binaries there: the one asked for, but in an installed engine
    folder:string,
    decl:string,                      // the collection "mirai" of a project
    declared:string,                  // what each declaration is with what it reaches (declared.odin)
    stage:string,
    work:string,                      // what the compilers say while a build runs
    editor_program,player_program:string,
    import_program:string,            // runs cook/import/sources.command: what mirai import does
    author_program:string,            // runs cook/author.command: what mirai ui and mirai scene do
    stamp:string,
}

// What a program links against to use a library: the import library on Windows, the library elsewhere.
@(private)
library_import_file :: proc(name:string,allocator:=context.allocator) -> string {
    when ODIN_OS==.Windows {return strings.concatenate({name,".lib"},allocator)}
    else {return project.library_file(name,allocator)}
}

// The file of a library of the engine, and what links against it.
@(private)
engine_library_files :: proc(paths:Engine_Paths,library:Engine_Library,allocator:=context.allocator) -> (file,linked:string) {
    file=project.path(paths.folder,project.library_file(library.file,context.temp_allocator),allocator=allocator)
    linked=project.path(paths.folder,library_import_file(library.file,context.temp_allocator),allocator=allocator)
    return
}

// What a library of the engine leaves. On Windows the import library is a file
// of its own: without it the projects and the programs do not link, and the
// only build that makes it is the one that declares the library. Elsewhere it
// is the library itself, and this is the same check twice.
@(private)
library_present :: proc(library,linked_against:string) -> bool {
    return os.is_file(library) && os.is_file(linked_against)
}

// Dev unless --release is asked for: no command takes its mode from what was built before.
Engine_Mode :: enum u8 {
    Dev,     // -o:minimal: for whoever changes the engine
    Release, // -o:speed: to play, measure and ship
}

@(private)
ENGINE_MODE_FOLDERS :: [Engine_Mode]string{.Dev="dev",.Release="release"}

// The mode of the binaries this code is compiled into. The editor builds the
// libraries of a project against the declarations of its own mode.
ENGINE_MODE_HERE :: Engine_Mode.Dev when ODIN_OPTIMIZATION_MODE==.Minimal || ODIN_OPTIMIZATION_MODE==.None else Engine_Mode.Release

@(private)
ENGINE_STAMP :: "engine.stamp"

// The mode of the binaries an installed engine carries, the only one it
// has: dev builds the libraries of a project at -o:minimal against them.
ENGINE_MODE_INSTALLED :: Engine_Mode.Release

// The mode of the binaries a command gets: the one it asks for, but in an
// installed engine, which has the binaries of one.
engine_mode_resolve :: proc(engine_root:string,mode:Engine_Mode) -> Engine_Mode {
    return ENGINE_MODE_INSTALLED if project.engine_installed(engine_root) else mode
}

// The folder of the binaries of a mode.
engine_paths :: proc(engine_root:string,mode:Engine_Mode,allocator:=context.allocator) -> (paths:Engine_Paths) {
    context.allocator=allocator
    folders:=ENGINE_MODE_FOLDERS
    paths.mode=engine_mode_resolve(engine_root,mode)
    paths.folder=project.path(engine_root,".mirai","engine",folders[paths.mode])
    paths.decl=project.path(paths.folder,"decl")
    paths.declared=project.path(paths.folder,"engine.declared")
    paths.stage=project.path(paths.folder,"stage")
    paths.work=project.path(paths.folder,"work")
    paths.editor_program=project.path(paths.folder,strings.concatenate({"mirai-editor",project.EXECUTABLE_SUFFIX},context.temp_allocator))
    paths.player_program=project.path(paths.folder,strings.concatenate({"mirai-player",project.EXECUTABLE_SUFFIX},context.temp_allocator))
    paths.import_program=project.path(paths.folder,strings.concatenate({"mirai-import",project.EXECUTABLE_SUFFIX},context.temp_allocator))
    paths.author_program=project.path(paths.folder,strings.concatenate({"mirai-author",project.EXECUTABLE_SUFFIX},context.temp_allocator))
    paths.stamp=project.path(paths.folder,ENGINE_STAMP)
    return
}

Engine_Desc :: struct {
    engine_root:string,
    compiler:string, // empty: compiler_find
    mode:Engine_Mode,
    force:bool,
}

Engine_Result :: struct {
    status:Status,
    shaders:shaders.Result,   // the generation of shaders/build and of the tables that embed it
    mode:Engine_Mode,         // of the binaries
    compiled:[]string,        // the libraries it compiled, by their files
    restored:int,             // the libraries it copied from the cache the checkouts of the repository share
    programs:bool,            // it compiled the programs
    failure:Failure,
    step:string,              // what failed: the declarations, a library, a program
    diagnostics:[]Diagnostic,
    text:string,
    seconds:f64,
}

// What the last compile of a library left. Zero: nothing of it stands, and it
// is declared and compiled again.
@(private)
Library_Stamp :: struct {
    sources:u64, // the fingerprint of its sources and of what it was compiled with
    tools:u64,   // the compiler, the flags and what it embeds besides its sources
    against:u64, // the declarations of other libraries its sources name (declared_key)
}

// What a library declares, which a compile of it does not move: a program
// that runs the library takes one built again in place while this stands
// (engine_swap).
@(private)
Library_Declared :: struct {
    hash:u64,      // of what its packages declare (Declare_Changed.declared)
    moved:string,  // the declaration that last changed it; "": none since its first build
    pinned:string, // what it keeps that a newer build of it would not have; "": nothing
}

// What the last build of a mode left: of each library, of the programs (the
// compiler and the flags they were built with, and the declarations they
// name) and of declare. What a build is about to compile is zeroed before
// anything is built, so a build that stops halfway leaves those parts to the
// next one.
@(private)
Engine_Stamp :: struct {
    libraries:[]Library_Stamp, // as engine_libraries has them
    declared:[]Library_Declared,
    programs:u64,
    programs_against:u64,
    declares:int,
}

// What a build of a mode finds: the fingerprints of now, and whether every
// part stands as the last build left it.
@(private)
Engine_Plan :: struct {
    previous:Engine_Stamp,
    stamped:bool, // previous is of a build of this version of declare
    flags:[dynamic]string,
    libraries:[]Library_Stamp, // sources and tools: what they name is known once they are declared
    programs:u64,
    current:bool,
}

@(private)
engine_programs :: proc(paths:Engine_Paths) -> [4]string {
    return {paths.editor_program,paths.player_program,paths.import_program,paths.author_program}
}

// The package of a library that embeds the shaders of the engine.
@(private)
ENGINE_EMBEDS_SHADERS :: "render"

@(private)
engine_plan :: proc(root,compiler:string,mode:Engine_Mode,paths:Engine_Paths,libraries:[]Engine_Library) -> (plan:Engine_Plan) {
    plan.flags=engine_flags(root,mode==.Dev)
    // render embeds the code of the shaders of the engine. A release build follows it, encoded to
    // ship. A dev build follows only its table (render/shaders_gen.odin), which says what the
    // stages bind and nothing of their code: the code it embeds is that of when it was compiled,
    // and a generation with newer code loads into it (render.shader_generation_current).
    names:=shaders.EMBEDDED_NAMES
    embedded:=[2]string{project.path(root,"shaders/build/manifest.json",allocator=context.temp_allocator),project.path(root,"shaders/build",names[shaders.HOST_BACKEND],allocator=context.temp_allocator)}
    plan.programs,_=fingerprint(root,compiler,plan.flags[:],nil)
    plan.libraries=make([]Library_Stamp,len(libraries),context.temp_allocator)
    for &library,which in plan.libraries {
        loads:=embedded[:] if mode==.Release && slice.contains(libraries[which].packages,ENGINE_EMBEDS_SHADERS) else nil
        library.sources,_=fingerprint(root,compiler,plan.flags[:],engine_sources(root,libraries[which].packages,..loads))
        library.tools,_=fingerprint(root,compiler,plan.flags[:],loads)
    }
    previous,stamped:=engine_stamp_read(paths.stamp,libraries)
    // Without the declarations nothing compiles against what stands.
    if !stamped || previous.declares!=DECLARE_VERSION || !os.is_dir(paths.decl) || !os.is_file(paths.declared) {
        plan.previous.libraries=make([]Library_Stamp,len(libraries),context.temp_allocator)
        plan.previous.declared=make([]Library_Declared,len(libraries),context.temp_allocator)
        return
    }
    plan.previous,plan.stamped=previous,true
    // Sources that are the ones of the stamp declare what they did: what each library names stands too.
    plan.current=previous.programs==plan.programs
    for library,which in plan.libraries {
        plan.current&&=previous.libraries[which].sources==library.sources && library_present(engine_library_files(paths,libraries[which],context.temp_allocator))
    }
    for program in engine_programs(paths) {plan.current&&=os.is_file(program)}
    return
}

// Whether engine_build of a mode would find everything as it is, the shaders
// of the engine and the binaries: what tells whether a build takes its turn.
// Takes no turn and writes nothing.
engine_current :: proc(engine_root:string,mode:Engine_Mode) -> bool {
    root:=slashes(engine_root,context.temp_allocator)
    if project.engine_installed(root) {return engine_installed_present(root)}
    if root=="" || !shaders.current({root=root,odin=true,ship=mode==.Release}) {return false}
    compiler,found:=compiler_find(root,context.temp_allocator)
    if !found {return false}
    return engine_plan(root,compiler,mode,engine_paths(root,mode,context.temp_allocator),engine_libraries(mode,context.temp_allocator)).current
}

// Whether the binaries of a mode there were built from these sources,
// without building. stamped: that mode has binaries with a stamp.
engine_state :: proc(engine_root:string,mode:Engine_Mode) -> (stamped,current:bool) {
    root:=slashes(engine_root,context.temp_allocator)
    if project.engine_installed(root) {
        present:=engine_installed_present(root)
        return present,present
    }
    paths:=engine_paths(root,mode,context.temp_allocator)
    libraries:=engine_libraries(mode,context.temp_allocator)
    if _,stamped=engine_stamp_read(paths.stamp,libraries);!stamped {return}
    compiler,found:=compiler_find(root,context.temp_allocator)
    if !found {return}
    current=engine_plan(root,compiler,mode,paths,libraries).current
    return
}

// The programs, each a main over the declarations of the libraries.
@(private)
Engine_Program :: struct {name,package_name,source,output:string}

@(private)
engine_program_sources :: proc(paths:Engine_Paths) -> [4]Engine_Program {
    return {
        {"editor program","editor","package main\n\nimport \"core:os\"\nimport \"mirai:editor\"\n\nmain :: proc() {os.exit(editor.launch(os.args[1:],editor.advance))}\n",paths.editor_program},
        {"player program","host","package main\n\nimport \"core:os\"\nimport \"mirai:host\"\n\nmain :: proc() {os.exit(host.launch(os.args[1:]))}\n",paths.player_program},
        {"import program","import",`package main

import "core:os"
import "mirai:cook/import/sources"
import "mirai:editor"

main :: proc() {os.exit(sources.command(os.args[1:],os.to_writer(os.stdout),os.to_writer(os.stderr),editor.plugin_import_formats))}
`,paths.import_program},
        {"author program","author",`package main

import "core:os"
import "mirai:cook/author"

main :: proc() {os.exit(author.command(os.args[1:],os.to_writer(os.stdout),os.to_writer(os.stderr)))}
`,paths.author_program},
    }
}

// Writes what a library compiles from its own packages: their sources staged
// and declared, and its entry. changed: what of the stage and of the
// declarations was written.
@(private)
engine_library_stage :: proc(root:string,paths:Engine_Paths,library:Engine_Library) -> (errors:[]string,changed:Declare_Changed,ok:bool) {
    _,linked:=engine_library_files(paths,library,context.temp_allocator)
    errors,changed=declare({root=root,packages=library.packages,binary="mirai",library=linked,stage=paths.stage,decl=paths.decl,staged=STAGE_COLLECTION,names=true,slots=paths.mode==.Dev,definition=engine_definition(paths,library)})
    if len(errors)>0 {return errors,changed,true}
    entry,written:=entry_write(paths.stage,engine_library_entry(library,context.temp_allocator),entry_imports(STAGE_COLLECTION,library.packages)[:])
    changed.stage||=entry
    return nil,changed,written
}

// The module definition its import library is made from (import_libraries_make).
@(private)
engine_definition :: proc(paths:Engine_Paths,library:Engine_Library) -> string {
    return project.path(paths.stage,strings.concatenate({library.file,".def"},context.temp_allocator),allocator=context.temp_allocator)
}

// The package a library is built from (entry_write): its name, as a package can be named.
@(private)
engine_library_entry :: proc(library:Engine_Library,allocator:=context.allocator) -> string {
    name,_:=strings.replace_all(library.name,"-","_",context.temp_allocator)
    return strings.concatenate({"__mirai_",name},allocator)
}

// What the sources of the engine name of each other. Of each library, the
// declarations of other libraries its sources name (the key of what it
// compiles against, declared_key) and the libraries before it that it reaches
// through its imports, directly or not: the ones it links against.
@(private)
Engine_Reach :: struct {
    names:[]map[string]bool,
    needs:[][]bool, // [library][library before it]
}

// only: the libraries to read, when no declaration moved: the others name
// what they named, and those read link one after another, which asks for no
// more than the few of them there are. nil: every library.
@(private)
engine_reach :: proc(root:string,libraries:[]Engine_Library,only:[]bool=nil) -> (reach:Engine_Reach) {
    a:=context.temp_allocator
    reach.names=make([]map[string]bool,len(libraries),a)
    reach.needs=make([][]bool,len(libraries),a)
    packages:=make([][ENGINE_PACKAGE_COUNT]bool,ENGINE_PACKAGE_COUNT,a)
    owner:[ENGINE_PACKAGE_COUNT]int
    for library,which in libraries {
        reach.names[which]=make(map[string]bool,a)
        reach.needs[which]=make([]bool,len(libraries),a)
        if only!=nil {
            if !only[which] {continue}
            for before in 0..<which {reach.needs[which][before]=only[before]}
        }
        skip:=make([]string,len(library.packages),a)
        for path,at in library.packages {skip[at]=fmt.tprintf("mirai:%s",path)}
        for path,at in library.packages {
            index:=library.first+at
            owner[index]=which
            row:=&packages[index]
            errors:=make([dynamic]string,a)
            _,files,_:=sources_read(project.path(root,path,allocator=a),&errors,a)
            declared_named(files,skip,&reach.names[which])
            // A package of the engine imports only the ones before it.
            for file in files {
                for imp in file.imports {
                    literal:=strings.trim(imp.fullpath,"\"`")
                    if !strings.has_prefix(literal,ENGINE_COLLECTION) {continue}
                    if other,found:=engine_package_index(literal[len(ENGINE_COLLECTION):]);found && other<index {row[other]=true}
                }
            }
            if only!=nil {continue}
            for other in 0..<index {
                if !row[other] {continue}
                for &to,beyond in row {to||=packages[other][beyond]}
            }
            for reached,other in row {
                if reached && owner[other]!=which {reach.needs[which][owner[other]]=true}
            }
        }
    }
    return
}

// Generates the shaders of the engine and builds the parts of its binaries
// that were not built from the same sources, compiler and flags. Blocks: it
// runs once per version.
engine_build :: proc(desc:Engine_Desc,allocator:=context.allocator) -> (result:Engine_Result) {
    context.allocator=allocator
    tick:=time.tick_now()
    // What the build did stands also when a part of it fails.
    done:Engine_Result
    done.mode=desc.mode
    compiled:=make([dynamic]string,allocator)
    result=engine_build_parts(desc,&done,&compiled)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    result.shaders=done.shaders
    result.mode,result.restored,result.programs=done.mode,done.restored,done.programs
    result.compiled=compiled[:]
    result.seconds=time.duration_seconds(time.tick_since(tick))
    return
}

@(private="file")
engine_build_parts :: proc(desc:Engine_Desc,done:^Engine_Result,compiled:^[dynamic]string) -> (result:Engine_Result) {
    root:=slashes(desc.engine_root,context.temp_allocator)
    if root=="" {
        result.status,result.failure=.Failed,.Engine_Missing
        return
    }
    // An installed engine carries its binaries and the shaders they embed.
    if project.engine_installed(root) {
        done.mode=ENGINE_MODE_INSTALLED
        if engine_installed_present(root) {
            result.status=.Up_To_Date
            return
        }
        return engine_fail(.Engine_Incomplete,"binaries of the installed engine",fmt.tprintf("%s lacks some of them: unpack the package of the engine again",engine_paths(root,ENGINE_MODE_INSTALLED,context.temp_allocator).folder))
    }
    mode:=desc.mode
    // Generated, not versioned: render embeds them and its table names them.
    done.shaders=shaders.generate({root=root,odin=true,ship=mode==.Release})
    if done.shaders.error!="" {
        result.status,result.failure,result.step,result.text=.Failed,.Shaders,"shaders of the engine",done.shaders.error
        return
    }
    paths:=engine_paths(root,mode,context.temp_allocator)
    compiler:=desc.compiler
    if compiler=="" {
        found,ok:=compiler_find(root,context.temp_allocator)
        if !ok {
            result.status,result.failure=.Failed,.Compiler_Missing
            return
        }
        compiler=found
    }
    compiler=slashes(compiler,context.temp_allocator)
    libraries:=engine_libraries(mode,context.temp_allocator)
    plan:=engine_plan(root,compiler,mode,paths,libraries)
    if !desc.force && plan.current {
        result.status=.Up_To_Date
        return
    }
    // What runs these binaries goes on with them; the build writes in their place (engine_unlock.odin).
    if file,unlocked:=engine_unlock(paths.folder);!unlocked {
        return engine_fail(.Write_Failed,"binaries of the engine",fmt.tprintf("%s runs and could not be moved aside: close what runs it",file))
    }
    // No stamp says what the stage, the declarations and the programs there were written from.
    if desc.force || !plan.stamped {
        for folder in ([3]string{paths.stage,paths.decl,project.path(paths.folder,"programs",allocator=context.temp_allocator)}) {_=base.remove_all(folder)}
        _=os.remove(paths.declared)
    }
    if os.make_directory_all(paths.folder)!=nil && !os.is_dir(paths.folder) {
        result.status,result.failure=.Failed,.Write_Failed
        return
    }

    // The libraries whose sources moved are declared first, all of them: what
    // every library and program compiles against is then known before any compiles.
    stamp:=plan.previous
    stamp.libraries=slice.clone(plan.previous.libraries,context.temp_allocator)
    stamp.declared=slice.clone(plan.previous.declared,context.temp_allocator)
    stamp.declares=DECLARE_VERSION
    compile:=make([]bool,len(libraries),context.temp_allocator)
    staged:=make([]bool,len(libraries),context.temp_allocator)
    declarations_moved:=!os.is_file(paths.declared)
    stage :: proc(root:string,paths:Engine_Paths,library:Engine_Library) -> (changed:Declare_Changed,failed:Engine_Result,ok:bool) {
        errors,written,done:=engine_library_stage(root,paths,library)
        if len(errors)>0 {return {},engine_fail(.Generate,fmt.tprintf("declarations of %s",library.file),strings.join(errors,"\n")),false}
        if !done {return {},engine_fail(.Write_Failed,fmt.tprintf("stage of %s",library.file),""),false}
        return written,{},true
    }
    for library,which in libraries {
        present:=library_present(engine_library_files(paths,library,context.temp_allocator))
        was:=stamp.libraries[which]
        if !desc.force && present && was.sources==plan.libraries[which].sources {continue}
        stamp.libraries[which]={}
        changed,failed,ok:=stage(root,paths,library)
        if !ok {
            _=engine_stamp_write(paths.stamp,stamp,libraries)
            return failed
        }
        staged[which]=true
        declarations_moved||=changed.decl
        stamp.declared[which]={changed.declared,changed.moved if changed.moved!="" else stamp.declared[which].moved,changed.pinned}
        // The stage may be the same while the compiler, the flags or what the
        // library embeds moved: it is compiled again anyway.
        compile[which]=desc.force || !present || changed.stage || was.tools!=plan.libraries[which].tools
    }
    _=engine_stamp_write(paths.stamp,stamp,libraries)
    if declarations_moved && !declared_write(paths.decl,paths.declared) {return engine_fail(.Write_Failed,paths.declared,"")}
    declared:=declared_read(paths.declared,context.temp_allocator)

    // What names a declaration that moved, or one that reaches it, compiles
    // again, unless another checkout built it from the same: it is copied.
    // With no declaration moved, the libraries whose sources stand name what
    // they named: only the others are read.
    reach:=engine_reach(root,libraries,nil if declarations_moved else staged)
    against:=make([]u64,len(libraries),context.temp_allocator)
    for library,which in libraries {
        if !declarations_moved && !staged[which] {
            against[which]=plan.previous.libraries[which].against
            continue
        }
        against[which]=declared_key(declared,reach.names[which])
        if against[which]==plan.previous.libraries[which].against {continue}
        if !staged[which] {
            if _,failed,ok:=stage(root,paths,library);!ok {return failed}
        }
        compile[which]=true
    }
    // What links against a library it compiles links against an import library made now.
    made:=make([dynamic][2]string,context.temp_allocator)
    for library,which in libraries {
        if !compile[which] {continue}
        _,linked:=engine_library_files(paths,library,context.temp_allocator)
        append(&made,[2]string{engine_definition(paths,library),linked})
    }
    if failed:=import_libraries_make(compiler,made[:]);failed!="" {return engine_fail(.Write_Failed,failed,"it could not be made from its module definition")}
    entries:=make([]string,len(libraries),context.temp_allocator)
    for library,which in libraries {
        if !compile[which] {continue}
        entries[which]=engine_cache_entry(root,library,mode,plan.libraries[which],against[which])
        if !desc.force && engine_cache_take(entries[which],paths,library) {
            compile[which]=false
            done.restored+=1
        }
    }
    programs:=engine_program_sources(paths)
    program_names:=make(map[string]bool,context.temp_allocator)
    build_programs:=desc.force || stamp.programs!=plan.programs
    for program in programs {
        folder:=project.path(paths.folder,"programs",program.package_name,allocator=context.temp_allocator)
        if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return engine_fail(.Write_Failed,program.name,"")}
        written,error:=write_changed(project.path(folder,"main.odin",allocator=context.temp_allocator),program.source)
        if error!=nil {return engine_fail(.Write_Failed,program.name,"")}
        build_programs||=written || !os.is_file(program.output)
        errors:=make([dynamic]string,context.temp_allocator)
        _,files,_:=sources_read(folder,&errors,context.temp_allocator)
        declared_named(files,nil,&program_names)
    }
    programs_against:=declared_key(declared,program_names)
    build_programs||=stamp.programs_against!=programs_against

    // The stamp says what stands as each part ends: a part that fails costs
    // itself and not the ones that ended before it.
    for &library,which in stamp.libraries {
        library={} if compile[which] else {plan.libraries[which].sources,plan.libraries[which].tools,against[which]}
    }
    if build_programs {stamp.programs,stamp.programs_against=0,0}
    _=engine_stamp_write(paths.stamp,stamp,libraries)

    tasks:=make([dynamic]Engine_Task,context.temp_allocator)
    for library,which in libraries {
        output,_:=engine_library_files(paths,library,context.temp_allocator)
        task:=Engine_Task{name=fmt.tprintf("library %s",library.file),compile={streams=engine_streams(paths,library.file),staged=output,library=which},state=.Done}
        if compile[which] {
            task.state=.Pending
            task.command=engine_library_command(compiler,paths,library,slice.contains(reach.needs[which],true),mode,plan.flags[:])
        }
        append(&tasks,task)
    }
    // A program links against the libraries its imports reach, most of them: it waits for them all.
    every:=make([]bool,len(libraries),context.temp_allocator)
    slice.fill(every,true)
    for program in programs {
        task:=Engine_Task{name=program.name,compile={streams=engine_streams(paths,fmt.tprintf("program-%s",program.package_name)),staged=program.output,library=-1},state=.Done,needs=every}
        if build_programs {
            task.state=.Pending
            task.command=engine_program_command(compiler,paths,program,plan.flags[:])
        }
        append(&tasks,task)
    }
    for &task in tasks {
        if task.compile.library>=0 {task.needs=reach.needs[task.compile.library]}
        // What they link against was made ahead: they all compile at once.
        if IMPORT_LIBRARIES_AHEAD {task.needs=nil}
    }
    built:=make([]Library_Stamp,len(libraries),context.temp_allocator)
    for &library,which in built {library={plan.libraries[which].sources,plan.libraries[which].tools,against[which]}}
    failed,ok:=engine_tasks_run(root,paths,libraries,tasks[:],&stamp,built,entries,compiled)
    if len(compiled)>0 {cache_trim(workspace.cache_folder(root,ENGINE_CACHE,context.temp_allocator),ENGINE_CACHE_ENTRIES)}
    if !ok {return failed}
    done.programs=build_programs
    for copy in engine_copies(root,paths.folder,compiler) {
        if !build_programs && os.is_file(copy.to) {continue}
        if os.copy_file(copy.to,copy.from)!=nil {return engine_fail(.Copy_Failed,copy.to,"")}
    }
    stamp.programs,stamp.programs_against=plan.programs,programs_against
    _=engine_stamp_write(paths.stamp,stamp,libraries)
    result.status=.Built
    return
}

// A compiler the build of the engine runs: of a library, or of a program.
@(private)
Engine_Task :: struct {
    name:string,    // the step it is
    command:[]string,
    needs:[]bool,   // the libraries it links against: it starts once none of them is being built
    state:enum u8 {Done,Pending,Running,Failed},
    compile:Compile, // library: of the libraries, -1 for a program
}

// The files of the streams of a compiler of the engine, named after what it builds.
@(private)
engine_streams :: proc(paths:Engine_Paths,name:string) -> [2]string {
    return {project.path(paths.work,fmt.tprintf("%s.err",name),allocator=context.temp_allocator),project.path(paths.work,fmt.tprintf("%s.out",name),allocator=context.temp_allocator)}
}

// Runs the pending tasks, as many at once as compilers_at_once, each once the
// libraries it needs stand (none where what it links against was made ahead,
// IMPORT_LIBRARIES_AHEAD). A library that ends well is stamped as built, named in compiled
// and kept in its entry of the shared cache. The first task that fails ends
// the build once the ones running end.
@(private)
engine_tasks_run :: proc(root:string,paths:Engine_Paths,libraries:[]Engine_Library,tasks:[]Engine_Task,stamp:^Engine_Stamp,built:[]Library_Stamp,entries:[]string,compiled:^[dynamic]string) -> (failed:Engine_Result,ok:bool) {
    if os.make_directory_all(paths.work)!=nil && !os.is_dir(paths.work) {return engine_fail(.Write_Failed,paths.work,""),false}
    limit:=compilers_at_once()
    ok=true
    for {
        running:=0
        for task in tasks {
            if task.state==.Running {running+=1}
        }
        start: for &task in tasks {
            if !ok || running>=limit {break}
            if task.state!=.Pending {continue}
            for needed,which in task.needs {
                if needed && tasks[which].state!=.Done {continue start}
            }
            if !compile_start(&task.compile,root,task.command,child_environment(root,context.temp_allocator)) {
                failed=engine_fail(.Compiler_Failed,task.name,"")
                ok=false
                break
            }
            task.state=.Running
            running+=1
        }
        if running==0 {break}
        waited:=false
        for &task in tasks {
            if task.state!=.Running {continue}
            state,error:=os.process_wait(task.compile.process,0 if waited else (os.TIMEOUT_INFINITE if running==1 else WAIT_STEP))
            waited=true
            if !state.exited {
                if general,is_general:=error.(os.General_Error);is_general && general==.Timeout {continue}
                task.state=.Failed
                if ok {
                    failed=engine_fail(.Compiler_Failed,task.name,"")
                    ok=false
                }
                continue
            }
            diagnostics,text,failure,_:=compile_end(&task.compile,state.exit_code)
            if failure==.None {
                task.state=.Done
                if which:=task.compile.library;ok && which>=0 {
                    stamp.libraries[which]=built[which]
                    _=engine_stamp_write(paths.stamp,stamp^,libraries)
                    append(compiled,strings.clone(libraries[which].file,compiled.allocator))
                    engine_cache_store(entries[which],paths,libraries[which])
                }
                continue
            }
            task.state=.Failed
            if !ok {continue}
            failed=engine_fail(failure,task.name,text)
            ok=false
            // The diagnostics of a staged source point at the source.
            for &diagnostic in diagnostics {
                if strings.has_prefix(diagnostic.file,paths.stage) {diagnostic.file=project.path(root,diagnostic.file[len(paths.stage):])}
            }
            failed.diagnostics=diagnostics
        }
    }
    return
}

// The compiler's command for a library of the engine: its own packages from
// the stage, every other one as its declarations.
@(private)
engine_library_command :: proc(compiler:string,paths:Engine_Paths,library:Engine_Library,links_libraries:bool,mode:Engine_Mode,flags:[]string) -> []string {
    output,_:=engine_library_files(paths,library,context.temp_allocator)
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,compiler,"build",project.path(paths.stage,engine_library_entry(library,context.temp_allocator),allocator=context.temp_allocator),"-build-mode:dll")
    append(&command,fmt.tprintf("-collection:mirai=%s",paths.decl),fmt.tprintf("-collection:%s=%s",STAGE_COLLECTION,paths.stage),fmt.tprintf("-out:%s",output))
    append(&command,..flags)
    append(&command,"-json-errors")
    // A library finds the ones it links beside it, whatever loads it. The many
    // of dev keep each its own runtime, as those of plugins do (LIBRARY_OWN_RUNTIME).
    when ODIN_OS==.Windows {linker_flags_append(&command,"/NOIMPLIB",context.temp_allocator)}
    else {
        own:=LIBRARY_OWN_RUNTIME if mode==.Dev else ""
        file:=project.library_file(library.file,context.temp_allocator)
        when ODIN_OS==.Linux {linker_flags_append(&command,fmt.tprintf("-Wl,-soname,%s%s %s",file,links_libraries?" -Wl,-rpath,$ORIGIN":"",own),context.temp_allocator)}
        else {linker_flags_append(&command,fmt.tprintf("-Wl,-install_name,@rpath/%s%s %s",file,links_libraries?" -Wl,-rpath,@loader_path":"",own),context.temp_allocator)}
    }
    return command[:]
}

@(private)
engine_program_command :: proc(compiler:string,paths:Engine_Paths,program:Engine_Program,flags:[]string) -> []string {
    folder:=project.path(paths.folder,"programs",program.package_name,allocator=context.temp_allocator)
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,compiler,"build",folder,fmt.tprintf("-collection:mirai=%s",paths.decl),fmt.tprintf("-out:%s",program.output))
    append(&command,..flags)
    append(&command,"-json-errors")
    // The program of the editor has the name of its library, and so would their PDBs.
    when ODIN_OS==.Windows {append(&command,fmt.tprintf("-pdb-name:%s",strings.concatenate({program.output[:len(program.output)-len(project.EXECUTABLE_SUFFIX)],"-program.pdb"},context.temp_allocator)))}
    when ODIN_OS==.Linux {linker_flags_append(&command,"-Wl,-rpath,$ORIGIN",context.temp_allocator)}
    else when ODIN_OS==.Darwin {linker_flags_append(&command,"-Wl,-rpath,@executable_path",context.temp_allocator)}
    return command[:]
}


// Whether an installed engine has every binary its package carries.
@(private)
engine_installed_present :: proc(root:string) -> bool {
    paths:=engine_paths(root,ENGINE_MODE_INSTALLED,context.temp_allocator)
    present:=os.is_dir(paths.decl) && os.is_file(paths.stamp)
    for library in engine_libraries(ENGINE_MODE_INSTALLED,context.temp_allocator) {present&&=library_present(engine_library_files(paths,library,context.temp_allocator))}
    for program in engine_programs(paths) {present&&=os.is_file(program)}
    return present
}

// The folder of the libraries of the engine in the cache every checkout of the repository shares.
@(private)
ENGINE_CACHE :: "engine-libraries"

// How many libraries of the engine the shared cache keeps, the last used
// first: those of a few builds of each mode for every branch being worked on.
// Builds that differ in a few packages share the rest.
@(private)
ENGINE_CACHE_ENTRIES :: 1024

// A library of the engine in the shared cache, by what it is built from: its
// sources, the compiler, the flags and what it embeds (Library_Stamp), the
// declarations of other libraries it names and what declare writes. Built
// once, by whichever checkout gets there first; its stage and its
// declarations are written by every checkout, from the same sources.
@(private)
engine_cache_entry :: proc(root:string,library:Engine_Library,mode:Engine_Mode,built_from:Library_Stamp,against:u64) -> string {
    key:=base.hash_combine(base.hash_combine(base.hash_combine(DECLARE_VERSION,built_from.sources),built_from.tools),against)
    return project.path(workspace.cache_folder(root,ENGINE_CACHE,context.temp_allocator),fmt.tprintf("%s-%v-%x",library.file,mode,key),allocator=context.temp_allocator)
}

// The files a library leaves in the folder of the engine: itself and its
// debug information on Windows. What links against it there is made from its
// declarations (import_libraries_make).
@(private)
engine_cache_files :: proc(library:Engine_Library) -> [2]string {
    files:[2]string
    files[0]=project.library_file(library.file,context.temp_allocator)
    when ODIN_OS==.Windows {files[1]=strings.concatenate({library.file,".pdb"},context.temp_allocator)}
    return files
}

// Copies the library of an entry into the folder of the engine; false when
// the cache has none or it cannot be copied whole, and then it is compiled.
@(private)
engine_cache_take :: proc(entry:string,paths:Engine_Paths,library:Engine_Library) -> bool {
    if !cache_entry_complete(entry) {return false}
    for name,at in engine_cache_files(library) {
        if name=="" {continue}
        from:=project.path(entry,name,allocator=context.temp_allocator)
        // The debug information is there only when the library was built with it.
        if at==1 && !os.is_file(from) {continue}
        if os.copy_file(project.path(paths.folder,name,allocator=context.temp_allocator),from)!=nil {return false}
    }
    cache_entry_used(entry)
    return true
}

// Keeps a library just built in the cache. The caller trims the cache once
// (cache_trim) after the libraries of a build are stored.
@(private)
engine_cache_store :: proc(entry:string,paths:Engine_Paths,library:Engine_Library) {
    staging,fresh:=cache_entry_begin(entry)
    if !fresh {return}
    for name,at in engine_cache_files(library) {
        if name=="" {continue}
        from:=project.path(paths.folder,name,allocator=context.temp_allocator)
        if at==1 && !os.is_file(from) {continue}
        if os.copy_file(project.path(staging,name,allocator=context.temp_allocator),from)!=nil {_=base.remove_all(staging);return}
    }
    cache_entry_commit(entry,staging)
}

// The mark of a whole entry of a shared cache, written last; its date is when
// the entry was last used.
@(private)
CACHE_COMPLETE :: "complete"

// Whether an entry of a shared cache is whole.
@(private)
cache_entry_complete :: proc(entry:string) -> bool {
    return os.is_file(project.path(entry,CACHE_COMPLETE,allocator=context.temp_allocator))
}

// The entry was used: it stays before the ones that were not.
@(private)
cache_entry_used :: proc(entry:string) {
    _=os.write_entire_file(project.path(entry,CACHE_COMPLETE,allocator=context.temp_allocator),"")
}

// The folder where an entry of a shared cache is written aside, so a reader
// never sees half of one. fresh: the cache has no such entry and the folder was made.
@(private)
cache_entry_begin :: proc(entry:string) -> (staging:string,fresh:bool) {
    if cache_entry_complete(entry) {return "",false}
    staging=fmt.tprintf("%s.part-%d",entry,os.get_pid())
    _=base.remove_all(staging)
    if os.make_directory_all(staging)!=nil {return "",false}
    return staging,true
}

// Renames what staging holds into place with its mark and, with keep, drops
// the entries of the cache used the longest ago, keeping `keep`. Without it
// the caller trims the folder once (cache_trim): looking at every entry
// takes longer than storing one.
@(private)
cache_entry_commit :: proc(entry,staging:string,keep:=0) {
    if os.write_entire_file(project.path(staging,CACHE_COMPLETE,allocator=context.temp_allocator),"")!=nil || os.rename(staging,entry)!=nil {
        _=base.remove_all(staging)
        return
    }
    if keep>0 {cache_trim(entry[:strings.last_index_byte(entry,'/')],keep)}
}

// Drops the entries of a folder of the cache used the longest ago, keeping
// `keep`, and those a build that did not finish left half written.
@(private)
cache_trim :: proc(folder:string,keep:int) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    Used :: struct {path:string,at:time.Time}
    used:=make([dynamic]Used,context.temp_allocator)
    removed:=make([dynamic]string,context.temp_allocator)
    for found in entries {
        if found.type!=.Directory {continue}
        stale:=time.diff(found.modification_time,time.now())>STALE_AFTER
        // One being removed (remove_later), whose removal did not finish when it is old.
        if strings.contains(found.name,TRASH) {
            if stale {append(&removed,found.fullpath)}
            continue
        }
        at,stat_error:=os.modification_time_by_path(project.path(found.fullpath,CACHE_COMPLETE,allocator=context.temp_allocator))
        if stat_error!=nil {
            // An entry left half written by a build that did not finish.
            if strings.contains(found.name,".part-") && stale {append(&removed,found.fullpath)}
            continue
        }
        append(&used,Used{found.fullpath,at})
    }
    slice.sort_by(used[:],proc(a,b:Used) -> bool {return time.diff(b.at,a.at)>0})
    for old in used[min(len(used),keep):] {append(&removed,old.path)}
    remove_later(removed[:])
}

// What the stamp of the binaries in folder says they were built from, to tell
// later whether a program that started from them runs the last ones built,
// and what a build changed since (engine_swap). "" without one.
engine_stamp_of :: proc(folder:string,allocator:=context.allocator) -> string {
    data,_:=os.read_entire_file(project.path(folder,ENGINE_STAMP,allocator=context.temp_allocator),allocator)
    return string(data)
}

// What a program that started from the binaries of one stamp does with those
// of another, which a build left since. The libraries of a dev build call
// each other through tables (Declare_Desc.slots), so one built again that
// declares what it did is taken in place (host.engine_library_swap): only the
// bodies of its procedures are other. restart says in a line what keeps the
// program from going on with the ones it runs: a declaration that changed,
// and with it the layouts, the constants and the inline bodies whatever names
// it compiled in; a library that keeps what a newer one would not have; the
// programs themselves.
engine_swap :: proc(mode:Engine_Mode,running,now:string,allocator:=context.allocator) -> (swapped:[]Engine_Library,restart:string) {
    if mode!=.Dev {return nil,"a release build of the engine calls its libraries directly"}
    libraries:=engine_libraries(mode,allocator)
    was,was_read:=engine_stamp_parse(running,libraries)
    is,is_read:=engine_stamp_parse(now,libraries)
    if !was_read || !is_read || was.declares!=is.declares {return nil,"the build of the engine lays its binaries out another way"}
    list:=make([dynamic]Engine_Library,allocator)
    for library,which in libraries {
        if is.libraries[which].sources==0 {return nil,fmt.aprintf("%s did not build",library.file,allocator=allocator)}
        if was.libraries[which]==is.libraries[which] {continue}
        declared:=is.declared[which]
        switch {
        case was.declared[which].hash!=declared.hash:
            return nil,fmt.aprintf("the declaration %s changed",declared.moved!=""?declared.moved:library.file,allocator=allocator)
        case declared.pinned!="":
            return nil,fmt.aprintf("%s keeps what a newer one would not have (%s)",library.file,declared.pinned,allocator=allocator)
        }
        append(&list,library)
    }
    if was.programs!=is.programs || was.programs_against!=is.programs_against {return nil,"the compiler or the flags of the build changed"}
    return list[:],""
}

// The stamp of the last build of a mode, of these libraries; false when
// there is none, it does not read or it is of other libraries.
@(private)
engine_stamp_read :: proc(file:string,libraries:[]Engine_Library) -> (stamp:Engine_Stamp,ok:bool) {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return}
    return engine_stamp_parse(string(data),libraries)
}

@(private)
engine_stamp_parse :: proc(text:string,libraries:[]Engine_Library) -> (stamp:Engine_Stamp,ok:bool) {
    lines:=strings.split_lines(strings.trim_space(text),context.temp_allocator)
    if len(lines)!=1+len(libraries) {return}
    fields:=strings.fields(lines[0],context.temp_allocator)
    if len(fields)!=3 {return}
    stamp.declares=strconv.parse_int(fields[0],10) or_return
    stamp.programs=strconv.parse_u64_of_base(fields[1],16) or_return
    stamp.programs_against=strconv.parse_u64_of_base(fields[2],16) or_return
    stamp.libraries=make([]Library_Stamp,len(libraries),context.temp_allocator)
    stamp.declared=make([]Library_Declared,len(libraries),context.temp_allocator)
    // One line per library, in their order, each with its name.
    for line,index in lines[1:] {
        of:=strings.fields(line,context.temp_allocator)
        if len(of)!=7 || of[3]!=libraries[index].name {return}
        stamp.libraries[index].sources=strconv.parse_u64_of_base(of[0],16) or_return
        stamp.libraries[index].tools=strconv.parse_u64_of_base(of[1],16) or_return
        stamp.libraries[index].against=strconv.parse_u64_of_base(of[2],16) or_return
        stamp.declared[index].hash=strconv.parse_u64_of_base(of[4],16) or_return
        stamp.declared[index].moved,stamp.declared[index].pinned=strings.trim_prefix(of[5],"-"),strings.trim_prefix(of[6],"-")
    }
    return stamp,true
}

@(private)
engine_stamp_write :: proc(file:string,stamp:Engine_Stamp,libraries:[]Engine_Library) -> os.Error {
    b:=strings.builder_make(context.temp_allocator)
    for library,index in stamp.libraries {
        declared:=stamp.declared[index]
        fmt.sbprintf(&b,"\n%x %x %x %s %x %s %s",library.sources,library.tools,library.against,libraries[index].name,declared.hash,declared.moved!=""?declared.moved:"-",declared.pinned!=""?declared.pinned:"-")
    }
    return os.write_entire_file(file,fmt.tprintf("%d %x %x%s",stamp.declares,stamp.programs,stamp.programs_against,strings.to_string(b)))
}

@(private)
ENGINE_COLLECTION :: "mirai:"

// -o and the attributes, the same for every binary of the engine and every
// library of a project: the layouts of what they share follow from them.
@(private)
engine_flags :: proc(root:string,dev:bool) -> [dynamic]string {
    flags:=make([dynamic]string,context.temp_allocator)
    // The debug information lets a crash report of what ships name the procedure and the line; it does not
    // change the code. In dev it is written again with every library that compiles: MIRAI_ODIN_FLAGS=-debug asks for it.
    append(&flags,dev?"-o:minimal":"-o:speed",fmt.tprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES))
    if !dev {append(&flags,"-debug")}
    platform_flags(root,&flags,false,context.temp_allocator)
    environment_flags(&flags,context.temp_allocator)
    return flags
}

// The sources of some packages under root, sorted, with the files they load
// (#load and its kin: what is built from them reads those too), and the files given besides.
@(private)
engine_sources :: proc(root:string,packages:[]string,files:..string) -> []string {
    list:=make([dynamic]string,context.temp_allocator)
    for path in packages {
        folder:=project.path(root,path,allocator=context.temp_allocator)
        entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
        for entry in entries {
            if entry.type==.Directory || !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
            append(&list,slashes(entry.fullpath,context.temp_allocator))
            text,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
            for loaded in loaded_files(string(text),folder) {
                if !slice.contains(list[:],loaded) {append(&list,loaded)}
            }
        }
    }
    for file in files {append(&list,slashes(file,context.temp_allocator))}
    slice.sort(list[:])
    return list[:]
}

// The package a library is built from: it imports the others, each with its
// collection (entry_imports), and their exports go into the library.
@(private)
entry_write :: proc(stage,name:string,imports:[]string) -> (changed,written:bool) {
    folder:=project.path(stage,name,allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintfln(&b,"package %s\n",name)
    for path in imports {fmt.sbprintfln(&b,"import _ \"%s\"",path)}
    wrote,error:=write_changed(project.path(folder,"library.odin",allocator=context.temp_allocator),strings.to_string(b))
    return wrote,error==nil
}

// The packages of a collection as a library imports them.
@(private)
entry_imports :: proc(collection:string,packages:[]string) -> [dynamic]string {
    imports:=make([dynamic]string,0,len(packages),context.temp_allocator)
    for path in packages {append(&imports,fmt.tprintf("%s:%s",collection,path))}
    return imports
}

@(private="file")
engine_fail :: proc(failure:Failure,step,text:string) -> Engine_Result {
    return {status=.Failed,failure=failure,step=strings.clone(step),text=strings.clone(text)}
}

// What the programs load besides the libraries of the engine: SDL3.
@(private="file")
engine_copies :: proc(root,folder,compiler:string) -> []Copy {
    copies:=make([dynamic]Copy,context.temp_allocator)
    when ODIN_OS==.Windows {
        odin_root,configured:=os.lookup_env("ODIN_ROOT",context.temp_allocator)
        if !configured || odin_root=="" {
            cut:=strings.last_index_any(compiler,"/\\")
            odin_root=cut>=0?compiler[:cut]:"."
        }
        if sdl:=project.path(odin_root,"vendor/sdl3/SDL3.dll",allocator=context.temp_allocator);os.is_file(sdl) {
            append(&copies,Copy{sdl,project.path(folder,"SDL3.dll",allocator=context.temp_allocator),false})
        }
    } else when ODIN_OS==.Linux {
        if sdl:=project.path(linux_deps(root),"sdl3/lib/libSDL3.so.0",allocator=context.temp_allocator);os.is_file(sdl) {
            append(&copies,Copy{sdl,project.path(folder,"libSDL3.so.0",allocator=context.temp_allocator),false})
        }
    } else when ODIN_OS==.Darwin {
        if sdl,relocatable:=macos_sdl(root);relocatable {
            append(&copies,Copy{project.path(sdl,MACOS_SDL,allocator=context.temp_allocator),project.path(folder,MACOS_SDL,allocator=context.temp_allocator),false})
        }
    }
    return copies[:]
}
