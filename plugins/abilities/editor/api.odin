package abilities_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import ab "plugins:abilities/runtime"
import phys "plugins:physics/runtime"

@(storage)
Abilities_Api :: struct {provider:editor.Api_Provider}

ABILITIES_API_DEFAULT :: Abilities_Api{provider={register=register}}

Inspect_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
}

Use_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    ability:[ab.ABILITY_NAME]u8 `mirai:"text,label=The name of an Ability row"`,
    table:[1024]u8 `mirai:"text,optional,label=The .records path when two tables have a row of that name"`,
}

Inspect_Result :: struct {
    kit:string `mirai:"optional,label=Its Ability_Kit row; left out without a kit"`,
    ability:string `mirai:"optional,label=The Ability row it runs; left out when idle"`,
    seconds:f32 `mirai:"optional,unit=s,label=Since the running ability started"`,
    own_seconds:f32 `mirai:"optional,unit=s,label=On the clock of the running ability"`,
    duration:f32 `mirai:"optional,unit=s"`,
    windows:[]Window_Result `mirai:"optional,label=The windows of the running ability open now"`,
    statuses:[]string,
    attributes:[]Attribute_Result,
    buffer:[]Buffer_Result `mirai:"label=What waits in its input buffer"`,
    cooldowns:[]Cooldown_Result,
    timers:[]Timer_Result,
    candidates:[]Candidate_Result `mirai:"label=Every ability of its kit and what blocks it"`,
}
Window_Result :: struct {
    index:int,
    from,to:f32 `mirai:"unit=s"`,
    clock:string `mirai:"optional,label=own: on the clock of the ability"`,
    cancel_into:[]string `mirai:"optional"`,
    hitbox:string `mirai:"optional"`,
    cue:string `mirai:"optional"`,
}
Attribute_Result :: struct {
    attribute:string,
    base,value,max:f32,
}
Buffer_Result :: struct {
    ability:string,
    seconds_ago:f32 `mirai:"unit=s"`,
    waits_for_running:bool `mirai:"optional"`,
}
Cooldown_Result :: struct {
    ability:string,
    seconds_left:f32 `mirai:"unit=s"`,
}
Timer_Result :: struct {
    tags,statuses:[]string,
    stacks:int,
    every:string `mirai:"optional,label=The attribute it changes each period"`,
    amount:f32 `mirai:"optional"`,
    modifies:string `mirai:"optional"`,
    seconds_left:f32 `mirai:"unit=s"`,
}
Candidate_Result :: struct {
    ability:string,
    blocked:string,
}

Check_Result :: struct {
    problems:[]Check_Problem `mirai:"label=Empty: every sheet runs"`,
    abilities,kits:int `mirai:"label=Rows of Ability and of Ability_Kit"`,
}
Check_Problem :: struct {table,row,problem:string}

Use_Result :: struct {
    ability:string,
    requested:bool,
}

@(private)
register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="abilities.inspect",summary="What an Ability_User does and why: its kit, the ability it runs and for how long, the windows open now, its statuses, its attributes with their bases and current values, what waits in its input buffer, its cooldowns and timers, and for every ability of its kit whether it could start now or what blocks it (a status, its mode, a condition, a cost, a cooldown, or no open cancel window of the running ability that accepts its tags). Use it in Play to see why an ability does or does not start.",params=Inspect_Params,params_info=type_info_of(Inspect_Params),flags={.Read_Only},result=Inspect_Result,result_info=type_info_of(Inspect_Result),run=inspect})
    editor.api_method_register(s,{name="abilities.check",summary="Checks every Ability and Ability_Kit row of the project as the game runs them: times, windows, hitboxes, effects, costs and conditions, and references to rows that no table has. Returns each problem with its table, its row and how to fix it; an empty list means every sheet runs. Run it after records.set or records.import of abilities.",flags={.Read_Only},result=Check_Result,result_info=type_info_of(Check_Result),run=check})
    editor.api_method_register(s,{name="abilities.use",summary="Asks an Ability_User of the running game to start an ability by the name of its row, as its input would: it starts when it is valid within the buffer of its kit. Needs Play or Simulate; abilities.inspect tells what blocks it.",params=Use_Params,params_info=type_info_of(Use_Params),result=Use_Result,result_info=type_info_of(Use_Result),run=use})
}

@(private)
sets :: proc(s:^editor.Session) -> (abilities:core.Records(ab.Ability),kits:core.Records(ab.Ability_Kit)) {
    if s.app==nil {return}
    if i:=core.record_of_ref(s.info,core.Record(ab.Ability));i>=0 {abilities.set=host.app_record_set(s.app,i)}
    if i:=core.record_of_ref(s.info,core.Record(ab.Ability_Kit));i>=0 {kits.set=host.app_record_set(s.app,i)}
    return
}

@(private)
table_name :: proc(set:^core.Record_Set,table:base.Asset_Id) -> string {
    if set==nil {return ""}
    for &t in set.tables {if t.id==table {return base.text_get(t.name[:])}}
    return ""
}

