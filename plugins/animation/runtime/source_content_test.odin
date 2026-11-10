package anim

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private="file")
sources_test_content :: proc(t:^testing.T,id:base.Asset_Id,duration,distance,morph:f32) -> host.Content_Animation {
    content:=host.Content_Animation{stamp={id=id,generation=1},clip_count=1}
    testing.expect(t,lib.library_init(&content.lib,{max_keys=4,max_tracks=2,max_clips=2,max_markers=1}))
    positions:=[2]lib.Keyframe{{},{time=duration,value={distance,0,0,0}}}
    weights:=[2]lib.Keyframe{{value={morph,0,0,0}},{time=duration,value={morph,0,0,0}}}
    tracks:=[2]lib.Track_Desc{{target=base.name_hash("hip"),property=.Position,keys=positions[:]},{target=base.name_hash("Smile"),property=.Float,keys=weights[:]}}
    markers:=[1]lib.Marker{{time=.25,id=0}}
    walk,_:=lib.clip_add(&content.lib,{name=base.name_hash("Walk"),tracks=tracks[:],markers=markers[:]})
    testing.expect(t,walk==1)
    _,error:=lib.library_compress(&content.lib);testing.expect_value(t,error,lib.Compress_Error.None)
    host.content_animation_loops(&content.lib,1)
    content.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,1);base.text_set(content.names[0][:],"Walk")
    content.roots=make([]asset.Animation_Root,1);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    content.markers=make([]u64,1);content.markers[0]=base.name_hash("step")
    return content
}
@(private="file")
sources_test_free :: proc(content:^host.Content_Animation) {
    lib.library_destroy(&content.lib);delete(content.names);delete(content.roots);delete(content.markers);content^={}
}

