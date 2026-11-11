package ai

import "base:intrinsics"
import math "mirai:std/math"

// How an agent decides. Every tick a think procedure of the game proposes the
// actions it can take now with their scores, and the highest wins; the
// running one gets a margin (`keep`) and can commit to a score until it exits,
// so near scores do not oscillate and a reaction scored higher interrupts it.
// An action not proposed and not committed is interrupted. An action is a
// procedure of the game for one value of its enum, called with Enter, Update
// and Exit; every Enter has one Exit with its cause, where it releases what it
// asked for, and the mind releases its reservation (an attack token, a smart
// object) itself. An action can run other actions of the same mind as steps,
// one after the other. The mind is plain data with the same layout for every
// enum: it is copied with the world, and behavior inspects and presents it.

MIND_WORDS :: #config(MIRAI_MIND_WORDS,4)      // memory of an action, zero on Enter
MIND_ACTIONS :: #config(MIRAI_MIND_ACTIONS,16) // values of the enum of actions: from 0 to below this
MIND_TRACE :: 4                                // exits a mind remembers
MIND_PROPOSALS :: 4                            // best proposals of its last decision it remembers
MIND_NONE :: u16(0xFFFF)

#assert(MIND_ACTIONS>0 && MIND_ACTIONS<=32)

Status :: enum u8 {Running,Success,Failure}
Phase :: enum u8 {Enter,Update,Exit}
Exit_Cause :: enum u8 {Success,Failure,Aborted}

exit_cause :: #force_inline proc "contextless" (r:Status) -> Exit_Cause {return .Success if r==.Success else .Failure}

// What a frame holds of the Reservations: the target and which of its
// reservations (the game's id: 0 for an attack token).
Reservation_Key :: struct {target:u64,what:u16}

// What runs at one level: the action of the mind, or a step of it.
Act_Frame :: struct {
    action:u16,         // the action plus one; 0 when nothing runs
    stage:u16,          // the stage of the action, or the step it runs
    entered,staged:u64, // the ticks the action and its stage started at
    reserved:Reservation_Key, // what it holds until it exits; target 0 for nothing
    memory:[MIND_WORDS]u64,
}

Mind_Exit :: struct {
    action:u16,
    by:u16, // the action that interrupted it, MIND_NONE when none did
    cause:Exit_Cause,
    step:bool,
}

Mind_Proposal :: struct {action:u16,score:f32}

Mind :: struct {
    main,step:Act_Frame,
    ended:[MIND_ACTIONS]u64, // the tick each action last exited at
    exited:u32,              // bit a: the action a has exited once
    commit:f32,              // the running action counts at least this until it exits; 0 for none
    score:f32,               // what it counted on the last tick
    ticks:u32,
    exits_seen:u32,
    exits:[MIND_TRACE]Mind_Exit,
    proposals:[MIND_PROPOSALS]Mind_Proposal, // of the last decision, best first; score 0 past the last
}

// The proposals of one decision: the game's think procedure calls `propose`
// for what it can do now. Only the best are kept, so it does not allocate.
Think :: struct($A:typeid) {
    using ctx:^Mind_Context,
    mind:^Mind,
    best:int,       // the best proposal but the running action and the excluded one, or -1
    score:f32,
    standing:f32,   // what the running action was proposed with
    running,excluded:int,
    top:[MIND_PROPOSALS]Mind_Proposal,
}

// Proposes an action with its score; a score of 0 or less does not propose it.
// The first of equal scores wins.
propose :: proc "contextless" (t:^Think($A),action:A,score:f32) {
    a:=int(action)
    if !(score>0) || score>max(f32) || !mind_valid(A,a) {return}
    if a==t.running {
        if score>t.standing {t.standing=score}
    } else if a!=t.excluded && score>t.score {
        t.best,t.score=a,score
    }
    // Into the trace, best first.
    for k in 0..<MIND_PROPOSALS {
        if score>t.top[k].score {
            for j:=MIND_PROPOSALS-1;j>k;j-=1 {t.top[j]=t.top[j-1]}
            t.top[k]={u16(a),score}
            break
        }
    }
}

