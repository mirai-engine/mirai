package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/serial"

Documents_Restore :: struct {
    active:int,
    tabs:[dynamic]Document_Restore,
    assets:[dynamic]string, // the asset documents, by their path in the registry or that of the source of a program
    asset:int,              // the one in front; -1: a scene
}

Document_Restore :: struct {
    path,selection:string, // path: empty for a document without a file yet
    orbit:Orbit,
    preview_sun:bool,
}

// The tabs, for the editor a restart starts: their files hold the documents.
// Written under folder, where documents_restore reads and removes it.
documents_save_restart :: proc(s:^Session,folder:string) -> (file:string,ok:bool) {
    documents_ensure(s)
    saved:=Documents_Restore{active=s.active_document,tabs=make([dynamic]Document_Restore,context.temp_allocator),assets=make([dynamic]string,context.temp_allocator),asset=s.asset_shown-1}
    for &d in s.asset_documents {append(&saved.assets,strings.clone(asset_document_path(s,&d),context.temp_allocator))}
    defer document_activate(s,saved.active)
    for index in 0..<len(s.documents) {
        document_activate(s,index)
        if document_flush(s)!=.None {return "",false}
        append(&saved.tabs,Document_Restore{strings.clone(document_path(s.document),context.temp_allocator),selected_ids(s),s.viewport.orbit,s.viewport.preview_sun})
    }
    data,encoded:=serial.text_encode(saved,.Line,context.temp_allocator)
    if !encoded {return "",false}
    file=project.path(folder,"restart-documents.json",allocator=context.temp_allocator)
    return file,serial.file_write_atomic(file,data)==.None
}

// The tabs a file lists, the first in the tab in front. "" or why not all of
// them came back.
documents_restore :: proc(s:^Session,file:string) -> string {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return fmt.tprintf("%s could not be read: %s",file,os.error_string(error))}
    _=os.remove(file)
    saved:Documents_Restore
    if serial.text_decode(string(data),&saved,context.temp_allocator)!="" || len(saved.tabs)==0 {return fmt.tprintf("%s lists no tabs",file)}
    documents_ensure(s)
    first:=s.active_document
    for tab,index in saved.tabs {
        if index>0 && !document_tab_new(s) {return fmt.tprintf("%s could not be opened in a new tab",tab.path)}
        if tab.path!="" {
            if failure:=scene_open(s,tab.path);failure!=.None {return fmt.tprintf("%s: %s",tab.path,document_error_text(failure))}
        }
        s.viewport.orbit,s.viewport.preview_sun=tab.orbit,tab.preview_sun
        select_ids(s,tab.selection)
    }
    document_activate(s,first+clamp(saved.active,0,len(saved.tabs)-1))
    // The asset documents open again; one whose asset is gone does not.
    for path,index in saved.assets {
        opened:=false
        if asset.registry_outside(path) {
            opened=asset_document_open_program(s,path)
        } else if record,found:=asset.registry_find_path(&s.app.assets.registry,path);found {
            opened=asset_document_open(s,record.id)
        }
        if !opened && saved.asset>=index {saved.asset-=1}
    }
    s.requests-={.Asset_Switch}
    if saved.asset>=0 {asset_document_activate(s,saved.asset)}
    return ""
}
