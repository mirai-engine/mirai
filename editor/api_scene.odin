package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// The scene through the agent API. Entities are named by their Id, as
// hexadecimal strings; transforms are local to the parent, with the rotation
// in degrees; the value of a component is the JSON of its schema, so the
// components of a game or a plugin need no code here. Entities are changed
// by scene.write alone (api_scene_write.odin).

API_INSPECT_DEFAULT :: 256 // entities an inspect gives when a filter narrows it
API_INSPECT_BRIEF :: 24     // and when none does

Api_Inspect_Params :: struct {
    root:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=By its name or a path Parent/Child or its id: this entity and what hangs from it nested by children; the document scene.write takes"`,
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=By its name or a path Parent/Child or its id or handle: only this entity"`,
    name:[128]u8 `mirai:"optional,text,label=Only the entities with this name; * stands for any run of characters"`,
    component:[64]u8 `mirai:"optional,text,label=Only the entities that have this component"`,
    components:serial.Json `mirai:"optional,label=true: the values of every component; a list of names: only those; omitted: id, name, parent, position and the names of the components"`,
    include_runtime:bool `mirai:"optional,label=Include hidden fields and transient component state for inspection"`,
    offset:int `mirai:"optional,min=0"`,
    limit:int `mirai:"optional,min=0,max=4096,clamp,label=Entities it gives at most; 0 or omitted: a few when no entity or name or component narrows them"`,
    player:int `mirai:"optional,min=0,max=3,label=play.inspect: the run of that player of a game a turn plays on the network"`,
    storages:bool `mirai:"optional,label=Include the storages of the world by name with their values: in play.inspect the score or the state of a match"`,
    storage:[64]u8 `mirai:"optional,text,label=Only the storages with this name (* stands for any run of characters); implies storages; without entity or name or component it answers no entities"`,
}

Api_Edit_Result :: struct {
    id:base.Entity_Id `mirai:"label=The entity; the new one when the method makes one"`,
}

Api_Path_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=A file or a path inside the asset folder; the file of the document when empty"`,
}

Api_File_Result :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file of the document"`,
    entities:int `mirai:"label=Entities alive in the scene"`,
    dirty:bool `mirai:"label=Whether the document has unsaved changes"`,
}

Api_Inspect_Result :: struct {
    path:[DOCUMENT_PATH_BYTES]u8 `mirai:"text,label=The file of the document; empty before it has one"`,
    dirty:bool `mirai:"label=Whether the document has unsaved changes"`,
    playing:bool `mirai:"label=scene.inspect: whether the editor is out of Edit mode; play.inspect: true"`,
    total:int `mirai:"label=Entities alive in the world"`,
    offset:int,
    entities:[]Api_Inspect_Entity `mirai:"label=Parents before their children and siblings in their order"`,
    shown:int,
    matched:int `mirai:"label=Entities the filters take"`,
    omitted:int `mirai:"label=Entities matched past the limit"`,
    left_out:[256]u8 `mirai:"text,optional,label=What the answer leaves out and how to ask for it"`,
    storages:serial.Json `mirai:"optional,label=With storages: by name the value of each storage of the world that is plain data with Entity fields as the entities are named"`,
    tree:serial.Json `mirai:"optional,label=With root: the entities scene.write takes, that entity with what hangs from it nested by children"`,
}
Api_Inspect_Entity :: struct {
    id:base.Entity_Id `mirai:"optional,label=The id; omitted for an entity of a game that has none"`,
    entity:core.Entity `mirai:"optional,label=play.inspect: the handle of the entity in the game"`,
    name:[64]u8 `mirai:"text"`,
    parent:serial.Json `mirai:"label=The id of the parent (in play.inspect its handle); null for a root"`,
    position:[3]f32 `mirai:"label=Local to the parent"`,
    rotation_deg:[3]f32 `mirai:"label=Local to the parent in degrees"`,
    scale:[3]f32,
    world_position:[3]f32,
    visible:bool,
    enabled:bool,
    active:bool `mirai:"label=Whether it runs: false when it or a parent is disabled"`,
    off:[][64]u8 `mirai:"text,optional,label=The components turned off by themselves"`,
    prefab:Api_Inspect_Prefab `mirai:"optional,label=scene.inspect: the link of a member of an instance of a prefab"`,
    components:serial.Json `mirai:"label=By name the value of each component as component.list describes it with Entity fields holding ids (in play.inspect handles); without components in the params the list of their names"`,
}
Api_Inspect_Prefab :: struct {
    instance:base.Entity_Id `mirai:"label=The instance placed in the document as prefab.list lists it"`,
    asset:base.Asset_Id `mirai:"label=The prefab"`,
    source:base.Entity_Id `mirai:"label=The entity of the prefab it stands for"`,
    root:bool `mirai:"label=Whether it is the root of the instance"`,
}

