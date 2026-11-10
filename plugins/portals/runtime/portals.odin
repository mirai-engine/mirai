package portals

import inp "mirai:engine/input"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

// Portals: an opening that shows another place of the scene and leads to it.
// What is in front of a portal continues behind its exit, turned around, so
// two portals that name each other join two places as a door joins two rooms.
// The other side is drawn as a nested view of each view that sees the
// opening, rays that go into it go on from the exit, and the lights behind it
// reach this side through it (gpu.odin). What has a Traveler goes through.

PORTAL_CAPACITY :: 8

@(component,description="An opening that shows the place of another entity and leads to it. It is the unit square of this entity seen from its +Z; its scale is its size.")
Portal :: struct {
    exit:core.Entity,    // what is in front of this portal continues behind that entity: a portal that leads back, or any entity
    ellipse:bool,        // the opening is the ellipse inside the square
    layers:u32,          // the layers of meshes seen through it; 0: every one
    wall:core.Entity,    // the collider the opening is cut into while it leads somewhere; NONE: it stands free
}

// The entity has to be a body or a character of the physics: it is carried by a request to them.
@(component,description="Goes through the portals its point crosses, with its velocity and what hangs from it.")
Traveler :: struct {
    point:[3]f32 `mirai:"unit=m"`, // in the space of the entity: what has to cross the opening; the eyes of who looks through them
}

Crossing :: struct {
    who,portal:core.Entity,
    turn:mm.Quat, // how the portal turned what went through it
}

// Who goes through a portal in this tick. Whoever keeps a direction of its
// own for a traveler, as where it looks, turns it by `turn`.
@(storage)
Portal_Crossings :: struct {
    queue:core.Events(Crossing),
}

// How near the eye of the view is to the way of the traveler it looks through the eyes of.
RIDE_DISTANCE :: 0.25
// How far from where a portal takes its last eye a view can be and still have been taken there by it: what it moves in a frame.
CARRY_REACH :: 2
// s: the time a view takes to right a turn or a step that a portal gave it beyond what it would see by moving through it, by a factor of e.
RIGHTING_TIME :: 0.12

// Where the last frame was seen from, and what the view still keeps of the
// last crossing that turned or moved it other than the portal carried it. Of
// the host: a world that goes back some ticks does not take what was drawn
// with it.
@(storage,host)
Portal_View :: struct {
    eye:[3]f32,
    rotation:mm.Quat,
    seen:bool,
    righting:mm.Quat, // turns the view as it is drawn; identity when it is upright again
    shift:[3]f32,     // m, moves it
    crossed:u64,      // tick of the last crossing taken
}

PORTAL_VIEW_DEFAULT :: Portal_View{rotation=1,righting=1}

// The rigid transform that carries what is in front of a portal to behind its
// exit, turned around its vertical: who walks in through one walks out of the other.
through_of :: proc "contextless" (entrance,exit:mm.Transform) -> mm.Transform {
    rotation:=linalg.normalize(exit.rotation*mm.quat_axis_angle({0,1,0},math.PI)*conj(entrance.rotation))
    return {exit.position-mm.quat_rotate(rotation,entrance.position),rotation,{1,1,1}}
}

// Whether the way from a to b goes into the opening of a portal from its
// front, and after which share of it.
crosses :: proc "contextless" (portal:mm.Transform,ellipse:bool,a,b:[3]f32) -> (share:f32,ok:bool) {
    inverse:=conj(portal.rotation)
    from,to:=mm.quat_rotate(inverse,a-portal.position),mm.quat_rotate(inverse,b-portal.position)
    if !(from.z>=0 && to.z<0) {return}
    size:=[2]f32{abs(portal.scale.x),abs(portal.scale.y)}
    if size.x<1e-6 || size.y<1e-6 {return}
    share=from.z/(from.z-to.z)
    at:=(from.xy+(to.xy-from.xy)*share)/size
    if ellipse {return share,linalg.dot(at,at)<=0.25}
    return share,abs(at.x)<=0.5 && abs(at.y)<=0.5
}

// The portal the way from a to b goes into first, where it is and what it carries by.
@(private)
portal_crossed :: proc(portals:core.Read(Portal),worlds:core.Read(core.World_Transform),a,b:[3]f32) -> (portal:core.Entity,entrance,through:mm.Transform,found:bool) {
    first:=f32(2)
    openings:=core.join(portals,worlds)
    for e,config,placed in core.each_joined(&openings) {
        exit:=core.get(worlds,config.exit) or_continue
        share,crossed:=crosses(placed.transform,config.ellipse,a,b)
        if !crossed || share>=first {continue}
        portal,entrance,through,first,found=e,placed.transform,through_of(placed.transform,exit.transform),share,true
    }
    return
}

