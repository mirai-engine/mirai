package geom

import "base:runtime"
import "core:math"
import "mirai:std/base"

Slice_Options :: struct {
    // Vertices closer than this to the plane are on it and belong to both
    // sides. 0 uses tolerance_noise of the mesh.
    tolerance:   f32,
    open:        bool, // leave the cut open instead of capping it
    cap_material:u32,  // material slot of the cap triangles
    cap_uv_scale:f32,  // texture repeats per unit of length on the cap; 0 is 1
    cap_color:   Vec4, // color of the cap vertices when the mesh has colors; zero is white
}

Slice_Side :: struct {
    triangles:    int, // triangles of the side, cap included; without a buffer, its surface triangles
    cap_first:    int, // the cap triangles are the last ones, from this triangle on
    cap_triangles:int,
    cap_area:     f32,
}

Slice_Result :: struct {
    front,back:Slice_Side,
    // Cut edges that do not close into a loop: the mesh is open there and that
    // part of the cut has no cap.
    open_edges:int,
}

Slice_Error :: enum {None,Invalid_Mesh,Invalid_Plane,Out_Of_Memory}

// Source of a cap triangle in Slicer.sources.
SLICE_CAP :: max(u32)

// Reusable memory of mesh_slice. After the first cuts of a given size a cut
// allocates nothing. A cut takes all the memory it needs before it writes:
// what it fills afterwards has its room.
Slicer :: struct {
    // For each triangle written to the front (0) and to the back (1), the
    // triangle of the input it comes from, or SLICE_CAP.
    sources:    [2][dynamic]u32,

    dist:       [dynamic]f64,
    side:       [dynamic]i8,
    remap:      [2][dynamic]u32,
    on_point:   [dynamic]u32,
    cut_of:     Key_Map,
    cuts:       [dynamic]Slice_Cut,
    points:     [dynamic]Vec3, // distinct positions on the plane
    point_set:  Point_Set,
    grid:       Key_Map,       // cell of the snapping grid to its first point
    grid_next:  [dynamic]u32,
    raw:        [dynamic]Vec3, // crossings as computed, before snapping
    raw_set:    Point_Set,
    raw_point:  [dynamic]u32,
    cap_vertex: [dynamic]u32,
    border:     [2][dynamic][2]u32,
    twins:      Key_Map,
    contour:    [dynamic][2]u32,
    first_out:  [dynamic]u32,
    next_out:   [dynamic]u32,
    used:       [dynamic]bool,
    flat:       [dynamic]DVec2,
    loop_points:[dynamic]DVec2,
    loop_ids:   [dynamic]u32,
    loop_sizes: [dynamic]i32,
    triangles:  [dynamic]u32,
    tr:         Triangulator,
}

@(private) Slice_Cut :: struct {
    lo,hi: u32,    // ends of the edge, ordered by position
    t:     f32,    // from lo to hi
    vertex:[2]u32, // vertex written on each side
    point: u32,
}

slicer_init :: proc(s:^Slicer,allocator:=context.allocator) {
    for k in 0..<2 {
        s.sources[k]=make([dynamic]u32,allocator)
        s.remap[k]=make([dynamic]u32,allocator)
        s.border[k]=make([dynamic][2]u32,allocator)
    }
    s.dist=make([dynamic]f64,allocator)
    s.side=make([dynamic]i8,allocator)
    s.on_point=make([dynamic]u32,allocator)
    key_map_init(&s.cut_of,allocator)
    s.cuts=make([dynamic]Slice_Cut,allocator)
    s.points=make([dynamic]Vec3,allocator)
    s.point_set.slots=make([dynamic]u32,allocator)
    key_map_init(&s.grid,allocator)
    s.grid_next=make([dynamic]u32,allocator)
    s.raw=make([dynamic]Vec3,allocator)
    s.raw_set.slots=make([dynamic]u32,allocator)
    s.raw_point=make([dynamic]u32,allocator)
    s.cap_vertex=make([dynamic]u32,allocator)
    key_map_init(&s.twins,allocator)
    s.contour=make([dynamic][2]u32,allocator)
    s.first_out=make([dynamic]u32,allocator)
    s.next_out=make([dynamic]u32,allocator)
    s.used=make([dynamic]bool,allocator)
    s.flat=make([dynamic]DVec2,allocator)
    s.loop_points=make([dynamic]DVec2,allocator)
    s.loop_ids=make([dynamic]u32,allocator)
    s.loop_sizes=make([dynamic]i32,allocator)
    s.triangles=make([dynamic]u32,allocator)
    triangulator_init(&s.tr,allocator)
}

