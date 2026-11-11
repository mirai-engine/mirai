package mirai_net

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
random_vitals :: proc(state:^u64) -> Test_Vitals {
    teams:=[3]Test_Team{.None,.Red,.Blue}
    v:=Test_Vitals{
        health=i32(base.splitmix_next(state)%1001),armor=u8(base.splitmix_next(state)),team=teams[base.splitmix_next(state)%3],
        flags=transmute(bit_set[Test_Flag;u8])u8(base.splitmix_next(state)%8),alive=base.splitmix_next(state)%2==0,
        cache=u32(base.splitmix_next(state)),energy=f32(rng_unit(state)*100),raw=f32(rng_unit(state)*1e6-5e5),big=base.splitmix_next(state),
        small=i16(base.splitmix_next(state)%32)-16,
    }
    length:=int(base.splitmix_next(state)%16)
    for i in 0..<length {v.name[i]=u8(97+base.splitmix_next(state)%26)}
    return v
}
@(private)
random_transform :: proc(state:^u64) -> Test_Transform {
    unit :: proc(state:^u64) -> f32 {return f32(rng_unit(state)*2-1)}
    q:=[4]f32{unit(state),unit(state),unit(state),unit(state)+0.01}
    length:=math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3])
    return {
        position={unit(state)*500,unit(state)*50,unit(state)*500},
        rotation=quaternion(w=q[3]/length,x=q[0]/length,y=q[1]/length,z=q[2]/length),
        velocity={unit(state)*20,unit(state)*20,unit(state)*20},
    }
}

