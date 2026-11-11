package editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:ui"

// The active tab lives in the editor storages; the other tabs own their parked state.
Document_Tab :: struct {
    world:rawptr,
    document:Document,
    edits:history.Edits,
    selection:history.Selection,
    viewport:Viewport,
    inspector:Inspector,
    outliner:Outliner,
    prefabs:Prefabs,
}

documents_ensure :: proc(s:^Session) {
    if len(s.documents)==0 {append(&s.documents,Document_Tab{})}
}

// Swaps through memory: at -o:speed with LLVM 20 (the Odin of Linux and macOS) `a^,b^=b^,a^` of
// a value with an array of more than 1024 elements after a field writes the second copy from
// memory the first overwrote (odin-lang/Odin#8113).
swap_values :: proc(a,b:^$T) {slice.ptr_swap_non_overlapping(a,b,size_of(T))}

document_tab_exchange :: proc(s:^Session,tab:^Document_Tab) {
    s.edit_world,tab.world=tab.world,s.edit_world
    swap_values(s.document,&tab.document)
    // Who edits stays with the document in front.
    author:=s.edits.author
    swap_values(s.edits,&tab.edits)
    s.edits.author,tab.edits.author=author,history.EDIT_AUTHOR_USER
    swap_values(s.selection,&tab.selection)
    preferences:=s.viewport.preferences
    swap_values(s.viewport,&tab.viewport)
    s.viewport.preferences=preferences
    swap_values(s.inspector,&tab.inspector)
    swap_values(s.outliner,&tab.outliner)
    if p:=prefabs_of(s);p!=nil {swap_values(p,&tab.prefabs)}
}

document_tab_free :: proc(s:^Session,tab:^Document_Tab) {
    if tab.world==nil {return}
    ai_document_closed(s,tab.world)
    host.app_world_free(s.app,tab.world)
    document_previous_free(&tab.document)
    history.edits_free(&tab.edits)
    prefabs_state_free(&tab.prefabs)
    core.value_free(&tab.selection,type_info_of(history.Selection))
    viewport_free(&tab.viewport)
    core.value_free(&tab.inspector,type_info_of(Inspector))
    core.value_free(&tab.outliner,type_info_of(Outliner))
    tab^={}
}

documents_free :: proc(s:^Session) {
    for &tab in s.documents {document_tab_free(s,&tab)}
    delete(s.documents)
    s.documents=nil
}

document_activate :: proc(s:^Session,index:int) -> bool {
    if index<0 || index>=len(s.documents) {return false}
    if index==s.active_document {return true}
    if !collab_can_open(s) {return false}
    runs_stop(s)
    tools_release(s)
    ai_turns_stop(s,s.ai,"Stopped when switching documents")
    if s.gui.ctx!=nil {s.gui.ctx.edit={};s.gui.ctx.scrub={}}
    s.inspector.gesture=0
    settings_flush(s)
    history.edits_commit(s.edits,edited_world(s),s.selection)
    // A tab at the back holds what its file does.
    document_flush(s)
    document_tab_exchange(s,&s.documents[s.active_document])
    document_tab_exchange(s,&s.documents[index])
    s.active_document=index
    s.gui.documents_reveal=true
    settings_load(s)
    s.viewport.exposure={}
    if s.viewport.exposure_source==.Camera {s.viewport.exposure_source=.Scene}
    s.view_cut=true
    s.gui.drag,s.gui.placement={},{}
    s.inspector.picker,s.inspector.list={},{}
    if s.materials!=nil {s.materials.color,s.materials.list={},{} }
    if document_is_prefab(s) {assets_rescan(s)}
    document_file_follow(s)
    if prefab_linked(s) {
        for state in prefab_instances(s) {
            if state.stale {prefab_refresh(s,{});break}
        }
    }
    return true
}

// The file of the document in front is not the one it read or wrote: it
// changed outside the editor (git, a tool, another tab that wrote the prefab),
// and the document reads it again, with a new history.
document_file_follow :: proc(s:^Session) {
    d:=s.document
    if s.app.assets==nil || d.id=={} || document_file(d)=="" {return}
    file,found:=asset.registry_find(&s.app.assets.registry,d.id)
    if !found || d.source_stamp==([2]i64{file.size,file.time}) {return}
    selected:=selected_ids(s)
    if scene_open(s,document_file(d))==.None {select_ids(s,selected)} else {document_source_stamp(s)}
}

