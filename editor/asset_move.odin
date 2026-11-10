package editor

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// Renaming, moving and duplicating assets and folders of the project, from
// the content browser and the API. Like deleting, they change the files at
// once and not as an edit, and the registry is scanned again. What names an
// asset names its id, which moving keeps: references, Recent, Favorites and
// open documents follow it. An asset moves with the parts it owns, which keep
// where they are beside it; an import keeps its source, which Import_Info
// names from the project. What has unsaved changes does not move until it is
// saved or discarded. A duplicate is a new asset with ids of its own, and no
// output of an import.

Api_Asset_Move_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The asset or folder: its path under the asset folder or the id of an asset"`,
    folder:[API_PATH_BYTES]u8 `mirai:"text,optional,label=The folder under the asset folder it goes in; / is the root; none: the one it is in"`,
    name:[ASSET_CREATE_NAME]u8 `mirai:"text,optional,label=Its new name, an asset keeping its extension; none: the one it has, or a free one for a copy"`,
    copy:bool `mirai:"optional,label=Copy it with new ids instead of moving it; the copies name each other and are no output of an import"`,
}

Api_Asset_Moved_Result :: struct {
    id:[base.ASSET_ID_TEXT]u8 `mirai:"text,label=The id of the asset: the same after a move and a new one for a copy; empty for a folder"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Where it is now under the asset folder"`,
}

@(private)
Asset_Move :: struct {from,to:string} // paths of the registry

// The extension of a path of the assets with its dot; "" for none.
@(private)
asset_path_extension :: proc(path:string) -> string {
    name:=asset_path_base(path)
    if dot:=strings.last_index_byte(name,'.');dot>0 {return name[dot:]}
    return ""
}

@(private)
asset_path_base :: proc(path:string) -> string {return path[strings.last_index_byte(path,'/')+1:]}

// Whether path is inside folder ("" is the root).
@(private)
asset_path_inside :: proc(path,folder:string) -> bool {
    return folder=="" || len(path)>len(folder) && path[len(folder)]=='/' && strings.has_prefix(path,folder)
}

// Why an asset is not one of the project the browser changes; "" when it is.
@(private)
asset_owned_refusal :: proc(r:^asset.Registry,file:^asset.Registry_File) -> string {
    switch {
    case file.state!=.Asset:          return "It is not an asset of the folder"
    case !asset.registry_listed(file): return "It is a file of the editor"
    case content_mounted(r,file.path): return "It belongs to a plugin or the engine"
    }
    return ""
}

// The first file of paths or inside folder that is unsaved, as why it cannot
// move; "" for none.
@(private)
asset_unsaved_refusal :: proc(r:^asset.Registry,paths:[]string,folder:="") -> string {
    for held in r.memory {
        if asset.registry_outside(held.path) {continue}
        inside:=folder!="" && asset_path_inside(held.path,folder)
        for path in paths {inside||=held.path==path}
        if inside {return fmt.tprintf("%s has unsaved changes: save or discard them first",held.path)}
    }
    return ""
}

// Why an asset cannot be renamed or moved now; "" when it can.
@(private)
asset_move_refusal :: proc(s:^Session,r:^asset.Registry,file:^asset.Registry_File) -> string {
    if file.imported!=0 {return "It is a part of what its source gives, listed in the folder of its source: move that folder, or duplicate it to have a copy that moves"}
    if refusal:=asset_create_refusal(s);refusal!="" {return refusal}
    if refusal:=asset_delete_refusal(s,r,file);refusal!="" {return refusal}
    files:=asset_delete_files(r,file.id)
    paths:=make([]string,len(files),context.temp_allocator)
    for at,i in files {paths[i]=r.files[at].path}
    return asset_unsaved_refusal(r,paths)
}

