package abilities

import "core:math"
import "core:mem"
import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// What abilities_step reads of the rest of the world and asks of it.
@(params)
Ability_World :: struct {
    time:core.Time,
    seats:core.Read(inp.Seat),
    drivables:core.Read(inp.Drivable),
    characters:core.Read(phys.Character),
    worlds:core.Read(core.World_Transform),
    remotes:core.Read(core.Remote),
    paces:core.Read(core.Own_Pace), // the windows on the Own clock count the user's own time
    clock:core.Clock,
    physics:core.Ref(phys.Physics_State),
    moves:^phys.Locomotion_Requests,
    actions:^anim.Action_Requests,
    animations:^anim.Animation_Requests,
    problems:^core.Problems,
}

// The entities a hitbox at pose touches, written into results.
Hitbox_Overlap :: #type proc(w:^Ability_World,hitbox:Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int

// Every tick: applies the effects asked in the tick before, runs the timers, cooldowns and
// regeneration, takes the inputs of each user into its buffer, advances the running ability
// along its timeline and starts the best valid candidate. Only the end that decides a user
// (core.owned) starts, ends or hits with its abilities; a replica derives its statuses and the
// events of its windows from what the network gives it.
@(step="fixed")
abilities_step :: proc(users:^core.Table(Ability_User),abilities:core.Records(Ability),kits:core.Records(Ability_Kit),requests:^Ability_Requests,events:^Ability_Events,w:Ability_World) {
    w:=w
    abilities_tick(users,abilities,kits,requests,events,&w,physics_overlap)
}

