package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import lib "mirai:std/anim"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

// The .character id names, read from its file: its tables are views into file. A set is too
// large to pass through a multiple assignment: one store per value until odin-lang/Odin#7937
// (see ODIN_WORKAROUNDS).
@(private)
character_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (set:anim.Character_Set,ok:bool) {
    if !authoring_open(s,call,id,anim.CHARACTER_KIND,file) {return}
    read,found:=character_read(s,call,file)
    set=read
    ok=found
    return
}
@(private)
character_read :: proc(s:^editor.Session,call:^api.Call,file:^Authoring_File) -> (set:anim.Character_Set,ok:bool) {
    read,error:=anim.character_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .character",fmt.tprintf("%v",error),"The .character is invalid");return}
    set=read
    ok=true
    return
}

// The .character a set method edits: the one at path, whose other parts it keeps, or a new one
// there whose clips are those of animation; without clips, a new one of only modifiers may have none.
@(private)
character_target :: proc(s:^editor.Session,call:^api.Call,path:string,animation:base.Asset_Id,file:^Authoring_File,clips:=true) -> (set:anim.Character_Set,id:base.Asset_Id,ok:bool) {
    id,ok=authoring_set_target(s,call,path,anim.CHARACTER_KIND,".character",file);if !ok {return}
    if file.replaced {
        read,found:=character_read(s,call,file)
        if !found {ok=false;return}
        set=read
        if animation!={} {set.info.animation=animation}
        return
    }
    if animation=={} && clips {authoring_failure(call,"animation","Required","the .anim of the clips of a new .character","empty","A new .character needs the animation of its clips");id,ok={},false;return}
    set=anim.character_set_make(animation)
    return
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
    return authoring_publish(s,call,file,&doc)
}

// A .character: its locomotion, its layers and actions, its spaces, its warping and a page of
// the table of its modifiers that table names.
@(private)
character_inspect :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,table:Profile_Table,offset,limit:u32) {
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,ok:=character_open(s,call,id,&file);if !ok {return}
    sections:=make([]Action_Section_Params,len(set.actions.sections),call.allocator)
    if len(set.actions.sections)>0 && sections==nil {authoring_failure(call,"sections","Out_Of_Memory","memory for the sections","allocation failed","The sections could not be listed",api.SERVER_ERROR);return}
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,id,file.path)
    api.write_key(out,"animation");serial.write_u8(out,'"');serial.text_write_asset_id(out,set.info.animation);serial.write_u8(out,'"')
    character_match_write(s,call,id,set.match,offset,limit)
    for section,i in set.actions.sections {sections[i]={action=set.actions.actions[section.action].name,name=section.name};if section.next>=0 {sections[i].next=set.actions.sections[section.next].name}}
    api.write_uint(out,"layers_total",u64(len(set.actions.layers)));api.write_uint(out,"actions_total",u64(len(set.actions.actions)));api.write_uint(out,"sections_total",u64(len(sections)))
    program_rows(call,"layers",set.actions.layers,offset,limit);program_rows(call,"actions",set.actions.actions,offset,limit);program_rows(call,"sections",sections,offset,limit)
    api.write_key(out,"spaces");serial.write_u8(out,'[')
    for &space,i in set.spaces {
        if i>0 {serial.write_u8(out,',')}
        first,count:=anim.character_space_samples(set,i)
        serial.text_write_raw(out,"{");api.write_key(out,"info",true);authoring_write_value(call,&space,type_info_of(anim.Blend_Info))
        program_rows(call,"samples",set.space_samples[first:][:count],0,lib.BLEND_MAX_SAMPLES);serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    api.write_key(out,"warp");authoring_write_value(call,&set.motion.warp,type_info_of(anim.Pose_Warp_Profile))
    api.write_uint(out,"windows_total",u64(len(set.motion.windows)));program_rows(call,"windows",set.motion.windows,offset,limit)
    api.write_uint(out,"distances_total",u64(len(set.motion.distances)))
    api.write_key(out,"distances");serial.text_write_raw(out,"[")
    first:=min(int(offset),len(set.motion.distances));last:=min(first+int(limit),len(set.motion.distances))
    for &track,i in set.motion.distances[first:last] {
        if i>0 {serial.text_write_raw(out,",")};serial.text_write_raw(out,"{");api.write_int(out,"index",i64(first+i),true)
        api.write_key(out,"value");serial.text_write_raw(out,"{")
        api.write_text(out,"clip",base.text_get(track.clip[:]),true);api.write_text(out,"name",base.text_get(track.name[:]))
        api.write_key(out,"animation");serial.write_u8(out,'"');serial.text_write_asset_id(out,track.animation);serial.write_u8(out,'"')
        api.write_key(out,"keys");serial.text_write_raw(out,"[")
        for &key,k in set.motion.keys[track.first:][:track.count] {if k>0 {serial.text_write_raw(out,",")};authoring_write_value(call,&key,type_info_of(lib.Distance_Key))}
        serial.text_write_raw(out,"]}}")
    }
    serial.write_u8(out,']')
    character_modifiers_write(call,set.pose,table,offset,limit)
    serial.text_write_raw(out,"}")
}

