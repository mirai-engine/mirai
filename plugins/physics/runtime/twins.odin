package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// Twins and cuts of the simulation (sim/twin.odin) from rows that another
// library writes, as portals do for what crosses an opening and for the
// walls the openings are in.

@(component,description="A second place of the body: copies of its colliders where `through` carries them, which collide only in front of a plane and push the body back through it. Portals give one to what is halfway through an opening.")
Body_Twin :: struct {
    through:mm.Transform, // rigid: its scale is not used
    point:[3]f32 `mirai:"unit=m"`, // the copies collide only in front of the plane through this point
    normal:[3]f32,                 // that faces this way
}

COLLIDER_CUT_CAPACITY :: 8

Cut_Box :: struct {
    center:[3]f32 `mirai:"unit=m"`,
    rotation:mm.Quat,
    half:[3]f32 `mirai:"unit=m"`, // half extents
}

@(component,description="Boxes where the collider of this entity is not: its contacts and the queries leave out what of it is inside them. A body with its own colliders loses them all there. An opening in a wall, the part of a body that went through one.")
Collider_Cuts :: struct {
    boxes:[COLLIDER_CUT_CAPACITY]Cut_Box,
    count:i32,
}

// The cuts of the rows to the simulation, and the twins: a body gets the one
// its row asks for and loses the one no row asks for. Before the step that
// simulates with them; a body that the step makes again gets its twin and its
// cuts in the next tick.
@(step="fixed",loops="game",stage="simulate",after="physics_places",before="physics_step")
physics_twins :: proc(state:^Physics_State,twins:^core.Table(Body_Twin,.Read),cuts:^core.Table(Collider_Cuts,.Read),problems:^core.Problems) {
    if !state.ready {return}
    w:=&state.world
    list:[sim.CUT_CAPACITY]sim.Cut
    count:=0
    for row in 0..<core.count(cuts) {
        e:=core.entity_at(cuts,row)
        l:=link_find(state,e)
        if l==nil {continue}
        cut:sim.Cut
        switch l.kind {
        case .None: continue
        case .Compound: cut.shape=l.shape
        case .Body,.Proxy: cut.body=l.body
        case .Character: cut.body=sim.character_body(w,l.character)
        }
        c:=core.at(cuts,row)
        // The pieces of a compound are cut as its first shape is.
        pieces:=l.kind==.Compound?pieces_of(state,l):nil
        boxes: for box in c.boxes[:clamp(c.count,0,COLLIDER_CUT_CAPACITY)] {
            rotation:=linalg.normalize(box.rotation)
            if !(abs(rotation.w)<=1) {rotation=1}
            cut.region={box.center,rotation,{abs(box.half.x),abs(box.half.y),abs(box.half.z)}}
            for at in -1..<len(pieces) {
                if count==len(list) {
                    core.report(problems,e,"physics.cuts","the simulation takes %d boxes of Collider_Cuts in all, and the entities that have one ask for more: the boxes after those are left out; cut fewer colliders at once",sim.CUT_CAPACITY)
                    break boxes
                }
                if at>=0 {cut.shape=pieces[at].shape}
                list[count]=cut
                count+=1
            }
            if len(pieces)>0 {cut.shape=l.shape}
        }
    }
    if !sim.world_set_cuts(w,list[:count]) {
        core.report(problems,core.NONE,"physics.cuts","a box of Collider_Cuts is not finite, so the simulation keeps the cuts it had; give every box a finite center, rotation and size")
    }
    for row in 0..<core.count(twins) {
        e:=core.entity_at(twins,row)
        twin:=core.at(twins,row)
        body:=twin_body(state,e)
        if body=={} {continue}
        if !sim.body_set_twin(w,body,{twin.through.position,twin.through.rotation},twin.point,twin.normal) {
            core.report(problems,e,"physics.twin","the simulation refused its Body_Twin: its body is static, the %d twins of the simulation are in use, there is no room in Physics_Settings.shapes for the copies of its shapes, or a value is not finite; make the body dynamic or kinematic, raise shapes, or give fewer bodies a twin",sim.TWIN_CAPACITY)
        }
    }
    bodies:[sim.TWIN_CAPACITY]sim.Body_Handle
    had:=sim.world_twins(w,bodies[:])
    for body in bodies[:had] {
        e:=core.Entity(sim.body_user_data(w,body))
        if !core.has(twins,e) || twin_body(state,e)!=body {sim.body_clear_twin(w,body)}
    }
}

@(private)
twin_body :: proc(state:^Physics_State,e:core.Entity) -> sim.Body_Handle {
    l:=link_find(state,e)
    if l==nil {return {}}
    #partial switch l.kind {
    case .Body,.Proxy: return l.body
    case .Character: return sim.character_body(&state.world,l.character)
    }
    return {}
}

// The box of the shapes of the body of the entity, without the copies of its twin.
body_bounds :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> (bounds:mm.Aabb,ok:bool) {
    if physics.ptr==nil || !physics.ready {return}
    return sim.body_bounds(&physics.world,body_of(physics,e))
}

// The ray against the collider of the entity alone, whatever its collision and its cuts: where its shape is.
collider_raycast :: proc(physics:core.Ref(Physics_State),e:core.Entity,origin,direction:[3]f32,max_distance:f32) -> (hit:Hit,ok:bool) {
    if physics.ptr==nil || !physics.ready || !(max_distance>0 && max_distance<=max(f32)) {return}
    l:=link_find(physics.ptr,e)
    if l==nil {return}
    shape:=l.kind==.Character?sim.character_shape(&physics.world,l.character):l.shape
    length:=linalg.length(direction)
    if !(length>1e-12 && length<=max(f32)) {return}
    ray:=direction*(max_distance/length)
    found:sim.Ray_Hit
    found,ok=sim.shape_ray_cast(&physics.world,shape,origin,ray)
    // The nearest of the pieces of a hull made of several.
    for piece in pieces_of(physics.ptr,l) {
        if near,hit_piece:=sim.shape_ray_cast(&physics.world,piece.shape,origin,ray);hit_piece && (!ok || near.fraction<found.fraction) {
            found,ok=near,true
        }
    }
    if !ok {return}
    return hit_of(&physics.world,found,max_distance),true
}
