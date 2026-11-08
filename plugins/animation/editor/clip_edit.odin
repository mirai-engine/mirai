package animation_editor

import "core:fmt"
import "core:math/linalg"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// What a clip edit does, as lib.Clip_Edit names them.
Clip_Verb :: enum u8 {Retime,Hold,Extend,Smooth,Exaggerate,Make_Loop,Offset,Lock_Feet,Mirror,Face_Rest}
// Body regions by name, alone or together.
Body_Group :: enum u8 {Body,Upper_Body,Lower_Body,Arms,Legs,Hips,Spine,Head,Arm_L,Arm_R,Leg_L,Leg_R}
Body_Groups :: bit_set[Body_Group]
// What an offset moves or turns: a body part, or the spine as a whole.
Body_Target :: enum u8 {
    Pelvis,Spine,Neck,Head,
    Clavicle_L,Shoulder_L,Elbow_L,Hand_L,Clavicle_R,Shoulder_R,Elbow_R,Hand_R,
    Hip_L,Knee_L,Foot_L,Toe_L,Hip_R,Knee_R,Foot_R,Toe_R,
}
// Whether a clip repeats: Auto decides by how close its end is to its start.
Clip_Loop :: enum u8 {Auto,Loop,Once}

Clip_Edit_Step :: struct {
    verb:Clip_Verb,
    range:[2]f32 `mirai:"optional,unit=s,label=Start and end in seconds; omitted is the whole clip"`,
    factor:f32 `mirai:"optional,label=Retime: times faster (2 is twice as fast)"`,
    duration:f32 `mirai:"optional,unit=s,label=Retime: seconds the range lasts"`,
    at:f32 `mirai:"optional,unit=s,label=Hold: the moment that stays"`,
    seconds:f32 `mirai:"optional,unit=s,label=Hold and Extend: seconds added"`,
    amount:f32 `mirai:"optional,label=Smooth 0 to 1; Exaggerate 0 to 4"`,
    parts:Body_Groups `mirai:"optional,label=Smooth and Exaggerate: the body parts; omitted is the whole body"`,
    part:Body_Target `mirai:"optional,label=Offset: the part"`,
    direction:lib.Body_Direction `mirai:"optional,label=Offset: in the space of the body"`,
    strength:lib.Body_Amount `mirai:"optional,label=Offset: how much"`,
    blend:f32 `mirai:"optional,unit=s,label=Make_Loop and Lock_Feet: seconds of blend; 0 picks"`,
    fade:f32 `mirai:"optional,unit=s,label=Offset: seconds of fade at the ends of its range"`,
}
CLIP_EDIT_STEPS :: 16
Clip_Edit_Params :: struct {
    asset:base.Asset_Id `mirai:"label=The .anim with the clip"`,
    clip:[64]u8 `mirai:"text,optional,label=Its clip; empty is the first"`,
    skeleton:base.Asset_Id `mirai:"optional,label=Its skeleton; or id"`,
    id:base.Entity_Id `mirai:"optional,label=An entity whose rig gives the skeleton"`,
    edits:[CLIP_EDIT_STEPS]Clip_Edit_Step `mirai:"optional,label=Applied in order; empty copies the clip with its keys as they are"`,
    name:[64]u8 `mirai:"text,optional,label=Name of the new clip; empty keeps the clip's in another .anim and adds ' edited' in asset"`,
    path:[1024]u8 `mirai:"text,optional,label=The .anim it goes into: a new one, or one whose clips move the same skeleton; empty is asset"`,
    replace:bool `mirai:"optional,label=Replaces a clip of that name"`,
    rate:f32 `mirai:"optional,min=1,max=240,label=Frames per second of the result"`,
    loop:Clip_Loop `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Measures and answers without writing"`,
}
Analyze_Params :: struct {
    asset:base.Asset_Id `mirai:"optional,label=An .anim to measure a clip of; with skeleton or id"`,
    clip:[64]u8 `mirai:"text,optional"`,
    skeleton:base.Asset_Id `mirai:"optional"`,
    id:base.Entity_Id `mirai:"optional,label=A rig whose skeleton to measure on"`,
    rate:f32 `mirai:"optional,min=1,max=240"`,
    loop:Clip_Loop `mirai:"optional"`,
    contacts:u32 `mirai:"optional,max=64,label=How many foot contacts to list"`,
}

