package editor

import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import "mirai:ui"

// A tick that moves the entity of the test as its input says: a frame played
// again has to give it the same input to leave it where it was.
@(private="file")
history_test_tick :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Play_Test_World)data
    play_test_ticks(data,app).count+=1
    for &transform in core.writable(&w.transforms) {transform.position.x+=.W in w.input.keys_down?1:0.25}
}

// A step of a run with W held or not, as play.step gives it.
@(private="file")
history_step :: proc(f:^Play_Test,r:^Run,held:bool) {
    r.step=true
    if held {r.input,r.has_input={keys_down={.W},keys_pressed={.W}},true}
    platform.frame_begin(f.p)
    game_frame(&f.s)
}

// Read, not written: a write between frames is an edit.
@(private="file")
history_x :: proc(f:^Play_Test,r:^Run) -> f32 {
    transform,_:=core.get(core.read(&(cast(^Play_Test_World)r.world).transforms),f.original)
    return transform.position.x
}

@(test)
a_run_goes_to_any_frame_it_played_and_plays_on_from_there :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    testing.expect(t,play_start(s,false,7))
    r:=run_find(s,7)
    w:=cast(^Play_Test_World)r.world
    // The first frame makes the first keyframe; then one every four ticks.
    history_step(f,r,true)
    r.history.interval=4
    played:[13]f32
    played[1]=history_x(f,r)
    for tick in 2..=12 {
        history_step(f,r,tick%3==0)
        played[tick]=history_x(f,r)
    }
    testing.expect_value(t,r.history.count,3) // ticks 1, 5 and 9
    oldest,newest,_,_,ok:=history_span(r.history)
    testing.expect(t,ok && oldest==1 && newest==12)
    // Back to tick 7: the keyframe of tick 5 and two frames played again with their input.
    seek:=history_seek(s,r,history_frame_for(r.history,7))
    testing.expect(t,seek.ok && seek.matches)
    testing.expect_value(t,seek.replayed,2)
    testing.expect_value(t,w.time.tick,u64(7))
    testing.expect_value(t,w.ticks.count,7)
    testing.expect_value(t,history_x(f,r),played[7])
    // On from where it is, without going back to the keyframe.
    seek=history_seek(s,r,history_frame_for(r.history,8))
    testing.expect(t,seek.ok && seek.matches && seek.replayed==1)
    testing.expect_value(t,history_x(f,r),played[8])
    // Every tick it played, either way.
    for tick in ([]u64{12,2,10,1,6}) {
        seek=history_seek(s,r,history_frame_for(r.history,tick))
        testing.expectf(t,seek.ok && seek.matches && w.time.tick==tick && history_x(f,r)==played[tick],"tick %d: %v at %d, x %f",tick,seek,w.time.tick,history_x(f,r))
    }
    testing.expect(t,history_frame_for(r.history,0)==0,"nothing before the first frame")
    // Playing on from tick 6 drops the past that was after it.
    history_step(f,r,true)
    _,newest,_,_,_=history_span(r.history)
    testing.expect_value(t,newest,u64(7))
    testing.expect_value(t,r.history.count,2)
    testing.expect_value(t,history_x(f,r),played[6]+1)
}

@(test)
a_frame_changed_from_outside_its_input_while_it_plays_does_not_match_when_played_again :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    // Not paused, a frame of the window is six ticks.
    testing.expect(t,play_start(s))
    r:=run_find(s,0)
    history_step(f,r,false)
    r.history.interval=100
    history_step(f,r,false)
    // An edit between frames of a game that plays is not in what the frames gave the World.
    core.get(&(cast(^Play_Test_World)r.world).transforms,f.original).position.y=3
    history_step(f,r,false)
    play_pause(s,true)
    seek:=history_seek(s,r,history_frame_for(r.history,12))
    testing.expect(t,seek.ok && seek.matches)
    seek=history_seek(s,r,history_frame_for(r.history,18))
    testing.expect(t,seek.ok && !seek.matches)
}

