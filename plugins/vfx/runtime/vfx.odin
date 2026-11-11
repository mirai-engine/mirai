package vfx

import "mirai:core"
import volume "mirai:engine/volume"
import gui "mirai:engine/gui"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// Particles, the plugin vfx. A Particle_Emitter at an entity shows a particle
// effect, an asset (.particle) as a material is: the entities that show it name it, and
// a Particle_Override (values of the effect) and Particle_Parameters (of its
// Vfx program) give one of them values of its own. Effects of several
// emitters are prefabs, spawned with scene.spawn.
//
// The clock of each emitter is part of the world (Particle_Clocks): where it
// is in the cycle of its effect and the births it started, numbered, in
// groups (how many, at once or one after another, when). particles_tick
// advances the clocks in fixed: with the ticks while the world plays, and
// with the frames, as a preview, in the editor. A game controls an emitter
// with Particle_Requests (start, stop, restart, pause, burst, values). A
// copy, a Play and a rollback take the clocks, and particles_sync starts on
// the GPU only the births it did not start yet: a rollback that runs a burst
// again does not draw it twice. The particles alive are not part of the
// world: they are in buffers the renderer keeps for the world (gpu.odin),
// which go with it.

GRAVITY :: [3]f32{0,-9.81,0} // of the particles of an effect view, which are of no place (fields.odin)

// What every effect does at its entity, whatever the effect.
@(component)
Particle_Emitter :: struct {
    particle:base.Asset_Id, // a .particle; none: effect.PARTICLE_DEFAULTS
    active:bool,            // it emits from the start; clearing it lets the particles alive finish
    loop:bool,              // the cycle of the effect starts again when it ends
    preview:bool,           // in the editor, while the world does not play, it emits and starts over when it is done
    destroy_when_done:bool, // while playing, the entity and what hangs from it go once every emitter there is done
}

PARTICLE_EMITTER_DEFAULT :: Particle_Emitter{active=true,loop=true,preview=true}

// The clocks of the emitters, by entity. Those of a world that plays follow
// its ticks; those of the editor's world, the preview. A Play starts them over.
@(storage)
Particle_Clocks :: struct {
    clocks:core.Entity_Map(Emitter_Clock),
    channels:[dynamic]Channel_Ring,      // the births of the channels the emitters listen to (channels.odin)
    seen_emitters,seen_worlds:core.Seen, // what the clocks of the emitters that went are pruned from
    playing:bool,                        // of a world that plays
}

// Particles alive at once in the emitters of a world.
@(storage,setting)
Particle_Settings :: struct {
    capacity:u32 `mirai:"min=1024,max=16777216,advanced"`, // the device may take less: then the renderer keeps the pool it has
}

PARTICLE_SETTINGS_DEFAULT :: Particle_Settings{capacity=CAPACITY}

// What the renderer was told of an emitter.
Emitter_Shown :: struct {
    resolved:u64,                // what it was resolved from: the asset, its revision, the values and parameters of the entity, the shaders
    info:effect.Particle_Info,    // the effect with the values of the entity over it
    sub:effect.Particle_Info,     // the effect its particles start in another emitter
    has_sub:bool,
    program,sub_program:Program,
    desc,sub_desc:Emitter_Desc,   // what the GPU is told of it and of its sub effect, but for what each frame gives
    needs:Program_Needs,          // the resources and stages its program declares
    sources:[RESOURCES]effect.Particle_Resource, // and what its effect gives them
    source_count:int,
    resource_previous:[RESOURCE_ROWS]mm.Mat4, // where each of its resources was drawn last
    resource_placed:[RESOURCE_ROWS]bool,
    problem:[192]u8,             // why its program does not run, as text; empty when it does or there is none
    started:u64,                 // births of its clock started on the GPU
    generation:u32,
    transform:mm.Mat4,           // where it was drawn last
    placed:bool,
}

