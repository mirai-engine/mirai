package build

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:cook/shaders"
import "mirai:project"
import "mirai:std/base"

// The shader generation of a project: the shaders of the engine compiled
// with the Slang programs under <project>/shaders and under the shaders/ of
// each active plugin that declares them. It is published in
// project.shader_generation(root), where the runtime and the editor load it
// and see it change; its cache is <project>/.mirai/shader-cache. A project
// without programs of its own has no generation and runs the shaders the
// executable embeds.

Shaders_Status :: enum u8 {
    Running,
    None,       // neither the project nor its active plugins have Slang programs; a generation left by an earlier build was removed
    Up_To_Date, // the published generation is what these sources give
    Built,      // another generation was published
    Failed,     // message says why; what was published stands
    Cancelled,  // shaders_cancel stopped it; what was published stands
}

// Everything it points to belongs to the job.
Shaders_Result :: struct {
    status:Shaders_Status,
    output:string,       // folder of the generation
    programs:int,        // material programs of its catalog, with those of the engine
    compiled,reused:int, // stages run through the compilers, and taken from an earlier build
    seconds:f64,
    message:string,      // Failed: the tool that is missing or what a compiler answered. Otherwise the warnings
    refused:string,      // the programs left out of the generation and why, one a line
    diagnostics:[]shaders.Diagnostic, // Failed: what the compiler said of the stage that failed, by its sources
}

Shaders_Job :: struct {
    result:Shaders_Result,
    allocator:runtime.Allocator,
    arena:virtual.Arena,
    options:shaders.Options,
    worker:^thread.Thread,
    done:bool, // atomic
    tick:time.Tick,
    progress:shaders.Progress,
    first:string, // folder the first stages are written to; "" without them
    active:string, // folder every stage but the idle ones is written to; "" without idle stages
}

// The folders the programs of a project come from besides its own shaders/:
// the shaders/ of each active plugin that declares the part, in the order of
// p.active. own tells whether the project has Slang sources itself.
shader_sources :: proc(p:^project.Project,allocator:=context.allocator) -> (sources:[]shaders.Source,own:bool) {
    has_slang :: proc(folder:string) -> bool {
        if !os.is_dir(folder) {return false}
        w:=os.walker_create(folder)
        defer os.walker_destroy(&w)
        for info in os.walker_walk(&w) {
            if info.type==.Regular && strings.has_suffix(info.name,".slang") {return true}
        }
        return false
    }
    own=has_slang(project.folder_path(p.root,.Shaders,context.temp_allocator))
    parts:=project.PART_NAMES
    list:=make([dynamic]shaders.Source,allocator)
    for index in p.active {
        plugin:=&p.plugins[index]
        if .Shaders not_in plugin.manifest.parts {continue}
        folder:=project.path(plugin.folder,parts[.Shaders],allocator=context.temp_allocator)
        if !has_slang(folder) {continue}
        append(&list,shaders.Source{strings.clone(base.text_get(plugin.manifest.name[:]),allocator),strings.clone(folder,allocator)})
    }
    return list[:],own
}

// Starts the generation of the shaders of a project on a thread of its own
// and returns at once: shaders_poll says when it is over. The project is
// only read here. first: stages compiled before the others (by their names
// in the manifest); once they are, shaders_first names a generation that
// loads alone with them. idle: stages compiled after the others; once every
// other one is, shaders_active names a generation that loads alone with
// them. overlay: sources read from memory instead of their files (what an
// editor holds unsaved), copied here.
shaders_start :: proc(p:^project.Project,first:[]string={},overlay:[]shaders.Overlay={},idle:[]string={},allocator:=context.allocator) -> ^Shaders_Job {
    job:=new(Shaders_Job,allocator)
    job.allocator=allocator
    _=virtual.arena_init_growing(&job.arena)
    a:=virtual.arena_allocator(&job.arena)
    job.tick=time.tick_now()
    job.result.status=.Running
    job.result.output=project.shader_generation(p.root,a)
    finish :: proc(job:^Shaders_Job,status:Shaders_Status,message:string) -> ^Shaders_Job {
        job.result.status,job.result.message=status,message
        job.result.seconds=time.duration_seconds(time.tick_since(job.tick))
        sync.atomic_store(&job.done,true)
        return job
    }
    sources,own:=shader_sources(p,a)
    // A program the editor made and did not save yet is of the project too.
    folder:=strings.concatenate({project.folder_path(p.root,.Shaders,context.temp_allocator),"/"},context.temp_allocator)
    for entry in overlay {own||=!entry.removed && strings.has_suffix(entry.path,".slang") && strings.has_prefix(entry.path,folder)}
    if !own && len(sources)==0 {
        if os.is_file(project.path(job.result.output,project.SHADERS_MANIFEST,allocator=context.temp_allocator)) {
            if base.remove_all(job.result.output)!=nil {return finish(job,.Failed,"the generation of an earlier build could not be removed")}
        }
        return finish(job,.None,"")
    }
    if p.engine_root=="" {return finish(job,.Failed,"the root of the engine is not known")}
    job.options={
        root=strings.clone(p.engine_root,a),project=strings.clone(p.root,a),sources=sources,output=job.result.output,
        progress=&job.progress,overlay=make([]shaders.Overlay,len(overlay),a),
    }
    for entry,i in overlay {job.options.overlay[i]={strings.clone(entry.path,a),slice.clone(entry.data,a),entry.removed}}
    if len(first)>0 {
        folder,error:=os.make_directory_temp("","mirai-shaders-first-*",a)
        if error!=nil {return finish(job,.Failed,"the folder of the first stages could not be made")}
        job.first=folder
        job.options.first=slice.clone(first,a)
        for &name in job.options.first {name=strings.clone(name,a)}
        job.options.first_output=folder
    }
    if len(idle)>0 {
        folder,error:=os.make_directory_temp("","mirai-shaders-active-*",a)
        if error!=nil {return finish(job,.Failed,"the folder of the stages in use could not be made")}
        job.active=folder
        job.options.idle=slice.clone(idle,a)
        for &name in job.options.idle {name=strings.clone(name,a)}
        job.options.active_output=folder
    }
    job.worker=thread.create_and_start_with_poly_data(job,shaders_work)
    if job.worker==nil {return finish(job,.Failed,"the thread of the generation could not be started")}
    return job
}

