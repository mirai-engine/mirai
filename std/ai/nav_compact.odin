package ai

// The filters over the heightfield, the compact heightfield of the walkable
// spans with their links to the neighbor columns, the area volumes and the
// erosion by the agent radius.

@(private) NAV_NOT_CONNECTED :: 0x3f

// The four directions between columns: 0 is -x, 1 is +z, 2 is +x and 3 is -z.
@(private) nav_dx :: #force_inline proc "contextless" (dir:int) -> int {return dir-1 if dir&1==0 else 0}
@(private) nav_dz :: #force_inline proc "contextless" (dir:int) -> int {return 2-dir if dir&1==1 else 0}

// A walkable span: the top of a solid and the open space above it.
@(private)
Nav_Compact_Span :: struct {
    con:u32, // per direction, 6 bits: the span of the neighbor column it links to, NAV_NOT_CONNECTED when none
    y,h:u16, // height cells of the floor and of the space above it
}

@(private)
nav_con :: #force_inline proc "contextless" (span:Nav_Compact_Span,dir:int) -> int {return int(span.con>>uint(dir*6))&NAV_NOT_CONNECTED}

// The span that a span of column (x, z) links to in direction dir.
@(private)
nav_neighbor :: #force_inline proc "contextless" (s:^Nav_Build_Scratch,side,x,z,dir,con:int) -> int {
    return int(s.cells[x+nav_dx(dir)+(z+nav_dz(dir))*side])+con
}

@(private)
nav_span_top :: #force_inline proc "contextless" (s:^Nav_Build_Scratch,span:Nav_Span) -> int {
    return int(s.spans[span.next-1].min) if span.next!=0 else NAV_SPAN_MAX
}

// Recast's three filters, in its order: a step on a walkable surface takes
// its area, a span at a drop deeper than a step (or between neighbors further
// apart than a step) is a ledge, and a span without room for the agent above
// is not walkable.
@(private)
nav_filter_spans :: proc "contextless" (s:^Nav_Build_Scratch,g:^Nav_Grid) {
    side:=int(g.side)
    climb,height:=int(g.climb),int(g.height)
    for c in 0..<side*side {
        below_walkable:=false
        below_area:u8
        below_top:int
        for i:=s.columns[c];i!=0;i=s.spans[i-1].next {
            span:=&s.spans[i-1]
            walkable:=span.area!=NAV_AREA_BLOCKED
            if !walkable && below_walkable && abs(int(span.max)-below_top)<=climb {span.area=below_area}
            below_walkable=walkable
            below_area=span.area
            below_top=int(span.max)
        }
    }
    for z in 0..<side {
        for x in 0..<side {
            for i:=s.columns[x+z*side];i!=0;i=s.spans[i-1].next {
                span:=&s.spans[i-1]
                if span.area==NAV_AREA_BLOCKED {continue}
                bottom,top:=int(span.max),nav_span_top(s,span^)
                lowest:=NAV_SPAN_MAX
                reach_low,reach_high:=bottom,bottom
                for dir in 0..<4 {
                    nx,nz:=x+nav_dx(dir),z+nav_dz(dir)
                    if nx<0 || nz<0 || nx>=side || nz>=side {
                        lowest=min(lowest,-climb-bottom)
                        continue
                    }
                    n:=s.columns[nx+nz*side]
                    // The open space below the first span of the neighbor is a drop.
                    neighbor_top:=int(s.spans[n-1].min) if n!=0 else NAV_SPAN_MAX
                    if min(top,neighbor_top)-max(bottom,-climb)>height {lowest=min(lowest,-climb-bottom)}
                    for ;n!=0;n=s.spans[n-1].next {
                        other:=s.spans[n-1]
                        neighbor_bottom:=int(other.max)
                        neighbor_top=nav_span_top(s,other)
                        if min(top,neighbor_top)-max(bottom,neighbor_bottom)<=height {continue}
                        lowest=min(lowest,neighbor_bottom-bottom)
                        if abs(neighbor_bottom-bottom)<=climb {
                            reach_low=min(reach_low,neighbor_bottom)
                            reach_high=max(reach_high,neighbor_bottom)
                        }
                    }
                }
                if lowest< -climb || reach_high-reach_low>climb {span.area=NAV_AREA_BLOCKED}
            }
        }
    }
    for c in 0..<side*side {
        for i:=s.columns[c];i!=0;i=s.spans[i-1].next {
            span:=&s.spans[i-1]
            if nav_span_top(s,span^)-int(span.max)<height {span.area=NAV_AREA_BLOCKED}
        }
    }
}