// Opens a scene, or brings its tab. One scene is open at a time, beside any
// number of prefabs: another scene takes the tab of the one open.
document_open_tab :: proc(s:^Session,path:string) -> Document_Error {
    if s.app.assets==nil {return .No_Assets}
    if !collab_can_open(s) {return .Rejected}
    documents_ensure(s)
    file:=scene_file(s,path)
    if file=="" {return .Bad_Path}
    for &tab,index in s.documents {
        d:=index==s.active_document?s.document:&tab.document
        if document_file(d)==file {document_activate(s,index);return .None}
    }
    if scene:=document_scene_tab(s);scene>=0 && !path_is_prefab(s,path) {
        previous:=s.active_document
        document_activate(s,scene)
        if error:=scene_open(s,path);error!=.None {
            document_activate(s,previous)
            return error
        }
        return .None
    }
    previous:=s.active_document
    if !document_tab_new(s) {return .Rejected}
    if error:=scene_open(s,path);error!=.None {
        document_tab_drop_last(s,previous)
        return error
    }
    if document_is_prefab(s) {
        w:=edited_world(s)
        for e in core.world_table_of(w,core.Id).entities {
            if entity_parent(w,e)==core.NONE {history.selection_add(s.selection,e)}
        }
        focus_selection(s,w)
    }
    return .None
}

// A tab with a World of its own, in front.
document_tab_new :: proc(s:^Session) -> bool {
    world:=host.app_world_create(s.app)
    if world==nil {return false}
    tab:=Document_Tab{world=world}
    viewport_init(&tab.viewport)
    tab.viewport.origin,tab.viewport.size,tab.viewport.window=s.viewport.origin,s.viewport.size,s.viewport.window
    append(&s.documents,tab)
    if document_activate(s,len(s.documents)-1) {return true}
    document_tab_free(s,&s.documents[len(s.documents)-1])
    resize(&s.documents,len(s.documents)-1)
    return false
}

// Takes out the last tab, which document_tab_new opened, back to the one in front before it.
document_tab_drop_last :: proc(s:^Session,previous:int) {
    document_activate(s,previous)
    document_tab_free(s,&s.documents[len(s.documents)-1])
    resize(&s.documents,len(s.documents)-1)
}

// A tab already holds the file of a path.
document_holds_file :: proc(s:^Session,path:string) -> bool {
    file:=scene_file(s,path)
    for &tab,index in s.documents {
        d:=index==s.active_document?s.document:&tab.document
        if document_file(d)==file {return true}
    }
    return false
}

// The tab of the scene; -1 when only prefabs are open.
document_scene_tab :: proc(s:^Session) -> int {
    for &tab,index in s.documents {
        d:=index==s.active_document?s.document:&tab.document
        if !d.prefab {return index}
    }
    return -1
}

// Whether the file a path names is a prefab, as its header says; a path that names no file yet is none.
path_is_prefab :: proc(s:^Session,path:string) -> bool {
    if s.app==nil || s.app.assets==nil {return false}
    file,found:=asset.registry_find_path(&s.app.assets.registry,scene_path(s,scene_file(s,path)))
    return found && asset.registry_prefab(file)
}

// Others lose what they do when the scene changes: the guests of the session,
// or this end its place in it, and the agents at work.
scene_switch_interrupts :: proc(s:^Session) -> bool {
    return collab_active(s) || ai_working_count(s)>0
}

document_close :: proc(s:^Session,index:int) {
    if document_activate(s,index) {document_close_active(s)}
}

document_close_active :: proc(s:^Session) {
    if len(s.documents)<=1 {scene_new(s);return}
    index:=s.active_document
    document_activate(s,index>0?index-1:1)
    document_tab_free(s,&s.documents[index])
    for i in index..<len(s.documents)-1 {s.documents[i]=s.documents[i+1]}
    resize(&s.documents,len(s.documents)-1)
    if s.active_document>index {s.active_document-=1}
}

// The editor ends, and the editor of the project asked for next starts;
// while agents work it asks first, and then about the pending changes, which
// it keeps or discards before it ends.
documents_quit :: proc(s:^Session,agents_asked:=false,pending_asked:=false) {
    if !agents_asked && ai_working_count(s)>0 {confirm_open(s,.Quit);return}
    if !pending_asked && git_quit_ask(s) {return}
    if projects_next_start(s) {s.quit=true}
}

