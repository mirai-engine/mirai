package editor

import "core:testing"
import "core:strings"
import "core:time"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

ai_chat_test_paint :: proc(ctx:^ui.Context,text:string) -> ^ui.Paint {
    for &paint in ctx.paints[:ctx.paint_count] {if paint.text==text {return &paint}}
    return nil
}

@(test)
ai_chat_agent_icons_select_tasks_and_finish_review :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    m.task_count,m.selected=3,1
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.icon=u8(index);task.color_index=u8(index)
        task.state=index==1?.Done:.Running
        base.text_set(task.title[:],index==0?"Refine the material":(index==1?"Balance the spacing":"Adjust the proportions"))
        base.text_set(task.agent[:],"codex")
        ai_transcript_add(&task.transcript,base.text_get(task.title[:]),.Prompt)
    }
    append(&m.tasks[1].review.changed_files,strings.clone("notes.txt"))
    m.workers[0].task=1;m.workers[1].task=3
    m.connections[AI_CODEX].configured=true
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-luna")
    m.agents_open=true
    frame :: proc(s:^Session,pointer:[2]f32={},pressed:bool=false,height:f32=560) {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer=pointer,pointer_absent=!pressed,pressed={.Left} if pressed else {},down={.Left} if pressed else {}})
        ai_chat_bar_buttons(s)
        ai_chat_content_build(s,280,height)
        painted:=ui.frame_end(s.gui.ctx)
        assert(!painted.overflow && s.gui.ctx.stats.layout_errors==0)
    }
    frame(&s);frame(&s)
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    agent_id:=ui.id(&ctx,"agent_task",2)
    tick_id:=ui.id(&ctx,"agent_finish",2)
    new_id:=shell_id(&g,"ai_new_chat")
    finish_id:=ui.id(&ctx,"finish")
    retry_id:=ui.id(&ctx,"retry")
    ui.id_pop(&ctx)
    second,found:=ui.widget_rect(&ctx,agent_id)
    testing.expect(t,found)
    _,ticked:=ui.widget_rect(&ctx,tick_id)
    testing.expect(t,ticked,"a session that finished shows its tick without the pointer on its row")
    testing.expect(t,ai_agent_icon(&m.tasks[0])!=ai_agent_icon(&m.tasks[1]) && ai_agent_color(&m.tasks[0])!=ai_agent_color(&m.tasks[1]))
    before:=ai_agent_icon(&m.tasks[1])
    frame(&s,{second.x+second.w*.5,second.y+second.h*.5},true)
    testing.expect(t,m.selected==2 && m.chat_open && g.layout.library_tab==.Ai)
    frame(&s)
    text:=string(ctx.text[:ctx.text_length])
    testing.expect(t,!strings.contains(text,"Review is ready") && !strings.contains(text,"New order") && !strings.contains(text,"New task"))
    testing.expect(t,strings.contains(text,"Accept all") && strings.contains(text,"change"),"the review of a turn lists its changes and keeps all of them")
    finish,finish_found:=ui.widget_rect(&ctx,finish_id)
    _,retry_found:=ui.widget_rect(&ctx,retry_id)
    testing.expect(t,finish_found && !retry_found,"completed work has Finish without Retry")
    frame(&s,{finish.x+finish.w*.5,finish.y+finish.h*.5},true)
    testing.expect(t,m.tasks[1].review_finished && ai_agent_icon(&m.tasks[1])!=before,"Finish clears the completion badge")
    testing.expect(t,m.selected==2,"Finish stays on the chat it finished")
    m.selected=1
    frame(&s);frame(&s)
    _,found=ui.widget_rect(&ctx,agent_id)
    testing.expect(t,!found,"finished reviews leave the active agents deck")
    _,new_found:=ui.widget_rect(&ctx,new_id)
    testing.expect(t,!new_found,"there is no other chat to open")
    m.selected=2
    m.prompt_length=copy(m.prompt[:],"Another independent question")
    ai_chat_submit(&s)
    testing.expect(t,m.pending,"a chat that finished can send while two other agents are working")
    frame(&s)
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    _,composer_found:=ui.widget_rect(&ctx,ui.id(&ctx,"prompt"))
    ui.id_pop(&ctx)
    testing.expect(t,composer_found && ai_chat_test_paint(&ctx,"Refine the material")!=nil,"the chat remains drawn while the message waits for its viewport snapshot")
    m.pending=false
    for height in ([2]f32{300,560}) {
        frame(&s,{},false,height);frame(&s,{},false,height)
        ui.id_push(&ctx,shell_id(&g,"ai_chat"))
        send,_:=ui.widget_rect(&ctx,ui.id(&ctx,"send"))
        ui.id_pop(&ctx)
        testing.expect(t,send.y+send.h<=height+.01,"the agents deck and composer fit the available panel")
    }
    m.selected=1
    frame(&s);frame(&s)
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    send,_:=ui.widget_rect(&ctx,ui.id(&ctx,"send"))
    ui.id_pop(&ctx)
    testing.expectf(t,send.y+send.h<=560.01 && send.y+send.h>=560-8,"a running turn shown by the deck leaves no room under the composer: %v",send.y+send.h)
    // Ask agent of a menu asks the main chat, whatever is being inspected.
    m.chat_open=false
    m.main=1
    asset_id:=base.Asset_Id{1,2}
    m.selected=2
    ai_ask(&s,{asset_id,asset_id})
    testing.expect(t,m.selected==1 && m.chat_open && m.focus && m.attachment_count==1 && m.attachments[0]==asset_id)
}

