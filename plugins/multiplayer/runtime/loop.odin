package multiplayer

import "mirai:core"
import "mirai:host"
import wire "mirai:net"

// The network inside the frame of the game:
//
//   input (begin)    opens the network the first time; the datagrams received become changes
//                    to the world; a client compares the states of the server with what it
//                    predicted, goes back and replays when they differ, and keeps the clock of
//                    the world on the clock of the connection
//   input (begin)    after the libraries read what arrived, client: goes back to the earliest
//                    tick a library asked for (rewind)
//   fixed (begin)    who arrived and who left since the last tick (Net_Connections).
//                    server: the input each connection sent for the tick.
//                    client: the copy of the world as the tick found it, and the interpolated
//                    replicas where they are shown at that tick
//   fixed (end)      client: the entities libraries made for replicas take their place
//                    (adopt). Both: publishes what the tick left, and the host sends what changed
//   frame (begin)    client: the error a correction left on a predicted replica fades
//   late (end)       the host sends and receives; the player is told how it stands
//
// Each step first catches up with a scene that replaced the world (world.odin).
// A paused game runs no phase: pump keeps its connections instead.
//
// A correction runs the fixed loop again from the input phase with
// core.Time.resimulating set: send drops what the ticks ask again, and the
// tail neither publishes nor sends.

@(step="input",loops="game",stage="begin",before="clock_requests")
net_begin :: proc(world:core.World_Ref,app:^host.App,session:^Net_Session,settings:^Net_Settings,events:^Net_Events,inputs:^Remote_Inputs,problems:^core.Problems) {
    previous:=session.problems
    session.problems=problems
    defer session.problems=previous
    defer authority_follow(session,world)
    if !session.events_held {core.queue_clear(&events.received)}
    session.events_held=false
    if !session.opened {session_start(session,world,app,settings)}
    if !session.host_ready {
        report_update(session,app)
        return
    }
    world_follow(session,world)
    if session.mode==.Client {
        frame_view_take(session,world)
        client_sync_test(session,world,app)
    }
    if net_receive(session,world,app,events,inputs) && session.mode==.Client {
        frame:=core.world_storage_of(world,core.Frame_Time)
        client_reconcile(session,world,app,frame!=nil?frame.dt:0)
        client_clock(session,world,app)
    }
    report_update(session,app)
}

// After the libraries read what arrived: what they learned changed ticks
// already simulated goes back to the earliest of them and runs again.
@(step="input",loops="game",stage="begin",after="net_begin")
net_rewind :: proc(world:core.World_Ref,app:^host.App,session:^Net_Session,rewinds:^Net_Rewinds,problems:^core.Problems) {
    asked:=core.take(&rewinds.queue)
    if !session.host_ready || session.mode!=.Client || len(asked)==0 {return}
    previous:=session.problems
    session.problems=problems
    defer session.problems=previous
    client_rewinds(session,world,app,asked)
}

@(step="fixed",loops="game",stage="begin",before="pose_targets_place")
net_tick_head :: proc(world:core.World_Ref,app:^host.App,session:^Net_Session,inputs:^Remote_Inputs,connections:^Net_Connections,problems:^core.Problems) {
    previous:=session.problems
    session.problems=problems
    defer session.problems=previous
    // A tick run alone (play.step, a correction) sees the role the session has now.
    authority_follow(session,world)
    time:=core.world_storage_of(world,core.Time)
    if time==nil {return}
    // A tick run again has those it had.
    if connections!=nil && !time.resimulating {
        core.queue_clear(&connections.events)
        for event in session.arrived {core.push(&connections.events,event)}
        clear(&session.arrived)
    }
    if !session.host_ready {return}
    world_follow(session,world)
    tick:=u32(time.tick)
    if session.mode==.Server {
        server_inputs(session,tick,inputs)
    } else {
        client_head(session,world,app,tick,time.resimulating)
    }
}

@(step="fixed",loops="game",stage="end")
net_tick_tail :: proc(world:core.World_Ref,session:^Net_Session,outbox:^Net_Outbox,adoptions:^Net_Adoptions,problems:^core.Problems) {
    previous:=session.problems
    session.problems=problems
    defer session.problems=previous
    world_follow(session,world)
    adopted:=core.take(&adoptions.queue)
    if session.host_ready && session.mode==.Client {
        for item in adopted {replica_adopt(session,world,item.id,item.entity)}
    }
    if !session.host_ready {return}
    time:=core.world_storage_of(world,core.Time)
    if time==nil || time.resimulating {return}
    tick:=u32(time.tick)
    if session.mode==.Server {
        server_publish(session,world,outbox,tick)
    } else {
        client_tail(session,world,tick,outbox)
    }
}

