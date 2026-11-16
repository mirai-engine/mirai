package ai

import "mirai:std/base"

// The polygon mesh: each contour is triangulated by ear clipping and its
// triangles merged greedily into convex polygons of up to NAV_VERTS_PER_POLY
// vertices, longest shared edge first. Vertices are shared between contours,
// those flagged on the tile border between regions are removed and the hole
// they leave filled again, and edges are linked to the polygon across them or
// marked as portals on the border of the tile.

@(private) NAV_NULL_INDEX :: u16(0xffff)
@(private) NAV_VERTEX_BUCKETS :: 1<<12

@(private)
Nav_Mesh_Poly :: struct {
    vertices:[NAV_VERTS_PER_POLY]u16, // NAV_NULL_INDEX past the last
    neighbor:[NAV_VERTS_PER_POLY]u16, // polygon index, NAV_EDGE_PORTAL|side, or NAV_NULL_INDEX
    count:u8,
    area:u8,
    region:u16,                       // 0 once it joins polygons of several regions
}

@(private)
Nav_Mesh_Edge :: struct {vert,poly,edge:[2]u16}

// Twice the signed area of a, b, c on XZ: negative when c lies to the left
// of a to b, which is counter-clockwise seen from above.
@(private)
nav_area2 :: #force_inline proc "contextless" (a,b,c:[4]i32) -> int {
    return (int(b.x)-int(a.x))*(int(c.z)-int(a.z))-(int(c.x)-int(a.x))*(int(b.z)-int(a.z))
}
@(private) nav_left :: #force_inline proc "contextless" (a,b,c:[4]i32) -> bool {return nav_area2(a,b,c)<0}
@(private) nav_left_on :: #force_inline proc "contextless" (a,b,c:[4]i32) -> bool {return nav_area2(a,b,c)<=0}
@(private) nav_same_xz :: #force_inline proc "contextless" (a,b:[4]i32) -> bool {return a.x==b.x && a.z==b.z}

@(private="file")
nav_between :: proc "contextless" (a,b,c:[4]i32) -> bool {
    if nav_area2(a,b,c)!=0 {return false}
    if a.x!=b.x {return a.x<=c.x && c.x<=b.x || a.x>=c.x && c.x>=b.x}
    return a.z<=c.z && c.z<=b.z || a.z>=c.z && c.z>=b.z
}

// Whether the segments a-b and c-d meet, properly or at an end.
@(private)
nav_intersect :: proc "contextless" (a,b,c,d:[4]i32) -> bool {
    if nav_area2(a,b,c)!=0 && nav_area2(a,b,d)!=0 && nav_area2(c,d,a)!=0 && nav_area2(c,d,b)!=0 {
        if nav_left(a,b,c)!=nav_left(a,b,d) && nav_left(c,d,a)!=nav_left(c,d,b) {return true}
    }
    return nav_between(a,b,c) || nav_between(a,b,d) || nav_between(c,d,a) || nav_between(c,d,b)
}

@(private="file") NAV_EAR :: u32(0x80000000)
@(private="file") NAV_INDEX_MASK :: u32(0x0fffffff)

@(private="file")
nav_vert :: #force_inline proc "contextless" (verts:[][4]i32,indices:[]u32,i:int) -> [4]i32 {return verts[indices[i]&NAV_INDEX_MASK]}

// Whether i to j crosses no edge of the polygon that does not touch them.
@(private="file")
nav_diagonal_free :: proc "contextless" (i,j:int,verts:[][4]i32,indices:[]u32) -> bool {
    n:=len(indices)
    d0,d1:=nav_vert(verts,indices,i),nav_vert(verts,indices,j)
    for k in 0..<n {
        k1:=(k+1)%n
        if k==i || k1==i || k==j || k1==j {continue}
        p0,p1:=nav_vert(verts,indices,k),nav_vert(verts,indices,k1)
        if nav_same_xz(d0,p0) || nav_same_xz(d1,p0) || nav_same_xz(d0,p1) || nav_same_xz(d1,p1) {continue}
        if nav_intersect(d0,d1,p0,p1) {return false}
    }
    return true
}

@(private="file")
nav_in_cone :: proc "contextless" (i,j:int,verts:[][4]i32,indices:[]u32) -> bool {
    n:=len(indices)
    a,b:=nav_vert(verts,indices,i),nav_vert(verts,indices,j)
    next,previous:=nav_vert(verts,indices,(i+1)%n),nav_vert(verts,indices,(i+n-1)%n)
    if nav_left_on(previous,a,next) {return nav_left(a,b,previous) && nav_left(b,a,next)}
    return !(nav_left_on(a,b,next) && nav_left_on(b,a,previous))
}

