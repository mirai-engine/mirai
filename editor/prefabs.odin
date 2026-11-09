package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Linked prefabs. The World holds every entity of an instance with its
// effective values; what it cannot hold are the records of the instances
// (Instance, Member, Override of asset.Scene), which the Document keeps in
// the scene it was read as. An operation captures the World once together
// with those records, changes the capture with the procedures of asset, and
// replaces the World by what the capture says as one step of the history.
//
// Overrides are marked by comparing the members of an instance with the
// prefab as the instance was last brought up to date (its base): after the
// steps of the history, from the rows each one changed, before an operation
// that brings values from the prefab, and before the scene is written.
//
// The hierarchy of an instance is the one of the prefab and the entities it
// added under its members. A member that is not the root is not deleted nor
// moved by an edit of the scene: turning it off leaves it out of the instance.

PREFAB_EXTENSION :: ".prefab"
PREFAB_CYCLE_DEPTH :: 16

Prefab_Error :: enum u8 {
    None,
    No_Assets,       // the application has no assets folder
    Unknown_Entity,
    No_Id,           // the entity has no Id: it is not an entity of a scene
    Member_Locked,   // a member of an instance that is not its root
    Not_Instance,
    Not_Found,       // no prefab with that path or id
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

// A prefab as its instances were last brought up to date with it.
Prefab_Base :: struct {
    id:base.Asset_Id,
    scene:^asset.Scene,
    size,time:i64, // of its file then
    serial:u64,    // Prefabs.bases_serial when it was set
}

// The records of the instances of a document at a point of the history.
Prefab_Records :: struct {
    instances:[dynamic]asset.Instance,
    members:[dynamic]asset.Member,
    overrides:[dynamic]asset.Override,
    last_instance:u32,
}

// What a step of the history changed of the records, kept while the history
// holds the step: undo takes out what came and puts back what went, redo the
// other way.
Prefab_Version :: struct {
    before_state,after_state:u64, // of the history
    gone:Prefab_Records,          // what the step took out, with the last instance before it
    came:Prefab_Records,          // what it put in, with the last instance after it
    files:[dynamic]Prefab_File,   // written by the step: undo gives them back
}

@(storage)
Prefabs :: struct {
    bases:[dynamic]Prefab_Base,
    bases_serial:u64,
    versions:[dynamic]Prefab_Version,
    epoch:u64,          // of the history of the document these follow
    last_state:u64,     // the state of the history they were made current for
    pending:Prefab_Records, // records before a change that waits for its step
    pending_state:u64,
    has_pending:bool,
    // The last observation of overrides: the turn of the history, its first
    // state and the bases it compared with. Not observed: the next is whole.
    observed:bool,
    observed_turns,observed_initial,observed_bases:u64,
    observe_error:Prefab_Error, // of that observation: the overrides are the ones before it
    // What the edits of other editors of a session changed since: they are
    // not steps of this history.
    remote:map[base.Entity_Id]bool,
    remote_places:bool, // an Id or a parent
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
    for &v in p.versions {prefab_version_free(&v)}
    delete(p.versions)
    prefab_records_free(&p.pending)
    delete(p.remote)
    p^={}
}

@(private)
prefab_scene_free :: proc(sc:^asset.Scene) {
    if sc==nil {return}
    asset.scene_destroy(sc)
    free(sc)
}

@(private)
prefab_records_free :: proc(r:^Prefab_Records) {
    delete(r.instances);delete(r.members);delete(r.overrides)
    r^={}
}

// ---------------------------------------------------------------- records of the document

// The scene the document was read as, made when it has none: it holds the records.
@(private)
prefab_previous :: proc(s:^Session) -> ^asset.Scene {
    d:=s.document
    if d.previous!=nil {return d.previous}
    a:=s.app.assets
    if a==nil {return nil}
    previous:=new(asset.Scene)
    id:=d.id
    if id=={} {id=asset_id_new(s)}
    if asset.scene_init(previous,&a.types,asset.KIND_SCENE,id)!=.None {
        free(previous)
        return nil
    }
    d.previous=previous
    return previous
}

@(private)
prefab_records_take :: proc(from:^asset.Scene) -> (r:Prefab_Records) {
    if from==nil {return}
    append(&r.instances,..from.instances[:])
    append(&r.members,..from.members[:])
    append(&r.overrides,..from.overrides[:])
    r.last_instance=from.info.last_instance
    return
}

@(private)
prefab_records_put :: proc(into:^asset.Scene,r:^Prefab_Records) {
    clear(&into.instances);clear(&into.members);clear(&into.overrides)
    append(&into.instances,..r.instances[:])
    append(&into.members,..r.members[:])
    append(&into.overrides,..r.overrides[:])
    into.info.last_instance=r.last_instance
}

// True when the document has instances of prefabs.
prefab_linked :: proc(s:^Session) -> bool {
    return s.document.previous!=nil && len(s.document.previous.instances)>0
}

Prefab_Link :: struct {
    instance:u32,
    asset:base.Asset_Id,
    source:base.Entity_Id, // the entity of the prefab this one stands for
    root:bool,             // the root of the instance
}

// The instance placed in the document that an entity belongs to.
prefab_link_of :: proc(s:^Session,id:base.Entity_Id) -> (link:Prefab_Link,found:bool) {
    if s.document==nil {return}
    previous:=s.document.previous
    if previous==nil || id==0 || len(previous.instances)==0 {return}
    for member in previous.members {
        if member.entity!=id {continue}
        at:=asset.scene_instance_find(previous,member.instance)
        if at<0 || previous.instances[at].outer!=0 {continue}
        return {member.instance,previous.instances[at].prefab,member.source,previous.instances[at].root==id},true
    }
    return
}

// The link of every entity an instance placed in the document, for many
// lookups while the document does not change. Empty when prefab_member_locked
// would not lock anything.
prefab_links :: proc(s:^Session,w:core.World_Ref,allocator:=context.temp_allocator) -> map[base.Entity_Id]Prefab_Link {
    links:=make(map[base.Entity_Id]Prefab_Link,allocator)
    previous:=s.document.previous
    if w.data!=s.edit_world || previous==nil || len(previous.instances)==0 || !prefab_linked(s) {return links}
    placed:=make(map[u32]int,len(previous.instances),context.temp_allocator)
    for instance,at in previous.instances {if instance.outer==0 && !(instance.id in placed) {placed[instance.id]=at}}
    for member in previous.members {
        at,found:=placed[member.instance]
        if !found || member.entity==0 || member.entity in links {continue}
        links[member.entity]={member.instance,previous.instances[at].prefab,member.source,previous.instances[at].root==member.entity}
    }
    return links
}

// prefab_member_locked over the links prefab_links gave.
prefab_member_locked_in :: proc(s:^Session,links:map[base.Entity_Id]Prefab_Link,w:core.World_Ref,e:core.Entity) -> bool {
    if section_locked(s,w,e) {return true}
    link,linked:=links[api_entity_id(w,e)]
    return linked && !link.root
}

// An entity of an instance that is not its root: it keeps the place its
// prefab gives it, and is not the root of a prefab of its own.
prefab_member_locked :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> bool {
    if w.data!=s.edit_world {return false}
    // An entity of a section is edited in its own scene, or in its world while its section is.
    if section_locked(s,edited_world(s),e) {return true}
    if !prefab_linked(s) {return false}
    link,linked:=prefab_link_of(s,api_entity_id(edited_world(s),e))
    return linked && !link.root
}

// The instance placed in a document an entity is part of: the one of the
// member, or the one that added it under a member; 0 for none.
@(private)
prefab_instance_of :: proc(sc:^asset.Scene,id:base.Entity_Id) -> u32 {
    if instance:=asset.scene_entity_instance(sc,id);instance!=0 {return instance}
    for override in sc.overrides {
        if override.kind==.Child && override.entity==id {return override.instance}
    }
    return 0
}

// ---------------------------------------------------------------- prefab files

@(private)
prefab_file :: proc(s:^Session,id:base.Asset_Id) -> (file:^asset.Registry_File,path:string,ok:bool) {
    a:=s.app.assets
    if a==nil {return}
    found:bool
    file,found=asset.registry_find(&a.registry,id)
    if !found || file.kind!=asset.KIND_PREFAB {return}
    return file,asset.registry_file_path(&a.registry,file.path,context.temp_allocator),true
}

// The id of a prefab named by an asset id or by a path: a file, or inside the assets folder.
prefab_locate :: proc(s:^Session,path:string) -> (found:base.Asset_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    assets_rescan(s)
    if id,is_id:=base.asset_id_parse(path);is_id {
        _,_,ok:=prefab_file(s,id)
        return id,ok?.None:.Not_Found
    }
    if path=="" {return {},.Not_Found}
    names:=[2]string{path,path}
    if !strings.has_suffix(path,PREFAB_EXTENSION) {names[1]=strings.concatenate({path,PREFAB_EXTENSION},context.temp_allocator)}
    for name in names {
        for candidate in ([2]string{scene_path(s,scene_file(s,name)),name}) {
            if file,ok:=asset.registry_find_path(&a.registry,candidate);ok && file.kind==asset.KIND_PREFAB {return file.id,.None}
        }
    }
    return {},.Not_Found
}

@(private)
assets_rescan :: proc(s:^Session) {
    a:=s.app.assets
    if a!=nil && !a.indexed {_=asset.registry_scan(&a.registry)}
}

// The prefab as its file holds it now, with the instances it holds up to
// date with their prefabs and its components in the layout of the program.
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

@(private)
prefab_base_find :: proc(p:^Prefabs,id:base.Asset_Id) -> ^Prefab_Base {
    for &b in p.bases {
        if b.id==id {return &b}
    }
    return nil
}

// The prefab as the instances were last updated from it. Takes the scene.
@(private)
prefab_base_set :: proc(s:^Session,id:base.Asset_Id,loaded:^asset.Scene) {
    p:=prefabs_of(s)
    p.bases_serial+=1
    file,_,_:=prefab_file(s,id)
    stamp:[2]i64
    if file!=nil {stamp={file.size,file.time}}
    if b:=prefab_base_find(p,id);b!=nil {
        prefab_scene_free(b.scene)
        b^={id=id,scene=loaded,size=stamp[0],time=stamp[1],serial=p.bases_serial}
        return
    }
    append(&p.bases,Prefab_Base{id=id,scene=loaded,size=stamp[0],time=stamp[1],serial=p.bases_serial})
}

// The file of a prefab is not what the instances were updated from.
prefab_stale :: proc(s:^Session,id:base.Asset_Id) -> bool {
    b:=prefab_base_find(prefabs_of(s),id)
    file,_,ok:=prefab_file(s,id)
    if !ok || b==nil {return false}
    return b.size!=file.size || b.time!=file.time
}

// Whether the prefab holds, directly or through the prefabs it places, the one given.
@(private)
prefab_contains :: proc(s:^Session,prefab:^asset.Scene,target:base.Asset_Id,depth:=0) -> bool {
    if depth>PREFAB_CYCLE_DEPTH {return true}
    for instance in prefab.instances {
        if instance.prefab==target {return true}
        if instance.outer!=0 {continue}
        inner,loaded:=prefab_scene_load(s,instance.prefab)
        if !loaded {continue}
        found:=prefab_contains(s,inner,target,depth+1)
        prefab_scene_free(inner)
        if found {return true}
    }
    return false
}

// ---------------------------------------------------------------- the capture an operation works on

@(private)
Prefab_Edit :: struct {
    s:^Session,
    cap:^asset.Scene,
    before:[]u8,
    records:Prefab_Records, // of the document when the operation began
    files:[dynamic]Prefab_File,
}

@(private)
prefab_bytes :: proc(sc:^asset.Scene) -> []u8 {
    w:serial.Writer
    serial.writer_init(&w,0,context.temp_allocator)
    if asset.scene_write(sc,&w)!=.None {return nil}
    return serial.writer_bytes(&w)
}

// Marks the overrides of the edits made so far and captures the World with the records of the document.
@(private)
prefab_begin :: proc(s:^Session) -> (e:Prefab_Edit,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    if import_busy(s)!="" {return {},.Importing}
    if prefab_previous(s)==nil {return {},.Out_Of_Memory}
    // A history replaced since the prefabs last followed it (the scene of a
    // host, without a frame between): they take it before the step whose
    // version they keep, or the next frame would drop that version.
    p:=prefabs_of(s)
    if p.epoch!=s.edits.epoch {prefabs_follow(s,p)}
    prefabs_sync(s,p)
    tools_release(s)
    w:=edited_world(s)
    edits_cancel(s.edits,w)
    core.world_settle(w)
    prefab_observe(s) or_return
    e.s=s
    e.cap=new(asset.Scene)
    d:=s.document
    if _,capture_error:=scene.capture(w,e.cap,&a.types,{previous=d.previous,id=d.id});capture_error!=.None {
        free(e.cap)
        return {},.Capture_Failed
    }
    e.records=prefab_records_take(d.previous)
    e.before=prefab_bytes(e.cap)
    return e,.None
}

@(private)
prefab_files_free :: proc(files:^[dynamic]Prefab_File) {
    for file in files {
        delete(file.path);delete(file.before);delete(file.after)
    }
    delete(files^)
    files^={}
}

@(private)
prefab_abort :: proc(e:^Prefab_Edit) {
    prefab_files_free(&e.files)
    prefab_scene_free(e.cap)
    prefab_records_free(&e.records)
    e.cap=nil
}

// Replaces the World by the capture, selecting the entities that were selected, in a step when it changed.
// It is the same scene edited, not a cut: the image keeps its history.
@(private)
prefab_world_replace :: proc(s:^Session,cap:^asset.Scene) -> Prefab_Error {
    a:=s.app.assets
    w:=edited_world(s)
    data:=prefab_bytes(cap)
    if data==nil {return .Write_Failed}
    source:asset.Asset
    if asset.asset_open(&source,data)!=.None {return .Rejected}
    defer asset.asset_close(&source)
    view,view_error:=asset.scene_view(&source,&a.types)
    if view_error!=.None || !asset.scene_view_check(view,context.temp_allocator) {return .Rejected}
    selection:=document_selection(s)
    selected:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for e in selection.entities {
        if id:=api_entity_id(w,e);id!=0 {append(&selected,id)}
    }
    w.info.clear(w.data)
    _,error:=scene.instantiate(w,&source,&a.types)
    core.world_settle(w)
    if error!=.None {return .Rejected}
    scene.propagate(w,s.app)
    picked:=make([dynamic]core.Entity,context.temp_allocator)
    for id in selected {
        if e:=api_entity(w,id);e!=core.NONE {append(&picked,e)}
    }
    selection_set(selection,picked[:])
    return .None
}

// Ends an operation: the capture becomes the scene the document was read as and, when it differs from
// the World, the World follows as one step of undo. Takes the edit.
@(private)
prefab_finish :: proc(e:^Prefab_Edit,label:string) -> Prefab_Error {
    s:=e.s
    d:=s.document
    p:=prefabs_of(s)
    cap:=e.cap
    defer prefab_records_free(&e.records)
    defer prefab_files_free(&e.files)
    after:=prefab_bytes(cap)
    changed:=after==nil || !slice.equal(after,e.before)
    error:=Prefab_Error.None
    // A step that only writes prefab files still has its place in the history: its undo takes them back.
    if changed || len(e.files)>0 {
        before_state:=edits_scene_state(s.edits)
        _,edit_ready:=edit_open(s,label,document=true)
        if !edit_ready {prefab_scene_free(cap);return .Out_Of_Memory}
        if changed {error=prefab_world_replace(s,cap)}
        edits_end(s.edits)
        if error!=.None {
            edits_cancel(s.edits,edited_world(s))
            prefab_scene_free(cap)
            return error
        }
        if !edits_commit(s.edits,edited_world(s),document_selection(s),true) {
            edits_cancel(s.edits,edited_world(s))
            prefab_scene_free(cap)
            return .Out_Of_Memory
        }
        after_state:=edits_scene_state(s.edits)
        document_previous_free(d)
        d.previous=cap
        if after_state!=before_state {
            version:=prefab_version_make(&e.records,cap,before_state,after_state)
            version.files=e.files
            e.files={}
            append(&p.versions,version)
            collab_prefab_step(s,&p.versions[len(p.versions)-1],true)
            prefab_versions_prune(p,s.edits)
            p.last_state=after_state
        }
    } else {
        document_previous_free(d)
        d.previous=cap
    }
    e.cap=nil
    return .None
}

// ---------------------------------------------------------------- following the document

// Makes the records, and the files, of the point of the history current, compares overrides after the
// edits that may have changed them, and brings a document just opened up to date with its prefabs.
@(step="input")
prefabs_follow :: proc(s:^Session,p:^Prefabs) {
    if s.app.assets==nil {return}
    edits:=s.edits
    if p.epoch!=edits.epoch {
        p.epoch=edits.epoch
        for &v in p.versions {prefab_version_free(&v)}
        clear(&p.versions)
        prefab_records_free(&p.pending)
        p.has_pending=false
        p.last_state=edits_scene_state(edits)
        p.observed=false
        clear(&p.remote)
        p.remote_places=false
        if prefab_linked(s) {prefab_refresh(s,{},true)}
        return
    }
    prefabs_sync(s,p)
    if !edits.open && !edits.commit {prefab_observe(s)}
}

@(private)
prefabs_pending_cancel :: proc(s:^Session) {
    p:=prefabs_of(s)
    if p==nil || !p.has_pending {return}
    if s.document.previous!=nil {prefab_records_put(s.document.previous,&p.pending)}
    prefab_records_free(&p.pending)
    p.has_pending=false
}

// The history moved: the records and the files of the step it is at. Only
// the steps in order move it (history_prefab_step): an undo goes back across
// each version it took back, newest first, and a redo forward across each it
// brought again, oldest first.
@(private)
prefabs_sync :: proc(s:^Session,p:^Prefabs) {
    edits:=s.edits
    if p.epoch!=edits.epoch || s.document.previous==nil && !p.has_pending {return}
    state:=edits_scene_state(edits)
    if p.has_pending && !edits.open && state==p.pending_state {prefabs_pending_cancel(s)}
    if state==p.last_state {return}
    before:=p.last_state
    p.last_state=state
    previous:=s.document.previous
    if state<before {
        #reverse for step in edits.steps[edits.cursor:] {
            if step.state>before || step.state<=state {continue}
            if v:=prefab_version_of(p,step.state);v!=nil {
                prefab_records_move(previous,v,false)
                prefab_files_restore(s,v.files[:],false)
                collab_prefab_step(s,v,false)
            }
        }
    } else {
        for step in edits.steps[:edits.cursor] {
            if step.swapped || step.state<=before || step.state>state {continue}
            if v:=prefab_version_of(p,step.state);v!=nil {
                prefab_records_move(previous,v,true)
                prefab_files_restore(s,v.files[:],true)
                collab_prefab_step(s,v,true)
            }
        }
    }
    if p.has_pending && previous!=nil {
        append(&p.versions,prefab_version_make(&p.pending,previous,p.pending_state,state))
        collab_prefab_step(s,&p.versions[len(p.versions)-1],true)
        prefab_records_free(&p.pending)
        p.has_pending=false
    }
    prefab_versions_prune(p,edits)
}

