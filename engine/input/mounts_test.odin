package input

import "core:testing"
import "mirai:core"

// The world of the mount tests: seats, bodies with places, mounts and what
// they derive.
@(private)
@(test_world)
Mount_World :: struct {
    using world:Test_World,
    seats:core.Table(Seat),
    runtime:Seat_States,
    seat_state:Seats,
    seat_requests:Seat_Requests,
    moves:core.Table(Move_Input),
    remotes:core.Table(core.Remote),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
    mounts:core.Table(Mount),
    carried:core.Table(core.Carried),
    disabled:core.Table(core.Disabled),
    places:core.Places,
    jumps:core.Jumps,
    contexts:Input_Contexts,
    mount_events:Mount_Events,
    network:core.Network,
}

@(private="file") HATCH_CONTEXT :: Input_Context(3)

// A tick of the input library as the loop runs it: the requests, then what every end derives.
@(private="file")
mount_tick :: proc(w:^Mount_World,problems:^core.Problems) {
    es:=core.ref(&w.entities)
    exits:=Mount_Exits{locals=core.read(&w.transforms),parents=core.read(&w.parents)}
    input_seat_index(es,core.read(&w.seats),&w.seat_state,problems)
    input_drive(es,&w.moves,&w.seats,&w.seat_state,&w.runtime,&w.seat_requests,core.ref(&w.network),core.read(&w.remotes),&w.mounts,core.read(&w.carried),exits,problems)
    test_world_settle(w)
    input_mounts(es,core.read(&w.mounts),&w.carried,&w.parents,&w.transforms,&w.places,&w.jumps,{},{},&w.seat_state,&w.contexts,&w.mount_events,problems)
    test_world_settle(w)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
}

// A diver drives itself; a submarine has a hatch that drives the hull. What
// mounting, getting off, a mount taken, a client, a mount that dies and a
// player that leaves do to who drives what and where the diver is, and that a
// copy of the world made halfway runs the same future.
@(test)
a_seat_rides_a_mount_and_gets_off_at_its_exit :: proc(t:^testing.T) {
    Case :: struct {
        what:string,
        role:core.Network_Role,
        act:proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity),
        code:string,       // the problem it reports; "" none
        rides:bool,        // the diver rides the hatch after it
        drives:bool,       // the seat drives the hull after it, else the diver
        place:[3]f32,      // where the diver is in the world after it
    }
    cases:=[]Case{
        {"mount",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {mount(&w.seat_requests,seat,hatch)},"",true,true,{10,1,0}},
        {"mount and get off",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {
            mount(&w.seat_requests,seat,hatch)
            mount_tick(w,problems)
            dismount(&w.seat_requests,seat)
        },"",false,false,{12,1,0}},
        {"a mount another body rides",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {
            mount(&w.seat_requests,seat,hatch)
            mount_tick(w,problems)
            // A second seat, with a body of its own, asks for the same hatch.
            second:=core.create(&w.entities)
            core.add(&w.transforms,second,core.TRANSFORM_IDENTITY)
            core.edit(&w.seats,other).body=second
            mount(&w.seat_requests,other,hatch)
        },"input.mount_taken",true,true,{10,1,0}},
        {"a client asks",.Client,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {mount(&w.seat_requests,seat,hatch)},"input.server_decides",false,false,{0,0,0}},
        {"a mount that is no Mount",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {mount(&w.seat_requests,seat,hull)},"input.not_a_mount",false,false,{0,0,0}},
        {"the hatch is destroyed",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {
            mount(&w.seat_requests,seat,hatch)
            mount_tick(w,problems)
            core.destroy(&w.entities,hatch)
            test_world_settle(w)
        },"",false,false,{10,1,0}},
        {"the submarine is destroyed",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {
            mount(&w.seat_requests,seat,hatch)
            mount_tick(w,problems)
            core.destroy(&w.entities,hull)
            test_world_settle(w)
        },"",false,false,{10,1,0}},
        {"its player leaves",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {
            mount(&w.seat_requests,seat,hatch)
            mount_tick(w,problems)
            core.add(&w.disabled,seat,core.Disabled{})
            test_world_settle(w)
            mount_tick(w,problems)
            core.remove(&w.disabled,seat)
            test_world_settle(w)
        },"",false,false,{12,1,0}},
        {"getting off what it does not ride",.Standalone,proc(w:^Mount_World,problems:^core.Problems,seat,other,diver,hull,hatch:core.Entity) {dismount(&w.seat_requests,seat)},"input.not_riding",false,false,{0,0,0}},
    }
    for c in cases {
        w:Mount_World
        problems:core.Problems
        if !test_world_init(t,&w) {return}
        defer test_world_destroy(&w)
        w.network.role=c.role
        seat,other,diver,hull,hatch:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
        core.add(&w.seats,seat,Seat{body=diver})
        core.add(&w.seats,other,Seat{slot=1})
        core.add(&w.transforms,diver,core.TRANSFORM_IDENTITY)
        core.add(&w.moves,diver,Move_Input{})
        // The hull at x 10, the hatch on top, getting off 2 m to its right.
        core.add(&w.transforms,hull,core.Transform{{10,0,0},1,{1,1,1}})
        core.add(&w.moves,hull,Move_Input{frame=.Body})
        core.add(&w.transforms,hatch,core.Transform{{0,1,0},1,{1,1,1}})
        core.add(&w.parents,hatch,core.Parent{entity=hull})
        core.add(&w.mounts,hatch,Mount{drives=hull,input_context=HATCH_CONTEXT,exits={0={2,0,0}},exit_count=1})
        test_world_settle(&w)
        core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
        c.act(&w,&problems,seat,other,diver,hull,hatch)
        mount_tick(&w,&problems)
        mount_tick(&w,&problems)

        value,_:=core.get(&w.mounts,hatch)
        carried,rides:=core.get(&w.carried,diver)
        parent,_:=core.get(&w.parents,diver)
        testing.expectf(t,rides==c.rides && (value.rider==diver)==c.rides && (parent.entity==hatch)==c.rides,"%s: rides %v, the hatch names %v, the diver hangs from %v",c.what,rides,value.rider,parent.entity)
        if rides {testing.expectf(t,carried.by==hatch,"%s: carried by %v",c.what,carried.by)}
        body:=body_of(core.read(&w.seats),seat)
        testing.expectf(t,body==(c.drives?hull:diver),"%s: the seat drives %v",c.what,body)
        place,_:=core.world_of(core.read(&w.transforms),core.read(&w.parents),diver)
        testing.expectf(t,linalg_close(place.position,c.place),"%s: the diver is at %v",c.what,place.position)
        entered:=in_context(&w.contexts,hatch)
        testing.expectf(t,entered==(c.rides && c.drives),"%s: the seat is in the context of the hatch: %v",c.what,entered)
        if c.code=="" {
            testing.expectf(t,problems.count==0,"%s: %d problems, the first %s",c.what,problems.count,problems.count>0?core.problem_code(&problems.entries[0]):"")
        } else {
            testing.expectf(t,core.problem_find(&problems,seat,c.code)!=nil || core.problem_find(&problems,other,c.code)!=nil,"%s: reports %s",c.what,c.code)
        }
        testing.expectf(t,body_of(core.read(&w.seats),other)!=hull,"%s: the other seat never drives the hull",c.what)
    }
}

