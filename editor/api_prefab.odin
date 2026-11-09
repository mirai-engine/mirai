package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// The prefab.* methods of the API: the linked prefabs of prefabs.odin. Each
// edit is one step of the history; a prefab is named by its asset id or by a
// path, a file or inside the assets folder.

Api_Prefab_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,optional,label=The prefab: its file, a path inside the assets folder or its asset id; none: all of them"`,
}

Api_Prefab_Inspect_Params :: struct {
    entity:base.Entity_Id `mirai:"optional,label=An entity: its prefab links and overrides"`,
    asset:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A prefab: its file, a path inside the assets folder or its asset id"`,
}

Api_Prefab_Create_Params :: struct {
    entity:base.Entity_Id `mirai:"label=The root of the subtree that becomes the prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A new file inside the assets folder; omitted: prefabs/ and the name of the entity"`,
}

Api_Prefab_Instantiate_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The prefab: its file, a path inside the assets folder or its asset id"`,
    parent:base.Entity_Id `mirai:"optional"`,
    position:[3]f32 `mirai:"optional"`,
    rotation_deg:[3]f32 `mirai:"optional"`,
    scale_multiplier:[3]f32 `mirai:"optional,min=0"`,
}

Api_Prefab_Entity_Params :: struct {
    entity:base.Entity_Id,
    paths:[512]u8 `mirai:"text,optional,label=Names separated by commas (name; Component; Component.field or child); none: every override of the entity"`,
}

Api_Prefab_Apply_Params :: struct {
    entity:base.Entity_Id,
    paths:[512]u8 `mirai:"text,optional,label=Names separated by commas (name; Component; Component.field or child); none: every override of the entity"`,
    target:Prefab_Apply_Target `mirai:"optional,label=Prefab: the prefab of the instance. Base: through that prefab, a variant, into its base"`,
}

Api_Prefab_Variant_Params :: struct {
    prefab:[API_PATH_BYTES]u8 `mirai:"text,label=The base: its file, a path inside the assets folder or its asset id"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A new file inside the assets folder; omitted: prefabs/ and the name of the base with _variant"`,
}

Api_Prefab_Variant_Result :: struct {
    asset:base.Asset_Id `mirai:"label=The variant"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Its file"`,
}

Api_Prefab_Unlink_Params :: struct {
    entity:base.Entity_Id,
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
    instance:u32 `mirai:"label=Its number in the document"`,
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the prefab; empty when it is missing"`,
    root:base.Entity_Id,
    outer:u32 `mirai:"label=The instance that brought it in; 0 when it was placed in the document"`,
    members:int,
    overrides:int `mirai:"label=Without the placement of its root"`,
    missing:bool `mirai:"label=Whether the file of its prefab is missing"`,
    stale:bool `mirai:"label=Whether it is not up to date with the file its prefab has now; prefab.refresh updates it"`,
}

Api_Prefab_Inspect_Result :: struct {
    id:base.Entity_Id `mirai:"optional,label=With id: the entity"`,
    locked:bool `mirai:"optional,label=With id: whether it keeps the place its prefab gives it as a member of an instance that is not its root"`,
    links:[1]Api_Prefab_Link `mirai:"list,optional,label=With id: the instance placed in the document it belongs to and then each one that instance brought in"`,
    overrides:[1]Api_Prefab_Override `mirai:"list,optional,label=With id: what it holds that its prefab does not; its placement left out"`,
    asset:base.Asset_Id `mirai:"optional,label=With path or asset: the prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=With path or asset: the file of the prefab"`,
    root:base.Entity_Id `mirai:"optional,label=With path or asset: the root of the prefab"`,
    entities:[1]Api_Prefab_Entity `mirai:"list,optional,label=With path or asset: every entity of the prefab"`,
    instances:int `mirai:"optional,label=With path or asset: the instances of other prefabs it places"`,
    base:Api_Asset_Id `mirai:"optional,label=With path or asset: the prefab its root is an instance of when it is a variant; zero when it is not"`,
    chain:[1]Api_Asset_Id `mirai:"list,optional,label=With path or asset: its base, the base of that one and so on"`,
}
// base.Asset_Id where a field is named base.
Api_Asset_Id :: base.Asset_Id

