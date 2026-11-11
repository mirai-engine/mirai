package terrain

import "core:math"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// A Volume whose Terrain.ground names a Heightfield terrain joins it: the
// Volume owns its box. The pieces of the Heightfield leave the cells under
// the box as holes (cuts), drawn, collided and picked, and in a band of
// JOIN_BAND samples inside the sides of the box the Volume reads the heights
// as distance, blended toward its own field inward: on its sides its
// surface runs along the edges of the Heightfield between the same samples.
// The Volume stands on the samples of the Heightfield (same cell, rotation
// and scale, its samples over those of the Heightfield along x and z), and
// its chunks on the sides of the box are at level 0, as the holed chunks
// of the Heightfield are. Where one of them is resident as a chunk, the
// chunks of the other over the same cells are too.

JOIN_BAND :: 4          // samples inside each side of the box over which the Volume goes from the ground to its own field
JOIN_SNAP :: f32(1e-3)  // of a cell: how far from a sample of the Heightfield a sample of the Volume may stand

// What the pieces of a terrain build from its joins.
Terrain_Join :: struct {
    ground:base.Asset_Id,   // Volume: the source of the Heightfield it joins; none: it joins none
    entity:core.Entity,     // Volume: the terrain of that Heightfield
    offset:[2]int,          // Volume: the sample of the Heightfield under its sample 0, along x and z
    lift:f32,               // Volume: the height of its sample 0 in the space of the Heightfield
    cuts:[dynamic]Join_Cut, // Heightfield: the cells Volumes take
    hash:u64,               // of what its pieces build from: they build again when it changes
    seen:u64,               // hash as the last call left it
}
// Cells of a Heightfield, high exclusive.
Join_Cut :: struct {low,high:[2]int}

// What a build reads of the joins of its terrain.
Chunk_Join :: struct {
    ground:^Source, // Volume: the Heightfield it joins, read live
    offset:[2]int,
    lift:f32,
    cuts:[]Join_Cut, // Heightfield
}

// Whether a cell of a Heightfield is a hole: of the source, or one a Volume takes.
cell_hole :: #force_inline proc "contextless" (s:^Source,cuts:[]Join_Cut,x,z:int) -> bool {
    if source_hole(s,x,z) {return true}
    for cut in cuts {if x>=cut.low.x && x<cut.high.x && z>=cut.low.y && z<cut.high.y {return true}}
    return false
}

// The cuts over the cells of a chunk of a Heightfield, as a key: 0 for none.
join_cut_key :: proc "contextless" (s:^Source,cuts:[]Join_Cut,index:int) -> u64 {
    if len(cuts)==0 {return 0}
    low,high,valid:=chunk_region(s,chunk_coord(s,index))
    if !valid {return 0}
    key:=u64(0)
    for cut in cuts {
        if cut.high.x<=low.x || cut.low.x>=high.x || cut.high.y<=low.z || cut.low.y>=high.z {continue}
        key=base.hash_mix(base.hash_mix(base.hash_mix(base.hash_mix(key|1,u64(cut.low.x)),u64(cut.low.y)),u64(cut.high.x)),u64(cut.high.y))
    }
    return key
}

// Whether a chunk of a joined Volume touches a side of its box.
join_side_chunk :: proc "contextless" (s:^Source,index:int) -> bool {
    low,high,valid:=chunk_region(s,chunk_coord(s,index))
    return valid && (low.x==0 || low.z==0 || high.x>=int(s.samples.x)-1 || high.z>=int(s.samples.z)-1)
}

// Whether the samples a chunk of a joined Volume reads at a level reach the band.
join_band_chunk :: proc "contextless" (s:^Source,index:int,level:u8) -> bool {
    low,high,valid:=chunk_region(s,chunk_coord(s,index))
    if !valid {return false}
    reach:=JOIN_BAND+max(1<<uint(level),2)
    return low.x<reach || low.z<reach || high.x>int(s.samples.x)-1-reach || high.z>int(s.samples.z)-1-reach
}

