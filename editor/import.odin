package editor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import "mirai:ui"

// Import from the content browser: a source file becomes assets of the
// project with sources.import_source, as mirai import does, with the formats
// of models of plugins too (Import_Format_Provider). A model writes its
// meshes, materials and textures into models/<file name> (or what its format
// says, Format.folder) of the asset folder with a prefab of its hierarchy
// next to them; an image becomes a texture in textures/ (sRGB unless its name
// says it holds data or a normal map); a sound file (WAV, Ogg) becomes a
// sound in sounds/; a source a plugin imports whole (Import_Source_Provider)
// writes where its importer says. The settings of a source stay next to it
// (<source>.import) and importing it again gives the same assets. The Import
// button of the Assets tab and File > Import ask for the file; a file dropped
// on the window is imported the same way.
//
// The import runs in a thread of its own, with its own job system, while the
// editor goes on; the content browser shows the dot of what works. When it
// ends, between frames, the registry looks again at what it wrote, what was
// loaded from the files it replaced is read again and, when it wrote Surface
// programs, the programs of the project are published, so its materials
// show. One import runs at a time, and while it does nothing else writes
// assets (import_busy).

DIALOG_IMPORT :: u32(0x4d494d50)
DIALOG_AI_REFERENCE :: u32(0x4d414952)
IMPORT_MESSAGE_BYTES :: 192

@(storage)
Importer :: struct {
    imports:int,   // files imported in this session
    message:[IMPORT_MESSAGE_BYTES]u8,message_length:int, // what the last one said
    running:^Import_Job,  // the import in its thread; nil when none runs
    status:Import_Status, // of the import that runs, or of the last one
    written:[dynamic]Import_Written, // what the last one that ended wrote
    warnings:[dynamic]string,        // what the last one that ended warned of
    zones:[dynamic]importer.Zone_Total, // of the last one that ended, when it was profiled
    publishing:time.Tick, // since the last one asked for its programs to be published, while they are; zero otherwise
    profiled:bool,        // the last one was profiled: the publication it asked for is a zone too
}

// An import in a thread of its own. Its memory is that of allocator, which
// any thread can call.
Import_Job :: struct {
    thread:^thread.Thread,
    source,folder:string,
    kind:sources.Source_Kind,
    formats:[]importer.Format,                // of a model: the engine's, then plugin_formats'
    plugin_formats:[]Import_Format_Provider, // with the format.data their prepare gave
    whole:Source_Importer, // of a source a plugin imports whole; run is nil otherwise
    state:rawptr,          // what whole.prepare gave
    options:importer.Import_Options,
    allocator:mem.Allocator,
    started:time.Tick,
    profiled:bool,
    profile:base.Profile, // its zones, when profiled
    // What the thread leaves once done is set.
    report:importer.Import_Report,
    scene:string,
    error:importer.Error,
    seconds:f64,
    done:bool,
}

// What asset.import_status gives (Import_Status_Result).
Import_Status :: struct {
    importing:bool,
    ok:bool,     // the last import that ended wrote its assets
    path:[API_PATH_BYTES]u8,  // the source
    scene:[API_PATH_BYTES]u8, // the scene a source imported whole wrote
    message:[IMPORT_MESSAGE_BYTES]u8,
    seconds:f64,   // from the request until the editor took what it wrote
    unzoned:f64,   // of seconds, those no zone of the thread that imports or of the editor covers, when profiled
}

Import_Written :: struct {
    id:base.Asset_Id,
    kind:asset.Fourcc,
    kept:bool,   // its file already was what the import gives
    path:string, // under the asset folder
}

@(private)
import_say :: proc(s:^Session,format:string,args:..any) {
    text:=fmt.tprintf(format,..args)
    s.importer.message_length=copy(s.importer.message[:],text)
    notify(s,text)
}

// Why nothing else may write assets now: an import is writing them; "" when
// none is.
import_busy :: proc(s:^Session) -> string {
    if s.importer==nil || s.importer.running==nil {return ""}
    job:=s.importer.running
    return fmt.tprintf("%s is being imported and writes assets; try again when it ends (asset.import_status)",filepath.base(job.source))
}

