package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Linked prefabs. The World holds every entity of an instance with its
// effective values and, as two components, which instance placed it
// (scene.Prefab_Instance on the root, scene.Prefab_Member on every entity it
// placed): the history, a shared session and the recovery log carry them as
// any other row. What an instance holds on its own, its overrides, is not
// kept: it is what its members hold apart from the prefab as the instance
// was last brought up to date (its base), compared when it is asked for.
//
// An operation works on one instance: it captures the entities under its
// root as a document, changes that document with the procedures of asset,
// and writes it back onto the same entities (scene.update) inside one
// gesture, whose step holds the rows that changed and the prefab files it
// wrote. A prefab file an operation writes stays in memory, unsaved, as any
// asset an edit changes.
//
// The hierarchy of an instance is the one of the prefab and the entities it
// added under its members. A member that is not the root is not deleted nor
// moved by an edit of the scene: turning it off leaves it out of the instance.


Prefab_Error :: enum u8 {
    None,
    No_Assets,       // the application has no assets folder
    Unknown_Entity,
    No_Id,           // the entity has no Id: it is not an entity of a scene
    Member_Locked,   // a member of an instance that is not its root
    Not_Instance,
    Not_Found,       // no prefab with that path or id
    Not_One_Root,    // a scene with no root or several: no prefab to place or to make a variant of
    Exists,
    Outside_Assets,  // a prefab is written inside the assets folder
    Write_Failed,
    Cycle,           // a prefab that contains the document
    Not_Variant,     // the root of the prefab is not an instance of another prefab
    Unknown_Path,    // an override that does not exist
    Capture_Failed,
    Rejected,        // the World could not take the result
    Out_Of_Memory,
    Importing,       // an import writes assets now
}

prefab_error_text :: proc(error:Prefab_Error) -> string {
    switch error {
    case .None:           return ""
    case .No_Assets:      return "the project has no assets folder"
    case .Importing:      return "an import writes assets now; try again when it ends (asset.import_status)"
    case .Unknown_Entity: return "no such entity in the scene"
    case .No_Id:          return "the entity has no id: it is not an entity of the scene"
    case .Member_Locked:  return "the entity is inside an instance of a prefab: use the root of the instance, or unlink it"
    case .Not_Instance:   return "the entity is not part of an instance of a prefab"
    case .Not_Found:      return "no prefab has that path or id"
    case .Not_One_Root:   return "the scene does not have exactly one root, and a prefab is a scene with one: put its entities under one root, or hang it whole from a Scene_Reference"
    case .Exists:         return "a file with that path exists already"
    case .Outside_Assets: return "a prefab is written inside the assets folder"
    case .Write_Failed:   return "the file could not be written"
    case .Cycle:          return "the prefab contains the document that is open"
    case .Not_Variant:    return "the prefab is not a variant: its root is not an instance of another prefab; apply to the prefab instead"
    case .Unknown_Path:   return "the instance has no such override"
    case .Capture_Failed: return "the scene could not be captured"
    case .Rejected:       return "the world could not take the result"
    case .Out_Of_Memory:  return "out of memory"
    }
    return ""
}

// A prefab as instances were brought up to date with it: by its content hash
// as resolved then, which is the stamp of those instances.
Prefab_Base :: struct {
    id:base.Asset_Id,
    stamp:u64,
    scene:^asset.Scene,
}

// The stamp a prefab gives its instances now, as last asked of its files.
Prefab_Stamp :: struct {
    id:base.Asset_Id,
    stamp:u64,
    found:bool,
    revision:u64, // of the registry then
}

// The overrides of one instance, as last derived.
Prefab_Derived :: struct {
    root:core.Entity,
    key:[4]u64, // what they were derived from: the history, the bases, the edits of others
    overrides:[dynamic]asset.Override,
    known:bool, // the base of the instance was there to compare with
}

@(storage)
Prefabs :: struct {
    bases:[dynamic]Prefab_Base,
    bases_serial:u64, // counts the changes of the bases
    stamps:[dynamic]Prefab_Stamp,
    changes:u64,      // counts the edits that are not steps of the history: those of the others of a session
    derived:Prefab_Derived,
}

@(private)
prefabs_of :: proc(s:^Session) -> ^Prefabs {
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Prefabs)
}

@(private)
prefabs_free :: proc(s:^Session) {
    p:=prefabs_of(s)
    if p==nil {return}
    prefabs_state_free(p)
}

@(private)
prefabs_state_free :: proc(p:^Prefabs) {
    for &b in p.bases {prefab_scene_free(b.scene)}
    delete(p.bases)
    delete(p.stamps)
    delete(p.derived.overrides)
    p^={}
}

@(private)
prefab_scene_free :: proc(sc:^asset.Scene) {
    if sc==nil {return}
    asset.scene_destroy(sc)
    free(sc)
}

// A document was opened: the bases of the one before are not of it, and
// those of the prefabs it places are taken now, while their files are what
// its instances were read with.
@(private)
prefabs_opened :: proc(s:^Session) {
    p:=prefabs_of(s)
    if p==nil {return}
    serial_before:=p.bases_serial
    prefabs_state_free(p)
    p.bases_serial=serial_before+1
    if s.app.assets==nil {return}
    w:=edited_world(s)
    for root in prefab_roots(w,{}) {
        if instance,placed:=scene.prefab_instance(w,root);placed {_=prefab_base_of(s,instance)}
    }
}

// An edit that is no step of the history changed the World: what was derived is of before it.
@(private)
prefabs_changed :: proc(s:^Session) {
    if p:=prefabs_of(s);p!=nil {p.changes+=1}
}

// ---------------------------------------------------------------- the instances of a World

Prefab_Link :: struct {
    instance:core.Entity,  // the root of the instance
    asset:base.Asset_Id,
    source:base.Entity_Id, // the entity of the prefab this one stands for
    root:bool,             // the root of the instance
}

// The instance that placed an entity.
prefab_link_of :: proc(w:core.World_Ref,e:core.Entity) -> (link:Prefab_Link,found:bool) {
    root,instance,member:=scene.prefab_instance_of(w,e)
    if root==core.NONE {return}
    return {root,instance.prefab,base.Entity_Id(member.source),root==e},true
}

// The instances an entity is of, outermost first: the one that placed it in
// the document, then each one the prefab of the one before places that the
// entity stands in, read from that prefab through its source there. It ends
// where a base is not held.
prefab_chain :: proc(s:^Session,w:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> []Prefab_Link {
    chain:=make([dynamic]Prefab_Link,allocator)
    link,linked:=prefab_link_of(w,e)
    if !linked {return chain[:]}
    append(&chain,link)
    members:=prefab_members(w,link.instance)
    // What each member stands for in the prefab the walk is at; 0 once it is of none there.
    sources:=make([]base.Entity_Id,len(members),context.temp_allocator)
    for member,at in members {sources[at]=member.source}
    mine:=link.source
    from:=prefab_link_base(s,w,link)
    for _ in 0..<asset.PREFAB_DEPTH {
        if from==nil {break}
        inner_root,inner_source,inner:=asset.scene_member(from,mine)
        if !inner {break}
        placed,is_instance:=asset.scene_instance(from,inner_root)
        if !is_instance {break}
        root:=core.NONE
        for &source,at in sources {
            if source==0 {continue}
            if source==inner_root {root=members[at].entity}
            of_root,inside,member:=asset.scene_member(from,source)
            source=member && of_root==inner_root?inside:0
        }
        append(&chain,Prefab_Link{instance=root,asset=placed.prefab,source=inner_source,root=root==e})
        mine=inner_source
        from=prefab_base_of(s,{prefab=placed.prefab,stamp=placed.stamp})
    }
    return chain[:]
}

// True when the document has instances of prefabs.
prefab_linked :: proc(s:^Session) -> bool {
    instances:=core.world_table_of(edited_world(s),scene.Prefab_Instance)
    return instances!=nil && len(core.raw(instances).entities)>0
}

// An entity of an instance that is not its root: it keeps the place its
// prefab gives it, and is not the root of a prefab of its own.
prefab_member_locked :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> bool {
    if w.data!=s.edit_world {return false}
    // An entity of a section is edited in its own scene, or in its world while its section is.
    if section_locked(s,w,e) {return true}
    link,linked:=prefab_link_of(w,e)
    return linked && !link.root
}

// The root of the instance an entity is part of: the one that placed it, or
// the one that holds it as an entity added under a member; NONE for neither.
@(private)
prefab_instance_for :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    if link,linked:=prefab_link_of(w,e);linked {return link.instance}
    if link,linked:=prefab_link_of(w,entity_parent(w,e));linked {return link.instance}
    return core.NONE
}

