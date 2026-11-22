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
import "mirai:core"
import "mirai:cook/build"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:cook/textures"
import "mirai:host"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import "mirai:store"
import "mirai:ui"

// Import from the content browser: a source file or folder anywhere on disk
// is ingested into the library of the machine where it is, nothing copied,
// and its package is pinned in the project (sources.project_ingest), as mirai
// import does, with the formats and whole sources of plugins too
// (Import_Format_Provider, Import_Source_Provider). Its package is listed in
// the folder of the browser, or for a source in the assets, in its own
// folder: its meshes, textures, sounds and fonts are blobs of the store the
// registry lists there, and its documents (materials, skeletons, clips, the
// prefab of a model) are files of that folder. Importing it again gives the
// same assets. The Import button of the Assets tab and File > Import ask for
// the file; a file dropped on the window is imported the same way, and Add
// from library pins a package the library has (library.odin).
//
// The import runs in a thread of its own, with its own job system, while the
// editor goes on; the content browser shows the dot of what works. When it
// ends, between frames, the registry lists the packages again and looks at
// what it wrote, what was loaded of it is read again and, when it wrote
// Surface programs, the programs of the project are published, so its
// materials show. One import runs at a time, and while it does nothing else
// writes assets (import_busy). It is no edit: undo does not take it back.

DIALOG_IMPORT :: u32(0x4d494d50)
DIALOG_AI_REFERENCE :: u32(0x4d414952)
IMPORT_MESSAGE_BYTES :: 192
IMPORT_CHANGED_ROWS :: 6 // documents the question lists; the rest is a count

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