// Starts importing a source file into the asset folder; false, with the
// reason shown, when it cannot. The source may be anywhere: only what it
// writes is in the project, and its settings are kept next to it only when it
// is inside. A source imported before writes the assets it wrote then,
// wherever they are; into names that import when the source was moved.
// folder, a folder of the assets (asset_folder_clean), replaces models,
// textures, sounds, fonts, texts or prompts. profiled records the zones of
// the import (importer.profile_totals) for asset.import_status.
// rig, when given, has the rig, rig_crotch and rig_neck that replace the
// source's settings, which a model inside the project keeps for its next import.
// image, when given, is the use of an image that replaces its settings the same
// way; without it, its settings say, else its name (sources.image_use).
// skeleton, when not zero, is the skeleton of the project the clips of a model
// play on (Import_Settings.skeleton), kept the same way.
import_file :: proc(s:^Session,source:string,into:base.Asset_Id={},folder:="",profiled:=false,rig:Maybe(importer.Import_Settings)=nil,image:Maybe(importer.Image_Use)=nil,skeleton:base.Asset_Id={}) -> bool {
    a:=s.app.assets
    if a==nil || a.registry.root=="" {
        import_say(s,"There is no asset folder to import into")
        return false
    }
    if busy:=import_busy(s);busy!="" {
        import_say(s,"%s",busy)
        return false
    }
    name:=filepath.base(source)
    allocator:=runtime.heap_allocator()
    options:=importer.Import_Options{
        root=strings.clone(s.project_root,allocator),into=into,
        texture_cache=project.cache_path(s.project_root,project.TEXTURE_CACHE,allocator=allocator),
        mesh_cache=project.cache_path(s.project_root,project.MESH_CACHE,allocator=allocator),
        fast_textures=true,
    }
    // A source outside the project keeps no settings next to it: the editor
    // writes only into the project, and reimporting finds it by its path.
    options.no_save=filepath.is_abs(importer.source_path(options,source))
    destination:=folder
    formats:=import_formats(s)
    // A source a plugin imports whole goes before the formats, which may read its bytes too.
    whole,claimed:=import_whole(s,source)
    kind:=sources.Source_Kind.None if claimed else sources.source_kind(source,formats)
    switch kind {
    case .None:
    case .Model:
        if folder=="" {destination="models"}
        destination=fmt.tprintf("%s/%s",destination,sources.model_folder(source,formats))
        if _,given:=rig.?;given || skeleton!={} {
            stored,_,settings_error:=importer.settings_load(importer.source_path(options,source))
            if settings_error.code!=.None {
                import_say(s,"%s: %s",name,settings_error.message)
                return false
            }
            options.settings,options.ignore_stored=stored,true
            if wanted,rigged:=rig.?;rigged {options.rig,options.rig_crotch,options.rig_neck=wanted.rig,wanted.rig_crotch,wanted.rig_neck}
            if skeleton!={} {options.skeleton=skeleton}
        }
    case .Image:
        if folder=="" {destination="textures"}
        options.image=sources.image_use(source)
        if use,given:=image.?;given {
            stored,_,settings_error:=importer.settings_load(importer.source_path(options,source))
            if settings_error.code!=.None {
                import_say(s,"%s: %s",name,settings_error.message)
                return false
            }
            options.settings,options.ignore_stored=stored,true
            options.image=use
        }
    case .Sound: if folder=="" {destination="sounds"}
    case .Font: if folder=="" {destination="fonts"}
    case .Strings: if folder=="" {destination="texts"}
    case .Prompts: if folder=="" {destination="prompts"}
    }
    destination=asset.registry_file_path(&a.registry,strings.trim_prefix(destination,"/"),context.temp_allocator)
    job:=new(Import_Job,allocator)
    job^={kind=kind,options=options,allocator=allocator,started=time.tick_now(),profiled=profiled}
    job.source=strings.clone(source,allocator)
    job.folder=strings.clone(destination,allocator)
    if kind==.Model {import_formats_prepare(s,job)}
    if kind==.None && !claimed {
        import_job_free(job)
        import_say(s,"%s is not a file the editor imports",name)
        return false
    }
    if _,given:=rig.?;given && kind!=.Model {
        import_job_free(job)
        import_say(s,"%s is not a model: only a model takes a rig",name)
        return false
    }
    if skeleton!={} && kind!=.Model {
        import_job_free(job)
        import_say(s,"%s is not a model: only the clips of a model go on a skeleton",name)
        return false
    }
    if _,given:=image.?;given && kind!=.Image {
        import_job_free(job)
        import_say(s,"%s is not an image: only an image imported on its own takes a use; the textures of a model take theirs from its materials",name)
        return false
    }
    if claimed && folder!="" {
        import_job_free(job)
        import_say(s,"%s is one of %s, which write where their importer says, so it takes no folder",name,whole.name)
        return false
    }
    if claimed {
        job.whole=whole
        if whole.prepare!=nil {job.state=whole.prepare(s,allocator)}
    }
    job.thread=thread.create_and_start_with_poly_data(job,import_run)
    if job.thread==nil {
        import_job_free(job)
        import_say(s,"%s: no thread could be started to import it",name)
        return false
    }
    s.importer.running=job
    s.importer.status={importing=true}
    base.text_set(s.importer.status.path[:],source)
    import_say(s,"Importing %s",name)
    return true
}

