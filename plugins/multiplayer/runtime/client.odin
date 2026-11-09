package multiplayer

import "base:runtime"
import "core:hash"
import "core:hash/xxhash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:time"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/render"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import wire "mirai:net"

// The client half. Every replica the server creates gets an entity: taken
// from the scene by its Id, copied from the scene of its section where that
// section is not loaded here, made from the prefab it was spawned from, or
// bare.
// What the client is to a replica decides how it lives:
//
//   Interpolated  someone else's: its states go to an interpolation buffer and
//                 it heads where the buffer says, every tick (core.Pose_Target, Shown)
//   Predicted     the client's own, and what a simulation moves on the server:
//                 the client simulates them at its own tick, ahead of the
//                 server (core.Pose_Target, Simulated)
//   Here          lent to this client, or what each end simulates: simulated
//                 here and never corrected
//
// Prediction keeps, per tick, a copy of the whole world as the tick found it,
// the input of the tick and the pose each predicted replica had after it. A
// state of the server is compared with what was predicted for its tick. What
// differs and is within reach of what this client drives is critical: the
// world goes back to the copy of the next tick, takes the states of the server
// at their ticks and the fixed loop runs again up to the present. Anything
// else that differs is moved in the present by the error found, without
// simulating anything again.

@(private) INTERPOLATION_DEPTH :: 32
@(private) REPLICA_EXTRAPOLATION :: 0.1 // seconds an interpolated replica goes on with its last velocity when its states run out

@(private)
Action :: enum u8 {None,Blend,Rollback}

@(private)
Mode :: enum u8 {Here,Interpolated,Predicted}

// A predicted replica as the simulation has it now.
@(private)
Present :: struct {
    position:[3]f32,
    rotation:quaternion128,
    scale:[3]f32,
    linear,angular:[3]f32,
    asleep:bool,
}

// What was predicted of a replica after a tick: what the state of the server is compared with.
@(private)
Record :: struct {
    object:Object,
    position:[3]f32,
    rotation:quaternion128,
    scale:[3]f32,
    linear,angular:[3]f32,
    center:[3]f32, // of mass, in the frame of the body
    stamps,layouts:[wire.MAX_FRAGMENTS]u64,
    bindings:u64,
}

@(private)
Sample :: struct {pose:Pose,motion:Motion_State}

@(private)
Replica :: struct {
    object:Object, // zero: free
    entity:core.Entity,
    type:wire.Type_Id,
    role:Role,
    simulation:Simulation,
    mode:Mode,
    pending:bool,      // its newest state was not compared with the prediction yet
    adopted:bool,      // its entity was in the scene before the replica: it outlives it
    waits:bool,        // none of its sections is loaded here: it has no entity until one loads
    corrected:bool,    // it was alive when the correction under way began
    kept:bool,         // out of reach when the correction under way began: it stays as it was unless the correction reaches it
    exact:bool,        // the correction under way gave it the state of the server at its tick
    action:Action,     // what the comparison of this frame asks for
    touched_set,verified_set:bool,
    touched:u32,       // last tick it was within reach of what this client drives
    verified:u32,      // tick its newest state was last compared at
    check:u32,         // tick of the comparison that asked for the action
    slot:i32,          // of the interpolation buffer or of the prediction records; -1: none
    tick:u32,          // server tick of the newest state
    pose:Pose,         // the newest state; for a replica this client holds, the last one it sent
    motion:Motion_State,
    smoothing:wire.Smoothing,
    drifting:bool,     // an error it was not simulated again for is being closed, tick by tick
    drift:[3]f32,      // what of it is left: meters its position still moves
    twist:quaternion128, // and what its rotation still turns
    before:Present,
    held_hash:u64,     // of the components last sent for a replica this client holds
    available:u64,
    references:u64,
    authority_next,authority_count:int,
    delay:f32,         // interpolated: ticks it is shown behind the display, for its states come further apart; negative until known
}

// The world as a tick found it, with what else the tick started from.
@(private)
Frame :: struct {
    world:rawptr,
    marks:[]core.Copy_Mark, // what each table of the World was when it was last copied here
    tick:u32,
    valid:bool,
    whole:bool,        // the world was replaced since: the next copy is whole
    interpolation:f64, // server tick the interpolated replicas were placed at
    delays:[]Delay,    // by object index: ticks each interpolated replica was placed behind that one; -1 for the rest
    input:core.Input,
    content:u32, // host.content_generation the tick saw: it sees the same when it runs again
}

@(private)
Delay :: struct {object:Object,ticks:f32}

@(private)
Client :: struct {
    replicas:[]Replica, // by object index
    replica_high:int,
    words:[]u32,        // newest quantized state of every replica, words_per each
    words_per:int,
    interpolation:wire.Interpolation,
    history:int,        // slots of the rings that follow: the server's ticks of history plus one (history_make)
    frames:[]Frame,     // by tick modulo history
    records:[]Record,   // one row of predicted_capacity per tick of the history
    record_words:[]u32,
    authoritative:[]Authoritative,
    authoritative_words:[]u32,
    record_ticks:[]u32, // by tick modulo history: the tick of its row plus one
    record_free:[]i32,
    record_free_count:int,
    islands:[]u32,      // of what this client drives, by records_capture
    newest:u32,         // last tick simulated
    any:bool,
    silence:u32,        // ticks without news after which a replica at rest is taken as unchanged on the server
    quiet:u32,          // newest tick of the server that old; valid when quiet_set
    quiet_set:bool,
    bindings:u64,
    budget:f32,         // ticks this client may still simulate again
    frame_left:int,     // of them, in this frame
    sync_world:rawptr,  // with sync_test: the world as the first time left it
    sync_testing:bool,  // its ticks run again: the history keeps the copies of the first time
    sync_hashes:[]u64,  // by tick modulo history: one per table of what the tick left the last time it ran (the first, or a correction), then one of the simulation; last, those of the tick run again
    sync_fed:[]u64,     // likewise: a hash of what the network wrote into the tick, the last time it ran; last, the time it runs again
    fed:u64,            // what the network wrote into the tick under way, while sync_fed is kept
    connection:Connection, // its own, as the server names it
    seen:u32,           // the changes of the world it last saw (scene.Scene_Root)
    heard:bool,         // the server said which world it is in
    first:bool,         // that was the first world it heard since it connected
    frame_view:f64,     // the tick of the server the others were shown at when the input of this frame was taken
    frame_view_ok:bool,
    scene:base.Asset_Id, // of the server, and the number of its change
    changes:u32,
    asked:bool,         // it asked for that scene
    answered:bool,      // it told the server it is in that world
    player_told:bool,   // it told the server the player it is
    sections:[dynamic]base.Entity_Id, // the sections of the world it told the server it has
    sections_seen:[2]u64, // the version and the layout of scene.Scene_Reference it told them for
    waiting:int,        // replicas none of whose sections is loaded here
    sections_version:u64, // of scene.Scene_Reference, when the replicas last looked at their sections
}

@(private)
client_init :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App) -> bool {
    c:=&s.client
    d:=&s.desc
    allocator:=app.allocator
    c.words_per=s.protocol.object_words
    error:runtime.Allocator_Error
    if c.replicas,error=make([]Replica,d.max_objects,allocator);error!=nil {return false}
    if c.words,error=make([]u32,d.max_objects*c.words_per,allocator);error!=nil {return false}
    if c.record_free,error=make([]i32,d.predicted_capacity,allocator);error!=nil {return false}
    if c.islands,error=make([]u32,d.max_objects,allocator);error!=nil {return false}
    c.budget=f32(d.resimulate_budget)
    c.sections=make([dynamic]base.Entity_Id,allocator)
    if d.sync_test>0 {
        data,alloc_error:=mem.alloc(max(w.info.sizes[.World],1),max(w.info.aligns[.World],1),allocator)
        if alloc_error!=nil || data==nil {return false}
        c.sync_world=data
        if !w.info.init[.World](data,allocator) {return false}
        // What simulates outside the tables leaves a hash of it for the test.
        if check:=core.world_storage_of(w,core.Sync_Check);check!=nil {check.on=true}
    }
    for &slot,index in c.record_free {slot=i32(d.predicted_capacity-1-index)}
    c.record_free_count=d.predicted_capacity
    if !history_make(s,w,c,wire.host_history(&s.host)) {return false}
    return wire.interpolation_init(&c.interpolation,{state_size=size_of(Sample),capacity=d.max_objects,depth=INTERPOLATION_DEPTH,allocator=allocator})==.None
}

