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

EVENT_BATCH :: 16     // markers one clip gives in a tick, and events the world keeps room for by animated entity
CLIP_CAPACITY :: 64

// Plays a clip of an asset. While playing is set the library advances the
// clip every fixed tick and writes the pose; in the editor it plays only
// with preview. Changing clip cross-fades into the new one over fade seconds
// (0: cut); the new clip starts at 0. weight is how much of the pose replaces
// what the subtree had when it was bound. On an entity whose Mesh_Renderer
// shows a mesh with a skeleton the clip poses that skeleton; on another it
// moves the entities below it by name, and any other that names it in its
// Animation_Target, and writes the fields its "@field" tracks name. Those
// entities are written on the ticks its clip moves: one that does not play
// leaves them where they are, for whoever else moves them. A .character
// plays its locomotion, or without one its clip of the animation of the set,
// with its layers and actions over it and its modifiers after it.
@(component,description="Plays a clip of an .anim, or a .character: its motion matching locomotion with the layers and actions of the set over it and its modifiers (IK, look, grounding) after it, and a root motion policy.")
Animation :: struct {
    asset:base.Asset_Id `mirai:"section=Clip,kind=.anim .character"`,
    library:base.Asset_Id `mirai:"kind=.anim"`, // .anim whose clips replace those of a .character, by name
    clip:[CLIP_CAPACITY]u8 `mirai:"text"`, // empty: the first of the asset or of the animation of the set
    speed:f32 `mirai:"section=Playback"`, // negative plays backwards: once, from the end
    loop:bool,
    mirror:bool,                           // left and right bones of a skeleton swap, reflected across the plane between them
    playing:bool,
    preview:bool,                          // plays in the editor too
    weight:f32 `mirai:"min=0,max=1"`,
    fade:f32 `mirai:"min=0,unit=s"`,
    root_motion:Root_Motion_Policy `mirai:"section=Motion"`,
    event_policy:Event_Policy `mirai:"section=Events"`,
    event_threshold:f32 `mirai:"min=0,max=1"`,
}

Root_Motion_Policy :: enum u8 {None,Extract,In_Place}
Event_Policy :: enum u8 {Dominant,Weighted,Always}
Curve_Blend :: enum u8 {Override,Additive,Ignore}

ANIMATION_DEFAULT :: Animation{speed=1,weight=1,loop=true,playing=true,fade=0.2,event_policy=.Weighted,event_threshold=.01}

// What a slot of the stack of an entity is asked to play in a tick: what its layer plays by
// itself, or the clip of the action that plays in it.
Layer_Ask :: struct {
    clip:u64,   // name in the library of the clip; 0: none, and without a space the layer fades out
    over:u64,   // base.name_hash of the path or name of the bone whose branch it moves; 0: the whole pose
    weight:f32, // over what is below it
    speed:f32,
    fade:f32,   // seconds to reach its weight, and of a change of clip
    loop:bool,
    sync:bool,  // its phase follows the clip of the base, by markers when both have them
    mode:Layer_Mode,
    reference:f32,       // Additive: seconds into the reference clip whose pose it adds its clip over
    reference_clip:u64,  // Additive: name in the library of that clip; 0: its own clip
    curves:Curve_Blend,
    mesh_space:bool, // Override: the rotations of its branch blend in the space of the rig
    space:u8,        // instead of clip: 1 + the space of the set its parameters sample
    injected:bool,   // slot 0 over locomotion: the action plays as the clip of the program, not as a layer
}

// What the tracks of a clip call this entity: its path below the entity that plays the clip
// (an imported rigid node), or, with animation, a name for an entity anywhere that the clip
// of that one moves, as the actors of a cinematic.
@(component,description="What the tracks of a clip call this entity, and the animated entity whose clip moves it when it is not below that one.")
Animation_Target :: struct {
    path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text,hidden"`,
    animation:core.Entity, // NONE: the animated entity it is below
}

// Where the clip of the Animation of an entity is while the game plays, and
// what the last command left it doing: what a saved game keeps, since Playback
// is derived and starts again when the World loads. Only animation_sample
// writes it.
@(component,description="Where the clip of the Animation of this entity is while the game plays, and what a command left it doing: a saved game goes on from there.")
Animation_Progress :: struct {
    time:f32 `mirai:"readonly,unit=s"`,
    transport:Timeline_Transport `mirai:"readonly"`,
}

@(storage,queue)
Animation_Requests :: struct {
    timeline:core.Queue(Animation_Command), // timeline.odin
    distances:core.Queue(Animation_Distance_Request),
    poses:core.Queue(Pose_Request),
    final_poses:core.Queue(Pose_Request),
    match_goals:core.Queue(Match_Goal),
    plays:core.Queue(Play_Request),
    values:core.Queue(Value_Request),
    looks:core.Queue(Modifier_Goal),
}

// What the animation of an entity tells in a tick. Marker: a playing Animation crossed a marker of
// a clip, also of one that is fading out. The others are of an action asked for with play:
// Started; Ended, it reached its end; Interrupted, it was stopped, or another took its slot;
// Section, it entered a section; Span_Begin and Span_End, it entered and left a window.
Animation_Event_Kind :: enum u8 {Marker,Started,Ended,Interrupted,Section,Span_Begin,Span_End}
Animation_Event :: struct {
    entity:core.Entity,
    kind:Animation_Event_Kind,
    action:u64, // base.name_hash of the name of the action; 0: a marker of a clip no action plays
    name:u64,   // of the marker or of the span; otherwise of the section the action is in (0: none)
    clip:u64,   // Marker: of the clip
    time:f32,   // where it sits in the clip
    fraction:f32, // Marker: of the tick's advance where it was crossed
    weight:f32,
    source:u32,
    group:u16,
    animation:base.Asset_Id, // Marker: the .anim of the clip
}

@(storage)
Animation_Events :: struct {using queue:core.Events(Animation_Event)}

// Pushes an event within the room the animated entities of the world reserve. False when it did
// not fit, or memory ran out.
@(private)
event_push :: proc(playback:^Playback,events:^Animation_Events,event:Animation_Event) -> bool {
    if playback==nil || events==nil {return false}
    needed:=playback.events_from+max(len(playback.states)*EVENT_BATCH,EVENT_BATCH)
    if cap(events.items)<needed && reserve(&events.items,needed)!=nil || len(events.items)>=needed {return false}
    append(&events.items,event)
    return true
}

Property_Set :: bit_set[lib.Property;u8]

Binding :: struct {
    target:u64,                // of the tracks that move it
    entity:core.Entity,
    driven:Property_Set,       // what some clip of the asset moves of it
    rest:mm.Transform,         // its Transform when it was bound
    parent:i32,
}