@(test)
the_keyframes_of_a_history_fit_its_memory_and_span_its_time :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    // Ten ticks of 1/60 s.
    settings:=Play_History{on=true,seconds=10.0/60,megabytes=1}
    s.play_history=&settings
    testing.expect(t,play_start(s,false,7) && play_start(s,false,8))
    measured:=run_find(s,7)
    history_step(f,measured,false)
    one:=history_bytes(measured.history)
    // A budget of three copies: one every four ticks spans the ten.
    r:=run_find(s,8)
    testing.expect(t,history_of(s,r)!=nil)
    r.history.budget=one*3+one/2
    for _ in 1..=12 {history_step(f,r,false)}
    testing.expect_value(t,r.history.interval,u64(4))
    oldest,newest,_,_,_:=history_span(r.history)
    testing.expect(t,oldest==1 && newest==12 && r.history.count==3)
    history_step(f,r,false)
    oldest,_,_,_,_=history_span(r.history)
    testing.expect(t,oldest==5 && r.history.count==3)
    testing.expect(t,history_bytes(r.history)<=r.history.budget)
    // A smaller budget leaves the newest copies that fit.
    r.history.budget=one*2+one/2
    for _ in 1..=8 {history_step(f,r,false)}
    testing.expect(t,r.history.count==2 && r.history.limit==2 && history_bytes(r.history)<=r.history.budget)
    seek:=history_seek(s,r,history_frame_for(r.history,19))
    testing.expect(t,seek.ok && seek.matches)
}

@(test)
a_run_keeps_no_history_when_it_is_off_or_on_the_network :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    settings:=Play_History{on=false,seconds=1,megabytes=16}
    s.play_history=&settings
    testing.expect(t,play_start(s,false,7))
    r:=run_find(s,7)
    history_step(f,r,false)
    testing.expect(t,r.history==nil)
    testing.expect(t,history_reason(s,r)!="")
}

@(test)
an_edit_where_a_run_went_back_is_kept_as_a_keyframe_and_drops_the_frames_after_it :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    testing.expect(t,play_start(s,false,7))
    r:=run_find(s,7)
    w:=cast(^Play_Test_World)r.world
    history_step(f,r,false)
    r.history.interval=4
    for _ in 2..=12 {history_step(f,r,false)}
    testing.expect(t,history_seek(s,r,history_frame_for(r.history,6)).ok)
    // Stepping without an edit keeps its keyframes: the frame played again is the one it had.
    keys:=r.history.count
    history_step(f,r,false)
    testing.expect_value(t,r.history.count,keys-1) // the keyframe of tick 9 led past the frame now played
    testing.expect(t,history_seek(s,r,history_frame_for(r.history,6)).ok)
    edited:=history_x(f,r)+100
    core.get(&w.transforms,f.original).position.x=edited
    history_step(f,r,false)
    _,newest,_,_,_:=history_span(r.history)
    testing.expect_value(t,newest,u64(7))
    // Back to the tick of the edit, and to the one after it, from any frame: the edit is there.
    seek:=history_seek(s,r,history_frame_for(r.history,1))
    seek=history_seek(s,r,history_frame_for(r.history,6))
    testing.expect(t,seek.ok && seek.matches)
    testing.expect_value(t,history_x(f,r),edited)
    seek=history_seek(s,r,history_frame_for(r.history,7))
    testing.expect(t,seek.ok && seek.matches && seek.replayed==1)
    testing.expect_value(t,history_x(f,r),edited+0.25)
}

// Content loaded again while a game plays is an edit: the World of the frame before it becomes a
// keyframe of an edit, as the frames before it read what the reload replaced.
@(test)
content_loaded_again_while_a_run_plays_is_kept_as_a_keyframe_of_an_edit :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    testing.expect(t,play_start(s))
    r:=run_find(s,0)
    history_step(f,r,false)
    r.history.interval=100
    history_step(f,r,false)
    keys:=r.history.count
    content:host.Content
    f.app.content=&content
    defer f.app.content=nil
    // What a reload leaves: the newest generation is a reload.
    content.generations,content.reloaded=1,1
    history_step(f,r,false)
    if !testing.expect_value(t,r.history.count,keys+1) {return}
    key:=history_at(r.history,r.history.count-1)
    testing.expect(t,key.edited && key.frame==2)
    history_step(f,r,false)
    testing.expect_value(t,r.history.count,keys+1)
}

