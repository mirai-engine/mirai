package input

import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

// Places a body rides while its seat drives something else: the hatch of a
// submarine, the seat of a gunner, the bench of a passenger. mount asks that
// the body a seat drives ride a Mount; dismount, that the rider get off.
// Both are applied with the other seat requests (input_drive), whole or not
// at all, where the rules are decided (a server or a game alone): the mount
// names its rider and the seat drives what the mount drives (Mount.drives, or
// the mount itself, which then only carries).
//
// Every end derives the rest from Mount.rider and Seat.body, which replicate
// (input_mounts): the rider hangs from the mount at its place, carried
// (core.Carried: its simulation and its pose on the network are off), and the
// seat is in the input context of the mount. A rider that gets off hangs from
// nothing again at the first exit of the mount where a probe of the world
// (core.World_Queries) finds room, tried in order. A mount that dies leaves
// its rider where it was (core settles a carried entity loose of what is
// destroyed), and one whose seat is gone (a player that disconnects) lets its
// rider off as a dismount would. Mount_Events tells presentation each change.
// Who may enter, prompts, and what entering costs are the game's.

MOUNT_EXITS :: 4
MOUNT_EXIT_RADIUS :: f32(0.3) // m of the sphere a probe sweeps to an exit
MOUNT_EXIT_HEIGHT :: f32(1.8) // m kept clear above an exit

@(component,replicated,description="A place a body rides while the seat that drove it drives something else: a hatch, the seat of a gunner, a bench.")
Mount :: struct {
    drives:core.Entity,             // what the seat drives from here; none: the mount itself, which only carries (a passenger)
    input_context:Input_Context,    // the seat is in it while its body rides; base: none
    hide:bool,                      // the rider is not drawn, with what hangs from it, while it rides
    keep_input:bool,                // the rider reads the actions of the seat as before (its own abilities); the game decides
    exits:[MOUNT_EXITS][3]f32 `mirai:"unit=m"`, // where the rider gets off, in the axes of the mount, tried in order
    exit_count:u8 `mirai:"max=4"`,
    rider:core.Entity `mirai:"readonly"`, // the body that rides it; only the input library writes it
}

MOUNT_DEFAULT :: Mount{exits={0={1.5,0,0}},exit_count=1}

// The seat of body rides mount and drives what it drives.
mount :: proc(r:^Seat_Requests,seat,mount:core.Entity) {
    core.offer(&r.queue,Seat_Request{kind=.Mount,seat=seat,entity=mount})
}

// The body that rides the mount seat drives from gets off, and seat drives it again.
dismount :: proc(r:^Seat_Requests,seat:core.Entity) {
    core.offer(&r.queue,Seat_Request{kind=.Dismount,seat=seat})
}

// What the seat of a mount drives: Mount.drives, or the mount itself.
mount_driven :: proc "contextless" (e:core.Entity,mount:Mount) -> core.Entity {
    return mount.drives!=core.NONE?mount.drives:e
}

// The mount whose rider the seat of a driven entity is, and that rider; none
// without one.
mount_of_driven :: proc(mounts:^core.Table(Mount,$A),driven:core.Entity) -> (e,rider:core.Entity) {
    if driven==core.NONE {return}
    for value,row in mounts.values[:core.count(mounts)] {
        if value.rider!=core.NONE && mount_driven(core.entity_at(mounts,row),value)==driven {return core.entity_at(mounts,row),value.rider}
    }
    return
}

// The seat a rider rode for, as the input step last saw it.
Rider :: struct {
    seat:core.Entity,
    keep_input:bool,
}

Mount_Event_Kind :: enum u8 {Mounted,Dismounted}

Mount_Event :: struct {
    kind:Mount_Event_Kind,
    mount,rider:core.Entity,
}

// What the mounts did, for presentation (a sound, a hatch that opens).
@(storage)
Mount_Events :: struct {using queue:core.Events(Mount_Event)}

MOUNT_EVENT_CAPACITY :: 1024

// What a dismount reads to find where its rider gets off.
@(params)
Mount_Exits :: struct {
    locals:^core.Table(core.Transform,.Read),
    parents:^core.Table(core.Parent,.Read),
    world:core.World_Read,
    queries:core.Ref(core.World_Queries),
}

