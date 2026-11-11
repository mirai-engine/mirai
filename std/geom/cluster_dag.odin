package geom

import "base:runtime"

// The DAG of clusters of a mesh, made when it is cooked: a port of the
// builder of demo/clusterlod.h of meshoptimizer 1.3 (MIT, Arseny
// Kapoulkine) on simplify, meshlets_build and clusters_partition, after
// Karis, Nanite: a deep dive (2021).
//
// Level 0 is the mesh in clusters, those of each submesh apart. While a
// level has more than one cluster, its clusters are partitioned in groups;
// the triangles of each group are simplified to CLUSTER_SIMPLIFY_RATIO of
// them with the vertices it shares with other groups locked, and split again
// in clusters, which make the next level. A group whose simplification
// keeps more than CLUSTER_SIMPLIFY_STUCK of its triangles stops there. Where
// the seams of attributes stop the simplifier short of its target, it runs
// again with Permissive; the outlines between submeshes are protected, and
// vertex_lock protects the other seams that must stay.
//
// The error of a group is its own simplification error or that of its
// clusters, whichever is larger, in a sphere around theirs: both grow from
// the leaves to the roots, so the cut of clusters whose own error projects
// within a threshold and whose parent's does not is a whole surface, and
// the locked borders join its clusters without cracks. The places of a
// group that stops stay locked in every level above, since its clusters are
// drawn next to any of them.

CLUSTER_MAX_TRIANGLES :: 128
// Local indices are bytes. The renderer draws CLUSTER_MAX_TRIANGLES*3
// corners per cluster whatever its size, so a cluster should be full: with
// seams of attributes 128 triangles can need more than 128 vertices, and up
// to 256 keeps such clusters full.
CLUSTER_MAX_VERTICES :: 256
CLUSTER_MIN_TRIANGLES :: CLUSTER_MAX_TRIANGLES/3 // a cluster is cut where the next triangle is far only once it has this many
CLUSTER_SPLIT_FACTOR :: 2                       // far: beyond this many expected radii of a cluster
CLUSTER_GROUP_SIZE :: 16                        // clusters a group aims at; it may have a third more
CLUSTER_SIMPLIFY_RATIO :: 0.5
CLUSTER_SIMPLIFY_STUCK :: 0.85

// A sphere and the error of the geometry it bounds, both in the units of
// the positions: the cull projects the error at the nearest point of the
// sphere.
Cluster_Lod :: struct {center:Vec3,radius:f32,error:f32}

// A cluster: its vertices are Cluster_Dag.vertices[first_vertex:][:vertex_count],
// vertices of the mesh, and its triangles
// Cluster_Dag.triangles[first_triangle*3:][:triangle_count*3], indices into
// those. It is drawn where own projects within the threshold and parent does
// not: own is reached by this cluster (error 0 at level 0), parent by the
// group it belongs to, which every cluster of the group shares, with error
// max(f32) at a root. The clusters of a group are contiguous, and those of
// a level come after the levels before.
Cluster :: struct {
    first_vertex,vertex_count:u32,
    first_triangle,triangle_count:u32,
    bounds:Cluster_Bounds, // of its own triangles, for culling
    own,parent:Cluster_Lod,
    group:u32,     // the clusters that share its parent
    generator:u32, // the group it was simplified from, its children; NONE at level 0
    level:u32,
    submesh:u32,
}

Cluster_Dag :: struct {
    clusters:[dynamic]Cluster,
    vertices:[dynamic]u32,
    triangles:[dynamic]u8,
    groups:int,
    levels:int,
}

// The triangles of indices[first_index:][:index_count], all of submesh.
Cluster_Range :: struct {first_index,index_count,submesh:u32}

// What the DAG is built from. attributes and attribute_weights are those of
// simplify; vertex_lock, empty or one per vertex, adds its flags (Protect
// for the seams that Permissive must keep) to the locks of each level.
Cluster_Source :: struct {
    positions:[]Vec3,
    indices:[]u32,
    ranges:[]Cluster_Range, // the submeshes; a vertex is of one only
    attributes:[]f32,
    attribute_weights:[]f32,
    vertex_lock:[]Simplify_Vertex,
}

Cluster_Error :: enum u8 {None,Invalid_Mesh,Invalid_Attributes,Out_Of_Memory}

