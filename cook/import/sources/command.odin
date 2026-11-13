package sources

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"

// The command mirai import, which the import program of the engine runs: it
// turns a model (OBJ, glTF, GLB, USD, FBX, or a format a plugin of the
// project adds), an image, a sound (WAV, Ogg Vorbis), a font (TrueType,
// OpenType), a manifest of prompts (<name>.prompts.json) or a source a plugin
// of the project imports whole in the assets folder of a project or a plugin
// into assets with import_source, as the editor does: a model also gets the
// prefab of its hierarchy.
// A source is imported with the settings its sidecar keeps (<file>.import),
// changed by the options given; the result is written back there with the id
// of each asset, so importing again without options gives the same assets.
// --rdo-lambda 0 encodes the blocks of textures for the least error and a
// higher lambda for smaller files. An asset whose file already is the one the
// import gives is kept as it is, unless --rebuild. An image imported for the
// first time without --srgb, --data or --normal holds what its name says
// (image_use). Only models and images have settings.
// --sync <root>, once per project or plugin, imports instead every source
// under it whose outputs in its imported folder are missing or stale (sync):
// what a checkout needs before it runs. --fast builds the textures of a sync
// or of an import Fast, as the editor imports them, unless the texture cache
// keeps them Final: what a build that does not cook takes.
// The report goes to output, one asset per line: id, kind, bytes and path, and
// under it, indented, what the asset holds; then the settings file and the
// warnings. How far a long import is goes to errors while it runs, and a
// failure as "mirai import: <file>: <reason>". A sync says each source it
// imports, and how far it is, in output.
// --profile adds the seconds each zone of the import took, summed over the
// threads that cooked it and on the thread that imports, and the time no zone
// of that thread covers.
// The import cooks on every core.
// Exit codes: 0 done, 1 failed, 2 misuse.

@(private="file")
IMPORT_USAGE :: "Usage: mirai import <file> [--uncompressed|--blocks] [--rdo-lambda L] [--srgb|--normal|--normal-green-down|--data] [--alpha-coverage C] [--lods auto|none] [--parts auto|all|none] [--front auto|negative_z|z|x|negative_x] [--rig source|humanoid|fox|horse|bird|dragon|kaiju|shark|snake|spider] [--rig-crotch M] [--rig-neck M] [--skeleton <id>] [--rebuild] [--fast] [--texture-cache <folder>] [--mesh-cache <folder>] [--profile] [--release]"

