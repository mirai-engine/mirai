package vfx

import "core:math"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

@(private)
@(test_world)
Emitters_World :: struct {
    using world:Test_World,
    emitters:core.Table(Particle_Emitter),
    worlds:core.Table(core.World_Transform),
    overrides:core.Table(Particle_Override),
    hidden:core.Table(erender.Hidden),
    parents:core.Table(core.Parent),
    bindings:core.Table(Particle_Bindings),
    listeners:core.Table(Particle_Channel),
    grids:core.Table(Particle_Grid),
    volumes:core.Table(Particle_Volume),
    textures:core.Table(Particle_World_Texture),
    meshes:core.Table(erender.Mesh_Renderer),
    births:core.Births,
    hierarchy:core.Hierarchy,
    clocks:Particle_Clocks,
    requests:Particle_Requests,
    settings:Particle_Settings,
}

@(private="file")
Emitters_Fixture :: struct {
    using w:Emitters_World,
    births_cursor:u64,
    sources:scene.Simulation_Sources,
    drawn:erender.Render_Sync,
    sync:Particle_Sync,
    app:host.App,
    problems:core.Problems,
}

@(private="file")
fixture_init :: proc(t:^testing.T,f:^Emitters_Fixture) -> bool {return test_world_init(t,&f.w)}

@(private="file")
fixture_destroy :: proc(f:^Emitters_Fixture) {
    particle_sync_free(&f.sync)
    test_world_destroy(&f.w)
}

@(private="file")
fixture_settle :: proc(f:^Emitters_Fixture) {test_world_settle(&f.w)}

@(private="file")
fixture_emitter :: proc(f:^Emitters_Fixture,emitter:Particle_Emitter,position:[3]f32={}) -> core.Entity {
    e:=core.create(&f.entities)
    place:=mm.TRANSFORM_IDENTITY
    place.position=position
    core.add(&f.emitters,e,emitter)
    core.add(&f.worlds,e,core.World_Transform{place,place})
    fixture_settle(f)
    return e
}

@(private="file")
fixture_tick :: proc(f:^Emitters_Fixture,time:core.Time,frame:=FRAME) {
    births:=f.births
    core.events_read(&births.log,&f.births_cursor)
    particles_tick(&f.emitters,&f.overrides,core.read(&f.worlds),core.ref(&f.hierarchy),{entities=&f.entities},&f.clocks,&f.sync,&f.requests,core.ref(&births),core.read(&f.listeners),time,frame,f.app.assets,&f.problems,core.ref(&f.sources))
    core.events_age(&f.births.log)
    fixture_settle(f)
}

@(private="file")
fixture_sync :: proc(f:^Emitters_Fixture,id:core.World_Id,time:core.Time,frame:=FRAME) {
    particles_sync(core.read(&f.emitters),core.read(&f.overrides),core.read(&f.worlds),core.read(&f.hidden),core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.bindings),nil,core.read(&f.meshes),core.ref(&f.drawn),core.read(&f.listeners),core.read(&f.grids),core.read(&f.volumes),core.read(&f.textures),core.ref(&f.clocks),core.ref(&f.settings),&f.sync,nil,{},id,time,frame,{},&f.problems,&f.app,{},{},{},{},{})
}

@(private="file")
sync_shown :: proc(sync:^Particle_Sync,e:core.Entity) -> ^Emitter_Shown {
    return core.entity_map_get(&sync.shown,e)
}

@(private="file")
TICK :: core.Time{playing=true,dt=1.0/60}
@(private="file")
FRAME :: core.Frame_Time{dt=1.0/60,alpha=1}

@(test)
new_emitters_start_at_the_current_pose_then_interpolate_motion :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true},{8,2,-16})
    current:=mm.TRANSFORM_IDENTITY;current.position={8,2,-16}
    time,frame:=core.Time{playing=true},core.Frame_Time{dt=1.0/60}
    fixture_sync(&f,{0,1},time,frame)
    testing.expect_value(t,len(f.sync.shown.values),1)
    testing.expect_value(t,f.sync.shown.values[0].transform,mm.transform_matrix(current))
    next:=current;next.position.x+=2
    core.edit(&f.worlds,e)^=core.World_Transform{next,current}
    frame.alpha=.5
    fixture_sync(&f,{0,1},time,frame)
    midpoint:=current;midpoint.position.x+=1
    testing.expect_value(t,f.sync.shown.values[0].transform,mm.transform_matrix(midpoint))
}

// A burst a game asks for in a tick, and the bursts of the effect, start
// once: a rollback that runs those ticks again leaves the births it repeats
// as started, and only what comes after starts.
@(test)
a_rollback_does_not_start_the_same_burst_twice :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true})
    // The effect: a burst of 7 at the start of each cycle of half a second, nothing else.
    clock_of(&f.clocks,e)
    f.clocks.playing=true
    clock:=clock_find(&f.clocks,e)
    clock.resolved=emission_key({},0)
    clock.emission={duration=0.5,longest=1,tail=1}
    clock.emission.bursts[0]={count=7}
    id:=core.World_Id{0,1}
    tick :: proc(f:^Emitters_Fixture,e:core.Entity,at:int) {
        // The game asks for a burst at the tenth tick, in fixed: a rollback asks again.
        if at==10 {burst(&f.requests,e,50)}
        fixture_tick(f,TICK)
    }
    // Keep the resolved emission: there are no assets in the test.
    f.app.assets=nil
    for at in 0..<5 {tick(&f,e,at)}
    saved:Particle_Clocks
    defer core.value_free(&saved,type_info_of(Particle_Clocks))
    testing.expect(t,core.value_copy(&saved,&f.clocks,type_info_of(Particle_Clocks)))
    for at in 5..<20 {tick(&f,e,at)}
    fixture_sync(&f,id,TICK)
    shown:=sync_shown(&f.sync,e)
    // 0.333 s: the burst of the first cycle, 7, and the one asked, 50.
    testing.expect_value(t,shown.started,u64(57))
    // The rollback: the clocks of five ticks in, and the ticks again with the same request.
    testing.expect(t,core.value_copy(&f.clocks,&saved,type_info_of(Particle_Clocks)))
    for at in 5..<20 {tick(&f,e,at)}
    clock=clock_find(&f.clocks,e)
    testing.expect_value(t,clock.emitted,u64(57))
    started_before:=sync_shown(&f.sync,e).started
    spawns:=births_since(clock,&started_before)
    for s in spawns {testing.expect_value(t,s.count,u32(0))}
    fixture_sync(&f,id,TICK)
    testing.expect_value(t,sync_shown(&f.sync,e).started,u64(57))
    // The second cycle starts its burst once.
    for at in 20..<31 {tick(&f,e,at)}
    clock=clock_find(&f.clocks,e)
    started:=sync_shown(&f.sync,e).started
    fresh:=births_since(clock,&started)
    total:u32
    for s in fresh {total+=s.count}
    testing.expect_value(t,total,u32(7))
    testing.expect_value(t,fresh[0].per,u32(7))
}

@(test)
a_frame_that_sees_an_older_copy_starts_only_what_comes_after_it :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true})
    for _ in 0..<2 {fixture_tick(&f,TICK)}
    clock:=clock_find(&f.clocks,e)
    clock.resolved=emission_key({},0)
    clock.emission={duration=1,rate=60,longest=1,tail=1}
    f.app.assets=nil
    for _ in 0..<30 {fixture_tick(&f,TICK)}
    saved:Particle_Clocks
    defer core.value_free(&saved,type_info_of(Particle_Clocks))
    testing.expect(t,core.value_copy(&saved,&f.clocks,type_info_of(Particle_Clocks)))
    first:=clock_find(&f.clocks,e).emitted
    for _ in 0..<10 {fixture_tick(&f,TICK)}
    fixture_sync(&f,{0,1},TICK)
    ahead:=sync_shown(&f.sync,e).started
    testing.expect(t,ahead>first)
    testing.expect(t,core.value_copy(&f.clocks,&saved,type_info_of(Particle_Clocks)))
    fixture_sync(&f,{0,1},TICK)
    testing.expect_value(t,sync_shown(&f.sync,e).started,first)
}

// The clock of an emitter and what the renderer was told of it go when its
// emitter or its place goes, from what the tables say changed.
@(test)
the_clock_and_the_shown_of_an_emitter_that_goes_are_dropped :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    kept:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true})
    gone:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true},{1,0,0})
    unplaced:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true},{2,0,0})
    fixture_tick(&f,TICK)
    fixture_sync(&f,{0,1},TICK)
    testing.expect(t,len(f.clocks.clocks.values)==3 && len(f.sync.shown.values)==3)
    core.remove(&f.emitters,gone)
    core.remove(&f.worlds,unplaced)
    fixture_settle(&f)
    fixture_tick(&f,TICK)
    fixture_sync(&f,{0,1},TICK)
    testing.expect(t,clock_find(&f.clocks,kept)!=nil && clock_find(&f.clocks,gone)==nil && clock_find(&f.clocks,unplaced)==nil)
    testing.expect(t,sync_shown(&f.sync,kept)!=nil && sync_shown(&f.sync,gone)==nil && sync_shown(&f.sync,unplaced)==nil)
}

