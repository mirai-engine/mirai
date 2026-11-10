package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:std/ai"
import mm "mirai:std/math"
import behavior "plugins:behavior/runtime"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// AI arenas: an entity with an AI_Arena builds, when its world runs, a place
// and the agents that show one kind of AI, each deciding with a mind:
// - Horde: zombies on the roofs and in the street of a block chase a runner
//   they see, jumping from roof to roof and dropping to the street, around a
//   cart that parks in a street; three bite at once and the rest circle the
//   runner until a place frees (attack tokens). With Horde_Waves, more come in
//   waves that are rows of a table.
// - Firefight: two squads of tactical bots. They fire holding a token, take
//   the cover a query of places finds among the walls, reload, fetch ammo and
//   health from the crates of their side, man a turret and sound an alarm:
//   smart objects they claim while they use them.
// - Boss: a boss chooses its attacks by score and finishes each, fights in
//   combos below half its health, and is staggered and killed by what the
//   fight writes in its Boss; it rises again to fight on.
// - Swarm: drones with the mind of the zombies fly after the runner through
//   a yard split by a wall that hangs over it, diving under it to cross.
// - Paths: guards climb a ladder (a manual link), drop off a platform (a
//   generated one), go around a blocked area and around a cart that parks in
//   their lane (an obstacle that blocks the tiles under it), and vault a
//   fence one at a time (a link the game crosses, with its smart object).
// - Senses: listeners that barely see go to the bells they hear behind walls,
//   and forget them when they stop.

Arena_Kind :: enum u8 {Horde,Firefight,Boss,Swarm,Paths,Senses}

@(component,description="Builds an arena of AI when the world runs: a block of roofs with a horde, two squads in a firefight, a boss fight, a swarm of drones, patrollers on the ways of navigation, or listeners and bells. Without place, the scene holds its place.")
AI_Arena :: struct {
    kind:Arena_Kind,
    agents:i32 `mirai:"min=1,max=2000"`, // zombies, drones, patrollers or listeners, or soldiers of each squad
    place:bool, // it builds its place too; tools/demo_content writes it into the scene instead
    built:bool `mirai:"transient"`,
}
AI_ARENA_DEFAULT :: AI_Arena{agents=60,place=true}

HORDE_WAVE_KINDS :: 4
HORDE_MOST :: 2000 // zombies the waves of a horde send at most
HORDE_SENDS :: 64  // zombies the waves of a horde send in a tick at most

@(record,description="A kind of zombie a wave of a horde sends: how fast it runs, how far it sees and its color.")
Zombie_Kind :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    sight:f32 `mirai:"min=0,unit=m"`,
    color:[4]f32 `mirai:"color"`,
}
ZOMBIE_KIND_DEFAULT :: Zombie_Kind{speed=3.5,sight=25,color={0.45,0.75,0.35,1}}

Horde_Wave_Kind :: struct {
    kind:core.Record(Zombie_Kind),
    weight:f32 `mirai:"min=0"`, // the chances of the kind are its share of the weights of the wave
}

@(record,description="A wave of a horde: delay seconds after the wave before it, count zombies interval seconds apart, each of a kind picked by weight; then the wave next. A wave that names one before it repeats them.")
Horde_Wave :: struct {
    delay,interval:f32 `mirai:"min=0,unit=s"`,
    count:i32 `mirai:"min=0,max=500"`,
    kinds:[HORDE_WAVE_KINDS]Horde_Wave_Kind, // without any, the zombies of the arena
    next:core.Record(Horde_Wave),
}

@(component,description="Sends more zombies to a horde arena in waves, rows of Horde_Wave: first, then the one each names next. The same seed sends the same kinds.")
Horde_Waves :: struct {
    first:core.Record(Horde_Wave),
    seed:u64,
    wave:core.Record(Horde_Wave) `mirai:"transient,readonly"`, // the one sending; none: over
    sent:i32 `mirai:"transient,readonly"`,                     // of that wave
    total:i32 `mirai:"transient,readonly"`,                    // of every wave
    wait:f32 `mirai:"transient,hidden"`,                       // s to the next zombie
    started:bool `mirai:"transient,hidden"`,
    rng:mm.Rng `mirai:"transient,hidden"`,
}

@(component,description="A zombie of an arena: it wanders, chases what it sees and bites what it reaches.")
Zombie :: struct {
    bites:u32 `mirai:"transient,readonly"`,
}

@(component,description="A soldier of an arena: it fires, takes cover, reloads, and fetches ammo and health from the crates of its side.")
Soldier :: struct {
    health:f32 `mirai:"transient,readonly"`,
    ammo:i32 `mirai:"transient,readonly"`,    // in the magazine
    reserve:i32 `mirai:"transient,readonly"`, // rounds to reload from
    ahead:f32 `mirai:"transient,hidden"`,     // +1 or -1: along z toward the other squad
    shots,hits,hit:u32 `mirai:"transient,readonly"`,
}

@(component,description="The boss of an arena: its health, and the hero it fights.")
Boss :: struct {
    health:f32 `mirai:"transient,readonly"`,
    hero:core.Entity `mirai:"transient,hidden"`,
    slams,charges,summons,roars,deaths:u32 `mirai:"transient,readonly"`,
    rises:u64 `mirai:"transient,hidden"`,     // the tick it rises again at; 0 while it stands
    staggered:bool `mirai:"transient,hidden"`, // by the hero: it is stunned at its next decision
}

@(component,description="What the AI of an arena chases or fights: it walks its round and hurts the boss near it.")
Arena_Target :: struct {
    next:i32 `mirai:"transient,hidden"`,
    again:u64 `mirai:"transient,hidden"`, // the tick the hero picks another point at
    center:[3]f32 `mirai:"transient,hidden"`,
}

BOSS_HEALTH :: f32(200)
TEAM_RUNNER :: behavior.Team(1)
TEAM_RED :: behavior.Team(2)
TEAM_BLUE :: behavior.Team(3)

// What the smart objects of the arenas offer.
USE_AMMO :: behavior.Smart_Use(1)
USE_HEALTH :: behavior.Smart_Use(2)
USE_COVER :: behavior.Smart_Use(3)
USE_TURRET :: behavior.Smart_Use(4)
USE_ALARM :: behavior.Smart_Use(5)
USE_VAULT :: behavior.Smart_Use(6)

// A fence the agents vault, one at a time: a link the game crosses.
LINK_VAULT :: nav.Nav_Link_Kind(7)

ZOMBIE_BITERS :: 3 // zombies that bite the same target at once; the rest circle it

// What the actions of the arenas work on: the world the arena function received.
@(private)
Arena_Tick :: struct {
    using tick:behavior.Mind_Tick,
    placer:core.Placer,
    zombies:^core.Table(Zombie),
    soldiers:^core.Table(Soldier),
    bosses:^core.Table(Boss),
    patrols:^core.Table(Arena_Patrol),
    flights:core.Read(phys.Fly),
    physics:core.Ref(phys.Physics_State),
    rng:^mm.Rng,
}

