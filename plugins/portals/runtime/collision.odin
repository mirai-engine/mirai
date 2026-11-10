package portals

import "core:math/linalg"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import mm "mirai:std/math"

// What a portal is for the physics. Its wall, of any collider, has a hole the
// size of the opening, as deep as the wall, and boxes that line that hole: the
// wall is cut (phys.Collider_Cuts) and not made again. A traveler halfway in
// is also where the portal carries it: a twin of its body (phys.Body_Twin)
// stands behind the exit and collides with what is in front of it, and what
// the twin touches pushes the traveler back through the portal. The part of
// the traveler beyond the wall is not on this side: it is cut away.

RIM_WIDTH :: 0.1 // m around the opening: the wall gives way to its frame there
RIM_DEPTH_MIN :: 0.1 // m of the frame of a wall that a ray finds no back to, as one sided triangles
WALL_REACH :: 0.5 // m in front of and behind the opening a ray looks for the face of its wall
WALL_DEPTH_MAX :: 2 // m: the hole of a thicker wall goes this deep
CUT_FRONT :: 0.01 // m of the hole in front of the opening

@(component,description="The frame of an opening in its wall: boxes that line the hole the opening makes, from the face of the wall to its back.")
Portal_Frame :: struct {
    rims:[4]core.Entity,
    face:f32 `mirai:"unit=m"`,  // from the opening to the face of the wall behind it
    depth:f32 `mirai:"unit=m"`, // from the opening to the back of the wall; zero: no wall behind it
    key:u64, // of the opening and the wall the frame was made for
}

@(component,description="A box that lines the hole an opening makes in its wall.")
Portal_Rim :: struct {
    portal:core.Entity,
}

// A box in the space of an opening, in metres: x and y along its sides, z out of its front.
Rim_Box :: struct {center,half:[3]f32}

// The four boxes that line the hole of an opening of `size`, from `face` to `depth` behind it.
rim_boxes :: proc "contextless" (size:[2]f32,face,depth:f32) -> (boxes:[4]Rim_Box) {
    w,h:=0.5*abs(size.x),0.5*abs(size.y)
    z,hz:=-0.5*(face+depth),0.5*(depth-face)
    boxes[0]={{-(w+0.5*RIM_WIDTH),0,z},{0.5*RIM_WIDTH,h+RIM_WIDTH,hz}}
    boxes[1]={{w+0.5*RIM_WIDTH,0,z},{0.5*RIM_WIDTH,h+RIM_WIDTH,hz}}
    boxes[2]={{0,-(h+0.5*RIM_WIDTH),z},{w,0.5*RIM_WIDTH,hz}}
    boxes[3]={{0,h+0.5*RIM_WIDTH,z},{w,0.5*RIM_WIDTH,hz}}
    return
}

// A box of the space of an opening, in the world.
@(private)
opening_box :: proc "contextless" (portal:mm.Transform,box:Rim_Box) -> phys.Cut_Box {
    return {portal.position+mm.quat_rotate(portal.rotation,box.center),portal.rotation,box.half}
}

// Where the wall of an opening is not: the opening and its frame, from a little in front of it to
// the back of the wall.
hole_box :: proc "contextless" (portal:mm.Transform,depth:f32) -> phys.Cut_Box {
    back:=depth+CUT_FRONT
    half:=[3]f32{0.5*abs(portal.scale.x)+RIM_WIDTH,0.5*abs(portal.scale.y)+RIM_WIDTH,0.5*(CUT_FRONT+back)}
    return opening_box(portal,{{0,0,0.5*(CUT_FRONT-back)},half})
}

// Where the part of a traveler of `radius` that went into an opening is not on this side: behind
// the back of its wall, or behind the opening when it stands free.
passage_box :: proc "contextless" (portal:mm.Transform,depth,radius:f32) -> phys.Cut_Box {
    length:=2*radius+RIM_WIDTH
    half:=[3]f32{0.5*abs(portal.scale.x)+radius,0.5*abs(portal.scale.y)+radius,0.5*length}
    return opening_box(portal,{{0,0,-(depth+0.5*length)},half})
}

// How far in front of an opening a sphere is, when it reaches across the plane of the opening within
// its square.
reaches_into :: proc "contextless" (portal:mm.Transform,center:[3]f32,radius:f32) -> (distance:f32,ok:bool) {
    local:=mm.quat_rotate(conj(portal.rotation),center-portal.position)
    if abs(local.z)>=radius {return}
    if abs(local.x)>0.5*abs(portal.scale.x)+radius || abs(local.y)>0.5*abs(portal.scale.y)+radius {return}
    return local.z,true
}

// An opening as the physics sees it: where it is, where it leads and how deep its wall is.
Opening :: struct {
    entity:core.Entity,
    entrance,exit:mm.Transform,
    depth:f32,
}

