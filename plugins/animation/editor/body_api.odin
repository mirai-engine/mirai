package animation_editor

import "core:fmt"
import "core:strings"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Body_Detect_Params :: struct {
    asset:base.Asset_Id,
    keep_manual:bool `mirai:"optional,label=Keeps the parts a person set"`,
    dry_run:bool `mirai:"optional,label=Answers without writing the skeleton"`,
}
Body_Part_Assignment :: struct {
    part:lib.Body_Part,
    bone:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Bone path or unique name; empty clears the part"`,
}
Body_Set_Params :: struct {
    asset:base.Asset_Id,
    parts:[len(lib.Body_Part)]Body_Part_Assignment `mirai:"optional,label=What it sets becomes manual and survives detection and reimport"`,
    dry_run:bool `mirai:"optional"`,
}
Body_Part_Result :: struct {
    part:lib.Body_Part,
    bone:string `mirai:"label=Its path"`,
    name:string,
    confidence:f32 `mirai:"label=0 to 1"`,
    manual:bool `mirai:"label=Whether a person set it"`,
}
// The body of a skeleton as the results that tell it give it.
Body_Fields :: struct {
    up:mm.Vec3 `mirai:"label=The up of the body at rest; it faces -Z"`,axes_confidence:f32 `mirai:"label=0 to 1: how sure detection was of how the body stands"`,
    parts:[]Body_Part_Result,
    missing:[]lib.Body_Part `mirai:"label=Parts without a bone"`,
    unassigned_total:u32,
    unassigned:[]string `mirai:"label=Bones outside the body, the first of them"`,
    fix:string `mirai:"label=How to complete or correct the body; empty when it needs nothing"`,
}
Body_Result :: struct {
    using written:Authoring_Write_Result `mirai:"inline"`,
    using body:Body_Fields `mirai:"inline"`,
}
// What animation.asset.inspect gives of the body of a .skeleton.
Body_Inspect_Result :: struct {
    asset:base.Asset_Id,
    path:string,
    using body:Body_Fields `mirai:"inline"`,
    stored:bool `mirai:"label=The .skeleton keeps it; false: detected now"`,
}

@(private)
body_register :: proc(s:^editor.Session) {
    detect:=Body_Detect_Params{keep_manual=true}
    editor.api_method_register(s,Body_Detect_Params,Body_Result,{name="skeleton.body.detect",summary="Finds the body parts of a skeleton and its up from bone names, hierarchy and rest pose, and saves them in the .skeleton. A body faces -Z: the import turns its source to it (front of asset.import).",defaults=&detect,run=body_detect})
    editor.api_method_register(s,Body_Set_Params,Body_Result,{name="skeleton.body.set",summary="Corrects the body parts of a skeleton: the bone of each part it names, or none. Where the body faces is not set here: it faces -Z, and front of asset.import turns a source that does not.",run=body_set})
}

// The bone with this path or, failing that, this unique name; -1 for none or several.
@(private)
body_bone_find :: proc(bones:[]aa.Skeleton_Bone,text:string) -> i32 {
    for &bone,i in bones {if base.text_get(bone.path[:])==text {return i32(i)}}
    found:i32=-1
    for &bone,i in bones {
        if base.text_get(bone.name[:])!=text {continue}
        if found>=0 {return -1}
        found=i32(i)
    }
    return found
}

// The rig of a skeleton for metrics and edits: hierarchy, rest pose, its body
// and its mirror. root is the bone named for the root motion of a clip, if any.
@(private)
body_rig :: proc(call:^api.Call,view:aa.Skeleton_View,root_path:string) -> (rig:lib.Body_Rig,ok:bool) {
    n:=len(view.bones)
    rig.parents=make([]i32,n,call.allocator)
    rig.rest=make([]mm.Transform,n,call.allocator)
    if len(rig.parents)!=n || len(rig.rest)!=n {authoring_failure(call,"skeleton","Out_Of_Memory","memory for the rig","allocation failed","The rig could not be prepared",api.SERVER_ERROR);return}
    for &bone,i in view.bones {rig.parents[i]=bone.parent;rig.rest[i]={bone.translation,bone.rotation,bone.scale}}
    rig.body=aa.skeleton_body_map(view.bones,view.body,view.body_parts)
    if view.body==nil {
        // Found for the call and not stored: skeleton.body.detect is what stores it.
        if detected,found:=aa.skeleton_body_detect(view.bones,lib.body_map_empty(),call.allocator);found {rig.body=detected}
    }
    rig.root=-1
    if root_path!="" {rig.root=body_bone_find(view.bones,root_path)}
    pairs,paired:=anim.skeleton_mirror_pairs(view.bones,call.allocator)
    corrections:=make([]mm.Quat,n,call.allocator)
    scratch:=make([]mm.Transform,n,call.allocator)
    if paired && len(corrections)==n && len(scratch)==n {
        if plane,prepared:=lib.mirror_prepare(rig.parents,pairs,rig.rest,corrections,scratch);prepared {rig.mirror={pairs,corrections,plane}}
    }
    return rig,true
}

@(private)
body_detect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Body_Detect_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
    previous:=lib.body_map_empty()
    if p.keep_manual {
        previous=aa.skeleton_body_map(view.bones,view.body,view.body_parts)
        for part in lib.Body_Part {if part not_in previous.manual {previous.bones[part],previous.confidence[part]=-1,0}}
    }
    found,detected:=aa.skeleton_body_detect(view.bones,previous,call.allocator)
    if !detected {authoring_failure(call,"asset","Invalid_Skeleton","a skeleton whose rest pose composes","detection failed","The body could not be detected",fix="Check the rest pose with animation.asset.inspect section=bones");return}
    body_save(s,call,file,p.asset,view,found)
}

