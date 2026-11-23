package audio

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import sdl "vendor:sdl3"

@(private="file") HUM :: base.Asset_Id{1,1}
@(private="file") STEP_A :: base.Asset_Id{2,2}
@(private="file") STEP_B :: base.Asset_Id{3,3}
@(private="file") STEPS :: base.Asset_Id{4,4}

// Two short .sound files and a .sound_set of both, in a folder of assets the
// application loads them from.
@(private="file")
Fixture :: struct {
    assets:host.Assets,
    app:host.App,
}

@(private="file")
fixture_init :: proc(t:^testing.T,f:^Fixture,set:asset.Sound_Set_Info=asset.SOUND_SET_DEFAULTS) -> bool {
    root:=base.test_folder(t,"engine-audio")
    if root=="" {return false}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    samples:=make([]i16,4800,context.temp_allocator)
    for &sample in samples {sample=8000}
    lossless,coded:=mixer.lossless_encode(samples,1,48000,context.temp_allocator)
    if !testing.expect_value(t,coded,mixer.Error.None) {return false}
    for sound in ([3]struct{id:base.Asset_Id,name:string}{{HUM,"hum"},{STEP_A,"step_a"},{STEP_B,"step_b"}}) {
        desc:=asset.Sound_Desc{id=sound.id,channels=1,sample_rate=48000,frames=len(samples),lossless=lossless}
        if !testing.expect_value(t,asset.sound_save(fmt.tprintf("%s/%s.sound",root,sound.name),&types,desc),asset.Error.None) {return false}
    }
    info:=set
    info.sounds[0].sound,info.sounds[1].sound=STEP_A,STEP_B
    if !testing.expect_value(t,asset.sound_set_save(fmt.tprintf("%s/steps.sound_set",root),&types,{id=STEPS,info=info}),asset.Error.None) {return false}
    if !testing.expect(t,host.assets_init(&f.assets,{root=root,capacity=8})) {return false}
    m,error:=mixer.mixer_create({})
    if !testing.expect_value(t,error,mixer.Error.None) {
        host.assets_destroy(&f.assets)
        return false
    }
    f.app=host.App{mixer=m,assets=&f.assets,allocator=context.allocator}
    return true
}

@(private="file")
fixture_destroy :: proc(f:^Fixture) {
    mixer.mixer_destroy(f.app.mixer)
    host.app_content_destroy(&f.app)
    host.assets_destroy(&f.assets)
}

@(private)
@(test_world)
Audio_World :: struct {
    using world:Test_World,
    sources:core.Table(Audio_Source),
    states:core.Table(Audio_Source_State),
    worlds:core.Table(core.World_Transform),
    listeners:core.Table(Audio_Listener),
    occlusions:core.Table(Audio_Occlusion),
    materials:core.Table(Audio_Material),
    reverbs:core.Table(Audio_Reverb),
    volumes:core.Table(volume.Volume),
    sections:core.Table(scene.Scene_Reference),
    view:core.View,
}

// A world with what the application holds for it and the query its sources look through.
@(private="file")
Heard_World :: struct {
    using data:Audio_World,
    voices:Voices,
    query:core.World_Query,
}

@(private="file")
world_init :: proc(t:^testing.T,w:^Heard_World,source:Audio_Source,position:[3]f32={}) -> (e:core.Entity,ok:bool) {
    test_world_init(t,&w.data) or_return
    e=core.create(&w.entities)
    core.add(&w.sources,e,source)
    placed:=mm.TRANSFORM_IDENTITY
    placed.position=position
    core.add(&w.worlds,e,core.World_Transform{placed,placed})
    test_world_settle(&w.data)
    return e,true
}

@(private="file")
world_destroy :: proc(w:^Heard_World) {
    core.value_free(&w.voices,type_info_of(Voices))
    test_world_destroy(&w.data)
}

@(private="file")
world_run :: proc(w:^Heard_World,listener:^Mixer_Listeners,app:^host.App,dt:f32=1.0/60) {
    hearing:=Hearing{core.read(&w.worlds),core.read(&w.occlusions),core.read(&w.materials),core.read(&w.listeners),core.ref(&w.view),{},w.query}
    sources_update(core.read(&w.sources),&w.states,hearing,dt,&w.voices,listener,app,nil)
    test_world_settle(&w.data)
}

// A Play beside the world it was copied from, or the run of an agent stepped
// in the same frame: each world plays its own voices and keeps them while
// the other runs.
@(test)
each_world_keeps_its_voices_and_freeing_one_stops_only_its_own :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop=HUM,true
    shown,played:Heard_World
    e,shown_made:=world_init(t,&shown,source);defer world_destroy(&shown)
    _,played_made:=world_init(t,&played,source);defer world_destroy(&played)
    if !shown_made || !played_made {return}

    world_run(&shown,&listener,&f.app)
    world_run(&played,&listener,&f.app)
    testing.expect(t,len(shown.voices.entries.values)==1 && len(played.voices.entries.values)==1)
    voice:=core.entity_map_get(&shown.voices.entries,e).voice
    testing.expect(t,voice!=core.entity_map_get(&played.voices.entries,e).voice)
    for _ in 0..<3 {
        world_run(&shown,&listener,&f.app)
        world_run(&played,&listener,&f.app)
    }
    testing.expect(t,core.entity_map_get(&shown.voices.entries,e).voice==voice && mixer.voice_valid(m,voice))
    testing.expect(t,shown.voices.stats.started==1 && played.voices.stats.started==1)

    audio_release(&played.voices,f.app.mixer)
    world_run(&shown,&listener,&f.app)
    testing.expect(t,len(played.voices.entries.values)==0)
    testing.expect(t,core.entity_map_get(&shown.voices.entries,e).voice==voice && mixer.voice_valid(m,voice))

    // Another bus is another voice.
    core.edit(&shown.sources,e).bus=BUS_MUSIC
    world_run(&shown,&listener,&f.app)
    moved:=core.entity_map_get(&shown.voices.entries,e)
    testing.expect(t,moved!=nil && moved.voice!=voice && moved.kind.bus==BUS_MUSIC && mixer.bus_count(m)>int(BUS_MUSIC))

    // A source that goes takes its voice with it.
    core.remove(&shown.sources,e)
    test_world_settle(&shown.data)
    world_run(&shown,&listener,&f.app)
    testing.expect_value(t,len(shown.voices.entries.values),0)
}

// A request plays once, at the end of the tick that asked; the same request
// in a tick that runs again does not play again; a copy of the world made
// before the end of the tick carries it.
@(test)
a_sound_request_plays_once_and_not_again_when_its_tick_runs_again :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    problems:core.Problems
    tick:=core.Time{dt=1.0/60,playing=true}
    replay:=tick
    replay.resimulating=true
    fixed:=core.Frame_Time{phase=.Fixed}
    played:Sounds_Played
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    play(&sounds,STEPS,at=[3]f32{1,0,0})
    copied:Sound_Requests
    defer core.value_free(&copied,type_info_of(Sound_Requests))
    testing.expect(t,core.value_copy(&copied,&sounds,type_info_of(Sound_Requests)))
    testing.expect(t,len(copied.items)==1 && copied.items[0].sound==STEPS && copied.items[0].placed,"a copy of the world carries what waits")
    audio_requests(&sounds,tick,fixed,&played,nil,&f.app,&problems)
    testing.expect_value(t,mixer.mixer_stats(m).voices_played,u64(1))
    testing.expect_value(t,len(sounds.items),0)
    audio_requests(&sounds,tick,fixed,&played,nil,&f.app,&problems)
    testing.expect_value(t,mixer.mixer_stats(m).voices_played,u64(1))
    // A rollback brings back the copy, and the tick asks again as it runs again.
    play(&copied,STEPS,at=[3]f32{1,0,0})
    audio_requests(&copied,replay,fixed,&played,nil,&f.app,&problems)
    testing.expect_value(t,mixer.mixer_stats(m).voices_played,u64(1))
    testing.expect_value(t,len(copied.items),0)
    testing.expect_value(t,problems.count,0)
    play(&sounds,HUM,bus=Audio_Bus(AUDIO_BUS_CAPACITY))
    audio_requests(&sounds,tick,fixed,&played,nil,&f.app,&problems)
    testing.expect(t,mixer.mixer_stats(m).voices_played==1 && core.problem_find(&problems,core.NONE,"audio.bus")!=nil,"a bus over the capacity plays nothing and says so")
    nan,inf:=math.nan_f32(),math.inf_f32(1)
    play(&sounds,HUM,volume=nan)
    play(&sounds,HUM,pitch=-1)
    play(&sounds,HUM,at=[3]f32{0,inf,0})
    audio_requests(&sounds,tick,fixed,&played,nil,&f.app,&problems)
    refused:=core.problem_find(&problems,core.NONE,"audio.request")
    testing.expect(t,mixer.mixer_stats(m).voices_played==1 && refused!=nil && refused.count==3,"what is not a number plays nothing and says so")
}

