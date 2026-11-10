package mirai_net

import "core:testing"
import "mirai:std/base"

@(test)
a_pool_of_words_reuses_holes_and_slides_its_blocks_down_instead_of_fragmenting :: proc(t:^testing.T) {
    pool:Word_Pool
    pool.words=make([]u32,64);defer delete(pool.words)
    pool.at=make([]u32,16);defer delete(pool.at)
    pool.size=make([]u16,16);defer delete(pool.size)
    fill :: proc(pool:^Word_Pool,id:int) {for &word,i in pool_words(pool,id) {word=u32(id*100+i)}}
    intact :: proc(pool:^Word_Pool,id:int) -> bool {
        for word,i in pool_words(pool,id) {
            if word!=u32(id*100+i) {return false}
        }
        return true
    }
    // Blocks of 3 and 5 words, each with its header, fill the 64 words.
    for id in 0..<10 {
        testing.expect(t,pool_alloc(&pool,id,id%2==0?3:5))
        fill(&pool,id)
    }
    testing.expect(t,pool_alloc(&pool,10,13))
    fill(&pool,10)
    testing.expect_value(t,pool.used,64)
    testing.expect(t,!pool_alloc(&pool,11,1))
    for id:=0;id<10;id+=2 {pool_free(&pool,id)}
    testing.expect_value(t,pool.used,44)
    // A block of a freed size takes a hole; a larger one finds the holes together at the top.
    testing.expect(t,pool_alloc(&pool,11,3))
    fill(&pool,11)
    testing.expect_value(t,pool.top,64)
    testing.expect(t,pool_alloc(&pool,12,11))
    fill(&pool,12)
    testing.expect_value(t,pool.used,60)
    testing.expect_value(t,pool.top,60)
    for id in ([?]int{1,3,5,7,9,10,11,12}) {testing.expectf(t,intact(&pool,id),"block %v moved without its words",id)}
    testing.expect(t,!pool_alloc(&pool,13,4))
    testing.expect(t,!pool_alloc(&pool,12,1),"an id holds one block")
    // Freeing the last block lowers the top.
    pool_free(&pool,12)
    testing.expect_value(t,pool.top,48)
    testing.expect(t,pool_alloc(&pool,13,4))
    testing.expect(t,!pool_has(&pool,12) && pool_has(&pool,13))
}

// The states of destroyed objects give their words back whatever their size, and object_create refuses an object
// whose state does not fit instead of leaving it without one.
@(test)
object_create_refuses_what_state_words_cannot_hold_and_any_type_takes_the_room_others_left :: proc(t:^testing.T) {
    sizes:Test_Protocol;test_protocol_init(&sizes)
    prop_words,actor_words:=sizes.protocol.types[sizes.prop].words,sizes.protocol.types[sizes.actor].words
    test_protocol_destroy(&sizes)
    PROPS :: 12
    room:=PROPS*(prop_words+1)
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=64,state_words=room});defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    state:=u64(2)
    for i in 0..<PROPS {
        c.transforms[i]=random_transform(&state)
        error:Error
        c.objects[i],error=object_create(s.server,{type=s.tp.prop,sources={0=&c.transforms[i]},poll=true})
        testing.expect_value(t,error,Error.None)
        c.owner[i]=-1
    }
    _,full:=object_create(s.server,{type=s.tp.prop,sources={0=&c.transforms[0]}})
    testing.expect_value(t,full,Error.Full)
    tick:=u32(0)
    for _ in 0..<20 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    for &object in c.objects[:PROPS] {
        object_destroy(s.server,object)
        object=0
    }
    for _ in 0..<20 {scene_tick(s,&tick)}
    actors:=room/(actor_words+1)
    testing.expect(t,actors>=2)
    for i in 0..<actors {
        c.owner[i]=-1
        c.transforms[i],c.vitals[i]=random_transform(&state),random_vitals(&state)
        error:Error
        c.objects[i],error=object_create(s.server,{type=s.tp.actor,sources={0=&c.transforms[i],1=&c.vitals[i],2=&c.secrets[i]},poll=true})
        testing.expect_value(t,error,Error.None)
    }
    _,still_full:=object_create(s.server,{type=s.tp.actor,sources={0=&c.transforms[0],1=&c.vitals[0],2=&c.secrets[0]}})
    testing.expect_value(t,still_full,Error.Full)
    for _ in 0..<30 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    stats:=host_stats(s.server)
    testing.expect_value(t,stats.state_failures,u64(0))
    testing.expect_value(t,stats.state_words_used,actors*(actor_words+1))
}

