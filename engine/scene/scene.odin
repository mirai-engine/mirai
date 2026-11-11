package scene

import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Scenes between their document and a world: loaded whole, hung under a
// Scene_Reference or, with exactly one root (a prefab), placed as a copy.
//
// A document names entities by Entity_Id and components by the name of their
// type; a world names them by handle and by its tables. Instantiating creates
// one entity per row of the document; capturing writes a document from the
// entities that have an Id. What a world cannot hold (the order of its
// roots, components of libraries the project does not have and tables that
// are not components) is carried from the document the world was loaded
// from.

Error :: enum u8 {
    None,
    No_Assets,    // the application has no assets folder
    Not_Found,    // no scene with that id or path
    Invalid,      // not a scene, or a parent that is not alive
    Cycle,        // a scene that references itself, or references nested past REFERENCE_DEPTH
    Not_A_Prefab, // spawn: the scene is not a prefab, the kind a copy is placed from by its one root
    Corrupt,      // the document contradicts itself
    Duplicate_Id, // capture: two entities have the same Id
    Out_Of_Memory,
    Write_Failed,
    Too_Large,         // load_untrusted: more bytes or entities than its rules let it have
    Not_Allowed,       // load_untrusted: a component its rules do not list, or a reference to a scene the game did not ship
    Out_Of_Range,      // load_untrusted: a value its field does not allow
    Unknown_Reference, // load_untrusted: an entity or an asset it names that is not there
}

Instantiate_Desc :: struct {
    parent:core.Entity,   // of the roots of the document; none: they are roots of the world
    transient:bool,       // entities get no Id: a copy spawned while playing, which a capture leaves out
    fresh:bool,           // entities get new Ids from the world (core.id_next), not those of the document: another copy of it that stays
    entities:[]core.Entity, // when given, receives the entity of every row of the document
    documents:Documents,    // the scenes the document references, loaded under their references; none: they stay empty
    salt:base.Entity_Id,    // the Id of the reference the document hangs from: its Ids are combined with it (id_in)
    path:[]base.Asset_Id,   // the scenes that reference this one, outermost first
    saved:bool,             // a saved game: what hangs from its references came with it, loaded as it was
    only:base.Entity_Id,    // when given, only the entity whose Id in the world (id_in with salt) is this and what hangs from it, a root; its references stay unloaded
    root:core.Entity,       // when given, the entity of the first root of the document, which keeps what it has: a spawned copy
    stored:^[dynamic]Stored, // when given, receives each component the document and the scenes it loads store otherwise than the world reads them
}

Capture_Desc :: struct {
    root:core.Entity,      // only this entity and what is under it, the one root of its scene: a prefab; none: every root with an Id
    previous:^asset.Scene, // the document the world came from, whose kind (Header_Flag.Prefab) the capture keeps
    id:base.Asset_Id,      // zero: the id of previous
    entities:[]core.Entity, // when given, only these, as roots without what is under them; their Entity fields keep the Id of an entity left out
    sections:bool,          // also what hangs from a Scene_Reference, which its own scene keeps otherwise: a saved game
    section:core.Entity,    // only what hangs from this Scene_Reference, as its own scene, with the Ids of that scene
    excluded:[]typeid,      // components left out: what a network session keeps on entities, which a saved game does not
    outside:bool,           // with root: its Entity fields keep the Id of an entity outside it, which are empty otherwise
}

Report :: struct {
    root:core.Entity, // instantiate: the first root of the document, the only one of a prefab
    entities:int,
    components:int,   // values attached or saved, Id, Name and Parent aside
    dangling:int,     // entity references that named nothing inside: set to none
    sections:int,     // instantiate: referenced scenes loaded under their references
    missing:int,      // instantiate: references whose scene is not in the assets
    refused:Refusal,  // load_untrusted: what made it fail
}

// A prefab, a scene with one root, to place while the world runs.
Spawn :: struct {
    prefab:base.Asset_Id,
    parent:core.Entity,
    transform:core.Transform, // of the root; a zero scale counts as 1, a zero rotation as none
    transient:bool,
}

@(private) NONE_ROW :: u32(0xffffffff)

// What placing a prefab needs, for a step to receive in one parameter.
@(params)
Spawner :: struct {
    commands:core.Commands,
    assets:^host.Assets,
    problems:^core.Problems,
}

