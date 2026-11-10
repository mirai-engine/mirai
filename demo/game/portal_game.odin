package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"
import portals "plugins:portals/runtime"

// The portal chamber of portals/portal_chamber.scene. The player carries a gun
// that opens two portals, a blue and an orange one, on the white surfaces
// (Portal_Surface); what goes into one comes out of the other, the player
// included, and a cube halfway through shows on both sides. The actions of
// ../input.mirai:
//   portal_blue    left button, left trigger   opens the blue portal; with a cube in hand, throws it
//   portal_orange  right button, left shoulder opens the orange portal
//   grab           E, West                     picks up the cube in front, or puts it down
// A grill (Grill) takes the portals of who walks through it and sends a cube
// that goes through it back to where it started, also a thrown one: the
// cubes are bullets, whose sweep meets thin triggers. A button in the floor
// (Floor_Button) opens its door while a cube or the player stands on it.
// The scene and the prefab of the player are written by tools/demo_content.

PORTAL_SIZE :: [2]f32{1.3,2.2} // m, of the opening
PORTAL_LIFT :: f32(0.02)        // m the opening stands off its wall
PORTAL_RANGE :: f32(120)        // m a shot reaches
HOLD_DISTANCE :: f32(1.7)       // m from the eyes a carried cube is held
HOLD_REACH :: f32(2.6)          // m: the farthest cube the gun picks up, and the farthest a carried one can lag
HOLD_RATE :: f32(14)            // 1/s: the share of the gap to its place a carried cube closes each second
HOLD_SPEED :: f32(20)           // m/s, the fastest a carried cube is moved
THROW_CUBE_SPEED :: f32(9)      // m/s
FALL_LIMIT :: f32(-30)          // m: a cube below this height goes back to where it started

Portal_Color :: enum u8 {Blue,Orange}
PORTAL_GLOW :: [Portal_Color][3]f32{.Blue={0.1,0.4,1},.Orange={1,0.3,0.02}}

@(component,description="The portal gun of the player: it opens the two portals and carries a cube.")
Portal_Gun :: struct {
    held:core.Entity `mirai:"transient"`, // the cube it carries
    shots:u32,
}

@(component,description="One of the two portals of the gun: the entity it moves, its opening and the film that shows while the other one is not placed.")
Portal_Mouth :: struct {
    color:Portal_Color,
    opening:core.Entity, // a child with the Portal, as large as PORTAL_SIZE
    film:core.Entity,    // a child that shows the color of the portal while it leads nowhere
    wall:core.Entity,    // the surface it is on
    placed:bool,
}

@(component,description="A surface the portal gun opens portals on. It has to be a box collider.")
Portal_Surface :: struct {}

@(component,description="A cube of the chamber. It goes back to where it started when it passes a grill or falls out of the chamber.")
Portal_Cube :: struct {
    home:[3]f32 `mirai:"transient"`,
    homed:bool `mirai:"transient"`,
}

@(component,description="A grill of light: who walks through it loses the portals, and a cube that goes through it goes back to where it started.")
Grill :: struct {}

@(component,description="A button in the floor: its door is open while a cube or the player is in the box of its collider.")
Floor_Button :: struct {
    door:core.Entity,
    plate:core.Entity, // glows while pressed
    pressed:bool `mirai:"transient"`,
}

// The first portal that leads somewhere the way from `from` to `to` goes into, after which share of the
// way, and what it carries by.
portal_way :: proc(openings:core.Read(portals.Portal),worlds:core.Read(core.World_Transform),from,to:[3]f32) -> (through:mm.Transform,share:f32,ok:bool) {
    share=2
    for row in 0..<core.count(openings) {
        portal:=core.at(openings,row)
        entrance,placed:=core.get(worlds,core.entity_at(openings,row))
        exit,has_exit:=core.get(worlds,portal.exit)
        if !placed || !has_exit {continue}
        if at,crossed:=portals.crosses(entrance.transform,portal.ellipse,from,to);crossed && at<share {
            share,through,ok=at,portals.through_of(entrance.transform,exit.transform),true
        }
    }
    return
}

