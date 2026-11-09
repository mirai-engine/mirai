package anim

import "base:runtime"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import "mirai:std/serial"
import mm "mirai:std/math"

@(private)
action_test_profile :: proc() -> Action_Profile {
    profile:=Action_Profile{info={animation={1,2}}}
    profile.actions=make([]Action_Definition,2);profile.sections=make([]Action_Section,2);profile.windows=make([]Action_Window,1)
    for &value in profile.actions {value=ACTION_DEFINITION_DEFAULT;value.fade_in,value.fade_out=0,.2;base.text_set(value.clip[:],"walk")}
    base.text_set(profile.actions[0].name[:],"attack");base.text_set(profile.actions[1].name[:],"interrupt");profile.actions[1].priority=1
    profile.sections[0]={action=0,start=0,end=.25,next=1};base.text_set(profile.sections[0].name[:],"windup")
    profile.sections[1]={action=0,start=1,end=1.5,next=-1};base.text_set(profile.sections[1].name[:],"recover")
    profile.windows[0]={action=0,start=.1,end=.2};base.text_set(profile.windows[0].name[:],"contact")
    return profile
}

@(private)
action_test_add_state :: proc(runtime:^Action_Runtime,value:Action_State) {
    append(&runtime.states,value)
    index:=core.entity_index(value.entity);resize(&runtime.rows,index+1);runtime.rows[index]=i32(len(runtime.states))
}

@(test)
action_profiles_roundtrip_and_reject_invalid_section_links_and_root_layer_policies :: proc(t:^testing.T) {
    profile:=action_test_profile();defer action_profile_free(&profile)
    for &action in profile.actions {action.mesh_space=true;action.clock=.World}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;defer asset.document_destroy(&doc)
    testing.expect_value(t,action_profile_document(&doc,&types,{3,4},profile),asset.Error.None)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None)
    file:asset.Asset;defer asset.asset_close(&file)
    testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None)
    view,error:=action_profile_view(&file,&types);testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,view.sections[1],profile.sections[1]);testing.expect_value(t,view.windows[0],profile.windows[0]);testing.expect(t,view.actions[0].mesh_space && view.actions[0].clock==.World)
    profile.sections[0].next=99;testing.expect(t,!action_profile_check(profile));profile.sections[0].next=1
    profile.sections[1].action=1;testing.expect(t,!action_profile_check(profile));profile.sections[1].action=0
    profile.actions[1].reference=.1;testing.expect(t,!action_profile_check(profile));profile.actions[1].reference=0
    profile.actions[1].layer=2;profile.actions[1].root_motion=.In_Place;testing.expect(t,action_profile_check(profile));profile.actions[1].layer=1;profile.actions[1].root_motion=.None
    profile.actions[0].root_motion=.Extract;profile.actions[0].over=bone_ref("arm");testing.expect(t,!action_profile_check(profile));profile.actions[0].over={};profile.actions[0].mode=.Additive;testing.expect(t,!action_profile_check(profile))
    // An action moves its body by its root motion, the actions of a layer move it alike, and a vertical asks for a move.
    profile.actions[0].mode=.Override
    for &action in profile.actions {action.root_motion=.In_Place;action.body_move=.Override;action.body_vertical=true}
    testing.expect(t,action_profile_check(profile))
    profile.actions[1].body_vertical=false;testing.expect(t,!action_profile_check(profile));profile.actions[1].body_vertical=true
    for &action in profile.actions {action.root_motion=.None};testing.expect(t,!action_profile_check(profile));for &action in profile.actions {action.root_motion=.In_Place}
    for &action in profile.actions {action.body_move=.None};testing.expect(t,!action_profile_check(profile));for &action in profile.actions {action.body_move=.Override}
    moved:asset.Document;defer asset.document_destroy(&moved)
    testing.expect_value(t,action_profile_document(&moved,&types,{3,4},profile),asset.Error.None)
    bytes,written:=asset.document_bytes(&moved,context.temp_allocator);testing.expect_value(t,written,asset.Error.None)
    moving:asset.Asset;defer asset.asset_close(&moving)
    testing.expect_value(t,asset.asset_open(&moving,bytes,context.temp_allocator),asset.Error.None)
    view,error=action_profile_view(&moving,&types)
    testing.expect(t,error==.None && view.actions[0]==profile.actions[0])
}

