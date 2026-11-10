package vfx

import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

@(private="file")
Emitters_Fixture :: struct {
    entities:core.Entities,
    emitters:core.Table(Particle_Emitter),
    worlds:core.Table(core.World_Transform),
    overrides:core.Table(Particle_Override),
    parameters:core.Table(Particle_Parameters),
    hidden:core.Table(erender.Hidden),
    parents:core.Table(core.Parent),
    bindings:core.Table(Particle_Bindings),
    listeners:core.Table(Particle_Channel),
    grids:core.Table(Particle_Grid),
    volumes:core.Table(Particle_Volume),
    textures:core.Table(Particle_World_Texture),
    channels:Particle_Channels,
    reports:Particle_Reports,
    meshes:core.Table(erender.Mesh_Renderer),
    drawn:erender.Render_Sync,
    hierarchy:core.Hierarchy,
    clocks:Particle_Clocks,
    requests:Particle_Requests,
    sync:Particle_Sync,
    settings:Particle_Settings,
    app:host.App,
    problems:core.Problems,
}

@(private="file")
fixture_init :: proc(f:^Emitters_Fixture) {
    core.entities_init(&f.entities)
    f.settings=PARTICLE_SETTINGS_DEFAULT
}

@(private="file")
fixture_destroy :: proc(f:^Emitters_Fixture) {
    core.table_destroy(&f.emitters);core.table_destroy(&f.worlds);core.table_destroy(&f.overrides)
    core.table_destroy(&f.parameters);core.table_destroy(&f.hidden);core.table_destroy(&f.parents);core.table_destroy(&f.bindings);core.table_destroy(&f.meshes);core.table_destroy(&f.listeners);core.table_destroy(&f.grids);core.table_destroy(&f.volumes);core.table_destroy(&f.textures);core.value_free(&f.channels,type_info_of(Particle_Channels));particle_reports_free(&f.reports);core.value_free(&f.hierarchy,type_info_of(core.Hierarchy))
    core.value_free(&f.clocks,type_info_of(Particle_Clocks))
    core.value_free(&f.requests,type_info_of(Particle_Requests))
    particle_sync_free(&f.sync)
    core.entities_destroy(&f.entities)
}

@(private="file")
fixture_settle :: proc(f:^Emitters_Fixture) {
    core.table_settle(&f.emitters,&f.entities);core.table_settle(&f.worlds,&f.entities)
    core.table_settle(&f.overrides,&f.entities);core.table_settle(&f.parameters,&f.entities)
    core.table_settle(&f.parents,&f.entities);core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities);core.entities_settle(&f.entities)
}

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
    particles_tick(core.read(&f.emitters),&f.overrides,&f.parameters,core.read(&f.worlds),core.ref(&f.hierarchy),&f.entities,&f.clocks,&f.requests,&f.channels,core.read(&f.listeners),time,frame,f.app.assets,&f.problems)
    fixture_settle(f)
}

@(private="file")
fixture_sync :: proc(f:^Emitters_Fixture,id:core.World_Id,time:core.Time,frame:=FRAME) {
    particles_sync(core.read(&f.emitters),core.read(&f.overrides),core.read(&f.parameters),core.read(&f.worlds),core.read(&f.hidden),core.read(&f.parents),core.read(&f.bindings),core.read(&f.meshes),core.ref(&f.drawn),core.read(&f.listeners),core.read(&f.grids),core.read(&f.volumes),core.read(&f.textures),core.ref(&f.clocks),core.ref(&f.settings),&f.sync,&f.reports,nil,nil,nil,nil,{},id,time,frame,{},&f.problems,&f.app,{},{},{})
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
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true},{8,2,-16})
    current:=mm.TRANSFORM_IDENTITY;current.position={8,2,-16}
    time,frame:=core.Time{playing=true},core.Frame_Time{dt=1.0/60}
    fixture_sync(&f,{0,1},time,frame)
    testing.expect_value(t,len(f.sync.shown.values),1)
    testing.expect_value(t,f.sync.shown.values[0].transform,mm.transform_matrix(current))
    next:=current;next.position.x+=2
    core.get(&f.worlds,e)^=core.World_Transform{next,current}
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
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true})
    // The effect: a burst of 7 at the start of each cycle of half a second, nothing else.
    clock_of(&f.clocks,e)
    f.clocks.playing=true
    clock:=clock_find(&f.clocks,e)
    clock.resolved=emission_key({},nil,0)
    clock.emission={duration=0.5,longest=1,tail=1,rate_over_cycle=effect.PARTICLE_CURVE_ONE}
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
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true,loop=true})
    for _ in 0..<2 {fixture_tick(&f,TICK)}
    clock:=clock_find(&f.clocks,e)
    clock.resolved=emission_key({},nil,0)
    clock.emission={duration=1,rate=60,longest=1,tail=1,rate_over_cycle=effect.PARTICLE_CURVE_ONE}
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
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    core.table_init(&f.emitters,"Particle_Emitter");core.table_init(&f.worlds,"World_Transform")
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
    copy.rate_over_cycle=effect.PARTICLE_CURVE_ONE
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

