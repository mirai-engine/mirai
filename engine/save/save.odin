package save

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "base:runtime"

// Save games: the world written to a slot, a file in the folder the user
// keeps for the game. A slot holds every entity with its components, hierarchy
// and references between them, as a scene document; fields tagged transient
// are not saved and a component stored with another layout migrates by the
// names of its fields. What the simulation derives (bodies, replicas, caches)
// is rebuilt by the libraries that own it from the components, so a library
// whose state is not in a component of its entities keeps it in a field of one:
// the velocities of bodies and characters are in core.Motion,
// the time of a clip in Animation_Progress. Loading clears the World, whose
// derived storages (the physics simulation among them) start again. An entity
// without an Id, as a transient copy, is lent one for the trip and gets back
// without it. A slot remembers the scene the world was (scene.Scene_Root), and
// is that scene again once loaded.
//
// Its header says what it is without reading the world: the label the game
// gave it, its kind, the scene, the time played, when it was written and a
// thumbnail of the view of the player (writes.odin). Autosaves and
// checkpoints are slots too (autosave.odin).
//
// A server of a network session saves and loads too; a client does not. What
// another end decides or asks of an entity (core.Remote, core.Pose_Target) is
// of the session, not of the game: a slot leaves it out, and keeps of what a
// client simulated the last state the server has.
//
// Games ask with a Save_Requests queue and read the answer in Save_Results.
// The world changes while functions run, so the request is served at the
// start of the next frame, with what the tick that asked left.

SLOT_CAPACITY :: 48
LABEL_CAPACITY :: 64
EXTENSION :: ".save"
FOLDER :: "saves"
VERSION :: u32(7)
CHECKPOINT :: "checkpoint" // the slot of the last checkpoint

@(private) MAGIC :: [4]u8{'M','S','A','V'}
@(private) DOCUMENT :: base.Asset_Id{0x6576617369617269,1}

// New starts a game, End ends it and Label names it.
Op :: enum u8 {Save,Load,Delete,New,End,Label}

Slot_Kind :: enum u8 {Manual,Autosave,Checkpoint}

Error :: enum u8 {
    None,
    Invalid_Slot, // empty, too long, more than letters, digits, spaces, '-' and '_', or a Windows device name
    Invalid_Label,// longer than LABEL_CAPACITY-1 bytes
    Unavailable,  // the world is a client of a network session, or there is no folder for slots
    Not_Found,
    Corrupt,      // not a save, or one that contradicts itself
    Version,      // written by another version of the engine
    Failed,       // the world could not be captured, or the slot did not load into it: then it stays as it was
    Write_Failed,
    Busy,         // WRITES_CAPACITY slots wait to be written
    No_Room,      // THUMBNAIL_TEXTURES thumbnails are held as textures, or the assets or the renderer have no room for another
}

// What the header of a slot says, without reading the world.
Slot :: struct {
    name:[SLOT_CAPACITY]u8 `mirai:"text"`,
    label:[LABEL_CAPACITY]u8 `mirai:"text"`, // the one the game gave it
    kind:Slot_Kind,
    scene:base.Asset_Id, // the scene the world was
    tick:u64,    // of the world when it was written
    seconds:f64, // simulated
    played:f64,  // seconds of play of its game (Save_Game.played)
    written:i64, // seconds since 1970 UTC
    entities:u32,
    thumbnail:u32, // bytes of the PNG of the view of the player (slot_thumbnail); 0: none
    size:i64,      // bytes of the file
    version:u32,   // VERSION of the engine that wrote it; 0: not a save
    error:Error,   // Corrupt or Version: it does not load, and only name, size and version say something
}

Request :: struct {
    op:Op,
    kind:Slot_Kind,
    slot:[SLOT_CAPACITY]u8 `mirai:"text"`,   // empty for an autosave: the oldest of them
    label:[LABEL_CAPACITY]u8 `mirai:"text"`, // empty: the label of the game (Save_Game)
    invalid:Error, // what is wrong with what was asked: it is not served, and is a problem
}

Result :: struct {
    op:Op,
    kind:Slot_Kind,
    error:Error,
    slot:[SLOT_CAPACITY]u8 `mirai:"text"`,
}

// Requests: the games push, this library takes them.
@(storage,queue,keep)
Save_Requests :: struct {queue:core.Queue(Request)}

