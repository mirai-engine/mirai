package anim

import "core:mem"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "base:runtime"

MOTION_KIND :: asset.Fourcc(u32('M')|u32('O')<<8|u32('T')<<16|u32('N')<<24)
MOTION_VERSION :: 2
MOTION_WINDOWS :: 64
MOTION_KEYS :: 4096
Pose_Warp_Leg :: struct {hip,knee,foot:Bone_Ref}
Pose_Warp_Profile :: struct {
    pelvis:Bone_Ref,
    spine:[16]Bone_Ref,
    spine_count:u8,
    legs:[16]Pose_Warp_Leg,
    count:u8,
    min_stride,max_stride,max_angle,weight:f32,
    orientation,stride:bool,
}
POSE_WARP_PROFILE_DEFAULT :: Pose_Warp_Profile{min_stride=.5,max_stride=2,max_angle=mm.PI,weight=1}

// m/s below which the pose warp fades out with the speed of the body or of its clip.
MOTION_WARP_FADE_SPEED :: .3
Motion_Info :: struct {pose:Pose_Warp_Profile}
Motion_Window :: struct {
    clip:[64]u8 `mirai:"text"`,
    name:[32]u8 `mirai:"text"`,
    start,end:f32 `mirai:"unit=s,min=0"`,
    translation,rotation:bool,
    axes:[3]bool,
    weight:f32 `mirai:"min=0,max=1"`,
    animation:base.Asset_Id,
}
MOTION_WINDOW_DEFAULT :: Motion_Window{translation=true,rotation=true,axes={true,true,true},weight=1}
Motion_Distance :: struct {clip:[64]u8 `mirai:"text"`,name:[32]u8 `mirai:"text"`,first,count:u32,animation:base.Asset_Id}
Motion_Profile :: struct {info:Motion_Info,windows:[]Motion_Window,distances:[]Motion_Distance,keys:[]lib.Distance_Key}

motion_profile_check :: proc(profile:Motion_Profile) -> bool {
    if len(profile.windows)>MOTION_WINDOWS || len(profile.distances)>MOTION_WINDOWS || len(profile.keys)>MOTION_KEYS {return false}
    pose:=profile.info.pose
    if pose.spine_count>16 || pose.count>16 || !profile_weight(pose.weight) || !finite(pose.min_stride) || !finite(pose.max_stride) || pose.min_stride<=0 || pose.max_stride<pose.min_stride || !finite(pose.max_angle) || pose.max_angle<0 || pose.max_angle>mm.PI {return false}
    if pose.orientation || pose.stride {
        if !profile_bone(pose.pelvis) || pose.pelvis=={} || pose.stride && pose.count==0 {return false}
        for bone,i in pose.spine[:pose.spine_count] {
            if !profile_bone(bone) || bone=={} || bone==pose.pelvis {return false}
            for previous in pose.spine[:i] {if previous==bone {return false}}
        }
        for leg,i in pose.legs[:pose.count] {
            if !profile_bone(leg.hip) || !profile_bone(leg.knee) || !profile_bone(leg.foot) || leg.hip=={} || leg.knee=={} || leg.foot=={} || leg.hip==leg.knee || leg.hip==leg.foot || leg.knee==leg.foot {return false}
            for previous in pose.legs[:i] {for bone in ([3]Bone_Ref{leg.hip,leg.knee,leg.foot}) {if bone==previous.hip || bone==previous.knee || bone==previous.foot {return false}}}
        }
    }
    for &window,i in profile.windows {
        if !blend_text_valid(window.clip[:],false) || !blend_text_valid(window.name[:],false) || !finite(window.start) || window.start<0 || !finite(window.end) || window.end<=window.start || !profile_weight(window.weight) || !window.translation && !window.rotation {return false}
        for &previous in profile.windows[:i] {if previous.animation==window.animation && previous.clip==window.clip && window.start<previous.end && previous.start<window.end {return false}}
    }
    for &track,i in profile.distances {
        if !blend_text_valid(track.clip[:],false) || !blend_text_valid(track.name[:],false) || track.first>u32(len(profile.keys)) || track.count>256 || track.count>u32(len(profile.keys))-track.first {return false}
        if !lib.distance_track_validate(profile.keys[track.first:][:track.count]) {return false}
        for &previous in profile.distances[:i] {if previous.name==track.name {return false}}
    }
    return true
}

