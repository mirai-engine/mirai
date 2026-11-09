package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/subprocess"

BENCH_USAGE :: "bench compare [project] [--base main|<ref>|<checkout>] [--scene S] [--camera x,y,z,tx,ty,tz[,fov]] [--size WxH] [--pairs N] [--frames N] [--warmup N] [--out folder]"

// mirai bench compare: the cost of the frames of a project in this checkout
// against --base, both built --release and measured alone among the checkouts
// in headless editors, which pace nothing and validate nothing. The two
// editors stay open and take turns, head, base, base, head..., so that what
// drifts while they measure (clocks, heat, the rest of the machine) falls on
// both. For the frame, the parts of the frame, the GPU passes and the
// functions that changed the most, the table has the median of the captures
// of each build with how much they spread, and the median of the differences
// of the pairs with their range. It warns when something else loads the GPU.
// The table goes to stdout and to --out, with the summaries of every capture.

BENCH_PAIRS :: 5
BENCH_FRAMES :: 240
BENCH_WARMUP :: 600         // frames each editor runs before its first capture: shaders, streaming and the light settle
BENCH_RESUME :: 60          // frames before every capture: the GPU comes back to speed after the other editor measured
BENCH_ZONES :: 12           // functions in the table: those that changed the most
BENCH_LINE :: 100           // characters of a line of prose in the table
BENCH_SIZE :: [2]int{1440,900}

Bench_Options :: struct {
    folder,base,scene,out:string,
    camera:[]f64, // position and target, and the vertical fov in degrees when there is a seventh
    size:[2]int,
    pairs,frames,warmup:int,
}

Bench_Section :: enum u8 {Frame,Parts,Passes,Zones}

BENCH_TITLES :: [Bench_Section]string{
    .Frame="Frame, ms",.Parts="CPU by part of the frame, ms",.Passes="GPU by pass, ms",
    .Zones="Functions that changed most, self time in ms",
}

// What the editor answers to profile.capture that the comparison reads.
Bench_Summary :: struct {
    frame:struct {p50_ms,p95_ms:f64},
    cpu:struct {
        ms:f64,
        parts:[]struct {name:string,mean_ms:f64},
        zones:[]struct {name,thread:string,self_ms:f64},
    },
    gpu:struct {
        mean_ms:f64,
        passes:[]struct {name:string,mean_ms:f64},
    },
}

// One measure across the captures: of head and of base, one per pair; NaN
// where that capture does not have it.
Bench_Row :: struct {
    section:Bench_Section,
    name,thread:string, // thread: of a function, main or workers
    values:[2][]f64,
}

Bench_Stat :: struct {
    median:f64,
    spread:f64, // the median of the distances to the median
    count:int,
}

Bench_Line :: struct {
    section:Bench_Section,
    name,thread:string,
    base,head:Bench_Stat,
    delta:f64,     // the median of the differences of the pairs, head less base
    delta_pct:f64, // that over the median of the base
    low,high:f64,  // the smallest and the largest of those differences
    pairs:int,     // pairs where both captures have it
}

Bench_Build :: struct {name,checkout,project,commit,editor:string}

Bench_Capture :: struct {
    run:string,
    pair:int,
    summary:json.Value, // as profile.capture answered it
}

Bench_Report :: struct {
    project,date,device:string,
    runs:[2]Bench_Build, // head and base
    scene:string,
    camera:[]f64,
    size:[2]int,
    pairs,frames,warmup:int,
    captures:[dynamic]Bench_Capture, // in the order they were measured
    lines:[]Bench_Line,
    warnings:[dynamic]string,
}

cmd_bench :: proc(root:string,args:[]string) -> int {
    if len(args)>0 && args[0]=="compare" {return bench_compare(root,args[1:])}
    fmt.eprintfln("Usage: mirai %s",BENCH_USAGE)
    return 2
}

