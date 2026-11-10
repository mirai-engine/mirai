package core

import "base:runtime"
import "core:hash/xxhash"
import "core:mem"
import "core:reflect"
import "core:strings"

// Which of the generated structs holds a table or a storage.
Place :: enum u8 {
    World,  // copied for Play and rollback, saved in scenes and games
    Shared, // one per application, never copied: GPU state, voices
    Editor, // the editor's alone
}

Table_Info :: struct {
    name:string,    // the type, as the scene file and the API name it
    library:string, // the package that declares it
    type:typeid,
    info:^runtime.Type_Info, // from the library that declares the type: type_info_of does not find it here
    offset:uintptr, // in the struct of its place
    place:Place,
    shared:bool,
    replicated:Replication,
    game:bool,      // the game of the project declares it, not the engine or a plugin
    default:proc(dst:rawptr), // writes the value a new row starts with; nil: zero
    description:string,
    fields:[]Field_Description, // of the fields of its struct that have a comment on their line
    single:bool, // @(component,single): the world uses one at a time; its table keeps one row on
    far:bool,    // @(component,far): its entity draws a far form of its own, which stays when its section unloads
    base:bool,   // a component of core, the base of every entity: on while its entity is disabled
    locks:[]Lock, // @(component,locks="..."): the rows of other tables of its struct a row on of this one owns
    flat:bool,   // world_info_index found that a value holds nothing behind a pointer: a copy of its bytes is a copy
}

// Which ends of a network session receive the values of a component of the
// entities it replicates: @(component,replicated), replicated="owner",
// replicated="others" or replicated="object".
Replication :: enum u8 {
    None,
    All,    // every end that has the entity
    Owner,  // only the end that owns it
    Others, // every end but the owner
    Object, // every end: an entity with it is replicated without saying so, by the server to every connection
}

// Who sends a message of the network: @(net_message), from="client" or from="owner".
Message_From :: enum u8 {
    Server, // the server, to the clients
    Client, // also a client, to the server
    Owner,  // also a client, about an entity it owns
}

// A structure the network sends as a message, @(net_message): reliable ones
// arrive once and in order, the others may not arrive.
Message_Info :: struct {
    name:string,
    library:string,
    type:typeid,
    info:^runtime.Type_Info,
    from:Message_From,
    reliable:bool,
}

// What the comment on the line of a field of a component says.
Field_Description :: struct {
    name,text:string,
}

// The description of a field of the struct of a component; "" without one.
field_description :: proc(t:^Table_Info,name:string) -> string {
    for field in t.fields {if field.name==name {return field.text}}
    return ""
}

// What the settings files say of a storage.
Setting_Kind :: enum u8 {
    None,
    Project, // @(storage,setting): a setting of the project; only its file holds it
    Machine, // @(storage,setting="machine"): a preference of whoever uses the engine on this machine, held by the file of the engine, which the project may set over
}

Storage_Info :: struct {
    name:string,
    library:string,
    type:typeid,
    info:^runtime.Type_Info,
    offset:uintptr,
    place:Place,
    setting:Setting_Kind,
    default:proc(dst:rawptr),
    by_world:bool, // @(storage,host,by_world): the Shared holds a value of it for each World, in a By_World
    for_device:proc(dst:rawptr,device:rawptr), // the default on a GPU (device: ^rhi.Device_Info), in place of default when there is one: <name>_for_device of its package
    persist:bool, // @(storage,persist): progress of the player that the save library keeps in the profile
    keep:bool,    // @(storage,keep): the state of the run, which clearing the World leaves
    plugin:string, // the plugin whose package declares it; empty for the engine and the project
    game:bool,     // the game of the project declares it, not the engine or a plugin
    local:bool,    // @(storage,copy=false): no copy, swap or clear of the World touches it
    procs:Storage_Procs,
    flat:bool,     // as that of Table_Info
}

// The procedures the attributes of a storage name, in place of what core
// does with its value by reflection; nil without one.
Storage_Procs :: struct {
    copy:proc(dst,src:rawptr) -> bool,      // copy="f"
    copy_kept:proc(dst,src:rawptr) -> bool, // copy_kept="f": into the copy a history keeps
    swap:proc(a,b:rawptr),                  // swap="f"
    free:proc(value:rawptr),                // free="f"
    reset:proc(value:rawptr),               // reset="f": what clearing the World does to it
}

