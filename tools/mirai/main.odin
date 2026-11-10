package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:path/filepath"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

Command :: struct {name,usage,summary:string,run:proc(root:string,args:[]string)->int}

COMMANDS :: [?]Command{
    {"build",BUILD_USAGE,"Builds the mirai tool into bin/",cmd_build},
    {"build",BUILD_ENGINE_USAGE,"Builds the engine libraries, their declarations and the programs that load a project",cmd_build},
    {"build",BUILD_PROJECT_USAGE,"Builds the editor, the game or the dedicated server of a project",cmd_build},
    {"generate",GENERATE_USAGE,"Generates the world of a project from the attributes of its packages",cmd_generate},
    {"edit",EDIT_USAGE,"Generates, builds and opens the editor of a project",cmd_edit},
    {"play",PLAY_USAGE,"Generates, builds and plays a project without cooking its assets",cmd_play},
    {"play",PLAY_TEST_USAGE,"Plays the scenarios of a project (gameplay tests in tests/scenarios) in a headless editor and says which pass",cmd_play},
    {"new",NEW_USAGE,"Creates a project from a template of templates/",cmd_new},
    {"plugin",PLUGIN_USAGE,"Adds, updates or removes the plugins from Git of a project, by address or from the catalog",cmd_plugin},
    {"package",PACKAGE_USAGE,"Packages this checkout as an installed engine, built --release with its tool, compiler, shader tools and plugin libraries, for building projects without building the engine",cmd_package},
    {"worktree",WORKTREE_USAGE,"Creates a git worktree ready to build, with the dependencies and binaries of the main checkout",cmd_worktree},
    {"doctor",DOCTOR_USAGE,"Checks the machine and a project: what fails and how to fix it",cmd_doctor},
    {"test",TEST_USAGE,"Builds if needed and runs the tests of one or more packages",cmd_test},
    {"test",TEST_LIST_USAGE,"Lists the tests of a package or of a file without building",cmd_test},
    {"check","check <package> [-flag...]","Checks the types of a package",cmd_check},
    {"locks",LOCKS_USAGE,"Says who holds the build and measurement turns of all checkouts and since when, or that they are free",cmd_locks},
    {"measure",MEASURE_USAGE,"Runs a command that measures times alone: waits for other measurements and for builds; what builds or tests meanwhile runs at low priority",cmd_measure},
    {"deps","deps","Builds the C dependencies pinned in third_party/",cmd_deps},
    {"asset","asset <subcommand> [arguments]","Inspects and edits binary assets of any type",cmd_asset},
    {"image",IMAGE_USAGE,"Compares PNG captures (SSIM, PSNR, MAE, RMSE), measures light mottling, describes them, puts them side by side, crops them, zooms them or reads their pixels",cmd_image},
    {"agent",AGENT_USAGE,"Installs and manages the ACP adapters of the editor in the folder of the user; requires an explicit action",cmd_agent},
    {"shaders",SHADERS_USAGE,"Generates SPIR-V, MSL and Odin tables from Slang",cmd_shaders},
    {"setup",SETUP_USAGE,"Installs Slang or ripgrep pinned in .deps, adds mirai and ripgrep to the PATH, or sets the git of a clone to merge and diff its assets through mirai",cmd_setup},
    {"session",SESSION_USAGE,"Opens a headless editor of the project in the background for rpc, capture and mcp, or closes it",cmd_session},
    {"capture",CAPTURE_USAGE,"Captures the world of the project without the editor UI, with its validation errors and image statistics",cmd_capture},
    {"record",RECORD_USAGE,"Records the game of the project frame after frame at a fixed rate as 16-bit PNG or EXR images and a WAV, with a contact sheet and a manifest of its frames and its validation errors",cmd_record},
    {"render",RENDER_USAGE,"Measures the fixed views of a project as the user sees them (cost per pass, stability, luminance, captures) against the base build",cmd_render},
    {"bench",BENCH_USAGE,"Measures the frame cost of a project against the base build in alternating pairs, alone among the checkouts, and writes the table for a report",cmd_bench},
    {"rpc",RPC_USAGE,"Calls a method of the editor of the project or of the given port, shows fields of the response or waits for a state; describe shows the params of the methods",cmd_rpc},
    {"docs",DOCS_USAGE,"Prints the game documentation of this engine: the index, a topic or one section of it",cmd_docs},
    {"mcp",MCP_USAGE,"MCP server over stdio that forwards to the editor of the project or of the given port; gives the editor tools and those of the plugins in --plugins",cmd_mcp},
    {"texts",TEXTS_USAGE,"Takes the translatable texts of the project's .ui files to a CSV to translate, and back, through the open editor",cmd_texts},
    {"ui",UI_USAGE,"Reads, writes and checks the interfaces of a project as the documents ui.inspect gives and ui.write takes, with no editor",cmd_ui},
    {"scene",SCENE_USAGE,"Reads, writes and checks the scenes of a project as the documents scene.inspect gives with root and scene.write takes, with no editor",cmd_scene},
    {"content",CONTENT_USAGE,"Runs the content tool of a project, which writes the assets it makes from code",cmd_content},
    {"import","import <file> --out <folder> [--max-texture N]","Imports a model, an image, a sound, a font, CSV texts or a prompts manifest as .mesh, .mat, .tex, .sound, .font, .strings and .prompts assets",cmd_import},
}