Metric_Pair :: struct {mean,max:f32}
Metric_Limit_Result :: struct {part:lib.Body_Part,frames:u32 `mirai:"label=Frames past its limit"`,worst:f32 `mirai:"unit=rad,label=How far past the worst frame went"`}
Metric_Contact_Result :: struct {foot:lib.Foot,start,end:f32 `mirai:"unit=s"`}
Metric_Fix :: struct {problem:[128]u8 `mirai:"text"`,edit:Clip_Edit_Step `mirai:"label=A step of animation.clip.edit that fixes it"`}
Metrics_Result :: struct {
    duration:f32 `mirai:"unit=s"`,frames:u32,loop:bool,root:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=The root bone; empty for a clip in place"`,
    travel:mm.Vec3 `mirai:"unit=m/s,label=Velocity of the body over the ground: that of its root or for a clip in place the one its feet push at"`,
    speed:f32 `mirai:"unit=m/s"`,in_place:bool,
    contacts_total:u32,contacts:[64]Metric_Contact_Result `mirai:"label=Foot contacts with the ground"`,
    foot_slide_left,foot_slide_right:Metric_Pair `mirai:"unit=m/s,label=Speed of a standing foot over the ground"`,
    penetration:Metric_Pair `mirai:"unit=m,label=How far a foot or toe goes below its height at rest"`,
    jerk:Metric_Pair `mirai:"unit=m/s³,label=Change of acceleration of the parts"`,
    seam_position:f32 `mirai:"unit=m,label=The last frame against the first relative to the root"`,
    seam_rotation:f32 `mirai:"unit=rad"`,
    seam_velocity:f32 `mirai:"unit=m/s,label=How much more the speed changes across the seam than between frames inside"`,
    limits:[len(lib.Body_Part)]Metric_Limit_Result `mirai:"label=Knees bent backwards; elbows folded too far and the head turned too far"`,
    fixes:[8]Metric_Fix,
}
Clip_Edit_Result :: struct {
    asset:base.Asset_Id,path:[1024]u8 `mirai:"text"`,dry_run:bool `mirai:"optional"`,
    clip:[64]u8 `mirai:"text"`,before,after:Metrics_Result,
}

@(private)
clip_edit_register :: proc(s:^editor.Session) {
    edit:=Clip_Edit_Params{rate=60}
    analyze:=Analyze_Params{rate=60,contacts=16}
    authoring_method_register(s,{name="animation.clip.edit",summary="Edits a clip with verbs applied in order into a new clip and measures it before and after as animation.analyze does. The body of the skeleton is the one it stores, or one found in memory for the call.",params=Clip_Edit_Params,params_info=type_info_of(Clip_Edit_Params),defaults=&edit,run=clip_edit},Clip_Edit_Result,type_info_of(Clip_Edit_Result))
    authoring_method_register(s,{name="animation.analyze",summary="Measures a clip on its skeleton (travel, foot contacts and slide, penetration, jerk, loop seam and joint limits) and suggests the clip edits that fix what it finds.",params=Analyze_Params,params_info=type_info_of(Analyze_Params),defaults=&analyze,flags={.Read_Only},run=clip_analyze},Metrics_Result,type_info_of(Metrics_Result))
}

// A clip sampled on its skeleton for metrics and edits.
@(private)
Clip_Sampled :: struct {
    rig:lib.Body_Rig,
    bones:[]aa.Skeleton_Bone,
    frames:lib.Frames,
    curves:[]aa.Animation_Track,
    tracked:[]bit_set[lib.Property],
    markers:[dynamic]aa.Animation_Marker_Desc,
    root:aa.Animation_Root,
    name:string,
}

// The skeleton of a call: the asset, or the one the rig of id shows.
@(private)
clip_skeleton :: proc(s:^editor.Session,call:^api.Call,skeleton:base.Asset_Id,id:base.Entity_Id,file:^Authoring_File) -> (view:aa.Skeleton_View,ok:bool) {
    skeleton:=skeleton
    if skeleton=={} && id!=0 {
        w,e,found:=subject(s,call,id);if !found {return}
        skeleton=rig_skeleton(s,w,e)
    }
    if skeleton=={} {authoring_failure(call,"skeleton","Required","a skeleton asset, or id of a rig that shows one","none","The clip needs a skeleton to be measured",fix="Pass skeleton, or id of an entity with a skinned mesh");return}
    return authoring_skeleton_open(s,call,skeleton,file)
}

