package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

PREVIEW_TRACE_TOTAL :: 1024 // rows of leaves, events and curves of every traced tick
PREVIEW_TRACE_ROWS :: 256
Preview_Program_Result :: struct {
    asset:base.Asset_Id,ready:bool,
    fade_remaining:f32 `mirai:"unit=s,label=Of the inertial blend into the last clip matching jumped to or a play"`,
    error:anim.Program_Error,
    parameters:[]anim.Stack_Parameter_Info `mirai:"label=What its .character declares: the weight of each layer and the axes of their spaces, at the value they have"`,
    match:Preview_Match_Result `mirai:"optional,label=The locomotion of its .character: what its matching plays"`,
}
// clip: of the library of the .character; mode: the Locomotion_Mode it serves; forced: a play of
// animation.request plays it; rate: of the clip to follow the body; speed: that the pose walks at.
// In animation.inspect a rig without matching holds only available, code and reason.
Preview_Match_Result :: struct {
    available:bool `mirai:"optional,label=false when the entity plays no locomotion of a .character"`,
    clip:[64]u8 `mirai:"text,optional"`,mode:[32]u8 `mirai:"text,optional"`,forced:bool `mirai:"optional"`,
    time:f32 `mirai:"optional,unit=s"`,rate:f32 `mirai:"optional"`,speed:f32 `mirai:"optional,unit=m/s"`,cost:f32 `mirai:"optional"`,
    searches,jumps:u32 `mirai:"optional"`,
}
Preview_Pose_Result :: struct {id:base.Entity_Id,path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`,name:[64]u8 `mirai:"text"`,position,scale:mm.Vec3,rotation:[4]f32}
Preview_Leaf_Source :: enum u8 {Base,Program,Layer}
Preview_Leaf_Result :: struct {clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id,source:Preview_Leaf_Source,key:u32,group:u16,layer:u8,outgoing:bool,weight,time,phase,duration:f32,sync_mode:anim.Sync_Mode}
// An event of Animation_Events in the tick. Marker: marker of clip; the others are of action, and
// name is its section, or for Span_Begin and Span_End its window.
Preview_Marker_Result :: struct {kind:anim.Animation_Event_Kind,action,name:[64]u8 `mirai:"text,optional"`,clip,marker:[64]u8 `mirai:"text,optional"`,animation:base.Asset_Id,clip_hash,marker_hash:u64,time,weight:f32,source:u32,group:u16}
Preview_Curve_Result :: struct {target:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`,target_hash:u64,property:lib.Property,slot:u8,value:mm.Vec4,weight:f32}
Preview_Root_Result :: struct {translation:mm.Vec3,rotation:mm.Quat}
// problems: those the preview reported on the entity, the most recent first.
Preview_Diagnostics :: struct {program:anim.Program_Error,skipped:u64,modifiers_last_request_error:anim.Modifier_Request_Error,motion:anim.Motion_Error,problems:[PREVIEW_PROBLEMS]Problem_Result,problems_total:u32}
Preview_Trace_Result :: struct {
    tick:u32,dt,time,duration:f32,ended:bool,program:Preview_Program_Result,
    leaves_total,events_total,curves_total:u32,
    leaves:[]Preview_Leaf_Result,events:[]Preview_Marker_Result,curves:[]Preview_Curve_Result,
    root_delta:Preview_Root_Result,root_enabled:bool,diagnostics:Preview_Diagnostics,
}
Preview_Result :: struct {id:base.Entity_Id,time:f32,ended:bool,program:Preview_Program_Result,poses:[]Preview_Pose_Result,total,shown:u32,trace:[]Preview_Trace_Result,trace_total,trace_shown:u32,trace_truncated:bool}
Preview_Trace_Source :: struct {id:base.Asset_Id,file:asset.Asset,view:asset.Animation_View}
Preview_Trace :: struct {frames:[dynamic]Preview_Trace_Result,rows:int,view:asset.Animation_View,primary:base.Asset_Id,sources:[anim.ANIMATION_SOURCES]Preview_Trace_Source,source_count:int,source_generation:u32,shown:u32,truncated:bool}