// The first exit of a mount where a body fits: a sphere swept from the mount
// to it, and one swept up from it, meet nothing but the body the mount is
// part of. forced: without a clear one, its first exit, or where the mount is
// without exits. false: none is clear and it is not forced.
mount_exit :: proc(exits:Mount_Exits,e:core.Entity,value:Mount,forced:bool) -> (place:mm.Transform,ok:bool) {
    pose,placed:=core.world_of(exits.locals,exits.parents,e)
    if !placed {return {},false}
    // Upright, facing as the mount faces across the up of the world.
    forward:=mm.quat_rotate(pose.rotation,{0,0,-1})
    forward.y=0
    facing:=mm.QUAT_IDENTITY
    if linalg.length(forward)>1e-4 {facing=mm.quat_axis_angle({0,1,0},mm.yaw_of_direction(forward))}
    count:=min(int(value.exit_count),MOUNT_EXITS)
    if count==0 {return {pose.position,facing,{1,1,1}},forced}
    query:=core.world_query_read(exits.world,exits.queries)
    ignore:=core.NONE
    if query.solid!=nil {
        for at:=e;at!=core.NONE;at=(core.get(exits.parents,at) or_else core.Parent{}).entity {
            if query.solid(query.user,at) {ignore=at;break}
        }
    }
    lift:=[3]f32{0,MOUNT_EXIT_RADIUS+0.05,0}
    for i in 0..<count {
        at:=pose.position+mm.quat_rotate(pose.rotation,value.exits[i])
        if !(linalg.length(at)<1e9) {continue}
        if query.probe!=nil {
            path:=at+lift-pose.position
            if length:=linalg.length(path);length>1e-4 {
                if _,hit:=query.probe(query.user,pose.position,path/length,length,MOUNT_EXIT_RADIUS,ignore,~u32(0));hit {continue}
            }
            if _,hit:=query.probe(query.user,at+lift,{0,1,0},MOUNT_EXIT_HEIGHT-2*lift.y,MOUNT_EXIT_RADIUS,ignore,~u32(0));hit {continue}
        }
        return {at,facing,{1,1,1}},true
    }
    if !forced {return {},false}
    return {pose.position+mm.quat_rotate(pose.rotation,value.exits[0]),facing,{1,1,1}},true
}

// A mount was asked for: the body of the seat rides it, the seat drives what
// it drives. Where another end decides, a refusal.
@(private)
mount_apply :: proc(a:^Apply,r:Seat_Request) -> Refusal {
    if !seated(a,r.seat) {return .Not_A_Seat}
    if a.role==.Client {return .Server_Decides}
    value,is_mount:=core.get(a.mounts,r.entity)
    if !core.alive(a.es,r.entity) || !is_mount {return .Not_A_Mount}
    rider:=body_of(a.seats,r.seat)
    if rider==core.NONE || !core.alive(a.es,rider) {return .No_Body}
    if value.rider!=core.NONE && core.alive(a.es,value.rider) {return value.rider==rider?.None:.Mount_Taken}
    if ridden,_:=mount_of_driven(a.mounts,rider);ridden!=core.NONE {return .Riding}
    if core.is_under(a.parents,r.entity,rider) {return .Rides_Itself}
    driven:=mount_driven(r.entity,value)
    if !core.alive(a.es,driven) {return .Not_Alive}
    if driver:=driver_of(core.ref(a.state),driven);driver!=core.NONE && driver!=r.seat {return .Taken}
    if refusal:=body_assign(a,r.seat,driven);refusal!=.None {return refusal}
    core.edit(a.mounts,r.entity).rider=rider
    return .None
}

// A dismount was asked for: the rider of the mount the seat drives from gets
// off at a clear exit, and the seat drives it again.
@(private)
dismount_apply :: proc(a:^Apply,r:Seat_Request) -> Refusal {
    if !seated(a,r.seat) {return .Not_A_Seat}
    if a.role==.Client {return .Server_Decides}
    e,rider:=mount_of_driven(a.mounts,body_of(a.seats,r.seat))
    if e==core.NONE {return .Not_Riding}
    value,_:=core.get(a.mounts,e)
    if _,clear:=mount_exit(a.exits,e,value,false);!clear {return .Exits_Blocked}
    core.edit(a.mounts,e).rider=core.NONE
    if !core.alive(a.es,rider) {return body_assign(a,r.seat,core.NONE)}
    // The rider is the seat's again: nobody else could take it while it rode.
    return body_assign(a,r.seat,rider)
}

// Mounts whose rider is gone, or whose seat no longer drives from them (it
// was released, or its player left), let the rider off; a seat that waits
// for its player gets its body back for when it returns. The seat of a rider
// whose mount was destroyed drives the rider again.
@(private)
mounts_upkeep :: proc(a:^Apply) {
    if a.role==.Client || a.mounts==nil {return}
    if a.carried!=nil {
        for value,row in a.carried.values[:core.count(a.carried)] {
            if core.alive(a.es,value.by) {continue}
            rider:=core.entity_at(a.carried,row)
            if was:=core.entity_map_get(&a.state.riders,rider);was!=nil && seated(a,was.seat) {_=body_assign(a,was.seat,rider)}
        }
    }
    for row in 0..<core.count(a.mounts) {
        value:=core.at(a.mounts,row)
        if value.rider==core.NONE {continue}
        e:=core.entity_at(a.mounts,row)
        driven:=mount_driven(e,value)
        if core.alive(a.es,value.rider) && driver_of(core.ref(a.state),driven)!=core.NONE {continue}
        rider:=value.rider
        core.edit_at(a.mounts,row).rider=core.NONE
        if !core.alive(a.es,rider) {continue}
        // A seat off (its player away) still names what it drove: it gets its body back. Its row is off, so
        // it is written as the network writes rows off.
        for &seat,at in a.seats.values {
            if seat.body!=driven {continue}
            if row:=(^Seat)(core.raw_edit(core.raw(a.seats),type_info_of(Seat),a.seats.entities[at]));row!=nil {row.body=rider}
            break
        }
    }
}

