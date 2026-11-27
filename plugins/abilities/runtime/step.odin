package abilities

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "mirai:host"
import "mirai:std/base"
import audio "mirai:engine/audio"
import "mirai:core"
import inp "mirai:engine/input"
import scene "mirai:engine/scene"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// What abilities_step reads of the rest of the world and asks of it.
@(params)
Ability_World :: struct {
    time:core.Time,
    seats:core.Ref(inp.Seats),
    seat_states:core.Ref(inp.Seat_States),
    characters:^core.Table(phys.Character,.Read),
    locomotions:^core.Table(locomotion.Locomotion_State,.Read), // the modes the characters are in
    grounds:^core.Table(phys.Character_State,.Read), // what Speed conditions measure from
    motions:^core.Table(core.Motion,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    remotes:^core.Table(core.Remote,.Read),
    paces:^core.Table(core.Own_Pace,.Read), // the windows on the Own clock count the user's own time
    helds:^core.Table(Ability_Held,.Read),
    tags:^core.Table(scene.Tags,.Read), // target class tags for hitbox/effect matching
    clock:core.Clock,
    physics:core.Ref(phys.Physics_State),
    moves:^locomotion.Locomotion_Requests,
    animations:^anim.Animation_Requests,
    anim_events:core.Ref(anim.Animation_Events), // .Span_Begin/.Span_End for clip-span-bound windows
    problems:^core.Problems,
    sounds:^audio.Sound_Requests,
    births:^core.Births,
    ids:^core.Table(core.Id,.Read), // what seeds the spread of a ray alike on every end
    verticals:^core.Table(core.Vertical,.Read), // the frame the view of a seat is in, for its aim
    attachments:^core.Table(anim.Bone_Attachment,.Read), // the rig a user hangs from, for a cue at a socket
    clips:^core.Table(anim.Animation,.Read), // a user that animates itself (a weapon's clip) plays its actions; else its wielder
    playback:core.Ref(anim.Playback),
    skeletons:core.Ref(anim.Skeleton_Assets),
    kicks:^inp.Look_Kicks,
    shots:^Ability_Shots,
}

// The entities a hitbox at pose touches, written into results.
Hitbox_Overlap :: #type proc(w:^Ability_World,hitbox:^Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int

@(params)
Ability_Tables :: struct {
    users:^core.Table(Ability_User),
    states:^core.Table(Ability_State),
    tracking:^core.Table(Ability_Tracking),
    locals:^core.Table(Ability_Local),
    wielded:^core.Table(Ability_Wielded),
}

@(step="fixed",stage="begin",loops="game")
abilities_prepare :: proc(
    tables:Ability_Tables,checks:^Ability_Attributes,events:^Ability_Events,
    problems:^core.Problems,app:^host.App,
) {
    ability_rows(tables,checks,problems)
    if core.count(tables.users)==0 {return}
    // The log holds the preceding frame and every tick of this one until the next age.
    ability_room(events,2*max(app.max_ticks,1)*EVENT_CAPACITY,problems)
}

@(step="fixed")
abilities_step :: proc(tables:Ability_Tables,data:Ability_Data,sheets:^Ability_Sheets,checks:^Ability_Attributes,requests:^Ability_Requests,events:^Ability_Events,w:Ability_World) {
    w:=w
    abilities_tick(tables,data,sheets,checks,requests,events,&w,physics_overlap)
}

@(private)
ability_room :: proc(events:^Ability_Events,room:int,problems:^core.Problems) {
    if events!=nil && cap(events.queue.items)<room && reserve(&events.queue.items,room)!=nil {
        core.report(problems,core.NONE,"abilities.events","out of memory for ability events")
    }
}

@(private)
ability_rows :: proc(tables:Ability_Tables,checks:^Ability_Attributes,problems:^core.Problems) {
    if !core.reshaped(tables.users,&checks.shape) {return}
    changes:=core.changes(tables.users,&checks.seen)
    core.entity_map_prune(&checks.entries,tables.users,changes)
    for row in 0..<core.count(tables.users) {
        e:=core.entity_at(tables.users,row)
        // The bases start where the user's attributes say.
        start:Ability_State
        for entry,i in core.at(tables.users,row).attributes {start.bases[i]=clamp_base(entry,entry.base) if finite(entry.base) else 0}
        if !core.has(tables.states,e) && !core.add(tables.states,e,start) ||
           !core.has(tables.tracking,e) && !core.add(tables.tracking,e,Ability_Tracking{}) ||
           !core.has(tables.locals,e) && !core.add(tables.locals,e,Ability_Local{}) {
            checks.shape={}
            core.report(problems,e,"abilities.state","out of memory for ability state")
        }
    }
    prune_rows(tables.states,tables.users)
    prune_rows(tables.tracking,tables.users)
    prune_rows(tables.locals,tables.users)
    room:=cap(tables.users.values)
    if !edit_room(tables.users,room) || !edit_room(tables.states,room) || !edit_room(tables.tracking,room) || !edit_room(tables.locals,room) {
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
    return core.table_edit_reserve(rows,room)
}

physics_overlap :: proc(w:^Ability_World,hitbox:^Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int {
    center,_:=hitbox_world(hitbox,pose)
    count:int
    switch hitbox.shape {
    case .None,.Ray,.Self:
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
    local:^Ability_Local,
    user_row,state_row,track_row,local_row:int,
    entity:core.Entity,
    driver:core.Entity,   // its wielder, or itself: whose seat, statuses, modes and moves are its own
    animated:core.Entity, // itself when it has an Animation, else its driver: where its actions play and its clip spans come from
}

@(private)
actor_at :: proc(t:^Tick,e:core.Entity,row:int) -> (u:Actor,ok:bool) {
    sr,tr,lr:=core.row_of(t.states,e),core.row_of(t.tracking,e),core.row_of(t.locals,e)
    if row<0 || sr<0 || tr<0 || lr<0 {return}
    u={user=&t.users.values[row],state=&t.states.values[sr],track=&t.tracking.values[tr],local=&t.locals.values[lr],
       user_row=row,state_row=sr,track_row=tr,local_row=lr}
    u.entity,u.driver=e,e
    if t.wielded!=nil {
        if held,found:=core.get(t.wielded,e);found && held.wielder!=core.NONE {u.driver=held.wielder}
    }
    u.animated=e if t.w.clips!=nil && core.has(t.w.clips,e) else u.driver
    stamp:=core.stamp(t.users,row)
    cached:=core.entity_map_get(&t.checks.entries,e)
    if cached==nil {
        cached,ok=core.entity_map_put(&t.checks.entries,e,Attribute_Check{})
        if !ok {
            core.report(t.w.problems,e,"abilities.attributes","out of memory for attribute validation")
            return u,false
        }
        cached.stamp=~stamp
    }
    if cached.stamp!=stamp {
        cached.problem,cached.index=attributes_check(u.user)
        cached.stamp=stamp
    }
    attribute_report(t.w.problems,e,cached.problem,cached.index)
    return u,cached.problem==.None
}

// The local row of u, to write.
@(private)
local_edit :: #force_inline proc(t:^Tick,u:^Actor) -> ^Ability_Local {return core.edit_at(t.locals,u.local_row)}

// The fields of the run in the local row follow the run of Ability_State: when another ability or
// start tick comes (from the network to a replica, or from a correction), they start again, its own
// time from where its pace has taken it.
@(private)
local_follow :: proc(t:^Tick,e:core.Entity,u:^Actor) {
    run:=u.state.start+1 if u.state.ability!={} else 0
    if u.local.run==run {return}
    l:=local_edit(t,u)
    ticks:=f32(t.tick-u.state.start) if run!=0 && t.tick>u.state.start else 0
    l.run,l.own,l.span_open,l.span_start,l.end_since=run,ticks*pace_tick(t,u.animated),0,{},0
    l.hit_count,l.targets,l.windows=0,{},{}
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
            ability_end(t,r.entity,&u,record_sheet(t.abilities,u.state.ability),time_of(t,&u),.Canceled,nil)
        }
    case .Kit:
        if u.user.kit!=r.kit {core.edit_at(t.users,u.user_row).kit=r.kit}
        local_edit(t,&u).buffer={}
    case .Wield:
        if t.wielded==nil || r.source==r.entity || u.driver==(r.source if r.source!=core.NONE else r.entity) {return}
        if u.state.ability!={} {
            ability_end(t,r.entity,&u,record_sheet(t.abilities,u.state.ability),time_of(t,&u),.Canceled,nil)
        }
        if r.source==core.NONE {
            core.remove(t.wielded,r.entity)
        } else if held:=core.edit(t.wielded,r.entity);held!=nil {
            held.wielder=r.source
        } else if !core.add(t.wielded,r.entity,Ability_Wielded{r.source}) {
            core.report(t.w.problems,r.entity,"abilities.state","out of memory for its wielder")
        }
        local_edit(t,&u).buffer={}
    case .Effect:
    }
}

@(private)
effect_apply :: proc(t:^Tick,target,source:core.Entity,effect:Ability_Effect) {
    if text:=effect_check(effect,t.text[:]);text!="" {
        core.report(t.w.problems,target,"abilities.effect","an effect asked for it %s",text)
        return
    }
    if effect.target_tags.bits!=0 {
        target_tags:scene.Tags
        if t.w.tags!=nil {target_tags,_=core.get(t.w.tags,target)}
        if !scene.tag_has_any(target_tags,effect.target_tags) {return}
    }
    row:=core.row_of(t.users,target)
    u,valid:=actor_at(t,target,row)
    if row>=0 && !valid {return}
    if valid && u.local.statuses&effect.blocked_by!=0 {return}
    amount:=effect.amount
    if effect.scale_by!=ATTRIBUTE_NONE && amount!=0 {
        from:=core.row_of(t.users,source)
        scale:f32
        has:bool
        if lr:=core.row_of(t.locals,source);from>=0 && lr>=0 {scale,has=ability_value(&t.users.values[from],&t.locals.values[lr],effect.scale_by)}
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
                if entry.attribute==effect.attribute {base_add(t,target,&u,i,amount,spend=amount<0)}
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

// Adds amount to base index now: a new line from this tick, with the rates it had. A spend puts off
// positive regeneration by regen_delay.
@(private)
base_add :: proc(t:^Tick,e:core.Entity,u:^Actor,index:int,amount:f32,spend:=false) {
    entry:=u.user.attributes[index]
    if spend && amount<0 && entry.regen_delay>0 {
        core.edit_at(t.tracking,u.track_row).regen_at[index]=core.deadline(t.w.time,entry.regen_delay)
    }
    before:=ability_base(u.user,u.state,index,t.tick,t.dt)
    value:=clamp_base(entry,before+amount)
    if !finite(value) {value=max(f32) if value>0 else 0}
    if value==before {return}
    bases_set(t,u,u.state.rates,u.state.drains)
    core.edit_at(t.states,u.state_row).bases[index]=value
    if before>0 && value<=0 {event_push(t,{kind=.Depleted,entity=e,window=-1,attribute=entry.attribute})}
}

// A new line of the bases from this tick, where they are now, at rates.
@(private)
bases_set :: proc(t:^Tick,u:^Actor,rates:[ATTRIBUTE_ENTRIES]f32,drains:u8) {
    bases:[ATTRIBUTE_ENTRIES]f32
    for _,i in bases {bases[i]=ability_base(u.user,u.state,i,t.tick,t.dt)}
    state:=core.edit_at(t.states,u.state_row)
    state.bases,state.since,state.rates,state.drains=bases,t.tick,rates,drains
}

// The rates of the bases from this tick: regeneration, which a positive one waits for while a drain
// takes from it and regen_delay after, less what the per_second costs of active take outside its
// pause_modes. A drain that stops starts the regen_delay. The line changes only when they do. A
// base that a rate took to 0 since the tick before is Depleted.
@(private)
rates_update :: proc(t:^Tick,e:core.Entity,u:^Actor,active:^Ability) {
    paused:=active!=nil && mode_in(t,u.driver,active.pause_modes)
    rates:[ATTRIBUTE_ENTRIES]f32
    drains:u8
    for entry,i in u.user.attributes {
        if entry.attribute==ATTRIBUTE_NONE {continue}
        if u.state.rates[i]<0 && t.tick>u.state.since && ability_base(u.user,u.state,i,t.tick-1,t.dt)>0 && ability_base(u.user,u.state,i,t.tick,t.dt)<=0 {
            event_push(t,{kind=.Depleted,entity=e,window=-1,attribute=entry.attribute})
        }
        drain:f32
        if active!=nil && !paused {
            for c in active.costs {
                if c.attribute==entry.attribute && c.per_second>0 {drain+=c.per_second}
            }
        }
        bit:=u8(1)<<u8(i)
        if drain>0 {drains|=bit}
        waits:=entry.regen>0 && entry.regen_delay>0
        if waits && drain==0 && u.state.drains&bit!=0 {
            core.edit_at(t.tracking,u.track_row).regen_at[i]=core.deadline(t.w.time,entry.regen_delay)
        }
        regen:=entry.regen
        if waits && (drain>0 || !core.due(t.w.time,u.track.regen_at[i])) {regen=0}
        rates[i]=regen-drain
    }
    if rates!=u.state.rates || drains!=u.state.drains {bases_set(t,u,rates,drains)}
}

@(private)
buffer_add :: proc(t:^Tick,u:^Actor,ability:core.Record(Ability),running:bool) {
    if ability=={} {return}
    slot:=-1
    for b,i in u.local.buffer {
        if b.ability==ability {slot=i;break}
    }
    if slot<0 {
        slot=0
        for b,i in u.local.buffer {
            if b.ability=={} {slot=i;break}
            if b.tick<u.local.buffer[slot].tick {slot=i}
        }
    }
    run:=u.state.start+1 if running && u.state.ability!={} else 0
    local_edit(t,u).buffer[slot]={ability=ability,tick=t.tick,run=run}
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

// Whether a window is open at a place of its ability's timeline, on the clock it counts or by its
// clip span bitmask (at.spans). Pass the window's index in Ability.windows for span-bound windows.
ability_window_open :: #force_inline proc "contextless" (w:Ability_Window,dt:f32,at:Ability_Time,index:int=-1) -> bool {
    if w.span[0]!=0 {return index>=0 && index<ABILITY_WINDOWS && at.spans&(u16(1)<<u16(index))!=0}
    if w.to==0 {return false}
    from,to:=window_ticks(w,dt)
    if w.clock==.Own {return at.own>=f32(from) && at.own<f32(to)}
    return at.local>=from && at.local<to
}

// Where the running ability of u is at this tick.
@(private)
time_of :: #force_inline proc "contextless" (t:^Tick,u:^Actor) -> Ability_Time {
    return {local=i64(t.tick-u.state.start) if t.tick>=u.state.start else 0,own=u.local.own,spans=u.local.span_open}
}

// The ticks of its own time e lives in one tick of the world.
@(private)
pace_tick :: #force_inline proc "contextless" (t:^Tick,e:core.Entity) -> f32 {
    return core.pace_of(t.w.clock,t.w.paces,e)
}

ability_ticks :: #force_inline proc "contextless" (a:^Ability,dt:f32) -> i64 {return max(i64(ticks_of(a.duration,dt)),1)}

@(private)
user_tick :: proc(t:^Tick,e:core.Entity,u:^Actor) {
    local_follow(t,e,u)
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
                if entry.attribute==timer.attribute {base_add(t,e,u,j,timer.amount*f32(max(timer.stacks,1)),spend=timer.amount<0)}
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
    for &b,i in u.local.buffer {
        if b.ability=={} || t.tick<=b.tick || t.tick-b.tick<=buffer {continue}
        if b.run!=0 && u.state.ability!={} && u.state.start+1==b.run {continue}
        local_edit(t,u).buffer[i]={}
    }
    // The running ability advances to this tick, on the clock of the world and on its own.
    next:core.Record(Ability)
    handoff:Ability_Statuses // of the windows open on the last tick of the ability that completed: its next starts in them
    at:Ability_Time
    before:=TIME_BEFORE_START
    active:=sheet_valid(t,e,u.state.ability)
    if u.state.ability!={} && active==nil {ability_end(t,e,u,nil,{},.Canceled,nil)}
    seat:^inp.Seat_State
    if t.w.seats.ptr!=nil && t.w.seat_states.ptr!=nil && (cached!=nil && cached.count>0 || active!=nil && active.hold) {
        seat=inp.seat_runtime(t.w.seat_states,inp.seat_of(t.w.seats,u.driver))
    }
    if active!=nil {
        before=time_advance(t,e,u)
        span_advance(t,e,u,active,i64(t.tick-u.state.start) if t.tick>=u.state.start else 0)
        at=time_of(t,u)
        windows_advance(t,e,u,active,before,at)
        if at.local>=ability_ticks(active,t.dt) {
            next=active.next
            for &w,i in active.windows {
                if ability_window_open(w,t.dt,before,i) {handoff|=w.statuses}
            }
            ability_end(t,e,u,active,at,.Completed,nil)
            active=nil
        } else if active.hold && active.input.on!=.None && !input_state(seat,active.input.action).down || !costs_pay(t,e,u,active) {
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
    derive(t,e,u,active,at)
    // The best valid candidate starts.
    best:=-1
    best_ref:=next
    best_sheet:=sheet_valid(t,e,next) if next!={} else nil
    if best_sheet!=nil {
        // The next of a completed ability is its last branch: it starts in the statuses the
        // ability had then (a dash that requires the charging status of its charge).
        if block,_:=start_block(t.w,t.tick,t.dt,u.driver,u.user,u.local,u.track,gate_statuses(t,u)|handoff,kit,active,at,best_sheet,next);block!=.None {
            best_sheet=nil
        }
    }
    for b,i in u.local.buffer {
        if b.ability=={} {continue}
        a:=sheet_valid(t,e,b.ability)
        if a==nil {local_edit(t,u).buffer[i]={};continue}
        if !can_start(t,e,u,kit,active,at,a,b.ability) {continue}
        if best_sheet==nil || a.priority>best_sheet.priority || a.priority==best_sheet.priority && best>=0 && b.tick<u.local.buffer[best].tick {
            best,best_ref,best_sheet=i,b.ability,a
        }
    }
    if best_sheet!=nil {
        if active!=nil {ability_end(t,e,u,active,at,.Interrupted,best_sheet)}
        ability_start(t,e,u,best_ref,best_sheet)
        active,at,before=best_sheet,{},TIME_BEFORE_START
        windows_advance(t,e,u,active,before,at)
    }
    if active!=nil {
        hitboxes(t,e,u,active,before,at)
        rays(t,e,u,active,before,at,true)
        kicks(t,u,active,before,at)
    }
    rates_update(t,e,u,active)
    if best_sheet!=nil {derive(t,e,u,active,at)}
    held_attach(t,e,u,active,at)
}

// Whether e's Character is in one of modes.
// The statuses that gate what u starts: its own and those of its wielder.
@(private)
gate_statuses :: proc(t:^Tick,u:^Actor) -> Ability_Statuses {
    statuses:=u.local.statuses
    if u.driver!=u.entity {
        if wielder,found:=core.get(t.locals,u.driver);found {statuses|=wielder.statuses}
    }
    return statuses
}

@(private)
mode_in :: proc(t:^Tick,e:core.Entity,modes:Ability_Modes) -> bool {
    if modes==0 || t.w.locomotions==nil {return false}
    loco,found:=core.get(t.w.locomotions,e)
    return found && u32(loco.mode)<32 && modes&Ability_Modes(u32(1)<<u32(loco.mode))!=0
}

// Whether the running ability goes on: false once an attribute its per_second costs drain is spent
// (the rates of Ability_State take it, rates_update) or its Character has been end_grace in its
// end_modes, which completes it.
@(private)
costs_pay :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability) -> bool {
    if a.end_modes!=0 {
        ending:=mode_in(t,u.driver,a.end_modes)
        since:=u.local.end_since
        if ending!=(since!=0) {
            since=t.tick if ending else 0
            local_edit(t,u).end_since=since
        }
        if ending && t.tick-since>=ticks_of(a.end_grace,t.dt) {return false}
    }
    each: for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || !(c.per_second>0) {continue}
        for entry,i in u.user.attributes {
            if entry.attribute!=c.attribute {continue}
            if u.state.drains&(u8(1)<<u8(i))!=0 && ability_base(u.user,u.state,i,t.tick,t.dt)<=0 {return false}
            continue each
        }
        return false
    }
    return true
}

// A replica follows the ability its owner runs: its statuses and the events of its windows.
@(private)
replica_tick :: proc(t:^Tick,e:core.Entity,u:^Actor) {
    local_follow(t,e,u)
    active:=sheet_valid(t,e,u.state.ability)
    at:Ability_Time
    if active!=nil {
        before:=time_advance(t,e,u)
        span_advance(t,e,u,active,i64(t.tick-u.state.start) if t.tick>=u.state.start else 0)
        at=time_of(t,u)
        if at.local<ability_ticks(active,t.dt) {
            windows_advance(t,e,u,active,before,at,replica=true)
            rays(t,e,u,active,before,at,false)
        } else {active=nil}
    }
    derive(t,e,u,active,at,replica=true)
    held_attach(t,e,u,active,at)
}

// Where the held entity of a user is, derived like its statuses: at its socket while a window
// with attach of the running ability is open, or at its own. It is asked when that changes (or the
// held entity does), and an ability that ends or is interrupted leaves it at its own.
@(private)
held_attach :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,at:Ability_Time) {
    if t.w.animations==nil || t.w.helds==nil || core.count(t.w.helds)==0 {return}
    held,found:=core.get(t.w.helds,e)
    if !found || held.entity==core.NONE {return}
    at_socket:=false
    if a!=nil {
        for &w,i in a.windows {
            if w.attach && ability_window_open(w,t.dt,at,i) {at_socket=true;break}
        }
    }
    if u.local.held==held.entity && u.local.held_at==at_socket {return}
    l:=local_edit(t,u)
    l.held,l.held_at=held.entity,at_socket
    anim.attach(t.w.animations,held.entity,base.text_get(held.socket[:]) if at_socket else "",held.blend)
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
kit_inputs :: proc(k:^Kit_Cache,seat:^inp.Seat_State) -> inp.Action_Mask {
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
input_state :: proc(seat:^inp.Seat_State,a:inp.Action) -> inp.Action_State {
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
    block,_:=start_block(t.w,t.tick,t.dt,u.driver,u.user,u.local,u.track,gate_statuses(t,u),kit,active,at,a,ref)
    return block==.None
}

// Why ability a cannot start for user u at tick, with active running at at, and what fails: of
// Status_Missing the first status it requires that the user is not in, of Status_Blocked the first
// it is in that blocks it, of Mode the mode of the user's Character (-1 without one), of Condition
// and Cost the index in a.conditions or a.costs, of Cooldown that in track.cooldowns; else -1.
start_block :: proc(w:^Ability_World,tick:u64,dt:f32,e:core.Entity,user:^Ability_User,local:^Ability_Local,track:^Ability_Tracking,statuses:Ability_Statuses,kit:^Ability_Kit,active:^Ability,at:Ability_Time,a:^Ability,ref:core.Record(Ability)) -> (block:Ability_Block,index:int) {
    if missing:=a.requires&~statuses;missing!=0 {return .Status_Missing,int(intrinsics.count_trailing_zeros(u64(missing)))}
    if blocking:=statuses&a.blocked_by;blocking!=0 {return .Status_Blocked,int(intrinsics.count_trailing_zeros(u64(blocking)))}
    if a.modes!=0 {
        if w.locomotions==nil {return .Mode,-1}
        c,found:=core.get(w.locomotions,e)
        if !found {return .Mode,-1}
        if u32(c.mode)>=32 || a.modes&Ability_Modes(u32(1)<<u32(c.mode))==0 {return .Mode,int(c.mode)}
    }
    for c,i in a.conditions {
        if !condition_holds(w,e,user,local,c) {return .Condition,i}
    }
    for c,i in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        value,found:=ability_value(user,local,c.attribute)
        if !found || value<c.amount {return .Cost,i}
    }
    for &c,i in track.cooldowns {
        if c.ability==ref && c.until>tick {return .Cooldown,i}
    }
    if active!=nil {
        accepted:=kit.interrupts if kit!=nil else 0
        for &w,i in active.windows {
            if ability_window_open(w,dt,at,i) {accepted|=w.cancel_into}
        }
        if accepted&a.tags==0 {return .No_Cancel,-1}
    }
    return .None,-1
}

// Whether a condition of an ability holds for user e now.
condition_holds :: proc(w:^Ability_World,e:core.Entity,user:^Ability_User,local:^Ability_Local,c:Ability_Condition) -> bool {
    within :: proc "contextless" (value:f32,c:Ability_Condition) -> bool {return value>=c.at_least && (c.at_most<=0 || value<=c.at_most)}
    switch c.kind {
    case .Attribute:
        if c.attribute==ATTRIBUTE_NONE {return true}
        value,found:=ability_value(user,local,c.attribute)
        return found && within(value,c)
    case .Speed:
        if w.grounds==nil || w.motions==nil {return false}
        ground,_:=core.get(w.grounds,e)
        motion,_:=core.get(w.motions,e)
        capsule,made:=phys.character_capsule(w.physics,e)
        if !made {return false}
        up:=mm.quat_rotate(capsule.up_frame,mm.Vec3{0,1,0})
        going:=motion.linear-ground.ground_velocity if ground.standing else motion.linear
        going-=up*linalg.dot(going,up)
        return within(linalg.length(going),c)
    }
    return false
}

@(private)
ability_start :: proc(t:^Tick,e:core.Entity,u:^Actor,ref:core.Record(Ability),a:^Ability) {
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || !(c.amount>0) {continue}
        for entry,i in u.user.attributes {
            if entry.attribute==c.attribute {base_add(t,e,u,i,-c.amount,spend=true)}
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
    l:=local_edit(t,u)
    for &b in l.buffer {
        if b.ability==ref {b={}}
    }
    state:=core.edit_at(t.states,u.state_row)
    state.ability,state.start=ref,t.tick
    l.run,l.own,l.span_open,l.span_start,l.end_since=t.tick+1,0,0,{},0
    l.hit_count,l.targets,l.windows=0,{},{}
    event_push(t,{kind=.Started,entity=e,ability=ref,window=-1})
    if name:=ability_name_text(&a.action);name!="" {anim.play(t.w.animations,u.animated,name)}
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
            if !ability_window_open(w,t.dt,at,i) {continue}
            event_push(t,{kind=.Window_End,entity=e,ability=ref,window=i8(i),cue=w.cue})
            if w.move.velocity!={} {locomotion.remove_moves(t.w.moves,u.driver,MOVE_ID+u32(i))}
        }
        if kind!=.Completed || a.hold {
            if name:=ability_name_text(&a.action);name!="" && (next==nil || ability_name_text(&next.action)!=name) {anim.stop(t.w.animations,u.animated,name)}
        }
    }
    state:=core.edit_at(t.states,u.state_row)
    state.ability,state.start={},0
    l:=local_edit(t,u)
    l.run,l.own,l.span_open,l.end_since=0,0,0,0
    l.hit_count,l.targets,l.windows=0,{},{}
    event_push(t,{kind=kind,entity=e,ability=ref,window=-1})
}

// Where an ability is on the tick before its start: no window is open there.
@(private)
TIME_BEFORE_START :: Ability_Time{local=-1,own=-1,spans=0}

// Moves the running ability of u to this tick: its own time grows by the pace of e. Returns where
// it was on the tick before.
@(private)
time_advance :: proc(t:^Tick,e:core.Entity,u:^Actor) -> (before:Ability_Time) {
    before=time_of(t,u)
    if before.local<=0 {return TIME_BEFORE_START}
    before.local-=1
    if pace:=pace_tick(t,u.animated);pace!=0 {local_edit(t,u).own+=pace}
    return
}

// Updates state.span_open from Animation_Events (.Span_Begin / .Span_End) for clip-span-bound
// windows of the running ability a of entity e. When a.action is set, only events from that
// action match (unnamed clips are ignored); when a.action is empty, any action or clip matches.
@(private)
span_advance :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,at_local:i64) {
    if t.w.anim_events.ptr==nil || len(t.w.anim_events.items)==0 {return}
    row:=record_row(t.abilities,u.state.ability)
    if row<0 || row>=len(t.sheets.ability_spans) {return}
    cached:=&t.sheets.ability_spans[row]
    if !cached.any {return}
    spans:=u.local.span_open
    for ev in t.w.anim_events.items {
        if ev.entity!=u.animated || (ev.kind!=.Span_Begin && ev.kind!=.Span_End) {continue}
        if cached.action!=0 && ev.action!=cached.action {continue}
        for hash,i in cached.windows {
            if hash==0 || hash!=ev.name {continue}
            bit:=u16(1)<<u16(i)
            if ev.kind==.Span_Begin {
                if spans&bit==0 {
                    local_edit(t,u).span_start[i]=u32(clamp(at_local,0,i64(max(u32))))
                }
                spans|=bit
            } else {
                spans&=~bit
            }
        }
    }
    if spans!=u.local.span_open {local_edit(t,u).span_open=spans}
}