// A frame tells the GPU only of the emitters that changed: none when nothing
// did or an asset no effect reads went, and alone the one that moved, was
// hidden, shows another effect, got other values, started births or whose
// effect changed. The tick resolves again only the emissions whose effect or
// values changed. Frames that change nothing allocate nothing.
@(test)
a_frame_tells_only_the_emitters_that_changed :: proc(t:^testing.T) {
    f:=new(Emitters_Fixture)
    defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    folder:=base.test_folder(t,"vfx-told")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    path:=strings.concatenate({folder,"/other.particle"},context.temp_allocator)
    other:=effect.PARTICLE_DEFAULTS
    other.rate=3
    testing.expect_value(t,effect.particle_save(path,&types,{id={7,8},info=other}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder})) {return}
    defer host.assets_destroy(&assets)
    f.app.assets=&assets
    // A mesh no effect reads, as a terrain piece is.
    positions:=[3]geom.Vec3{{0,0,0},{1,0,0},{0,1,0}}
    indices:=[3]u32{0,1,2}
    piece,made:=host.assets_mesh_generate(&assets,{positions=positions[:],indices=indices[:]})
    testing.expect(t,made)
    emitters:[5]core.Entity
    for &e,i in emitters {e=fixture_emitter(f,Particle_Emitter{active=true,loop=true},{f32(i),0,0})}
    EDITOR :: core.Time{}
    frame :: proc(f:^Emitters_Fixture) {
        fixture_tick(f,EDITOR)
        fixture_sync(f,{0,1},EDITOR)
    }
    for _ in 0..<2 {frame(f)}
    // A rate no effect has: an emission resolved again loses it.
    SEEN :: f32(-1)
    for &clock in f.clocks.clocks.values {clock.emission.rate=SEEN}
    Change :: enum {None,Moved,Hidden,Retargeted,Override,Births,Released,Effect}
    cases:=[?]struct{change:Change,emitter:int}{
        {.None,-1},{.Moved,0},{.Hidden,1},{.Retargeted,2},{.Override,3},{.Births,4},{.Released,-1},{.Effect,2},{.None,-1},
    }
    for c in cases {
        e:=emitters[max(c.emitter,0)]
        switch c.change {
        case .None:
        case .Moved:
            place:=mm.TRANSFORM_IDENTITY
            place.position={5,5,5}
            core.edit(&f.worlds,e)^=core.World_Transform{place,place}
        case .Hidden: core.add(&f.hidden,e,erender.Hidden{})
        case .Retargeted: core.edit(&f.emitters,e).particle={7,8}
        case .Override:
            override:Particle_Override
            testing.expect_value(t,value_set(&override,"rate",f32(55)),Error.None)
            core.add(&f.overrides,e,override)
        case .Births: births_add(clock_of(&f.clocks,e),0,4,4,0)
        case .Released: testing.expect(t,host.assets_mesh_release(&assets,piece))
        case .Effect:
            other.rate=9
            testing.expect_value(t,effect.particle_save(path,&types,{id={7,8},info=other}),asset.Error.None)
            testing.expect(t,host.assets_reload(&assets,{7,8}))
        }
        fixture_settle(f)
        frame(f)
        told:=f.sync.told[:]
        if c.emitter<0 {
            testing.expectf(t,len(told)==0,"%v: no emitter changed and %d were told",c.change,len(told))
        } else {
            testing.expectf(t,len(told)==1 && told[0]==e,"%v: only its emitter is told, not %v",c.change,told)
        }
        resolved:=c.change==.Retargeted || c.change==.Override || c.change==.Effect
        for other in emitters {
            clock:=clock_find(&f.clocks,other)
            again:=clock.emission.rate!=SEEN
            testing.expectf(t,again==(resolved && other==e),"%v: the emission of %v is resolved again: %v",c.change,other,again)
            clock.emission.rate=SEEN
        }
    }
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for _ in 0..<4 {frame(f)}
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
}

@(test)
an_effects_layers_keep_independent_clocks_and_share_resolved_values :: proc(t:^testing.T) {
    f:=new(Emitters_Fixture)
    defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    folder:=base.test_folder(t,"vfx-layers")
    path:=strings.concatenate({folder,"/torch.particle"},context.temp_allocator)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    id:=base.Asset_Id{3,7}
    flame:=effect.particle_preset(.Fire)
    layers:=[1]effect.Particle_Info{effect.particle_preset(.Smoke)}
    if !testing.expect_value(t,effect.particle_save(path,&types,{id=id,info=flame,layers=layers[:]}),asset.Error.None) {
        return
    }
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder})) {return}
    defer host.assets_destroy(&assets)
    f.app.assets=&assets
    emitter:=PARTICLE_EMITTER_DEFAULT
    emitter.particle=id
    first:=fixture_emitter(f,emitter)
    second:=fixture_emitter(f,emitter)
    fixture_tick(f,TICK)
    fixture_sync(f,{0,1},TICK)
    flame_clock,smoke_clock:=clock_find(&f.clocks,first),clock_find(&f.clocks,first,1)
    if !testing.expect(t,flame_clock!=nil && smoke_clock!=nil) {return}
    testing.expect_value(t,flame_clock.emission.rate,flame.rate)
    testing.expect_value(t,smoke_clock.emission.rate,layers[0].rate)
    flame_a,flame_b:=sync_shown(&f.sync,first),sync_shown(&f.sync,second)
    if testing.expect(t,flame_a!=nil && flame_b!=nil) {
        testing.expect(t,flame_a.desc.spec!=nil && flame_a.desc.spec==flame_b.desc.spec)
    }
    pause(&f.requests,first)
    fixture_tick(f,TICK)
    testing.expect(t,clock_find(&f.clocks,first).paused && clock_find(&f.clocks,first,1).paused)
    testing.expect(t,!clock_find(&f.clocks,second).paused && !clock_find(&f.clocks,second,1).paused)
    core.remove(&f.emitters,first)
    fixture_settle(f)
    fixture_tick(f,TICK)
    fixture_sync(f,{0,1},TICK)
    testing.expect(t,clock_find(&f.clocks,first,1)==nil)
    testing.expect(t,core.entity_map_get(&f.sync.layers[0],first)==nil)
}

@(test)
the_edit_controls_use_the_preview_flag_and_respect_single_cycles :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    emitter:=fixture_emitter(&f,Particle_Emitter{active=true,preset=.Muzzle_Flash})
    start(&f.requests,emitter)
    fixture_tick(&f,{}, {dt=0.1})
    if !testing.expect(t,core.at(&f.emitters,0).preview) {return}
    for _ in 0..<6 {fixture_tick(&f,{}, {dt=0.1})}
    clock:=clock_find(&f.clocks,emitter)
    testing.expect(t,clock.done && clock.emitted==7)
    stop(&f.requests,emitter)
    fixture_tick(&f,{}, {dt=0.1})
    testing.expect(t,core.at(&f.emitters,0).active && !core.at(&f.emitters,0).preview)
}

// Frames of 1/8 s add up exactly.
@(private="file")
steps :: proc(e:^Emission,looping:bool,clock:^Emitter_Clock,frames:int,moved:f32=0) -> (total:u64) {
    position:[3]f32
    before:=clock.emitted
    for _ in 0..<frames {
        position.x+=moved
        emission_step(clock,e,true,looping,position,0.125)
    }
    return clock.emitted-before
}

@(private="file")
emission :: proc(info:effect.Particle_Info) -> Emission {
    copy:=info
    return emission_of(nil,&copy)
}

@(test)
emission_follows_rate_bursts_and_distance :: proc(t:^testing.T) {
    e:=emission({duration=1,rate=10,lifetime={1,1}})
    clock:Emitter_Clock
    testing.expect_value(t,steps(&e,true,&clock,8),u64(10))
    info:=effect.Particle_Info{duration=1,lifetime={1,1}}
    info.bursts[0]={count=5}
    info.bursts[1]={time=0.5,count=2,cycles=2,interval=0.25}
    e=emission(info)
    clock={}
    // 2.375 s: the first burst three times, the second in two cycles.
    testing.expect_value(t,steps(&e,true,&clock,19),u64(3*5+2*2*2))
    // A burst starts all its particles at one instant; the repeats a step reaches go in one group.
    for b in clock.births[:clock.birth_count] {testing.expect(t,b.per==b.count)}
    clock={}
    emission_step(&clock,&e,true,true,{},1)
    // (0, 1]: the first burst at 0 and 1, the second twice in between.
    testing.expect_value(t,clock.birth_count,u32(3))
    repeat:=clock.births[2]
    testing.expect(t,repeat.count==4 && repeat.per==2 && repeat.spacing==0.25 && repeat.time==0.5)
    e=emission({duration=1,rate_over_distance=2,lifetime={1,1}})
    clock={}
    // The first frame places the emitter; the nine after it travel a metre each.
    testing.expect_value(t,steps(&e,true,&clock,10,moved=1),u64(18))
}

