package animation_editor

import "base:intrinsics"
import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

// A clip of the library of the .match played at once (match_play), as the clip of mode, until
// phase of it or its marker; matching goes on from there. The options are Match_Play_Options.
Request_Play :: struct {
    clip:[64]u8 `mirai:"text,label=A clip of the library of the .match"`,
    mode:[32]u8 `mirai:"text,optional,label=The Locomotion_Mode it plays in; the body leaving it gives the rig back to matching. Empty: the one the rig is in"`,
    fade:f32 `mirai:"optional,min=0,unit=s,label=Of the inertial blend into it"`,
    entry:anim.Match_Entry `mirai:"optional,label=Start; Keep_Time: at the time of the clip playing; Match_Phase: at the phase of its markers"`,
    phase:f32 `mirai:"optional,min=0,max=1,label=Of its duration where matching takes over again"`,
    marker:[64]u8 `mirai:"text,optional,label=A marker of the clip where matching takes over, instead of phase"`,
    priority:i16 `mirai:"optional,label=A play of lower priority than the one playing is refused"`,
    wait:bool `mirai:"optional,label=Starts when the blend that runs ends"`,
    tick:u32 `mirai:"optional,max=3600,label=In animation.preview and animation.pose.bake: the tick it is asked at"`,
}
Request_Motion :: struct {
    name:[32]u8 `mirai:"text,label=A warp window of the motion profile"`,
    target:Spatial_Target_Params `mirai:"optional,label=Where the window ends: a point (World), an entity, or a bone or socket of a rig"`,
    enabled:bool `mirai:"optional"`,
}
Request_Locomotion :: struct {
    velocity:mm.Vec3 `mirai:"unit=m/s"`,
    source_velocity:mm.Vec3 `mirai:"optional,unit=m/s"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    enabled:bool `mirai:"optional"`,
}
Request_Distance :: struct {name:[32]u8 `mirai:"text,label=A distance track of the motion profile"`,distance:f32 `mirai:"unit=m"`,seek:bool `mirai:"optional,label=Jumps to its time instead of advancing the clock with crossed events and root motion"`}
Request_Sequence :: struct {action:anim.Keyframe_Path_Command_Kind,value:f32 `mirai:"optional"`}
Hand_Side :: enum u8 {Left,Right}
Gesture_Mask :: enum u8 {Upper_Body,Arm_L,Arm_R}
Intent_Look :: struct {
    target:Spatial_Target_Params `mirai:"optional,label=What to look at"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    fade:f32 `mirai:"optional,min=0,unit=s"`,
    off:bool `mirai:"optional,label=Stops looking"`,
}
Intent_Reach :: struct {
    hand:Hand_Side,
    target:Spatial_Target_Params `mirai:"optional,label=Where the hand goes"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    fade:f32 `mirai:"optional,min=0,unit=s"`,
    off:bool `mirai:"optional,label=Lets the hand go"`,
}
Intent_Locomote :: struct {
    target:Spatial_Target_Params `mirai:"label=A point (World) or an entity to walk toward"`,
    speed:f32 `mirai:"optional,min=0,unit=m/s,label=0 walks"`,
}
Intent_Gesture :: struct {
    clip:[64]u8 `mirai:"text,label=A clip of the action profile"`,
    mask:Gesture_Mask `mirai:"optional"`,
    stop:bool `mirai:"optional"`,
}
REQUEST_ROWS :: 64
Request_Params :: struct {
    entity:base.Entity_Id,
    stop:bool `mirai:"optional,label=Stops playback where it is"`,
    seek:f32 `mirai:"optional,min=0,unit=s,label=Plays from this time on the next evaluation"`,
    parameters:[anim.GRAPH_PARAMETERS]Preview_Parameter `mirai:"optional"`,
    plays:[16]Request_Play `mirai:"optional,label=Clips of the .match to play now (a vault, a hit), in order"`,
    actions:[REQUEST_ROWS]Preview_Action `mirai:"optional"`,
    goals:[REQUEST_ROWS]Preview_Goal `mirai:"optional"`,
    controls:[REQUEST_ROWS]Preview_Control `mirai:"optional"`,
    motion:[16]Request_Motion `mirai:"optional,label=Targets of warp windows"`,
    locomotion:Request_Locomotion `mirai:"optional,label=Velocity the body travels at for orientation and stride"`,
    distance:Request_Distance `mirai:"optional,label=Plays a clip by distance left"`,
    sequence:Request_Sequence `mirai:"optional,label=Controls a Keyframe_Path sequence"`,
    locomote:Intent_Locomote `mirai:"optional,label=Walk toward a point or entity"`,
    look:Intent_Look `mirai:"optional,label=Look at something"`,
    gesture:Intent_Gesture `mirai:"optional,label=Play a gesture over the moving body"`,
    reach:[2]Intent_Reach `mirai:"optional,label=Reach with a hand"`,
}
Request_Applied :: struct {kind:[16]u8 `mirai:"text"`,name:[256]u8 `mirai:"text"`,value:f32}
Request_Result :: struct {id:base.Entity_Id,playing:bool `mirai:"optional"`,time:f32 `mirai:"optional,unit=s"`,applied:[REQUEST_ROWS]Request_Applied `mirai:"label=What the request did"`}

request_defaults :: proc() -> ^Request_Params {
    value:=new(Request_Params,context.temp_allocator);if value==nil {return nil}
    request_rows_defaults(value)
    return value
}
// Defaults of the request rows a params struct has.
request_rows_defaults :: proc(p:^$T) {
    for &play in p.plays {play.fade,play.phase=anim.MATCH_PLAY_OPTIONS_DEFAULT.fade,anim.MATCH_PLAY_OPTIONS_DEFAULT.phase}
    for &control in p.controls {control.weight,control.enabled=1,true}
    for &goal in p.goals {goal.contact,goal.grounded,goal.normal=1,true,{0,1,0};goal.target=SPATIAL_TARGET_PARAMS_DEFAULT}
    for &motion in p.motion {motion.target=SPATIAL_TARGET_PARAMS_DEFAULT;motion.enabled=true}
    p.locomotion.weight,p.locomotion.enabled=1,true
    p.look={target=SPATIAL_TARGET_PARAMS_DEFAULT,weight=1,fade=.3}
    p.locomote.target=SPATIAL_TARGET_PARAMS_DEFAULT
    for &reach in p.reach {reach={target=SPATIAL_TARGET_PARAMS_DEFAULT,weight=1,fade=.25}}
    for &reach,i in p.reach {reach.hand=Hand_Side(i)}
}

@(private)
request_register :: proc(s:^editor.Session) {
    defaults:=request_defaults();if defaults==nil {return}
    authoring_method_register(s,{name="animation.request",summary="Asks an animated entity what to do, from playback, graph parameters and clips of its .match to intents. Edit takes only stop, parameters and sequence play, pause and speed; the rest needs Play or Simulation.",params=Request_Params,params_info=type_info_of(Request_Params),defaults=defaults,run=request},Request_Result,type_info_of(Request_Result))
}

// Fields of a request that change the document in Edit; the rest change only a running world.
@(private)
request_runtime_field :: proc(call:^api.Call) -> string {
    for field in ([?]string{"seek","plays","actions","goals","controls","motion","locomotion","distance","locomote","look","gesture","reach"}) {
        if authoring_field_present(call,field) {return field}
    }
    if authoring_field_present(call,"sequence") {
        value,_:=authoring_json_field(call.raw,"sequence",call.allocator)
        if strings.contains(value,"Restart") || strings.contains(value,"Seek") {return "sequence"}
    }
    return ""
}

@(private)
request :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Request_Params)
    if s.mode==.Edit {
        if field:=request_runtime_field(call);field!="" {
            authoring_failure(call,field,"Runtime_Required","Play or Simulation","Edit",fmt.tprintf("%s changes only a running world",field),fix="Start Play or Simulation, or try it on a copy with animation.preview and the same fields")
            return
        }
    }
    w,e,ok:=subject(s,call,p.entity);if !ok {return}
    e=pose_owner(s,w,e)
    applied:=make([dynamic]Request_Applied,call.allocator)
    if !edit_begin(s,call,"Animation request") {return}
    if !request_apply(s,call,w,e,p,0,&applied) {
        // The failure says what was wrong; an Edit gesture only closes.
        if s.mode==.Edit {editor.api_edit_end(s,call,false)}
        return
    }
    if s.mode==.Edit && !edit_end(s,call,w,true) {return}
    out:=call.out
    serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,p.entity)
    if value,has:=editor.entity_get(w,e,anim.Animation);has {api.write_bool(out,"playing",value.playing)}
    if time,_,_,has:=anim.animation_progress(core.world_storage_of(w,anim.Playback),e);has {api.write_key(out,"time");api.write_number(out,time)}
    api.write_key(out,"applied");serial.text_write_raw(out,"[")
    for &value,i in applied {
        if i>0 {serial.text_write_raw(out,",")}
        serial.text_write_raw(out,"{");api.write_text(out,"kind",base.text_get(value.kind[:]),true);api.write_text(out,"name",base.text_get(value.name[:]));api.write_key(out,"value");api.write_number(out,value.value);serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]}")
}

@(private)
request_note :: proc(applied:^[dynamic]Request_Applied,kind,name:string,value:f32=0) {
    if applied==nil || len(applied)>=REQUEST_ROWS {return}
    row:Request_Applied
    base.text_set(row.kind[:],kind);base.text_set(row.name[:],name);row.value=value
    append(applied,row)
}

// Validates a request and applies what it asks now: to the running world, or
// to a copy (ticks is how long it runs; plays and actions of later ticks
// wait for request_tick). The entity is the rig.
@(private)
request_apply :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,p:^$T,ticks:u32,applied:^[dynamic]Request_Applied) -> bool {
    count,_:=api.params_array_count(call,"parameters")
    controls,_:=api.params_array_count(call,"controls")
    plays,_:=api.params_array_count(call,"plays")
    goals,_:=api.params_array_count(call,"goals")
    actions,_:=api.params_array_count(call,"actions")
    motions,_:=api.params_array_count(call,"motion")
    reaches,_:=api.params_array_count(call,"reach")
    animation,present:=editor.entity_get(world,entity,anim.Animation)
    needs:=count>0 || plays>0 || actions>0 || authoring_field_present(call,"locomote") || authoring_field_present(call,"gesture") || authoring_field_present(call,"distance") || authoring_field_present(call,"stop") || authoring_field_present(call,"seek")
    if needs && !present {authoring_failure(call,"entity","Missing_Component","an Animation component","missing component","The entity plays nothing",fix="Assign playback with animation.play or animation.character.setup");return false}
    changed:=false
    when intrinsics.type_has_field(T,"stop") {
        if authoring_field_present(call,"stop") && p.stop {animation.playing=false;changed=true;request_note(applied,"Stop","")}
    }
    for &parameter in p.parameters[:count] {
        name:=base.text_get(parameter.name[:])
        if !program_parameter_check(s,call,animation,name,parameter.value) {return false}
        if !anim.animation_parameter(&animation,name,parameter.value) {authoring_failure(call,"parameters","Capacity",fmt.tprintf("at most %d parameters set",anim.GRAPH_PARAMETERS),name,"The parameter could not be set");return false}
        changed=true;request_note(applied,"Parameter",name,parameter.value)
    }
    if changed {core.add(core.world_table_of(world,anim.Animation),entity,animation);core.world_settle(world)}
    when intrinsics.type_has_field(T,"seek") {
        if authoring_field_present(call,"seek") {
            requested:=core.world_storage_of(world,anim.Animation_Requests)
            waiting:=len(requested.seeks.items)
            anim.animation_seek(requested,entity,p.seek)
            if len(requested.seeks.items)==waiting {authoring_failure(call,"seek","Request_Failed","a finite nonnegative time and available seek queue",fmt.tprintf("%v",p.seek),"The seek could not be queued",api.SERVER_ERROR);return false}
            request_note(applied,"Seek","",p.seek)
        }
    }
    if plays>0 && !request_plays_check(s,call,world,entity,animation,p.plays[:plays],ticks) {return false}
    if actions>0 || authoring_field_present(call,"gesture") {
        if animation.actions=={} {authoring_failure(call,"actions" if actions>0 else "gesture","Missing_Profile","Animation.actions assigned","none","The entity has no action profile",fix="Create gestures with animation.character.setup, or assign an .action to Animation.actions");return false}
        file:Authoring_File;defer asset.asset_close(&file.file);profile,ok:=action_authoring_open(s,call,animation.actions,&file);if !ok {return false}
        for &action,i in p.actions[:actions] {
            if action.tick>ticks {authoring_failure(call,fmt.tprintf("actions[%d].tick",i),"Out_Of_Range",fmt.tprintf("0 to %d",ticks),fmt.tprintf("%d",action.tick),"An action tick cannot exceed the ticks that run",fix="Ticks schedule actions in animation.preview; a request queues them now");return false}
            index:=action_named_index(profile.actions,action.name)
            if index<0 {authoring_failure(call,fmt.tprintf("actions[%d].name",i),"Missing_Reference","an action name",base.text_get(action.name[:]),"The action does not exist",fix=request_action_names(profile.actions));return false}
            if action.kind==.Fire && !action_control_policy(call,profile.actions[index],animation,fmt.tprintf("actions[%d].name",i)) {return false}
            if action.kind==.Section || action.section!=([64]u8{}) {
                found:=false;for section in profile.sections {if int(section.action)==index && section.name==action.section {found=true;break}}
                if !found {authoring_failure(call,fmt.tprintf("actions[%d].section",i),"Missing_Reference","a section of the requested action",base.text_get(action.section[:]),"The action section does not exist");return false}
            }
        }
        if authoring_field_present(call,"gesture") {
            name:=base.text_get(p.gesture.clip[:])
            if p.gesture.mask!=.Upper_Body {name=fmt.tprintf("%s %v",name,p.gesture.mask)}
            index:=-1
            for &action,i in profile.actions {if base.text_get(action.name[:])==name {index=i;break}}
            if index<0 {authoring_failure(call,"gesture.clip","Missing_Reference","a gesture of the action profile",name,"The character has no such gesture",fix=request_action_names(profile.actions));return false}
            kind:=anim.Action_Request_Kind.Cancel if p.gesture.stop else .Fire
            if kind==.Fire && !action_control_policy(call,profile.actions[index],animation,"gesture.clip") {return false}
            requested:=core.world_storage_of(world,anim.Action_Requests)
            waiting:=len(requested.queue.items)
            anim.action_request(requested,entity,kind,name,"")
            if len(requested.queue.items)==waiting {authoring_failure(call,"gesture","Capacity","space in the action queue","full or unavailable","The gesture could not be queued",api.SERVER_ERROR);return false}
            request_note(applied,"Gesture",name)
        }
    }
    modifiers:=core.world_storage_of(world,anim.Modifier_Requests)
    for &control,i in p.controls[:controls] {
        file:Authoring_File;defer asset.asset_close(&file.file)
        profile,ok:=program_modifier_profile(s,call,world,entity,control.kind,&file);if !ok {return false}
        slot,valid:=program_modifier_slot(call,profile,control.kind,control.name[:]);if !valid {return false}
        if !finite(control.weight) || control.weight<0 || control.weight>1 {authoring_failure(call,fmt.tprintf("controls[%d].weight",i),"Range","a finite number in [0,1]",fmt.tprintf("%g",control.weight),"The control weight is invalid");return false}
        if !finite(control.fade) || control.fade<0 {authoring_failure(call,fmt.tprintf("controls[%d].fade",i),"Range","finite nonnegative seconds",fmt.tprintf("%g",control.fade),"The control fade is invalid");return false}
        waiting:=len(modifiers.controls.items)
        anim.modifier_control(modifiers,{rig=entity,kind=control.kind,slot=slot,name=control.name,weight=control.weight,enabled=control.enabled,fade=control.fade})
        if len(modifiers.controls.items)==waiting {authoring_failure(call,"controls","Capacity","space in Modifier_Requests.controls","full or unavailable","The control could not be queued",api.SERVER_ERROR);return false}
        request_note(applied,"Control",base.text_get(control.name[:]),control.weight)
    }
    if goals>0 {
        text,_:=authoring_json_field(call.raw,"goals",call.allocator)
        for &goal,i in p.goals[:goals] {
            file:Authoring_File;defer asset.asset_close(&file.file)
            profile,ok:=program_modifier_profile(s,call,world,entity,program_modifier_goal_kind(goal.kind),&file);if !ok {return false}
            raw,_:=authoring_json_element(text,i,call.allocator)
            value,valid:=program_modifier_goal_value(s,call,world,entity,profile,&goal,raw,fmt.tprintf("goals[%d]",i));if !valid {return false}
            waiting:=len(modifiers.queue.items)
            anim.modifier_goal(modifiers,value)
            if len(modifiers.queue.items)==waiting {authoring_failure(call,"goals","Capacity","space in Modifier_Requests.goals","full or unavailable","The goal could not be queued",api.SERVER_ERROR);return false}
            request_note(applied,"Goal",base.text_get(goal.name[:]))
        }
    }
    if authoring_field_present(call,"look") {
        raw,_:=authoring_json_field(call.raw,"look",call.allocator)
        if !request_aim(s,call,world,entity,.Look,.Head,p.look.target,p.look.weight,p.look.fade,p.look.off,raw,"look",applied) {return false}
    }
    if reaches>0 {
        text,_:=authoring_json_field(call.raw,"reach",call.allocator)
        for &reach,i in p.reach[:min(reaches,len(p.reach))] {
            raw,_:=authoring_json_element(text,i,call.allocator)
            hand:=lib.Body_Part.Hand_L if reach.hand==.Left else .Hand_R
            if !request_aim(s,call,world,entity,.IK,hand,reach.target,reach.weight,reach.fade,reach.off,raw,fmt.tprintf("reach[%d]",i),applied) {return false}
        }
    }
    if motions>0 || authoring_field_present(call,"locomotion") || authoring_field_present(call,"distance") || authoring_field_present(call,"locomote") {
        if animation.motion=={} {
            authoring_failure(call,"Animation.motion","Missing_Profile","an Animation component referencing a .motion profile","none","The entity has no motion profile",fix="Create one with animation.character.setup (want Locomotion) or animation.motion.set with path");return false
        } else {
            file:Authoring_File;defer asset.asset_close(&file.file)
            profile,ok:=motion_authoring_open(s,call,animation.motion,&file);if !ok {return false}
            requests:=core.world_storage_of(world,anim.Motion_Requests)
            for &motion,i in p.motion[:motions] {
                declared:=false;for &window in profile.windows {if window.name==motion.name {declared=true;break}}
                if !declared {authoring_failure(call,fmt.tprintf("motion[%d].name",i),"Missing_Target","a target name declared by a warp window",base.text_get(motion.name[:]),"The warp target is undeclared");return false}
                target,valid:=spatial_target_value(call,world,motion.target,fmt.tprintf("motion[%d].target",i));if !valid {return false}
                waiting:=len(requests.targets.items)
                anim.motion_target(requests,entity,base.text_get(motion.name[:]),target,motion.enabled)
                if len(requests.targets.items)==waiting {authoring_failure(call,fmt.tprintf("motion[%d]",i),"Capacity","space in Motion_Requests.targets","full or unavailable","The warp target could not be queued",api.SERVER_ERROR);return false}
                request_note(applied,"Motion",base.text_get(motion.name[:]))
            }
            if authoring_field_present(call,"locomotion") {
                value:=p.locomotion
                waiting:=len(requests.locomotion.items)
                anim.motion_locomotion(requests,{rig=entity,velocity=value.velocity,source_velocity=value.source_velocity,weight=value.weight,enabled=value.enabled})
                if len(requests.locomotion.items)==waiting {authoring_failure(call,"locomotion","Rejected_Request","finite velocities, weight in [0,1] and queue capacity","invalid data or capacity","The locomotion input was rejected");return false}
                request_note(applied,"Locomotion","",linalg.length(value.velocity))
            }
            if authoring_field_present(call,"distance") {
                name:=base.text_get(p.distance.name[:])
                time,clip,valid:=anim.motion_distance_time(profile,name,p.distance.distance)
                if !valid {authoring_failure(call,"distance","Invalid_Distance","a distance track of the motion profile and a finite distance",name,"The distance track cannot be evaluated",fix="List the tracks with animation.asset.inspect section motion");return false}
                state:^anim.Playing
                if playback:=core.world_storage_of(world,anim.Playback);playback!=nil {for &value in playback.states {if value.entity==entity {state=&value;break}}}
                if state!=nil {
                    content:=anim.animation_playing_content(core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Source_Assets),s.app,state)
                    query:=anim.Animation_Distance_Request{entity=entity,clip=base.name_hash(base.text_get(clip[:])),time=time,seek=p.distance.seek,animation=anim.motion_distance_source(profile,name)}
                    if error:=anim.distance_request_check(state,content,query,core.world_storage_of(world,anim.Action_Runtime));error!=.None {authoring_failure(call,"distance",fmt.tprintf("%v",error),"the active source clip and a forward interval; seek allows a discontinuity",base.text_get(clip[:]),"The active animation clock cannot accept this distance",fix="Pass seek true to jump, or a distance ahead of the clock");return false}
                }
                requested:=core.world_storage_of(world,anim.Animation_Requests)
                waiting:=len(requested.distances.items)
                anim.motion_play_distance(requested,entity,profile,name,p.distance.distance,p.distance.seek)
                if len(requested.distances.items)==waiting {authoring_failure(call,"distance","Invalid_Distance","a distance track of the motion profile and a finite distance",name,"The distance playback could not be queued",fix="List the tracks with animation.asset.inspect section motion");return false}
                request_note(applied,"Distance",name,p.distance.distance)
            }
            if authoring_field_present(call,"locomote") {
                position,ok:=request_target_position(call,world,p.locomote.target,"locomote.target");if !ok {return false}
                placed:=editor.entity_world(world,entity)
                toward:=position-placed.position;toward.y=0
                speed:=p.locomote.speed if p.locomote.speed>0 else 1.3
                if !finite(speed) {authoring_failure(call,"locomote.speed","Invalid_Value","finite m/s",fmt.tprintf("%v",speed),"The speed is invalid");return false}
                direction:=linalg.normalize0(toward)
                // The clip travels the way the body faces; the warp turns it toward the target.
                _,forward:=request_body(s,world,entity,.Pelvis)
                facing:=mm.quat_rotate(placed.rotation,forward);facing.y=0
                waiting:=len(requests.locomotion.items)
                anim.motion_locomotion(requests,{rig=entity,velocity=direction*speed,source_velocity=linalg.normalize0(facing)*speed,weight=1,enabled=true})
                if len(requests.locomotion.items)==waiting {authoring_failure(call,"locomote","Rejected_Request","a finite target and queue capacity","rejected","The locomotion input was rejected",api.SERVER_ERROR);return false}
                request_note(applied,"Locomotion","",speed)
                for &window in profile.windows {
                    if base.text_get(window.name[:])!="locomote" {continue}
                    waiting:=len(requests.targets.items)
                    anim.motion_target(requests,entity,"locomote",anim.spatial_point(position))
                    if len(requests.targets.items)==waiting {authoring_failure(call,"locomote","Rejected_Request","queue capacity","full","The locomotion target was rejected",api.SERVER_ERROR);return false}
                    request_note(applied,"Motion","locomote")
                    break
                }
            }
        }
    }
    when intrinsics.type_has_field(T,"sequence") {
        if authoring_field_present(call,"sequence") {
            value,has:=editor.entity_get(world,entity,anim.Keyframe_Path)
            if !has {authoring_failure(call,"sequence","Missing_Component","a Keyframe_Path component","missing component","The entity has no Keyframe_Path sequence");return false}
            if !finite(p.sequence.value) {authoring_failure(call,"sequence.value","Invalid_Value","a finite value",fmt.tprintf("%v",p.sequence.value),"The sequence value is invalid");return false}
            if s.mode==.Edit {
                #partial switch p.sequence.action {
                case .Play: value.playing=true
                case .Pause: value.playing=false
                case .Speed: value.speed=p.sequence.value
                }
                core.add(core.world_table_of(world,anim.Keyframe_Path),entity,value)
            } else {
                requested:=core.world_storage_of(world,anim.Keyframe_Path_Requests)
                waiting:=len(requested.queue.items)
                anim.keyframe_path_request(requested,entity,p.sequence.action,p.sequence.value)
                if len(requested.queue.items)==waiting {authoring_failure(call,"sequence","Capacity","an available sequence queue","full or unavailable queue","The sequence request could not be queued",api.SERVER_ERROR);return false}
            }
            request_note(applied,"Sequence",fmt.tprintf("%v",p.sequence.action),p.sequence.value)
        }
    }
    return request_tick(call,world,entity,p,0,applied)
}

// Checks the plays of a request: the rig plays a .match whose library has their clips and markers,
// with options in range and modes of the project.
@(private)
request_plays_check :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,animation:anim.Animation,plays:[]Request_Play,ticks:u32) -> bool {
    record,found:=asset.registry_find(&s.app.assets.registry,animation.asset)
    if !found || record.kind!=anim.MATCH_KIND {authoring_failure(call,"plays","Not_Matching","an Animation.asset that is a .match","another asset" if found else "none","The entity plays no motion matching",fix="Make one with animation.character.setup, or assign a .match with animation.play");return false}
    source,ok:=program_source(s,call,animation.asset,animation.library);if !ok {return false}
    file:Authoring_File;defer asset.asset_close(&file.file)
    view,opened:=program_animation_open(s,call,source,&file);if !opened {return false}
    modes:=locomotion_modes(world.info)
    for &play,i in plays {
        path:=fmt.tprintf("plays[%d]",i)
        if play.tick>ticks {authoring_failure(call,fmt.tprintf("%s.tick",path),"Out_Of_Range",fmt.tprintf("0 to %d",ticks),fmt.tprintf("%d",play.tick),"A play tick cannot exceed the ticks that run",fix="Ticks schedule plays in animation.preview; a request plays them now");return false}
        clip:=-1;for &value,c in view.clips {if base.text_get(value.name[:])==base.text_get(play.clip[:]) {clip=c;break}}
        if clip<0 {authoring_failure(call,fmt.tprintf("%s.clip",path),"Missing_Clip","a clip of the library of the .match",base.text_get(play.clip[:]),"The library of the .match has no such clip",fix=request_clip_names(view));return false}
        if marker:=base.text_get(play.marker[:]);marker!="" {
            known:=false;for &value in view.markers[view.clips[clip].first_marker:][:view.clips[clip].marker_count] {if base.text_get(value.name[:])==marker {known=true;break}}
            if !known {authoring_failure(call,fmt.tprintf("%s.marker",path),"Missing_Marker","a marker of the clip",marker,"The clip has no such marker",fix="List its markers with animation.asset.inspect and the clip");return false}
        }
        if !finite(play.fade) || play.fade<0 {authoring_failure(call,fmt.tprintf("%s.fade",path),"Invalid_Value","finite seconds, zero or more",fmt.tprintf("%v",play.fade),"The fade is invalid");return false}
        if !finite(play.phase) || play.phase<0 || play.phase>1 {authoring_failure(call,fmt.tprintf("%s.phase",path),"Out_Of_Range","0 to 1",fmt.tprintf("%v",play.phase),"The phase is a share of the duration of the clip");return false}
        if name:=base.text_get(play.mode[:]);name!="" {
            if len(modes)==0 {locomotion_modes_failure(call,fmt.tprintf("%s.mode",path));return false}
            if _,known:=locomotion_mode_value(modes,name);!known {authoring_failure(call,fmt.tprintf("%s.mode",path),"Unknown_Mode","a Locomotion_Mode of the project",name,"The project has no such locomotion mode",fix=locomotion_mode_names(modes));return false}
        }
    }
    return true
}

@(private)
request_clip_names :: proc(view:asset.Animation_View) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for &clip in view.clips[:min(len(view.clips),16)] {append(&names,base.text_get(clip.name[:]))}
    return fmt.tprintf("Clips: %s",strings.join(names[:],", ",context.temp_allocator))
}

// Queues the plays and actions of a tick.
@(private)
request_tick :: proc(call:^api.Call,world:core.World_Ref,entity:core.Entity,p:^$T,tick:u32,applied:^[dynamic]Request_Applied=nil) -> bool {
    plays,_:=api.params_array_count(call,"plays")
    for &play in p.plays[:plays] {
        if play.tick!=tick {continue}
        mode,known:=locomotion_mode_value(locomotion_modes(world.info),base.text_get(play.mode[:]))
        if !known {if value,matching:=anim.animation_match(core.world_storage_of(world,anim.Playback),entity);matching {mode=value.mode}}
        options:=anim.Match_Play_Options{fade=play.fade,entry=play.entry,phase=play.phase,marker=base.text_get(play.marker[:]),priority=play.priority,wait=play.wait}
        requested:=core.world_storage_of(world,anim.Animation_Requests)
        waiting:=len(requested.match_plays.items)
        anim.match_play(requested,entity,base.text_get(play.clip[:]),mode,options)
        if len(requested.match_plays.items)==waiting {authoring_failure(call,"plays","Capacity","an available play queue","full or unavailable queue","The play could not be queued",api.SERVER_ERROR);return false}
        request_note(applied,"Play",base.text_get(play.clip[:]),play.fade)
    }
    actions,_:=api.params_array_count(call,"actions")
    for &action in p.actions[:actions] {
        if action.tick!=tick {continue}
        requested:=core.world_storage_of(world,anim.Action_Requests)
        waiting:=len(requested.queue.items)
        anim.action_request(requested,entity,action.kind,base.text_get(action.name[:]),base.text_get(action.section[:]))
        if len(requested.queue.items)==waiting {authoring_failure(call,"actions","Capacity","space in the action queue","full or unavailable","The action could not be queued",api.SERVER_ERROR);return false}
        request_note(applied,fmt.tprintf("%v",action.kind),base.text_get(action.name[:]))
    }
    return true
}

// Where a target is in the world now: a point or an entity.
@(private)
request_target_position :: proc(call:^api.Call,world:core.World_Ref,target:Spatial_Target_Params,path:string) -> (mm.Vec3,bool) {
    #partial switch target.kind {
    case .World: return target.position,true
    case .Entity:
        e:=find_entity(world,target.entity)
        if e==core.NONE {authoring_failure(call,fmt.tprintf("%s.entity",path),"Missing_Reference","an entity of the world",fmt.tprintf("%x",target.entity),"The target entity does not exist");return {},false}
        return mm.transform_point(editor.entity_world(world,e),target.position),true
    }
    authoring_failure(call,fmt.tprintf("%s.kind",path),"Unsupported_Target","World or Entity",fmt.tprintf("%v",target.kind),"Walking needs a point or an entity",fix="Pass target {\"kind\":\"World\",\"position\":[x,y,z]} or {\"kind\":\"Entity\",\"entity\":\"<id>\"}")
    return {},false
}

// Look and reach: the goal of the operation that turns the part, and the
// control that brings it in or out.
@(private)
request_aim :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,kind:anim.Modifier_Kind,part:lib.Body_Part,target:Spatial_Target_Params,weight,fade:f32,off:bool,raw,path:string,applied:^[dynamic]Request_Applied) -> bool {
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=program_modifier_profile(s,call,world,entity,kind,&file);if !ok {return false}
    slot,found:=request_operation(s,world,entity,profile,kind,part)
    if !found {
        what:="Look" if kind==.Look else "IK"
        authoring_failure(call,path,"Missing_Operation",fmt.tprintf("a %s operation on %v in the pose profile",what,part),"none","The character cannot do this yet",fix=fmt.tprintf("Run animation.character.setup with want %s, or add the operation with pose.profile.set","Look" if kind==.Look else "Hand_Ik"))
        return false
    }
    definition,_:=program_modifier_definition(profile,kind,slot)
    requests:=core.world_storage_of(world,anim.Modifier_Requests)
    if !off {
        goal:=Preview_Goal{kind=.Look if kind==.Look else .IK,name=definition.name,target=target}
        value,valid:=program_modifier_goal_value(s,call,world,entity,profile,&goal,raw,path);if !valid {return false}
        // Asking for it turns on an operation the profile keeps off until asked.
        value.enabled=true
        waiting:=len(requests.queue.items)
        anim.modifier_goal(requests,value)
        if len(requests.queue.items)==waiting {authoring_failure(call,path,"Capacity","space in Modifier_Requests.goals","full or unavailable","The goal could not be queued",api.SERVER_ERROR);return false}
    }
    waiting:=len(requests.controls.items)
    anim.modifier_control(requests,{rig=entity,kind=kind,slot=slot,name=definition.name,weight=0 if off else weight,enabled=!off,fade=fade})
    if len(requests.controls.items)==waiting {authoring_failure(call,path,"Capacity","space in Modifier_Requests.controls","full or unavailable","The control could not be queued",api.SERVER_ERROR);return false}
    request_note(applied,"Look" if kind==.Look else "Reach",base.text_get(definition.name[:]),0 if off else weight)
    return true
}

// The operation of a kind that moves a body part: the one on its bone, else
// the only one of the kind.
@(private)
request_operation :: proc(s:^editor.Session,world:core.World_Ref,entity:core.Entity,profile:anim.Pose_Profile,kind:anim.Modifier_Kind,part:lib.Body_Part) -> (slot:u16,found:bool) {
    count:=program_modifier_count(profile,kind)
    if count==0 {return}
    bone:=request_body_bone(s,world,entity,part)
    label:=anim.bone_ref_part(part)
    for index in 0..<count {
        reference:anim.Bone_Ref
        #partial switch kind {
        case .Look: reference=profile.look[index].bone
        case .IK: reference=profile.ik[index].end
        }
        if bone!="" && (base.text_get(reference.path[:])==bone || reference==label) {return u16(index),true}
    }
    if count==1 && kind==.Look {return 0,true}
    return
}

// The bone path of a body part of the skeleton the rig shows, or "".
@(private)
request_body_bone :: proc(s:^editor.Session,world:core.World_Ref,entity:core.Entity,part:lib.Body_Part) -> string {
    bone,_:=request_body(s,world,entity,part)
    return bone
}

// The path of a body part of the skeleton the rig shows ("" without it) and
// the way the body faces in the space of the rig.
@(private)
request_body :: proc(s:^editor.Session,world:core.World_Ref,entity:core.Entity,part:lib.Body_Part) -> (bone:string,forward:mm.Vec3) {
    forward={0,0,-1}
    id:=rig_skeleton(s,world,entity)
    if id=={} || s.app==nil || s.app.assets==nil {return}
    file:asset.Asset
    if host.assets_file(s.app.assets,id,asset.KIND_SKELETON,&file)!=.None {return}
    defer asset.asset_close(&file)
    view,error:=asset.skeleton_view(&file,&s.app.assets.types)
    if error!=.None {return}
    map_:=asset.skeleton_body_map(view.bones,view.body,view.body_parts)
    forward=map_.forward
    if index:=map_.bones[part];index>=0 {bone=strings.clone(base.text_get(view.bones[index].path[:]),context.temp_allocator)}
    return
}

@(private)
request_action_names :: proc(actions:[]anim.Action_Definition) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for &action in actions[:min(len(actions),16)] {append(&names,base.text_get(action.name[:]))}
    return fmt.tprintf("Actions and gestures: %s",strings.join(names[:],", ",context.temp_allocator))
}

// A copy evaluates its animation: its source has to load.
@(private)
request_source_check :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity) -> bool {
    animation,present:=editor.entity_get(world,entity,anim.Animation)
    if !present || animation.asset=={} {return true}
    source,ok:=program_source(s,call,animation.asset,animation.library);if !ok {return false}
    if host.content_animation_wait(s.app,source)==nil {authoring_failure(call,"asset","Invalid_Asset","a loadable source .anim","source load failed","The animation source could not be loaded");return false}
    return true
}

// Runs an entity on a copy of the shown world with the requests of p (the
// fields of animation.preview): from time, ticks of dt, calling each with the
// copy after the first pose (tick 0) and after every tick. The entity is the
// rig. False, with the call failed, when the copy cannot run or each says so.
preview_run :: proc(s:^editor.Session,call:^api.Call,id:base.Entity_Id,p:^$T,time:f32,ticks:u32,dt:f32,each:proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,tick:u32,data:rawptr) -> bool,data:rawptr) -> bool {
    source,e,ok:=subject(s,call,id);if !ok {return false}
    e=pose_owner(s,source,e)
    if !editor.entity_has(source,e,anim.Animation) && rig_skeleton(s,source,e)=={} {authoring_failure(call,"entity","Missing_Component","Animation or a mesh with a skeleton","missing both","The entity has no Animation and shows no mesh with a skeleton");return false}
    clone:=preview_world_clone(s,call,source);if clone==nil {return false}
    defer host.app_world_free(s.app,clone)
    world:=core.world_ref(clone,s.info)
    if !request_source_check(s,call,world,e) || !request_apply(s,call,world,e,p,ticks,nil) {return false}
    requests:=core.world_storage_of(world,anim.Animation_Requests)
    if requests!=nil {anim.animation_seek(requests,e,time)}
    if requests==nil || !anim.animation_evaluate(world,s.app,0) {authoring_failure(call,"preview","Evaluation_Failed","an evaluable copy of the world","initial evaluation failed","The copy could not be evaluated",api.SERVER_ERROR);return false}
    if !each(s,call,world,e,0,data) {return false}
    for tick in 1..=ticks {
        if !request_tick(call,world,e,p,tick) {return false}
        if !anim.animation_evaluate(world,s.app,dt) {authoring_failure(call,"preview","Evaluation_Failed","an evaluable copy of the world",fmt.tprintf("tick %d",tick),"The copy could not advance",api.SERVER_ERROR);return false}
        if !each(s,call,world,e,tick,data) {return false}
    }
    return true
}
