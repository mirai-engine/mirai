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
PROGRAM_GROUPS :: 1
// Clocks its groups keep between ticks: that of the group that plays, and the one of the clip it
// jumped from until the tick that leaves it ends.
PROGRAM_CLOCKS :: PROGRAM_GROUPS*2
PROGRAM_LEAVES :: MATCH_BLEND
PROGRAM_PLAYERS :: PROGRAM_GROUPS*PROGRAM_LEAVES*2
Sync_Mode :: enum u8 {Independent,Markers,Weighted,Fixed}
// start: seconds a new player of it starts at.
Program_Leaf :: struct {clip:u64,key:u32,weight,speed:f32,loop,sync:bool,player:u16,start:f32}
Program_Group :: struct {leaves:[PROGRAM_LEAVES]Program_Leaf,count:u8,weight,root_weight:f32,mode:Sync_Mode,duration:f32,key:u64}
// mirror: its pose and root motion play reflected across the plane of the rig, left and right swapped.
Program_Output :: struct {asset:base.Asset_Id,groups:[PROGRAM_GROUPS]Program_Group,count:u8,primary:u8,mirror:bool}
Program_Player :: struct {key:u32,player:lib.Player,seen,advanced:u64,from,to:f32,was_done,active_last:bool}
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
    leaders:[PROGRAM_CLOCKS]u32,
    leader_keys:[PROGRAM_CLOCKS]u64,
    frame:u64,
    from:[dynamic]mm.Transform,
    from_curves:[dynamic]Curve_Output,
    elapsed,fade:f32,
    root:Root_Motion,
    has_root,ready:bool,
    sampled,before:[dynamic]mm.Transform, // what its clips blend, and that pose a tick before
    sampled_curves:[dynamic]Curve_Output,
    last_dt:f32,
    current_phase:lib.Sync_Phase,
    output:Program_Output,
    history,current:[dynamic]mm.Transform,
    history_curves,prior_curves:[dynamic]Curve_Output,
    history_dt:f32,
    kept:bool, // current holds the pose of a tick
    inertia:lib.Inertial_State,
    inertia_bones:[dynamic]lib.Inertial_Bone,
    inertia_curves:[dynamic]lib.Inertial_Curve,
    inertia_values:[dynamic]f32,
    capture:bool,

    epoch:u16,
    match:Match_Playing,
}

@(private)
program_curves_prepare :: proc(runtime:^Program_Playing,count:int) -> bool {
    if len(runtime.from_curves)==count {return true}
    if cap(runtime.from_curves)==0 {
        curves,error:=make([dynamic]Curve_Output,count)
        if error!=nil {delete(curves);return false}
        runtime.from_curves=curves
        return true
    }
    return resize(&runtime.from_curves,count)==nil
}

