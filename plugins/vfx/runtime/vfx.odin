package vfx

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
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
// of them values of its own. An effect of several emitters is one .particle
// of layers (effect.PARTICLE_LAYERS), each with a clock of its own.
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
    preset:effect.Particle_Preset,
    destroy_when_done:bool, // while playing, the entity and what hangs from it go once every emitter there is done
}

PARTICLE_EMITTER_DEFAULT :: Particle_Emitter{active=true,loop=true,preview=true}

// The clocks of the emitters, by entity. Those of a world that plays follow
// its ticks; those of the editor's world, the preview. A Play starts them over.
@(storage)
Particle_Clocks :: struct {
    clocks:core.Entity_Map(Emitter_Clock),
    layers:[dynamic]core.Entity_Map(Emitter_Clock),
    channels:[dynamic]Channel_Clock,
    seen_channels:core.Seen,
    seen_emitters,seen_worlds:core.Seen, // what the clocks of the emitters that went are pruned from
    playing:bool,                        // of a world that plays
}

// Particles alive at once in the emitters of a world.
@(storage,setting)
Particle_Settings :: struct {
    capacity:u32 `mirai:"min=1024,max=16777216,advanced"`, // the device may take less: then the renderer keeps the pool it has
    max_lights:u32 `mirai:"min=0,max=512,advanced"`,       // lights of particles at once (effect.Particle_Light), those of Light layers first; 0 disables
}

PARTICLE_SETTINGS_DEFAULT :: Particle_Settings{capacity=CAPACITY,max_lights=PARTICLE_LIGHTS}

// What the renderer was told of an emitter.
Emitter_Shown :: struct {
    resolved:u64,                // what it was resolved from: the asset, the values of the entity, the shaders and effect_inputs; 0: it is resolved again
    particle:base.Asset_Id,      // the effect it was resolved from
    inputs:u64,
    desc,sub_desc:Emitter_Desc,   // what the GPU is told of it and of its sub effect (id 0: none), but for what each frame gives
    needs:Program_Needs,          // the resources and stages its program declares
    resource_previous:[RESOURCE_ROWS]mm.Mat4, // where each of its resources was drawn last
    resource_placed:[RESOURCE_ROWS]bool,
    problem:[192]u8,             // why its program does not run, as text; empty when it does or there is none
    started:u64,                 // births of its clock started on the GPU
    layer_count:u8,
    generation:u32,
    paused:bool,                 // as its clock was when it was told
    culled:bool,                 // its emitter waits (Emitter_Clock.culled): not drawn
    every:bool,                  // each frame gives it something: its program, its resources or stages
    transform:mm.Mat4,           // where it was drawn last
    placed:bool,
    queued:u64,                  // the frame of Particle_Sync it was last told in
}

// What the GPU has of the emitters of a world: one for each world. The pool
// is told only of the emitters that changed since the last frame, from what
// the tables say changed and from their clocks, and of those whose frames
// give something every time.
@(storage,host,by_world,free="particle_sync_free")
Particle_Sync :: struct {
    shown:core.Entity_Map(Emitter_Shown),
    layers:[dynamic]core.Entity_Map(Emitter_Shown),
    emitter_infos:map[u64]^Emitter_Info,
    effects:map[base.Asset_Id]Effect_Stamp,
    effects_revision:u64,
    seen_emitters,seen_worlds:core.Seen, // what the emitters that went are pruned from
    seen_overrides,seen_hidden,seen_parents,seen_bindings,seen_listeners:core.Seen,
    frame:u64,                     // frames it told
    culls:[dynamic]Emitter_Cull,   // of the step: the emitters whose effect runs a max_instances of them
    told:[dynamic]core.Entity,     // the emitters told in this frame
    again:[dynamic]core.Entity,    // and those the next one tells again
    pool_made:u64,                 // Pool.made_count when every emitter was put in it; 0: none was
    revision,shaders:u64,          // of the assets and the shaders the effects were read with
    time:f64,          // seconds of the world at its last frame: of its ticks while it plays
    timed:bool,
    fields_seen:[7]core.Seen,
    fields_ready,fields_dirty:bool,
    fields_origin:[3]f32,
    fields:Gpu_Fields, // the gravity and the wind of the world, as the frame found them
    births:[dynamic]Gpu_Birth,   // of the channels, those the GPU starts in this frame
    regions:[dynamic]Channel_Region,
    channels:map[core.Birth_Channel]^Channel_Ring,
    passes:u64,        // calls of channels_step: what a birth a tick pushed again is kept for
    births_tick:u64,   // the tick the births were last read in
    births_lost:u64,   // of core.Births.log.lost, how many were reported
    world:u64,         // as the renderer names it (erender.world_key)
    world_id:core.World_Id,
    pool:Pool,
    surfaces:Surfaces,
    resource_bindings:map[[2]u64]core.Entity,
    bindings_seen:core.Seen,
    surface_extras:map[u64]int,
    surface_frame:u64,
    grids:Grids,
    stage_rows:[dynamic]Gpu_Stage, // of the emitters whose programs have stages, PROGRAM_STAGES each
    resources:[dynamic]Resource_Desc, // of the emitters that read some in this frame, RESOURCE_ROWS each
    bones:[dynamic]Gpu_Bone,          // the skeletons bones resources read in this frame, in the world
    bone_sources:[dynamic]Bone_Source, // whose they are
    pipelines:Particle_Pipelines,
    world_textures:[WORLD_TEXTURES]u64, // the names of the grids whose textures the renderer keeps
    world_texture_count:int,
    world_textures_changed,world_texture_layout_dirty:bool,
    world_frame:World_Textures_Frame, // the textures of the world as the last steps left them
    world_shown:World_Textures_Frame, // and as the steps before, which the views of this frame show
}

