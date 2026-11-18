package asset

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:std/geom"
import mm "mirai:std/math"

// The constructor of the geometry of a mesh: importers and the meshes made at
// run time go through it, on any thread. It encodes clusters (mesh_encode)
// that a clusterizer made of the triangles of a Mesh_Source.

// A mesh as importers and generators give it: full vertices and what goes
// with each of them.
Mesh_Source :: struct {
    vertices:[]Vertex,     // material: the row of slots
    skin:[]Skin_Vertex,    // empty, or one per vertex
    surfaces:[]Surface_Vertex, // empty, or one per vertex: a far mesh (Has_Surface)
    morphs:[]Morph_Target, // their deltas name vertices
    morph_deltas:[]Morph_Delta,
    flags:Mesh_Flags,      // Has_Colors and Has_Uv1: the streams kept
    locked:[]bool,         // empty, or one per vertex: the levels of mesh_build_dag keep it where it is, as on a border another mesh shares
}

// A cluster before it is encoded: triangles of one slot, as indices of the
// vertices of a Mesh_Source, and where it is in the levels and the DAG.
Cluster_Source :: struct {
    first_index,index_count:u32, // of the indices given with the clusters
    slot:u32,
    level:u32,
    group:u32,     // the clusters that share its parent, contiguous: below the count of clusters
    generator:u32, // the group it was simplified from, of the level before; geom.NONE: none
    lod:[4]f32,                  // as Cluster
    error:f32,
    parent:[4]f32,
    parent_error:f32,
}

// A level of a mesh given whole: a range of its indices, finest first.
Level_Source :: struct {
    first_index,index_count:u32,
    error:f32, // bound of its error against level 0, in the space of the mesh
}

// What the simplifier weighs of the attributes of a vertex against its place,
// which it scales to an extent of 1: the normal (x, y, z), then the uv.
MESH_SIMPLIFY_WEIGHTS :: [5]f32{0.5,0.5,0.5,1,1}

// What the simplifier takes of the vertices of a mesh: their positions,
// their attributes (MESH_SIMPLIFY_WEIGHTS) and Protect where Permissive must
// keep a seam: where vertices at one place differ in anything but the normal
// (uv, uv1, color, material or the sign of the tangent).
mesh_simplify_inputs :: proc(vertices:[]Vertex) -> (positions:[]geom.Vec3,attributes:[]f32,protect:[]geom.Simplify_Vertex) {
    WEIGHTS :: len(MESH_SIMPLIFY_WEIGHTS)
    positions=make([]geom.Vec3,len(vertices),context.temp_allocator)
    attributes=make([]f32,len(vertices)*WEIGHTS,context.temp_allocator)
    for vertex,at in vertices {
        positions[at]=vertex.position
        normal:=mm.normal_unpack(vertex.normal)
        copy(attributes[at*WEIGHTS:],[]f32{normal.x,normal.y,normal.z,vertex.uv.x,vertex.uv.y})
    }
    welds:=make([]u32,len(vertices),context.temp_allocator)
    geom.positions_weld(positions,0,welds)
    protect=make([]geom.Simplify_Vertex,len(vertices),context.temp_allocator)
    for first,at in welds {
        a,b:=vertices[at],vertices[first]
        if a.uv!=b.uv || a.uv1!=b.uv1 || a.color!=b.color || a.material!=b.material || (a.tangent~b.tangent)&(1<<30)!=0 {
            protect[at]={.Protect}
            protect[first]={.Protect}
        }
    }
    return
}

// The triangles of indices by slot, the slot of each the material of its
// first vertex, in the order they come within a slot: a range of out a slot,
// appended to ranges as submesh slot.
@(private="file")
slot_ranges :: proc(vertices:[]Vertex,indices:[]u32,out:^[dynamic]u32,ranges:^[dynamic]geom.Cluster_Range) {
    slots:u64
    for t:=0;t+2<len(indices);t+=3 {slots|=1<<(u64(vertices[indices[t]].material)&63)}
    for slot in 0..<u32(64) {
        if slots&(1<<u64(slot))==0 {continue}
        first:=u32(len(out))
        for t:=0;t+2<len(indices);t+=3 {
            if vertices[indices[t]].material==slot {append(out,indices[t],indices[t+1],indices[t+2])}
        }
        append(ranges,geom.Cluster_Range{first,u32(len(out))-first,slot})
    }
}

