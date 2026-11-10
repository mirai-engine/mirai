package anim

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
blend_test_profile :: proc() -> Blend_Profile {
    info:=Blend_Info{animation={3,4},dimension=.Two,x={min=-100,max=100},y={min=0,max=10}}
    base.text_set(info.x.name[:],"Direction");base.text_set(info.y.name[:],"Speed")
    samples:=make([]Blend_Sample,4)
    samples[0].position={-100,0};samples[1].position={100,0};samples[2].position={100,10};samples[3].position={-100,10}
    for &sample,i in samples {sample.speed=1;base.text_set(sample.clip[:],fmt.tprintf("clip%d",i))}
    return {info=info,samples=samples}
}

@(test)
blend_space_assets_roundtrip_cooked_topology_and_reject_invalid_names_and_ranges :: proc(t:^testing.T) {
    profile:=blend_test_profile();defer blend_profile_free(&profile)
    testing.expect_value(t,blend_space_prepare(&profile),asset.Error.None)
    testing.expect(t,blend_space_check(profile))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document
    if !testing.expect_value(t,blend_space_document(&doc,&types,{1,2},profile),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    if !testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None) {return}
    bytes:=serial.writer_bytes(&writer)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None) {return};defer asset.asset_close(&file)
    view,read:=blend_space_view(&file,&types)
    if !testing.expect_value(t,read,asset.Error.None) {return}
    testing.expect_value(t,view.info,profile.info)
    testing.expect_value(t,len(view.samples),4);testing.expect_value(t,len(view.triangles),2)
    for sample,i in view.samples {testing.expect_value(t,sample,profile.samples[i])}
    weights,ok:=blend_sample(view,{0,5})
    testing.expect(t,ok && weights.count<=3)
    sum:f32;for weight in weights.weights[:weights.count] {sum+=weight};testing.expect(t,abs(sum-1)<1e-6)
    profile.info.x.max=profile.info.x.min;testing.expect(t,!blend_space_check(profile));profile.info.x.max=100
    profile.samples[0].clip={};testing.expect(t,!blend_space_check(profile))
    base.text_set(profile.samples[0].clip[:],"idle")
    profile.samples[0].position.x= -101;testing.expect(t,!blend_space_check(profile));profile.samples[0].position.x= -100
    for &byte in profile.info.x.name {byte='x'};testing.expect(t,!blend_space_check(profile))
    for length in 0..<len(bytes) {
        damaged:asset.Asset
        if asset.asset_open(&damaged,bytes[:length])==.None {blend_space_view(&damaged,&types);asset.asset_close(&damaged)}
    }
}

@(test)
blend_space_content_shares_prepared_points_reloads_and_samples_without_allocations :: proc(t:^testing.T) {
    directory:=fmt.tprintf(".mirai/test-blend-content-%d",os.get_pid());os.make_directory_all(directory);defer os.remove(directory)
    path:=fmt.tprintf("%s/space.blend",directory);defer os.remove(path)
    profile:=blend_test_profile();defer blend_profile_free(&profile)
    testing.expect_value(t,blend_space_prepare(&profile),asset.Error.None)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{11,12}
    if !testing.expect_value(t,blend_space_save(path,&types,id,profile),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    app:=host.App{assets=&assets,allocator=mem.tracking_allocator(&tracker)}
    cache:Blend_Assets;defer blend_assets_free(&cache)
    content:=blend_content(&cache,app.assets,app.allocator,id)
    if !testing.expect(t,content!=nil) {return}
    testing.expect_value(t,raw_data(content.space.triangles),raw_data(content.profile.triangles))
    allocations:=tracker.total_allocation_count
    for i in 0..<1000 {
        same:=blend_content(&cache,app.assets,app.allocator,id);testing.expect_value(t,same,content)
        weights,ok:=blend_content_sample(same,{f32(i%11)*20-100,f32(i%13)})
        testing.expect(t,ok && weights.count<=3)
    }
    testing.expect_value(t,tracker.total_allocation_count,allocations)
    record,_:=asset.registry_find(&assets.registry,id)
    revision:=content.revision;record.time+=1;assets.revision+=1
    content=blend_content(&cache,app.assets,app.allocator,id)
    testing.expect(t,content!=nil && content.revision==revision+1 && len(cache.contents)==1)
    different:=id;different[0]+=1
    testing.expect(t,blend_content(&cache,app.assets,app.allocator,different)==nil)
    profile.info.x.min,profile.info.x.max=0,1e-20
    profile.samples[0].position.x,profile.samples[3].position.x=0,0
    profile.samples[1].position.x,profile.samples[2].position.x=1e-20,1e-20
    testing.expect_value(t,blend_space_prepare(&profile),asset.Error.None)
    weights,ok:=blend_sample(profile,{max(f32),5});testing.expect(t,ok && weights.count<=3)
}

@(test)
blend_space_content_retries_allocation_failures_without_losing_the_previous_version :: proc(t:^testing.T) {
    directory:=fmt.tprintf(".mirai/test-blend-retry-%d",os.get_pid());os.make_directory_all(directory);defer os.remove(directory)
    path:=fmt.tprintf("%s/space.blend",directory);defer os.remove(path)
    profile:=blend_test_profile();defer blend_profile_free(&profile)
    testing.expect_value(t,blend_space_prepare(&profile),asset.Error.None)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{13,14}
    if !testing.expect_value(t,blend_space_save(path,&types,id,profile),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return};defer host.assets_destroy(&assets)
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=1000}
    app:=host.App{assets=&assets,allocator={runtime_failure_allocator,&failure}}
    record,_:=asset.registry_find(&assets.registry,id)
    success:=false
    for budget in 0..<256 {
        cache:Blend_Assets
        failure.remaining=1000
        content:=blend_content(&cache,app.assets,app.allocator,id)
        if !testing.expect(t,content!=nil) {blend_assets_free(&cache);return}
        old_points:=raw_data(content.space.points);old_revision:=content.revision
        record.time+=1;assets.revision+=1;failure.remaining=budget
        content=blend_content(&cache,app.assets,app.allocator,id)
        if content==nil {
            testing.expect_value(t,raw_data(cache.contents[0].space.points),old_points)
            testing.expect_value(t,cache.contents[0].revision,old_revision)
        } else {success=true}
        failure.remaining=1000
        testing.expect(t,blend_content(&cache,app.assets,app.allocator,id)!=nil)
        blend_assets_free(&cache)
        if success {break}
    }
    testing.expect(t,success)
    for budget in 0..<5 {
        cache:Blend_Assets;failure.remaining=budget
        blend_content(&cache,app.assets,app.allocator,id)
        failure.remaining=1000
        testing.expect(t,blend_content(&cache,app.assets,app.allocator,id)!=nil)
        testing.expect_value(t,len(cache.contents),1)
        blend_assets_free(&cache)
    }
    failure.remaining=0
    empty:=Blend_Profile{info=profile.info,samples=profile.samples}
    testing.expect_value(t,blend_space_prepare(&empty,app.allocator),asset.Error.Out_Of_Memory)
}
