package mirai_net

import "core:fmt"
import "core:testing"
import "mirai:std/base"

@(private)
Crowd :: struct {
    transforms:[200]Test_Transform,
    vitals:[200]Test_Vitals,
    secrets:[200]Test_Secret,
    objects:[200]Object,
    owner:[200]int, // client index or -1
    polled:[200]bool,
}
@(private)
crowd_spawn :: proc(s:^Scene,c:^Crowd,i:int,state:^u64,poll:bool) -> Error {
    c.transforms[i],c.vitals[i]=random_transform(state),random_vitals(state)
    c.secrets[i]={ammo=u16(base.splitmix_next(state)),stamina=f32(rng_unit(state)*10)}
    c.owner[i]=int(base.splitmix_next(state)%u64(s.count+1))-1
    c.polled[i]=poll
    error:Error
    c.objects[i],error=object_create(s.server,{type=s.tp.actor,user=u64(1000+i),sources={0=&c.transforms[i],1=&c.vitals[i],2=&c.secrets[i]},
        owner=c.owner[i]>=0?s.on_server[c.owner[i]]:0,poll=poll})
    return error
}
@(private)
crowd_mutate :: proc(s:^Scene,c:^Crowd,i:int,state:^u64) {
    switch base.splitmix_next(state)%5 {
    case 0: c.transforms[i].position+={f32(rng_unit(state)-0.5),0,f32(rng_unit(state)-0.5)}
    case 1: c.transforms[i]=random_transform(state)
    case 2: c.vitals[i].health=i32(base.splitmix_next(state)%1001)
    case 3: c.vitals[i]=random_vitals(state)
    case 4: c.secrets[i].ammo+=1
    }
    if !c.polled[i] {object_mark_dirty(s.server,c.objects[i])}
}
// Every client holds exactly the objects of the server, with the same words.
@(private)
crowd_matches :: proc(t:^testing.T,s:^Scene,c:^Crowd) -> bool {
    alive:=0
    for object in c.objects {
        if object!=0 {alive+=1}
    }
    for client,k in s.clients[:s.count] {
        replicas:=0
        for live in client.back.repl.live {replicas+=int(live)}
        if replicas!=alive {testing.expectf(t,false,"client %v holds %v replicas of %v",k,replicas,alive);return false}
        for object,i in c.objects {
            if object!=0 && !test_replica_matches(s.server,client,object,c.owner[i]==k) {
                testing.expectf(t,false,"client %v differs on object %v",k,i)
                return false
            }
        }
    }
    return true
}

@(test)
replication_converges_under_loss_reordering_and_duplication :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,3,{max_objects=256},seed=21);defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    state:=u64(8)
    for i in 0..<150 {testing.expect_value(t,crowd_spawn(s,c,i,&state,i%2==0),Error.None)}
    harsh:=Sim_Conditions{latency=0.05,jitter=0.02,loss=0.3,duplicate=0.1,reorder=0.2,reorder_delay=0.04}
    for endpoint in 0..=3 {sim_endpoint_conditions(&s.w.sim,endpoint,harsh)}
    tick:=u32(0)
    // Between ticks the shared baselines count their links, and each active one is what its client kept.
    unsound:=0
    for step in 0..<600 {
        for _ in 0..<30 {
            i:=int(base.splitmix_next(&state)%200)
            if c.objects[i]!=0 {crowd_mutate(s,c,i,&state)}
        }
        if step%40==0 {
            for _ in 0..<5 {
                i:=int(base.splitmix_next(&state)%200)
                if c.objects[i]!=0 {
                    object_destroy(s.server,c.objects[i])
                    c.objects[i]=0
                } else {
                    crowd_spawn(s,c,i,&state,i%2==0)
                }
            }
        }
        scene_tick(s,&tick)
        unsound+=int(!test_baselines_counted(s.server))
        for client,k in s.clients[:s.count] {unsound+=int(!test_baselines_match(s.server,client,s.on_server[k]))}
    }
    testing.expect_value(t,unsound,0)
    for _ in 0..<400 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    stats,_:=connection_stats(s.server,s.on_server[0])
    testing.expect(t,stats.loss>0.15 && stats.packets_lost>100 && stats.objects_sent>1000)
    testing.expect_value(t,host_stats(s.server).connections,3)
    testing.expect(t,s.server.back.repl.state_failures==0 && s.server.back.repl.baseline_failures==0)
}