// Places a copy of a prefab, a scene of the assets with one root, by its path
// ("pets/Dog.scene") or its id, and gives back its root, whose rows wait for
// the end of the function. NONE when it did not spawn, which is the problem
// scene.spawn that says why. A prefab that is not loaded, or that takes
// something that is not, is read in jobs: its root comes at once with its
// Transform, Parent, Id and Prefab_Pending, and nothing else, and takes the
// rest of the prefab once it is read (scene_spawns); what was given to it
// meanwhile stays, and its own value of a component wins over the prefab's.
spawn :: proc{spawn_path,spawn_id}

spawn_path :: proc(s:Spawner,path:string,at:core.Transform={},parent:=core.NONE,transient:=false) -> core.Entity {
    prefab:base.Asset_Id
    error:=Error.No_Assets
    if s.assets!=nil {
        error=.Not_Found
        if named,found:=asset.registry_find_path(&s.assets.registry,path);found {prefab=named.id;error=.None}
    }
    return spawn_report(s,{prefab=prefab,parent=parent,transform=at,transient=transient},path,error)
}

spawn_id :: proc(s:Spawner,prefab:base.Asset_Id,at:core.Transform={},parent:=core.NONE,transient:=false) -> core.Entity {
    name:[base.ASSET_ID_TEXT]u8
    return spawn_report(s,{prefab=prefab,parent=parent,transform=at,transient=transient},host.assets_name(s.assets,prefab,&name),.None)
}

@(private)
spawn_report :: proc(s:Spawner,order:Spawn,name:string,found:Error) -> core.Entity {
    report,error:=Report{},found
    if error==.None {report,error=spawn_prefab(s.commands,s.assets,order)}
    if error==.None {return report.root}
    fix:string
    #partial switch error {
    case .No_Assets:     fix="run the game from a project with an assets folder"
    case .Not_Found:     fix="name a .scene of the assets by its path or id: import or create it, or fix the name"
    case .Invalid:       fix="spawn a .scene under a parent that is alive, or with no parent"
    case .Not_A_Prefab:  fix="make it a prefab in the editor (File > Prefab), with its entities under one root, or place it whole with a Scene_Reference (scene.section_request)"
    case .Corrupt:       fix="open the scene in the editor and save it again"
    case .Out_Of_Memory: fix="free memory or spawn fewer scenes at once"
    }
    core.report(s.problems,order.parent,"scene.spawn","scene %s did not spawn: %s; %s",name,error_text(error),fix)
    return core.NONE
}

error_text :: proc(error:Error) -> string {
    switch error {
    case .None:          return ""
    case .No_Assets:     return "the application has no assets folder"
    case .Not_Found:     return "no scene has that path or id"
    case .Invalid:       return "not a scene, or a parent that is not alive"
    case .Cycle:         return "a scene references itself"
    case .Not_A_Prefab:  return "it is not a prefab, and only a prefab is placed as a copy"
    case .Corrupt:       return "the document contradicts itself"
    case .Duplicate_Id:  return "two entities have the same Id"
    case .Out_Of_Memory: return "out of memory"
    case .Write_Failed:  return "the file could not be written"
    case .Too_Large:     return "it is larger than it may be"
    case .Not_Allowed:   return "it holds what it may not"
    case .Out_Of_Range:  return "a value is not one its field allows"
    case .Unknown_Reference: return "it names an entity or an asset that is not there"
    }
    return ""
}

// Replaces what the world holds with a scene of the assets, by path or id,
// all of it or nothing (replace).
load :: proc{load_path,load_id}

// A path of the assets, or the absolute path of a scene file outside them:
// the copy of the scene a network game of the editor runs.
load_path :: proc(w:core.World_Ref,app:^host.App,path:string) -> (report:Report,error:Error) {
    if app.assets==nil {return {},.No_Assets}
    host.assets_scan(app.assets)
    if file,found:=asset.registry_find_path(&app.assets.registry,path);found {return load_id(w,app,file.id)}
    if !filepath.is_abs(path) || !os.is_file(path) {return {},.Not_Found}
    source:asset.Asset
    if asset.asset_load(&source,path)!=.None {return {},.Invalid}
    defer asset.asset_close(&source)
    view,view_error:=asset.scene_view(&source,&app.assets.types)
    if view_error!=.None {return {},.Corrupt}
    if checked:=asset.scene_view_check(view,context.temp_allocator);checked!=.None {return {},.Out_Of_Memory if checked==.Out_Of_Memory else .Corrupt}
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=current(assets_documents(app.assets),&source,&resolved) or_return
    return replace(w,app,document,&app.assets.types)
}

