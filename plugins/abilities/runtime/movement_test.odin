package abilities

import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:std/base"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// Movement abilities written as data over physics and locomotion: what a game's economy asks of
// its characters (a sprint that spends energy, a jump off a ledge) is an Ability sheet, and the
// locomotion plugin holds no such rules.

@(private="file") ENERGY :: Ability_Attribute(1)
@(private="file") SPEED :: Ability_Attribute(2)
@(private="file") JUMP_ATTR :: Ability_Attribute(3)
@(private="file") ACCEL_ATTR :: Ability_Attribute(4)
@(private="file") SPRINT :: 0
@(private="file") LEDGE_JUMP :: 1
@(private="file") TABLE :: base.Asset_Id{9,9}
@(private="file") JUMP :: inp.Action_Mask(1) // Walk_Action.Jump with the actions from 0

@(private)
@(test_world)
Movement_World :: struct {
    using world:Test_World,
    using physics:phys.Test_Physics,
    users:core.Table(Ability_User),
    states:core.Table(Ability_State),
    tracking:core.Table(Ability_Tracking),
    loco_states:core.Table(locomotion.Locomotion_State),
    inputs:core.Table(inp.Move_Input),
    walks:core.Table(locomotion.Walk),
    flights:core.Table(locomotion.Fly),
    swims:core.Table(locomotion.Swim),
    remotes:core.Table(core.Remote),
    paces:core.Table(core.Own_Pace),
    loco_requests:locomotion.Locomotion_Requests,
    ability_requests:Ability_Requests,
    animations:anim.Animation_Requests,
    places:core.Places,
}

@(private="file")
Movement :: struct {
    using w:Movement_World,
    using host:phys.Test_Physics_Host,
    cache:Ability_Sheets,
    checks:Ability_Attributes,
    sheets:[2]Ability,
    rows:[2]core.Record_Row,
    index:[2]u32,
    set:core.Record_Set,
    time:core.Time,
    e:core.Entity,
}

// A runner with a Walk and an Ability_User with energy and a speed attribute, and the two sheets: a
// sprint that runs 40% faster for 15 energy a second while energy lasts, and a jump off a ledge that
// needs 6 m/s and the ground falling away by 1.9 m within 1.5 m ahead and adds 8 m/s forward on
// top of the jump for 0.2 s.
@(private="file")
movement_init :: proc(t:^testing.T,f:^Movement,position:[3]f32) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.settings={bodies=32,shapes=32,contacts=256,joints=4,characters=4}
    f.gravity={0,-9.81,0}
    walking:=Ability_Modes(1<<u32(locomotion.MODE_WALKING))
    f.sheets[SPRINT]={duration=100,modes=walking}
    f.sheets[SPRINT].conditions[0]={attribute=ENERGY,at_least=10}
    f.sheets[SPRINT].costs[0]={attribute=ENERGY,per_second=15}
    f.sheets[SPRINT].windows[0]={from=0,to=100,modify={attribute=SPEED,more=0.4}}
    f.sheets[LEDGE_JUMP]={duration=0.2,modes=walking}
    f.sheets[LEDGE_JUMP].conditions[0]={kind=.Speed,at_least=6}
    f.sheets[LEDGE_JUMP].conditions[1]={kind=.Ledge_Ahead,reach=1.5,at_least=1.9}
    f.sheets[LEDGE_JUMP].windows[0]={from=0,to=0.2,move={velocity={0,0,-8},mix=.Additive}}
    for i in 0..<2 {f.rows[i],f.index[i]={table=TABLE,row=core.Record_Id(i+1)},u32(i)}
    f.set={size=size_of(Ability),rows=f.rows[:],index=f.index[:],values=mem.slice_to_bytes(f.sheets[:])}
    f.e=core.create(&f.entities)
    core.add(&f.transforms,f.e,core.Transform{position,1,{1,1,1}})
    core.add(&f.colliders,f.e,phys.collider_character())
    core.add(&f.characters,f.e,phys.character_default())
    walk:=locomotion.WALK_DEFAULT
    walk.turn_speed=0
    core.add(&f.walks,f.e,walk)
    core.add(&f.inputs,f.e,inp.Move_Input{})
    user:=Ability_User{speed=SPEED}
    user.attributes[0]={attribute=ENERGY,base=30,max=30,regen=5}
    user.attributes[1]={attribute=SPEED,base=1}
    core.add(&f.users,f.e,user)
    f.time={tick=1,dt=1.0/60,playing=true}
    test_world_settle(&f.w)
    ability_rows({&f.users,&f.states,&f.tracking},&f.checks,&f.problems)
    test_world_settle(&f.w)
    return true
}