@(private)
nav_build_compact :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> Nav_Build_Status {
    side:=int(g.side)
    columns:=side*side
    count:=0
    for c in 0..<columns {
        for i:=s.columns[c];i!=0;i=s.spans[i-1].next {if s.spans[i-1].area!=NAV_AREA_BLOCKED {count+=1}}
    }
    if count==0 {return .Empty}
    if !nav_resize(&s.cells,columns+1) || !nav_resize(&s.compact,count) || !nav_resize(&s.area,count) {return .Out_Of_Memory}
    index:=0
    for c in 0..<columns {
        s.cells[c]=u32(index)
        for i:=s.columns[c];i!=0;i=s.spans[i-1].next {
            span:=s.spans[i-1]
            if span.area==NAV_AREA_BLOCKED {continue}
            s.compact[index]={y=span.max,h=u16(clamp(nav_span_top(s,span)-int(span.max),0,NAV_SPAN_MAX))}
            s.area[index]=span.area
            index+=1
        }
    }
    s.cells[columns]=u32(index)
    nav_link_compact(s,g)
    return .Built
}

// Links each walkable span to the span of each neighbor column an agent steps onto from it.
@(private)
nav_link_compact :: proc "contextless" (s:^Nav_Build_Scratch,g:^Nav_Grid) {
    side:=int(g.side)
    climb,height:=int(g.climb),int(g.height)
    for z in 0..<side {
        for x in 0..<side {
            c:=x+z*side
            for i in int(s.cells[c])..<int(s.cells[c+1]) {
                span:=s.compact[i]
                con:u32=0xffffff
                for dir in 0..<4 {
                    nx,nz:=x+nav_dx(dir),z+nav_dz(dir)
                    if nx<0 || nz<0 || nx>=side || nz>=side {continue}
                    first:=int(s.cells[nx+nz*side])
                    for k in first..<int(s.cells[nx+nz*side+1]) {
                        other:=s.compact[k]
                        bottom:=max(int(span.y),int(other.y))
                        top:=min(int(span.y)+int(span.h),int(other.y)+int(other.h))
                        if top-bottom<height || abs(int(other.y)-int(span.y))>climb {continue}
                        if k-first<NAV_NOT_CONNECTED {
                            shift:=uint(dir*6)
                            con=con&~(u32(NAV_NOT_CONNECTED)<<shift)|u32(k-first)<<shift
                        }
                        break
                    }
                }
                s.compact[i].con=con
            }
        }
    }
}

// The two passes of a chamfer distance (2 across, 3 diagonally) over the
// links of the compact heightfield, from the zeros already in dist.
@(private)
nav_chamfer :: proc "contextless" (s:^Nav_Build_Scratch,g:^Nav_Grid,dist:[]u16) {
    side:=int(g.side)
    relax :: #force_inline proc "contextless" (dist:[]u16,i,from,cost:int) {
        if d:=int(dist[from])+cost;d<int(dist[i]) {dist[i]=u16(d)}
    }
    // Each step goes along a link and then turns to the next direction for the diagonal.
    step :: #force_inline proc "contextless" (s:^Nav_Build_Scratch,dist:[]u16,side,x,z,i,dir,turn:int) {
        con:=nav_con(s.compact[i],dir)
        if con==NAV_NOT_CONNECTED {return}
        ax,az:=x+nav_dx(dir),z+nav_dz(dir)
        a:=int(s.cells[ax+az*side])+con
        relax(dist,i,a,2)
        con2:=nav_con(s.compact[a],turn)
        if con2==NAV_NOT_CONNECTED {return}
        relax(dist,i,nav_neighbor(s,side,ax,az,turn,con2),3)
    }
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                step(s,dist,side,x,z,i,0,3)
                step(s,dist,side,x,z,i,3,2)
            }
        }
    }
    for z:=side-1;z>=0;z-=1 {
        for x:=side-1;x>=0;x-=1 {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                step(s,dist,side,x,z,i,2,1)
                step(s,dist,side,x,z,i,1,0)
            }
        }
    }
}