// A tab of the strip: those of the scenes first, then those of the assets.
@(private)
Strip_Tab :: struct {
    label:string,
    icon:ui.Icon,
    pending,active:bool, // pending: its file has what is not kept
    asset:int, // the index of its asset document; -1 for a scene
}

@(private)
strip_tab_count :: proc(s:^Session) -> int {return max(len(s.documents),1)+len(s.asset_documents)}

@(private)
strip_tab :: proc(s:^Session,index:int) -> (tab:Strip_Tab) {
    scenes:=max(len(s.documents),1)
    if index>=scenes {
        tab.asset=index-scenes
        d:=&s.asset_documents[tab.asset]
        tab.label,tab.icon=asset_document_title(s,d),asset_document_icon(s,d)
        tab.active=s.asset_shown==tab.asset+1
        if path:=asset_document_path(s,d);path!="" {
            if r:=files_registry(s);r!=nil && !asset.registry_outside(path) {path=asset.registry_file_path(r,path,context.temp_allocator)}
            tab.pending=git_pending(s,path)
        }
        return
    }
    tab.asset=-1
    d:=s.document
    if index!=s.active_document && index<len(s.documents) {d=&s.documents[index].document}
    tab.label=document_title(d)
    tab.pending=git_pending(s,document_file(d))
    tab.icon=d.prefab?.Prefab:.Scene
    tab.active=index==s.active_document && !scene_covered(s)
    return
}

@(private)
document_tab_width :: proc(s:^Session,tab:Strip_Tab,room:f32) -> f32 {
    width:=ui.text_width(&s.gui.ctx.font,tab.label,ui.metric(s.gui.ctx,"font"))+54
    if tab.pending {width+=ui.text_width(&s.gui.ctx.font," •",ui.metric(s.gui.ctx,"font"))}
    return clamp(width,90,max(room,90))
}

