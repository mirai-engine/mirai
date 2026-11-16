package multiplayer_api_test

import "core:testing"
import "mirai:asset"
import multiplayer "plugins:multiplayer/runtime"
import wire "mirai:net"
import "mirai:std/serial"

@(private)
Item :: struct {amount:u32,weight:f32 `mirai:"precision=0.01"`}

@(component,replicated)
Api_Test_Inventory :: struct {items:multiplayer.Collection(Item,3)}

@(test)
public_collections_fit_the_protocol_as_replicated_components_and_serialize_after_slot_reuse :: proc(t:^testing.T) {
    value:Api_Test_Inventory
    testing.expect_value(t,multiplayer.collection_set(&value.items,0,{}),multiplayer.Net_Error.Invalid)
    testing.expect_value(t,multiplayer.collection_set(&value.items,11,{1,.25}),multiplayer.Net_Error.None)
    testing.expect_value(t,multiplayer.collection_set(&value.items,22,{2,.5}),multiplayer.Net_Error.None)
    testing.expect_value(t,multiplayer.collection_set(&value.items,33,{3,.75}),multiplayer.Net_Error.None)
    testing.expect_value(t,multiplayer.collection_count(&value.items),3)
    testing.expect_value(t,multiplayer.collection_set(&value.items,44,{}),multiplayer.Net_Error.Full)
    testing.expect(t,multiplayer.collection_remove(&value.items,22))
    testing.expect(t,!multiplayer.collection_remove(&value.items,0) && !multiplayer.collection_remove(&value.items,22))
    testing.expect_value(t,multiplayer.collection_set(&value.items,44,{4,1}),multiplayer.Net_Error.None)
    testing.expect_value(t,multiplayer.collection_set(&value.items,11,{9,.5}),multiplayer.Net_Error.None)
    item,found:=multiplayer.collection_get(&value.items,11)
    testing.expect(t,found && item==Item{9,.5})
    slot:=multiplayer.Collection_Item(Item){id=55,value={5,1.25}}
    testing.expect(t,slot.id==55 && slot.value.amount==5)
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    protocol:wire.Protocol;wire.protocol_init(&protocol);defer wire.protocol_destroy(&protocol)
    inventory,added:=serial.schema_add(&schema,Api_Test_Inventory)
    testing.expect(t,added,schema.error)
    _,registered:=wire.fragment_register(&protocol,"Api_Test_Inventory",{schema=&schema,type=inventory})
    testing.expect(t,registered)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    document:asset.Document;asset.document_init(&document,asset.fourcc("TEST"),{12,34});defer asset.document_destroy(&document)
    _,written:=asset.document_put_row(&document,&types,"inventory",&value)
    testing.expect_value(t,written,asset.Error.None)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&document,&writer),asset.Error.None)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None)
    defer asset.asset_close(&file)
    loaded,error:=asset.asset_row(&file,&types,"inventory",Api_Test_Inventory)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect_value(t,loaded^,value)
    testing.expect_value(t,multiplayer.collection_count(&loaded.items),3)
    item,found=multiplayer.collection_get(&loaded.items,44)
    testing.expect(t,found && item==Item{4,1})
    _,removed:=multiplayer.collection_get(&loaded.items,22)
    testing.expect(t,!removed)
}