@(private)
api_scene_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="scene.inspect",summary="The entities of the document in save order with their place and the names of their components; with components, their transforms, prefab links and values; with root, that entity and what hangs from it as the nested document scene.write takes.",params=type_info_of(Api_Inspect_Params),result=type_info_of(Api_Inspect_Result),flags={.Core,.Read_Only},run=api_scene_inspect})
    api_register(s,st,{name="play.inspect",summary="As scene.inspect, on the world of the game that plays, whose entities are named by their handle; with storages, also its storages: the score or the state of a match.",params=type_info_of(Api_Inspect_Params),result=type_info_of(Api_Inspect_Result),flags={.Core,.Read_Only},run=api_play_inspect})
    api_register(s,st,{name="play.player",summary="The focused local seat of the game that plays, the body it drives and the camera that shows it. play.inspect with include_runtime reads the rest.",params=type_info_of(Api_Play_Player_Params),result=type_info_of(Api_Play_Player_Result),flags={.Read_Only},run=api_play_player})
    api_scene_write_register(s,st)
    api_register(s,st,{name="scene.save",flags={.Core},summary="Writes the document to its file or to another, which becomes its file.",params=type_info_of(Api_Path_Params),result=type_info_of(Api_File_Result),run=api_scene_save})
    api_register(s,st,{name="scene.open",summary="Opens a scene or a prefab file as the document, with an empty history.",params=type_info_of(Api_Path_Params),result=type_info_of(Api_File_Result),flags={.Destructive},run=api_scene_open})
}

// ---------------------------------------------------------------- scene.inspect

// The component values the API names: what a scene saves, besides the identity and the place of an entity.
@(private)
api_component_listed :: proc(s:^Session,t:^core.Table_Info,include_runtime:=false) -> bool {
    if t.place!=.World || (!inspector_listed(s,t) && !(include_runtime && !author.type_saved(t.info))) {return false}
    st:=api_state(s)
    return st.types[api_table_index(s,t)]!=serial.TYPE_NONE
}

// The bytes of a component value as the API shows them: Entity fields hold
// Ids, or with handles the live entities, as a play world names them.
@(private)
api_value_out :: proc(w:core.World_Ref,type:^runtime.Type_Info,value:rawptr,bytes:[]u8,handles:=false) {
    size:=type.size
    if size>0 {runtime.mem_copy(raw_data(bytes),value,size)}
    if handles {return}
    for offset in entity_offsets(type) {
        field:=cast(^u64)&bytes[offset]
        field^=u64(api_entity_id(w,core.Entity(field^)))
    }
}

// Which components of an entity an inspect gives the values of.
@(private)
Api_Inspect_Values :: struct {
    every,listed:bool, // listed: the param gave a list of names, perhaps empty
    only:[]^core.Table_Info,
}