// The rings of a history of ticks, each with one slot more: the newest is the tick being
// written, and the whole history lies behind it. Allocated whole or not at all.
@(private)
history_make :: proc(s:^Net_Session,w:core.World_Ref,c:^Client,ticks:int) -> (ok:bool) {
    d:=&s.desc
    allocator:=s.allocator
    slots:=ticks+1
    c.history=slots
    error:runtime.Allocator_Error
    defer if !ok {history_free(s,c)}
    if c.frames,error=make([]Frame,slots,allocator);error!=nil {return false}
    for &frame in c.frames {
        data,alloc_error:=mem.alloc(max(w.info.sizes[.World],1),max(w.info.aligns[.World],1),allocator)
        if alloc_error!=nil || data==nil {return false}
        frame.world=data
        if !w.info.init[.World](data,allocator) {return false}
        if frame.marks,error=make([]core.Copy_Mark,len(w.info.tables),allocator);error!=nil {return false}
        if frame.delays,error=make([]Delay,d.max_objects,allocator);error!=nil {return false}
    }
    if c.records,error=make([]Record,slots*d.predicted_capacity,allocator);error!=nil {return false}
    if c.record_words,error=make([]u32,slots*d.predicted_capacity*c.words_per,allocator);error!=nil {return false}
    if c.authoritative,error=make([]Authoritative,slots*d.predicted_capacity,allocator);error!=nil {return false}
    if c.authoritative_words,error=make([]u32,slots*d.predicted_capacity*c.words_per,allocator);error!=nil {return false}
    if c.record_ticks,error=make([]u32,slots,allocator);error!=nil {return false}
    if d.sync_test>0 {
        if c.sync_hashes,error=make([]u64,(slots+1)*(len(w.info.tables)+1),allocator);error!=nil {return false}
        if c.sync_fed,error=make([]u64,slots+1,allocator);error!=nil {return false}
    }
    return true
}

@(private)
history_free :: proc(s:^Net_Session,c:^Client) {
    allocator:=s.allocator
    for &frame in c.frames {
        if frame.world!=nil {
            s.info.destroy[.World](frame.world)
            mem.free(frame.world,allocator)
        }
        delete(frame.marks,allocator)
        delete(frame.delays,allocator)
    }
    delete(c.frames,allocator)
    delete(c.records,allocator);delete(c.record_ticks,allocator)
    delete(c.record_words,allocator);delete(c.authoritative,allocator);delete(c.authoritative_words,allocator)
    delete(c.sync_hashes,allocator);delete(c.sync_fed,allocator)
    c.frames,c.records,c.record_ticks,c.record_words,c.authoritative,c.authoritative_words,c.sync_hashes,c.sync_fed=nil,nil,nil,nil,nil,nil,nil,nil
    c.history=0
}

// Takes the history the server announced when it accepted. A connection is a transaction:
// the rings are made again only here, and on failure the client keeps its own.
@(private)
history_follow :: proc(s:^Net_Session,w:core.World_Ref) -> bool {
    c:=&s.client
    ticks:=wire.host_history(&s.host)
    if ticks+1==c.history {return true}
    old:=c^
    if !history_make(s,w,c,ticks) {
        c^=old
        return false
    }
    history_free(s,&old)
    c.any=false
    return true
}

@(private)
client_destroy :: proc(s:^Net_Session) {
    c:=&s.client
    allocator:=s.allocator
    context.allocator=allocator
    history_free(s,c)
    if c.sync_world!=nil {
        s.info.destroy[.World](c.sync_world)
        mem.free(c.sync_world,allocator)
    }
    if c.interpolation.data!=nil {wire.interpolation_destroy(&c.interpolation)}
    delete(c.replicas,allocator);delete(c.words,allocator);delete(c.record_free,allocator)
    delete(c.islands,allocator);delete(c.sections)
    c^={}
}

@(private)
replica_of :: proc(s:^Net_Session,object:Object) -> ^Replica {
    c:=&s.client
    index:=object_index(object)
    if object==0 || index>=len(c.replicas) || c.replicas[index].object!=object {return nil}
    return &c.replicas[index]
}

@(private)
replica_words :: proc(s:^Net_Session,r:^Replica) -> []u32 {
    return s.client.words[object_index(r.object)*s.client.words_per:][:s.client.words_per]
}

// The newest state of a replica as a command object_read understands.
@(private)
replica_command :: proc(s:^Net_Session,r:^Replica) -> wire.Command {
    return {kind=.Object_Updated,type=r.type,object=r.object,tick=r.tick,mask=r.available,words=replica_words(s,r)}
}

@(private)
replica_state :: proc(s:^Net_Session,r:^Replica,command:^wire.Command) {
    copy(replica_words(s,r),command.words)
    r.available|=command.mask
    t:=net_type(s,r.type)
    wire.object_read(&s.host,command,0,&r.pose,max(u64))
    if t.motion>=0 {wire.object_read(&s.host,command,t.motion,&r.motion,max(u64))}
    r.tick=command.tick
    r.references=wire.object_references_pending(&s.host,command)
}

// The datagrams received since the last frame, as changes to the world and as events.
@(private)
client_commands :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,commands:[]wire.Command,events:^Net_Events) {
    for &command in commands {
        #partial switch command.kind {
        case .Connected:
            if !history_follow(s,w) {
                core.report(s.problems,core.NONE,"net.history","the history of %d ticks the server keeps was not made (out of memory), so this client keeps its own of %d; free memory, or lower Net_Settings.replication.history_seconds on the server",wire.host_history(&s.host),s.client.history-1)
            }
            s.status=.Connected
            s.joined+=1
            append(&s.arrived,Connection_Event{kind=.Connected,connection=command.connection})
        case .Disconnected:
            client_end(s,w,app,command.connection,command.reason,reason_text(command.reason,s.address,s.protocol.hash,app.allocator))
        case .Object_Created:
            replica_create(s,w,app,&command)
        case .Object_Updated:
            replica_update(s,w,app,&command)
        case .Object_Destroyed:
            replica_destroy(s,w,command.object,command.ended?.End:.Leave)
        case .Role_Changed:
            if r:=replica_of(s,command.object);r!=nil {
                r.role=command.role
                replica_classify(s,w,r)
            }
        case .Event:
            event_deliver(s,w,&command,events,nil)
        }
    }
    core.world_settle(w)
    if !s.ended {replicas_sections(s,w,app)}
    references_refresh(s,w)
    if !s.ended {client_world_update(s,w,app)}
}

// The replicas of entities of sections take the entity they have here as the
// sections load and drop (replica_place). Only when the sections change.
@(private)
replicas_sections :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App) {
    c:=&s.client
    references:=core.world_table_of(w,scene.Scene_Reference)
    if references==nil {return}
    version:=core.version(references)
    if version==c.sections_version {return}
    c.sections_version=version
    changed:=false
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 {continue}
        if r.pose.sections[0]!=0 {changed|=replica_place(s,w,app,&r)}
        // What a section turned on here stays off while the server's is.
        if r.pose.disabled && !r.waits && replica_turns(&r) {replica_turn(w,&r)}
    }
    if changed {core.world_settle(w)}
}

// The entity the replica of an entity of a section has here: none while
// none of its sections is loaded (it waits); the one the section it hangs
// from brought with its Id while that section is loaded; one of its own
// while only another section it is in is, or the one it hangs from no longer
// has it. An entity of a section that drops it, dormant or gone, is not the
// replica's any more. True when it changed.
@(private)
replica_place :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,r:^Replica) -> bool {
    c:=&s.client
    home:=r.pose.sections[0]==0 || section_loaded(w,r.pose.sections[0])
    near:=home
    for id in r.pose.sections[1:] {near||=id!=0 && section_loaded(w,id)}
    if !r.waits && core.alive(core.world_entities(w),r.entity) {
        if r.adopted {
            if home {return false}
            // Taken by the server out of a section loaded here, it goes; one whose section dropped it sleeps there.
            references:=core.world_table_of(w,scene.Scene_Reference)
            section:=section_of(core.ref(core.world_storage_of(w,core.Hierarchy)),references,r.entity)
            loaded:=section==core.NONE
            if !loaded && references!=nil {
                reference,_:=core.get(core.read(references),section)
                loaded=reference.loaded!={}
            }
            if loaded {
                core.world_destroy_tree(w,r.entity)
                s.stats.despawned+=1
            } else {
                replica_unlink(w,r.entity)
            }
        } else {
            if near && (!home || replica_adoptable(s,w,r)==core.NONE) {return false}
            core.world_destroy_tree(w,r.entity)
            s.stats.despawned+=1
        }
    }
    if !r.waits {
        slot_release(s,r)
        wire.object_bind(&s.host,r.object,0)
        r.entity,r.adopted,r.mode,r.waits=core.NONE,false,.Here,true
        c.waiting+=1
    }
    if near {
        r.waits=false
        c.waiting-=1
        replica_spawn(s,w,app,r)
        replica_classify(s,w,r)
    }
    return true
}

// The entity of the scene a replica takes: the one with its Id that hangs in
// the section it hangs from, loaded here, and that no live replica holds.
@(private)
replica_adoptable :: proc(s:^Net_Session,w:core.World_Ref,r:^Replica) -> core.Entity {
    home:=r.pose.sections[0]
    if home!=0 && !section_loaded(w,home) {return core.NONE}
    e:=entity_of_id(s,w,r.pose.id)
    if e==core.NONE {return core.NONE}
    section:=section_of(core.ref(core.world_storage_of(w,core.Hierarchy)),core.world_table_of(w,scene.Scene_Reference),e)
    if core.id_of(core.read(core.world_table_of(w,core.Id)),section)!=home {return core.NONE}
    return e
}

