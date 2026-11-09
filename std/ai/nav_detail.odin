package ai

import cmath "core:math"
import "core:math/linalg"
import "mirai:std/base"
import math "mirai:std/math"

// The detail mesh: per polygon, its edges sampled every detail_sample_distance
// and simplified to detail_max_error (in the same order from both sides, so
// neighbors share them), then triangulated, and samples inside added at the
// worst spot while the surface strays more than the error, up to
// NAV_DETAIL_MAX_VERTS vertices. Heights come from the voxels under the
// polygon, flooded from its own region so a floor above or below does not
// leak in.

@(private="file") NAV_UNSET_HEIGHT :: u16(0xffff)
@(private="file") NAV_DETAIL_MAX_VERTS :: 127
@(private="file") NAV_DETAIL_MAX_TRIS :: 255
@(private="file") NAV_DETAIL_EDGE_VERTS :: 32
@(private="file") NAV_DETAIL_MAX_SAMPLES :: 64 // per axis of a polygon: the spacing grows on larger ones
@(private="file") NAV_DETAIL_SEARCH :: 16      // cells around a sample without voxels where a height is looked for

// Heights of the floor under a polygon, in tile cells from (x, z).
@(private="file")
Nav_Patch :: struct {
    data:[]u16,
    x,z,width,height:int,
}

@(private="file")
Nav_Detail_Poly :: struct {
    verts:[NAV_DETAIL_MAX_VERTS]math.Vec3, // metres from the corner of the tile and from Nav_Grid.base; the polygon first
    count:int,
    hull:[NAV_DETAIL_MAX_VERTS]i32,        // the outline: the polygon and the samples of its edges
    hull_count:int,
}

@(private)
nav_build_detail :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> Nav_Build_Status {
    clear(&s.details)
    clear(&s.detail_verts)
    clear(&s.detail_out)
    tile,border:=int(g.tile),int(g.border)
    largest:=0
    for p in s.polys {
        low,high:=nav_poly_bounds(s,p,tile,border)
        largest=max(largest,(high.x-low.x)*(high.y-low.y))
    }
    if !nav_resize(&s.patch,largest) {return .Out_Of_Memory}
    radius:=int(nav_ceil(f64(g.max_error),1,NAV_DETAIL_SEARCH))
    origin:=[2]f64{f64(g.origin.x)+(f64(g.corner.x)+f64(border))*f64(g.cs),f64(g.origin.y)+(f64(g.corner.y)+f64(border))*f64(g.cs)}
    dp:Nav_Detail_Poly
    for p in s.polys {
        n:=int(p.count)
        polygon:[NAV_VERTS_PER_POLY]math.Vec3
        for k in 0..<n {
            v:=s.mesh_verts[p.vertices[k]]
            polygon[k]={f32(v.x)*g.cs,f32(v.y)*g.ch,f32(v.z)*g.cs}
        }
        low,high:=nav_poly_bounds(s,p,tile,border)
        patch:=Nav_Patch{s.patch[:(high.x-low.x)*(high.y-low.y)],low.x,low.y,high.x-low.x,high.y-low.y}
        if !nav_patch_heights(s,g,p,&patch) {return .Out_Of_Memory}
        if !nav_poly_detail(s,g,polygon[:n],&patch,radius,&dp) {return .Out_Of_Memory}
        if len(s.detail_out)+len(s.detail_tris)>int(max(u32)) {return .Too_Large}
        detail:=Nav_Detail{u32(len(s.detail_verts)),u32(len(s.detail_out)),u16(dp.count-n),u16(len(s.detail_tris))}
        if _,error:=append(&s.details,detail);error!=nil {return .Out_Of_Memory}
        for k in n..<dp.count {
            v:=dp.verts[k]
            height:=nav_floor(f64(v.y)/f64(g.ch)+0.5,-1,NAV_SPAN_MAX+1)
            world:=math.Vec3{f32(origin.x+f64(v.x)),f32((g.base+f64(height))*f64(g.ch)),f32(origin.y+f64(v.z))}
            if _,error:=append(&s.detail_verts,world);error!=nil {return .Out_Of_Memory}
        }
        for t in s.detail_tris {
            if _,error:=append(&s.detail_out,Nav_Detail_Triangle{u8(t[0]),u8(t[1]),u8(t[2]),u8(t[3])});error!=nil {return .Out_Of_Memory}
        }
    }
    return .Built
}

