package geom

// values may hold a window of the grid: extent samples on each axis from
// first, which are those a region reads (isosurface checks it). Zero extent:
// every sample.
Scalar_Grid :: struct {
    samples:[3]int,
    cell,origin:Vec3,
    values:[]f32,
    first,extent:[3]int,
}

Iso_Error :: enum u8 {None,Invalid_Grid,Invalid_Region,Out_Of_Memory}

// The level of a region and of what it shares with the regions around it:
// level k reads every 2^k-th sample. faces: -X,+X,-Y,+Y,-Z,+Z. edges: those
// along X at -Y-Z,+Y-Z,-Y+Z,+Y+Z, along Y at -X-Z,+X-Z,-X+Z,+X+Z and along Z
// at -X-Y,+X-Y,-X+Y,+X+Y. Two regions that give the same level to what they
// share build the same triangles on it.
Iso_Lod :: struct {level:u8,faces:[6]u8,edges:[12]u8}

ISO_LEVELS_MAX :: 16

@(private="file") TETRAHEDRA :: [6][4]int{{0,1,3,7},{0,3,2,7},{0,2,6,7},{0,6,4,7},{0,4,5,7},{0,5,1,7}}

@(private="file")
scalar_index :: #force_inline proc "contextless" (g:^Scalar_Grid,p:[3]int) -> int {
    q:=p-g.first
    return q.x+g.extent.x*(q.y+g.extent.y*q.z)
}

@(private="file")
scalar_gradient :: #force_inline proc "contextless" (g:^Scalar_Grid,p:[3]int,step:int) -> (normal:Vec3,ok:bool) #no_bounds_check {
    gradient:[3]f64
    for axis in 0..<3 {
        lo,hi:=p,p
        lo[axis]=max(p[axis]-step,0);hi[axis]=min(p[axis]+step,g.samples[axis]-1)
        a,b:=g.values[scalar_index(g,lo)],g.values[scalar_index(g,hi)]
        if a-a!=0 || b-b!=0 {return {},false}
        gradient[axis]=(f64(b)-f64(a))/(f64(hi[axis]-lo[axis])*f64(g.cell[axis]))
    }
    scale:=max(abs(gradient.x),max(abs(gradient.y),abs(gradient.z)))
    if scale>0 {normal={f32(gradient.x/scale),f32(gradient.y/scale),f32(gradient.z/scale)}}
    return normal,true
}

// The region being extracted, with the level of each of its parts. Points
// are in half samples of the grid (twice the sample coordinates), so the
// center of a cell or of a face is one too.
@(private="file")
Iso_Region :: struct {
    g:Scalar_Grid,
    low,size:[3]int,
    level:int,
    faces:[6]int,
    edges:[12]int,
    isolevel:f32,
    out:^Mesh_Buffer,
    emit:bool,
    triangles:int,
    error:Iso_Error,
}

@(private="file")
Iso_Vertex :: struct {point,gradient:Vec3,value:f32,at:[3]int}

// The level of what a point of the region (in samples, relative to low) lies
// on: the inside, a face, an edge, or a corner (0). For a segment along an
// axis, that axis is not looked at.
@(private)
iso_part_level :: proc "contextless" (r:^Iso_Region,p:[3]int,along:=-1) -> int {
    face_of:[3]int
    count:=0
    for axis in 0..<3 {
        face_of[axis]=-1
        if axis==along {continue}
        if p[axis]==0 {face_of[axis]=axis*2} else if p[axis]==r.size[axis] {face_of[axis]=axis*2+1}
        if face_of[axis]>=0 {count+=1}
    }
    switch count {
    case 0: return r.level
    case 1: for axis in 0..<3 {if face_of[axis]>=0 {return r.faces[face_of[axis]]}}
    case 2:
        a:=0
        for axis in 0..<3 {if face_of[axis]<0 {a=axis}}
        b,c:=(a+1)%3,(a+2)%3
        if b>c {b,c=c,b}
        return r.edges[4*a+(face_of[b]&1)+2*(face_of[c]&1)]
    }
    return 0
}

// The step between the points of a segment along axis through p: that of
// what it lies on.
@(private="file")
iso_segment_step :: proc "contextless" (r:^Iso_Region,axis:int,p:[3]int) -> int {
    return 1<<uint(iso_part_level(r,p,axis))
}

@(private="file")
iso_segment_split :: proc "contextless" (r:^Iso_Region,axis:int,p:[3]int,from,to:int) -> bool {
    step:=iso_segment_step(r,axis,p)
    return (from/step+1)*step<to
}

