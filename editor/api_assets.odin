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
    components:[]Api_Component_Entry,
    left_out:string `mirai:"optional,label=What the answer leaves out and how to ask for it"`,
}
Api_Component_Entry :: struct {
    name:string,
    library:string `mirai:"optional,label=The package that declares it"`,
    description:string `mirai:"optional"`,
    opaque:bool `mirai:"optional,label=The component is not plain data: it has no default nor fields"`,
    default:serial.Json `mirai:"optional,label=The value of a new component"`,
    fields:[]Api_Component_Field `mirai:"optional,label=Every field down to those of nested structs"`,
}
Api_Component_Field :: struct {
    path:string `mirai:"label=The field after those it is inside; separated by dots"`,
    type:string `mirai:"label=Bool Int Uint Float Enum Bit_Set Entity Entity_Id Asset or Array; Text Color or Quaternion by its flags"`,
    element:string `mirai:"optional,label=Of an Array: the kind of its elements"`,
    count:int `mirai:"optional,label=Of an Array: its length"`,
    options:[]string `mirai:"optional,label=Of an Enum or a Bit_Set: the names it takes"`,
    min:f64 `mirai:"optional"`,
    max:f64 `mirai:"optional"`,
    unit:string `mirai:"optional"`,
    label:string `mirai:"optional,label=The name the inspector shows"`,
    read_only:bool `mirai:"optional,label=scene.write refuses to change it"`,
    description:string `mirai:"optional"`,
}

Api_Asset_Params :: struct {
    kind:[32]u8 `mirai:"text,optional,label=Only the assets of this kind as the results name it (mesh; material; sound set or one of a plugin); empty or all: every kind"`,
    folder:[256]u8 `mirai:"text,optional,label=Only the assets under this folder"`,
    offset:int `mirai:"optional,min=0,max=1000000"`,
    limit:int `mirai:"optional,min=1,max=1024,clamp"`,
}

Api_Asset_List :: struct {
    root:string `mirai:"label=The asset folder"`,
    assets:[]Api_Asset_Entry,
    total:int `mirai:"label=Assets the filters take"`,
    offset:int,
    shown:int,
    broken:int `mirai:"label=Files that start as assets and contradict themselves"`,
    duplicates:int `mirai:"label=Files with the id of another; engine.diagnostics tells each"`,
    missing:int `mirai:"label=Dependencies that no file of the registry is"`,
}
Api_Asset_Entry :: struct {
    path:string `mirai:"label=Under the asset folder"`,
    asset:base.Asset_Id,
    kind:string `mirai:"label=The name of its kind (mesh; texture; material...); other for a kind this build does not know"`,
    prefab:bool `mirai:"optional,label=Of a scene: whether it has exactly one root, which makes it a prefab that scene.write with prefab and scene.spawn place"`,
    size:int `mirai:"label=Bytes of the file"`,
    dependencies:int `mirai:"label=Assets it uses"`,
    used_by:int `mirai:"label=Files that use it"`,
    owner:base.Asset_Id `mirai:"optional,label=The asset it is a part of"`,
}

// What api_asset_detach (assets_parts.odin) writes.
Api_Detach_Result :: struct {
    asset:base.Asset_Id `mirai:"label=The part"`,
    path:string `mirai:"label=Its path under the asset folder"`,
    owner:base.Asset_Id `mirai:"label=The asset it was a part of"`,
}

// What api_asset_delete (asset_delete.odin) writes.
Api_Asset_Delete_Result :: struct {
    moved:[]string `mirai:"label=The paths moved to the trash: the asset and its parts"`,
    used_by:[]string `mirai:"label=The files that use what moved; they keep the reference"`,
    error:string `mirai:"optional,label=Why the rest could not be moved after some were"`,
}

@(private)
api_assets_register :: proc(s:^Session,st:^Api_State) {
    assets:=Api_Asset_Params{limit=256}
    api_register(s,st,{name="component.list",summary="The components a scene can hold, with their defaults and their fields as scene.write takes them.",params=type_info_of(Api_Component_Params),result=type_info_of(Api_Component_List),flags={.Core,.Read_Only},run=api_component_list})
    api_register(s,st,{name="asset.list",summary="The assets of the registry by kind and folder, with a count of its broken files, duplicated ids and missing dependencies.",params=type_info_of(Api_Asset_Params),result=type_info_of(Api_Asset_List),defaults=&assets,flags={.Core,.Read_Only},run=api_asset_list})
    api_register(s,st,{name="asset.detach",summary="Takes a part of an import out of the asset that owns it so it shows on its own; the import still writes it and leaves it out of the owner.",params=type_info_of(Api_Detach_Params),result=type_info_of(Api_Detach_Result),run=api_asset_detach})
    api_register(s,st,{name="asset.create",summary="Makes an empty asset in a folder of the assets as Create of the content browser does; material.set, particle.set and the like fill it.",params=type_info_of(Api_Asset_Create_Params),result=type_info_of(Api_Asset_Create_Result),run=api_asset_create})
    api_register(s,st,{name="asset.users",summary="The files that use an asset or a part it owns, as the Delete modal of the content browser lists them.",params=type_info_of(Api_Asset_Users_Params),result=type_info_of(Api_Asset_Users_Result),flags={.Read_Only},run=api_asset_users})
    api_register(s,st,{name="asset.delete",summary="Moves an asset and the parts it owns to the trash of the system at once and without undo. Fails for files of plugins, the engine or the editor, open tabs and outside Edit.",params=type_info_of(Api_Asset_Delete_Params),result=type_info_of(Api_Asset_Delete_Result),flags={.Destructive},run=api_asset_delete})
    api_register(s,st,{name="asset.move",summary="Moves, renames or copies an asset with the parts it owns, or a folder with all it holds, at once and without undo; a move keeps ids and references, an asset its extension. A move fails for files of plugins, the engine or the editor, open tabs, files being edited, a folder into itself and outside Edit.",params=type_info_of(Api_Asset_Move_Params),result=type_info_of(Api_Asset_Moved_Result),run=api_asset_move})
}