// A traveler whose point went into a portal in the last tick comes out of its
// exit in this one. The crossing is known before the physics of the tick and
// before the game reads its input, so both act on it in the same tick; the
// frames in between are seen through the portal by portals_view. The
// teleport of the physics is a jump: the traveler is drawn as coming from
// behind the exit, and its next way does not start at the entrance. A
// traveler this end drives looks where the portal turned its look, also out
// of a floor.
@(step="fixed",loops="game",stage="input",before="locomotion_seat")
portals_travel :: proc(
    portals:core.Read(Portal),travelers:core.Read(Traveler),worlds:core.Read(core.World_Transform),
    motions:core.Read(core.Motion),characters:core.Read(phys.Character_State),
    colliders:core.Read(phys.Collider),moves:^core.Table(inp.Move_Input),remotes:core.Read(core.Remote),
    placer:core.Placer,requests:^phys.Body_Requests,crossings:^Portal_Crossings,
) {
    if core.count(portals)==0 {return}
    // Only the physics carries an entity: one it does not move stays where it is.
    carried:=core.join(travelers,worlds,motions)
    for e,traveler,world,motion in core.each_joined(&carried) {
        if world.previous==world.transform {continue}
        walking:=core.has(characters,e)
        point:=traveler.point
        portal,_,through,found:=portal_crossed(portals,worlds,mm.transform_point(world.previous,point),mm.transform_point(world.transform,point))
        if !found {continue}
        if !walking {
            core.place(placer,e,mm.transform_point(through,world.position),through.rotation*world.rotation)
            phys.set_velocity(requests,e,mm.quat_rotate(through.rotation,motion.linear),mm.quat_rotate(through.rotation,motion.angular))
        } else {
            config,_:=core.get(portals,portal)
            exit,_:=core.get(worlds,config.exit)
            capsule,_:=core.get(colliders,e)
            look:=mm.quat_forward(world.rotation)
            if move,driven:=core.get(moves,e);driven {look=mm.quat_forward(mm.quat_from_euler({move.look_pitch,move.look_yaw,0}))}
            feet,yaw:=character_through(through,exit.transform,world.transform,point,look,capsule)
            core.place(placer,e,feet,mm.quat_axis_angle({0,1,0},yaw))
            phys.set_velocity(requests,e,mm.quat_rotate(through.rotation,motion.linear))
        }
        if move:=core.edit(moves,e);move!=nil && core.owned(remotes,e) {look_through(move,through.rotation)}
        core.push(&crossings.queue,Crossing{who=e,portal=portal,turn=through.rotation})
    }
}

// The look of a Move_Input turned by a portal. A look the portal turned
// upright faces the way it carries what falls in: out of its exit.
@(private)
look_through :: proc "contextless" (move:^inp.Move_Input,turn:mm.Quat) {
    PITCH_LIMIT :: 89*mm.RAD_PER_DEG
    aim:=mm.quat_rotate(turn,mm.quat_forward(mm.quat_from_euler({move.look_pitch,move.look_yaw,0})))
    facing:=linalg.length2(aim.xz)>0.1?aim:mm.quat_rotate(turn,[3]f32{0,-1,0})
    if linalg.length2(facing.xz)>1e-6 {move.look_yaw=mm.yaw_of_direction(facing)}
    move.look_pitch=clamp(math.asin(clamp(aim.y,-1,1)),-PITCH_LIMIT,PITCH_LIMIT)
}

// Where a character that a portal carries comes out: it stays upright, with
// its point where the portal takes it and turned to where the portal turns
// its look, a yaw (-Z at 0) that its body faces. A portal that turns
// it about another axis than the vertical, as one in the floor to one in a
// wall, puts its capsule wholly in front of the exit and no lower than its
// opening.
character_through :: proc "contextless" (through,exit,placed:mm.Transform,point,look:[3]f32,capsule:phys.Collider) -> (feet:[3]f32,yaw:f32) {
    UP :: [3]f32{0,1,0}
    // A look the portal turns upright faces the way the portal carries what falls into it: out of its exit.
    turned:=mm.quat_rotate(through.rotation,look)
    if linalg.length2(turned.xz)<0.1 {turned=mm.quat_rotate(through.rotation,-UP)}
    if linalg.length2(turned.xz)<0.1 {turned=mm.quat_rotate(through.rotation,mm.quat_forward(placed.rotation))}
    yaw=linalg.length2(turned.xz)>1e-8?mm.yaw_of_direction(turned):0
    upright:=mm.quat_axis_angle(UP,yaw)
    feet=mm.transform_point(through,mm.transform_point(placed,point))-mm.quat_rotate(upright,point*placed.scale)
    if linalg.dot(mm.quat_rotate(through.rotation,UP),UP)>0.999 {return}
    MARGIN :: 0.02
    normal:=mm.quat_rotate(exit.rotation,[3]f32{0,0,1})
    if abs(normal.y)<0.7 {
        bottom:=max(f32)
        for i in 0..<4 {
            corner:=exit.position+mm.quat_rotate(exit.rotation,[3]f32{(i&1!=0?0.5:-0.5)*abs(exit.scale.x),(i&2!=0?0.5:-0.5)*abs(exit.scale.y),0})
            bottom=min(bottom,corner.y)
        }
        feet.y=max(feet.y,bottom+MARGIN)
    }
    scale:=[3]f32{abs(placed.scale.x),abs(placed.scale.y),abs(placed.scale.z)}
    radius,half:=capsule.size.x*max(scale.x,scale.z),capsule.size.y*scale.y
    center:=feet+mm.quat_rotate(upright,capsule.center*scale)
    lowest:=min(linalg.dot(center-UP*half-exit.position,normal),linalg.dot(center+UP*half-exit.position,normal))-radius
    if lowest<MARGIN {feet+=normal*(MARGIN-lowest)}
    return
}