@(test)
a_client_that_rejoins_receives_everything_again :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=256});defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    state:=u64(3)
    for i in 0..<60 {crowd_spawn(s,c,i,&state,true)}
    tick:=u32(0)
    for _ in 0..<60 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    held :: proc(r:^Repl) -> (count:int) {
        for refs in r.base_refs {count+=int(refs)}
        return
    }
    before:=held(&s.server.back.repl)

    host_disconnect(s.clients[1])
    gone:=false
    for _ in 0..<10 {
        tick+=1
        host_publish(s.server,tick)
        test_step(&s.w)
        for command in host_poll(s.server) {gone=gone || (command.kind==.Disconnected && command.connection==s.on_server[1])}
        host_poll(s.clients[0]);host_poll(s.clients[1])
    }
    testing.expect(t,gone)
    for live in s.clients[1].back.repl.live {testing.expect_value(t,live,u8(0))}
    testing.expect(t,!object_valid(s.clients[1],c.objects[0]))
    testing.expect(t,s.clients[1].back.repl.states.used==0 && s.clients[1].back.repl.bases.used==0)
    // The connection that left let go of its baselines.
    testing.expect(t,held(&s.server.back.repl)<before)
    for i in 0..<60 {
        c.owner[i]=c.owner[i]==1?-1:c.owner[i]
        crowd_mutate(s,c,i,&state)
    }
    s.on_server[1],s.on_client[1]=test_connect(&s.w,s.server,s.clients[1])
    testing.expect(t,s.on_server[1]!=0)
    for _ in 0..<90 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    testing.expect(t,object_valid(s.clients[1],c.objects[0]))
}

@(private="file")
measure_moving_props :: proc(t:^testing.T,baseline_interval:int) -> (bytes_per_object_tick:f64) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=256,baseline_interval=baseline_interval,budget_bytes=16<<10});defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    COUNT :: 100
    TICKS :: 300
    state:=u64(4)
    for i in 0..<COUNT {
        c.transforms[i]=random_transform(&state)
        c.objects[i],_=object_create(s.server,{type=s.tp.prop,sources={0=&c.transforms[i]},poll=true})
        c.owner[i]=-1
    }
    tick:=u32(0)
    for _ in 0..<30 {scene_tick(s,&tick)}
    before,_:=connection_stats(s.server,s.on_server[0])
    for _ in 0..<TICKS {
        // Walking pace along x, and a height that stays put.
        for i in 0..<COUNT {c.transforms[i].position.x+=3.0/60}
        scene_tick(s,&tick)
    }
    after,_:=connection_stats(s.server,s.on_server[0])
    for _ in 0..<30 {scene_tick(s,&tick)}
    testing.expect(t,crowd_matches(t,s,c))
    return f64(after.object_bytes_sent-before.object_bytes_sent)/(COUNT*TICKS)
}

@(test)
delta_compression_sends_fewer_bytes_per_object_and_tick :: proc(t:^testing.T) {
    whole:=measure_moving_props(t,-1)
    delta:=measure_moving_props(t,4)
    fmt.printfln("NET_DELTA,whole=%.2f,delta=%.2f,bytes per object and tick",whole,delta)
    testing.expect(t,delta<whole*0.75)
    testing.expect(t,delta<5 && whole>5)
}

