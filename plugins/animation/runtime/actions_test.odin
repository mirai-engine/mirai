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

// Two actions of the walk: attack, in the sections windup and recover, and interrupt. The spans
// of the walk (action_test_spans) place its sections and its window contact.
@(private)
action_test_profile :: proc() -> Action_Profile {
    profile:Action_Profile
    profile.actions=make([]Action_Definition,2);profile.sections=make([]Action_Section,2)
    for &value in profile.actions {value=ACTION_DEFINITION_DEFAULT;value.fade_in,value.fade_out=0,.2;base.text_set(value.clip[:],"walk")}
    base.text_set(profile.actions[0].name[:],"attack");base.text_set(profile.actions[1].name[:],"interrupt");profile.actions[1].priority=1
    profile.sections[0]={action=0,next=1};base.text_set(profile.sections[0].name[:],"windup")
    profile.sections[1]={action=0,next=-1};base.text_set(profile.sections[1].name[:],"recover")
    return profile
}
// The spans of the walk of layer_fixture: windup 0 to .25, contact .1 to .2 and recover 1 to 1.5,
// with markers windup at .1 and recover at 1.1.
@(private)
action_test_spans :: proc(content:^host.Content_Animation) {
    content.lib.markers=make([]lib.Marker,5);content.lib.marker_count=5
    content.lib.markers[0],content.lib.markers[1],content.lib.markers[2]={time=0,id=0,duration=.25},{time=.1,id=0},{time=.1,id=1,duration=.1}
    content.lib.markers[3],content.lib.markers[4]={time=1,id=2,duration=.5},{time=1.1,id=2}
    content.lib.clips[0].marker_count=5;content.lib.clips[3].marker_count=5
    content.markers=make([]u64,3);content.markers[0],content.markers[1],content.markers[2]=base.name_hash("windup"),base.name_hash("contact"),base.name_hash("recover")
}
@(private)
action_test_spans_free :: proc(content:^host.Content_Animation) {delete(content.markers);content.markers=nil}
// The .character {3,4} of the actions of profile over the clips {1,2} of layer_fixture.
@(private)
action_test_set :: proc(profile:Action_Profile) -> Character_Set {return {info={animation={1,2}},match={info=MATCH_INFO_DEFAULT},actions=profile,motion={warp=POSE_WARP_PROFILE_DEFAULT}}}

// A tick of the actions and the layers of state over content, as animation_tick runs them, over a
// base whose root motion is base: stack_root blends the layers over it.
@(private="file")
stack_step :: proc(actions:^Action_Runtime,state:^Playing,description:Animation,content:^host.Content_Animation,playback:^Playback,events:^Animation_Events,dt:f32,problems:^core.Problems=nil,base:=ROOT_DELTA_DEFAULT,distance:^Animation_Distance_Request=nil) {
    stack_asks(actions,state,description,content)
    actions_sample(actions,state,description,dt,problems,content,playback,events,distance,1)
    layers_advance(playback,state,content,description,events,dt,problems)
    actions_layer_finish(actions,state)
    state.motion,state.body_motion=base,{}
}

@(private)
action_test_add_state :: proc(runtime:^Action_Runtime,value:Action_State) {
    append(&runtime.states,value)
    index:=core.entity_index(value.entity);resize(&runtime.rows,index+1);runtime.rows[index]=i32(len(runtime.states))
}
// A plan of the runtime as actions_prepare leaves one: its slots and layers resolved.
@(private)
action_test_plan :: proc(runtime:^Action_Runtime,plan:Action_Plan) {
    append(&runtime.plans,plan);action_plan_bind(&runtime.plans[len(runtime.plans)-1],action_test_set(plan.profile))
}
// A second layer for the action that does not take the whole body.
@(private)
action_test_layered :: proc(profile:^Action_Profile,action:int) {
    profile.layers=make([]Stack_Layer,1);profile.layers[0]=STACK_LAYER_DEFAULT
    base.text_set(profile.layers[0].name[:],"second");base.text_set(profile.actions[action].layer[:],"second")
}
// actions_prepare over the events of a tick of its own, as animation_tick clears them.
@(private="file")
prepare :: proc(actions:^Action_Runtime,requests:^Animation_Requests,cache:^Character_Assets,descriptions:^core.Table(Animation),playback:^Playback,events:^Animation_Events,app:^host.App,problems:^core.Problems,remotes:core.Read(core.Remote)={},played:^core.Table(Animation_Played)=nil,tick:u64=1) -> bool {
    clear(&events.items)
    unheard:core.Table(Animation_Played);defer core.table_destroy(&unheard)
    local:core.Table(core.Remote);defer core.table_destroy(&local)
    return actions_prepare(actions,requests,cache,core.read(descriptions),playback,events,app,remotes if remotes.table!=nil else core.read(&local),played if played!=nil else &unheard,{tick=tick,dt=.1,playing=true},problems)
}
// How many events of a kind the tick left.
@(private="file")
count :: proc(events:^Animation_Events,kind:Animation_Event_Kind) -> (n:int) {
    for event in events.items {if event.kind==kind {n+=1}}
    return
}