main :: proc() {
    root:=project.engine_root_find("")
    if root=="" {fmt.eprintfln("mirai: cannot find the root of the engine: a checkout (AGENTS.md and tools/mirai) or an installed engine (%s)",project.ENGINE_FILE);os.exit(2)}
    // The editor and the player it starts look for the engine there first.
    os.set_env("MIRAI_ROOT",root)
    platform_environment(root)
    if _,valid:=build.compiler_memory();!valid {
        value,_:=os.lookup_env(build.COMPILER_MEMORY_ENV,context.temp_allocator)
        fmt.eprintfln("mirai: %s is the memory in GiB each compiler process may use (0: no limit), not '%s'",build.COMPILER_MEMORY_ENV,value)
        os.exit(2)
    }
    if code,refreshed:=self_refresh(root);refreshed {os.exit(code)}
    args:=os.args[1:]
    if len(args)==0 || args[0]=="help" || args[0]=="--help" || args[0]=="-h" {usage();os.exit(len(args)==0?2:0)}
    if project.engine_installed(root) && !installed_runs(args) {
        fmt.eprintfln("mirai %s: needs a checkout of the engine, with its sources and its history; %s is an installed engine",args[0],root)
        os.exit(2)
    }
    os.exit(command_run(root,args))
}

// Whether an installed engine runs a command: not those that build the engine
// or its tool, package it, or measure against another build of it.
installed_runs :: proc(args:[]string) -> bool {
    switch args[0] {
    case "worktree","bench","render","package": return false
    case "build": return len(args)<2 || args[1]!="tools"
    }
    return true
}

usage :: proc() {
    fmt.eprintln("Usage: mirai <command> [arguments]")
    for command in COMMANDS {fmt.eprintfln("  %-52s %s",command.usage,command.summary)}
}

join :: proc(parts:..string) -> string {
    path,_:=filepath.join(parts,context.allocator)
    return path
}


// The compiler of cook/build: MIRAI_ODIN, the one pinned under .deps (also
// the one of the main checkout from a worktree), or odin in PATH.
odin_executable :: proc(root:string) -> string {
    if found,ok:=build.compiler_find(root,context.allocator);ok {return found}
    return "odin"
}

// Runs a child process with this process' streams and returns its exit code.
run :: proc(root:string,command:[]string) -> int {return run_with(root,command,os.stdout)}

