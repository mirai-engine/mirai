package vfx

import "core:math"
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
    effects:[dynamic]Effect_Seen,        // the effects the emissions were resolved from
    revision:u64,                        // of the assets the effects were read with
}

// Particles alive at once in the emitters of a world.
@(storage,setting)
Particle_Settings :: struct {
    capacity:u32 `mirai:"min=1024,max=16777216,advanced"`, // the device may take less: then the renderer keeps the pool it has
}

PARTICLE_SETTINGS_DEFAULT :: Particle_Settings{capacity=CAPACITY}

// What the renderer was told of an emitter.
Emitter_Shown :: struct {
    resolved:u64,                // what it was resolved from: the asset, the values of the entity, the shaders and effect_inputs; 0: it is resolved again
    particle:base.Asset_Id,      // the effect it was resolved from
    desc,sub_desc:Emitter_Desc,   // what the GPU is told of it and of its sub effect (id 0: none), but for what each frame gives
    needs:Program_Needs,          // the resources and stages its program declares
    resource_previous:[RESOURCE_ROWS]mm.Mat4, // where each of its resources was drawn last
    resource_placed:[RESOURCE_ROWS]bool,
    problem:[192]u8,             // why its program does not run, as text; empty when it does or there is none
    started:u64,                 // births of its clock started on the GPU
    generation:u32,
    paused:bool,                 // as its clock was when it was told
    every:bool,                  // each frame gives it something: its program, its resources or stages
    transform:mm.Mat4,           // where it was drawn last
    placed:bool,
    queued:u64,                  // the frame of Particle_Sync it was last told in
}

// What resolving an effect reads of the assets besides the values of an
// entity (effect_inputs), as its emitters were resolved with it.
Effect_Seen :: struct {
    particle:base.Asset_Id,
    inputs:u64,
    changed:bool, // in this frame
}

// What the GPU has of the emitters of a world: one for each world. The pool
// is told only of the emitters that changed since the last frame, from what
// the tables say changed and from their clocks, and of those whose frames
// give something every time.
@(storage,host,by_world,free="particle_sync_free")
Particle_Sync :: struct {
    shown:core.Entity_Map(Emitter_Shown),
    seen_emitters,seen_worlds:core.Seen, // what the emitters that went are pruned from
    seen_overrides,seen_hidden,seen_parents,seen_bindings,seen_listeners:core.Seen,
    frame:u64,                     // frames it told
    told:[dynamic]core.Entity,     // the emitters told in this frame
    again:[dynamic]core.Entity,    // and those the next one tells again
    pool_made:u64,                 // Pool.made_count when every emitter was put in it; 0: none was
    effects:[dynamic]Effect_Seen,  // the effects its emitters were resolved from
    revision,shaders,made:u64,     // of the assets, the shaders and the vertices of the scene the effects were read with
    time:f64,          // seconds of the world at its last frame: of its ticks while it plays
    timed:bool,
    fields:Gpu_Fields, // the gravity and the wind of the world, as the frame found them
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
    delete(sync.told);delete(sync.again);delete(sync.effects)
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
    // An emission is resolved again when its effect, or what the effect reads of the assets, changed.
    refreshed:=false
    if a!=nil && a.revision!=clocks.revision {
        clocks.revision=a.revision
        refreshed=effects_read(clocks.effects[:],a,nil)
    }
    done:[dynamic]core.Entity
    done.allocator=context.temp_allocator
    placed:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&placed) {
        clock:=clock_of(clocks,e)
        if clock==nil {continue}
        if key:=emission_key(emitter.particle,row_stamp(overrides,e));clock.resolved!=key || refreshed && effect_changed(clocks.effects[:],emitter.particle) {
            override,_:=core.get(overrides,e)
            if a!=nil {effect_seen(&clocks.effects,a,nil,emitter.particle)}
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
        if subtree_done(emitters,clocks,hierarchy,e) {core.destroy(entities,e)}
    }
}