@(test)
descriptors_pick_a_serializer_per_field_and_round_trip_whole_and_as_deltas :: proc(t:^testing.T) {
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    p:=&tp.protocol
    actor:=&p.types[tp.actor]
    testing.expect_value(t,actor.fragment_count,3)
    testing.expect_value(t,actor.bit_count,3+11+2)
    testing.expect_value(t,actor.owner,actor.all)
    testing.expect_value(t,actor.others,actor.all&~type_fragment_mask(p,tp.actor,2))
    kinds:=[?]Leaf_Kind{.Quantized,.Quantized,.Quantized,.Quaternion,.Quantized,.Quantized,.Quantized,
        .Offset,.Unsigned,.Enum,.Bit_Set,.Bool,.Object,.Text,.Ranged,.Float,.Unsigned,.Signed,.Unsigned,.Quantized}
    testing.expect_value(t,len(actor.leaves),len(kinds))
    for leaf,i in actor.leaves {testing.expect_value(t,leaf.kind,kinds[i])}
    testing.expect_value(t,actor.leaves[7].bits,u8(10))  // health 0..1000
    testing.expect_value(t,actor.leaves[9].bits,u8(2))   // three teams
    testing.expect_value(t,actor.leaves[10].bits,u8(3))  // three flags
    testing.expect_value(t,actor.leaves[14].bits,u8(10)) // energy 0..100 by 0.1
    testing.expect_value(t,actor.leaves[17].bits,u8(5))
    found,ok:=type_find(p,"Prop")
    testing.expect(t,ok && found==tp.prop)
    _,missing:=type_find(p,"Nothing")
    testing.expect(t,!missing)

    state:=u64(17)
    buffer:[MAX_STATE_BYTES+64]u8
    words,base_words,back:[MAX_STATE_WORDS]u32
    for round in 0..<300 {
        transform,vitals,secret:=random_transform(&state),random_vitals(&state),Test_Secret{ammo=u16(base.splitmix_next(&state)),stamina=f32(rng_unit(&state)*10)}
        fragment_quantize(p,actor,0,&transform,words[:],nil,nil)
        fragment_quantize(p,actor,1,&vitals,words[:],nil,nil)
        fragment_quantize(p,actor,2,&secret,words[:],nil,nil)
        mask:=round%3==0?actor.all:base.splitmix_next(&state)&actor.all
        // Whole, then against a base that shares some leaves with the state.
        for pass in 0..<2 {
            base:[]u32
            if pass==1 {
                other_transform,other_vitals:=random_transform(&state),random_vitals(&state)
                if round%2==0 {other_transform.position=transform.position+{0.05,0,-0.31};other_vitals.health=vitals.health;other_vitals.name=vitals.name}
                copy(base_words[:],words[:])
                fragment_quantize(p,actor,0,&other_transform,base_words[:],nil,nil)
                fragment_quantize(p,actor,1,&other_vitals,base_words[:],nil,nil)
                base=base_words[:actor.words]
            }
            w,m:serial.Bit_Writer
            serial.bit_writer_init(&w,buffer[:]);serial.bit_writer_init_measure(&m)
            mask_write(&w,actor,mask);state_write(&w,actor,mask,words[:actor.words],base)
            mask_write(&m,actor,mask);state_write(&m,actor,mask,words[:actor.words],base)
            testing.expect(t,!w.overflow && serial.bit_writer_bits(&w)==serial.bit_writer_bits(&m) && serial.bit_writer_bits(&w)<=actor.max_bits)
            r:serial.Bit_Reader
            serial.bit_reader_init(&r,serial.bit_writer_flush(&w),serial.bit_writer_bits(&w))
            got,mask_ok:=mask_read(&r,actor)
            testing.expectf(t,mask_ok && got==mask,"mask %x read as %x ok=%v round %v pass %v bits %v",mask,got,mask_ok,round,pass,serial.bit_writer_bits(&w))
            for &word in back {word=0xa5a5a5a5}
            if !state_read(&r,actor,mask,back[:actor.words],base) || serial.bit_reader_remaining(&r)!=0 {testing.expect(t,false,"state does not parse");return}
            if state_diff(actor,words[:actor.words],back[:actor.words],mask)!=0 {testing.expect(t,false,"state differs after the round trip");return}
        }
        out_transform:Test_Transform
        out_vitals:=Test_Vitals{cache=4242}
        fragment_dequantize(p,actor,0,words[:],actor.all,&out_transform,nil,nil)
        fragment_dequantize(p,actor,1,words[:],actor.all,&out_vitals,nil,nil)
        for i in 0..<3 {
            testing.expect(t,abs(out_transform.position[i]-transform.position[i])<=0.0051)
            testing.expect(t,abs(out_transform.velocity[i]-transform.velocity[i])<=0.0251)
        }
        dot:=abs(out_transform.rotation.x*transform.rotation.x+out_transform.rotation.y*transform.rotation.y+out_transform.rotation.z*transform.rotation.z+out_transform.rotation.w*transform.rotation.w)
        testing.expect(t,dot>0.99999)
        expected:=vitals
        expected.cache,expected.target=4242,0
        expected.energy=out_vitals.energy
        testing.expect(t,abs(out_vitals.energy-vitals.energy)<=0.0501)
        if round%2==0 {expected.name[15]=0}
        if out_vitals!=expected {testing.expect(t,false,fmt.tprintf("vitals differ: %v\n%v",out_vitals,expected));return}
    }
}

