package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Prefab instances inside a scene. A prefab is a scene with exactly one root.
//
// Instantiating copies the entities of the prefab with new ids, points their
// references to each other at the copies and empties those that pointed
// outside the prefab. The root of the instance keeps the prefab and the
// content hash of the file it was last brought up to date with (Prefab_Instance),
// and every entity it placed, the root among them, the entity of the prefab
// it stands for (Prefab_Member): two components, saved and merged as any other.
// What it set on its own are its overrides: values and components, and the
// entities it added under its members. Updating adds and removes members
// with the prefab, and gives every member the parent, order, name and
// components the prefab has, except for what an override names. The parent,
// order and placement of the root (INSTANCE_PLACEMENT) belong to the
// instance.
//
// A document holds the instances it placed, not those its prefabs place: the
// entities of an instance a prefab placed are members of the outer one, and
// unlinking that one gives them back as instances of this document, read
// from the prefab through the source of each member.
//
// The stamp of an instance is that of its prefab as it was last brought up
// to date with it: the content hash of the prefab as resolved, which is the
// hash of its file while nothing it places is stale, and otherwise the hash
// of the file a save of it resolved would write. Every end computes the same
// one, so an instance brought up to date is up to date at the editor, the
// cook and a load alike, whether or not its prefab was saved again.
// Prefab_Resolver finds the stale instances and brings them up to date.

COMPONENT_INSTANCE :: "Prefab_Instance"
COMPONENT_MEMBER :: "Prefab_Member"

// The component of the root of what a prefab placed, in a document and in a
// world. The root of a copy spawned while the world runs is no Prefab_Member.
@(component,description="The root of what a prefab placed: an instance linked to it in this scene, or a copy spawned while the world runs.")
Prefab_Instance :: struct {
    prefab:base.Asset_Id `mirai:"readonly,hidden"`,
    stamp:u64 `mirai:"readonly,hidden"`, // the content hash of the prefab, as resolved, it was last updated from; 0: not known, and that of a spawned copy
}

// The component of an entity an instance placed.
@(component,description="An entity an instance of a prefab placed in this scene.")
Prefab_Member :: struct {
    instance:base.Entity `mirai:"readonly,hidden"`, // the root of its instance, by its Entity_Id in a document
    source:u64 `mirai:"readonly,hidden"`,           // its Entity_Id in the prefab: not a reference into this document
}

// An entity of an instance and the entity of the prefab it stands for.
Placed :: struct {entity,source:base.Entity_Id}

// The component that places the root of an instance: the instance's, never the prefab's.
INSTANCE_PLACEMENT :: "Transform"

// Whether a path names the part another names, or a part that contains it.
path_covers :: proc(path,part:string) -> bool {
    if path=="" || path==part {return true}
    return len(part)>len(path) && part[:len(path)]==path && (part[len(path)]=='.' || part[len(path)]=='[')
}

// Whether an open asset, or a file as its registry read its header, is a prefab: a scene its header says is one.
asset_prefab :: proc "contextless" (a:^Asset) -> bool {return a.blob.header.kind==KIND_SCENE && .Prefab in a.blob.header.flags}
registry_prefab :: proc "contextless" (file:^Registry_File) -> bool {return file.state==.Asset && file.kind==KIND_SCENE && .Prefab in file.flags}

// Why a scene cannot be a prefab: it has no root or several; "" when it can.
prefab_refused :: proc(scene:^Scene) -> string {
    if _,one:=prefab_root(scene);one {return ""}
    return "a prefab has exactly one root: put its entities under one, or keep it a scene"
}

// The entity an instance of a prefab places: its only entity without parent.
prefab_root :: proc(prefab:^Scene) -> (root:base.Entity_Id,found:bool) {
    for parent,row in scene_parents(prefab) {
        if parent!=0 {continue}
        if root!=0 {return 0,false}
        root=scene_ids(prefab)[row]
    }
    return root,root!=0
}

// The base of a variant: the prefab its root is an instance of.
prefab_variant_base :: proc(prefab:^Scene) -> (base_prefab:base.Asset_Id,variant:bool) {
    root:=prefab_root(prefab) or_return
    instance:=scene_instance(prefab,root) or_return
    return instance.prefab,true
}

@(private)
membership_hash :: proc(name_hash:u64) -> bool {
    return name_hash==base.name_hash(COMPONENT_INSTANCE) || name_hash==base.name_hash(COMPONENT_MEMBER)
}

// The table of one of the two components in the layout of this build; -1 without it.
@(private="file")
membership :: proc(scene:^Scene,name:string,$T:typeid) -> (table:int,error:Error) {
    found:bool
    if table,found=document_table(&scene.doc,name);!found {return -1,.None}
    if len(scene.doc.tables[table].columns)!=2 {return -1,.Corrupt}
    document_column_convert(&scene.doc,scene.types,table,1,T) or_return
    return table,.None
}

@(private="file")
table_entities :: proc(scene:^Scene,table:int) -> []u32 {
    return mem.slice_data_cast([]u32,scene.doc.tables[table].columns[0].data)
}

// The members of the document: the row of each in the entities, and its value.
@(private)
member_rows :: proc(scene:^Scene) -> (rows:[]u32,values:[]Prefab_Member,error:Error) {
    table:=membership(scene,COMPONENT_MEMBER,Prefab_Member) or_return
    if table<0 {return}
    return table_entities(scene,table),mem.slice_data_cast([]Prefab_Member,scene.doc.tables[table].columns[1].data),.None
}

