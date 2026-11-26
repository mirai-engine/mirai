package vfx

import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// What an emitter reads besides its values: the surface its Surface shape
// starts particles on, and the resources its Vfx
// program declares (`//! resource name kind`), in rows the GPU finds through the emitter (its
// shape first, then those of its program in their order). A surface is the
// mesh an entity draws in the frame, as the renderer has it: a skin moves its
// triangles, and a particle that keeps one follows it. The area of its
// triangles added up is made on the GPU the first time a world reads it, and
// again when the vertices of the scene are made again.

RESOURCES :: erender.PROGRAM_RESOURCES
RESOURCE_ROWS :: 1+RESOURCES

@(component,description="The entity whose mesh a Surface emitter samples.")
Particle_Bindings :: struct {
    surface:core.Entity,
}

@(component,description="Binds one named Vfx resource to an entity or a grid.")
Particle_Binding :: struct {
    emitter:core.Entity, // NONE uses the entity that holds this binding
    resource:[32]u8 `mirai:"text"`,
    entity:core.Entity,
    grid:[GRID_NAME_BYTES]u8 `mirai:"text"`,
}

@(private)
bindings_sync :: proc(sync:^Particle_Sync,bindings:^core.Table(Particle_Binding,.Read),
    problems:^core.Problems,
) {
    if bindings==nil || !core.touched(bindings,&sync.bindings_seen) {return}
    clear(&sync.resource_bindings)
    for row in 0..<core.count(bindings) {
        binding:=core.at(bindings,row)
        name:=base.text_get(binding.resource[:])
        if name=="" {continue}
        owner:=core.entity_at(bindings,row)
        emitter:=binding.emitter if binding.emitter!=core.NONE else owner
        key:=[2]u64{u64(emitter),base.name_hash(name)}
        if _,exists:=sync.resource_bindings[key];exists {
            core.report(problems,owner,"vfx.binding","give emitter %v one binding for %s",emitter,name)
            continue
        }
        if _,err:=map_insert(&sync.resource_bindings,key,owner);err!=nil {
            sync.bindings_seen={}
            core.report(problems,owner,"vfx.memory","out of memory for particle bindings: free memory")
            return
        }
    }
}

Resource_Kind :: enum u32 {None,Surface,Channel,Grid,Bones}

// A resource of an emitter in a frame.
Resource_Desc :: struct {
    kind:Resource_Kind,
    mesh:erender.Mesh_Handle,       // a surface: the mesh of the scene it is
    triangles:u32,                  // and its triangles
    first,count:u32,                // a channel: its births among those of the frame; a grid: which of the world; bones: in Particle_Sync.bones
    transform,previous:mm.Mat4,     // where it is this frame, and the frame before
}

// A resource the program of an effect declares.
Resource_Need :: struct {
    name:u64, // base.name_hash of its name
    kind:Resource_Kind,
    channel:core.Birth_Channel, // a channel: the one of its name
}

// shaders/particles.slang: Particle_Resource.
Gpu_Resource :: struct {
    head:[4]u32, // kind; a surface: mesh, first triangle in the surfaces, triangles; a channel: 0, first birth, births; a grid: bytes to its row; bones: bytes to the first, 0, bones
    world,previous:[3][4]f32,
}
#assert(size_of(Gpu_Resource)==112)

// The resources an emitter reads in this frame: the surface of its shape and
// those its program needs, from what the entity binds. A
// resource without a source has kind None: the program reads nothing from it.
@(private)
emitter_resources :: proc(
    sync:^Particle_Sync,shown:^Emitter_Shown,bindings:^Particle_Bindings,
    sources:^core.Table(Particle_Binding,.Read),bones:^Particle_Bones,
    e:core.Entity,extras:[]erender.Instance_Desc,drawn:^erender.Render_Sync,meshes:^core.Table(erender.Mesh_Renderer,.Read),worlds:^core.Table(core.World_Transform,.Read),id:core.World_Id,assets:^host.Assets,renderer:^erender.Renderer,
) -> (resources:[RESOURCE_ROWS]Resource_Desc) {
    source:=bindings.surface if bindings.surface!=core.NONE else e
    shape:=shown.desc.info.shape if shown.desc.spec!=nil else effect.Particle_Shape.Point
    if shape==.Surface {resources[0]=entity_surface(sync,extras,drawn,meshes,worlds,id,assets,renderer,source)}
    for need,at in shown.needs.resources {
        source,named:=core.NONE,""
        bound:Particle_Binding
        if owner,found:=sync.resource_bindings[[2]u64{u64(e),need.name}];found && sources!=nil {
            bound,_=core.get(sources,owner)
            source,named=bound.entity,base.text_get(bound.grid[:])
        }
        // A grid: that of the entity the emitter binds, or of the name it binds; else, the
        // first its stages go over, that of its own entity, and that of the world of its name.
        if need.kind==.Grid {
            grid:=-1
            switch {
            case source!=core.NONE: grid=grid_of_entity(&sync.grids,source)
            case named!="": grid=grid_find(&sync.grids,base.name_hash(named))
            case:
                if first_over(&shown.needs)==at {grid=grid_of_entity(&sync.grids,e)}
                if grid<0 {grid=grid_find(&sync.grids,need.name)}
            }
            if grid>=0 {resources[1+at]={kind=.Grid,first=u32(grid)}}
            continue
        }
        // A channel: the births of the channel of its name in this frame.
        if need.kind==.Channel {
            resources[1+at].kind=.Channel
            for region in sync.regions {
                if region.name==need.channel {resources[1+at].first,resources[1+at].count=region.first,region.count}
            }
            continue
        }
        if need.kind==.Bones {
            resources[1+at]=bones_resource(sync,bones,source)
            continue
        }
        if need.kind==.Surface && source!=core.NONE {
            resources[1+at]=entity_surface(sync,extras,drawn,meshes,worlds,id,assets,renderer,source)
        }
    }
    // Where each was the frame before: the first frame, where it is.
    for &resource,row in resources {
        if resource.kind!=.Surface {shown.resource_placed[row]=false;continue}
        resource.previous=shown.resource_previous[row] if shown.resource_placed[row] else resource.transform
        shown.resource_previous[row],shown.resource_placed[row]=resource.transform,true
    }
    return
}