@(test)
action_sets_roundtrip_and_reject_invalid_layers_section_links_and_root_policies :: proc(t:^testing.T) {
    profile:=action_test_profile();defer action_profile_free(&profile)
    for &action in profile.actions {action.clock=.World}
    profile.layers=make([]Stack_Layer,2)
    profile.layers[0]=test_stack_layer("wave",over="arm",weight=.5,fade=.2,mesh_space=true,name="Arm")
    profile.layers[1]=STACK_LAYER_DEFAULT;base.text_set(profile.layers[1].name[:],"Aim");profile.layers[1].mode=.Additive
    base.text_set(profile.actions[1].layer[:],"Arm");profile.actions[1].entry,profile.actions[1].exit=.Match_Phase,.5;base.text_set(profile.actions[1].exit_marker[:],"release")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    roundtrip :: proc(t:^testing.T,types:^asset.Types,profile:Action_Profile) -> (view:Action_Profile,file:asset.Asset,ok:bool) {
        doc:asset.Document;defer asset.document_destroy(&doc)
        if !testing.expect_value(t,character_document(&doc,types,{3,4},action_test_set(profile)),asset.Error.None) {return}
        bytes,written:=asset.document_bytes(&doc,context.temp_allocator);testing.expect_value(t,written,asset.Error.None)
        if !testing.expect_value(t,asset.asset_open(&file,bytes,context.temp_allocator),asset.Error.None) {return}
        set,error:=character_view(&file,types)
        return set.actions,file,testing.expect_value(t,error,asset.Error.None)
    }
    view,file,read:=roundtrip(t,&types,profile);defer asset.asset_close(&file)
    if !read {return}
    testing.expect_value(t,view.sections[1],profile.sections[1])
    testing.expect(t,view.actions[0].clock==.World && view.actions[1]==profile.actions[1] && view.layers[0]==profile.layers[0] && view.layers[1]==profile.layers[1])
    // What a table of cases breaks, each put back: the set is refused with it and taken without.
    Break :: proc(profile:^Action_Profile)
    breaks:=[?]struct {what:string,apply,undo:Break}{
        {"a section that goes on to none",proc(p:^Action_Profile) {p.sections[0].next=99},proc(p:^Action_Profile) {p.sections[0].next=1}},
        {"a section that goes on to one of another action",proc(p:^Action_Profile) {p.sections[1].action=1},proc(p:^Action_Profile) {p.sections[1].action=0}},
        {"an action in a layer the set does not have",proc(p:^Action_Profile) {base.text_set(p.actions[0].layer[:],"Leg")},proc(p:^Action_Profile) {p.actions[0].layer={}}},
        {"root motion in a layer over a branch",proc(p:^Action_Profile) {p.actions[1].root_motion=.Extract},proc(p:^Action_Profile) {p.actions[1].root_motion=.None}},
        {"root motion in a layer that adds",proc(p:^Action_Profile) {base.text_set(p.actions[0].layer[:],"Aim");p.actions[0].root_motion=.Extract},proc(p:^Action_Profile) {p.actions[0].layer={};p.actions[0].root_motion=.None}},
        {"an exit of no share of the clip",proc(p:^Action_Profile) {p.actions[0].exit=0},proc(p:^Action_Profile) {p.actions[0].exit=1}},
        {"an exit past the clip",proc(p:^Action_Profile) {p.actions[0].exit=1.5},proc(p:^Action_Profile) {p.actions[0].exit=1}},
        {"two layers of one name",proc(p:^Action_Profile) {p.layers[1].name=p.layers[0].name},proc(p:^Action_Profile) {base.text_set(p.layers[1].name[:],"Aim")}},
        {"a layer with a clip and a space",proc(p:^Action_Profile) {base.text_set(p.layers[0].space[:],"aim")},proc(p:^Action_Profile) {p.layers[0].space={}}},
        {"a layer that keeps the phase of the base with no clip",proc(p:^Action_Profile) {p.layers[1].sync=true},proc(p:^Action_Profile) {p.layers[1].sync=false}},
        {"a layer weight past 1",proc(p:^Action_Profile) {p.layers[0].weight=2},proc(p:^Action_Profile) {p.layers[0].weight=.5}},
        {"a layer weight that is not a number",proc(p:^Action_Profile) {zero:f32;p.layers[0].weight=zero/zero},proc(p:^Action_Profile) {p.layers[0].weight=.5}},
        {"a body that moves without root motion",proc(p:^Action_Profile) {p.actions[0].body_move=.Override},proc(p:^Action_Profile) {p.actions[0].body_move=.None}},
        {"a vertical without a body move",proc(p:^Action_Profile) {p.actions[0].body_vertical=true},proc(p:^Action_Profile) {p.actions[0].body_vertical=false}},
    }
    for value in breaks {
        value.apply(&profile);testing.expectf(t,!action_profile_check(profile),"%s is refused",value.what)
        value.undo(&profile);testing.expectf(t,action_profile_check(profile),"without %s the set is taken",value.what)
    }
    // An action that takes the whole body moves its body by its root motion, vertical too.
    profile.actions[0].root_motion,profile.actions[0].body_move,profile.actions[0].body_vertical=.In_Place,.Override,true
    testing.expect(t,action_profile_check(profile))
    moved,moving,again:=roundtrip(t,&types,profile);defer asset.asset_close(&moving)
    testing.expect(t,again && moved.actions[0]==profile.actions[0])
}

@(private="file")
Actions_World :: struct {
    using world:core.Test_World,
    descriptions:core.Table(Animation),
    transforms:core.Table(core.Transform),
    played:core.Table(Animation_Played),
    remotes:core.Table(core.Remote),
}

