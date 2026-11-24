package anim

import "core:testing"
import "mirai:core"
import "mirai:engine/save"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

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

@(private)
@(test_world)
Progress_Save_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    hierarchy:core.Hierarchy,
    animations:core.Table(Animation),
    progress:core.Table(Animation_Progress),
    playback:Playback,
}

// A saved game keeps where the clip of each entity was, which Playback writes in the snapshot of
// the save and not in the World: a clip that plays, plays backwards or holds comes back from the
// slot as it was, one previewed in the editor or of an entity without Animation does not, and
// the Animation_Progress the World holds stays as it was.
@(test)
a_saved_world_brings_back_where_its_clips_were :: proc(t:^testing.T) {
    Case :: struct {progress:Animation_Progress,animated,previewed:bool,live:Maybe(Animation_Progress),saved:bool}
    run:=Clip_Selection{clip=base.name_hash("run"),fade=.25,loop=true}
    cases:=[]Case{
        {progress={time=1.5,selection=run,speed=1,playing=true},animated=true,saved=true},
        {progress={time=.25,selection=run,speed=-1,playing=true},animated=true,saved=true},
        {progress={time=2,speed=1},animated=true,saved=true},
        {progress={time=1.5,speed=1,playing=true},animated=true,live=Animation_Progress{time=.5,speed=1},saved=true},
        {progress={time=1,speed=1,playing=true},animated=true,previewed=true},
        {live=Animation_Progress{time=.5,speed=1}},
    }
    for c,i in cases {
        info,described:=test_info(t,Progress_Save_World)
        if !described {return}
        defer test_info_destroy(&info)
        app:=host.App{info=&info,allocator=context.allocator}
        w:=cast(^Progress_Save_World)host.app_world_create(&app)
        if !testing.expect(t,w!=nil) {return}
        defer {host.app_world_free(&app,w);delete(app.worlds)}
        e:=core.create(&w.entities)
        core.add(&w.ids,e,{7})
        if c.animated {core.add(&w.animations,e,ANIMATION_DEFAULT)}
        if live,ok:=c.live.?;ok {core.add(&w.progress,e,live)}
        core.settle(&info,w,nil)
        if c.animated {
            state:=state_get(&w.playback,e)
            state.clip,state.time,state.selection=0,c.progress.time,c.progress.selection
            state.speed,state.playing=c.progress.speed,c.progress.playing
        }
        w.playback.previewed=c.previewed
        ref:=host.app_world_ref(&app,w)
        version,states:=w.progress.version,len(w.playback.states)
        out:serial.Writer
        serial.writer_init(&out)
        defer serial.writer_destroy(&out)
        if !testing.expectf(t,save.capture(ref,nil,context.allocator,&out)==.None,"case %d: captured",i) {continue}
        kept,found:=core.get(&w.progress,e)
        testing.expectf(t,w.progress.version==version && len(w.progress.pending)==0 && found==(c.live!=nil) && (!found || kept==c.live.?),"case %d: the World keeps its progress",i)
        testing.expectf(t,len(w.playback.states)==states,"case %d: Playback is not written",i)
        if !testing.expectf(t,save.restore(ref,&app,serial.writer_bytes(&out))==.None,"case %d: restored",i) {continue}
        saved,in_slot:=core.get(&w.progress,core.entity_of(&w.entities,7))
        testing.expectf(t,in_slot==c.saved && (!in_slot || saved==c.progress),"case %d: the slot holds %v, not %v",i,saved,c.progress)
    }
}