// The first grid resource the stages of a program go over; -1: none.
@(private)
first_over :: proc "contextless" (needs:^Program_Needs) -> int {
    first:=-1
    for stage in needs.stages {
        if stage.kind==.Cells && (first<0 || int(stage.over)<first) {first=int(stage.over)}
    }
    return first
}

// The surface an entity draws in the frame: the mesh a visual instance draws
// in its place, or that of its own instance (its pose, when a library poses
// it), where the renderer draws it. Without the scene of its world in the
// renderer, its Mesh_Renderer where it is.
@(private)
entity_surface :: proc(sync:^Particle_Sync,extras:[]erender.Instance_Desc,drawn:^erender.Render_Sync,meshes:^core.Table(erender.Mesh_Renderer,$A),worlds:^core.Table(core.World_Transform,$B),id:core.World_Id,assets:^host.Assets,renderer:^erender.Renderer,e:core.Entity) -> (result:Resource_Desc) {
    if drawn!=nil && drawn.world==id {
        if sync.surface_frame!=sync.frame {
            clear(&sync.surface_extras)
            for &extra,i in extras {
                if extra.replace_source && extra.object_id!=0 {
                    if _,err:=map_insert(&sync.surface_extras,extra.object_id,i);err!=nil {
                        break
                    }
                }
            }
            sync.surface_frame=sync.frame
        }
        if i,found:=sync.surface_extras[u64(e)];found {
            extra:=&extras[i]
            return surface_of(renderer,extra.mesh,extra.transform)
        }
        if at:=core.entity_map_index(&drawn.drawn,e);at>=0 {
            if mesh,transform,held:=erender.instance_placed(renderer,at);held {return surface_of(renderer,mesh,transform)}
        }
    }
    shown,has_mesh:=core.get(meshes,e)
    world,placed:=core.get(worlds,e)
    if !has_mesh || !placed {return}
    entry:=shown.mesh!={}?host.assets_mesh(assets,shown.mesh):host.assets_shape(assets,shown.shape)
    if entry==nil {return}
    return surface_of(renderer,entry.handle,mm.transform_matrix(world.transform))
}

@(private)
surface_of :: proc(renderer:^erender.Renderer,mesh:erender.Mesh_Handle,transform:mm.Mat4) -> (result:Resource_Desc) {
    count,ok:=erender.mesh_primitive_count(renderer,mesh)
    if !ok || count==0 {return}
    return {kind=.Surface,mesh=mesh,triangles=count,transform=transform}
}

// The areas of the surfaces of a world, in a buffer of the renderer: each
// surface a run of floats, added up by the GPU when it is new.
Surfaces :: struct {
    entries:[dynamic]Surface_Entry,
    capacity:u32,      // floats of the buffer
    used:u32,          // floats the entries take
    vertices:u64,      // erender.vertices_made when they were made: the vertices of the scene again, the areas again
}

Surface_Entry :: struct {
    mesh:erender.Mesh_Handle,
    first,count:u32,
    built:bool,
    frame:u64,        // the last frame of the pool that read it
}

SURFACES_MIN :: 1<<16

surfaces_free :: proc(s:^Surfaces) {
    delete(s.entries)
    s^={}
}


// Where the areas of a surface are, taking room for a new one. When the
// buffer has no more room, the surfaces read in the last frames go first,
// in a buffer large enough for them: all of them are made again.
@(private)
surface_place :: proc(s:^Surfaces,mesh:erender.Mesh_Handle,count:u32,frame:u64) -> (first:u32,ok:bool) {
    for &entry in s.entries {
        if entry.mesh==mesh && entry.count==count {
            entry.frame=frame
            return entry.first,true
        }
    }
    if s.used+count>s.capacity {
        // Those of the last frames stay, from the start of the buffer.
        kept:=0
        s.used=0
        for entry in s.entries {
            if entry.frame+2<frame {continue}
            s.entries[kept]={mesh=entry.mesh,first=s.used,count=entry.count,frame=entry.frame}
            s.used+=entry.count
            kept+=1
        }
        base.truncate(&s.entries,kept)
        need:=s.used+count
        if need>s.capacity {
            capacity:=u32(SURFACES_MIN)
            for capacity<need+need/2 {capacity*=2}
            s.capacity=capacity
        }
        for &entry in s.entries {entry.built=false}
    }
    if _,error:=append(&s.entries,Surface_Entry{mesh=mesh,first=s.used,count=count,frame=frame});error!=nil {return 0,false}
    first=s.used
    s.used+=count
    return first,true
}