cluster_dag_destroy :: proc(dag:^Cluster_Dag) {
    delete(dag.clusters);delete(dag.vertices);delete(dag.triangles)
    dag^={}
}

// A cluster of a level being built: its mesh indices are
// indices[index_offset:][:index_count].
@(private="file")
Pending :: struct {
    index_offset,index_count:u32,
    own:Cluster_Lod,
    generator:u32, // the group it was simplified from, NONE at level 0
    submesh:u32,
}

@(private="file")
Dag_Builder :: struct {
    source:Cluster_Source,
    dag:^Cluster_Dag,
    // Of each vertex: where it is in the part meshlets_build is given, NONE elsewhere.
    local_of:[]u32,
    local_positions:[dynamic]Vec3,
    local_indices:[dynamic]u32,
    globals:[dynamic]u32,
    meshlets:[dynamic]Meshlet,
    meshlet_vertices:[dynamic]u32,
    meshlet_triangles:[dynamic]u8,
}

// Splits the triangles of indices (all of submesh) in clusters appended to
// pending, their indices to cluster_indices.
@(private="file")
clusterize :: proc(b:^Dag_Builder,indices:[]u32,submesh:u32,own:Cluster_Lod,generator:u32,pending:^[dynamic]Pending,cluster_indices:^[dynamic]u32) -> Cluster_Error #no_bounds_check {
    if len(indices)==0 {return .None}
    // The part numbered by first use, so the work is that of the part and not of the mesh.
    clear(&b.local_positions);clear(&b.globals)
    if resize(&b.local_indices,len(indices))!=nil {return .Out_Of_Memory}
    for index,i in indices {
        if b.local_of[index]==NONE {
            b.local_of[index]=u32(len(b.globals))
            _,no_global:=append(&b.globals,index)
            _,no_position:=append(&b.local_positions,b.source.positions[index])
            if no_global!=nil || no_position!=nil {return .Out_Of_Memory}
        }
        b.local_indices[i]=b.local_of[index]
    }
    for index in b.globals {b.local_of[index]=NONE}
    bound:=meshlets_bound(len(indices),CLUSTER_MAX_VERTICES,CLUSTER_MIN_TRIANGLES)
    if resize(&b.meshlets,bound)!=nil || resize(&b.meshlet_vertices,len(indices))!=nil || resize(&b.meshlet_triangles,len(indices))!=nil {return .Out_Of_Memory}
    count,failed:=meshlets_build(b.meshlets[:],b.meshlet_vertices[:],b.meshlet_triangles[:],b.local_indices[:],b.local_positions[:],CLUSTER_MAX_VERTICES,CLUSTER_MIN_TRIANGLES,CLUSTER_MAX_TRIANGLES,0,CLUSTER_SPLIT_FACTOR)
    if failed==.Out_Of_Memory {return .Out_Of_Memory}
    if failed!=.None {return .Invalid_Mesh}
    for meshlet in b.meshlets[:count] {
        offset:=u32(len(cluster_indices))
        for k in 0..<meshlet.triangle_count*3 {
            local:=b.meshlet_vertices[meshlet.vertex_offset+u32(b.meshlet_triangles[meshlet.triangle_offset+k])]
            if _,err:=append(cluster_indices,b.globals[local]);err!=nil {return .Out_Of_Memory}
        }
        if _,err:=append(pending,Pending{offset,meshlet.triangle_count*3,own,generator,submesh});err!=nil {return .Out_Of_Memory}
    }
    return .None
}

// Appends the clusters of a group to the DAG; returns its index. False
// without memory.
@(private="file")
group_output :: proc(b:^Dag_Builder,clusters:[]Pending,cluster_indices:[]u32,parent:Cluster_Lod,level:int) -> (group:u32,ok:bool) #no_bounds_check {
    dag:=b.dag
    group=u32(dag.groups)
    dag.groups+=1
    dag.levels=max(dag.levels,level+1)
    for c in clusters {
        indices:=cluster_indices[c.index_offset:][:c.index_count]
        cluster:=Cluster{
            first_vertex=u32(len(dag.vertices)),first_triangle=u32(len(dag.triangles)/3),triangle_count=c.index_count/3,
            bounds=cluster_bounds(indices,b.source.positions),own=c.own,parent=parent,group=group,generator=c.generator,level=u32(level),submesh=c.submesh,
        }
        vertices:[MESHLET_MAX_VERTICES]u32
        first_triangle:=len(dag.triangles)
        // Grown by doubling: resize takes exactly what it is asked for, and
        // an allocator that keeps what it gave (an importer's arena) would
        // keep a copy of every length the triangles ever had.
        if reserve_more(&dag.triangles,len(indices))!=nil || resize(&dag.triangles,first_triangle+len(indices))!=nil {return 0,false}
        count:=max(meshlet_local_indices(vertices[:],dag.triangles[first_triangle:],indices),0)
        cluster.vertex_count=u32(count)
        if _,error:=append(&dag.vertices,..vertices[:count]);error!=nil {return 0,false}
        if _,error:=append(&dag.clusters,cluster);error!=nil {return 0,false}
    }
    return group,true
}

