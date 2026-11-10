package geom

import "core:math"
import mm "mirai:std/math"
import "mirai:std/base"

// How a brush weakens from its center to its radius.
Falloff :: enum u8 {Smooth,Sphere,Linear,Sharp,Constant}

// The weight of a brush at t, the distance from its center over its radius:
// 1 up to hardness, 0 from 1 on.
falloff_weight :: proc "contextless" (falloff:Falloff,hardness,t:f32) -> f32 {
    if !(t<1) {return 0}
    x:=hardness<1?max(t-hardness,0)/(1-hardness):0
    switch falloff {
    case .Smooth:   return 1-x*x*(3-2*x)
    case .Sphere:   return math.sqrt(max(1-x*x,0))
    case .Linear:   return 1-x
    case .Sharp:    return (1-x)*(1-x)
    case .Constant: return 1
    }
    return 0
}

Mesh_Surface_Brush_Kind :: enum u8 {Sculpt,Smooth,Flatten,Drag}
Mesh_Surface_Brush :: struct {
    kind:Mesh_Surface_Brush_Kind,
    center,normal:Vec3,
    delta:Vec3,
    rotation:mm.Quat,
    radius,amount,hardness:f32,
    falloff:Falloff,
    lock_boundary:bool,
}

Mesh_Surface_Refine :: struct {
    center:Vec3,
    radius,max_edge_length:f32,
    max_triangles:int,
    lock_boundary:bool,
}

Mesh_Surface_Error :: enum u8 {None,Invalid_Mesh,Invalid_Brush,Out_Of_Memory,Budget_Exceeded,Aliased_Output}
Mesh_Surface_Result :: struct {changed:bool,vertices,triangles:int,low,high:Vec3}

Mesh_Surface_Workspace :: struct {
    initialized:bool,
    representatives,next,corner_edges:[dynamic]u32,
    sums:[dynamic]DVec3,
    counts:[dynamic]u32,
    locked:[dynamic]bool,
    edges:[dynamic]Surface_Edge,
    points,edge_map,midpoints:Key_Map,
}

@(private="file") Surface_Edge :: struct {a,b:u32,uses,forward:u32,split:bool}

mesh_surface_workspace_init :: proc(w:^Mesh_Surface_Workspace,allocator:=context.allocator) {
    w.initialized=true
    w.representatives=make([dynamic]u32,allocator)
    w.next=make([dynamic]u32,allocator)
    w.corner_edges=make([dynamic]u32,allocator)
    w.sums=make([dynamic]DVec3,allocator)
    w.counts=make([dynamic]u32,allocator)
    w.locked=make([dynamic]bool,allocator)
    w.edges=make([dynamic]Surface_Edge,allocator)
    key_map_init(&w.points,allocator);key_map_init(&w.edge_map,allocator);key_map_init(&w.midpoints,allocator)
}

mesh_surface_workspace_destroy :: proc(w:^Mesh_Surface_Workspace) {
    if w==nil {return}
    delete(w.representatives);delete(w.next);delete(w.corner_edges)
    delete(w.sums);delete(w.counts);delete(w.locked);delete(w.edges)
    key_map_destroy(&w.points);key_map_destroy(&w.edge_map);key_map_destroy(&w.midpoints)
    w^={}
}

@(private="file")
surface_map_reset :: proc(m:^Key_Map,expected:int) -> bool {
    return key_map_reset(m,expected)==nil
}

@(private="file")
surface_valid :: proc(mesh:Mesh) -> bool {
    if !mesh_is_valid(mesh) || len(mesh.positions)>int(max(u32))-1 || len(mesh.indices)>int(max(u32))-1 {return false}
    for p in mesh.positions {if !finite3(p) {return false}}
    for n in mesh.normals {if !finite3(n) {return false}}
    for uv in mesh.uvs {if !finite2(uv) {return false}}
    for c in mesh.colors {for v in c {if v-v!=0 {return false}}}
    return true
}

