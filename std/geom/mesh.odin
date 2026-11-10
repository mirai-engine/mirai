package geom

import "base:runtime"
import "core:math"

// Triangle list over plain slices. normals, uvs and colors are either empty
// or as long as positions; materials is either empty or one slot per triangle.
Mesh :: struct {
    positions:[]Vec3,
    normals:  []Vec3,
    uvs:      []Vec2,
    colors:   []Vec4,
    indices:  []u32,
    materials:[]u32,
}

// Growable storage for a Mesh. Operations that write a mesh clear the buffer
// first unless they say they append, and reuse its memory between calls.
Mesh_Buffer :: struct {
    positions:[dynamic]Vec3,
    normals:  [dynamic]Vec3,
    uvs:      [dynamic]Vec2,
    colors:   [dynamic]Vec4,
    indices:  [dynamic]u32,
    materials:[dynamic]u32,
}

mesh_buffer_init :: proc(b:^Mesh_Buffer,allocator:=context.allocator) {
    b.positions=make([dynamic]Vec3,allocator)
    b.normals=make([dynamic]Vec3,allocator)
    b.uvs=make([dynamic]Vec2,allocator)
    b.colors=make([dynamic]Vec4,allocator)
    b.indices=make([dynamic]u32,allocator)
    b.materials=make([dynamic]u32,allocator)
}

mesh_buffer_destroy :: proc(b:^Mesh_Buffer) {
    delete(b.positions);delete(b.normals);delete(b.uvs);delete(b.colors);delete(b.indices);delete(b.materials)
    b^={}
}

mesh_buffer_clear :: proc(b:^Mesh_Buffer) {
    clear(&b.positions);clear(&b.normals);clear(&b.uvs);clear(&b.colors);clear(&b.indices);clear(&b.materials)
}

mesh_buffer_view :: proc(b:^Mesh_Buffer) -> Mesh {
    return {b.positions[:],b.normals[:],b.uvs[:],b.colors[:],b.indices[:],b.materials[:]}
}

mesh_triangle_count :: proc(mesh:Mesh) -> int {return len(mesh.indices)/3}

// The three corners of the triangle at t are vertices of n.
@(private)
triangle_in :: #force_inline proc "contextless" (indices:[]u32,t,n:int) -> bool {
    return int(indices[t])<n && int(indices[t+1])<n && int(indices[t+2])<n
}

// Streams have consistent lengths and every index refers to a vertex.
mesh_is_valid :: proc(mesh:Mesh) -> bool {
    n:=len(mesh.positions)
    if len(mesh.indices)%3!=0 {return false}
    if len(mesh.normals)!=0 && len(mesh.normals)!=n {return false}
    if len(mesh.uvs)!=0 && len(mesh.uvs)!=n {return false}
    if len(mesh.colors)!=0 && len(mesh.colors)!=n {return false}
    if len(mesh.materials)!=0 && len(mesh.materials)!=len(mesh.indices)/3 {return false}
    for i in mesh.indices {if int(i)>=n {return false}}
    return true
}

mesh_bounds :: proc(positions:[]Vec3) -> (lo,hi:Vec3) {
    if len(positions)==0 {return}
    lo=positions[0];hi=positions[0]
    for p in positions[1:] {
        lo={min(lo.x,p.x),min(lo.y,p.y),min(lo.z,p.z)}
        hi={max(hi.x,p.x),max(hi.y,p.y),max(hi.z,p.z)}
    }
    return
}