@(private)
Prefab_Member_Entity :: struct {entity:core.Entity,source:base.Entity_Id}

// The members of an instance: they hang where the prefab puts them, so they
// are found under the root, past no entity that is not one of them.
@(private)
prefab_members :: proc(w:core.World_Ref,root:core.Entity,allocator:=context.temp_allocator) -> []Prefab_Member_Entity {
    found:=make([dynamic]Prefab_Member_Entity,allocator)
    storage:=core.world_storage_of(w,core.Hierarchy)
    if storage==nil {return found[:]}
    hierarchy:=core.ref(storage)
    pending:=make([dynamic]core.Entity,context.temp_allocator)
    append(&pending,root)
    for len(pending)>0 {
        e:=pop(&pending)
        member,placed:=scene.prefab_member(w,e)
        if !placed || member.instance!=root {continue}
        append(&found,Prefab_Member_Entity{e,base.Entity_Id(member.source)})
        for child:=core.first_child(hierarchy,e);child!=core.NONE;child=core.next_sibling(hierarchy,child) {append(&pending,child)}
    }
    return found[:]
}

// The member of an instance that stands for an entity of its prefab; NONE without one.
@(private)
prefab_member_entity :: proc(w:core.World_Ref,root:core.Entity,source:base.Entity_Id) -> core.Entity {
    for member in prefab_members(w,root) {
        if member.source==source {return member.entity}
    }
    return core.NONE
}

// After entities were copied: a copy of a member whose root was not copied
// with it is an entity its instance added, not another member.
@(private)
prefab_copies_settle :: proc(w:core.World_Ref,copies:[]core.Entity) {
    table:=core.world_table_of(w,scene.Prefab_Member)
    if table==nil || len(core.raw(table).entities)==0 {return}
    removed:=false
    for copy in copies {
        member,placed:=scene.prefab_member(w,copy)
        if !placed || slice.contains(copies,member.instance) {continue}
        core.remove(table,copy)
        removed=true
    }
    if removed {core.world_settle(w)}
}

// ---------------------------------------------------------------- prefab files

@(private)
prefab_file :: proc(s:^Session,id:base.Asset_Id) -> (file:^asset.Registry_File,path:string,ok:bool) {
    a:=s.app.assets
    if a==nil {return}
    found:bool
    file,found=asset.registry_find(&a.registry,id)
    if !found || !asset.registry_prefab(file) {return}
    return file,asset.registry_file_path(&a.registry,file.path,context.temp_allocator),true
}

// Why an id names no prefab to place: no scene has it, or a scene without
// exactly one root.
@(private)
prefab_missing :: proc(s:^Session,id:base.Asset_Id) -> Prefab_Error {
    if a:=s.app.assets;a!=nil {
        if file,found:=asset.registry_find(&a.registry,id);found && file.state==.Asset && file.kind==asset.KIND_SCENE {return .Not_One_Root}
    }
    return .Not_Found
}

@(private)
assets_rescan :: proc(s:^Session) {
    a:=s.app.assets
    if a!=nil && !a.indexed {_=asset.registry_scan(&a.registry)}
}

// The prefab as its file holds it now, unsaved or on disk, with the instances
// it holds up to date with their prefabs and its components in the layout of
// the program.
@(private)
prefab_scene_load :: proc(s:^Session,id:base.Asset_Id) -> (loaded:^asset.Scene,ok:bool) {
    if s.app.assets==nil {return}
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    taken,error:=asset.resolver_take(&reader.resolver,id)
    if error!=.None || taken==nil {return taken,false}
    if prefab_scene_current(s,taken)!=.None {
        prefab_scene_free(taken)
        return nil,false
    }
    return taken,true
}

@(private)
prefab_component_tables :: proc(sc:^asset.Scene) -> []int {
    found:=make([dynamic]int,context.temp_allocator)
    for table,at in sc.doc.tables {
        if at==0 {continue}
        if _,is_component:=asset.scene_component(sc,table.name);is_component {append(&found,at)}
    }
    return found[:]
}

// Brings the component tables of a prefab read from its file to the layout the program gives each component,
// as reading the file into the world and saving it would: a field the file does not keep takes what loading
// gives it. The values the editor compares with the prefab and what it writes into it then have every field.
@(private)
prefab_scene_current :: proc(s:^Session,sc:^asset.Scene) -> Prefab_Error {
    w:=edited_world(s)
    types:=scene.schema_of(w)
    if types==nil || !serial.schema_hashes_update(&sc.doc.schema,&sc.doc.hashes) {return .Out_Of_Memory}
    for at in prefab_component_tables(sc) {
        index,known:=core.world_table_index_of_hash(w,sc.doc.tables[at].name_hash)
        if !known {continue}
        value_type:=&types.tables[index]
        if value_type.type==serial.TYPE_NONE || sc.doc.hashes[sc.doc.tables[at].columns[1].type]==value_type.hash {continue}
        default,ok:=scene.read_default(&w.info.tables[index])
        if !ok {return .Out_Of_Memory}
        image:[]u8
        if default!=nil {
            canonical,allocation_error:=make([]u8,len(default),context.temp_allocator)
            if allocation_error!=nil {return .Out_Of_Memory}
            serial.value_write(&value_type.layout,canonical,raw_data(default),1)
            image=canonical
        }
        if error:=asset.document_column_retype(&sc.doc,at,1,&types.schema,value_type.type,image);error!=.None {
            return .Out_Of_Memory if error==.Out_Of_Memory else .Rejected
        }
    }
    return .None
}

// The prefab files of the assets, read once for a question and closed by
// prefab_reader_end. It stays where prefab_reader_begin found it.
@(private)
Prefab_Reader :: struct {
    files:asset.Registry_Prefabs,
    resolver:asset.Prefab_Resolver,
}

@(private)
prefab_reader_begin :: proc(s:^Session,reader:^Prefab_Reader) {
    asset.registry_prefabs_init(&reader.files,&s.app.assets.registry)
    asset.resolver_init(&reader.resolver,&s.app.assets.types,asset.registry_prefab_files(&reader.files))
}

@(private)
prefab_reader_end :: proc(reader:^Prefab_Reader) {
    asset.resolver_destroy(&reader.resolver)
    asset.registry_prefabs_destroy(&reader.files)
}

