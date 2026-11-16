package mirai_net

import "core:mem"
import "core:testing"
import "mirai:std/serial"

@(test)
collections_replicate_only_changed_entries_and_preserve_stable_ids :: proc(t:^testing.T) {
    Item :: struct {amount:u32,weight:f32 `mirai:"precision=0.01"`}
    Bag :: struct {revision:u8,contents:Collection(Item,20)}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    index,added:=serial.schema_add(&schema,Bag)
    p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
    type,registered:=type_register(&p,"Bag",{{schema=&schema,type=index}})
    if !testing.expect(t,added && registered) {return}
    protocol_seal(&p)
    desc:=&p.types[type]
    testing.expect_value(t,desc.bit_count,21)
    source:Bag
    for id in 1..=u32(20) {testing.expect_value(t,collection_set(&source.contents,id,{id,f32(id)}),Error.None)}
    testing.expect_value(t,collection_set(&source.contents,21,{}),Error.Full)
    testing.expect_value(t,collection_set(&source.contents,0,{}),Error.Invalid)
    before,after,received:[MAX_STATE_WORDS]u32
    fragment_quantize(&p,desc,0,&source,before[:],nil,nil)
    testing.expect_value(t,collection_set(&source.contents,11,{123,2.5}),Error.None)
    fragment_quantize(&p,desc,0,&source,after[:],nil,nil)
    changed:=state_diff(desc,before[:],after[:],desc.all)
    testing.expect_value(t,changed,u64(1)<<11)
    buffer:[MAX_STATE_BYTES]u8
    writer:serial.Bit_Writer;serial.bit_writer_init(&writer,buffer[:])
    state_write(&writer,desc,changed,after[:],before[:])
    bits:=serial.bit_writer_bits(&writer)
    testing.expect(t,bits<80 && !writer.overflow)
    copy(received[:],before[:])
    reader:serial.Bit_Reader;serial.bit_reader_init(&reader,serial.bit_writer_flush(&writer),bits)
    testing.expect(t,state_read(&reader,desc,changed,received[:],before[:]))
    testing.expect_value(t,state_diff(desc,received[:],after[:],desc.all),u64(0))
    testing.expect(t,collection_remove(&source.contents,11))
    testing.expect_value(t,collection_set(&source.contents,999,{7,0.5}),Error.None)
    fragment_quantize(&p,desc,0,&source,after[:],nil,nil)
    changed=state_diff(desc,received[:],after[:],desc.all)
    testing.expect_value(t,changed,u64(1)<<11)
    decoded:Bag
    fragment_dequantize(&p,desc,0,after[:],desc.all,&decoded,nil,nil)
    testing.expect_value(t,collection_count(&decoded.contents),20)
    item,found:=collection_get(&decoded.contents,999)
    testing.expect(t,found && item.amount==7 && abs(item.weight-0.5)<0.001)
    _,gone:=collection_get(&decoded.contents,11)
    testing.expect(t,!gone && !collection_remove(&decoded.contents,0))
    testing.expect(t,mem.compare_ptrs(&decoded,&source,size_of(Bag))==0)
}

@(test)
large_entry_masks_never_merge_fragments_with_different_audiences :: proc(t:^testing.T) {
    Item :: struct {value:u32}
    Public :: struct {items:[40]Item}
    Private :: struct {items:[40]Item}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    a,_:=serial.schema_add(&schema,Public)
    b,_:=serial.schema_add(&schema,Private)
    p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
    type,ok:=type_register(&p,"Entries",{{schema=&schema,type=a},{schema=&schema,type=b,condition=.Owner}})
    if !testing.expect(t,ok) {return}
    protocol_seal(&p)
    desc:=&p.types[type]
    testing.expect_value(t,desc.bit_count,64)
    testing.expect(t,desc.fragment_bits[0]&desc.fragment_bits[1]==0)
    testing.expect_value(t,desc.others,desc.fragment_bits[0])
    testing.expect_value(t,desc.owner,desc.all)
}

@(test)
collection_insertions_removals_and_slot_reuse_converge_under_loss :: proc(t:^testing.T) {
    Item :: struct {amount:u32}
    Bag :: struct {contents:Collection(Item,16)}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    index,_:=serial.schema_add(&schema,Bag)
    p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
    type,ok:=type_register(&p,"Bag",{{schema=&schema,type=index}})
    if !testing.expect(t,ok) {return}
    protocol_seal(&p)
    w:Test_World;test_world_init(&w,3,seed=29);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,protocol=&p,replication={max_objects=16}})
    clients:[2]^Host
    for &client in clients {
        client=test_host(&w,{mode=.Client,protocol=&p,replication={max_objects=16}})
        on_server,on_client:=test_connect(&w,server,client)
        if !testing.expect(t,on_server!=0 && on_client!=0) {return}
    }
    for endpoint in 0..<3 {sim_endpoint_conditions(&w.sim,endpoint,{latency=0.05,jitter=0.02,loss=0.2,reorder=0.2,duplicate=0.1})}
    source:Bag
    object,_:=object_create(server,{type=type,sources={0=&source}})
    received:[2]Bag
    for tick in 0..<u32(700) {
        if tick<500 {
            id:=tick%16+1
            if tick%5==0 {collection_remove(&source.contents,id)} else {collection_set(&source.contents,id,{amount=tick})}
            object_mark_dirty(server,object)
        }
        host_publish(server,tick)
        test_step(&w)
        host_poll(server)
        for client,i in clients {
            for &command in host_poll(client) {
                if command.kind==.Object_Created || command.kind==.Object_Updated {object_read(client,&command,0,&received[i],p.types[type].all)}
            }
        }
    }
    for &bag in received {testing.expect(t,mem.compare_ptrs(&bag,&source,size_of(Bag))==0)}
}