@(private="file")
movement_destroy :: proc(f:^Movement) {
    core.value_free(&f.cache,type_info_of(Ability_Sheets))
    core.entity_map_destroy(&f.checks.entries)
    phys.test_host_destroy(&f.host)
    test_world_destroy(&f.w)
}

@(private="file")
movement_box :: proc(f:^Movement,half,position:[3]f32) {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,1,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_box(half))
}

@(private="file")
movement_world :: proc(f:^Movement) -> Ability_World {
    return {time=f.time,characters=core.read(&f.characters),locomotions=core.read(&f.loco_states),grounds=core.read(&f.character_states),
        motions=core.read(&f.bodies),worlds=core.read(&f.worlds),remotes=core.read(&f.remotes),paces=core.read(&f.paces),clock=core.CLOCK_DEFAULT,
        physics=core.ref(&f.state),moves=&f.loco_requests,animations=&f.animations,problems=&f.problems}
}

// Ticks of the loop: abilities, then locomotion, then physics, with the runner asked to go along
// move in the axes of its look with buttons held.
@(private="file")
movement_tick :: proc(f:^Movement,move:[3]f32,ticks:=1,buttons:=inp.Action_Mask(0)) {
    actions:=inp.Input_Of(locomotion.Walk_Action){}
    for _ in 0..<ticks {
        core.edit(&f.inputs,f.e)^={move=move,buttons=buttons}
        test_world_settle(&f.w)
        w:=movement_world(f)
        abilities_tick({&f.users,&f.states,&f.tracking},{abilities={&f.set}},&f.cache,&f.checks,&f.ability_requests,nil,&w,physics_overlap)
        test_world_settle(&f.w)
        locomotion.locomotion_prepare(core.read(&f.characters),core.read(&f.colliders),&f.loco_states,&f.moves,&f.inputs,
            core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),&f.loco_requests,f.time,&f.problems)
        test_world_settle(&f.w)
        locomotion.locomotion_step(core.read(&f.characters),&f.loco_states,&f.moves,&f.inputs,core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),
            core.read(&f.character_states),core.read(&f.bodies),core.read(&f.transforms),core.read(&f.parents),core.read(&f.remotes),core.ref(&f.state),
            core.ref(&f.places),core.read(&f.paces),actions,f.time,core.CLOCK_DEFAULT,&f.problems)
        test_world_settle(&f.w)
        phys.test_step(&f.physics,&f.host,f.time.dt)
        test_world_settle(&f.w)
        core.time_advance(&f.time)
    }
}

@(private="file")
flat_speed :: proc(f:^Movement) -> f32 {
    motion,_:=core.get(&f.bodies,f.e)
    return linalg.length(motion.linear.xz)
}

@(private="file")
energy :: proc(f:^Movement) -> f32 {
    user,_:=core.get(&f.users,f.e)
    return user.attributes[0].base
}

@(private="file")
running :: proc(f:^Movement) -> bool {
    state,_:=core.get(&f.states,f.e)
    return state.ability!={}
}