@(private="file")
lod_merge :: proc(clusters:[]Pending,scratch:runtime.Allocator) -> (merged:Cluster_Lod,ok:bool) {
    centers,no_centers:=make([]Vec3,len(clusters),scratch)
    radii,no_radii:=make([]f32,len(clusters),scratch)
    if no_centers!=nil || no_radii!=nil {return}
    for c,i in clusters {
        centers[i],radii[i]=c.own.center,c.own.radius
        // As large as any of its clusters: the error never shrinks towards the roots.
        merged.error=max(merged.error,c.own.error)
    }
    merged.center,merged.radius=spheres_bound(centers,radii)
    return merged,true
}

@(private="file")
source_valid :: proc(source:Cluster_Source) -> Cluster_Error {
    vertex_count:=len(source.positions)
    if len(source.indices)%3!=0 || vertex_count>=int(NONE) || len(source.vertex_lock)!=0 && len(source.vertex_lock)!=vertex_count {return .Invalid_Mesh}
    for index in source.indices {
        if int(index)>=vertex_count || !finite3(source.positions[index]) {return .Invalid_Mesh}
    }
    for r in source.ranges {
        if r.index_count%3!=0 || r.first_index%3!=0 || int(r.first_index)+int(r.index_count)>len(source.indices) {return .Invalid_Mesh}
    }
    if len(source.attribute_weights)>SIMPLIFY_MAX_ATTRIBUTES || len(source.attributes)!=vertex_count*len(source.attribute_weights) {return .Invalid_Attributes}
    for w in source.attribute_weights {
        if !(w>=0) || w-w!=0 {return .Invalid_Attributes}
    }
    for a in source.attributes {
        if a-a!=0 {return .Invalid_Attributes}
    }
    return .None
}