@(test)
protocols_reject_what_they_cannot_replicate_and_hash_every_choice :: proc(t:^testing.T) {
    Wide :: struct {values:[300]u64}
    Narrow :: struct {a:f32 `mirai:"precision=0.01"`,b:u8}
    Coarse :: struct {a:f32 `mirai:"precision=0.1"`,b:u8}
    Hidden :: struct {a:f32 `mirai:"local"`}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    wide,_:=serial.schema_add(&schema,Wide)
    narrow,_:=serial.schema_add(&schema,Narrow)
    coarse,_:=serial.schema_add(&schema,Coarse)
    hidden,_:=serial.schema_add(&schema,Hidden)
    hash_of :: proc(schema:^serial.Schema,type:serial.Type_Index,name:string,flags:Event_Flags) -> u64 {
        p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
        type_register(&p,name,{{schema=schema,type=type}})
        event_register(&p,"E",schema,type,flags)
        hash,_:=protocol_seal(&p)
        return hash
    }
    p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
    _,too_wide:=type_register(&p,"Wide",{{schema=&schema,type=wide}})
    _,nothing:=type_register(&p,"Hidden",{{schema=&schema,type=hidden}})
    _,no_fragments:=type_register(&p,"Empty",{})
    testing.expect(t,!too_wide && !nothing && !no_fragments)
    testing.expect_value(t,len(p.leaves),0)
    id,ok:=type_register(&p,"Narrow",{{schema=&schema,type=narrow}})
    testing.expect(t,ok && id==0)
    protocol_seal(&p)
    _,late:=type_register(&p,"Late",{{schema=&schema,type=narrow}})
    testing.expect(t,!late)
    reference:=hash_of(&schema,narrow,"T",{})
    testing.expect_value(t,hash_of(&schema,narrow,"T",{}),reference)
    testing.expect(t,hash_of(&schema,coarse,"T",{})!=reference)
    testing.expect(t,hash_of(&schema,narrow,"U",{})!=reference)
    testing.expect(t,hash_of(&schema,narrow,"T",{.Reliable})!=reference)
    unsealed:Protocol;protocol_init(&unsealed);defer protocol_destroy(&unsealed)
    host:Host
    testing.expect_value(t,host_init(&host,{mode=.Server,protocol=&unsealed,transport={nil,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {return true},proc(data:rawptr,buffer:[]u8) -> (int,Address,bool) {return 0,{},false}}}),Error.Invalid)
}

@(private)
Scene :: struct {
    tp:Test_Protocol,
    w:Test_World,
    server:^Host,
    clients:[8]^Host,
    on_server,on_client:[8]Connection,
    count:int,
}
@(private)
scene_init :: proc(s:^Scene,clients:int,replication:Replication_Desc={},seed:u64=1) {
    test_protocol_init(&s.tp)
    test_world_init(&s.w,9,seed)
    replication:=replication
    if replication.max_objects==0 {replication.max_objects=256}
    s.server=test_host(&s.w,{mode=.Server,protocol=&s.tp.protocol,replication=replication,max_connections=8})
    for i in 0..<clients {scene_join(s)}
}
@(private)
scene_join :: proc(s:^Scene) -> int {
    i:=s.count
    replication:=s.server.desc.replication
    replication.state_words,replication.baseline_words=0,0
    s.clients[i]=test_host(&s.w,{mode=.Client,protocol=&s.tp.protocol,replication=replication})
    s.on_server[i],s.on_client[i]=test_connect(&s.w,s.server,s.clients[i])
    s.count+=1
    return i
}
@(private)
scene_destroy :: proc(s:^Scene) {
    test_world_destroy(&s.w)
    test_protocol_destroy(&s.tp)
}
// One tick of every host; commands of the server are dropped, the clients' are given to visit.
@(private)
scene_tick :: proc(s:^Scene,tick:^u32,visit:proc(client:int,command:^Command,user:rawptr)=nil,user:rawptr=nil) {
    tick^+=1
    host_publish(s.server,tick^)
    for client in s.clients[:s.count] {host_publish(client,tick^)}
    test_step(&s.w)
    host_poll(s.server)
    for client,i in s.clients[:s.count] {
        for &command in host_poll(client) {
            if visit!=nil {visit(i,&command,user)}
        }
    }
}