// The clusters of a DAG as mesh_encode takes them: their triangles as
// indices of the mesh, the clusters of each level after those of the levels
// before, and within a level the groups nothing replaces last, so the root
// that must hold them takes as few others as it can.
@(private="file")
dag_sources :: proc(dag:^geom.Cluster_Dag,clusters:^[dynamic]Cluster_Source,indices:^[dynamic]u32) {
    for level in 0..<u32(max(dag.levels,1)) {for roots in ([]bool{false,true}) {
        for c in dag.clusters {
            if c.level!=level || (c.parent.error==CLUSTER_ROOT)!=roots {continue}
            source:=Cluster_Source{first_index=u32(len(indices)),index_count=c.triangle_count*3,slot=c.submesh,level=level,group=c.group,generator=c.generator}
            source.lod={c.own.center.x,c.own.center.y,c.own.center.z,c.own.radius}
            source.parent={c.parent.center.x,c.parent.center.y,c.parent.center.z,c.parent.radius}
            source.error,source.parent_error=c.own.error,c.parent.error
            for corner in dag.triangles[c.first_triangle*3:][:c.triangle_count*3] {append(indices,dag.vertices[c.first_vertex+u32(corner)])}
            append(clusters,source)
        }
    }}
}

// The geometry of a mesh of whole levels (geom.cluster_levels_build): level
// 0 alone, or several (Levels: a skinned mesh, foliage pruned by islands)
// whose clusters share the sphere of the mesh, so a view picks one of them.
// Every triangle is of the slot its first vertex names. What it returns is in
// allocator; false for indices outside the vertices or without memory.
mesh_build :: proc(source:Mesh_Source,indices:[]u32,levels:[]Level_Source,out:^Mesh_Geometry,allocator:=context.allocator) -> bool {
    whole:=[1]Level_Source{{index_count=u32(len(indices))}}
    given:=levels if len(levels)>0 else whole[:]
    if len(given)>MESH_MAX_LEVELS {return false}
    for level in given {
        if level.index_count==0 || level.index_count%3!=0 || u64(level.first_index)+u64(level.index_count)>u64(len(indices)) || !finite(level.error) || level.error<0 {return false}
    }
    for index in indices {if int(index)>=len(source.vertices) {return false}}
    for v in source.vertices {if v.material>=MESH_MAX_SLOTS {return false}}
    if !vertices_finite(source) {return false}
    scratch:=context.temp_allocator
    ordered:=make([dynamic]u32,0,len(indices),scratch)
    ranges:=make([dynamic]geom.Cluster_Range,scratch)
    cluster_levels:=make([]geom.Cluster_Level,len(given),scratch)
    for level,at in given {
        first:=u32(len(ranges))
        slot_ranges(source.vertices,indices[level.first_index:][:level.index_count],&ordered,&ranges)
        cluster_levels[at]={first,u32(len(ranges))-first,level.error}
    }
    positions:=make([]geom.Vec3,len(source.vertices),scratch)
    for v,at in source.vertices {positions[at]=v.position}
    dag:geom.Cluster_Dag
    defer geom.cluster_dag_destroy(&dag)
    if geom.cluster_levels_build(&dag,positions,ordered[:],ranges[:],cluster_levels,scratch)!=.None {return false}
    clusters:=make([dynamic]Cluster_Source,scratch)
    cluster_indices:=make([dynamic]u32,scratch)
    dag_sources(&dag,&clusters,&cluster_indices)
    flagged:=source
    if len(given)>1 {flagged.flags+={.Levels}}
    return mesh_encode(flagged,clusters[:],cluster_indices[:],out,allocator)
}