// Builds the DAG of clusters of a mesh into dag (cleared first; its memory
// in allocator). The triangles of each range are clusters of its submesh; a
// vertex used by two ranges of different submeshes is Invalid_Mesh, since a
// simplified triangle takes the submesh of its vertices. Equal input gives
// an identical DAG. Scratch memory comes from context.temp_allocator. An
// error leaves the DAG empty.
cluster_dag_build :: proc(dag:^Cluster_Dag,source:Cluster_Source,allocator:=context.allocator) -> (error:Cluster_Error) #no_bounds_check {
    cluster_dag_destroy(dag)
    dag.clusters=make([dynamic]Cluster,allocator)
    dag.vertices=make([dynamic]u32,allocator)
    dag.triangles=make([dynamic]u8,allocator)
    defer if error!=.None {dag_empty(dag)}
    if failed:=source_valid(source);failed!=.None {return failed}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(allocator))
    scratch:=context.temp_allocator
    vertex_count:=len(source.positions)
    ranges:=source.ranges
    whole:=[1]Cluster_Range{{0,u32(len(source.indices)),0}}
    if len(ranges)==0 {ranges=whole[:]}

    // The submesh of each vertex.
    submesh_of:=make([]u32,vertex_count,scratch)
    if submesh_of==nil && vertex_count>0 {return .Out_Of_Memory}
    for &s in submesh_of {s=NONE}
    for r in ranges {
        for index in source.indices[r.first_index:][:r.index_count] {
            if submesh_of[index]!=NONE && submesh_of[index]!=r.submesh {return .Invalid_Mesh}
            submesh_of[index]=r.submesh
        }
    }
    // The first vertex at the position of each: the boundaries between groups are found by place.
    remap:=make([]u32,vertex_count,scratch)
    locks:=make([]Simplify_Vertex,vertex_count,scratch)
    b:=Dag_Builder{source=source,dag=dag}
    b.local_of=make([]u32,vertex_count,scratch)
    if (remap==nil || locks==nil || b.local_of==nil) && vertex_count>0 {return .Out_Of_Memory}
    positions_weld(source.positions,0,remap)
    // The outlines between submeshes stay, also with Permissive: no triangle takes vertices of two.
    for v in 0..<vertex_count {
        if submesh_of[v]!=submesh_of[remap[v]] {
            locks[v]+={.Protect}
            locks[remap[v]]+={.Protect}
        }
    }
    for &l in b.local_of {l=NONE}
    b.local_positions=make([dynamic]Vec3,scratch)
    b.local_indices=make([dynamic]u32,scratch)
    b.globals=make([dynamic]u32,scratch)
    b.meshlets=make([dynamic]Meshlet,scratch)
    b.meshlet_vertices=make([dynamic]u32,scratch)
    b.meshlet_triangles=make([dynamic]u8,scratch)

    clusters:=make([dynamic]Pending,scratch)
    cluster_indices:=make([dynamic]u32,scratch)
    for r in ranges {
        if failed:=clusterize(&b,source.indices[r.first_index:][:r.index_count],r.submesh,{},NONE,&clusters,&cluster_indices);failed!=.None {return failed}
    }
    // Level 0 is measured exactly; the levels above take the spheres of their groups, which keeps them growing.
    for &c in clusters {
        bounds:=cluster_bounds(cluster_indices[c.index_offset:][:c.index_count],source.positions)
        c.own={bounds.center,bounds.radius,0}
    }

    pending:=make([dynamic]Pending,scratch)
    pending_indices:=make([dynamic]u32,scratch)
    merged:=make([dynamic]u32,scratch)
    simplified:=make([dynamic]u32,scratch)
    by_submesh:=make([dynamic]u32,scratch)
    counts:=make([dynamic]u32,scratch)
    order:=make([dynamic]u32,scratch)
    group_of:=make([dynamic]u32,scratch)
    generators:=make([dynamic]u32,scratch)
    partition_indices:=make([dynamic]u32,scratch)
    sorted:=make([dynamic]Pending,scratch)
    seen:=make([]bool,vertex_count,scratch)
    // The places of the groups that stopped: their clusters stay drawn next to any level above.
    retired:=make([]bool,vertex_count,scratch)
    if (seen==nil || retired==nil) && vertex_count>0 {return .Out_Of_Memory}
    // A level and each of its groups take their scratch from an arena of
    // their own, let go after them: the temp allocator of the caller may be
    // one that frees nothing until it ends (an importer's), where the groups
    // of a mesh of millions of triangles would add up to tens of gigabytes.
    work:runtime.Arena
    defer runtime.arena_destroy(&work)
    depth:=0
    for len(clusters)>1 {
        level_temp:=runtime.arena_temp_begin(&work)
        defer runtime.arena_temp_end(level_temp)
        context.temp_allocator=runtime.arena_allocator(&work)
        // The groups of this level, as runs of sorted.
        group_count:=1
        if resize(&group_of,len(clusters))!=nil {return .Out_Of_Memory}
        if len(clusters)>CLUSTER_GROUP_SIZE {
            clear(&partition_indices)
            corners:=0
            for c in clusters {corners+=int(c.index_count)}
            if resize(&counts,len(clusters))!=nil || resize(&generators,len(clusters))!=nil || reserve(&partition_indices,corners)!=nil {return .Out_Of_Memory}
            for c,i in clusters {
                for index in cluster_indices[c.index_offset:][:c.index_count] {append(&partition_indices,remap[index])}
                counts[i]=c.index_count
                generators[i]=c.generator
            }
            count,failed:=clusters_partition(group_of[:],partition_indices[:],counts[:],source.positions,CLUSTER_GROUP_SIZE,generators[:])
            if failed==.Out_Of_Memory {return .Out_Of_Memory}
            if failed!=.None {return .Invalid_Mesh}
            group_count=count
        } else {
            for &g in group_of {g=0}
        }
        offsets:=make([]u32,group_count+1,context.temp_allocator)
        if offsets==nil {return .Out_Of_Memory}
        for g in group_of {offsets[g+1]+=1}
        for g in 0..<group_count {offsets[g+1]+=offsets[g]}
        if resize(&sorted,len(clusters))!=nil || resize(&order,group_count)!=nil {return .Out_Of_Memory}
        copy(order[:],offsets[:group_count])
        for c,i in clusters {
            sorted[order[group_of[i]]]=c
            order[group_of[i]]+=1
        }

        // A place used by more than one group, or by one that stopped, is locked; vertex_lock and Protect stay.
        for &l,v in locks {
            if retired[v] {l+={.Lock}} else {l-={.Lock}}
        }
        for &s in seen {s=false}
        for g in 0..<group_count {
            group:=sorted[offsets[g]:offsets[g+1]]
            for c in group {
                for index in cluster_indices[c.index_offset:][:c.index_count] {
                    if seen[remap[index]] {locks[remap[index]]+={.Lock}}
                }
            }
            for c in group {
                for index in cluster_indices[c.index_offset:][:c.index_count] {seen[remap[index]]=true}
            }
        }
        for v in 0..<vertex_count {
            l:=locks[v]-{.Lock}
            if .Lock in locks[remap[v]] {l+={.Lock}}
            if len(source.vertex_lock)>0 {l+=source.vertex_lock[v]}
            locks[v]=l
        }

        clear(&pending);clear(&pending_indices)
        for g in 0..<group_count {
            group_temp:=runtime.arena_temp_begin(&work)
            defer runtime.arena_temp_end(group_temp)
            group:=sorted[offsets[g]:offsets[g+1]]
            clear(&merged)
            corners:=0
            for c in group {corners+=int(c.index_count)}
            if reserve(&merged,corners)!=nil {return .Out_Of_Memory}
            for c in group {append(&merged,..cluster_indices[c.index_offset:][:c.index_count])}
            target:=int(f32(len(merged)/3)*CLUSTER_SIMPLIFY_RATIO)*3
            bounds,bounded:=lod_merge(group,context.temp_allocator)
            if !bounded || resize(&simplified,len(merged))!=nil {return .Out_Of_Memory}
            options:=Simplify_Options{.Sparse,.Error_Absolute}
            result,failed:=simplify(simplified[:],merged[:],source.positions,target,max(f32),options,source.attributes,source.attribute_weights,locks)
            if failed==.None && result.index_count>target {
                result,failed=simplify(simplified[:],merged[:],source.positions,target,max(f32),options+{.Permissive},source.attributes,source.attribute_weights,locks)
            }
            if failed==.Out_Of_Memory {return .Out_Of_Memory}
            if failed!=.None {return .Invalid_Mesh}
            // Nothing is left empty: a group that loses every triangle keeps its first.
            if result.index_count==0 && len(merged)>0 {
                copy(simplified[:3],merged[:3])
                result.index_count=3
            }
            if f32(result.index_count)>f32(len(merged))*CLUSTER_SIMPLIFY_STUCK {
                // Stuck: the group is a root.
                bounds.error=max(f32)
                for c in group {
                    for index in cluster_indices[c.index_offset:][:c.index_count] {retired[remap[index]]=true}
                }
                if _,written:=group_output(&b,group[:],cluster_indices[:],bounds,depth);!written {return .Out_Of_Memory}
                continue
            }
            bounds.error=max(bounds.error,result.position_error)
            id,written:=group_output(&b,group[:],cluster_indices[:],bounds,depth)
            if !written {return .Out_Of_Memory}
            // The triangles that remain, by submesh, each split in clusters of the next level.
            kept:=simplified[:result.index_count]
            if resize(&by_submesh,len(kept))!=nil {return .Out_Of_Memory}
            first:=0
            for first<len(kept) {
                submesh:=submesh_of[kept[first]]
                n:=0
                for t:=first;t<len(kept);t+=3 {
                    if submesh_of[kept[t]]==submesh {
                        copy(by_submesh[n:n+3],kept[t:t+3])
                        n+=3
                    }
                }
                if failed:=clusterize(&b,by_submesh[:n],submesh,bounds,id,&pending,&pending_indices);failed!=.None {return failed}
                // The next submesh not taken yet; taken triangles are marked by a repeated corner.
                for t:=first;t<len(kept);t+=3 {
                    if submesh_of[kept[t]]==submesh {kept[t+1]=kept[t];kept[t+2]=kept[t]}
                }
                for first<len(kept) && kept[first]==kept[first+1] && kept[first]==kept[first+2] {first+=3}
            }
        }
        clusters,pending=pending,clusters
        cluster_indices,pending_indices=pending_indices,cluster_indices
        depth+=1
    }
    if len(clusters)==1 {
        root:=clusters[0].own
        root.error=max(f32)
        if _,written:=group_output(&b,clusters[:],cluster_indices[:],root,depth);!written {return .Out_Of_Memory}
    }
    return .None
}

