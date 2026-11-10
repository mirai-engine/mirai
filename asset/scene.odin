package asset

import "base:intrinsics"
import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// .scene: entities and their components, independent of any ECS. One with
// exactly one root is a prefab (Header_Flag.One_Root), which copies place.
//
//   entities     columns id (the key), parent, order and name
//   <component>  one table per component type, named as the component:
//                column entity, the row of entities it belongs to, in
//                increasing order, and column value, its data
//   scene        Scene_Info, one row
//   overrides    Override: what an instance of a prefab holds on its own
//   off          Component_Off: the components turned off by themselves; without
//                it, every component is on
//
// What a scene shows and obeys as a whole (its sky, its sun, its rules) is
// components of its entities. A table of one row and one column value is a
// setting of a version of the format before that: nothing reads it, and
// saving the document drops it.
//
// Whatever is saved refers to an entity by its Entity_Id: parents,
// overrides, and the Entity and Entity_Id fields of components. Only the
// entity column of a component table is a position in the file.
//
// The document stores every entity with its effective values, those of its
// prefabs included, so a scene loads without its prefabs. The instances of
// prefabs are two components of its entities (prefab.odin): where each came
// from, and on the root the content hash of the prefab file the instance was
// last brought up to date with. The overrides say which values and which
// places in its hierarchy an instance set itself as of that file; updating
// it from its prefab replaces everything else.

SCENE_VERSION :: 4
ENTITY_NAME_BYTES :: 64
OVERRIDE_PATH_BYTES :: 96

TABLE_ENTITIES :: "entities"
TABLE_SCENE :: "scene"
TABLE_OVERRIDES :: "overrides"
TABLE_OFF :: "off"
COLUMN_ENTITY :: "entity"
COLUMN_VALUE :: "value"

Entity_Name :: [ENTITY_NAME_BYTES]u8

Scene_Info :: struct {
    id_counter:u64, // the last one scene_new_id used
}

Override_Kind :: enum u8 {
    Field,   // the part of the component a path names; "" is all of it
    Added,   // a component the prefab does not have
    Removed, // a component of the prefab the instance does not have
    Turned,  // whether a component of the prefab is on
    Child,   // entity: one the instance placed under a member, with what is under it
}

Override :: struct {
    entity:base.Entity_Id, // the member; Child: the entity added
    component:u64, // name hash; 0 is the entity itself: its name (path "name") and, for Child, its place
    kind:Override_Kind,
    path:[OVERRIDE_PATH_BYTES]u8 `mirai:"text"`,
}

// A component of an entity turned off by itself: it keeps its value, and the
// world loads it off.
Component_Off :: struct {
    entity:base.Entity_Id,
    component:u64, // name hash
}

@(private="file") COLUMN_ID :: 0
@(private="file") COLUMN_PARENT :: 1
@(private="file") COLUMN_ORDER :: 2
@(private="file") COLUMN_NAME :: 3

Scene :: struct {
    doc:Document, // entities at table 0, then components and whatever else the file had
    types:^Types,
    index:map[base.Entity_Id]u32, // id -> row of entities
    info:Scene_Info,
    overrides:[dynamic]Override, // of the instances, as of the file each stamp names
    off:[dynamic]Component_Off,
    stamp:u64, // the content hash of the file it was read from or last written to; 0 for none
}

Entity_Record :: struct {
    id:base.Entity_Id,
    parent:base.Entity_Id,
    order:u32,
    name:string, // a view
}

scene_init :: proc(scene:^Scene,types:^Types,id:base.Asset_Id,allocator:=context.allocator) -> Error {
    scene^={types=types}
    document_init(&scene.doc,KIND_SCENE,id,allocator)
    scene.doc.kind_version=SCENE_VERSION
    scene_arrays_init(scene)
    table:=document_table_add(&scene.doc,TABLE_ENTITIES) or_return
    id_type,id_ok:=document_type(&scene.doc,types,base.Entity_Id)
    if !id_ok {return .Out_Of_Memory}
    order_type,order_ok:=document_type(&scene.doc,types,u32)
    if !order_ok {return .Out_Of_Memory}
    name_type,name_ok:=document_type(&scene.doc,types,Entity_Name)
    if !name_ok {return .Out_Of_Memory}
    document_column_add(&scene.doc,table,"id",id_type,{},.LZ) or_return
    document_column_add(&scene.doc,table,"parent",id_type,{},.LZ) or_return
    document_column_add(&scene.doc,table,"order",order_type,{},.LZ) or_return
    document_column_add(&scene.doc,table,"name",name_type,{.Text},.LZ) or_return
    scene.doc.tables[table].key=COLUMN_ID
    return .None
}