// The name of a value of a type @(names), or its number.
@(private)
value_name :: proc(s:^editor.Session,type:typeid,value:i64) -> string {
    for n in core.names_of(s.info,type) {if n.value==value {return n.name}}
    return fmt.tprintf("%d",value)
}

@(private)
bits_names :: proc(s:^editor.Session,call:^api.Call,type:typeid,bits:u64) -> []string {
    names:=make([dynamic]string,call.allocator)
    for i in 0..<64 {
        if bits&(u64(1)<<u64(i))!=0 {append(&names,value_name(s,type,i64(i)))}
    }
    return names[:]
}

@(private)
row_name :: proc(rows:core.Records(ab.Ability),ref:core.Record(ab.Ability)) -> string {
    if ref=={} {return ""}
    if name:=core.record_name(rows,ref);name!="" {return name}
    return fmt.tprintf("missing row %d",u64(ref.row))
}

@(private)
inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Inspect_Params)
    world:=editor.shown_world(s)
    e,named:=editor.api_call_entity(call,world,p.entity[:],game=s.mode!=.Edit)
    if !named {return}
    users:=core.world_table_of(world,ab.Ability_User)
    if users==nil || !core.has(users,e) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with an Ability_User in the shown world: add one, or pick another entity",base.text_get(p.entity[:]))
        return
    }
    u,_:=core.get(users,e)
    abilities,kits:=sets(s)
    time:core.Time
    if t:=core.world_storage_of(world,core.Time);t!=nil {time=t^}
    dt:=time.dt
    if !(dt>0) {
        dt=1.0/60
        if settings:=core.world_storage_of(world,core.Simulation_Settings);settings!=nil && settings.tick_rate>0 {dt=1/f32(settings.tick_rate)}
    }
    r:=api.call_result(call,Inspect_Result)
    if u.kit!={} {r.kit=core.record_name(kits,u.kit) if core.record_name(kits,u.kit)!="" else "missing row"}
    r.ability=row_name(abilities,u.ability)
    active:=ab.ability_sheet(abilities,u.ability)
    at:ab.Ability_Time
    if active!=nil {
        at={local=i64(time.tick-u.start) if time.tick>=u.start else 0,own=u.own}
        r.seconds,r.own_seconds,r.duration=f32(at.local)*dt,at.own*dt,active.duration
        windows:=make([dynamic]Window_Result,call.allocator)
        for &win,i in active.windows {
            if !ab.ability_window_open(win,dt,at) {continue}
            shown:=Window_Result{index=i,from=win.from,to=win.to,cancel_into=bits_names(s,call,ab.Ability_Tag,u64(win.cancel_into))}
            if win.clock==.Own {shown.clock="own"}
            if win.hitbox.shape!=.None {shown.hitbox=fmt.tprintf("%v",win.hitbox.shape)}
            if win.cue!=ab.CUE_NONE {shown.cue=value_name(s,ab.Ability_Cue,i64(win.cue))}
            append(&windows,shown)
        }
        r.windows=windows[:]
    }
    r.statuses=bits_names(s,call,ab.Ability_Status,u64(u.statuses))
    attributes:=make([dynamic]Attribute_Result,call.allocator)
    for entry,i in u.attributes {
        if entry.attribute!=ab.ATTRIBUTE_NONE {append(&attributes,Attribute_Result{value_name(s,ab.Ability_Attribute,i64(entry.attribute)),entry.base,u.values[i],entry.max})}
    }
    r.attributes=attributes[:]
    buffer:=make([dynamic]Buffer_Result,call.allocator)
    for b in u.buffer {
        if b.ability!={} {append(&buffer,Buffer_Result{row_name(abilities,b.ability),f32(time.tick-b.tick)*dt if time.tick>=b.tick else 0,b.running && u.ability!={} && u.start==b.run})}
    }
    r.buffer=buffer[:]
    cooldowns:=make([dynamic]Cooldown_Result,call.allocator)
    for c in u.cooldowns {
        if c.until>time.tick {append(&cooldowns,Cooldown_Result{row_name(abilities,c.ability),f32(c.until-time.tick)*dt})}
    }
    r.cooldowns=cooldowns[:]
    timers:=make([dynamic]Timer_Result,call.allocator)
    for timer in u.timers {
        if timer.until<=time.tick {continue}
        shown:=Timer_Result{tags=bits_names(s,call,ab.Ability_Tag,u64(timer.tags)),statuses=bits_names(s,call,ab.Ability_Status,u64(timer.statuses)),stacks=int(timer.stacks),seconds_left=f32(timer.until-time.tick)*dt}
        if timer.period>0 {shown.every,shown.amount=value_name(s,ab.Ability_Attribute,i64(timer.attribute)),timer.amount}
        if timer.modify.attribute!=ab.ATTRIBUTE_NONE {shown.modifies=value_name(s,ab.Ability_Attribute,i64(timer.modify.attribute))}
        append(&timers,shown)
    }
    r.timers=timers[:]
    candidates:=make([dynamic]Candidate_Result,call.allocator)
    if kit:=ab.kit_sheet(kits,u.kit);kit!=nil {
        params:ab.Ability_World
        params.time=time
        if t:=core.world_table_of(world,phys.Character);t!=nil {params.characters=core.read(t)}
        text:[512]u8
        for ref in kit.abilities {
            if ref=={} {continue}
            a:=ab.ability_sheet(abilities,ref)
            blocked:string
            switch {
            case a==nil: blocked="its row is missing"
            case ab.ability_check(a,text[:])!="": blocked=fmt.tprintf("its sheet is not valid: %s",ab.ability_check(a,text[:]))
            case: blocked=block_text(ab.start_block(&params,time.tick,dt,e,&u,kit,active,at,a,ref))
            }
            append(&candidates,Candidate_Result{row_name(abilities,ref),blocked})
        }
    }
    r.candidates=candidates[:]
}