// Moves the asset id and the parts it owns to folder, under name without its
// extension ("" keeps the one it has): renaming is moving to its own folder.
// A part keeps where it is beside the asset. Returns where the asset is, or
// what failed as how to correct it.
asset_move :: proc(s:^Session,id:base.Asset_Id,folder,name:string) -> (path,message:string) {
    r:=files_registry(s)
    if r==nil {return "","The editor has no asset folder it can change"}
    file,found:=asset.registry_find(r,id)
    if !found {return "","The asset is not in the registry: asset.list lists them"}
    // What a source gives is listed where the source is: its source moves, with its sidecar, and nothing is imported.
    if sidecar,_:=import_root(s,r,id);file.imported!=0 && sidecar!="" {
        into,refused:=asset_folder_clean(r,folder)
        if refused!="" {return "",fmt.tprintf("folder: %s",refused)}
        if busy:=import_busy(s);busy!="" {return "",busy}
        source:=strings.trim_suffix(sidecar,importer.SIDECAR_EXTENSION)
        target:=fmt.tprintf("%s/%s/%s",project.folder_path(s.project_root,.Source,context.temp_allocator),into,filepath.base(source))
        if dir:=filepath.dir(target);!os.is_dir(dir) {_=os.make_directory_all(dir)}
        if os.exists(target) || os.rename(source,target)!=nil || os.rename(sidecar,fmt.tprintf("%s%s",target,importer.SIDECAR_EXTENSION))!=nil {
            return "",fmt.tprintf("%s could not be moved to %s: a file is there, or another program has it open",source,target)
        }
        host.assets_scan(s.app.assets)
        if moved,listed:=asset.registry_find(r,id);listed {path=strings.clone(moved.path,context.temp_allocator)}
        return
    }
    if refusal:=asset_move_refusal(s,r,file);refusal!="" {return "",refusal}
    into,refused:=asset_folder_clean(r,folder)
    if refused!="" {return "",fmt.tprintf("folder: %s",refused)}
    into=strings.clone(into,context.temp_allocator)
    extension:=asset_path_extension(file.path)
    named:=strings.trim_space(name)
    if named=="" {named=asset_name(file.path)}
    if extension!="" && strings.has_suffix(named,extension) {named=named[:len(named)-len(extension)]}
    if refusal:=asset_name_refusal(named);refusal!="" {return "",refusal}
    source:=content_folder_of(file.path)
    moves:=make([dynamic]Asset_Move,context.temp_allocator)
    for at,i in asset_delete_files(r,id) {
        // A part of the imported folder stays at the path its sidecar lists.
        if i>0 && r.files[at].imported!=0 {continue}
        from:=strings.clone(r.files[at].path,context.temp_allocator)
        to:=asset_create_join(into,named,extension)
        if i>0 {to=asset_create_join(into,from[len(source)+1:] if source!="" && asset_path_inside(from,source) else asset_path_base(from),"")}
        if i==0 {path=to}
        if to==from {continue}
        if asset_path_taken(r,to) && !strings.equal_fold(to,from) {return "",fmt.tprintf("%s already exists: give another name or folder",to)}
        for other in moves {
            if strings.equal_fold(other.to,to) {return "",fmt.tprintf("Two files would be %s: give another name or folder",to)}
        }
        append(&moves,Asset_Move{from,to})
    }
    if len(moves)==0 {return}
    done:=0
    for move in moves {
        from:=asset.registry_file_path(r,move.from,context.temp_allocator)
        to:=asset.registry_file_path(r,move.to,context.temp_allocator)
        if dir:=filepath.dir(to);!os.is_dir(dir) {_=os.make_directory_all(dir)}
        if os.rename(from,to)!=nil {
            message=fmt.tprintf("%s could not be moved to %s; another program may have it open",move.from,move.to)
            break
        }
        done+=1
    }
    // The asset and its parts stay together: what moved goes back.
    if message!="" {
        for move in moves[:done] {
            _=os.rename(asset.registry_file_path(r,move.to,context.temp_allocator),asset.registry_file_path(r,move.from,context.temp_allocator))
        }
        return "",message
    }
    for move in moves {
        asset_history_moved(s,asset.registry_file_path(r,move.from,context.temp_allocator),asset.registry_file_path(r,move.to,context.temp_allocator),false)
        asset_start_scene_moved(s,move.from,move.to,false)
    }
    host.assets_scan(s.app.assets)
    if c:=s.content;c!=nil {
        c.reveal=id
        content_place_set(c,into)
    }
    return
}

