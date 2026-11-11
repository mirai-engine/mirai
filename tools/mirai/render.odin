package main

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import img "mirai:cook/image"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/subprocess"

RENDER_USAGE :: "render check [project] [--base main|<ref>|<checkout>|<report.json>|none] [--checkout C] [--views a,b] [--sizes WxH,...] [--rerun <report.json>] [--quality] [--release] [--fresh-base] [--wait S] [--allow-load] [--out folder] | render compare <base.json> <report.json>"

// mirai render check: the views of render_check.mirai of a project as its
// editor shows them, built dev (--release for the figures of the CPU, which
// an optimized build alone gives) and measured alone among the checkouts:
// the cost of the frame and of each GPU pass, how much the image changes
// between captures of a still view, its mean luminance and the captures. It
// measures the build of --base the same way, alternating the two, and fails
// when the frame costs RENDER_COST_LIMIT more, the image changes
// RENDER_STABILITY_LIMIT times as much or the luminance moves RENDER_LUMA_LIMIT
// stops, from the base or from the art direction of the view. A view that
// flies (Render_Fly) also measures how much brighter the image is right after
// flying than once settled there, the trail, judged as the change between
// captures, and the blotches of light it shows on smooth surfaces right after
// flying and RENDER_MOTTLE_AFTER frames later (img.image_mottle), judged the
// same way. A view that pushes an entity while its camera stays (Render_Push)
// measures how far the image is from the same pose settled midway through the
// push, judged as the change between captures, and how many frames after it
// stops the image takes to come within 10 % and 1 % of settled. It waits for
// the other programs of the engine to close and warns
// when something else loads the GPU. A cost past the limit is measured again
// alone, both builds alternating, before the verdict. The measures of a base
// built from a commit are saved for the next checks against it (Render_Saved).
// --quality measures all but the cost, which needs neither the machine alone
// nor the measurement lock: the headless editor draws every frame with the
// same dt, so the images do not depend on the load. The report and the
// captures go to --out.
// mirai render compare: the same verdicts between two reports.

RENDER_PLAN_FILE :: "render_check.mirai"
RENDER_COST_LIMIT :: 0.10     // a frame 10 % longer
RENDER_STABILITY_LIMIT :: 2.0 // twice the change between captures
RENDER_STABILITY_FLOOR :: 0.05 // luma MAE, over 0..255 of linear light, below which no change shows
RENDER_MOTTLE_FLOOR :: 0.1     // percent of the light below which no blotch shows
RENDER_MOTTLE_AFTER :: 10      // frames after a flight when the blotches are measured again
RENDER_LUMA_LIMIT :: 0.5      // stops
RENDER_GPU_BUSY :: 25         // percent of the GPU in use while the editor measured draws nothing; a desktop on a 4K display alone keeps it at 10-15
RENDER_TILES :: 4             // the region is split in RENDER_TILES² for the worst local change
RENDER_PORT :: 7970           // the first port tried for the editors measured
RENDER_TIMEOUT_MS :: 600000
RENDER_FLY_EVENTS :: 200      // editor.input events per call, within the API_INPUT_EVENTS of the editor
RENDER_WAIT :: 300            // seconds the check waits by default for the other programs of the engine to close
RENDER_KILL :: "taskkill /PID <pid> /F" when ODIN_OS==.Windows else "kill <pid>"
RENDER_SAVED :: "render-base" // the folder of the shared cache with the measures of the bases, a file per commit
RENDER_SAVED_VERSION :: 2     // of how a measure is taken and what it holds: a saved one of another version is not read
RENDER_SAVED_COST_HOURS :: 24 // a saved base gives the cost only this long after it was measured

Render_View :: struct {
    name,scene:string,
    position,target:[]f64,
    fov:f64,           // degrees, vertical; 0 keeps the camera of the editor
    play:[]json.Value, // play.step calls before the camera is placed, in order; "repeat" calls one that many times
    luma:f64,          // mean linear luminance its art direction gives the view; 0: none
    fly:Render_Fly,
    push:Render_Push,
}

// An entity of the scene pushed from one place to another while the camera
// of the view stays, as a body that is pushed or falls: one step a frame.
// The moves are edits of the document, which the check never saves.
Render_Push :: struct {
    entity:string,  // its id in the scene, in hexadecimal as the API gives it
    from,to:[]f64,  // its position, relative to its parent
    frames:int,     // 0: the view pushes nothing
    ev100:f64,      // manual exposure all along, so that only the light is compared and not the eye adapting
}

// Frames after a push stops when the image is captured and compared with
// the same pose settled.
RENDER_PUSH_AFTER :: [?]int{1, 2, 4, 8, 16, 32, 64, 128}

// A flight of the camera of the editor from the place of the view, as a
// person flies it: the right button held with keys, one frame each.
Render_Fly :: struct {
    keys:[]string, // held all along: W A S D Q E
    frames:int,    // 0: the view does not fly
    turn:[2]f64,   // mouse_delta of each frame, points
    ev100:f64,     // manual exposure all along, so that only the light is compared and not the eye adapting
}

Render_Plan :: struct {
    sizes:[][2]int,
    warmup:int,   // frames drawn before measuring
    frames:int,   // frames profile.capture records
    interval:int, // frames between two captures
    captures:int,
    views:[]Render_View,
}

Render_Pass :: struct {name:string,ms:f64}

Render_Measure :: struct {
    view:string,
    size:[2]int,
    render:[2]int,           // pixels the renderer drew
    frame_ms,frame_p95_ms:f64, // median and 95th percentile of the frame
    gpu_ms,cpu_ms:f64,       // means
    passes:[]Render_Pass,
    stability:f64,           // luma MAE between consecutive captures over the region
    stability_worst:f64,     // that of the tile that changes most
    luma:f64,                // mean linear luminance of the region in the first capture, 0..1
    luma_target:f64,
    flown:bool,              // the view flew: trail holds
    trail:f64,               // mean of how much brighter the image is right after flying than settled there, luma over 0..255 of linear light
    trail_map:string,        // that excess, amplified
    mottle:f64,              // blotches of light right after flying, percent of the light of the smooth surfaces
    mottle_after:f64,        // the same RENDER_MOTTLE_AFTER frames later
    mottle_map:string,       // those right after flying, amplified
    pushed:bool,             // the view pushed an entity: push_* hold
    push_error:f64,          // luma MAE midway through the push against the same pose settled
    push_step:f64,           // the same right after it stops, against where it stops settled
    push_settle:[2]int,      // frames after it stops until the image stays within 10 % and 1 % of push_step; -1: not within RENDER_PUSH_AFTER
    region:[4]int,           // x, y, w, h in pixels: the window less the bar and the panels
    images:[]string,
    diff_map:string,         // the change between the first two captures, amplified
    failure:string,          // why the view could not be measured
    scene_missing:bool,      // the build has no such scene
    memory_used_mb,memory_budget_mb:f64, // of the GPU, after the profile: what the editor holds and what the system lets it hold; 0: the driver does not say
}

// Of its budget of memory of the GPU, what the editor may hold while it measures: past it the
// system pages some of it out, and the passes that read what went out (a history, a target)
// cost several times as much, in one session and not in the next.
RENDER_MEMORY_SHARE :: 0.95

Render_Run :: struct {
    name:string, // head or base
    checkout,project,commit,editor:string,
    quality:bool,          // measured without the cost (--quality)
    dev:bool,              // built dev
    loaded:bool,           // something else loaded the GPU while it measured
    conditions:json.Value, // of the first profile.capture
    notes:[dynamic]string,
    measures:[dynamic]Render_Measure,
    repeats:[dynamic]Render_Measure, // the views whose cost was measured again, alone
}

Render_Verdict :: struct {
    view:string,
    size:[2]int,
    metric:string,  // cost, stability, stability_worst, trail, mottle, mottle_after, push, luma, art or base (the base did not measure it)
    base,head:f64,
    change:f64,     // cost: the fraction it grew; stability: head over base; luma, art: stops
    failed:bool,
    note:string,
    repeated:bool,  // cost: judged on the repeat
    first:[2]f64,   // cost: the frame of base and head the first time, when repeated
}

Render_Key :: struct {view:string,size:[2]int}

Render_Options :: struct {
    folder,base,checkout,views,sizes,out,rerun:string,
    wait:int, // seconds
    quality,fresh_base,allow_load,release:bool,
}

// A measure of a base saved in the shared cache, valid for the checks that
// would measure the same thing (render_base_key).
Render_Saved :: struct {
    key:string,
    date:i64,     // unix seconds
    quality:bool, // without the cost
    measure:Render_Measure,
}

Render_Program :: struct {pid:int,path,command:string}

Render_Report :: struct {
    project,date,device:string,
    warnings:[dynamic]string,
    runs:[dynamic]Render_Run,
    verdicts:[dynamic]Render_Verdict,
    regressions:int,
    failed_views:int,
}

Render_Target :: struct {name,checkout,project,editor:string}

Render_Editor :: struct {
    using headless:Headless_Editor,
    run:^Render_Run,
}

// The measurement lock, held while the cost is measured; owned: this process
// set MEASURE_ENV, and clears it when it lets the lock go.
Render_Alone :: struct {
    lock:workspace.Lock,
    owned:bool,
}

cmd_render :: proc(root:string,args:[]string) -> int {
    if len(args)>0 && args[0]=="check" {return render_check(root,args[1:])}
    if len(args)==3 && args[0]=="compare" {
        if code:=positionals_only("render compare",args[1:]);code!=0 {return code}
        return render_compare_files(args[1],args[2])
    }
    fmt.eprintfln("Usage: mirai %s",RENDER_USAGE)
    return 2
}