slicer_destroy :: proc(s:^Slicer) {
    for k in 0..<2 {delete(s.sources[k]);delete(s.remap[k]);delete(s.border[k])}
    delete(s.dist);delete(s.side);delete(s.on_point)
    key_map_destroy(&s.cut_of)
    delete(s.cuts);delete(s.points);delete(s.point_set.slots);delete(s.cap_vertex)
    key_map_destroy(&s.grid)
    delete(s.grid_next);delete(s.raw);delete(s.raw_set.slots);delete(s.raw_point)
    key_map_destroy(&s.twins)
    delete(s.contour);delete(s.first_out);delete(s.next_out);delete(s.used);delete(s.flat)
    delete(s.loop_points);delete(s.loop_ids);delete(s.loop_sizes);delete(s.triangles)
    triangulator_destroy(&s.tr)
    s^={}
}

@(private="file") Pass :: struct {
    s:   ^Slicer,
    mesh:Mesh,
    out: [2]^Mesh_Buffer,
    has_normals,has_uvs,has_colors,has_materials:bool,
    inverse:f64, // of the tolerance: the cell of the snapping grid
    reach:  f64, // tolerance squared
}

@(private="file") grid_key :: #force_inline proc "contextless" (position:Vec3,inverse:f64,dx,dy,dz:i64) -> u64 {
    x:=i64(clamp(math.floor(f64(position.x)*inverse),-4e18,4e18))+dx
    y:=i64(clamp(math.floor(f64(position.y)*inverse),-4e18,4e18))+dy
    z:=i64(clamp(math.floor(f64(position.z)*inverse),-4e18,4e18))+dz
    key:=hash_u64(hash_u64(hash_u64(u64(x))~u64(y))~u64(z))
    return 0 if key==KEY_EMPTY else key
}

// Of the point just added to s.points: grid_next has one entry per point.
@(private="file") grid_insert :: proc(p:^Pass,point:u32) #no_bounds_check {
    s:=p.s
    head,inserted:=key_map_entry(&s.grid,grid_key(s.points[point],p.inverse,0,0,0),point)
    if inserted {push(&s.grid_next,NONE)} else {push(&s.grid_next,head^);head^=point}
}

// The point on the plane nearest to `position` within the tolerance.
@(private="file") grid_nearest :: proc(p:^Pass,position:Vec3) -> u32 #no_bounds_check {
    s:=p.s
    best:=NONE
    best_distance:=p.reach
    for dz in i64(-1)..=1 {for dy in i64(-1)..=1 {for dx in i64(-1)..=1 {
        head,found:=key_map_find(&s.grid,grid_key(position,p.inverse,dx,dy,dz))
        if !found {continue}
        for q:=head;q!=NONE;q=s.grid_next[q] {
            d:=dvec(s.points[q])-dvec(position)
            distance:=ddot(d,d)
            if distance<best_distance || (distance==best_distance && q<best) {best=q;best_distance=distance}
        }
    }}}
    return best
}

@(private="file") pass_vertex :: #force_inline proc(p:^Pass,k:int,v:u32) -> u32 #no_bounds_check {
    index:=p.s.remap[k][v]
    if index!=NONE {return index}
    out:=p.out[k]
    index=u32(len(out.positions))
    push(&out.positions,p.mesh.positions[v])
    if p.has_normals {push(&out.normals,p.mesh.normals[v])}
    if p.has_uvs {push(&out.uvs,p.mesh.uvs[v])}
    if p.has_colors {push(&out.colors,p.mesh.colors[v])}
    p.s.remap[k][v]=index
    return index
}

@(private="file") pass_on_point :: #force_inline proc(p:^Pass,v:u32) -> u32 #no_bounds_check {
    return p.s.on_point[v]
}