// What the game hands a tick.
Mind_Context :: struct {
    user:rawptr,
    tick:u64,     // the tick: the mind counts its waits and the leases of reservations in ticks
    dt:f32,       // seconds of a tick
    keep:f32,     // the margin of the running action over the others
    holder:u64,   // the agent, as the holder of reservations
    reservations:^Reservations,
    lease:u32,    // ticks a reservation lasts after its holder last ran; 0 is 1
}

// One call of an action.
Act :: struct($A:typeid) {
    using ctx:^Mind_Context,
    mind:^Mind,
    acts:^[A]proc(a:^Act(A)) -> Status,
    frame:^Act_Frame,
    action:A,
    phase:Phase,
    cause:Exit_Cause, // on Exit
    memory:[]u64,
}

// Decides and runs one tick. `think` proposes; the running action keeps its
// place while nothing scores above what it counts (its proposal plus `keep`,
// or its commit), and is interrupted when something does or when it is neither
// proposed nor committed. An action that ends asks `think` again in the same
// tick, over what it changed, and the best enters; it can be itself unless it
// failed. Returns what runs after the tick.
mind_tick :: proc(m:^Mind,acts:^[$A]$P,think:proc(t:^Think(A)),ctx:^Mind_Context) -> (doing:A,running:bool) {
    #assert(intrinsics.type_is_enum(A) && int(min(A))>=0 && int(max(A))<MIND_ACTIONS)
    #assert(P==proc(a:^Act(A)) -> Status)
    if m==nil || acts==nil || think==nil || ctx==nil {return}
    m.ticks+=1
    if ctx.reservations!=nil {
        lease:=u64(max(ctx.lease,1))
        if m.main.reserved.target!=0 {reserve_renew(ctx.reservations,m.main.reserved,ctx.holder,ctx.tick,lease)}
        if m.step.reserved.target!=0 {reserve_renew(ctx.reservations,m.step.reserved,ctx.holder,ctx.tick,lease)}
    }
    current:=int(m.main.action)-1
    if current>=0 && !mind_valid(A,current) {current=-1;m.main={}}
    if m.step.action!=0 && (current<0 || !mind_valid(A,int(m.step.action)-1)) {m.step={}}
    t:=Think(A){ctx=ctx,mind=m,best=-1,running=current,excluded=-1}
    think(&t)
    m.proposals=t.top
    if current>=0 {
        standing:f32
        if t.standing>0 {standing=t.standing+(ctx.keep if ctx.keep>0 && ctx.keep<=max(f32) else 0)}
        if m.commit>standing {standing=m.commit}
        if standing>0 && !(t.score>standing) {
            m.score=standing
            r:=act_call(m,acts,ctx,&m.main,.Update,.Success)
            if r==.Running {return A(current),true}
            mind_exit(m,acts,ctx,exit_cause(r),MIND_NONE)
            t=Think(A){ctx=ctx,mind=m,best=-1,running=-1,excluded=current if r==.Failure else -1}
            think(&t)
            m.proposals=t.top
        } else {
            mind_exit(m,acts,ctx,.Aborted,u16(t.best) if t.best>=0 else MIND_NONE)
        }
    }
    if t.best<0 {return}
    m.score=t.score
    if act_enter(m,acts,ctx,&m.main,t.best)==.Running {return A(t.best),true}
    return
}

// Exits what runs with Aborted, the step first.
mind_stop :: proc(m:^Mind,acts:^[$A]$P,ctx:^Mind_Context) {
    if m==nil || acts==nil || ctx==nil || m.main.action==0 {return}
    mind_exit(m,acts,ctx,.Aborted,MIND_NONE)
}

// What runs: the action and the step it runs, MIND_NONE for none. The same
// for any enum: what behavior presents.
mind_running :: proc "contextless" (m:^Mind) -> (action,step:u16) {
    action,step=MIND_NONE,MIND_NONE
    if m.main.action!=0 && int(m.main.action)<=MIND_ACTIONS {action=m.main.action-1}
    if action!=MIND_NONE && m.step.action!=0 && int(m.step.action)<=MIND_ACTIONS {step=m.step.action-1}
    return
}