motion_profile_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Motion_Profile,allocator:=context.allocator) -> asset.Error {
    if !motion_profile_check(profile) {return .Invalid}
    asset.document_init(doc,MOTION_KIND,id,allocator);doc.kind_version=MOTION_VERSION
    error:=motion_profile_tables(doc,types,profile)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
motion_profile_tables :: proc(doc:^asset.Document,types:^asset.Types,profile:Motion_Profile) -> asset.Error {
    info:=[1]Motion_Info{profile.info}
    asset.document_put(doc,types,"info",info[:]) or_return
    asset.document_put(doc,types,"windows",profile.windows) or_return
    asset.document_put(doc,types,"distances",profile.distances) or_return
    asset.document_put(doc,types,"keys",profile.keys) or_return
    return .None
}
motion_profile_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Motion_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    motion_profile_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
motion_profile_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Motion_Profile,error:asset.Error) {
    asset.kind_check(file,MOTION_KIND,MOTION_VERSION) or_return
    info:=asset.asset_rows(file,types,"info","",Motion_Info) or_return
    if len(info)!=1 {return {},.Corrupt};profile.info=info[0]
    profile.windows=asset.asset_rows(file,types,"windows","",Motion_Window) or_return
    profile.distances=asset.asset_rows(file,types,"distances","",Motion_Distance) or_return
    profile.keys=asset.asset_rows(file,types,"keys","",lib.Distance_Key) or_return
    if !motion_profile_check(profile) {return {},.Corrupt}
    return profile,.None
}
motion_profile_free :: proc(profile:^Motion_Profile,allocator:=context.allocator) {
    if profile==nil {return}
    delete(profile.windows,allocator);delete(profile.distances,allocator);delete(profile.keys,allocator);profile^={}
}