// Code names a sound by its path in the assets as by its id; a path the
// assets do not have plays nothing and says so.
@(test)
a_sound_plays_by_its_path_in_the_assets :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    testing.expect(t,host.assets_scan(&f.assets))
    tick:=core.Time{dt=1.0/60,playing=true}
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    long:=make([]u8,SOUND_PATH_CAPACITY,context.temp_allocator)
    for &c in long {c='a'}
    cases:=[]struct{path:string,plays:bool}{{"hum.sound",true},{"steps.sound_set",true},{"missing.sound",false},{"",false},{string(long),false}}
    for c in cases {
        problems:core.Problems
        played:=mixer.mixer_stats(f.app.mixer).voices_played
        play(&sounds,c.path)
        play(&sounds,c.path,at=[3]f32{1,0,0})
        audio_requests(&sounds,tick,{},nil,nil,&f.app,&problems)
        testing.expectf(t,(mixer.mixer_stats(f.app.mixer).voices_played==played+2)==c.plays,"%q plays: %v",c.path,!c.plays)
        testing.expectf(t,(core.problem_find(&problems,core.NONE,"audio.sound")==nil)==c.plays,"%q says why it does not play",c.path)
    }
}

// One sound of a set that does not play all is chosen; the gain and pitch of
// its entry go over the volume and pitch drawn from the ranges.
@(test)
a_sound_set_plays_its_sounds_by_weight_in_its_ranges_and_not_the_same_twice :: proc(t:^testing.T) {
    set:=asset.SOUND_SET_DEFAULTS
    set.volume_min,set.volume_max,set.pitch_min,set.pitch_max=0.5,0.75,0.9,1.2
    set.sounds[0]={gain=2,pitch=1.5,delay=0.5}
    f:Fixture
    if !fixture_init(t,&f,set) {return}
    defer fixture_destroy(&f)
    a,b:=host.content_sound(&f.app,STEP_A),host.content_sound(&f.app,STEP_B)
    last:mixer.Sound
    for _ in 0..<32 {
        picks:[asset.SOUND_SET_CAPACITY]host.Sound_Pick
        testing.expect_value(t,host.content_sound_picks(&f.app,STEPS,&picks),1)
        pick:=picks[0]
        testing.expect(t,pick.sound==a || pick.sound==b)
        testing.expect(t,pick.sound!=last,"no_repeat never chooses the same sound twice in a row")
        scale:=[2]f32{2,1.5} if pick.sound==a else 1
        testing.expectf(t,pick.volume>=0.5*scale[0] && pick.volume<=0.75*scale[0] && pick.pitch>=0.9*scale[1] && pick.pitch<=1.2*scale[1] && pick.delay==0,"%v",pick)
        last=pick.sound
    }
    single:=host.content_sound_pick(&f.app,HUM)
    testing.expect(t,single.sound==host.content_sound(&f.app,HUM) && single.volume==1 && single.pitch==1)
    testing.expect(t,host.content_sound_generation(&f.app,STEPS)!=0 && host.content_sound_generation(&f.app,{9,9})==0)
}

// A set that plays all starts every sound of it as one cue: each with the
// gain and pitch of its entry, and each after its delay, exact to the sample
// in what the mixer renders. A source, which holds one voice, does not play
// it and says why.
@(test)
a_set_that_plays_all_starts_every_layer_after_its_delay_to_the_sample :: proc(t:^testing.T) {
    DELAY :: 300
    set:=asset.SOUND_SET_DEFAULTS
    set.all=true
    set.sounds[0]={gain=0.5}
    set.sounds[1]={pitch=1.5,delay=f32(DELAY)/mixer.MIXER_RATE}
    f:Fixture
    if !fixture_init(t,&f,set) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    problems:core.Problems
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    out:=make([]f32,1100*2,context.temp_allocator)
    mixer.mixer_render(m,out[:200])
    play(&sounds,STEPS)
    audio_requests(&sounds,core.Time{},{},nil,nil,&f.app,&problems)
    testing.expect_value(t,problems.count,0)
    testing.expect_value(t,mixer.mixer_stats(m).voices_played,u64(2))
    for done:=0;done<1100;done+=125 {mixer.mixer_render(m,out[done*2:][:min(125,1100-done)*2])}
    testing.expect(t,m.voices[0].volume==0.5 && m.voices[0].pitch==1 && m.voices[1].volume==1 && m.voices[1].pitch==1.5)
    body:=out[0]
    testing.expect(t,body>0)
    for i in 1..<1100 {
        want:=body if i<DELAY else 3*body
        if !testing.expectf(t,abs(out[i*2]-want)<1e-5,"frame %d: %v, wants %v",i,out[i*2],want) {break}
    }
    e:=core.entity_make(4,1)
    source:=AUDIO_SOURCE_DEFAULT
    source.sound=STEPS
    _,picked:=sound_pick(m,&f.app,source,e,&problems)
    testing.expect(t,!picked && core.problem_find(&problems,e,"audio.layered")!=nil,"a source says that a set that plays all is a cue of audio.play")
}

// A fixed tick plays a sound of an entity, or of none near a place, once: a
// tick a rollback runs again plays only what it did not play the first
// time, as a hit the correction found; the editor loop, whose ticks do not
// advance, keys nothing; a clock that goes back forgets what it kept.
@(test)
a_rollback_plays_each_sound_of_a_tick_once_and_what_only_the_correction_asks :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    E,OTHER:=core.entity_make(5,1),core.entity_make(6,1)
    Ask :: struct {sound:base.Asset_Id,by:core.Entity,at:Maybe([3]f32)}
    Step :: struct {tick:u64,again:bool,editor:bool,asks:[]Ask,played:u64,what:string}
    steps:=[]Step{
        {10,false,false,{{HUM,E,nil}},1,"the first time plays"},
        {11,false,false,{},1,"the next tick asks nothing"},
        {10,true,false,{{HUM,E,nil}},1,"the same sound of the same entity in the tick again does not play again"},
        {10,true,false,{{HUM,E,nil},{STEP_A,E,nil}},2,"what only the correction asks plays"},
        {10,true,false,{{HUM,E,nil},{STEP_A,E,nil}},2,"and does not play again in a second rollback"},
        {10,true,false,{{HUM,OTHER,nil}},3,"the same sound of another entity plays"},
        {12,false,false,{{HUM,core.NONE,[3]f32{0,0,0}},{HUM,core.NONE,[3]f32{0.5,0,0}},{HUM,core.NONE,[3]f32{5,0,0}}},5,"of none, one near a place"},
        {12,true,false,{{HUM,core.NONE,[3]f32{0.2,0,0}},{HUM,core.NONE,nil}},6,"near where it played is that one; not placed is another"},
        {3,false,false,{{HUM,E,nil}},7,"the clock went back"},
        {3,false,true,{{HUM,E,nil},{HUM,E,nil}},9,"the editor loop plays each"},
    }
    played:Sounds_Played
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    for step in steps {
        for ask in step.asks {play(&sounds,ask.sound,at=ask.at,by=ask.by)}
        time:=core.Time{tick=step.tick,dt=1.0/60,playing=!step.editor,resimulating=step.again}
        audio_requests(&sounds,time,core.Frame_Time{phase=.Fixed},&played,nil,&f.app,nil)
        testing.expectf(t,mixer.mixer_stats(m).voices_played==step.played,"%s: %d played, wants %d",step.what,mixer.mixer_stats(m).voices_played,step.played)
        mixer.mixer_update(m)
    }
}

