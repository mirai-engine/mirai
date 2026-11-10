package editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/serial"

// engine.diagnostics: the text behind the counters of engine.status and what
// the functions of the worlds could not do, so a failed capture, test, build
// or Play can be diagnosed without opening the editor.

API_DIAGNOSTICS_LIMIT :: 100 // asset errors and build diagnostics listed
API_DIAGNOSTICS_BUILD_TEXT :: 4096

Api_Diagnostics_Params :: struct {
    since:u64 `mirai:"optional,label=Lists the console entries written after this serial; 0: from the oldest"`,
    min_level:Console_Level `mirai:"optional,label=Lowest level of the console entries listed"`,
    limit:int `mirai:"optional,min=1,max=500,clamp,label=Most console entries listed: the newest ones"`,
}

Api_Engine_Diagnostics_Result_Validation :: struct {
    errors,loader_errors:int,
    messages:[]string,
}
Api_Engine_Diagnostics_Result_Console_Entries :: struct {
    serial:int,
    level:string `mirai:"label=Debug, Info, Warning or Error"`,
    text:string,
    repeats:int,
}
Api_Engine_Diagnostics_Result_Console :: struct {
    serial_:int `mirai:"name=serial"`,
    counts:serial.Json,
    omitted:int,
    entries:[]Api_Engine_Diagnostics_Result_Console_Entries,
}
Api_Engine_Diagnostics_Result_Asset_Errors :: struct {
    id,kind,problem,detail:string,
    path,message:string `mirai:"optional"`,
}
Api_Engine_Diagnostics_Result_Build_Diagnostics :: struct {
    severity:string `mirai:"label=Error or Warning"`,
    file:string,
    line,column:int,
    message:string,
}
Api_Engine_Diagnostics_Result_Build :: struct {
    phase:string,
    errors:int,
    diagnostics:[]Api_Engine_Diagnostics_Result_Build_Diagnostics,
    text:string,
}
Api_Engine_Diagnostics_Result_Problems_Entries :: struct {
    id,entity:string `mirai:"optional,label=Of the entity it is about, when it is about one"`,
    name:string,
    alive:bool,
    code:string,
    message:string `mirai:"label=What failed and how to fix it"`,
    count,first,last:int,
}
Api_Engine_Diagnostics_Result_Problems :: struct {
    world:string `mirai:"label=edit or play"`,
    owner,player:int `mirai:"optional"`,
    serial,evicted:int,
    entries:[]Api_Engine_Diagnostics_Result_Problems_Entries,
}
Api_Engine_Diagnostics_Result_Renderer :: struct {
    problem:string,
}
Api_Engine_Diagnostics_Result :: struct {
    validation:Api_Engine_Diagnostics_Result_Validation,
    console:Api_Engine_Diagnostics_Result_Console,
    asset_errors:[]Api_Engine_Diagnostics_Result_Asset_Errors,
    build:Api_Engine_Diagnostics_Result_Build,
    problems:[]Api_Engine_Diagnostics_Result_Problems,
    renderer:Api_Engine_Diagnostics_Result_Renderer,
}

@(private)
api_diagnostics_register :: proc(s:^Session,st:^Api_State) {
    defaults:=Api_Diagnostics_Params{min_level=.Info,limit=50}
    api_register(s,st,{name="engine.diagnostics",summary="The text behind the counters of engine.status: what the GPU, the console, the assets and the last build reported, and the problems the functions of the edited world and of each Play met.",params=Api_Diagnostics_Params,result=Api_Engine_Diagnostics_Result,defaults=&defaults,flags={.Core,.Read_Only,.As_User},run=api_diagnostics})
}

// The text without a multi-byte character cut at its end.
@(private)
api_text_whole :: proc(text:string) -> string {
    end:=len(text)
    for back in 1..=min(3,end) {
        start:=end-back
        if text[start]&0xC0==0x80 {continue}
        if _,size:=utf8.decode_rune_in_string(text[start:]);size==1 && text[start]>=0x80 {end=start}
        break
    }
    return text[:end]
}