@(private="file")
scene_arrays_init :: proc(scene:^Scene) {
    allocator:=scene.doc.allocator
    scene.index=make(map[base.Entity_Id]u32,allocator)
    scene.overrides=make([dynamic]Override,allocator)
    scene.off=make([dynamic]Component_Off,allocator)
}

scene_destroy :: proc(scene:^Scene) {
    delete(scene.index);delete(scene.overrides);delete(scene.off)
    document_destroy(&scene.doc)
    scene^={}
}

scene_ids :: #force_inline proc(scene:^Scene) -> []base.Entity_Id {return mem.slice_data_cast([]base.Entity_Id,scene.doc.tables[0].columns[COLUMN_ID].data)}
scene_parents :: #force_inline proc(scene:^Scene) -> []base.Entity_Id {return mem.slice_data_cast([]base.Entity_Id,scene.doc.tables[0].columns[COLUMN_PARENT].data)}
scene_orders :: #force_inline proc(scene:^Scene) -> []u32 {return mem.slice_data_cast([]u32,scene.doc.tables[0].columns[COLUMN_ORDER].data)}
scene_names :: #force_inline proc(scene:^Scene) -> []Entity_Name {return mem.slice_data_cast([]Entity_Name,scene.doc.tables[0].columns[COLUMN_NAME].data)}
scene_entity_count :: #force_inline proc(scene:^Scene) -> int {return scene.doc.tables[0].rows}

// Whether the entities of the document of a scene hang from one root: what its header says when it is written.
@(private)
document_one_root :: proc(doc:^Document) -> bool {
    table,found:=document_table(doc,TABLE_ENTITIES)
    if !found || len(doc.tables[table].columns)<=COLUMN_PARENT || doc.tables[table].columns[COLUMN_PARENT].size!=size_of(base.Entity_Id) {return false}
    roots:=0
    for at:=0;at<len(doc.tables[table].columns[COLUMN_PARENT].data);at+=size_of(base.Entity_Id) {
        roots+=int(intrinsics.unaligned_load((^base.Entity_Id)(&doc.tables[table].columns[COLUMN_PARENT].data[at]))==0)
    }
    return roots==1
}

scene_entity_find :: proc(scene:^Scene,id:base.Entity_Id) -> (row:int,found:bool) {
    at,ok:=scene.index[id]
    return int(at),ok
}
scene_entity :: proc(scene:^Scene,row:int) -> Entity_Record {
    return {scene_ids(scene)[row],scene_parents(scene)[row],scene_orders(scene)[row],serial.text_field(scene_names(scene)[row][:])}
}

// An id no entity of the document has, from the sequence of new Ids
// (base.entity_id_next) whose state follows from the id of the asset and a
// counter it stores: the same edits give the same ids.
scene_new_id :: proc(scene:^Scene) -> base.Entity_Id {
    seed:=scene.doc.id[0]~(scene.doc.id[1]<<1)
    for {
        state:=seed+scene.info.id_counter*0x9e3779b97f4a7c15
        scene.info.id_counter+=1
        if id:=base.entity_id_next(&state);!(id in scene.index) {return id}
    }
}

// Adds an entity under a parent, 0 for none. order below 0 places it after
// its siblings.
scene_entity_add :: proc(scene:^Scene,id:base.Entity_Id,parent:base.Entity_Id,name:string,order:=-1) -> (row:int,error:Error) {
    if id==0 || id in scene.index || parent!=0 && !(parent in scene.index) {return -1,.Invalid}
    row=scene_entity_count(scene)
    place:=order
    if place<0 {
        place=0
        parents,orders:=scene_parents(scene),scene_orders(scene)
        for other,at in parents {
            if other==parent {place=max(place,int(orders[at])+1)}
        }
    }
    document_resize(&scene.doc,0,row+1) or_return
    scene_ids(scene)[row],scene_parents(scene)[row],scene_orders(scene)[row]=id,parent,u32(place)
    text_set(scene_names(scene)[row][:len(Entity_Name)-1],name)
    scene.index[id]=u32(row)
    return row,.None
}

scene_entity_rename :: proc(scene:^Scene,id:base.Entity_Id,name:string) -> Error {
    row,found:=scene_entity_find(scene,id)
    if !found {return .Not_Found}
    text_set(scene_names(scene)[row][:len(Entity_Name)-1],name)
    return .None
}

