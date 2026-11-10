package anim

import "base:runtime"
import "core:fmt"
import "core:mem"
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
    // The Walk of each source, half and half.
    built:=program_test_output(program_test_leaf("Walk",0,.5),Program_Leaf{clip=alias,key=256,weight=.5,speed=1});output:=&built
    fixture:host.Content_Animation;state:=layer_fixture(t,&fixture);defer {lib.library_destroy(&fixture.lib);playing_free(&state)}
    state.asset,state.generation,state.source_plan=combined.id,combined.generation,1
    testing.expect(t,source_clip_source(&cache,&state,4)==sources[1].id && source_clip_source(&cache,&state,1)==sources[0].id)
    playback:Playback;events:Animation_Events;defer {playback_free(&playback);delete(events.items)}
    testing.expect(t,tracks_bind(&playback,&state,combined))
    animation:=ANIMATION_DEFAULT;animation.loop=false;animation.root_motion=.Extract
    testing.expect(t,program_buffers(&state,combined) && program_players(&state,output,combined,animation,&events,&playback,.5,-1,nil) && program_pose(&playback,&state,combined,animation,output))
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
    action_profile:=Action_Profile{actions=make([]Action_Definition,1)}
    action_profile.actions[0]=ACTION_DEFINITION_DEFAULT;definition:=&action_profile.actions[0]
    base.text_set(definition.name[:],"external");base.text_set(definition.clip[:],"Walk");definition.animation=sources[1].id;definition.fade_in=0
    append(&actions.plans,Action_Plan{profile=action_profile,animation=sources[0].id});action_test_add_state(&actions,{entity=state.entity,plan=0,slots={0={active=true,starting=true,section=-1}}})
    animation.root_motion=.None
    stack_asks(&actions,&state,animation,combined)
    actions_sample(&actions,&state,animation,.1,&problems,combined,&playback,&events)
    testing.expect(t,state.layers[0].clip==alias && actions.states[0].slots[0].active && problems.count==0)
    // A layer whose space names a clip of each source keeps them apart.
    samples:=[2]Blend_Sample{{position={0,0},speed=1},{position={1,0},speed=1,animation=sources[1].id}}
    for &sample in samples {base.text_set(sample.clip[:],"Walk")}
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator}
    names:=make([]u64,2);names[0],names[1]=base.name_hash("Walk"),base.name_hash("Walk")
    spaces:=[1]Blend_Info{{dimension=.One,x={min=0,max=1}}};base.text_set(spaces[0].name[:],"speeds");base.text_set(spaces[0].x.name[:],"speed")
    points:=[2]mm.Vec2{{0,0},{1,0}};space,_:=lib.blend_space_prepare(points[:],.One)
    ready:=make([]Space_Ready,1);ready[0]={space=space,names=names,axis_names={0=base.name_hash("speed")}}
    characters:Character_Assets;defer character_assets_free(&characters)
    animation.asset={101,3}
    append(&characters.contents,Character_Content{id=animation.asset,checked=assets_stamp(app.assets),revision=1,valid=true,set={info={animation=sources[0].id},spaces=spaces[:],space_samples=samples[:]},spaces=ready})
    state.asked[1]={space=1,weight=1,speed=1,mode=.Additive};state.stack=2
    testing.expect(t,stack_parameter_set(&state,base.name_hash("speed"),.5))
    layers_advance(&playback,&state,combined,animation,&events,.1,&problems,&characters,&app)
    spaced:=state.layers[1]
    testing.expect(t,spaced.leaf_count==2 && spaced.leaves[0].clip!=spaced.leaves[1].clip && abs(spaced.leaves[0].weight-.5)<1e-5 && problems.count==0,"a space keeps the clips of each source apart")
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
    append(&assets.registry.files,asset.Registry_File{id=graph_id,kind=CHARACTER_KIND,state=.Asset});assets.registry.by_id[graph_id]=0
    // A .character whose two locomotion clips are the Walk of each source.
    clips:=make([]Match_Source,2);defer delete(clips);for &clip in clips {base.text_set(clip.clip[:],"Walk");clip.modes=1};clips[1].animation=native.animations[1].id
    graphs:=Character_Assets{allocator=context.allocator};defer character_assets_free(&graphs)
    test_character_seed(&graphs,graph_id,{info={animation=native.animations[0].id},match={info=MATCH_INFO_DEFAULT,clips=clips}})
    cache:=Source_Assets{allocator=context.allocator};defer source_assets_free(&cache)
    description:=ANIMATION_DEFAULT;description.asset=graph_id
    first:=Playing{entity=core.entity_make(1,1)};second:=Playing{entity=core.entity_make(2,1)}
    one,error:=animation_content(&cache,&app,&first,description,characters=&graphs);testing.expect_value(t,error,Program_Error.None)
    two,error2:=animation_content(&cache,&app,&second,description,characters=&graphs);testing.expect_value(t,error2,Program_Error.None)
    if !testing.expect(t,one!=nil && two==one && len(cache.plans)==1 && len(cache.sets)==1 && first.source_plan==second.source_plan) {return}
    first.asset,first.generation=one.id,one.generation
    testing.expect(t,len(source_ids(&cache,&first))==2 && source_ids(&cache,&first)[1]==native.animations[1].id)
    changed:=description;changed.library=native.animations[1].id
    other,other_error:=animation_content(&cache,&app,&second,changed,characters=&graphs)
    testing.expect(t,other_error==.None && other!=one && len(cache.plans)==2 && second.source_plan==2)
    assets.revision+=1
    generation:=one.generation
    refreshed,refresh_error:=animation_content(&cache,&app,&first,description,characters=&graphs)
    testing.expect(t,refresh_error==.None && refreshed==one && refreshed.generation==generation && len(cache.sets)==1)
    copied:=first;copied.entity=core.entity_make(3,1)
    testing.expect(t,animation_playing_content(&cache,&app,&copied)==one)
    native.animations[1].generation=4;native.generations=4
    reloaded,reload_error:=animation_content(&cache,&app,&first,description,characters=&graphs)
    testing.expect(t,reload_error==.None && reloaded.generation!=generation && len(cache.sets)==1)
    first.generation=reloaded.generation
    generation=reloaded.generation;pointer:=raw_data(reloaded.lib.tracks)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();cache.allocator=runtime.nil_allocator();app.allocator=runtime.nil_allocator()
    stable,stable_error:=animation_content(&cache,&app,&first,description,characters=&graphs)
    context=saved;cache.allocator=saved.allocator;app.allocator=saved.allocator
    testing.expect(t,stable_error==.None && stable.generation==generation && raw_data(stable.lib.tracks)==pointer)
}

