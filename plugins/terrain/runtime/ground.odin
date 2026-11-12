package terrain

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The ground of the terrains of a world, for core.Ground_Queries: the probe
// reads the terrains as they are placed, and terrain_update pushes where each
// terrain comes, goes, moves, shows another source, its chunks change (an
// edit, a page that comes) or a stroke of the editor is held, and where its
// collision loads or goes. Far from every viewer, where the pages of a
// source are not in memory, a Heightfield answers from its coarse grid and a
// Volume answers Unloaded until the page that comes announces its chunks.
// Another epoch of Terrain_Data (a copy of the world, a swap, a scene loaded)
// starts its views anew, and with them every terrain is announced: they point
// into the sources of the Terrain_Data they were made from, so a copy or a
// swap of the world does not move them.
@(storage,copy=false)
Terrain_Ground :: struct {
    views:[dynamic]Ground_View,
    spacing:f32,
    seen:[3]core.Seen,    // of Terrain, World_Transform and Collider
    data:u64,             // terrain_data_change when it last looked
    marks:u64,            // Terrain_Resident.marks when the unloaded boxes were last made
    stroke:Terrain_Focus, // the stroke held, its center and radius left out; zero: none
    unloaded:[dynamic]mm.Aabb,
}

// A terrain as the probe reads it.
Ground_View :: struct {
    entity:core.Entity,
    id:base.Asset_Id,
    source:^Source,
    transform:mm.Transform,
    to_local,to_world:mm.Mat4,
    low,high:[3]f32, // of the source, in its space
    change:u32,      // of the source when it was last looked at
}

@(private)
ground_open :: proc(w:core.World_Ref) -> (core.Ground_Query,bool) {
    g:=core.world_storage_of(w,Terrain_Ground)
    if g==nil {return {},false}
    return {user=g,probe=ground_probe,spacing=g.spacing,unloaded=g.unloaded[:]},true
}

// What the ground of the world is now, at the end of terrain_update, and
// where it changed.
@(private)
ground_update :: proc(g:^Terrain_Ground,resident:^Terrain_Resident,data:^Terrain_Data,terrains:^core.Table(Terrain,$A),colliders:^core.Table(phys.Collider),worlds:^core.Table(core.World_Transform,.Read),focus:Terrain_Focus,queries:^core.Ground_Queries) {
    // A terrain that came, went or moved: the transforms of the rest do not count.
    placed:=core.touched(terrains,&g.seen[0])
    moved:=core.changes(worlds,&g.seen[1])
    for e in moved.gone {placed||=core.has(terrains,e)}
    for row:=0;!placed && moved.written && row<core.count(terrains);row+=1 {
        at:=core.row_of(worlds,core.entity_at(terrains,row))
        placed=at>=0 && core.changed(worlds,moved,at)
    }
    change:=terrain_data_change({data})
    edited:=change!=g.data
    // Another epoch: the sources the views point at went, and every terrain is announced.
    if change>>32!=g.data>>32 {clear(&g.views);clear(&g.unloaded)}
    g.data=change
    if placed || edited {
        views:=make([dynamic]Ground_View,0,len(g.views),context.temp_allocator)
        g.spacing=0
        for row in 0..<core.count(terrains) {
            e:=core.entity_at(terrains,row)
            id:=core.at(terrains,row).source
            entry:=data_find(data,id)
            world,placed:=core.get(worlds,e)
            if entry==nil || !placed || !source_valid(entry.source.info) {continue}
            to_local,inverted:=mm.transform_inverse_matrix(world.transform)
            if !inverted {continue}
            s:=&entry.source
            low,high:=source_box(s,{},s.field.size-1)
            append(&views,Ground_View{e,id,s,world.transform,to_local,mm.transform_matrix(world.transform),low,high,entry.change})
            spacing:=s.cell*max(abs(world.transform.scale.x),abs(world.transform.scale.z))
            if g.spacing==0 || spacing<g.spacing {g.spacing=spacing}
        }
        // A terrain that comes, goes, moves or shows another source: all it covered and covers.
        same :: proc(a,b:Ground_View) -> bool {return a.entity==b.entity && a.id==b.id && a.transform==b.transform}
        for &old in g.views {
            kept:=false
            for now in views {kept||=same(old,now)}
            if !kept {ground_change(&queries.changed,&old,old.low,old.high)}
        }
        for &now in views {
            old:^Ground_View
            for &seen in g.views {if same(seen,now) {old=&seen;break}}
            if old==nil {ground_change(&queries.changed,&now,now.low,now.high);continue}
            if old.change==now.change {continue}
            // The cells around the chunks that changed: the normals of the samples next to them change too.
            if low,high,changed:=terrain_changed({data},now.id,old.change);changed {ground_change(&queries.changed,&now,low-now.source.cell,high+now.source.cell)}
        }
        clear(&g.views)
        append(&g.views,..views[:])
    }
    stroke:=focus.stroke?focus:{}
    stroke.center,stroke.radius={},0
    if stroke!=g.stroke {
        for &view in g.views {
            for held in ([2]Terrain_Focus{g.stroke,stroke}) {
                if held.stroke && held.source==view.id {ground_change(&queries.changed,&view,{held.low.x,-HEIGHT_LIMIT,held.low.y},{held.high.x,HEIGHT_LIMIT,held.high.y})}
            }
        }
        g.stroke=stroke
    }
    if placed | edited | core.touched(colliders,&g.seen[2]) | (resident.marks!=g.marks) {
        g.marks=resident.marks
        ground_unloaded(g,resident,data,colliders,worlds,&queries.unloaded)
    }
}

