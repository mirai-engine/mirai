package terrain

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// Heightfields side by side meet by themselves: two terrains whose sources
// are Heightfields of the same cell and cells per chunk, placed with the same
// turn and scale, whose samples fall on one lattice and whose edges touch, a
// whole number of chunks along each other, share that edge. Its samples are
// those of the terrain of the lower Id; the levels of the borders along it are
// chosen over both; the normals, the rules of the layers and the edges of the
// colliders read across it; and a brush over it writes both. Nothing names
// the neighbor: where the terrains stand says it.

// The Heightfield beside a side of a terrain (-X, +X, -Z, +Z), as found in
// the last evaluation of levels: sample p of this terrain's source is sample
// p-offset of the other's, chunk c along the side is chunk c-shift of it.
Owner_Side :: struct {
    owner:int,            // in Terrain_Resident.owners; -1: none
    source:base.Asset_Id,
    offset:[2]int,
    shift:int,
    dy:f32,               // what a height of the other adds to be one of this terrain
    owns:bool,            // the other has the lower Id: the samples of the edge are its
}
OWNER_SIDE_NONE :: Owner_Side{owner=-1}

// Whether a build reads source s across a side.
@(private)
edges_read :: proc "contextless" (join:^Chunk_Join,s:^Source) -> bool {
    for e in join.edges {if e.s==s {return true}}
    return false
}

// What a build reads across a side: the source beside it, as Owner_Side.
Edge_Read :: struct {
    s:^Source,
    offset:[2]int,
    dy:f32,
    owns:bool,
}

// The Heightfield terrains beside each owner. A side takes the first
// terrain that meets it whole: same cell and chunk, same turn and scale, its
// samples on the lattice of this one and its edge on this edge, shifted along
// it by whole chunks.
@(private)
owners_sides :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:^core.Table(core.World_Transform,.Read),ids:^core.Table(core.Id,.Read)) {
    for &owner in resident.owners {owner.sides={OWNER_SIDE_NONE,OWNER_SIDE_NONE,OWNER_SIDE_NONE,OWNER_SIDE_NONE}}
    for &a,i in resident.owners {
        ea:=data_find(data,a.source)
        wa,placed_a:=core.get(worlds,a.entity)
        if ea==nil || !placed_a || ea.source.kind!=.Heightfield || a.far {continue}
        sa:=&ea.source
        for &b,j in resident.owners {
            if j==i {continue}
            eb:=data_find(data,b.source)
            wb,placed_b:=core.get(worlds,b.entity)
            if eb==nil || !placed_b || eb.source.kind!=.Heightfield || b.far {continue}
            side,d,dy,meets:=side_of(sa,wa.transform,&eb.source,wb.transform)
            if !meets {continue}
            if a.sides[side].owner>=0 {continue}
            owns:=owner_id(ids,b.entity)<owner_id(ids,a.entity)
            along:=side<2?1:0
            a.sides[side]={owner=j,source=b.source,offset=d,shift=d[along]/int(sa.chunk_cells),dy=dy,owns=owns}
        }
    }
}