@(private)
instance_rows :: proc(scene:^Scene) -> (rows:[]u32,values:[]Prefab_Instance,error:Error) {
    table:=membership(scene,COMPONENT_INSTANCE,Prefab_Instance) or_return
    if table<0 {return}
    return table_entities(scene,table),mem.slice_data_cast([]Prefab_Instance,scene.doc.tables[table].columns[1].data),.None
}

// The instance an entity is the root of.
scene_instance :: proc(scene:^Scene,root:base.Entity_Id) -> (instance:Prefab_Instance,found:bool) {
    table,error:=membership(scene,COMPONENT_INSTANCE,Prefab_Instance)
    if error!=.None || table<0 {return}
    image:=scene_component_get(scene,table,root) or_return
    mem.copy(&instance,raw_data(image),size_of(Prefab_Instance))
    return instance,true
}

scene_instance_set :: proc(scene:^Scene,root:base.Entity_Id,instance:Prefab_Instance) -> Error {
    value:=instance
    return scene_set(scene,root,COMPONENT_INSTANCE,&value)
}

// The roots of the instances placed in the document.
scene_instance_roots :: proc(scene:^Scene,allocator:=context.temp_allocator) -> []base.Entity_Id {
    rows,_,error:=instance_rows(scene)
    roots,failed:=make([]base.Entity_Id,error==.None?len(rows):0,allocator)
    if failed!=nil {return nil}
    ids:=scene_ids(scene)
    for &root,at in roots {root=ids[rows[at]]}
    return roots
}

// The root of the instance that placed an entity and the entity of the prefab it stands for.
scene_member :: proc(scene:^Scene,entity:base.Entity_Id) -> (root,source:base.Entity_Id,found:bool) {
    table,error:=membership(scene,COMPONENT_MEMBER,Prefab_Member)
    if error!=.None || table<0 {return}
    image:=scene_component_get(scene,table,entity) or_return
    member:Prefab_Member
    mem.copy(&member,raw_data(image),size_of(Prefab_Member))
    if member.instance==0 {return}
    return base.Entity_Id(member.instance),base.Entity_Id(member.source),true
}

scene_member_set :: proc(scene:^Scene,entity,root,source:base.Entity_Id) -> Error {
    value:=Prefab_Member{base.Entity(root),u64(source)}
    return scene_set(scene,entity,COMPONENT_MEMBER,&value)
}

@(private="file")
membership_remove :: proc(scene:^Scene,name:string,entity:base.Entity_Id) {
    if table,found:=document_table(&scene.doc,name);found {scene_component_remove(scene,table,entity)}
}

// The members of an instance, in the order of the entities of the document.
scene_instance_members :: proc(scene:^Scene,root:base.Entity_Id,allocator:=context.temp_allocator) -> (members:[]Placed,error:Error) {
    rows,values:=member_rows(scene) or_return
    out:=make([dynamic]Placed,allocator)
    ids:=scene_ids(scene)
    for value,at in values {
        if base.Entity_Id(value.instance)!=root {continue}
        if _,failed:=append(&out,Placed{ids[rows[at]],base.Entity_Id(value.source)});failed!=nil {return nil,.Out_Of_Memory}
    }
    return out[:],.None
}

// The root of the instance placed in this document that an entity is a member of; 0 for none.
scene_entity_instance :: proc(scene:^Scene,entity:base.Entity_Id) -> base.Entity_Id {
    root,_,member:=scene_member(scene,entity)
    if !member {return 0}
    if _,placed:=scene_instance(scene,root);!placed {return 0}
    return root
}

@(private="file")
override_text :: proc(override:^Override) -> string {return serial.text_field(override.path[:])}

// Whether an instance holds this part of a component of an entity on its own.
scene_overridden :: proc(scene:^Scene,entity:base.Entity_Id,component:u64,path:string) -> bool {
    for &override in scene.overrides {
        if override.entity==entity && override.component==component && override.kind==.Field && path_covers(override_text(&override),path) {return true}
    }
    return false
}

@(private="file")
override_find :: proc(scene:^Scene,entity:base.Entity_Id,component:u64,kind:Override_Kind) -> bool {
    for override in scene.overrides {
        if override.entity==entity && override.component==component && override.kind==kind {return true}
    }
    return false
}

// Whether an entity can hold an override of a kind: a member of an instance
// or, for Child, an entity under a member that its instance did not place.
@(private="file")
override_placed :: proc(scene:^Scene,entity:base.Entity_Id,kind:Override_Kind) -> bool {
    if kind!=.Child {return scene_entity_instance(scene,entity)!=0}
    row,found:=scene_entity_find(scene,entity)
    if !found {return false}
    root:=scene_entity_instance(scene,scene_parents(scene)[row])
    return root!=0 && scene_entity_instance(scene,entity)!=root
}

// Whether an override takes the place of another of the same entity: a value
// those of the parts inside it, the presence of a component every override
// of it, and the rest the one they repeat.
@(private="file")
override_replaces :: proc(added:Override,path:string,other:^Override) -> bool {
    if other.component!=added.component {return false}
    switch added.kind {
    case .Field:          return other.kind==.Field && path_covers(path,override_text(other))
    case .Added,.Removed: return other.kind<=.Turned
    case .Turned,.Child:  return other.kind==added.kind
    }
    return false
}

