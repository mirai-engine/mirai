package anim

import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// A set with every part: locomotion, a layer that samples a space of four clips, an action with a
// section, warping with a window and grounding, over the clips of animation {3,4}.
@(private)
character_test_set :: proc() -> Character_Set {
    space:=Blend_Info{dimension=.Two,x={min=-100,max=100},y={min=0,max=10}}
    base.text_set(space.name[:],"aim");base.text_set(space.x.name[:],"Direction");base.text_set(space.y.name[:],"Speed")
    samples:=make([]Blend_Sample,4)
    samples[0].position={-100,0};samples[1].position={100,0};samples[2].position={100,10};samples[3].position={-100,10}
    for &sample,i in samples {sample.speed=1;base.text_set(sample.clip[:],fmt.tprintf("clip%d",i))}
    clips:=make([]Match_Source,1);base.text_set(clips[0].clip[:],"walk");clips[0].loop=true;clips[0].modes=1
    layers:=make([]Stack_Layer,1);layers[0]=STACK_LAYER_DEFAULT;base.text_set(layers[0].name[:],"Aim");base.text_set(layers[0].space[:],"aim");layers[0].mode=.Additive
    actions:=make([]Action_Definition,1);actions[0]=ACTION_DEFINITION_DEFAULT;base.text_set(actions[0].name[:],"Wave");base.text_set(actions[0].clip[:],"wave")
    sections:=make([]Action_Section,1);sections[0]={action=0,next=-1};base.text_set(sections[0].name[:],"Hello")
    windows:=make([]Motion_Window,1);windows[0]=MOTION_WINDOW_DEFAULT;base.text_set(windows[0].name[:],"Reach")
    grounding:=make([]Foot_Grounding,1);grounding[0]=FOOT_GROUNDING_DEFAULT;grounding[0].count=2
    spaces:=make([]Blend_Info,1);spaces[0]=space
    return {info={animation={3,4}},match={info=MATCH_INFO_DEFAULT,clips=clips},actions={layers=layers,actions=actions,sections=sections},spaces=spaces,space_samples=samples,motion={warp=POSE_WARP_PROFILE_DEFAULT,windows=windows},pose={grounding=grounding}}
}
@(private)
character_test_free :: proc(set:^Character_Set) {
    delete(set.match.clips);delete(set.actions.layers);delete(set.actions.actions);delete(set.actions.sections)
    delete(set.spaces);delete(set.space_samples);delete(set.motion.windows);delete(set.pose.grounding)
}

@(test)
character_roundtrips_every_part_and_rejects_invalid_references_and_ranges :: proc(t:^testing.T) {
    set:=character_test_set();defer character_test_free(&set)
    testing.expect(t,character_check(set))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document
    if !testing.expect_value(t,character_document(&doc,&types,{1,2},set),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    if !testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None) {return}
    bytes:=serial.writer_bytes(&writer)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None) {return};defer asset.asset_close(&file)
    view,read:=character_view(&file,&types)
    if !testing.expect_value(t,read,asset.Error.None) {return}
    testing.expect_value(t,view.info,set.info);testing.expect_value(t,view.match.info,set.match.info)
    testing.expect(t,len(view.match.clips)==1 && view.match.clips[0]==set.match.clips[0])
    testing.expect(t,len(view.actions.layers)==1 && view.actions.layers[0]==set.actions.layers[0] && view.actions.sections[0]==set.actions.sections[0])
    testing.expect(t,len(view.spaces)==1 && view.spaces[0]==set.spaces[0] && len(view.space_samples)==4)
    testing.expect(t,len(view.motion.windows)==1 && view.motion.windows[0]==set.motion.windows[0] && len(view.pose.grounding)==1)
    Case :: struct {name:string,change:proc(set:^Character_Set)}
    cases:=[]Case{
        {"a layer that names a space the set lacks",proc(set:^Character_Set) {set.actions.layers[0].space={}; base.text_set(set.actions.layers[0].space[:],"missing")}},
        {"a section of an action the set lacks",proc(set:^Character_Set) {set.actions.sections[0].action=7}},
        {"an axis without range",proc(set:^Character_Set) {set.spaces[0].x.max=set.spaces[0].x.min}},
        {"a sample outside its axes",proc(set:^Character_Set) {set.space_samples[0].position.x= -101}},
        {"a sample of a space the set lacks",proc(set:^Character_Set) {set.space_samples[3].space=2}},
        {"a clip without animation",proc(set:^Character_Set) {set.info.animation={}}},
        {"two warp windows of one name",proc(set:^Character_Set) {two:=make([]Motion_Window,2,context.temp_allocator);two[0],two[1]=set.motion.windows[0],set.motion.windows[0];set.motion.windows=two}},
        {"a stride range upside down",proc(set:^Character_Set) {set.motion.warp.min_stride=3}},
    }
    for c in cases {
        changed:=character_test_set();defer character_test_free(&changed)
        windows:=changed.motion.windows
        c.change(&changed)
        testing.expectf(t,!character_check(changed),"%s is accepted",c.name)
        changed.motion.windows=windows
    }
    // A set that names no clip needs no animation: the modifiers of a rope.
    testing.expect(t,character_check({match={info=MATCH_INFO_DEFAULT},motion={warp=POSE_WARP_PROFILE_DEFAULT},pose={grounding=set.pose.grounding}}))
    for length in 0..<len(bytes) {
        damaged:asset.Asset
        if asset.asset_open(&damaged,bytes[:length])==.None {character_view(&damaged,&types);asset.asset_close(&damaged)}
    }
}