// An action whose body_move is not None gives its body the share of the root delta of the tick it
// has, and not what the base keeps; without one the body is left to its locomotion.
@(test)
an_action_that_moves_its_body_gives_it_its_share_of_the_root_delta :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
    descriptions:core.Table(Animation);defer core.table_destroy(&descriptions)
    description:=ANIMATION_DEFAULT;description.asset={1,2};description.actions={3,4};core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
    profile:=action_test_profile();profile.actions[0].weight=.75
    for &action in profile.actions {action.root_motion=.In_Place;action.body_move=.Additive}
    cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache)
    append(&cache.contents,Action_Content{id={3,4},checked=1,revision=1,profile=profile,valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    content:host.Content_Animation;defer lib.library_destroy(&content.lib)
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,layer_fixture(t,&content));resize(&playback.rows,core.entity_index(entity)+1);playback.rows[core.entity_index(entity)]=1
    state:=&playback.states[0];state.entity,state.asset,state.seen=entity,description.asset,playback.frame
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    requests:Action_Requests;defer delete(requests.queue.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
    events:Animation_Events;defer delete(events.items)
    action_fire(&requests,entity,"attack")
    if !testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)) {return}
    actions_sample(&actions,state,&description,.2,nil,&content);layers_advance(&playback,state,&content,description,&events,.2,nil);actions_layer_finish(&actions,state)
    state.motion={translation={.1,0,0},rotation=1};actions_apply_root(&actions,state,description)
    body,moving:=animation_body_motion(&playback,entity)
    testing.expectf(t,moving && body.move==.Additive && !body.vertical && abs(body.translation.x-.15)<1e-5 && abs(state.motion.translation.x-.175)<1e-5,"the action has .75 of .2 and the base the rest of .1: %v %v",body,state.motion)
    actions.states[0].layers[0].body=.None;state.motion={translation={.1,0,0},rotation=1};actions_apply_root(&actions,state,description)
    _,moving=animation_body_motion(&playback,entity)
    testing.expect(t,!moving && abs(state.motion.translation.x-.175)<1e-5)
}