// The height of a sample of a Heightfield: from its page, or from the coarse
// grid while the page is in its block.
join_height :: proc "contextless" (g:^Source,x,z:int) -> f32 {
    x,z:=clamp(x,0,int(g.samples.x)-1),clamp(z,0,int(g.samples.z)-1)
    if grid_absent(&g.field,x/PAGE+g.field.counts.x*(z/PAGE)) {
        if !grid_none(&g.coarse.heights) {return coarse_height(g,x,z)}
    }
    return grid_get(&g.field,x,z)
}

// The distance of a sample of a Volume to the ground of the Heightfield it
// joins: its height over the ground, within the band.
join_ground_distance :: proc "contextless" (s:^Source,join:Chunk_Join,p:[3]int) -> f32 {
    g:=join.ground
    x,z:=join.offset.x+p.x,join.offset.y+p.z
    h:=join_height(g,x,z)
    band:=s.cell*SDF_BAND_CELLS
    // Along y, not the normal: linear between samples, so on the sides of the
    // box the surface runs on the edges of the Heightfield.
    return clamp(join.lift+f32(p.y)*s.cell-h,-band,band)
}

// Blends the samples of a window of a Volume that lie in the band of its
// sides toward the ground: the ground alone on the sides.
join_blend :: proc "contextless" (s:^Source,join:Chunk_Join,samples:[]f32,first,extent:[3]int) {
    n:=[2]int{int(s.samples.x),int(s.samples.z)}
    at:=0
    for z in first.z..<first.z+extent.z {for y in first.y..<first.y+extent.y {for x in first.x..<first.x+extent.x {
        defer at+=1
        side:=min(x,z,n.x-1-x,n.y-1-z)
        if side>=JOIN_BAND {continue}
        t:=f32(side)/JOIN_BAND
        w:=t*t*(3-2*t)
        ground:=join_ground_distance(s,join,{x,y,z})
        samples[at]=ground+(samples[at]-ground)*w
    }}}
}

// Fills a Volume with the ground of a Heightfield it joins: what a joined
// Volume starts from, to dig into.
source_volume_ground :: proc(s:^Source,join:Chunk_Join) -> bool {
    if s.kind!=.Volume || join.ground==nil || join.ground.kind!=.Heightfield {return false}
    Ground :: struct {s:^Source,join:Chunk_Join}
    page :: proc(user:rawptr,first,extent:[3]int,values:[]f32) -> (fill:f32,uniform:bool) {
        g:=(^Ground)(user)
        for z in 0..<extent.z {for y in 0..<extent.y {for x in 0..<extent.x {
            values[x+extent.x*(y+extent.y*z)]=join_ground_distance(g.s,g.join,first+{x,y,z})
        }}}
        return
    }
    ground:=Ground{s,join}
    next:Grid(f32)
    if !grid_init(&next,s.field.size,s.cell*SDF_BAND_CELLS,s.allocator) {return false}
    if !grid_generate(&next,&ground,page,s.allocator) {grid_destroy(&next,s.allocator);return false}
    grid_destroy(&s.field,s.allocator)
    s.field=next
    return true
}

