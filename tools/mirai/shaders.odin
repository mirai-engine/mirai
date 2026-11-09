package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:cook/build"
import "mirai:cook/shaders"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:project"

SHADERS_EDITOR_MS :: 610_000 // the 600 s build.start waits by default, and the answer

SHADERS_USAGE :: "shaders [--project <path> [--whole]] [--output <path>] [--no-odin] [--cache <path>] [--workers <n>] [--backends vulkan|metal|all] | shaders check <program.slang> [--project <path>]"

cmd_shaders :: proc(root:string,args:[]string) -> int {
    if len(args)>0 && args[0]=="check" {return shaders_check(root,args[1:])}
    options:=shaders.Options{root=root,odin=true}
    whole:=false
    for i:=0;i<len(args);i+=1 {
        if args[i]=="--no-odin" {options.odin=false;continue}
        if args[i]=="--whole" {whole=true;continue}
        handled:=false
        for target in ([]struct{name:string,value:^string}{{"--project",&options.project},{"--output",&options.output},{"--cache",&options.cache}}) {
            value,matched,ok:=option_value(args,&i,target.name)
            if !matched {continue}
            if !ok || value=="" {fmt.eprintfln("mirai shaders: %s needs a path",target.name);return 2}
            target.value^=value
            handled=true
            break
        }
        if handled {continue}
        if value,matched,ok:=option_value(args,&i,"--workers");matched {
            count,parsed:=strconv.parse_int(value,10)
            if !ok || !parsed || count<1 {fmt.eprintln("mirai shaders: --workers must be a positive integer");return 2}
            options.workers=count
            continue
        }
        if value,matched,_:=option_value(args,&i,"--backends");matched {
            switch value {
            case "vulkan": options.backends={.Vulkan}
            case "metal":  options.backends={.Metal}
            case "all":    options.backends={.Vulkan,.Metal}
            case: fmt.eprintln("mirai shaders: --backends is vulkan, metal or all");return 2
            }
            continue
        }
        fmt.eprintfln("mirai shaders: unknown argument '%s'\nUsage: mirai %s",args[i],SHADERS_USAGE)
        return 2
    }
    if options.project=="" && project.engine_installed(root) {
        fmt.eprintln("mirai shaders: an installed engine carries its shaders already generated; --project generates those of a project")
        return 1
    }
    if options.project!="" {
        opened,sources,ok:=project_shader_sources(options.project,root,"mirai shaders")
        if !ok {return 1}
        options.project,options.sources=opened,sources
        if !whole && options.output=="" && options.cache=="" && options.backends=={} {
            if file,alive:=session_find(opened);alive {return shaders_publish_editor(opened,file.port)}
        }
    }
    result:=shaders.generate(options)
    defer shaders.result_destroy(&result)
    if result.warnings!="" {fmt.eprint(result.warnings)}
    if result.error!="" {fmt.eprintln(result.error);return 1}
    if result.current {
        fmt.printfln("shaders: up to date (%d Slang programs, %d tests, %d material programs)",result.shaders,result.tests,result.programs)
    } else {
        fmt.printfln("shaders: %d Slang programs, %d tests, %d material programs (%d compiled, %d reused)",result.shaders,result.tests,result.programs,result.compiled,result.reused)
        fmt.printfln("shaders: programs reflected in %.1f s, stages compiled in %.1f s added up",result.reflection,result.compiling)
        for each in result.slowest {
            if each.seconds>0 {fmt.printfln("  %.1f s  %s",each.seconds,each.name)}
        }
    }
    return 0
}

// The open editor of the project publishes its shaders, the stages its
// viewport runs first, and the command ends once it draws with them: the
// others go on compiling in the editor. --whole generates them all here.
@(private="file")
shaders_publish_editor :: proc(folder:string,port:int) -> int {
    result,err,called:=api.rpc_call(port,"build.start",`{"target":"shaders"}`,1,SHADERS_EDITOR_MS,context.temp_allocator)
    if !called || err.code!=0 {
        fmt.eprintfln("mirai shaders: the editor of %s did not publish them: %s",folder,err.message!=""?err.message:"it did not answer")
        return 1
    }
    reply:struct {seconds:f64,publishing:bool}
    _=json.unmarshal_string(result,&reply)
    fmt.printfln("shaders: the editor of %s draws with them after %.1f s%s",folder,reply.seconds,reply.publishing?"; the stages it does not run go on compiling there":"")
    return 0
}

// The root of the project in folder and the folders of programs its build passes besides its own
// shaders/ (build.shader_sources); ok is false, after saying why, when it does not open.
@(private="file")
project_shader_sources :: proc(folder,root,who:string) -> (project_root:string,sources:[]shaders.Source,ok:bool) {
    p,error:=project.open(folder,root,context.temp_allocator)
    if error.code!=.None {fmt.eprintfln("%s: could not open the project %s",who,folder);return}
    sources,_=build.shader_sources(&p,context.temp_allocator)
    return p.root,sources,true
}

// Checks a program as material.program.check does: the rules of the check and
// the compilations where it runs, without publishing. Exit 1 when it has errors.
@(private="file")
shaders_check :: proc(root:string,args:[]string) -> int {
    path,folder:string
    for i:=0;i<len(args);i+=1 {
        if value,matched,ok:=option_value(args,&i,"--project");matched {
            if !ok || value=="" {fmt.eprintln("mirai shaders check: --project needs a path");return 2}
            folder=value
            continue
        }
        if path!="" || strings.has_prefix(args[i],"--") {fmt.eprintfln("Usage: mirai %s",SHADERS_USAGE);return 2}
        path=args[i]
    }
    if path=="" {fmt.eprintfln("Usage: mirai %s",SHADERS_USAGE);return 2}
    options:=shaders.Check_Options{root=root,path=path}
    if folder!="" {
        ok:bool
        options.project,options.sources,ok=project_shader_sources(folder,root,"mirai shaders check")
        if !ok {return 1}
    }
    result:=shaders.program_check(options)
    defer shaders.check_result_destroy(&result)
    if result.error!="" {fmt.eprintln(result.error);return 1}
    for d in result.diagnostics {fmt.println(shaders.diagnostic_text(d,context.temp_allocator))}
    fmt.printfln("%s: %d errors, %d warnings%s",result.file,result.errors,result.warnings,result.compiled?"; compiles in the stages that run it":"")
    return result.errors>0?1:0
}

