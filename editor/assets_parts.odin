package editor

import "core:fmt"
import "core:path/filepath"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:std/base"

// Parts of assets. An import makes the meshes and skeletons of a model, and
// the materials and textures surely of it alone, parts of its prefab: their
// header names it as owner (asset.Header.owner, cook/import/parts.odin).
// Taking a part out of its owner clears that and nothing else: it is still
// what the import writes, which keeps it out of the owner from then on.
// Copies of assets made outside the editor get an id of their own in the
// registry (registry_duplicates_resolve), which the API tells with how to
// keep it.

Api_Detach_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The part to take out of the asset that owns it: its path under the asset folder or its id"`,
}

// Takes the asset id out of the asset that owns it, as an edit of its file:
// unsaved until it is saved, with undo. The owner it had, or a message that
// says why it could not.
asset_detach :: proc(s:^Session,id:base.Asset_Id) -> (owner:base.Asset_Id,message:string) {
    r:=files_registry(s)
    if r==nil {return {},"The editor has no asset folder it can change"}
    file,found:=asset.registry_find(r,id)
    buffer:[base.ASSET_ID_TEXT]u8
    if !found {return {},fmt.tprintf("No asset has the id %s; asset.list lists them",base.asset_id_format(id,buffer[:]))}
    path:=file.path
    if file.owner=={} {return {},fmt.tprintf("%s is a part of no asset: it already is one of its own",path)}
    if file.imported!=0 {return {},fmt.tprintf("%s is built by the import of its source, whose sidecar says it is a part: import the source with parts none, or duplicate the asset to have one of its own",path)}
    owner=file.owner
    bytes,error:=asset.registry_read(r,path,context.temp_allocator)
    if error==.None {error=asset.header_owner_set(bytes,{})}
    if error!=.None {return {},fmt.tprintf("%s could not be read: %v",path,error)}
    named:=fmt.tprintf("%s",base.asset_id_format(owner,buffer[:]))
    if known,has:=asset.registry_find(r,owner);has {named=filepath.stem(known.path)}
    if !file_write(s,asset.registry_file_path(r,path,context.temp_allocator),bytes,fmt.tprintf("Take %s out of %s",filepath.stem(path),named)) {
        return {},fmt.tprintf("%s could not be changed",path)
    }
    return owner,""
}

@(private)
api_asset_detach :: proc(s:^Session,call:^api.Call) {
    r,id,named:=api_asset_named(s,call,base.text_get(api.call_params(call,Api_Detach_Params).asset[:]))
    if !named {return}
    owner,message:=asset_detach(s,id)
    if message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    file,_:=asset.registry_find(r,id)
    api.call_result(call,Api_Detach_Result)^={id,file.path,owner,true}
}

// The files that had the id of another and were given one of their own, and
// the pairs that could not be: what engine.diagnostics tells as asset errors.
@(private)
api_duplicates_list :: proc(r:^asset.Registry,errors:^[dynamic]Api_Engine_Diagnostics_Result_Asset_Errors) {
    buffer,other:[base.ASSET_ID_TEXT]u8
    for entry in r.reassigned {
        append(errors,Api_Engine_Diagnostics_Result_Asset_Errors{
            fmt.tprint(base.asset_id_format(entry.to,buffer[:])),api_kind_name(r,entry.path),"Duplicate_Id","Reassigned",entry.path,
            fmt.tprintf("%s had the id %s of %s, as a copy made outside the editor does: in memory it has the id %s and is an asset of its own, without owner or import. Save it (asset.save) to keep that id, or delete the file if the copy is not wanted.",entry.path,base.asset_id_format(entry.from,other[:]),entry.original,base.asset_id_format(entry.to,buffer[:])),
        })
    }
    for duplicate in r.duplicates {
        a,b:=r.files[duplicate.first].path,r.files[duplicate.second].path
        append(errors,Api_Engine_Diagnostics_Result_Asset_Errors{
            fmt.tprint(base.asset_id_format(duplicate.id,buffer[:])),api_kind_name(r,a),"Duplicate_Id","Unresolved",b,
            fmt.tprintf("%s and %s have the same id, and lookups give %s. One of them is unsaved, which keeps the id: save it (asset.save) or discard it (asset.discard), and delete the file that is a copy.",a,b,a),
        })
    }
}

@(private)
api_kind_name :: proc(r:^asset.Registry,path:string) -> string {
    if file,found:=asset.registry_find_path(r,path);found {
        if info,known:=asset.kind_info(file.kind);known {return info.name}
    }
    return "other"
}
