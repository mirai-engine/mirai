package vfx

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// The skeletons a Vfx program reads (`//! resource name bones`): the plugin
// that animates an entity a Particle_Binding names gives its bones here in
// each frame before particles_sync, which reads them in the same frame. The
// bones of an entity that no binding names cost nothing, and those several
// emitters read go to the GPU once a frame.

@(storage,host,by_world,free="particle_bones_free")
Particle_Bones :: struct {
    entries:[dynamic]Bones_Entry,
    frame:u64, // frames begun (bones_begin)
}

Bones_Entry :: struct {
    entity:core.Entity,
    world:[]mm.Transform,     // bone i in the world, given in this frame: memory of the plugin that gave it
    parents:[dynamic]u32,     // of bone i; max(u32): a root
    previous:[dynamic][3]f32, // where each bone was in the frame before
    velocity:[dynamic][3]f32, // m/s of each bone since the frame before
    frame:u64,                // the last frame it was given in
}

// shaders/particles.slang PARTICLE_BONE_BYTES: a bone in the rows of the frame.
Gpu_Bone :: struct {
    world:[3][4]f32, // rows: its transform, its place relative to the origin of the renderer
    velocity:[3]f32, // m/s
    parent:u32,      // max(u32): a root
}
#assert(size_of(Gpu_Bone)==64)

// Where the bones of an entity are among those of a frame (Particle_Sync.bones).
@(private)
Bone_Source :: struct {
    entity:core.Entity,
    first,count:u32,
}

particle_bones_free :: proc(bones:^Particle_Bones) {
    for &entry in bones.entries {bones_entry_free(&entry)}
    delete(bones.entries)
    bones^={}
}

@(private)
bones_entry_free :: proc(entry:^Bones_Entry) {
    delete(entry.parents);delete(entry.previous);delete(entry.velocity)
}

// Begins the bones of a frame: those given in no frame of the last two go.
bones_begin :: proc(bones:^Particle_Bones) {
    bones.frame+=1
    kept:=0
    for &entry in bones.entries {
        entry.world=nil
        if entry.frame+2<bones.frame {bones_entry_free(&entry);continue}
        bones.entries[kept]=entry
        kept+=1
    }
    base.truncate(&bones.entries,kept)
}

// Gives the bones of an entity for this frame: bone i where world[i] is in the
// world, which stays valid until particles_sync reads it, moved since the
// frame before over dt seconds (still in its first frame, when its bones are
// others or without a dt). Returns the parents of its bones for the caller to
// fill, max(u32) for a root; nil without memory, and no emitter reads them.
bones_publish :: proc(bones:^Particle_Bones,e:core.Entity,world:[]mm.Transform,dt:f32) -> []u32 {
    entry:^Bones_Entry
    for &known in bones.entries {if known.entity==e {entry=&known;break}}
    if entry==nil {
        if _,error:=append(&bones.entries,Bones_Entry{entity=e});error!=nil {return nil}
        entry=&bones.entries[len(bones.entries)-1]
    }
    if entry.frame==bones.frame && len(entry.world)==len(world) {return entry.parents[:]}
    count:=len(world)
    moved:=entry.frame+1==bones.frame && len(entry.previous)==count && dt>0
    if resize(&entry.parents,count)!=nil || resize(&entry.previous,count)!=nil || resize(&entry.velocity,count)!=nil {
        entry.world,entry.frame=nil,0
        return nil
    }
    for bone,i in world {
        entry.velocity[i]=(bone.position-entry.previous[i])/dt if moved else {}
        entry.previous[i]=bone.position
    }
    entry.world,entry.frame=world,bones.frame
    return entry.parents[:]
}

// The bones of an entity given in this frame; nil without them.
bones_given :: proc(bones:^Particle_Bones,e:core.Entity) -> ^Bones_Entry {
    if bones==nil || e==core.NONE {return nil}
    for &entry in bones.entries {
        if entry.entity==e && entry.frame==bones.frame && entry.frame!=0 {return &entry}
    }
    return nil
}

// A bones resource of an entity: its bones among those of the frame, gathered
// once however many emitters read them. Kind None without them.
@(private)
bones_resource :: proc(sync:^Particle_Sync,bones:^Particle_Bones,e:core.Entity) -> Resource_Desc {
    for known in sync.bone_sources {
        if known.entity==e {return {kind=.Bones,first=known.first,count=known.count}}
    }
    entry:=bones_given(bones,e)
    if entry==nil || len(entry.world)==0 {return {}}
    first:=len(sync.bones)
    if reserve(&sync.bones,first+len(entry.world))!=nil {return {}}
    if _,error:=append(&sync.bone_sources,Bone_Source{e,u32(first),u32(len(entry.world))});error!=nil {return {}}
    for bone,i in entry.world {
        append(&sync.bones,Gpu_Bone{world=mm.mat4_rows(mm.transform_matrix(bone)),velocity=entry.velocity[i],parent=entry.parents[i]})
    }
    return {kind=.Bones,first=u32(first),count=u32(len(entry.world))}
}
