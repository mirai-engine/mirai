package anim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
program_test_content :: proc(t:^testing.T,content:^host.Content_Animation) -> Playing {
    state:=layer_fixture(t,content)
    content.roots=make([]asset.Animation_Root,3)
    for i in ([2]int{0,2}) {base.text_set(content.roots[i].bone[:],"hip");content.roots[i].translation=true}
    content.lib.tracks[5]={target=base.name_hash("pulse"),property=.Float,first=8,count=1}
    content.lib.keys[8]={value={6,0,0,0}}
    content.lib.track_count,content.lib.key_count=6,9
    content.lib.clips[2].track_count,content.lib.clips[5].track_count=2,2
    content.lib.markers=make([]lib.Marker,2);content.lib.marker_count=2
    content.lib.markers[0]={time=.25,id=0};content.lib.markers[1]={time=.125,id=0}
    content.lib.clips[0].first_marker,content.lib.clips[0].marker_count=0,1
    content.lib.clips[2].first_marker,content.lib.clips[2].marker_count=1,1
    content.lib.clips[3]=content.lib.clips[0];content.lib.clips[3].loop=.Loop
    content.lib.clips[5]=content.lib.clips[2];content.lib.clips[5].loop=.Loop
    content.markers=make([]u64,1);content.markers[0]=base.name_hash("step")
    return state
}

@(private)
program_test_content_free :: proc(content:^host.Content_Animation) {lib.library_destroy(&content.lib);delete(content.roots);delete(content.markers)}

@(private)
program_test_sync_markers :: proc(content:^host.Content_Animation) {
    delete(content.lib.markers);content.lib.markers=make([]lib.Marker,4);content.lib.marker_count=4
    markers:=[4]lib.Marker{{time=.2,id=0},{time=1.2,id=1},{time=.1,id=0},{time=.4,id=1}};copy(content.lib.markers,markers[:])
    for index in ([2]int{0,3}) {content.lib.clips[index].first_marker,content.lib.clips[index].marker_count=0,2}
    for index in ([2]int{2,5}) {content.lib.clips[index].first_marker,content.lib.clips[index].marker_count=2,2}
    delete(content.markers);content.markers=make([]u64,2);content.markers[0],content.markers[1]=base.name_hash("step"),base.name_hash("lift")
}

@(private)
program_test_graph :: proc() -> [5]Graph_Node {
    nodes:[5]Graph_Node
    for &node,i in nodes {node=GRAPH_NODE_DEFAULT;node.loop,node.sync_mode=false,.Independent;base.text_set(node.name[:],fmt.tprintf("node%d",i))}
    base.text_set(nodes[0].clip[:],"walk");base.text_set(nodes[1].clip[:],"run");base.text_set(nodes[2].clip[:],"wave")
    nodes[3].kind=.Blend;nodes[3].left,nodes[3].right,nodes[3].weight=0,1,.25
    nodes[4].kind=.Layer;nodes[4].left,nodes[4].right,nodes[4].weight=3,2,.5;base.text_set(nodes[4].over[:],"hip")
    return nodes
}

