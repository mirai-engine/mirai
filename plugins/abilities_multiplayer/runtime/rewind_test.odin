package abilities_multiplayer

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:std/base"
import ab "plugins:abilities/runtime"
import anim "plugins:animation/runtime"
import multiplayer "plugins:multiplayer/runtime"
import phys "plugins:physics/runtime"

@(private)
@(test_world)
Rewind_Test_World :: struct {
    using world:Test_World,
    marked:core.Table(multiplayer.Rewind),
    zone_sets:core.Table(anim.Hit_Zone_Set),
    zone_poses:core.Table(anim.Hit_Zone_Pose),
}

@(private="file") ZONE_TABLE :: base.Asset_Id{9,1}
@(private="file") RATE :: 60

// A player 100 ms behind the server (6 ticks at 60 Hz) saw a target that runs along +X at 10 m/s
// where it was then: its shot at that place hits its zone, and its shot at where the target is now
// misses it, through the collider the target has now. Judged now, the other way round.
@(test)
a_shooter_behind_hits_where_the_target_was :: proc(t:^testing.T) {
    w:Rewind_Test_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    physics:phys.Physics_State
    if !testing.expect(t,phys.test_state_make(&physics)) {return}
    defer phys.state_destroy(&physics)
    history:Zone_History
    defer zone_history_free(&history)
    if !testing.expect(t,zone_history_make(&history,32,4,context.allocator)) {return}
    zones:[1]anim.Hit_Zones
    zones[0].zones[0]={shape=.Capsule,size={0.3,0.6,0}}
    rows:=[1]core.Record_Row{{table=ZONE_TABLE,row=1}}
    index:=[1]u32{0}
    set:=core.Record_Set{size=size_of(anim.Hit_Zones),rows=rows[:],index=index[:],values=mem.slice_to_bytes(zones[:])}
    target,shooter:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.marked,target,multiplayer.Rewind{})
    core.add(&w.zone_sets,target,anim.Hit_Zone_Set{zones={ZONE_TABLE,1}})
    core.add(&w.zone_poses,target,anim.Hit_Zone_Pose{placed_bits=1})
    test_world_settle(&w)
    NOW :: u64(100)
    problems:core.Problems
    at :: proc(tick:u64) -> [3]f32 {return {f32(tick-90)*10.0/RATE,1,-10}}
    for tick in u64(90)..=NOW {
        core.edit(&w.zone_poses,target).placed[0]={at(tick),1}
        zones_record(&history,tick,core.read(&w.marked),core.read(&w.zone_poses),&problems)
    }
    // Its collider is where it is now.
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    body,_:=phys.owned_body_create(&physics,{1,target,0},at(NOW),1)
    phys.owned_shape_create(&physics,&collision,body,{collider=phys.collider_capsule(0.3,0.6),rotation=1})
    rw:=Rewind_World{
        marked=core.read(&w.marked),physics=core.ref(&physics),zone_sets=core.read(&w.zone_sets),
        zone_poses=core.read(&w.zone_poses),zones={&set},history=core.ref(&history),
    }
    Case :: struct {aimed_at:u64,judged:f64,hits:bool}
    for c in ([]Case{{94,94,true},{NOW,94,false},{NOW,f64(NOW),true},{94,f64(NOW),false}}) {
        shot:=ab.Ability_Shot{user=shooter,aim=shooter,origin={at(c.aimed_at).x,1,0},direction={0,0,-1},range=50}
        hit:=shot_rewind(&rw,&shot,c.judged)
        testing.expectf(t,(hit.entity==target)==c.hits,"aimed at tick %d, judged at %v: %v",c.aimed_at,c.judged,hit)
        if c.hits {testing.expectf(t,hit.zone==0 && abs(hit.point.z+9.7)<1e-3,"%v: at the front of its zone: %v",c,hit)}
    }
    // Between two ticks it is between their places.
    zones_now,found:=zones_at(&history,target,97.5)
    testing.expect(t,found && abs(zones_now.placed[0].position.x-at(97).x-5.0/RATE)<1e-4)
    testing.expect_value(t,problems.count,0)
}

// Without zones nothing is recorded or allocated, and without pellets nothing is judged.
@(test)
without_zones_or_pellets_lag_compensation_does_nothing :: proc(t:^testing.T) {
    w:Rewind_Test_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    history:Zone_History
    problems:core.Problems
    saved:=context
    context.allocator,context.temp_allocator=runtime.nil_allocator(),runtime.nil_allocator()
    abilities_rewind_record({},{tick=5,dt=1.0/RATE},core.read(&w.marked),core.read(&w.zone_poses),{},&history,context.allocator,&problems)
    shots:ab.Ability_Shots
    abilities_rewind(&shots,{marked=core.read(&w.marked),history=core.ref(&history)})
    context=saved
    testing.expect(t,history.frames==nil && problems.count==0)
}
