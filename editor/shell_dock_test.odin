package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:ui"

@(test)
the_rail_and_a_docked_details_take_their_edges_and_the_left_panel_does_not_move_the_scene :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
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
    // In a Play the panels are not there: the game takes the window.
    l.left_open=true
    s.mode=.Play
    left,right=dock_widths(&s)
    testing.expect(t,left==0 && right==0)
}

@(test)
the_editor_settings_list_the_modes_of_the_panels_first :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx,layout=LAYOUT_DEFAULT}
    info:core.World_Info
    s:=Session{gui=&g,info=&info}
    categories:=settings_categories(&s)
    testing.expect(t,len(categories)>0 && categories[0].storage==SETTINGS_CATEGORY_EDITOR && categories[0].sections[0]=="Panels")
    s.settings_dialog.search_length=copy(s.settings_dialog.search[:],"docked")
    categories=settings_categories(&s)
    testing.expect(t,len(categories)==1 && categories[0].storage==SETTINGS_CATEGORY_EDITOR,"the search finds the panels by their modes")
    s.settings_layer=.Project
    s.settings_plugins.count=1
    s.settings_dialog.search_length=copy(s.settings_dialog.search[:],"git")
    categories=settings_categories(&s)
    testing.expect(t,len(categories)==1 && categories[0].storage==SETTINGS_CATEGORY_PLUGINS,"the search finds the plugins from Git")
}

@(test)
each_type_of_document_has_its_tabs_of_the_left_panel :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
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