@(test)
actions_segment_sections_and_windows_copy_state_and_obey_cancellation_without_stable_allocations :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
    descriptions:core.Table(Animation);defer core.table_destroy(&descriptions)
    description:=ANIMATION_DEFAULT;description.asset={1,2};description.actions={3,4};description.loop=false;core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.entity=entity;state.asset=description.asset
    content.lib.markers=make([]lib.Marker,2);content.lib.marker_count=2;content.lib.markers[0]={time=.1,id=0};content.lib.markers[1]={time=1.1,id=1}
    content.lib.clips[0].marker_count=2;content.markers=make([]u64,2);defer delete(content.markers);content.markers[0],content.markers[1]=base.name_hash("windup"),base.name_hash("recover")
    cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache)
    append(&cache.contents,Action_Content{id=description.actions,checked=1,revision=1,profile=action_test_profile(),valid=true})
    for &action in cache.contents[0].profile.actions {action.mesh_space=true}
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    requests:Action_Requests;defer delete(requests.queue.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
    problems:core.Problems
    action_fire(&requests,entity,"attack")
    initial_request:=requests.queue.items[0];initial_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    prepared:=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=initial_context;app.allocator=initial_context.allocator;actions.allocator=initial_context.allocator
    testing.expect(t,!prepared && len(requests.queue.items)==1 && requests.queue.items[0]==initial_request && len(actions.states)==0 && len(actions.events.items)==0)
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil))
    testing.expect(t,len(requests.queue.items)==0 && actions.states[0].layers[0].active && actions.events.items[0].kind==.Started)
    actions_sample(&actions,&state,&description,.4,nil,&content,&playback,&events)
    testing.expect(t,description.layers[0].mesh_space,"an action of mesh_space blends its layer in the space of the rig")
    layers_advance(&playback,&state,&content,description,&events,.4,nil);actions_layer_finish(&actions,&state)
    testing.expect(t,abs(state.layers[0].fader.current.time-1.15)<1e-5)
    testing.expect(t,len(events.items)==2 && abs(events.items[0].fraction-.25)<1e-5 && abs(events.items[1].fraction-.875)<1e-5)
    kinds:=[?]Action_Event_Kind{.Started,.Section,.Window_Begin,.Window_End,.Section}
    testing.expect_value(t,len(actions.events.items),len(kinds));for kind,i in kinds {testing.expect_value(t,actions.events.items[i].kind,kind)}
    copied:Action_Runtime;core.value_copy(&copied,&actions,type_info_of(Action_Runtime));defer actions_runtime_free(&copied)
    copied.states[0].layers[0].time=7;copied.plans[0].profile.actions[0].priority=99
    testing.expect(t,actions.states[0].layers[0].time!=7 && actions.plans[0].profile.actions[0].priority!=99)
    cache.contents[0].profile.actions[0].cancel=.Finish_Section;actions.plans[0].profile.actions[0].cancel=.Finish_Section
    action_cancel(&requests,entity,"attack");testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    okay:=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    actions_sample(&actions,&state,&description,.5,nil,&content);layers_advance(&playback,&state,&content,description,&events,.5,nil);actions_layer_finish(&actions,&state)
    context=saved;cache.allocator=saved.allocator;actions.allocator=saved.allocator
    testing.expect(t,okay && actions.states[0].layers[0].finishing && actions.events.items[len(actions.events.items)-1].kind==.Interrupted)
    action_fire(nil,entity,"attack");action_fire(&requests,core.NONE,"attack");action_section(&requests,entity,"attack","")
    testing.expect_value(t,requests.queue.refused,2)
    cache.contents[0].revision+=1
    before:=actions.states[0].layers[0];revision:=actions.plans[0].revision
    saved=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    okay=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=saved;cache.allocator=saved.allocator;actions.allocator=saved.allocator;app.allocator=saved.allocator
    testing.expect(t,okay && len(actions.states)==1 && actions.states[0].layers[0]==before && actions.plans[0].revision==revision)
    cache.contents[0].revision=revision
    reserve_description:=core.free(&descriptions,entity);reserve_description.layers[0].clip=base.name_hash("wave")
    clear(&requests.queue.items);action_fire(&requests,entity,"attack");testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,&problems))
    refused:=core.problem_find(&problems,entity,"animation.action_layer")
    testing.expect(t,refused!=nil && strings.contains(core.problem_text(refused),"action 'attack' cannot play: its layer 1 holds a clip of animation_play") && actions.states[0].layers[0]==before)
    clear(&requests.queue.items);for _ in 0..=cap(requests.queue.items) {action_fire(&requests,entity,"attack")};testing.expect_value(t,requests.queue.dropped,1)
}

