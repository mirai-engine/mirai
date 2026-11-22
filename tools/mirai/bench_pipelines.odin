package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

BENCH_PIPELINES_USAGE :: "bench pipelines [project] [--scene S] [--frames N] [--release] [--out file]"

// mirai bench pipelines: what compiling the GPU pipelines costs a start of the
// game, the first after an install or an update against the next. It plays
// the project twice with a window, a cold start and a warm one, and writes the
// table of each: the start, the pipelines the driver compiled and what the
// frames lost to them. Both runs use a temporary application cache and direct
// drivers that support a cache location to a temporary folder.

BENCH_PIPELINES_FRAMES :: 300
// The variables that point each driver's cache of compiled shaders at a folder.
BENCH_PIPELINES_DRIVER_PATHS :: [?]string{"AMD_VK_PIPELINE_CACHE_PATH","__GL_SHADER_DISK_CACHE_PATH","MESA_SHADER_CACHE_DIR"}

Bench_Pipelines_Options :: struct {
    folder,scene,out:string,
    frames:int,
    mode:Build_Mode,
}

// What one start of the player says about its pipelines (host/player.odin,
// host/load_profile.odin); found: the summary line was there.
Bench_Pipelines_Run :: struct {
    startup_ms,resident_ms:f64,
    made,kept,late:int,
    driver_ms,longest_ms:f64,
    store:string,
    found:bool,
}

@(private)
bench_pipelines_options :: proc(args:[]string) -> (o:Bench_Pipelines_Options,error:string) {
    o={folder=".",frames=BENCH_PIPELINES_FRAMES}
    mode,rest:=build_mode_take(args)
    o.mode=mode
    named:=false
    for i:=0;i<len(rest);i+=1 {
        if positional(rest[i]) {
            if named {return o,fmt.tprintf("'%s' is one too many: it measures a single project",rest[i])}
            o.folder,named=rest[i],true
            continue
        }
        switch rest[i] {
        case "--scene","--frames","--out":
        case: return o,fmt.tprintf("there is no option %s",rest[i])
        }
        if i+1>=len(rest) || rest[i+1]=="" {return o,fmt.tprintf("%s needs a value",rest[i])}
        option,value:=rest[i],rest[i+1]
        i+=1
        switch option {
        case "--scene": o.scene=value
        case "--out":   o.out=value
        case "--frames":
            number,ok:=strconv.parse_int(value,10)
            if !ok || number<30 || number>36000 {return o,fmt.tprintf("--frames goes from 30 to 36000, not '%s'",value)}
            o.frames=number
        }
    }
    return o,""
}

// The value in line between after and before, as a number; ok false when
// either is missing or it is no number.
@(private="file")
bench_pipelines_between :: proc(line,after,before:string) -> (value:f64,ok:bool) {
    start:=0
    if after!="" {
        at:=strings.index(line,after)
        if at<0 {return 0,false}
        start=at+len(after)
    }
    end:=strings.index(line[start:],before)
    if end<0 {return 0,false}
    text:=strings.trim_space(line[start:][:end])
    if space:=strings.last_index_byte(text,' ');space>=0 {text=text[space+1:]}
    return strconv.parse_f64(text)
}

// Reads what the player printed (stdout and stderr) into a run.
bench_pipelines_parse :: proc(output:string) -> (run:Bench_Pipelines_Run) {
    for line in strings.split_lines(output,context.temp_allocator) {
        switch {
        case strings.has_prefix(line,"mirai: load Scene "):
            run.resident_ms,_=bench_pipelines_between(line,"resident at "," ms")
        case strings.has_prefix(line,"  phases: ") && strings.contains(line," Startup "):
            // The phases go the costliest first: Startup is anywhere in the line.
            run.startup_ms,_=bench_pipelines_between(line," Startup "," ms")
        case strings.has_prefix(line,"  pipelines: ") && strings.contains(line," made ("):
            made,_:=bench_pipelines_between(line,"pipelines: "," made")
            kept,_:=bench_pipelines_between(line,"(", " kept)")
            late,_:=bench_pipelines_between(line,"; "," frames late")
            run.made,run.kept,run.late=int(made),int(kept),int(late)
            run.driver_ms,_=bench_pipelines_between(line,"kept), "," ms in the driver")
            run.longest_ms,_=bench_pipelines_between(line,"longest "," ms")
            if at:=strings.index(line,"store ");at>=0 {
                rest:=line[at+len("store "):]
                if end:=strings.index_byte(rest,';');end>=0 {run.store=strings.clone(rest[:end],context.temp_allocator)}
            }
            run.found=true
        }
    }
    return
}

// Why a cold run may not have been cold; "" when both caches were empty.
bench_pipelines_cold_doubt :: proc(cold:Bench_Pipelines_Run,driver_wrote:bool) -> string {
    switch {
    case !cold.found:          return "the player did not print its pipelines: nothing to say of the run"
    case cold.store=="None":   return "the backend exposes no application cache and its driver cache could not be verified"
    case cold.store!="Missing": return fmt.tprintf("the temporary application cache reported %s",cold.store)
    case !driver_wrote:        return "the driver wrote nothing in the folder its variables named: it kept its own cache, which may have served this run, and its times are a floor"
    }
    return ""
}

