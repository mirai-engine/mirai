package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Motion_Distance_Params :: struct {clip:[64]u8 `mirai:"text"`,name:[32]u8 `mirai:"text"`,keys:[256]lib.Distance_Key,animation:base.Asset_Id `mirai:"optional"`}
Motion_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .character: its warping is replaced, its other parts kept"`,
    animation:base.Asset_Id `mirai:"optional,label=The .anim of the clips of a new .character"`,
    warp:anim.Pose_Warp_Profile `mirai:"optional,label=Pose warping of the pelvis, spine and legs of the body of the skeleton"`,
    windows:[anim.MOTION_WINDOWS]anim.Motion_Window `mirai:"optional,label=Warp windows: each, the spans of that name on the clips and the target of that name they reach; omitted is none"`,
    distances:[anim.MOTION_WINDOWS]Motion_Distance_Params `mirai:"optional,label=Tracks of strictly monotonic distance and time keys; omitted is none"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Motion_Distance_Params_Query :: struct {asset:base.Asset_Id,name:[32]u8 `mirai:"text"`,distance:f32 `mirai:"unit=m,label=Outside the track it clamps to its ends"`}
Motion_Distance_Result :: struct {clip:[64]u8 `mirai:"text"`,time:f32 `mirai:"unit=s"`,animation:base.Asset_Id}

motion_write_defaults :: proc() -> ^Motion_Write_Params {
    value:=new(Motion_Write_Params,context.temp_allocator);if value==nil {return nil}
    value.warp=anim.POSE_WARP_PROFILE_DEFAULT
    for &window in value.windows {window=anim.MOTION_WINDOW_DEFAULT}
    return value
}

authoring_motion_register :: proc(s:^editor.Session) {
    defaults:=motion_write_defaults();if defaults==nil {return}
    editor.api_method_register(s,Motion_Write_Params,Authoring_Write_Result,{name="animation.motion.set",summary="Replaces the warping of a .character that entities share: pose warping, warp windows over the spans of clips and distance tracks. An invalid one changes nothing. In Edit.",defaults=defaults,run=authoring_motion_set,writes_result=true})
    editor.api_method_register(s,Motion_Distance_Params_Query,Motion_Distance_Result,{name="animation.motion.distance",summary="The clip and time at which a distance track of a .character reaches a distance, without advancing the world.",flags={.Read_Only},run=authoring_motion_distance})
}

@(private)
motion_authoring_definition :: proc(call:^api.Call,p:^Motion_Write_Params) -> (profile:anim.Motion_Profile,ok:bool) {
    window_count,_:=api.params_array_count(call,"windows");distance_count,_:=api.params_array_count(call,"distances")
    if window_count>anim.MOTION_WINDOWS || distance_count>anim.MOTION_WINDOWS {authoring_failure(call,"windows/distances","Capacity","at most 64 entries","too many entries","Motion capacity exceeded");return}
    profile.warp=p.warp
    profile.windows=make([]anim.Motion_Window,window_count,call.allocator)
    profile.distances=make([]anim.Motion_Distance,distance_count,call.allocator)
    profile.keys=make([]lib.Distance_Key,anim.MOTION_KEYS,call.allocator)
    if window_count>0 && profile.windows==nil || distance_count>0 && profile.distances==nil || profile.keys==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for motion tables","allocation failed","The motion definition could not be allocated",api.SERVER_ERROR);return}
    copy(profile.windows,p.windows[:window_count])
    tracks_text:=api.json_member(call.raw,"distances")
    reader:serial.Text_Reader;serial.text_reader_init(&reader,tracks_text,call.allocator);defer serial.text_reader_destroy(&reader)
    if distance_count>0 && !serial.text_expect(&reader,'[') {return}
    key_count:=0
    for &track,i in p.distances[:distance_count] {
        start:=reader.offset;if !serial.text_skip(&reader) {return}
        nested:=api.Call{raw=tracks_text[start:reader.offset],allocator=call.allocator};count,_:=api.params_array_count(&nested,"keys")
        if count<2 || count>256 || count>anim.MOTION_KEYS-key_count {authoring_failure(call,fmt.tprintf("distances[%d].keys",i),"Capacity","2 to 256 keys; at most 4096 total",fmt.tprintf("%d",count),"Invalid distance key capacity");return}
        if !lib.distance_track_validate(track.keys[:count]) {authoring_failure(call,fmt.tprintf("distances[%d].keys",i),"Nonmonotonic","strictly increasing time and strictly monotonic distance","duplicate, unsorted or nonfinite keys","Distance cannot be inverted unambiguously");return}
        profile.distances[i]={clip=track.clip,name=track.name,first=u32(key_count),count=u32(count),animation=track.animation}
        copy(profile.keys[key_count:][:count],track.keys[:count]);key_count+=count
        if i+1<distance_count {if !serial.text_expect(&reader,',') {return}}
    }
    profile.keys=profile.keys[:key_count]
    if !anim.motion_profile_check(profile) {authoring_failure(call,"definition","Invalid_Profile","windows of names no other has, and stride and angle ranges","invalid warping","Warping validation failed");return}
    return profile,true
}

@(private)
authoring_motion_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Motion_Write_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,id,ok:=character_target(s,call,base.text_get(p.path[:]),p.animation,&file);if !ok {return}
    profile,valid:=motion_authoring_definition(call,p);if !valid {return}
    set.motion=profile
    _=character_publish(s,call,file,id,set)
}

@(private)
authoring_motion_distance :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Motion_Distance_Params_Query);file:Authoring_File;defer asset.asset_close(&file.file)
    set,ok:=character_open(s,call,p.asset,&file);if !ok {return}
    profile:=set.motion
    time,clip,valid:=anim.motion_distance_time(profile,base.text_get(p.name[:]),p.distance)
    if !valid {authoring_failure(call,"name/distance","Missing_Track","a named distance track and finite distance",base.text_get(p.name[:]),"The distance query is invalid");return}
    api.call_result(call,Motion_Distance_Result)^={clip=clip,time=time,animation=anim.motion_distance_source(profile,base.text_get(p.name[:]))}
}

@(private)
authoring_motion_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params);world,entity,ok:=subject(s,call,p.entity[:],p.handle);if !ok {return}
    instance,ready:=anim.motion_inspect(core.world_storage_of(world,anim.Motion_Runtime),entity)
    serial.text_write_raw(call.out,"{");api.write_key(call.out,"id",true);api.write_id(call.out,editor.api_entity_id(world,entity))
    api.write_key(call.out,"profile");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,instance.profile);serial.write_u8(call.out,'"')
    api.write_bool(call.out,"ready",ready);api.write_int(call.out,"window",i64(instance.window));api.write_key(call.out,"error");authoring_write_value(call,&instance.error,type_info_of(anim.Motion_Error))
    api.write_key(call.out,"remaining_error");api.write_number(call.out,instance.remaining_error);api.write_numbers(call.out,"source_velocity",instance.source_velocity)
    goal:=instance.locomotion
    api.write_key(call.out,"locomotion");serial.text_write_raw(call.out,"{");api.write_numbers(call.out,"velocity",goal.velocity,true);api.write_numbers(call.out,"source_velocity",goal.source_velocity)
    api.write_key(call.out,"weight");api.write_number(call.out,goal.weight);api.write_bool(call.out,"enabled",goal.enabled);serial.text_write_raw(call.out,"}")
    api.write_uint(call.out,"targets_total",u64(len(instance.targets)));api.write_key(call.out,"targets");serial.text_write_raw(call.out,"[")
    ids:=core.world_table_of(world,core.Id)
    for &target,i in instance.targets {
        if i>0 {serial.text_write_raw(call.out,",")};serial.text_write_raw(call.out,"{");api.write_text(call.out,"name",base.text_get(target.name[:]),true)
        named:=SPATIAL_TARGET_PARAMS_DEFAULT
        named.kind=target.target.kind;named.bone=target.target.bone;named.socket=target.target.socket
        named.position,named.rotation,named.scale=target.target.position,target.target.rotation,target.target.scale
        if id,found:=core.get(ids,target.target.entity);found {base.text_set(named.entity[:],fmt.tprintf("%016x",u64(id.value)))}
        api.write_key(call.out,"target");authoring_write_value(call,&named,type_info_of(Spatial_Target_Params))
        api.write_numbers(call.out,"world_position",target.world.position)
        rotation:=target.world.rotation;api.write_key(call.out,"world_rotation");authoring_write_value(call,&rotation,type_info_of(mm.Quat))
        api.write_bool(call.out,"enabled",target.enabled);api.write_bool(call.out,"resolved",target.resolved);serial.text_write_raw(call.out,"}")
    }
    serial.text_write_raw(call.out,"]}")
}