Step_Info :: struct {
    name:string,
    library:string,
    phases:Phases,
    loops:Loops,
    call:Step_Proc, // the function as its loops call it: its binding, its settle and its time
}

// A procedure @(draw="name") of the game: what draws the Draw nodes of the
// interfaces that name it. call is a proc(ctx:^ui.Context,node:ui.Draw_Node),
// which the library that shows the interfaces calls.
Draw_Info :: struct {
    name:string,
    call:rawptr,
}

// A phase of a loop: its functions, one after another in their order.
Loop_Proc :: #type proc(world,shared,editor:rawptr,app:rawptr)
Step_Proc :: #type proc(world,shared,editor:rawptr,app:rawptr)

// What the generator knows of the project, for code that works on any world.
World_Info :: struct {
    sizes:[Place]int,
    aligns:[Place]int,
    entities:uintptr, // offset of the Entities in World
    revisions:uintptr, // offset in World of a u64 for each storage, as storages lists them: it grows when a function receives the storage to write, when code outside the loop asks for it (world_storage) and when the World is copied over, swapped or cleared. 0: a World made by hand, which has none and whose storages a copy always takes
    tables:[]Table_Info,
    storages:[]Storage_Info,
    messages:[]Message_Info,
    named_types:[]Named_Type_Info, // the types @(names)
    names:[]Name_Info,          // their constants, together by type in the order they are declared
    name_bits:[]Name_Bits_Info, // the types @(name_bits)
    actions:[]Actions_Info,     // the enums @(actions), in the order of their values
    records:[]Record_Info,      // the types @(record)
    draws:[]Draw_Info,          // the procedures @(draw)
    steps:[]Step_Info,
    settles:Settle_Info, // what settle and the procedures of world_data look for in tables and storages
    loops:[Loop][Phase]Loop_Proc,
    order:[Loop][Phase][]i32, // the steps each loop calls, by index, in its order
    tables_by_type,storages_by_type:map[typeid]int, // index in tables and in storages, by_world aside: world_info_index
    schema:^World_Schema, // world_info_index
}

// After w was replaced by a copy of the World whose marks are restored
// (host.app_world_replace), the marks of another copy that equal those of
// restored describe w as it is now: they take its version and its layout,
// and its next copy_changed still skips what did not change. restored itself
// goes last.
copy_marks_follow :: proc(w:World_Ref,restored,marks:[]Copy_Mark) {
    for &info,i in w.info.tables {
        if info.place!=w.place || i>=len(marks) || i>=len(restored) || !restored[i].valid || marks[i]!=restored[i] {continue}
        t:=world_table_at(w,&info)
        marks[i]={t.version,t.layout,true}
    }
    first:=len(w.info.tables)
    for revision,i in world_revisions(w) {
        at:=first+i
        if at>=len(marks) || at>=len(restored) || !restored[at].valid || marks[at]!=restored[at] {continue}
        marks[at]={revision,0,true}
    }
}

// The marks a copy of what changed takes: one per table, then one per storage.
copy_marks_count :: proc "contextless" (info:^World_Info) -> int {return len(info.tables)+len(info.storages)}

// The revisions of the storages of a World, as its World_Info lists them;
// none in a World made by hand.
world_revisions :: proc "contextless" (w:World_Ref) -> []u64 {
    if w.data==nil || w.info.revisions==0 || w.place!=.World {return nil}
    return ([^]u64)(uintptr(w.data)+w.info.revisions)[:len(w.info.storages)]
}

// Whether a storage has to be copied again into the copy a mark is of: its
// revision is not the one the copy was made at.
storage_changed :: #force_inline proc "contextless" (mark:^Copy_Mark,revision:u64) -> bool {
    if mark.valid && mark.version==revision {return false}
    mark.valid=false
    return true
}

// A storage was copied over: the one written is another, and the mark says
// what the source was.
storage_copied :: #force_inline proc "contextless" (mark:^Copy_Mark,dst:^u64,revision:u64) {
    dst^=max(dst^,revision)+1
    mark^={revision,0,true}
}