// The options of mirai bench compare; error says what is wrong with them.
bench_options :: proc(args:[]string) -> (o:Bench_Options,error:string) {
    o={folder=".",base="main",size=BENCH_SIZE,pairs=BENCH_PAIRS,frames=BENCH_FRAMES,warmup=BENCH_WARMUP}
    folder_given:=false
    for i:=0;i<len(args);i+=1 {
        option:=args[i]
        if !strings.has_prefix(option,"--") {
            if folder_given {return o,fmt.tprintf("'%s' is one too many: the comparison takes a single project",option)}
            o.folder,folder_given=option,true
            continue
        }
        switch option {
        case "--base","--scene","--out","--camera","--size","--pairs","--frames","--warmup":
        case: return o,fmt.tprintf("there is no option %s",option)
        }
        if i+1>=len(args) || args[i+1]=="" {return o,fmt.tprintf("%s needs a value",option)}
        i+=1
        value:=args[i]
        switch option {
        case "--base":  o.base=value
        case "--scene": o.scene=value
        case "--out":   o.out=value
        case "--camera":
            parts:=strings.split(value,",",context.temp_allocator)
            if len(parts)!=6 && len(parts)!=7 {return o,"--camera is x,y,z,tx,ty,tz: the position and the point it looks at, then optionally the vertical fov in degrees"}
            camera:=make([]f64,len(parts))
            for part,k in parts {
                number,ok:=strconv.parse_f64(strings.trim_space(part))
                if !ok {return o,fmt.tprintf("--camera: '%s' is not a number",part)}
                camera[k]=number
            }
            if len(camera)==7 && (camera[6]<=0 || camera[6]>=180) {return o,"--camera: the fov goes between 0 and 180 degrees"}
            o.camera=camera
        case "--size":
            size,ok:=render_size_parse(value)
            if !ok || size.x<64 || size.y<64 || size.x>4096 || size.y>4096 {return o,fmt.tprintf("--size is WxH, each between 64 and 4096, not '%s'",value)}
            o.size=size
        case "--pairs","--frames","--warmup":
            number,ok:=strconv.parse_int(value,10)
            switch {
            case !ok: return o,fmt.tprintf("%s is a number, not '%s'",option,value)
            case option=="--pairs" && (number<2 || number>50): return o,"--pairs goes from 2 to 50: one pair has no spread"
            case option=="--frames" && (number<30 || number>3600): return o,"--frames goes from 30 to 3600: with fewer the percentiles say nothing"
            case option=="--warmup" && (number<0 || number>36000): return o,"--warmup goes from 0 to 36000"
            }
            switch option {
            case "--pairs":  o.pairs=number
            case "--frames": o.frames=number
            case "--warmup": o.warmup=number
            }
        }
    }
    return o,""
}

// The runs in the order they measure, 0 head and 1 base: head, base, base,
// head, ..., so that neither always measures first nor always after the other.
bench_order :: proc(pairs:int,allocator:=context.allocator) -> []int {
    order:=make([]int,2*pairs,allocator)
    for pair in 0..<pairs {
        first:=pair%2
        order[2*pair],order[2*pair+1]=first,1-first
    }
    return order
}