// Events: this library clears them at each frame and pushes one per request
// served, and one per autosave it made by itself. A slot written later (its
// thumbnail, a job) brings its own in the frame it is written.
@(storage,events,keep)
Save_Results :: struct {queue:core.Queue(Result)}

// Where the slots are kept: the folder set, or <user data>/Mirai/<project>/saves.
@(storage,host)
Save_State :: struct {
    folder:string,
    resolved:bool,
}

@(private)
Header :: struct {
    magic:[4]u8,
    version:u32,
    tick:u64,
    seconds:f64,
    played:f64,
    written:i64,     // nanoseconds since 1970 UTC
    bytes:u64,       // of the scene document
    entities:u32,
    lent:u32,        // Ids lent for the trip to entities without one, listed after the document
    thumbnail:u32,   // bytes of the PNG right after the header
    kind:Slot_Kind,
    scene:base.Asset_Id, // the scene the world was
    label:[LABEL_CAPACITY]u8,
}

slot_name :: proc "contextless" (slot:^Slot) -> string {return base.text_get(slot.name[:])}

slot_valid :: proc "contextless" (slot:string) -> bool {
    if slot=="" || len(slot)>=SLOT_CAPACITY || slot[0]==' ' || slot[len(slot)-1]==' ' {return false}
    for c in transmute([]u8)slot {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9',' ','-','_':
        case: return false
        }
    }
    return !slot_reserved(slot)
}

// The names Windows keeps for devices, in any case: a slot is valid on every system or on none.
@(private)
slot_reserved :: proc "contextless" (slot:string) -> bool {
    if len(slot)!=3 && len(slot)!=4 {return false}
    lower:[4]u8
    for c,i in transmute([]u8)slot {lower[i]=c|0x20}
    name:=string(lower[:len(slot)])
    switch name {
    case "con","prn","aux","nul": return true
    }
    return len(name)==4 && (name[:3]=="com" || name[:3]=="lpt") && name[3]>='0' && name[3]<='9'
}

error_text :: proc(error:Error) -> string {
    switch error {
    case .None:         return ""
    case .Invalid_Slot: return "the save slot name is not valid: use up to 47 letters, digits, spaces, '-' or '_', without leading or trailing spaces, and not a device name such as con or com1"
    case .Invalid_Label: return "the label of the save is too long: keep it under 64 bytes"
    case .Unavailable:  return "a client of a network session does not save: the server does"
    case .Not_Found:    return "no save exists in that slot"
    case .Corrupt:      return "the save is corrupt"
    case .Version:      return "the save was written by another engine version"
    case .Failed:       return "the world could not be captured or restored"
    case .Write_Failed: return "the save file could not be written"
    case .Busy:         return "too many slots are waiting to be written; wait for their results"
    case .No_Room:      return "there is no room for another thumbnail texture: release those no longer shown with thumbnail_release"
    }
    return ""
}

// Requests return nothing: the answer of each is in Save_Results, and a slot
// or a label that is not valid is also a problem that says how to fix it.

// Queues saving the world to a slot, with a label or that of the game.
request_save :: proc(requests:^Save_Requests,slot:string,label:="") {request(requests,.Save,slot,label=label)}

// Queues replacing the world with the one of a slot: every entity is destroyed
// and those of the slot take their place, so handles change and events in
// flight name entities that are gone.
request_load :: proc(requests:^Save_Requests,slot:string) {request(requests,.Load,slot)}

request_delete :: proc(requests:^Save_Requests,slot:string) {request(requests,.Delete,slot)}

// Queues an autosave: into the oldest of the slots of autosave.
request_autosave :: proc(requests:^Save_Requests,label:="") {request(requests,.Save,"",.Autosave,label)}

// Queues a checkpoint: the world into the slot CHECKPOINT.
request_checkpoint :: proc(requests:^Save_Requests,label:="") {request(requests,.Save,CHECKPOINT,.Checkpoint,label)}

// Queues loading the last checkpoint.
request_load_checkpoint :: proc(requests:^Save_Requests) {request(requests,.Load,CHECKPOINT)}

// Queues starting a game: no time played, the label given, and autosaves on.
request_new_game :: proc(requests:^Save_Requests,label:="") {request(requests,.New,"",label=label)}

// Queues ending the game, as a menu does: no autosaves and no time played
// until a new game or a load.
request_end_game :: proc(requests:^Save_Requests) {request(requests,.End,"")}

// Queues naming the game: the label of the slots that are not given one.
request_label :: proc(requests:^Save_Requests,label:string) {request(requests,.Label,"",label=label)}