// Without room for baselines the updates go whole: the replicas still match, and host_stats says why.
@(test)
without_room_for_baselines_updates_go_whole_and_host_stats_counts_it :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=64,baseline_words=1});defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    state:=u64(11)
    for i in 0..<20 {crowd_spawn(s,c,i,&state,true)}
    tick:=u32(0)
    for _ in 0..<120 {
        for _ in 0..<5 {crowd_mutate(s,c,int(base.splitmix_next(&state)%20),&state)}
        scene_tick(s,&tick)
    }
    for _ in 0..<60 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    stats:=host_stats(s.server)
    testing.expect(t,stats.baseline_failures>0)
    testing.expect_value(t,stats.baseline_words_used,0)
    testing.expect_value(t,stats.state_failures,u64(0))
}

// Well past eight connections, each one with its own round trip, the default room holds every baseline: the
// connections that take one in the same state share it.
@(test)
connections_well_past_eight_take_every_baseline_they_ask_for_within_the_default_room :: proc(t:^testing.T) {
    CLIENTS :: 48
    OBJECTS :: 100
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    w:=new(Test_World);defer free(w)
    test_world_init(w,CLIENTS+1,seed=4,packets=16384);defer test_world_destroy(w)
    server:=test_host(w,{mode=.Server,protocol=&tp.protocol,max_connections=CLIENTS,replication={max_objects=OBJECTS}})
    clients:[CLIENTS]^Host
    on_server:[CLIENTS]Connection
    for &client,i in clients {
        client=test_host(w,{mode=.Client,protocol=&tp.protocol,replication={max_objects=OBJECTS}})
        on_server[i],_=test_connect(w,server,client)
        if on_server[i]==0 {testing.expect(t,false,"a client could not connect");return}
    }
    sim_endpoint_conditions(&w.sim,0,{latency=0.01})
    for i in 0..<CLIENTS {sim_endpoint_conditions(&w.sim,i+1,{latency=0.01+0.0015*f64(i)})}
    transforms:=new([OBJECTS]Test_Transform);defer free(transforms)
    vitals:=new([OBJECTS]Test_Vitals);defer free(vitals)
    secrets:=new([OBJECTS]Test_Secret);defer free(secrets)
    objects:[OBJECTS]Object
    state:=u64(9)
    for i in 0..<OBJECTS {
        transforms[i],vitals[i]=random_transform(&state),random_vitals(&state)
        objects[i],_=object_create(server,{type=tp.actor,sources={0=&transforms[i],1=&vitals[i],2=&secrets[i]},poll=true})
    }
    tick:=u32(0)
    unsound:=0
    for step in 0..<420 {
        if step<300 {
            for i in 0..<OBJECTS {transforms[i].position.x+=0.05}
            for _ in 0..<10 {vitals[base.splitmix_next(&state)%OBJECTS].health=i32(base.splitmix_next(&state)%1001)}
        }
        tick+=1
        host_publish(server,tick)
        for client in clients {host_publish(client,tick)}
        test_step(w)
        host_poll(server)
        for client in clients {host_poll(client)}
        if step%20==0 {
            unsound+=int(!test_baselines_counted(server))
            for client,k in clients {unsound+=int(!test_baselines_match(server,client,on_server[k]))}
        }
    }
    testing.expect_value(t,unsound,0)
    for client in clients {
        for object in objects {testing.expect(t,test_replica_matches(server,client,object,false))}
    }
    without:=0
    for &p in server.back.peers {
        for object in objects {
            o:=int(base.handle_index(base.Handle(object)))
            without+=int(p.repl.link[o]==.Created && p.repl.active[o]==0)
        }
    }
    testing.expectf(t,without==0,"%v of %v replicas without a baseline",without,CLIENTS*OBJECTS)
    stats:=host_stats(server)
    testing.expect_value(t,stats.baseline_failures,u64(0))
    // Each connection holds at least its active baseline of every object; shared, they take a fraction of the words.
    words:=tp.protocol.types[tp.actor].words+1
    testing.expectf(t,stats.baseline_words_used<CLIENTS*OBJECTS*words/4,"%v words of baselines",stats.baseline_words_used)
}
