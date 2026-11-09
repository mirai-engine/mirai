package editor

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// profile.audit: one capture with every track, read against the budgets of
// the project (project.Performance) and turned into findings an agent acts
// on: what costs, who owns it (the game, a plugin, the engine, what the scene
// draws) and the call that explains it further.

PROFILE_AUDIT_SHARE_MIN :: 0.02  // of the frame: a zone below it is no finding
PROFILE_AUDIT_MEDIUM :: 0.05     // of the frame: a finding at least this large is medium
PROFILE_AUDIT_HIGH :: 0.25       // of the frame: and high
PROFILE_AUDIT_PASS_MIN :: 0.10   // of the GPU time of a frame: a pass below it is no finding
PROFILE_AUDIT_GPU_MEMORY :: 0.9  // of the GPU budget: the system may page out above it

Api_Profile_Audit_Params :: struct {
    frames:int `mirai:"optional,min=30,max=3600,label=Frames to record"`,
    top:int `mirai:"optional,min=1,max=32,label=Findings at most"`,
    wait:int `mirai:"optional,min=0,max=900,unit=s,label=How long to wait for a compilation or another measurement that runs, as in profile.capture"`,
    allow_limited:bool `mirai:"optional,label=Measure with VSync or a frame limit or graphics validation on; the frame budget is then checked against the CPU time of the frames"`,
    baseline:[PROFILE_BASELINE_NAME_BYTES]u8 `mirai:"optional,text,label=A baseline of the project to compare this capture against"`,
    save:[PROFILE_BASELINE_NAME_BYTES]u8 `mirai:"optional,text,label=Save this capture as the baseline of this name, replacing the one there was: letters, digits, '_' and '-'"`,
}

Profile_Owner :: enum u8 {Engine,Plugin,Project_Plugin,Game,Scene,Unattributed}
PROFILE_OWNER_NAMES :: [Profile_Owner]string{.Engine="engine",.Plugin="plugin",.Project_Plugin="project_plugin",.Game="game",.Scene="scene",.Unattributed="unattributed"}
// Owners whose cost the project can change: its code, and what its scenes draw.
PROFILE_OWNERS_ACTIONABLE :: bit_set[Profile_Owner;u8]{.Game,.Project_Plugin,.Scene}

Profile_Step_Owner :: struct {owner:Profile_Owner,plugin:string}

Profile_Severity :: enum u8 {High,Medium,Low}

Profile_Budget_Out :: struct {name:string,budget,measured:f64,unit:string,over:bool}
Profile_Finding_Out :: struct {
    severity,kind,subject,owner,plugin:string,
    actionable:bool,
    value:f64,
    unit:string,
    share:f64,
    text,next:string,
}
Profile_Audit_Out :: struct {
    capture:int,
    verdict:string,
    comparable:bool,
    bound:string,
    mean_ms,p95_ms,fps,cpu_ms,gpu_ms:f64,
    budgets:[]Profile_Budget_Out,
    findings:[]Profile_Finding_Out,
    saved:string,
    notes:[]string,
}

