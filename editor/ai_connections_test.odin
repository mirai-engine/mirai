package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

ai_connections_test_frame :: proc(s:^Session,pointer:[2]f32={},pressed:bool=false) {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,{size={800,700},pointer=pointer,pointer_absent=!pressed,pressed={.Left} if pressed else {},down={.Left} if pressed else {}})
    ai_connections_build(s)
    result:=ui.frame_end(ctx)
    assert(!result.overflow && ctx.stats.layout_errors==0)
}

@(test)
ai_connections_keep_runtime_advanced_and_only_offer_bun_when_none_is_available :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.initialized=true
    s:=Session{gui=&g,ai=m}
    state:=&m.connection_ui;state.screen=.Overview;state.available[.Node]=true
    ai_connections_test_frame(&s);ai_connections_test_frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"Advanced settings")!=nil && ai_chat_test_paint(&ctx,"Runtime")==nil)
    testing.expect(t,ai_chat_test_paint(&ctx,"Download Bun")==nil)
    ui.id_push(&ctx,shell_id(&g,"ai_connections"))
    advanced_id:=ui.id(&ctx,"advanced")
    ui.id_pop(&ctx)
    rect,found:=ui.widget_rect(&ctx,advanced_id);testing.expect(t,found)
    ai_connections_test_frame(&s,ui.rect_center(rect),true)
    ai_connections_test_frame(&s)
    testing.expect(t,state.advanced && ai_chat_test_paint(&ctx,"Runtime")!=nil)
    state.advanced=false
    for kind in ([3]Ai_Runtime{.Bun,.Node,.Pnpm}) {
        state.available={};state.available[kind]=true
        ai_connections_test_frame(&s)
        testing.expect(t,ai_chat_test_paint(&ctx,"Run with")==nil && ai_chat_test_paint(&ctx,"Runtime")==nil)
        testing.expect(t,ai_chat_test_paint(&ctx,"No runtime found")==nil && ai_chat_test_paint(&ctx,"Download Bun")==nil)
    }
    state.available={}
    ai_connections_test_frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"No runtime found")!=nil && ai_chat_test_paint(&ctx,"Download Bun")!=nil)
    // Download starts from the card itself: no page of its own. Without a
    // project it cannot, and says why there.
    state.available[.Node]=true
    ai_connections_test_frame(&s);ai_connections_test_frame(&s)
    ui.id_push(&ctx,shell_id(&g,"ai_connections"))
    ui.id_push(&ctx,ui.id(&ctx,"provider",1));download_id:=ui.id(&ctx,"agent_action");ui.id_pop(&ctx)
    ui.id_pop(&ctx)
    testing.expect(t,ai_chat_test_paint(&ctx,"Download")!=nil)
    rect,found=ui.widget_rect(&ctx,download_id);testing.expect(t,found)
    ai_connections_test_frame(&s,ui.rect_center(rect),true)
    testing.expect(t,state.screen==.Overview && base.text_get(state.error[:])=="Open a project first","Download goes at once and its problem shows in the same dialog")
}

