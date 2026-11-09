package scene

import "base:intrinsics"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// A level a player saved or downloaded is hostile input: its file may be
// huge, its values anything. It loads only after every value it would put in
// the world passed the rules the game gave and the schema of its components.
//
// Referenced scenes load through the trusted path (instantiate), so a level
// may reference only scenes the game ships, never another guest file; the
// prefab instances it records must be prefabs of the registry, and are loaded
// as the document holds them, without reading those prefabs.

// What a document the game did not ship may hold.
Untrusted :: struct {
    components:[]typeid, // the only components its entities may hold, Transform aside; empty: any the world has
    max_entities:int,    // 0: refuse nothing on count
    max_bytes:int,       // what its file, and its chunks once decompressed, may take; 0: UNTRUSTED_BYTES
}

// The most a downloaded level takes unless its rules say otherwise.
UNTRUSTED_BYTES :: 16<<20

REFUSAL_FIELD :: 64

// What load_untrusted refused, to tell the player what to fix.
Refusal :: struct {
    entity:base.Entity_Id,       // its Id in the document; 0: the document as a whole
    component:string,            // the name of its table, of the World_Info
    field:[REFUSAL_FIELD]u8,     // path of the part of the component, as serial.value_get takes it
    fault:serial.Value_Fault,
    number,limit:f64,            // the number refused and the bound it broke; Too_Large: entities (0 for bytes) and the limit
    asset:base.Asset_Id,         // an asset named that is not there, or a scene the game did not ship
    target:base.Entity_Id,       // an entity named that is not in the document
}

// Replaces what the world holds with a scene whose file the game did not ship,
// as replace does, all of it or nothing, once it holds only what rules allow:
// - its file, read and decompressed, within max_bytes (Too_Large);
// - at most max_entities entities, refused before any is made (Too_Large);
// - only the listed components (Not_Allowed);
// - values that their schema allows: finite floats, numbers within the min
//   and max of their field, enums and bools that are one of their values
//   (Out_Of_Range);
// - Entity fields that name an entity of the document, Asset fields an asset
//   of the registry, prefab instances a prefab of the registry
//   (Unknown_Reference), and Scene_References a scene outside guest mounts
//   (Not_Allowed).
// path is of the registry (a level under a host.assets_mount) or absolute.
// What failed is in report.refused; untrusted_text says it with its fix.
load_untrusted :: proc(w:core.World_Ref,app:^host.App,path:string,rules:Untrusted) -> (report:Report,error:Error) {
    if app==nil || app.assets==nil {return {},.No_Assets}
    if app.info==nil || w.info!=app.info || w.place!=.World {return {},.Invalid}
    limit:=u64(rules.max_bytes>0?rules.max_bytes:UNTRUSTED_BYTES)
    registry:=&app.assets.registry
    host.assets_scan(app.assets)
    data:[]u8
    read_error:asset.Error
    if file,found:=asset.registry_find_path(registry,path);found {data,read_error=asset.registry_read(registry,file.path,context.allocator,limit)}
    else if filepath.is_abs(path) {data,read_error=asset.asset_file_read(path,context.allocator,limit)}
    else {return {},.Not_Found}
    document:asset.Asset
    if read_error==.None {read_error=asset.asset_take(&document,data,context.allocator,limit)}
    if read_error!=.None {
        #partial switch read_error {
        case .Too_Large:
            report.refused.limit=f64(limit)
            return report,.Too_Large
        case .Not_Found:     return {},.Not_Found
        case .Out_Of_Memory: return {},.Out_Of_Memory
        }
        return {},.Corrupt
    }
    defer asset.asset_close(&document)
    if !asset.blob_verify_hash(&document.blob) {return {},.Corrupt}
    if document.blob.header.kind!=asset.KIND_SCENE {return {},.Invalid}
    if error=untrusted_check(w,app,&document,rules,&report.refused);error!=.None {return}
    return replace(w,app,&document,&app.assets.types)
}

// The refusal of a load_untrusted that failed and how to fix it, for the
// player; "" when it did not fail.
untrusted_text :: proc(report:Report,error:Error,allocator:=context.temp_allocator) -> string {
    r:=report.refused
    field:=base.text_get(r.field[:])
    name:[base.ASSET_ID_TEXT]u8
    #partial switch error {
    case .None:
        return ""
    case .Too_Large:
        if r.number>0 {return fmt.aprintf("the level has %v entities, more than the %v it may have: remove some",r.number,r.limit,allocator=allocator)}
        return fmt.aprintf("the level takes more than %v bytes: make it smaller",r.limit,allocator=allocator)
    case .Not_Allowed:
        if r.asset!={} {return fmt.aprintf("entity %v references the scene %s, which the game does not ship: remove the reference",r.entity,base.asset_id_format(r.asset,name[:]),allocator=allocator)}
        return fmt.aprintf("entity %v has %s, which a level may not hold: remove it from the entity",r.entity,r.component,allocator=allocator)
    case .Out_Of_Range:
        switch r.fault {
        case .Below_Min:  return fmt.aprintf("entity %v: %s.%s is %v, below its min %v: raise it",r.entity,r.component,field,r.number,r.limit,allocator=allocator)
        case .Above_Max:  return fmt.aprintf("entity %v: %s.%s is %v, above its max %v: lower it",r.entity,r.component,field,r.number,r.limit,allocator=allocator)
        case .Not_Finite: return fmt.aprintf("entity %v: %s.%s is not a finite number: set a number",r.entity,r.component,field,allocator=allocator)
        case .None,.Not_A_Choice,.Refused:
        }
        return fmt.aprintf("entity %v: %s.%s is %v, none of its values: pick one",r.entity,r.component,field,r.number,allocator=allocator)
    case .Unknown_Reference:
        if r.asset!={} {return fmt.aprintf("entity %v: %s.%s names the asset %s, which is not there: pick one the game has or none",r.entity,r.component,field,base.asset_id_format(r.asset,name[:]),allocator=allocator)}
        return fmt.aprintf("entity %v: %s.%s names entity %v, which is not in the level: pick one of the level or none",r.entity,r.component,field,r.target,allocator=allocator)
    }
    return fmt.aprintf("the level did not load: %s",error_text(error),allocator=allocator)
}

