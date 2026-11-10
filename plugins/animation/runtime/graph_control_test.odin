package anim

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
Graph_Control_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    targets:core.Table(Animation_Target),
    animations:core.Table(Animation),
}

@(test)
named_parameters_set_graph_parameters_and_blend_axes_and_report_unknown_names :: proc(t:^testing.T) {
    animation:=ANIMATION_DEFAULT
    testing.expect(t,!animation_parameter(&animation,"",1) && !animation_parameter(&animation,"speed",transmute(f32)u32(0x7f800000)) && !animation_parameter(nil,"speed",1))
    for i in 0..<GRAPH_PARAMETERS {testing.expect(t,animation_parameter(&animation,fmt.tprintf("p%d",i),f32(i)))}
    testing.expect(t,!animation_parameter(&animation,"extra",1),"at most GRAPH_PARAMETERS names")
    testing.expect(t,animation_parameter(&animation,"p3",9),"a known name changes its value")
    value,set:=animation_parameter_value(animation,"p3");testing.expect(t,set && value==9)
    _,set=animation_parameter_value(animation,"extra");testing.expect(t,!set)
    animation_parameters_clear(&animation);_,set=animation_parameter_value(animation,"p3");testing.expect(t,!set && animation.parameter_names=={})

    directory:=base.test_folder(t,"named-parameters")
    space:=blend_test_profile();defer blend_profile_free(&space)
    testing.expect_value(t,blend_space_prepare(&space),asset.Error.None)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id,graph_id:=base.Asset_Id{53,54},base.Asset_Id{53,55}
    if !testing.expect_value(t,blend_space_save(fmt.tprintf("%s/space.blend",directory),&types,id,space),asset.Error.None) {return}
    // An aim offset over a clip: the axes of the space are parameters of the graph, by name.
    nodes:=[3]Graph_Node{GRAPH_NODE_DEFAULT,GRAPH_NODE_DEFAULT,GRAPH_NODE_DEFAULT}
    for &node,i in nodes {base.text_set(node.name[:],fmt.tprintf("node%d",i))}
    base.text_set(nodes[0].clip[:],"clip0")
    nodes[1].kind,nodes[1].blend_space,nodes[1].x_param,nodes[1].y_param=.Blend_Space,id,0,1
    nodes[2].kind,nodes[2].left,nodes[2].right=.Additive,0,1
    parameters:=[2]Graph_Parameter{{min=-100,max=100},{min=0,max=10}};base.text_set(parameters[0].name[:],"Direction");base.text_set(parameters[1].name[:],"Speed")
    if !testing.expect_value(t,graph_save(fmt.tprintf("%s/aim.agraph",directory),&types,graph_id,{info={animation={3,4},output=2},parameters=parameters[:],nodes=nodes[:]}),asset.Error.None) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    blends:Blend_Assets;defer blend_assets_free(&blends)
    graphs:Graph_Assets;defer graph_assets_free(&graphs)
    state:Playing;defer playing_free(&state)
    animation.asset=graph_id
    testing.expect(t,animation_parameter(&animation,"Speed",5) && animation_parameter(&animation,"Direction",100))
    output,_,ok:=program_resolve(&state,animation,&app,&blends,&graphs,0)
    if !testing.expect(t,ok && output.count==2) {return}
    weights:[4]f32
    for &group in output.groups[:output.count] {for leaf in group.leaves[:group.count] {for i in 0..<4 {if leaf.clip==base.name_hash(fmt.tprintf("clip%d",i)) {weights[i]+=leaf.weight}}}}
    testing.expect(t,weights[0]==1 && abs(weights[1]-.5)<1e-5 && abs(weights[2]-.5)<1e-5,"the axes take the values set by their names")
    testing.expect(t,animation_parameter(&animation,"Wave",1))
    _,_,ok=program_resolve(&state,animation,&app,&blends,&graphs,0)
    testing.expect(t,!ok && state.program.error==.Unknown_Parameter)

    // A .blend alone is not locomotion: Animation.asset refuses it and says where it plays.
    w:Graph_Control_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    actor:=core.create(&w.entities);spaced:=ANIMATION_DEFAULT;spaced.asset=id
    core.add(&w.transforms,actor,core.TRANSFORM_IDENTITY);core.add(&w.animations,actor,spaced)
    core.test_world_settle(&w)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    core.hierarchy_settle(&hierarchy,core.read(&w.parents),&w.entities)
    requests:Animation_Requests;events:Animation_Events;playback:Playback;skeletons:Skeleton_Assets;problems:core.Problems
    defer {delete(requests.distances.items);delete(events.items);playback_free(&playback);skeleton_assets_free(&skeletons)}
    animation_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&hierarchy),core.read(&w.names),&requests,&events,core.read(&w.targets),{},&playback,&app,{dt=.1,playing=true},{},&skeletons,&problems,&blends,&graphs)
    testing.expect(t,core.problem_find(&problems,actor,"animation.additive_space")!=nil && problems.count==1)
    _,programmed,refused:=program_resolve(&state,spaced,&app,&blends,&graphs,0)
    testing.expect(t,programmed && !refused && state.program.error==.Additive_Space)
}

