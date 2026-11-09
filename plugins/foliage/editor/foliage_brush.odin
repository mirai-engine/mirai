package foliage_editor

import "core:math"
import "core:math/linalg"
import "core:slice"
import foliage "plugins:foliage/runtime"
import mm "mirai:std/math"

// What the brush and the selection do to a source, in the space of its
// entity: the tool calls them with the points the scene gives under the
// pointer, and the tests by steps.

// How far above or below the ground an instance placed on it may stand and
// still be on it (INSTANCE_GROUNDED): the ground is a grid of samples, the
// surface the picker met is the terrain's own.
GROUND_SNAP :: f32(0.25)

// The flags and the offset of an instance placed at a point: on the ground
// when the ground under it is known and the point is on it.
grounded :: proc "contextless" (ground:foliage.Ground_Cell,local:[3]f32) -> (flags:u32,offset:f32) {
    h,_,ok:=foliage.ground_at(ground,local.x,local.z)
    if !ok || abs(local.y-h)>GROUND_SNAP {return}
    return foliage.INSTANCE_GROUNDED,local.y-h
}

// The ground of the cell of a point, from the ground of an owner (nil: none).
ground_of :: proc "contextless" (owner:^foliage.Ground_Owner,coord:[2]i32) -> foliage.Ground_Cell {
    ground,_:=foliage.ground_cell(owner,coord)
    return ground
}

// A manual instance of a type at a point of the surface with its normal,
// scaled, turned, leaned, aligned and offset at random as the type says. One
// on the ground keeps its turn and lean from the ground (INSTANCE_ALIGNED),
// which aligns it as the generated ones and again when the ground changes.
paint_instance :: proc(s:^foliage.Source,t:^foliage.Foliage_Type,point,normal:[3]f32,random:^mm.Rng,ground:^foliage.Ground_Owner) -> (coord:[2]i32,id:u32) {
    g:=foliage.Generated{type=t.id}
    g.yaw=mm.random_f32(random)*t.yaw
    g.tilt=mm.random_f32(random)*t.tilt
    g.tilt_turn=mm.random_f32(random)*math.TAU
    across:=t.scale[0]+(t.scale[1]-t.scale[0])*mm.random_f32(random)
    along:=across*(t.height[0]+(t.height[1]-t.height[0])*mm.random_f32(random))
    cell,local:=foliage.cell_of(point)
    flags,offset:=grounded(ground_of(ground,cell),local)
    rotation:=foliage.generated_rotation(g,flags!=0?0:t.align,normal)
    if flags!=0 {flags|=foliage.INSTANCE_ALIGNED}
    // Sunk or raised along its own up by the offset of its type.
    sink:=t.offset[0]+(t.offset[1]-t.offset[0])*mm.random_f32(random)
    point:=point+mm.quat_rotate(rotation,[3]f32{0,sink,0})
    return foliage.source_instance_add(s,t.id,point,u32(mm.quat_pack(rotation,10)),{across,along},flags,offset+sink)
}

// The cells a disc of x and z around a point touches.
@(private)
cells_around :: proc "contextless" (center:[3]f32,radius:f32) -> (low,high:[2]i32) {
    low,_=foliage.cell_of(center-{radius,0,radius})
    high,_=foliage.cell_of(center+{radius,0,radius})
    return
}

@(private)
in_brush :: proc "contextless" (p,center:[3]f32,radius:f32) -> bool {
    d:=p-center
    return d.x*d.x+d.z*d.z<=radius*radius && abs(d.y)<=radius*2
}

// An instance near the brush: its type and where it is.
Near :: struct {type:u32,position:[3]f32}

// The instances of the types a brush covers, appended to out.
instances_near :: proc(s:^foliage.Source,ground:^foliage.Ground_Owner,types:[]u32,center:[3]f32,radius:f32,work:^foliage.Build_Work,out:^[dynamic]Near) {
    low,high:=cells_around(center,radius)
    for z in low.y..=high.y {for x in low.x..=high.x {
        cell:=foliage.source_cell(s,{x,z})
        if cell==nil {continue}
        foliage.cell_build(s,cell,ground_of(ground,cell.coord),work)
        for p in work.placed {if slice.contains(types,p.type) && in_brush(p.position,center,radius) {append(out,Near{p.type,p.position})}}
    }}
}

