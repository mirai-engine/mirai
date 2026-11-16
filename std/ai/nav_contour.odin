package ai

import "core:slice"

// Contours: the outline of each region traced along the edges of its spans,
// simplified to the vertices where the neighbor region or the area changes
// plus those the walls need to stay within max_error of the voxels, and with
// its holes joined to the outline. Vertices are (x, height, z, flags) in
// cells of the tile.

@(private) NAV_BORDER_VERTEX :: 0x10000 // a vertex on the tile border between two regions: the mesh removes it
@(private) NAV_AREA_BORDER :: 0x20000
@(private) NAV_REGION_MASK :: 0xffff

@(private)
Nav_Contour :: struct {
    first,count:i32, // in contour_verts
    region:u16,
    area:u8,
}

@(private)
Nav_Hole :: struct {contour,region,min_x,min_z,leftmost:i32}

@(private)
nav_build_contours :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> Nav_Build_Status {
    side:=int(g.side)
    if !nav_resize(&s.flags,len(s.compact)) {return .Out_Of_Memory}
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                r:=s.region[i]
                if r==0 || r&NAV_BORDER_REGION!=0 {continue}
                same:u8
                for dir in 0..<4 {
                    con:=nav_con(s.compact[i],dir)
                    if con!=NAV_NOT_CONNECTED && s.region[nav_neighbor(s,side,x,z,dir,con)]==r {same|=1<<uint(dir)}
                }
                s.flags[i]=same~0xf
            }
        }
    }
    clear(&s.contours)
    clear(&s.contour_verts)
    border:=i32(g.border)
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                if s.flags[i]==0 || s.flags[i]==0xf {
                    s.flags[i]=0
                    continue
                }
                clear(&s.raw)
                if !nav_walk_contour(s,side,x,z,i) {return .Out_Of_Memory}
                if !nav_simplify_contour(s,g.max_error,int(g.max_edge)) {return .Out_Of_Memory}
                if len(s.simple)<3 {continue}
                first:=len(s.contour_verts)
                for v in s.simple {
                    if _,error:=append(&s.contour_verts,[4]i32{v.x-border,v.y,v.z-border,v[3]});error!=nil {return .Out_Of_Memory}
                }
                contour:=Nav_Contour{i32(first),i32(len(s.simple)),s.region[i],s.area[i]}
                if _,error:=append(&s.contours,contour);error!=nil {return .Out_Of_Memory}
            }
        }
    }
    if len(s.contours)==0 {return .Empty}
    if !nav_merge_holes(s) {return .Out_Of_Memory}
    return .Built
}

// The height of the corner after the edge in direction dir: the highest
// floor of the four columns around it. It is a border vertex when two border
// columns meet two columns of different regions of the same area.
@(private="file")
nav_corner_height :: proc "contextless" (s:^Nav_Build_Scratch,side,x,z,i,dir:int) -> (height:int,border_vertex:bool) {
    span:=s.compact[i]
    height=int(span.y)
    turn:=(dir+1)&3
    regions:[4]u32
    regions[0]=u32(s.region[i])|u32(s.area[i])<<16
    if con:=nav_con(span,dir);con!=NAV_NOT_CONNECTED {
        ax,az:=x+nav_dx(dir),z+nav_dz(dir)
        a:=int(s.cells[ax+az*side])+con
        height=max(height,int(s.compact[a].y))
        regions[1]=u32(s.region[a])|u32(s.area[a])<<16
        if con2:=nav_con(s.compact[a],turn);con2!=NAV_NOT_CONNECTED {
            a2:=nav_neighbor(s,side,ax,az,turn,con2)
            height=max(height,int(s.compact[a2].y))
            regions[2]=u32(s.region[a2])|u32(s.area[a2])<<16
        }
    }
    if con:=nav_con(span,turn);con!=NAV_NOT_CONNECTED {
        ax,az:=x+nav_dx(turn),z+nav_dz(turn)
        a:=int(s.cells[ax+az*side])+con
        height=max(height,int(s.compact[a].y))
        regions[3]=u32(s.region[a])|u32(s.area[a])<<16
        if con2:=nav_con(s.compact[a],dir);con2!=NAV_NOT_CONNECTED {
            a2:=nav_neighbor(s,side,ax,az,dir,con2)
            height=max(height,int(s.compact[a2].y))
            regions[2]=u32(s.region[a2])|u32(s.area[a2])<<16
        }
    }
    flag:=u32(NAV_BORDER_REGION)
    for j in 0..<4 {
        a,b,c,d:=regions[j],regions[(j+1)&3],regions[(j+2)&3],regions[(j+3)&3]
        exterior:=a&b&flag!=0 && a==b
        interior:=(c|d)&flag==0
        if exterior && interior && c>>16==d>>16 && a!=0 && b!=0 && c!=0 && d!=0 {return height,true}
    }
    return height,false
}