// Runs the compiler like run, within what it may use (build.compiler_limits).
// What it says on stderr goes on to this process' stderr as it comes; when it
// stopped at the memory it may use, how to go on follows.
run_compiler :: proc(root:string,command:[]string,what:string) -> int {
    limits:=build.compiler_limits(root)
    memory:=limits.memory
    reader,writer,pipe_error:=os.pipe()
    if pipe_error!=nil {return run_with(root,command,os.stdout,limits)}
    process,error:=subprocess.start({working_dir=root,command=command,stdin=os.stdin,stdout=os.stdout,stderr=writer},limits)
    os.close(writer)
    defer os.close(reader)
    if error!=nil {fmt.eprintfln("mirai: could not run %s: %v",command[0],error);return 127}
    // The end of what came before, so that a message split between two reads is found.
    PATTERN :: build.COMPILER_OUT_OF_MEMORY
    window:[4096+len(PATTERN)]u8
    kept:=0
    out_of_memory,said:=false,false
    for {
        count,read_error:=os.read(reader,window[kept:])
        if count<=0 || read_error!=nil {break}
        said=true
        _,_=os.write(os.stderr,window[kept:kept+count])
        seen:=kept+count
        out_of_memory||=strings.contains(string(window[:seen]),PATTERN)
        kept=min(seen,len(PATTERN)-1)
        copy(window[:kept],window[seen-kept:seen])
    }
    state,wait_error:=os.process_wait(process)
    if wait_error!=nil {fmt.eprintfln("mirai: %s: %v",command[0],wait_error);return 127}
    if state.exit_code!=0 && out_of_memory {fmt.eprintln(out_of_memory_text(what))}
    if state.exit_code!=0 && !said && build.compiler_crashed(state.exit_code) && memory>0 {
        fmt.eprintfln("%s: the compiler crashed without a message (0x%X). With its limit of %.1f GiB it ends like this when it runs out of memory outside LLVM: if the build needs more, raise %s.",what,u32(state.exit_code),f64(memory)/(1<<30),build.COMPILER_MEMORY_ENV)
    }
    return state.exit_code
}

run_with :: proc(root:string,command:[]string,stdout:^os.File,limits:=subprocess.Limits{}) -> int {
    process,error:=subprocess.start({working_dir=root,command=command,stdin=os.stdin,stdout=stdout,stderr=os.stderr},limits)
    if error!=nil {fmt.eprintfln("mirai: could not run %s: %v",command[0],error);return 127}
    state,wait_error:=os.process_wait(process)
    if wait_error!=nil {fmt.eprintfln("mirai: %s: %v",command[0],wait_error);return 127}
    return state.exit_code
}

odin_command :: proc(root:string,verb,target:string,attributes:=true) -> [dynamic]string {
    command:=make([dynamic]string)
    append(&command,odin_executable(root),verb,target,fmt.aprintf("-collection:mirai=%s",root))
    if attributes {append(&command,fmt.aprintf("-custom-attribute:%s",build.CUSTOM_ATTRIBUTES))}
    if verb!="check" {platform_flags(root,&command)}
    if extra,found:=os.lookup_env("MIRAI_ODIN_FLAGS",context.allocator);found {
        for flag in strings.fields(extra) {append(&command,flag)}
    }
    return command
}

Build_Target :: struct {name,package_path,output:string}
BUILD_TARGETS :: [?]Build_Target{
    {"tools","tools/mirai","mirai"},
}

cmd_build :: proc(root:string,args:[]string) -> int {
    if len(args)==0 {fmt.eprintfln("Usage: mirai %s\n       mirai %s",BUILD_USAGE,BUILD_PROJECT_USAGE);return 2}
    if args[0]=="editor" || args[0]=="game" || args[0]=="server" {return cmd_build_project(root,args)}
    if args[0]=="engine" {return cmd_build_engine(root,args[1:])}
    if !positional(args[0]) {return argument_unknown("build",args[0])}
    debug:=false
    for arg in args[1:] {
        if arg!="--debug" {return argument_unknown("build",arg)}
        debug=true
    }
    for target in BUILD_TARGETS {
        if target.name!=args[0] {continue}
        if target.name!="tools" {
            if !ensure_runtime_dependencies(root) {return 1}
            ensure_sdl(root,join(root,"bin"))
        }
        if os.make_directory_all(join(root,"bin"))!=nil && !os.is_dir(join(root,"bin")) {return 1}
        // A failed build never replaces the previous executable.
        staging:=join(root,"bin",fmt.aprintf(".%s-build-%d%s",target.output,os.get_pid(),project.EXECUTABLE_SUFFIX))
        staged_sources:=fmt.aprintf("%s.sources.json",staging)
        final:=join(root,"bin",fmt.aprintf("%s%s",target.output,project.EXECUTABLE_SUFFIX))
        command:=tool_command(root,target.package_path,debug?"-debug":"-o:speed",staging,staged_sources)
        if code:=run_compiler(root,command[:],"mirai build tools");code!=0 {os.remove(staging);os.remove(staged_sources);return code}
        if !executable_publish(root,staging,final,staged_sources,build_sources_file(root,target.output)) {return 1}
        fmt.printfln("%s ready.",final)
        return 0
    }
    fmt.eprintfln("mirai: unknown target '%s'",args[0]);return 2
}