// remap[i] is the lowest index whose position is within `tolerance` of
// positions[i] (equal when tolerance is 0), searched among the vertices that
// are their own representative. Returns the number of representatives; a
// remap of another length is not written, and gives 0, as it is without
// temporary memory.
positions_weld :: proc(positions:[]Vec3,tolerance:f32,remap:[]u32) -> int #no_bounds_check {
    if len(remap)!=len(positions) {return 0}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    count:=0
    cells:Key_Map
    key_map_init(&cells,context.temp_allocator)
    next,no_next:=make([]u32,len(positions),context.temp_allocator)
    if no_next!=nil || key_map_reset(&cells,len(positions))!=nil {return 0}
    if !(tolerance>0) {
        for p,i in positions {
            key:=position_hash(p)
            if key==KEY_EMPTY {key=0}
            head,inserted:=key_map_entry(&cells,key,u32(i))
            if inserted {remap[i]=u32(i);next[i]=NONE;count+=1;continue}
            found:=NONE
            last:=head^
            for r:=head^;r!=NONE;r=next[r] {
                last=r
                if positions[r]==p {found=r;break}
            }
            if found!=NONE {remap[i]=found;continue}
            remap[i]=u32(i);next[i]=NONE;next[last]=u32(i);count+=1
        }
        return count
    }
    cell_of :: proc "contextless" (x:f32,inverse:f64) -> i64 {
        return i64(clamp(math.floor(f64(x)*inverse),-4e18,4e18))
    }
    cell_key :: proc "contextless" (x,y,z:i64) -> u64 {
        key:=hash_u64(hash_u64(hash_u64(u64(x))~u64(y))~u64(z))
        return 0 if key==KEY_EMPTY else key
    }
    inverse:=1/f64(tolerance)
    limit:=f64(tolerance)*f64(tolerance)
    for p,i in positions {
        cx,cy,cz:=cell_of(p.x,inverse),cell_of(p.y,inverse),cell_of(p.z,inverse)
        found:=NONE
        for dz in i64(-1)..=1 {for dy in i64(-1)..=1 {for dx in i64(-1)..=1 {
            head,ok:=key_map_find(&cells,cell_key(cx+dx,cy+dy,cz+dz))
            if !ok {continue}
            for r:=head;r!=NONE;r=next[r] {
                if r>=found {continue}
                d:=dvec(positions[r])-dvec(p)
                if ddot(d,d)<=limit {found=r}
            }
        }}}
        if found!=NONE {remap[i]=found;continue}
        remap[i]=u32(i);count+=1
        head,inserted:=key_map_entry(&cells,cell_key(cx,cy,cz),u32(i))
        if inserted {next[i]=NONE} else {next[i]=head^;head^=u32(i)}
    }
    return count
}

// Writes the mesh with the vertices that `positions_weld` merges collapsed to
// their representative, without unreferenced vertices or triangles that lost a
// corner. With keep_seams, vertices only merge when their normal, uv and color
// are also equal, so attribute seams survive. An index out of range writes an
// empty mesh. False, with an empty mesh, without memory.
mesh_weld :: proc(mesh:Mesh,tolerance:f32,out:^Mesh_Buffer,keep_seams:=false) -> bool {
    mesh_buffer_clear(out)
    n:=len(mesh.positions)
    for i in mesh.indices {
        if int(i)>=n {return true}
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(out.positions.allocator))
    remap,no_remap:=make([]u32,n,context.temp_allocator)
    first,no_first:=make([]u32,n,context.temp_allocator)
    target,no_target:=make([]u32,n,context.temp_allocator)
    chain,no_chain:=make([dynamic]u32,0,n,context.temp_allocator)
    if no_remap!=nil || no_first!=nil || no_target!=nil || no_chain!=nil {return false}
    positions_weld(mesh.positions,tolerance,remap)
    for i in 0..<n {first[i]=NONE;target[i]=NONE}
    has_normals,has_uvs,has_colors:=len(mesh.normals)==n,len(mesh.uvs)==n,len(mesh.colors)==n
    has_materials:=len(mesh.materials)==len(mesh.indices)/3
    // A vertex of the mesh gives one of the weld at most, and a triangle one.
    roomy:=reserve(&out.positions,n)==nil && reserve(&out.indices,len(mesh.indices))==nil
    roomy&&=!has_normals || reserve(&out.normals,n)==nil
    roomy&&=!has_uvs || reserve(&out.uvs,n)==nil
    roomy&&=!has_colors || reserve(&out.colors,n)==nil
    roomy&&=!has_materials || reserve(&out.materials,len(mesh.indices)/3)==nil
    if !roomy {return false}
    resolve :: proc(mesh:Mesh,out:^Mesh_Buffer,i:u32,remap,first,target:[]u32,chain:^[dynamic]u32,keep_seams,has_normals,has_uvs,has_colors:bool) -> u32 {
        if target[i]!=NONE {return target[i]}
        r:=remap[i]
        for v:=first[r];v!=NONE;v=chain[v] {
            if keep_seams {
                if has_normals && out.normals[v]!=mesh.normals[i] {continue}
                if has_uvs && out.uvs[v]!=mesh.uvs[i] {continue}
                if has_colors && out.colors[v]!=mesh.colors[i] {continue}
            }
            target[i]=v
            return v
        }
        v:=u32(len(out.positions))
        source:=i if keep_seams else r
        append(&out.positions,mesh.positions[r])
        if has_normals {append(&out.normals,mesh.normals[source])}
        if has_uvs {append(&out.uvs,mesh.uvs[source])}
        if has_colors {append(&out.colors,mesh.colors[source])}
        append(chain,first[r])
        first[r]=v
        target[i]=v
        return v
    }
    for t:=0;t+2<len(mesh.indices);t+=3 {
        ia,ib,ic:=mesh.indices[t],mesh.indices[t+1],mesh.indices[t+2]
        if remap[ia]==remap[ib] || remap[ib]==remap[ic] || remap[ia]==remap[ic] {continue}
        a:=resolve(mesh,out,ia,remap,first,target,&chain,keep_seams,has_normals,has_uvs,has_colors)
        b:=resolve(mesh,out,ib,remap,first,target,&chain,keep_seams,has_normals,has_uvs,has_colors)
        c:=resolve(mesh,out,ic,remap,first,target,&chain,keep_seams,has_normals,has_uvs,has_colors)
        append(&out.indices,a,b,c)
        if has_materials {append(&out.materials,mesh.materials[t/3])}
    }
    return true
}