// The geometry of a static mesh as a DAG of clusters (geom.cluster_dag_build):
// level 0 in clusters, groups of them simplified with their borders locked
// and split again, up to the roots, and the cuts its rays trace far away
// (mesh_ray_errors). Every triangle is of the slot its first vertex names,
// and a vertex is of one slot. What it returns is in allocator; false for
// indices outside the vertices, a vertex of two slots or without memory.
mesh_build_dag :: proc(source:Mesh_Source,indices:[]u32,out:^Mesh_Geometry,allocator:=context.allocator) -> bool {
    if len(indices)==0 || len(indices)%3!=0 {return false}
    for index in indices {if int(index)>=len(source.vertices) {return false}}
    for v in source.vertices {if v.material>=MESH_MAX_SLOTS {return false}}
    if !vertices_finite(source) {return false}
    scratch:=context.temp_allocator
    ordered:=make([dynamic]u32,0,len(indices),scratch)
    ranges:=make([dynamic]geom.Cluster_Range,scratch)
    slot_ranges(source.vertices,indices,&ordered,&ranges)
    positions,attributes,protect:=mesh_simplify_inputs(source.vertices)
    if len(source.locked)==len(source.vertices) {
        for locked,at in source.locked {if locked {protect[at]+={.Lock}}}
    }
    weights:=MESH_SIMPLIFY_WEIGHTS
    dag:geom.Cluster_Dag
    defer geom.cluster_dag_destroy(&dag)
    built:=geom.cluster_dag_build(&dag,{positions=positions,indices=ordered[:],ranges=ranges[:],attributes=attributes,attribute_weights=weights[:],vertex_lock=protect},scratch)
    if built!=.None || dag.levels>MESH_MAX_LEVELS {return false}
    clusters:=make([dynamic]Cluster_Source,scratch)
    cluster_indices:=make([dynamic]u32,scratch)
    dag_sources(&dag,&clusters,&cluster_indices)
    flagged:=source
    flagged.flags-={.Levels}
    if !mesh_encode(flagged,clusters[:],cluster_indices[:],out,allocator) {return false}
    mesh_ray_errors(out)
    return true
}

// Whether the places and uvs of the vertices are numbers: any finite ones
// fit the grids of mesh_encode.
vertices_finite :: proc(source:Mesh_Source) -> bool {
    uv1:=.Has_Uv1 in source.flags
    for v in source.vertices {
        if !finite(v.position.x,v.position.y,v.position.z,v.uv.x,v.uv.y) || uv1 && !finite(v.uv1.x,v.uv1.y) {return false}
    }
    return true
}

// The finest power of two whose CLUSTER_GRID steps cover extent, coarse
// enough that reach takes fewer than 2^30 of them.
@(private="file")
grid_step :: proc "contextless" (extent:f64,reach:f32) -> f32 {
    need:=max(extent/f64(CLUSTER_GRID-2),f64(reach)/f64(1<<30),1e-12)
    return f32(math.pow(2,math.ceil(math.log2(need))))
}

// The step of the grid nearest value, short of those past the largest f32.
@(private="file")
on_grid :: proc "contextless" (value,step:f32) -> i32 {
    limit:=math.floor(f64(max(f32))/f64(step))
    return i32(clamp(math.round(f64(value)/f64(step)),-limit,limit))
}

