package editor

import "core:strings"
import "mirai:editor/api"
import "mirai:asset"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:std/serial"

Api_Document_Params :: struct {
    action:enum u8 {Open,Activate,Close,Preview_Sun} `mirai:"label=Open takes a scene or a prefab or an asset that opens as a document (a material or a kind a plugin declares); Preview_Sun turns the preview sun of a prefab on or off"`,
    path:[DOCUMENT_PATH_BYTES]u8 `mirai:"text,optional,label=Open: the file to open. The others: the document by its path as editor.documents lists it, a tab or an asset document; empty: the active tab, and for Close the asset document in front when one is"`,
    enabled:bool `mirai:"optional,label=Preview_Sun: whether the sun shows"`,
    discard:bool `mirai:"optional,label=Close: drops unsaved changes; without it closing them fails"`,
}

Api_Documents_Result :: struct {
    active:[DOCUMENT_PATH_BYTES]u8 `mirai:"text,label=The file of the active tab; empty before it has one"`,
    documents:[1]Api_Document_Tab `mirai:"list,label=The tabs of scenes and prefabs"`,
    asset:[API_PATH_BYTES]u8 `mirai:"text,label=The asset document in front; empty when the active tab is in front"`,
    assets:[1]Api_Asset_Document_Tab `mirai:"list,label=The asset documents"`,
}
Api_Document_Tab :: struct {
    path:[DOCUMENT_PATH_BYTES]u8 `mirai:"text,label=Its file; empty before it has one"`,
    dirty:bool `mirai:"label=Whether it has unsaved changes"`,
    preview_sun:bool `mirai:"label=Whether a prefab shows with the preview sun"`,
}
Api_Asset_Document_Tab :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Under the asset folder; of a Slang program the path of its .slang"`,
    kind:[32]u8 `mirai:"text,label=The kind of the asset; program for a Slang program"`,
    dirty:bool `mirai:"label=Whether it has unsaved changes"`,
    undo:int `mirai:"label=Steps it can undo"`,
    redo:int `mirai:"label=Steps it can redo"`,
}

documents_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="editor.documents",summary="The open documents: the tabs of scenes and prefabs and the asset documents next to them.",result=Api_Documents_Result,writes_result=true,flags={.Read_Only},run=api_documents})
    api_register(s,st,{name="editor.document",summary="Opens, activates or closes a document, or turns the preview sun of a prefab on or off.",params=Api_Document_Params,result=Api_Documents_Result,writes_result=true,run=api_document})
}

