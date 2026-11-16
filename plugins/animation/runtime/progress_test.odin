package anim

import "core:testing"
import "mirai:core"

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
    progress_write(&w.progress,&w.animations,&w.playback)
    test_world_settle(&w)
    kept,found:=core.get(&w.progress,e)
    testing.expect(t,found && kept.time==1.5)

    progress_resume(&w.progress,&w.playback,&w.requests)
    testing.expect_value(t,len(w.requests.timeline.items),0)
    playback_free(&w.playback);w.playback={}
    progress_resume(&w.progress,&w.playback,&w.requests)
    items:=w.requests.timeline.items[:]
    testing.expect(t,len(items)==2 && items[0]==Animation_Command{e,0,1,.Pause} && items[1]==Animation_Command{e,1.5,1,.Seek})
    // Whether it played, and at what speed, comes back with it.
    clear(&w.requests.timeline.items)
    progress:=core.edit(&w.progress,e);progress.playing,progress.speed=true,-1
    progress_resume(&w.progress,&w.playback,&w.requests)
    testing.expect(t,len(w.requests.timeline.items)==2 && w.requests.timeline.items[0]==Animation_Command{e,0,-1,.Resume})

    core.remove(&w.animations,e);test_world_settle(&w)
    progress_write(&w.progress,&w.animations,&w.playback)
    test_world_settle(&w)
    testing.expect(t,!core.has(&w.progress,e))
}
