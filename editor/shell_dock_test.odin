package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:ui"

@(test)
the_rail_and_a_docked_details_take_their_edges_and_the_left_panel_does_not_move_the_scene :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}));defer ui.context_destroy(&ctx)
    ui.frame_begin(&ctx,{size={1600,900},pointer_absent=true})
    _=ui.frame_end(&ctx)
    g:=Editor_Ui{ctx=&ctx,layout=LAYOUT_DEFAULT}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    l:=&g.layout
    left,right:=dock_widths(&s)
    testing.expect(t,left==RAIL_WIDTH && right==0,"the view is the same with the left panel, and Details floats over it")
    testing.expect_value(t,dock_scene_left(&s),RAIL_WIDTH+LEFT_WIDTH.max-LEFT_UNDER)
    l.right_mode=.Docked
    _,right=dock_widths(&s)
    testing.expect(t,right==width_of(RIGHT_WIDTH,1600),"Docked as the global mode docks a scene")
    l.right_modes[.Scene]=.Floating
    _,right=dock_widths(&s)
    testing.expect(t,right==0,"a type of document keeps its own choice over the global mode")
    testing.expect_value(t,panel_mode(l,.Prefab),Panel_Mode.Docked)
    // A dragged width holds between the narrowest and 40 % of the window.
    l.right_modes[.Scene]=.Docked
    l.right_width=60
    _,right=dock_widths(&s)
    testing.expect_value(t,right,DOCK_MIN)
    l.right_width=5000
    _,right=dock_widths(&s)
    testing.expect_value(t,right,f32(640))
    l.left_open=false
    left,_=dock_widths(&s)
    testing.expect_value(t,left,RAIL_WIDTH)
    testing.expect_value(t,dock_scene_left(&s),RAIL_WIDTH)
    // In a Play only the rail stays: the game takes the rest.
    l.left_open=true
    s.mode=.Play
    left,right=dock_widths(&s)
    testing.expect(t,left==RAIL_WIDTH && right==0)
    testing.expect_value(t,dock_scene_left(&s),RAIL_WIDTH)
}

@(test)
an_asset_document_fills_the_window_from_under_the_left_panel :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}));defer ui.context_destroy(&ctx)
    ui.frame_begin(&ctx,{size={1600,900},pointer_absent=true})
    defer ui.frame_end(&ctx)
    g:=Editor_Ui{ctx=&ctx,layout=LAYOUT_DEFAULT}
    s:=Session{gui=&g}
    bars:=ui.metric(&ctx,"bar_height")+toolbar_height(&g)
    g.rects.left={RAIL_WIDTH,bars,LEFT_WIDTH.max,900-bars}
    x0:=RAIL_WIDTH+LEFT_WIDTH.max-LEFT_UNDER
    testing.expect_value(t,asset_workspace_rect(&g),ui.Rect{x0,bars,1600-x0,900-bars})
    testing.expect_value(t,asset_workspace(&g).padding,[4]f32{LEFT_UNDER,0,0,0})
    document,details,_:=asset_workspace_details(&s)
    testing.expect(t,document.width.value==1600-x0 && document.backdrop,"Details floats over the document, under the left panel")
    testing.expect_value(t,details.offset,[2]f32{-DETAILS_MARGIN,bars+DETAILS_MARGIN})
    // What the bottom panel takes stays free of what the document shows.
    g.rects.bottom={400,600,1000,292}
    testing.expect_value(t,asset_workspace(&g).padding[3],f32(300))
    g.rects.bottom={}
    g.layout.right_mode=.Docked
    document,details,_=asset_workspace_details(&s)
    width:=dock_right_width(&s)
    testing.expect_value(t,document.width.value,1600-x0-width)
    testing.expect_value(t,details.offset,[2]f32{0,bars})
    // With the panel folded only the rail is at the left, and nothing runs under it.
    g.rects.left={0,bars,RAIL_WIDTH,900-bars}
    testing.expect_value(t,asset_workspace_rect(&g).x,RAIL_WIDTH)
    testing.expect_value(t,asset_workspace_under(&g),f32(0))
}

@(test)
the_editor_settings_list_the_modes_of_the_panels_after_the_project :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx,layout=LAYOUT_DEFAULT}
    info:core.World_Info
    s:=Session{gui=&g,info=&info}
    categories:=settings_categories(&s)
    testing.expect(t,len(categories)>0 && categories[0].storage==SETTINGS_CATEGORY_EDITOR && categories[0].sections[0]=="Panels")
    s.settings_dialog.search_length=copy(s.settings_dialog.search[:],"docked")
    categories=settings_categories(&s)
    testing.expect(t,len(categories)==1 && categories[0].storage==SETTINGS_CATEGORY_EDITOR,"the search finds the panels by their modes")
    s.settings_dialog.search_length=0
    s.settings_layer,s.has_project=.Project,true
    categories=settings_categories(&s)
    project_at,editor_at:=-1,-1
    for c,i in categories {
        if c.storage==SETTINGS_CATEGORY_PROJECT {project_at=i}
        if c.storage==SETTINGS_CATEGORY_EDITOR {editor_at=i}
    }
    testing.expect(t,project_at>=0 && editor_at>project_at,"the editor comes after the project")
    s.has_project=false
    s.settings_plugins.count=1
    s.settings_dialog.search_length=copy(s.settings_dialog.search[:],"git")
    categories=settings_categories(&s)
    testing.expect(t,len(categories)==1 && categories[0].storage==SETTINGS_CATEGORY_PLUGINS,"the search finds the plugins from Git")
}

@(test)
each_type_of_document_has_its_tabs_of_the_left_panel :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx,layout=LAYOUT_DEFAULT}
    m:=new(Ai);defer free(m)
    s:=Session{gui=&g,ai=m}
    testing.expect_value(t,library_tabs(&s),Library_Tabs{.Editor,.Content,.Hierarchy,.World,.Ai,.Git})
    g.layout.library_tab=.Hierarchy
    testing.expect_value(t,library_tab_shown(&s),Library_Tab.Hierarchy)
    // An asset document in front has no Hierarchy of the scene: the first tab it has shows.
    append(&s.asset_documents,Asset_Document{kind=asset.KIND_MATERIAL});defer delete(s.asset_documents)
    s.asset_shown=1
    testing.expect_value(t,library_tabs(&s),Library_Tabs{.Content,.Ai,.Git})
    testing.expect_value(t,library_tab_shown(&s),Library_Tab.Content)
    testing.expect_value(t,g.layout.library_tab,Library_Tab.Hierarchy)
    g.layout.library_tab=.Git
    testing.expect_value(t,library_tab_shown(&s),Library_Tab.Git)
}