api_documents :: proc(s:^Session,call:^api.Call) {
    out:=call.out
    serial.text_write_raw(out,`{"active":`);serial.text_write_string(out,s.document!=nil?document_path(s.document):"")
    api.write_key(out,"documents");serial.write_u8(out,'[')
    for &tab,index in s.documents {
        d:=index==s.active_document?s.document:&tab.document
        e:=index==s.active_document?s.edits:&tab.edits
        v:=index==s.active_document?s.viewport:&tab.viewport
        if index>0 {serial.write_u8(out,',')}
        serial.text_write_raw(out,`{"path":`);serial.text_write_string(out,document_path(d))
        api.write_key(out,"dirty");api.write_flag(out,d.unsaved || history.edits_scene_state(e)!=d.saved)
        api.write_key(out,"preview_sun");api.write_flag(out,v.preview_sun)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    api.write_key(out,"asset");serial.text_write_string(out,api_asset_document_front(s))
    api.write_key(out,"assets");serial.write_u8(out,'[')
    for &d,index in s.asset_documents {
        if index>0 {serial.write_u8(out,',')}
        serial.text_write_raw(out,`{"path":`);serial.text_write_string(out,unsaved_name(s,asset_document_path(s,&d)))
        kind:="program"
        if d.id!={} {
            if info,known:=asset.kind_info(d.kind);known {kind=info.name}
        }
        api.write_key(out,"kind");serial.text_write_string(out,kind)
        api.write_key(out,"dirty");api.write_flag(out,asset_document_dirty(s,&d))
        api.write_key(out,"undo");serial.text_write_int(out,i64(d.history.cursor))
        api.write_key(out,"redo");serial.text_write_int(out,i64(len(d.history.steps)-d.history.cursor))
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    serial.write_u8(out,'}')
}

api_document :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Document_Params)
    if !collab_can_open(s) {api.call_fail(call,api.SERVER_ERROR,"Leave the shared session before changing documents (collab.leave)");return}
    path:=base.text_get(p.path[:])
    index:=s.active_document
    if p.action!=.Open {
        shown:=-1
        if path!="" {
            index,shown=api_document_named(s,path)
            if index<0 && shown<0 {api.call_failf(call,api.INVALID_PARAMS,"%q is not an open document: editor.documents lists them; Open opens one",path);return}
        } else if p.action==.Close && s.asset_shown>0 {
            index,shown=-1,s.asset_shown-1
        }
        if shown>=0 {
            api_asset_document(s,call,p,shown)
            return
        }
        if index<0 || index>=len(s.documents) {api.call_fail(call,api.INVALID_PARAMS,"No document is open: Open opens one");return}
    }
    switch p.action {
    case .Open:
        if path=="" {api.call_fail(call,api.INVALID_PARAMS,"An asset path is required");return}
        // An asset that is not a scene opens as an asset document.
        if !strings.has_suffix(path,".scene") {
            if file,found:=asset_document_file(s,path);found {
                if !asset_document_opens(s,file.kind) {api.call_failf(call,api.INVALID_PARAMS,"%s opens no document: scenes, materials and the kinds of the plugins do",path);return}
                asset_document_show(s,file.id)
                api_documents(s,call)
                return
            }
        }
        if error:=document_open_tab(s,path);error!=.None {api_document_fail(call,error,path);return}
        asset_document_activate(s,-1)
    case .Activate:
        asset_document_activate(s,-1)
        document_activate(s,index)
    case .Close:
        d:=index==s.active_document?s.document:&s.documents[index].document
        e:=index==s.active_document?s.edits:&s.documents[index].edits
        if d.unsaved || history.edits_scene_state(e)!=d.saved {
            if api_turn_refused(s,call,"close a document with unsaved changes") {return}
            if !p.discard {api.call_fail(call,api.SERVER_ERROR,"The document has unsaved changes; save it or pass discard");return}
        }
        document_activate(s,index)
        document_close_active(s)
    case .Preview_Sun:
        d:=index==s.active_document?s.document:&s.documents[index].document
        if !d.prefab {api.call_fail(call,api.INVALID_PARAMS,"The document is not a prefab: its scene did not have exactly one root when it was opened");return}
        document_activate(s,index)
        s.viewport.preview_sun=p.enabled
        s.view_cut=true
    }
    api_documents(s,call)
}

// The asset document in front, as editor.documents lists it; "" when none is.
@(private)
api_asset_document_front :: proc(s:^Session) -> string {
    if s.asset_shown<=0 || s.asset_shown>len(s.asset_documents) {return ""}
    return unsaved_name(s,asset_document_path(s,&s.asset_documents[s.asset_shown-1]))
}

// The open document named by its path: the index of a tab, or of an asset
// document in shown; both -1 when none has it.
@(private)
api_document_named :: proc(s:^Session,name:string) -> (index,shown:int) {
    index,shown=-1,-1
    file:=scene_file(s,name)
    for &tab,at in s.documents {
        d:=at==s.active_document?s.document:&tab.document
        if document_path(d)==name || (file!="" && document_file(d)==file) {return at,-1}
    }
    registered,found:=asset_document_file(s,name)
    for &d,at in s.asset_documents {
        if found && d.id==registered.id {return -1,at}
        if listed:=asset_document_path(s,&d);listed!="" && (listed==name || unsaved_name(s,listed)==name) {return -1,at}
    }
    return
}

// What editor.document does to the asset document at index.
@(private)
api_asset_document :: proc(s:^Session,call:^api.Call,p:^Api_Document_Params,index:int) {
    if index<0 || index>=len(s.asset_documents) {api.call_fail(call,api.INVALID_PARAMS,"That asset document is not open: editor.documents lists them");return}
    #partial switch p.action {
    case .Activate: asset_document_activate(s,index)
    case .Close:
        d:=&s.asset_documents[index]
        if asset_document_dirty(s,d) && !asset_document_used(s,d) {
            if api_turn_refused(s,call,"close an asset with unsaved changes") {return}
            if !p.discard {api.call_fail(call,api.SERVER_ERROR,"The asset has unsaved changes; save it (asset.save) or pass discard");return}
            path:=[1]string{asset_document_path(s,d)}
            assets_discard(s,path[:])
        }
        asset_document_close_now(s,index)
    case:
        api.call_fail(call,api.INVALID_PARAMS,"An asset document is activated or closed: Preview_Sun is of a prefab")
        return
    }
    api_documents(s,call)
}
