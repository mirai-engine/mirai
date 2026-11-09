package playtest_editor

import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:slice"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// What an agent needs for one decision, in one small answer, read between two
// ticks; with step it runs those ticks first, so that one call acts and
// observes. It costs an agent little to read and the game nothing.

API_OBSERVE_TARGETS :: 8
@(private) API_OBSERVE_PROBLEMS :: 5
@(private) API_OBSERVE_BUTTONS :: 16
@(private) API_OBSERVE_STUCK_SECONDS :: 1.5
@(private) API_OBSERVE_NEAREST :: 3
@(private) API_OBSERVE_CAPTURE_WIDTH :: 480

Api_Play_Observe_Params :: struct {
    targets:[API_OBSERVE_TARGETS][64]u8 `mirai:"optional,text,label=Names of components or of entities (* stands for any run of characters) to find around the player"`,
    nearest:int `mirai:"optional,min=1,max=16,label=How many of the matches of targets to return"`,
    path:[editor.API_PATH_BYTES]u8 `mirai:"optional,text,label=PNG file to write a small image of the game to"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    step:editor.Api_Play_Step_Params `mirai:"optional,label=Ticks to run first with the params of play.step: the answer adds its ran and met and drive and trace"`,
}

Api_Play_Observe :: struct {
    tick:u64,
    seconds:f64 `mirai:"label=The time of the game"`,
    frame_ms:f32 `mirai:"label=The whole last frame of the application"`,
    stuck:bool `mirai:"label=The body asks to move and has not moved for a while"`,
    player:Api_Play_Observe_Player `mirai:"optional,label=The body the focused seat drives; absent without one"`,
    ui:Api_Play_Observe_Ui `mirai:"optional,label=The top screen of the focused player; absent without one"`,
    problems:[1]Api_Play_Observe_Problem `mirai:"list,optional,label=core.report problems since the last observe"`,
    problems_more:int `mirai:"optional,label=New problems that did not fit"`,
    targets:[1]Api_Play_Observe_Target `mirai:"list,optional,label=The nearest matches of targets"`,
    capture:editor.Api_Capture_Result `mirai:"optional,label=The image written to path"`,
    capture_error:[256]u8 `mirai:"optional,text,label=Why the image of path could not be written"`,
    ran:int `mirai:"optional,label=With step: the ticks it ran"`,
    met:bool `mirai:"optional,label=With step and until: whether they held when it stopped"`,
    drive:editor.Api_Play_Drive_Result `mirai:"optional,label=With step and drive: where the player ended and why it stopped"`,
    trace:editor.Api_Play_Trace_Table `mirai:"optional,label=With step and trace: the values it read"`,
}
Api_Play_Observe_Player :: struct {
    position:[3]f32,
    velocity:[3]f32 `mirai:"label=m/s; zero when no simulation moves it"`,
    grounded:bool `mirai:"optional,label=It stands on something; absent when nothing says so"`,
    facing:[3]f32 `mirai:"label=Where it looks: a unit vector"`,
}
Api_Play_Observe_Ui :: struct {
    screen:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The .ui that takes the input"`,
    modal:bool `mirai:"optional"`,
    focused:[ui.TREE_NAME_CAPACITY]u8 `mirai:"optional,text,label=The node with the focus"`,
    buttons:[1]Api_Play_Observe_Button `mirai:"list,label=What can be pressed, in window points play.step takes"`,
    buttons_more:int `mirai:"optional,label=Buttons that did not fit"`,
}
Api_Play_Observe_Button :: struct {
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    text:[64]u8 `mirai:"optional,text,label=What it says"`,
    rect:[4]f32 `mirai:"optional,label=x y width height"`,
    disabled:bool `mirai:"optional"`,
}
Api_Play_Observe_Problem :: struct {
    code:[core.PROBLEM_CODE]u8 `mirai:"text"`,
    text:[core.PROBLEM_TEXT]u8 `mirai:"text"`,
    entity:[64]u8 `mirai:"optional,text,label=The name of the entity it is about"`,
}
Api_Play_Observe_Target :: struct {
    name:[64]u8 `mirai:"text"`,
    entity:[editor.API_HANDLE_TEXT]u8 `mirai:"text,label=Its handle"`,
    distance:f32 `mirai:"label=Meters from the eye of the player's camera"`,
    bearing:f32 `mirai:"label=Degrees to the right of where the camera looks; negative to its left"`,
    elevation:f32 `mirai:"label=Degrees above where the camera looks"`,
    on_screen:bool,
}