// Encodes clusters: those of each level after the levels before them, each
// with up to CLUSTER_TRIANGLES triangles of one slot (below MESH_MAX_SLOTS)
// and CLUSTER_VERTICES vertices, the clusters of a group contiguous. Their
// vertices are copied into each cluster that names them, on grids of the
// whole mesh; their skin and the deltas of their targets go with them. The
// clusters go in pages (mesh_pages_assign). What it returns is in allocator;
// false for clusters out of those bounds or without memory.
mesh_encode :: proc(source:Mesh_Source,clusters:[]Cluster_Source,indices:[]u32,out:^Mesh_Geometry,allocator:=context.allocator) -> bool {
    scratch:=context.temp_allocator
    count:=len(source.vertices)
    if len(clusters)==0 || len(source.skin)!=0 && len(source.skin)!=count || len(source.surfaces)!=0 && len(source.surfaces)!=count {return false}
    if !vertices_finite(source) {return false}
    for c,at in clusters {
        if c.index_count==0 || c.index_count%3!=0 || c.index_count/3>CLUSTER_TRIANGLES || c.slot>=MESH_MAX_SLOTS || c.level>=MESH_MAX_LEVELS {return false}
        if u64(c.first_index)+u64(c.index_count)>u64(len(indices)) || at>0 && c.level<clusters[at-1].level {return false}
        if int(c.group)>=len(clusters) || c.generator!=geom.NONE && int(c.generator)>=len(clusters) {return false}
        if at>0 && c.group==clusters[at-1].group && c.level!=clusters[at-1].level {return false}
        if !finite(c.lod.x,c.lod.y,c.lod.z,c.lod.w,c.error,c.parent.x,c.parent.y,c.parent.z,c.parent.w) || c.error<0 || !(c.parent_error>=c.error) {return false}
        for index in indices[c.first_index:][:c.index_count] {if int(index)>=count {return false}}
    }

    // The vertices of each cluster, in the order its triangles first name them.
    stamp:=make([]u32,count,scratch)
    local:=make([]u8,count,scratch)
    origins:=make([dynamic]u32,0,len(indices),scratch) // the vertex of the source of each vertex of the mesh
    corners:=make([dynamic]u8,0,len(indices),scratch)
    firsts:=make([]u32,len(clusters)+1,scratch)
    if count>0 && (stamp==nil || local==nil) || firsts==nil {return false}
    for &s in stamp {s=max(u32)}
    for c,at in clusters {
        firsts[at]=u32(len(origins))
        for index in indices[c.first_index:][:c.index_count] {
            if stamp[index]!=u32(at) {
                if u32(len(origins))-firsts[at]>=CLUSTER_VERTICES {return false}
                stamp[index]=u32(at)
                local[index]=u8(u32(len(origins))-firsts[at])
                if _,error:=append(&origins,index);error!=nil {return false}
            }
            if _,error:=append(&corners,local[index]);error!=nil {return false}
        }
    }
    firsts[len(clusters)]=u32(len(origins))

    // The grids: as fine as the widest cluster lets 16 bits span.
    extent,uv_extent,uv1_extent:f64 // a difference of f32 can pass the largest one
    reach,uv_reach,uv1_reach:f32
    for c,at in clusters {
        low,high:=[3]f32{max(f32),max(f32),max(f32)},[3]f32{-max(f32),-max(f32),-max(f32)}
        uv_low,uv_high:=[2]f32{max(f32),max(f32)},[2]f32{-max(f32),-max(f32)}
        uv1_low,uv1_high:=uv_low,uv_high
        for origin in origins[firsts[at]:firsts[at+1]] {
            v:=source.vertices[origin]
            low,high=linalg.min(low,v.position),linalg.max(high,v.position)
            uv_low,uv_high=linalg.min(uv_low,v.uv),linalg.max(uv_high,v.uv)
            uv1_low,uv1_high=linalg.min(uv1_low,v.uv1),linalg.max(uv1_high,v.uv1)
        }
        size:=linalg.array_cast(high,f64)-linalg.array_cast(low,f64)
        uv_size:=linalg.array_cast(uv_high,f64)-linalg.array_cast(uv_low,f64)
        uv1_size:=linalg.array_cast(uv1_high,f64)-linalg.array_cast(uv1_low,f64)
        extent=max(extent,size.x,size.y,size.z)
        uv_extent=max(uv_extent,uv_size.x,uv_size.y)
        uv1_extent=max(uv1_extent,uv1_size.x,uv1_size.y)
        reach=max(reach,abs(low.x),abs(low.y),abs(low.z),abs(high.x),abs(high.y),abs(high.z))
        uv_reach=max(uv_reach,abs(uv_low.x),abs(uv_low.y),abs(uv_high.x),abs(uv_high.y))
        uv1_reach=max(uv1_reach,abs(uv1_low.x),abs(uv1_low.y),abs(uv1_high.x),abs(uv1_high.y))
    }
    g:Mesh_Geometry
    g.flags=source.flags&{.Has_Colors,.Has_Uv1,.Levels}
    if len(source.surfaces)>0 {g.flags+={.Has_Colors,.Has_Surface}}
    g.position_step,g.uv_step,g.uv1_step=grid_step(extent,reach),grid_step(uv_extent,uv_reach),grid_step(uv1_extent,uv1_reach)

    vertex_total:=len(origins)
    error:mem.Allocator_Error
    encoded:=false
    defer if !encoded {mesh_geometry_delete(&g,allocator)}
    g.clusters,error=make([]Cluster,len(clusters),allocator);if error!=nil {return false}
    g.vertices,error=make([]Cluster_Vertex,vertex_total,allocator);if error!=nil {return false}
    if .Has_Uv1 in g.flags {g.uv1s,error=make([]u32,vertex_total,allocator);if error!=nil {return false}}
    if .Has_Colors in g.flags {g.colors,error=make([]u32,vertex_total,allocator);if error!=nil {return false}}
    if .Has_Surface in g.flags {g.surfaces,error=make([]Surface_Vertex,vertex_total,allocator);if error!=nil {return false}}
    if len(source.skin)>0 {g.skin,error=make([]Skin_Vertex,vertex_total,allocator);if error!=nil {return false}}
    words:u32
    for c in clusters {words+=(c.index_count+3)/4}
    g.triangles,error=make([]u32,words,allocator);if error!=nil {return false}

    words=0
    at_corner:=0
    for c,at in clusters {
        first,last:=firsts[at],firsts[at+1]
        out_c:=&g.clusters[at]
        lo:=[3]i32{max(i32),max(i32),max(i32)}
        hi:=[3]i32{min(i32),min(i32),min(i32)}
        uv_lo,uv1_lo:=[2]i32{max(i32),max(i32)},[2]i32{max(i32),max(i32)}
        for origin in origins[first:last] {
            v:=source.vertices[origin]
            for axis in 0..<3 {
                q:=on_grid(v.position[axis],g.position_step)
                lo[axis],hi[axis]=min(lo[axis],q),max(hi[axis],q)
            }
            for axis in 0..<2 {
                uv_lo[axis]=min(uv_lo[axis],on_grid(v.uv[axis],g.uv_step))
                uv1_lo[axis]=min(uv1_lo[axis],on_grid(v.uv1[axis],g.uv1_step))
            }
        }
        out_c.position,out_c.vertex_first,out_c.uv=lo,first,uv_lo
        if .Has_Uv1 in g.flags {out_c.uv1=uv1_lo}
        size:=hi-lo
        for axis in 0..<3 {if size[axis]>CLUSTER_GRID {return false}}
        out_c.size_xy=u32(size.x)|u32(size.y)<<16
        out_c.size_z_cone=u32(size.z)
        for origin,i in origins[first:last] {
            v:=source.vertices[origin]
            q:[3]u32
            for axis in 0..<3 {q[axis]=u32(on_grid(v.position[axis],g.position_step)-lo[axis])}
            u:=u32(on_grid(v.uv.x,g.uv_step)-uv_lo.x)
            w:=u32(on_grid(v.uv.y,g.uv_step)-uv_lo.y)
            if u>CLUSTER_GRID || w>CLUSTER_GRID {return false}
            tangent,sign:=mm.tangent_unpack(v.tangent)
            angle:=mm.tangent_angle_pack(v.normal,tangent,sign)
            g.vertices[first+u32(i)]={xy=q.x|q.y<<16,z_u=q.z|u<<16,v_tangent=w|u32(angle)<<16,normal=v.normal}
            if .Has_Uv1 in g.flags {
                u1:=u32(on_grid(v.uv1.x,g.uv1_step)-uv1_lo.x)
                w1:=u32(on_grid(v.uv1.y,g.uv1_step)-uv1_lo.y)
                if u1>CLUSTER_GRID || w1>CLUSTER_GRID {return false}
                g.uv1s[first+u32(i)]=u1|w1<<16
            }
            if .Has_Colors in g.flags {g.colors[first+u32(i)]=v.color}
            if .Has_Surface in g.flags {g.surfaces[first+u32(i)]=source.surfaces[origin]}
            if len(source.skin)>0 {g.skin[first+u32(i)]=source.skin[origin]}
        }
        triangles:=c.index_count/3
        out_c.counts=(last-first-1)|triangles<<8|c.slot<<16
        out_c.triangle_first=words
        for k in 0..<c.index_count {
            g.triangles[words+k/4]|=u32(corners[at_corner+int(k)])<<(k%4*8)
        }
        at_corner+=int(c.index_count)
        words+=(c.index_count+3)/4
        out_c.lod,out_c.error,out_c.parent,out_c.parent_error=c.lod,c.error,c.parent,c.parent_error
        cluster_cone(&g,out_c)
    }

    g.bounds_min,g.bounds_max={max(f32),max(f32),max(f32)},{-max(f32),-max(f32),-max(f32)}
    for c in g.clusters {
        low,high:=cluster_box(g.position_step,c)
        g.bounds_min,g.bounds_max=linalg.min(g.bounds_min,low),linalg.max(g.bounds_max,high)
    }
    if !mesh_levels_count(&g,clusters,allocator) || !mesh_morphs_follow(&g,source,origins[:],allocator) {return false}
    whole:=len(source.skin)>0 || len(source.morphs)>0 || .Levels in g.flags
    if !mesh_pages_assign(&g,clusters,whole,allocator) {return false}
    if mesh_closed(g) {g.flags+={.Closed}}
    out^=g
    encoded=true
    return true
}