@(test)
the_rate_follows_its_curve_along_the_cycle :: proc(t:^testing.T) {
    info:=effect.Particle_Info{duration=1,rate=40,lifetime={1,1}}
    // Twice the rate in the first half of the cycle, none in the second.
    info.rate_over_cycle={values={2,2,0,0,0,0,0,0},times={0,0.5,0.5,1,1,1,1,1}}
    e:=emission_of(nil,&info)
    clock:Emitter_Clock
    testing.expect_value(t,steps(&e,true,&clock,4),u64(40))
    testing.expect_value(t,steps(&e,true,&clock,4),u64(0))
}

// particles.slang copies values of the plugin by hand: each is the Odin one.
@(test)
the_values_particles_slang_copies_are_those_of_the_plugin :: proc(t:^testing.T) {
    defines:=make(map[string]u64,context.temp_allocator)
    rest:=string(#load("../shaders/particles.slang"))
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
        {"PARTICLE_STATE_BYTES",STATE_BYTES},{"PARTICLE_SPAWNS",SPAWNS},{"PARTICLE_CURVE_KEYS",effect.PARTICLE_CURVE_KEYS},
        {"PARTICLE_EVENT_CAPACITY",EVENT_CAPACITY},{"PARTICLE_EVENTS_AT",EVENTS_AT/4},{"PARTICLE_EVENT_WORDS",size_of(Gpu_Event)/4},
        {"PARTICLE_REPORT_CAPACITY",REPORT_CAPACITY},{"PARTICLE_REPORT_WORDS",size_of(Gpu_Report)/4},
        {"PARTICLE_RESOURCES",RESOURCE_ROWS},{"PARTICLE_RESOURCE_BYTES",size_of(Gpu_Resource)},
        {"PARTICLE_DATA_ENTRIES",DATA_ENTRIES},{"PARTICLE_DATA_GAME_ENTRIES",DATA_GAME_ENTRIES},{"PARTICLE_SEGMENT_BYTES",size_of(Gpu_Segment)},
        {"PARTICLE_STAGES",erender.PROGRAM_STAGES},{"PARTICLE_STAGE_BYTES",size_of(Gpu_Stage)},{"PARTICLE_BIRTH_BYTES",size_of(Gpu_Birth)},
        {"PARTICLE_SORT_MAX",SORT_MAX},{"PROGRAM_PARAMETER_BYTES",erender.PROGRAM_PARAMETER_BYTES},
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
    kinds(t,defines,effect.Particle_Event,"PARTICLE_EVENT_",false)
    kinds(t,defines,Resource_Kind,"PARTICLE_RESOURCE_",true)
    kinds(t,defines,Stage_Kind,"PARTICLE_STAGE_",true)
}

// The CPU reads curves and gradients as particles.slang does, at their ends
// and between keys closer than it divides by.
@(test)
curves_read_on_the_cpu_as_the_shader_reads_them :: proc(t:^testing.T) {
    c:=effect.Particle_Curve{values={2,4,8,6,6,6,6,6},times={0.25,0.5,0.500002,1,1,1,1,1}}
    testing.expect_value(t,curve_at(&c,-1),2)
    testing.expect_value(t,curve_at(&c,0.25),2)
    testing.expect_value(t,curve_at(&c,0.375),3)
    testing.expect_value(t,curve_at(&c,0.5),4)
    testing.expect_value(t,curve_at(&c,2),6)
    // Two microseconds apart, the shader ramps over ten: a tenth of the way.
    near:=curve_at(&c,0.500001)
    testing.expectf(t,abs(near-4.4)<0.05,"between keys closer than 1e-5: %v",near)
    g:effect.Particle_Gradient
    for &key in g.colors {key={0,0,1,0}}
    g.colors[0]={1,0,0,1}
    g.times={0.5,1,1,1,1,1,1,1}
    testing.expect_value(t,gradient_at(&g,0),[4]f32{1,0,0,1})
    testing.expect_value(t,gradient_at(&g,0.75),[4]f32{0.5,0,0.5,0.5})
    testing.expect_value(t,gradient_at(&g,3),[4]f32{0,0,1,0})
}

@(test)
a_single_cycle_ends_when_its_last_particles_die :: proc(t:^testing.T) {
    e:=emission({duration=1,rate=10,lifetime={0.25,0.5}})
    clock:Emitter_Clock
    testing.expect_value(t,steps(&e,false,&clock,8),u64(10))
    testing.expect(t,!clock.done)
    testing.expect_value(t,steps(&e,false,&clock,3),u64(0))
    testing.expect(t,!clock.done)
    // The last one, born at the end of the cycle, lives half a second.
    steps(&e,false,&clock,2)
    testing.expect(t,clock.done)
}

@(test)
a_prewarmed_emitter_starts_full :: proc(t:^testing.T) {
    info:=effect.Particle_Info{prewarm=true,duration=1,rate=20,lifetime={2,2},rate_over_cycle=effect.PARTICLE_CURVE_ONE}
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
    testing.expect_value(t,override_set(&override,"rate",f32(55)),Error.None)
    testing.expect_value(t,override_set(&override,"colors.1",[4]f32{1,0,0,1}),Error.None)
    testing.expect_value(t,override_set(&override,"bursts.2.count",u32(7)),Error.None)
    testing.expect_value(t,override_set(&override,"size_over_life.values.3",f32(2)),Error.None)
    info:=particle_resolve(nil,{},&override)
    testing.expect_value(t,info.rate,f32(55))
    testing.expect_value(t,info.colors[1],[4]f32{1,0,0,1})
    testing.expect_value(t,info.colors[0],effect.PARTICLE_DEFAULTS.colors[0])
    testing.expect_value(t,info.bursts[2].count,u32(7))
    testing.expect_value(t,info.size_over_life.values[3],f32(2))
    testing.expect_value(t,info.lifetime,effect.PARTICLE_DEFAULTS.lifetime)
    rate,error:=override_get(override,"rate",f32)
    testing.expect(t,error==.None && rate==55)
    testing.expect_value(t,override_remove(&override,"rate"),Error.None)
    _,error=override_get(override,"rate",f32)
    testing.expect_value(t,error,Error.Missing_Override)
    // A hash of a path the effect does not have is left out.
    override.names[override.count]=base.name_hash("not_a_field")
    override.count+=1
    testing.expect_value(t,particle_resolve(nil,{},&override).rate,effect.PARTICLE_DEFAULTS.rate)
    checked:effect.Particle_Info
    testing.expect_value(t,particle_resolve_checked(nil,{},&override,&checked),Error.Unknown_Field)
}

@(test)
invalid_instance_values_say_what_to_correct :: proc(t:^testing.T) {
    override:Particle_Override
    testing.expect_value(t,override_set(&override,"rates",f32(1)),Error.Unknown_Field)
    testing.expect_value(t,override_set(&override,"rate",u32(1)),Error.Type_Mismatch)
    testing.expect_value(t,override_set(&override,"rate",f32(-1)),Error.Invalid_Value)
    testing.expect_value(t,override_set(&override,"size_over_life.times.1",f32(2)),Error.Invalid_Value)
    testing.expect_value(t,override_set(&override,"material",base.Asset_Id{1,2}),Error.Effect_Field)
    testing.expect_value(t,override_set(&override,"render",effect.Particle_Render.Mesh),Error.None)
    for path in ([?]string{"drag","shell","soft","stretch","bounce","friction","noise","gravity","intensity","inherit_velocity","duration","rate","noise_speed","collision_life","noise_frequency"}) {
        testing.expect_value(t,override_set(&override,path,f32(0.5)),Error.None)
    }
    testing.expect_value(t,override_set(&override,"attractor_strength",f32(1)),Error.Override_Capacity)
    testing.expect(t,len(error_message(.Override_Capacity))>0)
}

@(test)
program_parameters_of_an_instance_keep_their_kind :: proc(t:^testing.T) {
    parameters:Particle_Parameters
    testing.expect_value(t,parameter_set(&parameters,"speed",f32(3)),Error.None)
    testing.expect_value(t,parameter_set(&parameters,"tint",[3]f32{1,0.5,0}),Error.None)
    testing.expect_value(t,parameter_set(&parameters,"count",u32(4)),Error.None)
    testing.expect_value(t,parameter_set(&parameters,"pattern",base.Asset_Id{7,8}),Error.None)
    testing.expect_value(t,parameter_set(&parameters,"speed",f32(5)),Error.None)
    testing.expect_value(t,parameters.count,u32(4))
    speed,error:=parameter_get(parameters,"speed")
    testing.expect(t,error==.None && speed.kind==.Float && speed.value[0]==5 && speed.components==1)
    tint,_:=parameter_get(parameters,"tint")
    testing.expect(t,tint.components==3 && tint.value[1]==0.5)
    pattern,_:=parameter_get(parameters,"pattern")
    testing.expect(t,pattern.kind==.Texture && pattern.texture==base.Asset_Id{7,8})
    parameter_remove(&parameters,"tint")
    _,error=parameter_get(parameters,"tint")
    testing.expect_value(t,error,Error.Missing_Override)
    testing.expect_value(t,parameter_set(&parameters,"",f32(1)),Error.Invalid_Parameter)
    for name in ([?]string{"a","b","c","d","e"}) {testing.expect_value(t,parameter_set(&parameters,name,f32(1)),Error.None)}
    testing.expect_value(t,parameter_set(&parameters,"overflow",f32(1)),Error.Parameter_Capacity)
}

@(test)
requests_control_an_emitter_from_the_next_step :: proc(t:^testing.T) {
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{loop=true})
    fixture_tick(&f,TICK)
    clock:=clock_find(&f.clocks,e)
    testing.expect(t,clock!=nil && clock.control==.Authored)
    start(&f.requests,e)
    fixture_tick(&f,TICK)
    clock=clock_find(&f.clocks,e)
    testing.expect_value(t,clock.control,Particle_Control.Playing)
    status_now,_:=status(&f.clocks,core.at(core.read(&f.emitters),0),e)
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
    testing.expect_value(t,clock_find(&f.clocks,e).control,Particle_Control.Stopped)
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
a_sorted_effect_past_its_room_is_a_problem :: proc(t:^testing.T) {
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    cases:=[?]struct{render:effect.Particle_Render,sort:bool,max_particles:u32,problem:bool}{
        {.Ribbon,false,SORT_MAX+1,true},
        {.Billboard,true,SORT_MAX+1,true},
        {.Billboard,true,SORT_MAX,false},
        {.Billboard,false,SORT_MAX+1,false},
    }
    for c in cases {
        e:=fixture_emitter(&f,PARTICLE_EMITTER_DEFAULT)
        override:Particle_Override
        testing.expect_value(t,override_set(&override,"render",c.render),Error.None)
        testing.expect_value(t,override_set(&override,"sort",c.sort),Error.None)
        testing.expect_value(t,override_set(&override,"max_particles",c.max_particles),Error.None)
        core.add(&f.overrides,e,override)
        fixture_settle(&f)
        fixture_sync(&f,{0,1},TICK)
        testing.expectf(t,(core.problem_find(&f.problems,e,"vfx.capacity")!=nil)==c.problem,"%v",c)
    }
}

@(test)
requests_change_the_values_of_an_instance :: proc(t:^testing.T) {
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,PARTICLE_EMITTER_DEFAULT)
    testing.expect_value(t,request_override(&f.requests,e,"rate",f32(80)),Error.None)
    testing.expect_value(t,request_override(&f.requests,e,"rate",f32(-1)),Error.Invalid_Value)
    testing.expect_value(t,request_parameter(&f.requests,e,"speed",f32(4)),Error.None)
    fixture_tick(&f,TICK)
    override,has:=core.get(core.read(&f.overrides),e)
    testing.expect(t,has && override.count==1)
    rate,_:=override_get(override,"rate",f32)
    testing.expect_value(t,rate,f32(80))
    given,has_given:=core.get(core.read(&f.parameters),e)
    testing.expect(t,has_given && given.count==1)
    // The clock follows the value of the instance from the next step.
    fixture_tick(&f,TICK)
    testing.expect_value(t,clock_find(&f.clocks,e).emission.rate,f32(80))
    request_override_clear(&f.requests,e)
    request_parameter_clear(&f.requests,e)
    fixture_tick(&f,TICK)
    override,_=core.get(core.read(&f.overrides),e)
    given,_=core.get(core.read(&f.parameters),e)
    testing.expect(t,override.count==0 && given.count==0)
}

