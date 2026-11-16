package mirai_net

import "core:testing"

// When an object does not fit what is left of an update, the smaller ones behind it fill the rest instead of
// waiting: when the budget of the tick ends, and when the last datagram of the update is full.
@(test)
small_objects_fill_what_an_object_that_does_not_fit_leaves_of_an_update :: proc(t:^testing.T) {
    for full_datagram in ([2]bool{false,true}) {
        tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
        w:Test_World;test_world_init(&w,2,seed=6);defer test_world_destroy(&w)
        // Whole states, so every update of an actor weighs about the same.
        replication:=Replication_Desc{max_objects=64,baseline_interval=-1,budget_bytes=full_datagram?4096:100}
        server:=test_host(&w,{mode=.Server,protocol=&tp.protocol,packets_per_update=1,replication=replication})
        client:=test_host(&w,{mode=.Client,protocol=&tp.protocol,replication=replication})
        on_server,on_client:=test_connect(&w,server,client)
        testing.expect(t,on_server!=0 && on_client!=0)
        HEAVY :: 30
        LIGHT :: 10
        heavy:=full_datagram?HEAVY:2
        transforms:[HEAVY+LIGHT]Test_Transform
        vitals:[HEAVY]Test_Vitals
        secrets:[HEAVY]Test_Secret
        objects:[HEAVY+LIGHT]Object
        state:=u64(3)
        for i in 0..<LIGHT {
            transforms[HEAVY+i]=random_transform(&state)
            objects[HEAVY+i],_=object_create(server,{type=tp.prop,sources={0=&transforms[HEAVY+i]},poll=true})
        }
        for i in 0..<heavy {
            transforms[i],vitals[i]=random_transform(&state),random_vitals(&state)
            objects[i],_=object_create(server,{type=tp.actor,sources={0=&transforms[i],1=&vitals[i],2=&secrets[i]},poll=true,priority=1000})
        }
        Count :: struct {light:int,prop:Type_Id}
        count:=Count{prop=tp.prop}
        tick:=u32(0)
        step :: proc(w:^Test_World,server,client:^Host,tick:^u32,count:^Count) {
            tick^+=1
            host_publish(server,tick^)
            host_publish(client,tick^)
            test_step(w)
            host_poll(server)
            for command in host_poll(client) {
                if command.kind==.Object_Updated && command.type==count.prop {count.light+=1}
            }
        }
        for _ in 0..<60 {step(&w,server,client,&tick,&count)}
        // Every actor changes whole at every tick and outranks the props, which move a little.
        count.light=0
        for _ in 0..<120 {
            for i in 0..<heavy {transforms[i],vitals[i]=random_transform(&state),random_vitals(&state)}
            for i in 0..<LIGHT {transforms[HEAVY+i].position.x+=0.25}
            step(&w,server,client,&tick,&count)
        }
        testing.expectf(t,count.light>=120,"full_datagram %v: %v updates of the small objects in 120 ticks",full_datagram,count.light)
        stats,_:=connection_stats(server,on_server)
        testing.expect(t,stats.budget_starved>0 || full_datagram)
        for _ in 0..<60 {step(&w,server,client,&tick,&count)}
        for object in objects[:heavy] {testing.expect(t,test_replica_matches(server,client,object,false))}
        for object in objects[HEAVY:] {testing.expect(t,test_replica_matches(server,client,object,false))}
    }
}