@(private)
prefab_version_of :: proc(p:^Prefabs,state:u64) -> ^Prefab_Version {
    for &v in p.versions {
        if v.after_state==state {return &v}
    }
    return nil
}

// Forgets the versions of the steps the history no longer holds: those it
// dropped as the oldest, and those undone that a new step left without redo.
@(private)
prefab_versions_prune :: proc(p:^Prefabs,edits:^Edits) {
    if len(p.versions)==0 {return}
    held:=make(map[u64]bool,len(edits.steps),context.temp_allocator)
    for step in edits.steps {held[step.state]=true}
    left:=0
    for &v in p.versions {
        if !(v.after_state in held) {
            prefab_version_free(&v)
            continue
        }
        p.versions[left]=v
        left+=1
    }
    resize(&p.versions,left)
}

// The version of a step from the records before it and the scene that holds those after it.
@(private)
prefab_version_make :: proc(before:^Prefab_Records,after:^asset.Scene,before_state,after_state:u64) -> (v:Prefab_Version) {
    v.before_state,v.after_state=before_state,after_state
    records_minus(&v.gone.instances,before.instances[:],after.instances[:],instance_less)
    records_minus(&v.gone.members,before.members[:],after.members[:],member_less)
    records_minus(&v.gone.overrides,before.overrides[:],after.overrides[:],override_less)
    records_minus(&v.came.instances,after.instances[:],before.instances[:],instance_less)
    records_minus(&v.came.members,after.members[:],before.members[:],member_less)
    records_minus(&v.came.overrides,after.overrides[:],before.overrides[:],override_less)
    v.gone.last_instance,v.came.last_instance=before.last_instance,after.info.last_instance
    return
}