// What runs, as values of the enum.
mind_doing :: proc "contextless" (m:^Mind,$A:typeid) -> (action:A,step:A,running,stepping:bool) {
    main,inner:=mind_running(m)
    if main!=MIND_NONE && mind_valid(A,int(main)) {action,running=A(main),true}
    if running && inner!=MIND_NONE && mind_valid(A,int(inner)) {step,stepping=A(inner),true}
    return
}

// Seconds since the action last exited, at the tick `tick` of `dt` seconds, or +inf if it never ran.
mind_since :: proc "contextless" (m:^Mind,action:$A,tick:u64,dt:f32) -> f64 {
    a:=int(action)
    if !mind_valid(A,a) || m.exited&(1<<uint(a))==0 {return 0h7FF0000000000000}
    return seconds_since(tick,m.ended[a],dt)
}

// Whether `cooldown` seconds passed since the action last exited.
mind_ready :: proc "contextless" (m:^Mind,action:$A,tick:u64,dt:f32,cooldown:f64) -> bool {
    a:=int(action)
    if !mind_valid(A,a) || m.exited&(1<<uint(a))==0 {return true}
    return waited(tick,m.ended[a],dt,cooldown)
}

@(private)
seconds_since :: #force_inline proc "contextless" (tick,since:u64,dt:f32) -> f64 {
    return f64(tick-since)*f64(dt) if tick>since && dt>0 else 0
}

// Whether `seconds` passed from the tick `since` to `tick`: counted in ticks,
// so it lasts the same at any tick rate. Never while the clock does not advance.
@(private)
waited :: #force_inline proc "contextless" (tick,since:u64,dt:f32,seconds:f64) -> bool {
    return dt>0 && tick>=since && tick-since>=math.ticks_of(seconds,dt)
}

// The last exits, the latest first: back 0 is the latest.
mind_exit_trace :: proc "contextless" (m:^Mind,back:int) -> (exit:Mind_Exit,ok:bool) {
    seen:=int(min(m.exits_seen,MIND_TRACE))
    if back<0 || back>=seen {return}
    return m.exits[(int(m.exits_seen)-1-back)%MIND_TRACE],true
}

entering :: #force_inline proc "contextless" (a:^Act($A)) -> bool {return a.phase==.Enter}

// Seconds since the action (or the step) entered, and since its stage started.
elapsed :: #force_inline proc "contextless" (a:^Act($A)) -> f64 {return seconds_since(a.tick,a.frame.entered,a.dt)}
stage_elapsed :: #force_inline proc "contextless" (a:^Act($A)) -> f64 {return seconds_since(a.tick,a.frame.staged,a.dt)}

// Success once the action has run `seconds`.
after :: #force_inline proc "contextless" (a:^Act($A),seconds:f64) -> Status {
    return .Success if waited(a.tick,a.frame.entered,a.dt,seconds) else .Running
}

stage :: #force_inline proc "contextless" (a:^Act($A)) -> int {return int(a.frame.stage)}

// Goes to the next stage now; returns Running.
next_stage :: proc "contextless" (a:^Act($A)) -> Status {
    a.frame.stage+=1
    a.frame.staged=a.tick
    return .Running
}

// The action counts `score` until it exits, proposed or not: what scores
// less does not interrupt it.
commit :: proc "contextless" (a:^Act($A),score:f32) {
    if score>0 && score<=max(f32) {a.mind.commit=score} else {a.mind.commit=0}
}

