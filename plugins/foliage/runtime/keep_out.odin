package foliage

import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// What keeps generated foliage out of where a game builds: an entity with
// Foliage_Keep_Out, by its Volume, else the width of its Spline, else its
// Collider. foliage_ground marks it in the tiles of ground it reads
// (Ground_Cell.kept), on the ground of each square, and reads again the
// tiles under one that comes, goes or changes, so that the cells under it are
// built again.

@(component,description="Keeps the foliage the generator makes out of its entity: out of its Volume, else the width of its Spline (a road, a path, a river), else its Collider (a box, a sphere, a capsule or a cylinder), and margin metres around it.")
Foliage_Keep_Out :: struct {
    margin:f32 `mirai:"min=0,unit=m"`,
}

KEEP_OUT_PIECE :: f32(1) // m between the samples of the curve of a Spline that keeps foliage out
KEEP_OUT_SAMPLES :: 512  // of the curve of a Spline, at most
KEEP_OUTS_A_TILE :: 64   // tested at each square of a tile; past them, all of them are

Keep_Out_Kind :: enum u8 {Volume,Spline,Capsule,Cylinder}

// A region that keeps foliage out, in the world.
Keep_Out :: struct {
    entity:core.Entity,
    kind:Keep_Out_Kind,
    box:mm.Aabb,            // around it and its margin
    shape:volume.Volume,    // of a Volume; of a Capsule or a Cylinder, its radius in x and half its height in y
    pose:mm.Transform,
    margin:f32,
    points:[]mm.Path_Point, // the outline of a Volume, or the curve of a Spline in the world
    stamp:u64,              // of all of it
}

// Where a keep-out was when the tiles were last asked for, by its entity.
Keep_Out_Seen :: struct {
    entity:core.Entity,
    box:mm.Aabb,
    stamp:u64,
}

// The regions that keep foliage out now, into out, with points from the
// temporary allocator. What has nothing that says where is a problem.
keep_outs_gather :: proc(keeps:^core.Table(Foliage_Keep_Out,$A),at:volume.Where,colliders:^core.Table(physics.Collider,$B),out:^[dynamic]Keep_Out,problems:^core.Problems) {
    clear(out)
    if keeps==nil {return}
    for row in 0..<core.count(keeps) {
        e:=core.entity_at(keeps,row)
        k:=Keep_Out{entity=e,margin=core.at(keeps,row).margin}
        if !(k.margin>=0 && k.margin<POSITION_MAX) {k.margin=0}
        world,placed:=core.get(at.worlds,e)
        if !placed {continue}
        k.pose=world.transform
        spline_row:=core.row_of(at.splines,e)
        has_spline:=spline_row>=0
        collider,has_collider:=core.get(colliders,e)
        switch {
        case core.has(at.volumes,e):
            ok:bool
            k.shape,k.pose,k.points,ok=volume.placed(at,e)
            if !ok {continue}
            k.box=volume.bounds(k.shape,k.pose,k.points)
        case has_spline:
            k.kind=.Spline
            buffer:=make([]mm.Path_Point,KEEP_OUT_SAMPLES,context.temp_allocator)
            spline:=&at.splines.values[spline_row]
            n:=volume.spline_sample(spline,KEEP_OUT_PIECE,buffer)
            reach,reached:=volume.spline_reach(spline,k.pose)
            if n<2 || !reached {continue}
            across:=max(abs(k.pose.scale.x),abs(k.pose.scale.z))
            for &p in buffer[:n] {p.position,p.width=mm.transform_point(k.pose,p.position),p.width*across}
            k.points,k.box=buffer[:n],reach
        case has_collider && collider.kind<=.Cylinder:
            scale:=linalg.abs(k.pose.scale)
            k.pose.position+=mm.quat_rotate(k.pose.rotation,collider.center*k.pose.scale)
            switch collider.kind {
            case .Box:     k.shape=volume.box(collider.size)
            case .Sphere:  k.shape=volume.sphere(collider.size.x)
            case .Capsule: k.kind,k.shape.extents=.Capsule,{collider.size.x*max(scale.x,scale.z),collider.size.y*scale.y,0}
            case .Cylinder:k.kind,k.shape.extents=.Cylinder,{collider.size.x*max(scale.x,scale.z),collider.size.y*scale.y,0}
            case .Hull,.Mesh,.Heightfield,.External,.Auto:
            }
            if k.kind==.Volume {
                k.box=volume.bounds(k.shape,k.pose)
            } else {
                r,h:=k.shape.extents.x,k.shape.extents.y+(k.kind==.Capsule?k.shape.extents.x:0)
                around:=k.pose
                around.scale=1
                k.box=volume.bounds(volume.box({r,h,r}),around)
            }
        case:
            core.report(problems,e,"foliage.keep_out","this Foliage_Keep_Out does not say where foliage is kept out: give its entity a Volume, a Spline, or a box, sphere, capsule or cylinder Collider")
            continue
        }
        // Past every cell, not without end: a box without end has no centre.
        reach:=f32(COORD_MAX+1)*CELL_SIZE
        k.box.min=linalg.clamp(k.box.min-k.margin,-reach,reach)
        k.box.max=linalg.clamp(k.box.max+k.margin,-reach,reach)
        k.stamp=keep_out_stamp(&k)
        append(out,k)
    }
}

