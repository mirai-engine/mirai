package importer

import "core:math"
import "core:slice"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// Levels of detail of a mesh, made when it is imported and stored in its
// asset: the renderer draws them as they are instead of deriving its own
// every time the mesh is loaded.
//
// A level is level 0 simplified by edge collapse (geom.simplify) with its
// normals and uvs weighed (LOD_WEIGHTS) and its border locked, so pieces
// that meet at their borders keep meeting at every level. Where the seams of
// normals stop it short of its target, it is simplified again crossing
// them (Permissive); the seams of everything else (uvs, colors, materials,
// the sign of the tangent) keep their outline. Where those seams still stop
// it above LOD_KEEP of the level before (faceted pieces, a seam on every
// edge), it crosses them too, all but the outlines between materials, and
// its error counts what the attributes lose. Every vertex of a level is a
// vertex of level 0 as it was, except those of islands. A static mesh without
// islands has no levels: its clusters are the DAG of level 0.
//
// Aggregate detail (leaves, cards, clumps of grass) is pruned instead
// (Cook, Halstead, Planck and Ryu, Stochastic simplification of aggregate
// detail, Pixar 2007): simplifying each leaf by quadrics shrinks it to
// nothing and leaves a bare tree with metres of error. An island is a piece
// of a submesh that shares no position with the rest; a submesh is of
// islands when at least ISLANDS_MIN of its islands are small: leaves and
// cards, of at most ISLAND_MAX_TRIANGLES and 1/ISLAND_MAX_SHARE of its
// triangles. Clumps of hundreds of triangles are not: quadrics simplify them
// with less error than dropping them. The small islands of a submesh are
// split in classes by their radius, an octave each, so a few large ones (a
// liana, a panel) do not hold back the leaves. A class pruned j times keeps
// the first 1/2^j of its islands in a fixed order spread over the submesh,
// and grows each around its center so that they keep the area all of them
// had; the rest of the submesh (a trunk, a body) is simplified as any other.
// The error of a class is the radius of its largest island grown, over
// ISLAND_PIXELS. Each level prunes every class as far as the error the rest
// already has allows, and allows more only when it would otherwise keep
// over LOD_KEEP of the level before: the leaves of a tree whose trunk
// simplifies with little error go when they are small, not with the trunk.
//
// A card cut to the outline of its mask (cutout.odin) is one island whatever
// its outline holds, and its class steps through the coarser outlines of its
// cards before it is pruned: each step the coarsest outline whose error, the
// largest of its cards, the error allowed lets it take, and pruning only from
// the last. The survivors of a pruned class of outlines grow to the area all
// of them drew in level 0, the area of what their masks keep, so the crown of
// a tree stays as dense as it was at every level.

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
ISLAND_PIXELS :: f32(8)    // of the threshold of the cut, how far the radius of a grown island may span where its level draws it
ISLAND_GROW_MAX :: f32(4)  // the most the islands of a class grow: past it they are not pruned further

// A mesh as its asset stores it: level 0 followed by its simplified levels.
Mesh_Levels :: struct {
    vertices: []asset.Vertex,
    indices:  []u32,               // of vertices, those of a level naming its own
    skin:     []asset.Skin_Vertex, // empty, or one per vertex
    lods:     []Lod,
    submeshes:[]Submesh,     // those of level 0 as given, then those of each level
    morphs:   []asset.Morph_Target,
    morph_deltas:[]asset.Morph_Delta, // a vertex of a level moves with the vertex of level 0 it is
    pruned:bool, // some submesh is of islands, which its levels prune
    dag:bool,    // static and not pruned: level 0 alone, whose clusters are its DAG
}

@(private="file")
NONE :: max(u32)