load_id :: proc(w:core.World_Ref,app:^host.App,id:base.Asset_Id) -> (report:Report,error:Error) {
    if app.assets==nil {return {},.No_Assets}
    file:=host.assets_scene(app.assets,id)
    if file==nil {return {},.Not_Found}
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=current(assets_documents(app.assets),file,&resolved) or_return
    return replace(w,app,document,&app.assets.types)
}

// Replaces what a World of the application holds with the entities of a
// document, all of it or nothing: the document is instantiated in another
// World made a copy of this one and cleared, so it keeps what clearing keeps,
// and that World then trades its contents with this one. A document that
// fails halfway, or memory that runs out, leaves the world as it was.
// entities, when given, receives the entity of every row of the document, as
// the world has it once replaced. Without references the scenes the document
// references are not loaded: a saved game, which keeps them as they were.
// stored, when given, receives what Instantiate_Desc.stored does.
replace :: proc(w:core.World_Ref,app:^host.App,a:^asset.Asset,asset_types:^asset.Types,entities:[]core.Entity=nil,references:=true,stored:^[dynamic]Stored=nil) -> (report:Report,error:Error) {
    if app.info==nil || w.info!=app.info || w.place!=.World {return {},.Invalid}
    making:=host.load_phase_begin(app,.Instantiate)
    data:=host.app_world_create(app)
    if data==nil {
        host.load_phase_end(app,making)
        return {},.Out_Of_Memory
    }
    defer host.app_world_free(app,data)
    candidate:=host.app_world_ref(app,data)
    if !core.world_copy(w.info,data,w.data) {
        host.load_phase_end(app,making)
        return {},.Out_Of_Memory
    }
    if !core.world_clear(w.info,data) {
        host.load_phase_end(app,making)
        return {},.Out_Of_Memory
    }
    report,error=instantiate(candidate,a,asset_types,{entities=entities,documents=references?assets_documents(app.assets):{},saved=!references,stored=stored})
    host.load_phase_end(app,making,core.world_entities(candidate).alive)
    settling:=host.load_phase_begin(app,.Settle)
    defer host.load_phase_end(app,settling)
    core.world_settle(candidate)
    if error!=.None {return}
    root_set(candidate,a.blob.header.id)
    references_resolve(candidate)
    propagate(candidate,app)
    prefabs_warm(candidate,app)
    core.world_swap(w.info,w.data,data)
    // A look without memory for it stays asked for: scene_sections looks again, and reports it.
    _=records_look(w)
    return
}

// The prefabs the fields of a World that was just loaded name, and what they
// take, read now, as a load in phases reads them in jobs: their first spawn
// is whole in its call.
@(private)
prefabs_warm :: proc(w:core.World_Ref,app:^host.App) {
    names:=make([dynamic]base.Asset_Id,context.temp_allocator)
    host.world_asset_ids(w,&names)
    prefabs:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for id in names {
        if file,found:=asset.registry_find(&app.assets.registry,id);found && asset.registry_prefab(file) {append(&prefabs,id)}
    }
    if len(prefabs)==0 {return}
    if job,begun:=prefab_warm_begin(app,prefabs[:]);begun==.None {
        load_step(job,true)
        load_free(job)
    }
}

// The world transforms of a World that was just loaded, now: the propagation
// of core as the loop runs it, for what reads them before the loop does.
propagate :: proc(w:core.World_Ref,app:^host.App) {
    if app==nil {return}
    time:core.Time
    if clock:=core.world_storage_of(w,core.Time);clock!=nil {time=clock^}
    core.world_run(w,app.shared,nil,app,.Game,.Late,{"core"},time)
}

// What spawn runs, for the editor method that answers with the report and the
// error: games and plugins call spawn. Its entities exist at once and their
// rows wait for the end of the function: whoever spawned it reads and finishes
// them with core.added. A prefab that waits for jobs gives its root alone
// (spawn).
spawn_prefab :: proc(c:core.Commands,assets:^host.Assets,s:Spawn) -> (report:Report,error:Error) {
    return spawn_placed(c,assets,s,core.world_storage_of(core.world_ref(c.data,c.info),Prefab_Forms))
}

