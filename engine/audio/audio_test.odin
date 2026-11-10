package audio

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"

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
    info.sounds[0],info.sounds[1]={sound=STEP_A},{sound=STEP_B}
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

@(private="file")
Audio_World :: struct {
    using world:core.Test_World,
    sources:core.Table(Audio_Source),
    states:core.Table(Audio_Source_State),
    worlds:core.Table(core.World_Transform),
    listeners:core.Table(Audio_Listener),
    occlusions:core.Table(Audio_Occlusion),
    reverbs:core.Table(Audio_Reverb),
    volumes:core.Table(volume.Volume),
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
    core.test_world_init(t,&w.data,test_types) or_return
    e=core.create(&w.entities)
    core.add(&w.sources,e,source)
    placed:=mm.TRANSFORM_IDENTITY
    placed.position=position
    core.add(&w.worlds,e,core.World_Transform{placed,placed})
    core.test_world_settle(&w.data)
    return e,true
}

@(private="file")
world_destroy :: proc(w:^Heard_World) {
    core.value_free(&w.voices,type_info_of(Voices))
    core.test_world_destroy(&w.data)
}

@(private="file")
world_run :: proc(w:^Heard_World,listener:^Mixer_Listener,app:^host.App,dt:f32=1.0/60) {
    hearing:=Hearing{core.read(&w.worlds),core.read(&w.occlusions),core.read(&w.listeners),core.ref(&w.view),w.query}
    sources_update(core.read(&w.sources),&w.states,hearing,dt,&w.voices,listener,app,nil)
    core.test_world_settle(&w.data)
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
    listener:Mixer_Listener
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
    core.get(&shown.sources,e).bus=BUS_MUSIC
    world_run(&shown,&listener,&f.app)
    moved:=core.entity_map_get(&shown.voices.entries,e)
    testing.expect(t,moved!=nil && moved.voice!=voice && moved.bus==BUS_MUSIC && mixer.bus_count(m)>int(BUS_MUSIC))

    // A source that goes takes its voice with it.
    core.remove(&shown.sources,e)
    core.test_world_settle(&shown.data)
    world_run(&shown,&listener,&f.app)
    testing.expect_value(t,len(shown.voices.entries.values),0)
}

@(test)
a_tick_that_runs_again_does_not_play_its_sounds_again :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    tick:=core.Time{dt=1.0/60,playing=true}
    replay:=tick
    replay.resimulating=true
    testing.expect_value(t,play_asset(&f.app,replay,HUM),Voice{})
    testing.expect_value(t,play_asset_at(&f.app,replay,HUM,{1,0,0}),Voice{})
    voice:=play_asset(&f.app,tick,STEPS)
    testing.expect(t,voice!={} && playing(f.app.mixer,voice))
    testing.expect(t,stop(f.app.mixer,voice))
    testing.expect_value(t,play_asset(&f.app,tick,HUM,bus=Audio_Bus(AUDIO_BUS_CAPACITY)),Voice{})
}