@(test)
scope_follows_views_owners_filters_and_parents :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=64,cell_size=10,hysteresis=4,filter_interval=1});defer scene_destroy(s)
    transform:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    line:[10]Object
    for &object,i in line {
        object,_=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Spatial,position={f32(i)*10,0,0}})
    }
    private,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Owner,owner=s.on_server[1]})
    custom,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Custom})
    hidden,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.None})
    child,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},parent=line[9]})
    grandchild,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},parent=child,priority=50})
    _,bad_parent:=object_create(s.server,{type=s.tp.prop,parent=Object(12345)})
    testing.expect_value(t,bad_parent,Error.Invalid)
    connection_set_view(s.server,s.on_server[0],{0,0,0},25)
    object_set_relevance(s.server,custom,s.on_server[0],true)

    Order :: struct {created:[2][64]int,next:[2]int,left,ended:[2]int}
    order:Order
    visit :: proc(client:int,command:^Command,user:rawptr) {
        order:=(^Order)(user)
        if command.kind==.Object_Destroyed {
            if command.ended {order.ended[client]+=1} else {order.left[client]+=1}
        }
        if command.kind==.Object_Created {
            order.next[client]+=1
            order.created[client][base.handle_index(base.Handle(command.object))]=order.next[client]
        }
    }
    has :: proc(s:^Scene,client:int,object:Object) -> bool {return object_valid(s.clients[client],object)}
    tick:=u32(0)
    for _ in 0..<20 {scene_tick(s,&tick,visit,&order)}
    for object,i in line {testing.expect_value(t,has(s,0,object),i<=2)}
    for object in line {testing.expect(t,!has(s,1,object))}
    testing.expect(t,!has(s,0,private) && has(s,1,private))
    testing.expect(t,has(s,0,custom) && !has(s,1,custom))
    testing.expect(t,!has(s,0,hidden) && !has(s,1,hidden))
    testing.expect(t,!has(s,0,child) && !has(s,0,grandchild))
    stats,_:=connection_stats(s.server,s.on_server[0])
    testing.expect_value(t,stats.objects_in_scope,u32(4))

    // The view moves: what it reaches appears at once, what it left lingers for a few evaluations.
    connection_set_view(s.server,s.on_server[0],{80,0,0},25)
    scene_tick(s,&tick,visit,&order)
    scene_tick(s,&tick,visit,&order)
    testing.expect(t,has(s,0,line[0]) && has(s,0,line[2]))
    for _ in 0..<20 {scene_tick(s,&tick,visit,&order)}
    for object,i in line {testing.expect_value(t,has(s,0,object),i>=6)}
    // A dependent object arrives after what it depends on, however urgent it is.
    testing.expect(t,has(s,0,child) && has(s,0,grandchild))
    index :: proc(object:Object) -> u32 {return base.handle_index(base.Handle(object))}
    testing.expect(t,order.created[0][index(line[9])]<order.created[0][index(child)])
    testing.expect(t,order.created[0][index(child)]<order.created[0][index(grandchild)])

    // An object that comes back before its replica was destroyed is kept.
    connection_set_view(s.server,s.on_server[0],{0,0,0},25)
    scene_tick(s,&tick,visit,&order)
    connection_set_view(s.server,s.on_server[0],{80,0,0},25)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&order)}
    testing.expect(t,has(s,0,line[8]) && has(s,0,child))
    // Four at first, six with the second view, and the three the first view brought back for a moment.
    testing.expect_value(t,order.next[0],4+6+3)

    // Filters, owners and parents can change afterwards.
    object_set_filter(s.server,private,.Always)
    object_set_filter(s.server,hidden,.Always)
    object_set_owner(s.server,private,s.on_server[0])
    object_set_parent(s.server,child,0)
    object_set_position(s.server,line[0],{80,0,5})
    for _ in 0..<10 {scene_tick(s,&tick,visit,&order)}
    testing.expect(t,has(s,0,private) && has(s,1,private) && has(s,1,hidden))
    testing.expect(t,has(s,1,child) && has(s,1,grandchild) && has(s,0,line[0]))
    testing.expect_value(t,object_role(s.clients[0],private),Role.Predicted)
    testing.expect_value(t,object_role(s.clients[1],private),Role.Shown)
    object_destroy(s.server,line[9])
    object_destroy(s.server,child)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&order)}
    testing.expect(t,!has(s,0,line[9]) && !has(s,0,child) && !has(s,0,grandchild) && !has(s,1,grandchild))
    // A replica says why it ends: its object is gone, or it only left the view.
    // The grandchild lives on without the parent that brought it into view.
    testing.expect_value(t,order.ended[0],2)
    testing.expect_value(t,order.ended[1],1)
    testing.expect_value(t,order.left[0],3+3+1)

    // What is seen stays seen within a tenth of the reach beyond the edge, and leaves past it.
    left:=order.left[0]
    connection_set_view(s.server,s.on_server[0],{86,0,0},25)
    for _ in 0..<20 {scene_tick(s,&tick,visit,&order)}
    testing.expect(t,has(s,0,line[6]),"26 m away with a view of 25 m and it was seen: it stays")
    connection_set_view(s.server,s.on_server[0],{114,0,0},25)
    for _ in 0..<20 {scene_tick(s,&tick,visit,&order)}
    testing.expect(t,!has(s,0,line[8]),"26 m away and it was never seen: it does not appear")
    connection_set_view(s.server,s.on_server[0],{89,0,0},25)
    for _ in 0..<20 {scene_tick(s,&tick,visit,&order)}
    testing.expect(t,!has(s,0,line[6]) && has(s,0,line[7]) && has(s,0,line[8]))
    testing.expect(t,order.left[0]>left)
    // A view without an edge reaches every spatial object, wherever it is.
    connection_set_view(s.server,s.on_server[1],{},-1)
    for _ in 0..<20 {scene_tick(s,&tick,visit,&order)}
    for object in line[:9] {testing.expect(t,has(s,1,object))}
    testing.expect(t,!has(s,0,line[1]))
}