// Whether a prefab holds the one given: it is that one, or places it, itself or through the prefabs it places.
@(private)
prefab_contains :: proc(s:^Session,id,target:base.Asset_Id) -> bool {
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    holds,error:=asset.prefab_holds(reader.resolver.files,&s.app.assets.types,id,target)
    return holds || error!=.None
}

// Whether a prefab places, itself or through the prefabs it places, one whose file is not what it was placed with.
@(private)
prefab_places_stale :: proc(s:^Session,id:base.Asset_Id) -> bool {
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    return asset.resolver_check(&reader.resolver,id).state==.Stale
}

// The stamp a prefab gives its instances now: its content hash as resolved,
// which is that of its file while nothing it places is stale. Asked of the
// files once for each state of the registry; false for a prefab without file.
@(private)
prefab_stamp :: proc(s:^Session,id:base.Asset_Id) -> (stamp:u64,found:bool) {
    p:=prefabs_of(s)
    if p==nil || s.app.assets==nil {return}
    revision:=s.app.assets.registry.revision
    known:^Prefab_Stamp
    for &entry in p.stamps {
        if entry.id!=id {continue}
        if entry.revision==revision {return entry.stamp,entry.found}
        known=&entry
    }
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    checked:=asset.resolver_check(&reader.resolver,id)
    asked:=Prefab_Stamp{id=id,stamp=checked.stamp,found=checked.state==.Current || checked.state==.Stale,revision=revision}
    if known!=nil {known^=asked} else {append(&p.stamps,asked)}
    return asked.stamp,asked.found
}

// Whether an instance is not up to date with its prefab as its files give it now.
prefab_stale :: proc(s:^Session,instance:scene.Prefab_Instance) -> bool {
    stamp,found:=prefab_stamp(s,instance.prefab)
    return found && stamp!=instance.stamp
}

// ---------------------------------------------------------------- bases

@(private)
prefab_base_find :: proc(p:^Prefabs,id:base.Asset_Id,stamp:u64) -> ^Prefab_Base {
    for &b in p.bases {
        if b.id==id && b.stamp==stamp {return &b}
    }
    return nil
}

// The prefab as instances are brought up to date with it now. Takes the scene.
@(private)
prefab_base_set :: proc(s:^Session,id:base.Asset_Id,loaded:^asset.Scene) {
    p:=prefabs_of(s)
    p.bases_serial+=1
    entry:=Prefab_Base{id=id,stamp=loaded.stamp,scene=loaded}
    if b:=prefab_base_find(p,id,loaded.stamp);b!=nil {
        prefab_scene_free(b.scene)
        b^=entry
        return
    }
    append(&p.bases,entry)
}

// The base of an instance: the prefab as its file was when the instance was
// last brought up to date. nil when this editor does not hold it and the
// file is another by now: nothing says then what the instance set itself.
@(private)
prefab_base_of :: proc(s:^Session,instance:scene.Prefab_Instance) -> ^asset.Scene {
    p:=prefabs_of(s)
    if p==nil || s.app.assets==nil {return nil}
    if b:=prefab_base_find(p,instance.prefab,instance.stamp);b!=nil {return b.scene}
    if stamp,found:=prefab_stamp(s,instance.prefab);!found || stamp!=instance.stamp {return nil}
    loaded,ok:=prefab_scene_load(s,instance.prefab)
    if !ok {return nil}
    if loaded.stamp!=instance.stamp {
        prefab_scene_free(loaded)
        return nil
    }
    prefab_base_set(s,instance.prefab,loaded)
    return loaded
}

// Forgets the bases no instance is at: neither one of the World nor one a
// step of the history would bring back.
@(private)
prefab_bases_prune :: proc(s:^Session) {
    p:=prefabs_of(s)
    if p==nil || len(p.bases)<=1 {return}
    w:=edited_world(s)
    Held :: struct {id:base.Asset_Id,stamp:u64}
    held:=make(map[Held]bool,context.temp_allocator)
    index:=-1
    for root in prefab_roots(w,{}) {
        instance,_:=scene.prefab_instance(w,root)
        held[{instance.prefab,instance.stamp}]=true
    }
    for &t,at in w.info.tables {
        if t.place==w.place && t.type==scene.Prefab_Instance {index=at}
    }
    size:=size_of(scene.Prefab_Instance)
    for &step in s.edits.steps {
        for &rows in step.tables {
            if rows.table!=index {continue}
            for k in 0..<len(rows.entities) {
                for side in ([2]^history.Step_Side{&rows.other,&rows.held}) {
                    if !side.present[k] {continue}
                    instance:=(^scene.Prefab_Instance)(&side.values[k*size])^
                    held[{instance.prefab,instance.stamp}]=true
                }
            }
        }
    }
    left:=0
    for &b in p.bases {
        if !held[{b.id,b.stamp}] {
            prefab_scene_free(b.scene)
            continue
        }
        p.bases[left]=b
        left+=1
    }
    resize(&p.bases,left)
}

// ---------------------------------------------------------------- one instance as a document

// The entities under the root of an instance, captured to be changed as a
// document and written back onto them.
@(private)
Prefab_Work :: struct {
    root:core.Entity,
    root_id:base.Entity_Id,
    instance:scene.Prefab_Instance,
    doc:asset.Scene,
    scope:[]base.Entity_Id, // what was captured
}

@(private)
prefab_work_begin :: proc(s:^Session,root:core.Entity) -> (work:Prefab_Work,error:Prefab_Error) {
    a:=s.app.assets
    w:=edited_world(s)
    if a==nil {return {},.No_Assets}
    core.world_settle(w)
    placed:bool
    if work.instance,placed=scene.prefab_instance(w,root);!placed {return {},.Not_Instance}
    work.root,work.root_id=root,api_entity_id(w,root)
    if _,failed:=scene.capture(w,&work.doc,&a.types,{root=root,outside=true,id=s.document.id});failed!=.None {
        return {},failed==.Out_Of_Memory?.Out_Of_Memory:.Capture_Failed
    }
    work.scope=slice.clone(asset.scene_ids(&work.doc),context.temp_allocator)
    return work,.None
}

@(private)
prefab_work_end :: proc(work:^Prefab_Work) {
    if work.root!=core.NONE {asset.scene_destroy(&work.doc)}
    work^={}
}

// What the instance holds apart from a base, as the overrides of its document.
@(private)
prefab_work_derive :: proc(work:^Prefab_Work,from:^asset.Scene) -> Prefab_Error {
    clear(&work.doc.overrides)
    return prefab_place_error(asset.scene_instance_overrides(&work.doc.overrides,&work.doc,work.root_id,from))
}

// Writes the document back onto the entities it was captured from. An entity
// it gained is new to the World: its Id is of no other.
@(private)
prefab_work_put :: proc(s:^Session,work:^Prefab_Work) -> Prefab_Error {
    a:=s.app.assets
    w:=edited_world(s)
    es:=core.world_entities(w)
    known:=make(map[base.Entity_Id]bool,len(work.scope),context.temp_allocator)
    for id in work.scope {known[id]=true}
    for id in asset.scene_ids(&work.doc) {
        if !known[id] && core.entity_of(es,id)!=core.NONE {return .Rejected}
    }
    data,encoded:=asset.scene_bytes(&work.doc,context.temp_allocator)
    if encoded!=.None {return encoded==.Out_Of_Memory?.Out_Of_Memory:.Write_Failed}
    file:asset.Asset
    if asset.asset_open(&file,data)!=.None {return .Rejected}
    defer asset.asset_close(&file)
    _,failed:=scene.update(w,&file,&a.types,{scope=work.scope})
    core.world_settle(w)
    #partial switch failed {
    case .None:          return .None
    case .Out_Of_Memory: return .Out_Of_Memory
    }
    return .Rejected
}