// spawn_prefab with the forms the prefab is prepared in; none: it is made now.
@(private)
spawn_placed :: proc(c:core.Commands,assets:^host.Assets,s:Spawn,forms:^Prefab_Forms) -> (report:Report,error:Error) {
    if assets==nil {return {},.No_Assets}
    file,found:=asset.registry_find(&assets.registry,s.prefab)
    if !found || file.state!=.Asset || file.kind!=asset.KIND_SCENE {return {},.Not_Found}
    if !asset.registry_prefab(file) {return {},.Not_A_Prefab}
    if s.parent!=core.NONE && !core.alive(c.entities,s.parent) {return {},.Invalid}
    w:=core.world_ref(c.data,c.info)
    form,entities,loaded:=prefab_form(forms,w,assets,s.prefab) or_return
    root:=core.create(c)
    transform:=s.transform
    if transform.rotation==0 {transform.rotation=1}
    if transform.scale=={} {transform.scale={1,1,1}}
    core.commands_add(c,root,transform)
    if s.parent!=core.NONE {core.commands_add(c,root,core.Parent{s.parent,0})}
    if !s.transient {core.commands_add(c,root,core.Id{core.id_next(c.entities)})}
    core.commands_add(c,root,Prefab_Instance{prefab=s.prefab}) // no stamp, no members: of its prefab, linked to no document
    if !loaded {
        core.commands_add(c,root,Prefab_Pending{prefab=s.prefab})
        return {root=root,entities=1},.None
    }
    report,error=form_place(w,form,&assets.types,{transient=s.transient,fresh=!s.transient,documents=assets_documents(assets),root=root},entities)
    if error!=.None {core.destroy(c,root)}
    return
}

// A copy of an entity of the scene of a section, by its Id in the world, and
// of what hangs from it, as a root of the world without Ids (Spawn.transient):
// what stands for it where its section is not loaded. salt is the Id of the
// reference of the section. Like spawn it reads no file: a scene that is not
// loaded, or that takes something that is not, gives the root at once with
// its Transform and Prefab_Pending, filled once jobs read them.
spawn_member :: proc(c:core.Commands,assets:^host.Assets,section_scene:base.Asset_Id,salt,id:base.Entity_Id,transform:core.Transform) -> (report:Report,error:Error) {
    if assets==nil {return {},.No_Assets}
    if file,found:=asset.registry_find(&assets.registry,section_scene);!found || file.state!=.Asset || file.kind!=asset.KIND_SCENE {return {},.Not_Found}
    root:=core.create(c)
    core.commands_add(c,root,transform)
    pending:=Prefab_Pending{prefab=section_scene,salt=salt,member=id}
    if !prefab_loaded(assets,section_scene,documents=true) {
        core.commands_add(c,root,pending)
        return {root=root,entities=1},.None
    }
    report,error=member_place(core.world_ref(c.data,c.info),assets,pending,root)
    if error!=.None {core.destroy(c,root)}
    return
}

// Places on root the entity of a section a pending copy stands for, with
// what hangs from it.
@(private)
member_place :: proc(w:core.World_Ref,assets:^host.Assets,pending:Prefab_Pending,root:core.Entity) -> (report:Report,error:Error) {
    file:=host.assets_scene(assets,pending.prefab)
    if file==nil {return {},.Not_Found}
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=current(assets_documents(assets),file,&resolved) or_return
    return instantiate(w,document,&assets.types,{transient=true,salt=pending.salt,only=pending.member,root=root})
}

// The document a load or a spawn instantiates. With the assets of a project
// it is a copy of the file whose stale prefab instances follow their prefabs
// now, when it has one; the file otherwise, and always in a shipped game,
// whose cook resolved them.
@(private)
current :: proc(d:Documents,file:^asset.Asset,resolved:^asset.Asset,sources:^Form_Sources=nil) -> (document:^asset.Asset,error:Error) {
    if _,placed:=asset.asset_table(file,asset.COMPONENT_INSTANCE);!placed || d.cooked || d.open==nil {return file,.None}
    d:=d
    open :: proc(data:rawptr,id:base.Asset_Id) -> (^asset.Asset,asset.Error) {
        d:=(^Documents)(data)
        return d.open(d.user,id),.None
    }
    r:asset.Prefab_Resolver
    asset.resolver_init(&r,d.types,{&d,open},context.temp_allocator)
    defer asset.resolver_destroy(&r)
    // What it is resolved from: every prefab the resolution looked at.
    defer if sources!=nil {
        sources.unsure=r.error!=.None
        for id in r.prefabs {
            looked:=d.open(d.user,id)
            append(&sources.items,Form_Source{id,looked!=nil?looked.blob.header.content_hash:0})
        }
    }
    if !asset.resolver_stale(&r,file) {return file,.None}
    copied:asset.Scene
    if asset.scene_from_asset(&copied,d.types,file)!=.None {return nil,.Corrupt}
    defer asset.scene_destroy(&copied)
    if _,resolve_error:=asset.scene_resolve(&r,&copied);resolve_error!=.None {return nil,resolve_error==.Out_Of_Memory?.Out_Of_Memory:.Corrupt}
    data,write_error:=asset.scene_bytes(&copied)
    if write_error!=.None {return nil,write_error==.Out_Of_Memory?.Out_Of_Memory:.Corrupt}
    if asset.asset_take(resolved,data)!=.None {return nil,.Corrupt}
    return resolved,.None
}