// Level 0 as given, followed by up to LOD_MAX-1 simplified levels for a
// skinned or pruned mesh (a static one is a DAG instead). Each aims at
// LOD_SHARE of the triangles of the one before; the levels end with the first
// that cannot remove a share of them, or once one has fewer than
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
    pruned,dag:=false,false
    if simplify && len(indices)>0 && len(vertices)<1<<24 {
        levels_simplify(vertices,indices,skin,submeshes,outlines if len(skin)==0 && len(morphs)==0 else {},&out_vertices,&out_indices,&out_skin,&out_lods,&out_submeshes,&sources if len(morphs)>0 else nil,&pruned,&dag)
    }
    levels={vertices=out_vertices[:],indices=out_indices[:],skin=out_skin[:],lods=out_lods[:],submeshes=out_submeshes[:],pruned=pruned,dag=dag}
    if len(morphs)>0 {levels.morphs,levels.morph_deltas=levels_morphs(len(vertices),morphs,morph_deltas,sources[:],allocator)}
    return
}

// The geometry of a mesh (asset.Mesh_Geometry) from its levels: the DAG of
// level 0 for a static mesh, or its whole levels when they are of a skinned
// one or prune islands (foliage), whose clusters share one sphere. flags: the
// streams it keeps. False where the constructor fails.
levels_geometry :: proc(levels:Mesh_Levels,flags:asset.Mesh_Flags,out:^asset.Mesh_Geometry,allocator:=context.allocator) -> bool {
    source:=asset.Mesh_Source{vertices=levels.vertices,skin=levels.skin,morphs=levels.morphs,morph_deltas=levels.morph_deltas,flags=flags}
    if levels.dag {
        level0:=levels.lods[0]
        return asset.mesh_build_dag(source,levels.indices[level0.first_index:][:level0.index_count],out,allocator)
    }
    given:=make([]asset.Level_Source,len(levels.lods) if len(levels.lods)>1 else 0,context.temp_allocator)
    for &level,at in given {
        lod:=levels.lods[at]
        level={first_index=lod.first_index,index_count=lod.index_count,error=lod.error}
    }
    return asset.mesh_build(source,levels.indices,given,out,allocator)
}