// Brings one instance from a base to a prefab: what it holds apart from the
// base stays over what the prefab gives.
@(private)
prefab_instance_update :: proc(s:^Session,root:core.Entity,from,to:^asset.Scene) -> Prefab_Error {
    work:=prefab_work_begin(s,root) or_return
    defer prefab_work_end(&work)
    prefab_work_derive(&work,from) or_return
    prefab_place_error(asset.scene_instance_update(&work.doc,work.root_id,to)) or_return
    return prefab_work_put(s,&work)
}

// The gesture of an operation: its own, recorded when it ends, or the one
// that is open when it is joined to it.
@(private)
Prefab_Gesture :: struct {
    s:^Session,
    joined:bool,
}

@(private)
prefab_gesture_begin :: proc(s:^Session,label:string,joined:=false) -> (g:Prefab_Gesture,error:Prefab_Error) {
    if s.app.assets==nil {return {},.No_Assets}
    if import_busy(s)!="" {return {},.Importing}
    w:=edited_world(s)
    g={s=s,joined=joined && s.edits.open && !s.edits.preview}
    if !g.joined {
        tools_release(s)
        history.edits_cancel(s.edits,w)
    }
    core.world_settle(w)
    if !g.joined {
        if _,ready:=edit_open(s,label,document=true);!ready {return g,.Out_Of_Memory}
    }
    return g,.None
}

// Ends the gesture of an operation with what it answers: a step when it
// changed something, and the World as it was when it failed.
@(private)
prefab_gesture_end :: proc(g:^Prefab_Gesture,error:Prefab_Error) -> Prefab_Error {
    s:=g.s
    w:=edited_world(s)
    core.world_settle(w)
    if g.joined {return error}
    if error!=.None {
        history.edits_cancel(s.edits,w)
        history.selection_prune(document_selection(s),w)
        return error
    }
    scene.propagate(w,s.app)
    history.selection_prune(document_selection(s),w)
    history.edits_end(s.edits)
    if !history.edits_commit(s.edits,w,document_selection(s)) && s.edits.error!=.No_Change {
        history.edits_cancel(s.edits,w)
        return .Out_Of_Memory
    }
    prefab_bases_prune(s)
    return .None
}

// The roots of the instances of a prefab in the document; of every prefab with a zero id.
@(private)
prefab_roots :: proc(w:core.World_Ref,id:base.Asset_Id,allocator:=context.temp_allocator) -> []core.Entity {
    roots:=make([dynamic]core.Entity,allocator)
    table:=core.world_table_of(w,scene.Prefab_Instance)
    if table==nil {return roots[:]}
    // Every row, those of the entities that are off among them.
    for root in core.raw(table).entities {
        if instance,_:=scene.prefab_instance(w,root);id=={} || instance.prefab==id {append(&roots,root)}
    }
    return roots[:]
}

// Brings the instances of a prefab in the document up to date with its file,
// inside a gesture, and keeps the prefab as it is now as their base. An
// instance whose base this editor does not hold keeps everything it has that
// the prefab does not give.
@(private)
prefab_sync :: proc(s:^Session,id:base.Asset_Id) -> (current:^asset.Scene,updated,failed:int,error:Prefab_Error) {
    p:=prefabs_of(s)
    w:=edited_world(s)
    stamp,located:=prefab_stamp(s,id)
    if !located {return nil,0,0,.Not_Found}
    held:=prefab_base_find(p,id,stamp)
    stale:=make([dynamic]core.Entity,context.temp_allocator)
    for root in prefab_roots(w,id) {
        if instance,_:=scene.prefab_instance(w,root);instance.stamp!=stamp {append(&stale,root)}
    }
    if held!=nil && len(stale)==0 {return held.scene,0,0,.None}
    loaded,ok:=prefab_scene_load(s,id)
    if !ok {return nil,0,0,.Not_Found}
    for root in stale {
        instance,_:=scene.prefab_instance(w,root)
        from:=loaded
        if b:=prefab_base_find(p,id,instance.stamp);b!=nil {from=b.scene}
        if prefab_instance_update(s,root,from,loaded)!=.None {failed+=1} else {updated+=1}
    }
    prefab_base_set(s,id,loaded)
    return loaded,updated,failed,.None
}

// ---------------------------------------------------------------- overrides

// What an instance holds apart from its base, as last derived: again when
// the history, the bases or the edits of others moved since. known false
// when its base is not there to compare with.
prefab_overrides_of :: proc(s:^Session,root:core.Entity) -> (overrides:[]asset.Override,known:bool) {
    p:=prefabs_of(s)
    w:=edited_world(s)
    if p==nil || s.app.assets==nil {return}
    d:=&p.derived
    key:=[4]u64{s.edits.turns,p.bases_serial,p.changes,s.edits.epoch<<1|u64(s.edits.open || s.edits.commit)}
    if d.root==root && d.key==key {return d.overrides[:],d.known}
    d.root,d.key,d.known=root,key,false
    clear(&d.overrides)
    instance,placed:=scene.prefab_instance(w,root)
    if !placed {return}
    from:=prefab_base_of(s,instance)
    // Taking a base counts as a change of them: the key is of after it.
    d.key[1]=p.bases_serial
    if from==nil {return}
    work,error:=prefab_work_begin(s,root)
    if error!=.None {return}
    defer prefab_work_end(&work)
    if prefab_work_derive(&work,from)!=.None {return}
    append(&d.overrides,..work.doc.overrides[:])
    d.known=true
    return d.overrides[:],true
}

// Gives a document captured from the World the overrides of its instances as
// a file keeps them: derived against the base of each, and for an instance
// whose base this editor does not hold, the ones in kept, which the file
// they were read from held.
@(private)
prefab_overrides_put :: proc(s:^Session,captured:^asset.Scene,kept:[]asset.Override) -> Prefab_Error {
    State :: struct {s:^Session,unknown:map[base.Entity_Id]bool}
    state:=State{s=s}
    state.unknown=make(map[base.Entity_Id]bool,context.temp_allocator)
    from :: proc(data:rawptr,root:base.Entity_Id,instance:asset.Prefab_Instance) -> ^asset.Scene {
        state:=(^State)(data)
        found:=prefab_base_of(state.s,{prefab=instance.prefab,stamp=instance.stamp})
        if found==nil {state.unknown[root]=true}
        return found
    }
    clear(&captured.overrides)
    prefab_place_error(asset.scene_overrides_derive(&captured.overrides,captured,{&state,from})) or_return
    if len(state.unknown)==0 {return .None}
    for override in kept {
        row,exists:=asset.scene_entity_find(captured,override.entity)
        if !exists {continue}
        about:=override.kind==.Child?asset.scene_parents(captured)[row]:override.entity
        if state.unknown[asset.scene_entity_instance(captured,about)] {append(&captured.overrides,override)}
    }
    return .None
}

Prefab_Instance_State :: struct {
    asset:base.Asset_Id,
    path:string,
    root:base.Entity_Id,
    members:int,
    missing,stale:bool,
}

