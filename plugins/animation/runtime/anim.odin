package anim

import "core:slice"
import "core:mem"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

EVENT_BATCH :: 16     // markers one entity crosses in a tick
PLAY_EVENT_BATCH :: 8 // match_play events one entity reports in a tick
POSE_CAPACITY :: 1024 // properties one entity drives
CLIP_CAPACITY :: 64
ANIMATION_LAYERS :: 3 // clips played over the one of the component

// Plays a clip of an asset. While playing is set the library advances the
// clip every fixed tick and writes the pose; in the editor it plays only
// with preview. Changing clip cross-fades into the new one over fade seconds
// (0: cut); the new clip starts at 0. weight is how much of the pose replaces
// what the subtree had when it was bound. On an entity whose Mesh_Renderer
// shows a mesh with a skeleton the clip poses that skeleton; on another it
// moves the entities below it by name. animation_play sets the layers.
@(component,description="Plays a clip, motion matching locomotion (.match) or a pose graph (.agraph), with named parameters, layers and a root motion policy. Can use another entity's animation source.")
Animation :: struct {
    asset:base.Asset_Id `mirai:"section=Clip,kind=.anim .match .agraph"`, // .anim, .match or .agraph
    library:base.Asset_Id `mirai:"kind=.anim"`, // .anim whose clips replace those of a .match or .agraph, by name
    clip:[CLIP_CAPACITY]u8 `mirai:"text"`, // empty: the first of the asset
    speed:f32 `mirai:"section=Playback"`, // negative plays backwards: once, from the end
    loop:bool,
    mirror:bool,                           // left and right bones of a skeleton swap, reflected across the plane between them
    playing:bool,
    preview:bool,                          // plays in the editor too
    weight:f32 `mirai:"min=0,max=1"`,
    fade:f32 `mirai:"min=0,unit=s"`,
    root_motion:Root_Motion_Policy `mirai:"section=Motion"`,
    source:core.Entity,
    retarget:base.Asset_Id `mirai:"kind=.pose"`,
    motion:base.Asset_Id `mirai:"kind=.motion"`,
    actions:base.Asset_Id `mirai:"kind=.action"`,
    event_policy:Event_Policy `mirai:"section=Events"`,
    event_threshold:f32 `mirai:"min=0,max=1"`,
    layers:[ANIMATION_LAYERS]Animation_Layer `mirai:"hidden"`,
    parameters:[GRAPH_PARAMETERS]f32 `mirai:"hidden"`,
    parameter_names:[GRAPH_PARAMETERS]u64 `mirai:"hidden"`, // base.name_hash of the parameter or axis of each value; 0: free
}

Root_Motion_Policy :: enum u8 {None,Extract,In_Place}
Event_Policy :: enum u8 {Dominant,Weighted,Always}
Layer_Mode :: enum u8 {Override,Additive}
Curve_Blend :: enum u8 {Override,Additive,Ignore}

ANIMATION_DEFAULT :: Animation{speed=1,weight=1,loop=true,playing=true,fade=0.2,event_policy=.Weighted,event_threshold=.01}

// A clip played over the clip of the component.
Animation_Layer :: struct {
    clip:u64,   // base.name_hash of a clip of the asset; 0: the layer fades out
    over:u64,   // base.name_hash of the path or name of the bone whose branch it moves; 0: the whole pose
    weight:f32, // over what is below it
    speed:f32,
    fade:f32,   // seconds to reach its weight, and of a change of clip
    loop:bool,
    sync:bool,  // its phase follows the clip of the component, by markers when both have them
    mode:Layer_Mode,
    reference:f32,       // Additive: seconds into the reference clip whose pose it adds its clip over
    reference_clip:u64,  // Additive: base.name_hash of that clip of the asset; 0: its own clip
    curves:Curve_Blend,
    mesh_space:bool, // Override: the rotations of its branch blend in the space of the rig, so it keeps the turn its clip gives them whatever the base turns above it
}

