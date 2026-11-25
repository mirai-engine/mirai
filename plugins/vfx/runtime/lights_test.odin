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
    core.events_read(&births.log,&f.births_cursor)
    particles_tick(&f.emitters,&f.overrides,core.read(&f.worlds),core.ref(&f.hierarchy),
        core.commands_of(test_world_ref(&f.w)),&f.clocks,&f.sync,&f.requests,core.ref(&births),
        core.read(&f.listeners),time,{dt=time.dt,alpha=1},a,&f.problems,core.ref(&f.sources))
    core.events_age(&f.births.log)
    test_world_settle(&f.w)
    f.extras.light_count=0
    particles_lights(core.read(&f.worlds),core.read(&f.hidden),core.read(&f.parents),core.ref(&f.clocks),
        core.ref(&f.settings),core.ref(&f.sources),&f.extras,&f.problems)
}

// Table-driven check: particle light emission obeys effect config (color,
// intensity, range, radius, shadows, indirect, scattering), particle life
// curve (color_over_life; the range stays whatever size_over_life does),
// fallback to effect colors, and
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
        {"burst mid life fades intensity and keeps its range",burst_id,0.1,5,false,1,190,210,9.99,10.01,{0.5,0.2,0.05},true},
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
            testing.expectf(t,l.position==[3]f32{2,3,4},"%s: light world pos=%v, not at its emitter",c.name,l.position)
        }
    }
}

// The light of a layer sits at its emitter, offset in its axes, wherever its
// particles go, and follows the emitter as it moves and turns.
@(test)
particle_light_sits_at_its_emitter_and_follows_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"vfx-lights-follow")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    // Sparks thrown up that fall under gravity and drag, in world space.
    sparks_id:=base.Asset_Id{0x1164,20}
    sparks:=effect.PARTICLE_DEFAULTS
    sparks.rate=60
    sparks.lifetime={1,1}
    sparks.speed={6,8}
    sparks.gravity=1
    sparks.drag=0.5
    sparks.acceleration={0,-9.81,0}
    sparks.light={color={1,0.6,0.2},intensity=300,range=6,offset={0,0.5,0}}
    path:=strings.concatenate({folder,"/sparks.particle"},context.temp_allocator)
    testing.expect_value(t,effect.particle_save(path,&types,{id=sparks_id,info=sparks}),asset.Error.None)

    f:=new(Lights_Fixture)
    defer free(f)
    if !lights_fixture_init(t,f,folder) {return}
    defer lights_fixture_destroy(f)
    e:=lights_fixture_emitter(f,{particle=sparks_id,active=true,loop=true},{1,0,0})
    now:=core.Time{playing=true,dt=0.1}
    for _ in 0..<5 {
        lights_fixture_step(f,now)
        now.seconds+=0.1
    }
    lights:=host.extras_lights(&f.extras)
    testing.expect_value(t,len(lights),1)
    if len(lights)==1 {testing.expectf(t,lights[0].position==[3]f32{1,0.5,0},"the light is at its emitter and offset: %v",lights[0].position)}

    // Moved and turned a quarter about Z: the offset turns with it.
    place:=mm.TRANSFORM_IDENTITY
    place.position={3,0,2}
    place.rotation=mm.quat_axis_angle({0,0,1},f32(math.PI/2))
    core.edit(&f.worlds,e)^=core.World_Transform{place,place}
    test_world_settle(&f.w)
    lights_fixture_step(f,now)
    lights=host.extras_lights(&f.extras)
    testing.expect_value(t,len(lights),1)
    if len(lights)==1 {
        want:=[3]f32{2.5,0,2}
        testing.expectf(t,abs(lights[0].position.x-want.x)<1e-4 && abs(lights[0].position.y-want.y)<1e-4 && abs(lights[0].position.z-want.z)<1e-4,"the light follows its emitter: %v, want %v",lights[0].position,want)
    }
}

