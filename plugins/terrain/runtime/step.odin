package terrain

import "base:runtime"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import render "mirai:engine/render"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// The chunks of the terrains: entities terrain makes under each one, whose
// meshes, tints and colliders it writes (shared tables). Their Transform and
// Parent it gives through commands: those tables have other writers.
@(private)
Chunk_Tables :: struct {
    commands:core.Commands,
    chunks:^core.Table(Terrain_Chunk),
    locals:core.Read(core.Transform),
    parents:core.Read(core.Parent),
    ids:core.Read(core.Id),
    colliders:^core.Table(phys.Collider),
    meshes:^core.Table(render.Mesh_Renderer),
    tints:^core.Table(render.Tint),
    overrides:^core.Table(render.Material_Override),
}

// The slots of Physics_Settings the colliders of terrain chunks can still
// take in a call: what the simulation has, less the colliders the tables
// hold. A chunk whose collider finds no slot shows its ground without it.
Collider_Room :: struct {
    pass:u32,       // of the call they were counted in
    counted:bool,
    meshes,heightfields,shapes:int, // left; before they are counted, what the call gave back
    starved:bool,   // a chunk waits for room
    seen:u64,       // the version of Collider when it began to wait
}

// A chunk shows nothing yet and a viewer is within this share of its
// distance: the call that builds it waits for it.
@(private) URGENT_REACH :: f32(0.5)

@(private)
chunk_entity_matches :: proc(c:^Chunk_Tables,e,owner:core.Entity,coord:[3]i32,depth:u8) -> bool {
    if !core.alive(c.commands.entities,e) || core.has(c.ids,e) {return false}
    chunk,has_chunk:=core.get(c.chunks,e)
    parent,has_parent:=core.get(c.parents,e)
    return has_chunk && has_parent && core.has(c.locals,e) && chunk.owner==owner && chunk.coord==coord && chunk.depth==depth && parent.entity==owner
}

// Removes chunks that lost their owner or were changed by someone else; true
// when it ran: then the owners show every chunk again.
@(private)
terrain_chunks_prune :: proc(c:^Chunk_Tables,terrains:^core.Table(Terrain),resident:^Terrain_Resident) -> bool {
    stamps:=[6]u64{core.layout(c.locals),core.layout(c.parents),core.version(c.parents),c.chunks.layout,core.layout(c.ids),terrains.layout}
    if resident.gc_stamps==stamps {return false}
    resident.gc_stamps=stamps
    entities:=c.commands.entities
    for chunk,row in c.chunks.values[:core.count(c.chunks)] {
        e:=c.chunks.entities[row]
        if !core.alive(entities,e) {continue}
        if core.has(c.ids,e) {core.remove(c.chunks,e);continue}
        if !core.alive(entities,chunk.owner) || !core.has(terrains,chunk.owner) || !chunk_entity_matches(c,e,chunk.owner,chunk.coord,chunk.depth) {core.destroy(entities,e)}
    }
    return true
}

@(private)
collider_kind :: #force_inline proc "contextless" (kind:Source_Kind) -> phys.Collider_Kind {return kind==.Heightfield?.Heightfield:.Mesh}

@(private)
room_take :: proc(resident:^Terrain_Resident,c:^Chunk_Tables,physics:phys.Physics_Settings,kind:phys.Collider_Kind,count:int) -> bool {
    room:=&resident.room
    if room.pass!=resident.pass {room^={pass=resident.pass,starved=room.starved,seen=room.seen}}
    if !room.counted {
        made:=phys.settings_capacities(physics)
        heightfields,meshes,shapes:=int(made.heightfields),int(made.meshes),int(made.shapes)
        for collider in c.colliders.values[:core.count(c.colliders)] {
            #partial switch collider.kind {
            case .Heightfield: heightfields-=1
            case .Mesh: meshes-=1
            }
        }
        room.heightfields+=heightfields;room.meshes+=meshes;room.shapes+=shapes-core.count(c.colliders)
        room.counted=true
    }
    slots:=kind==.Heightfield?&room.heightfields:&room.meshes
    if slots^<count || room.shapes<count {return false}
    slots^-=count;room.shapes-=count
    return true
}

@(private)
room_give :: proc(resident:^Terrain_Resident,kind:phys.Collider_Kind,count:=1) {
    room:=&resident.room
    if room.pass!=resident.pass {room^={pass=resident.pass,starved=room.starved,seen=room.seen}}
    #partial switch kind {
    case .Heightfield: room.heightfields+=count
    case .Mesh: room.meshes+=count
    case: return
    }
    room.shapes+=count
}

@(private)
starved_report :: proc(problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id,coord:[3]i32,kind:phys.Collider_Kind,physics:phys.Physics_Settings) {
    name:[base.ASSET_ID_TEXT]u8
    field:=kind==.Heightfield?"heightfields":"meshes"
    core.report(problems,e,"terrain.collider_budget","chunk (%d, %d, %d) of terrain source %s shows its ground without collider: it needs a slot of Physics_Settings.%s or .shapes and none is left; raise them, or set Terrain_Settings.collision_distance",coord.x,coord.y,coord.z,host.assets_name(a,id,&name),field)
}

@(private)
resident_owner_remove :: proc(c:^Chunk_Tables,resident:^Terrain_Resident,index:int) {
    owner:=&resident.owners[index]
    for e in owner.chunks {
        chunk,known:=core.get(c.chunks,e)
        if !known || !chunk_entity_matches(c,e,owner.entity,chunk.coord,chunk.depth) {continue}
        if collider,has:=core.get(c.colliders,e);has {room_give(resident,collider.kind)}
        core.destroy(c.commands.entities,e)
    }
    // Its pieces go with it.
    for j:=len(resident.sources)-1;j>=0;j-=1 {
        if resident.sources[j].id!=owner.source || resident.sources[j].owner!=owner.entity {continue}
        resident_source_free(resident,&resident.sources[j])
        unordered_remove(&resident.sources,j)
    }
    resident_owner_free(owner)
    unordered_remove(&resident.owners,index)
    resident.cut=true
}

