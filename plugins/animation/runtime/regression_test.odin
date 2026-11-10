package anim

import "core:testing"
import "core:mem"

import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"

@(test)
program_component_layers_preserve_scalar_curves :: proc(t:^testing.T) {
    content:host.Content_Animation; defer program_test_content_free(&content)
    playback:Playback; defer playback_free(&playback)
    append(&playback.states, program_test_content(t,&content)); state:=&playback.states[0]
    resize(&playback.rows,2); playback.rows[1]=1; playback.frame,state.seen=1,1
    testing.expect(t,lib.pose_init(&playback.pose,64))
    content.lib.clips[1].first_track,content.lib.clips[1].track_count=2,4
    content.lib.clips[4]=content.lib.clips[1]; content.lib.clips[4].loop=.Loop
    nodes:=program_test_graph(); profile:=Graph_Profile{info={animation={1,2},output=0},nodes=nodes[:]}
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,profile,0,nil,nil,nil,{}); if !testing.expect(t,ok) {return}
    animation:=ANIMATION_DEFAULT; animation.loop=false
    testing.expect(t,animation_play(&animation,"wave",layer=1,fade=0,loop=false,weight=1))
    events:Animation_Events; defer delete(events.items)
    testing.expect(t,program_players(state,output,&content,animation,&events,&playback,0,-1,nil))
    testing.expect(t,program_pose(&playback,state,&content,animation,output,{}))
    layers_advance(&playback,state,&content,animation,&events,0,nil)
    pose_layers(&playback,state,&content.lib,animation,nil)
    sample_layer_curves(state,&content,animation)
    got:=animation_curve(&playback,state.entity,"pulse",default_value=2)
    testing.expect_value(t,state.local[2].position.y,f32(1))
    testing.expect_value(t,got,f32(6))
}

@(test)
program_zero_weight_layers_suppress_events :: proc(t:^testing.T) {
    content:host.Content_Animation; defer program_test_content_free(&content)
    state:=program_test_content(t,&content); defer playing_free(&state)
    playback:Playback; defer playback_free(&playback)
    events:Animation_Events; defer delete(events.items)
    nodes:=program_test_graph(); nodes[4].left,nodes[4].right,nodes[4].weight=0,1,0
    profile:=Graph_Profile{info={animation={1,2},output=4},nodes=nodes[:]}
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,profile,4,nil,nil,nil,{}); if !testing.expect(t,ok) {return}
    animation:=ANIMATION_DEFAULT; animation.loop=false
    testing.expect(t,program_players(&state,output,&content,animation,&events,&playback,.13,-1,nil))
    testing.expect_value(t,len(events.items),0)
}

@(test)
program_root_channel_mismatch_rejects_before_clocks_or_events :: proc(t:^testing.T) {
    content:host.Content_Animation; defer program_test_content_free(&content)

    state:=program_test_content(t,&content); defer playing_free(&state)
    playback:Playback; defer playback_free(&playback)
    events:Animation_Events; defer delete(events.items)
    content.roots[2].translation=false; content.roots[2].rotation=true
    nodes:=program_test_graph(); profile:=Graph_Profile{info={animation={1,2},output=3},nodes=nodes[:]}
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)};ok:=program_node(output,profile,3,nil,nil,nil,{}); if !testing.expect(t,ok) {return}
    animation:=ANIMATION_DEFAULT; animation.loop=false; animation.root_motion=.In_Place
    testing.expect(t,!program_players(&state,output,&content,animation,&events,&playback,.5,-1,nil))
    testing.expect_value(t,state.program.error,Program_Error.Incompatible_Root)
    testing.expect(t,state.program.frame==0 && len(events.items)==0 && state.motion.translation=={})
}