@(private="file")
surface_aliases :: proc(mesh:Mesh,out:^Mesh_Buffer) -> bool {
    overlaps :: proc(a,b:[]$T) -> bool {
        if len(a)==0 || len(b)==0 {return false}
        first,last:=uintptr(raw_data(a)),uintptr(raw_data(b))
        return first<last+uintptr(len(b)*size_of(T)) && last<first+uintptr(len(a)*size_of(T))
    }
    return overlaps(mesh.positions,out.positions[:]) || overlaps(mesh.normals,out.normals[:]) ||
        overlaps(mesh.positions,out.normals[:]) || overlaps(mesh.normals,out.positions[:]) ||
        overlaps(mesh.uvs,out.uvs[:]) || overlaps(mesh.colors,out.colors[:]) ||
        overlaps(mesh.indices,out.indices[:]) || overlaps(mesh.materials,out.materials[:]) ||
        overlaps(mesh.indices,out.materials[:]) || overlaps(mesh.materials,out.indices[:])
}

@(private="file")
surface_copy :: proc(mesh:Mesh,out:^Mesh_Buffer,extra_vertices,triangles:int) -> bool {
    n:=len(mesh.positions)+extra_vertices
    if n<0 || n>int(max(u32))-1 || triangles<0 || triangles>max(int)/3 {return false}
    if reserve(&out.positions,n)!=nil || reserve(&out.indices,triangles*3)!=nil {return false}
    if len(mesh.normals)>0 && reserve(&out.normals,n)!=nil {return false}
    if len(mesh.uvs)>0 && reserve(&out.uvs,n)!=nil {return false}
    if len(mesh.colors)>0 && reserve(&out.colors,n)!=nil {return false}
    if len(mesh.materials)>0 && reserve(&out.materials,triangles)!=nil {return false}
    append(&out.positions,..mesh.positions);append(&out.normals,..mesh.normals)
    append(&out.uvs,..mesh.uvs);append(&out.colors,..mesh.colors)
    return true
}

@(private="file")
surface_prepare :: proc(w:^Mesh_Surface_Workspace,mesh:Mesh) -> bool {
    n,corners:=len(mesh.positions),len(mesh.indices)
    if resize(&w.representatives,n)!=nil || resize(&w.next,n)!=nil || resize(&w.sums,n)!=nil ||
        resize(&w.counts,n)!=nil || resize(&w.locked,n)!=nil || resize(&w.corner_edges,corners)!=nil ||
        reserve(&w.edges,corners)!=nil || !surface_map_reset(&w.points,n) || !surface_map_reset(&w.edge_map,corners) {return false}
    clear(&w.edges)
    for p,i in mesh.positions {
        w.sums[i]={};w.counts[i]=0;w.locked[i]=false;w.next[i]=NONE
        key:=position_hash(p)
        if key==KEY_EMPTY {key=0}
        head,inserted:=key_map_entry(&w.points,key,u32(i))
        w.representatives[i]=u32(i)
        if inserted {continue}
        last:=head^
        for v:=head^;v!=NONE;v=w.next[v] {
            if mesh.positions[v]==p {w.representatives[i]=v;break}
            last=v
        }
        if w.representatives[i]==u32(i) {w.next[last]=u32(i)}
    }
    for t:=0;t<corners;t+=3 {
        for k in 0..<3 {
            a,b:=w.representatives[mesh.indices[t+k]],w.representatives[mesh.indices[t+(k+1)%3]]
            key:=pair_key(min(a,b),max(a,b))
            edge,inserted:=key_map_entry(&w.edge_map,key,u32(len(w.edges)))
            if inserted {append(&w.edges,Surface_Edge{a=min(a,b),b=max(a,b)})}
            w.corner_edges[t+k]=edge^
            w.edges[edge^].uses+=1
            if a<b {w.edges[edge^].forward+=1}
        }
    }
    for e in w.edges {
        w.sums[e.a]+=dvec(mesh.positions[e.b]);w.counts[e.a]+=1
        w.sums[e.b]+=dvec(mesh.positions[e.a]);w.counts[e.b]+=1
        if e.uses!=2 || e.forward!=1 {w.locked[e.a]=true;w.locked[e.b]=true}
    }
    return true
}