@(component,description="An imported rigid animation target identified by its canonical path.")
Animation_Target :: struct {path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text,hidden"`}

// Where the clip of the Animation of an entity is while the game plays: what
// a saved game keeps, since Playback is derived and starts again when the
// World loads. Only animation_sample writes it.
@(component,description="Where the clip of the Animation of this entity is while the game plays: a saved game goes on from there.")
Animation_Progress :: struct {
    time:f32 `mirai:"readonly,unit=s"`,
}

Animation_Seek :: struct {
    entity:core.Entity,
    time:f32,
}

@(storage,queue)
Animation_Requests :: struct {
    seeks:core.Queue(Animation_Seek),
    distances:core.Queue(Animation_Distance_Request),
    poses:core.Queue(Pose_Request),
    final_poses:core.Queue(Pose_Request),
    match_goals:core.Queue(Match_Goal),
    match_plays:core.Queue(Match_Play),
}

// A marker a playing Animation crossed in this tick, also those of a clip
// that is fading out and of the layers that do not follow it.
Animation_Marker :: struct {
    entity:core.Entity,
    clip:u64,   // base.name_hash of the name of the clip
    marker:u64, // and of the marker
    time:f32,   // where the marker sits in the clip
    fraction:f32, // of the tick's advance where it was crossed
    weight:f32,
    source:u32,
    group:u16,
    animation:base.Asset_Id, // the .anim of the clip
}

Animation_Play_Event_Kind :: enum u8 {Entered,Exited,Finished}

// A clip of match_play that began, gave the rig back (to matching or to another play) or
// reached its end.
Animation_Play_Event :: struct {
    entity:core.Entity,
    kind:Animation_Play_Event_Kind,
    clip:u64,  // base.name_hash of the name of the clip, as the library of the .match calls it
    other:u64, // Entered: the play it interrupted (0: matching); Exited: the play that interrupted it (0: matching)
}

// Cleared and filled by animation_sample in every fixed tick: read it in fixed.
@(storage,events)
Animation_Events :: struct {
    using queue:core.Queue(Animation_Marker),
    plays:core.Queue(Animation_Play_Event),
}

Property_Set :: bit_set[lib.Property;u8]

Binding :: struct {
    target:u64,                // of the tracks that move it
    entity:core.Entity,
    driven:Property_Set,       // what some clip of the asset moves of it
    rest:mm.Transform,         // its Transform when it was bound
    parent:i32,
}

Layer_Playing :: struct {
    fader:lib.Fader,
    clip:u64,   // the one it plays; 0: none
    weight:f32, // on its way to the one asked
}

Playing :: struct {
    entity:core.Entity,
    asset:base.Asset_Id,
    source_plan:u32,           // in Source_Assets.plans + 1
    generation:u32,            // of the content the state was made for
    fader:lib.Fader,
    prev_fader:lib.Fader,
    clip:int,                  // of the asset; -1: none
    time,duration:f32,         // of the clip of the component, in seconds
    ended:bool,                // a clip that does not loop reached the end it heads to; playing again starts it over
    was_playing:bool,
    previewed:bool,            // played in the editor in the last tick
    layers:[ANIMATION_LAYERS]Layer_Playing,
    program:Program_Playing,
    layer_over:[ANIMATION_LAYERS]u64,
    curves:[dynamic]Curve_Output,
    curves_ready:bool,
    motion:Root_Delta,
    root_enabled:bool,
    body_motion:Body_Motion,   // the part of motion its actions give its body
    action_root:Root_Motion,
    has_action_root:bool,
    base_root:Root_Motion,
    has_base_root:bool,
    clips_in_place:bool,       // pose_sample keeps the root of each clip in place as it blends it
    action_roots:[ANIMATION_LAYERS]Root_Motion,
    action_root_mask:u8,
    action_in_place_root:Root_Motion,
    action_in_place_local:mm.Transform,
    has_action_in_place:bool,
    bindings:[dynamic]Binding,
    bound,hierarchy_stamp:u64,
    seen:u64,
    parents:[dynamic]i32,
    targets:[dynamic]u64,
    aliases:[dynamic]u64,
    rest,local,world,sampled:[dynamic]mm.Transform,
    previous:[dynamic]mm.Transform,
    mirror_pairs:[dynamic]i32,             // by bone: the bone on the other side, itself when centered; empty: cannot mirror
    mirror_corrections:[dynamic]mm.Quat,
    mirror_scratch:[dynamic]mm.Transform,  // two poses in rig space
    mirror_plane:lib.Mirror_Plane,
    body:[lib.Body_Part]i32,               // by part of the body of the skeleton: its bone; 0 when the body has none
    regions:[dynamic]i8,                   // by bone: its region of the body (lib.body_regions); empty without a body
    skeleton:base.Asset_Id,
    skeleton_revision:u64,
    changed:u64,               // Playback.frame of the last tick whose pose differed from previous
    pose_ready:bool,
    finished:u64,              // Playback.frame of the last tick its modifiers ran
    leader:core.Entity,        // the rig of another skeleton whose pose it follows (Pose_Source); NONE: none
    follow:[dynamic]lib.Follow_Bone,       // by bone: the bone of the leader it takes
    world_final:u64,                       // Playback.frame whose finished pose world holds, in the world, for its followers
    follow_bound:[2]u64,                   // the bound of the leader and its own the follow was paired for
    driven:[dynamic]Curve_Output,          // its curves after those of its leader and the drives of its profile, while driven_ready
    driven_own,driven_leader:[dynamic]i32, // where each of its curves and of its leader's goes in driven
    driven_key:Driven_Key,                 // what driven was laid out for
    driven_ready:bool,
    curve_layout:u64,                      // changes when the curves a lookup reads change place
}

// An entity whose Mesh_Renderer shows a mesh with a skeleton and that does
// not share the pose of another of that skeleton through Pose_Source: it poses
// that skeleton. One whose Pose_Source names a rig of another skeleton follows
// it: leader is that rig.
Rig :: struct {entity:core.Entity,skeleton:base.Asset_Id,leader:core.Entity}
// A rig that follows another, and how many leaders are above it (max: it is in a loop).
Rig_Follow :: struct {entity:core.Entity,depth:u32}

Stats :: struct {
    skipped:u64, // writes left out because another component owns the transform
}

// Playback belongs to the simulated world, including its cross-fades and rest pose.
@(storage,free="playback_free")
Playback :: struct {
    states:[dynamic]Playing,
    rows:[dynamic]i32, // by entity index: state+1
    rigs:[dynamic]Rig,
    follow_order:[dynamic]Rig_Follow, // the rigs that follow another, each after the rig it follows
    rigs_stamp:u64,
    rigs_inputs:[5]u64,
    pose:lib.Pose,
    mask:[dynamic]f32, // of the layer being sampled, by binding
    rig_rotations:[dynamic]mm.Quat, // of a layer blended in the space of the rig: the base, the layer and the blend, by binding
    final_rows:[dynamic]i32,
    frame,binding_revision:u64,
    stats:Stats,
}

@(private)
animation_tick :: proc(
    animations:core.Read(Animation),transforms:^core.Table(core.Transform),
    parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),names:core.Read(core.Name),requests:^Animation_Requests,events:^Animation_Events,
    targets:core.Read(Animation_Target),roots:core.Read(Root_Motion),
    playback:^Playback,app:^host.App,time:core.Time,frame:core.Frame_Time,skeleton_assets:^Skeleton_Assets,problems:^core.Problems,blends:^Blend_Assets=nil,graphs:^Graph_Assets=nil,
    actions:^Action_Runtime=nil,action_requests:^Action_Requests=nil,action_assets:^Actions_Assets=nil,motion:^Motion_Runtime=nil,motion_requests:^Motion_Requests=nil,motion_assets:^Motion_Assets=nil,sources:^Source_Assets=nil,
    paces:core.Read(core.Own_Pace)={},clock:=core.CLOCK_DEFAULT,
) {
    playback.frame+=1
    clear(&events.items);clear(&events.plays.items)
    if app.assets==nil || !finite(time.dt) || time.dt<0 {for &state in playback.states {clear(&state.curves);state.curves_ready=false;state.driven_ready=false;state.motion=ROOT_DELTA_DEFAULT;state.root_enabled=false;state.body_motion={}};return}
    // The editor runs this once a frame with dt 0: a preview advances by the frame.
    tick_dt:=time.dt
    if !time.playing {tick_dt=frame.dt if finite(frame.dt) && frame.dt>0 else 0}
    stamp:=core.layout(parents)+core.version(parents)+core.layout(names)+core.version(names)+core.layout(targets)+core.version(targets)+core.layout(core.read(transforms))+core.layout(animations)+playback.rigs_stamp+1
    if actions!=nil && !actions_prepare(actions,action_requests,action_assets,animations,playback,app,problems) {return}
    if motion!=nil {if !motion_prepare(motion,motion_requests,animations,playback,motion_assets,app,problems) {return};motion_resolve_targets(motion,playback,skeleton_assets,core.read(transforms),parents,{})}
    distances:=core.take(&requests.distances)
    seeks:=core.take(&requests.seeks)
    pose_requests:=core.take(&requests.poses)
    match_goals:=core.take(&requests.match_goals)
    match_plays:=core.take(&requests.match_plays)
    // Each rig gets its own goal, the last one told for it, found once for all of them; a rig
    // made in this tick is not there yet and looks for its own.
    unindexed:=0
    for goal,i in match_goals {if state:=constraint_playing(playback,goal.rig);state!=nil {state.program.match.goal=i32(i)+1} else {unindexed+=1}}
    rig_count:=len(playback.rigs)
    for row in 0..<rig_count+core.count(animations) {
        skeletal:=row<rig_count
        e:=playback.rigs[row].entity if skeletal else core.entity_at(animations,row-rig_count)
        if !skeletal && rig_find(playback,e)>=0 {continue}
        // An entity with a pace of its own advances by its own time.
        pace:=core.pace_of(clock,paces,e) if time.playing else 1
        dt:=tick_dt*pace
        if !core.has(core.read(transforms),e) {continue}
        animation,animated:=core.get(animations,e)
        if !animated {animation=ANIMATION_DEFAULT;animation.playing=false}
        if !time.playing {animation.playing=animation.playing && animation.preview}
        if !animation_valid(animation) {
            core.report(problems,e,"animation.invalid","Animation of this entity has a value that is not finite, an event_threshold outside 0 to 1, a layer with a negative reference or a mode out of range, or a parameter set twice, so it does not play; fix it")
            continue
        }
        state:=state_get(playback,e)
        if state==nil {memory_problem(problems,e,"its animation");continue}
        content,source_error:=animation_content(sources,app,state,animation,blends,graphs,actions)
        // Until its sources load it plays on what it played (a weapon's set swapped into library
        // takes over once loaded), or, having played nothing, as an Animation without asset: a rig
        // holds its rest pose.
        if source_error==.Pending {
            previous,played,library,kept:=source_previous(sources,app,state,animation)
            if kept {content,animation.asset,animation.library,source_error=previous,played,library,.None} else {animation.asset,animation.library,source_error={},{},.None}
        }
        if source_error!=.None {state.program.error=source_error;program_problem(problems,e,app,animation,source_error);continue}
        if content==nil && animation.asset!={} {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,e,"animation.asset","Animation.asset names %s, which cannot be played: it is missing, is not an .anim, .match or .agraph, or is damaged; asset_errors of engine.diagnostics says which, and importing it again fixes a damaged one",host.assets_name(app.assets,animation.asset,&name))
        }
        first_event:=len(events.items)
        defer source_markers_resolve(sources,state,events.items[first_event:])
        facing:=mm.Vec3{0,0,1};placed:=mm.TRANSFORM_IDENTITY
        if state.program.kind==MATCH_KIND {if world,ok:=constraint_world(core.read(transforms),parents,{},e);ok {placed=world;facing=mm.quat_rotate(world.rotation,facing)}}
        rig_goals:[]Match_Goal
        if at:=int(state.program.match.goal)-1;at>=0 && at<len(match_goals) && match_goals[at].rig==e {rig_goals=match_goals[at:][:1]} else if unindexed>0 {
            for &goal,i in match_goals {if goal.rig==e {rig_goals=match_goals[i:][:1]}}
        }
        state.program.match.goal=0
        program,programmed,program_valid:=program_resolve(state,animation,app,blends,graphs,dt,events,playback,content,problems,rig_goals,match_plays,facing)
        if !program_valid {program_problem(problems,e,app,animation,state.program.error);continue}
        if !programmed && animation.library!={} {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,e,"animation.library","Animation.library replaces the clips of a .match or .agraph, and Animation.asset %s is neither; clear library, or set asset to a .match or .agraph",host.assets_name(app.assets,animation.asset,&name))
            continue
        }
        content_id:=program.asset if programmed else animation.asset
        if !skeletal && content==nil {continue}
        needed:=max(POSE_CAPACITY,content.lib.track_count if content!=nil else 0)
        if len(playback.pose.entries)<needed {
            lib.pose_destroy(&playback.pose)
            if !lib.pose_init(&playback.pose,needed,app.allocator) {memory_problem(problems,core.NONE,"the pose of the animated entities, so nothing is animated in this tick");return}
        }
        sought:=f32(-1)
        for seek in seeks {if seek.entity==e {sought=max(seek.time,0)}}
        // Once a preview stops, the editor shows the start of the clip again.
        previewing:=!time.playing && animation.playing
        if !time.playing && state.previewed && !previewing {sought=0}
        state.previewed=previewing
        generation:=content.generation if content!=nil else 0
        changed:=state.asset!=content_id || state.generation!=generation
        if changed {
            state.asset,state.generation=content_id,generation
            state.curves_ready=false
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            state.fader=lib.Fader{}
            state.clip=-1
            state.layers={}
            mem.zero_slice(state.program.players[:]);state.program.fade=0
            if !skeletal {state.hierarchy_stamp=0}
        }
        if skeletal {
            state.leader=playback.rigs[row].leader
            skeleton:=playback.rigs[row].skeleton
            definition:=skeleton_content(skeleton_assets,app,skeleton)
            if definition==nil {
                if skeleton_assets!=nil {asset_problem(problems,e,app,"animation.skeleton","the mesh of its Mesh_Renderer",skeleton,content_error(skeleton_assets.contents[:],skeleton))}
                continue
            }
            if changed || state.skeleton!=definition.id || state.skeleton_revision!=definition.revision || len(state.bindings)==0 {
                if !skeleton_bind(playback,state,definition,content,transforms) {memory_problem(problems,e,"the pose of its skeleton");continue}
            }
            if programmed && len(state.program.from)!=len(state.local) && resize(&state.program.from,len(state.local))!=nil {memory_problem(problems,e,"its animation program");continue}
            if state.pose_ready {copy(state.previous[:],state.local[:])}
            copy(state.local[:],state.rest[:])
            if root,ok:=core.get(core.read(transforms),e);ok {state.local[0]=core.to_math(root)}
        } else if state.skeleton!={} || state.hierarchy_stamp!=stamp {
            state.leader=core.NONE
            if !bind(playback,state,content,hierarchy,transforms,names,targets,animations,problems) {
                core.report(problems,e,"animation.bind","the entities below this animated entity could not be bound: memory ran out; free memory, or animate fewer entities below it")
                continue
            }
            state.hierarchy_stamp=stamp
            state.skeleton={};state.skeleton_revision=0
        }
        if programmed && len(state.program.from)!=len(state.local) && resize(&state.program.from,len(state.local))!=nil {memory_problem(problems,e,"its animation program");continue}

        state.motion=ROOT_DELTA_DEFAULT;state.root_enabled=false;state.has_action_root=false;state.body_motion={}
        state.driven_ready=false
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        state.base_root={}
        state.has_base_root=false;state.clips_in_place=false
        if roots.table!=nil {
            base_root,has_base_root:=core.get(roots,e)
            state.base_root=base_root
            state.has_base_root=has_base_root
        }
        state.action_root_mask=0;state.has_action_in_place=false
        distance:^Animation_Distance_Request;action_distance:^Animation_Distance_Request;distance_error:=Distance_Error.None
        for &request in distances {if request.entity==e {distance_error=distance_request_check(state,content,request,actions);_,on_action:=action_player(actions,e,request.clip,content,request.animation);if !request.seek && !on_action && animation.speed<=0 {distance_error=.Unsupported_Clock};if distance_error==.None {distance=&request}}}
        if distance!=nil {_,on_action:=action_player(actions,e,distance.clip,content,distance.animation);if on_action {action_distance=distance;distance=nil}}
        current_dt:=dt
        if distance!=nil && !programmed {if distance.seek {sought=distance.time;current_dt=0} else {current_dt=(distance.time-state.fader.current.time)/animation.speed}}
        for layer,i in animation.layers {state.layer_over[i]=layer.over}
        // The pose refuses what does not fit and counts it.
        refused:=playback.pose.failed
        if content!=nil {
            if programmed {
                if !program_masks_prepare(state,program,content,graphs,app) {program_problem(problems,e,app,animation,state.program.error);continue}
                if !program_players(state,program,content,animation,events,playback,dt,sought,problems,distance) {program_problem(problems,e,app,animation,state.program.error);continue}
                if state.program.has_root {
                    state.base_root=state.program.root
                    state.has_base_root=true
                }
                if !program_pose(playback,state,content,animation,program,core.read(transforms)) {program_problem(problems,e,app,animation,state.program.error);continue}
            } else {
                state.program.ready=false;state.program.has_root=false
                advance(playback,state,content,animation,events,dt,problems,sought,current_dt)
                state.clips_in_place=!state.has_base_root && animation.root_motion==.In_Place
                if !state.has_base_root && animation.root_motion!=.None && state.clip>=0 && state.clip<len(content.roots) {
                    root:=content.roots[state.clip]
                    state.base_root={bone={root.bone},translation=root.translation,rotation=root.rotation,in_place=animation.root_motion==.In_Place}
                    state.has_base_root=root.translation || root.rotation
                }
            }
            if actions!=nil {actions_sample(actions,state,&animation,dt,problems,content,playback,events,action_distance,pace)}
            layers_advance(playback,state,content,animation,events,dt,problems)
            if actions!=nil {actions_layer_finish(actions,state)}
            if programmed {pose_layers(playback,state,&content.lib,animation,problems,core.read(transforms));sample_layer_curves(state,content,animation)} else {pose_sample(playback,state,&content.lib,animation,core.read(transforms),problems,content);sample_curves(state,content,animation.weight,animation)}
            if playback.pose.failed!=refused {
                core.report(problems,e,"animation.pose_full","values of the clips of this entity were left out of its pose: they animate more than the %d values a pose holds, or two of their targets share a key; give its clips fewer tracks, or rename the colliding ones",len(playback.pose.entries))
            }
            if animation.mirror && !playing_mirror(state,state.local[:]) {
                core.report(problems,e,"animation.mirror","Animation.mirror is on, and this rig has no skeleton whose bones say their side (Left, Right, L_, _R...) to swap, so it plays unmirrored; turn mirror off, or name the bones of its skeleton by side")
            }
        } else {clear(&state.curves);state.curves_ready=false}
        for request in pose_requests {
            if request.rig!=e {continue}
            bone:=bone_resolve(state,request.bone)
            if bone<0 {
                request:=request
                core.report(problems,e,"animation.pose_bone","a pose was asked for '%s', which this rig does not have; %s",base.text_get(request.bone.path[:]),bone_fix(request.bone))
                continue
            }
            state.local[bone]=mm.transform_interpolate(state.local[bone],request.transform,request.weight)
        }

        if root,extract:=state.base_root,state.has_base_root;extract && !programmed {
            motion:=ROOT_DELTA_DEFAULT
            if content!=nil && animation.playing && sought<0 {
                root_bone:=bone_target(state,root.bone)
                motion=root_motion_sample(&content.lib,state.prev_fader,root,dt,root_bone,current_dt)
                motion.translation,motion.rotation=root_motion_to_rig(state,root_bone,motion.translation,motion.rotation)
                motion.translation*=mm.saturate(animation.weight)
                motion.rotation=mm.quat_slerp(1,motion.rotation,mm.saturate(animation.weight))
            }
            state.motion=motion;state.root_enabled=true
        }
        if actions!=nil && content!=nil {actions_apply_root(actions,state,animation)}
        if animation.mirror && len(state.mirror_pairs)>0 {
            state.motion=root_delta_mirror(state.mirror_plane,state.motion)
            state.body_motion.translation=lib.mirror_vector(state.mirror_plane,state.body_motion.translation)
            if state.has_action_in_place {if bone:=bone_resolve(state,state.action_in_place_root.bone);bone>0 && state.parents[bone]==0 {state.action_in_place_local=lib.mirror_transform(state.mirror_plane,state.mirror_corrections[bone],state.action_in_place_local)}}
        }
        if motion!=nil && animation.motion!={} && content!=nil {
            actor,ok:=constraint_world(core.read(transforms),parents,{},e)
            clock:=animation_motion_clock(state,content,program if programmed else nil,dt,current_dt)
            clock.weight*=mm.saturate(animation.weight)
            if state.has_base_root && !programmed {clock.root=state.base_root}
            action:=action_clock(actions,e);if action.player.clip!=0 {clock=action}
            if animation.mirror && len(state.mirror_pairs)>0 {clock.mirror=!clock.mirror}
            unwarped:=state.motion.translation
            if ok && !motion_apply_root(motion,motion_assets,app,state,animation.motion,content,actor,dt,sought>=0 || distance!=nil && distance.seek || action_distance!=nil && action_distance.seek,clock,mm.saturate(animation.weight)) {
                if instance:=motion_instance(motion,e);instance!=nil {motion_problem(problems,e,instance.error,app,motion_assets,animation.motion)}
            }
            // The warp of the clock of an action that moves the body moves the body as much.
            if leading:=action_root_slot(actions,e);leading!=nil && leading.body!=.None {state.body_motion.translation+=state.motion.translation-unwarped}
        }
        if programmed && state.program.kind==MATCH_KIND {match_lag_apply(state,placed)}
        copy(state.sampled[:],state.local[:])
        if distance_error!=.None {state.program.error=.Invalid_Parameter;distance_problem(problems,e,distance_error)}
        state.seen=playback.frame
    }
    if actions!=nil {actions_finish(actions,playback,tick_dt)}
}