// What reads and writes the values of a world: the schema of its World_Info,
// or one made for this call when it has none. nil without memory.
schema_of :: proc(w:core.World_Ref) -> ^core.World_Schema {
    if w.info.schema!=nil {return w.info.schema}
    return core.world_schema_make(w.info,context.temp_allocator)
}

@(private)
Key :: struct {id:base.Entity_Id,row:u32}

@(private)
key_find :: proc(keys:[]Key,id:base.Entity_Id) -> (row:u32,found:bool) {
    low,high:=0,len(keys)
    for low<high {
        middle:=(low+high)/2
        if keys[middle].id<id {low=middle+1} else {high=middle}
    }
    if low<len(keys) && keys[low].id==id {return keys[low].row,true}
    return NONE_ROW,false
}

// The tables instantiating writes itself, and World_Transform, which only the
// propagation writes.
@(private)
is_structural :: proc(type:typeid) -> bool {
    return type==core.Parent || type==core.Id || type==core.Name || type==core.World_Transform
}

// Creates the entities of a scene in a world. Every entity gets
// Id, Name and Transform; each table the world has a component for is read
// into it, migrating by field names when the layouts differ, and its Entity
// fields become handles. Children keep the order of the document. The rows
// appear at the next settle, and the world transforms at the next
// propagation: what needs a pose before composes it with core.world_of.
instantiate :: proc(w:core.World_Ref,a:^asset.Asset,asset_types:^asset.Types,desc:Instantiate_Desc={}) -> (report:Report,error:Error) {
    if desc.parent!=core.NONE && !core.alive(core.world_entities(w),desc.parent) {return {},.Invalid}
    form,_:=form_make(w,a,asset_types,context.temp_allocator) or_return
    if desc.stored!=nil && !stored_collect(w,a,asset_types,desc.stored) {return {},.Out_Of_Memory}
    count:=len(form.ids)
    if desc.entities!=nil && len(desc.entities)<count {return {},.Invalid}
    entities:=desc.entities
    if entities==nil {
        no_entities:mem.Allocator_Error
        if entities,no_entities=make([]core.Entity,count,context.temp_allocator);no_entities!=nil {return {},.Out_Of_Memory}
    }
    return form_place(w,&form,asset_types,desc,entities[:count])
}

// Where the documents instantiate reads come from: the assets of the
// application, or what a load read before in a job.
Documents :: struct {
    user:rawptr,
    open:proc(user:rawptr,id:base.Asset_Id) -> ^asset.Asset, // nil when it cannot be read
    types:^asset.Types,
    cooked:bool, // the assets were cooked: files are loaded as they are, their prefab instances resolved
}

assets_documents :: proc(a:^host.Assets) -> Documents {
    if a==nil {return {}}
    open :: proc(user:rawptr,id:base.Asset_Id) -> ^asset.Asset {return host.assets_scene((^host.Assets)(user),id)}
    return {a,open,&a.types,a.indexed}
}

// The scenes the references of a document name, each under its reference.
@(private)
sections_load :: proc(w:core.World_Ref,scene:base.Asset_Id,asset_types:^asset.Types,desc:Instantiate_Desc,sections:[]Form_Section,report:^Report) -> Error {
    if desc.documents.open==nil {return .None}
    if len(desc.path)>=REFERENCE_DEPTH {return .Cycle}
    path:=make([]base.Asset_Id,len(desc.path)+1,context.temp_allocator)
    copy(path,desc.path)
    path[len(desc.path)]=scene
    for section in sections {
        if slice.contains(path,section.reference.scene) {return .Cycle}
        file:=desc.documents.open(desc.documents.user,section.reference.scene)
        if file==nil {
            report.missing+=1
            continue
        }
        resolved:asset.Asset
        defer asset.asset_close(&resolved)
        document:=current(desc.documents,file,&resolved) or_return
        inner,error:=instantiate(w,document,asset_types,{parent=section.entity,transient=desc.transient,documents=desc.documents,salt=section.id,path=path,stored=desc.stored})
        report.entities+=inner.entities
        report.components+=inner.components
        report.dangling+=inner.dangling
        report.sections+=1+inner.sections
        report.missing+=inner.missing
        if error!=.None {return error}
    }
    return .None
}

