package vfx

import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// What an emitter reads besides its values: the surface or the bones its
// Surface or Bones shape starts particles on, and the resources its Vfx
// program declares
// (`//! resource name kind`), in rows the GPU finds through the emitter (its
// shape first, then those of its program in their order). A surface is the
// mesh an entity draws in the frame, as the renderer has it: a skin moves its
// triangles, and a particle that keeps one follows it. The area of its
// triangles added up is made on the GPU the first time a world reads it, and
// again when the vertices of the scene are made again.

RESOURCES :: erender.PROGRAM_RESOURCES
RESOURCE_ROWS :: 1+RESOURCES

// The entities whose surfaces an emitter reads.
@(component)
Particle_Bindings :: struct {
    surface:core.Entity,                // what its Surface or Bones shape starts particles on: the mesh it draws; NONE: the mesh of its effect, or what its entity draws
    sources:[RESOURCES]Particle_Source, // what each resource of its program reads, by name, or the one of its index without a name; over the sources of its effect
}

Particle_Source :: struct {
    resource:[32]u8 `mirai:"text"`,           // as the program declares it
    entity:core.Entity,                       // a surface or bones: what it draws; a grid: the one of the entity
    grid:[GRID_NAME_BYTES]u8 `mirai:"text"`,  // a grid without entity: the one of the world of this name
}

Resource_Kind :: enum u32 {None,Surface,Channel,Bones,Grid,Emitter,Data}

// A resource of an emitter in a frame.
Resource_Desc :: struct {
    kind:Resource_Kind,
    mesh:erender.Mesh_Handle,       // a surface: the mesh of the scene it is
    triangles:u32,                  // and its triangles
    first,count:u32,                // a channel: its births among those of the frame; bones: its bones among those of the frame; a grid: which of the world
    emitter:u64,                    // an emitter: the id of the one it reads; a data channel: base.name_hash of its name
    transform,previous:mm.Mat4,     // where it is this frame, and the frame before
}

// A resource the program of an effect declares.
Resource_Need :: struct {
    name:u64, // base.name_hash of its name
    kind:Resource_Kind,
    words:u32, // a data channel: of an entry
    channel:Particle_Channel_Name, // a channel: the one of its name (channel_needs)
}

// shaders/particles.slang: Particle_Resource.
Gpu_Resource :: struct {
    head:[4]u32, // kind; a surface: mesh, first triangle in the surfaces, triangles; a channel: 0, first birth, births; bones: 0, bytes to the first, bones; a grid: bytes to its row; an emitter: 0, its slot
    world,previous:[3][4]f32,
}
#assert(size_of(Gpu_Resource)==112)