// What the end that decides an entity plays reaches the others in its Animation_Played: there it
// plays once, as far into it as that end is, and a copy of the world from before it played (a
// rollback) plays it the same, not again from its start.
@(test)
an_action_another_end_started_plays_once_as_far_into_it_as_that_end_is :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4};core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
    profile:=action_test_profile();defer action_profile_free(&profile)
    cache:Character_Assets;defer character_assets_free(&cache)
    test_character_seed(&cache,description.asset,action_test_set(profile))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    test_character_register(&host_assets,description.asset);defer test_registry_free(&host_assets)
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.entity=entity;state.asset=content.id
    action_test_spans(&content);defer action_test_spans_free(&content)
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    requests:Animation_Requests;defer delete(requests.plays.items)
    server,client:Action_Runtime;defer {actions_runtime_free(&server);actions_runtime_free(&client)}
    // The end that decides it tells the tick it asked for it.
    play(&requests,entity,"attack")
    testing.expect(t,prepare(&server,&requests,&cache,&w.descriptions,&playback,&events,&app,nil,core.read(&w.remotes),&w.played,tick=10))
    core.test_world_settle(&w)
    record,told:=core.get(&w.played,entity)
    testing.expect(t,told && record.slots[0]==Action_Started{action=base.name_hash("attack"),tick=10})
    // Another end, which does not decide it, plays it once from there.
    testing.expect(t,prepare(&client,&requests,&cache,&w.descriptions,&playback,&events,&app,nil,core.read(&w.remotes),&w.played,tick=10))
    core.add(&w.remotes,entity,core.Remote{});core.test_world_settle(&w)
    before:Action_Runtime;defer actions_runtime_free(&before)
    core.value_copy(&before,&client,type_info_of(Action_Runtime));layers:=state.layers
    // Two ticks: it starts as far in as the server is, once, and plays on.
    run :: proc(actions:^Action_Runtime,state:^Playing,description:Animation,content:^host.Content_Animation,playback:^Playback,events:^Animation_Events,w:^Actions_World,requests:^Animation_Requests,cache:^Character_Assets,app:^host.App) -> (time:f32,started:int,ok:bool) {
        for tick in u64(11)..=12 {
            if !prepare(actions,requests,cache,&w.descriptions,playback,events,app,nil,core.read(&w.remotes),&w.played,tick=tick) {return}
            stack_asks(actions,state,description,content);actions_sample(actions,state,description,.1,nil,content,playback,events,nil,1)
            started+=count(events,.Started)
            if tick==11 {time=actions.states[0].slots[0].time}
        }
        return time,started,true
    }
    time,started,ok:=run(&client,&state,description,&content,&playback,&events,&w,&requests,&cache,&app)
    testing.expectf(t,ok && abs(time-.2)<1e-5 && started==1 && client.states[0].slots[0].active,"a tick late it starts a tick in, once: %v %v",time,started)
    // A rollback to before it was heard plays it the same, and does not start it twice.
    after:=client.states[0].slots[0]
    actions_runtime_free(&client);core.value_copy(&client,&before,type_info_of(Action_Runtime));state.layers=layers
    time,started,ok=run(&client,&state,description,&content,&playback,&events,&w,&requests,&cache,&app)
    testing.expect(t,ok && abs(time-.2)<1e-5 && started==1 && client.states[0].slots[0]==after)
}

// An action whose body_move is not None gives its body the share of the root delta of the tick it
// has, and not what the base keeps; without one the body is left to its locomotion.
@(test)
an_action_that_moves_its_body_gives_it_its_share_of_the_root_delta :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4};core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
    profile:=action_test_profile();profile.actions[0].weight=.75
    for &action in profile.actions {action.root_motion=.In_Place;action.body_move=.Additive}
    cache:Character_Assets;defer character_assets_free(&cache);defer action_profile_free(&profile)
    test_character_seed(&cache,{3,4},action_test_set(profile))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    test_character_register(&host_assets,{3,4});defer test_registry_free(&host_assets)
    content:host.Content_Animation;defer lib.library_destroy(&content.lib)
    playback:Playback;defer playback_free(&playback)
    append(&playback.states,layer_fixture(t,&content));resize(&playback.rows,core.entity_index(entity)+1);playback.rows[core.entity_index(entity)]=1
    action_test_spans(&content);defer action_test_spans_free(&content)
    state:=&playback.states[0];state.entity,state.asset,state.seen=entity,content.id,playback.frame
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    requests:Animation_Requests;defer delete(requests.plays.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
    events:Animation_Events;defer delete(events.items)
    play(&requests,entity,"attack")
    if !testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)) {return}
    stack_step(&actions,state,description,&content,&playback,&events,.2,base={translation={.1,0,0},rotation=1});stack_root(state,&content,description,.2)
    body,moving:=animation_body_motion(&playback,entity)
    testing.expectf(t,moving && body.move==.Additive && !body.vertical && abs(body.translation.x-.15)<1e-5 && abs(state.motion.translation.x-.175)<1e-5,"the action has .75 of .2 and the base the rest of .1: %v %v",body,state.motion)
    state.layers[0].body=.None;state.motion={translation={.1,0,0},rotation=1};stack_root(state,&content,description,.2)
    _,moving=animation_body_motion(&playback,entity)
    testing.expect(t,!moving && abs(state.motion.translation.x-.175)<1e-5)
}

