package ai

import "core:math/linalg"
import math "mirai:std/math"

// Links a mesh does not know until someone looks: where an agent of a class
// can jump from a ledge to another surface, or drop to a lower one. The walls
// of a tile are sampled; from each sample the surface is searched outward,
// within how high and how far the class jumps and how far it drops; samples
// of the same edge whose landings follow one another become one link, from
// the middle one. Whoever builds the mesh checks that the arc is free.

NAV_JUMP_CLEARANCE :: f32(0.4) // m the arc of a jump rises above its higher end
NAV_JUMP_SAMPLES :: 512        // along one wall at most

// What a class can jump and drop, and how finely to look.
Nav_Jump :: struct {
    up,across,down:f32, // m: as Nav_Need
    radius:f32,         // m of the agent
    climb:f32,          // m it steps without jumping
    step:f32,           // m between samples along a wall, and between probes outward
}

Nav_Jump_Kind :: enum u8 {Jump,Drop}

Nav_Jump_Link :: struct {
    start,end:math.Vec3,
    kind:Nav_Jump_Kind,
    need:Nav_Need,
}

// Whether the arc of a link is free for the agent. user is the caller's.
Nav_Arc_Clear :: proc(user:rawptr,link:Nav_Jump_Link) -> bool

// The point of the arc of a link at u of its time (0 at its start, 1 at its
// end): a ballistic arc whose top is NAV_JUMP_CLEARANCE above the higher end
// for a jump, and the start for a drop. The same for any gravity.
nav_jump_point :: proc "contextless" (link:Nav_Jump_Link,u:f32) -> math.Vec3 {
    s,e:=link.start,link.end
    top:=max(s.y,e.y)+NAV_JUMP_CLEARANCE if link.kind==.Jump else max(s.y,e.y)
    // Times to rise and to fall, with g = 1.
    rise:=linalg.sqrt(max(2*(top-s.y),0))
    fall:=linalg.sqrt(max(2*(top-e.y),0))
    total:=rise+fall
    p:=s+(e-s)*u
    if !(total>1e-6) {return p}
    t:=u*total
    p.y=s.y+rise*t-0.5*t*t
    return p
}

// The links an agent that jumps and drops as `jump` says can take from the
// walls of the tile at `coord`, written to `out`; complete when all fit. A
// sample becomes a link only if the place it reaches is not just across a
// step, and `clear`, when given, accepts its arc.
nav_jump_links :: proc(mesh:^Nav_Mesh,coord:[2]i32,jump:Nav_Jump,out:[]Nav_Jump_Link,clear:Nav_Arc_Clear=nil,user:rawptr=nil) -> (count:int,complete:bool) {
    complete=true
    tile:=nav_mesh_tile_at(mesh,coord)
    if tile==nil || !(jump.step>0) || !(jump.radius>=0) || !(jump.climb>=0) {return}
    for x in ([3]f32{jump.up,jump.across,jump.down}) {if !(x>=0) || !(x<=1e6) {return}}
    if jump.up<=0 && jump.down<=jump.climb && jump.across<=0 {return}
    reach:=max(jump.across,jump.radius*4+jump.step)
    if reach/(jump.step*0.5)>4096 {return}
    for &poly,p in tile.data.polys {
        n:=int(poly.count)
        corners:[NAV_VERTS_PER_POLY]math.Vec3
        nav_poly_vertices(tile,&poly,&corners)
        center:=nav_poly_center(tile,&poly)
        from_ref:=nav_tile_ref(mesh,tile,p)
        for e in 0..<n {
            if poly.neighbor[e]!=NAV_EDGE_WALL {continue}
            a,b:=corners[e],corners[(e+1)%n]
            along:=math.Vec3{b.x-a.x,0,b.z-a.z}
            length:=linalg.length(along)
            if !(length>1e-4) {continue}
            out_dir:=math.Vec3{along.z,0,-along.x}/length
            if linalg.dot(out_dir,(a+b)*0.5-center)<0 {out_dir=-out_dir}
            samples:=max(1,int(min(length/jump.step,NAV_JUMP_SAMPLES)))
            // Once for the nearest surface out, and once for a jump past the floor of a gap to another surface.
            for past in ([2]bool{false,true}) {
                // A run of samples whose landings follow one another.
                run_first,run_last:=-1,-1
                run,last:Nav_Jump_Link
                for i in 0..=samples {
                    found:=false
                    link:Nav_Jump_Link
                    if i<samples {
                        start:=a+(b-a)*((f32(i)+0.5)/f32(samples))
                        link,_,found=nav_jump_probe(mesh,from_ref,start,out_dir,jump,reach,past)
                    }
                    if found && run_first>=0 && link.kind==last.kind && linalg.distance(link.end,last.end)<=jump.step*2.5 {
                        run_last,last=i,link
                        continue
                    }
                    if run_first>=0 {
                        // The middle sample of the run stands for it.
                        middle:=run
                        if run_last>run_first {
                            mid:=(run_first+run_last)/2
                            start:=a+(b-a)*((f32(mid)+0.5)/f32(samples))
                            if probed,_,ok:=nav_jump_probe(mesh,from_ref,start,out_dir,jump,reach,past);ok && probed.kind==run.kind {middle=probed}
                        }
                        if clear==nil || clear(user,middle) {
                            if count>=len(out) {complete=false;return}
                            out[count]=middle
                            count+=1
                        }
                        run_first=-1
                    }
                    if found {run_first,run_last,run,last=i,i,link,link}
                }
            }
        }
    }
    return
}