// Records that the instance of an entity holds something on its own. Field:
// the part of the component the path names, which replaces the overrides of
// the parts inside it. Added and Removed: the presence of the component,
// which replaces every override it had. Turned: whether it is on. Child: the
// entity, placed under a member, with component 0.
scene_override_add :: proc(scene:^Scene,entity:base.Entity_Id,component:u64,path:string,kind:=Override_Kind.Field) -> Error {
    added:=Override{entity=entity,component=component,kind=kind}
    if !override_placed(scene,entity,kind) || len(path)>=OVERRIDE_PATH_BYTES || kind!=.Field && path!="" || !override_valid(added) {return .Invalid}
    if kind==.Field {
        for &override in scene.overrides {
            if override.entity==entity && override.component==component && override.kind==.Field && path_covers(override_text(&override),path) {return .None}
        }
    }
    left:=0
    for &override in scene.overrides {
        if override.entity==entity && override_replaces(added,path,&override) {continue}
        scene.overrides[left]=override
        left+=1
    }
    base.truncate(&scene.overrides,left)
    copy(added.path[:],path)
    if _,failed:=append(&scene.overrides,added);failed!=nil {return .Out_Of_Memory}
    return .None
}

// Forgets an override: the next update gives what the prefab has back.
scene_override_remove :: proc(scene:^Scene,entity:base.Entity_Id,component:u64,path:string,kind:=Override_Kind.Field) -> bool {
    for &override,at in scene.overrides {
        if override.entity==entity && override.component==component && override.kind==kind && override_text(&override)==path {
            ordered_remove(&scene.overrides,at)
            return true
        }
    }
    return false
}

// Copies the components of prefab entities to their counterparts, the two of
// the instances aside. keep: what the overrides of the scene name stays as
// it is, and root keeps its placement.
@(private="file")
components_copy :: proc(scene:^Scene,prefab:^Scene,remap:^map[base.Entity_Id]base.Entity_Id,keep:bool,root:=base.Entity_Id(0)) -> Error {
    allocator:=scene.doc.allocator
    refs:=make([dynamic]serial.Ref,allocator);defer delete(refs)
    image:=make([dynamic]u8,allocator);defer delete(image)
    link:serial.Schema_Import
    document_import_begin(&scene.doc,&link,&prefab.doc.schema)
    defer serial.schema_import_destroy(&link)
    for at in 1..<len(prefab.doc.tables) {
        source:=&prefab.doc.tables[at]
        if len(source.columns)!=2 || source.columns[0].name!=COLUMN_ENTITY || source.columns[0].ref!=0 || source.columns[1].name!=COLUMN_VALUE || membership_hash(source.name_hash) {continue}
        table:=scene_component_add(scene,source.name,&prefab.doc.schema,source.columns[1].type) or_return
        type:=scene.doc.tables[table].columns[1].type
        size:=scene.doc.tables[table].columns[1].size
        migration:serial.Migration
        migration_error:=serial.migration_init(&migration,&prefab.doc.schema,source.columns[1].type,&scene.doc.schema,type,allocator)
        defer serial.migration_destroy(&migration)
        if migration_error!=.None {return migration_error==.Out_Of_Memory?.Out_Of_Memory:.Invalid}
        clear(&refs)
        if !serial.refs_collect(&scene.doc.schema,type,&refs,MAX_REFS) {return .Invalid}
        if resize(&image,size)!=nil {return .Out_Of_Memory}
        ids:=scene_ids(prefab)
        placement:=keep && source.name_hash==base.name_hash(INSTANCE_PLACEMENT)
        for entity_row,row in mem_rows(source) {
            entity,present:=remap[ids[entity_row]]
            if !present || placement && entity==root {continue}
            if keep && override_find(scene,entity,source.name_hash,.Removed) {continue}
            serial.migration_apply(&migration,image[:],source.columns[1].data[row*source.columns[1].size:],1)
            for ref in refs {
                if ref.kind==.Asset {continue}
                target:=(^u64)(&image[ref.offset])
                value:=intrinsics.unaligned_load(target)
                if value==0 {continue}
                intrinsics.unaligned_store(target,u64(remap[base.Entity_Id(value)]))
            }
            if keep {
                // What the instance holds on its own stays over what the prefab says.
                if current,has:=scene_component_get(scene,table,entity);has {
                    for &override in scene.overrides {
                        if override.entity!=entity || override.component!=source.name_hash || override.kind!=.Field {continue}
                        override_keep(&scene.doc.schema,type,current,image[:],override_text(&override))
                    }
                }
            }
            scene_component_set(scene,table,entity,image[:]) or_return
            if !keep || !override_find(scene,entity,source.name_hash,.Turned) {
                scene_component_turn(scene,entity,source.name_hash,scene_component_off(prefab,ids[entity_row],source.name_hash)) or_return
            }
        }
    }
    return .None
}

@(private="file")
mem_rows :: proc(table:^Doc_Table) -> []u32 {
    return ([^]u32)(raw_data(table.columns[0].data))[:table.rows]
}

// Copies entities of src with their components into dst, each with the id
// remap gives it, under the copy of its parent or, outside them, at the top:
// a prefab made of part of a scene. Their references to entities that are
// not copied are emptied, and they are members of no instance.
scene_copy :: proc(dst,src:^Scene,remap:^map[base.Entity_Id]base.Entity_Id) -> Error {
    if dst==src {return .Invalid}
    for row in 0..<scene_entity_count(src) {
        record:=scene_entity(src,row)
        id,present:=remap[record.id]
        if !present {continue}
        parent:=remap[record.parent] or_else 0
        if parent!=0 && !(parent in dst.index) {return .Invalid}
        scene_entity_add(dst,id,parent,record.name,int(record.order)) or_return
    }
    return components_copy(dst,src,remap,false)
}