// How far p is from the way from a to b, squared.
@(private)
way_distance2 :: proc "contextless" (p,a,b:[3]f32) -> f32 {
    along:=b-a
    length2:=linalg.length2(along)
    share:=length2>1e-12?clamp(linalg.dot(p-a,along)/length2,0,1):0
    return linalg.length2(p-(a+along*share))
}

// The view of a traveler that already went into a portal, in the frames
// before the tick that carries it, is seen from where it will be; and a view
// that a portal took to its other side says how: through its opening, which
// keeps the history of its image, or around it, which starts it again.
// A traveler that comes out upright where the portal would have turned it
// (out of a floor into a wall), or a step away from where it would have put
// it, is seen first where the portal took the last frame, and the view rights
// itself from there in RIGHTING_TIME.
@(step="late",loops="game",stage="end",after="camera_view")
portals_view :: proc(
    portals:core.Read(Portal),travelers:core.Read(Traveler),worlds:core.Read(core.World_Transform),
    crossings:core.Ref(Portal_Crossings),last:^Portal_View,view:^core.View,time:core.Time,frame:core.Frame_Time,
) {
    view.carried={}
    if last.righting==0 {last.righting=1}
    if core.count(portals)==0 {
        last.eye,last.rotation,last.seen,last.righting,last.shift=view.position,view.rotation,true,1,{}
        return
    }
    placed:=core.join(travelers,worlds)
    for _,traveler,world in core.each_joined(&placed) {
        if world.previous==world.transform {continue}
        point:=traveler.point
        a,b:=mm.transform_point(world.previous,point),mm.transform_point(world.transform,point)
        // The view looks through the eyes of the traveler whose way it is on.
        if way_distance2(view.position,a,b)>RIDE_DISTANCE*RIDE_DISTANCE {continue}
        _,entrance,through,found:=portal_crossed(portals,worlds,a,b)
        // Its eye is behind the opening already: it sees what it will see from there.
        if !found || mm.quat_rotate(conj(entrance.rotation),view.position-entrance.position).z>=0 {continue}
        view.position=mm.transform_point(through,view.position)
        view.rotation=linalg.normalize(through.rotation*view.rotation)
        break
    }
    keep:=math.exp(-max(frame.dt,0)/RIGHTING_TIME)
    last.righting=linalg.normalize(mm.quat_nlerp(1,last.righting,keep))
    last.shift*=keep
    carried:=false
    if last.seen && time.tick!=last.crossed {
        for crossing in crossings.queue.items {
            world,placed:=core.get(worlds,crossing.who)
            traveler,travels:=core.get(travelers,crossing.who)
            config,is_portal:=core.get(portals,crossing.portal)
            entrance,opened:=core.get(worlds,crossing.portal)
            exit,has_exit:=core.get(worlds,config.exit)
            if !placed || !travels || !is_portal || !opened || !has_exit {continue}
            // The view looks through the eyes of the traveler that came out.
            if linalg.length2(view.position-mm.transform_point(world.transform,traveler.point))>1 {continue}
            expected_position,expected_rotation:=last.eye,last.rotation
            // The last frame was still in front of the entrance: the portal carries it, and its history.
            through:=through_of(entrance.transform,exit.transform)
            if linalg.length2(view.position-mm.transform_point(through,last.eye))<linalg.length2(view.position-last.eye) {
                expected_position,expected_rotation=mm.transform_point(through,last.eye),through.rotation*last.rotation
                view.carried=mm.transform_matrix(through)
                carried=true
            }
            last.righting=linalg.normalize(expected_rotation*conj(view.rotation))
            if last.righting.w<0 {last.righting=-last.righting}
            last.shift=expected_position-view.position
            last.crossed=time.tick
            break
        }
    }
    view.rotation=linalg.normalize(last.righting*view.rotation)
    view.position+=last.shift
    if last.seen && !carried {
        stayed:=linalg.length2(view.position-last.eye)
        for row in 0..<core.count(portals) {
            config:=core.at(portals,row)
            entrance,placed:=core.get(worlds,core.entity_at(portals,row))
            exit,has_exit:=core.get(worlds,config.exit)
            if !placed || !has_exit {continue}
            // The view is where the portal takes its last eye, and not near that eye.
            through:=through_of(entrance.transform,exit.transform)
            taken:=linalg.length2(view.position-mm.transform_point(through,last.eye))
            if taken>=stayed || taken>=CARRY_REACH*CARRY_REACH {continue}
            before:=mm.quat_rotate(conj(through.rotation),view.position-through.position)
            if _,passed:=crosses(entrance.transform,config.ellipse,last.eye,before);passed {
                view.carried=mm.transform_matrix(through)
            } else {
                view.cut=true
            }
            break
        }
    }
    last.eye,last.rotation,last.seen=view.position,view.rotation,true
}