Api_Profile_Budget :: struct {
    name:[16]u8 `mirai:"text,label=frame memory or load of the performance of project.mirai"`,
    budget,measured:f32,
    unit:[4]u8 `mirai:"text"`,
    over:bool,
}
Api_Profile_Finding :: struct {
    severity:[8]u8 `mirai:"text,label=high medium or low"`,
    kind:[8]u8 `mirai:"text,label=cpu: a zone of the threads; gpu: a GPU pass; spike: frames over twice the median; memory; load"`,
    subject:[PROFILE_NAME_BYTES]u8 `mirai:"text,label=The zone, pass, counter, frame or load it is about"`,
    owner:[16]u8 `mirai:"text,label=game, project_plugin or scene: the project can change it; plugin or engine: it cannot, though what the scene holds may drive it; unattributed: the call in next says where it went"`,
    plugin:[64]u8 `mirai:"text,label=The plugin that owns it; empty: none"`,
    actionable:bool `mirai:"label=Its owner is the project: its code or what its scenes draw"`,
    value:f32,
    unit:[4]u8 `mirai:"text,label=ms per frame, or ms or MB"`,
    share:f32 `mirai:"label=Of the frame for cpu and spike; of the GPU time for gpu; 0 for the rest"`,
    text:[PROFILE_NOTE_BYTES]u8 `mirai:"text"`,
    next:[PROFILE_NOTE_BYTES]u8 `mirai:"text,label=The call that explains it further"`,
}
Api_Profile_Audit :: struct {
    capture:int `mirai:"label=What the id of the other profile methods takes"`,
    verdict:[12]u8 `mirai:"text,label=within: every budget it measured holds; over: one does not; unmeasured: no frame was recorded"`,
    comparable:bool `mirai:"label=Measured without VSync or a frame limit or graphics validation"`,
    bound:[8]u8 `mirai:"text,label=What most frames waited for: cpu gpu or paced"`,
    mean_ms,p95_ms,fps:f32,
    cpu_ms:f32 `mirai:"label=Mean of the main thread when it was not waiting"`,
    gpu_ms:f32 `mirai:"label=Mean of the GPU over the frames it measured"`,
    budgets:[1]Api_Profile_Budget `mirai:"list,label=The budgets of project.mirai it could measure; 0 in project.mirai: none"`,
    findings:[1]Api_Profile_Finding `mirai:"list,label=The severest first"`,
    baseline:Api_Profile_Compare `mirai:"optional,label=Only with baseline: as profile.compare against it"`,
    saved:[API_PATH_BYTES]u8 `mirai:"text,label=The baseline it wrote; empty: none"`,
    notes:[1][PROFILE_NOTE_BYTES]u8 `mirai:"text,list,label=What to know before reading the findings"`,
}

profile_audit_register :: proc(s:^Session,st:^Api_State) {
    audit_default:=Api_Profile_Audit_Params{frames=240,top=10,wait=PROFILE_WAIT}
    api_register(s,st,{name="profile.audit",summary="Measures the open scene or Play with every track and reads it against the performance budgets of project.mirai: whether they hold, and findings ranked by cost, each with who owns it (the game, a plugin, the engine, what the scene draws) and the call that explains it. Compares against a saved baseline and saves one.",params=Api_Profile_Audit_Params,result=Api_Profile_Audit,writes_result=true,defaults=&audit_default,run=api_profile_audit})
}

@(private)
api_profile_audit :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Audit_Params)
    baseline_name,save_name:=base.text_get(p.baseline[:]),base.text_get(p.save[:])
    if (baseline_name!="" || save_name!="") && !s.has_project {api.call_fail(call,api.SERVER_ERROR,"Without a project there are no baselines");return}
    if save_name!="" && !profile_baseline_name_valid(save_name) {
        api.call_failf(call,api.INVALID_PARAMS,"%q is not a baseline name: up to %d letters, digits, '_' and '-'",save_name,PROFILE_BASELINE_NAME_BYTES-1)
        return
    }
    against:Profile_Digest
    if baseline_name!="" {
        error:string
        if against,error=profile_baseline_load(s.project_root,baseline_name,call.allocator);error!="" {api.call_fail(call,api.INVALID_PARAMS,error);return}
    }
    c:=profile_record(s,call,{frames=p.frames,advance=true,dt=HEADLESS_DT,wait=p.wait,allow_limited=p.allow_limited,gpu=true,memory=true,label=profile_label("audit")})
    if c==nil {return}

    context.allocator=context.temp_allocator
    input:=Profile_Audit_Input{capture=c,summary=profile_summary(c,PROFILE_AUDIT_TOP_ZONES)}
    input.budget=project.manifest_default("").performance
    project_plugins:map[string]bool
    if s.has_project {
        if opened,error:=project.open(s.project_root,s.engine_root);error.code==.None {
            input.budget=opened.manifest.performance
            for &plugin in opened.plugins {
                if plugin.origin==.Project {project_plugins[base.text_get(plugin.manifest.name[:])]=true}
            }
        }
    }
    if s.app!=nil && s.app.info!=nil {
        for step in s.app.info.steps {input.owners[step.name]=profile_step_owner(step.game,step.plugin,project_plugins)}
    }
    kind:=host.Load_Kind.Scene
    if s.mode==.Play || s.mode==.Paused {kind=.Play}
    if summary,found:=host.load_summary(s.app,kind,PROFILE_LOAD_TOP);found {
        manual:=false
        if st:=api_state(s);st!=nil {manual=st.manual}
        input.load,input.loaded=profile_load_out(s,summary,manual),true
    }
    out:=profile_audit(input,p.top)
    if save_name!="" {
        path,error:=profile_baseline_save(s.project_root,save_name,profile_digest(c))
        if error!="" {
            notes:=make([dynamic]string)
            append(&notes,..out.notes)
            append(&notes,fmt.tprintf("The baseline was not saved: %s",error))
            out.notes=notes[:]
        }
        out.saved=path
    }
    compared:Maybe(Profile_Compare_Out)
    if baseline_name!="" {compared=profile_compare(against,profile_digest(c),PROFILE_AUDIT_TOP_ZONES)}
    profile_audit_write(call,out,compared)
}