// Publishes what a job built for a chunk or a node. Its owners show it with
// their colliders as they show it (owner_chunk_show).
@(private)
chunk_take :: proc(c:^Chunk_Tables,resident:^Terrain_Resident,entry:^Data_Source,source:^Resident_Source,slot:^Work_Slot,physics:phys.Physics_Settings,problems:^core.Problems,terrains:core.Read(Terrain)) {
    index:=slot.index
    chunk:=&source.chunks[index]
    s:=&entry.source
    mesh,ok:=chunk_publish(resident.assets,s.kind,&slot.mesh,slot.key.collision,resident.picking)
    if !ok {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,source_owner(terrains,entry.id),"terrain.chunk_mesh","the mesh of piece %v (depth %d) of terrain source %s could not be made: out of memory for the mesh or its collision; free memory, or give the source fewer cells per chunk",quad_place(&entry.source,&source.quad,index),quad_depth(&source.quad,index),host.assets_name(resident.assets,entry.id,&name))
        source_pending(source,index)
        return
    }
    if chunk.mesh!={} {host.assets_mesh_release(resident.assets,chunk.mesh);resident.stats.released+=1;resident.stats.meshes-=1}
    if !chunk.shown {resident.cut=true}
    // A chunk that turns empty or stops being so gives or wants a collider (resident_colliders).
    if !chunk.shown || (chunk.mesh=={})!=(mesh=={}) {resident.marks+=1}
    chunk.mesh,chunk.revision,chunk.built,chunk.shown=mesh,slot.version,slot.key,true
    if mesh!={} {resident.stats.meshes+=1}
    append(&source.changed,u32(index))
    resident.stats.built+=1
}

// Lets go of the mesh of a piece no owner wants or shows.
@(private)
chunk_evict :: proc(resident:^Terrain_Resident,source:^Resident_Source,index:int) {
    chunk:=&source.chunks[index]
    if chunk.mesh!={} {host.assets_mesh_release(resident.assets,chunk.mesh);resident.stats.released+=1;resident.stats.meshes-=1}
    chunk.mesh,chunk.revision,chunk.built,chunk.shown={},0,{},false
    append(&source.changed,u32(index))
    source.leave=true
    resident.stats.evicted+=1
    resident.cut=true
}

// Takes what a slot holds: a chunk it built, or a page it read, if what it
// read did not change meanwhile.
@(private)
work_take :: proc(c:^Chunk_Tables,data:^Terrain_Data,resident:^Terrain_Resident,slot:^Work_Slot,physics:phys.Physics_Settings,problems:^core.Problems,terrains:core.Read(Terrain)) {
    defer work_release(slot)
    entry:=data_find(data,slot.id)
    fresh:=slot.epoch==data.epoch && entry!=nil && &entry.source==slot.source
    switch slot.kind {
    case .None:
    case .Build:
        source:=slot.epoch==data.epoch?resident_source_find(resident,slot.id,slot.owner):nil
        if source!=nil && slot.index<len(source.chunks) {source.chunks[slot.index].working=false}
        if !fresh || source==nil || slot.index>=len(source.chunks) {
            resident.stats.stale+=1
            if source!=nil && slot.index<len(source.dirty) {source_pending(source,slot.index)}
            return
        }
        chunk:=&source.chunks[slot.index]
        if !slot.ok {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,source_owner(terrains,entry.id),"terrain.chunk_build","piece %v (depth %d) of terrain source %s has no mesh: out of memory, or the source is damaged; free memory, or save the source again from the editor",quad_place(&entry.source,&source.quad,slot.index),quad_depth(&source.quad,slot.index),host.assets_name(resident.assets,entry.id,&name))
            source_pending(source,slot.index)
            return
        }
        if data_version(entry,slot.index)!=slot.version || chunk.wanted!=slot.key || !chunk.resident {
            resident.stats.stale+=1
            source_pending(source,slot.index)
            return
        }
        chunk_take(c,resident,entry,source,slot,physics,problems,terrains)
    case .Page:
        if !fresh {return}
        s:=&entry.source
        if !slot.ok {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,source_owner(terrains,entry.id),"terrain.page_unread","a page of terrain source %s could not be read from its file: it changed or is damaged; it is read again when the file is, or save the source again from the editor",host.assets_name(resident.assets,entry.id,&name))
            return
        }
        first,last:[3]int
        switch slot.grid {
        case .Heights,.Distances:
            g:=source_samples_grid(s)
            if !grid_absent(g,slot.index) || g.blocks[slot.index].hash!=slot.block.hash {return}
            _,count:=grid_page_extent(g,slot.index)
            grid_page_install(g,slot.index,transmute([]f32)slot.page[:count])
            data.samples+=u32(count)
            first,last=grid_page_region(g,slot.index)
        case .Weights:
            if !grid_absent(&s.weights,slot.index) || s.weights.blocks[slot.index].hash!=slot.block.hash {return}
            _,count:=grid_page_extent(&s.weights,slot.index)
            grid_page_install(&s.weights,slot.index,transmute([]Weights)slot.page[:count])
            // The weights of a Volume count against the budget as its distances (source_cost).
            if s.kind==.Volume {data.samples+=u32(count)}
            first,last=grid_page_region(&s.weights,slot.index)
        case .Holes:
            if !grid_absent(&s.holes,slot.index) || s.holes.blocks[slot.index].hash!=slot.block.hash {return}
            _,count:=grid_page_extent(&s.holes,slot.index)
            grid_page_install(&s.holes,slot.index,slot.page[:count])
            first,last=grid_page_region(&s.holes,slot.index)
        }
        slot.page=nil
        data.stats.pages_read+=1
        data_pages_arrived(entry,first,last)
        resident.marks+=1
    }
}