// Removes the walkable spans closer than the agent radius to a wall, a ledge
// or a blocked span.
@(private)
nav_erode :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid) -> Nav_Build_Status {
    if g.radius<=0 {return .Built}
    if !nav_resize(&s.dist,len(s.compact)) {return .Out_Of_Memory}
    side:=int(g.side)
    for z in 0..<side {
        for x in 0..<side {
            for i in int(s.cells[x+z*side])..<int(s.cells[x+z*side+1]) {
                s.dist[i]=0
                if s.area[i]==NAV_AREA_BLOCKED {continue}
                walkable:=0
                for dir in 0..<4 {
                    con:=nav_con(s.compact[i],dir)
                    if con!=NAV_NOT_CONNECTED && s.area[nav_neighbor(s,side,x,z,dir,con)]!=NAV_AREA_BLOCKED {walkable+=1}
                }
                if walkable==4 {s.dist[i]=0xffff}
            }
        }
    }
    nav_chamfer(s,g,s.dist[:])
    threshold:=int(g.radius)*2
    for d,i in s.dist {if int(d)<threshold {s.area[i]=NAV_AREA_BLOCKED}}
    return .Built
}

// Marks the area of each volume on the spans whose column center lies inside
// it and whose floor lies between its heights, in order: later volumes win.
@(private)
nav_mark_volumes :: proc "contextless" (s:^Nav_Build_Scratch,g:^Nav_Grid,volumes:[]Nav_Area_Volume) {
    side:=i64(g.side)
    for volume in volumes {
        count:=int(volume.count)
        if count<3 || !nav_finite(volume.min_y) || !nav_finite(volume.max_y) {continue}
        points:[8][2]f32
        low,high:=[2]f32{max(f32),max(f32)},[2]f32{-max(f32),-max(f32)}
        finite:=true
        for k in 0..<count {
            p:=volume.points[k]-g.origin
            if !nav_finite(p.x) || !nav_finite(p.y) {finite=false;break}
            points[k]=p
            low={min(low.x,p.x),min(low.y,p.y)}
            high={max(high.x,p.x),max(high.y,p.y)}
        }
        if !finite {continue}
        x0:=nav_floor(f64(low.x)/f64(g.cs)-f64(g.corner.x),-1,side)
        x1:=nav_floor(f64(high.x)/f64(g.cs)-f64(g.corner.x),-1,side)
        z0:=nav_floor(f64(low.y)/f64(g.cs)-f64(g.corner.y),-1,side)
        z1:=nav_floor(f64(high.y)/f64(g.cs)-f64(g.corner.y),-1,side)
        if x1<0 || z1<0 || x0>=side || z0>=side {continue}
        bottom:=nav_floor(f64(volume.min_y)/f64(g.ch)-g.base,-1,NAV_SPAN_MAX+1)
        top:=nav_floor(f64(volume.max_y)/f64(g.ch)-g.base,-1,NAV_SPAN_MAX+1)
        for z in max(z0,0)..=min(z1,side-1) {
            for x in max(x0,0)..=min(x1,side-1) {
                c:=int(x+z*side)
                if s.cells[c]==s.cells[c+1] {continue}
                center:=[2]f32{(f32(g.corner.x+i32(x))+0.5)*g.cs,(f32(g.corner.y+i32(z))+0.5)*g.cs}
                if !nav_point_in_polygon(points[:count],center) {continue}
                for i in int(s.cells[c])..<int(s.cells[c+1]) {
                    y:=i64(s.compact[i].y)
                    if s.area[i]!=NAV_AREA_BLOCKED && y>=bottom && y<=top {s.area[i]=volume.area}
                }
            }
        }
    }
}

@(private)
nav_point_in_polygon :: proc "contextless" (points:[][2]f32,p:[2]f32) -> bool {
    inside:=false
    j:=len(points)-1
    for i in 0..<len(points) {
        a,b:=points[i],points[j]
        if (a.y>p.y)!=(b.y>p.y) && p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x {inside=!inside}
        j=i
    }
    return inside
}