// Moves an entity under another parent. Fails when the parent is the entity
// or one of its descendants.
scene_entity_reparent :: proc(scene:^Scene,id:base.Entity_Id,parent:base.Entity_Id,order:u32) -> Error {
    row,found:=scene_entity_find(scene,id)
    if !found {return .Not_Found}
    parents:=scene_parents(scene)
    for ancestor,steps:=parent,0;ancestor!=0;steps+=1 {
        at,known:=scene_entity_find(scene,ancestor)
        if !known {return .Not_Found}
        if ancestor==id || steps>len(parents) {return .Invalid}
        ancestor=parents[at]
    }
    parents[row],scene_orders(scene)[row]=parent,order
    return .None
}

@(private="file")
component_table :: proc(scene:^Scene,table:int) -> bool {
    target:=&scene.doc.tables[table]
    return table!=0 && len(target.columns)==2 && target.columns[0].name==COLUMN_ENTITY && target.columns[0].ref==0 && target.columns[1].name==COLUMN_VALUE
}

// The table of a component, by its name or by the hash of its name.
scene_component :: proc(scene:^Scene,name:string) -> (table:int,found:bool) {
    table=document_table(&scene.doc,name) or_return
    return table,component_table(scene,table)
}
scene_component_by_hash :: proc(scene:^Scene,name_hash:u64) -> (table:int,found:bool) {
    for candidate,at in scene.doc.tables {
        if candidate.name_hash==name_hash && component_table(scene,at) {return at,true}
    }
    return -1,false
}

// The table of a component, created when the document does not have it, with
// a type of any schema. An existing table keeps the type it has.
scene_component_add :: proc(scene:^Scene,name:string,source:^serial.Schema,type:serial.Type_Index) -> (table:int,error:Error) {
    if existing,found:=document_table(&scene.doc,name);found {
        return existing,component_table(scene,existing)?.None:.Invalid
    }
    link:serial.Schema_Import
    document_import_begin(&scene.doc,&link,source)
    defer serial.schema_import_destroy(&link)
    if int(type)>=len(source.types) {return -1,.Invalid}
    imported:=document_import(&scene.doc,&link,type)
    if imported==serial.TYPE_NONE {return -1,.Out_Of_Memory}
    return scene_component_create(scene,name,imported)
}

@(private="file")
scene_component_create :: proc(scene:^Scene,name:string,type:serial.Type_Index) -> (table:int,error:Error) {
    if name==TABLE_SCENE || name==TABLE_OVERRIDES {return -1,.Invalid}
    row_type,imported:=document_type(&scene.doc,scene.types,u32)
    if !imported {return -1,.Out_Of_Memory}
    table=document_table_add(&scene.doc,name) or_return
    entity:=document_column_add(&scene.doc,table,COLUMN_ENTITY,row_type,{},.LZ) or_return
    document_column_add(&scene.doc,table,COLUMN_VALUE,type,{},.LZ) or_return
    scene.doc.tables[table].columns[entity].ref=0
    return table,.None
}

// The table of the component that holds values of T.
scene_component_of :: proc(scene:^Scene,name:string,$T:typeid) -> (table:int,error:Error) {
    index,known:=types_index(scene.types,T)
    if !known {return -1,scene.types.error}
    return scene_component_add(scene,name,&scene.types.schema,index)
}

@(private="file")
component_rows :: #force_inline proc(scene:^Scene,table:int) -> []u32 {
    return mem.slice_data_cast([]u32,scene.doc.tables[table].columns[0].data)
}

// Where the component of an entity row is in its table, or where it would go.
@(private="file")
component_search :: proc(scene:^Scene,table:int,entity_row:u32) -> (row:int,found:bool) {
    rows:=component_rows(scene,table)
    low,high:=0,len(rows)
    for low<high {
        middle:=(low+high)/2
        if rows[middle]<entity_row {low=middle+1}
        else {high=middle}
    }
    return low,low<len(rows) && rows[low]==entity_row
}

// The stored bytes of the component of an entity.
scene_component_get :: proc(scene:^Scene,table:int,id:base.Entity_Id) -> (image:[]u8,found:bool) {
    entity:=scene.index[id] or_return
    row:=component_search(scene,table,entity) or_return
    return document_cell(&scene.doc,table,1,row),true
}

