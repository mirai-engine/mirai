package terrain_multiplayer

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import multiplayer "plugins:multiplayer/runtime"
import terrain "plugins:terrain/runtime"

// One end of a session over one Heightfield of 2 by 2 pages: its tables, its
// terrain data and what this library keeps, stepped as the fixed loop steps
// them. The messages go from one end to another by hand, as the network
// would deliver them, in the order a test chooses.
@(private="file")
End_World :: struct {
    using world:core.Test_World,
    using ground:terrain.Test_Terrain,
    seats:core.Table(input.Seat),
    drivables:core.Table(input.Drivable),
    replays:terrain.Terrain_Replays,
    replayed:terrain.Terrain_Replay_Events,
    net_state:Terrain_Net_World,
    net_settings:Terrain_Net_Settings,
    authority:core.Network,
    inbox:multiplayer.Net_Events,
    outbox:multiplayer.Net_Outbox,
    connections:multiplayer.Net_Connections,
    rewinds:multiplayer.Net_Rewinds,
    root:scene.Scene_Root,
}

@(private="file")
End :: struct {
    using w:End_World,
    resident:terrain.Terrain_Resident, // of its application, as net, session and problems
    net:Terrain_Net,
    session:multiplayer.Net_Session,
    problems:core.Problems,
    owner:core.Entity,
    connection:multiplayer.Connection, // client: its own
    tick:u64,
    fixture:^Fixture, // its assets
}

@(private="file")
Fixture :: struct {
    folder:string,
    types:asset.Types,
    assets:host.Assets,
    app:host.App,
}

@(private="file")
SOURCE :: base.Asset_Id{0x7e77a1,0x5e55}

// The assets of an end, with the source as a file: of kind, raised over a
// corner when raise is not 0, or no file when not written.
@(private="file")
fixture_init :: proc(t:^testing.T,f:^Fixture,name:string,kind:=terrain.Source_Kind.Heightfield,raise:f32=0,written:=true) -> bool {
    f.folder=base.test_folder(t,name)
    if f.folder=="" {return false}
    asset.types_init(&f.types)
    s:terrain.Source
    defer terrain.source_destroy(&s)
    if !terrain.source_make(&s,kind,{97,1,97},1,16) {return false}
    if raise!=0 {terrain.source_edit(&s,{kind=.Raise,center=terrain.source_origin(&s)+{20,0,20},radius=12,amount=raise,hardness=0.5})}
    if written && !testing.expect_value(t,terrain.source_save(&s,fmt.tprintf("%s/ground.terrain",f.folder),SOURCE,&f.types),asset.Error.None) {return false}
    if !host.assets_init(&f.assets,{root=f.folder,capacity=16}) {return false}
    f.app={assets=&f.assets,allocator=context.allocator}
    return true
}

@(private="file")
fixture_destroy :: proc(f:^Fixture) {
    host.assets_destroy(&f.assets);asset.types_destroy(&f.types)
}

// A call of terrain_update in a tick of a world that plays: it loads the
// sources and applies the requests of a tick that is not routed.
@(private="file")
end_update :: proc(e:^End,f:^Fixture) {
    terrain.test_step(&e.ground,core.commands(&e.w,core.test_world_info(&e.w)),&e.resident,&f.app,&e.problems)
    core.test_world_settle(&e.w)
}

// An end with its terrain loaded, as the first tick of terrain_update leaves
// it; or, not loaded, that cannot read it.
@(private="file")
end_init :: proc(t:^testing.T,e:^End,f:^Fixture,role:core.Network_Role,connection:multiplayer.Connection=0,loaded:=true) -> bool {
    e.fixture=f
    if !core.test_world_init(t,&e.w,test_types) {return false}
    e.authority.role=role
    e.connection=connection
    if role==.Client {
        e.session.host_ready,e.session.mode,e.session.status=true,.Client,.Connected
        e.session.client.connection=connection
    } else {
        // The clients of the tests are in its world: what it sends reaches them.
        for c in 1..=3 {core.push(&e.connections.events,multiplayer.Connection_Event{kind=.Entered,connection=multiplayer.Connection(c)})}
    }
    e.owner=core.create(&e.entities)
    core.add(&e.transforms,e.owner,core.TRANSFORM_IDENTITY)
    core.add(&e.terrains,e.owner,terrain.Terrain{source=SOURCE,solid=false})
    core.test_world_settle(&e.w)
    end_update(e,f)
    if !loaded {return testing.expect(t,terrain.terrain_unread(core.ref(&e.data),&e.fixture.assets,SOURCE),"an end without the file of the source cannot read it")}
    return testing.expectf(t,terrain.terrain_source(core.ref(&e.data),SOURCE)!=nil,"the source loads: %v",core.problems_list(&e.problems))
}

