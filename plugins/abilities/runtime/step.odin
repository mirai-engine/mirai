package abilities

import "core:math"
import "mirai:host"
import "mirai:std/base"
import audio "mirai:engine/audio"
import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// What abilities_step reads of the rest of the world and asks of it.
@(params)
Ability_World :: struct {
    time:core.Time,
    seats:^core.Table(inp.Seat,.Read),
    characters:^core.Table(phys.Character,.Read),
    locomotions:^core.Table(locomotion.Locomotion_State,.Read), // the modes the characters are in
    worlds:^core.Table(core.World_Transform,.Read),
    remotes:^core.Table(core.Remote,.Read),
    paces:^core.Table(core.Own_Pace,.Read), // the windows on the Own clock count the user's own time
    clock:core.Clock,
    physics:core.Ref(phys.Physics_State),
    moves:^locomotion.Locomotion_Requests,
    animations:^anim.Animation_Requests,
    problems:^core.Problems,
    sounds:^audio.Sound_Requests,
    births:^core.Births,
}

// The entities a hitbox at pose touches, written into results.
Hitbox_Overlap :: #type proc(w:^Ability_World,hitbox:^Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int

@(params)
Ability_Tables :: struct {
    users:^core.Table(Ability_User),
    states:^core.Table(Ability_State),
    tracking:^core.Table(Ability_Tracking),
}

@(step="fixed",stage="begin",loops="game")
abilities_prepare :: proc(
    tables:Ability_Tables,checks:^Ability_Attributes,events:^Ability_Events,
    sounds:^audio.Sound_Requests,births:^core.Births,problems:^core.Problems,app:^host.App,
) {
    ability_rows(tables,checks,problems)
    if core.count(tables.users)==0 {return}
    // The log holds the preceding frame and every tick of this one until the next age.
    ability_room(events,sounds,births,2*max(app.max_ticks,1)*EVENT_CAPACITY,problems)
}

@(step="fixed")
abilities_step :: proc(tables:Ability_Tables,data:Ability_Data,sheets:^Ability_Sheets,checks:^Ability_Attributes,requests:^Ability_Requests,events:^Ability_Events,w:Ability_World) {
    w:=w
    abilities_tick(tables,data,sheets,checks,requests,events,&w,physics_overlap)
}

@(private)
ability_room :: proc(events:^Ability_Events,sounds:^audio.Sound_Requests,births:^core.Births,room:int,problems:^core.Problems) {
    if events!=nil && cap(events.queue.items)<room && reserve(&events.queue.items,room)!=nil {
        core.report(problems,core.NONE,"abilities.events","out of memory for ability events")
    }
    if sounds!=nil && cap(sounds.queue.items)<EVENT_CAPACITY && reserve(&sounds.queue.items,EVENT_CAPACITY)!=nil ||
       births!=nil && cap(births.queue.items)<EVENT_CAPACITY && reserve(&births.queue.items,EVENT_CAPACITY)!=nil {
        core.report(problems,core.NONE,"abilities.feedback","out of memory for ability feedback")
    }
}

@(private)
ability_rows :: proc(tables:Ability_Tables,checks:^Ability_Attributes,problems:^core.Problems) {
    if !core.reshaped(tables.users,&checks.shape) {return}
    changes:=core.changes(tables.users,&checks.seen)
    core.entity_map_prune(&checks.entries,tables.users,changes)
    for row in 0..<core.count(tables.users) {
        e:=core.entity_at(tables.users,row)
        if !core.has(tables.states,e) && !core.add(tables.states,e,Ability_State{}) ||
           !core.has(tables.tracking,e) && !core.add(tables.tracking,e,Ability_Tracking{}) {
            checks.shape={}
            core.report(problems,e,"abilities.state","out of memory for ability state")
        }
    }
    prune_rows(tables.states,tables.users)
    prune_rows(tables.tracking,tables.users)
    room:=cap(tables.users.values)
    if !edit_room(tables.users,room) || !edit_room(tables.states,room) || !edit_room(tables.tracking,room) {
        checks.shape={}
        core.report(problems,core.NONE,"abilities.state","out of memory for ability state edits")
    }
}