// The cone of the normals of the triangles of a cluster, when it is narrower
// than a half space: its axis, octahedral in snorm8, and the sine of how far
// its normals spread from it, rounded up so the test that leaves out a
// cluster seen from behind stays conservative.
@(private="file")
cluster_cone :: proc(g:^Mesh_Geometry,c:^Cluster) {
    normals:[CLUSTER_TRIANGLES][3]f32
    sum:[3]f32
    count:=0
    for t in 0..<cluster_triangle_count(c^) {
        corners:=cluster_triangle(g.triangles,c^,t)
        a,b,d:=cluster_position(g^,c^,corners[0]),cluster_position(g^,c^,corners[1]),cluster_position(g^,c^,corners[2])
        n:=linalg.cross(b-a,d-a)
        length:=linalg.length(n)
        if !(length>1e-20) {continue}
        normals[count]=n/length
        sum+=normals[count]
        count+=1
    }
    if count==0 || linalg.length(sum)<1e-6 {return}
    axis:=mm.octahedral_encode(linalg.normalize(sum))
    packed:=[2]i8{mm.snorm8_pack(axis.x),mm.snorm8_pack(axis.y)}
    stored:=mm.octahedral_decode({mm.snorm8_unpack(packed.x),mm.snorm8_unpack(packed.y)})
    least:=f32(1)
    for n in normals[:count] {least=min(least,linalg.dot(stored,n))}
    if least<=0 {return}
    cutoff:=math.ceil(math.sqrt(max(1-least*least,0))*127)
    if cutoff>=127 {return}
    c.size_z_cone|=u32(u8(packed.x))<<16|u32(u8(packed.y))<<24
    c.counts|=CLUSTER_CONE|u32(u8(i8(cutoff)))<<24
}

