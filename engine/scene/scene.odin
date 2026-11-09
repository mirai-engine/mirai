package scene

import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Scenes and prefabs between their document and a world.
//
// A document names entities by Entity_Id and components by the name of their
// type; a world names them by handle and by its tables. Instantiating creates
// one entity per row of the document; capturing writes a document from the
// entities that have an Id. What a world cannot hold (the order of its
// roots, components of libraries the project does not have, the records of
// prefab instances and tables that are not components) is carried from the
// document the world was loaded from.

Error :: enum u8 {
    None,
    No_Assets,    // the application has no assets folder
    Not_Found,    // no scene or prefab with that id or path
    Invalid,      // not a scene nor a prefab, a parent that is not alive, a prefab that references a scene
    Cycle,        // a scene that references itself, or references nested past REFERENCE_DEPTH
    Not_A_Prefab, // spawn: the id names a scene, which is referenced, not spawned
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
    scope:core.Entity,      // the reference of a section: its unbounded volumes rule in its box (volume.Volume.scope)
    scope_extents:[3]f32,
    saved:bool,             // a saved game: what hangs from its references came with it, loaded as it was
    only:base.Entity_Id,    // when given, only the entity whose Id in the world (id_in with salt) is this and what hangs from it, a root; its references stay unloaded
}

Capture_Desc :: struct {
    root:core.Entity,      // only this entity and what is under it, as the root of a prefab; none: every root with an Id
    previous:^asset.Scene, // the document the world came from
    kind:asset.Fourcc,     // 0: a prefab when root is given, else the kind of previous, else a scene
    id:base.Asset_Id,      // zero: the id of previous
    entities:[]core.Entity, // when given, only these, as roots without what is under them; their Entity fields keep the Id of an entity left out
    sections:bool,          // also what hangs from a Scene_Reference, which its own scene keeps otherwise: a saved game
    section:core.Entity,    // only what hangs from this Scene_Reference, as its own scene, with the Ids of that scene
    excluded:[]typeid,      // components left out: what a network session keeps on entities, which a saved game does not
}

Report :: struct {
    root:core.Entity, // instantiate: the root of a prefab, or the first root of a scene
    entities:int,
    components:int,   // values attached or saved, Id, Name and Parent aside
    migrated:int,     // instantiate: tables stored with another layout
    unknown:int,      // tables the world has no component for
    dangling:int,     // entity references that named nothing inside: set to none
    sections:int,     // instantiate: referenced scenes loaded under their references
    missing:int,      // instantiate: references whose scene is not in the assets
    refused:Refusal,  // load_untrusted: what made it fail
}

// A prefab to place while the world runs.
Spawn :: struct {
    prefab:base.Asset_Id,
    parent:core.Entity,
    transform:core.Transform, // of the root; a zero scale counts as 1, a zero rotation as none
    transient:bool,
}

// The root of what spawn placed knows the prefab it came from: what
// replicates a prefab (multiplayer) recognizes it by this, whoever spawned it.
@(component,description="The prefab this entity was spawned from while the world runs.")
Prefab_Source :: struct {
    prefab:base.Asset_Id `mirai:"transient,readonly"`,
}

@(private) NONE_ROW :: u32(0xffffffff)

// What placing a prefab needs, for a step to receive in one parameter.
@(params)
Spawner :: struct {
    commands:core.Commands,
    app:^host.App,
    problems:^core.Problems,
}

// Places a prefab of the assets, by its path ("prefabs/Dog.prefab") or its id,
// and gives back its root, whose rows wait for the end of the function. NONE
// when it did not spawn, which is the problem scene.spawn that says why.
spawn :: proc{spawn_path,spawn_id}

spawn_path :: proc(s:Spawner,path:string,at:core.Transform={},parent:=core.NONE,transient:=false) -> core.Entity {
    prefab:base.Asset_Id
    error:=Error.No_Assets
    if s.app.assets!=nil {
        error=.Not_Found
        if named,found:=asset.registry_find_path(&s.app.assets.registry,path);found {prefab=named.id;error=.None}
    }
    return spawn_report(s,{prefab=prefab,parent=parent,transform=at,transient=transient},path,error)
}