// Each request keeps what became of it, newest last, by the id of its sound:
// played, beyond every listener, refused by the mixer, of a sound the assets
// lack, or asked again by a tick that runs again. Placed ones keep how far the
// nearest listener was.
@(test)
each_sound_request_keeps_what_became_of_it :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    testing.expect(t,host.assets_scan(&f.assets))
    E:=core.entity_make(5,1)
    listeners:=Mixer_Listeners{count=1}
    listeners.slots[0].position={0,0,3}
    played:Sounds_Played
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    fixed:=core.Frame_Time{phase=.Fixed}
    play(&sounds,HUM,by=E)
    play(&sounds,HUM,at=[3]f32{0,0,1003})
    play(&sounds,HUM,bus=Audio_Bus(AUDIO_BUS_CAPACITY))
    play(&sounds,"missing.sound")
    play(&sounds,base.Asset_Id{9,9},at=[3]f32{0,0,4})
    audio_requests(&sounds,core.Time{tick=10,dt=1.0/60,playing=true},fixed,&played,&listeners,&f.app,nil)
    play(&sounds,HUM,by=E)
    audio_requests(&sounds,core.Time{tick=10,dt=1.0/60,playing=true,resimulating=true},fixed,&played,&listeners,&f.app,nil)
    play(&sounds,"hum.sound")
    audio_requests(&sounds,core.Time{tick=10},{},&played,&listeners,&f.app,nil)
    Want :: struct {sound:base.Asset_Id,outcome:One_Shot_Outcome,keyed:bool,distance:f32}
    wants:=[]Want{
        {HUM,.Played,true,0},{HUM,.Culled_Distance,true,1000},{HUM,.Rejected_Mixer,true,0},
        {{},.Missing_Asset,false,0},{{9,9},.Missing_Asset,true,1},{HUM,.Deduped,true,0},{HUM,.Played,false,0},
    }
    older,newer:=sounds_played(&played)
    testing.expect_value(t,len(older),0)
    if !testing.expect_value(t,len(newer),len(wants)) {return}
    for want,i in wants {
        got:=newer[i]
        testing.expectf(t,got.tick==10 && got.sound==want.sound && got.outcome==want.outcome && got.keyed==want.keyed && abs(got.distance-want.distance)<1e-3,"%d: %v, wants %v",i,got,want)
    }
    testing.expect(t,newer[0].by==E && newer[1].placed && newer[1].at=={0,0,1003})
    // Past the capacity, the ring keeps the newest, oldest first.
    for _ in 0..<SOUNDS_PLAYED_CAPACITY {played_add(&played,{tick=11})}
    played_add(&played,{tick=12})
    older,newer=sounds_played(&played)
    testing.expect_value(t,len(older)+len(newer),SOUNDS_PLAYED_CAPACITY)
    testing.expect(t,older[0].tick==11 && newer[len(newer)-1].tick==12)
}

// The ring of a world is of the application, not of the World: a copy of the
// World (a snapshot a rollback goes back to) neither holds nor takes it back,
// so the tick that runs again on the restored copy still finds what it played.
@(test)
the_sounds_played_stay_out_of_the_copies_of_the_world :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    info,described:=test_info(t,Played_World)
    if !described {return}
    defer test_info_destroy(&info)
    for storage in info.storages {
        if storage.type!=Sounds_Played {continue}
        testing.expect(t,storage.place==.Shared && storage.by_world,"one ring per world, in the Shared")
    }
    shared:Played_Shared
    if !testing.expect(t,core.world_init(&info,.Shared,&shared,context.allocator)) {return}
    defer core.world_destroy(&info,.Shared,&shared)
    app:=&f.app
    app.info,app.shared=&info,&shared
    defer {
        delete(app.worlds)
        app.info,app.shared,app.worlds=nil,nil,nil
    }
    world:=cast(^Played_World)host.app_world_create(app)
    if !testing.expect(t,world!=nil) {return}
    defer host.app_world_free(app,world)
    played:=host.app_world_storage(app,world,Sounds_Played)
    if !testing.expect(t,played!=nil) {return}
    snapshot:Played_World
    if !testing.expect(t,core.world_init(&info,.World,&snapshot,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&snapshot)
    testing.expect(t,core.world_copy(&info,&snapshot,world))
    E:=core.entity_make(5,1)
    fixed:=core.Frame_Time{phase=.Fixed}
    play(&world.sounds,HUM,by=E)
    audio_requests(&world.sounds,core.Time{tick=4,playing=true},fixed,played,nil,app,nil)
    voices:=mixer.mixer_stats(app.mixer).voices_played
    testing.expect_value(t,played.count,u64(1))
    // The rollback restores the World and runs the tick again.
    testing.expect(t,core.world_copy(&info,world,&snapshot))
    testing.expect(t,host.app_world_storage(app,world,Sounds_Played)==played && played.count==1,"the copy brought back no ring")
    play(&world.sounds,HUM,by=E)
    audio_requests(&world.sounds,core.Time{tick=4,playing=true,resimulating=true},fixed,played,nil,app,nil)
    testing.expect_value(t,mixer.mixer_stats(app.mixer).voices_played,voices)
    _,kept:=sounds_played(played)
    testing.expect(t,len(kept)==2 && kept[1].outcome==.Deduped)
}

@(test_world,host="Played_Shared") @(private) Played_World :: struct {using world:Test_World,sounds:Sound_Requests,id:core.World_Id}
@(private) Played_Shared :: struct {played:core.By_World(Sounds_Played)}

// A source that plays is heard as its voice says: mixed, fading out, out of
// the budget of the mixer or silent; one whose sound does not load is not.
// Its gain is that of its volume, its draw, its bus and its distance.
@(test)
a_voice_says_how_it_is_heard_and_at_what_gain :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    sound:=host.content_sound(&f.app,HUM)
    playing:=mixer.voice_play(m,sound,mixer.VOICE_DEFAULT)
    if !testing.expect(t,playing!={}) {return}
    listeners:=Mixer_Listeners{count=1}
    source:=AUDIO_SOURCE_DEFAULT
    source.volume=0.5
    if !testing.expect(t,bus_ready(m,source.bus)) {return}
    Case :: struct {entry:Voice_Entry,gain:f32,state:Voice_State}
    attenuation:=attenuation_of(AUDIO_SOURCE_DEFAULT)
    cases:=[]Case{
        {{sound=sound,voice=playing,pick={0.5,1}},0.25,.Playing},
        {{sound=sound,fading=playing,pick={1,1}},0.5,.Fading},
        {{sound=sound,pick={1,1},kind={spatial=true,attenuation=attenuation},position={0,0,1000}},0,.Virtual_Silent},
        {{sound=sound,pick={1,1},kind={spatial=true,attenuation=attenuation},position={0,0,2}},0.25,.Virtual_Budget},
        {{pick={1,1}},0.5,.Unloaded},
    }
    for &c,i in cases {
        gain:=entry_gain(m,source,&c.entry,&listeners)
        testing.expectf(t,abs(gain-c.gain)<1e-4,"%d: gain %v, wants %v",i,gain,c.gain)
        testing.expectf(t,voice_state(m,&c.entry,gain)==c.state,"%d: %v, wants %v",i,voice_state(m,&c.entry,gain),c.state)
    }
    testing.expect(t,voice_state(nil,&cases[0].entry,1)==.Unloaded && entry_gain(nil,source,&cases[0].entry,&listeners)==0)
}

// The settings give the mixer its streams, within its range; a play refused
// because every stream plays is said once per frame that had one.
@(test)
the_stream_capacity_follows_the_settings_and_a_refused_stream_is_said :: proc(t:^testing.T) {
    m,error:=mixer.mixer_create({})
    if !testing.expect_value(t,error,mixer.Error.None) {return}
    defer mixer.mixer_destroy(m)
    frames:=4800
    wav:=make([]u8,44+frames*2,context.temp_allocator)
    header:=[]u32le{0x46464952,u32le(36+frames*2),0x45564157,0x20746d66,16,0x00010001,48000,96000,0x00100002,0x61746164,u32le(frames*2)}
    copy(wav,([^]u8)(raw_data(header))[:44])
    for i in 0..<frames {wav[44+i*2+1]=0x10}
    stream,streamed:=mixer.sound_stream(m,wav)
    testing.expect_value(t,streamed,mixer.Error.None)
    problems:core.Problems
    applied:Mixer_Buses
    settings:=Audio_Settings{stream_capacity=1}
    streams_apply(m,&settings,&applied,&problems)
    testing.expect_value(t,mixer.mixer_stats(m).stream_capacity,1)
    testing.expect(t,mixer.voice_play(m,stream)!=0)
    for refused in 1..=3 {
        testing.expect_value(t,mixer.voice_play(m,stream),Voice(0))
        if refused==2 {testing.expect_value(t,mixer.voice_play(m,stream),Voice(0))}
        streams_apply(m,&settings,&applied,&problems)
        streams_apply(m,&settings,&applied,&problems)
        said:=core.problem_find(&problems,core.NONE,"audio.streams")
        testing.expectf(t,said!=nil && said.count==u64(refused),"said once per frame that refused: %v",said)
    }
    Case :: struct {asked,has:int,says:bool}
    for c in ([?]Case{{0,mixer.STREAM_CAPACITY_DEFAULT,false},{3,3,false},{mixer.STREAM_CAPACITY_MAX+5,mixer.STREAM_CAPACITY_MAX,true},{-2,1,true}}) {
        cleared:core.Problems
        settings.stream_capacity=c.asked
        streams_apply(m,&settings,&applied,&cleared)
        testing.expectf(t,mixer.mixer_stats(m).stream_capacity==c.has,"%d asked, %d streams",c.asked,mixer.mixer_stats(m).stream_capacity)
        testing.expect_value(t,core.problem_find(&cleared,core.NONE,"audio.stream_capacity")!=nil,c.says)
    }
}