// The cells under the polygon and one around, within the heightfield.
@(private="file")
nav_poly_bounds :: proc "contextless" (s:^Nav_Build_Scratch,p:Nav_Mesh_Poly,tile,border:int) -> (low,high:[2]int) {
    low,high={max(int),max(int)},{min(int),min(int)}
    for k in 0..<int(p.count) {
        v:=s.mesh_verts[p.vertices[k]]
        low={min(low.x,int(v.x)),min(low.y,int(v.z))}
        high={max(high.x,int(v.x)),max(high.y,int(v.z))}
    }
    low={max(low.x-1,-border),max(low.y-1,-border)}
    high={min(high.x+1,tile+border),min(high.y+1,tile+border)}
    if high.x<low.x {high.x=low.x}
    if high.y<low.y {high.y=low.y}
    return
}

// Fills the patch with the floor of the region of the polygon, then floods
// from its edges to the cells around, which the samples near the outline read.
@(private="file")
nav_patch_heights :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,p:Nav_Mesh_Poly,patch:^Nav_Patch) -> bool {
    side,border:=int(g.side),int(g.border)
    for &h in patch.data {h=NAV_UNSET_HEIGHT}
    clear(&s.stack)
    empty:=true
    // A polygon that joined several regions may overlap one of them: it seeds from its center instead.
    if p.region!=0 {
        for hz in 0..<patch.height {
            z:=patch.z+hz+border
            for hx in 0..<patch.width {
                x:=patch.x+hx+border
                for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                    if s.region[i]!=p.region {continue}
                    patch.data[hx+hz*patch.width]=s.compact[i].y
                    empty=false
                    edge:=false
                    for dir in 0..<4 {
                        con:=nav_con(s.compact[i],dir)
                        if con!=NAV_NOT_CONNECTED && s.region[nav_neighbor(s,side,x,z,dir,con)]!=p.region {edge=true;break}
                    }
                    if edge {
                        if _,error:=append(&s.stack,Nav_Level_Entry{i32(x),i32(z),i32(i)});error!=nil {return false}
                    }
                    break
                }
            }
        }
    }
    if empty && !nav_patch_seed_center(s,g,p,patch) {return false}
    for head:=0;head<len(s.stack);head+=1 {
        e:=s.stack[head]
        for dir in 0..<4 {
            con:=nav_con(s.compact[e.index],dir)
            if con==NAV_NOT_CONNECTED {continue}
            ax,az:=int(e.x)+nav_dx(dir),int(e.z)+nav_dz(dir)
            hx,hz:=ax-patch.x-border,az-patch.z-border
            if hx<0 || hz<0 || hx>=patch.width || hz>=patch.height {continue}
            if patch.data[hx+hz*patch.width]!=NAV_UNSET_HEIGHT {continue}
            a:=int(s.cells[ax+az*side])+con
            patch.data[hx+hz*patch.width]=s.compact[a].y
            if _,error:=append(&s.stack,Nav_Level_Entry{i32(ax),i32(az),i32(a)});error!=nil {return false}
        }
    }
    return true
}