// The windows that open or close at at, against before (the tick before).
@(private)
windows_advance :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,before,at:Ability_Time,replica:=false) {
    row:=record_row(t.abilities,u.state.ability)
    for &w,i in a.windows {
        was,is:=ability_window_open(w,t.dt,before,i),ability_window_open(w,t.dt,at,i)
        if is && !was {
            event_push(t,{kind=.Window_Begin,entity=e,ability=u.state.ability,window=i8(i),cue=w.cue})
            if row>=0 && row<len(t.sheets.ability_spans) {window_cue(t,e,u,&w,t.sheets.ability_spans[row].channels[i])}
            if !replica && w.move.velocity!={} {
                velocity:=w.move.velocity
                if pose,found:=core.get(t.w.worlds,u.driver);found {velocity=mm.quat_rotate(pose.rotation,velocity)}
                ticks:u32
                if w.span[0]!=0 {
                    // Span-bound moves last until .Span_End or ability_end removes them.
                    ticks=u32(max(ability_ticks(a,t.dt)-at.local,1))
                } else {
                    from,to:=window_ticks(w,t.dt)
                    ticks=u32(to-from)
                    // On the Own clock it lasts until the window closes, which removes it.
                    if w.clock==.Own {ticks=u32(math.ceil(f32(to-from)/max(pace_tick(t,u.animated),1.0/64)))}
                }
                locomotion.add_move(t.w.moves,u.driver,{velocity=velocity,ticks=ticks,mix=w.move.mix,id=MOVE_ID+u32(i)})
            }
        }
        if was && !is {
            event_push(t,{kind=.Window_End,entity=e,ability=u.state.ability,window=i8(i),cue=w.cue})
            if !replica && (w.clock==.Own || w.span[0]!=0) && w.move.velocity!={} {locomotion.remove_moves(t.w.moves,u.driver,MOVE_ID+u32(i))}
        }
    }
}

