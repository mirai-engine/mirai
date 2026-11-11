package editor

import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:std/base"
import mm "mirai:std/math"

// A drive of play.step: its ticks steer the focused player to a target by the
// move action of the game, re-aimed every tick toward where the target is
// now, or toward the next point of the way a plugin gives (Route_Provider: the
// navigation). It takes off at the edge of a gap and when it stalls, and holds
// the jump as long as it still rises or until it is over the far side; then
// tries each side. It stops within a distance across the ground, or standing
// on a target that is out of reach or a solid raised over its feet, with the
// conditions of the step, at its ticks, or when it stops getting closer. A
// platform that moves is not predicted: wait for it with a step with until,
// then drive onto it.
//
// Its lengths are told for BODY_PERSON and scaled by the body it steers, where
// the plugin that moves it says its measures (Body_Provider): its height for
// what is of its size, its speed for what it covers, its jump and its step for
// what it gets over.
//
// A drive stalls when it gets no closer to its target for a while. That is not
// the stuck of the monitors of the playtest plugin, a body that asks to move
// and stays in place: one that slides along a wall or circles what it cannot
// reach moves, and gets no closer.

API_DRIVE_DEFAULT_SECONDS :: 30
API_DRIVE_WITHIN :: f32(1)         // m across the ground
API_DRIVE_ACTIONS :: 64
// By its height:
@(private) DRIVE_REACH_HEIGHT :: f32(2)     // m above or below its feet a target is at hand; past it only standing on it arrives
@(private) DRIVE_RAISED :: f32(0.5)         // m over its feet the bottom of a solid target is off the floor
@(private) DRIVE_ON_SLACK :: f32(0.5)       // m between its feet and a surface it stands on
@(private) DRIVE_GAP_EDGE :: f32(0.35)      // m ahead a gap is looked for, at the least: it takes off at the edge
@(private) DRIVE_GAP_FROM :: f32(1)         // m above its feet the rays start
@(private) DRIVE_GAP_DEPTH :: f32(3)        // m down: nothing deeper is ground to it
@(private) DRIVE_CLEAR :: f32(0.3)          // m its feet must be above what it lands on to let go of the jump
// By its step:
@(private) DRIVE_GAP_STEP :: f32(0.6)       // m under its feet ground is a gap to jump over, not a step
// By its jump:
@(private) DRIVE_FALL :: f32(1.5)           // m under its feet a target is walked off to, not jumped over
// By its speed:
@(private) DRIVE_PROGRESS :: f32(0.05)      // m closer to the target that count as getting closer
@(private) DRIVE_TAKEOFF :: f32(0.8)        // m from the edge of a raised target it first takes off
@(private) DRIVE_TAKEOFF_GROW :: f32(0.8)   // m farther after each jump that did not land on it
@(private) DRIVE_RUN_UP :: f32(1.5)         // m it goes back past where it takes off, for speed
// Whatever its body:
@(private) DRIVE_WARM_TICKS :: 60           // for the seat and its body to appear
@(private) DRIVE_STALL_TICKS :: 20          // without getting closer it stalled: another way
@(private) DRIVE_DETOUR_TICKS :: 40         // a stalled round walks to a side this long
@(private) DRIVE_GIVE_UP :: 6               // stalled rounds in a row before it stops
@(private) DRIVE_JUMP_SECONDS :: f32(0.2)   // a jump is held at least this long: a tap would cut it
@(private) DRIVE_GAP_TICKS :: f32(4)        // ticks of its speed ahead it also looks: what it covers before the jump leaves the ground
@(private) DRIVE_GAP_EVERY :: 3             // ticks between looks for a gap over meshes
@(private) DRIVE_TURN :: f32(0.02)          // of the move it asks: a smaller change is not asked again
@(private) DRIVE_NO_MESH_SIZE :: f32(1)     // m from its origin a solid target without meshes is taken to reach
@(private) DRIVE_ROUTE_EVERY :: 5           // ticks between two searches of its way
@(private) DRIVE_ROUTE_CORNER :: f32(0.5)   // m to the next point of the way: it asks for the following one
@(private) DRIVE_ROUTE_WAIT :: 180          // ticks it waits for the way before going straight

Api_Drive_Stop :: enum u8 {Arrived,Until,Ticks,Stuck,No_Body,Target_Gone,Run_Ended}