@(test)
action_root_motion_uses_section_segments_fade_weight_and_exposes_a_continuous_warp_clock :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.asset={1,2}
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    profile:=action_test_profile();profile.actions[0].root_motion=.In_Place;profile.actions[0].weight=.75
    profile.actions[1].root_motion=.In_Place
    append(&actions.plans,Action_Plan{asset={3,4},profile=profile});action_test_add_state(&actions,Action_State{entity=state.entity,plan=0})
    reserve(&actions.events.items,ACTION_EVENT_CAPACITY)
    actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=0}
    description:=ANIMATION_DEFAULT;description.asset=state.asset
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    actions_sample(&actions,&state,&description,.2,nil,&content);layers_advance(&playback,&state,&content,description,&events,.2,nil);actions_layer_finish(&actions,&state)
    state.motion={translation={.1,0,0},rotation=1};actions_apply_root(&actions,&state,description)
    testing.expect(t,abs(state.motion.translation.x-.175)<1e-5 && state.has_action_root && state.action_root.in_place)
    clock:=action_clock(&actions,state.entity);testing.expect(t,clock.active && clock.from==0 && abs(clock.to-.2)<1e-5 && clock.weight==.75)
    actions.states[0].layers[0].finishing=true;clock=action_clock(&actions,state.entity);testing.expect(t,!clock.active && clock.player.clip!=0);actions.states[0].layers[0].finishing=false
    actions_sample(&actions,&state,&description,.2,nil,&content);layers_advance(&playback,&state,&content,description,&events,.2,nil);actions_layer_finish(&actions,&state);actions_apply_root(&actions,&state,description)
    testing.expect(t,!action_clock(&actions,state.entity).active && abs(actions.states[0].layers[0].delta.translation.x-.2)<1e-5)
    profile.actions[0].fade_in=1
    actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=0};state.layers[0]={};state.motion=ROOT_DELTA_DEFAULT
    actions_sample(&actions,&state,&description,.1,nil,&content);layers_advance(&playback,&state,&content,description,&events,.1,nil);actions_layer_finish(&actions,&state);actions_apply_root(&actions,&state,description)
    testing.expect(t,abs(state.motion.translation.x-.01)<1e-5)
    base.text_set(profile.actions[0].clip[:],"missing")
    problems:core.Problems
    actions_sample(&actions,&state,&description,.1,&problems,&content)
    testing.expect(t,core.problem_find(&problems,state.entity,"animation.action_clip")!=nil && actions.states[0].layers[0].finishing && description.layers[0].clip==0)
}

@(test)
action_distance_requests_advance_only_the_selected_clip_and_reject_discontinuous_sections :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.asset={1,2}
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    append(&actions.plans,Action_Plan{profile=action_test_profile()});action_test_add_state(&actions,Action_State{entity=state.entity,plan=0});reserve(&actions.events.items,ACTION_EVENT_CAPACITY)
    actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=0}
    description:=ANIMATION_DEFAULT;description.asset=state.asset
    request:=Animation_Distance_Request{entity=state.entity,clip=base.name_hash("walk"),time=.15}
    actions_sample(&actions,&state,&description,.01,nil,&content,distance=&request)
    testing.expect(t,abs(state.layers[0].fader.current.time-.15)<1e-5 && actions.events.items[0].kind==.Window_Begin)
    player,selected:=action_player(&actions,state.entity,request.clip)
    testing.expect(t,selected && player.clip!=0 && player.time==.15 && actions.plans[0].profile.actions[0].root_motion==.None)
    _,selected=action_player(&actions,state.entity,base.name_hash("run"));testing.expect(t,!selected)
    problems:core.Problems
    before:=len(actions.events.items);request.time=1.1;actions_sample(&actions,&state,&description,.01,&problems,&content,distance=&request)
    testing.expect(t,core.problem_find(&problems,state.entity,"animation.action_distance")!=nil && state.layers[0].fader.current.time==.15 && len(actions.events.items)==before)
    request.time=.1;request.seek=true;actions_sample(&actions,&state,&description,.01,nil,&content,distance=&request)
    testing.expect(t,state.layers[0].fader.current.time==.1 && !actions.states[0].layers[0].continuous && actions.states[0].layers[0].delta==ROOT_DELTA_DEFAULT && len(actions.events.items)==before)
    request.clip=base.name_hash("run");request.seek=false;request.time=1;actions_sample(&actions,&state,&description,.02,nil,&content,distance=&request)
    testing.expect(t,abs(state.layers[0].fader.current.time-.12)<1e-5)
    actions.plans[0].profile.sections[1].start=.25
    request.clip=base.name_hash("walk");request.time=.4;actions_sample(&actions,&state,&description,.01,nil,&content,distance=&request)
    testing.expect(t,abs(state.layers[0].fader.current.time-.4)<1e-5 && actions.states[0].layers[0].section==1 && actions.states[0].layers[0].continuous)
}