// The effect hitbox h applies to a target carrying target_tags: the first target_effects entry
// whose target_tags share a bit with target_tags, else the hitbox's default effect (if its
// target_tags are zero or match), else empty.
hitbox_effect_for :: proc "contextless" (h:^Ability_Hitbox,target_tags:scene.Tags) -> Ability_Effect {
    at:=hitbox_effect_at(h,target_tags)
    return {} if at<0 else h.effect if at==0 else h.target_effects[at-1]
}

// Of the effects of h, the one hitbox_effect_for picks: 0 for its effect, 1 and on for its
// target_effects; -1 for none.
@(private)
hitbox_effect_at :: proc "contextless" (h:^Ability_Hitbox,target_tags:scene.Tags) -> int {
    if h==nil {return -1}
    for te,i in h.target_effects {
        if te.target_tags.bits!=0 && scene.tag_has_any(target_tags,te.target_tags) {return 1+i}
    }
    if h.effect.target_tags.bits!=0 && !scene.tag_has_any(target_tags,h.effect.target_tags) {return -1}
    return 0
}

// Each open hitbox touches each entity once: a Hit and the effect of the window, on the tick after.
// One open on the tick before (before) also touches what it passed through since: it is tested at
// poses between where the user was then (World_Transform.previous, which a teleport moves with it,
// core.Jumps) and where it is, so a dash or a swing faster than the hitbox is long hits what it
// crossed. The tick a window opens it is tested only where the user is.
@(private)
hitboxes :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,before,at:Ability_Time) {
    placed,found:=core.get(t.w.worlds,e)
    if !found {placed.rotation,placed.previous.rotation=1,1}
    for &w,i in a.windows {
        if w.hitbox=={} || !ability_window_open(w,t.dt,at,i) || t.overlap==nil {continue}
        hrow:=record_row(t.hitboxes,w.hitbox)
        h:=record_at(t.hitboxes,hrow)
        if h==nil || hrow>=len(t.sheets.hit_channels) || h.shape==.Ray || h.shape==.Self {continue}
        steps:=hitbox_steps(h,placed.previous,placed.transform) if ability_window_open(w,t.dt,before,i) else 1
        for step in 1..=steps {
            pose:=placed.transform
            if step<steps {pose=mm.transform_interpolate(placed.previous,placed.transform,f32(step)/f32(steps))}
            results:[HITBOX_RESULTS]core.Entity
            count:=clamp(t.overlap(t.w,h,pose,results[:]),0,HITBOX_RESULTS)
            each: for target in results[:count] {
                if target==e || target==u.driver || target==core.NONE {continue}
                for j in 0..<min(int(u.local.hit_count),USER_HITS) {
                    if u.local.targets[j]==target && int(u.local.windows[j])==i {continue each}
                }
                if int(u.local.hit_count)>=USER_HITS {
                    core.report(t.w.problems,e,"abilities.hits","the ability %s touched more than %d entities: smaller hitboxes, or fewer windows with hitboxes",core.record_name(t.abilities,u.state.ability),USER_HITS)
                    return
                }
                l:=local_edit(t,u)
                l.targets[l.hit_count],l.windows[l.hit_count]=target,u8(i)
                l.hit_count+=1
                event_push(t,{kind=.Hit,entity=e,ability=u.state.ability,window=i8(i),zone=-1,cue=w.cue,target=target})
                target_tags:scene.Tags
                if t.w.tags!=nil {target_tags,_=core.get(t.w.tags,target)}
                if at:=hitbox_effect_at(h,target_tags);at>=0 {
                    effect:=h.effect if at==0 else h.target_effects[at-1]
                    cue_emit(t,effect.on_hit,t.sheets.hit_channels[hrow][at],target,e,hit_point(t.w,h,pose,target))
                    if effect!={} {ability_effect(t.requests,target,effect,e)}
                }
            }
        }
    }
}