@(test)
animation_programs_blend_weighted_poses_curves_root_motion_and_masked_layers_without_allocations :: proc(t:^testing.T) {
    problems:core.Problems
    content:host.Content_Animation;defer program_test_content_free(&content)
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,program_test_content(t,&content));state:=&playback.states[0]
    resize(&playback.rows,2);playback.rows[1]=1
    testing.expect(t,lib.pose_init(&playback.pose,64))
    events:Animation_Events;defer delete(events.items)
    nodes:=program_test_graph();profile:=Graph_Profile{info={animation={1,2},output=4},nodes=nodes[:]}
    if !testing.expect(t,graph_check(profile)) {return}
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,profile,4,nil,nil,nil,{})
    if !testing.expect(t,ok && output.count==2 && output.groups[output.primary].count==2) {return}
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    playback.frame,state.seen=1,1;state.program.ready=true
    if !testing.expect(t,program_players(state,output,&content,animation,&events,&playback,.5,-1,&problems)) {return}
    program_pose(&playback,state,&content,animation,output,{})
    testing.expect(t,abs(state.local[1].position.x-.875)<1e-5)
    testing.expect(t,abs(state.local[3].position.z-.375)<1e-5 && state.local[3].position.y==0)
    testing.expect_value(t,state.local[2].position,mm.Vec3{0,.5,0})
    testing.expect(t,abs(animation_curve(&playback,state.entity,"pulse",default_value=5)-5.25)<1e-5)
    delta,present:=animation_root_delta(&playback,state.entity)
    testing.expect(t,present && abs(delta.translation.x-.875)<1e-5)
    testing.expect_value(t,len(events.items),2)
    for event in events.items {testing.expect(t,event.entity==state.entity && event.marker==base.name_hash("step"))}
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    constraints:Animation_Constraints;defer constraints_free(&constraints)
    state.program.root.in_place=true
    constraints_apply(state,&playback,{},&constraints,&transforms,{},0)
    testing.expect_value(t,state.local[1].position,mm.Vec3{})
    copy(state.local[:],state.rest[:]);state.program.root.in_place=false
    resize(&state.program.from,len(state.local));copy(state.program.from[:],state.local[:])
    before:=state.program.players[0].player.time
    copied:Playback;core.value_copy(&copied,&playback,type_info_of(Playback));defer playback_free(&copied)
    copied.states[0].program.from[1].position.x=17
    copied.states[0].program.players[0].player.time=17
    testing.expect(t,state.program.from[1].position.x==0 && raw_data(copied.states[0].program.from)!=raw_data(state.program.from))
    testing.expect(t,state.program.players[0].player.time==before && raw_data(copied.states[0].program.players)!=raw_data(state.program.players))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    steady:=true
    for _ in 0..<100 {
        clear(&events.items)
        steady &&=program_players(state,output,&content,animation,&events,&playback,0,-1,&problems)
        program_pose(&playback,state,&content,animation,output,{})
    }
    context=saved
    testing.expect(t,steady && state.program.players[0].player.time==before)
    testing.expect(t,abs(state.local[1].position.x-.875)<1e-5 && playback.pose.failed==0 && problems.count==0)
}

@(test)
synchronized_program_players_share_phase_across_clip_durations_and_emit_only_the_leader_events :: proc(t:^testing.T) {
    content:host.Content_Animation;defer program_test_content_free(&content)
    state:=program_test_content(t,&content);defer playing_free(&state)
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    nodes:=program_test_graph();nodes[0].sync_mode,nodes[1].sync_mode=.Markers,.Markers
    base.text_set(nodes[0].sync_group[:],"locomotion");base.text_set(nodes[1].sync_group[:],"locomotion")
    nodes[0].loop,nodes[1].loop=true,true
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,{info={animation={1,2},output=3},nodes=nodes[:]},3,nil,nil,nil,{})
    if !testing.expect(t,ok) {return}
    animation:=ANIMATION_DEFAULT;animation.root_motion=.Extract
    if !testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.5,-1,nil)) {return}
    group:=output.groups[0]
    walk:=state.program.players[group.leaves[0].player].player
    run:=state.program.players[group.leaves[1].player].player
    testing.expect(t,abs(lib.player_time(&content.lib,walk)/2-lib.player_time(&content.lib,run))<1e-5)
    testing.expect_value(t,len(events.items),1)
    testing.expect_value(t,events.items[0].clip,base.name_hash("walk"))
    testing.expect(t,abs(state.motion.translation.x-.625)<1e-5)
    for _ in 0..<4 {
        clear(&events.items)
        testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.5,-1,nil))
        walk=state.program.players[group.leaves[0].player].player
        run=state.program.players[group.leaves[1].player].player
        testing.expect(t,abs(lib.player_time(&content.lib,walk)/2-lib.player_time(&content.lib,run))<1e-5)
        testing.expect(t,abs(state.motion.translation.x-.625)<1e-5)
    }
}