// The CPU reads curves and gradients as particles.slang does, at their ends
// and between keys closer than it divides by.
@(test)
curves_read_on_the_cpu_as_the_shader_reads_them :: proc(t:^testing.T) {
    c:=effect.Particle_Curve{values={2,4,8,6,6,6,6,6},times={0.25,0.5,0.500002,1,1,1,1,1}}
    testing.expect_value(t,keys_at(c.times[:],c.values[:],-1),2)
    testing.expect_value(t,keys_at(c.times[:],c.values[:],0.25),2)
    testing.expect_value(t,keys_at(c.times[:],c.values[:],0.375),3)
    testing.expect_value(t,keys_at(c.times[:],c.values[:],0.5),4)
    testing.expect_value(t,keys_at(c.times[:],c.values[:],2),6)
    // Two microseconds apart, the shader ramps over ten: a tenth of the way.
    near:=keys_at(c.times[:],c.values[:],0.500001)
    testing.expectf(t,abs(near-4.4)<0.05,"between keys closer than 1e-5: %v",near)
    g:effect.Particle_Gradient
    for &key in g.colors {key={0,0,1,0}}
    g.colors[0]={1,0,0,1}
    g.times={0.5,1,1,1,1,1,1,1}
    testing.expect_value(t,keys_at(g.times[:],g.colors[:],0),[4]f32{1,0,0,1})
    testing.expect_value(t,keys_at(g.times[:],g.colors[:],0.75),[4]f32{0.5,0,0.5,0.5})
    testing.expect_value(t,keys_at(g.times[:],g.colors[:],3),[4]f32{0,0,1,0})
}