// A tactical sprint as data: started on the ground with at least 10 energy, its window raises the
// speed attribute by 40%, which scales the locomotion of the runner, and it spends 15 energy a
// second against a regen of 5 until energy cannot pay a tick, when it completes and the runner
// runs at its own speed again while energy comes back.
@(test)
a_tactical_sprint_is_an_ability_that_spends_energy_for_speed_and_recharges :: proc(t:^testing.T) {
    f:=new(Movement)
    defer free(f)
    if !movement_init(t,f,{0,0,40}) {return}
    defer movement_destroy(f)
    movement_box(f,{50,1,50},{0,-1,0})
    movement_tick(f,{0,0,-1},60)
    walk:=locomotion.WALK_DEFAULT
    testing.expectf(t,abs(flat_speed(f)-walk.max_speed)<0.05,"it runs at its walk: %v",flat_speed(f))
    ability_use(&f.ability_requests,f.e,{TABLE,core.Record_Id(SPRINT+1)})
    movement_tick(f,{0,0,-1},60)
    loco,_:=core.get(&f.loco_states,f.e)
    testing.expect(t,running(f),"the sprint runs")
    testing.expectf(t,abs(loco.speed_scale-1.4)<1e-4 && abs(flat_speed(f)-walk.max_speed*1.4)<0.05,"its speed attribute scales its walk: %v at %v",loco.speed_scale,flat_speed(f))
    testing.expectf(t,abs(energy(f)-(30-10))<0.5,"a second costs 15 less a regen of 5: %v",energy(f))
    movement_tick(f,{0,0,-1},150)
    testing.expect(t,!running(f),"it completes when energy cannot pay")
    loco,_=core.get(&f.loco_states,f.e)
    testing.expectf(t,loco.speed_scale==1 && abs(flat_speed(f)-walk.max_speed)<0.05,"back at its own speed: %v at %v",loco.speed_scale,flat_speed(f))
    low:=energy(f)
    ability_use(&f.ability_requests,f.e,{TABLE,core.Record_Id(SPRINT+1)})
    movement_tick(f,{0,0,-1},1)
    testing.expect(t,!running(f),"under 10 energy it does not start")
    movement_tick(f,{0,0,-1},59)
    testing.expectf(t,abs(energy(f)-low-5)<0.2,"energy comes back at its regen: %v from %v",energy(f),low)
    testing.expect_value(t,f.problems.count,0)
}

// A ledge jump as data: running at 6 m/s or more with the ground falling away 1.9 m within 1.5 m
// ahead, the ability starts with the jump and its window adds 8 m/s forward on top of it. Far from the edge, or over a lower drop, the condition does not hold and a jump is a jump.
@(test)
a_ledge_jump_is_an_ability_with_a_ledge_ahead_condition_and_a_layered_boost :: proc(t:^testing.T) {
    Case :: struct {drop:f32,ready:bool}
    for c in ([2]Case{{drop=3,ready=true},{drop=1}}) {
        f:=new(Movement)
        defer free(f)
        if !movement_init(t,f,{0,0,10}) {return}
        defer movement_destroy(f)
        movement_box(f,{5,0.5,15},{0,-0.5,0})            // its top at 0, its edge at z -15
        movement_box(f,{20,0.5,40},{0,-c.drop-0.5,-30}) // the ground under it
        core.edit(&f.walks,f.e).sprint_speed=7
        core.edit(&f.walks,f.e).sprint_default=true
        movement_tick(f,{},20)
        ledge:=&f.sheets[LEDGE_JUMP]
        ready_at:=f32(0)
        ready:=false
        for _ in 0..<300 {
            movement_tick(f,{0,0,-1})
            pose,_:=core.get(&f.transforms,f.e)
            w:=movement_world(f)
            user,_:=core.get(&f.users,f.e)
            state,_:=core.get(&f.states,f.e)
            ready=condition_holds(&w,f.e,&user,&state,ledge.conditions[0]) && condition_holds(&w,f.e,&user,&state,ledge.conditions[1])
            if pose.position.z>-10 {testing.expectf(t,!ready,"%v: no ledge far from the edge, at z %v",c,pose.position.z)}
            if ready || pose.position.z< -14.8 {ready_at=pose.position.z;break}
        }
        testing.expectf(t,ready==c.ready,"%v: ready %v at z %v",c,ready,ready_at)
        if c.ready {testing.expectf(t,ready_at< -15+1.5+0.05 && ready_at> -15+1.5-0.25,"%v: ready 1.5 m before the edge, at z %v",c,ready_at)}
        before:=flat_speed(f)
        ability_use(&f.ability_requests,f.e,{TABLE,core.Record_Id(LEDGE_JUMP+1)})
        movement_tick(f,{0,0,-1},1,JUMP)
        movement_tick(f,{0,0,-1},1)
        testing.expect_value(t,running(f),c.ready)
        motion,_:=core.get(&f.bodies,f.e)
        testing.expectf(t,abs(motion.linear.y-4.852)<0.4,"%v: it jumps as its walk does, at %v",c,motion.linear.y) // sqrt(2 g jump_height) of WALK_DEFAULT
        if c.ready {
            testing.expectf(t,abs(flat_speed(f)-(before+8))<0.3,"%v: launched at %v from %v",c,flat_speed(f),before)
        } else {
            testing.expectf(t,abs(flat_speed(f)-before)<0.2,"%v: a plain jump keeps its speed %v: %v",c,before,flat_speed(f))
        }
        testing.expect_value(t,f.problems.count,0)
    }
}

