package volume

import "core:math/linalg"
import "mirai:core"
import scene "mirai:engine/scene"
import gpu "mirai:render"
import mm "mirai:std/math"
import "mirai:std/spatial"

// One way to say where: every region of the world is a Volume, a shape and
// nothing else. What happens in it is another component of the same entity,
// of the library that does it: a value that changes by zone (Gravity, Wind,
// Audio_Reverb, View_Volume, fog), a fluid, a force, a navigation area, what
// bends the grass. With the plugin physics a box or a sphere also tells the
// game what bodies go in and out of it (Physics_Events.overlap_begin and
// overlap_end). Without a Volume a zone value rules the whole world.
//
// A library that needs a region asks this one whether a point is in it
// (depth, weight, holds), whether a box meets it (overlaps) or what box holds
// it (bounds), and takes any shape: no component carries a shape of its own.
//
// How zone values meet is of the values, in their Zone: at a point the ones
// whose volumes hold it are applied from the lowest priority up, on top of the
// default of the library; among equal priorities the bigger first, so a room
// inside a hall wins. Each replaces what is below by its weight, or adds to
// it. The weight is 1 inside and goes to 0 over the last blend metres before
// the border.
//
// What asks at one point (a view, the listener) gathers the volumes in one
// pass (at). What asks at many points in a tick (the gravity of each body)
// keeps an Index: the unbounded volumes, whose value it combines again only
// when they change, and the bounded ones in a tree, which a point asks for
// those that may hold it; where none does, the point costs reading that value.
//
// An unbounded volume rules the whole world only when it comes with the root
// scene: one under a section rules in the box of that section
// (scene.Scene_Reference.extents), and nowhere while that box has no size.

Volume_Shape :: enum u8 {
    Unbounded, // the whole world
    Box,       // extents: half its size along each axis
    Sphere,    // extents.x: its radius
    Plane,     // everything under the plane through the entity whose normal is its up (+Y): a sea, a pit
}

@(component,replicated,description="Where what its entity does happens: a zone value (Gravity, Wind, Audio_Reverb, View_Volume), a fluid, a force, a navigation area; with physics a box or a sphere also reports the bodies that go in and out. The whole world, a box or a sphere scaled by the entity, or everything under the plane of the entity.")
Volume :: struct {
    shape:Volume_Shape,
    extents:[3]f32 `mirai:"min=0,unit=m"`,
}

VOLUME_DEFAULT :: Volume{shape=.Box,extents={5,5,5}}

Zone_Mode :: enum u8 {Replace,Add}

// How a zone value meets the others where their volumes hold the same point.
Zone :: struct {
    blend:f32 `mirai:"min=0,unit=m"`, // inside the border of its Volume, where its weight goes from 0 to 1
    priority:i32,                     // the higher goes on top
    mode:Zone_Mode,
}

ZONE_DEFAULT :: Zone{blend=1}

// A box of half that size along each axis, scaled by the entity.
box :: proc "contextless" (half:[3]f32) -> Volume {return {shape=.Box,extents=half}}
// A sphere of that radius, scaled by the entity.
sphere :: proc "contextless" (radius:f32) -> Volume {return {shape=.Sphere,extents={radius,0,0}}}
// Everything under the entity, as its up (+Y) says where under is.
plane :: proc "contextless" () -> Volume {return {shape=.Plane}}
// The whole world; under a section, the box of its section.
world :: proc "contextless" () -> Volume {return {shape=.Unbounded}}

