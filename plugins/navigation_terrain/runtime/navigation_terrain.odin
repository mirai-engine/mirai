package navigation_terrain

import "core:math/linalg"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"
import terrain "plugins:terrain/runtime"

// Where the collision of the terrains is not loaded, for navigation: the
// chunks of each solid terrain shown by an owner that have no collider now
// (not resident, beyond Terrain_Settings.collision_distance, waiting for a
// slot or for their first build), in runs along x, as boxes of the world.
// A chunk shown empty has nothing to load. Navigation keeps its tiles there
// until they load (nav.Nav_Unloaded). Made again when the chunks, the
// colliders, the terrains, their places or their sources change.

// The versions the boxes were made from; per world, as the boxes.
@(storage,host,by_world)
Navigation_Terrain :: struct {stamps:[5]u64}

@(step="fixed",loops="game editor",stage="react",server)
navigation_terrain_unloaded :: proc(
    state:^Navigation_Terrain,unloaded:^nav.Nav_Unloaded,resident:core.Ref(terrain.Terrain_Resident),data:core.Ref(terrain.Terrain_Data),
    terrains:core.Read(terrain.Terrain),colliders:core.Read(phys.Collider),worlds:core.Read(core.World_Transform),
) {
    if resident.ptr==nil || data.ptr==nil {return}
    stamps:=[5]u64{core.version(colliders),core.version(terrains),core.version(worlds),terrain.terrain_data_change(data),u64(len(resident.owners))}
    for &source in resident.sources {for chunk in source.chunks {stamps[4]=stamps[4]*31+u64(chunk.shown)}}
    if stamps==state.stamps {return}
    state.stamps=stamps
    before:=len(unloaded.boxes)
    hash:=base.hash64(transmute([]u8)unloaded.boxes[:],0) if before>0 else 0
    clear(&unloaded.boxes)
    for &owner in resident.owners {
        if !owner.solid {continue}
        s:=terrain.terrain_source(data,owner.source)
        shown:^terrain.Resident_Source
        for &source in resident.sources {if source.id==owner.source && source.owner==owner.entity {shown=&source;break}}
        world,placed:=core.get(worlds,owner.entity)
        if s==nil || shown==nil || !placed || len(owner.chunks)!=len(shown.chunks) {continue}
        unloaded_runs(&unloaded.boxes,s,shown,&owner,colliders,world.transform)
    }
    if len(unloaded.boxes)!=before || before>0 && base.hash64(transmute([]u8)unloaded.boxes[:],0)!=hash {unloaded.revision+=1}
}

// The runs along x of the chunks of an owner whose collision is not loaded.
unloaded_runs :: proc(out:^[dynamic]mm.Aabb,s:^terrain.Source,shown:^terrain.Resident_Source,owner:^terrain.Resident_Owner,colliders:core.Read(phys.Collider),placed:mm.Transform) {
    n:=terrain.chunk_counts(s)
    origin:=terrain.source_origin(s)
    m:=mm.transform_matrix(placed)
    loaded :: proc(shown:^terrain.Resident_Source,owner:^terrain.Resident_Owner,colliders:core.Read(phys.Collider),i:int) -> bool {
        if owner.chunks[i]!=core.NONE && core.has(colliders,owner.chunks[i]) {return true}
        return shown.chunks[i].shown && shown.chunks[i].mesh=={}
    }
    for z in 0..<n.z {
        for y in 0..<n.y {
            for x:=0;x<n.x; {
                i:=terrain.chunk_index(s,{i32(x),i32(y),i32(z)})
                if loaded(shown,owner,colliders,i) {x+=1;continue}
                for x<n.x && !loaded(shown,owner,colliders,terrain.chunk_index(s,{i32(x),i32(y),i32(z)})) {x+=1}
                // A heightfield chunk reaches every height its ground may take.
                low,_:=terrain.chunk_box(s,origin,i,{-1e4,1e4})
                _,high:=terrain.chunk_box(s,origin,terrain.chunk_index(s,{i32(x-1),i32(y),i32(z)}),{-1e4,1e4})
                box:=mm.AABB_EMPTY
                for k in 0..<8 {
                    corner:=[3]f32{high.x if k&1!=0 else low.x,high.y if k&2!=0 else low.y,high.z if k&4!=0 else low.z}
                    box=mm.aabb_add_point(box,(m*[4]f32{corner.x,corner.y,corner.z,1}).xyz)
                }
                if linalg.is_nan(box.min.x) {continue}
                append(out,box)
            }
        }
    }
}