// The import of job, in its thread: a job system of its own cooks on the
// cores the editor leaves.
@(private)
import_run :: proc(job:^Import_Job) {
    context.allocator=job.allocator
    defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
    js:jobs.Job_System
    // A core stays with the editor, which keeps drawing.
    threaded:=jobs.system_init(&js,{threads=max(os.get_processor_core_count()-2,0),allocator=job.allocator})
    defer if threaded {jobs.system_destroy(&js)}
    if threaded {job.options.worker={system=&js,worker=jobs.OWNER}}
    defer job.options.worker={}
    if job.profiled && !importer.profile_begin(&job.profile,&job.options,job.allocator) {job.profiled=false}
    error:importer.Error
    if job.whole.run!=nil {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        report,scene,run_error:=job.whole.run(job.state,job.source,job.options,job.allocator)
        job.report=report
        job.scene,error=scene,run_error
    } else {
        report,import_error:=sources.import_source(job.source,job.folder,job.options,job.formats,job.allocator)
        job.report=report
        error=import_error
    }
    if error.code!=.None {job.error={error.code,strings.clone(error.message,job.allocator)}}
    job.seconds=time.duration_seconds(time.tick_since(job.started))
    intrinsics.atomic_store(&job.done,true)
}

@(private)
import_job_free :: proc(job:^Import_Job) {
    allocator:=job.allocator
    if job.thread!=nil {thread.destroy(job.thread)}
    importer.report_destroy(&job.report)
    delete(job.source,allocator);delete(job.folder,allocator);delete(job.scene,allocator)
    delete(job.options.root,allocator);delete(job.options.texture_cache,allocator);delete(job.options.mesh_cache,allocator)
    for provider in job.plugin_formats {
        if provider.prepare!=nil && provider.release!=nil {provider.release(provider.format.data,allocator)}
    }
    delete(job.plugin_formats,allocator)
    delete(job.formats,allocator)
    if job.whole.release!=nil {job.whole.release(job.state,allocator)}
    delete(job.error.message,allocator)
    if job.profiled {base.profile_destroy(&job.profile)}
    free(job,allocator)
}

