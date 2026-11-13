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
// the sign of the tangent) keep their outline. Every vertex of a level is a
// vertex of level 0 as it was, except those of islands.
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
    error:f32, // how far it is from level 0, in the space of the mesh; 0 for level 0
}

LOD_MIN_TRIANGLES :: 256 // a level with fewer triangles is the last
LOD_SHARE :: 0.25        // of the triangles of a level, what the next one aims at
LOD_KEEP :: 0.7          // a level that keeps more than this share of the one before is not stored
ISLAND_MAX_TRIANGLES :: 64 // a small island has at most this many triangles
ISLAND_MAX_SHARE :: 16     // and at most 1/16 of the triangles of its submesh
ISLANDS_MIN :: 16          // small islands a submesh of islands has at least
ISLAND_CLASSES :: 8        // octaves of radius the small islands of a submesh are split in; smaller ones join the last
ISLAND_PIXELS :: f32(1)    // of the threshold of the cut, how far the radius of a grown island may span where its level draws it
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
}

@(private="file")
NONE :: max(u32)

// Level 0 as given, followed by up to LOD_MAX-1 simplified levels.
// Each aims at LOD_SHARE of the triangles of the one before; the levels end
// with the first that cannot remove a share of them, or once one has fewer
// than LOD_MIN_TRIANGLES. Mesh_Lod.error is how far geom.simplify moved the
// surface of level 0 (its position error), in meters. With `simplify` false there is level 0 alone. indices are valid for vertices, and submeshes are ranges of
// indices: what asset.mesh_check asks. Everything returned is in `allocator`.
mesh_levels :: proc(vertices:[]asset.Vertex,indices:[]u32,skin:[]asset.Skin_Vertex,submeshes:[]Submesh,simplify:=true,allocator:=context.allocator,morphs:[]asset.Morph_Target=nil,morph_deltas:[]asset.Morph_Delta=nil) -> (levels:Mesh_Levels) {
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
    pruned:=false
    if simplify && len(indices)/3>=LOD_MIN_TRIANGLES && len(vertices)<1<<24 {
        levels_simplify(vertices,indices,skin,submeshes,&out_vertices,&out_indices,&out_skin,&out_lods,&out_submeshes,&sources if len(morphs)>0 else nil,0,LOD_MAX,&pruned)
    }
    levels={vertices=out_vertices[:],indices=out_indices[:],skin=out_skin[:],lods=out_lods[:],submeshes=out_submeshes[:],pruned=pruned}
    if len(morphs)>0 {levels.morphs,levels.morph_deltas=levels_morphs(len(vertices),morphs,morph_deltas,sources[:],allocator)}
    return
}