SPACE_LEAVES :: 3 // clips a place of a space blends
Space_Leaf :: struct {clip:lib.Clip,weight,speed:f32}
Layer_Playing :: struct {
    fader:lib.Fader,
    clip:u64,   // the one it plays; 0: none
    weight:f32, // on its way to the one asked
    space:u8,                        // 1 + the space of the set it samples instead of a clip
    leaves:[SPACE_LEAVES]Space_Leaf, // the clips of the space at the place its parameters give, by their weight
    leaf_count:u8,
    time:f32,   // of the clock the clips of its space play by
}
Stack_Parameter :: struct {name:u64,value:f32,used:bool} // used: a layer or an axis read it in this tick

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
    held:bool,                 // its clip did not move in the tick: the entities it drives are not written
    held_weight:f32,
    transport:Timeline_Transport, // what a command asked of its clip (timeline.odin)
    component_playing:bool,    // Animation.playing as last seen: a change of it ends the transport
    playing:bool,              // whether its clip plays in this tick
    was_playing:bool,
    previewed:bool,            // played in the editor in the last tick
    layers:[STACK_SLOTS]Layer_Playing,
    asked:[STACK_SLOTS]Layer_Ask,           // what each slot plays in this tick
    stack:u8,                               // slots its .character gives it; 0: none
    parameters:[STACK_PARAMETERS]Stack_Parameter, // what set gave it; name 0: free
    program:Program_Playing,
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
    action_roots:[STACK_SLOTS]Root_Motion,
    action_root_mask:u16,
    action_in_place_root:Root_Motion,
    action_in_place_local:mm.Transform,
    has_action_in_place:bool,
    bindings:[dynamic]Binding,
    tracks:u32,                // in Playback.track_maps + 1: the binding each track of its content moves; 0: bound to no content
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
    leader:core.Entity,        // the rig whose pose it takes (Pose_Source); NONE: none
    stage:Pose_Stage,          // of the pose of its leader it takes
    follow:[dynamic]lib.Follow_Bone,       // by bone: the bone of the leader it takes
    retarget:[dynamic]lib.Retarget_Bone,   // sampled: by bone, how it takes the pose of its bone of the leader
    retarget_rest,retarget_world:[dynamic]mm.Transform, // sampled: the rests of the leader and its own, and room for their poses in the world
    world_final:u64,                       // Playback.frame whose finished pose world holds, in the world, for its followers
    follow_bound:[2]u64,                   // the bound of the leader and its own the follow was paired for
    driven:[dynamic]Curve_Output,          // its curves after those of its leader and the drives of its profile, while driven_ready
    driven_own,driven_leader:[dynamic]i32, // where each of its curves and of its leader's goes in driven
    driven_key:Driven_Key,                 // what driven was laid out for
    driven_ready:bool,
    curve_layout:u64,                      // changes when the curves a lookup reads change place
}

// An entity whose Mesh_Renderer shows a mesh with a skeleton and that does
// not share the finished pose of another of that skeleton through Pose_Source:
// it poses that skeleton. One whose Pose_Source names another rig takes its
// pose: leader is that rig.
Rig :: struct {entity:core.Entity,skeleton:base.Asset_Id,leader:core.Entity,stage:Pose_Stage}
// A rig that follows another, and how many leaders are above it (max: it is in a loop).
Rig_Follow :: struct {entity:core.Entity,depth:u32}

Stats :: struct {
    skipped:u64, // writes left out because another component owns the transform
}

// Playback belongs to the simulated world, including its cross-fades and rest pose.
@(storage,free="playback_free")
Playback :: struct {
    states:[dynamic]Playing,
    events_from:int, // the events the log held when the tick began: the room of a tick is past them
    rows:[dynamic]i32, // by entity index: state+1
    rigs:[dynamic]Rig,
    follow_order:[dynamic]Rig_Follow, // the rigs that follow another, each after the rig it follows
    rigs_stamp:u64,
    rigs_seen:[2]core.Seen, // the meshes and the pose sources the rigs were made from
    rigs_assets:u64,
    hierarchy_seen:[3]core.Seen, // the parents, names and targets the bones of the rigs were bound with
    hierarchy_shapes:[2]core.Shape, // and the rows of the transforms and the animations
    hierarchy_stamp:u64, // moves when any of them does
    track_maps:[dynamic]Track_Map,
    scratch:[dynamic]Pose_Scratch, // one a job that poses
    bones_peak:int,                // bindings of the largest state bound: the room of each scratch
    work:[dynamic]Pose_Row,        // the entities of the tick under way
    work_contents:[dynamic]host.Content_Animation, // what they play, each once: its library outlives the tick, its place in the host may not
    final_rows:[dynamic]i32,
    frame,binding_revision:u64,
    stats:Stats,
}

