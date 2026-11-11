package ai

import "base:runtime"
import "core:testing"

// The zombie, the boss and a tactical bot of the demo as minds, over a
// simulated world that a script drives: the tests check what they decide, and
// tick by tick when it matters.

MIND_HZ :: 30

Alloc_Counter :: struct {calls:int}

counting_allocator :: proc(counter:^Alloc_Counter) -> runtime.Allocator {
    return {procedure=proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        if mode==.Query_Features || mode==.Query_Info {return nil,.Mode_Not_Implemented}
        (^Alloc_Counter)(data).calls+=1
        return nil,.Out_Of_Memory
    },data=counter}
}

Mind_Call :: struct {tick:u32,agent:u8,action:u16,phase:Phase,cause:Exit_Cause}
Mind_Log :: struct {
    calls:[1024]Mind_Call,
    count:int,
    tick:u32,
    agent:u8,
}

mind_log :: proc(log:^Mind_Log,action:int,phase:Phase,cause:Exit_Cause) {
    if phase==.Update || log.count>=len(log.calls) {return}
    log.calls[log.count]={log.tick,log.agent,u16(action),phase,cause if phase==.Exit else .Success}
    log.count+=1
}

// The entries of one agent: (tick, action) of every Enter, in order.
Mind_Enter :: struct {tick:u32,action:u16}
mind_enters :: proc(log:^Mind_Log,agent:u8,out:[]Mind_Enter) -> int {
    n:=0
    for c in log.calls[:log.count] {
        if c.agent==agent && c.phase==.Enter && n<len(out) {out[n]={c.tick,c.action};n+=1}
    }
    return n
}

// Every Enter has one Exit, and nothing is left running at the end.
mind_balanced :: proc(log:^Mind_Log) -> bool {
    open:[4][16]int
    for c in log.calls[:log.count] {
        switch c.phase {
        case .Enter: open[c.agent][c.action]+=1
        case .Exit: open[c.agent][c.action]-=1;if open[c.agent][c.action]<0 {return false}
        case .Update:
        }
    }
    for agent in open {for n in agent {if n!=0 {return false}}}
    return true
}

expect_enters :: proc(t:^testing.T,log:^Mind_Log,agent:u8,want:[]Mind_Enter,loc:=#caller_location) {
    got:[256]Mind_Enter
    n:=mind_enters(log,agent,got[:])
    testing.expectf(t,n==len(want),"%d entries, expected %d: %v",n,len(want),got[:n],loc=loc)
    for i in 0..<min(n,len(want)) {
        if got[i]!=want[i] {
            testing.expectf(t,false,"entry %d: %v, expected %v",i,got[i],want[i],loc=loc)
            return
        }
    }
}

// ---------------------------------------------------------------- the zombie

Zombie_World :: struct {
    using log:Mind_Log,
    time:f64,
    sees,near,lost:bool, // lost: its path to what it chases fails
    bites,nav:int,       // nav: requests to navigation not stopped
}

Zombie_Act :: enum u16 {Wander,Chase,Bite}

zombie_think :: proc(t:^Think(Zombie_Act)) {
    w:=(^Zombie_World)(t.user)
    propose(t,.Bite,1 if w.near else 0)
    propose(t,.Chase,0.5 if w.sees else 0)
    propose(t,.Wander,0.1)
}

