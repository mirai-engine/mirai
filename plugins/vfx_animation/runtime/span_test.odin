package vfx_animation

import "core:mem"
import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import vfx "plugins:vfx/runtime"

@(private)
@(test_world)
Span_World :: struct {
    using world:Test_World,
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    animations:core.Table(anim.Animation),
    emitters:core.Table(vfx.Particle_Emitter),
    overrides:core.Table(vfx.Particle_Override),
    listeners:core.Table(vfx.Particle_Channel),
    spans:core.Table(Particle_Animation_Span),
    hierarchy:core.Hierarchy,
    births:core.Births,
    clocks:vfx.Particle_Clocks,
    requests:vfx.Particle_Requests,
    events:anim.Animation_Events,
    span_state:Particle_Span_State,
}

@(private="file")
Span_Fixture :: struct {
    using w:Span_World,
    births_cursor:u64,
    sync:vfx.Particle_Sync,
    sources:scene.Simulation_Sources,
    problems:core.Problems,
}

@(private="file")
span_fixture_init :: proc(t:^testing.T,f:^Span_Fixture) -> bool {return test_world_init(t,&f.w)}

@(private="file")
span_fixture_destroy :: proc(f:^Span_Fixture) {
    vfx.particle_sync_free(&f.sync)
    test_world_destroy(&f.w)
}

@(private="file")
span_fixture_tick :: proc(f:^Span_Fixture,time:core.Time) {
    vfx_animation_spans(core.read(&f.spans),core.read(&f.emitters),core.read(&f.animations),
        core.read(&f.parents),core.ref(&f.entities),core.ref(&f.events),&f.span_state,&f.requests,time)
    births:=f.births
    core.events_read(&births.log,&f.births_cursor)
    vfx.particles_tick(&f.emitters,&f.overrides,core.read(&f.worlds),core.ref(&f.hierarchy),
        core.commands_of(test_world_ref(&f.w)),&f.clocks,&f.sync,&f.requests,core.ref(&births),
        core.read(&f.listeners),time,{dt=time.dt,alpha=1},nil,&f.problems,core.ref(&f.sources))
    core.events_age(&f.births.log)
    test_world_settle(&f.w)
    clear(&f.events.items)
}

@(private="file")
make_span_config :: proc(span:string,end_marker:string="",action:string="",source:=core.NONE,restart:=false) -> (cfg:Particle_Animation_Span) {
    cfg.source=source
    cfg.restart_on_begin=restart
    base.text_set(cfg.span[:],span)
    base.text_set(cfg.end_marker[:],end_marker)
    base.text_set(cfg.action[:],action)
    return
}

