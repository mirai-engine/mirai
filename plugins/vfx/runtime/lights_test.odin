package vfx

import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

@(private)
@(test_world)
Lights_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    hidden:core.Table(erender.Hidden),
    emitters:core.Table(Particle_Emitter),
    overrides:core.Table(Particle_Override),
    listeners:core.Table(Particle_Channel),
    births:core.Births,
    hierarchy:core.Hierarchy,
    clocks:Particle_Clocks,
    requests:Particle_Requests,
    settings:Particle_Settings,
}

@(private="file")
Lights_Fixture :: struct {
    using w:Lights_World,
    births_cursor:u64,
    sources:scene.Simulation_Sources,
    sync:Particle_Sync,
    assets:host.Assets,
    extras:host.Frame_Extras,
    has_assets:bool,
    problems:core.Problems,
}

@(private="file")
lights_fixture_init :: proc(t:^testing.T,f:^Lights_Fixture,folder:string="") -> bool {
    if !test_world_init(t,&f.w) {return false}
    if folder!="" {
        if !testing.expect(t,host.assets_init(&f.assets,{root=folder})) {
            test_world_destroy(&f.w)
            return false
        }
        f.has_assets=true
    }
    return true
}

@(private="file")
lights_fixture_destroy :: proc(f:^Lights_Fixture) {
    if f.has_assets {host.assets_destroy(&f.assets)}
    host.extras_free(&f.extras)
    particle_sync_free(&f.sync)
    test_world_destroy(&f.w)
}

@(private="file")
lights_fixture_emitter :: proc(f:^Lights_Fixture,emitter:Particle_Emitter,position:[3]f32={}) -> core.Entity {
    e:=core.create(&f.entities)
    tr:=core.TRANSFORM_IDENTITY
    tr.position=position
    place:=mm.TRANSFORM_IDENTITY
    place.position=position
    core.add(&f.transforms,e,tr)
    core.add(&f.worlds,e,core.World_Transform{place,place})
    core.add(&f.emitters,e,emitter)
    test_world_settle(&f.w)
    return e
}

@(private="file")
lights_fixture_step :: proc(f:^Lights_Fixture,time:core.Time) {
    a:=&f.assets if f.has_assets else nil
    births:=f.births
    core.events_read(&births.queue,&f.births_cursor)
    particles_tick(&f.emitters,&f.overrides,core.read(&f.worlds),core.ref(&f.hierarchy),
        core.commands_of(test_world_ref(&f.w)),&f.clocks,&f.sync,&f.requests,core.ref(&births),
        core.read(&f.listeners),time,{dt=time.dt,alpha=1},a,&f.problems,core.ref(&f.sources))
    core.events_age(&f.births.queue)
    test_world_settle(&f.w)
    f.extras.light_count=0
    particles_lights(core.read(&f.emitters),core.read(&f.overrides),
        core.read(&f.worlds),core.read(&f.hidden),core.read(&f.parents),core.ref(&f.clocks),
        core.ref(&f.settings),core.ref(&f.sources),a,&f.extras)
}

