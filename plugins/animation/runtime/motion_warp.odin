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

MOTION_WINDOWS :: 64
MOTION_KEYS :: 4096
// The warping of the pose of a .character to the velocity of its body: orientation turns its legs
// toward where it goes, against the spine; stride stretches them to its speed. Its pelvis, spine
// and legs are those of the body of the skeleton.
Pose_Warp_Profile :: struct {
    min_stride,max_stride,max_angle,weight:f32,
    orientation,stride:bool,
}
POSE_WARP_PROFILE_DEFAULT :: Pose_Warp_Profile{min_stride=.5,max_stride=2,max_angle=mm.PI,weight=1}

// m/s below which the pose warp fades out with the speed of the body or of its clip.
MOTION_WARP_FADE_SPEED :: .3
MOTION_WARP_HALF_LIFE :: .1 // seconds the turn and stride of the legs take to close half their way to the ones asked
// A warp window: while a clip crosses its span of this name, the root motion of the clip is
// warped to end at the target of that name (motion_target).
Motion_Window :: struct {
    name:[32]u8 `mirai:"text"`,
    translation,rotation:bool `mirai:"optional"`,
    axes:[3]bool `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
}
MOTION_WINDOW_DEFAULT :: Motion_Window{translation=true,rotation=true,axes={true,true,true},weight=1}
Motion_Distance :: struct {clip:[64]u8 `mirai:"text"`,name:[32]u8 `mirai:"text"`,first,count:u32,animation:base.Asset_Id}
Motion_Profile :: struct {warp:Pose_Warp_Profile,windows:[]Motion_Window,distances:[]Motion_Distance,keys:[]lib.Distance_Key}

motion_profile_check :: proc(profile:Motion_Profile) -> bool {
    if len(profile.windows)>MOTION_WINDOWS || len(profile.distances)>MOTION_WINDOWS || len(profile.keys)>MOTION_KEYS {return false}
    pose:=profile.warp
    if !profile_weight(pose.weight) || !finite(pose.min_stride) || !finite(pose.max_stride) || pose.min_stride<=0 || pose.max_stride<pose.min_stride || !finite(pose.max_angle) || pose.max_angle<0 || pose.max_angle>mm.PI {return false}
    for &window,i in profile.windows {
        if !blend_text_valid(window.name[:],false) || !profile_weight(window.weight) || !window.translation && !window.rotation {return false}
        for &previous in profile.windows[:i] {if previous.name==window.name {return false}}
    }
    for &track,i in profile.distances {
        if !blend_text_valid(track.clip[:],false) || !blend_text_valid(track.name[:],false) || track.first>u32(len(profile.keys)) || track.count>256 || track.count>u32(len(profile.keys))-track.first {return false}
        if !lib.distance_track_validate(profile.keys[track.first:][:track.count]) {return false}
        for &previous in profile.distances[:i] {if previous.name==track.name {return false}}
    }
    return true
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

// Gives the warp windows of name of the .character of rig a target: their root motion ends there.
motion_target :: proc(requests:^Animation_Requests,rig:core.Entity,name:string,target:Spatial_Target,enabled:bool=true) {
    if requests==nil {return}
    valid:=rig!=core.NONE && len(name)>0 && len(name)<32 && spatial_target_valid(target)
    for byte in name {valid&&=byte!=0}
    if !valid {core.refuse(&requests.warps);return}
    value:=Motion_Target{target=target,enabled=enabled};copy(value.name[:],transmute([]u8)name)
    core.offer(&requests.warps,Motion_Target_Request{rig=rig,target=value})
}
motion_locomotion :: proc(requests:^Animation_Requests,value:Motion_Locomotion) {
    if requests==nil {return}
    if value.rig==core.NONE || !profile_vector(value.velocity) || !profile_vector(value.source_velocity) || !profile_weight(value.weight) {core.refuse(&requests.locomotion);return}
    core.offer(&requests.locomotion,value)
}

Motion_Instance :: struct {
    entity:core.Entity,
    profile:base.Asset_Id, // the .character it was bound for
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
    warp,warping:[2]f32, // the turn of the legs (radians) and the stride scale less 1, and their rates per second
    window:i32,
    remaining_error:f32,
    error:Motion_Error,
}
@(storage,free="motion_runtime_free")
Motion_Runtime :: struct {instances:[dynamic]Motion_Instance,rows:[dynamic]i32,frame:u64,animations_seen:core.Seen}
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

// Reports why the warping of the .character of a rig did not apply in a tick.
motion_problem :: proc(problems:^core.Problems,e:core.Entity,error:Motion_Error) {
    switch error {
    case .None,.Unsupported_Clock,.Missing_Profile:
    case .Invalid:
        core.report(problems,e,"animation.motion_invalid","the warping of this rig could not warp it: a value of its .character, of its targets, of the locomotion asked or of the root motion is not finite or is out of range; check them (animation.inspect)")
    case .Unbound_Bone:
        core.report(problems,e,"animation.motion_bones","the warping of the stride or orientation of this rig needs the pelvis, the spine and the legs (hip, knee, foot) of the body of its skeleton, and its body lacks them or its legs are not chains; detect the body with skeleton.body.detect or set it with skeleton.body.set")
    case .Missing_Target:
        core.report(problems,e,"animation.motion_target","a warp window of the .character of this rig has no target: none was given with motion_target for its name, or what it names is gone: an entity without Transform, a rig not animated in the previous tick, or a bone or socket its skeleton does not have; give it one that exists")
    case .Capacity:
        core.report(problems,e,"animation.motion_targets","a motion target was refused: this rig has %d targets with other names, as many as fit; reuse their names",MOTION_WINDOWS)
    case .Out_Of_Memory:
        memory_problem(problems,e,"the warping of its .character")
    }
}

// The pelvis, spine and legs of the body of the skeleton of state, which the warping of its stride
// and orientation moves.
@(private)
motion_bind :: proc(instance:^Motion_Instance,state:^Playing,content:^Character_Content) -> bool {
    if instance.profile==content.id && instance.revision==content.revision && instance.bound==state.bound {if !instance.bound_valid {instance.error=.Unbound_Bone};return instance.bound_valid}
    config:=content.set.motion.warp
    instance.profile,instance.revision,instance.bound=content.id,content.revision,state.bound
    instance.bound_valid=false
    instance.spine_count,instance.leg_count=0,0
    instance.error=.None;instance.window=-1
    if config.orientation || config.stride {
        body:=state.body
        instance.pelvis=body[.Pelvis];if instance.pelvis<=0 {instance.error=.Unbound_Bone;return false}
        // The spine: the bones from the parent of the neck down to the pelvis, the top one first.
        if neck:=int(body[.Neck]);neck>0 {
            for at:=int(state.parents[neck]);at>0 && i32(at)!=instance.pelvis && int(instance.spine_count)<len(instance.spine);at=int(state.parents[at]) {instance.spine[instance.spine_count]=i32(at);instance.spine_count+=1}
        }
        for side in ([2][3]lib.Body_Part{{.Hip_L,.Knee_L,.Foot_L},{.Hip_R,.Knee_R,.Foot_R}}) {
            leg:=lib.Pose_Warp_Limb{hip=body[side[0]],knee=body[side[1]],foot=body[side[2]]}
            if leg.hip<=0 || leg.knee<=0 || leg.foot<=0 || state.parents[leg.knee]!=leg.hip || state.parents[leg.foot]!=leg.knee {continue}
            instance.legs[instance.leg_count]=leg;instance.leg_count+=1
        }
        if config.stride && instance.leg_count==0 {instance.error=.Unbound_Bone;return false}
    }
    instance.bound_valid=true
    return true
}

motion_take_requests :: proc(runtime:^Motion_Runtime,requests:^Animation_Requests,problems:^core.Problems) {
    for request in core.take(&requests.warps) {
        instance:=motion_instance(runtime,request.rig)
        if instance==nil {
            core.report(problems,request.rig,"animation.motion_owner","a motion target was given for this entity, and its Animation plays no .character; set Animation.asset to one, or give it to the entity that has one")
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
    for request in core.take(&requests.locomotion) {
        if instance:=motion_instance(runtime,request.rig);instance!=nil {
            instance.locomotion=request
        } else {
            core.report(problems,request.rig,"animation.motion_owner","a motion locomotion was given for this entity, and its Animation plays no .character; set Animation.asset to one, or give it to the entity that has one")
        }
    }
}

@(private)
motion_discover :: proc(runtime:^Motion_Runtime,animations:core.Read(Animation),assets:^host.Assets,problems:^core.Problems) -> bool {
    // Kept only when the entities found have their room: without it they are looked for again.
    seen:=runtime.animations_seen
    c:=core.changes(animations,&seen)
    if seen==runtime.animations_seen {return true}
    added,rows:=0,len(runtime.rows)
    counted:=c
    for row in core.each_changed(animations,&counted) {
        if animation_character(assets,animations.table.values[row])=={} {continue}
        index:=core.entity_index(core.entity_at(animations,row));rows=max(rows,index+1)
        slot:=int(runtime.rows[index])-1 if index<len(runtime.rows) else -1
        if slot<0 || slot>=len(runtime.instances) || core.entity_index(runtime.instances[slot].entity)!=index {added+=1}
    }
    if !program_array_reserve(&runtime.instances,len(runtime.instances)+added) || !program_array_resize(&runtime.rows,rows) {memory_problem(problems,core.NONE,"the entities whose .character warps, so none applies");return false}
    for row in core.each_changed(animations,&c) {
        if animation_character(assets,animations.table.values[row])=={} {continue}
        entity:=core.entity_at(animations,row);index:=core.entity_index(entity);slot:=int(runtime.rows[index])-1
        if slot<0 || slot>=len(runtime.instances) || core.entity_index(runtime.instances[slot].entity)!=index {
            slot=len(runtime.instances)
            if append(&runtime.instances,Motion_Instance{entity=entity,window=-1})!=1 {memory_problem(problems,core.NONE,"the entities whose .character warps, so none applies");return false}
        } else if runtime.instances[slot].entity!=entity {
            // A new entity in the slot keeps the memory of its targets.
            reused:=&runtime.instances[slot];targets,bindings:=reused.targets,reused.bindings
            clear(&targets);reused^={entity=entity,window=-1};reused.targets=targets;reused.bindings=bindings
        }
        runtime.rows[index]=i32(slot+1)
    }
    runtime.animations_seen=seen
    return true
}

motion_prepare :: proc(runtime:^Motion_Runtime,requests:^Animation_Requests,animations:core.Read(Animation),playback:^Playback,characters:^Character_Assets,loaded:^host.Assets,allocator:mem.Allocator,problems:^core.Problems) -> bool {
    if runtime==nil || playback==nil || animations.table==nil {return false}
    if allocator.procedure!=nil {context.allocator=allocator}
    runtime.frame+=1
    if !motion_discover(runtime,animations,loaded,problems) {return false}
    kept:=0
    for &instance,i in runtime.instances {
        row:=core.row_of(animations,instance.entity);index:=core.entity_index(instance.entity)
        id:=animation_character(loaded,animations.table.values[row]) if row>=0 else {}
        if id=={} {if index<len(runtime.rows) && runtime.rows[index]==i32(i+1) {runtime.rows[index]=0};motion_instance_free(&instance);continue}
        instance.seen=runtime.frame
        state:=constraint_playing(playback,instance.entity)
        content:=character_content(characters,loaded,allocator,id,&instance.content)
        if content==nil {
            instance.error=.Missing_Profile
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

motion_apply_root :: proc(runtime:^Motion_Runtime,characters:^Character_Assets,loaded:^host.Assets,allocator:mem.Allocator,state:^Playing,profile:base.Asset_Id,content:^host.Content_Animation,actor:mm.Transform,dt:f32,seeking:bool=false,clock:Motion_Clock={},base_weight:f32=1) -> bool {
    if state==nil || profile=={} {return true}
    instance:=motion_instance(runtime,state.entity);if instance==nil {return false}
    definition:=character_content(characters,loaded,allocator,profile,&instance.content)
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
    spans:[MOTION_WINDOWS]Motion_Window_Span;span_count:=0
    for &window,w in definition.set.motion.windows {
        if window.weight==0 || !(window.translation && root.translation && (window.axes[0] || window.axes[1] || window.axes[2]) || window.rotation && root.rotation) {continue}
        // Its span on the clip that plays: one without that span is not warped.
        window_start,window_end,spanned:=clip_span(content,player.clip,base.name_hash(base.text_get(window.name[:])))
        if !spanned {continue}
        offset:=f32(0)
        if to>duration && from>=window_end {offset=duration}
        start,end:=window_start+offset,window_end+offset
        if end>duration+offset {instance.error=.Unsupported_Clock;return false}
        a,b:=max(from,start),min(to,end);if b<=a {continue}
        slot:=span_count
        for slot>0 && spans[slot-1].from>a {spans[slot]=spans[slot-1];slot-=1}
        spans[slot]={u8(w),a,b,end};span_count+=1
    }
    original:=state.motion
    for span in spans[:span_count] {
        w:=int(span.window);window:=&definition.set.motion.windows[w];a,b,end:=span.from,span.to,span.end
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

motion_apply_pose :: proc(runtime:^Motion_Runtime,state:^Playing,profile:base.Asset_Id,actor,root_transform:mm.Transform,characters:^Character_Assets,problems:^core.Problems,dt:f32) -> bool {
    if state==nil || profile=={} {return true}
    instance:=motion_instance(runtime,state.entity);if instance==nil {return false}
    content:=character_cached(characters,profile,&instance.content)
    if content==nil {instance.error=.Missing_Profile;return false}
    if !motion_bind(instance,state,content) {motion_problem(problems,state.entity,instance.error);return false}
    config:=content.set.motion.warp
    goal:=instance.locomotion
    if !goal.enabled || goal.weight==0 || config.weight==0 || !config.orientation && !config.stride {instance.warp,instance.warping={},{};return true}
    speed:=linalg.length(goal.velocity)
    source:=goal.source_velocity if linalg.length(goal.source_velocity)>1e-6 else instance.source_velocity
    source_speed:=linalg.length(source)
    if !finite(speed) || !finite(source_speed) {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid);return false}
    if speed<1e-6 || source_speed<1e-6 {instance.warp,instance.warping={},{};return true}
    // Toward a stop the direction of the velocity means little and its ratio to the clip's tends
    // to the minimum stride, so the warp fades out with the slower of the two speeds: a body that
    // nearly stops keeps the pose of the clip, as one that stops does.
    fade:=mm.saturate(min(speed,source_speed)/MOTION_WARP_FADE_SPEED)
    fade=fade*fade*(3-2*fade)
    up:=mm.quat_rotate(actor.rotation,{0,1,0})
    angle:f32;stride:f32=1
    if config.orientation {value,ok:=lib.orientation_warp_angle(source,goal.velocity,up,config.max_angle);if !ok {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid);return false};angle=value}
    if config.stride {value,ok:=lib.stride_warp_scale(source_speed,speed,config.min_stride,config.max_stride);if !ok {instance.error=.Invalid;motion_problem(problems,state.entity,.Invalid);return false};stride=value}
    weight:=config.weight*goal.weight*fade
    // The legs follow the turn and the stride asked by a spring: a body that starts or turns at
    // once asks them at once.
    if finite(dt) && dt>0 {instance.warp,instance.warping=mm.spring_critical(instance.warp,instance.warping,[2]f32{angle,stride-1}*weight,mm.spring_omega(MOTION_WARP_HALF_LIFE),dt)}
    ok:=lib.pose_warp(playing_skeleton(state),state.local[:],state.world[:],{pelvis=instance.pelvis,spine=instance.spine[:instance.spine_count],legs=instance.legs[:instance.leg_count],up=up,direction=goal.velocity,angle=instance.warp[0],stride=max(1+instance.warp[1],min(config.min_stride,1)),weight=1},root_transform)
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