@(test)
buses_take_their_gain_filter_and_ducking_from_the_settings :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    settings:Audio_Settings
    hall:=Reverb{room_size=0.9,damping=0.3,wet=0.8,width=1}
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MUSIC,gain=-6,lowpass=2000,duck_by=BUS_VOICE,duck_amount=0.5,duck_threshold=0.1,duck_attack=0.05,duck_release=0.3,reverb=hall}))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MASTER,gain=AUDIO_SILENCE_DB}))
    AMBIENCE :: Audio_Bus(5)
    testing.expect(t,audio_bus_setting_set(&settings,{bus=AMBIENCE,send=BUS_EFFECTS}))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_EFFECTS,send=BUS_UI}))
    volumes:=AUDIO_VOLUMES_DEFAULT
    problems:core.Problems
    buses_apply(f.app.mixer,&settings,&volumes,0,&problems)
    testing.expect(t,mixer.bus_send(m,mixer.Bus(AMBIENCE))==mixer.Bus(BUS_EFFECTS),"ambience plays into effects")
    testing.expect(t,mixer.bus_send(m,mixer.Bus(BUS_EFFECTS))==mixer.BUS_MASTER && core.problem_find(&problems,core.NONE,"audio.send")!=nil,"a bus sends only to one before it, and says so")
    testing.expect(t,audio_bus_setting_set(&settings,{bus=AMBIENCE}))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_EFFECTS}))
    testing.expect(t,mixer.bus_count(m)>int(BUS_VOICE))
    testing.expect(t,abs(mixer.bus_volume(m,mixer.Bus(BUS_MUSIC))-0.5012)<0.001 && mixer.bus_lowpass(m,mixer.Bus(BUS_MUSIC))==2000)
    testing.expect(t,mixer.bus_duck(m,mixer.Bus(BUS_MUSIC)).source==mixer.Bus(BUS_VOICE) && mixer.bus_duck(m,mixer.Bus(BUS_MUSIC)).amount==0.5)
    testing.expect_value(t,mixer.bus_volume(m,mixer.BUS_MASTER),f32(0))
    testing.expect(t,mixer.bus_reverb(m,mixer.Bus(BUS_MUSIC))==hall,"a song in the music bus sounds in its hall")

    // The volume the player chose goes over the gain of the game.
    volumes.music=0.5
    buses_apply(f.app.mixer,&settings,&volumes,0,nil)
    testing.expect(t,abs(mixer.bus_volume(m,mixer.Bus(BUS_MUSIC))-0.2506)<0.001)
    testing.expect_value(t,audio_volume(core.ref(&volumes),BUS_MUSIC),f32(0.5))
    volumes.more[0]=0.25
    testing.expect_value(t,audio_volume(core.ref(&volumes),Audio_Bus(5)),f32(0.25))
    volumes.music=max(f32)
    testing.expect_value(t,audio_volume(core.ref(&volumes),BUS_MUSIC),f32(1))
    volumes.music=math.nan_f32()
    testing.expect_value(t,audio_volume(core.ref(&volumes),BUS_MUSIC),f32(0))
    volumes=AUDIO_VOLUMES_DEFAULT

    // A bus whose entry goes back to playing as it comes loses its entry, and the mixer follows.
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MUSIC}))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MASTER}))
    testing.expect(t,settings==Audio_Settings{},"settings that say nothing are zeros")
    buses_apply(f.app.mixer,&settings,&volumes,0,nil)
    testing.expect(t,mixer.bus_volume(m,mixer.Bus(BUS_MUSIC))==1 && mixer.bus_lowpass(m,mixer.Bus(BUS_MUSIC))==0 && mixer.bus_duck(m,mixer.Bus(BUS_MUSIC))=={} && mixer.bus_reverb(m,mixer.Bus(BUS_MUSIC))=={})
    testing.expect_value(t,mixer.bus_volume(m,mixer.BUS_MASTER),f32(1))
    testing.expect(t,db_volume(AUDIO_SILENCE_DB)==0 && abs(db_volume(-6)-0.5012)<0.001)
}

@(test)
without_a_listener_the_view_hears_and_moving_gives_it_a_velocity :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial,source.doppler,source.max_distance=HUM,true,true,1,100
    w:Heard_World
    e,made:=world_init(t,&w,source,{0,0,-10});defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={5,0,0},1
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.count==1 && listener.slots[0].position==[3]f32{5,0,0} && listener.slots[0].velocity==[3]f32{})
    w.view.position={6,0,0}
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.slots[0].position==[3]f32{6,0,0} && listener.slots[0].velocity==[3]f32{2,0,0})
    w.view.cut=true
    w.view.position={60,0,0}
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.slots[0].velocity==[3]f32{},"a view that jumped does not move")

    // A source that moves tells its velocity, and stops telling it once it rests.
    core.edit(&w.worlds,e).position={0,0,-9}
    world_run(&w,&listener,&f.app,0.5)
    entry:=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry!=nil && entry.moving && entry.position==[3]f32{0,0,-9})
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,!core.entity_map_get(&w.voices.entries,e).moving)

    // An entity that listens comes before the view.
    hearer:=core.create(&w.entities)
    core.add(&w.listeners,hearer,Audio_Listener{})
    placed:=mm.TRANSFORM_IDENTITY
    placed.position={0,2,0}
    core.add(&w.worlds,hearer,core.World_Transform{placed,placed})
    test_world_settle(&w.data)
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.count==1 && listener.slots[0].position==[3]f32{0,2,0})
    testing.expect(t,!math.is_nan(listener.slots[0].velocity.x))
}

// A wall that stands between every source and the listener while user points at true.
@(private="file")
wall_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (core.World_Hit,bool) {
    return {distance=length*0.5},(cast(^bool)user)^
}

@(test)
a_source_behind_a_wall_is_muffled_and_comes_back_over_its_fade :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial=HUM,true,true
    w:Heard_World
    e,made:=world_init(t,&w,source,{0,0,-10});defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={},1
    wall:=true
    w.query={user=&wall,probe=wall_probe}
    core.add(&w.occlusions,e,Audio_Occlusion{radius=0,fade=0.5})
    test_world_settle(&w.data)
    world_run(&w,&listener,&f.app,0.1)
    entry:=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry!=nil && core.at(&w.states,core.row_of(&w.states,e)).occlusion==1,"a voice that starts hidden is hidden at once")
    // Both sides of one wall without a material: the default one, once.
    want:=AUDIO_MATERIAL_DEFAULT.transmission
    for band in 0..<mixer.BANDS {testing.expect(t,abs(entry.transmission[band]-want[band])<1e-5)}

    wall=false
    world_run(&w,&listener,&f.app,0.1)
    amount:=core.at(&w.states,core.row_of(&w.states,e)).occlusion
    testing.expect(t,abs(amount-0.8)<1e-4,"it comes back a fifth of the way in a tenth of its fade")
    for _ in 0..<5 {world_run(&w,&listener,&f.app,0.1)}
    testing.expect(t,core.at(&w.states,core.row_of(&w.states,e)).occlusion==0,"in sight it plays as it is")

    // Near the listener nothing hides it: that is its own body.
    wall=true
    core.edit(&w.worlds,e).position={0,0,-0.3}
    world_run(&w,&listener,&f.app,0.1)
    testing.expect_value(t,core.at(&w.states,core.row_of(&w.states,e)).occlusion,f32(0))
}