@(test)
objects_reach_clients_with_their_state_and_follow_changes_until_destroyed :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2);defer scene_destroy(s)
    transform:=Test_Transform{position={1,2,3},rotation=quaternion(w=1,x=0,y=0,z=0)}
    vitals:=Test_Vitals{health=77,team=.Blue,alive=true}
    copy(vitals.name[:],"mirai")
    secret:=Test_Secret{ammo=30,stamina=4.5}
    actor,error:=object_create(s.server,{type=s.tp.actor,user=500,sources={0=&transform,1=&vitals,2=&secret},owner=s.on_server[0]})
    testing.expect_value(t,error,Error.None)
    testing.expect(t,object_valid(s.server,actor) && object_user(s.server,actor)==500 && object_of_user(s.server,500)==actor)
    testing.expect_value(t,object_type(s.server,actor),s.tp.actor)

    Seen :: struct {t:^testing.T,s:^Scene,created,updated,destroyed:[2]int,transform:[2]Test_Transform,vitals:[2]Test_Vitals,secret:[2]Test_Secret,role:[2]Role,last:[2]Object,mask:[2]u64}
    seen:=Seen{t=t,s=s}
    visit :: proc(client:int,command:^Command,user:rawptr) {
        seen:=(^Seen)(user)
        #partial switch command.kind {
        case .Object_Created,.Object_Updated:
            if command.kind==.Object_Created {seen.created[client]+=1;seen.role[client]=command.role} else {seen.updated[client]+=1}
            seen.last[client],seen.mask[client]=command.object,command.mask
            testing.expect(seen.t,object_read(seen.s.clients[client],command,0,&seen.transform[client]))
            if command.type!=seen.s.tp.actor {return}
            testing.expect(seen.t,object_read(seen.s.clients[client],command,1,&seen.vitals[client]))
            testing.expect(seen.t,object_read(seen.s.clients[client],command,2,&seen.secret[client]))
        case .Object_Destroyed:
            seen.destroyed[client]+=1
        }
    }
    tick:=u32(0)
    for _ in 0..<20 {scene_tick(s,&tick,visit,&seen)}
    for client in 0..<2 {
        testing.expect_value(t,seen.created[client],1)
        testing.expect_value(t,seen.last[client],actor)
        testing.expect_value(t,seen.transform[client].position,[3]f32{1,2,3})
        testing.expect_value(t,seen.vitals[client].health,i32(77))
        testing.expect_value(t,seen.vitals[client].team,Test_Team.Blue)
        testing.expect_value(t,string(cstring(&seen.vitals[client].name[0])),"mirai")
        testing.expect(t,object_valid(s.clients[client],actor))
    }
    testing.expect_value(t,seen.role,[2]Role{.Predicted,.Shown})
    testing.expect_value(t,object_role(s.clients[0],actor),Role.Predicted)
    testing.expect_value(t,seen.secret[0],Test_Secret{ammo=30,stamina=4.5})
    testing.expect_value(t,seen.secret[1],Test_Secret{})

    // Nothing is sent while nothing changes; a change sends only its field.
    quiet:=seen.updated
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.updated,quiet)
    vitals.health=12
    secret.ammo=29
    testing.expect_value(t,object_mark_dirty(s.server,actor),Error.None)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.updated,[2]int{quiet[0]+1,quiet[1]+1})
    testing.expect_value(t,seen.vitals[1].health,i32(12))
    testing.expect_value(t,seen.secret[0].ammo,u16(29))
    testing.expect_value(t,seen.mask[1],u64(1)<<3)
    testing.expect_value(t,seen.mask[0],u64(1)<<3|u64(1)<<14)
    testing.expect(t,test_replica_matches(s.server,s.clients[0],actor,true) && test_replica_matches(s.server,s.clients[1],actor,false))

    // object_write needs no stored pointer; an unmarked change is not seen.
    transform.position.x=50
    for _ in 0..<5 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.transform[1].position.x,f32(1))
    moved:=Test_Transform{position={9,8,7},rotation=quaternion(w=1,x=0,y=0,z=0)}
    testing.expect_value(t,object_write(s.server,actor,0,&moved),Error.None)
    for _ in 0..<5 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.transform[1].position,[3]f32{9,8,7})

    // The slot is reused, with another generation, once every client let go of it.
    testing.expect_value(t,object_destroy(s.server,actor),Error.None)
    testing.expect(t,!object_valid(s.server,actor))
    testing.expect_value(t,object_mark_dirty(s.server,actor),Error.Invalid)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.destroyed,[2]int{1,1})
    testing.expect(t,!object_valid(s.clients[0],actor))
    again,_:=object_create(s.server,{type=s.tp.prop,sources={0=&moved}})
    testing.expect(t,again!=actor)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    testing.expect_value(t,seen.created,[2]int{2,2})
    testing.expect_value(t,seen.last[0],again)
    testing.expect(t,type_stats(s.server,s.tp.actor).creates==2 && type_stats(s.server,s.tp.actor).destroys==2 && type_stats(s.server,s.tp.actor).bits>0)
    testing.expect_value(t,type_stats(s.server,s.tp.prop).creates,u64(2))
    stats,_:=connection_stats(s.server,s.on_server[0])
    testing.expect(t,stats.objects_in_scope==1 && stats.objects_sent>=5 && stats.object_bytes_sent>0)
}