// Reads the values of a component of a document as the world has them, into
// values: a field the document does not keep starts as the component starts,
// at its default.
@(private)
component_read :: proc(a:^asset.Asset,component:^asset.Scene_Component,types:^core.World_Schema,info:^core.Table_Info,value_type:^core.Value_Schema,values:[]u8) -> bool {
    default:=read_default(info) or_return
    return asset.scene_component_read(a,component,&types.schema,value_type.type,values,default)==.None
}

// What a field of a component that a document does not keep reads as, as one value of the component in
// memory: its default, the identity for a transform, and zero for the rest, which is nil.
read_default :: proc(info:^core.Table_Info,allocator:=context.temp_allocator) -> (default:[]u8,ok:bool) {
    if info.default==nil && info.type!=core.Transform {return nil,true}
    allocation:mem.Allocator_Error
    default,allocation=make([]u8,info.info.size,allocator)
    if allocation!=nil {return nil,false}
    if info.default!=nil {
        info.default(raw_data(default))
    } else {
        identity:=core.TRANSFORM_IDENTITY
        copy(default,mem.ptr_to_bytes(&identity))
    }
    return default,true
}

// Writes the document of a world into scene, which it initializes: the
// entities that have an Id, depth first, with their name, parent and order
// among their siblings; an entity without Id is left out with everything
// under it, and what hangs from a Scene_Reference, which its own scene keeps,
// unless desc.sections. Each component with something to save becomes a
// table: transient fields are zero and Entity fields hold the Id of the
// entity they name.
capture :: proc(w:core.World_Ref,scene:^asset.Scene,asset_types:^asset.Types,desc:Capture_Desc={},allocator:=context.allocator) -> (report:Report,error:Error) {
    id_table:=core.world_table_of(w,core.Id)
    parent_table:=core.world_table_of(w,core.Parent)
    hierarchy_storage:=core.world_storage_of(w,core.Hierarchy)
    if id_table==nil || parent_table==nil || hierarchy_storage==nil {return {},.Invalid}
    ids,parents:=id_table,parent_table
    names:=core.world_table_of(w,core.Name)
    previous:=desc.previous
    id:=desc.id
    if id=={} && previous!=nil {id=previous.doc.id}
    types:=schema_of(w)
    if types==nil {return {},.Out_Of_Memory}

    Root :: struct {entity:core.Entity,known:bool,order,tie:u32}
    roots:=make([dynamic]Root,context.temp_allocator)
    // The Id an entity has in the document: in a section, the one of its own scene.
    members:=core.world_table_of(w,Section_Member)
    doc_id :: proc(ids:^core.Table(core.Id,$A),members:^core.Table(Section_Member),section:core.Entity,e:core.Entity) -> base.Entity_Id {
        if section!=core.NONE && members!=nil {
            if member,ok:=core.get(members,e);ok && member.local!=0 {return member.local}
        }
        return core.id_of(ids,e)
    }
    if desc.section!=core.NONE {
        h:=core.ref(hierarchy_storage)
        order:=u32(0)
        for child:=core.first_child(h,desc.section);child!=core.NONE;child=core.next_sibling(h,child) {
            if core.id_of(ids,child)==0 {continue}
            append(&roots,Root{entity=child,order=order})
            order+=1
        }
    } else if desc.root!=core.NONE {
        if core.id_of(ids,desc.root)==0 {return {},.Invalid}
        append(&roots,Root{entity=desc.root})
    } else if desc.entities==nil {
        for row in 0..<core.count(ids) {
            e,identity:=core.entity_at(ids,row),core.at(ids,row).value
            if identity==0 || core.has(parents,e) {continue}
            root:=Root{entity=e,tie=u32(core.entity_index(e))}
            if previous!=nil {
                if found,ok:=asset.scene_entity_find(previous,identity);ok && asset.scene_parents(previous)[found]==0 {
                    root.known,root.order,root.tie=true,asset.scene_orders(previous)[found],u32(found)
                }
            }
            append(&roots,root)
        }
        slice.sort_by(roots[:],proc(a,b:Root) -> bool {
            if a.known!=b.known {return a.known}
            return a.order<b.order || a.order==b.order && a.tie<b.tie
        })
    }

    Visit :: struct {entity:core.Entity,parent,order:u32}
    placed:=make([dynamic]Visit,context.temp_allocator)
    row_of:=make(map[core.Entity]u32,context.temp_allocator)
    stack:=make([dynamic]Visit,context.temp_allocator)
    #reverse for root,at in roots {append(&stack,Visit{root.entity,NONE_ROW,u32(at)})}
    for e in desc.entities {
        if core.id_of(ids,e)==0 || e in row_of {continue}
        row_of[e]=u32(len(placed))
        append(&placed,Visit{e,NONE_ROW,u32(len(placed))})
    }
    hierarchy:=core.ref(hierarchy_storage)
    references:=core.world_table_of(w,Scene_Reference)
    for len(stack)>0 {
        visit:=pop(&stack)
        row:=u32(len(placed))
        append(&placed,visit)
        row_of[visit.entity]=row
        if !desc.sections && references!=nil && core.has(references,visit.entity) {continue}
        first,order:=len(stack),u32(0)
        for child:=core.first_child(hierarchy,visit.entity);child!=core.NONE;child=core.next_sibling(hierarchy,child) {
            if core.id_of(ids,child)==0 {continue}
            append(&stack,Visit{child,row,order})
            order+=1
        }
        slice.reverse(stack[first:])
    }

    if asset.scene_init(scene,asset_types,id,allocator)!=.None {return {},.Out_Of_Memory}
    if desc.previous!=nil {scene.doc.flags+=desc.previous.doc.flags&{.Prefab}}
    defer if error!=.None {
        asset.scene_destroy(scene)
        report={}
    }
    for visit in placed {
        label:=names!=nil?core.name_get(names,visit.entity):""
        parent:=visit.parent==NONE_ROW?0:asset.scene_ids(scene)[visit.parent]
        _,add_error:=asset.scene_entity_add(scene,doc_id(ids,members,desc.section,visit.entity),parent,label,int(visit.order))
        if add_error!=.None {return report,add_error==.Invalid?.Duplicate_Id:.Out_Of_Memory}
    }
    report.entities=len(placed)

    table_rows:=make([dynamic]u32,context.temp_allocator)
    images:=make([dynamic]u8,context.temp_allocator)
    pending:=unresolved_map(core.world_storage_of(w,Unresolved_References))
    for &info,at in w.info.tables {
        value_type:=&types.tables[at]
        if info.place!=w.place || is_structural(info.type) || info.derived || value_type.type==serial.TYPE_NONE {continue}
        if info.type==Section_Member && !desc.sections {continue}
        linked:=info.type==Prefab_Instance?core.world_table_of(w,Prefab_Member):nil // a spawned copy has none: no document holds it
        if slice.contains(desc.excluded,info.type) {continue}
        size:=info.info.size
        table:=core.world_table_at(w,&info)
        hash:=base.name_hash(info.name)
        clear(&table_rows);clear(&images)
        // resize asks for exactly what it is given, and this allocator frees
        // nothing: growing row by row would cost the square of the rows.
        if reserve(&images,core.raw_count(table)*size)!=nil {return report,.Out_Of_Memory}
        for visit,row in placed {
            value:=core.raw_find(table,info.info,visit.entity)
            if value==nil {continue}
            if info.type==Prefab_Instance && (linked==nil || core.raw_find(core.raw(linked),type_info_of(Prefab_Member),visit.entity)==nil) {continue}
            append(&table_rows,u32(row))
            if size==0 {continue}
            start:=len(images)
            if resize(&images,start+size)!=nil {return report,.Out_Of_Memory}
            image:=images[start:][:size]
            serial.value_write(&value_type.layout,image,value,1)
            for offset in value_type.entities {
                field:=cast(^u64)&image[offset]
                target:=core.Entity(intrinsics.unaligned_load(field))
                saved:=base.Entity_Id(0)
                if target!=core.NONE {
                    // Outside what is captured: an entity of a section keeps its Id in the world.
                    if target_row,inside:=row_of[target];inside {saved=asset.scene_ids(scene)[target_row]}
                    else if desc.root==core.NONE || desc.entities!=nil || desc.outside {saved=core.id_of(ids,target)}
                    if saved==0 {report.dangling+=1}
                } else {
                    saved=pending[{visit.entity,hash,offset}]
                }
                intrinsics.unaligned_store(field,u64(saved))
            }
        }
        if len(table_rows)==0 {continue}
        target,table_error:=asset.scene_component_add(scene,info.name,&types.schema,value_type.type)
        if table_error!=.None || asset.scene_component_fill(scene,target,table_rows[:],images[:])!=.None {return report,.Out_Of_Memory}
        if !table.base {
            for row in table_rows {
                if _,off,_:=core.raw_state(table,placed[row].entity);off && asset.scene_component_turn(scene,asset.scene_ids(scene)[row],hash,true)!=.None {return report,.Out_Of_Memory}
            }
        }
        report.components+=len(table_rows)
    }

    if previous!=nil {
        if carry(w,scene,previous,&report)!=.None {return report,.Out_Of_Memory}
    }
    return report,.None
}

