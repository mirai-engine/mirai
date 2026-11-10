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
    recovery:Recovery_Chain,
    quit_approved:bool,
}

documents_ensure :: proc(s:^Session) {
    if len(s.documents)==0 {append(&s.documents,Document_Tab{})}
}

// Swaps through memory: at -o:speed with LLVM 20 (the Odin of Linux and macOS) `a^,b^=b^,a^` of
// a value with an array of more than 1024 elements after a field writes the second copy from
// memory the first overwrote (odin-lang/Odin#8113).
swap_values :: proc(a,b:^$T) {slice.ptr_swap_non_overlapping(a,b,size_of(T))}

document_tab_exchange :: proc(s:^Session,tab:^Document_Tab) {
    recovery_park(s)
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
    swap_values(&s.recovery.chain,&tab.recovery)
}

document_tab_free :: proc(s:^Session,tab:^Document_Tab) {
    if tab.world==nil {return}
    ai_document_closed(s,tab.world)
    recovery_chain_close(s,&tab.recovery,false)
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
    if s.picker!=nil {picker_clear(s.picker)}
    if document_is_prefab(s) && !document_dirty(s) {
        assets_rescan(s)
        if file,found:=asset.registry_find(&s.app.assets.registry,s.document.id);found && s.document.source_stamp!=([2]i64{file.size,file.time}) {
            selected:=selected_ids(s)
            if scene_open(s,document_file(s.document))==.None {select_ids(s,selected)}
        }
    }
    if prefab_linked(s) {
        for state in prefab_instances(s) {
            if state.stale {prefab_refresh(s,{});break}
        }
    }
    return true
}

// Opens a scene or a prefab, or brings its tab. One scene is open at a time,
// beside any number of prefabs: another scene takes the tab of the one open.
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
    if scene:=document_scene_tab(s);scene>=0 && !path_is_prefab(path) {
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
        if d.previous==nil || d.previous.doc.kind!=asset.KIND_PREFAB {return index}
    }
    return -1
}

path_is_prefab :: proc(path:string) -> bool {return strings.has_suffix(path,".prefab")}

// Others lose what they do when the scene changes: the guests of the session,
// or this end its place in it, and the agents at work.
scene_switch_interrupts :: proc(s:^Session) -> bool {
    return collab_active(s) || ai_working_count(s)>0
}

document_close :: proc(s:^Session,index:int) {
    if !document_activate(s,index) {return}
    assets:=document_closing_assets(s)
    if document_dirty(s) || len(assets)>0 {confirm_open(s,.Close,assets);return}
    document_close_active(s)
}

// The unsaved assets the active document uses that no other open document
// does: closing or replacing it asks about them, in the temporary allocator.
document_closing_assets :: proc(s:^Session) -> []string {
    used:=make([dynamic]string,context.temp_allocator)
    world_unsaved_assets(s,edited_world(s),&used)
    if len(used)==0 {return nil}
    other:=make([dynamic]string,context.temp_allocator)
    for &tab,index in s.documents {
        if index==s.active_document || tab.world==nil {continue}
        world_unsaved_assets(s,core.world_ref(tab.world,s.info),&other)
        for i:=len(used)-1;i>=0;i-=1 {
            for path in other {
                if path==used[i] {unordered_remove(&used,i);break}
            }
        }
    }
    return used[:]
}

// Whether a document shows assets with unsaved changes: its tab is marked.
// Asked again only when the unsaved files or the history of the document change.
document_uses_unsaved :: proc(s:^Session,index:int) -> bool {
    if len(assets_unsaved(s))==0 {return false}
    active:=index==s.active_document
    if !active && (index>=len(s.documents) || s.documents[index].world==nil) {return false}
    world:=active?s.edit_world:s.documents[index].world
    key:=[2]u64{s.app.assets.registry.revision,history.edits_state(active?s.edits:&s.documents[index].edits)}
    g:=s.gui
    for &known in g.unsaved_uses {
        if known.world==world && known.key==key {return known.uses}
    }
    used:=make([dynamic]string,context.temp_allocator)
    world_unsaved_assets(s,core.world_ref(world,s.info),&used)
    for &known in g.unsaved_uses {
        if known.world==world {
            known.key,known.uses=key,len(used)>0
            return known.uses
        }
    }
    append(&g.unsaved_uses,Unsaved_Use{world,key,len(used)>0})
    return len(used)>0
}

document_close_active :: proc(s:^Session) {
    if len(s.documents)<=1 {scene_new(s);return}
    index:=s.active_document
    document_activate(s,index>0?index-1:1)
    recovery_chain_close(s,&s.documents[index].recovery,true)
    document_tab_free(s,&s.documents[index])
    for i in index..<len(s.documents)-1 {s.documents[i]=s.documents[i+1]}
    resize(&s.documents,len(s.documents)-1)
    if s.active_document>index {s.active_document-=1}
}

documents_dirty :: proc(s:^Session) -> bool {
    if document_dirty(s) {return true}
    for index in 0..<len(s.documents) {
        if document_tab_dirty(s,index) {return true}
    }
    return false
}

// Whether the document of a tab has changes its file does not.
document_tab_dirty :: proc(s:^Session,index:int) -> bool {
    if index==s.active_document {return document_dirty(s)}
    tab:=&s.documents[index]
    return tab.document.unsaved || history.edits_scene_state(&tab.edits)!=tab.document.saved
}

