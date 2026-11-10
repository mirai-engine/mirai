package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:cook/build"
import "mirai:cook/shaders"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

PACKAGE_USAGE :: "package engine --out <folder>"

// What a package of the engine takes of what git keeps: the sources the
// generator of a world reads and a shipped game compiles, the shaders the
// projects compile with, the templates, the recipes of Create, the skills of
// the agents, the game documentation mirai docs serves, the license of the
// engine and the notices of what it carries of others. cook/ and tools/ are
// in its binaries; their sources stay behind, as do the tests.
@(private="file")
PACKAGE_TRACKED :: [?]string{
    "asset","audio","core","editor","engine","host","net","platform","plugins","project","render","rhi","std","ui",
    "shaders","templates","recipes","assets/fonts",".agents/skills","docs/game","LICENSE-MIT","LICENSE-APACHE","THIRD_PARTY_NOTICES.md",
}
// Generated from those sources, and kept by git in no checkout.
@(private="file")
PACKAGE_GENERATED :: [?]string{"render/shaders_gen.odin","shaders/build"}
// What a C library of third_party keeps besides its sources: its binding and its notices.
@(private="file")
PACKAGE_C_LIBRARIES :: [?]string{"third_party/freetype","third_party/ufbx","third_party/sqlite"}
// Of the folder of the Odin compiler, what projects do not use.
@(private="file")
PACKAGE_ODIN_SKIPPED :: [?]string{"examples","tests","misc","docs","src","ci",".git",".github"}
// Where a package puts the compiler under its deps, where workspace.deps_compiler
// looks: on Linux with the C libraries of vendor compiled, as ODIN_ROOT.
@(private="file")
PACKAGE_ODIN :: "linux-amd64/odin" when ODIN_OS==.Linux else "odin/dist"
// Where it puts the tools of SPIR-V, one level under its deps.
@(private="file")
PACKAGE_SPIRV :: "spirv-tools"

