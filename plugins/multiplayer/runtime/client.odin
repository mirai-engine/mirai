package multiplayer

import "base:runtime"
import "core:hash/xxhash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
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
// One rule says how a replica lives here (replica_wanted):
//
//   Here          lent to this client, or what each end simulates: never corrected
//   Predicted     what this client drives, what a simulation moves on the server
//                 while it is within reach of it (they shared a group of the
//                 simulation in the last critical_ticks) and what the server
//                 asks to predict always: simulated ahead of the server
//   Interpolated  everything else: shown between the states of the server, in
//                 the past, with pose, motion and components of one instant
//
// A replica that goes from one to the other does not jump: what the eye saw
// stays as an error of its drawing that fades (wire.Smoothing), like the one a
// correction leaves.
//
// Prediction keeps, per tick, a copy of the whole world as the tick found it,
// the input of the tick and the pose each predicted replica had after it. A
// state of the server is compared with what was predicted for its tick: when
// it differs, the world goes back to the copy of the next tick, takes the
// states of the server at their ticks and the fixed loop runs again up to the
// present; when it cannot go back, the replica takes the state in the present.

@(private) INTERPOLATION_DEPTH :: 32
@(private) REPLICA_EXTRAPOLATION :: 0.1 // seconds an interpolated replica goes on with its last velocity when its states run out
@(private) SWITCH_HALF_LIFE :: 0.2 // seconds in which what a replica that changed timeline was drawn off by halves

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

// A state of the server in the interpolation buffer of a replica: what moves
// it, then mask and available as of that state, then its words (words_per).
@(private)
Sample :: struct {
    pose:Pose,
    motion:Motion_State,
    mask:u64,      // the fields that changed with this state
    available:u64, // those known by then
}

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
    corrected:bool,    // it was predicted when the correction under way began
    differs:bool,      // the comparison of this frame found it off, or it turns predicted: the world goes back for it
    switched:bool,     // it changed timeline in this frame: what it was drawn off by fades slower
    touched_set,verified_set:bool,
    touched:u32,       // last tick it was within reach of what this client drives
    verified:u32,      // tick its newest state was last compared at
    check:u32,         // tick of the state that asked to go back
    slot:i32,          // of the prediction records, while predicted; -1: none
    samples:i32,       // of the interpolation buffer, for what this client neither drives nor holds; -1: none
    tick:u32,          // server tick of the newest state
    pose:Pose,         // the newest state; for a replica this client holds, the last one it sent
    motion:Motion_State,
    smoothing:wire.Smoothing,
    before:Present,
    held_hash:u64,     // of the components last sent for a replica this client holds
    available:u64,
    references:u64,
    delay:f32,         // interpolated: ticks it is shown behind the display, for its states come further apart; negative until known
    shown:u32,         // interpolated: the tick of the state of the server whose components its entity has; valid when shown_set
    shown_set:bool,
    retyped_set:bool,  // the server gave it another type (the fragments it replicates) after the tick retyped
    retyped:u32,
    type_before:wire.Type_Id, // the one it had until then: what a copy of the world older than that has of it
    spawned_set:bool,  // its entity is one this client made in tick spawned, ahead of the server (Predicted_Spawn)
    spawned:u32,
}

// The world as a tick found it, with what else the tick started from.
@(private)
Frame :: struct {
    world:rawptr,
    marks:[]core.Copy_Mark, // what each table and storage of the World was when it was last copied here
    tick:u32,
    valid:bool,
    whole:bool,        // the world was replaced since: the next copy is whole
    interpolation:f64, // server tick the interpolated replicas were placed at
    shown:[]Shown,     // by object index: how each interpolated replica started the tick
    input:core.Input,
    content:u32, // host.content_generation the tick saw: it sees the same when it runs again
}

// What a tick started from of an interpolated replica, by object index: how
// far behind the display it was placed (negative for the rest), and the
// state of the server whose components its entity had.
@(private)
Shown :: struct {
    object:Object,
    ticks:f32,
    state:u32,
    state_set:bool,
}

// The actions the devices of a tick gave the seat a client drives with; tick is that tick plus one.
@(private)
Taken :: struct {tick:u32,actions:input.Remote_Actions}

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
    taken:[]Taken,      // with input_delay, by tick modulo its length: the actions the devices gave in each of the last ticks
    fed_seat,delayed:input.Seat, // with input_delay: the seat it drives with as its devices left it, and as the game had it at the start of the tick
    record_free:[]i32,
    record_free_count:int,
    islands:[]u32,      // of what this client drives, by records_capture
    driven:[]i32,       // the replicas this client drives, by index: driven_list
    driven_count:int,
    newest:u32,         // last tick simulated
    any:bool,
    sample:[]u8,        // one state for the interpolation buffer: a Sample and its words
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
    sections_seen:core.Seen, // what of scene.Scene_Reference it told them for
    waiting:int,        // replicas none of whose sections is loaded here
    sections_looked:core.Seen, // what of scene.Scene_Reference the replicas last looked at their sections for
}

