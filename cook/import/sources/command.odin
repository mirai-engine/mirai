package sources

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

// The command mirai import, which the import program of the engine runs: it
// ingests a model (OBJ, glTF, GLB, USD, FBX, or a format a plugin of the
// project adds), an image, a sound (WAV, Ogg Vorbis), a font (TrueType,
// OpenType), a manifest of prompts (<name>.prompts.json) or a source a plugin
// of the project imports whole, from wherever it is, into the library of the
// machine store (ingest), and adds it to a project (project_add): the one of
// --project, else the one whose assets hold the file, else none. Several
// files are imported one after another in the one process, each with the
// options given and its own report: what a process makes ready (the import
// program, the plugins of the project, its peers) is made ready once. A file
// that fails is said and the others go on; the exit code is the worst. Its cache
// is listed under --folder of the project's assets (else the folder of the
// file under them, else the top), and its documents and the prefab of a
// model are written there.
// A source is ingested with the settings its package keeps, changed by the
// options given; ingesting again without options gives the same assets, and
// a source whose package is current is not imported again, unless --rebuild.
// --rdo-lambda 0 encodes the blocks of textures for the least error and a
// higher lambda for smaller files. A document the import writes over in the
// project that changed since it last wrote it stops the import, which names
// it, unless --discard-changes; a refresh leaves it as it is and warns. An
// image ingested for the first time without --srgb, --data or --normal holds
// what its name says (image_use). Only models, images and sounds have
// settings.
// --refresh <root>, once per project or plugin, instead brings every package
// its packages.mirai pins to a build this engine reads (project_refresh): what
// a checkout needs before it runs. It keeps the package when its source is
// missing and can finalize a current local build. A missing build names
// it. Textures are built Fast, as the editor imports them, unless the texture
// cache keeps them Final, and a Fast build is taken; --final builds them Final
// and takes only a Final build: what a release game build and the package of the
// engine take. --from <folder> names a second store a build this store lacks
// is copied from before it is built (cache.store_source), as a peer gives it;
// an installed engine takes the store of the builds of its plugins
// (project.ENGINE_STORE) unless another is given. The store is that of the
// machine, or the one at --store.
// The report goes to output, one asset per line: id, kind, bytes and path, and
// under it, indented, what the asset holds; then the package and the
// warnings. How far a long import is goes to errors while it runs, and a
// failure as "mirai import: <file>: <reason>". A refresh says each source it
// imports, and how far it is, in output.
// --profile adds the seconds each zone of the import took, summed over the
// threads that cooked it and on the thread that imports, and the time no zone
// of that thread covers.
// The import cooks on every core.
// Exit codes: 0 done, 1 failed, 2 misuse.

@(private="file")
IMPORT_USAGE :: "Usage: mirai import <file> [<file>...] [--uncompressed|--blocks] [--rdo-lambda L] [--srgb|--normal|--normal-green-down|--data] [--alpha-coverage C] [--lods auto|none] [--parts auto|all|none] [--front auto|negative_z|z|x|negative_x] [--rig source|humanoid|fox|horse|bird|dragon|kaiju|shark|snake|spider] [--rig-crotch M] [--rig-neck M] [--skeleton <id>] [--sound smallest|lossless|file] [--project <root>] [--folder <folder>] [--rebuild] [--discard-changes] [--final] [--store <folder>] [--profile] [--release] | mirai import --refresh <root> [--refresh <root>...] [--final] [--store <folder>] [--from <folder>] [--release]"