// Takes what an import that ended wrote, on the thread of the editor.
// Between frames.
import_poll :: proc(s:^Session) {
    job:=s.importer.running
    if job==nil || !intrinsics.atomic_load(&job.done) {return}
    thread.join(job.thread)
    s.importer.running=nil
    defer import_job_free(job)
    name:=filepath.base(job.source)
    status:=&s.importer.status
    status.importing=false
    import_written_clear(s)
    // The thread of the import ended: the editor records on its ring.
    profile:=&job.profile if job.profiled else nil
    s.importer.profiled,s.importer.publishing=job.profiled,{}
    defer {
        status.seconds=time.duration_seconds(time.tick_since(job.started))
        if job.profiled {import_zones_take(s,profile)}
    }
    if job.error.code!=.None {
        import_say(s,"%s: %s",name,job.error.message)
        base.text_set(status.message[:],string(s.importer.message[:s.importer.message_length]))
        return
    }
    a:=s.app.assets
    report:=&job.report
    if a!=nil {
        registry_zone:=base.profile_begin(profile,jobs.OWNER,"editor.registry")
        // The registry looks again at the files it wrote, and what was loaded from the ones it replaced is read again.
        paths:=make([dynamic]string,0,len(report.assets)+1,context.temp_allocator)
        written:=true
        for entry in report.assets {
            path,inside:=asset.registry_relative(&a.registry,entry.path)
            if !inside {written=false;break}
            append(&paths,path)
        }
        for other in report.others {
            path,inside:=asset.registry_relative(&a.registry,other)
            if !inside {written=false;break}
            append(&paths,path)
        }
        if path,inside:=asset.registry_relative(&a.registry,report.saved);inside {append(&paths,path)}
        if written {host.assets_refresh(a,paths[:])} else {host.assets_scan(a)}
        base.profile_end(registry_zone)
        materials_zone:=base.profile_begin(profile,jobs.OWNER,"editor.materials")
        for entry in report.assets {
            if entry.kind==asset.KIND_MATERIAL {material_rebase(s,entry.id)}
        }
        base.profile_end(materials_zone)
        reload_zone:=base.profile_begin(profile,jobs.OWNER,"editor.reload")
        for entry in report.assets {host.assets_reload(a,entry.id)}
        base.profile_end(reload_zone)
    }
    if len(report.programs)>0 && s.build!=nil {
        programs_zone:=base.profile_begin(profile,jobs.OWNER,"editor.programs")
        programs_publish_request(s)
        base.profile_end(programs_zone)
        s.importer.publishing=time.tick_now()
    }
    s.content.revision+=1
    s.importer.imports+=1
    status.ok=true
    for warning in report.warnings {append(&s.importer.warnings,strings.clone(warning))}
    for entry in report.assets {
        path:=entry.path
        if a!=nil {
            if relative,inside:=asset.registry_relative(&a.registry,entry.path);inside {path=relative}
        }
        append(&s.importer.written,Import_Written{id=entry.id,kind=entry.kind,kept=entry.kept,path=strings.clone(path)})
    }
    switch {
    case job.scene!="":
        scene:=job.scene
        if a!=nil {scene,_=asset.registry_relative(&a.registry,job.scene)}
        base.text_set(status.scene[:],scene)
        import_say(s,"Imported %s: the scene %s and %d assets, %d warnings, in %.1f s",name,scene,len(report.assets)-1,len(report.warnings),job.seconds)
    case job.kind!=.Model && job.kind!=.Image || report.saved!="" || job.options.no_save:
        import_say(s,"Imported %s: %d assets",name,len(report.assets))
    case:
        import_say(s,"Imported %s: %d assets; its settings could not be written next to it",name,len(report.assets))
    }
    base.text_set(status.message[:],string(s.importer.message[:s.importer.message_length]))
    for warning in report.warnings {log.warn(warning)}
}

// Waits for an import that runs and lets go of what the last one wrote:
// when the editor ends.
import_end :: proc(s:^Session) {
    if job:=s.importer.running;job!=nil {
        thread.join(job.thread)
        s.importer.running=nil
        import_job_free(job)
    }
    import_written_clear(s)
    delete(s.importer.written)
    delete(s.importer.warnings)
    delete(s.importer.zones)
    s.importer.written,s.importer.warnings,s.importer.zones=nil,nil,nil
}