// The emitters of the world that changed to the GPU: what they show, where
// they are and the births of their clocks it did not start yet.
@(step="render",loops="game editor",after="render_sync")
particles_sync :: proc(
    emitters:^core.Table(Particle_Emitter,.Read),overrides:^core.Table(Particle_Override,.Read),
    worlds:^core.Table(core.World_Transform,.Read),hidden:^core.Table(erender.Hidden,.Read),parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),
    bindings:^core.Table(Particle_Bindings,.Read),meshes:^core.Table(erender.Mesh_Renderer,.Read),drawn:core.Ref(erender.Render_Sync),listeners:^core.Table(Particle_Channel,.Read),grids:^core.Table(Particle_Grid,.Read),volumes:^core.Table(Particle_Volume,.Read),textures:^core.Table(Particle_World_Texture,.Read),
    clocks:core.Ref(Particle_Clocks),settings:core.Ref(Particle_Settings),sync:^Particle_Sync,reports:^Particle_Reports,watch:^Particle_Data_Watch,read:^Particle_Data_Read,ui_effects:^UI_Particles,ui_requests:core.Ref(gui.UI_Effects),id:core.World_Id,time:core.Time,frame:core.Frame_Time,
    view:core.View,problems:^core.Problems,app:^host.App,
    winds:^core.Table(volume.Wind,.Read),places:^core.Table(volume.Volume,.Read),gravities:^core.Table(volume.Gravity,.Read),sections:^core.Table(scene.Scene_Reference,.Read),splines:^core.Table(volume.Spline,.Read),
) {
    if sync==nil {return}
    data_read(read,reports,sync,app.renderer,id,problems)
    r,a:=app.renderer,app.assets
    sync.world,sync.world_id=erender.world_key(id),id
    clear(&sync.resources)
    clear(&sync.stage_rows)
    clear(&sync.segments)
    grids_sync(&sync.grids,grids,volumes,textures,worlds,view,problems)
    sync.fields=fields_of(gravities,winds,{places,worlds,parents,sections,splines})
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
    asked:[]gui.UI_Effect
    if ui_requests.ptr!=nil {asked=ui_requests.items[:]}
    // The world stands still while its UI plays: its emitters keep their
    // particles as they are and the pool goes with the frames.
    still:=ui_effects!=nil && dt<=0 && len(asked)>0
    if still {dt=clamp(frame.dt,0,1)}
    pooled:=r!=nil && a!=nil
    if pooled {
        capacity:=settings.capacity
        wanted:=core.count(emitters)>0 || len(asked)>0 || ui_effects!=nil && ui_effects.count>0
        if !pool_frame(&sync.pool,dt,capacity,erender.max_storage_range(app),still,wanted) {
            core.report(problems,core.NONE,"vfx.capacity","the device takes no pool of %d particles: ask a smaller Particle_Settings.capacity",capacity)
            pooled=false
        } else if sync.pool.refused==capacity && sync.pool.capacity!=capacity {
            core.report(problems,core.NONE,"vfx.capacity","the device takes no pool of %d particles: the world keeps %d; ask a smaller Particle_Settings.capacity",capacity,sync.pool.capacity)
        }
    }
    f:=Sync_Frame{
        sync=sync,emitters=emitters,overrides=overrides,worlds=worlds,hidden=hidden,parents=parents,bindings=bindings,meshes=meshes,listeners=listeners,
        drawn=drawn.ptr,clocks=clocks.ptr,frame=frame,problems=problems,app=app,id=id,shaders=app.shaders.reloads,pooled=pooled,
    }
    sync_gather(&f,hierarchy)
    for e in sync.told {
        if emitter_tell(&f,e) {append(&sync.again,e)}
    }
    grids_release(&sync.grids,&sync.pool)
    watched:[]u64
    if watch!=nil {watched=core.take(&watch.queue)}
    data_watched(&sync.data,watched)
    if ui_effects!=nil && (ui_effects.count>0 || len(asked)>0) {
        ui_effects_sync(ui_effects,asked,app.assets,app.renderer,clamp(frame.dt,0,1),f.shaders,&sync.pool)
    }
    if !pooled {return}
    host.assets_commit(a)
    particles_frame(sync,app)
}

