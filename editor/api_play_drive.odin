package editor

import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:std/base"

// A drive of play.step: its ticks steer the focused player to a target by the
// move action of the game, re-aimed every tick toward where the target is
// now, as play.explore steers. It jumps at a gap in front of it and when
// blocked, then tries each side; it stops within a distance, with the conditions
// of the step, at its ticks, or when it stops getting closer. A platform that moves is
// not predicted: wait for it with a step with until, then drive onto it.

API_DRIVE_DEFAULT_SECONDS :: 30
API_DRIVE_WITHIN :: f32(1)         // m across the ground
API_DRIVE_ACTIONS :: 64
@(private) DRIVE_REACH_HEIGHT :: f32(2)     // m: above or below it within and this much still arrives
@(private) DRIVE_WARM_TICKS :: 60           // for the seat and its body to appear
@(private) DRIVE_PROGRESS :: f32(0.05)      // m closer to the target that count as getting closer
@(private) DRIVE_BLOCKED_TICKS :: 20        // without getting closer: another way
@(private) DRIVE_DETOUR_TICKS :: 40         // a blocked round walks to a side this long
@(private) DRIVE_GIVE_UP :: 6               // blocked rounds in a row before it stops
@(private) DRIVE_JUMP_SECONDS :: f32(0.2)   // a jump is held this long: a tap would cut it
@(private) DRIVE_GAP_AHEAD :: f32(1.2)      // m ahead a gap is looked for
@(private) DRIVE_GAP_FROM :: f32(1)         // m above its feet the rays start
@(private) DRIVE_GAP_DEPTH :: f32(3)        // m down: nothing deeper is ground to it
@(private) DRIVE_GAP_EVERY :: 3             // ticks between looks for a gap
@(private) DRIVE_FALL :: f32(1.5)           // m under its feet a target is walked off to, not jumped over

Api_Drive_Stop :: enum u8 {Arrived,Until,Ticks,Stuck,No_Body,Target_Gone,Run_Ended}

Api_Play_Drive :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,label=Where it goes: the entity by its name or a path Parent/Child or its id or its handle followed where it moves; in place of position"`,
    position:[3]f32 `mirai:"optional,label=Where it goes: a point of the world; in place of entity"`,
    within:f32 `mirai:"optional,min=0,unit=m,label=It stops at this distance across the ground"`,
    move:[API_DRIVE_ACTIONS]u8 `mirai:"optional,text,label=The Axis2 action that moves; empty: the first bound to keys or to the left stick"`,
    jump:[API_DRIVE_ACTIONS]u8 `mirai:"optional,text,label=The Button action that jumps; empty: the one bound to Space or to the South button"`,
}

Api_Play_Drive_Result :: struct {
    stopped:Api_Drive_Stop `mirai:"label=Why it ended: Arrived within its distance; Until its conditions held; Ticks its limit; Stuck it stopped getting closer; No_Body the focused seat drives nothing; Target_Gone the entity went away; Run_Ended the game ended"`,
    position:[3]f32 `mirai:"label=Where the player ended in the world"`,
    distance:f32 `mirai:"unit=m,label=Across the ground to where the target ended"`,
}

// What a drive does while its step runs.
@(private)
Api_Drive :: struct {
    entity:core.Entity, // the target; NONE: point
    point:[3]f32,
    within:f32,
    move,jump:input.Action,
    can_jump:bool,
    jump_ticks:u32,
    stopped:Api_Drive_Stop,
    stopping:bool,
    position:[3]f32,
    distance,best:f32, // best: the least distance so far
    measured:bool,
    still,rounds,warm,looks,hold_left,detour:int,
    side:f32,
}

