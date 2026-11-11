package animation_editor

import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(private)
Pose_Bake_Track :: struct {desc:asset.Animation_Track_Desc,hash:u64,bone:int,morph:core.Entity,morph_index:int}
@(private)
Pose_Bake_Root_State :: struct {root:anim.Root_Motion,bone:int,moved:mm.Vec3,turned:mm.Quat,ready:bool}

// Evaluates one step of the isolated world; a problem the step reports fails the bake.
@(private)
pose_bake_evaluate :: proc(call:^api.Call,world:core.World_Ref,app:^host.App,dt:f32) -> bool {
    problems:=host.app_world_storage(app,world.data,core.Problems)
    before:=problems.serial if problems!=nil else 0
    if !anim.animation_evaluate(world,app,dt) {authoring_failure(call,"bake","Evaluation_Failed","an evaluable copy of the world","evaluation failed","The animation could not be evaluated",api.SERVER_ERROR);return false}
    if problems==nil || problems.serial==before {return true}
    latest:^core.Problem
    for &p in core.problems_list(problems) {if latest==nil || p.last>latest.last {latest=&p}}
    authoring_failure(call,"bake","Evaluation_Failed","an evaluation without problems",fmt.tprintf("%s: %s",core.problem_code(latest),core.problem_text(latest)),"Resolve the problems of the instance (engine.diagnostics lists them) before baking",api.SERVER_ERROR)
    return false
}

@(private)
pose_bake_track :: proc(call:^api.Call,tracks:^[dynamic]Pose_Bake_Track,name:string,property:lib.Property,slot:u8,frames:int,bone:int=-1,morph:core.Entity=core.NONE,morph_index:int=-1) -> bool {
    for &track in tracks {if track.desc.target==name && track.desc.property==property && track.desc.slot==slot {if morph!=core.NONE {track.morph,track.morph_index=morph,morph_index};return true}}
    if len(tracks)>=asset.ANIMATION_MAX_TRACKS || frames>asset.ANIMATION_MAX_KEYS/max(len(tracks)+1,1) {authoring_failure(call,"tracks","Capacity","tracks and keys within .anim capacities","too many sampled values","Reduce the bake range or sample rate");return false}
    keys,error:=make([]lib.Keyframe,frames,call.allocator)
    owned:=strings.clone(name,call.allocator)
    if error!=nil || len(owned)!=len(name) || append(tracks,Pose_Bake_Track{{owned,property,slot,keys},base.name_hash(name),bone,morph,morph_index})!=1 {authoring_failure(call,"tracks","Out_Of_Memory","memory for sampled tracks","allocation failed","The baked tracks could not be allocated",api.SERVER_ERROR);return false}
    return true
}

@(private)
pose_bake_state :: proc(world:core.World_Ref,entity:core.Entity) -> ^anim.Playing {
    playback:=core.world_storage_of(world,anim.Playback);if playback==nil {return nil}
    for &state in playback.states {if state.entity==entity && state.seen==playback.frame && state.pose_ready {return &state}}
    return nil
}