@(private="file")
end_destroy :: proc(e:^End) {
    terrain.terrain_resident_free(&e.resident);net_free(&e.net)
    core.test_world_destroy(&e.w)
}

// A seat of the server for the player of a connection.
@(private="file")
end_seat :: proc(e:^End,connection:multiplayer.Connection) {
    seat:=core.create(&e.entities)
    core.add(&e.seats,seat,input.Seat{peer=u64(connection)})
    core.test_world_settle(&e.w)
}

// The messages an end is about to receive this frame, and the step of the input phase.
@(private="file")
end_receive :: proc(e:^End) {
    terrain_net_receive(core.ref(&e.inbox),core.ref(&e.authority),&e.net,core.ref(&e.net_state),core.ref(&e.session),{dt=1.0/60,tick=e.tick+1},&e.rewinds,core.ref(&e.root),e.net_settings,nil)
    core.queue_clear(&e.inbox.received)
}

// A tick of the fixed loop: this library, terrain and this library again.
@(private="file")
end_tick :: proc(e:^End,_:^Fixture,resimulating:=false) {
    f:=e.fixture
    e.tick+=1
    time:=core.Time{dt=1.0/60,playing=true,tick=e.tick,resimulating=resimulating}
    e.outbox.replaying=resimulating // as a correction of the network leaves it
    terrain_net_follow(core.ref(&e.authority),&e.net,&e.net_state,time,&e.replays,&e.outbox,core.ref(&e.session),core.ref(&e.data),core.read(&e.terrains),
        core.read(&e.seats),core.read(&e.drivables),core.read(&e.worlds),e.net_settings,core.ref(&e.root),f.app.assets,&e.problems)
    terrain.terrain_replay(&e.replays,&e.replayed,&e.digs,&e.terrain_requests,&e.data,core.read(&e.terrains),core.read(&e.worlds),f.app.assets,&e.problems)
    terrain_net_send(core.ref(&e.authority),&e.net,&e.net_state,time,&e.outbox,core.ref(&e.connections),core.ref(&e.replayed),core.ref(&e.data),core.ref(&e.session),core.ref(&e.root))
    core.queue_clear(&e.connections.events)
}

// What a server sent, to each client it is for. keep: the items stay to be
// delivered again, as to a client that comes later.
@(private="file")
server_deliver :: proc(server:^End,clients:..^End) {
    for item in server.outbox.queue.items {
        for c in clients {
            if item.to!=0 && item.to!=c.connection {continue}
            core.push(&c.inbox.received,multiplayer.Received{type=item.type,size=item.size,data=item.data})
        }
    }
    clear(&server.outbox.queue.items)
}

// What a client sent, to the server, from its connection.
@(private="file")
client_deliver :: proc(client,server:^End) {
    for item in client.outbox.queue.items {
        core.push(&server.inbox.received,multiplayer.Received{type=item.type,sender=client.connection,size=item.size,data=item.data})
    }
    clear(&client.outbox.queue.items)
}

// A round of the session: every client sends, the server receives and runs a
// tick, and every client receives and runs its tick.
@(private="file")
round :: proc(f:^Fixture,server:^End,clients:..^End) {
    for c in clients {client_deliver(c,server)}
    end_receive(server)
    end_tick(server,f)
    server_deliver(server,..clients)
    for c in clients {
        end_receive(c)
        end_tick(c,f)
    }
}

// Whether two ends hold the same heights everywhere.
@(private="file")
same_ground :: proc(a,b:^End) -> (same:bool,differ:int) {
    sa,sb:=terrain.terrain_source(core.ref(&a.data),SOURCE),terrain.terrain_source(core.ref(&b.data),SOURCE)
    if sa==nil || sb==nil {return}
    for z in 0..<int(sa.samples.z) {for x in 0..<int(sa.samples.x) {
        if terrain.source_value(sa,{x,0,z})!=terrain.source_value(sb,{x,0,z}) {differ+=1}
    }}
    return differ==0,differ
}