@(private)
client_init :: proc(s:^Net_Session,w:core.World_Ref,allocator:runtime.Allocator) -> bool {
    c:=&s.client
    d:=&s.desc
    c.words_per=s.protocol.object_words
    error:runtime.Allocator_Error
    if c.replicas,error=make([]Replica,d.max_objects,allocator);error!=nil {return false}
    if c.words,error=make([]u32,d.max_objects*c.words_per,allocator);error!=nil {return false}
    if c.record_free,error=make([]i32,d.predicted_capacity,allocator);error!=nil {return false}
    if c.islands,error=make([]u32,d.max_objects,allocator);error!=nil {return false}
    if c.driven,error=make([]i32,d.max_objects,allocator);error!=nil {return false}
    c.budget=f32(d.resimulate_budget)
    c.sections=make([dynamic]base.Entity_Id,allocator)
    if d.sync_test>0 {
        data,alloc_error:=mem.alloc(max(w.info.sizes[.World],1),max(w.info.aligns[.World],1),allocator)
        if alloc_error!=nil || data==nil {return false}
        c.sync_world=data
        if !core.world_init(w.info,.World,data,allocator) {return false}
        // What simulates outside the tables leaves a hash of it for the test.
        if check:=core.world_storage_of(w,core.Sync_Check);check!=nil {check.on=true}
    }
    for &slot,index in c.record_free {slot=i32(d.predicted_capacity-1-index)}
    c.record_free_count=d.predicted_capacity
    if !history_make(s,w,c,wire.host_history(&s.host)) {return false}
    if c.sample,error=runtime.mem_alloc_bytes(sample_size(c),align_of(Sample),allocator);error!=nil {return false}
    return wire.interpolation_init(&c.interpolation,{state_size=sample_size(c),capacity=d.max_objects,depth=INTERPOLATION_DEPTH,allocator=allocator})==.None
}

@(private)
sample_size :: #force_inline proc "contextless" (c:^Client) -> int {return size_of(Sample)+c.words_per*size_of(u32)}

// The words of a state of the interpolation buffer, after its Sample.
@(private)
sample_words :: #force_inline proc "contextless" (c:^Client,state:[]u8) -> []u32 {
    return mem.slice_data_cast([]u32,state[size_of(Sample):][:c.words_per*size_of(u32)])
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
        if !core.world_init(w.info,.World,data,allocator) {return false}
        if frame.marks,error=make([]core.Copy_Mark,core.copy_marks_count(w.info),allocator);error!=nil {return false}
        if frame.shown,error=make([]Shown,d.max_objects,allocator);error!=nil {return false}
    }
    if c.records,error=make([]Record,slots*d.predicted_capacity,allocator);error!=nil {return false}
    if c.record_words,error=make([]u32,slots*d.predicted_capacity*c.words_per,allocator);error!=nil {return false}
    if c.authoritative,error=make([]Authoritative,slots*d.predicted_capacity,allocator);error!=nil {return false}
    if c.authoritative_words,error=make([]u32,slots*d.predicted_capacity*c.words_per,allocator);error!=nil {return false}
    if c.record_ticks,error=make([]u32,slots,allocator);error!=nil {return false}
    if c.taken,error=make([]Taken,slots+INPUT_DELAY_MAX,allocator);error!=nil {return false}
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
            core.world_destroy(s.info,.World,frame.world)
            mem.free(frame.world,allocator)
        }
        delete(frame.marks,allocator)
        delete(frame.shown,allocator)
    }
    delete(c.frames,allocator)
    delete(c.records,allocator);delete(c.record_ticks,allocator);delete(c.taken,allocator)
    delete(c.record_words,allocator);delete(c.authoritative,allocator);delete(c.authoritative_words,allocator)
    delete(c.sync_hashes,allocator);delete(c.sync_fed,allocator)
    c.frames,c.records,c.record_ticks,c.record_words,c.authoritative,c.authoritative_words,c.sync_hashes,c.sync_fed,c.taken=nil,nil,nil,nil,nil,nil,nil,nil,nil
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
        core.world_destroy(s.info,.World,c.sync_world)
        mem.free(c.sync_world,allocator)
    }
    if c.interpolation.data!=nil {wire.interpolation_destroy(&c.interpolation)}
    delete(c.replicas,allocator);delete(c.words,allocator);delete(c.record_free,allocator);delete(c.sample,allocator)
    delete(c.islands,allocator);delete(c.driven,allocator);delete(c.sections)
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
client_commands :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,commands:[]wire.Command) {
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
            client_end(s,w,allocator,command.connection,command.reason,reason_text(command.reason,s.address,s.protocol.hash))
        case .Object_Created:
            if r:=replica_of(s,command.object);r!=nil && command.retyped {
                replica_retype(s,w,assets,r,&command)
            } else {
                replica_create(s,w,assets,&command)
            }
        case .Object_Updated:
            replica_update(s,w,assets,&command)
        case .Object_Destroyed:
            replica_destroy(s,w,command.object,command.ended?.End:.Leave)
        case .Role_Changed:
            if r:=replica_of(s,command.object);r!=nil {
                r.role=command.role
                replica_classify(s,w,r)
            }
        case .Event:
            event_deliver(s,w,&command,nil)
        }
    }
    core.world_settle(w)
    if !s.ended {replicas_sections(s,w,assets)}
    references_refresh(s,w)
    if !s.ended {client_world_update(s,w,assets,allocator)}
}

