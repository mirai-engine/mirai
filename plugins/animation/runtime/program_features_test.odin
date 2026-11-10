package anim

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:host"
import "mirai:asset"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
Program_Feature_Fixture :: struct {content:host.Content_Animation,state:Playing,playback:Playback,events:Animation_Events,output:^Program_Output,animation:Animation}
@(private)
program_feature_init :: proc(f:^Program_Feature_Fixture,t:^testing.T) {
    f.state=program_test_content(t,&f.content);f.output=new(Program_Output)
    testing.expect(t,f.output!=nil && tracks_bind(&f.playback,&f.state,&f.content))
    f.animation=ANIMATION_DEFAULT;f.animation.loop=false;f.animation.root_motion=.Extract
    copy(f.state.local[:],f.state.rest[:])
    resize(&f.state.sampled,len(f.state.rest));copy(f.state.sampled[:],f.state.rest[:])
}
@(private)
program_feature_free :: proc(f:^Program_Feature_Fixture) {
    program_test_content_free(&f.content);playing_free(&f.state);playback_free(&f.playback);delete(f.events.items);program_output_free(f.output);mem.free(f.output)
}
@(private)
program_feature_sample :: proc(f:^Program_Feature_Fixture,nodes:[]Graph_Node,output:u16,dt:f32) -> bool {
    clear(&f.events.items)
    return program_node(f.output,{info={animation={1,2},output=output},nodes=nodes},output,nil,nil,nil,{}) && program_players(&f.state,f.output,&f.content,f.animation,&f.events,&f.playback,dt,-1,nil) && program_pose(&f.playback,&f.state,&f.content,f.animation,f.output,{})
}

@(test)
nested_layer_inside_blend_preserves_sparse_channels_curves_events_and_root_motion :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    nodes:=program_test_graph()
    nodes[3].kind,nodes[3].left,nodes[3].right,nodes[3].weight=.Layer,1,2,.5
    nodes[4].kind,nodes[4].left,nodes[4].right,nodes[4].weight=.Blend,0,3,.25;nodes[4].over={}
    if !testing.expect(t,program_feature_sample(&f,nodes[:],4,.5)) {return}
    testing.expect(t,abs(f.state.local[1].position.x-.875)<1e-5)
    testing.expect_value(t,f.state.local[2].position,mm.Vec3{0,.125,0})
    testing.expect_value(t,f.state.local[3].position,mm.Vec3{0,.625,.375})
    testing.expect(t,abs(f.state.motion.translation.x-.875)<1e-5)
    testing.expect_value(t,len(f.events.items),2)
    for curve in f.state.curves {if curve.target==base.name_hash("pulse") {testing.expect(t,abs(curve.value.x+4*(1-curve.weight)-4.5)<1e-5)}}
    copied:Playing;core.value_copy(&copied,&f.state,type_info_of(Playing));defer playing_free(&copied)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=program_feature_sample(&f,nodes[:],4,0)
    stable &&=program_players(&copied,f.output,&f.content,f.animation,&f.events,&f.playback,0,-1,nil) && program_pose(&f.playback,&copied,&f.content,f.animation,f.output,{})
    context=saved;testing.expect(t,stable)
    for value,i in f.state.local {testing.expect_value(t,value,copied.local[i])}
}

@(test)
nested_additive_reference_evaluates_the_complete_right_subgraph_and_preserves_base_root :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    nodes:=program_test_graph();nodes[3].left,nodes[3].right,nodes[3].weight=0,1,.5
    nodes[4].kind,nodes[4].left,nodes[4].right,nodes[4].weight,nodes[4].reference=.Additive,0,3,.5,.25;nodes[4].over={}
    if !testing.expect(t,program_feature_sample(&f,nodes[:],4,.5)) {return}
    testing.expect(t,abs(f.state.local[1].position.x-.8125)<1e-5)
    testing.expect(t,abs(f.state.local[3].position.z-.5625)<1e-5)
    testing.expect(t,abs(f.state.motion.translation.x-.5)<1e-5)
    testing.expect_value(t,len(f.events.items),2)
}

