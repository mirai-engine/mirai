package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// New assets of Create in the content browser and of asset.create: a folder,
// a scene, a prefab (a scene of that kind with its one root), a material, a sound set, a table of texts (no languages yet), a
// font (the Inter of the editor, for another one import its file), or a kind a plugin creates
// (Asset_Document_Provider.creates), such as a particle effect. A folder and a scene are written
// at once, as an import writes: a scene or a prefab opens from its file. The others are a
// step of the history of the scene, written when it ends, as material.set
// with path writes them. The plugin of a kind it creates gives the bytes
// of its empty file (Asset_Document_Provider.create), which are written the
// same way.

ASSET_CREATE_FOLDER :: asset.Fourcc(0) // what Create makes that is not an asset
ASSET_CREATE_PREFAB :: asset.Fourcc(1) // what Create makes as a .scene of kind Prefab
ASSET_CREATE_NAME :: 64                // bytes of a name Create gives

Api_Asset_Create_Params :: struct {
    kind:[32]u8 `mirai:"text,label=What to make: folder; scene; prefab; material; sound_set; strings (a table of texts without languages); font (Inter; import a TTF or OTF for another); particle or a kind a plugin creates (such as ui)"`,
    folder:[API_PATH_BYTES]u8 `mirai:"text,optional,label=The folder under the assets folder it goes in; none: the root"`,
    name:[ASSET_CREATE_NAME]u8 `mirai:"text,optional,label=Its name without extension; none: New and its kind numbered while it is taken"`,
}

Api_Asset_Create_Result :: struct {
    id:[base.ASSET_ID_TEXT]u8 `mirai:"text,label=The id of the asset; empty for a folder"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Its path under the assets folder"`,
}

// What Create makes, in the order it lists them: what the editor makes, then
// the kinds plugins create.
asset_create_kinds :: proc(s:^Session) -> []asset.Fourcc {
    kinds:=make([dynamic]asset.Fourcc,context.temp_allocator)
    append(&kinds,ASSET_CREATE_FOLDER,asset.KIND_SCENE,ASSET_CREATE_PREFAB,asset.KIND_MATERIAL,asset.KIND_SOUND_SET,asset.KIND_STRINGS,asset.KIND_FONT)
    if s.info==nil {return kinds[:]}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    for &provider in found[:provided_all(s,found[:])] {
        for i in 0..<clamp(provider.count,0,len(provider.kinds)) {
            kind:=provider.kinds[i]
            _,known:=asset.kind_info(kind)
            known||=asset_plugin_kind(s,kind)!=nil
            if i in provider.creates && known && !slice.contains(kinds[:],kind) {append(&kinds,kind)}
        }
    }
    return kinds[:]
}

// Whether the plugin of a kind writes its empty file.
@(private)
asset_create_plugin :: proc(kind:asset.Fourcc) -> bool {
    switch kind {
    case ASSET_CREATE_FOLDER,asset.KIND_SCENE,ASSET_CREATE_PREFAB,asset.KIND_MATERIAL,asset.KIND_SOUND_SET,asset.KIND_STRINGS,asset.KIND_FONT: return false
    }
    return true
}

asset_create_label :: proc(s:^Session,kind:asset.Fourcc) -> string {
    switch kind {
    case ASSET_CREATE_FOLDER: return "Folder"
    case ASSET_CREATE_PREFAB: return "Prefab"
    }
    return asset_kind_label(s,kind)
}

// The name Create gives first, and the step of history it is: New and the
// label, each word capitalized.
asset_create_default :: proc(s:^Session,kind:asset.Fourcc) -> string {
    name:=transmute([]u8)fmt.tprintf("New %s",asset_create_label(s,kind))
    for i in 1..<len(name) {
        if name[i-1]==' ' && name[i]>='a' && name[i]<='z' {name[i]-='a'-'A'}
    }
    return string(name)
}

asset_create_extension :: proc(s:^Session,kind:asset.Fourcc) -> string {
    if kind==ASSET_CREATE_PREFAB {return SCENE_EXTENSION}
    if declared:=asset_plugin_kind(s,kind);declared!=nil {return declared.extension}
    info,_:=asset.kind_info(kind)
    return info.extension
}

// The name asset.create takes for a kind: folder, that of asset.KINDS with
// _ for its spaces, or the extension of a kind of a plugin without its dot.
asset_create_kind_name :: proc(s:^Session,kind:asset.Fourcc) -> string {
    if kind==ASSET_CREATE_FOLDER {return "folder"}
    if kind==ASSET_CREATE_PREFAB {return "prefab"}
    if declared:=asset_plugin_kind(s,kind);declared!=nil && len(declared.extension)>1 {return declared.extension[1:]}
    info,_:=asset.kind_info(kind)
    name,_:=strings.replace_all(info.name," ","_",context.temp_allocator)
    return name
}