// ---------------------------------------------------------------- component.list

@(private)
api_fields :: proc(schema:^serial.Schema,type:serial.Type_Index,prefix:string,list:^[dynamic]Api_Component_Field,include_runtime:bool=false) {
    t:=schema.types[type]
    for field in schema.fields[t.first:][:t.count] {
        if !include_runtime && (.Hidden in field.flags || .Transient in field.flags) {continue}
        path:=prefix==""?field.name:strings.concatenate({prefix,".",field.name},list.allocator)
        inner:=schema.types[field.type]
        if inner.kind==.Struct {
            api_fields(schema,field.type,path,list,include_runtime)
            continue
        }
        kind,_:=reflect.enum_name_from_value(inner.kind)
        switch {
        case .Text in field.flags:     kind="Text"
        case .Color in field.flags:    kind="Color"
        case .Rotation in field.flags: kind="Quaternion"
        }
        row:=Api_Component_Field{path=path,type=kind,label=field.label,read_only=.Read_Only in field.flags,description=field.description,unit=field.unit}
        if inner.kind==.Array && kind=="Array" {
            row.element,_=reflect.enum_name_from_value(schema.types[inner.elem].kind)
            row.count=int(inner.count)
        }
        if inner.kind==.Enum || inner.kind==.Bit_Set {
            row.options=make([]string,inner.count,list.allocator)
            for &option,i in row.options {option=schema.choices[inner.first+u32(i)].name}
        }
        if field.has_min {row.min=transmute(f64)field.min}
        if field.has_max {row.max=transmute(f64)field.max}
        if row.unit=="" && .Angle in field.flags {row.unit="rad"}
        append(list,row)
    }
}

@(private)
api_component_list :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Component_Params)
    st:=api_state(s)
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
        if !params.include_runtime && table.derived {
            api.call_failf(call,api.INVALID_PARAMS,"%s is derived by the engine: it is not added nor written, scene.inspect with world Game reads it; include_runtime=true lists it",table.name)
            return
        }
        named[count]=table
        count+=1
    }
    result:=api.call_result(call,Api_Component_List)
    components:=make([dynamic]Api_Component_Entry,call.allocator)
    for &t,i in s.info.tables {
        if t.place!=.World || count>0 && !slice.contains(named[:count],&t) {continue}
        type:=st.types[i]
        // A derived component is not added nor written: an inspect of the game reads it.
        if !params.include_runtime && t.derived {continue}
        if count==0 {
            append(&components,Api_Component_Entry{name=t.name,description=api.summary_brief(t.description)})
            continue
        }
        entry:=Api_Component_Entry{name=t.name,library=t.library,description=t.description,opaque=type==serial.TYPE_NONE}
        if entry.opaque {append(&components,entry);continue}
        size:=t.info.size
        bytes,_:=make([]u8,max(size,1),call.allocator)
        if t.default!=nil {t.default(raw_data(bytes))} else {component_default(t.type,bytes)}
        for offset in entity_offsets(t.info) {(cast(^u64)&bytes[offset])^=0}
        omitted:=serial.Field_Flags{.Transient,.Hidden} if !params.include_runtime else serial.Field_Flags{}
        // The default is of a type the world declares.
        value:serial.Writer
        serial.writer_init(&value,0,call.allocator)
        serial.text_write(&value,&st.schema,type,bytes[:size],.Line,omit_fields=omitted)
        entry.default=serial.Json(string(serial.writer_bytes(&value)))
        fields:=make([dynamic]Api_Component_Field,call.allocator)
        if st.schema.types[type].kind==.Struct {api_fields(&st.schema,type,"",&fields,params.include_runtime)}
        entry.fields=fields[:]
        append(&components,entry)
    }
    result.components=components[:]
    if count==0 {result.left_out="the library, default and fields of each: ask for them with name or names (up to 16)"}
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
    r:=api.call_result(call,Api_Asset_List)
    entries:=make([dynamic]Api_Asset_Entry,call.allocator)
    for &file in registry.files {
        if file.state==.Broken {r.broken+=1}
        if file.state!=.Asset || !asset.registry_listed(&file) || !api_asset_kind_matches(s,base.text_get(params.kind[:]),file.kind) {continue}
        if folder!="" && !strings.has_prefix(file.path,folder) {continue}
        r.total+=1
        if r.total<=params.offset || len(entries)>=params.limit {continue}
        append(&entries,Api_Asset_Entry{file.path,file.id,api_asset_kind_name(s,file.kind),asset.registry_prefab(&file),int(file.size),int(file.dependency_count),len(asset.registry_dependents(registry,file.id)),file.owner})
    }
    missing:=make([dynamic]asset.Registry_Missing,context.temp_allocator)
    asset.registry_missing(registry,&missing)
    r.root,r.assets,r.offset,r.shown=registry.root,entries[:],params.offset,len(entries)
    r.duplicates,r.missing=len(registry.duplicates)+len(registry.reassigned),len(missing)
}
