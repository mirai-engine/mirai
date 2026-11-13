package editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:ui"

@(private)
documents_test_frame :: proc(s:^Session,input:ui.Input) -> ui.Frame {
    ctx:=s.gui.ctx
    s.gui.named_count=0
    ui.frame_begin(ctx,input)
    if ui.panel(ctx,ui.id(ctx,"documents_test_bar"),{width=ui.fixed(input.size.x),height=ui.fixed(ui.metric(ctx,"bar_height")),padding=0,gap=0}) {documents_build(s)}
    return ui.frame_end(ctx)
}

@(test)
document_tabs_hover_as_one_surface_and_close_independently :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    gui:=Editor_Ui{ctx=&ctx}
    document:Document
    edits:history.Edits
    session:=Session{gui=&gui,document=&document,edits=&edits}
    document_name(&document,"scenes/Active.scene","")
    append(&session.documents,Document_Tab{})
    other:Document_Tab
    document_name(&other.document,"scenes/Other.scene","")
    append(&session.documents,other)
    defer delete(session.documents)
    shape_fill :: proc(frame:ui.Frame,rect:ui.Rect) -> [4]f32 {
        for shape in frame.shapes {
            if shape.bounds==([4]f32{rect.x,rect.y,rect.w,rect.h}) {return shape.fill}
        }
        return {}
    }
    input:=ui.Input{size={460,100},pointer_absent=true}
    frame:ui.Frame
    for _ in 0..<3 {frame=documents_test_frame(&session,input)}
    active,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_look",1))
    idle,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_look",2))
    testing.expect(t,active.h==ui.metric(&ctx,"bar_height") && idle.y+idle.h<active.y+active.h,"the active document connects to the toolbar in front of the inactive tabs")
    surface,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_surface",2))
    testing.expect(t,surface.y<=active.y && surface.h==ui.metric(&ctx,"bar_height"),"an inactive tab takes clicks up to the edge of the window")
    idle_fill:=shape_fill(frame,idle)
    tab,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_tab",2))
    close,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_close",2))
    input.pointer_absent=false
    input.pointer=ui.rect_center(tab)
    frame=documents_test_frame(&session,input)
    hovered:=shape_fill(frame,idle)
    testing.expect(t,hovered!=idle_fill && hovered[3]>0,"hovering the title lights the entire tab surface")
    testing.expect_value(t,shape_fill(frame,close),[4]f32{})
    input.pointer=ui.rect_center(close)
    frame=documents_test_frame(&session,input)
    testing.expect_value(t,shape_fill(frame,idle),hovered)
    testing.expect(t,shape_fill(frame,close)[3]>0,"hovering the close control adds its circular highlight")
    input.pressed,input.down={.Left},{.Left}
    documents_test_frame(&session,input)
    testing.expect(t,.Document_Close in session.requests && .Document_Switch not_in session.requests)
    testing.expect_value(t,session.document_request,1)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