@(private)
api_diagnostics :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Diagnostics_Params)
    r:=api.call_result(call,Api_Engine_Diagnostics_Result)
    app:=s.app
    if app!=nil && app.device!=nil {
        history:[rhi.VALIDATION_HISTORY]string
        r.validation.errors,r.validation.loader_errors=rhi.device_validation_errors(app.device),rhi.device_loader_errors(app.device)
        r.validation.messages=make([]string,rhi.device_validation_messages(app.device,history[:]),call.allocator)
        for &message,i in r.validation.messages {message=strings.clone(api_text_whole(history[i]),call.allocator)}
    }
    if app!=nil && app.renderer!=nil {r.renderer.problem=gpu.renderer_stats(app.renderer).problem}
    if s.console!=nil {r.console=api_diagnostics_console(s.console,params,call.allocator)}
    errors:=make([dynamic]Api_Engine_Diagnostics_Result_Asset_Errors,call.allocator)
    if app!=nil && app.assets!=nil {
        listed:=host.assets_errors(app.assets)
        for known in listed[:min(len(listed),API_DIAGNOSTICS_LIMIT)] {
            buffer:[base.ASSET_ID_TEXT]u8
            entry:=Api_Engine_Diagnostics_Result_Asset_Errors{id=strings.clone(base.asset_id_format(known.id,buffer[:]),call.allocator),kind=fmt.tprint(known.kind),problem=fmt.tprint(known.problem),detail=fmt.tprint(known.detail)}
            if known.detail==.Version {entry.message=api_asset_stale(app.assets,known.id)}
            append(&errors,entry)
        }
        api_duplicates_list(&app.assets.registry,&errors)
    }
    r.asset_errors=errors[:]
    r.build.phase="Idle"
    if b:=s.build;b!=nil {
        shown:=b.diagnostics[:min(len(b.diagnostics),API_DIAGNOSTICS_LIMIT)]
        r.build.phase,r.build.errors=fmt.tprint(b.phase),len(b.diagnostics)
        r.build.diagnostics=make([]Api_Engine_Diagnostics_Result_Build_Diagnostics,len(shown),call.allocator)
        for d,i in shown {r.build.diagnostics[i]={fmt.tprint(d.severity),d.file,d.line,d.column,d.message}}
        text:=b.text
        if len(b.shaders_text)>0 {text=len(text)>0?fmt.tprintf("%s\n%s",b.shaders_text,text):b.shaders_text}
        r.build.text=api_text_whole(text[:min(len(text),API_DIAGNOSTICS_BUILD_TEXT)])
    }
    problems:=make([dynamic]Api_Engine_Diagnostics_Result_Problems,call.allocator)
    if w:=edited_world(s);w.data!=nil && app!=nil {
        if held:=host.app_world_storage(app,w.data,core.Problems);held!=nil {append(&problems,api_problems_of(w,held,"edit",call.allocator))}
    }
    for &run in s.runs {
        if run.world==nil || app==nil {continue}
        w:=run_ref(s,&run)
        if held:=host.app_world_storage(app,w.data,core.Problems);held!=nil {
            listed:=api_problems_of(w,held,"play",call.allocator)
            listed.owner,listed.player=int(run.owner),int(run.player)
            append(&problems,listed)
        }
    }
    r.problems=problems[:]
}

// The serial, the evicted and the entries of the problems of a world, the
// oldest first, after the first key of an object.
@(private)
api_problems_of :: proc(w:core.World_Ref,problems:^core.Problems,world:string,allocator:runtime.Allocator) -> (r:Api_Engine_Diagnostics_Result_Problems) {
    listed:=slice.clone(core.problems_list(problems),context.temp_allocator)
    slice.sort_by(listed,proc(a,b:core.Problem) -> bool {return a.first<b.first})
    entities:=core.world_entities(w)
    r={world=world,serial=int(problems.serial),evicted=int(problems.evicted),entries=make([]Api_Engine_Diagnostics_Result_Problems_Entries,len(listed),allocator)}
    for &p,i in listed {
        named:=p.entity!=core.NONE
        entry:=&r.entries[i]
        entry^={alive=named && core.alive(entities,p.entity),code=core.problem_code(&p),message=strings.clone(api_text_whole(core.problem_text(&p)),allocator),count=int(p.count),first=int(p.first),last=int(p.last)}
        if !named {continue}
        entry.entity,entry.name=fmt.aprintf("0x%016x",u64(p.entity),allocator=allocator),entity_name(w,p.entity)
        if id:=api_entity_id(w,p.entity);id!=0 {entry.id=fmt.aprintf("0x%016x",u64(id),allocator=allocator)}
    }
    return
}

// The entries of the console that are newer than since and reach min_level,
// the newest limit of them, oldest first.
@(private)
api_diagnostics_console :: proc(c:^Console,params:^Api_Diagnostics_Params,allocator:runtime.Allocator) -> (r:Api_Engine_Diagnostics_Result_Console) {
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    matches :: proc(params:^Api_Diagnostics_Params,entry:^Console_Entry) -> bool {
        return entry.serial>params.since && entry.level>=params.min_level
    }
    entries:=make([dynamic]Api_Engine_Diagnostics_Result_Console_Entries,allocator)
    if len(c.entries)>0 {
        for i in 0..<c.count {
            if entry:=console_at(c,i);matches(params,entry) {
                append(&entries,Api_Engine_Diagnostics_Result_Console_Entries{int(entry.serial),fmt.tprint(entry.level),strings.clone(api_text_whole(string(entry.text[:entry.length])),allocator),int(entry.repeats)})
            }
        }
    }
    counts:=strings.builder_make(allocator)
    for level in Console_Level {fmt.sbprintf(&counts,`%s"%v":%d`,level==.Debug?"{":",",level,c.counts[level])}
    strings.write_byte(&counts,'}')
    r.omitted=max(len(entries)-params.limit,0)
    r.serial_,r.counts,r.entries=int(c.serial),serial.Json(strings.to_string(counts)),entries[r.omitted:]
    return
}

// What to do about an asset of a version this build does not read: which
// file it is and how to import it again.
@(private="file")
api_asset_stale :: proc(a:^host.Assets,id:base.Asset_Id) -> string {
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return ""}
    path:=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
    data,error:=asset.registry_read(&a.registry,record.path,context.temp_allocator)
    if error!=.None {return ""}
    file:asset.Asset
    if asset.asset_take(&file,data,context.temp_allocator)!=.None {return ""}
    defer asset.asset_close(&file)
    return asset.version_message(&file,&a.types,path,allocator=context.temp_allocator)
}