finite :: proc "contextless" (value:f32) -> bool {return abs(value)<=max(f32)}

// Reports why the program of an Animation (its asset, graph or blend space) did not play.
@(private)
program_problem :: proc(problems:^core.Problems,e:core.Entity,app:^host.App,animation:Animation,error:Program_Error) {
    name:[base.ASSET_ID_TEXT]u8
    path:=host.assets_name(app.assets if app!=nil else nil,animation.asset,&name)
    switch error {
    case .None,.Out_Of_Memory: memory_problem(problems,e,"its animation program")
    case .Invalid_Asset: core.report(problems,e,"animation.program_asset","Animation.asset %s, its library or a blend space, graph or clip source it names cannot be read or is of another kind, or they name more than %d animations; check them with animation.asset.inspect, and import or save them again",path,ANIMATION_SOURCES)
    case .Invalid_Parameter: core.report(problems,e,"animation.program_parameter","a parameter of %s is outside its range or not finite, or a speed, sync or transition of it cannot advance; set its parameters within their min and max with animation_parameter, and check its speeds and transitions",path)
    case .Unknown_Parameter: core.report(problems,e,"animation.program_parameter","the Animation has no value for a parameter or axis that %s needs; set it with animation_parameter",path)
    case .Missing_Clip: core.report(problems,e,"animation.program_clip","%s plays a clip its animation library does not have; add the clip, or set Animation.library to an .anim that has it",path)
    case .Incompatible_Root: core.report(problems,e,"animation.program_root","%s blends clips whose root motion has different bones or channels; give them the same root motion, or blend clips without it",path)
    case .Unbound_Mask: core.report(problems,e,"animation.program_mask","a mask or layer of %s names a bone, or a part or region of the body, that this rig does not have; name bones of its skeleton (animation.asset.inspect lists them), or give the skeleton a body with skeleton.body.detect",path)
    case .Unsupported_Mirror: core.report(problems,e,"animation.mirror","%s mirrors a pose, and this rig has no skeleton whose bones say their side to swap; mirror only skeletal rigs with sided bone names",path)
    case .Capacity: core.report(problems,e,"animation.program_capacity","%s plays more clips at once than fit (%d); blend fewer clips at a time",path,PROGRAM_PLAYERS)
    case .Pending: // its sources still load: it plays once they are ready
    case .Additive_Space: core.report(problems,e,"animation.additive_space","Animation.asset %s is a .blend, an aim offset or additive space that plays only under an Additive node of an .agraph; set asset to that .agraph, and play locomotion with a .match",path)
    }
}