// The Id of the entity an instance creates for an entity its prefab gained:
// the same wherever the same update runs, so the ends of a session and a
// load agree on it.
@(private="file")
member_id :: proc(scene:^Scene,root,source:base.Entity_Id) -> base.Entity_Id {
    id:=base.Entity_Id(base.hash_combine(u64(root),u64(source)))
    if id==0 || id in scene.index {return scene_new_id(scene)}
    return id
}

// Makes entities of the scene an instance of the prefab: members gives, for
// each entity of the prefab, the one that stands for it, and the root of the
// prefab the root of the instance. What they hold apart from the prefab
// becomes overrides of the instance; the root's parent, order and placement
// are its own.
scene_instance_adopt :: proc(scene:^Scene,prefab:^Scene,prefab_id:base.Asset_Id,members:^map[base.Entity_Id]base.Entity_Id) -> (root:base.Entity_Id,error:Error) {
    root_source,has_root:=prefab_root(prefab)
    if !has_root || scene==prefab || len(members)!=scene_entity_count(prefab) {return 0,.Invalid}
    ids,parents:=scene_ids(prefab),scene_parents(prefab)
    taken,no_taken:=make(map[base.Entity_Id]bool,len(members),context.temp_allocator)
    if no_taken!=nil {return 0,.Out_Of_Memory}
    for source,prefab_row in ids {
        entity,present:=members[source]
        row,in_scene:=scene_entity_find(scene,entity)
        if !present || !in_scene || entity in taken {return 0,.Invalid}
        if source!=root_source && scene_parents(scene)[row]!=members[parents[prefab_row]] {return 0,.Invalid}
        taken[entity]=true
    }
    root=members[root_source]
    scene_instance_set(scene,root,{prefab=prefab_id,stamp=prefab.stamp}) or_return
    for source in ids {scene_member_set(scene,members[source],root,source) or_return}
    scene_instance_overrides(&scene.overrides,scene,root,prefab) or_return
    return root,.None
}

// Places a prefab under a parent, 0 for none.
scene_instantiate :: proc(scene:^Scene,prefab:^Scene,prefab_id:base.Asset_Id,parent:base.Entity_Id) -> (root:base.Entity_Id,error:Error) {
    root_source,has_root:=prefab_root(prefab)
    if !has_root || scene==prefab {return 0,.Invalid}
    if parent!=0 && !(parent in scene.index) {return 0,.Not_Found}
    remap,no_remap:=make(map[base.Entity_Id]base.Entity_Id,scene_entity_count(prefab),scene.doc.allocator)
    defer delete(remap)
    if no_remap!=nil {return 0,.Out_Of_Memory}
    first:=scene_entity_count(scene)
    for row in 0..<scene_entity_count(prefab) {
        record:=scene_entity(prefab,row)
        id:=scene_new_id(scene)
        _,error=scene_entity_add(scene,id,0,record.name,int(record.order))
        if error!=.None {
            _,_=scene_entities_remove(scene,scene_ids(scene)[first:],false)
            return 0,error
        }
        remap[record.id]=id
    }
    root=remap[root_source]
    order:=u32(0)
    for other,row in scene_parents(scene)[:first] {
        if other==parent {order=max(order,scene_orders(scene)[row]+1)}
    }
    for row in 0..<scene_entity_count(prefab) {
        source:=scene_entity(prefab,row)
        if source.id==root_source {scene_parents(scene)[first+row],scene_orders(scene)[first+row]=parent,order}
        else {scene_parents(scene)[first+row]=remap[source.parent]}
    }
    error=components_copy(scene,prefab,&remap,false)
    if error==.None {error=scene_instance_set(scene,root,{prefab=prefab_id,stamp=prefab.stamp})}
    if error==.None {
        for id in scene_ids(prefab) {
            if error=scene_member_set(scene,remap[id],root,id);error!=.None {break}
        }
    }
    if error!=.None {
        _,_=scene_entities_remove(scene,scene_ids(scene)[first:],false)
        return 0,error
    }
    return root,.None
}