@(test)
asking_the_agent_about_a_range_of_the_play_attaches_it_to_the_next_message :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    frame :: proc(s:^Session) {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer_absent=true})
        ai_chat_content_build(s,280,560)
        ui.frame_end(s.gui.ctx)
    }
    asked:=Ai_Range{from=130,to=190,run=4}
    base.text_set(asked.path[:],"scenes/main.scene")
    timeline_range_use(&s,{ask=true},asked)
    opened:=m.chat_open && m.focus && g.layout.left_open
    testing.expect(t,opened,"The chat opens with its composer focused")
    attached:=m.range.from==130 && m.range.to==190
    testing.expect(t,attached,"The range goes with the next message")
    frame(&s);frame(&s)
    chip:=ai_chat_test_paint(&ctx,"Ticks 130 to 190")
    testing.expect(t,chip!=nil,"The range is a chip over the composer")
    task:Ai_Task
    task.range=m.range
    b:=strings.builder_make(context.temp_allocator)
    ai_range_prompt(&task,&b)
    line:=strings.to_string(b)
    testing.expect(t,strings.contains(line,"ticks 130 to 190 of run 4, a Play of scenes/main.scene"),line)
    testing.expect(t,strings.contains(line,"`play.history` with `run` 4, `from` 130 and `to` 190"),line)
    testing.expect(t,!strings.contains(line,":/"),"No path outside the project")
    said:=ai_context_range(&task.range)
    testing.expect(t,said==Ai_Context_Range{"play",130,190,4,0,"scenes/main.scene",""},"context.json says what Copy range says")
    m.range={}
    timeline_range_use(&s,{ask=true},{from=10,to=10})
    testing.expect(t,m.range=={},"An empty range is not attached")
}

@(test)
ai_chat_draws_the_first_prompt_and_does_not_reuse_another_conversations_scroll :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    m.task_count=2;m.stick=true
    first:=&m.tasks[0];first.id=1;first.state=.Done
    ai_transcript_add(&first.transcript,"Move the crate beside the wall",.Prompt)
    frame :: proc(s:^Session,task:^Ai_Task) -> ui.Frame {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer_absent=true})
        ai_transcript_draw(s,s.ai,task,120,280)
        return ui.frame_end(s.gui.ctx)
    }
    initial:=frame(&s,first)
    testing.expect(t,!initial.overflow && len(initial.vertices)>0 && m.scroll==0,"the first frame of a new chat draws its user bubble")
    for _ in 0..<20 {ai_transcript_add(&first.transcript,"A prior answer that makes this conversation longer than the viewport.",.Output)}
    frame(&s,first);frame(&s,first)
    testing.expect(t,m.scroll>0,"a longer conversation stays at its last message")
    second:=&m.tasks[1];second.id=2
    ai_transcript_add(&second.transcript,"Decorate the room",.Prompt)
    selected:=frame(&s,second)
    testing.expect(t,!selected.overflow && len(selected.vertices)>0 && m.scroll==0,"selecting a short chat does not inherit another chat's content height")
    // The side and the color of a bubble say who wrote it: no author label.
    testing.expect(t,ai_chat_test_paint(&ctx,"You")==nil && ai_chat_test_paint(&ctx,"Codex")==nil)
}

@(test)
ai_chat_builds_only_the_messages_in_sight_and_remeasures_a_growing_answer :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    m.task_count=1;m.stick=true
    task:=&m.tasks[0];task.id=1;task.state=.Done
    for _ in 0..<(AI_TRANSCRIPT_LINES-2)/2 {
        ai_transcript_add(&task.transcript,"Furnish the room",.Prompt)
        ai_transcript_add(&task.transcript,"A prior answer that wraps over a few lines of the narrow chat panel.",.Output)
    }
    frame :: proc(s:^Session,task:^Ai_Task) -> ui.Frame {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer_absent=true})
        ai_transcript_draw(s,s.ai,task,200,280)
        return ui.frame_end(s.gui.ctx)
    }
    painted:=frame(&s,task)
    testing.expect(t,!painted.overflow && ctx.stats.layout_errors==0)
    testing.expectf(t,ctx.stats.elements<60,"only the messages in sight become elements: %d",ctx.stats.elements)
    total:f32
    for h in task.transcript.heights[:task.transcript.count] {total+=h}
    testing.expect(t,m.scroll==total-200,"a new chat opens at its last message")
    // The answer that streams grows its own line and only that one is measured again.
    ai_transcript_add(&task.transcript,"And the lamp?",.Prompt)
    task.stream_open=true
    ai_transcript_add(&task.transcript,"Done.",.Output)
    frame(&s,task)
    last:=task.transcript.count-1
    before:=task.transcript.heights[last]
    second:=task.transcript.heights[last-1]
    ai_stream_add(&s,task," The table sits under the window and the lamp beside it, both inside the light of the sun.")
    testing.expect(t,task.transcript.heights[last]==0 && task.transcript.heights[last-1]==second)
    frame(&s,task)
    testing.expect(t,task.transcript.heights[last]>before,"the grown answer takes more lines")
    total=0
    for h in task.transcript.heights[:task.transcript.count] {total+=h}
    testing.expect(t,m.scroll==total-200,"the chat follows the answer while it grows")
    laid,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,ui.id(&ctx,"transcript",1),"content"))
    testing.expect(t,found && abs(laid.h-total)<0.5,"the content keeps the height of every message")
}