@(test)
multiple_animation_sources_keep_duplicate_clip_names_curves_markers_root_and_actions :: proc(t:^testing.T) {
    problems:core.Problems
    sources:=[2]host.Content_Animation{sources_test_content(t,{101,1},1,2,.2),sources_test_content(t,{101,2},2,8,.8)}
    defer for &source in sources {sources_test_free(&source)}
    cache:=Source_Assets{allocator=context.allocator};defer source_assets_free(&cache)
    append(&cache.sets,Source_Set{primary=sources[0].id})
    testing.expect_value(t,source_join(&cache,&cache.sets[0],sources[0].id,sources[:]),Source_Error.None)
    append(&cache.plans,Source_Plan{primary=sources[0].id,set=1,valid=true})
    combined:=&cache.sets[0].content
    alias:=source_clip_name(sources[0].id,sources[1].id,base.name_hash("Walk"))
    testing.expect(t,lib.clip_find(&combined.lib,base.name_hash("Walk"))==1 && lib.clip_find(&combined.lib,alias)==2 && combined.clip_count==2)
    testing.expect(t,combined.lib.stream_bytes>0 && combined.markers[0]==combined.markers[1] && combined.lib.markers[1].id==1)
    testing.expect(t,combined.generation&SOURCE_GENERATION!=0 && source_clip_label(combined,2)==sources[1].names[0])
    nodes:=[3]Graph_Node{GRAPH_NODE_DEFAULT,GRAPH_NODE_DEFAULT,GRAPH_NODE_DEFAULT}
    for &node,i in nodes {base.text_set(node.name[:],"source" if i==0 else "other" if i==1 else "blend");node.loop=false;node.sync_mode=.Independent}
    base.text_set(nodes[0].clip[:],"Walk");base.text_set(nodes[1].clip[:],"Walk");nodes[1].animation=sources[1].id
    nodes[2].kind,nodes[2].left,nodes[2].right,nodes[2].weight=.Blend,0,1,.5
    profile:=Graph_Profile{info={animation=sources[0].id,output=2},nodes=nodes[:]}
    output:=new(Program_Output);defer {program_output_free(output);mem.free(output)}
    testing.expect(t,graph_check(profile) && program_node(output,profile,2,nil,nil,nil,{}))
    fixture:host.Content_Animation;state:=layer_fixture(t,&fixture);defer {lib.library_destroy(&fixture.lib);playing_free(&state)}
    state.asset,state.generation,state.source_plan=combined.id,combined.generation,1
    testing.expect(t,source_clip_source(&cache,&state,4)==sources[1].id && source_clip_source(&cache,&state,1)==sources[0].id)
    playback:Playback;events:Animation_Events;defer {playback_free(&playback);delete(events.items)}
    testing.expect(t,lib.pose_init(&playback.pose,32))
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    testing.expect(t,program_players(&state,output,combined,animation,&events,&playback,.5,-1,nil) && program_pose(&playback,&state,combined,animation,output,{}))
    source_markers_resolve(&cache,&state,events.items[:])
    testing.expect(t,abs(state.local[1].position.x-1.5)<.001 && abs(state.motion.translation.x-1.5)<.001)
    found:bool
    for curve in state.curves {if curve.target==base.name_hash("Smile") {found=abs(curve.value.x-.5)<.001}}
    testing.expect(t,found && len(events.items)==2 && events.items[0].clip==base.name_hash("Walk") && events.items[1].clip==base.name_hash("Walk"))
    testing.expect(t,events.items[0].animation!=events.items[1].animation && events.items[0].fraction>0)
    request:=Animation_Distance_Request{entity=state.entity,clip=base.name_hash("Walk"),animation=sources[1].id,time=1}
    state.program.ready,state.was_playing=true,true
    testing.expect_value(t,distance_request_check(&state,combined,request),Distance_Error.None)
    actions:Action_Runtime;defer actions_runtime_free(&actions)
    action_profile:=Action_Profile{info={animation=sources[0].id},actions=make([]Action_Definition,1)}
    action_profile.actions[0]=ACTION_DEFINITION_DEFAULT;definition:=&action_profile.actions[0]
    base.text_set(definition.name[:],"external");base.text_set(definition.clip[:],"Walk");definition.animation=sources[1].id;definition.fade_in=0
    append(&actions.plans,Action_Plan{profile=action_profile});action_test_add_state(&actions,{entity=state.entity,plan=0,layers={0={active=true,starting=true,section=-1}}})
    animation.root_motion=.None
    actions_sample(&actions,&state,&animation,.1,&problems,combined,&playback,&events)
    testing.expect(t,state.layers[0].clip==alias && actions.states[0].layers[0].active && problems.count==0)
    samples:=[2]Blend_Sample{{position={0,0},speed=1},{position={1,0},speed=1,animation=sources[1].id}}
    for &sample in samples {base.text_set(sample.clip[:],"Walk")}
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    blend:=Blend_Content{id={101,3},checked=assets_stamp(app.assets),valid=true,profile={info={animation=sources[0].id,dimension=.One,x={min=0,max=1}},samples=samples[:]}}
    base.text_set(blend.profile.info.x.name[:],"speed")
    testing.expect_value(t,blend_space_prepare(&blend.profile),asset.Error.None)
    defer {delete(blend.profile.segments);delete(blend.profile.triangles)}
    points:=[2]mm.Vec2{{0,0},{1,0}};blend.space={dimension=.One,points=points[:],segments=blend.profile.segments,triangles=blend.profile.triangles}
    blends:Blend_Assets;defer delete(blends.contents);append(&blends.contents,blend)
    nodes[1].kind,nodes[1].blend_space,nodes[1].position,nodes[1].animation,nodes[1].clip=.Blend_Space,blend.id,{.5,0},{},{}
    nodes[2].kind=.Additive
    profile.info.output=2
    testing.expect(t,graph_check(profile) && program_node(output,profile,2,nil,&blends,app.assets,app.allocator))
    spaced:=output.groups[output.instructions[output.instructions[output.output].right].group]
    testing.expect(t,spaced.count==2 && spaced.leaves[0].clip!=spaced.leaves[1].clip,"an additive space keeps the clips of each source apart")
}

@(test)
joining_sources_without_memory_or_with_invalid_sources_keeps_the_published_library :: proc(t:^testing.T) {
    sources:=[2]host.Content_Animation{sources_test_content(t,{201,1},1,2,.2),sources_test_content(t,{201,2},2,8,.8)}
    defer for &source in sources {sources_test_free(&source)}
    cache:=Source_Assets{allocator=context.allocator};defer source_assets_free(&cache)
    append(&cache.sets,Source_Set{primary=sources[0].id})
    set:=&cache.sets[0]
    testing.expect_value(t,source_join(&cache,set,sources[0].id,sources[:]),Source_Error.None)
    keys,generation:=raw_data(set.content.lib.streams),set.content.generation
    cache.allocator=runtime.nil_allocator()
    testing.expect_value(t,source_join(&cache,set,sources[0].id,sources[:]),Source_Error.Out_Of_Memory)
    cache.allocator=context.allocator
    testing.expect(t,raw_data(set.content.lib.streams)==keys && set.content.generation==generation && set.content.clip_count==2)
    sources[1].id=sources[0].id
    testing.expect_value(t,source_join(&cache,set,sources[0].id,sources[:]),Source_Error.Invalid)
    testing.expect(t,raw_data(set.content.lib.streams)==keys && set.content.generation==generation)
}