@(private)
replica_create :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,command:^wire.Command) {
    c:=&s.client
    index:=object_index(command.object)
    if index>=len(c.replicas) {
        core.report(s.problems,core.NONE,"net.replicas","the server replicates object %d, and this client has room for %d (Net_Settings.max_objects); give the clients as many max_objects as their server",index,len(c.replicas))
        return
    }
    if !net_type(s,command.type).fits {
        core.report(s.problems,core.NONE,"net.replicas","the server replicates object %d with more replicated components than an object carries (%d); the server is of another build",index,COMPONENTS)
        return
    }
    r:=&c.replicas[index]
    // A slot handed out again without news of its end: what each end simulates, and ends by itself.
    if r.object!=0 {replica_destroy(s,w,r.object,r.simulation!=.Each?.End:.Forget)}
    r^={object=command.object,type=command.type,role=command.role,simulation=command.simulation,slot=-1,entity=core.NONE,waits=true}
    c.waiting+=1
    wire.smoothing_init(&r.smoothing)
    c.replica_high=max(c.replica_high,index+1)
    replica_state(s,r,command)
    replica_place(s,w,app,r)
    if r.waits {return}
    authoritative_capture(s,r,command)
}

// The entity of the scene with a persistent id that no live replica holds.
@(private)
entity_of_id :: proc(s:^Net_Session,w:core.World_Ref,id:base.Entity_Id) -> core.Entity {
    e:=core.entity_of(core.world_entities(w),id)
    if e==core.NONE {return core.NONE}
    for &x in s.client.replicas[:s.client.replica_high] {
        if x.object!=0 && x.entity==e {return core.NONE}
    }
    return e
}

// Gives a replica its entity, with everything the server last said of it.
@(private)
replica_spawn :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,r:^Replica) {
    t:=net_type(s,r.type)
    es:=core.world_entities(w)
    transforms:=core.world_table_of(w,core.Transform)
    e:=replica_adoptable(s,w,r)
    r.adopted=e!=core.NONE
    if e==core.NONE {
        local:=core.Transform{r.pose.position,r.pose.rotation,r.pose.scale}
        // Where its section is not loaded, a copy of it from the scene of that section.
        if home:=r.pose.sections[0];home!=0 && r.pose.id!=0 {
            if references:=core.world_table_of(w,scene.Scene_Reference);references!=nil {
                if reference,found:=core.get(core.read(references),core.entity_of(es,home));found && reference.scene!={} {
                    if report,error:=scene.spawn_member(core.commands_of(w),app,reference.scene,home,r.pose.id,local);error==.None {e=report.root}
                }
            }
        }
        if e==core.NONE && r.pose.prefab!={} {
            e=scene.spawn(scene.Spawner{core.commands_of(w),app,core.world_storage_of(w,core.Problems)},r.pose.prefab,local,transient=true)
        }
        if e==core.NONE {
            e=core.create(es)
            core.add(transforms,e,local)
        }
    }
    // Its rows wait for the end of the function: what follows writes them where they wait.
    replicate:=REPLICATE_DEFAULT
    replicate.simulation=r.simulation
    core.add(core.world_table_of(w,Replicate),e,replicate)
    core.add(core.world_table_of(w,Net_Link),e,Net_Link{object=r.object})
    r.entity=e
    wire.object_bind(&s.host,r.object,u64(e))
    command:=replica_command(s,r)
    components_apply(s,w,e,t,&command,r.available)
    // A body that is made with the next step takes its pose and its velocities from the replica.
    pose_apply(s,w,e,t,r.pose,r.motion,false)
    replica_turn(w,r)
    s.stats.spawned+=1
}

// What the server keeps turning on and off: not what this client holds, nor
// what each end simulates past its creation.
@(private)
replica_turns :: #force_inline proc "contextless" (r:^Replica) -> bool {return r.role!=.Held && r.simulation!=.Each}

// The entity of a replica is off while the server's is (Pose.disabled),
// whatever it was here: the network gives it Disabled or takes it back. What
// its section turned off here (scene.Section_Held) is left to the section,
// and so is what the network turned off in a section loaded and off here.
@(private)
replica_turn :: proc(w:core.World_Ref,r:^Replica) {
    disabled,held:=core.world_table_of(w,core.Disabled),core.world_table_of(w,scene.Section_Held)
    e:=r.entity
    if disabled==nil || !core.alive(core.world_entities(w),e) {return}
    off:=row_staged(core.raw(disabled),e)
    switch {
    case r.pose.disabled && !off:
        core.add(disabled,e,core.Disabled{})
    case !r.pose.disabled && off && (held==nil || !row_staged(core.raw(held),e)):
        if held!=nil && section_holding(w,e) {core.add(held,e,scene.Section_Held{})} else {core.remove(disabled,e)}
    }
}

// Whether e has a row of t at the end of the function: its last pending add
// or remove says, or else its row.
@(private)
row_staged :: proc "contextless" (t:^core.Raw_Table,e:core.Entity) -> bool {
    #reverse for p in t.pending {
        if p.entity!=e || p.value==core.PENDING_OFF || p.value==core.PENDING_ON {continue}
        return p.value!=core.PENDING_REMOVE
    }
    return core.raw_row(t,e)>=0
}

// Whether e hangs from a section loaded and off here: what that turns off
// (scene.Section_Held) it turns on with it.
@(private)
section_holding :: proc(w:core.World_Ref,e:core.Entity) -> bool {
    references:=core.world_table_of(w,scene.Scene_Reference)
    if references==nil {return false}
    reference,found:=core.get(core.read(references),core.parent_of(core.ref(core.world_storage_of(w,core.Hierarchy)),e))
    return found && reference.loaded!={} && reference.held
}

@(private)
slot_release :: proc(s:^Net_Session,r:^Replica) {
    c:=&s.client
    if r.slot>=0 {
        switch r.mode {
        case .Here:
        case .Interpolated:
            wire.interpolation_remove(&c.interpolation,int(r.slot))
        case .Predicted:
            c.record_free[c.record_free_count]=r.slot
            c.record_free_count+=1
        }
    }
    r.slot=-1
}

// Decides how the client treats a replica from its simulation and its role:
// what a simulation moves on the server is predicted.
@(private)
replica_classify :: proc(s:^Net_Session,w:core.World_Ref,r:^Replica) {
    c:=&s.client
    mode:=Mode.Interpolated
    switch {
    case r.simulation==.Each || r.role==.Held:                  mode=.Here
    case r.role==.Predicted:                                    mode=.Predicted
    case r.simulation==.Server && net_type(s,r.type).motion>=0 && !s.desc.interpolate_others: mode=.Predicted
    }
    if mode==.Predicted && c.record_free_count==0 {
        core.report(s.problems,r.entity,"net.predicted","this replica is shown interpolated instead of predicted: the %d replicas of Net_Settings.predicted_capacity are predicted already; raise predicted_capacity",s.desc.predicted_capacity)
        mode=.Interpolated
    }
    alive:=core.alive(core.world_entities(w),r.entity)
    if mode==r.mode && (r.slot>=0 || mode==.Here) {
        if alive {replica_components(s,w,r,mode)}
        return
    }
    slot_release(s,r)
    r.authority_next,r.authority_count=0,0
    r.mode,r.pending=mode,false
    switch mode {
    case .Here:
        // What the client holds starts from where it was being shown.
        if local,has:=core.get(core.read(core.world_table_of(w,core.Transform)),r.entity);has {
            r.pose.position,r.pose.rotation,r.pose.scale=local.position,local.rotation,local.scale
        }
    case .Interpolated:
        r.delay=-1
        if slot,ok:=wire.interpolation_add(&c.interpolation);ok {
            r.slot=i32(slot)
            replica_sample(s,r)
        }
    case .Predicted:
        c.record_free_count-=1
        r.slot=c.record_free[c.record_free_count]
        wire.smoothing_init(&r.smoothing)
        r.verified_set,r.touched_set=false,false
        command:=replica_command(s,r)
        authoritative_capture(s,r,&command)
    }
    if alive {replica_components(s,w,r,mode)}
}

// The components the network gives a replica for its mode and its role:
// core.Pose_Target for what the server decides, core.Remote for what this client
// neither predicts nor holds, Draw_Offset when it hides corrections.
@(private)
replica_components :: proc(s:^Net_Session,w:core.World_Ref,r:^Replica,mode:Mode) {
    e:=r.entity
    remote_set(core.world_table_of(w,core.Remote),e,r.role!=.Predicted && r.role!=.Held)
    replicas:=core.world_table_of(w,core.Pose_Target)
    held:=core.staged(replicas,e)
    switch mode {
    case .Here:
        if held!=nil {core.remove(replicas,e)}
    case .Interpolated,.Predicted:
        follow:=mode!=.Predicted
        if held==nil {
            pose_apply(s,w,e,net_type(s,r.type),r.pose,r.motion,follow)
        } else if held.follow!=follow {
            held.follow=follow
        }
    }
    offsets:=core.world_table_of(w,render.Draw_Offset)
    if mode==.Predicted && !core.has(offsets,e) && core.added(offsets,e)==nil {core.add(offsets,e,render.Draw_Offset{rotation=1})}
    if replica_turns(r) {replica_turn(w,r)}
}