// A box of the space of a view that changed.
@(private)
ground_change :: proc(changed:^core.Events(mm.Aabb),view:^Ground_View,low,high:[3]f32) {
    core.push(changed,mm.aabb_transform({low,high},view.to_world))
}

@(private)
ground_probe :: proc(user:rawptr,origin,down:[3]f32,coarse:bool) -> (best:core.Ground_Hit,found:core.Ground_Found) {
    g:=cast(^Terrain_Ground)user
    up:=-linalg.normalize0(down)
    if up=={} || linalg.is_nan(up.x) || !(abs(origin.x)<max(f32) && abs(origin.y)<max(f32) && abs(origin.z)<max(f32)) {return}
    top:f32
    for &view in g.views {
        hit,state:=view_probe(g,&view,origin,-up,coarse)
        if state==.Ground {
            height:=linalg.dot(hit.point,up)
            if found!=.Ground || height>top {best,found,top=hit,.Ground,height}
        } else if found==.None || found==.Empty && state==.Unloaded {found=state}
    }
    return
}

// The ground of one terrain along the line, from above it.
@(private)
view_probe :: proc(g:^Terrain_Ground,view:^Ground_View,origin,down:[3]f32,coarse:bool) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
    s:=view.source
    o:=mm.mat4_point(view.to_local,origin)
    d:=linalg.normalize0((view.to_local*[4]f32{down.x,down.y,down.z,0}).xyz)
    near,far:=-max(f32),max(f32)
    for axis in 0..<3 {
        if abs(d[axis])<1e-6 {
            if !(o[axis]>=view.low[axis] && o[axis]<=view.high[axis]) {return}
            continue
        }
        a,b:=(view.low[axis]-o[axis])/d[axis],(view.high[axis]-o[axis])/d[axis]
        near,far=max(near,min(a,b)),min(far,max(a,b))
    }
    if !(near<=far) {return}
    origin_s:=source_origin(s)
    middle:=(o+d*((near+far)*0.5)-origin_s)/s.cell
    c,r:=clamp(int(middle.x),0,int(s.samples.x)-2),clamp(int(middle.z),0,int(s.samples.z)-2)
    if g.stroke.stroke && g.stroke.source==view.id && middle.x*s.cell+origin_s.x>=g.stroke.low.x && middle.x*s.cell+origin_s.x<=g.stroke.high.x && middle.z*s.cell+origin_s.z>=g.stroke.low.y && middle.z*s.cell+origin_s.z<=g.stroke.high.y {return {},.Empty}
    local,normal:[3]f32
    weights:Weights
    if s.kind==.Heightfield && d.y< -0.9999 {
        // Straight down a Heightfield: from its coarse grid when asked or where its pages are not in memory.
        held:=!coarse && cell_held(s,c,r)
        if held && source_hole(s,c,r) {return {},.Empty}
        if held {
            local={o.x,source_height(s,o.x,o.z),o.z}
            normal=heightfield_normal(s,int(middle.x+0.5),int(middle.z+0.5),1)
            weights=shown_weights(s,local,normal)
        } else {
            height,coarse_normal,shown,known:=source_coarse_at(s,o.x,o.z)
            if !known {return {},.Empty}
            local,normal,weights={o.x,height,o.z},coarse_normal,weights_quantize(shown,int(s.layer_count))
        }
    } else {
        ok:bool
        local,normal,ok=source_ray(s,o+d*(near-s.cell),d)
        if !ok {
            held:=source_region_held(s,{c,0,r},{c+1,int(s.samples.y)-1,r+1})
            return {},held?.Empty:.Unloaded
        }
        normal=linalg.normalize0(normal)
        if linalg.dot(normal,d)>0 {normal=-normal}
        weights=shown_weights(s,local,normal)
    }
    hit.point=mm.mat4_point(view.to_world,local)
    hit.normal=linalg.normalize0((view.to_world*[4]f32{normal.x,normal.y,normal.z,0}).xyz)
    hit.weights=weights
    for i in 0..<min(int(s.layer_count),LAYERS_MAX) {hit.layers[i]=s.layers[i].material}
    return hit,.Ground
}