// The crossing of the edge between a and b. It depends only on the positions
// of the ends, so every triangle on the edge gets the same point. A crossing
// within the tolerance of a point already on the plane is that point: edges
// that meet the plane at one place do not leave slivers between them.
@(private="file") pass_cut :: proc(p:^Pass,a,b:u32) -> u32 #no_bounds_check {
    s:=p.s
    entry,inserted:=key_map_entry(&s.cut_of,pair_key(min(a,b),max(a,b)),u32(len(s.cuts)))
    if !inserted {return entry^}
    pa,pb:=p.mesh.positions[a],p.mesh.positions[b]
    lo,hi:=a,b
    if pb.x<pa.x || (pb.x==pa.x && (pb.y<pa.y || (pb.y==pa.y && pb.z<pa.z))) {lo,hi=b,a}
    t:=s.dist[lo]/(s.dist[lo]-s.dist[hi])
    plo,phi:=dvec(p.mesh.positions[lo]),dvec(p.mesh.positions[hi])
    raw:=fvec(plo+(phi-plo)*t)
    index,added:=point_set_add(&s.raw_set,&s.raw,raw)
    point:u32
    if added {
        point=grid_nearest(p,raw)
        if point==NONE {
            point=u32(len(s.points))
            push(&s.points,raw)
            grid_insert(p,point)
        }
        push(&s.raw_point,point)
    } else {
        point=s.raw_point[index]
    }
    push(&s.cuts,Slice_Cut{lo,hi,f32(t),{NONE,NONE},point})
    return u32(len(s.cuts)-1)
}

@(private="file") pass_cut_vertex :: proc(p:^Pass,k:int,cut:u32) -> u32 #no_bounds_check {
    c:=&p.s.cuts[cut]
    if c.vertex[k]!=NONE {return c.vertex[k]}
    out:=p.out[k]
    index:=u32(len(out.positions))
    push(&out.positions,p.s.points[c.point])
    if p.has_normals {
        a,b:=p.mesh.normals[c.lo],p.mesh.normals[c.hi]
        push(&out.normals,fnormalize(a+(b-a)*c.t,a))
    }
    if p.has_uvs {
        a,b:=p.mesh.uvs[c.lo],p.mesh.uvs[c.hi]
        push(&out.uvs,a+(b-a)*c.t)
    }
    if p.has_colors {
        a,b:=p.mesh.colors[c.lo],p.mesh.colors[c.hi]
        push(&out.colors,a+(b-a)*c.t)
    }
    c.vertex[k]=index
    return index
}

@(private="file") pass_triangle :: #force_inline proc(p:^Pass,k:int,a,b,c:u32,source:u32) {
    out:=p.out[k]
    push(&out.indices,a);push(&out.indices,b);push(&out.indices,c)
    push(&out.materials,p.mesh.materials[source] if p.has_materials else 0)
    push(&p.s.sources[k],source)
}

// A piece of a split triangle. One whose corners coincide (the cut of a
// triangle without area) only carries an edge and its opposite: it is dropped.
@(private="file") pass_fragment :: #force_inline proc(p:^Pass,k:int,a,b,c:u32,source:u32) {
    positions:=p.out[k].positions[:]
    if positions[a]==positions[b] || positions[b]==positions[c] || positions[a]==positions[c] {return}
    pass_triangle(p,k,a,b,c,source)
}

// Room in the buffers of side k for that many vertices and triangles more.
@(private="file") pass_reserve :: proc(p:^Pass,k:int,vertices,triangles:int) -> runtime.Allocator_Error {
    out:=p.out[k]
    reserve_more(&out.positions,vertices) or_return
    if p.has_normals {reserve_more(&out.normals,vertices) or_return}
    if p.has_uvs {reserve_more(&out.uvs,vertices) or_return}
    if p.has_colors {reserve_more(&out.colors,vertices) or_return}
    reserve_more(&out.indices,triangles*3) or_return
    reserve_more(&out.materials,triangles) or_return
    return reserve_more(&p.s.sources[k],triangles)
}

