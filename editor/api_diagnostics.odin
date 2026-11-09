package editor

import "core:fmt"
import "core:slice"
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

@(private) API_DIAGNOSTICS_RESULT :: `{"type":"object","properties":{` +
    `"validation":{"type":"object","properties":{"errors":{"type":"integer"},"loader_errors":{"type":"integer"},"messages":{"type":"array","items":{"type":"string"}}},"required":["errors","loader_errors","messages"]},` +
    `"console":{"type":"object","properties":{"serial":{"type":"integer"},"counts":{"type":"object","additionalProperties":{"type":"integer"}},"omitted":{"type":"integer"},"entries":{"type":"array","items":{"type":"object","properties":{"serial":{"type":"integer"},"level":{"enum":["Debug","Info","Warning","Error"]},"text":{"type":"string"},"repeats":{"type":"integer"}},"required":["serial","level","text","repeats"]}}},"required":["serial","counts","omitted","entries"]},` +
    `"asset_errors":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"kind":{"type":"string"},"problem":{"type":"string"},"detail":{"type":"string"},"path":{"type":"string"},"message":{"type":"string"}},"required":["id","kind","problem","detail"]}},` +
    `"build":{"type":"object","properties":{"phase":{"type":"string"},"errors":{"type":"integer"},"diagnostics":{"type":"array","items":{"type":"object","properties":{"severity":{"enum":["Error","Warning"]},"file":{"type":"string"},"line":{"type":"integer"},"column":{"type":"integer"},"message":{"type":"string"}},"required":["severity","file","line","column","message"]}},"text":{"type":"string"}},"required":["phase","errors","diagnostics","text"]},` +
    `"problems":{"type":"array","items":{"type":"object","properties":{"world":{"enum":["edit","play"]},"owner":{"type":"integer"},"player":{"type":"integer"},"serial":{"type":"integer"},"evicted":{"type":"integer"},` +
    `"entries":{"type":"array","items":{"type":"object","properties":{"id":{"type":["string","null"]},"entity":{"type":["string","null"]},"name":{"type":"string"},"alive":{"type":"boolean"},"code":{"type":"string"},"message":{"type":"string","description":"What failed and how to fix it"},"count":{"type":"integer"},"first":{"type":"integer"},"last":{"type":"integer"}},"required":["id","entity","name","alive","code","message","count","first","last"]}}},"required":["world","serial","evicted","entries"]}}` +
    `,"renderer":{"type":"object","properties":{"problem":{"type":"string"}},"required":["problem"]}` +
    `},"required":["validation","renderer","console","asset_errors","build","problems"],"additionalProperties":false}`

@(private)
api_diagnostics_register :: proc(s:^Session,st:^Api_State) {
    defaults:=Api_Diagnostics_Params{min_level=.Info,limit=50}
    api_register(s,st,{name="engine.diagnostics",summary="The text behind the counters of engine.status: what the GPU, the console, the assets and the last build reported, and the problems the functions of the edited world and of each Play met.",params=Api_Diagnostics_Params,result_schema=API_DIAGNOSTICS_RESULT,defaults=&defaults,flags={.Core,.Read_Only},run=api_diagnostics})
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
    out:=call.out
    app:=s.app
    errors,loader:int
    history:[rhi.VALIDATION_HISTORY]string
    shown:=0
    if app!=nil && app.device!=nil {
        errors,loader=rhi.device_validation_errors(app.device),rhi.device_loader_errors(app.device)
        shown=rhi.device_validation_messages(app.device,history[:])
    }
    serial.text_write_raw(out,`{"validation":{`)
    api.write_int(out,"errors",i64(errors),true)
    api.write_int(out,"loader_errors",i64(loader))
    api.write_key(out,"messages");serial.write_u8(out,'[')
    for message,i in history[:shown] {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,api_text_whole(message))
    }
    serial.text_write_raw(out,`]}`)
    problem:string
    if app!=nil && app.renderer!=nil {problem=gpu.renderer_stats(app.renderer).problem}
    api.write_key(out,"renderer");serial.write_u8(out,'{')
    api.write_text(out,"problem",problem,true)
    serial.write_u8(out,'}')
    if s.console!=nil {api_diagnostics_console(s.console,params,out)}
    api.write_key(out,"asset_errors");serial.write_u8(out,'[')
    if app!=nil && app.assets!=nil {
        listed:=host.assets_errors(app.assets)
        for known,i in listed[:min(len(listed),API_DIAGNOSTICS_LIMIT)] {
            if i>0 {serial.write_u8(out,',')}
            buffer:[base.ASSET_ID_TEXT]u8
            serial.write_u8(out,'{')
            api.write_text(out,"id",base.asset_id_format(known.id,buffer[:]),true)
            api.write_text(out,"kind",fmt.tprint(known.kind))
            api.write_text(out,"problem",fmt.tprint(known.problem))
            api.write_text(out,"detail",fmt.tprint(known.detail))
            if known.detail==.Version {api.write_text(out,"message",api_asset_stale(app.assets,known.id))}
            serial.write_u8(out,'}')
        }
        api_duplicates_write(&app.assets.registry,out,len(listed)==0)
    }
    serial.write_u8(out,']')
    api.write_key(out,"build");serial.write_u8(out,'{')
    if b:=s.build;b!=nil {
        api.write_text(out,"phase",fmt.tprint(b.phase),true)
        api.write_int(out,"errors",i64(len(b.diagnostics)))
        api.write_key(out,"diagnostics");serial.write_u8(out,'[')
        for d,i in b.diagnostics[:min(len(b.diagnostics),API_DIAGNOSTICS_LIMIT)] {
            if i>0 {serial.write_u8(out,',')}
            serial.write_u8(out,'{')
            api.write_text(out,"severity",fmt.tprint(d.severity),true)
            api.write_text(out,"file",d.file)
            api.write_int(out,"line",i64(d.line))
            api.write_int(out,"column",i64(d.column))
            api.write_text(out,"message",d.message)
            serial.write_u8(out,'}')
        }
        serial.write_u8(out,']')
        text:=b.text
        if len(b.shaders_text)>0 {text=len(text)>0?fmt.tprintf("%s\n%s",b.shaders_text,text):b.shaders_text}
        api.write_text(out,"text",api_text_whole(text[:min(len(text),API_DIAGNOSTICS_BUILD_TEXT)]))
    } else {
        api.write_text(out,"phase","Idle",true)
        api.write_int(out,"errors",0)
        api.write_key(out,"diagnostics");serial.text_write_raw(out,"[]")
        api.write_text(out,"text","")
    }
    serial.write_u8(out,'}')
    api.write_key(out,"problems");serial.write_u8(out,'[')
    listed:=api_diagnostics_problems(s,edited_world(s),nil,out,true)
    for &r in s.runs {
        if r.world!=nil && api_diagnostics_problems(s,run_ref(s,&r),&r,out,!listed) {listed=true}
    }
    serial.text_write_raw(out,"]}")
}