// Resolves the joins of the terrains that show sources: the Heightfield
// each joined Volume stands on and the cuts of the pieces of that
// Heightfield. A join that changes marks the levels to be chosen again.
@(private)
resident_joins :: proc(resident:^Terrain_Resident,data:^Terrain_Data,terrains:^core.Table(Terrain,$A),ids:^core.Table(core.Id,$B),worlds:^core.Table(core.World_Transform,$C),locals:^core.Table(core.Transform,$D),problems:^core.Problems) {
    // An entity without a World_Transform is a root: its Transform is where it is.
    place :: proc(worlds:^core.Table(core.World_Transform,$A),locals:^core.Table(core.Transform,$B),e:core.Entity) -> (mm.Transform,bool) {
        if world,found:=core.get(worlds,e);found {return world.transform,true}
        local,found:=core.get(locals,e)
        return mm.Transform(local),found
    }
    for &source in resident.sources {source.join.seen=source.join.hash;clear(&source.join.cuts)}
    for &source in resident.sources {
        join:=&source.join
        marker,known:=core.get(terrains,source.owner)
        entry:=data_find(data,source.id)
        join.ground,join.entity={},core.NONE
        if !known || marker.ground==0 || entry==nil || entry.source.kind!=.Volume {continue}
        v:=&entry.source
        name:[base.ASSET_ID_TEXT]u8
        g:=core.NONE
        for row in 0..<core.count(terrains) {
            e:=core.entity_at(terrains,row)
            if core.id_of(ids,e)==marker.ground {g=e;break}
        }
        ground,found:=core.get(terrains,g)
        ground_entry:=found?data_find(data,ground.source):nil
        if ground_entry==nil || ground_entry.source.kind!=.Heightfield {
            if g==core.NONE || ground_entry!=nil {core.report(problems,source.owner,"terrain.ground_invalid","Terrain.ground of this Volume names %v, which is no Heightfield terrain of the world; name the Id of a Heightfield terrain, or 0 to join none",marker.ground)}
            continue
        }
        h:=&ground_entry.source
        vw,placed:=place(worlds,locals,source.owner)
        gw,ground_placed:=place(worlds,locals,g)
        if !placed || !ground_placed {continue}
        relative,ok:=mm.transform_relative(vw,gw)
        turned:=1-abs(relative.rotation.w)>1e-6
        scaled:=abs(relative.scale.x-1)>1e-4 || abs(relative.scale.y-1)>1e-4 || abs(relative.scale.z-1)>1e-4
        if !ok || turned || scaled || v.cell!=h.cell {
            core.report(problems,source.owner,"terrain.ground_misaligned","this Volume (cell %v m) cannot join the Heightfield of %s (cell %v m): it needs the same cell, and no rotation or scale of its own against it; give it the cell of the Heightfield and the rotation and scale of its terrain",v.cell,host.assets_name(resident.assets,ground.source,&name),h.cell)
            continue
        }
        corner:=mm.transform_point(relative,source_point(v,{}))-source_origin(h)
        column,row:=corner.x/h.cell,corner.z/h.cell
        offset:=[2]int{int(math.round(column)),int(math.round(row))}
        if abs(column-f32(offset.x))>JOIN_SNAP || abs(row-f32(offset.y))>JOIN_SNAP {
            core.report(problems,source.owner,"terrain.ground_misaligned","the samples of this Volume fall between those of the Heightfield it joins; move it %.4f m along x and %.4f m along z",(f32(offset.x)-column)*h.cell,(f32(offset.y)-row)*h.cell)
            continue
        }
        far:=offset+[2]int{int(v.samples.x)-1,int(v.samples.z)-1}
        if offset.x<0 || offset.y<0 || far.x>int(h.samples.x)-1 || far.y>int(h.samples.z)-1 {
            core.report(problems,source.owner,"terrain.ground_outside","the box of this Volume is not within the Heightfield it joins (its samples %v to %v, of %v): move it over the Heightfield, or make it smaller",offset,far,[2]u32{h.samples.x,h.samples.z})
            continue
        }
        join.ground,join.entity,join.offset,join.lift=ground_entry.id,g,offset,corner.y
        hash:=base.hash_mix(base.hash_mix(base.hash_mix(base.hash_mix(base.hash_mix(ground_entry.id[0],ground_entry.id[1]),u64(offset.x)),u64(offset.y)),u64(transmute(u32)corner.y)),u64(transmute(u32)v.cell))
        // What the band reads of the ground: the chunks under the box and next to it.
        cells:=int(h.chunk_cells)
        counts:=chunk_counts(h)
        for cz in max(offset.y-1,0)/cells..=min((far.y+1)/cells,counts.z-1) {for cx in max(offset.x-1,0)/cells..=min((far.x+1)/cells,counts.x-1) {
            index:=chunk_index(h,{i32(cx),0,i32(cz)})
            if index>=0 && index<len(ground_entry.versions) {hash=base.hash_mix(hash,u64(ground_entry.versions[index]))}
        }}
        join.hash=hash|1
        if cut:=resident_source_find(resident,ground_entry.id,g);cut!=nil {
            append(&cut.join.cuts,Join_Cut{offset,far})
        }
        if join.hash!=join.seen {join_ground_check(problems,source.owner,v,h,join^)}
    }
    for &source in resident.sources {
        if len(source.join.cuts)>0 {
            hash:=u64(1)
            for cut in source.join.cuts {hash=base.hash_mix(base.hash_mix(base.hash_mix(base.hash_mix(hash,u64(cut.low.x)),u64(cut.low.y)),u64(cut.high.x)),u64(cut.high.y))}
            source.join.hash=hash
        } else if source.join.ground=={} {source.join.hash=0}
        if source.join.hash!=source.join.seen {resident.marks+=1}
    }
}