// Captures the world and writes it to a file of the assets.
save :: proc(w:core.World_Ref,assets:^host.Assets,path:string,previous:^asset.Scene=nil,id:base.Asset_Id={}) -> (report:Report,error:Error) {
    if assets==nil {return {},.No_Assets}
    doc:asset.Scene
    report,error=capture(w,&doc,&assets.types,{previous=previous,id=id})
    if error!=.None {return}
    defer asset.scene_destroy(&doc)
    if asset.scene_save(&doc,path)!=.None {return report,.Write_Failed}
    return
}

// What a world cannot hold, from the document it was loaded from.
@(private)
carry :: proc(w:core.World_Ref,scene,previous:^asset.Scene,report:^Report) -> asset.Error {
    scene.info=previous.info
    scene.doc.flags=previous.doc.flags

    link:serial.Schema_Import
    asset.document_import_begin(&scene.doc,&link,&previous.doc.schema)
    defer serial.schema_import_destroy(&link)
    Moved :: struct {row,from:u32}
    moved:=make([dynamic]Moved,context.temp_allocator)
    table_rows:=make([dynamic]u32,context.temp_allocator)
    images:=make([dynamic]u8,context.temp_allocator)
    copies:=make([]int,len(previous.doc.tables),context.temp_allocator)
    slice.fill(copies,-1)
    copies[0]=0
    previous_ids:=asset.scene_ids(previous)
    for &table,at in previous.doc.tables {
        if at==0 {continue}
        if table.name==asset.TABLE_SCENE || table.name==asset.TABLE_OVERRIDES || table.name==asset.TABLE_OFF {continue}
        if _,is_component:=asset.scene_component(previous,table.name);is_component {
            if _,known:=core.world_table_index_of_hash(w,table.name_hash);known {continue}
            clear(&moved)
            for entity_row,from in mem.slice_data_cast([]u32,table.columns[0].data) {
                if row,kept:=asset.scene_entity_find(scene,previous_ids[entity_row]);kept {append(&moved,Moved{u32(row),u32(from)})}
            }
            if len(moved)==0 {continue}
            slice.sort_by(moved[:],proc(a,b:Moved) -> bool {return a.row<b.row})
            size:=table.columns[1].size
            clear(&table_rows)
            if resize(&images,len(moved)*size)!=nil {return .Out_Of_Memory}
            for entry,to in moved {
                append(&table_rows,entry.row)
                copy(images[to*size:][:size],table.columns[1].data[int(entry.from)*size:][:size])
            }
            target:=asset.scene_component_add(scene,table.name,&previous.doc.schema,table.columns[1].type) or_return
            asset.scene_component_fill(scene,target,table_rows[:],images[:]) or_return
            continue
        }
        target:=asset.document_table_add(&scene.doc,table.name,table.flags) or_return
        for column in table.columns {
            asset.document_column_add(&scene.doc,target,column.name,asset.document_import(&scene.doc,&link,column.type),column.flags,column.compression,column.alignment) or_return
        }
        asset.document_resize(&scene.doc,target,table.rows) or_return
        for column,c in table.columns {copy(scene.doc.tables[target].columns[c].data,column.data)}
        scene.doc.tables[target].key=table.key
        copies[at]=target
    }
    for &table,at in previous.doc.tables {
        if copies[at]<=0 {continue}
        for column,c in table.columns {
            if column.ref>0 && copies[column.ref]>0 {scene.doc.tables[copies[at]].columns[c].ref=copies[column.ref]}
        }
    }
    // Components the world does not know keep whether they were off.
    for record in previous.off {
        if _,known:=core.world_table_index_of_hash(w,record.component);known {continue}
        if _,kept:=asset.scene_entity_find(scene,record.entity);kept {asset.scene_component_turn(scene,record.entity,record.component,true) or_return}
    }
    return .None
}