// particles.slang copies values of the plugin by hand: each is the Odin one.
@(test)
the_values_particles_slang_copies_are_those_of_the_plugin :: proc(t:^testing.T) {
    defines:=make(map[string]u64,context.temp_allocator)
    rest:=string(#load("../shaders/particles.slang"))
    testing.expect(t,strings.contains(rest,"//! mirai constant EMITTER_CAPACITY uint ../runtime/gpu.odin"))
    for line in strings.split_lines_iterator(&rest) {
        words:=strings.fields(line,context.temp_allocator)
        if len(words)<3 || words[0]!="#define" || !strings.has_suffix(words[2],"u") {continue}
        if value,ok:=strconv.parse_u64(words[2][:len(words[2])-1]);ok {defines[words[1]]=value}
    }
    expect :: proc(t:^testing.T,defines:map[string]u64,name:string,value:u64,loc:=#caller_location) {
        got,found:=defines[name]
        testing.expectf(t,found && got==value,"%s is %v in particles.slang (found: %v) and %v in the plugin",name,got,found,value,loc=loc)
    }
    Value :: struct {name:string,value:u64}
    for each in ([]Value{
        {"PARTICLE_FLAG_ACTIVE",FLAG_ACTIVE},{"PARTICLE_FLAG_RESET",FLAG_RESET},{"PARTICLE_FLAG_LOCAL",FLAG_LOCAL},{"PARTICLE_FLAG_LIT",FLAG_LIT},
        {"PARTICLE_FLAG_SORT",FLAG_SORT},{"PARTICLE_FLAG_PAUSED",FLAG_PAUSED},{"PARTICLE_FLAG_ADDITIVE",FLAG_ADDITIVE},{"PARTICLE_FLAG_RELATIVE",FLAG_RELATIVE},
        {"PARTICLE_FLAG_MOVED",FLAG_MOVED},{"PARTICLE_FLAG_BIRTHS",FLAG_BIRTHS},{"PARTICLE_FLAG_PREPARE",FLAG_PREPARE},
        {"PARTICLE_STATE_BYTES",STATE_BYTES},{"PARTICLE_SPAWNS",SPAWNS},
        {"PARTICLE_EVENT_CAPACITY",EVENT_CAPACITY},{"PARTICLE_EVENTS_AT",EVENTS_AT/4},{"PARTICLE_EVENT_WORDS",size_of(Gpu_Event)/4},
        {"PARTICLE_RESOURCES",RESOURCE_ROWS},{"PARTICLE_RESOURCE_BYTES",size_of(Gpu_Resource)},
        {"PARTICLE_STAGES",erender.PROGRAM_STAGES},{"PARTICLE_STAGE_BYTES",size_of(Gpu_Stage)},{"PARTICLE_BIRTH_BYTES",size_of(Gpu_Birth)},
    }) {expect(t,defines,each.name,each.value)}
    kinds :: proc(t:^testing.T,defines:map[string]u64,kind:typeid,prefix:string,none:bool,loc:=#caller_location) {
        for field in reflect.enum_fields_zipped(kind) {
            if !none && field.name=="None" {continue}
            expect(t,defines,strings.concatenate({prefix,strings.to_upper(field.name,context.temp_allocator)},context.temp_allocator),u64(field.value),loc)
        }
    }
    kinds(t,defines,effect.Particle_Shape,"PARTICLE_SHAPE_",true)
    kinds(t,defines,effect.Particle_Render,"PARTICLE_RENDER_",true)
    kinds(t,defines,effect.Particle_Collision,"PARTICLE_COLLISION_",false)
    kinds(t,defines,effect.Particle_Facing,"PARTICLE_FACING_",true)
    kinds(t,defines,effect.Particle_Event,"PARTICLE_EVENT_",false)
    kinds(t,defines,Resource_Kind,"PARTICLE_RESOURCE_",true)
    kinds(t,defines,Stage_Kind,"PARTICLE_STAGE_",true)
}

@(test)
a_single_cycle_ends_when_its_last_particles_die :: proc(t:^testing.T) {
    e:=emission({duration=1,rate=10,lifetime={0.25,0.5}})
    e.bursts[0]={time=1,count=3}
    clock:Emitter_Clock
    testing.expect_value(t,steps(&e,false,&clock,8),u64(13))
    testing.expect(t,!clock.done)
    testing.expect_value(t,steps(&e,false,&clock,3),u64(0))
    testing.expect(t,!clock.done)
    // The last one, born at the end of the cycle, lives half a second.
    steps(&e,false,&clock,2)
    testing.expect(t,clock.done)
}

@(test)
a_prewarmed_emitter_starts_full :: proc(t:^testing.T) {
    info:=effect.Particle_Info{prewarm=true,duration=1,rate=20,lifetime={2,2}}
    e:=emission(info)
    clock:Emitter_Clock
    emission_step(&clock,&e,true,true,{},1.0/60)
    testing.expect(t,clock.emitted>=40)
    // Born over a whole life before the clock started.
    testing.expect(t,clock.births[0].time==-2 && clock.births[0].count==40)
    before:=clock.emitted
    emission_step(&clock,&e,true,true,{},1.0/60)
    testing.expect(t,clock.emitted-before<2)
    testing.expect(t,emitter_capacity(&info)>=40)
}

@(test)
clocks_keep_a_bounded_list_of_births_without_losing_any :: proc(t:^testing.T) {
    clock:Emitter_Clock
    clock.last=-max(f64)
    for i in 0..<20 {births_add(&clock,f64(i)*0.1,3,3,0)}
    testing.expect_value(t,clock.birth_count,u32(PARTICLE_BIRTHS))
    total:u32
    for b in clock.births[:clock.birth_count] {total+=b.count}
    testing.expect_value(t,u64(total),clock.emitted)
    testing.expect_value(t,clock.births[0].first,u64(0))
    // A renderer that started a group in part starts the rest from its next instant.
    started:=u64(clock.births[PARTICLE_BIRTHS-1].first+1)
    clock.time=2
    spawns:=births_since(&clock,&started)
    testing.expect_value(t,spawns[0].count,u32(0))
    testing.expect_value(t,started,clock.emitted)
}

@(test)
an_instance_shows_its_values_over_those_of_its_effect :: proc(t:^testing.T) {
    override:Particle_Override
    testing.expect_value(t,value_set(&override,"rate",f32(55)),Error.None)
    testing.expect_value(t,value_set(&override,"colors.1",[4]f32{1,0,0,1}),Error.None)
    testing.expect_value(t,value_set(&override,"bursts.2.count",u32(7)),Error.None)
    testing.expect_value(t,value_set(&override,"size_over_life.values.3",f32(2)),Error.None)
    // A parameter of its program is a value too, which the fields leave out.
    testing.expect_value(t,value_set(&override,"parameters.heat",f32(0.8)),Error.None)
    info:=particle_resolve(nil,{},&override)
    testing.expect_value(t,info.rate,f32(55))
    testing.expect_value(t,info.colors[1],[4]f32{1,0,0,1})
    testing.expect_value(t,info.colors[0],effect.PARTICLE_DEFAULTS.colors[0])
    testing.expect_value(t,info.bursts[2].count,u32(7))
    testing.expect_value(t,info.size_over_life.values[3],f32(2))
    testing.expect_value(t,info.lifetime,effect.PARTICLE_DEFAULTS.lifetime)
    checked:effect.Particle_Info
    testing.expect_value(t,particle_resolve_checked(nil,{},&override,&checked),Error.None)
    value_remove(&override,"rate")
    testing.expect_value(t,override.count,u32(4))
    testing.expect_value(t,particle_resolve(nil,{},&override).rate,effect.PARTICLE_DEFAULTS.rate)
    // Without a program, a parameter has nothing to give.
    program:Program
    testing.expect(t,particle_program_check(nil,&info,nil,&override,&program)!="")
}

@(test)
invalid_instance_values_say_what_to_correct :: proc(t:^testing.T) {
    resolved:=effect.PARTICLE_DEFAULTS
    resolved.size_over_life.times[1]=0.1
    joint:Particle_Override
    testing.expect_value(t,value_set(&joint,"size_over_life.times.2",f32(0.2),&resolved),Error.None)
    testing.expect_value(t,value_set(&joint,"size_over_life.times.2",f32(0.05),&resolved),Error.Invalid_Value)
    override:Particle_Override
    long:[effect.PARTICLE_NAME_BYTES]u8
    for &c in long {c='a'}
    testing.expect_value(t,value_set(&override,"rates",f32(1)),Error.Unknown_Field)
    testing.expect_value(t,value_set(&override,"parameters.",f32(1)),Error.Unknown_Field)
    testing.expect_value(t,value_set(&override,strings.concatenate({"parameters.",string(long[:])},context.temp_allocator),f32(1)),Error.Unknown_Field)
    testing.expect_value(t,value_set(&override,"rate",u32(1)),Error.Type_Mismatch)
    testing.expect_value(t,value_set(&override,"parameters.heat","hot"),Error.Type_Mismatch)
    testing.expect_value(t,value_set(&override,"parameters.heat",[5]f32{}),Error.Type_Mismatch)
    testing.expect_value(t,value_set(&override,"parameters.heat",[2]f32{1,math.nan_f32()}),Error.Invalid_Value)
    testing.expect_value(t,value_set(&override,"rate",f32(-1)),Error.Invalid_Value)
    testing.expect_value(t,value_set(&override,"rate",math.inf_f32(1)),Error.Invalid_Value)
    testing.expect_value(t,value_set(&override,"size_over_life.times.1",f32(2)),Error.Invalid_Value)
    testing.expect_value(t,value_set(&override,"material",base.Asset_Id{1,2}),Error.Effect_Field)
    testing.expect_value(t,override.count,u32(0))
    testing.expect_value(t,value_set(&override,"render",effect.Particle_Render.Mesh),Error.None)
    for path in ([?]string{"drag","shell","soft","stretch","bounce","friction","noise","gravity","intensity","inherit_velocity","duration","rate","noise_speed","collision_life","noise_frequency"}) {
        testing.expect_value(t,value_set(&override,path,f32(0.5)),Error.None)
    }
    testing.expect_value(t,value_set(&override,"attractor_strength",f32(1)),Error.Override_Capacity)
    testing.expect_value(t,value_set(&override,"parameters.heat",f32(1)),Error.Override_Capacity)
    testing.expect(t,len(error_message(.Override_Capacity))>0)
    // A hostile row: a count past the room is refused, not read past.
    override.count=PARTICLE_OVERRIDE_CAPACITY+3
    testing.expect_value(t,value_set(&override,"rate",f32(1)),Error.Invalid_Value)
}

// The parameters an instance gives come back as its program declares them:
// numbers of their kind, or a texture.
@(test)
program_parameters_of_an_instance_come_back_as_their_program_declares_them :: proc(t:^testing.T) {
    override:Particle_Override
    testing.expect_value(t,value_set(&override,"parameters.speed",f32(3)),Error.None)
    testing.expect_value(t,value_set(&override,"parameters.tint",[3]f32{1,0.5,0}),Error.None)
    testing.expect_value(t,value_set(&override,"parameters.count",u32(4)),Error.None)
    testing.expect_value(t,value_set(&override,"parameters.pattern",base.Asset_Id{7,8}),Error.None)
    testing.expect_value(t,value_set(&override,"parameters.speed",f32(5)),Error.None)
    testing.expect_value(t,override.count,u32(4))
    declared:=[?]erender.Program_Parameter{{name="speed",kind=.Float,components=1},{name="tint",kind=.Float,components=3},{name="count",kind=.Uint,components=1},{name="pattern",kind=.Texture,components=1}}
    program:=erender.Program{name="Test",parameters=declared[:]}
    Want :: struct {name:string,kind:asset.Parameter_Kind,components:u8,value:[4]f64,texture:base.Asset_Id}
    for want in ([?]Want{{"speed",.Float,1,{5,0,0,0},{}},{"tint",.Float,3,{1,0.5,0,0},{}},{"count",.Uint,1,{4,0,0,0},{}},{"pattern",.Texture,1,{},{7,8}}}) {
        at:=-1
        for name,i in override.names[:override.count] {if name==parameter_hash(want.name) {at=i}}
        parameter,ok:=value_parameter(&program,override.names[max(at,0)],override.values[max(at,0)])
        testing.expectf(t,at>=0 && ok && base.text_get(parameter.name[:])==want.name && parameter.kind==want.kind && parameter.components==want.components && parameter.value==want.value && parameter.texture==want.texture,"%s comes back as %v",want.name,parameter)
    }
    _,undeclared:=value_parameter(&program,parameter_hash("heat"),{})
    testing.expect(t,!undeclared)
}

@(test)
requests_control_an_emitter_from_the_next_step :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{loop=true})
    fixture_tick(&f,TICK)
    clock:=clock_find(&f.clocks,e)
    testing.expect(t,clock!=nil && clock.emitted==0)
    // Start and stop set active, the field the emitter emits by.
    start(&f.requests,e)
    fixture_tick(&f,TICK)
    testing.expect(t,core.at(&f.emitters,0).active)
    status_now,_:=status(&f.clocks,core.at(&f.emitters,0),e)
    testing.expect_value(t,status_now.state,Particle_State.Playing)
    pause(&f.requests,e)
    fixture_tick(&f,TICK)
    paused_at:=clock_find(&f.clocks,e).time
    for _ in 0..<5 {fixture_tick(&f,TICK)}
    testing.expect_value(t,clock_find(&f.clocks,e).time,paused_at)
    resume(&f.requests,e)
    burst(&f.requests,e,12)
    fixture_tick(&f,TICK)
    clock=clock_find(&f.clocks,e)
    testing.expect(t,clock.time>paused_at)
    testing.expect(t,clock.emitted>=12)
    generation,emitted:=clock.generation,clock.emitted
    restart(&f.requests,e)
    fixture_tick(&f,TICK)
    clock=clock_find(&f.clocks,e)
    testing.expect_value(t,clock.generation,generation+1)
    testing.expect_value(t,clock.first,emitted)
    // The renderer starts the new generation from its first birth.
    fixture_sync(&f,{0,1},TICK)
    testing.expect_value(t,sync_shown(&f.sync,e).generation,generation+1)
    stop(&f.requests,e)
    fixture_tick(&f,TICK)
    testing.expect(t,!core.at(&f.emitters,0).active)
    // Nothing it started since its restart is alive.
    status_now,_=status(&f.clocks,core.at(&f.emitters,0),e)
    testing.expect_value(t,status_now.state,Particle_State.Idle)
    // An entity without an emitter is refused.
    other:=core.create(&f.entities)
    burst(&f.requests,other,3)
    fixture_tick(&f,TICK)
    refused:=core.problem_find(&f.problems,other,"vfx.request")
    if testing.expect(t,refused!=nil && refused.count==1) {
        testing.expect_value(t,core.problem_text(refused),"a Burst request of Particle_Requests did nothing on this entity (Invalid_Entity): Name a live entity that has a Particle_Emitter")
    }
}

@(test)
large_sorted_effects_keep_their_requested_capacity :: proc(t:^testing.T) {
    pool:Pool
    if !testing.expect(t,pool_make(&pool,8192)) {return}
    defer pool_free(&pool)
    info:Emitter_Info
    desc:=Emitter_Desc{id=1,capacity=4096,spec=&info}
    desc.info.render,desc.info.sort=.Ribbon,true
    if !testing.expect(t,pool_put(&pool,&desc)) {return}
    testing.expect_value(t,pool.slots[pool_slot_find(&pool,desc.id)].capacity,desc.capacity)
}