// The local transform the root bone is baked with: the trajectory moved so far over the
// first sample (Preserve) or the pinned reference (In_Place), with what modifiers changed.
@(private)
pose_bake_root :: proc(call:^api.Call,world:core.World_Ref,state:^anim.Playing,root:^Pose_Bake_Root_State,origin:[]mm.Transform,mode:Pose_Bake_Root) -> (mm.Transform,bool) {
    transforms:=core.world_table_of(world,core.Transform)
    active:=state.root;has_root:=active.translation || active.rotation
    if has_root && (active.translation || active.rotation) {
        bone,_,ok:=anim.animation_root_reference(state,active,state.sampled[:],transforms)
        if !ok || bone>=len(origin) {authoring_failure(call,"root_motion","Missing_Bone","a resolved root bone","unbound root","The effective root could not be baked");return {},false}
        if root.ready && root.bone!=bone {authoring_failure(call,"root_motion","Changed_Root","one root bone throughout the bake","a different effective root","Split this range where its root bone changes");return {},false}
        if !root.ready {root.root=active;root.bone,root.turned,root.ready=bone,1,true}
        root.root.translation ||= active.translation;root.root.rotation ||= active.rotation
    }
    if !root.ready {return mm.TRANSFORM_IDENTITY,true}
    if state.root_enabled {root.moved+=state.motion.translation;root.turned=linalg.normalize0(root.turned*state.motion.rotation)}
    reference_root:=root.root;reference_root.in_place=active.in_place if has_root else false
    _,reference,valid:=anim.animation_root_reference(state,reference_root,state.sampled[:],transforms)
    if !valid {return {},false}
    correction,relative:=mm.transform_relative(state.local[root.bone],reference)
    if !relative {authoring_failure(call,"root_motion","Invalid_Reference","an invertible root reference","zero scale","The root correction could not be baked");return {},false}
    basis:=reference
    if mode==.Preserve {
        if root.root.translation {basis.position=origin[root.bone].position+root.moved}
        if root.root.rotation {basis.rotation=linalg.normalize0(origin[root.bone].rotation*root.turned)}
    } else {
        reference_root.in_place=true
        _,basis,valid=anim.animation_root_reference(state,reference_root,state.sampled[:],transforms)
        if !valid {return {},false}
    }
    return mm.transform_compose(basis,correction),true
}

// A Float track "<path>/@morph/<target>" for each target of each mesh the rig deforms.
@(private)
pose_bake_morph_tracks :: proc(call:^api.Call,world:core.World_Ref,app:^host.App,rig:core.Entity,tracks:^[dynamic]Pose_Bake_Track,frames:int) -> bool {
    playback:=core.world_storage_of(world,anim.Morph_Playback)
    if playback==nil {return true}
    skin:=core.world_storage_of(core.world_ref(app.shared,world.info,.Shared),anim.Skin_Runtime);if skin==nil {return true}
    configs:=core.world_table_of(world,anim.Morph_Weights);targets:=core.world_table_of(world,anim.Animation_Target)
    for &state in playback.states {
        if state.source!=rig && state.entity!=rig && (state.source!=core.NONE || !within(world,state.entity,rig)) {continue}
        if state.error!=.None && state.error!=.Unknown_Target || int(state.rig)>=len(skin.rigs) || len(state.current)!=len(skin.rigs[state.rig].morphs) {authoring_failure(call,"morphs","Evaluation_Failed","resolved morph targets and finite final weights",fmt.tprintf("%v",state.error),"A morph instance could not be baked");return false}
        path:=""
        if config,found:=core.get(configs,state.entity);found {path=base.text_get(config.path[:])}
        if path=="" {if target,found:=core.get(targets,state.entity);found {path=base.text_get(target.path[:])}}
        for &target,i in skin.rigs[state.rig].morphs {
            name:=fmt.tprintf("%s/@morph/%s",path,base.text_get(target.name[:]))
            if len(name)>=asset.NODE_PATH_CAPACITY {authoring_failure(call,"morphs","Capacity",fmt.tprintf("morph curve targets shorter than %d bytes",asset.NODE_PATH_CAPACITY),name,"Shorten this mesh's animation path");return false}
            if !pose_bake_track(call,tracks,name,.Float,0,frames,morph=state.entity,morph_index=i) {return false}
        }
    }
    return true
}