// The targets with the deltas of level 0 as given, followed in each by those
// of the vertices of the other levels, which take the deltas of the vertex
// of level 0 they are.
@(private="file")
levels_morphs :: proc(count:int,morphs:[]asset.Morph_Target,deltas:[]asset.Morph_Delta,sources:[]u32,allocator:=context.allocator) -> (targets:[]asset.Morph_Target,out:[]asset.Morph_Delta) {
    targets=make([]asset.Morph_Target,len(morphs),allocator)
    output:=make([dynamic]asset.Morph_Delta,0,len(deltas),allocator)
    lookup:=make([]i32,count,context.temp_allocator)
    for &index in lookup {index=-1}
    for target,t in morphs {
        given:=deltas[target.first:][:target.count]
        for delta,i in given {lookup[delta.vertex]=i32(i)}
        targets[t]=target;targets[t].first=u32(len(output))
        append(&output,..given)
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


// The small islands of the submeshes of islands, in the order in which the
// levels drop them: those of island i are triangles[first:][:count].
@(private="file")
Island :: struct {
    first,count:u32,
    class:u32,        // octave of its radius below the largest of its submesh
    center:geom.Vec3, // of its vertices, what it grows around
    radius:f32,       // around center
    area:f32,
    order:u64,
    card:u32,         // of Mesh_Outlines.cards, NONE for an island that is not a cut card
}

// The islands of a submesh of one octave of radius, islands[first:][:count].
@(private="file")
Island_Class :: struct {
    first,count:u32,
    largest:f32, // radius of its largest island
    rungs:u32,   // outlines its cards step through, level 0 included; 1 for islands that are not cards
    errors:[OUTLINE_RUNGS]f32, // of each outline, the largest of its cards
}

// Of the islands of a mesh, what each of its outlines draws: those before
// each island, by outline, so a prefix of a class is a difference.
@(private="file")
Island_Sums :: struct {
    area:[OUTLINE_RUNGS][]f32,
    triangles:[OUTLINE_RUNGS][]u32,
}

// The small islands of the submeshes of islands (see ISLAND_MAX_TRIANGLES)
// by class, ordered within each by a hash of their first triangle: a fixed
// order whose prefixes spread over the submesh. island is the island of each
// triangle of level 0, NONE outside them. The triangles of each card are one
// small island, and a submesh with a card is of islands.
@(private="file")
levels_islands :: proc(positions:[]geom.Vec3,indices:[]u32,submeshes:[]Submesh,cards:[]Outline_Card,allocator:=context.allocator) -> (islands:[]Island,classes:[]Island_Class,triangles:[]u32,island:[]u32) {
    card_of:=make([]u32,len(indices)/3,context.temp_allocator)
    for &c in card_of {c=NONE}
    for card,at in cards {
        for t in card.first_triangle..<card.first_triangle+card.triangle_count {
            if int(t)<len(card_of) {card_of[t]=u32(at)}
        }
    }
    found:=make([dynamic]Island,allocator)
    found_classes:=make([dynamic]Island_Class,allocator)
    triangle_list:=make([dynamic]u32,allocator)
    island=make([]u32,len(indices)/3,allocator)
    for &i in island {i=NONE}
    for submesh,s in submeshes {
        sub:=indices[submesh.first_index:][:submesh.index_count]
        first_triangle:=submesh.first_index/3
        sub_triangles:=u32(len(sub)/3)
        labels:=make([]u32,sub_triangles,context.temp_allocator)
        count:=geom.mesh_components(positions,sub,labels)
        // A card is the island of its own label, after those of the components.
        given:=make([dynamic]u32,count,context.temp_allocator)
        for &g in given {g=NONE}
        first_card:=u32(count)
        for t in 0..<sub_triangles {
            if card:=card_of[first_triangle+t];card!=NONE {first_card=min(first_card,card)}
        }
        for t in 0..<sub_triangles {
            card:=card_of[first_triangle+t]
            if card==NONE {continue}
            label:=u32(count)+card-first_card
            for int(label)>=len(given) {append(&given,NONE)}
            given[label]=card
            labels[t]=label
        }
        count=len(given)
        sizes:=make([]u32,count,context.temp_allocator)
        for l in labels {if l!=NONE {sizes[l]+=1}}
        small,carded:=0,false
        for size,l in sizes {
            if size>0 && (given[l]!=NONE || island_small(size,sub_triangles)) {small+=1}
            carded||=given[l]!=NONE
        }
        island_first:=u32(len(found))
        if small<ISLANDS_MIN && !carded {continue}
        // The small islands in the order of their first triangle, and the triangles of each.
        number:=make([]u32,count,context.temp_allocator)
        for &n in number {n=NONE}
        starts:=make([dynamic]u32,0,small+1,context.temp_allocator)
        append(&starts,0)
        for l,t in labels {
            if l==NONE || sizes[l]==0 || given[l]==NONE && !island_small(sizes[l],sub_triangles) || number[l]!=NONE {continue}
            number[l]=u32(len(found))-island_first
            order:=u64(first_triangle)+u64(t)
            append(&found,Island{order=base.splitmix_next(&order),card=given[l]})
            append(&starts,starts[len(starts)-1]+sizes[l])
        }
        offset:=u32(len(triangle_list))
        resize(&triangle_list,int(offset+starts[len(starts)-1]))
        fill:=make([]u32,len(starts)-1,context.temp_allocator)
        for l,t in labels {
            if l==NONE || number[l]==NONE {continue}
            k:=number[l]
            triangle_list[offset+starts[k]+fill[k]]=first_triangle+u32(t)
            fill[k]+=1
        }
        at:=found[island_first:]
        for &i,k in at {
            i.first,i.count=offset+starts[k],starts[k+1]-starts[k]
            n:=0
            for triangle in triangle_list[i.first:][:i.count] {
                for corner in indices[triangle*3:][:3] {
                    i.center+=positions[corner]
                    n+=1
                }
                p0,p1,p2:=positions[indices[triangle*3]],positions[indices[triangle*3+1]],positions[indices[triangle*3+2]]
                i.area+=0.5*vec_length(vec_cross(p1-p0,p2-p0))
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
            i.class=u32(clamp(octave,0,ISLAND_CLASSES-1))
        }
        // By class, then by their hash, ties by their first triangle.
        slice.sort_by(at,proc(a,b:Island) -> bool {
            if a.class!=b.class {return a.class<b.class}
            if a.order!=b.order {return a.order<b.order}
            return a.first<b.first
        })
        for i,k in at {
            for triangle in triangle_list[i.first:][:i.count] {island[triangle]=island_first+u32(k)}
            if k==0 || at[k-1].class!=i.class {append(&found_classes,Island_Class{first=island_first+u32(k)})}
            class:=&found_classes[len(found_classes)-1]
            class.count+=1
            class.largest=max(class.largest,i.radius)
        }
    }
    return found[:],found_classes[:],triangle_list[:],island
}

@(private)
island_small :: #force_inline proc "contextless" (triangles,of:u32) -> bool {
    return triangles<=ISLAND_MAX_TRIANGLES && triangles*ISLAND_MAX_SHARE<=of
}

// The islands a class halved `depth` times keeps: the first of its order, one at least.
@(private="file")
class_keep :: #force_inline proc "contextless" (class:Island_Class,depth:u32) -> u32 {
    return max((class.count+(1<<depth)-1)>>depth,1)
}

// Where a class is at `state`: the outline its islands draw and how many
// times it is halved, which starts at its last outline.
@(private="file")
class_step :: #force_inline proc "contextless" (class:Island_Class,state:u32) -> (rung,depth:u32) {
    last:=class.rungs-1
    return min(state,last),state-min(state,last)
}

