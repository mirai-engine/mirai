package anim

import cmath "core:math"
import "core:mem"
import aa "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"

PROGRAM_PLAYERS :: PROGRAM_GROUPS*PROGRAM_LEAVES
Program_Leaf :: struct {clip:u64,key:u32,weight,speed:f32,loop,sync:bool,player:u16,start:f32} // start: seconds a new player of it starts at
Program_Group :: struct {leaves:[PROGRAM_LEAVES]Program_Leaf,count:u8,weight,root_weight:f32,over:u64,mode:Sync_Mode,duration:f32,key:u64,named,mirror:bool}
Program_Instruction :: struct {kind:Graph_Node_Kind,left,right,group,node:u8,weight,root_weight,reference:f32,over:u64,mask:[64]u8,curves:Curve_Blend}
Program_Output :: struct {asset:base.Asset_Id,groups:[dynamic]Program_Group,count:u8,instructions:[dynamic]Program_Instruction,instruction_count,output,primary:u8}
Program_Player :: struct {key:u32,player:lib.Player,seen,advanced:u64,from,to:f32,was_done,active_last:bool}
// Pending: a source still loads (host.content_animation_pending); nothing plays until it is ready.
Program_Error :: enum u8 {None,Invalid_Asset,Invalid_Parameter,Unknown_Parameter,Missing_Clip,Incompatible_Root,Unbound_Mask,Unsupported_Mirror,Out_Of_Memory,Capacity,Additive_Space,Pending}
Program_Playing :: struct {
    error:Program_Error,
    asset:base.Asset_Id,
    library:base.Asset_Id,        // the .anim the program plays
    revision:u64,
    checked:u64,
    kind:aa.Fourcc,
    players:[dynamic]Program_Player,
    leaders:[PROGRAM_GROUPS]u32,
    leader_keys:[PROGRAM_GROUPS]u64,
    frame:u64,
    from:[dynamic]mm.Transform,
    from_curves:[dynamic]Curve_Output,
    elapsed,fade:f32,
    root:Root_Motion,
    has_root,ready:bool,
    nodes,reference_nodes:[dynamic]mm.Transform,
    node_curves,reference_curves:[dynamic]Curve_Output,
    node_properties:[dynamic]Property_Set,
    node_weights:[dynamic]mm.Vec3,
    last_dt:f32,
    current_phase:lib.Sync_Phase,
    masks:[dynamic]f32,
    mask_bound:u64,
    mask_keys:[PROGRAM_INSTRUCTIONS]u64,
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
    compiled_stamp:u64,
    match:Match_Playing,
}

@(private)
program_output_prepare :: proc(output:^Program_Output,groups,instructions:int) -> bool {
    if groups<0 || groups>PROGRAM_GROUPS || instructions<0 || instructions>PROGRAM_INSTRUCTIONS {return false}
    return program_array_resize(&output.groups,max(groups,len(output.groups))) && program_array_resize(&output.instructions,max(instructions,len(output.instructions)))
}
@(private)
program_output_reset :: proc(output:^Program_Output) {
    output.asset={};output.count,output.instruction_count,output.output,output.primary=0,0,0,0
}
@(private)
program_output_free :: proc(output:^Program_Output) {delete(output.groups);delete(output.instructions);output^={}}

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

// Sets the parameter of a graph, a blend weight or an axis of its aim offsets
// and additive spaces, with this name. The program checks the name and the range when it samples: a name it
// does not declare, or a value outside its range, stops it with
// Unknown_Parameter or Invalid_Parameter. A parameter not set takes its
// default, an axis zero. False, with nothing changed, for an empty or too long
// name, a value that is not finite, or GRAPH_PARAMETERS other names set.
animation_parameter :: proc(animation:^Animation,name:string,value:f32) -> bool {
    if animation==nil || !finite(value) || len(name)==0 || len(name)>=32 {return false}
    for byte in name {if byte==0 {return false}}
    hash:=base.name_hash(name);free:=-1
    for known,i in animation.parameter_names {
        if known==hash {animation.parameters[i]=value;return true}
        if known==0 && free<0 {free=i}
    }
    if free<0 {return false}
    animation.parameter_names[free],animation.parameters[free]=hash,value
    return true
}
// The value set for a parameter by name; false when none is.
animation_parameter_value :: proc(animation:Animation,name:string) -> (value:f32,set:bool) {
    hash:=base.name_hash(name)
    for known,i in animation.parameter_names {if known!=0 && known==hash {return animation.parameters[i],true}}
    return 0,false
}
// Forgets every parameter set: each one goes back to its default.
animation_parameters_clear :: proc(animation:^Animation) {
    if animation!=nil {animation.parameters,animation.parameter_names={},{}}
}
@(private)
program_parameter_values :: proc(animation:Animation,names:[]u64,out:[]f32) -> bool {
    for known,i in animation.parameter_names {
        if known==0 {continue}
        found:=false
        for name,j in names {if name==known {out[j]=animation.parameters[i];found=true;break}}
        if !found {return false}
    }
    return true
}

