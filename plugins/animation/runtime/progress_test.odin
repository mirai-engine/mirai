package anim

import "core:testing"
import "mirai:core"
import "mirai:std/base"

@(private)
@(test_world)
Progress_World :: struct {
    using world:Test_World,
    animations:core.Table(Animation),
    progress:core.Table(Animation_Progress),
    requests:Animation_Requests,
    playback:Playback,
}

// The time of a clip goes to Animation_Progress, which a saved game keeps;
// when the World loads, Playback starts again and the clip seeks it.
@(test)
a_loaded_clip_seeks_the_progress_its_entity_kept :: proc(t:^testing.T) {
    w:Progress_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    e:=core.create(&w.entities)
    core.add(&w.animations,e,ANIMATION_DEFAULT);test_world_settle(&w)
    state:=state_get(&w.playback,e)
    state.clip,state.time=0,1.5
    state.playing,state.speed=true,-1
    state.selection={clip=base.name_hash("run"),fade=.25,loop=true}
    testing.expect(t,core.world_prepare_save(test_world_ref(&w)))
    test_world_settle(&w)
    kept,found:=core.get(&w.progress,e)
    testing.expect(t,found && kept.time==1.5)
    version:=core.version(&w.progress)
    state.time=2
    testing.expect_value(t,core.version(&w.progress),version)
    testing.expect(t,core.world_prepare_save(test_world_ref(&w)))
    test_world_settle(&w)
    latest,_:=core.get(&w.progress,e)
    testing.expect_value(t,latest.time,f32(2))

    playback_free(&w.playback)
    state=state_get(&w.playback,e)
    animation:=ANIMATION_DEFAULT
    edit:=clip_control(state,&animation,nil,true,nil,nil,nil,nil,nil,kept)
    testing.expect(t,edit.seek==1.5 && animation.playing && animation.speed==-1)
    testing.expect(t,state.selection.clip==base.name_hash("run") && animation.loop && animation.fade==.25)

    core.remove(&w.animations,e);test_world_settle(&w)
    testing.expect(t,core.world_prepare_save(test_world_ref(&w)))
    test_world_settle(&w)
    testing.expect(t,!core.has(&w.progress,e))
}