@(test)
requests_change_the_values_of_an_instance :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,PARTICLE_EMITTER_DEFAULT)
    testing.expect_value(t,request_value(&f.requests,e,"rate",f32(80)),Error.None)
    testing.expect_value(t,request_value(&f.requests,e,"rate",f32(-1)),Error.Invalid_Value)
    testing.expect_value(t,request_value(&f.requests,e,"parameters.speed",f32(4)),Error.None)
    // Both in one step: the second finds the row the first adds.
    fixture_tick(&f,TICK)
    override,has:=core.get(&f.overrides,e)
    testing.expect(t,has && override.count==2)
    // The clock follows the value of the instance from the next step.
    fixture_tick(&f,TICK)
    testing.expect_value(t,clock_find(&f.clocks,e).emission.rate,f32(80))
    request_value_remove(&f.requests,e,"parameters.speed")
    fixture_tick(&f,TICK)
    override,_=core.get(&f.overrides,e)
    testing.expect_value(t,override.count,u32(1))
    request_values_clear(&f.requests,e)
    fixture_tick(&f,TICK)
    override,_=core.get(&f.overrides,e)
    testing.expect_value(t,override.count,u32(0))
}

// The clocks of the editor's preview go with the frames and do not reach a
// Play: the copy of the world starts its clocks over.
@(test)
a_play_starts_the_clocks_of_the_preview_over :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,PARTICLE_EMITTER_DEFAULT)
    editor:=core.Time{playing=false,dt=0}
    for _ in 0..<5 {fixture_tick(&f,editor,{dt=0.1,alpha=1})}
    testing.expect(t,clock_find(&f.clocks,e).time>0.45)
    testing.expect(t,!f.clocks.playing)
    fixture_tick(&f,TICK)
    testing.expect(t,f.clocks.playing)
    testing.expect_value(t,clock_find(&f.clocks,e).time,f64(TICK.dt))
}

@(test)
done_effects_take_their_entity_with_them :: proc(t:^testing.T) {
    f:Emitters_Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true,destroy_when_done=true})
    fixture_tick(&f,TICK)
    clock:=clock_find(&f.clocks,e)
    clock.resolved=emission_key({},0)
    clock.emission={duration=0.1,rate=30,longest=0.1,tail=0.1}
    f.app.assets=nil
    for _ in 0..<20 {fixture_tick(&f,TICK)}
    testing.expect(t,!core.alive(&f.entities,e))
}

// The births of a channel start once through a rollback: a tick run again
// that pushes a birth again does not start it twice, one only the corrected
// tick pushes starts at its place, one only the corrected run lacks is not
// started if the GPU had not started it, and the births after it keep theirs.
// A channel no emitter listens to keeps none.
@(test)
channel_births_start_once_through_a_rollback :: proc(t:^testing.T) {
    // Births of ticks 4 to 7 by slot (bit i: one at x = 10*tick+i), in the first run and in the
    // corrected one; started: the GPU started the first run before the rollback.
    Case :: struct {name:string,first,corrected:[4]u8,started:bool,expected:[]f32}
    cases:=[?]Case{
        {"the same births",{1,1,1,1},{1,1,1,1},true,nil},
        {"a birth only the corrected tick pushes",{1,1,1,1},{1,3,1,1},true,{51}},
        {"a birth the corrected tick lacks, started",{3,1,1,1},{1,1,1,1},true,nil},
        {"a birth the corrected tick lacks, not started",{3,1,1,1},{1,1,1,1},false,{40,50,60,70}},
        {"a birth only the corrected tick pushes, not started",{1,1,1,1},{1,3,1,1},false,{40,50,51,60,70}},
        {"a birth the correction moves a metre is the same",{1,1,1,1},{1,2,1,1},true,nil},
    }
    for c in cases {
        f:Emitters_Fixture
        if !fixture_init(t,&f) {return}
        e:=fixture_emitter(&f,Particle_Emitter{})
        IMPACTS,NOBODY:=core.birth_channel("impacts"),core.birth_channel("nobody")
        listener:Particle_Channel
        base.text_set(listener.name[:],"impacts")
        core.add(&f.listeners,e,listener)
        fixture_settle(&f)
        f.app.assets=nil
        id:=core.World_Id{0,1}
        tick :: proc(f:^Emitters_Fixture,at:int,slots:u8,again:bool,impacts,nobody:core.Birth_Channel) {
            for i in 0..<8 {
                if slots&(1<<u8(i))!=0 {core.birth(&f.births,core.Birth{channel=impacts,position={f32(10*at+i),0,0},count=3})}
            }
            core.birth(&f.births,core.Birth{channel=nobody,count=1})
            time:=TICK
            time.tick,time.resimulating=u64(at),again
            fixture_tick(f,time)
        }
        for at in 0..<4 {tick(&f,at,1,false,IMPACTS,NOBODY)}
        fixture_sync(&f,id,TICK)
        saved:Particle_Clocks
        testing.expect(t,core.value_copy(&saved,&f.clocks,type_info_of(Particle_Clocks)))
        for at in 4..<8 {tick(&f,at,c.first[at-4],false,IMPACTS,NOBODY)}
        testing.expect_value(t,len(f.clocks.channels),1)
        if c.started {fixture_sync(&f,id,TICK)}
        testing.expect(t,core.value_copy(&f.clocks,&saved,type_info_of(Particle_Clocks)))
        core.value_free(&saved,type_info_of(Particle_Clocks))
        for at in 4..<8 {tick(&f,at,c.corrected[at-4],true,IMPACTS,NOBODY)}
        fixture_sync(&f,id,TICK)
        got:=make([dynamic]f32,context.temp_allocator)
        for b in f.sync.births {append(&got,b.position.x)}
        slice.sort(got[:])
        testing.expectf(t,slice.equal(got[:],c.expected),"%s: the GPU starts %v, not %v",c.name,got[:],c.expected)
        tick(&f,8,1,false,IMPACTS,NOBODY)
        fixture_sync(&f,id,TICK)
        testing.expectf(t,len(f.sync.births)==1 && f.sync.births[0].position.x==80,"%s: the birth after the rollback starts once at its place, not %v",c.name,f.sync.births[:])
        fixture_destroy(&f)
    }
}

// A tick run again pairs its births with those of the run it corrects by the
// entity that causes each, one to one and the nearest first; births of no
// entity pair with the nearest of none within BIRTH_SAME_DISTANCE. A paired
// birth the GPU did not start takes the corrected place; a load forgets what
// was kept. The ticks allocate nothing.
@(test)
channel_births_pair_by_what_causes_them :: proc(t:^testing.T) {
    // by: 0 none, 1 and 2 two entities.
    Pushed :: struct {by:int,x:f32}
    Case :: struct {name:string,first,corrected:[]Pushed,started,loaded:bool,expected:[]f32}
    cases:=[?]Case{
        {"two entities side by side both start",{{1,0}},{{2,0.2},{1,0}},true,false,{0.2}},
        {"another entity in the place of one starts",{{1,0}},{{2,0.2}},true,false,{0.2}},
        {"an entity corrected by 5 m is not drawn twice",{{1,0}},{{1,5}},true,false,nil},
        {"an entity corrected before it started takes the corrected place",{{1,0}},{{1,0.5}},false,false,{0.5}},
        {"an entity corrected by 5 m before it started",{{1,0}},{{1,5}},false,false,{5}},
        {"two births of one entity pair one to one",{{1,0},{1,3}},{{1,10},{1,11},{1,12}},true,false,{12}},
        {"two births of one entity pair the nearest",{{1,0},{1,0.8}},{{1,0.7},{1,-0.1}},false,false,{-0.1,0.7}},
        {"births of none pair the nearest",{{0,0},{0,0.9}},{{0,0.8},{0,0.05}},false,false,{0.05,0.8}},
        {"a birth of none farther than the distance starts",{{0,0}},{{0,1.5}},true,false,{1.5}},
        {"a birth of none is not one of an entity",{{1,0}},{{0,0}},true,false,{0}},
        {"a load forgets the births kept",{{1,0}},{{1,0}},true,true,{0}},
    }
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    for c in cases {
        f:=new(Emitters_Fixture)
        defer free(f)
        if !fixture_init(t,f) {return}
        e:=fixture_emitter(f,Particle_Emitter{})
        listener:Particle_Channel
        base.text_set(listener.name[:],"impacts")
        core.add(&f.listeners,e,listener)
        fixture_settle(f)
        f.app.assets=nil
        by:=[3]core.Entity{core.NONE,core.create(&f.entities),core.create(&f.entities)}
        Tick :: struct {f:^Emitters_Fixture,by:[3]core.Entity,tracker:^mem.Tracking_Allocator}
        tick :: proc(k:Tick,at:u64,pushed:[]Pushed,again:bool) {
            for p in pushed {core.birth(&k.f.births,core.Birth{channel=core.birth_channel("impacts"),by=k.by[p.by],position={p.x,0,0}})}
            time:=TICK
            time.tick,time.resimulating=at,again
            context.allocator=mem.tracking_allocator(k.tracker)
            fixture_tick(k.f,time)
        }
        // A birth to a channel nobody listens to makes the room of the log.
        core.birth(&f.births,core.Birth{channel=core.birth_channel("nobody")})
        fixture_tick(f,TICK)
        k:=Tick{f,by,&tracker}
        id:=core.World_Id{0,1}
        mem.tracking_allocator_reset(&tracker)
        saved:Particle_Clocks
        testing.expect(t,core.value_copy(&saved,&f.clocks,type_info_of(Particle_Clocks)))
        tick(k,1,c.first,false)
        if c.started {fixture_sync(f,id,TICK)}
        if c.loaded {
            tick(k,0,nil,false)
            tick(k,1,nil,false)
        }
        testing.expect(t,core.value_copy(&f.clocks,&saved,type_info_of(Particle_Clocks)))
        core.value_free(&saved,type_info_of(Particle_Clocks))
        tick(k,1,c.corrected,true)
        testing.expectf(t,tracker.total_allocation_count==0,"%s: the ticks allocated %d times",c.name,tracker.total_allocation_count)
        fixture_sync(f,id,TICK)
        got:=make([dynamic]f32,context.temp_allocator)
        for b in f.sync.births {append(&got,b.position.x)}
        slice.sort(got[:])
        testing.expectf(t,slice.equal(got[:],c.expected),"%s: the GPU starts %v, not %v",c.name,got[:],c.expected)
        fixture_destroy(f)
    }
}