particle_sync_free :: proc(sync:^Particle_Sync) {
    for &shown in sync.shown.values {shown_drop(&shown)}
    core.entity_map_destroy(&sync.shown)
    for &layer in sync.layers {
        for &shown in layer.values {shown_drop(&shown)}
        core.entity_map_destroy(&layer)
    }
    for _,held in sync.emitter_infos {emitter_info_drop(held)}
    delete(sync.emitter_infos)
    delete(sync.effects)
    delete(sync.layers)
    delete(sync.told);delete(sync.again);delete(sync.culls)
    delete(sync.births);delete(sync.regions)
    channels_clear(sync)
    delete(sync.channels)
    pool_free(&sync.pool)
    surfaces_free(&sync.surfaces)
    delete(sync.surface_extras)
    delete(sync.resource_bindings)
    grids_free(&sync.grids)
    delete(sync.resources);delete(sync.stage_rows)
    delete(sync.bones);delete(sync.bone_sources)
    delete(sync.pipelines.groups);delete(sync.pipelines.by_program)
    sync^={}
}

// The clocks of the emitters one step further: the requests of the step,
// what each starts and the entities of the effects that are done.
@(step="fixed",loops="game editor",stage="end")
particles_tick :: proc(
    emitters:^core.Table(Particle_Emitter),overrides:^core.Table(Particle_Override),
    worlds:^core.Table(core.World_Transform,.Read),hierarchy:core.Ref(core.Hierarchy),entities:core.Commands,
    clocks:^Particle_Clocks,sync:^Particle_Sync,requests:^Particle_Requests,births:core.Ref(core.Births),listeners:^core.Table(Particle_Channel,.Read),
    time:core.Time,frame:core.Frame_Time,assets:^host.Assets,problems:^core.Problems,sources:core.Ref(scene.Simulation_Sources),
) {
    if clocks.playing!=time.playing {
        core.entity_map_clear(&clocks.clocks)
        for &layer in clocks.layers {core.entity_map_clear(&layer)}
        clear(&clocks.channels)
        clocks.seen_channels={}
        channels_clear(sync)
        clocks.playing=time.playing
    }
    channels_step(clocks,sync,births.log.items[:],listeners,time,problems)
    if lost:=births.log.lost;lost!=sync.births_lost {
        if lost>sync.births_lost {
            core.report(problems,core.NONE,"vfx.births","%d births were lost: core.Births holds %d of a frame and the one before, or memory ran out; push fewer births in a frame",lost-sync.births_lost,core.BIRTHS_CAPACITY)
        }
        sync.births_lost=lost
    }
    // The clocks of the emitters that went, or whose entity is no longer placed.
    c_emitters:=core.changes(emitters,&clocks.seen_emitters)
    c_worlds:=core.changes(worlds,&clocks.seen_worlds)
    core.entity_map_prune(&clocks.clocks,emitters,c_emitters)
    core.entity_map_prune(&clocks.clocks,worlds,c_worlds)
    for &layer in clocks.layers {
        core.entity_map_prune(&layer,emitters,c_emitters)
        core.entity_map_prune(&layer,worlds,c_worlds)
    }
    dt:=time.playing?time.dt:max(frame.dt,0)
    effects_read(sync,assets)
    requests_apply(requests,emitters,overrides,clocks,sync,problems,assets,time.playing)
    done:[dynamic]core.Entity
    done.allocator=context.temp_allocator
    // Which emitters wait: those past the cull_distance of their effect from
    // every simulation source, and those past the max_instances nearest of it.
    clear(&sync.culls)
    placed:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&placed) {
        clock:=clocks_resolve(clocks,sync,overrides,assets,e,emitter)
        if clock==nil {continue}
        clock.culled=false
        reach,most:=clock.emission.cull_distance,clock.emission.max_instances
        if reach<=0 && most==0 {continue}
        at:=world.transform.position
        near:=scene.sources_distance(sources.ptr,at,at)
        if reach>0 && near>reach {clock.culled=true;continue}
        if most>0 {append(&sync.culls,Emitter_Cull{particle=emitter.particle,preset=emitter.preset,distance=near,entity=e,most=most})}
    }
    culls_rank(clocks,sync.culls[:])
    ticked:=core.join(emitters,worlds)
    for e,emitter,world in core.each_joined(&ticked) {
        clock:=clock_find(clocks,e)
        if clock==nil {continue}
        listener,listens:=core.get(listeners,e)
        if !listens {listener={}}
        all_done:=true
        for layer in 0..=int(clock.layers) {
            layer_clock:=clock_find(clocks,e,layer)
            if layer_clock==nil {continue}
            emits_preview:=layer==0
            if !clock.culled {emitter_tick(layer_clock,emitter,listener,world,dt,time,clocks,sync,emits_preview)}
            all_done&&=layer_clock.done
        }
        if time.playing && all_done && emitter.destroy_when_done {append(&done,e)}
    }
    for e in done {
        if subtree_done(emitters,clocks,hierarchy,e) {core.destroy(entities,e)}
    }
}