@(test)
ai_chat_keeps_partial_failed_changes_available_for_review :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    m.task_count,m.selected=1,7
    task:=&m.tasks[0];task.id=7;task.state=.Failed;task.icon=2;task.color_index=1;task.review.pending=true
    append(&task.review.changed_files,strings.clone("notes.txt"))
    base.text_set(task.title[:],"Adjust the proportions")
    ai_transcript_add(&task.transcript,"The connection ended early",.Note)
    m.agents_open=true
    frame :: proc(s:^Session,pointer:[2]f32={},pressed:bool=false) {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer=pointer,pointer_absent=!pressed,pressed={.Left} if pressed else {},down={.Left} if pressed else {}})
        ai_chat_content_build(s,280,560)
        painted:=ui.frame_end(s.gui.ctx)
        assert(!painted.overflow && s.gui.ctx.stats.layout_errors==0)
    }
    frame(&s);frame(&s)
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    agent_id:=ui.id(&ctx,"agent_task",7)
    finish_id:=ui.id(&ctx,"finish")
    revert_id:=ui.id(&ctx,"revert")
    retry_id:=ui.id(&ctx,"retry")
    card_id:=ui.id(&ctx,"review_header")
    ui.id_pop(&ctx)
    // Revert all shows while the pointer is on the head of the card.
    card,card_found:=ui.widget_rect(&ctx,card_id)
    testing.expect(t,card_found,"the card of the changes is there")
    ui.frame_begin(&ctx,{size={800,600},pointer=ui.rect_center(card)})
    ai_chat_content_build(&s,280,560)
    _=ui.frame_end(&ctx)
    _,agent_found:=ui.widget_rect(&ctx,agent_id)
    finish,finish_found:=ui.widget_rect(&ctx,finish_id)
    _,revert_found:=ui.widget_rect(&ctx,revert_id)
    _,retry_found:=ui.widget_rect(&ctx,retry_id)
    testing.expect(t,agent_found && finish_found && revert_found && !retry_found,"partial edits keep Finish and Revert after failure")
    before:=ai_agent_icon(task)
    frame(&s,ui.rect_center(finish),true)
    testing.expect(t,task.review_finished && !task.review.pending && ai_agent_icon(task)!=before)
    frame(&s)
    _,agent_found=ui.widget_rect(&ctx,agent_id)
    _,finish_found=ui.widget_rect(&ctx,finish_id)
    _,retry_found=ui.widget_rect(&ctx,retry_id)
    testing.expect(t,!agent_found && !finish_found && !retry_found && m.selected==7,"Finish clears the failed review and the unit leaves the list")
}

@(test)
ai_chat_settings_use_the_header_gear_for_connections_and_scene_agents :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    m.show_agents_in_scene=true
    frame :: proc(s:^Session) {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer_absent=true})
        if ui.box(s.gui.ctx,{width=ui.fixed(280),height=ui.fixed(26)}) {ai_chat_settings_button(s)}
        ai_chat_settings_build(s)
        ui.frame_end(s.gui.ctx)
    }
    frame(&s);frame(&s)
    gear,found:=ui.widget_rect(&ctx,shell_id(&g,"library_settings"))
    testing.expect(t,found)
    _,old_gear:=ui.widget_rect(&ctx,shell_id(&g,"ai_connections_open"))
    testing.expect(t,!old_gear)
    ui.popup_open(&ctx,shell_id(&g,"ai_settings_popup"),gear)
    frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"Connections")!=nil && ai_chat_test_paint(&ctx,"Show agents in scene")!=nil)
    testing.expect(t,ai_chat_test_paint(&ctx,"Agents")!=nil && ai_chat_test_paint(&ctx,"Agent picks")!=nil && ai_chat_test_paint(&ctx,"Memory")!=nil,"the gear also says what the agents run with and remember")
    eye,connection,check:=false,false,false
    for &p in ctx.paints[:ctx.paint_count] {
        if p.kind!=.Icon {continue}
        eye|=p.icon==.Eye
        connection|=p.icon==ui.icon_user(u8(User_Icon.Connection))
        check|=p.icon==.Check
    }
    testing.expect(t,eye && connection && check,"Each item shows its icon, and the agents in the scene their check")
}

@(test)
ai_chat_hides_tools_and_viewport_context_and_only_lists_supported_codex_models :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    m.task_count,m.selected=1,1
    m.tasks[0].id=1;m.tasks[0].state=.Done
    ai_transcript_add(&m.tasks[0].transcript,"Tool: hidden",.Note)
    ai_transcript_add(&m.tasks[0].transcript,"Tool failed: hidden",.Note)
    ai_transcript_add(&m.tasks[0].transcript,"Done",.Output)
    m.has_region=true
    m.connections[AI_CODEX].configured=true
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-luna")
    m.model_counts[AI_CODEX]=1
    base.text_set(m.models[AI_CODEX][0].value[:],"gpt-5")
    base.text_set(m.models[AI_CODEX][0].name[:],"Unavailable model")
    frame :: proc(s:^Session) {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer_absent=true})
        ai_chat_bar_buttons(s)
        ai_chat_content_build(s,280,420)
        ai_chat_history_build(s,280)
        ui.frame_end(s.gui.ctx)
    }
    frame(&s);frame(&s)
    visible_text:=string(ctx.text[:ctx.text_length])
    testing.expect(t,!strings.contains(visible_text,"Tool: hidden") && !strings.contains(visible_text,"Tool failed: hidden"),"persisted tool notes do not enter the text the chat draws")
    testing.expect(t,!strings.contains(visible_text,"Viewport region") && strings.contains(visible_text,"Done"))
    _,history_found:=ui.widget_rect(&ctx,shell_id(&g,"ai_history"))
    _,new_found:=ui.widget_rect(&ctx,shell_id(&g,"ai_new_chat"))
    testing.expect(t,history_found && !new_found,"History sits in the bar of the panel, and no New chat")
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    models_id:=ui.id_derive(&ctx,ui.id(&ctx,"agent"),"menu")
    ui.id_pop(&ctx)
    ui.popup_open(&ctx,shell_id(&g,"ai_history_menu"),{0,0,100,24})
    frame(&s)
    _,menu_found:=ui.widget_rect(&ctx,shell_id(&g,"ai_history_menu"))
    testing.expect(t,menu_found,"History opens its menu")
    ui.popup_close(&ctx)
    ui.popup_open(&ctx,models_id,{0,0,180,26})
    frame(&s)
    for label in AI_CODEX_MODEL_NAMES {testing.expect(t,ai_chat_test_paint(&ctx,label)!=nil)}
    testing.expect(t,ai_chat_test_paint(&ctx,"Unavailable model")==nil)
    testing.expect(t,ai_connection_configure(&s,AI_CODEX,"gpt-5","")!="" && base.text_get(m.connections[AI_CODEX].model[:])=="gpt-6-luna")
}