// A sample, with its gradient over the step of what it lies on, so the
// regions that share it agree.
@(private="file")
iso_sample :: #force_inline proc(r:^Iso_Region,p:[3]int,v:^Iso_Vertex) -> bool #no_bounds_check {
    g:=&r.g
    v.value=g.values[scalar_index(g,p)]
    if v.value-v.value!=0 {return false}
    if !r.emit {return true}
    v.at=p*2
    v.point=g.origin+[3]f32{f32(p.x),f32(p.y),f32(p.z)}*g.cell
    ok:bool
    v.gradient,ok=scalar_gradient(g,p,r.level==0?1:1<<uint(iso_part_level(r,p-r.low)))
    return ok
}

// A point in half samples: a sample, or between samples the mean of those
// around it.
@(private="file")
iso_vertex :: proc(r:^Iso_Region,half:[3]int) -> (v:Iso_Vertex,ok:bool) {
    if half.x&1==0 && half.y&1==0 && half.z&1==0 {
        ok=iso_sample(r,{half.x>>1,half.y>>1,half.z>>1},&v)
        return
    }
    g:=r.g
    count:=0
    value:f64
    gradient:Vec3
    for dz in 0..=half.z&1 {for dy in 0..=half.y&1 {for dx in 0..=half.x&1 {
        sample:Iso_Vertex
        iso_sample(r,{half.x>>1+dx,half.y>>1+dy,half.z>>1+dz},&sample) or_return
        value+=f64(sample.value)
        gradient+=sample.gradient
        count+=1
    }}}
    v.at=half
    v.point=g.origin+[3]f32{f32(half.x)*0.5,f32(half.y)*0.5,f32(half.z)*0.5}*g.cell
    v.value=f32(value/f64(count))
    v.gradient=gradient/f32(count)
    return v,true
}

// Before in the order of the grid: z, then y, then x.
@(private)
iso_before :: proc "contextless" (a,b:[3]int) -> bool {
    if a.z!=b.z {return a.z<b.z}
    if a.y!=b.y {return a.y<b.y}
    return a.x<b.x
}

// The surface through a tetrahedron, or only how many triangles it has.
@(private="file")
iso_tetrahedron :: #force_inline proc(r:^Iso_Region,corners:[4]^Iso_Vertex) #no_bounds_check {
    inside,outside:[4]^Iso_Vertex
    ni,no:=0,0
    for v in corners {if v.value<r.isolevel {inside[ni]=v;ni+=1} else {outside[no]=v;no+=1}}
    if ni==0 || no==0 {return}
    if !r.emit {
        if r.triangles>max(int)/3-2 {r.error=.Out_Of_Memory;return}
        r.triangles+=ni==2?2:1
        return
    }
    sum_inside,sum_outside:DVec3
    for v in inside[:ni] {sum_inside+=dvec(v.point)}
    for v in outside[:no] {sum_outside+=dvec(v.point)}
    toward:=sum_outside/f64(no)-sum_inside/f64(ni)
    edge :: proc(a,b:^Iso_Vertex,isolevel:f32) -> (point,normal:Vec3) {
        a,b:=a,b
        if iso_before(b.at,a.at) {a,b=b,a}
        t:=f32(clamp((f64(isolevel)-f64(a.value))/(f64(b.value)-f64(a.value)),0,1))
        point=a.point+(b.point-a.point)*t
        normal=fnormalize(a.gradient+(b.gradient-a.gradient)*t,{0,1,0})
        return
    }
    emit :: proc(out:^Mesh_Buffer,positions,normals:[3]Vec3,toward:DVec3) {
        positions,normals:=positions,normals
        cross:=dcross(dvec(positions[1])-dvec(positions[0]),dvec(positions[2])-dvec(positions[0]))
        if ddot(cross,cross)==0 {return}
        if ddot(cross,toward)<0 {positions[1],positions[2]=positions[2],positions[1];normals[1],normals[2]=normals[2],normals[1]}
        first:=u32(len(out.positions))
        append(&out.positions,..positions[:])
        append(&out.normals,..normals[:])
        append(&out.indices,first,first+1,first+2)
    }
    p,n:[4]Vec3
    if ni==1 || no==1 {
        root:=ni==1?inside[0]:outside[0]
        others:=ni==1?outside:inside
        for i in 0..<3 {p[i],n[i]=edge(root,others[i],r.isolevel)}
        emit(r.out,{p[0],p[1],p[2]},{n[0],n[1],n[2]},toward)
    } else {
        for a in 0..<2 {for b in 0..<2 {i:=a*2+b;p[i],n[i]=edge(inside[a],outside[b],r.isolevel)}}
        emit(r.out,{p[0],p[1],p[3]},{n[0],n[1],n[3]},toward)
        emit(r.out,{p[0],p[3],p[2]},{n[0],n[3],n[2]},toward)
    }
}