@(private="file")
render_check :: proc(root:string,args:[]string) -> int {
    o,problem:=render_options_parse(args)
    if problem!="" {fmt.eprintfln("mirai render: %s\nUsage: mirai %s",problem,RENDER_USAGE);return 2}
    // Both builds measure what the project asks for, not what this computer chose.
    _=os.set_env(project.SETTINGS_NO_MACHINE_ENV,"1")
    folder,out:=o.folder,o.out
    if !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai render: %s is not a project (%s is missing); pass the folder of the project",folder,project.PROJECT_FILE)
        return 2
    }
    folder=project.path_absolute(folder)
    relative,rel_error:=filepath.rel(root,folder,context.temp_allocator)
    if rel_error!=nil || strings.has_prefix(relative,"..") {
        fmt.eprintfln("mirai render: %s is not inside %s: the check measures a project of the engine",folder,root)
        return 2
    }
    relative,_=strings.replace_all(relative,"\\","/",context.temp_allocator)
    views,sizes:=o.views,o.sizes
    if o.rerun!="" {
        marked,marked_ok:=render_report_load(o.rerun)
        if !marked_ok {return 2}
        if marked.project!=relative {fmt.eprintfln("mirai render: %s is a check of %s, not of %s",o.rerun,marked.project,relative);return 2}
        names,marked_sizes:=render_flagged(marked)
        if len(names)==0 {fmt.printfln("mirai render: %s flagged no views: there is nothing to measure again",o.rerun);return 0}
        texts:=make([dynamic]string,context.temp_allocator)
        for size in marked_sizes {append(&texts,fmt.tprintf("%dx%d",size.x,size.y))}
        views,sizes=strings.join(names,","),strings.join(texts[:],",")
    }
    plan,plan_ok:=render_plan_load(folder,views,sizes)
    if !plan_ok {return 2}
    if out=="" {out=join(root,"bin","render-check",render_stamp(true))}
    out=project.path_absolute(out)
    if os.make_directory_all(out)!=nil && !os.is_dir(out) {fmt.eprintfln("mirai render: could not create %s",out);return 1}
    // One check at a time on the machine: the base checkout is shared.
    lock,_:=workspace.lock_acquire(workspace.lock_path(root,"render-check.lock",context.temp_allocator),fmt.tprintf("pid %d, mirai render check in %s",os.get_pid(),root),proc(holder:string) {
        fmt.eprintfln("mirai render: waiting for another check to finish (%s)",holder!=""?holder:"another process")
    })
    defer workspace.lock_release(&lock)
    if o.checkout=="" {
        if file,alive:=session_find(folder);alive {
            fmt.eprintfln("mirai render: a session of the project is open (pid %d) and holds the GPU and its port file; close it with mirai session stop %s",file.pid,relative)
            return 1
        }
    }
    if !o.quality && !o.allow_load && !render_wait_alone(o.wait) {return 1}

    report:Render_Report
    report.project=relative
    report.date=render_stamp(false)
    head:=Render_Target{name="head"}
    if o.checkout!="" {
        head.checkout=project.path_absolute(o.checkout)
        head.project=join(head.checkout,relative)
        head.editor=render_editor_program(head.checkout,o.release)
        if head.editor=="" {
            fmt.eprintfln("mirai render: %s has no built editor; build it there (mirai build editor %s%s)",head.checkout,relative,render_mode_flag(o.release))
            return 1
        }
    } else {
        head.checkout,head.project=root,folder
        mode:=Build_Mode.Release if o.release else .Dev
        if code,_,_:=build_project(root,.Editor,{folder},mode);code!=0 {return code}
        head.editor=project_engine_paths(root,folder,mode).editor_program
    }
    device:=render_device()
    base_target:Render_Target
    base_run:Maybe(Render_Run)
    // A base built from a commit: its measures are saved under it, and those
    // saved spare building and measuring it again.
    base_ref,base_commit:string
    cached:=make([dynamic]Render_Measure)
    missing:=make([dynamic]Render_Key)
    switch {
    case o.base=="none":
    case strings.has_suffix(o.base,".json"):
        loaded,ok:=render_report_load(o.base)
        if !ok {return 2}
        run,found:=render_run_named(loaded,"head")
        if !found {fmt.eprintfln("mirai render: %s has no head run",o.base);return 2}
        run.name="base"
        base_run=run
        if !o.quality && !run.quality && run.dev==o.release {
            append(&report.warnings,fmt.aprintf("%s was built %s and this check %s: the cost is not compared",o.base,render_mode_name(!run.dev),render_mode_name(o.release)))
        }
    case os.is_dir(o.base):
        base_target={name="base",checkout=project.path_absolute(o.base)}
        base_target.project=join(base_target.checkout,relative)
        base_target.editor=render_editor_program(base_target.checkout,o.release)
        if base_target.editor=="" {
            fmt.eprintfln("mirai render: %s has no built editor; build it there (mirai build editor %s%s)",base_target.checkout,relative,render_mode_flag(o.release))
            return 1
        }
    case:
        commit,resolved,same:=render_base_resolve(root,o.base)
        if !resolved {return 1}
        if same {
            append(&report.warnings,fmt.aprintf("the sources are those of %s: no base build, only the art direction",o.base))
        } else {
            base_ref,base_commit=o.base,commit
            saved:[dynamic]Render_Saved
            if device!="" && !o.fresh_base {saved=render_saved_load(render_saved_path(root,commit))}
            now:=time.time_to_unix(time.now())
            for size in plan.sizes {
                for view in plan.views {
                    m,found:=render_saved_find(saved[:],render_base_key(relative,device,plan,view,size,!o.release),o.quality,now)
                    if found {append(&cached,m)} else {append(&missing,Render_Key{view.name,size})}
                }
            }
            if len(missing)>0 {
                target,ok,_:=render_base_prepare(root,o.base,relative,o.release)
                if !ok {return 1}
                base_target=target
            } else {
                fmt.eprintfln("mirai render: the base %s (%s) is already measured in %s: it is neither built nor measured",o.base,commit[:10],render_saved_path(root,commit))
            }
        }
    }

    alone:Render_Alone
    if !o.quality {alone=render_alone_begin(root)}
    defer render_alone_end(&alone)
    layers_isolate(root)

    has_base:=base_target.editor!="" || base_ref!=""
    append(&report.runs,Render_Run{name="head",checkout=head.checkout,project=head.project,editor=head.editor,commit=render_commit(head.checkout),quality=o.quality,dev=!o.release})
    if has_base {
        commit:=base_target.checkout!=""?render_commit(base_target.checkout):base_commit[:10]
        append(&report.runs,Render_Run{name="base",checkout=base_target.checkout,project=base_target.project,editor=base_target.editor,commit=commit,quality=o.quality,dev=!o.release})
    }
    if run,loaded:=base_run.?;loaded {append(&report.runs,run)}
    targets:=[2]Render_Target{head,base_target}
    for size,s in plan.sizes {
        // The order alternates so that neither build always measures first.
        order:=s%2==0?[2]int{1,0}:[2]int{0,1}
        for i in order {
            if targets[i].editor=="" {continue}
            sub:=i==1 && base_ref!=""?render_plan_only(plan,missing[:],size):plan
            if len(sub.views)==0 {continue}
            if !render_session(&report,&report.runs[i],targets[i],sub,size,out,false) {
                fmt.eprintfln("mirai render: could not measure %s at %dx%d; see %s",targets[i].name,size.x,size.y,render_log(out,targets[i].name,size))
                return 1
            }
        }
    }
    fresh:=0
    if has_base {
        base:=&report.runs[1]
        fresh=len(base.measures)
        if len(cached)>0 {
            append(&base.measures,..cached[:])
            append(&base.notes,fmt.aprintf("%d of its measures are the ones saved in %s",len(cached),render_saved_path(root,base_commit)))
        }
    }
    render_judge(&report)

    // The cost of a view varies from one session to the next with what the
    // machine does: a cost past the limit is measured again, alone in a
    // session of each build, and the verdict is that of the repeat.
    if repeat:=render_repeat_list(report);len(repeat)>0 {
        if !has_base {
            append(&report.warnings,fmt.aprintf("the base is the report %s: the flagged cost was not measured again",o.base))
        } else {
            if targets[1].editor=="" {
                // The base was saved: built now, without holding the measurement while it compiles.
                render_alone_end(&alone)
                target,ok,_:=render_base_prepare(root,base_ref,relative,o.release)
                if !ok {return 1}
                targets[1]=target
                base:=&report.runs[1]
                base.checkout,base.project,base.editor=target.checkout,target.project,target.editor
                alone=render_alone_begin(root)
            }
            names:=make([dynamic]string,context.temp_allocator)
            for key in repeat {append(&names,fmt.tprintf("%s %dx%d",key.view,key.size.x,key.size.y))}
            fmt.eprintfln("mirai render: the cost of %s is past the limit: it is measured again, alone, with the two builds alternating",strings.join(names[:],", ",context.temp_allocator))
            for size,s in plan.sizes {
                sub:=render_plan_only(plan,repeat,size)
                if len(sub.views)==0 {continue}
                // The other build first this time.
                order:=s%2==0?[2]int{0,1}:[2]int{1,0}
                for i in order {
                    if !render_session(&report,&report.runs[i],targets[i],sub,size,out,true) {
                        fmt.eprintfln("mirai render: could not measure %s again at %dx%d; see %s",targets[i].name,size.x,size.y,render_log(out,fmt.tprintf("%s-repeat",targets[i].name),size))
                        return 1
                    }
                }
            }
            render_judge(&report)
        }
    }
    render_alone_end(&alone)
    if base_ref!="" && device!="" {render_base_save(root,report,base_commit,device,plan,fresh)}
    if report.device=="" {report.device=device}
    render_montages(&report,out)
    return render_finish(&report,join(out,"report.json"))
}