@(private="file")
height :: proc(e:^End,x,z:int) -> f32 {
    s:=terrain.terrain_source(core.ref(&e.data),SOURCE)
    return terrain.source_value(s,{x,0,z})
}

// A brush over sample x,z of the source.
@(private="file")
brush_at :: proc(e:^End,kind:terrain.Brush_Kind,x,z:int,radius,amount:f32,target:f32=0) -> terrain.Brush {
    s:=terrain.terrain_source(core.ref(&e.data),SOURCE)
    origin:=terrain.source_origin(s)
    return {kind=kind,center=origin+{f32(x)*s.cell,0,f32(z)*s.cell},radius=radius,amount=amount,target=target,hardness=0.5}
}

@(test)
an_edit_a_client_asks_for_is_applied_by_the_server_and_seen_by_another_client :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"seen")) {return}
    defer fixture_destroy(&f)
    s,a,b:End
    defer end_destroy(&s);defer end_destroy(&a);defer end_destroy(&b)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) || !end_init(t,&b,&f,.Client,2) {return}
    end_seat(&s,1);end_seat(&s,2)
    terrain.dig(&a.terrain_requests,brush_at(&a,.Raise,40,40,4,1),a.owner)
    // The client predicts at once: its ground rises in its tick.
    end_tick(&a,&f)
    testing.expect(t,height(&a,40,40)>0.5,"the prediction is applied in the tick it was asked")
    testing.expect_value(t,a.net_state.prediction_count,u32(1))
    s.tick,b.tick=a.tick-1,a.tick-1
    end_tick(&b,&f)
    round(&f,&s,&a,&b)
    testing.expect_value(t,s.net.stats.sent,u64(1))
    testing.expect(t,height(&s,40,40)>0.5,"the server applies what the client asked")
    for e in ([]^End{&a,&b}) {
        same,differ:=same_ground(e,&s)
        testing.expectf(t,same,"a client holds the ground of the server: %d samples differ",differ)
    }
    testing.expect_value(t,a.net.stats.absorbed,u64(1))
    testing.expect_value(t,a.net_state.prediction_count,u32(0))
    testing.expect_value(t,a.net.stats.desyncs,u64(0))
    testing.expect_value(t,b.net.stats.desyncs,u64(0))
    testing.expect_value(t,a.net_state.cursors[0].edits,u32(1))
    testing.expect_value(t,b.net_state.cursors[0].edits,u32(1))
}

@(test)
two_edits_of_one_region_end_in_the_order_of_the_server_on_every_client :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"concurrent")) {return}
    defer fixture_destroy(&f)
    s,a,b:End
    defer end_destroy(&s);defer end_destroy(&a);defer end_destroy(&b)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) || !end_init(t,&b,&f,.Client,2) {return}
    end_seat(&s,1);end_seat(&s,2)
    // Each predicts its own over the same samples: a flattens to 2, b raises by 1. Their order changes what is left.
    terrain.dig(&a.terrain_requests,brush_at(&a,.Flatten,30,30,6,1,2),a.owner)
    terrain.dig(&b.terrain_requests,brush_at(&b,.Raise,32,30,6,1),b.owner)
    end_tick(&a,&f);end_tick(&b,&f)
    s.tick=a.tick-1
    // The server hears b first.
    client_deliver(&b,&s);client_deliver(&a,&s)
    end_receive(&s)
    end_tick(&s,&f)
    testing.expect_value(t,s.net.stats.sent,u64(2))
    server_deliver(&s,&a,&b)
    end_receive(&a);end_receive(&b)
    // An edit of another over what a client predicts, for a tick it simulated, asks to go back to that tick.
    testing.expect_value(t,len(a.rewinds.queue.items),1)
    if len(a.rewinds.queue.items)==1 {testing.expect_value(t,a.rewinds.queue.items[0],u32(s.tick))}
    end_tick(&a,&f);end_tick(&b,&f)
    // Without going back the order here was not the server's: what differs asks for the pages, and converges.
    for _ in 0..<8 {round(&f,&s,&a,&b)}
    for e in ([]^End{&a,&b}) {
        same,differ:=same_ground(e,&s)
        testing.expectf(t,same,"a client holds the ground of the server: %d samples differ",differ)
        testing.expect_value(t,e.net_state.prediction_count,u32(0))
    }
    testing.expect(t,a.net.stats.resyncs>0,"a client whose order was not the server's asks for the pages")
    testing.expect(t,s.net.stats.pages_sent>0)
}