// The tables where a volume is: its shape, its pose and, unbounded under a
// section, the box of that section.
Where :: struct {
    volumes:^core.Table(Volume,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    parents:^core.Table(core.Parent,.Read),
    sections:^core.Table(scene.Scene_Reference,.Read),
}

// When a table of volumes changes: an unbounded volume with extents was meant
// to be a box, and without its shape it rules everywhere.
@(storage)
Volume_Check :: struct {seen:core.Seen `mirai:"transient,hidden"`}

@(step="frame")
volumes_check :: proc(volumes:^core.Table(Volume,.Read),check:^Volume_Check,problems:^core.Problems) {
    if !core.touched(volumes,&check.seen) {return}
    for row in 0..<core.count(volumes) {
        if v:=core.at(volumes,row);v.shape==.Unbounded && v.extents!={} {
            core.report(problems,core.entity_at(volumes,row),"volume.unbounded_extents","this Volume has extents but its shape is Unbounded, so it rules the whole world: use volume.box or volume.sphere, or leave the extents at zero")
        }
    }
}

// The volumes of one value that hold a point, the most that are applied at
// once: past it the lowest priorities are left out.
HITS_CAPACITY :: 16

Hit :: struct {
    row:i32,    // of the table of the value
    weight:f32, // 0 to 1
    add:bool,
    priority:i32,
    size:f32,   // m3; unbounded: max
}

Hits :: struct {
    hits:[HITS_CAPACITY]Hit,
    count:int,
}

// How far inside a volume placed at pose a point is, m: below 0 outside it;
// max(f32) for an unbounded one. A size, a pose or a point that is not a
// number is outside.
depth :: proc "contextless" (v:Volume,pose:mm.Transform,point:[3]f32) -> f32 {
    d:=-max(f32)
    switch v.shape {
    case .Unbounded:
        return max(f32)
    case .Box:
        local:=mm.quat_rotate(mm.quat_inverse(pose.rotation),point-pose.position)
        in_axis:=v.extents*linalg.abs(pose.scale)-linalg.abs(local)
        // min leaves out what is not a number.
        if in_axis.x!=in_axis.x || in_axis.y!=in_axis.y || in_axis.z!=in_axis.z {return -max(f32)}
        d=min(in_axis.x,in_axis.y,in_axis.z)
    case .Sphere:
        scale:=linalg.abs(pose.scale)
        d=v.extents.x*max(scale.x,scale.y,scale.z)-linalg.length(point-pose.position)
    case .Plane:
        d=-linalg.dot(mm.quat_rotate(pose.rotation,[3]f32{0,1,0}),point-pose.position)
    }
    return d==d?d:-max(f32)
}

// Whether a volume placed at pose holds a point; its border counts.
holds :: proc "contextless" (v:Volume,pose:mm.Transform,point:[3]f32) -> bool {
    return depth(v,pose,point)>=0
}

// Whether a volume placed at pose meets a box of the world; touching counts.
// False for a box or a pose that is not finite.
overlaps :: proc "contextless" (v:Volume,pose:mm.Transform,box:spatial.Aabb) -> bool {
    if !spatial.aabb_valid(box) || !pose_finite(pose) {return false}
    scale:=linalg.abs(pose.scale)
    switch v.shape {
    case .Unbounded:
        return true
    case .Box:
        half:=v.extents*scale
        if !finite(half) || !(half.x>=0 && half.y>=0 && half.z>=0) {return false}
        return mm.obb_overlaps({pose.position,pose.rotation,half},{spatial.aabb_center(box),1,spatial.aabb_extents(box)})
    case .Sphere:
        radius:=v.extents.x*max(scale.x,scale.y,scale.z)
        return radius>=0 && mm.sphere_overlaps_aabb({pose.position,radius},box)
    case .Plane:
        // The corner of the box that is deepest under the plane.
        up:=mm.quat_rotate(pose.rotation,[3]f32{0,1,0})
        corner:=[3]f32{up.x>=0?box.min.x:box.max.x,up.y>=0?box.min.y:box.max.y,up.z>=0?box.min.z:box.max.z}
        return linalg.dot(up,corner-pose.position)<=0
    }
    return false
}

// Whether a volume placed at pose can hold a point: a shape of Volume_Shape,
// a pose that is finite, and a size above zero where its shape has one.
valid :: proc "contextless" (v:Volume,pose:mm.Transform) -> bool {
    if !pose_finite(pose) {return false}
    scale:=linalg.abs(pose.scale)
    switch v.shape {
    case .Unbounded,.Plane:
        return true
    case .Box:
        half:=v.extents*scale
        return half.x>0 && half.y>0 && half.z>0 && finite(half)
    case .Sphere:
        radius:=v.extents.x*max(scale.x,scale.y,scale.z)
        return radius>0 && radius<=max(f32)
    }
    return false
}

@(private)
pose_finite :: proc "contextless" (pose:mm.Transform) -> bool {
    turn:=[3]f32{pose.rotation.x,pose.rotation.y,pose.rotation.z}
    return finite(pose.position) && finite(pose.scale) && finite(turn) && pose.rotation.w>=-max(f32) && pose.rotation.w<=max(f32)
}

@(private)
finite :: proc "contextless" (v:[3]f32) -> bool {
    return v.x>=-max(f32) && v.x<=max(f32) && v.y>=-max(f32) && v.y<=max(f32) && v.z>=-max(f32) && v.z<=max(f32)
}

// How much a volume placed at pose holds a point: 1 inside, 0 outside, and
// rising over the last blend metres inside its border.
weight :: proc "contextless" (v:Volume,pose:mm.Transform,point:[3]f32,blend:f32=0) -> f32 {
    d:=depth(v,pose,point)
    if !(d>=0) {return 0}
    if !(blend>0) {return 1}
    return min(d/blend,1)
}

size :: proc "contextless" (v:Volume,pose:mm.Transform) -> f32 {
    scale:=linalg.abs(pose.scale)
    switch v.shape {
    case .Box:
        half:=v.extents*scale
        return 8*half.x*half.y*half.z
    case .Sphere:
        r:=v.extents.x*max(scale.x,scale.y,scale.z)
        return 4.18879*r*r*r
    case .Unbounded,.Plane:
    }
    return max(f32)
}

// The box of the world a volume placed at pose is in: without end where the
// volume has none, as a plane to its sides and under it.
bounds :: proc "contextless" (v:Volume,pose:mm.Transform) -> spatial.Aabb {
    scale:=linalg.abs(pose.scale)
    half:[3]f32
    switch v.shape {
    case .Box:
        h:=v.extents*scale
        half=linalg.abs(mm.quat_rotate(pose.rotation,{h.x,0,0}))+linalg.abs(mm.quat_rotate(pose.rotation,{0,h.y,0}))+linalg.abs(mm.quat_rotate(pose.rotation,{0,0,h.z}))
    case .Sphere:
        r:=v.extents.x*max(scale.x,scale.y,scale.z)
        half={r,r,r}
    case .Plane:
        all:=spatial.Aabb{{-max(f32),-max(f32),-max(f32)},{max(f32),max(f32),max(f32)}}
        up:=mm.quat_rotate(pose.rotation,[3]f32{0,1,0})
        // Only a plane across an axis of the world leaves out the half of it over the plane.
        for axis in 0..<3 {
            if up[axis]>=1-1e-6 {all.max[axis]=pose.position[axis]} else if up[axis]<=-1+1e-6 {all.min[axis]=pose.position[axis]}
        }
        return all
    case .Unbounded:
        return {{-max(f32),-max(f32),-max(f32)},{max(f32),max(f32),max(f32)}}
    }
    return {pose.position-half,pose.position+half}
}

@(private)
hits_add :: proc "contextless" (h:^Hits,hit:Hit) {
    below :: proc "contextless" (a,b:Hit) -> bool {return a.priority<b.priority || a.priority==b.priority && a.size>b.size}
    at:=h.count
    if at==HITS_CAPACITY {
        if below(hit,h.hits[0]) {return}
        for i in 1..<HITS_CAPACITY {h.hits[i-1]=h.hits[i]}
        at-=1
    } else {
        h.count+=1
    }
    for at>0 && below(hit,h.hits[at-1]) {
        h.hits[at]=h.hits[at-1]
        at-=1
    }
    h.hits[at]=hit
}

@(private)
hit_of :: proc "contextless" (row:int,v:Volume,pose:mm.Transform,zone:Zone,weight:f32) -> Hit {
    return {row=i32(row),weight=weight,add=zone.mode==.Add,priority=zone.priority,size=size(v,pose)}
}

// Where the volume of e rules, as a shape at a pose: without a Volume, the
// whole world; unbounded under a section, the box of that section. False
// where it rules nowhere (no pose, or a section box without size).
placed :: proc(at:Where,e:core.Entity) -> (v:Volume,pose:mm.Transform,ok:bool) {
    found:bool
    v,found=core.get(at.volumes,e)
    if !found {return {},mm.TRANSFORM_IDENTITY,true}
    if v.shape==.Unbounded {
        section:=at.sections!=nil?core.ancestor_with(at.parents,at.sections,e):core.NONE
        if section==core.NONE {return v,mm.TRANSFORM_IDENTITY,true}
        reference,_:=core.get(at.sections,section)
        box,boxed:=core.get(at.worlds,section)
        if reference.extents=={} || !boxed {return}
        return {shape=.Box,extents=reference.extents},box.transform,true
    }
    world,placed:=core.get(at.worlds,e)
    return v,world.transform,placed
}

// The volumes of the value of table that hold point, in the order they are
// applied, in one pass over them.
gather :: proc(at:Where,table:^core.Table($T,$A),point:[3]f32) -> (h:Hits) {
    for row in 0..<core.count(table) {
        v,pose,ok:=placed(at,core.entity_at(table,row))
        if !ok {continue}
        zone:=core.at(table,row).zone
        if w:=weight(v,pose,point,zone.blend);w>0 {hits_add(&h,hit_of(row,v,pose,zone,w))}
    }
    return
}

// What the hits make of value: each changes it by its own value, which
// value_of gives for its row, by its weight; mix replaces or adds.
combine :: proc(h:Hits,value:$V,user:$U,value_of:proc(user:U,row:i32) -> V,mix:proc(value:^V,by:V,weight:f32,add:bool)) -> V {
    value:=value
    for i in 0..<h.count {mix(&value,value_of(user,h.hits[i].row),h.hits[i].weight,h.hits[i].add)}
    return value
}

// The value of table at a point: every volume that holds it over fallback.
at :: proc(zones:Where,table:^core.Table($T,$A),point:[3]f32,fallback:T,mix:proc(value:^T,by:T,weight:f32,add:bool)) -> T {
    if table==nil {return fallback}
    of :: proc(table:^core.Table(T,A),row:i32) -> T {return core.at(table,int(row))}
    return combine(gather(zones,table,point),fallback,table,of,mix)
}

// mix for a value that is numbers: lerp to replace, scaled to add.
mix_linear :: proc(value:^$T,by:T,weight:f32,add:bool) {
    if add {value^+=by*weight} else {value^+=(by-value^)*weight}
}

// What an Index keeps of the volume of one row of the value.
Place :: struct {
    volume:Volume,      // as it rules: unbounded under a section, the box of that section
    pose:mm.Transform,  // of that shape
    world:mm.Transform, // of the entity of the value, which turns a gravity or a wind; the identity without one
    zone:Zone,
    rules:bool,         // false: it rules nowhere
}

// The volumes of a value for a library that asks at many points: made again
// by index_update only when a volume, a value or a place changed.
Index :: struct {
    seen:[3]core.Seen,         // the volumes, the values and the sections it was made from
    placed:core.Seen,          // and the places it compared
    made:bool,
    places:[dynamic]Place,     // one per row of the value
    unbounded:Hits,            // the unbounded ones, weight 1, in the order they apply
    tree:spatial.Dynamic_Tree, // the boxes and the spheres, by their row
    planes:[dynamic]i32,       // the rows of the planes, which no box of a tree bounds
}

// Whether some volume of the index has a border: its value changes from
// place to place.
index_bounded :: proc "contextless" (ix:^Index) -> bool {
    return ix.tree.proxy_count>0 || len(ix.planes)>0
}

index_destroy :: proc(ix:^Index) {
    delete(ix.places)
    delete(ix.planes)
    spatial.dynamic_tree_destroy(&ix.tree)
    ix^={}
}

@(private)
place_of :: proc(at:Where,table:^core.Table($T,$A),row:int) -> (p:Place) {
    e:=core.entity_at(table,row)
    p.volume,p.pose,p.rules=placed(at,e)
    p.world=mm.TRANSFORM_IDENTITY
    if world,found:=core.get(at.worlds,e);found {p.world=world.transform}
    p.zone=core.at(table,row).zone
    return
}

// Makes the index of the value of table again when its volumes, its values
// or where they are changed. changed: it was made again, and what a library
// combined from it is to be combined again. ok is false without memory: then
// no volume holds any point until an update finds it.
index_update :: proc(ix:^Index,at:Where,table:^core.Table($T,$A)) -> (changed,ok:bool) {
    moved:=core.touched(at.volumes,&ix.seen[0]) | core.touched(at.sections,&ix.seen[2])
    count:=0
    if table!=nil {
        moved|=core.touched(table,&ix.seen[1])
        count=core.count(table)
    }
    placed:=core.touched(at.worlds,&ix.placed)
    if ix.made && !moved {
        if !placed {return false,true}
        same:=true
        for p,row in ix.places {
            if place_of(at,table,row)!=p {same=false;break}
        }
        if same {return false,true}
    }
    ix.made=false
    clear(&ix.places)
    clear(&ix.planes)
    ix.unbounded={}
    spatial.dynamic_tree_clear(&ix.tree)
    if reserve(&ix.places,count)!=nil {return true,false}
    bounded,planes:=0,0
    for row in 0..<count {
        p:=place_of(at,table,row)
        append(&ix.places,p)
        if !p.rules {continue}
        switch p.volume.shape {
        case .Unbounded:   hits_add(&ix.unbounded,hit_of(row,p.volume,p.pose,p.zone,1))
        case .Plane:       planes+=1
        case .Box,.Sphere: bounded+=1
        }
    }
    if reserve(&ix.planes,planes)!=nil {
        clear(&ix.places)
        ix.unbounded={}
        return true,false
    }
    if bounded>0 && 2*bounded>len(ix.tree.nodes) {
        spatial.dynamic_tree_destroy(&ix.tree)
        if !spatial.dynamic_tree_init(&ix.tree,{proxy_capacity=max(2*bounded,16)}) {
            clear(&ix.places)
            ix.unbounded={}
            return true,false
        }
    }
    for p,row in ix.places {
        if !p.rules {continue}
        #partial switch p.volume.shape {
        case .Plane:
            append(&ix.planes,i32(row))
        case .Box,.Sphere:
            if box:=bounds(p.volume,p.pose);spatial.aabb_valid(box) {spatial.dynamic_tree_insert(&ix.tree,box,u64(row))}
        }
    }
    ix.made=true
    return true,true
}