@(private="file")
nav_diagonal :: proc "contextless" (i,j:int,verts:[][4]i32,indices:[]u32) -> bool {
    return nav_in_cone(i,j,verts,indices) && nav_diagonal_free(i,j,verts,indices)
}

// Ear clipping, shortest diagonal first. indices holds the polygon and is
// consumed; tris gets three vertex indices per triangle. Returns the count of
// triangles, negative when the polygon could not be finished.
@(private="file")
nav_triangulate :: proc "contextless" (verts:[][4]i32,indices:[]u32,tris:[]i32) -> int {
    n:=len(indices)
    count:=0
    for i in 0..<n {
        if nav_diagonal(i,(i+2)%n,verts,indices[:n]) {indices[(i+1)%n]|=NAV_EAR}
    }
    for n>3 {
        shortest,best:=-1,-1
        for i in 0..<n {
            i1:=(i+1)%n
            if indices[i1]&NAV_EAR==0 {continue}
            p0,p2:=nav_vert(verts,indices,i),nav_vert(verts,indices,(i1+1)%n)
            dx,dz:=int(p2.x-p0.x),int(p2.z-p0.z)
            if length:=dx*dx+dz*dz;shortest<0 || length<shortest {shortest=length;best=i}
        }
        if best<0 {return -count}
        i:=best
        i1:=(i+1)%n
        i2:=(i1+1)%n
        tris[count*3]=i32(indices[i]&NAV_INDEX_MASK)
        tris[count*3+1]=i32(indices[i1]&NAV_INDEX_MASK)
        tris[count*3+2]=i32(indices[i2]&NAV_INDEX_MASK)
        count+=1
        n-=1
        for k in i1..<n {indices[k]=indices[k+1]}
        if i1>=n {i1=0}
        i=(i1+n-1)%n
        if nav_diagonal((i+n-1)%n,i1,verts,indices[:n]) {indices[i]|=NAV_EAR} else {indices[i]&=NAV_INDEX_MASK}
        if nav_diagonal(i,(i1+1)%n,verts,indices[:n]) {indices[i1]|=NAV_EAR} else {indices[i1]&=NAV_INDEX_MASK}
    }
    if n==3 {
        tris[count*3]=i32(indices[0]&NAV_INDEX_MASK)
        tris[count*3+1]=i32(indices[1]&NAV_INDEX_MASK)
        tris[count*3+2]=i32(indices[2]&NAV_INDEX_MASK)
        count+=1
    }
    return count
}

@(private="file")
nav_poly_count :: #force_inline proc "contextless" (p:[NAV_VERTS_PER_POLY]u16) -> int {
    for i in 0..<NAV_VERTS_PER_POLY {if p[i]==NAV_NULL_INDEX {return i}}
    return NAV_VERTS_PER_POLY
}

@(private="file")
nav_uleft :: #force_inline proc "contextless" (a,b,c:[3]u16) -> bool {
    return (int(b.x)-int(a.x))*(int(c.z)-int(a.z))-(int(c.x)-int(a.x))*(int(b.z)-int(a.z))<0
}

// The squared length of the edge two polygons share when they can merge into
// a convex polygon that fits, else -1.
@(private="file")
nav_merge_value :: proc "contextless" (a,b:[NAV_VERTS_PER_POLY]u16,verts:[][3]u16) -> (value,ea,eb:int) {
    na,nb:=nav_poly_count(a),nav_poly_count(b)
    if na+nb-2>NAV_VERTS_PER_POLY {return -1,-1,-1}
    ea,eb=-1,-1
    search: for i in 0..<na {
        va0,va1:=a[i],a[(i+1)%na]
        if va0>va1 {va0,va1=va1,va0}
        for j in 0..<nb {
            vb0,vb1:=b[j],b[(j+1)%nb]
            if vb0>vb1 {vb0,vb1=vb1,vb0}
            if va0==vb0 && va1==vb1 {ea,eb=i,j;break search}
        }
    }
    if ea<0 {return -1,-1,-1}
    if !nav_uleft(verts[a[(ea+na-1)%na]],verts[a[ea]],verts[b[(eb+2)%nb]]) {return -1,-1,-1}
    if !nav_uleft(verts[b[(eb+nb-1)%nb]],verts[b[eb]],verts[a[(ea+2)%na]]) {return -1,-1,-1}
    p,q:=verts[a[ea]],verts[a[(ea+1)%na]]
    dx,dz:=int(p.x)-int(q.x),int(p.z)-int(q.z)
    return dx*dx+dz*dz,ea,eb
}