@(test)
edits_that_arrive_out_of_order_wait_for_their_turn_and_a_lost_one_brings_a_base :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"order")) {return}
    defer fixture_destroy(&f)
    s,a,b:End
    defer end_destroy(&s);defer end_destroy(&a);defer end_destroy(&b)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) || !end_init(t,&b,&f,.Client,2) {return}
    // Three edits of the server's game, one a tick, over one region.
    sent:[3][dynamic]multiplayer.Outgoing
    defer for &items in sent {delete(items)}
    for i in 0..<3 {
        terrain.dig(&s.terrain_requests,brush_at(&s,i==1?.Smooth:.Raise,50+i,50,5,0.7),s.owner)
        end_tick(&s,&f)
        append(&sent[i],..s.outbox.queue.items[:])
        clear(&s.outbox.queue.items)
    }
    a.tick,b.tick=s.tick,s.tick
    deliver :: proc(e:^End,items:[]multiplayer.Outgoing) {
        for item in items {core.push(&e.inbox.received,multiplayer.Received{type=item.type,size=item.size,data=item.data})}
    }
    // a hears the second and the third first: it waits for the first.
    deliver(&a,sent[1][:]);deliver(&a,sent[2][:])
    end_receive(&a);end_tick(&a,&f)
    testing.expect_value(t,a.net_state.cursors[0].edits,u32(0))
    deliver(&a,sent[0][:])
    end_receive(&a);end_tick(&a,&f)
    testing.expect_value(t,a.net_state.cursors[0].edits,u32(3))
    same,differ:=same_ground(&a,&s)
    testing.expectf(t,same,"edits applied in their order leave the ground of the server: %d samples differ",differ)
    testing.expect_value(t,a.net.stats.desyncs,u64(0))
    // b never hears the second: after a while it asks for a base, and the pages bring it.
    deliver(&b,sent[0][:]);deliver(&b,sent[2][:])
    end_receive(&b)
    for _ in 0..<NET_ASK_TICKS+2 {end_tick(&b,&f)}
    testing.expect_value(t,b.net_state.cursors[0].edits,u32(1))
    // The base it asks for as it loads the source, and one for the lost edit.
    testing.expect_value(t,b.net.stats.resyncs,u64(2))
    s.tick=b.tick
    for _ in 0..<8 {round(&f,&s,&b)}
    same,differ=same_ground(&b,&s)
    testing.expectf(t,same,"a base after a lost edit leaves the ground of the server: %d samples differ",differ)
    testing.expect_value(t,b.net_state.cursors[0].edits,u32(3))
}

@(test)
a_client_that_enters_late_gets_the_pages_the_edits_touched_and_converges :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"late")) {return}
    defer fixture_destroy(&f)
    s,c:End
    defer end_destroy(&s);defer end_destroy(&c)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&c,&f,.Client,3) {return}
    for i in 0..<6 {
        terrain.dig(&s.terrain_requests,brush_at(&s,.Raise,10+i*15,20+i*12,6,1.5),s.owner)
        end_tick(&s,&f)
    }
    clear(&s.outbox.queue.items)
    // It enters the world of the server: a base of the source, without the history.
    core.push(&s.connections.events,multiplayer.Connection_Event{kind=.Entered,connection=3})
    c.tick=s.tick
    round(&f,&s,&c)
    core.queue_clear(&s.connections.events)
    for _ in 0..<16 {round(&f,&s,&c)}
    same,differ:=same_ground(&c,&s)
    testing.expectf(t,same,"a client that came late holds the ground of the server: %d samples differ",differ)
    testing.expect_value(t,c.net_state.cursors[0].edits,u32(6))
    testing.expect_value(t,c.net.stats.received,u64(0))
    // The head and the end of the base, and the pages the edits touched.
    testing.expect(t,s.net.stats.pages_sent>2 && s.net.stats.pages_sent<=2+4,"only the pages the edits touched travel")
    // An edit after it comes as any other.
    terrain.dig(&s.terrain_requests,brush_at(&s,.Lower,70,70,4,1),s.owner)
    round(&f,&s,&c);round(&f,&s,&c)
    same,differ=same_ground(&c,&s)
    testing.expectf(t,same,"an edit after the base: %d samples differ",differ)
    testing.expect_value(t,c.net.stats.desyncs,u64(0))
}