request :: proc(requests:^Save_Requests,op:Op,slot:string,kind:=Slot_Kind.Manual,label:="") {
    r:=Request{op=op,kind=kind,invalid=request_error(op,slot,kind,label)}
    base.text_set(r.slot[:],slot)
    base.text_set(r.label[:],label)
    core.push(&requests.queue,r)
}

// What is wrong with a request, for who answers at once (an API).
request_error :: proc(op:Op,slot:string,kind:=Slot_Kind.Manual,label:="") -> Error {
    if (op==.Save || op==.Load || op==.Delete) && kind!=.Autosave && !slot_valid(slot) {return .Invalid_Slot}
    return len(label)>=LABEL_CAPACITY?.Invalid_Label:.None
}

// Where the slots are kept from now on; made when the first one is written.
// False, with no folder for them, without memory for its name.
folder_set :: proc(state:^Save_State,allocator:runtime.Allocator,path:string) -> bool {
    delete(state.folder,allocator)
    error:mem.Allocator_Error
    state.folder,error=strings.clone(path,allocator)
    state.resolved=true
    return error==nil
}

// The folder of the slots, "" when there is none.
folder :: proc(state:^Save_State,app:^host.App) -> string {
    if state.resolved {return state.folder}
    state.resolved=true
    user:=host.app_user_folder(app.root,context.temp_allocator)
    if user=="" {return ""}
    joined,error:=filepath.join({user,FOLDER},app.allocator)
    // Asked again: there is one, and no memory for its name now.
    if error!=nil {state.resolved=false}
    state.folder=joined
    return state.folder
}

@(private)
slot_path :: proc(state:^Save_State,app:^host.App,slot:string) -> (path:string,error:Error) {
    if !slot_valid(slot) {return "",.Invalid_Slot}
    dir:=folder(state,app)
    if dir=="" {return "",.Unavailable}
    return strings.concatenate({dir,"/",slot,EXTENSION},context.temp_allocator),.None
}

// The header of the slot at path and the size of its file; Version keeps the
// magic and the version of the header, Corrupt nothing.
@(private)
slot_header :: proc(path:string) -> (header:Header,size:i64,error:Error) {
    buffer:[size_of(Header)]u8
    head,bytes,read_error:=serial.file_read_head(path,buffer[:])
    if read_error!=.None {return {},0,os.exists(path)?.Corrupt:.Not_Found}
    mem.copy(&header,raw_data(buffer[:]),size_of(Header))
    switch {
    case len(head)<size_of(MAGIC)+size_of(u32) || header.magic!=MAGIC: return {},bytes,.Corrupt
    case header.version!=VERSION: return {magic=MAGIC,version=header.version},bytes,.Version
    case len(head)<size_of(Header): return {},bytes,.Corrupt
    }
    return header,bytes,.None
}

// What the header of the slot at path says, with why it does not load.
@(private)
slot_of :: proc(path,name:string) -> (slot:Slot) {
    header,size,error:=slot_header(path)
    slot={
        label=header.label,kind=header.kind,scene=header.scene,tick=header.tick,seconds=header.seconds,played=header.played,
        written=header.written/1_000_000_000,entities=header.entities,thumbnail=header.thumbnail,size=size,version=header.version,error=error,
    }
    base.text_set(slot.name[:],name)
    return
}

// What the header of a slot says, without reading the world; its error says
// why it does not load: also Invalid_Slot, Unavailable and Not_Found.
slot_info :: proc(state:^Save_State,app:^host.App,slot:string) -> (info:Slot) {
    path,error:=slot_path(state,app,slot)
    if error!=.None {
        base.text_set(info.name[:],slot)
        info.error=error
        return
    }
    return slot_of(path,slot)
}

