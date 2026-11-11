package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import "mirai:ui"

@(test_world)
Shell_Test_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    graphics:erender.Graphics_Settings,
}

shell_test_frame :: proc(s:^Session,input:ui.Input) -> ui.Frame {
    ui.frame_begin(s.gui.ctx,input)
    shell_build(s,shown_world(s))
    return ui.frame_end(s.gui.ctx)
}

shell_test_click :: proc(t:^testing.T,s:^Session,id:ui.Id) {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    testing.expect(t,found)
    if !found {return}
    for phase in 0..<3 {
        input:=ui.Input{size={1440,900},pointer=ui.rect_center(rect)}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        frame:=shell_test_frame(s,input)
        testing.expect(t,!frame.overflow && s.gui.ctx.stats.layout_errors==0)
    }
}

@(test)
the_editor_shell_keeps_the_compact_create_and_details_panels :: proc(t:^testing.T) {
    world:Shell_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    selected:=core.create(&world.entities)
    core.add(&world.names,selected,core.name_make("Object"))
    core.add(&world.transforms,selected,core.TRANSFORM_IDENTITY)
    test_world_settle(&world)
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx,layout={left_open=true,right_open=true}}
    app:host.App
    viewport:Viewport
    viewport_init(&viewport)
    defer viewport_free(&viewport)
    selection:history.Selection
    inspector:Inspector
    edits:history.Edits
    document:Document
    build:Build_State
    ai:=new(Ai)
    defer free(ai)
    finder:Finder
    graphics:Graphics
    materials:Materials
    content:Content
    session:=Session{info=test_world_info(&world),edit_world=&world,headless=true,app=&app,gui=&g,viewport=&viewport,selection=&selection,inspector=&inspector,edits=&edits,document=&document,build=&build,ai=ai,finder=&finder,graphics=&graphics,materials=&materials,content=&content}
    defer delete(selection.entities)
    defer core.value_free(&inspector,type_info_of(Inspector))
    defer core.value_free(&content,type_info_of(Content))
    history.edits_reset(&edits,edited_world(&session))
    defer history.edits_free(&edits)
    commands:Api
    if !test_commands_open(t,&session,&commands) {return}
    defer test_commands_close(&session)
    history.selection_set(&selection,{selected})
    for size in ([2][2]f32{{1440,900},{800,420}}) {
        for _ in 0..<3 {
            ui.frame_begin(&ctx,{size=size,pointer_absent=true,dt=1.0/60})
            shell_build(&session,shown_world(&session))
            frame:=ui.frame_end(&ctx)
            testing.expect(t,!frame.overflow)
            testing.expect_value(t,ctx.stats.layout_errors,u32(0))
        }
        left,found:=ui.widget_rect(&ctx,shell_id(&g,"left"))
        testing.expect(t,found)
        testing.expect_value(t,left.x,RAIL_WIDTH)
        testing.expect_value(t,left.y,ui.metric(&ctx,"bar_height")+DOCUMENT_TOOLBAR_HEIGHT)
        testing.expect_value(t,left.w,LEFT_WIDTH.max)
        testing.expect_value(t,left.h,size.y-(ui.metric(&ctx,"bar_height")+DOCUMENT_TOOLBAR_HEIGHT))
        rail,rail_shown:=ui.widget_rect(&ctx,shell_id(&g,"rail"))
        testing.expect(t,rail_shown && rail.x==0 && rail.y==left.y && rail.w==RAIL_WIDTH && rail.h==left.h)
        toolbar,toolbar_shown:=ui.widget_rect(&ctx,shell_id(&g,"document_toolbar"))
        testing.expect(t,toolbar_shown && toolbar.y==ui.metric(&ctx,"bar_height") && toolbar.h==DOCUMENT_TOOLBAR_HEIGHT && toolbar.w==size.x)
        _,document_shown:=ui.widget_rect(&ctx,shell_id(&g,"document_tab",1))
        testing.expect(t,document_shown)
        right,shown:=ui.widget_rect(&ctx,shell_id(&g,"right"))
        testing.expect(t,shown && abs(right.x+right.w-(size.x-8))<0.01 && right.y==ui.metric(&ctx,"bar_height")+DOCUMENT_TOOLBAR_HEIGHT+8)
        testing.expect_value(t,right.w,RIGHT_WIDTH.max)
        testing.expect(t,right.y+right.h<=size.y-16+0.01)
        pick,_:=ui.widget_rect(&ctx,ui.id_derive(&ctx,shell_id(&g,"right"),"parent_pick"))
        testing.expect_value(t,pick.w,HIERARCHY_TILE)
        testing.expect_value(t,pick.h,HIERARCHY_TILE)
        _,create_menu:=ui.widget_rect(&ctx,shell_id(&g,"menu",3))
        _,play_menu:=ui.widget_rect(&ctx,shell_id(&g,"menu",5))
        testing.expect(t,!create_menu && !play_menu)
    }
    for _ in 0..<3 {shell_test_frame(&session,{size={1440,900},pointer_absent=true})}
    shell_test_click(t,&session,shell_id(&g,"library_tab",int(Library_Tab.Content)+1))
    testing.expect_value(t,g.layout.library_tab,Library_Tab.Content)
    shell_test_click(t,&session,shell_id(&g,"library_tab",int(Library_Tab.Ai)+1))
    testing.expect(t,ai.chat_open && g.layout.library_tab==.Ai)
    shell_test_click(t,&session,shell_id(&g,"library_tab",int(Library_Tab.Editor)+1))
    testing.expect(t,!ai.chat_open && g.layout.library_tab==.Editor)
    testing.expect_value(t,selection.entities[0],selected)
    testing.expect(t,test_command(&session,"library_panel"))
    shell_test_frame(&session,{size={1440,900},pointer_absent=true})
    _,left_shown:=ui.widget_rect(&ctx,shell_id(&g,"left"))
    testing.expect(t,!left_shown && g.layout.library_tab==.Editor)
    testing.expect(t,test_command(&session,"library_panel"))
    for _ in 0..<2 {shell_test_frame(&session,{size={1440,900},pointer_absent=true})}
    // The tab shown folds the panel, another shows that one.
    shell_test_click(t,&session,shell_id(&g,"library_tab",int(Library_Tab.Editor)+1))
    testing.expect(t,!g.layout.left_open && g.layout.library_tab==.Editor)
    shell_test_click(t,&session,shell_id(&g,"library_tab",int(Library_Tab.Content)+1))
    testing.expect(t,g.layout.left_open && g.layout.library_tab==.Content)
    shell_test_click(t,&session,shell_id(&g,"library_tab",int(Library_Tab.Editor)+1))
    testing.expect(t,g.layout.left_open && g.layout.library_tab==.Editor)
    for _ in 0..<2 {shell_test_frame(&session,{size={1440,900},pointer_absent=true})}
    // Move, Rotate and Scale, then the snaps and the axes.
    scale_tool,_:=ui.widget_rect(&ctx,command_widget(&g,"tool_scale"))
    snap_button,_:=ui.widget_rect(&ctx,shell_id(&g,"snap"))
    space,_:=ui.widget_rect(&ctx,command_widget(&g,"space"))
    camera_speed,_:=ui.widget_rect(&ctx,shell_id(&g,"camera_speed"))
    testing.expect(t,scale_tool.x<snap_button.x && snap_button.x<space.x && space.x<camera_speed.x)
    if tools,found:=ui.widget_rect(&ctx,shell_id(&g,"tools"));found {testing.expect(t,camera_speed.x<tools.x)}
    move_snap,scale_snap:=viewport.snap,viewport.snap_scale
    shell_test_click(t,&session,shell_id(&g,"snap_open"))
    shell_test_click(t,&session,shell_id(&g,"snap_toggle",int(Tool.Rotate)+1))
    testing.expect(t,viewport.snap_rotate && viewport.snap==move_snap && viewport.snap_scale==scale_snap)
    // The usual increments hang from the arrow of the field, without closing the snaps.
    _,chips:=ui.widget_rect(&ctx,shell_id(&g,"snap_choice",int(Tool.Rotate)*16+6))
    testing.expect(t,!chips)
    shell_test_click(t,&session,shell_id(&g,"snap_presets_open",int(Tool.Rotate)+1))
    shell_test_click(t,&session,shell_id(&g,"snap_choice",int(Tool.Rotate)*16+6))
    testing.expect_value(t,viewport.rotate_increment,f32(45))
    testing.expect(t,ui.popup_is_open(&ctx,shell_id(&g,"snap_popup")) && !ui.popup_is_open(&ctx,shell_id(&g,"snap_presets",int(Tool.Rotate)+1)))
    field,_:=ui.widget_rect(&ctx,shell_id(&g,"snap_value",int(Tool.Move)+1))
    testing.expect(t,field.w>0 && field.w<=SNAP_POPUP_WIDTH/3)
    // The entry Snap to grid and the toggle of Position change the same field.
    testing.expect(t,test_command(&session,"snap"))
    testing.expect(t,viewport.snap!=move_snap)
    shell_test_click(t,&session,shell_id(&g,"snap_toggle",int(Tool.Move)+1))
    testing.expect(t,viewport.snap==move_snap)
    ui.popup_close(&ctx,shell_id(&g,"snap_popup"))
    // The magnet turns the snaps chosen off and back on, keeping which they are.
    testing.expect(t,snapping(&viewport,.Rotate))
    shell_test_click(t,&session,shell_id(&g,"snap"))
    testing.expect(t,viewport.snap_off && !snapping(&viewport,.Rotate) && viewport.snap_rotate)
    shell_test_click(t,&session,shell_id(&g,"snap"))
    testing.expect(t,!viewport.snap_off && snapping(&viewport,.Rotate))
    shell_test_click(t,&session,shell_id(&g,"run_menu"))
    // Choosing a mode keeps it for the button and runs it.
    shell_test_click(t,&session,shell_id(&g,"run_kind",int(Run_Kind.Simulate)+1))
    asked:=&api_state(&session).commands
    testing.expect(t,g.layout.run_kind==.Simulate && asked.asked_count==1 && asked.asked[0].binding!=nil && asked.asked[0].binding.name=="simulate" && asked.asked[0].binding.params==`{"simulate":true}`)
    asked.asked_count=0
    testing.expect(t,test_command(&session,"rename"))
    ui.frame_begin(&ctx,{size={800,420},pointer_absent=true,dt=1.0/60})
    shell_build(&session,shown_world(&session))
    ui.frame_end(&ctx)
    testing.expect_value(t,ctx.edit.id,ui.id_derive(&ctx,shell_id(&g,"right"),"name"))
    testing.expect(t,g.layout.library_tab!=.Hierarchy)
    ctx.edit={}
    g.begun=true
    // The tool of a plugin is an entry of the Tools menu, which editor.tool turns on.
    _,no_tools:=ui.widget_rect(&ctx,shell_id(&g,"tools"))
    testing.expect(t,!no_tools)
    testing.expect(t,tool_entry(&session,"paint","Paint",.Edit,{key=.B,set=true}))
    for _ in 0..<3 {shell_test_frame(&session,{size={1440,900},pointer_absent=true})}
    rect,found:=ui.widget_rect(&ctx,shell_id(&g,"tools"))
    testing.expect(t,found && rect.h==TOOLBAR_BUTTON && rect.y>=ui.metric(&ctx,"bar_height") && rect.y+rect.h<=ui.metric(&ctx,"bar_height")+DOCUMENT_TOOLBAR_HEIGHT)
    space,_=ui.widget_rect(&ctx,command_widget(&g,"space"))
    camera_speed,_=ui.widget_rect(&ctx,shell_id(&g,"camera_speed"))
    testing.expect(t,space.x<camera_speed.x && camera_speed.x<rect.x)
    shell_test_click(t,&session,shell_id(&g,"tools"))
    shell_test_click(t,&session,command_widget(&g,"paint"))
    testing.expect(t,!tool_on(&session,"paint"),"the entry runs between frames")
    commands_run(&session)
    testing.expect(t,tool_on(&session,"paint") && command_state(&session,"paint").checked)
    // Its key is the shortcut of the entry.
    shortcuts_run(&session,{.B},{})
    commands_run(&session)
    testing.expect(t,!tool_on(&session,"paint"))
    for _ in 0..<2 {shell_test_frame(&session,{size={1440,900},pointer_absent=true})}
    session.mode=.Play
    for released in ([2]bool{false,true}) {
        session.play_input_released=released
        ui.frame_begin(&ctx,{size={1440,900},pointer_absent=true})
        shell_build(&session,shown_world(&session))
        frame:=ui.frame_end(&ctx)
        testing.expect(t,!frame.overflow)
        _,left:=ui.widget_rect(&ctx,shell_id(&g,"left"))
        _,right:=ui.widget_rect(&ctx,shell_id(&g,"right"))
        _,menu:=ui.widget_rect(&ctx,shell_id(&g,"menu",1))
        testing.expect(t,!left && !right)
        testing.expect_value(t,menu,released)
    }
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    app.platform=p
    session.headless=false
    layout_before_play:=g.layout
    // The chat opens only in the pause.
    play_chat_set(&session,true)
    testing.expect(t,!session.play_chat_open)
    session.mode=.Paused
    play_chat_set(&session,true)
    for size in ([2][2]f32{{1440,900},{800,420}}) {
        for _ in 0..<3 {
            frame:=shell_test_frame(&session,{size=size,pointer_absent=true})
            testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
        }
        left,left_shown:=ui.widget_rect(&ctx,shell_id(&g,"left"))
        _,right_shown:=ui.widget_rect(&ctx,shell_id(&g,"right"))
        _,editor_tab:=ui.widget_rect(&ctx,shell_id(&g,"library_tab",int(Library_Tab.Editor)+1))
        testing.expect(t,left_shown && left.x==RAIL_WIDTH && left.y+left.h==size.y)
        // In the pause Details stays beside the chat, for the entities it refers to.
        testing.expect(t,right_shown && editor_tab && g.rects.bottom.h==0)
        ui.id_push(&ctx,shell_id(&g,"left"))
        ui.id_push(&ctx,shell_id(&g,"ai_chat"))
        prompt:=ui.id(&ctx,"prompt")
        ui.id_pop(&ctx);ui.id_pop(&ctx)
        _,prompt_shown:=ui.widget_rect(&ctx,prompt)
        testing.expect(t,prompt_shown && ctx.edit.id==prompt)
    }
    play_chat_set(&session,false)
    shell_test_frame(&session,{size={1440,900},pointer_absent=true})
    _,chat_hidden:=ui.widget_rect(&ctx,shell_id(&g,"left"))
    chat_button:=shell_id(&g,"library_tab",int(Library_Tab.Ai)+1)
    _,launcher:=ui.widget_rect(&ctx,chat_button)
    testing.expect(t,!chat_hidden && launcher)
    shell_test_click(t,&session,chat_button)
    testing.expect(t,session.play_chat_open)
    shell_test_click(t,&session,chat_button)
    testing.expect(t,!session.play_chat_open)
    session.mode=.Play
    shell_test_frame(&session,{size={1440,900},pointer_absent=true})
    shell_test_click(t,&session,chat_button)
    testing.expect(t,!session.play_chat_open,"while the game plays the rail stays and the chat does not open")
    g.layout=layout_before_play
    world.graphics.show_fps=true
    testing.expect(t,tool_entry(&session,"terrain","Terrain",.Edit) && tool_entry(&session,"placement","Placement",.Edit))
    for mode in ([3]Mode{.Edit,.Simulate,.Simulation_Paused}) {
        session.mode=mode
        for width in ([8]f32{800,900,1000,1100,1180,1200,1280,1440}) {
            size:=[2]f32{width,420}
            for _ in 0..<3 {
                ui.frame_begin(&ctx,{size=size,pointer_absent=true})
                shell_build(&session,shown_world(&session))
                frame:=ui.frame_end(&ctx)
                testing.expect(t,!frame.overflow)
                testing.expect_value(t,ctx.stats.layout_errors,u32(0))
            }
            _,left:=ui.widget_rect(&ctx,shell_id(&g,"left"))
            _,right:=ui.widget_rect(&ctx,shell_id(&g,"right"))
            testing.expect(t,left && right)
            tools,shown:=ui.widget_rect(&ctx,shell_id(&g,"tools"))
            testing.expect_value(t,shown,!playing(&session))
            if shown {testing.expect(t,tools.x>=0 && tools.x+tools.w<=width)}
            fps,_:=ui.widget_rect(&ctx,shell_id(&g,"fps"))
            run,_:=ui.widget_rect(&ctx,command_widget(&g,session.mode==.Edit?"simulate":"stop"))
            testing.expectf(t,fps.x+fps.w<=width-9,"FPS fits at %.0fpx: %v",width,fps)
            // The counter goes before the controls of the run, 12 points from them.
            if run.w>0 {testing.expect(t,run.x-fps.x-fps.w>=12)}
            if simulating(&session) {testing.expect(t,!command_state(&session,"apply_simulation").disabled)}
            when platform.WINDOW_CONTROLS==.Right {
                close,found:=ui.widget_rect(&ctx,shell_id(&g,"window_control",int(User_Icon.Close)+1))
                testing.expectf(t,found && abs(close.x+close.w-width)<0.01 && close.y==0,"Close takes the top right corner at %.0fpx: %v",width,close)
                if shown {testing.expectf(t,tools.x+tools.w<=close.x-WINDOW_CONTROL_WIDTH*2+0.5,"the tools fit at %.0fpx: %v",width,tools)}
            }
        }
    }
}