// Table-driven check: particle light emission obeys effect config (color,
// intensity, range, radius, shadows, indirect, scattering), particle life
// curves (color_over_life, size_over_life), fallback to effect colors, and
// emitter state (active, hidden, stopped, destroyed).
@(test)
particle_lights_follow_effect_config_particle_life_and_emitter_state :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"vfx-lights-life")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)

    save :: proc(t:^testing.T,folder:string,types:^asset.Types,name:string,id:base.Asset_Id,info:effect.Particle_Info) {
        path:=strings.concatenate({folder,"/",name,".particle"},context.temp_allocator)
        testing.expect_value(t,effect.particle_save(path,types,{id=id,info=info}),asset.Error.None)
    }

    // Burst light with explicit tint, constant gradient fade 1 -> 0 and size 1 -> 2.
    burst_id:=base.Asset_Id{0x1164,1}
    burst_fx:=effect.PARTICLE_DEFAULTS
    burst_fx.rate=0
    burst_fx.duration=0.5
    burst_fx.bursts[0]={time=0,count=4,cycles=1}
    burst_fx.lifetime={1.0,1.0}
    burst_fx.color_over_life={
        colors={{1,1,1,1},{0.5,0.5,0.5,0.5},{0,0,0,0},{},{},{},{},{}},
        times={0,0.5,1,0,0,0,0,0},
    }
    burst_fx.size_over_life={
        values={1.0,2.0,1,1,1,1,1,1},
        times={0,1.0,0,0,0,0,0,0},
    }
    burst_fx.light={color={1,0.4,0.1},intensity=400,range=10,radius=0.15,shadows=true,indirect=0.8,scattering=0.5}
    save(t,folder,&types,"burst",burst_id,burst_fx)

    // Continuous light with zero light.color -> inherits effect particle colors midpoint.
    inherit_id:=base.Asset_Id{0x1164,2}
    inherit_fx:=effect.PARTICLE_DEFAULTS
    inherit_fx.rate=60
    inherit_fx.lifetime={1.0,1.0}
    inherit_fx.colors={{0.2,0.4,0.8,1},{0.6,0.8,1.0,1}}
    inherit_fx.color_over_life={colors={{1,1,1,1},{1,1,1,1},{},{},{},{},{},{}},times={0,1,0,0,0,0,0,0}}
    inherit_fx.size_over_life=effect.PARTICLE_CURVE_ONE
    inherit_fx.light={intensity=200,range=6}
    save(t,folder,&types,"inherit",inherit_id,inherit_fx)

    // Disabled light (intensity 0) and zero-range light.
    off_id:=base.Asset_Id{0x1164,3}
    off_fx:=effect.PARTICLE_DEFAULTS
    save(t,folder,&types,"off",off_id,off_fx)

    Case :: struct {
        name:string,
        asset:base.Asset_Id,
        dt:f32,
        steps:int,
        hide:bool,
        want_active:int,
        want_intensity_lo,want_intensity_hi:f32,
        want_range_lo,want_range_hi:f32,
        want_color:[3]f32,
        want_shadows:bool,
    }
    cases:=[?]Case{
        {"disabled effect creates no light",off_id,0.1,3,false,0,0,0,0,0,{},false},
        {"burst early life shines near peak",burst_id,0.05,1,false,1,340,400,10,11,{0.95,0.38,0.095},true},
        {"burst mid life fades intensity and grows range",burst_id,0.1,5,false,1,190,210,14.5,15.5,{0.5,0.2,0.05},true},
        {"burst past lifetime turns off",burst_id,0.25,5,false,0,0,0,0,0,{},false},
        {"hidden emitter suppresses light",burst_id,0.05,1,true,0,0,0,0,0,{},false},
        {"zero light.color inherits particle colors",inherit_id,0.1,3,false,1,195,205,5.9,6.1,{0.4,0.6,0.9},false},
    }

    for c in cases {
        f:=new(Lights_Fixture)
        defer free(f)
        if !lights_fixture_init(t,f,folder) {return}
        defer lights_fixture_destroy(f)
        e:=lights_fixture_emitter(f,{particle=c.asset,active=true,loop=false},{2,3,4})
        if c.hide {
            core.add(&f.hidden,e,erender.Hidden{})
            test_world_settle(&f.w)
        }
        now:=core.Time{playing=true,dt=c.dt}
        for _ in 0..<c.steps {
            lights_fixture_step(f,now)
            now.seconds+=f64(c.dt)
        }
        submitted:=host.extras_lights(&f.extras)
        testing.expectf(t,len(submitted)==c.want_active,"%s: active lights=%d want=%d",c.name,len(submitted),c.want_active)
        if c.want_active>0 {
            l:=submitted[0]
            testing.expectf(t,l.intensity>=c.want_intensity_lo && l.intensity<=c.want_intensity_hi,"%s: intensity=%f not in [%f,%f]",c.name,l.intensity,c.want_intensity_lo,c.want_intensity_hi)
            testing.expectf(t,l.range>=c.want_range_lo && l.range<=c.want_range_hi,"%s: range=%f not in [%f,%f]",c.name,l.range,c.want_range_lo,c.want_range_hi)
            testing.expectf(t,!l.shadowless==c.want_shadows,"%s: shadows=%v want=%v",c.name,!l.shadowless,c.want_shadows)
            for axis in 0..<3 {
                testing.expectf(t,math.abs(l.color[axis]-c.want_color[axis])<0.12,"%s: color[%d]=%f want~%f",c.name,axis,l.color[axis],c.want_color[axis])
            }
            testing.expectf(t,math.abs(l.position.x-2)<0.05 && math.abs(l.position.z-4)<0.05,"%s: light world pos=%v",c.name,l.position)
        }
    }
}

