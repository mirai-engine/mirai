package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:cook/build"
import "mirai:cook/shaders"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/subprocess"

DOCTOR_USAGE :: "doctor [project]"

// What is wrong on this machine or in a project, and what to do about it.
cmd_doctor :: proc(root:string,args:[]string) -> int {
    if len(args)>0 && args[0]=="--probe-gpu" {return gpu_probe()}
    folder:=len(args)>0?args[0]:(os.is_file(project.PROJECT_FILE)?".":"")
    errors:=0
    report :: proc(errors:^int,ok:bool,what,fix:string) {
        if ok {
            fmt.printfln("  ok     %s",what)
            return
        }
        errors^+=1
        fmt.printfln("  ERROR  %s\n         -> %s",what,fix)
    }
    fmt.printfln("Engine %s",root)
    installed:=project.engine_installed(root)
    if installed {
        m,manifest_error:=project.engine_manifest_read(root)
        platform:=base.text_get(m.platform[:])
        report(&errors,manifest_error.code==.None && platform==project.ENGINE_PLATFORM,fmt.tprintf("installed engine %s of %s, built from %s",base.text_get(m.version[:]),platform,base.text_get(m.commit[:])),fmt.tprintf("unpack the package of the engine for %s again",project.ENGINE_PLATFORM))
    }
    shared:=project.shared_root(root,context.temp_allocator)
    if !path_same(shared,root) {fmt.printfln("  info   worktree of %s: uses its .deps and its binary cache",shared)}
    deps:=workspace.deps_folder(root,context.temp_allocator)
    report(&errors,os.is_dir(deps),fmt.tprintf("dependencies in %s",deps),"download the pinned dependencies into .deps of the main checkout (README); a worktree takes them from there")
    compiler,found:=build.compiler_find(root)
    report(&errors,found,found?compiler:"Odin compiler",fmt.tprintf("install Odin %s in .deps/odin/dist, or put it in PATH or in MIRAI_ODIN",build.ODIN_RELEASE))
    if found {
        _,output,_,_:=subprocess.exec({command={compiler,"version"}},context.allocator)
        fields:=strings.fields(string(output))
        version:=len(fields)>0?fields[len(fields)-1]:"?"
        report(&errors,strings.has_prefix(version,build.ODIN_RELEASE),fmt.tprintf("Odin %s",version),fmt.tprintf("the engine is developed with Odin %s",build.ODIN_RELEASE))
    }
    memory,_:=build.compiler_memory()
    switch {
    case memory>0:
        fmt.printfln("  info   each compiler process may use %.1f GiB of memory (%s, in GiB)",f64(memory)/(1<<30),build.COMPILER_MEMORY_ENV)
    case ODIN_OS==.Darwin:
        fmt.println("  warn   no memory limit per build: macOS does not limit the memory of another process, and a multiple assignment of large values (odin-lang/Odin#7937) can take all the memory of the machine")
    case:
        fmt.printfln("  info   no memory limit per build (%s=0)",build.COMPILER_MEMORY_ENV)
    }
    toolchain,has_c:=c_toolchain_find()
    engine_clone:="" // the clone of a checkout of the engine, which a project inside it shares
    if installed {
        // The engine comes built; the code of a project is linked with the toolchain of the system.
        report(&errors,has_c,fmt.tprintf("C toolchain, which links the code of projects (%s)",toolchain),"install Visual Studio Build Tools with C++ on Windows, clang on Linux or the Xcode Command Line Tools on macOS")
        report(&errors,ensure_runtime_dependencies(root),"FreeType, ufbx and SQLite built","unpack the package of the engine again")
    } else {
        report(&errors,has_c && ensure_runtime_dependencies(root),fmt.tprintf("C compiler, FreeType, ufbx and SQLite (%s)",toolchain),"install a C compiler (on Windows, Visual Studio Build Tools); mirai deps shows the output")
        // The skills reach the agents through .claude/skills, a symbolic link of the repository.
        _,symlinks,_,_:=subprocess.exec({command={"git","-C",root,"config","--get","core.symlinks"}},context.temp_allocator)
        report(&errors,strings.trim_space(string(symlinks))=="true","git with core.symlinks","git config core.symlinks true (on Windows, with developer mode on) and then git checkout -- .claude/skills")
        report(&errors,link_to_folder(join(root,".claude","skills")),".claude/skills links to the folder .agents/skills","with core.symlinks on, delete .claude/skills and git checkout -- .claude/skills: a link git made before the folder existed stays a link to a file")
        engine_clone=doctor_git(&errors,root,root)
    }
    for tool in shaders.Tool {
        path,present:=shaders.tool_find(root,tool)
        if !present {
            report(&errors,false,fmt.tprintf("%v",tool),"mirai setup slang for Slang; the Vulkan SDK brings spirv-val, spirv-opt and spirv-cross")
            continue
        }
        if tool!=.Slangc {
            report(&errors,true,path,"")
            continue
        }
        version,answered:=shaders.slang_version(path)
        switch {
        case !answered:
            report(&errors,false,fmt.tprintf("%s (does not answer -version)",path),"reinstall the compiler: mirai setup slang")
        case !shaders.slang_version_at_least(version,shaders.SLANG_VERSION):
            report(&errors,false,fmt.tprintf("%s (Slang %s)",path,version),fmt.tprintf("the engine pins Slang %s or later; run `mirai setup slang` or point MIRAI_SLANGC to a newer one",shaders.SLANG_VERSION))
        case:
            report(&errors,true,fmt.tprintf("%s (Slang %s)",path,version),"")
        }
    }
    if _,installed:=ripgrep_folder(root);installed {
        report(&errors,true,fmt.tprintf("ripgrep %s in .deps",RIPGREP_VERSION),"")
    } else if path,present:=path_find("rg");present {
        report(&errors,true,fmt.tprintf("ripgrep (%s)",path),"")
    } else {
        fmt.println("  warn   ripgrep: missing -> mirai setup rg (agents search with rg, which skips .worktrees, .deps and bin)")
    }
    when ODIN_OS==.Windows {
        validation:=join(deps,"vulkan-sdk-windows","Bin","VkLayer_khronos_validation.json")
        layer_ok:=os.is_file(validation)
        fmt.printfln("  %s  Vulkan validation layer%s",layer_ok?"ok   ":"warn ",layer_ok?"":fmt.tprintf(": %s is missing; without it --validation runs without validating",validation))
    }
    for manifest in implicit_layers(context.temp_allocator) {
        present:=os.is_file(manifest)
        fmt.printfln("  %s  implicit Vulkan layer %s%s",present?"info ":"warn ",manifest,present?"":" (missing: the loader reports it as an error)")
    }
    fmt.println("         mirai test and --headless programs do not load implicit layers (MIRAI_KEEP_LAYERS=1 keeps them)")
    if extra,set:=os.lookup_env("MIRAI_ODIN_FLAGS",context.temp_allocator);set && extra!="" {
        fmt.printfln("  info   MIRAI_ODIN_FLAGS=%s is added to every build (except -thread-count, it does not change the fingerprint)",extra)
    }
    built:=false
    if installed {
        _,present:=build.engine_state(root,build.ENGINE_MODE_INSTALLED)
        report(&errors,present,fmt.tprintf("engine binaries in %s",build.engine_paths(root,build.ENGINE_MODE_INSTALLED,context.temp_allocator).folder),"unpack the package of the engine again")
        built=true
    }
    for mode in ([2]build.Engine_Mode{.Dev,.Release}) {
        if installed {break}
        flag:=mode==.Dev?"--dev":"--release"
        stamped,current:=build.engine_state(root,mode)
        built||=stamped
        switch {
        case !stamped:
        case current: fmt.printfln("  ok     engine binaries %s up to date in %s",flag,build.engine_paths(root,mode,context.temp_allocator).folder)
        case:         fmt.printfln("  warn   engine binaries %s older than their sources -> mirai build engine %s",flag,flag)
        }
    }
    if !built {fmt.println("  warn   engine binaries: not built -> mirai build engine --dev")}
    if entries,cache_error:=os.read_all_directory_by_path(workspace.cache_folder(root,"engine",context.temp_allocator),context.temp_allocator);cache_error==nil {
        fmt.printfln("  info   shared engine cache: %d builds",len(entries))
    }
    self,_:=os.get_executable_path(context.allocator)
    state,printed,_,error:=subprocess.exec({command={self,"doctor","--probe-gpu"}},context.allocator)
    gpu:=strings.trim_space(string(printed))
    report(&errors,error==nil && state.exit_code==0 && strings.has_prefix(gpu,"device="),gpu!=""?gpu:"graphics device","install or update the GPU driver: Vulkan 1.3 is needed, or Metal on macOS")
    if folder=="" {return errors>0?1:0}

    fmt.printfln("Project %s",project.path_absolute(folder))
    p,open_error:=project.open(folder,root)
    if open_error.code!=.None {
        report(&errors,false,project_error_text(folder,open_error),"fix the file")
        return 1
    }
    defer project.close(&p)
    doctor_git(&errors,root,folder,engine_clone)
    out:=build.world_generate(&p,context.temp_allocator)
    for e in out.errors {report(&errors,false,e,"fix the attributes; mirai generate lists them")}
    if len(out.errors)==0 {report(&errors,true,"the world of the project generates","")}
    if scene:=base.text_get(p.manifest.start_scene[:]);scene!="" {
        report(&errors,os.is_file(project.path(project.folder_path(p.root,.Assets),scene)),fmt.tprintf("start scene %s",scene),fmt.tprintf("save that scene or change start_scene in %s",project.PROJECT_FILE))
    }
    state_name:=[build.Target_State]string{.Missing="not built",.Stale="older than its sources",.Current="up to date"}
    editor:=build.target_state(&p,.Editor,compiler,engine=build.engine_mode_resolve(root,.Keep))
    fmt.printfln("  %s  editor %s%s",editor==.Current?"ok   ":"warn ",state_name[editor],editor==.Current?"":fmt.tprintf(" -> mirai build editor %s",folder))
    return errors>0?1:0
}

// The device rhi would give a renderer, in a process of its own: a driver
// that takes the process down is a finding, not the end of the report.
gpu_probe :: proc() -> int {
    device,error:=rhi.device_create({app_name="mirai doctor",allow_hardware_ray_tracing=true,upload_bytes_per_frame=1<<20})
    if device==nil {
        fmt.printfln("error=%s",error)
        return 1
    }
    info:=rhi.device_info(device)
    fmt.printfln("device=%s (%v, %v, ray queries %v)",info.name,info.backend,info.type,info.features.ray_query)
    rhi.device_destroy(device)
    return 0
}