@(test)
actions_segment_sections_and_windows_copy_state_and_obey_cancellation_without_stable_allocations :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4};description.loop=false;core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.entity=entity;state.asset=content.id
    action_test_spans(&content);defer action_test_spans_free(&content)
    profile:=action_test_profile();defer action_profile_free(&profile)
    cache:Character_Assets;defer character_assets_free(&cache)
    test_character_seed(&cache,description.asset,action_test_set(profile))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    test_character_register(&host_assets,description.asset);defer test_registry_free(&host_assets)
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    requests:Animation_Requests;defer delete(requests.plays.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
    problems:core.Problems
    play(&requests,entity,"attack")
    initial_request:=requests.plays.items[0];initial_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    prepared:=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=initial_context;app.allocator=initial_context.allocator;actions.allocator=initial_context.allocator
    testing.expect(t,!prepared && len(requests.plays.items)==1 && requests.plays.items[0]==initial_request && len(actions.states)==0 && len(events.items)==0)
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil))
    // It tells it started when it plays, in the sample of the tick.
    testing.expect(t,len(requests.plays.items)==0 && actions.states[0].slots[0].active && len(events.items)==0)
    stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.4,nil,&content,&playback,&events,nil,1)
    layers_advance(&playback,&state,&content,description,&events,.4,nil);actions_layer_finish(&actions,&state)
    testing.expect(t,abs(state.layers[0].fader.current.time-1.15)<1e-5)
    // One queue, in the order it happened: the markers of its clip between what the action tells.
    kinds:=[?]Animation_Event_Kind{.Started,.Section,.Marker,.Span_Begin,.Span_End,.Section,.Marker}
    names:=[?]string{"windup","windup","windup","contact","contact","recover","recover"}
    testing.expect_value(t,len(events.items),len(kinds))
    for event,i in events.items {
        if i>=len(kinds) {break}
        testing.expectf(t,event.kind==kinds[i] && event.name==base.name_hash(names[i]) && event.action==base.name_hash("attack") && event.entity==entity,"event %d is %v '%s' of the attack, not %v",i,kinds[i],names[i],event)
    }
    testing.expect(t,abs(events.items[2].fraction-.25)<1e-5 && abs(events.items[6].fraction-.875)<1e-5)
    copied:Action_Runtime;core.value_copy(&copied,&actions,type_info_of(Action_Runtime));defer actions_runtime_free(&copied)
    copied.states[0].slots[0].time=7;copied.plans[0].profile.actions[0].priority=99
    testing.expect(t,actions.states[0].slots[0].time!=7 && actions.plans[0].profile.actions[0].priority!=99)
    profile.actions[0].cancel=.Finish_Section;actions.plans[0].profile.actions[0].cancel=.Finish_Section
    stop(&requests,entity,"attack");testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil))
    testing.expect(t,actions.states[0].slots[0].cancel_pending && !actions.states[0].slots[0].finishing && len(events.items)==0,"a stop of Finish_Section waits for the end of the section")
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    okay:=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.5,nil,&content,&playback,&events,nil,1);layers_advance(&playback,&state,&content,description,&events,.5,nil);actions_layer_finish(&actions,&state)
    context=saved;cache.allocator=saved.allocator;actions.allocator=saved.allocator
    testing.expect(t,okay && actions.states[0].slots[0].finishing && count(&events,.Interrupted)==1 && count(&events,.Ended)==0)
    play(nil,entity,"attack");play(&requests,core.NONE,"attack");stop(&requests,entity,"")
    testing.expect_value(t,requests.plays.refused,2)
    cache.contents[0].revision+=1
    before:=actions.states[0].slots[0];revision:=actions.plans[0].revision
    saved=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    okay=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=saved;cache.allocator=saved.allocator;actions.allocator=saved.allocator;app.allocator=saved.allocator
    testing.expect(t,okay && len(actions.states)==1 && actions.states[0].slots[0]==before && actions.plans[0].revision==revision)
    cache.contents[0].revision=revision
    clear(&requests.plays.items);for _ in 0..=cap(requests.plays.items) {play(&requests,entity,"attack")};testing.expect_value(t,requests.plays.dropped,1)
}

@(test)
action_root_motion_uses_section_segments_fade_weight_and_exposes_a_continuous_warp_clock :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.asset={1,2}
    action_test_spans(&content);defer action_test_spans_free(&content)
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    profile:=action_test_profile();profile.actions[0].root_motion=.In_Place;profile.actions[0].weight=.75
    profile.actions[1].root_motion=.In_Place
    action_test_plan(&actions,Action_Plan{asset={3,4},profile=profile});action_test_add_state(&actions,Action_State{entity=state.entity,plan=0})
    actions.states[0].slots[0]={active=true,starting=true,seeking=true,action=0,section=0}
    description:=ANIMATION_DEFAULT;description.asset=state.asset
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    stack_step(&actions,&state,description,&content,&playback,&events,.2,base={translation={.1,0,0},rotation=1})
    leading,share:=stack_root(&state,&content,description,.2)
    testing.expect(t,abs(state.motion.translation.x-.175)<1e-5 && state.root.translation && state.root.in_place && leading==0)
    clock:=action_clock(&actions,&state,&content,leading,share);testing.expect(t,clock.active && clock.from==0 && abs(clock.to-.2)<1e-5 && clock.weight==.75)
    actions.states[0].slots[0].finishing=true;clock=action_clock(&actions,&state,&content,leading,share);testing.expect(t,!clock.active && clock.player.clip!=0);actions.states[0].slots[0].finishing=false
    // A jump from windup to recover keeps the root motion before it.
    stack_step(&actions,&state,description,&content,&playback,&events,.2);leading,share=stack_root(&state,&content,description,.2)
    testing.expect(t,!action_clock(&actions,&state,&content,leading,share).active && abs(state.motion.translation.x-.2*.75)<1e-5)
    profile.actions[0].fade_in=1
    actions.states[0].slots[0]={active=true,starting=true,seeking=true,action=0,section=0};state.layers[0]={}
    stack_step(&actions,&state,description,&content,&playback,&events,.1);stack_root(&state,&content,description,.1)
    testing.expect(t,abs(state.motion.translation.x-.01)<1e-5)
    base.text_set(profile.actions[0].clip[:],"missing")
    problems:core.Problems
    stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.1,&problems,&content,&playback,&events,nil,1)
    testing.expect(t,core.problem_find(&problems,state.entity,"animation.action_clip")!=nil && actions.states[0].slots[0].finishing && state.asked[0].clip==0 && state.asked[0].weight==0)
}