// Runs the actions of `list` as steps, one after the other, the next in the
// same tick as the one before succeeds: Success after the last, Failure at the
// first that fails. A step cannot run steps. The list is the same on every
// tick; a different action at the current stage is interrupted for the new one.
steps :: proc(a:^Act($A),list:..A) -> Status {
    if a.frame!=&a.mind.main || a.phase==.Exit {return .Failure}
    m:=a.mind
    for _ in 0..=len(list) {
        i:=int(a.frame.stage)
        if i>=len(list) {return .Success}
        r:Status
        if m.step.action!=0 && int(m.step.action)-1!=int(list[i]) {step_exit(a,.Aborted)}
        if m.step.action==0 {
            r=act_enter(m,a.acts,a.ctx,&m.step,int(list[i]))
        } else {
            r=act_call(m,a.acts,a.ctx,&m.step,.Update,.Success)
            if r!=.Running {step_exit(a,exit_cause(r))}
        }
        if r!=.Success {return r}
        next_stage(a)
    }
    return .Running
}

// Takes one of the `limit` attack tokens of `target` for the action (or step)
// that asks, which holds it until it exits: false when `limit` others hold one.
token_take :: proc(a:^Act($A),target:u64,limit:int) -> bool {return claim(a,target,0,limit)}

// Claims `what` of `target` (an offer of a smart object, the game's id) for
// the action (or step) that asks, one of `limit` holders at once, until it
// exits: false when `limit` others hold it and none can be displaced. A claim
// of a higher `priority` displaces the lowest one not in use (claim_use),
// whose holder then finds it no longer holds it. A frame holds one
// reservation: a new one releases the one it held.
claim :: proc(a:^Act($A),target:u64,what:u16,limit:int,priority:u8=0) -> bool {
    if a.reservations==nil || target==0 {return false}
    key:=Reservation_Key{target,what}
    lease:=u64(max(a.lease,1))
    if a.frame.reserved==key {return reserve_take(a.reservations,key,a.holder,limit,a.tick,lease,priority)}
    if !reserve_take(a.reservations,key,a.holder,limit,a.tick,lease,priority) {return false}
    if a.frame.reserved.target!=0 {reserve_release(a.reservations,a.frame.reserved,a.holder)}
    a.frame.reserved=key
    return true
}

// What the frame claimed is in use from now on: no claim displaces it until it is released.
claim_use :: proc "contextless" (a:^Act($A)) {
    if a.frame.reserved.target!=0 {reserve_use(a.reservations,a.frame.reserved,a.holder)}
}

// Whether the frame still holds what it claimed: false once a claim of a higher priority took it.
claim_held :: proc "contextless" (a:^Act($A)) -> bool {
    return reserve_holds(a.reservations,a.frame.reserved,a.holder,a.tick)
}

@(private)
mind_valid :: #force_inline proc "contextless" ($A:typeid,action:int) -> bool {
    return action>=0 && action<MIND_ACTIONS && action>=int(min(A)) && action<=int(max(A))
}

@(private)
act_call :: proc(m:^Mind,acts:^[$A]$P,ctx:^Mind_Context,frame:^Act_Frame,phase:Phase,cause:Exit_Cause) -> Status {
    if !mind_valid(A,int(frame.action)-1) {return .Failure}
    action:=A(frame.action-1)
    procedure:=acts[action]
    if procedure==nil {return .Failure}
    a:=Act(A){ctx=ctx,mind=m,acts=acts,frame=frame,action=action,phase=phase,cause=cause,memory=frame.memory[:]}
    r:=procedure(&a)
    return r if r==.Running || r==.Success else .Failure
}

@(private)
act_enter :: proc(m:^Mind,acts:^[$A]$P,ctx:^Mind_Context,frame:^Act_Frame,action:int) -> Status {
    frame^={action=u16(action+1),entered=ctx.tick,staged=ctx.tick}
    r:=act_call(m,acts,ctx,frame,.Enter,.Success)
    if r!=.Running {
        if frame==&m.main {mind_exit(m,acts,ctx,exit_cause(r),MIND_NONE)} else {frame_exit(m,acts,ctx,frame,exit_cause(r),MIND_NONE)}
    }
    return r
}