// The actions a bot plays by: move an Axis2 named or bound to keys or to the
// left stick, jump a Button named or bound to Space or to the South button.
// problem says what to give.
play_actions :: proc(s:^Session,m:^input.Input_Map,move_name,jump_name:string) -> (move,jump:input.Action,can_jump:bool,problem:string) {
    named :: proc(s:^Session,m:^input.Input_Map,name:string,kind:input.Action_Kind,what:string) -> (action:input.Action,problem:string) {
        found,declared:=core.name_value(s.info,input.Action,name)
        if !declared || found<0 || found>=input.ACTION_CAPACITY || m.kinds[found]!=kind || m.declared&input.action_bit(input.Action(found))==0 {return 0,fmt.tprintf("%s %q is not a %v action: input.get lists them",what,name,kind)}
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
    for &b in m.bindings[:m.binding_count] {
        kind:=m.kinds[b.action]
        if !has_move && kind==.Axis2 && b.count>0 && b.codes[0].device==.Key {move,has_move=b.action,true}
        if !can_jump && kind==.Button && b.count==1 {
            code:=b.codes[0]
            if code.device==.Key && core.Key(code.code)==.Space || code.device==.Gamepad_Button && core.Gamepad_Button(code.code)==.South {jump,can_jump=b.action,true}
        }
    }
    if !has_move {
        for &b in m.bindings[:m.binding_count] {
            if m.kinds[b.action]==.Axis2 && b.count==2 && b.codes[0].device==.Gamepad_Axis && core.Gamepad_Axis(b.codes[0].code)==.Left_X {move,has_move=b.action,true;break}
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
    if drivables:=core.world_table_of(w,input.Drivable);drivables!=nil {body=input.body_of(core.read(drivables),seat)}
    return
}

// What a drive asks of the game that plays, read from its params; ok is false
// after failing the call. raw is the JSON of the drive.
@(private)
api_drive_read :: proc(s:^Session,call:^api.Call,w:core.World_Ref,p:^Api_Play_Drive,raw:string) -> (drive:Api_Drive,ok:bool) {
    values:[2]string
    api.object_values(call.allocator,raw,{"entity","position"},values[:])
    if (values[0]!="")==(values[1]!="") {
        api.call_fail(call,api.INVALID_PARAMS,`drive: name where it goes with entity, a name of the game, or position, a point [x, y, z]; give one`)
        return
    }
    drive.within=p.within
    if !rpc_finite(p.within) {api.call_fail(call,api.INVALID_PARAMS,"drive.within takes a finite number of meters");return}
    if values[0]!="" {
        e,wrong:=api_entity_select(w,base.text_get(p.entity[:]),"drive.entity",true,call.allocator)
        if wrong!="" {api.call_fail(call,api.INVALID_PARAMS,wrong);return}
        drive.entity=e
    } else {
        if !rpc_finite(p.position.x) || !rpc_finite(p.position.y) || !rpc_finite(p.position.z) {api.call_fail(call,api.INVALID_PARAMS,"drive.position takes three finite numbers");return}
        drive.point=p.position
    }
    m,requests:=core.world_storage_of(w,input.Input_Map),core.world_storage_of(w,input.Hold_Requests)
    if m==nil || requests==nil {api.call_fail(call,api.INVALID_PARAMS,"This game has no input actions: its world does not take engine/input");return}
    problem:string
    drive.move,drive.jump,drive.can_jump,problem=play_actions(s,m,base.text_get(p.move[:]),base.text_get(p.jump[:]))
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    drive.jump_ticks=u32(max(int(DRIVE_JUMP_SECONDS/max(s.app.tick_dt,1e-6)),1))
    drive.side=1
    return drive,true
}

// Where the player and the target are, into the drive; false when the target or the body are not there.
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
    across=goal-at
    across.y=0
    d.position,d.distance=at,linalg.length(across)
    d.measured=true
    if d.distance<=d.within && abs(goal.y-at.y)<=d.within+DRIVE_REACH_HEIGHT {d.stopped,d.stopping=.Arrived,true}
    ok=true
    return
}

// Whether a character stands; true for a game whose bodies do not say.
@(private)
api_drive_standing :: proc(s:^Session,w:core.World_Ref,body:core.Entity) -> bool {
    if component_table(s,"Character_State")==nil {return true}
    value,problem:=api_entity_field(s,w,body,"Character_State.standing",context.temp_allocator)
    return problem!="" || value=="true"
}

// Steers the tick that comes: asks the game for the actions of the focused
// player to go toward the target; false when the drive ends.
@(private)
api_drive_steer :: proc(s:^Session,r:^Run,d:^Api_Drive) -> bool {
    w:=run_ref(s,r)
    requests:=core.world_storage_of(w,input.Hold_Requests)
    seat,body,goal,across,known:=api_drive_measure(s,w,d)
    if d.stopping {
        api_drive_let_go(requests,seat,d)
        return false
    }
    if body==core.NONE {
        d.warm+=1
        if d.warm>DRIVE_WARM_TICKS {
            d.stopped,d.stopping=.No_Body,true
            return false
        }
        return true
    }
    if !known {return true}
    if !d.measured {return true}
    if d.best==0 {d.best=d.distance}
    if d.detour>0 {
        // A step to the side gets no closer on purpose: it counts from where it ends.
        d.best,d.still=max(d.best,d.distance),0
    } else if d.distance<d.best-DRIVE_PROGRESS {
        d.best,d.still,d.rounds=d.distance,0,0
    } else {
        d.still+=1
    }
    direction:=across/max(d.distance,1e-4)
    right,forward:=play_view_axes(w)
    if d.hold_left>0 {d.hold_left-=1}
    jump_asked:=false
    if d.still>=DRIVE_BLOCKED_TICKS {
        d.still=0
        d.rounds+=1
        if d.rounds>=DRIVE_GIVE_UP {
            d.stopped,d.stopping=.Stuck,true
            api_drive_let_go(requests,seat,d)
            return false
        }
        // Over what is low first; then around it, by turns to each side.
        jump_asked=true
        if d.rounds>=2 {
            d.detour=DRIVE_DETOUR_TICKS
            d.side=-d.side
        }
    } else if d.can_jump && d.looks%DRIVE_GAP_EVERY==0 && d.distance>d.within+DRIVE_GAP_AHEAD && d.position.y-goal.y<DRIVE_FALL && d.hold_left==0 {
        origin:=d.position+[3]f32{0,DRIVE_GAP_FROM,0}
        reach:=DRIVE_GAP_FROM+DRIVE_GAP_DEPTH
        // On what has no meshes to the rays, as a terrain of a plugin, no ground is seen under it either.
        if spatial_ground_below(s,w,origin,reach,body) && !spatial_ground_below(s,w,origin+direction*DRIVE_GAP_AHEAD,reach,body) {jump_asked=true}
    }
    d.looks+=1
    if jump_asked && d.can_jump && d.hold_left==0 && api_drive_standing(s,w,body) {
        input.hold(requests,seat,d.jump,{1,0},d.jump_ticks)
        d.hold_left=int(d.jump_ticks)
    }
    if d.detour>0 {
        d.detour-=1
        direction=linalg.cross(direction,[3]f32{0,1,0})*d.side
    }
    vector:=[2]f32{linalg.dot(direction,right),linalg.dot(direction,forward)}
    if vector!={} {input.hold(requests,seat,d.move,vector,1)}
    return true
}

@(private)
api_drive_let_go :: proc(requests:^input.Hold_Requests,seat:core.Entity,d:^Api_Drive) {
    if requests==nil || seat==core.NONE {return}
    input.let_go(requests,seat,d.move)
    if d.can_jump {input.let_go(requests,seat,d.jump)}
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
    seat,_,_,_,_:=api_drive_measure(s,w,d)
    api_drive_let_go(core.world_storage_of(w,input.Hold_Requests),seat,d)
    if !d.stopping {d.stopped,d.stopping=met?.Until:.Ticks,true}
}

// The drive of a step in its answer.
@(private)
api_drive_result :: proc(d:^Api_Drive) -> Api_Play_Drive_Result {
    return {stopped=d.stopped,position=d.position,distance=d.distance}
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