@(test)
named_weighted_clock_uses_all_contributors_across_separate_composition_groups :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    program_test_sync_markers(&f.content)
    nodes:=program_test_graph()
    nodes[0].sync_mode,nodes[1].sync_mode=.Weighted,.Weighted
    nodes[0].loop,nodes[1].loop=true,true
    base.text_set(nodes[0].sync_group[:],"gait");base.text_set(nodes[1].sync_group[:],"gait")
    nodes[3].left,nodes[3].right,nodes[3].weight=0,1,.5
    base.text_set(nodes[3].over[:],"hip")
    if !testing.expect(t,program_feature_sample(&f,nodes[:],3,.5)) {return}
    walk,run:f32
    for player in f.state.program.players {if player.seen==0 {continue};clip:=lib.clip_data(&f.content.lib,player.player.clip);if clip.name==base.name_hash("walk") {walk=lib.player_time(&f.content.lib,player.player)};if clip.name==base.name_hash("run") {run=lib.player_time(&f.content.lib,player.player)}}
    testing.expect(t,abs(walk-2.0/3)<1e-5 && abs(run-1.0/3)<1e-5)
    testing.expect(t,abs(f.state.local[1].position.x-1)<1e-5)
    testing.expect(t,abs(f.state.motion.translation.x-1)<1e-5)
    testing.expect_value(t,len(f.events.items),1)
}

@(test)
weighted_graph_masks_keep_root_delta_consistent_with_the_masked_root_pose :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    nodes:=program_test_graph();nodes[3].weight=.5;base.text_set(nodes[3].mask[:],"upper")
    masks:=[1]Graph_Mask{{count=1}};base.text_set(masks[0].name[:],"upper")
    bones:=[1]Graph_Mask_Bone{{bone=bone_ref("hip"),weight=.25,branch=true}}
    profile:=Graph_Profile{info={animation={1,2},output=3},nodes=nodes[:],masks=masks[:],mask_bones=bones[:]}
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    graphs:Graph_Assets;defer delete(graphs.contents)
    compiled:=Graph_Content{id={1,2},checked=1,revision=1,valid=true,profile=profile}
    for _,i in nodes {compiled.plans[i],_=graph_plan(profile,i)}
    append(&graphs.contents,compiled)
    f.state.bound=1;f.state.program.kind=GRAPH_KIND;f.state.program.asset={1,2};f.state.program.revision=1
    if !testing.expect(t,program_node(f.output,profile,3,nil,nil,nil,{}) && program_masks_prepare(&f.state,f.output,&f.content,&graphs,app.assets,app.allocator)) {return}
    if !testing.expect(t,program_players(&f.state,f.output,&f.content,f.animation,&f.events,&f.playback,.5,-1,nil) && program_pose(&f.playback,&f.state,&f.content,f.animation,f.output,{})) {return}
    testing.expect(t,abs(f.state.local[1].position.x-.6875)<1e-5)
    testing.expect(t,abs(f.state.local[3].position.z-.5)<1e-5)
    testing.expect(t,abs(f.state.motion.translation.x-.6875)<1e-5)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    app.allocator=runtime.nil_allocator()
    stable:=program_masks_prepare(&f.state,f.output,&f.content,&graphs,app.assets,app.allocator) && program_players(&f.state,f.output,&f.content,f.animation,&f.events,&f.playback,0,-1,nil) && program_pose(&f.playback,&f.state,&f.content,f.animation,f.output,{})
    context=saved;testing.expect(t,stable)
}

@(test)
vector_curves_keep_every_component_and_slot_through_blend_and_additive_reference :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    f.animation.root_motion=.None
    tint:=base.name_hash("tint")
    f.content.lib.tracks[6]={target=tint,property=.Vector,slot=3,first=10,count=2}
    f.content.lib.tracks[7]={target=tint,property=.Vector,slot=3,first=12,count=2}
    f.content.lib.keys[10]={time=0};f.content.lib.keys[11]={time=2,value={2,4,6,8}}
    f.content.lib.keys[12]={time=0};f.content.lib.keys[13]={time=1,value={4,6,8,10}}
    f.content.lib.track_count,f.content.lib.key_count=8,14
    f.content.lib.clips[0].first_track,f.content.lib.clips[0].track_count=6,1
    f.content.lib.clips[2].first_track,f.content.lib.clips[2].track_count=7,1
    nodes:=program_test_graph()
    if !testing.expect(t,program_feature_sample(&f,nodes[:],3,.5)) {return}
    found:=false
    for curve in f.state.curves {if curve.property==.Vector && curve.target==tint && curve.slot==3 {testing.expect_value(t,curve.value,mm.Vec4{.875,1.5,2.125,2.75});testing.expect_value(t,curve.weight,f32(1));found=true}}
    testing.expect(t,found)
    nodes[3].kind,nodes[3].weight,nodes[3].reference=.Additive,.5,.25
    if !testing.expect(t,program_feature_sample(&f,nodes[:],3,0)) {return}
    for curve in f.state.curves {if curve.property==.Vector && curve.target==tint && curve.slot==3 {testing.expect_value(t,curve.value,mm.Vec4{1,1.75,2.5,3.25});testing.expect_value(t,curve.weight,f32(1))}}
}