@(test)
synchronized_program_players_preserve_marker_phase_when_new_samples_take_the_lead_without_allocations :: proc(t:^testing.T) {
    problems:core.Problems
    content:host.Content_Animation;defer program_test_content_free(&content)
    state:=program_test_content(t,&content);defer playing_free(&state)
    program_test_sync_markers(&content)
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    testing.expect(t,lib.pose_init(&playback.pose,64))
    walk:=Program_Leaf{key=0,weight=1,speed=1,loop=true,sync=true};walk.clip=base.name_hash("walk")
    run:=Program_Leaf{key=256,weight=.9,speed=1,loop=true,sync=true};run.clip=base.name_hash("run")
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)}
    if !testing.expect(t,program_output_prepare(output,1,1)) {return}
    output.count,output.instruction_count=1,1;output.groups[0]={count=1,weight=1,root_weight=1,leaves={0=walk}}
    animation:=ANIMATION_DEFAULT;animation.root_motion=.Extract
    if !testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.7,-1,&problems) && program_pose(&playback,&state,&content,animation,output,{})) {return}
    testing.expect_value(t,len(events.items),1)
    clear(&events.items)
    output.groups[0].leaves[0]=run;output.groups[0].leaves[0].weight=1
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    valid:=program_players(&state,output,&content,animation,&events,&playback,0,-1,&problems) && program_pose(&playback,&state,&content,animation,output,{})
    exclusive_handoff:=abs(state.time-.25)<1e-5 && state.motion.translation.x==0 && len(events.items)==0
    output.groups[0].count=2;output.groups[0].leaves[0]=walk;output.groups[0].leaves[0].weight=.1;output.groups[0].leaves[1]=run
    valid &&=program_players(&state,output,&content,animation,&events,&playback,0,-1,&problems) && program_pose(&playback,&state,&content,animation,output,{})
    leader:=state.program.players[output.groups[0].leaves[1].player].player
    follower:=state.program.players[output.groups[0].leaves[0].player].player
    phase,phase_valid:=lib.sync_phase(&content.lib,leader)
    preserved:=abs(leader.time-.25)<1e-5 && abs(follower.time-.7)<1e-5 && phase_valid && phase.markers && abs(phase.fraction-.5)<1e-5
    no_repeated_events:=len(events.items)==0
    root_at_handoff:=state.motion.translation.x
    output.groups[0].leaves[0].weight=.9;output.groups[0].leaves[1].weight=.1
    valid &&=program_players(&state,output,&content,animation,&events,&playback,.1,-1,&problems) && program_pose(&playback,&state,&content,animation,output,{})
    leader=state.program.players[output.groups[0].leaves[0].player].player
    follower=state.program.players[output.groups[0].leaves[1].player].player
    existing_leader_continuity:=abs(leader.time-.8)<1e-5 && abs(follower.time-.28)<1e-5 && abs(state.motion.translation.x-.102)<1e-5
    output.groups[0].count=1;output.groups[0].leaves[0]=run;output.groups[0].leaves[0].weight=1
    valid &&=program_players(&state,output,&content,animation,&events,&playback,.5,-1,&problems) && program_pose(&playback,&state,&content,animation,output,{})
    retired_leader:=abs(state.time-.78)<1e-5 && abs(state.motion.translation.x-2)<1e-5 && len(events.items)==1 && events.items[0].marker==base.name_hash("lift")
    clear(&events.items)
    output.groups[0].count=2;output.groups[0].leaves[0]=walk;output.groups[0].leaves[0].weight=.75;output.groups[0].leaves[1]=run;output.groups[0].leaves[1].weight=.25
    valid &&=program_players(&state,output,&content,animation,&events,&playback,.1,-1,&problems) && program_pose(&playback,&state,&content,animation,output,{})
    leader=state.program.players[output.groups[0].leaves[0].player].player
    follower=state.program.players[output.groups[0].leaves[1].player].player
    reentry:=abs(leader.time-(1.2+(.38/.7)+.1))<1e-5 && abs(follower.time-.85)<1e-5 && abs(state.motion.translation.x-.145)<1e-5 && len(events.items)==0
    context=saved
    testing.expect(t,valid && exclusive_handoff && preserved && no_repeated_events && root_at_handoff==0)
    testing.expect(t,existing_leader_continuity && retired_leader && reentry)
    testing.expect(t,playback.pose.failed==0 && problems.count==0)
}

