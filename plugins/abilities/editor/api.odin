package abilities_editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import ab "plugins:abilities/runtime"
import locomotion "plugins:locomotion/runtime"
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
    hitbox:Hitbox_Result `mirai:"optional,label=Its hitbox where it is now; left out without one"`,
    cue:string `mirai:"optional"`,
}
Hitbox_Result :: struct {
    shape:ab.Hitbox_Shape,
    center:mm.Vec3 `mirai:"unit=m,label=In the world"`,
    rotation:mm.Quat `mirai:"label=Its axes in the world, those of the user"`,
    size:mm.Vec3 `mirai:"unit=m,label=Box half extents, sphere radius, or capsule radius and half height"`,
    targets:[]string `mirai:"optional,label=What it already hit in this run of the ability, each once: by name or path, or the handle of an entity the game made"`,
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
    editor.api_method_register(s,{name="abilities.inspect",summary="What an Ability_User does and why: its kit, the ability it runs and for how long, the windows open now, its statuses, its attributes with their bases and current values, what waits in its input buffer, its cooldowns and timers, and for every ability of its kit whether it could start now or what blocks it (a status, its mode, a condition, a cost, a cooldown, or no open cancel window of the running ability that accepts its tags). Use it in Play to see why an ability does or does not start.",params=type_info_of(Inspect_Params),flags={.Read_Only},result=type_info_of(Inspect_Result),run=inspect})
    editor.api_method_register(s,{name="abilities.check",summary="Checks every Ability and Ability_Kit row of the project as the game runs them: times, windows, hitboxes, effects, costs and conditions, and references to rows that no table has. Returns each problem with its table, its row and how to fix it; an empty list means every sheet runs. Run it after records.set or records.import of abilities.",flags={.Read_Only},result=type_info_of(Check_Result),run=check})
    editor.api_method_register(s,{name="abilities.use",summary="Asks an Ability_User of the running game to start an ability by the name of its row, as its input would: it starts when it is valid within the buffer of its kit. Needs Play or Simulate; abilities.inspect tells what blocks it.",params=type_info_of(Use_Params),result=type_info_of(Use_Result),run=use})
}

@(private)
records :: proc(s:^editor.Session,$T:typeid) -> core.Records(T) {
    if s.app!=nil {
        if i:=core.record_of_ref(s.info,core.Record(T));i>=0 {return {host.app_record_set(s.app,i)}}
    }
    return {}
}

@(private)
sets :: proc(s:^editor.Session) -> ab.Ability_Data {
    return {records(s,ab.Ability),records(s,ab.Ability_Kit),
        records(s,ab.Ability_Hitbox),records(s,ab.Ability_Feedback)}
}