// The pages of the clusters of g: within a level, whole groups while their
// blocks fit in MESH_PAGE_WORDS, and a new page past that; a group larger
// than a page (a level given whole) goes in runs that fill pages, and no
// cluster can name it as its generator. Then the root (Mesh_Info.root_page):
// all of it for a whole mesh, else the levels from the coarsest while they
// fit in MESH_ROOT_WORDS, at least the coarsest, and from the first cluster
// nothing replaces on. False for groups that come apart or a generator that
// is not a group before.
@(private="file")
mesh_pages_assign :: proc(g:^Mesh_Geometry,sources:[]Cluster_Source,whole:bool,allocator:=context.allocator) -> bool {
    page_of_group:=make([]u32,len(sources),context.temp_allocator)
    split:=make([]bool,len(sources),context.temp_allocator)
    if page_of_group==nil || split==nil {return false}
    for &page in page_of_group {page=MESH_PAGE_NONE}
    pages:=make([dynamic]Mesh_Page,allocator)
    words :: proc(g:^Mesh_Geometry,c:Cluster) -> u32 {return mesh_page_layout(g.flags,cluster_vertex_count(c),cluster_triangle_words(c)).words}
    add :: proc(g:^Mesh_Geometry,pages:^[dynamic]Mesh_Page,at:int,level:u32,fresh:bool) -> bool {
        c:=&g.clusters[at]
        if fresh {
            if _,error:=append(pages,Mesh_Page{first_cluster=u32(at),first_vertex=c.vertex_first,first_triangle=c.triangle_first,level=level});error!=nil {return false}
        }
        page:=&pages[len(pages)-1]
        page.cluster_count+=1
        page.vertex_count+=cluster_vertex_count(c^)
        page.triangle_words+=cluster_triangle_words(c^)
        page.words=mesh_page_layout(g.flags,page.vertex_count,page.triangle_words).words
        c.page=u32(len(pages)-1)
        return true
    }
    level:u32
    for first:=0;first<len(sources); {
        group:=sources[first].group
        if page_of_group[group]!=MESH_PAGE_NONE || split[group] {delete(pages);return false}
        if first>0 && sources[first].level!=sources[first-1].level {level+=1}
        end:=first+1
        size:=words(g,g.clusters[first])
        for end<len(sources) && sources[end].group==group {
            size+=words(g,g.clusters[end])
            end+=1
        }
        fits:=size<=MESH_PAGE_WORDS
        split[group]=!fits
        for at in first..<end {
            fresh:=true
            if len(pages)>0 && pages[len(pages)-1].level==level {
                need:=size if fits else words(g,g.clusters[at])
                fresh=pages[len(pages)-1].words+need>MESH_PAGE_WORDS
            }
            if fits && at>first {fresh=false}
            if !add(g,&pages,at,level,fresh) {delete(pages);return false}
        }
        if fits {page_of_group[group]=g.clusters[first].page}
        first=end
    }
    for &c,at in g.clusters {
        c.child_page=MESH_PAGE_NONE
        generator:=sources[at].generator
        if generator==geom.NONE {continue}
        if split[generator] || page_of_group[generator]==MESH_PAGE_NONE || page_of_group[generator]>=c.page {delete(pages);return false}
        c.child_page=page_of_group[generator]
    }
    g.pages=pages[:]
    g.root_page=0
    if whole {return true}
    root:=u32(len(pages))
    total:u32
    for root>0 {
        first:=root
        size:u32
        for first>0 && pages[first-1].level==pages[root-1].level {
            first-=1
            size+=pages[first].words
        }
        if root<u32(len(pages)) && total+size>MESH_ROOT_WORDS {break}
        total+=size
        root=first
    }
    for c in g.clusters {
        if c.parent_error==CLUSTER_ROOT {
            root=min(root,c.page)
            break
        }
    }
    g.root_page=root
    return true
}