// Moves the folder from, with all it holds, to folder under name ("" keeps
// the one it has). Returns where it is, or what failed as how to correct it.
asset_folder_move :: proc(s:^Session,from,folder,name:string) -> (path,message:string) {
    r,source,refusal:=asset_folder_subject(s,from)
    if refusal!="" {return "",refusal}
    into,refused:=asset_folder_clean(r,folder)
    if refused!="" {return "",fmt.tprintf("folder: %s",refused)}
    named:=strings.trim_space(name)
    if named=="" {named=asset_path_base(source)}
    if refusal=asset_name_refusal(named);refusal!="" {return "",refusal}
    path=asset_create_join(into,named,"")
    if path==source {return}
    if asset_path_inside(path,source) {return "",fmt.tprintf("%s cannot go inside itself: give a folder outside it",source)}
    if asset_path_taken(r,path) && !strings.equal_fold(path,source) {return "",fmt.tprintf("%s already exists: give another name or folder",path)}
    if refusal=asset_unsaved_refusal(r,nil,source);refusal!="" {return "",refusal}
    for &file in r.files {
        if file.state==.Asset && asset_path_inside(file.path,source) && scene_tab(s,file.id)>=0 {return "",fmt.tprintf("%s is open in a tab: close the tab first",file.path)}
    }
    full:=asset.registry_file_path(r,source,context.temp_allocator)
    target:=asset.registry_file_path(r,path,context.temp_allocator)
    // The sources of the folder go with it: what they give is listed where they are, and nothing is imported.
    sources:=project.folder_path(s.project_root,.Source,context.temp_allocator)
    for pair in ([2][2]string{{fmt.tprintf("%s/%s",sources,source),fmt.tprintf("%s/%s",sources,path)},{full,target}}) {
        if !os.is_dir(pair[0]) {continue}
        if dir:=filepath.dir(pair[1]);!os.is_dir(dir) {_=os.make_directory_all(dir)}
        if os.rename(pair[0],pair[1])!=nil {return "",fmt.tprintf("%s could not be moved to %s; another program may have a file of it open",source,path)}
    }
    asset_history_moved(s,full,target,true)
    asset_start_scene_moved(s,source,path,true)
    host.assets_scan(s.app.assets)
    if c:=s.content;c!=nil {content_place_set(c,path)}
    return
}