// What the GPU has of the emitters of a world: one for each world.
@(storage,host,by_world,free="particle_sync_free")
Particle_Sync :: struct {
    shown:core.Entity_Map(Emitter_Shown),
    seen_emitters,seen_worlds:core.Seen, // what the emitters that went are pruned from
    time:f64,          // seconds of the world at its last frame: of its ticks while it plays
    timed:bool,
    descs:[dynamic]Emitter_Desc,
    fields:Gpu_Fields, // the gravity and the wind of the world, as the frame found them
    owners:[dynamic]core.Entity, // the entity of each of descs
    births:[dynamic]Gpu_Birth,   // of the channels, those the GPU starts in this frame
    regions:[dynamic]Channel_Region,
    started:[dynamic]Channel_Started,
    world:u64,         // as the renderer names it (erender.world_key)
    world_id:core.World_Id,
    pool:Pool,
    surfaces:Surfaces,
    grids:Grids,
    data:Data_Channels,
    stage_rows:[dynamic]Gpu_Stage, // of the emitters whose programs have stages, PROGRAM_STAGES each
    rigs:[dynamic]Bone_Rig,        // of the meshes whose bones its emitters read
    rigs_stamp:u64,                // of the assets they were read from
    resources:[dynamic]Resource_Desc, // of the emitters that read some in this frame, RESOURCE_ROWS each
    segments:[dynamic]Gpu_Segment, // the bones they read in this frame
    palette:[dynamic][3][4]f32,    // the palette of a skin, read into
    pipelines:Particle_Pipelines,
    world_textures:[WORLD_TEXTURES]u64, // the names of the grids whose textures the renderer keeps
    world_texture_count:int,
    world_frame:World_Textures_Frame, // the textures of the world as the last steps left them
    world_shown:World_Textures_Frame, // and as the steps before, which the views of this frame show
    loads:[dynamic]Grid_Load,      // the states of the frame the grids start from (gridfile)
    load_bytes:[dynamic]u8,        // their cells, as the grids keep them
}

particle_sync_free :: proc(sync:^Particle_Sync) {
    delete(sync.shown.values);delete(sync.shown.entities);delete(sync.shown.rows)
    delete(sync.descs)
    delete(sync.owners)
    delete(sync.births);delete(sync.regions);delete(sync.started)
    pool_free(&sync.pool)
    surfaces_free(&sync.surfaces)
    bone_rigs_free(&sync.rigs)
    grids_free(&sync.grids)
    data_free(&sync.data)
    delete(sync.resources);delete(sync.stage_rows);delete(sync.segments);delete(sync.palette)
    delete(sync.loads);delete(sync.load_bytes)
    sync^={}
}

// The clocks of the emitters one step further: the requests of the step,
// what each starts and the entities of the effects that are done.
@(step="fixed",loops="game editor",stage="end")
particles_tick :: proc(
    emitters:core.Read(Particle_Emitter),overrides:^core.Table(Particle_Override),parameters:^core.Table(Particle_Parameters),
    worlds:core.Read(core.World_Transform),hierarchy:core.Ref(core.Hierarchy),entities:core.Commands,
    clocks:^Particle_Clocks,requests:^Particle_Requests,births:^core.Births,listeners:core.Read(Particle_Channel),
    time:core.Time,frame:core.Frame_Time,assets:^host.Assets,problems:^core.Problems,
) {
    if clocks.playing!=time.playing {
        core.entity_map_clear(&clocks.clocks)
        clear(&clocks.channels)
        clocks.playing=time.playing
    }
    channels_step(clocks,core.take(&births.queue),listeners,time)
    // The clocks of the emitters that went, or whose entity is no longer placed.
    core.entity_map_prune(&clocks.clocks,emitters,core.changes(emitters,&clocks.seen_emitters))
    core.entity_map_prune(&clocks.clocks,worlds,core.changes(worlds,&clocks.seen_worlds))
    dt:=time.playing?time.dt:max(frame.dt,0)
    requests_apply(requests,emitters,overrides,parameters,clocks,problems)
    a:=assets
    done:[dynamic]core.Entity
    done.allocator=context.temp_allocator
    placed:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&placed) {
        clock:=clock_of(clocks,e)
        if clock==nil {continue}
        if key:=emission_key(emitter.particle,a,row_stamp(core.read(overrides),e));clock.resolved!=key {
            override,_:=core.get(overrides,e)
            info:=particle_resolve(a,emitter.particle,&override)
            clock.emission=emission_of(a,&info)
            clock.resolved=key
        }
        emitting:=clock.control==.Playing || clock.control==.Authored && (time.playing?emitter.active:emitter.preview)
        before:=clock.time
        emission_step(clock,&clock.emission,emitting,emitter.loop,world.transform.position,dt)
        if !time.playing && emitting && !clock.paused {
            if listener,listens:=core.get(listeners,e);listens {channel_preview(clocks,listener,world.transform.position,before,clock.time,f64(clock.emission.duration))}
        }
        if !time.playing && clock.done && emitter.preview && clock.control==.Authored {clock_restart(clock)}
        if time.playing && clock.done && emitter.destroy_when_done {append(&done,e)}
    }
    for e in done {
        if subtree_done(emitters,clocks,hierarchy,e) {core.destroy_tree(entities.entities,hierarchy,e)}
    }
}