@(test)
a_client_composes_the_type_of_a_creation_from_its_fragments :: proc(t:^testing.T) {
    ends:=new([2]Test_Protocol);defer free(ends)
    for &end in ends {test_protocol_init(&end)}
    defer for &end in ends {test_protocol_destroy(&end)}
    w:=new(Test_World);defer free(w)
    test_world_init(w,2);defer test_world_destroy(w)
    server:=test_host(w,{mode=.Server,protocol=&ends[0].protocol,replication={max_objects=16},max_connections=1})
    client:=test_host(w,{mode=.Client,protocol=&ends[1].protocol,replication={max_objects=16}})
    test_connect(w,server,client)
    // Vitals before the transform: a list neither end registered.
    actor:=type_kinds(&ends[0].protocol,ends[0].actor)
    composed,ok:=type_compose(&ends[0].protocol,{actor[1],actor[0]})
    if !testing.expect(t,ok) {return}
    again,_:=type_compose(&ends[0].protocol,{actor[1],actor[0]})
    testing.expect_value(t,again,composed)
    vitals:=Test_Vitals{health=5,team=.Blue,alive=true}
    transform:=Test_Transform{position={4,5,6},rotation=quaternion(w=1,x=0,y=0,z=0)}
    _,error:=object_create(server,{type=composed,user=9,sources={0=&vitals,1=&transform}})
    testing.expect_value(t,error,Error.None)
    known:=type_count(&ends[1].protocol)
    seen_vitals:Test_Vitals
    seen_transform:Test_Transform
    created:=false
    tick:=u32(0)
    for _ in 0..<20 {
        tick+=1
        host_publish(server,tick);host_publish(client,tick)
        test_step(w)
        host_poll(server)
        for &command in host_poll(client) {
            if command.kind!=.Object_Created {continue}
            created=true
            testing.expect(t,slice_equal(type_kinds(&ends[1].protocol,command.type),[]Fragment_Id{actor[1],actor[0]}))
            testing.expect(t,object_read(client,&command,0,&seen_vitals) && object_read(client,&command,1,&seen_transform))
        }
    }
    testing.expect(t,created)
    testing.expect_value(t,type_count(&ends[1].protocol),known+1)
    testing.expect_value(t,seen_vitals.health,i32(5))
    testing.expect_value(t,seen_transform.position,[3]f32{4,5,6})
}

@(private="file")
slice_equal :: proc(a,b:[]Fragment_Id) -> bool {
    if len(a)!=len(b) {return false}
    for value,i in a {if value!=b[i] {return false}}
    return true
}