// Walks the outline from the first edge of the span that faces another
// region, emitting a vertex per edge with the region across it.
@(private="file")
nav_walk_contour :: proc(s:^Nav_Build_Scratch,side,x,z,i:int) -> bool {
    x,z,i:=x,z,i
    dir:=0
    for s.flags[i]&(1<<uint(dir))==0 {dir+=1}
    start_i,start_dir:=i,dir
    area:=s.area[i]
    for _ in 0..<4*len(s.compact)+4 {
        con:=nav_con(s.compact[i],dir)
        if s.flags[i]&(1<<uint(dir))!=0 {
            height,border_vertex:=nav_corner_height(s,side,x,z,i,dir)
            px,pz:=x,z
            switch dir {
            case 0: pz+=1
            case 1: px+=1;pz+=1
            case 2: px+=1
            }
            r:=0
            if con!=NAV_NOT_CONNECTED {
                a:=nav_neighbor(s,side,x,z,dir,con)
                r=int(s.region[a])
                if s.area[a]!=area {r|=NAV_AREA_BORDER}
            }
            if border_vertex {r|=NAV_BORDER_VERTEX}
            if _,error:=append(&s.raw,[4]i32{i32(px),i32(height),i32(pz),i32(r)});error!=nil {return false}
            s.flags[i]&=~(1<<uint(dir))
            dir=(dir+1)&3
        } else {
            if con==NAV_NOT_CONNECTED {break}
            i=nav_neighbor(s,side,x,z,dir,con)
            x,z=x+nav_dx(dir),z+nav_dz(dir)
            dir=(dir+3)&3
        }
        if i==start_i && dir==start_dir {break}
    }
    return true
}

@(private="file")
nav_segment_distance2 :: proc "contextless" (x,z,px,pz,qx,qz:i32) -> f32 {
    dx,dz:=f32(qx-px),f32(qz-pz)
    ex,ez:=f32(x-px),f32(z-pz)
    d:=dx*dx+dz*dz
    t:=dx*ex+dz*ez
    if d>0 {t/=d}
    t=clamp(t,0,1)
    ex=f32(px)+t*dx-f32(x)
    ez=f32(pz)+t*dz-f32(z)
    return ex*ex+ez*ez
}