// The twin and the cut of a traveler whose body is within the sphere of `center` and `radius`: those
// of the opening it reaches into, the nearest to its plane.
traveler_twin :: proc "contextless" (openings:[]Opening,center:[3]f32,radius:f32) -> (twin:phys.Body_Twin,cut:phys.Cut_Box,ok:bool) {
    nearest:=max(f32)
    for opening in openings {
        distance,reaches:=reaches_into(opening.entrance,center,radius)
        if !reaches || abs(distance)>=nearest {continue}
        nearest=abs(distance)
        through:=through_of(opening.entrance,opening.exit)
        twin={through,opening.exit.position,mm.quat_rotate(opening.exit.rotation,[3]f32{0,0,1})}
        cut=passage_box(opening.entrance,opening.depth,radius)
        ok=true
    }
    return
}

@(private)
frame_key :: proc(portal,wall:mm.Transform,collider:phys.Collider) -> u64 {
    // What the frame is made from, without the padding of the collider.
    Made :: struct {
        portal,wall:mm.Transform,
        size,center:[3]f32,
        convex_radius,friction,restitution:f32,
        kind,preset,sensor:u32,
        belongs,collides:phys.Collision_Layers,
    }
    made:=Made{
        portal,wall,collider.size,collider.center,collider.convex_radius,collider.friction,collider.restitution,
        u32(collider.kind),u32(collider.preset),u32(collider.sensor),collider.belongs,collider.collides,
    }
    return base.hash64(([^]u8)(&made)[:size_of(made)])
}

// Where the face and the back of a wall are behind an opening, measured by rays against its collider
// alone. False when the wall is not behind the middle of the opening.
@(private)
wall_measure :: proc(physics:core.Ref(phys.Physics_State),wall:core.Entity,portal:mm.Transform) -> (face,depth:f32,ok:bool) {
    normal:=mm.quat_rotate(portal.rotation,[3]f32{0,0,1})
    front:=phys.collider_raycast(physics,wall,portal.position+normal*WALL_REACH,-normal,2*WALL_REACH) or_return
    face=clamp(front.distance-WALL_REACH,0,WALL_REACH)
    thickness:f32=RIM_DEPTH_MIN
    if back,found:=phys.collider_raycast(physics,wall,portal.position-normal*(face+WALL_DEPTH_MAX),normal,WALL_DEPTH_MAX);found {
        thickness=max(WALL_DEPTH_MAX-back.distance,RIM_DEPTH_MIN)
    }
    return face,face+thickness,true
}