@(private)
program_parameter :: proc(parameters:[]f32,index:i16,fallback:f32) -> f32 {return parameters[index] if index>=0 && int(index)<len(parameters) else fallback}
@(private)
program_weights :: proc(output:^Program_Output) {
    weights,roots:[PROGRAM_INSTRUCTIONS]f32
    weights[output.output],roots[output.output]=1,1
    for &group in output.groups[:output.count] {group.weight,group.root_weight=0,0}
    #reverse for instruction,i in output.instructions[:output.instruction_count] {
        instruction:=instruction
        if instruction.kind==.Clip || instruction.kind==.Blend_Space {
            output.groups[instruction.group].weight+=weights[i]
            output.groups[instruction.group].root_weight+=roots[i]*instruction.root_weight
        } else {
            left:=1-instruction.weight if instruction.kind==.Blend else 1
            weights[instruction.left]+=weights[i]*left;weights[instruction.right]+=weights[i]*instruction.weight
            roots[instruction.left]+=roots[i]*left
            if instruction.kind==.Blend {
                roots[instruction.left]+=roots[i]*(instruction.weight-instruction.root_weight)
                roots[instruction.right]+=roots[i]*instruction.root_weight
            }
        }
    }
    best:f32=-1
    for group,i in output.groups[:output.count] {if group.root_weight>best {best=group.root_weight;output.primary=u8(i)}}
}

@(private)
program_node :: proc(output:^Program_Output,profile:Graph_Profile,index:u16,parameters:[]f32,blends:^Blend_Assets,app:^host.App,depth:int=0,plan:^Graph_Plan=nil,override:base.Asset_Id={}) -> bool {
    if depth>=GRAPH_NODES || int(index)>=len(profile.nodes) {return false}
    wanted:[GRAPH_NODES]bool;wanted[index]=true
    if plan!=nil {for node in plan.nodes[:plan.count] {wanted[node]=true}} else {
    #reverse for node,i in profile.nodes[:int(index)+1] {
        if !wanted[i] {continue}
        if node.kind==.Blend || node.kind==.Layer || node.kind==.Additive {
            if int(node.left)>=i || int(node.right)>=i {return false}
            wanted[node.left],wanted[node.right]=true,true
        }
    }
    }
    groups,operations:=0,0
    for node,n in profile.nodes[:int(index)+1] {
        if !wanted[n] {continue};operations+=1
        if node.kind==.Clip || node.kind==.Blend_Space || node.kind==.Blend {groups+=1}
    }
    if !program_output_prepare(output,groups,operations) {return false}
    program_output_reset(output)
    output.asset=source_effective({},profile.info.animation,override)
    mapping:[GRAPH_NODES]u8
    for node,n in profile.nodes[:int(index)+1] {
        node:=node
        if !wanted[n] {continue}
        at:=output.instruction_count
        if at>=GRAPH_NODES {return false}
        mapping[n]=at;output.instruction_count+=1
        instruction:=&output.instructions[at]
        weight:=mm.saturate(program_parameter(parameters,node.weight_param,node.weight))
        instruction^={kind=node.kind,node=u8(n),weight=weight,root_weight=weight,reference=node.reference,mask=node.mask,curves=node.curves,over=base.name_hash(base.text_get(node.over[:])) if node.over[0]!=0 else 0}
        if node.kind==.Blend || node.kind==.Layer || node.kind==.Additive {instruction.left,instruction.right=mapping[node.left],mapping[node.right]}
        switch node.kind {
        case .Clip,.Blend_Space:
            if output.count>=PROGRAM_GROUPS {return false}
            group:=&output.groups[output.count];instruction.group=output.count;instruction.root_weight=1;output.count+=1
            group^={}
            group.mode,group.duration,group.named,group.mirror=node.sync_mode,node.sync_duration,node.sync_group[0]!=0,node.mirror
            group.key=base.name_hash(base.text_get(node.sync_group[:])) if node.sync_group[0]!=0 else u64(n)+1
            if node.kind==.Clip {
                source:=source_effective(node.animation,profile.info.animation,override)
                group.count=1;group.leaves[0]={clip=source_clip_name(output.asset,source,base.name_hash(base.text_get(node.clip[:]))),key=u32(n)*256,weight=1,speed=node.speed,loop=node.loop,sync=node.sync_mode!=.Independent}
            } else {
                content:=blend_content(blends,app,node.blend_space)
                if content==nil {return false}
                weights,sampled:=blend_content_sample(content,{program_parameter(parameters,node.x_param,node.position.x),program_parameter(parameters,node.y_param,node.position.y)})
                if !sampled {return false}
                for weight,w in weights.weights[:weights.count] {if weight<=0 {continue};sample:=content.profile.samples[weights.samples[w]];source:=source_effective(sample.animation,content.profile.info.animation,override);group.leaves[group.count]={clip=source_clip_name(output.asset,source,base.name_hash(base.text_get(sample.clip[:]))),key=u32(n)*256+u32(weights.samples[w]),weight=weight,speed=node.speed*sample.speed,loop=node.loop,sync=node.sync_mode!=.Independent};group.count+=1}
            }
        case .Blend,.Layer,.Additive:
            left,right:=output.instructions[instruction.left],output.instructions[instruction.right]
            simple:=left.kind==.Clip && right.kind==.Clip && left.mask[0]==0 && right.mask[0]==0 && left.over==0 && right.over==0 && left.curves==.Override && right.curves==.Override
            if simple {a,b:=output.groups[left.group],output.groups[right.group];simple=a.mode==b.mode && a.duration==b.duration && a.mirror==b.mirror && (a.key==b.key || a.mode==.Independent && !a.named && !b.named)}
            if node.kind==.Blend && simple && node.mask[0]==0 && node.over[0]==0 && node.curves!=.Ignore && int(output.groups[left.group].count)+int(output.groups[right.group].count)<=PROGRAM_LEAVES {
                if output.count>=PROGRAM_GROUPS {return false}
                group:=&output.groups[output.count]
                group^={}
                sides:=[2]Program_Group{output.groups[left.group],output.groups[right.group]}
                for &side,i in sides {
                    scale:=1-instruction.weight if i==0 else instruction.weight
                    for leaf in side.leaves[:side.count] {
                        if leaf.weight*scale<=0 {continue}
                        duplicate:=false
                        for &known in group.leaves[:group.count] {if known.key==leaf.key {known.weight+=leaf.weight*scale;duplicate=true;break}}
                        if !duplicate {leaf:=leaf;leaf.weight*=scale;group.leaves[group.count]=leaf;group.count+=1}
                    }
                }
                group.mode,group.duration,group.named,group.mirror=sides[0].mode,sides[0].duration,sides[0].named,sides[0].mirror
                group.key=sides[0].key if sides[0].key==sides[1].key else u64(n)+1
                instruction.kind,instruction.group,instruction.root_weight=.Clip,output.count,1;output.count+=1
            }
        }
    }
    output.output=mapping[index]
    program_compact(output)
    program_weights(output)
    return true
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