// Sets the component of an entity from an image in the layout the table
// stores, adding it when the entity does not have it.
scene_component_set :: proc(scene:^Scene,table:int,id:base.Entity_Id,image:[]u8) -> Error {
    entity,known:=scene.index[id]
    if !known {return .Not_Found}
    if !component_table(scene,table) || len(image)!=scene.doc.tables[table].columns[1].size {return .Invalid}
    row,found:=component_search(scene,table,entity)
    if !found {
        document_rows_insert(&scene.doc,table,row,1) or_return
        component_rows(scene,table)[row]=entity
    }
    copy(document_cell(&scene.doc,table,1,row),image)
    return .None
}

scene_component_remove :: proc(scene:^Scene,table:int,id:base.Entity_Id) -> bool {
    entity:=scene.index[id] or_return
    row:=component_search(scene,table,entity) or_return
    _=scene_component_turn(scene,id,scene.doc.tables[table].name_hash,false)
    return document_rows_remove(&scene.doc,table,row,1)==.None
}

// Whether the component of an entity is turned off by itself.
scene_component_off :: proc(scene:^Scene,id:base.Entity_Id,component:u64) -> bool {
    for record in scene.off {
        if record.entity==id && record.component==component {return true}
    }
    return false
}

// Turns the component of an entity off by itself, or on.
scene_component_turn :: proc(scene:^Scene,id:base.Entity_Id,component:u64,off:bool) -> Error {
    for record,at in scene.off {
        if record.entity!=id || record.component!=component {continue}
        if !off {unordered_remove(&scene.off,at)}
        return .None
    }
    if !off {return .None}
    if !(id in scene.index) {return .Not_Found}
    if _,error:=append(&scene.off,Component_Off{id,component});error!=nil {return .Out_Of_Memory}
    return .None
}

// Replaces what a table holds: one image per entity row, rows increasing.
scene_component_fill :: proc(scene:^Scene,table:int,rows:[]u32,images:[]u8) -> Error {
    if !component_table(scene,table) {return .Invalid}
    size:=scene.doc.tables[table].columns[1].size
    if len(images)!=len(rows)*size {return .Invalid}
    for row,at in rows {
        if int(row)>=scene_entity_count(scene) || at>0 && rows[at-1]>=row {return .Invalid}
    }
    document_resize(&scene.doc,table,len(rows)) or_return
    copy(component_rows(scene,table),rows)
    copy(scene.doc.tables[table].columns[1].data,images)
    return .None
}

@(private)
scene_value_table :: proc(scene:^Scene,name:string,$T:typeid) -> (table:int,index:serial.Type_Index,same:bool,error:Error) {
    table=scene_component_of(scene,name,T) or_return
    index,_=types_index(scene.types,T)
    same=scene.doc.hashes[scene.doc.tables[table].columns[1].type]==scene.types.hashes[index]
    return table,index,same,.None
}

// Sets the component `name` of an entity to a value.
scene_set :: proc(scene:^Scene,id:base.Entity_Id,name:string,value:^$T) -> Error {
    table,index,same:=scene_value_table(scene,name,T) or_return
    stored:=scene.doc.tables[table].columns[1]
    image,no_image:=make([]u8,stored.size,scene.doc.allocator)
    defer delete(image,scene.doc.allocator)
    layout:=types_layout(scene.types,index)
    if no_image!=nil || layout==nil {return .Out_Of_Memory}
    if same {
        serial.value_write(layout,image,value,1)
    } else {
        // The file keeps the layout it was written with: the value goes into it by field names.
        normal:[size_of(T)]u8
        serial.value_write(layout,normal[:],value,1)
        migration:serial.Migration
        migration_error:=serial.migration_init(&migration,&scene.types.schema,index,&scene.doc.schema,stored.type,scene.doc.allocator)
        defer serial.migration_destroy(&migration)
        if migration_error!=.None {return migration_error==.Out_Of_Memory?.Out_Of_Memory:.Invalid}
        serial.migration_apply(&migration,image,normal[:],1)
    }
    return scene_component_set(scene,table,id,image)
}

// The component `name` of an entity as a T.
scene_get :: proc(scene:^Scene,id:base.Entity_Id,name:string,$T:typeid,default:^T=nil) -> (value:T,found:bool) {
    table:=scene_component(scene,name) or_return
    image:=scene_component_get(scene,table,id) or_return
    index:=types_index(scene.types,T) or_return
    migration:serial.Migration
    migration_error:=serial.migration_init(&migration,&scene.doc.schema,scene.doc.tables[table].columns[1].type,&scene.types.schema,index,scene.doc.allocator)
    defer serial.migration_destroy(&migration)
    if migration_error!=.None {return {},false}
    serial.value_read(&migration,&value,image,1,default)
    return value,true
}