// Seeds the flood with the span nearest the center of the polygon, reached
// walking from the span closest in height to one of its vertices.
@(private="file")
nav_patch_seed_center :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,p:Nav_Mesh_Poly,patch:^Nav_Patch) -> bool {
    side,border:=int(g.side),int(g.border)
    OFFSETS :: [9][2]int{{0,0},{-1,-1},{0,-1},{1,-1},{1,0},{1,1},{0,1},{-1,1},{-1,0}}
    start:=Nav_Level_Entry{index=-1}
    closest:=int(NAV_UNSET_HEIGHT)
    center:[2]int
    n:=int(p.count)
    for k in 0..<n {
        v:=s.mesh_verts[p.vertices[k]]
        center+={int(v.x),int(v.z)}
        for offset in OFFSETS {
            ax,az:=int(v.x)+offset.x,int(v.z)+offset.y
            if ax<patch.x || az<patch.z || ax>=patch.x+patch.width || az>=patch.z+patch.height {continue}
            c:=ax+border+(az+border)*side
            for i in int(s.cells[c])..<int(s.cells[c+1]) {
                if d:=abs(int(v.y)-int(s.compact[i].y));d<closest {
                    closest=d
                    start={i32(ax),i32(az),i32(i)}
                }
            }
        }
    }
    if start.index<0 {return true}
    center/=n
    for &h in patch.data {h=0}
    clear(&s.stack)
    if _,error:=append(&s.stack,start);error!=nil {return false}
    current:=start
    for len(s.stack)>0 {
        current=pop(&s.stack)
        x,z:=int(current.x),int(current.z)
        if x==center.x && z==center.y {break}
        // The direction straight to the center is pushed last, to be taken next.
        toward:=2 if center.x>x else 0
        if x==center.x {toward=1 if center.y>z else 3}
        dirs:=[4]int{0,1,2,3}
        dirs[toward],dirs[3]=dirs[3],dirs[toward]
        for dir in dirs {
            con:=nav_con(s.compact[current.index],dir)
            if con==NAV_NOT_CONNECTED {continue}
            nx,nz:=x+nav_dx(dir),z+nav_dz(dir)
            hx,hz:=nx-patch.x,nz-patch.z
            if hx<0 || hz<0 || hx>=patch.width || hz>=patch.height || patch.data[hx+hz*patch.width]!=0 {continue}
            patch.data[hx+hz*patch.width]=1
            a:=int(s.cells[nx+border+(nz+border)*side])+con
            if _,error:=append(&s.stack,Nav_Level_Entry{i32(nx),i32(nz),i32(a)});error!=nil {return false}
        }
    }
    for &h in patch.data {h=NAV_UNSET_HEIGHT}
    clear(&s.stack)
    seed:=Nav_Level_Entry{current.x+i32(border),current.z+i32(border),current.index}
    if _,error:=append(&s.stack,seed);error!=nil {return false}
    patch.data[int(current.x)-patch.x+(int(current.z)-patch.z)*patch.width]=s.compact[current.index].y
    return true
}

// The height cell of the floor at a point in metres from the corner of the
// tile: the patch there, else the nearest ring of cells around that has one
// (the closest in height), else the height of the point.
@(private="file")
nav_patch_height :: proc "contextless" (patch:^Nav_Patch,p:math.Vec3,g:^Nav_Grid,radius:int) -> u16 {
    if patch.width==0 || patch.height==0 {return u16(nav_floor(f64(p.y)/f64(g.ch),0,NAV_SPAN_MAX-1))}
    ix:=int(nav_floor(f64(p.x*g.ics+0.01),-1<<30,1<<30))-patch.x
    iz:=int(nav_floor(f64(p.z*g.ics+0.01),-1<<30,1<<30))-patch.z
    ix,iz=clamp(ix,0,patch.width-1),clamp(iz,0,patch.height-1)
    h:=patch.data[ix+iz*patch.width]
    if h!=NAV_UNSET_HEIGHT {return h}
    best:=max(f32)
    look :: #force_inline proc "contextless" (patch:^Nav_Patch,x,z:int,y,ch:f32,best:^f32,h:^u16) {
        if x<0 || z<0 || x>=patch.width || z>=patch.height {return}
        nh:=patch.data[x+z*patch.width]
        if nh==NAV_UNSET_HEIGHT {return}
        if d:=abs(f32(nh)*ch-y);d<best^ {best^=d;h^=nh}
    }
    for r in 1..=min(radius,max(patch.width,patch.height)) {
        for d in -r..=r {
            look(patch,ix+d,iz-r,p.y,g.ch,&best,&h)
            look(patch,ix+d,iz+r,p.y,g.ch,&best,&h)
        }
        for d in -r+1..=r-1 {
            look(patch,ix-r,iz+d,p.y,g.ch,&best,&h)
            look(patch,ix+r,iz+d,p.y,g.ch,&best,&h)
        }
        if h!=NAV_UNSET_HEIGHT {return h}
    }
    return u16(nav_floor(f64(p.y)/f64(g.ch),0,NAV_SPAN_MAX-1))
}