// The levels of the clusters, which come in their order: a level of the
// sources is a run of them, and the numbers they skip are no level.
@(private="file")
mesh_levels_count :: proc(g:^Mesh_Geometry,sources:[]Cluster_Source,allocator:=context.allocator) -> bool {
    levels,no_levels:=make([dynamic]Mesh_Level,0,MESH_MAX_LEVELS,allocator)
    if no_levels!=nil {return false}
    for c,at in g.clusters {
        if at==0 || sources[at].level!=sources[at-1].level {
            if _,error:=append(&levels,Mesh_Level{first_cluster=u32(at),error=c.error,parent_error=c.parent_error});error!=nil {return false}
        }
        level:=&levels[len(levels)-1]
        level.cluster_count+=1
        level.triangle_count+=cluster_triangle_count(c)
        level.error=min(level.error,c.error)
        level.parent_error=max(level.parent_error,c.parent_error)
    }
    g.levels=levels[:]
    return true
}

// The deltas of each target follow the vertices of the clusters: a vertex
// copied into several clusters moves in each of them, quantized on the step
// of the largest. False for ranges out of the deltas, a vertex out of the
// source or an amount that is not finite.
@(private="file")
mesh_morphs_follow :: proc(g:^Mesh_Geometry,source:Mesh_Source,origins:[]u32,allocator:=context.allocator) -> bool {
    if len(source.morphs)==0 {return true}
    for target in source.morphs {
        if u64(target.first)+u64(target.count)>u64(len(source.morph_deltas)) {return false}
    }
    largest:f32
    for d in source.morph_deltas {
        if !finite(d.position.x,d.position.y,d.position.z,d.normal.x,d.normal.y,d.normal.z,d.tangent.x,d.tangent.y,d.tangent.z) {return false}
        largest=max(largest,abs(d.position.x),abs(d.position.y),abs(d.position.z))
    }
    g.morph_step=morph_step(largest)
    error:mem.Allocator_Error
    g.morphs,error=make([]Morph_Target,len(source.morphs),allocator);if error!=nil {return false}
    deltas,no_deltas:=make([dynamic]Morph_Cluster_Delta,0,len(source.morph_deltas),allocator)
    if no_deltas!=nil {return false}
    followed:=false
    defer if !followed {delete(deltas)}
    lookup:=make([]i32,len(source.vertices),context.temp_allocator)
    if len(source.vertices)>0 && lookup==nil {return false}
    for &at in lookup {at=-1}
    for target,t in source.morphs {
        given:=source.morph_deltas[target.first:][:target.count]
        for delta,i in given {
            if int(delta.vertex)>=len(lookup) {return false}
            lookup[delta.vertex]=i32(i)
        }
        g.morphs[t]=target
        g.morphs[t].first=u32(len(deltas))
        for origin,v in origins {
            if at:=lookup[origin];at>=0 {
                moved:=morph_quantize(given[at],g.morph_step)
                moved.vertex=u32(v)
                if _,failed:=append(&deltas,moved);failed!=nil {return false}
            }
        }
        g.morphs[t].count=u32(len(deltas))-g.morphs[t].first
        for delta in given {lookup[delta.vertex]=-1}
    }
    g.morph_deltas=deltas[:]
    followed=true
    return true
}

