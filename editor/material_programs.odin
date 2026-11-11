package editor

import "core:log"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:cook/shaders"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"

// The material programs of the project are published again when a source of
// theirs changes through the editor (an API edit, an undo, a discard): the
// shaders of the project are generated on a job, without stopping the editor,
// from the files of their sources. The stages the previews draw with go first: once they
// compile, the renderer takes them with the new catalog and the other stages
// as they were, and a preview shows the program. The stages the frames run
// go next: once they compile, the renderer takes them with the idle ones as
// they were (gpu.renderer_shaders_idle), and the viewport shows it. The whole
// generation replaces them when it is done. A change while a job runs cancels
// it and starts another.

Programs_Publication :: struct {
    job:^build.Shaders_Job,
    project:^project.Project, // open while the job runs
    again:bool,               // a source changed while it ran: it was cancelled and another starts
    first:bool,               // the first stages of the job were asked of the renderer
    active:bool,              // the stages the frames run were
    running:u64,              // the load of those stages; 0 while there is none
    mixed:bool,               // the renderer took first stages of a generation that was not published whole
    preview:u64,              // the load of the shaders the previews wait for; 0 while there is none
    whole:u64,                // the load of the generation the last job published
    refused:bool,             // the renderer refused a generation of this publication at once
    serial:u64,               // publications that ended, published or not
    failed:bool,              // the last one failed: message says why
    message:string,
}

// Asks for a publication of the programs of the project.
programs_publish_request :: proc(s:^Session) {
    p:=&s.build.programs
    if p.job!=nil {
        p.again=true
        build.shaders_cancel(p.job)
        return
    }
    programs_start(s)
}

// Whether a publication runs or waits to run, until the renderer has all of it.
programs_publishing :: proc(s:^Session) -> bool {
    p:=&s.build.programs
    return p.job!=nil || p.again || (s.app.renderer!=nil && host.app_shaders_loading(s.app,p.whole))
}

// Whether the previews still wait for the shaders of the last change.
@(private)
programs_previewing :: proc(s:^Session) -> bool {
    p:=&s.build.programs
    if p.again || (p.job!=nil && p.preview==0) {return true}
    return s.app.renderer!=nil && host.app_shaders_loading(s.app,p.preview)
}

// Whether the viewport still waits for the shaders of the last change: the
// stages the frames run, or the whole generation, or the pipelines of the
// programs those frames asked for.
@(private)
programs_drawing :: proc(s:^Session) -> bool {
    p:=&s.build.programs
    if p.again || (p.job!=nil && p.running==0) {return true}
    if s.app.renderer==nil {return false}
    return host.app_shaders_loading(s.app,p.running!=0?p.running:p.whole) || gpu.renderer_pipelines_pending(s.app.renderer)
}

@(private)
programs_start :: proc(s:^Session) {
    p:=&s.build.programs
    // What the renderer still makes of the last generation would compete for
    // the driver with the next one.
    if s.app.renderer!=nil {
        host.app_shaders_drop(s.app,p.preview)
        host.app_shaders_drop(s.app,p.running)
        host.app_shaders_drop(s.app,p.whole)
    }
    p.again,p.first,p.active,p.preview,p.running,p.failed,p.refused=false,false,false,0,0,false,false
    if !s.has_project || s.engine_root=="" {return}
    opened,error:=project.open(s.project_root,s.engine_root)
    if error.code!=.None {
        programs_finish(s,true,"The project could not be opened")
        return
    }
    p.project=new(project.Project)
    p.project^=opened
    first,idle:=make([dynamic]string,context.temp_allocator),make([dynamic]string,context.temp_allocator)
    for id in gpu.Shader_Id {if gpu.preview_shader(id) {append(&first,gpu.SHADERS[id].name)}}
    if s.app.renderer!=nil {
        unused:=gpu.renderer_shaders_idle(s.app.renderer)
        for id in gpu.Shader_Id {if unused[id] {append(&idle,gpu.SHADERS[id].name)}}
    }
    p.job=build.shaders_start(p.project,first[:],idle[:])
}

@(private)
programs_finish :: proc(s:^Session,failed:bool,message:string) {
    p:=&s.build.programs
    delete(p.message)
    p.failed,p.message=failed,strings.clone(message)
    p.serial+=1
    import_programs_published(s)
    if failed {
        log.errorf("the programs of the project were not published: %s",message)
        notify(s,"The programs of the project could not be published")
    }
}

// Follows the publication; between frames.
programs_poll :: proc(s:^Session) {
    p:=&s.build.programs
    if p.job==nil {
        if p.again {programs_start(s)}
        return
    }
    gpu_ready:=s.app.renderer!=nil
    if !build.shaders_poll(p.job) {
        if !gpu_ready || p.active {return}
        // The stages the frames run serve the previews too.
        if folder:=build.shaders_active(p.job);folder!="" {
            p.first,p.active=true,true
            log.infof("programs: the stages the frames run compiled in %.1f s",time.duration_seconds(time.tick_since(p.job.tick)))
            p.running=host.app_shaders_load(s.app,folder)
            p.refused||=p.running==0
            if p.preview==0 {p.preview=p.running}
            p.mixed||=p.running!=0
        } else if folder:=build.shaders_first(p.job);folder!="" && !p.first {
            p.first=true
            p.preview=host.app_shaders_load(s.app,folder)
            p.mixed||=p.preview!=0
        }
        return
    }
    result:=&p.job.result
    switch result.status {
    case .Running,.Cancelled:
    case .None,.Up_To_Date,.Built,.Failed:
        // The renderer takes what was published: the new generation, or the
        // one that stands when it holds first stages of another.
        if (result.status==.Built || p.mixed) && gpu_ready {
            p.whole=host.app_shaders_reload(s.app)
            p.refused||=p.whole==0
            p.mixed=false
            // The previews wait for the first stages while they load, and for
            // the whole generation without them.
            if p.preview==0 || (!host.app_shaders_loading(s.app,p.preview) && s.app.shaders.published<p.preview) {p.preview=p.whole}
        }
        programs_finish(s,result.status==.Failed,result.message)
        if result.refused!="" {
            log.errorf("programs left out of the shaders, the others were published:\n%s",result.refused)
            notify(s,"Some programs could not be published; engine.diagnostics says which")
        }
        if result.status==.Built {log.infof("programs published: %d programs, %d stages compiled in %.1f s",result.programs,result.compiled,result.seconds)}
    }
    build.shaders_destroy(p.job)
    project.close(p.project)
    free(p.project)
    p.job,p.project=nil,nil
    if p.again {programs_start(s)}
}

programs_cancel :: proc(s:^Session) {
    p:=&s.build.programs
    if p.job!=nil {
        build.shaders_cancel(p.job)
        build.shaders_destroy(p.job)
    }
    if p.project!=nil {project.close(p.project);free(p.project)}
    delete(p.message)
    p^={}
}