// Every storage of dst was copied from src: none of dst is what it was, nor
// what a mark of another copy says.
revisions_copied :: proc "contextless" (dst,src:[]u64) {
    for &revision,i in dst {revision=max(revision,src[i])+1}
}

revisions_swapped :: proc "contextless" (a,b:[]u64) {
    for &revision,i in a {
        revision=max(revision,b[i])+1
        b[i]=revision
    }
}

// Every storage was written, as when the World is cleared.
revisions_moved :: proc "contextless" (revisions:[]u64) {
    for &revision in revisions {revision+=1}
}

// With -define:MIRAI_CHECK_WRITES=true, a storage a copy of what changed
// left alone is compared with its copy: one written through a core.Ref, or
// through a pointer kept from an earlier function, differs without its
// revision having moved, and a rollback would bring back the older value.
storage_check :: proc(dst,src:rawptr,info:^runtime.Type_Info,name:string) {
    if !value_equal(dst,src,info) {
        fail("the storage %s changed without a function receiving it to write (^%s) or code outside the loop asking for it (core.world_storage): a copy of what changed left it as it was",name,name)
    }
}

// Runs, outside the loops, the functions of a phase of a loop that the given
// libraries declare, in the order of the loop and with its binding and its
// settle: the part of a world a tool advances by itself, as the physics of a
// preview or the animation of a copy. While they run it stands for the host:
// the Time of the World is time, and its Frame_Time a frame of time.dt in
// that phase, as the editor loop runs it; both are given back after. They
// run one after another on the calling thread. False for a World_Ref that is
// not of a World or without app.
world_run :: proc(w:World_Ref,shared,editor,app:rawptr,loop:Loop,phase:Phase,libraries:[]string,time:Time) -> bool {
    if w.data==nil || w.info==nil || w.place!=.World || app==nil {return false}
    clock,frame:=world_storage_of(w,Time),world_storage_of(w,Frame_Time)
    kept_clock:Time
    kept_frame:Frame_Time
    if clock!=nil {
        kept_clock=clock^
        clock^=time
    }
    if frame!=nil {
        kept_frame=frame^
        frame^={accumulator=kept_frame.accumulator,dt=time.dt,alpha=1,phase=phase}
    }
    settle(w.info,w.data,editor)
    for index in w.info.order[loop][phase] {
        s:=&w.info.steps[index]
        for library in libraries {
            if s.library==library {
                s.call(w.data,shared,editor,app)
                break
            }
        }
    }
    if clock!=nil {clock^=kept_clock}
    if frame!=nil {frame^=kept_frame}
    return true
}

// One value of a storage of the application for each of its Worlds, at the
// index of their World_Id: what Shared holds for @(storage,host,by_world). A
// function that receives the storage gets the value of the World it runs on.
// A World gets its value when the application makes it, and the value goes
// after the release phase of the World.
By_World :: struct($T:typeid) {
    entries:[dynamic]By_World_Entry(T),
    allocator:runtime.Allocator,
}

By_World_Entry :: struct($T:typeid) {
    world:World_Id,
    value:^T,
}

// The value of a World; nil for one the application did not make.
by_world_get :: #force_inline proc "contextless" (b:^By_World($T),id:World_Id) -> ^T {
    if id.generation==0 || int(id.index)>=len(b.entries) {return nil}
    entry:=b.entries[id.index]
    return entry.world==id?entry.value:nil
}

// Gives a World its value, starting at value. False without memory.
by_world_attach :: proc(b:^By_World($T),id:World_Id,value:T,allocator:runtime.Allocator) -> bool {
    if id.generation==0 {return true}
    room:=cast(^T)by_world_room(cast(^By_World(u8))b,id,size_of(T),align_of(T),allocator)
    if room==nil {return false}
    room^=value
    return true
}

// The room of the value of a World in a By_World of values of a size, made
// when it has none; nil without memory.
by_world_room :: proc(b:^By_World(u8),id:World_Id,size,align:int,allocator:runtime.Allocator) -> rawptr {
    if b.allocator.procedure==nil {b.allocator=allocator}
    if int(id.index)>=len(b.entries) {
        b.entries.allocator=b.allocator
        if resize(&b.entries,int(id.index)+1)!=nil {return nil}
    }
    entry:=&b.entries[id.index]
    if entry.value==nil {
        made,error:=mem.alloc(max(size,1),align,b.allocator)
        if error!=nil || made==nil {return nil}
        entry.value=cast(^u8)made
    }
    entry.world=id
    return entry.value
}