// Per-emitter and per-world budgets strictly cap active lights, prioritize
// nearest simulation source then intensity, spread across full shape radius/half-extent,
// clean up on emitter destruction, and allocate zero memory on every frame.
@(test)
particle_lights_respect_budgets_cleanup_and_zero_stable_allocations :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"vfx-lights-budget")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)

    multi_id:=base.Asset_Id{0x1164,10}
    multi_fx:=effect.PARTICLE_DEFAULTS
    multi_fx.rate=60
    multi_fx.lifetime={1.0,1.0}
    multi_fx.shape=.Circle
    multi_fx.shape_size={0.5,0,0}
    multi_fx.color_over_life={colors={{1,1,1,1},{1,1,1,1},{},{},{},{},{},{}},times={0,1,0,0,0,0,0,0}}
    multi_fx.size_over_life=effect.PARTICLE_CURVE_ONE
    multi_fx.light={color={1,0.8,0.5},intensity=300,range=8,max_lights=99} // clamped to EMITTER_LIGHTS_MAX
    path:=strings.concatenate({folder,"/multi.particle"},context.temp_allocator)
    testing.expect_value(t,effect.particle_save(path,&types,{id=multi_id,info=multi_fx}),asset.Error.None)

    // 1. Disabled world: zero cost and zero allocations.
    {
        f:=new(Lights_Fixture)
        defer free(f)
        if !lights_fixture_init(t,f,folder) {return}
        defer lights_fixture_destroy(f)
        _=lights_fixture_emitter(f,{active=true,loop=true})
        lights_fixture_step(f,{playing=true,dt=1.0/60})
        testing.expect_value(t,f.clocks.lit_count,u32(0))
        testing.expect_value(t,len(host.extras_lights(&f.extras)),0)
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        defer mem.tracking_allocator_destroy(&tracker)
        {
            context.allocator=mem.tracking_allocator(&tracker)
            for i in 0..<8 {lights_fixture_step(f,{playing=true,dt=1.0/60,seconds=f64(i+1)/60})}
        }
        testing.expect_value(t,tracker.total_allocation_count,i64(0))
    }

    // 2. Per-emitter cap (EMITTER_LIGHTS_MAX) and per-world cap (Particle_Settings.max_lights).
    {
        f:=new(Lights_Fixture)
        defer free(f)
        if !lights_fixture_init(t,f,folder) {return}
        defer lights_fixture_destroy(f)
        f.sources.count=1
        f.sources.items[0].position={0,0,0}

        near:=lights_fixture_emitter(f,{particle=multi_id,active=true,loop=true},{1,0,0})
        mid:=lights_fixture_emitter(f,{particle=multi_id,active=true,loop=true},{5,0,0})
        far:=lights_fixture_emitter(f,{particle=multi_id,active=true,loop=true},{20,0,0})
        _ = mid
        _ = far

        // World budget of 5: near takes 4 (EMITTER_LIGHTS_MAX), mid takes 1, far gets 0.
        f.settings.max_lights=5
        now:=core.Time{playing=true,dt=0.1}
        for _ in 0..<3 {
            lights_fixture_step(f,now)
            now.seconds+=0.1
        }
        submitted:=host.extras_lights(&f.extras)
        testing.expect_value(t,len(submitted),5)
        near_count,mid_count,far_count:=0,0,0
        max_near_radius:=f32(0)
        for l in submitted {
            switch {
            case math.abs(l.position.x-1)<1.0:
                near_count+=1
                dx,dz:=l.position.x-1,l.position.z
                max_near_radius=max(max_near_radius,math.sqrt(dx*dx+dz*dz))
            case math.abs(l.position.x-5)<1.0:
                mid_count+=1
            case math.abs(l.position.x-20)<1.0:
                far_count+=1
            }
        }
        testing.expect_value(t,near_count,EMITTER_LIGHTS_MAX)
        testing.expect_value(t,mid_count,1)
        testing.expect_value(t,far_count,0)
        // Circle shape_size.x = 0.5 is radius directly (not halved to 0.25).
        testing.expectf(t,math.abs(max_near_radius-0.5)<0.05,"circle light spread radius=%f want=0.5",max_near_radius)

        // Steady-state frames allocate zero memory (including budget reduction and restore).
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        defer mem.tracking_allocator_destroy(&tracker)
        {
            context.allocator=mem.tracking_allocator(&tracker)
            for _ in 0..<6 {
                lights_fixture_step(f,now)
                now.seconds+=0.1
            }
            f.settings.max_lights=2
            lights_fixture_step(f,now)
            now.seconds+=0.1
            f.settings.max_lights=5
            lights_fixture_step(f,now)
            now.seconds+=0.1
        }
        testing.expect_value(t,tracker.total_allocation_count,i64(0))
        testing.expect_value(t,len(host.extras_lights(&f.extras)),5)

        // Destroying near emitter drops its lights and lets mid + far take budget.
        core.destroy(&f.entities,near)
        test_world_settle(&f.w)
        lights_fixture_step(f,now)
        submitted=host.extras_lights(&f.extras)
        testing.expect_value(t,len(submitted),5)
        for l in submitted {
            testing.expect(t,math.abs(l.position.x-1)>1.0,"destroyed emitter submits no light")
        }

        // Particle_Override can enable or boost light on an instance.
        override_emitter:=lights_fixture_emitter(f,{active=true,loop=true},{0.5,0,0})
        override:Particle_Override
        testing.expect_value(t,value_set(&override,"light.intensity",f32(600)),Error.None)
        testing.expect_value(t,value_set(&override,"light.range",f32(12)),Error.None)
        testing.expect_value(t,value_set(&override,"light.color",[3]f32{0.2,0.6,1.0}),Error.None)
        core.add(&f.overrides,override_emitter,override)
        test_world_settle(&f.w)
        now.seconds+=0.2
        lights_fixture_step(f,now)
        now.seconds+=0.2
        lights_fixture_step(f,now)
        found_override:=false
        for l in host.extras_lights(&f.extras) {
            if math.abs(l.position.x-0.5)<0.1 && l.intensity>0 && l.color.b>l.color.r {
                found_override=true
            }
        }
        testing.expect(t,found_override,"Particle_Override light fields emit a dynamic point light")
    }
}
