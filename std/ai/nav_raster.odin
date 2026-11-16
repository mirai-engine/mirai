package ai

import math "mirai:std/math"

// Voxelization of the triangles into a heightfield: per column of cells, the
// solid spans in height cells from Nav_Grid.base, sorted bottom up and merged
// where they touch. A span keeps the area of the surface on its top.

@(private) NAV_SPAN_MAX :: 0xffff

@(private)
Nav_Span :: struct {
    min,max:u16, // height cells of the bottom and the top of the solid
    area:u8,
    next:u32,    // the span above in the column, plus one; 0 when none
}

// The integer below x clamped to [low, high]; NaN gives low.
@(private)
nav_floor :: #force_inline proc "contextless" (x:f64,low,high:i64) -> i64 {
    if !(x>f64(low)) {return low}
    if x>=f64(high) {return high}
    i:=i64(x)
    return i-1 if f64(i)>x else i
}
// The integer above x clamped to [low, high]; NaN gives low.
@(private)
nav_ceil :: #force_inline proc "contextless" (x:f64,low,high:i64) -> i64 {
    if !(x>f64(low)) {return low}
    if x>=f64(high) {return high}
    i:=i64(x)
    return i+1 if f64(i)<x else i
}

// The triangle in the space of the grid (x and z from the origin of the
// config), or false when a coordinate is not finite there.
@(private)
nav_triangle :: #force_inline proc "contextless" (g:^Nav_Grid,input:Nav_Build_Input,t:int) -> (a,b,c:math.Vec3,ok:bool) {
    shift:=math.Vec3{g.origin.x,0,g.origin.y}
    a=input.vertices[input.indices[t*3]]-shift
    b=input.vertices[input.indices[t*3+1]]-shift
    c=input.vertices[input.indices[t*3+2]]-shift
    for v in ([3]math.Vec3{a,b,c}) {
        if !nav_finite(v.x) || !nav_finite(v.y) || !nav_finite(v.z) {return}
    }
    return a,b,c,true
}

@(private)
nav_triangle_reaches :: #force_inline proc "contextless" (g:^Nav_Grid,a,b,c:math.Vec3) -> bool {
    return max(a.x,b.x,c.x)>=g.low.x && min(a.x,b.x,c.x)<=g.high.x && max(a.z,b.z,c.z)>=g.low.y && min(a.z,b.z,c.z)<=g.high.y
}

// The area of a triangle no steeper than the walkable slope, either winding;
// NAV_AREA_BLOCKED for the rest.
@(private)
nav_triangle_area :: proc "contextless" (g:^Nav_Grid,input:Nav_Build_Input,t:int,a,b,c:math.Vec3) -> u8 {
    e0:=[3]f64{f64(b.x)-f64(a.x),f64(b.y)-f64(a.y),f64(b.z)-f64(a.z)}
    e1:=[3]f64{f64(c.x)-f64(a.x),f64(c.y)-f64(a.y),f64(c.z)-f64(a.z)}
    n:=[3]f64{e0.y*e1.z-e0.z*e1.y,e0.z*e1.x-e0.x*e1.z,e0.x*e1.y-e0.y*e1.x}
    length2:=n.x*n.x+n.y*n.y+n.z*n.z
    if !(length2>0) || n.y*n.y<g.slope_cos2*length2 {return NAV_AREA_BLOCKED}
    return input.triangle_areas[t] if len(input.triangle_areas)>0 else NAV_AREA_WALKABLE
}

@(private)
nav_rasterize :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,input:Nav_Build_Input) -> Nav_Build_Status {
    // Heights count from the lowest triangle that reaches the heightfield.
    low:=max(f32)
    found:=false
    for t in 0..<len(input.indices)/3 {
        a,b,c,ok:=nav_triangle(g,input,t)
        if !ok || !nav_triangle_reaches(g,a,b,c) {continue}
        low=min(low,a.y,b.y,c.y)
        found=true
    }
    if !found {return .Empty}
    g.base=f64(nav_floor(f64(low)/f64(g.ch),-1<<62,1<<62))
    if !nav_resize(&s.columns,int(g.side)*int(g.side)) {return .Out_Of_Memory}
    clear(&s.spans)
    s.span_free=0
    for t in 0..<len(input.indices)/3 {
        a,b,c,ok:=nav_triangle(g,input,t)
        if !ok || !nav_triangle_reaches(g,a,b,c) {continue}
        if !nav_rasterize_triangle(s,g,a,b,c,nav_triangle_area(g,input,t,a,b,c)) {return .Out_Of_Memory}
    }
    return .Built
}

@(private="file") NAV_CLIP :: 12
@(private="file") Nav_Clip :: struct {p:[NAV_CLIP]math.Vec3,n:int}

