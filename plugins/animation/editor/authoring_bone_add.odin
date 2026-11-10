package animation_editor

import "core:fmt"
import "core:strings"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

// skeleton.bone.add: a bone the clips of another skeleton animate (Fortnite's
// hand_attach_r, which the body mesh does not weight) added to this one. It
// goes after the other bones, so the meshes skinned to them and every index
// keep theirs. Clips name bones by canonical path: the tracks of the clips
// given whose target ends in a node of the bone's name under another path
// take its path and drive it. The skeleton and the clips are written as one
// step of undo, or nothing is.

Skeleton_Bone_Add_Params :: struct {
    asset:base.Asset_Id,
    parent:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=The canonical path of the parent bone; empty for a root"`,
    bone:Authoring_Bone_Pose `mirai:"label=Its name and rest pose local to the parent; an omitted transform is identity"`,
    path:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Its canonical path; empty: the path of the parent then its name"`,
    clips:[16]base.Asset_Id `mirai:"optional,label=.anim assets whose tracks of a node with the bone's name under another path are renamed to its path so they drive it"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Skeleton_Bone_Add_Result :: struct {
    asset:base.Asset_Id,
    path:[1024]u8 `mirai:"text"`,
    bone:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=Its canonical path: the target its tracks name"`,
    clips:[1]Skeleton_Bone_Add_Clip `mirai:"list,label=The clips given: how many tracks now drive the bone"`,
    dry_run:bool `mirai:"optional,label=Only on a dry run: nothing was written"`,
}
Skeleton_Bone_Add_Clip :: struct {
    asset:base.Asset_Id,
    renamed:u32 `mirai:"label=Tracks taken from another path of a node of that name"`,
    driving:u32 `mirai:"label=Tracks of its clips that drive the bone now"`,
}

@(private)
authoring_bone_add_register :: proc(s:^editor.Session) {
    added:=Skeleton_Bone_Add_Params{bone={rotation={0,0,0,1},scale={1,1,1}}}
    editor.api_method_register(s,Skeleton_Bone_Add_Params,Skeleton_Bone_Add_Result,{name="skeleton.bone.add",summary="Adds a bone under a parent of a .skeleton, after the others so meshes and tracks keep theirs, and has the tracks of the clips given that animate a node of its name drive it.",defaults=&added,run=authoring_bone_add,writes_result=true})
}

// The last segment of a canonical path, unescaped: the name of its node.
@(private)
bone_path_name :: proc(path:string) -> string {
    at:=strings.last_index_byte(path,'/')
    name:=path[at+1:]
    name,_=strings.replace_all(name,"%2F","/",context.temp_allocator)
    name,_=strings.replace_all(name,"%25","%",context.temp_allocator)
    return name
}

// path then name as one more segment, escaped as importers write targets.
@(private)
bone_path_join :: proc(path,name:string) -> string {
    segment,_:=strings.replace_all(name,"%","%25",context.temp_allocator)
    segment,_=strings.replace_all(segment,"/","%2F",context.temp_allocator)
    return segment if path=="" else strings.concatenate({path,"/",segment},context.temp_allocator)
}

// The tracks of clips whose target names a node called name under another
// path take path, unless a clip already has tracks of path; returns how many
// were renamed and how many name path then.
@(private)
bone_tracks_follow :: proc(clips:[]aa.Animation_Clip_Desc,name,path:string) -> (renamed,driving:u32) {
    for &clip in clips {
        has:=false
        for track in clip.tracks {has||=track.target==path}
        for &track in clip.tracks {
            if !has && track.target!=path && bone_path_name(track.target)==name {
                track.target=path
                renamed+=1
            }
            if track.target==path {driving+=1}
        }
    }
    return
}

