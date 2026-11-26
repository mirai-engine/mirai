package terrain

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"

// What stands on a Heightfield reads the color of its ground from the renderer
// (render.ground_chunk_set, mirai_ground_color in the material programs): each
// chunk shown, with the instance that draws it, the square of the world it
// covers and a revision of what it shows, its build with its maps and the
// values its entity gives its materials. A node of the quadtree, a chunk of a
// Volume and a terrain turned or scaled unevenly keep none: what reads the
// color there takes its fallback. The renderer keeps so many chunks at once:
// the nearest to the view take the place of the farthest. The chunks are given
// again when the rows of the chunks, the values of an entity, the place of a
// terrain or the instances of the renderer change, or the view moves on by
// GROUND_VIEW_STEP; a frame without those does nothing.

GROUND_VIEW_STEP :: f32(8) // metres

@(storage,host)
Terrain_Ground_Color :: struct {
    shown:[render.GROUND_CHUNKS_MAX][2]f32, // where each chunk the renderer keeps starts, along x and z
    count:int,
    world:core.World_Id,
    given:[4]u64,
}

@(step="render",loops="game editor",after="render_sync")
terrain_ground_color :: proc(
    g:^Terrain_Ground_Color,data:core.Ref(Terrain_Data),terrains:^core.Table(Terrain,.Read),chunks:^core.Table(Terrain_Chunk,.Read),worlds:^core.Table(core.World_Transform,.Read),
    looks:^core.Table(render.Material_Values,.Read),meshes:^core.Table(render.Mesh_Renderer,.Read),synced:core.Ref(render.Render_Sync),renderer:^render.Renderer,view:core.View,
) {
    if renderer==nil || synced.ptr==nil || data.ptr==nil {return}
    sync:=synced.ptr
    stood:=[2]i32{i32(math.floor(view.position.x/GROUND_VIEW_STEP)),i32(math.floor(view.position.z/GROUND_VIEW_STEP))}
    given:=[4]u64{core.version(chunks)+core.layout(chunks),core.version(looks)+core.layout(looks),render.instance_revision(renderer)+u64(render.instance_count(renderer)),base.hash64(mem.ptr_to_bytes(&stood))}
    for row in 0..<core.count(terrains) {
        if world,placed:=core.get(worlds,core.entity_at(terrains,row));placed {given[3]+=base.hash64(mem.ptr_to_bytes(&world.transform))}
    }
    if sync.world!=g.world {g.world,g.count,g.given=sync.world,0,{}}
    if given==g.given {return}
    g.given=given
    // From the middle of the chunk that starts at low to the view, along x and z.
    away :: proc(low:[2]f32,size:f32,view:core.View) -> f32 {return linalg.length(low+size/2-[2]f32{view.position.x,view.position.z})}
    Wanted :: struct {using chunk:render.Ground_Chunk,away:f32}
    wanted:=make([dynamic]Wanted,context.temp_allocator)
    for row in 0..<core.count(chunks) {
        chunk:=core.at(chunks,row)
        e:=core.entity_at(chunks,row)
        marker,found:=core.get(terrains,chunk.owner)
        entry:=found?data_find(data.ptr,marker.source):nil
        world,placed:=core.get(worlds,e)
        look,_:=core.get(looks,e)
        mesh,drawn:=core.get(meshes,e)
        index:=render.instance_of(sync,e)
        if chunk.depth!=0 || entry==nil || entry.source.kind!=.Heightfield || !placed || !drawn || index<0 {continue}
        if abs(world.rotation.w)<0.99999 || world.scale.x!=world.scale.z {continue}
        revision:=base.hash64(mem.ptr_to_bytes(&look),base.hash64(mem.ptr_to_bytes(&mesh.materials),u64(chunk.revision)))
        size:=f32(entry.source.chunk_cells)*entry.source.cell*world.scale.x
        low:=[2]f32{world.position.x,world.position.z}
        append(&wanted,Wanted{{instance=u32(index),low=low,size=size,revision=revision},away(low,size,view)})
    }
    slice.sort_by(wanted[:],proc(a,b:Wanted) -> bool {return a.away<b.away})
    for i:=g.count-1;i>=0;i-=1 {
        kept:=false
        for chunk in wanted {kept||=chunk.low==g.shown[i]}
        if !kept {ground_color_drop(g,renderer,i)}
    }
    for chunk in wanted {
        held:=false
        for low in g.shown[:g.count] {held||=low==chunk.low}
        taken:=render.ground_chunk_set(renderer,g.world,chunk.chunk)
        if !taken && !held {
            // No slot is left: it takes that of the farthest chunk kept, when that one is clearly farther.
            farthest:=-1
            for low,i in g.shown[:g.count] {if farthest<0 || away(low,chunk.size,view)>away(g.shown[farthest],chunk.size,view) {farthest=i}}
            if farthest<0 || away(g.shown[farthest],chunk.size,view)<chunk.away+chunk.size/4 {break}
            ground_color_drop(g,renderer,farthest)
            taken=render.ground_chunk_set(renderer,g.world,chunk.chunk)
        }
        if taken && !held && g.count<len(g.shown) {g.shown[g.count]=chunk.low;g.count+=1}
    }
}

@(private)
ground_color_drop :: proc(g:^Terrain_Ground_Color,renderer:^render.Renderer,i:int) {
    render.ground_chunk_remove(renderer,g.world,g.shown[i])
    g.count-=1
    g.shown[i]=g.shown[g.count]
}