physics_overlap :: proc(w:^Ability_World,hitbox:Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int {
    center:=pose.position+mm.quat_rotate(pose.rotation,hitbox.center)
    count:int
    switch hitbox.shape {
    case .None:
    case .Box: count,_=phys.overlap_box(w.physics,center,hitbox.size,pose.rotation,results)
    case .Sphere: count,_=phys.overlap_sphere(w.physics,center,hitbox.size.x,results)
    case .Capsule: count,_=phys.overlap_capsule(w.physics,center,hitbox.size.x,hitbox.size.y,pose.rotation,results)
    }
    return count
}

@(private)
Tick :: struct {
    users:^core.Table(Ability_User),
    abilities:core.Records(Ability),
    kits:core.Records(Ability_Kit),
    requests:^Ability_Requests,
    events:^Ability_Events,
    w:^Ability_World,
    overlap:Hitbox_Overlap,
    tick:u64,
    dt:f32,
    text:[512]u8,
}

abilities_tick :: proc(users:^core.Table(Ability_User),abilities:core.Records(Ability),kits:core.Records(Ability_Kit),requests:^Ability_Requests,events:^Ability_Events,w:^Ability_World,overlap:Hitbox_Overlap) {
    if events!=nil {core.queue_clear(&events.queue)}
    if users==nil || w==nil || !(w.time.dt>0) || !finite(w.time.dt) {return}
    t:=Tick{users=users,abilities=abilities,kits=kits,requests=requests,events=events,w=w,overlap=overlap,tick=w.time.tick,dt=w.time.dt}
    if requests!=nil {
        for r in requests.queue.items {request_apply(&t,r)}
        core.queue_clear(&requests.queue)
    }
    for row in 0..<core.count(users) {
        e:=core.entity_at(users,row)
        u:=users.values[row]
        if core.owned(w.remotes,e) {user_tick(&t,e,&u)} else {replica_tick(&t,e,&u)}
        if mem.compare_ptrs(&u,&users.values[row],size_of(Ability_User))!=0 {core.edit_at(users,row)^=u}
    }
}

@(private)
request_apply :: proc(t:^Tick,r:Ability_Request) {
    if r.entity==core.NONE || !core.owned(t.w.remotes,r.entity) {return}
    switch r.kind {
    case .Use:
        // As if its input fired: it waits as its sheet says.
        if u:=core.edit(t.users,r.entity);u!=nil {
            a:=ability_sheet(t.abilities,r.ability)
            buffer_add(u,r.ability,t.tick,a!=nil && a.input.wait==.Running)
        }
    case .Cancel:
        u:=core.edit(t.users,r.entity)
        if u==nil || u.ability=={} {return}
        ability_end(t,r.entity,u,ability_sheet(t.abilities,u.ability),time_of(t,u),.Canceled,nil)
    case .Effect:
        effect_apply(t,r.entity,r.source,r.effect)
    case .Kit:
        if u:=core.edit(t.users,r.entity);u!=nil {u.kit,u.buffer=r.kit,{}}
    }
}

@(private)
effect_apply :: proc(t:^Tick,target,source:core.Entity,effect:Ability_Effect) {
    if text:=effect_check(effect,t.text[:]);text!="" {
        core.report(t.w.problems,target,"abilities.effect","an effect asked for it %s",text)
        return
    }
    u:=core.edit(t.users,target)
    if u!=nil && u.statuses&effect.blocked_by!=0 {return}
    amount:=effect.amount
    if effect.scale_by!=ATTRIBUTE_NONE && amount!=0 {
        from,found:=core.get(t.users,source)
        scale,has:=ability_value(from,effect.scale_by)
        if !found || !has {core.report(t.w.problems,target,"abilities.effect","an effect scaled by an attribute its source does not have hit it: give the source that attribute, or clear scale_by")}
        amount*=scale
    }
    if u!=nil {
        if effect.remove!=0 {
            for &timer in u.timers {
                if timer.until!=0 && timer.tags&effect.remove!=0 {timer_end(t,target,&timer)}
            }
        }
        if effect.period==0 && effect.attribute!=ATTRIBUTE_NONE && amount!=0 {
            for &entry in u.attributes {
                if entry.attribute==effect.attribute {base_add(t,target,&entry,amount)}
            }
        }
        lasting:=effect.statuses!=0 || effect.modify.attribute!=ATTRIBUTE_NONE || effect.period>0 || effect.cue!=CUE_NONE || effect.tags!=0
        if effect.seconds>0 && lasting {
            timer:=Ability_Timer{tags=effect.tags,statuses=effect.statuses,modify=effect.modify,cue=effect.cue,stacks=1,start=t.tick,until=t.tick+max(ticks_of(effect.seconds,t.dt),1)}
            if effect.period>0 {timer.attribute,timer.amount,timer.period=effect.attribute,amount,u32(max(ticks_of(effect.period,t.dt),1))}
            slot:=-1
            if effect.tags!=0 {
                for other,i in u.timers {
                    if other.until!=0 && other.tags==effect.tags {slot=i;break}
                }
            }
            if slot>=0 {
                old:=&u.timers[slot]
                timer.stacks=min(old.stacks+1,max(effect.max_stacks,1))
                timer.start=old.start
                old^=timer
            } else {
                slot=0
                for other,i in u.timers {
                    if other.until==0 {slot=i;break}
                    if other.until<u.timers[slot].until {slot=i}
                }
                if u.timers[slot].until!=0 {timer_end(t,target,&u.timers[slot])}
                u.timers[slot]=timer
                event_push(t,{kind=.Effect_Begin,entity=target,window=-1,cue=timer.cue,attribute=timer.attribute})
            }
        }
        if effect.use!={} {buffer_add(u,effect.use,t.tick,false)}
    }
    if effect.knockback!={} && core.has(t.w.characters,target) {
        velocity:=effect.knockback
        if pose,found:=core.get(t.w.worlds,source);found && source!=core.NONE {velocity=mm.quat_rotate(pose.rotation,velocity)}
        phys.add_move(t.w.moves,target,{velocity=velocity,ticks=u32(max(ticks_of(effect.knockback_seconds,t.dt),1)),mix=.Override,id=KNOCKBACK_ID})
    }
}

@(private)
timer_end :: proc(t:^Tick,e:core.Entity,timer:^Ability_Timer) {
    event_push(t,{kind=.Effect_End,entity=e,window=-1,cue=timer.cue,attribute=timer.attribute})
    timer^={}
}

@(private)
base_add :: proc(t:^Tick,e:core.Entity,entry:^Ability_Attribute_Entry,amount:f32) {
    before:=entry.base
    entry.base=clamp_base(entry^,entry.base+amount)
    if before>0 && entry.base<=0 {event_push(t,{kind=.Depleted,entity=e,window=-1,attribute=entry.attribute})}
}

@(private)
clamp_base :: #force_inline proc "contextless" (entry:Ability_Attribute_Entry,value:f32) -> f32 {
    v:=max(value,0)
    return min(v,entry.max) if entry.max>0 else v
}

