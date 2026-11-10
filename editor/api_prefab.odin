package editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// The prefab.* methods of the API: the linked prefabs of prefabs.odin. Each
// edit is one step of the history; a prefab is named as any asset is, by its
// id or by its path inside the assets folder.

Api_Prefab_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,optional,label=The prefab: a path inside the assets folder or its asset id; none: all of them"`,
}

Api_Prefab_Inspect_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity,optional,label=An entity: its prefab links and overrides"`,
    asset:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A prefab: a path inside the assets folder or its asset id"`,
}

Api_Prefab_Create_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity,label=The root of the subtree that becomes the prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A new file inside the assets folder; omitted: beside the open scene with the name of the entity"`,
}

Api_Prefab_Instantiate_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The prefab: a path inside the assets folder or its asset id"`,
    parent:Api_Entity_Text `mirai:"text,entity,optional"`,
    position:[3]f32 `mirai:"optional"`,
    rotation_deg:[3]f32 `mirai:"optional"`,
    scale_multiplier:[3]f32 `mirai:"optional,min=0"`,
}

Api_Prefab_Entity_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity"`,
    paths:[512]u8 `mirai:"text,optional,label=Names separated by commas (name; Component; Component.field or child); none: every override of the entity"`,
}

Api_Prefab_Apply_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity"`,
    paths:[512]u8 `mirai:"text,optional,label=Names separated by commas (name; Component; Component.field or child); none: every override of the entity"`,
    target:Prefab_Apply_Target `mirai:"optional,label=Prefab: the prefab of the instance. Base: through that prefab, a variant, into its base"`,
}

Api_Prefab_Variant_Params :: struct {
    prefab:[API_PATH_BYTES]u8 `mirai:"text,label=The base: a path inside the assets folder or its asset id"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A new file inside the assets folder; omitted: beside the base with its name and _variant"`,
}

Api_Prefab_Variant_Result :: struct {
    asset:base.Asset_Id `mirai:"label=The variant"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Its file"`,
}

Api_Prefab_Unlink_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity"`,
    recursive:bool `mirai:"optional,label=Also the instances it brought in"`,
}

Api_Prefab_Created_Result :: struct {
    id:base.Entity_Id `mirai:"label=The root of the instance"`,
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the prefab"`,
}

Api_Prefab_Count_Result :: struct {
    id:base.Entity_Id,
    count:int `mirai:"label=The overrides it took"`,
}

Api_Prefab_Refresh_Result :: struct {
    prefabs,instances,missing,failed:int,
}

Api_Prefab_List :: struct {
    prefabs:[1]Api_Prefab_File `mirai:"list,label=The prefab files of the assets"`,
    instances:[1]Api_Prefab_Instance `mirai:"list,label=The instances of the document whose root exists"`,
}
Api_Prefab_File :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text"`,
    asset:base.Asset_Id,
}
Api_Prefab_Instance :: struct {
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the prefab; empty when it is missing"`,
    root:base.Entity_Id `mirai:"label=Its root: what names the instance"`,
    members:int,
    missing:bool `mirai:"label=Whether the file of its prefab is missing"`,
    stale:bool `mirai:"label=Whether it is not up to date with the file its prefab has now; prefab.refresh updates it"`,
}