// The options of mirai render check; problem says what is wrong with them.
render_options_parse :: proc(args:[]string) -> (o:Render_Options,problem:string) {
    o.folder,o.base,o.wait=".","main",RENDER_WAIT
    wait:=""
    for i:=0;i<len(args);i+=1 {
        option:^string
        switch args[i] {
        case "--base":       option=&o.base
        case "--checkout":   option=&o.checkout
        case "--views":      option=&o.views
        case "--sizes":      option=&o.sizes
        case "--out":        option=&o.out
        case "--rerun":      option=&o.rerun
        case "--wait":       option=&wait
        case "--quality":    o.quality=true;continue
        case "--release":    o.release=true;continue
        case "--fresh-base": o.fresh_base=true;continue
        case "--allow-load": o.allow_load=true;continue
        }
        if option!=nil {
            if i+1>=len(args) || args[i+1]=="" {return o,fmt.tprintf("%s needs a value",args[i])}
            i+=1
            option^=args[i]
            continue
        }
        if strings.has_prefix(args[i],"-") {return o,fmt.tprintf("there is no option %s",args[i])}
        if o.folder!="." {return o,fmt.tprintf("one project only, not %s and %s",o.folder,args[i])}
        o.folder=args[i]
    }
    if wait!="" {
        seconds,valid:=strconv.parse_int(wait,10)
        if !valid || seconds<0 {return o,fmt.tprintf("--wait is seconds, 0 or more, not '%s'",wait)}
        o.wait=seconds
    }
    if o.rerun!="" && (o.views!="" || o.sizes!="") {return o,"--rerun picks the views and the sizes: leave out --views and --sizes"}
    return o,""
}

// Takes the measurement lock: other measurements and compilations wait, and
// the editors launched are part of this measurement (MEASURE_ENV).
@(private="file")
render_alone_begin :: proc(root:string) -> (alone:Render_Alone) {
    if workspace.measuring() {return}
    alone.lock=measure_lock(root,"render check")
    alone.owned=os.set_env(workspace.MEASURE_ENV,fmt.tprintf("%d",os.get_pid()))==nil
    return
}

@(private="file")
render_alone_end :: proc(alone:^Render_Alone) {
    workspace.lock_release(&alone.lock)
    if alone.owned {_=os.unset_env(workspace.MEASURE_ENV)}
    alone^={}
}

// The plan with only the views keys names at size.
render_plan_only :: proc(plan:Render_Plan,keys:[]Render_Key,size:[2]int) -> Render_Plan {
    only:=plan
    views:=make([dynamic]Render_View)
    for view in plan.views {
        if slice.contains(keys,Render_Key{view.name,size}) {append(&views,view)}
    }
    only.views=views[:]
    return only
}

// What a report marked: the views of its regressions and those it could not
// measure, and their sizes.
render_flagged :: proc(report:Render_Report) -> (views:[]string,sizes:[][2]int) {
    names:=make([dynamic]string)
    list:=make([dynamic][2]int)
    mark :: proc(names:^[dynamic]string,list:^[dynamic][2]int,view:string,size:[2]int) {
        if !slice.contains(names[:],view) {append(names,view)}
        if !slice.contains(list[:],size) {append(list,size)}
    }
    for v in report.verdicts {
        if v.failed {mark(&names,&list,v.view,v.size)}
    }
    if head,found:=render_run_named(report,"head");found {
        for m in head.measures {
            if m.failure!="" {mark(&names,&list,m.view,m.size)}
        }
    }
    return names[:],list[:]
}

// The views whose cost the verdicts call a regression and that were not
// measured again yet.
render_repeat_list :: proc(report:Render_Report) -> []Render_Key {
    list:=make([dynamic]Render_Key)
    for v in report.verdicts {
        if v.metric=="cost" && v.failed && !v.repeated && v.note=="" {append(&list,Render_Key{v.view,v.size})}
    }
    return list[:]
}

// The GPU of this machine as rhi names it (mirai doctor --probe-gpu, in a
// process of its own); empty when there is none.
@(private="file")
render_device :: proc() -> string {
    self,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return ""}
    state,printed,_,exec_error:=subprocess.exec({command={self,"doctor","--probe-gpu"}},context.temp_allocator)
    line:=strings.trim_space(string(printed))
    if exec_error!=nil || state.exit_code!=0 || !strings.has_prefix(line,"device=") {return ""}
    return strings.clone(line[len("device="):])
}

// Where the measures of the base at commit are saved, for every checkout of
// the repository.
@(private="file")
render_saved_path :: proc(root,commit:string) -> string {
    return join(workspace.cache_folder(root,RENDER_SAVED,context.temp_allocator),fmt.tprintf("%s.json",commit))
}

// What a measure of a build depends on besides its commit: the tool that
// takes it, the project, the GPU, the view, its size and the frames of the
// plan, and whether it was built dev. Two checks with the same key measure
// the same images.
render_base_key :: proc(project,device:string,plan:Render_Plan,view:Render_View,size:[2]int,dev:=false) -> string {
    Keyed :: struct {
        version:int,
        project,device:string,
        size:[2]int,
        warmup,frames,interval,captures:int,
        view:Render_View,
    }
    keyed:=Keyed{RENDER_SAVED_VERSION,project,device,size,plan.warmup,plan.frames,plan.interval,plan.captures,view}
    text,_:=json.marshal(keyed,{sort_maps_by_key=true},context.temp_allocator)
    return fmt.aprintf("%s%016x",dev?"dev-":"",hash.fnv64a(text))
}

@(private="file")
render_saved_load :: proc(path:string) -> (saved:[dynamic]Render_Saved) {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return}
    // One that cannot be read is measured again and written over.
    if json.unmarshal(data,&saved)!=nil {return {}}
    return
}

// The measure saved under key that serves a check: any one for the quality
// alone; with the cost, one that measured it less than
// RENDER_SAVED_COST_HOURS ago.
render_saved_find :: proc(saved:[]Render_Saved,key:string,quality:bool,now:i64) -> (m:Render_Measure,found:bool) {
    for entry in saved {
        if entry.key!=key {continue}
        if !quality && (entry.quality || now-entry.date>RENDER_SAVED_COST_HOURS*3600) {continue}
        return entry.measure,true
    }
    return
}

// Puts entry in place of the one saved with its key, unless that one has the
// cost and entry does not.
render_saved_merge :: proc(saved:^[dynamic]Render_Saved,entry:Render_Saved) {
    for &old in saved {
        if old.key!=entry.key {continue}
        if entry.quality && !old.quality {return}
        old=entry
        return
    }
    append(saved,entry)
}

// Saves what the base measured in this check (the first fresh measures and
// the repeats) for the next checks against commit: only when nothing else
// loaded the GPU and the checkout measured is that commit. A view the base
// has no scene for is saved too: it stays so in that commit.
@(private="file")
render_base_save :: proc(root:string,report:Render_Report,commit,device:string,plan:Render_Plan,fresh:int) {
    base,found:=render_run_named(report,"base")
    if !found || base.loaded || base.checkout=="" {return}
    if measured,_:=render_git(base.checkout,"rev-parse","HEAD");measured!=commit {return}
    path:=render_saved_path(root,commit)
    saved:=render_saved_load(path)
    now:=time.time_to_unix(time.now())
    count:=0
    for list in ([2][]Render_Measure{base.measures[:fresh],base.repeats[:]}) {
        for m in list {
            if m.failure!="" && !m.scene_missing {continue}
            for view in plan.views {
                if view.name!=m.view {continue}
                render_saved_merge(&saved,{key=render_base_key(report.project,device,plan,view,m.size,base.dev),date=now,quality=base.quality,measure=m})
                count+=1
            }
        }
    }
    if count==0 {return}
    text,_:=json.marshal(saved[:],{pretty=true},context.temp_allocator)
    folder:=filepath.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) || os.write_entire_file(path,text)!=nil {
        fmt.eprintfln("mirai render: could not save the base in %s",path)
    }
}

// The other programs of the engine open on the machine, but own: an editor
// or a player that draws loads the GPU and holds its memory.
@(private="file")
render_programs :: proc(own:int) -> []Render_Program {
    list:=make([dynamic]Render_Program,context.temp_allocator)
    pids,error:=os.process_list(context.temp_allocator)
    if error!=nil {return nil}
    for pid in pids {
        if pid==own || pid==os.get_pid() {continue}
        info,info_error:=os.process_info_by_pid(pid,{.Executable_Path},context.temp_allocator)
        if info_error!=nil || info.executable_path=="" {continue}
        name:=strings.to_lower(filepath.stem(filepath.base(info.executable_path)))
        if name!="mirai-editor" && name!="mirai-player" {continue}
        program:=Render_Program{pid=pid,path=info.executable_path,command=info.executable_path}
        if full,full_error:=os.process_info_by_pid(pid,{.Command_Line},context.temp_allocator);full_error==nil && full.command_line!="" {program.command=full.command_line}
        append(&list,program)
    }
    return list[:]
}

// Waits, at most limit seconds, until no other program of the engine is
// open: what one draws would be measured as the cost of this build. false
// when they are still open, with what to do about them.
@(private="file")
render_wait_alone :: proc(limit:int) -> bool {
    start:=time.tick_now()
    shown:=""
    for {
        programs:=render_programs(-1)
        if len(programs)==0 {return true}
        b:=strings.builder_make(context.temp_allocator)
        for program in programs {fmt.sbprintf(&b,"  pid %d: %s\n",program.pid,program.command)}
        list:=strings.to_string(b)
        if time.duration_seconds(time.tick_since(start))>=f64(limit) {
            fmt.eprintf("mirai render: other programs of the engine are still open, and they load the GPU being measured:\n%s",list)
            fmt.eprintfln("Close them (a session with mirai session stop <project>; another editor or player from its window or with %s) and run the check again. --allow-load measures anyway, with warnings and a cost that does not count; --quality does not depend on the load.",RENDER_KILL)
            return false
        }
        if list!=shown {
            fmt.eprintf("mirai render: waiting up to %d s for the other programs of the engine to close:\n%s",limit,list)
            shown=list
        }
        time.sleep(2*time.Second)
    }
}

