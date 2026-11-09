package mirai_anim

import "core:mem"
import math "mirai:std/math"

BLEND_MAX_SAMPLES :: 256

Blend_Dimension :: enum u8 {One,Two}
Blend_Error :: enum u8 {None,Invalid,Out_Of_Memory}
Blend_Segment :: struct {samples:[2]u16}
Blend_Triangle :: struct {samples:[3]u16}
Blend_Space :: struct {
    dimension:Blend_Dimension,
    points:[]math.Vec2,
    segments:[]Blend_Segment,
    triangles:[]Blend_Triangle,
    allocator:mem.Allocator,
}
Blend_Weights :: struct {count:u8,samples:[3]u16,weights:[3]f32}

blend_space_destroy :: proc(space:^Blend_Space) {
    if space==nil {return}
    allocator:=space.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    delete(space.points,allocator);delete(space.segments,allocator);delete(space.triangles,allocator)
    space^={}
}

blend_space_prepare :: proc(points:[]math.Vec2,dimension:Blend_Dimension,allocator:=context.allocator,failure:^Blend_Error=nil) -> (Blend_Space,bool) {
    if failure!=nil {failure^=.Invalid}
    if dimension>max(Blend_Dimension) || len(points)==0 || len(points)>BLEND_MAX_SAMPLES {return {},false}
    for point,i in points {
        if !blend_point_valid(point) {return {},false}
        for previous in points[:i] {if point==previous || dimension==.One && point.x==previous.x {return {},false}}
    }
    space:=Blend_Space{dimension=dimension,allocator=allocator}
    error:mem.Allocator_Error
    space.points,error=make([]math.Vec2,len(points),allocator)
    if error!=nil {if failure!=nil {failure^=.Out_Of_Memory};return {},false};copy(space.points,points)
    success:=false
    defer {if !success {blend_space_destroy(&space)}}
    if dimension==.One {
        order:[BLEND_MAX_SAMPLES]u16
        for point,i in points {
            j:=i
            for j>0 && points[order[j-1]].x>point.x {order[j]=order[j-1];j-=1}
            order[j]=u16(i)
        }
        space.segments,error=make([]Blend_Segment,len(points)-1,allocator)
        if error!=nil {if failure!=nil {failure^=.Out_Of_Memory};return {},false}
        for &segment,i in space.segments {segment.samples={order[i],order[i+1]}}
    } else {
        if len(points)<3 {return {},false}
        triangles,prepared:=blend_triangulate(points,allocator,failure)
        if !prepared {return {},false}
        space.triangles=triangles
    }
    success=true
    if failure!=nil {failure^=.None}
    return space,true
}

blend_space_validate :: proc "contextless" (space:Blend_Space) -> bool {
    if space.dimension>max(Blend_Dimension) || len(space.points)==0 || len(space.points)>BLEND_MAX_SAMPLES {return false}
    for point,i in space.points {
        if !blend_point_valid(point) {return false}
        for previous in space.points[:i] {if point==previous || space.dimension==.One && point.x==previous.x {return false}}
    }
    used:[BLEND_MAX_SAMPLES]bool
    if space.dimension==.One {
        if len(space.triangles)!=0 || len(space.segments)!=len(space.points)-1 {return false}
        if len(space.points)==1 {return true}
        previous:u16
        for segment,i in space.segments {
            a,b:=segment.samples[0],segment.samples[1]
            if int(a)>=len(space.points) || int(b)>=len(space.points) || space.points[a].x>=space.points[b].x || i>0 && previous!=a {return false}
            if i>0 && used[b] {return false}
            used[a],used[b],previous=true,true,b
        }
    } else {
        if len(space.segments)!=0 || len(space.points)<3 || len(space.triangles)==0 || len(space.triangles)>2*len(space.points)-5 {return false}
        area:f64
        for triangle,i in space.triangles {
            a,b,c:=triangle.samples[0],triangle.samples[1],triangle.samples[2]
            if int(a)>=len(space.points) || int(b)>=len(space.points) || int(c)>=len(space.points) {return false}
            determinant:=blend_orientation(space.points[a],space.points[b],space.points[c])
            if determinant<=0 {return false};area+=determinant
            used[a],used[b],used[c]=true,true,true
            for earlier in space.triangles[:i] {
                for edge in 0..<3 {
                    p,q:=triangle.samples[edge],triangle.samples[(edge+1)%3]
                    for other in 0..<3 {
                        r,s:=earlier.samples[other],earlier.samples[(other+1)%3]
                        if p==r && q==s {return false}
                        if p==r || p==s || q==r || q==s {continue}
                        ap,aq,ar,as:=space.points[p],space.points[q],space.points[r],space.points[s]
                        if blend_orientation(ap,aq,ar)*blend_orientation(ap,aq,as)<0 && blend_orientation(ar,as,ap)*blend_orientation(ar,as,aq)<0 {return false}
                    }
                }
                e:=earlier.samples
                contained:=true
                for edge in 0..<3 {
                    p,q:=space.points[e[edge]],space.points[e[(edge+1)%3]]
                    if blend_orientation(p,q,space.points[a])+blend_orientation(p,q,space.points[b])+blend_orientation(p,q,space.points[c])<=0 {contained=false;break}
                }
                if contained {return false}
            }
        }
        hull:[BLEND_MAX_SAMPLES*2]u16
        count:=blend_hull(space.points,hull[:])
        hull_area:f64
        for i in 1..<count-1 {hull_area+=blend_orientation(space.points[hull[0]],space.points[hull[i]],space.points[hull[i+1]])}
        if abs(area-hull_area)>hull_area*1e-6 {return false}
    }
    for value in used[:len(space.points)] {if !value {return false}}
    return true
}