Api_Prefab_Inspect_Result :: struct {
    id:base.Entity_Id `mirai:"optional,label=With entity: the entity"`,
    locked:bool `mirai:"optional,label=With entity: whether it keeps the place its prefab gives it as a member of an instance that is not its root"`,
    links:[1]Api_Prefab_Link `mirai:"list,optional,label=With entity: the instance that placed it in the document and then each instance the prefab of the one before places that the entity is of; empty for an entity no instance placed"`,
    overrides:[1]Api_Prefab_Override `mirai:"list,optional,label=With entity: what it holds that its prefab does not; its placement left out"`,
    stale:bool `mirai:"optional,label=With entity: whether its instance is not up to date with its prefab as its files give it now; prefab.refresh updates it"`,
    asset:base.Asset_Id `mirai:"optional,label=With asset: the prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=With asset: the file of the prefab"`,
    root:base.Entity_Id `mirai:"optional,label=With asset: the root of the prefab"`,
    entities:[1]Api_Prefab_Entity `mirai:"list,optional,label=With asset: every entity of the prefab"`,
    instances:int `mirai:"optional,label=With asset: the instances of other prefabs it places"`,
    base:Api_Asset_Id `mirai:"optional,label=With asset: the prefab its root is an instance of when it is a variant; zero when it is not"`,
    chain:[1]Api_Asset_Id `mirai:"list,optional,label=With asset: its base, the base of that one and so on"`,
}
// base.Asset_Id where a field is named base.
Api_Asset_Id :: base.Asset_Id

Api_Prefab_Link :: struct {
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the prefab; empty when it is missing"`,
    root:base.Entity_Id `mirai:"label=The root of the instance: of the document for the first link; of the instance a prefab places for the next ones"`,
    source:base.Entity_Id `mirai:"label=The entity of the prefab the entity stands for"`,
}
Api_Prefab_Override :: struct {
    path:[256]u8 `mirai:"text,label=name; child; a component or Component.field"`,
    kind:[8]u8 `mirai:"text,label=field; added; removed; turned or child"`,
}
Api_Prefab_Entity :: struct {
    id:base.Entity_Id,
    parent:u8 `mirai:"any,label=The id of its parent; null for the root"`,
    name:[64]u8 `mirai:"text"`,
}

@(private)
prefab_api_register :: proc(s:^Session,st:^Api_State) {
    instantiate:=Api_Prefab_Instantiate_Params{scale_multiplier={1,1,1}}
    api_register(s,st,{name="prefab.list",summary="The prefabs of the assets and the instances of the document.",result=Api_Prefab_List,writes_result=true,flags={.Read_Only},run=api_prefab_list})
    api_register(s,st,{name="prefab.inspect",summary="The prefab links and overrides of an entity, or the entities of a prefab.",params=Api_Prefab_Inspect_Params,result=Api_Prefab_Inspect_Result,writes_result=true,flags={.Read_Only},run=api_prefab_inspect})
    api_register(s,st,{name="prefab.create",summary="Writes the subtree of an entity as a prefab and links the entity as its first instance.",params=Api_Prefab_Create_Params,result=Api_Prefab_Created_Result,run=api_prefab_create})
    api_register(s,st,{name="prefab.instantiate",summary="Places an instance of a prefab with new ids.",params=Api_Prefab_Instantiate_Params,result=Api_Prefab_Created_Result,defaults=&instantiate,run=api_prefab_instantiate})
    api_register(s,st,{name="prefab.apply",summary="Writes the overrides of an entity, a member or one an instance added, into the file of its prefab, or through a variant into its base, ends them and brings every instance up to date.",params=Api_Prefab_Apply_Params,result=Api_Prefab_Count_Result,run=api_prefab_apply})
    api_register(s,st,{name="prefab.revert",summary="Forgets overrides of an entity, a member or one an instance added, and gives back what its prefab has: values, and no entity added by the instance.",params=Api_Prefab_Entity_Params,result=Api_Prefab_Count_Result,run=api_prefab_revert})
    api_register(s,st,{name="prefab.refresh",summary="Brings the instances of a prefab, or of all, up to date with its file; what an instance holds on its own stays.",params=Api_Prefab_Params,result=Api_Prefab_Refresh_Result,run=api_prefab_refresh})
    api_register(s,st,{name="prefab.variant.create",summary="Writes a variant of a prefab: a new prefab whose root is an instance of it, which follows its changes and keeps its own as overrides.",params=Api_Prefab_Variant_Params,result=Api_Prefab_Variant_Result,run=api_prefab_variant_create})
    api_register(s,st,{name="prefab.unlink",summary="Makes the members of an instance ordinary entities.",params=Api_Prefab_Unlink_Params,result=Api_Edit_Result,run=api_prefab_unlink})
}