@(test)
action_distance_requests_advance_only_the_selected_clip_and_reject_discontinuous_sections :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.asset={1,2}
    action_test_spans(&content);defer action_test_spans_free(&content)
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    action_test_plan(&actions,Action_Plan{profile=action_test_profile()});action_test_add_state(&actions,Action_State{entity=state.entity,plan=0})
    actions.states[0].slots[0]={active=true,starting=true,seeking=true,action=0,section=0}
    description:=ANIMATION_DEFAULT;description.asset=state.asset
    request:=Animation_Distance_Request{entity=state.entity,clip=base.name_hash("walk"),time=.15}
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.01,nil,&content,&playback,&events,&request,1)
    testing.expect(t,abs(state.layers[0].fader.current.time-.15)<1e-5 && count(&events,.Span_Begin)==1)
    player,selected:=action_player(&actions,state.entity,request.clip)
    testing.expect(t,selected && player.clip!=0 && player.time==.15 && actions.plans[0].profile.actions[0].root_motion==.None)
    _,selected=action_player(&actions,state.entity,base.name_hash("run"));testing.expect(t,!selected)
    problems:core.Problems
    before:=len(events.items);request.time=1.1;stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.01,&problems,&content,&playback,&events,&request,1)
    testing.expect(t,core.problem_find(&problems,state.entity,"animation.action_distance")!=nil && state.layers[0].fader.current.time==.15 && len(events.items)==before)
    request.time=.1;request.seek=true;stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.01,nil,&content,&playback,&events,&request,1)
    testing.expect(t,state.layers[0].fader.current.time==.1 && !actions.states[0].slots[0].continuous && state.layers[0].from==.1 && len(events.items)==before)
    request.clip=base.name_hash("run");request.seek=false;request.time=1;stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.02,nil,&content,&playback,&events,&request,1)
    testing.expect(t,abs(state.layers[0].fader.current.time-.12)<1e-5)
    content.lib.markers[3].time=.25
    request.clip=base.name_hash("walk");request.time=.4;stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.01,nil,&content,&playback,&events,&request,1)
    testing.expect(t,abs(state.layers[0].fader.current.time-.4)<1e-5 && actions.states[0].slots[0].section==1 && actions.states[0].slots[0].continuous)
}

@(test)
root_actions_can_start_over_an_idle_clip_without_root_channels :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer {lib.library_destroy(&content.lib);playing_free(&state)}
    action_test_spans(&content);defer action_test_spans_free(&content)
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots)
    base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    state.asset,state.clip={1,2},1
    profile:=action_test_profile();profile.actions[0].root_motion=.In_Place
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    action_test_plan(&actions,Action_Plan{profile=profile});action_test_add_state(&actions,{entity=state.entity,plan=0})
    actions.states[0].slots[0]={active=true,starting=true,seeking=true,action=0,section=-1}
    description:=ANIMATION_DEFAULT;description.asset=state.asset;description.root_motion=.In_Place
    problems:core.Problems
    playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
    stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.1,&problems,&content,&playback,&events,nil,1)
    testing.expect(t,problems.count==0 && state.layers[0].root_motion==.In_Place && !actions.states[0].slots[0].finishing)
}