blend_space_sample :: proc "contextless" (space:Blend_Space,position:math.Vec2) -> (out:Blend_Weights,ok:bool) {
    if !blend_point_valid(position) || space.dimension>max(Blend_Dimension) || len(space.points)==0 || len(space.points)>BLEND_MAX_SAMPLES {return {},false}
    if space.dimension==.One {
        if len(space.triangles)!=0 || len(space.segments)!=len(space.points)-1 {return {},false}
        if len(space.points)==1 {if !blend_point_valid(space.points[0]) {return {},false};return {count=1,weights={1,0,0}},true}
        nearest:=max(f64)
        for segment in space.segments {
            a,b:=segment.samples[0],segment.samples[1]
            if int(a)>=len(space.points) || int(b)>=len(space.points) || !blend_point_valid(space.points[a]) || !blend_point_valid(space.points[b]) {return {},false}
            from,to:=f64(space.points[a].x),f64(space.points[b].x)
            if from>=to {return {},false}
            alpha:=blend_clamp((f64(position.x)-from)/(to-from),0,1)
            distance:=abs(f64(position.x)-(from+(to-from)*alpha))
            if distance<nearest {nearest=distance;out={count=2,samples={a,b,0},weights={f32(1-alpha),f32(alpha),0}}}
        }
        return out,out.count!=0
    }
    if len(space.segments)!=0 || len(space.triangles)==0 || len(space.triangles)>2*len(space.points)-5 {return {},false}
    nearest:=max(f64)
    inside:=false
    for triangle in space.triangles {
        a,b,c:=triangle.samples[0],triangle.samples[1],triangle.samples[2]
        if int(a)>=len(space.points) || int(b)>=len(space.points) || int(c)>=len(space.points) {return {},false}
        p,q,r:=space.points[a],space.points[b],space.points[c]
        if !blend_point_valid(p) || !blend_point_valid(q) || !blend_point_valid(r) {return {},false}
        area:=blend_orientation(p,q,r)
        if area<=0 {return {},false}
        wa,wb,wc:=blend_orientation(q,r,position)/area,blend_orientation(r,p,position)/area,blend_orientation(p,q,position)/area
        if wa>= -1e-7 && wb>= -1e-7 && wc>= -1e-7 {
            wa,wb,wc=blend_clamp(wa,0,1),blend_clamp(wb,0,1),blend_clamp(wc,0,1)
            sum:=wa+wb+wc
            out={count=3,samples={a,b,c},weights={f32(wa/sum),f32(wb/sum),f32(wc/sum)}};inside=true
        } else if !inside {
            for edge in 0..<3 {
                ia,ib:=triangle.samples[edge],triangle.samples[(edge+1)%3]
                ep,eq:=space.points[ia],space.points[ib]
                dx,dy:=f64(eq.x)-f64(ep.x),f64(eq.y)-f64(ep.y)
                alpha:=blend_clamp(((f64(position.x)-f64(ep.x))*dx+(f64(position.y)-f64(ep.y))*dy)/(dx*dx+dy*dy),0,1)
                ex,ey:=f64(position.x)-(f64(ep.x)+alpha*dx),f64(position.y)-(f64(ep.y)+alpha*dy)
                distance:=ex*ex+ey*ey
                if distance<nearest {nearest=distance;out={count=2,samples={ia,ib,0},weights={f32(1-alpha),f32(alpha),0}}}
            }
        }
    }
    return out,out.count!=0
}

@(private) blend_point_valid :: proc "contextless" (point:math.Vec2) -> bool {return anim_finite(point.x) && anim_finite(point.y)}
@(private) blend_clamp :: proc "contextless" (value,low,high:f64) -> f64 {return low if value<low else high if value>high else value}
@(private) blend_orientation :: proc "contextless" (a,b,c:math.Vec2) -> f64 {return (f64(b.x)-f64(a.x))*(f64(c.y)-f64(a.y))-(f64(b.y)-f64(a.y))*(f64(c.x)-f64(a.x))}