@(private)
// The program an Animation plays this tick: that of a .match or an .agraph. A .blend is refused
// with Additive_Space: it plays only under an Additive node of a graph. problems: where what a
// .match cannot do is reported.
program_resolve :: proc(state:^Playing,animation:Animation,app:^host.App,blends:^Blend_Assets,graphs:^Graph_Assets,dt:f32,events:^Animation_Events=nil,playback:^Playback=nil,prepared:^host.Content_Animation=nil,problems:^core.Problems=nil,goals:[]Match_Goal={},plays:[]Match_Play={},facing:=mm.FORWARD) -> (output:^Program_Output,programmed,ok:bool) {
    if app==nil || app.assets==nil {return nil,false,false}
    runtime:=&state.program
    runtime.error=.None
    defer {if programmed && !ok && runtime.error==.None {runtime.error=.Invalid_Asset}}
    kind:=runtime.kind
    if runtime.asset!=animation.asset || runtime.checked!=assets_stamp(app.assets) {
        record,found:=aa.registry_find(&app.assets.registry,animation.asset)
        kind=record.kind if found else aa.Fourcc(0)
        runtime.kind,runtime.checked=kind,assets_stamp(app.assets)
    }
    if kind==BLEND_KIND {runtime.error=.Additive_Space;return nil,true,false}
    if kind!=GRAPH_KIND && kind!=MATCH_KIND {
        program_free(runtime)
        runtime.kind,runtime.asset,runtime.checked=kind,animation.asset,assets_stamp(app.assets)
        return nil,false,true
    }
    programmed=true
    if animation.library!={} {
        record,found:=aa.registry_find(&app.assets.registry,animation.library)
        if !found || record.kind!=aa.KIND_ANIMATION {runtime.error=.Invalid_Asset;return nil,true,false}
    }
    output=&runtime.output
    revision:u64
    reset,swapped:bool
    source:base.Asset_Id
    reused:=false;compiled_stamp:u64
    if kind==MATCH_KIND {
        content:=match_content(graphs,app,animation.asset);if content==nil {return nil,true,false}
        source=animation.library if animation.library!={} else content.profile.info.animation
        revision=content.revision;reset=runtime.asset!=animation.asset || runtime.revision!=revision || runtime.library!=source || !runtime.ready
        swapped=reset && runtime.ready && runtime.asset==animation.asset && runtime.revision==revision
        if reset && !program_output_prepare(output,1,1) {runtime.error=.Out_Of_Memory;return nil,true,false}
        if reset {runtime.match=match_swapped(runtime.match) if swapped else MATCH_PLAYING_DEFAULT}
        ok=match_output(state,output,content,prepared if prepared!=nil else host.content_animation(app,source),source,dt,goals,plays,facing,app.assets,app.allocator,events,playback,problems)
    } else {
        content:=graph_content(graphs,app,animation.asset);if content==nil {return nil,true,false}
        source=animation.library if animation.library!={} else content.profile.info.animation
        revision=content.revision;reset=runtime.asset!=animation.asset || runtime.revision!=revision || runtime.library!=source || !runtime.ready
        node:=content.profile.info.output
        if reset {
            groups:=0
            for index in content.plans[node].nodes[:content.plans[node].count] {kind:=content.profile.nodes[index].kind;if kind==.Clip || kind==.Blend_Space || kind==.Blend {groups+=1}}
            if !program_output_prepare(output,groups,int(content.plans[node].count)) {runtime.error=.Out_Of_Memory;return nil,true,false}
        }
        parameters:[GRAPH_PARAMETERS]f32
        count:=len(content.profile.parameters)
        for parameter,i in content.profile.parameters {parameters[i]=parameter.value}
        if !program_parameter_values(animation,content.parameter_names[:count],parameters[:count]) {runtime.error=.Unknown_Parameter;return nil,true,false}
        for parameter,i in content.profile.parameters {if !finite(parameters[i]) || parameters[i]<parameter.min || parameters[i]>parameter.max {runtime.error=.Invalid_Parameter;return nil,true,false}}
        compiled_stamp=base.hash_combine(base.hash_combine(revision,assets_stamp(app.assets)),u64(node))
        for parameter in parameters[:count] {compiled_stamp=base.hash_combine(compiled_stamp,u64(transmute(u32)parameter))}
        if !reset && runtime.compiled_stamp==compiled_stamp {ok,reused=true,true} else {ok=program_node(output,content.profile,node,parameters[:count],blends,app,0,&content.plans[node],animation.library)}
    }
    if reset {
        mem.zero_slice(runtime.players[:]);mem.zero_slice(runtime.leader_keys[:])
        runtime.epoch=0
        // A swapped library enters its clip through the capture match_output asked for.
        if !swapped {runtime.fade=0;runtime.capture=false;runtime.inertia={}}
    }
    if !ok {return nil,true,false}
    output.asset=source
    if !reused {for &group in output.groups[:output.count] {
        group.key~=(u64(runtime.epoch)<<48)
        for &leaf in group.leaves[:group.count] {leaf.key+=u32(runtime.epoch)<<16}
    }
    }
    runtime.compiled_stamp=compiled_stamp
    runtime.asset,runtime.revision,runtime.library=animation.asset,revision,source
    runtime.ready=ok
    return
}
@(private)
program_free :: proc(runtime:^Program_Playing) {
    delete(runtime.players);delete(runtime.from);delete(runtime.from_curves)
    delete(runtime.nodes);delete(runtime.reference_nodes);delete(runtime.node_curves);delete(runtime.reference_curves);delete(runtime.node_properties);delete(runtime.node_weights)
    delete(runtime.masks);program_output_free(&runtime.output)
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
    return -1,false
}

