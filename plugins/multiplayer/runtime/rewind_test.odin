package multiplayer

import "core:testing"
import "mirai:host"
import wire "mirai:net"
import phys "plugins:physics/runtime"
import "mirai:core"
import mm "mirai:std/math"

@(private="file")
rewind_put :: proc(history:^Rewind_History,tick:u64,poses:..Rewind_Pose) {
    frame:=&history.frames[tick%u64(len(history.frames))]
    frame.tick,frame.count=tick,len(poses)
    copy(frame.poses[:],poses)
}

@(test)
rewind_pose_interpolates_between_ticks_and_not_across_a_teleport :: proc(t:^testing.T) {
    slots:=u64(31)
    history:=new(Rewind_History)
    testing.expect(t,rewind_make(history,int(slots),4))
    defer {rewind_free(history);free(history)}
    runner,other:=core.Entity(5),core.Entity(9)
    turned:=mm.quat_axis_angle({0,1,0},1)
    rewind_put(history,100,{runner,{0,0,0},1},{other,{9,0,0},1})
    rewind_put(history,101,{runner,{1,0,0},turned},{other,{9,0,0},1})
    rewind_put(history,102,{runner,{50,0,0},turned})

    // A quarter into tick 100: a quarter of the way to 101.
    position,rotation,ok:=rewind_pose(history,runner,100.25)
    testing.expect(t,ok)
    testing.expectf(t,abs(position.x-0.25)<1e-5,"position %v",position)
    testing.expect(t,rotation!=1 && rotation!=turned)
    // A whole tick is that tick.
    position,_,ok=rewind_pose(history,runner,101)
    testing.expect(t,ok && position=={1,0,0})
    // 49 m in a tick is a teleport: the pose before it, not one in between.
    position,_,ok=rewind_pose(history,runner,101.5)
    testing.expect(t,ok && position=={1,0,0})
    // The last tick has no next one: itself.
    position,_,ok=rewind_pose(history,runner,102.5)
    testing.expect(t,ok && position=={50,0,0})
    // Not remembered: before the history, or an entity that was not in that tick.
    _,_,ok=rewind_pose(history,runner,99.5)
    testing.expect(t,!ok)
    _,_,ok=rewind_pose(history,other,102)
    testing.expect(t,!ok)
    // A tick the ring wrote over is gone.
    rewind_put(history,100+slots,{runner,{7,0,0},1})
    _,_,ok=rewind_pose(history,runner,100)
    testing.expect(t,!ok)
    position,_,ok=rewind_pose(history,runner,f64(100+slots))
    testing.expect(t,ok && position=={7,0,0})
}

@(test)
rewind_tick_is_what_the_client_showed_within_the_limit :: proc(t:^testing.T) {
    connection:=Connection(u64(3)<<32|2)
    inputs:Remote_Inputs
    defer delete(inputs.entries)
    resize(&inputs.entries,3)
    inputs.entries[2]={connection=connection,status=.Fresh,view=290.5}
    time:=core.Time{tick=300,dt=1.0/60}

    tick,ok:=rewind_tick(core.ref(&inputs),connection,time)
    testing.expect(t,ok)
    testing.expect_value(t,tick,290.5)
    // No further back than the limit: 0.1 s at 60 Hz is 6 ticks.
    tick,ok=rewind_tick(core.ref(&inputs),connection,time,0.1)
    testing.expect(t,ok)
    testing.expect_value(t,tick,f64(294))
    // Never after the tick being simulated.
    inputs.entries[2].view=310
    tick,_=rewind_tick(core.ref(&inputs),connection,time)
    testing.expect_value(t,tick,f64(300))
    // Without an input that says it, nothing to rewind to.
    inputs.entries[2].status=.None
    _,ok=rewind_tick(core.ref(&inputs),connection,time)
    testing.expect(t,!ok)
    _,ok=rewind_tick(core.ref(&inputs),Connection(u64(1)<<32|1),time)
    testing.expect(t,!ok)
}

// A body the server simulates and this client does not drive is predicted by
// default, and interpolated with interpolate_others; the one it drives is
// predicted either way.
@(test)
what_a_client_does_not_drive_is_shown_in_the_past_unless_it_is_asked_to_predict_it :: proc(t:^testing.T) {
    for case_ in ([3]struct{predict:bool,role:Role,mode:Mode}{{false,.Shown,.Interpolated},{true,.Shown,.Predicted},{false,.Predicted,.Predicted}}) {
        f:Correction_Fixture
        described:bool
        f.info,described=net_test_info(t)
        if !described {return}
        net_test_init(&f.world,&f.info)
        f.e=net_test_body(&f.world,&f.info,1)
        f.shared={info=&f.info}
        f.app={info=&f.info,allocator=context.allocator,tick_dt=1.0/60,shared=&f.shared}
        net_test_physics(&f.world,&f.shared,&f.app)
        if testing.expect(t,wire.sim_network_init(&f.network,{seed=31,endpoints=2,packets=64})) &&
           testing.expect(t,net_test_session(&f.session,&f.world,&f.info,&f.app,&f.network,1,.Client,settings={max_objects=8,predicted_capacity=8,replication={history_seconds=0.5}})) {
            f.shared.session=&f.session
            r:=net_test_replica(&f.session,core.world_ref(&f.world,&f.info),f.e,case_.role,.Server)
            r.pose.predict=case_.predict
            replica_classify(&f.session,core.world_ref(&f.world,&f.info),r)
            testing.expectf(t,r.mode==case_.mode,"Replicate.predict %v, role %v: %v, not %v",case_.predict,case_.role,r.mode,case_.mode)
        }
        correction_fixture_destroy(&f)
    }
}