// A wall across z=-5 that ends at x=0.3, the body of the entity in user.
@(private="file")
half_wall_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (core.World_Hit,bool) {
    if abs(direction.z)<1e-6 {return {},false}
    distance:=(-5-origin.z)/direction.z
    if !(distance>0 && distance<length) || origin.x+direction.x*distance>=0.3 {return {},false}
    return {distance=distance,entity=(cast(^core.Entity)user)^},true
}

// A source as wide as its radius behind the edge of a wall is partly hidden,
// and what hides it lets through what its material says.
@(test)
a_wide_source_behind_the_edge_of_a_wall_is_partly_hidden :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial=HUM,true,true
    w:Heard_World
    e,made:=world_init(t,&w,source,{0,0,-10});defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={},1
    wall:=core.create(&w.entities)
    core.add(&w.materials,wall,Audio_Material{transmission={0.5,0.25,0.04}})
    w.query={user=&wall,probe=half_wall_probe}
    core.add(&w.occlusions,e,Audio_Occlusion{radius=1,fade=0})
    test_world_settle(&w.data)
    world_run(&w,&listener,&f.app)
    state,_:=core.get(&w.states,e)
    testing.expectf(t,state.occlusion>0.2 && state.occlusion<0.95,"part of it is hidden: %v",state.occlusion)
    entry:=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry!=nil)
    testing.expectf(t,abs(entry.transmission[0]-0.5)<1e-5 && abs(entry.transmission[2]-0.04)<1e-5,"the material of the wall: %v",entry.transmission)
    // Each frame tests a few of its points again: it stays where it is while nothing moves.
    before:=state.occlusion
    for _ in 0..<OCCLUSION_SAMPLES/OCCLUSION_SAMPLES_PER_FRAME {world_run(&w,&listener,&f.app)}
    testing.expect_value(t,core.at(&w.states,core.row_of(&w.states,e)).occlusion,before)
    // Out from behind the wall it is in sight again within as many frames.
    core.edit(&w.worlds,e).position={10,0,-10}
    for _ in 0..<OCCLUSION_SAMPLES/OCCLUSION_SAMPLES_PER_FRAME {world_run(&w,&listener,&f.app)}
    testing.expect_value(t,core.at(&w.states,core.row_of(&w.states,e)).occlusion,f32(0))
}

// The level reverberates as its unbounded Audio_Reverb; a hall replaces it
// inside its box, a smaller cave of the same priority goes over the hall and
// a closet of lower priority stays under it.
@(test)
the_reverb_is_that_of_the_volumes_the_listener_is_in :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    w:Audio_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    place :: proc(p:^Audio_World,reverb:Audio_Reverb,v:Maybe(volume.Volume),position,scale:[3]f32) {
        e:=core.create(&p.entities)
        core.add(&p.reverbs,e,reverb)
        if v,ok:=v.?;ok {core.add(&p.volumes,e,v)}
        placed:=mm.TRANSFORM_IDENTITY
        placed.position,placed.scale=position,scale
        core.add(&p.worlds,e,core.World_Transform{placed,placed})
    }
    level,hall,cave,closet:=Audio_Reverb{room_size=0.5,wet=0.25},AUDIO_REVERB_DEFAULT,AUDIO_REVERB_DEFAULT,AUDIO_REVERB_DEFAULT
    hall.room_size,cave.room_size,closet.room_size=0.9,0.3,0.1
    hall.zone,cave.zone={},{}
    place(&w,level,nil,{},{1,1,1})
    place(&w,hall,volume.Volume{shape=.Box,extents={20,10,20}},{},{1,1,1})
    place(&w,cave,volume.Volume{shape=.Box,extents={2,2,2}},{10,0,0},{2,1,1}) // 4 m along x once scaled
    place(&w,{room_size=closet.room_size,zone={priority=-1}},volume.box({1,1,1}),{13,0,0},{1,1,1})
    test_world_settle(&w)
    at :: proc(p:^Audio_World,point:[3]f32) -> f32 {
        return volume.at({volumes=core.read(&p.volumes),worlds=core.read(&p.worlds)},core.read(&p.reverbs),point,Audio_Reverb{},reverb_mix).room_size
    }
    testing.expect_value(t,at(&w,{0,0,0}),f32(0.9))
    testing.expect_value(t,at(&w,{13.5,0,0}),f32(0.3))
    testing.expect_value(t,at(&w,{0,15,0}),f32(0.5))

    settings:Audio_Settings
    w.view=core.View{position={0,15,0},rotation=1}
    mixer_reverb:Mixer_Reverb
    run :: proc(p:^Audio_World,settings:^Audio_Settings,dt:f32,r:^Mixer_Reverb,app:^host.App) {
        audio_reverb(core.read(&p.reverbs),core.read(&p.volumes),core.read(&p.worlds),nil,nil,nil,core.read(&p.listeners),core.ref(&p.view),core.ref(settings),{},{dt=dt},r,app.mixer,{})
    }
    run(&w,&settings,0.1,&mixer_reverb,&f.app)
    got,_:=mixer.reverb_get(f.app.mixer)
    testing.expect(t,got==(^Reverb)(&level)^,"outside of every box, the level; the first one at once")
    w.view.position={0,0,0}
    run(&w,&settings,0.1,&mixer_reverb,&f.app)
    got,_=mixer.reverb_get(f.app.mixer)
    testing.expect(t,got.room_size>0.5 && got.room_size<0.9,"it goes toward the hall")
    for _ in 0..<40 {run(&w,&settings,0.1,&mixer_reverb,&f.app)}
    got,_=mixer.reverb_get(f.app.mixer)
    testing.expect(t,got==(^Reverb)(&hall)^,"and gets there")
}

@(test)
unchanged_bus_stamps_skip_applying_settings_until_a_revision_changes :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    settings:Audio_Settings
    volumes:=AUDIO_VOLUMES_DEFAULT
    revision:=u64(1)
    stamp:=core.Stamp(Audio_Volumes){&revision}
    settings_stamp:=core.Stamp(Audio_Settings){&revision}
    applied:Mixer_Buses
    m:=f.app.mixer
    w:Audio_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    audio_buses(core.ref(&settings),core.ref(&volumes),{},core.read(&w.worlds),core.read(&w.listeners),{},settings_stamp,stamp,&applied,m,{},nil)
    mixer.bus_set_volume(m,mixer.Bus(BUS_MASTER),0.25)
    audio_buses(core.ref(&settings),core.ref(&volumes),{},core.read(&w.worlds),core.read(&w.listeners),{},settings_stamp,stamp,&applied,m,{},nil)
    testing.expect_value(t,mixer.bus_volume(m,mixer.Bus(BUS_MASTER)),f32(0.25))
    revision+=1
    audio_buses(core.ref(&settings),core.ref(&volumes),{},core.read(&w.worlds),core.read(&w.listeners),{},settings_stamp,stamp,&applied,m,{},nil)
    testing.expect_value(t,mixer.bus_volume(m,mixer.Bus(BUS_MASTER)),f32(1))
}