// Fills the table of a component with one value per entity row, rows increasing.
scene_fill :: proc(scene:^Scene,name:string,rows:[]u32,values:[]$T) -> Error {
    table,index,same:=scene_value_table(scene,name,T) or_return
    if !same || len(values)!=len(rows) {return .Invalid}
    for row,at in rows {
        if int(row)>=scene_entity_count(scene) || at>0 && rows[at-1]>=row {return .Invalid}
    }
    layout:=types_layout(scene.types,index)
    if layout==nil {return .Out_Of_Memory}
    document_resize(&scene.doc,table,len(rows)) or_return
    serial.value_write(layout,scene.doc.tables[table].columns[1].data,raw_data(values),len(values))
    copy(component_rows(scene,table),rows)
    return .None
}

// Removes entities and, with descendants, everything under them: their
// components, and what the instances rooted at them recorded. What
// named them names none. Out_Of_Memory removes nothing. What it works with
// is temporary, so that it also takes back what a call without memory added.
scene_entities_remove :: proc(scene:^Scene,ids:[]base.Entity_Id,descendants:=true) -> (removed:int,error:Error) {
    count:=scene_entity_count(scene)
    allocator:=context.temp_allocator
    gone,no_gone:=make([]bool,count,allocator)
    remap,no_remap:=make([]i32,count,allocator)
    if no_gone!=nil || no_remap!=nil {return 0,.Out_Of_Memory}
    for id in ids {
        if row,found:=scene_entity_find(scene,id);found {gone[row]=true}
    }
    parents:=scene_parents(scene)
    if descendants {
        for changed:=true;changed; {
            changed=false
            for parent,row in parents {
                if gone[row] || parent==0 {continue}
                if gone[scene.index[parent]] {gone[row]=true;changed=true}
            }
        }
    }
    kept:=0
    for row in 0..<count {
        if gone[row] {remap[row]=-1;removed+=1}
        else {remap[row]=i32(kept);kept+=1}
    }
    if removed==0 {return 0,.None}
    left_ids,no_left:=make(map[base.Entity_Id]bool,removed,allocator)
    if no_left!=nil {return 0,.Out_Of_Memory}
    for id,row in scene_ids(scene) {
        if !gone[row] {continue}
        delete_key(&scene.index,id)
        left_ids[id]=true
    }
    for &table,at in scene.doc.tables {
        if at==0 {
            for &column in table.columns {
                size:=column.size
                for row in 0..<count {
                    if to:=remap[row];to>=0 && int(to)!=row {copy(column.data[int(to)*size:][:size],column.data[row*size:][:size])}
                }
                column_size(&scene.doc,&column,kept*size)
            }
            table.rows=kept
        } else if component_table(scene,at) {
            rows:=mem.slice_data_cast([]u32,table.columns[0].data)
            size:=table.columns[1].size
            left:=0
            for entity,row in rows {
                to:=remap[entity]
                if to<0 {continue}
                rows[left]=u32(to)
                if left!=row {copy(table.columns[1].data[left*size:][:size],table.columns[1].data[row*size:][:size])}
                left+=1
            }
            column_size(&scene.doc,&table.columns[0],left*size_of(u32))
            column_size(&scene.doc,&table.columns[1],left*size)
            table.rows=left
        }
    }
    for id,row in scene_ids(scene) {scene.index[id]=u32(row)}
    references_empty(scene,left_ids)
    for &parent in scene_parents(scene) {
        if parent!=0 && !(parent in scene.index) {parent=0}
    }
    scene_records_prune(scene)
    return removed,.None
}

// Empties the references of the components to the entities given.
@(private="file")
references_empty :: proc(scene:^Scene,targets:map[base.Entity_Id]bool) {
    refs:=make([dynamic]serial.Ref,scene.doc.allocator);defer delete(refs)
    for &table,at in scene.doc.tables {
        if !component_table(scene,at) || table.columns[1].size==0 {continue}
        clear(&refs)
        if !serial.refs_collect(&scene.doc.schema,table.columns[1].type,&refs,MAX_REFS) || len(refs)==0 {continue}
        size:=table.columns[1].size
        for row in 0..<table.rows {
            image:=table.columns[1].data[row*size:][:size]
            for ref in refs {
                if ref.kind==.Asset {continue}
                place:=(^u64)(&image[ref.offset])
                if base.Entity_Id(intrinsics.unaligned_load(place)) in targets {intrinsics.unaligned_store(place,0)}
            }
        }
    }
}

// -------------------------------------------------------------------- files