// What a document holds against the rules, before anything is instantiated.
@(private="file")
untrusted_check :: proc(w:core.World_Ref,app:^host.App,a:^asset.Asset,rules:Untrusted,refused:^Refusal) -> Error {
    registry:=&app.assets.registry
    view,view_error:=asset.scene_view(a,&app.assets.types)
    if view_error!=.None {return view_error==.Out_Of_Memory?.Out_Of_Memory:.Corrupt}
    if checked:=asset.scene_view_check(view,context.temp_allocator);checked!=.None {return .Out_Of_Memory if checked==.Out_Of_Memory else .Corrupt}
    if rules.max_entities>0 && len(view.ids)>rules.max_entities {
        refused^={number=f64(len(view.ids)),limit=f64(rules.max_entities)}
        return .Too_Large
    }
    for instance in view.instances {
        if file,found:=asset.registry_find(registry,instance.prefab);!found || file.kind!=asset.KIND_PREFAB {
            refused^={entity=instance.root,asset=instance.prefab}
            return .Unknown_Reference
        }
    }
    types:=schema_of(w)
    if types==nil {return .Out_Of_Memory}
    sorted,sorted_error:=slice.clone(view.ids,context.temp_allocator)
    if sorted_error!=nil {return .Out_Of_Memory}
    slice.sort(sorted)
    names:=Untrusted_Names{ids=sorted,registry=registry}
    values:=make([dynamic]u8,context.temp_allocator)
    path:[REFUSAL_FIELD]u8
    for &component in view.components {
        at,known:=core.world_table_index_of_hash(w,component.name_hash)
        if !known {continue}
        info:=&w.info.tables[at]
        if is_structural(info.type) {continue}
        value_type:=&types.tables[at]
        if !untrusted_allowed(rules.components,info.type) || value_type.type==serial.TYPE_NONE {
            if len(component.entities)>0 {refused.entity=view.ids[component.entities[0]]}
            refused.component=info.name
            return .Not_Allowed
        }
        size:=info.info.size
        if size==0 || len(component.entities)==0 {continue}
        if resize(&values,len(component.entities)*size)!=nil {return .Out_Of_Memory}
        if !component_read(a,&component,types,info,value_type,values[:]) {return .Corrupt}
        for row,i in component.entities {
            image:=values[i*size:][:size]
            problem:=serial.value_check(&types.schema,value_type.type,image,path[:],untrusted_name,&names)
            if problem.fault==.None && info.type==Scene_Reference {
                // What hangs from a reference loads unchecked: only scenes the game ships.
                scene:=intrinsics.unaligned_load((^Scene_Reference)(raw_data(image))).scene
                if file,found:=asset.registry_find(registry,scene);scene!={} && (!found || file.kind!=asset.KIND_SCENE || asset.registry_guest(registry,file.path)) {
                    refused^={entity=view.ids[row],component=info.name,asset=scene}
                    return .Not_Allowed
                }
            }
            if problem.fault==.None {continue}
            refused^={entity=view.ids[row],component=info.name,fault=problem.fault,number=problem.number,limit=problem.limit}
            base.text_set(refused.field[:],problem.path)
            if problem.fault!=.Refused {return .Out_Of_Range}
            refused.asset,refused.target=names.asset,names.target
            return .Unknown_Reference
        }
    }
    return .None
}

@(private="file")
untrusted_allowed :: proc(allowed:[]typeid,type:typeid) -> bool {
    return len(allowed)==0 || type==core.Transform || slice.contains(allowed,type)
}

// The entities of the document and the registry, against which its
// references are checked, and the reference refused.
@(private="file")
Untrusted_Names :: struct {
    ids:[]base.Entity_Id, // sorted
    registry:^asset.Registry,
    asset:base.Asset_Id,
    target:base.Entity_Id,
}

@(private="file")
untrusted_name :: proc(user:rawptr,kind:serial.Type_Kind,ref:[]u8) -> bool {
    names:=(^Untrusted_Names)(user)
    #partial switch kind {
    case .Entity:
        target:=intrinsics.unaligned_load((^base.Entity_Id)(raw_data(ref)))
        if _,found:=slice.binary_search(names.ids,target);target!=0 && !found {
            names.target=target
            return false
        }
    case .Asset:
        id:=intrinsics.unaligned_load((^base.Asset_Id)(raw_data(ref)))
        if _,found:=asset.registry_find(names.registry,id);id!={} && !found {
            names.asset=id
            return false
        }
    }
    return true
}