@(private)
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
            if group.root_weight<=0 || leaf.weight<=0 || animation.root_motion==.None || index>=len(content.roots) {continue}
            meta:=content.roots[index]
            if !meta.translation && !meta.rotation {continue}
            if has_root && (root.bone.path!=meta.bone || root.translation!=meta.translation || root.rotation!=meta.rotation) {runtime.error=.Incompatible_Root;return false}
            root={bone={meta.bone},translation=meta.translation,rotation=meta.rotation,in_place=animation.root_motion==.In_Place};has_root=true
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
    clock_leaders:[PROGRAM_GROUPS]u16
    clock_groups:[PROGRAM_GROUPS]i16
    clock_weights:[PROGRAM_GROUPS]f32
    for &index in clock_groups {index=-1}
    for group,g in output.groups[:output.count] {
        group:=group;clock:=clocks[g];if clock<0 {continue}
        for leaf in group.leaves[:group.count] {effective:=leaf.weight*max(group.weight,group.root_weight);if clock_groups[clock]<0 || effective>clock_weights[clock] {clock_leaders[clock],clock_groups[clock],clock_weights[clock]=leaf.player,i16(g),effective}}
    }
    order:[PROGRAM_GROUPS]u8;ordered:[PROGRAM_GROUPS]bool;order_count:int
    for group in clock_groups {if group>=0 && !ordered[group] {order[order_count]=u8(group);order_count+=1;ordered[group]=true}}
    for used,g in ordered[:output.count] {if !used {order[order_count]=u8(g);order_count+=1}}
    clock_durations,clock_totals,clock_steps:[PROGRAM_GROUPS]f32
    clock_modes:[PROGRAM_GROUPS]Sync_Mode
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
                if group.mirror {moved,turned=lib.mirror_vector(state.mirror_plane,moved),lib.mirror_rotation(state.mirror_plane,turned)}
                share:=leaf.weight*group.root_weight*mm.saturate(animation.weight)
                if root.translation {state.motion.translation+=moved*share}
                if root.rotation {state.motion.rotation*=mm.quat_slerp(1,turned,share)}
            }
        }
        runtime.leaders[clock]=lead.key
        if g==int(output.primary) {current:=runtime.players[group.leaves[representative].player].player;state.time=lib.player_time(&content.lib,current);state.duration=lib.clip_duration(&content.lib,current.clip);state.ended=current.done;state.clip=int(current.clip-1)%content.clip_count;state.fader.current=current;runtime.current_phase,_=lib.sync_phase(&content.lib,current);if group.mode==.Weighted || group.mode==.Fixed {runtime.current_phase.markers=false}}
    }
    for key,i in runtime.leader_keys {if key==0 {continue};used:=false;for group in output.groups[:output.count] {if group.key==key || group.key==0 && key==1 {used=true;break}};if !used {runtime.leader_keys[i]=0;runtime.leaders[i]=0}}
    state.was_playing=animation.playing;runtime.elapsed+=dt if animation.playing else 0
    return true
}