@(private="file")
bench_compare :: proc(root:string,args:[]string) -> int {
    o,error:=bench_options(args)
    if error!="" {fmt.eprintfln("mirai bench: %s\nUsage: mirai %s",error,BENCH_USAGE);return 2}
    if !os.is_file(project.path(o.folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai bench: %s is not a project (%s is missing); pass the folder of the project",o.folder,project.PROJECT_FILE)
        return 2
    }
    folder:=project.path_absolute(o.folder)
    relative,rel_error:=filepath.rel(root,folder,context.temp_allocator)
    if rel_error!=nil || strings.has_prefix(relative,"..") {
        fmt.eprintfln("mirai bench: %s is not inside %s: the comparison measures a project of the engine against the one of the base",folder,root)
        return 2
    }
    relative,_=strings.replace_all(relative,"\\","/",context.temp_allocator)
    if file,alive:=session_find(folder);alive {
        fmt.eprintfln("mirai bench: an editor of the project is open (pid %d) and holds the GPU and its port file; close it, or run mirai session stop %s",file.pid,relative)
        return 1
    }
    out:=o.out
    if out=="" {out=join(root,"bin","bench",render_stamp(true))}
    out=project.path_absolute(out)
    if os.make_directory_all(out)!=nil && !os.is_dir(out) {fmt.eprintfln("mirai bench: could not create %s",out);return 1}
    // The base checkout is the one of mirai render check: one of them at a time moves it.
    lock,_:=workspace.lock_acquire(workspace.lock_path(root,"render-check.lock",context.temp_allocator),fmt.tprintf("pid %d, mirai bench compare in %s",os.get_pid(),root),proc(holder:string) {
        fmt.eprintfln("mirai bench: waiting for a render check or another comparison to finish (%s)",holder!=""?holder:"another process")
    })
    defer workspace.lock_release(&lock)

    report:=Bench_Report{project=relative,date=render_stamp(false),scene=o.scene,camera=o.camera,size=o.size,pairs=o.pairs,frames=o.frames,warmup=o.warmup}
    head:=Bench_Build{name="head",checkout=root,project=folder}
    if code,_,_:=build_project(root,.Editor,{folder},.Release);code!=0 {return code}
    head.editor=build.engine_paths(root,.Release).editor_program
    base:Bench_Build
    if os.is_dir(o.base) {
        base={name="base",checkout=project.path_absolute(o.base)}
        base.project=join(base.checkout,relative)
        base.editor=build.engine_paths(base.checkout,.Release).editor_program
        if !os.is_file(base.editor) {
            fmt.eprintfln("mirai bench: %s has no editor built at --release; build it there (mirai build editor %s --release)",base.checkout,relative)
            return 1
        }
    } else {
        target,ok,same:=render_base_prepare(root,o.base,relative)
        if !ok {return 1}
        if same {fmt.eprintfln("mirai bench: this checkout has the sources of %s: there is nothing to compare",o.base);return 1}
        base={name="base",checkout=target.checkout,project=target.project,editor=target.editor}
    }
    head.commit,base.commit=render_commit(head.checkout),render_commit(base.checkout)
    report.runs={head,base}

    // Measured alone: other measurements and compilations wait, and the
    // editors opened are part of this measurement (MEASURE_ENV).
    measure:=measure_lock(root,"bench compare")
    defer workspace.lock_release(&measure)
    if !workspace.measuring() {_=os.set_env(workspace.MEASURE_ENV,fmt.tprintf("%d",os.get_pid()))}
    layers_isolate(root)

    // What else uses the GPU, before the editors open and after they close.
    load:Render_Report
    render_load(&load,0,"at the start",true)
    measured:=time.now()
    editors:[2]Headless_Editor
    defer {for &e in editors {headless_close(&e)}}
    port:=RENDER_PORT
    for &e,i in editors {
        b:=report.runs[i]
        if !headless_open(&e,"bench",b.name,b.editor,b.project,b.checkout,join(out,fmt.tprintf("%s.log",b.name)),o.size,&port) {return 1}
    }
    for &e in editors {
        if !bench_prepare(&e,o) {return 1}
    }
    summaries:[2][dynamic]Bench_Summary
    conditions:[2]json.Value
    for run,k in bench_order(o.pairs) {
        name,pair:=report.runs[run].name,k/2+1
        text,ok:=bench_capture(&editors[run],o,fmt.tprintf("%s %d",name,pair))
        if !ok {return 1}
        summary:Bench_Summary
        value,parse_error:=json.parse_string(text,parse_integers=true)
        if parse_error!=nil || json.unmarshal_string(text,&summary)!=nil {fmt.eprintfln("mirai bench: %s: profile.capture gave no summary",name);return 1}
        append(&report.captures,Bench_Capture{name,pair,value})
        append(&summaries[run],summary)
        if object,is_object:=value.(json.Object);is_object && conditions[run]==nil {conditions[run]=object["conditions"]}
        fmt.eprintfln("mirai bench: %s %d/%d: frame %.3f ms, CPU %.3f ms, GPU %.3f ms",name,pair,o.pairs,summary.frame.p50_ms,summary.cpu.ms,summary.gpu.mean_ms)
    }
    for &e in editors {headless_close(&e)}
    render_load(&load,0,"at the end",true)
    if workspace.builds_since(root,measured) {append(&load.warnings,"a build ran at low priority while it measured: the CPU cost may be noisy")}
    append(&report.warnings,..load.warnings[:])
    bench_conditions(&report,conditions)
    report.lines=bench_lines(bench_rows(summaries[0][:],summaries[1][:]))

    markdown:=bench_markdown(report)
    json_path,markdown_path:=join(out,"bench.json"),join(out,"bench.md")
    text,_:=json.marshal(report,{pretty=true,use_enum_names=true},context.temp_allocator)
    if os.write_entire_file(json_path,text)!=nil {fmt.eprintfln("mirai bench: could not write %s",json_path)}
    if os.write_entire_file(markdown_path,transmute([]u8)markdown)!=nil {fmt.eprintfln("mirai bench: could not write %s",markdown_path)}
    fmt.print(markdown)
    fmt.println()
    fmt.printfln("Table: %s",markdown_path)
    fmt.printfln("Captures: %s",json_path)
    return 0
}

@(private="file")
bench_call :: proc(e:^Headless_Editor,method:string,params:json.Object) -> (result:string,ok:bool) {
    response,err,called:=headless_call(e,method,params)
    if !called {fmt.eprintfln("mirai bench: %s: %s: %s",e.label,method,api.error_text(err,context.temp_allocator));return "",false}
    return response,true
}

// The scene and the camera of the comparison, and the frames that settle them.
@(private="file")
bench_prepare :: proc(e:^Headless_Editor,o:Bench_Options) -> bool {
    if o.scene!="" {
        params:=make(json.Object,context.temp_allocator)
        params["path"]=o.scene
        if _,ok:=bench_call(e,"scene.load",params);!ok {return false}
    }
    if len(o.camera)>0 {
        position,target:=make(json.Array,0,3,context.temp_allocator),make(json.Array,0,3,context.temp_allocator)
        for k in 0..<3 {append(&position,json.Value(o.camera[k]));append(&target,json.Value(o.camera[3+k]))}
        camera:=make(json.Object,context.temp_allocator)
        camera["position"],camera["target"],camera["exposure"]=position,target,"scene"
        if len(o.camera)==7 {camera["fov"]=o.camera[6]}
        if _,ok:=bench_call(e,"camera.set",camera);!ok {return false}
    }
    return headless_step(e,o.warmup)
}

// A capture of o.frames frames after BENCH_RESUME more; the summary as the editor wrote it.
@(private="file")
bench_capture :: proc(e:^Headless_Editor,o:Bench_Options,label:string) -> (text:string,ok:bool) {
    if !headless_step(e,BENCH_RESUME) {return}
    params:=make(json.Object,context.temp_allocator)
    params["frames"]=json.Integer(o.frames)
    params["advance"]=true
    params["label"]=label
    params["top"]=json.Integer(64)
    params["memory"]=false // a cost measure samples no memory
    return bench_call(e,"profile.capture",params)
}

// What tells the two runs apart besides the code: the conditions of their
// first captures but the entities, which the code may change, and the
// threads; a build that is not at Speed or that validates.
bench_conditions :: proc(report:^Bench_Report,conditions:[2]json.Value) {
    head,_:=conditions[0].(json.Object)
    base,_:=conditions[1].(json.Object)
    if device,is_string:=head["device"].(json.String);is_string {report.device=device}
    keys:=make([dynamic]string,context.temp_allocator)
    for key in head {append(&keys,key)}
    for key in base {if key not_in head {append(&keys,key)}}
    slice.sort(keys[:])
    for key in keys {
        if key=="entities" || key=="workers" {continue}
        a,_:=json.marshal(head[key],allocator=context.temp_allocator)
        b,_:=json.marshal(base[key],allocator=context.temp_allocator)
        if string(a)!=string(b) {append(&report.warnings,fmt.aprintf("head and base were not measured alike: %s is %s in head and %s in base",key,string(a),string(b)))}
    }
    for run,i in ([2]json.Object{head,base}) {
        name:=report.runs[i].name
        if optimization,_:=run["optimization"].(json.String);optimization!="" && optimization!="Speed" && optimization!="Aggressive" {
            append(&report.warnings,fmt.aprintf("%s is not built at --release (%s): the times are not those of a release",name,optimization))
        }
        if validation,_:=run["validation"].(json.Boolean);validation {append(&report.warnings,fmt.aprintf("%s measured with the validation of the graphics API: the times are inflated",name))}
    }
}

// The measures of the captures by name: the i-th capture of head and the
// i-th of base make the pair i.
bench_rows :: proc(head,base:[]Bench_Summary) -> []Bench_Row {
    pairs:=max(len(head),len(base))
    rows:=make([dynamic]Bench_Row)
    index:=make(map[string]int,context.temp_allocator)
    put :: proc(rows:^[dynamic]Bench_Row,index:^map[string]int,pairs:int,section:Bench_Section,name,thread:string,run,pair:int,value:f64) {
        key:=fmt.tprintf("%v %s %s",section,thread,name)
        at,found:=index[key]
        if !found {
            at=len(rows)
            index[key]=at
            row:=Bench_Row{section=section,name=name,thread=thread}
            for &values in row.values {
                values=make([]f64,pairs)
                for &v in values {v=math.nan_f64()}
            }
            append(rows,row)
        }
        rows[at].values[run][pair]=value
    }
    for summaries,run in ([2][]Bench_Summary{head,base}) {
        for s,pair in summaries {
            put(&rows,&index,pairs,.Frame,"frame p50","",run,pair,s.frame.p50_ms)
            put(&rows,&index,pairs,.Frame,"frame p95","",run,pair,s.frame.p95_ms)
            put(&rows,&index,pairs,.Frame,"CPU of the main thread","",run,pair,s.cpu.ms)
            put(&rows,&index,pairs,.Frame,"GPU","",run,pair,s.gpu.mean_ms)
            for part in s.cpu.parts {put(&rows,&index,pairs,.Parts,part.name,"",run,pair,part.mean_ms)}
            for pass in s.gpu.passes {put(&rows,&index,pairs,.Passes,pass.name,"",run,pair,pass.mean_ms)}
            for zone in s.cpu.zones {put(&rows,&index,pairs,.Zones,zone.name,zone.thread,run,pair,zone.self_ms)}
        }
    }
    return rows[:]
}

@(private="file")
bench_median :: proc(values:[]f64) -> f64 {
    slice.sort(values)
    n:=len(values)
    return n%2==1?values[n/2]:(values[n/2-1]+values[n/2])/2
}

// The median of the values that are there and the median of their distances to it.
bench_stat :: proc(values:[]f64) -> (s:Bench_Stat) {
    kept:=make([dynamic]f64,0,len(values),context.temp_allocator)
    for v in values {if !math.is_nan(v) {append(&kept,v)}}
    s.count=len(kept)
    if s.count==0 {return}
    s.median=bench_median(kept[:])
    for &v in kept {v=abs(v-s.median)}
    s.spread=bench_median(kept[:])
    return
}

bench_line :: proc(row:Bench_Row) -> (l:Bench_Line) {
    l.section,l.name,l.thread=row.section,row.name,row.thread
    l.head,l.base=bench_stat(row.values[0]),bench_stat(row.values[1])
    differences:=make([dynamic]f64,context.temp_allocator)
    for h,i in row.values[0] {
        if b:=row.values[1][i];!math.is_nan(h) && !math.is_nan(b) {append(&differences,h-b)}
    }
    l.pairs=len(differences)
    if l.pairs==0 {return}
    l.low,l.high=slice.min(differences[:]),slice.max(differences[:])
    l.delta=bench_median(differences[:])
    if l.base.median>0 {l.delta_pct=l.delta/l.base.median*100}
    return
}

// The lines of the table: the frame as it comes; the parts and the passes by
// their larger median; the functions that every capture has, by how much
// they changed, at most BENCH_ZONES. What neither build spends a microsecond
// on says nothing.
bench_lines :: proc(rows:[]Bench_Row) -> []Bench_Line {
    by_section:[Bench_Section][dynamic]Bench_Line
    for &list in by_section {list=make([dynamic]Bench_Line,context.temp_allocator)}
    for row in rows {
        l:=bench_line(row)
        if row.section!=.Frame && max(l.base.median,l.head.median)<0.001 {continue}
        if row.section==.Zones && (l.pairs<len(row.values[0]) || l.head.count<len(row.values[0]) || l.base.count<len(row.values[1])) {continue}
        append(&by_section[row.section],l)
    }
    slice.sort_by(by_section[.Parts][:],proc(a,b:Bench_Line) -> bool {return max(a.base.median,a.head.median)>max(b.base.median,b.head.median)})
    slice.sort_by(by_section[.Passes][:],proc(a,b:Bench_Line) -> bool {return max(a.base.median,a.head.median)>max(b.base.median,b.head.median)})
    slice.sort_by(by_section[.Zones][:],proc(a,b:Bench_Line) -> bool {return abs(a.delta)>abs(b.delta)})
    resize(&by_section[.Zones],min(len(by_section[.Zones]),BENCH_ZONES))
    lines:=make([dynamic]Bench_Line)
    for list in by_section {append(&lines,..list[:])}
    return lines[:]
}

// Milliseconds with three decimals.
@(private="file")
bench_ms :: proc(value:f64,signed:=false) -> string {
    text:=signed?fmt.tprintf("%+.3f",value):fmt.tprintf("%.3f",value)
    if text=="-0.000" || text=="+0.000" {text=signed?"±0.000":"0.000"}
    return text
}

@(private="file")
bench_cell :: proc(s:Bench_Stat) -> string {
    if s.count==0 {return "—"}
    return fmt.tprintf("%s ± %s",bench_ms(s.median),bench_ms(s.spread))
}

// text in lines of at most width characters, the ones after the first indented by indent.
@(private="file")
bench_wrap :: proc(b:^strings.Builder,text:string,width:int,indent:="") {
    column:=0
    for word in strings.fields(text,context.temp_allocator) {
        size:=strings.rune_count(word)
        if column>0 && column+1+size>width {
            strings.write_byte(b,'\n')
            strings.write_string(b,indent)
            column=len(indent)
        } else if column>0 {
            strings.write_byte(b,' ')
            column+=1
        }
        strings.write_string(b,word)
        column+=size
    }
    strings.write_byte(b,'\n')
}

// The table of a comparison, ready for a report: how it was measured,
// a table per kind of measure and the warnings.
bench_markdown :: proc(r:Bench_Report) -> string {
    b:=strings.builder_make()
    head,base:=r.runs[0],r.runs[1]
    fmt.sbprintfln(&b,"## %s: `%s` against `%s`",r.project,head.commit,base.commit)
    strings.write_byte(&b,'\n')
    scene:=r.scene!=""?fmt.tprintf("scene `%s`",r.scene):"the start scene of the project"
    camera:="the camera of the editor"
    if len(r.camera)>0 {
        numbers:=make([]string,len(r.camera),context.temp_allocator)
        for v,i in r.camera {numbers[i]=fmt.tprintf("%g",v)}
        camera=fmt.tprintf("camera `%s`",strings.join(numbers,",",context.temp_allocator))
    }
    device:=r.device!=""?r.device:"an unnamed GPU"
    bench_wrap(&b,fmt.tprintf("`mirai bench compare` of %s on %s: %d alternating pairs (head, base, base, head…) of %d frames at %dx%d, %s and %s, after %d frames of warmup. Headless editors built at `--release`, without VSync, frame limit or validation. Each cell is the median of the captures ± the median of their distances to it; Δ is the median of the head - base differences of each pair, and the last column, the smallest and the largest: if they cross 0, the pairs do not agree on the sign.",r.date,device,r.pairs,r.frames,r.size.x,r.size.y,scene,camera,r.warmup),BENCH_LINE)
    titles:=BENCH_TITLES
    for section in Bench_Section {
        first:=true
        for l in r.lines {
            if l.section!=section {continue}
            if first {
                fmt.sbprintfln(&b,"\n| %s | base | head | Δ | Δ %% | Δ per pair |",titles[section])
                strings.write_string(&b,"| --- | ---: | ---: | ---: | ---: | ---: |\n")
                first=false
            }
            name:=section==.Frame?l.name:fmt.tprintf("`%s`%s",l.name,l.thread=="workers"?" (workers)":"")
            delta,pct,range:="—","—","—"
            if l.pairs>0 {
                delta=bench_ms(l.delta,true)
                range=fmt.tprintf("%s to %s",bench_ms(l.low,true),bench_ms(l.high,true))
                if l.base.median>0 {pct=fmt.tprintf("%+.1f %%",l.delta_pct)}
            }
            fmt.sbprintfln(&b,"| %s | %s | %s | %s | %s | %s |",name,bench_cell(l.base),bench_cell(l.head),delta,pct,range)
        }
    }
    if len(r.warnings)>0 {
        strings.write_string(&b,"\nWarnings:\n\n")
        for warning in r.warnings {bench_wrap(&b,fmt.tprintf("- %s",warning),BENCH_LINE,"  ")}
    }
    return strings.to_string(b)
}