// The instances of the document. One is stale when its stamp is not the
// content hash of the file of its prefab, or when that prefab holds a stale
// instance.
prefab_instances :: proc(s:^Session,allocator:=context.temp_allocator) -> []Prefab_Instance_State {
    out:=make([dynamic]Prefab_Instance_State,allocator)
    w:=edited_world(s)
    roots:=prefab_roots(w,{})
    if s.app.assets==nil || len(roots)==0 {return out[:]}
    assets_rescan(s)
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    counts:=make(map[core.Entity]int,context.temp_allocator)
    if members:=core.world_table_of(w,scene.Prefab_Member);members!=nil {
        for e in core.raw(members).entities {
            if member,placed:=scene.prefab_member(w,e);placed {counts[member.instance]+=1}
        }
    }
    for root in roots {
        instance,_:=scene.prefab_instance(w,root)
        state:=Prefab_Instance_State{asset=instance.prefab,root=api_entity_id(w,root),members=counts[root]}
        file,_,found:=prefab_file(s,instance.prefab)
        state.missing=!found
        if found {state.path=file.path}
        state.stale=asset.resolver_instance_stale(&reader.resolver,{prefab=instance.prefab,stamp=instance.stamp})
        append(&out,state)
    }
    return out[:]
}

// The root's entire transform belongs to the placement, never to prefab overrides.
@(private)
prefab_placement :: proc(override:^asset.Override,root:base.Entity_Id) -> bool {
    return override.entity==root && override.component==base.name_hash(asset.INSTANCE_PLACEMENT)
}

// The name of an override of the entity itself: its name, or that the instance added it.
@(private)
prefab_place_name :: proc(kind:asset.Override_Kind) -> string {return kind==.Child?"child":"name"}

@(private)
prefab_override_text :: proc(override:^asset.Override) -> string {return serial.text_field(override.path[:])}

// "Spot_Light.intensity", "Spot_Light", "name", "child": how an override is named.
prefab_override_name :: proc(s:^Session,override:^asset.Override,allocator:=context.temp_allocator) -> string {
    if override.component==0 {return strings.clone(prefab_place_name(override.kind),allocator)}
    path:=prefab_override_text(override)
    name:=""
    for t in s.info.tables {
        if base.name_hash(t.name)==override.component {name=t.name;break}
    }
    if name=="" {name=fmt.tprintf("0x%016x",override.component)}
    if override.kind!=.Field || path=="" {return strings.clone(name,allocator)}
    return strings.concatenate({name,".",path},allocator)
}

// The overrides of an instance that paths name, of one entity or, with entity 0, of all of it; no paths
// selects every override in that scope. In the temporary allocator.
@(private)
prefab_overrides_take :: proc(s:^Session,overrides:[]asset.Override,root,entity:base.Entity_Id,paths:[]string) -> (selected:[]asset.Override,error:Prefab_Error) {
    names:=make(map[u64]string,context.temp_allocator)
    for t in s.info.tables {names[base.name_hash(t.name)]=t.name}
    taken:=make([dynamic]asset.Override,context.temp_allocator)
    for &override in overrides {
        if entity!=0 && override.entity!=entity || prefab_placement(&override,root) {continue}
        if len(paths)==0 {
            append(&taken,override)
            continue
        }
        for path in paths {
            name,_,field:=strings.partition(path,".")
            chosen:=false
            switch {
            case override.component==0:
                chosen=strings.equal_fold(path,prefab_place_name(override.kind))
            case:
                chosen=strings.equal_fold(names[override.component],name) && (field=="" || override.kind==.Field && asset.path_covers(field,prefab_override_text(&override)))
            }
            if chosen {append(&taken,override);break}
        }
    }
    if len(paths)>0 && len(taken)==0 {return nil,.Unknown_Path}
    return taken[:],.None
}

@(private)
prefab_overrides_drop :: proc(sc:^asset.Scene,selected:[]asset.Override) {
    left:=0
    next: for override in sc.overrides {
        for chosen in selected {
            if override==chosen {continue next}
        }
        sc.overrides[left]=override
        left+=1
    }
    resize(&sc.overrides,left)
}

// What a procedure of asset answers, as an operation gives it.
@(private)
prefab_place_error :: proc(error:asset.Error) -> Prefab_Error {
    #partial switch error {
    case .None:          return .None
    case .Out_Of_Memory: return .Out_Of_Memory
    }
    return .Rejected
}

@(private)
prefab_entity_id :: proc(s:^Session,e:core.Entity) -> (id:base.Entity_Id,error:Prefab_Error) {
    w:=edited_world(s)
    if !entity_alive(w,e) {return 0,.Unknown_Entity}
    id=api_entity_id(w,e)
    if id==0 {return 0,.No_Id}
    return id,.None
}

// The file of a new prefab named by a path: inside the assets folder, and not there yet.
@(private)
prefab_new_file :: proc(s:^Session,path:string) -> (file:string,error:Prefab_Error) {
    file=scene_file(s,path)
    if !strings.has_suffix(file,SCENE_EXTENSION) {file=strings.concatenate({file,SCENE_EXTENSION},context.temp_allocator)}
    inside:=strings.has_prefix(strings.to_lower(file,context.temp_allocator),strings.to_lower(s.assets_root,context.temp_allocator))
    if !inside {return "",.Outside_Assets}
    if file_exists(s,file) {return "",.Exists}
    return file,.None
}

// Writes a prefab into its file, unsaved, as part of the open gesture. A file
// no Save could write, because what would be its folder is a file, is refused now.
@(private)
prefab_file_write :: proc(s:^Session,prefab:^asset.Scene,path,label:string) -> Prefab_Error {
    for at:=strings.last_index_byte(path,'/');at>0;at=strings.last_index_byte(path[:at],'/') {
        if !os.exists(path[:at]) {continue}
        if !os.is_dir(path[:at]) {return .Write_Failed}
        break
    }
    data,encoded:=asset.scene_bytes(prefab,context.temp_allocator)
    if encoded!=.None {return encoded==.Out_Of_Memory?.Out_Of_Memory:.Write_Failed}
    return file_write(s,path,data,label)?.None:.Write_Failed
}

// ---------------------------------------------------------------- operations

// Makes the subtree of an entity a prefab of the assets and links the entity as its first instance.
prefab_create :: proc(s:^Session,root:core.Entity,path:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    return prefab_create_entities(s,{root},path)
}

prefab_create_entities :: proc(s:^Session,entities:[]core.Entity,path:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    if len(entities)==0 {return {},.Unknown_Entity}
    w:=edited_world(s)
    chosen:=history.Selection{}
    chosen.entities.allocator=context.temp_allocator
    append(&chosen.entities,..entities)
    roots:=history.selection_roots(&chosen,w)
    if len(roots)==0 {return {},.Unknown_Entity}
    for e in roots {
        _=prefab_entity_id(s,e) or_return
        if prefab_member_locked(s,w,e) {return {},.Member_Locked}
    }
    file:=prefab_new_file(s,path) or_return
    LABEL :: "Create prefab"
    g:=prefab_gesture_begin(s,LABEL) or_return
    grouped:=len(roots)>1
    selected:=slice.clone(s.selection.entities[:],context.temp_allocator)
    id,error=prefab_create_in(s,roots,file,LABEL)
    if error=prefab_gesture_end(&g,error);error!=.None {
        if grouped {history.selection_restore(s.selection,w,selected)}
        return {},error
    }
    return id,.None
}