@(test)
ai_chat_uses_live_selection_and_keeps_tasks_with_their_document :: proc(t:^testing.T) {
    world:Shell_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    entity:=core.create(&world.entities)
    core.add(&world.names,entity,core.name_make("Selected entity"))
    core.add(&world.transforms,entity,core.TRANSFORM_IDENTITY)
    core.test_world_settle(&world)
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    ai:=new(Ai)
    defer free(ai)
    app:host.App
    viewport:Viewport
    selection:history.Selection
    defer delete(selection.entities)
    session:=Session{info=core.test_world_info(&world),edit_world=&world,app=&app,gui=&g,viewport=&viewport,selection=&selection,ai=ai}
    history.selection_set(&selection,{entity})
    for _ in 0..<3 {
        ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
        ai_chat_content_build(&session,280,420)
        frame:=ui.frame_end(&ctx)
        testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    }
    // Before the first message, with no agent at work, only the composer waits, in the middle.
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    waiting,sent:=ui.widget_rect(&ctx,ui.id(&ctx,"send"))
    ui.id_pop(&ctx)
    testing.expectf(t,sent && waiting.y>120 && waiting.y+waiting.h<360,"the composer is centered: %v",waiting)
    // The first message takes it down to its place in a short movement, not at once.
    {
        ai.task_count,ai.selected=1,1
        defer {ai.task_count,ai.selected,ai.composer_drop_at=0,0,0}
        ai.tasks[0]={id=1,state=.Running}
        ai_transcript_add(&ai.tasks[0].transcript,"Light the room",.Prompt)
        ai.composer_drop_from,ai.composer_drop_at=ai.composer_empty_y,max(ctx.time,1e-6)
        send_y :: proc(session:^Session,g:^Editor_Ui,dt:f32) -> f32 {
            ui.frame_begin(g.ctx,{size={800,600},pointer_absent=true,dt=dt})
            ai_chat_content_build(session,280,420)
            ui.frame_end(g.ctx)
            ui.id_push(g.ctx,shell_id(g,"ai_chat"))
            defer ui.id_pop(g.ctx)
            r,_:=ui.widget_rect(g.ctx,ui.id(g.ctx,"prompt"))
            return r.y
        }
        ui.id_push(&ctx,shell_id(&g,"ai_chat"))
        field,_:=ui.widget_rect(&ctx,ui.id(&ctx,"prompt"))
        ui.id_pop(&ctx)
        send_y(&session,&g,0);moving:=send_y(&session,&g,0.05)
        for _ in 0..<6 {send_y(&session,&g,0.05)}
        rest:=send_y(&session,&g,0.05)
        testing.expectf(t,moving>field.y-1 && moving<rest-20 && rest==send_y(&session,&g,0.05),"the composer goes down from %v through %v to %v",field.y,moving,rest)
    }
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    context_id:=ui.id(&ctx,"context",1)
    ui.id_pop(&ctx)
    chip,found:=ui.widget_rect(&ctx,context_id)
    testing.expect(t,found,"selection is automatically displayed in the AI composer")
    testing.expect(t,chip.w<240,"the context chip fits its entity name instead of growing to the composer width")
    filled:=false
    for paint in ctx.paints[:ctx.paint_count] {if paint.radius==ctx.theme.radius_control && paint.fill==ctx.theme.field {filled=true;break}}
    testing.expect(t,filled,"selected context sits on the gray of a field")
    second:=core.create(&world.entities)
    core.add(&world.names,second,core.name_make("A"))
    core.add(&world.transforms,second,core.TRANSFORM_IDENTITY)
    core.test_world_settle(&world)
    history.selection_set(&selection,{entity,second})
    for _ in 0..<2 {
        ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
        ai_chat_content_build(&session,280,420)
        frame:=ui.frame_end(&ctx)
        testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    }
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    first_chip,_:=ui.widget_rect(&ctx,context_id)
    second_chip,second_found:=ui.widget_rect(&ctx,ui.id(&ctx,"context",2))
    ui.id_pop(&ctx)
    testing.expect(t,second_found && first_chip.y==second_chip.y && second_chip.w<60,"short entity chips share a row and keep their own width")
    core.edit(&world.names,second)^=core.name_make("An entity whose very long name should fit inside the composer without pushing the send button out")
    for _ in 0..<2 {
        ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
        ai_chat_content_build(&session,280,420)
        frame:=ui.frame_end(&ctx)
        testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    }
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    first_chip,_=ui.widget_rect(&ctx,context_id)
    second_chip,_=ui.widget_rect(&ctx,ui.id(&ctx,"context",2))
    context_send,_:=ui.widget_rect(&ctx,ui.id(&ctx,"send"))
    ui.id_pop(&ctx)
    testing.expect(t,second_chip.y>first_chip.y && second_chip.w<=240 && context_send.y+context_send.h<=420,"long chips wrap and truncate within the available panel")
    history.selection_clear(&selection)
    ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
    ai_chat_content_build(&session,280,420)
    frame:=ui.frame_end(&ctx)
    testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    _,found=ui.widget_rect(&ctx,context_id)
    testing.expect(t,!found,"deselection removes the composer context")
    other:Shell_Test_World
    task:=Ai_Task{world=&other,state=.Done,review={pending=true}}
    testing.expect(t,ai_task_revert(&session,ai,&task)!="" && task.review.pending && !task.review_finished,"reverting another document leaves its review intact")
    ai.task_count,ai.selected=1,1
    ai.tasks[0].id=1
    ai.tasks[0].world=&world
    ai.tasks[0].state=.Done
    ai_transcript_add(&ai.tasks[0].transcript,"Make the selected entity larger",.Prompt)
    ai_transcript_add(&ai.tasks[0].transcript,"Done",.Output)
    ai_transcript_add(&ai.tasks[0].transcript,"/Users/example/a-project-with-a-long-directory/.agents/skills/mirai-agent-api/SKILL.md",.Output)
    history.selection_set(&selection,{entity})
    for _ in 0..<3 {
        ui.frame_begin(&ctx,{size={800,420},pointer_absent=true})
        ai_chat_content_build(&session,280,300)
        frame=ui.frame_end(&ctx)
        testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    }
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    send,_:=ui.widget_rect(&ctx,ui.id(&ctx,"send"))
    ui.id_pop(&ctx)
    testing.expect(t,send.y+send.h<=300.01,"the composer remains within the compact AI panel")
    chat,chat_found:=ui.widget_rect(&ctx,shell_id(&g,"ai_chat"))
    testing.expect(t,chat_found && chat.w<=280.01,"long file paths cannot enlarge the chat panel")
    full_title:="Read the exposed skill catalog and then inspect the live player through the Mirai MCP server without changing the scene"
    short_title:=ai_chat_menu_label(&ctx,full_title,200)
    testing.expect(t,len(short_title)<len(full_title) && ui.text_width(&ctx.font,short_title,ctx.theme.font_small)<=200.01,"conversation titles fit the history popup without changing stored text")
    for _ in 0..<5 {
        extra:=core.create(&world.entities)
        core.add(&world.names,extra,core.name_make("Another selected entity"))
        core.add(&world.transforms,extra,core.TRANSFORM_IDENTITY)
        history.selection_add(&selection,extra)
    }
    core.test_world_settle(&world)
    for height in ([2]f32{300,390}) {
        for region in ([2]bool{false,true}) {
            ai.has_region=region
            for _ in 0..<3 {
                ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
                ai_chat_content_build(&session,280,height)
                frame=ui.frame_end(&ctx)
                testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
            }
            ui.id_push(&ctx,shell_id(&g,"ai_chat"))
            send,_=ui.widget_rect(&ctx,ui.id(&ctx,"send"))
            ui.id_pop(&ctx)
            testing.expect(t,send.y+send.h<=height+0.01,"many selected entities and a region fit the compositor")
        }
    }
}