@(storage)
Arena_State :: struct {
    rng:mm.Rng,
    seeded:bool,
}

// The best subject an agent remembers and how sure it is.
@(private)
arena_seen :: proc(w:^Arena_Tick,e:core.Entity) -> (subject:core.Entity,position:mm.Vec3,confidence:f32) {
    mine,ok:=core.get(w.perceptions,e)
    if !ok {return}
    pose,_:=core.get(w.worlds,e)
    best,found:=ai.memory_best(&mine.memory,pose.position)
    if !found {return}
    return core.Entity(best.subject),best.position,best.confidence
}

@(private)
arena_position :: proc(w:^Arena_Tick,e:core.Entity) -> mm.Vec3 {
    pose,_:=core.get(w.worlds,e)
    return pose.position
}

// Who an agent is to the smart objects.
@(private)
arena_user :: proc(w:^Arena_Tick,e:core.Entity) -> behavior.Smart_User {
    user:=behavior.Smart_User{entity=e}
    if p,ok:=core.get(w.perceivables,e);ok {user.team=p.team}
    if a,ok:=core.get(w.agents,e);ok {user.abilities=a.abilities}
    return user
}

// ---------------------------------------------------------------- zombies

// Wanders until it sees or hears something, chases it, and bites while it is
// near, at most ZOMBIE_BITERS of them at once on one target: the rest circle
// it until a place frees. Drones and listeners are zombies too.
Zombie_Act :: enum u8 {Wander,Chase,Circle,Bite}

@(private)
zombie_think :: proc(t:^ai.Think(Zombie_Act)) {
    w:=(^Arena_Tick)(t.user)
    subject,_,confidence:=arena_seen(w,w.entity)
    ai.propose(t,.Wander,0.1)
    if confidence<=0.2 || subject==core.NONE {return}
    ai.propose(t,.Chase,0.5)
    distance:=linalg.length(arena_position(w,subject)-arena_position(w,w.entity))
    if distance>4 {return}
    if distance<1.8 && ai.reserve_free(t,subject,ZOMBIE_BITERS) {
        ai.propose(t,.Bite,1)
    } else {
        ai.propose(t,.Circle,0.7)
    }
}

// Walks somewhere near for a second or so, then stands a second and a half.
@(private)
zombie_wander :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if ai.stage(a)==0 {
        if a.phase==.Enter {
            angle:=mm.random_range(w.rng,0,2*math.PI)
            s,c:=mm.sincos_det(angle)
            to:=arena_position(w,w.entity)+mm.Vec3{c,0,s}*mm.random_range(w.rng,3,8)
            // A drone wanders up and down too; its goal is where its middle goes.
            if core.has(w.flights,w.entity) {to.y+=mm.random_range(w.rng,-1.5,3)}
            return behavior.move_act(w,a,to)
        }
        status:=behavior.move_act(w,a,{})
        if a.phase==.Exit || status==.Running {return status}
        return ai.next_stage(a)
    }
    if a.phase==.Exit {return .Success}
    return .Success if ai.stage_elapsed(a)>=1.5 else .Running
}

// Follows what it remembers best; a new subject is followed instead.
@(private)
zombie_chase :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    subject,_,_:=arena_seen(w,w.entity)
    if a.phase==.Exit {nav.nav_stop(w.requests,w.entity);return .Success}
    if subject==core.NONE {return .Failure}
    distance:=f32(1.2 if a.action==.Chase else 3.5)
    if a.phase==.Enter || u64(subject)!=a.memory[0] {
        a.memory[0]=u64(subject)
        nav.nav_follow(w.requests,w.entity,subject,distance)
        return .Running
    }
    p,_:=behavior.agent_path(w)
    return .Failure if p.state==.Failed else .Running
}

// Bites now and again 0.8 s later, holding one of the places to bite its target.
@(private)
zombie_bite :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if a.phase==.Exit {return .Success}
    subject,_,_:=arena_seen(w,w.entity)
    if a.phase==.Enter {
        if subject==core.NONE || !ai.token_take(a,u64(subject),ZOMBIE_BITERS) {return .Failure}
        if z:=core.edit(w.zombies,w.entity);z!=nil {z.bites+=1}
        behavior.present_look(w,subject)
    }
    return ai.after(a,0.8)
}

@(private)
ZOMBIE_ACTS := [Zombie_Act]proc(a:^ai.Act(Zombie_Act)) -> ai.Status{.Wander=zombie_wander,.Chase=zombie_chase,.Circle=zombie_chase,.Bite=zombie_bite}

// ---------------------------------------------------------------- soldiers

// A soldier of a squad: it fires when it sees an enemy and holds one of the
// tokens to fire at it, else takes the cover a query of places finds among
// the walls (hidden from the enemy, where its squad is and the other is not),
// reloads, fetches ammo and health from the crates of its side, mans the
// turret near it and sounds the alarm, which every soldier of its side hears.
Soldier_Act :: enum u8 {Advance,Take_Cover,Fire,Reload,Get_Ammo,Heal,Man_Turret,Alarm}

SOLDIER_SHOOTERS :: 2 // soldiers that fire at the same enemy at once
SOLDIER_MAG :: 6
SOLDIER_SURE :: f32(0.8) // how sure of an enemy it fires at it: seen a moment ago, in its turn of rays
SOLDIER_ERRAND :: f32(0.8) // what going for a smart object counts once begun: only healing and fetching ammo interrupt it

@(private)
soldier_think :: proc(t:^ai.Think(Soldier_Act)) {
    w:=(^Arena_Tick)(t.user)
    e:=w.entity
    s:=core.edit(w.soldiers,e)
    if s==nil {return}
    user:=arena_user(w,e)
    here:=arena_position(w,e)
    subject,_,confidence:=arena_seen(w,e)
    sees:=confidence>=SOLDIER_SURE && subject!=core.NONE
    if s.health<40 {
        if _,ok:=behavior.smart_nearest(&w.smart,USE_HEALTH,here,60,user);ok {ai.propose(t,.Heal,0.9)}
    }
    if s.ammo==0 && s.reserve>0 {ai.propose(t,.Reload,0.8)}
    if s.ammo==0 && s.reserve==0 {
        if _,ok:=behavior.smart_nearest(&w.smart,USE_AMMO,here,60,user);ok {ai.propose(t,.Get_Ammo,0.85)}
    }
    if sees {
        if _,ok:=behavior.smart_nearest(&w.smart,USE_ALARM,here,25,user);ok {ai.propose(t,.Alarm,0.75)}
        if _,ok:=behavior.smart_nearest(&w.smart,USE_TURRET,here,15,user);ok {ai.propose(t,.Man_Turret,0.72)}
        if s.ammo>0 && ai.reserve_free(t,subject,SOLDIER_SHOOTERS) {ai.propose(t,.Fire,0.7)}
        ai.propose(t,.Take_Cover,0.55)
    } else if confidence>0 {
        ai.propose(t,.Advance,0.3)
    }
    ai.propose(t,.Advance,0.2)
}