// An emitter of an effect that runs at most `most` of its emitters at once,
// and how far it is from the nearest simulation source.
@(private)
Emitter_Cull :: struct {
    particle:base.Asset_Id,
    preset:effect.Particle_Preset,
    most:u16,
    distance:f32,
    entity:core.Entity,
}

// Of each effect, the most nearest go on; the others wait. The same ties
// fall the same way on every machine: nearest, then by entity.
@(private)
culls_rank :: proc(clocks:^Particle_Clocks,culls:[]Emitter_Cull) {
    slice.sort_by(culls,proc(a,b:Emitter_Cull) -> bool {
        if a.particle!=b.particle {return a.particle[0]<b.particle[0] || a.particle[0]==b.particle[0] && a.particle[1]<b.particle[1]}
        if a.preset!=b.preset {return a.preset<b.preset}
        if a.distance!=b.distance {return a.distance<b.distance}
        return a.entity<b.entity
    })
    rank:=0
    for cull,i in culls {
        if i>0 && (cull.particle!=culls[i-1].particle || cull.preset!=culls[i-1].preset) {rank=0}
        if rank>=int(cull.most) {
            if clock:=clock_find(clocks,cull.entity);clock!=nil {clock.culled=true}
        }
        rank+=1
    }
}

// Whether the particles of a clock of e stand still: it is paused, or its
// emitter waits (Emitter_Clock.culled).
@(private)
clock_held :: proc(clocks:^Particle_Clocks,e:core.Entity,clock:^Emitter_Clock) -> bool {
    if clock.paused {return true}
    primary:=clock_find(clocks,e)
    return primary!=nil && primary.culled
}

@(private)
clocks_resolve :: proc(clocks:^Particle_Clocks,sync:^Particle_Sync,overrides:^core.Table(Particle_Override,$A),
    assets:^host.Assets,e:core.Entity,emitter:Particle_Emitter,
) -> ^Emitter_Clock {
    clock:=clock_of(clocks,e)
    if clock==nil {return nil}
    inputs:=effect_stamp(sync,assets,emitter.particle)
    // The shaders too: the program of the effect says whether it gives the births.
    key:=emission_key(emitter.particle,row_stamp(overrides,e),inputs,emitter.preset,sync.shaders)
    if clock.resolved==key {return clock}
    override,_:=core.get(overrides,e)
    info:=particle_resolve(assets,emitter.particle,&override,emitter.preset)
    clock.emission=emission_of(assets,&info)
    count:=0
    if assets!=nil && emitter.particle!={} {
        if view,ok:=effect_view(assets,emitter.particle);ok {count=len(view.layers)}
    }
    if count>len(clocks.layers) && resize(&clocks.layers,count)!=nil {return clock}
    for layer in 0..<count {
        more:=clock_of(clocks,e,layer+1)
        if more==nil {return clock}
        values:=particle_resolve(assets,emitter.particle,&override,emitter.preset,u8(layer+1))
        more.emission=emission_of(assets,&values)
    }
    for layer in count..<int(clock.layers) {core.entity_map_remove(&clocks.layers[layer],e)}
    clock.layers=u8(count)
    clock.resolved=key
    return clock
}

@(private)
emitter_tick :: proc(clock:^Emitter_Clock,emitter:Particle_Emitter,listener:Particle_Channel,
    world:core.World_Transform,dt:f32,time:core.Time,clocks:^Particle_Clocks,sync:^Particle_Sync,emits_preview:bool,
) {
    emitting:=time.playing?emitter.active:emitter.preview
    before:=clock.time
    position:=world.transform.position
    // An entity that jumps (core.Jump) comes from elsewhere than where the clock saw it last:
    // its ribbons do not join across the jump.
    if time.playing && clock.placed && linalg.length(world.previous.position-clock.position)>JUMP_DISTANCE {clock.segment+=1}
    emission_step(clock,&clock.emission,emitting,emitter.loop,position,dt)
    if !listener.silent && !clock.paused && channel_key(listener)!=0 {
        if time.playing {
            if channel:=channel_clock(clocks,channel_key(listener));channel!=nil && channel.emitted>0 {
                now:=time.seconds+f64(time.dt)
                clock.last=max(clock.last,clock.time-max(now-channel.latest,0))
                emission_done(clock,&clock.emission,emitting,emitter.loop)
            }
        } else if emitting && emits_preview {
            channel_preview(clocks,sync,listener,position,before,clock.time,f64(clock.emission.duration))
        }
    }
    if !time.playing && clock.done && emitter.preview && emitter.loop {clock_restart(clock)}
}