@(private)
program_buffers :: proc(state:^Playing,output:^Program_Output,content:^host.Content_Animation) -> bool {
    if !curves_prepare(state,content) {return false}
    runtime:=&state.program;n:=len(state.bindings);c:=len(state.curves);count:=int(output.instruction_count)
    masks_grow:=len(runtime.masks)<count*n
    capacity:=max(count,3)
    if !program_array_reserve(&runtime.nodes,capacity*n) || !program_array_reserve(&runtime.reference_nodes,capacity*n) || !program_array_reserve(&runtime.node_properties,capacity*n) || !program_array_reserve(&runtime.node_weights,capacity*n) || !program_array_reserve(&runtime.masks,capacity*n) || !program_array_reserve(&runtime.node_curves,capacity*c) || !program_array_reserve(&runtime.reference_curves,capacity*c) {return false}
    if !program_curves_prepare(runtime,c) || !program_array_resize(&runtime.from,n) {return false}
    if !program_array_resize(&runtime.nodes,count*n) || !program_array_resize(&runtime.reference_nodes,count*n) || !program_array_resize(&runtime.node_properties,count*n) || !program_array_resize(&runtime.node_weights,count*n) {return false}
    if !program_array_resize(&runtime.node_curves,count*c) || !program_array_resize(&runtime.reference_curves,count*c) || !program_array_resize(&runtime.masks,count*n) {return false}
    // Regrowing masks clears rows whose keys can still be cached.
    if masks_grow {runtime.mask_bound=~state.bound}
    if len(runtime.current)!=n {runtime.kept,runtime.history_dt=false,0}
    if !program_array_resize(&runtime.history,n) || !program_array_resize(&runtime.current,n) || !program_array_resize(&runtime.history_curves,c) || !program_array_resize(&runtime.prior_curves,c) || !program_array_resize(&runtime.inertia_bones,n) || !program_array_resize(&runtime.inertia_curves,c*5) || !program_array_resize(&runtime.inertia_values,c*5*4) {return false}
    return true
}

