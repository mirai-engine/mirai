package mirai_net

import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(test)
worker_threads_carry_replication_over_udp_while_the_simulation_only_queues_and_polls :: proc(t:^testing.T) {
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    server_socket,client_socket:Udp
    if !udp_open(&server_socket,address_loopback(0)) || !udp_open(&client_socket,address_loopback(0)) {
        testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1")
        return
    }
    defer udp_close(&server_socket)
    defer udp_close(&client_socket)
    channels:=[]Channel_Desc{{kind=.Reliable}}
    server,client:=new(Host),new(Host)
    defer {host_destroy(server);host_destroy(client);free(server);free(client)}
    replication:=Replication_Desc{max_objects=64}
    testing.expect_value(t,host_init(server,{mode=.Server,transport=udp_transport(&server_socket),protocol=&tp.protocol,channels=channels,replication=replication,seed=1}),Error.None)
    testing.expect_value(t,host_init(client,{mode=.Client,transport=udp_transport(&client_socket),protocol=&tp.protocol,channels=channels,replication=replication,seed=2}),Error.None)
    testing.expect(t,worker_start(server) && worker_start(client))
    testing.expect(t,!worker_start(server))
    testing.expect(t,!host_update(server,0),"the network half belongs to the worker while it runs")

    transforms:[40]Test_Transform
    objects:[40]Object
    for &transform,i in transforms {
        transform={position={f32(i),0,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
        objects[i],_=object_create(server,{type=tp.prop,sources={0=&transform},poll=true})
    }
    host_connect(client,server_socket.address)
    on_server,on_client:Connection
    seen:[64]f32
    ticks:Test_Ticks
    created,messages,inputs,events,tick,steps:=0,0,0,0,u32(0),0
    text:="del cliente"
    for steps=0;steps<3000;steps+=1 {
        moving:=tick<240
        tick+=1
        for &command in host_poll(server) {
            #partial switch command.kind {
            case .Connected: on_server=command.connection
            case .Message:   messages+=int(string(command.data)==text)
            case .Input:     inputs+=1
            case .Event:     events+=1
            }
        }
        if moving {
            for &transform in transforms {transform.position.z+=0.25}
        }
        host_publish(server,tick)
        for &command in host_poll(client) {
            #partial switch command.kind {
            case .Connected:
                on_client=command.connection
                message_send(client,on_client,0,transmute([]u8)text)
            case .Object_Created,.Object_Updated:
                out:Test_Transform
                object_read(client,&command,0,&out,max(u64))
                seen[base.handle_index(base.Handle(command.object))]=out.position.z
                created+=int(command.kind==.Object_Created)
            }
        }
        if on_client!=0 {
            first,count:=test_ticks(&ticks,client,host_time(client))
            for step in 0..<u32(count) {
                input:=Test_Input{buttons=u8(first+step)}
                input_submit(client,first+step,&input)
                if (first+step)%16==0 {
                    hit:=Test_Hit{damage=1}
                    event_send(client,tp.ping,0,&hit)
                }
                host_publish(client,first+step)
            }
        }
        done:=!moving && created==len(objects)
        for object in objects {done=done && seen[base.handle_index(base.Handle(object))]==60}
        if done && messages==1 && inputs>30 && events>0 {break}
        time.sleep(2*time.Millisecond)
    }
    worker_stop(server)
    worker_stop(client)
    worker_stop(client)
    testing.expectf(t,steps<3000,"created %v messages %v inputs %v events %v",created,messages,inputs,events)
    for object in objects {testing.expect(t,test_replica_matches(server,client,object,false))}
    stats:=host_stats(server)
    testing.expect(t,stats.frames>100 && stats.commands_dropped==0 && stats.operations_dropped==0)
    testing.expect(t,clock_state(client).synced)
    // With the worker gone the same host runs on the caller's thread.
    transforms[0].position.z=61
    for _ in 0..<200 {
        tick+=1
        host_publish(server,tick)
        host_update(server,host_time(server))
        host_update(client,host_time(client))
        host_poll(server);host_poll(client)
        if test_replica_matches(server,client,objects[0],false) && client.back.repl.remote_tick==tick {break}
        time.sleep(time.Millisecond)
    }
    testing.expect(t,test_replica_matches(server,client,objects[0],false))
}

@(test)
damaged_replication_traffic_never_crashes_allocates_or_reaches_other_clients :: proc(t:^testing.T) {
    for security in Security {damaged_replication_traffic(t,security)}
}