// Without a replicated velocity a state takes the one from the state before:
// what the replica goes on with when its states run out.
@(private)
replica_sample :: proc(s:^Net_Session,r:^Replica) {
    c:=&s.client
    sample:=Sample{r.pose,r.motion}
    if net_type(s,r.type).motion<0 {
        if before,tick,ok:=wire.interpolation_newest(&c.interpolation,int(r.slot));ok && i32(r.tick-tick)>0 {
            last:=(^Sample)(raw_data(before))
            seconds:=f32(r.tick-tick)/f32(s.host.desc.tick_rate)
            sample.motion.linear=(r.pose.position-last.pose.position)/seconds
            sample.motion.angular=rotation_rate(last.pose.rotation,r.pose.rotation,seconds)
        }
    }
    wire.interpolation_push(&c.interpolation,int(r.slot),r.tick,mem.ptr_to_bytes(&sample))
}

// The angular velocity, in rad/s about world axes, that turns from into to in seconds.
@(private)
rotation_rate :: proc "contextless" (from,to:quaternion128,seconds:f32) -> [3]f32 {
    q:=to*conj(from)
    if q.w<0 {q=-q}
    axis:=[3]f32{q.x,q.y,q.z}
    length:=math.sqrt(axis.x*axis.x+axis.y*axis.y+axis.z*axis.z)
    if length<1e-6 || seconds<=0 {return {}}
    return axis/length*(2*math.atan2(length,q.w)/seconds)
}

@(private)
replica_update :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,command:^wire.Command) {
    r:=replica_of(s,command.object)
    if r==nil {return}
    sections:=r.pose.sections
    replica_state(s,r,command)
    if r.pose.sections!=sections {replica_place(s,w,app,r)}
    if r.waits {return}
    authoritative_capture(s,r,command)
    if core.alive(core.world_entities(w),r.entity) {
        components_apply(s,w,r.entity,net_type(s,r.type),command,command.mask)
        if replica_turns(r) {replica_turn(w,r)}
    }
    switch r.mode {
    case .Here:
    case .Interpolated: replica_sample(s,r)
    case .Predicted:    r.pending=true
    }
}

@(private)
End :: enum u8 {
    Forget, // the entity lives on by itself: what each end simulates
    Leave,  // the replica left what this client sees, or the connection ended: an entity of the scene stays as it is
    End,    // the object is gone on the server
}

@(private)
replica_destroy :: proc(s:^Net_Session,w:core.World_Ref,object:Object,end:End) {
    r:=replica_of(s,object)
    if r==nil {return}
    es:=core.world_entities(w)
    if (end==.End || end==.Leave && !r.adopted) && core.alive(es,r.entity) {
        // The parts the prefab of the replica brought go with it.
        core.world_destroy_tree(w,r.entity)
        s.stats.despawned+=1
    } else if core.alive(es,r.entity) {
        replica_unlink(w,r.entity)
    }
    if r.waits {s.client.waiting-=1}
    slot_release(s,r)
    r^={}
}

// An entity of the scene that a replica lets go of keeps nothing of the network.
@(private)
replica_unlink :: proc(w:core.World_Ref,e:core.Entity) {
    core.remove(core.world_table_of(w,Net_Link),e)
    core.remove(core.world_table_of(w,core.Pose_Target),e)
    core.remove(core.world_table_of(w,core.Remote),e)
    core.remove(core.world_table_of(w,render.Draw_Offset),e)
}

// Forgets every copy of the world: there is nothing to go back to until new ticks run.
@(private)
history_reset :: proc(s:^Net_Session) {
    c:=&s.client
    if !c.any {return}
    c.any=false
    for &frame in c.frames {frame.valid=false}
    mem.zero_slice(c.record_ticks)
    s.stats.history_resets+=1
}

// Keeps the tick of the world on the clock of the connection. The clock of
// the world (Time.tick and the time of the frames its ticks have not
// simulated) is the client's tick: the network clock says how much faster or
// slower than the frames its ticks run, and moves it forward when it is far
// behind. None runs until the server answered. How far behind the display an
// interpolated replica is shown follows how far apart its states come, as
// slowly as the display may change its pace.
@(private)
client_clock :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App) {
    clock,frame:=core.world_storage_of(w,core.Time),core.world_storage_of(w,core.Frame_Time)
    if clock==nil || frame==nil {return}
    h:=&s.host
    last:=wire.clock_state(h)
    local:=f64(clock.tick)-1+frame.accumulator/f64(app.tick_dt)
    shift,dilation:=wire.clock_advance(h,s.now,local)
    frame.dilation=f32(dilation)
    state:=wire.clock_state(h)
    if !state.synced {return}
    // The server pauses and scales the time of the session.
    clock_follow(w,state.paused,state.scale)
    if !last.placed || shift!=0 {
        clock.tick=u64(max(i64(clock.tick)+shift,0))
        history_reset(s)
    }
    ran:=last.placed?max(f32(local-last.local),0):0
    c:=&s.client
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || r.mode!=.Interpolated || r.slot<0 {continue}
        spacing:=wire.interpolation_spacing(&c.interpolation,int(r.slot))
        if spacing==0 {continue}
        wanted:=max(spacing-1,0)
        r.delay=r.delay<0?wanted:r.delay+clamp(wanted-r.delay,-ran*0.1,ran*0.1)
    }
}

// What tick head does: the copy of the world as the tick found it, then the
// interpolated replicas go where the buffer has them at a server tick, so
// what the client simulates meets them there.
@(private)
client_head :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,tick:u32,resimulating:bool) {
    c:=&s.client
    c.fed=0
    input:=core.world_storage_of(w,core.Input)
    frame:=&c.frames[int(tick)%len(c.frames)]
    if !resimulating {
        if c.any && tick!=c.newest+1 {history_reset(s)}
        started:=time.tick_now()
        frame.interpolation=wire.clock_interpolation_tick(&s.host,tick)
        for &r,index in c.replicas[:c.replica_high] {frame.delays[index]={r.object,r.mode==.Interpolated?r.delay:-1}}
        frame.valid=false
        if frame_copy(w,frame) {
            frame.tick,frame.valid=tick,true
            if input!=nil {frame.input=input^}
            frame.content=host.content_generation(app)
        } else {snapshot_problem(s,tick)}
        s.stats.snapshot_seconds+=time.duration_seconds(time.tick_since(started))
        drifts_apply(s,w,app.tick_dt)
    } else if frame.tick==tick && !c.sync_testing {
        if !frame_copy(w,frame) {frame.valid=false;snapshot_problem(s,tick)}
    }
    client_place(s,w,frame.interpolation,frame.delays)
    client_inputs(s,w,tick)
    s.taken=s.placed
    if c.sync_fed!=nil {c.sync_fed[c.sync_testing?len(c.frames):int(tick)%len(c.frames)]=c.fed}
}

// What the network writes into the tick under way goes into a hash while
// SyncTest keeps them: it compares only the ticks given the same both times.
@(private)
feed :: proc(c:^Client,value:$T) {
    value:=value
    feed_bytes(c,mem.ptr_to_bytes(&value))
}

@(private)
feed_bytes :: proc(c:^Client,bytes:[]u8) {
    if c.sync_fed!=nil {c.fed=xxhash.XXH3_64_with_seed(bytes,c.fed)}
}

@(private)
feed_state :: proc(c:^Client,object:Object,pose:Pose,motion:Motion_State) {
    if c.sync_fed==nil {return}
    feed(c,object);feed(c,pose.position);feed(c,pose.rotation);feed(c,pose.scale);feed(c,pose.off)
    feed(c,motion.linear);feed(c,motion.angular)
}

// The world into a slot of the history, copying again only what changed
// since the slot was last written.
@(private)
frame_copy :: proc(w:core.World_Ref,frame:^Frame) -> bool {
    if w.info.copy_changed==nil {return w.info.copy(frame.world,w.data)}
    // Marks of no copy: every table again.
    if frame.whole {mem.zero_slice(frame.marks)}
    if !w.info.copy_changed(frame.world,w.data,frame.marks) {return false}
    frame.whole=false
    return true
}

@(private)
snapshot_problem :: proc(s:^Net_Session,tick:u32) {
    core.report(s.problems,core.NONE,"net.snapshot","the copy of the world at tick %d was not made (out of memory), so a correction of the server cannot go back to it; free memory, or lower Net_Settings.replication.history_seconds",tick)
}

// The interpolated replicas go where the buffer has them at a server tick,
// each as far behind it as delays says it was when the tick ran first (by
// object index); one that did not exist then, as far as its states come apart now.
@(private)
client_place :: proc(s:^Net_Session,w:core.World_Ref,tick:f64,delays:[]Delay) {
    c:=&s.client
    es:=core.world_entities(w)
    for &r,index in c.replicas[:c.replica_high] {
        if r.object==0 || r.mode!=.Interpolated || !core.alive(es,r.entity) || core.entity_off(es,r.entity) {continue}
        delay:=index<len(delays) && delays[index].object==r.object?delays[index].ticks:r.delay
        if sample,ok:=replica_blend(s,&r,tick-f64(max(delay,0)));ok {
            feed_state(c,r.object,sample.pose,sample.motion)
            pose_follow(s,w,r.entity,net_type(s,r.type),sample.pose,sample.motion)
        }
    }
}