// Moves the records of a document across the step of a version: forward,
// from before it to after it; back, from after it to before it.
@(private)
prefab_records_move :: proc(into:^asset.Scene,v:^Prefab_Version,forward:bool) {
    if into==nil {return}
    out,back:=&v.came,&v.gone
    if forward {out,back=&v.gone,&v.came}
    records_swap(&into.instances,out.instances[:],back.instances[:])
    records_swap(&into.members,out.members[:],back.members[:])
    records_swap(&into.overrides,out.overrides[:],back.overrides[:])
    into.info.last_instance=back.last_instance
}

// Appends to out what from has that without does not, each as many times as
// from has it more. less orders by every field, so two records the order
// does not tell apart are the same.
@(private="file")
records_minus :: proc(out:^[dynamic]$T,from,without:[]T,less:proc(a,b:T) -> bool) {
    a,b:=slice.clone(from,context.temp_allocator),slice.clone(without,context.temp_allocator)
    slice.sort_by(a,less)
    slice.sort_by(b,less)
    j:=0
    for x in a {
        for j<len(b) && less(b[j],x) {j+=1}
        if j<len(b) && !less(x,b[j]) {
            j+=1
            continue
        }
        append(out,x)
    }
}

// Takes out of the records one of each of out, and puts in each of back they do not hold.
@(private="file")
records_swap :: proc(records:^[dynamic]$T,out,back:[]T) {
    for x in out {
        if at,found:=slice.linear_search(records[:],x);found {ordered_remove(records,at)}
    }
    for x in back {
        if !slice.contains(records[:],x) {append(records,x)}
    }
}

@(private="file")
instance_less :: proc(a,b:asset.Instance) -> bool {
    if a.id!=b.id {return a.id<b.id}
    if a.prefab[0]!=b.prefab[0] {return a.prefab[0]<b.prefab[0]}
    if a.prefab[1]!=b.prefab[1] {return a.prefab[1]<b.prefab[1]}
    if a.root!=b.root {return a.root<b.root}
    if a.outer!=b.outer {return a.outer<b.outer}
    return a.stamp<b.stamp
}

@(private="file")
member_less :: proc(a,b:asset.Member) -> bool {
    if a.instance!=b.instance {return a.instance<b.instance}
    if a.entity!=b.entity {return a.entity<b.entity}
    return a.source<b.source
}

@(private="file")
override_less :: proc(a,b:asset.Override) -> bool {
    if a.instance!=b.instance {return a.instance<b.instance}
    if a.entity!=b.entity {return a.entity<b.entity}
    if a.component!=b.component {return a.component<b.component}
    if a.kind!=b.kind {return a.kind<b.kind}
    for i in 0..<len(a.path) {
        if a.path[i]!=b.path[i] {return a.path[i]<b.path[i]}
    }
    return false
}

@(private)
prefab_version_free :: proc(v:^Prefab_Version) {
    prefab_records_free(&v.gone);prefab_records_free(&v.came)
    for file in v.files {
        delete(file.path);delete(file.before);delete(file.after)
    }
    delete(v.files)
}

// A prefab file written by an operation, with the bytes it had and the ones it got.
Prefab_File :: struct {
    path:string,
    before,after:[]u8, // nil: it did not exist
}

// Writes a prefab and remembers what it replaced.
@(private)
prefab_file_save :: proc(prefab:^asset.Scene,path:string,files:^[dynamic]Prefab_File) -> bool {
    before,read_error:=os.read_entire_file(path,context.allocator)
    had:=read_error==nil
    if asset.scene_save(prefab,path)!=.None {
        delete(before)
        return false
    }
    after,_:=os.read_entire_file(path,context.allocator)
    kept:=strings.clone(path)
    append(files,Prefab_File{path=kept,before=had?before:nil,after=after})
    return true
}

@(private)
prefab_files_wrote :: proc(s:^Session,files:[]Prefab_File) {
    paths:=make([]string,len(files),context.temp_allocator)
    for file,at in files {paths[at]=file.path}
    assets_wrote(s,..paths)
}

// Gives the files of a step the bytes they had before it or after it, unless they were changed by other means.
@(private)
prefab_files_restore :: proc(s:^Session,files:[]Prefab_File,after:bool) {
    a:=s.app.assets
    if len(files)==0 || a==nil {return}
    for file in files {
        expected,wanted:=file.before,file.after
        if !after {expected,wanted=file.after,file.before}
        current,current_error:=os.read_entire_file(file.path,context.temp_allocator)
        exists:=current_error==nil
        matches:=(expected==nil && !exists) || (expected!=nil && exists && slice.equal(current,expected))
        if !matches {continue}
        if wanted==nil {
            os.remove(file.path)
        } else {
            _=os.write_entire_file(file.path,wanted)
        }
    }
    paths:=make([]string,len(files),context.temp_allocator)
    for file,at in files {paths[at]=file.path}
    prefab_files_reload(s,paths)
}

// The prefabs of files written are read again, and the instances compared with them.
@(private)
prefab_files_reload :: proc(s:^Session,paths:[]string) {
    a:=s.app.assets
    if len(paths)==0 || a==nil {return}
    assets_wrote(s,..paths)
    for path in paths {
        id:base.Asset_Id
        found:=false
        for &entry in a.registry.files {
            if entry.kind==asset.KIND_PREFAB && asset.registry_file_path(&a.registry,entry.path,context.temp_allocator)==path {
                id,found=entry.id,true
                break
            }
        }
        if !found {continue}
        _=host.assets_reload(a,id)
        if loaded,ok:=prefab_scene_load(s,id);ok {prefab_base_set(s,id,loaded)}
    }
}

// Marks the overrides of the instances placed in the document from the World:
// what their members hold that the prefab they were last brought up to date
// from does not. It looks again only at what the steps of the history since
// the last observation changed (their Step_Rows) and at the instances whose
// prefab was read again since; at everything when the history does not say,
// or while edits wait for their step. On an error the overrides stay as they
// were, and the next calls give it until something changes.
prefab_observe :: proc(s:^Session) -> Prefab_Error {
    if s.app.assets==nil {return .None}
    p:=prefabs_of(s)
    edits:=s.edits
    w:=edited_world(s)
    prefabs_sync(s,p)
    if !prefab_linked(s) {return .None}
    pending:=edits.open || edits.commit || w.data!=edits.world
    remote:=len(p.remote)>0 || p.remote_places
    if !pending && !remote && p.observed && p.observed_turns==edits.turns && p.observed_initial==edits.initial && p.observed_bases==p.bases_serial {return p.observe_error}
    core.world_settle(w)
    touched,whole:=prefab_touched(s,p)
    error:=prefab_observe_world(s,p,&touched,whole || pending)
    clear(&p.remote)
    p.remote_places=false
    p.observed,p.observed_turns,p.observed_initial,p.observed_bases,p.observe_error=!pending,edits.turns,edits.initial,p.bases_serial,error
    return error
}

// The entities the steps of the history changed since the last observation
// (their turn is later), by handle and by Id.
@(private)
Prefab_Touched :: struct {
    entities:map[core.Entity]bool,
    ids:map[base.Entity_Id]bool,
    places:bool, // an Id or a parent changed, or which entities are alive
}

// whole: the history does not hold the steps since the last observation.
@(private)
prefab_touched :: proc(s:^Session,p:^Prefabs) -> (touched:Prefab_Touched,whole:bool) {
    edits:=s.edits
    if !p.observed || p.observed_initial!=edits.initial {return {},true}
    w:=edited_world(s)
    ids:=core.world_table_of(w,core.Id)
    id_table,parent_table:=-1,-1
    for t,i in w.info.tables {
        if t.place!=w.place {continue}
        if t.type==core.Id {id_table=i} else if t.type==core.Parent {parent_table=i}
    }
    touched.entities=make(map[core.Entity]bool,context.temp_allocator)
    touched.ids=make(map[base.Entity_Id]bool,context.temp_allocator)
    for &step in edits.steps {
        if step.turned<=p.observed_turns {continue}
        touched.places||=len(step.entities.indices)>0
        for &rows in step.tables {
            touched.places||=rows.table==id_table || rows.table==parent_table
            size:=w.info.tables[rows.table].info.size
            for e,k in rows.entities {
                touched.entities[e]=true
                // One no longer alive has its Id in the rows of the step that destroyed it.
                if id:=core.id_of(core.read(ids),e);id!=0 {touched.ids[id]=true}
                else if rows.table==id_table && rows.present[k] {touched.ids[(^core.Id)(&rows.values[k*size]).value]=true}
            }
        }
    }
    touched.places||=p.remote_places
    for id in p.remote {
        touched.ids[id]=true
        if e:=api_entity(w,id);e!=core.NONE {touched.entities[e]=true}
    }
    return touched,false
}

// The entities, by Id, that an edit of another editor of the session
// changed; places: it changed an Id or a parent.
prefabs_remote_edited :: proc(s:^Session,ids:[]base.Entity_Id,places:bool) {
    p:=prefabs_of(s)
    if p==nil || s.document==nil || s.document.previous==nil || len(s.document.previous.instances)==0 {return}
    for id in ids {p.remote[id]=true}
    p.remote_places||=places
}

