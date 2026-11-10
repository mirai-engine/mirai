package editor

import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// What the API tells of the building blocks of the project: the components
// of its world with their fields, and the assets of its registry.

API_COMPONENT_NAMES :: 16 // components component.list gives whole in one call

Api_Component_Params :: struct {
    names:[API_COMPONENT_NAMES][64]u8 `mirai:"text,optional,label=The components to give with defaults and fields (name for one); without any: all their names with what each is"`,
    include_runtime:bool `mirai:"optional,label=Include the components the engine derives and the hidden and transient fields with their defaults"`,
}

Api_Component_List :: struct {
    components:[1]Api_Component_Entry `mirai:"list"`,
    left_out:[256]u8 `mirai:"text,optional,label=What the answer leaves out and how to ask for it"`,
}
Api_Component_Entry :: struct {
    name:[64]u8 `mirai:"text"`,
    library:[64]u8 `mirai:"text,label=The package that declares it"`,
    description:[1024]u8 `mirai:"text,optional"`,
    plain_data:bool `mirai:"optional,label=Present and false when the component is not plain data: it has no default nor fields"`,
    default:u8 `mirai:"any,optional,label=The value of a new component"`,
    fields:[1]Api_Component_Field `mirai:"list,optional,label=Every field down to those of nested structs"`,
}
Api_Component_Field :: struct {
    path:[256]u8 `mirai:"text,label=The field after those it is inside; separated by dots"`,
    type:[16]u8 `mirai:"text,label=Bool Int Uint Float Enum Bit_Set Entity Entity_Id Asset or Array; Text Color or Quaternion by its flags"`,
    element:[16]u8 `mirai:"text,optional,label=Of an Array: the kind of its elements"`,
    count:int `mirai:"optional,label=Of an Array: its length"`,
    options:[1][64]u8 `mirai:"text,list,optional,label=Of an Enum or a Bit_Set: the names it takes"`,
    min:f32 `mirai:"optional"`,
    max:f32 `mirai:"optional"`,
    unit:[32]u8 `mirai:"text,optional"`,
    label:[256]u8 `mirai:"text,optional,label=The name the inspector shows"`,
    read_only:bool `mirai:"optional,label=Present and true when scene.add and scene.set refuse to change it"`,
    description:[1024]u8 `mirai:"text,optional"`,
}

Api_Asset_Params :: struct {
    kind:[32]u8 `mirai:"text,optional,label=Only the assets of this kind as the results name it (mesh; material; sound set or one of a plugin), or prefab for the scenes with exactly one root; empty or all: every kind"`,
    folder:[256]u8 `mirai:"text,optional,label=Only the assets under this folder"`,
    offset:int `mirai:"optional,min=0,max=1000000"`,
    limit:int `mirai:"optional,min=1,max=1024,clamp"`,
}

Api_Asset_List :: struct {
    root:[API_PATH_BYTES]u8 `mirai:"text,label=The asset folder"`,
    assets:[1]Api_Asset_Entry `mirai:"list"`,
    total:int `mirai:"label=Assets the filters take"`,
    offset:int,
    shown:int,
    broken:int `mirai:"label=Files that start as assets and contradict themselves"`,
    duplicates:int `mirai:"label=Files with the id of another; engine.diagnostics tells each"`,
    missing:int `mirai:"label=Dependencies that no file of the registry is"`,
}
Api_Asset_Entry :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Under the asset folder"`,
    asset:base.Asset_Id,
    kind:[32]u8 `mirai:"text,label=The name of its kind (mesh; texture; material...); other for a kind this build does not know"`,
    prefab:bool `mirai:"optional,label=Of a scene: whether it has exactly one root, which makes it a prefab that prefab.instantiate and scene.spawn place"`,
    size:int `mirai:"label=Bytes of the file"`,
    dependencies:int `mirai:"label=Assets it uses"`,
    used_by:int `mirai:"label=Files that use it"`,
    owner:base.Asset_Id `mirai:"optional,label=The asset it is a part of"`,
}