// Births that find no room are reported, never dropped in silence: those past
// core.BIRTHS_CAPACITY in the log, and those a channel gives up before the
// GPU started them.
@(test)
births_without_room_are_reported :: proc(t:^testing.T) {
    Case :: struct {name:string,pushed:int,want:string}
    cases:=[?]Case{
        {"within the room of the log and of the channel",CHANNEL_BIRTHS,""},
        {"past the room of a channel",CHANNEL_BIRTHS+6,"6 births of a channel were lost"},
        {"past the room of the log",core.BIRTHS_CAPACITY+3,"3 births were lost"},
    }
    for c in cases {
        f:Emitters_Fixture
        if !fixture_init(t,&f) {return}
        e:=fixture_emitter(&f,Particle_Emitter{})
        listener:Particle_Channel
        base.text_set(listener.name[:],"impacts")
        core.add(&f.listeners,e,listener)
        fixture_settle(&f)
        f.app.assets=nil
        for i in 0..<c.pushed {core.birth(&f.births,core.Birth{channel=core.birth_channel("impacts"),position={f32(i),0,0}})}
        fixture_tick(&f,TICK)
        fixture_sync(&f,core.World_Id{0,1},TICK)
        problem:=core.problem_find(&f.problems,core.NONE,"vfx.births")
        if c.want=="" {
            testing.expectf(t,problem==nil,"%s: a problem was reported",c.name)
        } else {
            testing.expectf(t,problem!=nil && strings.contains(base.text_get(problem.text[:]),c.want),"%s: no problem says %q",c.name,c.want)
        }
        fixture_destroy(&f)
    }
}

// The textures of the world reach a view relative to its origin: the region
// of a grid far from the centre of the world, and the uv of its lowest corner,
// which the cells before it in the world turned.
@(test)
world_textures_reach_a_view_relative_to_its_origin :: proc(t:^testing.T) {
    shown:World_Textures_Frame
    shown.names[1],shown.textures[1]=world_texture_name("fluid"),5
    shown.first[1],shown.cells[1],shown.cell_size[1]={-80010,60003},{64,32},0.25
    frame:=world_frame_gpu(shown,{-20000,512,15000})
    testing.expect_value(t,frame.names,shown.names)
    testing.expect_value(t,frame.textures,shown.textures)
    testing.expect_value(t,frame.bounds[1],[4]f32{-2.5,0.75,13.5,8.75})
    // -80010 is 10 cells past a turn of 64 below zero: 54 of them; 60003 is 3 past a turn of 32.
    testing.expect_value(t,frame.starts[0].zw,[2]f32{54.0/64,3.0/32})
    testing.expect_value(t,frame.bounds[0],[4]f32{})
}

// The rows of an emitter place it relative to the origin, and keep how it turns.
@(test)
emitter_rows_are_relative_to_the_origin :: proc(t:^testing.T) {
    m:=mm.transform_matrix(mm.Transform{position={20000.5,-3,-9000.25},rotation=1,scale=2})
    rows:=rows_of(m,{19456,0,-9216})
    testing.expect_value(t,rows[0],[4]f32{2,0,0,544.5})
    testing.expect_value(t,rows[1],[4]f32{0,2,0,-3})
    testing.expect_value(t,rows[2],[4]f32{0,0,2,215.75})
}

// count particles born at once, age seconds before the end of the frame.
@(private)
test_burst :: proc(count: u32, birth: u32 = 0, age: f32 = 0) -> (spawns: [SPAWNS]Particle_Spawn) {
	spawns[0] = {count = count, per = count, birth = birth, age = age}
	return
}

// count particles one by one over dt seconds, the last one at the end of the frame.
@(private)
test_rate :: proc(count: u32, dt: f32, birth: u32 = 0) -> (spawns: [SPAWNS]Particle_Spawn) {
	spacing := dt / f32(max(count, 1))
	spawns[0] = {count = count, per = 1, birth = birth, age = spacing * f32(max(count, 1) - 1), spacing = spacing}
	return
}

@(test)
particle_ranges_join_again_when_they_return_to_the_pool :: proc(t: ^testing.T) {
	p: Pool
	p.capacity = 1000
	p.slots = make([]Pool_Slot, 8)
	p.order = make([]u16, 8)
	base.ranges_reset(&p.free, 1000, 8)
	if !testing.expect(t,base.hash_map_init(&p.by_id,8)) {return}
	defer {delete(p.slots); delete(p.order); base.ranges_free(&p.free); base.hash_map_destroy(&p.by_id)}
	a, b, c := pool_slot_take(&p, 30, 100), pool_slot_take(&p, 10, 200), pool_slot_take(&p, 20, 300)
	testing.expect_value(t, p.slots[a].offset, u32(0))
	testing.expect_value(t, p.slots[b].offset, u32(100))
	testing.expect_value(t, p.slots[c].offset, u32(300))
	testing.expect_value(t, pool_slot_find(&p, 10), b)
	testing.expect_value(t, pool_slot_find(&p, 99), -1)
	testing.expect_value(t, pool_slot_take(&p, 40, 500), -1)
	pool_slot_release(&p, b)
	testing.expect_value(t, len(p.free.free), 2)
	pool_slot_release(&p, a)
	testing.expect_value(t, len(p.free.free), 2)
	testing.expect_value(t, p.free.free[0], base.Range{0, 300})
	testing.expect_value(t, p.pool_end, u32(600))
	pool_slot_release(&p, c)
	testing.expect_value(t, len(p.free.free), 1)
	testing.expect_value(t, p.free.free[0], base.Range{0, 1000})
	testing.expect_value(t, p.slot_end, 0)
	whole := pool_slot_take(&p, 40, 1000)
	testing.expect_value(t, p.slots[whole].offset, u32(0))
	testing.expect_value(t, pool_slot_find(&p, 40), whole)
}

// Lists that come before a frame add their births: those of the first ones
// grow older, and past SPAWNS neighbours join without losing any.
@(test)
particle_births_of_lists_between_frames_join_without_losing_any :: proc(t: ^testing.T) {
	spawns: [SPAWNS]Particle_Spawn
	first := test_burst(5, 0, 0.01)
	second := test_rate(4, 0.02, 5)
	spawns_join(&spawns, first, second, 0.02)
	testing.expect_value(t, spawns[0].age, f32(0.03))
	testing.expect_value(t, spawns[1].count, u32(4))
	many: [SPAWNS]Particle_Spawn
	for &s, i in many {s = {count = 2, per = 2, birth = u32(i) * 2, age = 0.05 - f32(i) * 0.005}}
	spawns_join(&spawns, many, many, 0.1)
	total: u32
	for s in spawns {total += s.count}
	testing.expect_value(t, total, u32(32))
	for s in spawns {
		testing.expect(t, s.count > 0)
		testing.expectf(t, spawn_youngest(s) >= -1e-6 && s.age <= 0.15 + 1e-6, "a joined group spans what its births spanned: %v", s)
	}
}

// A renderer without a device whose catalog has the Vfx programs given, each
// with float parameters of those names: what the values of an instance are
// checked against. Its assets let go of it before they are destroyed.
@(private="file")
fake_programs :: proc(a:^host.Assets,programs:[]struct{name:string,parameters:[]string}) -> ^gpu.Renderer {
    r:=new(gpu.Renderer,context.temp_allocator)
    list:=make([]gpu.Program,len(programs),context.temp_allocator)
    for each,i in programs {
        parameters:=make([]gpu.Program_Parameter,len(each.parameters),context.temp_allocator)
        for name,k in each.parameters {parameters[k]={name=name,kind=.Float,components=1,offset=u16(16*k),min=-1000,max=1000}}
        list[i]={id=u32(i+1),name=each.name,domain=.Vfx,size=16*len(each.parameters),parameters=parameters}
    }
    r.programs={programs=list,loaded=true}
    a.renderer=r
    return r
}