@(test)
object_capacity_and_misuse_are_errors_not_crashes :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=4});defer scene_destroy(s)
    transform:Test_Transform
    objects:[4]Object
    for &object in objects {
        error:Error
        object,error=object_create(s.server,{type=s.tp.prop,sources={0=&transform}})
        testing.expect_value(t,error,Error.None)
    }
    _,full:=object_create(s.server,{type=s.tp.prop})
    testing.expect_value(t,full,Error.Full)
    _,bad_type:=object_create(s.server,{type=99})
    testing.expect_value(t,bad_type,Error.Invalid)
    _,on_client:=object_create(s.clients[0],{type=s.tp.prop})
    testing.expect_value(t,on_client,Error.Invalid)
    testing.expect_value(t,object_write(s.server,objects[0],3,&transform),Error.Invalid)
    testing.expect_value(t,object_set_source(s.server,objects[0],1,&transform),Error.Invalid)
    testing.expect_value(t,object_set_owner(s.server,0,0),Error.Invalid)
    testing.expect_value(t,authority_grant(s.server,objects[0],s.on_server[0]),Error.Invalid)
    testing.expect_value(t,event_send(s.server,99,0,&transform),Error.Invalid)
    testing.expect_value(t,input_submit(s.server,1,&transform),Error.Invalid)
    tick:=u32(0)
    for _ in 0..<10 {scene_tick(s,&tick)}
    testing.expect_value(t,object_write(s.clients[0],objects[0],0,&transform),Error.Invalid)
    testing.expect_value(t,object_destroy(s.server,objects[1]),Error.None)
    _,still_full:=object_create(s.server,{type=s.tp.prop})
    testing.expect_value(t,still_full,Error.Full)
    for _ in 0..<10 {scene_tick(s,&tick)}
    _,freed:=object_create(s.server,{type=s.tp.prop})
    testing.expect_value(t,freed,Error.None)
}