// The emitters of the world to the GPU: the births of their clocks it did
// not start yet, and where they are.
@(step="render",loops="game editor",after="render_sync")
particles_sync :: proc(
    emitters:core.Read(Particle_Emitter),overrides:core.Read(Particle_Override),parameters:core.Read(Particle_Parameters),
    worlds:core.Read(core.World_Transform),hidden:core.Read(erender.Hidden),parents:core.Read(core.Parent),
    bindings:core.Read(Particle_Bindings),meshes:core.Read(erender.Mesh_Renderer),drawn:core.Ref(erender.Render_Sync),listeners:core.Read(Particle_Channel),grids:core.Read(Particle_Grid),volumes:core.Read(Particle_Volume),textures:core.Read(Particle_World_Texture),
    clocks:core.Ref(Particle_Clocks),settings:core.Ref(Particle_Settings),sync:^Particle_Sync,reports:^Particle_Reports,watch:^Particle_Data_Watch,read:^Particle_Data_Read,ui_effects:^UI_Particles,ui_requests:core.Ref(gui.UI_Effects),id:core.World_Id,time:core.Time,frame:core.Frame_Time,
    view:core.View,problems:^core.Problems,app:^host.App,
    winds:core.Read(volume.Wind),places:core.Read(volume.Volume),gravities:core.Read(volume.Gravity),
) {
    if sync==nil {return}
    if reports!=nil {reports_read(reports,sync,app.renderer,id)}
    if read!=nil {data_read(read,&sync.data,app.renderer,id,problems)}
    r,a:=app.renderer,app.assets
    sync.world,sync.world_id=erender.world_key(id),id
    clear(&sync.descs)
    clear(&sync.owners)
    clear(&sync.resources)
    clear(&sync.stage_rows)
    clear(&sync.segments)
    grids_sync(&sync.grids,grids,volumes,textures,worlds,view,problems)
    sync.fields=fields_of(gravities,winds,places,worlds)
    world_textures_keep(sync,app.renderer,id)
    // Rigs are read again once the assets change.
    if a!=nil {
        if stamp:=a.revision+a.registry.revision+1;stamp!=sync.rigs_stamp {
            for &rig in sync.rigs {delete(rig.joints)}
            clear(&sync.rigs)
            sync.rigs_stamp=stamp
        }
    }
    // The seconds the clocks went since the last frame: the ticks of a world that plays, the frame in the editor.
    now:=time.playing?time.seconds:sync.time+f64(max(frame.dt,0))
    dt:=sync.timed?f32(clamp(now-sync.time,0,1)):0
    sync.time,sync.timed=now,true
    channels_sync(sync,clocks.ptr,now,problems)
    core.entity_map_prune(&sync.shown,emitters,core.changes(emitters,&sync.seen_emitters))
    core.entity_map_prune(&sync.shown,worlds,core.changes(worlds,&sync.seen_worlds))
    shaders:=app.shaders.reloads
    // What an emitter is resolved from besides its own: the triangles of meshes move when the scene is made again.
    made:=erender.vertices_made(app.renderer)
    used:[DATA_CHANNELS]bool
    placed:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&placed) {
        shown:=shown_of(sync,e)
        if shown==nil {continue}
        key:=base.hash_combine(base.hash_combine(emitter.particle[0],emitter.particle[1]),a!=nil?a.revision:0)
        key=base.hash_combine(base.hash_combine(base.hash_combine(base.hash_combine(key,row_stamp(overrides,e)),row_stamp(parameters,e)),shaders),made)|1
        if shown.resolved!=key {
            shown.resolved=shown_resolve(shown,app,emitter.particle,overrides,parameters,e)?key:0
            shown.desc.revision,shown.sub_desc.revision=shown.resolved,shown.resolved
        }
        for info in ([2]^effect.Particle_Info{&shown.info,shown.has_sub?&shown.sub:nil}) {
            if info==nil || !(info.sort || info.render==.Ribbon) {continue}
            if needed:=emitter_capacity(info);needed>SORT_MAX {
                core.report(problems,e,"vfx.capacity","a sorted or ribbon effect keeps at most %d particles alive and this one needs %d: give it max_particles %d or less, or a lower rate or lifetime",SORT_MAX,needed,SORT_MAX)
            }
        }
        pose:=erender.drawn_transform(world,frame)
        if !shown.placed {pose=world.transform}
        transform:=mm.transform_matrix(pose)
        spawns:[SPAWNS]Particle_Spawn
        paused:bool
        age:f32
        born:u64
        if clock:=clock_find(clocks.ptr,e);clock!=nil {
            if clock.generation!=shown.generation {
                shown.generation=clock.generation
                shown.started=max(shown.started,clock.first)
            }
            // A rollback that runs again less than what was started: what comes next starts.
            if clock.emitted<shown.started {shown.started=clock.emitted}
            born=shown.started
            spawns=births_since(clock,&shown.started)
            paused=clock.paused
            age=f32(clock.time)
        }
        previous:=shown.placed?shown.transform:transform
        shown.transform,shown.placed=transform,true
        if r==nil || a==nil || erender.is_hidden(hidden,parents,e) {continue}
        desc:=shown.desc
        desc.transform,desc.previous,desc.spawns=transform,previous,spawns
        desc.age,desc.born=age,u32(born)
        if shown.info.shape==.Surface || shown.info.shape==.Bones || shown.needs.resources[0].kind!=.None || shown.needs.stages[0].kind!=.None {
            bound,_:=core.get(bindings,e)
            rows:=emitter_resources(sync,shown,&shown.info,shown.sources[:shown.source_count],&bound,e,transform,host.extras_instances(&app.extras),drawn.ptr,meshes,worlds,id,app.assets,app.renderer)
            desc.resources=u32(len(sync.resources))+1
            append(&sync.resources,..rows[:])
        }
        desc.stages=emitter_stages(sync,&shown.needs,desc.resources,desc.id,e,problems)
        for need in shown.needs.resources {
            if need.kind==.Data {data_need(&sync.data,need.name,need.words,&used,problems,e)}
        }
        if listener,listens:=core.get(listeners,e);listens && !listener.silent {desc.births.x,desc.births.y=channel_region(sync,channel_key(listener))}
        desc.paused,desc.generation=paused,shown.generation
        if shown.has_sub {
            sub:=shown.sub_desc
            sub.transform,sub.previous=transform,previous
            sub.paused,sub.generation=paused,shown.generation
            append(&sync.descs,sub)
            append(&sync.owners,e)
        }
        append(&sync.descs,desc)
        append(&sync.owners,e)
    }
    grids_release(&sync.grids,&sync.pool)
    watched:[]u64
    if watch!=nil {watched=core.take(&watch.queue)}
    data_place(&sync.data,used,watched)
    asked:[]gui.UI_Effect
    if ui_requests.ptr!=nil {asked=ui_requests.items[:]}
    if ui_effects!=nil && (ui_effects.count>0 || len(asked)>0) {
        // The world stands still while its UI plays: its emitters keep their
        // particles as they are and the pool goes with the frames.
        if dt<=0 && len(asked)>0 {
            for &desc in sync.descs {desc.paused=true}
            dt=clamp(frame.dt,0,1)
        }
        ui_effects_sync(ui_effects,asked,app.assets,app.renderer,clamp(frame.dt,0,1),shaders,&sync.descs)
        for len(sync.owners)<len(sync.descs) {append(&sync.owners,core.NONE)}
    }
    if r==nil {return}
    if a!=nil {host.assets_commit(a)}
    capacity:=settings.capacity
    if dropped,ok:=pool_emitters(&sync.pool,sync.descs[:],dt,capacity,erender.max_storage_range(app));!ok {
        if len(sync.descs)>0 {core.report(problems,core.NONE,"vfx.capacity","the device takes no pool of %d particles: ask a smaller Particle_Settings.capacity",capacity)}
        return
    } else if dropped>0 {
        for desc,at in sync.descs {
            if pool_slot_find(&sync.pool,desc.id)<0 {core.report(problems,sync.owners[at],"vfx.capacity","this emitter found no room among the %d particles and %d emitters of the world: ask a larger Particle_Settings.capacity, or fewer max_particles of its effect",sync.pool.capacity,EMITTER_CAPACITY)}
        }
    }
    if sync.pool.refused==capacity && sync.pool.capacity!=capacity {
        core.report(problems,core.NONE,"vfx.capacity","the device takes no pool of %d particles: the world keeps %d; ask a smaller Particle_Settings.capacity",capacity,sync.pool.capacity)
    }
    particles_frame(sync,app)
}