// What the param components of an inspect asks: true, every component; a
// list of names or one name, those; left out, none. false after failing the
// call.
@(private)
api_inspect_values :: proc(s:^Session,call:^api.Call,w:core.World_Ref,include_runtime:bool) -> (values:Api_Inspect_Values,ok:bool) {
    given:[1]string
    if !api.object_values(call.allocator,call.raw,{"components"},given[:]) || given[0]=="" {return {},true}
    if given[0]=="true" {return {every=true},true}
    names,is_list:=api.json_elements(given[0],call.allocator)
    if !is_list {
        names=make([dynamic]string,call.allocator)
        append(&names,given[0])
    }
    only:=make([dynamic]^core.Table_Info,call.allocator)
    for each in names {
        name,is_text:=api.json_string(each)
        if !is_text {api.call_fail(call,api.INVALID_PARAMS,"components must be true or a list of names of components");return}
        t,problem:=api_component_named(w,name)
        if t==nil {api.call_failf(call,api.INVALID_PARAMS,"components: %s; component.list lists them",problem);return}
        if !api_component_listed(s,t,include_runtime) {api.call_failf(call,api.INVALID_PARAMS,"components: %s has no values an inspect gives: Transform, Name, Parent, Hidden and Disabled have their own fields, and include_runtime gives the state of a game",name);return}
        append(&only,t)
    }
    return {listed=true,only=only[:]},true
}

@(private)
api_inspect_wants :: proc(values:Api_Inspect_Values,t:^core.Table_Info) -> bool {
    return values.every || slice.contains(values.only,t)
}

// What an inspect gives of an entity: its place and, with components false,
// the names of its components, or else their values; only: those of these
// tables and no others.
@(private)
api_entity_inspect :: proc(s:^Session,w:core.World_Ref,e:core.Entity,components:bool,scratch:[]u8,play:bool,include_runtime:=false,only:[]^core.Table_Info=nil,allocator:=context.temp_allocator) -> (r:Api_Inspect_Entity) {
    st:=api_state(s)
    r.id=api_entity_id(w,e)
    if play {r.entity=e}
    base.text_set(r.name[:],entity_name(w,e))
    parent:=entity_parent(w,e)
    switch {
    case play && parent!=core.NONE: r.parent=serial.Json(fmt.aprintf(`"0x%016x"`,u64(parent),allocator=allocator))
    case parent!=core.NONE && api_entity_id(w,parent)!=0: r.parent=serial.Json(fmt.aprintf(`"0x%016x"`,u64(api_entity_id(w,parent)),allocator=allocator))
    case: r.parent="null"
    }
    local:=entity_local(w,e)
    r.position,r.scale,r.rotation_deg=local.position,local.scale,mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    r.world_position=entity_world(w,e).position
    r.visible,r.enabled,r.active=!entity_has(w,e,erender.Hidden),!entity_has(w,e,core.Disabled),!core.entity_off(core.world_entities(w),e)
    off:=make([dynamic][64]u8,allocator)
    for &t in s.info.tables {
        if !api_component_listed(s,&t,include_runtime) {continue}
        if _,turned_off,_:=core.raw_state(core.world_table_at(w,&t),e);turned_off {name:[64]u8;base.text_set(name[:],t.name);append(&off,name)}
    }
    r.off=off[:]
    if link,linked:=prefab_link_of(w,e);linked && !play {r.prefab={instance=api_entity_id(w,link.instance),asset=link.asset,source=link.source,root=link.root}}
    // The values are of the components the world declares: an object whose keys it names.
    out:serial.Writer
    serial.writer_init(&out,0,allocator)
    serial.write_u8(&out,'{' if components else '[')
    for &t,i in s.info.tables {
        if !api_component_listed(s,&t,include_runtime) || components && only!=nil && !slice.contains(only,&t) {continue}
        value:=core.raw_find(core.world_table_at(w,&t),t.info,e)
        if value==nil {continue}
        if out.count>1 {serial.write_u8(&out,',')}
        serial.text_write_string(&out,t.name)
        if !components {continue}
        serial.text_write_raw(&out,": ")
        api_value_out(w,t.info,value,scratch,play)
        omitted:=serial.Field_Flags{.Transient,.Hidden} if !include_runtime else serial.Field_Flags{}
        serial.text_write(&out,&st.schema,st.types[i],scratch[:t.info.size],.Line,omit_fields=omitted)
    }
    serial.write_u8(&out,'}' if components else ']')
    r.components=serial.Json(string(serial.writer_bytes(&out)))
    return
}