// Nothing of a DAG that did not end stays: its last group would be cut short.
@(private="file")
dag_empty :: proc(dag:^Cluster_Dag) {
    clear(&dag.clusters);clear(&dag.vertices);clear(&dag.triangles)
    dag.groups,dag.levels=0,0
}

// A discrete level of a mesh: its submeshes are ranges[first_range:][:range_count].
Cluster_Level :: struct {first_range,range_count:u32,error:f32}

// Builds clusters of discrete levels (skinned meshes, foliage) in the
// format of the DAG: level k is group k, and its clusters share the sphere
// of the mesh (level 0) as own and parent sphere, with the error of level k
// as own and that of level k+1 as parent (max(f32) for the last). Errors
// below that of the level before are raised to it. The cut of the DAG then
// draws one whole level. An error leaves the DAG empty.
cluster_levels_build :: proc(dag:^Cluster_Dag,positions:[]Vec3,indices:[]u32,ranges:[]Cluster_Range,levels:[]Cluster_Level,allocator:=context.allocator) -> (result:Cluster_Error) #no_bounds_check {
    cluster_dag_destroy(dag)
    dag.clusters=make([dynamic]Cluster,allocator)
    dag.vertices=make([dynamic]u32,allocator)
    dag.triangles=make([dynamic]u8,allocator)
    defer if result!=.None {dag_empty(dag)}
    if failed:=source_valid({positions=positions,indices=indices,ranges=ranges});failed!=.None {return failed}
    for level in levels {
        if int(level.first_range)+int(level.range_count)>len(ranges) || !(level.error>=0) {return .Invalid_Mesh}
    }
    if len(levels)==0 {return .None}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(allocator))
    scratch:=context.temp_allocator
    // The sphere of level 0.
    points:=make([dynamic]Vec3,scratch)
    for r in ranges[levels[0].first_range:][:levels[0].range_count] {
        for index in indices[r.first_index:][:r.index_count] {append(&points,positions[index])}
    }
    center,radius:=spheres_bound(points[:])
    b:=Dag_Builder{source={positions=positions,indices=indices},dag=dag}
    b.local_of=make([]u32,len(positions),scratch)
    if b.local_of==nil && len(positions)>0 {return .Out_Of_Memory}
    for &l in b.local_of {l=NONE}
    b.local_positions=make([dynamic]Vec3,scratch)
    b.local_indices=make([dynamic]u32,scratch)
    b.globals=make([dynamic]u32,scratch)
    b.meshlets=make([dynamic]Meshlet,scratch)
    b.meshlet_vertices=make([dynamic]u32,scratch)
    b.meshlet_triangles=make([dynamic]u8,scratch)
    clusters:=make([dynamic]Pending,scratch)
    cluster_indices:=make([dynamic]u32,scratch)
    work:runtime.Arena
    defer runtime.arena_destroy(&work)
    error:f32
    for level,k in levels {
        error=max(error,level.error)
        next:=max(f32)
        if k+1<len(levels) {next=max(error,levels[k+1].error)}
        clear(&clusters);clear(&cluster_indices)
        for r in ranges[level.first_range:][:level.range_count] {
            // The scratch of a range goes with it (cluster_dag_build says why).
            range_temp:=runtime.arena_temp_begin(&work)
            defer runtime.arena_temp_end(range_temp)
            context.temp_allocator=runtime.arena_allocator(&work)
            if failed:=clusterize(&b,indices[r.first_index:][:r.index_count],r.submesh,{center,radius,error},NONE,&clusters,&cluster_indices);failed!=.None {return failed}
        }
        if _,written:=group_output(&b,clusters[:],cluster_indices[:],{center,radius,next},k);!written {return .Out_Of_Memory}
    }
    return .None
}