// The slots of the folder, by name, from their headers: how many it wrote to
// out. With all, also those that do not load, each with its error.
slots :: proc(state:^Save_State,app:^host.App,out:[]Slot,all:=false) -> (count:int) {
    dir:=folder(state,app)
    if dir=="" {return 0}
    files,error:=os.read_all_directory_by_path(dir,context.temp_allocator)
    if error!=nil {return 0}
    slice.sort_by(files,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    for entry in files {
        if count>=len(out) {break}
        name:=strings.trim_suffix(entry.name,EXTENSION)
        if len(name)==len(entry.name) || !slot_valid(name) {continue}
        slot:=slot_of(entry.fullpath,name)
        if slot.error==.Not_Found || (slot.error!=.None && !all) {continue}
        out[count]=slot;count+=1
    }
    return
}

// The thumbnail of a slot as a PNG, read without the rest of it; nil when it
// has none. The caller owns it.
slot_thumbnail :: proc(state:^Save_State,app:^host.App,slot:string,allocator:=context.allocator) -> (png:[]u8,error:Error) {
    path:=slot_path(state,app,slot) or_return
    header,_:=slot_header(path) or_return
    if header.thumbnail==0 {return nil,.None}
    at:=mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT)
    buffer:=make([]u8,at+int(header.thumbnail),context.temp_allocator)
    head,_,read_error:=serial.file_read_head(path,buffer)
    if read_error!=.None || len(head)<len(buffer) {return nil,.Corrupt}
    copied,no_copy:=slice.clone(head[at:],allocator)
    if no_copy!=nil {return nil,.Failed}
    return copied,.None
}

delete_slot :: proc(state:^Save_State,app:^host.App,slot:string) -> Error {
    path:=slot_path(state,app,slot) or_return
    if !os.exists(path) {return .Not_Found}
    return os.remove(path)==nil?.None:.Write_Failed
}

// Serves the requests of the tick before, first thing of the frame, and the
// autosaves that are due. The first time a world runs it reads the profile
// of the player into it, and from then on it keeps the files of the player
// up to date (kept_watch).
@(step="input",loops="game")
saves_serve :: proc(
    world:core.World_Ref,app:^host.App,requests:^Save_Requests,results:^Save_Results,state:^Save_State,work:^Save_Work,
    thumbnails:^Save_Thumbnails,game:^Save_Game,settings:core.Ref(Save_Settings),profile:^Profile_State,bindings:core.Ref(inp.Input_Map),
    authority:core.Ref(core.Network),frame:core.Ref(core.Frame_Time),clock:core.Ref(core.Clock),
    references:core.Read(scene.Scene_Reference),problems:^core.Problems,
) {
    core.queue_clear(&results.queue)
    if !profile.read {
        profile.read=true
        if error:=profile_read(world,app,state);error!=.None && error!=.Not_Found && error!=.Unavailable {
            path,_:=profile_path(state,app)
            core.report(problems,core.NONE,"save.profile","the profile of the player %s did not read: %s; the progress starts from its defaults until the game writes it again, or delete the file",path,error_text(error))
        }
    }
    if !game.off && !clock.paused {game.played+=f64(frame.dt)}
    if work!=nil {
        work.frame+=1
        writes_step(work,app.renderer,&app.jobs,results,problems)
    }
    // A load replaces the world, and with it the buffer the requests were taken from.
    asked,_:=slice.clone(core.take(&requests.queue),context.temp_allocator)
    for &r in asked {
        result:=Result{op=r.op,kind=r.kind,slot=r.slot}
        queued:=false
        switch {
        case r.invalid!=.None:
            result.error=r.invalid
            core.report(problems,core.NONE,"save.request","the request to %v the slot %s was refused: %s",r.op,base.text_get(r.slot[:]),error_text(r.invalid))
        case r.op==.New:     game^={label=r.label}
        case r.op==.End:     game.off=true
        case r.op==.Label:   game.label=r.label
        case authority.role==.Client: result.error=.Unavailable
        case r.op==.Save:
            slot:=r.kind==.Autosave?autosave_slot(state,app,work,settings.autosave_slots):base.text_get(r.slot[:])
            base.text_set(result.slot[:],slot)
            queued,result.error=slot_save(world,app,state,work,game,result,slot,game_label(game,&r))
        case r.op==.Load:
            writes_flush(work,&app.jobs,results)
            result.error=read(world,app,state,base.text_get(r.slot[:]),game)
            if result.error==.None {autosave_settle(work,core.world_storage_of(world,scene.Scene_Root))}
        case r.op==.Delete:
            writes_flush(work,&app.jobs,results)
            result.error=delete_slot(state,app,base.text_get(r.slot[:]))
            thumbnail_release(thumbnails,app.assets,base.text_get(r.slot[:]))
        }
        if !queued {core.push(&results.queue,result)}
    }
    if work==nil {return}
    kept_watch(work,world,app,state,bindings.ptr,frame.dt,problems)
    root:scene.Scene_Root
    if r:=core.world_storage_of(world,scene.Scene_Root);r!=nil {root=r^}
    due:=autosave_watch(work,game,settings.ptr^,root,references)
    if game.off || authority.role==.Client {work.due=false} else {work.due||=due}
    if work.due {
        result:=Result{op=.Save,kind=.Autosave}
        slot:=autosave_slot(state,app,work,settings.autosave_slots)
        base.text_set(result.slot[:],slot)
        queued:bool
        queued,result.error=slot_save(world,app,state,work,game,result,slot,base.text_get(game.label[:]))
        if !queued {core.push(&results.queue,result)}
        // One that cannot be written waits for another interval.
        work.due=result.error==.Busy
        if !work.due {game.saved=game.played}
    }
    writes_step(work,app.renderer,&app.jobs,results,problems)
}

