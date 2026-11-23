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
// --project, else the one whose assets hold the file, else none. Its cache
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
IMPORT_USAGE :: "Usage: mirai import <file> [--uncompressed|--blocks] [--rdo-lambda L] [--srgb|--normal|--normal-green-down|--data] [--alpha-coverage C] [--lods auto|none] [--parts auto|all|none] [--front auto|negative_z|z|x|negative_x] [--rig source|humanoid|fox|horse|bird|dragon|kaiju|shark|snake|spider] [--rig-crotch M] [--rig-neck M] [--skeleton <id>] [--sound lossless|file] [--project <root>] [--folder <folder>] [--rebuild] [--discard-changes] [--final] [--store <folder>] [--profile] [--release] | mirai import --refresh <root> [--refresh <root>...] [--final] [--store <folder>] [--from <folder>] [--release]"

// library reads the formats and the importers of whole sources the plugins of
// a project add and the types of its game (in the import program of the
// engine, editor.import_library).
command :: proc(args:[]string,output,errors:io.Writer,library:Library=nil) -> int {
    file:string
    options:=importer.Import_Options{fast_textures=true}
    roots:=make([dynamic]string,context.temp_allocator) // of --refresh
    root:string   // of --project
    folder:Maybe(string) // of --folder
    profiled:bool
    store_root:string // of the store whose caches keep what imports build; "": that of the machine
    from_root:string  // of --from
    // What the options change of the settings the source has.
    Change :: enum {Textures,Rdo_Lambda,Image,Alpha_Coverage,Lods,Parts,Front,Rig,Rig_Crotch,Rig_Neck,Skeleton,Sound}
    given:importer.Import_Settings
    changed:bit_set[Change]
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
        case "--srgb","--normal","--normal-green-down","--data":
            if .Image in changed {fmt.wprintln(errors,"mirai import: an image is one of --srgb, --normal, --normal-green-down or --data; pass only one");return 2}
            switch args[at] {
            case "--srgb": given.image=.Color
            case "--normal": given.image=.Normal
            case "--normal-green-down": given.image=.Normal_Green_Down
            case: given.image=.Data
            }
            changed+={.Image}
        case "--sound":
            text:string
            text,ok=value(args,&at)
            switch text {
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
            if file!="" {fmt.wprintln(errors,IMPORT_USAGE);return 2}
            file=args[at]
        }
        if !ok {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    }
    // Nothing to import is a misuse, whatever the store says.
    if len(roots)==0 && file=="" {fmt.wprintln(errors,IMPORT_USAGE);return 2}
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
        if file!="" || root!="" || folder!=nil || changed!={} || options.changed!=.Refuse {fmt.wprintln(errors,IMPORT_USAGE);return 2}
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
        return refresh_command(roots[:],library_options,output,errors)
    }
    if from_root!="" {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    if file=="" {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    origin:=importer.path_key(file)
    // The project it is added to, and where under its assets.
    if root=="" {root,_=importer.source_root(origin,context.temp_allocator)}
    if root!="" {
        root=project.path_absolute(root,context.temp_allocator)
        library_options.root=root
    } else if folder!=nil {
        fmt.wprintln(errors,"mirai import: --folder is a folder of the assets of a project: give it with --project")
        return 2
    }
    formats:=FORMATS[:]
    kind:=source_kind(origin)
    plugins:Library_Imports
    defer if plugins.release!=nil {plugins.release(plugins.state)}
    if (kind==.None || kind==.Model) && library!=nil && root!="" {
        plugins=library(root,options.store,context.temp_allocator)
        library_options.imports=&plugins
        all:=make([dynamic]importer.Format,0,len(FORMATS)+len(plugins.formats),context.temp_allocator)
        append(&all,..FORMATS[:])
        append(&all,..plugins.formats)
        formats=all[:]
        kind=source_kind(origin,formats)
        if _,claimed:=whole_find(plugins.wholes,origin);claimed {kind=.None}
    }
    if changed&{.Image,.Alpha_Coverage}!={} && kind!=.Image {fmt.wprintln(errors,"mirai import: --srgb, --normal, --normal-green-down, --data and --alpha-coverage apply only to images");return 2}
    if changed&{.Lods,.Parts,.Front,.Rig,.Rig_Crotch,.Rig_Neck,.Skeleton}!={} && kind!=.Model {fmt.wprintln(errors,"mirai import: --lods, --parts, --front, --skeleton and the --rig options apply only to models");return 2}
    if .Sound in changed && kind!=.Sound {fmt.wprintln(errors,"mirai import: --sound applies only to sounds (WAV, Ogg Vorbis)");return 2}

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
            if changed&{.Rig_Crotch,.Rig_Neck}!={} {fmt.wprintln(errors,"mirai import: --rig-crotch and --rig-neck go with --rig humanoid");return 2}
            chosen.rig_crotch,chosen.rig_neck=0,0
        }
        if chosen!=stored || !found {
            settings=new(importer.Import_Settings,context.temp_allocator)
            settings^=chosen
        }
    }
    profile:base.Profile
    started:=time.tick_now()
    if profiled && !importer.profile_begin(&profile,&options) {fmt.wprintln(errors,"mirai import: no memory for --profile");return 1}
    defer if profiled {profile_print(&profile,started,output);base.profile_destroy(&profile)}
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
    report,added,error:=project_ingest(root,origin,folder,library_options,settings)
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
refresh_command :: proc(roots:[]string,options:Library_Options,output,errors:io.Writer) -> int {
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
        report:=project_refresh(root,options)
        defer library_report_destroy(&report)
        if library_print(&report,root,output,errors)!=0 {code=1}
        if report.packages>0 {
            fmt.wprintfln(output,"%s: %d packages, %d ingested, %d builds fetched (%.1f s).",root,report.packages,report.ingested,report.fetched,time.duration_seconds(time.tick_since(started)))
        }
    }
    return code
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