@(private)
block_text :: proc(block:ab.Ability_Block) -> string {
    switch block {
    case .None: return "none: it starts when its input fires"
    case .Status_Missing: return "the user is not in a status it requires"
    case .Status_Blocked: return "the user is in a status that blocks it"
    case .Mode: return "the user's Character is not in one of its modes"
    case .Condition: return "an attribute is out of one of its conditions"
    case .Cost: return "an attribute has less than one of its costs"
    case .Cooldown: return "its cooldown runs"
    case .No_Cancel: return "the running ability has no open window whose cancel_into has one of its tags, and the kit's interrupts do not either"
    }
    return ""
}

@(private)
check :: proc(s:^editor.Session,call:^api.Call) {
    abilities,kits:=sets(s)
    text:[512]u8
    problems:=make([dynamic]Check_Problem,call.allocator)
    missing :: proc(rows:core.Records(ab.Ability),ref:core.Record(ab.Ability)) -> bool {return ref!={} && ab.ability_sheet(rows,ref)==nil}
    for i in 0..<core.records_count(abilities) {
        a,ref:=core.records_at(abilities,i)
        table,row:=table_name(abilities.set,ref.table),core.record_name(abilities,ref)
        if t:=ab.ability_check(&a,text[:]);t!="" {append(&problems,Check_Problem{table,row,fmt.tprint(t)})}
        if missing(abilities,a.next) {append(&problems,Check_Problem{table,row,"next names a row no table of Ability has: pick another row or none"})}
        for win,k in a.windows {
            if missing(abilities,win.hitbox.effect.use) {append(&problems,Check_Problem{table,row,fmt.tprintf("windows[%d].hitbox.effect.use names a row no table of Ability has: pick another row or none",k)})}
        }
    }
    for i in 0..<core.records_count(kits) {
        k,ref:=core.records_at(kits,i)
        table,row:=table_name(kits.set,ref.table),core.record_name(kits,ref)
        if t:=ab.kit_check(&k,text[:]);t!="" {append(&problems,Check_Problem{table,row,fmt.tprint(t)})}
        for a,n in k.abilities {
            if missing(abilities,a) {append(&problems,Check_Problem{table,row,fmt.tprintf("abilities[%d] names a row no table of Ability has: pick another row or none",n)})}
        }
    }
    api.call_result(call,Check_Result)^={problems[:],core.records_count(abilities),core.records_count(kits)}
}

@(private)
use :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Use_Params)
    if !editor.playing(s) {
        editor.api_no_game(call)
        return
    }
    world:=editor.shown_world(s)
    e,named:=editor.api_call_entity(call,world,p.entity[:],game=true)
    if !named {return}
    users:=core.world_table_of(world,ab.Ability_User)
    if users==nil || !core.has(users,e) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with an Ability_User in the running game: add one, or pick another entity",base.text_get(p.entity[:]))
        return
    }
    abilities,_:=sets(s)
    name,table:=base.text_get(p.ability[:]),base.text_get(p.table[:])
    found:core.Record(ab.Ability)
    matches:=0
    for i in 0..<core.records_count(abilities) {
        _,ref:=core.records_at(abilities,i)
        if core.record_name(abilities,ref)!=name || table!="" && table_name(abilities.set,ref.table)!=table {continue}
        found=ref
        matches+=1
    }
    if matches==0 {
        api.call_failf(call,api.INVALID_PARAMS,"no table of Ability has a row named %q%s: records.inspect lists the rows",name,table!="" ? fmt.tprintf(" in %s",table) : "")
        return
    }
    if matches>1 {
        api.call_failf(call,api.INVALID_PARAMS,"%d tables of Ability have a row named %q: give its table",matches,name)
        return
    }
    requests:=core.world_storage_of(world,ab.Ability_Requests)
    if requests==nil || len(requests.queue.items)>=cap(requests.queue.items) {
        api.call_failf(call,api.SERVER_ERROR,"the requests of abilities are full: step the game and ask again, or raise Ability_Settings.requests")
        return
    }
    ab.ability_use(requests,e,found)
    api.call_result(call,Use_Result)^={name,true}
}