@(private)
sheet_cache :: proc(s:^editor.Session,data:ab.Ability_Data) -> ^ab.Ability_Sheets {
    if s.app==nil {return nil}
    shared:=core.world_ref(s.app.shared,s.info,.Shared)
    cache:=core.world_storage_of(shared,ab.Ability_Sheets)
    context.allocator=s.app.allocator
    if cache==nil || !ab.sheets_refresh(cache,data) {return nil}
    return cache
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
    names:=make([dynamic]string,call.allocator if call!=nil else context.temp_allocator)
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
    state:ab.Ability_State
    track:ab.Ability_Tracking
    state_found:=false
    if rows:=core.world_table_of(world,ab.Ability_State);rows!=nil {state,state_found=core.get(rows,e)}
    if rows:=core.world_table_of(world,ab.Ability_Tracking);rows!=nil {track,_=core.get(rows,e)}
    data:=sets(s)
    abilities,kits:=data.abilities,data.kits
    time,dt:=world_clock(world)
    r:=api.call_result(call,Inspect_Result)
    if u.kit!={} {r.kit=core.record_name(kits,u.kit) if core.record_name(kits,u.kit)!="" else "missing row"}
    r.ability=row_name(abilities,state.ability)
    active:=ab.record_sheet(abilities,state.ability)
    at:=running_at(time,&state)
    if active!=nil {
        r.seconds,r.own_seconds,r.duration=f32(at.local)*dt,at.own*dt,active.duration
        windows:=make([dynamic]Window_Result,call.allocator)
        for &win,i in active.windows {
            if !ab.ability_window_open(win,dt,at) {continue}
            shown:=Window_Result{index=i,from=win.from,to=win.to,cancel_into=bits_names(s,call,ab.Ability_Tag,u64(win.cancel_into))}
            if win.clock==.Own {shown.clock="own"}
            if hitbox:=ab.record_sheet(data.hitboxes,win.hitbox);hitbox!=nil {shown.hitbox=window_hitbox(world,e,&track,hitbox,i,call.allocator)}
            if win.cue!=ab.CUE_NONE {shown.cue=value_name(s,ab.Ability_Cue,i64(win.cue))}
            append(&windows,shown)
        }
        r.windows=windows[:]
    }
    r.statuses=bits_names(s,call,ab.Ability_Status,u64(state.statuses))
    attributes:=make([dynamic]Attribute_Result,call.allocator)
    for entry,i in u.attributes {
        if entry.attribute!=ab.ATTRIBUTE_NONE {append(&attributes,Attribute_Result{value_name(s,ab.Ability_Attribute,i64(entry.attribute)),entry.base,state.values[i] if state_found else entry.base,entry.max})}
    }
    r.attributes=attributes[:]
    buffer:=make([dynamic]Buffer_Result,call.allocator)
    for b in track.buffer {
        if b.ability!={} {append(&buffer,Buffer_Result{row_name(abilities,b.ability),f32(time.tick-b.tick)*dt if time.tick>=b.tick else 0,b.running && state.ability!={} && state.start==b.run})}
    }
    r.buffer=buffer[:]
    cooldowns:=make([dynamic]Cooldown_Result,call.allocator)
    for c in track.cooldowns {
        if c.until>time.tick {append(&cooldowns,Cooldown_Result{row_name(abilities,c.ability),f32(c.until-time.tick)*dt})}
    }
    r.cooldowns=cooldowns[:]
    timers:=make([dynamic]Timer_Result,call.allocator)
    for timer in track.timers {
        if timer.until<=time.tick {continue}
        shown:=Timer_Result{tags=bits_names(s,call,ab.Ability_Tag,u64(timer.tags)),statuses=bits_names(s,call,ab.Ability_Status,u64(timer.statuses)),stacks=int(timer.stacks),seconds_left=f32(timer.until-time.tick)*dt}
        if timer.period>0 {shown.every,shown.amount=value_name(s,ab.Ability_Attribute,i64(timer.attribute)),timer.amount}
        if timer.modify.attribute!=ab.ATTRIBUTE_NONE {shown.modifies=value_name(s,ab.Ability_Attribute,i64(timer.modify.attribute))}
        append(&timers,shown)
    }
    r.timers=timers[:]
    candidates:=make([dynamic]Candidate_Result,call.allocator)
    sheets:=sheet_cache(s,data)
    if sheets==nil {
        api.call_failf(call,api.SERVER_ERROR,"out of memory for ability validation")
        return
    }
    if kit:=ab.record_sheet(kits,u.kit);kit!=nil {
        params:ab.Ability_World
        params.time=time
        if t:=core.world_table_of(world,phys.Character);t!=nil {params.characters=core.read(t)}
        if t:=core.world_table_of(world,locomotion.Locomotion_State);t!=nil {params.locomotions=core.read(t)}
        if t:=core.world_table_of(world,phys.Character_State);t!=nil {params.grounds=core.read(t)}
        if t:=core.world_table_of(world,core.Motion);t!=nil {params.motions=core.read(t)}
        if t:=core.world_table_of(world,core.World_Transform);t!=nil {params.worlds=core.read(t)}
        params.physics=core.ref(core.world_storage_of(world,phys.Physics_State))
        for ref in kit.abilities {
            if ref=={} {continue}
            row:=ab.record_row(abilities,ref)
            a:=ab.record_at(abilities,row)
            blocked:="its row is missing"
            if a!=nil {
                if problem:=base.text_get(sheets.abilities[row][:]);problem!="" {
                    blocked=fmt.tprintf("its sheet is not valid: %s",problem)
                } else {
                    block,index:=ab.start_block(&params,time.tick,dt,e,&u,&state,&track,state.statuses,kit,active,at,a,ref)
                    blocked=block_text(s,block,index,a,&u,&state,&track,time.tick,dt)
                }
            }
            append(&candidates,Candidate_Result{row_name(abilities,ref),blocked})
        }
    }
    r.candidates=candidates[:]
}