// Takes the value of a World out: the caller frees what it holds, then
// by_world_release frees the value. nil without one.
by_world_detach :: proc "contextless" (b:^By_World($T),id:World_Id) -> ^T {
    value:=by_world_get(b,id)
    if value!=nil {b.entries[id.index]={}}
    return value
}

by_world_release :: proc(b:^By_World($T),value:^T) {
    if value!=nil {_=runtime.mem_free(value,b.allocator)}
}

// Which World of its application this one is: a handle that no World made
// later repeats. What a storage of the application holds for a World, it
// keeps by this id and gives back in the release phase. The application sets
// it when it makes the World; copying or swapping Worlds leaves it in place.
// Zero for a World the application did not make.
@(storage,copy=false)
World_Id :: struct {
    index:u32 `mirai:"readonly"`,
    generation:u32 `mirai:"readonly"`,
}

// A world of any project: what generic code receives.
World_Ref :: struct {
    data:rawptr,
    info:^World_Info,
    place:Place,
}

world_ref :: #force_inline proc "contextless" (data:rawptr,info:^World_Info,place:=Place.World) -> World_Ref {return {data,info,place}}

world_entities :: proc "contextless" (w:World_Ref) -> ^Entities {
    return cast(^Entities)(uintptr(w.data)+w.info.entities)
}

world_table :: proc(w:World_Ref,type:typeid) -> (table:^Raw_Table,info:^Table_Info) {
    if w.info.tables_by_type!=nil {
        at,found:=w.info.tables_by_type[type]
        if !found || w.info.tables[at].place!=w.place {return nil,nil}
        return world_table_at(w,&w.info.tables[at]),&w.info.tables[at]
    }
    for &t in w.info.tables {
        if t.type==type && t.place==w.place {return world_table_at(w,&t),&t}
    }
    return nil,nil
}

world_table_named :: proc(w:World_Ref,name:string) -> (table:^Raw_Table,info:^Table_Info) {
    for &t in w.info.tables {
        if t.place==w.place && strings.equal_fold(t.name,name) {return cast(^Raw_Table)(uintptr(w.data)+t.offset),&t}
    }
    return nil,nil
}

world_table_at :: proc "contextless" (w:World_Ref,t:^Table_Info) -> ^Raw_Table {
    return cast(^Raw_Table)(uintptr(w.data)+t.offset)
}

// A storage of a World, to read or to write: its revision moves, so the next
// copy of what changed takes it again.
world_storage :: proc(w:World_Ref,type:typeid) -> rawptr {
    if w.info.storages_by_type!=nil {
        at,found:=w.info.storages_by_type[type]
        if !found || w.info.storages[at].place!=w.place {return nil}
        return world_storage_at(w,at)
    }
    for s,at in w.info.storages {
        if s.type==type && s.place==w.place && !s.by_world {return world_storage_at(w,at)}
    }
    return nil
}

// The storage at an index of info.storages, of the place of w, as
// world_storage gives it.
world_storage_at :: proc "contextless" (w:World_Ref,index:int) -> rawptr {
    if w.info.revisions!=0 && w.place==.World {([^]u64)(uintptr(w.data)+w.info.revisions)[index]+=1}
    return rawptr(uintptr(w.data)+w.info.storages[index].offset)
}

world_storage_of :: proc(w:World_Ref,$T:typeid) -> ^T {return cast(^T)world_storage(w,T)}

world_table_of :: proc(w:World_Ref,$T:typeid) -> ^Table(T) {
    t,_:=world_table(w,T)
    return cast(^Table(T))t
}

// For code outside the loop: the World of a reference.
world_settle :: proc(w:World_Ref) {
    if w.place==.World {settle(w.info,w.data,nil)}
}

// The components an entity has, by table.
entity_tables :: proc(w:World_Ref,e:Entity,allocator:=context.temp_allocator) -> []^Table_Info {
    found:=make([dynamic]^Table_Info,allocator)
    for &t in w.info.tables {
        if t.place!=w.place {continue}
        if raw_find(world_table_at(w,&t),t.info,e)!=nil {append(&found,&t)}
    }
    return found[:]
}