@(private)
api_prefab_fail :: proc(call:^api.Call,error:Prefab_Error) {
    code:=api.SERVER_ERROR
    #partial switch error {
    case .Unknown_Entity,.No_Id,.Not_Found,.Not_One_Root,.Unknown_Path,.Not_Instance,.Not_Variant: code=api.INVALID_PARAMS
    }
    api.call_fail(call,code,prefab_error_text(error))
}

// The prefab a call names by path or id: a scene of the assets with exactly
// one root. A scene with another number of roots fails with what to do.
@(private)
prefab_named :: proc(s:^Session,call:^api.Call,name:string) -> (id:base.Asset_Id,ok:bool) {
    id=asset_named(s,call,name,asset.KIND_SCENE,SCENE_EXTENSION,"a scene") or_return
    if file,found:=asset.registry_find(&s.app.assets.registry,id);!found || !asset.registry_prefab(file) {
        api.call_failf(call,api.INVALID_PARAMS,"%q is no prefab: %s (asset.list says which scenes are prefabs)",name,prefab_error_text(.Not_One_Root))
        return {},false
    }
    return id,true
}

@(private)
api_asset_write :: proc(w:^serial.Writer,id:base.Asset_Id) {
    serial.write_u8(w,'"')
    buffer:[base.ASSET_ID_TEXT]u8
    serial.text_write_raw(w,base.asset_id_format(id,buffer[:]))
    serial.write_u8(w,'"')
}