@(test)
an_edit_the_server_does_not_allow_is_refused_with_what_failed_and_taken_back :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"refused")) {return}
    defer fixture_destroy(&f)
    s,a,b:End
    defer end_destroy(&s);defer end_destroy(&a);defer end_destroy(&b)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) || !end_init(t,&b,&f,.Client,2) {return}
    // a has a seat; b does not.
    end_seat(&s,1)
    s.net_settings.radius=3
    terrain.dig(&a.terrain_requests,brush_at(&a,.Raise,40,40,5,1),a.owner)
    terrain.dig(&b.terrain_requests,brush_at(&b,.Raise,60,60,2,1),b.owner)
    end_tick(&a,&f);end_tick(&b,&f)
    testing.expect(t,height(&a,40,40)>0.5 && height(&b,60,60)>0.5,"each predicts its edit")
    s.tick=a.tick-1
    for _ in 0..<6 {round(&f,&s,&a,&b)}
    testing.expect_value(t,s.net.stats.sent,u64(0))
    testing.expect_value(t,s.net.stats.refused,u64(2))
    expect_refusal :: proc(t:^testing.T,e:^End,words:string) {
        p:=core.problem_find(&e.problems,e.owner,"terrain.net_refused")
        if !testing.expect(t,p!=nil,"a refused edit is a problem of the terrain it was for") {return}
        testing.expectf(t,strings.contains(base.text_get(p.text[:]),words),"the problem says what failed: %s",base.text_get(p.text[:]))
    }
    expect_refusal(t,&a,"Terrain_Net_Settings.radius")
    expect_refusal(t,&b,"no seat")
    for e in ([]^End{&a,&b}) {
        testing.expect_value(t,e.net_state.prediction_count,u32(0))
        same,differ:=same_ground(e,&s)
        testing.expectf(t,same,"a refused prediction is taken back by the pages of the server: %d samples differ",differ)
    }
}

// What a correction brings back of an end: its terrain data and where it
// stands in the streams, at the tick it was saved.
@(private="file")
Saved :: struct {
    data:terrain.Terrain_Data,
    state:Terrain_Net_World,
    tick:u64,
}

@(private="file")
end_save :: proc(saved:^Saved,e:^End) -> bool {
    saved.state,saved.tick=e.net_state,e.tick
    return terrain.terrain_data_copy(&saved.data,&e.data)
}

@(private="file")
end_restore :: proc(e:^End,saved:^Saved) -> bool {
    e.net_state,e.tick=saved.state,saved.tick
    return terrain.terrain_data_copy(&e.data,&saved.data)
}

@(test)
a_correction_that_goes_back_applies_the_edits_of_the_server_and_the_predictions_again_at_their_ticks :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"again")) {return}
    defer fixture_destroy(&f)
    s,a:End
    defer end_destroy(&s);defer end_destroy(&a)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) {return}
    end_seat(&s,1)
    saved:Saved
    defer terrain.terrain_data_free(&saved.data)
    testing.expect(t,end_save(&saved,&a))
    // The server edits; the client predicts one of its own two ticks later.
    terrain.dig(&s.terrain_requests,brush_at(&s,.Raise,20,20,5,1),s.owner)
    own:=brush_at(&a,.Lower,60,60,5,1)
    asked:=a.tick+3
    for _ in 0..<8 {
        if a.tick+1==asked {terrain.dig(&a.terrain_requests,own,a.owner)}
        round(&f,&s,&a)
    }
    same,differ:=same_ground(&a,&s)
    testing.expectf(t,same,"the client holds the ground of the server: %d samples differ",differ)
    testing.expect_value(t,a.net.stats.absorbed,u64(1))
    end:=a.tick
    present:=a.net_state
    // Back to before both, and every tick again: the game asks its edit again at its tick.
    testing.expect(t,end_restore(&a,&saved))
    for a.tick<end {
        if a.tick+1==asked {terrain.dig(&a.terrain_requests,own,a.owner)}
        end_tick(&a,&f,true)
    }
    same,differ=same_ground(&a,&s)
    testing.expectf(t,same,"after going back the client holds the ground of the server: %d samples differ",differ)
    testing.expect_value(t,a.net_state.cursors[0],present.cursors[0])
    testing.expect_value(t,a.net_state.prediction_count,present.prediction_count)
    testing.expect_value(t,a.net.stats.desyncs,u64(0))
    testing.expect_value(t,len(a.outbox.queue.items),0)
}