@(private="file")
surface_change :: proc(result:^Mesh_Surface_Result,a,b:Vec3) {
    if !result.changed {result.low=a;result.high=a;result.changed=true}
    for axis in 0..<3 {
        result.low[axis]=min(result.low[axis],a[axis],b[axis])
        result.high[axis]=max(result.high[axis],a[axis],b[axis])
    }
}

// The caller passes one selected region, including its halo for Smooth.
// Sculpt is a signed distance; Smooth and Flatten use a blend in [0,1].
mesh_surface_edit :: proc(w:^Mesh_Surface_Workspace,mesh:Mesh,brush:Mesh_Surface_Brush,out:^Mesh_Buffer) -> (result:Mesh_Surface_Result,error:Mesh_Surface_Error) {
    if out==nil {return {},.Invalid_Mesh}
    if surface_aliases(mesh,out) {return {},.Aliased_Output}
    mesh_buffer_clear(out)
    if w==nil || !w.initialized || !surface_valid(mesh) {return {},.Invalid_Mesh}
    if !finite3(brush.center) || !finite3(brush.normal) || !finite3(brush.delta) || !(brush.radius>0) || brush.radius-brush.radius!=0 ||
        brush.amount-brush.amount!=0 || !(brush.hardness>=0 && brush.hardness<1) || brush.kind>.Drag || brush.falloff>.Constant {return {},.Invalid_Brush}
    if brush.kind!=.Sculpt && (brush.amount<0 || brush.amount>1) {return {},.Invalid_Brush}
    normal:=dnormalize(dvec(brush.normal))
    if (brush.kind==.Sculpt || brush.kind==.Flatten) && ddot(normal,normal)==0 {return {},.Invalid_Brush}
    rotation:=brush.rotation
    for v in ([4]f32{rotation.x,rotation.y,rotation.z,rotation.w}) {if v-v!=0 {return {},.Invalid_Brush}}
    if rotation==0 {rotation=1}
    if abs(rotation.x)>1 || abs(rotation.y)>1 || abs(rotation.z)>1 || abs(rotation.w)>1 {return {},.Invalid_Brush}
    rotation=mm.quat_nlerp(1,rotation,1)
    neighbors:=brush.kind==.Smooth || brush.lock_boundary
    if neighbors && !surface_prepare(w,mesh) {return {},.Out_Of_Memory}
    if len(mesh.normals)>0 {
        if resize(&w.sums,len(mesh.positions))!=nil || resize(&w.locked,len(mesh.positions))!=nil {return {},.Out_Of_Memory}
    }
    if !surface_copy(mesh,out,0,len(mesh.indices)/3) {return {},.Out_Of_Memory}
    append(&out.indices,..mesh.indices);append(&out.materials,..mesh.materials)
    inverse:=1/f64(brush.radius)
    for p,i in mesh.positions {
        representative:=neighbors?w.representatives[i]:u32(i)
        if brush.lock_boundary && w.locked[representative] {continue}
        relative:=dvec(p)-dvec(brush.center)
        distance:=dlength(relative)*inverse
        if distance>=1 {continue}
        weight:=f64(falloff_weight(brush.falloff,brush.hardness,f32(distance)))*f64(brush.amount)
        q:=dvec(p)
        switch brush.kind {
        case .Sculpt:q+=normal*weight
        case .Flatten:q-=normal*(ddot(relative,normal)*weight)
        case .Smooth:
            if w.counts[representative]>0 {q+=(w.sums[representative]/f64(w.counts[representative])-q)*weight}
        case .Drag:
            turned:=mm.quat_rotate(mm.quat_nlerp(1,rotation,f32(weight)),fvec(relative))
            q=dvec(brush.center)+dvec(turned)+dvec(brush.delta)*weight
        }
        next:=fvec(q)
        if !finite3(next) {mesh_buffer_clear(out);return {},.Invalid_Brush}
        if next!=p {out.positions[i]=next;surface_change(&result,p,next);result.vertices+=1}
    }
    result.triangles=len(mesh.indices)/3
    if result.changed && len(out.normals)>0 {
        n:=len(mesh.positions)
        if resize(&w.representatives,n)!=nil || resize(&w.next,n)!=nil || !surface_map_reset(&w.points,n) {
            mesh_buffer_clear(out);return {},.Out_Of_Memory
        }
        for p,i in mesh.positions {
            key:=base.hash_u64(position_hash(p)~position_hash(mesh.normals[i]))
            if key==KEY_EMPTY {key=0}
            head,inserted:=key_map_entry(&w.points,key,u32(i))
            w.representatives[i]=u32(i);w.next[i]=NONE
            if inserted {continue}
            last:=head^
            for v:=head^;v!=NONE;v=w.next[v] {
                if mesh.positions[v]==p && mesh.normals[v]==mesh.normals[i] {w.representatives[i]=v;break}
                last=v
            }
            if w.representatives[i]==u32(i) {w.next[last]=u32(i)}
        }
        for &sum in w.sums {sum={}}
        for &mark in w.locked {mark=false}
        for t:=0;t<len(out.indices);t+=3 {
            a,b,c:=out.indices[t],out.indices[t+1],out.indices[t+2]
            normal:=dcross(dvec(out.positions[b])-dvec(out.positions[a]),dvec(out.positions[c])-dvec(out.positions[a]))
            ra,rb,rc:=w.representatives[a],w.representatives[b],w.representatives[c]
            w.sums[ra]+=normal;w.sums[rb]+=normal;w.sums[rc]+=normal
            if out.positions[a]!=mesh.positions[a] || out.positions[b]!=mesh.positions[b] || out.positions[c]!=mesh.positions[c] {
                w.locked[ra]=true;w.locked[rb]=true;w.locked[rc]=true
            }
        }
        for &normal,i in out.normals {
            representative:=w.representatives[i]
            if !w.locked[representative] {continue}
            value:=dnormalize(w.sums[representative])
            normal=fvec(value) if ddot(value,value)>0 else mesh.normals[i]
        }
    }
    return result,.None
}