@(private)
prefab_create_in :: proc(s:^Session,roots:[]core.Entity,file,label:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    a:=s.app.assets
    w:=edited_world(s)
    root:=roots[0]
    if len(roots)>1 {
        root=entities_group(s,w,roots)
        if root==core.NONE {return {},.Rejected}
        core.world_settle(w)
        history.selection_set(s.selection,{root})
        for e in roots {
            if entity_parent(w,e)!=root {return {},.Rejected}
        }
    }
    root_id:=api_entity_id(w,root)
    sub:asset.Scene
    id=asset_id_new(s)
    if _,failed:=scene.capture(w,&sub,&a.types,{root=root,id=id});failed!=.None {return {},.Capture_Failed}
    defer asset.scene_destroy(&sub)
    // The root stands at the origin, upright, with its scale.
    if placed,has:=asset.scene_get(&sub,root_id,"Transform",core.Transform);has {
        placed.position,placed.rotation=0,1
        asset.scene_set(&sub,root_id,"Transform",&placed)
    }
    // The instances inside the subtree are the prefab's from now on, with what they hold on their own.
    prefab_overrides_put(s,&sub,nil) or_return
    prefab_file_write(s,&sub,file,label) or_return
    instances,members:=core.world_table_of(w,scene.Prefab_Instance),core.world_table_of(w,scene.Prefab_Member)
    if instances==nil || members==nil {return {},.Rejected}
    es:=core.world_entities(w)
    for entity in asset.scene_ids(&sub) {
        e:=core.entity_of(es,entity)
        if e==core.NONE {return {},.Rejected}
        if e!=root && core.has(instances,e) {core.remove(instances,e)}
        core.add(members,e,scene.Prefab_Member{root,u64(entity)})
    }
    core.add(instances,root,scene.Prefab_Instance{id,sub.stamp})
    core.world_settle(w)
    if loaded,ok:=prefab_scene_load(s,id);ok {prefab_base_set(s,id,loaded)}
    return id,.None
}

// Writes a variant of a prefab: a new prefab whose root is an instance of it,
// its base, at the origin. What the variant changes of its base are the
// overrides of that instance, so it follows every later change of the base.
prefab_variant_create :: proc(s:^Session,base_id:base.Asset_Id,path:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    assets_rescan(s)
    if _,_,known:=prefab_file(s,base_id);!known {return {},prefab_missing(s,base_id)}
    file:=prefab_new_file(s,path) or_return
    loaded,found:=prefab_scene_load(s,base_id)
    if !found {return {},.Not_Found}
    defer prefab_scene_free(loaded)
    variant:asset.Scene
    id=asset_id_new(s)
    if asset.scene_init(&variant,&a.types,id)!=.None {return {},.Out_Of_Memory}
    defer asset.scene_destroy(&variant)
    root,placed:=asset.scene_instantiate(&variant,loaded,base_id,0)
    if placed!=.None {return {},prefab_place_error(placed)}
    if local,has:=asset.scene_get(&variant,root,asset.INSTANCE_PLACEMENT,core.Transform);has {
        local.position,local.rotation=0,1
        asset.scene_set(&variant,root,asset.INSTANCE_PLACEMENT,&local)
    }
    LABEL :: "Create prefab variant"
    g:=prefab_gesture_begin(s,LABEL) or_return
    error=prefab_gesture_end(&g,prefab_file_write(s,&variant,file,LABEL))
    return id,error
}

// A free path for a variant of a prefab: beside it, named after it.
prefab_variant_path :: proc(s:^Session,base_id:base.Asset_Id) -> string {
    file,_,found:=prefab_file(s,base_id)
    if !found {return "Variant"}
    stem:=file.path[:len(file.path)-len(SCENE_EXTENSION)] if strings.has_suffix(file.path,SCENE_EXTENSION) else file.path
    for n in 1..<10000 {
        path:=n==1?fmt.tprintf("%s_variant",stem):fmt.tprintf("%s_variant_%d",stem,n)
        if !file_exists(s,scene_file(s,strings.concatenate({path,SCENE_EXTENSION},context.temp_allocator))) {return path}
    }
    return fmt.tprintf("%s_variant",stem)
}

// The bases of a prefab, from its own outwards; empty when it is not a variant.
prefab_variant_chain :: proc(s:^Session,id:base.Asset_Id,allocator:=context.temp_allocator) -> []base.Asset_Id {
    chain:=make([dynamic]base.Asset_Id,allocator)
    at:=id
    for _ in 0..<asset.PREFAB_DEPTH {
        loaded,found:=prefab_scene_load(s,at)
        if !found {break}
        next,variant:=asset.prefab_variant_base(loaded)
        prefab_scene_free(loaded)
        if !variant || slice.contains(chain[:],next) || next==id {break}
        append(&chain,next)
        at=next
    }
    return chain[:]
}

// The base of the variant an entity is the root of: of the prefab its
// instance places or, in the document of a variant, of the document itself.
// Zero when it is not a variant or its base is not known.
prefab_variant_of :: proc(s:^Session,w:core.World_Ref,link:Prefab_Link) -> base.Asset_Id {
    if !link.root {return {}}
    if document_is_prefab(s) && entity_parent(w,link.instance)==core.NONE {return link.asset}
    from:=prefab_link_base(s,w,link)
    if from==nil {return {}}
    variant_base,_:=asset.prefab_variant_base(from)
    return variant_base
}

// The base of the instance of a link; nil when this editor does not hold it.
prefab_link_base :: proc(s:^Session,w:core.World_Ref,link:Prefab_Link) -> ^asset.Scene {
    instance,placed:=scene.prefab_instance(w,link.instance)
    return placed?prefab_base_of(s,instance):nil
}

Prefab_Placement :: struct {
    parent:core.Entity,
    position:[3]f32,
    rotation:[4]f32, // x, y, z, w; the identity when all are zero
    scale_multiplier:[3]f32, // 1 when zero
}

// Places an instance of a prefab: new entities with new ids, the root where the placement says.
// joined: inside the gesture that is open, whose step holds it.
prefab_instantiate :: proc(s:^Session,prefab_id:base.Asset_Id,placement:Prefab_Placement,joined:=false) -> (root:base.Entity_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return 0,.No_Assets}
    w:=edited_world(s)
    if _,_,located:=prefab_file(s,prefab_id);!located {return 0,prefab_missing(s,prefab_id)}
    if placement.parent!=core.NONE {_=prefab_entity_id(s,placement.parent) or_return}
    if s.document.id==prefab_id || document_is_prefab(s) && prefab_contains(s,prefab_id,s.document.id) {return 0,.Cycle}
    g:=prefab_gesture_begin(s,"Instantiate prefab",joined) or_return
    placed:core.Entity
    placed,error=prefab_instantiate_in(s,prefab_id,placement)
    if error=prefab_gesture_end(&g,error);error!=.None {return 0,error}
    return api_entity_id(w,placed),.None
}