// Brings an instance up to date with its prefab: members, hierarchy, names
// and components follow the prefab, except what the instance overrides. A
// member that leaves takes with it what the instance added under it.
scene_instance_update :: proc(scene:^Scene,root:base.Entity_Id,prefab:^Scene) -> Error {
    instance,placed:=scene_instance(scene,root)
    root_source,has_root:=prefab_root(prefab)
    if !placed || !has_root || scene==prefab {return .Invalid}
    allocator:=scene.doc.allocator
    remap:=make(map[base.Entity_Id]base.Entity_Id,allocator);defer delete(remap)
    vanished:=make([dynamic]base.Entity_Id,allocator);defer delete(vanished)
    members:=scene_instance_members(scene,root) or_return
    for member in members {
        if member.source in prefab.index {remap[member.source]=member.entity}
        else {append(&vanished,member.entity)}
    }
    if mapped,known:=remap[root_source];!known || mapped!=root {return .Invalid}
    for id,row in scene_ids(prefab) {
        if id in remap {continue}
        created:=member_id(scene,root,id)
        scene_entity_add(scene,created,0,scene_entity(prefab,row).name,int(scene_orders(prefab)[row])) or_return
        remap[id]=created
        scene_member_set(scene,created,root,id) or_return
    }
    for row in 0..<scene_entity_count(prefab) {
        source:=scene_entity(prefab,row)
        target:=int(scene.index[remap[source.id]])
        if source.id!=root_source {scene_parents(scene)[target],scene_orders(scene)[target]=remap[source.parent],source.order}
        if !scene_overridden(scene,remap[source.id],0,"name") {
            scene_names(scene)[target]={}
            copy(scene_names(scene)[target][:ENTITY_NAME_BYTES-1],source.name)
        }
    }
    // A component the prefab no longer has leaves with it, unless the instance added it.
    placement:=base.name_hash(INSTANCE_PLACEMENT)
    for table in 1..<len(scene.doc.tables) {
        target:=&scene.doc.tables[table]
        if _,is_component:=scene_component(scene,target.name);!is_component || membership_hash(target.name_hash) {continue}
        source,in_prefab:=scene_component_by_hash(prefab,target.name_hash)
        for source_id,entity in remap {
            if entity==root && target.name_hash==placement {continue}
            if _,has:=scene_component_get(scene,table,entity);!has {continue}
            if in_prefab {
                if _,inherited:=scene_component_get(prefab,source,source_id);inherited {continue}
            }
            if !override_find(scene,entity,target.name_hash,.Added) {scene_component_remove(scene,table,entity)}
        }
    }
    components_copy(scene,prefab,&remap,true,root) or_return
    // Every member hangs where the prefab puts it, so what is still under
    // one that leaves is what the instance added there.
    _=scene_entities_remove(scene,vanished[:]) or_return
    instance.stamp=prefab.stamp
    return scene_instance_set(scene,root,instance)
}

// Turns the members of an instance into ordinary entities. With its prefab,
// the instances that prefab placed are given back as instances of this
// document: their members by the source of each, and what the prefab held
// of them on its own beside what this instance did. Without it, or with
// recursive, every member is an ordinary entity.
scene_instance_unlink :: proc(scene:^Scene,root:base.Entity_Id,prefab:^Scene=nil,recursive:=false) -> Error {
    if _,placed:=scene_instance(scene,root);!placed || scene==prefab {return .Invalid}
    members:=scene_instance_members(scene,root) or_return
    remap:=make(map[base.Entity_Id]base.Entity_Id,len(members),context.temp_allocator)
    for member in members {remap[member.source]=member.entity}
    membership_remove(scene,COMPONENT_INSTANCE,root)
    given:=prefab!=nil && !recursive
    linked:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for member in members {
        inner_root,inner_source,inner:=base.Entity_Id(0),base.Entity_Id(0),false
        if given {
            inner_root,inner_source,inner=scene_member(prefab,member.source)
            if inner {
                _,inner=scene_instance(prefab,inner_root)
                inner&&=inner_root in remap
            }
        }
        if inner {
            scene_member_set(scene,member.entity,remap[inner_root],inner_source) or_return
            linked[member.entity]=true
        } else {
            membership_remove(scene,COMPONENT_MEMBER,member.entity)
        }
    }
    if given {
        rows,values:=instance_rows(prefab) or_return
        for value,at in values {
            if entity,placed:=remap[scene_ids(prefab)[rows[at]]];placed && linked[entity] {scene_instance_set(scene,entity,value) or_return}
        }
    }
    // The overrides of what is no longer of an instance go; those the prefab held come.
    was:=make(map[base.Entity_Id]bool,len(members),context.temp_allocator)
    for member in members {was[member.entity]=true}
    left:=0
    for override in scene.overrides {
        row,exists:=scene_entity_find(scene,override.entity)
        if !exists {continue}
        about:=override.kind==.Child?scene_parents(scene)[row]:override.entity
        if was[about] && !linked[about] {continue}
        scene.overrides[left]=override
        left+=1
    }
    base.truncate(&scene.overrides,left)
    if given {
        each: for override in prefab.overrides {
            entity,placed:=remap[override.entity]
            if !placed {continue}
            copied:=override
            copied.entity=entity
            for known in scene.overrides {
                if known==copied {continue each}
            }
            if _,failed:=append(&scene.overrides,copied);failed!=nil {return .Out_Of_Memory}
        }
    }
    return .None
}

// Removes an instance with every entity it placed.
scene_instance_remove :: proc(scene:^Scene,root:base.Entity_Id) -> Error {
    if _,placed:=scene_instance(scene,root);!placed {return .Invalid}
    members:=scene_instance_members(scene,root) or_return
    ids:=make([]base.Entity_Id,len(members),context.temp_allocator)
    for member,at in members {ids[at]=member.entity}
    _=scene_entities_remove(scene,ids,false) or_return
    return .None
}

// Drops what is of no instance: the members whose root is not one, the
// overrides of an entity no instance placed, and what was off of entities
// that are gone.
@(private)
scene_records_prune :: proc(scene:^Scene) {
    if rows,values,error:=member_rows(scene);error==.None && len(rows)>0 {
        roots,_:=membership(scene,COMPONENT_INSTANCE,Prefab_Instance)
        table,_:=document_table(&scene.doc,COMPONENT_MEMBER)
        ids:=scene_ids(scene)
        left:=0
        for value,at in values {
            placed:=false
            if roots>=0 {_,placed=scene_component_get(scene,roots,base.Entity_Id(value.instance))}
            if !placed || int(rows[at])>=len(ids) {continue}
            rows[left],values[left]=rows[at],value
            left+=1
        }
        if left!=len(rows) {document_resize(&scene.doc,table,left)}
    }
    left:=0
    for override in scene.overrides {
        if !override_placed(scene,override.entity,override.kind) {continue}
        scene.overrides[left]=override
        left+=1
    }
    base.truncate(&scene.overrides,left)
    left=0
    for record in scene.off {
        if !(record.entity in scene.index) {continue}
        scene.off[left]=record
        left+=1
    }
    base.truncate(&scene.off,left)
}