// library reads the formats and the importers of whole sources the plugins of
// a project add and the types of its game (in the import program of the
// engine, editor.import_library).
command :: proc(args:[]string,output,errors:io.Writer,library:Library=nil,peers:cache.Peers_Open=nil) -> int {
    files:=make([dynamic]string,context.temp_allocator)
    options:=importer.Import_Options{fast_textures=true}
    roots:=make([dynamic]string,context.temp_allocator) // of --refresh
    root:string   // of --project
    folder:Maybe(string) // of --folder
    profiled:bool
    store_root:string // of the store whose caches keep what imports build; "": that of the machine
    from_root:string  // of --from
    given:importer.Import_Settings
    changed:bit_set[Import_Change] // of the settings each source has
    at:=0
    value :: proc(args:[]string,at:^int) -> (string,bool) {
        at^+=1
        if at^>=len(args) {return "",false}
        return args[at^],true
    }
    for ;at<len(args);at+=1 {
        ok:=true
        switch args[at] {
        case "--refresh":
            refreshed:string
            if refreshed,ok=value(args,&at);ok {append(&roots,refreshed)}
        case "--project": root,ok=value(args,&at)
        case "--folder":
            path:string
            path,ok=value(args,&at)
            folder=path
        case "--skeleton":
            text:string
            if text,ok=value(args,&at);ok {
                parsed:bool
                if given.skeleton,parsed=base.asset_id_parse(text);!parsed {fmt.wprintln(errors,"mirai import: --skeleton needs the 32-hex-digit id of a skeleton of the project (32 zeros import the model whole)");return 2}
                changed+={.Skeleton}
            }
        case "--rdo-lambda":
            text:string
            text,ok=value(args,&at)
            if ok {
                lambda,parsed:=strconv.parse_int(text)
                if !parsed || lambda<0 || lambda>textures.RDO_LAMBDA_MAX {fmt.wprintfln(errors,"mirai import: --rdo-lambda needs an integer from 0 (the least error) to %d (the smallest files)",textures.RDO_LAMBDA_MAX);return 2}
                given.rdo_lambda=lambda if lambda>0 else -1
                changed+={.Rdo_Lambda}
            }
        case "--alpha-coverage":
            text:string
            text,ok=value(args,&at)
            if ok {
                cutoff,parsed:=strconv.parse_f64(text)
                if !parsed || !(cutoff>=0 && cutoff<=1) {fmt.wprintln(errors,"mirai import: --alpha-coverage needs the cutoff of the masked material, from 0 (none) to 1");return 2}
                given.alpha_coverage=f32(cutoff)
                changed+={.Alpha_Coverage}
            }
        case "--store": store_root,ok=value(args,&at)
        case "--from": from_root,ok=value(args,&at)
        case "--profile": profiled=true
        case "--rebuild": options.rebuild=true
        case "--discard-changes": options.changed=.Discard
        case "--final": options.fast_textures=false
        case "--uncompressed": given.textures=.Uncompressed;changed+={.Textures}
        case "--blocks": given.textures=.Blocks;changed+={.Textures}
        case "--srgb","--normal","--normal-green-down","--vectors","--data":
            if .Image in changed {fmt.wprintln(errors,"mirai import: an image is one of --srgb, --normal, --normal-green-down, --vectors or --data; pass only one");return 2}
            switch args[at] {
            case "--srgb": given.image=.Color
            case "--normal": given.image=.Normal
            case "--normal-green-down": given.image=.Normal_Green_Down
            case "--vectors": given.image=.Vectors
            case: given.image=.Data
            }
            changed+={.Image}
        case "--sound":
            text:string
            text,ok=value(args,&at)
            switch text {
            case "smallest": given.sound=.Smallest
            case "lossless": given.sound=.Lossless
            case "file": given.sound=.File
            case: ok=false
            }
            changed+={.Sound}
        case "--lods":
            text:string
            text,ok=value(args,&at)
            switch text {
            case "auto": given.lods=.Auto
            case "none": given.lods=.None
            case: ok=false
            }
            changed+={.Lods}
        case "--parts":
            text:string
            text,ok=value(args,&at)
            switch text {
            case "auto": given.parts=.Auto
            case "all":  given.parts=.All
            case "none": given.parts=.None
            case: ok=false
            }
            changed+={.Parts}
        case "--front":
            text:string
            text,ok=value(args,&at)
            if ok {given.front,ok=importer.front_from_name(text)}
            changed+={.Front}
        case "--rig":
            text:string
            text,ok=value(args,&at)
            if ok {given.rig,ok=importer.rig_from_name(text)}
            changed+={.Rig}
        case "--rig-crotch","--rig-neck":
            flag:=args[at]
            text:string
            text,ok=value(args,&at)
            if ok {
                height,parsed:=strconv.parse_f64(text)
                if !parsed || !(height>=0) || height-height!=0 {fmt.wprintfln(errors,"mirai import: %s needs a height in meters in the model, or 0 for the one the fit finds",flag);return 2}
                if flag=="--rig-crotch" {given.rig_crotch=f32(height);changed+={.Rig_Crotch}} else {given.rig_neck=f32(height);changed+={.Rig_Neck}}
            }
        case:
            if strings.has_prefix(args[at],"-") {fmt.wprintfln(errors,"mirai import: '%s' is not an option of import; a file that starts with '-' goes as ./%s\n%s",args[at],args[at],IMPORT_USAGE);return 2}
            append(&files,args[at])
        }
        if !ok {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    }
    // Nothing to import is a misuse, whatever the store says.
    if len(roots)==0 && len(files)==0 {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    js:jobs.Job_System
    if !jobs.system_init(&js,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        fmt.wprintln(errors,"mirai import: the threads to cook on could not be started")
        return 1
    }
    defer jobs.system_destroy(&js)
    options.worker={system=&js,worker=jobs.OWNER}
    if store_root=="" {store_root=store.default_root(context.temp_allocator)}
    kept:store.Store
    if store_root!="" {
        opened:store.Error
        if kept,opened=store.open(store_root,context.temp_allocator);opened!=.None {
            fmt.wprintfln(errors,"mirai import: the store at %s could not be opened (%v): pass another with --store",store_root,opened)
            return 1
        }
        options.store=&kept
    }
    gpu:textures.Gpu_Context
    defer textures.gpu_context_destroy(&gpu)
    library_options:=Library_Options{gpu=&gpu,store=options.store,fast_textures=options.fast_textures,rebuild=options.rebuild,changed=options.changed,plugins=library,worker=options.worker}
    if options.store==nil {fmt.wprintln(errors,"mirai import: this machine has no folder of user data for its store: pass one with --store");return 1}
    if len(roots)>0 {
        if len(files)>0 || root!="" || folder!=nil || changed!={} || options.changed!=.Refuse {fmt.wprintln(errors,IMPORT_USAGE);return 2}
        if from_root=="" {
            if engine:=project.engine_root_find("",context.temp_allocator);project.engine_installed(engine) {
                if bundled:=project.path(engine,project.ENGINE_STORE,allocator=context.temp_allocator);os.is_dir(bundled) {from_root=bundled}
            }
        }
        from:store.Store
        if from_root!="" {
            opened:store.Error
            if from,opened=store.open(from_root,context.temp_allocator);opened!=.None {
                fmt.wprintfln(errors,"mirai import: the store at %s could not be opened (%v): pass another with --from",from_root,opened)
                return 1
            }
            library_options.source=cache.store_source(&from)
        }
        return refresh_command(roots[:],library_options,peers,output,errors)
    }
    if from_root!="" {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    // Every file in turn in this one process, which made ready once what each
    // needs: the threads, the store, the textures of the GPU and, of a
    // project, its plugins and its peers. One that fails is said and the
    // others go on.
    run:=Import_Run{
        options=options,library_options=library_options,root=root,folder=folder,given=given,changed=changed,profiled=profiled,
        library=library,peers=peers,output=output,errors=errors,
    }
    defer import_project_end(&run)
    code,done:=0,0
    for file in files {
        result:=import_file(&run,file)
        code=max(code,result)
        if result==0 {done+=1}
    }
    if len(files)>1 {fmt.wprintfln(output,"%d of %d files imported",done,len(files))}
    return code
}

// What the options of a command change of the settings a source has.
@(private="file")
Import_Change :: enum {Textures,Rdo_Lambda,Image,Alpha_Coverage,Lods,Parts,Front,Rig,Rig_Crotch,Rig_Neck,Skeleton,Sound}

// What the files of a command are imported with: its options, and of the
// project of the last file its plugins and its peers, which the files of one
// project share.
@(private="file")
Import_Run :: struct {
    options:importer.Import_Options,
    library_options:Library_Options,
    root:string,          // of --project; "": that of each file
    folder:Maybe(string), // of --folder
    given:importer.Import_Settings,
    changed:bit_set[Import_Change],
    profiled:bool,
    library:Library,
    peers:cache.Peers_Open,
    output,errors:io.Writer,
    project:string,       // the root the plugins and the peers are of; "": none
    loaded:bool,          // plugins holds those of project
    plugins:Library_Imports,
    formats:[]importer.Format, // those of the engine and of plugins
    shared:cache.Source,
    close:cache.Peers_Close,
}

// Ends what the run holds of a project: its plugins, and its peers, saying what went each way.
@(private="file")
import_project_end :: proc(run:^Import_Run) {
    if run.plugins.release!=nil {run.plugins.release(run.plugins.state)}
    peers_said(run.output,run.project,run.shared,run.close)
    delete(run.project)
    run.project,run.loaded,run.plugins,run.formats,run.shared,run.close="",false,{},nil,{},nil
}

// One file of a command, as its options say: 0 done, 1 failed, 2 misuse.
@(private="file")
import_file :: proc(run:^Import_Run,file:string) -> int {
    output,errors,options,changed,given:=run.output,run.errors,run.options,run.changed,run.given
    library_options:=run.library_options
    origin:=importer.path_key(file)
    // The project it is added to, and where under its assets.
    root:=run.root
    if root=="" {root,_=importer.source_root(origin,context.temp_allocator)}
    if root!="" {
        root=project.path_absolute(root,context.temp_allocator)
        library_options.root=root
    } else if run.folder!=nil {
        fmt.wprintln(errors,"mirai import: --folder is a folder of the assets of a project: give it with --project")
        return 2
    }
    if root!=run.project {
        import_project_end(run)
        run.project=strings.clone(root)
        if root!="" {run.shared,run.close=peers_of(run.peers,options.store.root,root)}
    }
    formats:=FORMATS[:]
    kind:=source_kind(origin)
    if (kind==.None || kind==.Model) && run.library!=nil && root!="" {
        if !run.loaded {
            run.plugins=run.library(root,options.store,context.temp_allocator)
            run.loaded=true
            all:=make([dynamic]importer.Format,0,len(FORMATS)+len(run.plugins.formats),context.temp_allocator)
            append(&all,..FORMATS[:])
            append(&all,..run.plugins.formats)
            run.formats=all[:]
        }
        library_options.imports=&run.plugins
        formats=run.formats
        kind=source_kind(origin,formats)
        if _,claimed:=whole_find(run.plugins.wholes,origin);claimed {kind=.None}
    }
    if changed&{.Image,.Alpha_Coverage}!={} && kind!=.Image {fmt.wprintfln(errors,"mirai import: %s: --srgb, --normal, --normal-green-down, --data and --alpha-coverage apply only to images",file);return 2}
    if changed&{.Lods,.Parts,.Front,.Rig,.Rig_Crotch,.Rig_Neck,.Skeleton}!={} && kind!=.Model {fmt.wprintfln(errors,"mirai import: %s: --lods, --parts, --front, --skeleton and the --rig options apply only to models",file);return 2}
    if .Sound in changed && kind!=.Sound {fmt.wprintfln(errors,"mirai import: %s: --sound applies only to sounds (WAV, Ogg Vorbis)",file);return 2}

    // The settings the package keeps, changed by the options: given only when they change it.
    settings:^importer.Import_Settings
    if kind==.Model || kind==.Image || kind==.Sound {
        stored,found,settings_error:=importer.settings_load(options,origin)
        if settings_error.code!=.None {
            fmt.wprintfln(errors,"mirai import: %s: %s",file,settings_error.message)
            return 1
        }
        chosen:=stored
        // An image with no settings yet holds what its name says, as in the editor.
        if kind==.Image && !found {chosen.image=image_use(origin)}
        if .Textures in changed {chosen.textures=given.textures}
        if .Rdo_Lambda in changed {chosen.rdo_lambda=given.rdo_lambda}
        if .Image in changed {chosen.image=given.image}
        if .Alpha_Coverage in changed {chosen.alpha_coverage=given.alpha_coverage}
        if .Lods in changed {chosen.lods=given.lods}
        if .Parts in changed {chosen.parts=given.parts}
        if .Front in changed {chosen.front=given.front}
        if .Rig in changed {chosen.rig=given.rig}
        if .Rig_Crotch in changed {chosen.rig_crotch=given.rig_crotch}
        if .Rig_Neck in changed {chosen.rig_neck=given.rig_neck}
        if .Skeleton in changed {chosen.skeleton=given.skeleton}
        if .Sound in changed {chosen.sound=given.sound}
        // The heights tell the fit of a person where the body is.
        if chosen.rig!=.Humanoid {
            if changed&{.Rig_Crotch,.Rig_Neck}!={} {fmt.wprintfln(errors,"mirai import: %s: --rig-crotch and --rig-neck go with --rig humanoid",file);return 2}
            chosen.rig_crotch,chosen.rig_neck=0,0
        }
        if chosen!=stored || !found {
            settings=new(importer.Import_Settings,context.temp_allocator)
            settings^=chosen
        }
    }
    profile:base.Profile
    started:=time.tick_now()
    if run.profiled && !importer.profile_begin(&profile,&options) {fmt.wprintln(errors,"mirai import: no memory for --profile");return 1}
    defer if run.profiled {profile_print(&profile,started,output);base.profile_destroy(&profile)}
    library_options.worker=options.worker
    library_options.progress=errors
    if root=="" {
        report,error:=ingest(origin,library_options,settings)
        if error.code!=.None {
            fmt.wprintfln(errors,"mirai import: %s: %s",file,error.message)
            return 1
        }
        defer importer.report_destroy(&report)
        ingest_print(&report,output)
        return 0
    }
    if run.close!=nil {library_options.source=run.shared}
    report,added,error:=project_ingest(root,origin,run.folder,library_options,settings)
    defer library_report_destroy(&added)
    if error.code!=.None {
        fmt.wprintfln(errors,"mirai import: %s: %s",file,error.message)
        return 1
    }
    defer importer.report_destroy(&report)
    ingest_print(&report,output)
    return library_print(&added,root,output,errors)
}

// The assets an ingest wrote, its warnings and its package.
@(private="file")
ingest_print :: proc(report:^importer.Import_Report,output:io.Writer) {
    written_print(output,report.assets[:])
    for warning in report.warnings {fmt.wprintfln(output,"warning: %s",warning)}
    id:[base.ASSET_ID_TEXT]u8
    digits:[64]u8
    fmt.wprintfln(output,"package %s %s",base.asset_id_format(report.package_id,id[:]),store.hex(report.manifest,&digits))
}

// --refresh: every root in turn, one line each with what its refresh did.
@(private="file")
refresh_command :: proc(roots:[]string,options:Library_Options,peers:cache.Peers_Open,output,errors:io.Writer) -> int {
    code:=0
    seen:=make([dynamic]string,0,len(roots),context.temp_allocator)
    each: for root in roots {
        top:=project.path_absolute(root,context.temp_allocator)
        for earlier in seen {if project.path_same(earlier,top) {continue each}}
        append(&seen,top)
        started:=time.tick_now()
        options:=options
        options.root=top
        options.progress=output
        // The store of --from first: it is on this machine, and the peers' answers wait on the network.
        chain:=cache.Chain{first=options.source}
        shared,close:=peers_of(peers,options.store.root,top)
        if close!=nil {
            chain.second=shared
            options.source=cache.chain_source(&chain)
        }
        defer peers_said(output,root,shared,close)
        report:=project_refresh(root,options)
        defer library_report_destroy(&report)
        if library_print(&report,root,output,errors)!=0 {code=1}
        if report.packages>0 {
            fmt.wprintfln(output,"%s: %d packages, %d ingested, %d builds fetched (%.1f s).",root,report.packages,report.ingested,report.fetched,time.duration_seconds(time.tick_since(started)))
        }
    }
    return code
}

@(private="file")
peers_of :: proc(peers:cache.Peers_Open,store_root,root:string) -> (source:cache.Source,close:cache.Peers_Close) {
    if peers==nil {return}
    return peers(store_root,root)
}

// Ends what peers_of opened and says what went each way.
@(private="file")
peers_said :: proc(output:io.Writer,root:string,source:cache.Source,close:cache.Peers_Close) {
    if close==nil {return}
    taken,published:=close(source)
    fmt.wprintfln(output,"%s: kai: %d results taken from peers, %d published to them.",root,taken,published)
}

// The warnings, failures and missing packages of a report; 1 with any failure or package missing.
@(private="file")
library_print :: proc(report:^Library_Report,root:string,output,errors:io.Writer) -> int {
    for warning in report.warnings {fmt.wprintfln(output,"warning: %s",warning)}
    for failure in report.failures {fmt.wprintfln(errors,"mirai import: %s",failure)}
    for missing in report.missing {fmt.wprintfln(errors,"mirai import: %s: %s",root,missing)}
    return 1 if len(report.failures)>0 || len(report.missing)>0 else 0
}

// The zones of a profiled import (importer.profile_totals), each with its
// seconds summed over the threads and those on the thread that imports, and
// the wall time no zone of that thread covers.
@(private="file")
profile_print :: proc(profile:^base.Profile,started:time.Tick,output:io.Writer) {
    seconds:=time.duration_seconds(time.tick_since(started))
    totals,lost:=importer.profile_totals(profile,context.temp_allocator)
    fmt.wprintln(output,"profile (seconds summed over the threads, then on the thread that imports; a zone counts inside those that hold it):")
    for t in totals {fmt.wprintfln(output,"  %s%-24s %10.3f s %10.3f s %7d",strings.repeat("  ",t.depth,context.temp_allocator),t.name,t.seconds,t.owner,t.count)}
    fmt.wprintfln(output,"  %-24s %10.3f s","(no zone)",importer.profile_unzoned(totals,seconds))
    fmt.wprintfln(output,"  %-24s %10.3f s","(total)",seconds)
    if lost>0 {fmt.wprintfln(output,"  %d zones were lost: the rings hold %d each",lost,importer.PROFILE_ZONES)}
}

// One line per asset written (id, kind, bytes, and its path or its object of
// the store) with what it holds
// under it, and how many there are.
@(private="file")
written_print :: proc(output:io.Writer,assets:[]importer.Written) {
    buffer:[32]u8
    kept:=0
    for written in assets {
        info,_:=asset.kind_info(written.kind)
        digits:[64]u8
        at:=written.path if written.path!="" else fmt.tprintf("object %s",store.hex(written.object,&digits))
        fmt.wprintfln(output,"%s %-8s %d %s",base.asset_id_format(written.id,buffer[:]),info.name,written.bytes,at)
        if written.detail!="" {fmt.wprintfln(output,"  %s",written.detail)}
        if written.kept {kept+=1}
    }
    if kept>0 {fmt.wprintfln(output,"%d assets, %d were already up to date",len(assets),kept)} else {fmt.wprintfln(output,"%d assets",len(assets))}
}
