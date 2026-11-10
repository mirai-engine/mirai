package anim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
graph_test_profile :: proc() -> Graph_Profile {
    parameters:=make([]Graph_Parameter,1);base.text_set(parameters[0].name[:],"speed");parameters[0].max=1;parameters[0].value=.25
    nodes:=make([]Graph_Node,5)
    for &node,i in nodes {node=GRAPH_NODE_DEFAULT;base.text_set(node.name[:],fmt.tprintf("node%d",i))}
    nodes[0].kind=.Clip;base.text_set(nodes[0].clip[:],"walk")
    nodes[1].kind=.Clip;base.text_set(nodes[1].clip[:],"run")
    nodes[2].kind=.Blend;nodes[2].left,nodes[2].right,nodes[2].weight_param=0,1,0
    nodes[3].kind=.Blend_Space;nodes[3].blend_space={8,9};nodes[3].x_param=0
    nodes[4].kind=.Additive;nodes[4].left,nodes[4].right=2,3
    return {info={animation={3,4},output=2},parameters=parameters,nodes=nodes}
}

@(test)
graph_assets_roundtrip_dependencies_and_reject_cyclic_or_unbounded_compositions :: proc(t:^testing.T) {
    profile:=graph_test_profile();defer graph_profile_free(&profile)
    testing.expect(t,graph_check(profile))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;if !testing.expect_value(t,graph_document(&doc,&types,{1,2},profile),asset.Error.None) {return};defer asset.document_destroy(&doc)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    if !testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None) {return};defer asset.asset_close(&file)
    view,read:=graph_view(&file,&types)
    if !testing.expect_value(t,read,asset.Error.None) {return}
    testing.expect_value(t,view.info,profile.info);testing.expect_value(t,view.parameters[0],profile.parameters[0])
    testing.expect_value(t,view.nodes[4],profile.nodes[4]);testing.expect_value(t,len(file.dependencies),2)
    dependency_clip,dependency_blend:=false,false
    for id in file.dependencies {dependency_clip ||=id==profile.info.animation;dependency_blend ||=id==profile.nodes[3].blend_space}
    testing.expect(t,dependency_clip && dependency_blend)
    profile.nodes[2].left=2;testing.expect(t,!graph_check(profile));profile.nodes[2].left=0
    profile.nodes[2].right=3;testing.expect(t,!graph_check(profile));profile.nodes[2].right=1
    profile.nodes[2].weight_param=1;testing.expect(t,!graph_check(profile));profile.nodes[2].weight_param=0
    profile.parameters[0].value=2;testing.expect(t,!graph_check(profile));profile.parameters[0].value=.25
    Space_Case :: struct {kind:Graph_Node_Kind,left,right,output:u16,nodes:int,why:string}
    spaces:=[?]Space_Case{
        {.Blend,2,3,2,5,"a blend space blended by weight"},
        {.Layer,2,3,2,5,"a blend space layered over a pose"},
        {.Additive,3,2,2,5,"a blend space as the base of an additive"},
        {.Additive,2,3,3,5,"a blend space as the output"},
        {.Additive,2,3,2,4,"a blend space no additive uses"},
    }
    for c in spaces {
        varied:=profile;nodes:=[5]Graph_Node{};copy(nodes[:],profile.nodes)
        nodes[4].kind,nodes[4].left,nodes[4].right=c.kind,c.left,c.right
        varied.nodes,varied.info.output=nodes[:c.nodes],c.output
        testing.expectf(t,!graph_check(varied) && !graph_spaces_additive(varied),"%s is refused",c.why)
    }
    testing.expect(t,graph_check(profile))
    for length in 0..<writer.count {
        damaged:asset.Asset
        if asset.asset_open(&damaged,serial.writer_bytes(&writer)[:length])==.None {graph_view(&damaged,&types);asset.asset_close(&damaged)}
    }
    nodes:=[6]Graph_Node{}
    for &node,i in nodes {node=GRAPH_NODE_DEFAULT;base.text_set(node.name[:],fmt.tprintf("n%d",i));if i==0 {node.kind=.Clip;base.text_set(node.clip[:],"walk")} else {node.kind=.Blend;node.left,node.right=u16(i-1),u16(i-1)}}
    bounded:=Graph_Profile{info={animation={1,2},output=4},nodes=nodes[:5]}
    testing.expect(t,graph_check(bounded));bounded.nodes=nodes[:];bounded.info.output=5;testing.expect(t,graph_check(bounded))
    for &node,i in nodes {if i>0 {node.kind=.Layer;node.left=u16(i-1);node.right=0}}
    bounded.nodes,bounded.info.output=nodes[:4],3;testing.expect(t,graph_check(bounded));bounded.nodes,bounded.info.output=nodes[:5],4;testing.expect(t,graph_check(bounded))
    too_many:=[GRAPH_NODES+1]Graph_Node{}
    for &node,i in too_many {node=GRAPH_NODE_DEFAULT;base.text_set(node.name[:],fmt.tprintf("many%d",i));node.kind=.Clip;base.text_set(node.clip[:],"walk")}
    bounded.nodes,bounded.info.output=too_many[:],0
    invalid:asset.Document
    testing.expect_value(t,graph_document(&invalid,&types,{5,6},bounded),asset.Error.Invalid);testing.expect_value(t,len(invalid.tables),0)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    rejected:asset.Document
    error:=graph_document(&rejected,&types,{5,6},profile,context.allocator)
    context=saved
    testing.expect_value(t,error,asset.Error.Out_Of_Memory);testing.expect_value(t,len(rejected.tables),0)
}