spawn_id :: proc(s:Spawner,prefab:base.Asset_Id,at:core.Transform={},parent:=core.NONE,transient:=false) -> core.Entity {
    name:[base.ASSET_ID_TEXT]u8
    return spawn_report(s,{prefab=prefab,parent=parent,transform=at,transient=transient},host.assets_name(s.app.assets,prefab,&name),.None)
}

@(private)
spawn_report :: proc(s:Spawner,order:Spawn,name:string,found:Error) -> core.Entity {
    report,error:=Report{},found
    if error==.None {report,error=spawn_prefab(s.commands,s.app,order)}
    if error==.None {return report.root}
    fix:string
    #partial switch error {
    case .No_Assets:     fix="run the game from a project with an assets folder"
    case .Not_Found:     fix="name a .prefab of the assets by its path or id: import or create it, or fix the name"
    case .Invalid:       fix="spawn a .prefab under a parent that is alive, or with no parent"
    case .Not_A_Prefab:  fix="name a .prefab: a scene is placed as a Scene_Reference, or turned into a prefab with asset.convert"
    case .Corrupt:       fix="open the prefab in the editor and save it again"
    case .Out_Of_Memory: fix="free memory or spawn fewer prefabs at once"
    }
    core.report(s.problems,order.parent,"scene.spawn","prefab %s did not spawn: %s; %s",name,error_text(error),fix)
    return core.NONE
}