// Where a hitbox of a user placed at pose is in the world: its center and its axes, those of the
// user. Its extents are its size.
hitbox_world :: proc "contextless" (hitbox:^Ability_Hitbox,pose:mm.Transform) -> (center:mm.Vec3,rotation:mm.Quat) {
    return pose.position+mm.quat_rotate(pose.rotation,hitbox.center),pose.rotation
}

// How many poses between from and to test a hitbox so that two in a row are at most its smallest
// half extent apart, along what its farthest point travels (moving and turning): 1 to HITBOX_STEPS.
hitbox_steps :: proc "contextless" (h:^Ability_Hitbox,from,to:mm.Transform) -> int {
    least,reach:f32
    switch h.shape {
    case .None,.Ray,.Self: return 1
    case .Box: least,reach=min(h.size.x,h.size.y,h.size.z),linalg.length(h.size)
    case .Sphere: least,reach=h.size.x,h.size.x
    case .Capsule: least,reach=h.size.x,h.size.x+h.size.y
    }
    travel:=linalg.length(to.position-from.position)+mm.quat_angle(from.rotation,to.rotation)*(linalg.length(h.center)+reach)
    steps:=travel/max(least,HITBOX_STEP_MIN)
    if !(steps>1) {return 1}
    if !(steps<HITBOX_STEPS) {return HITBOX_STEPS}
    return int(math.ceil(steps))
}