@(test)
source_plans_share_exact_sets_rebuild_for_source_generations_and_survive_world_copies :: proc(t:^testing.T) {
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    assets.registry.by_id=make(map[base.Asset_Id]u32);defer {delete(assets.registry.by_id);delete(assets.registry.files)}
    native:=host.app_content(&app)
    for i in 0..<2 {id:=base.Asset_Id{301,u64(i+1)};append(&native.animations,sources_test_content(t,id,1,f32(i+1),.2));native.index[id]={kind=.Animation,index=u32(i)}}
    native.generations=2
    graph_id:=base.Asset_Id{302,1}
    append(&assets.registry.files,asset.Registry_File{id=graph_id,kind=GRAPH_KIND,state=.Asset});assets.registry.by_id[graph_id]=0
    nodes:=make([]Graph_Node,2);for &node,i in nodes {node=GRAPH_NODE_DEFAULT;base.text_set(node.name[:],"first" if i==0 else "second");base.text_set(node.clip[:],"Walk")};nodes[1].animation=native.animations[1].id
    graphs:=Graph_Assets{allocator=context.allocator};defer graph_assets_free(&graphs)
    append(&graphs.contents,Graph_Content{id=graph_id,checked=1,valid=true,profile={info={animation=native.animations[0].id},nodes=nodes}})
    cache:=Source_Assets{allocator=context.allocator};defer source_assets_free(&cache)
    description:=ANIMATION_DEFAULT;description.asset=graph_id
    first:=Playing{entity=core.entity_make(1,1)};second:=Playing{entity=core.entity_make(2,1)}
    one,error:=animation_content(&cache,&app,&first,description,graphs=&graphs);testing.expect_value(t,error,Program_Error.None)
    two,error2:=animation_content(&cache,&app,&second,description,graphs=&graphs);testing.expect_value(t,error2,Program_Error.None)
    if !testing.expect(t,one!=nil && two==one && len(cache.plans)==1 && len(cache.sets)==1 && first.source_plan==second.source_plan) {return}
    first.asset,first.generation=one.id,one.generation
    testing.expect(t,len(source_ids(&cache,&first))==2 && source_ids(&cache,&first)[1]==native.animations[1].id)
    changed:=description;changed.library=native.animations[1].id
    other,other_error:=animation_content(&cache,&app,&second,changed,graphs=&graphs)
    testing.expect(t,other_error==.None && other!=one && len(cache.plans)==2 && second.source_plan==2)
    assets.revision+=1
    generation:=one.generation
    refreshed,refresh_error:=animation_content(&cache,&app,&first,description,graphs=&graphs)
    testing.expect(t,refresh_error==.None && refreshed==one && refreshed.generation==generation && len(cache.sets)==1)
    copied:=first;copied.entity=core.entity_make(3,1)
    testing.expect(t,animation_playing_content(&cache,&app,&copied)==one)
    native.animations[1].generation=4;native.generations=4
    reloaded,reload_error:=animation_content(&cache,&app,&first,description,graphs=&graphs)
    testing.expect(t,reload_error==.None && reloaded.generation!=generation && len(cache.sets)==1)
    first.generation=reloaded.generation
    generation=reloaded.generation;pointer:=raw_data(reloaded.lib.tracks)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();cache.allocator=runtime.nil_allocator();app.allocator=runtime.nil_allocator()
    stable,stable_error:=animation_content(&cache,&app,&first,description,graphs=&graphs)
    context=saved;cache.allocator=saved.allocator;app.allocator=saved.allocator
    testing.expect(t,stable_error==.None && stable.generation==generation && raw_data(stable.lib.tracks)==pointer)
}