// A brush travels as its bytes, and bytes that are not a brush are refused.
@(test)
a_brush_travels_as_its_bytes_and_bytes_that_are_not_one_are_refused :: proc(t:^testing.T) {
    brush:=terrain.Brush{kind=.Terrace,center={1,2,3},radius=4,amount=0.5,interval=2,riser=0.25,way=.Up,capped=true,falloff=.Linear,rotation=1}
    read,ok:=terrain.brush_of_bytes(terrain.brush_bytes(brush))
    testing.expect(t,ok)
    testing.expect_value(t,read,brush)
    bad:=terrain.brush_bytes(brush)
    bad[offset_of(terrain.Brush,kind)]=200
    _,ok=terrain.brush_of_bytes(bad)
    testing.expect(t,!ok,"an enum out of its values")
    bad=terrain.brush_bytes(brush)
    bad[offset_of(terrain.Brush,capped)]=2
    _,ok=terrain.brush_of_bytes(bad)
    testing.expect(t,!ok,"a bool that is not 0 or 1")
    nan:=brush
    nan.radius=transmute(f32)u32(0x7fc00000)
    _,ok=terrain.brush_of_bytes(terrain.brush_bytes(nan))
    testing.expect(t,!ok,"a value that is not finite")
    #assert(size_of(Net_Terrain_Edit)<=multiplayer.EVENT_BYTES)
    #assert(size_of(Net_Terrain_Page)<=multiplayer.EVENT_BYTES)
}

// Whether two ends hold the same sections of a Mesh source.
@(private="file")
same_mesh :: proc(a,b:^End) -> (same:bool,differ:int) {
    _,_,counts,ok:=terrain.terrain_sections(core.ref(&a.data),SOURCE,{},{-1,-1,-1})
    if !ok {return}
    ba,bb:[dynamic]u8
    defer delete(ba);defer delete(bb)
    for i in 0..<counts.x*counts.y*counts.z {
        if !terrain.terrain_section_bytes(core.ref(&a.data),SOURCE,i,&ba) || !terrain.terrain_section_bytes(core.ref(&b.data),SOURCE,i,&bb) || string(ba[:])!=string(bb[:]) {differ+=1}
    }
    return differ==0,differ
}

// Whether two ends hold the same layers and weights.
@(private="file")
same_layers :: proc(a,b:^End) -> bool {
    sa,sb:=terrain.terrain_source(core.ref(&a.data),SOURCE),terrain.terrain_source(core.ref(&b.data),SOURCE)
    if sa==nil || sb==nil || sa.layer_count!=sb.layer_count || sa.layers!=sb.layers {return false}
    _,_,counts,ok:=terrain.terrain_grid_pages(core.ref(&a.data),SOURCE,.Weights,{},{-1,-1,-1})
    if !ok {return sa.layer_count==0}
    ra,rb:=make([]u8,terrain.PAGE_BYTES_MAX,context.temp_allocator),make([]u8,terrain.PAGE_BYTES_MAX,context.temp_allocator)
    for i in 0..<counts.x*counts.y*counts.z {
        size_a,fill_a,read_a:=terrain.terrain_page_bytes(core.ref(&a.data),SOURCE,.Weights,i,ra)
        size_b,fill_b,read_b:=terrain.terrain_page_bytes(core.ref(&b.data),SOURCE,.Weights,i,rb)
        if !read_a || !read_b || size_a!=size_b || fill_a!=fill_b || string(ra[:size_a])!=string(rb[:size_b]) {return false}
    }
    return true
}