// The emitters of the world that changed to the GPU: what they show, where
// they are and the births of their clocks it did not start yet.
@(step="render",loops="game editor",after="render_sync")
particles_sync :: proc(
    emitters:^core.Table(Particle_Emitter,.Read),overrides:^core.Table(Particle_Override,.Read),
    worlds:^core.Table(core.World_Transform,.Read),hidden:^core.Table(erender.Hidden,.Read),parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),
    bindings:^core.Table(Particle_Bindings,.Read),sources:^core.Table(Particle_Binding,.Read),meshes:^core.Table(erender.Mesh_Renderer,.Read),drawn:core.Ref(erender.Render_Sync),listeners:^core.Table(Particle_Channel,.Read),grids:^core.Table(Particle_Grid,.Read),volumes:^core.Table(Particle_Volume,.Read),textures:^core.Table(Particle_World_Texture,.Read),
    clocks:core.Ref(Particle_Clocks),settings:core.Ref(Particle_Settings),sync:^Particle_Sync,ui_effects:^UI_Particles,ui_requests:core.Ref(gui.UI_Effects),id:core.World_Id,time:core.Time,frame:core.Frame_Time,
    view:core.View,problems:^core.Problems,app:^host.App,
    winds:^core.Table(volume.Wind,.Read),places:^core.Table(volume.Volume,.Read),gravities:^core.Table(volume.Gravity,.Read),sections:^core.Table(scene.Scene_Reference,.Read),splines:^core.Table(volume.Spline,.Read),
    bones:core.Ref(Particle_Bones),
) {
    if sync==nil {return}
    r,a:=app.renderer,app.assets
    pool_drain(&sync.pool,r,id)
    sync.world,sync.world_id=erender.world_key(id),id
    clear(&sync.resources)
    clear(&sync.stage_rows)
    clear(&sync.bones);clear(&sync.bone_sources)
    bindings_sync(sync,sources,problems)
    grids_sync(&sync.grids,grids,volumes,textures,worlds,view,problems)
    fields_sync(sync,gravities,winds,{places,worlds,parents,sections,splines})
    // Stronger fields take particles farther: the boxes of the emitters grow.
    if gravity,wind:=fields_reach(&sync.fields);gravity!=sync.pool.gravity_reach || wind!=sync.pool.wind_reach {
        sync.pool.gravity_reach,sync.pool.wind_reach=gravity,wind
        for at in sync.pool.order[:sync.pool.order_count] {emitter_bounds(&sync.pool,&sync.pool.slots[at])}
    }
    world_textures_keep(sync,app.renderer,id)
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
        wanted:=core.count(emitters)>0 || len(asked)>0 || ui_effects!=nil && len(ui_effects.effects)>0
        if !pool_frame(&sync.pool,dt,capacity,erender.max_storage_range(app),still,wanted) {
            core.report(problems,core.NONE,"vfx.capacity","the device takes no pool of %d particles: ask a smaller Particle_Settings.capacity",capacity)
            pooled=false
        } else if sync.pool.refused==capacity && sync.pool.capacity!=capacity {
            core.report(problems,core.NONE,"vfx.capacity","the device takes no pool of %d particles: the world keeps %d; ask a smaller Particle_Settings.capacity",capacity,sync.pool.capacity)
        }
    }
    f:=Sync_Frame{
        sync=sync,emitters=emitters,overrides=overrides,worlds=worlds,hidden=hidden,parents=parents,bindings=bindings,sources=sources,bones=bones.ptr,meshes=meshes,listeners=listeners,
        drawn=drawn.ptr,clocks=clocks.ptr,frame=frame,problems=problems,app=app,id=id,shaders=app.shaders.reloads,pooled=pooled,
    }
    effects_read(sync,a)
    sync_gather(&f,hierarchy)
    for e in sync.told {
        if emitter_tell(&f,e) {append(&sync.again,e)}
    }
    grids_release(&sync.grids,&sync.pool)
    if ui_effects!=nil && (len(ui_effects.effects)>0 || len(asked)>0) {
        ui_effects_sync(ui_effects,asked,app.assets,app.renderer,clamp(frame.dt,0,1),f.shaders,sync)
    }
    emitter_infos_prune(&sync.emitter_infos)
    effects_prune(sync)
    if !pooled {return}
    host.assets_commit(a)
    particles_frame(sync,app,settings.max_lights)
    lights_report(problems,app.renderer,&sync.pool)
}