Api_Prefab_Link :: struct {
    instance:u32,
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the prefab; empty when it is missing"`,
    root:base.Entity_Id,
    outer:u32 `mirai:"label=The instance that brought it in; 0 when it was placed in the document"`,
    source:base.Entity_Id `mirai:"label=The entity of the prefab the entity stands for"`,
}
Api_Prefab_Override :: struct {
    path:[256]u8 `mirai:"text,label=name; child; a component or Component.field"`,
    kind:[8]u8 `mirai:"text,label=field; added; removed; turned or child"`,
    instance:u32,
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
    case .Unknown_Entity,.No_Id,.Not_Found,.Unknown_Path,.Not_Instance,.Not_Variant: code=api.INVALID_PARAMS
    }
    api.call_fail(call,code,prefab_error_text(error))
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
    prefab_observe(s)
    w:=call.out
    serial.text_write_raw(w,`{"prefabs":[`)
    first:=true
    if a!=nil {
        assets_rescan(s)
        for &file in a.registry.files {
            if file.state!=.Asset || file.kind!=asset.KIND_PREFAB || !asset.registry_listed(&file) {continue}
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
        serial.text_write_raw(w,`{"instance":`);serial.text_write_uint(w,u64(state.instance))
        api.write_key(w,"asset");api_asset_write(w,state.asset)
        api.write_key(w,"path");serial.text_write_string(w,state.path)
        api.write_key(w,"root");api_write_id(w,state.root)
        api.write_key(w,"outer");serial.text_write_uint(w,u64(state.outer))
        api.write_key(w,"members");serial.text_write_int(w,i64(state.members))
        api.write_key(w,"overrides");serial.text_write_int(w,i64(state.overrides))
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
    prefab_observe(s)
    w:=call.out
    world:=edited_world(s)
    if params.entity!=0 {
        e:=api_entity(world,params.entity)
        if e==core.NONE {
            api.call_failf(call,api.INVALID_PARAMS,"id 0x%016x is not an entity of the scene",u64(params.entity))
            return
        }
        previous:=s.document.previous
        serial.text_write_raw(w,`{"id":`);api_write_id(w,params.entity)
        api.write_key(w,"locked");api.write_flag(w,prefab_member_locked(s,world,e))
        api.write_key(w,"links");serial.write_u8(w,'[')
        overrides:=make([dynamic]asset.Override,call.allocator)
        if previous!=nil {
            first:=true
            // The instance placed in the document first, then each one it brought in.
            for member in previous.members {
                if member.entity!=params.entity {continue}
                at:=asset.scene_instance_find(previous,member.instance)
                if at<0 {continue}
                instance:=previous.instances[at]
                if !first {serial.write_u8(w,',')}
                first=false
                file,_,_:=prefab_file(s,instance.prefab)
                serial.text_write_raw(w,`{"instance":`);serial.text_write_uint(w,u64(instance.id))
                api.write_key(w,"asset");api_asset_write(w,instance.prefab)
                api.write_key(w,"path");serial.text_write_string(w,file!=nil?file.path:"")
                api.write_key(w,"root");api_write_id(w,instance.root)
                api.write_key(w,"outer");serial.text_write_uint(w,u64(instance.outer))
                api.write_key(w,"source");api_write_id(w,member.source)
                serial.write_u8(w,'}')
            }
            for override in previous.overrides {
                if override.entity==params.entity {append(&overrides,override)}
            }
        }
        serial.write_u8(w,']')
        api.write_key(w,"overrides");serial.write_u8(w,'[')
        first:=true
        for &override in overrides {
            kind:=override.kind
            root:=base.Entity_Id(0)
            if previous!=nil {
                if at:=asset.scene_instance_find(previous,override.instance);at>=0 {root=previous.instances[at].root}
            }
            if prefab_placement(&override,root) {continue}
            if !first {serial.write_u8(w,',')}
            first=false
            serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,prefab_override_name(s,&override,call.allocator))
            kinds:=[asset.Override_Kind]string{.Field="field",.Added="added",.Removed="removed",.Turned="turned",.Child="child"}
            api.write_key(w,"kind");serial.text_write_string(w,kinds[kind])
            api.write_key(w,"instance");serial.text_write_uint(w,u64(override.instance))
            serial.write_u8(w,'}')
        }
        serial.text_write_raw(w,"]}")
        return
    }
    id,error:=prefab_locate(s,base.text_get(params.asset[:]))
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
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
    api.write_key(w,"root");api_write_id(w,root)
    api.write_key(w,"entities");serial.write_u8(w,'[')
    for row in 0..<asset.scene_entity_count(loaded) {
        record:=asset.scene_entity(loaded,row)
        if row>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"id":`);api_write_id(w,record.id)
        api.write_key(w,"parent")
        if record.parent!=0 {api_write_id(w,record.parent)} else {serial.text_write_raw(w,"null")}
        api.write_key(w,"name");serial.text_write_string(w,record.name)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    api.write_key(w,"instances");serial.text_write_int(w,i64(len(loaded.instances)))
    chain:=prefab_variant_chain(s,id)
    api.write_key(w,"base");api_asset_write(w,len(chain)>0?chain[0]:{})
    api.write_key(w,"chain");serial.write_u8(w,'[')
    for link,at in chain {
        if at>0 {serial.write_u8(w,',')}
        api_asset_write(w,link)
    }
    serial.text_write_raw(w,"]}")
}

@(private)
api_prefab_entity :: proc(s:^Session,call:^api.Call,id:base.Entity_Id) -> (e:core.Entity,ok:bool) {
    e=api_entity(edited_world(s),id)
    if e==core.NONE {
        api.call_failf(call,api.INVALID_PARAMS,"id 0x%016x is not an entity of the scene",u64(id))
        return core.NONE,false
    }
    return e,true
}

// A file for a new prefab of this name that no asset takes.
@(private)
api_prefab_new_path :: proc(s:^Session,name:string) -> string {
    clean:=strings.builder_make(context.temp_allocator)
    for c in strings.trim_space(name) {
        if strings.contains_rune(`<>:"/\|?*`,c) {strings.write_byte(&clean,'_')} else {strings.write_rune(&clean,c)}
    }
    stem:=strings.to_string(clean)
    if stem=="" {stem="prefab"}
    path:=fmt.tprintf("prefabs/%s.prefab",stem)
    r:=&s.app.assets.registry
    for i:=2;;i+=1 {
        _,taken:=asset.registry_find_path(r,path)
        if !taken && !os.exists(project.path(r.root,path,allocator=context.temp_allocator)) {return path}
        path=fmt.tprintf("prefabs/%s_%d.prefab",stem,i)
    }
}

