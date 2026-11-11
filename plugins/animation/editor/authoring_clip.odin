package animation_editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

AUTHORING_KEYS :: 512
Authoring_Keyframe :: struct {
    time:f32 `mirai:"min=0,unit=s"`,
    value:mm.Vec4,
    ease:mm.Ease `mirai:"optional"`,
    interpolation:lib.Interpolation `mirai:"optional"`,
    tangents:bool `mirai:"optional"`,
    in_slope,out_slope:mm.Vec4 `mirai:"optional"`,
}

// What a key holds at its time; animation.key.set names the time apart.
Authoring_Key_Value :: struct {
    value:mm.Vec4 `mirai:"optional"`,
    ease:mm.Ease `mirai:"optional"`,
    interpolation:lib.Interpolation `mirai:"optional"`,
    tangents:bool `mirai:"optional"`,
    in_slope,out_slope:mm.Vec4 `mirai:"optional"`,
}

// Seconds within which two times are the same key or marker.
AUTHORING_TIME_EPSILON :: 1e-4

@(private)
authoring_keyframe :: proc(value:Authoring_Keyframe) -> lib.Keyframe {
    return {time=value.time,value=value.value,ease=value.ease,interpolation=value.interpolation,tangents=value.tangents,in_slope=value.in_slope,out_slope=value.out_slope}
}
Clip_Create_Params :: struct {
    path:[1024]u8 `mirai:"text,label=An .anim: the clip goes after those of what is there"`,
    name:[64]u8 `mirai:"text"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Clip_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text,label=Existing clip name"`,
    name:[64]u8 `mirai:"text,label=New clip name"`,
    root:aa.Animation_Root,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Track_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=Canonical bone or rigid-node path; scalar curve name for Float/Vector"`,
    property:lib.Property,
    slot:u8 `mirai:"optional"`,
    keys:[AUTHORING_KEYS]Authoring_Keyframe `mirai:"optional,label=Ordered by time; animation.key.set edits a longer track key by key"`,
    remove:bool `mirai:"optional,label=Removes the track"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Key_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=Canonical bone or rigid-node path; scalar curve name for Float/Vector"`,
    property:lib.Property,
    slot:u8 `mirai:"optional"`,
    time:f32 `mirai:"min=0,unit=s,label=The key at this time is replaced, moved or removed; with no key there it is inserted in order"`,
    key:Authoring_Key_Value `mirai:"optional,label=What the key holds; a field left out keeps what the key at time holds, and a new key needs value"`,
    to:f32 `mirai:"optional,min=0,unit=s,label=Moves the key at time here; a key already at to is replaced"`,
    remove:bool `mirai:"optional,label=Removes the key at time"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Marker_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    name:[aa.ANIMATION_NAME_CAPACITY]u8 `mirai:"text,label=The marker by its name; on an actor of a cinematic, the action it plays there"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=The entity it is on, named as a track target: on a camera of a cinematic it is a shot from its time on, blended in over its duration; on another actor it plays the action of its name until a span ends. Empty: a marker of the clip"`,
    time:f32 `mirai:"optional,min=0,unit=s,label=Where it goes; needed unless it is removed"`,
    duration:f32 `mirai:"optional,min=0,unit=s,label=Makes it a span of that length: a section or a window of an action, a warp window, the blend into a shot"`,
    at:f32 `mirai:"optional,min=0,unit=s,label=Of a name several markers of the target have: the time of the one to change or remove"`,
    add:bool `mirai:"optional,label=Adds one more of that name at time instead of changing the one it has"`,
    remove:bool `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
authoring_clip_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{params=type_info_of(Clip_Create_Params),result=type_info_of(Authoring_Write_Result),name="animation.clip.create",summary="Creates an empty named clip in a new .anim or after the clips of an existing one. One step of undo.",run=authoring_clip_create})
    editor.api_method_register(s,{params=type_info_of(Clip_Set_Params),result=type_info_of(Authoring_Write_Result),name="animation.clip.set",summary="Renames a clip and replaces its root motion; its tracks and markers stay.",run=authoring_clip_set})
    editor.api_method_register(s,{params=type_info_of(Track_Set_Params),result=type_info_of(Authoring_Write_Result),name="animation.track.set",summary="Creates, replaces or removes the track of a clip found by target, property and slot.",run=authoring_track_set})
    editor.api_method_register(s,{params=type_info_of(Key_Set_Params),result=type_info_of(Authoring_Write_Result),name="animation.key.set",summary="Replaces, inserts, moves or removes one key of a track; the clip must stay valid, with finite values and ordered times. One step of undo.",run=authoring_key_set})
    editor.api_method_register(s,{params=type_info_of(Marker_Set_Params),result=type_info_of(Authoring_Write_Result),name="animation.marker.set",summary="Replaces, appends or removes a named clip marker used for animation events and synchronization, or a span with a duration that actions and warping name.",run=authoring_marker_set})
}

@(private)
authoring_clip_index :: proc(call:^api.Call,view:aa.Animation_View,name:string) -> (int,bool) {
    for &clip,i in view.clips {if base.text_get(clip.name[:])==name || name=="" && i==0 {return i,true}}
    authoring_failure(call,"clip","Missing_Clip","a clip name in the asset",name,"The clip does not exist")
    return -1,false
}

@(private)
authoring_clip_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,result:^Authoring_File) -> (view:aa.Animation_View,ok:bool) {
    if !authoring_open(s,call,id,aa.KIND_ANIMATION,result) {return}
    error:aa.Error
    view,error=aa.animation_view(&result.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .anim asset",fmt.tprintf("%v",error),"The animation asset is invalid");return}
    return view,true
}

@(private)
authoring_clip_descs :: proc(view:aa.Animation_View,call:^api.Call) -> (clips:[]aa.Animation_Clip_Desc,ok:bool) {
    if clips,ok=aa.animation_descs(view,call.allocator);!ok {authoring_failure(call,"clips","Out_Of_Memory","memory for clip descriptions","allocation failed","The clip descriptions could not be allocated",api.INTERNAL_ERROR)}
    return
}

// rows with value put at an index, the ones from there moved one further.
@(private)
authoring_insert_row :: proc(rows:[]$T,index:int,value:T,maximum:int,allocator:=context.temp_allocator) -> (result:[]T,ok:bool) {
    if index<0 || index>len(rows) || len(rows)>=maximum {return}
    error:runtime.Allocator_Error
    result,error=make([]T,len(rows)+1,allocator)
    if error!=nil {return nil,false}
    copy(result[:index],rows[:index]);result[index]=value;copy(result[index+1:],rows[index:])
    return result,true
}

@(private)
authoring_clip_save :: proc(s:^editor.Session,call:^api.Call,target:Authoring_File,id:base.Asset_Id,view:aa.Animation_View,clips:[]aa.Animation_Clip_Desc) {
    doc:aa.Document
    defer aa.document_destroy(&doc)
    if error:=aa.animation_document(&doc,&s.app.assets.types,{id=id,clips=clips,source=view.source},s.app.allocator);error!=.None {authoring_failure(call,"clips","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid names, root metadata and ordered finite keys within clip capacities",fmt.tprintf("%v",error),"The animation edit could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc,api.call_result(call,Authoring_Write_Result))
}

@(private)
authoring_clip_inspect :: proc(s:^editor.Session,call:^api.Call,p:^Asset_Inspect_Params,r:^Asset_Inspect_Result) {
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    selected,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    base.text_set(r.path[:],file.path)
    r.clips=make([]Asset_Clip_Name,len(view.clips),call.allocator)
    for &clip,i in r.clips {clip.name=view.clips[i].name}
    clip:=view.clips[selected]
    r.clip,r.root=clip.name,clip.root
    tracks:=view.tracks[clip.first_track:][:clip.track_count]
    first:=min(int(p.offset),len(tracks))
    r.tracks_total,r.tracks=u32(len(tracks)),make([]Asset_Clip_Track,min(first+int(p.limit),len(tracks))-first,call.allocator)
    for &row,i in r.tracks {track:=tracks[first+i];row={target=track.target,property=track.property,slot=track.slot,keys_total=u32(track.key_count)}}
    markers:=view.markers[clip.first_marker:][:clip.marker_count]
    r.markers_total,r.markers=u32(len(markers)),authoring_page(call,markers,p.offset,p.limit)
}

@(private)
authoring_clip_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clip_Create_Params)
    path:=base.text_get(p.path[:])
    existing,found,at:=authoring_at(s,call,path,aa.KIND_ANIMATION,".anim");if !at {return}
    clip:=aa.Animation_Clip_Desc{name=base.text_get(p.name[:])}
    if found {
        target:Authoring_File;defer aa.asset_close(&target.file)
        view,ok:=authoring_clip_open(s,call,existing,&target);if !ok {return}
        clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
        updated,appended:=authoring_replace_row(clips,len(clips),clip,false,aa.ANIMATION_MAX_CLIPS,call.allocator)
        if !appended {authoring_failure(call,"clips","Capacity","space for an additional clip","full or allocation failed","The animation asset has no capacity for another clip");return}
        authoring_clip_save(s,call,target,existing,view,updated)
        return
    }
    target,id,ok:=authoring_create_target(s,call,path,".anim");if !ok {return}
    authoring_clip_save(s,call,target,id,{},([]aa.Animation_Clip_Desc{clip}))
}

@(private)
authoring_clip_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clip_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    clips[index].name,clips[index].root=base.text_get(p.name[:]),p.root
    authoring_clip_save(s,call,file,p.asset,view,clips)
}

@(private)
authoring_track_inspect :: proc(s:^editor.Session,call:^api.Call,p:^Asset_Inspect_Params,r:^Asset_Inspect_Result) {
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clip:=view.clips[index]
    selected:=-1
    for &each,i in view.tracks[clip.first_track:][:clip.track_count] {if base.text_get(each.target[:])==base.text_get(p.target[:]) && each.property==p.property && each.slot==p.slot {selected=i;break}}
    if selected<0 {authoring_failure(call,"target","Missing_Track","a track of the clip by target, property and slot",base.text_get(p.target[:]),"The clip has no such track",fix="animation.asset.inspect of the clip lists its tracks");return}
    track:=view.tracks[clip.first_track+u32(selected)]
    keys:=view.keys[track.first_key:][:track.key_count]
    base.text_set(r.path[:],file.path)
    r.clip,r.target,r.property,r.slot,r.keys_total=clip.name,track.target,track.property,track.slot,u32(len(keys))
    r.keys=authoring_page(call,keys,p.offset,p.limit)
}

@(private)
authoring_track_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Track_Set_Params)
    if !authoring_editable(s,call) {return}
    count,present:=api.params_array_count(call,"keys")
    if !p.remove && !present || count>len(p.keys) {authoring_failure(call,"keys","Capacity","an array with at most 512 entries",fmt.tprintf("%d entries; present=%t",count,present),"keys must be an array with at most 512 entries");return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    tracks:=clips[index].tracks
    at:=len(tracks)
    for track,i in tracks {if track.target==base.text_get(p.target[:]) && track.property==p.property && track.slot==p.slot {at=i;break}}
    keys,error:=make([]lib.Keyframe,count,call.allocator)
    if error!=nil {authoring_failure(call,"keys","Out_Of_Memory","memory for track keys","allocation failed","The keys could not be prepared",api.INTERNAL_ERROR);return}
    for value,i in p.keys[:count] {keys[i]=authoring_keyframe(value)}
    updated,replaced:=authoring_replace_row(tracks,at,aa.Animation_Track_Desc{target=base.text_get(p.target[:]),property=p.property,slot=p.slot,keys=keys},p.remove,aa.ANIMATION_MAX_TRACKS,call.allocator)
    if !replaced {authoring_failure(call,"target","Invalid_Edit","an existing track to remove or capacity to add","missing track, capacity exceeded or allocation failed","The track cannot be added or removed");return}
    clips[index].tracks=updated
    authoring_clip_save(s,call,file,p.asset,view,clips)
}

@(private)
authoring_key_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Key_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    moving:=authoring_field_present(call,"to")
    if p.remove && moving {authoring_failure(call,"to","Invalid_Edit","to or remove, not both","both","A key is moved or removed",fix="Pass to to move the key at time, or remove to take it out");return}
    if !p.remove && !moving && !authoring_field_present(call,"key") {authoring_failure(call,"key","Required","the key to write at time, unless it is moved or removed","missing","Supply key, to or remove");return}
    selected:=-1
    for &each,i in clips[index].tracks {if each.target==base.text_get(p.target[:]) && each.property==p.property && each.slot==p.slot {selected=i;break}}
    if selected<0 {authoring_failure(call,"target","Missing_Track","a track of the clip by target, property and slot",base.text_get(p.target[:]),"The clip has no such track",fix="animation.track.set creates it");return}
    track:=&clips[index].tracks[selected]
    at,exists:=authoring_key_at(track.keys,p.time)
    if (p.remove || moving) && !exists {authoring_failure(call,"time","Missing_Key","the time of a key of the track",fmt.tprintf("%f",p.time),"The track has no key at that time",fix="animation.asset.inspect with section Track lists its keys");return}
    keys:[]lib.Keyframe
    done:bool
    if p.remove {
        keys,done=authoring_replace_row(track.keys,at,lib.Keyframe{},true,aa.ANIMATION_MAX_KEYS,call.allocator)
    } else {
        key:=track.keys[at] if exists else lib.Keyframe{}
        given:=api.json_member(call.raw,"key")
        has :: proc(given,field:string) -> bool {return api.json_member(given,field)!=""}
        if !exists && !has(given,"value") {authoring_failure(call,"key.value","Required","the value of a new key","missing","No key is at time, so the key needs its value",fix="Pass key.value, or the time of a key of the track");return}
        if has(given,"value") {key.value=p.key.value}
        if has(given,"ease") {key.ease=p.key.ease}
        if has(given,"interpolation") {key.interpolation=p.key.interpolation}
        if has(given,"tangents") {key.tangents=p.key.tangents}
        if has(given,"in_slope") {key.in_slope=p.key.in_slope}
        if has(given,"out_slope") {key.out_slope=p.key.out_slope}
        key.time=p.to if moving else p.time
        rest:=track.keys
        if moving {
            if rest,done=authoring_replace_row(track.keys,at,key,true,aa.ANIMATION_MAX_KEYS,call.allocator);done {at,exists=authoring_key_at(rest,key.time)}
        } else {done=true}
        if done && exists {keys,done=authoring_replace_row(rest,at,key,false,aa.ANIMATION_MAX_KEYS,call.allocator)} else if done {keys,done=authoring_insert_row(rest,at,key,aa.ANIMATION_MAX_KEYS,call.allocator)}
    }
    if !done {authoring_failure(call,"time","Invalid_Edit","a track with room for the key",fmt.tprintf("%d keys; remove=%t",len(track.keys),p.remove),"The key edit cannot be prepared within capacity");return}
    track.keys=keys
    authoring_clip_save(s,call,file,p.asset,view,clips)
}

// Where a key at time is in keys ordered by time: its index, or where it goes.
@(private)
authoring_key_at :: proc(keys:[]lib.Keyframe,time:f32) -> (at:int,exists:bool) {
    for &key,i in keys {
        if abs(key.time-time)<=AUTHORING_TIME_EPSILON {return i,true}
        if key.time>time {return i,false}
    }
    return len(keys),false
}

@(private)
authoring_marker_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Marker_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    name,target:=base.text_get(p.name[:]),base.text_get(p.target[:])
    rows:=clips[index].markers
    if !p.remove && !authoring_field_present(call,"time") {authoring_failure(call,"time","Required","where the marker goes, unless it is removed","missing","Supply time, or remove");return}
    at:=len(rows)
    if !p.add {
        given_at:=authoring_field_present(call,"at")
        same:=0
        times:=strings.builder_make(call.allocator)
        for &row,i in rows {
            if row.name!=name || row.target!=target {continue}
            fmt.sbprintf(&times,"%s%f",same>0?", ":"",row.time)
            same+=1
            if !given_at || abs(row.time-p.at)<=AUTHORING_TIME_EPSILON {at=i}
        }
        if given_at && at==len(rows) {authoring_failure(call,"at","Missing_Marker","the time of a marker of that name",strings.to_string(times),"The clip has no marker of that name and target at that time",fix="animation.asset.inspect of the clip lists its markers");return}
        if !given_at && same>1 {authoring_failure(call,"name","Ambiguous_Marker","the time of one of them in at, or add true for one more",strings.to_string(times),fmt.tprintf("%d markers are named %s",same,name));return}
    }
    if p.remove && at==len(rows) {authoring_failure(call,"name","Missing_Marker","the name of a marker of the clip",name,"The clip has no marker of that name and target",fix="animation.asset.inspect of the clip lists its markers");return}
    markers,replaced:=authoring_replace_row(rows,at,aa.Animation_Marker_Desc{p.time,name,p.duration,target},p.remove,aa.ANIMATION_MAX_MARKERS,call.allocator)
    if !replaced {authoring_failure(call,"name","Invalid_Edit","a clip with room for the marker",fmt.tprintf("%d markers; remove=%t",len(rows),p.remove),"The marker edit cannot be prepared within capacity");return}
    clips[index].markers=markers
    authoring_clip_save(s,call,file,p.asset,view,clips)
}