@(test)
synchronized_program_players_preserve_once_completion_and_leave_independent_samples_unsynchronized :: proc(t:^testing.T) {
    problems:core.Problems
    content:host.Content_Animation;defer program_test_content_free(&content)
    state:=program_test_content(t,&content);defer playing_free(&state)
    program_test_sync_markers(&content)
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    walk:=Program_Leaf{key=0,weight=1,speed=1,sync=true};walk.clip=base.name_hash("walk")
    run:=Program_Leaf{key=256,weight=1,speed=1,sync=true};run.clip=base.name_hash("run")
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)}
    if !testing.expect(t,program_output_prepare(output,1,1)) {return}
    output.count,output.instruction_count=1,1;output.groups[0]={count=1,weight=1,root_weight=1,leaves={0=walk}}
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    if !testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,2,-1,&problems)) {return}
    testing.expect(t,state.ended && state.time==2)
    clear(&events.items)
    output.groups[0].leaves[0]=run
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    valid:=program_players(&state,output,&content,animation,&events,&playback,.1,-1,&problems)
    once_completion:=state.ended && state.time==1 && state.motion.translation.x==0 && len(events.items)==0
    animation.playing=false
    valid &&=program_players(&state,output,&content,animation,&events,&playback,0,-1,&problems)
    animation.playing=true
    valid &&=program_players(&state,output,&content,animation,&events,&playback,.25,-1,&problems)
    once_replay:=!state.ended && abs(state.time-.25)<1e-5 && abs(state.motion.translation.x-1)<1e-5
    clear(&events.items)
    run.key=512;run.sync=false;output.groups[0].leaves[0]=run
    valid &&=program_players(&state,output,&content,animation,&events,&playback,.1,-1,&problems)
    independent:=abs(state.time-.1)<1e-5 && abs(state.motion.translation.x-.4)<1e-5 && !state.ended
    for &slot in state.program.players {slot={}}
    walk.loop=true;output.groups[0].leaves[0]=walk
    valid &&=program_players(&state,output,&content,animation,&events,&playback,.2,-1,&problems)
    reset_from_empty:=abs(state.time-.2)<1e-5 && abs(state.motion.translation.x-.2)<1e-5
    context=saved
    testing.expect(t,valid && once_completion && once_replay && independent && reset_from_empty)
    testing.expect_value(t,problems.count,0)
}

@(test)
shared_graph_nodes_preserve_full_root_motion_and_do_not_double_animation_events :: proc(t:^testing.T) {
    content:host.Content_Animation;defer program_test_content_free(&content)
    state:=program_test_content(t,&content);defer playing_free(&state)
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    nodes:=program_test_graph();nodes[3].left,nodes[3].right,nodes[3].weight=0,0,.5
    profile:=Graph_Profile{info={animation={1,2},output=3},nodes=nodes[:]}
    testing.expect(t,graph_check(profile))
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,profile,3,nil,nil,nil,{})
    if !testing.expect(t,ok) {return}
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.5,-1,nil))
    testing.expect(t,abs(state.motion.translation.x-.5)<1e-5)
    testing.expect_value(t,len(events.items),1)
}

@(test)
program_players_allocate_only_for_programs_replay_once_clips_and_retire_optional_buffers :: proc(t:^testing.T) {
    content:host.Content_Animation;defer program_test_content_free(&content)
    state:=program_test_content(t,&content);defer playing_free(&state)
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    nodes:=program_test_graph()
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,{info={animation={1,2}},nodes=nodes[:]},0,nil,nil,nil,{})
    if !testing.expect(t,ok) {return}
    animation:=ANIMATION_DEFAULT;animation.loop=false
    testing.expect(t,state.program.players==nil && state.program.from==nil && state.program.from_curves==nil)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    failed:=program_players(&state,output,&content,animation,&events,&playback,0,-1,nil)
    context=saved
    testing.expect(t,!failed && len(state.program.players)==0 && state.program.frame==0)
    if !testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,2,-1,nil)) {return}
    testing.expect(t,len(state.program.players)>0 && state.ended && state.time==2)
    animation.playing=false
    testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.1,-1,nil))
    testing.expect(t,!state.was_playing && state.ended && state.time==2)
    animation.playing=true
    testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.5,-1,nil))
    testing.expect(t,state.was_playing && !state.ended && abs(state.time-.5)<1e-5)
    slots:=raw_data(state.program.players)
    resize(&state.program.from,4)
    testing.expect(t,program_curves_prepare(&state.program,2))
    assets:host.Assets
    app:=host.App{assets=&assets,allocator=context.allocator}
    animation.asset={5,6}
    _,programmed,valid:=program_resolve(&state,animation,&app,nil,nil,0,nil)
    testing.expect(t,valid && !programmed && cap(state.program.players)==0 && cap(state.program.from)==0 && cap(state.program.from_curves)==0 && !state.program.ready)
    testing.expect(t,slots!=nil)
}