// What play.observe keeps of a run between two calls.
Run_Observed :: struct {
    serial:u64,        // the Problems.serial it has listed
    anchor:[3]f32,     // where the body was when it last moved or did not ask to
    anchor_seconds:f64,
    anchored:bool,
}

@(private)
observe_api_register :: proc(s:^editor.Session) {
    defaults:=Api_Play_Observe_Params{nearest=API_OBSERVE_NEAREST,step={input={ticks=1},focus=-1,trace={every=1}}}
    editor.api_method_register(s,{name="play.observe",summary="Everything needed for one decision in one small answer: the tick, the frame time, the focused player (place, velocity, grounded, facing), the buttons of the screen it sees, the problems since the last observe, whether it is stuck and the nearest targets. With step it first runs those ticks as play.step does, so one call acts and observes.",params=Api_Play_Observe_Params,params_info=type_info_of(Api_Play_Observe_Params),result=Api_Play_Observe,result_info=type_info_of(Api_Play_Observe),writes_result=true,defaults=&defaults,run=api_play_observe})
}

@(private)
observe_round :: proc(value:f32,decimals:f32=100) -> f32 {return f32(math.round(f64(value)*f64(decimals))/f64(decimals))+0}

@(private)
observe_vector_write :: proc(out:^serial.Writer,key:string,value:[]f32,decimals:f32=100,first:=false) {
    api.write_key(out,key,first);serial.write_u8(out,'[')
    for v,i in value {
        if i>0 {serial.write_u8(out,',')}
        api.write_number(out,observe_round(v,decimals))
    }
    serial.write_u8(out,']')
}

@(private)
Observe_Found :: struct {
    entity:core.Entity,
    distance,bearing,elevation:f32,
    on_screen:bool,
}

// The entities targets name: those with a component or those whose name
// matches, without the body itself; the nearest to the camera first.
@(private)
observe_targets_find :: proc(s:^editor.Session,w:core.World_Ref,names:[]string,body:core.Entity,nearest:int,allocator:=context.temp_allocator) -> []Observe_Found {
    view:=core.world_storage_of(w,core.View)
    if view==nil || len(names)==0 {return nil}
    entities:=editor.api_entities_ordered(w,allocator)
    found:=make([dynamic]Observe_Found,allocator)
    forward:=core.view_forward(view^)
    right:=mm.quat_rotate(view.rotation,[3]f32{1,0,0})
    up:=mm.quat_rotate(view.rotation,[3]f32{0,1,0})
    for e in entities {
        if e==body {continue}
        matched:=false
        for name in names {
            table:=editor.component_table(s,name)
            matched=table!=nil?core.raw_find(core.world_table_at(w,table),table.info,e)!=nil:editor.api_name_match(name,editor.entity_name(w,e))
            if matched {break}
        }
        if !matched {continue}
        point:=editor.api_entity_middle(w,e)
        relative:=point-view.position
        distance:=linalg.length(relative)
        entry:=Observe_Found{entity=e,distance=distance}
        entry.bearing=f32(math.atan2(f64(linalg.dot(relative,right)),f64(linalg.dot(relative,forward))))*mm.DEG_PER_RAD
        if distance>1e-4 {entry.elevation=f32(math.asin(f64(clamp(linalg.dot(relative,up)/distance,-1,1))))*mm.DEG_PER_RAD}
        size:=[2]f32{max(view.size.x,1),max(view.size.y,1)}
        if pixel,_,front:=core.view_project(view^,point);front {
            at:=pixel/size
            entry.on_screen=at.x>=0 && at.x<=1 && at.y>=0 && at.y<=1
        }
        append(&found,entry)
    }
    slice.stable_sort_by(found[:],proc(a,b:Observe_Found) -> bool {return a.distance<b.distance})
    return found[:min(len(found),nearest)]
}

// The direction a body looks: that of its Move_Input, else that of its camera.
@(private)
observe_facing :: proc(w:core.World_Ref,body:core.Entity) -> [3]f32 {
    if moves:=core.world_table_of(w,input.Move_Input);moves!=nil {
        if move,found:=core.get(core.read(moves),body);found {
            yaw:=f64(move.look_yaw)
            return {f32(-math.sin(yaw)),0,f32(-math.cos(yaw))}
        }
    }
    if view:=core.world_storage_of(w,core.View);view!=nil {return core.view_forward(view^)}
    return mm.FORWARD
}