@(private)
preview_trace_sources_close :: proc(trace:^Preview_Trace) {
    for &source in trace.sources[:trace.source_count] {asset.asset_close(&source.file);source={}}
    trace.source_count,trace.source_generation=0,0
}
@(private)
preview_trace_sources_prepare :: proc(call:^api.Call,trace:^Preview_Trace,cache:^anim.Source_Assets,state:^anim.Playing,content:^host.Content_Animation,assets:^host.Assets) -> bool {
    ids:=anim.source_ids(cache,state)
    if content==nil || len(ids)==0 || trace.source_generation==content.generation {return true}
    preview_trace_sources_close(trace)
    if trace.primary=={} {trace.primary=content.id}
    for id in ids {
        if id==trace.primary {continue}
        found:=false;for source in trace.sources[:trace.source_count] {if source.id==id {found=true;break}}
        if found {continue}
        if trace.source_count>=len(trace.sources) {authoring_failure(call,"trace.sources","Capacity","at most 64 animation sources","too many sources","The preview metadata exceeds its source capacity",api.SERVER_ERROR);return false}
        source:=&trace.sources[trace.source_count]
        error:=host.assets_file(assets,id,asset.KIND_ANIMATION,&source.file)
        if error==.None {source.view,error=asset.animation_view(&source.file,&assets.types)}
        if error!=.None {asset.asset_close(&source.file);authoring_failure(call,"trace.sources","Invalid_Asset","readable animation source metadata","source load failed","The preview could not read its animation source metadata",api.SERVER_ERROR);return false}
        source.id=id;trace.source_count+=1
    }
    trace.source_generation=content.generation
    return true
}
@(private)
preview_trace_source_view :: proc(trace:^Preview_Trace,id:base.Asset_Id) -> asset.Animation_View {
    if id=={} || id==trace.primary {return trace.view}
    for source in trace.sources[:trace.source_count] {if source.id==id {return source.view}}
    return {}
}