@(private)
animation_tick :: proc(
    animations:core.Read(Animation),transforms:^core.Table(core.Transform),
    parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),names:core.Read(core.Name),requests:^Animation_Requests,events:^Animation_Events,
    targets:core.Read(Animation_Target),roots:core.Read(Root_Motion),
    playback:^Playback,app:^host.App,time:core.Time,frame:core.Frame_Time,skeleton_assets:^Skeleton_Assets,problems:^core.Problems,characters:^Character_Assets=nil,
    actions:^Action_Runtime=nil,motion:^Motion_Runtime=nil,motion_requests:^Motion_Requests=nil,sources:^Source_Assets=nil,
    paces:core.Read(core.Own_Pace)={},clock:=core.CLOCK_DEFAULT,budget:=ANIMATION_BUDGET_CONFIG_DEFAULT,
) {
    playback.frame+=1
    playback.events_from=len(events.items)
    if app.assets==nil || !finite(time.dt) || time.dt<0 {for &state in playback.states {clear(&state.curves);state.curves_ready=false;state.driven_ready=false;state.motion=ROOT_DELTA_DEFAULT;state.root_enabled=false;state.body_motion={}};return}
    // The editor runs this once a frame with dt 0: a preview advances by the frame.
    tick_dt:=time.dt
    if !time.playing {tick_dt=frame.dt if finite(frame.dt) && frame.dt>0 else 0}
    if core.touched(parents,&playback.hierarchy_seen[0]) | core.touched(names,&playback.hierarchy_seen[1]) | core.touched(targets,&playback.hierarchy_seen[2]) | core.reshaped(transforms,&playback.hierarchy_shapes[0]) | core.reshaped(animations,&playback.hierarchy_shapes[1]) {playback.hierarchy_stamp+=1}
    stamp:=playback.hierarchy_stamp+playback.rigs_stamp+1
    if actions!=nil && !actions_prepare(actions,requests,characters,animations,playback,events,app,problems) {return}
    if actions==nil {core.queue_clear(&requests.plays)}
    for value in core.take(&requests.values) {
        state:=constraint_playing(playback,value.entity)
        if state==nil && (core.has(animations,value.entity) || rig_find(playback,value.entity)>=0) {state=state_get(playback,value.entity)}
        if state==nil || !stack_parameter_set(state,value.name,value.value) {
            core.report(problems,value.entity,"animation.parameter","a parameter was set on this entity, which has no Animation, or on which more than %d names are set; set the weights of layers and the axes of spaces on the entity whose Animation plays the .character",STACK_PARAMETERS)
        }
    }
    if motion!=nil {if !motion_prepare(motion,motion_requests,animations,playback,characters,app.assets,app.allocator,problems) {return};motion_resolve_targets(motion,playback,skeleton_assets,core.read(transforms),parents,{})}
    distances:=core.take(&requests.distances)
    seeks:=core.take(&requests.timeline)
    pose_requests:=core.take(&requests.poses)
    match_goals:=core.take(&requests.match_goals)
    // Each rig gets its own goal, the last one told for it, found once for all of them; a rig
    // made in this tick is not there yet and looks for its own.
    unindexed:=0
    for goal,i in match_goals {if state:=constraint_playing(playback,goal.rig);state!=nil {state.program.match.goal=i32(i)+1} else {unindexed+=1}}
    rig_count:=len(playback.rigs)
    clear(&playback.work);clear(&playback.work_contents)
    if reserve(&playback.work,rig_count+core.count(animations))!=nil {memory_problem(problems,core.NONE,"the poses of the animated entities, so nothing is animated in this tick");return}
    for row in 0..<rig_count+core.count(animations) {
        skeletal:=row<rig_count
        e:=playback.rigs[row].entity if skeletal else core.entity_at(animations,row-rig_count)
        if !skeletal && rig_find(playback,e)>=0 {continue}
        // An entity with a pace of its own advances by its own time.
        pace:=core.pace_of(clock,paces,e) if time.playing else 1
        dt:=tick_dt*pace
        if !core.has(transforms,e) {continue}
        animation,animated:=core.get(animations,e)
        if !animated {animation=ANIMATION_DEFAULT;animation.playing=false}
        if !time.playing {animation.playing=animation.playing && animation.preview}
        if !animation_valid(animation) {
            core.report(problems,e,"animation.invalid","Animation of this entity has a value that is not finite, or an event_threshold outside 0 to 1, so it does not play; fix it")
            continue
        }
        state:=state_get(playback,e)
        if state==nil {memory_problem(problems,e,"its animation");continue}
        timeline_transport(state,&animation,seeks,time.playing)
        content,source_error:=animation_content(sources,app,state,animation,characters)
        // Until its sources load it plays on what it played (a weapon's set swapped into library
        // takes over once loaded), or, having played nothing, as an Animation without asset: a rig
        // holds its rest pose.
        if source_error==.Pending {
            previous,played,library,kept:=source_previous(sources,app,state,animation)
            if kept {content,animation.asset,animation.library,source_error=previous,played,library,.None} else {animation.asset,animation.library,source_error={},{},.None}
        }
        if source_error!=.None {state.program.error=source_error;program_problem(problems,e,app.assets,animation,source_error);continue}
        if content==nil && animation.asset!={} && animation_character(app.assets,animation)=={} {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,e,"animation.asset","Animation.asset names %s, which cannot be played: it is missing, is not an .anim or a .character, or is damaged; asset_errors of engine.diagnostics says which, and importing it again fixes a damaged one",host.assets_name(app.assets,animation.asset,&name))
        }
        first_event:=len(events.items)
        defer source_markers_resolve(sources,state,events.items[first_event:])
        facing:=mm.FORWARD;placed:=mm.TRANSFORM_IDENTITY
        if state.program.matched {if world,ok:=constraint_world(core.read(transforms),parents,{},e);ok {placed=world;facing=mm.quat_rotate(world.rotation,facing)}}
        rig_goals:[]Match_Goal
        if at:=int(state.program.match.goal)-1;at>=0 && at<len(match_goals) && match_goals[at].rig==e {rig_goals=match_goals[at:][:1]} else if unindexed>0 {
            for &goal,i in match_goals {if goal.rig==e {rig_goals=match_goals[i:][:1]}}
        }
        state.program.match.goal=0
        program,programmed,program_valid:=program_resolve(state,animation,app,characters,dt,events,playback,content,problems,rig_goals,action_inject(actions,state,animation,content),facing)
        if !program_valid {program_problem(problems,e,app.assets,animation,state.program.error);continue}
        content_id:=program.asset if programmed else content.id if content!=nil else animation.asset
        if !skeletal && content==nil {continue}
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
            state.layers,state.asked,state.stack={},{},0
            mem.zero_slice(state.program.players[:]);state.program.fade=0
            if !skeletal {state.hierarchy_stamp=0}
        }
        if skeletal {
            state.leader,state.stage=playback.rigs[row].leader,playback.rigs[row].stage
            skeleton:=playback.rigs[row].skeleton
            definition:=skeleton_content(skeleton_assets,app.assets,app.allocator,skeleton)
            if definition==nil {
                if skeleton_assets!=nil {asset_problem(problems,e,app.assets,"animation.skeleton","the mesh of its Mesh_Renderer",skeleton,content_error(skeleton_assets.contents[:],skeleton))}
                continue
            }
            if changed || state.skeleton!=definition.id || state.skeleton_revision!=definition.revision || len(state.bindings)==0 || content!=nil && state.tracks==0 {
                if !skeleton_bind(playback,state,definition,content,transforms) {memory_problem(problems,e,"the pose of its skeleton");continue}
            }
            if programmed && len(state.program.from)!=len(state.local) && resize(&state.program.from,len(state.local))!=nil {memory_problem(problems,e,"its animation program");continue}
            if state.pose_ready {copy(state.previous[:],state.local[:])}
            copy(state.local[:],state.rest[:])
            if root,ok:=core.get(transforms,e);ok {state.local[0]=core.to_math(root)}
        } else if state.skeleton!={} || state.hierarchy_stamp!=stamp || state.tracks==0 {
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
        stack_asks(actions,state,animation,content)
        state.held=false
        if content!=nil {
            if programmed {
                if !program_buffers(state,content) {state.program.error=.Out_Of_Memory;program_problem(problems,e,app.assets,animation,state.program.error);continue}
                // A whole-body action gives the program the times its clip goes between.
                if actions!=nil {actions_sample(actions,state,animation,dt,problems,content,playback,events,action_distance,pace,true)}
                if !program_players(state,program,content,animation,events,playback,dt,sought,problems,distance) {program_problem(problems,e,app.assets,animation,state.program.error);continue}
                if state.program.has_root {
                    state.base_root=state.program.root
                    state.has_base_root=true
                }
            } else {
                state.program.ready=false;state.program.has_root=false
                advance(playback,state,content,animation,events,dt,problems,sought,current_dt)
                state.clips_in_place=!state.has_base_root && animation.root_motion==.In_Place
                if !state.has_base_root && animation.root_motion!=.None && state.clip>=0 && state.clip<len(content.roots) {
                    root:=content.roots[state.clip]
                    state.base_root={bone={root.bone},translation=root.translation,rotation=root.rotation,in_place=animation.root_motion==.In_Place}
                    state.has_base_root=root.translation || root.rotation
                }
                curves_prepare(state,content)
                if actions!=nil {actions_sample(actions,state,animation,dt,problems,content,playback,events,action_distance,pace,false)}
            }
            layers_advance(playback,state,content,animation,events,dt,problems,characters,app,actions)
            if actions!=nil {actions_layer_finish(actions,state)}
            for &layer in state.layers[:state.stack] {if layer.weight>0 {state.held=false}}
            stack_parameters_check(state,problems)
        } else {clear(&state.curves);state.curves_ready=false}
        played:=work_content(playback,content)
        if played<0 {memory_problem(problems,e,"its animation");continue}
        append(&playback.work,Pose_Row{state=playback.rows[core.entity_index(e)]-1,content=played,programmed=programmed,animation=animation,dt=dt,current_dt=current_dt,sought=sought,distance=distance,action_distance=action_distance,distance_error=distance_error,placed=placed})
    }
    timeline_unclaimed(seeks,time.playing,problems)
    pose_rows_run(playback,core.read(transforms),&app.jobs if budget.parallel else nil,int(budget.job_grain))
    for &row in playback.work {
        state:=&playback.states[row.state]
        e:=state.entity
        animation:=&row.animation
        content:=&playback.work_contents[row.content-1] if row.content>0 else nil
        programmed,dt,current_dt,sought,distance,action_distance:=row.programmed,row.dt,row.current_dt,row.sought,row.distance,row.action_distance
        if row.faults.program {program_problem(problems,e,app.assets,animation^,state.program.error);continue}
        pose_faults_report(problems,e,row.faults,actions)
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
        if actions!=nil && content!=nil {actions_apply_root(actions,state,animation^)}
        if animation.mirror && len(state.mirror_pairs)>0 {
            state.motion=root_delta_mirror(state.mirror_plane,state.motion)
            state.body_motion.translation=lib.mirror_vector(state.mirror_plane,state.body_motion.translation)
            if state.has_action_in_place {if bone:=bone_resolve(state,state.action_in_place_root.bone);bone>0 && state.parents[bone]==0 {state.action_in_place_local=lib.mirror_transform(state.mirror_plane,state.mirror_corrections[bone],state.action_in_place_local)}}
        }
        if character:=animation_character(app.assets,animation^);motion!=nil && character!={} && content!=nil {
            actor,ok:=constraint_world(core.read(transforms),parents,{},e)
            clock:=animation_motion_clock(state,content,&state.program.output if programmed else nil,dt,current_dt)
            clock.weight*=mm.saturate(animation.weight)
            if state.has_base_root && !programmed {clock.root=state.base_root}
            action:=action_clock(actions,e);if action.player.clip!=0 {clock=action}
            if animation.mirror && len(state.mirror_pairs)>0 {clock.mirror=!clock.mirror}
            unwarped:=state.motion.translation
            if ok && !motion_apply_root(motion,characters,app.assets,app.allocator,state,character,content,actor,dt,sought>=0 || distance!=nil && distance.seek || action_distance!=nil && action_distance.seek,clock,mm.saturate(animation.weight)) {
                if instance:=motion_instance(motion,e);instance!=nil {motion_problem(problems,e,instance.error)}
            }
            // The warp of the clock of an action that moves the body moves the body as much.
            if leading:=action_root_slot(actions,e);leading!=nil && leading.body!=.None {state.body_motion.translation+=state.motion.translation-unwarped} else if !state.has_action_root && action_body_injected(actions,state) {state.body_motion.translation=state.motion.translation}
        }
        if programmed {match_lag_apply(state,row.placed)}
        copy(state.sampled[:],state.local[:])
        if row.distance_error!=.None {state.program.error=.Invalid_Parameter;distance_problem(problems,e,row.distance_error)}
        state.seen=playback.frame
    }
    clear(&playback.work);clear(&playback.work_contents)
    if actions!=nil {actions_finish(actions,playback,tick_dt)}
}

