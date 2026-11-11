package multiplayer

import "core:testing"
import "mirai:core"
import "mirai:std/base"
import wire "mirai:net"

// A body the server moves steadily, six ticks behind the client and shown
// eleven behind it, comes within reach of what the client drives and leaves
// it again: it turns predicted, then interpolated, and what is drawn of it
// (its Transform and its Draw_Offset) never goes back nor moves more than
// twice its steady step in a tick, while its place jumps half a meter each time.
@(test)
a_replica_changes_between_interpolated_and_predicted_without_a_jump_in_what_is_drawn :: proc(t:^testing.T) {
    f:Correction_Fixture
    defer correction_fixture_destroy(&f)
    if !correction_fixture_init(t,&f,.Shown,{max_objects=8,predicted_capacity=8,replication={history_seconds=0.5}}) {return}
    s:=&f.session
    c:=&s.client
    r:=&c.replicas[1]
    ref:=core.world_ref(&f.world,&f.info)
    SPEED :: f32(3)
    STEP :: SPEED/60
    core.edit(&f.world.values,f.e).force=0
    s.host.front.clock.local=12
    modes:[3]Mode
    seen:=0
    drawn,placed:f32
    largest_jump:f32
    for tick in u32(11)..=200 {
        at:=tick-6
        command:=net_test_pack(s,&f.world,r,at,{id=1,position={SPEED*f32(at)/60,0,0},rotation=1,scale={1,1,1}},{linear={SPEED,0,0}},0,f.words)
        replica_update(s,ref,f.app.assets,&command)
        // From tick 60 to 100 it shares a group of the simulation with what this client drives.
        if tick>=60 && tick<=100 {r.touched,r.touched_set=c.newest,true}
        client_reconcile(s,ref,&f.app,1.0/60)
        correction_fixture_tick(&f,tick)
        client_frame(s,ref,1.0/60)
        if seen==0 || modes[seen-1]!=r.mode {
            if !testing.expect(t,seen<len(modes),"it changed timeline more than twice") {return}
            modes[seen]=r.mode
            seen+=1
        }
        local,_:=core.get(&f.world.transforms,f.e)
        offset,_:=core.get(&f.world.offsets,f.e)
        now:=local.position.x+offset.offset.x
        if tick>40 {
            testing.expectf(t,now-drawn>-1e-4 && now-drawn<2*STEP,"tick %d, %v: drawn %.3f m after %.3f m, and its steady step is %.3f m",tick,r.mode,now,drawn,STEP)
            largest_jump=max(largest_jump,abs(local.position.x-placed-STEP))
        }
        drawn,placed=now,local.position.x
    }
    testing.expect_value(t,modes,[3]Mode{.Interpolated,.Predicted,.Interpolated})
    testing.expect_value(t,s.stats.switched,u64(2))
    testing.expectf(t,largest_jump>0.4,"where it is jumped %.3f m at the most: the two timelines are eleven ticks apart",largest_jump)
    testing.expectf(t,abs(r.smoothing.offset.x)<0.01 && abs(placed-SPEED*f32(200-11)/60)<0.02,"at the end it is at %.3f m, drawn %.3f m off",placed,r.smoothing.offset.x)
}