// The client stops updating for longer than 32 datagrams of the server and
// then reads them all: their fate as the server learns it is the one the
// client gave them, so nothing it took is created again or closes the link.
@(test)
a_client_that_stalls_past_the_acknowledgement_window_keeps_its_replicas :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1);defer scene_destroy(s)
    Seen :: struct {created,destroyed:[8]int,closed:bool}
    seen:Seen
    visit :: proc(client:int,command:^Command,user:rawptr) {
        seen:=(^Seen)(user)
        #partial switch command.kind {
        case .Object_Created:   seen.created[base.handle_index(base.Handle(command.object))]+=1
        case .Object_Destroyed: seen.destroyed[base.handle_index(base.Handle(command.object))]+=1
        case .Disconnected:     seen.closed=true
        }
    }
    transforms:[8]Test_Transform
    objects:[8]Object
    for i in 0..<4 {
        transforms[i]={position={f32(i),0,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
        objects[i],_=object_create(s.server,{type=s.tp.prop,sources={0=&transforms[i]}})
    }
    tick:=u32(0)
    for _ in 0..<30 {scene_tick(s,&tick,visit,&seen)}
    for step in 0..<60 {
        tick+=1
        if step==20 {
            for i in 4..<8 {
                transforms[i]={position={f32(i),1,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
                objects[i],_=object_create(s.server,{type=s.tp.prop,sources={0=&transforms[i]}})
            }
        }
        for i in 0..<8 {
            if objects[i]==0 {continue}
            transforms[i].position.y+=0.25
            object_write(s.server,objects[i],0,&transforms[i])
        }
        host_publish(s.server,tick)
        s.w.now+=TEST_STEP
        sim_network_advance(&s.w.sim,s.w.now)
        host_update(s.server,s.w.now)
        host_poll(s.server)
    }
    stats,_:=connection_stats(s.server,s.on_server[0])
    for _ in 0..<60 {scene_tick(s,&tick,visit,&seen)}
    testing.expect(t,!seen.closed,"the connection stays")
    for object,i in objects {
        index:=base.handle_index(base.Handle(object))
        testing.expect_value(t,seen.created[index],1)
        testing.expect_value(t,seen.destroyed[index],0)
        testing.expect(t,test_replica_matches(s.server,s.clients[0],object,false))
    }
    testing.expect(t,stats.packets_sent>=60,"the server kept sending while the client was stalled")
}

// An object that changes type keeps its replica on every connection: no end
// sees it destroyed, what the client bound it to stays, and its words and
// baselines are those of the new type, also when the creations are lost.
@(test)
an_object_retyped_keeps_its_replica_and_takes_the_fragments_of_its_new_type :: proc(t:^testing.T) {
    Seen :: struct {destroyed,retyped,created:int}
    visit :: proc(client:int,command:^Command,user:rawptr) {
        seen:=(^Seen)(user)
        #partial switch command.kind {
        case .Object_Destroyed: seen.destroyed+=1
        case .Object_Created:   if command.retyped {seen.retyped+=1} else {seen.created+=1}
        }
    }
    harsh:=Sim_Conditions{latency=0.05,jitter=0.02,loss=0.3,duplicate=0.1,reorder=0.2,reorder_delay=0.04}
    for conditions,index in ([]Sim_Conditions{{},harsh}) {
        s:=new(Scene);defer free(s)
        scene_init(s,2,{max_objects=16},seed=u64(40+index));defer scene_destroy(s)
        transforms:[4]Test_Transform
        vitals:[4]Test_Vitals
        secrets:[4]Test_Secret
        objects:[4]Object
        actor:[4]bool
        for &object,i in objects {
            transforms[i]={position={f32(i),0,0},rotation=quaternion(w=1,x=0,y=0,z=0)}
            error:Error
            object,error=object_create(s.server,{type=s.tp.prop,sources={0=&transforms[i]},poll=true,owner=i==0?s.on_server[0]:0})
            testing.expect_value(t,error,Error.None)
        }
        seen:Seen
        tick:=u32(0)
        for _ in 0..<40 {scene_tick(s,&tick,visit,&seen)}
        testing.expect_value(t,seen.created,8)
        for object in objects {testing.expect_value(t,object_bind(s.clients[0],object,u64(object)+100),Error.None)}
        for endpoint in 0..=2 {sim_endpoint_conditions(&s.w.sim,endpoint,conditions)}
        state:=u64(9+index)
        unsound:=0
        for step in 0..<400 {
            i:=int(base.splitmix_next(&state)%4)
            transforms[i].position.x+=1
            vitals[i].health=i32(base.splitmix_next(&state)%1000)
            secrets[i].ammo+=1
            if step%7==0 {
                k:=int(base.splitmix_next(&state)%4)
                sources:[MAX_FRAGMENTS]rawptr
                sources[0]=&transforms[k]
                if !actor[k] {sources[1],sources[2]=&vitals[k],&secrets[k]}
                if object_retype(s.server,objects[k],actor[k]?s.tp.prop:s.tp.actor,sources)==.None {actor[k]=!actor[k]}
            }
            scene_tick(s,&tick,visit,&seen)
            unsound+=int(!test_baselines_counted(s.server))
            for client,k in s.clients[:s.count] {unsound+=int(!test_baselines_match(s.server,client,s.on_server[k]))}
        }
        for endpoint in 0..=2 {sim_endpoint_conditions(&s.w.sim,endpoint,{})}
        for _ in 0..<200 {scene_tick(s,&tick,visit,&seen)}
        testing.expectf(t,unsound==0,"conditions %d: %d ticks with a baseline of another type or miscounted",index,unsound)
        testing.expectf(t,seen.destroyed==0 && seen.created==8 && seen.retyped>0,"conditions %d: %d replicas destroyed, %d created and %d retyped",index,seen.destroyed,seen.created,seen.retyped)
        for object,i in objects {
            testing.expect_value(t,object_type(s.server,object),actor[i]?s.tp.actor:s.tp.prop)
            for client,k in s.clients[:s.count] {
                testing.expectf(t,test_replica_matches(s.server,client,object,i==0 && k==0),"conditions %d: client %d differs on object %d",index,k,i)
            }
            testing.expect_value(t,object_user(s.clients[0],object),u64(object)+100)
        }
        testing.expect(t,s.server.back.repl.state_failures==0)
        testing.expect_value(t,host_stats(s.server).connections,2)
    }
    // Hostile: what is not an object of this server, or not a type.
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=4});defer scene_destroy(s)
    transform:Test_Transform
    object,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform}})
    testing.expect_value(t,object_retype(s.server,Object(12345),s.tp.actor,{}),Error.Invalid)
    testing.expect_value(t,object_retype(s.server,object,Type_Id(200),{}),Error.Invalid)
    testing.expect_value(t,object_retype(s.clients[0],object,s.tp.actor,{}),Error.Invalid)
    testing.expect_value(t,object_retype(s.server,object,s.tp.prop,{}),Error.None)
}

