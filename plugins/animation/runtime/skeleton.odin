package anim

import "core:mem"
import "core:slice"
import "core:strings"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import lib "mirai:std/anim"

// A mesh that shows the pose of a rig of its skeleton instead of posing its own;
// with a skeleton of its own it is a rig that follows that one (Rig.leader).
@(component,description="Uses another entity's evaluated pose to deform this mesh: clothing and meshes that share one rig. A mesh of another skeleton, as a head, follows it on the bones of the same name and keeps its own animation on the rest.")
Pose_Source :: struct {rig:core.Entity}

// A bone by its path, or by its name when no other bone has it. A text that
// starts with BODY_LABEL names a part of the body of the skeleton instead
// (lib.BODY_PART_NAMES: "@hand_l"), and in a mask or an over also a region
// (lib.BODY_REGION_NAMES: "@upper_body"), which wins over the part of the
// same name ("@head"). A label follows the body the .skeleton keeps.
Bone_Ref :: struct {path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`}

BODY_LABEL :: "@"

bone_ref :: proc(name:string) -> (Bone_Ref,bool) #optional_ok {
    result:Bone_Ref
    valid:=len(name)<len(result.path)
    for byte in name {if byte==0 {valid=false;break}}
    if !valid {for &byte in result.path {byte=0xff};return result,false}
    base.text_set(result.path[:],name)
    return result,true
}

bone_ref_hash :: proc(reference:Bone_Ref) -> (u64,bool) #optional_ok {
    reference:=reference
    terminated:=false
    for byte in reference.path {if byte==0 {terminated=true;break}}
    if !terminated {return 0,false}
    path:=base.text_get(reference.path[:])
    return base.name_hash(path) if path!="" else 0,true
}

// The label of a part of the body.
bone_ref_part :: proc(part:lib.Body_Part) -> Bone_Ref {
    names:=lib.BODY_PART_NAMES
    result:Bone_Ref
    at:=copy(result.path[:],BODY_LABEL)
    copy(result.path[at:],names[part])
    return result
}

// The part and the regions of the body the label with this hash names: a
// part, a region or both ("@head").
@(private)
body_label :: proc "contextless" (hash:u64) -> (part:lib.Body_Part,regions:lib.Body_Regions,is_part,is_region:bool) {
    if hash==0 {return}
    buffer:[64]u8
    at:=copy(buffer[:],BODY_LABEL)
    for name,value in lib.BODY_PART_NAMES {
        if base.name_hash(string(buffer[:at+copy(buffer[at:],name)]))==hash {part,is_part=value,true;break}
    }
    for entry in lib.BODY_REGION_NAMES {
        if base.name_hash(string(buffer[:at+copy(buffer[at:],entry.name)]))==hash {regions,is_region=entry.regions,true;break}
    }
    return
}

// How to fix a reference a rig could not resolve.
bone_fix :: proc(reference:Bone_Ref) -> string {
    reference:=reference
    if strings.has_prefix(base.text_get(reference.path[:]),BODY_LABEL) {return "name a part of its body: skeleton.body.detect finds them and skeleton.body.set fixes them"}
    return "name one of its bones (animation.asset.inspect lists them)"
}

// The bone of a skeleton a reference names, or -1: by path, by a name no
// other bone has, or by the label of a part of its body.
skeleton_bone_find :: proc(bones:[]asset.Skeleton_Bone,body:lib.Body_Map,reference:Bone_Ref) -> int {
    reference:=reference
    text:=base.text_get(reference.path[:])
    if text=="" {return -1}
    for &bone,i in bones {if base.text_get(bone.path[:])==text {return i}}
    found:=-1
    for &bone,i in bones {
        if base.text_get(bone.name[:])!=text {continue}
        if found>=0 {return -1}
        found=i
    }
    if found>=0 || !strings.has_prefix(text,BODY_LABEL) {return found}
    part,named:=lib.body_part_parse(text[len(BODY_LABEL):])
    return int(body.bones[part]) if named else -1
}

Skeleton_Content :: struct {
    id:base.Asset_Id,
    stamp:[2]i64,
    checked,revision:u64,
    bones:[]asset.Skeleton_Bone,
    sockets:[]asset.Skeleton_Socket,
    mirror:[]i32, // by bone: the one whose name names the other side, itself when none or several do
    body:lib.Body_Map, // on these bones; empty without a body
    error:asset.Error, // of the last read; Invalid: no bones
}

@(storage,host,free="skeleton_assets_free")
Skeleton_Assets :: struct {
    allocator:mem.Allocator,
    contents:[dynamic]Skeleton_Content,
    rows:map[base.Asset_Id]u32,
}

skeleton_assets_free :: proc(cache:^Skeleton_Assets) {
    if cache.allocator.procedure!=nil {context.allocator=cache.allocator}
    for content in cache.contents {delete(content.bones);delete(content.sockets);delete(content.mirror)}
    delete(cache.contents);delete(cache.rows)
    cache^={}
}

// Advances when what the plugin reads of the assets may have changed: a file
// of the registry, on disk or unsaved in its memory, or what the host gave out
// of one. A content looks at its record again only then. Never 0.
@(private)
assets_stamp :: proc "contextless" (app:^host.App) -> u64 {return app.assets.revision+app.assets.registry.revision+1}

skeleton_content :: proc(cache:^Skeleton_Assets,app:^host.App,id:base.Asset_Id) -> ^Skeleton_Content {
    if cache==nil || app==nil || app.assets==nil || id=={} {return nil}
    context.allocator=app.allocator;cache.allocator=app.allocator
    if cache.rows==nil {cache.rows=make(map[base.Asset_Id]u32,app.allocator)}
    row,found:=cache.rows[id]
    if !found {
        row=u32(len(cache.contents))
        if append(&cache.contents,Skeleton_Content{id=id})!=1 {return nil}
        if map_insert(&cache.rows,id,row)==nil {pop(&cache.contents);return nil}
    }
    content:=&cache.contents[row]
    if content.checked==assets_stamp(app) {return content if len(content.bones)>0 else nil}
    record,exists:=asset.registry_find(&app.assets.registry,id)
    stamp:=[2]i64{}
    if exists {stamp={record.size,record.time}}
    if found && content.checked!=0 && content.stamp==stamp {content.checked=assets_stamp(app);return content if len(content.bones)>0 else nil}
    bones:[]asset.Skeleton_Bone
    sockets:[]asset.Skeleton_Socket
    mirror:[]i32
    body:=lib.body_map_empty()
    error:=asset.Error.Not_Found
    if exists {bones,sockets,body,error=skeleton_read(app,id)}
    if error==.None {
        paired:bool
        if mirror,paired=skeleton_mirror_pairs(bones,app.allocator);!paired {delete(bones);delete(sockets);bones,sockets=nil,nil;error=.Out_Of_Memory}
    }
    if error==.None && len(bones)==0 {error=.Invalid}
    content.error=error
    if error==.Out_Of_Memory {content.checked=0;return nil}
    delete(content.bones);delete(content.sockets);delete(content.mirror);content.bones,content.sockets,content.mirror=bones,sockets,mirror
    content.body=body if error==.None else lib.body_map_empty()
    content.stamp,content.checked=stamp,assets_stamp(app);content.revision+=1
    return content if error==.None else nil
}

@(private)
skeleton_read :: proc(app:^host.App,id:base.Asset_Id) -> ([]asset.Skeleton_Bone,[]asset.Skeleton_Socket,lib.Body_Map,asset.Error) {
    file:asset.Asset
    if error:=host.assets_file(app.assets,id,asset.KIND_SKELETON,&file);error!=.None {return nil,nil,{},error}
    defer asset.asset_close(&file)
    view,error:=asset.skeleton_view(&file,&app.assets.types)
    if error!=.None {return nil,nil,{},error}
    bones,allocation:=make([]asset.Skeleton_Bone,len(view.bones),app.allocator)
    if allocation!=nil {return nil,nil,{},.Out_Of_Memory}
    copy(bones,view.bones)
    sockets,socket_allocation:=make([]asset.Skeleton_Socket,len(view.sockets),app.allocator)
    if socket_allocation!=nil {delete(bones);return nil,nil,{},.Out_Of_Memory}
    copy(sockets,view.sockets)
    return bones,sockets,asset.skeleton_body_map(view.bones,view.body,view.body_parts),.None
}

// Pairs each bone with the bone named for the other side (lib.mirror_name).
// A bone without side, or whose counterpart is missing, ambiguous or not
// mutual, pairs with itself.
skeleton_mirror_pairs :: proc(bones:[]asset.Skeleton_Bone,allocator:=context.allocator) -> (pairs:[]i32,ok:bool) {
    Named :: struct {hash:u64,bone:i32}
    error:mem.Allocator_Error
    if pairs,error=make([]i32,len(bones),allocator);error!=nil {return nil,false}
    named,named_error:=make([]Named,len(bones),context.temp_allocator)
    if named_error!=nil {delete(pairs,allocator);return nil,false}
    defer delete(named,context.temp_allocator)
    for &bone,i in bones {named[i]={base.name_hash(base.text_get(bone.name[:])),i32(i)};pairs[i]=i32(i)}
    slice.sort_by(named,proc(a,b:Named) -> bool {return a.hash<b.hash || a.hash==b.hash && a.bone<b.bone})
    buffer:[64]u8
    for &bone,i in bones {
        other,sided:=lib.mirror_name(base.text_get(bone.name[:]),buffer[:]);if !sided {continue}
        hash:=base.name_hash(other)
        at,_:=slice.binary_search_by(named,hash,proc(entry:Named,hash:u64) -> slice.Ordering {return .Less if entry.hash<hash else .Greater if entry.hash>hash else .Equal})
        for at>0 && named[at-1].hash==hash {at-=1}
        if at>=len(named) || named[at].hash!=hash || at+1<len(named) && named[at+1].hash==hash {continue}
        pairs[i]=named[at].bone
    }
    for &pair,i in pairs {if pairs[pair]!=i32(i) {pair=i32(i)}}
    return pairs,true
}

skeleton_bind :: proc(playback:^Playback,state:^Playing,content:^Skeleton_Content,clip:^host.Content_Animation,transforms:^core.Table(core.Transform)) -> bool {
    root,exists:=core.get(core.read(transforms),state.entity)
    if !exists {return false}
    count:=len(content.bones)+1
    next:Playing
    defer playing_free(&next)
    if resize(&next.bindings,count)!=nil || resize(&next.parents,count)!=nil || resize(&next.targets,count)!=nil || resize(&next.aliases,count)!=nil ||
       resize(&next.rest,count)!=nil || resize(&next.local,count)!=nil || resize(&next.world,count)!=nil || resize(&next.sampled,count)!=nil || resize(&next.previous,count)!=nil {return false}
    next.bindings[0]={entity=state.entity,parent=-1,rest=core.to_math(root)}
    next.parents[0]=-1;next.rest[0]=core.to_math(root)
    for &bone,i in content.bones {
        index:=i+1
        reference:=mm.Transform{position=bone.translation,rotation=bone.rotation,scale=bone.scale}
        driven:Property_Set
        if clip!=nil {driven=targeted(&clip.lib,bone.target)}
        next.bindings[index]={target=bone.target,entity=core.NONE,parent=bone.parent+1,rest=reference,driven=driven}
        next.parents[index],next.targets[index],next.rest[index]=bone.parent+1,bone.target,reference
        next.aliases[index]=base.name_hash(base.text_get(bone.name[:]))
    }
    copy(next.local[:],next.rest[:]);copy(next.previous[:],next.rest[:])
    plane:=lib.MIRROR_PLANE_DEFAULT
    if len(content.mirror)==len(content.bones) {
        if resize(&next.mirror_pairs,count)!=nil || resize(&next.mirror_corrections,count)!=nil || resize(&next.mirror_scratch,count*2)!=nil {return false}
        next.mirror_pairs[0]=0
        for pair,i in content.mirror {next.mirror_pairs[i+1]=pair+1}
        mirrored:bool
        if plane,mirrored=lib.mirror_prepare(next.parents[:],next.mirror_pairs[:],next.rest[:],next.mirror_corrections[:],next.mirror_scratch[:]);!mirrored {clear(&next.mirror_pairs);clear(&next.mirror_corrections);clear(&next.mirror_scratch)}
    }
    body:=content.body
    for &bone,part in body.bones {if bone>=0 {bone+=1;next.body[part]=bone}}
    if next.body!={} {
        if resize(&next.regions,count)!=nil {return false}
        if !lib.body_regions(next.parents[:],body,next.regions[:]) {clear(&next.regions);next.body={}}
    }
    delete(state.bindings);delete(state.parents);delete(state.targets);delete(state.aliases)
    delete(state.rest);delete(state.local);delete(state.world);delete(state.sampled);delete(state.previous)
    delete(state.mirror_pairs);delete(state.mirror_corrections);delete(state.mirror_scratch);delete(state.regions)
    state.bindings,state.parents,state.targets,state.aliases=next.bindings,next.parents,next.targets,next.aliases
    state.rest,state.local,state.world,state.sampled,state.previous=next.rest,next.local,next.world,next.sampled,next.previous
    state.mirror_pairs,state.mirror_corrections,state.mirror_scratch,state.mirror_plane=next.mirror_pairs,next.mirror_corrections,next.mirror_scratch,plane
    state.body,state.regions=next.body,next.regions
    state.forward,state.up=content.body.forward,content.body.up
    if !lib.body_axes_valid(state.forward,state.up) {state.forward,state.up={0,0,-1},{0,1,0}}
    next.bindings,next.parents,next.targets,next.aliases=nil,nil,nil,nil
    next.rest,next.local,next.world,next.sampled,next.previous=nil,nil,nil,nil,nil
    next.mirror_pairs,next.mirror_corrections,next.mirror_scratch,next.regions=nil,nil,nil,nil
    state.skeleton=content.id;state.skeleton_revision=content.revision
    playback.binding_revision+=1;state.bound=playback.binding_revision
    state.pose_ready=false
    return true
}

bone_resolve :: proc(state:^Playing,reference:Bone_Ref) -> int {
    if state==nil {return -1}
    hash,valid:=bone_ref_hash(reference)
    if !valid {return -1}
    return bone_find(state,hash)
}

// The bone with this hash of its path, of its name when no other bone has it,
// or of the label of a part of the body of the rig.
bone_find :: proc(state:^Playing,hash:u64) -> int {
    if bone:=bone_named(state,hash);bone>=0 || state.body=={} {return bone}
    part,_,is_part,_:=body_label(hash)
    return int(state.body[part]) if is_part && state.body[part]>0 else -1
}

@(private)
bone_named :: proc(state:^Playing,hash:u64) -> int {
    for target,i in state.targets {if target==hash {return i}}
    found:=-1
    for alias,i in state.aliases {
        if hash==0 || alias!=hash {continue}
        if found>=0 {return -1}
        found=i
    }
    return found
}

// What a reference of a mask or an over holds: a bone and the bones below
// it, or with bone -1, regions of the body.
Bone_Selection :: struct {bone:int,regions:lib.Body_Regions}

bone_select :: proc(state:^Playing,hash:u64) -> (selection:Bone_Selection,ok:bool) {
    if bone:=bone_named(state,hash);bone>=0 {return {bone=bone},true}
    if state.body=={} {return {bone=-1},false}
    part,regions,is_part,is_region:=body_label(hash)
    if is_region && len(state.regions)==len(state.parents) {return {bone=-1,regions=regions},true}
    if is_part && state.body[part]>0 {return {bone=int(state.body[part])},true}
    return {bone=-1},false
}

bone_selected :: proc "contextless" (state:^Playing,selection:Bone_Selection,bone:int) -> bool {
    if selection.bone<0 {return lib.body_region_inside(state.regions[bone],selection.regions)}
    at:=bone
    for at>selection.bone {at=int(state.parents[at])}
    return at==selection.bone
}

bone_target :: proc(state:^Playing,reference:Bone_Ref) -> u64 {
    index:=bone_resolve(state,reference)
    return state.targets[index] if index>=0 else bone_ref_hash(reference)
}

// A clip moves its root bone in the space of the bone's parent; the root motion of the rig is in
// the space of the rig. Bones above the root, such as the armature of an import that scales
// centimeters to meters and turns Z up into Y up, carry it there with their rest.
root_motion_to_rig :: proc "contextless" (state:^Playing,root:u64,moved:mm.Vec3,turned:mm.Quat) -> (mm.Vec3,mm.Quat) {
    bone:=-1
    for target,i in state.targets {if target==root {bone=i;break}}
    if bone<0 || bone>=len(state.parents) || len(state.rest)!=len(state.parents) || state.parents[bone]<0 {return moved,turned}
    above:=mm.TRANSFORM_IDENTITY
    steps:=0
    // Only the bones above the root: a bound rig's first slot is its entity (no target), whose
    // Transform when it was bound is not part of the rig's space.
    for parent:=state.parents[bone];parent>=0 && int(parent)<len(state.rest) && steps<len(state.rest);parent=state.parents[parent] {
        if int(parent)<len(state.targets) && state.targets[parent]==0 {break}
        above=mm.transform_compose(state.rest[parent],above);steps+=1
    }
    return mm.transform_vector(above,moved),linalg.normalize(above.rotation*turned*conj(above.rotation))
}

animation_bone_transform :: proc(playback:^Playback,rig:core.Entity,bone:Bone_Ref) -> (mm.Transform,bool) {
    if playback==nil {return mm.TRANSFORM_IDENTITY,false}
    state:=constraint_playing(playback,rig)
    index:=bone_resolve(state,bone)
    if state==nil || !state.pose_ready || index<0 || index>=len(state.world) {return mm.TRANSFORM_IDENTITY,false}
    return state.world[index],true
}

Bone_Handle :: struct {rig:core.Entity,index:i32,revision:u64}
Pose_Request :: struct {rig:core.Entity,bone:Bone_Ref,transform:mm.Transform,weight:f32,binding:Bone_Handle}

animation_pose :: proc(requests:^Animation_Requests,rig:core.Entity,bone:Bone_Ref,transform:mm.Transform,weight:f32=1) {
    if requests==nil {return}
    if _,valid:=bone_ref_hash(bone);rig==core.NONE || !valid {core.refuse(&requests.poses);return}
    pose_request_offer(&requests.poses,{rig=rig,bone=bone,transform=transform,weight=weight})
}

@(private)
pose_request_offer :: proc(queue:^core.Queue(Pose_Request),request:Pose_Request) {
    transform,weight:=request.transform,request.weight
    valid:=finite(weight) && weight>=0 && weight<=1 && abs(linalg.dot(transform.rotation,transform.rotation)-1)<0.002
    for value in transform.position {valid&&=finite(value)}
    for value in transform.scale {valid&&=finite(value)}
    if !valid {core.refuse(queue);return}
    core.offer(queue,request)
}

animation_bone_bind :: proc(playback:^Playback,rig:core.Entity,bone:Bone_Ref) -> (Bone_Handle,bool) {
    if playback==nil {return {},false}
    state:=constraint_playing(playback,rig)
    index:=bone_resolve(state,bone)
    if index<0 {return {},false}
    return {rig,i32(index),state.bound},true
}

// World poses of the current sampled animation, before physics and constraints.
animation_sample_pose :: proc(playback:^Playback,rig:core.Entity,out:[]mm.Transform,parent_world:=mm.TRANSFORM_IDENTITY) -> (count:int,revision:u64,ok:bool) {
    if playback==nil {return}
    state:=constraint_playing(playback,rig)
    if state==nil || state.seen!=playback.frame {return}
    count,revision=len(state.sampled),state.bound
    if len(out)<count {return}
    ok=lib.skeleton_world(playing_skeleton(state),state.sampled[:],out[:count],parent_world)
    return
}

// Room for final_poses in a tick, past the room of Animation_Settings: what a library that sends one per bone keeps.
animation_requests_reserve :: proc(requests:^Animation_Requests,final_poses:int) -> bool {
    if requests==nil || final_poses<0 || final_poses>65536 {return false}
    return final_poses<=cap(requests.final_poses.items) || reserve(&requests.final_poses.items,final_poses)==nil
}

animation_pose_final :: proc{animation_pose_final_ref,animation_pose_final_binding}

animation_pose_final_ref :: proc(requests:^Animation_Requests,rig:core.Entity,bone:Bone_Ref,world:mm.Transform,weight:f32=1) {
    if requests==nil {return}
    if _,valid:=bone_ref_hash(bone);rig==core.NONE || !valid {core.refuse(&requests.final_poses);return}
    pose_request_offer(&requests.final_poses,{rig=rig,bone=bone,transform=world,weight=weight})
}

animation_pose_final_binding :: proc(requests:^Animation_Requests,binding:Bone_Handle,world:mm.Transform,weight:f32=1) {
    if requests==nil {return}
    if binding.rig==core.NONE || binding.index<0 || binding.revision==0 {core.refuse(&requests.final_poses);return}
    pose_request_offer(&requests.final_poses,{rig=binding.rig,transform=world,weight=weight,binding=binding})
}

@(private)
final_pose_apply :: proc(state:^Playing,playback:^Playback,parent_world:mm.Transform,requests:[]Pose_Request,problems:^core.Problems) {
    if len(requests)==0 {return}
    count:=len(state.local)
    if len(playback.final_rows)<count && resize(&playback.final_rows,count)!=nil {memory_problem(problems,state.entity,"the final poses asked for this rig");return}
    for &row in playback.final_rows[:count] {row=-1}
    for request,i in requests {
        if request.rig!=state.entity {continue}
        bone:=int(request.binding.index)
        if request.binding.revision==0 {bone=bone_resolve(state,request.bone)}
        else if request.binding.revision!=state.bound {bone=-1}
        if bone<0 || bone>=count {
            request:=request
            if request.binding.revision==0 {
                core.report(problems,state.entity,"animation.final_pose_bone","a final pose was asked for '%s', which the skeleton of this rig does not have; %s",base.text_get(request.bone.path[:]),bone_fix(request.bone))
            } else {
                core.report(problems,state.entity,"animation.final_pose_binding","a final pose was asked through a bone handle bound before the skeleton of this rig changed; bind the bone again with animation_bone_bind")
            }
            continue
        }
        playback.final_rows[bone]=i32(i)
    }
    for &local,bone in state.local {
        parent:=state.parents[bone]
        world_parent:=state.world[parent] if parent>=0 else parent_world
        if row:=playback.final_rows[bone];row>=0 {
            request:=requests[row]
            if request.weight>0 {
                world:=mm.transform_interpolate(state.world[bone],request.transform,request.weight)
                target,ok:=mm.transform_relative(world,world_parent)
                if ok {local=target} else {core.report(problems,state.entity,"animation.final_pose_parent","a final pose of bone %d could not be applied: the rig or a bone above it has a scale of zero; give them a scale",bone)}
            }
        }
        state.world[bone]=mm.transform_compose(world_parent,local)
    }
}