// The walls of the portals that lead somewhere, not mirrors, get their hole and their
// frame, made again only when an opening or its wall moves; those of the
// portals that do not lose them. Each traveler halfway into an opening gets
// its twin and its cut, and loses them when it is through.
@(step="fixed",loops="game",stage="input")
portals_collision :: proc(
    commands:core.Commands,portals:core.Read(Portal),travelers:core.Read(Traveler),worlds:core.Read(core.World_Transform),
    crossings:core.Ref(Portal_Crossings),physics:core.Ref(phys.Physics_State),colliders:^core.Table(phys.Collider),
    frames:^core.Table(Portal_Frame),cuts:^core.Table(phys.Collider_Cuts),twins:^core.Table(phys.Body_Twin),
) {
    es:=commands.entities
    openings:[PORTAL_CAPACITY]Opening
    opening_count:=0
    Wall :: struct {entity:core.Entity,cuts:phys.Collider_Cuts}
    walls:[PORTAL_CAPACITY]Wall
    wall_count:=0
    for row in 0..<core.count(portals) {
        e:=core.entity_at(portals,row)
        portal:=core.at(portals,row)
        placed,has_place:=core.get(worlds,e)
        exit,has_exit:=core.get(worlds,portal.exit)
        if !has_place || !has_exit || portal.mirror || opening_count==len(openings) {continue}
        opening:=Opening{entity=e,entrance=placed.transform,exit=exit.transform}
        wall,has_wall:=core.get(worlds,portal.wall)
        held,framed:=core.get(frames,e)
        frame:=held // the one the portal has when this ends
        if portal.wall!=core.NONE && has_wall && phys.collider_ready(physics,portal.wall) {
            collider,_:=core.get(colliders,portal.wall)
            key:=frame_key(placed.transform,wall.transform,collider)
            if !framed || frame.key!=key {
                made:=Portal_Frame{key=key}
                if face,depth,measured:=wall_measure(physics,portal.wall,placed.transform);measured {
                    made.face,made.depth=face,depth
                    made.rims=rims_make(commands,colliders,e,placed.transform,collider,face,depth)
                }
                for rim in frame.rims {
                    if rim!=core.NONE {core.destroy(es,rim)}
                }
                core.add(frames,e,made)
                frame=made
            }
            opening.depth=frame.depth
            if frame.depth>0 {
                at:=0
                for at<wall_count && walls[at].entity!=portal.wall {at+=1}
                if at==wall_count {
                    walls[at]={entity=portal.wall}
                    wall_count+=1
                }
                if count:=&walls[at].cuts.count;count^<phys.COLLIDER_CUT_CAPACITY {
                    walls[at].cuts.boxes[count^]=hole_box(placed.transform,frame.depth)
                    count^+=1
                }
            }
        } else if framed && portal.wall!=core.NONE {
            opening.depth=frame.depth
        }
        openings[opening_count]=opening
        opening_count+=1
    }
    // A portal that leads nowhere, is a mirror or is gone takes its frame away.
    for row:=core.count(frames)-1;row>=0;row-=1 {
        e:=core.entity_at(frames,row)
        portal,is_portal:=core.get(portals,e)
        if is_portal && core.has(worlds,e) && core.has(worlds,portal.exit) && !portal.mirror && portal.wall!=core.NONE {continue}
        frame_drop(es,frames,e,core.at(frames,row))
    }
    for wall in walls[:wall_count] {cuts_put(cuts,wall.entity,wall.cuts)}
    for row in 0..<core.count(travelers) {
        e:=core.entity_at(travelers,row)
        bounds,has_body:=phys.body_bounds(physics,e)
        twin:phys.Body_Twin
        cut:phys.Cut_Box
        near:=false
        if has_body {
            center:=0.5*(bounds.min+bounds.max)
            radius:=0.5*linalg.length(bounds.max-bounds.min)
            // What the portal carries in this tick is already where it lands.
            for crossing in crossings.queue.items {
                if crossing.who!=e {continue}
                for opening in openings[:opening_count] {
                    if opening.entity==crossing.portal {center=mm.transform_point(through_of(opening.entrance,opening.exit),center)}
                }
            }
            twin,cut,near=traveler_twin(openings[:opening_count],center,radius)
        }
        if !near {
            if core.has(twins,e) {core.remove(twins,e)}
            if core.has(cuts,e) {core.remove(cuts,e)}
            continue
        }
        if had,has:=core.get(twins,e);!has || had!=twin {core.add(twins,e,twin)}
        mine:=phys.Collider_Cuts{count=1}
        mine.boxes[0]=cut
        cuts_put(cuts,e,mine)
    }
    // What is neither a cut wall nor a traveler halfway in keeps no cut.
    for row:=core.count(cuts)-1;row>=0;row-=1 {
        e:=core.entity_at(cuts,row)
        kept:=core.has(travelers,e) && core.has(twins,e)
        for wall in walls[:wall_count] {kept||=wall.entity==e}
        if !kept {core.remove(cuts,e)}
    }
    for row:=core.count(twins)-1;row>=0;row-=1 {
        if e:=core.entity_at(twins,row);!core.has(travelers,e) {core.remove(twins,e)}
    }
}

@(private)
cuts_put :: proc(cuts:^core.Table(phys.Collider_Cuts),e:core.Entity,value:phys.Collider_Cuts) {
    if had,has:=core.get(cuts,e);has && had==value {return}
    core.add(cuts,e,value)
}

@(private)
frame_drop :: proc(es:^core.Entities,frames:^core.Table(Portal_Frame),e:core.Entity,frame:Portal_Frame) {
    for rim in frame.rims {
        if rim!=core.NONE {core.destroy(es,rim)}
    }
    core.remove(frames,e)
}

// The boxes that line the hole of an opening, children of it, with the surface and the collision of
// its wall.
@(private)
rims_make :: proc(commands:core.Commands,colliders:^core.Table(phys.Collider),portal:core.Entity,placed:mm.Transform,wall:phys.Collider,face,depth:f32) -> (rims:[4]core.Entity) {
    scale:=[3]f32{abs(placed.scale.x),abs(placed.scale.y),abs(placed.scale.z)}
    if scale.x<1e-6 || scale.y<1e-6 || scale.z<1e-6 {return}
    for box,i in rim_boxes(placed.scale.xy,face,depth) {
        rim:=core.create(commands.entities)
        lining:=wall
        lining.kind,lining.convex_radius=.Box,0
        lining.center,lining.size=box.center/scale,box.half/scale
        name:core.Name
        base.text_set(name.text[:],"Portal rim")
        core.commands_add(commands,rim,core.Transform{rotation=1,scale={1,1,1}})
        core.commands_add(commands,rim,core.Parent{entity=portal})
        core.commands_add(commands,rim,name)
        core.add(colliders,rim,lining)
        core.commands_add(commands,rim,Portal_Rim{portal})
        rims[i]=rim
    }
    return
}