@(private)
pose_bake_sample :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,p:^Pose_Bake_Params,preview:^Preview_Params,doc:^asset.Document,id:base.Asset_Id,existing:asset.Animation_View) -> bool {
    state:=pose_bake_state(world,entity)
    if state==nil {authoring_failure(call,"bake","Unbound_Pose","a ready pose after evaluation","unbound rig","The requested instance has no final pose to bake");return false}
    origin,error:=make([]mm.Transform,len(state.sampled),call.allocator)
    if error!=nil {authoring_failure(call,"bake","Out_Of_Memory","memory for the sampled root reference","allocation failed","The bake could not be prepared",api.SERVER_ERROR);return false};copy(origin,state.sampled[:])
    sources:=core.world_storage_of(core.world_ref(s.app.shared,world.info,.Shared),anim.Source_Assets)
    trace:Preview_Trace;defer preview_trace_sources_close(&trace)
    source_file:Authoring_File;defer asset.asset_close(&source_file.file)
    animation,_:=editor.entity_get(world,entity,anim.Animation)
    if animation.asset!={} {
        valid:bool;trace.primary,valid=program_source(s,call,animation.asset,animation.library);if !valid {return false}
        // A .character of only modifiers has no clips.
        if trace.primary!={} {trace.view,valid=program_animation_open(s,call,trace.primary,&source_file);if !valid {return false}}
    }
    tracks:=make([dynamic]Pose_Bake_Track,call.allocator);frames:=int(preview.ticks)+1
    skeleton:^anim.Skeleton_Content
    if state.skeleton!={} {cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets);skeleton=anim.skeleton_content(cache,s.app.assets,s.app.allocator,state.skeleton);if skeleton==nil {authoring_failure(call,"skeleton","Missing_Asset","the evaluated skeleton definition","missing skeleton","The skeleton paths could not be exported");return false}}
    for binding,b in state.bindings {
        path:=""
        if skeleton!=nil {if b==0 {if binding.driven=={} {continue}} else {if b>len(skeleton.bones) {return false};path=base.text_get(skeleton.bones[b-1].path[:])}} else if binding.entity!=entity {
            if target,found:=editor.entity_get(world,binding.entity,anim.Animation_Target);found {path=base.text_get(target.path[:])} else {path=core.name_get(core.world_table_of(world,core.Name),binding.entity)}
            if path=="" || base.name_hash(path)!=binding.target {authoring_failure(call,"bones","Missing_Path","Animation_Target paths for all rigid nodes",path,"Assign a path before baking this node");return false}
        }
        for property in 0..<3 {if !pose_bake_track(call,&tracks,path,lib.Property(property),0,frames,bone=b) {return false}}
    }
    root:=Pose_Bake_Root_State{turned=1};markers:=make([dynamic]asset.Animation_Marker_Desc,call.allocator)
    root_metadata:asset.Animation_Root
    previous:f32
    cursor:u64 // of the event log, which keeps the steps before: frame 0 skips what the seek pushed
    for frame in 0..<frames {
        time:=min(f32(frame)/p.rate,p.end-p.start)
        if frame>0 {
            if !request_tick(call,world,entity,preview,u32(frame)) {return false}
            if !pose_bake_evaluate(call,world,s.app,time-previous) {return false}
            state=pose_bake_state(world,entity);if state==nil {authoring_failure(call,"bake","Unbound_Pose","a ready pose at every sample",fmt.tprintf("frame %d",frame),"The rig became unbound while baking");return false}
        }
        content:=anim.animation_playing_content(sources,s.app,state)
        if !preview_trace_sources_prepare(call,&trace,sources,state,content,s.app.assets) {return false}
        for curve in state.curves {
            name:=preview_curve_name(&trace,curve.target)
            if name[0]==0 {authoring_failure(call,"curves","Missing_Name","a source name for each composed curve",fmt.tprintf("%x",curve.target),"A curve name could not be resolved");return false}
            if !pose_bake_track(call,&tracks,base.text_get(name[:]),curve.property,curve.slot,frames) {return false}
        }
        modifiers:=core.world_storage_of(world,anim.Modifier_Runtime)
        if modifiers!=nil {for &value in modifiers.correctives.values {if value.rig!=entity || value.curve[0]==0 {continue};if !pose_bake_track(call,&tracks,base.text_get(value.curve[:]),.Float,0,frames) {return false}}}
        if !pose_bake_morph_tracks(call,world,s.app,entity,&tracks,frames) {return false}
        baked_root,valid:=pose_bake_root(call,world,state,&root,origin,p.root_motion);if !valid {return false}
        for &track in tracks {
            value:mm.Vec4
            if track.bone>=0 {
                local:=baked_root if root.ready && track.bone==root.bone else state.local[track.bone]
                #partial switch track.desc.property {case .Position:value={local.position.x,local.position.y,local.position.z,0};case .Rotation:value=lib.quat_vec4(local.rotation);case .Scale:value={local.scale.x,local.scale.y,local.scale.z,0}}
            } else if track.morph!=core.NONE {
                morph,ready:=anim.animation_morph_state(core.world_storage_of(world,anim.Morph_Playback),track.morph)
                if !ready || track.morph_index>=len(morph.weights) {authoring_failure(call,"morphs","Evaluation_Failed","weights for every baked target","missing weights","A morph instance stopped being evaluated while baking");return false}
                value.x=morph.weights[track.morph_index]
            } else {
                for curve in state.curves {if curve.target==track.hash && curve.property==track.desc.property && curve.slot==track.desc.slot {value=curve.value;break}}
                if track.desc.property==.Float && track.desc.slot==0 {value.x+=anim.animation_corrective_curve(modifiers,entity,track.hash)}
            }
            track.desc.keys[frame]={time=time,value=value}
        }
        if root.ready && p.root_motion==.Preserve {
            for track in tracks {if track.bone==root.bone {base.text_set(root_metadata.bone[:],track.desc.target);break}}
            root_metadata.translation,root_metadata.rotation=root.root.translation,root.root.rotation
        }
        if events:=core.world_storage_of(world,anim.Animation_Events);events!=nil {crossed,_:=core.log_since(events.queue.log,&cursor);if frame>0 {for event in crossed {
            if event.entity!=entity || event.kind!=.Marker {continue}
            name:=preview_marker_name(preview_trace_source_view(&trace,event.animation),event.name)
            if name[0]==0 {authoring_failure(call,"markers","Missing_Name","a source name for every crossed marker",fmt.tprintf("%x",event.name),"A marker name could not be resolved");return false}
            label:=base.text_get(name[:]);owned:=strings.clone(label,call.allocator)
            if len(owned)!=len(label) || len(markers)>=asset.ANIMATION_MAX_MARKERS || append(&markers,asset.Animation_Marker_Desc{time=previous+(time-previous)*event.fraction,name=owned})!=1 {authoring_failure(call,"markers","Capacity","memory and capacity for crossed markers","full marker buffer","The baked markers could not be stored",api.SERVER_ERROR);return false}
        }}}
        previous=time
    }
    slice.sort_by(markers[:],proc(a,b:asset.Animation_Marker_Desc) -> bool {return a.time<b.time})
    descriptions,allocation:=make([]asset.Animation_Track_Desc,len(tracks),call.allocator);if allocation!=nil {authoring_failure(call,"bake","Out_Of_Memory","memory for track descriptions","allocation failed","The bake output could not be prepared",api.SERVER_ERROR);return false}
    for track,i in tracks {descriptions[i]=track.desc}
    clip:=asset.Animation_Clip_Desc{name=base.text_get(p.clip[:]),tracks=descriptions,markers=markers[:],root=root_metadata}
    clips,prepared:=authoring_clip_descs(existing,call);if !prepared {return false}
    at:=len(clips);for value,i in clips {if value.name==clip.name {at=i;break}}
    replaced:bool;clips,replaced=authoring_replace_row(clips,at,clip,false,asset.ANIMATION_MAX_CLIPS,call.allocator)
    if !replaced {authoring_failure(call,"clips","Capacity","memory and capacity for the output clip","full or allocation failed","The baked clip could not be stored",api.SERVER_ERROR);return false}
    if result:=asset.animation_document(doc,&s.app.assets.types,{id=id,clips=clips,source=existing.source},s.app.allocator);result!=.None {authoring_failure(call,"bake","Invalid_Output","finite sampled tracks within asset capacities",fmt.tprintf("%v",result),"The baked animation could not be prepared",api.SERVER_ERROR);return false}
    return true
}