// The place in Playback.work_contents of what a row plays, kept there the first time a row of the
// tick plays it: 0 for none, -1 when memory ran out.
@(private)
work_content :: proc(playback:^Playback,content:^host.Content_Animation) -> i32 {
    if content==nil {return 0}
    for &known,i in playback.work_contents {
        if known.id==content.id && known.generation==content.generation && raw_data(known.lib.tracks)==raw_data(content.lib.tracks) {return i32(i+1)}
    }
    if append(&playback.work_contents,content^)!=1 {return -1}
    return i32(len(playback.work_contents))
}


finite :: proc "contextless" (value:f32) -> bool {return abs(value)<=max(f32)}

// Reports why the .character of an Animation did not play.
@(private)
program_problem :: proc(problems:^core.Problems,e:core.Entity,assets:^host.Assets,animation:Animation,error:Program_Error) {
    name:[base.ASSET_ID_TEXT]u8
    path:=host.assets_name(assets,animation.asset,&name)
    switch error {
    case .None,.Out_Of_Memory: memory_problem(problems,e,"its animation program")
    case .Invalid_Asset: core.report(problems,e,"animation.program_asset","Animation.asset %s, its library or a clip source it names cannot be read or is of another kind, or they name more than %d animations; check them with animation.asset.inspect, and import or save them again",path,ANIMATION_SOURCES)
    case .Invalid_Parameter: core.report(problems,e,"animation.program_parameter","a speed, a sync or a transition of %s cannot advance: a value of it is not finite, or a clip it plays by distance cannot reach the time asked; check Animation.speed and the distance asked",path)
    case .Missing_Clip: core.report(problems,e,"animation.program_clip","%s plays a clip its animation library does not have; add the clip, or set Animation.library to an .anim that has it",path)
    case .Incompatible_Root: core.report(problems,e,"animation.program_root","%s blends clips whose root motion has different bones or channels; give them the same root motion, or blend clips without it",path)
    case .Capacity: core.report(problems,e,"animation.program_capacity","%s plays more clips at once than fit (%d); blend fewer clips at a time",path,PROGRAM_PLAYERS)
    case .Pending: // its sources still load: it plays once they are ready
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
    return true
}

// The rigs of the world, found again when its meshes or skins change. A mesh
// with a Pose_Source of stage Finished shares the pose of its rig when both
// have one skeleton; otherwise it is a rig that takes the pose of that one.
@(private)
rigs_update :: proc(playback:^Playback,meshes:core.Read(erender.Mesh_Renderer),skins:core.Read(Pose_Source),assets:^host.Assets) -> bool {
    if meshes.table==nil {if len(playback.rigs)>0 {clear(&playback.rigs);clear(&playback.follow_order);playback.rigs_stamp+=1};playback.rigs_seen,playback.rigs_assets={},0;return true}
    // Kept only when the rigs were made: without memory they are made again.
    seen,loaded:=playback.rigs_seen,assets_stamp(assets)
    moved:=core.touched(meshes,&seen[0])
    if skins.table!=nil {moved|=core.touched(skins,&seen[1])} else {moved|=seen[1]!={};seen[1]={}}
    if !moved && loaded==playback.rigs_assets {return true}
    skeleton_of :: proc(meshes:core.Read(erender.Mesh_Renderer),assets:^host.Assets,e:core.Entity) -> base.Asset_Id {
        static,has:=core.get(meshes,e)
        if !has || static.mesh=={} {return {}}
        mesh:=host.assets_mesh(assets,static.mesh)
        return mesh.skeleton if mesh!=nil && !mesh.failed else {}
    }
    rig_of :: proc(meshes:core.Read(erender.Mesh_Renderer),skins:core.Read(Pose_Source),assets:^host.Assets,row:int) -> (rig:Rig,ok:bool) {
        e:=core.entity_at(meshes,row)
        skeleton:=skeleton_of(meshes,assets,e)
        if skeleton=={} {return}
        rig={entity=e,skeleton=skeleton}
        if skins.table!=nil {
            if source,has:=core.get(skins,e);has {
                leader:=skeleton_of(meshes,assets,source.rig)
                if leader=={} || leader==skeleton && source.stage==.Finished || source.rig==e {return}
                rig.leader,rig.stage=source.rig,source.stage
            }
        }
        return rig,true
    }
    changed:=false;count:=0
    for row in 0..<core.count(meshes) {
        rig,ok:=rig_of(meshes,skins,assets,row)
        if !ok {continue}
        count+=1
        known:=rig_find(playback,rig.entity)
        changed ||= known<0 || playback.rigs[known]!=rig
    }
    if changed || count!=len(playback.rigs) {
        next,error:=make([dynamic]Rig,0,count)
        if error!=nil {return false}
        for row in 0..<core.count(meshes) {
            if rig,ok:=rig_of(meshes,skins,assets,row);ok {append(&next,rig)}
        }
        slice.sort_by(next[:],proc(a,b:Rig) -> bool {return a.entity<b.entity})
        delete(playback.rigs);playback.rigs=next;playback.rigs_stamp+=1
        if !follow_order_update(playback) {return false}
    }
    playback.rigs_seen,playback.rigs_assets=seen,loaded
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
    was,weight_was:=state.time,state.held_weight
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
    state.held_weight=animation.weight
    state.held=!started && seek<0 && state.time==was && animation.weight==weight_was && state.fader.outgoing_count==0
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

// The value set gave a parameter of an entity; false when none was set.
@(private)
stack_parameter :: proc "contextless" (state:^Playing,name:u64) -> (value:f32,given:bool) {
    if name==0 {return}
    for &parameter in state.parameters {if parameter.name==name {parameter.used=true;return parameter.value,true}}
    return
}
@(private)
stack_parameter_set :: proc "contextless" (state:^Playing,name:u64,value:f32) -> bool {
    free:=-1
    for &parameter,i in state.parameters {
        if parameter.name==name {parameter.value=value;return true}
        if parameter.name==0 && free<0 {free=i}
    }
    if free<0 || name==0 {return false}
    state.parameters[free]={name=name,value=value}
    return true
}
// A parameter no layer or axis of the stack read in this tick names nothing: it is dropped.
@(private)
stack_parameters_check :: proc(state:^Playing,problems:^core.Problems) {
    for &parameter in state.parameters {
        if parameter.name==0 {continue}
        if !parameter.used {
            core.report(problems,state.entity,"animation.parameter","a parameter was set on this entity that names no layer of its .character and no axis of the space of one, or it plays no .character; set the name of a layer (its weight) or of an axis of a space of its set (animation.inspect lists them)")
            parameter={};continue
        }
        parameter.used=false
    }
}

// The clips a layer blends in this tick, each with its weight: those of its fader, or those of
// its space at the place its parameters give.
LAYER_PLAYERS :: lib.FADER_OUTGOING+1
layer_players :: proc "contextless" (layer:^Layer_Playing,out:^[LAYER_PLAYERS]lib.Player) -> (count:int) {
    if layer.leaf_count>0 {
        for leaf in layer.leaves[:min(int(layer.leaf_count),SPACE_LEAVES)] {
            player:=lib.Player{clip=leaf.clip,time=layer.time*leaf.speed,speed=leaf.speed,weight=leaf.weight}
            out[count]=player;count+=1
        }
        return
    }
    if layer.clip==0 {return}
    out[0]=layer.fader.current;out[0].weight=lib.fader_current_weight(layer.fader);count=1
    for outgoing in layer.fader.outgoing[:clamp(layer.fader.outgoing_count,0,lib.FADER_OUTGOING)] {
        out[count]=outgoing.player;out[count].weight=lib.fade_out_weight(outgoing);count+=1
    }
    return
}

// The clips of the space of a layer at the place its axes are set to (set), and its weight on the
// way to the one asked. False when the space or a clip of it cannot be played.
@(private)
layer_space_advance :: proc(state:^Playing,layer:^Layer_Playing,asked:Layer_Ask,content:^host.Content_Animation,animation:Animation,characters:^Character_Assets,app:^host.App,dt:f32) -> bool {
    set:=character_content(characters,app.assets,app.allocator,animation.asset)
    index:=int(asked.space)-1
    if set==nil || index<0 || index>=len(set.spaces) {layer^={};return false}
    info:=set.set.spaces[index];ready:=&set.spaces[index]
    position:mm.Vec2
    x,_:=stack_parameter(state,ready.axis_names[0]);position.x=clamp(x,info.x.min,info.x.max)
    if info.dimension==.Two {y,_:=stack_parameter(state,ready.axis_names[1]);position.y=clamp(y,info.y.min,info.y.max)}
    weights,sampled:=space_sample(info,ready,position)
    if !sampled {layer^={};return false}
    if layer.space!=asked.space {layer^={space=asked.space}}
    layer.leaf_count=0
    for weight,w in weights.weights[:weights.count] {
        if weight<=0 {continue}
        sample:=set.set.space_samples[ready.first+int(weights.samples[w])]
        source:=source_effective(sample.animation,set.set.info.animation,animation.library)
        handle:=lib.clip_find(&content.lib,source_clip_name(content.id,source,ready.names[weights.samples[w]]))
        if handle==0 || int(handle)>content.clip_count {layer^={};return false}
        layer.leaves[layer.leaf_count]={clip=handle+lib.Clip(content.clip_count),weight=weight,speed=sample.speed};layer.leaf_count+=1
    }
    target:=mm.saturate(asked.weight)
    step:=dt/asked.fade if asked.fade>0 else 1
    layer.weight=target if abs(target-layer.weight)<=step else layer.weight+(step if target>layer.weight else -step)
    if animation.playing && finite(layer.time+dt*asked.speed) {layer.time+=dt*asked.speed}
    return true
}

// The slots of the stack follow what they are asked: a new clip cross-fades in, the weight moves to
// the one asked over fade, and a slot without clip fades out.
@(private)
layers_advance :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,dt:f32,problems:^core.Problems,characters:^Character_Assets=nil,app:^host.App=nil,actions:^Action_Runtime=nil) {
    library:=&content.lib
    for &layer,i in state.layers[:state.stack] {
        asked:=state.asked[i]
        if asked.injected {continue}
        if asked.space!=0 {
            if app==nil || !layer_space_advance(state,&layer,asked,content,animation,characters,app,dt) {
                core.report(problems,state.entity,"animation.layer_space","layer '%s' of the .character of this entity samples a space that names a clip its animation does not have; check it with animation.asset.inspect, and fix it with animation.space.set",stack_slot_name(actions,state.entity,i))
            }
            continue
        }
        if layer.space!=0 {layer={}}
        index:=int(lib.clip_find(library,asked.clip))-1 if asked.clip!=0 else -1
        known:=index>=0 && index<content.clip_count
        if asked.clip!=0 && !known {core.report(problems,state.entity,"animation.layer_clip","layer '%s' of the .character of this entity plays a clip its animation does not have, so it plays nothing; name one of its clips in the layer (animation.asset.inspect lists them)",stack_slot_name(actions,state.entity,i))}
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
pose_sample :: proc(playback:^Playback,state:^Playing,library:^lib.Library,animation:Animation,transforms:core.Read(core.Transform),content:^host.Content_Animation=nil,worker:=0) -> (faults:Pose_Faults) {
    if len(state.bindings)==0 {return}
    if state.clip>=0 {
        _,bones,shared,ready:=pose_room(playback,state,worker)
        if !ready {faults.memory=true;return}
        tracks:=shared.bones[:]
        lib.bones_blend(bones,tracks,library,state.fader.current,lib.fader_current_weight(state.fader),clip_root_lock(state,content,state.fader.current.clip,transforms))
        for o in state.fader.outgoing[:state.fader.outgoing_count] {lib.bones_blend(bones,tracks,library,o.player,lib.fade_out_weight(o),clip_root_lock(state,content,o.player.clip,transforms))}
        tracks_twins(shared,bones)
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
                value,w,ok:=lib.bone_position(bones[i])
                alpha:=mm.saturate(w)*share
                out.position=rest.position if !ok || alpha==0 else value if alpha==1 else rest.position+(value-rest.position)*alpha
            }
            if .Rotation in binding.driven {
                value,w,ok:=lib.bone_rotation(bones[i])
                alpha:=mm.saturate(w)*share
                out.rotation=rest.rotation if !ok || alpha==0 else value if alpha==1 else mm.quat_slerp(rest.rotation,value,alpha)
            }
            if .Scale in binding.driven {
                value,w,ok:=lib.bone_scale(bones[i])
                alpha:=mm.saturate(w)*share
                out.scale=rest.scale if !ok || alpha==0 else value if alpha==1 else rest.scale+(value-rest.scale)*alpha
            }
            state.local[i]=out
        }
    }
    return pose_layers(playback,state,library,animation,transforms,worker)
}

// What a layer blended for a bone over the transform below it, by its share: an additive one
// puts its change on top, another moves each channel toward its value by the weight that blended it.
@(private)
pose_layer_transform :: proc(blend:lib.Bone_Blend,out:mm.Transform,share:f32,additive:bool,root:^Root_Motion=nil,reference:mm.Transform=mm.TRANSFORM_IDENTITY) -> mm.Transform {
    out:=out
    if share<=0 {return out}
    in_place:=root!=nil && root.in_place
    if additive {
        if value,ok:=lib.bone_added_position(blend);ok {if in_place && root.translation {value=reference.position};out.position+=value*share}
        if value,ok:=lib.bone_added_rotation(blend);ok {if in_place && root.rotation {value=reference.rotation};out.rotation*=mm.quat_slerp(1,value,share)}
        if value,ok:=lib.bone_added_scale(blend);ok {out.scale+=value*share}
        return out
    }
    if value,w,ok:=lib.bone_position(blend);ok {if in_place && root.translation {value=reference.position};out.position+=(value-out.position)*(mm.saturate(w)*share)}
    if value,w,ok:=lib.bone_rotation(blend);ok {if in_place && root.rotation {value=reference.rotation};out.rotation=mm.quat_slerp(out.rotation,value,mm.saturate(w)*share)}
    if value,w,ok:=lib.bone_scale(blend);ok {out.scale+=(value-out.scale)*(mm.saturate(w)*share)}
    return out
}

// The rotation of bone b after an Override layer blended in the space of the rig, written to its
// local pose: rotations holds by binding that of the base, of the layer and of the blend in that
// space (the bone under none is its origin). A bone the layer leaves out follows its parent as in
// the base. False when its parent comes after it.
@(private)
pose_layer_mesh_rotation :: proc(rotations:[]mm.Quat,state:^Playing,blend:lib.Bone_Blend,b:int,share:f32) -> bool {
    n:=len(state.bindings)
    base,layered,blended:=rotations[:n],rotations[n:2*n],rotations[2*n:3*n]
    parent:=int(state.parents[b])
    if parent<0 {base[b],layered[b],blended[b]=1,1,1;return true}
    if parent>=b {return false}
    own:=state.local[b].rotation;theirs:=own
    if value,w,ok:=lib.bone_rotation(blend);ok {theirs=mm.quat_slerp(own,value,mm.saturate(w))}
    base[b]=base[parent]*own;layered[b]=layered[parent]*theirs
    if share<=0 {blended[b]=blended[parent]*own;return true}
    blended[b]=mm.quat_slerp(base[b],layered[b],mm.saturate(share))
    state.local[b].rotation=linalg.normalize0(mm.quat_inverse(blended[parent])*blended[b])
    return true
}

// The slots of the stack of state over its local pose, in order: each moves only what its clips
// animate, inside its branch, replacing by its weight or adding its change from its reference.
@(private)
pose_layers :: proc(playback:^Playback,state:^Playing,library:^lib.Library,animation:Animation,transforms:core.Read(core.Transform)={},worker:=0) -> (faults:Pose_Faults) {
    if state.stack==0 {return}
    root_bone:=-1;reference:=mm.TRANSFORM_IDENTITY;retired:=mm.TRANSFORM_IDENTITY
    for root,i in state.action_roots {if state.action_root_mask&(u16(1)<<u16(i))==0 {continue};root_bone=bone_resolve(state,root.bone);if root_bone>=0 {state.action_in_place_root=root;break}}
    if root_bone>=0 {
        reference=state.rest[root_bone];retired=state.local[root_bone]
        if state.parents[root_bone]<0 && state.bindings[root_bone].entity==state.entity && transforms.table!=nil {if current,present:=core.get(transforms,state.entity);present {reference=core.to_math(current)}}
        if state.has_base_root && state.base_root.in_place && bone_resolve(state,state.base_root.bone)==root_bone {if state.base_root.translation {retired.position=reference.position};if state.base_root.rotation {retired.rotation=reference.rotation}}
    }
    n:=len(state.bindings)
    for &layer,i in state.layers[:state.stack] {
        asked:=state.asked[i]
        if asked.injected || layer.weight<=0 {continue}
        players:[LAYER_PLAYERS]lib.Player
        count:=layer_players(&layer,&players)
        if count==0 {continue}
        selection:Bone_Selection;masked:=asked.over!=0
        if masked {
            found:bool
            if selection,found=bone_select(state,asked.over);!found {faults.layer_bone|=u16(1)<<u16(i);continue}
        }
        additive:=asked.mode==.Additive
        from:lib.Clip
        if additive && asked.reference_clip!=0 {
            if from=lib.clip_find(library,asked.reference_clip);from==0 {faults.layer_reference|=u16(1)<<u16(i);continue}
        }
        scratch,bones,shared,ready:=pose_room(playback,state,worker)
        if !ready {faults.memory=true;continue}
        tracks:=shared.bones[:]
        for player in players[:count] {
            if additive {lib.bones_blend_additive(bones,tracks,library,player,asked.reference,1,from,scratch.references[:])} else {lib.bones_blend(bones,tracks,library,player)}
        }
        tracks_twins(shared,bones)
        mesh:=!additive && asked.mesh_space && len(state.parents)==n
        for b in 0..<n {
            share:=layer.weight*mm.saturate(animation.weight)
            if masked && !bone_selected(state,selection,b) {share=0}
            if mesh && !pose_layer_mesh_rotation(scratch.rig_rotations[:3*n],state,bones[b],b,share) {continue}
            if share<=0 {continue}
            turned:=state.local[b].rotation
            state.local[b]=pose_layer_transform(bones[b],state.local[b],share,additive)
            if mesh && state.parents[b]>=0 {state.local[b].rotation=turned}
            if b==root_bone {root:^Root_Motion;if state.action_root_mask&(u16(1)<<u16(i))!=0 {root=&state.action_roots[i]};retired=pose_layer_transform(bones[b],retired,share,additive,root,reference)}
        }
    }
    if root_bone>=0 {state.action_in_place_local=retired;state.has_action_in_place=true}
    return
}

// Writes the pose to the entities it is bound to. An entity whose Transform another component
// owns (a body) is asked of its owner through places, at the place the track gives it.
pose_write :: proc(playback:^Playback,state:^Playing,transforms:^core.Table(core.Transform),parents:core.Read(core.Parent)={},places:^core.Places=nil) {
    if state.held && state.skeleton=={} {return}
    for binding,i in state.bindings {
        if binding.entity==core.NONE {continue}
        old,ok:=core.get(transforms,binding.entity)
        if !ok || state.local[i]==core.to_math(old) {continue}
        row:=core.free(transforms,binding.entity)
        if row==nil {
            if places==nil || state.skeleton!={} || binding.driven&{.Position,.Rotation}=={} {playback.stats.skipped+=1;continue}
            world:=state.local[i]
            if parent,under:=core.get(parents,binding.entity);under && parent.entity!=core.NONE {
                above,placed:=core.world_of(core.read(transforms),parents,parent.entity)
                if placed {world=mm.transform_compose(above,world)}
            }
            core.push(&places.queue,core.Place_Request{entity=binding.entity,position=world.position,rotation=world.rotation})
            continue
        }
        row^=core.from_math(state.local[i])
    }
}

// action: base.name_hash of the name of the action that plays the clip; 0: none.
emit_events :: proc(playback:^Playback,events:^Animation_Events,entity:core.Entity,content:^host.Content_Animation,batch:[]lib.Event,dropped:int,problems:^core.Problems,weight:f32=1,source:u32=0,group:u16=0,animation:Animation=ANIMATION_DEFAULT,action:u64=0) {
    if weight<=0 || animation.event_policy==.Weighted && weight<animation.event_threshold {return}
    for event in batch {
        if int(event.id)>=len(content.markers) {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,entity,"animation.marker_name","a marker of a clip of animation %s has no name in the asset, which is damaged; import it again",base.asset_id_format(content.id,name[:]))
            continue
        }
        if !event_push(playback,events,Animation_Event{entity=entity,kind=.Marker,action=action,name=content.markers[event.id].name,clip=lib.clip_data(&content.lib,event.clip).name,time=event.time,fraction=event.fraction,weight=weight,source=source,group=group,animation=content.id}) {
            markers_lost(problems,entity,1,"memory ran out, or the events of the world in this tick passed the room of Animation_Events; free memory, or space the markers of the clips")
        }
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
    row,ok:=core.get(transforms,e)
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

// Finds what the tracks of the asset move: the entity itself for the tracks
// without target, whatever below it has the name of a track, and the entities
// anywhere whose Animation_Target names this one. What was bound keeps its
// rest transform. Below it, entities with an Animation of their own, rigs and
// what names another animation are left to it.
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
        if !explicit || target.animation==core.NONE || target.animation==root {
            hash:=base.name_hash(base.text_get(target.path[:])) if explicit else base.name_hash(core.name_get(names,e))
            if !binding_add(playback,&next,old,transforms,e,hash,targeted(library,hash),problems) {return false}
        }
        e=core.subtree_next(hierarchy,root,e)
    }
    for row in 0..<core.count(targets) {
        target:=core.at(targets,row)
        e:=core.entity_at(targets,row)
        if target.animation!=root || e==root {continue}
        known:=false
        for binding in next.bindings {if binding.entity==e {known=true;break}}
        if known {continue}
        name:=base.text_get(target.path[:])
        if name=="" {name=core.name_get(names,e)}
        hash:=base.name_hash(name)
        if !binding_add(playback,&next,old,transforms,e,hash,targeted(library,hash),problems) {return false}
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
    if !tracks_bind(playback,&next,content) {return false}
    tracks_release(playback,state);state.tracks,next.tracks=next.tracks,0
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

@(storage,setting)
Animation_Settings :: struct {
    requests:u32 `mirai:"advanced"`,    // of each kind a tick can ask for: timeline commands, poses, plays, parameters, goals and targets; past it they are dropped and reported
    match_goals:u32 `mirai:"advanced"`, // rigs whose motion matching a tick is told of; as many
}
ANIMATION_SETTINGS_DEFAULT :: Animation_Settings{requests=256,match_goals=4096}

// The room of the requests of a tick, and what did not fit or was invalid in them.
@(step="input fixed",loops="game editor",stage="begin")
animation_requests_serve :: proc(requests:^Animation_Requests,motion:^Motion_Requests,modifiers:^Modifier_Requests,settings:Animation_Settings,problems:^core.Problems) {
    code,capacity,setting:="animation.requests",int(settings.requests),"Animation_Settings.requests"
    core.queue_serve(&requests.timeline,capacity,problems,code,"timeline commands",setting,"it names an entity, a command and a finite time")
    core.queue_serve(&requests.distances,capacity,problems,code,"animation distance plays",setting,"it names an entity, a clip and a time of 0 or more, or a distance track of its .character")
    core.queue_serve(&requests.poses,capacity,problems,code,"bone poses",setting,"it names a rig and a bone, with a finite pose, a unit rotation and a weight from 0 to 1")
    core.queue_serve(&requests.final_poses,capacity,problems,code,"final bone poses",setting,"it names a rig and a bone, with a finite pose, a unit rotation and a weight from 0 to 1")
    core.queue_serve(&requests.match_goals,int(settings.match_goals),problems,code,"motion matching goals","Animation_Settings.match_goals","it names a rig and a mode up to 31, with finite values and rates of 0 or more")
    core.queue_serve(&requests.plays,capacity,problems,code,"plays and stops of actions",setting,"it names an entity, an action of under 64 bytes and a section of under 64 bytes or none")
    core.queue_serve(&requests.values,capacity,problems,code,"animation parameters",setting,"it names an entity and a parameter of under 64 bytes, with a finite value")
    core.queue_serve(&requests.looks,capacity,problems,code,"looks",setting,"it names an entity and a valid spatial target, with a weight from 0 to 1")
    core.queue_serve(&motion.targets,capacity,problems,code,"motion warp targets",setting,"it names a rig, a target of under 32 bytes and a valid spatial target")
    core.queue_serve(&motion.locomotion,capacity,problems,code,"motion locomotion inputs",setting,"it names a rig, with finite velocities and a weight from 0 to 1")
    core.queue_serve(&modifiers.queue,capacity,problems,code,"pose goals",setting,"it names a rig and a slot of its kind, with finite values and a weight from 0 to 1")
    core.queue_serve(&modifiers.controls,capacity,problems,code,"pose controls",setting,"it names a rig and a slot of its kind, with a weight from 0 to 1 and a fade of 0 or more")
}

// Changes the clip the component plays, which cross-fades into it from its start over fade seconds
// (below zero: the fade of the component). False, with nothing changed, for a name that does not
// fit or numbers that are not finite. What plays over the clip is asked for with play.
animation_clip :: proc(animation:^Animation,clip:string,fade:f32=-1,loop:Maybe(bool)=nil,speed:f32=1) -> bool {
    if animation==nil || !finite(fade) || !finite(speed) || len(clip)>=CLIP_CAPACITY {return false}
    base.text_set(animation.clip[:],clip)
    animation.playing,animation.speed=true,speed
    if fade>=0 {animation.fade=fade}
    if value,given:=loop.?;given {animation.loop=value}
    return true
}

playback_free :: proc(playback:^Playback) {
    for &state in playback.states {playing_free(&state)}
    delete(playback.states);delete(playback.rows);delete(playback.rigs);delete(playback.follow_order);delete(playback.final_rows)
    for &shared in playback.track_maps {track_map_free(&shared)}
    for &scratch in playback.scratch {delete(scratch.bones);delete(scratch.references);delete(scratch.rig_rotations)}
    delete(playback.track_maps);delete(playback.scratch);delete(playback.work);delete(playback.work_contents)
    playback^={}
}

playing_free :: proc(state:^Playing) {
    program_free(&state.program)
    delete(state.curves);delete(state.bindings);delete(state.parents);delete(state.targets);delete(state.aliases);delete(state.previous)
    delete(state.mirror_pairs);delete(state.mirror_corrections);delete(state.mirror_scratch);delete(state.regions)
    delete(state.rest);delete(state.local);delete(state.world);delete(state.sampled)
    delete(state.follow);delete(state.retarget);delete(state.retarget_rest);delete(state.retarget_world);delete(state.driven);delete(state.driven_own);delete(state.driven_leader)
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

animation_finish :: proc(playback:^Playback,inputs:Constraint_Inputs,constraints:^Animation_Constraints,transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),dt:f32,grounding:^Grounding_Runtime,ground_inputs:Grounding_Inputs,rig_runtime:^Modifier_Runtime=nil,motion:^Motion_Runtime=nil,characters:^Character_Assets=nil,final_poses:[]Pose_Request=nil,paces:core.Read(core.Own_Pace)={},clock:=core.CLOCK_DEFAULT,places:^core.Places=nil) {
    grounding_prepare(grounding,ground_inputs.configs,ground_inputs.problems)
    finish :: proc(state:^Playing,playback:^Playback,inputs:Constraint_Inputs,constraints:^Animation_Constraints,transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),dt:f32,grounding:^Grounding_Runtime,ground_inputs:Grounding_Inputs,rig_runtime:^Modifier_Runtime,motion:^Motion_Runtime,characters:^Character_Assets,final_poses:[]Pose_Request,paces:core.Read(core.Own_Pace),clock:core.Clock,places:^core.Places) {
        if state.skeleton!={} {if root,ok:=core.get(transforms,state.entity);ok {state.local[0]=core.to_math(root)}}
        constraints_apply(state,playback,inputs,constraints,transforms,parents,dt*core.pace_of(clock,paces,state.entity),grounding,ground_inputs,rig_runtime,motion,characters,final_poses)
        pose_write(playback,state,transforms,parents,places)
        if !state.pose_ready || !slice.equal(state.local[:],state.previous[:]) {state.changed=playback.frame}
        if !state.pose_ready {copy(state.previous[:],state.local[:])}
        state.pose_ready=true
        state.finished=playback.frame
    }
    for &state in playback.states {
        if state.seen!=playback.frame || state.leader!=core.NONE {continue}
        finish(&state,playback,inputs,constraints,transforms,parents,dt,grounding,ground_inputs,rig_runtime,motion,characters,final_poses,paces,clock,places)
    }
    // Each follower after the rig it follows, in the order rigs_update found;
    // then those it does not list (a leader set by hand), and those of a loop.
    for follow in playback.follow_order {
        state:=constraint_playing(playback,follow.entity)
        if state==nil || state.seen!=playback.frame || state.leader==core.NONE || state.finished==playback.frame {continue}
        finish(state,playback,inputs,constraints,transforms,parents,dt,grounding,ground_inputs,rig_runtime,motion,characters,final_poses,paces,clock,places)
    }
    for &state in playback.states {
        if state.seen!=playback.frame || state.leader==core.NONE || state.finished==playback.frame {continue}
        finish(&state,playback,inputs,constraints,transforms,parents,dt,grounding,ground_inputs,rig_runtime,motion,characters,final_poses,paces,clock,places)
    }
    #reverse for &state,i in playback.states {
        if state.seen==playback.frame {continue}
        index:=core.entity_index(state.entity)
        if playback.rows[index]==i32(i+1) {playback.rows[index]=0}
        tracks_release(playback,&state)
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
            clock={player=slot.player,from=slot.from,to=slot.to,root=state.program.root,weight=share,active=true}
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