// What an inspect gives of an entity, as JSON.
@(private)
api_entity_write :: proc(s:^Session,w:core.World_Ref,out:^serial.Writer,e:core.Entity,components:bool,scratch:[]u8,play:bool,include_runtime:=false,only:[]^core.Table_Info=nil) {
    text,_:=serial.text_encode(api_entity_inspect(s,w,e,components,scratch,play,include_runtime,only),.Line,context.temp_allocator,sparse=true)
    serial.text_write_raw(out,string(text))
}

// The entities of a world depth first, parents before children, siblings in their order.
api_entities_ordered :: proc(w:core.World_Ref,allocator:=context.temp_allocator) -> []core.Entity {
    transforms:=core.world_table_of(w,core.Transform)
    parents:=core.world_table_of(w,core.Parent)
    h:=entity_hierarchy(w)
    out:=make([dynamic]core.Entity,allocator)
    if transforms==nil {return out[:]}
    for e in transforms.entities {
        if parents!=nil && core.has(parents,e) {continue}
        for at:=e;at!=core.NONE;at=core.subtree_next(h,e,at) {append(&out,at)}
    }
    return out[:]
}

@(private)
api_inspect_run :: proc(s:^Session,call:^api.Call,w:core.World_Ref,play:bool) {
    params:=api.call_params(call,Api_Inspect_Params)
    narrowed:=base.text_get(params.entity[:])!="" || base.text_get(params.name[:])!="" || base.text_get(params.component[:])!=""
    if params.limit==0 {params.limit=narrowed || base.text_get(params.root[:])!=""?API_INSPECT_DEFAULT:API_INSPECT_BRIEF}
    if base.text_get(params.root[:])!="" {
        if play {api.call_fail(call,api.INVALID_PARAMS,"root is of scene.inspect: the document scene.write takes");return}
        api_inspect_tree(s,call,w,params)
        return
    }
    st:=api_state(s)
    scratch,memory:=make([]u8,max(st.largest,1),call.allocator)
    if memory!=nil {
        api.call_fail(call,api.INTERNAL_ERROR,"the request needs more scratch memory than the server has")
        return
    }
    only:core.Entity
    if base.text_get(params.entity[:])!="" {
        known:bool
        if only,known=api_call_entity(call,w,params.entity[:],game=play);!known {return}
    }
    pattern:=base.text_get(params.name[:])
    component:^core.Table_Info
    if name:=base.text_get(params.component[:]);name!="" {
        problem:string
        if component,problem=api_component_named(w,name);component==nil {
            api.call_failf(call,api.INVALID_PARAMS,"component: %s; component.list lists them",problem)
            return
        }
    }
    values,read:=api_inspect_values(s,call,w,params.include_runtime)
    if !read {return}
    storages:=base.text_get(params.storage[:])
    if storages!="" && !api_storage_named(s,storages) {
        api.call_failf(call,api.INVALID_PARAMS,"storage %q names no storage of the world the API shows; leave it out with storages true to list them all",storages)
        return
    }
    entities:=core.world_entities(w)
    offset:=only!=core.NONE?0:params.offset
    // Naming a storage asks for it alone, unless the entities are named too.
    r:=api.call_result(call,Api_Inspect_Result)
    base.text_set(r.path[:],document_path(s.document))
    r.dirty,r.playing,r.total,r.offset=document_dirty(s),play || s.mode!=.Edit,entities.alive,offset
    only_storages:=storages!="" && !narrowed
    candidates:=[]core.Entity{only} if only!=core.NONE else api_entities_ordered(w)
    if only_storages {candidates=nil}
    shown:=make([dynamic]Api_Inspect_Entity,call.allocator)
    for e in candidates {
        if pattern!="" && !api_name_match(pattern,entity_name(w,e)) {continue}
        if component!=nil && core.raw_find(core.world_table_at(w,component),component.info,e)==nil {continue}
        r.matched+=1
        if r.matched<=offset || len(shown)>=params.limit {continue}
        append(&shown,api_entity_inspect(s,w,e,values.every || len(values.only)>0,scratch,play,params.include_runtime,values.only,call.allocator))
    }
    r.entities,r.shown=shown[:],len(shown)
    r.omitted=max(r.matched-offset-r.shown,0)
    if r.omitted>0 {
        base.text_set(r.left_out[:],fmt.tprintf("%d more entities: ask for them with entity, name or component, or with offset and limit",r.omitted))
    } else if only_storages {
        base.text_set(r.left_out[:],"the entities: with storages they come only with entity, name or component")
    }
    if params.storages || storages!="" {r.storages=api_storages_json(s,w,storages,scratch,play,params.include_runtime,call.allocator)}
}