@(private)
frame_exit :: proc(m:^Mind,acts:^[$A]$P,ctx:^Mind_Context,frame:^Act_Frame,cause:Exit_Cause,by:u16) {
    if frame.action==0 {return}
    if !mind_valid(A,int(frame.action)-1) {frame^={};return}
    action:=int(frame.action)-1
    act_call(m,acts,ctx,frame,.Exit,cause)
    if frame.reserved.target!=0 && ctx.reservations!=nil {reserve_release(ctx.reservations,frame.reserved,ctx.holder)}
    m.ended[action]=ctx.tick
    m.exited|=1<<uint(action)
    m.exits[m.exits_seen%MIND_TRACE]={action=u16(action),by=by,cause=cause,step=frame==&m.step}
    m.exits_seen+=1
    frame^={}
}

@(private)
step_exit :: #force_inline proc(a:^Act($A),cause:Exit_Cause) {frame_exit(a.mind,a.acts,a.ctx,&a.mind.step,cause,MIND_NONE)}

@(private)
mind_exit :: proc(m:^Mind,acts:^[$A]$P,ctx:^Mind_Context,cause:Exit_Cause,by:u16) {
    frame_exit(m,acts,ctx,&m.step,.Aborted,by)
    frame_exit(m,acts,ctx,&m.main,cause,by)
    m.commit=0
}

// Reservations: how many agents hold a target at once, for an attack token
// or an offer of a smart object. A holder renews its lease on every tick its
// mind runs; one that stops (destroyed, or its mind no longer ticks) loses it
// `lease` ticks after its last renewal. A holder of a lower priority that does
// not use it yet gives its place to a taker of a higher one; one that uses it
// keeps it. Plain data, shared by the agents a function ticks.

RESERVATION_TARGETS :: #config(MIRAI_RESERVATION_TARGETS,128)
RESERVATION_HOLDERS :: #config(MIRAI_RESERVATION_HOLDERS,4)

Reservation_Slot :: struct {
    key:Reservation_Key,
    holders:[RESERVATION_HOLDERS]u64,
    until:[RESERVATION_HOLDERS]u64, // the last tick of each lease
    priority:[RESERVATION_HOLDERS]u8,
    used:[RESERVATION_HOLDERS]bool, // in use: no taker displaces it
}
Reservations :: struct {
    slots:[RESERVATION_TARGETS]Reservation_Slot,
    failed:u32, // takes without a slot for the key or a place for the holder
}

@(private="file")
reserve_live :: #force_inline proc "contextless" (s:^Reservation_Slot,k:int,tick:u64) -> bool {
    return s.holders[k]!=0 && s.until[k]>=tick
}

@(private="file")
reserve_slot :: proc "contextless" (r:^Reservations,key:Reservation_Key) -> ^Reservation_Slot {
    for &s in r.slots {if s.key==key {return &s}}
    return nil
}

// The holder a taker at `priority` displaces: of the live ones below it and
// not in use, the lowest, the first of equals; -1 for none.
@(private="file")
reserve_displaced :: proc "contextless" (s:^Reservation_Slot,tick:u64,priority:u8) -> int {
    found:=-1
    for k in 0..<RESERVATION_HOLDERS {
        if !reserve_live(s,k,tick) || s.used[k] || s.priority[k]>=priority {continue}
        if found<0 || s.priority[k]<s.priority[found] {found=k}
    }
    return found
}

// Holders of `key` whose lease is live.
reserve_count :: proc "contextless" (r:^Reservations,key:Reservation_Key,tick:u64) -> int {
    if r==nil || key.target==0 {return 0}
    s:=reserve_slot(r,key)
    if s==nil {return 0}
    count:=0
    for k in 0..<RESERVATION_HOLDERS {if reserve_live(s,k,tick) {count+=1}}
    return count
}

// Whether the agent that thinks holds the token of subject or could take it,
// as one of limit: what a think proposes an attack on (ai.token_take takes it).
reserve_free :: proc{reserve_free_subject,reserve_free_key}

reserve_free_subject :: proc "contextless" (t:^Think($A),subject:$T,limit:int) -> bool where intrinsics.type_is_integer(T) {
    return reserve_open(t.reservations,{u64(subject),0},t.holder,limit,t.tick)
}