@(test)
source_masks_blend_against_bind_pose_scale_root_motion_and_keep_property_curves :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    f.state.bindings[1].rest.position={3,2,1};f.state.rest[1]=f.state.bindings[1].rest
    nodes:=program_test_graph();base.text_set(nodes[1].mask[:],"upper")
    masks:=[1]Graph_Mask{{count=1}};base.text_set(masks[0].name[:],"upper")
    bones:=[1]Graph_Mask_Bone{{bone=bone_ref("hip"),weight=.25,branch=true}}
    profile:=Graph_Profile{info={animation={1,2},output=1},nodes=nodes[:],masks=masks[:],mask_bones=bones[:]}
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    graphs:Graph_Assets;defer delete(graphs.contents)
    compiled:=Graph_Content{id={1,2},checked=1,revision=1,valid=true,profile=profile}
    for _,i in nodes {compiled.plans[i],_=graph_plan(profile,i)}
    append(&graphs.contents,compiled)
    f.state.bound=1;f.state.program.kind=GRAPH_KIND;f.state.program.asset={1,2};f.state.program.revision=1
    if !testing.expect(t,program_node(f.output,profile,1,nil,nil,nil,{}) && program_masks_prepare(&f.state,f.output,&f.content,&graphs,app.assets,app.allocator)) {return}
    if !testing.expect(t,program_players(&f.state,f.output,&f.content,f.animation,&f.events,&f.playback,.5,-1,nil) && program_pose(&f.playback,&f.state,&f.content,f.animation,f.output,{})) {return}
    testing.expect_value(t,f.state.local[1].position,mm.Vec3{2.75,1.5,.75})
    testing.expect(t,abs(f.state.motion.translation.x-.5)<1e-5)
    found:=false
    for curve in f.state.curves {if curve.target==base.name_hash("pulse") {testing.expect_value(t,curve.value.x,f32(6));testing.expect_value(t,curve.weight,f32(1));found=true}}
    testing.expect(t,found)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=runtime.nil_allocator()
    stable:=program_masks_prepare(&f.state,f.output,&f.content,&graphs,app.assets,app.allocator) && program_players(&f.state,f.output,&f.content,f.animation,&f.events,&f.playback,0,-1,nil) && program_pose(&f.playback,&f.state,&f.content,f.animation,f.output,{})
    context=saved;testing.expect(t,stable)
    testing.expect_value(t,f.state.local[1].position,mm.Vec3{2.75,1.5,.75})
}

@(test)
distinct_named_source_clocks_preserve_marker_and_fixed_timelines_inside_plain_blends :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    program_test_sync_markers(&f.content)
    nodes:=program_test_graph();nodes[3].weight=.5
    nodes[0].sync_mode,nodes[1].sync_mode=.Markers,.Fixed
    nodes[0].loop,nodes[1].loop=true,true;nodes[1].sync_duration=2
    base.text_set(nodes[0].sync_group[:],"walk_clock");base.text_set(nodes[1].sync_group[:],"run_clock")
    if !testing.expect(t,program_feature_sample(&f,nodes[:],3,.5)) {return}
    testing.expect(t,abs(f.state.local[1].position.x-.75)<1e-5)
    testing.expect(t,abs(f.state.local[3].position.z-.25)<1e-5)
    testing.expect(t,abs(f.state.motion.translation.x-.75)<1e-5)
    testing.expect_value(t,len(f.events.items),2)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=program_feature_sample(&f,nodes[:],3,.1)
    context=saved;testing.expect(t,stable)
    testing.expect(t,abs(f.state.local[1].position.x-.9)<1e-5)
    testing.expect(t,abs(f.state.motion.translation.x-.15)<1e-5)
    testing.expect_value(t,len(f.events.items),0)
}