@(test)
action_root_projection_preserves_each_base_and_action_contribution_and_validates_active_metadata :: proc(t:^testing.T) {
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.asset={1,2}
    action_test_spans(&content);defer action_test_spans_free(&content)
    content.roots=make([]asset.Animation_Root,3);defer delete(content.roots);base.text_set(content.roots[0].bone[:],"hip");content.roots[0].translation=true
    actions:=Action_Runtime{allocator=context.allocator};defer actions_runtime_free(&actions)
    profile:=action_test_profile();profile.actions[0].root_motion=.In_Place;profile.actions[0].weight=.5;action_test_layered(&profile,1);profile.actions[1].root_motion=.Extract;base.text_set(profile.actions[1].clip[:],"run")
    action_test_plan(&actions,Action_Plan{profile=profile});action_test_add_state(&actions,Action_State{entity=state.entity,plan=0})
    playback:Playback;defer playback_free(&playback);testing.expect(t,tracks_bind(&playback,&state,&content));events:Animation_Events;defer delete(events.items)
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    cache:Animation_Constraints;defer constraints_free(&cache)
    // An action kept in place blends the reference of the root bone by its weight, one that extracts
    // its clip: over a base kept in place, the base is at the reference.
    for policy in ([?]Root_Motion_Policy{.In_Place,.Extract}) {
        actions.plans[0].profile.actions[0].root_motion=policy;actions.states[0].slots[0]={active=true,starting=true,seeking=true,action=0,section=-1};state.layers={}
        description:=ANIMATION_DEFAULT;description.asset=state.asset;state.clip=0
        state.root={bone=bone_ref("hip"),translation=true,in_place=true} if policy==.Extract else {}
        stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.25,nil,&content,&playback,&events,nil,1);layers_advance(&playback,&state,&content,description,&events,.25,nil);actions_layer_finish(&actions,&state)
        copy(state.local[:],state.rest[:]);state.local[1].position.x=1 if policy==.In_Place else 0
        pose_layers(&playback,&state,&content,description)
        expected:f32=.5 if policy==.In_Place else .125
        testing.expectf(t,state.layers[0].root_motion==policy && abs(state.local[1].position.x-expected)<1e-5,"%v: %v",policy,state.local[1].position)
        actions.states[0].slots[0].finishing=true
        description=ANIMATION_DEFAULT;description.asset=state.asset;stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.01,nil,&content,&playback,&events,nil,1)
        testing.expect(t,state.layers[0].root_motion==policy,"a finishing action keeps its policy")
    }
    // The stack has one root bone: an action whose clip moves another than the base is stopped.
    state.layers={};actions.states[0].slots={};actions.states[0].slots[0]={active=true,starting=true,seeking=true,action=0,section=-1};actions.states[0].slots[1]={active=true,starting=true,seeking=true,action=1,section=-1}
    content.roots[2]=content.roots[0];base.text_set(content.roots[2].bone[:],"spine")
    state.root={bone=bone_ref("hip"),translation=true}
    problems:core.Problems
    description:=ANIMATION_DEFAULT;description.asset=state.asset;stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.1,&problems,&content,&playback,&events,nil,1)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,state.entity,"animation.action_clip")!=nil && !actions.states[0].slots[0].finishing && actions.states[0].slots[1].finishing)
}

@(test)
actions_preserve_the_previous_asset_state_when_appending_a_replacement_plan_fails_and_retry :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4};core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
    cache:Character_Assets;defer character_assets_free(&cache)
    profiles:=[2]Action_Profile{action_test_profile(),action_test_profile()};defer for &value in profiles {action_profile_free(&value)}
    test_character_seed(&cache,{3,4},action_test_set(profiles[0]));test_character_seed(&cache,{5,6},action_test_set(profiles[1]))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    test_character_register(&host_assets,{3,4},{5,6});defer test_registry_free(&host_assets)
    playback:Playback;defer playback_free(&playback);requests:Animation_Requests;defer delete(requests.plays.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
    events:Animation_Events;defer delete(events.items)
    play(&requests,entity,"attack");if !testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)) {return}
    previous:=actions.states[0].slots;previous_plan:=actions.plans[0]
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=100};failing:=runtime.Allocator{procedure=runtime_failure_allocator,data=&failure}
    limited:=make([dynamic]Action_Plan,1,1,failing);limited[0]=actions.plans[0];delete(actions.plans);actions.plans=limited
    core.free(&w.descriptions,entity).asset={5,6};failure.remaining,failure.calls=2,0;app.allocator=failing
    problems:core.Problems
    prepared:=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,&problems)
    app.allocator=failure.owner;actions.allocator=failure.owner
    testing.expect(t,prepared && failure.calls==3 && core.problem_find(&problems,entity,"animation.memory")!=nil && len(actions.plans)==1 && len(actions.states)==1)
    testing.expect(t,actions.states[0].plan==0 && actions.states[0].slots==previous && actions.states[0].seen==actions.frame && actions.plans[0].asset==previous_plan.asset && actions.plans[0].revision==previous_plan.revision && raw_data(actions.plans[0].profile.actions)==raw_data(previous_plan.profile.actions) && len(events.items)==0)
    failure.remaining=100
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil))
    // The action asked had not played yet: it ends without telling.
    testing.expect(t,len(actions.plans)==2 && actions.plans[1].asset==base.Asset_Id{5,6} && actions.states[0].plan==1 && actions.states[0].slots[0].finishing && len(events.items)==0)
}

