package pcg_editor

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import "mirai:editor"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"

// Before the history records an edit of the scene, the cells it moved under
// each Pcg_Graph ask for their ground again, fine and first: those under a
// Volume, a Spline or a Pcg_Zone that came, went or moved, under the ground
// a Terrain (or any ground) announced changed, and those of a graph whose
// Volume moved. What they place follows their new ground and zones in the
// next frames; nothing of it enters the step, which is derived.

FOLLOW_REQUESTS :: 256 // cells an edit asks again at most: Pcg_Settings.ground_requests

@(storage)
Pcg_Follow :: struct {provider:editor.Edit_Follow_Provider}
PCG_FOLLOW_DEFAULT :: Pcg_Follow{provider={follow=pcg_follow}}

// Where a Volume or a Spline was at the last follow.
Zone_Seen :: struct {
    entity:core.Entity,
    stamp:u64,
    box:mm.Aabb,
}

@(private)
pcg_follow :: proc(s:^editor.Session) {
    t:=tool_of(s)
    if t==nil {return}
    w:=editor.edited_world(s)
    graphs:=core.world_table_of(w,pcg.Pcg_Graph)
    if graphs==nil || core.count(graphs)==0 {return}
    changes:=follow_changes(t,w)
    if queries:=core.world_storage_of(w,core.Ground_Queries);queries!=nil {append(&changes,..queries.changed.items[:])}
    if len(changes)==0 {return}
    follow_ask(w,changes[:])
}

// The boxes of the world that changed since the last follow: where each
// Volume, Spline or Pcg_Zone was and is, for those that came, went or moved.
follow_changes :: proc(t:^Pcg_Tool,w:core.World_Ref) -> (changes:[dynamic]mm.Aabb) {
    changes=make([dynamic]mm.Aabb,context.temp_allocator)
    at:=where_of(w)
    now:=make([dynamic]Zone_Seen,context.temp_allocator)
    add :: proc(now:^[dynamic]Zone_Seen,at:volume.Where,e:core.Entity) {
        for seen in now {if seen.entity==e {return}}
        has_volume:=at.volumes!=nil && core.has(at.volumes,e)
        spline:volume.Spline
        has_spline:=false
        if at.splines!=nil {spline,has_spline=core.get(at.splines,e)}
        if !has_volume && !has_spline {return}
        v,pose,outline,placed:=volume.placed(at,e)
        if !placed {return}
        Fixed :: struct {v:volume.Volume,pose:mm.Transform}
        fixed:=Fixed{v,pose}
        stamp:=base.hash64(([^]byte)(&fixed)[:size_of(fixed)])
        stamp=base.hash64(([^]byte)(raw_data(outline))[:len(outline)*size_of(mm.Path_Point)],stamp)
        box:mm.Aabb
        if has_volume {
            box=volume.bounds(v,pose,outline)
            if v.shape==.Unbounded || v.shape==.Plane {box={{-pcg.POSITION_MAX,-pcg.POSITION_MAX,-pcg.POSITION_MAX},{pcg.POSITION_MAX,pcg.POSITION_MAX,pcg.POSITION_MAX}}}
        }
        if has_spline {
            world,ok:=core.get(at.worlds,e)
            if !ok {return}
            points:=volume.spline_points(&spline)
            stamp=base.hash64(([^]byte)(raw_data(points))[:len(points)*size_of(mm.Path_Point)],stamp)
            stamp=base.hash64(([^]byte)(&world.transform)[:size_of(world.transform)],stamp)
            if reach,reached:=volume.spline_reach(&spline,world.transform);reached {
                box=reach if !has_volume else {linalg.min(box.min,reach.min),linalg.max(box.max,reach.max)}
            }
        }
        append(now,Zone_Seen{e,stamp,box})
    }
    if zones:=core.world_table_of(w,pcg.Pcg_Zone);zones!=nil {for row in 0..<core.count(zones) {add(&now,at,core.entity_at(zones,row))}}
    if graphs:=core.world_table_of(w,pcg.Pcg_Graph);graphs!=nil && at.volumes!=nil {
        for row in 0..<core.count(graphs) {if e:=core.entity_at(graphs,row);core.has(at.volumes,e) {add(&now,at,e)}}
    }
    for seen in now {
        before:=-1
        for old,i in t.seen {if old.entity==seen.entity {before=i;break}}
        if before<0 {append(&changes,seen.box);continue}
        if t.seen[before].stamp!=seen.stamp {append(&changes,t.seen[before].box,seen.box)}
    }
    for old in t.seen {
        gone:=true
        for seen in now {if seen.entity==old.entity {gone=false;break}}
        if gone {append(&changes,old.box)}
    }
    // The first follow only learns where they are.
    first:=len(t.seen)==0
    clear(&t.seen)
    append(&t.seen,..now[:])
    if first {clear(&changes)}
    return
}