// Weight in 0..1 of a modifier with optional ramp_in (from start) and ramp_out (before end).
// remaining < 0 means the end time is unknown (a clip-span-bound window): only ramp_in applies.
@(private)
modifier_weight :: proc "contextless" (m:Ability_Modifier,elapsed,remaining:f32) -> f32 {
    weight:=f32(1)
    if m.ramp_in>0 {weight=min(weight,clamp(elapsed/m.ramp_in,0,1))}
    if m.ramp_out>0 && remaining>=0 {weight=min(weight,clamp(remaining/m.ramp_out,0,1))}
    return weight
}

// The statuses and current values of a user: those of its timers and of the windows open at at.
@(private)
derive :: proc(t:^Tick,e:core.Entity,u:^Actor,active:^Ability,at:Ability_Time,replica:=false) {
    statuses:Ability_Statuses
    add,more:[ATTRIBUTE_ENTRIES]f32
    modify :: proc(u:^Ability_User,m:Ability_Modifier,weight:f32,add,more:^[ATTRIBUTE_ENTRIES]f32) {
        if m.attribute==ATTRIBUTE_NONE || weight==0 {return}
        for entry,i in u.attributes {
            if entry.attribute==m.attribute {add[i]+=m.add*weight;more[i]+=m.more*weight}
        }
    }
    for &timer in u.track.timers {
        if timer.until==0 {continue}
        statuses|=timer.statuses
        m:=timer.modify
        stacks:=f32(max(timer.stacks,1))
        m.add*=stacks;m.more*=stacks
        elapsed:=f32(t.tick-timer.start)*t.dt if t.tick>=timer.start else 0
        remaining:=f32(timer.until-t.tick)*t.dt if timer.until>=t.tick else 0
        modify(u.user,m,modifier_weight(m,elapsed,remaining),&add,&more)
    }
    if active!=nil {
        for &w,i in active.windows {
            if !ability_window_open(w,t.dt,at,i) {continue}
            statuses|=w.statuses
            if w.modify.attribute!=ATTRIBUTE_NONE {
                elapsed,remaining:f32
                if w.span[0]!=0 {
                    elapsed=max(f32(at.local-i64(u.local.span_start[i]))*t.dt,0)
                    remaining=-1
                } else {
                    now_s:=at.own*t.dt if w.clock==.Own else f32(at.local)*t.dt
                    elapsed=max(now_s-w.from,0)
                    remaining=max(w.to-now_s,0)
                }
                modify(u.user,w.modify,modifier_weight(w.modify,elapsed,remaining),&add,&more)
            }
        }
    }
    values:[ATTRIBUTE_ENTRIES]f32
    for entry,i in u.user.attributes {
        if entry.attribute!=ATTRIBUTE_NONE {
            values[i]=max((ability_base(u.user,u.state,i,t.tick,t.dt)+add[i])*max(1+more[i],0),0)
        }
    }
    if u.local.statuses==statuses && u.local.values==values {return}
    // The speed, jump and acceleration scales of its locomotion follow their attributes when changed.
    if !replica && t.w.moves!=nil && core.has(t.w.characters,e) {
        for entry,i in u.user.attributes {
            if entry.attribute==ATTRIBUTE_NONE {continue}
            if entry.attribute==u.user.speed {
                scale:=min(values[i],locomotion.SPEED_SCALE_MAX)
                if scale!=u.local.values[i] {locomotion.set_speed_scale(t.w.moves,e,scale)}
            }
            if entry.attribute==u.user.jump {
                scale:=min(values[i],locomotion.JUMP_SCALE_MAX)
                if scale!=u.local.values[i] {locomotion.set_jump_scale(t.w.moves,e,scale)}
            }
            if entry.attribute==u.user.acceleration {
                scale:=min(values[i],locomotion.ACCELERATION_SCALE_MAX)
                if scale!=u.local.values[i] {locomotion.set_acceleration_scale(t.w.moves,e,scale)}
            }
        }
    }
    l:=local_edit(t,u)
    l.statuses,l.values=statuses,values
}

