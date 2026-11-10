package editor

import "core:fmt"
import "core:path/filepath"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

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
    w:=call.out
    serial.text_write_raw(w,`{"asset":`);api_asset_write(w,id)
    api.write_text(w,"path",file.path)
    api.write_key(w,"owner");api_asset_write(w,owner)
    api.write_key(w,"unsaved");api.write_flag(w,true)
    serial.write_u8(w,'}')
}

// The files that had the id of another and were given one of their own, and
// the pairs that could not be: what engine.diagnostics tells as asset errors.
@(private)
api_duplicates_write :: proc(r:^asset.Registry,out:^serial.Writer,first:bool) -> (count:int) {
    buffer,other:[base.ASSET_ID_TEXT]u8
    for entry in r.reassigned {
        if !first || count>0 {serial.write_u8(out,',')}
        count+=1
        serial.write_u8(out,'{')
        api.write_text(out,"id",base.asset_id_format(entry.to,buffer[:]),true)
        api.write_text(out,"kind",api_kind_name(r,entry.path))
        api.write_text(out,"problem","Duplicate_Id")
        api.write_text(out,"detail","Reassigned")
        api.write_text(out,"path",entry.path)
        api.write_text(out,"message",fmt.tprintf("%s had the id %s of %s, as a copy made outside the editor does: in memory it has the id %s and is an asset of its own, without owner or import. Save it (asset.save) to keep that id, or delete the file if the copy is not wanted.",entry.path,base.asset_id_format(entry.from,other[:]),entry.original,base.asset_id_format(entry.to,buffer[:])))
        serial.write_u8(out,'}')
    }
    for duplicate in r.duplicates {
        if !first || count>0 {serial.write_u8(out,',')}
        count+=1
        a,b:=r.files[duplicate.first].path,r.files[duplicate.second].path
        serial.write_u8(out,'{')
        api.write_text(out,"id",base.asset_id_format(duplicate.id,buffer[:]),true)
        api.write_text(out,"kind",api_kind_name(r,a))
        api.write_text(out,"problem","Duplicate_Id")
        api.write_text(out,"detail","Unresolved")
        api.write_text(out,"path",b)
        api.write_text(out,"message",fmt.tprintf("%s and %s have the same id, and lookups give %s. One of them is unsaved, which keeps the id: save it (asset.save) or discard it (asset.discard), and delete the file that is a copy.",a,b,a))
        serial.write_u8(out,'}')
    }
    return
}

@(private)
api_kind_name :: proc(r:^asset.Registry,path:string) -> string {
    if file,found:=asset.registry_find_path(r,path);found {
        if info,known:=asset.kind_info(file.kind);known {return info.name}
    }
    return "other"
}