// What api_asset_detach (assets_parts.odin) writes.
Api_Detach_Result :: struct {
    asset:base.Asset_Id `mirai:"label=The part"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Its path under the asset folder"`,
    owner:base.Asset_Id `mirai:"label=The asset it was a part of"`,
    unsaved:bool `mirai:"label=Always true: the change waits for asset.save"`,
}

// What api_asset_delete (asset_delete.odin) writes.
Api_Asset_Delete_Result :: struct {
    moved:[1][API_PATH_BYTES]u8 `mirai:"text,list,label=The paths moved to the trash: the asset and its parts"`,
    used_by:[1][API_PATH_BYTES]u8 `mirai:"text,list,label=The files that use what moved; they keep the reference"`,
    error:[API_PATH_BYTES+64]u8 `mirai:"text,optional,label=Why the rest could not be moved after some were"`,
}

@(private)
api_assets_register :: proc(s:^Session,st:^Api_State) {
    assets:=Api_Asset_Params{limit=256}
    api_register(s,st,{name="component.list",summary="The components a scene can hold, with their defaults and their fields as scene.add and scene.set take them.",params=Api_Component_Params,result=Api_Component_List,writes_result=true,flags={.Core,.Read_Only},run=api_component_list})
    api_register(s,st,{name="asset.list",summary="The assets of the registry by kind and folder, with a count of its broken files, duplicated ids and missing dependencies.",params=Api_Asset_Params,result=Api_Asset_List,writes_result=true,defaults=&assets,flags={.Core,.Read_Only},run=api_asset_list})
    api_register(s,st,{name="asset.detach",summary="Takes a part of an import out of the asset that owns it so it shows on its own; the import still writes it and leaves it out of the owner.",params=Api_Detach_Params,result=Api_Detach_Result,writes_result=true,run=api_asset_detach})
    api_register(s,st,{name="asset.create",summary="Makes an empty asset in a folder of the assets as Create of the content browser does; material.set, particle.set and the like fill it.",params=Api_Asset_Create_Params,result=Api_Asset_Create_Result,run=api_asset_create})
    api_register(s,st,{name="asset.users",summary="The files that use an asset or a part it owns, as the Delete modal of the content browser lists them.",params=Api_Asset_Users_Params,result=Api_Asset_Users_Result,writes_result=true,flags={.Read_Only},run=api_asset_users})
    api_register(s,st,{name="asset.delete",summary="Moves an asset and the parts it owns to the trash of the system at once and without undo. Fails for files of plugins, the engine or the editor, open tabs and outside Edit.",params=Api_Asset_Delete_Params,result=Api_Asset_Delete_Result,writes_result=true,flags={.Destructive},run=api_asset_delete})
    api_register(s,st,{name="asset.move",summary="Moves, renames or copies an asset with the parts it owns, or a folder with all it holds, at once and without undo; a move keeps ids and references, an asset its extension. A move fails for files of plugins, the engine or the editor, open tabs, unsaved changes, a folder into itself and outside Edit.",params=Api_Asset_Move_Params,result=Api_Asset_Moved_Result,run=api_asset_move})
}

// ---------------------------------------------------------------- component.list

