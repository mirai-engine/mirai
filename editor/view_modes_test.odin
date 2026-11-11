package editor

import "core:testing"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:ui"

@(private="file")
View_Modes_Test_World :: struct {using world:core.Test_World}

@(private="file")
view_modes_test_record :: proc(s:^gpu.Stage_Pass,user:rawptr) {}

// The menu and the API list the modes of the core, then those the plugins
// declared in the frame; a name finds its mode whatever its case, and the
// viewport shows the mode it names until nothing declares it, when it goes
// back to Lit. A Play shows the lit image.
@(test)
view_modes_list_the_core_then_the_plugins_and_go_back_to_lit_when_undeclared :: proc(t:^testing.T) {
    world:View_Modes_Test_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    modes:View_Modes
    defer view_modes_free(&modes)
    viewport:Viewport
    document:Document
    app:host.App
    s:=Session{info=core.test_world_info(&world),edit_world=&world,app=&app,viewport=&viewport,document=&document,view_modes=&modes}
    marker:int

    testing.expect(t,view_mode_declare(&s,{name="nested",label="Nested views",group="Advanced",icon=.Split,record=view_modes_test_record,user=&marker}))
    testing.expect(t,!view_mode_declare(&s,{name="Nested",record=view_modes_test_record}),"a name is declared once")
    testing.expect(t,!view_mode_declare(&s,{name="lit",record=view_modes_test_record}),"the core keeps its names")
    testing.expect(t,!view_mode_declare(&s,{name="empty"}),"a mode has a pass")
    testing.expect(t,view_mode_declare(&s,{name="heat",record=view_modes_test_record,reason="Nothing is hot"}))
    testing.expect(t,view_mode_declare(&s,{name="collision.Walls",label="Walls",title="Collision: Walls",group="Advanced",submenu="Collision",record=view_modes_test_record}))

    buffer:[VIEW_MODE_ENTRY_CAPACITY]View_Mode_Entry
    entries:=view_mode_entries(nil,&modes,shown_world(&s),buffer[:])
    // The core, then the three of the plugins.
    testing.expect_value(t,len(entries),len(VIEW_MODES)+3)
    testing.expect(t,entries[0].name=="lit" && entries[0].group=="Shading" && !entries[0].available && entries[0].reason!="","without a GPU no image can be shown")
    nested,heat,walls:=entries[len(VIEW_MODES)],entries[len(VIEW_MODES)+1],entries[len(VIEW_MODES)+2]
    testing.expect(t,nested.kind==.Plugin && nested.available && nested.group=="Advanced" && nested.label=="Nested views")
    testing.expect(t,!heat.available && heat.reason=="Nothing is hot" && heat.group=="Plugins" && heat.label=="heat")
    testing.expect(t,walls.submenu=="Collision" && walls.label=="Walls" && walls.title=="Collision: Walls")

    found:bool
    entry:View_Mode_Entry
    entry,found=view_mode_resolve(nil,&modes,shown_world(&s),"BASE_COLOR")
    testing.expect(t,found && entry.kind==.Render && entry.render==.Albedo)
    entry,found=view_mode_resolve(nil,&modes,shown_world(&s),"COLLISION.walls")
    testing.expect(t,found && entry.name=="collision.Walls")
    entry,found=view_mode_resolve(nil,&modes,shown_world(&s),"collision.Camera")
    testing.expect(t,!found,"a mode nothing declared is none")

    // The viewport shows what it names, in this frame.
    base.text_set(viewport.view_mode[:],"nested")
    view_mode_render(&s,&viewport,&modes,&app)
    testing.expect(t,app.inspection.record==view_modes_test_record && app.inspection.user==&marker)
    app.inspection={}
    base.text_set(viewport.view_mode[:],"depth")
    view_mode_render(&s,&viewport,&modes,&app)
    testing.expect_value(t,app.inspection.mode,gpu.Debug_View.Depth)
    app.inspection={}
    s.mode=.Play
    view_mode_render(&s,&viewport,&modes,&app)
    testing.expect_value(t,app.inspection,gpu.View_Inspection{})
    testing.expect_value(t,view_mode_current(&viewport),"depth")
    s.mode=.Edit
    // A frame whose plugins no longer declare the mode shows Lit.
    base.text_set(viewport.view_mode[:],"nested")
    view_modes_begin(&modes)
    view_mode_render(&s,&viewport,&modes,&app)
    testing.expect_value(t,view_mode_current(&viewport),"lit")
    testing.expect_value(t,app.inspection,gpu.View_Inspection{})
}