// Keeps the part of the convex polygon on one side of the plane where the
// coordinate along axis equals line: above it, or below.
@(private="file")
nav_clip :: proc "contextless" (src,dst:^Nav_Clip,line:f32,axis:int,above:bool) {
    d:[NAV_CLIP]f32
    for i in 0..<src.n {d[i]=src.p[i][axis]-line if above else line-src.p[i][axis]}
    dst.n=0
    j:=src.n-1
    for i in 0..<src.n {
        inside_j,inside_i:=d[j]>=0,d[i]>=0
        if inside_j!=inside_i && dst.n<NAV_CLIP {
            t:=d[j]/(d[j]-d[i])
            dst.p[dst.n]=src.p[j]+(src.p[i]-src.p[j])*t
            dst.n+=1
        }
        if inside_i && dst.n<NAV_CLIP {
            dst.p[dst.n]=src.p[i]
            dst.n+=1
        }
        j=i
    }
}

// Clips the triangle to each cell it touches: every row from the triangle and
// every cell from its row, so a cell gets the same span from any tile whose
// heightfield covers it.
@(private="file")
nav_rasterize_triangle :: proc(s:^Nav_Build_Scratch,g:^Nav_Grid,a,b,c:math.Vec3,area:u8) -> bool {
    last:=i64(g.side)-1
    z0:=nav_floor(f64(min(a.z,b.z,c.z)-g.low.y)*f64(g.ics),0,last+1)-1
    z1:=nav_floor(f64(max(a.z,b.z,c.z)-g.low.y)*f64(g.ics),-1,last)+1
    triangle:=Nav_Clip{n=3}
    triangle.p[0],triangle.p[1],triangle.p[2]=a,b,c
    part,row,cell:Nav_Clip
    for z in max(z0,0)..=min(z1,last) {
        gz:=g.corner.y+i32(z)
        nav_clip(&triangle,&part,f32(gz)*g.cs,2,true)
        if part.n<3 {continue}
        nav_clip(&part,&row,f32(gz+1)*g.cs,2,false)
        if row.n<3 {continue}
        low_x,high_x:=row.p[0].x,row.p[0].x
        for i in 1..<row.n {low_x=min(low_x,row.p[i].x);high_x=max(high_x,row.p[i].x)}
        x0:=nav_floor(f64(low_x-g.low.x)*f64(g.ics),0,last+1)-1
        x1:=nav_floor(f64(high_x-g.low.x)*f64(g.ics),-1,last)+1
        for x in max(x0,0)..=min(x1,last) {
            gx:=g.corner.x+i32(x)
            nav_clip(&row,&part,f32(gx)*g.cs,0,true)
            if part.n<3 {continue}
            nav_clip(&part,&cell,f32(gx+1)*g.cs,0,false)
            if cell.n<3 {continue}
            low_y,high_y:=cell.p[0].y,cell.p[0].y
            for i in 1..<cell.n {low_y=min(low_y,cell.p[i].y);high_y=max(high_y,cell.p[i].y)}
            bottom:=nav_floor(f64(low_y)/f64(g.ch)-g.base,-1,NAV_SPAN_MAX+1)
            top:=nav_ceil(f64(high_y)/f64(g.ch)-g.base,-1,NAV_SPAN_MAX+1)
            if top<0 || bottom>NAV_SPAN_MAX {continue}
            bottom=clamp(bottom,0,NAV_SPAN_MAX-1)
            top=clamp(top,bottom+1,NAV_SPAN_MAX)
            if !nav_add_span(s,int(x)+int(z)*int(g.side),u16(bottom),u16(top),area,g.climb) {return false}
        }
    }
    return true
}

// Inserts the span into its column, merged with those it touches. Where the
// tops of merged spans are within a step the walkable area wins; otherwise
// the area of the higher top.
@(private="file")
nav_add_span :: proc(s:^Nav_Build_Scratch,column:int,bottom,top:u16,area:u8,merge:i32) -> bool {
    index:u32
    if s.span_free!=0 {
        index=s.span_free
        s.span_free=s.spans[index-1].next
    } else {
        if len(s.spans)>=int(max(u32)-1) {return false}
        if _,error:=append(&s.spans,Nav_Span{});error!=nil {return false}
        index=u32(len(s.spans))
    }
    span:=Nav_Span{min=bottom,max=top,area=area}
    previous:u32
    current:=s.columns[column]
    for current!=0 {
        other:=s.spans[current-1]
        if other.min>span.max {break}
        if other.max<span.min {
            previous=current
            current=other.next
            continue
        }
        if abs(i32(span.max)-i32(other.max))<=merge {
            span.area=max(span.area,other.area)
        } else if other.max>span.max {
            span.area=other.area
        }
        span.min=min(span.min,other.min)
        span.max=max(span.max,other.max)
        next:=other.next
        s.spans[current-1].next=s.span_free
        s.span_free=current
        if previous!=0 {s.spans[previous-1].next=next} else {s.columns[column]=next}
        current=next
    }
    span.next=s.spans[previous-1].next if previous!=0 else s.columns[column]
    s.spans[index-1]=span
    if previous!=0 {s.spans[previous-1].next=index} else {s.columns[column]=index}
    return true
}
