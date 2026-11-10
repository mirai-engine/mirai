package editor

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Deleting an asset from the content browser or the API: the file goes to the
// trash of the system, from which the user brings it back, at once and not as
// an edit, as an import writes. The parts of an import go with the asset that
// owns them; what uses it is named before and keeps the reference.

Api_Asset_Delete_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The asset to delete: its path under the asset folder or its id"`,
}

Api_Asset_Users_Params :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The asset: its path under the asset folder or its id"`,
}

Api_Asset_Users_Result :: struct {
    used_by:[1][API_PATH_BYTES]u8 `mirai:"text,list,label=The files that reference the asset or a part it owns, by id: moving it keeps them working and deleting it breaks them"`,
}

ASSET_DELETE_USERS :: 4 // rows of the files that use it; the rest is a count
ASSET_DELETE_THUMB :: 56
ASSET_DELETE_USED_FILL :: ui.Color{42,28,33,255}
ASSET_DELETE_USED_RULE :: ui.Color{92,47,51,255}

// The files deleting id moves, as indices of the registry: the asset and its parts.
@(private)
asset_delete_files :: proc(r:^asset.Registry,id:base.Asset_Id) -> []u32 {
    at,known:=r.by_id[id]
    if !known {return nil}
    files:=make([dynamic]u32,context.temp_allocator)
    asset.registry_parts(r,id,&files)
    inject_at(&files,0,at)
    return files[:]
}

// As asset_delete_files, with what goes when the asset is the root of an
// import: what that import keeps in the imported folder, which nothing builds
// once its source and its sidecar are gone.
@(private)
asset_delete_all :: proc(s:^Session,r:^asset.Registry,id:base.Asset_Id) -> (files:[]u32,sidecar:string) {
    listed:=make([dynamic]u32,context.temp_allocator)
    append(&listed,..asset_delete_files(r,id))
    cached:[]u32
    sidecar,cached=import_root(s,r,id)
    for at in cached {
        if !slice.contains(listed[:],at) {append(&listed,at)}
    }
    return listed[:],sidecar
}

// The files that use what deleting id moves and are not moved with it.
@(private)
asset_delete_users :: proc(r:^asset.Registry,files:[]u32) -> []u32 {
    users:=make([dynamic]u32,context.temp_allocator)
    for at in files {
        for user in asset.registry_dependents(r,r.files[at].id) {
            if !slice.contains(files,user) && !slice.contains(users[:],user) {append(&users,user)}
        }
    }
    return users[:]
}

// Why an asset cannot be deleted now; empty when it can.
@(private)
asset_delete_refusal :: proc(s:^Session,r:^asset.Registry,file:^asset.Registry_File) -> string {
    if refusal:=asset_owned_refusal(r,file);refusal!="" {return refusal}
    if file.imported!=0 {
        if sidecar,_:=import_root(s,r,file.id);sidecar=="" {return "It is built by the import of its source, which makes it again: delete or move the asset that source gives (its prefab), change the source, or duplicate it to have a copy of its own"}
    }
    if watching(s) {return "The run of an agent is being watched; stop watching it first"}
    if busy:=import_busy(s);busy!="" {return busy}
    for at in asset_delete_files(r,file.id) {
        if scene_tab(s,r.files[at].id)>=0 {return "It is open in a tab: close the tab first"}
    }
    return ""
}

// Asks whether to delete an asset.
asset_delete_ask :: proc(s:^Session,id:base.Asset_Id) {
    r:=files_registry(s)
    if r==nil || s.gui==nil || id=={} {return}
    if _,found:=asset.registry_find(r,id);!found {return}
    s.gui.delete_asset=id
    s.gui.modal=.Delete_Asset
}

// Moves an asset and its parts to the trash. Returns the paths it moved, in
// the temporary allocator, and what went wrong.
asset_delete :: proc(s:^Session,id:base.Asset_Id) -> (moved:[]string,message:string) {
    r:=files_registry(s)
    if r==nil {return nil,"The editor has no asset folder it can change"}
    file,found:=asset.registry_find(r,id)
    if !found {return nil,"The asset is not in the registry"}
    if refusal:=asset_delete_refusal(s,r,file);refusal!="" {return nil,refusal}
    files,sidecar:=asset_delete_all(s,r,id)
    paths:=make([]string,len(files),context.temp_allocator)
    for at,i in files {paths[i]=strings.clone(r.files[at].path,context.temp_allocator)}
    // What memory holds of them goes first, or the registry would keep answering for them.
    assets_discard(s,paths)
    done:=make([dynamic]string,context.temp_allocator)
    for path in paths {
        if !platform.trash(asset.registry_file_path(r,path,context.temp_allocator)) {
            message=fmt.tprintf("%s could not be moved to the trash",path)
            break
        }
        append(&done,path)
    }
    // The import is given up with its root: its source stays, and importing it again is a new import.
    if message=="" && sidecar!="" {
        _=platform.trash(sidecar)
        _=platform.trash(strings.trim_suffix(sidecar,asset.SIDECAR_EXTENSION))
    }
    if len(done)>0 {
        host.assets_refresh(s.app.assets,done[:])
        host.content_refresh(s.app)
        asset_documents_prune(s)
        if c:=s.content;c!=nil {
            for at:=len(c.picked)-1;at>=0;at-=1 {
                if _,kept:=asset.registry_find(r,c.picked[at]);!kept {ordered_remove(&c.picked,at)}
            }
            if _,kept:=asset.registry_find(r,c.selected);!kept {content_unselect(c,c.selected)}
        }
    }
    return done[:],message
}