// The problems of a world, the oldest first: those of the run r, or of the
// edited world. False when the world has none to list.
@(private)
api_diagnostics_problems :: proc(s:^Session,w:core.World_Ref,r:^Run,out:^serial.Writer,first:bool) -> bool {
    if w.data==nil || s.app==nil {return false}
    problems:=host.app_world_storage(s.app,w.data,core.Problems)
    if problems==nil {return false}
    if !first {serial.write_u8(out,',')}
    serial.write_u8(out,'{')
    api.write_text(out,"world",r!=nil?"play":"edit",true)
    if r!=nil {
        api.write_int(out,"owner",i64(r.owner))
        api.write_int(out,"player",i64(r.player))
    }
    api_problems_write(w,problems,out)
    serial.write_u8(out,'}')
    return true
}

// The serial, the evicted and the entries of the problems of a world, the
// oldest first, after the first key of an object.
@(private)
api_problems_write :: proc(w:core.World_Ref,problems:^core.Problems,out:^serial.Writer) {
    api.write_uint(out,"serial",problems.serial)
    api.write_uint(out,"evicted",problems.evicted)
    api.write_key(out,"entries");serial.write_u8(out,'[')
    listed:=slice.clone(core.problems_list(problems),context.temp_allocator)
    slice.sort_by(listed,proc(a,b:core.Problem) -> bool {return a.first<b.first})
    entities:=core.world_entities(w)
    for &p,i in listed {
        if i>0 {serial.write_u8(out,',')}
        named:=p.entity!=core.NONE
        serial.write_u8(out,'{')
        api.write_key(out,"id",true)
        if id:=api_entity_id(w,p.entity);named && id!=0 {api.write_id(out,id)} else {serial.text_write_raw(out,"null")}
        api.write_key(out,"entity")
        if named {serial.write_u8(out,'"');serial.text_write_hex(out,u64(p.entity));serial.write_u8(out,'"')} else {serial.text_write_raw(out,"null")}
        api.write_text(out,"name",entity_name(w,p.entity) if named else "")
        api.write_bool(out,"alive",named && core.alive(entities,p.entity))
        api.write_text(out,"code",core.problem_code(&p))
        api.write_text(out,"message",api_text_whole(core.problem_text(&p)))
        api.write_uint(out,"count",p.count)
        api.write_uint(out,"first",p.first)
        api.write_uint(out,"last",p.last)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
}

// The entries of the console that are newer than since and reach min_level,
// the newest limit of them, oldest first.
@(private)
api_diagnostics_console :: proc(c:^Console,params:^Api_Diagnostics_Params,out:^serial.Writer) {
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    matches :: proc(params:^Api_Diagnostics_Params,entry:^Console_Entry) -> bool {
        return entry.serial>params.since && entry.level>=params.min_level
    }
    total:=0
    if len(c.entries)>0 {
        for i in 0..<c.count {
            if matches(params,console_at(c,i)) {total+=1}
        }
    }
    skip:=max(total-params.limit,0)
    api.write_key(out,"console");serial.text_write_raw(out,`{"serial":`);serial.text_write_uint(out,c.serial)
    api.write_key(out,"counts");serial.write_u8(out,'{')
    for level in Console_Level {
        api.write_int(out,fmt.tprint(level),i64(c.counts[level]),level==.Debug)
    }
    serial.write_u8(out,'}')
    api.write_int(out,"omitted",i64(skip))
    api.write_key(out,"entries");serial.write_u8(out,'[')
    seen,written:=0,0
    if len(c.entries)>0 {
        for i in 0..<c.count {
            entry:=console_at(c,i)
            if !matches(params,entry) {continue}
            seen+=1
            if seen<=skip {continue}
            if written>0 {serial.write_u8(out,',')}
            written+=1
            serial.write_u8(out,'{')
            api.write_uint(out,"serial",entry.serial,true)
            api.write_text(out,"level",fmt.tprint(entry.level))
            api.write_text(out,"text",api_text_whole(string(entry.text[:entry.length])))
            api.write_uint(out,"repeats",u64(entry.repeats))
            serial.write_u8(out,'}')
        }
    }
    serial.text_write_raw(out,"]}")
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