// Asks the ground of the cells of every graph that a box of the world
// reaches, FOLLOW_REQUESTS at most, the nearest a box first.
follow_ask :: proc(w:core.World_Ref,changes:[]mm.Aabb) {
    graphs:=core.world_table_of(w,pcg.Pcg_Graph)
    grounds:=core.world_storage_of(w,pcg.Pcg_Ground)
    requests:=core.world_storage_of(w,pcg.Pcg_Ground_Requests)
    data:=core.world_storage_of(w,pcg.Pcg_Data)
    places:=core.world_table_of(w,core.World_Transform)
    if graphs==nil || grounds==nil || requests==nil || data==nil || places==nil {return}
    Asked :: struct {e:core.Entity,coord:[2]i32}
    asked:=make([dynamic]Asked,context.temp_allocator)
    for row in 0..<core.count(graphs) {
        e:=core.entity_at(graphs,row)
        graph:=core.at(graphs,row)
        owner:=pcg.ground_owner(grounds,e)
        entry:=pcg.data_find(data,graph.source)
        place,placed:=core.get(places,e)
        if owner==nil || entry==nil || !placed {continue}
        frame_world:=mm.transform_matrix(pcg.graph_frame(graph,place.transform))
        cell:=entry.source.info.cell_size
        for want in owner.cells {
            corner:=pcg.cell_corner(cell,want.coord)
            column:=mm.aabb_transform({{corner.x,-pcg.POSITION_MAX,corner.z},{corner.x+cell,pcg.POSITION_MAX,corner.z+cell}},frame_world)
            for change in changes {if mm.aabb_overlaps(change,column) {append(&asked,Asked{e,want.coord});break}}
        }
    }
    if len(asked)>FOLLOW_REQUESTS {
        // The nearest the middle of the changes keep their place.
        middle:=(changes[0].min+changes[0].max)*0.5
        Keyed :: struct {asked:Asked,d:f32}
        keyed:=make([]Keyed,len(asked),context.temp_allocator)
        for a,i in asked {
            graph,_:=core.get(graphs,a.e)
            entry:=pcg.data_find(data,graph.source)
            place,_:=core.get(places,a.e)
            corner:=pcg.cell_corner(entry.source.info.cell_size,a.coord)
            p:=mm.transform_point(pcg.graph_frame(graph,place.transform),corner)
            keyed[i]={a,(p.x-middle.x)*(p.x-middle.x)+(p.z-middle.z)*(p.z-middle.z)}
        }
        slice.sort_by(keyed,proc(a,b:Keyed) -> bool {return a.d<b.d})
        for k,i in keyed[:FOLLOW_REQUESTS] {asked[i]=k.asked}
        resize(&asked,FOLLOW_REQUESTS)
    }
    for a in asked {pcg.ground_request(requests,a.e,a.coord)}
}

// The tables of a world where its volumes are.
where_of :: proc(w:core.World_Ref) -> volume.Where {
    at:volume.Where
    if t:=core.world_table_of(w,volume.Volume);t!=nil {at.volumes=core.read(t)}
    if t:=core.world_table_of(w,core.World_Transform);t!=nil {at.worlds=core.read(t)}
    if t:=core.world_table_of(w,core.Parent);t!=nil {at.parents=core.read(t)}
    if t:=core.world_table_of(w,volume.Spline);t!=nil {at.splines=core.read(t)}
    return at
}