@(private)
distance_problem :: proc(problems:^core.Problems,e:core.Entity,error:Distance_Error) {
    cause:string
    switch error {
    case .None: return
    case .Missing_Player: cause="names another entity than the one it plays on"
    case .Missing_Clip: cause="names a clip the animation does not have"
    case .Inactive_Clip: cause="names a clip that is not playing"
    case .Backwards: cause="asks for a time before the one the clip is at; seek instead"
    case .Unsupported_Clock: cause="needs the clip to advance forward and it is stopped, ended or played backwards; seek instead"
    case .Invalid_Time: cause="asks for a time outside the clip"
    }
    core.report(problems,e,"animation.distance","a distance-matched request for this entity was refused: it %s",cause)
}

// Reports markers crossed in a tick that did not reach Animation_Events.
@(private)
markers_lost :: proc(problems:^core.Problems,e:core.Entity,count:int,cause:string) {
    if count>0 {core.report(problems,e,"animation.markers_lost","%d markers this entity crossed in a tick were lost: %s",count,cause)}
}

@(private)
animation_valid :: proc "contextless" (animation:Animation) -> bool {
    if !finite(animation.speed) || !finite(animation.weight) || !finite(animation.fade) {return false}
    if u8(animation.event_policy)>u8(Event_Policy.Always) || !finite(animation.event_threshold) || animation.event_threshold<0 || animation.event_threshold>1 {return false}
    for layer in animation.layers {if !finite(layer.weight) || !finite(layer.speed) || !finite(layer.fade) || !finite(layer.reference) || layer.reference<0 || u8(layer.mode)>u8(Layer_Mode.Additive) || u8(layer.curves)>u8(Curve_Blend.Ignore) {return false}}
    for parameter in animation.parameters {if !finite(parameter) {return false}}
    for name,i in animation.parameter_names {if name!=0 {for j in 0..<i {if animation.parameter_names[j]==name {return false}}}}
    return true
}

// The rigs of the world, found again when its meshes or skins change. A mesh
// with a Pose_Source shares the pose of its rig when both have one skeleton,
// and is a rig that follows it when they have two.
@(private)
rigs_update :: proc(playback:^Playback,meshes:core.Read(erender.Mesh_Renderer),skins:core.Read(Pose_Source),app:^host.App) -> bool {
    if meshes.table==nil {if len(playback.rigs)>0 {clear(&playback.rigs);clear(&playback.follow_order);playback.rigs_stamp+=1};playback.rigs_inputs={};return true}
    inputs:=[5]u64{core.layout(meshes),core.version(meshes),core.layout(skins) if skins.table!=nil else 0,core.version(skins) if skins.table!=nil else 0,assets_stamp(app)}
    if inputs==playback.rigs_inputs {return true}
    skeleton_of :: proc(meshes:core.Read(erender.Mesh_Renderer),app:^host.App,e:core.Entity) -> base.Asset_Id {
        static,has:=core.get(meshes,e)
        if !has || static.mesh=={} {return {}}
        mesh:=host.assets_mesh(app.assets,static.mesh)
        return mesh.skeleton if mesh!=nil && !mesh.failed else {}
    }
    rig_of :: proc(meshes:core.Read(erender.Mesh_Renderer),skins:core.Read(Pose_Source),app:^host.App,row:int) -> (rig:Rig,ok:bool) {
        e:=core.entity_at(meshes,row)
        skeleton:=skeleton_of(meshes,app,e)
        if skeleton=={} {return}
        rig={entity=e,skeleton=skeleton}
        if skins.table!=nil {
            if source,has:=core.get(skins,e);has {
                leader:=skeleton_of(meshes,app,source.rig)
                if leader=={} || leader==skeleton || source.rig==e {return}
                rig.leader=source.rig
            }
        }
        return rig,true
    }
    changed:=false;count:=0
    for row in 0..<core.count(meshes) {
        rig,ok:=rig_of(meshes,skins,app,row)
        if !ok {continue}
        count+=1
        known:=rig_find(playback,rig.entity)
        changed ||= known<0 || playback.rigs[known]!=rig
    }
    if changed || count!=len(playback.rigs) {
        next,error:=make([dynamic]Rig,0,count)
        if error!=nil {return false}
        for row in 0..<core.count(meshes) {
            if rig,ok:=rig_of(meshes,skins,app,row);ok {append(&next,rig)}
        }
        slice.sort_by(next[:],proc(a,b:Rig) -> bool {return a.entity<b.entity})
        delete(playback.rigs);playback.rigs=next;playback.rigs_stamp+=1
        if !follow_order_update(playback) {return false}
    }
    playback.rigs_inputs=inputs
    return true
}

// The rigs that follow another, by how many leaders are above them, so that
// animation_finish takes each after its leader in one pass; those of a loop go
// last. It runs when the rigs change, not in every tick.
@(private)
follow_order_update :: proc(playback:^Playback) -> bool {
    clear(&playback.follow_order)
    for rig in playback.rigs {
        if rig.leader==core.NONE {continue}
        depth:=u32(1)
        at:=rig.leader
        for {
            found:=rig_find(playback,at)
            if found<0 || playback.rigs[found].leader==core.NONE {break}
            if int(depth)>len(playback.rigs) {depth=max(u32);break}
            depth+=1;at=playback.rigs[found].leader
        }
        if append(&playback.follow_order,Rig_Follow{rig.entity,depth})!=1 {return false}
    }
    slice.sort_by(playback.follow_order[:],proc(a,b:Rig_Follow) -> bool {return a.depth<b.depth || a.depth==b.depth && a.entity<b.entity})
    return true
}

@(private)
rig_find :: proc "contextless" (playback:^Playback,e:core.Entity) -> int {
    first,end:=0,len(playback.rigs)
    for first<end {
        middle:=first+(end-first)/2
        if playback.rigs[middle].entity<e {first=middle+1} else {end=middle}
    }
    if first<len(playback.rigs) && playback.rigs[first].entity==e {return first}
    return -1
}

@(private)
state_get :: proc(playback:^Playback,e:core.Entity) -> ^Playing {
    i:=core.entity_index(e)
    if i<len(playback.rows) && playback.rows[i]!=0 {
        row:=int(playback.rows[i])-1
        if row>=0 && row<len(playback.states) {
            state:=&playback.states[row]
            if state.entity==e {return state}
        }
    }
    if i>=len(playback.rows) && resize(&playback.rows,i+1)!=nil {return nil}
    if append(&playback.states,Playing{entity=e,clip=-1})!=1 {return nil}
    playback.rows[i]=i32(len(playback.states))
    return &playback.states[len(playback.states)-1]
}