// A ray of the gun: it goes through a portal that leads somewhere, once, and on from its exit.
portal_ray :: proc(physics:core.Ref(phys.Physics_State),openings:core.Read(portals.Portal),worlds:core.Read(core.World_Transform),origin,direction:[3]f32,ignore:core.Entity) -> (hit:phys.Hit,ok:bool) {
    from,ahead:=origin,linalg.normalize(direction)
    for bounce in 0..<2 {
        hit,ok=phys.raycast(physics,from,ahead,PORTAL_RANGE,ignore)
        end:=ok?hit.point:from+ahead*PORTAL_RANGE
        through,share,crossed:=portal_way(openings,worlds,from,end)
        if !crossed || bounce==1 {return}
        from=mm.transform_point(through,from+(end-from)*share)
        ahead=mm.quat_rotate(through.rotation,ahead)
    }
    return
}

// Where a carried cube goes and how it turns: in front of the eyes, upright to the look. When the look
// goes into a portal and the cube is on its other side, the place is the one the portal carries it to,
// and so are its turn and the way it is thrown; a place short of the opening is then behind the exit,
// and the cube comes back through it.
hold_place :: proc(openings:core.Read(portals.Portal),worlds:core.Read(core.World_Transform),eye,aim:[3]f32,yaw:f32,cube:[3]f32) -> (place:[3]f32,turn:mm.Quat,carry:mm.Quat) {
    place,turn,carry=eye+aim*HOLD_DISTANCE,mm.quat_axis_angle({0,1,0},yaw),1
    if through,_,crossed:=portal_way(openings,worlds,eye,eye+aim*(HOLD_DISTANCE+1));crossed {
        beyond:=mm.transform_point(through,place)
        if linalg.length2(cube-beyond)<linalg.length2(cube-place) {place,turn,carry=beyond,through.rotation*turn,through.rotation}
    }
    return
}

Surface_Box :: struct {min,max:[3]f32}

// The box of a surface in its own space, without its scale: what its collider is.
@(private="file")
surface_box :: proc(colliders:core.Read(phys.Collider),wall:core.Entity) -> (box:Surface_Box,ok:bool) {
    collider,has:=core.get(colliders,wall)
    if !has || collider.kind!=.Box {return}
    return {collider.center-collider.size,collider.center+collider.size},true
}

// How far an opening of `rotation` reaches along each axis of a wall turned by `wall`.
@(private="file")
opening_reach :: proc "contextless" (wall,rotation:mm.Quat) -> [3]f32 {
    inverse:=conj(wall)
    x,y:=mm.quat_rotate(inverse,mm.quat_rotate(rotation,[3]f32{1,0,0})),mm.quat_rotate(inverse,mm.quat_rotate(rotation,[3]f32{0,1,0}))
    return {abs(x.x),abs(x.y),abs(x.z)}*PORTAL_SIZE.x*0.5+[3]f32{abs(y.x),abs(y.y),abs(y.z)}*PORTAL_SIZE.y*0.5
}