// A cell whose faces all split along their diagonal from the lowest corner:
// six tetrahedra around that of the cell, which its neighbors share.
@(private="file")
iso_cell_regular :: proc "contextless" (r:^Iso_Region,lo,hi:[3]int) -> bool {
    if r.level==0 {return true}
    inner:=true
    for axis in 0..<3 {inner&&=lo[axis]>0 && hi[axis]<r.size[axis]}
    if inner {return true}
    for axis in 0..<3 {
        b,c:=(axis+1)%3,(axis+2)%3
        for corner in 0..<4 {
            p:=lo
            if corner&1!=0 {p[b]=hi[b]}
            if corner&2!=0 {p[c]=hi[c]}
            if iso_segment_split(r,axis,p,lo[axis],hi[axis]) {return false}
        }
        // A face on a face of the region at a finer level is several squares.
        for side in 0..<2 {
            at:=side==0?lo[axis]:hi[axis]
            if at!=0 && at!=r.size[axis] {continue}
            step:=1<<uint(r.faces[axis*2+(at==0?0:1)])
            if (lo[b]/step+1)*step<hi[b] || (lo[c]/step+1)*step<hi[c] {return false}
        }
    }
    return true
}

// The triangles of a face of a cell, in half samples, coned to center: the
// face perpendicular to axis at at, from lo to hi on the other two. On a face
// of the region it is made of the squares of that face's level; a square
// whose sides have points between its corners is coned from its center, and
// any other splits along its diagonal from the lowest corner.
@(private="file")
iso_face :: proc(r:^Iso_Region,axis,at:int,lo,hi:[3]int,center:^Iso_Vertex) {
    b,c:=(axis+1)%3,(axis+2)%3
    if b>c {b,c=c,b}
    step:=r.size[b]+r.size[c]+1
    if at==0 || at==r.size[axis] {step=1<<uint(r.faces[axis*2+(at==0?0:1)])}
    for v0:=lo[c];v0<hi[c]; {
        v1:=min(v0+step,hi[c])
        for u0:=lo[b];u0<hi[b]; {
            u1:=min(u0+step,hi[b])
            iso_square(r,axis,at,b,c,{u0,v0},{u1,v1},center)
            if r.error!=.None {return}
            u0=u1
        }
        v0=v1
    }
}

@(private="file")
iso_square :: proc(r:^Iso_Region,axis,at,b,c:int,low,high:[2]int,center:^Iso_Vertex) {
    point :: proc "contextless" (r:^Iso_Region,axis,at,b,c,u,v:int) -> (p:[3]int) {
        p[axis],p[b],p[c]=at,u,v
        return
    }
    vertex :: proc(r:^Iso_Region,local:[3]int) -> (v:Iso_Vertex,ok:bool) {
        return iso_vertex(r,(r.low+local)*2)
    }
    // Its sides: along b at low v and at high v, along c at low u and at high u.
    split:=iso_segment_split(r,b,point(r,axis,at,b,c,low.x,low.y),low.x,high.x) ||
        iso_segment_split(r,b,point(r,axis,at,b,c,low.x,high.y),low.x,high.x) ||
        iso_segment_split(r,c,point(r,axis,at,b,c,low.x,low.y),low.y,high.y) ||
        iso_segment_split(r,c,point(r,axis,at,b,c,high.x,low.y),low.y,high.y)
    if !split {
        a,ok0:=vertex(r,point(r,axis,at,b,c,low.x,low.y))
        e,ok1:=vertex(r,point(r,axis,at,b,c,high.x,low.y))
        f,ok2:=vertex(r,point(r,axis,at,b,c,high.x,high.y))
        d,ok3:=vertex(r,point(r,axis,at,b,c,low.x,high.y))
        if !ok0 || !ok1 || !ok2 || !ok3 {r.error=.Invalid_Grid;return}
        iso_tetrahedron(r,{center,&a,&e,&f})
        iso_tetrahedron(r,{center,&a,&f,&d})
        return
    }
    middle:=point(r,axis,at,b,c,low.x+high.x,low.y+high.y)
    middle[axis]=at*2
    apex,known:=iso_vertex(r,r.low*2+middle)
    if !known {r.error=.Invalid_Grid;return}
    // Around the square: its points in order, each with the next.
    corners:=[5][2]int{{low.x,low.y},{high.x,low.y},{high.x,high.y},{low.x,high.y},{low.x,low.y}}
    previous:Iso_Vertex
    started:=false
    for side in 0..<4 {
        from,to:=corners[side],corners[side+1]
        along:=from.x!=to.x?b:c
        p:=point(r,axis,at,b,c,min(from.x,to.x),min(from.y,to.y))
        step:=iso_segment_step(r,along,p)
        start,end:=along==b?from.x:from.y,along==b?to.x:to.y
        forward:=end>start
        for at_along:=start;true; {
            local:=along==b?point(r,axis,at,b,c,at_along,from.y):point(r,axis,at,b,c,from.x,at_along)
            current,ok:=vertex(r,local)
            if !ok {r.error=.Invalid_Grid;return}
            if started && previous.at!=current.at {iso_tetrahedron(r,{center,&apex,&previous,&current})}
            previous,started=current,true
            if at_along==end {break}
            at_along=forward?min((at_along/step+1)*step,end):max(((at_along-1)/step)*step,end)
            if r.error!=.None {return}
        }
    }
}