// A stand or a walk on nothing: the bool of the physics that a game may not have.
@(private)
observe_grounded :: proc(s:^editor.Session,w:core.World_Ref,body:core.Entity,allocator:=context.temp_allocator) -> (grounded,known:bool) {
    table:=editor.component_table(s,"Character_State")
    if table==nil || core.raw_find(core.world_table_at(w,table),table.info,body)==nil {return}
    value,problem:=editor.api_entity_field(s,w,body,"Character_State.standing",allocator)
    if problem!="" {return}
    return value=="true",true
}

// Writes the answer of play.observe for a run: one JSON object.
@(private)
play_observe_write :: proc(s:^editor.Session,out:^serial.Writer,r:^editor.Run,names:[]string,nearest:int,allocator:=context.temp_allocator) {
    w:=editor.run_ref(s,r)
    tick,seconds:=u64(0),f64(0)
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick,seconds=t.tick,t.seconds}
    _,body:=editor.play_focused(w)
    moved:[3]f32
    if body!=core.NONE {moved=editor.entity_world(w,body).position}
    // The tracker: a body is stuck that asked to move and stayed where it was.
    slot:=playtest_run(s,r)
    if slot==nil {return}
    o:=&slot.observed
    if body==core.NONE || !play_moving(w,body) || !o.anchored || linalg.length(moved-o.anchor)>=QA_STUCK_DISTANCE {
        o.anchor,o.anchor_seconds,o.anchored=moved,seconds,true
    }
    stuck:=seconds-o.anchor_seconds>=API_OBSERVE_STUCK_SECONDS
    if q:=slot.qa;q!=nil && q.limits.stuck_seconds>0 {stuck=q.stuck}
    serial.write_u8(out,'{')
    api.write_uint(out,"tick",tick,true)
    api.write_key(out,"seconds");api.write_number(out,observe_round(f32(seconds)))
    api.write_key(out,"frame_ms");api.write_number(out,observe_round(s.app.stats.frame_ms,10))
    api.write_bool(out,"stuck",stuck)
    if body!=core.NONE {
        velocity:[3]f32
        if motions:=core.world_table_of(w,core.Motion);motions!=nil {
            if motion,moves:=core.get(core.read(motions),body);moves {velocity=motion.linear}
        }
        facing:=observe_facing(w,body)
        api.write_key(out,"player");serial.write_u8(out,'{')
        observe_vector_write(out,"position",moved[:],first=true)
        observe_vector_write(out,"velocity",velocity[:])
        if grounded,known:=observe_grounded(s,w,body,allocator);known {api.write_bool(out,"grounded",grounded)}
        observe_vector_write(out,"facing",facing[:],1000)
        serial.write_u8(out,'}')
    }
    observe_ui_write(s,out,r)
    observe_problems_write(s,out,r,o,w)
    if found:=observe_targets_find(s,w,names,body,max(nearest,1),allocator);len(names)>0 {
        api.write_key(out,"targets");serial.write_u8(out,'[')
        for &f,i in found {
            if i>0 {serial.write_u8(out,',')}
            serial.write_u8(out,'{')
            api.write_text(out,"name",editor.entity_name(w,f.entity),true)
            api.write_key(out,"entity")
            serial.write_u8(out,'"');serial.text_write_hex(out,u64(f.entity));serial.write_u8(out,'"')
            api.write_key(out,"distance");api.write_number(out,observe_round(f.distance,10))
            api.write_key(out,"bearing");api.write_number(out,observe_round(f.bearing,1))
            api.write_key(out,"elevation");api.write_number(out,observe_round(f.elevation,1))
            api.write_bool(out,"on_screen",f.on_screen)
            serial.write_u8(out,'}')
        }
        serial.write_u8(out,']')
    }
    serial.write_u8(out,'}')
}

@(private)
observe_ui_write :: proc(s:^editor.Session,out:^serial.Writer,r:^editor.Run) {
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {return}
    defer virtual.arena_destroy(&arena)
    top,found:=editor.play_ui_screen(s,r,false,virtual.arena_allocator(&arena))
    if !found {return}
    api.write_key(out,"ui");serial.write_u8(out,'{')
    api.write_text(out,"screen",top.screen,true)
    if top.modal {api.write_bool(out,"modal",true)}
    if top.focused!="" {api.write_text(out,"focused",top.focused)}
    api.write_key(out,"buttons");serial.write_u8(out,'[')
    for &b,i in top.buttons[:min(len(top.buttons),API_OBSERVE_BUTTONS)] {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"name",b.name,true)
        if b.text!="" && b.text!=b.name {api.write_text(out,"text",b.text)}
        if b.laid {observe_vector_write(out,"rect",b.rect[:],1)}
        if b.disabled {api.write_bool(out,"disabled",true)}
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    if len(top.buttons)>API_OBSERVE_BUTTONS {api.write_int(out,"buttons_more",i64(len(top.buttons)-API_OBSERVE_BUTTONS))}
    serial.write_u8(out,'}')
}