@(test)
root_actions_can_start_over_an_idle_clip_without_root_channels :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer {lib.library_destroy(&content.lib);playing_free(&state)}
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots)
    base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    state.asset,state.clip={1,2},1
    profile:=action_test_profile();profile.actions[0].root_motion=.In_Place
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    append(&actions.plans,Action_Plan{profile=profile});action_test_add_state(&actions,{entity=state.entity,plan=0});reserve(&actions.events.items,ACTION_EVENT_CAPACITY)
    actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=-1}
    description:=ANIMATION_DEFAULT;description.asset=state.asset;description.root_motion=.In_Place
    problems:core.Problems
    actions_sample(&actions,&state,&description,.1,&problems,&content)
    testing.expect(t,problems.count==0 && actions.states[0].layers[0].has_root && !actions.states[0].layers[0].finishing)
}

@(test)
action_root_projection_preserves_each_base_and_action_contribution_and_validates_active_metadata :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.asset={1,2}
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    profile:=action_test_profile();profile.actions[0].root_motion=.In_Place;profile.actions[0].weight=.5;profile.actions[1].layer=2;profile.actions[1].root_motion=.Extract;base.text_set(profile.actions[1].clip[:],"run")
    append(&actions.plans,Action_Plan{profile=profile});action_test_add_state(&actions,Action_State{entity=state.entity,plan=0});reserve(&actions.events.items,ACTION_EVENT_CAPACITY)
    playback:Playback;defer playback_free(&playback);testing.expect(t,lib.pose_init(&playback.pose,64));events:Animation_Events;defer delete(events.items)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms);cache:Animation_Constraints;defer constraints_free(&cache)
    for policy in ([?]Root_Motion_Policy{.In_Place,.Extract}) {
        actions.plans[0].profile.actions[0].root_motion=policy;actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=-1};state.layers={};state.has_action_in_place=false
        description:=ANIMATION_DEFAULT;description.asset=state.asset
        description.root_motion=.In_Place if policy==.Extract else .None;state.clip=0
        state.base_root={bone=bone_ref("hip"),translation=true,in_place=policy==.Extract};state.has_base_root=policy==.Extract
        actions_sample(&actions,&state,&description,.25,nil,&content);layers_advance(&playback,&state,&content,description,&events,.25,nil);actions_layer_finish(&actions,&state)
        copy(state.local[:],state.rest[:]);state.local[1].position.x=1
        pose_layers(&playback,&state,&content.lib,description,nil);constraints_apply(&state,&playback,{},&cache,&transforms,{},.25)
        expected:f32=.5 if policy==.In_Place else .125
        testing.expect(t,state.action_root_mask==1 && state.has_action_in_place && abs(state.local[1].position.x-expected)<1e-5)
        actions.states[0].layers[0].finishing=true
        description=ANIMATION_DEFAULT;description.asset=state.asset;actions_sample(&actions,&state,&description,.01,nil,&content)
        testing.expect(t,state.action_root_mask==1 && actions.states[0].layers[0].has_root)
    }
    state.has_base_root=false;state.layers={};actions.states[0].layers={};actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=-1};actions.states[0].layers[1]={active=true,starting=true,seeking=true,action=1,section=-1}
    content.roots[2]=content.roots[0];content.roots[2].translation=false;content.roots[2].rotation=true
    problems:core.Problems
    description:=ANIMATION_DEFAULT;description.asset=state.asset;actions_sample(&actions,&state,&description,.1,&problems,&content)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,state.entity,"animation.action_clip")!=nil && state.action_root_mask==1 && actions.states[0].layers[1].finishing && !actions.states[0].layers[1].has_root)
    actions.states[0].layers[0]={active=true,starting=true,seeking=true,action=0,section=-1};description=ANIMATION_DEFAULT;description.asset=state.asset;description.source=core.entity_make(2,1)
    actions_sample(&actions,&state,&description,.1,nil,&content)
    testing.expect(t,state.action_root_mask==0 && actions.states[0].layers[0].finishing && action_policy_check(profile.actions[0],description)==.UnsupportedPolicy)
}