// Captures the world into a slot: queued to be written with its thumbnail in
// a world of the application, at once in another. Busy keeps it uncaptured.
@(private)
slot_save :: proc(w:core.World_Ref,app:^host.App,state:^Save_State,work:^Save_Work,game:^Save_Game,result:Result,slot,label:string) -> (queued:bool,error:Error) {
    path:=slot_path(state,app,slot) or_return
    if work!=nil && len(work.writes)>=WRITES_CAPACITY {return false,.Busy}
    out:serial.Writer
    serial.writer_init(&out,0,app.allocator)
    if error=capture(w,app.assets,app.allocator,&out,result.kind,label,game.played);error!=.None {
        serial.writer_destroy(&out)
        return
    }
    game.saved=game.played
    if work==nil {
        defer serial.writer_destroy(&out)
        return false,slot_file_write(path,serial.writer_bytes(&out),nil)
    }
    error=write_queue(work,app.renderer,app.allocator,result,path,serial.writer_take(&out))
    return error==.None,error
}

// The types of the saves: the ones of the assets, or a local set without them.
@(private)
types_open :: proc(assets:^host.Assets,allocator:runtime.Allocator,local:^asset.Types) -> ^asset.Types {
    if assets!=nil {return &assets.types}
    asset.types_init(local,allocator)
    return local
}

// Writes the world to a slot now, replacing what it held, without a thumbnail.
write :: proc(w:core.World_Ref,app:^host.App,state:^Save_State,slot:string,kind:=Slot_Kind.Manual,label:="",played:=0.0) -> Error {
    path:=slot_path(state,app,slot) or_return
    out:serial.Writer
    serial.writer_init(&out,0,app.allocator)
    defer serial.writer_destroy(&out)
    capture(w,app.assets,app.allocator,&out,kind,label,played) or_return
    return slot_file_write(path,serial.writer_bytes(&out),nil)
}

// The world as the bytes of a slot, without a thumbnail. Entities without an
// Id lend one for the trip.
capture :: proc(w:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,out:^serial.Writer,kind:=Slot_Kind.Manual,label:="",played:=0.0) -> Error {
    if w.place!=.World {return .Failed}
    ids:=core.world_table_of(w,core.Id)
    if ids==nil {return .Failed}
    es:=core.world_entities(w)
    core.world_settle(w)

    present:=make([]bool,core.entities_capacity(es),context.temp_allocator)
    for &t in w.info.tables {
        if t.place!=w.place {continue}
        for e in core.world_table_at(w,&t).entities {present[core.entity_index(e)]=true}
    }
    state:=u64(0)
    lent:=make([dynamic]core.Entity,context.temp_allocator)
    lent_ids:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for yes,index in present {
        if !yes {continue}
        e:=core.entity_make(index,es.generation[index])
        if !core.alive(es,e) {continue}
        if value,_:=core.get(ids,e);value.value!=0 {continue}
        id:=core.id_new(es,&state)
        core.add(ids,e,core.Id{id})
        append(&lent,e)
        append(&lent_ids,id)
    }
    core.world_settle(w)
    defer if len(lent)>0 {
        for e in lent {core.remove(ids,e)}
        core.world_settle(w)
    }

    local:asset.Types
    types:=types_open(assets,allocator,&local)
    defer if types==&local {asset.types_destroy(&local)}
    document:asset.Scene
    // What a network session keeps on entities is of the session, not of the game.
    // A saved game holds no instances: nothing brings it up to date with a prefab.
    excluded:=[]typeid{core.Remote,core.Pose_Target,scene.Prefab_Instance,scene.Prefab_Member}
    report,error:=scene.capture(w,&document,types,{id=DOCUMENT,sections=true,excluded=excluded},allocator)
    if error!=.None {return .Failed}
    defer asset.scene_destroy(&document)
    body:serial.Writer
    serial.writer_init(&body,0,allocator)
    defer serial.writer_destroy(&body)
    if asset.scene_write(&document,&body)!=.None || body.overflow!=0 {return .Failed}

    header:=Header{magic=MAGIC,version=VERSION,entities=u32(report.entities),bytes=u64(body.count),kind=kind,played=played}
    header.written=time.to_unix_nanoseconds(time.now())
    base.text_set(header.label[:],label)
    if clock:=core.world_storage_of(w,core.Time);clock!=nil {header.tick,header.seconds=clock.tick,clock.seconds}
    if root:=core.world_storage_of(w,scene.Scene_Root);root!=nil {header.scene=root.scene}
    header.lent=u32(len(lent_ids))
    serial.write_align(out,serial.WRITER_ALIGNMENT)
    serial.write_bytes(out,mem.ptr_to_bytes(&header))
    serial.write_align(out,serial.WRITER_ALIGNMENT)
    serial.write_bytes(out,serial.writer_bytes(&body))
    serial.write_align(out,serial.WRITER_ALIGNMENT)
    serial.write_bytes(out,slice.to_bytes(lent_ids[:]))
    return out.overflow==0?.None:.Failed
}

