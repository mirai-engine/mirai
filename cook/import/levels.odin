package importer

import "core:math"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// Levels of detail of a mesh, made when it is imported and stored in its
// asset: the renderer draws them as they are instead of deriving its own
// every time the mesh is loaded.
//
// A static mesh has no levels of its own: its clusters are the DAG of level 0
// (asset.mesh_build_dag), whose cut takes each part of it as fine as its
// distance needs. A skinned one has whole levels. Such a level is level 0
// simplified by edge collapse (geom.simplify) with its normals and uvs weighed
// (LOD_WEIGHTS) and its border locked, so pieces that meet at their borders
// keep meeting at every level. Where the seams of normals stop it short of
// its target, it is simplified again crossing them (Permissive); the seams of
// everything else (uvs, colors, materials, the sign of the tangent) keep
// their outline. Where those seams still stop it above LOD_KEEP of the level
// before (faceted pieces, a seam on every edge), it crosses them too, all but
// the outlines between materials, and its error counts what the attributes
// lose. Every vertex of a level is a vertex of level 0 as it was, except those
// of islands.
//
// Aggregate detail (leaves, cards, clumps of grass) is pruned instead
// (geom.islands_reduce). An island is a piece of a submesh that shares no
// position with the rest; a submesh is of islands when at least ISLANDS_MIN
// of its islands are small: leaves and cards, of at most
// ISLAND_MAX_TRIANGLES and 1/ISLAND_MAX_SHARE of its triangles. Clumps of
// hundreds of triangles are not: quadrics simplify them with less error than
// dropping them. The small islands of a submesh are split in classes by their
// radius, an octave each, so a few large ones (a liana, a panel) do not hold
// back the leaves, in a fixed order spread over the submesh; the rest of the
// submesh (a trunk, a body) is simplified as any other. In the DAG a group of
// islands is reduced; of a skinned mesh, each level reduces all of them as far
// as the error the rest already has allows, and more only when it would
// otherwise keep over LOD_KEEP of the level before: the leaves of a tree whose
// trunk simplifies with little error go when they are small, not with the
// trunk.
//
// A card cut to the outline of its mask (cutout.odin) is one island whatever
// its outline holds, and its outlines are its rungs: the one level 0 draws,
// then the coarser ones of Mesh_Outlines. The survivors of a pruned class of
// outlines grow to the area all of them drew in level 0, the area of what
// their masks keep, so the crown of a tree stays as dense as it was at every
// level.

LOD_MAX :: 16            // levels, level 0 included

// A range of the indices of a mesh with the triangles of one material slot.
Submesh :: struct {
    first_index,index_count:u32,
    slot:u32, // row of slots
    bounds_min,bounds_max:[3]f32,
}

// A level of Mesh_Levels: its indices, the vertices they name and its submeshes.
Lod :: struct {
    first_index,index_count:u32,
    first_vertex,vertex_count:u32,
    first_submesh,submesh_count:u32,
    error:f32, // how far it is from level 0 as given, in the space of the mesh; of level 0, how far its outlines draw from what their masks keep
}

LOD_MIN_TRIANGLES :: 256 // a level with fewer triangles is the last
LOD_SHARE :: 0.25        // of the triangles of a level, what the next one aims at
LOD_KEEP :: 0.7          // a level that keeps more than this share of the one before is not stored
ISLAND_MAX_TRIANGLES :: 64 // a small island has at most this many triangles
ISLAND_MAX_SHARE :: 16     // and at most 1/16 of the triangles of its submesh
ISLANDS_MIN :: 16          // small islands a submesh of islands has at least
ISLAND_CLASSES :: 8        // octaves of radius the small islands of a submesh are split in; smaller ones join the last

// A mesh as its asset stores it: level 0 followed by its simplified levels.
Mesh_Levels :: struct {
    vertices: []asset.Vertex, // of a DAG, those of level 0 followed by those of the outlines of its islands
    indices:  []u32,               // of vertices, those of a level naming its own
    skin:     []asset.Skin_Vertex, // empty, or one per vertex
    lods:     []Lod,
    submeshes:[]Submesh,     // those of level 0 as given, then those of each level
    morphs:   []asset.Morph_Target,
    morph_deltas:[]asset.Morph_Delta, // a vertex of a level moves with the vertex of level 0 it is
    pruned:bool, // some submesh is of islands, which its levels prune
    dag:bool,    // static: level 0 alone, whose clusters are its DAG
    rest:[]u32,  // of a DAG, the triangles of level 0 it simplifies: all but those of islands
    failed:bool, // there was not the memory for its islands: it is not to be built
    islands:asset.Mesh_Islands, // of a DAG, those it prunes
}