@(test)
actions_preserve_the_previous_asset_state_when_appending_a_replacement_plan_fails_and_retry :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
    descriptions:core.Table(Animation);defer core.table_destroy(&descriptions)
    description:=ANIMATION_DEFAULT;description.asset={1,2};description.actions={3,4};core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
    cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache)
    append(&cache.contents,Action_Content{id={3,4},checked=1,revision=1,profile=action_test_profile(),valid=true},Action_Content{id={5,6},checked=1,revision=1,profile=action_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    playback:Playback;defer playback_free(&playback);requests:Action_Requests;defer delete(requests.queue.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
    action_fire(&requests,entity,"attack");if !testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)) {return}
    previous:=actions.states[0].layers;previous_plan:=actions.plans[0]
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=100};failing:=runtime.Allocator{procedure=runtime_failure_allocator,data=&failure}
    limited:=make([dynamic]Action_Plan,1,1,failing);limited[0]=actions.plans[0];delete(actions.plans);actions.plans=limited
    core.free(&descriptions,entity).actions={5,6};failure.remaining,failure.calls=3,0;app.allocator=failing
    problems:core.Problems
    prepared:=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,&problems)
    app.allocator=failure.owner;actions.allocator=failure.owner
    testing.expect(t,prepared && failure.calls==4 && core.problem_find(&problems,entity,"animation.memory")!=nil && len(actions.plans)==1 && len(actions.states)==1)
    testing.expect(t,actions.states[0].plan==0 && actions.states[0].layers==previous && actions.states[0].seen==actions.frame && actions.plans[0].asset==previous_plan.asset && actions.plans[0].revision==previous_plan.revision && raw_data(actions.plans[0].profile.actions)==raw_data(previous_plan.profile.actions) && len(actions.events.items)==0)
    failure.remaining=100
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil))
    testing.expect(t,len(actions.plans)==2 && actions.plans[1].asset==base.Asset_Id{5,6} && actions.states[0].plan==1 && actions.states[0].layers[0].finishing && actions.events.items[0].kind==.Interrupted)
}

@(test)
a_new_actions_asset_or_revision_interrupts_the_playing_action_and_fades_its_layer_out :: proc(t:^testing.T) {
    for change in ([2]string{"another asset","a new revision"}) {
        entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
        descriptions:core.Table(Animation);defer core.table_destroy(&descriptions)
        description:=ANIMATION_DEFAULT;description.asset={1,2};description.actions={3,4};core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
        cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache)
        append(&cache.contents,Action_Content{id={3,4},checked=1,revision=1,profile=action_test_profile(),valid=true},Action_Content{id={5,6},checked=1,revision=1,profile=action_test_profile(),valid=true})
        host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
        content:host.Content_Animation;defer lib.library_destroy(&content.lib)
        playback:Playback;defer playback_free(&playback)
        append(&playback.states,layer_fixture(t,&content));resize(&playback.rows,core.entity_index(entity)+1);playback.rows[core.entity_index(entity)]=1
        state:=&playback.states[0];state.entity,state.asset=entity,description.asset
        events:Animation_Events;defer delete(events.items)
        requests:Action_Requests;defer delete(requests.queue.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
        tick :: proc(actions:^Action_Runtime,requests:^Action_Requests,cache:^Actions_Assets,descriptions:^core.Table(Animation),playback:^Playback,app:^host.App,content:^host.Content_Animation,events:^Animation_Events,dt:f32) -> bool {
            if !actions_prepare(actions,requests,cache,core.read(descriptions),playback,app,nil) {return false}
            state:=&playback.states[0];sampled,_:=core.get(core.read(descriptions),state.entity)
            actions_sample(actions,state,&sampled,dt,nil,content,playback,events);layers_advance(playback,state,content,sampled,events,dt,nil);actions_finish(actions,playback,dt)
            return true
        }
        action_fire(&requests,entity,"attack")
        if !testing.expect(t,tick(&actions,&requests,&cache,&descriptions,&playback,&app,&content,&events,.1) && state.layers[0].weight==1) {continue}
        if change=="another asset" {core.free(&descriptions,entity).actions={5,6}} else {cache.contents[0].revision+=1}
        weights:[dynamic]f32;defer delete(weights)
        interrupted:=0
        for _ in 0..<10 {
            ticked:=tick(&actions,&requests,&cache,&descriptions,&playback,&app,&content,&events,.05)
            for event in actions.events.items {if event.kind==.Interrupted {interrupted+=1}}
            if !testing.expect(t,ticked) || !actions.states[0].layers[0].active {break}
            append(&weights,state.layers[0].weight)
        }
        testing.expectf(t,interrupted==1,"%s interrupts the action once, not %d times",change,interrupted)
        testing.expectf(t,len(weights)>=3 && !actions.states[0].layers[0].active,"%s fades the layer out over fade_out, %v",change,weights[:])
        for weight,i in weights {testing.expectf(t,weight>0 && weight<1 && (i==0 || weight<weights[i-1]),"%s lowers the weight tick by tick, %v",change,weights[:])}
    }
}