// An actor with a bone under it, with what animation_tick reads and writes of the World.
@(private="file")
Source_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    targets:core.Table(Animation_Target),
    animations:core.Table(Animation),
    hierarchy:core.Hierarchy,
    requests:Animation_Requests,
    events:Animation_Events,
    playback:Playback,
    actions:Action_Runtime,
}

// While its .anim compresses in a job the entity stays as it is and nothing is reported; the tick
// after the library is ready animates it.
@(test)
an_animation_that_compresses_in_a_job_plays_once_it_is_ready_without_problems :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"animation-pending")
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
    w:Source_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    actor,hip:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.transforms,actor,core.TRANSFORM_IDENTITY);core.add(&w.transforms,hip,core.TRANSFORM_IDENTITY);core.add(&w.parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&w.names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=id;animation.loop=false;animation.fade=0;base.text_set(animation.clip[:],"walk")
    core.add(&w.animations,actor,animation)
    core.test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    problems:core.Problems
    for ready in 0..<2 {
        animation_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),&w.requests,&w.events,core.read(&w.targets),{},&w.playback,&app,{dt=.25,playing=true},{},&skeletons,&problems)
        testing.expect_value(t,problems.count,0)
        if ready==1 {break}
        testing.expect(t,host.content_animation_pending(&app,id),"it compresses in a job")
        testing.expect(t,len(w.playback.states)==0 || len(w.playback.states[0].local)==0,"it waits")
        if !testing.expect(t,host.content_animation_wait(&app,id)!=nil) {return}
    }
    if testing.expect(t,len(w.playback.states)==1 && len(w.playback.states[0].local)==2) {
        testing.expect(t,abs(w.playback.states[0].local[1].position.x-.25)<1e-4,"the tick after it is ready plays it")
    }
}