@(private)
prefab_instantiate_in :: proc(s:^Session,prefab_id:base.Asset_Id,placement:Prefab_Placement) -> (root:core.Entity,error:Prefab_Error) {
    a:=s.app.assets
    w:=edited_world(s)
    instances,members,transforms:=core.world_table_of(w,scene.Prefab_Instance),core.world_table_of(w,scene.Prefab_Member),core.world_table_of(w,core.Transform)
    if instances==nil || members==nil {return core.NONE,.Rejected}
    // The other instances of the prefab follow its file with this one.
    current,_,_:=prefab_sync(s,prefab_id) or_return
    // Encoding gives a scene the stamp of its bytes: the base keeps that of its file.
    stamp:=current.stamp
    data,encoded:=asset.scene_bytes(current,context.temp_allocator)
    current.stamp=stamp
    if encoded!=.None {return core.NONE,encoded==.Out_Of_Memory?.Out_Of_Memory:.Rejected}
    file:asset.Asset
    if asset.asset_open(&file,data)!=.None {return core.NONE,.Rejected}
    defer asset.asset_close(&file)
    view,viewed:=asset.scene_view(&file,&a.types)
    if viewed!=.None {return core.NONE,.Rejected}
    entities:=make([]core.Entity,len(view.ids),context.temp_allocator)
    // The sections the prefab holds load under the instance, as they do under a copy the game spawns.
    report,failed:=scene.instantiate(w,&file,&a.types,{parent=placement.parent,fresh=true,entities=entities,documents=scene.assets_documents(a)})
    core.world_settle(w)
    if failed!=.None {return core.NONE,failed==.Out_Of_Memory?.Out_Of_Memory:.Rejected}
    root=report.root
    for e,row in entities {core.add(members,e,scene.Prefab_Member{root,u64(view.ids[row])})}
    core.add(instances,root,scene.Prefab_Instance{prefab_id,stamp})
    if transforms!=nil {
        if local:=core.get(transforms,root);local!=nil {
            if placement.rotation!={} {local.rotation=quaternion(x=placement.rotation.x,y=placement.rotation.y,z=placement.rotation.z,w=placement.rotation.w)} else {local.rotation=1}
            local.position=placement.position
            if placement.scale_multiplier!={} {local.scale*=placement.scale_multiplier}
        }
    }
    core.world_settle(w)
    return root,.None
}

Prefab_Report :: struct {
    prefabs,instances,missing,failed:int,
}

// Brings the instances of a prefab, or of all of them, up to date with its file: the members follow the
// prefab except in what the instance holds on its own.
prefab_refresh :: proc(s:^Session,prefab_id:base.Asset_Id) -> (report:Prefab_Report,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    if !prefab_linked(s) {return}
    assets_rescan(s)
    w:=edited_world(s)
    g:=prefab_gesture_begin(s,"Refresh prefabs") or_return
    placed:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for root in prefab_roots(w,prefab_id) {
        if instance,_:=scene.prefab_instance(w,root);!slice.contains(placed[:],instance.prefab) {append(&placed,instance.prefab)}
    }
    for id in placed {
        report.prefabs+=1
        _,updated,failed,synced:=prefab_sync(s,id)
        if synced!=.None {
            report.missing+=1
            continue
        }
        report.instances+=updated
        report.failed+=failed
    }
    error=prefab_gesture_end(&g,.None)
    return
}

// Forgets overrides of an entity of an instance and gives back what the prefab has: its values, and its
// places: an entity the instance added goes, one it does not have comes back.
prefab_revert :: proc(s:^Session,entity:core.Entity,paths:[]string,all_members:=false) -> (count:int,error:Prefab_Error) {
    id:=prefab_entity_id(s,entity) or_return
    w:=edited_world(s)
    root:=prefab_instance_for(w,entity)
    if root==core.NONE {return 0,.Not_Instance}
    g:=prefab_gesture_begin(s,"Revert prefab overrides") or_return
    count,error=prefab_revert_in(s,root,all_members?0:id,paths)
    error=prefab_gesture_end(&g,error)
    return error==.None?count:0,error
}

@(private)
prefab_revert_in :: proc(s:^Session,root:core.Entity,entity:base.Entity_Id,paths:[]string) -> (count:int,error:Prefab_Error) {
    instance,_:=scene.prefab_instance(edited_world(s),root)
    current,_,_:=prefab_sync(s,instance.prefab) or_return
    work:=prefab_work_begin(s,root) or_return
    defer prefab_work_end(&work)
    prefab_work_derive(&work,current) or_return
    selected:=prefab_overrides_take(s,work.doc.overrides[:],work.root_id,entity,paths) or_return
    for override in selected {
        if override.kind==.Child {asset.scene_child_revert(&work.doc,work.root_id,override.entity)}
    }
    prefab_overrides_drop(&work.doc,selected)
    prefab_place_error(asset.scene_instance_update(&work.doc,work.root_id,current)) or_return
    prefab_work_put(s,&work) or_return
    return len(selected),.None
}

// Makes the members of the instance ordinary entities. The instances its prefab places stay, as instances
// of the document; with recursive they are unlinked too.
prefab_unlink :: proc(s:^Session,entity:core.Entity,recursive:bool) -> (error:Prefab_Error) {
    _=prefab_entity_id(s,entity) or_return
    link,linked:=prefab_link_of(edited_world(s),entity)
    if !linked {return .Not_Instance}
    g:=prefab_gesture_begin(s,"Unlink prefab") or_return
    return prefab_gesture_end(&g,prefab_unlink_in(s,link.instance,recursive))
}

@(private)
prefab_unlink_in :: proc(s:^Session,root:core.Entity,recursive:bool) -> Prefab_Error {
    work:=prefab_work_begin(s,root) or_return
    defer prefab_work_end(&work)
    from:=prefab_base_of(s,work.instance)
    if from!=nil {prefab_work_derive(&work,from) or_return}
    prefab_place_error(asset.scene_instance_unlink(&work.doc,work.root_id,from,recursive)) or_return
    return prefab_work_put(s,&work)
}

// Where Apply writes the overrides of an instance.
Prefab_Apply_Target :: enum u8 {
    Prefab, // the prefab the instance places
    Base,   // through that prefab, a variant, into its base
}

// Writes the overrides of an entity into its prefab, ends them, and brings every instance up to date, the
// prefabs that place this one included. Base: the variant takes them first and its base then takes, of what
// the variant holds as the overrides of its root, what they changed. The files stay unsaved.
prefab_apply :: proc(s:^Session,entity:core.Entity,paths:[]string,all_members:=false,target:=Prefab_Apply_Target.Prefab) -> (count:int,error:Prefab_Error) {
    id:=prefab_entity_id(s,entity) or_return
    w:=edited_world(s)
    root:=prefab_instance_for(w,entity)
    if root==core.NONE {return 0,.Not_Instance}
    label:=target==.Base?"Apply prefab overrides to base":"Apply prefab overrides"
    g:=prefab_gesture_begin(s,label) or_return
    count,error=prefab_apply_in(s,root,all_members?0:id,paths,target,label)
    error=prefab_gesture_end(&g,error)
    return error==.None?count:0,error
}