// Area-weighted vertex normals. Vertices that share an index are smoothed;
// a vertex without area gets +Y.
mesh_compute_normals :: proc(positions:[]Vec3,indices:[]u32,normals:[]Vec3) {
    if len(normals)!=len(positions) {return}
    for &n in normals {n={}}
    for t:=0;t+2<len(indices);t+=3 {
        if !triangle_in(indices,t,len(positions)) {continue}
        a,b,c:=indices[t],indices[t+1],indices[t+2]
        pa:=dvec(positions[a])
        n:=fvec(dcross(dvec(positions[b])-pa,dvec(positions[c])-pa))
        normals[a]+=n;normals[b]+=n;normals[c]+=n
    }
    for &n in normals {n=fnormalize(n,{0,1,0})}
}

Mesh_Topology :: struct {
    boundary_edges:      int, // half-edges that no opposite half-edge matches
    non_manifold_edges:  int, // half-edges of an edge used more than once in one direction
    degenerate_triangles:int, // triangles with a repeated corner
    pinched_vertices:    int, // vertices whose triangles form more than one fan
}

// A closed two-manifold: every edge joins exactly two triangles that run it in
// opposite directions, and every vertex has a single fan.
mesh_topology_is_closed :: proc(t:Mesh_Topology) -> bool {
    return t.boundary_edges==0 && t.non_manifold_edges==0 && t.degenerate_triangles==0 && t.pinched_vertices==0
}

// Every half-edge is matched by an opposite one: the surface bounds a volume,
// even where it touches itself along an edge or at a vertex.
mesh_topology_is_watertight :: proc(t:Mesh_Topology) -> bool {return t.boundary_edges==0}

