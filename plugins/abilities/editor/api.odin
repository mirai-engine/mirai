package abilities_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
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

@(private)
register :: proc(s:^editor.Session) {
    editor.api_method_register(s,Inspect_Params,{name="abilities.inspect",summary="What an Ability_User does and why: its kit, the ability it runs and for how long, the windows open now, its statuses, its attributes with their bases and current values, what waits in its input buffer, its cooldowns and timers, and for every ability of its kit whether it could start now or what blocks it (a status, its mode, a condition, a cost, a cooldown, or no open cancel window of the running ability that accepts its tags). Use it in Play to see why an ability does or does not start.",flags={.Read_Only},result_schema=`{"type":"object"}`,run=inspect})
    editor.api_method_register(s,{name="abilities.check",summary="Checks every Ability and Ability_Kit row of the project as the game runs them: times, windows, hitboxes, effects, costs and conditions, and references to rows that no table has. Returns each problem with its table, its row and how to fix it; an empty list means every sheet runs. Run it after records.set or records.import of abilities.",flags={.Read_Only},result_schema=`{"type":"object"}`,run=check})
    editor.api_method_register(s,Use_Params,{name="abilities.use",summary="Asks an Ability_User of the running game to start an ability by the name of its row, as its input would: it starts when it is valid within the buffer of its kit. Needs Play or Simulate; abilities.inspect tells what blocks it.",result_schema=`{"type":"object"}`,run=use})
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
bits_write :: proc(s:^editor.Session,w:^serial.Writer,key:string,type:typeid,bits:u64,first_key:=false) {
    api.write_key(w,key,first_key)
    serial.text_write_raw(w,"[")
    first:=true
    for i in 0..<64 {
        if bits&(u64(1)<<u64(i))==0 {continue}
        if !first {serial.text_write_raw(w,",")}
        serial.text_write_string(w,value_name(s,type,i64(i)))
        first=false
    }
    serial.text_write_raw(w,"]")
}

@(private)
row_write :: proc(w:^serial.Writer,key:string,rows:core.Records(ab.Ability),ref:core.Record(ab.Ability),first:=false) {
    api.write_key(w,key,first)
    if ref=={} {serial.text_write_raw(w,"null");return}
    if name:=core.record_name(rows,ref);name!="" {serial.text_write_string(w,name)} else {serial.text_write_string(w,fmt.tprintf("missing row %d",u64(ref.row)))}
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_key(w,"kit",true)
    if u.kit=={} {serial.text_write_raw(w,"null")} else {serial.text_write_string(w,core.record_name(kits,u.kit) if core.record_name(kits,u.kit)!="" else "missing row")}
    row_write(w,"ability",abilities,u.ability)
    active:=ab.ability_sheet(abilities,u.ability)
    at:ab.Ability_Time
    if active!=nil {
        at={local=i64(time.tick-u.start) if time.tick>=u.start else 0,own=u.own}
        api.write_key(w,"seconds");api.write_number(w,f32(at.local)*dt)
        api.write_key(w,"own_seconds");api.write_number(w,at.own*dt)
        api.write_key(w,"duration");api.write_number(w,active.duration)
        api.write_key(w,"windows")
        serial.text_write_raw(w,"[")
        listed:=0
        for &win,i in active.windows {
            if !ab.ability_window_open(win,dt,at) {continue}
            if listed>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            api.write_int(w,"index",i64(i),true)
            api.write_key(w,"from");api.write_number(w,win.from)
            api.write_key(w,"to");api.write_number(w,win.to)
            if win.clock==.Own {api.write_text(w,"clock","own")}
            if win.cancel_into!=0 {bits_write(s,w,"cancel_into",ab.Ability_Tag,u64(win.cancel_into))}
            if win.hitbox.shape!=.None {api.write_text(w,"hitbox",fmt.tprintf("%v",win.hitbox.shape))}
            if win.cue!=ab.CUE_NONE {api.write_text(w,"cue",value_name(s,ab.Ability_Cue,i64(win.cue)))}
            serial.text_write_raw(w,"}")
            listed+=1
        }
        serial.text_write_raw(w,"]")
    }
    bits_write(s,w,"statuses",ab.Ability_Status,u64(u.statuses))
    api.write_key(w,"attributes")
    serial.text_write_raw(w,"[")
    listed:=0
    for entry,i in u.attributes {
        if entry.attribute==ab.ATTRIBUTE_NONE {continue}
        if listed>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_text(w,"attribute",value_name(s,ab.Ability_Attribute,i64(entry.attribute)),true)
        api.write_key(w,"base");api.write_number(w,entry.base)
        api.write_key(w,"value");api.write_number(w,u.values[i])
        api.write_key(w,"max");api.write_number(w,entry.max)
        serial.text_write_raw(w,"}")
        listed+=1
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"buffer")
    serial.text_write_raw(w,"[")
    listed=0
    for b in u.buffer {
        if b.ability=={} {continue}
        if listed>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        row_write(w,"ability",abilities,b.ability,true)
        api.write_key(w,"seconds_ago");api.write_number(w,f32(time.tick-b.tick)*dt if time.tick>=b.tick else 0)
        if b.running && u.ability!={} && u.start==b.run {api.write_key(w,"waits_for_running");serial.text_write_raw(w,"true")}
        serial.text_write_raw(w,"}")
        listed+=1
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"cooldowns")
    serial.text_write_raw(w,"[")
    listed=0
    for c in u.cooldowns {
        if c.until<=time.tick {continue}
        if listed>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        row_write(w,"ability",abilities,c.ability,true)
        api.write_key(w,"seconds_left");api.write_number(w,f32(c.until-time.tick)*dt)
        serial.text_write_raw(w,"}")
        listed+=1
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"timers")
    serial.text_write_raw(w,"[")
    listed=0
    for timer in u.timers {
        if timer.until<=time.tick {continue}
        if listed>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        bits_write(s,w,"tags",ab.Ability_Tag,u64(timer.tags),true)
        bits_write(s,w,"statuses",ab.Ability_Status,u64(timer.statuses))
        api.write_int(w,"stacks",i64(timer.stacks))
        if timer.period>0 {api.write_text(w,"every",value_name(s,ab.Ability_Attribute,i64(timer.attribute)));api.write_key(w,"amount");api.write_number(w,timer.amount)}
        if timer.modify.attribute!=ab.ATTRIBUTE_NONE {api.write_text(w,"modifies",value_name(s,ab.Ability_Attribute,i64(timer.modify.attribute)))}
        api.write_key(w,"seconds_left");api.write_number(w,f32(timer.until-time.tick)*dt)
        serial.text_write_raw(w,"}")
        listed+=1
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"candidates")
    serial.text_write_raw(w,"[")
    if kit:=ab.kit_sheet(kits,u.kit);kit!=nil {
        listed=0
        params:ab.Ability_World
        params.time=time
        if t:=core.world_table_of(world,phys.Character);t!=nil {params.characters=core.read(t)}
        text:[512]u8
        for ref in kit.abilities {
            if ref=={} {continue}
            if listed>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            row_write(w,"ability",abilities,ref,true)
            a:=ab.ability_sheet(abilities,ref)
            switch {
            case a==nil: api.write_text(w,"blocked","its row is missing")
            case ab.ability_check(a,text[:])!="": api.write_text(w,"blocked",fmt.tprintf("its sheet is not valid: %s",ab.ability_check(a,text[:])))
            case:
                block:=ab.start_block(&params,time.tick,dt,e,&u,kit,active,at,a,ref)
                api.write_text(w,"blocked",block_text(block))
            }
            serial.text_write_raw(w,"}")
            listed+=1
        }
    }
    serial.text_write_raw(w,"]}")
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
    w:=call.out
    text:[512]u8
    count:=0
    serial.text_write_raw(w,`{"problems":[`)
    problem :: proc(w:^serial.Writer,count:^int,table,row,text:string) {
        if count^>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_text(w,"table",table,true)
        api.write_text(w,"row",row)
        api.write_text(w,"problem",text)
        serial.text_write_raw(w,"}")
        count^+=1
    }
    missing :: proc(rows:core.Records(ab.Ability),ref:core.Record(ab.Ability)) -> bool {return ref!={} && ab.ability_sheet(rows,ref)==nil}
    for i in 0..<core.records_count(abilities) {
        a,ref:=core.records_at(abilities,i)
        table,row:=table_name(abilities.set,ref.table),core.record_name(abilities,ref)
        if t:=ab.ability_check(&a,text[:]);t!="" {problem(w,&count,table,row,t)}
        if missing(abilities,a.next) {problem(w,&count,table,row,"next names a row no table of Ability has: pick another row or none")}
        for win,k in a.windows {
            if missing(abilities,win.hitbox.effect.use) {problem(w,&count,table,row,fmt.tprintf("windows[%d].hitbox.effect.use names a row no table of Ability has: pick another row or none",k))}
        }
    }
    for i in 0..<core.records_count(kits) {
        k,ref:=core.records_at(kits,i)
        table,row:=table_name(kits.set,ref.table),core.record_name(kits,ref)
        if t:=ab.kit_check(&k,text[:]);t!="" {problem(w,&count,table,row,t)}
        for a,n in k.abilities {
            if missing(abilities,a) {problem(w,&count,table,row,fmt.tprintf("abilities[%d] names a row no table of Ability has: pick another row or none",n))}
        }
    }
    serial.text_write_raw(w,"]")
    api.write_int(w,"abilities",i64(core.records_count(abilities)))
    api.write_int(w,"kits",i64(core.records_count(kits)))
    serial.text_write_raw(w,"}")
}

@(private)
use :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Use_Params)
    if !editor.playing(s) {
        api.call_failf(call,api.INVALID_PARAMS,"the game is not running: play.start first")
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"ability",name,true)
    api.write_bool(w,"requested",true)
    serial.text_write_raw(w,"}")
}