@(private="file")
NONE :: max(u32)

// Level 0 as given, followed by up to LOD_MAX-1 simplified levels for a
// skinned mesh (a static one is a DAG instead, with its islands). Each aims
// at LOD_SHARE of the triangles of the one before; the levels end with the
// first that cannot remove a share of them, or once one has fewer than
// LOD_MIN_TRIANGLES. Mesh_Lod.error is how far geom.simplify moved the surface
// of level 0, in meters. With `simplify` false there is level 0 alone. indices
// are valid for vertices, and submeshes are ranges of indices: what
// asset.mesh_check asks. Everything returned is in `allocator`.
mesh_levels :: proc(vertices:[]asset.Vertex,indices:[]u32,skin:[]asset.Skin_Vertex,submeshes:[]Submesh,simplify:=true,allocator:=context.allocator,morphs:[]asset.Morph_Target=nil,morph_deltas:[]asset.Morph_Delta=nil,outlines:=Mesh_Outlines{}) -> (levels:Mesh_Levels) {
    out_vertices:=make([dynamic]asset.Vertex,0,len(vertices),allocator)
    out_indices:=make([dynamic]u32,0,len(indices),allocator)
    out_skin:=make([dynamic]asset.Skin_Vertex,0,len(skin),allocator)
    out_lods:=make([dynamic]Lod,0,LOD_MAX,allocator)
    out_submeshes:=make([dynamic]Submesh,0,len(submeshes),allocator)
    sources:=make([dynamic]u32,context.temp_allocator)
    append(&out_vertices,..vertices)
    append(&out_indices,..indices)
    append(&out_skin,..skin)
    append(&out_submeshes,..submeshes)
    append(&out_lods,Lod{index_count=u32(len(indices)),vertex_count=u32(len(vertices)),submesh_count=u32(len(submeshes))})
    outlines:=outlines
    if len(outlines.rungs)!=len(outlines.cards)*(OUTLINE_RUNGS-1) || len(skin)>0 && len(outlines.skin)!=len(outlines.vertices) || len(morphs)>0 && len(outlines.morphs)!=len(morphs) {outlines={}}
    if simplify && len(indices)>0 && len(vertices)<1<<24 {
        levels_simplify(vertices,indices,skin,submeshes,outlines,&out_vertices,&out_indices,&out_skin,&out_lods,&out_submeshes,&sources if len(morphs)>0 else nil,&levels,allocator)
    }
    levels.vertices,levels.indices,levels.skin,levels.lods,levels.submeshes=out_vertices[:],out_indices[:],out_skin[:],out_lods[:],out_submeshes[:]
    if len(morphs)>0 {
        // The deltas of the outlines after those of level 0, as their vertices come after.
        targets,deltas:=morphs,morph_deltas
        if len(outlines.vertices)>0 {
            no_targets:mem.Allocator_Error
            targets,no_targets=make([]asset.Morph_Target,len(morphs),context.temp_allocator)
            merged,no_merged:=make([dynamic]asset.Morph_Delta,0,len(morph_deltas)+len(outlines.morph_deltas),context.temp_allocator)
            if no_targets!=nil || no_merged!=nil {levels.failed=true;return}
            // Within its capacity.
            for target,t in morphs {
                targets[t]=target
                targets[t].first=u32(len(merged))
                append(&merged,..morph_deltas[target.first:][:target.count])
                for delta in outlines.morph_deltas[outlines.morphs[t].first:][:outlines.morphs[t].count] {
                    moved:=delta
                    moved.vertex+=u32(len(vertices))
                    append(&merged,moved)
                }
                targets[t].count=u32(len(merged))-targets[t].first
            }
            deltas=merged[:]
        }
        levels.morphs,levels.morph_deltas=levels_morphs(len(out_vertices)-len(sources),len(vertices)+len(outlines.vertices),targets,deltas,sources[:],allocator)
    }
    return
}