// An edit, with its terrain chosen, and the same brush on each Heightfield
// beside that terrain whose ground it reaches: a brush over an edge two
// terrains share writes both, so the samples they share stay one.
EDIT_SPREAD :: 5
edit_spread :: proc(asked:Edit_Request,data:^Terrain_Data,terrains:^core.Table(Terrain,$A),worlds:^core.Table(core.World_Transform,$B)) -> (spread:[EDIT_SPREAD]Edit_Request,count:int) {
    spread[0],count=asked,1
    if asked.owner==core.NONE {
        owner,found:=dig_owner(asked.brush,data,terrains,worlds)
        if !found {return}
        spread[0].owner=owner
    }
    a:=spread[0].owner
    marker,known:=core.get(terrains,a)
    wa,placed:=core.get(worlds,a)
    entry:=known?data_find(data,marker.source):nil
    if entry==nil || !placed || entry.source.kind!=.Heightfield {return}
    b:=asked.brush
    reach:=max(b.radius,linalg.length(b.extent),linalg.length(b.delta)+b.radius)
    for other,row in terrains.values[:core.count(terrains)] {
        e:=core.entity_at(terrains,row)
        if e==a || count==EDIT_SPREAD {continue}
        beside:=data_find(data,other.source)
        wb,placed_b:=core.get(worlds,e)
        if beside==nil || !placed_b {continue}
        if _,_,_,meets:=side_of(&entry.source,wa.transform,&beside.source,wb.transform);!meets {continue}
        s:=&beside.source
        low,high:=source_box(s,{},{int(s.samples.x)-1,0,int(s.samples.z)-1})
        box:=mm.aabb_transform(mm.Aabb{min=low,max=high},mm.transform_matrix(wb.transform))
        if b.center.x+reach<box.min.x || b.center.x-reach>box.max.x || b.center.z+reach<box.min.z || b.center.z-reach>box.max.z {continue}
        spread[count]={owner=e,brush=b}
        count+=1
    }
    return
}

// The side of a Heightfield a that another, b, meets (-X, +X, -Z, +Z), and
// where the first sample of b is among those of a; ok false where they do
// not meet: another cell or chunk, another turn or scale, samples off the
// lattice, edges apart, or shifted along the side by a part of a chunk.
side_of :: proc "contextless" (sa:^Source,wa:mm.Transform,sb:^Source,wb:mm.Transform) -> (side:int,offset:[2]int,dy:f32,ok:bool) {
    if sa.kind!=.Heightfield || sb.kind!=.Heightfield || sb.cell!=sa.cell || sb.chunk_cells!=sa.chunk_cells {return}
    if abs(abs(linalg.dot(quaternion_vector(wa.rotation),quaternion_vector(wb.rotation)))-1)>1e-5 || linalg.length(wa.scale-wb.scale)>1e-5*linalg.length(wa.scale) {return}
    corner:=mm.mat4_point(linalg.inverse(mm.transform_matrix(wa)),mm.mat4_point(mm.transform_matrix(wb),source_origin(sb)))-source_origin(sa)
    at:=[2]f32{corner.x,corner.z}/sa.cell
    d:=[2]int{int(math.round(at.x)),int(math.round(at.y))}
    if abs(at.x-f32(d.x))>1e-3 || abs(at.y-f32(d.y))>1e-3 {return}
    na,nb:=[2]int{int(sa.samples.x),int(sa.samples.z)},[2]int{int(sb.samples.x),int(sb.samples.z)}
    side=-1
    switch {
    case d.x==na.x-1:   side=1
    case d.x+nb.x-1==0: side=0
    case d.y==na.y-1:   side=3
    case d.y+nb.y-1==0: side=2
    }
    if side<0 {return}
    // Along the side: a whole number of chunks, and some cells in common.
    along:=side<2?1:0
    if d[along]%int(sa.chunk_cells)!=0 || d[along]>=na[along]-1 || d[along]+nb[along]-1<=0 {return}
    return side,d,corner.y,true
}

@(private="file")
quaternion_vector :: #force_inline proc "contextless" (q:quaternion128) -> [4]f32 {return {q.x,q.y,q.z,q.w}}

// What orders two terrains that meet: their Id, or without one their entity.
@(private="file")
owner_id :: proc(ids:^core.Table(core.Id,.Read),e:core.Entity) -> u64 {
    if ids!=nil {if id,has:=core.get(ids,e);has {return u64(id.value)}}
    return u64(e)
}

// What the builds of an owner read across its sides, from the data as it is.
@(private)
owner_edges :: proc(resident:^Terrain_Resident,data:^Terrain_Data,owner:^Resident_Owner) -> (edges:[4]Edge_Read) {
    for side,i in owner.sides {
        if side.owner<0 {continue}
        if entry:=data_find(data,side.source);entry!=nil {edges[i]={&entry.source,side.offset,side.dy,side.owns}}
    }
    return
}