// Puts the overrides and the components off of the scene into its document, which can then be
// written without the types.
scene_records_put :: proc(scene:^Scene) -> Error {
    doc:=&scene.doc
    for name in ([]string{TABLE_SCENE,TABLE_OVERRIDES,TABLE_OFF}) {
        if table,found:=document_table(doc,name);found {document_table_remove(doc,table)}
    }
    document_put_row(doc,scene.types,TABLE_SCENE,&scene.info) or_return
    if len(scene.overrides)>0 {document_put(doc,scene.types,TABLE_OVERRIDES,scene.overrides[:],{},.LZ) or_return}
    if len(scene.off)>0 {document_put(doc,scene.types,TABLE_OFF,scene.off[:],{},.LZ) or_return}
    return .None
}

// Writes the scene into w, which has to be empty.
scene_write :: proc(scene:^Scene,w:^serial.Writer) -> Error {
    scene_records_put(scene) or_return
    document_write(&scene.doc,w) or_return
    header,_:=header_read(serial.writer_bytes(w))
    scene.stamp=header.content_hash
    return .None
}

// The file the scene is, as bytes from allocator.
scene_bytes :: proc(scene:^Scene,allocator:=context.allocator) -> (data:[]u8,error:Error) {
    scene_records_put(scene) or_return
    data=document_bytes(&scene.doc,allocator) or_return
    header,_:=header_read(data)
    scene.stamp=header.content_hash
    return data,.None
}

scene_save :: proc(scene:^Scene,path:string,sync:=false) -> Error {
    data:=scene_bytes(scene,scene.doc.allocator) or_return
    defer mem.free_bytes(data,scene.doc.allocator)
    return serial.file_write_atomic(path,data,sync)==.None?.None:.IO
}

// Takes a document as a scene. The document is the scene's from here on; on
// failure it is destroyed.
scene_from_document :: proc(scene:^Scene,types:^Types,doc:^Document) -> Error {
    scene^={types=types,doc=doc^}
    doc^={}
    scene_arrays_init(scene)
    error:=scene_adopt(scene)
    if error!=.None {scene_destroy(scene)}
    return error
}

// A copy of an open asset as a scene.
scene_from_asset :: proc(scene:^Scene,types:^Types,a:^Asset,allocator:=context.allocator) -> Error {
    doc:Document
    document_from_asset(&doc,a,allocator) or_return
    scene_from_document(scene,types,&doc) or_return
    scene.stamp=a.blob.header.content_hash
    return .None
}

scene_read :: proc(scene:^Scene,types:^Types,data:[]u8,allocator:=context.allocator) -> Error {
    a:Asset
    asset_open(&a,data,allocator) or_return
    defer asset_close(&a)
    return scene_from_asset(scene,types,&a,allocator)
}

scene_load :: proc(scene:^Scene,types:^Types,path:string,allocator:=context.allocator) -> Error {
    a:Asset
    asset_load(&a,path,allocator) or_return
    defer asset_close(&a)
    return scene_from_asset(scene,types,&a,allocator)
}