// What blocks a, as start_block found it with what fails at index: the status, the mode, the
// condition or the cost with its value now against what it needs, or the cooldown left.
@(private)
block_text :: proc(s:^editor.Session,block:ab.Ability_Block,index:int,a:^ab.Ability,user:^ab.Ability_User,state:^ab.Ability_State,track:^ab.Ability_Tracking,tick:u64,dt:f32) -> string {
    attribute :: proc(s:^editor.Session,user:^ab.Ability_User,state:^ab.Ability_State,attribute:ab.Ability_Attribute) -> (name,value:string) {
        name=value_name(s,ab.Ability_Attribute,i64(attribute))
        current,found:=ab.ability_value(user,state,attribute)
        return name,fmt.tprintf("%g",current) if found else "missing from the Ability_User"
    }
    switch block {
    case .None: return "none: it starts when its input fires"
    case .Status_Missing: return fmt.tprintf("it requires the status %s, which the user is not in",value_name(s,ab.Ability_Status,i64(index)))
    case .Status_Blocked: return fmt.tprintf("the user is in the status %s, which blocks it",value_name(s,ab.Ability_Status,i64(index)))
    case .Mode:
        modes:=strings.join(bits_names(s,nil,locomotion.Locomotion_Mode,u64(a.modes)),", ",context.temp_allocator)
        if index<0 {return fmt.tprintf("it starts only in the modes %s and the user has no locomotion mode",modes)}
        return fmt.tprintf("the user's Character is in the mode %s, and it starts only in %s",value_name(s,locomotion.Locomotion_Mode,i64(index)),modes)
    case .Condition:
        if index<0 || index>=len(a.conditions) {break}
        c:=a.conditions[index]
        bounds:=fmt.tprintf("at least %g",c.at_least) if c.at_most<=0 else fmt.tprintf("from %g to %g",c.at_least,c.at_most)
        switch c.kind {
        case .Attribute:
            name,value:=attribute(s,user,state,c.attribute)
            return fmt.tprintf("condition %d: %s is %s and has to be %s",index,name,value,bounds)
        case .Speed: return fmt.tprintf("condition %d: the speed of its Character over the ground has to be %s m/s",index,bounds)
        case .Ledge_Ahead: return fmt.tprintf("condition %d: its Character stands with no ledge at least %g m deep within %g m ahead",index,c.at_least,c.reach)
        }
    case .Cost:
        if index<0 || index>=len(a.costs) {break}
        c:=a.costs[index]
        name,value:=attribute(s,user,state,c.attribute)
        return fmt.tprintf("cost %d: %s is %s, less than the %g it costs",index,name,value,c.amount)
    case .Cooldown:
        if index<0 || index>=len(track.cooldowns) {break}
        left:=track.cooldowns[index].until-tick if track.cooldowns[index].until>tick else 0
        return fmt.tprintf("its cooldown runs for %g s more",f32(left)*dt)
    case .No_Cancel: return "the running ability has no open window whose cancel_into has one of its tags, and the kit's interrupts do not either"
    }
    return fmt.tprintf("%v",block)
}