@(test)
switching_graph_assets_with_equal_revisions_refreshes_named_masks_without_rebinding_or_allocations :: proc(t:^testing.T) {
    f:Program_Feature_Fixture;program_feature_init(&f,t);defer program_feature_free(&f)
    nodes:=program_test_graph();base.text_set(nodes[1].mask[:],"upper")
    masks:=[1]Graph_Mask{{count=1}};base.text_set(masks[0].name[:],"upper")
    bones:=[2]Graph_Mask_Bone{{bone=bone_ref("hip"),weight=.25,branch=true},{bone=bone_ref("hip"),weight=.75,branch=true}}
    ids:=[2]base.Asset_Id{{71,72},{71,73}}
    assets:host.Assets
    assets.registry.by_id=make(map[base.Asset_Id]u32);defer delete(assets.registry.by_id);defer delete(assets.registry.files)
    graphs:Graph_Assets;defer delete(graphs.contents)
    for id,i in ids {
        profile:=Graph_Profile{info={animation={1,2},output=1},nodes=nodes[:],masks=masks[:],mask_bones=bones[i:i+1]}
        compiled:=Graph_Content{id=id,checked=1,revision=1,valid=true,profile=profile}
        for _,n in nodes {compiled.plans[n],_=graph_plan(profile,n)}
        append(&graphs.contents,compiled);append(&assets.registry.files,asset.Registry_File{id=id,kind=GRAPH_KIND,state=.Asset});assets.registry.by_id[id]=u32(i)
    }
    app:=host.App{assets=&assets,allocator=context.allocator}
    f.state.bound=1;f.animation.asset=ids[0]
    step :: proc(f:^Program_Feature_Fixture,app:^host.App,graphs:^Graph_Assets) -> bool {
        output,programmed,ok:=program_resolve(&f.state,f.animation,app,nil,graphs,.25,nil)
        return ok && programmed && program_masks_prepare(&f.state,output,&f.content,graphs,app.assets,app.allocator) && program_players(&f.state,output,&f.content,f.animation,&f.events,&f.playback,.25,-1,nil) && program_pose(&f.playback,&f.state,&f.content,f.animation,output,{})
    }
    if !testing.expect(t,step(&f,&app,&graphs)) {return}
    testing.expect_value(t,f.state.local[1].position.x,f32(.25));testing.expect_value(t,f.state.motion.translation.x,f32(.25))
    f.animation.asset=ids[1]
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=runtime.nil_allocator()
    stable:=step(&f,&app,&graphs)
    context=saved;testing.expect(t,stable)
    testing.expect_value(t,f.state.local[1].position.x,f32(.75));testing.expect_value(t,f.state.motion.translation.x,f32(.75))
}

@(test)
failed_tick_preparation_retires_previous_root_delta_and_markers_while_preserving_pending_requests :: proc(t:^testing.T) {
    playback:Playback;defer playback_free(&playback)
    entity:=core.entity_make(1,1);playback.frame=11
    resize(&playback.rows,2);playback.rows[1]=1
    append(&playback.states,Playing{entity=entity,seen=11,root_enabled=true,motion={translation={.5,0,0},rotation=1}})
    requests:Animation_Requests;defer delete(requests.timeline.items);defer delete(requests.distances.items)
    core.push(&requests.timeline,Animation_Command{entity=entity,time=.7})
    events:Animation_Events;defer delete(events.items);core.push(&events.queue,Animation_Marker{entity=entity,marker=1})
    app:=host.App{allocator=runtime.nil_allocator()}
    _,valid:=animation_root_delta(&playback,entity);testing.expect(t,valid)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    animation_tick({},nil,{},{},{},&requests,&events,{},{},&playback,&app,{dt=1.0/60,playing=true},{},nil,nil)
    context=saved
    delta,available:=animation_root_delta(&playback,entity)
    testing.expect(t,!available);testing.expect_value(t,delta,ROOT_DELTA_DEFAULT)
    testing.expect_value(t,len(events.items),0);testing.expect_value(t,len(requests.timeline.items),1)
    testing.expect_value(t,requests.timeline.items[0].time,f32(.7))
}