Motion_Content :: struct {id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Motion_Profile,valid:bool,error:asset.Error}
@(storage,host,free="motion_assets_free")
Motion_Assets :: struct {allocator:mem.Allocator,contents:[dynamic]Motion_Content}
motion_assets_free :: proc(cache:^Motion_Assets) {
    if cache==nil {return}
    if cache.allocator.procedure!=nil {context.allocator=cache.allocator}
    for &content in cache.contents {motion_profile_free(&content.profile)}
    delete(cache.contents);cache^={}
}
@(private)
motion_cached_content :: proc(cache:^Motion_Assets,id:base.Asset_Id,hint:^i32=nil) -> ^Motion_Content {
    if cache==nil || id=={} {return nil}
    row:=int(hint^)-1 if hint!=nil else -1
    if row<0 || row>=len(cache.contents) || cache.contents[row].id!=id {row=-1;for &content,i in cache.contents {if content.id==id {row=i;break}}}
    if row<0 {return nil}
    if hint!=nil {hint^=i32(row+1)}
    return &cache.contents[row]
}
motion_content :: proc(cache:^Motion_Assets,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id,hint:^i32=nil) -> ^Motion_Content {
    if cache==nil || assets==nil || id=={} {return nil}
    context.allocator=allocator;cache.allocator=allocator
    content:=motion_cached_content(cache,id,hint)
    if content==nil {if !program_array_reserve(&cache.contents,len(cache.contents)+1) || append(&cache.contents,Motion_Content{id=id})!=1 {return nil};content=&cache.contents[len(cache.contents)-1];if hint!=nil {hint^=i32(len(cache.contents))}}
    if content.checked==assets_stamp(assets) {return content if content.valid else nil}
    record,found:=asset.registry_find(&assets.registry,id)
    stamp:=[2]i64{};if found {stamp={record.size,record.time}}
    if content.checked!=0 && content.stamp==stamp {content.checked=assets_stamp(assets);return content if content.valid else nil}
    profile:Motion_Profile;error:=asset.Error.Not_Found
    if found {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        read,read_error:=motion_profile_read(assets,allocator,id)
        profile=read;error=read_error
    }
    content.error=error
    if error==.Out_Of_Memory {content.checked=0;return nil}
    motion_profile_free(&content.profile);content.profile=profile;content.valid=error==.None
    content.stamp,content.checked=stamp,assets_stamp(assets);content.revision+=1
    return content if content.valid else nil
}
@(private)
motion_profile_read :: proc(assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> (profile:Motion_Profile,error:asset.Error) {
    file:asset.Asset
    if error:=host.assets_file(assets,id,MOTION_KIND,&file);error!=.None {return {},error};defer asset.asset_close(&file)
    view,read:=motion_profile_view(&file,&assets.types);if read!=.None {return {},read}
    profile.info=view.info
    ok:bool
    profile.windows,ok=rows_clone(view.windows,allocator);if !ok {return {},.Out_Of_Memory}
    profile.distances,ok=rows_clone(view.distances,allocator);if !ok {motion_profile_free(&profile,allocator);return {},.Out_Of_Memory}
    profile.keys,ok=rows_clone(view.keys,allocator);if !ok {motion_profile_free(&profile,allocator);return {},.Out_Of_Memory}
    return profile,.None
}

Motion_Clock :: struct {player:lib.Player,from,to:f32,root:Root_Motion,weight:f32,active,mirror:bool} // mirror: the clip moves the rig reflected
@(private)
Motion_Window_Span :: struct {window:u8,from,to,end:f32}
Motion_Error :: enum u8 {None,Invalid,Missing_Profile,Unbound_Bone,Missing_Target,Unsupported_Clock,Capacity,Out_Of_Memory}
// world: where target is in this tick, once resolved.
Motion_Target :: struct {name:[32]u8 `mirai:"text"`,target:Spatial_Target,enabled:bool,world:mm.Transform `mirai:"readonly,transient"`,resolved:bool `mirai:"readonly,transient"`}
Motion_Target_Request :: struct {rig:core.Entity,target:Motion_Target}
Motion_Locomotion :: struct {rig:core.Entity,velocity,source_velocity:mm.Vec3,weight:f32,enabled:bool}
MOTION_LOCOMOTION_DEFAULT :: Motion_Locomotion{weight=1,enabled=true}
@(storage,queue)
Motion_Requests :: struct {targets:core.Queue(Motion_Target_Request),locomotion:core.Queue(Motion_Locomotion)}

motion_target :: proc(requests:^Motion_Requests,rig:core.Entity,name:string,target:Spatial_Target,enabled:bool=true) {
    if requests==nil {return}
    valid:=rig!=core.NONE && len(name)>0 && len(name)<32 && spatial_target_valid(target)
    for byte in name {valid&&=byte!=0}
    if !valid {core.refuse(&requests.targets);return}
    value:=Motion_Target{target=target,enabled=enabled};copy(value.name[:],transmute([]u8)name)
    core.offer(&requests.targets,Motion_Target_Request{rig=rig,target=value})
}
motion_locomotion :: proc(requests:^Motion_Requests,value:Motion_Locomotion) {
    if requests==nil {return}
    if value.rig==core.NONE || !profile_vector(value.velocity) || !profile_vector(value.source_velocity) || !profile_weight(value.weight) {core.refuse(&requests.locomotion);return}
    core.offer(&requests.locomotion,value)
}

Motion_Instance :: struct {
    entity:core.Entity,
    profile:base.Asset_Id,
    content:i32,
    revision,bound,seen:u64,
    bound_valid:bool,
    pelvis:i32,
    spine:[16]i32,
    legs:[16]lib.Pose_Warp_Limb,
    spine_count,leg_count:u8,
    targets:[dynamic]Motion_Target, // at most MOTION_WINDOWS
    bindings:[dynamic]Spatial_Target_Binding, // of each target; never fewer
    locomotion:Motion_Locomotion,
    source_velocity:mm.Vec3,
    window:i32,
    remaining_error:f32,
    error:Motion_Error,
}
@(storage,free="motion_runtime_free")
Motion_Runtime :: struct {instances:[dynamic]Motion_Instance,rows:[dynamic]i32,frame,animation_version,animation_layout:u64,discovered:bool}
motion_runtime_free :: proc(runtime:^Motion_Runtime) {if runtime!=nil {for &instance in runtime.instances {motion_instance_free(&instance)};delete(runtime.instances);delete(runtime.rows);runtime^={}}}
@(private)
motion_instance_free :: proc(instance:^Motion_Instance) {
    for binding in instance.bindings {delete(binding.path)}
    delete(instance.bindings);delete(instance.targets);instance^={}
}
motion_instance :: proc(runtime:^Motion_Runtime,entity:core.Entity) -> ^Motion_Instance {
    if runtime==nil || entity==core.NONE {return nil}
    index:=core.entity_index(entity)
    if index>=len(runtime.rows) {return nil}
    row:=int(runtime.rows[index])-1
    if row<0 || row>=len(runtime.instances) || runtime.instances[row].entity!=entity {return nil}
    return &runtime.instances[row]
}
motion_inspect :: proc(runtime:^Motion_Runtime,entity:core.Entity) -> (Motion_Instance,bool) {
    value:=motion_instance(runtime,entity);if value==nil {return {},false};return value^,true
}

// Reports why the motion profile of a rig did not apply in a tick.
motion_problem :: proc(problems:^core.Problems,e:core.Entity,error:Motion_Error,loaded:^host.Assets=nil,assets:^Motion_Assets=nil,profile:base.Asset_Id={}) {
    switch error {
    case .None,.Unsupported_Clock:
    case .Invalid:
        core.report(problems,e,"animation.motion_invalid","the motion profile of this rig could not warp it: a value of the profile, of its targets, of the locomotion asked or of the root motion is not finite or is out of range; check them (animation.inspect)")
    case .Missing_Profile:
        if assets!=nil {asset_problem(problems,e,loaded,"animation.motion_asset","Animation.motion",profile,content_error(assets.contents[:],profile))}
    case .Unbound_Bone:
        core.report(problems,e,"animation.motion_bones","the motion profile of this rig names a pelvis, spine or leg bone its skeleton does not have, or legs that are not chains (hip, knee, foot) or that share bones; fix the profile (animation.asset.inspect lists the bones)")
    case .Missing_Target:
        core.report(problems,e,"animation.motion_target","a warp window of the motion profile of this rig has no target: none was given with motion_target for its name, or what it names is gone: an entity without Transform, a rig not animated in the previous tick, or a bone or socket its skeleton does not have; give it one that exists")
    case .Capacity:
        core.report(problems,e,"animation.motion_targets","a motion target was refused: this rig has %d targets with other names, as many as fit; reuse their names",MOTION_WINDOWS)
    case .Out_Of_Memory:
        memory_problem(problems,e,"its motion profile")
    }
}

@(private)
motion_bind :: proc(instance:^Motion_Instance,state:^Playing,content:^Motion_Content) -> bool {
    if instance.profile==content.id && instance.revision==content.revision && instance.bound==state.bound {if !instance.bound_valid {instance.error=.Unbound_Bone};return instance.bound_valid}
    config:=content.profile.info.pose
    instance.profile,instance.revision,instance.bound=content.id,content.revision,state.bound
    instance.bound_valid=false
    instance.spine_count,instance.leg_count=config.spine_count,config.count
    instance.error=.None;instance.window=-1
    if config.orientation || config.stride {
        instance.pelvis=i32(bone_resolve(state,config.pelvis));if instance.pelvis<0 {instance.error=.Unbound_Bone;return false}
        for bone,i in config.spine[:config.spine_count] {
            instance.spine[i]=i32(bone_resolve(state,bone));if instance.spine[i]<0 || instance.spine[i]==instance.pelvis {instance.error=.Unbound_Bone;return false}
            for previous in instance.spine[:i] {if previous==instance.spine[i] {instance.error=.Unbound_Bone;return false}}
        }
        for leg,i in config.legs[:config.count] {
            instance.legs[i]={hip=i32(bone_resolve(state,leg.hip)),knee=i32(bone_resolve(state,leg.knee)),foot=i32(bone_resolve(state,leg.foot))}
            value:=instance.legs[i]
            if value.hip<0 || value.knee<0 || value.foot<0 || state.parents[value.knee]!=value.hip || state.parents[value.foot]!=value.knee {instance.error=.Unbound_Bone;return false}
            for previous in instance.legs[:i] {for bone in ([3]i32{value.hip,value.knee,value.foot}) {if bone==previous.hip || bone==previous.knee || bone==previous.foot {instance.error=.Unbound_Bone;return false}}}
        }
    }
    instance.bound_valid=true
    return true
}

motion_take_requests :: proc(runtime:^Motion_Runtime,requests:^Motion_Requests,problems:^core.Problems) {
    if runtime==nil || requests==nil {return}
    for request in requests.targets.items {
        instance:=motion_instance(runtime,request.rig)
        if instance==nil {
            core.report(problems,request.rig,"animation.motion_owner","a motion target was given for this entity, and its Animation has no motion profile; set Animation.motion first, or give it to the entity that has one")
            continue
        }
        found:=-1
        for &target,i in instance.targets {if target.name==request.target.name {found=i;break}}
        if found<0 {
            if len(instance.targets)>=MOTION_WINDOWS {instance.error=.Capacity;motion_problem(problems,request.rig,.Capacity);continue}
            if !program_array_reserve(&instance.targets,len(instance.targets)+1) || len(instance.bindings)<=len(instance.targets) && !program_array_resize(&instance.bindings,len(instance.targets)+1) {instance.error=.Out_Of_Memory;motion_problem(problems,request.rig,.Out_Of_Memory);continue}
            found=len(instance.targets)
            if append(&instance.targets,request.target)!=1 {instance.error=.Out_Of_Memory;motion_problem(problems,request.rig,.Out_Of_Memory);continue}
        } else {instance.targets[found]=request.target}
        target:=&instance.targets[found]
        target.resolved=target.target.kind==.World
        target.world=spatial_offset(target.target)
    }
    for request in requests.locomotion.items {
        if instance:=motion_instance(runtime,request.rig);instance!=nil {
            instance.locomotion=request
        } else {
            core.report(problems,request.rig,"animation.motion_owner","a motion locomotion was given for this entity, and its Animation has no motion profile; set Animation.motion first, or give it to the entity that has one")
        }
    }
    clear(&requests.targets.items);clear(&requests.locomotion.items)
}

@(private)
motion_discover :: proc(runtime:^Motion_Runtime,animations:core.Read(Animation),problems:^core.Problems) -> bool {
    if runtime.discovered && runtime.animation_layout==core.layout(animations) && runtime.animation_version==core.version(animations) {return true}
    layout:=!runtime.discovered || runtime.animation_layout!=core.layout(animations)
    added,rows:=0,len(runtime.rows)
    for row in 0..<core.count(animations) {
        if !layout && core.stamp(animations,row)<=runtime.animation_version || animations.table.values[row].motion=={} {continue}
        index:=core.entity_index(core.entity_at(animations,row));rows=max(rows,index+1)
        slot:=int(runtime.rows[index])-1 if index<len(runtime.rows) else -1
        if slot<0 || slot>=len(runtime.instances) || core.entity_index(runtime.instances[slot].entity)!=index {added+=1}
    }
    if !program_array_reserve(&runtime.instances,len(runtime.instances)+added) || !program_array_resize(&runtime.rows,rows) {memory_problem(problems,core.NONE,"the entities with a motion profile, so none applies");return false}
    for row in 0..<core.count(animations) {
        if !layout && core.stamp(animations,row)<=runtime.animation_version || animations.table.values[row].motion=={} {continue}
        entity:=core.entity_at(animations,row);index:=core.entity_index(entity);slot:=int(runtime.rows[index])-1
        if slot<0 || slot>=len(runtime.instances) || core.entity_index(runtime.instances[slot].entity)!=index {
            slot=len(runtime.instances)
            if append(&runtime.instances,Motion_Instance{entity=entity,window=-1})!=1 {memory_problem(problems,core.NONE,"the entities with a motion profile, so none applies");return false}
        } else if runtime.instances[slot].entity!=entity {
            // A new entity in the slot keeps the memory of its targets.
            reused:=&runtime.instances[slot];targets,bindings:=reused.targets,reused.bindings
            clear(&targets);reused^={entity=entity,window=-1};reused.targets=targets;reused.bindings=bindings
        }
        runtime.rows[index]=i32(slot+1)
    }
    runtime.animation_layout,runtime.animation_version=core.layout(animations),core.version(animations);runtime.discovered=true
    return true
}

motion_prepare :: proc(runtime:^Motion_Runtime,requests:^Motion_Requests,animations:core.Read(Animation),playback:^Playback,assets:^Motion_Assets,loaded:^host.Assets,allocator:mem.Allocator,problems:^core.Problems) -> bool {
    if runtime==nil || playback==nil || animations.table==nil {return false}
    if allocator.procedure!=nil {context.allocator=allocator}
    runtime.frame+=1
    if !motion_discover(runtime,animations,problems) {return false}
    kept:=0
    for &instance,i in runtime.instances {
        row:=core.row_of(animations,instance.entity);index:=core.entity_index(instance.entity)
        if row<0 || animations.table.values[row].motion=={} {if index<len(runtime.rows) && runtime.rows[index]==i32(i+1) {runtime.rows[index]=0};motion_instance_free(&instance);continue}
        instance.seen=runtime.frame
        state:=constraint_playing(playback,instance.entity)
        id:=animations.table.values[row].motion
        content:=motion_content(assets,loaded,allocator,id,&instance.content)
        if content==nil {
            instance.error=.Missing_Profile
            motion_problem(problems,instance.entity,.Missing_Profile,loaded,assets,id)
        } else if state!=nil && !motion_bind(&instance,state,content) {
            motion_problem(problems,instance.entity,instance.error)
        }
        if kept!=i {runtime.instances[kept]=instance};runtime.rows[index]=i32(kept+1);kept+=1
    }
    base.truncate(&runtime.instances,kept)
    motion_take_requests(runtime,requests,problems)
    return true
}

// Before the rigs sample: a bone or socket reads the pose of the previous tick.
motion_resolve_targets :: proc(runtime:^Motion_Runtime,playback:^Playback,skeletons:^Skeleton_Assets,transforms:core.Read(core.Transform),parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform)) {
    if runtime==nil {return}
    previous:=playback.frame-1 if playback!=nil && playback.frame>1 else 0
    for &instance in runtime.instances {for &target,i in instance.targets {
        if target.target.kind==.World || !target.enabled {continue}
        value,ok:=spatial_target_sample(target.target,&instance.bindings[i],playback,skeletons,transforms,parents,worlds,previous)
        target.resolved=ok
        if !ok {instance.error=.Missing_Target;continue}
        target.world=value
    }}
}