@(private)
keep_out_stamp :: proc(k:^Keep_Out) -> u64 {
    Fixed :: struct {kind:Keep_Out_Kind,shape:volume.Volume,pose:mm.Transform,margin:f32}
    fixed:=Fixed{k.kind,k.shape,k.pose,k.margin}
    h:=base.hash64(([^]byte)(&fixed)[:size_of(fixed)])
    return base.hash64(([^]byte)(raw_data(k.points))[:len(k.points)*size_of(mm.Path_Point)],h)
}

// Whether a keep-out holds a point of the world.
keep_out_holds :: proc "contextless" (k:^Keep_Out,p:[3]f32) -> bool {
    if !mm.aabb_contains_point(k.box,p) {return false}
    switch k.kind {
    case .Volume:
        return volume.depth(k.shape,k.pose,p,k.points)>=-k.margin
    case .Spline:
        for i in 1..<len(k.points) {
            a,b:=k.points[i-1],k.points[i]
            ab,ap:=b.position.xz-a.position.xz,p.xz-a.position.xz
            t:=clamp(linalg.dot(ap,ab)/max(linalg.dot(ab,ab),1e-12),0,1)
            d:=ap-ab*t
            half:=0.5*(a.width+(b.width-a.width)*t)+k.margin
            if d.x*d.x+d.y*d.y<=half*half {return true}
        }
    case .Capsule,.Cylinder:
        local:=mm.quat_rotate(mm.quat_inverse(k.pose.rotation),p-k.pose.position)
        r,h:=k.shape.extents.x+k.margin,k.shape.extents.y
        if k.kind==.Capsule {
            local.y-=clamp(local.y,-h,h)
            return linalg.dot(local,local)<=r*r
        }
        return local.x*local.x+local.z*local.z<=r*r && abs(local.y)<=h+k.margin
    }
    return false
}

// The boxes of the keep-outs that came, went or changed since seen, into
// changes, and seen made what they are now.
keep_outs_changed :: proc(now:[]Keep_Out,seen:^[dynamic]Keep_Out_Seen,changes:^[dynamic]mm.Aabb) {
    next:=make([dynamic]Keep_Out_Seen,0,len(now),context.temp_allocator)
    for k in now {append(&next,Keep_Out_Seen{k.entity,k.box,k.stamp})}
    for old in seen {
        found:=false
        for k in next {
            if k.entity!=old.entity {continue}
            found=true
            if k.stamp!=old.stamp || k.box!=old.box {append(changes,old.box,k.box)}
            break
        }
        if !found {append(changes,old.box)}
    }
    for k in next {
        found:=false
        for old in seen {if old.entity==k.entity {found=true;break}}
        if !found {append(changes,k.box)}
    }
    clear(seen)
    append(seen,..next[:])
}

// Marks the squares of a tile where foliage is kept out: those whose centre,
// on the ground of the tile, one of keeps holds. None without ground there.
tile_keep_out :: proc(keeps:[]Keep_Out,owner_world:mm.Mat4,coord:[2]i32,ground:Ground_Cell,kept:[]u64) {
    for &w in kept {w=0}
    if len(keeps)==0 {return}
    corner:=cell_corner(coord)
    column:=mm.aabb_transform({{corner.x,-POSITION_MAX,corner.z},{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE}},owner_world)
    near:[KEEP_OUTS_A_TILE]int
    count:=0
    for &k,i in keeps {
        if !mm.aabb_overlaps(k.box,column) {continue}
        if count==len(near) {count=-1;break}
        near[count]=i
        count+=1
    }
    if count==0 {return}
    step:=CELL_SIZE/KEEP_OUT_SIDE
    for k in 0..<KEEP_OUT_SIDE*KEEP_OUT_SIDE {
        x,z:=(f32(k%KEEP_OUT_SIDE)+0.5)*step,(f32(k/KEEP_OUT_SIDE)+0.5)*step
        h,_,on_ground:=ground_at(ground,x,z)
        if !on_ground {continue}
        p:=mm.mat4_point(owner_world,corner+{x,h,z})
        held:=false
        if count<0 {
            for &keep in keeps {if keep_out_holds(&keep,p) {held=true;break}}
        } else {
            for i in near[:count] {if keep_out_holds(&keeps[i],p) {held=true;break}}
        }
        if held {kept[k>>6]|=1<<(uint(k)&63)}
    }
}
