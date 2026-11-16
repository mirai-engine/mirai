package asset

import "mirai:std/base"
import "mirai:std/serial"

// The overrides of an instance, found and written by comparing documents:
// derived from what its members hold apart from the prefab as the instance
// was last brought up to date (its base), and applied into the prefab.

// A component as a scene and a prefab store it.
@(private)
Override_Pair :: struct {
    scene_table,prefab_table:int, // -1 where one lacks the component
    hash:u64,
    name:string,
    size:int,                   // of a value in the scene
    migration:serial.Migration, // from the layout of the prefab to the one of the scene
    refs:[dynamic]serial.Ref,
    leaves:[dynamic]Value_Leaf,
}

@(private="file")
component_tables :: proc(scene:^Scene) -> []int {
    found:=make([dynamic]int,context.temp_allocator)
    for table,at in scene.doc.tables {
        if at==0 || membership_hash(table.name_hash) {continue}
        if _,is_component:=scene_component(scene,table.name);is_component {append(&found,at)}
    }
    return found[:]
}

// The pairs of component tables of a scene and of a prefab, those of the
// instances aside, in temporary memory.
@(private)
override_pairs :: proc(scene,prefab:^Scene) -> (pairs:[]Override_Pair,error:Error) {
    out:=make([dynamic]Override_Pair,context.temp_allocator)
    matched:=make(map[u64]bool,context.temp_allocator)
    for at in component_tables(scene) {
        table:=&scene.doc.tables[at]
        pair:=Override_Pair{scene_table=at,prefab_table=-1,hash=table.name_hash,name=table.name,size=table.columns[1].size}
        if theirs,found:=scene_component_by_hash(prefab,table.name_hash);found {
            pair.prefab_table=theirs
            matched[table.name_hash]=true
            if failed:=serial.migration_init(&pair.migration,&prefab.doc.schema,prefab.doc.tables[theirs].columns[1].type,&scene.doc.schema,table.columns[1].type,context.temp_allocator);failed!=.None {
                return nil,failed==.Out_Of_Memory?.Out_Of_Memory:.Invalid
            }
        }
        pair.refs.allocator=context.temp_allocator
        pair.leaves.allocator=context.temp_allocator
        serial.refs_collect(&scene.doc.schema,table.columns[1].type,&pair.refs)
        value_leaves(&scene.doc.schema,table.columns[1].type,&pair.leaves)
        if _,failed:=append(&out,pair);failed!=nil {return nil,.Out_Of_Memory}
    }
    for theirs in component_tables(prefab) {
        table:=&prefab.doc.tables[theirs]
        if matched[table.name_hash] {continue}
        if _,failed:=append(&out,Override_Pair{scene_table=-1,prefab_table=theirs,hash=table.name_hash,name=table.name});failed!=nil {return nil,.Out_Of_Memory}
    }
    return out[:],.None
}

// A component of the prefab in the layout of the scene, its references
// pointing at the members.
@(private="file")
pair_image :: proc(pair:^Override_Pair,prefab:^Scene,source:base.Entity_Id,remap:map[base.Entity_Id]base.Entity_Id) -> (image:[]u8,found:bool) {
    stored:[]u8
    stored,found=scene_component_get(prefab,pair.prefab_table,source)
    if !found {return}
    image=make([]u8,max(pair.size,1),context.temp_allocator)
    if pair.scene_table<0 {return image,true}
    serial.migration_apply(&pair.migration,image[:pair.size],stored,1)
    for ref in pair.refs {
        if ref.kind==.Asset {continue}
        target:=(^u64)(&image[ref.offset])
        if target^!=0 {target^=u64(remap[base.Entity_Id(target^)])}
    }
    return image,true
}

override_make :: proc(entity:base.Entity_Id,component:u64,kind:Override_Kind,path:string) -> (override:Override) {
    override={entity=entity,component=component,kind=kind}
    if len(path)<len(override.path) {copy(override.path[:],path)}
    return
}

// Where a derivation finds the base of an instance: the prefab as the
// instance was last brought up to date, by its root; nil when it is not
// known, and the instance is left out.
Override_Bases :: struct {
    data:rawptr,
    base:proc(data:rawptr,root:base.Entity_Id,instance:Prefab_Instance) -> ^Scene,
}