// Starts the reading of the pages of a source over a region that are in
// their blocks, as far as there are slots; true when it is under way.
@(private)
pages_start :: proc(data:^Terrain_Data,entry:^Data_Source,low,high:[3]int,phase:core.Phase,problems:^core.Problems,e:core.Entity,a:^host.Assets) {
    s:=&entry.source
    start :: proc(data:^Terrain_Data,entry:^Data_Source,g:^Grid($T),grid:Grid_Kind,low,high:[3]int,phase:core.Phase,problems:^core.Problems,e:core.Entity,a:^host.Assets) -> bool {
        if len(g.blocks)==0 {return true}
        from,to:=grid_pages(g,low,high)
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            i:=px+g.counts.x*(py+g.counts.y*pz)
            if !grid_absent(g,i) || work_reading(data,&entry.source,grid,i) {continue}
            if (grid==.Heights || grid==.Distances) && int(data.samples)+PAGE_VALUES>int(data.settings.samples) {
                name:[base.ASSET_ID_TEXT]u8
                core.report(problems,e,"terrain.budget","the pages of terrain source %s near its viewers need more samples than the %d of Terrain_Settings.samples; raise it, or lower Terrain_Settings.resident_distance",host.assets_name(a,entry.id,&name),data.settings.samples)
                return false
            }
            slot:=work_slot(data,false)
            if slot==nil || !work_page(data,slot,entry,grid,i,phase) {return false}
        }}}
        return true
    }
    if s.kind==.Volume {
        if start(data,entry,&s.distances,.Distances,low,high,phase,problems,e,a) {start(data,entry,&s.weights,.Weights,low,high,phase,problems,e,a)}
        return
    }
    if !start(data,entry,&s.heights,.Heights,low,high,phase,problems,e,a) {return}
    if !start(data,entry,&s.weights,.Weights,low,high,phase,problems,e,a) {return}
    start(data,entry,&s.holes,.Holes,low,high,phase,problems,e,a)
}

// Whether the pages of a region of samples are in memory: if not, a build
// that can wait starts reading them in jobs, and one that cannot reads them now.
@(private)
pages_ready :: proc(data:^Terrain_Data,resident:^Terrain_Resident,entry:^Data_Source,low,high:[3]int,urgent:bool,phase:core.Phase,problems:^core.Problems,terrains:core.Read(Terrain)) -> bool {
    s:=&entry.source
    if source_region_held(s,low,high) {return true}
    if !urgent {
        pages_start(data,entry,low,high,phase,problems,source_owner(terrains,entry.id),resident.assets)
        return false
    }
    before:=source_cost(s)
    read:=source_region_read(s,low,high,entry)
    data.samples=u32(int(data.samples)-before+source_cost(s))
    if !read {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,source_owner(terrains,entry.id),"terrain.page_unread","a page of terrain source %s could not be read from its file: it changed or is damaged; it is read again when the file is, or save the source again from the editor",host.assets_name(resident.assets,entry.id,&name))
    }
    return read
}

// Whether the samples a node of a Heightfield reads along the segments of
// its border below COARSE_LEVEL are in memory, as pages_ready.
@(private)
node_border_ready :: proc(data:^Terrain_Data,resident:^Terrain_Resident,entry:^Data_Source,index:int,border:^Piece_Border,urgent:bool,phase:core.Phase,problems:^core.Problems,terrains:core.Read(Terrain)) -> bool {
    s:=&entry.source
    if !source_paged(s) {return true}
    low,high:=quad_region(s,&entry.quad,index)
    cells:=int(s.chunk_cells)
    // What a segment and its ends read around them: their normals and the slope of the rules of layers.
    halo:=max(1<<COARSE_LEVEL,LAYER_RULE_SAMPLES)+1
    ready:=true
    for side in 0..<4 {for level,k in border.sides[side] {
        if level>=COARSE_LEVEL && border.corners[side][k]>=COARSE_LEVEL && border.corners[side][k+1]>=COARSE_LEVEL {continue}
        from,to:[2]int
        switch side {
        case 0,1:
            x:=side==0?low.x:high.x
            from,to={x,low.y+k*cells},{x,min(low.y+(k+1)*cells,high.y)}
        case 2,3:
            z:=side==2?low.y:high.y
            from,to={low.x+k*cells,z},{min(low.x+(k+1)*cells,high.x),z}
        }
        from,to=from-halo,to+halo
        if !pages_ready(data,resident,entry,{max(from.x,0),0,max(from.y,0)},{min(to.x,int(s.samples.x)-1),0,min(to.y,int(s.samples.z)-1)},urgent,phase,problems,terrains) {ready=false}
    }}
    return ready
}

// Starts the jobs of the pending pieces of a source: a build, or the reading
// of the pages it needs first; lets go of the pieces no owner wants or shows.
// urgent_left is set when a piece that cannot wait found no slot.
@(private)
terrain_schedule :: proc(data:^Terrain_Data,resident:^Terrain_Resident,entry:^Data_Source,source:^Resident_Source,phase:core.Phase,stream:bool,problems:^core.Problems,terrains:core.Read(Terrain),urgent_left:^bool) {
    s:=&entry.source
    q:=&source.quad
    chunks:=q.first[1]
    write:=0
    for index in source.pending {
        i:=int(index)
        chunk:=&source.chunks[i]
        keep:=false
        build: switch {
        case chunk.working: keep=true
        case !chunk.resident:
            if (chunk.shown || chunk.mesh!={}) && !chunk.visible {chunk_evict(resident,source,i)}
        case chunk.shown && chunk.revision==data_version(entry,i) && chunk.built==chunk.wanted:
        case:
            // A chunk near a viewer is wanted with its collider; a node where nothing shows, cheap from the coarse grid.
            urgent:=!chunk.shown && (chunk.urgent || i<chunks && (!stream || chunk.reach<=URGENT_REACH))
            border:^Piece_Border
            if i<chunks {
                if low,high,ok:=chunk_pages_region(s,i);ok && !pages_ready(data,resident,entry,low,high,urgent,phase,problems,terrains) {keep=true;break build}
            } else if s.kind==.Heightfield {
                border=&resident.border
                levels:=Border_Levels{counts=q.counts[0],levels=source.levels,deep=source.deep}
                a,b:=quad_chunks(q,i)
                piece_border(&levels,a,b,border)
                if !node_border_ready(data,resident,entry,i,border,urgent,phase,problems,terrains) {keep=true;break build}
            }
            slot:=work_slot(data,urgent)
            if slot==nil {
                keep=true
                if urgent {urgent_left^=true}
                break build
            }
            if !work_build(data,slot,entry,source.owner,i,chunk.wanted,urgent,phase,host.assets_limits(resident.assets),border,&source.join) {
                name:[base.ASSET_ID_TEXT]u8
                core.report(problems,source.owner,"terrain.memory","out of memory for the border of a piece of terrain source %s; it is built in a later frame: free memory, or make the source smaller",host.assets_name(resident.assets,entry.id,&name))
                keep=true
                break build
            }
            chunk.working=true
        }
        if keep {source.pending[write]=index;write+=1} else {source.dirty[index]=false}
    }
    base.truncate(&source.pending,write)
}