@(test)
a_new_actions_asset_or_revision_interrupts_the_playing_action_and_fades_its_layer_out :: proc(t:^testing.T) {
    for change in ([2]string{"another asset","a new revision"}) {
        w:Actions_World
        if !core.test_world_init(t,&w,test_types) {return}
        defer core.test_world_destroy(&w)
        entity:=core.create(&w.entities)
        description:=ANIMATION_DEFAULT;description.asset={3,4};core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
        cache:Character_Assets;defer character_assets_free(&cache)
        profiles:=[2]Action_Profile{action_test_profile(),action_test_profile()};defer for &value in profiles {action_profile_free(&value)}
        test_character_seed(&cache,{3,4},action_test_set(profiles[0]));test_character_seed(&cache,{5,6},action_test_set(profiles[1]))
        host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
        test_character_register(&host_assets,{3,4},{5,6});defer test_registry_free(&host_assets)
        content:host.Content_Animation;defer lib.library_destroy(&content.lib)
        playback:Playback;defer playback_free(&playback)
        append(&playback.states,layer_fixture(t,&content));resize(&playback.rows,core.entity_index(entity)+1);playback.rows[core.entity_index(entity)]=1
        action_test_spans(&content);defer action_test_spans_free(&content)
        state:=&playback.states[0];state.entity,state.asset=entity,content.id
        events:Animation_Events;defer delete(events.items)
        requests:Animation_Requests;defer delete(requests.plays.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
        tick :: proc(actions:^Action_Runtime,requests:^Animation_Requests,cache:^Character_Assets,descriptions:^core.Table(Animation),playback:^Playback,app:^host.App,content:^host.Content_Animation,events:^Animation_Events,dt:f32) -> bool {
            if !prepare(actions,requests,cache,descriptions,playback,events,app,nil) {return false}
            state:=&playback.states[0];sampled,_:=core.get(core.read(descriptions),state.entity)
            stack_asks(actions,state,sampled,content)
            actions_sample(actions,state,sampled,dt,nil,content,playback,events,nil,1);layers_advance(playback,state,content,sampled,events,dt,nil);actions_finish(actions,playback,dt)
            return true
        }
        play(&requests,entity,"attack")
        if !testing.expect(t,tick(&actions,&requests,&cache,&w.descriptions,&playback,&app,&content,&events,.1) && state.layers[0].weight==1) {continue}
        if change=="another asset" {core.free(&w.descriptions,entity).asset={5,6}} else {cache.contents[0].revision+=1}
        weights:[dynamic]f32;defer delete(weights)
        interrupted:=0
        for _ in 0..<10 {
            ticked:=tick(&actions,&requests,&cache,&w.descriptions,&playback,&app,&content,&events,.05)
            interrupted+=count(&events,.Interrupted)
            if !testing.expect(t,ticked) || !actions.states[0].slots[0].active {break}
            append(&weights,state.layers[0].weight)
        }
        testing.expectf(t,interrupted==1,"%s interrupts the action once, not %d times",change,interrupted)
        testing.expectf(t,len(weights)>=3 && !actions.states[0].slots[0].active,"%s fades the layer out over fade_out, %v",change,weights[:])
        for weight,i in weights {testing.expectf(t,weight>0 && weight<1 && (i==0 || weight<weights[i-1]),"%s lowers the weight tick by tick, %v",change,weights[:])}
    }
}

@(test)
actions_discover_changed_components_retry_requests_and_compact_generational_rows_through_world_copies :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,plain:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    for entity in ([3]core.Entity{first,second,plain}) {core.add(&w.descriptions,entity,ANIMATION_DEFAULT)}
    core.test_world_settle(&w)
    cache:Character_Assets;defer character_assets_free(&cache)
    profiles:=[2]Action_Profile{action_test_profile(),action_test_profile()};defer for &value in profiles {action_profile_free(&value)}
    test_character_seed(&cache,{3,4},action_test_set(profiles[0]));test_character_seed(&cache,{5,6},action_test_set(profiles[1]))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    test_character_register(&host_assets,{3,4},{5,6});defer test_registry_free(&host_assets)
    playback:Playback;defer playback_free(&playback);requests:Animation_Requests;defer delete(requests.plays.items)
    actions:Action_Runtime;defer actions_runtime_free(&actions)
    events:Animation_Events;defer delete(events.items)
    reserve(&events.items,EVENT_BATCH)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    empty:=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator
    testing.expect(t,empty && len(actions.states)==0 && len(events.items)==0)
    core.edit(&w.descriptions,first).asset={3,4};core.edit(&w.descriptions,second).asset={5,6}
    play(&requests,first,"attack")
    observed:=actions.animations_seen
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator
    testing.expect(t,!prepared && len(requests.plays.items)==1 && len(actions.states)==0 && actions.animations_seen==observed)
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil) && len(actions.states)==2 && action_state(&actions,first).slots[0].active)
    copied:Action_Runtime;core.value_copy(&copied,&actions,type_info_of(Action_Runtime));defer actions_runtime_free(&copied)
    first_state:=action_state(&copied,first);first_state.slots[0].time=9
    testing.expect(t,action_state(&actions,first).slots[0].time!=9)
    core.edit(&w.descriptions,first).asset={5,6}
    core.edit(&w.descriptions,plain).weight=.4
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && actions.plans[action_state(&actions,first).plan].asset==base.Asset_Id{5,6} && len(actions.states)==2)
    core.remove(&w.descriptions,first);core.test_world_settle(&w)
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil) && action_state(&actions,first)==nil && action_state(&actions,second)!=nil && len(actions.states)==1)
    old:=second;index:=core.entity_index(second)
    core.destroy(&w.entities,second);core.test_world_settle(&w)
    second=core.create(&w.entities);core.add(&w.descriptions,second,Animation{asset={3,4}});core.test_world_settle(&w)
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && core.entity_index(second)==index && second!=old && action_state(&actions,old)==nil && action_state(&actions,second)!=nil && len(actions.states)==1)
}

@(test)
actions_retry_a_first_fire_when_profile_preparation_has_no_memory :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4};core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
    profile:=action_test_profile();defer action_profile_free(&profile)
    cache:Character_Assets;defer character_assets_free(&cache);test_character_seed(&cache,{3,4},action_test_set(profile))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator};playback:Playback;defer playback_free(&playback)
    test_character_register(&host_assets,{3,4});defer test_registry_free(&host_assets)
    actions:Action_Runtime;defer actions_runtime_free(&actions);requests:Animation_Requests;defer delete(requests.plays.items)
    events:Animation_Events;defer delete(events.items)
    reserve(&events.items,EVENT_BATCH)
    testing.expect(t,actions_discover(&actions,core.read(&w.descriptions),&playback,&events,&host_assets,nil))
    play(&requests,entity,"attack")
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil)
    context=saved;app.allocator=saved.allocator;actions.allocator=saved.allocator;cache.allocator=saved.allocator
    testing.expect(t,prepared && len(requests.plays.items)==1 && len(actions.plans)==0 && !action_state(&actions,entity).slots[0].active)
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil) && len(requests.plays.items)==0 && action_state(&actions,entity).slots[0].active)
}