@(private)
buffer_add :: proc "contextless" (u:^Ability_User,ability:core.Record(Ability),tick:u64,running:bool) {
    if ability=={} {return}
    slot:=-1
    for b,i in u.buffer {
        if b.ability==ability {slot=i;break}
    }
    if slot<0 {
        slot=0
        for b,i in u.buffer {
            if b.ability=={} {slot=i;break}
            if b.tick<u.buffer[slot].tick {slot=i}
        }
    }
    u.buffer[slot]={ability=ability,tick=tick,run=u.start,running=running && u.ability!={}}
}

@(private)
ticks_of :: #force_inline proc "contextless" (seconds,dt:f32) -> u64 {
    if !(seconds>0) || !(dt>0) {return 0}
    return u64(math.round(f64(seconds)/f64(dt)))
}

// The ticks of a window from the start of its ability, on its clock: open while from<=time<to.
@(private)
window_ticks :: #force_inline proc "contextless" (w:Ability_Window,dt:f32) -> (from,to:i64) {
    from=i64(ticks_of(w.from,dt))
    to=max(i64(ticks_of(w.to,dt)),from+1)
    return
}

// Whether a window is open at a place of its ability's timeline, on the clock it counts.
ability_window_open :: #force_inline proc "contextless" (w:Ability_Window,dt:f32,at:Ability_Time) -> bool {
    if w.to==0 {return false}
    from,to:=window_ticks(w,dt)
    if w.clock==.Own {return at.own>=f32(from) && at.own<f32(to)}
    return at.local>=from && at.local<to
}

// Where the running ability of u is at this tick.
@(private)
time_of :: #force_inline proc "contextless" (t:^Tick,u:^Ability_User) -> Ability_Time {
    return {local=i64(t.tick-u.start) if t.tick>=u.start else 0,own=u.own}
}

// The ticks of its own time e lives in one tick of the world.
@(private)
pace_tick :: #force_inline proc "contextless" (t:^Tick,e:core.Entity) -> f32 {
    return core.pace_of(t.w.clock,t.w.paces,e)
}

ability_ticks :: #force_inline proc "contextless" (a:^Ability,dt:f32) -> i64 {return max(i64(ticks_of(a.duration,dt)),1)}