// Under the water the master loses its highs, by the lower of its own cutoff
// and that of the medium, while every listener is under one; while only some
// are, the voices heard from those lose them through their EQ instead. The
// reverb goes to that of the medium by its weight, averaged over the
// listeners; back in the air, all are those of the settings and the room.
@(test)
the_medium_of_each_listener_dulls_the_master_or_its_voices :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    volumes:=AUDIO_VOLUMES_DEFAULT
    water:=Medium{lowpass=700,reverb={room_size=0.3,damping=0.9,wet=0.6,width=0.5},weight=1}
    lake:=water
    lake.lowpass=900
    FLAT :: [mixer.BANDS]f32{1,1,1}
    Case :: struct {name:string,media:[2]Medium,count:int,setting,master:f32,bands:[2][mixer.BANDS]f32}
    for c in ([?]Case{
        {"one under water",{water,{}},1,0,700,{FLAT,FLAT}},
        {"its own cutoff lower",{water,{}},1,500,500,{FLAT,FLAT}},
        {"its own cutoff higher",{water,{}},1,4000,700,{FLAT,FLAT}},
        {"one in the air",{},1,4000,4000,{FLAT,FLAT}},
        {"one of two under water",{water,{}},2,0,0,{mixer.lowpass_bands(700),FLAT}},
        {"the other of two under water",{{},water},2,4000,4000,{FLAT,mixer.lowpass_bands(700)}},
        {"both under water: the clearer",{water,lake},2,0,900,{FLAT,FLAT}},
    }) {
        settings:Audio_Settings
        testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MASTER,lowpass=c.setting}))
        medium:Audio_Medium
        medium.listeners[0],medium.listeners[1]=c.media[0],c.media[1]
        buses_apply(m,&settings,&volumes,medium_lowpass(&medium,c.count),nil)
        testing.expectf(t,mixer.bus_lowpass(m,mixer.BUS_MASTER)==c.master,"%s: the master at %v, not %v",c.name,mixer.bus_lowpass(m,mixer.BUS_MASTER),c.master)
        for slot in 0..<c.count {testing.expectf(t,medium_bands(&medium,c.count,slot)==c.bands[slot],"%s: listener %d dulled by %v",c.name,slot,medium_bands(&medium,c.count,slot))}
    }

    room:Audio_World
    if !test_world_init(t,&room) {return}
    defer test_world_destroy(&room)
    level:=Audio_Reverb{room_size=0.5,damping=0.1,wet=0.2,width=1}
    e:=core.create(&room.entities)
    core.add(&room.reverbs,e,level)
    core.add(&room.worlds,e,core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
    test_world_settle(&room)
    room.view=core.View{position={0,-2,0},rotation=1}
    mixed:Mixer_Reverb
    settings:Audio_Settings
    hear :: proc(room:^Audio_World,settings:^Audio_Settings,medium:^Audio_Medium,mixed:^Mixer_Reverb,app:^host.App) -> Reverb {
        for _ in 0..<60 {audio_reverb(core.read(&room.reverbs),core.read(&room.volumes),core.read(&room.worlds),nil,core.read(&room.sections),nil,core.read(&room.listeners),core.ref(&room.view),core.ref(settings),core.ref(medium),{dt=0.1},mixed,app.mixer,{})}
        got,_:=mixer.reverb_get(app.mixer)
        return got
    }
    near :: proc(a,b:Reverb) -> bool {return abs(a.room_size-b.room_size)<1e-3 && abs(a.damping-b.damping)<1e-3 && abs(a.wet-b.wet)<1e-3 && abs(a.width-b.width)<1e-3}
    under,half_under,air:Audio_Medium
    under.listeners[0]=water
    half_under.listeners[0]=water
    half_under.listeners[0].weight=0.5
    testing.expect(t,near(hear(&room,&settings,&under,&mixed,&f.app),water.reverb),"under the water, the reverb of the water")
    half:=Reverb{0.4,0.5,0.4,0.75}
    testing.expect(t,near(hear(&room,&settings,&half_under,&mixed,&f.app),half),"half of each")
    testing.expect(t,near(hear(&room,&settings,&air,&mixed,&f.app),(^Reverb)(&level)^),"in the air, the room")
    positions,count:=listener_positions(core.read(&room.worlds),core.read(&room.listeners),core.ref(&room.view))
    testing.expect(t,count==1 && positions[0]==room.view.position,"without an Audio_Listener the View hears")
    // Two players, one under water: the average of the room of each.
    for position in ([2][3]f32{{0,-2,0},{5,-2,0}}) {
        hearer:=core.create(&room.entities)
        core.add(&room.listeners,hearer,Audio_Listener{})
        placed:=mm.TRANSFORM_IDENTITY
        placed.position=position
        core.add(&room.worlds,hearer,core.World_Transform{placed,placed})
    }
    test_world_settle(&room)
    positions,count=listener_positions(core.read(&room.worlds),core.read(&room.listeners),core.ref(&room.view))
    testing.expect(t,count==2 && positions[1]==[3]f32{5,-2,0},"each Audio_Listener hears, and the View does not")
    both:=transmute(Reverb)(((transmute([4]f32)water.reverb)+(transmute([4]f32)(^Reverb)(&level)^))*0.5)
    testing.expect(t,near(hear(&room,&settings,&under,&mixed,&f.app),both),"one in the water and one in the air: half of each")
}

@(test)
the_output_follows_the_setting_and_the_default_plays_while_it_is_not_connected :: proc(t:^testing.T) {
    m,error:=mixer.mixer_create({})
    if !testing.expect_value(t,error,mixer.Error.None) {return}
    defer mixer.mixer_destroy(m)
    p,platform_error:=platform.create({headless=true})
    if !testing.expect_value(t,platform_error,platform.Error.None) {return}
    // The device goes before the mixer.
    defer platform.destroy(p)
    app:=host.App{mixer=m,platform=p,allocator=context.allocator}
    applied:Mixer_Output
    problems:core.Problems
    output:Audio_Output
    // Without an output of the system there is nothing to change.
    audio_output(output,&applied,&app,&problems)
    testing.expect(t,!applied.set)
    if !testing.expect_value(t,platform.audio_device_open(p,m,{driver="dummy"}),platform.Audio_Error.None) {return}
    audio_output(output,&applied,&app,&problems)
    testing.expect(t,applied.set && problems.count==0)
    for name in platform.audio_device_names(p,context.temp_allocator) {
        base.text_set(output.device[:],name)
        audio_output(output,&applied,&app,&problems)
        testing.expect_value(t,problems.count,0)
    }
    base.text_set(output.device[:],"no such output")
    audio_output(output,&applied,&app,&problems)
    testing.expect(t,platform.audio_device_is_open(p))
    testing.expect(t,core.problem_find(&problems,core.NONE,"audio.output")!=nil)
    // Unchanged, it is not opened again.
    audio_output(output,&applied,&app,&problems)
    testing.expect_value(t,core.problem_find(&problems,core.NONE,"audio.output").count,u64(1))
    // The chosen output is unplugged: the next frame plays the default and
    // tells it once; plugged in again, the chosen one plays again.
    count:i32
    devices:=sdl.GetAudioPlaybackDevices(&count)
    if !testing.expect(t,devices!=nil && count>0) {return}
    defer sdl.free(devices)
    base.text_set(output.device[:],string(sdl.GetAudioDeviceName(devices[0])))
    audio_output(output,&applied,&app,&problems)
    testing.expect(t,!applied.missing)
    unplugged,plugged:sdl.Event
    unplugged.type=.AUDIO_DEVICE_REMOVED
    unplugged.adevice.which=devices[0]
    plugged.type=.AUDIO_DEVICE_ADDED
    plugged.adevice.which=devices[0]
    steps:=[?]struct{event:^sdl.Event,missing:bool}{{&unplugged,true},{nil,true},{&plugged,false},{nil,false}}
    for step in steps {
        if step.event!=nil {testing.expect(t,sdl.PushEvent(step.event))}
        platform.frame_begin(p)
        audio_output(output,&applied,&app,&problems)
        testing.expect(t,applied.missing==step.missing && platform.audio_device_is_open(p))
        testing.expect_value(t,core.problem_find(&problems,core.NONE,"audio.output").count,u64(2))
    }
}

// A voice draws its variation from its set once: the source tunes it in
// place, and a source that changed nothing writes nothing.
@(test)
a_voice_is_tuned_in_place_and_a_quiet_source_writes_nothing :: proc(t:^testing.T) {
    set:=asset.SOUND_SET_DEFAULTS
    set.volume_min,set.volume_max,set.pitch_min,set.pitch_max=0.5,0.75,0.9,1.2
    f:Fixture
    if !fixture_init(t,&f,set) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.volume,source.pitch=STEPS,true,0.8,2
    w:Heard_World
    e,made:=world_init(t,&w,source);defer world_destroy(&w)
    if !made {return}
    world_run(&w,&listener,&f.app)
    entry:=core.entity_map_get(&w.voices.entries,e)
    if !testing.expect(t,entry!=nil) {return}
    testing.expect(t,entry.pick[0]>=0.5 && entry.pick[0]<=0.75 && entry.pick[1]>=0.9 && entry.pick[1]<=1.2)
    voice,pick:=entry.voice,entry.pick
    seen:core.Seen
    _=core.changes(&w.states,&seen)
    world_run(&w,&listener,&f.app)
    testing.expect(t,!core.changes(&w.states,&seen).written,"a source that changed nothing writes nothing")
    changed:=core.edit(&w.sources,e)
    changed.pitch,changed.volume=0.5,0.4
    world_run(&w,&listener,&f.app)
    entry=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry.voice==voice && entry.pick==pick && w.voices.stats.started==1,"the same voice, with the same variation")
}