document_tabs_scroll_and_reveal_the_active_document_with_clipped_native_regions :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    gui:=Editor_Ui{ctx=&ctx,documents_reveal=true}
    document:Document
    edits:history.Edits
    session:=Session{gui=&gui,document=&document,edits=&edits,active_document=19}
    for index in 0..<20 {
        tab:Document_Tab
        document_name(&tab.document,fmt.tprintf("scenes/Document_%02d.scene",index),"")
        append(&session.documents,tab)
    }
    defer delete(session.documents)
    document=session.documents[19].document
    for _ in 0..<3 {documents_test_frame(&session,{size={420,100},pointer_absent=true})}
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    strip,found:=ui.widget_rect(&ctx,shell_id(&gui,"documents_strip"))
    testing.expect(t,found && gui.documents_scroll>0,"activating a clipped tab reveals it")
    last,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_tab",20))
    testing.expect(t,last.x>=strip.x-0.01 && last.x+last.w<=strip.x+strip.w+0.01)
    next,next_found:=ui.widget_rect(&ctx,shell_id(&gui,"documents_next"))
    previous,previous_found:=ui.widget_rect(&ctx,shell_id(&gui,"documents_previous"))
    testing.expect(t,next_found && previous_found && next.w>0 && previous.w>0)
    before:=gui.documents_scroll
    documents_test_frame(&session,{size={420,100},pointer=ui.rect_center(previous),pressed={.Left},down={.Left},clicks=1})
    testing.expect(t,gui.documents_scroll<before,"the previous arrow scrolls without switching documents")
    documents_test_frame(&session,{size={420,100},pointer=ui.rect_center(previous),released={.Left}})
    before=gui.documents_scroll
    documents_test_frame(&session,{size={420,100},pointer=ui.rect_center(strip),wheel={2,0}})
    testing.expect(t,gui.documents_scroll<before,"horizontal wheel input moves the document strip")
    gui.documents_reveal=true
    documents_test_frame(&session,{size={420,100},pointer_absent=true})
    gui.documents_scroll-=107
    documents_test_frame(&session,{size={420,100},pointer_absent=true})
    gui.rects.bar={0,0,420,ui.metric(&ctx,"bar_height")}
    regions:[NAMED_CAPACITY+1]platform.Window_Region
    count:=shell_regions(&session,regions[:])
    for region in regions[:count] {
        if region.kind!=.Client {continue}
        testing.expect(t,region.rect.x>=0 && region.rect.x+region.rect.w<=420.01,"native client regions stay inside the displayed bar")
    }
    testing.expect(t,gui.named_count<=12,"clipped documents do not consume native hit regions")
    partial,_:=ui.widget_rect(&ctx,shell_id(&gui,"document_close",15))
    clipped:=ui.rect_intersect(partial,strip)
    testing.expect(t,clipped.w>0 && clipped.w<partial.w,"the fixture includes a partially visible tab control")
    clipped_region:=false
    for region in regions[:count] {
        if region.kind==.Client && abs(region.rect.x-clipped.x)<0.01 && abs(region.rect.w-clipped.w)<0.01 {clipped_region=true;break}
    }
    testing.expect(t,clipped_region,"the native window receives only the visible part of a clipped tab control")
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

// A scene that waits for the question about the open one does not drop what
// was asked in the same frame.
@(test)
the_question_before_opening_a_scene_keeps_the_other_requests_of_the_frame :: proc(t:^testing.T) {
    gui:Editor_Ui
    document:Document
    edits:history.Edits
    // An agent at work in the open scene is asked about before it changes.
    ai:=new(Ai);defer free(ai)
    ai.task_count=1
    s:=Session{gui=&gui,document=&document,edits=&edits,ai=ai}
    append(&s.documents,Document_Tab{})
    defer delete(s.documents)
    s.open_length=copy(s.open_path[:],"scenes/other.scene")
    s.requests={.Open,.Quit}
    requests_run(&s)
    testing.expect(t,gui.modal==.Confirm && gui.pending==.Open_Scene)
    testing.expect(t,s.quit)
}

// Escape closes a dialog as its Cancel does: nothing of what it asked about stays.
@(test)
escape_closes_a_dialog_with_what_it_asks_about :: proc(t:^testing.T) {
    gui:Editor_Ui
    viewport:Viewport
    selection:history.Selection
    edits:history.Edits
    s:=Session{gui=&gui,edits=&edits,selection=&selection,viewport=&viewport}
    for modal in ([]Modal{.Confirm,.Delete_Asset,.Git_Discard}) {
        gui.modal=modal
        if modal==.Confirm {
            gui.pending=.New
            escape_run(&s,&gui,&viewport,&selection)
            testing.expect(t,gui.modal==.None && gui.pending==.None && .New not_in s.requests,"what the question waited for does not go on")
            continue
        }
        gui.delete_asset={1,2}
        base.text_set(gui.discard_path[:],"scenes/a.scene")
        escape_run(&s,&gui,&viewport,&selection)
        testing.expectf(t,gui.modal==.None && gui.delete_asset=={} && base.text_get(gui.discard_path[:])=="","%v",modal)
    }
}

// Whether the scene of a file has an entity named name.
@(private="file")
documents_test_has :: proc(f:^Prefab_Fixture,file,name:string) -> bool {
    loaded:asset.Scene
    if asset.scene_load(&loaded,&f.assets.types,file,context.temp_allocator)!=.None {return false}
    defer asset.scene_destroy(&loaded)
    for &held in asset.scene_names(&loaded) {
        if base.text_get(held[:])==name {return true}
    }
    return false
}