// A world that goes takes its particles with it.
@(step="release")
particles_release :: proc(sync:^Particle_Sync,id:core.World_Id,renderer:^erender.Renderer) {
    if sync==nil {return}
    if renderer!=nil {
        pool_release(renderer,id,&sync.pool)
        erender.buffer_release(renderer,id,world_buffer(sync).name)
        for name in sync.world_textures[:sync.world_texture_count] {erender.table_texture_release(renderer,id,world_texture_key(name))}
        erender.readback_release(renderer,id,reports_readback().name)
        for entry in sync.data.entries {erender.readback_release(renderer,id,data_readback_desc(entry.name,entry.words).name)}
    }
    pool_free(&sync.pool)
    surfaces_free(&sync.surfaces)
    grids_free(&sync.grids)
    data_free(&sync.data)
}

// The births of a clock from started on, for the GPU: how old each is at
// the time of the clock. started goes to what the clock emitted. Births the
// clock no longer keeps are not started.
@(private)
births_since :: proc(clock:^Emitter_Clock,started:^u64) -> (spawns:[SPAWNS]Particle_Spawn) {
    count:=0
    for b in clock.births[:clock.birth_count] {
        end:=b.first+u64(b.count)
        if end<=started^ {continue}
        // A group started in part: from its next whole instant.
        per:=u64(max(b.per,1))
        skip:=started^>b.first?(started^-b.first+per-1)/per*per:0
        if skip>=u64(b.count) {continue}
        instant:=f64(skip/per)*f64(b.spacing)
        spawns[count]={
            count=u32(u64(b.count)-skip),per=b.per,birth=u32(b.first+skip),
            age=f32(max(clock.time-(b.time+instant),0)),spacing=b.spacing,
        }
        count+=1
    }
    started^=clock.emitted
    return
}

