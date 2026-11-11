package animation_editor

import "core:fmt"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// A bone or socket asked, found on the skeleton: its bone, and for a socket its offset on it.
Pose_Row :: struct {
    name:string,
    kind:Pose_Kind,
    bone:int,
    path:[aa.NODE_PATH_CAPACITY]u8,
    offset:mm.Transform,
}

// What the Pose part places; without a skeleton the part says why it cannot.
Pose_Query :: struct {
    rows:[]Pose_Row,
    skeleton:base.Asset_Id,
}

POSE_NAMES_FIX :: "animation.inspect with parts [Rig] lists the bones of a rig; animation.asset.inspect of its skeleton lists its bones and sockets, and with section Body the parts of its body (@head, @hand_r...)"

// Finds each name on the skeleton the rig posed with, or on that of its mesh before it has posed.
// A socket name wins over a bone of the same name; the path of the bone reaches that one.
@(private)
pose_query :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity,names:^[POSE_NAMES][aa.NODE_PATH_CAPACITY]u8) -> (query:Pose_Query) {
    asked:=0
    for &name in names^ {if base.text_get(name[:])!="" {asked+=1}}
    if asked==0 {
        authoring_failure(call,"names","Missing_Names",fmt.tprintf("one to %d bones or sockets",POSE_NAMES),"none","The Pose part needs the names of what to place",fix=POSE_NAMES_FIX)
        return
    }
    query.skeleton=anim.pose_skeleton(core.world_storage_of(w,anim.Playback),e)
    skeleton:=query.skeleton if query.skeleton!={} else rig_skeleton(s,w,e)
    if skeleton=={} || s.app==nil || s.app.shared==nil {return}
    cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets)
    content:=anim.skeleton_content(cache,s.app.assets,s.app.allocator,skeleton)
    if content==nil {return}
    rows,error:=make([]Pose_Row,asked,call.allocator)
    if error!=nil {authoring_failure(call,"names","Out_Of_Memory","memory for the names asked","allocation failed","The Pose part could not be prepared",api.SERVER_ERROR);return {}}
    at:=0
    for &name,slot in names^ {
        text:=base.text_get(name[:])
        if text=="" {continue}
        row:=&rows[at];at+=1
        row.name=text
        row.bone=-1
        for &socket in content.sockets {
            if base.text_get(socket.name[:])!=text {continue}
            row.kind,row.offset=.Socket,socket.offset
            row.bone=anim.skeleton_bone_find(content.bones,content.body,anim.Bone_Ref{path=socket.bone})
            break
        }
        if row.kind==.Bone {row.bone=anim.skeleton_bone_find(content.bones,content.body,anim.Bone_Ref{path=name})}
        if row.bone<0 {
            authoring_failure(call,fmt.tprintf("names[%d]",slot),"Missing_Name","a bone path or name the skeleton has once, a part of its body (@hand_r) or one of its sockets",text,fmt.tprintf("'%s' is not a bone, a part of the body or a socket of the skeleton, or it names several bones",text),fix=POSE_NAMES_FIX)
            return {}
        }
        if row.kind==.Bone {row.offset=mm.TRANSFORM_IDENTITY}
        row.path=content.bones[row.bone].path
    }
    query.rows=rows
    return
}

// Each bone and socket asked where its rig ended its last tick, in the space of the entity and in
// the world from where the entity is now.
@(private)
instance_pose :: proc(call:^api.Call,w:core.World_Ref,e:core.Entity,query:^Pose_Query) -> (r:Instance_Pose) {
    if query.rows==nil {
        authoring_failure(call,"entity","Missing_Skeleton","a rig with a skeleton","none","The entity has no skeleton to place bones on",fix="Give it a mesh with a skeleton and play it")
        return
    }
    playback:=core.world_storage_of(w,anim.Playback)
    if query.skeleton=={} {
        authoring_failure(call,"entity","Not_Posed","a rig animated in the last tick","not animated","The entity has not posed a skeleton yet",fix="Run the world (play.start, play.step) or animation.preview so a tick poses it; a mesh that shares the pose of a rig of its skeleton through Pose_Source is asked on that rig")
        return
    }
    actor,placed:=core.world_of(core.world_table_of(w,core.Transform),core.world_table_of(w,core.Parent),e)
    if !placed {authoring_failure(call,"entity","Not_Placed","an entity with a transform","none","The entity has no transform",api.SERVER_ERROR);return}
    pose,posed:=anim.pose_space(playback,e,call.allocator)
    r.skeleton=query.skeleton
    r.transforms=make([]Instance_Pose_Transform,len(query.rows),call.allocator)
    for &row,i in query.rows {
        space,placed:=lib.skeleton_socket(pose,row.bone+1,row.offset)
        if !posed || !placed {authoring_failure(call,"entity","Not_Posed","a pose of the rig in its last tick that has these bones","not posed","The pose of the rig cannot place a bone",api.SERVER_ERROR,fix="Run a tick of the world again; a pose with a value that is not finite is reported by engine.diagnostics");return}
        value:=Instance_Pose_Transform{kind=row.kind,bone=row.path,world=mm.transform_compose(actor,space),entity=space}
        copy(value.name[:len(value.name)-1],row.name)
        if i<len(r.transforms) {r.transforms[i]=value}
    }
    return
}