@(private)
clip_sample :: proc(call:^api.Call,animation:aa.Animation_View,index:int,skeleton:aa.Skeleton_View,rate:f32,loop:Clip_Loop) -> (sampled:Clip_Sampled,ok:bool) {
    allocator:=context.temp_allocator
    clip:=&animation.clips[index]
    sampled.name=base.text_get(clip.name[:])
    sampled.root=clip.root
    sampled.bones=skeleton.bones
    root:=""
    if clip.root.translation || clip.root.rotation {root=base.text_get(clip.root.bone[:])}
    sampled.rig=body_rig(call,skeleton,root) or_return
    n:=len(skeleton.bones)
    library:lib.Library
    desc:=aa.animation_library_desc(animation);desc.allocator=allocator
    if !lib.library_init(&library,desc) {authoring_failure(call,"asset","Out_Of_Memory","memory for the clips","allocation failed","The clips could not be loaded",api.SERVER_ERROR);return}
    first:=aa.animation_clips_add(animation,&library)
    if first==0 {authoring_failure(call,"asset","Invalid_Asset","clips that fit a library","refused","The clips could not be loaded");return}
    handle:=lib.Clip(int(first)+index)
    names:=make([]u64,n,allocator)
    for &bone,i in skeleton.bones {names[i]=bone.target}
    bindings:=make([]lib.Bone_Tracks,n,allocator)
    if !lib.skeleton_bind(&library,handle,{sampled.rig.parents,names,sampled.rig.rest},bindings) {authoring_failure(call,"skeleton","Invalid_Skeleton","a skeleton whose rest pose is valid","bind failed","The clip could not be bound to the skeleton");return}
    sampled.tracked=make([]bit_set[lib.Property],n,allocator)
    bound:=false
    for binding,i in bindings {
        if binding.position>=0 {sampled.tracked[i]+={.Position}}
        if binding.rotation>=0 {sampled.tracked[i]+={.Rotation}}
        if binding.scale>=0 {sampled.tracked[i]+={.Scale}}
        bound||=sampled.tracked[i]!={}
    }
    if !bound {authoring_failure(call,"skeleton","Unbound_Clip","a skeleton whose bone paths the clip names","no track names a bone","The clip does not move this skeleton",fix="Pass the skeleton the clip was made for, or retarget it with animation.retarget.bake");return}
    curves:=make([dynamic]lib.Track,allocator)
    sampled.curves=make([]aa.Animation_Track,0,allocator)
    rows:=make([dynamic]aa.Animation_Track,allocator)
    for track,i in animation.tracks[clip.first_track:][:clip.track_count] {
        if track.property!=.Float && track.property!=.Vector {continue}
        append(&curves,lib.clip_tracks(&library,handle)[i]);append(&rows,track)
    }
    sampled.curves=rows[:]
    duration:=lib.clip_duration(&library,handle)
    count,exact:=lib.frames_layout(duration,rate,aa.ANIMATION_MAX_KEYS/max(n*3,1))
    if count<2 {authoring_failure(call,"clip","Too_Short","a clip that lasts, with keys at more than one time",fmt.tprintf("%v s",duration),"The clip is a single pose",fix="Edit poses with animation.track.set, or pick a clip with motion");return}
    sampled.frames={rate=exact,bones=n,curves=len(curves),local=make([]mm.Transform,count*n,allocator),values=make([]mm.Vec4,count*len(curves),allocator)}
    if !lib.frames_sample_clip(&library,handle,bindings,sampled.rig.rest,curves[:],sampled.frames) {authoring_failure(call,"clip","Invalid_Clip","finite keys","sampling failed","The clip could not be sampled");return}
    sampled.markers=make([dynamic]aa.Animation_Marker_Desc,allocator)
    for &marker in animation.markers[clip.first_marker:][:clip.marker_count] {append(&sampled.markers,aa.Animation_Marker_Desc{marker.time,base.text_get(marker.name[:])})}
    switch loop {
    case .Loop: sampled.frames.loop=true
    case .Once: sampled.frames.loop=false
    case .Auto:
        metrics,measured:=clip_measure(sampled.rig,sampled.frames,nil)
        sampled.frames.loop=measured && metrics.seam_position<.02*metrics.height && metrics.seam_rotation<5*mm.RAD_PER_DEG
    }
    return sampled,true
}