// The values, the sub effect and the programs an emitter shows, and what the
// GPU is told of them. False without assets, or while the renderer does not
// have the triangles of its mesh: it is resolved again.
@(private)
shown_resolve :: proc(shown:^Emitter_Shown,app:^host.App,particle:base.Asset_Id,overrides:core.Read(Particle_Override),parameters:core.Read(Particle_Parameters),e:core.Entity) -> bool {
    a:=app.assets
    override,_:=core.get(overrides,e)
    given,_:=core.get(parameters,e)
    shown.info=particle_resolve(a,particle,&override)
    shown.sub={}
    shown.has_sub=false
    problem:=particle_program(a,particle,&shown.info,&given,&shown.program,&shown.needs)
    channel_needs(a,&shown.program,&shown.needs)
    shown.source_count=0
    if a!=nil && particle!={} {
        if view,ok:=effect_view(a,particle);ok {
            shown.source_count=copy(shown.sources[:],view.resources)
        }
    }
    shown.sub_program={}
    if shown.info.trigger!=.None && shown.info.sub_particle!={} {
        shown.sub=particle_resolve(a,shown.info.sub_particle,nil)
        shown.has_sub=true
        sub_problem:=particle_program(a,shown.info.sub_particle,&shown.sub,nil,&shown.sub_program,nil)
        if problem=="" {problem=sub_problem}
    }
    base.text_set(shown.problem[:],problem)
    if a==nil {return false}
    desc,ready:=emitter_desc(&shown.info,app.assets,app.renderer,u64(e))
    shown.desc=desc
    shown.desc.program=shown.program
    shown.desc.report,shown.desc.owner=shown.info.report,e
    shown.sub_desc={}
    if shown.has_sub {
        sub_desc,sub_ready:=emitter_desc(&shown.sub,app.assets,app.renderer,sub_id(e))
        shown.sub_desc=sub_desc
        ready&&=sub_ready
        sub:=&shown.sub_desc
        sub.program=shown.sub_program
        sub.report,sub.owner=shown.sub.report,e
        sub.capacity+=min(shown.desc.capacity*shown.info.sub_count,1<<16)
        shown.desc.event,shown.desc.event_target,shown.desc.event_count=shown.info.trigger,sub.id,shown.info.sub_count
    }
    return ready
}