// The ground must cross the sides of the box between its bottom and top
// samples, or the surface of the Volume opens where it leaves.
@(private)
join_ground_check :: proc(problems:^core.Problems,e:core.Entity,v,h:^Source,join:Terrain_Join) {
    n:=[2]int{int(v.samples.x),int(v.samples.z)}
    low,high:=join.lift+v.cell,join.lift+f32(v.samples.y-2)*v.cell
    check :: proc "contextless" (h:^Source,join:Terrain_Join,x,z:int,low,high:f32) -> bool {
        height:=join_height(h,join.offset.x+x,join.offset.y+z)
        return height>low && height<high
    }
    for x in 0..<n.x {
        if !check(h,join,x,0,low,high) || !check(h,join,x,n.y-1,low,high) {
            core.report(problems,e,"terrain.ground_box","the ground of the Heightfield leaves the box of this Volume through its top or bottom at sample %v of its sides: its surface opens there; make the Volume taller or move it to hold the ground",x)
            return
        }
    }
    for z in 0..<n.y {
        if !check(h,join,0,z,low,high) || !check(h,join,n.x-1,z,low,high) {
            core.report(problems,e,"terrain.ground_box","the ground of the Heightfield leaves the box of this Volume through its top or bottom at sample %v of its sides: its surface opens there; make the Volume taller or move it to hold the ground",z)
            return
        }
    }
}

// Where one of a Volume and the Heightfield it joins is resident as a chunk
// over some cells, the chunks of the other over them are too: the hole
// never shows without the Volume, nor the Volume over the ground.
@(private)
joins_resident :: proc(resident:^Terrain_Resident,data:^Terrain_Data) {
    for &source in resident.sources {
        join:=&source.join
        if join.ground=={} {continue}
        entry,ground_entry:=data_find(data,source.id),data_find(data,join.ground)
        volume,ground:=resident_owner_find(resident,source.owner,source.id),resident_owner_find(resident,join.entity,join.ground)
        if entry==nil || ground_entry==nil || volume==nil || ground==nil {continue}
        v,h:=&entry.source,&ground_entry.source
        vc,hc:=int(v.chunk_cells),int(h.chunk_cells)
        // Twice: what a Volume chunk brings, then what the ground brings back.
        for pass in 0..<2 {
            for &node,i in volume.nodes[:min(volume.quad.first[1],len(volume.nodes))] {
                coord:=chunk_coord(v,i)
                low:=join.offset+[2]int{int(coord.x),int(coord.z)}*vc
                high:=low+vc
                any:=false
                for cz in low.y/hc..=min((high.y-1)/hc,chunk_counts(h).z-1) {for cx in low.x/hc..=min((high.x-1)/hc,chunk_counts(h).x-1) {
                    index:=chunk_index(h,{i32(cx),0,i32(cz)})
                    if index<0 || index>=len(ground.nodes) {continue}
                    if pass==0 && node.resident {ground.nodes[index].resident=true}
                    any||=ground.nodes[index].resident
                }}
                if pass==1 && any {node.resident=true}
            }
        }
    }
}

@(private)
resident_owner_find :: proc "contextless" (resident:^Terrain_Resident,e:core.Entity,id:base.Asset_Id) -> ^Resident_Owner {
    for &owner in resident.owners {if owner.entity==e && owner.source==id {return &owner}}
    return nil
}