// The height of a sample of the other side, as one of this terrain; false
// where it is past its source or its page is not in memory.
@(private)
edge_read :: #force_inline proc "contextless" (e:Edge_Read,x,z:int) -> (h:f32,ok:bool) {
    if e.s==nil {return}
    p:=[2]int{x,z}-e.offset
    if p.x<0 || p.y<0 || p.x>=int(e.s.samples.x) || p.y>=int(e.s.samples.z) || !cell_held(e.s,min(p.x,int(e.s.samples.x)-2),min(p.y,int(e.s.samples.z)-2)) {return}
    return grid_get(&e.s.field,p.x,p.y)+e.dy,true
}

// Whether sample x,z of a source lies on its side.
@(private)
edge_on :: #force_inline proc "contextless" (s:^Source,side,x,z:int) -> bool {
    switch side {
    case 0: return x==0
    case 1: return x==int(s.samples.x)-1
    case 2: return z==0
    }
    return z==int(s.samples.z)-1
}

// The height of sample x,z of a Heightfield with what lies beside it: a
// sample of an edge another terrain owns is its, and one past a side with a
// terrain is that terrain's; past a side without one, the nearest of its own.
@(private)
edge_height :: proc "contextless" (s:^Source,edges:^[4]Edge_Read,x,z:int) -> f32 {
    nx,nz:=int(s.samples.x),int(s.samples.z)
    side:=-1
    switch {
    case x<0:   side=0
    case x>=nx: side=1
    case z<0:   side=2
    case z>=nz: side=3
    }
    if edges!=nil {
        if side>=0 {
            if h,ok:=edge_read(edges[side],x,z);ok {return h}
        } else {
            for e,i in edges {if e.owns && edge_on(s,i,x,z) {if h,ok:=edge_read(e,x,z);ok {return h}}}
        }
    }
    return grid_get(&s.field,clamp(x,0,nx-1),clamp(z,0,nz-1))
}

// The side of a source a sample past it lies beyond, -1 for one inside.
@(private)
edge_beyond :: #force_inline proc "contextless" (s:^Source,x,z:int) -> int {
    switch {
    case x<0:                  return 0
    case x>=int(s.samples.x):  return 1
    case z<0:                  return 2
    case z>=int(s.samples.z):  return 3
    }
    return -1
}

// Whether a source has a terrain beyond the side sample x,z lies past.
@(private)
edge_has :: #force_inline proc "contextless" (s:^Source,edges:^[4]Edge_Read,x,z:int) -> bool {
    side:=edge_beyond(s,x,z)
    return edges!=nil && side>=0 && edges[side].s!=nil
}

// The owner of a sample of an edge: the source beside it and where it is
// there, for what else it holds (weights, paint); ok false where this source
// owns it.
@(private)
edge_owner :: proc "contextless" (s:^Source,edges:^[4]Edge_Read,x,z:int) -> (other:^Source,p:[2]int,ok:bool) {
    if edges==nil {return}
    for e,i in edges {
        if e.s==nil || !e.owns || !edge_on(s,i,x,z) {continue}
        p=[2]int{x,z}-e.offset
        if p.x<0 || p.y<0 || p.x>=int(e.s.samples.x) || p.y>=int(e.s.samples.z) || !cell_held(e.s,min(p.x,int(e.s.samples.x)-2),min(p.y,int(e.s.samples.z)-2)) {continue}
        return e.s,p,true
    }
    return
}

// The levels of the chunks along the edges two terrains share, while they
// are made to meet (owners_levels_meet).
Side_Level :: struct {owner,chunk:u32}