@(test)
a_library_replaces_the_clips_of_a_program_and_restarts_it :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"library")
    profile:=graph_test_profile();defer graph_profile_free(&profile)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    graph_id,library_id:=base.Asset_Id{55,56},base.Asset_Id{57,58}
    if !testing.expect_value(t,graph_save(fmt.tprintf("%s/machine.agraph",directory),&types,graph_id,profile),asset.Error.None) {return}
    keys:=[2]lib.Keyframe{{time=0},{time=1,value={1,0,0,0}}}
    tracks:=[1]asset.Animation_Track_Desc{{target="hip",property=.Position,keys=keys[:]}}
    clips:=[2]asset.Animation_Clip_Desc{{name="walk",tracks=tracks[:]},{name="run",tracks=tracks[:]}}
    if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/other.anim",directory),&types,{id=library_id,clips=clips[:]}),asset.Error.None) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    graphs:Graph_Assets;defer graph_assets_free(&graphs)
    state:Playing;defer playing_free(&state)
    animation:=ANIMATION_DEFAULT;animation.asset=graph_id
    output,_,ok:=program_resolve(&state,animation,&app,nil,&graphs,0,nil)
    testing.expect(t,ok && output.asset==profile.info.animation,"without library the graph plays its source")
    state.program.epoch=7
    animation.library=library_id
    output,_,ok=program_resolve(&state,animation,&app,nil,&graphs,0,nil)
    testing.expect(t,ok && output.asset==library_id && state.program.library==library_id && state.program.epoch==0,"a new library restarts the program on its clips")
    animation.library=graph_id
    _,_,ok=program_resolve(&state,animation,&app,nil,&graphs,0,nil)
    testing.expect(t,!ok && state.program.error==.Invalid_Asset,"a library must be an .anim")
}

@(private="file")
Mirror_Fixture :: struct {
    using w:Graph_Control_World,
    bones:[3]asset.Skeleton_Bone,
    definition:Skeleton_Content,
    content:host.Content_Animation,
    playback:Playback,
    rig:core.Entity,
}

@(private="file")
mirror_fixture :: proc(t:^testing.T,f:^Mirror_Fixture) -> ^Playing {
    if !core.test_world_init(t,&f.w,test_types) {return nil}
    f.rig=core.create(&f.entities)
    core.add(&f.transforms,f.rig,core.TRANSFORM_IDENTITY);core.test_world_settle(&f.w)
    f.bones={{parent=-1,translation={0,1,0},rotation=1,scale={1,1,1}},{parent=0,translation={-.2,-.1,0},rotation=1,scale={1,1,1}},{parent=0,translation={.2,-.1,0},rotation=1,scale={1,1,1}}}
    names:=[3]string{"pelvis","leg_l","leg_r"};paths:=[3]string{"pelvis","pelvis/leg_l","pelvis/leg_r"}
    for &bone,i in f.bones {base.text_set(bone.name[:],names[i]);base.text_set(bone.path[:],paths[i]);bone.target=base.name_hash(paths[i])}
    pairs,ok:=skeleton_mirror_pairs(f.bones[:])
    testing.expect(t,ok && len(pairs)==3 && pairs[0]==0 && pairs[1]==2 && pairs[2]==1,"bones pair by the side in their names")
    f.definition={id={9,8},revision=1,bones=f.bones[:],mirror=pairs}
    testing.expect(t,lib.library_init(&f.content.lib,{max_keys=8,max_tracks=4,max_clips=2,max_markers=0}))
    turn:=[1]lib.Keyframe{{value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.5))}}
    slide:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=1,value={1,1,0,0}}}
    kick,_:=lib.clip_add(&f.content.lib,{name=base.name_hash("kick"),tracks={{target=base.name_hash("pelvis/leg_l"),property=.Rotation,keys=turn[:]},{target=base.name_hash("pelvis"),property=.Position,keys=slide[:]}}})
    testing.expect(t,kick!=0)
    f.content.lib.clips[1]=f.content.lib.clips[0];f.content.lib.clips[1].loop=.Loop;f.content.lib.clip_count=2;f.content.clip_count=1
    f.content.roots=make([]asset.Animation_Root,1);base.text_set(f.content.roots[0].bone[:],"pelvis");f.content.roots[0].translation=true
    state:=state_get(&f.playback,f.rig)
    testing.expect(t,skeleton_bind(&f.playback,state,&f.definition,&f.content,&f.transforms))
    return state
}
@(private="file")
mirror_fixture_free :: proc(f:^Mirror_Fixture) {
    playback_free(&f.playback);lib.library_destroy(&f.content.lib);delete(f.content.roots);delete(f.definition.mirror)
    core.test_world_destroy(&f.w)
}

