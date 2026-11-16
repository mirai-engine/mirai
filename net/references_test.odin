package mirai_net

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
references_republish_when_targets_register_and_wait_for_binding_without_resends :: proc(t:^testing.T) {
    Ref :: struct {target:base.Entity}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    index,_:=serial.schema_add(&schema,Ref)
    p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
    type,ok:=type_register(&p,"Reference",{{schema=&schema,type=index}})
    if !testing.expect(t,ok) {return}
    protocol_seal(&p)
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,protocol=&p})
    client:=test_host(&w,{mode=.Client,protocol=&p})
    on_server,on_client:=test_connect(&w,server,client)
    if !testing.expect(t,on_server!=0 && on_client!=0) {return}
    source:=Ref{target=222}
    object,_:=object_create(server,{type=type,user=111,sources={0=&source}})
    for tick in 0..<u32(8) {host_publish(server,tick);test_step(&w);host_poll(server);host_poll(client)}
    target,_:=object_create(server,{type=type,user=222})
    saved:Command
    words:[MAX_STATE_WORDS]u32
    for tick in 8..<u32(30) {
        host_publish(server,tick);test_step(&w);host_poll(server)
        for &command in host_poll(client) {
            if command.kind==.Object_Updated && command.object==object {
                copy(words[:],command.words)
                saved=command
                saved.words=words[:len(command.words)]
            }
        }
    }
    if !testing.expect(t,saved.object==object && object_valid(client,target)) {return}
    testing.expect_value(t,object_references_pending(client,&saved),u64(1))
    out:Ref
    testing.expect(t,object_read(client,&saved,0,&out))
    testing.expect_value(t,out.target,base.Entity(0))
    revision:=object_binding_revision(client)
    testing.expect_value(t,object_bind(client,target,777),Error.None)
    testing.expect(t,object_binding_revision(client)>revision)
    testing.expect_value(t,object_references_pending(client,&saved),u64(0))
    testing.expect(t,object_read(client,&saved,0,&out))
    testing.expect_value(t,out.target,base.Entity(777))
    revision=object_binding_revision(client)
    object_bind(client,target,777)
    testing.expect_value(t,object_binding_revision(client),revision)
    object_destroy(server,target)
    for tick in 30..<u32(50) {
        host_publish(server,tick);test_step(&w);host_poll(server)
        for &command in host_poll(client) {
            if command.kind==.Object_Updated && command.object==object {object_read(client,&command,0,&out)}
        }
    }
    testing.expect_value(t,out.target,base.Entity(0))
    testing.expect_value(t,object_references_pending(client,&saved),u64(1))
}