@(test)
action_playing_answers_while_an_action_plays_and_a_section_asked_of_it_moves_it_there :: proc(t:^testing.T) {
    w:Actions_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4};core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
    profile:=action_test_profile();defer action_profile_free(&profile)
    cache:Character_Assets;defer character_assets_free(&cache);test_character_seed(&cache,{3,4},action_test_set(profile))
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator};playback:Playback;defer playback_free(&playback)
    test_character_register(&host_assets,{3,4});defer test_registry_free(&host_assets)
    actions:Action_Runtime;defer actions_runtime_free(&actions);requests:Animation_Requests;defer delete(requests.plays.items)
    events:Animation_Events;defer delete(events.items)
    content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.entity,state.asset=entity,content.id
    action_test_spans(&content);defer action_test_spans_free(&content)
    // What plays tells what it does and where it is in the sample of the tick.
    sample :: proc(actions:^Action_Runtime,state:^Playing,description:Animation,content:^host.Content_Animation,playback:^Playback,events:^Animation_Events) {stack_asks(actions,state,description,content);actions_sample(actions,state,description,0,nil,content,playback,events,nil,1)}
    problems:core.Problems
    _,_,playing:=action_playing({&actions},entity,"attack");testing.expect(t,!playing)
    play(&requests,entity,"attack")
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,&problems))
    sample(&actions,&state,description,&content,&playback,&events)
    time,section,ok:=action_playing({&actions},entity,"attack")
    testing.expect(t,problems.count==0 && ok && time==0 && section==base.name_hash("windup"))
    _,_,playing=action_playing({&actions},entity,"interrupt");testing.expect(t,!playing)
    _,_,playing=action_playing({&actions},core.NONE,"attack");testing.expect(t,!playing)
    // A section asked of it while it plays moves it there, and does not start it again.
    play(&requests,entity,"attack","recover")
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,&problems))
    sample(&actions,&state,description,&content,&playback,&events)
    time,section,ok=action_playing({&actions},entity,"attack");testing.expect(t,ok && time==1 && section==base.name_hash("recover"))
    testing.expect(t,count(&events,.Section)==1 && count(&events,.Started)==0 && count(&events,.Interrupted)==0 && events.items[0].name==base.name_hash("recover"))
    play(&requests,entity,"attack","missing")
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,&problems) && core.problem_find(&problems,entity,"animation.action_section")!=nil && len(events.items)==0)
    // Stopped, it fades out and no longer plays.
    stop(&requests,entity,"attack")
    testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,&problems))
    _,_,playing=action_playing({&actions},entity,"attack");testing.expect(t,!playing && actions.states[0].slots[0].finishing && count(&events,.Interrupted)==1)
}

@(test)
a_world_action_plays_at_its_speed_while_its_entity_is_slowed :: proc(t:^testing.T) {
    for clock in Action_Clock {
        w:Actions_World
        if !core.test_world_init(t,&w,test_types) {return}
        defer core.test_world_destroy(&w)
        entity:=core.create(&w.entities)
        description:=ANIMATION_DEFAULT;description.asset={3,4};description.loop=false;core.add(&w.descriptions,entity,description);core.test_world_settle(&w)
        content:host.Content_Animation;state:=layer_fixture(t,&content);defer lib.library_destroy(&content.lib);defer playing_free(&state);state.entity=entity;state.asset=content.id
        action_test_spans(&content);defer action_test_spans_free(&content)
        profile:=action_test_profile();defer action_profile_free(&profile);profile.actions[0].clock=clock
        cache:Character_Assets;defer character_assets_free(&cache)
        test_character_seed(&cache,description.asset,action_test_set(profile))
        host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
        test_character_register(&host_assets,description.asset);defer test_registry_free(&host_assets)
        playback:Playback;defer playback_free(&playback);events:Animation_Events;defer delete(events.items)
        requests:Animation_Requests;defer delete(requests.plays.items);actions:Action_Runtime;defer actions_runtime_free(&actions)
        play(&requests,entity,"attack")
        testing.expect(t,prepare(&actions,&requests,&cache,&w.descriptions,&playback,&events,&app,nil))
        // A tick of 0.2 s of the world while the entity runs at half pace: 0.1 s of its own time.
        stack_asks(&actions,&state,description,&content);actions_sample(&actions,&state,description,.1,nil,&content,&playback,&events,nil,.5)
        want:=f32(.2) if clock==.World else .1
        testing.expectf(t,abs(actions.states[0].slots[0].time-want)<1e-5,"%v: the action is at %v s of its clip, want %v",clock,actions.states[0].slots[0].time,want)
        layers_advance(&playback,&state,&content,description,&events,.1,nil);actions_layer_finish(&actions,&state)
        testing.expectf(t,abs(state.layers[0].fader.current.time-want)<1e-5,"%v: the pose is at %v s of its clip, want %v",clock,state.layers[0].fader.current.time,want)
    }
}