// How many instances a touch adds to bring the brush to a density, in
// instances per square metre: those it lacks, or one with the chance of a
// fraction of one.
paint_count :: proc "contextless" (density,radius:f32,existing:int,random:^mm.Rng) -> int {
    desired:=density*math.PI*radius*radius
    whole:=int(desired)
    if mm.random_f32(random)<desired-f32(whole) {whole+=1}
    return max(whole-existing,0)
}

// Whether a point keeps the spacing of the density of a type from the
// instances of that type near it.
spaced :: proc "contextless" (p:[3]f32,near:[]Near,type:u32,density:f32) -> bool {
    if !(density>0) {return true}
    gap:=0.5/math.sqrt(density)
    for q in near {
        if q.type!=type {continue}
        d:=p-q.position
        if d.x*d.x+d.z*d.z<gap*gap {return false}
    }
    return true
}

// A point of the disc of a brush on the plane of a normal, at random.
disc_point :: proc "contextless" (center,normal:[3]f32,radius:f32,random:^mm.Rng) -> [3]f32 {
    n:=linalg.normalize0(normal)
    if n=={} {n={0,1,0}}
    reference:=abs(n.y)>0.9?[3]f32{1,0,0}:[3]f32{0,1,0}
    u:=linalg.normalize(linalg.cross(n,reference))
    v:=linalg.cross(n,u)
    r:=radius*math.sqrt(mm.random_f32(random))
    angle:=mm.random_f32(random)*math.TAU
    return center+(u*math.cos(angle)+v*math.sin(angle))*r
}


// Turns the generator on or off in the cells under a brush. True when one changed.
generate_touch :: proc(s:^foliage.Source,center:[3]f32,radius:f32,on:bool) -> (changed:bool) {
    return foliage.source_generate_area(s,center,radius,on)
}

// An instance a selection names: its cell and its id (foliage.Placed.id).
Instance_Ref :: struct {
    coord:[2]i32,
    id:u64,
}

// The instance of a cell that the k-th instance of a batch of a type shows:
// the batches of a cell hold the instances of each type in the order the
// cell places them.
instance_of_batch :: proc(s:^foliage.Source,ground:^foliage.Ground_Owner,coord:[2]i32,type:u32,k:int,work:^foliage.Build_Work,role:=foliage.ROLE_MESH,owner:=mm.Quat(1)) -> (ref:Instance_Ref,placed:foliage.Placed,found:bool) {
    cell:=foliage.source_cell(s,coord)
    if cell==nil {return}
    foliage.cell_build(s,cell,ground_of(ground,coord),work)
    foliage.placed_group(s,work)
    t,index:=foliage.source_type(s,type)
    if index<0 {return}
    order:=work.order[work.firsts[index]:work.firsts[index+1]]
    // A variant of the wind holds the instances of its turn alone.
    at:=foliage.role_instance(role,foliage.wind_variants(t^),owner,work.placed[:],order,k)
    if at<0 || at>=len(order) {return}
    placed=work.placed[order[at]]
    return {coord,placed.id},placed,true
}

// Where an instance is now, as its cell places it.
instance_placed :: proc(s:^foliage.Source,ground:^foliage.Ground_Owner,ref:Instance_Ref,work:^foliage.Build_Work) -> (placed:foliage.Placed,found:bool) {
    cell:=foliage.source_cell(s,ref.coord)
    if cell==nil {return}
    foliage.cell_build(s,cell,ground_of(ground,ref.coord),work)
    for p in work.placed {if p.id==ref.id {return p,true}}
    return
}

