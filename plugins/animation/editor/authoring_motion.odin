package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Motion_Pose_Params :: struct {
    pelvis:anim.Bone_Ref `mirai:"optional"`,
    spine:[16]anim.Bone_Ref `mirai:"optional,trim"`,
    legs:[16]anim.Pose_Warp_Leg `mirai:"optional,trim"`,
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
Motion_Distance_Params :: struct {clip:[64]u8 `mirai:"text"`,name:[32]u8 `mirai:"text"`,keys:[256]lib.Distance_Key `mirai:"trim"`,animation:base.Asset_Id `mirai:"optional"`}
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
    editor.api_method_register(s,{params=type_info_of(Motion_Write_Params),result=type_info_of(Authoring_Write_Result),name="animation.motion.set",summary="Makes or replaces a .motion profile that entities share: warp windows, pose warping and distance tracks. An invalid one changes nothing. In Edit.",defaults=defaults,run=authoring_motion_set})
    editor.api_method_register(s,{params=type_info_of(Motion_Distance_Params_Query),result=type_info_of(Motion_Distance_Result),name="animation.motion.distance",summary="The clip and time at which a distance track of a .motion profile reaches a distance, without advancing the world.",flags={.Read_Only},run=authoring_motion_distance})
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
    _=authoring_publish(s,call,file,&doc,api.call_result(call,Authoring_Write_Result))
}


@(private)
authoring_motion_profile_inspect :: proc(s:^editor.Session,call:^api.Call,p:^Asset_Inspect_Params,r:^Asset_Inspect_Result) {
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=motion_authoring_open(s,call,p.asset,&file);if !ok {return}
    base.text_set(r.path[:],file.path)
    pose:=profile.info.pose
    authoring_struct_fields(&r.pose,pose)
    copy(r.pose.spine[:],pose.spine[:pose.spine_count]);copy(r.pose.legs[:],pose.legs[:pose.count])
    r.windows_total,r.distances_total=u32(len(profile.windows)),u32(len(profile.distances))
    r.windows=authoring_pages(call,profile.windows,p.offset,p.limit,Asset_Window)
    first:=min(int(p.offset),len(profile.distances))
    r.distances=make([]Authoring_Page(Motion_Distance_Params),min(first+int(p.limit),len(profile.distances))-first,call.allocator)
    for &page,i in r.distances {
        track:=profile.distances[first+i]
        page={index=u32(first+i),value={clip=track.clip,name=track.name,animation=track.animation}}
        copy(page.value.keys[:],profile.keys[track.first:][:track.count])
    }
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
authoring_motion_inspect :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity) -> (r:Instance_Motion) {
    instance,ready:=anim.motion_inspect(core.world_storage_of(world,anim.Motion_Runtime),entity)
    r.id,r.profile,r.ready,r.window,r.error=editor.api_entity_id(world,entity),instance.profile,ready,i32(instance.window),instance.error
    r.remaining_error,r.source_velocity=instance.remaining_error,instance.source_velocity
    goal:=instance.locomotion
    r.locomotion={velocity=goal.velocity,source_velocity=goal.source_velocity,weight=goal.weight,enabled=goal.enabled}
    r.targets_total=u32(len(instance.targets))
    r.targets=make([]Instance_Motion_Target,len(instance.targets),call.allocator)
    ids:=core.world_table_of(world,core.Id)
    for &row,i in r.targets {
        target:=instance.targets[i]
        named:=SPATIAL_TARGET_PARAMS_DEFAULT
        named.kind=target.target.kind;named.bone=target.target.bone;named.socket=target.target.socket
        named.position,named.rotation,named.scale=target.target.position,target.target.rotation,target.target.scale
        if id,found:=core.get(ids,target.target.entity);found {base.text_set(named.entity[:],fmt.tprintf("%016x",u64(id.value)))}
        row={name=target.name,target=named,world_position=target.world.position,world_rotation=target.world.rotation,enabled=target.enabled,resolved=target.resolved}
    }
    return
}