// The GPU names the emitter of the sub particle of an entity with this id.
@(private)
sub_id :: proc "contextless" (e:core.Entity) -> u64 {return base.hash_combine(u64(e),0x7375625f70617274)}

// What the GPU is told of an effect at an emitter, but for what each frame
// gives. ready: the renderer has the triangles of its mesh, or it draws none.
@(private)
emitter_desc :: proc(m:^effect.Particle_Info,assets:^host.Assets,renderer:^erender.Renderer,id:u64) -> (desc:Emitter_Desc,ready:bool) {
    a:=assets
    material:=erender.Material_Handle(m.material!={}?host.assets_material_row(a,m.material):0)
    mesh:[3]u32
    blended:=false
    ready=true
    if m.render==.Mesh {
        // A material that blends draws its meshes over the lit scene, as a sprite.
        if found:=host.assets_material(a,m.material);found!=nil {blended=found.info.alpha_mode==.Blend}
        entry:=m.mesh!={}?host.assets_mesh(a,m.mesh):host.assets_shape(a,.Cube)
        if entry!=nil {mesh.x,ready=erender.mesh_draw_range(renderer,entry.handle);mesh.y=u32(entry.handle)}
        ready||=renderer==nil
    }
    return {
        id=id,capacity=emitter_capacity(m),
        seed=u32(base.hash_combine(id,0x7061727469636c65)),
        local=m.local_space,lit=m.lit,relative=m.emission_mode==.Relative,sort=m.sort,
        lights=m.lights if m.light_intensity>0 && m.light_range>0 else 0,light={m.light_intensity,m.light_range,m.light_radius},shadows=m.light_shadows,
        shape=m.shape,shape_size=m.shape_size,shape_angle=m.shape_angle,shell=m.shell,
        lifetime=m.lifetime,speed=m.speed,size=m.size,rotation=m.rotation,spin=m.spin,velocity=m.velocity,
        color={m.colors[0],m.colors[1]},inherit=m.inherit_velocity,
        acceleration=m.acceleration,gravity=m.gravity,drag=m.drag,
        noise_strength=m.noise,noise_frequency=m.noise_frequency,noise_speed=m.noise_speed,
        attractor=m.attractor,attractor_strength=m.attractor_strength,
        collision=m.collision,bounce=m.bounce,friction=m.friction,collision_life=m.collision_life,
        render=m.render,blend=m.blend,material=material,mesh=mesh,blended=blended,
        facing=m.facing,spin_axis=m.spin_axis,mesh_rotation=m.mesh_rotation,mesh_scale=m.mesh_scale,
        stretch=m.stretch,soft=m.soft,intensity=m.intensity,flipbook=m.flipbook,flipbook_speed=m.flipbook_speed,
        size_curve=m.size_over_life,color_curve=m.color_over_life,
    },ready
}