@(test)
a_sound_set_plays_its_sounds_by_weight_in_its_ranges_and_not_the_same_twice :: proc(t:^testing.T) {
    set:=asset.SOUND_SET_DEFAULTS
    set.volume_min,set.volume_max,set.pitch_min,set.pitch_max=0.5,0.75,0.9,1.2
    f:Fixture
    if !fixture_init(t,&f,set) {return}
    defer fixture_destroy(&f)
    a,b:=host.content_sound(&f.app,STEP_A),host.content_sound(&f.app,STEP_B)
    last:mixer.Sound
    for _ in 0..<32 {
        pick:=host.content_sound_pick(&f.app,STEPS)
        testing.expect(t,pick.sound==a || pick.sound==b)
        testing.expect(t,pick.sound!=last,"no_repeat never chooses the same sound twice in a row")
        testing.expect(t,pick.volume>=0.5 && pick.volume<=0.75 && pick.pitch>=0.9 && pick.pitch<=1.2)
        last=pick.sound
    }
    single:=host.content_sound_pick(&f.app,HUM)
    testing.expect(t,single.sound==host.content_sound(&f.app,HUM) && single.volume==1 && single.pitch==1)
    testing.expect(t,host.content_sound_generation(&f.app,STEPS)!=0 && host.content_sound_generation(&f.app,{9,9})==0)
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
    volumes:=AUDIO_VOLUMES_DEFAULT
    audio_buses(core.ref(&settings),core.ref(&volumes),{},f.app.mixer)
    testing.expect(t,mixer.bus_count(m)>int(BUS_VOICE))
    testing.expect(t,abs(mixer.bus_volume(m,mixer.Bus(BUS_MUSIC))-0.5012)<0.001 && mixer.bus_lowpass(m,mixer.Bus(BUS_MUSIC))==2000)
    testing.expect(t,mixer.bus_duck(m,mixer.Bus(BUS_MUSIC)).source==mixer.Bus(BUS_VOICE) && mixer.bus_duck(m,mixer.Bus(BUS_MUSIC)).amount==0.5)
    testing.expect_value(t,mixer.bus_volume(m,mixer.BUS_MASTER),f32(0))
    testing.expect(t,mixer.bus_reverb(m,mixer.Bus(BUS_MUSIC))==hall,"a song in the music bus sounds in its hall")

    // The volume the player chose goes over the gain of the game.
    volumes.music=0.5
    audio_buses(core.ref(&settings),core.ref(&volumes),{},f.app.mixer)
    testing.expect(t,abs(mixer.bus_volume(m,mixer.Bus(BUS_MUSIC))-0.2506)<0.001)
    testing.expect_value(t,audio_volume(&volumes,BUS_MUSIC),f32(0.5))
    volumes.more[0]=0.25
    testing.expect_value(t,audio_volume(&volumes,Audio_Bus(5)),f32(0.25))
    volumes.music=max(f32)
    testing.expect_value(t,audio_volume(&volumes,BUS_MUSIC),f32(1))
    volumes.music=math.nan_f32()
    testing.expect_value(t,audio_volume(&volumes,BUS_MUSIC),f32(0))
    volumes=AUDIO_VOLUMES_DEFAULT

    // A bus whose entry goes back to playing as it comes loses its entry, and the mixer follows.
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MUSIC}))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MASTER}))
    testing.expect(t,settings==Audio_Settings{},"settings that say nothing are zeros")
    audio_buses(core.ref(&settings),core.ref(&volumes),{},f.app.mixer)
    testing.expect(t,mixer.bus_volume(m,mixer.Bus(BUS_MUSIC))==1 && mixer.bus_lowpass(m,mixer.Bus(BUS_MUSIC))==0 && mixer.bus_duck(m,mixer.Bus(BUS_MUSIC))=={} && mixer.bus_reverb(m,mixer.Bus(BUS_MUSIC))=={})
    testing.expect_value(t,mixer.bus_volume(m,mixer.BUS_MASTER),f32(1))
    testing.expect(t,db_volume(AUDIO_SILENCE_DB)==0 && abs(db_volume(-6)-0.5012)<0.001)
}

@(test)
without_a_listener_the_view_hears_and_moving_gives_it_a_velocity :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listener
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial,source.doppler=HUM,true,true,1
    w:Heard_World
    e,made:=world_init(t,&w,source,{0,0,-10});defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={5,0,0},1
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.set && listener.position==[3]f32{5,0,0} && listener.velocity==[3]f32{})
    w.view.position={6,0,0}
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.position==[3]f32{6,0,0} && listener.velocity==[3]f32{2,0,0})
    w.view.cut=true
    w.view.position={60,0,0}
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.velocity==[3]f32{},"a view that jumped does not move")

    // A source that moves tells its velocity, and stops telling it once it rests.
    core.get(&w.worlds,e).position={0,0,-9}
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
    core.test_world_settle(&w.data)
    world_run(&w,&listener,&f.app,0.5)
    testing.expect(t,listener.position==[3]f32{0,2,0})
    testing.expect(t,!math.is_nan(listener.velocity.x))
}