Api_Play_Drive :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=Where it goes: the entity by its name or a path Parent/Child or its id or its handle followed where it moves; a solid raised over its feet or one out of its reach arrives only standing on it; in place of position"`,
    position:[3]f32 `mirai:"optional,label=Where it goes: a point of the world; its y counts: it arrives within within plus about the height of its body above or below it; in place of entity"`,
    within:f32 `mirai:"optional,min=0,unit=m,label=It stops at this distance across the ground; given with a target it must stand on the distance also counts"`,
    move:[API_DRIVE_ACTIONS]u8 `mirai:"optional,text,label=The Axis2 action that moves; empty: the first bound to keys or to the left stick"`,
    jump:[API_DRIVE_ACTIONS]u8 `mirai:"optional,text,label=The Button action that jumps; empty: the one bound to Space or to the South button"`,
}

Api_Play_Drive_Result :: struct {
    stopped:Api_Drive_Stop `mirai:"label=Why it ended: Arrived within its distance or standing on the target; Until its conditions held; Ticks its limit; Stuck it stopped getting closer; No_Body the focused seat drives nothing; Target_Gone the entity went away; Run_Ended the game ended"`,
    position:[3]f32 `mirai:"label=Where the player ended in the world"`,
    distance:f32 `mirai:"unit=m,label=Across the ground to where the target ended"`,
    height:f32 `mirai:"unit=m,label=Of its feet over the top of the target where it ended; negative below it"`,
}

// The body of a drive over BODY_PERSON: what its lengths scale by.
@(private)
Drive_Scale :: struct {size,step,jump,speed:f32}

// What a drive does while its ticks run: those of a play.step, or of a bot of
// a plugin (play_drive_to).
Api_Drive :: struct {
    entity:core.Entity, // the target; NONE: point
    point:[3]f32,
    level:bool,    // a point taken at the height of its feet: a place across the ground
    within:f32,
    within_given:bool,
    box:mm.Aabb,   // of the target around its origin; zero: its point
    boxed:bool,
    has_top:bool,  // what is solid under its top stops a ray down
    must_stand:bool, // standing on it is what arrives
    top,bottom:f32,
    move,jump:input.Action,
    can_jump:bool,
    min_ticks:int, // ticks a jump is held at the least
    stopped:Api_Drive_Stop,
    stopping:bool,
    position:[3]f32,
    distance,best:f32, // best: the least distance so far
    height:f32,
    last:[3]f32, // where it was a tick before
    measured:bool,
    stance:Stance, // of its body at the last measure
    scale:Drive_Scale,
    seat:core.Entity, // whose actions it holds
    asked:[2]f32,     // the move it holds
    asking:bool,
    jumping:bool,   // holds the jump
    landing:bool,   // left the ground by a jump of its own and has not stood since
    held,stalled,rounds,warm,looks,detour,climbs:int, // held: ticks of the jump held; stalled: ticks without getting closer
    over_gap:bool,  // went over the gap of the jump it holds
    gap_jump:bool,  // it holds a jump taken at a gap
    climbing:bool,  // took off onto a target above it
    clearing:bool,  // walks out from under a target to take off again
    takeoff:f32,    // from the edge of the target
    takeoff_y:f32,  // where its feet left the ground
    side:f32,
    route:Route,    // the way a plugin gave, or none
    routed:bool,    // getting closer is along that way
    route_age,route_waited:int, // ticks since it was asked for; ticks waited for it
}