@(test)
a_paused_play_resumes_from_its_newest_frame_or_from_where_it_went_back :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    testing.expect(t,play_start(s))
    play_pause(s,true)
    r:=run_find(s,0)
    w:=cast(^Play_Test_World)r.world
    for _ in 1..=10 {history_step(f,r,false)}
    newest:=history_x(f,r)
    testing.expect(t,history_seek(s,r,history_frame_for(r.history,4)).ok)
    // Resume goes back to the newest frame, and an edit made where it went back is dropped.
    core.get(&w.transforms,f.original).position.x+=100
    play_pause(s,false)
    testing.expect(t,s.mode==.Play && w.time.tick==10 && history_x(f,r)==newest)
    play_pause(s,true)
    testing.expect(t,history_seek(s,r,history_frame_for(r.history,4)).ok)
    at_four:=history_x(f,r)
    // From here: the frames after it go, the edit stays and the next frame starts from it.
    core.get(&w.transforms,f.original).position.x+=100
    play_pause(s,false,here=true)
    _,last,_,_,_:=history_span(r.history)
    testing.expect(t,s.mode==.Play && w.time.tick==4 && last==4 && history_x(f,r)==at_four+100)
    play_pause(s,true)
    history_step(f,r,false)
    testing.expect_value(t,w.time.tick,u64(5))
    seek:=history_seek(s,r,history_frame_for(r.history,4))
    testing.expect(t,seek.ok && seek.matches && history_x(f,r)==at_four+100)
}

@(test)
what_the_mouse_does_while_a_play_is_paused_does_not_reach_it_when_it_resumes :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    testing.expect(t,play_start(s))
    play_pause(s,true)
    for _ in 0..<3 {
        platform.input_inject(f.p,platform.Mouse_Motion_Event{position={100,100},delta={200,0}})
        platform.input_inject(f.p,platform.Mouse_Button_Event{button=.Left,down=true,position={100,100}})
        platform.frame_begin(f.p)
        play_input_update(s)
        game_frame(s)
    }
    play_pause(s,false)
    platform.frame_begin(f.p)
    tick:=platform.input_tick_take(f.p)
    testing.expect(t,tick.mouse_delta=={} && tick.mouse_pressed=={},"the first tick after the pause gets what the mouse did while it lasted")
}

@(test)
the_strip_plays_the_past_again_at_the_pace_of_the_clock_with_the_game_paused :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    testing.expect(t,play_start(s))
    play_pause(s,true)
    r:=run_find(s,0)
    w:=cast(^Play_Test_World)r.world
    for _ in 1..=10 {history_step(f,r,false)}
    testing.expect(t,history_seek(s,r,history_frame_for(r.history,2)).ok)
    // A frame of the window is 0.1 s: six ticks.
    s.history_playback={playing=true}
    platform.frame_begin(f.p)
    play_history_seek(s)
    testing.expect(t,w.time.tick==8 && play_paused(s) && s.history_playback.playing)
    platform.frame_begin(f.p)
    play_history_seek(s)
    _,newest,_,_,_:=history_span(r.history)
    testing.expect(t,w.time.tick==10 && newest==10 && !s.history_playback.playing,"it stops at the newest frame, which it keeps")
    // Looping, it goes on from the oldest.
    testing.expect(t,history_seek(s,r,history_frame_for(r.history,8)).ok)
    s.history_playback={playing=true,loop=true}
    platform.frame_begin(f.p)
    play_history_seek(s)
    oldest,_,_,_,_:=history_span(r.history)
    testing.expect(t,w.time.tick==oldest && s.history_playback.playing)
}

@(test)
space_plays_and_stops_the_strip_of_the_past_unless_a_text_field_takes_it :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    f.info.loops[.Game][.Fixed]=history_test_tick
    settings:=PLAY_HISTORY_DEFAULT
    s.play_history=&settings
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{draw_user=draw_user}))
    defer ui.context_destroy(&ctx)
    f.gui.ctx=&ctx
    defer f.gui.ctx=nil
    testing.expect(t,play_start(s))
    play_pause(s,true)
    r:=run_find(s,0)
    for _ in 1..=4 {history_step(f,r,false)}
    space :: proc(f:^Play_Test) {editor_shortcuts(&f.s,&f.gui,&f.viewport,{.Space},{},0,false)}
    ctx.edit.id=0x1234
    space(f)
    testing.expect(t,!s.history_playback.playing,"A text field being edited takes Space")
    ctx.edit={}
    space(f)
    testing.expect(t,s.history_playback.playing && s.history_seek!=0,"At the end it plays from the start")
    space(f)
    testing.expect(t,!s.history_playback.playing,"And Space stops it")
    // While the game plays, Space is its own.
    play_pause(s,false)
    space(f)
    testing.expect(t,!s.history_playback.playing && s.mode==.Play)
}
