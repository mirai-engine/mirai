package editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// asset.unsaved, asset.save and asset.discard: the asset files edits changed
// in memory and did not write (assets_unsaved.odin), with the sources of
// programs, named by their path under the project (unsaved_name).

API_UNSAVED :: 64
API_UNSAVED_NAMED :: 16 // of the unsaved files an error names, the rest counted

Api_Unsaved_Result :: struct {
    assets:[]Api_Unsaved_Asset,
    scene:[]string `mirai:"label=The unsaved assets the scene of the document uses"`,
}
Api_Unsaved_Asset :: struct {
    path:string `mirai:"label=Under the asset folder; of a Slang program the path of its .slang under the project or under engine/ for one of the engine"`,
    removed:bool `mirai:"label=Whether memory holds it as removed"`,
    asset:base.Asset_Id `mirai:"optional,label=Its id; a program has none"`,
    kind:string `mirai:"optional,label=The kind of the asset; program for a Slang program"`,
}

Api_Saved_Result :: struct {
    saved:int `mirai:"label=Assets written: to their files or as copies under folder"`,
    folder:[2*API_PATH_BYTES]u8 `mirai:"text,optional,label=With folder: the full path of the copies"`,
}

Api_Discarded_Result :: struct {
    discarded:int `mirai:"label=Assets given back what their files hold"`,
}

Api_Asset_Save_Params :: struct {
    assets:[]string `mirai:"optional,label=At most 64. Unsaved assets, by their path under the asset folder or their id; a program by the path of its .slang under the project. asset.save without assets or all: those of the turn of the caller, or every one outside a turn"`,
    all:bool `mirai:"optional,label=Every unsaved asset instead of a list"`,
    folder:string `mirai:"optional,label=asset.save: writes copies under this folder of the project, inside .mirai/tmp/, and leaves the assets unsaved"`,
}

@(private)
unsaved_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="asset.unsaved",summary="The assets and Slang programs changed in memory and not saved, and which of them the scene of the document uses.",result=Api_Unsaved_Result,flags={.Read_Only},run=api_asset_unsaved})
    api_register(s,st,{name="asset.save",flags={.Core},params=Api_Asset_Save_Params,summary="Writes unsaved assets to their files, or copies of them that leave them unsaved. Writing the files is refused while a game plays.",result=Api_Saved_Result,writes_result=true,run=api_asset_save})
    api_register(s,st,{name="asset.discard",params=Api_Asset_Save_Params,summary="Gives unsaved assets back what their files hold; one that only memory held is gone.",result=Api_Discarded_Result,run=api_asset_discard})
}

@(private)
api_asset_unsaved :: proc(s:^Session,call:^api.Call) {
    if s.app==nil || s.app.assets==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no assets")
        return
    }
    r:=&s.app.assets.registry
    held:=assets_unsaved(s)
    result:=api.call_result(call,Api_Unsaved_Result)
    result.assets=make([]Api_Unsaved_Asset,len(held),call.allocator)
    for entry,i in held {
        out:=&result.assets[i]
        out.path,out.removed=unsaved_name(s,entry.path),entry.removed
        if asset.registry_outside(entry.path) {
            out.kind="program"
        } else if file,found:=asset.registry_find_path(r,entry.path);found && file.state==.Asset {
            out.asset,out.kind=file.id,api_asset_kind_name(s,file.kind)
        }
    }
    used:=make([dynamic]string,call.allocator)
    world_unsaved_assets(s,edited_world(s),&used)
    for &path in used {path=unsaved_name(s,path)}
    result.scene=used[:]
}

// The unsaved files of the caller: those its turn changed, or every one
// outside a turn.
@(private)
api_unsaved_of_caller :: proc(s:^Session,call:^api.Call) -> []string {
    task:=ai_task_find(s.ai,ai_task_of_call(s,call)) if s.ai!=nil else nil
    if task==nil {return assets_unsaved_paths(s)}
    r:=&s.app.assets.registry
    paths:=make([dynamic]string,context.temp_allocator)
    for held in assets_unsaved(s) {
        for changed in task.review.changed_files {
            relative,inside:=asset.registry_relative(r,changed)
            if changed==held.path || inside && relative==held.path {
                append(&paths,strings.clone(held.path,context.temp_allocator))
                break
            }
        }
    }
    return paths[:]
}