// What the instances placed in a document hold apart from their bases: for
// each member, its name and the components it adds, lacks, turns or gives
// other values, and the entities placed under its members. The placement of
// a root is the instance's own and is never one. only: that instance alone.
scene_overrides_derive :: proc(out:^[dynamic]Override,scene:^Scene,bases:Override_Bases,only:=base.Entity_Id(0)) -> Error {
    rows,values:=member_rows(scene) or_return
    if len(rows)==0 {return .None}
    ids,parents:=scene_ids(scene),scene_parents(scene)
    // The members of each instance, one after another.
    Group :: struct {first,count:int,prefab:^Scene,instance:Prefab_Instance}
    groups:=make(map[base.Entity_Id]Group,context.temp_allocator)
    order:=make([dynamic]base.Entity_Id,context.temp_allocator) // of the roots: what is derived does not depend on the map
    for value in values {
        root:=base.Entity_Id(value.instance)
        if only!=0 && root!=only {continue}
        group,known:=groups[root]
        if !known {append(&order,root)}
        group.count+=1
        groups[root]=group
    }
    total:=0
    for root in order {
        group:=&groups[root]
        group.first,total=total,total+group.count
        group.count=0
        placed:bool
        if group.instance,placed=scene_instance(scene,root);placed && root in scene.index {group.prefab=bases.base(bases.data,root,group.instance)}
        if group.prefab==scene {group.prefab=nil}
    }
    members,no_members:=make([]Placed,total,context.temp_allocator)
    if no_members!=nil {return .Out_Of_Memory}
    for value,at in values {
        group,grouped:=&groups[base.Entity_Id(value.instance)]
        if !grouped {continue}
        members[group.first+group.count]={ids[rows[at]],base.Entity_Id(value.source)}
        group.count+=1
    }
    pairs:=make(map[^Scene][]Override_Pair,context.temp_allocator)
    remap:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    marked:=make([dynamic]string,context.temp_allocator)
    placement:=base.name_hash(INSTANCE_PLACEMENT)
    for root in order {
        group:=groups[root]
        prefab:=group.prefab
        if prefab==nil {continue}
        if !(prefab in pairs) {pairs[prefab]=override_pairs(scene,prefab) or_return}
        clear(&remap)
        for member in members[group.first:][:group.count] {remap[member.source]=member.entity}
        for member in members[group.first:][:group.count] {
            entity,source:=member.entity,member.source
            row,_:=scene_entity_find(scene,entity)
            prefab_row,in_prefab:=scene_entity_find(prefab,source)
            if !in_prefab {continue}
            if scene_names(scene)[row]!=scene_names(prefab)[prefab_row] {append(out,override_make(entity,0,.Field,"name"))}
            for &pair in pairs[prefab] {
                if entity==root && pair.hash==placement {continue}
                value:[]u8
                has,inherited:=false,false
                if pair.scene_table>=0 {value,has=scene_component_get(scene,pair.scene_table,entity)}
                if pair.prefab_table>=0 {_,inherited=scene_component_get(prefab,pair.prefab_table,source)}
                switch {
                case has && !inherited:
                    append(out,override_make(entity,pair.hash,.Added,""))
                case !has && inherited:
                    append(out,override_make(entity,pair.hash,.Removed,""))
                case has && inherited:
                    if scene_component_off(scene,entity,pair.hash)!=scene_component_off(prefab,source,pair.hash) {
                        append(out,override_make(entity,pair.hash,.Turned,""))
                    }
                    image,_:=pair_image(&pair,prefab,source,remap)
                    clear(&marked)
                    overrides_mark(pair.leaves[:],value,image,&marked)
                    for path in marked {append(out,override_make(entity,pair.hash,.Field,len(path)<OVERRIDE_PATH_BYTES?path:""))}
                }
            }
        }
    }
    // An entity under a member that its instance did not place was added there.
    member_of:=make(map[base.Entity_Id]base.Entity_Id,len(values),context.temp_allocator)
    for value,at in values {member_of[ids[rows[at]]]=base.Entity_Id(value.instance)}
    for entity,row in ids {
        above,under:=member_of[parents[row]]
        if !under || member_of[entity]==above {continue}
        if group,derived:=groups[above];derived && group.prefab!=nil {append(out,override_make(entity,0,.Child,""))}
    }
    return .None
}

// scene_overrides_derive of one instance against a prefab.
scene_instance_overrides :: proc(out:^[dynamic]Override,scene:^Scene,root:base.Entity_Id,prefab:^Scene) -> Error {
    if _,placed:=scene_instance(scene,root);!placed || scene==prefab {return .Invalid}
    one :: proc(data:rawptr,root:base.Entity_Id,instance:Prefab_Instance) -> ^Scene {return (^Scene)(data)}
    return scene_overrides_derive(out,scene,{prefab,one},root)
}