// The world cap keeps the lights nearest a simulation source and reports
// those it drops; only emitters with a light are visited, the lights go when
// their emitter does, and steady frames allocate nothing.
@(test)
particle_lights_respect_budgets_cleanup_and_zero_stable_allocations :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"vfx-lights-budget")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)

    lit_id:=base.Asset_Id{0x1164,10}
    lit_fx:=effect.PARTICLE_DEFAULTS
    lit_fx.rate=60
    lit_fx.lifetime={1.0,1.0}
    lit_fx.color_over_life={colors={{1,1,1,1},{1,1,1,1},{},{},{},{},{},{}},times={0,1,0,0,0,0,0,0}}
    lit_fx.size_over_life=effect.PARTICLE_CURVE_ONE
    lit_fx.light={color={1,0.8,0.5},intensity=300,range=8}
    path:=strings.concatenate({folder,"/lit.particle"},context.temp_allocator)
    testing.expect_value(t,effect.particle_save(path,&types,{id=lit_id,info=lit_fx}),asset.Error.None)

    // 1. Without lit layers: nothing visited and zero allocations.
    {
        f:=new(Lights_Fixture)
        defer free(f)
        if !lights_fixture_init(t,f,folder) {return}
        defer lights_fixture_destroy(f)
        _=lights_fixture_emitter(f,{active=true,loop=true})
        lights_fixture_step(f,{playing=true,dt=1.0/60})
        testing.expect_value(t,len(f.clocks.lit),0)
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

    // 2. The world cap (Particle_Settings.max_lights).
    {
        f:=new(Lights_Fixture)
        defer free(f)
        if !lights_fixture_init(t,f,folder) {return}
        defer lights_fixture_destroy(f)
        f.sources.count=1
        f.sources.items[0].position={0,0,0}

        near:=lights_fixture_emitter(f,{particle=lit_id,active=true,loop=true},{1,0,0})
        _=lights_fixture_emitter(f,{particle=lit_id,active=true,loop=true},{5,0,0})
        _=lights_fixture_emitter(f,{particle=lit_id,active=true,loop=true},{20,0,0})
        _=lights_fixture_emitter(f,{active=true,loop=true},{2,0,0})

        f.settings.max_lights=2
        now:=core.Time{playing=true,dt=0.1}
        for _ in 0..<3 {
            lights_fixture_step(f,now)
            now.seconds+=0.1
        }
        testing.expect_value(t,len(f.clocks.lit),3)
        submitted:=host.extras_lights(&f.extras)
        testing.expect_value(t,len(submitted),2)
        if len(submitted)==2 {testing.expect(t,submitted[0].position=={1,0,0} && submitted[1].position=={5,0,0},"the nearest first")}
        testing.expect(t,core.problem_find(&f.problems,core.NONE,"vfx.lights_over")!=nil,"the light dropped is reported")

        // Steady-state frames allocate zero memory (including budget reduction and restore).
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        defer mem.tracking_allocator_destroy(&tracker)
        {
            context.allocator=mem.tracking_allocator(&tracker)
            f.settings.max_lights=3
            for _ in 0..<6 {
                lights_fixture_step(f,now)
                now.seconds+=0.1
            }
            f.settings.max_lights=1
            lights_fixture_step(f,now)
            now.seconds+=0.1
            f.settings.max_lights=3
            lights_fixture_step(f,now)
            now.seconds+=0.1
        }
        testing.expect_value(t,tracker.total_allocation_count,i64(0))
        testing.expect_value(t,len(host.extras_lights(&f.extras)),3)

        // Destroying the near emitter drops its light.
        core.destroy(&f.entities,near)
        test_world_settle(&f.w)
        lights_fixture_step(f,now)
        submitted=host.extras_lights(&f.extras)
        testing.expect_value(t,len(submitted),2)
        for l in submitted {
            testing.expect(t,l.position!={1,0,0},"destroyed emitter submits no light")
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
            if l.position=={0.5,0,0} && l.intensity>0 && l.color.b>l.color.r {
                found_override=true
            }
        }
        testing.expect(t,found_override,"Particle_Override light fields emit a dynamic point light")
    }
}

// An emitter that starts its particles at the births of a channel gives its
// light from the last of them, while those particles live.
@(test)
a_channel_emitter_lights_from_the_births_of_its_channel :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"vfx-lights-channel")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    flash_id:=base.Asset_Id{0x1164,30}
    flash:=effect.PARTICLE_DEFAULTS
    flash.rate=0
    flash.lifetime={0.3,0.3}
    flash.color_over_life={colors={{1,1,1,1},{1,1,1,0},{},{},{},{},{},{}},times={0,1,0,0,0,0,0,0}}
    flash.light={color={1,0.7,0.4},intensity=800,range=6}
    path:=strings.concatenate({folder,"/flash.particle"},context.temp_allocator)
    testing.expect_value(t,effect.particle_save(path,&types,{id=flash_id,info=flash}),asset.Error.None)

    f:=new(Lights_Fixture)
    defer free(f)
    if !lights_fixture_init(t,f,folder) {return}
    defer lights_fixture_destroy(f)
    e:=lights_fixture_emitter(f,{particle=flash_id,active=true,loop=true},{0,1,0})
    listener:Particle_Channel
    base.text_set(listener.name[:],"impacts")
    core.add(&f.listeners,e,listener)
    test_world_settle(&f.w)
    now:=core.Time{playing=true,dt=1.0/60}
    lights_fixture_step(f,now)
    testing.expect_value(t,len(host.extras_lights(&f.extras)),0)
    core.birth(&f.births,core.Birth{channel=core.birth_channel("impacts"),position={0,1,2},count=4})
    now.seconds+=f64(now.dt)
    lights_fixture_step(f,now)
    lights:=host.extras_lights(&f.extras)
    testing.expectf(t,len(lights)==1 && lights[0].position=={0,1,0} && lights[0].intensity>700,"a flash at the emitter: %v",lights)
    for _ in 0..<30 {
        now.seconds+=f64(now.dt)
        lights_fixture_step(f,now)
    }
    testing.expectf(t,len(host.extras_lights(&f.extras))==0,"out once its particles died: %v",host.extras_lights(&f.extras))
}