// End-to-end tactical sprint expressed 100% in pure ability data:
// 115 energy, 15/s drain paused while airborne with fall_grace, 52/s regen after 2 s regen_delay,
// ramped 1.4x speed (0.6224 s), ramped 1.2x jump (0.7265 s), and 3x acceleration.
@(test)
a_tactical_sprint_runs_entirely_from_ability_data :: proc(t:^testing.T) {
    f:=new(Movement);defer free(f)
    if !movement_init(t,f,{0,0,40}) {return}
    defer movement_destroy(f)
    // High ledge (y=0, z in [5, 45]) and a deep floor below (-20) to test fall_grace off a cliff.
    movement_box(f,{20,1,20},{0,-1,25})
    movement_box(f,{50,1,50},{0,-21,-40})

    walking:=Ability_Modes(1<<u32(locomotion.MODE_WALKING))
    sprint:=&f.sheets[SPRINT]
    sprint^={duration=100,modes=walking}
    sprint.conditions[0]={attribute=ENERGY,at_least=10}
    sprint.costs[0]={attribute=ENERGY,per_second=15,pause_falling=true,fall_grace=0.7}
    sprint.windows[0]={from=0,to=100,modify={attribute=SPEED,more=0.4,ramp_in=0.6224}}
    sprint.windows[1]={from=0,to=100,modify={attribute=JUMP_ATTR,more=0.2,ramp_in=0.7265}}
    sprint.windows[2]={from=0,to=100,modify={attribute=ACCEL_ATTR,more=2.0}}

    u:=core.edit(&f.users,f.e)
    u.speed,u.jump,u.acceleration=SPEED,JUMP_ATTR,ACCEL_ATTR
    u.attributes[0]={attribute=ENERGY,base=115,max=115,regen=52,regen_delay=2.0}
    u.attributes[1]={attribute=SPEED,base=1}
    u.attributes[2]={attribute=JUMP_ATTR,base=1}
    u.attributes[3]={attribute=ACCEL_ATTR,base=1}
    test_world_settle(&f.w)

    // Settle on ground and start sprint.
    movement_tick(f,{0,0,-1},30)
    ability_use(&f.ability_requests,f.e,{TABLE,core.Record_Id(SPRINT+1)})
    movement_tick(f,{0,0,-1},1)
    testing.expect(t,running(f),"tactical sprint started")
    loco,_:=core.get(&f.loco_states,f.e)
    testing.expectf(t,abs(loco.acceleration_scale-3.0)<1e-4,"3x acceleration immediate: %v",loco.acceleration_scale)

    // Mid-ramp (~0.3 s): speed and jump are strictly between 1.0 and their targets.
    movement_tick(f,{0,0,-1},18)
    loco,_=core.get(&f.loco_states,f.e)
    testing.expectf(t,loco.speed_scale>1.15 && loco.speed_scale<1.25,"mid-ramp speed_scale: %v",loco.speed_scale)
    testing.expectf(t,loco.jump_scale>1.06 && loco.jump_scale<1.12,"mid-ramp jump_scale: %v",loco.jump_scale)

    // Past both ramps (total 1.0 s): full 1.4x speed, 1.2x jump, 3x accel; ~15 energy drained with
    // zero regen fighting it because regen_delay=2.0.
    movement_tick(f,{0,0,-1},41)
    loco,_=core.get(&f.loco_states,f.e)
    walk:=locomotion.WALK_DEFAULT
    testing.expectf(t,abs(loco.speed_scale-1.4)<1e-4 && abs(flat_speed(f)-walk.max_speed*1.4)<0.05,"full speed_scale %v at %v m/s",loco.speed_scale,flat_speed(f))
    testing.expectf(t,abs(loco.jump_scale-1.2)<1e-4,"full jump_scale: %v",loco.jump_scale)
    testing.expectf(t,abs(energy(f)-(115-15))<0.5,"1 s drained 15 energy without regen: %v",energy(f))

    // Jump while sprinting: boosted apex (~1.44 * 1.2 = 1.728 m), drain pauses in the air, sprint survives landing.
    energy_before_jump:=energy(f)
    apex:f32
    air_ticks:=0
    for i in 0..<90 {
        movement_tick(f,{0,0,-1},1,JUMP if i==0 else 0)
        pose,_:=core.get(&f.transforms,f.e)
        apex=max(apex,pose.position.y)
        ground,_:=core.get(&f.character_states,f.e)
        if !ground.standing {air_ticks+=1}
        if i>10 && ground.standing {break}
    }
    testing.expect(t,running(f),"sprint survives normal jump")
    testing.expectf(t,apex>1.6 && apex<1.85,"boosted jump apex %v m (normal 1.2 m)",apex)
    testing.expect(t,air_ticks>50,"spent substantial ticks airborne")
    // Energy barely dropped (only the 1-2 ground ticks around takeoff/landing), not ~1.1s * 15 = 16.5!
    testing.expectf(t,energy_before_jump-energy(f)<1.5,"drain paused while airborne: lost %v over %d air ticks",energy_before_jump-energy(f),air_ticks)

    // Run off the ledge (z = -5) and fall past fall_grace (0.7 s): sprint completes cleanly and scales reset to 1.0.
    for _ in 0..<240 {
        movement_tick(f,{0,0,-1},1)
        if !running(f) {break}
    }
    testing.expect(t,!running(f),"falling past fall_grace ended tactical sprint")
    loco,_=core.get(&f.loco_states,f.e)
    testing.expectf(t,abs(loco.speed_scale-1)<1e-4 && abs(loco.jump_scale-1)<1e-4 && abs(loco.acceleration_scale-1)<1e-4,"scales reset to 1 after sprint ends: %v %v %v",loco.speed_scale,loco.jump_scale,loco.acceleration_scale)

    // Energy waits for the full 2.0 s regen_delay (counting from last ground drain before cliff) before regenerating at 52/s.
    e_after_end:=energy(f)
    movement_tick(f,{},45) // ~0.75 s after fall_grace (total ~1.45 s since last spend < 2.0 s)
    testing.expectf(t,abs(energy(f)-e_after_end)<1e-3,"still waiting on regen_delay: %v vs %v",energy(f),e_after_end)
    movement_tick(f,{},90) // +1.5 s: well past 2.0 s delay -> regenerates strongly at 52/s
    testing.expectf(t,energy(f)>e_after_end+30,"regen resumed at 52/s after regen_delay: %v from %v",energy(f),e_after_end)
    testing.expect_value(t,f.problems.count,0)
}