// The state of a replica at a server tick: between the two around it, or past
// the newest one with its velocity for a while and then still.
@(private)
replica_blend :: proc(s:^Net_Session,replica:^Replica,tick:f64) -> (out:Sample,ok:bool) {
    from,to,alpha,status:=wire.interpolation_sample(&s.client.interpolation,int(replica.slot),tick)
    a:Sample
    switch status {
    case .Empty: return
    case .Before:
        mem.copy(&out,raw_data(to),size_of(Sample))
        return out,true
    case .After:
        mem.copy(&out,raw_data(to),size_of(Sample))
        rate:=f32(s.host.desc.tick_rate)
        seconds:=min(alpha,REPLICA_EXTRAPOLATION*rate)/rate
        out.pose.position+=out.motion.linear*seconds
        if turn:=linalg.length(out.motion.angular);turn>0 {
            out.pose.rotation=linalg.normalize(mm.quat_axis_angle(out.motion.angular/turn,turn*seconds)*out.pose.rotation)
        }
        return out,true
    case .Between:
        mem.copy(&a,raw_data(from),size_of(Sample))
        mem.copy(&out,raw_data(to),size_of(Sample))
    }
    out.pose.position=a.pose.position+(out.pose.position-a.pose.position)*alpha
    out.pose.scale=a.pose.scale+(out.pose.scale-a.pose.scale)*alpha
    p,q:=a.pose.rotation,out.pose.rotation
    sign:=p.x*q.x+p.y*q.y+p.z*q.z+p.w*q.w<0?f32(-1):1
    x,y,z,m:=p.x+(q.x*sign-p.x)*alpha,p.y+(q.y*sign-p.y)*alpha,p.z+(q.z*sign-p.z)*alpha,p.w+(q.w*sign-p.w)*alpha
    length:=math.sqrt(x*x+y*y+z*z+m*m)
    if length>0 {out.pose.rotation=quaternion(w=m/length,x=x/length,y=y/length,z=z/length)}
    out.motion.linear=a.motion.linear+(out.motion.linear-a.motion.linear)*alpha
    out.motion.angular=a.motion.angular+(out.motion.angular-a.motion.angular)*alpha
    return out,true
}

// Every frame, before the transforms are propagated: the error a correction
// left on a predicted replica fades. The interpolated ones move in the ticks,
// and the frame draws them between the last two like everything else.
@(private)
client_frame :: proc(s:^Net_Session,w:core.World_Ref,dt:f32) {
    c:=&s.client
    es:=core.world_entities(w)
    offsets:=core.world_table_of(w,render.Draw_Offset)
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || r.mode!=.Predicted || !core.alive(es,r.entity) {continue}
        wire.smoothing_update(&r.smoothing,dt)
        shown:=core.get(offsets,r.entity)
        if shown==nil {continue}
        shown.offset,shown.rotation=r.smoothing.offset,r.smoothing.rotation
    }
}

// After a tick: what this client holds the authority of goes to the server,
// and the pose of every predicted replica is remembered to compare with the
// state of the server.
@(private)
client_tail :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,tick:u32,outbox:^Net_Outbox) {
    c:=&s.client
    h:=&s.host
    c.newest,c.any=tick,true
    records_capture(s,w,tick)
    if s.desc.sync_test>0 {
        // What the tick left, settled as a tick run again leaves it.
        core.world_settle(w)
        sync_hashes(s,w,c.sync_hashes[(int(tick)%s.client.history)*(len(w.info.tables)+1):][:len(w.info.tables)+1])
    }
    if s.status==.Connected {
        packet:=Input_Packet{actions=driven_actions(s,w)}
        look:[2]f32
        look,packet.has_look=driven_look(w)
        packet.look_yaw,packet.look_pitch=mm.angle_wrap(look[0]),look[1]
        // What the others looked like on this player's screen when the input of this frame was
        // taken (frame_view_take): every tick of the frame runs that input.
        view,shown:=shown_tick(s,w,tick)
        if c.frame_view_ok {view=c.frame_view}
        if shown {
            packet.view_behind=f32(clamp(f64(tick)-view,0,255))
            packet.has_view=true
        }
        wire.input_submit(h,tick,&packet)
    }
    client_upload(s,w)
    events_send(s,outbox)
    wire.host_publish(h,tick)
}

// What each predicted replica is after a tick (replica_now: a correction that
// just put it at the state of the server of the tick is that state), and
// which of them share a group of the simulation (core.Motion.island) with
// what this client drives: what touches it or is joined to it now.
@(private)
records_capture :: proc(s:^Net_Session,w:core.World_Ref,tick:u32) {
    c:=&s.client
    d:=&s.desc
    motions:=core.world_table_of(w,core.Motion)
    es:=core.world_entities(w)
    c.record_ticks[int(tick)%c.history]=tick+1
    row:=c.records[(int(tick)%c.history)*d.predicted_capacity:][:d.predicted_capacity]
    islands:=0
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || r.role!=.Predicted && r.role!=.Held || !core.alive(es,r.entity) {continue}
        if motion,has:=core.get(core.read(motions),r.entity);has && motion.island!=0 && islands<len(c.islands) {
            c.islands[islands]=motion.island
            islands+=1
        }
    }
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || !core.alive(es,r.entity) {continue}
        motion,has_motion:=core.get(core.read(motions),r.entity)
        if has_motion && motion.island!=0 {
            for island in c.islands[:islands] {
                if island==motion.island {r.touched,r.touched_set=tick,true;break}
            }
        }
        if r.mode!=.Predicted || r.slot<0 {continue}
        record:=&row[r.slot]
        record^={}
        now,has_pose:=replica_now(s,w,&r)
        if !has_pose {continue}
        record^={object=r.object,position=now.position,rotation=now.rotation,scale=now.scale,linear=now.linear,angular=now.angular,center=motion.center}
        // What is still being closed is part of what the server should have.
        if r.drifting {record.position,record.rotation=record.position+r.drift,linalg.normalize(r.twist*record.rotation)}
        record_components(s,w,&r,tick)
    }
}

// The state of what this client holds goes to the server.
@(private)
client_upload :: proc(s:^Net_Session,w:core.World_Ref) {
    c:=&s.client
    es:=core.world_entities(w)
    transforms:=core.world_table_of(w,core.Transform)
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || r.role!=.Held || !core.alive(es,r.entity) {continue}
        t:=net_type(s,r.type)
        local,has_pose:=core.get(core.read(transforms),r.entity)
        if !has_pose {continue}
        pose:=Pose{id=r.pose.id,prefab=r.pose.prefab,sections=r.pose.sections,position=local.position,rotation=local.rotation,scale=local.scale,off=components_off(w,r.entity,t)}
        motion,_:=motion_read(w,r.entity)
        if pose!=r.pose {
            r.pose=pose
            wire.object_write(&s.host,r.object,0,&pose)
        }
        if t.motion>=0 && motion!=r.motion {
            r.motion=motion
            wire.object_write(&s.host,r.object,t.motion,&motion)
        }
        held_hash:=u64(0xcbf29ce484222325)
        for k in 0..<t.count {
            info:=&w.info.tables[t.tables[k]]
            if value:=core.raw_find(core.world_table_at(w,info),info.info,r.entity);value!=nil {held_hash=hash.fnv64a(mem.byte_slice(value,info.info.size),held_hash)}
        }
        if held_hash==r.held_hash {continue}
        r.held_hash=held_hash
        for k in 0..<t.count {
            info:=&w.info.tables[t.tables[k]]
            if value:=core.raw_find(core.world_table_at(w,info),info.info,r.entity);value!=nil {wire.object_write(&s.host,r.object,t.first+k,value)}
        }
    }
}

@(private)
resting :: #force_inline proc "contextless" (motion:^Motion_State) -> bool {return motion.linear=={} && motion.angular=={}}

// Whether the newest state of a replica says what the server had after a
// tick: it is of that tick, or it is one of rest that old enough news confirm.
@(private)
replica_known :: proc(c:^Client,x:^Replica,tick:u32) -> bool {
    if x.tick==tick {return true}
    return i32(tick-x.tick)>0 && resting(&x.motion) && c.quiet_set && i32(c.quiet-tick)>=0
}

// Within reach of what this client drives around a tick: only a new
// simulation says what a correction of it does to the rest.
@(private)
replica_critical :: proc(d:^Net_Settings,x:^Replica,tick:u32) -> bool {
    return x.role==.Predicted || x.touched_set && i32(x.touched-tick)>=-i32(d.critical_ticks)
}

// What was predicted of a replica for a tick; kept is false when the tick left the history.
@(private)
record_of :: proc(c:^Client,d:^Net_Settings,x:^Replica,tick:u32) -> (record:^Record,kept:bool) {
    if c.record_ticks[int(tick)%c.history]!=tick+1 {return nil,false}
    record=&c.records[(int(tick)%c.history)*d.predicted_capacity+int(x.slot)]
    return record.object==x.object?record:nil,true
}

// Positions are compared where the mass of the body is: the frame of a group of pieces is far from them.
@(private)
record_differs :: proc(d:^Net_Settings,body:bool,record:^Record,pose:^Pose,motion:^Motion_State) -> bool {
    apart:=record.position-pose.position
    if body {apart+=mm.quat_rotate(record.rotation,record.center)-mm.quat_rotate(pose.rotation,record.center)}
    if linalg.length2(apart)>d.position_tolerance*d.position_tolerance {return true}
    if linalg.length2(record.scale-pose.scale)>d.scale_tolerance*d.scale_tolerance {return true}
    p,q:=record.rotation,pose.rotation
    if abs(p.x*q.x+p.y*q.y+p.z*q.z+p.w*q.w)<math.cos(d.rotation_tolerance*0.5) {return true}
    if !body {return false}
    if linalg.length2(record.linear-motion.linear)>d.velocity_tolerance*d.velocity_tolerance {return true}
    if linalg.length2(record.angular-motion.angular)>d.velocity_tolerance*d.velocity_tolerance {return true}
    return false
}