@(private="file")
surface_midpoint :: proc(mesh:Mesh,out:^Mesh_Buffer,w:^Mesh_Surface_Workspace,a,b:u32) -> u32 {
    entry,inserted:=key_map_entry(&w.midpoints,pair_key(min(a,b),max(a,b)),u32(len(out.positions)))
    if !inserted {return entry^}
    append(&out.positions,fvec((dvec(mesh.positions[a])+dvec(mesh.positions[b]))*0.5))
    if len(mesh.normals)>0 {append(&out.normals,fvec(dnormalize(dvec(mesh.normals[a])+dvec(mesh.normals[b]))))}
    if len(mesh.uvs)>0 {
        uv:Vec2
        for axis in 0..<2 {uv[axis]=f32((f64(mesh.uvs[a][axis])+f64(mesh.uvs[b][axis]))*0.5)}
        append(&out.uvs,uv)
    }
    if len(mesh.colors)>0 {
        color:Vec4
        for axis in 0..<4 {color[axis]=f32((f64(mesh.colors[a][axis])+f64(mesh.colors[b][axis]))*0.5)}
        append(&out.colors,color)
    }
    return entry^
}

// A single conforming refinement pass, not isotropic remeshing. Every face
// sharing a selected geometric edge splits it, including attribute seams.
mesh_surface_refine :: proc(w:^Mesh_Surface_Workspace,mesh:Mesh,desc:Mesh_Surface_Refine,out:^Mesh_Buffer) -> (result:Mesh_Surface_Result,error:Mesh_Surface_Error) {
    if out==nil {return {},.Invalid_Mesh}
    if surface_aliases(mesh,out) {return {},.Aliased_Output}
    mesh_buffer_clear(out)
    if w==nil || !w.initialized || !surface_valid(mesh) {return {},.Invalid_Mesh}
    if !finite3(desc.center) || !(desc.radius>0) || desc.radius-desc.radius!=0 || !(desc.max_edge_length>0) ||
        desc.max_edge_length-desc.max_edge_length!=0 || desc.max_triangles<0 {return {},.Invalid_Brush}
    if !surface_prepare(w,mesh) {return {},.Out_Of_Memory}
    if len(mesh.indices)/3>desc.max_triangles {return {},.Budget_Exceeded}
    radius_sq:=f64(desc.radius)*f64(desc.radius)
    length_sq:=f64(desc.max_edge_length)*f64(desc.max_edge_length)
    for &edge in w.edges {
        if edge.a==edge.b || edge.uses>2 || (edge.uses==2 && edge.forward!=1) {return {},.Invalid_Mesh}
        if desc.lock_boundary && edge.uses==1 {continue}
        a,b:=dvec(mesh.positions[edge.a]),dvec(mesh.positions[edge.b])
        d:=b-a;distance:=ddot(d,d)
        if distance<=length_sq {continue}
        middle:=fvec((a+b)*0.5)
        if middle==mesh.positions[edge.a] || middle==mesh.positions[edge.b] {continue}
        t:=clamp(ddot(dvec(desc.center)-a,d)/distance,0,1)
        nearest:=a+d*t-dvec(desc.center)
        edge.split=ddot(nearest,nearest)<radius_sq
    }
    triangles,split_corners:=len(mesh.indices)/3,0
    for edge in w.corner_edges {if w.edges[edge].split {split_corners+=1}}
    if split_corners>desc.max_triangles-triangles {return {},.Budget_Exceeded}
    triangles+=split_corners
    if split_corners>int(max(u32))-1-len(mesh.positions) || !surface_map_reset(&w.midpoints,split_corners) ||
        !surface_copy(mesh,out,split_corners,triangles) {return {},.Out_Of_Memory}
    emit :: proc(out:^Mesh_Buffer,a,b,c:u32,material:u32,has_materials:bool) {
        append(&out.indices,a,b,c)
        if has_materials {append(&out.materials,material)}
    }
    for t:=0;t<len(mesh.indices);t+=3 {
        v:=[3]u32{mesh.indices[t],mesh.indices[t+1],mesh.indices[t+2]}
        middle:=[3]u32{NONE,NONE,NONE}
        selected:=0
        for k in 0..<3 {
            if w.edges[w.corner_edges[t+k]].split {
                middle[k]=surface_midpoint(mesh,out,w,v[k],v[(k+1)%3]);selected+=1
            }
        }
        material:=len(mesh.materials)>0?mesh.materials[t/3]:0
        has_materials:=len(mesh.materials)>0
        switch selected {
        case 0:emit(out,v[0],v[1],v[2],material,has_materials)
        case 1:
            for k in 0..<3 {if middle[k]!=NONE {
                a,b,c,m:=v[k],v[(k+1)%3],v[(k+2)%3],middle[k]
                emit(out,a,m,c,material,has_materials);emit(out,m,b,c,material,has_materials)
                break
            }}
        case 2:
            for k in 0..<3 {if middle[k]!=NONE && middle[(k+1)%3]!=NONE {
                a,b,c,m,n:=v[k],v[(k+1)%3],v[(k+2)%3],middle[k],middle[(k+1)%3]
                emit(out,b,n,m,material,has_materials);emit(out,a,m,c,material,has_materials);emit(out,m,n,c,material,has_materials)
                break
            }}
        case 3:
            a,b,c:=middle[0],middle[1],middle[2]
            emit(out,v[0],a,c,material,has_materials);emit(out,a,v[1],b,material,has_materials)
            emit(out,c,b,v[2],material,has_materials);emit(out,a,b,c,material,has_materials)
        }
        if selected>0 {for point in v {surface_change(&result,mesh.positions[point],mesh.positions[point])}}
    }
    result.vertices=len(out.positions)-len(mesh.positions);result.triangles=triangles
    return result,.None
}