// A copy of the world made while the diver rides runs the same ticks as the
// world it came from: it gets off at the same tick and place.
@(test)
a_copy_made_while_riding_runs_the_same_future :: proc(t:^testing.T) {
    w,copied:Mount_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    if !test_world_init(t,&copied) {return}
    defer test_world_destroy(&copied)
    seat,diver,hull,hatch:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,Seat{body=diver})
    core.add(&w.transforms,diver,core.TRANSFORM_IDENTITY)
    core.add(&w.transforms,hull,core.Transform{{0,0,-4},1,{1,1,1}})
    core.add(&w.transforms,hatch,core.Transform{{0,1,0},1,{1,1,1}})
    core.add(&w.parents,hatch,core.Parent{entity=hull})
    core.add(&w.mounts,hatch,Mount{drives=hull,hide=true,exits={0={0,0,3}},exit_count=1})
    test_world_settle(&w)
    problems:core.Problems
    mount(&w.seat_requests,seat,hatch)
    mount_tick(&w,&problems)
    if !testing.expect(t,test_world_copy(&copied,&w),"the world copies") {return}
    for world in ([2]^Mount_World{&w,&copied}) {
        for tick in 0..<4 {
            if tick==2 {dismount(&world.seat_requests,seat)}
            core.edit(&world.transforms,hull).position.x+=1 // the hull moves on, as physics moves it
            mount_tick(world,&problems)
            if tick==0 {
                carried,rides:=core.get(&world.carried,diver)
                testing.expect(t,rides && carried.hidden,"it rides hidden")
            }
        }
    }
    for e in ([2]core.Entity{diver,hull}) {
        a,_:=core.get(&w.transforms,e)
        b,_:=core.get(&copied.transforms,e)
        testing.expectf(t,a==b,"%v: %v and %v",e,a,b)
    }
    place,_:=core.get(&w.transforms,diver)
    testing.expectf(t,linalg_close(place.position,{3,1,-1}),"it gets off behind the hatch where it was: %v",place.position)
    testing.expect_value(t,body_of(core.read(&copied.seats),seat),diver)
    testing.expect_value(t,len(w.mount_events.items),len(copied.mount_events.items))
}

@(private="file")
linalg_close :: proc(a,b:[3]f32) -> bool {
    d:=a-b
    return d.x*d.x+d.y*d.y+d.z*d.z<1e-6
}