@(private)
prune_rows :: proc(rows:^core.Table($T),users:^core.Table(Ability_User)) {
    for e in rows.entities {
        if core.raw_find(core.raw(users),type_info_of(Ability_User),e)==nil {core.remove(rows,e)}
    }
}

@(private)
edit_room :: proc(rows:^core.Table($T),room:int) -> bool {
    return (cap(rows.edits)>=room || reserve(&rows.edits,room)==nil) &&
           (cap(rows.edited)>=room || reserve(&rows.edited,room)==nil)
}

physics_overlap :: proc(w:^Ability_World,hitbox:^Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int {
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
    using tables:Ability_Tables,
    using data:Ability_Data,
    sheets:^Ability_Sheets,
    checks:^Ability_Attributes,
    requests:^Ability_Requests,
    events:^Ability_Events,
    event_count:int,
    w:^Ability_World,
    overlap:Hitbox_Overlap,
    tick:u64,
    dt:f32,
    text:[512]u8,
}

@(private)
Actor :: struct {
    user:^Ability_User,
    state:^Ability_State,
    track:^Ability_Tracking,
    setup_check:^Attribute_Check,
    user_row,state_row,track_row:int,
}

@(private)
actor_at :: proc(t:^Tick,e:core.Entity,row:int) -> (u:Actor,ok:bool) {
    sr,tr:=core.row_of(t.states,e),core.row_of(t.tracking,e)
    if row<0 || sr<0 || tr<0 {return}
    u={user=&t.users.values[row],state=&t.states.values[sr],track=&t.tracking.values[tr],
       user_row=row,state_row=sr,track_row=tr}
    stamp:=core.stamp(t.users,row)
    cached:=core.entity_map_get(&t.checks.entries,e)
    if cached==nil {
        cached,ok=core.entity_map_put(&t.checks.entries,e,Attribute_Check{})
        if !ok {
            core.report(t.w.problems,e,"abilities.attributes","out of memory for attribute validation")
            return u,false
        }
        cached.stamp=~stamp
        cached.write=~stamp
    }
    if cached.stamp!=stamp && cached.write!=stamp {
        cached.problem,cached.index=attributes_check(u.user)
        cached.stamp,cached.write=stamp,stamp
    }
    u.setup_check=cached
    attribute_report(t.w.problems,e,cached.problem,cached.index)
    return u,cached.problem==.None
}

@(private)
user_edit :: proc(t:^Tick,u:^Actor) -> ^Ability_User {
    stamp:=core.stamp(t.users,u.user_row)
    if len(t.users.edits)==0 || stamp<=t.users.edit_from {u.setup_check.stamp=stamp}
    value:=core.edit_at(t.users,u.user_row)
    u.setup_check.write=core.stamp(t.users,u.user_row)
    return value
}

abilities_tick :: proc(tables:Ability_Tables,data:Ability_Data,sheets:^Ability_Sheets,checks:^Ability_Attributes,requests:^Ability_Requests,events:^Ability_Events,w:^Ability_World,overlap:Hitbox_Overlap) {
    if tables.users==nil || w==nil || !(w.time.dt>0) || !finite(w.time.dt) {return}
    if !sheets_refresh(sheets,data) {
        core.report(w.problems,core.NONE,"abilities.sheets","out of memory for ability sheet validation")
        return
    }
    t:=Tick{tables=tables,data=data,sheets=sheets,checks=checks,requests=requests,events=events,w=w,overlap=overlap,tick=w.time.tick,dt=w.time.dt}
    if requests!=nil {
        for r in core.take(&requests.queue) {request_apply(&t,r)}
    }
    for row in 0..<core.count(t.users) {
        e:=core.entity_at(t.users,row)
        u,ok:=actor_at(&t,e,row)
        if !ok {continue}
        if core.owned(w.remotes,e) {user_tick(&t,e,&u)} else {replica_tick(&t,e,&u)}
    }
}

@(private)
request_apply :: proc(t:^Tick,r:Ability_Request) {
    if r.entity==core.NONE || !core.owned(t.w.remotes,r.entity) {return}
    if r.kind==.Effect {effect_apply(t,r.entity,r.source,r.effect);return}
    u,ok:=actor_at(t,r.entity,core.row_of(t.users,r.entity))
    if !ok {return}
    switch r.kind {
    case .Use:
        if a:=sheet_valid(t,r.entity,r.ability);a!=nil {
            buffer_add(t,&u,r.ability,a.input.wait==.Running)
        }
    case .Cancel:
        if u.state.ability!={} {
            ability_end(t,r.entity,&u,record_sheet(t.abilities,u.state.ability),time_of(t,u.state),.Canceled,nil)
        }
    case .Kit:
        if u.user.kit!=r.kit {user_edit(t,&u).kit=r.kit}
        core.edit_at(t.tracking,u.track_row).buffer={}
    case .Effect:
    }
}

@(private)
effect_apply :: proc(t:^Tick,target,source:core.Entity,effect:Ability_Effect) {
    if text:=effect_check(effect,t.text[:]);text!="" {
        core.report(t.w.problems,target,"abilities.effect","an effect asked for it %s",text)
        return
    }
    row:=core.row_of(t.users,target)
    u,valid:=actor_at(t,target,row)
    if row>=0 && !valid {return}
    if valid && u.state.statuses&effect.blocked_by!=0 {return}
    amount:=effect.amount
    if effect.scale_by!=ATTRIBUTE_NONE && amount!=0 {
        from,sr:=core.row_of(t.users,source),core.row_of(t.states,source)
        scale:f32
        has:bool
        if from>=0 && sr>=0 {scale,has=ability_value(&t.users.values[from],&t.states.values[sr],effect.scale_by)}
        if !has {core.report(t.w.problems,target,"abilities.effect","an effect scaled by an attribute its source does not have hit it: give the source that attribute, or clear scale_by")}
        amount*=scale
    }
    if valid {
        if effect.remove!=0 {
            for &timer,i in u.track.timers {
                if timer.until!=0 && timer.tags&effect.remove!=0 {
                    timer_end(t,target,&core.edit_at(t.tracking,u.track_row).timers[i])
                }
            }
        }
        if effect.period==0 && effect.attribute!=ATTRIBUTE_NONE && amount!=0 {
            for entry,i in u.user.attributes {
                if entry.attribute==effect.attribute {base_add(t,target,&u,i,amount)}
            }
        }
        lasting:=effect.statuses!=0 || effect.modify.attribute!=ATTRIBUTE_NONE || effect.period>0 || effect.cue!=CUE_NONE || effect.tags!=0
        if effect.seconds>0 && lasting {
            timer:=Ability_Timer{tags=effect.tags,statuses=effect.statuses,modify=effect.modify,cue=effect.cue,stacks=1,start=t.tick,until=core.deadline(t.w.time,effect.seconds)}
            if effect.period>0 {timer.attribute,timer.amount,timer.period=effect.attribute,amount,u32(max(ticks_of(effect.period,t.dt),1))}
            slot:=-1
            if effect.tags!=0 {
                for &other,i in u.track.timers {
                    if other.until!=0 && other.tags==effect.tags {slot=i;break}
                }
            }
            timers:=&core.edit_at(t.tracking,u.track_row).timers
            if slot>=0 {
                old:=&timers[slot]
                timer.stacks=u8(min(int(old.stacks)+1,max(int(effect.max_stacks),1)))
                timer.start=old.start
                old^=timer
            } else {
                slot=0
                for &other,i in u.track.timers {
                    if other.until==0 {slot=i;break}
                    if other.until<u.track.timers[slot].until {slot=i}
                }
                if timers[slot].until!=0 {timer_end(t,target,&timers[slot])}
                timers[slot]=timer
                event_push(t,{kind=.Effect_Begin,entity=target,window=-1,cue=timer.cue,attribute=timer.attribute})
            }
        }
        if effect.use!={} {buffer_add(t,&u,effect.use,false)}
    }
    if effect.knockback!={} && core.has(t.w.characters,target) {
        velocity:=effect.knockback
        if pose,found:=core.get(t.w.worlds,source);found && source!=core.NONE {velocity=mm.quat_rotate(pose.rotation,velocity)}
        locomotion.add_move(t.w.moves,target,{velocity=velocity,ticks=u32(max(ticks_of(effect.knockback_seconds,t.dt),1)),mix=.Override,id=KNOCKBACK_ID})
    }
}

@(private)
timer_end :: proc(t:^Tick,e:core.Entity,timer:^Ability_Timer) {
    event_push(t,{kind=.Effect_End,entity=e,window=-1,cue=timer.cue,attribute=timer.attribute})
    timer^={}
}

@(private)
base_add :: proc(t:^Tick,e:core.Entity,u:^Actor,index:int,amount:f32) {
    entry:=u.user.attributes[index]
    value:=clamp_base(entry,entry.base+amount)
    if !finite(value) {value=max(f32) if value>0 else 0}
    if value==entry.base {return}
    user_edit(t,u).attributes[index].base=value
    if entry.base>0 && value<=0 {event_push(t,{kind=.Depleted,entity=e,window=-1,attribute=entry.attribute})}
}

@(private)
clamp_base :: #force_inline proc "contextless" (entry:Ability_Attribute_Entry,value:f32) -> f32 {
    v:=max(value,0)
    return min(v,entry.max) if entry.max>0 else v
}