@(test)
mirrored_graph_sources_and_rigs_swap_sides_and_reflect_root_motion :: proc(t:^testing.T) {
    f:Mirror_Fixture;state:=mirror_fixture(t,&f);defer mirror_fixture_free(&f)
    if state==nil {return}
    testing.expect(t,len(state.mirror_pairs)==4 && state.mirror_pairs[2]==3 && state.mirror_pairs[3]==2 && abs(abs(state.mirror_plane.normal.x)-1)<1e-5)
    events:Animation_Events;defer {delete(events.items);delete(events.plays.items)}
    nodes:=[1]Graph_Node{GRAPH_NODE_DEFAULT};base.text_set(nodes[0].name[:],"kick");base.text_set(nodes[0].clip[:],"kick");nodes[0].loop,nodes[0].sync_mode=false,.Independent
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    poses:[2][4]mm.Transform;motions:[2]Root_Delta
    for mirror,i in ([2]bool{false,true}) {
        nodes[0].mirror=mirror
        profile:=Graph_Profile{info={animation={1,2}},nodes=nodes[:]}
        if !testing.expect(t,graph_check(profile)) {return}
        program_free(&state.program)
        output:=new(Program_Output);defer {program_output_free(output);mem.free(output)}
        if !testing.expect(t,program_node(output,profile,0,nil,nil,nil,{}) && output.groups[0].mirror==mirror) {return}
        f.playback.frame+=1;state.seen=f.playback.frame;state.program.ready=true
        copy(state.local[:],state.rest[:])
        if !testing.expect(t,program_players(state,output,&f.content,animation,&events,&f.playback,.5,-1,nil) && program_pose(&f.playback,state,&f.content,animation,output,{})) {return}
        copy(poses[i][:],state.local[:]);motions[i]=state.motion
    }
    left,right:=poses[1][2],poses[1][3]
    testing.expect(t,abs(abs(linalg.dot(right.rotation,mm.quat_axis_angle({0,0,1},-.5)))-1)<1e-4,"the right leg takes the reflected turn of the left one")
    testing.expect(t,abs(abs(linalg.dot(left.rotation,mm.Quat(1)))-1)<1e-4 && linalg.length(left.position-mm.Vec3{-.2,-.1,0})<1e-4,"the left leg takes the rest of the right one")
    testing.expect(t,abs(poses[1][1].position.x+.5)<1e-4 && abs(poses[0][1].position.x-.5)<1e-4,"the pelvis slides the other way")
    testing.expect(t,abs(motions[0].translation.x-.5)<1e-4 && abs(motions[1].translation.x+.5)<1e-4,"root motion is reflected")
    rig_mirrored:=poses[0]
    testing.expect(t,playing_mirror(state,rig_mirrored[:]))
    for value,b in rig_mirrored[1:] {testing.expectf(t,linalg.length(value.position-poses[1][b+1].position)<1e-4 && abs(abs(linalg.dot(value.rotation,poses[1][b+1].rotation))-1)<1e-4,"mirroring the rig matches the mirrored source at bone %d",b+1)}
    testing.expect(t,root_delta_mirror(state.mirror_plane,motions[0]).translation.x==motions[1].translation.x)

    content:host.Content_Animation;defer program_test_content_free(&content)
    plain:=program_test_content(t,&content);defer playing_free(&plain)
    plain_nodes:=program_test_graph();plain_nodes[0].mirror=true
    plain_profile:=Graph_Profile{info={animation={1,2}},nodes=plain_nodes[:]}
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)}
    testing.expect(t,program_node(output,plain_profile,0,nil,nil,nil,{}))
    f.playback.frame+=1;plain.program.ready=true
    testing.expect(t,tracks_bind(&f.playback,&plain,&content))
    testing.expect(t,program_players(&plain,output,&content,ANIMATION_DEFAULT,&events,&f.playback,.1,-1,nil))
    testing.expect(t,!program_pose(&f.playback,&plain,&content,ANIMATION_DEFAULT,output,{}) && plain.program.error==.Unsupported_Mirror,"a rig without skeleton cannot mirror")
    testing.expect(t,!playing_mirror(&plain,plain.local[:]))
    plain_nodes[3].mirror=true;testing.expect(t,!graph_check({info={animation={1,2}},nodes=plain_nodes[:]}),"only sources mirror")
}