@(private="file")
nav_merge_into :: proc "contextless" (a:^[NAV_VERTS_PER_POLY]u16,b:[NAV_VERTS_PER_POLY]u16,ea,eb:int) {
    na,nb:=nav_poly_count(a^),nav_poly_count(b)
    merged:[NAV_VERTS_PER_POLY]u16=NAV_NULL_INDEX
    n:=0
    for i in 0..<na-1 {merged[n]=a[(ea+1+i)%na];n+=1}
    for i in 0..<nb-1 {merged[n]=b[(eb+1+i)%nb];n+=1}
    a^=merged
}

// Merges the polygons of s.merge, best pair first, until no pair merges.
@(private="file")
nav_merge_polys :: proc(s:^Nav_Build_Scratch) {
    polys:=s.merge[:]
    count:=len(polys)
    for {
        best,best_a,best_b,best_ea,best_eb:=0,0,0,0,0
        for j in 0..<count-1 {
            for k in j+1..<count {
                value,ea,eb:=nav_merge_value(polys[j].vertices,polys[k].vertices,s.mesh_verts[:])
                if value>best {best,best_a,best_b,best_ea,best_eb=value,j,k,ea,eb}
            }
        }
        if best<=0 {break}
        nav_merge_into(&polys[best_a].vertices,polys[best_b].vertices,best_ea,best_eb)
        if polys[best_a].region!=polys[best_b].region {polys[best_a].region=0}
        polys[best_b]=polys[count-1]
        count-=1
    }
    base.truncate(&s.merge,count)
}

@(private="file")
nav_add_vertex :: proc(s:^Nav_Build_Scratch,v:[4]i32) -> (u16,bool) {
    x,y,z:=u16(v.x),u16(v.y),u16(v.z)
    bucket:=int((u32(x)*0x8da6b343+u32(z)*0xcb1ab31f)&(NAV_VERTEX_BUCKETS-1))
    for i:=s.buckets[bucket];i>=0;i=s.vertex_next[i] {
        p:=s.mesh_verts[i]
        if p.x==x && p.z==z && abs(int(p.y)-int(y))<=2 {return u16(i),true}
    }
    i:=len(s.mesh_verts)
    if _,error:=append(&s.mesh_verts,[3]u16{x,y,z});error!=nil {return 0,false}
    if _,error:=append(&s.vertex_next,s.buckets[bucket]);error!=nil {return 0,false}
    if _,error:=append(&s.vertex_flags,0);error!=nil {return 0,false}
    s.buckets[bucket]=i32(i)
    return u16(i),true
}