@(private)
asset_delete_modal :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    r:=files_registry(s)
    file:^asset.Registry_File
    found:=false
    if r!=nil {file,found=asset.registry_find(r,g.delete_asset)}
    if !found {
        g.modal,g.delete_asset=.None,{}
        return
    }
    closed:=false
    defer if closed {g.modal,g.delete_asset=.None,{}}
    if ui.modal(ctx,shell_id(g,"delete_asset"),{width=420,padding=16,gap=14,close=&closed}) {
        files,_:=asset_delete_all(s,r,file.id)
        users:=asset_delete_users(r,files)
        refusal:=asset_delete_refusal(s,r,file)
        ui.label(ctx,"Delete asset",th.font_heading,th.text,font=ui.FONT_SEMIBOLD)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=12,align_y=.Center}) {
            asset_thumbnail(s,file,ASSET_DELETE_THUMB)
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=4}) {
                ui.label(ctx,filepath.base(file.path),th.font+1,th.text,0,font=ui.FONT_SEMIBOLD)
                ui.label(ctx,file.path,th.font_small,th.text_faint,0)
            }
        }
        if len(files)>1 {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
                ui.label(ctx,len(files)==2?"With its part":fmt.tprintf("With its %d parts",len(files)-1),th.font_small,th.text_muted)
                for at in files[1:] {modal_asset_row(s,ctx,&r.files[at])}
            }
        }
        if len(users)>0 {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2,padding={0,8,0,4},fill=ASSET_DELETE_USED_FILL,stroke=ASSET_DELETE_USED_RULE,stroke_width=1,radius=6}) {
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={8,0,8,4}}) {
                    ui.label(ctx,fmt.tprintf("Used by %d",len(users)),th.font,th.danger,font=ui.FONT_SEMIBOLD)
                }
                for at in users[:min(len(users),ASSET_DELETE_USERS)] {
                    user:=&r.files[at]
                    icon,_:=asset_icon(s,shown_kind(user))
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),gap=8,padding={8,0,8,0},align_y=.Center}) {
                        ui.icon(ctx,icon,th.text_muted,14)
                        ui.label(ctx,filepath.base(user.path),th.font,th.text,0)
                    }
                }
                if len(users)>ASSET_DELETE_USERS {
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),padding={8,0,8,0},align_y=.Center}) {
                        ui.label(ctx,fmt.tprintf("and %d more",len(users)-ASSET_DELETE_USERS),th.font_small,th.text_muted)
                    }
                }
            }
        }
        if refusal!="" {ui.label(ctx,refusal,th.font_small,th.danger_soft)}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),gap=8,align_x=.End,align_y=.Center}) {
            if ui.button(ctx,shell_id(g,"delete_asset_cancel"),{label="Cancel",style=.Field,width=90,height=th.control,center=true}).clicked {closed=true}
            if ui.button(ctx,shell_id(g,"delete_asset_confirm"),{label="Delete",style=.Danger,width=90,height=th.control,center=true,disabled=refusal!=""}).clicked {
                id:=g.delete_asset
                g.modal,g.delete_asset=.None,{}
                moved,message:=asset_delete(s,id)
                switch {
                case message!="":  notify(s,message)
                case len(moved)==1: notify(s,fmt.tprintf("%s moved to the trash",asset_name(moved[0])))
                case:              notify(s,fmt.tprintf("%d files moved to the trash",len(moved)))
                }
            }
        }
    }
}

// The asset a call names by its path or its id; fails the call when there is none.
@(private)
api_asset_named :: proc(s:^Session,call:^api.Call,name:string) -> (r:^asset.Registry,id:base.Asset_Id,ok:bool) {
    r=files_registry(s)
    if r==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no asset folder it can change")
        return
    }
    problem:string
    if id,problem=asset_resolve(s,name,"");problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    if _,found:=asset.registry_find(r,id);!found {
        api.call_failf(call,api.INVALID_PARAMS,"No asset has the id %s: asset.list lists them",name)
        return
    }
    return r,id,true
}

@(private)
api_asset_users :: proc(s:^Session,call:^api.Call) {
    r,id,ok:=api_asset_named(s,call,base.text_get(api.call_params(call,Api_Asset_Users_Params).asset[:]))
    if !ok {return}
    w:=call.out
    serial.text_write_raw(w,`{"used_by":[`)
    for at,i in asset_delete_users(r,asset_delete_files(r,id)) {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_string(w,r.files[at].path)
    }
    serial.text_write_raw(w,`]}`)
}

@(private)
api_asset_delete :: proc(s:^Session,call:^api.Call) {
    r,id,ok:=api_asset_named(s,call,base.text_get(api.call_params(call,Api_Asset_Delete_Params).asset[:]))
    if !ok {return}
    users:=make([dynamic]string,context.temp_allocator)
    for at in asset_delete_users(r,asset_delete_files(r,id)) {append(&users,strings.clone(r.files[at].path,context.temp_allocator))}
    moved,message:=asset_delete(s,id)
    if len(moved)==0 {
        api.call_fail(call,api.INVALID_PARAMS,message!=""?message:"Nothing was deleted")
        return
    }
    w:=call.out
    serial.text_write_raw(w,`{"moved":[`)
    for path,i in moved {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_string(w,path)
    }
    serial.text_write_raw(w,`],"used_by":[`)
    for path,i in users {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_string(w,path)
    }
    serial.write_u8(w,']')
    if message!="" {api.write_text(w,"error",message)}
    serial.write_u8(w,'}')
}