// The storages of a world the API shows whose name is the pattern ("": all),
// as an object by name: the world names its keys.
@(private)
api_storages_json :: proc(s:^Session,w:core.World_Ref,pattern:string,scratch:[]u8,handles,include_runtime:bool,allocator:=context.temp_allocator) -> serial.Json {
    st:=api_state(s)
    out:serial.Writer
    serial.writer_init(&out,0,allocator)
    serial.write_u8(&out,'{')
    for &info,i in s.info.storages {
        if st.storage_types[i]==serial.TYPE_NONE || pattern!="" && !api_name_match(pattern,info.name) {continue}
        value:=rawptr(uintptr(w.data)+info.offset)
        api_value_out(w,info.info,value,scratch,handles)
        if out.count>1 {serial.write_u8(&out,',')}
        serial.text_write_string(&out,info.name);serial.text_write_raw(&out,": ")
        omitted:=serial.Field_Flags{.Transient,.Hidden} if !include_runtime else serial.Field_Flags{}
        serial.text_write(&out,&st.schema,st.storage_types[i],scratch[:info.info.size],.Line,omit_fields=omitted)
    }
    serial.write_u8(&out,'}')
    return serial.Json(string(serial.writer_bytes(&out)))
}

// Whether a storage the API shows has a name the pattern takes.
@(private)
api_storage_named :: proc(s:^Session,pattern:string) -> bool {
    st:=api_state(s)
    for &info,i in s.info.storages {
        if st.storage_types[i]!=serial.TYPE_NONE && api_name_match(pattern,info.name) {return true}
    }
    return false
}

// Whether a name is the pattern, where * stands for any run of characters.
api_name_match :: proc "contextless" (pattern,name:string) -> bool {
    p,n:=0,0
    star,resume:=-1,0
    for n<len(name) {
        switch {
        case p<len(pattern) && pattern[p]=='*':
            star,resume=p,n
            p+=1
        case p<len(pattern) && pattern[p]==name[n]:
            p+=1;n+=1
        case star>=0:
            resume+=1
            p,n=star+1,resume
        case:
            return false
        }
    }
    for p<len(pattern) && pattern[p]=='*' {p+=1}
    return p==len(pattern)
}

@(private)
api_scene_inspect :: proc(s:^Session,call:^api.Call) {api_inspect_run(s,call,edited_world(s),false)}

@(private)
api_play_inspect :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call,api.call_params(call,Api_Inspect_Params).player)
    if r==nil {api_no_game(call);return}
    api_inspect_run(s,call,core.world_ref(r.world,s.info),true)
}

// ---------------------------------------------------------------- values

// The path of the first read-only field whose bytes the reader changed; "" when none did.
@(private)
read_only_written :: proc(schema:^serial.Schema,type:serial.Type_Index,before,after:[]u8,prefix:string) -> string {
    return author.read_only_written(schema,type,before,after,prefix)
}

// The value a component starts with, as the API shows it: Entity fields hold no id.
@(private)
component_start :: proc(t:^core.Table_Info,bytes:[]u8) {
    mem.zero_slice(bytes)
    if t.default!=nil {t.default(raw_data(bytes))} else {component_default(t.type,bytes)}
    for offset in entity_offsets(t.info) {(cast(^u64)&bytes[offset])^=0}
}