// The actions a bot plays by: move an Axis2 named or bound to keys or to the
// left stick, jump a Button named or bound to Space or to the South button.
// problem says what to give.
play_actions :: proc(s:^Session,m:^input.Input_Map,move_name,jump_name:string) -> (move,jump:input.Action,can_jump:bool,problem:string) {
    named :: proc(s:^Session,m:^input.Input_Map,name:string,kind:input.Action_Kind,what:string) -> (action:input.Action,problem:string) {
        found,declared:=core.name_value(s.info,input.Action,name)
        if !declared || found<0 || found>=input.ACTION_CAPACITY || m.actions[found].kind!=kind || m.declared&input.action_bit(input.Action(found))==0 {return 0,fmt.tprintf("%s %q is not a %v action: input.get lists them",what,name,kind)}
        return input.Action(found),""
    }
    has_move:=false
    if move_name!="" {
        if move,problem=named(s,m,move_name,.Axis2,"move");problem!="" {return}
        has_move=true
    }
    if jump_name!="" {
        if jump,problem=named(s,m,jump_name,.Button,"jump");problem!="" {return}
        can_jump=true
    }
    for &a,i in m.actions {
        for &b in input.action_bindings(&a) {
            first,_:=input.code_device(b.inputs[0])
            if !has_move && a.kind==.Axis2 && first==.Key {move,has_move=input.Action(i),true}
            if !can_jump && a.kind==.Button && (b.inputs[0]==.Space || b.inputs[0]==.South) {jump,can_jump=input.Action(i),true}
        }
    }
    if !has_move {
        search: for &a,i in m.actions {
            for &b in input.action_bindings(&a) {
                if a.kind==.Axis2 && b.inputs[0]==.Left_X {move,has_move=input.Action(i),true;break search}
            }
        }
    }
    if !has_move {problem="The game binds no Axis2 action to keys or to the left stick: give the one that moves with move; input.get lists them"}
    return
}

// The axes of the camera along the ground: where a Move_Input of y and x goes.
play_view_axes :: proc(w:core.World_Ref) -> (right,forward:[3]f32) {
    forward={0,0,-1}
    if view:=core.world_storage_of(w,core.View);view!=nil {
        look:=core.view_forward(view^)
        look.y=0
        if linalg.length(look)>0.001 {forward=linalg.normalize(look)}
    }
    right=linalg.cross(forward,[3]f32{0,1,0})
    return
}

// The seat with the focus and the body it drives; NONE where there is none.
play_focused :: proc(w:core.World_Ref) -> (seat,body:core.Entity) {
    state,seats:=core.world_storage_of(w,input.Seats),core.world_table_of(w,input.Seat)
    if state==nil || seats==nil {return}
    seat=input.focused(state,core.read(seats))
    body=input.body_of(core.read(seats),seat)
    return
}

// What collides in w: of its simulation, or nothing without one.
@(private)
api_drive_query :: proc(w:core.World_Ref) -> core.World_Query {
    return core.world_query(w,core.Ref(core.World_Queries){core.world_storage_of(w,core.World_Queries)})
}

// The height of what collides down from origin within reach, not counting body;
// without a simulation, of a mesh.
@(private)
api_drive_ground :: proc(s:^Session,w:core.World_Ref,query:core.World_Query,origin:[3]f32,reach:f32,body:core.Entity) -> (height:f32,found:bool) {
    if query.probe==nil {return spatial_ground_below(s,w,origin,reach,body)}
    hit,there:=query.probe(query.user,origin,{0,-1,0},reach,0,body,~u32(0))
    return hit.point.y,there
}

// Whether e is what was hit, or holds it or hangs from it.
@(private)
api_drive_is :: proc(w:core.World_Ref,hit,e:core.Entity) -> bool {
    return hit==e || entity_under(w,hit,e) || entity_under(w,e,hit)
}

// Whether a ray down over the middle or the footprint of a target meets it: a
// top to stand on. A body that plays, as a character, is not one.
@(private)
api_drive_has_top :: proc(w:core.World_Ref,e:core.Entity,world:[3]f32,box:mm.Aabb) -> bool {
    query:=api_drive_query(w)
    if query.probe==nil {return false}
    if moves:=core.world_table_of(w,input.Move_Input);moves!=nil && core.has(moves,e) {return false}
    from:=world.y+box.max.y+1
    span:=box.max.y-box.min.y+2
    middle:=world+(box.min+box.max)*0.5
    quarter:=(box.max-box.min)*0.25
    for offset in ([5][2]f32{{0,0},{1,1},{-1,1},{1,-1},{-1,-1}}) {
        origin:=[3]f32{middle.x+offset.x*quarter.x,from,middle.z+offset.y*quarter.z}
        if hit,found:=query.probe(query.user,origin,{0,-1,0},span,0,core.NONE,~u32(0));found && api_drive_is(w,hit.entity,e) {return true}
    }
    return false
}