// The last state of a class: halved until it keeps one island or its islands grow past ISLAND_GROW_MAX.
@(private="file")
class_state_max :: proc "contextless" (class:Island_Class,sums:^Island_Sums) -> u32 {
    depth:u32
    for class_keep(class,depth)>1 && class_grow(class,depth+1,sums)<=ISLAND_GROW_MAX {depth+=1}
    return class.rungs-1+depth
}

// How much the islands a class keeps halved `depth` times grow: to the area
// all of them drew in level 0, each drawing its last outline.
@(private="file")
class_grow :: proc "contextless" (class:Island_Class,depth:u32,sums:^Island_Sums) -> f32 {
    if depth==0 {return 1}
    all:=sums.area[0][class.first+class.count]-sums.area[0][class.first]
    last:=&sums.area[class.rungs-1]
    kept:=last[class.first+class_keep(class,depth)]-last[class.first]
    return max(math.sqrt(all/kept),1) if kept>0 else 1
}

// The error of a class at a state: that of its outline, and once halved the
// radius of its largest island grown over ISLAND_PIXELS, whichever is larger.
@(private="file")
class_error :: proc "contextless" (class:Island_Class,state:u32,sums:^Island_Sums) -> f32 {
    rung,depth:=class_step(class,state)
    grow:=class_grow(class,depth,sums)
    error:=class.errors[rung]*grow
    if depth>0 {error=max(error,class.largest*grow/ISLAND_PIXELS)}
    return error
}

// The triangles a class draws at a state.
@(private="file")
class_triangles :: proc "contextless" (class:Island_Class,state:u32,sums:^Island_Sums) -> u32 {
    rung,depth:=class_step(class,state)
    before:=&sums.triangles[rung]
    return before[class.first+class_keep(class,depth)]-before[class.first]
}

@(private="file")
vec_cross :: #force_inline proc "contextless" (a,b:geom.Vec3) -> geom.Vec3 {return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}}
@(private="file")
vec_length :: #force_inline proc "contextless" (a:geom.Vec3) -> f32 {return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z)}

// Appends the triangles an island draws at an outline, as indices of the
// vertices of level 0 followed by those of the outlines: its own for
// outline 0 or an island that is not a card.
@(private="file")
island_rung :: proc(outlines:Mesh_Outlines,island:Island,rung:u32,island_triangles,indices:[]u32,offset:u32,out:^[dynamic]u32) {
    if rung==0 || island.card==NONE {
        for triangle in island_triangles[island.first:][:island.count] {append(out,..indices[triangle*3:][:3])}
        return
    }
    r:=outlines.rungs[int(island.card)*(OUTLINE_RUNGS-1)+int(rung)-1]
    for index in outlines.indices[r.first_index:][:r.index_count] {append(out,offset+index)}
}