// The volumes of the index that hold point, in the order they are applied.
// bounded: some volume with a border holds it; without one, the hits are
// the unbounded ones alone, which every point that none holds shares.
index_hits :: proc(ix:^Index,point:[3]f32) -> (h:Hits,bounded:bool) {
    if ix.tree.proxy_count>0 {
        q:=spatial.dynamic_tree_query(&ix.tree,{point,point})
        for _,user in spatial.tree_query_next(&q) {
            p:=ix.places[user]
            if w:=weight(p.volume,p.pose,point,p.zone.blend);w>0 {
                hits_add(&h,hit_of(int(user),p.volume,p.pose,p.zone,w))
                bounded=true
            }
        }
    }
    for row in ix.planes {
        p:=ix.places[row]
        if w:=weight(p.volume,p.pose,point,p.zone.blend);w>0 {
            hits_add(&h,hit_of(int(row),p.volume,p.pose,p.zone,w))
            bounded=true
        }
    }
    if !bounded {return ix.unbounded,false}
    for i in 0..<ix.unbounded.count {hits_add(&h,ix.unbounded.hits[i])}
    return h,true
}

// The volumes of the value of table in the order they are applied, wherever
// they are: what a shader that combines them at each point gets, with
// gpu_volume. rows takes their rows; past its length the lowest priorities
// are left out.
ordered :: proc(at:Where,table:^core.Table($T,$A),rows:[]i32) -> int {
    h:Hits
    for row in 0..<core.count(table) {
        v,pose,ok:=placed(at,core.entity_at(table,row))
        if !ok {continue}
        hits_add(&h,hit_of(row,v,pose,core.at(table,row).zone,1))
    }
    n:=min(h.count,len(rows))
    for i in 0..<n {rows[i]=h.hits[h.count-n+i].row}
    return n
}