@(test)
priority_shares_a_small_budget_without_starving_anyone :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=256,budget_bytes=150});defer scene_destroy(s)
    c:=new(Crowd);defer free(c)
    COUNT :: 120
    state:=u64(6)
    for i in 0..<COUNT {
        c.transforms[i]=random_transform(&state)
        c.objects[i],_=object_create(s.server,{type=s.tp.prop,sources={0=&c.transforms[i]},poll=true,priority=i<10?8:1})
        c.owner[i]=-1
    }
    Counts :: struct {updates:[256]int}
    counts:Counts
    visit :: proc(client:int,command:^Command,user:rawptr) {
        if command.kind==.Object_Updated {(^Counts)(user).updates[base.handle_index(base.Handle(command.object))]+=1}
    }
    tick:=u32(0)
    for _ in 0..<200 {scene_tick(s,&tick,visit,&counts)}
    counts={}
    before,_:=connection_stats(s.server,s.on_server[0])
    TICKS :: 600
    for _ in 0..<TICKS {
        for i in 0..<COUNT {c.transforms[i].position.z+=0.25}
        scene_tick(s,&tick,visit,&counts)
    }
    after,_:=connection_stats(s.server,s.on_server[0])
    per_tick:=f64(after.object_bytes_sent-before.object_bytes_sent)/TICKS
    testing.expect(t,per_tick<=151 && per_tick>120)
    testing.expect(t,after.budget_starved>before.budget_starved)
    urgent,ordinary,least:=0,0,max(int)
    for i in 0..<COUNT {
        n:=counts.updates[base.handle_index(base.Handle(c.objects[i]))]
        if i<10 {urgent+=n} else {ordinary+=n;least=min(least,n)}
    }
    testing.expect(t,least>=10)
    testing.expect(t,f64(urgent)/10>4*f64(ordinary)/(COUNT-10))
    for _ in 0..<400 {scene_tick(s,&tick,visit,&counts)}
    testing.expect(t,crowd_matches(t,s,c))
}

@(test)
dormant_objects_send_nothing_until_woken_and_polled_ones_need_no_marks :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=16});defer scene_destroy(s)
    polled,marked:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)},Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    a,_:=object_create(s.server,{type=s.tp.prop,sources={0=&polled},poll=true})
    b,_:=object_create(s.server,{type=s.tp.prop,sources={0=&marked}})
    Seen :: struct {s:^Scene,position:[2]f32,updates:int}
    seen:=Seen{s=s}
    visit :: proc(client:int,command:^Command,user:rawptr) {
        seen:=(^Seen)(user)
        if command.kind!=.Object_Updated {return}
        out:Test_Transform
        object_read(seen.s.clients[0],command,0,&out)
        seen.position[base.handle_index(base.Handle(command.object))]=out.position.x
        seen.updates+=1
    }
    tick:=u32(0)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    polled.position.x,marked.position.x=5,5
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.position,[2]f32{5,0})
    object_set_dormant(s.server,a,true)
    object_set_dormant(s.server,b,true)
    polled.position.x,marked.position.x=6,6
    object_mark_dirty(s.server,b)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.position,[2]f32{5,0})
    testing.expect_value(t,seen.updates,1)
    object_set_dormant(s.server,a,false)
    object_set_dormant(s.server,b,false)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.position,[2]f32{6,6})
    object_set_poll(s.server,a,false)
    polled.position.x=7
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.position,[2]f32{6,6})
    object_set_poll(s.server,a,true)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.position,[2]f32{7,6})
}