@(private)
program_primary_group :: proc(output:^Program_Output,content:^host.Content_Animation,has_root:bool) -> u8 {
    primary:=output.primary
    if !has_root {return primary}
    greatest:f32=-1
    for group,g in output.groups[:output.count] {
        group:=group
        for leaf in group.leaves[:group.count] {
            index:=int(lib.clip_find(&content.lib,leaf.clip))-1
            if index>=0 && index<len(content.roots) {
                meta:=content.roots[index];amount:=leaf.weight*group.root_weight
                if (meta.translation || meta.rotation) && amount>greatest {greatest=amount;primary=u8(g)}
            }
        }
    }
    return primary
}
@(private)
program_representative :: proc(group:^Program_Group,content:^host.Content_Animation,has_root:bool) -> int {
    leader:=0
    for leaf,i in group.leaves[:group.count] {if leaf.weight>group.leaves[leader].weight {leader=i}}
    if has_root {
        best:f32=-1
        for leaf,i in group.leaves[:group.count] {
            index:=int(lib.clip_find(&content.lib,leaf.clip))-1
            if index>=0 && index<len(content.roots) && (content.roots[index].translation || content.roots[index].rotation) && leaf.weight>best {leader,best=i,leaf.weight}
        }
    }
    return leader
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
        program_free(runtime)
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
    ok=match_output(state,output,content,prepared if prepared!=nil else host.content_animation(app,source),source,dt,goals,facing,app.assets,app.allocator,problems)
    if reset {
        mem.zero_slice(runtime.players[:]);mem.zero_slice(runtime.leader_keys[:])
        runtime.epoch=0
        // A swapped library enters its clip through the capture match_output asked for.
        if !swapped {runtime.fade=0;runtime.capture=false;runtime.inertia={}}
    }
    if !ok {return nil,true,false}
    output.asset=source
    for &group in output.groups[:output.count] {
        group.key~=(u64(runtime.epoch)<<48)
        for &leaf in group.leaves[:group.count] {leaf.key+=u32(runtime.epoch)<<16}
    }
    runtime.asset,runtime.revision,runtime.library=animation.asset,revision,source
    runtime.ready=ok
    return
}
@(private)
program_free :: proc(runtime:^Program_Playing) {
    delete(runtime.players);delete(runtime.from);delete(runtime.from_curves)
    delete(runtime.sampled);delete(runtime.before);delete(runtime.sampled_curves)
    delete(runtime.history);delete(runtime.current);delete(runtime.history_curves);delete(runtime.prior_curves)
    delete(runtime.inertia_bones);delete(runtime.inertia_curves);delete(runtime.inertia_values)
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

@(private)
program_clock_find :: proc(runtime:^Program_Playing,key:u64) -> (index:int,existing:bool) {
    key:=key
    if key==0 {key=1}
    for stored,i in runtime.leader_keys {if stored==key {return i,true}}
    for stored,i in runtime.leader_keys {if stored==0 {runtime.leader_keys[i]=key;return i,false}}
    // None free: those kept are of clips a tick that failed left.
    runtime.leader_keys={0=key};runtime.leaders={}
    return 0,false
}

program_players :: proc(state:^Playing,output:^Program_Output,content:^host.Content_Animation,animation:Animation,events:^Animation_Events,playback:^Playback,dt,sought:f32,problems:^core.Problems,distance:^Animation_Distance_Request=nil) -> bool {
    runtime:=&state.program
    runtime.error=.None
    root:Root_Motion;has_root:=false
    for group in output.groups[:output.count] {
        group:=group
        for leaf in group.leaves[:group.count] {
            leaf:=leaf
            index:=int(lib.clip_find(&content.lib,leaf.clip))-1
            if index<0 || index>=content.clip_count {runtime.error=.Missing_Clip;return false}
            if !finite(leaf.speed*animation.speed) {runtime.error=.Invalid_Parameter;return false}
            policy:=animation.root_motion
            if group.root_weight<=0 || leaf.weight<=0 || policy==.None || index>=len(content.roots) {continue}
            meta:=content.roots[index]
            if !meta.translation && !meta.rotation {continue}
            if has_root && (root.bone.path!=meta.bone || root.translation!=meta.translation || root.rotation!=meta.rotation) {runtime.error=.Incompatible_Root;return false}
            root={bone={meta.bone},translation=meta.translation,rotation=meta.rotation,in_place=policy==.In_Place};has_root=true
        }
    }
    required:=0;for group in output.groups[:output.count] {required+=int(group.count)}
    if required>PROGRAM_PLAYERS {runtime.error=.Capacity;return false}
    if len(runtime.players)<required || len(runtime.players)==0 {
        players,error:=make([dynamic]Program_Player,min(PROGRAM_PLAYERS,max(32,required*2)))
        if error!=nil {delete(players);runtime.error=.Out_Of_Memory;return false}
        delete(runtime.players);runtime.players=players
    }
    output.primary=program_primary_group(output,content,has_root)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    runtime.frame+=1;runtime.root=root;runtime.has_root=has_root;runtime.last_dt=dt
    rising:=animation.playing && !state.was_playing
    phases:[PROGRAM_GROUPS]lib.Sync_Phase
    completed,phase_valid:[PROGRAM_GROUPS]bool
    clocks:[PROGRAM_GROUPS]int
    for group,g in output.groups[:output.count] {

        clock,existing:=program_clock_find(runtime,group.key);if clock<0 {runtime.error=.Capacity;return false};clocks[g]=clock
        if !existing {continue}
        for slot in runtime.players {
            if slot.seen==0 || slot.key!=runtime.leaders[clock] {continue}
            previous:=slot.player
            if rising && previous.done {lib.player_restart(&content.lib,&previous)}
            phases[g],phase_valid[g]=lib.sync_phase(&content.lib,previous);completed[g]=previous.done;break
        }
    }
    for group in output.groups[:output.count] {
        group:=group
        for leaf in group.leaves[:group.count] {
            leaf:=leaf;for &slot in runtime.players {if slot.seen!=0 && slot.key==leaf.key {slot.active_last=slot.seen==runtime.frame-1;slot.seen=runtime.frame;break}}}
    }
    for &group,g in output.groups[:output.count] {
        if clocks[g]<0 {continue}
        for &leaf in group.leaves[:group.count] {
            index:=int(lib.clip_find(&content.lib,leaf.clip))-1
            at:=program_player_find(runtime,leaf.key);if at<0 {runtime.error=.Capacity;return false}
            slot:=&runtime.players[at];handle:=lib.Clip(index+1+(content.clip_count if leaf.loop else 0))
            fresh:=slot.seen==0 || slot.key!=leaf.key || slot.player.clip!=handle || !slot.active_last
            if fresh {
                slot^={key=leaf.key,player=lib.player_make(handle,leaf.speed*animation.speed),active_last=true};lib.player_restart(&content.lib,&slot.player)
                if leaf.sync && phase_valid[g] {
                    phase:=phases[g];if completed[g] || group.mode==.Weighted || group.mode==.Fixed {phase.markers=false}
                    lib.player_synchronize(&content.lib,&slot.player,phase);slot.player.done=completed[g] && !leaf.loop
                } else if leaf.start>0 {slot.player.time=leaf.start}
            }
            slot.player.speed,slot.player.weight=leaf.speed*animation.speed,1
            if rising && slot.player.done {lib.player_restart(&content.lib,&slot.player)}
            if sought>=0 {slot.player.time=sought;slot.player.done,slot.player.fresh=false,false}
            slot.seen=runtime.frame;leaf.player=u16(at)
        }
    }
    clock_leaders:[PROGRAM_CLOCKS]u16
    clock_groups:[PROGRAM_CLOCKS]i16
    clock_weights:[PROGRAM_CLOCKS]f32
    for &index in clock_groups {index=-1}
    for group,g in output.groups[:output.count] {
        group:=group;clock:=clocks[g];if clock<0 {continue}
        for leaf in group.leaves[:group.count] {effective:=leaf.weight*max(group.weight,group.root_weight);if clock_groups[clock]<0 || effective>clock_weights[clock] {clock_leaders[clock],clock_groups[clock],clock_weights[clock]=leaf.player,i16(g),effective}}
    }
    order:[PROGRAM_GROUPS]u8;ordered:[PROGRAM_GROUPS]bool;order_count:int
    for group in clock_groups {if group>=0 && !ordered[group] {order[order_count]=u8(group);order_count+=1;ordered[group]=true}}
    for used,g in ordered[:output.count] {if !used {order[order_count]=u8(g);order_count+=1}}
    clock_durations,clock_totals,clock_steps:[PROGRAM_CLOCKS]f32
    clock_modes:[PROGRAM_CLOCKS]Sync_Mode
    event_key:u32;event_weight:f32=-1
    for &step in clock_steps {step=dt}
    for group,g in output.groups[:output.count] {
        group:=group;clock:=clocks[g];if clock<0 {continue};clock_modes[clock]=group.mode
        if group.mode==.Fixed {clock_durations[clock]=group.duration}
        for leaf in group.leaves[:group.count] {
            amount:=leaf.weight*group.weight
            if amount>event_weight || amount==event_weight && leaf.key<event_key {event_key,event_weight=leaf.key,amount}
            if group.mode==.Weighted {share:=leaf.weight*max(group.weight,group.root_weight);clock_durations[clock]+=lib.clip_duration(&content.lib,runtime.players[leaf.player].player.clip)*share/max(abs(leaf.speed),1e-6);clock_totals[clock]+=share}
        }
    }
    for total,i in clock_totals {if total>0 {clock_durations[i]/=total}}
    distance_player:=-1;distance_step:=dt
    if distance!=nil {
        selected_group:=-1;selected:=-1;greatest:f32=-1
        for group,g in output.groups[:output.count] {group:=group;for leaf,i in group.leaves[:group.count] {share:=leaf.weight*max(group.weight,group.root_weight);if leaf.clip==source_clip_name(content.id,distance.animation,distance.clip) && share>greatest {selected_group,selected,greatest=g,i,share}}}
        if selected<0 {runtime.error=.Invalid_Parameter;return false}
        primary:=&output.groups[selected_group]
        clock:=clocks[selected_group];lead:=&runtime.players[clock_leaders[clock]]
        selected_player:=runtime.players[primary.leaves[selected].player].player
        independent:=!primary.leaves[selected].sync
        if independent {distance_player=int(primary.leaves[selected].player);lead=&runtime.players[distance_player]}
        phase_player:=selected_player;phase_player.time=distance.time;phase_player.done=false
        phase,valid:=lib.sync_phase(&content.lib,phase_player);if !valid {runtime.error=.Invalid_Parameter;return false}
        if clock_modes[clock]==.Weighted || clock_modes[clock]==.Fixed {phase.markers=false}
        target_time:=distance.time
        if lead.player.clip!=selected_player.clip {converted,ok:=lib.sync_time(&content.lib,lead.player.clip,phase);if !ok {runtime.error=.Invalid_Parameter;return false};target_time=converted}
        if distance.seek {
            for &group,g in output.groups[:output.count] {if clocks[g]!=clock {continue};for leaf in group.leaves[:group.count] {slot:=&runtime.players[leaf.player];if !independent && leaf.sync {lib.player_synchronize(&content.lib,&slot.player,phase)} else if int(leaf.player)==distance_player {slot.player.time=distance.time;slot.player.done,slot.player.fresh=false,false}}}
            if independent {distance_step=0} else {clock_steps[clock]=0}
        } else {
            if target_time<lead.player.time {if lib.clip_data(&content.lib,lead.player.clip).loop!=.Loop {runtime.error=.Invalid_Parameter;return false};target_time+=lib.clip_duration(&content.lib,lead.player.clip)}
            if lead.player.speed<=0 || animation.speed==0 {runtime.error=.Invalid_Parameter;return false}
            scale:=f32(1)
            if !independent && (clock_modes[clock]==.Weighted || clock_modes[clock]==.Fixed) {duration:=clock_durations[clock];if duration<=0 {return false};scale=lib.clip_duration(&content.lib,lead.player.clip)/(duration*max(abs(lead.player.speed/animation.speed),1e-6))}
            if lead.player.speed<=0 {runtime.error=.Invalid_Parameter;return false}
            step:=(target_time-lead.player.time)/(lead.player.speed*scale)
            if independent {distance_step=step} else {clock_steps[clock]=step}
        }
    }
    state.motion=ROOT_DELTA_DEFAULT;state.root_enabled=has_root
    for index in order[:order_count] {
        g:=int(index);group:=&output.groups[g]
        clock:=clocks[g];if clock<0 {continue}
        representative:=program_representative(group,content,has_root && g==int(output.primary))
        leader:=-1
        for leaf,i in group.leaves[:group.count] {if leaf.player==clock_leaders[clock] {leader=i;break}}
        lead:=&runtime.players[clock_leaders[clock]]
        phase,valid:=lib.sync_phase(&content.lib,lead.player);if lead.player.done || group.mode==.Weighted || group.mode==.Fixed {phase.markers=false}
        before:=lead.player
        if lead.advanced==runtime.frame {before.time,before.done=lead.from,lead.was_done;phase,valid=lib.sync_phase(&content.lib,before);if before.done || group.mode==.Weighted || group.mode==.Fixed {phase.markers=false}}
        duration:=clock_durations[clock];clock_dt:=clock_steps[clock]
        for step in 0..<int(group.count) {
            i:=step if leader<0 else (leader if step==0 else (step-1 if step<=leader else step))
            leaf:=&group.leaves[i];slot:=&runtime.players[leaf.player];player:=&slot.player
            if slot.advanced!=runtime.frame {
                if leaf.sync && valid && i!=leader {lib.player_synchronize(&content.lib,player,phase)}
                from:=player.time;was_done:=player.done;to:=from
                batch:[EVENT_BATCH]lib.Event;written,dropped:int
                if leaf.sync && valid && i!=leader {
                    next,next_valid:=lib.sync_phase(&content.lib,lead.player);if lead.player.done || group.mode==.Weighted || group.mode==.Fixed {next.markers=false}
                    if next_valid {lib.player_synchronize(&content.lib,player,next)}
                    to=player.time
                    lead_duration:=lib.clip_duration(&content.lib,before.clip)
                    if animation.playing && lib.clip_data(&content.lib,lead.player.clip).loop==.Loop && leaf.loop && lead_duration>0 {to+=(cmath.floor(lead.to/lead_duration)-cmath.floor(lead.from/lead_duration))*lib.clip_duration(&content.lib,player.clip)}
                    player.done=lead.player.done
                } else if animation.playing {
                    scale:=f32(1)
                    if leaf.sync && (group.mode==.Weighted || group.mode==.Fixed) && duration>0 {scale=lib.clip_duration(&content.lib,player.clip)/(duration*max(abs(leaf.speed),1e-6))}
                    step:=distance_step if int(leaf.player)==distance_player else clock_dt if leaf.sync else dt
                    to=from+step*player.speed*scale
                    if !finite(to) {runtime.error=.Invalid_Parameter;return false}
                    written,dropped=lib.player_advance(&content.lib,player,step*scale,batch[:])
                }
                weight:=leaf.weight*group.weight*mm.saturate(animation.weight)
                if animation.event_policy!=.Dominant || leaf.key==event_key {emit_events(playback,events,state.entity,content,batch[:written],dropped,problems,weight,leaf.key,u16(clock),animation)}
                slot.from,slot.to,slot.was_done=from,to,was_done;slot.advanced=runtime.frame
            }
            if group.root_weight>0 && has_root && animation.playing && sought<0 && !(distance!=nil && distance.seek) && !slot.was_done {
                root_bone:=bone_target(state,root.bone)
                moved,turned:=lib.clip_root_motion(&content.lib,player.clip,root_bone,slot.from,slot.to)
                moved,turned=root_motion_to_rig(state,root_bone,moved,turned)
                share:=leaf.weight*group.root_weight*mm.saturate(animation.weight)
                if root.translation {state.motion.translation+=moved*share}
                if root.rotation {state.motion.rotation*=mm.quat_slerp(1,turned,share)}
            }
        }
        runtime.leaders[clock]=lead.key
        if g==int(output.primary) {current:=runtime.players[group.leaves[representative].player].player;state.time=lib.player_time(&content.lib,current);state.duration=lib.clip_duration(&content.lib,current.clip);state.ended=current.done;state.clip=int(current.clip-1)%content.clip_count;state.fader.current=current;runtime.current_phase,_=lib.sync_phase(&content.lib,current);if group.mode==.Weighted || group.mode==.Fixed {runtime.current_phase.markers=false}}
    }
    if output.mirror {state.motion=root_delta_mirror(state.mirror_plane,state.motion)}
    for key,i in runtime.leader_keys {if key==0 {continue};used:=false;for group in output.groups[:output.count] {if group.key==key || group.key==0 && key==1 {used=true;break}};if !used {runtime.leader_keys[i]=0;runtime.leaders[i]=0}}
    state.was_playing=animation.playing;runtime.elapsed+=dt if animation.playing else 0
    return true
}

// Room for the pose and the curves of the program of state, taken on the owner thread: the job
// that poses it takes no memory.
@(private)
program_buffers :: proc(state:^Playing,content:^host.Content_Animation) -> bool {
    if !curves_prepare(state,content) {return false}
    runtime:=&state.program;n:=len(state.bindings);c:=len(state.curves)
    if !program_curves_prepare(runtime,c) || !program_array_resize(&runtime.from,n) {return false}
    if !program_array_resize(&runtime.sampled,n) || !program_array_resize(&runtime.before,n) || !program_array_resize(&runtime.sampled_curves,c) {return false}
    if len(runtime.current)!=n {runtime.kept,runtime.history_dt=false,0}
    if !program_array_resize(&runtime.history,n) || !program_array_resize(&runtime.current,n) || !program_array_resize(&runtime.history_curves,c) || !program_array_resize(&runtime.prior_curves,c) || !program_array_resize(&runtime.inertia_bones,n) || !program_array_resize(&runtime.inertia_curves,c*5) || !program_array_resize(&runtime.inertia_values,c*5*4) {return false}
    return true
}

// The pose and the curves the clips of the program blend into sampled and sampled_curves, each
// clip at the time its player is at, or with previous at the one it was at before this tick.
@(private)
program_sample :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,output:^Program_Output,previous:bool,worker:int) -> bool {
    runtime:=&state.program
    _,bones,shared,ready:=pose_room(playback,state,worker)
    if !ready || len(runtime.sampled)!=len(state.bindings) || len(runtime.sampled_curves)!=len(state.curves) {runtime.error=.Out_Of_Memory;return false}
    for group in output.groups[:output.count] {
        group:=group
        for leaf in group.leaves[:group.count] {
            if int(leaf.player)>=len(runtime.players) {continue}
            player:=runtime.players[leaf.player].player
            if previous {player.time=runtime.players[leaf.player].from}
            lib.bones_blend(bones,shared.bones[:],&content.lib,player,leaf.weight)
        }
    }
    tracks_twins(shared,bones)
    for binding,b in state.bindings {runtime.sampled[b],_,_=lib.bone_transform(bones[b],binding.rest)}
    if output.mirror && !playing_mirror(state,runtime.sampled[:]) {runtime.error=.Invalid_Parameter;return false}
    for curve,k in state.curves {
        value:=curve;value.value,value.weight={},0
        for group in output.groups[:output.count] {
            group:=group
            for leaf in group.leaves[:group.count] {
                if int(leaf.player)>=len(runtime.players) {continue}
                player:=runtime.players[leaf.player].player
                if previous {player.time=runtime.players[leaf.player].from}
                curve_accumulate(&value,&content.lib,player,leaf.weight)
            }
        }
        runtime.sampled_curves[k]=value
    }
    return true
}