// What a mount derives on every end from its rider: the rider hangs from it
// at its place and is carried, and the seat that drives from it is in its
// input context; a rider that left hangs from nothing at the first clear
// exit. The seats that read the actions of a rider that keeps its input are
// indexed here (seat_of). The Parent of a carried entity is this step's alone:
// the other step that writes Parent (streaming_crossings) reads Carried, runs
// after it and leaves what is carried as it is.
@(step="fixed",stage="input",after="input_drive")
input_mounts :: proc(
    es:core.Ref(core.Entities),mounts:^core.Table(Mount,.Read),carried:^core.Table(core.Carried),parents:^core.Table(core.Parent),
    transforms:^core.Table(core.Transform),places:^core.Places,jumps:^core.Jumps,world:core.World_Read,queries:core.Ref(core.World_Queries),
    state:^Seats,contexts:^Input_Contexts,events:^Mount_Events,problems:^core.Problems,
) {
    if core.count(mounts)==0 && core.count(carried)==0 && len(state.riders.values)==0 {return}
    placer:=core.Placer{transforms,core.read(parents),places,jumps}
    exits:=Mount_Exits{core.read(transforms),core.read(parents),world,queries}
    core.entity_map_clear(&state.riders)
    // Who left first, then who came: a rider that changes mount rides the second from the next tick.
    #reverse for e,row in carried.entities[:core.count(carried)] {
        was:=core.at(carried,row).by
        if value,ok:=core.get(mounts,was);ok && value.rider==e && core.alive(es.ptr,was) {continue}
        core.remove(carried,e)
        mount_context_leave(contexts,was)
        if parent,hung:=core.get(parents,e);hung && parent.entity==was {core.remove(parents,e)}
        if core.alive(es.ptr,was) {
            value,_:=core.get(mounts,was)
            if place,ok:=mount_exit(exits,was,value,true);ok && !core.place_under(placer,e,core.NONE,place.position,place.rotation,true,true) {
                core.report(problems,e,"input.mount_exit","the rider could not be put at the exit of its mount: it has no Transform")
            }
        }
        core.events_push(&events.queue,Mount_Event{.Dismounted,was,e},MOUNT_EVENT_CAPACITY)
    }
    for row in 0..<core.count(mounts) {
        value:=core.at(mounts,row)
        rider:=value.rider
        if rider==core.NONE || !core.alive(es.ptr,rider) {continue}
        e:=core.entity_at(mounts,row)
        seat:=driver_of(core.ref(state),mount_driven(e,value))
        if seat!=core.NONE {
            if _,ok:=core.entity_map_put(&state.riders,rider,Rider{seat,value.keep_input});!ok {core.report(problems,rider,"input.seat_index","out of memory for the seat of a rider; free memory")}
        }
        if seat!=core.NONE && value.input_context!=CONTEXT_BASE && !mount_context_enter(contexts,e,seat,value.input_context) {
            core.report(problems,e,"input.contexts_full","the seat that rides this mount cannot enter its input context: %d contexts are entered; leave the ones no longer needed",CONTEXT_ENTRY_CAPACITY)
        }
        if was,ok:=core.get(carried,rider);ok && was.by==e {
            if was.hidden!=value.hide {core.edit(carried,rider).hidden=value.hide}
            continue
        }
        if core.has(carried,rider) {continue} // still another's until it leaves it
        if !core.add(carried,rider,core.Carried{by=e,hidden=value.hide}) {
            core.report(problems,rider,"input.mount","out of memory to carry this rider; free memory")
            continue
        }
        // At the place of the mount, as its child: a body is placed by its owner.
        at,_:=core.world_of(exits.locals,exits.parents,e)
        if !core.place_under(placer,rider,e,at.position,at.rotation,true,true) {core.report(problems,rider,"input.mount","the rider could not be put on its mount: it has no Transform")}
        if row:=core.staged(parents,rider);row!=nil {row^={entity=e}} else {core.add(parents,rider,core.Parent{entity=e})}
        core.events_push(&events.queue,Mount_Event{.Mounted,e,rider},MOUNT_EVENT_CAPACITY)
    }
}

@(private)
mount_context_enter :: proc(contexts:^Input_Contexts,mount,seat:core.Entity,input_context:Input_Context) -> bool {
    free:^Context_Entry
    for &entry in contexts.entries {
        if entry.active && entry.owner==mount {
            if entry.seat==seat && entry.input_context==input_context {return true}
            free=&entry
            break
        }
        if !entry.active && free==nil {free=&entry}
    }
    if free==nil || int(input_context)>=CONTEXT_CAPACITY || input_context==CONTEXT_ALWAYS {return false}
    contexts.order+=1
    free^={owner=mount,seat=seat,input_context=input_context,order=contexts.order,active=true}
    return true
}

@(private)
mount_context_leave :: proc(contexts:^Input_Contexts,mount:core.Entity) {
    for &entry in contexts.entries {
        if entry.active && entry.owner==mount {entry.active=false}
    }
}