// Copies the asset id, with copies of the parts it owns, beside itself with a
// free name, or into folder (of the registry) under name without its
// extension ("": a free one); the parts keep where they are beside it. Every
// copy has a new id, and what the copies name of each other they name of the
// copies. What memory holds unsaved of them is what is copied. Returns the
// copy, or what failed.
asset_duplicate :: proc(s:^Session,id:base.Asset_Id,folder:Maybe(string)=nil,name:="") -> (copy:base.Asset_Id,path,message:string) {
    if refusal:=asset_create_refusal(s);refusal!="" {return {},"",refusal}
    r:=files_registry(s)
    file,found:=asset.registry_find(r,id)
    if !found {return {},"","The asset is not in the registry: asset.list lists them"}
    if refusal:=asset_owned_refusal(r,file);refusal!="" {return {},"",refusal}
    files:=asset_delete_files(r,id)
    owner:=strings.clone(content_folder_of(file.path),context.temp_allocator)
    into:=owner
    if place,placed:=folder.?;placed {
        refused:string
        if into,refused=asset_folder_clean(r,place);refused!="" {return {},"",fmt.tprintf("folder: %s",refused)}
        into=strings.clone(into,context.temp_allocator)
    }
    extension:=asset_path_extension(file.path)
    named:=strings.trim_space(name)
    if extension!="" && strings.has_suffix(named,extension) {named=named[:len(named)-len(extension)]}
    if named!="" {
        if refusal:=asset_name_refusal(named);refusal!="" {return {},"",fmt.tprintf("name: %s",refusal)}
        if taken:=asset_create_join(into,named,extension);asset_path_taken(r,taken) {return {},"",fmt.tprintf("%s already exists: give another name or folder",taken)}
    }
    ids:=make(map[base.Asset_Id]base.Asset_Id,context.temp_allocator)
    sources:=make([]string,len(files),context.temp_allocator)
    for at,i in files {
        ids[r.files[at].id]=asset_id_new(s)
        sources[i]=strings.clone(r.files[at].path,context.temp_allocator)
    }
    written:=make([dynamic]string,context.temp_allocator)
    for source,i in sources {
        place:=content_folder_of(source)
        if into!=owner {place=content_folder_of(asset_create_join(into,source[len(owner)+1:] if owner!="" && asset_path_inside(source,owner) else asset_path_base(source),""))}
        target:=asset_create_path(r,place,asset_name(source),asset_path_extension(source))
        if i==0 && named!="" {target=asset_create_join(into,named,extension)}
        if problem:=asset_copy(r,source,target,ids);problem!="" {
            for done in written {_=os.remove(done)}
            return {},"",problem
        }
        append(&written,asset.registry_file_path(r,target,context.temp_allocator))
        if i==0 {path=target}
    }
    host.assets_scan(s.app.assets)
    copy=ids[id]
    if c:=s.content;c!=nil {
        c.reveal=copy
        content_place_set(c,content_folder_of(path))
    }
    return
}

// Copies the folder from, with all it holds, beside itself with a free name
// or into folder under name ("": a free one): its assets as asset_duplicate
// copies them, among each other; a part whose owner is outside is of its own.
// Returns where the copy is, or what failed.
asset_folder_duplicate :: proc(s:^Session,from:string,folder:Maybe(string)=nil,name:="") -> (path,message:string) {
    r,source,refusal:=asset_folder_subject(s,from)
    if refusal!="" {return "",refusal}
    into:=content_folder_of(source)
    if place,placed:=folder.?;placed {
        refused:string
        if into,refused=asset_folder_clean(r,place);refused!="" {return "",fmt.tprintf("folder: %s",refused)}
        into=strings.clone(into,context.temp_allocator)
    }
    if asset_path_inside(into,source) || into==source {return "",fmt.tprintf("%s cannot be copied inside itself: give a folder outside it",source)}
    named:=strings.trim_space(name)
    if named=="" {path=asset_create_path(r,into,asset_path_base(source),"")} else {
        if refusal=asset_name_refusal(named);refusal!="" {return "",fmt.tprintf("name: %s",refusal)}
        path=asset_create_join(into,named,"")
        if asset_path_taken(r,path) {return "",fmt.tprintf("%s already exists: give another name or folder",path)}
    }
    ids:=make(map[base.Asset_Id]base.Asset_Id,context.temp_allocator)
    files:=make([dynamic]string,context.temp_allocator)
    for &file in r.files {
        if !asset_path_inside(file.path,source) {continue}
        if file.state==.Asset {ids[file.id]=asset_id_new(s)}
        append(&files,strings.clone(file.path,context.temp_allocator))
    }
    target:=asset.registry_file_path(r,path,context.temp_allocator)
    if os.make_directory_all(target)!=nil {return "",fmt.tprintf("%s could not be made",path)}
    for folder in r.folders {
        if asset_path_inside(folder,source) {_=os.make_directory_all(asset.registry_file_path(r,strings.concatenate({path,folder[len(source):]},context.temp_allocator),context.temp_allocator))}
    }
    for file in files {
        copy:=strings.concatenate({path,file[len(source):]},context.temp_allocator)
        problem:string
        if known,found:=asset.registry_find_path(r,file);found && known.state==.Asset {
            problem=asset_copy(r,file,copy,ids)
        } else {
            to:=asset.registry_file_path(r,copy,context.temp_allocator)
            if dir:=filepath.dir(to);!os.is_dir(dir) {_=os.make_directory_all(dir)}
            if os.copy_file(to,asset.registry_file_path(r,file,context.temp_allocator))!=nil {problem=fmt.tprintf("%s could not be copied",file)}
        }
        if problem!="" {
            _=base.remove_all(target)
            return "",problem
        }
    }
    host.assets_scan(s.app.assets)
    if c:=s.content;c!=nil {content_place_set(c,path)}
    return
}

