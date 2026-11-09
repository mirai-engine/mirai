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

Motion_Pose_Params :: struct {
    pelvis:anim.Bone_Ref `mirai:"optional"`,
    spine:[16]anim.Bone_Ref `mirai:"optional"`,
    legs:[16]anim.Pose_Warp_Leg `mirai:"optional"`,
    min_stride,max_stride,max_angle,weight:f32 `mirai:"optional"`,
    orientation,stride:bool `mirai:"optional"`,
}
Motion_Window_Params :: struct {
    clip:[64]u8 `mirai:"text"`,name:[32]u8 `mirai:"text"`,
    start,end:f32 `mirai:"min=0,unit=s"`,
    translation,rotation:bool `mirai:"optional"`,
    axes:[3]bool `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    animation:base.Asset_Id `mirai:"optional"`,
}
Motion_Distance_Params :: struct {clip:[64]u8 `mirai:"text"`,name:[32]u8 `mirai:"text"`,keys:[256]lib.Distance_Key,animation:base.Asset_Id `mirai:"optional"`}
Motion_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .motion: what is there is replaced keeping its id"`,
    pose:Motion_Pose_Params `mirai:"optional,label=Pose warping: the pelvis; spine and IK legs"`,
    windows:[anim.MOTION_WINDOWS]Motion_Window_Params `mirai:"optional,label=Warp windows: each names its source clip and the target it reaches; omitted is none"`,
    distances:[anim.MOTION_WINDOWS]Motion_Distance_Params `mirai:"optional,label=Tracks of strictly monotonic distance and time keys; omitted is none"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Motion_Distance_Params_Query :: struct {asset:base.Asset_Id,name:[32]u8 `mirai:"text"`,distance:f32 `mirai:"unit=m,label=Outside the track it clamps to its ends"`}
Motion_Distance_Result :: struct {clip:[64]u8 `mirai:"text"`,time:f32 `mirai:"unit=s"`,animation:base.Asset_Id}

motion_write_defaults :: proc() -> ^Motion_Write_Params {
    value:=new(Motion_Write_Params,context.temp_allocator);if value==nil {return nil}
    value.pose={min_stride=.5,max_stride=2,max_angle=mm.PI,weight=1}
    for &window in value.windows {window.translation,window.rotation=true,true;window.axes={true,true,true};window.weight=1}
    return value
}

authoring_motion_register :: proc(s:^editor.Session) {
    defaults:=motion_write_defaults();if defaults==nil {return}
    authoring_method_register(s,{name="animation.motion.set",summary="Makes or replaces a .motion profile that entities share: warp windows, pose warping and distance tracks. An invalid one changes nothing. In Edit.",params=Motion_Write_Params,params_info=type_info_of(Motion_Write_Params),defaults=defaults,run=authoring_motion_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    editor.api_method_register(s,{name="animation.motion.distance",summary="The clip and time at which a distance track of a .motion profile reaches a distance, without advancing the world.",params=Motion_Distance_Params_Query,params_info=type_info_of(Motion_Distance_Params_Query),result=Motion_Distance_Result,result_info=type_info_of(Motion_Distance_Result),flags={.Read_Only},run=authoring_motion_distance})
}

@(private)
motion_authoring_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (anim.Motion_Profile,bool) {
    if !authoring_open(s,call,id,anim.MOTION_KIND,file) {return {},false}
    profile,error:=anim.motion_profile_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Profile","a valid .motion profile","corrupt or wrong version","The motion profile is invalid");return {},false}
    return profile,true
}

@(private)
motion_authoring_definition :: proc(call:^api.Call,p:^Motion_Write_Params) -> (profile:anim.Motion_Profile,ok:bool) {
    window_count,_:=api.params_array_count(call,"windows");distance_count,_:=api.params_array_count(call,"distances")
    if window_count>anim.MOTION_WINDOWS || distance_count>anim.MOTION_WINDOWS {authoring_failure(call,"windows/distances","Capacity","at most 64 entries","too many entries","Motion capacity exceeded");return}
    pose:=p.pose
    spine,legs:=0,0
    if text:=api.json_member(call.raw,"pose");text!="" {nested:=api.Call{raw=text,allocator=call.allocator};spine,_=api.params_array_count(&nested,"spine");legs,_=api.params_array_count(&nested,"legs")}
    if spine>16 || legs>16 {authoring_failure(call,"pose","Capacity","at most 16 spine bones and legs","too many entries","Pose warping capacity exceeded");return}
    profile.info.pose={pelvis=pose.pelvis,spine=pose.spine,spine_count=u8(spine),legs=pose.legs,count=u8(legs),min_stride=pose.min_stride,max_stride=pose.max_stride,max_angle=pose.max_angle,weight=pose.weight,orientation=pose.orientation,stride=pose.stride}
    profile.windows=make([]anim.Motion_Window,window_count,call.allocator)
    profile.distances=make([]anim.Motion_Distance,distance_count,call.allocator)
    profile.keys=make([]lib.Distance_Key,anim.MOTION_KEYS,call.allocator)
    if window_count>0 && profile.windows==nil || distance_count>0 && profile.distances==nil || profile.keys==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for motion tables","allocation failed","The motion definition could not be allocated",api.SERVER_ERROR);return}
    for &window,i in p.windows[:window_count] {profile.windows[i]={clip=window.clip,name=window.name,start=window.start,end=window.end,translation=window.translation,rotation=window.rotation,axes=window.axes,weight=window.weight,animation=window.animation}}
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
    if !anim.motion_profile_check(profile) {authoring_failure(call,"definition","Invalid_Profile","nonoverlapping windows, valid names, bones and solver ranges","invalid motion definition","Motion profile validation failed");return}
    return profile,true
}

@(private)
authoring_motion_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Motion_Write_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    id,ok:=authoring_set_target(s,call,base.text_get(p.path[:]),anim.MOTION_KIND,".motion",&file);if !ok {return}
    profile,valid:=motion_authoring_definition(call,p);if !valid {return}
    doc:asset.Document;defer asset.document_destroy(&doc)
    if error:=anim.motion_profile_document(&doc,&s.app.assets.types,id,profile,s.app.allocator);error!=.None {authoring_failure(call,"definition","Prepare_Failed","a valid serializable motion profile",fmt.tprintf("%v",error),"The motion profile could not be prepared",api.SERVER_ERROR);return}
    _=authoring_publish(s,call,file,&doc)
}

@(private)
motion_authoring_pose_write :: proc(call:^api.Call,pose:anim.Pose_Warp_Profile) {
    pose:=pose
    serial.text_write_raw(call.out,"{");api.write_key(call.out,"pelvis",true);value:=pose.pelvis;authoring_write_value(call,&value,type_info_of(anim.Bone_Ref))
    api.write_key(call.out,"spine");serial.text_write_raw(call.out,"[")
    for &bone,i in pose.spine[:pose.spine_count] {if i>0 {serial.text_write_raw(call.out,",")};authoring_write_value(call,&bone,type_info_of(anim.Bone_Ref))}
    serial.text_write_raw(call.out,"]")
    api.write_key(call.out,"legs");serial.text_write_raw(call.out,"[")
    for &leg,i in pose.legs[:pose.count] {if i>0 {serial.text_write_raw(call.out,",")};authoring_write_value(call,&leg,type_info_of(anim.Pose_Warp_Leg))}
    serial.text_write_raw(call.out,"]")
    for field in ([4]string{"min_stride","max_stride","max_angle","weight"}) {
        number:=pose.min_stride if field=="min_stride" else pose.max_stride if field=="max_stride" else pose.max_angle if field=="max_angle" else pose.weight
        api.write_key(call.out,field);api.write_number(call.out,number)
    }
    api.write_bool(call.out,"orientation",pose.orientation);api.write_bool(call.out,"stride",pose.stride);serial.text_write_raw(call.out,"}")
}

@(private)
authoring_motion_profile_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Inspect_Params);file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=motion_authoring_open(s,call,p.asset,&file);if !ok {return}
    serial.text_write_raw(call.out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(call.out,"pose");motion_authoring_pose_write(call,profile.info.pose)
    api.write_uint(call.out,"windows_total",u64(len(profile.windows)));api.write_uint(call.out,"distances_total",u64(len(profile.distances)))
    program_rows(call,"windows",profile.windows,p.offset,p.limit)
    api.write_key(call.out,"distances");serial.text_write_raw(call.out,"[")
    first:=min(int(p.offset),len(profile.distances));last:=min(first+int(p.limit),len(profile.distances))
    for &track,i in profile.distances[first:last] {
        if i>0 {serial.text_write_raw(call.out,",")};serial.text_write_raw(call.out,"{");api.write_int(call.out,"index",i64(first+i),true)
        api.write_key(call.out,"value");serial.text_write_raw(call.out,"{")
        api.write_text(call.out,"clip",base.text_get(track.clip[:]),true);api.write_text(call.out,"name",base.text_get(track.name[:]))
        api.write_key(call.out,"animation");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,track.animation);serial.write_u8(call.out,'"')
        api.write_key(call.out,"keys");serial.text_write_raw(call.out,"[")
        for &key,k in profile.keys[track.first:][:track.count] {if k>0 {serial.text_write_raw(call.out,",")};authoring_write_value(call,&key,type_info_of(lib.Distance_Key))}
        serial.text_write_raw(call.out,"]}}")
    }
    serial.text_write_raw(call.out,"]}")
}

@(private)
authoring_motion_distance :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Motion_Distance_Params_Query);file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=motion_authoring_open(s,call,p.asset,&file);if !ok {return}
    time,clip,valid:=anim.motion_distance_time(profile,base.text_get(p.name[:]),p.distance)
    if !valid {authoring_failure(call,"name/distance","Missing_Track","a named distance track and finite distance",base.text_get(p.name[:]),"The distance query is invalid");return}
    api.call_result(call,Motion_Distance_Result)^={clip=clip,time=time,animation=anim.motion_distance_source(profile,base.text_get(p.name[:]))}
}

@(private)
authoring_motion_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params);world,entity,ok:=subject(s,call,p.entity,p.handle);if !ok {return}
    instance,ready:=anim.motion_inspect(core.world_storage_of(world,anim.Motion_Runtime),entity)
    serial.text_write_raw(call.out,"{");api.write_key(call.out,"id",true);api.write_id(call.out,p.entity)
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
        if id,found:=core.get(core.read(ids),target.target.entity);found {named.entity=id.value}
        api.write_key(call.out,"target");authoring_write_value(call,&named,type_info_of(Spatial_Target_Params))
        api.write_numbers(call.out,"world_position",target.world.position)
        rotation:=target.world.rotation;api.write_key(call.out,"world_rotation");authoring_write_value(call,&rotation,type_info_of(mm.Quat))
        api.write_bool(call.out,"enabled",target.enabled);api.write_bool(call.out,"resolved",target.resolved);serial.text_write_raw(call.out,"}")
    }
    serial.text_write_raw(call.out,"]}")
}