motion_apply_root :: proc(runtime:^Motion_Runtime,assets:^Motion_Assets,loaded:^host.Assets,allocator:mem.Allocator,state:^Playing,profile:base.Asset_Id,content:^host.Content_Animation,actor:mm.Transform,dt:f32,seeking:bool=false,clock:Motion_Clock={},base_weight:f32=1) -> bool {
    if state==nil || profile=={} {return true}
    instance:=motion_instance(runtime,state.entity);if instance==nil {return false}
    definition:=motion_content(assets,loaded,allocator,profile,&instance.content)
    if definition==nil {return false}
    if !motion_bind(instance,state,definition) {return false}
    instance.window=-1;instance.remaining_error=0;instance.error=.None;instance.source_velocity={}
    if !finite(dt) || dt<0 || !profile_weight(base_weight) || clock.active && !profile_weight(clock.weight) {instance.error=.Invalid;return false}
    if content==nil || !state.root_enabled || seeking || dt==0 || !state.was_playing {return true}
    if !clock.active && clock.player.clip!=0 {return true}
    player:=state.fader.current
    if clock.active {player=clock.player}
    if !lib.clip_valid(&content.lib,player.clip) {instance.error=.Invalid;return false}
    instance.source_velocity=mm.transform_vector(actor,state.motion.translation)/dt
    if !profile_vector(instance.source_velocity) {instance.error=.Invalid;return false}
    if !finite(player.speed) {instance.error=.Invalid;return false}
    if player.speed==0 {return true}
    if player.speed<0 {instance.error=.Unsupported_Clock;return true}
    influence:=clock.weight if clock.active else base_weight
    if influence==0 {return true}
    duration:=lib.clip_duration(&content.lib,player.clip)
    span:=clock.to-clock.from if clock.active else dt*player.speed
    if !finite(span) || duration<=0 || span>duration {instance.error=.Unsupported_Clock;return true}
    from:=clock.from if clock.active else state.prev_fader.current.time if state.prev_fader.current.clip==player.clip else max(player.time-span,0)
    to:=clock.to if clock.active else from+span
    if !finite(from) || !finite(to) || to<from {instance.error=.Unsupported_Clock;return true}
    if lib.clip_data(&content.lib,player.clip).loop==.Once {to=min(to,duration)}
    root:Root_Motion
    if clock.active {root=clock.root} else if state.program.ready && state.program.has_root {root=state.program.root} else if state.clip>=0 && state.clip<len(content.roots) {
        metadata:=content.roots[state.clip];root={bone={metadata.bone},translation=metadata.translation,rotation=metadata.rotation}
    } else {return true}
    if !root.translation && !root.rotation {return true}
    root_target:=bone_target(state,root.bone)
    if root_target==0 {instance.error=.Unbound_Bone;return false}
    clip_name:=lib.clip_data(&content.lib,player.clip).name
    spans:[MOTION_WINDOWS]Motion_Window_Span;span_count:=0
    for &window,w in definition.profile.windows {
        if source_clip_name(content.id,window.animation,base.name_hash(base.text_get(window.clip[:])))!=clip_name || window.weight==0 || !(window.translation && root.translation && (window.axes[0] || window.axes[1] || window.axes[2]) || window.rotation && root.rotation) {continue}
        offset:=f32(0)
        if to>duration && from>=window.end {offset=duration}
        start,end:=window.start+offset,window.end+offset
        if end>duration+offset {instance.error=.Unsupported_Clock;return false}
        a,b:=max(from,start),min(to,end);if b<=a {continue}
        slot:=span_count
        for slot>0 && spans[slot-1].from>a {spans[slot]=spans[slot-1];slot-=1}
        spans[slot]={u8(w),a,b,end};span_count+=1
    }
    original:=state.motion
    for span in spans[:span_count] {
        w:=int(span.window);window:=&definition.profile.windows[w];a,b,end:=span.from,span.to,span.end
        target:^Motion_Target
        for &value in instance.targets {if value.name==window.name && value.enabled && value.resolved {target=&value;break}}
        if target==nil {instance.error=.Missing_Target;continue}
        prefix,prefix_turn:=motion_root_sample(content,state,clock.mirror,player.clip,root_target,from,a)
        prefix+=state.motion.translation-original.translation
        prefix_turn=state.motion.rotation*conj(original.rotation)*prefix_turn
        window_actor:=mm.transform_compose(actor,{position=prefix,rotation=prefix_turn,scale={1,1,1}})
        moved,turned:=motion_root_sample(content,state,clock.mirror,player.clip,root_target,a,b)
        remaining,remaining_turn:=motion_root_sample(content,state,clock.mirror,player.clip,root_target,a,end)
        moved_local:=mm.transform_inverse_vector(window_actor,mm.transform_vector(actor,moved))
        remaining_local:=mm.transform_inverse_vector(window_actor,mm.transform_vector(actor,remaining))
        corrected,ok:=lib.root_motion_warp(window_actor,{position=moved_local,rotation=turned,scale={1,1,1}},{position=remaining_local,rotation=remaining_turn,scale={1,1,1}},target.world,(b-a)/(end-a),{translation=window.translation && root.translation,rotation=window.rotation && root.rotation,axes=window.axes,weight=window.weight*influence})
        if !ok {state.motion=original;instance.error=.Invalid;return false}
        correction:=mm.transform_inverse_vector(actor,mm.transform_vector(window_actor,corrected.position-moved_local))
        for enabled,axis in window.axes {if enabled {state.motion.translation[axis]+=correction[axis]}}
        if window.rotation && root.rotation {turn:=prefix_turn*corrected.rotation*conj(turned)*conj(prefix_turn);state.motion.rotation=linalg.normalize0(turn*state.motion.rotation)}
        if !profile_vector(state.motion.translation) || !profile_rotation(state.motion.rotation) {state.motion=original;instance.error=.Invalid;return false}
        endpoint:=mm.transform_compose(window_actor,corrected)
        instance.remaining_error=linalg.length(target.world.position-endpoint.position)
        instance.window=i32(w)
    }
    return true
}