@(private="file")
view_modes_test_frame :: proc(t:^testing.T,s:^Session,input:ui.Input) {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    view_mode_build(s)
    output:=ui.frame_end(ctx)
    testing.expect(t,!output.overflow)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(private="file")
view_modes_test_click :: proc(t:^testing.T,s:^Session,id:ui.Id) {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    if !testing.expect(t,found) {return}
    for phase in 0..<3 {
        input:=ui.Input{size={1200,800},pointer=ui.rect_center(rect),dt=1.0/60}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        view_modes_test_frame(t,s,input)
    }
}


// The menu has a header for each group, a row for each mode of a group and a
// submenu for each family, whose modes show when it opens; Advanced folds
// into a submenu of its own. Choosing a mode, or a family,
// which is its first mode, shows it in the viewport and closes the menu.
@(test)
view_mode_menu_groups_its_modes_under_headers_and_families_in_submenus :: proc(t:^testing.T) {
    world:View_Modes_Test_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    modes:View_Modes
    defer view_modes_free(&modes)
    viewport:Viewport
    document:Document
    app:host.App
    s:=Session{info=core.test_world_info(&world),edit_world=&world,app=&app,gui=&g,viewport=&viewport,document=&document,view_modes=&modes}
    testing.expect(t,view_mode_declare(&s,{name="nested",label="Nested views",group="Advanced",icon=.Split,record=view_modes_test_record}))
    // As physics declares its Collision modes: the family is its first mode.
    testing.expect(t,view_mode_declare(&s,{name="collision",label="All layers",title="Collision",group="Advanced",submenu="Collision",icon=.Collider,record=view_modes_test_record}))
    testing.expect(t,view_mode_declare(&s,{name="collision.Walls",label="Walls",title="Collision: Walls",group="Advanced",submenu="Collision",icon=.Layers,record=view_modes_test_record}))
    for _ in 0..<2 {view_modes_test_frame(t,&s,{size={1200,800},pointer_absent=true,dt=1.0/60})}
    popup:=shell_id(&g,"view_mode_popup")
    view_modes_test_click(t,&s,shell_id(&g,"view_mode"))
    testing.expect(t,ui.popup_is_open(&ctx,popup))
    view_modes_test_frame(t,&s,{size={1200,800},pointer_absent=true,dt=1.0/60})
    shown :: proc(ctx:^ui.Context,popup:ui.Id,name:string,index:=0) -> bool {
        _,found:=ui.widget_rect(ctx,ui.id_derive(ctx,popup,name,index))
        return found
    }
    for name in ([]string{"lit","lighting","shadows"}) {testing.expectf(t,shown(&ctx,popup,name),"%s is a row of its group",name)}
    for family in ([]string{"Material","Direct","Reflections","Indirect"}) {testing.expectf(t,shown(&ctx,popup,family,1),"%s is a submenu",family)}
    testing.expect(t,shown(&ctx,popup,"Advanced",2),"Advanced is folded into a submenu")
    for name in ([]string{"base_color","depth","nested","indirect_history"}) {testing.expectf(t,!shown(&ctx,popup,name),"%s is in a submenu",name)}
    // Pointing at a folded group opens it, with its rows and families.
    point :: proc(t:^testing.T,s:^Session,popup:ui.Id,name:string,index:int) {
        rect,_:=ui.widget_rect(s.gui.ctx,ui.id_derive(s.gui.ctx,popup,name,index))
        for _ in 0..<2 {view_modes_test_frame(t,s,{size={1200,800},pointer=ui.rect_center(rect),dt=1.0/60})}
    }
    point(t,&s,popup,"Advanced",2)
    testing.expect(t,shown(&ctx,popup,"depth") && shown(&ctx,popup,"nested") && shown(&ctx,popup,"Collision",1))
    point(t,&s,popup,"Collision",1)
    testing.expect(t,shown(&ctx,popup,"collision") && shown(&ctx,popup,"collision.Walls"))
    view_modes_test_click(t,&s,ui.id_derive(&ctx,popup,"collision.Walls"))
    testing.expect_value(t,view_mode_current(&viewport),"collision.Walls")
    testing.expect(t,!ui.popup_is_open(&ctx,popup))
    // A click on a family shows its first mode, which opening it on the way does not stop.
    view_modes_test_click(t,&s,shell_id(&g,"view_mode"))
    point(t,&s,popup,"Advanced",2)
    view_modes_test_click(t,&s,ui.id_derive(&ctx,popup,"Collision",1))
    testing.expect_value(t,view_mode_current(&viewport),"collision")
    testing.expect(t,!ui.popup_is_open(&ctx,popup))
    // The studio light is an option of the view beside its modes, not one of them.
    view_modes_test_click(t,&s,shell_id(&g,"view_mode"))
    view_modes_test_click(t,&s,ui.id_derive(&ctx,popup,"studio_light"))
    testing.expect(t,viewport.studio_light)
    testing.expect_value(t,view_mode_current(&viewport),"collision")
}