documents_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    id:=shell_id(g,"documents")
    strip_id:=shell_id(g,"documents_strip")
    count:=strip_tab_count(s)
    available:=max(ctx.size.x-310,100)
    if rect,found:=ui.widget_rect(ctx,id);found && rect.w>0 {available=rect.w}
    room:=max(available-f32(count-1)*3,1)/f32(count)
    total:=f32(0)
    active_start,active_end:f32
    for index in 0..<count {
        tab:=strip_tab(s,index)
        width:=document_tab_width(s,tab,room)
        if index>0 {total+=3}
        if tab.active {active_start,active_end=total,total+width}
        total+=width
    }
    overflow:=total>available+0.5
    strip_width:=max(available-(overflow?50:0),1)
    if rect,found:=ui.widget_rect(ctx,strip_id);found && rect.w>0 && overflow {strip_width=min(rect.w,strip_width)}
    limit:=max(total-strip_width,0)
    if !overflow {g.documents_scroll=0}
    if g.documents_reveal || available!=g.documents_width {
        ui.scroll_reveal(&g.documents_scroll,active_start,active_end,strip_width)
        g.documents_reveal=false
    }
    g.documents_width=available
    if ctx.wheel_target==strip_id {
        delta:=ctx.input.wheel.x!=0?ctx.input.wheel.x:ctx.input.wheel.y
        g.documents_scroll-=delta*ui.WHEEL_STEP
    }
    g.documents_scroll=clamp(g.documents_scroll,0,limit)
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.GROW,gap=3,align_y=.End,track=true}) {
        if overflow {
            previous:=shell_id(g,"documents_previous")
            named_add(g,previous)
            if ui.button(ctx,previous,{label="←",tip="Previous documents",variant="ghost",width=22,height=28,size=ui.metric(ctx,"font"),disabled=g.documents_scroll<=0}).clicked {
                g.documents_scroll=max(g.documents_scroll-max(strip_width*0.6,90),0)
            }
        }
        if ui.box(ctx,{id=strip_id,width=ui.GROW,height=ui.GROW,gap=3,align_y=.Center,clip_x=true,scroll={g.documents_scroll,0}}) {
            ui.interact(ctx,strip_id,{.Passive,.Scroll})
            at:=f32(0)
            for index in 0..<count {
                tab:=strip_tab(s,index)
                active:=tab.active
                label:=tab.label
                if tab.pending {label=ui.text_commit(ctx,fmt.bprintf(ui.text_reserve(ctx,len(label)+4),"%s •",label))}
                width:=document_tab_width(s,tab,room)
                tab_id:=shell_id(g,"document_tab",index+1)
                close_id:=shell_id(g,"document_close",index+1)
                surface_id:=shell_id(g,"document_surface",index+1)
                if at+width>g.documents_scroll && at<g.documents_scroll+strip_width {
                    named_add(g,surface_id,clip=strip_id)
                    named_add(g,close_id,clip=strip_id)
                }
                surface:=ui.interact(ctx,surface_id,{.Focusable})
                hot:=surface.hot || ctx.hot==tab_id || ctx.hot==close_id
                fill:=active?ui.tone(ctx,"panel"):ui.tone(ctx,"bar_bottom")
                if hot {fill=active?ui.color_shade(fill,1.15):ui.tone(ctx,"field_hover")}
                text_color:=active || hot?ui.tone(ctx,"text"):ui.tone(ctx,"text_muted")
                appearance:=ui.Node_Style{text={size=ui.metric(ctx,"font"),color=text_color}}
                // The whole height of the bar takes its clicks, up to the edge of the window.
                if ui.box(ctx,{id=surface_id,width=ui.fixed(width),height=ui.fixed(ui.metric(ctx,"bar_height")),align_y=.Center}) {
                    if ui.box(ctx,{id=shell_id(g,"document_look",index+1),track=true,width=ui.fixed(width),height=ui.fixed(active?ui.metric(ctx,"bar_height"):ui.metric(ctx,"control")),gap=1,padding={2,0,2,0},align_y=.Center,fill=fill,radius=4}) {
                        if active {
                            if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(4),fill=fill,float={to=.Parent,anchor=.Bottom_Left,pivot=.Bottom_Left,layer=ui.LAYER_BAR}}) {}
                        }
                        if ui.button(ctx,tab_id,{label=label,icon=tab.icon,width=-1,height=ui.metric(ctx,"control"),size=ui.metric(ctx,"font"),icon_size=12,look=&appearance}).clicked || surface.clicked {
                            switch {
                            case tab.asset>=0: asset_document_request(s,tab.asset)
                            case:              s.document_request=index;s.requests+={.Document_Switch}
                            }
                        }
                        close:=ui.Node_Style{fill=ctx.hot==close_id?ui.color_alpha(ui.tone(ctx,"text"),65):ui.Color{},radius=12,text={color=text_color}}
                        if ui.button(ctx,close_id,{icon=.Cross,width=19,height=19,icon_size=10,icon_color=text_color,look=&close}).clicked {
                            switch {
                            case tab.asset>=0: s.asset_request=tab.asset;s.requests+={.Asset_Close}
                            case:              s.document_request=index;s.requests+={.Document_Close}
                            }
                        }
                    }
                }
                at+=width+3
            }
        }
        if overflow {
            next:=shell_id(g,"documents_next")
            named_add(g,next)
            if ui.button(ctx,next,{label="→",tip="Next documents",variant="ghost",width=22,height=28,size=ui.metric(ctx,"font"),disabled=g.documents_scroll>=limit}).clicked {
                g.documents_scroll=min(g.documents_scroll+max(strip_width*0.6,90),limit)
            }
        }
    }
}

document_is_prefab :: proc(s:^Session) -> bool {
    return s.document!=nil && s.document.prefab
}

// Who loses what they do when the scene changes, for the question that asks
// first; empty when nobody does.
scene_switch_others :: proc(s:^Session,pending:Pending) -> string {
    if pending!=.Open_Scene && pending!=.New {return ""}
    st:=collab_state(s)
    if st!=nil && st.role==.Guest && st.phase!=.Ended {return "You leave the shared session: the other scene is yours alone."}
    if collab_hosting(s) {
        count:=0
        for &peer,i in st.peers {if i!=0 && peer.used && peer.joined {count+=1}}
        if count==1 {return "The collaborator of the session gets the other scene and loses what they do in this one."}
        if count>1 {return fmt.tprintf("The %d collaborators of the session get the other scene and lose what they do in this one.",count)}
    }
    return ""
}