// Reports the lights the particles of a world gave past the most it shows,
// as the finish pass counted them two frames before (particle_finish).
lights_report :: proc(problems:^core.Problems,renderer:^erender.Renderer,pool:^Pool) {
    counted,ok:=erender.counters(renderer,"particles")
    if !ok || counted[2]==0 || !pool.lights {return}
    core.report(problems,core.NONE,"vfx.lights_over","particles gave %d lights and %d are shown (Particle_Settings.max_lights), those of Light layers first: raise max_lights, or give fewer particles a light (Particle_Light.fraction and max_lights)",counted[2]+counted[3],counted[3])
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
    sources:^core.Table(Particle_Binding,.Read),
    bones:^Particle_Bones,
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
    gone :: proc(sync:^Particle_Sync,left:^Emitter_Shown,primary:=true) {
        pool_orphan(&sync.pool,left.desc.id)
        pool_orphan(&sync.pool,left.sub_desc.id)
        if primary {effect_drop(sync,left.particle)}
        shown_drop(left)
    }
    c_emitters:=core.changes(f.emitters,&sync.seen_emitters)
    c_worlds:=core.changes(f.worlds,&sync.seen_worlds)
    at,left:=0,Emitter_Shown{}
    for _ in core.entity_map_left(&sync.shown,f.emitters,c_emitters,&at,&left) {gone(sync,&left)}
    at=0
    for _ in core.entity_map_left(&sync.shown,f.worlds,c_worlds,&at,&left) {gone(sync,&left)}
    for &layer in sync.layers {
        at=0
        for _ in core.entity_map_left(&layer,f.emitters,c_emitters,&at,&left) {gone(sync,&left,false)}
        at=0
        for _ in core.entity_map_left(&layer,f.worlds,c_worlds,&at,&left) {gone(sync,&left,false)}
    }
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
            if shown:=core.entity_map_get(&sync.shown,e);shown!=nil && (clock.emitted!=shown.started || clock.generation!=shown.generation || clock_held(clocks,e,&clock)!=shown.paused) {sync_queue(sync,e,shown)}
        }
    }
    if clocks:=f.clocks;clocks!=nil {
        for &layer,k in clocks.layers {
            for &clock,i in layer.values {
                e:=layer.entities[i]
                shown:^Emitter_Shown
                if k<len(sync.layers) {shown=core.entity_map_get(&sync.layers[k],e)}
                if shown==nil || clock.emitted!=shown.started || clock.generation!=shown.generation ||
                    clock_held(clocks,e,&clock)!=shown.paused {sync_queue_entity(sync,e)}
            }
        }
    }
    revision:=f.app.assets.revision if f.app.assets!=nil else 0
    reloaded:=f.shaders!=sync.shaders
    if revision!=sync.revision || reloaded {
        sync.revision,sync.shaders=revision,f.shaders
        for &shown,i in sync.shown.values {
            if reloaded || shown.inputs!=sync.effects[shown.particle].inputs {
                sync_queue(sync,sync.shown.entities[i],&shown)
            }
        }
    }
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
    inputs:=effect_stamp(sync,f.app.assets,emitter.particle)
    if shown.particle!=emitter.particle {
        effect_drop(sync,shown.particle)
        if stamp:=&sync.effects[emitter.particle];stamp!=nil {stamp.users+=1}
        shown.particle=emitter.particle
    }
    shown.inputs=inputs
    key:=emission_key(emitter.particle,row_stamp(f.overrides,e),inputs,emitter.preset,f.shaders)
    count:=int(shown.layer_count)
    load:=shown.resolved!=key
    for i in 0..<min(count,len(sync.layers)) {
        entry:=core.entity_map_get(&sync.layers[i],e)
        load||=entry==nil || entry.resolved!=key
    }
    if load {
        count=0
        if a:=f.app.assets;a!=nil && emitter.particle!={} {
            if view,ok:=effect_view(a,emitter.particle);ok {count=len(view.layers)}
        }
        if count>len(sync.layers) && resize(&sync.layers,count)!=nil {return true}
        for i in count..<len(sync.layers) {
            if gone:=core.entity_map_get(&sync.layers[i],e);gone!=nil {
                pool_orphan(&sync.pool,gone.desc.id)
                pool_orphan(&sync.pool,gone.sub_desc.id)
                shown_drop(gone)
                core.entity_map_remove(&sync.layers[i],e)
            }
        }
        shown.layer_count=u8(count)
    }
    layer_tell(f,e,emitter,&world,shown,key,0,&again)
    for i in 0..<count {
        entry:=core.entity_map_get(&sync.layers[i],e)
        if entry==nil {
            if entry,_=core.entity_map_put(&sync.layers[i],e,Emitter_Shown{});entry==nil {again=true;continue}
        }
        layer_tell(f,e,emitter,&world,entry,key,i+1,&again)
    }
    return
}