// Destroys an entity and everything under it, from code outside the loop.
world_destroy_tree :: proc(w:World_Ref,e:Entity) {
    destroy_tree(world_entities(w),ref(world_storage_of(w,Hierarchy)),e)
}

// Gives dst what src holds of the run, not of its entities: the storages
// that say keep and the settings. What a World made apart takes from the one
// it replaces (a scene loaded in a job). An Entity they hold named an entity
// of src, and names none in dst. False without memory.
world_run_copy :: proc(dst,src:World_Ref) -> bool {
    for &storage,index in dst.info.storages {
        if storage.place!=.World || !storage.keep && storage.setting==.None {continue}
        to,from:=world_storage_at(dst,index),rawptr(uintptr(src.data)+storage.offset)
        value_free(to,storage.info)
        if !value_copy(to,from,storage.info) {return false}
        value_entities_clear(to,storage.info)
    }
    return true
}

// Makes every Entity of a value NONE, also in its arrays and in what its
// dynamic arrays and slices hold: handles of another World name nothing here.
value_entities_clear :: proc(data:rawptr,info:^runtime.Type_Info) {
    if info.id==Entity {
        (^Entity)(data)^=NONE
        return
    }
    if !type_has_entity(info) {return}
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {value_entities_clear(rawptr(uintptr(data)+v.offsets[i]),v.types[i])}
    case runtime.Type_Info_Array:
        for i in 0..<v.count {value_entities_clear(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)}
    case runtime.Type_Info_Enumerated_Array:
        for i in 0..<v.count {value_entities_clear(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)}
    case runtime.Type_Info_Dynamic_Array:
        a:=cast(^runtime.Raw_Dynamic_Array)data
        for i in 0..<a.len {value_entities_clear(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)}
    case runtime.Type_Info_Slice:
        a:=cast(^runtime.Raw_Slice)data
        for i in 0..<a.len {value_entities_clear(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)}
    }
}

// Whether a value of the type holds an Entity, in place or in what its
// dynamic arrays and slices hold; pointers and maps are not looked into.
@(private)
type_has_entity :: proc(info:^runtime.Type_Info) -> bool {
    if info.id==Entity {return true}
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {if type_has_entity(v.types[i]) {return true}}
    case runtime.Type_Info_Array:            return type_has_entity(v.elem)
    case runtime.Type_Info_Enumerated_Array: return type_has_entity(v.elem)
    case runtime.Type_Info_Dynamic_Array:    return type_has_entity(v.elem)
    case runtime.Type_Info_Slice:            return type_has_entity(v.elem)
    }
    return false
}

// Copies a value with what its dynamic arrays and slices hold. Pointers,
// maps and procedures are copied as they are.
value_copy :: proc(dst,src:rawptr,info:^runtime.Type_Info) -> bool {
    if dst==src {return true}
    if value_flat(info) {
        mem.copy(dst,src,info.size)
        return true
    }
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {
            offset:=v.offsets[i]
            if !value_copy(rawptr(uintptr(dst)+offset),rawptr(uintptr(src)+offset),v.types[i]) {return false}
        }
    case runtime.Type_Info_Array:
        for i in 0..<v.count {
            offset:=uintptr(i*v.elem_size)
            if !value_copy(rawptr(uintptr(dst)+offset),rawptr(uintptr(src)+offset),v.elem) {return false}
        }
    case runtime.Type_Info_Enumerated_Array:
        for i in 0..<v.count {
            offset:=uintptr(i*v.elem_size)
            if !value_copy(rawptr(uintptr(dst)+offset),rawptr(uintptr(src)+offset),v.elem) {return false}
        }
    case runtime.Type_Info_Dynamic_Array:
        return array_copy(cast(^runtime.Raw_Dynamic_Array)dst,cast(^runtime.Raw_Dynamic_Array)src,v.elem)
    case runtime.Type_Info_Slice:
        d:=cast(^runtime.Raw_Slice)dst
        s:=cast(^runtime.Raw_Slice)src
        if s.len>0 && v.elem_size>0 && s.len>max(int)/v.elem_size {return false}
        if d.len!=s.len {
            data:rawptr
            if s.len>0 && v.elem_size>0 {
                allocated,error:=mem.alloc(s.len*v.elem_size,v.elem.align)
                if error!=nil || allocated==nil {return false}
                data=allocated
                mem.zero(data,s.len*v.elem_size)
            }
            mem.copy(data,d.data,min(d.len,s.len)*v.elem_size)
            for i in s.len..<d.len {value_free(rawptr(uintptr(d.data)+uintptr(i*v.elem_size)),v.elem)}
            if d.data!=nil {_=mem.free_with_size(d.data,d.len*v.elem_size)}
            d.data,d.len=data,s.len
        }
        if value_flat(v.elem) {mem.copy(d.data,s.data,s.len*v.elem_size);return true}
        for i in 0..<s.len {
            offset:=uintptr(i*v.elem_size)
            if !value_copy(rawptr(uintptr(d.data)+offset),rawptr(uintptr(s.data)+offset),v.elem) {return false}
        }
    case:
        mem.copy(dst,src,info.size)
    }
    return true
}