@(private)
advance :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,dt:f32,problems:^core.Problems,seek:f32=-1,current_dt:f32=-1) {
    animation:=animation
    library:=&content.lib
    index:=0
    if name:=base.text_get(animation.clip[:]);name!="" {
        index=int(lib.clip_find(library,base.name_hash(name)))-1
        if index<0 || index>=content.clip_count {core.report(problems,state.entity,"animation.clip","Animation.clip is '%s', which its animation does not have, so nothing plays; name one of its clips (animation.asset.inspect lists them), or leave it empty for the first",name)}
    }
    if index<0 || index>=content.clip_count {
        state.fader,state.clip={},-1
        state.time,state.duration,state.ended=0,0,false
        return
    }
    handle:=lib.Clip(index+1+(animation.loop?content.clip_count:0))
    current:=&state.fader.current
    started:=false
    if index!=state.clip {
        lib.fader_play(&state.fader,handle,animation.speed,state.clip<0?0:animation.fade)
        if seek>=0 {current.time=seek}
        state.clip=index
        started=true
        state.ended=false
    } else {
        if current.clip!=handle {current.clip,current.done=handle,false}
        rising:=animation.playing && !state.was_playing
        if seek>=0 || rising && current.done {
            current.time,current.fresh,current.done=max(seek,0),true,false
            started=true
            state.ended=false
        }
    }
    state.was_playing=animation.playing
    current.speed=animation.speed
    if current.done && ((current.time<=0 && current.speed>0) || (current.time>=lib.clip_duration(library,current.clip) && current.speed<0)) {current.done=false;state.ended=false}
    // Played backwards once from time 0, a clip starts at its end.
    if started && current.speed<0 && !animation.loop && current.time==0 {lib.player_restart(library,current)}
    state.prev_fader=state.fader
    if animation.playing {
        batch:[EVENT_BATCH]lib.Event
        written,dropped:=lib.fader_advance(library,&state.fader,dt,batch[:],current_dt)
        fader_emit(playback,events,state.entity,content,batch[:written],dropped,state.fader,mm.saturate(animation.weight),0,animation,problems)
        state.ended=!animation.loop && current.done
    }
    state.time=lib.player_time(library,current^)
    state.duration=lib.clip_duration(library,current.clip)
}

// Where the clip of the Animation of an entity is: its time and duration in
// seconds, and whether a clip that does not loop reached its end. False for
// an entity that plays no clip.
animation_progress :: proc(playback:^Playback,entity:core.Entity) -> (time,duration:f32,ended,ok:bool) {
    if playback==nil {return}
    state:=constraint_playing(playback,entity)
    if state==nil || state.clip<0 {return}
    return state.time,state.duration,state.ended,true
}

// The layers follow what the component asks: a new clip cross-fades in, the
// weight moves to the one asked over fade, and a layer without clip fades out.
@(private)
layers_advance :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,dt:f32,problems:^core.Problems) {
    library:=&content.lib
    for &layer,i in state.layers {
        asked:=animation.layers[i]
        index:=int(lib.clip_find(library,asked.clip))-1 if asked.clip!=0 else -1
        known:=index>=0 && index<content.clip_count
        if asked.clip!=0 && !known {core.report(problems,state.entity,"animation.layer_clip","layer %d of the Animation of this entity plays a clip its animation does not have, so it plays nothing; give animation_play the name of one of its clips",i+1)}
        handle:=lib.Clip(index+1+(asked.loop?content.clip_count:0)) if known else 0
        if known && asked.clip!=layer.clip && (layer.clip!=0 || asked.weight>0) {
            lib.fader_play(&layer.fader,handle,asked.speed,asked.fade if layer.clip!=0 else 0)
            layer.clip=asked.clip
        }
        if layer.clip==0 || !animation.playing {continue}
        target:f32=0
        if known && asked.clip==layer.clip {
            target=mm.saturate(asked.weight)
            if layer.fader.current.clip!=handle {layer.fader.current.clip,layer.fader.current.done=handle,false}
            layer.fader.current.speed=asked.speed
        }
        step:=dt/asked.fade if asked.fade>0 else 1
        layer.weight=target if abs(target-layer.weight)<=step else layer.weight+(step if target>layer.weight else -step)
        if layer.weight<=0 && target<=0 {layer={};continue}
        batch:[EVENT_BATCH]lib.Event
        written,dropped:=lib.fader_advance(library,&layer.fader,dt,batch[:])
        if !asked.sync {fader_emit(playback,events,state.entity,content,batch[:written],dropped,layer.fader,layer.weight*mm.saturate(animation.weight),u16(i+1),animation,problems);continue}
        if phase,ok:=lib.sync_phase(library,state.fader.current);ok && state.clip>=0 {lib.player_synchronize(library,&layer.fader.current,phase)}
    }
}

// The lock of a clip that carries root motion, with clips_in_place: its root bone blends its rest,
// or the entity's transform for a root bound to it, so a clip fading out does not take it along.
@(private)
clip_root_lock :: proc(state:^Playing,content:^host.Content_Animation,clip:lib.Clip,transforms:core.Read(core.Transform)) -> (lock:lib.Pose_Lock) {
    if !state.clips_in_place || content==nil || content.clip_count<=0 || int(clip)<1 {return}
    index:=(int(clip)-1)%content.clip_count
    if index>=len(content.roots) || !(content.roots[index].translation || content.roots[index].rotation) {return}
    meta:=content.roots[index]
    bone:=bone_resolve(state,{meta.bone})
    if bone<0 || bone>=len(state.rest) || bone>=len(state.bindings) {return}
    pinned:=state.rest[bone]
    if bone==0 && state.parents[bone]<0 && state.bindings[bone].entity==state.entity {
        if current,exists:=core.get(transforms,state.entity);exists {pinned=core.to_math(current)}
    }
    return {target=state.bindings[bone].target,position=meta.translation,rotation=meta.rotation,value=pinned}
}

@(private)
pose_sample :: proc(playback:^Playback,state:^Playing,library:^lib.Library,animation:Animation,transforms:core.Read(core.Transform),problems:^core.Problems,content:^host.Content_Animation=nil) {
    if len(state.bindings)==0 {return}
    pose:=&playback.pose
    if state.clip>=0 {
        lib.pose_clear(pose)
        lib.pose_blend(pose,library,state.fader.current,lib.fader_current_weight(state.fader),clip_root_lock(state,content,state.fader.current.clip,transforms))
        for o in state.fader.outgoing[:state.fader.outgoing_count] {lib.pose_blend(pose,library,o.player,lib.fade_out_weight(o),clip_root_lock(state,content,o.player.clip,transforms))}
        share:=mm.saturate(animation.weight)
        for &binding,i in state.bindings {
            out:=state.local[i]
            if binding.entity!=core.NONE {
                row,ok:=core.get(transforms,binding.entity)
                if !ok {continue}
                out=core.to_math(row)
            }
            rest:=binding.rest
            if .Position in binding.driven {
                value,w,ok:=lib.pose_position(pose,binding.target)
                alpha:=mm.saturate(w)*share
                out.position=rest.position if !ok || alpha==0 else value if alpha==1 else rest.position+(value-rest.position)*alpha
            }
            if .Rotation in binding.driven {
                value,w,ok:=lib.pose_rotation(pose,binding.target)
                alpha:=mm.saturate(w)*share
                out.rotation=rest.rotation if !ok || alpha==0 else value if alpha==1 else mm.quat_slerp(rest.rotation,value,alpha)
            }
            if .Scale in binding.driven {
                value,w,ok:=lib.pose_scale(pose,binding.target)
                alpha:=mm.saturate(w)*share
                out.scale=rest.scale if !ok || alpha==0 else value if alpha==1 else rest.scale+(value-rest.scale)*alpha
            }
            state.local[i]=out
        }
    }
    pose_layers(playback,state,library,animation,problems,transforms)
}

@(private)
pose_layer_transform :: proc(pose:^lib.Pose,target:u64,out:mm.Transform,share:f32,additive:bool,root:^Root_Motion=nil,reference:mm.Transform=mm.TRANSFORM_IDENTITY) -> mm.Transform {
    out:=out
    if share<=0 {return out}
    if value,w,ok:=lib.pose_position(pose,target);ok {if root!=nil && root.in_place && root.translation {value=reference.position};if additive {out.position+=value*share} else {out.position+=(value-out.position)*(mm.saturate(w)*share)}}
    if value,w,ok:=lib.pose_rotation(pose,target);ok {if root!=nil && root.in_place && root.rotation {value=reference.rotation};if additive {out.rotation*=mm.quat_slerp(1,value,share)} else {out.rotation=mm.quat_slerp(out.rotation,value,mm.saturate(w)*share)}}
    if value,w,ok:=lib.pose_scale(pose,target);ok {if additive {out.scale+=value*share} else {out.scale+=(value-out.scale)*(mm.saturate(w)*share)}}
    return out
}

// The rotation of bone b after an Override layer blended in the space of the rig, written to its
// local pose: rotations holds by binding that of the base, of the layer and of the blend in that
// space (the bone under none is its origin). A bone the layer leaves out follows its parent as in
// the base. False when its parent comes after it.
@(private)
pose_layer_mesh_rotation :: proc(rotations:[]mm.Quat,state:^Playing,pose:^lib.Pose,target:u64,b:int,share:f32) -> bool {
    n:=len(state.bindings)
    base,layered,blended:=rotations[:n],rotations[n:2*n],rotations[2*n:3*n]
    parent:=int(state.parents[b])
    if parent<0 {base[b],layered[b],blended[b]=1,1,1;return true}
    if parent>=b {return false}
    own:=state.local[b].rotation;theirs:=own
    if value,w,ok:=lib.pose_rotation(pose,target);ok {theirs=mm.quat_slerp(own,value,mm.saturate(w))}
    base[b]=base[parent]*own;layered[b]=layered[parent]*theirs
    if share<=0 {blended[b]=blended[parent]*own;return true}
    blended[b]=mm.quat_slerp(base[b],layered[b],mm.saturate(share))
    state.local[b].rotation=linalg.normalize0(mm.quat_inverse(blended[parent])*blended[b])
    return true
}