reserve_free_key :: proc "contextless" (t:^Think($A),key:Reservation_Key,limit:int) -> bool {
    return reserve_open(t.reservations,key,t.holder,limit,t.tick)
}

// Whether `holder` holds `key` or could take it as one of `limit` at `priority`.
reserve_open :: proc "contextless" (r:^Reservations,key:Reservation_Key,holder:u64,limit:int,tick:u64,priority:u8=0) -> bool {
    if r==nil || key.target==0 || holder==0 || limit<=0 {return false}
    s:=reserve_slot(r,key)
    if s==nil {return true}
    count:=0
    for k in 0..<RESERVATION_HOLDERS {
        if !reserve_live(s,k,tick) {continue}
        if s.holders[k]==holder {return true}
        count+=1
    }
    return count<limit && count<RESERVATION_HOLDERS || reserve_displaced(s,tick,priority)>=0
}

// Whether `holder` holds `key` now.
reserve_holds :: proc "contextless" (r:^Reservations,key:Reservation_Key,holder:u64,tick:u64) -> bool {
    if r==nil || key.target==0 || holder==0 {return false}
    s:=reserve_slot(r,key)
    if s==nil {return false}
    for k in 0..<RESERVATION_HOLDERS {if s.holders[k]==holder && reserve_live(s,k,tick) {return true}}
    return false
}

// Takes `key` for `holder` as one of `limit` at `priority`, displacing a
// holder reserve_displaced names when there is no room; renews it when it
// holds it already.
reserve_take :: proc "contextless" (r:^Reservations,key:Reservation_Key,holder:u64,limit:int,tick:u64,lease:u64=1,priority:u8=0) -> bool {
    if r==nil || key.target==0 || holder==0 || limit<=0 {return false}
    s:=reserve_slot(r,key)
    if s==nil {
        for &free in r.slots {
            if free.key.target==0 {s=&free;break}
            live:=false
            for k in 0..<RESERVATION_HOLDERS {if reserve_live(&free,k,tick) {live=true}}
            if !live {free={};s=&free;break}
        }
        if s==nil {r.failed+=1;return false}
        s.key=key
    }
    count:=0
    place:=-1
    for k in 0..<RESERVATION_HOLDERS {
        if !reserve_live(s,k,tick) {s.holders[k]=0;if place<0 {place=k};continue}
        if s.holders[k]==holder {s.until[k]=tick+lease;return true}
        count+=1
    }
    if count>=limit || place<0 {
        unplaced:=count<limit
        if place=reserve_displaced(s,tick,priority);place<0 {
            if unplaced {r.failed+=1}
            return false
        }
    }
    s.holders[place],s.until[place],s.priority[place],s.used[place]=holder,tick+lease,priority,false
    return true
}

// What `holder` holds of `key` is in use: no taker displaces it.
reserve_use :: proc "contextless" (r:^Reservations,key:Reservation_Key,holder:u64) {
    if r==nil || key.target==0 || holder==0 {return}
    if s:=reserve_slot(r,key);s!=nil {
        for k in 0..<RESERVATION_HOLDERS {if s.holders[k]==holder {s.used[k]=true}}
    }
}

reserve_renew :: proc "contextless" (r:^Reservations,key:Reservation_Key,holder:u64,tick:u64,lease:u64=1) {
    if r==nil || key.target==0 {return}
    if s:=reserve_slot(r,key);s!=nil {
        for k in 0..<RESERVATION_HOLDERS {if s.holders[k]==holder && s.until[k]<tick+lease {s.until[k]=tick+lease}}
    }
}

reserve_release :: proc "contextless" (r:^Reservations,key:Reservation_Key,holder:u64) {
    if r==nil || key.target==0 {return}
    s:=reserve_slot(r,key)
    if s==nil {return}
    empty:=true
    for k in 0..<RESERVATION_HOLDERS {
        if s.holders[k]==holder {s.holders[k],s.used[k]=0,false}
        if s.holders[k]!=0 {empty=false}
    }
    if empty {s^={}}
}