// A sound without loop that ended plays again from its start by one more in
// plays, and so does one that still plays.
@(test)
one_more_play_plays_a_source_again :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound=HUM
    w:Heard_World
    e,made:=world_init(t,&w,source);defer world_destroy(&w)
    if !made {return}
    world_run(&w,&listener,&f.app)
    out:=make([]f32,mixer.CHUNK_FRAMES*8*2,context.temp_allocator)
    for _ in 0..<8 {mixer.mixer_render(m,out)}
    mixer.mixer_update(m)
    world_run(&w,&listener,&f.app)
    world_run(&w,&listener,&f.app)
    state,_:=core.get(&w.states,e)
    testing.expect(t,state.ended && state.voice=={} && w.voices.stats.started==1 && w.voices.stats.ended==1,"it ended and stays ended")
    core.edit(&w.sources,e).plays+=1
    world_run(&w,&listener,&f.app)
    state,_=core.get(&w.states,e)
    testing.expect(t,!state.ended && state.voice!={} && w.voices.stats.started==2,"one more play plays it again")
    voice:=state.voice
    core.edit(&w.sources,e).plays+=1
    world_run(&w,&listener,&f.app)
    state,_=core.get(&w.states,e)
    testing.expect(t,state.voice!=voice && mixer.voice_valid(m,state.voice) && w.voices.stats.started==3,"while it plays it starts over")
}

// A placed request is the voice of a source there: on speakers, near and in
// sight, both come out sample for sample alike, through the same cheap path.
@(test)
a_placed_request_plays_as_a_source_at_its_place :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    testing.expect_value(t,mixer.mixer_output(m),Output_Kind.Speakers)
    at:=[3]f32{0.5,0,-1}
    heard :: proc(m:^Mixer) -> []f32 {
        out:=make([]f32,mixer.CHUNK_FRAMES*4*2,context.temp_allocator)
        mixer.mixer_render(m,out)
        return out
    }
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    play(&sounds,HUM,at=at)
    audio_requests(&sounds,core.Time{},{},nil,nil,&f.app,nil)
    requested:=heard(m)
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.spatial=HUM,true
    w:Heard_World
    _,made:=world_init(t,&w,source,at);defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={},1 // where the mixer hears the request from
    // The request, a tenth of a second long, ends before the source starts.
    for _ in 0..<6 {_=heard(m)}
    mixer.mixer_update(m)
    world_run(&w,&listener,&f.app)
    sourced:=heard(m)
    worst:=f32(0)
    for x,i in requested {worst=max(worst,abs(x-sourced[i]))}
    testing.expectf(t,worst==0 && requested[len(requested)-2]!=0,"a request and a source at one place differ by %v",worst)
}

// More sources than voices: the loudest at the listener hold the voices, the
// rest and one beyond its range keep their time without one; a steady scene
// starts, stops and steals nothing and does not allocate; walking up to a far
// one brings it back where its loop would be.
@(test)
the_loudest_sources_hold_the_voices_and_the_others_keep_their_time :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    voices:=mixer.voices_free(m)
    listener:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial=HUM,true,true
    w:Heard_World
    _,made:=world_init(t,&w,source,{0,0,-500});defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={},1
    line:[80]core.Entity
    for &e,i in line {
        e=core.create(&w.entities)
        core.add(&w.sources,e,source)
        placed:=mm.TRANSFORM_IDENTITY
        placed.position={0,0,-(1+f32(i)*0.2)}
        core.add(&w.worlds,e,core.World_Transform{placed,placed})
    }
    test_world_settle(&w.data)
    frame :: proc(w:^Heard_World,listener:^Mixer_Listeners,app:^host.App) {
        out:[mixer.CHUNK_FRAMES*2]f32
        world_run(w,listener,app)
        for _ in 0..<3 {mixer.mixer_render(app.mixer,out[:])}
        mixer.mixer_update(app.mixer)
    }
    held :: proc(w:^Heard_World,e:core.Entity) -> bool {
        entry:=core.entity_map_get(&w.voices.entries,e)
        return entry!=nil && entry.voice!={}
    }
    frame(&w,&listener,&f.app)
    testing.expect_value(t,len(w.voices.entries.values),len(line)+1)
    testing.expect(t,!held(&w,core.entity_at(core.read(&w.sources),0)),"beyond its range it holds no voice")
    for e,i in line {testing.expectf(t,held(&w,e)==(i<voices),"source %d at %v m holds a voice: %v",i,1+f32(i)*0.2,held(&w,e))}

    before:=mixer.mixer_stats(m)
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    for _ in 0..<100 {
        hearing:=Hearing{core.read(&w.worlds),core.read(&w.occlusions),core.read(&w.materials),core.read(&w.listeners),core.ref(&w.view),{},w.query}
        {
            context.allocator,context.temp_allocator=mem.tracking_allocator(&track),mem.tracking_allocator(&track)
            sources_update(core.read(&w.sources),&w.states,hearing,1.0/60,&w.voices,&listener,&f.app,nil)
        }
        test_world_settle(&w.data)
        out:[mixer.CHUNK_FRAMES*2]f32
        for _ in 0..<3 {mixer.mixer_render(m,out[:])}
        mixer.mixer_update(m)
    }
    after:=mixer.mixer_stats(m)
    testing.expect_value(t,track.total_allocation_count,i64(0))
    testing.expect(t,after.voices_played==before.voices_played && after.voices_stolen==0,"a steady scene starts and steals nothing")

    // Walking up to the farthest, it comes back where its loop is now.
    far:=line[len(line)-1]
    w.view.position={0,0,-(1+f32(len(line)-1)*0.2)}
    for _ in 0..<2 {frame(&w,&listener,&f.app)}
    if !testing.expect(t,held(&w,far),"the source walked up to holds a voice") {return}
    voice:=core.entity_map_get(&w.voices.entries,far).voice
    started:=-1
    for feed in m.feeds {
        if feed.owner==voice {started=feed.offset}
    }
    // The frames rendered since it started, less the chunks rendered after it came back.
    want:=(int(mixer.mixer_clock(m))-3*mixer.CHUNK_FRAMES)%int(mixer.sound_frames(m,host.content_sound(&f.app,HUM)))
    testing.expectf(t,abs(started-want)<=1,"it comes back %d frames into its loop, not %d",started,want)
    testing.expect_value(t,mixer.mixer_stats(m).voices_stolen,u64(0))
}

// A source with values that are not numbers, or heard over no range, plays
// nothing and says so.
@(test)
a_source_of_hostile_values_is_refused :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    nan:=math.nan_f32()
    Case :: struct {name:string,change:proc(s:^Audio_Source,nan:f32)}
    for c in ([?]Case{
        {"a volume that is not a number",proc(s:^Audio_Source,nan:f32) {s.volume=nan}},
        {"a pitch below 0",proc(s:^Audio_Source,nan:f32) {s.pitch=-1}},
        {"a reverb that is not a number",proc(s:^Audio_Source,nan:f32) {s.reverb=nan}},
        {"no range",proc(s:^Audio_Source,nan:f32) {s.max_distance=s.min_distance}},
        {"a min_distance of 0",proc(s:^Audio_Source,nan:f32) {s.min_distance=0}},
        {"an infinite range",proc(s:^Audio_Source,nan:f32) {s.max_distance=math.inf_f32(1)}},
    }) {
        source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial=HUM,true,true
        c.change(&source,nan)
        problems:core.Problems
        listener:Mixer_Listeners
        w:Heard_World
        e,made:=world_init(t,&w,source,{0,0,-2})
        if !made {return}
        hearing:=Hearing{core.read(&w.worlds),core.read(&w.occlusions),core.read(&w.materials),core.read(&w.listeners),core.ref(&w.view),{},w.query}
        sources_update(core.read(&w.sources),&w.states,hearing,1.0/60,&w.voices,&listener,&f.app,&problems)
        testing.expectf(t,core.entity_map_get(&w.voices.entries,e)==nil && core.problem_find(&problems,e,"audio.source")!=nil,"%s is refused",c.name)
        world_destroy(&w)
    }
}