@(private="file")
scene_adopt :: proc(scene:^Scene) -> Error {
    doc,types:=&scene.doc,scene.types
    if doc.kind!=KIND_SCENE {return .Invalid}
    if doc.kind_version!=SCENE_VERSION {return .Version}
    entities,found:=document_table(doc,TABLE_ENTITIES)
    if !found || len(doc.tables[entities].columns)!=4 {return .Corrupt}
    if entities!=0 {
        // Entities first: component tables refer to table 0.
        moved:=doc.tables[entities]
        ordered_remove(&doc.tables,entities)
        inject_at(&doc.tables,0,moved)
        for &table in doc.tables {
            for &column in table.columns {
                if column.ref==entities {column.ref=0}
                else if column.ref>=0 && column.ref<entities {column.ref+=1}
            }
        }
    }
    names:=[4]string{"id","parent","order","name"}
    for name,at in names {
        if doc.tables[0].columns[at].name!=name {return .Corrupt}
    }
    document_column_convert(doc,types,0,COLUMN_ID,base.Entity_Id) or_return
    document_column_convert(doc,types,0,COLUMN_PARENT,base.Entity_Id) or_return
    document_column_convert(doc,types,0,COLUMN_ORDER,u32) or_return
    document_column_convert(doc,types,0,COLUMN_NAME,Entity_Name) or_return
    doc.tables[0].columns[COLUMN_NAME].flags+={.Text}
    doc.tables[0].key=COLUMN_ID
    count:=scene_entity_count(scene)
    for id,row in scene_ids(scene) {
        if id==0 || id in scene.index {return .Corrupt}
        scene.index[id]=u32(row)
    }
    for &name in scene_names(scene) {name[len(name)-1]=0}
    // Every chain of parents ends: a row is clear once its parent is.
    parents:=scene_parents(scene)
    state,no_state:=make([]u8,count,doc.allocator);defer delete(state,doc.allocator)
    if no_state!=nil {return .Out_Of_Memory}
    for start in 0..<count {
        row:=start
        for state[row]==0 {
            state[row]=1
            if parents[row]==0 {break}
            parent,known:=scene.index[parents[row]]
            if !known {return .Corrupt}
            row=int(parent)
            if state[row]==1 {return .Corrupt}
        }
        for row=start;state[row]==1; {
            state[row]=2
            if parents[row]==0 {break}
            row=int(scene.index[parents[row]])
        }
    }
    for &table,at in doc.tables {
        if at==0 || len(table.columns)!=2 || table.columns[0].name!=COLUMN_ENTITY || table.columns[1].name!=COLUMN_VALUE || table.columns[0].ref!=0 {continue}
        document_column_convert(doc,types,at,0,u32) or_return
        rows:=mem.slice_data_cast([]u32,table.columns[0].data)
        for row,i in rows {
            if int(row)>=count || i>0 && rows[i-1]>=row {return .Corrupt}
        }
    }
    if _,has:=document_table(doc,TABLE_SCENE);has {
        info:=make([dynamic]Scene_Info,doc.allocator);defer delete(info)
        document_rows(doc,types,TABLE_SCENE,&info) or_return
        if len(info)!=1 {return .Corrupt}
        scene.info=info[0]
    }
    if _,has:=document_table(doc,TABLE_OVERRIDES);has {document_rows(doc,types,TABLE_OVERRIDES,&scene.overrides) or_return}
    if _,has:=document_table(doc,TABLE_OFF);has {document_rows(doc,types,TABLE_OFF,&scene.off) or_return}
    for &override in scene.overrides {
        if !(override.entity in scene.index) || !override_valid(override) {return .Corrupt}
        override.path[len(override.path)-1]=0
    }
    for record in scene.off {
        if !(record.entity in scene.index) {return .Corrupt}
    }
    for name in ([]string{TABLE_SCENE,TABLE_OVERRIDES,TABLE_OFF}) {
        if table,has:=document_table(doc,name);has {document_table_remove(doc,table)}
    }
    // A member whose root is not one, or an override of what no instance placed, is of no instance.
    scene_records_prune(scene)
    return .None
}

// A kind it knows, with the entity itself for Child.
@(private)
override_valid :: proc(override:Override) -> bool {
    if override.kind>max(Override_Kind) {return false}
    return override.kind!=.Child || override.component==0
}

// ------------------------------------------------------------- read-only view

Scene_Component :: struct {
    name:string,
    name_hash:u64,
    table:^Asset_Table,
    type:serial.Type_Index, // of its values, in the schema of the file
    size:int,
    entities:[]u32, // rows of the entity table, increasing
}

// A scene open for loading: the columns of the file as they are.
Scene_View :: struct {
    info:Scene_Info,
    ids:[]base.Entity_Id,
    parents:[]base.Entity_Id,
    orders:[]u32,
    names:[]Entity_Name,
    components:[]Scene_Component,
    instances:[]Prefab_Instance, // of the roots of the prefab instances
    instance_rows:[]u32,   // the row of each root in the entities
    member_rows:[]u32,     // the rows of the entities a prefab instance placed
    overrides:[]Override,
    off:[]Component_Off,
}

// Columns of equal length, entity rows inside the entity table and in order, and a header that
// says One_Root of the scene that has one. Whether ids repeat or parents exist is left to scene_view_check.
// The asset keeps the view it read with types, so reading it again does not
// take more of its memory; the view is read only.
scene_view :: proc(a:^Asset,types:^Types) -> (view:Scene_View,error:Error) {
    if a.view_types==types && types!=nil {return a.view,.None}
    view=scene_view_read(a,types) or_return
    a.view,a.view_types=view,types
    return view,.None
}