// A wall that stands between every source and the listener while user points at true.
@(private="file")
wall_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (core.World_Hit,bool) {
    return {distance=length*0.5},(cast(^bool)user)^
}

@(test)
a_source_behind_a_wall_goes_down_and_duller_and_comes_back_over_its_fade :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listener
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.spatial=HUM,true,true
    w:Heard_World
    e,made:=world_init(t,&w,source,{0,0,-10});defer world_destroy(&w)
    if !made {return}
    w.view.position,w.view.rotation={},1
    wall:=true
    w.query={user=&wall,probe=wall_probe}
    core.add(&w.occlusions,e,Audio_Occlusion{volume=0.25,lowpass=500,fade=0.5})
    core.test_world_settle(&w.data)
    world_run(&w,&listener,&f.app,0.1)
    entry:=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry!=nil && core.get(&w.states,e).occlusion==1,"a voice that starts hidden is hidden at once")
    testing.expect(t,abs(entry.volume-0.25)<1e-5 && abs(entry.lowpass-500)<0.5)

    wall=false
    world_run(&w,&listener,&f.app,0.1)
    amount:=core.get(&w.states,e).occlusion
    testing.expect(t,abs(amount-0.8)<1e-4,"it comes back a fifth of the way in a tenth of its fade")
    entry=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,entry.volume>0.25 && entry.volume<1 && entry.lowpass>500)
    for _ in 0..<5 {world_run(&w,&listener,&f.app,0.1)}
    entry=core.entity_map_get(&w.voices.entries,e)
    testing.expect(t,core.get(&w.states,e).occlusion==0 && entry.volume==1 && entry.lowpass==0,"in sight it plays as it is")

    // Near the listener nothing hides it: that is its own body.
    wall=true
    core.get(&w.worlds,e).position={0,0,-0.3}
    world_run(&w,&listener,&f.app,0.1)
    testing.expect_value(t,core.get(&w.states,e).occlusion,f32(0))
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
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
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
    place(&w,level,nil,{},{1,1,1})
    place(&w,hall,volume.Volume{shape=.Box,extents={20,10,20}},{},{1,1,1})
    place(&w,cave,volume.Volume{shape=.Box,extents={2,2,2}},{10,0,0},{2,1,1}) // 4 m along x once scaled
    place(&w,closet,volume.Volume{shape=.Box,extents={1,1,1},priority=-1},{13,0,0},{1,1,1})
    core.test_world_settle(&w)
    at :: proc(p:^Audio_World,point:[3]f32) -> f32 {
        return volume.at(core.read(&p.volumes),core.read(&p.worlds),core.read(&p.reverbs),point,Audio_Reverb{},reverb_mix).room_size
    }
    testing.expect_value(t,at(&w,{0,0,0}),f32(0.9))
    testing.expect_value(t,at(&w,{13.5,0,0}),f32(0.3))
    testing.expect_value(t,at(&w,{0,15,0}),f32(0.5))

    settings:Audio_Settings
    w.view=core.View{position={0,15,0},rotation=1}
    mixer_reverb:Mixer_Reverb
    run :: proc(p:^Audio_World,settings:^Audio_Settings,dt:f32,r:^Mixer_Reverb,app:^host.App) {
        audio_reverb(core.read(&p.reverbs),core.read(&p.volumes),core.read(&p.worlds),core.read(&p.listeners),core.ref(&p.view),core.ref(settings),{},{dt=dt},r,app.mixer)
    }
    run(&w,&settings,0.1,&mixer_reverb,&f.app)
    got,_:=mixer.reverb_get(f.app.mixer)
    testing.expect(t,got==transmute(Reverb)level,"outside of every box, the level; the first one at once")
    w.view.position={0,0,0}
    run(&w,&settings,0.1,&mixer_reverb,&f.app)
    got,_=mixer.reverb_get(f.app.mixer)
    testing.expect(t,got.room_size>0.5 && got.room_size<0.9,"it goes toward the hall")
    for _ in 0..<40 {run(&w,&settings,0.1,&mixer_reverb,&f.app)}
    got,_=mixer.reverb_get(f.app.mixer)
    testing.expect(t,got==transmute(Reverb)hall,"and gets there")
}

