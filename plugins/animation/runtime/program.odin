package anim

import cmath "core:math"
import "core:mem"
import aa "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// The program of an Animation whose asset is a .character with locomotion: the clips the search
// picked, played together in phase when they are a blended sample, entered through an inertial
// transition. The layers of the set go over the pose it gives.
PROGRAM_LEAVES :: MATCH_BLEND
PROGRAM_PLAYERS :: PROGRAM_LEAVES*2
Program_Leaf :: struct {clip:u64,key:u32,weight,speed:f32,loop,sync:bool,player:u8,start:f32}
Program_Output :: struct {asset:base.Asset_Id,leaves:[PROGRAM_LEAVES]Program_Leaf,count:u8,normalized,mirror:bool}
Program_Player :: struct {key:u32,player:lib.Player,seen:u64,from,to:f32,active_last:bool}
// Pending: a source still loads (host.content_animation_pending); nothing plays until it is ready.
Program_Error :: enum u8 {None,Invalid_Asset,Invalid_Parameter,Missing_Clip,Incompatible_Root,Out_Of_Memory,Capacity,Pending}
Program_Playing :: struct {
    error:Program_Error,
    asset:base.Asset_Id,
    library:base.Asset_Id,        // the .anim the program plays
    revision:u64,
    checked:u64,
    kind:aa.Fourcc,  // of its asset
    matched:bool,    // its asset is a .character with locomotion
    players:[dynamic]Program_Player,
    leader:u32,
    frame:u64,
    root:Root_Motion,
    has_root,ready:bool,
    current_phase:lib.Sync_Phase,
    output:Program_Output,
    transition:f32, // negative: cut
    epoch:u16,
    match:Match_Playing,
}

// The program an Animation plays this tick, when its asset is a .character with locomotion.
// problems: where what its locomotion cannot do is reported.
@(private)
program_resolve :: proc(state:^Playing,animation:Animation,app:^host.App,characters:^Character_Assets,dt:f32,events:^Animation_Events=nil,playback:^Playback=nil,prepared:^host.Content_Animation=nil,problems:^core.Problems=nil,goals:[]Match_Goal={},facing:=mm.FORWARD) -> (output:^Program_Output,programmed,ok:bool) {
    if app.assets==nil {return nil,false,false}
    runtime:=&state.program
    runtime.error=.None
    defer {if programmed && !ok && runtime.error==.None {runtime.error=.Invalid_Asset}}
    kind:=runtime.kind
    if runtime.asset!=animation.asset || runtime.checked!=assets_stamp(app.assets) {
        record,found:=aa.registry_find(&app.assets.registry,animation.asset)
        kind=record.kind if found else aa.Fourcc(0)
        runtime.kind,runtime.checked=kind,assets_stamp(app.assets)
    }
    content:^Character_Content
    if kind==CHARACTER_KIND {content=character_content(characters,app.assets,app.allocator,animation.asset);if content==nil {runtime.error=.Invalid_Asset;return nil,true,false}}
    if content==nil || len(content.set.match.clips)==0 {
        if runtime.matched || len(runtime.players)>0 {program_free(runtime)}
        runtime.kind,runtime.asset,runtime.checked=kind,animation.asset,assets_stamp(app.assets)
        return nil,false,true
    }
    programmed=true
    runtime.matched=true
    if animation.library!={} {
        record,found:=aa.registry_find(&app.assets.registry,animation.library)
        if !found || record.kind!=aa.KIND_ANIMATION {runtime.error=.Invalid_Asset;return nil,true,false}
    }
    output=&runtime.output
    source:=animation.library if animation.library!={} else content.set.info.animation
    revision:=content.revision
    reset:=runtime.asset!=animation.asset || runtime.revision!=revision || runtime.library!=source || !runtime.ready
    swapped:=reset && runtime.ready && runtime.asset==animation.asset && runtime.revision==revision
    if reset {runtime.match=match_swapped(runtime.match) if swapped else MATCH_PLAYING_DEFAULT}
    ok=match_output(state,output,content,prepared if prepared!=nil else host.content_animation(app,source),source,dt,goals,facing,app.assets,app.allocator,problems,playback_searched(playback,state))
    if reset {
        mem.zero_slice(runtime.players[:])
        runtime.epoch=0
        // A swapped library enters its clip through the capture match_output asked for.
        if !swapped {runtime.transition=-1}
    }
    if !ok {return nil,true,false}
    output.asset=source
    for &leaf in output.leaves[:output.count] {leaf.key+=u32(runtime.epoch)<<16}
    runtime.asset,runtime.revision,runtime.library=animation.asset,revision,source
    runtime.ready=ok
    return
}
@(private)
program_free :: proc(runtime:^Program_Playing) {
    delete(runtime.players)
    runtime^={}
}