// The answer of profile.audit; with a baseline, its comparison goes in the
// object as baseline.
@(private)
profile_audit_write :: proc(call:^api.Call,out:Profile_Audit_Out,compared:Maybe(Profile_Compare_Out)) {
    text,error:=json.marshal(out,{},call.allocator)
    if error!=nil {api.call_fail(call,api.INTERNAL_ERROR,"The answer could not be serialized");return}
    if against,ok:=compared.?;ok {
        comparison,compare_error:=json.marshal(against,{},call.allocator)
        if compare_error!=nil {api.call_fail(call,api.INTERNAL_ERROR,"The answer could not be serialized");return}
        text=transmute([]u8)strings.concatenate({string(text[:len(text)-1]),`,"baseline":`,string(comparison),"}"},call.allocator)
    }
    serial.text_write_raw(call.out,json_numbers_short(string(text),call.allocator))
}

PROFILE_AUDIT_TOP_ZONES :: 12

@(private="file")
profile_label :: proc(text:string) -> (label:[32]u8) {
    base.text_set(label[:],text)
    return
}

// Who owns a loop function, from what the generator says of its package.
profile_step_owner :: proc(game:bool,plugin:string,project_plugins:map[string]bool) -> Profile_Step_Owner {
    switch {
    case game: return {.Game,""}
    case plugin=="": return {.Engine,""}
    case plugin in project_plugins: return {.Project_Plugin,plugin}
    }
    return {.Plugin,plugin}
}

Profile_Audit_Input :: struct {
    capture:^Profile_Capture,
    summary:Profile_Summary_Out,
    owners:map[string]Profile_Step_Owner, // by the name of a loop function
    budget:project.Performance,
    load:Profile_Load_Out, // the last of the scene or of Play, when loaded
    loaded:bool,
}