// Writes overrides of an instance placed in a scene into its prefab: first
// the entities it added, which the values of members may name, then names,
// values and components. The prefab is as it was when an error comes back
// from a value; the entities added before it stay.
scene_overrides_apply :: proc(scene:^Scene,root:base.Entity_Id,selected:[]Override,prefab:^Scene) -> Error {
    for override in selected {
        if override.kind==.Child {scene_child_apply(scene,root,override.entity,prefab) or_return}
    }
    inverse:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    members:=scene_instance_members(scene,root) or_return
    for member in members {inverse[member.entity]=member.source}
    pairs:=override_pairs(scene,prefab) or_return
    for &override in selected {
        if override.kind>=.Child {continue}
        entity:=override.entity
        source:=inverse[entity]
        if source==0 {return .Not_Found}
        if override.component==0 {
            row,exists:=scene_entity_find(scene,entity)
            if !exists {return .Not_Found}
            scene_entity_rename(prefab,source,serial.text_field(scene_names(scene)[row][:])) or_return
            continue
        }
        for &pair in pairs {
            if pair.hash!=override.component || pair.scene_table<0 && override.kind!=.Removed {continue}
            switch override.kind {
            case .Removed:
                if pair.prefab_table>=0 {scene_component_remove(prefab,pair.prefab_table,source)}
            case .Added:
                if pair.prefab_table<0 {
                    pair.prefab_table=scene_component_add(prefab,pair.name,&scene.doc.schema,scene.doc.tables[pair.scene_table].columns[1].type) or_return
                }
                override_value_apply(&pair,scene,prefab,entity,source,"",inverse) or_return
                fallthrough
            case .Turned:
                if pair.prefab_table<0 {continue}
                scene_component_turn(prefab,source,pair.hash,scene_component_off(scene,entity,pair.hash)) or_return
            case .Field:
                if pair.prefab_table<0 {continue}
                override_value_apply(&pair,scene,prefab,entity,source,serial.text_field(override.path[:]),inverse) or_return
            case .Child:
            }
        }
    }
    return .None
}

// Copies the part of a component a path names ("" is all of it) from the
// scene into the prefab, in the layout of the prefab and with its references
// pointing at the entities of the prefab. Not_Found: the path names no part.
@(private)
override_value_apply :: proc(pair:^Override_Pair,scene,prefab:^Scene,entity,source:base.Entity_Id,path:string,inverse:map[base.Entity_Id]base.Entity_Id) -> Error {
    if pair.scene_table<0 || pair.prefab_table<0 {return .Invalid}
    scene_type:=scene.doc.tables[pair.scene_table].columns[1].type
    prefab_type:=prefab.doc.tables[pair.prefab_table].columns[1].type
    value,has:=scene_component_get(scene,pair.scene_table,entity)
    if !has {return .Invalid}
    size:=prefab.doc.tables[pair.prefab_table].columns[1].size
    buffer,no_buffer:=make([]u8,max(size,1),context.temp_allocator)
    if no_buffer!=nil {return .Out_Of_Memory}
    converted:=buffer[:size] // a tag has no bytes
    migration:serial.Migration
    defer serial.migration_destroy(&migration)
    if failed:=serial.migration_init(&migration,&scene.doc.schema,scene_type,&prefab.doc.schema,prefab_type,context.temp_allocator);failed!=.None {
        return failed==.Out_Of_Memory?.Out_Of_Memory:.Invalid
    }
    serial.migration_apply(&migration,converted,value,1)
    refs:[dynamic]serial.Ref
    refs.allocator=context.temp_allocator
    if !serial.refs_collect(&prefab.doc.schema,prefab_type,&refs) {return .Out_Of_Memory}
    for ref in refs {
        if ref.kind==.Asset {continue}
        target:=(^u64)(&converted[ref.offset])
        if target^!=0 {target^=u64(inverse[base.Entity_Id(target^)])}
    }
    current,exists:=scene_component_get(prefab,pair.prefab_table,source)
    if path=="" || !exists {return scene_component_set(prefab,pair.prefab_table,source,converted)}
    merged,no_merged:=make([]u8,len(current),context.temp_allocator)
    if no_merged!=nil {return .Out_Of_Memory}
    copy(merged,current)
    _,to,to_error:=serial.value_slice(&prefab.doc.schema,prefab_type,merged,path)
    _,from,from_error:=serial.value_slice(&prefab.doc.schema,prefab_type,converted,path)
    if to_error!=.None || from_error!=.None || len(to)!=len(from) {return .Not_Found}
    copy(to,from)
    return scene_component_set(prefab,pair.prefab_table,source,merged)
}