@(private="file")
nav_distance2_segment_xz :: proc "contextless" (p,a,b:math.Vec3) -> f32 {
    dx,dz:=b.x-a.x,b.z-a.z
    ex,ez:=p.x-a.x,p.z-a.z
    length2:=dx*dx+dz*dz
    t:=dx*ex+dz*ez
    if length2>0 {t/=length2}
    t=clamp(t,0,1)
    ex,ez=a.x+t*dx-p.x,a.z+t*dz-p.z
    return ex*ex+ez*ez
}

// The distance on XZ to the outline of the polygon, negative inside.
@(private="file")
nav_distance_to_poly :: proc "contextless" (polygon:[]math.Vec3,p:math.Vec3) -> f32 {
    closest:=max(f32)
    inside:=false
    j:=len(polygon)-1
    for i in 0..<len(polygon) {
        a,b:=polygon[i],polygon[j]
        if (a.z>p.z)!=(b.z>p.z) && p.x<(b.x-a.x)*(p.z-a.z)/(b.z-a.z)+a.x {inside=!inside}
        closest=min(closest,nav_distance2_segment_xz(p,b,a))
        j=i
    }
    d:=cmath.sqrt(closest)
    return -d if inside else d
}

@(private="file")
nav_poly_min_extent :: proc "contextless" (polygon:[]math.Vec3) -> f32 {
    smallest:=max(f32)
    n:=len(polygon)
    for i in 0..<n {
        a,b:=polygon[i],polygon[(i+1)%n]
        widest:f32
        for j in 0..<n {
            if j==i || j==(i+1)%n {continue}
            widest=max(widest,nav_distance2_segment_xz(polygon[j],a,b))
        }
        smallest=min(smallest,widest)
    }
    return cmath.sqrt(smallest)
}

// The vertical distance from the point to the triangle of the mesh under
// it, or -1 when no triangle covers it.
@(private="file")
nav_distance_to_mesh :: proc "contextless" (p:math.Vec3,verts:[]math.Vec3,tris:[][4]i32) -> f32 {
    closest:=max(f32)
    for t in tris {
        a,b,c:=verts[t[0]],verts[t[1]],verts[t[2]]
        v0,v1,v2:=c-a,b-a,p-a
        d00,d01,d02:=v0.x*v0.x+v0.z*v0.z,v0.x*v1.x+v0.z*v1.z,v0.x*v2.x+v0.z*v2.z
        d11,d12:=v1.x*v1.x+v1.z*v1.z,v1.x*v2.x+v1.z*v2.z
        denominator:=d00*d11-d01*d01
        if denominator==0 {continue}
        inverse:=1/denominator
        u:=(d11*d02-d01*d12)*inverse
        v:=(d00*d12-d01*d02)*inverse
        EPSILON :: 1e-4
        if u>= -EPSILON && v>= -EPSILON && u+v<=1+EPSILON {
            closest=min(closest,abs(a.y+v0.y*u+v1.y*v-p.y))
        }
    }
    return -1 if closest==max(f32) else closest
}