// The geometry of a mesh (asset.Mesh_Geometry) from its levels: the DAG of
// level 0 and its islands for a static mesh, or the whole levels of a
// skinned one, whose clusters share one sphere. flags: the streams it keeps.
// False where the constructor fails.
levels_geometry :: proc(levels:Mesh_Levels,flags:asset.Mesh_Flags,out:^asset.Mesh_Geometry,allocator:=context.allocator) -> bool {
    source:=asset.Mesh_Source{vertices=levels.vertices,skin=levels.skin,morphs=levels.morphs,morph_deltas=levels.morph_deltas,flags=flags}
    if levels.dag {return asset.mesh_build_dag(source,levels.rest,out,allocator,levels.islands)}
    given:=make([]asset.Level_Source,len(levels.lods) if len(levels.lods)>1 else 0,context.temp_allocator)
    for &level,at in given {
        lod:=levels.lods[at]
        level={first_index=lod.first_index,index_count=lod.index_count,error=lod.error}
    }
    return asset.mesh_build(source,levels.indices,given,out,allocator)
}

// The targets with the deltas of the first `count` vertices as given (level
// 0, and the outlines of a DAG), followed in each by those of the vertices of
// the other levels, which take the deltas of the vertex of level 0 or of an
// outline (of `every`) they are.
@(private="file")
levels_morphs :: proc(count,every:int,morphs:[]asset.Morph_Target,deltas:[]asset.Morph_Delta,sources:[]u32,allocator:=context.allocator) -> (targets:[]asset.Morph_Target,out:[]asset.Morph_Delta) {
    targets=make([]asset.Morph_Target,len(morphs),allocator)
    output:=make([dynamic]asset.Morph_Delta,0,len(deltas),allocator)
    lookup:=make([]i32,every,context.temp_allocator)
    for &index in lookup {index=-1}
    for target,t in morphs {
        given:=deltas[target.first:][:target.count]
        for delta,i in given {lookup[delta.vertex]=i32(i)}
        targets[t]=target;targets[t].first=u32(len(output))
        for delta in given {if int(delta.vertex)<count {append(&output,delta)}}
        for source,v in sources {
            if at:=lookup[source];at>=0 {
                delta:=given[at]
                delta.vertex=u32(count+v)
                append(&output,delta)
            }
        }
        targets[t].count=u32(len(output))-targets[t].first
        for delta in given {lookup[delta.vertex]=-1}
    }
    return targets,output[:]
}