@(private)
replica_now :: proc(s:^Net_Session,w:core.World_Ref,x:^Replica) -> (now:Present,ok:bool) {
    local,has_pose:=core.get(core.read(core.world_table_of(w,core.Transform)),x.entity)
    if !has_pose {return}
    // A place the simulation takes with the next tick is where the replica is for the network already.
    if asked:=core.staged(core.world_table_of(w,core.Pose_Target),x.entity);asked!=nil && i32(asked.placed-s.taken)>0 {
        return {position=asked.position,rotation=asked.rotation,scale=asked.scale,linear=asked.linear,angular=asked.angular,asleep=asked.rest},true
    }
    motion,awake:=motion_read(w,x.entity)
    return {position=local.position,rotation=local.rotation,scale=local.scale,linear=motion.linear,angular=motion.angular,asleep=!awake},true
}

@(private)
replica_put :: proc(s:^Net_Session,w:core.World_Ref,x:^Replica,to:^Present) {
    local,has_pose:=core.get(core.read(core.world_table_of(w,core.Transform)),x.entity)
    if !has_pose {return}
    pose:=Pose{position=to.position,rotation=to.rotation,scale=to.scale}
    motion:=x.motion
    motion.linear,motion.angular=to.linear,to.angular
    pose_apply(s,w,x.entity,net_type(s,x.type),pose,motion,false,to.asleep)
}

// The records of a replica after a tick follow a change made to its present.
@(private)
records_shift :: proc(s:^Net_Session,x:^Replica,after:u32,dp,rate:[3]f32,dq:quaternion128,dv,dw:[3]f32,tick_dt:f32) {
    c:=&s.client
    for tick:=after+1;i32(c.newest-tick)>=0;tick+=1 {
        record:=record_of(c,&s.desc,x,tick) or_continue
        if record==nil {continue}
        record.position+=dp+rate*(f32(tick-after)*tick_dt)
        record.rotation=linalg.normalize(dq*record.rotation)
        record.linear+=dv
        record.angular+=dw
    }
}

// A replica that differs from the server and is not simulated again. Its
// velocity takes the error of velocity at once, and the error of pose, carried
// to the present, is closed over the next ticks (drifts_apply): neither moves
// it through what it touches. A body the server has at rest goes to that pose
// and sleeps, and so does an error too large to close: past the distance at
// which the smoothing of the drawing gives up.
@(private)
replica_adjust :: proc(s:^Net_Session,w:core.World_Ref,x:^Replica,tick_dt:f32) {
    c:=&s.client
    record,_:=record_of(c,&s.desc,x,x.check)
    now,alive:=replica_now(s,w,x)
    if record==nil || !alive {return}
    t:=net_type(s,x.type)
    body:=t.motion>=0
    pose,motion:=x.pose,x.motion
    if command,found:=authoritative_command(s,x,x.check,true);found {
        wire.object_read(&s.host,&command,0,&pose,max(u64))
        if t.motion>=0 {wire.object_read(&s.host,&command,t.motion,&motion,max(u64))}
        components_apply(s,w,x.entity,t,&command,command.mask)
    }
    wanted:=now
    wanted.scale=pose.scale
    placed:=true
    if body && resting(&motion) {
        wanted={position=pose.position,rotation=pose.rotation,scale=pose.scale,asleep=true}
        x.drifting=false
        for tick:=x.check+1;i32(c.newest-tick)>=0;tick+=1 {
            if later,_:=record_of(c,&s.desc,x,tick);later!=nil {later.position,later.rotation,later.linear,later.angular=wanted.position,wanted.rotation,{},{}}
        }
    } else {
        dp:=pose.position-record.position
        dv:=body?motion.linear-record.linear:{}
        dw:=body?motion.angular-record.angular:{}
        dq:=linalg.normalize(pose.rotation*conj(record.rotation))
        error:=dp+dv*(f32(i32(c.newest-x.check))*tick_dt)
        records_shift(s,x,x.check,dp,dv,dq,dv,dw,tick_dt)
        wanted.linear+=dv
        wanted.angular+=dw
        wanted.asleep=false
        if !x.drifting {x.drift,x.twist={},1}
        x.drift+=error
        x.twist=linalg.normalize(dq*x.twist)
        x.drifting=true
        placed=linalg.length2(x.drift)>x.smoothing.snap_distance*x.smoothing.snap_distance
        if placed {
            wanted.position+=x.drift
            wanted.rotation=linalg.normalize(x.twist*now.rotation)
            x.drifting=false
        }
    }
    replica_put(s,w,x,&wanted)
    for tick:=x.check+1;i32(c.newest-tick)>=0;tick+=1 {
        if later,_:=record_of(c,&s.desc,x,tick);later!=nil {later.scale=wanted.scale}
    }
    core.world_settle(w)
    if placed {
        wire.smoothing_correct(&x.smoothing,now.position,wanted.position,now.rotation,wanted.rotation)
        s.stats.placed+=1
    }
    s.stats.blended+=1
}

// A state of the server older than the history: there is no prediction of its
// tick to compare it with (the client ran too far ahead of the server, as after
// the server stopped and dropped ticks), but it is still the newest news of the
// replica. Without it the replica would go on predicted with nothing to correct
// it until the clock came back within the history, seconds later. It goes where
// the server had it, carried to the present by its velocity, and the drawing
// closes the jump by its smoothing.
@(private)
replica_overtaken :: proc(s:^Net_Session,w:core.World_Ref,x:^Replica,tick:u32,mask:u64,words:[]u32,tick_dt:f32) {
    c:=&s.client
    now,alive:=replica_now(s,w,x)
    if !alive {return}
    t:=net_type(s,x.type)
    command:=wire.Command{kind=.Object_Updated,type=x.type,object=x.object,tick=tick,mask=mask,words=words}
    pose:Pose
    motion:Motion_State
    wire.object_read(&s.host,&command,0,&pose,max(u64))
    if t.motion>=0 {wire.object_read(&s.host,&command,t.motion,&motion,max(u64))}
    components_apply(s,w,x.entity,t,&command,command.mask)
    ahead:=f32(i32(c.newest-tick))*tick_dt
    wanted:=Present{position=pose.position+motion.linear*ahead,rotation=pose.rotation,scale=pose.scale,linear=motion.linear,angular=motion.angular,asleep=resting(&motion)}
    x.drifting=false
    replica_put(s,w,x,&wanted)
    core.world_settle(w)
    wire.smoothing_correct(&x.smoothing,now.position,wanted.position,now.rotation,wanted.rotation)
    s.stats.overtaken+=1
}

// Every tick that runs the first time, before it: each error a replica is
// closing moves it the share of what is left that a tick is of correction_time.
@(private)
drifts_apply :: proc(s:^Net_Session,w:core.World_Ref,tick_dt:f32) {
    c:=&s.client
    share:=clamp(tick_dt/s.desc.correction_time,0,1)
    moved:=false
    for &x in c.replicas[:c.replica_high] {
        if x.object==0 || !x.drifting {continue}
        if x.mode!=.Predicted {
            x.drifting=false
            continue
        }
        now:=replica_now(s,w,&x) or_continue
        step:=x.drift*share
        turn:=linalg.normalize(mm.quat_nlerp(1,x.twist,share))
        feed(c,x.object);feed(c,step);feed(c,turn)
        wanted:=now
        wanted.position+=step
        wanted.rotation=linalg.normalize(turn*now.rotation)
        replica_put(s,w,&x,&wanted)
        x.drift-=step
        x.twist=linalg.normalize(x.twist*conj(turn))
        x.drifting=linalg.length2(x.drift)>DRIFT_DONE*DRIFT_DONE || abs(x.twist.w)<math.cos(f32(DRIFT_DONE)*0.5)
        moved=true
    }
    if moved {core.world_settle(w)}
}

// Meters, and radians, below which what is left of an error is dropped.
@(private) DRIFT_DONE :: 0.0005