// Walks to where it last perceived an enemy, or ahead toward the other squad.
@(private)
soldier_advance :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if a.phase!=.Enter {return behavior.move_act(w,a,{})}
    _,position,confidence:=arena_seen(w,w.entity)
    if confidence<=0 {
        ahead:=f32(-1)
        if s:=core.edit(w.soldiers,w.entity);s!=nil && s.ahead!=0 {ahead=s.ahead}
        position=arena_position(w,w.entity)+{0,0,8*ahead}
    }
    return behavior.move_act(w,a,position)
}

// Asks for the wall that covers it best and stays behind it: stage 0 waits
// for the answer and claims the place, 1 walks there, 2 holds it.
@(private)
soldier_cover :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    e:=w.entity
    switch a.phase {
    case .Enter:
        subject,_,_:=arena_seen(w,e)
        mine:=arena_user(w,e).team
        q:=behavior.Place_Query{querier=e,center=.Querier,layout=.Offers,use=USE_COVER,outer=14,keep=1}
        falling:=ai.Response{kind=.Linear,slope=-1,shift_y=1}
        q.tests[0]={measure=.Visible,from=.Target if subject!=core.NONE else .Querier,target=subject,min=0,max=1,response=falling}
        q.tests[1]={measure=.Path,from=.Querier,min=0,max=30,response=falling}
        q.tests[2]={measure=.Influence,teams=behavior.Teams(1<<u32(TEAM_RED+TEAM_BLUE-mine)),min=0,max=2,response={kind=.Linear,slope=-0.5,shift_y=1}}
        q.test_count=3
        a.memory[0]=u64(behavior.place_query(w.places,q))
        return .Running
    case .Update:
        switch ai.stage(a) {
        case 0:
            result,ok:=core.get(w.results,e)
            if !ok || result.request!=u32(a.memory[0]) || result.status==.Waiting {return .Running}
            if result.status!=.Found || result.offers[0]<0 {return .Failure}
            object,_:=core.get(w.smart.objects,result.entities[0])
            found:=behavior.Smart_Found{result.entities[0],int(result.offers[0]),result.points[0],max(int(object.offers[result.offers[0]].users),1)}
            if !behavior.smart_claim(a,found) {return .Failure}
            nav.nav_move_to(w.requests,e,found.at)
            return ai.next_stage(a)
        case 1:
            status:=behavior.path_status(w)
            if status!=.Success {return status}
            return ai.next_stage(a)
        }
        return .Running
    case .Exit:
        if a.cause==.Aborted && ai.stage(a)==1 {nav.nav_stop(w.requests,e)}
    }
    return .Success
}

// Fires its magazine at the enemy it sees, a round every 0.4 s, holding one
// of the tokens to fire at it.
@(private)
soldier_fire :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    e:=w.entity
    if a.phase==.Exit {nav.nav_look_along(w.requests,e);return .Success}
    s:=core.edit(w.soldiers,e)
    subject,position,confidence:=arena_seen(w,e)
    if s==nil || subject==core.NONE || confidence<SOLDIER_SURE {return .Failure}
    if a.phase==.Enter {
        if !ai.token_take(a,u64(subject),SOLDIER_SHOOTERS) {return .Failure}
        nav.nav_stop(w.requests,e)
        nav.nav_look_at(w.requests,e,position)
        return .Running
    }
    if ai.stage_elapsed(a)<0.4 {return .Running}
    ai.next_stage(a)
    arena_shot(w,e,subject,position)
    s.ammo-=1
    return .Success if s.ammo<=0 else .Running
}

// A round from e at what it sees: a hit takes health from a soldier, down to 10.
@(private)
arena_shot :: proc(w:^Arena_Tick,e,subject:core.Entity,position:mm.Vec3) {
    s:=core.edit(w.soldiers,e)
    if s!=nil {s.shots+=1}
    eye:=arena_position(w,e)+{0,1.5,0}
    to:=position+{0,1.2,0}-eye
    if hit,ok:=phys.raycast(w.physics,eye,linalg.normalize0(to),linalg.length(to)+1,e);ok && hit.entity==subject {
        if s!=nil {s.hits+=1}
        if other:=core.edit(w.soldiers,subject);other!=nil {
            other.hit+=1
            other.health=max(other.health-12,10)
        }
    }
}

@(private)
soldier_reload :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    s:=core.edit(w.soldiers,w.entity)
    if a.phase==.Exit {return .Success}
    if s==nil {return .Failure}
    if ai.elapsed(a)<1.5 {return .Running}
    n:=min(SOLDIER_MAG,s.reserve)
    s.ammo+=n
    s.reserve-=n
    return .Success
}

// Fetches ammo from a crate of its side, or health from a kit.
@(private)
soldier_supply :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    use:=USE_AMMO if a.action==.Get_Ammo else USE_HEALTH
    status,found:=behavior.offer_act(w,&w.smart,a,use,arena_user(w,w.entity),60,1 if use==USE_AMMO else 2)
    if a.phase==.Enter {ai.commit(a,SOLDIER_ERRAND)}
    if a.phase==.Exit || status!=.Success {return status}
    if s:=core.edit(w.soldiers,w.entity);s!=nil {
        if use==USE_AMMO {s.reserve+=2*SOLDIER_MAG} else {s.health=100}
    }
    behavior.smart_used(w.uses,found)
    return .Success
}

// Mans the turret of its side near it and fires from it, fast and without
// using its rounds, while it sees an enemy.
@(private)
soldier_turret :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    e:=w.entity
    if ai.stage(a)<2 || a.phase==.Enter {
        status,_:=behavior.offer_act(w,&w.smart,a,USE_TURRET,arena_user(w,e),15,0.5)
        if a.phase==.Enter {ai.commit(a,SOLDIER_ERRAND)}
        if a.phase==.Exit || status!=.Success {return status}
        // Manned: it stays while it sees an enemy.
        ai.commit(a,0)
        return ai.next_stage(a)
    }
    if a.phase==.Exit {nav.nav_look_along(w.requests,e);return .Success}
    subject,position,confidence:=arena_seen(w,e)
    if subject==core.NONE || confidence<SOLDIER_SURE {return .Failure}
    nav.nav_look_at(w.requests,e,position)
    if ai.stage_elapsed(a)<0.2 {return .Running}
    ai.next_stage(a)
    arena_shot(w,e,subject,position)
    return .Running
}