// Why a name cannot be that of a file or folder of the assets; "" when it can.
asset_name_refusal :: proc(name:string) -> string {
    switch {
    case name=="":                  return "A name is needed"
    case len(name)>=ASSET_CREATE_NAME: return fmt.tprintf("A name has fewer than %d bytes",ASSET_CREATE_NAME)
    case name[0]=='.':              return "A name does not start with a dot: the registry leaves those out"
    case strings.contains_any(name,`/\:*?"<>|`): return `A name has none of / \ : * ? " < > |`
    case name[len(name)-1]==' ' || name[len(name)-1]=='.': return "A name does not end with a space or a dot"
    }
    for c in transmute([]u8)name {
        if c<' ' {return "A name has no control characters"}
    }
    return ""
}

// A folder under the assets folder as the registry names it, without slashes
// at its ends ("" is the root), or why it cannot take a new asset.
asset_folder_clean :: proc(r:^asset.Registry,folder:string) -> (clean,refusal:string) {
    clean,_=strings.replace_all(folder,"\\","/",context.temp_allocator)
    clean=strings.trim(clean,"/")
    if clean=="" {return}
    for segment in strings.split(clean,"/",context.temp_allocator) {
        if refused:=asset_name_refusal(segment);refused!="" {return clean,fmt.tprintf("%q: %s",segment,refused)}
    }
    for mount in r.mounts {
        if clean==mount.prefix || len(clean)>len(mount.prefix) && clean[len(mount.prefix)]=='/' && strings.has_prefix(clean,mount.prefix) {return clean,"It is a folder of a plugin or the engine: give one of the project"}
    }
    return
}

// Whether a path of the assets is taken: by a file the registry has, in
// memory or on disk, by a file or folder of the disk, or by a folder some
// file is in.
asset_path_taken :: proc(r:^asset.Registry,path:string) -> bool {
    if _,found:=asset.registry_find_path(r,path);found {return true}
    if os.exists(asset.registry_file_path(r,path,context.temp_allocator)) {return true}
    folder:=strings.concatenate({path,"/"},context.temp_allocator)
    for &file in r.files {
        if strings.has_prefix(file.path,folder) {return true}
    }
    return false
}

@(private)
asset_create_join :: proc(folder,name,extension:string) -> string {
    return fmt.tprintf("%s%s%s%s",folder,"/" if folder!="" else "",name,extension)
}

// The path of a new asset in a folder: name with its extension, or the first
// of name 2, name 3... that nothing takes.
asset_create_path :: proc(r:^asset.Registry,folder,name,extension:string) -> string {
    path:=asset_create_join(folder,name,extension)
    for n:=2;asset_path_taken(r,path);n+=1 {path=asset_create_join(folder,fmt.tprintf("%s %d",name,n),extension)}
    return path
}

// Why nothing can be created now; "" when it can.
asset_create_refusal :: proc(s:^Session) -> string {
    switch {
    case files_registry(s)==nil: return "The project has no assets folder"
    case watching(s):            return "The run of an agent is being watched; stop watching it first"
    case import_busy(s)!="":     return import_busy(s)
    }
    return ""
}

// A gesture of the scene for what Create writes: a step of the history of the
// scene, not of the asset document in front, joined to the open one of a call
// of the API.
@(private)
asset_create_gesture :: proc(s:^Session,label:string) -> (opened,ready:bool) {
    if s.edits==nil {return false,true}
    opened,ready=edit_open(s,label,document=true)
    return
}