// The time of now, UTC: for a folder name, or to read.
render_stamp :: proc(folder:bool) -> string {
    now:=time.now()
    y,mo,d:=time.date(now)
    h,mi,s:=time.clock_from_time(now)
    if folder {return fmt.aprintf("%04d%02d%02d-%02d%02d%02d",y,int(mo),d,h,mi,s)}
    return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d UTC",y,int(mo),d,h,mi,s)
}

// The plan of the project, with only the views and sizes asked for.
render_plan_load :: proc(folder,views,sizes:string) -> (plan:Render_Plan,ok:bool) {
    path:=project.path(folder,RENDER_PLAN_FILE,allocator=context.temp_allocator)
    data,error:=os.read_entire_file(path,context.allocator)
    if error!=nil {fmt.eprintfln("mirai render: %s is missing: the list of views the check measures",path);return}
    if json.unmarshal(data,&plan)!=nil {fmt.eprintfln("mirai render: %s is not JSON with sizes, warmup, frames, interval, captures and views",path);return}
    if sizes!="" {
        list:=make([dynamic][2]int)
        for text in strings.split(sizes,",",context.temp_allocator) {
            size,valid:=render_size_parse(text)
            if !valid {fmt.eprintfln("mirai render: --sizes is WxH sizes separated by commas, not '%s'",text);return}
            append(&list,size)
        }
        plan.sizes=list[:]
    }
    if views!="" {
        wanted:=strings.split(views,",",context.temp_allocator)
        kept:=make([dynamic]Render_View)
        for name in wanted {
            found:=false
            for view in plan.views {
                if view.name==name {append(&kept,view);found=true}
            }
            if !found {fmt.eprintfln("mirai render: %s has no view '%s'",path,name);return}
        }
        plan.views=kept[:]
    }
    switch {
    case len(plan.sizes)==0:    fmt.eprintfln("mirai render: %s: sizes is a list of [width, height]",path);return
    case len(plan.views)==0:    fmt.eprintfln("mirai render: %s: views is empty",path);return
    case plan.captures<2:       fmt.eprintfln("mirai render: %s: captures is 2 or more: the stability compares consecutive captures",path);return
    case plan.interval<1 || plan.frames<1 || plan.warmup<0: fmt.eprintfln("mirai render: %s: interval and frames are 1 or more, and warmup 0 or more",path);return
    }
    for size in plan.sizes {
        if size.x<64 || size.y<64 || size.x>4096 || size.y>4096 {fmt.eprintfln("mirai render: %s: the size %dx%d is not between 64 and 4096",path,size.x,size.y);return}
    }
    for view,i in plan.views {
        if view.name=="" || view.scene=="" {fmt.eprintfln("mirai render: %s: view %d needs name and scene",path,i+1);return}
        if len(view.position)!=len(view.target) || len(view.position)!=0 && len(view.position)!=3 {
            fmt.eprintfln("mirai render: %s: %s: position and target go together, with three numbers each",path,view.name)
            return
        }
        for step in view.play {
            if _,is_object:=step.(json.Object);!is_object {fmt.eprintfln("mirai render: %s: %s: each step of play is an object with the params of play.step",path,view.name);return}
        }
        if view.fly.frames<0 || view.fly.frames>0 && len(view.position)!=3 {
            fmt.eprintfln("mirai render: %s: %s: fly.frames is 0 or more, and a view that flies needs position and target",path,view.name)
            return
        }
        if view.push.frames<0 || view.push.frames==1 || view.push.frames>1 && (len(view.position)!=3 || len(view.push.from)!=3 || len(view.push.to)!=3 || view.push.entity=="") {
            fmt.eprintfln("mirai render: %s: %s: push.frames is 0, or 2 or more, and a view that pushes needs position and target, push.entity and push.from and push.to with three numbers each",path,view.name)
            return
        }
    }
    return plan,true
}

render_size_parse :: proc(text:string) -> (size:[2]int,ok:bool) {
    cut:=strings.index_byte(text,'x')
    if cut<=0 {return}
    w,w_ok:=strconv.parse_int(strings.trim_space(text[:cut]),10)
    h,h_ok:=strconv.parse_int(strings.trim_space(text[cut+1:]),10)
    return {w,h},w_ok && h_ok
}

// What selects the mode of a build on the command line, after the command: dev unless --release.
@(private)
render_mode_flag :: proc(release:bool) -> string {return " --release" if release else ""}

@(private)
render_mode_name :: proc(release:bool) -> string {return "release" if release else "dev"}