@(private)
event_push :: proc(t:^Tick,event:Ability_Event) {
    if t.events==nil {return}
    if t.event_count>=EVENT_CAPACITY || len(t.events.queue.items)>=cap(t.events.queue.items) {
        core.report(t.w.problems,core.NONE,"abilities.events","ability event capacity reached: remaining events were dropped")
        return
    }
    t.event_count+=1
    event:=event
    if event.kind!=.Hit && event.kind!=.Shot {event.zone=-1}
    core.push(&t.events.queue,event)
}

// Plays cue where entity is (where fallback is when entity is not placed), by entity.
@(private)
cue_emit :: proc(t:^Tick,cue:audio.Cue,channel:core.Birth_Channel,entity:core.Entity,fallback:=core.NONE,point:Maybe(mm.Transform)=nil) {
    if cue.sound=={} && channel==0 {return}
    at:=point
    if at==nil {
        pose,placed:=core.get(t.w.worlds,entity)
        if !placed && fallback!=core.NONE {pose,placed=core.get(t.w.worlds,fallback)}
        if placed {at=pose.transform}
    }
    audio.cue_play(t.w.sounds,t.w.births,cue,channel,at,entity)
}

// Where a hitbox at pose meets a target it overlaps: the point of the box of the target's body
// nearest the hitbox's centre, turned as the hitbox. Nil without a body, where the target's own
// place stands in.
hit_point :: proc(w:^Ability_World,h:^Ability_Hitbox,pose:mm.Transform,target:core.Entity) -> Maybe(mm.Transform) {
    bounds,ok:=phys.body_bounds(w.physics,target)
    if !ok {return nil}
    center,rotation:=hitbox_world(h,pose)
    return mm.Transform{position=linalg.clamp(center,bounds.min,bounds.max),rotation=rotation,scale=1}
}