// Two entities the game makes on both ends in one tick, which the client
// predicts, are one entity each on the client: the plugin numbers them alike
// on both ends, and the replica of the server takes each the client made,
// once: one whose creation arrives at once, one whose creation is lost and
// arrives ticks later, also when a correction goes back past the tick of the
// spawn and runs it again, and when the ticks that run again no longer make
// them. One the server never makes goes when the history passes. One a library
// keeps is taken and outlives its replica; without a replica only its mark goes.
@(test)
a_predicted_spawn_is_taken_by_its_replica_once_across_a_loss_and_a_correction :: proc(t:^testing.T) {
    f:Correction_Fixture
    defer correction_fixture_destroy(&f)
    if !correction_fixture_init(t,&f,.Predicted,{max_objects=8,predicted_capacity=8,replication={history_seconds=0.5}}) {return}
    s:=&f.session
    c:=&s.client
    ref:=core.world_ref(&f.world,&f.info)
    c.connection=7
    ids:=[2]base.Entity_Id{spawn_id(7,12,0),spawn_id(7,12,1)}
    testing.expect(t,ids[0]!=0 && ids[0]!=ids[1] && ids[0]!=spawn_id(7,13,0) && ids[0]!=spawn_id(8,12,0))
    f.shared.spawn_at,f.shared.spawns=12,2
    for tick in u32(11)..=14 {correction_fixture_tick(&f,tick)}
    made:[2]core.Entity
    for id,k in ids {
        made[k]=core.entity_of(&f.world.entities,id)
        if !testing.expectf(t,made[k]!=core.NONE && core.has(&f.world.spawns,made[k]),"the client made spawn %d of the tick in its tick, with the Id both ends draw",k) {return}
    }
    entities:=core.count(&f.world.transforms)

    words:=make([]u32,c.words_per);defer delete(words)
    type:=net_test_type(s,ref,made[0])
    // The creation the server sends of what it made with an Id.
    create :: proc(f:^Correction_Fixture,ref:core.World_Ref,type:wire.Type_Id,words:[]u32,object:Object,id:base.Entity_Id) -> ^Replica {
        s:=&f.session
        pose:=Pose{id=id,position={0,5,0},rotation=1,scale={1,1,1}}
        value:=Net_Test_Value{}
        wire.object_pack(&s.host,type,0,&pose,words)
        wire.object_pack(&s.host,type,net_test_fragment(s,type,Net_Test_Value),&value,words)
        created:=wire.Command{kind=.Object_Created,object=object,type=type,role=.Shown,simulation=.Server,tick=12,mask=s.protocol.types[type].all,words=words}
        replica_create(s,ref,f.app.assets,&created)
        core.world_settle(ref)
        return replica_of(s,object)
    }
    taken :: proc(t:^testing.T,f:^Correction_Fixture,r:^Replica,id:base.Entity_Id,entities:int,what:string) {
        e:=core.entity_of(&f.world.entities,id)
        link,linked:=core.get(&f.world.links,e)
        testing.expectf(t,e!=core.NONE && r.entity==e && linked && link.object==r.object && !core.has(&f.world.spawns,e) && core.count(&f.world.transforms)==entities,
            "%s: the replica has entity %v, the Id is of %v (linked %v), and the world has %d entities of %d",what,r.entity,e,linked,core.count(&f.world.transforms),entities)
    }
    first:=create(&f,ref,type,words,Object(2),ids[0])
    taken(t,&f,first,ids[0],entities,"as its creation arrives")
    testing.expect(t,first.entity==made[0] && first.mode==.Predicted && !first.adopted,"the one the client made, predicted, and the replica's own")
    for tick in u32(15)..=17 {correction_fixture_tick(&f,tick)}
    testing.expect(t,core.has(&f.world.spawns,made[1]),"the second waits for its replica")
    second:=create(&f,ref,type,words,Object(3),ids[1])
    taken(t,&f,second,ids[1],entities,"as its lost creation arrives")
    testing.expect(t,second.entity==made[1] && second.mode==.Predicted,"the second the client made")

    // The server corrects the body of the client at a tick before the spawn: the tick of the spawn runs again.
    correction_fixture_state(&f,11,{0,0.2,0})
    client_reconcile(s,ref,&f.app,1.0/60)
    testing.expect_value(t,s.stats.corrected,u64(1))
    taken(t,&f,first,ids[0],entities,"the first, after the tick of the spawn ran again")
    taken(t,&f,second,ids[1],entities,"the second, after the tick of the spawn ran again")
    testing.expect_value(t,f.shared.sent,1) // the tick that ran again sent nothing

    // The ticks that run again no longer make them, and the server did: each replica makes its entity.
    f.shared.spawn_at=0
    correction_fixture_state(&f,11,{0,0.4,0})
    client_reconcile(s,ref,&f.app,1.0/60)
    testing.expect(t,s.stats.corrected==2 && core.alive(&f.world.entities,first.entity) && core.alive(&f.world.entities,second.entity) && core.count(&f.world.transforms)==entities)

    // One the server never makes goes once the history is past.
    f.shared.spawn_at,f.shared.spawns=u64(c.newest+1),1
    alone:=spawn_id(7,f.shared.spawn_at,0)
    correction_fixture_tick(&f,c.newest+1)
    testing.expect(t,core.entity_of(&f.world.entities,alone)!=core.NONE)
    for _ in 0..<c.history+1 {correction_fixture_tick(&f,c.newest+1)}
    testing.expect(t,core.entity_of(&f.world.entities,alone)==core.NONE,"nothing confirmed it within the history")

    // What a library makes with the Id both ends draw and keeps (the piece of a fracture).
    kept :: proc(f:^Correction_Fixture,id:base.Entity_Id) -> core.Entity {
        e:=core.create(&f.world.entities)
        core.add(&f.world.identities,e,core.Id{id})
        core.add(&f.world.transforms,e,core.TRANSFORM_IDENTITY)
        core.settle(&f.info,&f.world,nil)
        predict_kept(&f.world.made,e)
        correction_fixture_tick(f,f.session.client.newest+1)
        return e
    }
    piece:=kept(&f,98)
    held:=create(&f,ref,type,words,Object(4),98)
    testing.expect(t,held.entity==piece && held.adopted && !core.has(&f.world.spawns,piece),"a replica takes what a library keeps, which outlives it")
    lone:=kept(&f,99)
    testing.expect(t,core.has(&f.world.spawns,lone))
    for _ in 0..<c.history+1 {correction_fixture_tick(&f,c.newest+1)}
    core.settle(&f.info,&f.world,nil)
    testing.expect(t,core.alive(&f.world.entities,lone) && !core.has(&f.world.spawns,lone),"what a library keeps stays; without a replica only its mark goes")
}