@(private)
prefab_observe_world :: proc(s:^Session,p:^Prefabs,touched:^Prefab_Touched,whole:bool) -> Prefab_Error {
    previous:=s.document.previous
    w:=edited_world(s)
    // The instance placed in the document and the entity of the prefab of each member.
    Placed :: struct {instance:u32,source:base.Entity_Id}
    members:=make(map[base.Entity_Id]Placed,context.temp_allocator)
    based:=make(map[u32]^Prefab_Base,context.temp_allocator)
    for instance in previous.instances {
        if instance.outer!=0 {continue}
        if b:=prefab_base_find(p,instance.prefab);b!=nil {based[instance.id]=b}
    }
    for member in previous.members {
        if member.instance in based {members[member.entity]={member.instance,member.source}}
    }
    // What is looked at again of each instance: its places, and the values of all its members or of those touched.
    Scope :: struct {places,all:bool}
    scopes:=make(map[u32]Scope,context.temp_allocator)
    for instance,b in based {
        if whole || b.serial>p.observed_bases {scopes[instance]={true,true}}
    }
    touched_values:=make(map[base.Entity_Id]bool,context.temp_allocator)
    if !whole {
        reach :: proc(scopes:^map[u32]Scope,instance:u32,places:bool) {
            scope:=scopes[instance]
            scope.places||=places
            scopes[instance]=scope
        }
        for id in touched.ids {
            if placed,member:=members[id];member {
                reach(&scopes,placed.instance,touched.places)
                touched_values[id]=true
            }
        }
        for override in previous.overrides {
            if override.entity in touched.ids && override.instance in based {reach(&scopes,override.instance,touched.places)}
        }
        if touched.places {
            for e in touched.entities {
                if !entity_alive(w,e) {continue}
                if placed,member:=members[api_entity_id(w,entity_parent(w,e))];member {reach(&scopes,placed.instance,true)}
            }
        }
    }
    if len(scopes)==0 {return .None}
    compared:=make([dynamic]core.Entity,context.temp_allocator)
    compared_ids:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for member in previous.members {
        placed,known:=members[member.entity]
        scope,looked:=scopes[placed.instance]
        if !known || member.instance!=placed.instance || !looked || !scope.all && !touched_values[member.entity] || member.entity in compared_ids {continue}
        if e:=api_entity(w,member.entity);e!=core.NONE {
            append(&compared,e)
            compared_ids[member.entity]=true
        }
    }
    fresh:=make([dynamic]asset.Override,context.temp_allocator)
    if len(compared)>0 {
        cap:asset.Scene
        if _,error:=scene.capture(w,&cap,&s.app.assets.types,{entities=compared[:],kind=asset.KIND_PREFAB});error!=.None {return .Capture_Failed}
        defer asset.scene_destroy(&cap)
        pairs:=make(map[base.Asset_Id][]Prefab_Pair,context.temp_allocator)
        remaps:=make(map[u32]map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
        for member in previous.members {
            if !compared_ids[member.entity] || member.instance!=members[member.entity].instance {continue}
            instance:=previous.instances[asset.scene_instance_find(previous,member.instance)]
            b:=based[instance.id]
            if !(b.id in pairs) {pairs[b.id]=prefab_pairs(&cap,b.scene) or_return}
            if !(instance.id in remaps) {
                remap:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
                for other in previous.members {
                    if other.instance==instance.id {remap[other.source]=other.entity}
                }
                remaps[instance.id]=remap
            }
            prefab_member_observe(&fresh,instance,member.entity,member.source,&cap,b.scene,pairs[b.id],remaps[instance.id])
        }
    }
    for instance in previous.instances {
        if scope,looked:=scopes[instance.id];looked && scope.places {prefab_places_observe(&fresh,w,instance,previous)}
    }
    // The fresh overrides take the place of those of what was looked at; the
    // rest stay, those of members the World does not have now too: an undo
    // may bring them back. The placement of a root is never an override.
    kept:=make([dynamic]asset.Override,context.temp_allocator)
    for &override in previous.overrides {
        if at:=asset.scene_instance_find(previous,override.instance);at>=0 && prefab_placement(&override,previous.instances[at].root) {continue}
        scope,looked:=scopes[override.instance]
        if looked && (override.kind>=.Child ? scope.places : compared_ids[override.entity]) {continue}
        append(&kept,override)
    }
    append(&kept,..fresh[:])
    clear(&previous.overrides)
    append(&previous.overrides,..kept[:])
    return .None
}

// Marks the entities a placed instance added under its members (Child), in
// the order of its members and of their children.
@(private)
prefab_places_observe :: proc(out:^[dynamic]asset.Override,w:core.World_Ref,instance:asset.Instance,previous:^asset.Scene) {
    inside:=make(map[core.Entity]bool,context.temp_allocator)
    for member in previous.members {
        if member.instance!=instance.id {continue}
        if e:=api_entity(w,member.entity);e!=core.NONE {inside[e]=true}
    }
    ids:=core.read(core.world_table_of(w,core.Id))
    for member in previous.members {
        if member.instance!=instance.id {continue}
        e:=api_entity(w,member.entity)
        if e==core.NONE {continue}
        for child in entity_children(w,e) {
            if child in inside {continue}
            if id:=core.id_of(ids,child);id!=0 {append(out,prefab_override_make(instance.id,id,0,.Child,""))}
        }
    }
}

@(private)
Prefab_Pair :: struct {
    cap_table,base_table:int, // -1 where the scene or the prefab lacks the component
    hash:u64,
    name:string,
    size:int,
    migration:serial.Migration,
    refs:[dynamic]serial.Ref,
    leaves:[dynamic]asset.Value_Leaf,
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

// The pairs of tables of a scene and of a prefab, allocated in scratch memory.
@(private)
prefab_pairs :: proc(cap,prefab:^asset.Scene) -> ([]Prefab_Pair,Prefab_Error) {
    pairs:=make([dynamic]Prefab_Pair,context.temp_allocator)
    matched:=make(map[u64]bool,context.temp_allocator)
    for at in prefab_component_tables(cap) {
        table:=&cap.doc.tables[at]
        pair:=Prefab_Pair{cap_table=at,base_table=-1,hash=table.name_hash,name=table.name,size=table.columns[1].size}
        if bt,found:=asset.scene_component_by_hash(prefab,table.name_hash);found {
            pair.base_table=bt
            matched[table.name_hash]=true
            if error:=serial.migration_init(&pair.migration,&prefab.doc.schema,prefab.doc.tables[bt].columns[1].type,&cap.doc.schema,table.columns[1].type,context.temp_allocator);error!=.None {
                return nil,.Out_Of_Memory if error==.Out_Of_Memory else .Rejected
            }
        }
        pair.refs.allocator=context.temp_allocator
        pair.leaves.allocator=context.temp_allocator
        serial.refs_collect(&cap.doc.schema,table.columns[1].type,&pair.refs)
        asset.value_leaves(&cap.doc.schema,table.columns[1].type,&pair.leaves)
        append(&pairs,pair)
    }
    for bt in prefab_component_tables(prefab) {
        table:=&prefab.doc.tables[bt]
        if matched[table.name_hash] {continue}
        append(&pairs,Prefab_Pair{cap_table=-1,base_table=bt,hash=table.name_hash,name=table.name})
    }
    return pairs[:],.None
}

// The image of a component of the prefab in the layout of the scene, its references pointing at the members.
@(private)
prefab_image :: proc(pair:^Prefab_Pair,prefab:^asset.Scene,source:base.Entity_Id,remap:map[base.Entity_Id]base.Entity_Id) -> (image:[]u8,found:bool) {
    stored:[]u8
    stored,found=asset.scene_component_get(prefab,pair.base_table,source)
    if !found {return}
    image=make([]u8,max(pair.size,1),context.temp_allocator)
    if pair.cap_table<0 {return image,true}
    serial.migration_apply(&pair.migration,image[:pair.size],stored,1)
    for ref in pair.refs {
        if ref.kind==.Asset {continue}
        target:=(^u64)(&image[ref.offset])
        if target^!=0 {target^=u64(remap[base.Entity_Id(target^)])}
    }
    return image,true
}

@(private)
prefab_override_text :: proc(override:^asset.Override) -> string {return serial.text_field(override.path[:])}

@(private)
prefab_override_make :: proc(instance:u32,entity:base.Entity_Id,component:u64,kind:asset.Override_Kind,path:string) -> (o:asset.Override) {
    o={instance=instance,entity=entity,component=component,kind=kind}
    if len(path)<len(o.path) {copy(o.path[:],path)}
    return
}

// Marks what a member of a placed instance holds that its entity of the
// prefab does not: its name, and components added, removed, turned or with
// other values. cap holds the member as the World has it.
@(private)
prefab_member_observe :: proc(out:^[dynamic]asset.Override,instance:asset.Instance,entity,source:base.Entity_Id,cap,prefab:^asset.Scene,pairs:[]Prefab_Pair,remap:map[base.Entity_Id]base.Entity_Id) {
    row,in_cap:=asset.scene_entity_find(cap,entity)
    base_row,in_base:=asset.scene_entity_find(prefab,source)
    if !in_cap || !in_base {return}
    if asset.scene_names(cap)[row]!=asset.scene_names(prefab)[base_row] {append(out,prefab_override_make(instance.id,entity,0,.Field,"name"))}
    placement:=instance.root==entity?base.name_hash(asset.INSTANCE_PLACEMENT):0
    for &pair in pairs {
        if pair.hash==placement {continue}
        cap_image:[]u8
        cap_has,base_has:=false,false
        if pair.cap_table>=0 {cap_image,cap_has=asset.scene_component_get(cap,pair.cap_table,entity)}
        if pair.base_table>=0 {_,base_has=asset.scene_component_get(prefab,pair.base_table,source)}
        switch {
        case cap_has && !base_has:
            append(out,prefab_override_make(instance.id,entity,pair.hash,.Added,""))
        case !cap_has && base_has:
            append(out,prefab_override_make(instance.id,entity,pair.hash,.Removed,""))
        case cap_has && base_has:
            if asset.scene_component_off(cap,entity,pair.hash)!=asset.scene_component_off(prefab,source,pair.hash) {
                append(out,prefab_override_make(instance.id,entity,pair.hash,.Turned,""))
            }
            image,_:=prefab_image(&pair,prefab,source,remap)
            marked:=make([dynamic]string,context.temp_allocator)
            asset.overrides_mark(pair.leaves[:],cap_image,image,&marked)
            for path in marked {append(out,prefab_override_make(instance.id,entity,pair.hash,.Field,len(path)<asset.OVERRIDE_PATH_BYTES?path:""))}
        }
    }
}

// ---------------------------------------------------------------- queries

Prefab_Instance_State :: struct {
    instance:u32,
    asset:base.Asset_Id,
    path:string,
    root:base.Entity_Id,
    outer:u32,
    members,overrides:int,
    missing,stale:bool,
}

// The instances of the document whose root exists. Overrides are counted
// without the placement. One placed in the document is stale when its stamp
// is not the content hash of the file of its prefab, or when that prefab
// holds a stale instance.
prefab_instances :: proc(s:^Session,allocator:=context.temp_allocator) -> []Prefab_Instance_State {
    out:=make([dynamic]Prefab_Instance_State,allocator)
    previous:=s.document.previous
    if previous==nil || s.app.assets==nil {return out[:]}
    assets_rescan(s)
    reader:Prefab_Reader
    prefab_reader_begin(s,&reader)
    defer prefab_reader_end(&reader)
    for instance in previous.instances {
        if api_entity(edited_world(s),instance.root)==core.NONE {continue}
        state:=Prefab_Instance_State{instance=instance.id,asset=instance.prefab,root=instance.root,outer=instance.outer}
        file,_,found:=prefab_file(s,instance.prefab)
        state.missing=!found
        if found {state.path=file.path}
        state.stale=asset.resolver_instance_stale(&reader.resolver,instance)
        for member in previous.members {
            if member.instance==instance.id {state.members+=1}
        }
        for &override in previous.overrides {
            if override.instance==instance.id && !prefab_placement(&override,instance.root) {state.overrides+=1}
        }
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

// ---------------------------------------------------------------- operations

// entity 0 selects the entire instance; no paths selects every override in that scope.
@(private)
prefab_overrides_select :: proc(cap:^asset.Scene,instance:u32,entity:base.Entity_Id,paths:[]string,hashes:map[u64]string) -> (indices:[dynamic]int,error:Prefab_Error) {
    indices.allocator=context.temp_allocator
    at:=asset.scene_instance_find(cap,instance)
    root:=at>=0?cap.instances[at].root:base.Entity_Id(0)
    for &override,at in cap.overrides {
        if override.instance!=instance || entity!=0 && override.entity!=entity {continue}
        if prefab_placement(&override,root) {continue}
        if len(paths)==0 {
            append(&indices,at)
            continue
        }
        for path in paths {
            name,_,field:=strings.partition(path,".")
            selected:=false
            switch {
            case override.component==0:
                selected=strings.equal_fold(path,prefab_place_name(override.kind))
            case:
                component:=hashes[override.component]
                selected=strings.equal_fold(component,name) && (field=="" || override.kind==.Field && asset.path_covers(field,prefab_override_text(&override)))
            }
            if selected {append(&indices,at);break}
        }
    }
    if len(paths)>0 && len(indices)==0 {return indices,.Unknown_Path}
    return indices,.None
}

@(private)
prefab_component_names :: proc(s:^Session) -> map[u64]string {
    names:=make(map[u64]string,context.temp_allocator)
    for t in s.info.tables {names[base.name_hash(t.name)]=t.name}
    return names
}

// The overrides prefab_overrides_select names, as they are now: what an operation applies or forgets
// while it changes the records.
@(private)
prefab_overrides_take :: proc(cap:^asset.Scene,instance:u32,entity:base.Entity_Id,paths:[]string,hashes:map[u64]string) -> (selected:[]asset.Override,error:Prefab_Error) {
    indices:=prefab_overrides_select(cap,instance,entity,paths,hashes) or_return
    selected=make([]asset.Override,len(indices),context.temp_allocator)
    for i,at in indices {selected[at]=cap.overrides[i]}
    return selected,.None
}

@(private)
prefab_overrides_drop :: proc(cap:^asset.Scene,selected:[]asset.Override) {
    left:=0
    next: for override in cap.overrides {
        for chosen in selected {
            if override==chosen {continue next}
        }
        cap.overrides[left]=override
        left+=1
    }
    resize(&cap.overrides,left)
}

// What writing an entity an instance added into its prefab answers.
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
    if !strings.has_suffix(file,PREFAB_EXTENSION) {file=strings.concatenate({file,PREFAB_EXTENSION},context.temp_allocator)}
    inside:=strings.has_prefix(strings.to_lower(file,context.temp_allocator),strings.to_lower(s.assets_root,context.temp_allocator))
    if !inside {return "",.Outside_Assets}
    if os.exists(file) {return "",.Exists}
    return file,.None
}

// Writes the subtree of an entity as a prefab of the assets and links the entity as its first instance.
prefab_create :: proc(s:^Session,root:core.Entity,path:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    return prefab_create_entities(s,{root},path)
}

prefab_create_entities :: proc(s:^Session,entities:[]core.Entity,path:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    if len(entities)==0 {return {},.Unknown_Entity}
    selected:=Selection{}
    selected.entities.allocator=context.temp_allocator
    append(&selected.entities,..entities)
    roots:=selection_roots(&selected,edited_world(s))
    if len(roots)==0 {return {},.Unknown_Entity}
    for e in roots {
        _=prefab_entity_id(s,e) or_return
        if prefab_member_locked(s,edited_world(s),e) {return {},.Member_Locked}
    }
    file:=prefab_new_file(s,path) or_return
    edit:=prefab_begin(s) or_return
    root:=roots[0]
    w:=edited_world(s)
    grouped:=len(roots)>1
    defer {
        if error!=.None && grouped {
            edits_cancel(s.edits,w)
            selection_restore(s.selection,w,s.edits.selection[:])
        }
    }
    if grouped {
        _,edit_ready:=edit_open(s,"Create prefab")
        if !edit_ready {prefab_abort(&edit);return {},.Out_Of_Memory}
        selection_set(s.selection,roots)
        selection_group(s,w)
        core.world_settle(w)
        root=selection_active(s.selection)
        for e in roots {
            if entity_parent(w,e)!=root {
                prefab_abort(&edit)
                return {},.Rejected
            }
        }
        captured:=new(asset.Scene)
        if _,capture_error:=scene.capture(w,captured,&a.types,{previous=edit.cap,id=s.document.id});capture_error!=.None {
            prefab_scene_free(captured)
            prefab_abort(&edit)
            return {},.Capture_Failed
        }
        prefab_scene_free(edit.cap)
        edit.cap=captured
    }
    root_id:=api_entity_id(w,root)
    cap:=edit.cap
    sub:asset.Scene
    id=asset_id_new(s)
    if _,capture_error:=scene.capture(w,&sub,&a.types,{root=root,kind=asset.KIND_PREFAB,id=id});capture_error!=.None {
        prefab_abort(&edit)
        return {},.Capture_Failed
    }
    defer asset.scene_destroy(&sub)
    // The root stands at the origin, upright, with its scale.
    if placed,has:=asset.scene_get(&sub,root_id,"Transform",core.Transform);has {
        placed.position,placed.rotation=0,1
        asset.scene_set(&sub,root_id,"Transform",&placed)
    }
    // The instances inside the subtree come with it, as the ones it brings in.
    inside_ids:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for entity in asset.scene_ids(&sub) {inside_ids[entity]=true}
    included:=make(map[u32]bool,context.temp_allocator)
    for instance in cap.instances {
        if instance.root in inside_ids {
            included[instance.id]=true
            append(&sub.instances,instance)
            sub.info.last_instance=max(sub.info.last_instance,instance.id)
        }
    }
    for member in cap.members {
        if included[member.instance] && member.entity in inside_ids {append(&sub.members,member)}
    }
    for override in cap.overrides {
        if included[override.instance] && override.entity in inside_ids {append(&sub.overrides,override)}
    }
    os.make_directory_all(file[:max(strings.last_index_byte(file,'/'),0)])
    if !prefab_file_save(&sub,file,&edit.files) {
        prefab_abort(&edit)
        return {},.Write_Failed
    }
    assets_wrote(s,file)
    // The new instance is the first of the document; the ones it brings in follow it.
    for &instance in cap.instances {instance.id+=1;if instance.outer!=0 {instance.outer+=1}}
    for &member in cap.members {member.instance+=1}
    for &override in cap.overrides {override.instance+=1}
    cap.info.last_instance+=1
    for &instance in cap.instances {
        if instance.id-1 in included && instance.outer==0 {instance.outer=1}
    }
    append(&cap.instances,asset.Instance{id=1,prefab=id,root=root_id,stamp=sub.stamp})
    for entity in asset.scene_ids(&sub) {append(&cap.members,asset.Member{instance=1,source=entity,entity=entity})}
    if loaded,ok:=prefab_scene_load(s,id);ok {prefab_base_set(s,id,loaded)}
    return id,prefab_finish(&edit,"Create prefab")
}

// Writes a variant of a prefab: a new prefab whose root is an instance of it,
// its base, at the origin. What the variant changes of its base are the
// overrides of that instance, so it follows every later change of the base.
prefab_variant_create :: proc(s:^Session,base_id:base.Asset_Id,path:string) -> (id:base.Asset_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    assets_rescan(s)
    if _,_,known:=prefab_file(s,base_id);!known {return {},.Not_Found}
    file:=prefab_new_file(s,path) or_return
    loaded,found:=prefab_scene_load(s,base_id)
    if !found {return {},.Not_Found}
    defer prefab_scene_free(loaded)
    edit:=prefab_begin(s) or_return
    variant:asset.Scene
    id=asset_id_new(s)
    if asset.scene_init(&variant,&a.types,asset.KIND_PREFAB,id)!=.None {
        prefab_abort(&edit)
        return {},.Out_Of_Memory
    }
    defer asset.scene_destroy(&variant)
    _,root,place_error:=asset.scene_instantiate(&variant,loaded,base_id,0)
    if place_error!=.None {
        prefab_abort(&edit)
        return {},prefab_place_error(place_error)
    }
    variant.info.root=root
    if placed,has:=asset.scene_get(&variant,root,asset.INSTANCE_PLACEMENT,core.Transform);has {
        placed.position,placed.rotation=0,1
        asset.scene_set(&variant,root,asset.INSTANCE_PLACEMENT,&placed)
    }
    os.make_directory_all(file[:max(strings.last_index_byte(file,'/'),0)])
    if !prefab_file_save(&variant,file,&edit.files) {
        prefab_abort(&edit)
        return {},.Write_Failed
    }
    assets_wrote(s,file)
    return id,prefab_finish(&edit,"Create prefab variant")
}

// A free path for a variant of a prefab: beside it, named after it.
prefab_variant_path :: proc(s:^Session,base_id:base.Asset_Id) -> string {
    file,_,found:=prefab_file(s,base_id)
    if !found {return "prefabs/Variant"}
    stem:=file.path[:len(file.path)-len(PREFAB_EXTENSION)] if strings.has_suffix(file.path,PREFAB_EXTENSION) else file.path
    for n in 1..<10000 {
        path:=n==1?fmt.tprintf("%s_variant",stem):fmt.tprintf("%s_variant_%d",stem,n)
        if !os.exists(scene_file(s,strings.concatenate({path,PREFAB_EXTENSION},context.temp_allocator))) {return path}
    }
    return fmt.tprintf("%s_variant",stem)
}

// The bases of a prefab, from its own outwards; empty when it is not a variant.
prefab_variant_chain :: proc(s:^Session,id:base.Asset_Id,allocator:=context.temp_allocator) -> []base.Asset_Id {
    chain:=make([dynamic]base.Asset_Id,allocator)
    at:=id
    for _ in 0..<PREFAB_CYCLE_DEPTH {
        loaded,found:=prefab_scene_load(s,at)
        if !found {break}
        _,next:=asset.prefab_variant_base(loaded)
        prefab_scene_free(loaded)
        if next=={} || slice.contains(chain[:],next) || next==id {break}
        append(&chain,next)
        at=next
    }
    return chain[:]
}

// The base of a prefab placed in the document, as its instances were last
// updated from it; none when it is not a variant or not known.
prefab_placed_base :: proc(s:^Session,prefab_id:base.Asset_Id) -> base.Asset_Id {
    p:=prefabs_of(s)
    if p==nil {return {}}
    b:=prefab_base_find(p,prefab_id)
    if b==nil || b.scene==nil {return {}}
    _,variant_base:=asset.prefab_variant_base(b.scene)
    return variant_base
}

// The base of the variant an entity is the root of: of the prefab its
// instance places or, in the document of a variant, of the document itself.
prefab_variant_of :: proc(s:^Session,link:Prefab_Link,id:base.Entity_Id) -> base.Asset_Id {
    if !link.root {return {}}
    previous:=s.document.previous
    if previous!=nil && previous.doc.kind==asset.KIND_PREFAB && previous.info.root==id {return link.asset}
    return prefab_placed_base(s,link.asset)
}

Prefab_Placement :: struct {
    parent:core.Entity,
    position:[3]f32,
    rotation:[4]f32, // x, y, z, w; the identity when all are zero
    scale_multiplier:[3]f32, // 1 when zero
}

// Places an instance of a prefab: new entities with new ids, the root where the placement says.
prefab_instantiate :: proc(s:^Session,prefab_id:base.Asset_Id,placement:Prefab_Placement) -> (root:base.Entity_Id,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return 0,.No_Assets}
    placement:=placement
    automatic_parent:=placement.parent==core.NONE?document_root(s,edited_world(s)):core.NONE
    if automatic_parent!=core.NONE {placement.parent=automatic_parent}
    loaded,found:=prefab_scene_load(s,prefab_id)
    if !found {return 0,.Not_Found}
    parent_id:base.Entity_Id
    if placement.parent!=core.NONE {
        parent_id=prefab_entity_id(s,placement.parent) or_return
    }
    if s.document.id==prefab_id || prefab_contains(s,loaded,s.document.id) && s.document.previous!=nil && s.document.previous.doc.kind==asset.KIND_PREFAB {
        prefab_scene_free(loaded)
        return 0,.Cycle
    }
    edit,begin_error:=prefab_begin(s)
    if begin_error!=.None {
        prefab_scene_free(loaded)
        return 0,begin_error
    }
    cap:=edit.cap
    refresh_others:=prefab_stale(s,prefab_id)
    instance,placed,instance_error:=asset.scene_instantiate(cap,loaded,prefab_id,parent_id)
    if instance_error!=.None {
        prefab_scene_free(loaded)
        prefab_abort(&edit)
        return 0,.Rejected
    }
    local,_:=asset.scene_get(cap,placed,"Transform",core.Transform)
    if placement.rotation!={} {local.rotation=quaternion(x=placement.rotation.x,y=placement.rotation.y,z=placement.rotation.z,w=placement.rotation.w)} else {local.rotation=1}
    local.position=placement.position
    if placement.scale_multiplier!={} {local.scale*=placement.scale_multiplier}
    if automatic_parent!=core.NONE {
        relative,ok:=mm.transform_relative(core.to_math(local),entity_world(edited_world(s),automatic_parent))
        if !ok {prefab_scene_free(loaded);prefab_abort(&edit);return 0,.Rejected}
        local=core.from_math(relative)
    }
    asset.scene_set(cap,placed,"Transform",&local)
    if refresh_others {
        others:=make([dynamic]u32,context.temp_allocator)
        for other in cap.instances {
            if other.prefab==prefab_id && other.outer==0 && other.id!=instance {append(&others,other.id)}
        }
        for other in others {asset.scene_instance_update(cap,other,loaded)}
    }
    prefab_base_set(s,prefab_id,loaded)
    error=prefab_finish(&edit,"Instantiate prefab")
    return placed,error
}

Prefab_Report :: struct {
    prefabs,instances,missing,failed:int,
}

// Brings the instances of a prefab, or of all of them, up to date with its file: the members follow the
// prefab except in what the instance holds on its own. quiet: the same, without a step of undo to hold it.
prefab_refresh :: proc(s:^Session,prefab_id:base.Asset_Id,quiet:=false) -> (report:Prefab_Report,error:Prefab_Error) {
    a:=s.app.assets
    if a==nil {return {},.No_Assets}
    if !prefab_linked(s) {return}
    assets_rescan(s)
    edit:=prefab_begin(s) or_return
    cap:=edit.cap
    done:=make(map[base.Asset_Id]bool,context.temp_allocator)
    // An update changes the instances its instance brought in: the placed ones are listed first.
    placed:=make([dynamic]asset.Instance,context.temp_allocator)
    for instance in cap.instances {
        if instance.outer==0 {append(&placed,instance)}
    }
    for instance in placed {
        if prefab_id!={} && instance.prefab!=prefab_id || done[instance.prefab] {continue}
        done[instance.prefab]=true
        report.prefabs+=1
        loaded,found:=prefab_scene_load(s,instance.prefab)
        if !found {
            report.missing+=1
            continue
        }
        failed:=false
        for other in placed {
            if other.prefab!=instance.prefab {continue}
            if asset.scene_instance_update(cap,other.id,loaded)!=.None {
                failed=true
                report.failed+=1
            } else {
                report.instances+=1
            }
        }
        if failed {
            prefab_scene_free(loaded)
        } else {
            prefab_base_set(s,instance.prefab,loaded)
        }
    }
    // The bases of what was not loaded stay as they were; the records of an instance whose update failed too.
    error=prefab_finish(&edit,"Refresh prefabs")
    _=quiet
    return
}

// Forgets overrides of an entity of an instance and gives back what the prefab has: its values, and its
// places: an entity the instance added goes, one it does not have comes back, one it moved goes back.
prefab_revert :: proc(s:^Session,entity:core.Entity,paths:[]string,all_members:=false) -> (count:int,error:Prefab_Error) {
    id:=prefab_entity_id(s,entity) or_return
    edit:=prefab_begin(s) or_return
    cap:=edit.cap
    instance:=prefab_instance_of(cap,id)
    if instance==0 {
        prefab_abort(&edit)
        return 0,.Not_Instance
    }
    selected,select_error:=prefab_overrides_take(cap,instance,all_members?base.Entity_Id(0):id,paths,prefab_component_names(s))
    if select_error!=.None {
        prefab_abort(&edit)
        return 0,select_error
    }
    count=len(selected)
    for override in selected {
        if override.kind==.Child {asset.scene_child_revert(cap,instance,override.entity)}
    }
    prefab_overrides_drop(cap,selected)
    at:=asset.scene_instance_find(cap,instance)
    loaded,found:=prefab_scene_load(s,cap.instances[at].prefab)
    if !found {
        prefab_abort(&edit)
        return 0,.Not_Found
    }
    if asset.scene_instance_update(cap,instance,loaded)!=.None {
        prefab_scene_free(loaded)
        prefab_abort(&edit)
        return 0,.Rejected
    }
    prefab_base_set(s,cap.instances[at].prefab,loaded)
    return count,prefab_finish(&edit,"Revert prefab overrides")
}

// Makes the members of the instance ordinary entities. With recursive the instances it brought in too.
prefab_unlink :: proc(s:^Session,entity:core.Entity,recursive:bool) -> (error:Prefab_Error) {
    id:=prefab_entity_id(s,entity) or_return
    edit:=prefab_begin(s) or_return
    cap:=edit.cap
    instance:=asset.scene_entity_instance(cap,id)
    if instance==0 {
        prefab_abort(&edit)
        return .Not_Instance
    }
    nested:=make([dynamic]u32,context.temp_allocator)
    pending:=make([dynamic]u32,context.temp_allocator)
    append(&pending,instance)
    for len(pending)>0 {
        at:=pop(&pending)
        for other in cap.instances {
            if other.outer==at {
                append(&nested,other.id)
                append(&pending,other.id)
            }
        }
    }
    if asset.scene_instance_unlink(cap,instance)!=.None {
        prefab_abort(&edit)
        return .Rejected
    }
    if recursive {
        for inner in nested {
            if asset.scene_instance_find(cap,inner)>=0 {asset.scene_instance_unlink(cap,inner)}
        }
    }
    return prefab_finish(&edit,"Unlink prefab")
}

// Where Apply writes the overrides of an instance.
Prefab_Apply_Target :: enum u8 {
    Prefab, // the prefab the instance places
    Base,   // through that prefab, a variant, into its base
}

// Writes the overrides of an entity into the file of its prefab, ends them, and brings every instance up to
// date, the prefabs that place this one included. Base: the variant takes them first and its base then
// takes, of what the variant holds as the overrides of its root, what they changed.
prefab_apply :: proc(s:^Session,entity:core.Entity,paths:[]string,all_members:=false,target:=Prefab_Apply_Target.Prefab) -> (count:int,error:Prefab_Error) {
    id:=prefab_entity_id(s,entity) or_return
    edit:=prefab_begin(s) or_return
    cap:=edit.cap
    instance:=prefab_instance_of(cap,id)
    if instance==0 {
        prefab_abort(&edit)
        return 0,.Not_Instance
    }
    at:=asset.scene_instance_find(cap,instance)
    prefab_id:=cap.instances[at].prefab
    selected,select_error:=prefab_overrides_take(cap,instance,all_members?base.Entity_Id(0):id,paths,prefab_component_names(s))
    if select_error!=.None {
        prefab_abort(&edit)
        return 0,select_error
    }
    _,path,located:=prefab_file(s,prefab_id)
    prefab,loaded:=prefab_scene_load(s,prefab_id)
    if !located || !loaded {
        if loaded {prefab_scene_free(prefab)}
        prefab_abort(&edit)
        return 0,.Not_Found
    }
    defer prefab_scene_free(prefab)
    based,base_id:=asset.prefab_variant_base(prefab)
    if target==.Base && based==0 {
        prefab_abort(&edit)
        return 0,.Not_Variant
    }
    if error=prefab_overrides_write(cap,instance,selected,prefab);error!=.None {prefab_abort(&edit);return 0,error}
    count=len(selected)
    prefab_overrides_drop(cap,selected)
    if error=prefab_scene_mark(s,prefab);error!=.None {prefab_abort(&edit);return 0,error}
    changed:=make(map[base.Asset_Id]^asset.Scene,context.temp_allocator)
    owned:=make([dynamic]base.Asset_Id,context.temp_allocator)
    base_scene:^asset.Scene
    defer if base_scene!=nil {prefab_scene_free(base_scene)}
    if target==.Base {
        chosen:=prefab_variant_overrides(cap,instance,selected,prefab,based)
        if len(chosen)>0 {
            _,base_path,base_located:=prefab_file(s,base_id)
            base_loaded:bool
            base_scene,base_loaded=prefab_scene_load(s,base_id)
            if !base_loaded {base_scene=nil}
            if !base_located || !base_loaded {
                prefab_abort(&edit)
                return 0,.Not_Found
            }
            if error=prefab_overrides_write(prefab,based,chosen,base_scene);error!=.None {prefab_abort(&edit);return 0,error}
            prefab_overrides_drop(prefab,chosen)
            if error=prefab_scene_mark(s,base_scene);error!=.None {prefab_abort(&edit);return 0,error}
            if !prefab_file_save(base_scene,base_path,&edit.files) {
                prefab_abort(&edit)
                return 0,.Write_Failed
            }
            if asset.scene_instance_update(prefab,based,base_scene)!=.None {
                prefab_abort(&edit)
                return 0,.Rejected
            }
            changed[base_id]=base_scene
            append(&owned,base_id)
        }
    }
    if !prefab_file_save(prefab,path,&edit.files) {
        prefab_abort(&edit)
        return 0,.Write_Failed
    }
    changed[prefab_id]=prefab
    append(&owned,prefab_id)
    for key in owned {prefab_propagate(s,key,changed[key],&changed,&edit.files)}
    prefab_files_wrote(s,edit.files[:])
    updated:=make([dynamic]asset.Instance,context.temp_allocator)
    for other in cap.instances {
        if other.outer==0 && other.prefab in changed {append(&updated,other)}
    }
    for other in updated {asset.scene_instance_update(cap,other.id,changed[other.prefab])}
    for key,loaded_scene in changed {
        if slice.contains(owned[:],key) {
            reloaded,ok:=prefab_scene_load(s,key)
            if ok {prefab_base_set(s,key,reloaded)}
        } else {
            prefab_base_set(s,key,loaded_scene)
        }
    }
    error=prefab_finish(&edit,target==.Base?"Apply prefab overrides to base":"Apply prefab overrides")
    return
}

// Writes overrides of an instance placed in a scene into its prefab: first the entities it added, which the
// values of members may name, then names, values and components.
@(private)
prefab_overrides_write :: proc(cap:^asset.Scene,instance:u32,selected:[]asset.Override,prefab:^asset.Scene) -> Prefab_Error {
    for override in selected {
        if override.kind!=.Child {continue}
        prefab_place_error(asset.scene_child_apply(cap,instance,override.entity,prefab)) or_return
    }
    inverse:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for member in cap.members {
        if member.instance==instance {inverse[member.entity]=member.source}
    }
    pairs:=prefab_pairs(cap,prefab) or_return
    for &override in selected {
        if override.kind>=.Child {continue}
        entity:=override.entity
        source:=inverse[entity]
        if source==0 {return .Not_Instance}
        if override.component==0 {
            row,exists:=asset.scene_entity_find(cap,entity)
            if !exists {return .Unknown_Entity}
            asset.scene_entity_rename(prefab,source,string(serial.text_field(asset.scene_names(cap)[row][:])))
            continue
        }
        for &pair in pairs {
            if pair.hash!=override.component || pair.cap_table<0 && override.kind!=.Removed {continue}
            switch override.kind {
            case .Removed:
                if pair.base_table>=0 {asset.scene_component_remove(prefab,pair.base_table,source)}
            case .Added:
                if pair.base_table<0 {
                    bt,add_error:=asset.scene_component_add(prefab,pair.name,&cap.doc.schema,cap.doc.tables[pair.cap_table].columns[1].type)
                    if add_error!=.None {return .Out_Of_Memory if add_error==.Out_Of_Memory else .Rejected}
                    pair.base_table=bt
                }
                prefab_value_apply(&pair,cap,prefab,entity,source,"",inverse) or_return
                fallthrough
            case .Turned:
                if pair.base_table<0 {continue}
                if asset.scene_component_turn(prefab,source,pair.hash,asset.scene_component_off(cap,entity,pair.hash))!=.None {return .Out_Of_Memory}
            case .Field:
                if pair.base_table<0 {continue}
                prefab_value_apply(&pair,cap,prefab,entity,source,prefab_override_text(&override),inverse) or_return
            case .Child:
            }
        }
    }
    return .None
}

// Marks again the overrides of the instances placed in a prefab against their prefabs as they are now, as
// the observation of an open document does: what an apply wrote on their members stays the prefab's own
// when the prefab they place changes.
@(private)
prefab_scene_mark :: proc(s:^Session,sc:^asset.Scene) -> Prefab_Error {
    fresh:=make([dynamic]asset.Override,context.temp_allocator)
    marked:=make(map[u32]bool,context.temp_allocator)
    for instance in sc.instances {
        if instance.outer!=0 {continue}
        inner,loaded:=prefab_scene_load(s,instance.prefab)
        if !loaded {continue}
        defer prefab_scene_free(inner)
        pairs:=prefab_pairs(sc,inner) or_return
        remap:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
        inside:=make(map[base.Entity_Id]bool,context.temp_allocator)
        for member in sc.members {
            if member.instance==instance.id {remap[member.source],inside[member.entity]=member.entity,true}
        }
        for member in sc.members {
            if member.instance==instance.id {prefab_member_observe(&fresh,instance,member.entity,member.source,sc,inner,pairs,remap)}
        }
        for entity,row in asset.scene_ids(sc) {
            if !inside[entity] && inside[asset.scene_parents(sc)[row]] {append(&fresh,prefab_override_make(instance.id,entity,0,.Child,""))}
        }
        marked[instance.id]=true
    }
    left:=0
    for override in sc.overrides {
        if marked[override.instance] {continue}
        sc.overrides[left]=override
        left+=1
    }
    resize(&sc.overrides,left)
    append(&sc.overrides,..fresh[:])
    return .None
}

// The overrides of the instance at the root of a variant that stand for overrides of an instance of the
// variant just written into it: of the same members and parts, and the entities it added. What the instance
// changed of an entity the variant added is the variant's alone.
@(private)
prefab_variant_overrides :: proc(cap:^asset.Scene,instance:u32,selected:[]asset.Override,variant:^asset.Scene,based:u32) -> []asset.Override {
    sources:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for member in cap.members {
        if member.instance==instance {sources[member.entity]=member.source}
    }
    chosen:=make([dynamic]asset.Override,context.temp_allocator)
    for &override in variant.overrides {
        if override.instance!=based {continue}
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

// Copies the value of the part of a component an override names from the scene into the prefab.
@(private)
prefab_value_apply :: proc(pair:^Prefab_Pair,cap,prefab:^asset.Scene,entity,source:base.Entity_Id,path:string,inverse:map[base.Entity_Id]base.Entity_Id) -> Prefab_Error {
    if pair.cap_table<0 || pair.base_table<0 {return .Rejected}
    cap_type:=cap.doc.tables[pair.cap_table].columns[1].type
    base_type:=prefab.doc.tables[pair.base_table].columns[1].type
    cap_image,has:=asset.scene_component_get(cap,pair.cap_table,entity)
    if !has {return .Rejected}
    // The value in the layout of the prefab, its references pointing at the entities of the prefab.
    size:=prefab.doc.tables[pair.base_table].columns[1].size
    buffer,allocation_error:=make([]u8,max(size,1),context.temp_allocator)
    if allocation_error!=nil {return .Out_Of_Memory}
    converted:=buffer[:size] // a tag has no bytes
    migration:serial.Migration
    defer serial.migration_destroy(&migration)
    if error:=serial.migration_init(&migration,&cap.doc.schema,cap_type,&prefab.doc.schema,base_type,context.temp_allocator);error!=.None {
        return .Out_Of_Memory if error==.Out_Of_Memory else .Rejected
    }
    serial.migration_apply(&migration,converted,cap_image,1)
    refs:[dynamic]serial.Ref
    refs.allocator=context.temp_allocator
    if !serial.refs_collect(&prefab.doc.schema,base_type,&refs) {return .Out_Of_Memory}
    for ref in refs {
        if ref.kind==.Asset {continue}
        target:=(^u64)(&converted[ref.offset])
        if target^!=0 {target^=u64(inverse[base.Entity_Id(target^)])}
    }
    current,exists:=asset.scene_component_get(prefab,pair.base_table,source)
    if path=="" || !exists {
        if error:=asset.scene_component_set(prefab,pair.base_table,source,converted);error!=.None {
            return .Out_Of_Memory if error==.Out_Of_Memory else .Rejected
        }
        return .None
    }
    merged,merge_error:=make([]u8,len(current),context.temp_allocator)
    if merge_error!=nil {return .Out_Of_Memory}
    copy(merged,current)
    _,to,to_error:=serial.value_slice(&prefab.doc.schema,base_type,merged,path)
    _,from,from_error:=serial.value_slice(&prefab.doc.schema,base_type,converted,path)
    if to_error==.None && from_error==.None && len(to)==len(from) {
        copy(to,from)
        if error:=asset.scene_component_set(prefab,pair.base_table,source,merged);error!=.None {
            return .Out_Of_Memory if error==.Out_Of_Memory else .Rejected
        }
        return .None
    }
    return .Unknown_Path
}

// The prefabs of the registry that place a prefab that changed are updated from it and written, outwards.
@(private)
prefab_propagate :: proc(s:^Session,changed_id:base.Asset_Id,changed:^asset.Scene,done:^map[base.Asset_Id]^asset.Scene,files:^[dynamic]Prefab_File,depth:=0) {
    a:=s.app.assets
    if depth>PREFAB_CYCLE_DEPTH {return}
    for &file in a.registry.files {
        if file.state!=.Asset || file.kind!=asset.KIND_PREFAB || file.id in done^ {continue}
        outer,loaded:=prefab_scene_load(s,file.id)
        if !loaded {continue}
        touched:=false
        placed:=make([dynamic]u32,context.temp_allocator)
        for instance in outer.instances {
            if instance.prefab==changed_id && instance.outer==0 {append(&placed,instance.id)}
        }
        for instance in placed {
            if asset.scene_instance_update(outer,instance,changed)==.None {touched=true}
        }
        if !touched {
            prefab_scene_free(outer)
            continue
        }
        path:=asset.registry_file_path(&a.registry,file.path,context.temp_allocator)
        if !prefab_file_save(outer,path,files) {
            prefab_scene_free(outer)
            continue
        }
        done^[file.id]=outer
        prefab_propagate(s,file.id,outer,done,files,depth+1)
    }
}

// ---------------------------------------------------------------- placing and copying

// A prefab of the assets placed in the scene as an instance linked to it. The root of the instance is returned.
prefab_place_linked :: proc(s:^Session,prefab_id:base.Asset_Id,point:[3]f32) -> core.Entity {
    root,error:=prefab_instantiate(s,prefab_id,{position=point})
    if error!=.None {
        notify(s,fmt.tprintf("The prefab could not be placed: %s",prefab_error_text(error)))
        return core.NONE
    }
    return api_entity(edited_world(s),root)
}

// Called when entities were copied: the instances whose root was copied are registered again in the
// copy, with their members and overrides. sources and copies are parallel.
prefab_copied :: proc(s:^Session,w:core.World_Ref,sources,copies:[]core.Entity) {
    previous:=s.document.previous
    if w.data!=s.edit_world || previous==nil || len(previous.instances)==0 {return}
    mapped:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for source,i in sources {
        from,to:=api_entity_id(w,source),api_entity_id(w,copies[i])
        if from!=0 && to!=0 {mapped[from]=to}
    }
    p:=prefabs_of(s)
    before:=prefab_records_take(previous)
    wanted:=make([dynamic]asset.Instance,context.temp_allocator)
    for instance in previous.instances {
        if instance.root in mapped {append(&wanted,instance)}
    }
    if len(wanted)==0 {
        prefab_records_free(&before)
        return
    }
    slice.sort_by(wanted[:],proc(a,b:asset.Instance) -> bool {return a.id<b.id})
    renumber:=make(map[u32]u32,context.temp_allocator)
    for instance in wanted {
        previous.info.last_instance+=1
        renumber[instance.id]=previous.info.last_instance
        outer:=u32(0)
        if instance.outer!=0 {outer=renumber[instance.outer]}
        append(&previous.instances,asset.Instance{id=previous.info.last_instance,prefab=instance.prefab,root=mapped[instance.root],outer=outer})
    }
    for member in slice.clone(previous.members[:],context.temp_allocator) {
        if member.instance in renumber && member.entity in mapped {
            append(&previous.members,asset.Member{instance=renumber[member.instance],source=member.source,entity=mapped[member.entity]})
        }
    }
    for override in slice.clone(previous.overrides[:],context.temp_allocator) {
        if override.instance in renumber && override.entity in mapped {
            copied:=override
            copied.instance,copied.entity=renumber[override.instance],mapped[override.entity]
            append(&previous.overrides,copied)
        }
    }
    if p.has_pending {
        prefab_records_free(&before)
    } else {
        p.pending=before
        p.pending_state=edits_scene_state(s.edits)
        p.has_pending=true
    }
}

// ---------------------------------------------------------------- actions of the editor

// The entity the prefab actions work on: the active one, when it is alone in what is selected or last.
@(private)
prefab_target :: proc(s:^Session) -> core.Entity {
    return selection_active(s.selection)
}

// Whether a prefab action cannot run now.
@(private)
prefab_action_disabled :: proc(s:^Session,action:Action) -> bool {
    if s.mode!=.Edit || s.app.assets==nil {return true}
    if action==.Prefab_Create {
        roots:=selection_roots(s.selection,edited_world(s))
        if len(roots)==0 {return true}
        for e in roots {
            if prefab_member_locked(s,edited_world(s),e) || api_entity_id(edited_world(s),e)==0 {return true}
        }
        return false
    }
    if len(s.selection.entities)!=1 {return true}
    e:=prefab_target(s)
    if e==core.NONE {return true}
    w:=edited_world(s)
    id:=api_entity_id(w,e)
    if id==0 {return true}
    link,linked:=prefab_link_of(s,id)
    #partial switch action {
    case .Prefab_Apply,.Prefab_Revert,.Prefab_Apply_Base:
        // A member with overrides, or an entity an instance added; to a base, the root of an instance of a variant.
        if s.document.previous==nil || action==.Prefab_Apply_Base && (!link.root || prefab_placed_base(s,link.asset)=={}) {return true}
        for &override in s.document.previous.overrides {
            if !linked {
                if override.kind==.Child && override.entity==id {return false}
                continue
            }
            if (link.root || override.entity==id) && override.instance==link.instance && !(link.root && prefab_placement(&override,id)) {return false}
        }
        return true
    case .Prefab_Unlink: return !linked
    }
    return true
}

// A name for the prefab of an entity that no file of the assets has.
@(private)
prefab_name_free :: proc(s:^Session,e:core.Entity) -> string {
    stem:=strings.trim_space(entity_name(edited_world(s),e))
    if stem=="" {stem="Prefab"}
    cleaned:=make([]u8,len(stem),context.temp_allocator)
    for c,i in transmute([]u8)stem {
        cleaned[i]=(c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='_' || c=='-')?c:'_'
    }
    for n in 1..<10000 {
        path:=n==1?fmt.tprintf("prefabs/%s",string(cleaned)):fmt.tprintf("prefabs/%s_%d",string(cleaned),n)
        if !os.exists(scene_file(s,strings.concatenate({path,PREFAB_EXTENSION},context.temp_allocator))) {return path}
    }
    return "prefabs/Prefab"
}

@(private)
prefab_action_run :: proc(s:^Session,action:Action) {
    e:=prefab_target(s)
    error:=Prefab_Error.None
    message:string
    #partial switch action {
    case .Prefab_Create:
        path:=prefab_name_free(s,e)
        _,error=prefab_create_entities(s,s.selection.entities[:],path)
        message=fmt.tprintf("Prefab %s created",path)
    case .Prefab_Apply:
        count:int
        link,_:=prefab_link_of(s,api_entity_id(edited_world(s),e))
        count,error=prefab_apply(s,e,nil,link.root)
        message=fmt.tprintf("%d overrides applied",count)
    case .Prefab_Apply_Base:
        count:int
        count,error=prefab_apply(s,e,nil,true,.Base)
        message=fmt.tprintf("%d overrides applied to the base",count)
    case .Prefab_Revert:
        count:int
        link,_:=prefab_link_of(s,api_entity_id(edited_world(s),e))
        count,error=prefab_revert(s,e,nil,link.root)
        message=fmt.tprintf("%d overrides reverted",count)
    case .Prefab_Unlink:
        error=prefab_unlink(s,e,false)
        message="Prefab unlinked"
    }
    if error!=.None {message=fmt.tprintf("%s",prefab_error_text(error))}
    notify(s,message)
}