@(private)
program_evaluate_nodes :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,output:^Program_Output,last:int,reference:f32=-1) -> bool {
    runtime:=&state.program;n:=len(state.bindings);c:=len(state.curves)
    for instruction,i in output.instructions[:last+1] {
        out:=runtime.nodes[i*n:(i+1)*n];properties:=runtime.node_properties[i*n:(i+1)*n];curves:=runtime.node_curves[i*c:(i+1)*c];weights:=runtime.node_weights[i*n:(i+1)*n]
        if instruction.kind==.Clip || instruction.kind==.Blend_Space {
            group:=output.groups[instruction.group];pose:=&playback.pose;lib.pose_clear(pose)
            for leaf in group.leaves[:group.count] {
            leaf:=leaf;player:=runtime.players[leaf.player].player;if reference>=0 {player.time=reference} else if reference==-2 {player.time=runtime.players[leaf.player].from};lib.pose_blend(pose,&content.lib,player,leaf.weight)}
            for binding,b in state.bindings {out[b],weights[b],properties[b]=lib.pose_bone(pose,binding.target,binding.rest)}
            if group.mirror {
                if !playing_mirror(state,out) {runtime.error=.Unsupported_Mirror;return false}
                for pair,b in state.mirror_pairs {if int(pair)>b {properties[b],properties[pair]=properties[pair],properties[b];weights[b],weights[pair]=weights[pair],weights[b]}}
            }
            for binding,b in state.bindings {
                alpha:=runtime.masks[i*n+b]
                if alpha==0 {out[b]=binding.rest;weights[b]={}} else if alpha!=1 {out[b]=mm.transform_interpolate(binding.rest,out[b],alpha);weights[b]*=alpha}
            }
            for curve,k in state.curves {
                value:=curve;value.value,value.weight={},0
                for leaf in group.leaves[:group.count] {
            leaf:=leaf;player:=runtime.players[leaf.player].player;if reference>=0 {player.time=reference} else if reference==-2 {player.time=runtime.players[leaf.player].from};curve_accumulate(&value,&content.lib,player,leaf.weight)}
                if instruction.curves==.Ignore || instruction.over!=0 && instruction.over!=value.target {value.value,value.weight={},0}
                curves[k]=value
            }
            continue
        }
        left:=runtime.nodes[int(instruction.left)*n:(int(instruction.left)+1)*n];right:=runtime.nodes[int(instruction.right)*n:(int(instruction.right)+1)*n]
        lp:=runtime.node_properties[int(instruction.left)*n:(int(instruction.left)+1)*n];rp:=runtime.node_properties[int(instruction.right)*n:(int(instruction.right)+1)*n]
        ref:=runtime.reference_nodes[i*n:(i+1)*n]
        lw:=runtime.node_weights[int(instruction.left)*n:(int(instruction.left)+1)*n];rw:=runtime.node_weights[int(instruction.right)*n:(int(instruction.right)+1)*n]
        for value,b in left {
            value:=value
            alpha:=instruction.weight*runtime.masks[i*n+b];properties[b]=lp[b]|rp[b]
            if alpha==0 {out[b]=value;weights[b]=lw[b];properties[b]=lp[b];continue}
            if alpha==1 && instruction.kind==.Blend {out[b]=right[b];weights[b]=rw[b];properties[b]=rp[b];continue}
            if instruction.kind==.Blend {out[b]=mm.transform_interpolate(value,right[b],alpha);weights[b]=mm.lerp(lw[b],rw[b],alpha)}
            else if instruction.kind==.Additive {
                weights[b]=lw[b]
                if alpha>0 {for amount,j in rw[b] {if amount>0 {weights[b][j]=1}}}
                if .Position in rp[b] {value.position+=(right[b].position-ref[b].position)*alpha}
                if .Rotation in rp[b] {value.rotation*=mm.quat_slerp(1,mm.quat_inverse(ref[b].rotation)*right[b].rotation,alpha)}
                if .Scale in rp[b] {value.scale+=(right[b].scale-ref[b].scale)*alpha}
                out[b]=value
            } else {
                weights[b]=lw[b]+(mm.Vec3{1,1,1}-lw[b])*rw[b]*alpha
                rest:=state.bindings[b].rest
                if .Position in rp[b] {value.position+=(right[b].position-rest.position+(rest.position-value.position)*rw[b].x)*alpha}
                if .Rotation in rp[b] && rw[b].y>0 {target:=right[b].rotation if rw[b].y==1 else mm.quat_slerp(rest.rotation,right[b].rotation,1/rw[b].y);value.rotation=mm.quat_slerp(value.rotation,target,alpha*rw[b].y)}
                if .Scale in rp[b] {value.scale+=(right[b].scale-rest.scale+(rest.scale-value.scale)*rw[b].z)*alpha}
                out[b]=value
            }
        }
        lc:=runtime.node_curves[int(instruction.left)*c:(int(instruction.left)+1)*c];rc:=runtime.node_curves[int(instruction.right)*c:(int(instruction.right)+1)*c]
        refs:=runtime.reference_curves[i*c:(i+1)*c]
        for value,k in lc {
            value:=value
            sample:=rc[k];alpha:=instruction.weight
            if instruction.over!=0 && instruction.over!=sample.target {alpha=0}
            if instruction.curves==.Ignore {alpha=0}
            if instruction.kind==.Blend {value.value=mm.lerp(value.value,sample.value,alpha);value.weight=mm.lerp(value.weight,sample.weight,alpha)}
            else if instruction.kind==.Additive || instruction.curves==.Additive {value.value+=(sample.value-refs[k].value)*alpha}
            else if sample.weight>0 {value.value=mm.lerp(value.value,sample.value/sample.weight,alpha*sample.weight);value.weight=mm.lerp(value.weight,1,alpha*sample.weight)}
            curves[k]=value
        }
    }
    return true
}