// What a drive asks of the game that plays, read from its params; ok is false
// after failing the call. raw is the JSON of the drive.
@(private)
api_drive_read :: proc(s:^Session,call:^api.Call,w:core.World_Ref,p:^Api_Play_Drive,raw:string) -> (drive:Api_Drive,ok:bool) {
    values:[3]string
    api.object_values(call.allocator,raw,{"entity","position","within"},values[:])
    if (values[0]!="")==(values[1]!="") {
        api.call_fail(call,api.INVALID_PARAMS,`drive: name where it goes with entity, a name of the game, or position, a point [x, y, z]; give one`)
        return
    }
    drive.within,drive.within_given=p.within,values[2]!=""
    if !rpc_finite(p.within) {api.call_fail(call,api.INVALID_PARAMS,"drive.within takes a finite number of meters");return}
    if values[0]!="" {
        e,wrong:=api_entity_select(w,base.text_get(p.entity[:]),"drive.entity",true,call.allocator)
        if wrong!="" {api.call_fail(call,api.INVALID_PARAMS,wrong);return}
        drive.entity=e
        world:=entity_world(w,e).position
        box,meshes:=api_entity_box(s,w,e)
        drive.box={box.min-world,box.max-world}
        drive.has_top=api_drive_has_top(w,e,world,drive.box)
        drive.boxed=meshes || drive.has_top
        if !meshes && drive.has_top {drive.box={{-DRIVE_NO_MESH_SIZE,0,-DRIVE_NO_MESH_SIZE},{DRIVE_NO_MESH_SIZE,0,DRIVE_NO_MESH_SIZE}}}
    } else {
        if !rpc_finite(p.position.x) || !rpc_finite(p.position.y) || !rpc_finite(p.position.z) {api.call_fail(call,api.INVALID_PARAMS,"drive.position takes three finite numbers");return}
        drive.point=p.position
    }
    m,requests:=core.world_storage_of(w,input.Input_Map),core.world_storage_of(w,input.Hold_Requests)
    if m==nil || requests==nil {api.call_fail(call,api.INVALID_PARAMS,"This game has no input actions: its world does not take engine/input");return}
    problem:string
    drive.move,drive.jump,drive.can_jump,problem=play_actions(s,m,base.text_get(p.move[:]),base.text_get(p.jump[:]))
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    api_drive_begin(s,&drive)
    return drive,true
}

// What every drive starts with, whatever gave its target.
@(private)
api_drive_begin :: proc(s:^Session,d:^Api_Drive) {
    d.min_ticks=max(int(DRIVE_JUMP_SECONDS/max(s.app.tick_dt,1e-6)),1)
    d.scale={1,1,1,1}
    d.takeoff=DRIVE_TAKEOFF
    d.side=1
}

// A drive to a place across the ground, whatever its height, for what plays a
// run tick by tick outside play.step (a bot of a plugin), by the actions
// play_actions gave: play_drive_steer before each of its ticks until it says
// the drive ended, and stopped says why. play_drive_end lets go of what one
// that is left before that holds.
play_drive_to :: proc(s:^Session,place:[3]f32,within:f32,move,jump:input.Action,can_jump:bool) -> (d:Api_Drive) {
    d.point,d.level,d.within=place,true,within
    d.move,d.jump,d.can_jump=move,jump,can_jump
    api_drive_begin(s,&d)
    return
}

play_drive_end :: proc(s:^Session,r:^Run,d:^Api_Drive) {
    api_drive_let_go(run_ref(s,r),d)
}

