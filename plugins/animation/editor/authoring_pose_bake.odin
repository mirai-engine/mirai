package animation_editor

import "core:fmt"
import "core:math"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// Preserve keeps the root's trajectory in the clip; In_Place pins it to its reference.
Pose_Bake_Root :: enum u8 {Preserve,In_Place}
Pose_Bake_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    path:[1024]u8 `mirai:"text,label=An .anim: the clip is added to what is there"`,
    clip:[64]u8 `mirai:"text,label=A clip of that name is replaced"`,
    start,end:f32 `mirai:"min=0,unit=s"`,
    rate:f32 `mirai:"optional,min=1,max=240,unit=Hz"`,
    root_motion:Pose_Bake_Root `mirai:"optional,label=Preserve records the trajectory of the root; In_Place removes it"`,
    parameters:[anim.GRAPH_PARAMETERS]Preview_Parameter `mirai:"optional"`,
    controls:[64]Preview_Control `mirai:"optional"`,
    goals:[64]Preview_Goal `mirai:"optional"`,
    plays:[16]Request_Play `mirai:"optional"`,
    actions:[64]Preview_Action `mirai:"optional"`,
    motion:[16]Request_Motion `mirai:"optional"`,
    locomotion:Request_Locomotion `mirai:"optional"`,
    distance:Request_Distance `mirai:"optional"`,
    locomote:Intent_Locomote `mirai:"optional"`,
    look:Intent_Look `mirai:"optional"`,
    gesture:Intent_Gesture `mirai:"optional"`,
    reach:[2]Intent_Reach `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
pose_bake_defaults :: proc() -> ^Pose_Bake_Params {
    p:=new(Pose_Bake_Params,context.temp_allocator);if p==nil {return nil}
    p.rate=60
    request_rows_defaults(p)
    return p
}

@(private)
pose_bake_register :: proc(s:^editor.Session) {
    p:=pose_bake_defaults();if p==nil {return}
    authoring_method_register(s,{name="animation.pose.bake",summary="Bakes the final pose, curves, morph weights and crossed markers of an entity between two times into a clip, on a copy run with the fields of animation.preview without gameplay or physics. In Edit.",params=Pose_Bake_Params,params_info=type_info_of(Pose_Bake_Params),defaults=p,run=authoring_pose_bake},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
}

@(private)
authoring_pose_bake :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Pose_Bake_Params)
    if !authoring_editable(s,call) {return}
    if !finite(p.start) || !finite(p.end) || p.start<0 || p.end<p.start || !finite(p.rate) || p.rate<1 || p.rate>240 || p.root_motion>max(Pose_Bake_Root) {authoring_failure(call,"range","Range","finite 0 <= start <= end and rate in [1,240]","invalid range or rate","The bake range or sample rate is invalid");return}
    steps64:=math.ceil(f64((p.end-p.start)*p.rate))
    if steps64>3600 {authoring_failure(call,"range","Capacity","at most 3600 sample intervals",fmt.tprintf("%.0f",steps64),"Shorten the bake range or reduce its rate");return}
    if base.text_get(p.clip[:])=="" {authoring_failure(call,"clip","Required","a nonempty output clip name","empty","Name the baked clip");return}
    destination:Authoring_File;defer asset.asset_close(&destination.file)
    output_id,there,at:=authoring_at(s,call,base.text_get(p.path[:]),asset.KIND_ANIMATION,".anim");if !at {return}
    existing:asset.Animation_View
    if there {loaded:bool;existing,loaded=authoring_clip_open(s,call,output_id,&destination);if !loaded {return}} else {
        created:bool;destination,output_id,created=authoring_create_target(s,call,base.text_get(p.path[:]),".anim");if !created {return}
    }
    source,entity,found:=subject(s,call,p.entity[:]);if !found {return}
    entity=pose_owner(s,source,entity)
    if !editor.entity_has(source,entity,anim.Animation) && rig_skeleton(s,source,entity)=={} {authoring_failure(call,"entity","Missing_Component","Animation or a mesh with a skeleton","missing both","The entity has no evaluable pose");return}
    preview:=new(Preview_Params,call.allocator)
    if preview==nil {authoring_failure(call,"bake","Out_Of_Memory","memory for bake requests","allocation failed","The bake requests could not be prepared",api.SERVER_ERROR);return}
    copy(preview.entity[:],p.entity[:]);preview.time,preview.ticks,preview.dt=p.start,u32(steps64),1/p.rate
    copy(preview.parameters[:],p.parameters[:]);copy(preview.controls[:],p.controls[:]);copy(preview.goals[:],p.goals[:]);copy(preview.plays[:],p.plays[:]);copy(preview.actions[:],p.actions[:])
    // One store per value until odin-lang/Odin#7937.
    preview.locomotion=p.locomotion;preview.distance=p.distance;preview.locomote=p.locomote
    preview.look=p.look;preview.gesture=p.gesture;preview.reach=p.reach;preview.motion=p.motion
    clone:=preview_world_clone(s,call,source);if clone==nil {return};defer host.app_world_free(s.app,clone)
    world:=core.world_ref(clone,s.info)
    if !request_source_check(s,call,world,entity) || !request_apply(s,call,world,entity,preview,preview.ticks,nil) {return}
    requests:=core.world_storage_of(world,anim.Animation_Requests)
    if requests==nil {authoring_failure(call,"bake","Evaluation_Failed","an available animation request queue","missing or full queue","The bake could not seek to its initial pose",api.SERVER_ERROR);return}
    anim.animation_seek(requests,entity,p.start)
    if !pose_bake_evaluate(call,world,s.app,0) {return}
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !pose_bake_sample(s,call,world,entity,p,preview,&doc,output_id,existing) {return}
    _=authoring_publish(s,call,destination,&doc)
}