// mirai package engine --out <folder>: this checkout as an installed engine
// (project.ENGINE_FILE), for whoever builds projects and not the engine: the
// binaries of the engine built --release, the tool, the compiler, Slang and the
// tools of SPIR-V, SDL3, the sources the generator and a shipped game read,
// the shaders, the templates and the skills, and the libraries of the plugins
// of the engine for every project without defines nor debug information, at
// minimal and at speed. The workflow of the releases archives the folder.
cmd_package :: proc(root:string,args:[]string) -> int {
    if len(args)!=3 || args[0]!="engine" || args[1]!="--out" || args[2]=="" {fmt.eprintfln("Usage: mirai %s",PACKAGE_USAGE);return 2}
    out:=project.path_absolute(args[2])
    if os.exists(out) {
        entries,error:=os.read_all_directory_by_path(out,context.temp_allocator)
        if !os.is_dir(out) || error!=nil || len(entries)>0 {fmt.eprintfln("mirai package: %s already exists and is not an empty folder",out);return 1}
    }

    // What it takes from the deps of this checkout, found before anything is built.
    deps:=workspace.deps_folder(root)
    compiler,compiler_found:=build.compiler_find(root)
    if !compiler_found {fmt.eprintfln("mirai package: cannot find the Odin compiler; install Odin %s in .deps/odin/dist",build.ODIN_RELEASE);return 1}
    slangc,slang_found:=shaders.tool_find(root,.Slangc)
    slang:=filepath.dir(filepath.dir(slangc))
    if !slang_found || !project.path_same(slang,join(deps,"slang")) {fmt.eprintfln("mirai package: the package carries the Slang of %s/slang: mirai setup slang",deps);return 1}
    spirv:[3]string
    for tool,i in ([3]shaders.Tool{.Spirv_Val,.Spirv_Opt,.Spirv_Cross}) {
        found:bool
        if spirv[i],found=shaders.tool_find(root,tool);!found {fmt.eprintfln("mirai package: cannot find %v; the Vulkan SDK brings spirv-val, spirv-opt and spirv-cross",tool);return 1}
    }
    sdl:=build.sdl_deps_folder(root)
    when ODIN_OS==.Linux {
        if sdl=="" {fmt.eprintln("mirai package: SDL3 is not under .deps/linux-amd64: uv run scripts/setup_linux_deps.py");return 1}
    } else when ODIN_OS==.Darwin {
        if sdl=="" {fmt.eprintln("mirai package: the package needs an SDL3 it can carry, which Homebrew's is not: uv run scripts/setup_macos_deps.py");return 1}
    }
    state,head,_,git_error:=subprocess.exec({command={"git","-C",root,"rev-parse","HEAD"}},context.allocator)
    if git_error!=nil || state.exit_code!=0 {fmt.eprintln("mirai package: git does not name the commit of this checkout");return 1}

    lock:=build_lock(root,"package engine")
    defer workspace.lock_release(&lock)
    if _,_,released:=engine_release(root,"",.Release,"package engine");!released {return 1}
    if !ensure_runtime_dependencies(root) {fmt.eprintln("mirai package: the C libraries could not be built; mirai deps shows why");return 1}
    if code:=engine_report(build.engine_build({engine_root=root,mode=.Release}),root);code!=0 {return code}

    fmt.printfln("mirai package: writing %s",out)
    if !package_sources(root,out) {return 1}
    from:=build.engine_paths(root,.Release,context.temp_allocator)
    to:=build.engine_paths(out,.Release,context.temp_allocator)
    if !package_binaries(from.folder,to.folder) {fmt.eprintfln("mirai package: could not copy %s",from.folder);return 1}
    odin_version:=package_odin(compiler,join(out,".deps",PACKAGE_ODIN))
    if odin_version=="" {fmt.eprintfln("mirai package: could not copy the compiler of %s",compiler);return 1}
    if !package_slang(slang,join(out,".deps","slang")) {fmt.eprintfln("mirai package: could not copy %s",slang);return 1}
    if !package_spirv(spirv[:],join(out,".deps",PACKAGE_SPIRV)) {fmt.eprintln("mirai package: could not copy the tools of SPIR-V");return 1}
    if sdl!="" && os.copy_directory_all(join(out,".deps",sdl),join(deps,sdl))!=nil {fmt.eprintfln("mirai package: could not copy %s/%s",deps,sdl);return 1}

    // The tool, built for speed: it is what people run.
    if os.make_directory_all(join(out,"bin"))!=nil {fmt.eprintfln("mirai package: could not write to %s",out);return 1}
    sources:=join(root,"bin",fmt.aprintf(".package-%d.sources.json",os.get_pid()))
    defer os.remove(sources)
    command:=tool_command(root,"tools/mirai","-o:speed",join(out,"bin",fmt.aprintf("mirai%s",project.EXECUTABLE_SUFFIX)),sources)
    if code:=run_compiler(root,command[:],"mirai package engine");code!=0 {return code}

    m:project.Engine_Manifest
    base.text_set(m.version[:],project.ENGINE_VERSION)
    base.text_set(m.commit[:],strings.trim_space(string(head)))
    base.text_set(m.platform[:],project.ENGINE_PLATFORM)
    base.text_set(m.odin[:],odin_version)
    if version,answered:=shaders.slang_version(slangc,context.temp_allocator);answered {base.text_set(m.slang[:],version)}
    if error:=project.engine_manifest_write(out,&m);error.code!=.None {fmt.eprintfln("mirai package: could not write %s",project.ENGINE_FILE);return 1}

    // The plugin libraries, built by the engine just packaged: their fingerprints are those of its projects.
    if !package_plugins(out) {return 1}
    // What the imports of the plugins build, which no checkout has: an installed engine imports nothing.
    imported:=make([dynamic]string,context.temp_allocator)
    plugins,_:=os.read_all_directory_by_path(join(out,"plugins"),context.temp_allocator)
    for plugin in plugins {
        if os.is_dir(join(out,"plugins",plugin.name,"source")) {append(&imported,join(out,"plugins",plugin.name))}
    }
    if ok,message:=build.imports_sync(out,.Release,imported[:]);!ok {
        fmt.eprintfln("mirai package: could not import the sources of the plugins: %s",message)
        return 1
    }
    _=base.remove_all(join(out,".mirai","tmp"))
    _=base.remove_all(workspace.cache_folder(out,"locks",context.temp_allocator))

    total:i64
    files:=0
    walker:=os.walker_create(out)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if info.type==.Regular {total+=info.size;files+=1}
    }
    fmt.printfln("%s ready: engine %s for %s, %d files, %.0f MB",out,project.ENGINE_VERSION,project.ENGINE_PLATFORM,files,f64(total)/(1<<20))
    return 0
}