@(private)
pose_layers :: proc(playback:^Playback,state:^Playing,library:^lib.Library,animation:Animation,problems:^core.Problems,transforms:core.Read(core.Transform)={}) {
    pose:=&playback.pose
    root_bone:=-1;reference:=mm.TRANSFORM_IDENTITY;retired:=mm.TRANSFORM_IDENTITY
    for root,i in state.action_roots {if state.action_root_mask&(u8(1)<<u8(i))==0 {continue};root_bone=bone_resolve(state,root.bone);if root_bone>=0 {state.action_in_place_root=root;break}}
    if root_bone>=0 {
        reference=state.rest[root_bone];retired=state.local[root_bone]
        if state.parents[root_bone]<0 && state.bindings[root_bone].entity==state.entity && transforms.table!=nil {if current,present:=core.get(transforms,state.entity);present {reference=core.to_math(current)}}
        if state.has_base_root && state.base_root.in_place && bone_resolve(state,state.base_root.bone)==root_bone {if state.base_root.translation {retired.position=reference.position};if state.base_root.rotation {retired.rotation=reference.rotation}}
    }
    // A layer moves only what its clip animates, inside its branch.
    for &layer,i in state.layers {
        if layer.clip==0 || layer.weight<=0 {continue}
        mask:[]f32
        if over:=animation.layers[i].over;over!=0 {
            selection,found:=bone_select(state,over)
            if !found {
                core.report(problems,state.entity,"animation.layer_bone","layer %d of the Animation of this entity plays over a bone, or a part or region of the body, that this rig does not have, so it plays nothing; give animation_play in over one of its bones, a part or region of its body (@upper_body), or none",i+1)
                continue
            }
            if resize(&playback.mask,len(state.bindings))!=nil {memory_problem(problems,state.entity,"the mask of a layer");continue}
            for &weight,b in playback.mask {weight=1 if bone_selected(state,selection,b) else 0}
            mask=playback.mask[:]
        }
        lib.pose_clear(pose)
        additive:=animation.layers[i].mode==.Additive
        if additive {
            from:lib.Clip
            if name:=animation.layers[i].reference_clip;name!=0 {
                from=lib.clip_find(library,name)
                if from==0 {
                    core.report(problems,state.entity,"animation.layer_reference","layer %d of the Animation of this entity adds its clip over a reference clip its animation does not have, so it plays nothing; give animation_play in reference_clip the name of one of its clips, or none to subtract its own clip",i+1)
                    continue
                }
            }
            player:=layer.fader.current;player.weight=lib.fader_current_weight(layer.fader)
            lib.pose_blend_additive(pose,library,player,animation.layers[i].reference,1,from)
            for outgoing in layer.fader.outgoing[:layer.fader.outgoing_count] {
                player=outgoing.player;player.weight=lib.fade_out_weight(outgoing)
                lib.pose_blend_additive(pose,library,player,animation.layers[i].reference,1,from)
            }
        } else {lib.fader_blend(pose,library,layer.fader)}
        n:=len(state.bindings)
        mesh:=!additive && animation.layers[i].mesh_space && len(state.parents)==n
        if mesh && len(playback.rig_rotations)<3*n && resize(&playback.rig_rotations,3*n)!=nil {memory_problem(problems,state.entity,"the rotations of a layer in the space of the rig");mesh=false}
        for binding,b in state.bindings {
            share:=layer.weight*mm.saturate(animation.weight)*(mask[b] if mask!=nil else 1)
            if mesh && !pose_layer_mesh_rotation(playback.rig_rotations[:3*n],state,pose,binding.target,b,share) {continue}
            if share<=0 {continue}
            turned:=state.local[b].rotation
            state.local[b]=pose_layer_transform(pose,binding.target,state.local[b],share,additive)
            if mesh && state.parents[b]>=0 {state.local[b].rotation=turned}
            if b==root_bone {root:^Root_Motion;if state.action_root_mask&(u8(1)<<u8(i))!=0 {root=&state.action_roots[i]};retired=pose_layer_transform(pose,binding.target,retired,share,additive,root,reference)}
        }
    }
    if root_bone>=0 {state.action_in_place_local=retired;state.has_action_in_place=true}
}

pose_write :: proc(playback:^Playback,state:^Playing,transforms:^core.Table(core.Transform)) {
    for binding,i in state.bindings {
        if binding.entity==core.NONE {continue}
        old,ok:=core.get(core.read(transforms),binding.entity)
        if !ok || state.local[i]==core.to_math(old) {continue}
        row:=core.free(transforms,binding.entity)
        if row==nil {playback.stats.skipped+=1;continue}
        row^=core.from_math(state.local[i])
    }
}

emit_events :: proc(playback:^Playback,events:^Animation_Events,entity:core.Entity,content:^host.Content_Animation,batch:[]lib.Event,dropped:int,problems:^core.Problems,weight:f32=1,source:u32=0,group:u16=0,animation:Animation=ANIMATION_DEFAULT) {
    if weight<=0 || animation.event_policy==.Weighted && weight<animation.event_threshold {return}
    needed:=max(len(playback.states)*EVENT_BATCH,EVENT_BATCH)
    if cap(events.items)<needed {if reserve(&events.items,needed)!=nil {markers_lost(problems,entity,len(batch)+dropped,"out of memory for Animation_Events; free memory");return}}
    for event in batch {
        if int(event.id)>=len(content.markers) {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,entity,"animation.marker_name","a marker of a clip of animation %s has no name in the asset, which is damaged; import it again",base.asset_id_format(content.id,name[:]))
            continue
        }
        if len(events.items)>=cap(events.items) {markers_lost(problems,entity,1,"the markers of the world in this tick passed the room of Animation_Events; space the markers of the clips");continue}
        append(&events.items,Animation_Marker{entity=entity,clip=lib.clip_data(&content.lib,event.clip).name,marker=content.markers[event.id],time=event.time,fraction=event.fraction,weight=weight,source=source,group=group,animation=content.id})
    }
    markers_lost(problems,entity,dropped,MARKERS_PAST_BATCH)
}

// Why markers past EVENT_BATCH in one clip and tick are lost.
@(private)
MARKERS_PAST_BATCH :: "a clip gives at most 16 markers in one tick (EVENT_BATCH); space its markers, or play it slower"

@(private)
targeted :: proc "contextless" (library:^lib.Library,target:u64) -> (driven:Property_Set) {
    for track in library.tracks[:library.track_count] {
        if track.target==target {driven+={track.property}}
    }
    return driven&{.Position,.Rotation,.Scale}
}

@(private)
binding_add :: proc(playback:^Playback,state:^Playing,old:[]Binding,transforms:^core.Table(core.Transform),e:core.Entity,target:u64,driven:Property_Set,problems:^core.Problems) -> bool {
    row,ok:=core.get(core.read(transforms),e)
    if !ok {
        core.report(problems,state.entity,"animation.bind_transform","entity 0x%016x below this animated entity has no Transform, so the tracks of its name move nothing; give it one",u64(e))
        return true
    }
    binding:=Binding{target=target,entity=e,driven=driven,rest=core.to_math(row),parent=-1}
    for known in old {
        if known.entity!=e || known.target!=target {continue}
        binding.rest=known.rest
        break
    }
    return append(&state.bindings,binding)==1
}

// Finds what the tracks of the asset move below the entity: the entity itself
// for the tracks without target, and whatever has the name of a track. What
// was bound keeps its rest transform. Entities with an Animation of their own
// and rigs are left to it.
@(private)
bind :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,hierarchy:core.Ref(core.Hierarchy),transforms:^core.Table(core.Transform),names:core.Read(core.Name),targets:core.Read(Animation_Target),animations:core.Read(Animation),problems:^core.Problems) -> bool {
    next:Playing
    defer playing_free(&next)
    old:=state.bindings[:]
    library:=&content.lib
    root:=state.entity
    root_target,explicit_root:=core.get(targets,root)
    root_hash:=base.name_hash(base.text_get(root_target.path[:])) if explicit_root else 0
    if !binding_add(playback,&next,old,transforms,root,root_hash,targeted(library,root_hash),problems) {return false}
    for e:=core.subtree_next(hierarchy,root,root);e!=core.NONE; {
        if core.has(animations,e) || rig_find(playback,e)>=0 {
            e=core.subtree_next(hierarchy,root,e,false)
            continue
        }
        target,explicit:=core.get(targets,e)
        hash:=base.name_hash(base.text_get(target.path[:])) if explicit else base.name_hash(core.name_get(names,e))
        if !binding_add(playback,&next,old,transforms,e,hash,targeted(library,hash),problems) {return false}
        e=core.subtree_next(hierarchy,root,e)
    }
    count:=len(next.bindings)
    if resize(&next.parents,count)!=nil || resize(&next.targets,count)!=nil || resize(&next.rest,count)!=nil || resize(&next.local,count)!=nil || resize(&next.world,count)!=nil || resize(&next.sampled,count)!=nil || resize(&next.previous,count)!=nil {return false}
    for &binding,i in next.bindings {
        if parent:=core.parent_of(hierarchy,binding.entity);parent!=core.NONE && i>0 {
            for other,j in next.bindings[:i] {if other.entity==parent {binding.parent=i32(j);break}}
        }
        next.parents[i],next.targets[i],next.rest[i]=binding.parent,binding.target,binding.rest
        next.local[i]=binding.rest
        next.previous[i]=binding.rest
    }
    delete(state.bindings);delete(state.parents);delete(state.targets);delete(state.aliases);state.aliases=nil
    delete(state.mirror_pairs);delete(state.mirror_corrections);delete(state.mirror_scratch);state.mirror_pairs,state.mirror_corrections,state.mirror_scratch=nil,nil,nil
    delete(state.regions);state.regions=nil;state.body={}
    delete(state.rest);delete(state.local);delete(state.world);delete(state.sampled);delete(state.previous)
    state.bindings,state.parents,state.targets=next.bindings,next.parents,next.targets
    state.rest,state.local,state.world,state.sampled,state.previous=next.rest,next.local,next.world,next.sampled,next.previous
    next.bindings,next.parents,next.targets=nil,nil,nil
    next.rest,next.local,next.world,next.sampled,next.previous=nil,nil,nil,nil,nil
    playback.binding_revision+=1;state.bound=playback.binding_revision;state.pose_ready=false
    return true
}