@(private)
program_player_find :: proc(runtime:^Program_Playing,key:u32) -> int {
    for player,i in runtime.players {if player.seen!=0 && player.key==key {return i}}
    for player,i in runtime.players {if player.seen==0 {return i}}
    oldest:=-1
    for player,i in runtime.players {if player.seen!=runtime.frame && (oldest<0 || player.seen<runtime.players[oldest].seen) {oldest=i}}
    if oldest>=0 {return oldest}
    return -1
}

program_players :: proc(state:^Playing,output:^Program_Output,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,playback:^Playback,dt,sought:f32,problems:^core.Problems,distance:^Animation_Distance_Request=nil) -> bool {
    runtime:=&state.program
    runtime.error=.None
    if output.count==0 || output.count>PROGRAM_LEAVES {runtime.error=.Capacity;return false}
    leaves:=output.leaves[:output.count]
    root:Root_Motion
    has_root:=false
    leader,representative,dominant:=0,-1,0
    handles:[PROGRAM_LEAVES]lib.Clip
    for leaf,i in leaves {
        index:=int(lib.clip_find(&content.lib,leaf.clip))-1
        if index<0 || index>=content.clip_count {runtime.error=.Missing_Clip;return false}
        if !finite(leaf.speed*animation.speed) {runtime.error=.Invalid_Parameter;return false}
        handles[i]=lib.Clip(index+1+(content.clip_count if leaf.loop else 0))
        if leaf.weight>leaves[leader].weight {leader=i}
        if leaf.weight>leaves[dominant].weight || leaf.weight==leaves[dominant].weight && leaf.key<leaves[dominant].key {dominant=i}
        if leaf.weight<=0 || animation.root_motion==.None || index>=len(content.roots) {continue}
        meta:=content.roots[index]
        if !meta.translation && !meta.rotation {continue}
        if has_root && (root.bone!=bone_ref_hash({meta.bone}) || root.translation!=meta.translation || root.rotation!=meta.rotation) {runtime.error=.Incompatible_Root;return false}
        root={bone=bone_ref_hash({meta.bone}),translation=meta.translation,rotation=meta.rotation,in_place=animation.root_motion==.In_Place}
        has_root=true
        if representative<0 || leaf.weight>leaves[representative].weight {representative=i}
    }
    if representative<0 {representative=leader}
    if !program_array_resize(&runtime.players,PROGRAM_PLAYERS) {runtime.error=.Out_Of_Memory;return false}
    rising:=animation.playing && !state.was_playing
    previous:lib.Player
    for slot in runtime.players {
        if slot.seen!=0 && slot.key==runtime.leader && slot.key>>16==leaves[0].key>>16 {previous=slot.player;break}
    }
    if rising && previous.done {lib.player_restart(&content.lib,&previous)}
    phase,valid:=lib.sync_phase(&content.lib,previous)
    if previous.done || output.normalized {phase.markers=false}

    runtime.frame+=1
    runtime.root=root
    runtime.has_root=has_root
    for leaf in leaves {
        for &slot in runtime.players {
            if slot.seen!=0 && slot.key==leaf.key {
                slot.active_last=slot.seen==runtime.frame-1
                slot.seen=runtime.frame
                break
            }
        }
    }
    duration,total:f32
    for &leaf,i in leaves {
        at:=program_player_find(runtime,leaf.key)
        if at<0 {runtime.error=.Capacity;return false}
        slot:=&runtime.players[at]
        if slot.seen==0 || slot.key!=leaf.key || slot.player.clip!=handles[i] || !slot.active_last {
            player:=lib.player_make(handles[i],leaf.speed*animation.speed)
            lib.player_restart(&content.lib,&player)
            if leaf.sync && valid {
                lib.player_synchronize(&content.lib,&player,phase)
                player.done=previous.done && !leaf.loop
            } else if leaf.start>0 {player.time=leaf.start}
            slot^={key=leaf.key,player=player,active_last=true}
        }
        slot.player.speed,slot.player.weight=leaf.speed*animation.speed,1
        if rising && slot.player.done {lib.player_restart(&content.lib,&slot.player)}
        if sought>=0 {slot.player.time=sought;slot.player.done,slot.player.fresh=false,false}
        slot.seen=runtime.frame
        leaf.player=u8(at)
        if output.normalized {
            duration+=lib.clip_duration(&content.lib,handles[i])*leaf.weight/max(abs(leaf.speed),1e-6)
            total+=leaf.weight
        }
    }
    if total>0 {duration/=total}
    lead:=&runtime.players[leaves[leader].player]
    scale:=f32(1)
    if leaves[leader].sync && duration>0 {
        scale=lib.clip_duration(&content.lib,lead.player.clip)/(duration*max(abs(leaves[leader].speed),1e-6))
    }
    clock_dt:=dt
    selected:=-1
    distance_dt:=dt
    if distance!=nil {
        name:=source_clip_name(content.id,distance.animation,distance.clip)
        for leaf,i in leaves {
            if leaf.clip==name && (selected<0 || leaf.weight>leaves[selected].weight) {selected=i}
        }
        if selected<0 {runtime.error=.Invalid_Parameter;return false}
        sample:=&runtime.players[leaves[selected].player].player
        synced:=leaves[selected].sync
        target:=sample^
        target.time,target.done=distance.time,false
        phase,valid:=lib.sync_phase(&content.lib,target)
        if !valid {runtime.error=.Invalid_Parameter;return false}
        if output.normalized {phase.markers=false}
        if distance.seek {
            if synced {
                for leaf in leaves {if leaf.sync {lib.player_synchronize(&content.lib,&runtime.players[leaf.player].player,phase)}}
                clock_dt=0
            } else {
                sample.time=distance.time
                sample.done,sample.fresh=false,false
                distance_dt=0
            }
        } else {
            clock:=&lead.player if synced else sample
            at:=distance.time
            if clock.clip!=sample.clip {
                converted,found:=lib.sync_time(&content.lib,clock.clip,phase)
                if !found {runtime.error=.Invalid_Parameter;return false}
                at=converted
            }
            if at<clock.time {
                if lib.clip_data(&content.lib,clock.clip).loop!=.Loop {runtime.error=.Invalid_Parameter;return false}
                at+=lib.clip_duration(&content.lib,clock.clip)
            }
            if clock.speed<=0 {runtime.error=.Invalid_Parameter;return false}
            if synced {clock_dt=(at-clock.time)/(clock.speed*scale)} else {distance_dt=(at-clock.time)/clock.speed}
        }
    }
    state.motion=ROOT_DELTA_DEFAULT
    state.root_enabled=has_root
    root_bone:=bone_target(state,root.bone) if has_root else 0
    phase,valid=lib.sync_phase(&content.lib,lead.player)
    if lead.player.done || output.normalized {phase.markers=false}
    for step in 0..<len(leaves) {
        i:=leader if step==0 else step-1 if step<=leader else step
        leaf:=leaves[i]
        slot:=&runtime.players[leaf.player]
        player:=&slot.player
        follows:=i!=leader && leaf.sync && valid
        if follows {lib.player_synchronize(&content.lib,player,phase)}
        from:=player.time
        to:=from
        was_done:=player.done
        batch:[EVENT_BATCH]lib.Event
        written,dropped:int
        if follows {
            next,found:=lib.sync_phase(&content.lib,lead.player)
            if lead.player.done || output.normalized {next.markers=false}
            if found {lib.player_synchronize(&content.lib,player,next)}
            to=player.time
            lead_duration:=lib.clip_duration(&content.lib,lead.player.clip)
            if animation.playing && lib.clip_data(&content.lib,lead.player.clip).loop==.Loop && leaf.loop && lead_duration>0 {
                to+=(cmath.floor(lead.to/lead_duration)-cmath.floor(lead.from/lead_duration))*lib.clip_duration(&content.lib,player.clip)
            }
            player.done=lead.player.done
        } else if animation.playing {
            advance:=dt
            if leaf.sync {advance=clock_dt*(scale if i==leader else 1)} else if i==selected {advance=distance_dt}
            to=from+advance*player.speed
            if !finite(to) {runtime.error=.Invalid_Parameter;return false}
            written,dropped=lib.player_advance(&content.lib,player,advance,batch[:])
        }
        share:=leaf.weight*mm.saturate(animation.weight)
        if animation.event_policy!=.Dominant || i==dominant {emit_events(playback,events,state.entity,content,batch[:written],dropped,problems,share,leaf.key,0,animation)}
        slot.from,slot.to=from,to
        if has_root && animation.playing && sought<0 && !(distance!=nil && distance.seek) && !was_done {
            moved,turned:=lib.clip_root_motion(&content.lib,player.clip,root_bone,from,to)
            moved,turned=root_motion_to_rig(state,root_bone,moved,turned)
            if root.translation {state.motion.translation+=moved*share}
            if root.rotation {state.motion.rotation*=mm.quat_slerp(1,turned,share)}
        }
    }
    runtime.leader=lead.key
    current:=runtime.players[leaves[representative].player].player
    state.time=lib.player_time(&content.lib,current)
    state.duration=lib.clip_duration(&content.lib,current.clip)
    state.ended=current.done
    state.clip=int(current.clip-1)%content.clip_count
    state.fader.current=current
    runtime.current_phase,_=lib.sync_phase(&content.lib,current)
    if output.normalized {runtime.current_phase.markers=false}
    if output.mirror {state.motion=root_delta_mirror(state.mirror_plane,state.motion)}
    state.was_playing=animation.playing
    return true
}