// Weight 1 inside what over holds and 0 outside; without over, 1 everywhere.
@(private)
program_mask_over :: proc(state:^Playing,over:u64,mask:[]f32) -> bool {
    if over==0 {for &weight in mask {weight=1};return true}
    selection,selected:=bone_select(state,over)
    if !selected {return false}
    for &weight,b in mask {weight=1 if bone_selected(state,selection,b) else 0}
    return true
}

@(private)
program_pose :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,output:^Program_Output,transforms:core.Read(core.Transform)) -> bool {
    if !program_buffers(state,output,content) {state.program.error=.Out_Of_Memory;return false}
    runtime:=&state.program;n:=len(state.bindings);c:=len(state.curves)
    for instruction,i in output.instructions[:output.instruction_count] {
        instruction:=instruction
        key:=program_mask_key(state,instruction)
        if runtime.mask_bound!=state.bound || runtime.mask_keys[i]!=key {
            if instruction.mask[0]!=0 {runtime.error=.Unbound_Mask;return false}
            if !program_mask_over(state,instruction.over,runtime.masks[i*n:(i+1)*n]) {runtime.error=.Unbound_Mask;return false}
            runtime.mask_keys[i]=key
        }
        if instruction.kind==.Additive || instruction.curves==.Additive {
            if !program_evaluate_nodes(playback,state,content,output,int(instruction.right),instruction.reference) {return false}
            copy(runtime.reference_nodes[i*n:(i+1)*n],runtime.nodes[int(instruction.right)*n:(int(instruction.right)+1)*n])
            copy(runtime.reference_curves[i*c:(i+1)*c],runtime.node_curves[int(instruction.right)*c:(int(instruction.right)+1)*c])
        }
    }
    runtime.mask_bound=state.bound
    if !program_evaluate_nodes(playback,state,content,output,int(output.output)) {return false}
    pose:=runtime.nodes[int(output.output)*n:(int(output.output)+1)*n];curves:=runtime.node_curves[int(output.output)*c:(int(output.output)+1)*c]
    share:=mm.saturate(animation.weight)
    for value,b in pose {if state.bindings[b].target!=0 {state.local[b]=value if share==1 else state.bindings[b].rest if share==0 else mm.transform_interpolate(state.bindings[b].rest,value,share)}}
    for value,k in curves {value:=value;value.value*=share;value.weight*=share;state.curves[k]=value}
    if runtime.capture && runtime.last_dt==0 {copy(state.local[:],runtime.from[:]);copy(state.curves[:],runtime.from_curves[:]);return true}
    if runtime.capture && len(runtime.from)==n {
        previous:=runtime.history[:] if runtime.history_dt>0 else runtime.from[:]
        values:=runtime.inertia_values[:];old:=values[:c*5];now:=values[c*5:c*10];target:=values[c*10:c*15];target_previous:=values[c*15:]
        if !program_evaluate_nodes(playback,state,content,output,int(output.output),-2) {return false}
        before:=runtime.reference_nodes[int(output.output)*n:(int(output.output)+1)*n]
        for value,b in runtime.nodes[int(output.output)*n:(int(output.output)+1)*n] {before[b]=mm.transform_interpolate(state.bindings[b].rest,value,share)}
        for value,k in runtime.node_curves[int(output.output)*c:(int(output.output)+1)*c] {for v,j in value.value {target_previous[k*5+j]=v*share};target_previous[k*5+4]=value.weight*share}
        for value,k in runtime.from_curves {for v,j in value.value {now[k*5+j]=v;old[k*5+j]=runtime.history_curves[k].value[j]};now[k*5+4]=value.weight;old[k*5+4]=runtime.history_curves[k].weight}
        for value,k in state.curves {for v,j in value.value {target[k*5+j]=v};target[k*5+4]=value.weight}
        older:=runtime.nodes[int(output.output)*n:(int(output.output)+1)*n]
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
        before:=runtime.reference_nodes[int(output.output)*n:(int(output.output)+1)*n]
        if !program_evaluate_nodes(playback,state,content,output,int(output.output),-2) {return false}
        for value,b in runtime.nodes[int(output.output)*n:(int(output.output)+1)*n] {before[b]=mm.transform_interpolate(state.bindings[b].rest,value,share)}
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
program_mask_key :: proc(state:^Playing,instruction:Program_Instruction) -> u64 {
    instruction:=instruction
    runtime:=&state.program
    key:=base.hash_combine(state.bound,base.hash_combine(runtime.revision,base.name_hash(base.text_get(instruction.mask[:]))))
    key=base.hash_combine(key,base.hash_combine(runtime.asset[0],runtime.asset[1]))
    return base.hash_combine(key,instruction.over)
}
@(private)
program_masks_prepare :: proc(state:^Playing,output:^Program_Output,content:^host.Content_Animation,graphs:^Graph_Assets,app:^host.App) -> (ok:bool) {
    defer {if !ok && state.program.error==.None {state.program.error=.Unbound_Mask}}
    if !program_buffers(state,output,content) {state.program.error=.Out_Of_Memory;return false}
    runtime:=&state.program;n:=len(state.bindings)
    profile:Graph_Profile
    if runtime.kind==GRAPH_KIND {compiled:=graph_content(graphs,app,runtime.asset);if compiled==nil {return false};profile=compiled.profile
        maximum:=1
        for plan in compiled.plans[:len(profile.nodes)] {maximum=max(maximum,int(plan.count))}
        capacity:=min(PROGRAM_INSTRUCTIONS,maximum*2+1)
        c:=len(state.curves)
        if !program_array_reserve(&runtime.nodes,capacity*n) || !program_array_reserve(&runtime.reference_nodes,capacity*n) || !program_array_reserve(&runtime.node_properties,capacity*n) || !program_array_reserve(&runtime.node_weights,capacity*n) || !program_array_reserve(&runtime.masks,capacity*n) || !program_array_reserve(&runtime.node_curves,capacity*c) || !program_array_reserve(&runtime.reference_curves,capacity*c) {return false}
        players:=0;for node in profile.nodes {if node.kind==.Clip {players+=1} else if node.kind==.Blend_Space {players+=PROGRAM_LEAVES}}
        if !program_array_resize(&runtime.players,min(PROGRAM_PLAYERS,max(32,players*2))) {return false}
    }
    for instruction,i in output.instructions[:output.instruction_count] {
        instruction:=instruction
        key:=program_mask_key(state,instruction)
        if runtime.mask_bound==state.bound && runtime.mask_keys[i]==key {continue}
        if instruction.mask[0]==0 {if !program_mask_over(state,instruction.over,runtime.masks[i*n:(i+1)*n]) {return false};runtime.mask_keys[i]=key;continue}
        found:=-1
        for candidate,m in profile.masks {if candidate.name==instruction.mask {found=m;break}}
        if found<0 {return false}
        mask:=runtime.masks[i*n:(i+1)*n];for &weight in mask {weight=0}
        description:=profile.masks[found]
        for entry in profile.mask_bones[int(description.first):int(description.first)+int(description.count)] {
            selection,selected:=bone_select(state,bone_ref_hash(entry.bone));if !selected {return false}
            if selection.bone>=0 && !entry.branch {mask[selection.bone]=entry.weight;continue}
            for &weight,b in mask {if bone_selected(state,selection,b) {weight=entry.weight}}
        }
        if instruction.over!=0 {
            over,selected:=bone_select(state,instruction.over);if !selected {return false}
            for &weight,b in mask {if !bone_selected(state,over,b) {weight=0}}
        }
        runtime.mask_keys[i]=key
    }
    root_bone:=-1;greatest:f32=-1
    for group in output.groups[:output.count] {
        group:=group
        for leaf in group.leaves[:group.count] {
            index:=int(lib.clip_find(&content.lib,leaf.clip))-1
            if index<0 || index>=len(content.roots) {continue}
            meta:=content.roots[index]
            share:=leaf.weight*group.root_weight
            if (meta.translation || meta.rotation) && share>greatest {candidate:=bone_resolve(state,{meta.bone});if candidate>=0 {root_bone,greatest=candidate,share}}
        }
    }
    for &instruction,i in output.instructions[:output.instruction_count] {
        if instruction.kind==.Clip || instruction.kind==.Blend_Space {instruction.root_weight=runtime.masks[i*n+root_bone] if root_bone>=0 else 1;continue}
        if instruction.kind!=.Blend {continue}
        instruction.root_weight=instruction.weight
        if root_bone>=0 && (instruction.mask[0]!=0 || instruction.over!=0) {instruction.root_weight*=runtime.masks[i*n+root_bone]}
    }
    program_weights(output)
    runtime.mask_bound=state.bound
    return true
}
@(private)
program_compact :: proc(output:^Program_Output) {
    wanted:[PROGRAM_INSTRUCTIONS]bool;wanted[output.output]=true
    #reverse for instruction,i in output.instructions[:output.instruction_count] {if wanted[i] && instruction.kind!=.Clip && instruction.kind!=.Blend_Space {wanted[instruction.left],wanted[instruction.right]=true,true}}
    mapped:[PROGRAM_INSTRUCTIONS]u8
    count,operations:u8
    for instruction,i in output.instructions[:output.instruction_count] {
        if !wanted[i] {continue}
        value:=instruction;mapped[i]=operations
        if value.kind==.Clip || value.kind==.Blend_Space {output.groups[count]=output.groups[value.group];value.group=count;count+=1}
        else {value.left,value.right=mapped[value.left],mapped[value.right]}
        output.instructions[operations]=value;operations+=1
    }
    output.count=count;output.instruction_count=operations;output.output=mapped[output.output]
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