// A key of what a piece on an edge reads across it: the versions of the
// chunks of the other side along it. A piece whose neighbor changes there is
// built again.
@(private)
edge_key :: proc(resident:^Terrain_Resident,data:^Terrain_Data,owner:^Resident_Owner,s:^Source,low,high:[2]int) -> (key:u64) {
    cells:=int(s.chunk_cells)
    for side,i in owner.sides {
        if side.owner<0 {continue}
        if !(i==0 && low.x==0 || i==1 && high.x>=int(s.samples.x)-1 || i==2 && low.y==0 || i==3 && high.y>=int(s.samples.z)-1) {continue}
        entry:=data_find(data,side.source)
        if entry==nil {continue}
        o:=&entry.source
        key=base.hash_mix(key|1,u64(i)+u64(side.offset.x)*7+u64(side.offset.y)*131+u64(side.owns))
        // The chunks of the other along this piece, and one more each way for its normals.
        a:=low-side.offset-2
        b:=high-side.offset+2
        n:=chunk_counts(o)
        for cz in max(a.y/cells,0)..=min(b.y/cells,n.z-1) {for cx in max(a.x/cells,0)..=min(b.x/cells,n.x-1) {
            if b.x<0 || b.y<0 {continue}
            index:=chunk_index(o,{i32(cx),0,i32(cz)})
            if index>=0 && index<len(entry.versions) {key=base.hash_mix(key,u64(entry.versions[index]))}
        }}
    }
    return
}

// The levels the borders of the pieces of a source are built from, for its
// owner: its chunks and those of the terrains beside it.
@(private)
resident_border :: proc(resident:^Terrain_Resident,source:^Resident_Source) -> (b:Border_Levels) {
    q:=&source.quad
    b={counts=q.counts[0],levels=source.levels,deep=source.deep}
    owner:=resident_owner_find(resident,source.owner,source.id)
    if owner==nil {return}
    for side,i in owner.sides {
        if side.owner<0 || side.owner>=len(resident.owners) {continue}
        other:=&resident.owners[side.owner]
        beside:=resident_source_find(resident,other.source,other.entity)
        if beside==nil || len(beside.levels)==0 {continue}
        counts:=beside.quad.counts[0]
        shift:[2]int
        switch i {
        case 0: shift={-counts.x,side.shift}
        case 1: shift={b.counts.x,side.shift}
        case 2: shift={side.shift,-counts.y}
        case 3: shift={side.shift,b.counts.y}
        }
        b.sides[i]={counts=counts,levels=beside.levels,deep=beside.deep,shift=shift}
    }
    return
}

// The levels of the chunks along the edges terrains share made to meet: two
// chunks that touch across one are one level apart at most, the coarser made
// finer, as lod_levels_balance does inside a terrain; each owner balances
// again from what changed. Rounds until nothing does.
@(private)
owners_levels_meet :: proc(resident:^Terrain_Resident,data:^Terrain_Data) {
    for _ in 0..<LOD_LEVELS_MAX+QUAD_DEPTH_MAX {
        changed:=false
        for &owner in resident.owners {
            source:=resident_source_find(resident,owner.source,owner.entity)
            entry:=data_find(data,owner.source)
            if source==nil || entry==nil || entry.source.kind!=.Heightfield || len(source.levels)==0 {continue}
            b:=resident_border(resident,source)
            lowered:=false
            for z in 0..<b.counts.y {for x in 0..<b.counts.x {
                if x>0 && x<b.counts.x-1 && z>0 && z<b.counts.y-1 {continue}
                level:=&source.levels[x+b.counts.x*z]
                for dz in -1..=1 {for dx in -1..=1 {
                    if x+dx>=0 && x+dx<b.counts.x && z+dz>=0 && z+dz<b.counts.y {continue}
                    other,_,ok:=border_chunk(&b,x+dx,z+dz)
                    if ok && level^>other+1 {level^=other+1;lowered=true}
                }}
            }}
            if lowered {
                changed=true
                levels_balance_sparse(&entry.source,&owner,source.levels,resident.lod_pass,&resident.stack)
            }
        }
        if !changed {return}
    }
}