@(private)
scene_view_read :: proc(a:^Asset,types:^Types) -> (view:Scene_View,error:Error) {
    if a.blob.header.kind!=KIND_SCENE {return {},.Invalid}
    if a.blob.header.kind_version!=SCENE_VERSION {return {},.Version}
    view.ids=asset_rows(a,types,TABLE_ENTITIES,"id",base.Entity_Id) or_return
    view.parents=asset_rows(a,types,TABLE_ENTITIES,"parent",base.Entity_Id) or_return
    view.orders=asset_rows(a,types,TABLE_ENTITIES,"order",u32) or_return
    view.names=asset_rows(a,types,TABLE_ENTITIES,"name",Entity_Name) or_return
    roots:=0
    for parent in view.parents {roots+=int(parent==0)}
    if (roots==1)!=(.One_Root in a.blob.header.flags) {return {},.Corrupt}
    if info,info_error:=table_rows(a,types,TABLE_SCENE,Scene_Info);info_error!=.None {return {},info_error}
    else if len(info)==1 {view.info=info[0]}
    view.instances=table_rows(a,types,COMPONENT_INSTANCE,Prefab_Instance,COLUMN_VALUE) or_return
    view.instance_rows=table_rows(a,types,COMPONENT_INSTANCE,u32,COLUMN_ENTITY) or_return
    view.member_rows=table_rows(a,types,COMPONENT_MEMBER,u32,COLUMN_ENTITY) or_return
    if len(view.instances)!=len(view.instance_rows) {return {},.Corrupt}
    view.overrides=table_rows(a,types,TABLE_OVERRIDES,Override) or_return
    view.off=table_rows(a,types,TABLE_OFF,Component_Off) or_return
    entity_table:=-1
    for table,at in a.tables {
        if table.name==TABLE_ENTITIES {entity_table=at}
    }
    count:=0
    for &table in a.tables {
        if len(table.columns)==2 && table.columns[0].name==COLUMN_ENTITY && table.columns[0].ref==entity_table && table.columns[1].name==COLUMN_VALUE {count+=1}
    }
    block:=asset_alloc(a,count*size_of(Scene_Component),align_of(Scene_Component)) or_return
    view.components=mem.slice_data_cast([]Scene_Component,block)
    count=0
    for &table in a.tables {
        if !(len(table.columns)==2 && table.columns[0].name==COLUMN_ENTITY && table.columns[0].ref==entity_table && table.columns[1].name==COLUMN_VALUE) {continue}
        rows:=asset_rows(a,types,table.name,COLUMN_ENTITY,u32) or_return
        for row,at in rows {
            if int(row)>=len(view.ids) || at>0 && rows[at-1]>=row {return {},.Corrupt}
        }
        view.components[count]={name=table.name,name_hash=table.name_hash,table=&table,type=table.columns[1].type,size=table.columns[1].size,entities=rows}
        count+=1
    }
    return view,.None
}

// The stored values of a component: rows*size bytes in the layout of the file.
scene_component_values :: proc(a:^Asset,component:^Scene_Component) -> ([]u8,Error) {
    return asset_column_data(a,component.table,1)
}

// The values of a component as a type of another schema, into dst.
scene_component_read :: proc(a:^Asset,component:^Scene_Component,schema:^serial.Schema,type:serial.Type_Index,dst:[]u8,default:[]u8=nil) -> Error {
    return asset_column_read(a,component.table,1,schema,type,dst,default)
}

// Ids that are not 0 nor repeated, parents that exist without cycles, names
// that end, and records that refer to what the scene has: Corrupt otherwise.
scene_view_check :: proc(view:Scene_View,allocator:=context.allocator) -> Error {
    index,no_index:=make(map[base.Entity_Id]u32,len(view.ids),allocator)
    defer delete(index)
    state,no_state:=make([]u8,len(view.ids),allocator)
    defer delete(state,allocator)
    if no_index!=nil || no_state!=nil {return .Out_Of_Memory}
    for id,row in view.ids {
        if id==0 || id in index {return .Corrupt}
        index[id]=u32(row)
    }
    for start in 0..<len(view.ids) {
        row:=start
        for state[row]==0 {
            state[row]=1
            if view.parents[row]==0 {break}
            parent,known:=index[view.parents[row]]
            if !known {return .Corrupt}
            row=int(parent)
            if state[row]==1 {return .Corrupt}
        }
        for row=start;state[row]==1; {
            state[row]=2
            if view.parents[row]==0 {break}
            row=int(index[view.parents[row]])
        }
    }
    for &name in view.names {
        if name[len(name)-1]!=0 {return .Corrupt}
    }
    for override in view.overrides {
        if !(override.entity in index) || !override_valid(override) {return .Corrupt}
    }
    for rows in ([][]u32{view.instance_rows,view.member_rows}) {
        for row in rows {
            if int(row)>=len(view.ids) {return .Corrupt}
        }
    }
    for record in view.off {
        if !(record.entity in index) {return .Corrupt}
    }
    return .None
}