@(test)
actions_discover_changed_components_retry_requests_and_compact_generational_rows_through_world_copies :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    first,second,plain:=core.create(&entities),core.create(&entities),core.create(&entities)
    descriptions:core.Table(Animation);defer core.table_destroy(&descriptions)
    for entity in ([3]core.Entity{first,second,plain}) {core.add(&descriptions,entity,ANIMATION_DEFAULT)}
    core.table_settle(&descriptions,&entities)
    cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache)
    append(&cache.contents,Action_Content{id={3,4},checked=1,revision=1,profile=action_test_profile(),valid=true},Action_Content{id={3,5},checked=1,revision=1,profile=action_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    playback:Playback;defer playback_free(&playback);requests:Action_Requests;defer delete(requests.queue.items)
    actions:Action_Runtime;defer actions_runtime_free(&actions)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    empty:=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator
    testing.expect(t,empty && len(actions.states)==0 && cap(actions.events.items)==0)
    core.get(&descriptions,first).actions={3,4};core.get(&descriptions,second).actions={3,5}
    action_fire(&requests,first,"attack")
    observed:=actions.animation_version
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator
    testing.expect(t,!prepared && len(requests.queue.items)==1 && len(actions.states)==0 && actions.animation_version==observed)
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil) && len(actions.states)==2 && action_state(&actions,first).layers[0].active)
    copied:Action_Runtime;core.value_copy(&copied,&actions,type_info_of(Action_Runtime));defer actions_runtime_free(&copied)
    first_state:=action_state(&copied,first);first_state.layers[0].time=9
    testing.expect(t,action_state(&actions,first).layers[0].time!=9)
    core.get(&descriptions,first).actions={3,5}
    core.get(&descriptions,plain).weight=.4
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && actions.plans[action_state(&actions,first).plan].asset==base.Asset_Id{3,5} && len(actions.states)==2 && actions.events.items[0].kind==.Interrupted)
    core.remove(&descriptions,first);core.table_settle(&descriptions,&entities)
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil) && action_state(&actions,first)==nil && action_state(&actions,second)!=nil && len(actions.states)==1)
    old:=second;index:=core.entity_index(second)
    core.destroy(&entities,second);core.table_settle(&descriptions,&entities);core.entities_settle(&entities)
    second=core.create(&entities);core.add(&descriptions,second,Animation{actions={3,4}});core.table_settle(&descriptions,&entities)
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && core.entity_index(second)==index && second!=old && action_state(&actions,old)==nil && action_state(&actions,second)!=nil && len(actions.states)==1)
}

@(test)
actions_retry_a_first_fire_when_profile_preparation_has_no_memory :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
    descriptions:core.Table(Animation);defer core.table_destroy(&descriptions);description:=ANIMATION_DEFAULT;description.actions={3,4};core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
    cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache);append(&cache.contents,Action_Content{id={3,4},checked=1,revision=1,profile=action_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator};playback:Playback;defer playback_free(&playback)
    actions:Action_Runtime;defer actions_runtime_free(&actions);requests:Action_Requests;defer delete(requests.queue.items)
    testing.expect(t,actions_discover(&actions,core.read(&descriptions),false,nil))
    action_fire(&requests,entity,"attack")
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && len(requests.queue.items)==1 && len(actions.plans)==0 && !action_state(&actions,entity).layers[0].active)
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil) && len(requests.queue.items)==0 && action_state(&actions,entity).layers[0].active && actions.events.items[0].kind==.Started)
}