@(private)
import_written_clear :: proc(s:^Session) {
    for w in s.importer.written {delete(w.path)}
    clear(&s.importer.written)
    for w in s.importer.warnings {delete(w)}
    clear(&s.importer.warnings)
    for z in s.importer.zones {delete(z.name)}
    clear(&s.importer.zones)
    s.importer.status.unzoned=0
}

@(private)
import_zones_take :: proc(s:^Session,profile:^base.Profile) {
    totals,_:=importer.profile_totals(profile,context.temp_allocator)
    // The names of the zones of plugins live in their libraries, which a build replaces.
    for &t in totals {t.name=strings.clone(t.name)}
    append(&s.importer.zones,..totals)
    s.importer.status.unzoned=importer.profile_unzoned(totals,s.importer.status.seconds)
}

// A publication of programs ended: when the last import asked for it, its
// seconds are a zone of that import, after the others, on a thread of its own.
@(private)
import_programs_published :: proc(s:^Session) {
    if s.importer==nil || s.importer.publishing=={} {return}
    if s.importer.profiled {
        seconds:=time.duration_seconds(time.tick_since(s.importer.publishing))
        append(&s.importer.zones,importer.Zone_Total{name=strings.clone("programs.publish"),seconds=seconds,count=1})
    }
    s.importer.publishing={}
}

// While an import runs: the dot of what works and the source it imports.
@(private)
import_working :: proc(s:^Session) -> bool {
    if s.importer==nil {return false}
    job:=s.importer.running
    if job==nil {return false}
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=8,align_y=.Center}) {
        pulse_dot(ctx,th.accent,true)
        ui.label(ctx,fmt.tprintf("Importing %s",filepath.base(job.source)),th.font_small,th.text)
    }
    return true
}

// A format of models a plugin adds: its files import as those of the engine.
Import_Format_Provider :: struct {
    format:importer.Format,
    // On the thread of the editor, before a model is imported: the options of
    // the format for it (Format.data) from the session, in allocator; nil
    // keeps format.data.
    prepare:proc(s:^Session,allocator:mem.Allocator) -> rawptr,
    release:proc(data:rawptr,allocator:mem.Allocator), // of what prepare gave, once the import ended
}

// A source a plugin imports whole, writing into the project what it says
// (an Unreal map: a scene and the assets it names).
Source_Importer :: struct {
    name:string, // "Unreal maps": its filter in the file dialog and in messages
    extensions:[importer.FORMAT_EXTENSIONS]string, // lower case, with the dot, "" after the last
    claims:proc(path:string,head:[]u8) -> bool,    // head: up to importer.SNIFF_BYTES from the start of the file
    // On the thread of the editor, before the import starts: what run needs
    // of the session, in allocator; nil for nothing.
    prepare:proc(s:^Session,allocator:mem.Allocator) -> rawptr,
    // In the thread of the import, with a job system of its own in
    // options.worker. scene: the scene it wrote, "" for none.
    run:proc(state:rawptr,source:string,options:importer.Import_Options,allocator:mem.Allocator) -> (report:importer.Import_Report,scene:string,error:importer.Error),
    release:proc(state:rawptr,allocator:mem.Allocator), // of what prepare gave, once the import ended
}
Import_Source_Provider :: struct {source:Source_Importer}

// The formats of models the editor imports: those of the engine and those of
// the plugins of the library in use.
@(private)
import_formats :: proc(s:^Session) -> []importer.Format {
    found:[PROVIDER_CAPACITY]Import_Format_Provider
    out:=make([dynamic]importer.Format,0,len(sources.FORMATS)+PROVIDER_CAPACITY,context.temp_allocator)
    append(&out,..sources.FORMATS[:])
    for provider in found[:provided_all(s,found[:])] {append(&out,provider.format)}
    return out[:]
}