@(private="file")
damaged_replication_traffic :: proc(t:^testing.T,security:Security) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator=mem.tracking_allocator(&track)
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=128},seed=77,security=security);defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    state:=u64(12)
    for i in 0..<80 {crowd_spawn(s,c,i,&state,true)}
    for i in 0..<80 {
        if c.owner[i]==0 {object_set_owner(s.server,c.objects[i],0);c.owner[i]=-1}
    }
    tick:=u32(0)
    for _ in 0..<60 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    allocations:=track.total_allocation_count

    // Everything client 0 sends and receives may arrive damaged, with a valid checksum.
    victim:=s.clients[0]
    to_server:=Test_Fuzz{inner=s.server.desc.transport,host=s.server,rng=5,rate=0.04,only=address_memory(1)}
    to_client:=Test_Fuzz{inner=victim.desc.transport,host=victim,rng=6,rate=0.04}
    s.server.desc.transport=test_fuzz_transport(&to_server)
    victim.desc.transport=test_fuzz_transport(&to_client)
    reconnects,client_tick:=0,u32(0)
    for step in 0..<6000 {
        for _ in 0..<10 {
            i:=int(rng_next(&state)%80)
            crowd_mutate(s,c,i,&state)
        }
        tick+=1
        host_publish(s.server,tick)
        for client,k in s.clients[:2] {
            if s.on_client[k]!=0 {
                client_tick+=1
                input:=Test_Input{buttons=u8(client_tick)}
                input_submit(client,client_tick,&input)
                hit:=Test_Hit{damage=i32(step)}
                if step%7==0 {event_send(client,s.tp.ping,0,&hit)}
                if step%11==0 {event_send(client,s.tp.use,c.objects[step%80],&hit)}
            }
            host_publish(client,tick)
        }
        if step%13==0 {
            hit:=Test_Hit{damage=i32(step)}
            event_send(s.server,s.tp.hit,c.objects[step%80],&hit)
        }
        test_step(&s.w)
        host_poll(s.server)
        for client,k in s.clients[:2] {
            for command in host_poll(client) {
                if command.kind==.Connected {s.on_client[k]=command.connection}
                if command.kind==.Disconnected {
                    testing.expect_value(t,k,0)
                    s.on_client[k]=0
                    reconnects+=1
                    host_connect(client,address_memory(0))
                }
            }
        }
    }
    testing.expectf(t,to_server.mutated>100 && to_client.mutated>100 && reconnects>0,"mutated %v %v reconnects %v",to_server.mutated,to_client.mutated,reconnects)
    testing.expect_value(t,track.total_allocation_count,allocations)
    testing.expect(t,s.server.back.repl.state_failures==0 && s.server.back.repl.baseline_failures==0)

    // The damage ends: the victim starts over and both clients agree with the server.
    s.server.desc.transport,victim.desc.transport=to_server.inner,to_client.inner
    host_disconnect(victim)
    for _ in 0..<30 {scene_tick(s,&tick)}
    s.on_server[0],s.on_client[0]=test_connect(&s.w,s.server,victim)
    testing.expect(t,s.on_client[0]!=0)
    for _ in 0..<200 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    testing.expect_value(t,host_stats(s.server).connections,2)
}

// Opt-in: mirai test net server_with_64_clients_and_2000_objects --release -define:NET_BENCHMARK=true
@(test)
server_with_64_clients_and_2000_objects :: proc(t:^testing.T) {
    when #config(NET_BENCHMARK,false) {server_benchmark(t,false,false)}
}
// The same with a round trip of 30 to 120 ms that differs per client.
@(test)
server_with_64_clients_and_2000_objects_with_latency :: proc(t:^testing.T) {
    when #config(NET_BENCHMARK,false) {server_benchmark(t,false,true)}
}
// And with views without an edge: every client sees every object, and the budget decides.
@(test)
server_with_64_clients_and_2000_objects_in_view_of_all :: proc(t:^testing.T) {
    when #config(NET_BENCHMARK,false) {server_benchmark(t,true,true)}
}

