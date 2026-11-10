package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Prefab instances inside a scene or another prefab.
//
// Instantiating copies the entities of the prefab with new ids, points their
// references to each other at the copies and empties those that pointed
// outside the prefab. The instance keeps, as members, which entity stands
// for which entity of the prefab, and as overrides what it set on its own:
// values and components, and the entities it added under its members.
// Updating adds and removes members with the prefab, and gives every member
// the parent, order, name and components the prefab has, except for what an
// override names. The parent, order and placement of the root
// (INSTANCE_PLACEMENT) belong to the instance.
//
// The prefabs a prefab contains come along as instances of their own, marked
// with the instance that brought them in; their overrides are part of what
// the outer prefab defines, and an update of the outer instance brings them
// again.
//
// An instance placed in a document is stale when its stamp is not the
// content hash of the file of its prefab, or when that prefab holds a stale
// instance itself; Prefab_Resolver finds them and brings them up to date.

// The component that places the root of an instance: the instance's, never the prefab's.
INSTANCE_PLACEMENT :: "Transform"

// Whether a path names the part another names, or a part that contains it.
path_covers :: proc(path,part:string) -> bool {
    if path=="" || path==part {return true}
    return len(part)>len(path) && part[:len(path)]==path && (part[len(path)]=='.' || part[len(path)]=='[')
}

// The entity an instance of a prefab places: its root when it says one, or
// its only entity without parent.
prefab_root :: proc(prefab:^Scene) -> (root:base.Entity_Id,found:bool) {
    if prefab.info.root!=0 {return prefab.info.root,prefab.info.root in prefab.index}
    for parent,row in scene_parents(prefab) {
        if parent!=0 {continue}
        if root!=0 {return 0,false}
        root=scene_ids(prefab)[row]
    }
    return root,root!=0
}

// The base of a variant: the prefab its root is an instance of, placed in it,
// with that instance; none when the prefab is not a variant.
prefab_variant_base :: proc(prefab:^Scene) -> (instance:u32,base_prefab:base.Asset_Id) {
    root,found:=prefab_root(prefab)
    if !found {return}
    for candidate in prefab.instances {
        if candidate.outer==0 && candidate.root==root {return candidate.id,candidate.prefab}
    }
    return
}

// The instance placed in this document that an entity is a member of; 0 for none.
scene_entity_instance :: proc(scene:^Scene,entity:base.Entity_Id) -> u32 {
    for member in scene.members {
        if member.entity!=entity {continue}
        if at:=scene_instance_find(scene,member.instance);at>=0 && scene.instances[at].outer==0 {return member.instance}
    }
    return 0
}

@(private="file")
override_text :: proc(override:^Override) -> string {return serial.text_field(override.path[:])}

// Whether an instance holds this part of a component of an entity on its own.
scene_overridden :: proc(scene:^Scene,entity:base.Entity_Id,component:u64,path:string) -> bool {
    instance:=scene_entity_instance(scene,entity)
    if instance==0 {return false}
    for &override in scene.overrides {
        if override.instance==instance && override.entity==entity && override.component==component && override.kind==.Field && path_covers(override_text(&override),path) {return true}
    }
    return false
}

@(private="file")
override_find :: proc(scene:^Scene,instance:u32,entity:base.Entity_Id,component:u64,kind:Override_Kind) -> bool {
    for override in scene.overrides {
        if override.instance==instance && override.entity==entity && override.component==component && override.kind==kind {return true}
    }
    return false
}

// The instance placed in this document an override of an entity belongs to:
// the one of the member or, for Child, the one of the member it hangs from,
// which the entity is not a member of.
@(private="file")
override_instance :: proc(scene:^Scene,entity:base.Entity_Id,kind:Override_Kind) -> u32 {
    if kind!=.Child {return scene_entity_instance(scene,entity)}
    row,found:=scene_entity_find(scene,entity)
    if !found {return 0}
    instance:=scene_entity_instance(scene,scene_parents(scene)[row])
    for member in scene.members {
        if member.instance==instance && member.entity==entity {return 0}
    }
    return instance
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
    instance:=override_instance(scene,entity,kind)
    added:=Override{instance=instance,entity=entity,component=component,kind=kind}
    if instance==0 || len(path)>=OVERRIDE_PATH_BYTES || kind!=.Field && path!="" || !override_valid(added) {return .Invalid}
    if kind==.Field {
        for &override in scene.overrides {
            if override.instance==instance && override.entity==entity && override.component==component && override.kind==.Field && path_covers(override_text(&override),path) {return .None}
        }
    }
    left:=0
    for &override in scene.overrides {
        if override.instance==instance && override.entity==entity && override_replaces(added,path,&override) {continue}
        scene.overrides[left]=override
        left+=1
    }
    base.truncate(&scene.overrides,left)
    copy(added.path[:],path)
    append(&scene.overrides,added)
    return .None
}

