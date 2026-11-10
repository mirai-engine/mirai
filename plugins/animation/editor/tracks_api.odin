package animation_editor

import "core:fmt"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

// What the Tracks tool asks of a clip besides animation.key.set and animation.track.set: where its
// head is, and the keys of what an entity has now. How the tracks of a clip name the entities and
// the fields they move is the binding of the runtime (anim bind, field_resolve), read back.

Tracks_Show_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity whose Animation plays the clip"`,
    command:anim.Timeline_Command `mirai:"optional,label=Seek puts the head at time (without time it keeps it); Play plays the preview from the start and Resume from the head; Pause and Stop stop it, Stop at the start"`,
    time:f32 `mirai:"optional,min=0,unit=s"`,
    speed:f32 `mirai:"optional,min=0,max=4,label=Of the preview; 0 keeps it"`,
}
Tracks_Show_Result :: struct {
    asset:base.Asset_Id `mirai:"label=The .anim: animation.asset.inspect reads its tracks and keys"`,
    clip:[anim.CLIP_CAPACITY]u8 `mirai:"text"`,
    time:f32 `mirai:"unit=s,label=Where the head is: the scene shows the clip there"`,
    duration:f32 `mirai:"unit=s"`,
    playing:bool,
}

Key_Capture_Params :: struct {
    animation:editor.Api_Entity_Text `mirai:"text,entity,label=The entity whose Animation plays the clip"`,
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=An entity the clip moves: each of its tracks gets a key at time with what the entity has now"`,
    time:f32 `mirai:"min=0,unit=s"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Key_Capture_Result :: struct {
    using written:Authoring_Write_Result `mirai:"inline"`,
    keys:u32 `mirai:"label=The tracks keyed"`,
}

@(private)
tracks_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,TRACKS_TOOL,"Tracks",.Play)
    editor.api_method_register(s,Tracks_Show_Params,Tracks_Show_Result,{name="animation.tracks.show",summary="Turns on the Tracks tool on the clip of an entity's Animation and moves its head: the scene shows the clip at the head without changing the document. Edit only.",run=tracks_show})
    editor.api_method_register(s,Key_Capture_Params,Key_Capture_Result,{name="animation.key.capture",summary="Keys at a time every track of the clip of an Animation that moves an entity, with the transform and the fields the entity has now: a key there is updated, else one is inserted. One step of undo.",run=key_capture})
}

@(private)
tracks_show :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Tracks_Show_Params)
    if s.mode!=.Edit {api.call_fail(call,api.INVALID_PARAMS,"the Tracks tool shows a clip in Edit; in Play, animation.request seeks it");return}
    w:=editor.edited_world(s)
    e,found:=editor.api_call_entity(call,w,p.entity[:]);if !found {return}
    animation,animated:=editor.entity_get(w,e,anim.Animation)
    if !animated {api.call_fail(call,api.INVALID_PARAMS,"the entity has no Animation: give it one whose asset is an .anim, or name the entity whose clip moves it");return}
    t:=tracks_tool_state(s)
    if t==nil {api.call_fail(call,api.SERVER_ERROR,"the Tracks tool is not in this build of the editor");return}
    // Another tool that shows the clip of the entity keeps it.
    kept:=t.on && t.entity==e
    if !kept {
        editor.tool_set(s,TRACKS_TOOL,true)
        t.selected=s.selection.entities[0] if len(s.selection.entities)>0 else core.NONE
    }
    if !kept && !editor.tool_on(s,TRACKS_TOOL) {api.call_fail(call,api.INVALID_PARAMS,"the Tracks tool works on the scene: bring the scene to the front with editor.document first");return}
    out:=api.call_result(call,Tracks_Show_Result)
    out.time,out.playing,_=tracks_command(s,e,p.command,p.time,authoring_field_present(call,"time"),p.speed)
    out.asset=animation.asset
    copy(out.clip[:],animation.clip[:])
    if view,clip,ok:=tracks_clip(s,t,w);ok {out.duration=tracks_duration(view,clip)}
}

// The command of a timeline applied to the preview of the tool on the clip of an entity, which it
// shows from now: Seek moves the head when timed, and with neither shows the scene there again.
// seconds and playing: the head after it.
tracks_command :: proc(s:^editor.Session,entity:core.Entity,command:anim.Timeline_Command,time:f32,timed:bool,speed:f32) -> (seconds:f32,playing,ok:bool) {
    t:=tracks_tool_state(s)
    if t==nil {return}
    tracks_choose(t,entity)
    switch command {
    case .Play: t.head,t.playing=0,true
    case .Pause: t.playing=false
    case .Resume: t.playing=true
    case .Stop: t.head,t.playing=0,false
    case .Seek: if timed {t.head,t.playing=time,false}
    }
    if speed>0 {t.speed=speed}
    t.shown=-1
    return t.head,t.playing,true
}

@(private)
key_capture :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Key_Capture_Params)
    if !authoring_editable(s,call) {return}
    w:=editor.edited_world(s)
    animated,found:=editor.api_call_entity(call,w,p.animation[:],"animation");if !found {return}
    e,there:=editor.api_call_entity(call,w,p.entity[:]);if !there {return}
    animation,has:=editor.entity_get(w,animated,anim.Animation)
    if !has {authoring_failure(call,"animation","Missing_Animation","an entity with an Animation","none","The entity plays no clip",fix="Give it an Animation whose asset is an .anim");return}
    name,reached:=track_name(w,animated,e)
    if !reached {authoring_failure(call,"entity","Not_Animated","the entity of animation, one below it, or one whose Animation_Target names it",editor.entity_label(w,e),"The clip does not move this entity",fix="Pick an entity below animation, or give it an Animation_Target whose animation is that entity");return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,animation.asset,&file);if !ok {return}
    index,clip_found:=authoring_clip_index(call,view,base.text_get(animation.clip[:]));if !clip_found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    schema:serial.Schema
    serial.schema_init(&schema,call.allocator)
    keyed:u32
    for &track in clips[index].tracks {
        node,component,field:=track_parts(track.target)
        if node!=name {continue}
        value,read:=track_value(w,&schema,e,track.property,component,field)
        if !read {continue}
        at,exists:=authoring_key_at(track.keys,p.time)
        // A rotation turns the short way from the key before it.
        if track.property==.Rotation && at>0 {value=lib.quat_align(value,track.keys[at-1].value)}
        key:=track.keys[at] if exists else lib.Keyframe{}
        key.time,key.value=p.time,value
        keys:[]lib.Keyframe
        done:bool
        if exists {keys,done=authoring_replace_row(track.keys,at,key,false,aa.ANIMATION_MAX_KEYS,call.allocator)} else {keys,done=authoring_insert_row(track.keys,at,key,aa.ANIMATION_MAX_KEYS,call.allocator)}
        if !done {authoring_failure(call,"time","Capacity","a track with room for the key",fmt.tprintf("%d keys",len(track.keys)),"The key cannot be added within capacity");return}
        track.keys=keys
        keyed+=1
    }
    if keyed==0 {authoring_failure(call,"entity","Missing_Track","a track of the clip that moves the entity with a value it has",name,"The clip has no track for this entity",fix="animation.track.set adds one, with the name of the entity as target");return}
    doc:aa.Document
    defer aa.document_destroy(&doc)
    if error:=aa.animation_document(&doc,&s.app.assets.types,{id=animation.asset,clips=clips,source=view.source},s.app.allocator);error!=.None {authoring_failure(call,"clips","Invalid_Definition","keys within the clip capacities",fmt.tprintf("%v",error),"The keys could not be stored",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    r:=api.call_result(call,Key_Capture_Result)
    r.keys=keyed
    authoring_publish(s,call,file,&doc,&r.written)
}

// The node a track target names, and for a "@field" track the component and its field.
track_parts :: proc(target:string) -> (node,component,field:string) {
    if n,c,f,ok:=aa.animation_field_target(target);ok {return n,c,f}
    return target,"",""
}

// The name the tracks of the clip of animated give e, as the runtime binds them: animated is ""
// unless its Animation_Target gives a path; one below it that is not under another Animation goes
// by its Animation_Target path or else its name, and one whose Animation_Target names animated by
// that path or else its name. False for an entity the clip does not reach.
track_name :: proc(w:core.World_Ref,animated,e:core.Entity) -> (name:string,ok:bool) {
    target,explicit:=editor.entity_get(w,e,anim.Animation_Target)
    path:=fmt.tprintf("%s",base.text_get(target.path[:]))
    if e==animated {return path if explicit else "",true}
    if explicit && target.animation==animated {return path if path!="" else editor.entity_name(w,e),true}
    if explicit && target.animation!=core.NONE || editor.entity_has(w,e,anim.Animation) {return}
    for parent:=editor.entity_parent(w,e);parent!=core.NONE;parent=editor.entity_parent(w,parent) {
        if parent==animated {return path if explicit else editor.entity_name(w,e),true}
        if editor.entity_has(w,parent,anim.Animation) {return}
    }
    return
}

// What a track keys for an entity now: its local Transform for Position, Rotation and Scale, the
// field of a component for a "@field" track. False when the entity lacks it.
track_value :: proc(w:core.World_Ref,schema:^serial.Schema,e:core.Entity,property:lib.Property,component,field:string) -> (value:mm.Vec4,ok:bool) {
    if component=="" {
        if property>.Scale || !editor.entity_has(w,e,core.Transform) {return}
        t:=editor.entity_local(w,e)
        #partial switch property {
        case .Position: return {t.position.x,t.position.y,t.position.z,0},true
        case .Rotation: return lib.quat_vec4(t.rotation),true
        }
        return {t.scale.x,t.scale.y,t.scale.z,0},true
    }
    bound,problem,_:=anim.field_resolve(w,schema,component,field,property)
    if problem!=.None {return}
    table:=core.world_table_at(w,bound.table)
    row:=core.raw_row(table,e)
    if row<0 {return}
    return anim.field_read(bound,([^]u8)(core.raw_value(table,bound.table.info,row))),true
}

// A value of an entity a track can key: its target in the clip and its property.
Track_Field :: struct {target,label:string,property:lib.Property}

// What of e a new track of the clip of animated can key: Position, Rotation and Scale, and the fields
// of its components a track writes. Empty for an entity the clip does not reach.
track_fields :: proc(w:core.World_Ref,animated,e:core.Entity) -> []Track_Field {
    name,reached:=track_name(w,animated,e)
    if !reached {return nil}
    fields:=make([dynamic]Track_Field,context.temp_allocator)
    if editor.entity_has(w,e,core.Transform) {
        for property in ([3]lib.Property{.Position,.Rotation,.Scale}) {append(&fields,Track_Field{name,fmt.tprintf("%v",property),property})}
    }
    prefix:=fmt.tprintf("%s/",name) if name!="" else ""
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    for &table in w.info.tables {
        if table.place!=w.place || table.type==core.Transform || core.raw_row(core.world_table_at(w,&table),e)<0 {continue}
        type,added:=serial.schema_add_type_info(&schema,table.info)
        if !added || schema.types[type].kind!=.Struct {continue}
        for &field in schema.fields[schema.types[type].first:][:schema.types[type].count] {
            if field.flags&{.Transient,.Hidden,.Read_Only}!={} {continue}
            for property in ([2]lib.Property{.Float,.Vector}) {
                if _,problem,_:=anim.field_resolve(w,&schema,table.name,field.name,property);problem!=.None {continue}
                label:=fmt.tprintf("%s.%s",table.name,field.name)
                append(&fields,Track_Field{fmt.tprintf("%s%s%s",prefix,aa.ANIMATION_FIELD_PATH,label),label,property})
                break
            }
            if len(fields)>=TRACKS_FIELDS {return fields[:]}
        }
    }
    return fields[:]
}
