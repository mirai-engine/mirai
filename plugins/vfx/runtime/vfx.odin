package vfx

import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import gui "mirai:engine/gui"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// Particles, the plugin vfx. A Particle_Emitter at an entity shows a particle
// effect, an asset (.particle) as a material is: the entities that show it name it, and
// a Particle_Override (values of the effect and of its Vfx program) gives one
// of them values of its own. Effects of several
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
    active:bool,            // it emits while the world plays (start and stop set it); clearing it lets the particles alive finish
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
    resolved:u64,                // what it was resolved from: the asset, its revision, the values of the entity, the shaders
    desc,sub_desc:Emitter_Desc,   // what the GPU is told of it and of its sub effect (id 0: none), but for what each frame gives
    needs:Program_Needs,          // the resources and stages its program declares
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
    emitters:^core.Table(Particle_Emitter),overrides:^core.Table(Particle_Override),
    worlds:^core.Table(core.World_Transform,.Read),hierarchy:core.Ref(core.Hierarchy),entities:core.Commands,
    clocks:^Particle_Clocks,requests:^Particle_Requests,births:^core.Births,listeners:^core.Table(Particle_Channel,.Read),
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
    requests_apply(requests,emitters,overrides,clocks,problems)
    a:=assets
    done:[dynamic]core.Entity
    done.allocator=context.temp_allocator
    placed:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&placed) {
        clock:=clock_of(clocks,e)
        if clock==nil {continue}
        if key:=emission_key(emitter.particle,a,row_stamp(overrides,e));clock.resolved!=key {
            override,_:=core.get(overrides,e)
            info:=particle_resolve(a,emitter.particle,&override)
            clock.emission=emission_of(a,&info)
            clock.resolved=key
        }
        emitting:=time.playing?emitter.active:emitter.preview
        before:=clock.time
        emission_step(clock,&clock.emission,emitting,emitter.loop,world.transform.position,dt)
        if !time.playing && emitting && !clock.paused {
            if listener,listens:=core.get(listeners,e);listens {channel_preview(clocks,listener,world.transform.position,before,clock.time,f64(clock.emission.duration))}
        }
        if !time.playing && clock.done && emitter.preview {clock_restart(clock)}
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
    emitters:^core.Table(Particle_Emitter,.Read),overrides:^core.Table(Particle_Override,.Read),
    worlds:^core.Table(core.World_Transform,.Read),hidden:^core.Table(erender.Hidden,.Read),parents:^core.Table(core.Parent,.Read),
    bindings:^core.Table(Particle_Bindings,.Read),meshes:^core.Table(erender.Mesh_Renderer,.Read),drawn:core.Ref(erender.Render_Sync),listeners:^core.Table(Particle_Channel,.Read),grids:^core.Table(Particle_Grid,.Read),volumes:^core.Table(Particle_Volume,.Read),textures:^core.Table(Particle_World_Texture,.Read),
    clocks:core.Ref(Particle_Clocks),settings:core.Ref(Particle_Settings),sync:^Particle_Sync,reports:^Particle_Reports,watch:^Particle_Data_Watch,read:^Particle_Data_Read,ui_effects:^UI_Particles,ui_requests:core.Ref(gui.UI_Effects),id:core.World_Id,time:core.Time,frame:core.Frame_Time,
    view:core.View,problems:^core.Problems,app:^host.App,
    winds:^core.Table(volume.Wind,.Read),places:^core.Table(volume.Volume,.Read),gravities:^core.Table(volume.Gravity,.Read),sections:^core.Table(scene.Scene_Reference,.Read),
) {
    if sync==nil {return}
    data_read(read,reports,sync,app.renderer,id,problems)
    r,a:=app.renderer,app.assets
    sync.world,sync.world_id=erender.world_key(id),id
    clear(&sync.descs)
    clear(&sync.owners)
    clear(&sync.resources)
    clear(&sync.stage_rows)
    clear(&sync.segments)
    grids_sync(&sync.grids,grids,volumes,textures,worlds,view,problems)
    sync.fields=fields_of(gravities,winds,{places,worlds,parents,sections})
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
    placed:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&placed) {
        shown:=shown_of(sync,e)
        if shown==nil {continue}
        key:=base.hash_combine(base.hash_combine(emitter.particle[0],emitter.particle[1]),a!=nil?a.revision:0)
        key=base.hash_combine(base.hash_combine(base.hash_combine(key,row_stamp(overrides,e)),shaders),made)|1
        if shown.resolved!=key {
            override,_:=core.get(overrides,e)
            shown.resolved=shown_resolve(shown,a,r,emitter.particle,&override,{u64(e),sub_id(e)},&shown.needs)?key:0
            shown.desc.owner,shown.sub_desc.owner=e,e
            shown.desc.revision,shown.sub_desc.revision=shown.resolved,shown.resolved
        }
        for d in ([2]^Emitter_Desc{&shown.desc,&shown.sub_desc}) {
            if d.id==0 || !(d.info.sort || d.info.render==.Ribbon) {continue}
            if needed:=emitter_capacity(&d.info);needed>SORT_MAX {
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
        if shape:=shown.desc.info.shape;shape==.Surface || shape==.Bones || shown.needs.resources[0].kind!=.None || shown.needs.stages[0].kind!=.None {
            bound,_:=core.get(bindings,e)
            rows:=emitter_resources(sync,shown,&bound,e,host.extras_instances(&app.extras),drawn.ptr,meshes,worlds,id,app.assets,app.renderer)
            desc.resources=u32(len(sync.resources))+1
            append(&sync.resources,..rows[:])
        }
        desc.stages=emitter_stages(sync,&shown.needs,desc.resources,desc.id,e,problems)
        for need in shown.needs.resources {
            if need.kind==.Data {data_need(&sync.data,need.name,need.words,problems,e)}
        }
        if listener,listens:=core.get(listeners,e);listens && !listener.silent {desc.births.x,desc.births.y=channel_region(sync,channel_key(listener))}
        desc.paused,desc.generation=paused,shown.generation
        if shown.sub_desc.id!=0 {
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
    data_watched(&sync.data,watched)
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
        for &entry in sync.data.entries {erender.readback_release(renderer,id,data_readback_desc(&entry).name)}
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
// GPU is told of them; ids: of its emitter and of that of its sub effect.
// False without assets, or while the renderer does not have the triangles of
// its mesh: it is resolved again.
@(private)
shown_resolve :: proc(shown:^Emitter_Shown,a:^host.Assets,renderer:^erender.Renderer,particle:base.Asset_Id,override:^Particle_Override,ids:[2]u64,needs:^Program_Needs) -> bool {
    if a==nil {return false}
    ready:bool
    shown.desc,ready=emitter_desc(particle_resolve(a,particle,override),a,renderer,ids[0])
    d:=&shown.desc
    problem:=particle_program(a,particle,&d.info,override,&d.program,needs)
    shown.sub_desc={}
    if d.info.trigger!=.None && d.info.sub_particle!={} {
        sub_ready:bool
        shown.sub_desc,sub_ready=emitter_desc(particle_resolve(a,d.info.sub_particle,nil),a,renderer,ids[1])
        sub:=&shown.sub_desc
        if sub_problem:=particle_program(a,d.info.sub_particle,&sub.info,nil,&sub.program);problem=="" {problem=sub_problem}
        sub.capacity+=min(d.capacity*d.info.sub_count,1<<16)
        d.event_target=sub.id
        ready&&=sub_ready
    }
    base.text_set(shown.problem[:],problem)
    return ready
}

// The GPU names the emitter of the sub particle of an entity with this id.
@(private)
sub_id :: proc "contextless" (e:core.Entity) -> u64 {return base.hash_combine(u64(e),0x7375625f70617274)}

// What the GPU is told of an effect at an emitter, but for what each frame
// gives. ready: the renderer has the triangles of its mesh, or it draws none.
@(private)
emitter_desc :: proc(info:effect.Particle_Info,a:^host.Assets,renderer:^erender.Renderer,id:u64) -> (d:Emitter_Desc,ready:bool) {
    d.info,d.id,ready=info,id,true
    m:=&d.info
    d.capacity=emitter_capacity(m)
    if m.light_intensity<=0 || m.light_range<=0 {m.lights=0}
    d.material=erender.Material_Handle(m.material!={}?host.assets_material_row(a,m.material):0)
    if m.render==.Mesh {
        // A material that blends draws its meshes over the lit scene, as a sprite.
        if found:=host.assets_material(a,m.material);found!=nil {d.blended=found.info.alpha_mode==.Blend}
        entry:=m.mesh!={}?host.assets_mesh(a,m.mesh):host.assets_shape(a,.Cube)
        if entry!=nil {d.mesh.x,ready=erender.mesh_draw_range(renderer,entry.handle);d.mesh.y=u32(entry.handle)}
        ready||=renderer==nil
    }
    return
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
    time:f64,       // seconds of its generation
    generation:u32,
    emitted:u64,    // births since it began
}

// The status of the emitter at e; false when it has no clock yet.
status :: proc(clocks:^Particle_Clocks,emitter:Particle_Emitter,e:core.Entity) -> (s:Particle_Status,ok:bool) {
    clock:=clock_find(clocks,e)
    if clock==nil {return}
    s={time=clock.time,generation=clock.generation,emitted=clock.emitted}
    emitting:=clocks.playing?emitter.active:emitter.preview
    over:=!emitter.loop && clock.time>=f64(clock.emission.duration) || !emitting
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
subtree_done :: proc(emitters:^core.Table(Particle_Emitter,$A),clocks:^Particle_Clocks,hierarchy:core.Ref(core.Hierarchy),root:core.Entity) -> bool {
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