// What particles_sync reads to tell the pool of an emitter.
@(private)
Sync_Frame :: struct {
    sync:^Particle_Sync,
    emitters:^core.Table(Particle_Emitter,.Read),
    overrides:^core.Table(Particle_Override,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    hidden:^core.Table(erender.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),
    bindings:^core.Table(Particle_Bindings,.Read),
    meshes:^core.Table(erender.Mesh_Renderer,.Read),
    listeners:^core.Table(Particle_Channel,.Read),
    drawn:^erender.Render_Sync,
    clocks:^Particle_Clocks,
    frame:core.Frame_Time,
    problems:^core.Problems,
    app:^host.App,
    id:core.World_Id,
    shaders:u64,  // the shader generation of the application
    pooled:bool,  // the world has a pool to put its emitters in
}

// The emitters to tell in this frame (Particle_Sync.told): those whose
// emitter, values, place, hiding, bindings or channel changed, those whose
// clock started births, restarted or paused since, those whose effect reads
// otherwise in the assets, those the last frame left to tell again, and all
// of them when the pool was made again. The pool loses the particles of those
// whose emitter or place went.
@(private)
sync_gather :: proc(f:^Sync_Frame,hierarchy:core.Ref(core.Hierarchy)) {
    sync:=f.sync
    sync.frame+=1
    clear(&sync.told)
    gone :: proc(sync:^Particle_Sync,left:^Emitter_Shown) {
        pool_remove(&sync.pool,left.desc.id)
        pool_remove(&sync.pool,left.sub_desc.id)
    }
    c_emitters:=core.changes(f.emitters,&sync.seen_emitters)
    c_worlds:=core.changes(f.worlds,&sync.seen_worlds)
    at,left:=0,Emitter_Shown{}
    for _ in core.entity_map_left(&sync.shown,f.emitters,c_emitters,&at,&left) {gone(sync,&left)}
    at=0
    for _ in core.entity_map_left(&sync.shown,f.worlds,c_worlds,&at,&left) {gone(sync,&left)}
    for row in core.each_changed(f.emitters,&c_emitters) {
        e:=core.entity_at(f.emitters,row)
        sync_queue(sync,e,shown_of(sync,e))
    }
    for row in core.each_changed(f.worlds,&c_worlds) {sync_queue_entity(sync,core.entity_at(f.worlds,row))}
    gather :: proc(sync:^Particle_Sync,table:^core.Table($T,$A),seen:^core.Seen) {
        c:=core.changes(table,seen)
        for e in c.gone {sync_queue_entity(sync,e)}
        for row in core.each_changed(table,&c) {sync_queue_entity(sync,core.entity_at(table,row))}
    }
    gather(sync,f.overrides,&sync.seen_overrides)
    gather(sync,f.bindings,&sync.seen_bindings)
    gather(sync,f.listeners,&sync.seen_listeners)
    // Hiding, showing or moving under another: what hangs from it.
    subtree :: proc(sync:^Particle_Sync,h:core.Ref(core.Hierarchy),table:^core.Table($T,$A),seen:^core.Seen) {
        c:=core.changes(table,seen)
        for e in c.gone {
            for at:=e;at!=core.NONE;at=core.subtree_next(h,e,at) {sync_queue_entity(sync,at)}
        }
        for row in core.each_changed(table,&c) {
            e:=core.entity_at(table,row)
            for at:=e;at!=core.NONE;at=core.subtree_next(h,e,at) {sync_queue_entity(sync,at)}
        }
    }
    subtree(sync,hierarchy,f.hidden,&sync.seen_hidden)
    subtree(sync,hierarchy,f.parents,&sync.seen_parents)
    // The clocks are written every tick, as their time goes: those that
    // started births, restarted or paused since they were told.
    if clocks:=f.clocks;clocks!=nil {
        for &clock,i in clocks.clocks.values {
            e:=clocks.clocks.entities[i]
            if shown:=core.entity_map_get(&sync.shown,e);shown!=nil && (clock.emitted!=shown.started || clock.generation!=shown.generation || clock.paused!=shown.paused) {sync_queue(sync,e,shown)}
        }
    }
    effects_refresh(f)
    for e in sync.again {sync_queue_entity(sync,e)}
    clear(&sync.again)
    // A pool made again holds none of them.
    if !f.pooled {
        sync.pool_made=0
    } else if sync.pool_made!=sync.pool.made_count {
        sync.pool_made=sync.pool.made_count
        for &shown,i in sync.shown.values {sync_queue(sync,sync.shown.entities[i],&shown)}
    }
}

// An emitter is told in this frame, once.
@(private)
sync_queue :: proc(sync:^Particle_Sync,e:core.Entity,shown:^Emitter_Shown) {
    if shown==nil || shown.queued==sync.frame {return}
    if _,error:=append(&sync.told,e);error==nil {shown.queued=sync.frame}
}

// The emitter at e, if the GPU was told of it, is told in this frame.
@(private)
sync_queue_entity :: proc(sync:^Particle_Sync,e:core.Entity) {sync_queue(sync,e,core.entity_map_get(&sync.shown,e))}

// The assets, the shaders or the vertices of the scene changed: the emitters
// whose effect reads otherwise are told, and resolved again.
@(private)
effects_refresh :: proc(f:^Sync_Frame) {
    sync,a,r:=f.sync,f.app.assets,f.app.renderer
    if a==nil {return}
    made:=erender.vertices_made(r)
    reloaded:=f.shaders!=sync.shaders
    if a.revision==sync.revision && !reloaded && made==sync.made {return}
    sync.revision,sync.shaders,sync.made=a.revision,f.shaders,made
    if !effects_read(sync.effects[:],a,r) && !reloaded {return}
    for &shown,i in sync.shown.values {
        if reloaded || effect_changed(sync.effects[:],shown.particle) {sync_queue(sync,sync.shown.entities[i],&shown)}
    }
}

// Reads again what each effect reads of the assets; true when that of one
// changed, which its changed says until the next read.
@(private)
effects_read :: proc(effects:[]Effect_Seen,a:^host.Assets,renderer:^erender.Renderer) -> (changed:bool) {
    for &effect in effects {
        inputs:=effect_inputs(a,renderer,effect.particle)
        effect.changed=inputs!=effect.inputs
        effect.inputs=inputs
        changed||=effect.changed
    }
    return
}

@(private)
effect_changed :: proc(effects:[]Effect_Seen,particle:base.Asset_Id) -> bool {
    for effect in effects {if effect.particle==particle {return effect.changed}}
    return false
}

// effect_inputs of an effect as its emitters were resolved with it; read now
// for one no emitter showed yet.
@(private)
effect_seen :: proc(effects:^[dynamic]Effect_Seen,a:^host.Assets,renderer:^erender.Renderer,particle:base.Asset_Id) -> u64 {
    for effect in effects {if effect.particle==particle {return effect.inputs}}
    inputs:=effect_inputs(a,renderer,particle)
    append(effects,Effect_Seen{particle=particle,inputs=inputs})
    return inputs
}

// What resolving an effect reads of the assets besides the values of an
// entity, as a hash: the files of the effect and of its sub effect, the rows
// and blending of their materials, and the meshes they draw with the indices
// the renderer draws them from.
@(private)
effect_inputs :: proc(a:^host.Assets,renderer:^erender.Renderer,particle:base.Asset_Id) -> u64 {
    h:=u64(1)
    id:=particle
    for _ in 0..<2 {
        if id=={} {break}
        if file:=host.assets_document(a,id,effect.PARTICLE_KIND);file!=nil {h=base.hash_combine(h,file.blob.header.content_hash)}
        info:=particle_resolve(a,id,nil)
        if info.material!={} {
            h=base.hash_combine(h,u64(host.assets_material_row(a,info.material)))
            if found:=host.assets_material(a,info.material);found!=nil {h=base.hash_combine(h,u64(found.info.alpha_mode))}
        }
        for mesh in info.meshes {
            if mesh=={} {continue}
            entry:=host.assets_mesh(a,mesh)
            if entry==nil {
                h=base.hash_combine(h,0)
                continue
            }
            first,indices,drawable:=erender.mesh_draw_range(renderer,entry.handle)
            h=base.hash_combine(base.hash_combine(h,u64(entry.handle)),u64(first)<<32|u64(indices)|u64(drawable)<<63)
        }
        id=info.sub_particle
    }
    return h
}

// Tells the pool what an emitter is now: what it shows, resolved again when
// its effect, the values of its entity or the shaders changed, where it is,
// and the births its clock started since. True when the next frame tells it
// again: it is not resolved yet, it is drawn between two places, the pool had
// no room for it, or its frames give something every time (its program, its
// resources or stages, or the births of its channel).
@(private)
emitter_tell :: proc(f:^Sync_Frame,e:core.Entity) -> (again:bool) {
    sync:=f.sync
    shown:=core.entity_map_get(&sync.shown,e)
    if shown==nil {return}
    emitter,on:=core.get(f.emitters,e)
    world,placed:=core.get(f.worlds,e)
    if !on || !placed {return}
    a,r:=f.app.assets,f.app.renderer
    key:=base.hash_combine(base.hash_combine(emitter.particle[0],emitter.particle[1]),row_stamp(f.overrides,e))
    key=base.hash_combine(base.hash_combine(key,f.shaders),a!=nil?effect_seen(&sync.effects,a,r,emitter.particle):0)|1
    if shown.resolved!=key {
        sub:=shown.sub_desc.id
        override,_:=core.get(f.overrides,e)
        shown.particle=emitter.particle
        shown.resolved=shown_resolve(shown,a,r,emitter.particle,&override,{u64(e),sub_id(e)},&shown.needs)?key:0
        shown.desc.owner,shown.sub_desc.owner=e,e
        if sub!=0 && shown.sub_desc.id!=sub {pool_remove(&sync.pool,sub)}
        for d in ([2]^Emitter_Desc{&shown.desc,&shown.sub_desc}) {
            if d.id==0 || !(d.info.sort || d.info.render==.Ribbon) {continue}
            if needed:=emitter_capacity(&d.info);needed>SORT_MAX {
                core.report(f.problems,e,"vfx.capacity","a sorted or ribbon effect keeps at most %d particles alive and this one needs %d: give it max_particles %d or less, or a lower rate or lifetime",SORT_MAX,needed,SORT_MAX)
            }
        }
        shape:=shown.desc.info.shape
        shown.every=shown.desc.program.id!=0 || shape==.Surface || shape==.Bones || shown.needs.resources[0].kind!=.None || shown.needs.stages[0].kind!=.None
    }
    pose:=erender.drawn_transform(world,f.frame)
    if !shown.placed {pose=world.transform}
    transform:=mm.transform_matrix(pose)
    spawns:[SPAWNS]Particle_Spawn
    age:f32
    born:u64
    if clock:=clock_find(f.clocks,e);clock!=nil {
        if clock.generation!=shown.generation {
            shown.generation=clock.generation
            shown.started=max(shown.started,clock.first)
        }
        // A rollback that runs again less than what was started: what comes next starts.
        if clock.emitted<shown.started {shown.started=clock.emitted}
        born=shown.started
        spawns=births_since(clock,&shown.started)
        shown.paused=clock.paused
        age=f32(clock.time)
    }
    previous:=shown.placed?shown.transform:transform
    shown.transform,shown.placed=transform,true
    listener,listens:=core.get(f.listeners,e)
    listens&&=!listener.silent
    again=shown.resolved==0 || world.previous!=world.transform || shown.every || listens
    if !f.pooled {return}
    if erender.is_hidden(f.hidden,f.parents,e) {
        pool_remove(&sync.pool,shown.desc.id)
        pool_remove(&sync.pool,shown.sub_desc.id)
        return
    }
    desc:=shown.desc
    desc.transform,desc.previous,desc.spawns=transform,previous,spawns
    desc.age,desc.born=age,u32(born)
    if shape:=shown.desc.info.shape;shape==.Surface || shape==.Bones || shown.needs.resources[0].kind!=.None || shown.needs.stages[0].kind!=.None {
        bound,_:=core.get(f.bindings,e)
        rows:=emitter_resources(sync,shown,&bound,e,host.extras_instances(&f.app.extras),f.drawn,f.meshes,f.worlds,f.id,a,r)
        desc.resources=u32(len(sync.resources))+1
        append(&sync.resources,..rows[:])
    }
    desc.stages=emitter_stages(sync,&shown.needs,desc.resources,desc.id,e,f.problems)
    for need in shown.needs.resources {
        if need.kind==.Data {data_need(&sync.data,need.name,need.words,f.problems,e)}
    }
    if listens {desc.births.x,desc.births.y=channel_region(sync,channel_key(listener))}
    desc.paused,desc.generation=shown.paused,shown.generation
    fits:=true
    if shown.sub_desc.id!=0 {
        sub:=shown.sub_desc
        sub.transform,sub.previous=transform,previous
        sub.paused,sub.generation=shown.paused,shown.generation
        fits=pool_put(&sync.pool,&sub)
    }
    fits=pool_put(&sync.pool,&desc) && fits
    if !fits {
        core.report(f.problems,e,"vfx.capacity","this emitter found no room among the %d particles and %d emitters of the world: ask a larger Particle_Settings.capacity, or fewer max_particles of its effect",sync.pool.capacity,EMITTER_CAPACITY)
        again=true
    }
    return
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
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    desc,ready:=emitter_desc(particle_resolve(a,particle,override),a,renderer,ids[0])
    shown.desc=desc
    d:=&shown.desc
    problem:=particle_program(a,particle,&d.info,override,&d.program,needs)
    shown.sub_desc={}
    if d.info.trigger!=.None && d.info.sub_particle!={} {
        sub_desc,sub_ready:=emitter_desc(particle_resolve(a,d.info.sub_particle,nil),a,renderer,ids[1])
        shown.sub_desc=sub_desc
        sub:=&shown.sub_desc
        if sub_problem:=particle_program(a,d.info.sub_particle,&sub.info,nil,&sub.program);problem=="" {problem=sub_problem}
        // Those of the events of its live particles: one each, or of a trail, those of a life of the sub effect.
        events:=u64(d.capacity)*u64(d.info.sub_count)
        if d.info.trigger==.Trail {events*=u64(min(math.ceil(f32(TRAILS_PER_SECOND)*max(sub.info.lifetime[0],sub.info.lifetime[1],0)),1<<16))}
        sub.capacity+=u32(min(events,1<<16))
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
// gives. ready: there are assets, and the renderer has the triangles of its
// mesh or it draws none.
@(private)
emitter_desc :: proc(info:effect.Particle_Info,a:^host.Assets,renderer:^erender.Renderer,id:u64) -> (d:Emitter_Desc,ready:bool) {
    d.info,d.id,ready=info,id,true
    m:=&d.info
    d.capacity=emitter_capacity(m)
    if a==nil {return d,false}
    d.material=erender.Material_Handle(m.material!={}?host.assets_material_row(a,m.material):0)
    if m.render==.Mesh {
        // A material that blends draws its meshes over the lit scene, as a sprite.
        if found:=host.assets_material(a,m.material);found!=nil {d.blended=found.info.alpha_mode==.Blend}
        // Each mesh of the effect with its weight; none: the cube.
        handles:[effect.PARTICLE_MESHES]erender.Mesh_Handle
        weights:[effect.PARTICLE_MESHES]f32
        count:=0
        for id,c in m.meshes {
            if id=={} {continue}
            entry:=host.assets_mesh(a,id)
            if entry==nil {ready=false;continue}
            handles[count],weights[count]=entry.handle,m.mesh_weights[c]
            count+=1
        }
        if count==0 && ready {
            if cube:=host.assets_shape(a,.Cube);cube!=nil {handles[0],weights[0],count=cube.handle,1,1}
        }
        ready=mesh_choices(&d,renderer,handles[:count],weights[:count]) && ready
        ready||=renderer==nil
    }
    return
}

// The meshes Mesh particles show, with the indices of a draw of each and
// their weights added up to 1 (all 0: each as often). False while one of the
// meshes is not on the GPU yet.
mesh_choices :: proc(d:^Emitter_Desc,renderer:^erender.Renderer,handles:[]erender.Mesh_Handle,weights:[]f32) -> bool {
    d.meshes,d.mesh_count={},0
    total:f32
    for w in weights {total+=max(w,0)}
    ready:=true
    for handle,c in handles[:min(len(handles),effect.PARTICLE_MESHES)] {
        choice:=&d.meshes[c]
        first,indices,drawable:=erender.mesh_draw_range(renderer,handle)
        ready&&=drawable
        share:=max(weights[c],0)/total if total>0 else 1/f32(len(handles))
        choice^={handle=handle,first=first,indices=indices,weight=share+(d.meshes[c-1].weight if c>0 else 0)}
        d.mesh_count+=1
    }
    if d.mesh_count>0 {d.meshes[d.mesh_count-1].weight=1}
    return ready
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