@(private)
api_fields_write :: proc(w:^serial.Writer,schema:^serial.Schema,type:serial.Type_Index,prefix:string,first:^bool,include_runtime:bool=false) {
    t:=schema.types[type]
    for field in schema.fields[t.first:][:t.count] {
        if !include_runtime && (.Hidden in field.flags || .Transient in field.flags) {continue}
        path:=prefix==""?field.name:strings.concatenate({prefix,".",field.name},context.temp_allocator)
        inner:=schema.types[field.type]
        if inner.kind==.Struct {
            api_fields_write(w,schema,field.type,path,first,include_runtime)
            continue
        }
        if !first^ {serial.write_u8(w,',')}
        first^=false
        serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,path)
        kind,_:=reflect.enum_name_from_value(inner.kind)
        switch {
        case .Text in field.flags:     kind="Text"
        case .Color in field.flags:    kind="Color"
        case .Rotation in field.flags: kind="Quaternion"
        }
        api.write_key(w,"type");serial.text_write_string(w,kind)
        if inner.kind==.Array && kind=="Array" {
            elem:=schema.types[inner.elem]
            elem_kind,_:=reflect.enum_name_from_value(elem.kind)
            api.write_key(w,"element");serial.text_write_string(w,elem_kind)
            api.write_key(w,"count");serial.text_write_int(w,i64(inner.count))
        }
        if inner.kind==.Enum || inner.kind==.Bit_Set {
            api.write_key(w,"options");serial.write_u8(w,'[')
            for choice,i in schema.choices[inner.first:][:inner.count] {
                if i>0 {serial.write_u8(w,',')}
                serial.text_write_string(w,choice.name)
            }
            serial.write_u8(w,']')
        }
        if field.has_min {api.write_key(w,"min");serial.text_write_float(w,transmute(u64)field.min,8)}
        if field.has_max {api.write_key(w,"max");serial.text_write_float(w,transmute(u64)field.max,8)}
        unit:=field.unit
        if unit=="" && .Angle in field.flags {unit="rad"}
        if unit!="" {api.write_key(w,"unit");serial.text_write_string(w,unit)}
        if field.label!="" {api.write_key(w,"label");serial.text_write_string(w,field.label)}
        if .Read_Only in field.flags {api.write_key(w,"read_only");api.write_flag(w,true)}
        if field.description!="" {api.write_key(w,"description");serial.text_write_string(w,field.description)}
        serial.write_u8(w,'}')
    }
}

// Every field of the component is transient: the engine derives it.
@(private)
api_schema_derived :: proc(schema:^serial.Schema,type:serial.Type_Index) -> bool {
    t:=schema.types[type]
    if t.kind!=.Struct || t.count==0 {return false}
    for field in schema.fields[t.first:][:t.count] {
        if .Transient not_in field.flags {return false}
    }
    return true
}

@(private)
api_component_list :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Component_Params)
    st:=api_state(s)
    w:=call.out
    named:[API_COMPONENT_NAMES]^core.Table_Info
    count:=0
    for &entry in params.names {
        name:=base.text_get(entry[:])
        if name=="" {continue}
        table,problem:=api_component_named(shown_world(s),name)
        if table==nil {
            api.call_failf(call,api.INVALID_PARAMS,"%s; component.list without a name lists them",problem)
            return
        }
        if type:=st.types[api_table_index(s,table)];!params.include_runtime && type!=serial.TYPE_NONE && api_schema_derived(&st.schema,type) {
            api.call_failf(call,api.INVALID_PARAMS,"%s is derived by the engine: it is not added nor written, play.inspect reads it; include_runtime=true lists it",table.name)
            return
        }
        named[count]=table
        count+=1
    }
    serial.text_write_raw(w,`{"components":[`)
    first:=true
    for &t,i in s.info.tables {
        if t.place!=.World || count>0 && !slice.contains(named[:count],&t) {continue}
        type:=st.types[i]
        // A derived component is not added nor written: play.inspect reads it.
        if !params.include_runtime && type!=serial.TYPE_NONE && api_schema_derived(&st.schema,type) {continue}
        if !first {serial.write_u8(w,',')}
        first=false
        serial.text_write_raw(w,`{"name":`);serial.text_write_string(w,t.name)
        if count==0 {
            if brief:=api.summary_brief(t.description);brief!="" {api.write_key(w,"description");serial.text_write_string(w,brief)}
            serial.write_u8(w,'}')
            continue
        }
        size:=t.info.size
        api.write_key(w,"library");serial.text_write_string(w,t.library)
        api.write_key(w,"description");serial.text_write_string(w,t.description)
        if type==serial.TYPE_NONE {
            api.write_key(w,"plain_data");api.write_flag(w,false)
            serial.write_u8(w,'}')
            continue
        }
        bytes,_:=make([]u8,max(size,1),call.allocator)
        if t.default!=nil {t.default(raw_data(bytes))} else {component_default(t.type,bytes)}
        for offset in entity_offsets(t.info) {(cast(^u64)&bytes[offset])^=0}
        omitted:=serial.Field_Flags{.Transient,.Hidden} if !params.include_runtime else serial.Field_Flags{}
        api.write_key(w,"default");serial.text_write(w,&st.schema,type,bytes[:size],.Line,omit_fields=omitted)
        api.write_key(w,"fields");serial.write_u8(w,'[')
        fields_first:=true
        if st.schema.types[type].kind==.Struct {api_fields_write(w,&st.schema,type,"",&fields_first,params.include_runtime)}
        serial.write_u8(w,']')
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    if count==0 {
        api.write_key(w,"left_out")
        serial.text_write_string(w,"the library, default and fields of each: ask for them with name or names (up to 16)")
    }
    serial.write_u8(w,'}')
}