// The small islands of the submeshes of islands (see ISLAND_MAX_TRIANGLES),
// by class and, within each, by a hash of their first triangle: a fixed
// order whose prefixes spread over the submesh. Their rungs are their
// triangles of level 0 and, of a card, its coarser outlines (Mesh_Outlines,
// whose vertices come after those of level 0, from `offset`). island is the
// island of each triangle of level 0, NONE outside them. The triangles of
// each card are one small island, and a submesh with a card is of islands.
// False without memory.
@(private="file")
levels_islands :: proc(positions:[]geom.Vec3,indices:[]u32,submeshes:[]Submesh,outlines:Mesh_Outlines,offset:u32,allocator:=context.allocator) -> (islands:asset.Mesh_Islands,island:[]u32,ok:bool) {
    cards:=outlines.cards
    card_of,no_cards:=make([]u32,len(indices)/3,context.temp_allocator)
    if no_cards!=nil {return}
    for &c in card_of {c=NONE}
    for card,at in cards {
        for t in card.first_triangle..<card.first_triangle+card.triangle_count {
            if int(t)<len(card_of) {card_of[t]=u32(at)}
        }
    }
    // Of each small island: where its triangles are in triangle_list, its card and its order.
    Found :: struct {first,count:u32,card:u32,order:u64,center:geom.Vec3,radius:f32,class:u32}
    found:=make([dynamic]Found,context.temp_allocator)
    triangle_list:=make([dynamic]u32,context.temp_allocator)
    no_island:mem.Allocator_Error
    if island,no_island=make([]u32,len(indices)/3,allocator);no_island!=nil {return}
    for &i in island {i=NONE}
    class_count:u32
    for submesh in submeshes {
        sub:=indices[submesh.first_index:][:submesh.index_count]
        first_triangle:=submesh.first_index/3
        sub_triangles:=u32(len(sub)/3)
        labels,no_labels:=make([]u32,sub_triangles,context.temp_allocator)
        if no_labels!=nil {return}
        count:=geom.mesh_components(positions,sub,labels)
        // A card is the island of its own label, after those of the components.
        given,no_given:=make([dynamic]u32,count,context.temp_allocator)
        if no_given!=nil {return}
        for &g in given {g=NONE}
        first_card:=u32(count)
        for t in 0..<sub_triangles {
            if card:=card_of[first_triangle+t];card!=NONE {first_card=min(first_card,card)}
        }
        for t in 0..<sub_triangles {
            card:=card_of[first_triangle+t]
            if card==NONE {continue}
            label:=u32(count)+card-first_card
            for int(label)>=len(given) {
                if _,error:=append(&given,NONE);error!=nil {return}
            }
            given[label]=card
            labels[t]=label
        }
        count=len(given)
        sizes,no_sizes:=make([]u32,count,context.temp_allocator)
        if no_sizes!=nil {return}
        for l in labels {if l!=NONE {sizes[l]+=1}}
        small,carded:=0,false
        for size,l in sizes {
            if size>0 && (given[l]!=NONE || island_small(size,sub_triangles)) {small+=1}
            carded||=given[l]!=NONE
        }
        island_first:=u32(len(found))
        if small<ISLANDS_MIN && !carded {continue}
        // The small islands in the order of their first triangle, and the triangles of each.
        number,no_number:=make([]u32,count,context.temp_allocator)
        starts,no_starts:=make([dynamic]u32,0,small+1,context.temp_allocator)
        if no_number!=nil || no_starts!=nil {return}
        for &n in number {n=NONE}
        append(&starts,0)
        for l,t in labels {
            if l==NONE || sizes[l]==0 || given[l]==NONE && !island_small(sizes[l],sub_triangles) || number[l]!=NONE {continue}
            number[l]=u32(len(found))-island_first
            order:=u64(first_triangle)+u64(t)
            _,no_found:=append(&found,Found{order=base.splitmix_next(&order),card=given[l]})
            _,no_start:=append(&starts,starts[len(starts)-1]+sizes[l])
            if no_found!=nil || no_start!=nil {return}
        }
        base_triangle:=u32(len(triangle_list))
        fill,no_fill:=make([]u32,len(starts)-1,context.temp_allocator)
        if no_fill!=nil || resize(&triangle_list,int(base_triangle+starts[len(starts)-1]))!=nil {return}
        for l,t in labels {
            if l==NONE || number[l]==NONE {continue}
            k:=number[l]
            triangle_list[base_triangle+starts[k]+fill[k]]=first_triangle+u32(t)
            fill[k]+=1
        }
        at:=found[island_first:]
        for &i,k in at {
            i.first,i.count=base_triangle+starts[k],starts[k+1]-starts[k]
            n:=0
            for triangle in triangle_list[i.first:][:i.count] {
                for corner in indices[triangle*3:][:3] {
                    i.center+=positions[corner]
                    n+=1
                }
            }
            i.center/=f32(n)
            for triangle in triangle_list[i.first:][:i.count] {
                for corner in indices[triangle*3:][:3] {i.radius=max(i.radius,vec_length(positions[corner]-i.center))}
            }
        }
        largest:f32
        for i in at {largest=max(largest,i.radius)}
        for &i in at {
            octave:=i.radius>0?int(math.log2(largest/i.radius)):ISLAND_CLASSES-1
            i.class=class_count+u32(clamp(octave,0,ISLAND_CLASSES-1))
        }
        class_count+=ISLAND_CLASSES
    }
    // By class, then by their hash, ties by their first triangle.
    slice.sort_by(found[:],proc(a,b:Found) -> bool {
        if a.class!=b.class {return a.class<b.class}
        if a.order!=b.order {return a.order<b.order}
        return a.first<b.first
    })
    out:=make([dynamic]geom.Cluster_Island,0,len(found),allocator)
    rungs:=make([dynamic]geom.Cluster_Island_Rung,0,len(found),allocator)
    rung_indices:=make([dynamic]u32,0,len(triangle_list)*3,allocator)
    for i,k in found {
        made:=geom.Cluster_Island{first_rung=u32(len(rungs)),class=i.class,center=i.center,radius=i.radius,order=i.order}
        first:=u32(len(rung_indices))
        for triangle in triangle_list[i.first:][:i.count] {
            island[triangle]=u32(k)
            if _,error:=append(&rung_indices,..indices[triangle*3:][:3]);error!=nil {return}
        }
        if _,error:=append(&rungs,geom.Cluster_Island_Rung{first,u32(len(rung_indices))-first,cards[i.card].error if i.card!=NONE else 0});error!=nil {return}
        if i.card!=NONE && len(outlines.rungs)==len(cards)*(OUTLINE_RUNGS-1) {
            for r in outlines.rungs[int(i.card)*(OUTLINE_RUNGS-1):][:OUTLINE_RUNGS-1] {
                first=u32(len(rung_indices))
                for index in outlines.indices[r.first_index:][:r.index_count] {
                    if _,error:=append(&rung_indices,offset+index);error!=nil {return}
                }
                if _,error:=append(&rungs,geom.Cluster_Island_Rung{first,r.index_count,r.error});error!=nil {return}
            }
        }
        made.rung_count=u32(len(rungs))-made.first_rung
        if _,error:=append(&out,made);error!=nil {return}
    }
    return {out[:],rungs[:],rung_indices[:]},island,true
}