@(private)
user_tick :: proc(t:^Tick,e:core.Entity,u:^Ability_User) {
    if text:=attributes_check(u,t.text[:]);text!="" {
        core.report(t.w.problems,e,"abilities.attributes","%s",text)
        return
    }
    kit:=kit_sheet(t.kits,u.kit)
    if kit==nil && u.kit!={} {core.record_missing(t.kits.set,u.kit.table,u.kit.row,"Ability_Kit",t.w.problems,e)}
    if kit!=nil {
        if text:=kit_check(kit,t.text[:]);text!="" {
            core.report(t.w.problems,e,"abilities.kit","its kit %s %s",core.record_name(t.kits,u.kit),text)
            kit=nil
        }
    }
    for &timer in u.timers {
        if timer.until==0 {continue}
        if timer.period>0 && t.tick>timer.start && t.tick<=timer.until && (t.tick-timer.start)%u64(timer.period)==0 {
            for &entry in u.attributes {
                if entry.attribute==timer.attribute {base_add(t,e,&entry,timer.amount*f32(max(timer.stacks,1)))}
            }
        }
        if timer.until<=t.tick {timer_end(t,e,&timer)}
    }
    for &c in u.cooldowns {if c.until!=0 && c.until<=t.tick {c={}}}
    // An entry leaves after the kit's buffer or, when it waits for the run it came in, once that
    // run is over too.
    buffer:=ticks_of(kit.buffer,t.dt) if kit!=nil else 0
    for &b in u.buffer {
        if b.ability=={} || b.tick+buffer>=t.tick {continue}
        if b.running && u.ability!={} && u.start==b.run {continue}
        b={}
    }
    for &entry in u.attributes {
        if entry.attribute!=ATTRIBUTE_NONE && entry.regen!=0 {base_add(t,e,&entry,entry.regen*t.dt)}
    }
    // The running ability advances to this tick, on the clock of the world and on its own.
    next:core.Record(Ability)
    handoff:Ability_Statuses // of the windows open on the last tick of the ability that completed: its next starts in them
    at:Ability_Time
    active:=sheet_valid(t,e,u.ability)
    if u.ability!={} && active==nil {ability_end(t,e,u,nil,{},.Canceled,nil)}
    if active!=nil {
        before:=time_advance(t,e,u)
        at=time_of(t,u)
        windows_advance(t,e,u,active,before,at)
        if at.local>=ability_ticks(active,t.dt) {
            next=active.next
            for &w in active.windows {
                if ability_window_open(w,t.dt,before) {handoff|=w.statuses}
            }
            ability_end(t,e,u,active,at,.Completed,nil)
            active=nil
        } else if active.hold && active.input.on!=.None && !input_down(t,e,active.input) {
            ability_end(t,e,u,active,at,.Completed,nil)
            active=nil
        }
    }
    if kit!=nil {
        for ref in kit.abilities {
            a:=ability_sheet(t.abilities,ref)
            if a!=nil && a.input.on>max(Ability_Trigger) {a=sheet_valid(t,e,ref)}
            if a==nil || !input_fired(t,e,a.input) {continue}
            // Over a running ability, the input counts only from after seconds into it.
            if active!=nil && at.local<i64(ticks_of(a.input.after,t.dt)) {continue}
            buffer_add(u,ref,t.tick,a.input.wait==.Running)
        }
    }
    derive(t,u,active,at)
    // The best valid candidate starts.
    best:=-1
    best_ref:=next
    best_sheet:=sheet_valid(t,e,next) if next!={} else nil
    if best_sheet!=nil {
        // The next of a completed ability is its last branch: it starts in the statuses the
        // ability had then (a dash that requires the charging status of its charge).
        from:=u^
        from.statuses|=handoff
        if !can_start(t,e,&from,kit,active,at,best_sheet,next) {best_sheet=nil}
    }
    for b,i in u.buffer {
        if b.ability=={} {continue}
        a:=sheet_valid(t,e,b.ability)
        if a==nil {u.buffer[i]={};continue}
        if !can_start(t,e,u,kit,active,at,a,b.ability) {continue}
        if best_sheet==nil || a.priority>best_sheet.priority || a.priority==best_sheet.priority && best>=0 && b.tick<u.buffer[best].tick {
            best,best_ref,best_sheet=i,b.ability,a
        }
    }
    if best_sheet!=nil {
        if active!=nil {ability_end(t,e,u,active,at,.Interrupted,best_sheet)}
        ability_start(t,e,u,best_ref,best_sheet)
        active,at=best_sheet,{}
        windows_advance(t,e,u,active,TIME_BEFORE_START,at)
    }
    if active!=nil {hitboxes(t,e,u,active,at)}
    derive(t,u,active,at)
}

// A replica follows the ability its owner runs: its statuses and the events of its windows.
@(private)
replica_tick :: proc(t:^Tick,e:core.Entity,u:^Ability_User) {
    active:=ability_sheet(t.abilities,u.ability)
    at:Ability_Time
    if active!=nil {
        before:=time_advance(t,e,u)
        at=time_of(t,u)
        if at.local<ability_ticks(active,t.dt) {
            for &w,i in active.windows {
                was,is:=ability_window_open(w,t.dt,before),ability_window_open(w,t.dt,at)
                if is && !was {event_push(t,{kind=.Window_Begin,entity=e,ability=u.ability,window=i8(i),cue=w.cue})}
                if was && !is {event_push(t,{kind=.Window_End,entity=e,ability=u.ability,window=i8(i),cue=w.cue})}
            }
        } else {active=nil}
    }
    derive(t,u,active,at)
}