// The tick of a world and the seconds of a tick.
@(private)
world_clock :: proc(world:core.World_Ref) -> (time:core.Time,dt:f32) {
    if t:=core.world_storage_of(world,core.Time);t!=nil {time=t^}
    dt=time.dt
    if !(dt>0) {
        dt=1.0/60
        if settings:=core.world_storage_of(world,core.Simulation_Settings);settings!=nil && settings.tick_rate>0 {dt=1/f32(settings.tick_rate)}
    }
    return
}

// Where the running ability of a user is on its clocks.
@(private)
running_at :: proc(time:core.Time,state:^ab.Ability_State) -> ab.Ability_Time {
    if state.ability=={} {return {}}
    return {local=i64(time.tick-state.start) if time.tick>=state.start else 0,own=state.own}
}

// Where the user e is in world: its World_Transform, or the identity without one.
@(private)
user_pose :: proc(world:core.World_Ref,e:core.Entity) -> mm.Transform {
    if worlds:=core.world_table_of(world,core.World_Transform);worlds!=nil {
        if placed,found:=core.get(worlds,e);found {return placed.transform}
    }
    return mm.TRANSFORM_IDENTITY
}

// The hitbox h of the window at index of the ability user e runs, where it is now in world, with
// what it hit.
@(private)
window_hitbox :: proc(world:core.World_Ref,e:core.Entity,track:^ab.Ability_Tracking,h:^ab.Ability_Hitbox,window:int,allocator:=context.temp_allocator) -> (r:Hitbox_Result) {
    center,rotation:=ab.hitbox_world(h,user_pose(world,e))
    r={shape=h.shape,center=center,rotation=rotation,size=h.size}
    hit:=window_targets(track,window)
    if len(hit)==0 {return}
    r.targets=make([]string,len(hit),allocator)
    for target,i in hit {r.targets[i]=entity_text(world,target,allocator)}
    return
}

// What the window at index of the running ability hit since it started.
@(private)
window_targets :: proc(track:^ab.Ability_Tracking,window:int) -> []core.Entity {
    targets:=make([dynamic]core.Entity,context.temp_allocator)
    for j in 0..<min(int(track.hit_count),len(track.targets)) {
        if int(track.windows[j])==window {append(&targets,track.targets[j])}
    }
    return targets[:]
}

// An entity by its path, or its handle when it has no name.
@(private)
entity_text :: proc(world:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> string {
    if path:=editor.api_entity_path(world,e,allocator);path!="" {return path}
    return fmt.aprintf("0x%016x",u64(e),allocator=allocator)
}

@(private)
check :: proc(s:^editor.Session,call:^api.Call) {
    data:=sets(s)
    sheets:=sheet_cache(s,data)
    if sheets==nil {
        api.call_failf(call,api.SERVER_ERROR,"out of memory for ability validation")
        return
    }
    problems:=make([dynamic]Check_Problem,call.allocator)
    for &problem,i in sheets.abilities {add_problem(&problems,data.abilities.set,i,problem[:])}
    for &problem,i in sheets.kits {add_problem(&problems,data.kits.set,i,problem.problem[:])}
    for &problem,i in sheets.hitboxes {add_problem(&problems,data.hitboxes.set,i,problem[:])}
    api.call_result(call,Check_Result)^={problems[:],len(sheets.abilities),len(sheets.kits)}
}

@(private)
add_problem :: proc(problems:^[dynamic]Check_Problem,set:^core.Record_Set,i:int,text:[]u8) {
    message:=base.text_get(text)
    if message=="" {return}
    row:=&set.rows[i]
    append(problems,Check_Problem{table_name(set,row.table),base.text_get(row.name[:]),fmt.tprint(message)})
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
    abilities:=records(s,ab.Ability)
    name,table:=base.text_get(p.ability[:]),base.text_get(p.table[:])
    found:core.Record(ab.Ability)
    matches:=0
    for i in 0..<core.records_count(abilities) {
        row:=&abilities.set.rows[i]
        ref:=core.Record(ab.Ability){row.table,row.row}
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