@(private)
api_prefab_create :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Create_Params)
    if !api_guard(s,call) {return}
    e,found:=api_prefab_entity(s,call,params.entity)
    if !found {return}
    path:=base.text_get(params.path[:])
    if path=="" {path=api_prefab_new_path(s,entity_name(edited_world(s),e))}
    id,error:=prefab_create(s,e,path)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    result:=api.call_result(call,Api_Prefab_Created_Result)
    result.id,result.asset=params.entity,id
    if file,_,ok:=prefab_file(s,id);ok {api_text_put(result.path[:],file.path)}
}

@(private)
api_prefab_instantiate :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Instantiate_Params)
    if !api_guard(s,call) {return}
    id,locate_error:=prefab_locate(s,base.text_get(params.asset[:]))
    if locate_error!=.None {
        api_prefab_fail(call,locate_error)
        return
    }
    placement:=Prefab_Placement{position=params.position,scale_multiplier=params.scale_multiplier}
    if params.parent!=0 {
        parent,found:=api_prefab_entity(s,call,params.parent)
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
    if file,_,ok:=prefab_file(s,id);ok {api_text_put(result.path[:],file.path)}
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
    e,found:=api_prefab_entity(s,call,params.entity)
    if !found {return}
    count,error:=prefab_apply(s,e,api_paths_split(base.text_get(params.paths[:])),false,params.target)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    api.call_result(call,Api_Prefab_Count_Result)^={params.entity,count}
}

@(private)
api_prefab_variant_create :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Variant_Params)
    if !api_guard(s,call) {return}
    base_id,locate_error:=prefab_locate(s,base.text_get(params.prefab[:]))
    if locate_error!=.None {
        api_prefab_fail(call,locate_error)
        return
    }
    path:=base.text_get(params.path[:])
    if path=="" {
        file,_,_:=prefab_file(s,base_id)
        path=api_prefab_new_path(s,fmt.tprintf("%s_variant",asset_name(file.path)))
    }
    id,error:=prefab_variant_create(s,base_id,path)
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    result:=api.call_result(call,Api_Prefab_Variant_Result)
    result.asset=id
    if file,_,ok:=prefab_file(s,id);ok {api_text_put(result.path[:],file.path)}
}

@(private)
api_prefab_revert :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Entity_Params)
    if !api_guard(s,call) {return}
    e,found:=api_prefab_entity(s,call,params.entity)
    if !found {return}
    count,error:=prefab_revert(s,e,api_paths_split(base.text_get(params.paths[:])))
    if error!=.None {
        api_prefab_fail(call,error)
        return
    }
    api.call_result(call,Api_Prefab_Count_Result)^={params.entity,count}
}

@(private)
api_prefab_refresh :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Prefab_Params)
    if !api_guard(s,call) {return}
    id:base.Asset_Id
    if named:=base.text_get(params.asset[:]);named!="" {
        located,error:=prefab_locate(s,named)
        if error!=.None {
            api_prefab_fail(call,error)
            return
        }
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
    e,found:=api_prefab_entity(s,call,params.entity)
    if !found {return}
    if error:=prefab_unlink(s,e,params.recursive);error!=.None {
        api_prefab_fail(call,error)
        return
    }
    api.call_result(call,Api_Edit_Result).id=params.entity
}