// Lets go of the pages of a paged source that no resident chunk reads, once
// no job reads the source.
@(private)
pages_leave :: proc(data:^Terrain_Data,resident:^Terrain_Resident,entry:^Data_Source) {
    s:=&entry.source
    // The pages of a source are those the pieces of every terrain that shows it read.
    source:^Resident_Source
    leave:=false
    for &each in resident.sources {
        if each.id!=entry.id {continue}
        if source==nil {source=&each}
        leave||=each.leave
    }
    if source==nil || !leave || !source_paged(s) || work_busy(data,s) {return}
    for &each in resident.sources {if each.id==entry.id {each.leave=false}}
    if len(source.pages)!=len(source_samples_grid(s).pages) {
        delete(source.pages)
        pages,error:=make([]bool,len(source_samples_grid(s).pages),resident.assets.allocator)
        if error!=nil {return}
        source.pages=pages
    }
    for &value in source.pages {value=false}
    for &each in resident.sources {
        if each.id!=entry.id {continue}
        for chunk,index in each.chunks[:each.quad.first[1]] {if chunk.resident || chunk.working {chunk_pages_mark(s,index,source.pages)}}
    }
    before:=source_cost(s)
    data.stats.pages_left+=u64(source_pages_leave(s,source.pages))
    data.samples=u32(int(data.samples)-before+source_cost(s))
}

// The layers of a source as each chunk shows them, made again when its layers
// or the assets change.
@(private)
resident_layers_override :: proc(resident:^Terrain_Resident,source:^Resident_Source,s:^Source) -> render.Material_Override {
    a:=resident.assets
    stamp:=[2]u64{a.revision,a.structure}
    if source.override_info.layer_count!=s.layer_count || source.override_info.layers!=s.layers || source.override_assets!=stamp {
        source.override=layers_override(a,s)
        source.override_info.layer_count,source.override_info.layers,source.override_assets=s.layer_count,s.layers,stamp
    }
    return source.override
}

// Shows the pieces of a source for an owner: every one when its appearance,
// its count or the chunk tables changed; otherwise only those published or
// let go since the last call, and those it began or stopped showing.
@(private)
owner_publish :: proc(c:^Chunk_Tables,resident:^Terrain_Resident,owner:^Resident_Owner,entry:^Data_Source,source:^Resident_Source,marker:Terrain,physics:phys.Physics_Settings,problems:^core.Problems,seen:bool) {
    tint:=owner.tint
    if !seen || owner.full {
        tint=render.TINT_DEFAULT
        if value,ok:=core.get(c.tints,owner.entity);ok {tint=value}
    }
    // A program of its own reads its parameters from its material.
    override:=entry.source.layers_material=={}?resident_layers_override(resident,source,&entry.source):{}
    materials:=chunk_materials(&entry.source)
    solid:=marker.solid && !owner.far
    appearance:=materials!=owner.materials || tint!=owner.tint || override!=owner.override || solid!=owner.solid
    full:=owner.full || appearance
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    owner.materials=materials
    owner.tint=tint
    owner.override=override
    owner.solid=solid
    owner.full=false
    if full {
        for index in 0..<len(source.chunks) {owner_chunk_show(c,resident,owner,entry,source,index,appearance,physics,problems)}
    } else {
        for index in source.changed {owner_chunk_show(c,resident,owner,entry,source,int(index),false,physics,problems)}
        for index in owner.changed {owner_chunk_show(c,resident,owner,entry,source,int(index),false,physics,problems)}
    }
    clear(&owner.changed)
}