error_text :: proc(error:Error) -> string {
    switch error {
    case .None:          return ""
    case .No_Assets:     return "the application has no assets folder"
    case .Not_Found:     return "no scene or prefab has that path or id"
    case .Invalid:       return "not a scene nor a prefab, or a prefab that references a scene"
    case .Cycle:         return "a scene references itself"
    case .Not_A_Prefab:  return "it is a scene, not a prefab"
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
    if view_error!=.None || !asset.scene_view_check(view,context.temp_allocator) {return {},.Corrupt}
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
replace :: proc(w:core.World_Ref,app:^host.App,a:^asset.Asset,asset_types:^asset.Types,entities:[]core.Entity=nil,references:=true) -> (report:Report,error:Error) {
    if app.info==nil || w.info!=app.info || w.place!=.World {return {},.Invalid}
    making:=host.load_phase_begin(app,.Instantiate)
    data:=host.app_world_create(app)
    if data==nil {
        host.load_phase_end(app,making)
        return {},.Out_Of_Memory
    }
    defer host.app_world_free(app,data)
    candidate:=host.app_world_ref(app,data)
    if !w.info.copy(data,w.data) {
        host.load_phase_end(app,making)
        return {},.Out_Of_Memory
    }
    w.info.clear(data)
    report,error=instantiate(candidate,a,asset_types,{entities=entities,documents=references?assets_documents(app.assets):{},saved=!references})
    host.load_phase_end(app,making,core.world_entities(candidate).alive)
    settling:=host.load_phase_begin(app,.Settle)
    defer host.load_phase_end(app,settling)
    core.world_settle(candidate)
    if error!=.None {return}
    if !references {scopes_restore(candidate)}
    root_set(candidate,a.blob.header.id)
    references_resolve(candidate)
    propagate(candidate,app)
    w.info.swap(w.data,data)
    records_look(w)
    return
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
// them with core.added.
spawn_prefab :: proc(c:core.Commands,app:^host.App,s:Spawn) -> (report:Report,error:Error) {
    if app.assets==nil {return {},.No_Assets}
    file:=host.assets_scene(app.assets,s.prefab)
    if file==nil {return {},.Not_Found}
    if file.blob.header.kind!=asset.KIND_PREFAB {return {},.Not_A_Prefab}
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=current(assets_documents(app.assets),file,&resolved) or_return
    report,error=instantiate(core.world_ref(c.data,c.info),document,&app.assets.types,{parent=s.parent,transient=s.transient,fresh=!s.transient})
    if error!=.None {return}
    if root:=core.commands_added(c,report.root,core.Transform);root!=nil {
        root^=s.transform
        if root.rotation==0 {root.rotation=1}
        if root.scale=={} {root.scale={1,1,1}}
    }
    core.commands_add(c,report.root,Prefab_Source{s.prefab})
    return
}

// A copy of an entity of the scene of a section, by its Id in the world, and
// of what hangs from it, as a root of the world without Ids (Spawn.transient):
// what stands for it where its section is not loaded. salt is the Id of the
// reference of the section.
spawn_member :: proc(c:core.Commands,app:^host.App,section_scene:base.Asset_Id,salt,id:base.Entity_Id,transform:core.Transform) -> (report:Report,error:Error) {
    if app.assets==nil {return {},.No_Assets}
    file:=host.assets_scene(app.assets,section_scene)
    if file==nil {return {},.Not_Found}
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=current(assets_documents(app.assets),file,&resolved) or_return
    report,error=instantiate(core.world_ref(c.data,c.info),document,&app.assets.types,{transient=true,salt=salt,only=id})
    if error!=.None {return}
    if root:=core.commands_added(c,report.root,core.Transform);root!=nil {root^=transform}
    return
}

// The document a load or a spawn instantiates. With the assets of a project
// it is a copy of the file whose stale prefab instances follow their prefabs
// now, when it has one; the file otherwise, and always in a shipped game,
// whose cook resolved them.
@(private)
current :: proc(d:Documents,file:^asset.Asset,resolved:^asset.Asset) -> (document:^asset.Asset,error:Error) {
    if _,placed:=asset.asset_table(file,asset.TABLE_INSTANCES);!placed || d.cooked || d.open==nil {return file,.None}
    r:asset.Prefab_Resolver
    asset.resolver_init(&r,d.types,{d.user,d.open},context.temp_allocator)
    defer asset.resolver_destroy(&r)
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

// Creates the entities of a scene or prefab in a world. Every entity gets
// Id, Name and Transform; each table the world has a component for is read
// into it, migrating by field names when the layouts differ, and its Entity
// fields become handles. Children keep the order of the document. The rows
// appear at the next settle, and the world transforms at the next
// propagation: what needs a pose before composes it with core.world_of.
instantiate :: proc(w:core.World_Ref,a:^asset.Asset,asset_types:^asset.Types,desc:Instantiate_Desc={}) -> (report:Report,error:Error) {
    es:=core.world_entities(w)
    if desc.parent!=core.NONE && !core.alive(es,desc.parent) {return {},.Invalid}
    view,view_error:=asset.scene_view(a,asset_types)
    if view_error!=.None {return {},view_error==.Invalid?.Invalid:view_error==.Out_Of_Memory?.Out_Of_Memory:.Corrupt}
    if !asset.scene_view_check(view,context.temp_allocator) {return {},.Corrupt}
    count:=len(view.ids)
    if desc.entities!=nil && len(desc.entities)<count {return {},.Invalid}
    types:=schema_of(w)
    if types==nil {return {},.Out_Of_Memory}

    keys:=make([]Key,count,context.temp_allocator)
    parents:=make([]u32,count,context.temp_allocator)
    for id,row in view.ids {keys[row]={id,u32(row)}}
    slice.sort_by(keys,proc(a,b:Key) -> bool {return a.id<b.id})
    for parent,row in view.parents {parents[row],_=key_find(keys,parent)}

    // The rows of the document it makes: all, or those under the one asked for.
    kept:=make([]bool,count,context.temp_allocator)
    top:=NONE_ROW
    if desc.only!=0 {
        for id,row in view.ids {
            if id_in(desc.salt,id)==desc.only {top=u32(row);break}
        }
        if top==NONE_ROW {return {},.Not_Found}
        for row in 0..<count {
            for x,depth:=u32(row),0;x!=NONE_ROW && depth<=count;x,depth=parents[x],depth+1 {
                if x==top {kept[row]=true;break}
            }
        }
    } else {
        for &k in kept {k=true}
    }
    entities:=desc.entities!=nil?desc.entities[:count]:make([]core.Entity,count,context.temp_allocator)
    for row in 0..<count {entities[row]=kept[row]?core.create(es):core.NONE}

    transforms:=core.world_table_of(w,core.Transform)
    names:=core.world_table_of(w,core.Name)
    ids:=core.world_table_of(w,core.Id)
    parent_table:=core.world_table_of(w,core.Parent)
    members:=core.world_table_of(w,Section_Member)
    placed:=make([]bool,count,context.temp_allocator)
    for row in 0..<count {
        e:=entities[row]
        if e==core.NONE {continue}
        if names!=nil {core.add(names,e,core.Name{text=view.names[row]})}
        if ids!=nil && !desc.transient {core.add(ids,e,core.Id{desc.fresh?core.id_next(es):id_in(desc.salt,view.ids[row])})}
        if members!=nil && desc.salt!=0 && !desc.transient {core.add(members,e,Section_Member{view.ids[row]})}
    }

    Section :: struct {entity:core.Entity,reference:Scene_Reference,id:base.Entity_Id}
    unresolved:=core.world_storage_of(w,Unresolved_References)
    sections:=make([dynamic]Section,context.temp_allocator)
    values:=make([dynamic]u8,context.temp_allocator)
    Off :: struct {entity:base.Entity_Id,component:u64}
    off:=make(map[Off]bool,context.temp_allocator)
    for record in view.off {off[{record.entity,record.component}]=true}
    // The rows a prefab instance of the document brought.
    instanced:=make([]bool,count,context.temp_allocator)
    for member in view.members {
        if row,found:=key_find(keys,member.entity);found {instanced[row]=true}
    }
    for &component in view.components {
        at,known:=core.world_table_index_of_hash(w,component.name_hash)
        if !known {
            report.unknown+=1
            continue
        }
        info:=&w.info.tables[at]
        table:=core.world_table_at(w,info)
        if is_structural(info.type) {continue}
        value_type:=&types.tables[info_index(w,info)]
        size:=info.info.size
        report.components+=len(component.entities)
        if resize(&values,len(component.entities)*size)!=nil {return report,.Out_Of_Memory}
        if size>0 {
            if value_type.type==serial.TYPE_NONE {
                stored,stored_error:=asset.scene_component_values(a,&component)
                if stored_error!=.None {return report,.Corrupt}
                copy(values[:],stored)
            } else {
                if !component_read(a,&component,types,info,value_type,values[:]) {return report,.Corrupt}
                if !asset.asset_column_matches(a,component.table,1,value_type.hash) {report.migrated+=1}
            }
            for row in 0..<len(component.entities) {
                image:=values[row*size:][:size]
                for offset in value_type.entities {
                    field:=cast(^u64)&image[offset]
                    target:=base.Entity_Id(intrinsics.unaligned_load(field))
                    live:=core.NONE
                    if target!=0 {
                        // Outside the document: the Id in the world of an entity of another section or of the root.
                        if found,known:=key_find(keys,target);known {live=entities[found]}
                        else if unresolved!=nil && !desc.transient && kept[component.entities[row]] {append(&unresolved.items,Unresolved_Reference{entities[component.entities[row]],component.name_hash,offset,target})}
                        else {report.dangling+=1}
                    }
                    intrinsics.unaligned_store(field,u64(live))
                }
            }
        }
        for row,i in component.entities {
            if !kept[row] {continue}
            value:rawptr=size>0?&values[i*size]:nil
            if info.type==volume.Volume && desc.scope!=core.NONE {
                place:=(^volume.Volume)(value)
                if place.shape==.Unbounded {place.scope,place.scope_extents=desc.scope,desc.scope_extents}
            }
            if info.type==Scene_Reference && (desc.documents.open!=nil || desc.saved) && desc.only==0 {
                reference:=(^Scene_Reference)(value)
                if (reference.rule==.With_Document || desc.saved) && reference.state!=.Unloaded {reference.loaded=reference.scene}
            }
            core.raw_add(table,info.info,entities[row],value)
            // What the world uses one of (a sky, a sun) of a section or a prefab, placed or in the document, comes off: only enable turns it on.
            if off[{view.ids[row],component.name_hash}] || info.single && (desc.salt!=0 || desc.fresh || desc.transient || instanced[row]) {core.raw_disable(table,entities[row])}
            if info.type==core.Transform {placed[row]=true}
            // Only what loads with its document; the others wait for their state (scene_sections).
            if info.type==Scene_Reference && desc.only==0 {
                reference:=(^Scene_Reference)(value)
                if reference.rule==.With_Document && reference.state!=.Unloaded {append(&sections,Section{entities[row],reference^,id_in(desc.salt,view.ids[row])})}
            }
        }
    }
    if transforms!=nil {
        for row in 0..<count {
            if kept[row] && !placed[row] {core.add(transforms,entities[row],core.TRANSFORM_IDENTITY)}
        }
    }

    // Children keep the order of the document.
    Place :: struct {order,row:u32}
    places:=make([]Place,count,context.temp_allocator)
    for order,row in view.orders {places[row]={order,u32(row)}}
    slice.sort_by(places,proc(a,b:Place) -> bool {return a.order<b.order || a.order==b.order && a.row<b.row})
    siblings:=make(map[u32]i32,context.temp_allocator)
    for place in places {
        if !kept[place.row] {continue}
        parent_row:=parents[place.row]
        if place.row==top {parent_row=NONE_ROW}
        parent:=parent_row==NONE_ROW?desc.parent:entities[parent_row]
        if parent_row==NONE_ROW && report.root==core.NONE {report.root=entities[place.row]}
        if parent!=core.NONE && parent_table!=nil {
            order:=siblings[parent_row]
            siblings[parent_row]=order+1
            core.add(parent_table,entities[place.row],core.Parent{parent,order})
        }
    }
    if root,found:=key_find(keys,view.info.root);found && top==NONE_ROW {report.root=entities[root]}
    if top!=NONE_ROW {report.root=entities[top]}
    report.entities=0
    for k in kept {report.entities+=int(k)}
    // A section that loads with what holds it knows what its scene brought.
    if desc.parent!=core.NONE && desc.salt!=0 && !desc.transient && desc.only==0 {records_add(w,desc.parent,view.ids)}
    if len(sections)>0 {
        if a.blob.header.kind==asset.KIND_PREFAB {return report,.Invalid}
        sections_error:=sections_load(w,a,asset_types,desc,sections[:],&report)
        if sections_error!=.None {return report,sections_error}
    }
    return report,.None
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
sections_load :: proc(w:core.World_Ref,a:^asset.Asset,asset_types:^asset.Types,desc:Instantiate_Desc,sections:[]$T,report:^Report) -> Error {
    if desc.documents.open==nil {return .None}
    if len(desc.path)>=REFERENCE_DEPTH {return .Cycle}
    path:=make([]base.Asset_Id,len(desc.path)+1,context.temp_allocator)
    copy(path,desc.path)
    path[len(desc.path)]=a.blob.header.id
    for section in sections {
        if slice.contains(path,section.reference.scene) {return .Cycle}
        file:=desc.documents.open(desc.documents.user,section.reference.scene)
        if file==nil || file.blob.header.kind!=asset.KIND_SCENE {
            report.missing+=1
            continue
        }
        resolved:asset.Asset
        defer asset.asset_close(&resolved)
        document:=current(desc.documents,file,&resolved) or_return
        inner,error:=instantiate(w,document,asset_types,{parent=section.entity,transient=desc.transient,documents=desc.documents,salt=section.id,path=path,scope=section.entity,scope_extents=section.reference.extents})
        report.entities+=inner.entities
        report.components+=inner.components
        report.migrated+=inner.migrated
        report.unknown+=inner.unknown
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

@(private)
info_index :: proc(w:core.World_Ref,info:^core.Table_Info) -> int {
    return int((uintptr(info)-uintptr(raw_data(w.info.tables)))/size_of(core.Table_Info))
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
    ids,parents:=core.read(id_table),core.read(parent_table)
    names:=core.read(core.world_table_of(w,core.Name))
    previous:=desc.previous
    kind,id:=desc.kind,desc.id
    if kind==0 {kind=desc.root!=core.NONE?asset.KIND_PREFAB:previous!=nil?previous.doc.kind:asset.KIND_SCENE}
    if id=={} && previous!=nil {id=previous.doc.id}
    types:=schema_of(w)
    if types==nil {return {},.Out_Of_Memory}

    Root :: struct {entity:core.Entity,known:bool,order,tie:u32}
    roots:=make([dynamic]Root,context.temp_allocator)
    // The Id an entity has in the document: in a section, the one of its own scene.
    members:=core.world_table_of(w,Section_Member)
    doc_id :: proc(ids:core.Read(core.Id),members:^core.Table(Section_Member),section:core.Entity,e:core.Entity) -> base.Entity_Id {
        if section!=core.NONE && members!=nil {
            if member,ok:=core.get(core.read(members),e);ok && member.local!=0 {return member.local}
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

    if asset.scene_init(scene,asset_types,kind,id,allocator)!=.None {return {},.Invalid}
    defer if error!=.None {
        asset.scene_destroy(scene)
        report={}
    }
    for visit in placed {
        label:=names.table!=nil?core.name_get(names,visit.entity):""
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
        if info.place!=w.place || is_structural(info.type) || value_type.type==serial.TYPE_NONE {continue}
        if info.type==Section_Member && !desc.sections {continue}
        if slice.contains(desc.excluded,info.type) {continue}
        size:=info.info.size
        if size>0 && len(value_type.layout.runs)==0 {continue}
        table:=core.world_table_at(w,&info)
        hash:=base.name_hash(info.name)
        clear(&table_rows);clear(&images)
        // resize asks for exactly what it is given, and this allocator frees
        // nothing: growing row by row would cost the square of the rows.
        if reserve(&images,core.raw_count(table)*size)!=nil {return report,.Out_Of_Memory}
        for visit,row in placed {
            value:=core.raw_find(table,info.info,visit.entity)
            if value==nil {continue}
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
                    else if desc.root==core.NONE || desc.entities!=nil {saved=core.id_of(ids,target)}
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

    if desc.root!=core.NONE {scene.info.root=core.id_of(ids,desc.root)}
    if previous!=nil {
        if carry(w,scene,previous,&report)!=.None {return report,.Out_Of_Memory}
    }
    return report,.None
}

// Captures the world and writes it to a file of the assets.
save :: proc(w:core.World_Ref,app:^host.App,path:string,previous:^asset.Scene=nil,id:base.Asset_Id={}) -> (report:Report,error:Error) {
    if app.assets==nil {return {},.No_Assets}
    doc:asset.Scene
    report,error=capture(w,&doc,&app.assets.types,{previous=previous,id=id})
    if error!=.None {return}
    defer asset.scene_destroy(&doc)
    if asset.scene_save(&doc,path)!=.None {return report,.Write_Failed}
    return
}

// What a world cannot hold, from the document it was loaded from.
@(private)
carry :: proc(w:core.World_Ref,scene,previous:^asset.Scene,report:^Report) -> asset.Error {
    root:=scene.info.root
    scene.info=previous.info
    if root!=0 {scene.info.root=root}
    else if _,kept:=asset.scene_entity_find(scene,scene.info.root);!kept {scene.info.root=0}
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
        if table.name==asset.TABLE_SCENE || table.name==asset.TABLE_INSTANCES || table.name==asset.TABLE_MEMBERS || table.name==asset.TABLE_OVERRIDES || table.name==asset.TABLE_OFF {continue}
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
            report.unknown+=1
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
    for instance in previous.instances {
        _,rooted:=asset.scene_entity_find(scene,instance.root)
        if rooted && (instance.outer==0 || asset.scene_instance_find(scene,instance.outer)>=0) {append(&scene.instances,instance)}
    }
    for member in previous.members {
        if _,kept:=asset.scene_entity_find(scene,member.entity);kept && asset.scene_instance_find(scene,member.instance)>=0 {append(&scene.members,member)}
    }
    for override in previous.overrides {
        if _,kept:=asset.scene_entity_find(scene,override.entity);kept && asset.scene_instance_find(scene,override.instance)>=0 {append(&scene.overrides,override)}
    }
    // Components the world does not know keep whether they were off.
    for record in previous.off {
        if _,known:=core.world_table_index_of_hash(w,record.component);known {continue}
        if _,kept:=asset.scene_entity_find(scene,record.entity);kept {asset.scene_component_turn(scene,record.entity,record.component,true) or_return}
    }
    return .None
}

// The unbounded volumes of the sections of a saved game, which does not keep
// where they rule: each rules again in the box of the section it hangs from.
@(private)
scopes_restore :: proc(w:core.World_Ref) {
    places:=core.world_table_of(w,volume.Volume)
    references:=core.world_table_of(w,Scene_Reference)
    parents:=core.world_table_of(w,core.Parent)
    if places==nil || references==nil || parents==nil {return}
    for row in 0..<core.count(places) {
        if core.at(core.read(places),row).shape!=.Unbounded {continue}
        section:=core.ancestor_with(core.read(parents),core.read(references),core.entity_at(places,row))
        reference,found:=core.get(core.read(references),section)
        if !found {continue}
        place:=core.at(places,row)
        place.scope,place.scope_extents=section,reference.extents
    }
}