@(private)
buffer_add :: proc(t:^Tick,u:^Actor,ability:core.Record(Ability),running:bool) {
    if ability=={} {return}
    slot:=-1
    for b,i in u.track.buffer {
        if b.ability==ability {slot=i;break}
    }
    if slot<0 {
        slot=0
        for b,i in u.track.buffer {
            if b.ability=={} {slot=i;break}
            if b.tick<u.track.buffer[slot].tick {slot=i}
        }
    }
    core.edit_at(t.tracking,u.track_row).buffer[slot]={ability=ability,tick=t.tick,run=u.state.start,running=running && u.state.ability!={}}
}

@(private)
ticks_of :: #force_inline proc "contextless" (seconds,dt:f32) -> u64 {return core.ticks_of(core.Time{dt=dt},seconds)}

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
time_of :: #force_inline proc "contextless" (t:^Tick,u:^Ability_State) -> Ability_Time {
    return {local=i64(t.tick-u.start) if t.tick>=u.start else 0,own=u.own}
}

// The ticks of its own time e lives in one tick of the world.
@(private)
pace_tick :: #force_inline proc "contextless" (t:^Tick,e:core.Entity) -> f32 {
    return core.pace_of(t.w.clock,t.w.paces,e)
}

ability_ticks :: #force_inline proc "contextless" (a:^Ability,dt:f32) -> i64 {return max(i64(ticks_of(a.duration,dt)),1)}