@(private)
layer_tell :: proc(f:^Sync_Frame,e:core.Entity,emitter:Particle_Emitter,world:^core.World_Transform,
    shown:^Emitter_Shown,key:u64,layer:int,again:^bool,
) {
    sync,a,r:=f.sync,f.app.assets,f.app.renderer
    if shown.resolved!=key {
        sub:=shown.sub_desc.id
        override,_:=core.get(f.overrides,e)
        id:=layer_id(e,layer)
        ready:=shown_resolve(shown,&sync.emitter_infos,a,r,emitter.particle,&override,
            {id,sub_id(core.Entity(id))},&shown.needs,nil,emitter.preset,layer=u8(layer))
        shown.resolved=key if ready else 0
        shown.desc.owner,shown.sub_desc.owner=e,e
        shown.desc.look,shown.sub_desc.look=key,key
        if sub!=0 && shown.sub_desc.id!=sub {pool_remove(&sync.pool,sub)}
        if shown.desc.spec==nil {again^=true;return}
        shown.every=shown.desc.program.id!=0 || shown.desc.info.shape==.Surface ||
            shown.needs.resources[0].kind!=.None || shown.needs.stages[0].kind!=.None
    }
    pose:=erender.drawn_transform(world^,f.frame)
    if !shown.placed {pose=world.transform}
    transform:=mm.transform_matrix(pose)
    spawns:[SPAWNS]Particle_Spawn
    age:f32
    born:u64
    birth_limit:f32 // a program starts nothing before the clock of its emitter emits
    if clock:=clock_find(f.clocks,e,layer);clock!=nil {
        if clock.generation!=shown.generation {
            shown.generation=clock.generation
            shown.started=max(shown.started,clock.first)
        }
        // A rollback that runs again less than what was started: what comes next starts.
        if clock.emitted<shown.started {shown.started=clock.emitted}
        born=shown.started
        spawns=births_since(clock,&shown.started)
        shown.paused=clock_held(f.clocks,e,clock)
        if primary:=clock_find(f.clocks,e);primary!=nil {shown.culled=primary.culled}
        age=f32(clock.time)
        if clock.emission.program_births {birth_limit=f32(clock.program_until)}
    }
    shown.desc.age,shown.desc.born,shown.desc.birth_limit=age,u32(born),birth_limit
    previous:=shown.placed?shown.transform:transform
    shown.transform,shown.placed=transform,true
    listener,listens:=core.get(f.listeners,e)
    listens&&=!listener.silent
    again^||=shown.resolved==0 || world.previous!=world.transform || shown.every || listens
    if !f.pooled {return}
    if erender.is_hidden(f.hidden,f.parents,e) {
        pool_remove(&sync.pool,shown.desc.id)
        pool_remove(&sync.pool,shown.sub_desc.id)
        return
    }
    desc:=&shown.desc
    desc.transform,desc.previous=transform,previous
    desc.spawns=spawns
    desc.resources,desc.stages,desc.births=0,0,{}
    if shown.desc.info.shape==.Surface || shown.needs.resources[0].kind!=.None || shown.needs.stages[0].kind!=.None {
        bound,_:=core.get(f.bindings,e)
        rows:=emitter_resources(sync,shown,&bound,f.sources,f.bones,e,host.extras_instances(&f.app.extras),f.drawn,f.meshes,f.worlds,f.id,f.frame,a,r)
        desc.resources=u32(len(sync.resources))+1
        append(&sync.resources,..rows[:])
    }
    desc.stages=emitter_stages(sync,&shown.needs,desc.resources,desc.id,e,f.problems)
    if listens {desc.births.x,desc.births.y=channel_region(sync,channel_key(listener))}
    desc.external_positions=listens
    desc.paused,desc.culled,desc.generation=shown.paused,shown.culled,shown.generation
    fits:=true
    if shown.sub_desc.id!=0 {
        sub:=&shown.sub_desc
        sub.transform,sub.previous=transform,previous
        sub.external_positions=true
        sub.paused,sub.culled,sub.generation=shown.paused,shown.culled,shown.generation
        fits=pool_put(&sync.pool,sub)
    }
    fits=pool_put(&sync.pool,desc) && fits
    if !fits {
        core.report(f.problems,e,"vfx.capacity","this emitter found no room among the %d particles and %d emitters of the world: ask a larger Particle_Settings.capacity, or fewer max_particles of its effect",sync.pool.capacity,EMITTER_CAPACITY)
        again^=true
    }
}