// A document without a file writes nothing; once it has one, every step that
// ends reaches it, undo too, and an open gesture waits for its end.
@(test)
the_steps_of_a_document_reach_its_file_once_it_has_one :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"document-flush")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    entity_create(s,{name="Rock",named=true})
    core.world_settle(w)
    prefab_fixture_step(f)
    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,asset.registry_scan(&f.assets.registry),asset.Error.None)
    testing.expect(t,len(f.assets.registry.files)==0 && document_file(s.document)=="","no file is made for it")

    testing.expect_value(t,document_file_give(s,"level.scene"),Document_Error.None)
    file:=scene_file(s,"level.scene")
    testing.expect(t,!os.exists(file),"the file is written by the next flush")
    testing.expect(t,files_flush(s,true) && documents_test_has(f,file,"Rock"))

    tree:=entity_create(s,{name="Tree",named=true})
    core.world_settle(w)
    prefab_fixture_step(f)
    testing.expect(t,files_flush(s,true) && documents_test_has(f,file,"Tree"))
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,files_flush(s,true) && !documents_test_has(f,file,"Tree") && documents_test_has(f,file,"Rock"))
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect(t,files_flush(s,true) && documents_test_has(f,file,"Tree"))

    tree=api_entity(w,api_entity_id(w,tree))
    opened,ready:=edit_open(s,"Rename")
    testing.expect(t,ready && entity_rename(s,tree,"Oak"))
    testing.expect(t,!files_flush(s,true) && !documents_test_has(f,file,"Oak"),"an open gesture is no step yet")
    edit_close(s,opened)
    prefab_fixture_step(f)
    testing.expect(t,files_flush(s,true) && documents_test_has(f,file,"Oak"))
}

// The file of the document changed outside the editor: the next flush reads
// it again, with a new history, and writes nothing over it.
@(test)
a_document_reads_its_file_again_when_it_changed_outside :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"document-follow")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    rock:=entity_create(s,{name="Rock",named=true})
    core.world_settle(w)
    prefab_fixture_step(f)
    id:=api_entity_id(w,rock)
    if !testing.expect_value(t,test_document_write(s,"level.scene"),Document_Error.None) {return}
    file:=document_file(s.document)
    testing.expect(t,len(f.edits.steps)>0)

    outside:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&outside,&f.assets.types,file),asset.Error.None) {return}
    asset.scene_entity_rename(&outside,id,"Boulder")
    testing.expect_value(t,asset.scene_save(&outside,file),asset.Error.None)
    asset.scene_destroy(&outside)
    assets_wrote(s,file)

    testing.expect(t,files_flush(s,true))
    testing.expect_value(t,entity_name(w,api_entity(w,id)),"Boulder")
    testing.expect_value(t,len(f.edits.steps),0)
    testing.expect(t,documents_test_has(f,file,"Boulder"))
}

// A scene asked to open shows its tab loading on the frame after the request,
// before it is read, and until a frame drew it resident.
@(test)
the_tab_of_a_scene_that_opens_loads_from_the_first_frame_until_it_is_resident :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"document-loading")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    entity_create(s,{name="Rock",named=true})
    core.world_settle(edited_world(s))
    prefab_fixture_step(f)
    if !testing.expect_value(t,test_document_write(s,"level.scene"),Document_Error.None) {return}
    file:=document_file(s.document)
    scene_new(s)
    testing.expect_value(t,document_loading_tab(s),-1)
    file_open_path(s,"level.scene")
    requests_run(s)
    defer documents_free(s)
    testing.expect(t,document_file(s.document)!=file && .Open in s.requests,"the scene is read at the end of the next frame")
    testing.expect_value(t,document_loading_tab(s),s.active_document)
    requests_run(s)
    testing.expect(t,document_file(s.document)==file && .Open not_in s.requests)
    testing.expect_value(t,document_loading_tab(s),s.active_document)
    host.load_profile_frame(&f.app,true)
    testing.expect_value(t,document_loading_tab(s),-1)
}