// ---------------------------------------------------- entities an instance added

// The members of an instance: entity of the document -> entity of the prefab.
@(private="file")
members_of :: proc(scene:^Scene,root:base.Entity_Id) -> map[base.Entity_Id]base.Entity_Id {
    sources:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    members,_:=scene_instance_members(scene,root)
    for member in members {sources[member.entity]=member.source}
    return sources
}

// An entity an instance added and what is under it that is not a member,
// each after its parent.
@(private="file")
added_subtree :: proc(scene:^Scene,entity:base.Entity_Id,sources:map[base.Entity_Id]base.Entity_Id) -> []base.Entity_Id {
    found:=make([dynamic]base.Entity_Id,context.temp_allocator)
    within:=make(map[base.Entity_Id]bool,context.temp_allocator)
    append(&found,entity)
    within[entity]=true
    ids,parents:=scene_ids(scene),scene_parents(scene)
    for changed:=true;changed; {
        changed=false
        for id,row in ids {
            if id in within || id in sources || !(parents[row] in within) {continue}
            within[id]=true
            append(&found,id)
            changed=true
        }
    }
    return found[:]
}

@(private="file")
placed_check :: proc(scene:^Scene,root:base.Entity_Id,prefab:^Scene) -> bool {
    _,placed:=scene_instance(scene,root)
    return placed && scene!=prefab
}

// Writes into the prefab of an instance an entity the instance added under
// a member, with what is under it that is not a member: new entities of the
// prefab with their names, places, components and the instances placed
// among them, their references to each other and to members kept. They
// become members of the instance, and those instances the prefab's own.
// .Not_Found when the entity does not hang from a member.
scene_child_apply :: proc(scene:^Scene,root:base.Entity_Id,entity:base.Entity_Id,prefab:^Scene) -> Error {
    row,found:=scene_entity_find(scene,entity)
    if !placed_check(scene,root,prefab) || !found {return .Invalid}
    sources:=members_of(scene,root)
    if entity in sources {return .Invalid}
    parent,inside:=sources[scene_parents(scene)[row]]
    if !inside {return .Not_Found}
    subtree:=added_subtree(scene,entity,sources)
    within:=make(map[base.Entity_Id]bool,len(subtree),context.temp_allocator)
    for id in subtree {
        within[id]=true
        sources[id]=scene_new_id(prefab)
    }
    for id in subtree {
        record:=scene_entity(scene,int(scene.index[id]))
        scene_entity_add(prefab,sources[id],id==entity?parent:sources[record.parent],record.name,int(record.order)) or_return
    }
    allocator:=scene.doc.allocator
    refs:=make([dynamic]serial.Ref,allocator);defer delete(refs)
    image:=make([dynamic]u8,allocator);defer delete(image)
    for table in 1..<len(scene.doc.tables) {
        from:=&scene.doc.tables[table]
        if _,is_component:=scene_component(scene,from.name);!is_component {continue}
        target:=-1
        migration:serial.Migration
        defer serial.migration_destroy(&migration)
        for id in subtree {
            stored,has:=scene_component_get(scene,table,id)
            if !has {continue}
            if target<0 {
                target=scene_component_add(prefab,from.name,&scene.doc.schema,from.columns[1].type) or_return
                type:=prefab.doc.tables[target].columns[1].type
                if error:=serial.migration_init(&migration,&scene.doc.schema,from.columns[1].type,&prefab.doc.schema,type,allocator);error!=.None {return error==.Out_Of_Memory?.Out_Of_Memory:.Invalid}
                clear(&refs)
                if !serial.refs_collect(&prefab.doc.schema,type,&refs,MAX_REFS) {return .Invalid}
                if resize(&image,prefab.doc.tables[target].columns[1].size)!=nil {return .Out_Of_Memory}
            }
            serial.migration_apply(&migration,image[:],stored,1)
            for ref in refs {
                if ref.kind==.Asset {continue}
                place:=(^u64)(&image[ref.offset])
                if value:=intrinsics.unaligned_load(place);value!=0 {intrinsics.unaligned_store(place,u64(sources[base.Entity_Id(value)]))}
            }
            scene_component_set(prefab,target,sources[id],image[:]) or_return
            scene_component_turn(prefab,sources[id],from.name_hash,scene_component_off(scene,id,from.name_hash)) or_return
        }
    }
    // What the instances placed among them held on their own is the prefab's to keep.
    left:=0
    for override in scene.overrides {
        if within[override.entity] {
            copied:=override
            copied.entity=sources[override.entity]
            if _,failed:=append(&prefab.overrides,copied);failed!=nil {return .Out_Of_Memory}
            continue
        }
        scene.overrides[left]=override
        left+=1
    }
    base.truncate(&scene.overrides,left)
    for id in subtree {
        membership_remove(scene,COMPONENT_INSTANCE,id)
        scene_member_set(scene,id,root,sources[id]) or_return
    }
    return .None
}

// Removes an entity an instance added under a member, with what is under it.
scene_child_revert :: proc(scene:^Scene,root:base.Entity_Id,entity:base.Entity_Id) -> Error {
    if !placed_check(scene,root,nil) || !(entity in scene.index) {return .Invalid}
    sources:=members_of(scene,root)
    if entity in sources {return .Invalid}
    _=scene_entities_remove(scene,added_subtree(scene,entity,sources),false) or_return
    return .None
}