// An effect of layers at folder, each with the program named, saved and read.
@(private="file")
fake_effect :: proc(t:^testing.T,folder:string,id:base.Asset_Id,layers:[]effect.Particle_Info) -> bool {
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    path:=strings.concatenate({folder,"/fake.particle"},context.temp_allocator)
    return testing.expect_value(t,effect.particle_save(path,&types,{id=id,info=layers[0],layers=layers[1:]}),asset.Error.None)
}

@(private="file")
layer_of :: proc(program:string,rate:f32) -> (info:effect.Particle_Info) {
    info=effect.PARTICLE_DEFAULTS
    info.rate=rate
    base.text_set(info.program[:],program)
    return
}

// A game that changes a value of an emitter every frame (a parameter it
// animates) writes it in place: once warm, no frame allocates, the row of
// the emitter goes to the GPU again and the pool keeps how it grouped its
// programs.
@(test)
an_animated_value_allocates_nothing_and_keeps_the_pool_grouped :: proc(t:^testing.T) {
    f:=new(Emitters_Fixture)
    defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    folder:=base.test_folder(t,"vfx-animated")
    id:=base.Asset_Id{0x616e696d,1}
    layers:=[2]effect.Particle_Info{layer_of("Heat",10),layer_of("Heat",5)}
    if !fake_effect(t,folder,id,layers[:]) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder})) {return}
    defer host.assets_destroy(&assets)
    defer assets.renderer=nil
    fake_programs(&assets,{{"Heat",{"heat"}}})
    f.app.assets=&assets
    e:=fixture_emitter(f,Particle_Emitter{particle=id,active=true,loop=true})
    if !testing.expect(t,pool_make(&f.sync.pool,8192)) {return}
    frame :: proc(f:^Emitters_Fixture,e:core.Entity,value:f32) {
        _=request_value(&f.requests,e,"parameters.heat",value)
        _=request_value(&f.requests,e,"colors.0",[4]f32{value/10,0,0,1})
        fixture_tick(f,TICK)
        fixture_sync(f,{0,1},TICK)
        for layer in 0..<2 {
            if shown:=shown_find(&f.sync,e,layer);shown!=nil {pool_put(&f.sync.pool,&shown.desc)}
        }
    }
    for i in 0..<3 {frame(f,e,f32(i))}
    f.sync.pool.regroup=false
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    regrouped:=false
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for i in 0..<8 {
            for &s in f.sync.pool.slots[:f.sync.pool.slot_end] {s.look_dirty,s.program_dirty=false,false}
            frame(f,e,4+f32(i))
            regrouped||=f.sync.pool.regroup
            for layer in 0..<2 {
                at:=pool_slot_find(&f.sync.pool,layer_id(e,layer))
                if !testing.expect(t,at>=0) {return}
                s:=&f.sync.pool.slots[at]
                testing.expectf(t,s.look_dirty && s.program_dirty,"layer %d writes its row and parameters again",layer)
                testing.expect_value(t,s.desc.program.parameters[0][0],4+f32(i))
            }
        }
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect(t,!regrouped,"a value that changes alone does not group the pool again")
    shown:=shown_find(&f.sync,e,0)
    testing.expect(t,shown.desc.spec.owned && abs(shown.desc.info.colors[0].x-1.1)<1e-5)
}

// layers.N. names a layer: its fields change that layer alone. A parameter
// without it reaches every layer whose program declares it and leaves the
// others; one no program declares is a problem of the primary layer. A burst
// and the status name a layer or take all of them.
@(test)
layer_paths_change_their_layer_and_parameters_every_layer_that_declares_them :: proc(t:^testing.T) {
    f:=new(Emitters_Fixture)
    defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    folder:=base.test_folder(t,"vfx-layer-paths")
    id:=base.Asset_Id{0x6c617972,1}
    layers:=[3]effect.Particle_Info{layer_of("Heat",10),layer_of("Heat",5),layer_of("Cold",2)}
    if !fake_effect(t,folder,id,layers[:]) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder})) {return}
    defer host.assets_destroy(&assets)
    defer assets.renderer=nil
    fake_programs(&assets,{{"Heat",{"heat"}},{"Cold",{"chill","heat_unused"}}})
    f.app.assets=&assets
    e:=fixture_emitter(f,Particle_Emitter{particle=id,loop=true})
    testing.expect_value(t,request_value(&f.requests,e,"layers.1.rate",f32(40)),Error.None)
    testing.expect_value(t,request_value(&f.requests,e,"parameters.heat",f32(7)),Error.None)
    testing.expect_value(t,request_value(&f.requests,e,"layers.2.parameters.chill",f32(3)),Error.None)
    testing.expect_value(t,request_value(&f.requests,e,"layers.8.rate",f32(1)),Error.Unknown_Field)
    testing.expect_value(t,request_value(&f.requests,e,"layers.x.rate",f32(1)),Error.Unknown_Field)
    fixture_tick(f,TICK)
    fixture_tick(f,TICK)
    fixture_sync(f,{0,1},TICK)
    Case :: struct {layer:int,rate:f32,parameter:f32}
    for c in ([]Case{{0,10,7},{1,40,7},{2,2,3}}) {
        clock:=clock_find(&f.clocks,e,c.layer)
        shown:=shown_find(&f.sync,e,c.layer)
        if !testing.expectf(t,clock!=nil && shown!=nil,"layer %d has a clock and was told",c.layer) {continue}
        testing.expectf(t,clock.emission.rate==c.rate && shown.desc.info.rate==c.rate,"layer %d emits %v, not %v",c.layer,c.rate,clock.emission.rate)
        testing.expectf(t,shown.desc.program.parameters[0][0]==c.parameter,"layer %d takes %v, not %v",c.layer,c.parameter,shown.desc.program.parameters[0][0])
        testing.expectf(t,base.text_get(shown.problem[:])=="","layer %d runs its program: %s",c.layer,base.text_get(shown.problem[:]))
    }
    // A layer that does not exist is refused when its request is taken.
    testing.expect_value(t,request_value(&f.requests,e,"layers.5.rate",f32(1)),Error.None)
    f.problems={}
    fixture_tick(f,TICK)
    testing.expect_value(t,f.problems.count,1)
    // A parameter no layer declares.
    testing.expect_value(t,request_value(&f.requests,e,"parameters.nothing",f32(1)),Error.None)
    fixture_tick(f,TICK)
    fixture_sync(f,{0,1},TICK)
    testing.expect(t,base.text_get(shown_find(&f.sync,e,0).problem[:])!="")
    testing.expect(t,base.text_get(shown_find(&f.sync,e,1).problem[:])=="")
    // A burst of a layer, then of all; the status of each layer and of the whole.
    burst(&f.requests,e,4,layer=1)
    fixture_tick(f,TICK)
    emitted:[3]u64
    for &n,layer in emitted {n=clock_find(&f.clocks,e,layer).emitted}
    testing.expect_value(t,emitted,[3]u64{0,4,0})
    burst(&f.requests,e,2)
    fixture_tick(f,TICK)
    whole,found:=status(&f.clocks,PARTICLE_EMITTER_DEFAULT,e)
    testing.expect(t,found && whole.layers==3 && whole.emitted==10)
    one,_:=status(&f.clocks,PARTICLE_EMITTER_DEFAULT,e,1)
    testing.expect_value(t,one.emitted,u64(6))
    _,beyond:=status(&f.clocks,PARTICLE_EMITTER_DEFAULT,e,3)
    testing.expect(t,!beyond)
}

// The box of an emitter holds every place its particles reach, from their
// speed, the gravity and the wind of the world, the motion of their entity
// and their bounces: an emitter is culled by the frustum unless its program
// moves its particles or a surface starts them.
@(test)
emitter_bounds_hold_what_forces_and_motion_reach :: proc(t:^testing.T) {
    Case :: struct {
        name:string,
        gravity,drag,inherit:f32,
        collision:effect.Particle_Collision,
        shape:effect.Particle_Shape,
        program:u32,
        reach:[3]f32, // a place a particle reaches
        unbounded:bool,
    }
    LIFE,SPEED :: f32(2),f32(5)
    cases:=[]Case{
        {name="gravity",gravity=1,reach={0,SPEED*LIFE-0.5*9.81*LIFE*LIFE,0}},
        {name="gravity of the world",gravity=2,reach={0,-0.5*2*50*LIFE*LIFE,0}},
        {name="drag into the wind",drag=3,reach={50*LIFE,SPEED*LIFE,0}},
        {name="inherit",inherit=0.5,reach={0.5*60*LIFE,SPEED*LIFE,0}},
        {name="collision",collision=.World,gravity=1,reach={SPEED*LIFE,0,0}},
        {name="program",program=1,unbounded=true},
        {name="surface",shape=.Surface,unbounded=true},
    }
    for c in cases {
        pool:Pool
        if !testing.expect(t,pool_make(&pool,4096)) {return}
        defer pool_free(&pool)
        pool.dt,pool.gravity_reach,pool.wind_reach=1.0/60,50,50
        info:Emitter_Info
        info.info=effect.PARTICLE_DEFAULTS
        m:=&info.info
        m.lifetime,m.speed,m.gravity,m.drag,m.inherit_velocity,m.collision,m.shape=LIFE,SPEED,c.gravity,c.drag,c.inherit,c.collision,c.shape
        info.program.id=c.program
        // It moved a metre along x in the frame.
        desc:=Emitter_Desc{id=1,capacity=64,spec=&info,transform=1,previous=1}
        desc.previous[0,3]=-1
        if !testing.expect(t,pool_put(&pool,&desc)) {return}
        s:=&pool.slots[pool_slot_find(&pool,1)]
        testing.expectf(t,s.unbounded==c.unbounded,"%s: unbounded %v",c.name,s.unbounded)
        if c.unbounded {continue}
        for axis in 0..<3 {
            testing.expectf(t,abs(s.bounds_min[axis])<1e30 && abs(s.bounds_max[axis])<1e30,"%s: a finite box",c.name)
            testing.expectf(t,s.bounds_min[axis]<=c.reach[axis] && c.reach[axis]<=s.bounds_max[axis] && s.bounds_min[axis]<=-c.reach[axis] && -c.reach[axis]<=s.bounds_max[axis],
                "%s: %v inside %v %v",c.name,c.reach,s.bounds_min,s.bounds_max)
        }
    }
}