// The shaders of the engine, generated from Slang unless the ones there are
// current: render and the tests of rhi embed them, and git does not keep them.
// A generation that compiles takes its turn with the other compilations,
// unless the caller already has it. backends: {} for the host's.
engine_shaders :: proc(root:string,turn_held:=false,backends:shaders.Backends={}) -> bool {
    // An installed engine carries them, generated when it was packaged.
    if project.engine_installed(root) {return true}
    options:=shaders.Options{root=root,odin=true,backends=backends}
    lock:workspace.Lock
    defer workspace.lock_release(&lock)
    if !turn_held {
        if shaders.current(options) {return true}
        lock=shaders_lock(root)
    }
    result:=shaders.generate(options)
    defer shaders.result_destroy(&result)
    return engine_shaders_report(result)
}

// The backends a build for the Odin flags of args reads, with the host's: a
// -target of another system also needs that system's code.
target_backends :: proc(args:[]string) -> shaders.Backends {
    backends:=shaders.Backends{shaders.HOST_BACKEND}
    for argument in args {
        if !strings.has_prefix(argument,"-target:") {continue}
        backends+={.Metal if strings.has_prefix(argument[len("-target:"):],"darwin_") else .Vulkan}
    }
    return backends
}

// Says what a generation of the engine's shaders did, in out; false when it failed.
engine_shaders_report :: proc(result:shaders.Result,out:=os.stdout) -> bool {
    if result.warnings!="" {fmt.eprint(result.warnings)}
    if result.error!="" {fmt.eprintfln("mirai: the engine shaders could not be generated: %s",result.error);return false}
    if !result.current && result.compiled+result.reused>0 {
        fmt.fprintfln(out,"shaders/build: %d stages compiled and %d reused.",result.compiled,result.reused)
    }
    return true
}

SETUP_USAGE :: "setup slang|rg [--archive <file>] | setup path"

cmd_setup :: proc(root:string,args:[]string) -> int {
    if len(args)==1 && args[0]=="path" {return setup_path(root)}
    if len(args)==0 || args[0]!="slang" && args[0]!="rg" && args[0]!="ripgrep" {fmt.eprintfln("Usage: mirai %s",SETUP_USAGE);return 2}
    archive:string
    for i:=1;i<len(args);i+=1 {
        value,matched,ok:=option_value(args,&i,"--archive")
        if !matched || !ok || value=="" {fmt.eprintfln("Usage: mirai %s",SETUP_USAGE);return 2}
        archive=value
    }
    if args[0]!="slang" {return setup_ripgrep(root,archive)}
    message,installed:=shaders.slang_install(root,archive)
    if !installed {fmt.eprintln(message);return 1}
    fmt.println(message)
    return 0
}

// The shaders the GPU tests of a package of an engine plugin load: those of
// the plugin and, as <plugin>_test, the programs of testdata/ of the package,
// in <root>/.mirai/tmp/<plugin>-test-shaders. A test of a runtime package does
// not generate them itself: the shipped game compiles its test files too, and
// cook is not shipped. Only for a package whose tests take the shared device.
plugin_test_shaders :: proc(root,folder:string) -> bool {
    plugins:=project.path_absolute(join(root,"plugins"),context.temp_allocator)
    absolute:=project.path_absolute(folder,context.temp_allocator)
    if len(absolute)<=len(plugins) || absolute[len(plugins)]!='/' || !path_same(absolute[:len(plugins)],plugins) {return true}
    rest:=absolute[len(plugins)+1:]
    name:=rest
    if slash:=strings.index_byte(rest,'/');slash>=0 {name=rest[:slash]}
    folder_shaders:=join(plugins,name,"shaders")
    if !os.is_dir(folder_shaders) || !takes_shared_device(absolute) {return true}
    sources:=make([dynamic]shaders.Source,context.temp_allocator)
    append(&sources,shaders.Source{name=name,folder=folder_shaders})
    testdata:=join(absolute,"testdata")
    if entries,error:=os.read_all_directory_by_path(testdata,context.temp_allocator);error==nil {
        for entry in entries {
            if strings.has_suffix(entry.name,".slang") {
                append(&sources,shaders.Source{name=fmt.tprintf("%s_test",name),folder=testdata})
                break
            }
        }
    }
    output:=join(root,".mirai","tmp",fmt.tprintf("%s-test-shaders",name))
    lock:=shaders_lock(root)
    defer workspace.lock_release(&lock)
    result:=shaders.generate({root=root,sources=sources[:],output=output,cache=fmt.tprintf("%s-stamp",output)})
    defer shaders.result_destroy(&result)
    if result.warnings!="" {fmt.eprint(result.warnings)}
    if result.error!="" {fmt.eprintfln("mirai test: the shaders of the plugin %s could not be generated: %s",name,result.error);return false}
    return true
}

@(private="file")
takes_shared_device :: proc(folder:string) -> bool {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        if !strings.has_suffix(entry.name,"_test.odin") {continue}
        text,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if strings.contains(string(text),`"mirai:rhi/shared_device"`) {return true}
    }
    return false
}