@(test)
ai_tool_notes_are_the_steps_of_a_turn_with_what_each_worked_on :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m)
    s:=Session{ai=m}
    task:=&m.tasks[0];task.id=1;m.task_count=1
    ai_tool_note(&s,task,"scene.add","Point Light 1","","",1500*time.Microsecond)
    ai_tool_note(&s,task,"scene.set","","","Unknown entity",0)
    ai_tool_note(&s,task,"material.set","Floor · Wet","","",0)
    ai_tool_note(&s,task,"scene.set","Crate","0x000000010000002a materials/floor.mat","Unknown field",0)
    text,kind:=ai_transcript_line(&task.transcript,0)
    testing.expectf(t,ai_transcript_hidden(text,kind) && strings.has_prefix(text,"Tool: scene.add Point Light 1 · +") && strings.has_suffix(text,"1.5 ms"),"got %q",text)
    call,ok:=ai_call_parse(text)
    testing.expect(t,ok && call.method=="scene.add" && call.target=="Point Light 1" && !call.failed)
    text,kind=ai_transcript_line(&task.transcript,1)
    testing.expectf(t,ai_transcript_hidden(text,kind) && strings.has_prefix(text,"Tool failed: scene.set ·") && strings.has_suffix(text,"Unknown entity"),"got %q",text)
    call,ok=ai_call_parse(text)
    testing.expect(t,ok && call.method=="scene.set" && call.target=="" && call.failed && call.failure=="Unknown entity")
    text,_=ai_transcript_line(&task.transcript,2)
    call,ok=ai_call_parse(text)
    testing.expect(t,ok && call.target=="Floor Wet","a target never breaks the fields of its note")
    text,_=ai_transcript_line(&task.transcript,3)
    call,ok=ai_call_parse(text)
    testing.expectf(t,ok && call.target=="Crate" && call.failure=="Unknown field" && strings.contains(text," · ref 0x000000010000002a materials/floor.mat · +"),"the ids and paths a call names go after its target, got %q",text)
    testing.expect(t,task.dirty,"the calls are saved with the chat")
    buffer:[96]u8
    testing.expect_value(t,ai_call_target(&s,`{"name":"Crate","preset":"Cube"}`,buffer[:]),"Crate")
    testing.expect_value(t,ai_call_target(&s,`{"path":"materials/floor.mat"}`,buffer[:]),"floor.mat")
    testing.expect_value(t,ai_call_target(&s,`{"ids":[4,5,6]}`,buffer[:]),"3 entities")
    testing.expect_value(t,ai_call_target(&s,`{"calls":[{},{}]}`,buffer[:]),"2 calls")
    testing.expect_value(t,ai_call_target(&s,`not json`,buffer[:]),"")
    refs:[256]u8
    testing.expect_value(t,ai_call_refs(`{"path":"materials/floor.mat","ids":["0x2a","7",3]}`,refs[:]),"materials/floor.mat 0x000000000000002a 0x0000000000000007")
    testing.expect_value(t,ai_call_refs(`{"name":"Crate"}`,refs[:]),"")
}

@(test)
ai_answers_are_one_markdown_message_with_the_entities_they_name_as_pills :: proc(t:^testing.T) {
    mark,ok:=ai_entity_mark("[Point Light 1](entity:42) and more")
    testing.expect(t,ok && mark.name=="Point Light 1" && mark.id==42 && mark.end==len("[Point Light 1](entity:42)"))
    mark,ok=ai_entity_mark("[Crate](entity:0x965802afb68c0788)")
    testing.expect(t,ok && mark.id==0x965802afb68c0788,"an id as the API writes it")
    _,ok=ai_entity_mark("[Point Light 1](entity:) and more")
    testing.expect(t,!ok,"a mark needs its id")
    _,ok=ai_entity_mark("[a link](https://example.com)")
    testing.expect(t,!ok,"other links stay text")
    buffer:[256]u8
    testing.expect_value(t,ai_entity_marks_plain("Moved [Crate 4](entity:7) beside [Table](entity:9).",buffer[:]),"Moved Crate 4 beside Table.")
    testing.expect_value(t,ai_entity_marks_plain("No marks here",buffer[:]),"No marks here")
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    link:=ai_markdown_resolve(&s,"entity:4","Point Light 1",buffer[:])
    testing.expect(t,link.pill && !link.live,"an entity that is not in the scene is a pill that leads nowhere")
    link=ai_markdown_resolve(&s,"https://example.com","a page",buffer[:])
    testing.expect(t,!link.pill,"other links are not pills")
    // The lines of an answer are one message: its first line measures all of
    // it as Markdown, a block of code across lines included, and the rest take
    // no row.
    m.task_count=1;m.stick=true
    task:=&m.tasks[0];task.id=1;task.state=.Done
    tr:=&task.transcript
    ai_transcript_add(tr,"Light the table",.Prompt)
    ai_transcript_add(tr,"I added a light over [Table](entity:3):\n\n```odin\nlight := 1\n```\n\n- [Point Light 1](entity:4)",.Output)
    ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
    ai_transcript_draw(&s,m,task,400,300)
    painted:=ui.frame_end(&ctx)
    testing.expect(t,!painted.overflow && ctx.stats.layout_errors==0)
    shown:[AI_TRANSCRIPT_LINES]bool
    ai_transcript_shown(task,shown[:tr.count])
    message:=ai_message_text(tr,1,shown[:tr.count])
    testing.expect(t,strings.has_suffix(message,"](entity:4)") && strings.contains(message,"```odin\nlight := 1\n```"),"the lines of the answer join by their breaks")
    testing.expect_value(t,tr.heights[1],AI_MESSAGE_GAP+ui.markdown_height(&ctx,message,300,ai_markdown_style(&s,ctx.theme.font_small)))
    for index in 2..<tr.count {testing.expectf(t,tr.heights[index]==0,"line %d goes on the answer",index)}
}