// Whether level 0 is closed: welded by place, every edge of a triangle is
// the edge of one other, which runs it the other way.
@(private="file")
mesh_closed :: proc(g:Mesh_Geometry) -> bool {
    if len(g.levels)==0 {return false}
    Place :: [3]i32
    Edge :: [2]u32
    ids:=make(map[Place]u32,context.temp_allocator)
    edges:=make(map[Edge]i32,context.temp_allocator)
    range:=g.levels[0]
    for c in g.clusters[range.first_cluster:][:range.cluster_count] {
        for t in 0..<cluster_triangle_count(c) {
            corners:=cluster_triangle(g.triangles,c,t)
            welded:[3]u32
            for corner,k in corners {
                v:=g.vertices[c.vertex_first+corner]
                place:=c.position+{i32(v.xy&0xffff),i32(v.xy>>16),i32(v.z_u&0xffff)}
                id,known:=ids[place]
                if !known {id=u32(len(ids));ids[place]=id}
                welded[k]=id
            }
            if welded[0]==welded[1] || welded[1]==welded[2] || welded[0]==welded[2] {continue}
            for k in 0..<3 {
                edge:=Edge{welded[k],welded[(k+1)%3]}
                edges[edge]+=1
            }
        }
    }
    if len(edges)==0 {return false}
    for edge,uses in edges {
        if uses!=1 || edges[{edge[1],edge[0]}]!=1 {return false}
    }
    return true
}

// The cuts of the DAG of a mesh rays trace far away: the first whose
// triangles drop to a quarter of those of level 0, then to a sixteenth and a
// sixty-fourth. A cut at an error takes the clusters whose error is within it
// and whose parent's is not. None for whole levels or a small mesh.
//
// The coarsest cut is of the root alone, which is always resident: a cut at
// e takes c when c.error <= e < c.parent_error, so it takes no cluster out of
// the root once e reaches the greatest parent error among them (finite: the
// root holds every cluster nothing replaces). When the cuts fall short of it,
// one more is added there, or the last is raised to it.
mesh_ray_errors :: proc(g:^Mesh_Geometry) {
    g.ray_errors={}
    made:=0
    if .Levels not_in g.flags && len(g.levels)>=2 && g.levels[0].triangle_count>=4*CLUSTER_TRIANGLES {
        whole:=f32(g.levels[0].triangle_count)
        share:=f32(0.25)
        for level in g.levels[1:] {
            if made==len(g.ray_errors) {break}
            e:=level.error
            if e<=0 || made>0 && e<=g.ray_errors[made-1] {continue}
            triangles:u32
            for c in g.clusters {if c.error<=e && c.parent_error>e {triangles+=cluster_triangle_count(c)}}
            if f32(triangles)>share*whole {continue}
            g.ray_errors[made]=e
            made+=1
            share*=0.25
        }
    }
    if g.root_page==0 || int(g.root_page)>=len(g.pages) {return}
    need:=f32(math.F32_MIN)
    for c in g.clusters[:g.pages[g.root_page].first_cluster] {need=max(need,c.parent_error)}
    if made>0 && g.ray_errors[made-1]>=need {return}
    g.ray_errors[min(made,len(g.ray_errors)-1)]=need
}

// Frees the geometry mesh_build or mesh_build_dag made, with the allocator
// they were given.
mesh_geometry_delete :: proc(g:^Mesh_Geometry,allocator:=context.allocator) {
    delete(g.clusters,allocator);delete(g.levels,allocator);delete(g.vertices,allocator)
    delete(g.uv1s,allocator);delete(g.colors,allocator);delete(g.surfaces,allocator);delete(g.skin,allocator)
    delete(g.triangles,allocator);delete(g.pages,allocator);delete(g.page_data,allocator);delete(g.morphs,allocator);delete(g.morph_deltas,allocator)
    g^={}
}