@(private)
program_pose :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,output:^Program_Output,worker:=0) -> bool {
    runtime:=&state.program
    scratch,bones,shared,ready:=pose_room(playback,state,worker)
    if !ready {runtime.error=.Out_Of_Memory;return false}
    share:=mm.saturate(animation.weight)
    for &curve in state.curves {curve.value,curve.weight={},0}
    for leaf in output.leaves[:output.count] {
        player:=runtime.players[leaf.player].player
        lib.bones_blend(bones,shared.bones[:],&content.lib,player,leaf.weight)
        curves_accumulate(state.curves[:],&content.lib,player,leaf.weight*share)
    }
    tracks_twins(shared,bones)
    pose:=scratch.pose[:len(state.bindings)]
    rest:=playing_topology(state).rest
    for reference,b in rest {pose[b],_,_=lib.bone_transform(bones[b],reference)}
    if output.mirror && !playing_mirror(state,pose,scratch.pose[len(pose):]) {runtime.error=.Invalid_Parameter;return false}
    for value,b in pose {
        if state.bindings[b].target!=0 {playing_pose(state,.Local)[b]=mm.transform_interpolate(rest[b],value,share)}
    }
    return true
}

@(private)
program_array_reserve :: proc(array:^[dynamic]$T,count:int) -> bool {
    if cap(array^)>=count {return true}
    if cap(array^)>0 {return reserve(array,count)==nil}
    next,error:=make([dynamic]T,0,count)
    if error!=nil {delete(next);return false}
    array^=next
    return true
}
@(private)
program_array_resize :: proc(array:^[dynamic]$T,count:int) -> bool {
    if !program_array_reserve(array,count) {return false}
    return resize(array,count)==nil
}
// A copy of the rows of an asset, which its view lends, in the memory of allocator.
@(private)
rows_clone :: proc(source:[]$T,allocator:mem.Allocator) -> ([]T,bool) {
    out,error:=make([]T,len(source),allocator);if error!=nil {return nil,false};copy(out,source);return out,true
}