// The problems reported since the last observe, the oldest first.
@(private)
observe_problems_write :: proc(s:^editor.Session,out:^serial.Writer,r:^editor.Run,o:^Run_Observed,w:core.World_Ref) {
    problems:=host.app_world_storage(s.app,r.world,core.Problems)
    if problems==nil || problems.serial==o.serial {return}
    since:=o.serial
    o.serial=problems.serial
    fresh:=make([dynamic]core.Problem,context.temp_allocator)
    for &p in core.problems_list(problems) {
        if p.last>since {append(&fresh,p)}
    }
    if len(fresh)==0 {return}
    slice.sort_by(fresh[:],proc(a,b:core.Problem) -> bool {return a.first<b.first})
    api.write_key(out,"problems");serial.write_u8(out,'[')
    for &p,i in fresh[:min(len(fresh),API_OBSERVE_PROBLEMS)] {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"code",core.problem_code(&p),true)
        api.write_text(out,"text",core.problem_text(&p))
        if p.entity!=core.NONE {api.write_text(out,"entity",editor.entity_name(w,p.entity))}
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    if len(fresh)>API_OBSERVE_PROBLEMS {api.write_int(out,"problems_more",i64(len(fresh)-API_OBSERVE_PROBLEMS))}
}

// A small capture of the game at path, by the method of the images: what it
// answered goes in capture, or why it could not in capture_error.
@(private)
observe_capture_write :: proc(s:^editor.Session,call:^api.Call,out:^serial.Writer,path:string) {
    server:=call.server
    params:serial.Writer
    serial.writer_init(&params,0,call.allocator)
    serial.text_write_raw(&params,`{"path":`);serial.text_write_string(&params,path)
    serial.text_write_raw(&params,`,"of":"Game","frames":1,"width":`);serial.text_write_int(&params,API_OBSERVE_CAPTURE_WIDTH)
    serial.write_u8(&params,'}')
    answer:=make([]u8,4096,call.allocator)
    text,error,ok:=editor.api_scenario_call(server,"capture",string(serial.writer_bytes(&params)),answer)
    if !ok {
        api.write_text(out,"capture_error",error.message)
        return
    }
    api.write_key(out,"capture");serial.text_write_raw(out,text)
}

@(private)
api_play_observe :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Observe_Params)
    stepped:[len(OBSERVE_STEP_KEYS)]string
    if !observe_step(call,&stepped) {return}
    r,_:=editor.api_play_run(s,call,p.player)
    if r==nil {
        if stepped[0]!="" {api.call_failf(call,api.SERVER_ERROR,"The game ended during the step, after %s ticks",stepped[0]);return}
        api.call_fail(call,api.SERVER_ERROR,editor.API_NO_GAME)
        return
    }
    count,_:=api.params_array_count(call,"targets")
    names:=make([]string,count,call.allocator)
    for &name,i in names {name=base.text_get(p.targets[i][:])}
    out:=call.out
    play_observe_write(s,out,r,names,p.nearest,call.allocator)
    out.count-=1
    if path:=base.text_get(p.path[:]);path!="" {observe_capture_write(s,call,out,path)}
    for key,i in OBSERVE_STEP_KEYS {
        if stepped[i]!="" {api.write_key(out,key);serial.text_write_raw(out,stepped[i])}
    }
    serial.write_u8(out,'}')
}

@(private) OBSERVE_STEP_KEYS :: [4]string{"ran","met","drive","trace"}
@(private) OBSERVE_STEP_ANSWER :: 1<<20

// Runs the step the params give, if any, by the method of play.step; what it
// answered of OBSERVE_STEP_KEYS as JSON, or false after failing the call.
@(private)
observe_step :: proc(call:^api.Call,answer:^[len(OBSERVE_STEP_KEYS)]string) -> bool {
    given:[1]string
    api.object_values(call.allocator,call.raw,{"step"},given[:])
    if given[0]=="" {return true}
    buffer:=make([]u8,OBSERVE_STEP_ANSWER,call.allocator)
    text,error,ok:=editor.api_scenario_call(call.server,"play.step",given[0],buffer)
    if !ok {
        api.call_fail(call,error.code,error.message)
        return false
    }
    keys:=OBSERVE_STEP_KEYS
    api.object_values(call.allocator,text,keys[:],answer[:])
    return true
}