// ------------------------------------------------------------------ resolution

// Where instances find their prefabs: the open file of each, by id, which
// outlives the resolution; nil when there is none, and Out_Of_Memory when
// there is one and no memory to open it.
Prefab_Files :: struct {
    data:rawptr,
    open:proc(data:rawptr,id:base.Asset_Id) -> (^Asset,Error),
}

Resolve_State :: enum u8 {
    Checking, // being looked at: a prefab that holds itself
    Current,  // every instance its file holds is up to date
    Stale,    // an instance its file holds is not: it is not what it resolves to
    Missing,  // no file of a prefab has the id
}

Resolved_Prefab :: struct {
    state:Resolve_State,
    stamp:u64,    // its content hash as resolved: of its file when Current, of what it resolves to when Stale
    scene:^Scene, // its document with its instances up to date, once it was resolved or an instance asked for it
}

// The prefabs a resolution looked at, by id: which instances of a document
// are stale, and the prefabs that bring them up to date. Each file is read
// once.
Prefab_Resolver :: struct {
    types:^Types,
    files:Prefab_Files,
    prefabs:map[base.Asset_Id]Resolved_Prefab,
    // Why a prefab that is there was not opened, from then on: its instances
    // read as up to date, and resolver_prefab and scene_resolve answer it.
    error:Error,
    allocator:runtime.Allocator,
}

resolver_init :: proc(r:^Prefab_Resolver,types:^Types,files:Prefab_Files,allocator:=context.allocator) {
    r^={types=types,files=files,allocator=allocator}
    r.prefabs=make(map[base.Asset_Id]Resolved_Prefab,allocator)
}

resolver_destroy :: proc(r:^Prefab_Resolver) {
    for _,p in r.prefabs {
        if p.scene!=nil {
            scene_destroy(p.scene)
            free(p.scene,r.allocator)
        }
    }
    delete(r.prefabs)
    r^={}
}

// The instances of an open document: the file itself, or a copy in
// temporary memory when it stores another layout.
@(private="file")
instances_of :: proc(a:^Asset,types:^Types) -> []Prefab_Instance {
    table,found:=asset_table(a,COMPONENT_INSTANCE)
    if !found || len(table.columns)!=2 || table.rows==0 {return nil}
    index,known:=types_index(types,Prefab_Instance)
    if !known {return nil}
    if asset_column_matches(a,table,1,types.hashes[index]) {
        data,error:=asset_column_data(a,table,1)
        if error==.None && uintptr(raw_data(data))&uintptr(align_of(Prefab_Instance)-1)==0 {return mem.slice_data_cast([]Prefab_Instance,data)}
    }
    rows,error:=make([]Prefab_Instance,table.rows,context.temp_allocator)
    if error!=nil || asset_column_read(a,table,1,&types.schema,index,mem.slice_to_bytes(rows))!=.None {return nil}
    return rows
}

// What a prefab is to its instances.
resolver_check :: proc(r:^Prefab_Resolver,id:base.Asset_Id) -> Resolved_Prefab {
    if known,found:=r.prefabs[id];found {return known}
    r.prefabs[id]={state=.Checking}
    checked:=Resolved_Prefab{state=.Missing}
    file,error:=r.files.open(r.files.data,id)
    if error!=.None {
        r.error=error
        delete_key(&r.prefabs,id)
        return checked
    }
    if file!=nil && asset_prefab(file) {
        checked.stamp=file.blob.header.content_hash
        checked.state=resolver_instances_stale(r,instances_of(file,r.types))?.Stale:.Current
        if checked.state==.Stale {
            // What it resolves to has another content, and that is what its instances follow.
            if prefab,failed:=resolver_resolve(r,file);failed==.None {
                checked.scene,checked.stamp=prefab,prefab.stamp
            } else {
                r.error=failed
            }
        }
    }
    r.prefabs[id]=checked
    return checked
}

// A prefab whose file holds stale instances, with them up to date and the
// stamp of the file that would hold it so.
@(private="file")
resolver_resolve :: proc(r:^Prefab_Resolver,file:^Asset) -> (prefab:^Scene,error:Error) {
    no_scene:runtime.Allocator_Error
    if prefab,no_scene=new(Scene,r.allocator);no_scene!=nil {return nil,.Out_Of_Memory}
    if error=scene_from_asset(prefab,r.types,file,r.allocator);error==.None {
        if _,error=scene_resolve(r,prefab);error==.None {
            data:[]u8
            // Encoding gives the scene the stamp of its bytes.
            if data,error=scene_bytes(prefab,r.allocator);error==.None {mem.free_bytes(data,r.allocator)}
        }
        if error!=.None {scene_destroy(prefab)}
    }
    if error!=.None {
        free(prefab,r.allocator)
        return nil,error
    }
    return prefab,.None
}

// Whether an instance placed in a document is not what its prefab gives
// now: its stamp is not that of the prefab as resolved. One of a prefab that
// is missing, or that holds itself, stays as it is.
resolver_instance_stale :: proc(r:^Prefab_Resolver,instance:Prefab_Instance) -> bool {
    p:=resolver_check(r,instance.prefab)
    return (p.state==.Current || p.state==.Stale) && instance.stamp!=p.stamp
}

@(private="file")
resolver_instances_stale :: proc(r:^Prefab_Resolver,instances:[]Prefab_Instance) -> bool {
    for instance in instances {
        if resolver_instance_stale(r,instance) {return true}
    }
    return false
}