@(test)
graph_content_reloads_shared_definitions_and_retries_every_allocation_failure :: proc(t:^testing.T) {
    directory:=fmt.tprintf(".mirai/test-graph-cache-%d",os.get_pid());os.make_directory_all(directory);defer os.remove_all(directory)
    path:=fmt.tprintf("%s/graph.agraph",directory)
    profile:=graph_test_profile();defer graph_profile_free(&profile)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{31,32}
    if !testing.expect_value(t,graph_save(path,&types,id,profile),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory,capacity=8})) {return};defer host.assets_destroy(&assets)
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=1000}
    app:=host.App{assets=&assets,allocator={runtime_failure_allocator,&failure}}
    record,_:=asset.registry_find(&assets.registry,id)
    success:=false
    for budget in 0..<256 {
        cache:Graph_Assets
        failure.remaining=1000
        content:=graph_content(&cache,app.assets,app.allocator,id)
        if !testing.expect(t,content!=nil) {graph_assets_free(&cache);return}
        old_nodes,old_revision:=raw_data(content.profile.nodes),content.revision
        record.time+=1;assets.revision+=1;failure.remaining=budget
        content=graph_content(&cache,app.assets,app.allocator,id)
        if content==nil {
            testing.expect_value(t,raw_data(cache.contents[0].profile.nodes),old_nodes)
            testing.expect_value(t,cache.contents[0].revision,old_revision)
        } else {success=true;testing.expect_value(t,content.revision,old_revision+1)}
        failure.remaining=1000
        content=graph_content(&cache,app.assets,app.allocator,id)
        testing.expect(t,content!=nil && len(cache.contents)==1)
        graph_assets_free(&cache)
        if success {break}
    }
    testing.expect(t,success)
    cache:Graph_Assets;defer graph_assets_free(&cache)
    failure.remaining=1000
    content:=graph_content(&cache,app.assets,app.allocator,id);if !testing.expect(t,content!=nil) {return}
    calls:=failure.calls;failure.remaining=0
    for _ in 0..<100 {testing.expect_value(t,graph_content(&cache,app.assets,app.allocator,id),content)}
    testing.expect_value(t,failure.calls,calls)
    failure.remaining=1000
    missing:=id;missing[0]+=1;testing.expect(t,graph_content(&cache,app.assets,app.allocator,missing)==nil)
    profile.parameters[0].value=.8
    testing.expect_value(t,graph_save(path,&types,id,profile),asset.Error.None)
    host.assets_scan(&assets)
    assets.revision+=1
    content=graph_content(&cache,app.assets,app.allocator,id)
    testing.expect(t,content!=nil && content.profile.parameters[0].value==.8)
    testing.expect(t,graph_parameter_index(content.profile,"speed")==0 && graph_parameter_index(content.profile,"missing")== -1)
}