@(private)
preview_clip_name :: proc(view:asset.Animation_View,hash:u64) -> [64]u8 {for &clip in view.clips {if base.name_hash(base.text_get(clip.name[:]))==hash {return clip.name}};return {}}
@(private)
preview_marker_name :: proc(view:asset.Animation_View,hash:u64) -> [64]u8 {for &marker in view.markers {if base.name_hash(base.text_get(marker.name[:]))==hash {return marker.name}};return {}}
@(private)
preview_curve_name :: proc(trace:^Preview_Trace,hash:u64) -> [asset.NODE_PATH_CAPACITY]u8 {
    for &track in trace.view.tracks {if base.name_hash(base.text_get(track.target[:]))==hash {return track.target}}
    for source in trace.sources[:trace.source_count] {for &track in source.view.tracks {if base.name_hash(base.text_get(track.target[:]))==hash {return track.target}}}
    return {}
}
// What the matching of an entity plays, with the names of its clip and mode; false for an entity
// that plays no locomotion of a .character.
@(private)
preview_match :: proc(world:core.World_Ref,app:^host.App,entity:core.Entity) -> (result:Preview_Match_Result,ok:bool) {
    playback:=core.world_storage_of(world,anim.Playback)
    value,matching:=anim.animation_match(playback,entity);if !matching {return}
    result={available=true,forced=value.forced,time=value.time,rate=value.rate,speed=value.speed,cost=value.cost,searches=value.searches,jumps=value.jumps}
    for &state in playback.states {
        if state.entity!=entity {continue}
        content:=anim.animation_playing_content(core.world_storage_of(core.world_ref(app.shared,world.info,.Shared),anim.Source_Assets),app,&state)
        if content!=nil {if clip:=lib.clip_find(&content.lib,value.clip);clip!=0 {result.clip=anim.source_clip_label(content,clip)}}
        break
    }
    name,named:=locomotion_mode_name(locomotion_modes(world.info),value.mode)
    base.text_set(result.mode[:],name if named else fmt.tprintf("%d",value.mode))
    return result,true
}
@(private)
preview_program :: proc(call:^api.Call,world:core.World_Ref,app:^host.App,state:^anim.Playing,animation:anim.Animation) -> (r:Preview_Program_Result) {
    r.asset=animation.asset
    if state==nil {return}
    runtime:=&state.program;r.ready,r.error,r.fade_remaining=runtime.ready,runtime.error,max(0,runtime.fade-runtime.elapsed)
    parameters:=make([]anim.Stack_Parameter_Info,anim.STACK_PARAMETERS*2,call.allocator)
    characters:=core.world_storage_of(core.world_ref(app.shared,world.info,.Shared),anim.Character_Assets)
    r.parameters=parameters[:anim.stack_parameters(core.world_storage_of(world,anim.Action_Runtime),characters,core.world_storage_of(world,anim.Playback),state.entity,parameters)]
    if match,ok:=preview_match(world,app,state.entity);ok {r.match=match}
    return
}
@(private)
preview_leaf :: proc(cache:^anim.Source_Assets,state:^anim.Playing,content:^host.Content_Animation,player:lib.Player,source:Preview_Leaf_Source,key:u32,group:u16,layer:u8,outgoing:bool,weight:f32,mode:anim.Sync_Mode) -> Preview_Leaf_Result {
    value:=Preview_Leaf_Result{source=source,key=key,group=group,layer=layer,outgoing=outgoing,weight=weight,sync_mode=mode}
    if content!=nil && lib.clip_valid(&content.lib,player.clip) {value.clip=anim.source_clip_label(content,player.clip);value.animation=anim.source_clip_source(cache,state,player.clip);value.time=lib.player_time(&content.lib,player);value.phase=lib.player_normalized(&content.lib,player);value.duration=lib.clip_duration(&content.lib,player.clip)}
    return value
}
@(private)
preview_trace_frame :: proc(call:^api.Call,trace:^Preview_Trace,world:core.World_Ref,entity:core.Entity,p:^Preview_Params,tick:u32,app:^host.App) -> bool {
    if !p.trace || tick<p.trace_offset || len(trace.frames)>=int(p.trace_limit) || trace.truncated {return true}
    playback:=core.world_storage_of(world,anim.Playback);if playback==nil {return true}
    state:^anim.Playing;for &value in playback.states {if value.entity==entity {state=&value;break}}
    if state==nil {return true}
    description,_:=editor.entity_get(world,entity,anim.Animation);sources:=core.world_storage_of(core.world_ref(app.shared,world.info,.Shared),anim.Source_Assets);content:=anim.animation_playing_content(sources,app,state)
    if !preview_trace_sources_prepare(call,trace,sources,state,content,app.assets) {return false}
    r:=Preview_Trace_Result{tick=tick,dt=p.dt if tick>0 else 0,time=state.time,duration=state.duration,ended=state.ended,program=preview_program(call,world,app,state,description)}
    leaves:=make([dynamic]Preview_Leaf_Result,call.allocator)
    total:=0
    if state.program.ready {
        runtime:=&state.program;output:=&runtime.output
        for &group,g in output.groups[:output.count] {for leaf in group.leaves[:group.count] {
            total+=1;if len(leaves)>=PREVIEW_TRACE_ROWS {continue};player:lib.Player
            for slot in runtime.players {if slot.key==leaf.key {player=slot.player;break}}
            append(&leaves,preview_leaf(sources,state,content,player,.Program,leaf.key,u16(g),0,false,leaf.weight*group.weight*description.weight,group.mode))
        }}
    } else if state.clip>=0 {total+=1;append(&leaves,preview_leaf(sources,state,content,state.fader.current,.Base,0,0,0,false,lib.fader_current_weight(state.fader)*description.weight,.Independent))
        for outgoing in state.fader.outgoing[:state.fader.outgoing_count] {total+=1;if len(leaves)>=PREVIEW_TRACE_ROWS {continue};append(&leaves,preview_leaf(sources,state,content,outgoing.player,.Base,0,0,0,true,lib.fade_out_weight(outgoing)*description.weight,.Independent))}
    }
    actions:=core.world_storage_of(world,anim.Action_Runtime)
    for &layer,i in state.layers[:state.stack] {
        asked:=state.asked[i]
        if layer.weight<=0 {continue}
        players:[anim.LAYER_PLAYERS]lib.Player
        for player,k in players[:anim.layer_players(&layer,&players)] {
            total+=1;if len(leaves)>=PREVIEW_TRACE_ROWS {continue}
            append(&leaves,preview_leaf(sources,state,content,player,.Layer,u32(i),0,u8(i),k>0 && layer.leaf_count==0,player.weight*layer.weight*description.weight,.Markers if asked.sync else .Independent))
        }
    }
    r.leaves,r.leaves_total=leaves[:],u32(total)
    marks:=make([dynamic]Preview_Marker_Result,call.allocator)
    total=0
    events:=core.world_storage_of(world,anim.Animation_Events)
    if events!=nil {for event in events.items {
        if event.entity!=entity {continue}
        total+=1;if len(marks)>=PREVIEW_TRACE_ROWS {continue}
        value:=Preview_Marker_Result{kind=event.kind,animation=event.animation,clip_hash=event.clip,time=event.time,weight=event.weight,source=event.source,group=event.group}
        if event.kind==.Marker {view:=preview_trace_source_view(trace,event.animation);value.clip,value.marker,value.marker_hash=preview_clip_name(view,event.clip),preview_marker_name(view,event.name),event.name}
        if actions!=nil && event.action!=0 {for &plan in actions.plans {
            if plan.asset!=description.asset {continue}
            for &action in plan.profile.actions {if base.name_hash(base.text_get(action.name[:]))==event.action {value.action=action.name}}
            if event.kind==.Span_Begin || event.kind==.Span_End {value.name=preview_marker_name(preview_trace_source_view(trace,plan.animation),event.name)} else if event.kind!=.Marker {for &section in plan.profile.sections {if base.name_hash(base.text_get(section.name[:]))==event.name {value.name=section.name}}}
        }}
        append(&marks,value)
    }}
    r.events,r.events_total=marks[:],u32(total)
    r.curves,r.curves_total=make([]Preview_Curve_Result,min(len(state.curves),PREVIEW_TRACE_ROWS),call.allocator),u32(len(state.curves))
    for &value,i in r.curves {curve:=state.curves[i];value={target=preview_curve_name(trace,curve.target),target_hash=curve.target,property=curve.property,slot=curve.slot,value=curve.value,weight=curve.weight}}
    r.root_delta,r.root_enabled={state.motion.translation,state.motion.rotation},state.root_enabled
    diagnostics:=Preview_Diagnostics{program=state.program.error,skipped=playback.stats.skipped}
    if modifiers:=core.world_storage_of(world,anim.Modifier_Runtime);modifiers!=nil {diagnostics.modifiers_last_request_error=anim.modifier_request_error(modifiers,entity)}
    _,problems_total:=entity_problems(app,world,entity,"",diagnostics.problems[:]);diagnostics.problems_total=u32(problems_total)
    if motion,ok:=anim.motion_inspect(core.world_storage_of(world,anim.Motion_Runtime),entity);ok {diagnostics.motion=motion.error}
    r.diagnostics=diagnostics
    rows:=len(r.leaves)+len(r.events)+len(r.curves)
    if trace.rows+rows>PREVIEW_TRACE_TOTAL {trace.truncated=true;return true}
    trace.rows+=rows
    append(&trace.frames,r)
    return true
}
@(private)
preview_trace_result :: proc(r:^Preview_Result,trace:^Preview_Trace,p:^Preview_Params) {
    r.trace,r.trace_shown=trace.frames[:],u32(len(trace.frames))
    r.trace_total=p.ticks+1 if p.trace else 0
    r.trace_truncated=trace.truncated || p.trace && u64(p.trace_offset)+u64(len(trace.frames))<u64(p.ticks)+1
}