// Under the water the master loses its highs, by the lower of its own cutoff
// and that of the medium, and the reverb goes to that of the medium by its
// weight; back in the air, both are those of the settings and the room.
@(test)
the_medium_around_the_listener_dulls_the_master_and_mixes_its_reverb :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    settings:Audio_Settings
    volumes:=AUDIO_VOLUMES_DEFAULT
    water:=Audio_Medium{lowpass=700,reverb={room_size=0.3,damping=0.9,wet=0.6,width=0.5},weight=1}
    audio_buses(core.ref(&settings),core.ref(&volumes),core.ref(&water),f.app.mixer)
    testing.expect_value(t,mixer.bus_lowpass(m,mixer.BUS_MASTER),f32(700))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MASTER,lowpass=500}))
    audio_buses(core.ref(&settings),core.ref(&volumes),core.ref(&water),f.app.mixer)
    testing.expect_value(t,mixer.bus_lowpass(m,mixer.BUS_MASTER),f32(500))
    testing.expect(t,audio_bus_setting_set(&settings,{bus=BUS_MASTER,lowpass=4000}))
    audio_buses(core.ref(&settings),core.ref(&volumes),core.ref(&water),f.app.mixer)
    testing.expect_value(t,mixer.bus_lowpass(m,mixer.BUS_MASTER),f32(700))
    air:Audio_Medium
    audio_buses(core.ref(&settings),core.ref(&volumes),core.ref(&air),f.app.mixer)
    testing.expect_value(t,mixer.bus_lowpass(m,mixer.BUS_MASTER),f32(4000))

    room:Audio_World
    if !core.test_world_init(t,&room,test_types) {return}
    defer core.test_world_destroy(&room)
    level:=Audio_Reverb{room_size=0.5,damping=0.1,wet=0.2,width=1}
    e:=core.create(&room.entities)
    core.add(&room.reverbs,e,level)
    core.add(&room.worlds,e,core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
    core.test_world_settle(&room)
    room.view=core.View{position={0,-2,0},rotation=1}
    mixed:Mixer_Reverb
    hear :: proc(r:core.Read(Audio_Reverb),v:core.Read(volume.Volume),w:core.Read(core.World_Transform),l:core.Read(Audio_Listener),view:^core.View,settings:^Audio_Settings,medium:^Audio_Medium,mixed:^Mixer_Reverb,app:^host.App) -> Reverb {
        for _ in 0..<60 {audio_reverb(r,v,w,l,core.ref(view),core.ref(settings),core.ref(medium),{dt=0.1},mixed,app.mixer)}
        got,_:=mixer.reverb_get(app.mixer)
        return got
    }
    near :: proc(a,b:Reverb) -> bool {return abs(a.room_size-b.room_size)<1e-3 && abs(a.damping-b.damping)<1e-3 && abs(a.wet-b.wet)<1e-3 && abs(a.width-b.width)<1e-3}
    r,v,w,l:=core.read(&room.reverbs),core.read(&room.volumes),core.read(&room.worlds),core.read(&room.listeners)
    testing.expect(t,near(hear(r,v,w,l,&room.view,&settings,&water,&mixed,&f.app),water.reverb),"under the water, the reverb of the water")
    water.weight=0.5
    half:=Reverb{0.4,0.5,0.4,0.75}
    testing.expect(t,near(hear(r,v,w,l,&room.view,&settings,&water,&mixed,&f.app),half),"half of each")
    testing.expect(t,near(hear(r,v,w,l,&room.view,&settings,&air,&mixed,&f.app),transmute(Reverb)level),"in the air, the room")
    position,found:=listener_position(w,l,core.ref(&room.view))
    testing.expect(t,found && position==room.view.position,"without an Audio_Listener the View hears")
}