// The editor a checkout built in that mode: --release also where builds
// before the modes left it.
@(private="file")
render_editor_program :: proc(checkout:string,release:bool) -> string {
    if !release {
        candidate:=project.path(checkout,".mirai","engine","dev",strings.concatenate({"mirai-editor",project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator)
        return strings.clone(candidate) if os.is_file(candidate) else ""
    }
    for candidate in ([2]string{
        project.path(checkout,".mirai","engine","release",strings.concatenate({"mirai-editor",project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator),
        project.path(checkout,".mirai","engine",strings.concatenate({"mirai-editor",project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator),
    }) {
        if os.is_file(candidate) {return strings.clone(candidate)}
    }
    return ""
}

render_git :: proc(folder:string,args:..string) -> (out:string,ok:bool) {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,"git","-C",folder)
    append(&command,..args)
    state,stdout,_,error:=subprocess.exec({command=command[:]},context.allocator)
    return strings.trim_space(string(stdout)),error==nil && state.exit_code==0
}

render_same_folder :: proc(a,b:string) -> bool {
    x,_:=strings.replace_all(strings.trim_right(a,"/\\"),"\\","/",context.temp_allocator)
    y,_:=strings.replace_all(strings.trim_right(b,"/\\"),"\\","/",context.temp_allocator)
    return strings.equal_fold(x,y)
}

// The commit of a checkout, marked when its tracked files changed.
render_commit :: proc(checkout:string) -> string {
    commit,_:=render_git(checkout,"rev-parse","--short=10","HEAD")
    if changes,ok:=render_git(checkout,"status","--porcelain","--untracked-files=no");ok && changes!="" {return fmt.aprintf("%s+changes",commit)}
    return commit
}

// The commit of ref the check measures as its base. same: this checkout holds
// the sources of ref, so there is nothing to compare.
@(private="file")
render_base_resolve :: proc(root,ref:string) -> (commit:string,ok,same:bool) {
    ref:=ref
    // The pull requests land on the remote: a local main behind it is not main.
    if _,behind:=render_git(root,"merge-base","--is-ancestor",ref,strings.concatenate({"origin/",ref},context.temp_allocator));behind {
        ref=strings.concatenate({"origin/",ref})
    }
    found:bool
    commit,found=render_git(root,"rev-parse","--verify",strings.concatenate({ref,"^{commit}"},context.temp_allocator))
    if !found {fmt.eprintfln("mirai render: '%s' is neither a commit nor a branch; --base is a branch, a commit, a .json report or none",ref);return}
    ours,_:=render_git(root,"rev-parse","HEAD^{tree}")
    theirs,_:=render_git(root,"rev-parse",strings.concatenate({commit,"^{tree}"},context.temp_allocator))
    changes,_:=render_git(root,"status","--porcelain","--untracked-files=no")
    return commit,true,ours==theirs && changes==""
}

// The checkout of ref the check measures as its base, built in the mode of the
// check with its own tool: <main>/.worktrees/render-base, moved to the commit of ref. same:
// this checkout holds the sources of ref, so there is nothing to compare.
render_base_prepare :: proc(root,ref,relative:string,release:=false) -> (target:Render_Target,ok,same:bool) {
    commit,resolved,sources:=render_base_resolve(root,ref)
    if !resolved {return}
    if sources {return {},true,true}
    folder:=join(project.shared_root(root,context.temp_allocator),".worktrees","render-base")
    if !os.exists(folder) {
        if run(root,{"git","worktree","add","--quiet","--detach",folder,commit})!=0 {fmt.eprintfln("mirai render: git did not create the worktree %s",folder);return}
    } else if top,_:=render_git(folder,"rev-parse","--show-toplevel");!render_same_folder(top,folder) {
        // A folder left without its .git would move the checkout that holds it.
        fmt.eprintfln("mirai render: %s is not a worktree of the repository; remove it with rm -rf and run again",folder)
        return
    } else if _,moved:=render_git(folder,"checkout","--quiet","--detach","--force",commit);!moved {
        fmt.eprintfln("mirai render: %s did not move to %s; if it is not a worktree of the repository, remove it with git worktree remove or rm -rf",folder,commit)
        return
    }
    launcher:=join(folder,"mirai")
    if !os.is_file(launcher) {
        fmt.eprintfln("mirai render: %s has no ./mirai; build it by hand and pass its report or its checkout (--checkout)",ref)
        return
    }
    shell,_:=shell_executable()
    fmt.eprintfln("mirai render: building %s (%s) in %s",ref,commit[:10],folder)
    slashed,_:=strings.replace_all(launcher,"\\","/",context.temp_allocator)
    if run(folder,{shell,slashed,"build","editor",relative,"--release"} if release else {shell,slashed,"build","editor",relative})!=0 {fmt.eprintfln("mirai render: could not build the editor of %s",ref);return}
    target={name="base",checkout=folder,project=join(folder,relative),editor=render_editor_program(folder,release)}
    return target,target.editor!="",false
}

@(private="file")
render_log :: proc(out,name:string,size:[2]int) -> string {
    return join(out,fmt.tprintf("%s-%dx%d.log",name,size.x,size.y))
}

// Opens the editor of target at size, measures every view and closes it. A
// repeat goes to r.repeats, beside the first measures.
@(private="file")
render_session :: proc(report:^Render_Report,r:^Render_Run,target:Render_Target,plan:Render_Plan,size:[2]int,out:string,repeat:bool) -> bool {
    label:=repeat?fmt.tprintf("%s-repeat",target.name):target.name
    port:=RENDER_PORT
    e:=Render_Editor{run=r}
    defer headless_close(&e)
    if !headless_open(&e,"render",label,target.editor,target.project,target.checkout,render_log(out,label,size),size,&port) {return false}
    // The load matters only to the cost.
    if !r.quality {r.loaded||=render_load(report,e.process.pid,fmt.tprintf("%s at %dx%d, at the start",label,size.x,size.y),true)}
    defer if !r.quality {r.loaded||=render_load(report,e.process.pid,fmt.tprintf("%s at %dx%d, at the end",label,size.x,size.y),false)}
    measured:=time.now()
    defer if !r.quality && workspace.builds_since(target.checkout,measured) {
        append(&report.warnings,fmt.aprintf("%s at %dx%d: a build ran at low priority while it measured: the CPU cost may be noisy",label,size.x,size.y))
        r.loaded=true
    }
    folder:=join(out,label,fmt.tprintf("%dx%d",size.x,size.y))
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return false}
    measures:=repeat?&r.repeats:&r.measures
    for view in plan.views {
        m:=render_measure(&e,plan,view,size,folder)
        if !r.quality && m.memory_budget_mb>0 && m.memory_used_mb>RENDER_MEMORY_SHARE*m.memory_budget_mb {
            append(&report.warnings,fmt.aprintf("%s %dx%d %s: the editor held %.0f MB of the GPU with a budget of %.0f MB: the system pages memory out and the cost does not count",label,size.x,size.y,view.name,m.memory_used_mb,m.memory_budget_mb))
            r.loaded=true
        }
        switch {
        case m.failure!="":
            fmt.eprintfln("mirai render: %s %s: %s",label,view.name,m.failure)
        case r.quality:
            fmt.eprintfln("mirai render: %s %dx%d %s: stability %.3f (worst %.3f), luminance %.4f",label,size.x,size.y,view.name,m.stability,m.stability_worst,m.luma)
        case:
            fmt.eprintfln("mirai render: %s %dx%d %s: frame %.2f ms, GPU %.2f ms, stability %.3f (worst %.3f), luminance %.4f",label,size.x,size.y,view.name,m.frame_ms,m.gpu_ms,m.stability,m.stability_worst,m.luma)
        }
        if conditions,is_object:=r.conditions.(json.Object);is_object && report.device=="" {
            if device,is_string:=conditions["device"].(json.String);is_string {report.device=device}
        }
        append(measures,m)
    }
    Status :: struct {validation_errors,asset_errors:int}
    status:Status
    if text,ok:=render_call(&e,"engine.status",{});ok {_=json.unmarshal_string(text,&status)}
    if status.validation_errors>0 || status.asset_errors>0 {
        append(&r.notes,fmt.aprintf("%dx%d: %d validation errors and %d asset errors (engine.diagnostics describes them)",size.x,size.y,status.validation_errors,status.asset_errors))
    }
    return true
}

// One call; a build older than the check does not take every field: the
// call goes again without it, and the run says so.
@(private="file")
render_call :: proc(e:^Render_Editor,method:string,params:json.Object) -> (result:string,ok:bool) {
    params:=params
    for {
        response,err,called:=headless_call(e,method,params)
        if called {return response,true}
        if err.code==api.INVALID_PARAMS {
            MARK :: `unknown field "`
            if at:=strings.index(err.message,MARK);at>=0 {
                rest:=err.message[at+len(MARK):]
                field:=rest[:max(strings.index_byte(rest,'"'),0)]
                if field in params {
                    delete_key(&params,field)
                    note:=fmt.aprintf("%s does not take %s in this build: measured without it",method,field)
                    known:=false
                    for n in e.run.notes {known||=n==note}
                    if !known {append(&e.run.notes,note)}
                    continue
                }
            }
        }
        fmt.eprintfln("mirai render: %s: %s",method,api.error_text(err,context.temp_allocator))
        return "",false
    }
}

@(private="file")
render_vector :: proc(values:[]f64) -> json.Value {
    list:=make(json.Array,0,len(values),context.temp_allocator)
    for v in values {append(&list,json.Value(v))}
    return list
}

// The value with the whole numbers parsing gave as floats made integers: the
// params of the API that count take no fractions.
@(private="file")
render_integral :: proc(value:json.Value) -> json.Value {
    #partial switch v in value {
    case json.Float:
        if v==math.floor(v) && abs(v)<1e15 {return json.Integer(i64(v))}
    case json.Array:
        list:=make(json.Array,0,len(v),context.temp_allocator)
        for item in v {append(&list,render_integral(item))}
        return list
    case json.Object:
        object:=make(json.Object,len(v),context.temp_allocator)
        for key,item in v {object[key]=render_integral(item)}
        return object
    }
    return value
}

// A view of the plan: its scene (and its Play), its camera with the exposure
// of the scene, the frames that settle it, a profile, the captures and what
// they say.
@(private="file")
render_measure :: proc(e:^Render_Editor,plan:Render_Plan,view:Render_View,size:[2]int,folder:string) -> (m:Render_Measure) {
    m.view,m.size,m.luma_target=view.name,size,view.luma
    params:=make(json.Object,context.temp_allocator)
    params["path"]=view.scene
    if _,ok:=render_call(e,"scene.open",params);!ok {
        m.scene_missing=!os.is_file(project.path(project.folder_path(e.run.project,.Assets,context.temp_allocator),view.scene,allocator=context.temp_allocator))
        m.failure=m.scene_missing?fmt.aprintf("this build has no scene %s",view.scene):"scene.open failed"
        return
    }
    playing:=false
    defer if playing {_,_=render_call(e,"play.stop",nil)}
    if len(view.play)>0 {
        if _,ok:=render_call(e,"play.start",nil);!ok {m.failure="play.start failed";return}
        playing=true
        for step in view.play {
            object:=render_integral(step).(json.Object)
            repeat:=1
            if count,has:=object["repeat"].(json.Integer);has {repeat=int(count)}
            delete_key(&object,"repeat")
            for _ in 0..<repeat {
                if _,ok:=render_call(e,"play.step",object);!ok {m.failure="play.step failed";return}
            }
        }
    }
    if len(view.position)==3 {
        camera:=make(json.Object,context.temp_allocator)
        camera["position"]=render_vector(view.position)
        camera["target"]=render_vector(view.target)
        if view.fov>0 {camera["fov"]=view.fov}
        camera["exposure"]="scene"
        if _,ok:=render_call(e,"camera.set",camera);!ok {m.failure="camera.set failed";return}
    }
    // The captures come a fixed count of frames after the camera was set,
    // which restarts the jitter of the view: profile.capture runs frames by
    // the clock until they stop getting faster, so the cost is recorded after them.
    if !headless_step(e,plan.warmup+plan.frames) {m.failure="engine.step failed";return}
    Status :: struct {render_width,render_height:int,gpu_memory:struct {used_mb,budget_mb:f64}}
    status:Status
    if status_text,ok:=render_call(e,"engine.status",nil);ok {_=json.unmarshal_string(status_text,&status)}
    m.render={status.render_width,status.render_height}
    m.memory_used_mb,m.memory_budget_mb=status.gpu_memory.used_mb,status.gpu_memory.budget_mb
    images:=make([dynamic]string)
    for i in 0..<plan.captures {
        path:=join(folder,fmt.tprintf("%s-%d.png",view.name,i+1))
        path,_=strings.replace_all(path,"\\","/")
        capture:=make(json.Object,context.temp_allocator)
        capture["path"]=path
        capture["ui"]=true
        capture["frames"]=json.Integer(i==0?1:plan.interval)
        if _,ok:=render_call(e,"capture",capture);!ok {m.failure="capture failed";return}
        append(&images,path)
    }
    m.images=images[:]
    Rects :: struct {window:struct {size:[2]f64},layout:struct {bar,left,right,bottom:[4]f64}}
    rects:Rects
    if inspect,ok:=render_call(e,"editor.inspect",nil);ok {_=json.unmarshal_string(inspect,&rects)}
    m.diff_map=join(folder,fmt.tprintf("%s-diff.png",view.name))
    m.diff_map,_=strings.replace_all(m.diff_map,"\\","/")
    region,measured:=render_images(&m,rects.window.size,rects.layout.bar,rects.layout.left,rects.layout.right,rects.layout.bottom)
    m.region={region.x,region.y,region.w,region.h}
    if !measured {m.failure="the captures could not be read or compared";return}
    if !e.run.quality {
        profile:=make(json.Object,context.temp_allocator)
        profile["frames"]=json.Integer(plan.frames)
        profile["advance"]=true
        profile["label"]=view.name
        profile["top"]=json.Integer(64)
        text,profiled:=render_call(e,"profile.capture",profile)
        if !profiled {m.failure="profile.capture failed";return}
        Summary :: struct {
            frame:struct {p50_ms,p95_ms,cpu_ms,gpu_ms:f64},
            gpu:[]struct {name:string,mean_ms:f64},
            conditions:json.Value,
        }
        summary:Summary
        if json.unmarshal_string(text,&summary)!=nil {m.failure="profile.capture gave no summary";return}
        m.frame_ms,m.frame_p95_ms,m.gpu_ms,m.cpu_ms=summary.frame.p50_ms,summary.frame.p95_ms,summary.frame.gpu_ms,summary.frame.cpu_ms
        passes:=make([]Render_Pass,len(summary.gpu))
        for pass,i in summary.gpu {passes[i]={pass.name,pass.mean_ms}}
        m.passes=passes
        if e.run.conditions==nil {e.run.conditions=summary.conditions}
    }
    if view.fly.frames>0 {
        free:=render_free_region(rects.window.size,int(rects.window.size.x),int(rects.window.size.y),rects.layout.bar,rects.layout.left,rects.layout.right,rects.layout.bottom)
        m.failure=render_fly(e,plan,view,folder,{f64(free.x)+0.5*f64(free.w),f64(free.y)+0.5*f64(free.h)},region,&m)
    }
    if view.push.frames>0 && m.failure=="" {m.failure=render_push(e,plan,view,folder,region,&m)}
    return
}

// Pushes the entity of the view a step a frame, capturing midway and
// RENDER_PUSH_AFTER frames after it stops, then lets the image settle where it
// stopped and midway: what each capture has against the same pose settled is
// what the histories leave behind a moving shadow, and how fast it goes.
@(private="file")
render_push :: proc(e:^Render_Editor,plan:Render_Plan,view:Render_View,folder:string,region:img.Region,m:^Render_Measure) -> string {
    push:=view.push
    camera:=make(json.Object,context.temp_allocator)
    camera["position"]=render_vector(view.position)
    camera["target"]=render_vector(view.target)
    if view.fov>0 {camera["fov"]=view.fov}
    camera["exposure"]="manual"
    camera["ev100"]=push.ev100
    if _,ok:=render_call(e,"camera.set",camera);!ok {return "camera.set failed before the push"}
    place :: proc(e:^Render_Editor,push:Render_Push,share:f64) -> bool {
        at:=make([]f64,3,context.temp_allocator)
        for i in 0..<3 {at[i]=push.from[i]+(push.to[i]-push.from[i])*share}
        moved:=make(json.Object,context.temp_allocator)
        moved["position"]=render_vector(at)
        entities:=make(json.Array,1,context.temp_allocator)
        entities[0]=moved
        params:=make(json.Object,context.temp_allocator)
        params["root"],params["entities"]=push.entity,entities
        _,ok:=render_call(e,"scene.write",params)
        return ok
    }
    capture :: proc(e:^Render_Editor,folder,name:string,frames:int) -> (path:string,ok:bool) {
        path,_=strings.replace_all(join(folder,name),"\\","/")
        params:=make(json.Object,context.temp_allocator)
        params["path"]=path
        params["ui"]=true
        params["frames"]=json.Integer(frames)
        _,ok=render_call(e,"capture",params)
        return
    }
    if !place(e,push,0) || !headless_step(e,plan.warmup) {return "the push could not start"}
    midway:=push.frames/2
    moving:string
    for k in 1..=push.frames {
        if !place(e,push,f64(k)/f64(push.frames)) {return "scene.write failed during the push"}
        if k==midway {
            ok:bool
            if moving,ok=capture(e,folder,fmt.tprintf("%s-push-moving.png",view.name),1);!ok {return "capture failed during the push"}
        } else if !headless_step(e,1) {return "engine.step failed during the push"}
    }
    frames:=RENDER_PUSH_AFTER
    after:[len(frames)]string
    for count,i in frames {
        ok:bool
        if after[i],ok=capture(e,folder,fmt.tprintf("%s-push-after-%d.png",view.name,count),count-(i>0?frames[i-1]:0));!ok {return "capture failed after the push"}
    }
    settled,settled_ok:=capture(e,folder,fmt.tprintf("%s-push-settled.png",view.name),plan.warmup)
    if !settled_ok {return "capture failed once the push settled"}
    if !place(e,push,f64(midway)/f64(push.frames)) {return "scene.write failed going back midway"}
    moving_settled,moving_ok:=capture(e,folder,fmt.tprintf("%s-push-moving-settled.png",view.name),plan.warmup)
    if !moving_ok {return "capture failed midway settled"}
    _=place(e,push,0)
    distance :: proc(a,b:string,region:img.Region) -> (mae:f64,ok:bool) {
        first,first_error:=img.image_load(a)
        defer img.image_destroy(&first)
        second,second_error:=img.image_load(b)
        defer img.image_destroy(&second)
        if first_error!=.None || second_error!=.None {return}
        diff,error:=img.image_diff(first,second,region)
        return diff.mae,error==.None
    }
    ok:bool
    if m.push_error,ok=distance(moving,moving_settled,region);!ok {return "the captures of the push could not be compared"}
    distances:[len(frames)]f64
    for path,i in after {
        if distances[i],ok=distance(path,settled,region);!ok {return "the captures of the push could not be compared"}
    }
    m.pushed,m.push_step=true,distances[0]
    m.push_settle={render_settle_frames(distances[:],frames[:],0.1),render_settle_frames(distances[:],frames[:],0.01)}
    return ""
}

// The first of frames after which every distance stays within share of the
// first one, or the floor no change shows below (RENDER_STABILITY_FLOOR); -1
// when the last one does not.
render_settle_frames :: proc(distances:[]f64,frames:[]int,share:f64) -> int {
    if len(distances)==0 {return -1}
    limit:=max(share*distances[0],RENDER_STABILITY_FLOOR)
    settled:=-1
    for i:=len(distances)-1;i>=0;i-=1 {
        if distances[i]>limit {break}
        settled=frames[i]
    }
    return settled
}

// Flies from the place of the view and captures right after and
// RENDER_MOTTLE_AFTER frames later, then settles there and captures again:
// what the first has over the last is the trail the histories leave behind a
// moving camera, and the blotches of the first two against the last are those
// of light that has not gathered its samples yet.
@(private="file")
render_fly :: proc(e:^Render_Editor,plan:Render_Plan,view:Render_View,folder:string,center:[2]f64,region:img.Region,m:^Render_Measure) -> string {
    fly:=view.fly
    camera:=make(json.Object,context.temp_allocator)
    camera["position"]=render_vector(view.position)
    camera["target"]=render_vector(view.target)
    if view.fov>0 {camera["fov"]=view.fov}
    camera["exposure"]="manual"
    camera["ev100"]=fly.ev100
    if _,ok:=render_call(e,"camera.set",camera);!ok {return "camera.set failed before the flight"}
    if !headless_step(e,plan.warmup) {return "engine.step failed before the flight"}
    keys:=make(json.Array,0,len(fly.keys),context.temp_allocator)
    for key in fly.keys {append(&keys,json.String(key))}
    right:=make(json.Array,0,1,context.temp_allocator)
    append(&right,json.String("right"))
    events:=make(json.Array,0,fly.frames+2,context.temp_allocator)
    press:=make(json.Object,context.temp_allocator)
    at:=center
    press["mouse_position"]=render_vector(at[:])
    press["mouse_buttons"]=right
    append(&events,press)
    for _ in 0..<fly.frames {
        held:=make(json.Object,context.temp_allocator)
        held["mouse_buttons"]=right
        held["keys"]=keys
        held["mouse_delta"]=render_vector(fly.turn[:])
        append(&events,held)
    }
    release:=make(json.Object,context.temp_allocator)
    release["mouse_buttons"]=make(json.Array,context.temp_allocator)
    release["keys"]=make(json.Array,context.temp_allocator)
    append(&events,release)
    for start:=0;start<len(events);start+=RENDER_FLY_EVENTS {
        chunk:=make(json.Array,0,RENDER_FLY_EVENTS,context.temp_allocator)
        append(&chunk,..events[start:min(start+RENDER_FLY_EVENTS,len(events))])
        input:=make(json.Object,context.temp_allocator)
        input["events"]=chunk
        if _,ok:=render_call(e,"editor.input",input);!ok {return "editor.input failed during the flight"}
    }
    paths:[3]string
    for name,i in ([3]string{"moving","after","settled"}) {
        if i==2 && !headless_step(e,plan.warmup) {return "engine.step failed after the flight"}
        path,_:=strings.replace_all(join(folder,fmt.tprintf("%s-%s.png",view.name,name)),"\\","/")
        capture:=make(json.Object,context.temp_allocator)
        capture["path"]=path
        capture["ui"]=true
        capture["frames"]=json.Integer(i==1?RENDER_MOTTLE_AFTER-1:1)
        if _,ok:=render_call(e,"capture",capture);!ok {return "capture failed during the flight"}
        paths[i]=path
    }
    images:[3]img.Image
    defer {for &image in images {img.image_destroy(&image)}}
    for path,i in paths {
        error:img.Error
        if images[i],error=img.image_load(path);error!=.None {return "the captures of the flight could not be read"}
    }
    trail_map:img.Image
    diff,error:=img.image_diff(images[0],images[2],region,img.DEFAULT_PIXEL_THRESHOLD,&trail_map)
    if error!=.None {return "the captures of the flight could not be compared"}
    defer img.image_destroy(&trail_map)
    m.flown,m.trail=true,diff.excess
    m.trail_map,_=strings.replace_all(join(folder,fmt.tprintf("%s-trail.png",view.name)),"\\","/")
    if img.image_write(m.trail_map,trail_map)!=.None {m.trail_map=""}
    mottle_map:img.Image
    moving,moving_error:=img.image_mottle(images[0],images[2],region,&mottle_map)
    if moving_error!=.None {return "the blotches of the flight could not be measured"}
    defer img.image_destroy(&mottle_map)
    after,after_error:=img.image_mottle(images[1],images[2],region)
    if after_error!=.None {return "the blotches of the flight could not be measured"}
    m.mottle,m.mottle_after=moving.mean,after.mean
    m.mottle_map,_=strings.replace_all(join(folder,fmt.tprintf("%s-mottle.png",view.name)),"\\","/")
    if img.image_write(m.mottle_map,mottle_map)!=.None {m.mottle_map=""}
    return ""
}

// The part of the window the bar and the panels leave to the scene, as the
// editor finds it (free_region), in pixels of an image width wide.
render_free_region :: proc(window:[2]f64,width,height:int,bar,left,right,bottom:[4]f64) -> img.Region {
    size:=window
    if size.x<=0 || size.y<=0 {size={f64(width),f64(height)}}
    x0,x1:=16.0,size.x-16
    y0,y1:=bar[3]+16,size.y-16
    if left[2]>0 && left[3]>0 {x0=max(x0,left[0]+left[2]+16)}
    if right[2]>0 && right[3]>0 {x1=min(x1,right[0]-16)}
    if bottom[2]>0 && bottom[3]>0 {y1=min(y1,bottom[1]-16)}
    if x1-x0<64 {x0,x1=16,size.x-16}
    if y1-y0<64 {y0,y1=bar[3]+16,size.y-16}
    scale:=f64(width)/size.x
    return {int(x0*scale),int(y0*scale),max(int((x1-x0)*scale),1),max(int((y1-y0)*scale),1)}
}

// Stability and luminance of the captures of m over the free region.
@(private="file")
render_images :: proc(m:^Render_Measure,window:[2]f64,bar,left,right,bottom:[4]f64) -> (region:img.Region,ok:bool) {
    images:=make([]img.Image,len(m.images))
    defer {for &image in images {img.image_destroy(&image)}}
    for path,i in m.images {
        error:img.Error
        images[i],error=img.image_load(path)
        if error!=.None {return}
    }
    first:=images[0]
    region=render_free_region(window,first.width,first.height,bar,left,right,bottom)
    if resolved,error:=img.region_resolve(first,region);error==.None {region=resolved} else {return}
    stats,stats_error:=img.image_stats(first,region)
    if stats_error!=.None {return}
    m.luma=f64(stats.mean_luma)
    tiles:[RENDER_TILES*RENDER_TILES]f64
    pairs:=0
    for i in 1..<len(images) {
        diff_map:img.Image
        diff,error:=img.image_diff(images[i-1],images[i],region,img.DEFAULT_PIXEL_THRESHOLD,i==1?&diff_map:nil)
        if error!=.None {return}
        if i==1 {
            if img.image_write(m.diff_map,diff_map)!=.None {m.diff_map=""}
            img.image_destroy(&diff_map)
        }
        m.stability+=diff.mae
        for &tile,t in tiles {
            tx,ty:=t%RENDER_TILES,t/RENDER_TILES
            area:=img.Region{region.x+tx*region.w/RENDER_TILES,region.y+ty*region.h/RENDER_TILES,region.w/RENDER_TILES,region.h/RENDER_TILES}
            local,local_error:=img.image_diff(images[i-1],images[i],area)
            if local_error!=.None {return}
            tile+=local.mae
        }
        pairs+=1
    }
    m.stability/=f64(pairs)
    for tile in tiles {m.stability_worst=max(m.stability_worst,tile/f64(pairs))}
    return region,true
}

// What else uses the GPU while the editor measured, idle, draws nothing:
// with programs, the other programs of the engine; with nvidia-smi, how busy
// the GPU is. loaded: either one.
render_load :: proc(report:^Render_Report,own:int,when_:string,programs:bool) -> (loaded:bool) {
    if programs {
        for program in render_programs(own) {
            append(&report.warnings,fmt.aprintf("%s: another program of the engine is open (pid %d, %s): it loads the GPU when it draws and holds its memory",when_,program.pid,program.path))
            loaded=true
        }
    }
    total,samples:=0,0
    for _ in 0..<10 {
        state,stdout,_,error:=subprocess.exec({command={"nvidia-smi","--query-gpu=utilization.gpu","--format=csv,noheader,nounits"}},context.temp_allocator)
        if error!=nil || state.exit_code!=0 {break}
        line:=strings.trim_space(string(stdout))
        if cut:=strings.index_byte(line,'\n');cut>=0 {line=strings.trim_space(line[:cut])}
        busy,valid:=strconv.parse_int(line,10)
        if !valid {break}
        total+=busy
        samples+=1
        time.sleep(200*time.Millisecond)
    }
    switch {
    case samples==0:
        note:="no nvidia-smi: whether another program uses the GPU was not measured"
        for w in report.warnings {if w==note {return}}
        append(&report.warnings,note)
    case total/samples>=RENDER_GPU_BUSY:
        append(&report.warnings,fmt.aprintf("%s: the GPU was %d %% busy while the check drew nothing: another program uses it and the measurement does not count",when_,total/samples))
        loaded=true
    }
    return
}

@(private="file")
render_run_named :: proc(report:Render_Report,name:string) -> (run:Render_Run,found:bool) {
    for r in report.runs {
        if r.name==name {return r,true}
    }
    return
}

@(private="file")
render_measure_find :: proc(list:[]Render_Measure,view:string,size:[2]int) -> (m:Render_Measure,found:bool) {
    for candidate in list {
        if candidate.view==view && candidate.size==size {return candidate,true}
    }
    return
}

@(private="file")
render_report_load :: proc(path:string) -> (report:Render_Report,ok:bool) {
    data,error:=os.read_entire_file(path,context.allocator)
    if error!=nil {fmt.eprintfln("mirai render: could not read %s",path);return}
    if json.unmarshal(data,&report)!=nil {fmt.eprintfln("mirai render: %s is not a report of mirai render check",path);return}
    return report,true
}

// The verdicts of head against base and against the art direction. The cost
// is judged where both measured it, on the repeat when both repeated it. A
// view the base has no scene for is not compared; one it failed to measure
// leaves the check without its answer, so it does not pass.
render_judge :: proc(report:^Render_Report) {
    clear(&report.verdicts)
    report.regressions,report.failed_views=0,0
    add :: proc(report:^Render_Report,verdict:Render_Verdict) {
        append(&report.verdicts,verdict)
        if verdict.failed {report.regressions+=1}
    }
    stops :: proc(a,b:f64) -> f64 {return math.log2(max(b,1e-6)/max(a,1e-6))}
    stability :: proc(report:^Render_Report,m:Render_Measure,metric:string,base,head:f64,floor:f64=RENDER_STABILITY_FLOOR) {
        ratio:=head/max(base,1e-6)
        add(report,{view=m.view,size=m.size,metric=metric,base=base,head=head,change=ratio,failed=ratio>RENDER_STABILITY_LIMIT && head-base>floor})
    }
    head,has_head:=render_run_named(report^,"head")
    if !has_head {return}
    base,has_base:=render_run_named(report^,"base")
    for m in head.measures {
        if m.failure!="" {report.failed_views+=1;continue}
        b,found:=render_measure_find(base.measures[:],m.view,m.size)
        if m.luma_target>0 {
            change:=stops(m.luma_target,m.luma)
            // Off its art direction in the base too, it is not this change.
            inherited:=found && b.failure=="" && abs(stops(m.luma_target,b.luma))>RENDER_LUMA_LIMIT
            add(report,{view=m.view,size=m.size,metric="art",base=m.luma_target,head=m.luma,change=change,failed=abs(change)>RENDER_LUMA_LIMIT && !inherited,note=inherited?"also in the base":""})
        }
        if !has_base {continue}
        if !found || b.failure!="" {
            if found && !b.scene_missing {report.failed_views+=1}
            add(report,{view=m.view,size=m.size,metric="base",note=found?fmt.aprintf("not measured in the base: %s",b.failure):"not measured: the base has no such view"})
            continue
        }
        if !head.quality && !base.quality && head.dev==base.dev {
            h,c:=m,b
            again,head_again:=render_measure_find(head.repeats[:],m.view,m.size)
            before,base_again:=render_measure_find(base.repeats[:],m.view,m.size)
            repeated:=head_again && base_again && again.failure=="" && before.failure==""
            if repeated {h,c=again,before}
            first:=repeated?[2]f64{b.frame_ms,m.frame_ms}:{}
            if c.render!=h.render {
                add(report,{view=m.view,size=m.size,metric="cost",base=c.frame_ms,head=h.frame_ms,failed=true,note=fmt.aprintf("they drew %dx%d and %dx%d: not comparable",c.render.x,c.render.y,h.render.x,h.render.y),repeated=repeated,first=first})
            } else {
                change:=h.frame_ms/max(c.frame_ms,1e-6)-1
                add(report,{view=m.view,size=m.size,metric="cost",base=c.frame_ms,head=h.frame_ms,change=change,failed=change>RENDER_COST_LIMIT,repeated=repeated,first=first})
            }
        }
        stability(report,m,"stability",b.stability,m.stability)
        stability(report,m,"stability_worst",b.stability_worst,m.stability_worst)
        if m.flown && b.flown {
            stability(report,m,"trail",b.trail,m.trail)
            stability(report,m,"mottle",b.mottle,m.mottle,RENDER_MOTTLE_FLOOR)
            stability(report,m,"mottle_after",b.mottle_after,m.mottle_after,RENDER_MOTTLE_FLOOR)
        }
        if m.pushed && b.pushed {stability(report,m,"push",b.push_error,m.push_error)}
        change:=stops(b.luma,m.luma)
        // Back to its art direction from a base away from it: the change mends it.
        mended:=m.luma_target>0 && abs(stops(m.luma_target,m.luma))<=RENDER_LUMA_LIMIT && abs(stops(m.luma_target,b.luma))>RENDER_LUMA_LIMIT
        add(report,{view=m.view,size=m.size,metric="luma",base=b.luma,head=m.luma,change=change,failed=abs(change)>RENDER_LUMA_LIMIT && !mended,note=mended?"back to its art direction":""})
    }
}

// The first capture of base and of head side by side, per view and size.
@(private="file")
render_montages :: proc(report:^Render_Report,out:string) {
    head,has_head:=render_run_named(report^,"head")
    base,has_base:=render_run_named(report^,"base")
    if !has_head || !has_base {return}
    for m in head.measures {
        for b in base.measures {
            if b.view!=m.view || b.size!=m.size || len(b.images)==0 || len(m.images)==0 {continue}
            if !os.is_file(b.images[0]) || !os.is_file(m.images[0]) {continue}
            path:=join(out,fmt.tprintf("%s-%dx%d.png",m.view,m.size.x,m.size.y))
            _,_=img.image_montage({b.images[0],m.images[0]},path)
        }
    }
}

// Writes the report and says what it found; 1 with a regression or a view
// that could not be measured.
@(private="file")
render_finish :: proc(report:^Render_Report,path:string) -> int {
    text,_:=json.marshal(report^,{pretty=true},context.temp_allocator)
    if os.write_entire_file(path,text)!=nil {fmt.eprintfln("mirai render: could not write %s",path)}
    head,_:=render_run_named(report^,"head")
    base,has_base:=render_run_named(report^,"base")
    fmt.printfln("Render check of %s on %s",report.project,report.device!=""?report.device:"an unnamed GPU")
    fmt.printfln("  head %s, built %s",head.commit,render_mode_name(!head.dev))
    if has_base {fmt.printfln("  base %s",base.commit!=""?base.commit:"(report)")}
    fmt.println()
    fmt.printfln("%-16s %-10s %-34s %-30s %s","view","size","frame ms (p50)","stability (luma MAE)","mean luminance")
    for m in head.measures {
        if m.failure!="" {fmt.printfln("%-16s %-10s not measured: %s",m.view,fmt.tprintf("%dx%d",m.size.x,m.size.y),m.failure);continue}
        cells:[3]string
        art:string
        cells[0]=head.quality?"no cost":fmt.tprintf("%.2f",m.frame_ms)
        cells[1]=fmt.tprintf("%.3f (worst %.3f)",m.stability,m.stability_worst)
        trail:=m.flown?fmt.tprintf("; trail %.3f",m.trail):""
        mottle:=m.flown?fmt.tprintf("; blotches %.2f %%, at %d frames %.2f %%",m.mottle,RENDER_MOTTLE_AFTER,m.mottle_after):""
        pushed:=m.pushed?fmt.tprintf("; push %.3f from settled, settles 90 %% in %d and 99 %% in %d frames",m.push_error,m.push_settle[0],m.push_settle[1]):""
        cells[2]=fmt.tprintf("%.4f",m.luma)
        for v in report.verdicts {
            if v.view!=m.view || v.size!=m.size {continue}
            mark:=v.failed?" REGRESSION":""
            switch v.metric {
            case "base":
                cells[0]=v.note
            case "cost":
                cells[0]=v.note!=""?fmt.tprintf("%s%s",v.note,mark):fmt.tprintf("%.2f → %.2f (%+.0f %%)%s",v.base,v.head,v.change*100,mark)
                if v.repeated {cells[0]=fmt.tprintf("%s; before %.2f → %.2f",cells[0],v.first[0],v.first[1])}
            case "stability":
                cells[1]=fmt.tprintf("%.3f → %.3f (×%.1f)%s",v.base,v.head,v.change,mark)
            case "luma":
                cells[2]=fmt.tprintf("%.4f → %.4f (%+.2f stops)%s",v.base,v.head,v.change,mark)
            case "art":
                art=fmt.tprintf("; art %.4f (%+.2f stops)%s",v.base,v.change,v.note!=""?fmt.tprintf(", %s",v.note):mark)
            case "stability_worst":
                if v.failed {cells[1]=fmt.tprintf("%s; worst %.3f → %.3f REGRESSION",cells[1],v.base,v.head)}
            case "trail":
                trail=fmt.tprintf("; trail %.3f → %.3f (×%.1f)%s",v.base,v.head,v.change,mark)
            case "mottle":
                mottle=fmt.tprintf("; blotches %.2f → %.2f %% (×%.1f)%s",v.base,v.head,v.change,mark)
            case "mottle_after":
                mottle=fmt.tprintf("%s, at %d frames %.2f → %.2f %% (×%.1f)%s",strings.split(mottle,", at ",context.temp_allocator)[0],RENDER_MOTTLE_AFTER,v.base,v.head,v.change,mark)
            case "push":
                pushed=fmt.tprintf("; push %.3f → %.3f from settled (×%.1f)%s, settles 90 %% in %d and 99 %% in %d frames",v.base,v.head,v.change,mark,m.push_settle[0],m.push_settle[1])
            }
        }
        fmt.printfln("%-16s %-10s %-34s %-30s %s%s%s%s%s",m.view,fmt.tprintf("%dx%d",m.size.x,m.size.y),cells[0],cells[1],cells[2],art,trail,mottle,pushed)
    }
    for run in report.runs {
        for note in run.notes {fmt.printfln("  %s: %s",run.name,note)}
    }
    if len(report.warnings)>0 {
        fmt.println()
        for warning in report.warnings {fmt.printfln("WARNING: %s",warning)}
    }
    fmt.println()
    fmt.printfln("Report: %s",path)
    fmt.println()
    for line in render_summary(report^) {fmt.println(line)}
    return report.failed_views>0 || report.regressions>0?1:0
}

// The end of what the check says: each view that regressed with every metric
// that did and its change, and the GPU pass that changed most; the views it
// could not measure or compare; and what that means for the change.
render_summary :: proc(report:Render_Report) -> []string {
    lines:=make([dynamic]string)
    head,_:=render_run_named(report,"head")
    base,_:=render_run_named(report,"base")
    regressed:=make([dynamic]Render_Key,context.temp_allocator)
    for v in report.verdicts {
        if v.failed && !slice.contains(regressed[:],Render_Key{v.view,v.size}) {append(&regressed,Render_Key{v.view,v.size})}
    }
    for key in regressed {
        b:=strings.builder_make()
        fmt.sbprintf(&b,"REGRESSION %s %dx%d:",key.view,key.size.x,key.size.y)
        first:=true
        for v in report.verdicts {
            if !v.failed || v.view!=key.view || v.size!=key.size {continue}
            fmt.sbprintf(&b,"%s %s",first?"":";",render_verdict_text(v))
            first=false
        }
        h,has_head:=render_measure_find(head.repeats[:],key.view,key.size)
        if !has_head {h,has_head=render_measure_find(head.measures[:],key.view,key.size)}
        c,has_base:=render_measure_find(base.repeats[:],key.view,key.size)
        if !has_base {c,has_base=render_measure_find(base.measures[:],key.view,key.size)}
        if has_head && has_base {
            if name,before,after,changed:=render_pass_change(c.passes,h.passes);changed {
                fmt.sbprintf(&b,"; the pass that changed most: %s, %.2f → %.2f ms (%+.2f)",name,before,after,after-before)
            }
        }
        append(&lines,strings.to_string(b))
    }
    for v in report.verdicts {
        if v.metric=="base" {append(&lines,fmt.aprintf("Not compared %s %dx%d: %s",v.view,v.size.x,v.size.y,v.note))}
    }
    for m in head.measures {
        if m.failure!="" {append(&lines,fmt.aprintf("Not measured %s %dx%d: %s",m.view,m.size.x,m.size.y,m.failure))}
    }
    if head.quality {append(&lines,"Quality only (--quality): stability, luminance, trail and blotches; the cost was neither measured nor judged.")}
    switch {
    case report.failed_views>0:
        append(&lines,fmt.aprintf("%d views were not measured: the check does not pass.",report.failed_views))
    case report.regressions>0:
        append(&lines,fmt.aprintf("%d regressions: the change is not accepted.",report.regressions))
    case len(report.warnings)>0:
        append(&lines,"No regressions, with the warnings above: if the GPU had another load, measure again without it.")
    case:
        append(&lines,"No regressions.")
    }
    return lines[:]
}

// A verdict as the summary says it.
@(private="file")
render_verdict_text :: proc(v:Render_Verdict) -> string {
    switch v.metric {
    case "cost":
        if v.note!="" {return fmt.tprintf("frame: %s",v.note)}
        text:=fmt.tprintf("frame %.2f → %.2f ms (%+.0f %%)",v.base,v.head,v.change*100)
        if v.repeated {text=fmt.tprintf("%s on the repeat; the first time %.2f → %.2f ms",text,v.first[0],v.first[1])}
        return text
    case "stability":       return fmt.tprintf("stability %.3f → %.3f (×%.1f)",v.base,v.head,v.change)
    case "stability_worst": return fmt.tprintf("worst tile %.3f → %.3f (×%.1f)",v.base,v.head,v.change)
    case "trail":           return fmt.tprintf("trail %.3f → %.3f (×%.1f)",v.base,v.head,v.change)
    case "mottle":          return fmt.tprintf("blotches %.2f → %.2f %% (×%.1f)",v.base,v.head,v.change)
    case "mottle_after":    return fmt.tprintf("blotches at %d frames %.2f → %.2f %% (×%.1f)",RENDER_MOTTLE_AFTER,v.base,v.head,v.change)
    case "push":            return fmt.tprintf("push %.3f → %.3f from settled (×%.1f)",v.base,v.head,v.change)
    case "luma":            return fmt.tprintf("luminance %.4f → %.4f (%+.2f stops)",v.base,v.head,v.change)
    case "art":             return fmt.tprintf("luminance %.4f against %.4f of its art direction (%+.2f stops)",v.head,v.base,v.change)
    }
    return v.metric
}

// The GPU pass whose time changed most from base to head, by name; one that
// only one of them draws counts from zero.
render_pass_change :: proc(base,head:[]Render_Pass) -> (name:string,before,after:f64,found:bool) {
    most:=-1.0
    time_of :: proc(passes:[]Render_Pass,name:string) -> (ms:f64,found:bool) {
        for pass in passes {
            if pass.name==name {return pass.ms,true}
        }
        return
    }
    for pass in head {
        ms,_:=time_of(base,pass.name)
        if abs(pass.ms-ms)>most {name,before,after,most,found=pass.name,ms,pass.ms,abs(pass.ms-ms),true}
    }
    for pass in base {
        if _,drawn:=time_of(head,pass.name);!drawn && pass.ms>most {name,before,after,most,found=pass.name,pass.ms,0,pass.ms,true}
    }
    return
}

// mirai render compare: the head run of a report against the head run of another.
@(private="file")
render_compare_files :: proc(base_path,head_path:string) -> int {
    base,base_ok:=render_report_load(base_path)
    head,head_ok:=render_report_load(head_path)
    if !base_ok || !head_ok {return 2}
    base_run,base_found:=render_run_named(base,"head")
    head_run,head_found:=render_run_named(head,"head")
    if !base_found || !head_found {fmt.eprintln("mirai render: both reports need a head run");return 2}
    base_run.name="base"
    report:=Render_Report{project=head.project,device=head.device,date=render_stamp(false)}
    append(&report.warnings,..head.warnings[:])
    append(&report.warnings,..base.warnings[:])
    append(&report.runs,head_run,base_run)
    render_judge(&report)
    return render_finish(&report,join(filepath.dir(head_path),"compare.json"))
}
