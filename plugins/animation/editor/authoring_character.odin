package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import lib "mirai:std/anim"
import anim "plugins:animation/runtime"

// The .character id names, read from its file: its tables are views into file.
@(private)
character_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (set:anim.Character_Set,ok:bool) {
    if !authoring_open(s,call,id,anim.CHARACTER_KIND,file) {return}
    return character_read(s,call,file)
}
@(private)
character_read :: proc(s:^editor.Session,call:^api.Call,file:^Authoring_File) -> (set:anim.Character_Set,ok:bool) {
    error:asset.Error
    if set,error=anim.character_view(&file.file,&s.app.assets.types);error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .character",fmt.tprintf("%v",error),"The .character is invalid");return}
    return set,true
}

// The .character a set method edits: the one at path, whose other parts it keeps, or a new one
// there whose clips are those of animation; without clips, a new one of only modifiers may have none.
@(private)
character_target :: proc(s:^editor.Session,call:^api.Call,path:string,animation:base.Asset_Id,file:^Authoring_File,clips:=true) -> (set:anim.Character_Set,id:base.Asset_Id,ok:bool) {
    id,ok=authoring_set_target(s,call,path,anim.CHARACTER_KIND,".character",file);if !ok {return}
    if file.replaced {
        if set,ok=character_read(s,call,file);!ok {return}
        if animation!={} {set.info.animation=animation}
        return set,id,true
    }
    if animation=={} && clips {authoring_failure(call,"animation","Required","the .anim of the clips of a new .character","empty","A new .character needs the animation of its clips");return {},{},false}
    return anim.character_set_make(animation),id,true
}

// Publishes a set as a step of the history; false, with the failure of the call, when it is
// not valid.
@(private)
character_publish :: proc(s:^editor.Session,call:^api.Call,file:Authoring_File,id:base.Asset_Id,set:anim.Character_Set) -> bool {
    doc:asset.Document;defer asset.document_destroy(&doc)
    if error:=anim.character_document(&doc,&s.app.assets.types,id,set,s.app.allocator);error!=.None {
        authoring_failure(call,"definition","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","a valid .character within its capacities",fmt.tprintf("%v",error),"The .character could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS)
        return false
    }
    return authoring_publish(s,call,file,&doc,api.call_result(call,Authoring_Write_Result))
}

// A .character: its locomotion, its layers and actions, its spaces, its warping and a page of
// the table of its modifiers that table names.
@(private)
character_inspect :: proc(s:^editor.Session,call:^api.Call,p:^Asset_Inspect_Params,r:^Asset_Inspect_Result) {
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,ok:=character_open(s,call,p.asset,&file);if !ok {return}
    sections:=make([]Action_Section_Params,len(set.actions.sections),call.allocator)
    if len(set.actions.sections)>0 && sections==nil {authoring_failure(call,"sections","Out_Of_Memory","memory for the sections","allocation failed","The sections could not be listed",api.SERVER_ERROR);return}
    o,l:=p.offset,p.limit
    base.text_set(r.path[:],file.path)
    r.animation=set.info.animation
    character_match(s,call,p.asset,set.match,o,l,r)
    for section,i in set.actions.sections {sections[i]={action=set.actions.actions[section.action].name,name=section.name};if section.next>=0 {sections[i].next=set.actions.sections[section.next].name}}
    r.layers_total,r.actions_total,r.sections_total=u32(len(set.actions.layers)),u32(len(set.actions.actions)),u32(len(sections))
    r.layers=authoring_pages(call,set.actions.layers,o,l,anim.Stack_Layer)
    r.actions=authoring_pages(call,set.actions.actions,o,l,anim.Action_Definition)
    r.sections=authoring_pages(call,sections,o,l,Action_Section_Params)
    r.spaces=make([]Asset_Space,len(set.spaces),call.allocator)
    for &space,i in r.spaces {
        first,count:=anim.character_space_samples(set,i)
        space={info=set.spaces[i],samples=authoring_pages(call,set.space_samples[first:][:count],0,lib.BLEND_MAX_SAMPLES,anim.Blend_Sample)}
    }
    r.warp=set.motion.warp
    r.windows_total,r.windows=u32(len(set.motion.windows)),authoring_pages(call,set.motion.windows,o,l,anim.Motion_Window)
    r.distances_total=u32(len(set.motion.distances))
    first:=min(int(o),len(set.motion.distances))
    r.distances=make([]Authoring_Page(Motion_Distance_Params),min(first+int(l),len(set.motion.distances))-first,call.allocator)
    for &page,i in r.distances {
        track:=set.motion.distances[first+i]
        page={index=u32(first+i),value={clip=track.clip,name=track.name,animation=track.animation}}
        copy(page.value.keys[:],set.motion.keys[track.first:][:track.count])
    }
    character_modifiers(call,set.pose,p.table,o,l,r)
}

// The locomotion of a set with a page of its clips and the database each skeleton a rig played it
// on built.
@(private)
character_match :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,profile:anim.Match_Profile,offset,limit:u32,r:^Asset_Inspect_Result) {
    modes:=locomotion_modes(s.info)
    r.match,r.match_clips_total=profile.info,u32(len(profile.clips))
    start:=min(int(offset),len(profile.clips));end:=min(start+int(limit),len(profile.clips))
    r.match_clips=make([]Asset_Match_Clip,end-start,call.allocator)
    for &row,i in r.match_clips {
        clip:=&profile.clips[start+i]
        row={clip=clip.clip,animation=clip.animation,modes=match_modes(call,modes,clip.modes),loop=clip.loop,entry=clip.entry,speed=clip.speed}
        names,count:=anim.match_source_clips(clip)
        if count<=1 {continue}
        row.blend=make([][64]u8,count-1,call.allocator)
        for &name,k in row.blend {base.text_set(name[:],names[1+k])}
        samples:=make([dynamic]Asset_Match_Sample,call.allocator)
        for &sample in profile.samples {if int(sample.source)==start+i {append(&samples,Asset_Match_Sample{weights=sample.weights,speed=sample.speed})}}
        row.samples=samples[:]
    }
    databases:=make([dynamic]Asset_Match_Database,call.allocator)
    if s.info!=nil {if cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Character_Assets);cache!=nil {
        for &content in cache.contents {
            if content.id!=id {continue}
            for &built in content.databases {
                row:=Asset_Match_Database{rows=u32(built.database.rows),error=built.error}
                if built.error==.None {row.bytes=u64(lib.match_database_size(built.database))}
                append(&databases,row)
            }
        }
    }}
    r.databases=databases[:]
}