// Makes a new asset of kind at path, a path of the assets with its extension
// (asset_create_path), with id: a folder or a scene at once on disk, another
// kind as an edit; the empty file of a kind of a plugin is what its
// plugin gives. Returns what failed, as how to correct it; "" when it was made.
asset_create :: proc(s:^Session,kind:asset.Fourcc,path:string,id:base.Asset_Id) -> string {
    if refusal:=asset_create_refusal(s);refusal!="" {return refusal}
    a:=s.app.assets
    file:=asset.registry_file_path(&a.registry,path,context.temp_allocator)
    switch kind {
    case ASSET_CREATE_FOLDER:
        if os.make_directory_all(file)!=nil && !os.is_dir(file) {return fmt.tprintf("%s could not be made",path)}
        host.assets_scan(a)
        return ""
    case asset.KIND_SCENE,ASSET_CREATE_PREFAB:
        scene:asset.Scene
        if asset.scene_init(&scene,&a.types,id)!=.None {return "The scene could not be made"}
        defer asset.scene_destroy(&scene)
        if kind==ASSET_CREATE_PREFAB {
            scene.doc.flags+={.Prefab}
            root:=asset.scene_new_id(&scene)
            place:=core.TRANSFORM_IDENTITY
            if _,added:=asset.scene_entity_add(&scene,root,0,asset_name(path));added!=.None || asset.scene_set(&scene,root,"Transform",&place)!=.None {return "The prefab could not be made"}
        }
        if folder:=filepath.dir(file);!os.is_dir(folder) {_=os.make_directory_all(folder)}
        if asset.scene_save(&scene,file)!=.None {return fmt.tprintf("%s could not be written",path)}
        assets_wrote(s,file)
        return ""
    }
    made:[]u8
    if asset_create_plugin(kind) {
        if !slice.contains(asset_create_kinds(s),kind) {return fmt.tprintf("No plugin of the project creates %s",asset_create_kind_name(s,kind))}
        found:[PROVIDER_CAPACITY]Asset_Document_Provider
        for &provider in found[:provided_all(s,found[:])] {
            for i in 0..<clamp(provider.count,0,len(provider.kinds)) {
                if provider.kinds[i]==kind && i in provider.creates && provider.create!=nil {made=provider.create(s,kind,id)}
            }
        }
        if made==nil {return fmt.tprintf("The plugin of %s could not make it; engine.diagnostics may tell why",asset_create_kind_name(s,kind))}
    }
    label:=asset_create_default(s,kind)
    opened,ready:=asset_create_gesture(s,label)
    if !ready {return history.edits_error_text(s.edits.error)}
    defer edit_close(s,opened)
    switch kind {
    case asset.KIND_MATERIAL:
        bytes,error:=asset.material_bytes(&a.types,{id=id,info=asset.MATERIAL_DEFAULTS},context.temp_allocator)
        if error!=.None || !file_write(s,file,bytes,label) {return "The material could not be written"}
    case asset.KIND_SOUND_SET:
        return sound_set_publish(s,id,file,asset.SOUND_SET_DEFAULTS,label)
    case asset.KIND_STRINGS:
        bytes,error:=asset.strings_bytes(&a.types,{id=id},context.temp_allocator)
        if error!=.None || !file_write(s,file,bytes,label) {return "The table of texts could not be written"}
    case asset.KIND_FONT:
        bytes,error:=asset.font_bytes(&a.types,{id=id,file=ui.FONT_INTER,compression=.Stream},context.temp_allocator)
        if error!=.None || !file_write(s,file,bytes,label) {return "The font could not be written"}
    case:
        if !file_write(s,file,made,label) {return fmt.tprintf("%s could not be written",path)}
    }
    return ""
}

// ---------------------------------------------------------------- asset.create

@(private)
api_asset_create :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Asset_Create_Params)
    kinds:=asset_create_kinds(s)
    named:=strings.trim_space(base.text_get(p.kind[:]))
    kind:asset.Fourcc
    known:=false
    for candidate in kinds {
        if strings.equal_fold(asset_create_kind_name(s,candidate),named) || strings.equal_fold(asset_create_label(s,candidate),named) {kind,known=candidate,true;break}
    }
    if kind==asset.KIND_RECORDS {
        api.call_fail(call,api.INVALID_PARAMS,"A table of game data has a type: records.create {path,type} makes it")
        return
    }
    if !known {
        names:=make([dynamic]string,context.temp_allocator)
        for candidate in kinds {if candidate!=asset.KIND_RECORDS {append(&names,asset_create_kind_name(s,candidate))}}
        api.call_failf(call,api.INVALID_PARAMS,"kind %q is not one asset.create makes: give %s",named,strings.join(names[:],", ",context.temp_allocator))
        return
    }
    r:=files_registry(s)
    if r==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project with an assets folder")
        return
    }
    if refusal:=asset_create_refusal(s);refusal!="" {
        api.call_fail(call,api.SERVER_ERROR,refusal)
        return
    }
    folder,refusal:=asset_folder_clean(r,base.text_get(p.folder[:]))
    if refusal!="" {
        api.call_failf(call,api.INVALID_PARAMS,"folder: %s",refusal)
        return
    }
    extension:=asset_create_extension(s,kind)
    name:=strings.trim_space(base.text_get(p.name[:]))
    if extension!="" && strings.has_suffix(name,extension) {name=name[:len(name)-len(extension)]}
    path:string
    if name=="" {path=asset_create_path(r,folder,asset_create_default(s,kind),extension)} else {
        if refused:=asset_name_refusal(name);refused!="" {
            api.call_failf(call,api.INVALID_PARAMS,"name: %s",refused)
            return
        }
        path=asset_create_join(folder,name,extension)
        if asset_path_taken(r,path) {
            api.call_failf(call,api.INVALID_PARAMS,"%s already exists: give another name, or none for a free one",path)
            return
        }
    }
    id:base.Asset_Id
    if kind!=ASSET_CREATE_FOLDER {id=asset_id_new(s)}
    switch {
    case kind==ASSET_CREATE_FOLDER || kind==asset.KIND_SCENE || kind==ASSET_CREATE_PREFAB:
        if problem:=asset_create(s,kind,path,id);problem!="" {
            api.call_fail(call,api.SERVER_ERROR,problem)
            return
        }
    case:
        if !api_edit_begin(s,call,asset_create_default(s,kind)) {return}
        problem:=asset_create(s,kind,path,id)
        if problem!="" {api.call_fail(call,api.SERVER_ERROR,problem)}
        if !api_edit_end(s,call,problem=="") {return}
    }
    result:=api.call_result(call,Api_Asset_Create_Result)
    if id!={} {base.asset_id_format(id,result.id[:])}
    base.text_set(result.path[:],path)
}