// Forgets an override: the next update gives what the prefab has back.
scene_override_remove :: proc(scene:^Scene,entity:base.Entity_Id,component:u64,path:string,kind:=Override_Kind.Field) -> bool {
    instance:=override_instance(scene,entity,kind)
    for &override,at in scene.overrides {
        if override.instance==instance && override.entity==entity && override.component==component && override.kind==kind && override_text(&override)==path {
            ordered_remove(&scene.overrides,at)
            return true
        }
    }
    return false
}

// Copies the components of prefab entities to their counterparts. keep: the
// instance whose overrides stay as they are in the scene, and whose root
// keeps its placement, or 0 to copy all. adopt: instead of copying, the
// instance that records as overrides what its members hold apart from the
// prefab, its root's placement aside.
@(private="file")
components_copy :: proc(scene:^Scene,prefab:^Scene,remap:^map[base.Entity_Id]base.Entity_Id,keep:u32,root:=base.Entity_Id(0),adopt:=u32(0)) -> Error {
    allocator:=scene.doc.allocator
    refs:=make([dynamic]serial.Ref,allocator);defer delete(refs)
    image:=make([dynamic]u8,allocator);defer delete(image)
    link:serial.Schema_Import
    document_import_begin(&scene.doc,&link,&prefab.doc.schema)
    defer serial.schema_import_destroy(&link)
    for at in 1..<len(prefab.doc.tables) {
        source:=&prefab.doc.tables[at]
        if len(source.columns)!=2 || source.columns[0].name!=COLUMN_ENTITY || source.columns[0].ref!=0 || source.columns[1].name!=COLUMN_VALUE {continue}
        table,found:=document_table(&scene.doc,source.name)
        if !found && adopt!=0 {
            for entity_row in mem_rows(source) {
                if entity,present:=remap[scene_ids(prefab)[entity_row]];present {append(&scene.overrides,Override{instance=adopt,entity=entity,component=source.name_hash,kind=.Removed})}
            }
            continue
        }
        if !found {table=scene_component_add(scene,source.name,&prefab.doc.schema,source.columns[1].type) or_return}
        else if _,is_component:=scene_component(scene,source.name);!is_component {return .Invalid}
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
        placement:=(keep!=0 || adopt!=0) && source.name_hash==base.name_hash(INSTANCE_PLACEMENT)
        for entity_row,row in mem_rows(source) {
            entity,present:=remap[ids[entity_row]]
            if !present || placement && entity==root {continue}
            if keep!=0 && override_find(scene,keep,entity,source.name_hash,.Removed) {continue}
            serial.migration_apply(&migration,image[:],source.columns[1].data[row*source.columns[1].size:],1)
            for ref in refs {
                if ref.kind==.Asset {continue}
                target:=(^u64)(&image[ref.offset])
                value:=intrinsics.unaligned_load(target)
                if value==0 {continue}
                intrinsics.unaligned_store(target,u64(remap[base.Entity_Id(value)]))
            }
            if adopt!=0 {
                current,has:=scene_component_get(scene,table,entity)
                if !has {
                    append(&scene.overrides,Override{instance=adopt,entity=entity,component=source.name_hash,kind=.Removed})
                    continue
                }
                if mem.compare(current,image[:])!=0 {append(&scene.overrides,Override{instance=adopt,entity=entity,component=source.name_hash,kind=.Field})}
                if scene_component_off(scene,entity,source.name_hash)!=scene_component_off(prefab,ids[entity_row],source.name_hash) {
                    append(&scene.overrides,Override{instance=adopt,entity=entity,component=source.name_hash,kind=.Turned})
                }
                continue
            }
            if keep!=0 {
                // What the instance holds on its own stays over what the prefab says.
                if current,has:=scene_component_get(scene,table,entity);has {
                    for &override in scene.overrides {
                        if override.instance!=keep || override.entity!=entity || override.component!=source.name_hash || override.kind!=.Field {continue}
                        override_keep(&scene.doc.schema,type,current,image[:],override_text(&override))
                    }
                }
            }
            scene_component_set(scene,table,entity,image[:]) or_return
            if keep==0 || !override_find(scene,keep,entity,source.name_hash,.Turned) {
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

// Brings the instances a prefab contains, with their members and overrides,
// as instances the given one brought in: those whose root is among the
// entities remap gives.
@(private="file")
nested_copy :: proc(scene:^Scene,prefab:^Scene,remap:^map[base.Entity_Id]base.Entity_Id,instance:u32) -> Error {
    if len(prefab.instances)==0 {return .None}
    ids,no_ids:=make(map[u32]u32,len(prefab.instances),scene.doc.allocator)
    defer delete(ids)
    if no_ids!=nil {return .Out_Of_Memory}
    // An instance has a larger id than the one that brought it in, here too.
    for _ in 0..<len(prefab.instances) {
        added:=false
        for inner in prefab.instances {
            if inner.id in ids || inner.outer!=0 && !(inner.outer in ids) || !(inner.root in remap) {continue}
            scene.info.last_instance+=1
            ids[inner.id]=scene.info.last_instance
            copied:=inner
            copied.id,copied.root,copied.outer=scene.info.last_instance,remap[inner.root],inner.outer==0?instance:ids[inner.outer]
            append(&scene.instances,copied)
            added=true
        }
        if !added {break}
    }
    for member in prefab.members {
        if entity,present:=remap[member.entity];present && member.instance in ids {append(&scene.members,Member{ids[member.instance],member.source,entity})}
    }
    for override in prefab.overrides {
        entity,present:=remap[override.entity]
        if !present || !(override.instance in ids) {continue}
        copied:=override
        copied.instance,copied.entity=ids[override.instance],entity
        append(&scene.overrides,copied)
    }
    return .None
}

// Copies entities of src with their components into dst, each with the id
// remap gives it, under the copy of its parent or, outside them, at the top:
// a prefab made of part of a scene. Their references to entities that are
// not copied are emptied.
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
    return components_copy(dst,src,remap,0)
}

// Makes entities of the scene an instance of the prefab: members gives, for
// each entity of the prefab, the one that stands for it, root the one of
// the prefab's root. What they hold apart from the prefab becomes overrides
// of the instance: names, values, components it adds or lacks and what is
// turned off; the root's parent, order and placement are its own.
scene_instance_adopt :: proc(scene:^Scene,prefab:^Scene,prefab_id:base.Asset_Id,members:^map[base.Entity_Id]base.Entity_Id) -> (instance:u32,error:Error) {
    root_source,has_root:=prefab_root(prefab)
    if !has_root || scene==prefab || len(members)!=scene_entity_count(prefab) {return 0,.Invalid}
    // In the order of the prefab's entities, as scene_instantiate records them.
    ids,parents,names:=scene_ids(prefab),scene_parents(prefab),scene_names(prefab)
    sources,no_sources:=make(map[base.Entity_Id]base.Entity_Id,len(members),scene.doc.allocator)
    defer delete(sources)
    if no_sources!=nil {return 0,.Out_Of_Memory}
    for source,prefab_row in ids {
        entity,present:=members[source]
        row,in_scene:=scene_entity_find(scene,entity)
        if !present || !in_scene || entity in sources {return 0,.Invalid}
        if source!=root_source && scene_parents(scene)[row]!=members[parents[prefab_row]] {return 0,.Invalid}
        sources[entity]=source
    }
    root:=members[root_source]
    scene.info.last_instance+=1
    instance=scene.info.last_instance
    append(&scene.instances,Instance{id=instance,prefab=prefab_id,root=root,stamp=prefab.stamp})
    for source,prefab_row in ids {
        entity:=members[source]
        append(&scene.members,Member{instance,source,entity})
        row,_:=scene_entity_find(scene,entity)
        if scene_names(scene)[row]!=names[prefab_row] {
            named:=Override{instance=instance,entity=entity,kind=.Field}
            copy(named.path[:],"name")
            append(&scene.overrides,named)
        }
    }
    components_copy(scene,prefab,members,0,root,instance) or_return
    for at in 1..<len(scene.doc.tables) {
        table:=&scene.doc.tables[at]
        if _,is_component:=scene_component(scene,table.name);!is_component {continue}
        theirs,found:=document_table(&prefab.doc,table.name)
        for entity_row in mem_rows(table) {
            entity:=scene_ids(scene)[entity_row]
            source,member:=sources[entity]
            if !member {continue}
            if found {
                if _,has:=scene_component_get(prefab,theirs,source);has {continue}
            }
            append(&scene.overrides,Override{instance=instance,entity=entity,component=table.name_hash,kind=.Added})
        }
    }
    return instance,.None
}

// Places a prefab under a parent, 0 for none.
scene_instantiate :: proc(scene:^Scene,prefab:^Scene,prefab_id:base.Asset_Id,parent:base.Entity_Id) -> (instance:u32,root:base.Entity_Id,error:Error) {
    root_source,has_root:=prefab_root(prefab)
    if !has_root || scene==prefab {return 0,0,.Invalid}
    if parent!=0 && !(parent in scene.index) {return 0,0,.Not_Found}
    remap,no_remap:=make(map[base.Entity_Id]base.Entity_Id,scene_entity_count(prefab),scene.doc.allocator)
    defer delete(remap)
    if no_remap!=nil {return 0,0,.Out_Of_Memory}
    first:=scene_entity_count(scene)
    for row in 0..<scene_entity_count(prefab) {
        record:=scene_entity(prefab,row)
        id:=scene_new_id(scene)
        _,error=scene_entity_add(scene,id,0,record.name,int(record.order))
        if error!=.None {
            _,_=scene_entities_remove(scene,scene_ids(scene)[first:],false)
            return 0,0,error
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
    if error=components_copy(scene,prefab,&remap,0);error!=.None {
        _,_=scene_entities_remove(scene,scene_ids(scene)[first:],false)
        return 0,0,error
    }
    scene.info.last_instance+=1
    instance=scene.info.last_instance
    append(&scene.instances,Instance{id=instance,prefab=prefab_id,root=root,stamp=prefab.stamp})
    for id in scene_ids(prefab) {append(&scene.members,Member{instance,id,remap[id]})}
    error=nested_copy(scene,prefab,&remap,instance)
    return instance,root,error
}

// Brings an instance up to date with its prefab: members, hierarchy, names
// and components follow the prefab, except what the instance overrides. A
// member that leaves takes with it what the instance added under it.
scene_instance_update :: proc(scene:^Scene,instance:u32,prefab:^Scene) -> Error {
    at:=scene_instance_find(scene,instance)
    root_source,has_root:=prefab_root(prefab)
    if at<0 || scene.instances[at].outer!=0 || !has_root || scene==prefab {return .Invalid}
    root:=scene.instances[at].root
    allocator:=scene.doc.allocator
    remap:=make(map[base.Entity_Id]base.Entity_Id,allocator);defer delete(remap)
    vanished:=make([dynamic]base.Entity_Id,allocator);defer delete(vanished)
    for member in scene.members {
        if member.instance!=instance {continue}
        if member.source in prefab.index {remap[member.source]=member.entity}
        else {append(&vanished,member.entity)}
    }
    if mapped,known:=remap[root_source];!known || mapped!=root {return .Invalid}
    for id,row in scene_ids(prefab) {
        if id in remap {continue}
        created:=scene_new_id(scene)
        scene_entity_add(scene,created,0,scene_entity(prefab,row).name,int(scene_orders(prefab)[row])) or_return
        remap[id]=created
        append(&scene.members,Member{instance,id,created})
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
        if _,is_component:=scene_component(scene,target.name);!is_component {continue}
        source,in_prefab:=scene_component_by_hash(prefab,target.name_hash)
        for source_id,entity in remap {
            if entity==root && target.name_hash==placement {continue}
            if _,has:=scene_component_get(scene,table,entity);!has {continue}
            if in_prefab {
                if _,inherited:=scene_component_get(prefab,source,source_id);inherited {continue}
            }
            if !override_find(scene,instance,entity,target.name_hash,.Added) {scene_component_remove(scene,table,entity)}
        }
    }
    components_copy(scene,prefab,&remap,instance,root) or_return
    // Every member hangs where the prefab puts it, so what is still under
    // one that leaves is what the instance added there.
    _=scene_entities_remove(scene,vanished[:]) or_return
    for {
        nested:=u32(0)
        for candidate in scene.instances {
            if candidate.outer==instance {nested=candidate.id;break}
        }
        if nested==0 {break}
        scene_instance_forget(scene,nested)
    }
    scene_records_prune(scene)
    nested_copy(scene,prefab,&remap,instance) or_return
    if at=scene_instance_find(scene,instance);at>=0 {scene.instances[at].stamp=prefab.stamp}
    return .None
}

// Turns the members of an instance into ordinary entities. The instances it
// brought in stay, as placed in this document.
scene_instance_unlink :: proc(scene:^Scene,instance:u32) -> Error {
    at:=scene_instance_find(scene,instance)
    if at<0 || scene.instances[at].outer!=0 {return .Invalid}
    for &other in scene.instances {
        if other.outer==instance {other.outer=0}
    }
    ordered_remove(&scene.instances,at)
    scene_records_prune(scene)
    return .None
}

// Removes an instance with every entity it placed.
scene_instance_remove :: proc(scene:^Scene,instance:u32) -> Error {
    at:=scene_instance_find(scene,instance)
    if at<0 || scene.instances[at].outer!=0 {return .Invalid}
    ids:=make([dynamic]base.Entity_Id,scene.doc.allocator);defer delete(ids)
    for member in scene.members {
        if member.instance==instance {append(&ids,member.entity)}
    }
    _=scene_entities_remove(scene,ids[:],false) or_return
    return .None
}

// ---------------------------------------------------- entities an instance added

// The members of an instance: entity of the document -> entity of the prefab.
@(private="file")
members_of :: proc(scene:^Scene,instance:u32) -> map[base.Entity_Id]base.Entity_Id {
    sources:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for member in scene.members {
        if member.instance==instance {sources[member.entity]=member.source}
    }
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
placed_check :: proc(scene:^Scene,instance:u32,prefab:^Scene) -> bool {
    at:=scene_instance_find(scene,instance)
    return at>=0 && scene.instances[at].outer==0 && scene!=prefab
}

// Writes into the prefab of a placed instance an entity the instance added
// under a member, with what is under it that is not a member: new entities
// of the prefab with their names, places, components and the instances
// placed among them, their references to each other and to members kept.
// They become members of the instance; those instances leave its records,
// and the next update brings them back as instances it brought in.
// .Not_Found when the entity does not hang from a member.
scene_child_apply :: proc(scene:^Scene,instance:u32,entity:base.Entity_Id,prefab:^Scene) -> Error {
    row,found:=scene_entity_find(scene,entity)
    if !placed_check(scene,instance,prefab) || !found {return .Invalid}
    sources:=members_of(scene,instance)
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
    // The instances placed among them become the prefab's own.
    renumber:=make(map[u32]u32,context.temp_allocator)
    for _ in 0..<len(scene.instances) {
        added:=false
        for inner in scene.instances {
            if inner.id in renumber || !within[inner.root] || inner.outer!=0 && !(inner.outer in renumber) {continue}
            prefab.info.last_instance+=1
            renumber[inner.id]=prefab.info.last_instance
            copied:=inner
            copied.id,copied.root,copied.outer=prefab.info.last_instance,sources[inner.root],inner.outer==0?0:renumber[inner.outer]
            append(&prefab.instances,copied)
            added=true
        }
        if !added {break}
    }
    for member in scene.members {
        if to,brought:=renumber[member.instance];brought && within[member.entity] {append(&prefab.members,Member{to,member.source,sources[member.entity]})}
    }
    for override in scene.overrides {
        to,brought:=renumber[override.instance]
        if !brought || !within[override.entity] {continue}
        copied:=override
        copied.instance,copied.entity=to,sources[override.entity]
        append(&prefab.overrides,copied)
    }
    for id in subtree {append(&scene.members,Member{instance,sources[id],id})}
    for inner in renumber {
        if at:=scene_instance_find(scene,inner);at>=0 && scene.instances[at].outer==0 {scene_instance_forget(scene,inner)}
    }
    scene_records_prune(scene)
    return .None
}

// Removes an entity a placed instance added under a member, with what is
// under it.
scene_child_revert :: proc(scene:^Scene,instance:u32,entity:base.Entity_Id) -> Error {
    if !placed_check(scene,instance,nil) || !(entity in scene.index) {return .Invalid}
    sources:=members_of(scene,instance)
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
    Current,  // every instance it holds is up to date
    Stale,    // an instance it holds is not
    Missing,  // no file of a prefab has the id
}

Resolved_Prefab :: struct {
    state:Resolve_State,
    stamp:u64,    // the content hash of its file
    scene:^Scene, // its document with its instances up to date, once an instance asked for it
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
instances_of :: proc(a:^Asset,types:^Types) -> []Instance {
    table,found:=asset_table(a,TABLE_INSTANCES)
    if !found || len(table.columns)!=1 || table.rows==0 {return nil}
    index,known:=types_index(types,Instance)
    if !known {return nil}
    if asset_column_matches(a,table,0,types.hashes[index]) {
        data,error:=asset_column_data(a,table,0)
        if error==.None && uintptr(raw_data(data))&uintptr(align_of(Instance)-1)==0 {return mem.slice_data_cast([]Instance,data)}
    }
    rows,error:=make([]Instance,table.rows,context.temp_allocator)
    if error!=nil || asset_column_read(a,table,0,&types.schema,index,mem.slice_to_bytes(rows))!=.None {return nil}
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
    if file!=nil && file.blob.header.kind==KIND_PREFAB {
        checked.stamp=file.blob.header.content_hash
        checked.state=resolver_instances_stale(r,instances_of(file,r.types))?.Stale:.Current
    }
    r.prefabs[id]=checked
    return checked
}

// Whether an instance placed in a document is not what its prefab gives
// now. One of a prefab that is missing, or that holds itself, stays as it is.
resolver_instance_stale :: proc(r:^Prefab_Resolver,instance:Instance) -> bool {
    if instance.outer!=0 {return false}
    p:=resolver_check(r,instance.prefab)
    return (p.state==.Current || p.state==.Stale) && (instance.stamp!=p.stamp || p.state==.Stale)
}

@(private="file")
resolver_instances_stale :: proc(r:^Prefab_Resolver,instances:[]Instance) -> bool {
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
prefab_holds :: proc(files:Prefab_Files,types:^Types,id,target:base.Asset_Id,depth:=0) -> bool {
    if id==target || depth>PREFAB_DEPTH {return true}
    file:=files.open(files.data,id)
    if file==nil || file.blob.header.kind!=KIND_PREFAB {return false}
    for instance in instances_of(file,types) {
        if instance.prefab==target {return true}
        if instance.outer==0 && prefab_holds(files,types,instance.prefab,target,depth+1) {return true}
    }
    return false
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
    no_scene:runtime.Allocator_Error
    if prefab,no_scene=new(Scene,r.allocator);no_scene!=nil {return nil,.Out_Of_Memory}
    if error=scene_from_asset(prefab,r.types,file,r.allocator);error!=.None {
        free(prefab,r.allocator)
        return nil,error
    }
    // Kept before resolving it: a prefab that holds itself gets this one.
    kept.scene=prefab
    if checked.state==.Stale {scene_resolve(r,prefab) or_return}
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
    stale:=make([dynamic]u32,context.temp_allocator)
    for instance in scene.instances {
        if resolver_instance_stale(r,instance) {append(&stale,instance.id)}
    }
    if r.error!=.None {return false,r.error}
    for id in stale {
        at:=scene_instance_find(scene,id)
        if at<0 {continue}
        prefab:=resolver_prefab(r,scene.instances[at].prefab) or_return
        if prefab==nil || prefab==scene {continue}
        scene_instance_update(scene,id,prefab) or_return
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
        if file,found:=registry_find(files.registry,id);found && file.kind==KIND_PREFAB {
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