// The geometry of a mesh (asset.Mesh_Geometry) from its levels: the DAG of
// level 0 for a static mesh, or its whole levels when they are of a skinned
// one or prune islands (foliage), whose clusters share one sphere. flags: the
// streams it keeps. False where the constructor fails.
levels_geometry :: proc(levels:Mesh_Levels,flags:asset.Mesh_Flags,out:^asset.Mesh_Geometry,allocator:=context.allocator) -> bool {
    source:=asset.Mesh_Source{vertices=levels.vertices,skin=levels.skin,morphs=levels.morphs,morph_deltas=levels.morph_deltas,flags=flags}
    if len(levels.skin)==0 && !levels.pruned && len(levels.lods)>1 {
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
}

// The islands of a submesh of one octave of radius, islands[first:][:count].
@(private="file")
Island_Class :: struct {
    first,count:u32,
    largest:f32, // radius of its largest island
}

// The small islands of the submeshes of islands (see ISLAND_MAX_TRIANGLES)
// by class, ordered within each by a hash of their first triangle: a fixed
// order whose prefixes spread over the submesh. island is the island of each
// triangle of level 0, NONE outside them.
@(private="file")
levels_islands :: proc(positions:[]geom.Vec3,indices:[]u32,submeshes:[]Submesh,allocator:=context.allocator) -> (islands:[]Island,classes:[]Island_Class,triangles:[]u32,island:[]u32) {
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
        sizes:=make([]u32,count,context.temp_allocator)
        for l in labels {if l!=NONE {sizes[l]+=1}}
        small:=0
        for size in sizes {if island_small(size,sub_triangles) {small+=1}}
        island_first:=u32(len(found))
        if small<ISLANDS_MIN {continue}
        // The small islands in the order of their first triangle, and the triangles of each.
        number:=make([]u32,count,context.temp_allocator)
        for &n in number {n=NONE}
        starts:=make([dynamic]u32,0,small+1,context.temp_allocator)
        append(&starts,0)
        for l,t in labels {
            if l==NONE || !island_small(sizes[l],sub_triangles) || number[l]!=NONE {continue}
            number[l]=u32(len(found))-island_first
            order:=u64(first_triangle)+u64(t)
            append(&found,Island{order=base.splitmix_next(&order)})
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

@(private="file")
island_small :: #force_inline proc "contextless" (triangles,of:u32) -> bool {
    return triangles<=ISLAND_MAX_TRIANGLES && triangles*ISLAND_MAX_SHARE<=of
}

// The islands a class halved `depth` times keeps: the first of its order, one at least.
@(private="file")
class_keep :: #force_inline proc "contextless" (class:Island_Class,depth:u32) -> u32 {
    return max((class.count+(1<<depth)-1)>>depth,1)
}

// How many times a class can be halved before it keeps one island or its islands grow past ISLAND_GROW_MAX.
@(private="file")
class_depth_max :: proc "contextless" (class:Island_Class,area_before:[]f32) -> (depth:u32) {
    for class_keep(class,depth)>1 && class_grow(class,depth+1,area_before)<=ISLAND_GROW_MAX {depth+=1}
    return
}

// How much the islands a class keeps at `depth` grow, to the area all of them had.
@(private="file")
class_grow :: proc "contextless" (class:Island_Class,depth:u32,area_before:[]f32) -> f32 {
    all:=area_before[class.first+class.count]-area_before[class.first]
    kept:=area_before[class.first+class_keep(class,depth)]-area_before[class.first]
    return kept>0?math.sqrt(all/kept):1
}

// The error of a class halved `depth` times: the radius of its largest island grown, over ISLAND_PIXELS.
@(private="file")
class_error :: proc "contextless" (class:Island_Class,depth:u32,area_before:[]f32) -> f32 {
    return class.largest*class_grow(class,depth,area_before)/ISLAND_PIXELS
}

@(private="file")
vec_cross :: #force_inline proc "contextless" (a,b:geom.Vec3) -> geom.Vec3 {return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}}
@(private="file")
vec_length :: #force_inline proc "contextless" (a:geom.Vec3) -> f32 {return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z)}

// Appends levels to out_lods until it holds `limit`. The first aims at
// `target` triangles when it is above 0, simplifies everything and is kept
// however many it removes. The others prune the small islands of the
// submeshes of islands and simplify the rest.
@(private="file")
levels_simplify :: proc(vertices:[]asset.Vertex,indices:[]u32,skin:[]asset.Skin_Vertex,submeshes:[]Submesh,out_vertices:^[dynamic]asset.Vertex,out_indices:^[dynamic]u32,out_skin:^[dynamic]asset.Skin_Vertex,out_lods:^[dynamic]Lod,out_submeshes:^[dynamic]Submesh,out_sources:^[dynamic]u32,target:int,limit:int,pruned:^bool=nil) {
    temp:=context.temp_allocator
    positions,attributes,protect:=asset.mesh_simplify_inputs(vertices)
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
    if target==0 {
        islands,classes,island_triangles,island_of=levels_islands(positions,indices,submeshes,temp)
        if len(islands)>0 {
            if pruned!=nil {pruned^=true}
            others:=make([dynamic]u32,0,len(indices),temp)
            for i,t in island_of {
                if i==NONE {append(&others,..indices[t*3:][:3])}
            }
            rest=others[:]
        }
    }
    // Sums of the areas and triangles of the islands before each, for what a prefix of a class keeps.
    area_before:=make([]f32,len(islands)+1,temp)
    triangles_before:=make([]u32,len(islands)+1,temp)
    for i,at in islands {
        area_before[at+1]=area_before[at]+i.area
        triangles_before[at+1]=triangles_before[at]+i.count
    }
    // How many times each class has been halved.
    depth:=make([]u32,len(classes),temp)
    allowed:f32
    // A level whose error passes the radius of the mesh would be drawn only where all of it is within a pixel.
    low,high:=positions[0],positions[0]
    for p in positions {low,high=geom.Vec3{min(low.x,p.x),min(low.y,p.y),min(low.z,p.z)},geom.Vec3{max(high.x,p.x),max(high.y,p.y),max(high.z,p.z)}}
    radius:=0.5*vec_length(high-low)

    simplified:=make([]u32,len(indices),temp)
    // Of each triangle of the level: its corners (vertices of level 0) and its island, NONE for none.
    level_corners:=make([dynamic]u32,0,len(indices),temp)
    level_islands:=make([dynamic]u32,0,len(indices)/3,temp)
    grow_of:=make([]f32,len(islands),temp)
    local:=make([]u32,len(vertices),temp)
    // The triangles of the level by submesh, NONE last: those of group g are order[first[g]:first[g+1]].
    groups:=len(submeshes)+1
    order:=make([]u32,len(indices)/3,temp)
    first:=make([]u32,groups+1,temp)
    next:=make([]u32,groups,temp)
    previous,previous_rest:=len(indices)/3,len(rest)/3
    aimed:=target
    for k:=1;len(out_lods)<limit && previous>=LOD_MIN_TRIANGLES;k+=1 {
        clear(&level_corners);clear(&level_islands)
        error:f32
        if len(rest)>0 {
            aim:=aimed>0?aimed:int(f32(previous_rest)*LOD_SHARE)
            options:=geom.Simplify_Options{.Lock_Border,.Error_Absolute}
            result,failed:=geom.simplify(simplified,rest,positions,aim*3,max(f32),options,attributes,weights[:],protect)
            if failed==.None && result.index_count>aim*3 {
                result,failed=geom.simplify(simplified,rest,positions,aim*3,max(f32),options+{.Permissive},attributes,weights[:],protect)
            }
            if failed!=.None {break}
            append(&level_corners,..simplified[:result.index_count])
            for _ in 0..<result.index_count/3 {append(&level_islands,NONE)}
            error=result.position_error
            previous_rest=result.index_count/3
        }
        // Each class goes as deep as the error allowed lets its grown islands; where the level would
        // keep too much of the one before, it is allowed the least more that prunes one more class.
        allowed=max(allowed,error)
        for {
            kept:=len(level_corners)/3
            next:=max(f32)
            for class,c in classes {
                for depth[c]<class_depth_max(class,area_before) && class_error(class,depth[c]+1,area_before)<=allowed {depth[c]+=1}
                kept+=int(triangles_before[class.first+class_keep(class,depth[c])]-triangles_before[class.first])
                if depth[c]<class_depth_max(class,area_before) {next=min(next,class_error(class,depth[c]+1,area_before))}
            }
            // A class with no finite error (a damaged mesh) allows nothing more: next is not above allowed.
            if !(next>allowed) || next==max(f32) || aimed>0 || f32(kept)<=LOD_KEEP*f32(previous) {break}
            allowed=next
        }
        for class,c in classes {
            keep:=class_keep(class,depth[c])
            grow:=class_grow(class,depth[c],area_before)
            if depth[c]>0 {error=max(error,class_error(class,depth[c],area_before))}
            for i,at in islands[class.first:][:keep] {
                grow_of[int(class.first)+at]=grow
                for triangle in island_triangles[i.first:][:i.count] {
                    append(&level_corners,..indices[triangle*3:][:3])
                    append(&level_islands,class.first+u32(at))
                }
            }
        }
        kept:=len(level_corners)/3
        if kept==0 || aimed==0 && (f32(kept)>LOD_KEEP*f32(previous) || error>radius) {break}
        aimed=0
        previous=kept
        level:=Lod{first_index=u32(len(out_indices)),first_vertex=u32(len(out_vertices)),first_submesh=u32(len(out_submeshes)),error=error}
        for &at in local {at=NONE}
        // Triangles in the order of the submeshes, so each is one range of the level.
        for &f in first {f=0}
        for t in 0..<kept {first[min(owner[level_corners[t*3]],u32(groups-1))+1]+=1}
        for g in 1..=groups {first[g]+=first[g-1]}
        copy(next,first[:groups])
        for t in 0..<kept {
            g:=min(owner[level_corners[t*3]],u32(groups-1))
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
                        vertex:=vertices[source]
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