// A world that goes takes its particles with it.
@(step="release")
particles_release :: proc(sync:^Particle_Sync,id:core.World_Id,renderer:^erender.Renderer) {
    if sync==nil {return}
    if renderer!=nil {
        pool_release(renderer,id,&sync.pool)
        erender.buffer_release(renderer,id,world_buffer(sync).name)
        for name in sync.world_textures[:sync.world_texture_count] {erender.table_texture_release(renderer,id,world_texture_key(name))}
    }
    pool_free(&sync.pool)
    surfaces_free(&sync.surfaces)
    grids_free(&sync.grids)
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
            age=f32(max(clock.time-(b.time+instant),0)),spacing=b.spacing,ribbon=b.segment,
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
shown_resolve :: proc(shown:^Emitter_Shown,cache:^map[u64]^Emitter_Info,a:^host.Assets,
    renderer:^erender.Renderer,particle:base.Asset_Id,override:^Particle_Override,ids:[2]u64,
    needs:^Program_Needs,values:^effect.Particle_Info=nil,preset:=effect.Particle_Preset.Default,
    view:erender.Texture_Handle=0,layer:u8=0,
) -> bool {
    spec,sub_spec:Emitter_Info
    if values!=nil {spec.info=values^} else {spec.info=particle_resolve(a,particle,override,preset,layer)}
    resolved_needs:Program_Needs
    problem:=particle_program(a,particle,&spec.info,override,&spec.program,&resolved_needs,layer)
    emitter_look_for_view(&spec.info,view)
    desc,ready:=emitter_desc(&spec,a,renderer,ids[0],view)
    sub:Emitter_Desc
    if spec.info.trigger!=.None && spec.info.sub_particle!={} {
        sub_spec.info=particle_resolve(a,spec.info.sub_particle,nil)
        if sub_problem:=particle_program(a,spec.info.sub_particle,&sub_spec.info,nil,&sub_spec.program);
           problem=="" {problem=sub_problem}
        emitter_look_for_view(&sub_spec.info,view)
        sub_desc,sub_ready:=emitter_desc(&sub_spec,a,renderer,ids[1],view)
        sub=sub_desc
        events:=u64(desc.capacity)*u64(spec.info.sub_count)
        if spec.info.trigger==.Trail {
            life:=max(sub.info.lifetime[0],sub.info.lifetime[1],0)
            events*=u64(min(math.ceil(f32(TRAILS_PER_SECOND)*life),1<<16))
        }
        sub.capacity+=u32(min(events,1<<16))
        desc.event_target=sub.id
        ready&&=sub_ready
        sub.spec=emitter_info_intern(cache,&sub_spec)
        if sub.spec==nil {return false}
    }
    // Values of its own change in place, frame after frame; those of an effect are shared.
    if override!=nil && override.count>0 && override_reaches(override,layer) {
        desc.spec=emitter_info_own(shown.desc.spec,&spec)
    } else {
        desc.spec=emitter_info_intern(cache,&spec)
    }
    if desc.spec==nil {emitter_info_drop(sub.spec);return false}
    shown_drop(shown)
    shown.desc=desc
    shown.sub_desc=sub
    if needs!=nil {needs^=resolved_needs}
    base.text_set(shown.problem[:],problem)
    return ready
}

@(private)
emitter_look_for_view :: proc(info:^effect.Particle_Info,view:erender.Texture_Handle) {
    if view!=0 {
        info.lit,info.emission_mode,info.collision,info.soft=false,.Relative,.None,0
    }
}

// Metres between where the clock of an emitter saw it last and where its entity says it
// was before this tick past which it jumped.
JUMP_DISTANCE :: f32(1e-3)

// The id the pool knows a layer of the emitter of an entity by (0 the primary).
layer_id :: proc "contextless" (e:core.Entity,layer:int) -> u64 {
    return u64(e) if layer==0 else base.hash_combine(u64(e),u64(layer)+0x706172746c617965)
}

// What the renderer was told of a layer of the emitter at e; nil for none.
shown_find :: proc(sync:^Particle_Sync,e:core.Entity,layer:int) -> ^Emitter_Shown {
    if layer==0 {return core.entity_map_get(&sync.shown,e)}
    if layer<0 || layer>len(sync.layers) {return nil}
    return core.entity_map_get(&sync.layers[layer-1],e)
}

// Whether a resource the emitter of shown reads in this frame has no source:
// the surface of its Surface shape, or one its program declares, bound to
// nothing there is.
resource_missing :: proc(sync:^Particle_Sync,shown:^Emitter_Shown) -> bool {
    if shown==nil || shown.desc.spec==nil {return false}
    first:=int(shown.desc.resources)-1
    surface:=shown.desc.info.shape==.Surface
    needed:=surface || shown.needs.resources[0].kind!=.None
    if !needed {return false}
    if first<0 || first+RESOURCE_ROWS>len(sync.resources) {return true}
    rows:=sync.resources[first:][:RESOURCE_ROWS]
    if surface && rows[0].kind==.None {return true}
    for need,at in shown.needs.resources {
        if need.kind!=.None && rows[1+at].kind==.None {return true}
    }
    return false
}

// The GPU names the emitter of the sub particle of an entity with this id.
@(private)
sub_id :: proc "contextless" (e:core.Entity) -> u64 {return base.hash_combine(u64(e),0x7375625f70617274)}

// What the GPU is told of an effect at an emitter, but for what each frame
// gives. ready: there are assets, and the renderer has the triangles of its
// mesh or it draws none.
@(private)
emitter_desc :: proc(spec:^Emitter_Info,a:^host.Assets,renderer:^erender.Renderer,id:u64,view:erender.Texture_Handle) -> (d:Emitter_Desc,ready:bool) {
    d.spec,d.id,d.view,ready=spec,id,view,true
    m:=&d.info
    d.capacity=emitter_capacity(m)
    if a==nil {return d,false}
    d.material=erender.Material_Handle(m.material!={}?host.assets_material_row(a,m.material):0)
    if m.render==.Mesh {
        // A material that blends or adds draws its meshes over the lit scene, as a sprite.
        if found:=host.assets_material(a,m.material);found!=nil {d.blended=asset.alpha_blended(found.info.alpha_mode)}
        // Each mesh of the effect with its weight; none: the cube.
        handles:[effect.PARTICLE_MESHES]erender.Mesh_Handle
        weights:[effect.PARTICLE_MESHES]f32
        count:=0
        opaque,blended:=false,false
        for id,c in m.meshes {
            if id=={} {continue}
            entry:=host.assets_mesh(a,id)
            if entry==nil {ready=false;continue}
            handles[count],weights[count]=entry.handle,m.mesh_weights[c]
            count+=1
            if m.material!={} {continue}
            opaque||=entry.slot_count==0
            for material in entry.slot_materials[:entry.slot_count] {
                row:=host.assets_material(a,material)
                alpha:=row!=nil && asset.alpha_blended(row.info.alpha_mode)
                opaque||=!alpha
                blended||=alpha
            }
        }
        if count==0 && ready {
            if cube:=host.assets_shape(a,.Cube);cube!=nil {handles[0],weights[0],count=cube.handle,1,1}
        }
        if m.material=={} {d.blended,d.mixed=blended && !opaque,blended && opaque}
        ready=mesh_choices(&d,renderer,handles[:count],weights[:count]) && ready
        ready||=renderer==nil
    }
    return
}

// The meshes Mesh particles show, with their weights added up to 1 (all 0:
// each as often). False while one of the meshes is not on the GPU yet.
mesh_choices :: proc(d:^Emitter_Desc,renderer:^erender.Renderer,handles:[]erender.Mesh_Handle,weights:[]f32) -> bool {
    d.meshes,d.mesh_count={},0
    total:f32
    for w in weights {total+=max(w,0)}
    ready:=true
    for handle,c in handles[:min(len(handles),effect.PARTICLE_MESHES)] {
        choice:=&d.meshes[c]
        _,drawable:=erender.mesh_primitive_count(renderer,handle)
        ready&&=drawable
        share:=max(weights[c],0)/total if total>0 else 1/f32(len(handles))
        choice^={handle=handle,weight=share+(d.meshes[c-1].weight if c>0 else 0)}
        d.mesh_count+=1
        if lo,hi,ok:=erender.mesh_bounds(renderer,handle);ok {
            extent:[3]f32
            for axis in 0..<3 {extent[axis]=max(abs(lo[axis]),abs(hi[axis]))}
            d.mesh_extent=max(d.mesh_extent,linalg.length(extent))
        }
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
    Culled,   // it waits, its particles as they are and not drawn: farther than the cull_distance of its effect from every simulation source, or past the max_instances nearest of it
}

// Where an emitter of the world is: what particles_tick says of its clock.
Particle_Status :: struct {
    state:Particle_State,
    time:f64,       // seconds of its generation
    generation:u32,
    emitted:u64,    // births since it began
    layers:u8,      // of its effect, the primary one among them
    alive:bool,     // it started a particle within the life of its longest one, or its program starts them now: some show
}

// The status of the emitter at e, of the layer it names (0 the primary); of
// every layer at once without one: playing while one plays, finishing while
// one finishes, done once all are, with the births of all and the seconds
// and the generation of the primary. False when it has no clock yet, or its
// effect not that layer.
status :: proc(clocks:^Particle_Clocks,emitter:Particle_Emitter,e:core.Entity,layer:=-1) -> (s:Particle_Status,ok:bool) {
    primary:=clock_find(clocks,e)
    if primary==nil {return}
    if layer>=0 {
        clock:=clock_find(clocks,e,layer)
        if clock==nil || layer>int(primary.layers) {return}
        s=clock_status(clocks,emitter,clock,primary.culled)
        s.layers=primary.layers+1
        return s,true
    }
    s=clock_status(clocks,emitter,primary,primary.culled)
    s.layers=primary.layers+1
    if s.state==.Paused || s.state==.Culled {return s,true}
    RANK :: [Particle_State]int{.Done=0,.Idle=1,.Finishing=2,.Playing=3,.Paused=4,.Culled=4}
    rank:=RANK
    for at in 1..=int(primary.layers) {
        clock:=clock_find(clocks,e,at)
        if clock==nil {continue}
        each:=clock_status(clocks,emitter,clock,false)
        s.emitted+=each.emitted
        s.alive||=each.alive
        if rank[each.state]>rank[s.state] {s.state=each.state}
    }
    return s,true
}

@(private)
clock_status :: proc(clocks:^Particle_Clocks,emitter:Particle_Emitter,clock:^Emitter_Clock,culled:bool) -> (s:Particle_Status) {
    s={time=clock.time,generation=clock.generation,emitted=clock.emitted}
    s.alive=clock.emitted>clock.first && clock.time-clock.last<f64(clock.emission.longest) || clock.time<clock.program_until
    emitting:=clocks.playing?emitter.active:emitter.preview
    over:=!emitter.loop && clock.time>=f64(clock.emission.duration) || !emitting
    switch {
    case clock.paused: s.state=.Paused
    case culled: s.state=.Culled
    case clock.done: s.state=.Done
    case emitting && !over: s.state=.Playing
    case clock.time-clock.last<f64(clock.emission.tail): s.state=.Finishing
    case: s.state=.Idle
    }
    return
}

// Whether every emitter at e or under it is done.
@(private)
subtree_done :: proc(emitters:^core.Table(Particle_Emitter,$A),clocks:^Particle_Clocks,hierarchy:core.Ref(core.Hierarchy),root:core.Entity) -> bool {
    for e:=root;e!=core.NONE;e=core.subtree_next(hierarchy,root,e) {
        if !core.has(emitters,e) {continue}
        primary:=clock_find(clocks,e)
        if primary==nil {return false}
        for layer in 0..=int(primary.layers) {
            if clock:=clock_find(clocks,e,layer);clock==nil || !clock.done {return false}
        }
    }
    return true
}

// The clock of an emitter, if it has one.
@(private)
clock_find :: proc(clocks:^Particle_Clocks,e:core.Entity,layer:=0) -> ^Emitter_Clock {
    if clocks==nil || layer<0 || layer>len(clocks.layers) {return nil}
    rows:=&clocks.clocks if layer==0 else &clocks.layers[layer-1]
    return core.entity_map_get(rows,e)
}

@(private)
clock_of :: proc(clocks:^Particle_Clocks,e:core.Entity,layer:=0) -> ^Emitter_Clock {
    if clock:=clock_find(clocks,e,layer);clock!=nil {return clock}
    rows:=&clocks.clocks if layer==0 else &clocks.layers[layer-1]
    clock,_:=core.entity_map_put(rows,e,Emitter_Clock{last=-max(f64)})
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