when ODIN_OS!=.Windows {
    @(test)
    ai_connections_check_keeps_its_popup_and_update_starts_without_confirmation :: proc(t:^testing.T) {
        root:=base.test_folder(t,"connections");if root=="" {return}
        // The adapters are of the user of the machine: a folder of their own, outside the project.
        home:=project.path(root,"agents",allocator=context.temp_allocator)
        m:=new(Ai);defer free(m);ai_connections_reset(m);m.initialized=true;m.connections[AI_CODEX].configured=true
        base.text_set(m.agents_home[:],home)
        folder:=ai_agents_folder(m,"codex")
        binary_folder:=project.path(root,"bin",allocator=context.temp_allocator)
        os.make_directory_all(binary_folder)
        os.make_directory_all(project.path(folder,"node_modules","@agentclientprotocol","codex-acp","dist",allocator=context.temp_allocator))
        testing.expect(t,os.write_entire_file(ai_agent_entry(m,.Codex,.Bun),"")==nil)
        testing.expect(t,os.write_entire_file(project.path(folder,"installation.json",allocator=context.temp_allocator),`{"version":"2.2.1","runtime":"Bun"}`)==nil)
        private_runtime:=project.path(home,"runtime",allocator=context.temp_allocator)
        os.make_directory_all(private_runtime);testing.expect(t,os.write_entire_file(project.path(private_runtime,"bun",allocator=context.temp_allocator),"")==nil)
        installer:=project.path(binary_folder,"mirai",allocator=context.temp_allocator)
        script:=`#!/bin/sh
test "$4" = --home || exit 2
case "$2" in
updates) printf '["2.2.2","0.89.1"]' > "$5/updates.json" ;;
install) printf '%s\n' "$@" > "$5/request" ;;
*) exit 1 ;;
esac
`
        testing.expect(t,os.write_entire_file(installer,script)==nil)
        testing.expect(t,os.chmod(installer,{.Read_User,.Write_User,.Execute_User})==nil)
        p,platform_error:=platform.create({headless=true})
        testing.expect_value(t,platform_error,platform.Error.None);if p==nil {return}
        defer platform.destroy(p)
        ctx:ui.Context
        testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
        g:=Editor_Ui{ctx=&ctx};app:=host.App{platform=p}
        s:=Session{gui=&g,ai=m,app=&app,engine_root=root,project_root=root,has_project=true}
        defer ai_destroy(&s)
        ai_connections_open(&s)
        m.connection_ui.advanced=true
        m.task_count=1;m.tasks[0].id=1;m.tasks[0].state=.Running;m.workers[0].task=1
        ai_connections_test_frame(&s);ai_connections_test_frame(&s)
        ui.id_push(&ctx,shell_id(&g,"ai_connections"))
        check_id:=ui.id(&ctx,"check_updates")
        ui.id_push(&ctx,ui.id(&ctx,"provider",1));update_id:=ui.id(&ctx,"agent_action");ui.id_pop(&ctx)
        ui.id_pop(&ctx)
        rect,found:=ui.widget_rect(&ctx,check_id);testing.expect(t,found)
        ai_connections_test_frame(&s,ui.rect_center(rect),true)
        ai_connections_open(&s)
        ai_connections_test_frame(&s)
        testing.expect(t,m.installer.pid!=0 && m.connection_ui.screen==.Overview && m.connection_ui.advanced)
        testing.expect(t,ai_chat_test_paint(&ctx,"Check for updates").icon==ui.icon_user(u8(User_Icon.Waiting)))
        until:=platform.clock_seconds()+5
        for m.installer.pid!=0 && platform.clock_seconds()<until {ai_install_poll(&s);platform.sleep_coarse(1_000_000)}
        testing.expect(t,m.installer.pid==0 && m.connection_ui.screen==.Overview && m.connection_ui.advanced)
        testing.expect_value(t,base.text_get(m.connections[AI_CODEX].latest[:]),"2.2.2")
        testing.expect(t,m.tasks[0].state==.Running && m.workers[0].task==1,"checking versions preserves ongoing work")
        m.tasks[0].state=.Done;m.workers[0].task=0
        ai_connections_test_frame(&s);ai_connections_test_frame(&s)
        rect,found=ui.widget_rect(&ctx,update_id);testing.expect(t,found)
        ai_connections_test_frame(&s,ui.rect_center(rect),true)
        testing.expect(t,m.installer.pid!=0 && m.connection_ui.screen==.Overview,"Update immediately starts its process from its card")
        until=platform.clock_seconds()+5
        for m.installer.pid!=0 && platform.clock_seconds()<until {ai_install_poll(&s);platform.sleep_coarse(1_000_000)}
        request,read_error:=os.read_entire_file(project.path(home,"request",allocator=context.temp_allocator),context.temp_allocator)
        testing.expect(t,read_error==nil && strings.contains(string(request),"agent\ninstall\ncodex\n") && strings.contains(string(request),"--version\n2.2.2\n"))
    }
}