// volume.slang Gpu_Volume: where a volume is, for volume_weight on the GPU.
Gpu_Volume :: struct {
    to_local:[3][4]f32, // rows: from the world to the volume, turned and moved, not scaled
    shape:[4]f32,       // xyz half its size along each axis, metres (x the radius of a sphere); w its blend
    kind:[4]u32,        // x 0 unbounded, 1 box, 2 sphere, 3 plane; y 1 when it adds
}
#assert(size_of(Gpu_Volume)==80)

gpu_volume :: proc "contextless" (v:Volume,pose:mm.Transform,zone:Zone) -> (g:Gpu_Volume) {
    scale:=linalg.abs(pose.scale)
    switch v.shape {
    case .Unbounded,.Plane:
    case .Box:    g.shape.xyz=v.extents*scale
    case .Sphere: g.shape.x=v.extents.x*max(scale.x,scale.y,scale.z)
    }
    g.shape.w=max(zone.blend,0)
    g.kind={u32(v.shape),u32(zone.mode==.Add),0,0}
    back:=mm.quat_inverse(pose.rotation)
    x,y,z:=mm.quat_rotate(back,{1,0,0}),mm.quat_rotate(back,{0,1,0}),mm.quat_rotate(back,{0,0,1})
    // The columns of the inverse rotation: row i of the matrix is axis i of the world seen from the volume.
    m:=[3][3]f32{{x.x,y.x,z.x},{x.y,y.y,z.y},{x.z,y.z,z.z}}
    for i in 0..<3 {
        g.to_local[i]={m[i][0],m[i][1],m[i][2],f32(-(f64(m[i][0])*f64(pose.position.x)+f64(m[i][1])*f64(pose.position.y)+f64(m[i][2])*f64(pose.position.z)))}
    }
    return
}

// A volume of gpu_volume for a shader whose places are relative to origin
// (the origin the renderer draws from, Stage_Pass.origin).
gpu_volume_relative :: proc "contextless" (g:Gpu_Volume,origin:[3]f32) -> Gpu_Volume {
    g:=g
    g.to_local=gpu.origin_from_world(g.to_local,origin)
    return g
}