// The locomotion of a set with a page of its clips and the database each skeleton a rig played it
// on built.
@(private)
character_match_write :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,profile:anim.Match_Profile,offset,limit:u32) {
    modes:=locomotion_modes(s.info)
    out:=call.out
    info:=profile.info
    api.write_key(out,"match");authoring_write_value(call,&info,type_info_of(anim.Match_Info))
    api.write_uint(out,"match_clips_total",u64(len(profile.clips)));api.write_key(out,"match_clips");serial.text_write_raw(out,"[")
    start:=min(int(offset),len(profile.clips));end:=min(start+int(limit),len(profile.clips))
    for &clip,i in profile.clips[start:end] {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_raw(out,"{");api.write_text(out,"clip",base.text_get(clip.clip[:]),true)
        if clip.animation!={} {api.write_key(out,"animation");serial.write_u8(out,'"');serial.text_write_asset_id(out,clip.animation);serial.write_u8(out,'"')}
        api.write_key(out,"modes");match_modes_write(out,modes,clip.modes)
        api.write_bool(out,"loop",clip.loop);api.write_bool(out,"entry",clip.entry)
        if clip.speed>0 {api.write_key(out,"speed");api.write_number(out,clip.speed)}
        if names,count:=anim.match_source_clips(&clip);count>1 {
            api.write_key(out,"blend");serial.write_u8(out,'[')
            for name,k in names[1:count] {if k>0 {serial.write_u8(out,',')};serial.text_write_string(out,name)}
            serial.text_write_raw(out,`],"samples":[`);listed:=0
            for &sample in profile.samples {
                if int(sample.source)!=start+i {continue}
                if listed>0 {serial.write_u8(out,',')};listed+=1
                serial.text_write_raw(out,`{"weights":[`)
                for w,k in sample.weights {if k>0 {serial.write_u8(out,',')};api.write_number(out,w)}
                serial.write_u8(out,']')
                if sample.speed>0 {api.write_key(out,"speed");api.write_number(out,sample.speed)}
                serial.write_u8(out,'}')
            }
            serial.write_u8(out,']')
        }
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]");api.write_key(out,"databases");serial.write_u8(out,'[');written:=0
    if s.info!=nil {if cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Character_Assets);cache!=nil {
        for &content in cache.contents {
            if content.id!=id {continue}
            for &built in content.databases {
                if written>0 {serial.write_u8(out,',')};written+=1
                row:=Asset_Match_Database{rows=u32(built.database.rows),error=built.error}
                if built.error==.None {row.bytes=u64(lib.match_database_size(built.database))}
                authoring_write_value(call,&row,type_info_of(Asset_Match_Database))
            }
        }
    }}
    serial.write_u8(out,']')
}