@(private)
api_prefab_list :: proc(s:^Session,call:^api.Call) {
    a:=s.app.assets
    w:=call.out
    serial.text_write_raw(w,`{"prefabs":[`)
    first:=true
    if a!=nil {
        assets_rescan(s)
        for &file in a.registry.files {
            if !asset.registry_prefab(&file) || !asset.registry_listed(&file) {continue}
            if !first {serial.write_u8(w,',')}
            first=false
            serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,file.path)
            api.write_key(w,"asset");api_asset_write(w,file.id)
            serial.write_u8(w,'}')
        }
    }
    serial.write_u8(w,']')
    api.write_key(w,"instances");serial.write_u8(w,'[')
    for state,i in prefab_instances(s) {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"asset":`);api_asset_write(w,state.asset)
        api.write_key(w,"path");serial.text_write_string(w,state.path)
        api.write_key(w,"root");api.write_id(w,state.root)
        api.write_key(w,"members");serial.text_write_int(w,i64(state.members))
        api.write_key(w,"missing");api.write_flag(w,state.missing)
        api.write_key(w,"stale");api.write_flag(w,state.stale)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    serial.write_u8(w,'}')
}

@(private)
api_prefab_inspect :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Inspect_Params)
    w:=call.out
    world:=edited_world(s)
    if params.entity[0]!=0 {
        e,named:=api_call_entity(call,world,params.entity[:])
        if !named {return}
        entity_id:=api_entity_id(world,e)
        serial.text_write_raw(w,`{"id":`);api.write_id(w,entity_id)
        api.write_key(w,"locked");api.write_flag(w,prefab_member_locked(s,world,e))
        assets_rescan(s)
        api.write_key(w,"links");serial.write_u8(w,'[')
        for link,at in prefab_chain(s,world,e,call.allocator) {
            if at>0 {serial.write_u8(w,',')}
            file,_,_:=prefab_file(s,link.asset)
            serial.text_write_raw(w,`{"asset":`);api_asset_write(w,link.asset)
            api.write_key(w,"path");serial.text_write_string(w,file!=nil?file.path:"")
            api.write_key(w,"root");api.write_id(w,api_entity_id(world,link.instance))
            api.write_key(w,"source");api.write_id(w,link.source)
            serial.write_u8(w,'}')
        }
        serial.write_u8(w,']')
        api.write_key(w,"overrides");serial.write_u8(w,'[')
        root:=prefab_instance_for(world,e)
        overrides:[]asset.Override
        known:=true
        if root!=core.NONE {overrides,known=prefab_overrides_of(s,root)}
        kinds:=[asset.Override_Kind]string{.Field="field",.Added="added",.Removed="removed",.Turned="turned",.Child="child"}
        first:=true
        for &override in overrides {
            if override.entity!=entity_id {continue}
            if !first {serial.write_u8(w,',')}
            first=false
            serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,prefab_override_name(s,&override,call.allocator))
            api.write_key(w,"kind");serial.text_write_string(w,kinds[override.kind])
            serial.write_u8(w,'}')
        }
        serial.write_u8(w,']')
        placed,is_instance:=scene.prefab_instance(world,root)
        api.write_key(w,"stale");api.write_flag(w,is_instance && (!known || prefab_stale(s,placed)))
        serial.write_u8(w,'}')
        return
    }
    id,located:=prefab_named(s,call,base.text_get(params.asset[:]))
    if !located {return}
    loaded,ok:=prefab_scene_load(s,id)
    if !ok {
        api_prefab_fail(call,.Not_Found)
        return
    }
    defer prefab_scene_free(loaded)
    file,_,_:=prefab_file(s,id)
    root,_:=asset.prefab_root(loaded)
    serial.text_write_raw(w,`{"asset":`);api_asset_write(w,id)
    api.write_key(w,"path");serial.text_write_string(w,file.path)
    api.write_key(w,"root");api.write_id(w,root)
    api.write_key(w,"entities");serial.write_u8(w,'[')
    for row in 0..<asset.scene_entity_count(loaded) {
        record:=asset.scene_entity(loaded,row)
        if row>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"id":`);api.write_id(w,record.id)
        api.write_key(w,"parent")
        if record.parent!=0 {api.write_id(w,record.parent)} else {serial.text_write_raw(w,"null")}
        api.write_key(w,"name");serial.text_write_string(w,record.name)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    api.write_key(w,"instances");serial.text_write_int(w,i64(len(asset.scene_instance_roots(loaded))))
    chain:=prefab_variant_chain(s,id)
    api.write_key(w,"base");api_asset_write(w,len(chain)>0?chain[0]:{})
    api.write_key(w,"chain");serial.write_u8(w,'[')
    for link,at in chain {
        if at>0 {serial.write_u8(w,',')}
        api_asset_write(w,link)
    }
    serial.text_write_raw(w,"]}")
}

// The entry of a menu on the root of an instance takes the overrides of every
// member of it; a call names the entity whose overrides it takes.
@(private)
api_prefab_whole :: proc(s:^Session,e:core.Entity) -> bool {
    link,linked:=prefab_link_of(edited_world(s),e)
    return api_person(s) && linked && link.root
}

@(private)
api_prefab_create :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Create_Params)
    if !api_guard(s,call) {return}
    // Several selected entities become one prefab.
    targets,found:=api_call_targets(call,edited_world(s),params.entity[:])
    if !found {return}
    e:=targets[0]
    path:=base.text_get(params.path[:])
    if path=="" {path=prefab_name_free(s,prefab_folder(s),entity_name(edited_world(s),e))}
    id,error:=prefab_create_entities(s,targets,path)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    if api_person(s) {notify(s,fmt.tprintf("Prefab %s created",path))}
    result:=api.call_result(call,Api_Prefab_Created_Result)
    result.id,result.asset=api_entity_id(edited_world(s),e),id
    if file,_,ok:=prefab_file(s,id);ok {base.text_set(result.path[:],file.path)}
}