// Splits a mesh with a plane into the part in front of it and the part behind
// it; either buffer may be nil. A closed mesh gives closed parts: the cut of
// each side is filled with cap triangles that face the other side, written
// after the surface triangles with their own vertices, planar texture
// coordinates and material slot. Vertices are shared by position, so seams of
// normals or texture coordinates do not open the cut. Without memory both
// buffers are left empty.
mesh_slice :: proc(s:^Slicer,mesh:Mesh,plane:Plane,front,back:^Mesh_Buffer,options:Slice_Options={}) -> (result:Slice_Result,error:Slice_Error) {
    if !mesh_is_valid(mesh) {return {},.Invalid_Mesh}
    dp,plane_ok:=dplane(plane)
    if !plane_ok {return {},.Invalid_Plane}
    no_memory:runtime.Allocator_Error
    if result,no_memory=slice_plane(s,mesh,dp,front,back,options,true);no_memory!=nil {
        if front!=nil {mesh_buffer_clear(front)}
        if back!=nil {mesh_buffer_clear(back)}
        return {},.Out_Of_Memory
    }
    return result,.None
}

// mesh_slice for a valid mesh and a unit plane. Without copy_whole, a mesh
// that the plane does not separate is not written anywhere: the result only
// tells on which side it is.
@(private) slice_plane :: proc(s:^Slicer,mesh:Mesh,dp:DPlane,front,back:^Mesh_Buffer,options:Slice_Options,copy_whole:bool) -> (result:Slice_Result,error:runtime.Allocator_Error) #no_bounds_check {
    p:=Pass{s=s,mesh=mesh,out={front,back}}
    vertex_count:=len(mesh.positions)
    p.has_normals=len(mesh.normals)==vertex_count && vertex_count>0
    p.has_uvs=len(mesh.uvs)==vertex_count && vertex_count>0
    p.has_colors=len(mesh.colors)==vertex_count && vertex_count>0
    p.has_materials=len(mesh.materials)>0
    for k in 0..<2 {
        clear(&s.sources[k]);clear(&s.border[k])
        if p.out[k]!=nil {mesh_buffer_clear(p.out[k])}
    }

    tolerance:=f64(max(options.tolerance,tolerance_noise(positions_max_abs(mesh.positions))))
    resize(&s.dist,vertex_count) or_return
    resize(&s.side,vertex_count) or_return
    in_front,behind:=0,0
    for position,i in mesh.positions {
        d:=ddot(dp.n,dvec(position))-dp.d
        s.dist[i]=d
        switch {
        case d>tolerance: s.side[i]=1;in_front+=1
        case d<-tolerance: s.side[i]=-1;behind+=1
        case: s.side[i]=0
        }
    }
    sides:=[2]^Slice_Side{&result.front,&result.back}
    if in_front==0 || behind==0 {
        // Nothing to separate: the mesh goes whole to the side it is on.
        k:=0 if behind==0 && in_front>0 else 1
        if in_front==0 && behind==0 {k=1}
        if out:=p.out[k];out!=nil && copy_whole {
            pass_reserve(&p,k,vertex_count,len(mesh.indices)/3) or_return
            append(&out.positions,..mesh.positions) or_return
            if p.has_normals {append(&out.normals,..mesh.normals) or_return}
            if p.has_uvs {append(&out.uvs,..mesh.uvs) or_return}
            if p.has_colors {append(&out.colors,..mesh.colors) or_return}
            append(&out.indices,..mesh.indices) or_return
            for t in 0..<len(mesh.indices)/3 {
                push(&out.materials,mesh.materials[t] if p.has_materials else 0)
                push(&s.sources[k],u32(t))
            }
        }
        sides[k].triangles=len(mesh.indices)/3
        sides[k].cap_first=sides[k].triangles
        return
    }

    for k in 0..<2 {
        if p.out[k]==nil {continue}
        resize(&s.remap[k],vertex_count) or_return
        for &r in s.remap[k] {r=NONE}
    }
    resize(&s.on_point,vertex_count) or_return
    for &o in s.on_point {o=NONE}
    // crossing: triangles the plane splits. flat: edges on the plane of the
    // triangles it does not.
    crossing,flat:=0,0
    for t:=0;t+2<len(mesh.indices);t+=3 {
        a,b,c:=s.side[mesh.indices[t]],s.side[mesh.indices[t+1]],s.side[mesh.indices[t+2]]
        if (a>0 || b>0 || c>0) && (a<0 || b<0 || c<0) {crossing+=1} else {flat+=int(a==0 && b==0)+int(b==0 && c==0)+int(c==0 && a==0)}
    }
    // Room for everything the surface can leave: a split triangle cuts at
    // most two edges, each cut is at most one new point, and a side gets at
    // most one more triangle and one border edge from it. The triangle loop
    // writes without growing.
    triangle_count:=len(mesh.indices)/3
    on_plane:=vertex_count-in_front-behind
    cuts:=crossing*2
    points:=on_plane+cuts
    for k in 0..<2 {
        if p.out[k]==nil {continue}
        pass_reserve(&p,k,vertex_count+cuts,triangle_count+crossing) or_return
        reserve(&s.border[k],crossing+flat) or_return
    }
    clear(&s.cuts);clear(&s.points);clear(&s.raw);clear(&s.raw_point);clear(&s.grid_next)
    reserve(&s.cuts,cuts) or_return
    reserve(&s.points,points) or_return
    reserve(&s.raw,cuts) or_return
    reserve(&s.raw_point,cuts) or_return
    reserve(&s.grid_next,points) or_return
    key_map_reset(&s.cut_of,cuts) or_return
    point_set_reset(&s.point_set,on_plane) or_return
    point_set_reset(&s.raw_set,cuts) or_return
    key_map_reset(&s.grid,points) or_return
    p.inverse=1/tolerance
    p.reach=tolerance*tolerance
    // The vertices on the plane are its first points, whatever the order of
    // the triangles.
    for v in 0..<vertex_count {
        if s.side[v]!=0 {continue}
        point,added:=point_set_add(&s.point_set,&s.points,mesh.positions[v])
        s.on_point[v]=point
        if added {grid_insert(&p,point)}
    }

    kept:[2]int
    for t:=0;t+2<len(mesh.indices);t+=3 {
        source:=u32(t/3)
        v:=[3]u32{mesh.indices[t],mesh.indices[t+1],mesh.indices[t+2]}
        sd:=[3]i8{s.side[v[0]],s.side[v[1]],s.side[v[2]]}
        front_count:=int(sd[0]>0)+int(sd[1]>0)+int(sd[2]>0)
        back_count:=int(sd[0]<0)+int(sd[1]<0)+int(sd[2]<0)
        if front_count==0 || back_count==0 {
            k:=0 if front_count>0 else 1
            if front_count==0 && back_count==0 {
                // On the plane: it bounds the side its normal points away from.
                a:=dvec(mesh.positions[v[0]])
                n:=dcross(dvec(mesh.positions[v[1]])-a,dvec(mesh.positions[v[2]])-a)
                k=1 if ddot(n,dp.n)>0 else 0
            }
            kept[k]+=1
            if p.out[k]==nil {continue}
            pass_triangle(&p,k,pass_vertex(&p,k,v[0]),pass_vertex(&p,k,v[1]),pass_vertex(&p,k,v[2]),source)
            for e in 0..<3 {
                a,b:=v[e],v[(e+1)%3]
                if sd[e]==0 && sd[(e+1)%3]==0 {push(&s.border[k],[2]u32{pass_on_point(&p,a),pass_on_point(&p,b)})}
            }
            continue
        }
        if front_count+back_count==2 {
            // One corner on the plane and one on each side.
            r:=0 if sd[0]==0 else 1 if sd[1]==0 else 2
            a,b,c:=v[r],v[(r+1)%3],v[(r+2)%3]
            kb:=0 if s.side[b]>0 else 1
            kc:=1-kb
            kept[kb]+=1;kept[kc]+=1
            cut:=pass_cut(&p,b,c)
            pa,px:=pass_on_point(&p,a),s.cuts[cut].point
            if p.out[kb]!=nil {
                pass_fragment(&p,kb,pass_vertex(&p,kb,a),pass_vertex(&p,kb,b),pass_cut_vertex(&p,kb,cut),source)
                push(&s.border[kb],[2]u32{px,pa})
            }
            if p.out[kc]!=nil {
                pass_fragment(&p,kc,pass_vertex(&p,kc,a),pass_cut_vertex(&p,kc,cut),pass_vertex(&p,kc,c),source)
                push(&s.border[kc],[2]u32{pa,px})
            }
            continue
        }
        // One corner alone on its side.
        r:=0
        if front_count==1 {r=0 if sd[0]>0 else 1 if sd[1]>0 else 2} else {r=0 if sd[0]<0 else 1 if sd[1]<0 else 2}
        a,b,c:=v[r],v[(r+1)%3],v[(r+2)%3]
        ka:=0 if s.side[a]>0 else 1
        kb:=1-ka
        kept[ka]+=1;kept[kb]+=2
        ab,ca:=pass_cut(&p,a,b),pass_cut(&p,c,a)
        pab,pca:=s.cuts[ab].point,s.cuts[ca].point
        if p.out[ka]!=nil {
            pass_fragment(&p,ka,pass_vertex(&p,ka,a),pass_cut_vertex(&p,ka,ab),pass_cut_vertex(&p,ka,ca),source)
            push(&s.border[ka],[2]u32{pab,pca})
        }
        if p.out[kb]!=nil {
            xab,xca:=pass_cut_vertex(&p,kb,ab),pass_cut_vertex(&p,kb,ca)
            vb,vc:=pass_vertex(&p,kb,b),pass_vertex(&p,kb,c)
            pass_fragment(&p,kb,xab,vb,vc,source)
            pass_fragment(&p,kb,xab,vc,xca,source)
            push(&s.border[kb],[2]u32{pca,pab})
        }
    }

    for k in 0..<2 {
        out:=p.out[k]
        if out==nil {
            // Not written: only how many surface triangles belong to the side.
            sides[k].triangles=kept[k]
            sides[k].cap_first=kept[k]
            continue
        }
        sides[k].cap_first=len(out.indices)/3
        if !options.open {slice_cap(&p,k,dp,options,&result,sides[k]) or_return}
        sides[k].triangles=len(out.indices)/3
    }
    return
}