@(private)
nav_build_polymesh :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> Nav_Build_Status {
    max_vertices,max_tris,max_per_contour:=0,0,0
    for c in s.contours {
        if c.count<3 {continue}
        max_vertices+=int(c.count)
        max_tris+=int(c.count)-2
        max_per_contour=max(max_per_contour,int(c.count))
    }
    if max_vertices==0 {return .Empty}
    if max_vertices>=0xfffe {return .Too_Large}
    clear(&s.mesh_verts)
    clear(&s.vertex_next)
    clear(&s.vertex_flags)
    clear(&s.polys)
    if !nav_resize(&s.buckets,NAV_VERTEX_BUCKETS) || !nav_resize(&s.indices,max_per_contour) || !nav_resize(&s.tris,max_per_contour*3) {return .Out_Of_Memory}
    if reserve(&s.mesh_verts,max_vertices)!=nil || reserve(&s.polys,max_tris)!=nil || reserve(&s.merge,max_per_contour)!=nil {return .Out_Of_Memory}
    for &b in s.buckets {b=-1}
    for c in s.contours {
        if c.count<3 {continue}
        verts:=s.contour_verts[c.first:c.first+c.count]
        n:=len(verts)
        for j in 0..<n {s.indices[j]=u32(j)}
        triangles:=nav_triangulate(verts,s.indices[:n],s.tris[:])
        triangles=abs(triangles)
        for j in 0..<n {
            index,ok:=nav_add_vertex(s,verts[j])
            if !ok {return .Out_Of_Memory}
            s.indices[j]=u32(index)
            if verts[j][3]&NAV_BORDER_VERTEX!=0 {s.vertex_flags[index]=1}
        }
        clear(&s.merge)
        for t in 0..<triangles {
            a,b,cc:=s.tris[t*3],s.tris[t*3+1],s.tris[t*3+2]
            if a==b || a==cc || b==cc {continue}
            p:=Nav_Mesh_Poly{area=c.area,region=c.region}
            p.vertices=NAV_NULL_INDEX
            p.vertices[0],p.vertices[1],p.vertices[2]=u16(s.indices[a]),u16(s.indices[b]),u16(s.indices[cc])
            append(&s.merge,p)
        }
        nav_merge_polys(s)
        for p in s.merge {
            if _,error:=append(&s.polys,p);error!=nil {return .Out_Of_Memory}
        }
    }
    for i:=0;i<len(s.mesh_verts); {
        if s.vertex_flags[i]==0 || !nav_can_remove_vertex(s,u16(i)) {
            i+=1
            continue
        }
        if !nav_remove_vertex(s,u16(i)) {return .Out_Of_Memory}
    }
    if len(s.polys)==0 {return .Empty}
    if len(s.polys)>int(NAV_EDGE_PORTAL)-2 {return .Too_Large}
    for &p in s.polys {
        p.count=u8(nav_poly_count(p.vertices))
        p.neighbor=NAV_NULL_INDEX
    }
    if !nav_link_polys(s) {return .Out_Of_Memory}
    tile:=u16(g.tile)
    for &p in s.polys {
        for j in 0..<int(p.count) {
            if p.neighbor[j]!=NAV_NULL_INDEX {continue}
            a,b:=s.mesh_verts[p.vertices[j]],s.mesh_verts[p.vertices[(j+1)%int(p.count)]]
            if a.x==0 && b.x==0 {
                p.neighbor[j]=NAV_EDGE_PORTAL|u16(Nav_Side.Neg_X)
            } else if a.z==tile && b.z==tile {
                p.neighbor[j]=NAV_EDGE_PORTAL|u16(Nav_Side.Pos_Z)
            } else if a.x==tile && b.x==tile {
                p.neighbor[j]=NAV_EDGE_PORTAL|u16(Nav_Side.Pos_X)
            } else if a.z==0 && b.z==0 {
                p.neighbor[j]=NAV_EDGE_PORTAL|u16(Nav_Side.Neg_Z)
            }
        }
    }
    return .Built
}

// A vertex can go when the polygons around it leave at least a triangle and
// form a single fan, open on at most two edges.
@(private="file")
nav_can_remove_vertex :: proc(s:^Nav_Build_Scratch,remove:u16) -> bool {
    remaining:=0
    clear(&s.edges)
    for &p in s.polys {
        n:=nav_poly_count(p.vertices)
        removed:=0
        for j in 0..<n {if p.vertices[j]==remove {removed+=1}}
        if removed==0 {continue}
        remaining+=n-(removed+1)
        for j,k:=0,n-1;j<n;k,j=j,j+1 {
            if p.vertices[j]!=remove && p.vertices[k]!=remove {continue}
            other:=p.vertices[k] if p.vertices[j]==remove else p.vertices[j]
            exists:=false
            for &e in s.edges {
                if e[1]==i32(other) {e[2]+=1;exists=true}
            }
            if !exists {
                if _,error:=append(&s.edges,[4]i32{i32(remove),i32(other),1,0});error!=nil {return false}
            }
        }
    }
    if remaining<=2 {return false}
    open:=0
    for e in s.edges {if e[2]<2 {open+=1}}
    return open<=2
}