// The resources an emitter reads in this frame: the surface or the bones of
// its shape and those its program needs, from what the entity binds, then
// what its effect gives. A resource without a source has kind None: the
// program reads nothing from it.
@(private)
emitter_resources :: proc(
    sync:^Particle_Sync,shown:^Emitter_Shown,info:^effect.Particle_Info,sources:[]effect.Particle_Resource,bindings:^Particle_Bindings,
    e:core.Entity,transform:mm.Mat4,drawn:^erender.Render_Sync,meshes:core.Read(erender.Mesh_Renderer),worlds:core.Read(core.World_Transform),id:core.World_Id,app:^host.App,
) -> (resources:[RESOURCE_ROWS]Resource_Desc) {
    of_entity :: proc(sync:^Particle_Sync,kind:Resource_Kind,drawn:^erender.Render_Sync,meshes:core.Read(erender.Mesh_Renderer),worlds:core.Read(core.World_Transform),id:core.World_Id,app:^host.App,e:core.Entity) -> Resource_Desc {
        return entity_bones(sync,drawn,meshes,worlds,id,app.assets,app.renderer,e) if kind==.Bones else entity_surface(drawn,meshes,worlds,id,app.assets,app.renderer,e)
    }
    of_asset :: proc(sync:^Particle_Sync,kind:Resource_Kind,app:^host.App,mesh:base.Asset_Id,transform:mm.Mat4) -> Resource_Desc {
        return asset_bones(sync,app.assets,app.renderer,mesh,transform) if kind==.Bones else asset_surface(app.assets,app.renderer,mesh,transform)
    }
    if info.shape==.Surface || info.shape==.Bones {
        kind:=Resource_Kind.Bones if info.shape==.Bones else .Surface
        switch {
        case bindings.surface!=core.NONE: resources[0]=of_entity(sync,kind,drawn,meshes,worlds,id,app,bindings.surface)
        case info.surface_mesh!={}: resources[0]=of_asset(sync,kind,app,info.surface_mesh,transform)
        case: resources[0]=of_entity(sync,kind,drawn,meshes,worlds,id,app,e)
        }
    }
    for need,at in shown.needs.resources {
        // The source the emitter binds it to: by its name, or the one of its index without a name.
        bound:^Particle_Source
        binds :: proc(given:^Particle_Source) -> bool {return given.entity!=core.NONE || base.text_get(given.grid[:])!=""}
        for &given in bindings.sources {
            if binds(&given) && base.name_hash(base.text_get(given.resource[:]))==need.name {bound=&given}
        }
        if unnamed:=&bindings.sources[at];bound==nil && base.text_get(unnamed.resource[:])=="" && binds(unnamed) {bound=unnamed}
        source,named:=core.NONE,""
        if bound!=nil {source,named=bound.entity,base.text_get(bound.grid[:])}
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
        // A data channel: that of the world of its name.
        if need.kind==.Data {
            resources[1+at]={kind=.Data,emitter=need.name}
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
        // An emitter: the particles of the entity it names.
        if need.kind==.Emitter {
            if source!=core.NONE {resources[1+at]={kind=.Emitter,emitter=u64(source)}}
            continue
        }
        if need.kind!=.Surface && need.kind!=.Bones {continue}
        if source!=core.NONE {
            resources[1+at]=of_entity(sync,need.kind,drawn,meshes,worlds,id,app,source)
            continue
        }
        for &given in sources {
            if base.name_hash(base.text_get(given.name[:]))==need.name && given.mesh!={} {resources[1+at]=of_asset(sync,need.kind,app,given.mesh,transform)}
        }
    }
    // Where each was the frame before: the first frame, where it is.
    for &resource,row in resources {
        if resource.kind!=.Surface && resource.kind!=.Bones {shown.resource_placed[row]=false;continue}
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

// The surface of a mesh asset at a transform.
@(private)
asset_surface :: proc(assets:^host.Assets,renderer:^erender.Renderer,mesh:base.Asset_Id,transform:mm.Mat4) -> Resource_Desc {
    entry:=host.assets_mesh(assets,mesh)
    if entry==nil {return {}}
    return surface_of(renderer,entry.handle,transform)
}

// The surface an entity draws in the frame: the mesh that replaces its own
// (a skin), or its own, where the renderer draws it. Without the scene of its
// world in the renderer, its Mesh_Renderer where it is.
@(private)
entity_surface :: proc(drawn:^erender.Render_Sync,meshes:core.Read(erender.Mesh_Renderer),worlds:core.Read(core.World_Transform),id:core.World_Id,assets:^host.Assets,renderer:^erender.Renderer,e:core.Entity) -> Resource_Desc {
    if drawn!=nil && drawn.world==id {
        for &extra in drawn.extras {
            if extra.replace_source && extra.object_id==u64(e) {return surface_of(renderer,extra.mesh,extra.transform)}
        }
        if at:=core.entity_map_index(&drawn.drawn,e);at>=0 && at<len(drawn.instances) {
            instance:=drawn.instances[at]
            return surface_of(renderer,instance.mesh,instance.transform)
        }
    }
    shown,has_mesh:=core.get(meshes,e)
    world,placed:=core.get(worlds,e)
    if !has_mesh || !placed {return {}}
    entry:=shown.mesh!={}?host.assets_mesh(assets,shown.mesh):host.assets_shape(assets,shown.shape)
    if entry==nil {return {}}
    return surface_of(renderer,entry.handle,mm.transform_matrix(world.transform))
}

@(private)
surface_of :: proc(renderer:^erender.Renderer,mesh:erender.Mesh_Handle,transform:mm.Mat4) -> Resource_Desc {
    count,ok:=erender.mesh_draw_range(renderer,mesh)
    if !ok || count<3 {return {}}
    return {kind=.Surface,mesh=mesh,triangles=count/3,transform=transform}
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