@(private="file")
server_benchmark :: proc(t:^testing.T,everywhere,latency:bool) {
    CLIENTS :: 64
    OBJECTS :: 2000
    WORLD :: 800
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    w:=new(Test_World);defer free(w)
    test_world_init(w,CLIENTS+1,seed=3,packets=16384);defer test_world_destroy(w)
    server:=test_host(w,{mode=.Server,protocol=&tp.protocol,max_connections=CLIENTS,send_rate=1<<20,
        replication={max_objects=2048,budget_bytes=1200,cell_size=40,filter_interval=4,object_stats=true}})
    clients:[CLIENTS]^Host
    on_server:[CLIENTS]Connection
    for &client,i in clients {
        client=test_host(w,{mode=.Client,protocol=&tp.protocol,frame_ops=256,frame_bytes=32<<10,replication={max_objects=2048}})
        on_server[i],_=test_connect(w,server,client)
        if on_server[i]==0 {testing.expect(t,false,"a client could not connect");return}
    }
    if latency {
        sim_endpoint_conditions(&w.sim,0,{latency=0.015})
        for i in 0..<CLIENTS {sim_endpoint_conditions(&w.sim,i+1,{latency=0.015+0.09*f64(i)/(CLIENTS-1)})}
    }
    transforms:=make([]Test_Transform,OBJECTS);defer delete(transforms)
    objects:=make([]Object,OBJECTS);defer delete(objects)
    state:=u64(40)
    for &transform,i in transforms {
        transform=random_transform(&state)
        transform.position={f32(rng_unit(&state))*WORLD,0,f32(rng_unit(&state))*WORLD}
        owner:=i<CLIENTS?on_server[i]:0
        objects[i],_=object_create(server,{type=tp.prop,sources={0=&transform},filter=.Spatial,position=transform.position,owner=owner,poll=true})
    }
    Bench :: struct {simulation,publish,network:time.Duration,phases:[4]f64,peak:int}
    frame :: proc(w:^Test_World,server:^Host,clients:[]^Host,on_server:[]Connection,transforms:[]Test_Transform,objects:[]Object,tick:^u32,bench:^Bench,everywhere:bool) {
        tick^+=1
        // Half of the objects walk; the players are among them and take their views along.
        for &transform,i in transforms {
            if i<len(clients) {connection_set_view(server,on_server[i],transform.position,everywhere?-1:80)}
            if i%2!=0 {continue}
            transform.position.x+=transform.velocity.x*0.003
            transform.position.z+=transform.velocity.z*0.003
            if tick^%8==0 {object_set_position(server,objects[i],transform.position)}
        }
        started:=time.tick_now()
        host_poll(server)
        last:=host_stats(server)
        bench.phases+={last.apply_seconds,last.receive_seconds,last.scope_seconds,last.send_seconds}
        publishing:=time.tick_now()
        host_publish(server,tick^)
        bench.publish+=time.tick_since(publishing)
        bench.simulation+=time.tick_since(started)
        w.now+=TEST_STEP
        sim_network_advance(&w.sim,w.now)
        started=time.tick_now()
        host_update(server,w.now)
        bench.network+=time.tick_since(started)
        bench.peak=max(bench.peak,server.back.repl.states.used+server.back.repl.bases.used)
        for client in clients {
            host_publish(client,tick^)
            host_update(client,w.now)
            host_poll(client)
        }
    }
    tick:=u32(0)
    bench:Bench
    for _ in 0..<600 {frame(w,server,clients[:],on_server[:],transforms,objects,&tick,&bench,everywhere)}
    TICKS :: 600
    // Every object read at every publish, then on its turn once every four ticks.
    for interval in ([2]int{1,4}) {
        for object in objects {object_set_poll_interval(server,object,interval)}
        for _ in 0..<60 {frame(w,server,clients[:],on_server[:],transforms,objects,&tick,&bench,everywhere)}
        before:=host_stats(server)
        before_type:=type_stats(server,tp.prop)
        bench={}
        scope,starved:=u64(0),u64(0)
        for _ in 0..<TICKS {frame(w,server,clients[:],on_server[:],transforms,objects,&tick,&bench,everywhere)}
        host_poll(server)
        after:=host_stats(server)
        after_type:=type_stats(server,tp.prop)
        loss:f32
        for connection in on_server {
            stats,_:=connection_stats(server,connection)
            scope+=u64(stats.objects_in_scope)
            starved+=stats.budget_starved
            loss=max(loss,stats.loss)
        }
        bytes:=f64(after.bytes_sent-before.bytes_sent)/TICKS
        phases:=bench.phases
        fmt.printfln("NET_BENCH_MEMORY,poll_interval=%v,everywhere=%v,latency=%v,pool_words_peak=%v,state_words=%v,baseline_words_end=%v,baseline_failures=%v",interval,everywhere,latency,bench.peak,after.state_words_used,after.baseline_words_used,after.baseline_failures)
        fmt.printfln("NET_BENCH_PHASES,poll_interval=%v,publish_ms=%.3f,apply_ms=%.3f,receive_ms=%.3f,scope_ms=%.3f,send_ms=%.3f",interval,time.duration_milliseconds(bench.publish)/TICKS,
            phases[0]*1000/TICKS,phases[1]*1000/TICKS,phases[2]*1000/TICKS,phases[3]*1000/TICKS)
        fmt.printfln("NET_BENCH,poll_interval=%v,clients=%v,objects=%v,ticks=%v,simulation_ms_per_tick=%.3f,network_ms_per_tick=%.3f,bytes_per_tick=%.0f,bytes_per_client_per_second=%.0f,objects_in_scope_per_client=%.1f,updates_per_tick=%.0f,bits_per_update=%.1f,starved_updates=%v",
            interval,CLIENTS,OBJECTS,TICKS,time.duration_milliseconds(bench.simulation)/TICKS,time.duration_milliseconds(bench.network)/TICKS,bytes,bytes*60/CLIENTS,
            f64(scope)/CLIENTS,f64(after_type.updates-before_type.updates)/TICKS,f64(after_type.bits-before_type.bits)/f64(max(after_type.updates-before_type.updates,1)),starved)
        testing.expect(t,after.commands_dropped==0 && after.operations_dropped==0 && loss<0.01)
    }
    // Left alone, every client ends with exactly what the server has for what it sees.
    for _ in 0..<600 {
        tick+=1
        host_publish(server,tick)
        test_step(w)
        host_poll(server)
        for client in clients {host_poll(client)}
    }
    matched,held:=0,0
    for client,k in clients {
        for object in objects {
            index:=int(base.handle_index(base.Handle(object)))
            if client.back.repl.live[index]!=1 {continue}
            held+=1
            matched+=int(test_replica_matches(server,client,object,on_server[k]==server.back.repl.owner[index]))
        }
    }
    testing.expect(t,held>CLIENTS*50)
    testing.expect_value(t,matched,held)
}