// The replicas of entities of sections take the entity they have here as the
// sections load and drop (replica_place). Only when the sections change.
@(private)
replicas_sections :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets) {
    c:=&s.client
    references:=core.world_table_of(w,scene.Scene_Reference)
    if references==nil || !core.touched(references,&c.sections_looked) {return}
    changed:=false
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 {continue}
        if r.pose.sections[0]!=0 {changed|=replica_place(s,w,assets,&r)}
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
replica_place :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,r:^Replica) -> bool {
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
                reference,_:=core.get(references,section)
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
        replica_spawn(s,w,assets,r)
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
replica_create :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,command:^wire.Command) {
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
    r^={object=command.object,type=command.type,role=command.role,simulation=command.simulation,slot=-1,samples=-1,entity=core.NONE,waits=true}
    c.waiting+=1
    wire.smoothing_init(&r.smoothing)
    c.replica_high=max(c.replica_high,index+1)
    replica_state(s,r,command)
    replica_place(s,w,assets,r)
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
replica_spawn :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,r:^Replica) {
    t:=net_type(s,r.type)
    es:=core.world_entities(w)
    transforms:=core.world_table_of(w,core.Transform)
    e:=replica_adoptable(s,w,r)
    r.adopted=e!=core.NONE
    // One this client made ahead of the server (predict_spawn) is the replica's own: it goes with it.
    if spawn,predicted:=core.get(core.read(core.world_table_of(w,Predicted_Spawn)),e);predicted {
        r.adopted,r.spawned,r.spawned_set=false,u32(spawn.tick),true
        core.remove(core.world_table_of(w,Predicted_Spawn),e)
    }
    if e==core.NONE {
        local:=core.Transform{r.pose.position,r.pose.rotation,r.pose.scale}
        // Where its section is not loaded, a copy of it from the scene of that section.
        if home:=r.pose.sections[0];home!=0 && r.pose.id!=0 {
            if references:=core.world_table_of(w,scene.Scene_Reference);references!=nil {
                if reference,found:=core.get(references,core.entity_of(es,home));found && reference.scene!={} {
                    if report,error:=scene.spawn_member(core.commands_of(w),assets,reference.scene,home,r.pose.id,local);error==.None {e=report.root}
                }
            }
        }
        if e==core.NONE && r.pose.prefab!={} {
            e=scene.spawn(scene.Spawner{core.commands_of(w),assets,core.world_storage_of(w,core.Problems)},r.pose.prefab,local,transient=true)
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
// and so is what the network turned off in a section loaded and off here,
// and a copy that waits for its prefab (scene.Prefab_Pending).
@(private)
replica_turn :: proc(w:core.World_Ref,r:^Replica) {
    disabled,held,pending:=core.world_table_of(w,core.Disabled),core.world_table_of(w,scene.Section_Held),core.world_table_of(w,scene.Prefab_Pending)
    e:=r.entity
    if disabled==nil || !core.alive(core.world_entities(w),e) {return}
    off:=row_staged(core.raw(disabled),e)
    switch {
    case r.pose.disabled && !off:
        core.add(disabled,e,core.Disabled{})
    case !r.pose.disabled && off && (held==nil || !row_staged(core.raw(held),e)) && (pending==nil || !row_staged(core.raw(pending),e)):
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
    reference,found:=core.get(references,core.parent_of(core.ref(core.world_storage_of(w,core.Hierarchy)),e))
    return found && reference.loaded!={} && reference.held
}

// A replica lets go of its row of prediction records and of its buffer of states.
@(private)
slot_release :: proc(s:^Net_Session,r:^Replica) {
    c:=&s.client
    if r.slot>=0 {
        c.record_free[c.record_free_count]=r.slot
        c.record_free_count+=1
    }
    if r.samples>=0 {wire.interpolation_remove(&c.interpolation,int(r.samples))}
    r.slot,r.samples=-1,-1
}

// How a replica lives here: the one rule of the header.
@(private)
replica_wanted :: proc(s:^Net_Session,r:^Replica) -> Mode {
    c:=&s.client
    switch {
    case r.simulation==.Each || r.role==.Held: return .Here
    case r.role==.Predicted || r.pose.predict || r.spawned_set: return .Predicted
    case net_type(s,r.type).motion<0:          return .Interpolated
    case c.any && r.touched_set && i32(c.newest-r.touched)<=i32(s.desc.critical_ticks): return .Predicted
    }
    return .Interpolated
}

// Gives a replica what its mode keeps: a row of prediction records while it
// is predicted, a buffer of states while the server decides it and this
// client does not drive it (also while it predicts it, to return to them),
// and its components.
@(private)
replica_classify :: proc(s:^Net_Session,w:core.World_Ref,r:^Replica) {
    c:=&s.client
    mode:=replica_wanted(s,r)
    if mode==.Predicted && r.slot<0 && c.record_free_count==0 {
        core.report(s.problems,r.entity,"net.predicted","this replica is shown interpolated instead of predicted: the %d replicas of Net_Settings.predicted_capacity are predicted already; raise predicted_capacity",s.desc.predicted_capacity)
        mode=.Interpolated
    }
    if mode==.Here || r.role==.Predicted {
        if r.samples>=0 {wire.interpolation_remove(&c.interpolation,int(r.samples))}
        r.samples=-1
    } else if r.samples<0 {
        if slot,ok:=wire.interpolation_add(&c.interpolation);ok {
            r.samples,r.delay,r.shown_set=i32(slot),-1,false
            replica_sample(s,r,r.available)
        }
    }
    if mode!=r.mode || mode==.Predicted && r.slot<0 {
        if r.slot>=0 {
            c.record_free[c.record_free_count]=r.slot
            c.record_free_count+=1
            r.slot=-1
        }
        r.mode,r.pending=mode,false
        switch mode {
        case .Here:
            // What the client holds starts from where it was being shown.
            if local,has:=core.get(core.read(core.world_table_of(w,core.Transform)),r.entity);has {
                r.pose.position,r.pose.rotation,r.pose.scale=local.position,local.rotation,local.scale
            }
        case .Interpolated:
            r.shown_set=false
        case .Predicted:
            c.record_free_count-=1
            r.slot=c.record_free[c.record_free_count]
            authority_clear(s,r)
            r.verified_set=false
            command:=replica_command(s,r)
            authoritative_capture(s,r,&command)
        }
    }
    if core.alive(core.world_entities(w),r.entity) {replica_components(s,w,r,mode)}
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

// The newest state of a replica goes to its buffer, with the fields that
// changed with it; a second one of a tick joins the first. Without a
// replicated velocity a state takes the one from the state before: what the
// replica goes on with when its states run out.
@(private)
replica_sample :: proc(s:^Net_Session,r:^Replica,mask:u64) {
    c:=&s.client
    if r.samples<0 {return}
    sample:=(^Sample)(raw_data(c.sample))
    sample^={pose=r.pose,motion=r.motion,mask=mask,available=r.available}
    before,tick,kept:=wire.interpolation_newest(&c.interpolation,int(r.samples))
    if kept && net_type(s,r.type).motion<0 && i32(r.tick-tick)>0 {
        last:=(^Sample)(raw_data(before))
        seconds:=f32(r.tick-tick)/f32(s.host.desc.tick_rate)
        sample.motion.linear=(r.pose.position-last.pose.position)/seconds
        sample.motion.angular=rotation_rate(last.pose.rotation,r.pose.rotation,seconds)
    }
    copy(sample_words(c,c.sample),replica_words(s,r))
    if kept && tick==r.tick {
        sample.mask|=(^Sample)(raw_data(before)).mask
        copy(before,c.sample)
    } else {
        wire.interpolation_push(&c.interpolation,int(r.samples),r.tick,c.sample)
    }
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
replica_update :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,command:^wire.Command) {
    r:=replica_of(s,command.object)
    if r==nil {return}
    sections:=r.pose.sections
    replica_state(s,r,command)
    if r.pose.sections!=sections {replica_place(s,w,assets,r)}
    if r.waits {return}
    replica_sample(s,r,command.mask)
    authoritative_capture(s,r,command)
    if core.alive(core.world_entities(w),r.entity) {
        // What is shown in the past takes its components when the display reaches this state (replica_show).
        if r.mode!=.Interpolated {components_apply(s,w,r.entity,net_type(s,r.type),command,command.mask)}
        if replica_turns(r) {replica_turn(w,r)}
    }
    r.pending=r.mode==.Predicted
}

// The server gave the object another list of fragments, for its entity gained
// or lost a replicated component: the replica and its entity go on. The entity
// loses the components that left the list and takes the whole state of the
// new one; what was kept of it, in the words of the type before, is dropped.
@(private)
replica_retype :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,r:^Replica,command:^wire.Command) {
    c:=&s.client
    after:=net_type(s,command.type)
    if !after.fits {return}
    if !r.waits && core.alive(core.world_entities(w),r.entity) {components_prune(w,r.entity,net_type(s,r.type),after)}
    if r.samples>=0 {wire.interpolation_clear(&c.interpolation,int(r.samples))}
    if r.slot>=0 {
        authority_clear(s,r)
        for index in 0..<c.history {c.records[index*s.desc.predicted_capacity+int(r.slot)].object=0}
    }
    r.type_before,r.retyped,r.retyped_set=r.type,c.newest,c.any
    r.type,r.role,r.simulation,r.available,r.shown_set=command.type,command.role,command.simulation,0,false
    replica_state(s,r,command)
    replica_place(s,w,assets,r)
    if r.waits {return}
    if core.alive(core.world_entities(w),r.entity) {components_apply(s,w,r.entity,after,command,r.available)}
    replica_classify(s,w,r)
    replica_sample(s,r,r.available)
    authoritative_capture(s,r,command)
    r.pending=r.mode==.Predicted
}

// The components of a type that another one does not list leave the entity.
@(private)
components_prune :: proc(w:core.World_Ref,e:core.Entity,before,after:^Net_Type) {
    for table in before.tables[:before.count] {
        if !type_has(after,table) {core.raw_remove(core.world_table_at(w,&w.info.tables[table]),e)}
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
        if r.object==0 || r.samples<0 {continue}
        spacing:=wire.interpolation_spacing(&c.interpolation,int(r.samples))
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
        for &r,index in c.replicas[:c.replica_high] {frame.shown[index]={r.object,r.mode==.Interpolated?r.delay:-1,r.shown,r.shown_set}}
        frame.valid=false
        if frame_copy(w,frame) {
            frame.tick,frame.valid=tick,true
            if input!=nil {frame.input=input^}
            frame.content=host.content_generation(app)
        } else {snapshot_problem(s,tick)}
        s.stats.snapshot_seconds+=time.duration_seconds(time.tick_since(started))
    } else if frame.tick==tick && !c.sync_testing {
        if !frame_copy(w,frame) {frame.valid=false;snapshot_problem(s,tick)}
    }
    client_place(s,w,frame.interpolation,frame.shown,resimulating)
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
    // Marks of no copy: every table again.
    if frame.whole {mem.zero_slice(frame.marks)}
    if !core.world_copy_changed(w.info,frame.world,w.data,frame.marks) {return false}
    frame.whole=false
    return true
}

@(private)
snapshot_problem :: proc(s:^Net_Session,tick:u32) {
    core.report(s.problems,core.NONE,"net.snapshot","the copy of the world at tick %d was not made (out of memory), so a correction of the server cannot go back to it; free memory, or lower Net_Settings.replication.history_seconds",tick)
}

// The interpolated replicas go where the buffer has them at a server tick,
// each as far behind it as shown says it was when the tick ran first (by
// object index); one that did not exist then, as far as its states come apart
// now. A tick that runs again starts from the components it started from.
@(private)
client_place :: proc(s:^Net_Session,w:core.World_Ref,tick:f64,shown:[]Shown,resimulating:bool) {
    c:=&s.client
    es:=core.world_entities(w)
    for &r,index in c.replicas[:c.replica_high] {
        if r.object==0 || r.mode!=.Interpolated || r.samples<0 || !core.alive(es,r.entity) {continue}
        delay:=r.delay
        if was:=index<len(shown) && shown[index].object==r.object && shown[index].ticks>=0;was {
            delay=shown[index].ticks
            if resimulating {r.shown,r.shown_set=shown[index].state,shown[index].state_set}
        } else if resimulating {
            r.shown_set=false
        }
        at:=tick-f64(max(delay,0))
        replica_show(s,w,&r,at)
        if core.entity_off(es,r.entity) {continue}
        if sample,ok:=replica_blend(s,&r,at);ok {
            feed_state(c,r.object,sample.pose,sample.motion)
            pose_follow(s,w,r.entity,net_type(s,r.type),sample.pose,sample.motion)
        }
    }
}

// The components and the Move_Input of an interpolated replica are those of
// the newest state of the server the display reached, like its pose: its
// entity takes the fields that changed in the states since the one it has, or
// every one it knows when that one is not kept any more.
@(private)
replica_show :: proc(s:^Net_Session,w:core.World_Ref,r:^Replica,tick:f64) {
    c:=&s.client
    reached:[]u8
    at:u32
    mask:u64
    whole:=!r.shown_set
    for index in 0..<wire.interpolation_count(&c.interpolation,int(r.samples)) {
        state,state_tick,_:=wire.interpolation_entry(&c.interpolation,int(r.samples),index)
        if f64(state_tick)>tick {break}
        if r.shown_set && i32(state_tick-r.shown)<=0 {continue}
        whole||=index==0
        reached,at=state,state_tick
        mask|=(^Sample)(raw_data(state)).mask
    }
    if reached==nil {return}
    command:=wire.Command{kind=.Object_Updated,type=r.type,object=r.object,tick=at,mask=whole?(^Sample)(raw_data(reached)).available:mask,words=sample_words(c,reached)}
    feed(c,r.object);feed(c,at);feed(c,command.mask)
    components_apply(s,w,r.entity,net_type(s,r.type),&command,command.mask)
    driver_apply(s,w,r,&command)
    r.shown,r.shown_set=at,true
}

// The state of a replica at a server tick: between the two around it, or past
// the newest one with its velocity for a while and then still.
@(private)
replica_blend :: proc(s:^Net_Session,replica:^Replica,tick:f64) -> (out:Sample,ok:bool) {
    from,to,alpha,status:=wire.interpolation_sample(&s.client.interpolation,int(replica.samples),tick)
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
// or a change of timeline left on the drawing of a replica fades. The
// interpolated ones move in the ticks, and the frame draws them between the
// last two like everything else.
@(private)
client_frame :: proc(s:^Net_Session,w:core.World_Ref,dt:f32) {
    c:=&s.client
    es:=core.world_entities(w)
    offsets:=core.world_table_of(w,render.Draw_Offset)
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || r.mode==.Here || !core.alive(es,r.entity) {continue}
        wire.smoothing_update(&r.smoothing,dt)
        drawn,has:=core.get(core.read(offsets),r.entity)
        if !has || drawn.offset==r.smoothing.offset && drawn.rotation==r.smoothing.rotation {continue}
        shown:=core.edit(offsets,r.entity)
        shown.offset,shown.rotation=r.smoothing.offset,r.smoothing.rotation
    }
}

// After a tick: what this client holds the authority of goes to the server,
// and the pose of every predicted replica is remembered to compare with the
// state of the server.
@(private)
client_tail :: proc(s:^Net_Session,w:core.World_Ref,tick:u32,outbox:^Net_Outbox) {
    c:=&s.client
    h:=&s.host
    c.newest,c.any=tick,true
    driven_list(c)
    records_capture(s,w,tick)
    if s.desc.sync_test>0 {
        // What the tick left, settled as a tick run again leaves it.
        core.world_settle(w)
        sync_hashes(s,w,c.sync_hashes[(int(tick)%s.client.history)*(len(w.info.tables)+1):][:len(w.info.tables)+1])
    }
    if s.status==.Connected {
        // With an input delay, what the devices gave in this tick is the input of a later one.
        delay:=u32(s.desc.input_delay)
        packet:=Input_Packet{actions=delay>0?c.taken[int(tick)%len(c.taken)].actions:driven_actions(s,w),look_behind=u8(delay)}
        look:[2]f32
        look,packet.has_look=driven_look(w)
        packet.look_yaw,packet.look_pitch=mm.angle_wrap(look[0]),look[1]
        // What the others looked like on this player's screen when the input of this frame was
        // taken (frame_view_take): every tick of the frame runs that input.
        view,shown:=shown_tick(s,w,tick)
        if c.frame_view_ok {view=c.frame_view}
        if shown {
            packet.view_behind=f32(clamp(f64(tick+delay)-view,0,255))
            packet.has_view=true
        }
        wire.input_submit(h,tick+delay,&packet)
    }
    client_upload(s,w)
    events_send(s,outbox)
    wire.host_publish(h,tick)
}

// The replicas this client drives: listed before a tick is recorded, and
// once for all the ticks a correction runs again, which change none.
@(private)
driven_list :: proc(c:^Client) {
    c.driven_count=0
    for &r,index in c.replicas[:c.replica_high] {
        if r.object==0 || r.role!=.Predicted && r.role!=.Held {continue}
        c.driven[c.driven_count]=i32(index)
        c.driven_count+=1
    }
}

// What each predicted replica is after a tick (replica_now: a correction that
// just put it at the state of the server of the tick is that state), and
// which of them share a group of the simulation (core.Motion.island) with
// what this client drives (driven_list): what touches it or is joined to it
// now. The groups are of the tick: each one of what it drives, once.
@(private)
records_capture :: proc(s:^Net_Session,w:core.World_Ref,tick:u32) {
    c:=&s.client
    d:=&s.desc
    motions:=core.world_table_of(w,core.Motion)
    es:=core.world_entities(w)
    c.record_ticks[int(tick)%c.history]=tick+1
    row:=c.records[(int(tick)%c.history)*d.predicted_capacity:][:d.predicted_capacity]
    islands:=0
    for index in c.driven[:c.driven_count] {
        r:=&c.replicas[index]
        if !core.alive(es,r.entity) {continue}
        motion,has:=core.get(motions,r.entity)
        if !has || motion.island==0 || slice.contains(c.islands[:islands],motion.island) {continue}
        c.islands[islands]=motion.island
        islands+=1
    }
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 || !core.alive(es,r.entity) {continue}
        motion,has_motion:=core.get(motions,r.entity)
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
        local,has_pose:=core.get(transforms,r.entity)
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
        held_hash:=base.HASH_SEED
        for k in 0..<t.count {
            info:=&w.info.tables[t.tables[k]]
            if value:=core.raw_find(core.world_table_at(w,info),info.info,r.entity);value!=nil {held_hash=base.hash64(mem.byte_slice(value,info.info.size),held_hash)}
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

// A predicted replica takes a state of the server in the present, when the
// world cannot go back to its tick: it goes where the state had it, carried
// by its velocity, or moves by what it was off at that tick. The drawing
// closes the jump, and what it predicted until now is not compared again.
@(private)
replica_place_now :: proc(s:^Net_Session,w:core.World_Ref,x:^Replica,command:^wire.Command,tick_dt:f32) {
    c:=&s.client
    now,alive:=replica_now(s,w,x)
    if !alive {return}
    t:=net_type(s,x.type)
    pose:Pose
    motion:Motion_State
    wire.object_read(&s.host,command,0,&pose,max(u64))
    if t.motion>=0 {wire.object_read(&s.host,command,t.motion,&motion,max(u64))}
    components_apply(s,w,x.entity,t,command,command.mask)
    ahead:=f32(max(i32(c.newest-command.tick),0))*tick_dt
    wanted:=Present{position=pose.position+motion.linear*ahead,rotation=pose.rotation,scale=pose.scale,linear=motion.linear,angular=motion.angular,asleep=t.motion>=0 && resting(&motion)}
    // With what it predicted for that tick, the present keeps what it did since and moves by the error found there.
    if record,_:=record_of(c,&s.desc,x,command.tick);record!=nil && !wanted.asleep {
        off:=motion.linear-record.linear
        wanted.position=now.position+pose.position-record.position+off*ahead
        wanted.rotation=linalg.normalize(pose.rotation*conj(record.rotation)*now.rotation)
        wanted.linear,wanted.angular=now.linear+off,now.angular+motion.angular-record.angular
    }
    replica_put(s,w,x,&wanted)
    core.world_settle(w)
    for index in 0..<c.history {c.records[index*s.desc.predicted_capacity+int(x.slot)].object=0}
    wire.smoothing_correct(&x.smoothing,now.position,wanted.position,now.rotation,wanted.rotation,x.switched?SWITCH_HALF_LIFE:0)
    s.stats.placed+=1
}

// A replica goes to the timeline the rule gives it now; where it was drawn
// stays as an error that fades. Turning predicted, it asks the world to go
// back to its newest state (true), so that the ticks since run again with it
// simulated, or takes that state now. Turning interpolated, it is put where
// its states have it at the tick shown.
@(private)
replica_switch :: proc(s:^Net_Session,w:core.World_Ref,x:^Replica,tick_dt:f32) -> (back:bool) {
    c:=&s.client
    was:=x.mode
    before,alive:=replica_now(s,w,x)
    replica_classify(s,w,x)
    if x.mode==was || !alive {return false}
    x.switched=true
    s.stats.switched+=1
    if x.mode==.Predicted {
        if i32(c.newest-x.tick)>0 {return true}
        command:=replica_command(s,x)
        replica_place_now(s,w,x,&command,tick_dt)
    } else if sample,ok:=replica_blend(s,x,wire.clock_interpolation_tick(&s.host,c.newest)-f64(max(x.delay,0)));ok {
        pose_apply(s,w,x.entity,net_type(s,x.type),sample.pose,sample.motion,true)
        core.world_settle(w)
        wire.smoothing_correct(&x.smoothing,before.position,sample.pose.position,before.rotation,sample.pose.rotation,SWITCH_HALF_LIFE)
    }
    return false
}

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
    compared,differing:=0,0
    // A replica that differs, or turns predicted, asks the world to go back to tick at.
    back :: proc(x:^Replica,at:u32,target:^u32,differing:^int) {
        if !x.differs || i32(at-x.check)>0 {x.check=at}
        x.differs=true
        if differing^==0 || i32(at-target^)<0 {target^=at}
        differing^+=1
    }
    for &x in c.replicas[:c.replica_high] {
        x.differs,x.switched=false,false
        if x.object==0 {continue}
        fresh:=x.pending
        x.pending=false
        if x.mode!=.Here && !x.waits && replica_wanted(s,&x)!=x.mode {
            if replica_switch(s,w,&x,app.tick_dt) {back(&x,x.tick,&target,&differing)}
            continue
        }
        if x.mode!=.Predicted || x.slot<0 {continue}
        handled,inside:=false,false
        stale:wire.Command
        for index in 0..<c.history {
            authority,words:=authority_slot(s,&x,index)
            if authority.object!=x.object || authority.checked || i32(authority.tick-newest)>0 {continue}
            authority.checked=true
            handled=true
            command:=wire.Command{kind=.Object_Updated,type=x.type,object=x.object,tick=authority.tick,mask=authority.available,words=words}
            record,kept:=record_of(c,d,&x,authority.tick)
            if record==nil {
                if !kept {
                    s.stats.unverified+=1
                    if stale.words==nil || i32(authority.tick-stale.tick)>0 {stale=command}
                }
                continue
            }
            inside=true
            pose:Pose
            motion:Motion_State
            wire.object_read(&s.host,&command,0,&pose,max(u64))
            t:=net_type(s,x.type)
            if t.motion>=0 {wire.object_read(&s.host,&command,t.motion,&motion,max(u64))}
            compared+=1
            if record_differs(d,t.motion>=0,record,&pose,&motion) || record_components_differ(s,&x,authority.tick,&command) {back(&x,authority.tick,&target,&differing)}
        }
        // A state older than the history is still the newest news of the replica: it goes where that state has it.
        if stale.words!=nil && !inside {replica_place_now(s,w,&x,&stale,app.tick_dt)}
        if handled || fresh {continue}
        tick:=c.quiet
        if !c.quiet_set || !resting(&x.motion) || i32(tick-x.tick)<=0 || i32(tick-newest)>0 {continue}
        if x.verified_set && i32(tick-x.verified)<=0 {continue}
        record,_:=record_of(c,d,&x,tick)
        if record==nil {continue}
        x.verified,x.verified_set=tick,true
        compared+=1
        command:=replica_command(s,&x)
        if record_differs(d,net_type(s,x.type).motion>=0,record,&x.pose,&x.motion) || record_components_differ(s,&x,tick,&command) {back(&x,tick,&target,&differing)}
    }
    if compared>0 && differing==0 {s.stats.confirmed+=1}
    if differing==0 {return}
    started:=time.tick_now()
    if !client_rewind(s,w,app,target) {
        s.stats.deferred+=1
        for &x in c.replicas[:c.replica_high] {
            if x.object==0 || !x.differs || x.mode!=.Predicted {continue}
            command,found:=authoritative_command(s,&x,x.check,false)
            if !found {command=replica_command(s,&x)}
            replica_place_now(s,w,&x,&command,app.tick_dt)
        }
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
    for &x in c.replicas[:c.replica_high] {x.switched=false}
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
    }
    present_input:core.Input
    if input!=nil {present_input=input^}
    restored:=&c.frames[int(start)%len(c.frames)]
    if !host.app_world_replace(app,w.data,restored.world,restored.whole?nil:restored.marks) {
        for &x in c.replicas[:c.replica_high] {x.corrected=false}
        core.report(s.problems,core.NONE,"net.rollback","a correction of the server could not go back to tick %d: out of memory for the copy of the world, so the prediction keeps its error; free memory",start)
        return false
    }
    for &frame in c.frames {
        if &frame!=restored {core.copy_marks_follow(w,restored.marks,frame.marks)}
    }
    core.copy_marks_follow(w,restored.marks,restored.marks)
    clock.resimulating=true
    replicas_relink(s,w,app.assets,start)
    driven_list(c)
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
    outbox_follow(w)
    if input!=nil {input^=present_input}
    for &x in c.replicas[:c.replica_high] {
        if x.object==0 || x.waits {continue}
        // The ticks that ran again did not make the entity this client had made ahead of the server.
        if x.entity==core.NONE {
            replica_spawn(s,w,app.assets,&x)
            replica_components(s,w,&x,x.mode)
        } else if x.mode==.Here && core.alive(core.world_entities(w),x.entity) {
            command:=replica_command(s,&x)
            components_apply(s,w,x.entity,net_type(s,x.type),&command,x.available)
        }
    }
    core.world_settle(w)
    references_refresh(s,w)
    behind:=int(i32(c.newest-target))
    s.stats.corrected+=1
    s.stats.largest_resimulation=max(s.stats.largest_resimulation,behind)
    for &x in c.replicas[:c.replica_high] {
        if !x.corrected || x.object==0 || x.mode!=.Predicted {continue}
        after:=replica_now(s,w,&x) or_continue
        wire.smoothing_correct(&x.smoothing,x.before.position,after.position,x.before.rotation,after.rotation,x.switched?SWITCH_HALF_LIFE:0)
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
    if !core.world_copy(w.info,c.sync_world,w.data) {return}
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
        outbox_follow(w)
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
    core.world_swap(w.info,w.data,c.sync_world)
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

// After the world was replaced by the copy of tick start: the replicas that
// did not exist then are made again, and the entities of replicas that ended
// since are destroyed. An entity this client made ahead of the server in a
// tick that runs again is made by that tick, and taken then (spawns_settle).
@(private)
replicas_relink :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,start:u32) {
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
        if r.object==0 || r.waits || r.entity==core.NONE && r.spawned_set && i32(r.spawned-start)>=0 {continue}
        if r.entity==core.NONE {
            replica_spawn(s,w,assets,&r)
            s.stats.spawned-=1
        } else if r.retyped_set && i32(r.retyped-start)>=0 {
            // The copy has the components of the type the replica had then.
            command:=replica_command(s,&r)
            components_prune(w,r.entity,net_type(s,r.type_before),net_type(s,r.type))
            components_apply(s,w,r.entity,net_type(s,r.type),&command,r.available)
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
replica_adopt :: proc(s:^Net_Session,w:core.World_Ref,id:base.Entity_Id,e:core.Entity) -> ^Replica {
    if !s.host_ready || s.mode!=.Client || id==0 {return nil}
    es:=core.world_entities(w)
    links:=core.world_table_of(w,Net_Link)
    if core.has(links,e) {return nil}
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object==0 || r.waits || r.pose.id!=id {continue}
        if r.entity==e {return &r}
        if core.alive(es,r.entity) {core.world_destroy_tree(w,r.entity)}
        r.entity,r.adopted=e,true
        replicate:=REPLICATE_DEFAULT
        replicate.simulation=r.simulation
        core.add(core.world_table_of(w,Replicate),e,replicate)
        core.add(links,e,Net_Link{object=r.object})
        wire.object_bind(&s.host,r.object,u64(e))
        replica_components(s,w,&r,r.mode)
        return &r
    }
    return nil
}

// Client, after a tick: an entity this client made ahead of the server
// (Predicted_Spawn) takes the place of the entity of the replica the server
// sent for it; one no replica took within the history was not made by the
// server, and goes.
@(private)
spawns_settle :: proc(s:^Net_Session,w:core.World_Ref,time:^core.Time) {
    spawns:=core.world_table_of(w,Predicted_Spawn)
    if spawns==nil {return}
    for row in 0..<core.count(spawns) {
        e,spawn:=core.entity_at(spawns,row),spawns.values[row]
        if r:=replica_adopt(s,w,core.id_of(core.read(core.world_table_of(w,core.Id)),e),e);r!=nil {
            r.adopted,r.spawned,r.spawned_set=false,u32(spawn.tick),true
            core.remove(spawns,e)
            replica_classify(s,w,r)
        } else if !time.resimulating && time.tick>spawn.tick+u64(s.client.history) {
            core.world_destroy_tree(w,e)
        }
    }
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
        move,has:=core.get(moves,core.entity_at(drivables,row))
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
        delay:=frame.shown[index]
        if delay.object!=r.object || delay.ticks<0 {continue}
        sum+=f64(delay.ticks)
        count+=1
    }
    return frame.interpolation-(count>0?sum/f64(count):0),true
}
