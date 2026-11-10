package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:host"
import "mirai:project"
import "mirai:std/serial"

RESTART_ASSETS :: "restart-assets"

Documents_Restore :: struct {
    active:int,
    tabs:[dynamic]Document_Restore,
    assets:[dynamic]string, // the asset documents, by their path in the registry or that of the source of a program
    asset:int,              // the one in front; -1: a scene
}

Document_Restore :: struct {
    file,path,selection:string,
    orbit:Orbit,
    dirty,preview_sun:bool,
}

// The tabs and the unsaved assets, for the editor a restart starts: written
// under folder, where documents_restore reads and removes them.
documents_save_restart :: proc(s:^Session,folder:string) -> (file:string,ok:bool) {
    documents_ensure(s)
    if !assets_unsaved_store(s,project.path(folder,RESTART_ASSETS,allocator=context.temp_allocator)) {return "",false}
    saved:=Documents_Restore{active=s.active_document,tabs=make([dynamic]Document_Restore,context.temp_allocator),assets=make([dynamic]string,context.temp_allocator),asset=s.asset_shown-1}
    for &d in s.asset_documents {append(&saved.assets,strings.clone(asset_document_path(s,&d),context.temp_allocator))}
    defer document_activate(s,saved.active)
    for index in 0..<len(s.documents) {
        document_activate(s,index)
        snapshot:=project.path(folder,fmt.tprintf("restart-%d.scene",index),allocator=context.temp_allocator)
        if document_write(s,snapshot,false)!=.None {return "",false}
        append(&saved.tabs,Document_Restore{snapshot,strings.clone(document_path(s.document),context.temp_allocator),selected_ids(s),s.viewport.orbit,document_dirty(s),s.viewport.preview_sun})
    }
    data,encoded:=serial.text_encode(saved,.Line,context.temp_allocator)
    if !encoded {return "",false}
    file=project.path(folder,"restart-documents.json",allocator=context.temp_allocator)
    return file,serial.file_write_atomic(file,data)==.None
}

// The tabs a file keeps, the first in the tab in front or, with beside,
// after the tabs there are. "" or why not all of them came back.
documents_restore :: proc(s:^Session,file:string,beside:=false) -> string {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return fmt.tprintf("%s could not be read: %s",file,os.error_string(error))}
    saved:Documents_Restore
    if serial.text_decode(string(data),&saved,context.temp_allocator)!="" || len(saved.tabs)==0 {return fmt.tprintf("%s lists no tabs",file)}
    folder:=filepath.dir(project.path_absolute(file,context.temp_allocator))
    for tab,index in saved.tabs {
        expected:=project.path(folder,fmt.tprintf("restart-%d.scene",index),allocator=context.temp_allocator)
        if tab.file!=expected {return fmt.tprintf("%s names %s where %s should be",file,tab.file,expected)}
    }
    // The scenes find the assets as they were.
    if assets:=project.path(folder,RESTART_ASSETS,allocator=context.temp_allocator);assets_unsaved_kept(assets) {
        if _,restored:=assets_unsaved_restore(s,assets);!restored {return fmt.tprintf("the unsaved assets in %s could not be read",assets)}
    }
    documents_ensure(s)
    first,after:=s.active_document,len(s.documents)
    if beside {first=after}
    for tab,index in saved.tabs {
        if (index>0 || beside) && !document_tab_new(s) {return fmt.tprintf("%s could not be opened in a new tab",tab.path)}
        if failure:=document_restore(s,tab.file,tab.path,tab.dirty);failure!=.None {return fmt.tprintf("%s: %s",tab.path,document_error_text(failure))}
        s.viewport.orbit,s.viewport.preview_sun=tab.orbit,tab.preview_sun
        select_ids(s,tab.selection)
    }
    active:=clamp(saved.active,0,len(saved.tabs)-1)
    document_activate(s,active==0?first:(beside?first:after-1)+active)
    // The asset documents open again; one whose asset is gone does not.
    for path,index in saved.assets {
        opened:=false
        if asset.registry_outside(path) {
            opened=asset_document_open_program(s,path)
        } else if file,found:=asset.registry_find_path(&s.app.assets.registry,path);found {
            opened=asset_document_open(s,file.id)
        }
        if !opened && saved.asset>=index {saved.asset-=1}
    }
    s.requests-={.Asset_Switch}
    if saved.asset>=0 {asset_document_activate(s,saved.asset)}
    for tab in saved.tabs {_=os.remove(tab.file)}
    _=os.remove(file)
    return ""
}