@(test)
action_playing_answers_while_an_action_plays_and_animation_stop_frees_a_layer_that_weight_zero_keeps :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
    descriptions:core.Table(Animation);defer core.table_destroy(&descriptions);description:=ANIMATION_DEFAULT;description.actions={3,4};core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
    cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache);append(&cache.contents,Action_Content{id={3,4},checked=1,revision=1,profile=action_test_profile(),valid=true})
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator};playback:Playback;defer playback_free(&playback)
    actions:Action_Runtime;defer actions_runtime_free(&actions);requests:Action_Requests;defer delete(requests.queue.items)
    problems:core.Problems
    _,_,playing:=action_playing({&actions},entity,"attack");testing.expect(t,!playing)
    // A pose faded out to weight 0 keeps its clip, so the layer stays taken.
    testing.expect(t,animation_play(core.get(&descriptions,entity),"wave",layer=1) && animation_weight(core.get(&descriptions,entity),1,0))
    action_fire(&requests,entity,"attack")
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,&problems))
    _,_,playing=action_playing({&actions},entity,"attack")
    testing.expect(t,core.problem_find(&problems,entity,"animation.action_layer")!=nil && !playing)
    // animation_stop frees it in the same tick.
    core.problems_clear(&problems)
    testing.expect(t,animation_stop(core.get(&descriptions,entity),1,.3) && core.get(&descriptions,entity).layers[0].fade==.3)
    action_fire(&requests,entity,"attack")
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,&problems))
    time,section,ok:=action_playing({&actions},entity,"attack")
    testing.expect(t,core.problem_find(&problems,entity,"animation.action_layer")==nil && ok && time==0 && section==base.name_hash("windup"))
    _,_,playing=action_playing({&actions},entity,"interrupt");testing.expect(t,!playing)
    _,_,playing=action_playing({&actions},core.NONE,"attack");testing.expect(t,!playing)
    action_section(&requests,entity,"attack","recover")
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,&problems))
    time,section,ok=action_playing({&actions},entity,"attack");testing.expect(t,ok && time==1 && section==base.name_hash("recover"))
    // Cancelled, it fades out and no longer plays.
    action_cancel(&requests,entity,"attack")
    testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,&problems))
    _,_,playing=action_playing({&actions},entity,"attack");testing.expect(t,!playing && actions.states[0].layers[0].finishing)
}

@(test)
a_world_action_plays_at_its_speed_while_its_entity_is_slowed :: proc(t:^testing.T) {
    for clock in Action_Clock {
        entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities);entity:=core.create(&entities)
        descriptions:core.Table(Animation);defer core.table_destroy(&descriptions)
        description:=ANIMATION_DEFAULT;description.asset={1,2};description.actions={3,4};description.loop=false;core.add(&descriptions,entity,description);core.table_settle(&descriptions,&entities)
        content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.entity=entity;state.asset=description.asset
        cache:=Actions_Assets{allocator=context.allocator};defer actions_assets_free(&cache)
        append(&cache.contents,Action_Content{id=description.actions,checked=1,revision=1,profile=action_test_profile(),valid=true})
        cache.contents[0].profile.actions[0].clock=clock
        host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
        playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
        requests:Action_Requests;defer delete(requests.queue.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
        action_fire(&requests,entity,"attack")
        testing.expect(t,actions_prepare(&actions,&requests,&cache,core.read(&descriptions),&playback,&app,nil))
        // A tick of 0.2 s of the world while the entity runs at half pace: 0.1 s of its own time.
        actions_sample(&actions,&state,&description,.1,nil,&content,&playback,&events,pace=.5)
        want:=f32(.2) if clock==.World else .1
        testing.expectf(t,abs(actions.states[0].layers[0].time-want)<1e-5,"%v: the action is at %v s of its clip, want %v",clock,actions.states[0].layers[0].time,want)
        layers_advance(&playback,&state,&content,description,&events,.1,nil);actions_layer_finish(&actions,&state)
        testing.expectf(t,abs(state.layers[0].fader.current.time-want)<1e-5,"%v: the pose is at %v s of its clip, want %v",clock,state.layers[0].fader.current.time,want)
    }
}