@(private="file")
nav_circumcircle :: proc "contextless" (a,b,c:math.Vec3) -> (center:math.Vec3,radius:f32) {
    cross:=cross_xz(a,b,c)
    if abs(cross)<=1e-6 {return a,0}
    a2,b2,c2:=a.x*a.x+a.z*a.z,b.x*b.x+b.z*b.z,c.x*c.x+c.z*c.z
    center.x=(a2*(b.z-c.z)+b2*(c.z-a.z)+c2*(a.z-b.z))/(2*cross)
    center.z=(a2*(c.x-b.x)+b2*(a.x-c.x)+c2*(b.x-a.x))/(2*cross)
    dx,dz:=center.x-a.x,center.z-a.z
    return center,cmath.sqrt(dx*dx+dz*dz)
}

@(private="file") NAV_EDGE_UNDEFINED :: -1
@(private="file") NAV_EDGE_HULL :: -2

@(private="file")
nav_find_edge :: proc "contextless" (edges:[][4]i32,a,b:i32) -> int {
    for e,i in edges {if e[0]==a && e[1]==b || e[0]==b && e[1]==a {return i}}
    return NAV_EDGE_UNDEFINED
}

@(private="file")
nav_update_left_face :: proc "contextless" (e:^[4]i32,a,b,face:i32) {
    if e[0]==a && e[1]==b && e[2]==NAV_EDGE_UNDEFINED {
        e[2]=face
    } else if e[1]==a && e[0]==b && e[3]==NAV_EDGE_UNDEFINED {
        e[3]=face
    }
}

@(private="file")
nav_segments_overlap :: proc "contextless" (a,b,c,d:math.Vec3) -> bool {
    a1,a2:=cross_xz(a,b,d),cross_xz(a,b,c)
    if a1*a2<0 {
        a3:=cross_xz(c,d,a)
        if a3*(a3+a2-a1)<0 {return true}
    }
    return false
}

@(private="file")
nav_overlaps_edges :: proc "contextless" (pts:[]math.Vec3,edges:[][4]i32,a,b:i32) -> bool {
    for e in edges {
        if e[0]==a || e[0]==b || e[1]==a || e[1]==b {continue}
        if nav_segments_overlap(pts[e[0]],pts[e[1]],pts[a],pts[b]) {return true}
    }
    return false
}

// Finds the triangle on the open side of edge e whose circumcircle holds no
// other point, and adds its edges.
@(private="file")
nav_complete_facet :: proc(s:^Nav_Build_Scratch,pts:[]math.Vec3,faces:^i32,e:int,max_edges:int) -> bool {
    edge:=s.detail_edges[e]
    a,b:i32
    if edge[2]==NAV_EDGE_UNDEFINED {
        a,b=edge[0],edge[1]
    } else if edge[3]==NAV_EDGE_UNDEFINED {
        a,b=edge[1],edge[0]
    } else {
        return true
    }
    best:=i32(len(pts))
    center:math.Vec3
    radius:=f32(-1)
    for u in 0..<i32(len(pts)) {
        if u==a || u==b || cross_xz(pts[a],pts[b],pts[u])<=1e-5 {continue}
        if radius<0 {
            best=u
            center,radius=nav_circumcircle(pts[a],pts[b],pts[u])
            continue
        }
        dx,dz:=center.x-pts[u].x,center.z-pts[u].z
        d:=cmath.sqrt(dx*dx+dz*dz)
        TOLERANCE :: 0.001
        if d>radius*(1+TOLERANCE) {continue}
        if d>=radius*(1-TOLERANCE) {
            // On the circle: the new edges must not cross the existing ones.
            if nav_overlaps_edges(pts,s.detail_edges[:],a,u) || nav_overlaps_edges(pts,s.detail_edges[:],b,u) {continue}
        }
        best=u
        center,radius=nav_circumcircle(pts[a],pts[b],pts[u])
    }
    if best>=i32(len(pts)) {
        nav_update_left_face(&s.detail_edges[e],a,b,NAV_EDGE_HULL)
        return true
    }
    face:=faces^
    nav_update_left_face(&s.detail_edges[e],a,b,face)
    for pair in ([2][2]i32{{best,a},{b,best}}) {
        if found:=nav_find_edge(s.detail_edges[:],pair[0],pair[1]);found!=NAV_EDGE_UNDEFINED {
            nav_update_left_face(&s.detail_edges[found],pair[0],pair[1],face)
        } else if len(s.detail_edges)<max_edges {
            if _,error:=append(&s.detail_edges,[4]i32{pair[0],pair[1],face,NAV_EDGE_UNDEFINED});error!=nil {return false}
        }
    }
    faces^+=1
    return true
}