// Copies a dynamic array of values of a type, as value_copy copies each.
array_copy :: proc(d,s:^runtime.Raw_Dynamic_Array,elem:^runtime.Type_Info) -> bool {
    if d==s {return true}
    if value_flat(elem) {return array_copy_flat(d,s,elem.size,elem.align)}
    size:=elem.size
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    context.allocator=d.allocator
    if s.len>0 && size>0 && s.len>max(int)/size {return false}
    if d.cap<s.len && !runtime.__dynamic_array_reserve(d,size,elem.align,s.len) {return false}
    for i in s.len..<d.len {value_free(rawptr(uintptr(d.data)+uintptr(i*size)),elem)}
    if s.len>d.len {mem.zero(rawptr(uintptr(d.data)+uintptr(d.len*size)),(s.len-d.len)*size)}
    d.len=s.len
    for i in 0..<s.len {
        offset:=uintptr(i*size)
        if !value_copy(rawptr(uintptr(d.data)+offset),rawptr(uintptr(s.data)+offset),elem) {return false}
    }
    return true
}

// Copies a dynamic array of values of size bytes that hold nothing behind a
// pointer.
array_copy_flat :: proc(d,s:^runtime.Raw_Dynamic_Array,size,align:int) -> bool {
    if d==s {return true}
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    if s.len>0 && size>0 && s.len>max(int)/size {return false}
    if d.cap<s.len {
        context.allocator=d.allocator
        if !runtime.__dynamic_array_reserve(d,size,align,s.len) {return false}
    }
    d.len=s.len
    if size>0 && s.len>0 {mem.copy(d.data,s.data,s.len*size)}
    return true
}

// Whether two values are the same, with what their dynamic arrays and slices
// hold. Pointers, maps and procedures are the same when they are equal.
value_equal :: proc(a,b:rawptr,info:^runtime.Type_Info) -> bool {
    if a==b {return true}
    if value_flat(info) {return mem.compare_ptrs(a,b,info.size)==0}
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {
            if !value_equal(rawptr(uintptr(a)+v.offsets[i]),rawptr(uintptr(b)+v.offsets[i]),v.types[i]) {return false}
        }
    case runtime.Type_Info_Array:
        for i in 0..<v.count {
            if !value_equal(rawptr(uintptr(a)+uintptr(i*v.elem_size)),rawptr(uintptr(b)+uintptr(i*v.elem_size)),v.elem) {return false}
        }
    case runtime.Type_Info_Enumerated_Array:
        for i in 0..<v.count {
            if !value_equal(rawptr(uintptr(a)+uintptr(i*v.elem_size)),rawptr(uintptr(b)+uintptr(i*v.elem_size)),v.elem) {return false}
        }
    case runtime.Type_Info_Dynamic_Array:
        x,y:=cast(^runtime.Raw_Dynamic_Array)a,cast(^runtime.Raw_Dynamic_Array)b
        if x.len!=y.len {return false}
        for i in 0..<x.len {
            if !value_equal(rawptr(uintptr(x.data)+uintptr(i*v.elem_size)),rawptr(uintptr(y.data)+uintptr(i*v.elem_size)),v.elem) {return false}
        }
    case runtime.Type_Info_Slice:
        x,y:=cast(^runtime.Raw_Slice)a,cast(^runtime.Raw_Slice)b
        if x.len!=y.len {return false}
        for i in 0..<x.len {
            if !value_equal(rawptr(uintptr(x.data)+uintptr(i*v.elem_size)),rawptr(uintptr(y.data)+uintptr(i*v.elem_size)),v.elem) {return false}
        }
    case:
        return mem.compare_ptrs(a,b,info.size)==0
    }
    return true
}