// audio.play hears a set as the set says: its range, its reverb send and its
// priority; placed beyond its range it does not start.
@(test)
a_request_is_heard_as_its_set_says :: proc(t:^testing.T) {
    for c in ([?]struct{max_distance:f32,plays:bool}{{300,true},{20,false}}) {
        set:=asset.SOUND_SET_DEFAULTS
        set.hearing={attenuation=.Inverse,min_distance=1,max_distance=c.max_distance,rolloff=1,reverb=0.6,priority=7}
        f:Fixture
        if !fixture_init(t,&f,set) {return}
        m:=f.app.mixer
        problems:core.Problems
        listener:=Mixer_Listeners{slots={0={rotation=1}},count=1}
        sounds:Sound_Requests
        play(&sounds,STEPS,at=[3]f32{0,0,-50})
        play(&sounds,STEPS,at=[3]f32{0,0,-200})
        audio_requests(&sounds,core.Time{},{},nil,&listener,&f.app,&problems)
        stats:=mixer.mixer_stats(m)
        testing.expectf(t,stats.voices_played==(2 if c.plays else 0),"within %v m: %d played",c.max_distance,stats.voices_played)
        testing.expect_value(t,problems.count,0)
        if c.plays {
            out:[mixer.CHUNK_FRAMES*2]f32
            mixer.mixer_render(m,out[:])
            near,far:=m.voices[0],m.voices[1]
            testing.expectf(t,far.direct_gain>0 && far.direct_gain<near.direct_gain,"at 200 m %v, at 50 m %v",far.direct_gain,near.direct_gain)
            testing.expect(t,near.reverb==0.6 && m.shadows[0].priority==7 && m.shadows[1].priority==7)
        }
        core.value_free(&sounds,type_info_of(Sound_Requests))
        fixture_destroy(&f)
    }
}

// A wall between every source and the listener on its +X side.
@(private="file")
east_wall_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (core.World_Hit,bool) {
    return {distance=length*0.5},direction.x>0
}

@(private="file")
listener_add :: proc(w:^Audio_World,position:[3]f32) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.listeners,e,Audio_Listener{})
    placed:=mm.TRANSFORM_IDENTITY
    placed.position=position
    core.add(&w.worlds,e,core.World_Transform{placed,placed})
    return e
}

// Two players of a split screen 20 m apart: a source is heard from the nearer,
// keeps its listener within LISTENER_SWITCH of the middle, tests what hides it
// from the new one at once when it goes over, and is as loud as at its
// nearest listener; the motion of either moves no pitch, and one under water
// dulls only the voices heard from it.
@(test)
each_source_is_heard_from_its_nearest_listener_of_a_split_screen :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    listeners:Mixer_Listeners
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial,source.max_distance=HUM,true,true,50
    w:Heard_World
    e,made:=world_init(t,&w,source,{9,0,0});defer world_destroy(&w)
    if !made {return}
    core.add(&w.occlusions,e,Audio_Occlusion{radius=0,fade=10})
    first:=listener_add(&w.data,{})
    second:=listener_add(&w.data,{20,0,0})
    test_world_settle(&w.data)
    wall:=false
    w.query={user=&wall,probe=east_wall_probe}
    medium:Audio_Medium
    run :: proc(w:^Heard_World,listeners:^Mixer_Listeners,medium:^Audio_Medium,app:^host.App) {
        hearing:=Hearing{core.read(&w.worlds),core.read(&w.occlusions),core.read(&w.materials),core.read(&w.listeners),core.ref(&w.view),core.ref(medium),w.query}
        sources_update(core.read(&w.sources),&w.states,hearing,1.0/60,&w.voices,listeners,app,nil)
        test_world_settle(&w.data)
        out:[mixer.CHUNK_FRAMES*2]f32
        mixer.mixer_render(app.mixer,out[:])
        mixer.mixer_update(app.mixer)
    }
    run(&w,&listeners,&medium,&f.app)
    testing.expect(t,listeners.count==2 && listeners.slots[1].position==[3]f32{20,0,0})
    entry:=core.entity_map_get(&w.voices.entries,e)
    if !testing.expect(t,entry!=nil && entry.voice!={}) {return}
    wall=true
    // At x the source is 10+d from one and 10-d from the other: it goes over past 12% nearer.
    Step :: struct {x:f32,listener:u8,occlusion:f32}
    for s in ([?]Step{{9,0,0},{10.5,0,0},{10.7,1,1},{9.5,1,1},{9.2,0,0}}) {
        core.edit(&w.worlds,e).position={s.x,0,0}
        test_world_settle(&w.data)
        run(&w,&listeners,&medium,&f.app)
        entry=core.entity_map_get(&w.voices.entries,e)
        state,_:=core.get(&w.states,e)
        index:=base.handle_index(base.Handle(entry.voice))
        testing.expectf(t,entry.listener==s.listener && m.voices[index].listener==s.listener,"at %v m: heard from %d (the mixer %d), not %d",s.x,entry.listener,m.voices[index].listener,s.listener)
        testing.expectf(t,state.occlusion==s.occlusion,"at %v m: hidden %v from its listener at once, not %v",s.x,state.occlusion,s.occlusion)
    }
    wall=false

    // Out of the range of the first, near the second: it holds its voice.
    core.edit(&w.worlds,e).position={-95,0,0}
    test_world_settle(&w.data)
    core.edit(&w.worlds,second).position={-100,0,0}
    test_world_settle(&w.data)
    run(&w,&listeners,&medium,&f.app)
    entry=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry.voice!={} && entry.listener==1,"near the second it is heard, from the second")

    // The second runs from it: no pitch moves with two listeners, and with one it does.
    for count in ([?]int{2,1}) {
        if count==1 {core.disable(&w.listeners,first)}
        test_world_settle(&w.data)
        source.doppler=1
        core.edit(&w.sources,e)^=source
        test_world_settle(&w.data)
        for i in 0..<3 {
            core.edit(&w.worlds,second).position={-100+f32(i+1)*2,0,0}
            test_world_settle(&w.data)
            run(&w,&listeners,&medium,&f.app)
        }
        entry=core.entity_map_get(&w.voices.entries,e)
        pitch:=m.voices[base.handle_index(base.Handle(entry.voice))].spatial_pitch
        testing.expectf(t,(pitch==1)==(count==2),"%d listeners running away: pitch %v",count,pitch)
    }
    core.enable(&w.listeners,first)
    test_world_settle(&w.data)

    // Under water, the second dulls what it hears; both under, the master does.
    medium.listeners[1]=Medium{lowpass=800,weight=1}
    run(&w,&listeners,&medium,&f.app)
    testing.expect(t,listeners.count==2 && listeners.slots[1].medium==mixer.lowpass_bands(800) && listeners.slots[0].medium==[mixer.BANDS]f32{1,1,1})
    medium.listeners[0]=Medium{lowpass=800,weight=1}
    run(&w,&listeners,&medium,&f.app)
    testing.expect(t,listeners.slots[0].medium==[mixer.BANDS]f32{1,1,1} && listeners.slots[1].medium==[mixer.BANDS]f32{1,1,1})
}

// A one-shot far from the first player and near the second plays, from the
// second; one beyond the range of both does not start.
@(test)
a_request_near_any_listener_plays_from_the_nearest :: proc(t:^testing.T) {
    set:=asset.SOUND_SET_DEFAULTS
    set.hearing={attenuation=.Inverse,min_distance=1,max_distance=20,rolloff=1,priority=1}
    f:Fixture
    if !fixture_init(t,&f,set) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    problems:core.Problems
    listeners:=Mixer_Listeners{slots={0={rotation=1},1={position={300,0,0},rotation=1}},count=2}
    testing.expect(t,mixer.listeners_set_count(m,2) && mixer.listener_set(m,{300,0,0},1,slot=1))
    sounds:Sound_Requests
    defer core.value_free(&sounds,type_info_of(Sound_Requests))
    play(&sounds,STEPS,at=[3]f32{295,0,0})
    play(&sounds,STEPS,at=[3]f32{150,0,0})
    audio_requests(&sounds,core.Time{},{},nil,&listeners,&f.app,&problems)
    testing.expect_value(t,mixer.mixer_stats(m).voices_played,u64(1))
    out:[mixer.CHUNK_FRAMES*2]f32
    mixer.mixer_render(m,out[:])
    testing.expectf(t,m.voices[0].listener==1 && m.voices[0].direct_gain>0.15,"heard from the second, 5 m away: from %d at %v",m.voices[0].listener,m.voices[0].direct_gain)
}