@(private)
owner_chunk_show :: proc(c:^Chunk_Tables,resident:^Terrain_Resident,owner:^Resident_Owner,entry:^Data_Source,source:^Resident_Source,index:int,appearance:bool,physics:phys.Physics_Settings,problems:^core.Problems) {
    chunk:=&source.chunks[index]
    node:=&owner.nodes[index]
    if node.pass==resident.pass {return}
    node.pass=resident.pass
    s:=&entry.source
    q:=&source.quad
    depth:=u8(quad_depth(q,index))
    coord:=quad_place(s,q,index)
    e:=owner.chunks[index]
    if !node.visible || !chunk.shown {
        if e==core.NONE {return}
        if chunk_entity_matches(c,e,owner.entity,coord,depth) {
            if collider,has:=core.get(c.colliders,e);has {room_give(resident,collider.kind)}
            core.destroy(c.commands.entities,e)
        }
        owner.chunks[index]=core.NONE
        return
    }
    created:=false
    // Its entity stands where its mesh is relative to (chunk_place); one of a
    // piece at another place, of another size of the source, goes.
    place:=core.TRANSFORM_IDENTITY
    place.position=chunk_origin(s,coord)
    placed :: proc(c:^Chunk_Tables,e:core.Entity,place:core.Transform) -> bool {
        local,has:=core.get(c.locals,e)
        return has && local==place
    }
    if chunk_entity_matches(c,e,owner.entity,coord,depth) && !placed(c,e,place) {
        if collider,has:=core.get(c.colliders,e);has {room_give(resident,collider.kind)}
        core.destroy(c.commands.entities,e)
    }
    if !chunk_entity_matches(c,e,owner.entity,coord,depth) {
        e=core.NONE
        for existing,row in c.chunks.values[:core.count(c.chunks)] {
            candidate:=c.chunks.entities[row]
            if existing.owner==owner.entity && existing.coord==coord && existing.depth==depth && chunk_entity_matches(c,candidate,owner.entity,coord,depth) && placed(c,candidate,place) {e=candidate;break}
        }
        if e==core.NONE {
            e=core.commands_create(c.commands)
            core.commands_add(c.commands,e,place)
            core.commands_add(c.commands,e,core.Parent{entity=owner.entity})
        }
        owner.chunks[index]=e
        created=true
    }
    kind:=collider_kind(s.kind)
    wants:=owner.solid && chunk.built.collision && node.collide && chunk.mesh!={}
    old,has_old:=core.get(c.chunks,e)
    held,_:=core.get(c.meshes,e)
    collider,has:=core.get(c.colliders,e)
    joined:=depth==0 && chunk.built.join!=0
    if has_old && old.revision==chunk.revision && old.lod==chunk.built.lod && old.joined==joined && held.mesh==chunk.mesh && (has && collider.kind==kind)==wants && !appearance && !created {resident.stats.reused+=1;return}
    core.add(c.chunks,e,Terrain_Chunk{owner.entity,coord,chunk.revision,chunk.built.lod,depth,joined})
    if chunk.mesh=={} {
        if core.has(c.meshes,e) {core.remove(c.meshes,e)}
        if has {core.remove(c.colliders,e);room_give(resident,collider.kind)}
        return
    }
    if wants && (!has || collider.kind!=kind) {
        if !room_take(resident,c,physics,kind,1) {
            // Its ground shows without it; it is tried again when the colliders change.
            wants=false
            resident.room.starved=true
            resident.stats.starved+=1
            starved_report(problems,owner.entity,resident.assets,entry.id,coord,kind,physics)
        } else if has {room_give(resident,collider.kind)}
    }
    core.add(c.meshes,e,render.Mesh_Renderer{mesh=chunk.mesh,materials=owner.materials})
    core.add(c.tints,e,owner.tint)
    if !render.material_override_empty(&owner.override) {core.add(c.overrides,e,owner.override)} else if core.has(c.overrides,e) {core.remove(c.overrides,e)}
    if wants {core.add(c.colliders,e,s.kind==.Heightfield?phys.collider_heightfield():phys.collider_mesh())} else if has {core.remove(c.colliders,e);room_give(resident,collider.kind)}
}

// The loaded source of the terrain a request names; without it the request is a problem of that entity.
// The terrain a request edits and its brush as its source reads it: what an
// edit keys on from here on, also on the network.
@(private)
edit_resolve :: proc(request:Edit_Request,data:^Terrain_Data,terrains:core.Read(Terrain),worlds:core.Read(core.World_Transform)) -> (resolved:Edit_Request,ok:bool) {
    owner:=request.owner
    if owner==core.NONE {owner=dig_owner(request.brush,data,terrains,worlds) or_return}
    return {owner,brush_local(request.brush,edit_place(worlds,owner))},true
}

@(private)
edit_place :: proc(worlds:core.Read(core.World_Transform),owner:core.Entity) -> mm.Transform {
    if world,found:=core.get(worlds,owner);found {return world.transform}
    return mm.TRANSFORM_IDENTITY
}

// The terrain a brush of the world touches: of several, the nearest to its
// center, then the one of the smallest footprint (a Volume over the ground it
// joins). A Heightfield reaches any height.
@(private)
dig_owner :: proc(brush:Brush,data:^Terrain_Data,terrains:core.Read(Terrain),worlds:core.Read(core.World_Transform)) -> (owner:core.Entity,ok:bool) {
    best,smallest:=max(f32),max(f32)
    for marker,row in terrains.table.values[:core.count(terrains)] {
        entry:=data_find(data,marker.source)
        if entry==nil {continue}
        e:=core.entity_at(terrains,row)
        local:=brush_local(brush,edit_place(worlds,e))
        s:=&entry.source
        low:=source_origin(s)
        high:=low+[3]f32{f32(s.samples.x-1),f32(s.samples.y-1),f32(s.samples.z-1)}*s.cell
        if s.kind==.Mesh {
            low,high=max(f32),min(f32)
            for chunk in s.mesh_chunks {
                for axis in 0..<3 {low[axis],high[axis]=min(low[axis],chunk.low[axis]),max(high[axis],chunk.high[axis])}
            }
        }
        outside:=linalg.max(low-local.center,local.center-high,[3]f32{})
        if s.kind==.Heightfield {outside.y=0}
        distance:=linalg.length(outside)
        reach:=max(local.radius,linalg.length(local.extent))
        area:=(high.x-low.x)*(high.z-low.z)
        if !(distance<=reach) || distance>best || distance==best && area>=smallest {continue}
        owner,ok,best,smallest=e,true,distance,area
    }
    return
}

@(private)
request_source :: proc(data:^Terrain_Data,terrains:core.Read(Terrain),owner:core.Entity,request:string,problems:^core.Problems,a:^host.Assets) -> (entry:^Data_Source,ok:bool) {
    marker,known:=core.get(terrains,owner)
    if !known {
        core.report(problems,owner,"terrain.request_owner","%s of a terrain named this entity, which has no Terrain; name the entity of the terrain",request)
        return
    }
    if marker.source=={} {
        core.report(problems,owner,"terrain.no_source","%s of this terrain was refused: Terrain.source is empty; set it to a .terrain of the assets",request)
        return
    }
    entry=data_find(data,marker.source)
    if entry==nil {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,owner,"terrain.not_loaded","%s of this terrain was refused: its source %s is not loaded; another problem of this entity says why",request,host.assets_name(a,marker.source,&name))
        return
    }
    return entry,true
}