// The weights of the layers a source shows at a point of its surface, in its
// space: those painted with its automatic layers over them, at the slope and
// height there. A Heightfield as its chunks show it: over the triangle of its
// cell, from the weights of its samples, each with the rule at the slope and
// the height of its own.
shown_weights :: proc "contextless" (s:^Source,local,normal:[3]f32) -> Weights {
    count:=int(s.layer_count)
    if s.kind!=.Heightfield {
        return weights_quantize(layers_vertex(s,source_weights_at(s,local),normal,local.y),count)
    }
    at :: proc "contextless" (s:^Source,x,z:int) -> [4]f32 {
        p:=source_point(s,{x,0,z})
        return layers_vertex(s,source_weights_at(s,p),heightfield_normal(s,x,z,LAYER_RULE_SAMPLES),p.y)
    }
    origin:=source_origin(s)
    column,row:=clamp((local.x-origin.x)/s.cell,0,f32(s.samples.x-1)),clamp((local.z-origin.z)/s.cell,0,f32(s.samples.z-1))
    c,r:=min(int(column),int(s.samples.x)-2),min(int(row),int(s.samples.z)-2)
    u,v:=column-f32(c),row-f32(r)
    a,b,d:=at(s,c,r),at(s,c+1,r),at(s,c,r+1)
    w:=a+(b-a)*u+(d-a)*v
    if u+v>1 {e:=at(s,c+1,r+1);w=e+(d-e)*(1-u)+(b-e)*(1-v)}
    return weights_quantize(w,count)
}

// Where the collision of the terrains is not loaded, for navigation: the
// chunks of each solid terrain shown by an owner that have no collider now
// (not resident, beyond Terrain_Settings.collision_distance, waiting for a
// slot or for their first build), in runs along x, as boxes of the world. A
// chunk shown empty has nothing to load. Made again when the colliders, the
// terrains, their places or their sources change, or an owner or a chunk
// comes, goes or turns empty or not (Terrain_Resident.marks); where it
// changed is pushed.
@(private)
ground_unloaded :: proc(g:^Terrain_Ground,resident:^Terrain_Resident,data:^Terrain_Data,colliders:^core.Table(phys.Collider),worlds:^core.Table(core.World_Transform,.Read),unloaded:^core.Events(mm.Aabb)) {
    before:=slice.clone(g.unloaded[:],context.temp_allocator)
    clear(&g.unloaded)
    for &owner in resident.owners {
        if !owner.solid {continue}
        entry:=data_find(data,owner.source)
        shown:=resident_source_find(resident,owner.source,owner.entity)
        world,placed:=core.get(worlds,owner.entity)
        if entry==nil || shown==nil || !placed || len(owner.chunks)!=len(shown.chunks) {continue}
        unloaded_runs(&g.unloaded,&entry.source,shown,&owner,colliders,world.transform)
    }
    if slice.equal(before,g.unloaded[:]) {return}
    box:=mm.AABB_EMPTY
    for boxes in ([2][]mm.Aabb{before,g.unloaded[:]}) {for b in boxes {box=mm.aabb_merge(box,b)}}
    core.push(unloaded,box)
}

// The runs along x of the chunks of an owner whose collision is not loaded.
@(private)
unloaded_runs :: proc(out:^[dynamic]mm.Aabb,s:^Source,shown:^Resident_Source,owner:^Resident_Owner,colliders:^core.Table(phys.Collider),placed:mm.Transform) {
    n:=chunk_counts(s)
    origin:=source_origin(s)
    m:=mm.transform_matrix(placed)
    loaded :: proc(shown:^Resident_Source,owner:^Resident_Owner,colliders:^core.Table(phys.Collider),i:int) -> bool {
        if owner.chunks[i]!=core.NONE && core.staged_has(colliders,owner.chunks[i]) {return true}
        return shown.chunks[i].shown && shown.chunks[i].mesh=={}
    }
    for z in 0..<n.z {
        for y in 0..<n.y {
            for x:=0;x<n.x; {
                if loaded(shown,owner,colliders,chunk_index(s,{i32(x),i32(y),i32(z)})) {x+=1;continue}
                first:=x
                for x<n.x && !loaded(shown,owner,colliders,chunk_index(s,{i32(x),i32(y),i32(z)})) {x+=1}
                // A heightfield chunk reaches every height its ground may take.
                low,_:=chunk_box(s,origin,chunk_index(s,{i32(first),i32(y),i32(z)}),{-1e4,1e4})
                _,high:=chunk_box(s,origin,chunk_index(s,{i32(x-1),i32(y),i32(z)}),{-1e4,1e4})
                box:=mm.aabb_transform({low,high},m)
                if linalg.is_nan(box.min.x) {continue}
                append(out,box)
            }
        }
    }
}