@(private)
api_prefab_instantiate :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Instantiate_Params)
    if !api_guard(s,call) {return}
    id,located:=prefab_named(s,call,base.text_get(params.asset[:]))
    if !located {return}
    placement:=Prefab_Placement{position=params.position,scale_multiplier=params.scale_multiplier}
    if params.parent[0]!=0 {
        parent,found:=api_call_entity(call,edited_world(s),params.parent[:],"parent")
        if !found {return}
        placement.parent=parent
    }
    if params.rotation_deg!={} {
        q:=mm.quat_from_euler(params.rotation_deg*mm.RAD_PER_DEG)
        placement.rotation={q.x,q.y,q.z,q.w}
    }
    root,error:=prefab_instantiate(s,id,placement)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    result:=api.call_result(call,Api_Prefab_Created_Result)
    result.id,result.asset=root,id
    if file,_,ok:=prefab_file(s,id);ok {base.text_set(result.path[:],file.path)}
}

@(private)
api_paths_split :: proc(text:string,allocator:=context.temp_allocator) -> []string {
    parts:=make([dynamic]string,allocator)
    rest:=text
    for part in strings.split_iterator(&rest,",") {
        trimmed:=strings.trim_space(part)
        if trimmed!="" {append(&parts,trimmed)}
    }
    return parts[:]
}

@(private)
api_prefab_apply :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Apply_Params)
    if !api_guard(s,call) {return}
    targets,found:=api_call_targets(call,edited_world(s),params.entity[:])
    if !found {return}
    e:=targets[0]
    count,error:=prefab_apply(s,e,api_paths_split(base.text_get(params.paths[:])),api_prefab_whole(s,e),params.target)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    if api_person(s) {notify(s,fmt.tprintf(params.target==.Base?"%d overrides applied to the base":"%d overrides applied",count))}
    api.call_result(call,Api_Prefab_Count_Result)^={api_entity_id(edited_world(s),e),count}
}

@(private)
api_prefab_variant_create :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Variant_Params)
    if !api_guard(s,call) {return}
    base_id,located:=prefab_named(s,call,base.text_get(params.prefab[:]))
    if !located {return}
    path:=base.text_get(params.path[:])
    if path=="" {
        file,_,_:=prefab_file(s,base_id)
        path=prefab_name_free(s,content_folder_of(file.path),fmt.tprintf("%s_variant",asset_name(file.path)))
    }
    id,error:=prefab_variant_create(s,base_id,path)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    result:=api.call_result(call,Api_Prefab_Variant_Result)
    result.asset=id
    if file,_,ok:=prefab_file(s,id);ok {base.text_set(result.path[:],file.path)}
}

@(private)
api_prefab_revert :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Entity_Params)
    if !api_guard(s,call) {return}
    targets,found:=api_call_targets(call,edited_world(s),params.entity[:])
    if !found {return}
    e:=targets[0]
    count,error:=prefab_revert(s,e,api_paths_split(base.text_get(params.paths[:])),api_prefab_whole(s,e))
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    if api_person(s) {notify(s,fmt.tprintf("%d overrides reverted",count))}
    api.call_result(call,Api_Prefab_Count_Result)^={api_entity_id(edited_world(s),e),count}
}

@(private)
api_prefab_refresh :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Params)
    if !api_guard(s,call) {return}
    id:base.Asset_Id
    if named:=base.text_get(params.asset[:]);named!="" {
        located,found:=prefab_named(s,call,named)
        if !found {return}
        id=located
    }
    report,error:=prefab_refresh(s,id)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    api.call_result(call,Api_Prefab_Refresh_Result)^={report.prefabs,report.instances,report.missing,report.failed}
}

@(private)
api_prefab_unlink :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Unlink_Params)
    if !api_guard(s,call) {return}
    targets,found:=api_call_targets(call,edited_world(s),params.entity[:])
    if !found {return}
    e:=targets[0]
    if error:=prefab_unlink(s,e,params.recursive);error!=.None {
        api_prefab_fail(call,error)
        return
    }
    if api_person(s) {notify(s,"Prefab unlinked")}
    api.call_result(call,Api_Edit_Result).id=api_entity_id(edited_world(s),e)
}