@(private)
edit_report :: proc(problems:^core.Problems,owner:core.Entity,a:^host.Assets,entry:^Data_Source,brush:Brush,error:Edit_Error) {
    name:[base.ASSET_ID_TEXT]u8
    source:=host.assets_name(a,entry.id,&name)
    switch error {
    case .None:
    case .Invalid:
        core.report(problems,owner,"terrain.edit_invalid","a %v brush cannot edit %s, a %v source, or a value of it is not finite; heightfields take Raise, Lower, Smooth and Flatten; volumes Add, Remove, Smooth, Flatten and Grow; meshes Raise, Lower, Smooth, Flatten, Refine, Grow, Union and Subtract",brush.kind,source,entry.source.kind)
    case .Not_Closed:
        core.report(problems,owner,"terrain.edit_not_closed","a %v of mesh source %s was refused: the mesh is not closed, so it has no inside to add to or cut; close its holes in the modeling tool, or use a sculpt brush",brush.kind,source)
    case .Topology:
        core.report(problems,owner,"terrain.edit_topology","a %v of mesh source %s was refused: the result would not be a valid surface; use a smaller radius, or another place",brush.kind,source)
    case .Budget:
        core.report(problems,owner,"terrain.edit_budget","a %v of source %s was refused: the result would pass the triangles of a mesh source or the samples of Terrain_Settings; raise Terrain_Settings.samples, or use a smaller brush",brush.kind,source)
    case .Out_Of_Memory:
        core.report(problems,owner,"terrain.memory","a %v of source %s ran out of memory and changed nothing; free memory, or use a smaller brush",brush.kind,source)
    }
}

// Changes the layers of a source as a request of request_layer asks.
// Invalid when its layers do not allow it; Out_Of_Memory, applied or not.
@(private)
data_layer :: proc(data:^Terrain_Data,entry:^Data_Source,change:Layer_Change) -> (applied:bool,error:Edit_Error) {
    s:=&entry.source
    work_wait(data,s)
    previous_cost:=source_cost(s)
    // Taking a layer away rewrites every weight.
    read:=!change.remove || source_weights_read_all(s)
    data.samples=u32(int(data.samples)-previous_cost+source_cost(s))
    if !read {return false,.Out_Of_Memory}
    if !(change.remove?source_layer_remove(s,int(change.index)):source_layer_set(s,int(change.index),change.layer)) {return false,.Invalid}
    source_pages_edited(s)
    data_mark_all(entry)
    data.stats.edits+=1
    return true,source_coarse_weights(s)?.None:.Out_Of_Memory
}

@(private)
layer_report :: proc(problems:^core.Problems,owner:core.Entity,a:^host.Assets,entry:^Data_Source,change:Layer_Change,error:Edit_Error) {
    name:[base.ASSET_ID_TEXT]u8
    #partial switch error {
    case .Invalid:
        core.report(problems,owner,"terrain.layer_invalid","layer %d of terrain source %s was not changed: a source has from 1 to %d layers, added one after another, with a tiling above zero and up to 10000 m, a height blend from 0 to 1 and ordered ranges, and keeps its last one; name an existing layer, or the next one to add it",change.index,host.assets_name(a,entry.id,&name),LAYERS_MAX)
    case .Out_Of_Memory:
        source_memory(problems,owner,a,entry.id)
    }
}

// The pages of a paged source a brush reads and writes, into memory: an edit
// is applied in its tick wherever it is.
@(private)
brush_pages_read :: proc(entry:^Data_Source,brush:Brush) -> bool {
    s:=&entry.source
    if !source_paged(s) {return true}
    for value in ([?]f32{brush.center.x,brush.center.y,brush.center.z,brush.radius,brush.delta.x,brush.delta.y,brush.delta.z}) {if !distance_finite(value) {return true}}
    origin:=source_origin(s)
    reach:=max(brush.radius,0)/s.cell+3
    if s.kind==.Volume {reach+=SDF_BAND_CELLS}
    limit:=f32(HEIGHT_SAMPLES_MAX)
    low,high:[3]int
    for axis in 0..<3 {
        if s.kind==.Heightfield && axis==1 {continue}
        center:=(brush.center[axis]-origin[axis])/s.cell
        end:=center+(brush.kind==.Grow?brush.delta[axis]/s.cell:0)
        low[axis],high[axis]=int(clamp(min(center,end)-reach,-1,limit)),int(clamp(max(center,end)+reach,-1,limit))
        if high[axis]<0 {return true}
    }
    return source_region_read(s,low,high,entry)
}