// The instance a placement makes, in the space of the entity, from its cell:
// one on the ground keeps its rotation from the ground (INSTANCE_ALIGNED), so
// that it stands as placed and leans with a ground that changes.
@(private)
instance_record :: proc "contextless" (s:^foliage.Source,p:foliage.Placed,ground:^foliage.Ground_Owner) -> (coord:[2]i32,instance:foliage.Foliage_Instance) {
    local:[3]f32
    coord,local=foliage.cell_of(p.position)
    cell:=ground_of(ground,coord)
    flags,offset:=grounded(cell,local)
    rotation:=p.rotation
    if t,_:=foliage.source_type(s,p.type);t!=nil && flags!=0 {
        _,normal,_:=foliage.ground_at(cell,local.x,local.z)
        rotation=linalg.normalize(conj(foliage.ground_slope(t.align,normal))*rotation)
        flags|=foliage.INSTANCE_ALIGNED
    }
    return coord,{type=p.type,flags=flags,position=local,rotation=u32(mm.quat_pack(rotation,10)),scale=p.scale,ground=offset}
}

// Puts an instance where a placement says, with its type: a manual one in
// its cell, or in the cell it moves to; a generated one becomes an override
// Moved (Replaced with another type) in its cell, or Deleted there and a
// manual one in the cell it moves to. What names it afterwards.
instance_set :: proc(s:^foliage.Source,ground:^foliage.Ground_Owner,ref:Instance_Ref,p:foliage.Placed) -> (next:Instance_Ref,ok:bool) {
    cell:=foliage.source_cell(s,ref.coord)
    if cell==nil || !(p.scale[0]>0) || !(p.scale[1]>0) {return}
    coord,instance:=instance_record(s,p,ground)
    if t,_:=foliage.source_type(s,p.type);t==nil {return}
    if ref.id&foliage.MANUAL!=0 {
        // A manual one keeps its id, also in another cell.
        instance.id=u32(ref.id)
        index:=foliage.manual_find(cell,instance.id)
        if index<0 {return}
        if coord==ref.coord {
            cell.manual[index]=instance
            return ref,true
        }
        foliage.source_instance_remove(s,ref.coord,instance.id)
        append(&foliage.source_cell(s,coord,true).manual,instance)
        return {coord,ref.id},true
    }
    type,point:=u32(ref.id>>32),u32(ref.id)
    if coord==ref.coord {
        foliage.source_override_set(s,ref.coord,{type=type,point=point,kind=p.type==type?.Moved:.Replaced,instance=instance})
        return ref,true
    }
    added_coord,added:=foliage.source_instance_add(s,p.type,p.position,instance.rotation,instance.scale,instance.flags,instance.ground)
    if added==0 {return}
    foliage.source_override_set(s,ref.coord,{type=type,point=point,kind=.Deleted})
    return {added_coord,foliage.MANUAL | u64(added)},true
}

// Takes an instance out: a manual one from its cell, a generated one by an override Deleted.
instance_delete :: proc(s:^foliage.Source,ref:Instance_Ref) -> bool {
    if ref.id&foliage.MANUAL!=0 {return foliage.source_instance_remove(s,ref.coord,u32(ref.id))}
    if foliage.source_cell(s,ref.coord)==nil {return false}
    foliage.source_override_set(s,ref.coord,{type=u32(ref.id>>32),point=u32(ref.id),kind=.Deleted})
    return true
}

// The transform of the world of an instance, as the gizmo holds it.
instance_world :: proc "contextless" (p:foliage.Placed,owner:mm.Transform) -> mm.Transform {
    return {position=mm.transform_point(owner,p.position),rotation=owner.rotation*p.rotation,scale={p.scale[0]*owner.scale.x,p.scale[1]*owner.scale.y,p.scale[0]*owner.scale.z}}
}

// The placement of an instance in the space of its entity from a transform
// of the world: one scale across x and z, the mean of the two.
instance_local :: proc "contextless" (world:mm.Transform,owner:mm.Transform,type:u32) -> (p:foliage.Placed) {
    p.type=type
    p.position=mm.transform_inverse_point(owner,world.position)
    p.rotation=linalg.normalize(conj(owner.rotation)*world.rotation)
    p.scale={(world.scale.x/owner.scale.x+world.scale.z/owner.scale.z)*0.5,world.scale.y/owner.scale.y}
    return
}