// Where the player and the target are, into the drive, and whether it has
// arrived; false when the target or the body are not there.
@(private)
api_drive_measure :: proc(s:^Session,w:core.World_Ref,d:^Api_Drive) -> (seat,body:core.Entity,goal:[3]f32,across:[3]f32,ok:bool) {
    seat,body=play_focused(w)
    if body==core.NONE {return}
    goal=d.point
    if d.entity!=core.NONE {
        if !core.alive(core.world_entities(w),d.entity) {
            d.stopped,d.stopping=.Target_Gone,true
            return
        }
        goal=entity_world(w,d.entity).position
    }
    at:=entity_world(w,body).position
    if d.level {goal.y=at.y}
    if !d.measured {
        person,its:=BODY_PERSON,play_body_measure(s,w,body)
        d.scale={its.height/person.height,its.step_height/person.step_height,its.jump_height/person.jump_height,its.speed/person.speed}
        d.takeoff=DRIVE_TAKEOFF*d.scale.speed
    }
    across=goal-at
    across.y=0
    d.last=d.measured?d.position:at
    d.top,d.bottom=goal.y+d.box.max.y,goal.y+d.box.min.y
    d.position,d.distance,d.height=at,linalg.length(across),at.y-d.top
    d.measured=true
    d.stance=play_stance(s,w,body)
    standing:=api_drive_grounded(d)
    reach:=DRIVE_REACH_HEIGHT*d.scale.size
    out_of_reach:=d.bottom>at.y+reach || d.top<at.y-reach
    // In the air its feet say nothing of what it rose from.
    if standing {
        d.must_stand=d.entity!=core.NONE && (out_of_reach || d.has_top && d.bottom>at.y+DRIVE_RAISED*d.scale.size)
        if !d.jumping {d.landing=false}
    }
    arrived:=false
    switch {
    case d.entity==core.NONE:
        arrived=d.distance<=d.within && abs(goal.y-at.y)<=d.within+reach
    case d.must_stand:
        arrived=standing && api_drive_on_target(w,d,body,at) && (!d.within_given || d.distance<=d.within)
    case:
        arrived=d.distance<=d.within
    }
    // A jump it took lands first: the next drive should not start in the air.
    if arrived && !d.landing {d.stopped,d.stopping=.Arrived,true}
    ok=true
    return
}

// Whether the feet of a body rest on the target.
@(private)
api_drive_on_target :: proc(w:core.World_Ref,d:^Api_Drive,body:core.Entity,at:[3]f32) -> bool {
    query:=api_drive_query(w)
    slack:=DRIVE_ON_SLACK*d.scale.size
    if query.probe==nil {
        return abs(at.y-d.top)<=slack && api_drive_edge(d,entity_world(w,d.entity).position,at)<=0
    }
    hit,found:=query.probe(query.user,at+{0,slack,0},{0,-1,0},2*slack,0,body,~u32(0))
    return found && api_drive_is(w,hit.entity,d.entity)
}

// How far across the ground its feet are from the footprint of the target; 0 inside it.
@(private)
api_drive_edge :: proc(d:^Api_Drive,goal,at:[3]f32) -> f32 {
    low,high:=goal+d.box.min,goal+d.box.max
    x:=max(low.x-at.x,at.x-high.x,0)
    z:=max(low.z-at.z,at.z-high.z,0)
    return linalg.length([2]f32{x,z})
}

// Whether its feet count as on something. A body no plugin answers for
// (Stance.Unknown) is steered as on the ground: its jumps are asked whenever
// the way calls for one, and only the rays say what it stands on.
@(private)
api_drive_grounded :: proc(d:^Api_Drive) -> bool {
    return d.stance!=.Airborne
}

// Takes off, holding the jump until the steering lets go of it.
@(private)
api_drive_jump :: proc(requests:^input.Hold_Requests,d:^Api_Drive,gap:bool) {
    input.hold(requests,d.seat,d.jump,{1,0},0)
    d.jumping,d.landing,d.held,d.gap_jump,d.over_gap,d.takeoff_y=true,true,0,gap,false,d.position.y
}

// Whether what is under origin is ground it can land on: nothing within reach,
// or well under the height it left, is a gap. height is what it found there.
@(private)
api_drive_can_land :: proc(s:^Session,w:core.World_Ref,query:core.World_Query,d:^Api_Drive,origin:[3]f32,body:core.Entity,from_y:f32) -> (land:bool,height:f32) {
    found:bool
    from:=DRIVE_GAP_FROM*d.scale.size
    height,found=api_drive_ground(s,w,query,origin+[3]f32{0,from,0},from+DRIVE_GAP_DEPTH*d.scale.size,body)
    return found && height>=from_y-DRIVE_GAP_STEP*d.scale.step,height
}

// The jump it holds: it lets go once it stopped rising, or once its feet are
// over the far side of its gap.
@(private)
api_drive_hold_jump :: proc(s:^Session,w:core.World_Ref,requests:^input.Hold_Requests,body:core.Entity,query:core.World_Query,d:^Api_Drive) {
    if !d.jumping {return}
    d.held+=1
    crossed:=false
    if d.gap_jump {
        land,height:=api_drive_can_land(s,w,query,d,d.position,body,d.takeoff_y)
        if !land {d.over_gap=true}
        crossed=d.over_gap && land && d.position.y>height+DRIVE_CLEAR*d.scale.size
    }
    if d.held>=d.min_ticks && (d.position.y<=d.last.y+1e-4 || crossed) {
        input.let_go(requests,d.seat,d.jump)
        d.jumping=false
    }
}