// Where an opening goes on the face of a wall a shot hit: its up along the axis of the wall nearest to
// `up`, so that the hole it cuts follows the box, and moved to fit the face and to keep off the other
// portal. False when the face is too small for it.
portal_fit :: proc(wall:mm.Transform,box:Surface_Box,point,normal,up:[3]f32,other:Maybe(mm.Transform)) -> (placed:mm.Transform,ok:bool) {
    inverse:=conj(wall.rotation)
    local_normal:=mm.quat_rotate(inverse,normal)
    k:=0
    for i in 1..<3 {if abs(local_normal[i])>abs(local_normal[k]) {k=i}}
    sign:=local_normal[k]>=0?f32(1):f32(-1)
    axes:=[3][3]f32{mm.quat_rotate(wall.rotation,[3]f32{1,0,0}),mm.quat_rotate(wall.rotation,[3]f32{0,1,0}),mm.quat_rotate(wall.rotation,[3]f32{0,0,1})}
    face:=axes[k]*sign
    best:=f32(-2)
    chosen:[3]f32
    for i in 0..<3 {
        if i==k {continue}
        for s in ([2]f32{1,-1}) {
            if d:=linalg.dot(axes[i]*s,up);d>best {best,chosen=d,axes[i]*s}
        }
    }
    placed.rotation=mm.quat_look(-face,chosen)
    placed.scale={1,1,1}
    scale:=[3]f32{abs(wall.scale.x),abs(wall.scale.y),abs(wall.scale.z)}
    low,high:=box.min*scale,box.max*scale
    local:=mm.quat_rotate(inverse,point-wall.position)
    reach:=opening_reach(wall.rotation,placed.rotation)
    fit :: proc "contextless" (local:^[3]f32,low,high,reach:[3]f32,k:int) -> bool {
        for i in 0..<3 {
            if i==k {continue}
            if low[i]+reach[i]>high[i]-reach[i] {return false}
            local[i]=clamp(local[i],low[i]+reach[i],high[i]-reach[i])
        }
        return true
    }
    fit(&local,low,high,reach,k) or_return
    overlaps :: proc "contextless" (a,b,ra,rb:[3]f32,k:int) -> bool {
        for i in 0..<3 {
            if i!=k && abs(a[i]-b[i])>=ra[i]+rb[i]-1e-3 {return false}
        }
        return true
    }
    // The other portal on the same face pushes this one off along the axis that needs the least.
    if beside,has:=other.?;has {
        there:=mm.quat_rotate(inverse,beside.position-wall.position)
        other_reach:=opening_reach(wall.rotation,beside.rotation)
        if abs(there[k]-(sign>0?high[k]:low[k]))<0.1 && overlaps(local,there,reach,other_reach,k) {
            push,axis:=max(f32),-1
            for i in 0..<3 {
                if i==k {continue}
                if gap:=reach[i]+other_reach[i]-abs(local[i]-there[i]);gap<push {push,axis=gap,i}
            }
            local[axis]+=(local[axis]>=there[axis]?f32(1):f32(-1))*(push+0.01)
            fit(&local,low,high,reach,k) or_return
            if overlaps(local,there,reach,other_reach,k) {return}
        }
    }
    local[k]=(sign>0?high[k]:low[k])+sign*PORTAL_LIFT
    placed.position=wall.position+mm.quat_rotate(wall.rotation,local)
    return placed,true
}