// Asks for the entity to be at a time of its clip in the next tick, without firing the markers it skips.
animation_seek :: proc(requests:^Animation_Requests,entity:core.Entity,time:f32) {
    if requests==nil {return}
    if !finite(time) {core.refuse(&requests.seeks);return}
    core.offer(&requests.seeks,Animation_Seek{entity,time})
}

@(storage,setting)
Animation_Settings :: struct {
    requests:u32 `mirai:"advanced"`,    // of each kind a tick can ask for: seeks, poses, plays, goals, actions and targets; past it they are dropped and reported
    match_goals:u32 `mirai:"advanced"`, // rigs whose motion matching a tick is told of; as many
}
ANIMATION_SETTINGS_DEFAULT :: Animation_Settings{requests=256,match_goals=4096}

// The room of the requests of a tick, and what did not fit or was invalid in them.
@(step="input fixed",loops="game editor",stage="begin")
animation_requests_serve :: proc(requests:^Animation_Requests,actions:^Action_Requests,motion:^Motion_Requests,modifiers:^Modifier_Requests,paths:^Keyframe_Path_Requests,settings:Animation_Settings,problems:^core.Problems) {
    code,capacity,setting:="animation.requests",int(settings.requests),"Animation_Settings.requests"
    core.queue_serve(&requests.seeks,capacity,problems,code,"animation seeks",setting,"a seek asks for a finite time")
    core.queue_serve(&requests.distances,capacity,problems,code,"animation distance plays",setting,"it names an entity, a clip and a time of 0 or more, or a distance track of its motion profile")
    core.queue_serve(&requests.poses,capacity,problems,code,"bone poses",setting,"it names a rig and a bone, with a finite pose, a unit rotation and a weight from 0 to 1")
    core.queue_serve(&requests.final_poses,capacity,problems,code,"final bone poses",setting,"it names a rig and a bone, with a finite pose, a unit rotation and a weight from 0 to 1")
    core.queue_serve(&requests.match_goals,int(settings.match_goals),problems,code,"motion matching goals","Animation_Settings.match_goals","it names a rig and a mode up to 31, with finite values and rates of 0 or more")
    core.queue_serve(&requests.match_plays,capacity,problems,code,"motion matching plays",setting,"it names a rig, a clip of under 64 bytes, a mode up to 31, a finite fade and a phase from 0 to 1")
    core.queue_serve(&actions.queue,capacity,problems,code,"action requests",setting,"it names an entity and an action of under 64 bytes, and a section for a section change")
    core.queue_serve(&motion.targets,capacity,problems,code,"motion warp targets",setting,"it names a rig, a target of under 32 bytes and a valid spatial target")
    core.queue_serve(&motion.locomotion,capacity,problems,code,"motion locomotion inputs",setting,"it names a rig, with finite velocities and a weight from 0 to 1")
    core.queue_serve(&modifiers.queue,capacity,problems,code,"pose goals",setting,"it names a rig and a slot of its kind, with finite values and a weight from 0 to 1")
    core.queue_serve(&modifiers.controls,capacity,problems,code,"pose controls",setting,"it names a rig and a slot of its kind, with a weight from 0 to 1 and a fade of 0 or more")
    core.queue_serve(&paths.queue,capacity,problems,code,"keyframe path commands",setting,"it names an entity and a finite value")
}

// Plays a clip of the asset of the component. Layer 0 is the clip of the
// component: it cross-fades into the new one from its start. Layers 1 to
// ANIMATION_LAYERS play over it with their weight, over the branch of the
// bone named by over (the whole pose when empty); with sync, the phase of the
// layer follows the clip of the component; with mesh_space, an Override layer
// blends its rotations in the space of the rig. An Additive layer adds what its
// clip changes from the pose of reference_clip at reference seconds (empty: of
// its own clip), as an emote over a stand: pose += weight*(clip - stand at 0).
// fade below zero keeps the fade of the component. False, with nothing changed,
// for a layer that does not exist, a name that does not fit, or numbers that
// are not finite.
animation_play :: proc(animation:^Animation,clip:string,fade:f32=-1,loop:Maybe(bool)=nil,layer:=0,over:="",sync:=false,weight:f32=1,speed:f32=1,mode:Layer_Mode=.Override,reference:f32=0,curves:Curve_Blend=.Override,mesh_space:=false,reference_clip:="") -> bool {
    if animation==nil || layer<0 || layer>ANIMATION_LAYERS || !finite(fade) || !finite(weight) || !finite(speed) || !finite(reference) || reference<0 || mode>max(Layer_Mode) || curves>max(Curve_Blend) || len(clip)>=CLIP_CAPACITY || len(reference_clip)>=CLIP_CAPACITY {return false}
    if layer==0 {
        base.text_set(animation.clip[:],clip)
        animation.playing,animation.speed=true,speed
        if fade>=0 {animation.fade=fade}
        if value,given:=loop.?;given {animation.loop=value}
        return true
    }
    if clip=="" {return false}
    animation.layers[layer-1]={
        clip=base.name_hash(clip),over=base.name_hash(over) if over!="" else 0,
        weight=mm.saturate(weight),speed=speed,fade=max(fade if fade>=0 else animation.fade,0),loop=loop.? or_else true,sync=sync,mode=mode,reference=reference,reference_clip=base.name_hash(reference_clip) if reference_clip!="" else 0,curves=curves,mesh_space=mesh_space,
    }
    return true
}

// The weight of a layer, reached over its fade; layer 0 is the weight of the component. A layer at
// weight 0 keeps its clip, to come back to with a higher weight, so it stays taken for actions;
// animation_stop frees it.
animation_weight :: proc(animation:^Animation,layer:int,weight:f32) -> bool {
    if animation==nil || layer<0 || layer>ANIMATION_LAYERS || !finite(weight) {return false}
    if layer==0 {animation.weight=mm.saturate(weight)} else {animation.layers[layer-1].weight=mm.saturate(weight)}
    return true
}

// Fades a layer out over fade seconds (below zero: its own fade) and frees it at once for an action,
// which cross-fades from what is fading; layer 0 stops the clip of the component where it is.
animation_stop :: proc(animation:^Animation,layer:int,fade:f32=-1) -> bool {
    if animation==nil || layer<0 || layer>ANIMATION_LAYERS || !finite(fade) {return false}
    if layer==0 {animation.playing=false;return true}
    slot:=&animation.layers[layer-1]
    slot.clip=0
    if fade>=0 {slot.fade=fade}
    return true
}

playback_free :: proc(playback:^Playback) {
    for &state in playback.states {playing_free(&state)}
    delete(playback.states);delete(playback.rows);delete(playback.rigs);delete(playback.follow_order);delete(playback.mask);delete(playback.rig_rotations);delete(playback.final_rows)
    lib.pose_destroy(&playback.pose)
    playback^={}
}

playing_free :: proc(state:^Playing) {
    program_free(&state.program)
    delete(state.curves);delete(state.bindings);delete(state.parents);delete(state.targets);delete(state.aliases);delete(state.previous)
    delete(state.mirror_pairs);delete(state.mirror_corrections);delete(state.mirror_scratch);delete(state.regions)
    delete(state.rest);delete(state.local);delete(state.world);delete(state.sampled)
    delete(state.follow);delete(state.driven);delete(state.driven_own);delete(state.driven_leader)
    state^={}
}

// Mirrors a pose of the bones of the rig in place; false for a rig without skeleton.
@(private)
playing_mirror :: proc(state:^Playing,pose:[]mm.Transform) -> bool {
    if len(state.mirror_pairs)==0 || len(state.mirror_pairs)!=len(pose) {return false}
    return lib.pose_mirror(state.parents[:],state.mirror_pairs[:],state.mirror_corrections[:],state.mirror_plane,pose,pose,state.mirror_scratch[:])
}
@(private)
root_delta_mirror :: proc "contextless" (plane:lib.Mirror_Plane,delta:Root_Delta) -> Root_Delta {
    return {lib.mirror_vector(plane,delta.translation),lib.mirror_rotation(plane,delta.rotation)}
}