@(test)
ai_chat_shows_each_turn_asked_and_its_last_message_and_one_line_while_it_runs :: proc(t:^testing.T) {
    task:=new(Ai_Task);defer free(task)
    tr:=&task.transcript
    ai_transcript_add(tr,"Make the floor rougher",.Prompt)
    ai_transcript_add(tr,"I look at the material first.",.Output)
    ai_transcript_add(tr,"Tool: material.set · +1.2 s · 9.0 ms",.Note)
    ai_transcript_add(tr,"Roughness is 0.8 now.\n\nThe sun no longer burns it.",.Output)
    ai_transcript_add(tr,"Less orange",.Prompt)
    ai_transcript_add(tr,"Checking the albedo.",.Output)
    ai_transcript_add(tr,"Tool: material.inspect · +0.4 s · 3.0 ms",.Note)
    task.state=.Running
    shown:[AI_TRANSCRIPT_LINES]bool
    steps:[AI_TRANSCRIPT_LINES]int
    doing:=ai_transcript_shown(task,shown[:tr.count],steps[:tr.count])
    testing.expect(t,shown[0] && !shown[1],"what was asked stays; the message before a call goes")
    testing.expect(t,shown[2] && steps[2]==1,"the calls of a turn that ended fold under its first one")
    testing.expect(t,shown[3] && shown[4] && shown[5],"the last message of a turn is shown whole")
    testing.expect(t,shown[6] && !shown[7] && !shown[8] && steps[8]==0,"the running turn shows nothing of its own, nor its steps")
    call,ok:=ai_call_parse(doing)
    testing.expect(t,ok && call.method=="material.inspect","the line of the running turn is its last call")
    task.state=.Done
    shown={};steps={}
    doing=ai_transcript_shown(task,shown[:tr.count],steps[:tr.count])
    testing.expect_value(t,doing,"")
    testing.expect(t,shown[7] && shown[8] && steps[8]==1,"a finished turn shows its last message and its steps")
}

@(test)
ai_history_lists_only_chats_without_a_row_and_says_how_long_ago :: proc(t:^testing.T) {
    testing.expect_value(t,ai_time_ago(20_000),"now")
    testing.expect_value(t,ai_time_ago(5*60_000),"5m")
    testing.expect_value(t,ai_time_ago(3*3_600_000),"3h")
    testing.expect_value(t,ai_time_ago(2*86_400_000),"2d")
    testing.expect_value(t,ai_time_ago(15*86_400_000),"2w")
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m}
    m.task_count=2
    m.tasks[0].id=1;m.tasks[0].state=.Running;m.tasks[0].conversation.kind=.Agent
    base.text_set(m.tasks[0].title[:],"Still working")
    m.tasks[1].id=2;m.tasks[1].state=.Done;m.tasks[1].review_finished=true;m.tasks[1].conversation.kind=.Agent
    base.text_set(m.tasks[1].title[:],"Long finished")
    ai_transcript_add(&m.tasks[1].transcript,"Long finished",.Prompt)
    ai_transcript_add(&m.tasks[1].transcript,"Moved [Crate](entity:3) aside.",.Output)
    ui.popup_open(&ctx,shell_id(&g,"ai_history_menu"),{0,0,100,24})
    for _ in 0..<2 {
        ui.frame_begin(&ctx,{size={800,600},pointer_absent=true})
        ai_chat_history_build(&s,280)
        ui.frame_end(&ctx)
    }
    testing.expect(t,ai_chat_test_paint(&ctx,"Still working")==nil,"a chat at work keeps its row over the chat and stays out of History")
    testing.expect(t,ai_chat_test_paint(&ctx,"Long finished")!=nil,"a finished chat is in History")
    testing.expect(t,ai_chat_test_paint(&ctx,"Moved Crate aside.")!=nil,"a chat of History says what its agent answered last")
}

