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
import "mirai:std/subprocess"

// The binaries of the engine, built once per version of their sources and
// of the compiler, under <engine>/.mirai/engine/<mode>: those of dev and of
// release stand side by side, so going from one mode to the other builds
// nothing.
//
//   mirai-<library>  the libraries (ENGINE_LIBRARIES), each linked against the ones it needs
//   decl/            the declarations projects compile against instead of those sources
//   mirai-editor, mirai-player  the programs that load the library of a project
//   mirai-import     the program of mirai import, on the libraries of the editor
//   mirai-author     the program of mirai ui and mirai scene, on the libraries of the editor
//   stage-<library>/ the copy each library is built from (declare.odin), with the
//                    declarations of the libraries it needs
//
// Each part is built again only for what it reads: a library for its sources
// and for the declarations its packages import from the libraries it needs,
// so a change in the body of a procedure builds its library and no other, and
// one of a declaration builds, besides, the libraries and the programs that
// reach its package.
//
// A project then compiles its generated world, its game and its plugins
// alone, into a library the editor or the player loads.

// The libraries of the engine, each after the ones it needs: the layers of
// the packages, cut where no import goes up.
Engine_Library :: enum u8 {
    Base,   // what needs no renderer: the standard library, the system, the device and the data core
    Engine, // the rest of what a game or a plugin can import
    Cook,   // engine-time: what imports, cooks and builds
    Editor, // engine-time: the editor
}

Engine_Library_Info :: struct {
    name:string,                   // mirai-<name> its file, stage-<name> its stage
    needs:bit_set[Engine_Library], // the libraries its packages may import, with the ones those need
    engine_time:bool,              // no game contains its packages
}

ENGINE_LIBRARIES :: [Engine_Library]Engine_Library_Info{
    .Base={name="base"},
    .Engine={name="engine",needs={.Base}},
    .Cook={name="cook",needs={.Base,.Engine},engine_time=true},
    .Editor={name="editor",needs={.Base,.Engine,.Cook},engine_time=true},
}

Engine_Package :: struct {
    library:Engine_Library,
    path:string, // relative to the root and to the collection: core, engine/scene
}