// Simplifies s.raw into s.simple. A simplified vertex keeps in its flags the
// region across the edge that starts at it.
@(private="file")
nav_simplify_contour :: proc(s:^Nav_Build_Scratch,max_error:f32,max_edge:int) -> bool {
    points:=s.raw[:]
    count:=len(points)
    clear(&s.simple)
    if count==0 {return true}
    point :: #force_inline proc "contextless" (points:[][4]i32,i:int) -> [4]i32 {return {points[i].x,points[i].y,points[i].z,i32(i)}}
    connected:=false
    for p in points {if p[3]&NAV_REGION_MASK!=0 {connected=true;break}}
    if connected {
        for i in 0..<count {
            a,b:=points[i][3],points[(i+1)%count][3]
            if a&NAV_REGION_MASK!=b&NAV_REGION_MASK || a&NAV_AREA_BORDER!=b&NAV_AREA_BORDER {
                if _,error:=append(&s.simple,point(points,i));error!=nil {return false}
            }
        }
    }
    if len(s.simple)==0 {
        low,high:=0,0
        for p,i in points {
            if p.x<points[low].x || p.x==points[low].x && p.z<points[low].z {low=i}
            if p.x>points[high].x || p.x==points[high].x && p.z>points[high].z {high=i}
        }
        if _,error:=append(&s.simple,point(points,low),point(points,high));error!=nil {return false}
    }
    // Walls and borders between areas get the raw point furthest from the
    // simplified edge until all are within the error. The raw points are
    // walked in the same order from both sides of an edge.
    for i:=0;i<len(s.simple); {
        a,b:=s.simple[i],s.simple[(i+1)%len(s.simple)]
        ai,bi:=int(a[3]),int(b[3])
        step,c,end:int
        if b.x>a.x || b.x==a.x && b.z>a.z {
            step,c,end=1,(ai+1)%count,bi
        } else {
            step,c,end=count-1,(bi+count-1)%count,ai
        }
        furthest:=-1
        largest:f32
        if points[c][3]&NAV_REGION_MASK==0 || points[c][3]&NAV_AREA_BORDER!=0 {
            for c!=end {
                if d:=nav_segment_distance2(points[c].x,points[c].z,a.x,a.z,b.x,b.z);d>largest {largest=d;furthest=c}
                c=(c+step)%count
            }
        }
        if furthest>=0 && largest>max_error*max_error {
            if _,error:=inject_at(&s.simple,i+1,point(points,furthest));error!=nil {return false}
        } else {
            i+=1
        }
    }
    if max_edge>0 {
        for i:=0;i<len(s.simple); {
            a,b:=s.simple[i],s.simple[(i+1)%len(s.simple)]
            ai,bi:=int(a[3]),int(b[3])
            split:=-1
            if points[(ai+1)%count][3]&NAV_REGION_MASK==0 {
                dx,dz:=int(b.x-a.x),int(b.z-a.z)
                if dx*dx+dz*dz>max_edge*max_edge {
                    n:=bi+count-ai if bi<ai else bi-ai
                    if n>1 {
                        // Rounded the same way from both sides of the edge.
                        split=(ai+n/2)%count if b.x>a.x || b.x==a.x && b.z>a.z else (ai+(n+1)/2)%count
                    }
                }
            }
            if split>=0 {
                if _,error:=inject_at(&s.simple,i+1,point(points,split));error!=nil {return false}
            } else {
                i+=1
            }
        }
    }
    for &p in s.simple {
        at:=int(p[3])
        p[3]=points[(at+1)%count][3]&(NAV_REGION_MASK|NAV_AREA_BORDER)|points[at][3]&NAV_BORDER_VERTEX
    }
    // Consecutive vertices at the same place confuse the triangulation.
    for i:=0;i<len(s.simple); {
        a,b:=s.simple[i],s.simple[(i+1)%len(s.simple)]
        if a.x==b.x && a.z==b.z {ordered_remove(&s.simple,i)} else {i+=1}
    }
    return true
}

@(private="file")
nav_contour_area :: proc "contextless" (verts:[][4]i32) -> int {
    area:=0
    j:=len(verts)-1
    for i in 0..<len(verts) {
        area+=int(verts[i].x)*int(verts[j].z)-int(verts[j].x)*int(verts[i].z)
        j=i
    }
    return (area+1)/2
}

@(private="file")
nav_contour_verts :: #force_inline proc "contextless" (s:^Nav_Build_Scratch,c:Nav_Contour) -> [][4]i32 {
    return s.contour_verts[c.first:c.first+c.count]
}