// The sheet of a reference when it is there and valid; a missing or invalid one is a problem.
@(private)
sheet_valid :: proc(t:^Tick,e:core.Entity,ref:core.Record(Ability)) -> ^Ability {
    if ref=={} {return nil}
    a:=ability_sheet(t.abilities,ref)
    if a==nil {
        core.record_missing(t.abilities.set,ref.table,ref.row,"Ability",t.w.problems,e)
        return nil
    }
    if text:=ability_check(a,t.text[:]);text!="" {
        core.report(t.w.problems,e,"abilities.invalid","the ability %s does not run: %s",core.record_name(t.abilities,ref),text)
        return nil
    }
    return a
}

@(private)
input_state :: proc(t:^Tick,e:core.Entity,input:Ability_Input) -> inp.Action_State {
    return inp.body_action({t.w.seats,t.w.drivables},e,input.action)
}

@(private)
input_down :: proc(t:^Tick,e:core.Entity,input:Ability_Input) -> bool {
    return input.on!=.None && input_state(t,e,input).down
}

@(private)
input_fired :: proc(t:^Tick,e:core.Entity,input:Ability_Input) -> bool {
    if input.on==.None {return false}
    s:=input_state(t,e,input)
    hold:=u32(ticks_of(input.hold,t.dt))
    switch input.on {
    case .None: return false
    case .Pressed: return s.pressed
    case .Released: return s.released && s.released_held>=hold
    case .Held: return hold==0?s.pressed:s.down && s.held_ticks==hold
    case .Down: return s.down
    }
    return false
}

// Why a candidate cannot start now; .None when it can.
Ability_Block :: enum u8 {
    None,
    Status_Missing, // it requires a status the user is not in
    Status_Blocked, // the user is in a status that blocks it
    Mode,           // the user's Character is not in one of its modes
    Condition,      // an attribute is out of a condition
    Cost,           // an attribute has less than a cost
    Cooldown,
    No_Cancel,      // the running ability has no open window that accepts its tags
}

@(private)
can_start :: proc(t:^Tick,e:core.Entity,u:^Ability_User,kit:^Ability_Kit,active:^Ability,at:Ability_Time,a:^Ability,ref:core.Record(Ability)) -> bool {
    return start_block(t.w,t.tick,t.dt,e,u,kit,active,at,a,ref)==.None
}

// Why ability a cannot start for user u at tick, with active running at at.
start_block :: proc(w:^Ability_World,tick:u64,dt:f32,e:core.Entity,u:^Ability_User,kit:^Ability_Kit,active:^Ability,at:Ability_Time,a:^Ability,ref:core.Record(Ability)) -> Ability_Block {
    if u.statuses&a.requires!=a.requires {return .Status_Missing}
    if u.statuses&a.blocked_by!=0 {return .Status_Blocked}
    if a.modes!=0 {
        if w.characters.table==nil {return .Mode}
        c,found:=core.get(w.characters,e)
        if !found || u32(c.mode)>=32 || a.modes&Ability_Modes(u32(1)<<u32(c.mode))==0 {return .Mode}
    }
    for c in a.conditions {
        if c.attribute==ATTRIBUTE_NONE {continue}
        value,found:=ability_value(u^,c.attribute)
        if !found || value<c.at_least || c.at_most>0 && value>c.at_most {return .Condition}
    }
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        value,found:=ability_value(u^,c.attribute)
        if !found || value<c.amount {return .Cost}
    }
    for c in u.cooldowns {
        if c.ability==ref && c.until>tick {return .Cooldown}
    }
    if active!=nil {
        accepted:=kit.interrupts if kit!=nil else 0
        for &w in active.windows {
            if ability_window_open(w,dt,at) {accepted|=w.cancel_into}
        }
        if accepted&a.tags==0 {return .No_Cancel}
    }
    return .None
}

