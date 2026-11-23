package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import anim "plugins:animation/runtime"

Motion_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .character: its warping is replaced, its other parts kept"`,
    animation:base.Asset_Id `mirai:"optional,label=The .anim of the clips of a new .character"`,
    warp:anim.Pose_Warp_Profile `mirai:"optional,label=Pose warping of the pelvis, spine and legs of the body of the skeleton"`,
    windows:[anim.MOTION_WINDOWS]anim.Motion_Window `mirai:"optional,label=Warp windows: each, the spans of that name on the clips and the target of that name they reach; omitted is none"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

motion_write_defaults :: proc() -> ^Motion_Write_Params {
    value:=new(Motion_Write_Params,context.temp_allocator);if value==nil {return nil}
    value.warp=anim.POSE_WARP_PROFILE_DEFAULT
    for &window in value.windows {window=anim.MOTION_WINDOW_DEFAULT}
    return value
}

authoring_motion_register :: proc(s:^editor.Session) {
    defaults:=motion_write_defaults();if defaults==nil {return}
    editor.api_method_register(s,{params=type_info_of(Motion_Write_Params),result=type_info_of(Authoring_Write_Result),name="animation.motion.set",summary="Replaces the warping of a .character that entities share: pose warping and warp windows over the spans of clips. An invalid one changes nothing. In Edit.",defaults=defaults,run=authoring_motion_set})
}

@(private)
motion_authoring_definition :: proc(call:^api.Call,p:^Motion_Write_Params) -> (profile:anim.Motion_Profile,ok:bool) {
    window_count,_:=api.params_array_count(call,"windows")
    if window_count>anim.MOTION_WINDOWS {authoring_failure(call,"windows","Capacity","at most 64 entries","too many entries","Motion capacity exceeded");return}
    profile.warp=p.warp
    profile.windows=make([]anim.Motion_Window,window_count,call.allocator)
    if window_count>0 && profile.windows==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for motion tables","allocation failed","The motion definition could not be allocated",api.SERVER_ERROR);return}
    copy(profile.windows,p.windows[:window_count])
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
authoring_motion_inspect :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity) -> (r:Instance_Motion) {
    instance,ready:=anim.motion_inspect(core.ref(core.world_storage_of(world,anim.Motion_Runtime)),entity)
    r.id,r.character,r.ready,r.window,r.error=editor.api_entity_id(world,entity),instance.profile,ready,i32(instance.window),instance.error
    r.remaining_error,r.source_velocity=instance.remaining_error,instance.source_velocity
    goal:=instance.locomotion
    r.locomotion={velocity=goal.velocity,source_velocity=goal.source_velocity,weight=goal.weight,enabled=goal.enabled}
    r.targets_total=u32(len(instance.targets))
    r.targets=make([]Instance_Motion_Target,len(instance.targets),call.allocator)
    ids:=core.world_table_of(world,core.Id)
    for &row,i in r.targets {
        target:=instance.targets[i]
        named:=Instance_Spatial_Target{}
        named.kind=target.target.kind;named.name=target.target.name
        named.position,named.rotation,named.scale=target.target.position,target.target.rotation,target.target.scale
        if id,found:=core.get(ids,target.target.entity);found {base.text_set(named.entity[:],fmt.tprintf("%016x",u64(id.value)))}
        row={name=target.name,target=named,world_position=target.world.position,world_rotation=target.world.rotation,enabled=target.enabled,resolved=target.resolved}
    }
    return
}