// The shots, the carried cube and the throws of whoever has a portal gun.
@(step="fixed")
portal_gun :: proc(
    guns:^core.Table(Portal_Gun),mouths:^core.Table(Portal_Mouth),surfaces:core.Read(Portal_Surface),cubes:core.Read(Portal_Cube),
    rims:core.Read(portals.Portal_Rim),openings:core.Read(portals.Portal),
    colliders:core.Read(phys.Collider),inputs:core.Read(inp.Move_Input),drivables:core.Read(inp.Drivable),actions:inp.Input_Of(Action),worlds:core.Read(core.World_Transform),
    transforms:^core.Table(core.Transform),physics:core.Ref(phys.Physics_State),bodies:^phys.Body_Requests,
    characters:core.Read(core.Motion),passes:^Grill_Passes,
) {
    // A player that went through a grill loses the portals and what it carries; a cube that did is let go.
    for passed in passes.queue.items {
        for row in 0..<core.count(guns) {
            if core.entity_at(guns,row)!=passed && guns.values[row].held!=passed {continue}
            core.at(guns,row).held=core.NONE
            if core.entity_at(guns,row)!=passed {continue}
            for at in 0..<core.count(mouths) {
                if mouths.values[at].placed {core.at(mouths,at).placed=false}
            }
        }
    }
    core.queue_clear(&passes.queue)
    for row in 0..<core.count(guns) {
        player:=core.entity_at(guns,row)
        gun:=core.at(core.read(guns),row)
        eye,aim,ok:=inp.aim(drivables,worlds,player)
        if !ok {continue}
        blue:=inp.pressed(actions,player,.Portal_Blue)
        orange:=inp.pressed(actions,player,.Portal_Orange)
        grab:=inp.pressed(actions,player,.Grab)
        held:=gun.held
        if held!=core.NONE {
            cube,placed:=core.get(worlds,held)
            input,_:=core.get(inputs,player)
            target,facing,carry:=hold_place(openings,worlds,eye,aim,input.look_yaw,cube.position)
            dropped:=!placed || linalg.distance(cube.position,target)>HOLD_REACH || grab
            // Standing on what it carries would lift the player with it.
            feet,_:=core.get(worlds,player)
            if under,found:=phys.raycast(physics,feet.position+[3]f32{0,0.2,0},{0,-1,0},0.5,player);found && under.entity==held {dropped=true}
            if blue {
                walking,_:=core.get(characters,player)
                phys.set_velocity(bodies,held,mm.quat_rotate(carry,aim*THROW_CUBE_SPEED+walking.linear))
                core.at(guns,row).held=core.NONE
                continue
            }
            if dropped {
                core.at(guns,row).held=core.NONE
                continue
            }
            gap:=target-cube.position
            velocity:=gap*HOLD_RATE
            if speed:=linalg.length(velocity);speed>HOLD_SPEED {velocity*=HOLD_SPEED/speed}
            // It turns to face the way the player looks, upright, or as the portal turns that.
            turn:=facing*conj(cube.rotation)
            if turn.w<0 {turn=-turn}
            spin:=[3]f32{turn.x,turn.y,turn.z}
            angle:=2*math.atan2(linalg.length(spin),turn.w)
            angular:=linalg.length(spin)>1e-6?linalg.normalize(spin)*angle*8:[3]f32{}
            phys.set_velocity(bodies,held,velocity,angular)
            continue
        }
        if grab {
            if hit,found:=phys.raycast(physics,eye,aim,HOLD_REACH,player);found && core.has(cubes,hit.entity) {core.at(guns,row).held=hit.entity}
            continue
        }
        if !blue && !orange {continue}
        color:=blue?Portal_Color.Blue:Portal_Color.Orange
        core.at(guns,row).shots+=1
        hit,found:=portal_ray(physics,openings,worlds,eye,aim,player)
        if !found {continue}
        wall:=hit.collider
        if rim,lines:=core.get(rims,wall);lines {
            if opening,has:=core.get(openings,rim.portal);has {wall=opening.wall}
        }
        wall_world,has_wall:=core.get(worlds,wall)
        box,boxed:=surface_box(colliders,wall)
        if !core.has(surfaces,wall) || !has_wall || !boxed {continue}
        up:=[3]f32{0,1,0}
        if abs(hit.normal.y)>0.7 {
            up={aim.x,0,aim.z}
            if hit.normal.y<0 {up=-up}
        }
        mine,other:=core.Entity(core.NONE),Maybe(mm.Transform)(nil)
        for at in 0..<core.count(mouths) {
            mouth:=core.at(core.read(mouths),at)
            if mouth.color==color {mine=core.entity_at(mouths,at);continue}
            if !mouth.placed {continue}
            if portal,has:=core.get(openings,mouth.opening);has && portal.wall==wall {
                if there,seen:=core.get(worlds,core.entity_at(mouths,at));seen {other=there.transform}
            }
        }
        if mine==core.NONE {continue}
        placed,fits:=portal_fit(wall_world.transform,box,hit.point,hit.normal,up,other)
        if !fits {continue}
        local:=core.get(transforms,mine)
        if local==nil {continue}
        local.position,local.rotation=placed.position,placed.rotation
        mouth:=core.get(mouths,mine)
        mouth.placed,mouth.wall=true,wall
    }
}

// Who went through a grill in the last tick: the gun of a player loses its portals, a cube goes home.
@(storage,queue)
Grill_Passes :: struct {queue:core.Queue(core.Entity)}

// Each opening leads to the other once both are placed, cut into the wall it is on; the film of a mouth
// shows while it leads nowhere, and a mouth not placed is not drawn.
@(step="fixed",after="portal_gun")
portal_links :: proc(mouths:core.Read(Portal_Mouth),openings:^core.Table(portals.Portal),shows:^Show_Requests) {
    opening_of :: proc(mouths:core.Read(Portal_Mouth),color:Portal_Color) -> (core.Entity,bool) {
        for row in 0..<core.count(mouths) {
            mouth:=core.at(mouths,row)
            if mouth.color==color {return mouth.opening,mouth.placed}
        }
        return core.NONE,false
    }
    for row in 0..<core.count(mouths) {
        mouth:=core.at(mouths,row)
        other,other_placed:=opening_of(mouths,mouth.color==.Blue?.Orange:.Blue)
        exit:=mouth.placed && other_placed?other:core.NONE
        wall:=mouth.placed?mouth.wall:core.NONE
        if portal,has:=core.get(core.read(openings),mouth.opening);has && (portal.exit!=exit || portal.wall!=wall) {
            written:=core.get(openings,mouth.opening)
            written.exit,written.wall=exit,wall
        }
        ask_hidden(shows,core.entity_at(mouths,row),!mouth.placed)
        ask_hidden(shows,mouth.film,exit!=core.NONE)
    }
}