// Clockwise angle from `back` to `direction` mapped to (0,4], without
// trigonometry: 2 is straight ahead and 4 is turning back.
@(private="file") clockwise_turn :: proc "contextless" (back,direction:DVec2) -> f64 {
    cross:=back.x*direction.y-back.y*direction.x
    dot:=back.x*direction.x+back.y*direction.y
    norm:=abs(cross)+abs(dot)
    if norm==0 {return 4}
    t:=dot/norm
    if cross<0 {return 1-t}
    if cross>0 {return 3+t}
    return 2 if dot<0 else 4
}

// Every array is sized for the border before it is filled: the twins are
// keyed by its directed edges, a contour has at most its edges, and the loops
// walk each edge of the contour once.
@(private="file") slice_cap :: proc(p:^Pass,k:int,dp:DPlane,options:Slice_Options,result:^Slice_Result,side:^Slice_Side) -> runtime.Allocator_Error #no_bounds_check {
    s:=p.s
    out:=p.out[k]
    border:=s.border[k][:]
    if len(border)==0 {return nil}
    // Edges used in both directions are interior to this side: what is left
    // is its open border. The cap runs along it backwards.
    key_map_reset(&s.twins,len(border)) or_return
    for e in border {
        if e[0]==e[1] {continue}
        if opposite,found:=key_map_find(&s.twins,pair_key(e[1],e[0]));found && opposite>0 {
            entry,_:=key_map_entry(&s.twins,pair_key(e[1],e[0]),0)
            entry^-=1
            continue
        }
        entry,_:=key_map_entry(&s.twins,pair_key(e[0],e[1]),0)
        entry^+=1
    }
    clear(&s.contour)
    reserve(&s.contour,len(border)) or_return
    for e in border {
        if e[0]==e[1] {continue}
        entry,_:=key_map_entry(&s.twins,pair_key(e[0],e[1]),0)
        if entry^==0 {continue}
        entry^-=1
        push(&s.contour,[2]u32{e[1],e[0]})
    }
    if len(s.contour)==0 {return nil}

    // Plane coordinates with u×v along the cap normal, so that the outlines
    // of the cap are counter-clockwise.
    u,v:=plane_basis(dp.n)
    origin:=dp.n*dp.d
    cap_u,cap_v:=u,v
    if k==0 {cap_u,cap_v=v,u}
    resize(&s.flat,len(s.points)) or_return
    for point,i in s.points {
        d:=dvec(point)-origin
        s.flat[i]={ddot(d,cap_u),ddot(d,cap_v)}
    }
    resize(&s.first_out,len(s.points)) or_return
    for &f in s.first_out {f=NONE}
    resize(&s.next_out,len(s.contour)) or_return
    resize(&s.used,len(s.contour)) or_return
    // Lists keep the order of the edges.
    for i:=len(s.contour)-1;i>=0;i-=1 {
        from:=s.contour[i][0]
        s.next_out[i]=s.first_out[from]
        s.first_out[from]=u32(i)
        s.used[i]=false
    }
    clear(&s.loop_points);clear(&s.loop_ids);clear(&s.loop_sizes)
    reserve(&s.loop_ids,len(s.contour)) or_return
    reserve(&s.loop_sizes,len(s.contour)/3) or_return
    for start in 0..<len(s.contour) {
        if s.used[start] {continue}
        first:=len(s.loop_ids)
        e:=u32(start)
        closed:=false
        for {
            s.used[e]=true
            from,to:=s.contour[e][0],s.contour[e][1]
            push(&s.loop_ids,from)
            // Where several edges leave a point, the sharpest turn towards the
            // inside keeps touching outlines apart.
            back:=s.flat[from]-s.flat[to]
            following:=NONE
            best:=max(f64)
            for candidate:=s.first_out[to];candidate!=NONE;candidate=s.next_out[candidate] {
                if s.used[candidate] && candidate!=u32(start) {continue}
                turn:=clockwise_turn(back,s.flat[s.contour[candidate][1]]-s.flat[to])
                if turn<best {best=turn;following=candidate}
            }
            if following==NONE {break}
            if following==u32(start) {closed=true;break}
            e=following
        }
        if !closed || len(s.loop_ids)-first<3 {
            if !closed {result.open_edges+=len(s.loop_ids)-first}
            base.truncate(&s.loop_ids,first)
            continue
        }
        push(&s.loop_sizes,i32(len(s.loop_ids)-first))
    }
    if len(s.loop_sizes)==0 {return nil}
    resize(&s.loop_points,len(s.loop_ids)) or_return
    for id,i in s.loop_ids {s.loop_points[i]=s.flat[id]}
    clear(&s.triangles)
    triangulate_loops(&s.tr,s.loop_points[:],s.loop_sizes[:],&s.triangles,.Orientation) or_return

    resize(&s.cap_vertex,len(s.points)) or_return
    for &c in s.cap_vertex {c=NONE}
    pass_reserve(p,k,min(len(s.points),len(s.loop_ids)),len(s.triangles)/3) or_return
    normal:=fvec(dp.n) if k==1 else fvec(-dp.n)
    scale:=f64(options.cap_uv_scale) if options.cap_uv_scale!=0 else 1
    color:=options.cap_color if options.cap_color!={} else Vec4{1,1,1,1}
    area:f64
    first:=len(out.indices)/3
    for t:=0;t+2<len(s.triangles);t+=3 {
        corners:[3]u32
        ids:=[3]u32{s.loop_ids[s.triangles[t]],s.loop_ids[s.triangles[t+1]],s.loop_ids[s.triangles[t+2]]}
        if ids[0]==ids[1] || ids[1]==ids[2] || ids[0]==ids[2] {continue}
        for c in 0..<3 {
            id:=ids[c]
            index:=s.cap_vertex[id]
            if index==NONE {
                index=u32(len(out.positions))
                push(&out.positions,s.points[id])
                if p.has_normals {push(&out.normals,normal)}
                if p.has_uvs {
                    d:=dvec(s.points[id])-origin
                    push(&out.uvs,Vec2{f32(ddot(d,u)*scale),f32(ddot(d,v)*scale)})
                }
                if p.has_colors {push(&out.colors,color)}
                s.cap_vertex[id]=index
            }
            corners[c]=index
        }
        a,b,c:=s.loop_points[s.triangles[t]],s.loop_points[s.triangles[t+1]],s.loop_points[s.triangles[t+2]]
        area+=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
        push(&out.indices,corners[0]);push(&out.indices,corners[1]);push(&out.indices,corners[2])
        push(&out.materials,options.cap_material)
        push(&s.sources[k],SLICE_CAP)
    }
    side.cap_triangles=len(out.indices)/3-first
    side.cap_area=f32(abs(area)*0.5)
    return nil
}

// The mesh has no triangles in front of the plane, within the tolerance.
mesh_is_behind :: proc(positions:[]Vec3,plane:Plane,tolerance:f32) -> bool {
    dp,ok:=dplane(plane)
    if !ok {return false}
    for position in positions {
        if ddot(dp.n,dvec(position))-dp.d>f64(tolerance) {return false}
    }
    return true
}