// The paths the params name: each an unsaved asset, by path or id, all of
// them, or with none named those of the caller when none says so.
@(private)
api_unsaved_paths :: proc(s:^Session,call:^api.Call,p:^Api_Asset_Save_Params,of_caller:=false) -> (paths:[dynamic]string,ok:bool) {
    if s.app==nil || s.app.assets==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no assets")
        return
    }
    paths=make([dynamic]string,context.temp_allocator)
    if p.all {
        append(&paths,..assets_unsaved_paths(s))
        return paths,true
    }
    r:=&s.app.assets.registry
    if len(p.assets)>API_UNSAVED {
        api.call_failf(call,api.INVALID_PARAMS,"assets takes at most %d entries; all: true takes every one",API_UNSAVED)
        return
    }
    for name in p.assets {
        if name=="" {continue}
        path:=name
        if id,is_id:=serial.text_parse_asset_id(name);is_id {
            if file,found:=asset.registry_find(r,id);found {path=file.path}
        }
        for held in assets_unsaved(s) {
            if asset.registry_outside(held.path) && unsaved_name(s,held.path)==name {path=held.path}
        }
        if _,found:=asset.registry_memory_find(r,path);!found {
            api.call_failf(call,api.INVALID_PARAMS,"%q has no unsaved changes; asset.unsaved lists the assets that have",name)
            return
        }
        append(&paths,strings.clone(path,context.temp_allocator))
    }
    if len(paths)==0 && of_caller {
        append(&paths,..api_unsaved_of_caller(s,call))
        return paths,true
    }
    if len(paths)==0 {
        api.call_fail(call,api.INVALID_PARAMS,"Name the assets, or pass all: true")
        return
    }
    return paths,true
}

@(private)
api_asset_save :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Asset_Save_Params)
    paths,ok:=api_unsaved_paths(s,call,p,of_caller=true)
    if !ok {return}
    folder:=p.folder
    if folder!="" {
        api_unsaved_copy(s,call,folder,paths[:])
        return
    }
    if !api_guard(s,call) {return}
    saved,failures:=assets_write(s,paths[:])
    if failures!="" {
        api.call_failf(call,api.SERVER_ERROR,"%d of %d assets could not be written and stay unsaved: %s",len(paths)-saved,len(paths),failures)
        return
    }
    serial.text_write_raw(call.out,`{"saved":`);serial.text_write_int(call.out,i64(saved))
    serial.write_u8(call.out,'}')
}

// Copies of unsaved assets under a folder of .mirai/tmp/ of the project, at
// their paths in the registry: what a check reads without saving the project.
@(private)
api_unsaved_copy :: proc(s:^Session,call:^api.Call,folder:string,paths:[]string) {
    temporary:=project.path(s.project_root,".mirai/tmp",allocator=context.temp_allocator)
    target:=project.path(s.project_root,folder,allocator=context.temp_allocator)
    if !strings.has_prefix(target,temporary) || (len(target)>len(temporary) && target[len(temporary)]!='/') {
        api.call_failf(call,api.INVALID_PARAMS,"folder %q is not inside .mirai/tmp/ of the project: copies go there, never over the assets",folder)
        return
    }
    r:=&s.app.assets.registry
    copied:=0
    for path in paths {
        held,found:=asset.registry_memory_find(r,path)
        if !found || held.removed {continue}
        file:=project.path(target,unsaved_name(s,path),allocator=context.temp_allocator)
        if dir:=filepath.dir(file);!os.is_dir(dir) {_=os.make_directory_all(dir)}
        if serial.file_write_atomic(file,held.data)!=.None {
            api.call_failf(call,api.SERVER_ERROR,"%s could not be written",file)
            return
        }
        copied+=1
    }
    serial.text_write_raw(call.out,`{"saved":`);serial.text_write_int(call.out,i64(copied))
    api.write_key(call.out,"folder");serial.text_write_string(call.out,target)
    serial.write_u8(call.out,'}')
}

@(private)
api_asset_discard :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"discard unsaved changes of the user") {return}
    p:=api.call_params(call,Api_Asset_Save_Params)
    if p.folder!="" {
        api.call_fail(call,api.INVALID_PARAMS,"folder is for asset.save")
        return
    }
    paths,ok:=api_unsaved_paths(s,call,p)
    if !ok {return}
    api.call_result(call,Api_Discarded_Result).discarded=assets_discard(s,paths[:])
}