// Steers the tick that comes: asks the game for the actions of the focused
// player to go toward the target; false when the drive ends.
play_drive_steer :: proc(s:^Session,r:^Run,d:^Api_Drive) -> bool {
    w:=run_ref(s,r)
    requests:=core.world_storage_of(w,input.Hold_Requests)
    seat,body,goal,across,known:=api_drive_measure(s,w,d)
    if seat!=d.seat {
        api_drive_let_go(w,d)
        d.seat=seat
    }
    if d.stopping {
        api_drive_let_go(w,d)
        return false
    }
    if body==core.NONE {
        api_drive_ask(requests,d,{})
        d.warm+=1
        if d.warm>DRIVE_WARM_TICKS {
            d.stopped,d.stopping=.No_Body,true
            return false
        }
        return true
    }
    if !known {return true}
    query:=api_drive_query(w)
    standing:=api_drive_grounded(d)
    api_drive_route_update(s,w,d,body,goal)
    if d.route.state==.Waiting && d.route_waited<DRIVE_ROUTE_WAIT {
        api_drive_ask(requests,d,{})
        d.route_waited+=1
        return true
    }
    routed:=d.route.state==.Found
    if routed!=d.routed {d.routed,d.best,d.stalled=routed,0,0}
    left:=routed?d.route.left:d.distance
    if d.best==0 {d.best=left}
    if d.detour>0 || d.clearing {
        // A step away gets no closer on purpose: it counts from where it ends.
        d.best,d.stalled=max(d.best,left),0
    } else if left<d.best-DRIVE_PROGRESS*d.scale.speed {
        d.best,d.stalled,d.rounds=left,0,0
    } else {
        d.stalled+=1
    }
    direction:=across/max(d.distance,1e-4)
    right,forward:=play_view_axes(w)
    api_drive_hold_jump(s,w,requests,body,query,d)
    jump_asked,gap_jump:=false,false
    above:=d.must_stand && d.boxed && d.position.y<d.top-DRIVE_ON_SLACK*d.scale.size
    edge:=d.boxed?api_drive_edge(d,goal,d.position):0
    // Around what blocks it, and up onto a target at hand, it goes by itself.
    if routed && d.detour==0 && !d.clearing && !(above && edge<=d.takeoff) {
        toward:=d.route.next-d.position
        toward.y=0
        if linalg.length(toward)>1e-4 {direction=linalg.normalize(toward)}
    }
    if above {
        // Fell back from a jump onto it: another run at it, from farther.
        if d.climbing && standing && !d.jumping {
            d.climbing,d.clearing=false,true
            d.climbs+=1
            d.takeoff+=DRIVE_TAKEOFF_GROW*d.scale.speed
            if d.climbs>=DRIVE_GIVE_UP {
                d.stopped,d.stopping=.Stuck,true
                api_drive_let_go(w,d)
                return false
            }
        }
        if !d.clearing && standing && !d.jumping && edge<=0 {d.clearing=true}
        if d.clearing && edge>=d.takeoff+DRIVE_RUN_UP*d.scale.speed {d.clearing=false}
    } else {d.clearing,d.climbing=false,false}
    if d.stalled>=DRIVE_STALL_TICKS {
        d.stalled=0
        d.rounds+=1
        if d.rounds>=DRIVE_GIVE_UP {
            d.stopped,d.stopping=.Stuck,true
            api_drive_let_go(w,d)
            return false
        }
        // Over what is low first; then around it, by turns to each side.
        jump_asked=true
        if d.rounds>=2 {
            d.detour=DRIVE_DETOUR_TICKS
            d.side=-d.side
        }
    } else if above && !d.clearing && edge>0 && edge<=d.takeoff {
        jump_asked=true
        d.climbing=true
    } else if d.can_jump && !d.jumping && d.position.y-d.top<DRIVE_FALL*d.scale.jump && (query.probe!=nil || d.looks%DRIVE_GAP_EVERY==0) {
        moved:=d.position-d.last
        moved.y=0
        ahead:=max(DRIVE_GAP_EDGE*d.scale.size,linalg.length(moved)*DRIVE_GAP_TICKS)
        if (d.must_stand && d.boxed)?edge>ahead:d.distance>d.within+ahead {
            // On what has no shape to the rays, no ground is seen under it either.
            here,_:=api_drive_can_land(s,w,query,d,d.position,body,d.position.y)
            ahead_land,_:=api_drive_can_land(s,w,query,d,d.position+direction*ahead,body,d.position.y)
            if here && !ahead_land {jump_asked,gap_jump=true,true}
        }
    }
    d.looks+=1
    if jump_asked && d.can_jump && !d.jumping && standing {api_drive_jump(requests,d,gap_jump)}
    if d.clearing {
        direction=api_drive_out(d,goal)
    } else if d.detour>0 {
        d.detour-=1
        direction=linalg.cross(direction,[3]f32{0,1,0})*d.side
    }
    api_drive_ask(requests,d,{linalg.dot(direction,right),linalg.dot(direction,forward)})
    return true
}