// The verdict and findings of a capture, in the temp allocator.
profile_audit :: proc(input:Profile_Audit_Input,top:int) -> (out:Profile_Audit_Out) {
    context.allocator=context.temp_allocator
    c,sum:=input.capture,input.summary
    out.capture,out.comparable=c.id,sum.comparable
    out.mean_ms,out.p95_ms,out.fps,out.cpu_ms,out.gpu_ms=sum.frame.mean_ms,sum.frame.p95_ms,sum.frame.fps,sum.cpu.ms,sum.gpu.mean_ms
    notes:=make([dynamic]string)
    append(&notes,..sum.notes)
    if sum.frame.count==0 {
        out.verdict,out.notes="unmeasured",notes[:]
        return
    }
    bound:=sum.frame.bound
    switch {
    case bound.paced>=bound.cpu && bound.paced>=bound.gpu: out.bound="paced"
    case bound.gpu>bound.cpu: out.bound="gpu"
    case: out.bound="cpu"
    }
    // The time a frame costs: with pacing on it is the CPU time of the frames.
    frame_basis:=sum.frame.mean_ms
    if !out.comparable {frame_basis=sum.cpu.ms}

    budgets:=make([dynamic]Profile_Budget_Out)
    over:=false
    if b:=f64(input.budget.frame);b>0 {
        measured:=sum.frame.p95_ms
        if !out.comparable {
            cpu:=make([]f64,len(c.frames))
            for f,i in c.frames {cpu[i]=profile_frame_cpu_ms(f)}
            measured=profile_ms(profile_spread(cpu).p95)
            append(&notes,"Not comparable: the frame budget is checked against the CPU time of the frames, without the waits for the display or a limit")
        }
        append(&budgets,Profile_Budget_Out{"frame",profile_ms(b),measured,"ms",measured>b})
    }
    if b:=f64(input.budget.memory);b>0 {
        measured:=-1.0
        for counter in sum.memory.counters {if counter.name=="process_private" {measured=counter.high_mb}}
        if measured>=0 {append(&budgets,Profile_Budget_Out{"memory",profile_ms(b),measured,"MB",measured>b})}
    }
    if b:=f64(input.budget.load);b>0 {
        switch {
        case !input.loaded: append(&notes,"No load of the scene or of Play yet: the load budget is not checked")
        case input.load.state!="Done": append(&notes,fmt.tprintf("The last load is %s: the load budget is not checked",input.load.state))
        case: append(&budgets,Profile_Budget_Out{"load",profile_ms(b),input.load.resident_ms,"ms",input.load.resident_ms>b})
        }
    }
    for budget in budgets {over|=budget.over}
    out.budgets=budgets[:]
    out.verdict=over?"over":"within"

    findings:=make([dynamic]Profile_Finding_Out)
    finding :: proc(list:^[dynamic]Profile_Finding_Out,severity:Profile_Severity,kind,subject:string,owner:Profile_Step_Owner,value:f64,unit:string,share:f64,text,next:string) {
        severities:=[Profile_Severity]string{.High="high",.Medium="medium",.Low="low"}
        names:=PROFILE_OWNER_NAMES
        append(list,Profile_Finding_Out{severities[severity],kind,subject,names[owner.owner],owner.plugin,owner.owner in PROFILE_OWNERS_ACTIONABLE,profile_ms(value),unit,profile_ms(share),text,next})
    }
    by_share :: proc(share:f64) -> Profile_Severity {
        if share>=PROFILE_AUDIT_HIGH {return .High}
        if share>=PROFILE_AUDIT_MEDIUM {return .Medium}
        return .Low
    }

    // CPU: every zone by its own time, not only those the summary lists.
    for a in profile_aggregate(c) {
        name:=c.cpu.names[a.name]
        if name=="frame" || profile_is_part(name) {continue}
        own:=profile_spread(a.self).mean
        share:=frame_basis>0?own/frame_basis:0
        if share<PROFILE_AUDIT_SHARE_MIN {continue}
        owner,found:=input.owners[name]
        if !found {owner={.Engine,""}}
        thread:=a.worker?"workers":"main"
        whose:string
        switch owner.owner {
        case .Game: whose="a loop function of the game"
        case .Project_Plugin: whose=fmt.tprintf("a loop function of %s, a plugin of the project",owner.plugin)
        case .Plugin: whose=fmt.tprintf("a loop function of the engine plugin %s: not code of the project, though what the scene holds or the settings of the plugin may drive it",owner.plugin)
        case .Engine,.Scene,.Unattributed: whose="of the engine: not code of the project, though what the scene holds may drive it"
        }
        text:=fmt.tprintf("%s (%s), %s, takes %.3f ms per frame of its own, %.0f%% of the frame",name,thread,whose,own,share*100)
        if out.bound=="gpu" {text=fmt.tprintf("%s; the frames wait for the GPU, so saving it does not shorten them",text)}
        next:=fmt.tprintf(`profile.zone {{"id":%d,"name":"%s","thread":"%s"}}`,c.id,name,thread)
        finding(&findings,by_share(share),"cpu",name,owner,own,"ms",share,text,next)
    }

    // GPU: the passes that take a good part of it, which cost with what is drawn.
    if sum.gpu.recorded && sum.gpu.mean_ms>0 {
        for values,i in profile_passes_by_name(c) {
            ms:=profile_spread(values).mean
            share:=ms/sum.gpu.mean_ms
            if share<PROFILE_AUDIT_PASS_MIN {continue}
            name:=c.gpu.pass_names[i]
            text:=fmt.tprintf("The GPU pass %s takes %.3f ms per frame, %.0f%% of the GPU: it costs with what the scene draws (entities, materials, lights) and the graphics settings",name,ms,share*100)
            if out.bound=="cpu" {text=fmt.tprintf("%s; the frames wait for the CPU, so saving it does not shorten them",text)}
            severity:=by_share(frame_basis>0?ms/frame_basis:0)
            if out.bound!="gpu" && severity==.High {severity=.Medium}
            finding(&findings,severity,"gpu",name,{.Scene,""},ms,"ms",share,text,"graphics.get")
        }
    }

    // Spikes: the slowest frame and the loop function that took most of it.
    if sum.frame.spikes>0 && len(sum.frame.worst)>0 {
        worst:=sum.frame.worst[0]
        worst_ms:=profile_frame_ms(c.frames[worst])
        culprit,culprit_ns:="",i64(0)
        for zone in c.cpu.zones {
            if zone.frame!=worst || zone.self_ns<=culprit_ns {continue}
            name:=c.cpu.names[zone.name]
            if name in input.owners {culprit,culprit_ns=name,zone.self_ns}
        }
        owner:=Profile_Step_Owner{.Unattributed,""}
        text:=fmt.tprintf("%d of %d frames took more than twice the median; the slowest, frame %d, took %.3f ms",sum.frame.spikes,sum.frame.count,worst,worst_ms)
        if culprit!="" {
            owner=input.owners[culprit]
            text=fmt.tprintf("%s, %.3f ms of it in %s",text,f64(culprit_ns)/1e6,culprit)
        }
        severity:=Profile_Severity.Medium
        if f64(sum.frame.spikes)>=0.05*f64(sum.frame.count) {severity=.High}
        finding(&findings,severity,"spike",fmt.tprintf("frame %d",worst),owner,worst_ms-sum.frame.p50_ms,"ms",frame_basis>0?(worst_ms-sum.frame.p50_ms)/frame_basis:0,text,fmt.tprintf(`profile.frames {{"id":%d,"worst":3}}`,c.id))
    }

    // Memory: a stable frame allocates nothing, and the GPU keeps under its budget.
    if sum.memory.recorded {
        for counter in sum.memory.counters {
            if counter.name=="process_private" && counter.rises>0 && counter.risen_mb>0 {
                text:=fmt.tprintf("The private memory of the process went up in %d of %d frames, %.3f MB in all: a stable frame allocates nothing",counter.rises,sum.frame.count-1,counter.risen_mb)
                finding(&findings,.Medium,"memory","process_private",{.Unattributed,""},counter.risen_mb,"MB",0,text,fmt.tprintf(`profile.memory {{"id":%d,"counter":"process_private"}}`,c.id))
            }
            if counter.name=="gpu_used" && sum.memory.gpu_budget_mb>0 && counter.high_mb>PROFILE_AUDIT_GPU_MEMORY*sum.memory.gpu_budget_mb {
                text:=fmt.tprintf("The GPU holds %.0f MB of a budget of %.0f MB: the system may page some of it out, which costs time the passes do not show; textures and geometry are what the scene draws",counter.high_mb,sum.memory.gpu_budget_mb)
                finding(&findings,.High,"memory","gpu_used",{.Scene,""},counter.high_mb,"MB",0,text,fmt.tprintf(`profile.memory {{"id":%d,"counter":"gpu_used"}}`,c.id))
            }
        }
    }

    // Load: over its budget, with where its seconds went.
    for budget in budgets {
        if budget.name!="load" || !budget.over {continue}
        l:=input.load
        text:=fmt.tprintf("Loading %s took %.0f ms until all of it was resident, over the budget of %.0f ms",l.name,l.resident_ms,budget.budget)
        if len(l.assets)>0 {
            slowest:=l.assets[0]
            for kind in l.assets {if kind.ms>slowest.ms {slowest=kind}}
            text=fmt.tprintf("%s; %s took the most, %.0f ms",text,slowest.kind,slowest.ms)
        }
        if len(l.slowest)>0 {text=fmt.tprintf("%s; the slowest asset is %s",text,l.slowest[0].asset)}
        finding(&findings,.High,"load",l.name,{.Scene,""},l.resident_ms,"ms",0,text,fmt.tprintf(`profile.load {{"kind":"%s"}}`,l.kind))
    }

    slice.sort_by(findings[:],proc(a,b:Profile_Finding_Out) -> bool {
        rank :: proc(severity:string) -> int {return severity=="high"?0:(severity=="medium"?1:2)}
        if rank(a.severity)!=rank(b.severity) {return rank(a.severity)<rank(b.severity)}
        return a.share>b.share || (a.share==b.share && a.value>b.value)
    })
    out.findings=findings[:min(len(findings),top)]
    if len(findings)>top {append(&notes,fmt.tprintf("%d findings more: raise top to see them",len(findings)-top))}
    out.notes=notes[:]
    return
}