@(private)
clip_measure :: proc(rig:lib.Body_Rig,frames:lib.Frames,contacts:[]lib.Contact) -> (lib.Clip_Metrics,bool) {
    scratch:=make([]mm.Transform,lib.frames_scratch_size(frames),context.temp_allocator)
    return lib.clip_metrics(rig,frames,{contacts=contacts},scratch)
}

// The metrics of a clip and the edits that would fix what they show.
@(private)
metrics_write :: proc(out:^serial.Writer,key:string,rig:lib.Body_Rig,bones:[]aa.Skeleton_Bone,frames:lib.Frames,contact_limit:int,first:=false) -> bool {
    contacts:=make([]lib.Contact,min(contact_limit,64),context.temp_allocator)
    metrics,ok:=clip_measure(rig,frames,contacts)
    if !ok {return false}
    if key!="" {api.write_key(out,key,first);serial.text_write_raw(out,"{")} else {serial.text_write_raw(out,"{")}
    number :: proc(out:^serial.Writer,key:string,value:f32,first:=false) {api.write_key(out,key,first);api.write_number(out,value)}
    pair :: proc(out:^serial.Writer,key:string,value:lib.Metric_Stat) {api.write_key(out,key);serial.text_write_raw(out,"{");number(out,"mean",value.mean,true);number(out,"max",value.max);serial.text_write_raw(out,"}")}
    number(out,"duration",metrics.duration,true);api.write_uint(out,"frames",u64(lib.frames_count(frames)));api.write_bool(out,"loop",frames.loop)
    api.write_text(out,"root",base.text_get(bones[metrics.root].path[:]) if metrics.root>=0 && int(metrics.root)<len(bones) else "")
    api.write_numbers(out,"travel",metrics.travel);number(out,"speed",linalg.length(metrics.travel));api.write_bool(out,"in_place",metrics.in_place)
    api.write_uint(out,"contacts_total",u64(metrics.contacts))
    api.write_key(out,"contacts");serial.text_write_raw(out,"[")
    for contact,i in contacts[:min(metrics.contacts,len(contacts))] {
        if i>0 {serial.text_write_raw(out,",")}
        serial.text_write_raw(out,"{");api.write_text(out,"foot",fmt.tprintf("%v",contact.foot),true)
        number(out,"start",f32(contact.first)/frames.rate);number(out,"end",f32(contact.last)/frames.rate);serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]")
    pair(out,"foot_slide_left",metrics.foot_slide[.Left]);pair(out,"foot_slide_right",metrics.foot_slide[.Right])
    pair(out,"penetration",metrics.penetration);pair(out,"jerk",metrics.jerk)
    number(out,"seam_position",metrics.seam_position);number(out,"seam_rotation",metrics.seam_rotation);number(out,"seam_velocity",metrics.seam_velocity)
    api.write_key(out,"limits");serial.text_write_raw(out,"[")
    written:=0
    for stat,part in metrics.limits {
        if stat.frames==0 {continue}
        if written>0 {serial.text_write_raw(out,",")};written+=1
        serial.text_write_raw(out,"{");api.write_text(out,"part",fmt.tprintf("%v",part),true);api.write_uint(out,"frames",u64(stat.frames));number(out,"worst",stat.worst);serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"fixes");serial.text_write_raw(out,"[")
    fixes:=0
    fix :: proc(out:^serial.Writer,count:^int,problem,edit:string) {
        if count^>0 {serial.text_write_raw(out,",")};count^+=1
        serial.text_write_raw(out,"{");api.write_text(out,"problem",problem,true);api.write_key(out,"edit");serial.text_write_raw(out,edit);serial.text_write_raw(out,"}")
    }
    slide:=max(metrics.foot_slide[.Left].mean,metrics.foot_slide[.Right].mean)
    if slide>.05 {fix(out,&fixes,fmt.tprintf("feet slide %.2f m/s while they stand",slide),`{"verb":"Lock_Feet"}`)}
    if metrics.penetration.max>.01 {fix(out,&fixes,fmt.tprintf("a foot goes %.3f m under the floor",metrics.penetration.max),`{"verb":"Offset","part":"Pelvis","direction":"Up","strength":"Slight"}`)}
    if frames.loop && metrics.seam_position>.01*metrics.height {
        fix(out,&fixes,fmt.tprintf("the loop jumps %.3f m at its seam",metrics.seam_position),`{"verb":"Make_Loop"}`)
    } else if frames.loop && metrics.seam_velocity>.1*metrics.height {
        fix(out,&fixes,fmt.tprintf("the loop changes speed by %.2f m/s at its seam",metrics.seam_velocity),`{"verb":"Make_Loop"}`)
    }
    if metrics.jerk.mean>400 {fix(out,&fixes,fmt.tprintf("motion shakes (jerk %.0f m/s3)",metrics.jerk.mean),`{"verb":"Smooth","amount":0.3}`)}
    for side in ([2]lib.Body_Part{.Knee_L,.Knee_R}) {
        if metrics.limits[side].frames>0 {fix(out,&fixes,fmt.tprintf("%v bends backwards on %d frames",side,metrics.limits[side].frames),fmt.tprintf(`{{"verb":"Offset","part":"%v","direction":"Forward","strength":"Slight"}}`,side))}
    }
    serial.text_write_raw(out,"]}")
    return true
}