@(test)
a_source_heard_alone_plays_as_it_is_set_and_follows_its_changes :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    source:=AUDIO_SOURCE_DEFAULT
    source.sound,source.bus,source.loop,source.pitch=HUM,BUS_MUSIC,true,2
    voice:=play_source(&f.app,{},source)
    testing.expect(t,voice!={} && mixer.bus_count(m)>int(BUS_MUSIC),"it plays in its bus")
    // Twice the sound at twice its speed, a frame of the game at a time.
    render :: proc(m:^mixer.Mixer) {
        out:=make([]f32,960*2,context.temp_allocator)
        for _ in 0..<10 {
            mixer.mixer_render(m,out)
            mixer.mixer_update(m)
        }
    }
    render(m)
    testing.expect(t,playing(f.app.mixer,voice),"a loop goes on")
    source.loop=false
    source_tune(f.app.mixer,voice,source)
    render(m)
    testing.expect(t,!playing(f.app.mixer,voice),"once it does not loop, it ends")
}

@(test)
a_source_heard_at_a_place_falls_by_its_curve_and_follows_where_it_is_moved :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_init(t,&f) {return}
    defer fixture_destroy(&f)
    m:=f.app.mixer
    mixer.listener_set(m,{0,0,0},1)
    source:=AUDIO_SOURCE_DEFAULT
    source.sound,source.loop,source.attenuation,source.min_distance,source.max_distance=HUM,true,.Linear,1,20
    // The loudest sample of a few frames of the game.
    peak :: proc(m:^mixer.Mixer) -> f32 {
        out:=make([]f32,960*2,context.temp_allocator)
        loudest:f32
        for _ in 0..<6 {
            mixer.mixer_render(m,out)
            mixer.mixer_update(m)
        }
        for sample in out {loudest=max(loudest,abs(sample))}
        return loudest
    }
    voice:=play_source_at(&f.app,{},source,{0,0,-30})
    if !testing.expect(t,voice!={},"it plays") {return}
    testing.expect(t,peak(m)<1e-4,"beyond its max_distance its linear curve leaves it silent")
    source_place(f.app.mixer,voice,{0,0,-1})
    testing.expect(t,peak(m)>0.05,"moved within its min_distance it is heard whole")
    testing.expect(t,playing(f.app.mixer,voice),"a loop goes on")
}

@(test)
the_output_follows_the_setting_and_one_the_system_does_not_list_plays_the_default :: proc(t:^testing.T) {
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
}

// What a voice is given is its source by what its set drew, also after the
// source changes its pitch and its volume.
@(test)
a_voice_is_given_its_source_by_what_its_set_drew :: proc(t:^testing.T) {
    set:=asset.SOUND_SET_DEFAULTS
    set.volume_min,set.volume_max,set.pitch_min,set.pitch_max=0.5,0.75,0.9,1.2
    f:Fixture
    if !fixture_init(t,&f,set) {return}
    defer fixture_destroy(&f)
    listener:Mixer_Listener
    source:=AUDIO_SOURCE_DEFAULT;source.sound,source.loop,source.volume,source.pitch=STEPS,true,0.8,2
    w:Heard_World
    e,made:=world_init(t,&w,source);defer world_destroy(&w)
    if !made {return}
    world_run(&w,&listener,&f.app)
    entry:=core.entity_map_get(&w.voices.entries,e)
    if !testing.expect(t,entry!=nil) {return}
    volume,pitch:=voice_entry_given(entry^)
    testing.expect(t,abs(volume-0.8*entry.pick[0])<1e-5 && abs(pitch-2*entry.pick[1])<1e-5)
    testing.expect(t,entry.pick[0]>=0.5 && entry.pick[0]<=0.75 && entry.pick[1]>=0.9 && entry.pick[1]<=1.2)
    changed:=core.get(&w.sources,e)
    changed.pitch,changed.volume=0.5,0.4
    world_run(&w,&listener,&f.app)
    entry=core.entity_map_get(&w.voices.entries,e)
    volume,pitch=voice_entry_given(entry^)
    testing.expect(t,abs(volume-0.4*entry.pick[0])<1e-5 && abs(pitch-0.5*entry.pick[1])<1e-5)
}