// The value of a component with the JSON object at r applied over it: the
// current value, or the default without one, with the fields the object
// names. from, a value as the API shows it, is where it starts instead,
// keeping of the current value only what the API neither shows nor changes:
// hidden, transient and read-only fields. An Entity field holds the id it
// names, which must be an entity of the scene of w. path names the value in
// the messages.
component_value_read :: proc(w:core.World_Ref,t:^core.Table_Info,current:rawptr,schema:^serial.Schema,type:serial.Type_Index,r:^serial.Text_Reader,bytes:[]u8,path:string,allocator:runtime.Allocator,read_only_kept:=false,from:[]u8=nil) -> (message:string,ok:bool) {
    if from!=nil {
        copy(bytes,from)
        if current!=nil {
            kept:=make([]u8,len(bytes),allocator)
            api_value_out(w,t.info,current,kept)
            author.fields_kept(schema,type,bytes,kept)
        }
    } else if current!=nil {
        api_value_out(w,t.info,current,bytes)
    } else {
        component_start(t,bytes)
    }
    before:=read_only_kept?slice.clone(bytes,allocator):nil
    if !serial.text_read(r,schema,type,bytes) {
        line,column:=serial.text_position(r.text,r.error.offset)
        return fmt.aprintf("%s at line %d column %d",serial.text_error_message(r,path,allocator),line,column,allocator=allocator),false
    }
    if field:=read_only_kept?read_only_written(schema,type,before,bytes,""):"";field!="" {
        return fmt.aprintf("%s.%s is read only: leave it out of the value",path,field,allocator=allocator),false
    }
    if message,valid:=api.value_check(schema,type,bytes,path,allocator);!valid {return message,false}
    for offset in entity_offsets(t.info) {
        field:=cast(^u64)&bytes[offset]
        named:=field^
        if named==0 {continue}
        target:=api_entity(w,base.Entity_Id(named))
        if target==core.NONE {return fmt.aprintf("%s names 0x%016x, which is not an entity of the scene",path,named,allocator=allocator),false}
        field^=u64(target)
    }
    return "",true
}

// ---------------------------------------------------------------- files

@(private)
api_file_result :: proc(s:^Session,call:^api.Call) {
    result:=api.call_result(call,Api_File_Result)
    result.entities,result.dirty=core.world_entities(edited_world(s)).alive,document_dirty(s)
    base.text_set(result.path[:],document_path(s.document))
}

@(private)
api_document_fail :: proc(call:^api.Call,error:Document_Error,path:string) {
    api.call_failf(call,api.SERVER_ERROR,"%s: %s",path,document_error_text(error))
}

@(private)
api_scene_save :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Path_Params)
    // A person saves what is in front, picks the file of Save as, and is asked
    // about the unsaved assets the scene uses.
    if api_person(s) {
        switch {
        case api_asks(s,base.text_get(params.path[:])): dialog_save(s)
        case asset_document_active(s)!=nil:             asset_document_save(s)
        case:                                           save_request(s)
        }
        api_file_result(s,call)
        return
    }
    if !api_guard(s,call) {return}
    if !collab_can_save(s) {
        api.call_fail(call,api.SERVER_ERROR,"The host of the session saves the shared scene")
        return
    }
    path:=base.text_get(params.path[:])
    if path=="" {path=document_path(s.document)}
    if path=="" {
        api.call_fail(call,api.SERVER_ERROR,"The scene has no file yet; pass a path")
        return
    }
    if error:=scene_save(s,strings.clone(path,call.allocator));error!=.None {
        api_document_fail(call,error,path)
        return
    }
    api_file_result(s,call)
}

@(private)
api_scene_open :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"replace the document and its history") {return}
    params:=api.call_params(call,Api_Path_Params)
    if !collab_can_open(s) {
        api.call_fail(call,api.SERVER_ERROR,"Leave the session before opening another scene (collab.leave)")
        return
    }
    path:=base.text_get(params.path[:])
    if path=="" {path=document_path(s.document)}
    if path=="" {
        api.call_fail(call,api.SERVER_ERROR,"The scene has no file yet; pass a path")
        return
    }
    target:=strings.clone(path,call.allocator)
    tools_release(s)
    if error:=scene_open(s,target);error!=.None {
        api_document_fail(call,error,target)
        return
    }
    host.load_ready(s.app,.Scene,core.world_entities(edited_world(s)).alive)
    api_file_result(s,call)
}