@(private)
clip_analyze :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Analyze_Params)
    if p.asset=={} {authoring_failure(call,"asset","Required","an .anim asset with the clip to measure","none","Nothing to measure",fix="Pass asset and clip, with skeleton or the id of a rig");return}
    file,skeleton_file:Authoring_File;defer aa.asset_close(&file.file);defer aa.asset_close(&skeleton_file.file)
    animation,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,animation,base.text_get(p.clip[:]));if !found {return}
    skeleton,has:=clip_skeleton(s,call,p.skeleton,p.id,&skeleton_file);if !has {return}
    sampled,sampled_ok:=clip_sample(call,animation,index,skeleton,p.rate,p.loop);if !sampled_ok {return}
    if !metrics_write(call.out,"",sampled.rig,skeleton.bones,sampled.frames,int(p.contacts)) {authoring_failure(call,"clip","Unmeasured","frames that compose on the skeleton","metrics failed","The clip could not be measured",api.SERVER_ERROR)}
}

// The lib edit of a step, after checking that it names what its verb needs.
@(private)
clip_step :: proc(call:^api.Call,step:Clip_Edit_Step,raw:string,index:int) -> (edit:lib.Clip_Edit,ok:bool) {
    has :: proc(raw,field:string) -> bool {_,found:=authoring_json_field(raw,field);return found}
    path:=fmt.tprintf("edits[%d]",index)
    need :: proc(call:^api.Call,raw,path,field,expected:string) -> bool {
        if has(raw,field) {return true}
        authoring_failure(call,fmt.tprintf("%s.%s",path,field),"Required",expected,"missing","The edit needs this field",fix=fmt.tprintf("Add %s to %s",field,path))
        return false
    }
    range:=lib.Time_Range{step.range[0],step.range[1]} if has(raw,"range") else {}
    regions:lib.Body_Regions
    for group in step.parts {
        switch group {
        case .Body: regions=lib.BODY_REGIONS_ALL
        case .Upper_Body: regions+={.Spine,.Head,.Arm_L,.Arm_R}
        case .Lower_Body: regions+={.Hips,.Leg_L,.Leg_R}
        case .Arms: regions+={.Arm_L,.Arm_R}
        case .Legs: regions+={.Leg_L,.Leg_R}
        case .Hips: regions+={.Hips}
        case .Spine: regions+={.Spine}
        case .Head: regions+={.Head}
        case .Arm_L: regions+={.Arm_L}
        case .Arm_R: regions+={.Arm_R}
        case .Leg_L: regions+={.Leg_L}
        case .Leg_R: regions+={.Leg_R}
        }
    }
    switch step.verb {
    case .Retime:
        if has(raw,"factor")==has(raw,"duration") {authoring_failure(call,path,"Required","factor or duration, not both","both or neither","Retime needs how fast or how long",fix=`Pass {"verb":"Retime","duration":2} or {"verb":"Retime","factor":0.5}`);return}
        edit=lib.Retime{range=range,factor=step.factor if has(raw,"factor") else 0,duration=step.duration if has(raw,"duration") else 0}
    case .Hold:
        need(call,raw,path,"at","the second that stays") or_return
        need(call,raw,path,"seconds","how long it stays") or_return
        edit=lib.Hold{step.at,step.seconds}
    case .Extend:
        need(call,raw,path,"seconds","the seconds to add") or_return
        edit=lib.Extend{range,step.seconds}
    case .Smooth:
        need(call,raw,path,"amount","0 to 1 (0.3 removes shaking)") or_return
        edit=lib.Smooth{step.amount,regions,range}
    case .Exaggerate:
        need(call,raw,path,"amount","0 to 4 (1 doubles the accents)") or_return
        edit=lib.Exaggerate{step.amount,regions,range}
    case .Make_Loop: edit=lib.Make_Loop{step.blend}
    case .Offset:
        need(call,raw,path,"part","the part to move or turn") or_return
        need(call,raw,path,"direction","Forward, Back, Left, Right, Up or Down") or_return
        target:lib.Offset_Target
        if step.part==.Spine {target=lib.Body_Region.Spine} else {target=lib.Body_Part(u8(step.part)-(1 if step.part>.Spine else 0))}
        edit=lib.Offset{target=target,direction=step.direction,amount=step.strength,range=range,fade=step.fade}
    case .Lock_Feet: edit=lib.Lock_Feet{step.blend}
    case .Mirror: edit=lib.Mirror{}
    case .Face_Rest: edit=lib.Face_Rest{}
    }
    return edit,true
}