@(private)
ability_start :: proc(t:^Tick,e:core.Entity,u:^Ability_User,ref:core.Record(Ability),a:^Ability) {
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        for &entry in u.attributes {
            if entry.attribute==c.attribute {base_add(t,e,&entry,-c.amount)}
        }
    }
    if a.cooldown>0 {
        slot:=0
        for c,i in u.cooldowns {
            if c.ability==ref || c.until==0 {slot=i;break}
            if c.until<u.cooldowns[slot].until {slot=i}
        }
        u.cooldowns[slot]={ref,t.tick+max(ticks_of(a.cooldown,t.dt),1)}
    }
    for &b in u.buffer {if b.ability==ref {b={}}}
    u.ability,u.start,u.own,u.hits,u.hit_count=ref,t.tick,0,{},0
    event_push(t,{kind=.Started,entity=e,ability=ref,window=-1})
    if name:=ability_name_text(&a.action);name!="" {
        anim.action_fire(t.w.actions,e,name)
    } else if name:=ability_name_text(&a.clip);name!="" {
        mode:u16
        if c,found:=core.get(t.w.characters,e);found {mode=u16(c.mode)}
        anim.match_play(t.w.animations,e,name,mode)
    }
}

// Ends the running ability at at: its open windows close, their moves stop and its animation
// stops unless next plays the same action, or a clip of its own. An action next does not fire again
// is cancelled even when next fires another: on another layer nothing would replace it, and a
// looping section would play on, and on the same layer the one next fires takes the layer.
@(private)
ability_end :: proc(t:^Tick,e:core.Entity,u:^Ability_User,a:^Ability,at:Ability_Time,kind:Ability_Event_Kind,next:^Ability) {
    ref:=u.ability
    if a!=nil {
        for &w,i in a.windows {
            if !ability_window_open(w,t.dt,at) {continue}
            event_push(t,{kind=.Window_End,entity=e,ability=ref,window=i8(i),cue=w.cue})
            if w.move.velocity!={} {phys.remove_moves(t.w.moves,e,MOVE_ID+u32(i))}
        }
        if kind!=.Completed || a.hold {
            if name:=ability_name_text(&a.action);name!="" && (next==nil || ability_name_text(&next.action)!=name) {anim.action_cancel(t.w.actions,e,name)}
            if ability_name_text(&a.clip)!="" && (next==nil || ability_name_text(&next.clip)=="") {anim.match_stop(t.w.animations,e)}
        }
    }
    u.ability,u.start,u.own,u.hits,u.hit_count={},0,0,{},0
    event_push(t,{kind=kind,entity=e,ability=ref,window=-1})
}

// Where an ability is on the tick before its start: no window is open there.
@(private)
TIME_BEFORE_START :: Ability_Time{local=-1,own=-1}

// Moves the running ability of u to this tick: its own time grows by the pace of e. Returns where
// it was on the tick before.
@(private)
time_advance :: proc "contextless" (t:^Tick,e:core.Entity,u:^Ability_User) -> (before:Ability_Time) {
    before=time_of(t,u)
    if before.local<=0 {return TIME_BEFORE_START}
    before.local-=1
    u.own+=pace_tick(t,e)
    return
}