// Table-driven check covering duration spans (.Span_Begin/.Span_End), paired
// point markers (e.g. FortMeleeAnimTrails_On/Off), action filtering, ancestor
// and explicit source resolution, overlapping spans, and interruption cleanup.
@(test)
animation_spans_and_paired_markers_start_and_stop_emitters :: proc(t:^testing.T) {
    Step_Event :: struct {
        kind:anim.Animation_Event_Kind,
        name:string,
        action:string,
        want_active:bool,
    }
    Case :: struct {
        name:string,
        hierarchy:enum {Self,Child,Explicit},
        span,end_marker,action:string,
        restart:bool,
        steps:[]Step_Event,
    }

    duration_steps:=[?]Step_Event{
        {.Span_Begin,"other_span","slash",false},
        {.Span_Begin,"melee_trail","slash",true},
        {.Span_End,"melee_trail","slash",false},
    }
    paired_steps:=[?]Step_Event{
        {.Marker,"FortMeleeAnimTrails_On","swing",true},
        {.Marker,"other_marker","swing",true},
        {.Marker,"FortMeleeAnimTrails_Off","swing",false},
    }
    action_filtered_steps:=[?]Step_Event{
        {.Span_Begin,"melee_trail","light_attack",false},
        {.Span_Begin,"melee_trail","heavy_attack",true},
        {.Interrupted,"","light_attack",true},
        {.Interrupted,"","heavy_attack",false},
    }
    overlap_steps:=[?]Step_Event{
        {.Span_Begin,"melee_trail","combo",true},
        {.Span_Begin,"melee_trail","combo",true},
        {.Span_End,"melee_trail","combo",true},
        {.Span_End,"melee_trail","combo",false},
    }
    interrupt_paired_steps:=[?]Step_Event{
        {.Marker,"FortMeleeAnimTrails_On","swing",true},
        {.Interrupted,"","",true},          // unrelated unnamed clip end must NOT stop named-action trail
        {.Ended,"","other_action",true},    // unrelated other action end must NOT stop trail
        {.Interrupted,"","swing",false},
        {.Marker,"FortMeleeAnimTrails_On","swing",true},
        {.Ended,"","swing",false},
        {.Marker,"FortMeleeAnimTrails_On","",true},
        {.Ended,"","other_action",true},    // named action end must NOT stop unnamed-clip trail
        {.Ended,"","",false},
    }

    cases:=[?]Case{
        {"duration span on same entity",.Self,"melee_trail","","",false,duration_steps[:]},
        {"paired markers on child weapon entity",.Child,"FortMeleeAnimTrails_On","FortMeleeAnimTrails_Off","",false,paired_steps[:]},
        {"action filter ignores other actions",.Explicit,"melee_trail","","heavy_attack",true,action_filtered_steps[:]},
        {"overlapping duration spans use depth counting",.Child,"melee_trail","","",false,overlap_steps[:]},
        {"interruption and end stop paired marker emitters",.Child,"FortMeleeAnimTrails_On","FortMeleeAnimTrails_Off","",false,interrupt_paired_steps[:]},
    }

    for c in cases {
        f:=new(Span_Fixture)
        defer free(f)
        if !span_fixture_init(t,f) {return}
        defer span_fixture_destroy(f)

        rig:=core.create(&f.entities)
        core.add(&f.animations,rig,anim.ANIMATION_DEFAULT)
        emitter_entity:=rig
        explicit:=core.NONE
        switch c.hierarchy {
        case .Self:
        case .Child:
            emitter_entity=core.create(&f.entities)
            core.add(&f.parents,emitter_entity,core.Parent{entity=rig})
        case .Explicit:
            emitter_entity=core.create(&f.entities)
            explicit=rig
        }
        core.add(&f.worlds,emitter_entity,core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
        core.add(&f.emitters,emitter_entity,vfx.Particle_Emitter{active=false,loop=true})
        core.add(&f.spans,emitter_entity,make_span_config(c.span,c.end_marker,c.action,explicit,c.restart))
        test_world_settle(&f.w)

        now:=core.Time{playing=true,dt=1.0/60}
        for s,idx in c.steps {
            ev:=anim.Animation_Event{
                entity=rig,
                kind=s.kind,
                name=base.name_hash(s.name) if s.name!="" else 0,
                action=base.name_hash(s.action) if s.action!="" else 0,
            }
            append(&f.events.items,ev)
            span_fixture_tick(f,now)
            now.seconds+=f64(now.dt)
            em,has:=core.get(&f.emitters,emitter_entity)
            testing.expectf(t,has && em.active==s.want_active,"%s step %d (%v %s): active=%v want=%v",c.name,idx,s.kind,s.name,em.active,s.want_active)
        }
        if c.restart {
            status,ok:=vfx.status(&f.clocks,core.at(&f.emitters,0),emitter_entity)
            testing.expectf(t,ok && status.generation>0,"%s: restart_on_begin incremented generation",c.name)
        }
    }
}

// Source entity destruction, span component removal and emitter destruction
// never leave trails stuck on or produce stale requests; steady ticks allocate
// zero memory.
@(test)
animation_span_handles_destruction_removal_and_zero_stable_allocations :: proc(t:^testing.T) {
    f:=new(Span_Fixture)
    defer free(f)
    if !span_fixture_init(t,f) {return}
    defer span_fixture_destroy(f)

    // 1. Source entity destroyed mid-span stops an explicit-source emitter.
    rig:=core.create(&f.entities)
    core.add(&f.animations,rig,anim.ANIMATION_DEFAULT)
    emitter:=core.create(&f.entities)
    core.add(&f.worlds,emitter,core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
    core.add(&f.emitters,emitter,vfx.Particle_Emitter{active=false,loop=true})
    core.add(&f.spans,emitter,make_span_config("swing_trail","","",rig))
    test_world_settle(&f.w)

    now:=core.Time{playing=true,dt=1.0/60}
    append(&f.events.items,anim.Animation_Event{entity=rig,kind=.Span_Begin,name=base.name_hash("swing_trail")})
    span_fixture_tick(f,now)
    now.seconds+=f64(now.dt)
    em,_:=core.get(&f.emitters,emitter)
    testing.expect(t,em.active,"emitter started on Span_Begin")

    core.destroy(&f.entities,rig)
    test_world_settle(&f.w)
    span_fixture_tick(f,now)
    now.seconds+=f64(now.dt)
    em,_=core.get(&f.emitters,emitter)
    testing.expect(t,!em.active,"destroying animated source stops emitter")

    // 2. Removing Particle_Animation_Span mid-span stops the emitter cleanly.
    rig2:=core.create(&f.entities)
    core.add(&f.animations,rig2,anim.ANIMATION_DEFAULT)
    core.edit(&f.spans,emitter).source=rig2
    test_world_settle(&f.w)

    append(&f.events.items,anim.Animation_Event{entity=rig2,kind=.Span_Begin,name=base.name_hash("swing_trail")})
    span_fixture_tick(f,now)
    now.seconds+=f64(now.dt)
    em,_=core.get(&f.emitters,emitter)
    testing.expect(t,em.active)

    core.remove(&f.spans,emitter)
    test_world_settle(&f.w)
    span_fixture_tick(f,now)
    now.seconds+=f64(now.dt)
    em,_=core.get(&f.emitters,emitter)
    testing.expect(t,!em.active,"removing Particle_Animation_Span stops active emitter")
    testing.expect_value(t,len(f.span_state.entries.values),0)

    // 3. Re-add span, sync once (no events), then verify zero allocations even on the very first
    //    Span_Begin and across steady begin/end cycles.
    core.add(&f.spans,emitter,make_span_config("swing_trail","","",rig2))
    test_world_settle(&f.w)
    span_fixture_tick(f,now)
    now.seconds+=f64(now.dt)

    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for _ in 0..<4 {
            append(&f.events.items,anim.Animation_Event{entity=rig2,kind=.Span_Begin,name=base.name_hash("swing_trail")})
            span_fixture_tick(f,now)
            now.seconds+=f64(now.dt)
            append(&f.events.items,anim.Animation_Event{entity=rig2,kind=.Span_End,name=base.name_hash("swing_trail")})
            span_fixture_tick(f,now)
            now.seconds+=f64(now.dt)
        }
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))

    // 4. World copy round-trip preserves active span state and cached hashes without losing stop.
    append(&f.events.items,anim.Animation_Event{entity=rig2,kind=.Span_Begin,name=base.name_hash("swing_trail"),action=base.name_hash("slash")})
    span_fixture_tick(f,now)
    now.seconds+=f64(now.dt)
    copied:=new(Span_Fixture)
    defer free(copied)
    if !span_fixture_init(t,copied) {return}
    defer span_fixture_destroy(copied)
    testing.expect(t,test_world_copy(&copied.w,&f.w))
    append(&copied.events.items,anim.Animation_Event{entity=rig2,kind=.Span_End,name=base.name_hash("swing_trail"),action=base.name_hash("slash")})
    span_fixture_tick(copied,now)
    em_copied,_:=core.get(&copied.emitters,emitter)
    testing.expect(t,!em_copied.active,"copied world closes active span cleanly")

    // 5. Destroying the emitter entity mid-span prunes state and leaves no problems.
    core.destroy(&f.entities,emitter)
    test_world_settle(&f.w)
    span_fixture_tick(f,now)
    testing.expect_value(t,len(f.span_state.entries.values),0)
    testing.expect_value(t,f.problems.count,0)
}