@(private="file")
nav_delaunay_hull :: proc(s:^Nav_Build_Scratch,dp:^Nav_Detail_Poly) -> bool {
    pts:=dp.verts[:dp.count]
    clear(&s.detail_edges)
    clear(&s.detail_tris)
    max_edges:=dp.count*10
    for i,j:=0,dp.hull_count-1;i<dp.hull_count;j,i=i,i+1 {
        a,b:=dp.hull[j],dp.hull[i]
        if nav_find_edge(s.detail_edges[:],a,b)!=NAV_EDGE_UNDEFINED {continue}
        if _,error:=append(&s.detail_edges,[4]i32{a,b,NAV_EDGE_HULL,NAV_EDGE_UNDEFINED});error!=nil {return false}
    }
    faces:i32
    for e:=0;e<len(s.detail_edges);e+=1 {
        if s.detail_edges[e][2]==NAV_EDGE_UNDEFINED && !nav_complete_facet(s,pts,&faces,e,max_edges) {return false}
        if s.detail_edges[e][3]==NAV_EDGE_UNDEFINED && !nav_complete_facet(s,pts,&faces,e,max_edges) {return false}
    }
    if !nav_resize(&s.detail_tris,int(faces)) {return false}
    for &t in s.detail_tris {t={-1,-1,-1,0}}
    for e in s.detail_edges {
        if e[3]>=0 {
            t:=&s.detail_tris[e[3]]
            if t[0]==-1 {
                t[0],t[1]=e[0],e[1]
            } else if t[0]==e[1] {
                t[2]=e[0]
            } else if t[1]==e[0] {
                t[2]=e[1]
            }
        }
        if e[2]>=0 {
            t:=&s.detail_tris[e[2]]
            if t[0]==-1 {
                t[0],t[1]=e[1],e[0]
            } else if t[0]==e[0] {
                t[2]=e[1]
            } else if t[1]==e[1] {
                t[2]=e[0]
            }
        }
    }
    for i:=0;i<len(s.detail_tris); {
        t:=s.detail_tris[i]
        if t[0]<0 || t[1]<0 || t[2]<0 {unordered_remove(&s.detail_tris,i)} else {i+=1}
    }
    return true
}