// library reads the formats and the importers of whole sources the plugins of
// a project add and the types of its game (in the import program of the
// engine, editor.import_library).
command :: proc(args:[]string,output,errors:io.Writer,library:Library=nil) -> int {
    file:string
    options:importer.Import_Options
    roots:=make([dynamic]string,context.temp_allocator) // of --sync
    profiled:bool
    // What the options change of the settings the source has.
    Change :: enum {Textures,Rdo_Lambda,Image,Alpha_Coverage,Lods,Parts,Front,Rig,Rig_Crotch,Rig_Neck,Skeleton}
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
        case "--sync":
            root:string
            if root,ok=value(args,&at);ok {append(&roots,root)}
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
        case "--texture-cache": options.texture_cache,ok=value(args,&at)
        case "--mesh-cache": options.mesh_cache,ok=value(args,&at)
        case "--profile": profiled=true
        case "--rebuild": options.rebuild=true
        case "--fast": options.fast_textures=true
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
    js:jobs.Job_System
    if !jobs.system_init(&js,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        fmt.wprintln(errors,"mirai import: the threads to cook on could not be started")
        return 1
    }
    defer jobs.system_destroy(&js)
    options.worker={system=&js,worker=jobs.OWNER}
    if len(roots)>0 {
        return sync_command(roots[:],options,library,output,errors)
    }
    if file=="" {fmt.wprintln(errors,IMPORT_USAGE);return 2}
    root,in_assets:=source_root(file,context.temp_allocator)
    if !in_assets {fmt.wprintfln(errors,"mirai import: %s is in no assets folder of a project or a plugin: move it beside what it makes, under assets/",file);return 1}
    options.root=root
    if options.texture_cache=="" {options.texture_cache=project.content_cache_path(root,project.TEXTURE_CACHE,context.temp_allocator)}
    if options.mesh_cache=="" {options.mesh_cache=project.content_cache_path(root,project.MESH_CACHE,context.temp_allocator)}
    formats:=FORMATS[:]
    kind:=source_kind(file)
    plugins:Library_Imports
    defer if plugins.release!=nil {plugins.release(plugins.state)}
    if (kind==.None || kind==.Model) && library!=nil {
        plugins=library(root,context.temp_allocator)
        options.world=plugins.world
        all:=make([dynamic]importer.Format,0,len(FORMATS)+len(plugins.formats),context.temp_allocator)
        append(&all,..FORMATS[:])
        append(&all,..plugins.formats)
        formats=all[:]
        kind=source_kind(file,formats)
        if _,claimed:=whole_find(plugins.wholes,file);claimed {kind=.None}
    }
    if changed&{.Image,.Alpha_Coverage}!={} && kind!=.Image {fmt.wprintln(errors,"mirai import: --srgb, --normal, --normal-green-down, --data and --alpha-coverage apply only to images");return 2}
    if changed&{.Lods,.Parts,.Front,.Rig,.Rig_Crotch,.Rig_Neck,.Skeleton}!={} && kind!=.Model {fmt.wprintln(errors,"mirai import: --lods, --parts, --front, --skeleton and the --rig options apply only to models");return 2}

    if kind==.Model || kind==.Image {
        stored,found,settings_error:=importer.settings_load(file)
        if settings_error.code!=.None {
            fmt.wprintfln(errors,"mirai import: %s: %s",file,settings_error.message)
            return 1
        }
        options.settings,options.ignore_stored=stored,true
        // An image with no settings yet holds what its name says, as in the editor.
        if kind==.Image && !found {options.image=image_use(file)}
        if .Textures in changed {options.textures=given.textures}
        if .Rdo_Lambda in changed {options.rdo_lambda=given.rdo_lambda}
        if .Image in changed {options.image=given.image}
        if .Alpha_Coverage in changed {options.alpha_coverage=given.alpha_coverage}
        if .Lods in changed {options.lods=given.lods}
        if .Parts in changed {options.parts=given.parts}
        if .Front in changed {options.front=given.front}
        if .Rig in changed {options.rig=given.rig}
        if .Rig_Crotch in changed {options.rig_crotch=given.rig_crotch}
        if .Rig_Neck in changed {options.rig_neck=given.rig_neck}
        if .Skeleton in changed {options.skeleton=given.skeleton}
        // The heights tell the fit of a person where the body is.
        if options.rig!=.Humanoid {
            if changed&{.Rig_Crotch,.Rig_Neck}!={} {fmt.wprintln(errors,"mirai import: --rig-crotch and --rig-neck go with --rig humanoid");return 2}
            options.rig_crotch,options.rig_neck=0,0
        }
    }
    profile:base.Profile
    started:=time.tick_now()
    if profiled && !importer.profile_begin(&profile,&options) {fmt.wprintln(errors,"mirai import: no memory for --profile");return 1}
    defer if profiled {profile_print(&profile,started,output);base.profile_destroy(&profile)}
    progress:importer.Progress
    importer.progress_begin(&progress,errors,filepath.base(file))
    options.progress=&progress
    report,error:=import_source(file,options,formats,plugins.wholes)
    if error.code!=.None {
        fmt.wprintfln(errors,"mirai import: %s: %s",file,error.message)
        return 1
    }
    defer importer.report_destroy(&report)
    written_print(output,report.assets[:])
    if report.saved!="" {fmt.wprintfln(output,"sidecar %s",report.saved)}
    for warning in report.warnings {fmt.wprintfln(output,"warning: %s",warning)}
    return 0
}

// --sync: every root in turn, one line each with what its sync did.
@(private="file")
sync_command :: proc(roots:[]string,options:importer.Import_Options,library:Library,output,errors:io.Writer) -> int {
    code:=0
    for root in roots {
        started:=time.tick_now()
        report:=sync(root,{texture_cache=options.texture_cache,mesh_cache=options.mesh_cache,rebuild=options.rebuild,fast_textures=options.fast_textures,worker=options.worker,library=library,progress=output})
        defer sync_report_destroy(&report)
        for warning in report.warnings {fmt.wprintfln(output,"warning: %s",warning)}
        for failure in report.failures {fmt.wprintfln(errors,"mirai import: %s",failure)}
        if len(report.failures)>0 {code=1}
        if report.sources>0 || report.removed>0 {
            fmt.wprintfln(output,"%s: %d of %d imported sources built again, %d stale files removed (%.1f s).",root,report.imported,report.sources,report.removed,time.duration_seconds(time.tick_since(started)))
        }
    }
    return code
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

// One line per asset written (id, kind, bytes and path) with what it holds
// under it, and how many there are.
@(private="file")
written_print :: proc(output:io.Writer,assets:[]importer.Written) {
    buffer:[32]u8
    kept:=0
    for written in assets {
        info,_:=asset.kind_info(written.kind)
        fmt.wprintfln(output,"%s %-8s %d %s",base.asset_id_format(written.id,buffer[:]),info.name,written.bytes,written.path)
        if written.detail!="" {fmt.wprintfln(output,"  %s",written.detail)}
        if written.kept {kept+=1}
    }
    if kept>0 {fmt.wprintfln(output,"%d assets, %d were already up to date",len(assets),kept)} else {fmt.wprintfln(output,"%d assets",len(assets))}
}