@(private)
user_tick :: proc(t:^Tick,e:core.Entity,u:^Actor) {
    kit_row:=record_row(t.kits,u.user.kit)
    kit:=record_at(t.kits,kit_row)
    cached:^Kit_Cache
    if kit==nil {
        if u.user.kit!={} {core.record_missing(t.kits.set,u.user.kit.table,u.user.kit.row,"Ability_Kit",t.w.problems,e)}
    } else {
        cached=&t.sheets.kits[kit_row]
        if text:=base.text_get(cached.problem[:]);text!="" {
            core.report(t.w.problems,e,"abilities.kit","its kit %s %s",core.record_name(t.kits,u.user.kit),text)
            kit,cached=nil,nil
        } else if cached.invalid_ability>=0 {
            sheet_report(t,e,cached.invalid_ability)
        }
    }
    for &timer,i in u.track.timers {
        if timer.until==0 {continue}
        if timer.period>0 && t.tick>timer.start && t.tick<=timer.until && (t.tick-timer.start)%u64(timer.period)==0 {
            for entry,j in u.user.attributes {
                if entry.attribute==timer.attribute {base_add(t,e,u,j,timer.amount*f32(max(timer.stacks,1)))}
            }
        }
        if core.due(t.w.time,timer.until) {timer_end(t,e,&core.edit_at(t.tracking,u.track_row).timers[i])}
    }
    for &c,i in u.track.cooldowns {
        if c.until!=0 && core.due(t.w.time,c.until) {core.edit_at(t.tracking,u.track_row).cooldowns[i]={}}
    }
    // An entry leaves after the kit's buffer or, when it waits for the run it came in, once that
    // run is over too.
    buffer:=ticks_of(kit.buffer,t.dt) if kit!=nil else 0
    for &b,i in u.track.buffer {
        if b.ability=={} || t.tick<=b.tick || t.tick-b.tick<=buffer {continue}
        if b.running && u.state.ability!={} && u.state.start==b.run {continue}
        core.edit_at(t.tracking,u.track_row).buffer[i]={}
    }
    for entry,i in u.user.attributes {
        if entry.attribute!=ATTRIBUTE_NONE && entry.regen!=0 {base_add(t,e,u,i,entry.regen*t.dt)}
    }
    // The running ability advances to this tick, on the clock of the world and on its own.
    next:core.Record(Ability)
    handoff:Ability_Statuses // of the windows open on the last tick of the ability that completed: its next starts in them
    at:Ability_Time
    active:=sheet_valid(t,e,u.state.ability)
    if u.state.ability!={} && active==nil {ability_end(t,e,u,nil,{},.Canceled,nil)}
    seat:^inp.Seat
    if t.w.seats!=nil && (cached!=nil && cached.count>0 || active!=nil && active.hold) {
        if row:=core.row_of(t.w.seats,inp.seat_of(t.w.seats,e));row>=0 {
            seat=&t.w.seats.values[row]
        }
    }
    if active!=nil {
        before:=time_advance(t,e,u)
        at=time_of(t,u.state)
        windows_advance(t,e,u,active,before,at)
        if at.local>=ability_ticks(active,t.dt) {
            next=active.next
            for &w in active.windows {
                if ability_window_open(w,t.dt,before) {handoff|=w.statuses}
            }
            ability_end(t,e,u,active,at,.Completed,nil)
            active=nil
        } else if active.hold && active.input.on!=.None && !input_state(seat,active.input.action).down {
            ability_end(t,e,u,active,at,.Completed,nil)
            active=nil
        }
    }
    if cached!=nil && seat!=nil {
        if mask:=kit_inputs(cached,seat);mask!=0 {
            for entry in cached.inputs[:cached.count] {
                if entry.action&mask==0 {continue}
                a:=record_at(t.abilities,entry.row)
                if !input_fired(t.dt,a.input,input_state(seat,a.input.action)) {continue}
                if active!=nil && at.local<i64(ticks_of(a.input.after,t.dt)) {continue}
                row:=&t.abilities.set.rows[entry.row]
                buffer_add(t,u,{row.table,row.row},a.input.wait==.Running)
            }
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
        if start_block(t.w,t.tick,t.dt,e,u.user,u.state,u.track,u.state.statuses|handoff,kit,active,at,best_sheet,next)!=.None {
            best_sheet=nil
        }
    }
    for b,i in u.track.buffer {
        if b.ability=={} {continue}
        a:=sheet_valid(t,e,b.ability)
        if a==nil {core.edit_at(t.tracking,u.track_row).buffer[i]={};continue}
        if !can_start(t,e,u,kit,active,at,a,b.ability) {continue}
        if best_sheet==nil || a.priority>best_sheet.priority || a.priority==best_sheet.priority && best>=0 && b.tick<u.track.buffer[best].tick {
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
    if best_sheet!=nil {derive(t,u,active,at)}
}

// A replica follows the ability its owner runs: its statuses and the events of its windows.
@(private)
replica_tick :: proc(t:^Tick,e:core.Entity,u:^Actor) {
    active:=sheet_valid(t,e,u.state.ability)
    at:Ability_Time
    if active!=nil {
        before:=time_advance(t,e,u)
        at=time_of(t,u.state)
        if at.local<ability_ticks(active,t.dt) {
            windows_advance(t,e,u,active,before,at,replica=true)
        } else {active=nil}
    }
    derive(t,u,active,at)
}

@(private)
sheet_report :: proc(t:^Tick,e:core.Entity,row:int) {
    name:=base.text_get(t.abilities.set.rows[row].name[:])
    text:=base.text_get(t.sheets.abilities[row][:])
    core.report(t.w.problems,e,"abilities.invalid","the ability %s does not run: %s",name,text)
}

@(private)
sheet_valid :: proc(t:^Tick,e:core.Entity,ref:core.Record(Ability)) -> ^Ability {
    if ref=={} {return nil}
    row:=record_row(t.abilities,ref)
    a:=record_at(t.abilities,row)
    if a==nil {
        core.record_missing(t.abilities.set,ref.table,ref.row,"Ability",t.w.problems,e)
        return nil
    }
    if t.sheets.abilities[row][0]!=0 {
        sheet_report(t,e,row)
        return nil
    }
    return a
}

@(private)
kit_inputs :: proc(k:^Kit_Cache,seat:^inp.Seat) -> inp.Action_Mask {
    pressed,released,down:inp.Action_Mask
    for &s,i in seat.actions.states[:min(seat.actions.count,inp.ACTION_CAPACITY)] {
        bit:=inp.action_bit(inp.Action(i))
        if s.pressed {pressed|=bit}
        if s.released {released|=bit}
        if s.down {down|=bit}
    }
    mask:=pressed&k.actions[.Pressed]|released&k.actions[.Released]|
          down&(k.actions[.Down]|k.actions[.Held])
    return mask&~(seat.blocked|seat.rearm)
}

@(private)
input_state :: proc(seat:^inp.Seat,a:inp.Action) -> inp.Action_State {
    if seat==nil || int(a)>=inp.ACTION_CAPACITY || (seat.blocked|seat.rearm)&inp.action_bit(a)!=0 {return {}}
    return inp.action(&seat.actions,a)
}

@(private)
input_fired :: proc(dt:f32,input:Ability_Input,s:inp.Action_State) -> bool {
    crossed:=input.hold-dt*0.5
    switch input.on {
    case .None: return false
    case .Pressed: return s.pressed
    case .Released: return s.released && s.released_held>=crossed
    case .Held: return s.down && s.held>=crossed && (s.pressed || s.held-dt<crossed)
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
can_start :: proc(t:^Tick,e:core.Entity,u:^Actor,kit:^Ability_Kit,active:^Ability,at:Ability_Time,a:^Ability,ref:core.Record(Ability)) -> bool {
    return start_block(t.w,t.tick,t.dt,e,u.user,u.state,u.track,u.state.statuses,kit,active,at,a,ref)==.None
}

// Why ability a cannot start for user u at tick, with active running at at.
start_block :: proc(w:^Ability_World,tick:u64,dt:f32,e:core.Entity,user:^Ability_User,state:^Ability_State,track:^Ability_Tracking,statuses:Ability_Statuses,kit:^Ability_Kit,active:^Ability,at:Ability_Time,a:^Ability,ref:core.Record(Ability)) -> Ability_Block {
    if statuses&a.requires!=a.requires {return .Status_Missing}
    if statuses&a.blocked_by!=0 {return .Status_Blocked}
    if a.modes!=0 {
        if w.locomotions==nil {return .Mode}
        c,found:=core.get(w.locomotions,e)
        if !found || u32(c.mode)>=32 || a.modes&Ability_Modes(u32(1)<<u32(c.mode))==0 {return .Mode}
    }
    for c in a.conditions {
        if c.attribute==ATTRIBUTE_NONE {continue}
        value,found:=ability_value(user,state,c.attribute)
        if !found || value<c.at_least || c.at_most>0 && value>c.at_most {return .Condition}
    }
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        value,found:=ability_value(user,state,c.attribute)
        if !found || value<c.amount {return .Cost}
    }
    for &c in track.cooldowns {
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
ability_start :: proc(t:^Tick,e:core.Entity,u:^Actor,ref:core.Record(Ability),a:^Ability) {
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        for entry,i in u.user.attributes {
            if entry.attribute==c.attribute {base_add(t,e,u,i,-c.amount)}
        }
    }
    if a.cooldown>0 {
        slot:=0
        for &c,i in u.track.cooldowns {
            if c.ability==ref || c.until==0 {slot=i;break}
            if c.until<u.track.cooldowns[slot].until {slot=i}
        }
        core.edit_at(t.tracking,u.track_row).cooldowns[slot]={ref,core.deadline(t.w.time,a.cooldown)}
    }
    for &b,i in u.track.buffer {
        if b.ability==ref {core.edit_at(t.tracking,u.track_row).buffer[i]={}}
    }
    state:=core.edit_at(t.states,u.state_row)
    state.ability,state.start,state.own=ref,t.tick,0
    event_push(t,{kind=.Started,entity=e,ability=ref,window=-1})
    feedback_emit(t,a.on_start,e)
    if name:=ability_name_text(&a.action);name!="" {anim.play(t.w.animations,e,name)}
}

// Ends the running ability at at: its open windows close, their moves stop and its animation
// stops unless next plays the same action. An action next does not play again is stopped even when
// next plays another: in another layer nothing would replace it, and a looping section would play
// on, and in the same layer the one next plays takes the layer.
@(private)
ability_end :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,at:Ability_Time,kind:Ability_Event_Kind,next:^Ability) {
    ref:=u.state.ability
    if a!=nil {
        for &w,i in a.windows {
            if !ability_window_open(w,t.dt,at) {continue}
            event_push(t,{kind=.Window_End,entity=e,ability=ref,window=i8(i),cue=w.cue})
            if w.move.velocity!={} {locomotion.remove_moves(t.w.moves,e,MOVE_ID+u32(i))}
        }
        if kind!=.Completed || a.hold {
            if name:=ability_name_text(&a.action);name!="" && (next==nil || ability_name_text(&next.action)!=name) {anim.stop(t.w.animations,e,name)}
        }
    }
    state:=core.edit_at(t.states,u.state_row)
    state.ability,state.start,state.own={},0,0
    if u.track.hit_count!=0 {
        track:=core.edit_at(t.tracking,u.track_row)
        track.hit_count,track.targets,track.windows=0,{},{}
    }
    event_push(t,{kind=kind,entity=e,ability=ref,window=-1})
}

// Where an ability is on the tick before its start: no window is open there.
@(private)
TIME_BEFORE_START :: Ability_Time{local=-1,own=-1}

// Moves the running ability of u to this tick: its own time grows by the pace of e. Returns where
// it was on the tick before.
@(private)
time_advance :: proc(t:^Tick,e:core.Entity,u:^Actor) -> (before:Ability_Time) {
    before=time_of(t,u.state)
    if before.local<=0 {return TIME_BEFORE_START}
    before.local-=1
    if pace:=pace_tick(t,e);pace!=0 {core.edit_at(t.states,u.state_row).own+=pace}
    return
}

// The windows that open or close at at, against before (the tick before).
@(private)
windows_advance :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,before,at:Ability_Time,replica:=false) {
    for &w,i in a.windows {
        was,is:=ability_window_open(w,t.dt,before),ability_window_open(w,t.dt,at)
        if is && !was {
            event_push(t,{kind=.Window_Begin,entity=e,ability=u.state.ability,window=i8(i),cue=w.cue})
            feedback_emit(t,w.on_begin,e)
            if !replica && w.move.velocity!={} {
                velocity:=w.move.velocity
                if pose,found:=core.get(t.w.worlds,e);found {velocity=mm.quat_rotate(pose.rotation,velocity)}
                from,to:=window_ticks(w,t.dt)
                ticks:=u32(to-from)
                // On the Own clock it lasts until the window closes, which removes it.
                if w.clock==.Own {ticks=u32(math.ceil(f32(to-from)/max(pace_tick(t,e),1.0/64)))}
                locomotion.add_move(t.w.moves,e,{velocity=velocity,ticks=ticks,mix=w.move.mix,id=MOVE_ID+u32(i)})
            }
        }
        if was && !is {
            event_push(t,{kind=.Window_End,entity=e,ability=u.state.ability,window=i8(i),cue=w.cue})
            if !replica && w.clock==.Own && w.move.velocity!={} {locomotion.remove_moves(t.w.moves,e,MOVE_ID+u32(i))}
        }
    }
}

// Each open hitbox touches each entity once: a Hit and the effect of the window, on the tick after.
@(private)
hitboxes :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,at:Ability_Time) {
    pose,found:=core.get(t.w.worlds,e)
    if !found {pose.rotation=1}
    for &w,i in a.windows {
        if w.hitbox=={} || !ability_window_open(w,t.dt,at) || t.overlap==nil {continue}
        h:=record_sheet(t.hitboxes,w.hitbox)
        if h==nil {continue}
        results:[HITBOX_RESULTS]core.Entity
        count:=clamp(t.overlap(t.w,h,pose.transform,results[:]),0,HITBOX_RESULTS)
        each: for target in results[:count] {
            if target==e || target==core.NONE {continue}
            for j in 0..<min(int(u.track.hit_count),USER_HITS) {
                if u.track.targets[j]==target && int(u.track.windows[j])==i {continue each}
            }
            if int(u.track.hit_count)>=USER_HITS {
                core.report(t.w.problems,e,"abilities.hits","the ability %s touched more than %d entities: smaller hitboxes, or fewer windows with hitboxes",core.record_name(t.abilities,u.state.ability),USER_HITS)
                return
            }
            track:=core.edit_at(t.tracking,u.track_row)
            track.targets[track.hit_count],track.windows[track.hit_count]=target,u8(i)
            track.hit_count+=1
            event_push(t,{kind=.Hit,entity=e,ability=u.state.ability,window=i8(i),cue=w.cue,target=target})
            feedback_emit(t,h.on_hit,target,e)
            if h.effect!={} {ability_effect(t.requests,target,h.effect,e)}
        }
    }
}

// The statuses and current values of a user: those of its timers and of the windows open at at.
@(private)
derive :: proc(t:^Tick,u:^Actor,active:^Ability,at:Ability_Time) {
    statuses:Ability_Statuses
    add,more:[ATTRIBUTE_ENTRIES]f32
    modify :: proc(u:^Ability_User,m:Ability_Modifier,add,more:^[ATTRIBUTE_ENTRIES]f32) {
        if m.attribute==ATTRIBUTE_NONE {return}
        for entry,i in u.attributes {
            if entry.attribute==m.attribute {add[i]+=m.add;more[i]+=m.more}
        }
    }
    for &timer in u.track.timers {
        if timer.until==0 {continue}
        statuses|=timer.statuses
        m:=timer.modify
        stacks:=f32(max(timer.stacks,1))
        m.add*=stacks;m.more*=stacks
        modify(u.user,m,&add,&more)
    }
    if active!=nil {
        for &w in active.windows {
            if !ability_window_open(w,t.dt,at) {continue}
            statuses|=w.statuses
            modify(u.user,w.modify,&add,&more)
        }
    }
    values:[ATTRIBUTE_ENTRIES]f32
    for entry,i in u.user.attributes {
        if entry.attribute!=ATTRIBUTE_NONE {
            values[i]=max((entry.base+add[i])*max(1+more[i],0),0)
        }
    }
    if u.state.statuses!=statuses || u.state.values!=values {
        state:=core.edit_at(t.states,u.state_row)
        state.statuses,state.values=statuses,values
    }
}

@(private)
event_push :: proc(t:^Tick,event:Ability_Event) {
    if t.events==nil {return}
    if t.event_count>=EVENT_CAPACITY || len(t.events.queue.items)>=cap(t.events.queue.items) {
        core.report(t.w.problems,core.NONE,"abilities.events","ability event capacity reached: remaining events were dropped")
        return
    }
    t.event_count+=1
    core.push(&t.events.queue,event)
}

@(private)
feedback_emit :: proc(t:^Tick,ref:core.Record(Ability_Feedback),entity:core.Entity,fallback:=core.NONE) {
    row:=record_row(t.feedback,ref)
    f:=record_at(t.feedback,row)
    if f==nil {return}
    pose,placed:=core.get(t.w.worlds,entity)
    if !placed && fallback!=core.NONE {pose,placed=core.get(t.w.worlds,fallback)}
    if t.w.sounds!=nil && f.sound!={} && !t.w.time.resimulating {
        sounds:=t.w.sounds
        if len(sounds.queue.items)<cap(sounds.queue.items) {
            at:Maybe([3]f32)
            if placed {at=pose.position}
            audio.play_id(sounds,f.sound,at)
        } else {feedback_full(t,entity)}
    }
    if t.w.births!=nil && placed && t.sheets.channels[row]!=0 {
        births:=t.w.births
        if len(births.queue.items)<cap(births.queue.items) {
            core.push(&births.queue,core.Birth{channel=t.sheets.channels[row],position=pose.position})
        } else {feedback_full(t,entity)}
    }
}

@(private)
feedback_full :: proc(t:^Tick,e:core.Entity) {
    core.report(t.w.problems,e,"abilities.feedback","ability feedback queue is full: use fewer simultaneous cues")
}