// The pose of the program into the local pose of state, through the inertial transition a jump
// of its clips asked for.
@(private)
program_pose :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,output:^Program_Output,worker:=0) -> bool {
    runtime:=&state.program;n:=len(state.bindings);c:=len(state.curves)
    if !program_sample(playback,state,content,output,false,worker) {return false}
    pose:=runtime.sampled[:n];curves:=runtime.sampled_curves[:c]
    share:=mm.saturate(animation.weight)
    for value,b in pose {if state.bindings[b].target!=0 {state.local[b]=value if share==1 else state.bindings[b].rest if share==0 else mm.transform_interpolate(state.bindings[b].rest,value,share)}}
    for value,k in curves {value:=value;value.value*=share;value.weight*=share;state.curves[k]=value}
    if runtime.capture && runtime.last_dt==0 {copy(state.local[:],runtime.from[:]);copy(state.curves[:],runtime.from_curves[:]);return true}
    if runtime.capture && len(runtime.from)==n {
        previous:=runtime.history[:] if runtime.history_dt>0 else runtime.from[:]
        values:=runtime.inertia_values[:];old:=values[:c*5];now:=values[c*5:c*10];target:=values[c*10:c*15];target_previous:=values[c*15:]
        if !program_sample(playback,state,content,output,true,worker) {return false}
        before:=runtime.before[:n]
        for value,b in pose {before[b]=mm.transform_interpolate(state.bindings[b].rest,value,share)}
        for value,k in curves {for v,j in value.value {target_previous[k*5+j]=v*share};target_previous[k*5+4]=value.weight*share}
        for value,k in runtime.from_curves {for v,j in value.value {now[k*5+j]=v;old[k*5+j]=runtime.history_curves[k].value[j]};now[k*5+4]=value.weight;old[k*5+4]=runtime.history_curves[k].weight}
        for value,k in state.curves {for v,j in value.value {target[k*5+j]=v};target[k*5+4]=value.weight}
        // The pose two ticks before the target, into the room of the sampled one.
        older:=pose
        ratio:=runtime.history_dt/runtime.last_dt
        for value,b in before {old:=value;old.position-=(state.local[b].position-value.position)*ratio;old.scale-=(state.local[b].scale-value.scale)*ratio;delta:=mm.quat_inverse(value.rotation)*state.local[b].rotation;old.rotation=value.rotation*mm.quat_slerp(1,mm.quat_inverse(delta),ratio);older[b]=old}
        for &value,k in target {value=target_previous[k]-(value-target_previous[k])*ratio}
        input:=lib.Inertial_Input{previous=previous,current=runtime.from[:],target=before,target_previous=older,previous_curves=old,current_curves=now,target_curves=target_previous,target_previous_curves=target,dt=runtime.history_dt,duration=runtime.fade}
        if !lib.inertial_capture(&runtime.inertia,runtime.inertia_bones[:],runtime.inertia_curves[:],input) {runtime.error=.Invalid_Parameter;return false}
        // A bone no clip moves stays where the target puts it.
        for binding,b in state.bindings {if binding.target==0 {runtime.inertia_bones[b]={}}}
        runtime.capture=false
    }
    if runtime.inertia.active {
        before:=runtime.before[:n]
        if !program_sample(playback,state,content,output,true,worker) {return false}
        for value,b in pose {before[b]=mm.transform_interpolate(state.bindings[b].rest,value,share)}
        root_bone:=bone_resolve(state,runtime.root.bone) if runtime.has_root else -1
        old_root,new_root:=mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY
        if root_bone>=0 {old_root,new_root=before[root_bone],state.local[root_bone]}
        if !lib.inertial_pose_apply(runtime.inertia,runtime.inertia_bones[:],before,before) {runtime.error=.Invalid_Parameter;return false}
        previous_correction:=mm.TRANSFORM_IDENTITY
        if root_bone>=0 {previous_correction.position=before[root_bone].position-old_root.position;previous_correction.rotation=mm.quat_inverse(old_root.rotation)*before[root_bone].rotation}
        if !lib.inertial_advance(&runtime.inertia,runtime.last_dt if animation.playing else 0) || !lib.inertial_pose_apply(runtime.inertia,runtime.inertia_bones[:],state.local[:],state.local[:]) {runtime.error=.Invalid_Parameter;return false}
        values:=runtime.inertia_values[:c*5];for value,k in state.curves {for v,j in value.value {values[k*5+j]=v};values[k*5+4]=value.weight}
        if !lib.inertial_curves_apply(runtime.inertia,runtime.inertia_curves[:],values,values) {runtime.error=.Invalid_Parameter;return false}
        for &value,k in state.curves {for &v,j in value.value {v=values[k*5+j]};value.weight=mm.saturate(values[k*5+4])}
        if root_bone>=0 && animation.playing && runtime.last_dt>0 {
            correction:=mm.TRANSFORM_IDENTITY;correction.position=state.local[root_bone].position-new_root.position;correction.rotation=mm.quat_inverse(new_root.rotation)*state.local[root_bone].rotation
            if runtime.root.translation {state.motion.translation+=correction.position-previous_correction.position}
            if runtime.root.rotation {state.motion.rotation=mm.quat_inverse(previous_correction.rotation)*state.motion.rotation*correction.rotation}
        }
    }
    if runtime.last_dt>0 && runtime.kept {copy(runtime.history[:],runtime.current[:]);copy(runtime.history_curves[:],runtime.prior_curves[:]);runtime.history_dt=runtime.last_dt}
    copy(runtime.current[:],state.local[:]);copy(runtime.prior_curves[:],state.curves[:]);runtime.kept=true
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
