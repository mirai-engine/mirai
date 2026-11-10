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

// A spawn both ends make in the same tick is one entity on the client: the
// replica of the server takes the one the client made, also when a correction
// goes back past the tick of the spawn and runs it again, and when the ticks
// that run again no longer make it. One the server never makes goes when the
// history passes.
@(test)
a_predicted_spawn_is_taken_by_its_replica_also_across_a_correction :: proc(t:^testing.T) {
    f:Correction_Fixture
    defer correction_fixture_destroy(&f)
    if !correction_fixture_init(t,&f,.Predicted,{max_objects=8,predicted_capacity=8,replication={history_seconds=0.5}}) {return}
    s:=&f.session
    c:=&s.client
    ref:=core.world_ref(&f.world,&f.info)
    c.connection=7
    id:=spawn_id(7,12,0)
    testing.expect(t,id!=0 && id!=spawn_id(7,13,0) && id!=spawn_id(8,12,0) && id!=spawn_id(7,12,1))
    f.shared.spawn_at=12
    for tick in u32(11)..=14 {correction_fixture_tick(&f,tick)}
    made:=core.entity_of(&f.world.entities,id)
    if !testing.expect(t,made!=core.NONE && core.has(&f.world.spawns,made),"the client made the entity in its tick, with the Id both ends draw") {return}
    entities:=core.count(&f.world.transforms)

    // The server made it in that tick too: its creation arrives.
    type:=net_test_type(s,ref,made)
    words:=make([]u32,c.words_per);defer delete(words)
    pose:=Pose{id=id,position={0,5,0},rotation=1,scale={1,1,1}}
    value:=Net_Test_Value{}
    wire.object_pack(&s.host,type,0,&pose,words)
    wire.object_pack(&s.host,type,net_test_fragment(s,type,Net_Test_Value),&value,words)
    created:=wire.Command{kind=.Object_Created,object=Object(2),type=type,role=.Shown,simulation=.Server,tick=12,mask=s.protocol.types[type].all,words=words}
    replica_create(s,ref,f.app.assets,&created)
    core.world_settle(ref)
    r:=&c.replicas[2]
    taken :: proc(t:^testing.T,f:^Correction_Fixture,r:^Replica,id:base.Entity_Id,entities:int,what:string) {
        e:=core.entity_of(&f.world.entities,id)
        link,linked:=core.get(&f.world.links,e)
        testing.expectf(t,e!=core.NONE && r.entity==e && linked && link.object==r.object && !core.has(&f.world.spawns,e) && core.count(&f.world.transforms)==entities,
            "%s: the replica has entity %v, the Id is of %v (linked %v), and the world has %d entities of %d",what,r.entity,e,linked,core.count(&f.world.transforms),entities)
    }
    taken(t,&f,r,id,entities,"as its creation arrives")
    testing.expect(t,r.entity==made && r.mode==.Predicted && !r.adopted,"the one the client made, predicted, and the replica's own")

    // The server corrects the body of the client at a tick before the spawn: the tick of the spawn runs again.
    correction_fixture_state(&f,11,{0,0.2,0})
    client_reconcile(s,ref,&f.app,1.0/60)
    testing.expect_value(t,s.stats.corrected,u64(1))
    taken(t,&f,r,id,entities,"after the tick of the spawn ran again")
    testing.expect_value(t,f.shared.sent,1) // the tick that ran again sent nothing

    // The ticks that run again no longer make it, and the server did: the replica makes its entity.
    f.shared.spawn_at=0
    correction_fixture_state(&f,11,{0,0.4,0})
    client_reconcile(s,ref,&f.app,1.0/60)
    testing.expect(t,s.stats.corrected==2 && core.alive(&f.world.entities,r.entity) && core.count(&f.world.transforms)==entities)

    // One the server never makes goes once the history is past.
    f.shared.spawn_at=u64(c.newest+1)
    alone:=spawn_id(7,f.shared.spawn_at,0)
    correction_fixture_tick(&f,c.newest+1)
    testing.expect(t,core.entity_of(&f.world.entities,alone)!=core.NONE)
    for _ in 0..<c.history+1 {correction_fixture_tick(&f,c.newest+1)}
    testing.expect(t,core.entity_of(&f.world.entities,alone)==core.NONE,"nothing confirmed it within the history")
}