// ---------------------------------------------------------------- asset.list

// The name of a kind as asset.list gives it: that of the engine, or the
// extension of the files of a kind of a plugin; "other" without one.
@(private)
api_asset_kind_name :: proc(s:^Session,kind:asset.Fourcc) -> string {
    if info,known:=asset.kind_info(kind);known {return info.name}
    if declared:=asset_plugin_kind(s,kind);declared!=nil && len(declared.extension)>1 {return declared.extension[1:]}
    return "other"
}

// Whether a kind is the one the filter names, without minding case and with
// spaces or underscores.
@(private)
api_asset_kind_matches :: proc(s:^Session,filter:string,kind:asset.Fourcc) -> bool {
    if filter=="" || strings.equal_fold(filter,"all") {return true}
    name:=api_asset_kind_name(s,kind)
    if len(name)!=len(filter) {return false}
    for i in 0..<len(name) {
        a,b:=name[i],filter[i]
        if a>='A' && a<='Z' {a+=32}
        if b>='A' && b<='Z' {b+=32}
        if a=='_' {a=' '}
        if b=='_' {b=' '}
        if a!=b {return false}
    }
    return true
}

@(private)
api_asset_list :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Asset_Params)
    a:=s.app.assets
    if a==nil {
        api.call_fail(call,api.SERVER_ERROR,"The project has no assets folder")
        return
    }
    host.assets_scan(a)
    registry:=&a.registry
    folder:=base.text_get(params.folder[:])
    w:=call.out
    total,shown:=0,0
    broken:=0
    serial.text_write_raw(w,`{"root":`);serial.text_write_string(w,registry.root)
    api.write_key(w,"assets");serial.write_u8(w,'[')
    for &file in registry.files {
        if file.state==.Broken {broken+=1}
        if file.state!=.Asset || !asset.registry_listed(&file) {continue}
        // A prefab is no kind: it is asked for as one, and is a scene among the scenes.
        if wanted:=base.text_get(params.kind[:]);strings.equal_fold(wanted,"prefab")?!asset.registry_prefab(&file):!api_asset_kind_matches(s,wanted,file.kind) {continue}
        if folder!="" && !strings.has_prefix(file.path,folder) {continue}
        total+=1
        if total<=params.offset || shown>=params.limit {continue}
        if shown>0 {serial.write_u8(w,',')}
        shown+=1
        serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,file.path)
        api.write_key(w,"asset");api_asset_write(w,file.id)
        api.write_key(w,"kind");serial.text_write_string(w,api_asset_kind_name(s,file.kind))
        if file.kind==asset.KIND_SCENE {api.write_key(w,"prefab");api.write_flag(w,asset.registry_prefab(&file))}
        api.write_key(w,"size");serial.text_write_int(w,file.size)
        api.write_key(w,"dependencies");serial.text_write_int(w,i64(file.dependency_count))
        api.write_key(w,"used_by");serial.text_write_int(w,i64(len(asset.registry_dependents(registry,file.id))))
        if file.owner!={} {api.write_key(w,"owner");api_asset_write(w,file.owner)}
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    api.write_key(w,"total");serial.text_write_int(w,i64(total))
    api.write_key(w,"offset");serial.text_write_int(w,i64(params.offset))
    api.write_key(w,"shown");serial.text_write_int(w,i64(shown))
    api.write_key(w,"broken");serial.text_write_int(w,i64(broken))
    api.write_key(w,"duplicates");serial.text_write_int(w,i64(len(registry.duplicates)+len(registry.reassigned)))
    missing:=make([dynamic]asset.Registry_Missing,context.temp_allocator)
    asset.registry_missing(registry,&missing)
    api.write_key(w,"missing");serial.text_write_int(w,i64(len(missing)))
    serial.write_u8(w,'}')
}
