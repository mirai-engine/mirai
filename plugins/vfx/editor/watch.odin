package vfx_editor

import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import vfx "plugins:vfx/runtime"

// What the editor reads back of the particles of a world to debug them, in a
// Simulate pass of its own each frame (vfx/runtime/inspect.odin): the rows of
// the emitter particle.instance.inspect looks at, at most WATCH_MAX of them,
// and the counters of every emitter for particle.pool.inspect, until
// WATCH_FRAMES frames go by without another call. A game binary has none of
// it.
WATCH_MAX :: 1024
WATCH_FRAMES :: 600
WATCH_POSES :: 4 // frames in flight whose poses wait for their rows

Particle_Watch :: struct {
    world:rawptr,            // the world it reads: the edited one or that of a Play; nil: none
    emitter:u64,             // the emitter whose rows it reads; 0: none
    pool:bool,               // the counters of every emitter too
    sync:^vfx.Particle_Sync, // of world, in the frame it reads it
    poses:[WATCH_POSES]Emitter_Pose,
    posed:int,
    seen:u64,                // the frame of the last rows it took
    until:u64,               // the editor frame after which it stops reading
}

// Reads the particles of an emitter of a world for the next WATCH_FRAMES
// frames, and only those of that world.
@(private)
watch_emitter :: proc(s:^editor.Session,w:^Particle_Watch,world:rawptr,emitter:u64) {
    watch_world_set(w,world)
    w.emitter,w.until=emitter,s.frame+WATCH_FRAMES
}

// Reads the counters of every emitter of a world for the next WATCH_FRAMES frames.
@(private)
watch_pool :: proc(s:^editor.Session,w:^Particle_Watch,world:rawptr) {
    watch_world_set(w,world)
    w.pool,w.until=true,s.frame+WATCH_FRAMES
}

@(private)
watch_world_set :: proc(w:^Particle_Watch,world:rawptr) {
    if w.world==world {return}
    w^={world=world}
}

// Whether a world is still the edited one or that of a Play.
@(private)
world_live :: proc(s:^editor.Session,world:rawptr) -> bool {
    return world!=nil && (world==s.edit_world || editor.run_of_world(s,world)!=nil)
}

@(private)
watch_ask :: proc(s:^editor.Session,v:^Vfx_Editor) {
    w:=&v.watch
    w.sync=nil
    if w.world!=nil && (!world_live(s,w.world) || s.frame>w.until) {watch_world_set(w,nil)}
    if w.world==nil || s.app==nil || s.app.renderer==nil {return}
    w.sync=host.app_world_storage(s.app,w.world,vfx.Particle_Sync)
    if w.sync==nil {return}
    if w.emitter!=0 || w.pool {erender.frame_pass(s.app.renderer,.Simulate,watch_pass,v)}
    watch_take(s,w)
}

@(private)
watch_pass :: proc(pass:^erender.Pass,user:rawptr) {
    w:=&(cast(^Vfx_Editor)user).watch
    sync:=w.sync
    if sync==nil || pass.world!=sync.world {return}
    if w.pool {states_read(pass,sync)}
    if w.emitter==0 {return}
    if pose,ok:=emitter_read(pass,sync,w.emitter,WATCH_MAX);ok {
        w.poses[w.posed%WATCH_POSES]=pose
        w.posed+=1
    }
}

// The rows of the watched emitter that came back since the last frame: those
// of values that are not finite are the vfx.nan problem of its entity.
@(private)
watch_take :: proc(s:^editor.Session,w:^Particle_Watch) {
    rows,ok:=emitter_rows(s.app.renderer,w.sync,w.poses[:])
    if !ok || rows.frame==w.seen || rows.id!=w.emitter {return}
    w.seen=rows.frame
    at:=vfx.pool_slot_find(&w.sync.pool,rows.id)
    if at<0 {return}
    desc:=&w.sync.pool.slots[at].desc
    name,fields:=watch_program(s,desc)
    if scan:=rows_scan(&rows,fields);scan.particles>0 {
        rows_report(host.app_world_storage(s.app,w.world,core.Problems),desc.owner,scan,name)
    }
}

// The Vfx program of an emitter by name and the fields of its Attributes;
// none without one, or while the shaders do not have it.
@(private)
watch_program :: proc(s:^editor.Session,desc:^vfx.Emitter_Desc) -> (name:string,fields:[]erender.Program_Attribute) {
    if desc.program.id==0 {return}
    name=base.text_get(desc.info.program[:])
    if program:=erender.program_find(s.app.assets,name,.Vfx);program!=nil {fields=program.attribute_fields}
    return
}