documents_quit_next :: proc(s:^Session) {
    documents_ensure(s)
    for &tab,index in s.documents {
        if tab.quit_approved {continue}
        d:=index==s.active_document?s.document:&tab.document
        e:=index==s.active_document?s.edits:&tab.edits
        // Agents work only on the active document: quitting asks while they do.
        if !d.unsaved && history.edits_scene_state(e)==d.saved && (index!=s.active_document || ai_working_count(s)==0) {continue}
        // The first question lists every unsaved asset too, so none is asked twice.
        document_activate(s,index)
        confirm_open(s,.Quit,assets_unsaved_paths(s))
        return
    }
    // With no document to ask about: every asset still unsaved.
    if unsaved:=assets_unsaved_paths(s);len(unsaved)>0 {
        confirm_open(s,.Quit,unsaved)
        return
    }
    if !projects_next_start(s) {return}
    s.quit=true
}

// A tab of the strip: those of the scenes first, then those of the assets.
@(private)
Strip_Tab :: struct {
    label:string,
    icon:ui.Icon,
    dirty,active:bool,
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
        tab.dirty,tab.active=asset_document_dirty(s,d),s.asset_shown==tab.asset+1
        return
    }
    tab.asset=-1
    d,e:=s.document,s.edits
    if index!=s.active_document && index<len(s.documents) {d,e=&s.documents[index].document,&s.documents[index].edits}
    tab.label=document_title(d)
    tab.icon=d.previous!=nil && d.previous.doc.kind==asset.KIND_PREFAB?.Prefab:.Scene
    tab.dirty=d.unsaved || history.edits_scene_state(e)!=d.saved || document_uses_unsaved(s,index)
    tab.active=index==s.active_document && !scene_covered(s)
    return
}

@(private)
document_tab_width :: proc(s:^Session,tab:Strip_Tab,room:f32) -> f32 {
    width:=ui.text_width(&s.gui.ctx.font,tab.label,s.gui.ctx.theme.font)+54
    if tab.dirty {width+=ui.text_width(&s.gui.ctx.font," •",s.gui.ctx.theme.font)}
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
        g.documents_scroll-=delta*ctx.theme.wheel_step
    }
    g.documents_scroll=clamp(g.documents_scroll,0,limit)
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.GROW,gap=3,align_y=.End,track=true}) {
        if overflow {
            previous:=shell_id(g,"documents_previous")
            named_add(g,previous)
            if ui.button(ctx,previous,{label="←",tip="Previous documents",style=.Ghost,width=22,height=28,size=ctx.theme.font,disabled=g.documents_scroll<=0}).clicked {
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
                if tab.dirty {label=ui.text_commit(ctx,fmt.bprintf(ui.text_reserve(ctx,len(label)+4),"%s •",label))}
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
                fill:=active?ctx.theme.panel:ctx.theme.bar_bottom
                if hot {fill=active?ui.color_shade(fill,1.15):ctx.theme.field_hover}
                text_color:=active || hot?ctx.theme.text:ctx.theme.text_muted
                appearance:=ui.Node_Style{text={size=ctx.theme.font,color=text_color}}
                // The whole height of the bar takes its clicks, up to the edge of the window.
                if ui.box(ctx,{id=surface_id,width=ui.fixed(width),height=ui.fixed(ctx.theme.bar_height),align_y=.Center}) {
                    if ui.box(ctx,{id=shell_id(g,"document_look",index+1),track=true,width=ui.fixed(width),height=ui.fixed(active?ctx.theme.bar_height:ctx.theme.control),gap=1,padding={2,0,2,0},align_y=.Center,fill=fill,radius=4}) {
                        if active {
                            if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(4),fill=fill,float={to=.Parent,anchor=.Bottom_Left,pivot=.Bottom_Left,layer=ui.LAYER_BAR}}) {}
                        }
                        if ui.button(ctx,tab_id,{label=label,icon=tab.icon,width=-1,height=ctx.theme.control,size=ctx.theme.font,icon_size=12,use_appearance=true,appearance=appearance}).clicked || surface.clicked {
                            switch {
                            case tab.asset>=0: asset_document_request(s,tab.asset)
                            case:              s.document_request=index;s.requests+={.Document_Switch}
                            }
                        }
                        close:=ui.Node_Style{fill=ctx.hot==close_id?ui.color_alpha(ctx.theme.text,65):ui.Color{},radius=12,text={color=text_color}}
                        if ui.button(ctx,close_id,{icon=.Cross,width=19,height=19,icon_size=10,icon_color=text_color,use_appearance=true,appearance=close}).clicked {
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
            if ui.button(ctx,next,{label="→",tip="Next documents",style=.Ghost,width=22,height=28,size=ctx.theme.font,disabled=g.documents_scroll>=limit}).clicked {
                g.documents_scroll=min(g.documents_scroll+max(strip_width*0.6,90),limit)
            }
        }
    }
}

document_is_prefab :: proc(s:^Session) -> bool {
    return s.document!=nil && s.document.previous!=nil && s.document.previous.doc.kind==asset.KIND_PREFAB
}

document_root :: proc(s:^Session,w:core.World_Ref) -> core.Entity {
    if !document_is_prefab(s) {return core.NONE}
    return core.entity_of(core.world_entities(w),s.document.previous.info.root)
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