@(test)
ai_sessions_say_what_they_wait_for_and_are_answered_in_their_thread :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    m.task_count=4
    titles:=[4]string{"Warm lights","Waving robot","Tidy the crates","Clear the boxes"}
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.icon=u8(index);task.color_index=u8(index)
        task.state=index==0 || index==3?.Running:.Done
        base.text_set(task.title[:],titles[index])
        base.text_set(task.agent[:],"codex")
        ai_transcript_add(&task.transcript,titles[index],.Prompt)
    }
    m.tasks[1].question=.Single
    m.tasks[1].options_length=copy(m.tasks[1].options[:],"2 m\n3 m")
    for path in ([2]string{"lights.mat","fog.mat"}) {append(&m.tasks[2].review.changed_files,strings.clone(path))}
    m.tasks[2].review.pending=true
    defer for &task in m.tasks[:m.task_count] {ai_review_free(&task.review)}
    m.workers[0].task=4;m.workers[1].task=1
    p:=&m.permissions[0];m.permission_count=1
    p.worker=0;p.count=2
    base.text_set(p.title[:],"Delete 3 entities")
    base.text_set(p.ids[0][:],"allow");base.text_set(p.names[0][:],"Allow")
    base.text_set(p.ids[1][:],"reject");base.text_set(p.names[1][:],"Reject")
    m.connections[AI_CODEX].configured=true
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-luna")
    frame :: proc(s:^Session,pointer:[2]f32={},pressed:bool=false) {
        ui.frame_begin(s.gui.ctx,{size={800,600},pointer=pointer,pointer_absent=pointer=={},pressed={.Left} if pressed else {},down={.Left} if pressed else {}})
        ai_chat_content_build(s,280,560)
        painted:=ui.frame_end(s.gui.ctx)
        assert(!painted.overflow && s.gui.ctx.stats.layout_errors==0)
    }
    m.selected=4
    m.agents_open=true
    frame(&s);frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"!")!=nil && ai_chat_test_paint(&ctx,"?")!=nil && ai_chat_test_paint(&ctx,"2")!=nil,"the rows say a permission, a question and how many changes wait")
    testing.expect(t,ai_chat_test_paint(&ctx,"Allow")!=nil && ai_chat_test_paint(&ctx,"Reject")!=nil,"the permission is answered in the thread")
    _,modal:=ui.widget_rect(&ctx,shell_id(&g,"ai_permission"))
    testing.expect(t,!modal,"a permission is no dialog")
    testing.expect(t,ai_chat_test_paint(&ctx,"Luna 6")!=nil && ai_chat_test_paint(&ctx,"GPT-6 Luna")==nil,"the composer shows the short name of the model")
    // The review of a session is folded: how many changes, Revert all and Accept all.
    m.selected=3
    frame(&s);frame(&s)
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    header_id:=ui.id(&ctx,"review_header")
    row_id:=ui.id(&ctx,"review_change",0)
    keep_id:=ui.id(&ctx,"review_change_keep",0)
    revert_id:=ui.id(&ctx,"revert")
    ui.id_pop(&ctx)
    header,header_found:=ui.widget_rect(&ctx,header_id)
    _,row_found:=ui.widget_rect(&ctx,row_id)
    _,revert_found:=ui.widget_rect(&ctx,revert_id)
    testing.expect(t,header_found && revert_found && !row_found && ai_chat_test_paint(&ctx,"2 changes")!=nil && ai_chat_test_paint(&ctx,"Accept all")!=nil,"the review starts folded with its actions in sight")
    frame(&s,ui.rect_center(header),true);frame(&s)
    row,found:=ui.widget_rect(&ctx,row_id)
    testing.expect(t,found && m.review_open,"its head unfolds a row per change")
    frame(&s,ui.rect_center(row));frame(&s,ui.rect_center(row))
    keep,keep_found:=ui.widget_rect(&ctx,keep_id)
    testing.expect(t,keep_found,"a row offers to keep its change while the pointer is on it")
    frame(&s,ui.rect_center(keep),true)
    // Without transactions behind them, keeping one change leaves none: the review ends and says how.
    testing.expect_value(t,ai_transcript_line_last(&m.tasks[2].transcript),"Reviewed · 1 kept")
}

@(test)
ai_sessions_keep_their_own_model_and_a_new_one_takes_that_of_its_agent :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.connections[AI_CODEX].configured=true
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-luna")
    base.text_set(m.connections[AI_CODEX].effort[:],"low")
    base.text_set(m.agent[:],"codex")
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.state=.Done
    c:=&task.conversation;c.id=1
    ai_store.conversation_set_text(c.provider[:],&c.provider_len,"codex")
    ai_store.conversation_set_text(c.model[:],&c.model_len,"gpt-6.1-sol")
    ai_store.conversation_set_text(c.effort[:],&c.effort_len,"high")
    m.selected=1
    model,effort:=ai_chat_model(m)
    testing.expect(t,model=="gpt-6.1-sol" && effort=="high","a session shows its own model")
    testing.expect_value(t,ai_model_name(m,AI_CODEX,model),"Sol 6.1")
    m.selected=0
    model,effort=ai_chat_model(m)
    testing.expect(t,model=="gpt-6-luna" && effort=="low","a new session takes those of its agent")
}

@(private="file")
ai_chat_test_frame :: proc(s:^Session,pointer:[2]f32={},pressed:=false,height:f32=560) {
    ui.frame_begin(s.gui.ctx,{size={800,600},pointer=pointer,pointer_absent=pointer=={},pressed={.Left} if pressed else {},down={.Left} if pressed else {}})
    ai_chat_bar_buttons(s)
    ai_chat_content_build(s,280,height)
    painted:=ui.frame_end(s.gui.ctx)
    assert(!painted.overflow && s.gui.ctx.stats.layout_errors==0)
}

// A main chat and a running and a finished subagent, the second with two changes.
@(private="file")
ai_chat_test_units :: proc(m:^Ai) {
    m.task_count,m.main,m.selected=3,1,1
    titles:=[3]string{"The arena","Cover","Wood texture"}
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.color_index=u8(index);task.state=index==1?.Running:.Done
        task.conversation.id=u64(index+1)
        base.text_set(task.title[:],titles[index])
        base.text_set(task.agent[:],"codex")
        if index>0 {task.conversation.kind,task.conversation.parent=.Agent,1}
        ai_transcript_add(&task.transcript,titles[index],.Prompt)
    }
    m.workers[0].task=2
    m.connections[AI_CODEX].configured=true
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-luna")
    ai_transcript_add(&m.tasks[2].transcript,"Both crates use Dark oak.",.Output)
    for path in ([2]string{"crate.mat","floor.mat"}) {append(&m.tasks[2].review.changed_files,strings.clone(path))}
    m.tasks[2].review.pending=true
}