@(private)
bench_pipelines :: proc(root:string,args:[]string) -> int {
    o,error:=bench_pipelines_options(args)
    if error!="" {fmt.eprintfln("mirai bench: %s\nUsage: mirai %s",error,BENCH_PIPELINES_USAGE);return 2}
    if !os.is_file(project.path(o.folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai bench: %s is not a project (%s is missing); pass the folder of the project",o.folder,project.PROJECT_FILE)
        return 2
    }
    folder:=project.path_absolute(o.folder,context.temp_allocator)
    if code,_,_:=build_project(root,.Editor,{o.folder},o.mode);code!=0 {return code}
    temporary,temp_error:=os.make_directory_temp("","mirai-bench-pipelines-*",context.temp_allocator)
    if temp_error!=nil {fmt.eprintfln("mirai bench: could not create a cache directory: %v",temp_error);return 1}
    defer base.remove_all(temporary)
    cache,cache_error:=filepath.join({temporary,project.PIPELINES_FILE},context.temp_allocator)
    driver,driver_error:=filepath.join({temporary,"driver"},context.temp_allocator)
    if cache_error!=nil || driver_error!=nil || os.make_directory(driver)!=nil {
        fmt.eprintln("mirai bench: could not prepare the temporary cache paths")
        return 1
    }
    measure_env_set()
    for name in BENCH_PIPELINES_DRIVER_PATHS {os.set_env(name,driver)}
    os.set_env(project.PIPELINES_PATH_ENV,cache)
    os.set_env("AMD_VK_PIPELINE_CACHE_FILENAME","mirai-bench")
    os.set_env("__GL_SHADER_DISK_CACHE_SKIP_CLEANUP","1")
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,project_engine_paths(root,o.folder,o.mode).player_program,"--project",folder,"--frames",fmt.tprint(o.frames),"--show-window")
    if o.scene!="" {append(&command,"--scene",o.scene)}

    runs:[2]Bench_Pipelines_Run
    names:=[2]string{"cold","warm"}
    driver_wrote:=false
    measurement:=measure_lock(root,"bench pipelines")
    defer workspace.lock_release(&measurement)
    measure_load_say("bench pipelines","at the start")
    for &run,i in runs {
        fmt.printfln("mirai bench: %s start of %s (%d frames)…",names[i],o.folder,o.frames)
        state,stdout,stderr,run_error:=subprocess.exec({command=command[:],working_dir=root},context.temp_allocator)
        if run_error!=nil || state.exit_code!=0 {
            fmt.eprintfln("mirai bench: the %s start failed (exit %d %v):\n%s",names[i],state.exit_code,run_error,string(stderr))
            return 1
        }
        run=bench_pipelines_parse(strings.concatenate({string(stdout),"\n",string(stderr)},context.temp_allocator))
        if !run.found {
            fmt.eprintfln("mirai bench: the %s start ended without pipeline statistics",names[i])
            return 1
        }
        if i==0 {
            if entries,read_error:=os.read_all_directory_by_path(driver,context.temp_allocator);read_error==nil {driver_wrote=len(entries)>0}
        }
    }
    table:=bench_pipelines_table(o,runs,bench_pipelines_cold_doubt(runs[0],driver_wrote))
    fmt.print(table)
    if o.out!="" && os.write_entire_file(o.out,transmute([]u8)table)!=nil {
        fmt.eprintfln("mirai bench: could not write %s",o.out)
        return 1
    }
    return 0
}

// The table of the two starts, in Markdown, with what to doubt.
bench_pipelines_table :: proc(o:Bench_Pipelines_Options,runs:[2]Bench_Pipelines_Run,doubt:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    scene:=o.scene if o.scene!="" else "the start scene"
    fmt.sbprintfln(&b,"Pipelines of %s, %s, %d frames:\n",o.folder,scene,o.frames)
    fmt.sbprintln(&b,"| | Cold | Warm |")
    fmt.sbprintln(&b,"| --- | ---: | ---: |")
    cold,warm:=runs[0],runs[1]
    fmt.sbprintfln(&b,"| Player startup, ms | %.0f | %.0f |",cold.startup_ms,warm.startup_ms)
    fmt.sbprintfln(&b,"| Resident, ms after the load began | %.0f | %.0f |",cold.resident_ms,warm.resident_ms)
    fmt.sbprintfln(&b,"| Pipelines made | %d | %d |",cold.made,warm.made)
    fmt.sbprintfln(&b,"| Without a confirmed application cache hit | %d | %d |",cold.made-cold.kept,warm.made-warm.kept)
    fmt.sbprintfln(&b,"| Driver time, ms summed | %.0f | %.0f |",cold.driver_ms,warm.driver_ms)
    fmt.sbprintfln(&b,"| Longest pipeline, ms | %.1f | %.1f |",cold.longest_ms,warm.longest_ms)
    fmt.sbprintfln(&b,"| Frames late (materials as rows) | %d | %d |",cold.late,warm.late)
    fmt.sbprintfln(&b,"| Kept pipelines found | %s | %s |",cold.store,warm.store)
    if doubt!="" {fmt.sbprintfln(&b,"\nThe cold start may not have been cold: %s.",doubt)}
    return strings.to_string(b)
}