@(private)
island_small :: #force_inline proc "contextless" (triangles,of:u32) -> bool {
    return triangles<=ISLAND_MAX_TRIANGLES && triangles*ISLAND_MAX_SHARE<=of
}

@(private="file")
vec_length :: #force_inline proc "contextless" (a:geom.Vec3) -> f32 {return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z)}

// Of a static mesh, sets levels to a DAG of level 0 with its islands; of a
// skinned one, appends levels to out_lods until it holds LOD_MAX, each
// pruning the islands and simplifying the rest.
@(private="file")
levels_simplify :: proc(vertices:[]asset.Vertex,indices:[]u32,skin:[]asset.Skin_Vertex,submeshes:[]Submesh,outlines:Mesh_Outlines,out_vertices:^[dynamic]asset.Vertex,out_indices:^[dynamic]u32,out_skin:^[dynamic]asset.Skin_Vertex,out_lods:^[dynamic]Lod,out_submeshes:^[dynamic]Submesh,out_sources:^[dynamic]u32,levels:^Mesh_Levels,allocator:=context.allocator) {
    temp:=context.temp_allocator
    // The vertices of level 0 followed by those of the coarser outlines of its cards, with their skin.
    every,every_skin:=vertices,skin
    if len(outlines.cards)>0 {
        error:mem.Allocator_Error
        if every,error=make([]asset.Vertex,len(vertices)+len(outlines.vertices),temp);error!=nil {levels.failed=true;return}
        copy(every,vertices)
        copy(every[len(vertices):],outlines.vertices)
        if len(skin)>0 {
            if every_skin,error=make([]asset.Skin_Vertex,len(every),temp);error!=nil {levels.failed=true;return}
            copy(every_skin,skin)
            copy(every_skin[len(skin):],outlines.skin)
        }
    }
    offset:=u32(len(vertices))
    positions,attributes,protect:=asset.mesh_simplify_inputs(every)
    weights:=asset.MESH_SIMPLIFY_WEIGHTS
    // The islands that are pruned, and the triangles that are simplified.
    islands,island_of,found:=levels_islands(positions[:len(vertices)],indices,submeshes,outlines,offset,allocator if len(skin)==0 else temp)
    if !found {levels.failed=true;return}
    rest:=indices
    if len(islands.islands)>0 {
        levels.pruned=true
        others,no_others:=make([dynamic]u32,0,len(indices),allocator if len(skin)==0 else temp)
        if no_others!=nil {levels.failed=true;return}
        // Within its capacity.
        for i,t in island_of {
            if i==NONE {append(&others,..indices[t*3:][:3])}
        }
        rest=others[:]
    }
    // What each outline draws, and where each island is.
    areas,measured:=geom.islands_areas(positions,islands.rungs,islands.indices,temp)
    states,no_states:=make([]geom.Cluster_Island_State,len(islands.islands),temp)
    if !measured || no_states!=nil {levels.failed=true;return}
    allowed:f32
    for island,at in islands.islands {
        first:=islands.rungs[island.first_rung]
        states[at]={island=u32(at),grow=1,area=areas[island.first_rung],error=first.error}
        allowed=max(allowed,first.error)
    }
    // Level 0 is as far from what the masks keep as its outlines draw.
    out_lods[0].error=allowed
    if len(skin)==0 {
        levels.dag=true
        levels.rest=rest
        levels.islands=islands
        if len(outlines.vertices)>0 {
            if _,error:=append(out_vertices,..outlines.vertices);error!=nil {levels.failed=true}
        }
        return
    }
    alive:=len(states)
    // A level whose error passes the radius of the mesh would be drawn only where all of it is within a pixel.
    low,high:=positions[0],positions[0]
    for p in positions[:len(vertices)] {low,high=geom.Vec3{min(low.x,p.x),min(low.y,p.y),min(low.z,p.z)},geom.Vec3{max(high.x,p.x),max(high.y,p.y),max(high.z,p.z)}}
    radius:=0.5*vec_length(high-low)
    // The submesh of each vertex of level 0; NONE outside all of them.
    owner:=make([]u32,len(vertices),temp)
    for &submesh in owner {submesh=NONE}
    for submesh,at in submeshes {
        for index in indices[submesh.first_index:][:submesh.index_count] {
            if owner[index]==NONE {owner[index]=u32(at)}
        }
    }

    simplified:=make([]u32,len(indices),temp)
    // Of each triangle of the level: its corners (of level 0, or of an outline past it) and its island, NONE for none.
    level_corners:=make([dynamic]u32,0,len(indices),temp)
    level_islands:=make([dynamic]u32,0,len(indices)/3,temp)
    grow_of:=make([]f32,len(islands.islands),temp)
    local:=make([]u32,len(every),temp)
    // The triangles of the level by submesh, NONE last: those of group g are order[first[g]:first[g+1]].
    groups:=len(submeshes)+1
    order:=make([dynamic]u32,temp)
    first:=make([]u32,groups+1,temp)
    next:=make([]u32,groups,temp)
    // protect without the seams of attributes, for the levels they stop.
    relaxed:[]geom.Simplify_Vertex
    previous,previous_rest:=len(indices)/3,len(rest)/3
    for len(out_lods)<LOD_MAX && previous>=LOD_MIN_TRIANGLES {
        clear(&level_corners);clear(&level_islands)
        error:f32
        if len(rest)>0 {
            aim:=int(f32(previous_rest)*LOD_SHARE)
            options:=geom.Simplify_Options{.Lock_Border,.Error_Absolute}
            result,failed:=geom.simplify(simplified,rest,positions,aim*3,max(f32),options,attributes,weights[:],protect)
            if failed==.None && result.index_count>aim*3 {
                result,failed=geom.simplify(simplified,rest,positions,aim*3,max(f32),options+{.Permissive},attributes,weights[:],protect)
            }
            error=result.position_error
            if failed==.None && f32(result.index_count)>LOD_KEEP*f32(previous_rest*3) {
                if relaxed==nil {relaxed=levels_outlines(every,positions)}
                // Clamped, the error of the attributes reads as a distance, which the cut must see.
                result,failed=geom.simplify(simplified,rest,positions,aim*3,max(f32),options+{.Permissive,.Error_Clamped},attributes,weights[:],relaxed)
                error=max(result.result_error,result.position_error)
            }
            if failed!=.None {break}
            append(&level_corners,..simplified[:result.index_count])
            for _ in 0..<result.index_count/3 {append(&level_islands,NONE)}
            previous_rest=result.index_count/3
        }
        // The islands go as far as the error allowed lets them; where the level would keep too much
        // of the one before, they are allowed the least more that moves one more class.
        allowed=max(allowed,error)
        kept_islands,reached,islands_error,_,reduced:=geom.islands_reduce(states[:alive],islands.islands,islands.rungs,areas,allowed,int(LOD_KEEP*f32(previous))-len(level_corners)/3)
        if !reduced {levels.failed=true;return}
        alive,allowed=kept_islands,reached
        error=max(error,islands_error)
        for s in states[:alive] {
            island:=islands.islands[s.island]
            grow_of[s.island]=s.grow
            rung:=islands.rungs[island.first_rung+min(s.rung,island.rung_count-1)]
            for index in islands.indices[rung.first_index:][:rung.index_count] {append(&level_corners,index)}
            for _ in 0..<rung.index_count/3 {append(&level_islands,s.island)}
        }
        kept:=len(level_corners)/3
        if kept==0 || f32(kept)>LOD_KEEP*f32(previous) || error>radius {break}
        previous=kept
        level:=Lod{first_index=u32(len(out_indices)),first_vertex=u32(len(out_vertices)),first_submesh=u32(len(out_submeshes)),error=error}
        for &at in local {at=NONE}
        // Triangles in the order of the submeshes, so each is one range of the level; an island is of the submesh of its first vertex.
        resize(&order,kept)
        for &f in first {f=0}
        group_of :: proc(owner,level_corners,level_islands:[]u32,islands:asset.Mesh_Islands,groups,t:int) -> u32 {
            corner:=level_corners[t*3]
            if i:=level_islands[t];i!=NONE {corner=islands.indices[islands.rungs[islands.islands[i].first_rung].first_index]}
            return min(owner[corner],u32(groups-1))
        }
        for t in 0..<kept {first[group_of(owner,level_corners[:],level_islands[:],islands,groups,t)+1]+=1}
        for g in 1..=groups {first[g]+=first[g-1]}
        copy(next,first[:groups])
        for t in 0..<kept {
            g:=group_of(owner,level_corners[:],level_islands[:],islands,groups,t)
            order[next[g]]=u32(t)
            next[g]+=1
        }
        for group in 0..<groups {
            run:=order[first[group]:first[group+1]]
            if len(run)==0 {continue}
            wanted:=group<len(submeshes)?u32(group):NONE
            range:=Submesh{first_index=u32(len(out_indices))}
            if wanted!=NONE {range.slot=submeshes[wanted].slot}
            for t,nth in run {
                for corner in 0..<3 {
                    source:=level_corners[t*3+u32(corner)]
                    position:=positions[source]
                    // A vertex of an island is of no other triangle: it moves with its island.
                    if i:=level_islands[t];i!=NONE {
                        center:=islands.islands[i].center
                        position=center+(position-center)*grow_of[i]
                    }
                    if local[source]==NONE {
                        local[source]=u32(len(out_vertices))
                        vertex:=every[source]
                        vertex.position=position
                        append(out_vertices,vertex)
                        if len(skin)>0 {append(out_skin,every_skin[source])}
                        if out_sources!=nil {append(out_sources,source)}
                    }
                    append(out_indices,local[source])
                    if nth==0 && corner==0 {range.bounds_min,range.bounds_max=position,position}
                    for axis in 0..<3 {
                        range.bounds_min[axis]=min(range.bounds_min[axis],position[axis])
                        range.bounds_max[axis]=max(range.bounds_max[axis],position[axis])
                    }
                }
            }
            range.index_count=u32(len(out_indices))-range.first_index
            if wanted!=NONE {append(out_submeshes,range)}
        }
        level.index_count=u32(len(out_indices))-level.first_index
        level.vertex_count=u32(len(out_vertices))-level.first_vertex
        level.submesh_count=u32(len(out_submeshes))-level.first_submesh
        append(out_lods,level)
    }
    return
}

// Protect where vertices of different materials meet at one place, and
// nowhere else: what a level stuck on the seams of attributes keeps.
@(private="file")
levels_outlines :: proc(vertices:[]asset.Vertex,positions:[]geom.Vec3) -> []geom.Simplify_Vertex {
    welds:=make([]u32,len(vertices),context.temp_allocator)
    geom.positions_weld(positions,0,welds)
    outlines:=make([]geom.Simplify_Vertex,len(vertices),context.temp_allocator)
    for first,at in welds {
        if vertices[at].material!=vertices[first].material {
            outlines[at]={.Protect}
            outlines[first]={.Protect}
        }
    }
    return outlines
}