@(test)
a_mesh_edit_that_differs_on_a_client_comes_back_as_its_sections_and_a_late_client_gets_them :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"mesh",.Mesh)) {return}
    defer fixture_destroy(&f)
    s,a,c:End
    defer end_destroy(&s);defer end_destroy(&a);defer end_destroy(&c)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) {return}
    a.tick=s.tick
    // The base of the client as it loads the source comes and ends first.
    for _ in 0..<4 {round(&f,&s,&a)}
    // Where the server edits, the client holds another mesh, as another architecture could leave it.
    testing.expect_value(t,terrain.source_edit(terrain.terrain_source(core.ref(&a.data),SOURCE),brush_at(&a,.Raise,40,40,6,0.5)).error,terrain.Edit_Error.None)
    terrain.dig(&s.terrain_requests,brush_at(&s,.Raise,40,40,6,1),s.owner)
    for _ in 0..<60 {round(&f,&s,&a)}
    testing.expect(t,a.net.stats.desyncs>0,"the edit of the server left another mesh on the client")
    same,differ:=same_mesh(&a,&s)
    testing.expectf(t,same,"the sections of the server repair the client: %d differ",differ)
    // One that comes late gets the sections the server changed.
    if !end_init(t,&c,&f,.Client,3) {return}
    c.tick=s.tick
    for _ in 0..<60 {round(&f,&s,&a,&c)}
    same,differ=same_mesh(&c,&s)
    testing.expectf(t,same,"a client that came late holds the mesh of the server: %d sections differ",differ)
}

@(test)
layer_changes_travel_in_the_order_of_the_edits_and_a_paint_of_them_lands_the_same :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"layers")) {return}
    defer fixture_destroy(&f)
    s,a:End
    defer end_destroy(&s);defer end_destroy(&a)
    if !end_init(t,&s,&f,.Server) || !end_init(t,&a,&f,.Client,1) {return}
    end_seat(&s,1)
    a.tick=s.tick
    round(&f,&s,&a)
    rock,grass,sand:=terrain.LAYER_DEFAULT,terrain.LAYER_DEFAULT,terrain.LAYER_DEFAULT
    rock.tiling,grass.tiling,sand.tiling=2,3,5
    // The server adds two layers and paints the second in one tick.
    terrain.request_layer(&s.terrain_requests,s.owner,0,rock)
    terrain.request_layer(&s.terrain_requests,s.owner,1,grass)
    paint:=brush_at(&s,.Paint,30,30,8,0.6);paint.layer=1
    terrain.dig(&s.terrain_requests,paint,s.owner)
    for _ in 0..<4 {round(&f,&s,&a)}
    testing.expect_value(t,terrain.terrain_source(core.ref(&a.data),SOURCE).layer_count,u32(2))
    testing.expect(t,same_layers(&a,&s),"the layers and the paint of the server reach the client")
    // The client asks for a third: it is applied when the server sends it back, and a paint of it after.
    terrain.request_layer(&a.terrain_requests,a.owner,2,sand)
    end_tick(&a,&f)
    testing.expect_value(t,terrain.terrain_source(core.ref(&a.data),SOURCE).layer_count,u32(2))
    s.tick=a.tick-1
    for _ in 0..<4 {round(&f,&s,&a)}
    testing.expect_value(t,terrain.terrain_source(core.ref(&s.data),SOURCE).layer_count,u32(3))
    testing.expect_value(t,terrain.terrain_source(core.ref(&a.data),SOURCE).layer_count,u32(3))
    paint=brush_at(&a,.Paint,50,50,8,0.8);paint.layer=2
    terrain.dig(&a.terrain_requests,paint,a.owner)
    // The server takes the first away: every weight is rewritten, in its order with the paint.
    terrain.request_layer_remove(&s.terrain_requests,s.owner,0)
    for _ in 0..<8 {round(&f,&s,&a)}
    testing.expect_value(t,terrain.terrain_source(core.ref(&a.data),SOURCE).layer_count,u32(2))
    testing.expect(t,same_layers(&a,&s),"after a layer taken away the client holds the layers and weights of the server")
    testing.expect_value(t,s.net.stats.refused,u64(0))
}