// Start of a frame, after the commands: every state of the server is compared
// with what was predicted for its tick, and what differs is corrected.
@(private)
client_reconcile :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,dt:f32) {
    c:=&s.client
    d:=&s.desc
    clock:=wire.clock_state(&s.host)
    c.silence=u32(clock.rtt*clock.rate*1.5)+8
    c.budget=min(c.budget+max(dt,0)*f32(d.resimulate_budget),f32(max(d.resimulate_budget,d.max_resimulate)))
    c.frame_left=min(d.max_resimulate,c.history-1)
    if !c.any {
        for &x in c.replicas[:c.replica_high] {x.pending=false}
        return
    }
    // The newest tick of the server this client has news of.
    heard:=clock.synced?i64(clock.server-clock.rtt*0.5*clock.rate):-1
    for &x in c.replicas[:c.replica_high] {
        if x.object!=0 && x.pending {heard=max(heard,i64(x.tick))}
    }
    c.quiet_set=heard>i64(c.silence)
    c.quiet=u32(max(heard-i64(c.silence),0))
    newest:=c.newest
    target:u32
    wanted:=false
    compared,differing:=0,0
    for &x in c.replicas[:c.replica_high] {
        x.action,x.exact=.None,false
        if x.object==0 {continue}
        fresh:=x.pending
        x.pending=false
        if x.mode!=.Predicted || x.slot<0 {continue}
        handled:=false
        stale:=false
        stale_tick:u32
        stale_mask:u64
        stale_words:[]u32
        inside:=false
        for index in 0..<x.authority_count {
            authority,words:=authority_at(s,&x,index)
            if authority.object!=x.object || authority.checked || i32(authority.tick-newest)>0 {continue}
            authority.checked=true
            handled=true
            record,kept:=record_of(c,d,&x,authority.tick)
            if record==nil {
                if !kept {
                    s.stats.unverified+=1
                    if !stale || i32(authority.tick-stale_tick)>0 {stale,stale_tick,stale_mask,stale_words=true,authority.tick,authority.available,words}
                }
                continue
            }
            inside=true
            command:=wire.Command{kind=.Object_Updated,type=x.type,object=x.object,tick=authority.tick,mask=authority.available,words=words}
            pose:Pose
            motion:Motion_State
            wire.object_read(&s.host,&command,0,&pose,max(u64))
            t:=net_type(s,x.type)
            if t.motion>=0 {wire.object_read(&s.host,&command,t.motion,&motion,max(u64))}
            compared+=1
            if !record_differs(d,t.motion>=0,record,&pose,&motion) && !record_components_differ(s,&x,authority.tick,&command) {continue}
            differing+=1
            if x.action==.None || i32(authority.tick-x.check)>0 {x.check=authority.tick}
            if !replica_critical(d,&x,authority.tick) {
                if x.action==.None {x.action=.Blend}
                continue
            }
            x.action=.Rollback
            if !wanted || i32(authority.tick-target)<0 {target=authority.tick}
            wanted=true
        }
        if stale && !inside {replica_overtaken(s,w,&x,stale_tick,stale_mask,stale_words,app.tick_dt)}
        if handled || fresh {continue}
        tick:=c.quiet
        if !c.quiet_set || !resting(&x.motion) || i32(tick-x.tick)<=0 || i32(tick-newest)>0 {continue}
        if x.verified_set && i32(tick-x.verified)<=0 {continue}
        record,_:=record_of(c,d,&x,tick)
        if record==nil {continue}
        x.verified,x.verified_set=tick,true
        compared+=1
        command:=replica_command(s,&x)
        if !record_differs(d,net_type(s,x.type).motion>=0,record,&x.pose,&x.motion) && !record_components_differ(s,&x,tick,&command) {continue}
        differing+=1
        x.check=tick
        if !replica_critical(d,&x,tick) {
            x.action=.Blend
            continue
        }
        x.action=.Rollback
        if !wanted || i32(tick-target)<0 {target=tick}
        wanted=true
    }
    if compared>0 && differing==0 {s.stats.confirmed+=1}
    if differing==0 {return}
    started:=time.tick_now()
    if wanted {
        if !client_rewind(s,w,app,target) {s.stats.deferred+=1}
    }
    for &x in c.replicas[:c.replica_high] {
        if x.object!=0 && x.action!=.None && !x.exact {replica_adjust(s,w,&x,app.tick_dt)}
    }
    s.stats.resimulate_seconds+=time.duration_seconds(time.tick_since(started))
}

// The ticks libraries asked to go back to: the earliest the client simulated
// runs again from the copy of the world as it found it, when the history,
// this frame and the budget allow it.
@(private)
client_rewinds :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,ticks:[]u32) {
    c:=&s.client
    if !c.any {return}
    earliest:u32
    found:=false
    for tick in ticks {
        if i32(c.newest-tick)<0 || found && i32(tick-earliest)>=0 {continue}
        earliest,found=tick,true
    }
    if !found {return}
    for &x in c.replicas[:c.replica_high] {x.action,x.exact=.None,false}
    started:=time.tick_now()
    if client_rewind(s,w,app,earliest-1) {s.stats.rewound+=1}
    s.stats.resimulate_seconds+=time.duration_seconds(time.tick_since(started))
}

// A rollback to target when this frame and the budget have room for it.
@(private)
client_rewind :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,target:u32) -> bool {
    c:=&s.client
    behind:=int(i32(c.newest-target))
    if behind>c.frame_left || f32(behind)>c.budget || !client_rollback(s,w,app,target) {return false}
    c.budget-=f32(behind)
    c.frame_left-=behind
    return true
}

// The world goes back to the start of the tick after target, takes what the
// server said of it and of the ticks after it, and the fixed loop runs again
// up to the present: its clock comes with the copy and the ticks advance it
// to where it was, and the frame (core.Frame_Time) is not part of the copy.
// What was out of reach of this client before and after stays as it was.
// False when a tick from there on is out of the history.
@(private)
client_rollback :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,target:u32) -> bool {
    c:=&s.client
    d:=&s.desc
    if !c.any {return false}
    start:=target+1
    clock:=core.world_storage_of(w,core.Time)
    input:=core.world_storage_of(w,core.Input)
    if w.info.loops[.Game][.Fixed]==nil || clock==nil || i32(c.newest-start)<0 {return false}
    for tick:=start;i32(c.newest-tick)>=0;tick+=1 {
        if at:=&c.frames[int(tick)%len(c.frames)];!at.valid || at.tick!=tick {return false}
    }

    for &x in c.replicas[:c.replica_high] {
        x.corrected=false
        if x.object==0 || x.mode!=.Predicted {continue}
        x.before,x.corrected=replica_now(s,w,&x)
        x.kept=x.action!=.Rollback && !replica_critical(d,&x,target)
    }
    present_input:core.Input
    if input!=nil {present_input=input^}
    restored:=&c.frames[int(start)%len(c.frames)]
    if !host.app_world_replace(app,w.data,restored.world) {
        for &x in c.replicas[:c.replica_high] {x.corrected=false}
        core.report(s.problems,core.NONE,"net.rollback","a correction of the server could not go back to tick %d: out of memory for the copy of the world, so the prediction keeps its error; free memory",start)
        return false
    }
    for &frame in c.frames {
        if &frame!=restored {core.copy_marks_follow(w,restored.marks,frame.marks)}
    }
    core.copy_marks_follow(w,restored.marks,restored.marks)
    // What is simulated again leaves the error it was closing to the correction.
    for &x in c.replicas[:c.replica_high] {
        if x.corrected && !x.kept {x.drifting=false}
    }
    clock.resimulating=true
    replicas_relink(s,w,app)
    authoritative_apply(s,w,target,true)
    for tick:=start;i32(c.newest-tick)>=0;tick+=1 {
        frame:=&c.frames[int(tick)%len(c.frames)]
        if input!=nil {input^=frame.input}
        host.app_tick_replay(app,w.data,frame.content)
        // SyncTest runs the tick again from the copy this correction made, without the states of the server.
        if c.sync_hashes!=nil {
            core.world_settle(w)
            sync_hashes(s,w,c.sync_hashes[(int(tick)%c.history)*(len(w.info.tables)+1):][:len(w.info.tables)+1])
        }
        authoritative_apply(s,w,tick,false)
        records_capture(s,w,tick)
        s.stats.resimulated+=1
    }
    clock.resimulating=false
    if input!=nil {input^=present_input}
    for &x in c.replicas[:c.replica_high] {
        if x.object==0 || x.mode==.Predicted || !core.alive(core.world_entities(w),x.entity) {continue}
        command:=replica_command(s,&x)
        components_apply(s,w,x.entity,net_type(s,x.type),&command,x.available)
    }
    core.world_settle(w)
    references_refresh(s,w)
    behind:=int(i32(c.newest-target))
    s.stats.corrected+=1
    s.stats.largest_resimulation=max(s.stats.largest_resimulation,behind)
    for &x in c.replicas[:c.replica_high] {
        if !x.corrected || x.object==0 || x.mode!=.Predicted {continue}
        after:=replica_now(s,w,&x) or_continue
        if x.kept && !x.exact && !replica_critical(d,&x,c.newest) {
            replica_put(s,w,&x,&x.before)
            dq:=linalg.normalize(x.before.rotation*conj(after.rotation))
            records_shift(s,&x,target,x.before.position-after.position,{},dq,x.before.linear-after.linear,x.before.angular-after.angular,app.tick_dt)
        } else {
            wire.smoothing_correct(&x.smoothing,x.before.position,after.position,x.before.rotation,after.rotation)
        }
    }
    return true
}