@(private)
body_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Body_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
    map_:=aa.skeleton_body_map(view.bones,view.body,view.body_parts)
    if view.body==nil {
        // Without a detected body its up comes from detection.
        if detected,found:=aa.skeleton_body_detect(view.bones,lib.body_map_empty(),call.allocator);found {map_.up,map_.axes_confidence=detected.up,detected.axes_confidence}
    }
    count,_:=api.params_array_count(call,"parts")
    for assignment,i in p.parts[:min(count,len(p.parts))] {
        assignment:=assignment
        text:=base.text_get(assignment.bone[:])
        if text=="" {map_.bones[assignment.part],map_.confidence[assignment.part]=-1,0;map_.manual+={assignment.part};continue}
        bone:=body_bone_find(view.bones,text)
        if bone<0 {
            authoring_failure(call,fmt.tprintf("parts[%d].bone",i),"Missing_Bone","a bone path, or a name only one bone has",text,"The skeleton has no such bone",fix=body_similar_bones(view.bones,assignment.part,call.allocator))
            return
        }
        for &other,part in map_.bones {if other==bone && part!=assignment.part {other=-1;map_.confidence[part]=0}}
        map_.bones[assignment.part],map_.confidence[assignment.part]=bone,1
        map_.manual+={assignment.part}
    }
    body_save(s,call,file,p.asset,view,map_)
}

// Bones whose name shares a word with the part, as a hint.
@(private)
body_similar_bones :: proc(bones:[]aa.Skeleton_Bone,part:lib.Body_Part,allocator:=context.temp_allocator) -> string {
    names:=lib.BODY_PART_NAMES
    word:=names[part]
    if at:=strings.index_byte(word,'_');at>0 {word=word[:at]}
    hints:=make([dynamic]string,0,8,allocator)
    for &bone in bones {
        name:=base.text_get(bone.name[:])
        if len(hints)<8 && strings.contains(strings.to_lower(name,allocator),word) {append(&hints,base.text_get(bone.path[:]))}
    }
    if len(hints)==0 {return "Use a bone path from animation.asset.inspect with section bones"}
    return fmt.aprintf("Bones named like %s: %s",word,strings.join(hints[:],", ",allocator),allocator=allocator)
}

@(private)
body_save :: proc(s:^editor.Session,call:^api.Call,file:Authoring_File,id:base.Asset_Id,view:aa.Skeleton_View,map_:lib.Body_Map) {
    body:aa.Skeleton_Body
    rows:[len(lib.Body_Part)]aa.Skeleton_Body_Part
    count,has:=aa.skeleton_body_rows(view.bones,map_,&body,&rows)
    doc:aa.Document;defer aa.document_destroy(&doc)
    desc:=aa.Skeleton_Desc{id=id,bones=view.bones,sockets=view.sockets,source=view.source}
    if has {desc.body,desc.body_parts=&body,rows[:count]}
    if error:=aa.skeleton_document(&doc,&s.app.assets.types,desc,s.app.allocator);error!=.None {authoring_failure(call,"parts","Invalid_Body","each part on a bone of its own",fmt.tprintf("%v",error),"The body could not be saved",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    r:=api.call_result(call,Body_Result)
    r.body=body_fields(call,view,map_)
    authoring_publish(s,call,file,&doc,&r.written)
}

// The body of a result: parts, missing parts, bones outside the body and a fix.
@(private)
body_fields :: proc(call:^api.Call,view:aa.Skeleton_View,map_:lib.Body_Map) -> (r:Body_Fields) {
    r.up,r.axes_confidence=map_.up,map_.axes_confidence
    parts:=make([dynamic]Body_Part_Result,call.allocator)
    missing:=make([dynamic]lib.Body_Part,call.allocator)
    for bone,part in map_.bones {
        if bone<0 {append(&missing,part);continue}
        append(&parts,Body_Part_Result{part,strings.clone(base.text_get(view.bones[bone].path[:]),call.allocator),strings.clone(base.text_get(view.bones[bone].name[:]),call.allocator),map_.confidence[part],part in map_.manual})
    }
    r.parts,r.missing=parts[:],missing[:]
    regions:=make([]i8,len(view.bones),call.allocator)
    outside:=make([]i32,len(view.bones),call.allocator)
    total,_:=lib.body_unassigned(body_parents(view,call.allocator),map_,regions,outside)
    r.unassigned_total=u32(total)
    r.unassigned=make([]string,min(total,32),call.allocator)
    for bone,i in outside[:min(total,32)] {r.unassigned[i]=strings.clone(base.text_get(view.bones[bone].path[:]),call.allocator)}
    weakest:=lib.Body_Part.Pelvis;lowest:=f32(2)
    for bone,part in map_.bones {if bone>=0 && map_.confidence[part]<lowest {weakest,lowest=part,map_.confidence[part]}}
    switch {
    case len(missing)==len(lib.Body_Part): r.fix="No body part was recognized: name them with skeleton.body.set"
    case len(missing)>0: r.fix=fmt.tprintf("Missing parts can be set with skeleton.body.set, for example {{\"parts\":[{{\"part\":\"%v\",\"bone\":\"<path>\"}}]}}",body_first_missing(map_))
    case lowest<.6: r.fix=fmt.tprintf("%v has confidence %.2f: check it and correct it with skeleton.body.set",weakest,lowest)
    }
    return
}

@(private)
body_first_missing :: proc(map_:lib.Body_Map) -> lib.Body_Part {
    for bone,part in map_.bones {if bone<0 {return part}}
    return .Pelvis
}

@(private)
body_parents :: proc(view:aa.Skeleton_View,allocator:=context.temp_allocator) -> []i32 {
    parents:=make([]i32,len(view.bones),allocator)
    for &bone,i in view.bones {parents[i]=bone.parent}
    return parents
}