// Every package of the engine with a declaration, and the library that holds
// it. A package goes in the lowest library that has what it imports; a C
// library, with the package that binds it.
ENGINE_PACKAGES :: [?]Engine_Package{
    {.Base,"std/base"},{.Base,"std/subprocess"},{.Base,"std/math"},{.Base,"std/geom"},{.Base,"std/serial"},{.Base,"std/spatial"},
    {.Base,"std/jobs"},{.Base,"std/anim"},{.Base,"std/ai"},{.Base,"std/input"},{.Base,"std/ui_format"},
    {.Base,"std/compressor"},{.Base,"std/compressor/bc7split"},{.Base,"std/compressor/lz/entropy"},{.Base,"std/compressor/lz/match"},
    {.Base,"std/compressor/lz/parse"},{.Base,"std/compressor/lz"},
    {.Base,"audio"},{.Base,"platform"},{.Base,"rhi"},{.Base,"project"},{.Base,"core"},

    {.Engine,"third_party/freetype"},{.Engine,"asset"},{.Engine,"net"},{.Engine,"render/abi"},{.Engine,"render"},{.Engine,"ui"},{.Engine,"host"},
    {.Engine,"engine/volume"},{.Engine,"engine/input"},{.Engine,"engine/scene"},{.Engine,"engine/render"},{.Engine,"engine/audio"},
    {.Engine,"engine/gui"},{.Engine,"engine/camera"},{.Engine,"engine/save"},

    {.Cook,"cook/workspace"},{.Cook,"cook/cache"},{.Cook,"cook/compressor/bc7split"},{.Cook,"cook/compressor/texture/common"},
    {.Cook,"cook/compressor/texture/bc67"},{.Cook,"cook/compressor/texture/bc1"},{.Cook,"cook/compressor/texture/bc4"},
    {.Cook,"cook/compressor/texture/bc6"},{.Cook,"cook/compressor/texture/bc7"},{.Cook,"cook/compressor/texture"},
    {.Cook,"cook/textures"},{.Cook,"cook/image"},{.Cook,"cook/movie"},{.Cook,"cook/rig"},{.Cook,"cook/import"},
    {.Cook,"cook/import/obj"},{.Cook,"cook/import/gltf"},{.Cook,"cook/import/usd"},{.Cook,"third_party/ufbx"},{.Cook,"cook/import/fbx"},
    {.Cook,"cook/shaders"},{.Cook,"cook/prefab"},{.Cook,"cook/import/sources"},{.Cook,"cook/author"},{.Cook,"cook/install"},
    {.Cook,"cook/build"},

    {.Editor,"third_party/sqlite"},{.Editor,"editor/api"},{.Editor,"editor/acp"},{.Editor,"editor/diff"},{.Editor,"editor/ai_store"},{.Editor,"editor/git"},{.Editor,"editor/history"},{.Editor,"editor/records"},
    {.Editor,"editor"},
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

// The packages of a library, in the order of ENGINE_PACKAGES.
engine_library_packages :: proc(library:Engine_Library,allocator:=context.allocator) -> []string {
    packages:=ENGINE_PACKAGES
    list:=make([dynamic]string,allocator)
    for entry in packages {
        if entry.library==library {append(&list,entry.path)}
    }
    return list[:]
}

// The packages a game binary can contain: those of the libraries that are not engine-time.
engine_runtime_packages :: proc(allocator:=context.allocator) -> []string {
    packages,libraries:=ENGINE_PACKAGES,ENGINE_LIBRARIES
    list:=make([dynamic]string,allocator)
    for entry in packages {
        if !libraries[entry.library].engine_time {append(&list,entry.path)}
    }
    return list[:]
}

// The file of a library without its extension.
@(private)
engine_library_file :: proc(library:Engine_Library,allocator:=context.allocator) -> string {
    libraries:=ENGINE_LIBRARIES
    return strings.concatenate({"mirai-",libraries[library].name},allocator)
}

// The package a library is built from (entry_write).
@(private)
engine_library_entry :: proc(library:Engine_Library,allocator:=context.allocator) -> string {
    libraries:=ENGINE_LIBRARIES
    return strings.concatenate({"__mirai_",libraries[library].name},allocator)
}

// Changes when what declare writes changes, so that binaries built by an
// earlier version are built again.
@(private)
DECLARE_VERSION :: 9

Engine_Paths :: struct {
    folder:string,
    decl:string,                      // the collection "mirai" of a project
    stages:[Engine_Library]string,
    libraries:[Engine_Library]string,
    imports:[Engine_Library]string,   // what links against each library
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

// What a library of the engine leaves. On Windows the import library is a file
// of its own: without it the projects and the programs do not link, and the
// only build that makes it is the one that compiles the library. Elsewhere it
// is the library itself, and this is the same check twice.
@(private)
library_present :: proc(library,linked_against:string) -> bool {
    return os.is_file(library) && os.is_file(linked_against)
}

Engine_Mode :: enum u8 {
    Keep,    // the one built last; Release when there is none
    Release, // -o:speed: to play, measure and ship
    Dev,     // -o:minimal: for whoever changes the engine
}

@(private)
ENGINE_MODE_FOLDERS :: [Engine_Mode]string{.Keep="",.Release="release",.Dev="dev"}

// The mode of the binaries this code is compiled into. The editor builds the
// libraries of a project against the declarations of its own mode.
ENGINE_MODE_HERE :: Engine_Mode.Dev when ODIN_OPTIMIZATION_MODE==.Minimal || ODIN_OPTIMIZATION_MODE==.None else Engine_Mode.Release

@(private)
ENGINE_STAMP :: "engine.stamp"

@(private)
ENGINE_STAGE_PREFIX :: "stage-"

// The mode of the binaries an installed engine carries, the only one it
// has: --dev builds the libraries of a project at -o:minimal against them.
ENGINE_MODE_INSTALLED :: Engine_Mode.Release

// The mode Keep stands for: the one whose binaries were built last, Release
// when there are none. The others stand for themselves, but in an installed
// engine, which has the binaries of one.
engine_mode_resolve :: proc(engine_root:string,mode:Engine_Mode) -> Engine_Mode {
    if project.engine_installed(engine_root) {return ENGINE_MODE_INSTALLED}
    if mode!=.Keep {return mode}
    folders:=ENGINE_MODE_FOLDERS
    last:=Engine_Mode.Release
    newest:time.Time
    for candidate in ([2]Engine_Mode{.Release,.Dev}) {
        at,error:=os.modification_time_by_path(project.path(engine_root,".mirai","engine",folders[candidate],ENGINE_STAMP,allocator=context.temp_allocator))
        if error==nil && time.diff(newest,at)>0 {newest,last=at,candidate}
    }
    return last
}

// The folder of the binaries of a mode; Keep is the one built last.
engine_paths :: proc(engine_root:string,mode:Engine_Mode,allocator:=context.allocator) -> (paths:Engine_Paths) {
    context.allocator=allocator
    folders:=ENGINE_MODE_FOLDERS
    paths.folder=project.path(engine_root,".mirai","engine",folders[engine_mode_resolve(engine_root,mode)])
    paths.decl=project.path(paths.folder,"decl")
    libraries:=ENGINE_LIBRARIES
    for info,library in libraries {
        file:=engine_library_file(library,context.temp_allocator)
        // A stage holds a copy of the declarations it compiles against: at the
        // depth of decl, the relative paths of their foreign imports stand.
        paths.stages[library]=project.path(paths.folder,strings.concatenate({ENGINE_STAGE_PREFIX,info.name},context.temp_allocator))
        paths.libraries[library]=project.path(paths.folder,project.library_file(file,context.temp_allocator))
        paths.imports[library]=project.path(paths.folder,library_import_file(file,context.temp_allocator))
    }
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
    restored:bool,            // Built from the cache the checkouts of the repository share
    shaders:shaders.Result,   // the generation of shaders/build and of the tables that embed it
    mode:Engine_Mode,         // of the binaries: Release or Dev
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
}

// What the last build of a mode left: of each library, of the programs (the
// compiler and the flags they were built with) and of declare. A declaration
// that changes zeroes what compiles against it before anything else is
// built, so a build that stops halfway leaves those parts to the next one.
@(private)
Engine_Stamp :: struct {
    libraries:[Engine_Library]Library_Stamp,
    programs:u64,
    declares:int,
    // Of each package (engine_package), what whoever imports it compiles
    // against: its declarations and those of every package of the engine they
    // import, directly or not (decl_hashes). Zero: unknown.
    declared:[ENGINE_PACKAGE_COUNT]u64,
}

// What a build of a mode finds: the fingerprints of now, and whether every
// part stands as the last build left it.
@(private)
Engine_Plan :: struct {
    previous:Engine_Stamp,
    stamped:bool, // previous is of a build of this version of declare
    flags:[dynamic]string,
    libraries:[Engine_Library]Library_Stamp,
    programs:u64,
    key:u64, // of every library and of declare: the entry of the shared cache
    current:bool,
}

@(private)
engine_programs :: proc(paths:Engine_Paths) -> [4]string {
    return {paths.editor_program,paths.player_program,paths.import_program,paths.author_program}
}

@(private)
engine_plan :: proc(root,compiler:string,mode:Engine_Mode,paths:Engine_Paths) -> (plan:Engine_Plan) {
    plan.flags=engine_flags(root,mode==.Dev)
    // render embeds the code of the shaders of the engine, whose manifest has the hash of each.
    // A release build embeds it as encoded to ship; a dev build, however it was encoded.
    names:=shaders.EMBEDDED_NAMES
    embedded:=[2]string{project.path(root,"shaders/build/manifest.json",allocator=context.temp_allocator),project.path(root,"shaders/build",names[shaders.HOST_BACKEND],allocator=context.temp_allocator)}
    packages:=ENGINE_PACKAGES
    render,_:=engine_package_index("render")
    plan.programs,_=fingerprint(root,compiler,plan.flags[:],nil)
    plan.key=DECLARE_VERSION
    for &library,which in plan.libraries {
        loads:=(embedded[:] if mode==.Release else embedded[:1]) if packages[render].library==which else nil
        library.sources,_=fingerprint(root,compiler,plan.flags[:],engine_sources(root,engine_library_packages(which,context.temp_allocator),..loads))
        library.tools,_=fingerprint(root,compiler,plan.flags[:],loads)
        plan.key=base.hash_combine(plan.key,library.sources)
    }
    previous,stamped:=engine_stamp_read(paths.stamp)
    // Without the declarations nothing compiles against what stands.
    if !stamped || previous.declares!=DECLARE_VERSION || !os.is_dir(paths.decl) {return}
    plan.previous,plan.stamped=previous,true
    plan.current=previous.programs==plan.programs
    for library,which in plan.libraries {
        plan.current&&=previous.libraries[which].sources==library.sources && library_present(paths.libraries[which],paths.imports[which])
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
    resolved:=engine_mode_resolve(root,mode)
    if root=="" || !shaders.current({root=root,odin=true,ship=resolved==.Release}) {return false}
    compiler,found:=compiler_find(root,context.temp_allocator)
    if !found {return false}
    return engine_plan(root,compiler,resolved,engine_paths(root,mode,context.temp_allocator)).current
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
    if _,stamped=engine_stamp_read(paths.stamp);!stamped {return}
    compiler,found:=compiler_find(root,context.temp_allocator)
    if !found {return}
    current=engine_plan(root,compiler,engine_mode_resolve(root,mode),paths).current
    return
}

// The programs, each a main over the declarations of the libraries.
@(private)
Engine_Program :: struct {name,package_name,source,output:string}

@(private)
engine_program_sources :: proc(paths:Engine_Paths) -> [4]Engine_Program {
    return {
        {"editor program","editor","package main\n\nimport \"core:os\"\nimport \"mirai:editor\"\n\nmain :: proc() {os.exit(editor.launch(os.args[1:]))}\n",paths.editor_program},
        {"player program","host","package main\n\nimport \"core:os\"\nimport \"mirai:host\"\n\nmain :: proc() {os.exit(host.launch(os.args[1:]))}\n",paths.player_program},
        {"import program","import",`package main

import "core:os"
import "mirai:cook/import/sources"

main :: proc() {os.exit(sources.command(os.args[1:],os.to_writer(os.stdout),os.to_writer(os.stderr)))}
`,paths.import_program},
        {"author program","author",`package main

import "core:os"
import "mirai:cook/author"
import "mirai:editor"

main :: proc() {os.exit(author.command(os.args[1:],os.to_writer(os.stdout),os.to_writer(os.stderr),editor.plugin_recipes))}
`,paths.author_program},
    }
}

// What the stage of a library holds before it compiles: the declarations of
// the libraries it needs, its sources staged and declared, and its entry.
// stage: whether what the library compiles from its own packages was written.
@(private)
engine_library_stage :: proc(root:string,paths:Engine_Paths,library:Engine_Library) -> (errors:[]string,stage:bool,ok:bool) {
    libraries:=ENGINE_LIBRARIES
    for needed in libraries[library].needs {
        if !decl_mirror(paths.stages[library],paths.decl,engine_library_packages(needed,context.temp_allocator)) {return}
    }
    packages:=engine_library_packages(library,context.temp_allocator)
    changed:Declare_Changed
    errors,changed=declare({root=root,packages=packages,binary="mirai",library=paths.imports[library],stage=paths.stages[library],decl=paths.decl})
    if len(errors)>0 {return errors,changed.stage,true}
    entry,written:=entry_write(paths.stages[library],engine_library_entry(library,context.temp_allocator),entry_imports("mirai",packages)[:])
    return nil,changed.stage || entry,written
}

// The packages of the libraries a library needs that its sources import:
// what it compiles against.
@(private)
engine_library_reach :: proc(root:string,paths:Engine_Paths,library:Engine_Library) -> (reached:[ENGINE_PACKAGE_COUNT]bool) {
    packages,libraries:=ENGINE_PACKAGES,ENGINE_LIBRARIES
    engine_imports(paths.decl,engine_sources(root,engine_library_packages(library,context.temp_allocator)),&reached)
    for &package_reached,index in reached {package_reached&&=packages[index].library in libraries[library].needs}
    return
}

// The hash of what the packages reached declare. Zero when one is unknown.
@(private)
declared_hash :: proc(declared:^[ENGINE_PACKAGE_COUNT]u64,reached:^[ENGINE_PACKAGE_COUNT]bool) -> (hash:u64) {
    hash=1
    for package_reached,index in reached {
        if !package_reached {continue}
        if declared[index]==0 {return 0}
        hash=base.hash_combine(base.hash_combine(hash,base.name_hash(engine_package(index))),declared[index])
    }
    return
}

// Whether what a part compiles against is the same under both sets of hashes.
@(private)
declared_same :: proc(before,after:^[ENGINE_PACKAGE_COUNT]u64,reached:^[ENGINE_PACKAGE_COUNT]bool) -> bool {
    hash:=declared_hash(after,reached)
    return hash!=0 && hash==declared_hash(before,reached)
}

// Generates the shaders of the engine and builds the parts of its binaries
// that were not built from the same sources, compiler and flags. Blocks: it
// runs once per version.
engine_build :: proc(desc:Engine_Desc,allocator:=context.allocator) -> (result:Engine_Result) {
    context.allocator=allocator
    tick:=time.tick_now()
    defer result.seconds=time.duration_seconds(time.tick_since(tick))
    root:=slashes(desc.engine_root,context.temp_allocator)
    if root=="" {
        result.status,result.failure=.Failed,.Engine_Missing
        return
    }
    // An installed engine carries its binaries and the shaders they embed.
    if project.engine_installed(root) {
        result.mode=ENGINE_MODE_INSTALLED
        if engine_installed_present(root) {
            result.status=.Up_To_Date
            return
        }
        result=engine_fail(.Engine_Incomplete,"binaries of the installed engine",fmt.tprintf("%s lacks some of them: unpack the package of the engine again",engine_paths(root,ENGINE_MODE_INSTALLED,context.temp_allocator).folder))
        result.mode=ENGINE_MODE_INSTALLED
        return
    }
    mode:=engine_mode_resolve(root,desc.mode)
    result.mode=mode
    // Generated, not versioned: render embeds them and its table names them.
    result.shaders=shaders.generate({root=root,odin=true,ship=mode==.Release})
    if result.shaders.error!="" {
        result.status,result.failure,result.step,result.text=.Failed,.Shaders,"shaders of the engine",result.shaders.error
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
    plan:=engine_plan(root,compiler,mode,paths)
    if !desc.force && plan.current {
        result.status=.Up_To_Date
        return
    }
    // What runs these binaries goes on with them; the build writes in their place (engine_unlock.odin).
    if file,unlocked:=engine_unlock(paths.folder);!unlocked {
        return engine_fail(.Write_Failed,"binaries of the engine",fmt.tprintf("%s runs and could not be moved aside: close what runs it",file))
    }
    // No stamp says what the stages, the declarations and the programs there were written from.
    if desc.force || !plan.stamped {
        engine_stages_remove(paths.folder)
        for folder in ([2]string{paths.decl,project.path(paths.folder,"programs",allocator=context.temp_allocator)}) {_=os.remove_all(folder)}
    }
    cache:=engine_cache_entry(root,plan.key,mode)
    if !desc.force && cache_entry_complete(cache) {
        if engine_cache_restore(cache,paths) {
            result.status,result.restored=.Built,true
            return
        }
        // A copy that stopped halfway left nothing that stands.
        plan.previous={}
    }
    if os.make_directory_all(paths.folder)!=nil && !os.is_dir(paths.folder) {
        result.status,result.failure=.Failed,.Write_Failed
        return
    }
    programs:=engine_program_sources(paths)
    reaches:[Engine_Library][ENGINE_PACKAGE_COUNT]bool
    for &reached,library in reaches {reached=engine_library_reach(root,paths,library)}
    programs_reach:[ENGINE_PACKAGE_COUNT]bool
    for program in programs {engine_imports_text(paths.decl,program.source,&programs_reach)}

    // The stamp says what stands as each part ends: a part that fails costs
    // itself and not the ones before it.
    stamp:=plan.previous
    stamp.declares=DECLARE_VERSION
    libraries:=ENGINE_LIBRARIES
    for info,library in libraries {
        file:=engine_library_file(library,context.temp_allocator)
        present:=library_present(paths.libraries[library],paths.imports[library])
        was:=stamp.libraries[library]
        if !desc.force && present && was.sources==plan.libraries[library].sources {continue}
        stamp.libraries[library]={}
        _=engine_stamp_write(paths.stamp,stamp)
        errors,stage_changed,staged:=engine_library_stage(root,paths,library)
        if len(errors)>0 {return engine_fail(.Generate,fmt.tprintf("declarations of %s",file),strings.join(errors,"\n"))}
        if !staged {return engine_fail(.Write_Failed,fmt.tprintf("stage of %s",file),"")}
        // What reaches a package that declares something else compiles again:
        // the libraries after this one and the programs.
        if declared:=decl_hashes(paths.decl);declared!=stamp.declared {
            for &reached,other in reaches {
                if other>library && !declared_same(&stamp.declared,&declared,&reached) {stamp.libraries[other]={}}
            }
            if !declared_same(&stamp.declared,&declared,&programs_reach) {stamp.programs=0}
            stamp.declared=declared
            _=engine_stamp_write(paths.stamp,stamp)
        }
        // The stage may be the same while the compiler, the flags or what the
        // library embeds moved: it is compiled again anyway.
        if engine_library_compile(desc.force,present,stage_changed,was.tools!=plan.libraries[library].tools) {
            if !library_compile(&result,compiler,root,paths.stages[library],engine_library_entry(library,context.temp_allocator),paths.libraries[library],file,info.needs!={},plan.flags[:],fmt.tprintf("library %s",file)) {return}
        }
        stamp.libraries[library]=plan.libraries[library]
        _=engine_stamp_write(paths.stamp,stamp)
    }

    // The programs are built against the declarations of the libraries.
    build_programs:=stamp.programs!=plan.programs
    for program in programs {
        folder:=project.path(paths.folder,"programs",program.package_name,allocator=context.temp_allocator)
        if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return engine_fail(.Write_Failed,program.name,"")}
        written,error:=write_changed(project.path(folder,"main.odin",allocator=context.temp_allocator),program.source)
        if error!=nil {return engine_fail(.Write_Failed,program.name,"")}
        build_programs||=written || !os.is_file(program.output)
    }
    if build_programs {
        stamp.programs=0
        _=engine_stamp_write(paths.stamp,stamp)
        for program in programs {
            folder:=project.path(paths.folder,"programs",program.package_name,allocator=context.temp_allocator)
            command:=make([dynamic]string,context.temp_allocator)
            append(&command,compiler,"build",folder,fmt.tprintf("-collection:mirai=%s",paths.decl),fmt.tprintf("-out:%s",program.output))
            append(&command,..plan.flags[:])
            // The program of the editor has the name of its library, and so would their PDBs.
            when ODIN_OS==.Windows {append(&command,fmt.tprintf("-pdb-name:%s",strings.concatenate({program.output[:len(program.output)-len(project.EXECUTABLE_SUFFIX)],"-program.pdb"},context.temp_allocator)))}
            when ODIN_OS==.Linux {linker_flags_append(&command,"-Wl,-rpath,$ORIGIN",context.temp_allocator)}
            else when ODIN_OS==.Darwin {linker_flags_append(&command,"-Wl,-rpath,@executable_path",context.temp_allocator)}
            if !compile(&result,root,command[:],program.name) {return}
        }
    }
    for copy in engine_copies(root,paths.folder,compiler) {
        if !build_programs && os.is_file(copy.to) {continue}
        if os.copy_file(copy.to,copy.from)!=nil {return engine_fail(.Copy_Failed,copy.to,"")}
    }
    stamp.programs=plan.programs
    _=engine_stamp_write(paths.stamp,stamp)
    engine_cache_store(paths,cache)
    result.status=.Built
    result.seconds=time.duration_seconds(time.tick_since(tick))
    return
}

// Whether an installed engine has every binary its package carries.
@(private)
engine_installed_present :: proc(root:string) -> bool {
    paths:=engine_paths(root,ENGINE_MODE_INSTALLED,context.temp_allocator)
    present:=os.is_dir(paths.decl) && os.is_file(paths.stamp)
    for library,which in paths.libraries {present&&=library_present(library,paths.imports[which])}
    for program in engine_programs(paths) {present&&=os.is_file(program)}
    return present
}

// Removes the stages of a folder of binaries: what they hold is of no library that stands there.
@(private)
engine_stages_remove :: proc(folder:string) {
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    for entry in entries {
        if entry.type==.Directory && strings.has_prefix(entry.name,ENGINE_STAGE_PREFIX) {_=os.remove_all(entry.fullpath)}
    }
}

// Leaves in stage the declarations of the packages as decl has them: what
// is the same by size and date is not copied again, and what decl no longer
// has goes. What the stage builds compiles against them.
@(private)
decl_mirror :: proc(stage,decl:string,packages:[]string) -> bool {
    for path in packages {
        from:=project.path(decl,path,allocator=context.temp_allocator)
        to:=project.path(stage,path,allocator=context.temp_allocator)
        if os.make_directory_all(to)!=nil && !os.is_dir(to) {return false}
        sources,error:=os.read_all_directory_by_path(from,context.temp_allocator)
        if error!=nil {return false}
        copies,_:=os.read_all_directory_by_path(to,context.temp_allocator)
        present:=make(map[string]os.File_Info,context.temp_allocator)
        for entry in copies {
            if entry.type!=.Directory && strings.has_suffix(entry.name,".odin") {present[entry.name]=entry}
        }
        for entry in sources {
            if entry.type==.Directory || !strings.has_suffix(entry.name,".odin") {continue}
            copy,found:=present[entry.name]
            delete_key(&present,entry.name)
            if found && copy.size==entry.size && time.diff(entry.modification_time,copy.modification_time)>=0 {continue}
            if os.copy_file(project.path(to,entry.name,allocator=context.temp_allocator),entry.fullpath)!=nil {return false}
        }
        for _,stale in present {_=os.remove(stale.fullpath)}
    }
    return true
}

// How many builds of the engine the shared cache keeps, the last used first:
// some of each mode for every branch that is being worked on.
@(private)
ENGINE_CACHE_ENTRIES :: 16

// The binaries of one build of the engine in the cache every checkout of the
// repository shares: built once, by whichever checkout gets there first.
@(private)
engine_cache_entry :: proc(root:string,key:u64,mode:Engine_Mode) -> string {
    return project.path(workspace.cache_folder(root,"engine",context.temp_allocator),fmt.tprintf("%x-%v",key,mode),allocator=context.temp_allocator)
}

// What a build leaves in the folder of the engine that projects and programs
// use: the libraries, the programs, their debug information and SDL3, the
// stamp and the declarations. The stages and the sources of the programs are not.
@(private)
engine_cache_files :: proc(folder:string) -> []string {
    list:=make([dynamic]string,context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    for entry in entries {
        if entry.type==.Directory || strings.has_suffix(entry.name,".obj") || strings.has_suffix(entry.name,".o") {continue}
        append(&list,entry.name)
    }
    return list[:]
}

// The mark of a whole entry of a shared cache, written last; its date is when
// the entry was last used.
@(private)
CACHE_COMPLETE :: "complete"

// Copies an entry of the cache over the binaries of the engine; false when
// there is none or it cannot be copied whole, and then nothing stands. Its
// stamp, of fingerprints relative to the root, goes last. The stages go: the
// libraries copied were not compiled from them.
@(private)
engine_cache_restore :: proc(entry:string,paths:Engine_Paths) -> bool {
    if !cache_entry_complete(entry) {return false}
    _=os.remove(paths.stamp)
    _=os.remove_all(paths.decl)
    engine_stages_remove(paths.folder)
    if os.make_directory_all(paths.folder)!=nil && !os.is_dir(paths.folder) {return false}
    for name in engine_cache_files(entry) {
        if name==CACHE_COMPLETE || name==ENGINE_STAMP {continue}
        if os.copy_file(project.path(paths.folder,name,allocator=context.temp_allocator),project.path(entry,name,allocator=context.temp_allocator))!=nil {return false}
    }
    if os.copy_directory_all(paths.decl,project.path(entry,"decl",allocator=context.temp_allocator))!=nil {return false}
    if os.copy_file(paths.stamp,project.path(entry,ENGINE_STAMP,allocator=context.temp_allocator))!=nil {return false}
    cache_entry_used(entry)
    return true
}

// Keeps the binaries just built in the cache.
@(private)
engine_cache_store :: proc(paths:Engine_Paths,entry:string) {
    staging,fresh:=cache_entry_begin(entry)
    if !fresh {return}
    for name in engine_cache_files(paths.folder) {
        if os.copy_file(project.path(staging,name,allocator=context.temp_allocator),project.path(paths.folder,name,allocator=context.temp_allocator))!=nil {_=os.remove_all(staging);return}
    }
    if os.copy_directory_all(project.path(staging,"decl",allocator=context.temp_allocator),paths.decl)!=nil {_=os.remove_all(staging);return}
    cache_entry_commit(entry,staging,ENGINE_CACHE_ENTRIES)
}

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
    _=os.remove_all(staging)
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
        _=os.remove_all(staging)
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

// What the stamp of the binaries in folder says they were built from, its
// first line, to tell later whether a program that started from them runs the
// last ones built. "" without one.
engine_stamp_of :: proc(folder:string,allocator:=context.allocator) -> string {
    data,error:=os.read_entire_file(project.path(folder,ENGINE_STAMP,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return ""}
    text:=string(data)
    line,_:=strings.split_lines_iterator(&text)
    return strings.clone(strings.trim_space(line),allocator)
}

// The stamp of the last build of a mode; false when there is none or it does not read.
@(private)
engine_stamp_read :: proc(file:string) -> (stamp:Engine_Stamp,ok:bool) {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return}
    lines:=strings.split_lines(strings.trim_space(string(data)),context.temp_allocator)
    if len(lines)!=1+ENGINE_PACKAGE_COUNT {return}
    fields:=strings.fields(lines[0],context.temp_allocator)
    if len(fields)!=2+2*len(Engine_Library) {return}
    stamp.declares=strconv.parse_int(fields[0],10) or_return
    stamp.programs=strconv.parse_u64_of_base(fields[1],16) or_return
    for &library,which in stamp.libraries {
        library.sources=strconv.parse_u64_of_base(fields[2+2*int(which)],16) or_return
        library.tools=strconv.parse_u64_of_base(fields[3+2*int(which)],16) or_return
    }
    // One line per package, in their order, each with its name.
    for line,index in lines[1:] {
        declared:=strings.fields(line,context.temp_allocator)
        if len(declared)!=2 || declared[1]!=engine_package(index) {return}
        stamp.declared[index]=strconv.parse_u64_of_base(declared[0],16) or_return
    }
    return stamp,true
}

// The first line says what every binary was built from (engine_stamp_of).
@(private)
engine_stamp_write :: proc(file:string,stamp:Engine_Stamp) -> os.Error {
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%d %x",stamp.declares,stamp.programs)
    for library in stamp.libraries {fmt.sbprintf(&b," %x %x",library.sources,library.tools)}
    for hash,index in stamp.declared {fmt.sbprintf(&b,"\n%x %s",hash,engine_package(index))}
    return os.write_entire_file(file,strings.to_string(b))
}

// Of each package of the engine, the hash of what whoever imports it compiles
// against: its declarations under decl and those of every package of the
// engine they import, directly or not. A declaration that changes moves the
// hashes of the packages that reach it and no other. Zero for a package that
// reaches declarations no hash follows (engine_imports).
@(private)
decl_hashes :: proc(decl:string) -> (hashes:[ENGINE_PACKAGE_COUNT]u64) {
    own:[ENGINE_PACKAGE_COUNT]u64
    followed:[ENGINE_PACKAGE_COUNT]bool
    reaches:=make([][ENGINE_PACKAGE_COUNT]bool,ENGINE_PACKAGE_COUNT,context.temp_allocator)
    for &reached,index in reaches {
        files:=engine_sources(decl,{engine_package(index)})
        own[index],_=fingerprint(decl,"",nil,files)
        followed[index]=engine_imports(decl,files,&reached)
        reached[index]=true
    }
    for via in 0..<ENGINE_PACKAGE_COUNT {
        for &reached in reaches {
            if !reached[via] {continue}
            for &to,index in reached {to||=reaches[via][index]}
        }
    }
    for &hash,index in hashes {
        whole:=true
        for reached,at in reaches[index] {
            if !reached {continue}
            whole&&=followed[at]
            hash=base.hash_combine(base.hash_combine(hash,base.name_hash(engine_package(at))),own[at])
        }
        if !whole {hash=0}
    }
    return
}

@(private)
ENGINE_COLLECTION :: "mirai:"

// Marks the packages of the engine that files import. Every string literal
// that names one with its collection counts, "mirai:core": an import is one
// however it is written, so none is missed, and a literal that is no import
// only builds more. followed is false when a file cannot be read or names
// declarations decl has that are of no package of the engine: what imports
// them compiles against something no hash follows.
@(private)
engine_imports :: proc(decl:string,files:[]string,reached:^[ENGINE_PACKAGE_COUNT]bool) -> (followed:bool) {
    followed=true
    for file in files {
        data,error:=os.read_entire_file(file,context.temp_allocator)
        followed&&=error==nil && engine_imports_text(decl,string(data),reached)
    }
    return
}

@(private)
engine_imports_text :: proc(decl,source:string,reached:^[ENGINE_PACKAGE_COUNT]bool) -> (followed:bool) {
    followed=true
    text:=source
    for {
        at:=strings.index(text,ENGINE_COLLECTION)
        if at<0 {break}
        quote:=text[at-1] if at>0 else 0
        text=text[at+len(ENGINE_COLLECTION):]
        if quote!='"' && quote!='`' {continue}
        end:=strings.index_byte(text,quote)
        if end<=0 {continue}
        path:=text[:end]
        if index,found:=engine_package_index(path);found {
            reached[index]=true
        } else if folder_path(path) && len(engine_sources(decl,{path}))>0 {
            followed=false
        }
    }
    return

    // Whether a literal can be the path of an import: a field tag, a format
    // or a message is not, and is not looked for in the declarations.
    folder_path :: proc(path:string) -> bool {
        for c in transmute([]u8)path {
            switch c {
            case 'a'..='z','A'..='Z','0'..='9','_','-','.','/':
            case: return false
            }
        }
        return true
    }
}

// -o and the attributes, the same for every binary of the engine and every
// library of a project: the layouts of what they share follow from them.
@(private)
engine_flags :: proc(root:string,dev:bool) -> [dynamic]string {
    flags:=make([dynamic]string,context.temp_allocator)
    // The debug information lets a crash report name the procedure and the line; it does not change the code.
    append(&flags,dev?"-o:minimal":"-o:speed","-debug",fmt.tprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES))
    platform_flags(root,&flags,false,context.temp_allocator)
    environment_flags(&flags,context.temp_allocator)
    return flags
}

// The sources of some packages under root, sorted, and the files given besides.
@(private)
engine_sources :: proc(root:string,packages:[]string,files:..string) -> []string {
    list:=make([dynamic]string,context.temp_allocator)
    for path in packages {
        folder:=project.path(root,path,allocator=context.temp_allocator)
        entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
        for entry in entries {
            if entry.type==.Directory || !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
            append(&list,slashes(entry.fullpath,context.temp_allocator))
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

// A library is compiled again when it is missing, its stage moved, or the
// compiler, the flags or what it embeds moved.
@(private)
engine_library_compile :: proc(force,present,stage_changed,tools_changed:bool) -> bool {
    return force || !present || stage_changed || tools_changed
}

@(private="file")
library_compile :: proc(result:^Engine_Result,compiler,root,stage,entry,output,name:string,links_libraries:bool,flags:[]string,step:string) -> bool {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,compiler,"build",project.path(stage,entry,allocator=context.temp_allocator),"-build-mode:dll",fmt.tprintf("-collection:mirai=%s",stage),fmt.tprintf("-out:%s",output))
    append(&command,..flags)
    // A library finds the ones it links beside it, whatever loads it.
    when ODIN_OS==.Linux {linker_flags_append(&command,fmt.tprintf("-Wl,-soname,%s%s",project.library_file(name,context.temp_allocator),links_libraries?" -Wl,-rpath,$ORIGIN":""),context.temp_allocator)}
    else when ODIN_OS==.Darwin {linker_flags_append(&command,fmt.tprintf("-Wl,-install_name,@rpath/%s%s",project.library_file(name,context.temp_allocator),links_libraries?" -Wl,-rpath,@loader_path":""),context.temp_allocator)}
    ok:=compile(result,root,command[:],step)
    // The diagnostics of a staged source point at the source.
    for &diagnostic in result.diagnostics {
        if strings.has_prefix(diagnostic.file,stage) {diagnostic.file=project.path(root,diagnostic.file[len(stage):])}
    }
    return ok
}

@(private="file")
compile :: proc(result:^Engine_Result,root:string,command:[]string,step:string) -> bool {
    full:=make([dynamic]string,context.temp_allocator)
    append(&full,..command)
    append(&full,"-json-errors")
    state,stdout,stderr,error:=subprocess.exec({command=full[:],env=child_environment(root,context.temp_allocator)},context.temp_allocator,compiler_limits(root))
    if error!=nil {
        result^=engine_fail(.Compiler_Failed,step,"")
        return false
    }
    diagnostics,rest:=diagnostics_parse(string(stderr),context.allocator)
    failed:=state.exit_code!=0
    for diagnostic in diagnostics {
        if diagnostic.severity==.Error {failed=true}
    }
    if !failed {return true}
    text:=strings.trim_space(strings.concatenate({rest,"\n",string(stdout)},context.temp_allocator))
    if text=="" && len(diagnostics)==0 {text=compiler_silent_failure(state.exit_code,context.temp_allocator)}
    result^=engine_fail(.Out_Of_Memory if compiler_out_of_memory(text) else .Compile,step,text)
    result.diagnostics=diagnostics
    return false
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