// The nearest surface outward from a point of a wall that the agent can
// reach by a jump or a drop: the highest floor under each probe. past: a
// jump to the first surface beyond the floor the probes meet first, as from
// roof to roof over the street of a gap.
@(private)
nav_jump_probe :: proc "contextless" (mesh:^Nav_Mesh,from:Nav_Ref,start,dir:math.Vec3,jump:Nav_Jump,reach:f32,past:bool) -> (link:Nav_Jump_Link,to:Nav_Ref,ok:bool) {
    low:=start.y-max(jump.down,jump.climb)
    high:=start.y+max(jump.up,jump.climb)
    probe_step:=jump.step*0.5
    first:=max(jump.radius*2,probe_step)
    gap:=f32(max(f32))
    for k in 0..<4096 {
        d:=first+f32(k)*probe_step
        if !(d<=reach) {break}
        x:=start+dir*d
        ref,point,found:=nav_highest_floor(mesh,{x.x,(high+low)*0.5,x.z},{probe_step*0.5,(high-low)*0.5,probe_step*0.5})
        if !found || ref==from {continue}
        dy:=point.y-start.y
        if abs(dy)<=jump.climb && d<=jump.radius*2+jump.step {continue}
        flat:=linalg.length(math.Vec3{point.x-start.x,0,point.z-start.z})
        link={start=start,end=point,need={up=max(dy,0),across=flat,down=max(-dy,0)}}
        if past {
            if gap==max(f32) {gap=point.y}
            if abs(point.y-gap)<=jump.climb {continue}
            if dy<=jump.up && -dy<=jump.down && flat<=jump.across && (jump.up>0 || jump.across>0) {
                link.kind=.Jump
                return link,ref,true
            }
            continue
        }
        if dy< -jump.climb && flat<=jump.radius*4+jump.step {
            if -dy>jump.down {return}
            // Nearer, the body falling along the arc would still touch the edge it leaves.
            if flat<jump.radius*4 {continue}
            link.kind=.Drop
            link.need.across=0
            return link,ref,true
        }
        if dy<=jump.up && -dy<=jump.down && flat<=jump.across && (jump.up>0 || jump.across>0) {
            link.kind=.Jump
            return link,ref,true
        }
    }
    return
}

// The polygon with the highest surface over the XZ of the center within a
// box, and that point of its surface.
@(private)
nav_highest_floor :: proc "contextless" (mesh:^Nav_Mesh,center,extents:math.Vec3) -> (ref:Nav_Ref,point:math.Vec3,ok:bool) {
    best:=f32(-max(f32))
    it:=nav_box_polys(mesh,{center-extents,center+extents})
    for r in nav_box_polys_next(&it) {
        y,over:=nav_poly_height(mesh,r,center)
        if !over || y<center.y-extents.y || y>center.y+extents.y {continue}
        if y>best {best=y;ref=r;point={center.x,y,center.z}}
    }
    return ref,point,ref!=0
}