// An effect that runs at most max_instances emitters keeps the nearest to
// the simulation sources; one with a cull_distance waits past it. Those
// that wait keep their clock and are not drawn; no step allocates once warm.
@(test)
emitters_past_their_cull_distance_or_max_instances_wait :: proc(t:^testing.T) {
    f:=new(Emitters_Fixture)
    defer free(f)
    if !fixture_init(t,f) {return}
    defer fixture_destroy(f)
    folder:=base.test_folder(t,"vfx-cull")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    crowd,far:=base.Asset_Id{0x63756c6c,1},base.Asset_Id{0x63756c6c,2}
    crowded:=effect.PARTICLE_DEFAULTS
    crowded.max_instances=2
    distant:=effect.PARTICLE_DEFAULTS
    distant.cull_distance=10
    testing.expect_value(t,effect.particle_save(strings.concatenate({folder,"/crowd.particle"},context.temp_allocator),&types,{id=crowd,info=crowded}),asset.Error.None)
    testing.expect_value(t,effect.particle_save(strings.concatenate({folder,"/far.particle"},context.temp_allocator),&types,{id=far,info=distant}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder})) {return}
    defer host.assets_destroy(&assets)
    f.app.assets=&assets
    xs:=[4]f32{4,1,3,2}
    crowds:[4]core.Entity
    for &e,i in crowds {e=fixture_emitter(f,Particle_Emitter{particle=crowd,active=true,loop=true},{xs[i],0,0})}
    near:=fixture_emitter(f,Particle_Emitter{particle=far,active=true,loop=true},{5,0,0})
    away:=fixture_emitter(f,Particle_Emitter{particle=far,active=true,loop=true},{25,0,0})
    f.sources.count=1
    step :: proc(f:^Emitters_Fixture,source:f32) {
        f.sources.items[0].position={source,0,0}
        fixture_tick(f,TICK)
        fixture_sync(f,{0,1},TICK)
    }
    Case :: struct {source:f32,waiting:[6]bool}
    cases:=[]Case{
        {0,{true,false,true,false,false,true}},   // the two nearest of x 1 and 2; 25 is past 10
        {5,{false,true,false,true,false,true}},   // 4 and 3 now
        {20,{false,true,false,true,true,false}},  // 4 and 3 again; x 25 within 10, x 5 past it
    }
    all:=[6]core.Entity{crowds[0],crowds[1],crowds[2],crowds[3],near,away}
    for c in cases {
        step(f,c.source)
        for e,i in all {
            clock:=clock_find(&f.clocks,e)
            shown:=sync_shown(&f.sync,e)
            if !testing.expect(t,clock!=nil && shown!=nil) {return}
            testing.expectf(t,clock.culled==c.waiting[i] && shown.culled==c.waiting[i] && shown.paused==c.waiting[i],"source at %v: emitter %d waits %v",c.source,i,clock.culled)
            s,_:=status(&f.clocks,PARTICLE_EMITTER_DEFAULT,e)
            testing.expect(t,(s.state==.Culled)==c.waiting[i])
        }
    }
    // A clock that waits stands still.
    before:=clock_find(&f.clocks,away).time
    step(f,cases[0].source)
    testing.expect_value(t,clock_find(&f.clocks,away).time,before)
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for i in 0..<12 {step(f,cases[i%len(cases)].source)}
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
}

// A ribbon is a stretch of emission: births of a clock that starts to emit
// again, or whose entity jumps (core.Jump), join another one, which the GPU
// is told by group of births; groups of one ribbon join before two of two.
@(test)
ribbons_begin_again_where_emission_starts_again_or_the_emitter_jumps :: proc(t:^testing.T) {
    e:=Emission{duration=1,rate=60,longest=1,tail=1}
    clock:Emitter_Clock
    emitter:=Particle_Emitter{active=true,loop=true}
    PLAYING :: core.Time{playing=true}
    tick :: proc(clock:^Emitter_Clock,emitter:Particle_Emitter,position,before:[3]f32) {
        world:=core.World_Transform{transform={position=position,rotation=1,scale={1,1,1}},previous={position=before,rotation=1,scale={1,1,1}}}
        emitter_tick(clock,emitter,{},world,1.0/60,PLAYING,nil,nil,false)
    }
    clock.emission=e
    for i in 0..<4 {tick(&clock,emitter,{f32(i),0,0},{f32(i-1) if i>0 else 0,0,0})}
    first:=clock.segment
    testing.expect(t,first>0,"emission that starts begins a segment")
    started:u64
    slash:=births_since(&clock,&started)
    testing.expect(t,slash[0].count>0 && slash[0].ribbon==first)
    // It stops, then emits again: another ribbon.
    emitter.active=false
    for i in 4..<6 {tick(&clock,emitter,{f32(i),0,0},{f32(i-1),0,0})}
    testing.expect_value(t,clock.segment,first)
    emitter.active=true
    tick(&clock,emitter,{6,0,0},{5,0,0})
    second:=births_since(&clock,&started)
    testing.expect(t,clock.segment==first+1 && second[0].count>0 && second[0].ribbon==first+1,"emission that starts again joins another ribbon")
    // Its entity jumps: where it was before this tick is not where the clock saw it.
    tick(&clock,emitter,{50,0,0},{40,0,0})
    testing.expect_value(t,clock.segment,first+2)
    tick(&clock,emitter,{51,0,0},{50,0,0})
    testing.expect_value(t,clock.segment,first+2)
    // A full clock joins its two oldest groups of one segment.
    full:Emitter_Clock
    full.segment=1
    births_add(&full,0,1,1,0)
    full.segment=2
    for k in 1..<PARTICLE_BIRTHS {births_add(&full,f64(k),1,1,0)}
    births_add(&full,9,1,1,0)
    testing.expect(t,full.births[0].segment==1 && full.births[0].count==1,"the group of the first ribbon stays apart")
    testing.expect(t,full.births[1].segment==2 && full.births[1].count==2)
    // And so do the groups given to the GPU.
    before,after:[SPAWNS]Particle_Spawn
    for k in 0..<SPAWNS {before[k]={count=1,per=1,birth=u32(k),age=f32(SPAWNS-k),ribbon=1 if k==0 else 2}}
    after[0]={count=1,per=1,birth=SPAWNS,age=0,ribbon=2}
    joined:[SPAWNS]Particle_Spawn
    spawns_join(&joined,before,after,0)
    testing.expect(t,joined[0].ribbon==1 && joined[0].count==1,"a group of another ribbon does not join")
}

// Mesh particles blend as the alpha mode of their material says: Opaque and
// Mask go into the G-buffer, Blend and Additive over the lit scene.
@(test)
mesh_particles_blend_as_the_alpha_mode_of_their_material :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"vfx-mesh-blend")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    modes:=[asset.Alpha_Mode]bool{.Opaque=false,.Mask=false,.Blend=true,.Additive=true}
    for mode in asset.Alpha_Mode {
        info:=asset.MATERIAL_DEFAULTS
        info.alpha_mode=mode
        path:=strings.concatenate({folder,"/",reflect.enum_string(mode),".mat"},context.temp_allocator)
        testing.expect_value(t,asset.material_save(path,&types,{id={9,u64(mode)+1},info=info}),asset.Error.None)
    }
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder})) {return}
    defer host.assets_destroy(&assets)
    for blended,mode in modes {
        spec:Emitter_Info
        spec.info=effect.PARTICLE_DEFAULTS
        spec.info.render,spec.info.material=.Mesh,{9,u64(mode)+1}
        d,_:=emitter_desc(&spec,&assets,nil,1,0)
        testing.expectf(t,d.blended==blended,"a mesh of a material %v blends: %v",mode,d.blended)
    }
}