// Sounds the alarm of its side: everyone within 60 m hears where the enemy it saw is.
@(private)
soldier_alarm :: proc(a:^ai.Act(Soldier_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    e:=w.entity
    status,found:=behavior.offer_act(w,&w.smart,a,USE_ALARM,arena_user(w,e),25,1)
    if a.phase==.Enter {ai.commit(a,SOLDIER_ERRAND)}
    if a.phase==.Exit || status!=.Success {return status}
    subject,position,_:=arena_seen(w,e)
    behavior.noise(w.noises,position,60,subject)
    behavior.smart_used(w.uses,found)
    return .Success
}

@(private)
SOLDIER_ACTS := [Soldier_Act]proc(a:^ai.Act(Soldier_Act)) -> ai.Status{
    .Advance=soldier_advance,.Take_Cover=soldier_cover,.Fire=soldier_fire,.Reload=soldier_reload,
    .Get_Ammo=soldier_supply,.Heal=soldier_supply,.Man_Turret=soldier_turret,.Alarm=soldier_alarm,
}

// ------------------------------------------------------------------- the boss

// Fights in two phases: attacks chosen by score in the first, each finished
// once begun; combos below half its health, chosen by where the hero is when
// each starts. A stagger stuns it at once, and it falls when its health ends.
Boss_Act :: enum u8 {Slam,Charge,Summon,Roar,Rage,Stunned,Dead}

BOSS_COMMITTED :: 2 // what an attack counts once begun: more than any other attack
BOSS_PHASE :: 3
BOSS_STUNNED :: 50
BOSS_DEAD :: 100

@(private)
boss_think :: proc(t:^ai.Think(Boss_Act)) {
    w:=(^Arena_Tick)(t.user)
    b:=core.edit(w.bosses,w.entity)
    if b==nil {return}
    alive:=b.health>0
    first:=b.health>BOSS_HEALTH/2
    near:=f32(1 if linalg.length(arena_position(w,b.hero)-arena_position(w,w.entity))<4 else 0)
    ai.propose(t,.Dead,BOSS_DEAD if !alive else 0)
    ai.propose(t,.Stunned,BOSS_STUNNED if alive && b.staggered else 0)
    ai.propose(t,.Rage,BOSS_PHASE if alive && !first else 0)
    if alive && first {
        ai.propose(t,.Slam,0.1+0.9*near)
        ai.propose(t,.Charge,1-0.9*near)
        if ai.mind_ready(t.mind,Boss_Act.Summon,t.tick,t.dt,6) {ai.propose(t,.Summon,0.6*(1-f32(b.summons%4)/3))}
    }
}

@(private)
boss_attack :: proc(a:^ai.Act(Boss_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    b:=core.edit(w.bosses,w.entity)
    if b==nil {return .Failure if a.phase!=.Exit else .Success}
    if a.action==.Charge {
        if a.phase==.Enter {
            b.charges+=1
            ai.commit(a,BOSS_COMMITTED)
            return behavior.move_act(w,a,arena_position(w,b.hero))
        }
        status:=behavior.move_act(w,a,{})
        return .Success if status==.Failure else status
    }
    switch a.phase {
    case .Enter:
        ai.commit(a,BOSS_COMMITTED)
        #partial switch a.action {
        case .Slam: b.slams+=1
        case .Summon: b.summons+=1
        case .Roar: b.roars+=1
        }
        behavior.present_animation(w,u16(a.action))
        return .Running
    case .Update: return ai.after(a,1)
    case .Exit:
    }
    return .Success
}

@(private)
boss_rage :: proc(a:^ai.Act(Boss_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if a.phase==.Exit {return .Success}
    if ai.entering(a) {
        if b,ok:=core.get(w.bosses,w.entity);ok && linalg.length(arena_position(w,b.hero)-arena_position(w,w.entity))<4 {a.memory[0]=1}
    }
    if a.memory[0]==1 {return ai.steps(a,.Slam,.Slam,.Roar)}
    return ai.steps(a,.Charge,.Slam)
}

// The stagger is a flag of the Boss that the fight raises; being stunned takes it down.
@(private)
boss_stunned :: proc(a:^ai.Act(Boss_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if ai.entering(a) {
        ai.commit(a,BOSS_STUNNED)
        if b:=core.edit(w.bosses,w.entity);b!=nil {b.staggered=false}
    }
    return ai.after(a,1.5)
}

@(private)
boss_dead :: proc(a:^ai.Act(Boss_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if ai.entering(a) {ai.commit(a,BOSS_DEAD)}
    b,ok:=core.get(w.bosses,w.entity)
    return .Success if !ok || b.health>0 else .Running
}

@(private)
BOSS_ACTS := [Boss_Act]proc(a:^ai.Act(Boss_Act)) -> ai.Status{
    .Slam=boss_attack,.Charge=boss_attack,.Summon=boss_attack,.Roar=boss_attack,
    .Rage=boss_rage,.Stunned=boss_stunned,.Dead=boss_dead,
}

// ------------------------------------------------------------------ guards

// Walks its points in turn; at the fence on its way it waits for the one
// before it to vault, then vaults, and walks on to the same point.
Guard_Act :: enum u8 {Patrol,Vault}

@(private)
guard_think :: proc(t:^ai.Think(Guard_Act)) {
    w:=(^Arena_Tick)(t.user)
    if p,ok:=behavior.agent_path(w);ok && p.state==.Crossing && p.manual && p.kind==LINK_VAULT {ai.propose(t,.Vault,1)}
    ai.propose(t,.Patrol,0.1)
}

// Its way goes on while it vaults: an exit leaves navigation as it is.
@(private)
guard_patrol :: proc(a:^ai.Act(Guard_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    patrol:=core.edit(w.patrols,w.entity)
    if patrol==nil || a.phase==.Exit {return .Success if a.phase==.Exit else .Failure}
    if a.phase==.Enter {
        nav.nav_move_to(w.requests,w.entity,patrol.points[patrol.next])
        return .Running
    }
    status:=behavior.path_status(w)
    if status==.Running {return .Running}
    // There, or where it cannot get: the next point.
    patrol.next=(patrol.next+1)%4
    return .Success
}

// Once begun it lasts until navigation takes the guard on from the other side.
@(private)
guard_vault :: proc(a:^ai.Act(Guard_Act)) -> ai.Status {
    w:=(^Arena_Tick)(a.user)
    if ai.entering(a) {ai.commit(a,1)}
    return behavior.cross_act(w,&w.smart,a,w.links,w.placer,USE_VAULT,arena_user(w,w.entity),0.6)
}

@(private)
GUARD_ACTS := [Guard_Act]proc(a:^ai.Act(Guard_Act)) -> ai.Status{.Patrol=guard_patrol,.Vault=guard_vault}

// Builds the arenas that have not been built, once the world runs: their
// place, unless the scene holds it, and their agents.
@(step="fixed",stage="apply",server)
arena_build :: proc(
    commands:core.Commands,arenas:^core.Table(AI_Arena),worlds:core.Read(core.World_Transform),time:core.Time,
) {
    if !time.playing {return}
    for row in 0..<core.count(arenas) {
        a:=core.edit_at(arenas,row)
        if a.built {continue}
        a.built=true
        e:=core.entity_at(arenas,row)
        origin:mm.Vec3
        if pose,ok:=core.get(worlds,e);ok {origin=pose.position}
        if a.place {
            pieces:=make([dynamic]Arena_Piece,context.temp_allocator)
            arena_place(a.kind,origin,&pieces)
            for piece in pieces {arena_piece_add(commands,piece)}
        }
        arena_agents(commands,a.kind,origin,int(a.agents))
    }
}

// A piece of the place of an arena. The world adds it when the arena runs, or
// the scene holds it (AI_Arena.place false; tools/demo_content writes it), so
// that the navigation mesh is there in the editor.
Arena_Piece_Kind :: enum u8 {
    Solid, // a box of the static collision
    Area,  // a Nav_Area, shown as a tinted slab without collision
    Link,  // a Nav_Link from position to position+end
    Air,   // a Nav_Bounds of the air, of half `half`
    Cart,  // a kinematic box with a Nav_Obstacle that drives from position to `to` and back
    Offer, // a Smart_Object with the offers
}

Arena_Piece :: struct {
    kind:Arena_Piece_Kind,
    name:string,
    position,half:mm.Vec3,
    color:[4]f32,
    end:mm.Vec3,
    link:nav.Nav_Link_Kind,
    area:nav.Nav_Area_Kind,
    to:mm.Vec3,
    offers:[2]behavior.Smart_Offer, // of an Offer, or of a Link the game crosses
}

ARENA_GROUND :: [4]f32{0.35,0.35,0.38,1}
ARENA_WALL :: [4]f32{0.5,0.45,0.42,1}
ARENA_CART_DRIVE :: f32(3) // s from one end to the other
ARENA_CART_WAIT :: f32(6)  // s parked at each end: long enough for it to block the surface under it

// The place of an arena around its origin.
arena_place :: proc(kind:Arena_Kind,origin:mm.Vec3,out:^[dynamic]Arena_Piece) {
    solid :: proc(out:^[dynamic]Arena_Piece,name:string,position,half:mm.Vec3,color:=ARENA_WALL) {
        append(out,Arena_Piece{kind=.Solid,name=name,position=position,half=half,color=color})
    }
    switch kind {
    case .Horde:
        // 3 x 3 buildings 8 m across with streets of 2.5 m: roofs of 3.5 and 4.5 m, so a zombie jumps up 1 m
        // from roof to roof and drops 3.5 m to the street. A cart parks in a street now and then.
        solid(out,"Horde ground",origin+{0,-0.5,0},{40,0.5,40},ARENA_GROUND)
        for z in 0..<3 {
            for x in 0..<3 {
                height:=f32(3.5 if (x+z)%2==0 else 4.5)
                solid(out,"Building",origin+{f32(x-1)*10.5,height*0.5,f32(z-1)*10.5},{4,height*0.5,4})
            }
        }
        append(out,Arena_Piece{kind=.Cart,name="Cart",position=origin+{-5.25,0.75,-22},to=origin+{-5.25,0.75,0},half={1,0.75,1.5},color={0.8,0.6,0.15,1}})
    case .Firefight:
        // Walls whose two sides are cover; for each side, crates of ammo and health, a turret and an alarm.
        solid(out,"Firefight ground",origin+{0,-0.5,0},{25,0.5,25},{0.35,0.38,0.35,1})
        for i in 0..<10 {
            wall:=origin+{f32(i%5)*8-16,0.7,f32(i/5)*12-6}
            solid(out,"Cover wall",wall,{1.5,0.7,0.3},{0.45,0.42,0.4,1})
            append(out,Arena_Piece{kind=.Offer,name="Cover",position=wall-{0,0.7,0},offers={{use=USE_COVER,at={0,0,-1},users=2},{use=USE_COVER,at={0,0,1},users=2}}})
        }
        for side in ([2]f32{-1,1}) {
            team:=behavior.Teams(1<<u32(TEAM_RED if side<0 else TEAM_BLUE))
            supply :: proc(out:^[dynamic]Arena_Piece,name:string,at,half:mm.Vec3,color:[4]f32,offer:behavior.Smart_Offer) {
                append(out,Arena_Piece{kind=.Solid,name=name,position=at+{0,half.y,0},half=half,color=color})
                append(out,Arena_Piece{kind=.Offer,name=name,position=at,offers={0=offer}})
            }
            supply(out,"Ammo crate",origin+{20,0,side*14},{0.5,0.4,0.5},{0.85,0.7,0.2,1},{use=USE_AMMO,at={0,0,side*1.1},users=1,uses=4,cooldown=8,teams=team})
            supply(out,"Health kit",origin+{-20,0,side*14},{0.5,0.4,0.5},{0.9,0.9,0.9,1},{use=USE_HEALTH,at={0,0,side*1.1},users=1,uses=3,cooldown=10,teams=team})
            supply(out,"Turret",origin+{0,0,side*10},{0.4,0.6,0.4},{0.3,0.3,0.32,1},{use=USE_TURRET,at={0,0,side*1},users=1,teams=team})
            supply(out,"Alarm",origin+{-8,0,side*20},{0.15,1.2,0.15},{0.9,0.2,0.15,1},{use=USE_ALARM,at={0,0,side*0.8},users=1,cooldown=30,teams=team})
        }
    case .Boss:
        solid(out,"Boss hall",origin+{0,-0.5,0},{18,0.5,18},{0.3,0.28,0.3,1})
        for i in 0..<4 {
            s,co:=mm.sincos_det(f32(i)*0.5*math.PI+0.785)
            solid(out,"Pillar",origin+{co*9,2,s*9},{0.8,2,0.8},{0.45,0.4,0.38,1})
        }
    case .Swarm:
        // A yard split by a wall that hangs from 3.5 m to 14 m and goes beyond the air on both sides.
        solid(out,"Swarm yard",origin+{0,-0.5,0},{30,0.5,30},{0.33,0.36,0.4,1})
        solid(out,"Hanging wall",origin+{0,8.75,0},{28,5.25,0.5})
        for i in 0..<6 {solid(out,"Pillar",origin+{f32(i%3-1)*12,6,f32(i/3)*20-10},{1,6,1},{0.45,0.42,0.4,1})}
        append(out,Arena_Piece{kind=.Air,name="Air of the swarm",position=origin+{0,8,0},half={26,8,26}})
    case .Paths:
        // A platform reached by a ladder (a manual link) and left by the drops the build generates,
        // a blocked area, a fence across the ground that the guards vault, and a cart that parks
        // across the lane on the far side.
        solid(out,"Paths ground",origin+{0,-0.5,0},{20,0.5,15},ARENA_GROUND)
        solid(out,"Fence",origin+{11,0.9,0},{0.15,0.9,16},{0.55,0.4,0.25,1})
        append(out,Arena_Piece{kind=.Link,name="Vault",position=origin+{10.2,0,0},end={1.6,0,0},link=LINK_VAULT,color={0.55,0.4,0.25,1},offers={0={use=USE_VAULT,at={-0.3,0,0},users=1}}})
        solid(out,"Platform",origin+{-8,1.75,0},{3,1.75,3})
        append(out,Arena_Piece{kind=.Link,name="Ladder",position=origin+{-11.8,0,0},end={1.4,3.5,0},link=nav.LINK_LADDER,color={0.9,0.75,0.3,1}})
        append(out,Arena_Piece{kind=.Area,name="Blocked area",position=origin+{4,0,0},half={3,0.02,6},area=nav.AREA_BLOCKED,color={0.8,0.2,0.2,1}})
        append(out,Arena_Piece{kind=.Cart,name="Cart",position=origin+{16.5,0.75,-13},to=origin+{16.5,0.75,0},half={2,0.75,1},color={0.8,0.6,0.15,1}})
    case .Senses:
        // Walls that hide the bells from the listeners: they find them by ear.
        solid(out,"Senses ground",origin+{0,-0.5,0},{18,0.5,18},ARENA_GROUND)
        for i in 0..<4 {
            s,co:=mm.sincos_det(f32(i)*0.5*math.PI)
            solid(out,"Screen wall",origin+{co*7,1.5,s*7},{0.3+abs(s)*3,1.5,0.3+abs(co)*3})
        }
    }
}

// What the world adds for a piece.
@(private)
arena_piece_add :: proc(c:core.Commands,piece:Arena_Piece) {
    e:=core.commands_create(c)
    switch piece.kind {
    case .Solid,.Cart:
        core.commands_add(c,e,core.Transform{piece.position,1,piece.half*2})
        core.commands_add(c,e,phys.collider_box({0.5,0.5,0.5}))
        core.commands_add(c,e,render.Mesh_Renderer{shape=.Cube})
        core.commands_add(c,e,render.Tint{color=piece.color})
        if piece.kind==.Cart {
            core.commands_add(c,e,phys.RIGID_BODY_KINEMATIC)
            core.commands_add(c,e,nav.Nav_Obstacle{settle=1})
            core.commands_add(c,e,volume.box({0.5,0.5,0.5}))
            core.commands_add(c,e,Arena_Cart{from=piece.position,to=piece.to})
        }
    case .Area:
        core.commands_add(c,e,core.Transform{piece.position,1,{1,1,1}})
        core.commands_add(c,e,nav.Nav_Area{area=piece.area})
        core.commands_add(c,e,volume.box(piece.half+{0,1,0}))
        slab:=core.commands_create(c)
        core.commands_add(c,slab,core.Transform{{0,0.01,0},1,piece.half*2})
        core.commands_add(c,slab,core.Parent{entity=e})
        core.commands_add(c,slab,render.Mesh_Renderer{shape=.Cube})
        core.commands_add(c,slab,render.Tint{color=piece.color})
    case .Link:
        core.commands_add(c,e,core.Transform{piece.position,1,{1,1,1}})
        core.commands_add(c,e,nav.Nav_Link{end=piece.end,kind=piece.link,two_way=true,area=nav.AREA_WALKABLE,abilities=arena_link_abilities(piece.link)})
        if piece.offers[0].use!=behavior.USE_NONE {core.commands_add(c,e,behavior.Smart_Object{offers={0=piece.offers[0],1=piece.offers[1]}})}
    case .Offer:
        core.commands_add(c,e,core.Transform{piece.position,1,{1,1,1}})
        core.commands_add(c,e,behavior.Smart_Object{offers={0=piece.offers[0],1=piece.offers[1]}})
    case .Air:
        core.commands_add(c,e,core.Transform{piece.position,1,{1,1,1}})
        core.commands_add(c,e,nav.Nav_Bounds{air=true})
        core.commands_add(c,e,volume.box(piece.half))
    }
}

// What an agent needs to cross a manual link of a kind.
arena_link_abilities :: proc "contextless" (kind:nav.Nav_Link_Kind) -> nav.Nav_Abilities {
    if kind==nav.LINK_LADDER {return nav.Nav_Abilities(1<<u32(nav.ABILITY_LADDER))}
    return {}
}

// Drives between its two places, waiting at each end. Its Nav_Obstacle blocks
// the surface under it once it has waited long enough.
@(component,description="Drives from where it was placed to `to` and back, waiting at each end: a cart of the AI arenas.")
Arena_Cart :: struct {
    from,to:[3]f32 `mirai:"unit=m"`,
}

// Guards patrol their points in turn; bells ring in turn for whoever hears.
@(component,description="A guard of the AI arenas: it walks to each of its points in turn.")
Arena_Patrol :: struct {
    points:[4][3]f32 `mirai:"unit=m"`,
    next:i32 `mirai:"transient,hidden"`,
}

@(component,description="A bell of the AI arenas: it rings, a noise of `loudness` m, when its turn comes among `count` bells, every `period` s.")
Arena_Bell :: struct {
    turn,count:i32,
    period:f32 `mirai:"min=0,unit=s"`,
    loudness:f32 `mirai:"min=0,unit=m"`,
}

@(private)
arena_body :: proc(c:core.Commands,position:mm.Vec3,color:[4]f32,speed:f32=4) -> core.Entity {
    e:=core.commands_create(c)
    // An id, so the API can name the agent while the arena runs.
    core.commands_add(c,e,core.Id{core.id_next(c.entities)})
    core.commands_add(c,e,core.Transform{position,1,{1,1,1}})
    core.commands_add_default(c,e,phys.Character)
    core.commands_add_default(c,e,phys.Locomotion)
    core.commands_add(c,e,phys.collider_character())
    walk:=core.default(c,phys.Walk)
    walk.max_speed=speed
    core.commands_add(c,e,walk)
    core.commands_add_default(c,e,nav.Nav_Agent)
    look:=core.commands_create(c)
    core.commands_add(c,look,core.Transform{{0,0.9,0},1,{0.6,0.9,0.6}})
    core.commands_add(c,look,core.Parent{entity=e})
    core.commands_add(c,look,render.Mesh_Renderer{shape=.Capsule})
    core.commands_add(c,look,render.Tint{color=color})
    return e
}

@(private)
arena_target :: proc(c:core.Commands,position:mm.Vec3,team:behavior.Team) -> core.Entity {
    e:=arena_body(c,position,{0.2,0.6,1,1},5)
    core.commands_add(c,e,Arena_Target{center=position})
    core.commands_add(c,e,behavior.Perceivable{team=team,point=1})
    return e
}

// Sends the waves of the horde arenas that have them, once the arena is built.
@(step="fixed",stage="apply",server)
horde_waves :: proc(
    commands:core.Commands,hordes:^core.Table(Horde_Waves),arenas:core.Read(AI_Arena),worlds:core.Read(core.World_Transform),
    waves:core.Records(Horde_Wave),kinds:core.Records(Zombie_Kind),time:core.Time,problems:^core.Problems,
) {
    if !time.playing || time.dt<=0 {return}
    for row in 0..<core.count(hordes) {
        h:=core.edit_at(hordes,row)
        e:=core.entity_at(hordes,row)
        arena,built:=core.get(arenas,e)
        if !built || !arena.built || arena.kind!=.Horde {continue}
        if !h.started {
            h.started=true
            h.rng=mm.rng_make(h.seed,7)
            h.wave=h.first
            first,_:=core.record(waves,h.wave,problems,e)
            h.wait=first.delay
        }
        origin:mm.Vec3
        if pose,ok:=core.get(worlds,e);ok {origin=pose.position}
        left:=f32(time.dt)
        // A chain of waves that send nothing and wait nothing would never end the tick.
        for _ in 0..<HORDE_SENDS {
            if h.wave=={} || h.total>=HORDE_MOST {break}
            if left<h.wait {h.wait-=left;break}
            left-=h.wait
            wave,found:=core.record(waves,h.wave,problems,e)
            if !found {h.wave={};break}
            if h.sent<wave.count {
                kind:=ZOMBIE_KIND_DEFAULT
                if picked,ok:=core.record(kinds,horde_pick(&h.rng,wave.kinds),problems,e);ok {kind=picked}
                arena_zombie(commands,arena_body(commands,horde_spot(origin,int(h.total)),kind.color,kind.speed),kind.sight)
                h.sent+=1
                h.total+=1
            }
            if h.sent<wave.count {
                h.wait=wave.interval
                continue
            }
            h.wave,h.sent=wave.next,0
            next,_:=core.record(waves,h.wave,problems,e)
            h.wait=next.delay
        }
    }
}

// A kind of the wave with chances in proportion to its weight; none when no
// kind has weight.
@(private)
horde_pick :: proc(rng:^mm.Rng,kinds:[HORDE_WAVE_KINDS]Horde_Wave_Kind) -> (picked:core.Record(Zombie_Kind)) {
    total:f32
    for k in kinds {
        if k.kind!={} && k.weight>0 {total+=k.weight}
    }
    if !(total>0) || total>max(f32) {return}
    at:=mm.random_f32(rng)*total
    for k in kinds {
        if k.kind=={} || !(k.weight>0) {continue}
        picked=k.kind
        if at<k.weight {return}
        at-=k.weight
    }
    return
}

// Where the zombie number i of the waves comes in: along the streets at the
// edge of the block, a little further each round.
@(private)
horde_spot :: proc(origin:mm.Vec3,i:int) -> mm.Vec3 {
    return origin+{-30+f32(i%12)*5+f32((i/36)%4)*0.6,0.05,32-f32((i/12)%3)*2}
}

// A zombie, or a drone with the mind of the zombies: it wanders, chases what it sees or hears, bites what it reaches.
@(private)
arena_zombie :: proc(c:core.Commands,e:core.Entity,sight:f32,hearing:f32=1,forget:f32=8) {
    core.commands_add(c,e,Zombie{})
    core.commands_add(c,e,behavior.Mind_Agent{mind=behavior.mind_name("zombie")})
    core.commands_add_default(c,e,behavior.Mind_Presentation)
    perceiver:=behavior.PERCEIVER_DEFAULT
    perceiver.notices=behavior.Teams(1<<u32(TEAM_RUNNER))
    perceiver.sight,perceiver.hearing,perceiver.forget=sight,hearing,forget
    core.commands_add(c,e,perceiver)
}

// The agents of an arena around its origin.
@(private)
arena_agents :: proc(c:core.Commands,kind:Arena_Kind,origin:mm.Vec3,count:int) {
    switch kind {
    case .Horde:
        arena_target(c,origin+{-22,0,-22},TEAM_RUNNER)
        for i in 0..<count {
            spot:mm.Vec3
            if i%2==0 {
                x,z:=(i/2)%3,(i/2)/3%3
                height:=f32(3.5 if (x+z)%2==0 else 4.5)
                spot=origin+{f32(x-1)*10.5+f32((i/18)%4)-1.5,height+0.05,f32(z-1)*10.5+f32((i/72)%4)-1.5}
            } else {
                k:=i/2
                spot=origin+{-30+f32(k%12)*5,0.05,30-f32((k/12)%3)*2}
            }
            arena_zombie(c,arena_body(c,spot,{0.45,0.75,0.35,1},3.5),25)
        }
    case .Firefight:
        count:=max(count,1)
        for team in 0..<2 {
            for i in 0..<count {
                side:=f32(-1 if team==0 else 1)
                e:=arena_body(c,origin+{f32(i)*2.5-f32(count)*1.25,0.05,side*18},{0.9,0.3,0.25,1} if team==0 else {0.3,0.45,0.9,1},4.5)
                core.commands_add(c,e,Soldier{health=100,ammo=SOLDIER_MAG,reserve=SOLDIER_MAG,ahead=-side})
                core.commands_add(c,e,behavior.Mind_Agent{mind=behavior.mind_name("soldier")})
                core.commands_add_default(c,e,behavior.Mind_Presentation)
                mine,theirs:=TEAM_RED,TEAM_BLUE
                if team==1 {mine,theirs=TEAM_BLUE,TEAM_RED}
                perceiver:=behavior.PERCEIVER_DEFAULT
                perceiver.notices=behavior.Teams(1<<u32(theirs))
                perceiver.sight=40
                perceiver.angle=1.4
                core.commands_add(c,e,perceiver)
                core.commands_add(c,e,behavior.Perceivable{team=mine,point=1.2})
            }
        }
    case .Boss:
        hero:=arena_target(c,origin+{0,0.05,8},TEAM_RUNNER)
        boss:=arena_body(c,origin+{0,0.05,-6},{0.6,0.15,0.6,1},3)
        core.commands_add(c,boss,Boss{health=BOSS_HEALTH,hero=hero})
        core.commands_add(c,boss,behavior.Mind_Agent{mind=behavior.mind_name("boss")})
        core.commands_add_default(c,boss,behavior.Mind_Presentation)
    case .Swarm:
        arena_target(c,origin+{-22,0,-22},TEAM_RUNNER)
        for i in 0..<count {arena_zombie(c,arena_drone(c,origin+{f32(i%8)*4-14,4+f32((i/8)%3)*3,8+f32(i/24)*3}),30)}
    case .Paths:
        // Up the ladder, off the platform by a drop, past the blocked area, over the fence and through the lane of the cart.
        points:=[4][3]f32{origin+{-15,0,-10},origin+{-7,3.5,1},origin+{17,0,10},origin+{17,0,-10}}
        for i in 0..<max(count,1) {
            e:=arena_body(c,origin+{-15+f32(i%4)*1.5,0.05,-12+f32(i/4)*1.5},{0.85,0.75,0.3,1},3.5)
            agent:=core.default(c,nav.Nav_Agent)
            agent.abilities=nav.Nav_Abilities(1<<u32(nav.ABILITY_LADDER))
            core.commands_add(c,e,agent)
            core.commands_add(c,e,Arena_Patrol{points=points,next=i32(i%4)})
            core.commands_add(c,e,behavior.Mind_Agent{mind=behavior.mind_name("guard")})
            core.commands_add_default(c,e,behavior.Mind_Presentation)
        }
    case .Senses:
        // Bells ring in turn behind the walls; listeners that barely see go to what they hear and forget it.
        corners:=[4]mm.Vec3{{-12,0,-12},{12,0,-12},{12,0,12},{-12,0,12}}
        for corner,i in corners {
            bell:=core.commands_create(c)
            core.commands_add(c,bell,core.Transform{origin+corner,1,{1,1,1}})
            core.commands_add(c,bell,Arena_Bell{turn=i32(i),count=4,period=6,loudness=12})
            core.commands_add(c,bell,render.Mesh_Renderer{shape=.Sphere})
            core.commands_add(c,bell,render.Tint{color={1,0.85,0.2,1}})
        }
        for i in 0..<max(count,1) {
            s,co:=mm.sincos_det(f32(i)/f32(max(count,1))*2*math.PI)
            arena_zombie(c,arena_body(c,origin+{co*3,0.05,s*3},{0.6,0.4,0.85,1},3),4,hearing=2.5,forget=5)
        }
    }
}

// A drone: a small capsule that flies, with a class of the air.
@(private)
arena_drone :: proc(c:core.Commands,position:mm.Vec3) -> core.Entity {
    e:=core.commands_create(c)
    core.commands_add(c,e,core.Id{core.id_next(c.entities)})
    core.commands_add(c,e,core.Transform{position,1,{1,1,1}})
    core.commands_add_default(c,e,phys.Character)
    locomotion:=core.default(c,phys.Locomotion)
    locomotion.mode=phys.MODE_FLYING
    core.commands_add(c,e,locomotion)
    core.commands_add(c,e,phys.collider_character(0.25,0.8))
    core.commands_add_default(c,e,phys.Walk)
    core.commands_add(c,e,phys.Fly{speed=5,acceleration=20})
    core.commands_add_default(c,e,nav.Nav_Agent)
    look:=core.commands_create(c)
    core.commands_add(c,look,core.Transform{{0,0.4,0},1,{0.5,0.4,0.5}})
    core.commands_add(c,look,core.Parent{entity=e})
    core.commands_add(c,look,render.Mesh_Renderer{shape=.Capsule})
    core.commands_add(c,look,render.Tint{color={0.95,0.6,0.2,1}})
    return e
}

// The carts drive and park; the bells ring.
@(step="fixed",server)
arena_carts :: proc(carts:core.Read(Arena_Cart),bodies:^phys.Body_Requests,bells:core.Read(Arena_Bell),worlds:core.Read(core.World_Transform),noises:^behavior.Noises,time:core.Time) {
    if !time.playing || time.dt<=0 {return}
    // Every cart is at the same point of its cycle.
    t:=f32(math.mod(time.seconds,f64(2*(ARENA_CART_DRIVE+ARENA_CART_WAIT))))
    along:f32
    switch {
    case t<ARENA_CART_WAIT: along=0
    case t<ARENA_CART_WAIT+ARENA_CART_DRIVE: along=(t-ARENA_CART_WAIT)/ARENA_CART_DRIVE
    case t<2*ARENA_CART_WAIT+ARENA_CART_DRIVE: along=1
    case: along=1-(t-2*ARENA_CART_WAIT-ARENA_CART_DRIVE)/ARENA_CART_DRIVE
    }
    along=along*along*(3-2*along)
    for cart,row in carts.table.values[:core.count(carts)] {
        phys.move_kinematic(bodies,core.entity_at(carts,row),cart.from+(cart.to-cart.from)*along)
    }
    for bell,row in bells.table.values[:core.count(bells)] {
        if bell.count<=0 || !(bell.period>0) {continue}
        slot:=u64(time.seconds/f64(bell.period))
        if slot%u64(bell.count)!=u64(bell.turn) {continue}
        e:=core.entity_at(bells,row)
        if pose,ok:=core.get(worlds,e);ok {behavior.noise(noises,pose.position,bell.loudness,e)}
    }
}

// The runner walks its round; the hero walks around the boss.
@(step="fixed",server)
arena_targets :: proc(
    targets:^core.Table(Arena_Target),bosses:core.Read(Boss),
    paths:core.Read(nav.Nav_Path),requests:^nav.Nav_Requests,
    state:^Arena_State,time:core.Time,
) {
    if !time.playing || time.dt<=0 {return}
    if !state.seeded {state.rng,state.seeded=mm.rng_make(17),true}
    round:=[4]mm.Vec3{{-22,0,-22},{22,0,-22},{22,0,22},{-22,0,22}}
    for row in 0..<core.count(targets) {
        e:=core.entity_at(targets,row)
        t:=core.edit_at(targets,row)
        p,ok:=core.get(paths,e)
        hunting:=false
        for b in bosses.table.values[:core.count(bosses)] {hunting|=b.hero==e}
        if hunting {
            if core.due(time,t.again) {
                t.again=core.deadline(time,2.5)
                angle:=mm.random_range(&state.rng,0,2*math.PI)
                s,c:=mm.sincos_det(angle)
                nav.nav_move_to(requests,e,t.center+{0,0,-14}+{c,0,s}*6)
            }
            continue
        }
        if !ok || p.state==.Idle || p.state==.Arrived || p.state==.Failed {
            t.next=(t.next+1)%4
            nav.nav_move_to(requests,e,t.center+{22,0,22}+round[t.next])
        }
    }
}

// The agents of the arenas decide, each kind with its mind. The hero hurts
// the boss near it and staggers it now and then; a fallen boss rises again
// after a while.
@(step="fixed",server)
arena_think :: proc(
    world:behavior.Mind_World,zombies:^core.Table(Zombie),soldiers:^core.Table(Soldier),bosses:^core.Table(Boss),patrols:^core.Table(Arena_Patrol),
    flights:core.Read(phys.Fly),placer:core.Placer,physics:core.Ref(phys.Physics_State),state:^Arena_State,
) {
    minds,agents,time,problems:=world.minds,world.agents,world.time,world.problems
    if !time.playing || time.dt<=0 || core.count(agents)==0 {return}
    if !state.seeded {state.rng,state.seeded=mm.rng_make(17),true}
    w:=Arena_Tick{
        tick=behavior.mind_tick(world),placer=placer,
        zombies=zombies,soldiers=soldiers,bosses=bosses,patrols=patrols,flights=flights,physics=physics,rng=&state.rng,
    }
    for row in 0..<core.count(bosses) {
        e:=core.entity_at(bosses,row)
        b:=core.edit_at(bosses,row)
        if b.health<=0 {
            if b.rises==0 {b.rises=core.deadline(time,3);b.deaths+=1}
            if core.due(time,b.rises) {b.health,b.rises=BOSS_HEALTH,0}
            continue
        }
        if linalg.length(arena_position(&w,e)-arena_position(&w,b.hero))<12 {
            b.health-=6*time.dt
            if every:=core.ticks_of(time,3);every>0 && time.tick%every==0 {b.staggered=true}
        }
    }
    ctx:=ai.Mind_Context{user=&w,keep=0.05,reservations=&world.claims.reservations}
    behavior.minds_tick(minds,agents,"zombie",&ZOMBIE_ACTS,zombie_think,&ctx,&w.act,time,problems)
    behavior.minds_tick(minds,agents,"soldier",&SOLDIER_ACTS,soldier_think,&ctx,&w.act,time,problems)
    behavior.minds_tick(minds,agents,"boss",&BOSS_ACTS,boss_think,&ctx,&w.act,time,problems)
    behavior.minds_tick(minds,agents,"guard",&GUARD_ACTS,guard_think,&ctx,&w.act,time,problems)
    behavior.minds_unknown(minds,agents,problems)
}