// What the physics of the tick did in the chamber: cubes and players that went through a grill, the
// buttons that something stands on, and the cubes that fell out.
@(step="fixed",stage="react")
portal_chamber :: proc(
    cubes:^core.Table(Portal_Cube),buttons:^core.Table(Floor_Button),grills:core.Read(Grill),guns:core.Read(Portal_Gun),
    colliders:core.Read(phys.Collider),worlds:core.Read(core.World_Transform),events:core.Ref(phys.Physics_Events),
    physics:core.Ref(phys.Physics_State),passes:^Grill_Passes,placer:core.Placer,
) {
    home :: proc(cubes:^core.Table(Portal_Cube),placer:core.Placer,e:core.Entity) {
        cube,_:=core.get(core.read(cubes),e)
        core.place(placer,e,cube.home,at_rest=true)
    }
    for row in 0..<core.count(cubes) {
        e:=core.entity_at(cubes,row)
        placed,has:=core.get(worlds,e)
        if !has {continue}
        if !cubes.values[row].homed {
            cube:=core.at(cubes,row)
            cube.home,cube.homed=placed.position,true
        } else if placed.position.y<FALL_LIMIT {
            home(cubes,placer,e)
        }
    }
    for event in events.overlap_begin.items {
        if !core.has(grills,event.collider) && !core.has(grills,event.entity) {continue}
        if core.has(cubes,event.other) {
            home(cubes,placer,event.other)
            core.push(&passes.queue,event.other)
        } else if core.has(guns,event.other) {
            core.push(&passes.queue,event.other)
        }
    }
    found:[16]core.Entity
    for row in 0..<core.count(buttons) {
        e:=core.entity_at(buttons,row)
        placed,has_place:=core.get(worlds,e)
        zone,has_zone:=core.get(colliders,e)
        pressed:=false
        if has_place && has_zone {
            filter:=phys.QUERY_FILTER_DEFAULT
            filter.overlaps=true
            count,_:=phys.overlap_box(physics,mm.transform_point(placed.transform,zone.center),zone.size*placed.scale,placed.rotation,found[:],filter)
            for other in found[:min(count,len(found))] {pressed||=core.has(cubes,other) || core.has(guns,other)}
        }
        if buttons.values[row].pressed!=pressed {core.at(buttons,row).pressed=pressed}
    }
}

// A door with buttons is open while one of them is pressed, besides when it was opened by hand.
door_opened :: proc(doors:core.Read(Door),buttons:core.Read(Floor_Button),e:core.Entity) -> bool {
    door,has:=core.get(doors,e)
    if !has {return false}
    if door.open {return true}
    for row in 0..<core.count(buttons) {
        button:=core.at(buttons,row)
        if button.door==e && button.pressed {return true}
    }
    return false
}

// What portal_hud.ui shows of the body with the gun it is on, while a seat
// drives it: the screen is on the body, so it shows in the view of its player.
@(component,description="The HUD of a portal gun: the crosshair with the portals it has open, what its actions do and the caption of what is near.")
Portal_Hud :: struct {
    shown:bool,   // a seat drives this body
    blue,orange:bool, // that portal is open
    holding:bool, // it carries a cube
    aiming:bool,  // it does not: its buttons open portals
    captioned:bool,
    caption:[CAPTION_CAPACITY]u8 `mirai:"text"`,
}

@(step="frame")
portal_hud :: proc(
    huds:^core.Table(Portal_Hud),guns:core.Read(Portal_Gun),mouths:core.Read(Portal_Mouth),exhibits:core.Read(Exhibit),
    drivables:core.Read(inp.Drivable),worlds:core.Read(core.World_Transform),names:core.Read(core.Name),
) {
    shown:=core.read(huds)
    for row in 0..<core.count(shown) {
        body:=core.entity_at(shown,row)
        next:Portal_Hud
        gun,has_gun:=core.get(guns,body)
        if placed,has_world:=core.get(worlds,body);has_world && has_gun && inp.seat_of(drivables,body)!=core.NONE {
            next.shown,next.holding,next.aiming=true,gun.held!=core.NONE,gun.held==core.NONE
            for at in 0..<core.count(mouths) {
                mouth:=core.at(mouths,at)
                if !mouth.placed {continue}
                if mouth.color==.Blue {next.blue=true} else {next.orange=true}
            }
            next.captioned=exhibit_caption(next.caption[:],exhibits,worlds,names,placed.position)
        }
        if core.at(shown,row)!=next {core.at(huds,row)^=next}
    }
}