@(test)
ai_chat_has_one_status_line_and_no_new_chat_button :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    ai_chat_test_units(m)
    defer for &task in m.tasks[:m.task_count] {ai_review_free(&task.review)}
    ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"1 agent working · 2 changes to review")!=nil,"one line says what the agents do")
    for &paint in ctx.paints[:ctx.paint_count] {testing.expect(t,paint.icon!=.Plus,"there is nothing to start")}
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    status_id:=ui.id(&ctx,"agent_status")
    row_id:=ui.id(&ctx,"agent_task",3)
    ui.id_pop(&ctx)
    _,row_found:=ui.widget_rect(&ctx,row_id)
    testing.expect(t,!row_found,"the list starts folded")
    status,_:=ui.widget_rect(&ctx,status_id)
    ai_chat_test_frame(&s,ui.rect_center(status),true);ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    row,found:=ui.widget_rect(&ctx,row_id)
    testing.expect(t,found && m.agents_open,"the line unfolds to the units")
    ai_chat_test_frame(&s,ui.rect_center(row),true)
    testing.expect(t,m.selected==3,"a click on a finished one inspects it")
    m.selected=1;m.tasks[1].state=.Done;m.tasks[2].review_finished=true;m.tasks[1].review_finished=true
    ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    _,found=ui.widget_rect(&ctx,status_id)
    testing.expect(t,!found,"with nothing to say the line goes")
}

@(test)
ai_a_finished_subagent_is_a_card_in_the_thread_of_the_main_chat :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    ai_chat_test_units(m)
    defer for &task in m.tasks[:m.task_count] {ai_review_free(&task.review)}
    ai_transcript_add(&m.tasks[0].transcript,"3",.Report)
    ai_transcript_add(&m.tasks[0].transcript,"Editor reopened",.Divider)
    ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"Wood texture finished")!=nil,"its title")
    testing.expect(t,ai_chat_test_paint(&ctx,"Both crates use Dark oak.")!=nil,"its answer")
    testing.expect(t,ai_chat_test_paint(&ctx,"2 changes")!=nil && ai_chat_test_paint(&ctx,"Reply")!=nil && ai_chat_test_paint(&ctx,"Request changes")==nil,"what is done about it")
    testing.expect(t,ai_chat_test_paint(&ctx,"Editor reopened")!=nil,"a divider is drawn")
    testing.expect(t,ai_chat_test_paint(&ctx,"Accept all")==nil,"a subagent has no bar over the composer")
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    ui.id_push(&ctx,ui.id(&ctx,"report",3))
    ask_id:=ui.id(&ctx,"reply")
    finish_id:=ui.id(&ctx,"finish")
    ui.id_pop(&ctx)
    ui.id_pop(&ctx)
    ask,_:=ui.widget_rect(&ctx,ask_id)
    ai_chat_test_frame(&s,ui.rect_center(ask),true)
    testing.expect(t,m.about==3,"Reply attaches the unit to the next message")
    ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    finish,_:=ui.widget_rect(&ctx,finish_id)
    ai_chat_test_frame(&s,ui.rect_center(finish),true)
    testing.expect(t,m.tasks[2].review_finished,"its card keeps what it changed")
    // Without the subagent in memory the card still says what it was.
    m.tasks[2].id,m.tasks[2].state=9,.Done
    base.text_set(m.reports[0].text[:],"Kept from the conversation")
    m.reports[0].id,m.reports[0].length=3,len("Kept from the conversation")
    ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"Kept from the conversation")!=nil,"the answer survives the task")
}

@(test)
ai_a_subagent_is_inspected_from_its_own_view_and_written_to :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}));defer ui.context_destroy(&ctx)
    g:=Editor_Ui{ctx=&ctx}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{gui=&g,ai=m,has_project=true}
    ai_chat_test_units(m)
    defer for &task in m.tasks[:m.task_count] {ai_review_free(&task.review)}
    ai_transcript_add(&m.tasks[1].transcript,"Moving the blocks",.Output)
    m.selected=2
    ai_chat_test_frame(&s);ai_chat_test_frame(&s)
    testing.expect(t,ai_chat_test_paint(&ctx,"Main chat")!=nil && ai_chat_test_paint(&ctx,"Working")!=nil,"the way back and its state")
    named:=false
    for &paint in ctx.paints[:ctx.paint_count] {named|=paint.placeholder=="Message Cover..."}
    testing.expect(t,named,"the composer names it")
    testing.expect(t,ai_chat_test_paint(&ctx,"Luna 6")==nil,"no selector of the model")
    ui.id_push(&ctx,shell_id(&g,"ai_chat"))
    _,stop_found:=ui.widget_rect(&ctx,ui.id(&ctx,"stop"))
    ui.id_pop(&ctx)
    testing.expect(t,stop_found,"empty and busy it stops")
    m.prompt_length=copy(m.prompt[:],"Keep the cover low")
    testing.expect(t,ai_chat_send(&s)==false || m.prompt_length==0,"a running subagent takes the message")
    testing.expect_value(t,ai_transcript_line_last(&m.tasks[1].transcript),"Keep the cover low")
    testing.expect(t,m.tasks[1].state==.Running,"it does not interrupt the agent")
}

@(private="file")
ai_transcript_line_last :: proc(t:^Ai_Transcript) -> string {
    text,_:=ai_transcript_line(t,t.count-1)
    return text
}

@(test)
ai_answers_name_assets_as_pills_that_open_them :: proc(t:^testing.T) {
    mark,ok:=ai_entity_mark("[Wet stone](asset:materials/Wet stone.mat) is ready")
    testing.expect(t,ok && mark.name=="Wet stone" && mark.asset=="materials/Wet stone.mat" && mark.id==0,"a path with spaces ends at its parenthesis")
    testing.expect_value(t,mark.end,len("[Wet stone](asset:materials/Wet stone.mat)"))
    _,ok=ai_entity_mark("[Empty](asset:)")
    testing.expect(t,!ok,"an asset mark needs its path")
    buffer:[64]u8
    testing.expect_value(t,ai_entity_marks_plain("Open [Wet stone](asset:materials/Wet stone.mat).",buffer[:]),"Open Wet stone.")
}