// Removes the polygons around the vertex, and the vertex, and fills the hole
// they leave with new polygons.
@(private="file")
nav_remove_vertex :: proc(s:^Nav_Build_Scratch,remove:u16) -> bool {
    clear(&s.edges)
    for i:=0;i<len(s.polys); {
        p:=s.polys[i]
        n:=nav_poly_count(p.vertices)
        touches:=false
        for j in 0..<n {if p.vertices[j]==remove {touches=true}}
        if !touches {
            i+=1
            continue
        }
        for j,k:=0,n-1;j<n;k,j=j,j+1 {
            if p.vertices[j]==remove || p.vertices[k]==remove {continue}
            if _,error:=append(&s.edges,[4]i32{i32(p.vertices[k]),i32(p.vertices[j]),i32(p.region),i32(p.area)});error!=nil {return false}
        }
        s.polys[i]=s.polys[len(s.polys)-1]
        pop(&s.polys)
    }
    ordered_remove(&s.mesh_verts,int(remove))
    ordered_remove(&s.vertex_flags,int(remove))
    for &p in s.polys {
        for j in 0..<nav_poly_count(p.vertices) {if p.vertices[j]>remove {p.vertices[j]-=1}}
    }
    for &e in s.edges {
        if e[0]>i32(remove) {e[0]-=1}
        if e[1]>i32(remove) {e[1]-=1}
    }
    if len(s.edges)==0 {return true}
    // The boundary of the hole: vertex, region and area of the edge from it.
    clear(&s.hole)
    if _,error:=append(&s.hole,[3]i32{s.edges[0][0],s.edges[0][2],s.edges[0][3]});error!=nil {return false}
    for len(s.edges)>0 {
        matched:=false
        for i:=0;i<len(s.edges); {
            e:=s.edges[i]
            added:=false
            if s.hole[0][0]==e[1] {
                if _,error:=inject_at(&s.hole,0,[3]i32{e[0],e[2],e[3]});error!=nil {return false}
                added=true
            } else if s.hole[len(s.hole)-1][0]==e[0] {
                if _,error:=append(&s.hole,[3]i32{e[1],e[2],e[3]});error!=nil {return false}
                added=true
            }
            if added {
                s.edges[i]=s.edges[len(s.edges)-1]
                pop(&s.edges)
                matched=true
            } else {
                i+=1
            }
        }
        if !matched {break}
    }
    n:=len(s.hole)
    if !nav_resize(&s.tverts,n) || !nav_resize(&s.indices,n) || !nav_resize(&s.tris,n*3) {return false}
    for h,i in s.hole {
        v:=s.mesh_verts[h[0]]
        s.tverts[i]={i32(v.x),i32(v.y),i32(v.z),0}
        s.indices[i]=u32(i)
    }
    triangles:=abs(nav_triangulate(s.tverts[:],s.indices[:n],s.tris[:]))
    clear(&s.merge)
    for t in 0..<triangles {
        a,b,c:=s.tris[t*3],s.tris[t*3+1],s.tris[t*3+2]
        if a==b || a==c || b==c {continue}
        p:=Nav_Mesh_Poly{region=u16(s.hole[a][1]),area=u8(s.hole[a][2])}
        p.vertices=NAV_NULL_INDEX
        p.vertices[0],p.vertices[1],p.vertices[2]=u16(s.hole[a][0]),u16(s.hole[b][0]),u16(s.hole[c][0])
        if _,error:=append(&s.merge,p);error!=nil {return false}
    }
    nav_merge_polys(s)
    for p in s.merge {
        if _,error:=append(&s.polys,p);error!=nil {return false}
    }
    return true
}

// Links each edge to the polygon that shares it.
@(private="file")
nav_link_polys :: proc(s:^Nav_Build_Scratch) -> bool {
    vertex_count:=len(s.mesh_verts)
    if !nav_resize(&s.first_edge,vertex_count) {return false}
    for &f in s.first_edge {f=-1}
    clear(&s.next_edge)
    clear(&s.mesh_edges)
    for p,i in s.polys {
        n:=int(p.count)
        for j in 0..<n {
            v0,v1:=p.vertices[j],p.vertices[(j+1)%n]
            if v0>=v1 {continue}
            if _,error:=append(&s.mesh_edges,Nav_Mesh_Edge{{v0,v1},{u16(i),u16(i)},{u16(j),0}});error!=nil {return false}
            if _,error:=append(&s.next_edge,s.first_edge[v0]);error!=nil {return false}
            s.first_edge[v0]=i32(len(s.mesh_edges)-1)
        }
    }
    for p,i in s.polys {
        n:=int(p.count)
        for j in 0..<n {
            v0,v1:=p.vertices[j],p.vertices[(j+1)%n]
            if v0<=v1 {continue}
            for e:=s.first_edge[v1];e>=0;e=s.next_edge[e] {
                edge:=&s.mesh_edges[e]
                if edge.vert[1]==v0 && edge.poly[0]==edge.poly[1] {
                    edge.poly[1]=u16(i)
                    edge.edge[1]=u16(j)
                    break
                }
            }
        }
    }
    for e in s.mesh_edges {
        if e.poly[0]==e.poly[1] {continue}
        s.polys[e.poly[0]].neighbor[e.edge[0]]=e.poly[1]
        s.polys[e.poly[1]].neighbor[e.edge[1]]=e.poly[0]
    }
    return true
}