// The files of PACKAGE_TRACKED as git keeps them, without tests, those of
// PACKAGE_GENERATED, and the binding, the notices and the built library of
// each C library.
@(private="file")
package_sources :: proc(root,out:string) -> bool {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,"git","-C",root,"ls-files","-z","--")
    tracked:=PACKAGE_TRACKED
    append(&command,..tracked[:])
    libraries:=PACKAGE_C_LIBRARIES
    append(&command,..libraries[:])
    state,listed,said,error:=subprocess.exec({command=command[:]},context.allocator)
    if error!=nil || state.exit_code!=0 {fmt.eprintfln("mirai package: git ls-files failed: %s",strings.trim_space(string(said)));return false}
    copied:=0
    rest:=string(listed)
    for file in strings.split_iterator(&rest,"\x00") {
        if file=="" || strings.has_suffix(file,"_test.odin") || strings.contains(file,"testdata/") {continue}
        // Of a C library, what sits at its top but its sources: they are in the library already built.
        if package_c_source(file) {continue}
        // A file git keeps but this checkout deleted is not packaged.
        if !os.is_file(join(root,file)) {continue}
        if !package_copy(join(root,file),join(out,file)) {return false}
        copied+=1
    }
    for generated in PACKAGE_GENERATED {
        from:=join(root,generated)
        if os.is_dir(from) {
            if os.copy_directory_all(join(out,generated),from)!=nil {fmt.eprintfln("mirai package: could not copy %s",from);return false}
        } else if !package_copy(from,join(out,generated)) {
            return false
        }
    }
    for library in c_libraries() {
        files:=c_library_files(root,library)
        built:=fmt.tprintf("third_party/%s/%s",library.name,filepath.base(files.directory))
        for file in ([2]string{files.library,files.key}) {
            if !package_copy(file,join(out,built,filepath.base(file))) {return false}
        }
    }
    fmt.printfln("mirai package: %d sources",copied)
    return true
}

// A file of a C library that its built library replaces: one in a folder of
// it, or a source of C at its top.
@(private="file")
package_c_source :: proc(file:string) -> bool {
    for library in PACKAGE_C_LIBRARIES {
        if len(file)<=len(library) || !strings.has_prefix(file,library) || file[len(library)]!='/' {continue}
        rest:=file[len(library)+1:]
        return strings.contains(rest,"/") || strings.has_suffix(rest,".c") || strings.has_suffix(rest,".h")
    }
    return false
}

@(private="file")
package_copy :: proc(from,to:string) -> bool {
    folder:=filepath.dir(to)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) || os.copy_file(to,from)!=nil {
        fmt.eprintfln("mirai package: could not copy %s to %s%s",from,to,len(to)>=260 && ODIN_OS==.Windows?": the path is longer than Windows allows; package into a shorter folder":"")
        return false
    }
    return true
}

// What projects and programs use of the binaries of the engine: the
// libraries and what links against them, the programs, their debug
// information, SDL3, the stamp and the declarations. Not the stages, the
// sources of the programs nor what the linker leaves.
@(private="file")
package_binaries :: proc(from,to:string) -> bool {
    if os.make_directory_all(to)!=nil && !os.is_dir(to) {return false}
    entries,error:=os.read_all_directory_by_path(from,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        if entry.type==.Directory {continue}
        if strings.has_suffix(entry.name,".obj") || strings.has_suffix(entry.name,".o") || strings.has_suffix(entry.name,".exp") || strings.has_suffix(entry.name,".ilk") {continue}
        if os.copy_file(join(to,entry.name),entry.fullpath)!=nil {return false}
    }
    return os.copy_directory_all(join(to,"decl"),join(from,"decl"))==nil
}

// Copies the folder of the compiler without what projects do not use and,
// when ODIN_ROOT is elsewhere with the C libraries of vendor compiled
// (platform_environment on Linux), that vendor over its own. The release of
// the compiler; "" when it fails.
@(private="file")
package_odin :: proc(compiler,to:string) -> string {
    folder:=filepath.dir(compiler)
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil || os.make_directory_all(to)!=nil && !os.is_dir(to) {return ""}
    skipped:=PACKAGE_ODIN_SKIPPED
    copy: for entry in entries {
        for name in skipped {if entry.name==name {continue copy}}
        target:=join(to,entry.name)
        if entry.type==.Directory {
            if os.copy_directory_all(target,entry.fullpath)!=nil {return ""}
        } else if os.copy_file(target,entry.fullpath)!=nil {
            return ""
        }
    }
    odin_root,_:=os.lookup_env("ODIN_ROOT",context.temp_allocator)
    if odin_root!="" && !project.path_same(odin_root,folder) && os.is_dir(join(odin_root,"vendor")) {
        if os.copy_directory_all(join(to,"vendor"),join(odin_root,"vendor"))!=nil {return ""}
    }
    _,said,_,run_error:=subprocess.exec({command={compiler,"version"}},context.temp_allocator)
    fields:=strings.fields(string(said),context.temp_allocator)
    if run_error!=nil || len(fields)==0 {return ""}
    return strings.clone(fields[len(fields)-1])
}