@(step="fixed frame",loops="game editor",stage="simulate",before="physics_prepare")
terrain_update :: proc(
    commands:core.Commands,terrains:^core.Table(Terrain),chunks:^core.Table(Terrain_Chunk),
    locals:core.Read(core.Transform),parents:core.Read(core.Parent),ids:core.Read(core.Id),colliders:^core.Table(phys.Collider),
    meshes:^core.Table(render.Mesh_Renderer),tints:^core.Table(render.Tint),overrides:^core.Table(render.Material_Override),
    data:^Terrain_Data,resident:^Terrain_Resident,requests:^Terrain_Requests,digs:^Terrain_Digs,settings:Terrain_Settings,app:^host.App,time:core.Time,frame:core.Frame_Time,
    view:core.View,worlds:core.Read(core.World_Transform),sources:core.Ref(scene.Streaming_Sources),kept:core.Read(scene.Far_Kept),physics:phys.Physics_Settings,
    loads:core.Ref(scene.Section_Loads),waits:^scene.Load_Waits,problems:^core.Problems,focus:Terrain_Focus,
) {
    c:=Chunk_Tables{commands,chunks,locals,parents,ids,colliders,meshes,tints,overrides}
    if resident==nil || app.assets==nil {return}
    if !data_ready(data,settings,app.allocator) || !work_ready(data,&app.jobs,app.allocator) {
        core.report(problems,core.NONE,"terrain.memory","out of memory for the list of %d terrain sources of Terrain_Settings.sources; no terrain shows until it fits: free memory, or lower it",max(settings.sources,1))
        return
    }
    data.settings.resident_distance=settings.resident_distance
    if !resident.ready || resident.epoch!=data.epoch {
        sources,source_error:=make([dynamic]Resident_Source,0,int(data.settings.sources),app.allocator)
        owners,owner_error:=make([dynamic]Resident_Owner,0,int(data.settings.sources),app.allocator)
        if source_error!=nil || owner_error!=nil {
            delete(sources);delete(owners)
            core.report(problems,core.NONE,"terrain.memory","out of memory for the meshes of %d terrain sources (Terrain_Settings.sources); no terrain shows until it fits: free memory, or lower it",data.settings.sources)
            return
        }
        stats:=resident.stats
        terrain_resident_free(resident)
        stats.meshes=0
        resident.assets,resident.epoch,resident.ready,resident.stats=app.assets,data.epoch,true,stats
        resident.sources,resident.owners=sources,owners
    }
    resident.pass+=1
    resident.picking=!time.playing
    // What the jobs of the calls before made shows before the sources change again.
    for &slot in data.work {if work_due(data,&slot,frame.phase) {work_take(&c,data,resident,&slot,physics,problems,core.read(terrains))}}
    // A source is read again when its file changes, on disk or in the memory
    // of the registry; the revision of an owner is the key of the history of
    // its editor.
    if data.registry!=app.assets.registry.revision {
        data.registry=app.assets.registry.revision
        clear(&data.unread)
        for &entry in data.entries {
            if terrain_stamp(app.assets,entry.id)==entry.stamp {continue}
            work_wait(data,&entry.source)
            data_reload(data,&entry,app.assets,problems,core.read(terrains))
        }
    }
    // What the jobs read joins the sources; what the loads of sections name is
    // read in jobs, and they wait for it (scene.Load_Waits): a section joins
    // with its sources.
    for i:=len(data.loads)-1;i>=0;i-=1 {
        if i<len(data.loads) && !jobs.pending(&data.loads[i].counter) {data_load_end(data,data.loads[i],app.assets,problems,terrains)}
    }
    named:=make([dynamic]base.Asset_Id,context.temp_allocator)
    scene.loads_waiting(loads.ptr,&named)
    for id in named {
        if data_find(data,id)!=nil || slice.contains(data.unread[:],id) {continue}
        record,found:=asset.registry_find(&app.assets.registry,id)
        if !found || record.kind!=KIND {continue}
        if data_load_begin(data,app.assets,id)!=nil {scene.load_wait(waits,id)} else {data_load(data,app.assets,id,problems,core.NONE)}
    }
    for marker,row in terrains.values[:core.count(terrains)] {
        if marker.source=={} {continue}
        entry:=data_find(data,marker.source)
        loaded:=entry==nil
        // A terrain that no load waited for (the scene that opens, one the editor adds) has its source in this call.
        if loaded && slice.contains(data.unread[:],marker.source) {continue}
        if loaded {
            if load:=data_load_begin(data,app.assets,marker.source);load!=nil {
                entry=data_load_end(data,load,app.assets,problems,terrains)
            } else {entry=data_load(data,app.assets,marker.source,problems,terrains.entities[row])}
        }
        if entry==nil {continue}
        if loaded {
            for shared,index in terrains.values[:core.count(terrains)] {if shared.source==marker.source && shared.revision!=entry.source.revision {core.edit_at(terrains,index).revision=entry.source.revision}}
            continue
        }
        if entry.source.revision!=marker.revision {
            rebound:=marker.revision==0
            if !rebound {
                e:=terrains.entities[row]
                for owner in resident.owners {if owner.entity==e && owner.source!=marker.source {rebound=true;break}}
            }
            if rebound {core.edit_at(terrains,row).revision=entry.source.revision}
        }
    }
    if !time.playing || frame.phase==.Fixed {
        for asked_edit in core.take(&requests.edits) {
            request:=edit_resolve(asked_edit,data,core.read(terrains),worlds) or_continue
            entry:=request_source(data,core.read(terrains),request.owner,"an edit",problems,app.assets) or_continue
            change:=data_edit(data,entry,request.brush)
            if change.error!=.None {
                edit_report(problems,request.owner,app.assets,entry,request.brush,change.error)
                continue
            }
            if !change.changed {continue}
            if time.playing {dig_push(digs,request.owner,entry,worlds)}
            entry.source.revision+=1
            for value,row in terrains.values[:core.count(terrains)] {if value.source==entry.id {core.edit_at(terrains,row).revision=entry.source.revision}}
        }
        for request in core.take(&requests.layers) {
            entry:=request_source(data,core.read(terrains),request.owner,"a layer change",problems,app.assets) or_continue
            applied,error:=data_layer(data,entry,request.change)
            layer_report(problems,request.owner,app.assets,entry,request.change,error)
            if !applied {continue}
            entry.source.revision+=1
            for value,row in terrains.values[:core.count(terrains)] {if value.source==entry.id {core.edit_at(terrains,row).revision=entry.source.revision}}
        }
    }
    full:=terrain_chunks_prune(&c,terrains,resident)
    // Chunks shown without their collider try again once the colliders change.
    if resident.room.starved && core.version(c.colliders)!=resident.room.seen {
        resident.room.starved=false
        full=true
    }
    for i:=len(resident.owners)-1;i>=0;i-=1 {
        owner:=&resident.owners[i]
        marker,known:=core.get(terrains,owner.entity)
        entry:=data_find(data,marker.source)
        if known && (marker.source!=owner.source || entry!=nil && (owner.quad!=entry.quad || len(owner.chunks)!=quad_total(&entry.quad))) {resident_owner_remove(&c,resident,i)}
    }
    // The terrains that show each source and their pieces, before they choose what they want of it.
    for marker,row in terrains.values[:core.count(terrains)] {
        entry:=data_find(data,marker.source)
        e:=terrains.entities[row]
        if entry==nil || resident_source(resident,entry,e,problems)==nil {continue}
        if owner:=resident_owner(resident,e,entry,problems);owner!=nil {owner.pass=resident.pass}
    }
    // Where pieces go and what shows: in the first call of a frame. The call
    // of the frame phase after a tick has nothing new to choose from.
    first:=resident.called!=app.stats.frames+1
    resident.called=app.stats.frames+1
    if first || frame.phase==.Fixed {
        // What changed in the data is chosen for in this call; pieces that wait to be built, once a frame.
        changed:=false
        for &entry in data.entries {changed||=len(entry.pending)>0}
        data_pending_spread(data,resident)
        // What stands for a section that is not loaded collides with nothing.
        for &owner in resident.owners {owner.far=kept.table!=nil && core.has(kept,owner.entity)}
        resident_joins(resident,data,core.read(terrains),ids,worlds,locals,problems)
        resident_lod(resident,data,worlds,view,sources,settings,core.read(terrains),&c,physics,problems,changed || first,focus)
        resident_cut(resident,data)
        stream:=settings.resident_distance>0
        // A piece that is wanted where nothing shows is built in this call.
        for round:=0;;round+=1 {
            urgent_left:=false
            data_pending_spread(data,resident)
            for &source in resident.sources {if entry:=data_find(data,source.id);entry!=nil {terrain_schedule(data,resident,entry,&source,frame.phase,stream,problems,core.read(terrains),&urgent_left)}}
            took:=false
            for &slot in data.work {
                if slot.kind==.None {continue}
                // A build that became urgent while it ran is taken now too.
                if !slot.urgent {
                    source:=slot.kind==.Build && slot.epoch==data.epoch?resident_source_find(resident,slot.id,slot.owner):nil
                    if source==nil || slot.index>=len(source.chunks) || !source.chunks[slot.index].urgent {continue}
                }
                if jobs.pending(&slot.counter) {jobs.wait(data.jobs,jobs.OWNER,&slot.counter)}
                work_take(&c,data,resident,&slot,physics,problems,core.read(terrains))
                took=true
            }
            resident_cut(resident,data)
            // Each round may open one more node over a chunk near a viewer (owner_cut).
            if !took || round>QUAD_DEPTH_MAX {break}
        }
        for &entry in data.entries {pages_leave(data,resident,&entry)}
        seen:=[3]u64{core.version(terrains),core.version(c.tints),core.version(c.overrides)}==resident.shown
        for marker,row in terrains.values[:core.count(terrains)] {
            entry:=data_find(data,marker.source)
            if entry==nil {continue}
            source:=resident_source_find(resident,marker.source,terrains.entities[row])
            if source==nil {continue}
            owner:=resident_owner(resident,terrains.entities[row],entry,problems)
            if owner==nil {continue}
            if full {owner.full=true}
            owner_publish(&c,resident,owner,entry,source,marker,physics,problems,seen)
        }
        for &source in resident.sources {clear(&source.changed)}
        for i:=len(resident.owners)-1;i>=0;i-=1 {
            owner:=&resident.owners[i]
            if owner.pass==resident.pass {continue}
            resident_owner_remove(&c,resident,i)
        }
    }
    for &request in core.take(&requests.saves) {
        entry:=request_source(data,core.read(terrains),request.owner,"a save",problems,app.assets) or_continue
        work_wait(data,&entry.source)
        path:=base.text_get(request.path[:])
        own,_:=terrain_file(app.assets,entry.id)
        if path=="" {path=own}
        name:[base.ASSET_ID_TEXT]u8
        if path=="" {
            core.report(problems,request.owner,"terrain.save_path","terrain source %s was not saved: it has no file in the assets and the request named none; pass the path to write",host.assets_name(app.assets,entry.id,&name))
        } else if error:=source_save(&entry.source,path,entry.id,&app.assets.types,path==own);error!=.None {
            core.report(problems,request.owner,"terrain.save","terrain source %s was not saved to %s: %v; %s",host.assets_name(app.assets,entry.id,&name),path,error,error==.Invalid?"a value of the source is not finite or is out of range: edit it again before saving":"check that the folder exists and the file can be written")
        } else {
            data.stats.saves+=1
        }
    }
    for i:=len(data.entries)-1;i>=0;i-=1 {
        entry:=&data.entries[i]
        used:=false
        for marker in terrains.values[:core.count(terrains)] {if marker.source==entry.id {used=true;break}}
        // A source a load waits for stays until its section joins.
        if used || slice.contains(named[:],entry.id) {continue}
        // Every job waits: removing the entry moves the last one, whose results are taken first.
        work_wait(data,nil)
        last:=&data.entries[len(data.entries)-1].source
        for &slot in data.work {
            if slot.kind==.None {continue}
            if slot.source==&entry.source {work_release(&slot)} else if slot.source==last {work_take(&c,data,resident,&slot,physics,problems,core.read(terrains))}
        }
        for j:=len(resident.sources)-1;j>=0;j-=1 {
            if resident.sources[j].id!=entry.id {continue}
            resident_source_free(resident,&resident.sources[j])
            unordered_remove(&resident.sources,j)
        }
        data.samples-=u32(source_cost(&entry.source))
        data_entry_free(entry)
        unordered_remove(&data.entries,i)
    }
    resident.shown={core.version(terrains),core.version(c.tints),core.version(c.overrides)}
    if resident.room.starved {resident.room.seen=core.version(c.colliders)}
    host.assets_commit(app.assets)
}

// The terrain e that shows the source of entry; made the first time, with room
// for what it shows and for its nodes in the order of the budget.
@(private)
resident_owner :: proc(resident:^Terrain_Resident,e:core.Entity,entry:^Data_Source,problems:^core.Problems) -> ^Resident_Owner {
    for &owner in resident.owners {if owner.entity==e && owner.source==entry.id {return &owner}}
    allocator:=resident.assets.allocator
    count:=quad_total(&entry.quad)
    owner:=Resident_Owner{entity=e,source=entry.id,quad=entry.quad,full=true}
    e0,e1,e2:runtime.Allocator_Error
    owner.chunks,e0=make([]core.Entity,count,allocator)
    owner.nodes,e1=make([]Owner_Node,count,allocator)
    owner.changed,e2=make([dynamic]u32,0,2*count,allocator)
    room:=count
    for &other in resident.owners {room+=len(other.nodes)}
    if e0!=nil || e1!=nil || e2!=nil || reserve(&resident.splits,room)!=nil || append(&resident.owners,owner)!=1 {
        resident_owner_free(&owner)
        source_memory(problems,e,resident.assets,entry.id)
        return nil
    }
    resident.cut=true
    return &resident.owners[len(resident.owners)-1]
}