// Replaces the world with the one of a slot, and the game with its.
read :: proc(w:core.World_Ref,app:^host.App,state:^Save_State,slot:string,game:^Save_Game=nil) -> Error {
    path:=slot_path(state,app,slot) or_return
    data,file_error:=serial.file_read(path,app.allocator)
    if file_error!=.None {return .Not_Found}
    defer delete(data,app.allocator)
    return restore(w,app,data,game)
}

// Replaces the world with the one in the bytes of a slot, all of it or
// nothing (scene.replace), and the game, when given, with the one it was of.
restore :: proc(w:core.World_Ref,app:^host.App,data:[]u8,game:^Save_Game=nil) -> Error {
    if w.place!=.World {return .Failed}
    if len(data)<size_of(Header) {return .Corrupt}
    header:Header
    mem.copy(&header,raw_data(data),size_of(Header))
    if header.magic!=MAGIC {return .Corrupt}
    if header.version!=VERSION {return .Version}
    at:=u64(mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT))
    at=u64(mem.align_forward_int(int(at)+int(header.thumbnail),serial.WRITER_ALIGNMENT))
    if at>u64(len(data)) || header.bytes>u64(len(data))-at {return .Corrupt}
    lent_at:=u64(mem.align_forward_int(int(at+header.bytes),serial.WRITER_ALIGNMENT))
    if u64(header.lent)>(u64(len(data))-min(lent_at,u64(len(data))))/size_of(base.Entity_Id) {return .Corrupt}
    lent:=make([]base.Entity_Id,header.lent,context.temp_allocator)
    if header.lent>0 {mem.copy(raw_data(lent),&data[lent_at],len(lent)*size_of(base.Entity_Id))}
    slice.sort(lent)

    local:asset.Types
    types:=types_open(app.assets,app.allocator,&local)
    defer if types==&local {asset.types_destroy(&local)}
    file:asset.Asset
    if asset.asset_open(&file,data[at:][:header.bytes],app.allocator)!=.None {return .Corrupt}
    defer asset.asset_close(&file)
    view,view_error:=asset.scene_view(&file,types)
    if view_error!=.None {return .Corrupt}
    if checked:=asset.scene_view_check(view,app.allocator);checked!=.None {return .Failed if checked==.Out_Of_Memory else .Corrupt}

    made:=make([]core.Entity,len(view.ids),context.temp_allocator)
    if _,error:=scene.replace(w,app,&file,types,made,references=false);error!=.None {return .Failed}
    // An Id the trip lent goes back: the entity was transient.
    if ids:=core.world_table_of(w,core.Id);ids!=nil && len(lent)>0 {
        for id,row in view.ids {
            if _,was_lent:=slice.binary_search(lent,id);was_lent {core.remove(ids,made[row])}
        }
        core.world_settle(w)
    }
    if clock:=core.world_storage_of(w,core.Time);clock!=nil {clock.tick,clock.seconds=header.tick,header.seconds}
    if root:=core.world_storage_of(w,scene.Scene_Root);root!=nil {root.scene=header.scene}
    if game!=nil {game^={played=header.played,saved=header.played,label=header.label}}
    return .None
}