// A reliable event larger than a datagram streams on its channel and arrives
// whole, also over a link that loses datagrams, and one that large that is
// not reliable is refused as it registers. Event bytes that do not parse are
// refused, at every length, without crashing the host nor reaching the game.
@(test)
a_reliable_event_of_4_kb_arrives_whole_and_hostile_event_bytes_are_refused :: proc(t:^testing.T) {
    {
        schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
        big,_:=serial.schema_add(&schema,Test_Big)
        p:Protocol;protocol_init(&p);defer protocol_destroy(&p)
        _,unreliable:=event_register(&p,"Big",&schema,big,{.From_Client})
        _,reliable:=event_register(&p,"Big",&schema,big,{.Reliable,.From_Client})
        testing.expect(t,!unreliable && reliable,"only a reliable event exceeds a datagram")
    }
    s:Scene;scene_init(&s,1);defer scene_destroy(&s)
    sim_endpoint_conditions(&s.w.sim,1,{loss=0.2})
    value:Test_Big
    for &v,i in value.values {v=u32(i*2654435761)}
    value.count=len(value.values)
    testing.expect_value(t,event_send(s.clients[0],s.tp.big,0,&value),Error.None)
    arrived:=0
    for tick in u32(1)..=600 {
        host_publish(s.clients[0],tick);host_publish(s.server,tick)
        test_step(&s.w)
        host_poll(s.clients[0])
        for &command in host_poll(s.server) {
            if command.kind!=.Event || command.event!=s.tp.big {continue}
            out:Test_Big
            testing.expect(t,event_read(s.server,&command,&out) && out==value && command.connection==s.on_server[0],"the event arrives whole, from its client")
            arrived+=1
        }
        if arrived>0 {break}
    }
    testing.expect_value(t,arrived,1)

    peer:=peer_from(s.server,s.on_server[0])
    if !testing.expect(t,peer!=nil) {return}
    state:=u64(5)
    junk:[RELIABLE_EVENT_MAX_BYTES+64]u8
    refused:=0
    for round in 0..<4000 {
        size:=int(base.splitmix_next(&state)%u64(len(junk)))
        for &b in junk[:size] {b=u8(base.splitmix_next(&state))}
        if size>=4 {
            // An event of the protocol, or just past its ids, with what follows at random.
            w:serial.Bit_Writer
            serial.bit_writer_init(&w,junk[:4])
            serial.bit_write(&w,u64(System_Message.Event),3)
            serial.bit_write(&w,u64(round%(len(s.tp.protocol.events)+1)),16)
        }
        if !repl_message(s.server,peer,CHANNEL_SYSTEM,junk[:size]) {refused+=1}
    }
    for &command in host_poll(s.server) {
        if command.kind==.Event {testing.expect(t,int(command.event)<len(s.tp.protocol.events) && len(command.words)>=s.tp.protocol.events[command.event].desc.words)}
    }
    testing.expectf(t,refused>1000,"%d of 4000 refused",refused)
}