// Slang as mirai setup slang installed it: its programs, its libraries and its notices.
@(private="file")
package_slang :: proc(from,to:string) -> bool {
    entries,error:=os.read_all_directory_by_path(from,context.temp_allocator)
    if error!=nil || os.make_directory_all(to)!=nil && !os.is_dir(to) {return false}
    for entry in entries {
        target:=join(to,entry.name)
        if entry.type!=.Directory {
            if os.copy_file(target,entry.fullpath)!=nil {return false}
        } else if entry.name=="bin" || entry.name=="lib" || strings.has_prefix(strings.to_lower(entry.name,context.temp_allocator),"licenses") || entry.name=="third-party-notices" {
            if os.copy_directory_all(target,entry.fullpath)!=nil {return false}
        }
    }
    return true
}

// The tools of SPIR-V side by side, each with the libraries of SPIR-V of its
// folder that it may load, and the licenses of its folder and of the one above.
@(private="file")
package_spirv :: proc(tools:[]string,to:string) -> bool {
    if os.make_directory_all(to)!=nil && !os.is_dir(to) {return false}
    for tool in tools {
        if os.copy_file(join(to,filepath.base(tool)),tool)!=nil {return false}
        folder:=filepath.dir(tool)
        for searched,above in ([2]string{folder,filepath.dir(folder)}) {
            entries,_:=os.read_all_directory_by_path(searched,context.temp_allocator)
            for entry in entries {
                if entry.type==.Directory {continue}
                name:=strings.to_lower(entry.name,context.temp_allocator)
                library:=strings.has_suffix(name,".dll") || strings.has_suffix(name,".dylib") || strings.contains(name,".so")
                license:=strings.has_prefix(name,"license")
                if !license && (above==1 || !library || !strings.contains(name,"spirv")) {continue}
                if os.copy_file(join(to,entry.name),entry.fullpath)!=nil {return false}
            }
        }
    }
    return true
}

// Builds the libraries of every plugin of the engine at out into its shared
// cache, at minimal and at speed, through a project that activates them all:
// a project of that engine with the same flags takes them from there.
@(private="file")
package_plugins :: proc(out:string) -> bool {
    compiler,found:=workspace.deps_compiler(out,context.temp_allocator)
    if !found {fmt.eprintfln("mirai package: %s has no compiler",out);return false}
    m:=project.manifest_default("plugins")
    named:=0
    entries,_:=os.read_all_directory_by_path(join(out,"plugins"),context.temp_allocator)
    for entry in entries {
        if entry.type!=.Directory {continue}
        plugin,error:=project.plugin_read(join(entry.fullpath,project.PLUGIN_FILE))
        if error.code!=.None || plugin.automatic || plugin.parts & {.Runtime,.Editor}=={} {continue}
        if named==len(m.plugins) {fmt.eprintfln("mirai package: more than %d plugins to build",len(m.plugins));return false}
        m.plugins[named]=plugin.name
        named+=1
    }
    for optimization in ([2]project.Optimization{.Minimal,.Speed}) {
        scratch:=join(out,".mirai","tmp",fmt.tprintf("plugins-%v",optimization))
        _=base.remove_all(scratch)
        if os.make_directory_all(scratch)!=nil {fmt.eprintfln("mirai package: could not write to %s",scratch);return false}
        m.build.optimization=optimization
        if error:=project.manifest_write(join(scratch,project.PROJECT_FILE),&m);error.code!=.None {fmt.eprintfln("mirai package: %s",project_error_text(scratch,error));return false}
        p,error:=project.open(scratch,out)
        if error.code!=.None {fmt.eprintfln("mirai package: %s",project_error_text(scratch,error));return false}
        defer project.close(&p)
        job:=build.job_run({project=&p,target=.Editor,compiler=compiler,engine=build.ENGINE_MODE_INSTALLED})
        defer build.job_destroy(job)
        result:=&job.result
        for diagnostic in result.diagnostics {
            fmt.eprintfln("%s(%d:%d) %s: %s",diagnostic.file,diagnostic.line,diagnostic.column,diagnostic.severity==.Error?"Error":"Warning",diagnostic.message)
        }
        if result.status==.Failed {
            if result.text!="" {fmt.eprintln(result.text)}
            fmt.eprintfln("mirai package: the plugin libraries at %v failed (%v)",optimization,result.failure)
            return false
        }
        fmt.printfln("mirai package: %d plugin libraries at %v in %.1f s",result.plugins_built,optimization,result.seconds)
    }
    return true
}