// With Net_Settings.sync_test, at the start of a frame, before anything of
// the network comes in: each of the last sync_test ticks runs again from the
// copy of the world it started from, with its input and without the states of
// the server, and what it leaves is compared with what it left the last time
// it ran (the first time, or a correction): by a hash of each table and of the
// simulation, and row by row after the last tick, which names the entity. A
// tick the network gives something else this time is not compared. A
// difference is the problem net.sync_test. Then the world the first time made
// is put back.
@(private)
client_sync_test :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App) {
    c:=&s.client
    d:=&s.desc
    if d.sync_test<=0 || c.sync_world==nil || !c.any {return}
    clock:=core.world_storage_of(w,core.Time)
    input:=core.world_storage_of(w,core.Input)
    if w.info.loops[.Game][.Fixed]==nil || clock==nil {return}
    last:=c.newest
    first:=last-u32(min(d.sync_test,c.history-1))+1
    for tick:=first;i32(last-tick)>=0;tick+=1 {
        if at:=&c.frames[int(tick)%len(c.frames)];!at.valid || at.tick!=tick || c.record_ticks[int(tick)%c.history]!=tick+1 {return}
    }
    if !w.info.copy(c.sync_world,w.data) {return}
    count:=len(w.info.tables)+1
    hashes:=c.sync_hashes[c.history*count:][:count]
    present_input:core.Input
    if input!=nil {present_input=input^}
    c.sync_testing=true
    for tick:=first;i32(last-tick)>=0;tick+=1 {
        frame:=&c.frames[int(tick)%len(c.frames)]
        if !host.app_world_replace(app,w.data,frame.world) {break}
        clock.resimulating=true
        if input!=nil {input^=frame.input}
        host.app_tick_replay(app,w.data,frame.content)
        clock.resimulating=false
        s.stats.sync_tested+=1
        // The network gave the tick something else: a state of the server that came after it ran.
        if c.sync_fed[c.history]!=c.sync_fed[int(tick)%c.history] {
            s.stats.sync_skipped+=1
            continue
        }
        sync_hashes(s,w,hashes)
        expected:=c.sync_hashes[(int(tick)%c.history)*count:][:count]
        for hash,table in hashes {
            if hash==expected[table] {continue}
            sync_problem(s,w,tick,table,tick==last)
            break
        }
    }
    c.sync_testing=false
    if input!=nil {input^=present_input}
    w.info.swap(w.data,c.sync_world)
    core.world_settle(w)
}

// A hash of each table of a World, of the rows on and their entities, and
// last the one of what simulates outside the tables (core.Simulation_Hash).
@(private)
sync_hashes :: proc(s:^Net_Session,w:core.World_Ref,out:[]u64) {
    for &info,i in w.info.tables {
        out[i]=0
        if info.place!=.World {continue}
        t:=core.world_table_at(w,&info)
        hash:=t.on>0?xxhash.XXH3_64_with_seed(mem.slice_to_bytes(t.entities[:t.on]),u64(t.on)):0
        for row in 0..<t.on {hash=core.value_hash(rawptr(uintptr(t.values.data)+uintptr(row*info.info.size)),info.info,hash)}
        out[i]=hash
    }
    out[len(w.info.tables)]=0
    if simulated:=core.world_storage_of(w,core.Simulation_Hash);simulated!=nil {out[len(w.info.tables)]=simulated.value}
}

// A tick ran again different: the table, or the simulation, and after the last
// tick the entity, which the world the first time left tells.
@(private)
sync_problem :: proc(s:^Net_Session,w:core.World_Ref,tick:u32,table:int,last:bool) {
    WHY :: "a fixed function reads something besides the World and the Input, or keeps what it needs outside the World; keep it in a component or a storage of the World"
    if table>=len(w.info.tables) {
        core.report(s.problems,core.NONE,"net.sync_test","tick %d leaves what simulates outside the tables (the bodies of physics) different when it runs again from the same world and input (Net_Settings.sync_test): %s",tick,WHY)
        return
    }
    info:=&w.info.tables[table]
    e:=core.NONE
    if last {
        a,b:=core.world_table_at(core.world_ref(s.client.sync_world,w.info),info),core.world_table_at(w,info)
        for row in 0..<max(a.on,b.on) {
            if row>=a.on || row>=b.on || a.entities[row]!=b.entities[row] {e=row<a.on?a.entities[row]:b.entities[row];break}
            if !core.value_equal(rawptr(uintptr(a.values.data)+uintptr(row*info.info.size)),rawptr(uintptr(b.values.data)+uintptr(row*info.info.size)),info.info) {e=a.entities[row];break}
        }
    }
    core.report(s.problems,e,"net.sync_test","tick %d leaves %s different when it runs again from the same world and input (Net_Settings.sync_test): %s",tick,info.name,WHY)
}

// After the world was replaced by an older copy: the replicas that did not
// exist then are made again, and the entities of replicas that ended since are destroyed.
@(private)
replicas_relink :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App) {
    c:=&s.client
    es:=core.world_entities(w)
    links:=core.world_table_of(w,Net_Link)
    for &r in c.replicas[:c.replica_high] {
        if r.object!=0 {r.entity=core.NONE}
    }
    for row in 0..<core.count(links) {
        e:=links.entities[row]
        r:=replica_of(s,links.values[row].object)
        if r==nil || r.entity!=core.NONE {
            core.destroy(es,e)
            continue
        }
        r.entity=e
        wire.object_bind(&s.host,r.object,u64(e))
    }
    core.world_settle(w)
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 {continue}
        if r.entity==core.NONE {
            replica_spawn(s,w,app,&r)
            s.stats.spawned-=1
        }
        // The copy has the mode the replica had then; it may have changed since.
        replica_components(s,w,&r,r.mode)
    }
    core.world_settle(w)
}

// Client: the entity this application made for what a replica stands for takes
// the place of the one the replica made when it arrived first. The replica
// stays, with its object, and the entity of the replica is destroyed.
@(private)
replica_adopt :: proc(s:^Net_Session,w:core.World_Ref,id:base.Entity_Id,e:core.Entity) -> bool {
    if !s.host_ready || s.mode!=.Client || id==0 {return false}
    es:=core.world_entities(w)
    links:=core.world_table_of(w,Net_Link)
    if core.has(links,e) {return false}
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object==0 || r.waits || r.pose.id!=id {continue}
        if r.entity==e {return true}
        if core.alive(es,r.entity) {core.world_destroy_tree(w,r.entity)}
        r.entity,r.adopted=e,true
        replicate:=REPLICATE_DEFAULT
        replicate.simulation=r.simulation
        core.add(core.world_table_of(w,Replicate),e,replicate)
        core.add(links,e,Net_Link{object=r.object})
        wire.object_bind(&s.host,r.object,u64(e))
        replica_components(s,w,&r,r.mode)
        return true
    }
    return false
}

// Client: the look of the Move_Input of the body the seat of this machine
// drives (the first local one), to send with the input.
@(private)
driven_look :: proc(w:core.World_Ref) -> (look:[2]f32,ok:bool) {
    seats:=core.world_table_of(w,input.Seat)
    drivables:=core.world_table_of(w,input.Drivable)
    moves:=core.world_table_of(w,input.Move_Input)
    if seats==nil || drivables==nil || moves==nil {return}
    seat:=input.local_seat(core.read(seats),0)
    if seat==core.NONE {return}
    for row in 0..<core.count(drivables) {
        if drivables.values[row].seat!=seat {continue}
        move,has:=core.get(core.read(moves),core.entity_at(drivables,row))
        if !has {return}
        return {move.look_yaw,move.look_pitch},true
    }
    return
}

// The actions of the first local seat, the one that drives what the server
// lets this client predict, as the game here saw them this tick.
@(private)
driven_actions :: proc(s:^Net_Session,w:core.World_Ref) -> (sent:input.Remote_Actions) {
    seats:=core.world_table_of(w,input.Seat)
    bindings:=core.world_storage_of(w,input.Input_Map)
    if seats==nil || bindings==nil {return}
    ok:bool
    sent,ok=input.seat_remote(core.read(seats),input.local_seat(core.read(seats),0),bindings)
    if !ok {core.report(s.problems,core.NONE,"net.input_axes","more than %d axis actions of the seat that drives were away from zero in one tick, and the server got only the first %d; give the actions that move together fewer axes, or make some of them buttons",input.REMOTE_AXES,input.REMOTE_AXES)}
    return
}

// Client, at the start of a frame, before its ticks: what the input the frame takes is aimed at,
// the others as the last tick simulated left them, the transforms the game reads.
@(private)
frame_view_take :: proc(s:^Net_Session,w:core.World_Ref) {
    c:=&s.client
    c.frame_view_ok=false
    if !c.any {return}
    c.frame_view,c.frame_view_ok=shown_tick(s,w,c.newest)
}

// Client: the tick of the server the others were shown at in a tick: where
// client_head placed the interpolated replicas, less how far behind that the
// ones with Rewind (what can be hit) are shown, on average, for their states
// come further apart. Without such replicas, the tick of the display.
@(private)
shown_tick :: proc(s:^Net_Session,w:core.World_Ref,tick:u32) -> (view:f64,ok:bool) {
    c:=&s.client
    frame:=&c.frames[int(tick)%len(c.frames)]
    if frame.tick!=tick || frame.interpolation<1 {return}
    marked:=core.world_table_of(w,Rewind)
    if marked==nil || core.count(marked)==0 {return frame.interpolation,true}
    sum,count:=f64(0),0
    for &r,index in c.replicas[:c.replica_high] {
        if r.object==0 || r.mode!=.Interpolated || !core.has(marked,r.entity) {continue}
        delay:=frame.delays[index]
        if delay.object!=r.object || delay.ticks<0 {continue}
        sum+=f64(delay.ticks)
        count+=1
    }
    return frame.interpolation-(count>0?sum/f64(count):0),true
}