// The clocks of the editor's preview go with the frames and do not reach a
// Play: the copy of the world starts its clocks over.
@(test)
a_play_starts_the_clocks_of_the_preview_over :: proc(t:^testing.T) {
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
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
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{active=true,destroy_when_done=true})
    fixture_tick(&f,TICK)
    clock:=clock_find(&f.clocks,e)
    clock.resolved=emission_key({},nil,0)
    clock.emission={duration=0.1,rate=30,longest=0.1,tail=0.1,rate_over_cycle=effect.PARTICLE_CURVE_ONE}
    f.app.assets=nil
    for _ in 0..<20 {fixture_tick(&f,TICK)}
    testing.expect(t,!core.alive(&f.entities,e))
}

// The births a game gives a channel are numbered in the world: a rollback
// that pushes them again does not start them twice, and a channel no emitter
// listens to keeps none.
@(test)
channel_births_start_once_through_a_rollback :: proc(t:^testing.T) {
    f:Emitters_Fixture;fixture_init(&f);defer fixture_destroy(&f)
    e:=fixture_emitter(&f,Particle_Emitter{})
    IMPACTS,NOBODY :: Particle_Channel_Name(CHANNEL_GAME),Particle_Channel_Name(CHANNEL_GAME+1)
    listener:=Particle_Channel{name=IMPACTS}
    core.add(&f.listeners,e,listener)
    core.table_settle(&f.listeners,&f.entities)
    f.app.assets=nil
    id:=core.World_Id{0,1}
    tick :: proc(f:^Emitters_Fixture,at:int) {
        if at%2==0 {channel_emit(&f.channels,IMPACTS,Channel_Birth{position={f32(at),0,0},count=3})}
        channel_emit(&f.channels,NOBODY,Channel_Birth{count=1})
        fixture_tick(f,TICK)
    }
    for at in 0..<4 {tick(&f,at)}
    saved:Particle_Clocks
    defer core.value_free(&saved,type_info_of(Particle_Clocks))
    testing.expect(t,core.value_copy(&saved,&f.clocks,type_info_of(Particle_Clocks)))
    for at in 4..<8 {tick(&f,at)}
    testing.expect_value(t,len(f.clocks.channels),1)
    fixture_sync(&f,id,TICK)
    testing.expect_value(t,len(f.sync.births),4)
    testing.expect(t,f.sync.births[3].position=={6,0,0} && f.sync.births[3].count==3 && f.sync.births[3].number==3)
    // The rollback: four ticks in, and the same ticks again.
    testing.expect(t,core.value_copy(&f.clocks,&saved,type_info_of(Particle_Clocks)))
    for at in 4..<8 {tick(&f,at)}
    fixture_sync(&f,id,TICK)
    testing.expect_value(t,len(f.sync.births),0)
    tick(&f,8)
    fixture_sync(&f,id,TICK)
    testing.expect_value(t,len(f.sync.births),1)
    testing.expect_value(t,f.sync.births[0].number,u32(4))
}