// Appends levels to out_lods until it holds LOD_MAX, each pruning the small
// islands of the submeshes of islands and simplifying the rest; of a static
// mesh without islands, none, and dag is set.
@(private="file")
levels_simplify :: proc(vertices:[]asset.Vertex,indices:[]u32,skin:[]asset.Skin_Vertex,submeshes:[]Submesh,outlines:Mesh_Outlines,out_vertices:^[dynamic]asset.Vertex,out_indices:^[dynamic]u32,out_skin:^[dynamic]asset.Skin_Vertex,out_lods:^[dynamic]Lod,out_submeshes:^[dynamic]Submesh,out_sources:^[dynamic]u32,pruned,dag:^bool) {
    temp:=context.temp_allocator
    outlines:=outlines
    if len(outlines.rungs)!=len(outlines.cards)*(OUTLINE_RUNGS-1) {outlines={}}
    // The vertices of level 0 followed by those of the coarser outlines of its cards.
    every:=vertices
    if len(outlines.cards)>0 {
        every=make([]asset.Vertex,len(vertices)+len(outlines.vertices),temp)
        copy(every,vertices)
        copy(every[len(vertices):],outlines.vertices)
    }
    offset:=u32(len(vertices))
    positions,attributes,protect:=asset.mesh_simplify_inputs(every)
    weights:=asset.MESH_SIMPLIFY_WEIGHTS
    // The submesh of each vertex of level 0; NONE outside all of them.
    owner:=make([]u32,len(vertices),temp)
    for &submesh in owner {submesh=NONE}
    for submesh,at in submeshes {
        for index in indices[submesh.first_index:][:submesh.index_count] {
            if owner[index]==NONE {owner[index]=u32(at)}
        }
    }
    // The islands that are pruned, and the triangles that are simplified.
    islands:[]Island
    classes:[]Island_Class
    island_triangles,island_of:[]u32
    rest:=indices
    islands,classes,island_triangles,island_of=levels_islands(positions[:len(vertices)],indices,submeshes,outlines.cards,temp)
    if len(islands)>0 {
        pruned^=true
        others:=make([dynamic]u32,0,len(indices),temp)
        for i,t in island_of {
            if i==NONE {append(&others,..indices[t*3:][:3])}
        }
        rest=others[:]
    } else if len(skin)==0 {
        dag^=true
        return
    }
    // What each outline of each island draws, summed before each; an island that is not a card draws its own.
    sums:Island_Sums
    for rung in 0..<OUTLINE_RUNGS {
        sums.area[rung]=make([]f32,len(islands)+1,temp)
        sums.triangles[rung]=make([]u32,len(islands)+1,temp)
    }
    drawn:=make([dynamic]u32,temp)
    for &class in classes {
        class.rungs=1
        for i in islands[class.first:][:class.count] {
            if i.card==NONE {continue}
            class.rungs=OUTLINE_RUNGS
            class.errors[0]=max(class.errors[0],outlines.cards[i.card].error)
            for rung in 1..<OUTLINE_RUNGS {
                class.errors[rung]=max(class.errors[rung],class.errors[rung-1],outlines.rungs[int(i.card)*(OUTLINE_RUNGS-1)+rung-1].error)
            }
        }
    }
    for i,at in islands {
        for rung in 0..<OUTLINE_RUNGS {
            clear(&drawn)
            island_rung(outlines,i,u32(rung),island_triangles,indices,offset,&drawn)
            area:f32
            for t:=0;t+2<len(drawn);t+=3 {
                p0,p1,p2:=positions[drawn[t]],positions[drawn[t+1]],positions[drawn[t+2]]
                area+=0.5*vec_length(vec_cross(p1-p0,p2-p0))
            }
            sums.area[rung][at+1]=sums.area[rung][at]+area
            sums.triangles[rung][at+1]=sums.triangles[rung][at]+u32(len(drawn)/3)
        }
    }
    // Where each class is: the outline its islands draw, then how many times it has been halved.
    state:=make([]u32,len(classes),temp)
    // Level 0 is as far from what the masks keep as its outlines draw.
    allowed:f32
    for class in classes {allowed=max(allowed,class.errors[0])}
    out_lods[0].error=allowed
    // A level whose error passes the radius of the mesh would be drawn only where all of it is within a pixel.
    low,high:=positions[0],positions[0]
    for p in positions[:len(vertices)] {low,high=geom.Vec3{min(low.x,p.x),min(low.y,p.y),min(low.z,p.z)},geom.Vec3{max(high.x,p.x),max(high.y,p.y),max(high.z,p.z)}}
    radius:=0.5*vec_length(high-low)

    simplified:=make([]u32,len(indices),temp)
    // Of each triangle of the level: its corners (of level 0, or of an outline past it) and its island, NONE for none.
    level_corners:=make([dynamic]u32,0,len(indices),temp)
    level_islands:=make([dynamic]u32,0,len(indices)/3,temp)
    grow_of:=make([]f32,len(islands),temp)
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
        // Each class goes as far as the error allowed lets it; where the level would keep too much
        // of the one before, it is allowed the least more that moves one more class.
        allowed=max(allowed,error)
        for {
            kept:=len(level_corners)/3
            next:=max(f32)
            for class,c in classes {
                last:=class_state_max(class,&sums)
                for state[c]<last && class_error(class,state[c]+1,&sums)<=allowed {state[c]+=1}
                kept+=int(class_triangles(class,state[c],&sums))
                if state[c]<last {next=min(next,class_error(class,state[c]+1,&sums))}
            }
            // A class with no finite error (a damaged mesh) allows nothing more: next is not above allowed.
            if !(next>allowed) || next==max(f32) || f32(kept)<=LOD_KEEP*f32(previous) {break}
            allowed=next
        }
        for class,c in classes {
            rung,depth:=class_step(class,state[c])
            keep:=class_keep(class,depth)
            grow:=class_grow(class,depth,&sums)
            error=max(error,class_error(class,state[c],&sums))
            for i,at in islands[class.first:][:keep] {
                grow_of[int(class.first)+at]=grow
                before:=len(level_corners)
                island_rung(outlines,i,rung,island_triangles,indices,offset,&level_corners)
                for _ in 0..<(len(level_corners)-before)/3 {append(&level_islands,class.first+u32(at))}
            }
        }
        kept:=len(level_corners)/3
        if kept==0 || f32(kept)>LOD_KEEP*f32(previous) || error>radius {break}
        previous=kept
        level:=Lod{first_index=u32(len(out_indices)),first_vertex=u32(len(out_vertices)),first_submesh=u32(len(out_submeshes)),error=error}
        for &at in local {at=NONE}
        // Triangles in the order of the submeshes, so each is one range of the level; an island is of the submesh of its first triangle.
        resize(&order,kept)
        for &f in first {f=0}
        group_of :: proc(owner,level_corners,level_islands:[]u32,islands:[]Island,island_triangles,indices:[]u32,groups,t:int) -> u32 {
            corner:=level_corners[t*3]
            if i:=level_islands[t];i!=NONE {corner=indices[island_triangles[islands[i].first]*3]}
            return min(owner[corner],u32(groups-1))
        }
        for t in 0..<kept {first[group_of(owner,level_corners[:],level_islands[:],islands,island_triangles,indices,groups,t)+1]+=1}
        for g in 1..=groups {first[g]+=first[g-1]}
        copy(next,first[:groups])
        for t in 0..<kept {
            g:=group_of(owner,level_corners[:],level_islands[:],islands,island_triangles,indices,groups,t)
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
                    if i:=level_islands[t];i!=NONE {position=islands[i].center+(position-islands[i].center)*grow_of[i]}
                    if local[source]==NONE {
                        local[source]=u32(len(out_vertices))
                        vertex:=every[source]
                        vertex.position=position
                        append(out_vertices,vertex)
                        if len(skin)>0 {append(out_skin,skin[source])}
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