// The move it asks of its seat, held until it asks another. One that barely
// turned is not asked again: what keeps the holds of a run (the repros of the
// playtest plugin) gets one a turn, not one a tick.
@(private)
api_drive_ask :: proc(requests:^input.Hold_Requests,d:^Api_Drive,vector:[2]f32) {
    if d.seat==core.NONE || d.asking==(vector!={}) && linalg.length(vector-d.asked)<=DRIVE_TURN {return}
    input.hold(requests,d.seat,d.move,vector)
    d.asked,d.asking=vector,vector!={}
}

// Asks for the way when it is old or its next point is at hand.
@(private)
api_drive_route_update :: proc(s:^Session,w:core.World_Ref,d:^Api_Drive,body:core.Entity,goal:[3]f32) {
    toward:=d.route.next-d.position
    toward.y=0
    if d.route.state==.Found && d.route_age<DRIVE_ROUTE_EVERY && linalg.length(toward)>DRIVE_ROUTE_CORNER {
        d.route_age+=1
        return
    }
    d.route,d.route_age=route_of_body(s,w,body,goal),0
}

// The way out from under the target: toward its nearest edge across the ground.
@(private)
api_drive_out :: proc(d:^Api_Drive,goal:[3]f32) -> [3]f32 {
    low,high:=goal+d.box.min,goal+d.box.max
    x:=d.position.x-low.x<high.x-d.position.x?f32(-1):f32(1)
    z:=d.position.z-low.z<high.z-d.position.z?f32(-1):f32(1)
    along_x:=min(d.position.x-low.x,high.x-d.position.x)<min(d.position.z-low.z,high.z-d.position.z)
    return along_x?{x,0,0}:{0,0,z}
}

// Lets go of what it holds of its seat, when that one is still there.
@(private)
api_drive_let_go :: proc(w:core.World_Ref,d:^Api_Drive) {
    requests:=core.world_storage_of(w,input.Hold_Requests)
    held:=d.asking || d.jumping
    d.asking,d.jumping,d.asked=false,false,{}
    if !held || requests==nil || !core.alive(core.world_entities(w),d.seat) {return}
    input.let_go(requests,d.seat,d.move)
    if d.can_jump {input.let_go(requests,d.seat,d.jump)}
}

// How a drive ended, after its step: its last measure with the conditions it
// met and whether the game still runs.
@(private)
api_drive_finish :: proc(s:^Session,r:^Run,d:^Api_Drive,met:bool) {
    if r==nil {
        if !d.stopping {d.stopped,d.stopping=.Run_Ended,true}
        return
    }
    w:=run_ref(s,r)
    api_drive_measure(s,w,d)
    api_drive_let_go(w,d)
    if !d.stopping {d.stopped,d.stopping=met?.Until:.Ticks,true}
}

// The drive of a step in its answer.
@(private)
api_drive_result :: proc(d:^Api_Drive) -> Api_Play_Drive_Result {
    return {stopped=d.stopped,position=d.position,distance=d.distance,height=d.height}
}

// Whether a drive of a step held: it reached its target, or its conditions held.
@(private)
api_drive_held :: proc(drive:string) -> bool {
    value,err:=json.parse(transmute([]u8)drive,allocator=context.temp_allocator)
    if err!=nil {return false}
    object,is_object:=value.(json.Object)
    if !is_object {return false}
    stopped,_:=object["stopped"].(json.String)
    return string(stopped)=="Arrived" || string(stopped)=="Until"
}