// An import in a thread of its own: of a source (source), or the add of a
// packages of the library (additions). Its memory is that of allocator, which
// any thread can call.
Import_Job :: struct {
    thread:^thread.Thread,
    source:string,        // the source, or the name of the package added
    root:string,          // the project or plugin it is pinned in
    folder:Maybe(string), // nil: the library chooses the folder of its assets
    prefix:string,        // of that root in the registry: "" for the project
    additions:[]sources.Package_Add, // empty for a source
    group_add:bool,
    assets:[]base.Asset_Id, // of the package added, those it uses; none: all
    settings:importer.Import_Settings,
    settled:bool,         // settings replace those its package keeps
    claimed:bool,         // a plugin imports the source whole
    imports:sources.Library_Imports, // what the plugins give, prepared on the thread of the editor
    plugin_formats:[]Import_Format_Provider, // with the format.data their prepare gave
    wholes:[]Source_Importer,                // with the state their prepare gave, in imports.wholes
    store:store.Store,    // the session's
    mesh_org:vcs.Log_Id,  // the org whose peers' derived data the cook takes and to which it publishes; zero: none
    options:sources.Library_Options,
    allocator:mem.Allocator,
    started:time.Tick,
    profiled:bool,
    profile:base.Profile, // its zones, when profiled
    // What the thread leaves once done is set.
    report:importer.Import_Report,
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

// Where what the user imports goes: the folder the browser is in.
@(private)
import_place :: proc(s:^Session) -> Maybe(string) {
    if s.content==nil || s.content.place_length==0 {return nil}
    return string(s.content.place[:s.content.place_length])
}

// The root of the registry folder is of, the project or a plugin, and
// where the folder is under its assets; false for a folder of the editor or
// of the engine, which pins nothing.
@(private)
import_root_of :: proc(s:^Session,r:^asset.Registry,folder:string) -> (root:Library_Root,rest:string,ok:bool) {
    for mount in r.mounts {
        if folder!=mount.prefix && !asset_path_inside(folder,mount.prefix) {continue}
        if strings.has_prefix(mount.prefix,".") || filepath.base(mount.folder)!=project.FOLDER_NAMES[.Assets] {return}
        rest=folder[min(len(mount.prefix)+1,len(folder)):]
        return {filepath.dir(mount.folder),mount.prefix},rest,true
    }
    if s.project_root=="" {return}
    return {s.project_root,""},folder,true
}

// Starts importing a source file or folder from anywhere on disk; false,
// with the reason shown, when it cannot. It is ingested into the library
// where it is and its package is pinned in the project or plugin whose
// assets contain folder. Without a folder, the library chooses it.
// profiled records the zones of the import
// (importer.profile_totals) for asset.import_status.
// rig, when given, has the rig, rig_crotch and rig_neck that replace the
// settings its package keeps for its next import.
// image, when given, is the use of an image that replaces its settings the same
// way; without it, its settings say, else its name (sources.image_use).
// skeleton, when not zero, is the skeleton of the project the clips of a model
// play on (Import_Settings.skeleton), kept the same way; so is front, when
// given, where a model stands facing (Import_Settings.front).
// A source whose import wrote documents that changed since (the entities
// added to the scene of a map) is not imported unless discard writes over
// them: ask opens the question (Modal.Import_Changes), else it fails naming
// them.
import_file :: proc(s:^Session,source:string,folder:Maybe(string)=nil,profiled:=false,rig:Maybe(importer.Import_Settings)=nil,image:Maybe(importer.Image_Use)=nil,skeleton:base.Asset_Id={},front:Maybe(importer.Front)=nil,discard:=false,ask:=false) -> bool {
    a:=s.app.assets
    if a==nil || a.registry.root=="" {
        import_say(s,"There is no asset folder to import into")
        return false
    }
    if busy:=import_busy(s);busy!="" {
        import_say(s,"%s",busy)
        return false
    }
    if s.store.root=="" {
        import_say(s,"The editor has no store to keep imports in: start it with --store <folder>")
        return false
    }
    if importer.unsafe_path(source) || !os.exists(source) {
        import_say(s,"%s does not exist: give the path of a file or a folder on disk",source)
        return false
    }
    origin:=importer.path_key(source)
    name:=filepath.base(origin)
    place,explicit:=folder.?
    if !explicit {
        if relative,inside:=asset.registry_relative(&a.registry,origin);inside {place=content_folder_of(relative)}
    }
    root,rest,rooted:=import_root_of(s,&a.registry,place)
    if !rooted {
        import_say(s,"%s is a folder of the editor or the engine: import into a folder of the project or of a plugin",place)
        return false
    }
    // A source a plugin imports whole goes before the formats, which may read its bytes too.
    whole,code,claimed:=import_whole(s,origin)
    kind:=sources.Source_Kind.None if claimed else sources.source_kind(origin,import_formats(s))
    switch {
    case kind==.None && !claimed:
        import_say(s,"%s is not a file the editor imports",name)
        return false
    case rig!=nil && kind!=.Model:
        import_say(s,"%s is not a model: only a model takes a rig",name)
        return false
    case skeleton!={} && kind!=.Model:
        import_say(s,"%s is not a model: only the clips of a model go on a skeleton",name)
        return false
    case front!=nil && kind!=.Model:
        import_say(s,"%s is not a model: only a model has a front",name)
        return false
    case image!=nil && kind!=.Image:
        import_say(s,"%s is not an image: only an image imported on its own takes a use; the textures of a model take theirs from its materials",name)
        return false
    }
    if changed:=import_changed(s,root.root,origin);len(changed)>0 && !discard {
        if ask && s.gui!=nil {
            modal_close(s.gui)
            base.text_set(s.gui.import_source[:],origin)
            append(&s.gui.import_changed,..changed)
            s.gui.modal=.Import_Changes
            return false
        }
        paths:=make([]string,len(changed),context.temp_allocator)
        for id,at in changed {
            file,_:=asset.registry_find(&a.registry,id)
            paths[at]=file.path
        }
        one:=len(changed)==1
        import_say(s,"%s: %s changed since it was last imported, and importing it again writes over %s: import with discard_changes to write over %s, or leave it as it is to keep %s",
            name,strings.join(paths,", ",context.temp_allocator),one?"it":"them",one?"that change":"those changes",one?"it":"them")
        return false
    }
    allocator:=runtime.heap_allocator()
    job:=new(Import_Job,allocator)
    job^={allocator=allocator,started=time.tick_now(),profiled=profiled,claimed=claimed}
    job.store=s.store
    job.mesh_org=kai_mesh_org(s)
    job.source=strings.clone(origin,allocator)
    job.root,job.prefix=strings.clone(root.root,allocator),strings.clone(root.prefix,allocator)
    if explicit {job.folder=strings.clone(rest,allocator)}
    // The settings its package keeps, changed by what was asked: given only when they change it.
    if kind==.Model || kind==.Image {
        stored,found,settings_error:=importer.settings_load({store=&job.store},origin)
        if settings_error.code!=.None {
            import_job_free(job)
            import_say(s,"%s: %s",name,settings_error.message)
            return false
        }
        chosen:=stored
        // An image with no settings yet holds what its name says.
        if kind==.Image && !found {chosen.image=sources.image_use(origin)}
        if use,given:=image.?;given {chosen.image=use}
        if wanted,given:=rig.?;given {chosen.rig,chosen.rig_crotch,chosen.rig_neck=wanted.rig,wanted.rig_crotch,wanted.rig_neck}
        if skeleton!={} {chosen.skeleton=skeleton}
        if stated,given:=front.?;given {chosen.front=stated}
        job.settings=chosen
        job.settled=chosen!=stored || !found
    }
    import_plugins_prepare(s,job,kind==.Model,whole if claimed else {},code)
    job.options.changed=.Discard if discard else .Refuse
    return import_job_start(s,job,"Importing %s",name)
}

// The formats and the whole importers of the plugins job imports with, with
// what their prepare gives from the library: models takes the formats,
// whole the one importer that claims its source, with the identity of the
// code of its plugin.
@(private)
import_plugins_prepare :: proc(s:^Session,job:^Import_Job,models:bool,whole:Source_Importer,code:u64) {
    job.imports.world=s.info
    if models {
        found:[PROVIDER_CAPACITY]Import_Format_Provider
        plugins:=found[:provided_all(s,found[:])]
        job.plugin_formats=slice.clone(plugins,job.allocator)
        formats:=make([]importer.Format,len(plugins),job.allocator)
        for &provider,i in job.plugin_formats {
            if provider.prepare!=nil {provider.format.data=provider.prepare(&job.store,job.root,s.info,job.allocator)}
            formats[i]=provider.format
        }
        job.imports.formats=formats
    }
    if whole.run!=nil {
        job.wholes=make([]Source_Importer,1,job.allocator)
        job.wholes[0]=whole
        wholes:=make([]sources.Whole_Source,1,job.allocator)
        wholes[0]={name=whole.name,version=whole.version,claims=whole.claims,run=whole.run,code=code}
        if whole.prepare!=nil {wholes[0].state=whole.prepare(&job.store,job.root,s.info,job.allocator)}
        job.imports.wholes=wholes
    }
    job.options=sources.Library_Options{store=&job.store,fast_textures=true,root=job.root,imports=&job.imports}
}

// Starts the thread of job, which is the import that runs once started; it
// is freed when it cannot start, with the reason shown.
@(private)
import_job_start :: proc(s:^Session,job:^Import_Job,format:string,args:..any) -> bool {
    if job.options.gpu==nil {job.options.gpu=&s.import_gpu}
    job.thread=thread.create_and_start_with_poly_data(job,import_run)
    if job.thread==nil {
        import_say(s,"%s: no thread could be started to import it",filepath.base(job.source))
        import_job_free(job)
        return false
    }
    s.importer.running=job
    s.importer.status={importing=true}
    base.text_set(s.importer.status.path[:],job.source)
    import_say(s,format,..args)
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
    mesh:Kai_Mesh_Import
    if source,shared:=kai_mesh_import_open(&mesh,job.store.root,job.mesh_org);shared {job.options.source=source}
    defer kai_mesh_import_close(&mesh)
    defer job.options.source={}
    if job.profiled {
        timed:=importer.Import_Options{worker=job.options.worker}
        if importer.profile_begin(&job.profile,&timed,job.allocator) {job.options.worker=timed.worker} else {job.profiled=false}
    }
    added:sources.Library_Report
    error:importer.Error
    switch {
    case job.group_add:
        added=sources.project_add_many(job.root,job.additions,job.options,job.allocator)
    case len(job.additions)>0:
        entry:=job.additions[0]
        added=sources.project_add(job.root,entry.manifest,entry.folder,job.assets,job.options,job.allocator)
    case:
        settings:=&job.settings if job.settled else nil
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        report,ingested,ingest_error:=sources.project_ingest(job.root,job.source,job.folder,job.options,settings,job.allocator)
        job.report=report
        added=ingested
        error=ingest_error
    }
    defer sources.library_report_destroy(&added)
    if error.code==.None && len(added.failures)+len(added.missing)>0 {
        error={.Write,strings.join(len(added.failures)>0?added.failures[:]:added.missing[:],"; ",context.temp_allocator)}
    }
    if error.code==.None && len(job.additions)>0 {import_added_report(job)}
    for warning in added.warnings {append(&job.report.warnings,strings.clone(warning,job.allocator))}
    if error.code!=.None {job.error={error.code,strings.clone(error.message,job.allocator)}}
    job.seconds=time.duration_seconds(time.tick_since(job.started))
    intrinsics.atomic_store(&job.done,true)
}

// What the add of a package gives: its assets the project uses.
@(private)
import_added_report :: proc(job:^Import_Job) {
    importer.report_init(&job.report,job.allocator)
    a:=context.temp_allocator
    list,_,error:=asset.packages_load(job.root,a)
    if error!=.None {return}
    pins:=make(map[base.Asset_Id]store.Hash,a)
    for &entry in list.packages {pins[entry.id]=entry.manifest}
    digits:[64]u8
    for entry in job.additions {
        p,read_error:=asset.package_get(&job.store,entry.manifest,a)
        if read_error!=.None {continue}
        manifest,found:=pins[p.id]
        if !found {continue}
        if manifest!=entry.manifest {
            if p,read_error=asset.package_get(&job.store,manifest,a);read_error!=.None {continue}
        }
        if hash,e:=store.ref_get(&job.store,asset.REF_BUILDS,
            store.hex(asset.build_select(manifest,&p),&digits));e==.None {
            if b,build_error:=asset.build_get(&job.store,hash,a);build_error==.None {
                for program in b.programs {
                    append(&job.report.programs,asset.generated_program_id(program,job.allocator))
                }
            }
        }
        selected,_,select_error:=asset.package_selection(&p,job.assets,a)
        if select_error!=.None {continue}
        for &entry,i in p.assets {
            if selected[i] {append(&job.report.assets,importer.Written{id=entry.id,kind=entry.kind})}
        }
    }
}

@(private)
import_job_free :: proc(job:^Import_Job) {
    allocator:=job.allocator
    if job.thread!=nil {thread.destroy(job.thread)}
    importer.report_destroy(&job.report)
    delete(job.source,allocator)
    delete(job.root,allocator);delete(job.prefix,allocator)
    if folder,given:=job.folder.?;given {delete(folder,allocator)}
    for entry in job.additions {delete(entry.folder,allocator)}
    delete(job.additions,allocator)
    delete(job.assets,allocator)
    for provider in job.plugin_formats {
        if provider.prepare!=nil && provider.release!=nil {provider.release(provider.format.data,allocator)}
    }
    delete(job.plugin_formats,allocator)
    delete(job.imports.formats,allocator)
    for source,i in job.wholes {
        if source.prepare!=nil && source.release!=nil {source.release(job.imports.wholes[i].state,allocator)}
    }
    delete(job.wholes,allocator)
    delete(job.imports.wholes,allocator)
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
    a:=s.app.assets
    // What its package lists is listed again, also after a failure that pinned it.
    if a!=nil {
        registry_zone:=base.profile_begin(profile,jobs.OWNER,"editor.registry")
        library_relist(s,{job.root,job.prefix})
        base.profile_end(registry_zone)
    }
    if job.error.code!=.None {
        import_say(s,"%s: %s",name,job.error.message)
        base.text_set(status.message[:],string(s.importer.message[:s.importer.message_length]))
        return
    }
    report:=&job.report
    if a!=nil {
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
    if s.content!=nil {s.content.revision+=1}
    s.importer.imports+=1
    status.ok=true
    for warning in report.warnings {append(&s.importer.warnings,strings.clone(warning))}
    scene_id:base.Asset_Id
    if job.claimed && len(report.assets)>0 {
        if p,error:=asset.package_get(&job.store,report.manifest,context.temp_allocator);error==.None {
            scene_id=asset.package_root(&p)
        }
    }
    scene:=""
    for entry in report.assets {
        path:=entry.path
        if a!=nil {
            if file,found:=asset.registry_find(&a.registry,entry.id);found {path=file.path}
        }
        if entry.id==scene_id && entry.kind==asset.KIND_SCENE {scene=path}
        append(&s.importer.written,Import_Written{id=entry.id,kind=entry.kind,kept=entry.kept,path=strings.clone(path)})
    }
    switch {
    case scene!="":
        base.text_set(status.scene[:],scene)
        import_say(s,"Imported %s: the scene %s and %d assets, %d warnings, in %.1f s",name,scene,len(report.assets)-1,len(report.warnings),job.seconds)
    case len(job.additions)>0:
        import_say(s,"Added %s: %d assets",name,len(report.assets))
    case:
        import_say(s,"Imported %s: %d assets",name,len(report.assets))
    }
    base.text_set(status.message[:],string(s.importer.message[:s.importer.message_length]))
    for warning in report.warnings {log.warn(warning)}
}

// The documents of the package the source at origin was ingested as that
// the project at root pins and that changed since an import or a refresh
// last wrote them (importer.documents_changed), in the temp allocator; none
// for a source never ingested or a package root does not pin.
@(private)
import_changed :: proc(s:^Session,root,origin:string) -> []base.Asset_Id {
    p,_,found,error:=importer.package_previous(&s.store,{},origin,context.temp_allocator)
    if !found || error.code!=.None {return nil}
    list,_,_:=asset.packages_load(root,context.temp_allocator)
    for &entry in list.packages {
        if entry.id==p.id {return importer.documents_changed(&p,entry.written[:],&s.app.assets.registry,context.temp_allocator)}
    }
    return nil
}

// Asks before importing a source again over documents of it that changed
// since its import wrote them: they go back to what the source gives.
@(private)
import_changes_modal :: proc(s:^Session) {
    g:=s.gui;ctx:=g.ctx
    r:=files_registry(s)
    closed:=false
    defer if closed {modal_close(g)}
    if ui.modal(ctx,shell_id(g,"import_changes"),{width=420,padding=16,gap=12,close=&closed}) {
        source:=strings.clone(base.text_get(g.import_source[:]),context.temp_allocator)
        changed:=len(g.import_changed)
        ui.label(ctx,changed==1?"Discard a change?":fmt.tprintf("Discard %d changes?",changed),ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
            ui.label(ctx,fmt.tprintf("Changed since %s was imported",filepath.base(source)),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
            for id in g.import_changed[:min(changed,IMPORT_CHANGED_ROWS)] {
                if r==nil {break}
                if file,found:=asset.registry_find(r,id);found {modal_asset_row(s,ctx,file)}
            }
            if changed>IMPORT_CHANGED_ROWS {ui.label(ctx,fmt.tprintf("and %d more",changed-IMPORT_CHANGED_ROWS),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_x=.End,align_y=.Center}) {
            if ui.button(ctx,shell_id(g,"import_changes_cancel"),{label="Cancel",variant="field",width=90,height=ui.metric(ctx,"control"),center=true}).clicked {closed=true}
            if ui.button(ctx,shell_id(g,"import_changes_confirm"),{label="Discard and import",variant="danger",width=150,height=ui.metric(ctx,"control"),center=true}).clicked {
                modal_close(g)
                import_file(s,source,discard=true)
            }
        }
    }
}

// Waits for an import that runs and lets go of what the last one wrote:
// when the editor ends.
import_end :: proc(s:^Session) {
    if job:=s.importer.running;job!=nil {
        thread.join(job.thread)
        s.importer.running=nil
        import_job_free(job)
    }
    textures.gpu_context_destroy(&s.import_gpu)
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
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
        pulse_dot(ctx,ui.tone(ctx,"accent"),true)
        ui.label(ctx,fmt.tprintf("Importing %s",filepath.base(job.source)),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
    }
    return true
}

// A format of models a plugin adds: its files import as those of the engine,
// in the editor and in the refresh of every build (import_library).
Import_Format_Provider :: struct {
    format:importer.Format,
    // Before a model is imported: the options of the format for it
    // (Format.data), in allocator; nil keeps format.data. library: the store
    // the packages of the root the import is for are in (asset.root_packages
    // of root lists them), info: the types of its game.
    prepare:proc(library:^store.Store,root:string,info:^core.World_Info,allocator:mem.Allocator) -> rawptr,
    release:proc(data:rawptr,allocator:mem.Allocator), // of what prepare gave, once the import ended
}

// A source a plugin imports whole with importer.Outputs, the one source of
// every asset it makes (an Unreal map: a scene and the meshes, materials and
// textures it names, the packages it reads being its inputs), in the editor
// and in the refresh of every build (import_library). It is read where it is.
Source_Importer :: struct {
    name:string, // "Unreal maps": its filter in the file dialog and in messages, and the importer its packages record
    version:u16, // the format version its run gives importer.import_version: a build is found by it without the source
    extensions:[importer.FORMAT_EXTENSIONS]string, // lower case, with the dot, "" after the last
    claims:proc(path:string,head:[]u8) -> bool,    // head: up to importer.SNIFF_BYTES from the start of the file
    // Before the import starts: what run needs, in allocator; nil for
    // nothing. library, root and info as Import_Format_Provider.prepare has them.
    prepare:proc(library:^store.Store,root:string,info:^core.World_Info,allocator:mem.Allocator) -> rawptr,
    // In the thread of the import, with a job system of its own in
    // options.worker. scene: the scene it wrote, in allocator, "" for none.
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

// What import_library holds until its release.
@(private="file")
Import_Library_Held :: struct {
    library:host.Project_Library,
    providers:[]Import_Format_Provider,
    formats:[]importer.Format,
    importers:[]Source_Importer,
    wholes:[]sources.Whole_Source,
    allocator:mem.Allocator,
}

// The formats of models and the importers of whole sources the plugins of
// the project at root add, prepared with the store s, and the types of its
// game, from the library of its editor (sources.Library): what the import
// program of the engine refreshes and imports its sources with.
import_library :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> (imports:sources.Library_Imports) {
    path:=project.project_library(root,"editor",context.temp_allocator)
    if !os.is_file(path) {
        imports.problem="the project has no built editor library, where the importers of its plugins and the types of its game are: mirai build editor builds it"
        return
    }
    held:=new(Import_Library_Held,allocator)
    held.allocator=allocator
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    library,error:=host.project_library_load(path)
    if error!=.None {
        imports.problem=host.library_error_text(error,path)
        return
    }
    held.library=library
    found:[PROVIDER_CAPACITY]Import_Format_Provider
    held.providers=slice.clone(found[:provided_in(&held.library.info,found[:])],allocator)
    held.formats=make([]importer.Format,len(held.providers),allocator)
    for provider,i in held.providers {
        held.formats[i]=provider.format
        if provider.prepare!=nil {held.formats[i].data=provider.prepare(s,root,&held.library.info,allocator)}
    }
    claimed:[PROVIDER_CAPACITY]Import_Source_Provider
    plugins:[PROVIDER_CAPACITY]string
    count:=provided_in(&held.library.info,claimed[:],plugins[:])
    held.importers=make([]Source_Importer,count,allocator)
    held.wholes=make([]sources.Whole_Source,count,allocator)
    engine:=project.engine_root_find("",context.temp_allocator)
    for provider,i in claimed[:count] {
        held.importers[i]=provider.source
        held.wholes[i]={name=provider.source.name,version=provider.source.version,claims=provider.source.claims,run=provider.source.run,code=plugin_code(root,engine,plugins[i])}
        if provider.source.prepare!=nil {held.wholes[i].state=provider.source.prepare(s,root,&held.library.info,allocator)}
    }
    imports.formats=held.formats
    imports.wholes=held.wholes
    imports.world=&held.library.info
    imports.state=held
    imports.release=proc(state:rawptr) {
        held:=(^Import_Library_Held)(state)
        for provider,i in held.providers {
            if provider.prepare!=nil && provider.release!=nil {provider.release(held.formats[i].data,held.allocator)}
        }
        for source,i in held.importers {
            if source.prepare!=nil && source.release!=nil {source.release(held.wholes[i].state,held.allocator)}
        }
        host.project_library_unload(&held.library)
    }
    return
}

// import_library of the project at root with the library of its editor
// built first from its files as they are, against the binaries of the engine
// this program runs, its packages left for the caller to refresh: what a join
// refreshes the packages that just arrived with. problem: why it could not be
// built, and what to do.
import_library_built :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> sources.Library_Imports {
    opened,open_error:=project.open(root,project.engine_root_find("",context.temp_allocator))
    if open_error.code!=.None {
        return {problem=fmt.aprintf("the library of its editor, where the importers of its plugins are, could not be built: %s",project.error_text(root,open_error,context.temp_allocator),allocator=allocator)}
    }
    defer project.close(&opened)
    runs,_:=os.get_executable_directory(context.temp_allocator)
    job:=build.job_run({project=&opened,target=.Editor,dev=build.ENGINE_MODE_HERE==.Dev,engine=build.ENGINE_MODE_HERE,runs=runs,store_root=s.root,refresh_skip=true})
    defer build.job_destroy(job)
    if result:=&job.result;result.status==.Failed {
        text:=result.text
        for d in result.diagnostics {
            if d.severity==.Error {text=fmt.tprintf("%s(%d:%d) %s",d.file,d.line,d.column,d.message);break}
        }
        if text=="" {text=fmt.tprintf("%v",result.failure)}
        return {problem=fmt.aprintf("the library of its editor, where the importers of its plugins are, could not be built (%s): fix that and run mirai build editor %s",text,root,allocator=allocator)}
    }
    return import_library(root,s,allocator)
}

// The importer of a plugin that claims source whole, with the identity of
// the code of that plugin.
@(private)
import_whole :: proc(s:^Session,source:string) -> (whole:Source_Importer,code:u64,claimed:bool) {
    if importer.unsafe_path(source) || os.is_dir(source) {return}
    buffer:[importer.SNIFF_BYTES]u8
    head,_,error:=serial.file_read_head(source,buffer[:])
    if error!=.None {return}
    found:[PROVIDER_CAPACITY]Import_Source_Provider
    plugins:[PROVIDER_CAPACITY]string
    for provider,i in found[:provided_all(s,found[:],plugins[:])] {
        if provider.source.claims!=nil && provider.source.run!=nil && provider.source.claims(source,head) {return provider.source,plugin_code(s.project_root,s.engine_root,plugins[i]),true}
    }
    return
}

// sources.code_identity of the plugin named plugin of the project at root; 0
// when the project or the plugin is not found.
@(private="file")
plugin_code :: proc(root,engine_root,plugin:string) -> u64 {
    opened,error:=project.open(root,engine_root,context.temp_allocator)
    if error.code!=.None {return 0}
    index,found:=project.plugin_find(opened.plugins,plugin)
    return sources.code_identity(opened.plugins[index].folder) if found else 0
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
    images,sounds,fonts:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    image_extensions,sound_extensions,font_extensions:=sources.IMAGE_EXTENSIONS,sources.SOUND_EXTENSIONS,sources.FONT_EXTENSIONS
    filters:=make([dynamic]platform.Dialog_Filter,context.temp_allocator)
    append(&filters,
        platform.Dialog_Filter{"Models",strings.to_string(models)},{"Images",dialog_patterns(image_extensions[:],&images)},{"Sounds",dialog_patterns(sound_extensions[:],&sounds)},
        {"Fonts",dialog_patterns(font_extensions[:],&fonts)},{"Prompt packs","json"},
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
    if answer.tag==DIALOG_IMPORT && answer.state==.Accepted {import_file(s,answer.path,folder=import_place(s),ask=true)}
    if answer.tag==DIALOG_AI_REFERENCE && answer.state==.Accepted {ai_reference_add(s,answer.path)}
    for event in platform.input_events(p) {
        if drop,dropped:=event.(platform.Drop_Event);dropped {
            path:=platform.input_dropped(p,int(drop.index))
            if path=="" {continue}
            // An image dropped on the chat is a reference for the next message, not an asset.
            if ai_chat_holds(s.ai,drop.position) && ai_reference_image(path) {
                ai_reference_add(s,path)
                continue
            }
            import_file(s,path,folder=import_place(s),ask=true)
        }
    }
}