// The folder of the assets a call names, as the registry names it, or why
// its files cannot change now.
@(private)
asset_folder_subject :: proc(s:^Session,from:string) -> (r:^asset.Registry,folder,refusal:string) {
    if refusal=asset_create_refusal(s);refusal!="" {return}
    r=files_registry(s)
    folder,refusal=asset_folder_clean(r,from)
    switch {
    case refusal!="": return
    case folder=="":  refusal="The assets folder itself stays: give one of its folders"
    case !os.is_dir(asset.registry_file_path(r,folder,context.temp_allocator)): refusal=fmt.tprintf("%s is not a folder of the assets: asset.list lists what they hold",folder)
    }
    return
}

// Writes at target a copy of the asset at source, with the ids of ids: its
// own, those it names and its owner, which is none when it is not among
// them. The copy is no output of an import: no import table, not Cooked.
@(private)
asset_copy :: proc(r:^asset.Registry,source,target:string,ids:map[base.Asset_Id]base.Asset_Id) -> string {
    data,error:=asset.registry_read(r,source)
    if error!=.None {return fmt.tprintf("%s could not be read: %v",source,error)}
    doc:asset.Document
    error=asset.document_read(&doc,data)
    mem.free_bytes(data)
    if error!=.None {return fmt.tprintf("%s could not be read: %v",source,error)}
    defer asset.document_destroy(&doc)
    file,_:=asset.registry_find_path(r,source)
    doc.id=ids[file.id]
    doc.owner=ids[doc.owner]
    doc.flags-={.Cooked}
    if table,found:=asset.document_table(&doc,asset.TABLE_IMPORT);found {asset.document_table_remove(&doc,table)}
    if !asset_document_remap(&doc,ids) {return fmt.tprintf("%s holds values that could not be read",source)}
    full:=asset.registry_file_path(r,target,context.temp_allocator)
    if dir:=filepath.dir(full);!os.is_dir(dir) {_=os.make_directory_all(dir)}
    if asset.document_save(&doc,full)!=.None {return fmt.tprintf("%s could not be written",target)}
    return ""
}

// Every asset id the values of doc name that ids has becomes the one it maps to.
@(private)
asset_document_remap :: proc(doc:^asset.Document,ids:map[base.Asset_Id]base.Asset_Id) -> bool {
    refs:=make([dynamic]serial.Ref,context.temp_allocator)
    for &table in doc.tables {
        for &column in table.columns {
            clear(&refs)
            if !serial.refs_collect(&doc.schema,column.type,&refs,asset.MAX_REFS) {return false}
            for row in 0..<table.rows {
                for ref in refs {
                    if ref.kind!=.Asset {continue}
                    at:=(^base.Asset_Id)(&column.data[row*column.size+int(ref.offset)])
                    if to,found:=ids[intrinsics.unaligned_load(at)];found {intrinsics.unaligned_store(at,to)}
                }
            }
        }
    }
    return true
}

// The steps of the histories of the scene and of the asset documents name
// files by their absolute paths: what moved is named where it went, so undo
// and redo put it there. folder: from and to are folders, and what they hold
// moved with them.
@(private)
asset_history_moved :: proc(s:^Session,from,to:string,folder:bool) {
    rename :: proc(files:[]history.Edit_File,from,to:string,folder:bool) {
        for &file in files {
            if file.path!=from && !(folder && asset_path_inside(file.path,from)) {continue}
            moved:=strings.concatenate({to,file.path[len(from):]})
            delete(file.path)
            file.path=moved
        }
    }
    if s.edits!=nil {
        for &step in s.edits.steps {rename(step.files[:],from,to,folder)}
        rename(s.edits.files[:],from,to,folder)
    }
    for &d in s.asset_documents {
        for &step in d.history.steps {rename(step.files[:],from,to,folder)}
        rename(d.history.files[:],from,to,folder)
    }
}