@(private)
blend_hull :: proc "contextless" (points:[]math.Vec2,out:[]u16) -> int {
    order:[BLEND_MAX_SAMPLES]u16
    for point,i in points {
        j:=i
        for j>0 && (points[order[j-1]].x>point.x || points[order[j-1]].x==point.x && points[order[j-1]].y>point.y) {order[j]=order[j-1];j-=1}
        order[j]=u16(i)
    }
    count:=0
    for index in order[:len(points)] {for count>=2 && blend_orientation(points[out[count-2]],points[out[count-1]],points[index])<=0 {count-=1};out[count]=index;count+=1}
    lower:=count
    #reverse for index in order[:len(points)-1] {for count>lower && blend_orientation(points[out[count-2]],points[out[count-1]],points[index])<=0 {count-=1};out[count]=index;count+=1}
    return count-1
}

@(private)
blend_triangulate :: proc(points:[]math.Vec2,allocator:mem.Allocator,failure:^Blend_Error) -> ([]Blend_Triangle,bool) {
    hull:[BLEND_MAX_SAMPLES*2]u16
    count:=blend_hull(points,hull[:])
    if count<3 {return nil,false}
    triangles,no_triangles:=make([dynamic]Blend_Triangle,0,2*len(points),allocator)
    defer delete(triangles)
    if no_triangles!=nil {if failure!=nil {failure^=.Out_Of_Memory};return nil,false}
    used:[BLEND_MAX_SAMPLES]bool
    for index in hull[:count] {used[index]=true}
    for i in 1..<count-1 {append(&triangles,Blend_Triangle{{hull[0],hull[i],hull[i+1]}})}
    for point,index in points {
        if used[index] {continue}
        inserted:=false
        original:=len(triangles)
        // An edge sample splits both neighboring triangles before edge flips.
        #reverse for triangle,i in triangles {
            if i>=original {continue}
            a,b,c:=points[triangle.samples[0]],points[triangle.samples[1]],points[triangle.samples[2]]
            weights:=[3]f64{blend_orientation(a,b,point),blend_orientation(b,c,point),blend_orientation(c,a,point)}
            if weights[0]<0 || weights[1]<0 || weights[2]<0 {continue}
            unordered_remove(&triangles,i)
            for weight,edge in weights {if weight>0 {if append(&triangles,Blend_Triangle{{triangle.samples[edge],triangle.samples[(edge+1)%3],u16(index)}})!=1 {if failure!=nil {failure^=.Out_Of_Memory};return nil,false}}}
            inserted=true
            if weights[0]>0 && weights[1]>0 && weights[2]>0 {break}
        }
        if !inserted {return nil,false}
    }
    flips:=0
    for {
        changed:=false
        for triangle,i in triangles {
            flipped:=false
            for other,j in triangles[:i] {
                for edge in 0..<3 {
                    a,b,c:=triangle.samples[edge],triangle.samples[(edge+1)%3],triangle.samples[(edge+2)%3]
                    for second in 0..<3 {
                        if other.samples[second]!=b || other.samples[(second+1)%3]!=a {continue}
                        d:=other.samples[(second+2)%3]
                        if blend_orientation(points[c],points[d],points[b])<=0 || blend_orientation(points[d],points[c],points[a])<=0 {continue}
                        if !blend_inside_circle(points[a],points[b],points[c],points[d]) {continue}
                        triangles[i],triangles[j]={samples={c,d,b}},{samples={d,c,a}}
                        changed,flipped=true,true;flips+=1
                        break
                    }
                    if flipped {break}
                }
                if flipped {break}
            }
        }
        if !changed {break}
        if flips>16*len(points)*len(points) {return nil,false}
    }
    result,error:=make([]Blend_Triangle,len(triangles),allocator)
    if error!=nil {if failure!=nil {failure^=.Out_Of_Memory};return nil,false};copy(result,triangles[:])
    if !blend_space_validate({dimension=.Two,points=points,triangles=result}) {delete(result,allocator);return nil,false}
    return result,true
}

@(private)
blend_inside_circle :: proc "contextless" (a,b,c,d:math.Vec2) -> bool {
    ax,ay,bx,by,cx,cy:=f64(a.x)-f64(d.x),f64(a.y)-f64(d.y),f64(b.x)-f64(d.x),f64(b.y)-f64(d.y),f64(c.x)-f64(d.x),f64(c.y)-f64(d.y)
    scale:=max(abs(ax),abs(ay),abs(bx),abs(by),abs(cx),abs(cy))
    if scale<=0 {return false}
    ax/=scale;ay/=scale;bx/=scale;by/=scale;cx/=scale;cy/=scale
    determinant:=(ax*ax+ay*ay)*(bx*cy-by*cx)-(bx*bx+by*by)*(ax*cy-ay*cx)+(cx*cx+cy*cy)*(ax*by-ay*bx)
    return determinant>1e-14
}