// The places of the reports come back to the world from the origin of the
// frame they were written in, but those of an effect view, which are of the
// view; what does not fit is lost and counted.
@(test)
reports_come_back_to_the_world_from_the_origin_of_their_frame :: proc(t:^testing.T) {
    pool:Pool
    if !testing.expect(t,pool_make(&pool,64)) {return}
    defer pool_free(&pool)
    world_at:=pool_slot_take(&pool,1,8)
    view_at:=pool_slot_take(&pool,2,8)
    pool.slots[world_at].desc.owner=core.Entity(7)
    pool.slots[view_at].desc.owner,pool.slots[view_at].desc.view=core.Entity(9),1
    Bytes :: struct {head:Reports_Head,rows:[3]Gpu_Report}
    bytes:=Bytes{head={count=REPORT_CAPACITY+5,origin={-20480,1024,15360}}}
    bytes.rows[0]={position={1.5,-2,0.25},slot=u32(world_at),kind=u32(effect.Particle_Event.Death)}
    bytes.rows[1]={position={0.5,0.5,0},slot=u32(view_at),kind=u32(effect.Particle_Event.Collision)}
    bytes.rows[2]={position={3,3,3},slot=u32(world_at)}
    reports:Particle_Reports
    defer particle_reports_free(&reports)
    reports_take(&reports,&pool,([^]u8)(&bytes)[:size_of(bytes)])
    if !testing.expect_value(t,len(reports.reports),3) {return}
    testing.expect_value(t,reports.reports[0].position,[3]f32{-20478.5,1022,15360.25})
    testing.expect_value(t,reports.reports[0].entity,core.Entity(7))
    testing.expect_value(t,reports.reports[1].position,[3]f32{0.5,0.5,0})
    testing.expect_value(t,reports.reports[1].entity,core.Entity(9))
    testing.expect_value(t,reports.lost,u32(REPORT_CAPACITY+2))
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

// What an effect says of how its Mesh particles face and turn reaches the row
// of their emitter, its zeros as what they stand for: Random, X, no turn and
// a scale of one, which is how they turned before they could say more.
@(test)
mesh_facing_reaches_the_row_of_the_emitter :: proc(t:^testing.T) {
    // Without assets, the effect draws sprites: the mesh fields reach the row all the same.
    info:=effect.PARTICLE_DEFAULTS
    app:host.App
    s:Pool_Slot
    s.desc,_=emitter_desc(&info,app.assets,app.renderer,1)
    g:Gpu_Emitter
    emitter_row(&g,&s,8)
    testing.expect_value(t,g.mesh.z,u32(effect.Particle_Facing.Random))
    testing.expect_value(t,g.mesh_rotation,[4]f32{0,0,0,1})
    testing.expect_value(t,g.mesh_axis,[4]f32{1,0,0,0})
    testing.expect_value(t,g.mesh_scale,[4]f32{1,1,1,1})
    info.facing,info.spin_axis,info.mesh_rotation,info.mesh_scale=.Camera_Position,{0,2,0},{0,0,2,0},{0.5,3,1}
    s.desc,_=emitter_desc(&info,app.assets,app.renderer,1)
    emitter_row(&g,&s,8)
    testing.expect_value(t,g.mesh.z,u32(effect.Particle_Facing.Camera_Position))
    testing.expect_value(t,g.mesh_rotation,[4]f32{0,0,1,0})
    testing.expect_value(t,g.mesh_axis,[4]f32{0,1,0,0})
    testing.expect_value(t,g.mesh_scale,[4]f32{0.5,3,1,3})
}

// The room for the lights of the particles has two parts: an emitter takes
// its share from the part of its kind, in the order of the slots and as many
// as the world asked for, and one of the other kind has an empty share where
// those before it end. particle_lights.comp finds the light i of a part at
// the last slot whose share of the part starts at i or before.
@(test)
emitters_take_their_lights_from_the_part_of_the_room_of_their_kind :: proc(t:^testing.T) {
    info:=effect.PARTICLE_DEFAULTS
    info.lights=3
    app:host.App
    desc,_:=emitter_desc(&info,app.assets,app.renderer,1)
    testing.expect(t,desc.lights==3 && !desc.shadows,"the lights of an effect cast no shadows unless it asks")
    info.light_shadows=true
    desc,_=emitter_desc(&info,app.assets,app.renderer,1)
    testing.expect(t,desc.shadows)
    info.light_range=0
    desc,_=emitter_desc(&info,app.assets,app.renderer,1)
    testing.expect_value(t,desc.lights,u32(0))

    Want :: struct {lights:u32,shadows,live:bool}
    wants:=[?]Want{{3,true,true},{2,false,true},{7,true,false},{4,true,true},{5,false,true}}
    slots:[len(wants)]Pool_Slot
    for want,at in wants {slots[at].live,slots[at].desc.lights,slots[at].desc.shadows=want.live,want.lights,want.shadows}
    asked:=lights_asked(slots[:])
    testing.expect_value(t,asked,[2]u32{7,7})
    taken:[2]u32
    shares:[len(wants)][4]u32
    for &s,at in slots {shares[at]=light_share(s.desc.lights if s.live else 0,s.desc.shadows,&taken,asked)}
    testing.expect_value(t,shares,[len(wants)][4]u32{{0,3,0,0},{3,0,0,2},{3,0,2,0},{3,4,2,0},{7,0,2,5}})
    for part in 0..<2 {
        for i in 0..<asked[part] {
            found:=-1
            for share,at in shares {if share[2*part]<=i {found=at}}
            share:=shares[max(found,0)]
            testing.expectf(t,found>=0 && i>=share[2*part] && i<share[2*part]+share[2*part+1] && slots[found].desc.shadows==(part==0),"light %d of part %d is of slot %d",i,part,found)
        }
    }
    // What is left of what the world asked for, and no more.
    taken={}
    testing.expect_value(t,light_share(5,true,&taken,{4,0}),[4]u32{0,4,0,0})
    testing.expect_value(t,light_share(2,true,&taken,{4,0}),[4]u32{4,0,0,0})
    many:[2]Pool_Slot
    many[0].live,many[0].desc.lights,many[0].desc.shadows=true,erender.LIGHTS_ASKED_MAX+5,true
    many[1].live,many[1].desc.lights=true,erender.LIGHTS_ASKED_MAX+5
    testing.expect_value(t,lights_asked(many[:]),[2]u32{erender.LIGHTS_ASKED_MAX,erender.LIGHTS_ASKED_MAX})
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
	p.free = make([][2]u32, 9)
	defer {delete(p.slots); delete(p.order); delete(p.free)}
	p.free[0], p.free_count = {0, 1000}, 1
	a, b, c := pool_slot_take(&p, 30, 100), pool_slot_take(&p, 10, 200), pool_slot_take(&p, 20, 300)
	testing.expect_value(t, p.slots[a].offset, u32(0))
	testing.expect_value(t, p.slots[b].offset, u32(100))
	testing.expect_value(t, p.slots[c].offset, u32(300))
	testing.expect_value(t, pool_slot_find(&p, 10), b)
	testing.expect_value(t, pool_slot_find(&p, 99), -1)
	testing.expect_value(t, pool_slot_take(&p, 40, 500), -1)
	pool_slot_release(&p, b)
	testing.expect_value(t, p.free_count, 2)
	pool_slot_release(&p, a)
	testing.expect_value(t, p.free_count, 2)
	testing.expect_value(t, p.free[0], [2]u32{0, 300})
	testing.expect_value(t, p.pool_end, u32(600))
	pool_slot_release(&p, c)
	testing.expect_value(t, p.free_count, 1)
	testing.expect_value(t, p.free[0], [2]u32{0, 1000})
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
