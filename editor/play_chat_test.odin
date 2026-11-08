package editor

import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import "mirai:ui"

@(private="file")
Play_Chat_Input_World :: struct {time:core.Time,input:core.Input,frame:core.Frame_Input,frame_time:core.Frame_Time}

// While the game plays Tab is its own and the chat stays closed; in the pause
// Tab opens it, and resuming closes it and gives the capture back.
@(test)
the_chat_opens_only_while_the_game_is_paused :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    storages:=[4]core.Storage_Info{
        {type=core.Time,offset=offset_of(Play_Chat_Input_World,time)},
        {type=core.Input,offset=offset_of(Play_Chat_Input_World,input)},
        {type=core.Frame_Input,offset=offset_of(Play_Chat_Input_World,frame)},
        {type=core.Frame_Time,offset=offset_of(Play_Chat_Input_World,frame_time)},
    }
    info:=core.World_Info{storages=storages[:]}
    app:=host.App{info=&info,platform=p,tick_dt=1.0/60,max_ticks=8,game_input_excluded={.F1}}
    defer delete(app.worlds)
    world:Play_Chat_Input_World
    viewport:Viewport
    gui:=Editor_Ui{ctx=&ctx}
    ai:=new(Ai);defer free(ai)
    s:=Session{mode=.Play,app=&app,info=&info,gui=&gui,ai=ai,viewport=&viewport}
    s.runs[0]={world=&world}
    key :: proc(s:^Session,p:^platform.Platform,key:core.Key,down:bool) {
        platform.input_inject(p,platform.Key_Event{key=key,down=down})
        platform.frame_begin(p)
        s.app.ui_input=host.ui_input_from_platform(platform.input_frame(p))
        play_input_update(s)
    }
    platform.window_set_relative_mouse(p,true)
    platform.input_inject(p,platform.Key_Event{key=.W,down=true})
    key(&s,p,.Tab,true)
    testing.expect(t,!s.play_chat_open && !ai.chat_open && !s.play_input_released && !app.game_input_blocked)
    game_frame(&s)
    testing.expect(t,.Tab in world.input.keys_down && .W in world.input.keys_down)
    // The AI action, or a chat asked from elsewhere, does not open it either.
    play_chat_set(&s,true)
    testing.expect(t,!s.play_chat_open && !ai.chat_open && platform.window_relative_mouse(p))
    key(&s,p,.Tab,false)

    play_pause(&s,true)
    key(&s,p,.Tab,true)
    testing.expect(t,s.play_chat_open && ai.chat_open && ai.focus)
    testing.expect(t,gui.layout.left_open && gui.layout.library_tab==.Ai)
    testing.expect(t,s.play_input_released && app.game_input_blocked && !platform.window_relative_mouse(p))
    testing.expect(t,.Tab not_in app.ui_input.keys_repeated)
    shortcuts_run(&s,{.Tab},{})
    testing.expect(t,gui.layout.left_open,"Tab is not the key of the content browser in the pause")
    key(&s,p,.Tab,false)
    ctx.edit.id=0x1234
    play_pause(&s,false)
    testing.expect(t,!s.play_chat_open && !ai.chat_open && !gui.layout.left_open && ctx.edit.id==0)
    testing.expect(t,s.mode==.Play && !s.play_input_released && !platform.window_relative_mouse(p))
    // Playing again the mouse is the game's, which captures it in its frame.
    testing.expect(t,app.game_mouse_off,"the frame that resumed is still the editor's")
    key(&s,p,.Tab,false)
    testing.expect(t,!app.game_mouse_off)
}