// While its .anim compresses in a job the entity stays as it is and nothing is reported; the tick
// after the library is ready animates it.
@(test)
an_animation_that_compresses_in_a_job_plays_once_it_is_ready_without_problems :: proc(t:^testing.T) {
    directory:=fmt.tprintf(".mirai/test-animation-pending-%d",os.get_pid());os.make_directory_all(directory);defer os.remove_all(directory)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{0x9e1,1}
    keys:=[2]lib.Keyframe{{time=0},{time=1,value={1,0,0,0}}}
    tracks:=[1]asset.Animation_Track_Desc{{target="hip",property=.Position,keys=keys[:]}}
    clips:=[1]asset.Animation_Clip_Desc{{name="walk",tracks=tracks[:]}}
    if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/walk.anim",directory),&types,{id=id,clips=clips[:]}),asset.Error.None) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=2})) {return}
    defer {host.app_content_destroy(&app);jobs.system_destroy(&app.jobs)}
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent);names:core.Table(core.Name);targets:core.Table(Animation_Target);animations:core.Table(Animation)
    defer {core.table_destroy(&transforms);core.table_destroy(&parents);core.table_destroy(&names);core.table_destroy(&targets);core.table_destroy(&animations)}
    actor,hip:=core.create(&entities),core.create(&entities)
    core.add(&transforms,actor,core.TRANSFORM_IDENTITY);core.add(&transforms,hip,core.TRANSFORM_IDENTITY);core.add(&parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=id;animation.loop=false;animation.fade=0;base.text_set(animation.clip[:],"walk")
    core.add(&animations,actor,animation)
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities);core.table_settle(&names,&entities);core.table_settle(&targets,&entities);core.table_settle(&animations,&entities)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    core.hierarchy_settle(&hierarchy,core.read(&parents),&entities)
    requests:Animation_Requests;events:Animation_Events;playback:Playback;skeletons:Skeleton_Assets;problems:core.Problems
    defer {delete(requests.seeks.items);delete(requests.poses.items);delete(requests.distances.items);delete(events.items);playback_free(&playback);skeleton_assets_free(&skeletons)}
    for ready in 0..<2 {
        animation_tick(core.read(&animations),&transforms,core.read(&parents),core.ref(&hierarchy),core.read(&names),&requests,&events,core.read(&targets),{},&playback,&app,{dt=.25,playing=true},{},&skeletons,&problems)
        testing.expect_value(t,problems.count,0)
        if ready==1 {break}
        testing.expect(t,host.content_animation_pending(&app,id),"it compresses in a job")
        testing.expect(t,len(playback.states)==0 || len(playback.states[0].local)==0,"it waits")
        if !testing.expect(t,host.content_animation_wait(&app,id)!=nil) {return}
    }
    if testing.expect(t,len(playback.states)==1 && len(playback.states[0].local)==2) {
        testing.expect(t,abs(playback.states[0].local[1].position.x-.25)<1e-4,"the tick after it is ready plays it")
    }
}