// The failure of a lib edit, said for its step.
@(private)
clip_step_failure :: proc(call:^api.Call,index:int,step:Clip_Edit_Step,result:lib.Edit_Result,max_frames:int) {
    path:=fmt.tprintf("edits[%d]",index)
    switch result.error {
    case .None:
    case .Invalid_Range: authoring_failure(call,fmt.tprintf("%s.range",path),"Invalid_Range","a start before its end, inside the clip",fmt.tprintf("%v",step.range),"The range is outside the clip",fix="Pass seconds inside the clip, or omit range for the whole clip")
    case .Invalid_Amount: authoring_failure(call,path,"Invalid_Amount","factor 0.01 to 100, positive durations and seconds, amount within the verb's bounds, blends and fades shorter than half the range",fmt.tprintf("%v",step.verb),"A value of the edit is out of bounds",fix="Smooth takes amount 0 to 1, Exaggerate 0 to 4; Make_Loop blend at most half the clip")
    case .Missing_Part: authoring_failure(call,path,"Missing_Part","a body with that part",fmt.tprintf("%v",result.part),"The body of the skeleton lacks a part this edit needs",fix=fmt.tprintf("Detect it with skeleton.body.detect or set it with skeleton.body.set {{\"parts\":[{{\"part\":\"%v\",\"bone\":\"<path>\"}}]}}",result.part))
    case .Missing_Mirror: authoring_failure(call,path,"Missing_Mirror","bones named for their side (thigh_l, LeftArm)","no pairs","The skeleton has no sides to swap",fix="Name the bones of each side with l/r or left/right")
    case .Along_Part: authoring_failure(call,fmt.tprintf("%s.direction",path),"Along_Part","a direction the part can turn toward",fmt.tprintf("%v",step.direction),"The part already points that way",fix="Choose another direction, or move the end of the limb (Hand or Foot) instead")
    case .Too_Long: authoring_failure(call,path,"Too_Long",fmt.tprintf("at most %d frames",max_frames),"more","The result is too long",fix="Add fewer seconds or lower rate")
    case .Buffers,.Invalid_Frames,.Invalid_Rig,.Numeric: authoring_failure(call,path,"Edit_Failed","an edit whose poses compose",fmt.tprintf("%v",result.error),"The edit could not be applied",api.SERVER_ERROR)
    }
}