// What the compiler read to build an executable of bin/: what tells that it
// is older than its sources, and that it was built when it is no longer there.
// Named after the executable, so that Windows and WSL on one checkout keep theirs.
build_sources_file :: proc(root,output:string) -> string {
    return join(root,"bin",fmt.aprintf("%s%s.sources.json",output,project.EXECUTABLE_SUFFIX))
}

// Puts a built executable and the list of its sources in their place. One
// that is running cannot be replaced on Windows but can be renamed: it
// leaves under another name, removed by a later build.
executable_publish :: proc(root,staging,final,staged_sources,sources:string) -> bool {
    if !os.is_file(staging) {
        fmt.eprintfln("mirai: the compiler succeeded and %s is missing.",staging)
        when ODIN_OS==.Windows {fmt.eprintfln("mirai: an antivirus may have quarantined it; exclude %s from real-time scanning.",join(root,"bin"))}
        os.remove(staged_sources)
        return false
    }
    bin:=join(root,"bin")
    if entries,error:=os.read_all_directory_by_path(bin,context.allocator);error==nil {
        for entry in entries {
            if strings.has_prefix(entry.name,".retired-") {os.remove(entry.fullpath)}
        }
    }
    if os.rename(staging,final)!=nil {
        retired:=join(bin,fmt.aprintf(".retired-%d-%x%s",os.get_pid(),u64(time.to_unix_nanoseconds(time.now())),project.EXECUTABLE_SUFFIX))
        if os.rename(final,retired)!=nil || os.rename(staging,final)!=nil {
            fmt.eprintfln("mirai: could not replace %s",final)
            os.remove(staging);os.remove(staged_sources)
            return false
        }
    }
    os.remove(sources)
    os.rename(staged_sources,sources)
    return true
}

// Checks the types of a package with the collections plugins and project it
// reaches, like mirai test.
cmd_check :: proc(root:string,args:[]string) -> int {
    if len(args)==0 || strings.has_prefix(args[0],"-") {
        if owner:=project_of(project.path_absolute(".",context.temp_allocator));owner!="" && len(args)==0 {return check_project(root,owner)}
        fmt.eprintln("Usage: mirai check [<package> [-flag...]]; without a package, inside a project: its game, editor and plugins")
        return 2
    }
    if !engine_shaders(root,backends=target_backends(args[1:])) {return 1}
    folder:=package_folder(root,args[0])
    command:=odin_command(root,"check",folder!=""?folder:args[0])
    // A check is no test build: the tests that run generated shaders are asked for (rhi.TEST_SHADERS).
    append(&command,"-no-entry-point","-define:MIRAI_TEST_SHADERS=true","-ignore-unused-defineables")
    if folder!="" {
        collections,ok:=package_collections(root,folder,args[1:])
        if !ok {return 1}
        append(&command,..collections)
    }
    append(&command,..args[1:])
    code:=run(root,command[:])
    if code==0 && folder!="" && alloc_lint_applies(root,folder) && !alloc_lint_package(folder) {return 1}
    if code==0 && folder!="" && plugin_api_lint_applies(folder) && !plugin_api_lint_folder(folder) {return 1}
    if code==0 && folder!="" && solver_lint_applies(root,folder) && !solver_lint_package(folder) {return 1}
    return code
}

// The code of a project, as build.check checks it: the world generated from
// it, with its game, editor and plugins.
@(private="file")
check_project :: proc(root,folder:string) -> int {
    opened,error:=project.open(folder,root,context.temp_allocator)
    if error.code!=.None {fmt.eprintfln("mirai check: could not open the project %s",folder);return 1}
    clean:=plugin_api_lint_project(&opened)
    job:=build.job_run({project=&opened,target=.Editor,action=.Check})
    defer build.job_destroy(job)
    for d in job.result.diagnostics {fmt.eprintfln("%s(%d:%d) %v: %s",d.file,d.line,d.column,d.severity,d.message)}
    if job.result.status==.Built {
        game:=join(folder,project.FOLDER_NAMES[.Game])
        if !solver_lint_package(game) {return 1}
        return 1 if alloc_lint_applies(root,game) && !alloc_lint_package(game) || !clean else 0
    }
    if len(job.result.diagnostics)==0 {fmt.eprintln(job.result.text)}
    return 1
}

cmd_deps :: proc(root:string,args:[]string) -> int {
    if len(args)>0 {return argument_unknown("deps",args[0])}
    return ensure_runtime_dependencies(root)?0:1
}