// Whether an open document holds a stale instance. Prefab_Resolver.error
// tells when a prefab could not be asked.
resolver_stale :: proc(r:^Prefab_Resolver,a:^Asset) -> bool {
    return resolver_instances_stale(r,instances_of(a,r.types))
}

// How deep a prefab is followed through the prefabs it places.
PREFAB_DEPTH :: 16

// Whether a prefab holds another: it is that one, or places it, itself or
// through the prefabs it places. One deeper than PREFAB_DEPTH holds it.
prefab_holds :: proc(files:Prefab_Files,types:^Types,id,target:base.Asset_Id,depth:=0) -> (holds:bool,error:Error) {
    if id==target || depth>PREFAB_DEPTH {return true,.None}
    file:=files.open(files.data,id) or_return
    if file==nil || !asset_prefab(file) {return false,.None}
    for instance in instances_of(file,types) {
        if prefab_holds(files,types,instance.prefab,target,depth+1) or_return {return true,.None}
    }
    return false,.None
}

// A prefab with its instances up to date, which the resolver keeps; nil when
// it is missing.
resolver_prefab :: proc(r:^Prefab_Resolver,id:base.Asset_Id) -> (prefab:^Scene,error:Error) {
    checked:=resolver_check(r,id)
    if r.error!=.None {return nil,r.error}
    if checked.state!=.Current && checked.state!=.Stale {return nil,.None}
    if checked.scene!=nil {return checked.scene,.None}
    file:=r.files.open(r.files.data,id) or_return
    if file==nil {return nil,.None}
    kept:=&r.prefabs[id]
    if kept==nil {return nil,.Out_Of_Memory}
    if checked.state==.Stale {
        // Its resolved document was given away: it is resolved again, to the same stamp.
        prefab=resolver_resolve(r,file) or_return
        kept.scene=prefab
        return prefab,.None
    }
    no_scene:runtime.Allocator_Error
    if prefab,no_scene=new(Scene,r.allocator);no_scene!=nil {return nil,.Out_Of_Memory}
    if error=scene_from_asset(prefab,r.types,file,r.allocator);error!=.None {
        free(prefab,r.allocator)
        return nil,error
    }
    kept.scene=prefab
    return prefab,.None
}

// resolver_prefab, given to the caller, who destroys it and frees it with
// the allocator of the resolver.
resolver_take :: proc(r:^Prefab_Resolver,id:base.Asset_Id) -> (prefab:^Scene,error:Error) {
    prefab=resolver_prefab(r,id) or_return
    if prefab!=nil {(&r.prefabs[id]).scene=nil}
    return prefab,.None
}

// Brings every stale instance placed in a document up to date with its
// prefab. changed: one was.
scene_resolve :: proc(r:^Prefab_Resolver,scene:^Scene) -> (changed:bool,error:Error) {
    stale:=make([dynamic]base.Entity_Id,context.temp_allocator)
    rows,values:=instance_rows(scene) or_return
    for value,at in values {
        if resolver_instance_stale(r,value) {append(&stale,scene_ids(scene)[rows[at]])}
    }
    if r.error!=.None {return false,r.error}
    for root in stale {
        instance,placed:=scene_instance(scene,root)
        if !placed {continue}
        prefab:=resolver_prefab(r,instance.prefab) or_return
        if prefab==nil || prefab==scene {continue}
        scene_instance_update(scene,root,prefab) or_return
        changed=true
    }
    return
}

// Prefab files of a registry, read when a resolution asks for them and kept
// open until registry_prefabs_destroy.
Registry_Prefabs :: struct {
    registry:^Registry,
    opened:map[base.Asset_Id]^Asset,
    allocator:runtime.Allocator,
}

registry_prefabs_init :: proc(files:^Registry_Prefabs,registry:^Registry,allocator:=context.allocator) {
    files^={registry=registry,allocator=allocator}
    files.opened=make(map[base.Asset_Id]^Asset,allocator)
}

registry_prefabs_destroy :: proc(files:^Registry_Prefabs) {
    for _,a in files.opened {
        if a==nil {continue}
        asset_close(a)
        free(a,files.allocator)
    }
    delete(files.opened)
    files^={}
}

registry_prefab_files :: proc(files:^Registry_Prefabs) -> Prefab_Files {
    open :: proc(data:rawptr,id:base.Asset_Id) -> (^Asset,Error) {
        files:=(^Registry_Prefabs)(data)
        if opened,known:=files.opened[id];known {return opened,.None}
        a:^Asset
        if file,found:=registry_find(files.registry,id);found && registry_prefab(file) {
            no_asset:runtime.Allocator_Error
            if a,no_asset=new(Asset,files.allocator);no_asset!=nil {return nil,.Out_Of_Memory}
            // What the registry holds of it unsaved, else the disk.
            data,error:=registry_read(files.registry,file.path,files.allocator)
            if error==.None {error=asset_take(a,data,files.allocator)}
            if error!=.None {
                free(a,files.allocator)
                // A file that cannot be read is no prefab; one there was no memory for is asked again.
                if error==.Out_Of_Memory {return nil,.Out_Of_Memory}
                a=nil
            }
        }
        if reserve(&files.opened,len(files.opened)+1)!=nil {
            if a!=nil {
                asset_close(a)
                free(a,files.allocator)
            }
            return nil,.Out_Of_Memory
        }
        files.opened[id]=a
        return a,.None
    }
    return {files,open}
}