// Fans the hull from its ear with the shortest perimeter, advancing on the
// side whose next triangle is shorter.
@(private="file")
nav_triangulate_hull :: proc(s:^Nav_Build_Scratch,dp:^Nav_Detail_Poly,polygon_count:int) -> bool {
    clear(&s.detail_tris)
    n:=dp.hull_count
    if n<3 {return true}
    pts:=dp.verts[:dp.count]
    hull:=dp.hull[:n]
    distance :: #force_inline proc "contextless" (a,b:math.Vec3) -> f32 {dx,dz:=b.x-a.x,b.z-a.z;return cmath.sqrt(dx*dx+dz*dz)}
    start,left,right:=0,1,n-1
    shortest:=max(f32)
    for i in 0..<n {
        if int(hull[i])>=polygon_count {continue}
        previous,next:=(i+n-1)%n,(i+1)%n
        a,b,c:=pts[hull[previous]],pts[hull[i]],pts[hull[next]]
        if d:=distance(a,b)+distance(b,c)+distance(c,a);d<shortest {
            start,left,right,shortest=i,next,previous,d
        }
    }
    if _,error:=append(&s.detail_tris,[4]i32{hull[start],hull[left],hull[right],0});error!=nil {return false}
    for (left+1)%n!=right {
        next_left,next_right:=(left+1)%n,(right+n-1)%n
        left_cost:=distance(pts[hull[left]],pts[hull[next_left]])+distance(pts[hull[next_left]],pts[hull[right]])
        right_cost:=distance(pts[hull[right]],pts[hull[next_right]])+distance(pts[hull[left]],pts[hull[next_right]])
        if left_cost<right_cost {
            if _,error:=append(&s.detail_tris,[4]i32{hull[left],hull[next_left],hull[right],0});error!=nil {return false}
            left=next_left
        } else {
            if _,error:=append(&s.detail_tris,[4]i32{hull[left],hull[next_right],hull[right],0});error!=nil {return false}
            right=next_right
        }
    }
    return true
}

@(private="file")
nav_jitter :: #force_inline proc "contextless" (i:int,k:u32) -> f32 {
    return f32((u32(i)*k)&0xffff)/65535*2-1
}