// The start scene of the project, named by its path, follows it.
@(private)
asset_start_scene_moved :: proc(s:^Session,from,to:string,folder:bool) {
    if !s.has_project || s.project_root=="" {return}
    file:=project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator)
    m,error:=project.manifest_read(file)
    if error.code!=.None {return}
    scene:=base.text_get(m.start_scene[:])
    if scene!=from && !(folder && asset_path_inside(scene,from)) {return}
    if !base.text_set(m.start_scene[:],strings.concatenate({to,scene[len(from):]},context.temp_allocator)) || project.manifest_write(file,&m).code!=.None {
        notify(s,fmt.tprintf("The start scene moved and %s could not be changed: set it again in Project settings",project.PROJECT_FILE))
    }
}

// ---------------------------------------------------------------- asset.move

// What a call names: an asset by its id or path, or a folder of the assets.
@(private)
api_asset_subject :: proc(call:^api.Call,r:^asset.Registry,name:string) -> (id:base.Asset_Id,folder:string,ok:bool) {
    if parsed,is_id:=serial.text_parse_asset_id(name);is_id {
        if _,found:=asset.registry_find(r,parsed);!found {
            api.call_failf(call,api.INVALID_PARAMS,"No asset has the id %s: asset.list lists them",name)
            return
        }
        return parsed,"",true
    }
    if file,found:=asset.registry_find_path(r,name);found && file.state==.Asset {return file.id,"",true}
    clean,refusal:=asset_folder_clean(r,name)
    if refusal=="" && clean!="" && os.is_dir(asset.registry_file_path(r,clean,context.temp_allocator)) {return {},clean,true}
    api.call_failf(call,api.INVALID_PARAMS,"%q is no asset nor folder: give a path under the asset folder or the id of an asset as asset.list lists them",name)
    return
}

@(private)
api_asset_moved :: proc(call:^api.Call,id:base.Asset_Id,path,message:string) {
    if message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    result:=api.call_result(call,Api_Asset_Moved_Result)
    if id!={} {base.asset_id_format(id,result.id[:])}
    base.text_set(result.path[:],path)
}

@(private)
api_asset_registry :: proc(s:^Session,call:^api.Call) -> ^asset.Registry {
    r:=files_registry(s)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"The editor has no asset folder it can change")}
    return r
}

@(private)
api_asset_move :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Asset_Move_Params)
    r:=api_asset_registry(s,call)
    if r==nil {return}
    id,folder,ok:=api_asset_subject(call,r,base.text_get(p.asset[:]))
    if !ok {return}
    place,name:=base.text_get(p.folder[:]),base.text_get(p.name[:])
    if place=="" && name=="" && !p.copy {
        api.call_fail(call,api.INVALID_PARAMS,"give a folder, a name or copy true: asset.move changes nothing without them")
        return
    }
    if place=="" {
        current:=folder
        if id!={} {
            file,_:=asset.registry_find(r,id)
            current=file.path
        }
        place=strings.clone(content_folder_of(current),context.temp_allocator)
    }
    if p.copy {
        if id=={} {
            path,message:=asset_folder_duplicate(s,folder,place,name)
            api_asset_moved(call,{},path,message)
            return
        }
        made,path,message:=asset_duplicate(s,id,place,name)
        api_asset_moved(call,made,path,message)
        return
    }
    if id=={} {
        path,message:=asset_folder_move(s,folder,place,name)
        api_asset_moved(call,{},path,message)
        return
    }
    path,message:=asset_move(s,id,place,name)
    api_asset_moved(call,id,path,message)
}