// A weapon's set swapped into Animation.library while its .anim compresses in a job: until it is
// ready the entity plays on what it played, with the action it plays, without a problem of its
// own; then the set joins its sources. The actor has no feet to match by, so the locomotion of its .character plays its
// first clip and says so.
@(test)
a_library_that_compresses_in_a_job_keeps_what_plays_until_it_is_ready :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"animation-swap")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    CLIPS :: base.Asset_Id{0x9e2,1}
    SET :: base.Asset_Id{0x9e2,2}
    CHARACTER :: base.Asset_Id{0x9e2,3}
    for id,i in ([2]base.Asset_Id{CLIPS,SET}) {
        keys:=[2]lib.Keyframe{{time=0},{time=1,value={1 if i==0 else -1,0,0,0}}}
        tracks:=[1]asset.Animation_Track_Desc{{target="hip",property=.Position,keys=keys[:]}}
        clips:=[1]asset.Animation_Clip_Desc{{name="walk",tracks=tracks[:]}}
        if !testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/%d.anim",directory,i),&types,{id=id,clips=clips[:]}),asset.Error.None) {return}
    }
    sources_of_match:=[1]Match_Source{{loop=true,modes=1}};base.text_set(sources_of_match[0].clip[:],"walk")
    layers:=[1]Stack_Layer{STACK_LAYER_DEFAULT};base.text_set(layers[0].name[:],"Arm")
    definitions:=[1]Action_Definition{ACTION_DEFINITION_DEFAULT}
    base.text_set(definitions[0].name[:],"slash");base.text_set(definitions[0].clip[:],"walk");base.text_set(definitions[0].layer[:],"Arm");definitions[0].animation=CLIPS
    if !test_character_save(t,directory,"blade",&types,CHARACTER,{info={animation=CLIPS},match={clips=sources_of_match[:]},actions={layers=layers[:],actions=definitions[:]}}) {return}
    assets:host.Assets;if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=2})) {return}
    defer {host.app_content_destroy(&app);jobs.system_destroy(&app.jobs)}
    w:Source_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    actor,hip:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.transforms,actor,core.TRANSFORM_IDENTITY);core.add(&w.transforms,hip,core.TRANSFORM_IDENTITY);core.add(&w.parents,hip,{entity=actor})
    name:core.Name;base.text_set(name.text[:],"hip");core.add(&w.names,hip,name)
    animation:=ANIMATION_DEFAULT;animation.asset=CHARACTER;animation.fade=0
    core.add(&w.animations,actor,animation)
    core.test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    problems:core.Problems
    graphs:=Character_Assets{allocator=context.allocator};defer character_assets_free(&graphs)
    sources:=Source_Assets{allocator=context.allocator};defer source_assets_free(&sources)
    w.actions.allocator=context.allocator
    Swap_Test :: struct {
        w:^Source_World,
        app:^host.App,skeletons:^Skeleton_Assets,problems:^core.Problems,graphs:^Character_Assets,
        sources:^Source_Assets,
    }
    tick :: proc(s:Swap_Test) {
        w:=s.w
        animation_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),&w.requests,&w.events,&w.targets,{},&w.playback,s.app,{dt=.1,playing=true},{},s.skeletons,s.problems,characters=s.graphs,actions=&w.actions,sources=s.sources)
    }
    s:=Swap_Test{&w,&app,&skeletons,&problems,&graphs,&sources}
    if !testing.expect(t,host.content_animation_wait(&app,CLIPS)!=nil) {return}
    // Its only problem, once it is bound: it has no feet to search by.
    only_unmatched :: proc(problems:^core.Problems,actor:core.Entity) -> bool {return problems.count==0 || problems.count==1 && core.problem_find(problems,actor,"animation.match_database")!=nil}
    play(&w.requests,actor,"slash")
    tick(s)
    if !testing.expect(t,only_unmatched(&problems,actor) && len(w.playback.states)==1 && len(w.playback.states[0].local)==2 && len(w.actions.states)==1 && w.actions.states[0].slots[1].active) {return}
    before:=w.playback.states[0].local[1].position.x
    core.free(&w.animations,actor).library=SET
    tick(s)
    testing.expect(t,host.content_animation_pending(&app,SET),"the set compresses in a job")
    testing.expect(t,only_unmatched(&problems,actor))
    testing.expect(t,w.playback.states[0].local[1].position.x>before+.05,"it plays on what it played")
    testing.expect(t,w.actions.states[0].slots[1].active && !w.actions.states[0].slots[1].finishing,"the action it plays goes on")
    testing.expect(t,len(source_ids(&sources,&w.playback.states[0]))==0)
    if !testing.expect(t,host.content_animation_wait(&app,SET)!=nil) {return}
    tick(s)
    testing.expect(t,only_unmatched(&problems,actor))
    joined:=source_ids(&sources,&w.playback.states[0])
    testing.expect(t,len(joined)==2 && joined[0]==SET,"the set plays once it is ready")
    testing.expect(t,w.actions.states[0].slots[1].active,"with the action")
}