@(private)
motion_root_sample :: proc(content:^host.Content_Animation,state:^Playing,mirror:bool,clip:lib.Clip,root:u64,from,to:f32) -> (moved:mm.Vec3,turned:mm.Quat) {
    moved,turned=lib.clip_root_motion(&content.lib,clip,root,from,to)
    moved,turned=root_motion_to_rig(state,root,moved,turned)
    if mirror {moved,turned=lib.mirror_vector(state.mirror_plane,moved),lib.mirror_rotation(state.mirror_plane,turned)}
    return
}

motion_apply_pose :: proc(runtime:^Motion_Runtime,state:^Playing,profile:base.Asset_Id,actor,root_transform:mm.Transform,assets:^Motion_Assets,problems:^core.Problems) -> bool {
    if state==nil || profile=={} {return true}
    instance:=motion_instance(runtime,state.entity);if instance==nil {return false}
    content:=motion_cached_content(assets,profile,&instance.content)
    if content==nil || !content.valid {instance.error=.Missing_Profile;return false}
    if !motion_bind(instance,state,content) {motion_problem(problems,state.entity,instance.error);return false}
    config:=content.profile.info.pose
    goal:=instance.locomotion
    if !goal.enabled || goal.weight==0 || config.weight==0 || !config.orientation && !config.stride {return true}
    speed:=linalg.length(goal.velocity)
    source:=goal.source_velocity if linalg.length(goal.source_velocity)>1e-6 else instance.source_velocity
    source_speed:=linalg.length(source)
    if !finite(speed) || !finite(source_speed) {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid);return false}
    if speed<1e-6 || source_speed<1e-6 {return true}
    // Toward a stop the direction of the velocity means little and its ratio to the clip's tends
    // to the minimum stride, so the warp fades out with the slower of the two speeds: a body that
    // nearly stops keeps the pose of the clip, as one that stops does.
    fade:=mm.saturate(min(speed,source_speed)/MOTION_WARP_FADE_SPEED)
    fade=fade*fade*(3-2*fade)
    up:=mm.quat_rotate(actor.rotation,{0,1,0})
    angle:f32;stride:f32=1
    if config.orientation {value,ok:=lib.orientation_warp_angle(source,goal.velocity,up,config.max_angle);if !ok {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid);return false};angle=value}
    if config.stride {value,ok:=lib.stride_warp_scale(source_speed,speed,config.min_stride,config.max_stride);if !ok {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid);return false};stride=value}
    ok:=lib.pose_warp(playing_skeleton(state),state.local[:],state.world[:],{pelvis=instance.pelvis,spine=instance.spine[:instance.spine_count],legs=instance.legs[:instance.leg_count],up=up,direction=goal.velocity,angle=angle,stride=stride,weight=config.weight*goal.weight*fade},root_transform)
    if !ok {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid)}
    return ok
}

motion_distance_time :: proc(profile:Motion_Profile,name:string,distance:f32) -> (time:f32,clip:[64]u8,ok:bool) {
    if !motion_profile_check(profile) {return}
    for &track in profile.distances {if base.text_get(track.name[:])==name {time,ok=lib.distance_to_time(profile.keys[track.first:][:track.count],distance);return time,track.clip,ok}}
    return
}

motion_distance_source :: proc "contextless" (profile:Motion_Profile,name:string) -> base.Asset_Id {
    for &track in profile.distances {if base.text_get(track.name[:])==name {return track.animation}}
    return {}
}