// Cells use [low,high); all six tetrahedra share their face diagonals with
// adjacent cells. Gradients read the full grid, including a chunk's halo.
// lod: the level of the region, and of its faces and edges; what a face or
// an edge shares takes the finer of its level and those around it.
isosurface :: proc(g:Scalar_Grid,low,high:[3]int,out:^Mesh_Buffer,isolevel:f32=0,lod:=Iso_Lod{}) -> Iso_Error {
    mesh_buffer_clear(out)
    if isolevel-isolevel!=0 {return .Invalid_Grid}
    g:=g
    if g.extent=={} {g.first,g.extent={},g.samples}
    if int(lod.level)>ISO_LEVELS_MAX {return .Invalid_Region}
    // The gradients of what the region shares reach a step of its level past it.
    reach:=1<<uint(lod.level)
    count:=1
    for axis in 0..<3 {
        n,first,extent:=g.samples[axis],g.first[axis],g.extent[axis]
        if n<2 || first<0 || extent<1 || first>n-extent || extent>max(int)/count || !(g.cell[axis]>0) || g.cell[axis]-g.cell[axis]!=0 || g.origin[axis]-g.origin[axis]!=0 {return .Invalid_Grid}
        count*=extent
        end:=g.origin[axis]+f32(n-1)*g.cell[axis]
        if end-end!=0 {return .Invalid_Grid}
        if low[axis]<0 || high[axis]>n-1 || low[axis]>high[axis] {return .Invalid_Region}
        if max(low[axis]-reach,0)<first || min(high[axis]+reach,n-1)>first+extent-1 {return .Invalid_Region}
    }
    if len(g.values)!=count {return .Invalid_Grid}
    r:=Iso_Region{g=g,low=low,size=high-low,level=int(lod.level),isolevel=isolevel,out=out}
    for &face,i in r.faces {face=min(int(lod.faces[i]),r.level)}
    for &edge,i in r.edges {
        axis:=i/4
        b,c:=(axis+1)%3,(axis+2)%3
        if b>c {b,c=c,b}
        edge=min(int(lod.edges[i]),r.faces[b*2+(i&1)],r.faces[c*2+((i>>1)&1)])
    }
    iso_cells(&r)
    if r.error!=.None {return r.error}
    vertices:=r.triangles*3
    if reserve(&out.positions,vertices)!=nil || reserve(&out.normals,vertices)!=nil || reserve(&out.indices,vertices)!=nil {return .Out_Of_Memory}
    r.emit=true
    iso_cells(&r)
    if r.error!=.None {mesh_buffer_clear(out);return r.error}
    return .None
}

@(private="file")
iso_cells :: proc(r:^Iso_Region) #no_bounds_check {
    step:=1<<uint(r.level)
    for z0:=0;z0<r.size.z; {
        z1:=min(z0+step,r.size.z)
        for y0:=0;y0<r.size.y; {
            y1:=min(y0+step,r.size.y)
            for x0:=0;x0<r.size.x; {
                x1:=min(x0+step,r.size.x)
                lo,hi:=[3]int{x0,y0,z0},[3]int{x1,y1,z1}
                if iso_cell_regular(r,lo,hi) {
                    corners:[8]Iso_Vertex
                    for corner in 0..<8 {
                        p:=r.low+[3]int{corner&1!=0?hi.x:lo.x,corner&2!=0?hi.y:lo.y,corner&4!=0?hi.z:lo.z}
                        if !iso_sample(r,p,&corners[corner]) {r.error=.Invalid_Grid;return}
                    }
                    for tetra in TETRAHEDRA {iso_tetrahedron(r,{&corners[tetra[0]],&corners[tetra[1]],&corners[tetra[2]],&corners[tetra[3]]})}
                } else {
                    // Coned from its center onto its faces, as each face is shared.
                    center,known:=iso_vertex(r,r.low*2+lo+hi)
                    if !known {r.error=.Invalid_Grid;return}
                    for axis in 0..<3 {
                        iso_face(r,axis,lo[axis],lo,hi,&center)
                        iso_face(r,axis,hi[axis],lo,hi,&center)
                    }
                }
                if r.error!=.None {return}
                x0=x1
            }
            y0=y1
        }
        z0=z1
    }
}