// The formats of the import of a model by job, with the options the plugins
// prepare for it.
@(private)
import_formats_prepare :: proc(s:^Session,job:^Import_Job) {
    found:[PROVIDER_CAPACITY]Import_Format_Provider
    plugins:=found[:provided_all(s,found[:])]
    for &provider in plugins {
        if provider.prepare!=nil {provider.format.data=provider.prepare(s,job.allocator)}
    }
    formats:=make([dynamic]importer.Format,0,len(sources.FORMATS)+len(plugins),job.allocator)
    append(&formats,..sources.FORMATS[:])
    for provider in plugins {append(&formats,provider.format)}
    job.formats=formats[:]
    job.plugin_formats=slice.clone(plugins,job.allocator)
}

// The importer of a plugin that claims source whole.
@(private)
import_whole :: proc(s:^Session,source:string) -> (whole:Source_Importer,claimed:bool) {
    if importer.unsafe_path(source) || os.is_dir(source) {return}
    buffer:[importer.SNIFF_BYTES]u8
    head,_,error:=serial.file_read_head(source,buffer[:])
    if error!=.None {return}
    found:[PROVIDER_CAPACITY]Import_Source_Provider
    for provider in found[:provided_all(s,found[:])] {
        if provider.source.claims!=nil && provider.source.run!=nil && provider.source.claims(source,head) {return provider.source,true}
    }
    return
}

// "obj;gltf;glb": the extensions of a file dialog filter.
@(private)
dialog_patterns :: proc(extensions:[]string,b:^strings.Builder) -> string {
    for extension in extensions {
        if extension=="" {continue}
        if strings.builder_len(b^)>0 {strings.write_byte(b,';')}
        strings.write_string(b,extension[1:])
    }
    return strings.to_string(b^)
}

// The dialog that asks for the file to import.
import_ask :: proc(s:^Session) {
    models:=strings.builder_make(context.temp_allocator)
    for &format in import_formats(s) {dialog_patterns(format.extensions[:],&models)}
    images,sounds,fonts,texts:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    image_extensions,sound_extensions,font_extensions,text_extensions:=sources.IMAGE_EXTENSIONS,sources.SOUND_EXTENSIONS,sources.FONT_EXTENSIONS,importer.STRINGS_EXTENSIONS
    filters:=make([dynamic]platform.Dialog_Filter,context.temp_allocator)
    append(&filters,
        platform.Dialog_Filter{"Models",strings.to_string(models)},{"Images",dialog_patterns(image_extensions[:],&images)},{"Sounds",dialog_patterns(sound_extensions[:],&sounds)},
        {"Fonts",dialog_patterns(font_extensions[:],&fonts)},{"Texts",dialog_patterns(text_extensions[:],&texts)},{"Prompt packs","json"},
    )
    found:[PROVIDER_CAPACITY]Import_Source_Provider
    for &provider in found[:provided_all(s,found[:])] {
        patterns:=strings.builder_make(context.temp_allocator)
        append(&filters,platform.Dialog_Filter{provider.source.name,dialog_patterns(provider.source.extensions[:],&patterns)})
    }
    if !platform.dialog_show(s.app.platform,{kind=.Open_File,tag=DIALOG_IMPORT,filters=filters[:]}) {notify(s,"A file dialog is already open")}
}

// The answer of the dialog and the files dropped on the window in this frame.
@(private)
import_frame :: proc(s:^Session) {
    p:=s.app.platform
    if p==nil || s.app.assets==nil {return}
    answer:=platform.dialog_result(p)
    if answer.tag==DIALOG_IMPORT && answer.state==.Accepted {import_file(s,answer.path)}
    if answer.tag==DIALOG_AI_REFERENCE && answer.state==.Accepted {ai_reference_add(s,answer.path)}
    for event in platform.input_events(p) {
        if drop,dropped:=event.(platform.Drop_Event);dropped {
            path:=platform.input_dropped(p,int(drop.index))
            if path=="" {continue}
            // An image dropped on the chat is a reference for the next message, not an asset.
            if s.ai!=nil && s.ai.chat_open && ui.rect_contains(s.ai.chat_rect,drop.position) && ai_reference_image(path) {
                ai_reference_add(s,path)
                continue
            }
            import_file(s,path)
        }
    }
}