// Whether shaders_start would leave the generation of the project as it is,
// without compiling, taking a turn or writing anything.
shaders_current :: proc(p:^project.Project) -> bool {
    sources,own:=shader_sources(p,context.temp_allocator)
    output:=project.shader_generation(p.root,context.temp_allocator)
    if !own && len(sources)==0 {return !os.is_file(project.path(output,project.SHADERS_MANIFEST,allocator=context.temp_allocator))}
    return p.engine_root!="" && shaders.current({root=p.engine_root,project=p.root,sources=sources,output=output})
}

@(private)
shaders_work :: proc(job:^Shaders_Job) {
    a:=virtual.arena_allocator(&job.arena)
    result:=shaders.generate(job.options,a)
    r:=&job.result
    r.programs,r.compiled,r.reused=result.programs,result.compiled,result.reused
    if result.cancelled {
        r.status,r.message=.Cancelled,result.error
    } else if result.error!="" {
        r.status,r.message,r.diagnostics=.Failed,result.error,result.diagnostics
    } else {
        r.status=result.changed?.Built:.Up_To_Date
        r.message=strings.trim_space(result.warnings)
        r.refused=result.refused
    }
    r.seconds=time.duration_seconds(time.tick_since(job.tick))
    sync.atomic_store(&job.done,true)
}

// The folder of the generation of the first stages once they compiled, while
// the job lasts: the catalog and those stages of this generation, the others
// as the output has them. "" before, and for a job without first stages.
shaders_first :: proc(job:^Shaders_Job) -> string {
    if job.first=="" || !sync.atomic_load(&job.progress.first) {return ""}
    return job.first
}

// The folder of the generation of every stage but the idle ones once they
// compiled, while the job lasts: the catalog and those stages of this
// generation, the idle ones as the output has them. "" before, and for a job
// without idle stages.
shaders_active :: proc(job:^Shaders_Job) -> string {
    if job.active=="" || !sync.atomic_load(&job.progress.active) {return ""}
    return job.active
}

// Stops a job that runs: no stage starts any more, the compilers that run are
// killed and it ends Cancelled. Does not block.
shaders_cancel :: proc(job:^Shaders_Job) {
    shaders.cancel(&job.progress)
}

// True once the job is over: job.result has how. Does not block.
shaders_poll :: proc(job:^Shaders_Job) -> bool {
    if !sync.atomic_load(&job.done) {return false}
    shaders_join(job)
    return true
}

// Blocks until the job is over.
shaders_wait :: proc(job:^Shaders_Job) -> ^Shaders_Result {
    shaders_join(job)
    return &job.result
}

@(private)
shaders_join :: proc(job:^Shaders_Job) {
    if job.worker==nil {return}
    thread.join(job.worker)
    thread.destroy(job.worker)
    job.worker=nil
}

// The whole generation, waiting for it.
shaders_run :: proc(p:^project.Project,allocator:=context.allocator) -> ^Shaders_Job {
    job:=shaders_start(p,allocator=allocator)
    shaders_wait(job)
    return job
}

// Waits for a generation that is running: the compilers are not interrupted.
shaders_destroy :: proc(job:^Shaders_Job) {
    if job==nil {return}
    shaders_join(job)
    if job.first!="" {_=base.remove_all(job.first)}
    if job.active!="" {_=base.remove_all(job.active)}
    virtual.arena_destroy(&job.arena)
    free(job,job.allocator)
}

// What a shipped game carries of the generation of the project: its manifest,
// its catalog and the code of this system. Nothing without a generation.
@(private)
shaders_copies :: proc(copies:^[dynamic]Copy,root,folder:string,a:runtime.Allocator) {
    built:=project.shader_generation(root,context.temp_allocator)
    if !os.is_file(project.path(built,project.SHADERS_MANIFEST,allocator=context.temp_allocator)) {return}
    entries,error:=os.read_all_directory_by_path(built,context.temp_allocator)
    if error!=nil {return}
    CODE :: ".metal" when ODIN_OS==.Darwin else ".spv"
    for entry in entries {
        if entry.type!=.Regular {continue}
        if entry.name!=project.SHADERS_MANIFEST && entry.name!="catalog.json" && !strings.has_suffix(entry.name,CODE) {continue}
        append(copies,Copy{project.path(built,entry.name,allocator=a),project.path(folder,project.SHADERS_SHIPPED,entry.name,allocator=a),false})
    }
}