@(private)
prefab_apply_in :: proc(s:^Session,root:core.Entity,entity:base.Entity_Id,paths:[]string,target:Prefab_Apply_Target,label:string) -> (count:int,error:Prefab_Error) {
    instance,_:=scene.prefab_instance(edited_world(s),root)
    prefab_id:=instance.prefab
    _,path,located:=prefab_file(s,prefab_id)
    if !located {return 0,.Not_Found}
    changed:=make([dynamic]base.Asset_Id,context.temp_allocator)
    {
        current,_,_:=prefab_sync(s,prefab_id) or_return
        work:=prefab_work_begin(s,root) or_return
        defer prefab_work_end(&work)
        prefab_work_derive(&work,current) or_return
        selected:=prefab_overrides_take(s,work.doc.overrides[:],work.root_id,entity,paths) or_return
        count=len(selected)
        prefab,loaded:=prefab_scene_load(s,prefab_id)
        if !loaded {return 0,.Not_Found}
        defer prefab_scene_free(prefab)
        base_id,variant:=asset.prefab_variant_base(prefab)
        if target==.Base && !variant {return 0,.Not_Variant}
        prefab_place_error(asset.scene_overrides_apply(&work.doc,work.root_id,selected,prefab)) or_return
        // The entities applied are members from here on.
        prefab_work_put(s,&work) or_return
        prefab_overrides_put(s,prefab,slice.clone(prefab.overrides[:],context.temp_allocator)) or_return
        if target==.Base {
            variant_root,_:=asset.prefab_root(prefab)
            chosen:=prefab_variant_overrides(&work.doc,work.root_id,selected,prefab,variant_root)
            if len(chosen)>0 {
                _,base_path,base_located:=prefab_file(s,base_id)
                base_scene,base_loaded:=prefab_scene_load(s,base_id)
                if !base_located || !base_loaded {return 0,.Not_Found}
                defer prefab_scene_free(base_scene)
                prefab_place_error(asset.scene_overrides_apply(prefab,variant_root,chosen,base_scene)) or_return
                prefab_overrides_drop(prefab,chosen)
                prefab_overrides_put(s,base_scene,slice.clone(base_scene.overrides[:],context.temp_allocator)) or_return
                prefab_file_write(s,base_scene,base_path,label) or_return
                prefab_place_error(asset.scene_instance_update(prefab,variant_root,base_scene)) or_return
                append(&changed,base_id)
            }
        }
        prefab_file_write(s,prefab,path,label) or_return
        append(&changed,prefab_id)
    }
    // The prefabs that place what changed follow it, and the instances of the document all of them.
    for at:=0;at<len(changed);at+=1 {prefab_propagate(s,changed[at],&changed,label)}
    for id in changed {
        if len(prefab_roots(edited_world(s),id))>0 {prefab_sync(s,id) or_return}
    }
    return count,.None
}

// The overrides of the instance at the root of a variant that stand for overrides of an instance of the
// variant just written into it: of the same members and parts, and the entities it added. What the instance
// changed of an entity the variant added is the variant's alone.
@(private)
prefab_variant_overrides :: proc(doc:^asset.Scene,root:base.Entity_Id,selected:[]asset.Override,variant:^asset.Scene,variant_root:base.Entity_Id) -> []asset.Override {
    sources:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    members,_:=asset.scene_instance_members(doc,root)
    for member in members {sources[member.entity]=member.source}
    chosen:=make([dynamic]asset.Override,context.temp_allocator)
    for &override in variant.overrides {
        row,exists:=asset.scene_entity_find(variant,override.entity)
        if !exists {continue}
        about:=override.kind==.Child?asset.scene_parents(variant)[row]:override.entity
        if asset.scene_entity_instance(variant,about)!=variant_root {continue}
        for &wanted in selected {
            entity:=sources[wanted.entity]
            if entity==0 || override.entity!=entity || override.kind!=wanted.kind || override.component!=wanted.component {continue}
            if override.kind==.Field && override.component!=0 && !asset.path_covers(prefab_override_text(&wanted),prefab_override_text(&override)) {continue}
            append(&chosen,override)
            break
        }
    }
    return chosen[:]
}

// The prefabs that place a prefab that changed, found by what the files of the assets depend on, are
// brought up to date with it and written, unsaved; done takes them, for those that place them in turn.
@(private)
prefab_propagate :: proc(s:^Session,changed:base.Asset_Id,done:^[dynamic]base.Asset_Id,label:string) {
    registry:=&s.app.assets.registry
    placers:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for index in asset.registry_dependents(registry,changed) {
        file:=&registry.files[index]
        if asset.registry_prefab(file) && !slice.contains(done[:],file.id) {append(&placers,file.id)}
    }
    for id in placers {
        _,path,located:=prefab_file(s,id)
        if !located || slice.contains(done[:],id) || !prefab_places_stale(s,id) {continue}
        outer,loaded:=prefab_scene_load(s,id)
        if !loaded {continue}
        written:=prefab_file_write(s,outer,path,label)
        prefab_scene_free(outer)
        if written==.None {append(done,id)}
    }
}

// ---------------------------------------------------------------- placing

// A prefab of the assets placed in the scene as an instance linked to it. The root of the instance is returned.
prefab_place_linked :: proc(s:^Session,prefab_id:base.Asset_Id,point:[3]f32) -> core.Entity {
    root,error:=prefab_instantiate(s,prefab_id,{position=point})
    if error!=.None {
        notify(s,fmt.tprintf("The prefab could not be placed: %s",prefab_error_text(error)))
        return core.NONE
    }
    return api_entity(edited_world(s),root)
}

// ---------------------------------------------------------------- actions of the editor

// The entity the prefab actions work on: the active one, when it is alone in what is selected or last.
@(private)
prefab_target :: proc(s:^Session) -> core.Entity {
    return history.selection_active(s.selection)
}

// Whether an entry of the prefabs (prefab_create, prefab_apply,
// prefab_apply_base, prefab_revert, prefab_unlink) cannot run on what is selected now.
@(private)
prefab_entry_disabled :: proc(s:^Session,entry:string) -> bool {
    if s.mode!=.Edit || s.app==nil || s.app.assets==nil {return true}
    w:=edited_world(s)
    if entry=="prefab_create" {
        roots:=history.selection_roots(s.selection,w)
        if len(roots)==0 {return true}
        for e in roots {
            if prefab_member_locked(s,w,e) || api_entity_id(w,e)==0 {return true}
        }
        return false
    }
    if len(s.selection.entities)!=1 {return true}
    e:=prefab_target(s)
    if e==core.NONE {return true}
    id:=api_entity_id(w,e)
    if id==0 {return true}
    link,linked:=prefab_link_of(w,e)
    switch entry {
    case "prefab_apply","prefab_revert","prefab_apply_base":
        // A member with overrides, or an entity an instance added; to a base, the root of an instance of a variant.
        if entry=="prefab_apply_base" && prefab_variant_of(s,w,link)=={} {return true}
        root:=prefab_instance_for(w,e)
        if root==core.NONE {return true}
        overrides,_:=prefab_overrides_of(s,root)
        for &override in overrides {
            if linked && link.root || override.entity==id {return false}
        }
        return true
    case "prefab_unlink": return !linked
    }
    return true
}

// Where a new prefab goes: beside the scene it comes from, at the root for one outside the assets.
@(private)
prefab_folder :: proc(s:^Session) -> string {
    path:=scene_path(s,document_file(s.document))
    if filepath.is_abs(path) {return ""}
    return content_folder_of(path)
}

// A file of this name for a new prefab, in a folder of the assets, that no file has.
@(private)
prefab_name_free :: proc(s:^Session,folder,name:string) -> string {
    prefix:=folder==""?"":fmt.tprintf("%s/",folder)
    stem:=strings.trim_space(name)
    if stem=="" {stem="Prefab"}
    cleaned:=make([]u8,len(stem),context.temp_allocator)
    for c,i in transmute([]u8)stem {
        cleaned[i]=(c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='_' || c=='-')?c:'_'
    }
    for n in 1..<10000 {
        path:=n==1?fmt.tprintf("%s%s",prefix,string(cleaned)):fmt.tprintf("%s%s_%d",prefix,string(cleaned),n)
        if !file_exists(s,scene_file(s,strings.concatenate({path,SCENE_EXTENSION},context.temp_allocator))) {return path}
    }
    return fmt.tprintf("%sPrefab",prefix)
}