// Joins each hole (a contour wound backwards) to the outline of its region
// through the shortest diagonal from its leftmost vertex that crosses nothing.
@(private="file")
nav_merge_holes :: proc(s:^Nav_Build_Scratch) -> bool {
    clear(&s.holes)
    regions:=0
    for c,i in s.contours {
        verts:=nav_contour_verts(s,c)
        regions=max(regions,int(c.region)+1)
        if nav_contour_area(verts)>=0 {continue}
        hole:=Nav_Hole{contour=i32(i),region=i32(c.region),min_x=verts[0].x,min_z=verts[0].z}
        for v,k in verts {
            if v.x<hole.min_x || v.x==hole.min_x && v.z<hole.min_z {hole.min_x,hole.min_z,hole.leftmost=v.x,v.z,i32(k)}
        }
        if _,error:=append(&s.holes,hole);error!=nil {return false}
    }
    if len(s.holes)==0 {return true}
    if !nav_resize(&s.outlines,regions) {return false}
    for &o in s.outlines {o=-1}
    for c,i in s.contours {
        if s.outlines[c.region]<0 && nav_contour_area(nav_contour_verts(s,c))>=0 {s.outlines[c.region]=i32(i)}
    }
    slice.sort_by(s.holes[:],proc(a,b:Nav_Hole) -> bool {
        if a.region!=b.region {return a.region<b.region}
        if a.min_x!=b.min_x {return a.min_x<b.min_x}
        if a.min_z!=b.min_z {return a.min_z<b.min_z}
        return a.contour<b.contour
    })
    for h in 0..<len(s.holes) {
        hole:=s.holes[h]
        outline_index:=s.outlines[hole.region]
        if outline_index<0 {continue}
        group_end:=h
        for group_end<len(s.holes) && s.holes[group_end].region==hole.region {group_end+=1}
        found,best:=-1,int(hole.leftmost)
        hole_count:=int(s.contours[hole.contour].count)
        for _ in 0..<hole_count {
            outline:=nav_contour_verts(s,s.contours[outline_index])
            corner:=nav_contour_verts(s,s.contours[hole.contour])[best]
            clear(&s.diagonals)
            for j in 0..<len(outline) {
                if !nav_in_cone_point(outline,j,corner) {continue}
                dx,dz:=outline[j].x-corner.x,outline[j].z-corner.z
                if _,error:=append(&s.diagonals,[2]i32{i32(j),dx*dx+dz*dz});error!=nil {return false}
            }
            slice.sort_by(s.diagonals[:],proc(a,b:[2]i32) -> bool {return a[1]<b[1] || a[1]==b[1] && a[0]<b[0]})
            for d in s.diagonals {
                p:=outline[d[0]]
                crossed:=nav_crosses_contour(p,corner,int(d[0]),outline)
                for k:=h;k<group_end && !crossed;k+=1 {
                    crossed=nav_crosses_contour(p,corner,-1,nav_contour_verts(s,s.contours[s.holes[k].contour]))
                }
                if !crossed {found=int(d[0]);break}
            }
            if found>=0 {break}
            best=(best+1)%hole_count
        }
        if found<0 {continue}
        a,b:=s.contours[outline_index],s.contours[hole.contour]
        first:=len(s.contour_verts)
        for k in 0..=int(a.count) {
            if _,error:=append(&s.contour_verts,s.contour_verts[int(a.first)+(found+k)%int(a.count)]);error!=nil {return false}
        }
        for k in 0..=int(b.count) {
            if _,error:=append(&s.contour_verts,s.contour_verts[int(b.first)+(best+k)%int(b.count)]);error!=nil {return false}
        }
        s.contours[outline_index].first=i32(first)
        s.contours[outline_index].count=a.count+b.count+2
        s.contours[hole.contour].count=0
    }
    return true
}

// Whether the diagonal from vertex i of the polygon to p leaves i inside the polygon.
@(private="file")
nav_in_cone_point :: proc "contextless" (verts:[][4]i32,i:int,p:[4]i32) -> bool {
    n:=len(verts)
    a,b,c:=verts[i],verts[(i+1)%n],verts[(i+n-1)%n]
    if nav_left_on(c,a,b) {return nav_left(a,p,c) && nav_left(p,a,b)}
    return !(nav_left_on(a,p,b) && nav_left_on(p,a,c))
}

// Whether the segment from a to b crosses an edge of the contour that does not
// touch vertex skip nor share an end with the segment.
@(private="file")
nav_crosses_contour :: proc "contextless" (a,b:[4]i32,skip:int,verts:[][4]i32) -> bool {
    n:=len(verts)
    for k in 0..<n {
        k1:=(k+1)%n
        if skip==k || skip==k1 {continue}
        p,q:=verts[k],verts[k1]
        if nav_same_xz(a,p) || nav_same_xz(b,p) || nav_same_xz(a,q) || nav_same_xz(b,q) {continue}
        if nav_intersect(a,b,p,q) {return true}
    }
    return false
}