// An update that asks for a baseline is still in flight when the link forgets its baselines (a new
// owner, or a moment out of scope), and the update that asks for the same slot afterwards is lost: the
// acknowledgement of the first must not activate the block of the second, which the receiver never kept.
@(test)
an_old_acknowledgement_never_activates_a_baseline_asked_for_after_the_link_forgot_its_own :: proc(t:^testing.T) {
    for leave_scope in ([2]bool{false,true}) {
        tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
        w:Test_World;test_world_init(&w,2,seed=9);defer test_world_destroy(&w)
        // One object per update, so the departure of the target can wait behind the other one.
        replication:=Replication_Desc{max_objects=16,baseline_interval=1,filter_interval=1,max_updates=1}
        server:=test_host(&w,{mode=.Server,protocol=&tp.protocol,replication=replication})
        client:=test_host(&w,{mode=.Client,protocol=&tp.protocol,replication=replication})
        on_server,on_client:=test_connect(&w,server,client)
        testing.expect(t,on_server!=0 && on_client!=0)
        slow:=Sim_Conditions{latency=0.05}
        sim_endpoint_conditions(&w.sim,0,slow)
        sim_endpoint_conditions(&w.sim,1,slow)
        state:=u64(5)
        target,other:=random_transform(&state),random_transform(&state)
        object,_:=object_create(server,{type=tp.prop,sources={0=&target},poll=true,priority=1000})
        filler,_:=object_create(server,{type=tp.prop,sources={0=&other},poll=true})
        o:=int(base.handle_index(base.Handle(object)))
        p:=peer_from(server,on_server)
        tick:=u32(0)
        step :: proc(w:^Test_World,server,client:^Host,target,other:^Test_Transform,tick:^u32,moving:=true) {
            if moving {target.position.x+=0.25;other.position.z+=0.25}
            tick^+=1
            host_publish(server,tick^)
            host_publish(client,tick^)
            test_step(w)
            host_poll(server)
            host_poll(client)
        }
        // Until an update asks for slot 0 while slot 1 is the active baseline.
        asked:=false
        for _ in 0..<600 {
            ready:=p.repl.link[o]==.Created && p.repl.active[o]==2 && p.repl.pending[o]==0
            step(&w,server,client,&target,&other,&tick)
            if ready && p.repl.pending[o]==1 {asked=true;break}
        }
        testing.expectf(t,asked,"leave_scope %v: no update asked for slot 0",leave_scope)
        // The link forgets its baselines, and the next update, which asks for slot 0 again, is lost.
        if leave_scope {
            object_set_filter(server,object,.None)
            object_set_priority(server,object,0.001)
            step(&w,server,client,&target,&other,&tick)
            testing.expect_value(t,p.repl.link[o],Link.Pending_Destroy)
            object_set_filter(server,object,.Always)
            object_set_priority(server,object,1000)
        } else {
            object_set_owner(server,object,on_server)
        }
        sim_endpoint_conditions(&w.sim,0,{latency=0.05,loss=1})
        step(&w,server,client,&target,&other,&tick)
        sim_endpoint_conditions(&w.sim,0,slow)
        testing.expectf(t,p.repl.link[o]==.Created && p.repl.active[o]==0 && p.repl.pending[o]==1,"leave_scope %v: link %v active %v pending %v",
            leave_scope,p.repl.link[o],p.repl.active[o],p.repl.pending[o])
        unsound:=0
        for i in 0..<150 {
            step(&w,server,client,&target,&other,&tick,moving=i<30)
            unsound+=int(!test_baselines_match(server,client,on_server) || !test_baselines_counted(server))
        }
        testing.expectf(t,unsound==0,"leave_scope %v: %v ticks with a baseline the client did not keep",leave_scope,unsound)
        testing.expectf(t,test_replica_matches(server,client,object,!leave_scope),"leave_scope %v: the replica differs from the server",leave_scope)
        testing.expect(t,test_replica_matches(server,client,filler,false))
    }
}