@(private)
clip_edit :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clip_Edit_Params)
    if !authoring_editable(s,call) {return}
    file,skeleton_file:Authoring_File;defer aa.asset_close(&file.file);defer aa.asset_close(&skeleton_file.file)
    animation,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,animation,base.text_get(p.clip[:]));if !found {return}
    skeleton,has:=clip_skeleton(s,call,p.skeleton,p.id,&skeleton_file);if !has {return}
    sampled,sampled_ok:=clip_sample(call,animation,index,skeleton,p.rate,p.loop);if !sampled_ok {return}
    steps,_:=api.params_array_count(call,"edits")
    steps=min(steps,CLIP_EDIT_STEPS)
    edits_raw,_:=authoring_json_field(call.raw,"edits",call.allocator)
    max_frames:=aa.ANIMATION_MAX_KEYS/max(len(skeleton.bones)*3,1)
    frames:=sampled.frames
    markers:=sampled.markers
    for step,i in p.edits[:steps] {
        raw,_:=authoring_json_element(edits_raw,i,call.allocator)
        edit,valid:=clip_step(call,step,raw,i);if !valid {return}
        layout,error:=lib.clip_edit_layout(edit,frames,max_frames)
        if error!=.None {clip_step_failure(call,i,step,{error=error},max_frames);return}
        output:=lib.Frames{rate=layout.rate,bones=frames.bones,curves=frames.curves,loop=layout.loop,local=make([]mm.Transform,layout.count*frames.bones,context.temp_allocator),values=make([]mm.Vec4,layout.count*frames.curves,context.temp_allocator)}
        transforms,contacts,heights:=lib.clip_edit_buffers(edit,frames)
        buffers:=lib.Edit_Buffers{make([]mm.Transform,transforms,context.temp_allocator),make([]lib.Contact,contacts,context.temp_allocator),make([]f32,heights,context.temp_allocator)}
        if result:=lib.clip_edit(sampled.rig,edit,frames,output,buffers);result.error!=.None {clip_step_failure(call,i,step,result,max_frames);return}
        moved:=make([dynamic]aa.Animation_Marker_Desc,context.temp_allocator)
        for marker in markers {
            times:[64]f32
            count:=lib.clip_edit_times(edit,frames,marker.time,times[:])
            for time in times[:min(count,len(times))] {append(&moved,aa.Animation_Marker_Desc{time,marker.name})}
        }
        frames,markers=output,moved
    }
    // The .anim it goes into: asset, another one at path whose clips move the same skeleton, or a
    // new one at path.
    target,target_view,id:=file,animation,p.asset
    other:Authoring_File;defer aa.asset_close(&other.file)
    created:=false
    if path:=base.text_get(p.path[:]);path!="" {
        if record,found:=aa.registry_find_path(&s.app.assets.registry,path);found {
            // What the record says is copied: opening an asset may add files to the registry and
            // move its records.
            kind,there:=record.kind,record.id
            if kind!=aa.KIND_ANIMATION {authoring_failure(call,"path","Invalid_Asset","a new path, or an .anim",authoring_kind_text(kind),"The path holds another kind of asset",fix="Pass a new path ending in .anim, or the path of an .anim");return}
            if there!=p.asset {
                view,opened:=authoring_clip_open(s,call,there,&other);if !opened {return}
                if !clip_same_skeleton(call,view,skeleton) {return}
                target,target_view,id=other,view,there
            }
        } else {
            target,id,created=authoring_create_target(s,call,path,".anim");if !created {return}
        }
    }
    name:=base.text_get(p.name[:])
    if name=="" {name=sampled.name if id!=p.asset else fmt.tprintf("%s edited",sampled.name[:min(len(sampled.name),56)])}
    clip:aa.Animation_Clip_Desc
    if steps==0 {
        source,prepared:=authoring_clip_descs(animation,call);if !prepared {return}
        clip=source[index];clip.name=name
    } else {
        clip=clip_desc(sampled,frames,name,markers[:])
        clip.skeleton=skeleton_file.file.blob.header.id
    }
    clips:[]aa.Animation_Clip_Desc
    if created {
        clips=make([]aa.Animation_Clip_Desc,1,call.allocator);clips[0]=clip
    } else {
        existing,prepared:=authoring_clip_descs(target_view,call);if !prepared {return}
        at:=len(existing)
        for &value,i in existing {if value.name==name {at=i}}
        if at<len(existing) && !p.replace {authoring_failure(call,"name","Already_Exists","a clip name the asset does not have",name,"The asset already has a clip of that name",fix="Pass another name, or replace=true");return}
        updated,placed:=authoring_replace_row(existing,at,clip,false,aa.ANIMATION_MAX_CLIPS,call.allocator)
        if !placed {authoring_failure(call,"asset","Capacity","room for another clip","full","The asset has no room for another clip");return}
        clips=updated
    }
    doc:aa.Document;defer aa.document_destroy(&doc)
    if error:=aa.animation_document(&doc,&s.app.assets.types,{id=id,clips=clips,source=target_view.source if !created else nil},s.app.allocator);error!=.None {authoring_failure(call,"edits","Invalid_Result","keys and markers within the clip capacities",fmt.tprintf("%v",error),"The edited clip could not be stored",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    Written :: struct {sampled:^Clip_Sampled,frames:lib.Frames,name:string,skeleton:aa.Skeleton_View}
    written:=Written{&sampled,frames,name,skeleton}
    authoring_publish(s,call,target,&doc,proc(call:^api.Call,data:rawptr) {
        w:=(^Written)(data)
        api.write_text(call.out,"clip",w.name)
        metrics_write(call.out,"before",w.sampled.rig,w.skeleton.bones,w.sampled.frames,16)
        metrics_write(call.out,"after",w.sampled.rig,w.skeleton.bones,w.frames,16)
    },&written)
}

// Whether every bone track of an .anim names a bone of the skeleton: the clips of a library move
// one skeleton.
@(private)
clip_same_skeleton :: proc(call:^api.Call,view:aa.Animation_View,skeleton:aa.Skeleton_View) -> bool {
    bones:=make(map[u64]struct{},len(skeleton.bones),context.temp_allocator)
    for &bone in skeleton.bones {bones[base.name_hash(base.text_get(bone.path[:]))]={}}
    for &track in view.tracks {
        if track.property==.Float || track.property==.Vector {continue}
        target:=base.text_get(track.target[:])
        if base.name_hash(target) in bones {continue}
        authoring_failure(call,"path","Other_Skeleton","an .anim whose clips move the bones of the skeleton",target,"The .anim at path animates another skeleton",fix="Pass the path of an .anim made for this skeleton, or a new path")
        return false
    }
    return true
}

// The tracks of a clip from its frames: a key a frame for what moves, one key
// for what holds still, and nothing for a bone the clip never moved that
// stays at rest.
@(private)
clip_desc :: proc(sampled:Clip_Sampled,frames:lib.Frames,name:string,markers:[]aa.Animation_Marker_Desc) -> aa.Animation_Clip_Desc {
    allocator:=context.temp_allocator
    count:=lib.frames_count(frames)
    duration:=lib.frames_duration(frames)
    tracks:=make([dynamic]aa.Animation_Track_Desc,allocator)
    time_of :: proc(frame,count:int,rate,duration:f32) -> f32 {return duration if frame==count-1 else min(f32(frame)/rate,duration)}
    for &bone,b in sampled.bones {
        rest:=sampled.rig.rest[b]
        for property in ([3]lib.Property{.Position,.Rotation,.Scale}) {
            value_of :: proc(t:mm.Transform,property:lib.Property) -> mm.Vec4 {
                #partial switch property {
                case .Position: return {t.position.x,t.position.y,t.position.z,0}
                case .Rotation: return lib.quat_vec4(t.rotation)
                }
                return {t.scale.x,t.scale.y,t.scale.z,0}
            }
            first:=value_of(lib.frames_pose(frames,0)[b],property)
            still:=true
            for frame in 1..<count {
                value:=value_of(lib.frames_pose(frames,frame)[b],property)
                if property==.Rotation {if abs(linalg.dot(value,first))<1-1e-9 {still=false;break}} else if linalg.length(value-first)>1e-6 {still=false;break}
            }
            at_rest:=property==.Rotation ? abs(linalg.dot(first,value_of(rest,property)))>=1-1e-9 : linalg.length(first-value_of(rest,property))<=1e-6
            if still && at_rest && property not_in sampled.tracked[b] {continue}
            keys:=make([]lib.Keyframe,1 if still else count,allocator)
            previous:=first
            for &key,frame in keys {
                value:=value_of(lib.frames_pose(frames,frame)[b],property)
                if property==.Rotation {value=lib.quat_align(value,previous);previous=value}
                key={time=time_of(frame,count,frames.rate,duration),value=value}
            }
            append(&tracks,aa.Animation_Track_Desc{target=base.text_get(bone.path[:]),property=property,keys=keys})
        }
    }
    for &curve,c in sampled.curves {
        keys:=make([]lib.Keyframe,count,allocator)
        for &key,frame in keys {key={time=time_of(frame,count,frames.rate,duration),value=lib.frames_values(frames,frame)[c]}}
        append(&tracks,aa.Animation_Track_Desc{target=base.text_get(curve.target[:]),property=curve.property,slot=curve.slot,keys=keys})
    }
    kept:=make([dynamic]aa.Animation_Marker_Desc,allocator)
    for marker in markers {if marker.time<=duration+1e-4 {append(&kept,aa.Animation_Marker_Desc{min(marker.time,duration),marker.name})}}
    return {name=name,tracks=tracks[:],markers=kept[:],root=sampled.root}
}