// The windows that open or close at at, against before (the tick before).
@(private)
windows_advance :: proc(t:^Tick,e:core.Entity,u:^Ability_User,a:^Ability,before,at:Ability_Time) {
    for &w,i in a.windows {
        was,is:=ability_window_open(w,t.dt,before),ability_window_open(w,t.dt,at)
        if is && !was {
            event_push(t,{kind=.Window_Begin,entity=e,ability=u.ability,window=i8(i),cue=w.cue})
            if w.move.velocity!={} {
                velocity:=w.move.velocity
                if pose,found:=core.get(t.w.worlds,e);found {velocity=mm.quat_rotate(pose.rotation,velocity)}
                from,to:=window_ticks(w,t.dt)
                ticks:=u32(to-from)
                // On the Own clock it lasts until the window closes, which removes it.
                if w.clock==.Own {ticks=u32(math.ceil(f32(to-from)/max(pace_tick(t,e),1.0/64)))}
                phys.add_move(t.w.moves,e,{velocity=velocity,ticks=ticks,mix=w.move.mix,id=MOVE_ID+u32(i)})
            }
        }
        if was && !is {
            event_push(t,{kind=.Window_End,entity=e,ability=u.ability,window=i8(i),cue=w.cue})
            if w.clock==.Own && w.move.velocity!={} {phys.remove_moves(t.w.moves,e,MOVE_ID+u32(i))}
        }
    }
}

// Each open hitbox touches each entity once: a Hit and the effect of the window, on the tick after.
@(private)
hitboxes :: proc(t:^Tick,e:core.Entity,u:^Ability_User,a:^Ability,at:Ability_Time) {
    pose,found:=core.get(t.w.worlds,e)
    if !found {pose.rotation=1}
    for &w,i in a.windows {
        if w.hitbox.shape==.None || !ability_window_open(w,t.dt,at) || t.overlap==nil {continue}
        results:[HITBOX_RESULTS]core.Entity
        count:=clamp(t.overlap(t.w,w.hitbox,pose.transform,results[:]),0,HITBOX_RESULTS)
        each: for target in results[:count] {
            if target==e || target==core.NONE {continue}
            for h in u.hits[:u.hit_count] {
                if h.target==target && int(h.window)==i {continue each}
            }
            if int(u.hit_count)>=USER_HITS {
                core.report(t.w.problems,e,"abilities.hits","the ability %s touched more than %d entities: smaller hitboxes, or fewer windows with hitboxes",core.record_name(t.abilities,u.ability),USER_HITS)
                return
            }
            u.hits[u.hit_count]={target,u8(i)}
            u.hit_count+=1
            event_push(t,{kind=.Hit,entity=e,ability=u.ability,window=i8(i),cue=w.cue,target=target})
            if w.hitbox.effect!={} {
                ability_effect(t.requests,target,w.hitbox.effect,e)
            }
        }
    }
}

// The statuses and current values of a user: those of its timers and of the windows open at at.
@(private)
derive :: proc(t:^Tick,u:^Ability_User,active:^Ability,at:Ability_Time) {
    statuses:Ability_Statuses
    add,more:[ATTRIBUTE_ENTRIES]f32
    modify :: proc(u:^Ability_User,m:Ability_Modifier,add,more:^[ATTRIBUTE_ENTRIES]f32) {
        if m.attribute==ATTRIBUTE_NONE {return}
        for entry,i in u.attributes {
            if entry.attribute==m.attribute {add[i]+=m.add;more[i]+=m.more}
        }
    }
    for timer in u.timers {
        if timer.until==0 {continue}
        statuses|=timer.statuses
        m:=timer.modify
        stacks:=f32(max(timer.stacks,1))
        m.add*=stacks;m.more*=stacks
        modify(u,m,&add,&more)
    }
    if active!=nil {
        for &w in active.windows {
            if !ability_window_open(w,t.dt,at) {continue}
            statuses|=w.statuses
            modify(u,w.modify,&add,&more)
        }
    }
    u.statuses=statuses
    for entry,i in u.attributes {
        u.values[i]=0 if entry.attribute==ATTRIBUTE_NONE else max((entry.base+add[i])*max(1+more[i],0),0)
    }
}

@(private)
event_push :: proc(t:^Tick,event:Ability_Event) {
    if t.events==nil {return}
    if cap(t.events.queue.items)==0 {
        if reserve(&t.events.queue.items,EVENT_CAPACITY)!=nil {return}
    }
    if len(t.events.queue.items)>=EVENT_CAPACITY {
        core.report(t.w.problems,core.NONE,"abilities.events","more than %d ability events in one tick: the rest were dropped",EVENT_CAPACITY)
        return
    }
    core.push(&t.events.queue,event)
}