@(private="file")
nav_poly_detail :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,polygon:[]math.Vec3,patch:^Nav_Patch,radius:int,dp:^Nav_Detail_Poly) -> bool {
    n:=len(polygon)
    for k in 0..<n {dp.verts[k]=polygon[k]}
    dp.count=n
    dp.hull_count=0
    clear(&s.detail_tris)
    spacing:=g.sample_distance
    error2:=g.sample_error*g.sample_error
    if spacing>0 {
        for i,j:=0,n-1;i<n;j,i=i,i+1 {
            from,to:=polygon[j],polygon[i]
            // Sampled in the same order from both polygons that share the edge.
            swapped:=false
            if abs(from.x-to.x)<1e-6 {
                if from.z>to.z {from,to=to,from;swapped=true}
            } else if from.x>to.x {
                from,to=to,from
                swapped=true
            }
            delta:=to-from
            length:=cmath.sqrt(delta.x*delta.x+delta.z*delta.z)
            samples:=1+int(nav_floor(f64(length/spacing),0,NAV_DETAIL_EDGE_VERTS))
            samples=min(samples,NAV_DETAIL_EDGE_VERTS-1,NAV_DETAIL_MAX_VERTS-1-dp.count)
            samples=max(samples,1)
            edge:[NAV_DETAIL_EDGE_VERTS+1]math.Vec3
            for k in 0..=samples {
                p:=from+delta*(f32(k)/f32(samples))
                p.y=f32(nav_patch_height(patch,p,g,radius))*g.ch
                edge[k]=p
            }
            kept:[NAV_DETAIL_EDGE_VERTS+1]int
            kept[0],kept[1]=0,samples
            kept_count:=2
            for k:=0;k<kept_count-1; {
                a,b:=kept[k],kept[k+1]
                worst,worst_d:=-1,f32(0)
                for m in a+1..<b {
                    on,_:=math.closest_point_segment(edge[m],{edge[a],edge[b]})
                    if d:=linalg.length2(on-edge[m]);d>worst_d {worst,worst_d=m,d}
                }
                if worst>=0 && worst_d>error2 {
                    for m:=kept_count;m>k+1;m-=1 {kept[m]=kept[m-1]}
                    kept[k+1]=worst
                    kept_count+=1
                } else {
                    k+=1
                }
            }
            dp.hull[dp.hull_count]=i32(j)
            dp.hull_count+=1
            for m in 1..<kept_count-1 {
                v:=edge[kept[kept_count-1-m]] if swapped else edge[kept[m]]
                dp.verts[dp.count]=v
                dp.hull[dp.hull_count]=i32(dp.count)
                dp.count+=1
                dp.hull_count+=1
            }
        }
    } else {
        for k in 0..<n {dp.hull[k]=i32((k+n-1)%n)}
        dp.hull_count=n
    }
    if !nav_triangulate_hull(s,dp,n) {return false}
    if spacing>0 && len(s.detail_tris)>0 && nav_poly_min_extent(polygon)>=spacing*2 {
        low,high:=polygon[0],polygon[0]
        for p in polygon[1:] {low=math.vec3_min(low,p);high=math.vec3_max(high,p)}
        step:=spacing
        widest:=max(high.x-low.x,high.z-low.z)
        if widest/step>NAV_DETAIL_MAX_SAMPLES {step=widest/NAV_DETAIL_MAX_SAMPLES}
        x0:=int(nav_floor(f64(low.x/step),-1<<30,1<<30))
        x1:=int(nav_ceil(f64(high.x/step),-1<<30,1<<30))
        z0:=int(nav_floor(f64(low.z/step),-1<<30,1<<30))
        z1:=int(nav_ceil(f64(high.z/step),-1<<30,1<<30))
        clear(&s.samples)
        for z in z0..<z1 {
            for x in x0..<x1 {
                p:=math.Vec3{f32(x)*step,(low.y+high.y)*0.5,f32(z)*step}
                if nav_distance_to_poly(polygon,p)> -step/2 {continue}
                if _,error:=append(&s.samples,[4]i32{i32(x),i32(nav_patch_height(patch,p,g,radius)),i32(z),0});error!=nil {return false}
            }
        }
        for _ in 0..<len(s.samples) {
            if dp.count>=NAV_DETAIL_MAX_VERTS {break}
            best:=-1
            best_d:f32
            best_p:math.Vec3
            for sample,i in s.samples {
                if sample[3]!=0 {continue}
                // Jittered off the grid: symmetric samples triangulate badly.
                p:=math.Vec3{f32(sample.x)*step+nav_jitter(i,0x8da6b343)*g.cs*0.1,f32(sample.y)*g.ch,f32(sample.z)*step+nav_jitter(i,0xd8163841)*g.cs*0.1}
                d:=nav_distance_to_mesh(p,dp.verts[:dp.count],s.detail_tris[:])
                if d<0 {continue}
                if d>best_d {best,best_d,best_p=i,d,p}
            }
            if best<0 || best_d<=g.sample_error {break}
            s.samples[best][3]=1
            dp.verts[dp.count]=best_p
            dp.count+=1
            if !nav_delaunay_hull(s,dp) {return false}
        }
    }
    if len(s.detail_tris)==0 {
        for k in 2..<dp.count {
            if _,error:=append(&s.detail_tris,[4]i32{0,i32(k-1),i32(k),0});error!=nil {return false}
        }
    }
    base.truncate(&s.detail_tris,NAV_DETAIL_MAX_TRIS)
    on_hull :: proc "contextless" (dp:^Nav_Detail_Poly,a,b:i32) -> bool {
        for i,j:=0,dp.hull_count-1;i<dp.hull_count;j,i=i,i+1 {
            if dp.hull[j]==a && dp.hull[i]==b || dp.hull[j]==b && dp.hull[i]==a {return true}
        }
        return false
    }
    for &t in s.detail_tris {
        // Counter-clockwise seen from above, like the polygons.
        if cross_xz(dp.verts[t[0]],dp.verts[t[1]],dp.verts[t[2]])>0 {t[1],t[2]=t[2],t[1]}
        flags:i32
        if on_hull(dp,t[0],t[1]) {flags|=1}
        if on_hull(dp,t[1],t[2]) {flags|=1<<2}
        if on_hull(dp,t[2],t[0]) {flags|=1<<4}
        t[3]=flags
    }
    return true
}