// A weapon's set swapped into Animation.library while its .anim compresses in a job: until it is
// ready the entity plays on what it played, with the action it fired, without a problem; then
// the set joins its sources.
@(test)
a_library_that_compresses_in_a_job_keeps_what_plays_until_it_is_ready :: proc(t:^testing.T) {
    directory:=fmt.tprintf(".mirai/test-animation-swap-%d",os.get_pid());os.make_directory_all(directory);defer os.remove_all(directory)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    CLIPS :: base.Asset_Id{0x9e2,1}
    SET :: base.Asset_Id{0x9e2,2}
    GRAPH :: base.Asset_Id{0x9e2,3}
    ACTIONS :: base.Asset_Id{0x9e2,4}
    for id,i in ([2]base.Asset_Id{CLIPS,SET}) {
        keys:=[2]lib.Keyframe{{time=0},{time=1,value={1 if i==0 else -1,0,0,0}}}
        tracks:=[1]asset.Animation_Track_Desc{{target="hip",property=.Position,keys=keys[:]}}
        clips:=[1]asset.Animation_Clip_Desc{{name="walk",tracks=tracks[:]}}
        if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/%d.anim",directory,i),&types,{id=id,clips=clips[:]}),asset.Error.None) {return}
    }
    nodes:=[1]Graph_Node{GRAPH_NODE_DEFAULT};nodes[0].sync_mode=.Independent
    base.text_set(nodes[0].name[:],"walk");base.text_set(nodes[0].clip[:],"walk")
    if !testing.expect_value(t,graph_save(fmt.tprintf("%s/walk.agraph",directory),&types,GRAPH,{info={animation=CLIPS},nodes=nodes[:]}),asset.Error.None) {return}
    definitions:=[1]Action_Definition{ACTION_DEFINITION_DEFAULT}
    base.text_set(definitions[0].name[:],"slash");base.text_set(definitions[0].clip[:],"walk");definitions[0].animation=CLIPS
    if !testing.expect_value(t,action_profile_save(fmt.tprintf("%s/blade.action",directory),&types,ACTIONS,{info={animation=CLIPS},actions=definitions[:]}),asset.Error.None) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=2})) {return}
    defer {host.app_content_destroy(&app);jobs.system_destroy(&app.jobs)}
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform);parents:core.Table(core.Parent);names:core.Table(core.Name);targets:core.Table(Animation_Target);animations:core.Table(Animation)
    defer {core.table_destroy(&transforms);core.table_destroy(&parents);core.table_destroy(&names);core.table_destroy(&targets);core.table_destroy(&animations)}
    actor,hip:=core.create(&entities),core.create(&entities)
    core.add(&transforms,actor,core.TRANSFORM_IDENTITY);core.add(&transforms,hip,core.TRANSFORM_IDENTITY);core.add(&parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=GRAPH;animation.actions=ACTIONS;animation.fade=0
    core.add(&animations,actor,animation)
    core.table_settle(&transforms,&entities);core.table_settle(&parents,&entities);core.table_settle(&names,&entities);core.table_settle(&targets,&entities);core.table_settle(&animations,&entities)
    hierarchy:core.Hierarchy;defer core.value_free(&hierarchy,type_info_of(core.Hierarchy))
    core.hierarchy_settle(&hierarchy,core.read(&parents),&entities)
    requests:Animation_Requests;events:Animation_Events;playback:Playback;skeletons:Skeleton_Assets;problems:core.Problems
    defer {delete(requests.seeks.items);delete(requests.poses.items);delete(requests.distances.items);delete(events.items);playback_free(&playback);skeleton_assets_free(&skeletons)}
    graphs:=Graph_Assets{allocator=context.allocator};defer graph_assets_free(&graphs)
    sources:=Source_Assets{allocator=context.allocator};defer source_assets_free(&sources)
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    action_assets:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&action_assets)
    action_requests:Action_Requests;defer delete(action_requests.queue.items)
    Swap_Test :: struct {
        animations:^core.Table(Animation),transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent),hierarchy:^core.Hierarchy,
        names:^core.Table(core.Name),targets:^core.Table(Animation_Target),requests:^Animation_Requests,events:^Animation_Events,playback:^Playback,
        app:^host.App,skeletons:^Skeleton_Assets,problems:^core.Problems,graphs:^Graph_Assets,actions:^Action_Runtime,
        action_requests:^Action_Requests,action_assets:^Actions_Assets,sources:^Source_Assets,
    }
    tick :: proc(s:Swap_Test) {
        animation_tick(core.read(s.animations),s.transforms,core.read(s.parents),core.ref(s.hierarchy),core.read(s.names),s.requests,s.events,core.read(s.targets),{},s.playback,s.app,{dt=.1,playing=true},{},s.skeletons,s.problems,graphs=s.graphs,actions=s.actions,action_requests=s.action_requests,action_assets=s.action_assets,sources=s.sources)
    }
    s:=Swap_Test{&animations,&transforms,&parents,&hierarchy,&names,&targets,&requests,&events,&playback,&app,&skeletons,&problems,&graphs,&actions,&action_requests,&action_assets,&sources}
    if !testing.expect(t,host.content_animation_wait(&app,CLIPS)!=nil) {return}
    action_fire(&action_requests,actor,"slash")
    tick(s)
    if !testing.expect(t,problems.count==0 && len(playback.states)==1 && len(playback.states[0].local)==2 && len(actions.states)==1 && actions.states[0].layers[0].active) {return}
    before:=playback.states[0].local[1].position.x
    core.free(&animations,actor).library=SET
    tick(s)
    testing.expect(t,host.content_animation_pending(&app,SET),"the set compresses in a job")
    testing.expect_value(t,problems.count,0)
    testing.expect(t,playback.states[0].local[1].position.x>before+.05,"it plays on what it played")
    testing.expect(t,actions.states[0].layers[0].active && !actions.states[0].layers[0].finishing,"the action it fired goes on")
    testing.expect(t,len(source_ids(&sources,&playback.states[0]))==0)
    if !testing.expect(t,host.content_animation_wait(&app,SET)!=nil) {return}
    tick(s)
    testing.expect_value(t,problems.count,0)
    joined:=source_ids(&sources,&playback.states[0])
    testing.expect(t,len(joined)==2 && joined[0]==SET,"the set plays once it is ready")
    testing.expect(t,actions.states[0].layers[0].active,"with the action")
}
