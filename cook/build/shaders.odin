package build

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:asset"
import "mirai:cook/shaders"
import "mirai:project"
import "mirai:render/abi"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

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
    features:abi.Render_Features, // what the assets of the project draw of the optional features of the renderer (program_uses)
}

Shaders_Job :: struct {
    result:Shaders_Result,
    allocator:runtime.Allocator,
    arena:virtual.Arena,
    options:shaders.Options,
    store_root:string,
    package_roots:[]string,
    own:bool,
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
// them.
shaders_start :: proc(
    p:^project.Project,first:[]string={},idle:[]string={},previews:[]string={},
    allocator:=context.allocator,store_root:="",
) -> ^Shaders_Job {
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
    job.package_roots=shaders_package_roots(p,a)
    job.own=own
    uses,features,problem:=shaders_uses(p,previews,a)
    if problem!="" {return finish(job,.Failed,problem)}
    job.result.features=features
    if !own && len(sources)==0 && len(job.package_roots)==0 && !shaders_have_generated(uses) {
        if os.is_file(project.path(job.result.output,project.SHADERS_MANIFEST,allocator=context.temp_allocator)) {
            if base.remove_all(job.result.output)!=nil {return finish(job,.Failed,"the generation of an earlier build could not be removed")}
        }
        return finish(job,.None,"")
    }
    if p.engine_root=="" {return finish(job,.Failed,"the root of the engine is not known")}
    job.store_root=strings.clone(store_root,a)
    job.options={
        root=strings.clone(p.engine_root,a),project=strings.clone(p.root,a),sources=sources,output=job.result.output,
        progress=&job.progress,uses=uses,
    }
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
shaders_current :: proc(p:^project.Project,previews:[]string={},store_root:="") -> bool {
    sources,own:=shader_sources(p,context.temp_allocator)
    output:=project.shader_generation(p.root,context.temp_allocator)
    uses,_,problem:=shaders_uses(p,previews,context.temp_allocator)
    if problem!="" {return false}
    roots:=shaders_package_roots(p,context.temp_allocator)
    generated,reason:=shaders_generated(uses,store_root,roots,context.temp_allocator)
    if reason!="" {return false}
    if !own && len(sources)==0 && len(generated)==0 {
        return !os.is_file(project.path(output,project.SHADERS_MANIFEST,allocator=context.temp_allocator))
    }
    return p.engine_root!="" && shaders.current({
        root=p.engine_root,project=p.root,sources=sources,output=output,uses=uses,
        generated=generated,
    })
}

@(private="file")
shaders_have_generated :: proc(uses:[]shaders.Program_Uses_Of) -> bool {
    for use in uses {
        if strings.has_prefix(use.program,asset.GENERATED_PROGRAM_PREFIX) {return true}
    }
    return false
}

shaders_package_roots :: proc(p:^project.Project,allocator:=context.allocator) -> []string {
    roots:=make([dynamic]string,allocator)
    for folder in project.asset_folders(p,context.temp_allocator) {
        pins:=project.path(folder.root,asset.PACKAGES_FILE,allocator=context.temp_allocator)
        if !os.is_file(pins) || slice.contains(roots[:],folder.root) {continue}
        append(&roots,strings.clone(folder.root,allocator))
    }
    return roots[:]
}

shaders_generated :: proc(
    uses:[]shaders.Program_Uses_Of,store_root:string,package_roots:[]string,
    allocator:=context.allocator,
) -> (generated:[]shaders.Generated_Program,problem:string) {
    if len(package_roots)==0 && !shaders_have_generated(uses) {return}
    s,open_error:=store.open(store_root if store_root!="" else
        store.default_root(context.temp_allocator),context.temp_allocator)
    if open_error!=.None {
        return nil,fmt.aprintf("the shader source store could not be opened (%v)",
            open_error,allocator=allocator)
    }
    defer store.close(&s)
    index:=store.read_index(&s,refresh=false)
    wanted:=make(map[store.Hash]bool,context.temp_allocator)
    for use in uses {
        if !strings.has_prefix(use.program,asset.GENERATED_PROGRAM_PREFIX) {continue}
        address,ok:=asset.generated_program_address(use.program)
        if !ok {
            return nil,fmt.aprintf("invalid generated program id %s: import its source again",
                use.program,allocator=allocator)
        }
        wanted[address]=true
    }
    for root in package_roots {
        pins,_,pins_error:=asset.packages_load(root,context.temp_allocator)
        if pins_error!=.None {
            return nil,fmt.aprintf("could not read the package pins of %s (%v)",
                root,pins_error,allocator=allocator)
        }
        for &pin in pins.packages {
            p,manifest_error:=asset.package_load(&index,root,&pin,context.temp_allocator)
            if manifest_error!=.None {continue}
            digits:[64]u8
            key:=store.hex(asset.build_select(pin.manifest,&p),&digits)
            built,ref_error:=store.ref_get(&index,asset.REF_BUILDS,key)
            if ref_error!=.None {continue}
            b,build_error:=asset.build_get(&index,built,context.temp_allocator)
            if build_error!=.None || b.package_id!=pin.id {continue}
            for address in b.programs {wanted[address]=true}
        }
    }
    found:=make([dynamic]shaders.Generated_Program,0,len(wanted),allocator)
    for address in wanted {
        id:=asset.generated_program_id(address,allocator)
        source,read_error:=asset.record_get(&index,address)
        if read_error!=.None {
            return nil,fmt.aprintf("generated program %s is unavailable (%v): fetch or rebuild its package",
                id,read_error,allocator=allocator)
        }
        append(&found,shaders.Generated_Program{id=id,text=strings.clone(source,allocator)})
    }
    slice.sort_by(found[:],proc(a,b:shaders.Generated_Program) -> bool {return a.id<b.id})
    return found[:],""
}

// What the generation of a project compiles its Surface programs for: what
// its assets draw them as (program_uses) and, for the programs named, the
// previews of the editor, which compiles them when it first shows one.
// features: what the assets draw of the optional features of the renderer.
shaders_uses :: proc(p:^project.Project,previews:[]string,allocator:=context.allocator) -> (uses:[]shaders.Program_Uses_Of,features:abi.Render_Features,problem:string) {
    drawn:[]shaders.Program_Uses_Of
    if drawn,features,problem=program_uses(p,context.temp_allocator);problem!="" {return nil,{},strings.clone(problem,allocator)}
    list:=make([dynamic]shaders.Program_Uses_Of,0,len(drawn)+len(previews),allocator)
    for each in drawn {append(&list,shaders.Program_Uses_Of{strings.clone(each.program,allocator),each.uses})}
    outer: for name in previews {
        for &each in list {if each.program==name {each.uses+={.Preview};continue outer}}
        append(&list,shaders.Program_Uses_Of{strings.clone(name,allocator),{.Preview}})
    }
    slice.sort_by(list[:],proc(a,b:shaders.Program_Uses_Of) -> bool {return a.program<b.program})
    return list[:],features,""
}

@(private)
shaders_work :: proc(job:^Shaders_Job) {
    a:=virtual.arena_allocator(&job.arena)
    r:=&job.result
    defer sync.atomic_store(&job.done,true)
    defer r.seconds=time.duration_seconds(time.tick_since(job.tick))
    generated,problem:=shaders_generated(job.options.uses,job.store_root,job.package_roots,a)
    if problem!="" {
        r.status,r.message=.Failed,problem
        return
    }
    if !job.own && len(job.options.sources)==0 && len(generated)==0 {
        r.status=.None
        manifest:=project.path(r.output,project.SHADERS_MANIFEST,allocator=context.temp_allocator)
        if os.is_file(manifest) && base.remove_all(r.output)!=nil {
            r.status,r.message=.Failed,"the generation of an earlier build could not be removed"
        }
        return
    }
    job.options.generated=generated
    result:=shaders.generate(job.options,a)
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
shaders_run :: proc(p:^project.Project,allocator:=context.allocator,store_root:="") -> ^Shaders_Job {
    job:=shaders_start(p,allocator=allocator,store_root=store_root)
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

// What a shipped game carries of the generation of the project: its catalog,
// the code of this system and its manifest, which it returns to write beside
// them. Neither the code of the stages only the tools of an editor run
// (abi.TOOL_STAGES), whose entries the manifest keeps without it, nor what
// they were compiled for each Surface program as, which it leaves out.
// Nothing without a generation, or with one whose manifest does not read.
@(private)
shaders_copies :: proc(copies:^[dynamic]Copy,root,folder:string,a:runtime.Allocator) -> (manifest:[]u8) {
    built:=project.shader_generation(root,context.temp_allocator)
    text,read_error:=os.read_entire_file(project.path(built,abi.SHADER_MANIFEST,allocator=context.temp_allocator),context.temp_allocator)
    m:abi.Shader_Manifest
    if read_error!=nil || serial.text_decode(string(text),&m,context.temp_allocator)!="" {return nil}
    catalog:abi.Shader_Catalog
    if text,error:=os.read_entire_file(project.path(built,abi.SHADER_CATALOG,allocator=context.temp_allocator),context.temp_allocator);error==nil {
        _=serial.text_decode(string(text),&catalog,context.temp_allocator,skip_unknown=true)
    }
    // A stage of a program is <stem>__<program>[_<variant>] of <stem>[_<variant>] (render.program_stage).
    tools:=make(map[string]bool,context.temp_allocator)
    for stage in abi.TOOL_STAGES {
        tools[stage]=true
        dot:=strings.index_byte(stage,'.')
        name,suffix:=stage[:dot],stage[dot:]
        for cut:=len(name);cut>0;cut-=1 {
            if cut<len(name) && name[cut]!='_' {continue}
            for program in catalog.programs {
                if program.domain==.Surface {tools[fmt.tprintf("%s__%s%s%s",name[:cut],program.name,name[cut:],suffix)]=true}
            }
        }
    }
    ship :: proc(copies:^[dynamic]Copy,built,folder:string,entry:abi.Shader_Entry,a:runtime.Allocator) {
        file:=entry.msl if ODIN_OS==.Darwin else entry.spv
        if file=="" {return}
        append(copies,Copy{from=project.path(built,file,allocator=a),to=project.path(folder,project.SHADERS_SHIPPED,file,allocator=a)})
    }
    for &entry in m.shaders {
        if tools[entry.name] {entry.spv,entry.msl,entry.entry="","",""} else {ship(copies,built,folder,entry,a)}
    }
    kept:=make([dynamic]abi.Shader_Entry,0,len(m.program_stages),context.temp_allocator)
    for entry in m.program_stages {
        if tools[entry.name] {continue}
        append(&kept,entry)
        ship(copies,built,folder,entry,a)
    }
    m.program_stages=kept[:]
    for entry in m.extensions {ship(copies,built,folder,entry,a)}
    m.tests=nil
    append(copies,Copy{from=project.path(built,abi.SHADER_CATALOG,allocator=a),to=project.path(folder,project.SHADERS_SHIPPED,abi.SHADER_CATALOG,allocator=a)})
    manifest,_=serial.text_encode(m,.Pretty,a)
    return
}