// A hash of a value, from seed, with what its dynamic arrays and slices hold.
// Pointers, maps and procedures count by their bits.
value_hash :: proc(data:rawptr,info:^runtime.Type_Info,seed:u64) -> u64 {
    if value_flat(info) {return bytes_hash(mem.byte_slice(data,info.size),seed)}
    hash:=seed
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {hash=value_hash(rawptr(uintptr(data)+v.offsets[i]),v.types[i],hash)}
    case runtime.Type_Info_Array:
        for i in 0..<v.count {hash=value_hash(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem,hash)}
    case runtime.Type_Info_Enumerated_Array:
        for i in 0..<v.count {hash=value_hash(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem,hash)}
    case runtime.Type_Info_Dynamic_Array:
        a:=cast(^runtime.Raw_Dynamic_Array)data
        for i in 0..<a.len {hash=value_hash(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem,hash)}
        hash=bytes_hash(mem.ptr_to_bytes(&a.len),hash)
    case runtime.Type_Info_Slice:
        a:=cast(^runtime.Raw_Slice)data
        for i in 0..<a.len {hash=value_hash(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem,hash)}
        hash=bytes_hash(mem.ptr_to_bytes(&a.len),hash)
    case:
        hash=bytes_hash(mem.byte_slice(data,info.size),hash)
    }
    return hash
}

@(private)
bytes_hash :: proc(bytes:[]u8,seed:u64) -> u64 {return len(bytes)==0?seed:xxhash.XXH3_64_with_seed(bytes,seed)}

// Frees what the dynamic arrays and slices of a value hold.
value_free :: proc(data:rawptr,info:^runtime.Type_Info) {
    if value_flat(info) {return}
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {value_free(rawptr(uintptr(data)+v.offsets[i]),v.types[i])}
    case runtime.Type_Info_Array:
        for i in 0..<v.count {value_free(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)}
    case runtime.Type_Info_Enumerated_Array:
        for i in 0..<v.count {value_free(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)}
    case runtime.Type_Info_Dynamic_Array:
        a:=cast(^runtime.Raw_Dynamic_Array)data
        if a.allocator.procedure!=nil {context.allocator=a.allocator}
        for i in 0..<a.len {value_free(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)}
        if a.data!=nil && a.allocator.procedure!=nil {_=mem.free_with_size(a.data,a.cap*v.elem_size,a.allocator)}
        a^={}
    case runtime.Type_Info_Slice:
        a:=cast(^runtime.Raw_Slice)data
        for i in 0..<a.len {value_free(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)}
        if a.data!=nil {_=mem.free_with_size(a.data,a.len*v.elem_size)}
        a^={}
    }
}

// True when the value has nothing behind a pointer: a copy of its bytes is a copy.
value_flat :: proc(info:^runtime.Type_Info) -> bool {
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {
            if !value_flat(v.types[i]) {return false}
        }
        return true
    case runtime.Type_Info_Array:
        return value_flat(v.elem)
    case runtime.Type_Info_Enumerated_Array:
        return value_flat(v.elem)
    case runtime.Type_Info_Dynamic_Array,runtime.Type_Info_Slice,runtime.Type_Info_Map,runtime.Type_Info_Pointer,runtime.Type_Info_Multi_Pointer,runtime.Type_Info_String,runtime.Type_Info_Procedure,runtime.Type_Info_Any:
        return false
    }
    return true
}

// The tag of a field, as `mirai:"..."` holds it: whether it has an option, and its value.
field_option :: proc(tag:reflect.Struct_Tag,option:string) -> (value:string,ok:bool) {
    text:=reflect.struct_tag_get(tag,"mirai")
    for part in strings.split_iterator(&text,",") {
        name,_,rest:=strings.partition(strings.trim_space(part),"=")
        if name==option {return rest,true}
    }
    return "",false
}