@(step="frame",loops="game",stage="begin")
net_frame :: proc(world:core.World_Ref,session:^Net_Session) {
    if !session.host_ready || session.mode!=.Client {return}
    world_follow(session,world)
    frame:=core.world_storage_of(world,core.Frame_Time)
    client_frame(session,world,frame!=nil?frame.dt:0)
}

STATUS_TICKS :: 60

@(step="late",loops="game",stage="end")
net_end :: proc(world:core.World_Ref,app:^host.App,session:^Net_Session,problems:core.Ref(core.Problems)) {
    world_follow(session,world)
    if session.host_ready && session.mode==.Server {
        server_world_update(session)
        server_clock(session,world,false)
    }
    if session.host_ready {
        wire.host_update(&session.host,host.app_seconds(app))
    }
    report_update(session,app)
    if session.status_file!=nil {
        time:=core.world_storage_of(world,core.Time)
        if time!=nil && time.tick>=session.status_tick {
            // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
            status_write(session,world,app.stats.frames,time.tick,problems.ptr!=nil?problems.ptr.count:0)
            // On multiples of the step: a client and a server write the same ticks, and their blocks compare one to one.
            every:=session.status_ticks>0?session.status_ticks:STATUS_TICKS
            session.status_tick=(time.tick/every+1)*every
        }
    }
}

// The network of a World whose game is paused, called each frame instead of
// its phases: without it the other ends time out. A session asked for opens
// here when no frame opened it yet (a run that has not run). What arrives is
// taken as at the start of a frame, without the correction nor the clock of a
// client, and its events wait for the next frame that runs.
pump :: proc(session:^Net_Session,world:core.World_Ref,app:^host.App) {
    previous:=session.problems
    session.problems=core.world_storage_of(world,core.Problems)
    defer session.problems=previous
    if !session.opened {
        if request:=core.world_storage_of(world,Session_Request);request!=nil && (request.open.server || request.open.connect[0]!=0) {
            settings:Net_Settings
            if app.shared!=nil {
                if stored:=core.world_storage_of(core.world_ref(app.shared,world.info,.Shared),Net_Settings);stored!=nil {settings=stored^}
            }
            session_start(session,world,app,&settings)
        }
    }
    if !session.host_ready {return}
    events,inputs:=core.world_storage_of(world,Net_Events),core.world_storage_of(world,Remote_Inputs)
    if events==nil || inputs==nil {return}
    session.events_held=true
    world_follow(session,world)
    if net_receive(session,world,app,events,inputs) {
        // Its ticks stand still while it is pumped: its clients' estimate of them too.
        if session.mode==.Server {server_clock(session,world,true)}
        wire.host_update(&session.host,host.app_seconds(app))
    }
    authority_follow(session,world)
    report_update(session,app)
}

// What arrived, as commands of the host, for net_begin and pump. false when
// the session of a client ended with it, and is destroyed.
@(private)
net_receive :: proc(session:^Net_Session,world:core.World_Ref,app:^host.App,events:^Net_Events,inputs:^Remote_Inputs) -> bool {
    session.now=host.app_seconds(app)
    commands:=wire.host_poll(&session.host)
    if session.mode==.Server {
        server_commands(session,world,app,commands,events,inputs)
        return true
    }
    client_commands(session,world,app.assets,app.allocator,commands,events)
    if !session.ended {return true}
    // Its ticks go at the pace of the frames again, and its clock is its own.
    if frame:=core.world_storage_of(world,core.Frame_Time);frame!=nil {frame.dilation=0}
    clock_follow(world,core.CLOCK_DEFAULT.paused,core.CLOCK_DEFAULT.scale)
    // What arrived, the end of the session among it, waits for the next tick.
    arrived:=session.arrived
    session.arrived=nil
    session_destroy(session)
    session.arrived=arrived
    return false
}

// Client: the clock of the world as the server has it, or its own again when
// the session ends, asked of the one that writes it (core.clock_requests).
// Only what differs is asked: what a frame asks is taken before the next.
@(private)
clock_follow :: proc(w:core.World_Ref,paused:bool,scale:f32) {
    clock,requests:=core.world_storage_of(w,core.Clock),core.world_storage_of(w,core.Clock_Requests)
    if clock==nil || requests==nil {return}
    if clock.paused!=paused || clock.scale!=scale {core.clock_follow(requests,paused,scale)}
}