// Walks a second, then waits a second and a half.
zombie_wander :: proc(a:^Act(Zombie_Act)) -> Status {
    w:=(^Zombie_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    switch a.phase {
    case .Enter: w.nav+=1
    case .Update:
        if stage(a)==0 {
            if elapsed(a)<1 {return .Running}
            w.nav-=1
            next_stage(a)
        }
        return .Success if stage_elapsed(a)>=1.5 else .Running
    case .Exit: if stage(a)==0 {w.nav-=1}
    }
    return .Running
}

zombie_chase :: proc(a:^Act(Zombie_Act)) -> Status {
    w:=(^Zombie_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    switch a.phase {
    case .Enter: w.nav+=1
    case .Update: if w.lost {return .Failure}
    case .Exit: w.nav-=1
    }
    return .Running
}

zombie_bite :: proc(a:^Act(Zombie_Act)) -> Status {
    w:=(^Zombie_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    if entering(a) {w.bites+=1}
    return after(a,0.8)
}

ZOMBIE_ACTS := [Zombie_Act]proc(a:^Act(Zombie_Act)) -> Status{.Wander=zombie_wander,.Chase=zombie_chase,.Bite=zombie_bite}

// Unseen for 2 s, seen, reached at 3 s, out of reach at 5 s, its path lost
// for a tick at 6 s and unseen from 7 s.
zombie_script :: proc(w:^Zombie_World,tick:int) {
    s:=f64(tick)/MIND_HZ
    w.time=s
    w.tick=u32(tick)
    w.sees=s>=2 && s<7
    w.near=s>=3 && s<5
    w.lost=tick==6*MIND_HZ
}

// It wanders, chases what it sees and bites again once 0.8 s passed while
// it is near (24 or 25 ticks, by the rounding of the seconds); a chase that fails wanders in the same tick and chases again on the
// next, and what stops being proposed stops at once.
@(test)
the_zombie_chases_bites_and_wanders :: proc(t:^testing.T) {
    w:Zombie_World
    mind:Mind
    ctx:=Mind_Context{user=&w,keep=0.05}
    for tick in 0..<9*MIND_HZ {
        zombie_script(&w,tick)
        ctx.time=w.time
        mind_tick(&mind,&ZOMBIE_ACTS,zombie_think,&ctx)
    }
    mind_stop(&mind,&ZOMBIE_ACTS,&ctx)
    W,C,B:=u16(Zombie_Act.Wander),u16(Zombie_Act.Chase),u16(Zombie_Act.Bite)
    expect_enters(t,&w,0,{{0,W},{60,C},{90,B},{115,B},{139,B},{150,C},{180,W},{181,C},{210,W}})
    testing.expect_value(t,w.bites,3)
    testing.expect_value(t,w.nav,0)
    testing.expect(t,mind_balanced(&w))
}

// ------------------------------------------------------------------ the boss

Boss_World :: struct {
    using log:Mind_Log,
    time:f64,
    health:i32, // percent
    near,stagger:bool,
    summoned:i32,
    attacks:[Boss_Act]int,
    nav:int,
}

Boss_Act :: enum u16 {Slam,Charge,Summon,Roar,Rage,Stunned,Dead}

// Attacks commit above every attack; the second phase, a stagger and death
// interrupt them.
BOSS_COMMITTED :: 2
BOSS_PHASE :: 3
BOSS_STUNNED :: 50
BOSS_DEAD :: 100

boss_think :: proc(t:^Think(Boss_Act)) {
    w:=(^Boss_World)(t.user)
    alive:=w.health>0
    first:=w.health>50
    near:=f32(1 if w.near else 0)
    propose(t,.Dead,BOSS_DEAD if !alive else 0)
    propose(t,.Stunned,BOSS_STUNNED if alive && w.stagger else 0)
    propose(t,.Rage,BOSS_PHASE if alive && !first else 0)
    if first {
        propose(t,.Slam,0.1+0.9*near)
        propose(t,.Charge,1-0.9*near)
        if mind_ready(t.mind,Boss_Act.Summon,t.time,6) {propose(t,.Summon,0.6*(1-f32(w.summoned)/3))}
    }
}

boss_attack :: proc(a:^Act(Boss_Act)) -> Status {
    w:=(^Boss_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    switch a.phase {
    case .Enter:
        w.attacks[a.action]+=1
        if a.action==.Summon {w.summoned+=1}
        if a.action==.Charge {w.nav+=1}
        commit(a,BOSS_COMMITTED)
    case .Update: return after(a,0.5 if a.action==.Charge else 1)
    case .Exit: if a.action==.Charge {w.nav-=1}
    }
    return .Running
}

// The combo of the second phase, chosen when it starts.
boss_rage :: proc(a:^Act(Boss_Act)) -> Status {
    w:=(^Boss_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    if a.phase==.Exit {return .Success}
    if entering(a) && w.near {a.memory[0]=1}
    if a.memory[0]==1 {return steps(a,.Slam,.Slam,.Roar)}
    return steps(a,.Charge,.Slam)
}

boss_stunned :: proc(a:^Act(Boss_Act)) -> Status {
    mind_log((^Boss_World)(a.user),int(a.action),a.phase,a.cause)
    if entering(a) {commit(a,BOSS_STUNNED)}
    return after(a,1.5)
}

boss_dead :: proc(a:^Act(Boss_Act)) -> Status {
    w:=(^Boss_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    if entering(a) {commit(a,BOSS_DEAD)}
    return .Success if w.health>0 else .Running
}

BOSS_ACTS := [Boss_Act]proc(a:^Act(Boss_Act)) -> Status{
    .Slam=boss_attack,.Charge=boss_attack,.Summon=boss_attack,.Roar=boss_attack,
    .Rage=boss_rage,.Stunned=boss_stunned,.Dead=boss_dead,
}

// Near; the hero steps away at 2.5 s and back at 3.6 s; a stagger at 4.2 s;
// half its health at 7 s, the hero away from 9 s to 10 s; it dies at 13 s and
// comes back at 15 s.
boss_script :: proc(w:^Boss_World,tick:int) {
    s:=f64(tick)/MIND_HZ
    w.time=s
    w.tick=u32(tick)
    w.near=!(s>=2.5 && s<3.6) && !(s>=9 && s<10)
    w.stagger=tick==int(4.2*MIND_HZ)
    w.health=100
    if s>=7 {w.health=40}
    if s>=13 && s<15 {w.health=0}
}

// An attack finishes even when another scores higher; a stagger, the second
// phase and death interrupt it in the tick they come; the second phase runs
// combos as steps, chosen by where the hero is when each starts.
@(test)
the_boss_commits_to_attacks_and_reacts_at_once :: proc(t:^testing.T) {
    w:Boss_World
    mind:Mind
    ctx:=Mind_Context{user=&w,keep=0.05}
    stunned_at,raged_at,dead_at,risen_at:=-1,-1,-1,-1
    for tick in 0..<18*MIND_HZ {
        boss_script(&w,tick)
        ctx.time=w.time
        action,_,running,_:=mind_doing(&mind,Boss_Act)
        doing,_:=mind_tick(&mind,&BOSS_ACTS,boss_think,&ctx)
        if doing==.Stunned && stunned_at<0 {stunned_at=tick}
        if doing==.Rage && raged_at<0 {raged_at=tick}
        if doing==.Dead && dead_at<0 {dead_at=tick}
        if running && action==.Dead && doing!=.Dead && risen_at<0 {risen_at=tick}
    }
    mind_stop(&mind,&BOSS_ACTS,&ctx)
    testing.expect_value(t,stunned_at,int(4.2*MIND_HZ))
    testing.expect_value(t,raged_at,7*MIND_HZ)
    testing.expect_value(t,dead_at,13*MIND_HZ)
    testing.expect_value(t,risen_at,15*MIND_HZ)
    // The hero away from 2.5 s: the slam that runs finishes, then a charge.
    got:[256]Mind_Enter
    n:=mind_enters(&w,0,got[:])
    first_charge:=-1
    for e in got[:n] {if e.action==u16(Boss_Act.Charge) {first_charge=int(e.tick);break}}
    testing.expect(t,first_charge>=int(2.5*MIND_HZ) && first_charge<=int(3.5*MIND_HZ))
    testing.expect_value(t,w.attacks[.Summon],0) // a slam or a charge always scores more
    testing.expect(t,w.attacks[.Roar]>=1 && w.attacks[.Slam]>w.attacks[.Charge])
    testing.expect(t,mind_balanced(&w))
    testing.expect_value(t,w.nav,0)
}

// ------------------------------------------------------------ a tactical bot

Bot :: struct {
    health,mag,reserve,medkits:i32,
    at_crate:bool,
    shots,nav,picked:int,
}
Bot_World :: struct {
    using log:Mind_Log,
    time:f64,
    tick64:u64,
    bots:[2]Bot,
    sees:bool,
    reservations:Reservations,
    most_holders,most_at_crate:int,
}

BOT_TARGET :: 77
BOT_CRATE :: 78 // a crate of ammo, one user at a time
BOT_CRATE_OFFER :: 1
Bot_Act :: enum u16 {Patrol,Fire,Reload,Take_Cover,Bandage,Go_To_Crate,Pick_Ammo,Heal,Get_Ammo}

bot_think :: proc(t:^Think(Bot_Act)) {
    w:=(^Bot_World)(t.user)
    bot:=&w.bots[w.agent]
    crate:=Reservation_Key{BOT_CRATE,BOT_CRATE_OFFER}
    if bot.health<30 && bot.medkits>0 {propose(t,.Heal,0.9)}
    if bot.mag==0 && bot.reserve>0 {propose(t,.Reload,0.8)}
    if bot.mag==0 && bot.reserve==0 && reserve_free(t,crate,1) {propose(t,.Get_Ammo,0.8)}
    if w.sees && bot.mag>0 && reserve_free(t,Reservation_Key{BOT_TARGET,0},1) {propose(t,.Fire,0.6)}
    propose(t,.Patrol,0.1)
}

bot_move :: proc(a:^Act(Bot_Act)) -> Status {
    w:=(^Bot_World)(a.user)
    bot:=&w.bots[w.agent]
    mind_log(w,int(a.action),a.phase,a.cause)
    switch a.phase {
    case .Enter: bot.nav+=1
    case .Update:
        if a.action==.Patrol || elapsed(a)<1 {return .Running}
        if a.action==.Go_To_Crate {bot.at_crate=true}
        return .Success
    case .Exit: bot.nav-=1
    }
    return .Running
}

bot_fire :: proc(a:^Act(Bot_Act)) -> Status {
    w:=(^Bot_World)(a.user)
    bot:=&w.bots[w.agent]
    mind_log(w,int(a.action),a.phase,a.cause)
    switch a.phase {
    case .Enter: if !token_take(a,BOT_TARGET,1) {return .Failure}
    case .Update:
        if stage_elapsed(a)<0.3 {return .Running}
        next_stage(a)
        bot.mag-=1
        bot.shots+=1
        if bot.mag==0 {return .Success}
    case .Exit:
    }
    return .Running
}

bot_timed :: proc(a:^Act(Bot_Act)) -> Status {
    w:=(^Bot_World)(a.user)
    bot:=&w.bots[w.agent]
    mind_log(w,int(a.action),a.phase,a.cause)
    if a.phase!=.Update {return .Running}
    #partial switch a.action {
    case .Reload:
        if elapsed(a)<1.5 {return .Running}
        n:=min(6,bot.reserve);bot.mag+=n;bot.reserve-=n
    case .Bandage:
        if elapsed(a)<2 {return .Running}
        bot.health=100;bot.medkits-=1
    case .Pick_Ammo:
        if elapsed(a)<0.5 {return .Running}
        bot.reserve+=12
        bot.picked+=1
    }
    return .Success
}

bot_heal :: proc(a:^Act(Bot_Act)) -> Status {
    mind_log((^Bot_World)(a.user),int(a.action),a.phase,a.cause)
    if a.phase==.Exit {return .Success}
    return steps(a,.Take_Cover,.Bandage)
}

// Reserves the crate for the whole errand: going to it and picking.
bot_get_ammo :: proc(a:^Act(Bot_Act)) -> Status {
    w:=(^Bot_World)(a.user)
    mind_log(w,int(a.action),a.phase,a.cause)
    switch a.phase {
    case .Enter: if !claim(a,BOT_CRATE,BOT_CRATE_OFFER,1) {return .Failure}
    case .Update:
    case .Exit:
        w.bots[w.agent].at_crate=false
        return .Success
    }
    return steps(a,.Go_To_Crate,.Pick_Ammo)
}

BOT_ACTS := [Bot_Act]proc(a:^Act(Bot_Act)) -> Status{
    .Patrol=bot_move,.Take_Cover=bot_move,.Go_To_Crate=bot_move,.Fire=bot_fire,
    .Reload=bot_timed,.Bandage=bot_timed,.Pick_Ammo=bot_timed,
    .Heal=bot_heal,.Get_Ammo=bot_get_ammo,
}

// Two bots see one target that one of them shoots at a time. The first is
// hurt at 1 s, while it shoots; the second runs out of rounds and fetches more
// from the crate; at 9 s the first runs out too and waits for the crate.
bot_script :: proc(w:^Bot_World,tick:int) {
    w.time=f64(tick)/MIND_HZ
    w.tick=u32(tick)
    w.tick64=u64(tick)
    w.sees=true
    if tick==0 {
        w.bots[0]={health=100,mag=6,reserve=6,medkits=1}
        w.bots[1]={health=100,mag=6,reserve=6}
    }
    if tick==MIND_HZ {w.bots[0].health=20}
}

bot_run :: proc(w:^Bot_World,minds:^[2]Mind,from,to:int,handover:^int=nil) {
    ctx:=Mind_Context{user=w,keep=0.05,reservations=&w.reservations}
    for tick in from..<to {
        bot_script(w,tick)
        for k in 0..<2 {
            w.agent=u8(k)
            ctx.time,ctx.tick,ctx.holder=w.time,w.tick64,u64(k)+1
            before:=w.count
            mind_tick(&minds[k],&BOT_ACTS,bot_think,&ctx)
            if handover==nil {continue}
            for c in w.calls[before:w.count] {
                if k==0 && c.action==u16(Bot_Act.Fire) && c.phase==.Exit && c.cause==.Aborted {handover^=tick}
                if k==1 && handover^==tick && c.action==u16(Bot_Act.Fire) && c.phase==.Enter {handover^=-2}
            }
        }
        w.most_holders=max(w.most_holders,reserve_count(&w.reservations,{BOT_TARGET,0},w.tick64))
        w.most_at_crate=max(w.most_at_crate,int(w.bots[0].at_crate)+int(w.bots[1].at_crate))
    }
}

@(test)
the_tactical_bot_shares_its_target_and_its_crate :: proc(t:^testing.T) {
    w:=new(Bot_World)
    defer free(w)
    minds:[2]Mind
    handover:=-1
    bot_run(w,&minds,0,20*MIND_HZ,&handover)
    ctx:=Mind_Context{user=w,reservations=&w.reservations,tick=w.tick64}
    for k in 0..<2 {
        w.agent=u8(k)
        ctx.holder=u64(k)+1
        mind_stop(&minds[k],&BOT_ACTS,&ctx)
    }
    testing.expect_value(t,handover,-2) // the token the first one releases, interrupted to heal, goes to the second in the same tick
    testing.expect_value(t,w.most_holders,1)
    testing.expect_value(t,w.most_at_crate,1)
    testing.expect_value(t,reserve_count(&w.reservations,{BOT_TARGET,0},w.tick64),0)
    testing.expect_value(t,reserve_count(&w.reservations,{BOT_CRATE,BOT_CRATE_OFFER},w.tick64),0)
    testing.expect(t,w.bots[0].picked>=1 && w.bots[1].picked>=1)
    testing.expect_value(t,w.bots[0].medkits,0)
    for k in 0..<2 {testing.expect_value(t,w.bots[k].nav,0)}
    testing.expect(t,mind_balanced(w))
    testing.expect(t,w.reservations.failed==0)
}

// Two actions whose scores swap on every tick: without a margin the mind
// changes on every tick, with one it keeps the first.
@(test)
near_scores_do_not_oscillate :: proc(t:^testing.T) {
    Flip :: enum u8 {Left,Right}
    think :: proc(t:^Think(Flip)) {
        odd:=t.tick%2==1
        propose(t,.Left,0.52 if odd else 0.5)
        propose(t,.Right,0.5 if odd else 0.52)
    }
    hold :: proc(a:^Act(Flip)) -> Status {return .Running}
    acts:=[Flip]proc(a:^Act(Flip)) -> Status{.Left=hold,.Right=hold}
    cases:=[?]struct{keep:f32,changes:u32}{{0,59},{0.05,0}}
    for c in cases {
        m:Mind
        ctx:=Mind_Context{keep=c.keep}
        for tick in 0..<60 {
            ctx.tick=u64(tick)
            mind_tick(&m,&acts,think,&ctx)
        }
        testing.expectf(t,m.exits_seen==c.changes,"keep %v: %d changes, expected %d",c.keep,m.exits_seen,c.changes)
    }
}

// The trace keeps the best proposals of the last decision, best first, and
// which action interrupted the one that exited.
@(test)
the_trace_says_why_a_mind_changed :: proc(t:^testing.T) {
    w:Zombie_World
    mind:Mind
    ctx:=Mind_Context{user=&w,keep=0.05}
    for tick in 0..=60 {
        zombie_script(&w,tick)
        ctx.time=w.time
        mind_tick(&mind,&ZOMBIE_ACTS,zombie_think,&ctx)
    }
    testing.expect(t,mind.proposals[0]==Mind_Proposal{u16(Zombie_Act.Chase),0.5} && mind.proposals[1]==Mind_Proposal{u16(Zombie_Act.Wander),0.1} && mind.proposals[2].score==0)
    exit,ok:=mind_exit_trace(&mind,0)
    testing.expect(t,ok && exit.action==u16(Zombie_Act.Wander) && exit.cause==.Aborted && exit.by==u16(Zombie_Act.Chase))
    action,step:=mind_running(&mind)
    testing.expect(t,action==u16(Zombie_Act.Chase) && step==MIND_NONE)
}

// A reservation lasts `lease` ticks after its holder last ran: one that stops
// ticking loses it then, and another takes it.
@(test)
a_reservation_outlives_its_holder_by_its_lease :: proc(t:^testing.T) {
    r:Reservations
    key:=Reservation_Key{5,2}
    cases:=[?]struct{lease:u64}{{1},{8}}
    for c in cases {
        r={}
        testing.expect(t,reserve_take(&r,key,1,1,100,c.lease))
        testing.expect(t,!reserve_take(&r,key,2,1,100+c.lease,c.lease))
        testing.expect(t,reserve_holds(&r,key,1,100+c.lease))
        testing.expect(t,reserve_take(&r,key,2,1,101+c.lease,c.lease))
        testing.expect(t,!reserve_holds(&r,key,1,101+c.lease))
        testing.expect_value(t,reserve_count(&r,key,101+c.lease),1)
        reserve_release(&r,key,2)
        testing.expect_value(t,reserve_count(&r,key,101+c.lease),0)
    }
}

// Copying the minds and the world in the middle of an errand, with the crate
// and a token held, gives the same future, and the ticks after the copy do not
// allocate.
@(test)
a_copied_mind_runs_the_same_future_without_allocating :: proc(t:^testing.T) {
    COPY :: 9*MIND_HZ+5
    TICKS :: 13*MIND_HZ
    w:=new(Bot_World)
    defer free(w)
    minds:[2]Mind
    bot_run(w,&minds,0,COPY)
    copy_world:=new_clone(w^)
    defer free(copy_world)
    copy_minds:=minds
    from:=w.count
    counter:Alloc_Counter
    saved:=context
    context.allocator=counting_allocator(&counter)
    context.temp_allocator=context.allocator
    bot_run(w,&minds,COPY,TICKS)
    bot_run(copy_world,&copy_minds,COPY,TICKS)
    context=saved
    testing.expect_value(t,counter.calls,0)
    testing.expect(t,w.count>from && w.count==copy_world.count)
    for i in from..<w.count {
        if w.calls[i]!=copy_world.calls[i] {testing.expectf(t,false,"call %d differs",i);break}
    }
    testing.expect(t,minds==copy_minds)
}

// Every procedure returns with a mind, a world and reservations scribbled
// over, actions out of the enum, and NaN or infinite scores and times.
@(test)
a_mind_survives_scribbled_state_and_wild_proposals :: proc(t:^testing.T) {
    ROUNDS :: #config(AI_HOSTILE_ROUNDS,400)
    Wild :: struct {using world:Bot_World,rng:u64} // the world first: the actions read it from `user`
    next :: proc(w:^Wild) -> u64 {
        w.rng+=0x9e3779b97f4a7c15
        z:=w.rng
        z=(z~(z>>30))*0xbf58476d1ce4e5b9
        z=(z~(z>>27))*0x94d049bb133111eb
        return z~(z>>31)
    }
    wild_f32 :: proc(w:^Wild) -> f32 {
        values:=[?]f32{f32(0h7fc00000),f32(0h7f800000),f32(0hff800000),0,-1,0.5,1,3,1e30}
        return values[next(w)%len(values)]
    }
    scribble :: proc(w:^Wild,data:[]u8) {for &b in data {b=u8(next(w))}}
    think :: proc(t:^Think(Bot_Act)) {
        w:=(^Wild)(t.user)
        for _ in 0..<int(next(w)%6) {propose(t,Bot_Act(next(w)%16),wild_f32(w))}
        if next(w)%2==0 {bot_think(t)}
    }
    w:=new(Wild)
    defer free(w)
    for _ in 0..<ROUNDS {
        m:Mind
        scribble(w,([^]u8)(&m)[:size_of(m)])
        scribble(w,([^]u8)(&w.reservations)[:size_of(w.reservations)])
        scribble(w,([^]u8)(&w.bots)[:size_of(w.bots)])
        w.agent=u8(next(w)%2)
        w.count=0
        ctx:=Mind_Context{user=w,time=f64(wild_f32(w)),tick=next(w),keep=wild_f32(w),holder=next(w)%3,reservations=&w.reservations,lease=u32(next(w))}
        for _ in 0..<8 {
            mind_tick(&m,&BOT_ACTS,think,&ctx)
            ctx.time+=f64(wild_f32(w))
            ctx.tick+=1
        }
        _,_,_,_=mind_doing(&m,Bot_Act)
        _,_=mind_running(&m)
        _,_=mind_exit_trace(&m,int(next(w)%8)-2)
        _=mind_ready(&m,Bot_Act(next(w)%16),ctx.time,f64(wild_f32(w)))
        key:=Reservation_Key{next(w)%4,u16(next(w)%3)}
        _=reserve_count(&w.reservations,key,ctx.tick)
        _=reserve_open(&w.reservations,key,next(w)%4,int(next(w)%6)-1,ctx.tick)
        _=reserve_take(&w.reservations,key,next(w)%4,int(next(w)%6)-1,ctx.tick,next(w))
        _=reserve_holds(&w.reservations,key,next(w)%4,ctx.tick)
        reserve_renew(&w.reservations,key,next(w)%4,ctx.tick,next(w))
        reserve_release(&w.reservations,key,next(w)%4)
        mind_stop(&m,&BOT_ACTS,&ctx)
    }
    zero:Mind
    ctx:=Mind_Context{}
    mind_stop(&zero,&BOT_ACTS,&ctx)
    _,running:=mind_tick(&zero,&BOT_ACTS,nil,&ctx)
    testing.expect(t,!running)
    _=reserve_take(nil,{1,0},1,1,0)
}