Particle_State :: enum u8 {
    Idle,     // it does not emit and has nothing alive
    Playing,  // it emits
    Paused,
    Finishing,// it emits no more; particles are alive
    Done,
}

// Where an emitter of the world is: what particles_tick says of its clock.
Particle_Status :: struct {
    state:Particle_State,
    control:Particle_Control,
    time:f64,       // seconds of its generation
    generation:u32,
    emitted:u64,    // births since it began
}

// The status of the emitter at e; false when it has no clock yet.
status :: proc(clocks:^Particle_Clocks,emitter:Particle_Emitter,e:core.Entity) -> (s:Particle_Status,ok:bool) {
    clock:=clock_find(clocks,e)
    if clock==nil {return}
    s={control=clock.control,time=clock.time,generation=clock.generation,emitted=clock.emitted}
    emitting:=clock.control==.Playing || clock.control==.Authored && (clocks.playing?emitter.active:emitter.preview)
    over:=!emitter.loop && clock.time>=f64(clock.emission.duration) || clock.control==.Stopped
    switch {
    case clock.paused: s.state=.Paused
    case clock.done: s.state=.Done
    case emitting && !over: s.state=.Playing
    case clock.time-clock.last<f64(clock.emission.tail): s.state=.Finishing
    case: s.state=.Idle
    }
    return s,true
}

// Whether every emitter at e or under it is done.
@(private)
subtree_done :: proc(emitters:core.Read(Particle_Emitter),clocks:^Particle_Clocks,hierarchy:core.Ref(core.Hierarchy),root:core.Entity) -> bool {
    for e:=root;e!=core.NONE;e=core.subtree_next(hierarchy,root,e) {
        if !core.has(emitters,e) {continue}
        if clock:=clock_find(clocks,e);clock==nil || !clock.done {return false}
    }
    return true
}

// The clock of an emitter, if it has one.
@(private)
clock_find :: proc(clocks:^Particle_Clocks,e:core.Entity) -> ^Emitter_Clock {
    return clocks==nil?nil:core.entity_map_get(&clocks.clocks,e)
}

// The clock of an emitter; a new one for an entity that has none. nil
// without memory for it.
@(private)
clock_of :: proc(clocks:^Particle_Clocks,e:core.Entity) -> ^Emitter_Clock {
    if clock:=core.entity_map_get(&clocks.clocks,e);clock!=nil {return clock}
    clock,_:=core.entity_map_put(&clocks.clocks,e,Emitter_Clock{last=-max(f64)})
    return clock
}

// What the renderer was told of an emitter; new for an entity it was told
// nothing of. nil without memory for it.
@(private)
shown_of :: proc(sync:^Particle_Sync,e:core.Entity) -> ^Emitter_Shown {
    if shown:=core.entity_map_get(&sync.shown,e);shown!=nil {return shown}
    shown,_:=core.entity_map_put(&sync.shown,e,Emitter_Shown{})
    return shown
}