playing_skeleton :: proc(state:^Playing) -> lib.Skeleton {
    return {parents=state.parents[:],names=state.targets[:],rest=state.rest[:]}
}

// The skeleton a rig posed in its last tick; empty without a pose.
pose_skeleton :: proc(playback:^Playback,entity:core.Entity) -> base.Asset_Id {
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    return state.skeleton if state!=nil && state.pose_ready else {}
}

// The pose a rig ended its last tick with in the space of its entity, after its modifiers and
// without the interpolation between ticks. A bone of its skeleton is at its index plus one.
pose_space :: proc(playback:^Playback,entity:core.Entity,allocator:=context.allocator) -> (pose:[]mm.Transform,ok:bool) {
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    if state==nil || !state.pose_ready || len(state.local)==0 {return nil,false}
    buffer,error:=make([]mm.Transform,len(state.local),allocator)
    if error!=nil {return nil,false}
    pose=buffer
    copy(pose,state.local[:])
    pose[0]=mm.TRANSFORM_IDENTITY
    if !lib.pose_world(state.parents[:],pose,pose) {delete(pose,allocator);return nil,false}
    return pose,true
}

animation_finish :: proc(playback:^Playback,inputs:Constraint_Inputs,constraints:^Animation_Constraints,transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),dt:f32,grounding:^Grounding_Runtime,ground_inputs:Grounding_Inputs,rig_runtime:^Modifier_Runtime=nil,motion:^Motion_Runtime=nil,motion_assets:^Motion_Assets=nil,final_poses:[]Pose_Request=nil,paces:core.Read(core.Own_Pace)={},clock:=core.CLOCK_DEFAULT) {
    grounding_prepare(grounding,ground_inputs.configs,ground_inputs.problems)
    finish :: proc(state:^Playing,playback:^Playback,inputs:Constraint_Inputs,constraints:^Animation_Constraints,transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),dt:f32,grounding:^Grounding_Runtime,ground_inputs:Grounding_Inputs,rig_runtime:^Modifier_Runtime,motion:^Motion_Runtime,motion_assets:^Motion_Assets,final_poses:[]Pose_Request,paces:core.Read(core.Own_Pace),clock:core.Clock) {
        if state.skeleton!={} {if root,ok:=core.get(core.read(transforms),state.entity);ok {state.local[0]=core.to_math(root)}}
        constraints_apply(state,playback,inputs,constraints,transforms,parents,dt*core.pace_of(clock,paces,state.entity),grounding,ground_inputs,rig_runtime,motion,motion_assets,final_poses)
        pose_write(playback,state,transforms)
        if !state.pose_ready || !slice.equal(state.local[:],state.previous[:]) {state.changed=playback.frame}
        if !state.pose_ready {copy(state.previous[:],state.local[:])}
        state.pose_ready=true
        state.finished=playback.frame
    }
    for &state in playback.states {
        if state.seen!=playback.frame || state.leader!=core.NONE {continue}
        finish(&state,playback,inputs,constraints,transforms,parents,dt,grounding,ground_inputs,rig_runtime,motion,motion_assets,final_poses,paces,clock)
    }
    // Each follower after the rig it follows, in the order rigs_update found;
    // then those it does not list (a leader set by hand), and those of a loop.
    for follow in playback.follow_order {
        state:=constraint_playing(playback,follow.entity)
        if state==nil || state.seen!=playback.frame || state.leader==core.NONE || state.finished==playback.frame {continue}
        finish(state,playback,inputs,constraints,transforms,parents,dt,grounding,ground_inputs,rig_runtime,motion,motion_assets,final_poses,paces,clock)
    }
    for &state in playback.states {
        if state.seen!=playback.frame || state.leader==core.NONE || state.finished==playback.frame {continue}
        finish(&state,playback,inputs,constraints,transforms,parents,dt,grounding,ground_inputs,rig_runtime,motion,motion_assets,final_poses,paces,clock)
    }
    #reverse for &state,i in playback.states {
        if state.seen==playback.frame {continue}
        index:=core.entity_index(state.entity)
        if playback.rows[index]==i32(i+1) {playback.rows[index]=0}
        playing_free(&state)
        last:=len(playback.states)-1
        if i!=last {
            playback.states[i]=playback.states[last]
            playback.rows[core.entity_index(playback.states[i].entity)]=i32(i+1)
        }
        pop(&playback.states)
    }
}

@(private)
fader_emit :: proc(playback:^Playback,events:^Animation_Events,entity:core.Entity,content:^host.Content_Animation,batch:[]lib.Event,dropped:int,fader:lib.Fader,weight:f32,group:u16,animation:Animation,problems:^core.Problems) {
    fader:=fader
    leading:=fader.current.clip;best:=lib.fader_current_weight(fader)
    for outgoing in fader.outgoing[:fader.outgoing_count] {if share:=lib.fade_out_weight(outgoing);share>best {leading,best=outgoing.player.clip,share}}
    for event in batch {
        if animation.event_policy==.Dominant && event.clip!=leading {continue}
        share:=lib.fader_current_weight(fader) if event.clip==fader.current.clip else f32(0)
        for outgoing in fader.outgoing[:fader.outgoing_count] {if outgoing.player.clip==event.clip {share+=lib.fade_out_weight(outgoing)}}
        emit_events(playback,events,entity,content,([]lib.Event{event}),0,problems,weight*share,u32(event.clip),group,animation)
    }
    markers_lost(problems,entity,dropped,MARKERS_PAST_BATCH)
}
@(private)
animation_motion_clock :: proc(state:^Playing,content:^host.Content_Animation,output:^Program_Output,dt,current_dt:f32) -> (clock:Motion_Clock) {
    if state==nil || content==nil || !state.root_enabled {return}
    if output!=nil {
        for group in output.groups[:output.count] {group:=group;for leaf in group.leaves[:group.count] {
            source:=int(lib.clip_find(&content.lib,leaf.clip))-1
            if source<0 || source>=len(content.roots) || !(content.roots[source].translation || content.roots[source].rotation) {continue}
            share:=leaf.weight*group.root_weight
            if share<=clock.weight || int(leaf.player)>=len(state.program.players) {continue}
            slot:=state.program.players[leaf.player]
            if slot.advanced!=state.program.frame {continue}
            clock={player=slot.player,from=slot.from,to=slot.to,root=state.program.root,weight=share,active=true,mirror=group.mirror}
        }}
        return
    }
    player:=state.fader.current
    if !lib.clip_valid(&content.lib,player.clip) {return}
    from:=state.prev_fader.current.time
    if state.prev_fader.current.clip!=player.clip {from=player.time}
    metadata_for:=proc(content:^host.Content_Animation,clip:lib.Clip) -> (root:Root_Motion) {index:=int(clip)-1;if content.clip_count>0 {index%=content.clip_count};if index>=0 && index<len(content.roots) {metadata:=content.roots[index];root={bone={metadata.bone},translation=metadata.translation,rotation=metadata.rotation}};return}
    clock={player=player,from=from,to=from+current_dt*player.speed,root=metadata_for(content,player.clip),weight=lib.fader_current_weight(state.fader),active=true}
    for outgoing in state.fader.outgoing[:state.fader.outgoing_count] {
        share:=lib.fade_out_weight(outgoing)
        if share<=clock.weight {continue}
        for previous in state.prev_fader.outgoing[:state.prev_fader.outgoing_count] {if previous.player.clip==outgoing.player.clip && previous.elapsed+dt==outgoing.elapsed {
            clock={player=outgoing.player,from=previous.player.time,to=previous.player.time+dt*previous.player.speed,root=metadata_for(content,outgoing.player.clip),weight=share,active=true};break
        }}
    }
    return
}

distance_request_check :: proc(state:^Playing,content:^host.Content_Animation,request:Animation_Distance_Request,actions:^Action_Runtime=nil) -> Distance_Error {
    if state==nil || state.entity!=request.entity {return .Missing_Player}
    if content==nil || request.clip==0 {return .Missing_Clip}
    clip_name:=source_clip_name(content.id,request.animation,request.clip)
    index:=int(lib.clip_find(&content.lib,clip_name))-1
    if index<0 || index>=content.clip_count {return .Missing_Clip}
    duration:=lib.clip_duration(&content.lib,lib.Clip(index+1))
    if !finite(request.time) || request.time<0 || request.time>duration {return .Invalid_Time}
    player:=state.fader.current
    if action,on_action:=action_player(actions,request.entity,request.clip,content,request.animation);on_action {player=action} else if state.program.ready {
        for slot in state.program.players {if slot.seen!=state.program.frame || !lib.clip_valid(&content.lib,slot.player.clip) {continue};if lib.clip_data(&content.lib,slot.player.clip).name==clip_name {player=slot.player;break}}
    }
    if !lib.clip_valid(&content.lib,player.clip) || lib.clip_data(&content.lib,player.clip).name!=clip_name {return .Inactive_Clip}
    if request.seek {return .None}
    if !state.was_playing || player.done || player.speed<=0 {return .Unsupported_Clock}
    if request.time<lib.player_time(&content.lib,player) {return .Backwards}
    return .None
}