@(test)
character_content_samples_its_spaces_without_allocations_and_reloads_on_change :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"character-content")
    set:=character_test_set();defer character_test_free(&set)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{11,12}
    if !test_character_save(t,directory,"figure",&types,id,set) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    app:=host.App{assets=&assets,allocator=mem.tracking_allocator(&tracker)}
    cache:Character_Assets;defer character_assets_free(&cache)
    content:=character_content(&cache,app.assets,app.allocator,id)
    if !testing.expect(t,content!=nil && len(content.spaces)==1) {return}
    testing.expect_value(t,len(content.spaces[0].space.triangles),2)
    allocations:=tracker.total_allocation_count
    for i in 0..<1000 {
        same:=character_content(&cache,app.assets,app.allocator,id);testing.expect_value(t,same,content)
        weights,ok:=space_sample(same.set.spaces[0],&same.spaces[0],{f32(i%11)*20-100,f32(i%13)})
        sum:f32;for weight in weights.weights[:weights.count] {sum+=weight}
        testing.expect(t,ok && weights.count<=3 && abs(sum-1)<1e-5)
    }
    testing.expect_value(t,tracker.total_allocation_count,allocations)
    record,_:=asset.registry_find(&assets.registry,id)
    revision:=content.revision;record.time+=1;assets.revision+=1
    content=character_content(&cache,app.assets,app.allocator,id)
    testing.expect(t,content!=nil && content.revision==revision+1 && len(cache.contents)==1)
    different:=id;different[0]+=1
    testing.expect(t,character_content(&cache,app.assets,app.allocator,different)==nil)
}

@(test)
character_content_keeps_the_previous_version_when_memory_runs_out :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"character-retry")
    set:=character_test_set();defer character_test_free(&set)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{13,14}
    if !test_character_save(t,directory,"figure",&types,id,set) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=1000}
    app:=host.App{assets=&assets,allocator={runtime_failure_allocator,&failure}}
    record,_:=asset.registry_find(&assets.registry,id)
    failed,succeeded:=false,false
    for budget in 0..<256 {
        cache:Character_Assets
        failure.remaining=1000
        content:=character_content(&cache,app.assets,app.allocator,id)
        if !testing.expect(t,content!=nil) {character_assets_free(&cache);return}
        old_points:=raw_data(content.spaces[0].space.points);old_revision:=content.revision
        record.time+=1;assets.revision+=1;failure.remaining=budget
        content=character_content(&cache,app.assets,app.allocator,id)
        if content==nil {
            failed=true
            testing.expect_value(t,raw_data(cache.contents[0].spaces[0].space.points),old_points)
            testing.expect_value(t,cache.contents[0].revision,old_revision)
        } else {succeeded=true}
        failure.remaining=1000
        testing.expect(t,character_content(&cache,app.assets,app.allocator,id)!=nil)
        character_assets_free(&cache)
        if succeeded {break}
    }
    testing.expect(t,failed && succeeded)
}
