package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"

Retarget_Bake_Params :: struct {
    animation:base.Asset_Id,
    source_skeleton,target_skeleton:base.Asset_Id,
    profile:base.Asset_Id,
    path:[1024]u8 `mirai:"text,label=New .anim destination; source assets are preserved"`,
    rate:f32 `mirai:"optional,min=1,max=240,unit=Hz"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
authoring_bake_register :: proc(s:^editor.Session) {
    pose_bake_register(s)
    defaults:=Retarget_Bake_Params{rate=60}
    editor.api_method_register(s,{params=type_info_of(Retarget_Bake_Params),result=type_info_of(Authoring_Write_Result),name="animation.retarget.bake",summary="Bakes the clips of an .anim onto another skeleton, of any topology, through the bone mappings and chains of a .pose profile, into a new .anim with their curves, markers and root motion.",defaults=&defaults,run=authoring_retarget_bake})
}

@(private)
authoring_retarget_bake :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Retarget_Bake_Params)
    target,id,created:=authoring_create_target(s,call,base.text_get(p.path[:]),".anim");if !created {return}
    animation_file,source_file,target_file,profile_file:Authoring_File
    defer asset.asset_close(&animation_file.file);defer asset.asset_close(&source_file.file)
    defer asset.asset_close(&target_file.file);defer asset.asset_close(&profile_file.file)
    animation,a:=authoring_clip_open(s,call,p.animation,&animation_file);if !a {return}
    source,b:=authoring_skeleton_open(s,call,p.source_skeleton,&source_file);if !b {return}
    destination,c:=authoring_skeleton_open(s,call,p.target_skeleton,&target_file);if !c {return}
    profile,d:=authoring_profile_open(s,call,p.profile,&profile_file);if !d {return}
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !finite(p.rate) || p.rate<1 || p.rate>240 {authoring_failure(call,"rate","Range","finite Hz in [1,240]",fmt.tprintf("%g",p.rate),"The retarget bake sample rate is invalid");return}
    error:=retarget_bake(&doc,&s.app.assets.types,id,animation,source,destination,profile,p.rate,s.app.allocator,p.target_skeleton)
    if error!=.None {authoring_failure(call,"profile","Retarget_Bake","valid bone mappings or semantic chains within output capacity",fmt.tprintf("%v",error),"The retarget bake could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc,api.call_result(call,Authoring_Write_Result))
}
