package ai

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

// Queries of places: candidates generated around a point, each scored by
// considerations over inputs the caller measures for it (a distance, an
// angle, whether it is seen, the length of the way there)
// (score_considerations); the best few are kept. Who measures is the caller's: these
// procedures only lay out candidates and keep the best.

// Points on rings around a center, on the XZ plane at its height: `rings`
// rings from `inner` to `outer` metres, `per_ring` points each, the outer
// ones turned half a step so the rings interleave. How many were written.
places_rings :: proc "contextless" (center:math.Vec3,inner,outer:f32,rings,per_ring:int,out:[]math.Vec3) -> int {
    if rings<=0 || per_ring<=0 || !(inner>=0) || !(outer>=inner) || !(outer<=1e6) {return 0}
    count:=0
    for r in 0..<rings {
        radius:=inner if rings==1 else inner+(outer-inner)*f32(r)/f32(rings-1)
        for k in 0..<per_ring {
            if count>=len(out) {return count}
            turn:=(f32(k)+(0.5 if r%2==1 else 0))/f32(per_ring)*2*math.PI
            s,c:=math.sincos_det(turn)
            out[count]=center+{c*radius,0,s*radius}
            count+=1
        }
    }
    return count
}

// Points of a square grid around a center, `spacing` apart, within `half`
// metres along x and z, at its height. How many were written.
places_grid :: proc "contextless" (center:math.Vec3,half,spacing:f32,out:[]math.Vec3) -> int {
    if !(spacing>0) || !(half>=0) || half/spacing>512 {return 0}
    steps:=int(half/spacing)
    count:=0
    for z in -steps..=steps {
        for x in -steps..=steps {
            if count>=len(out) {return count}
            out[count]=center+{f32(x)*spacing,0,f32(z)*spacing}
            count+=1
        }
    }
    return count
}

// Points of the mesh joined to start_ref without leaving `outer` metres of
// the center, beyond `inner`: a grid `spacing` apart over each polygon it
// reaches, or its middle when none falls in it, in the order the polygons
// are reached. How many were written.
places_mesh :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref:Nav_Ref,center:math.Vec3,inner,outer,spacing:f32,filter:^Nav_Filter,out:[]math.Vec3) -> (count:int) {
    if !(spacing>0) || !(inner>=0) || !(outer>=inner) || !(outer<=1e6) {return 0}
    q.around={center=center,radius=outer,random=true}
    if !nav_around(q,mesh,start_ref,center,outer,filter) {return 0}
    within :: proc "contextless" (center,p:math.Vec3,inner,outer:f32) -> bool {
        d:=(p.x-center.x)*(p.x-center.x)+(p.z-center.z)*(p.z-center.z)
        return d>=inner*inner && d<=outer*outer
    }
    for slot in 0..<u32(len(q.points)) {
        if count>=len(out) {return}
        if !search_reached(&q.search,slot) {continue}
        ref:=Nav_Ref(search_key(&q.search,slot))
        tile,poly:=nav_poly_of(mesh,ref)
        if poly==nil {continue}
        corners:[NAV_VERTS_PER_POLY]math.Vec3
        n:=nav_poly_vertices(tile,poly,&corners)
        low,high:=corners[0],corners[0]
        for c in corners[1:n] {low,high=linalg.min(low,c),linalg.max(high,c)}
        before:=count
        for z:=cmath.ceil(low.z/spacing)*spacing;z<=high.z && count<len(out);z+=spacing {
            for x:=cmath.ceil(low.x/spacing)*spacing;x<=high.x && count<len(out);x+=spacing {
                p:=math.Vec3{x,center.y,z}
                if !nav_point_in_poly_xz(p,corners[:n]) || !within(center,p,inner,outer) {continue}
                if h,on:=nav_poly_height(mesh,ref,p);on {p.y=h} else {continue}
                out[count]=p
                count+=1
            }
        }
        if count==before {
            middle:=nav_poly_center(tile,poly)
            if h,on:=nav_poly_height(mesh,ref,middle);on {middle.y=h}
            if within(center,middle,inner,outer) {
                out[count]=middle
                count+=1
            }
        }
    }
    return
}

Place_Score :: struct {
    index:i32, // of the candidate
    score:f32,
}

// Scores the candidates whose inputs are laid one after another in `inputs`
// (`stride` each), with the considerations (score_considerations), and
// keeps in `best` the highest, best first (the first wins ties). A candidate
// that scores 0 is never kept. How many were kept.
places_best :: proc "contextless" (considerations:[]Consideration,inputs:[]f32,stride:int,best:[]Place_Score) -> int {
    if stride<=0 || len(best)==0 {return 0}
    kept:=0
    for i in 0..<len(inputs)/stride {
        score:=score_considerations(considerations,1,inputs[i*stride:][:stride])
        if !(score>0) {continue}
        if kept==len(best) && score<=best[kept-1].score {continue}
        at:=min(kept,len(best)-1)
        for at>0 && best[at-1].score<score {
            if at<len(best) {best[at]=best[at-1]}
            at-=1
        }
        best[at]={i32(i),score}
        kept=min(kept+1,len(best))
    }
    return kept
}