@(test)
a_base_brings_what_was_edited_before_the_session_and_a_source_the_client_has_otherwise_or_not_at_all :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    // Three sets of assets do not fit in the stack of a test.
    fixtures:=new([3]Fixture)
    defer free(fixtures)
    f,g,h:=&fixtures[0],&fixtures[1],&fixtures[2]
    if !testing.expect(t,fixture_init(t,f,"before")) || !testing.expect(t,fixture_init(t,g,"other",raise=3)) || !testing.expect(t,fixture_init(t,h,"none",written=false)) {return}
    defer fixture_destroy(f);defer fixture_destroy(g);defer fixture_destroy(h)
    s,a,b,c:End
    defer end_destroy(&s);defer end_destroy(&a);defer end_destroy(&b);defer end_destroy(&c)
    if !end_init(t,&s,f,.Server) {return}
    // Before the session the server edits, saves to its file, and edits and paints again.
    s.authority.role=.Standalone
    terrain.dig(&s.terrain_requests,brush_at(&s,.Raise,30,30,6,2),s.owner)
    end_update(&s,f)
    terrain.request_save(&s.terrain_requests,s.owner)
    end_update(&s,f)
    terrain.dig(&s.terrain_requests,brush_at(&s,.Lower,70,60,5,1),s.owner)
    terrain.request_layer(&s.terrain_requests,s.owner,0,terrain.LAYER_DEFAULT)
    terrain.request_layer(&s.terrain_requests,s.owner,1,terrain.LAYER_DEFAULT)
    end_update(&s,f)
    paint:=brush_at(&s,.Paint,70,60,6,0.7);paint.layer=1
    terrain.dig(&s.terrain_requests,paint,s.owner)
    end_update(&s,f)
    s.authority.role=.Server
    // c has the file the server saved, a another source of the same id, b none.
    if !end_init(t,&c,f,.Client,3) || !end_init(t,&a,g,.Client,1) || !end_init(t,&b,h,.Client,2,loaded=false) {return}
    a.tick,b.tick,c.tick=s.tick,s.tick,s.tick
    for _ in 0..<80 {round(f,&s,&a,&b,&c)}
    for e in ([]^End{&a,&b,&c}) {
        same,differ:=same_ground(e,&s)
        testing.expectf(t,same,"client %d holds the ground of the server: %d samples differ",e.connection,differ)
        testing.expectf(t,same_layers(e,&s),"client %d holds the layers and weights of the server",e.connection)
    }
    testing.expect(t,c.net.stats.pages_applied<a.net.stats.pages_applied,"a client with the file of the server gets only what was written since")
}

TERRAIN_NET_BENCHMARK :: #config(TERRAIN_NET_BENCHMARK,false)

// The traffic of a long stroke of the server: STROKE touches, one a tick,
// to a client that leaves each the same and to one where each leaves
// another check, as another architecture could.
@(test)
traffic_of_a_long_stroke :: proc(t:^testing.T) {
    when !TERRAIN_NET_BENCHMARK {return}
    STROKE :: 240
    defer free_all(context.temp_allocator)
    f:Fixture
    if !testing.expect(t,fixture_init(t,&f,"stroke")) {return}
    defer fixture_destroy(&f)
    for differs in ([]bool{false,true}) {
        s,c:End
        if !end_init(t,&s,&f,.Server) || !end_init(t,&c,&f,.Client,1) {end_destroy(&s);end_destroy(&c);return}
        c.tick=s.tick
        for _ in 0..<4 {round(&f,&s,&c)}
        base_sent,base_bytes:=s.net.stats.pages_sent,s.net.stats.bytes_sent
        for i in 0..<STROKE {
            x:=8+f32(i)*0.33
            terrain.dig(&s.terrain_requests,brush_at(&s,.Raise,int(x),48,4,0.3),s.owner)
            if differs {
                source:=terrain.terrain_source(core.ref(&c.data),SOURCE)
                terrain.source_edit(source,brush_at(&c,.Raise,int(x),48,1,0.001))
            }
            round(&f,&s,&c)
        }
        for _ in 0..<120 {round(&f,&s,&c)}
        same,differ:=same_ground(&c,&s)
        testing.expectf(t,same,"the client holds the ground of the server after the stroke: %d samples differ",differ)
        log.infof("stroke of %d touches, the client %s: %d edits sent of %d bytes each; %d parts (%d LZ bytes) after the base; %d resyncs; %d desyncs",
            STROKE,differs?"otherwise":"the same",s.net.stats.sent,size_of(Net_Terrain_Edit),s.net.stats.pages_sent-base_sent,s.net.stats.bytes_sent-base_bytes,c.net.stats.resyncs,c.net.stats.desyncs)
        end_destroy(&s);end_destroy(&c)
    }
}