// Connectivity of a triangle list. With by_position, vertices with equal
// positions are one vertex, so attribute seams do not open the surface.
// adjacency, when given, has one entry per index: the half-edge (3*triangle +
// corner, from that corner to the next) opposite to each half-edge, or NONE.
mesh_topology :: proc(positions:[]Vec3,indices:[]u32,adjacency:[]u32=nil,by_position:=true) -> (topology:Mesh_Topology) #no_bounds_check {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    n:=len(indices)/3*3
    ids:=make([]u32,len(positions),context.temp_allocator)
    if by_position {positions_weld(positions,0,ids)} else {for &id,i in ids {id=u32(i)}}
    twin:=adjacency
    if len(twin)!=len(indices) {twin=make([]u32,len(indices),context.temp_allocator)}
    for &v in twin {v=NONE}
    Edge :: struct {first,count:u32}
    edges:=make([dynamic]Edge,0,n,context.temp_allocator)
    edge_of:=make([]u32,n,context.temp_allocator)
    directed:Key_Map
    key_map_init(&directed,context.temp_allocator)
    // Without temporary memory no half-edge finds its opposite: the mesh reads as open.
    if key_map_reset(&directed,n)!=nil {
        topology.boundary_edges=n
        return
    }
    degenerate:=make([]bool,n/3,context.temp_allocator)
    for t:=0;t<n;t+=3 {
        if !triangle_in(indices,t,len(positions)) {
            degenerate[t/3]=true
            topology.degenerate_triangles+=1
            edge_of[t]=NONE;edge_of[t+1]=NONE;edge_of[t+2]=NONE
            continue
        }
        a,b,c:=ids[indices[t]],ids[indices[t+1]],ids[indices[t+2]]
        if a==b || b==c || a==c {
            degenerate[t/3]=true
            topology.degenerate_triangles+=1
            edge_of[t]=NONE;edge_of[t+1]=NONE;edge_of[t+2]=NONE
            continue
        }
        corners:=[3]u32{a,b,c}
        for k in 0..<3 {
            entry,inserted:=key_map_entry(&directed,pair_key(corners[k],corners[(k+1)%3]),u32(len(edges)))
            if inserted {append(&edges,Edge{u32(t+k),0})}
            edges[entry^].count+=1
            edge_of[t+k]=entry^
        }
    }
    for t:=0;t<n;t+=3 {
        if degenerate[t/3] {continue}
        corners:=[3]u32{ids[indices[t]],ids[indices[t+1]],ids[indices[t+2]]}
        for k in 0..<3 {
            forward:=edges[edge_of[t+k]]
            reverse,found:=key_map_find(&directed,pair_key(corners[(k+1)%3],corners[k]))
            opposite:=edges[reverse].count if found else 0
            if forward.first==u32(t+k) && forward.count>opposite {topology.boundary_edges+=int(forward.count-opposite)}
            if forward.count>1 || opposite>1 {
                topology.non_manifold_edges+=1
            } else if found {
                twin[t+k]=edges[reverse].first
            }
        }
    }
    // A vertex is a single fan when walking around it through the opposite
    // half-edges reaches every triangle that uses it.
    incident:=make([]u32,len(positions),context.temp_allocator)
    corner_of:=make([]u32,len(positions),context.temp_allocator)
    for &c in corner_of {c=NONE}
    for t:=0;t<n;t+=3 {
        if degenerate[t/3] {continue}
        for k in 0..<3 {
            v:=ids[indices[t+k]]
            incident[v]+=1
            if corner_of[v]==NONE {corner_of[v]=u32(t+k)}
        }
    }
    for start,v in corner_of {
        if start==NONE {continue}
        visited:=u32(1)
        closed:=false
        c:=start
        for visited<=incident[v] {
            other:=twin[c]
            if other==NONE {break}
            c=other/3*3+(other%3+1)%3
            if c==start {closed=true;break}
            visited+=1
        }
        if !closed {
            c=start
            for visited<=incident[v] {
                other:=twin[c/3*3+(c%3+2)%3]
                if other==NONE {break}
                c=other
                visited+=1
            }
        }
        if visited!=incident[v] {topology.pinched_vertices+=1}
    }
    return
}

// Every edge is shared by exactly two triangles with opposite directions.
mesh_is_closed :: proc(positions:[]Vec3,indices:[]u32) -> bool {
    return len(indices)>=12 && mesh_topology_is_closed(mesh_topology(positions,indices))
}

// labels[t] is the component of triangle t; triangles that share a position
// are in the same component. Components are numbered by their first triangle.
// A triangle with an index out of range has none (NONE); labels of another
// length are not written, and give 0.
mesh_components :: proc(positions:[]Vec3,indices:[]u32,labels:[]u32) -> int #no_bounds_check {
    if len(labels)!=len(indices)/3 {return 0}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    parent:=make([]u32,len(positions),context.temp_allocator)
    positions_weld(positions,0,parent)
    find :: proc(parent:[]u32,v:u32) -> u32 #no_bounds_check {
        r:=v
        for parent[r]!=r {r=parent[r]}
        v:=v
        for parent[v]!=r {next:=parent[v];parent[v]=r;v=next}
        return r
    }
    for t:=0;t+2<len(indices);t+=3 {
        if !triangle_in(indices,t,len(positions)) {continue}
        a:=find(parent,indices[t])
        for k in 1..<3 {
            b:=find(parent,indices[t+k])
            if a==b {continue}
            if b<a {a,b=b,a}
            parent[b]=a
        }
    }
    label:=make([]u32,len(positions),context.temp_allocator)
    for &l in label {l=NONE}
    count:=0
    for t:=0;t+2<len(indices);t+=3 {
        if !triangle_in(indices,t,len(positions)) {
            labels[t/3]=NONE
            continue
        }
        root:=find(parent,indices[t])
        if label[root]==NONE {label[root]=u32(count);count+=1}
        labels[t/3]=label[root]
    }
    return count
}