@(private)
authoring_bone_add :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Skeleton_Bone_Add_Params)
    if !authoring_editable(s,call) {return}
    name:=base.text_get(p.bone.name[:])
    if name=="" {authoring_failure(call,"bone.name","Required","a nonempty bone name","empty","The bone needs a name");return}
    clip_count,_:=api.params_array_count(call,"clips")
    if clip_count>len(p.clips) {authoring_failure(call,"clips","Capacity",fmt.tprintf("at most %d clips",len(p.clips)),fmt.tprintf("%d",clip_count),"Too many clips");return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
    if len(view.bones)>=aa.SKELETON_MAX_BONES {authoring_failure(call,"asset","Capacity",fmt.tprintf("fewer than %d bones",aa.SKELETON_MAX_BONES),fmt.tprintf("%d",len(view.bones)),"The skeleton holds no more bones");return}
    parent:=i32(-1)
    parent_path:=base.text_get(p.parent[:])
    if parent_path!="" {
        for &bone,i in view.bones {
            if base.text_get(bone.path[:])==parent_path {parent=i32(i);break}
        }
        if parent<0 {authoring_failure(call,"parent","Missing_Bone","the canonical path of a bone of the skeleton",parent_path,"The parent is not a bone of the skeleton",fix="skeleton.inspect lists the bones with their paths");return}
    }
    path:=base.text_get(p.path[:])
    if path=="" {path=bone_path_join(parent_path,name)}
    if len(path)>=aa.NODE_PATH_CAPACITY {authoring_failure(call,"path","Capacity",fmt.tprintf("a path shorter than %d bytes",aa.NODE_PATH_CAPACITY),fmt.tprintf("%d bytes",len(path)),"The path of the bone is too long");return}
    for &bone in view.bones {
        if base.text_get(bone.path[:])==path {authoring_failure(call,"path","Already_Exists","a path no bone has",path,"The skeleton has a bone at that path",fix="skeleton.bone.set changes its name and rest pose");return}
    }
    value:=Authoring_Bone{name=p.bone.name,parent=p.parent,position=p.bone.position,rotation=p.bone.rotation,scale=p.bone.scale}
    base.text_set(value.path[:],path)
    bones,error:=make([]aa.Skeleton_Bone,len(view.bones)+1,call.allocator)
    if error!=nil {authoring_failure(call,"bone","Out_Of_Memory","memory for the bone rows","allocation failed","The bone could not be added",api.INTERNAL_ERROR);return}
    copy(bones,view.bones)
    bones[len(view.bones)]=authoring_bone(value,parent)
    view.bones=bones

    // Every document is prepared before anything is written.
    Written :: struct {path:string,bytes:[]u8,id:base.Asset_Id,renamed,driving:u32}
    written:=make([dynamic]Written,call.allocator)
    serialize :: proc(call:^api.Call,doc:^aa.Document,what:string) -> (bytes:[]u8,ok:bool) {
        out:serial.Writer;serial.writer_init(&out,4096,call.allocator)
        if error:=aa.document_write(doc,&out);error!=.None {
            authoring_failure(call,what,"Serialization","a valid asset document",fmt.tprintf("%v",error),"The asset could not be serialized",api.SERVER_ERROR)
            return nil,false
        }
        return serial.writer_bytes(&out),true
    }
    {
        doc:aa.Document;defer aa.document_destroy(&doc)
        if error:=aa.skeleton_document(&doc,&s.app.assets.types,{id=p.asset,bones=view.bones,sockets=view.sockets,body=view.body,body_parts=view.body_parts,source=view.source},s.app.allocator);error!=.None {
            authoring_failure(call,"bone","Invalid_Definition","a valid path, rotation and scale",fmt.tprintf("%v",error),"The bone could not be added")
            return
        }
        bytes,serialized:=serialize(call,&doc,"asset");if !serialized {return}
        append(&written,Written{path=file.path,bytes=bytes,id=p.asset})
    }
    for id,at in p.clips[:clip_count] {
        what:=fmt.tprintf("clips[%d]",at)
        clip_file:Authoring_File;defer aa.asset_close(&clip_file.file)
        clip_view,opened:=authoring_clip_open(s,call,id,&clip_file);if !opened {return}
        clips,described:=authoring_clip_descs(clip_view,call);if !described {return}
        entry:=Written{path=clip_file.path,id=id}
        entry.renamed,entry.driving=bone_tracks_follow(clips,name,path)
        if entry.renamed>0 {
            doc:aa.Document;defer aa.document_destroy(&doc)
            if error:=aa.animation_document(&doc,&s.app.assets.types,{id=id,clips=clips,source=clip_view.source},s.app.allocator);error!=.None {
                authoring_failure(call,what,"Invalid_Definition","clips that stay valid",fmt.tprintf("%v",error),"The tracks could not be renamed")
                return
            }
            serialized:bool
            entry.bytes,serialized=serialize(call,&doc,what);if !serialized {return}
        }
        append(&written,entry)
    }

    out:=call.out
    serial.text_write_raw(out,"{")
    authoring_result(call,p.asset,file.path)
    api.write_text(out,"bone",path)
    api.write_key(out,"clips");serial.text_write_raw(out,"[")
    for entry,i in written[1:] {
        if i>0 {serial.text_write_raw(out,",")}
        serial.text_write_raw(out,"{");api.write_key(out,"asset",true);serial.write_u8(out,'"');serial.text_write_asset_id(out,entry.id);serial.write_u8(out,'"')
        api.write_uint(out,"renamed",u64(entry.renamed));api.write_uint(out,"driving",u64(entry.driving))
        serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]")
    dry_run:=authoring_dry_run(call)
    if dry_run {api.write_bool(out,"dry_run",true)}
    serial.text_write_raw(out,"}")
    if dry_run {return}
    label:=call.method.name if call.method!=nil else "Add bone"
    if s.edits!=nil && !editor.api_edit_begin(s,call,label) {return}
    done:=true
    for entry in written {
        if entry.bytes!=nil {done=editor.file_write(s,entry.path,entry.bytes,label) && done}
    }
    if s.edits!=nil {done=editor.api_edit_end(s,call,done) && done}
    if !done && !call.failed {authoring_failure(call,"path","Write_Error","the skeleton and clip writes","write failed","The bone could not be written",api.SERVER_ERROR)}
}
