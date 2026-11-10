package audio

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import mixer "mirai:audio"
import volume "mirai:engine/volume"
import "mirai:std/base"

// Sound. The mixer belongs to the application, which hands it to the
// function that asks for a ^Mixer (nil without audio); this library
// keeps its voices equal to the Audio_Source components of the world, its
// listener at the Audio_Listener entity or, without one, at the View, its
// buses as Audio_Settings says and its reverb as the Audio_Reverb volumes
// where the listener is.
// What collides in the world (core.World_Query) hides the sources that have
// an Audio_Occlusion, letting through what the Audio_Material of each body
// it crosses lets through. Its game-thread procedures are not thread-safe, so only
// this library's steps and the helpers below, called from a step that
// receives the mixer or the application, talk to it.

VOICE_RESERVE :: 256
AUDIO_BUS_CAPACITY :: 8  // the buses of the mixer, the master included
AUDIO_SILENCE_DB :: -80  // a gain at or below it silences
REVERB_FADE :: f32(0.5)  // s: the reverb goes from a room to the next in about this long
OCCLUSION_CLEARANCE :: f32(0.5) // m around the listener that does not hide: its own body
OCCLUSION_SAMPLES :: 16           // points of the sphere of a source with a radius whose sight is tested
OCCLUSION_SAMPLES_PER_FRAME :: 4  // of them tested again each frame
TRANSMISSION_SURFACES :: 4        // bodies crossed whose materials are added up between a source and the listener
@(private) TRANSMISSION_RAY_OFFSET :: f32(1e-2) // m past a surface where the next ray starts

Mixer :: mixer.Mixer
Voice :: mixer.Voice
Attenuation_Model :: mixer.Attenuation_Model
Output_Kind :: mixer.Output_Kind
Reverb :: mixer.Reverb

// Where a sound plays. The voices of a bus are mixed, filtered and turned up
// or down together before the master, as Audio_Settings says. Buses are ids
// with names declared in code (core/names.odin): the engine declares those
// below and a game its own below AUDIO_BUS_CAPACITY,
// BUS_AMBIENCE :: audio.Audio_Bus(5).
@(names="BUS_")
Audio_Bus :: distinct u8
BUS_MASTER :: Audio_Bus(0)
BUS_MUSIC :: Audio_Bus(1)
BUS_EFFECTS :: Audio_Bus(2)
BUS_VOICE :: Audio_Bus(3)
BUS_UI :: Audio_Bus(4)

// A voice that follows the entity. While playing is set the library keeps a
// voice of the sound alive: it starts it, moves it with the entity when
// spatial, applies volume, pitch and pan when they change and stops it when
// playing is cleared or the component goes away; a change of sound, bus or
// how it is heard starts it again. A .sound_set chooses one of its sounds each
// time the voice starts, and a loop repeats the one it chose. A sound that
// ends without loop sets Audio_Source_State.ended; clearing playing makes the
// source ready to play again.
@(component,description="Plays a .sound or a .sound_set: placed at the entity when spatial, or as it is.")
Audio_Source :: struct {
    sound:base.Asset_Id, // a .sound or a .sound_set
    bus:Audio_Bus,
    volume:f32 `mirai:"min=0"`,
    pitch:f32 `mirai:"min=0"`, // speed it plays at, which moves its pitch with it, as a slowed song; 0 is taken as 1
    pan:f32 `mirai:"min=-1,max=1"`, // -1 left to 1 right, when not spatial
    loop:bool,
    playing:bool,
    spatial:bool, // placed at the entity and heard from the listener: from its direction, attenuated and dulled by the air
    attenuation:Attenuation_Model, // how it falls between min_distance and max_distance
    min_distance:f32 `mirai:"min=0,unit=m"`,
    max_distance:f32 `mirai:"min=0,unit=m"`,
    rolloff:f32 `mirai:"min=0"`, // how fast it falls: 1 is the curve as its model says it
    doppler:f32 `mirai:"min=0"`, // 0: none; 1: the physical shift of pitch as it and the listener move
    reverb:f32 `mirai:"min=0,max=1"`, // share of it the room of the listener reverberates
    directivity:f32 `mirai:"min=0,max=1"`, // 0: the same all around; 0.5: loudest toward -Z of the entity and silent behind; 1: silent at its sides
    directivity_power:f32 `mirai:"min=0"`,  // how narrow the directivity is: 1 as it is, higher narrower
}

AUDIO_SOURCE_DEFAULT :: Audio_Source{bus=BUS_EFFECTS,volume=1,pitch=1,playing=true,attenuation=.Inverse,min_distance=1,max_distance=20,rolloff=1,directivity_power=1}

// A spatial source that what collides between it and the listener hides:
// Audio_Source_State.occlusion is the part of it out of sight, 0 to 1, which
// follows over fade seconds; what is hidden is heard through what hides it,
// as its Audio_Material lets through.
@(component,description="Makes a spatial sound muffled as far as something solid stands between it and the listener.")
Audio_Occlusion :: struct {
    radius:f32 `mirai:"min=0,unit=m"`, // of the sphere the sound comes from, so a wall hides it a part at a time; 0: a point
    fade:f32 `mirai:"min=0,unit=s"`,
}

AUDIO_OCCLUSION_DEFAULT :: Audio_Occlusion{radius=1,fade=0.15}

// What a body lets through of a sound it hides, per band: below 800 Hz, 800
// Hz to 8 kHz and above. A body without one lets through as
// AUDIO_MATERIAL_DEFAULT, a wall: some lows and few highs.
@(component,description="How much of a sound hidden behind this body gets through it: its lows, mids and highs.")
Audio_Material :: struct {
    transmission:[mixer.BANDS]f32 `mirai:"min=0,max=1"`,
}

AUDIO_MATERIAL_DEFAULT :: Audio_Material{transmission=mixer.TRANSMISSION_DEFAULT}

// The room the listener hears where the Volume of its entity is: a cave, a
// hall. Without a Volume it is the reverb of the whole level; without any,
// nothing reverberates.
@(component,replicated,description="The reverb the listener hears where the Volume of this entity is, as a cave or a hall; without a Volume, that of the whole level.")
Audio_Reverb :: struct {
    room_size:f32 `mirai:"min=0,max=1"`, // how long its tail lasts
    damping:f32 `mirai:"min=0,max=1"`,   // how fast the highs of its tail die
    wet:f32 `mirai:"min=0"`,             // gain of what it returns
    width:f32 `mirai:"min=0,max=1"`,     // from mono to wide stereo
}

AUDIO_REVERB_DEFAULT :: Audio_Reverb{room_size=0.6,damping=0.4,wet=1,width=1}

#assert(size_of(Audio_Reverb)==size_of(Reverb))

// What the library derived from the source. Only audio_sources writes it.
@(component)
Audio_Source_State :: struct {
    voice:mixer.Voice `mirai:"transient,readonly,local,hidden"`,
    ended:bool `mirai:"transient,readonly,local"`,
    occlusion:f32 `mirai:"transient,readonly,local"`, // 0 in sight to 1 hidden, of a source with an Audio_Occlusion
    // Of the OCCLUSION_SAMPLES points of its sphere: those the source reaches,
    // those the listener sees, and the next to test.
    rays_valid,rays_open:u16 `mirai:"transient,readonly,local,hidden"`,
    ray_next:u8 `mirai:"transient,readonly,local,hidden"`,
}

// The entity that hears: the first one found with a world transform. Without
// one, the View hears.
@(component,single)
Audio_Listener :: struct {}

// What surrounds the listener besides the air, as the water it is under:
// audio_buses filters the master bus by its lowpass too, the lower of both,
// and audio_reverb mixes its reverb by weight over that of the room. One
// plugin writes it (water), before audio_reverb and audio_buses; zero: the
// air.
@(storage)
Audio_Medium :: struct {
    lowpass:f32 `mirai:"min=0,unit=Hz"`, // cutoff of the low-pass filter of all the listener hears; 0: none
    reverb:Reverb,
    weight:f32 `mirai:"min=0,max=1"`,    // of its reverb over that of the room
}

// How a bus sounds. A bus without an entry plays as its voices come; an
// entry of zeros says nothing.
Audio_Bus_Setting :: struct {
    bus:Audio_Bus,
    gain:f32 `mirai:"min=-80,max=24,unit=dB"`, // 0: as it comes; AUDIO_SILENCE_DB or below: silent
    lowpass:f32 `mirai:"min=0,unit=Hz"`,       // cutoff of its low-pass filter; 0: none
    duck_by:Audio_Bus,                         // while it is louder than duck_threshold, this bus goes down by duck_amount
    duck_amount:f32 `mirai:"min=0,max=1"`,     // 0: not ducked
    duck_threshold:f32 `mirai:"min=0"`,        // linear peak
    duck_attack:f32 `mirai:"min=0,unit=s"`,
    duck_release:f32 `mirai:"min=0,unit=s"`,
    reverb:Reverb, // on all it plays, as a song made to sound in a hall; wet 0: none
}

// One entry per bus that does not play as it comes, the first one of a bus
// being the one that counts, and the bus the reverb returns in.
@(storage,setting)
Audio_Settings :: struct {
    buses:[AUDIO_BUS_CAPACITY]Audio_Bus_Setting `mirai:"trim"`,
    reverb_bus:Audio_Bus,
}

// The volume of each bus as the player chose it, 0 to 1, over the gain the
// game gives it in Audio_Settings: what a slider of the options menu binds
// (Audio_Volumes.music) and save keeps in the options of the player.
@(storage,setting="machine")
Audio_Volumes :: struct {
    master,music,effects,voice,ui:f32 `mirai:"min=0,max=1"`, // by the order of the BUS_ constants
    more:[AUDIO_BUS_CAPACITY-5]f32 `mirai:"min=0,max=1"`,    // the buses a game adds after BUS_UI
}
#assert(size_of(Audio_Volumes)==AUDIO_BUS_CAPACITY*size_of(f32))

AUDIO_VOLUMES_DEFAULT :: Audio_Volumes{1,1,1,1,1,{1,1,1}}

AUDIO_OUTPUT_NAME_BYTES :: 128

// Where the sound plays: an option of the player, which audio_output brings
// the output of the application to.
@(storage,setting="machine")
Audio_Output :: struct {
    device:[AUDIO_OUTPUT_NAME_BYTES]u8 `mirai:"text"`, // the name of the output as the system lists it (platform.audio_device_names); empty: the default of the system
    kind:Output_Kind, // headphones hear where each sound is, ahead, behind, above or below; speakers pan it
}

// The output the mixer was last brought to: one per application, as the mixer.
@(storage,host)
Mixer_Output :: struct {
    device:[AUDIO_OUTPUT_NAME_BYTES]u8,
    set:bool,
}

Audio_Stats :: struct {
    started,ended:u64,
}

Voice_Entry :: struct {
    voice:mixer.Voice,
    sound:base.Asset_Id,
    generation:u32,  // of what the content loaded for sound
    pick:[2]f32,     // volume and pitch its variation takes over those of the source
    volume,pitch,pan,reverb:f32, // as the voice was told
    bus:Audio_Bus,
    loop,spatial,moving:bool,
    attenuation:mixer.Attenuation,
    directivity:mixer.Directivity,
    doppler:f32,
    occlusion:f32,
    transmission:[mixer.BANDS]f32,
    position:[3]f32,
    rotation:quaternion128,
}

// The linear gain and the rate of playback the voice of an entry was given
// last: those of its source by the variation of its set, before buses,
// distance and what hides it.
voice_entry_given :: proc "contextless" (entry:Voice_Entry) -> (volume,pitch:f32) {
    return entry.volume,entry.pitch*entry.pick[1]
}

// The voices of the sources of a world, which the mixer of the application
// plays: each world keeps its own, never copied.
@(storage,host,by_world)
Voices :: struct {
    entries:core.Entity_Map(Voice_Entry),
    seen:core.Seen, // of the sources: the voices of those that went stop
    stats:Audio_Stats,
    paused:bool,    // the voices of the sources were paused with the clock of the world
}

// Where the mixer hears from, as it was told last: one per application, as
// the mixer. The world whose listener moved, or that runs after another,
// places it.
@(storage,host)
Mixer_Listener :: struct {
    position:[3]f32,
    rotation:quaternion128,
    velocity:[3]f32,
    set:bool,
}

// The reverb of the mixer as it was told last, on its way to that of the
// room the listener is in: one per application, as the mixer.
@(storage,host)
Mixer_Reverb :: struct {
    reverb:Reverb,
    bus:Audio_Bus,
    set:bool,
}

@(step="late",stage="end",after="transforms_propagate camera_view")
audio_sources :: proc(
    world:core.World_Ref,sources:core.Read(Audio_Source),states:^core.Table(Audio_Source_State),worlds:core.Read(core.World_Transform),
    occlusions:core.Read(Audio_Occlusion),materials:core.Read(Audio_Material),listeners:core.Read(Audio_Listener),view:core.Ref(core.View),queries:core.Ref(core.World_Queries),
    frame:core.Frame_Time,clock:core.Clock,voices:^Voices,listener:^Mixer_Listener,app:^host.App,problems:^core.Problems,
) {
    if voices!=nil && app.mixer!=nil && clock.paused!=voices.paused {
        voices.paused=clock.paused
        for entry in voices.entries.values {mixer.voice_set_paused(app.mixer,entry.voice,clock.paused)}
    }
    if voices!=nil && voices.paused {return}
    sources_update(sources,states,{worlds,occlusions,materials,listeners,view,core.world_query(world,queries)},frame.dt,voices,listener,app,problems)
}

// What the voices of a frame look at besides their sources.
@(private)
Hearing :: struct {
    worlds:core.Read(core.World_Transform),
    occlusions:core.Read(Audio_Occlusion),
    materials:core.Read(Audio_Material),
    listeners:core.Read(Audio_Listener),
    view:core.Ref(core.View),
    query:core.World_Query, // what hides a source
}

@(private)
sources_update :: proc(sources:core.Read(Audio_Source),states:^core.Table(Audio_Source_State),hearing:Hearing,dt:f32,voices:^Voices,listener:^Mixer_Listener,app:^host.App,problems:^core.Problems) {
    m:=app.mixer
    if m==nil || voices==nil {return}
    if cap(voices.entries.values)==0 {core.entity_map_reserve(&voices.entries,VOICE_RESERVE)}
    hearing:=hearing
    listener_update(listener,m,&hearing,dt)
    // The voices of the sources that went, or were turned off, stop.
    gone,at,left:=core.changes(sources,&voices.seen),0,Voice_Entry{}
    for _ in core.entity_map_left(&voices.entries,sources,gone,&at,&left) {mixer.voice_stop(m,left.voice)}
    for row in 0..<core.count(sources) {
        e:=core.entity_at(sources,row)
        source:=core.at(sources,row)
        local:Audio_Source_State
        state:=core.get(states,e)
        fresh:=state==nil
        if fresh {state=&local}
        voice_update(voices,m,app,&hearing,listener.position,source,e,dt,state,problems)
        if fresh {core.add(states,e,local)}
    }
}

// The reverb of the mixer goes to that of the volumes where the listener is
// over about REVERB_FADE.
@(step="late",stage="end",after="transforms_propagate camera_view")
audio_reverb :: proc(
    reverbs:core.Read(Audio_Reverb),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),listeners:core.Read(Audio_Listener),
    view:core.Ref(core.View),settings:core.Ref(Audio_Settings),medium:core.Ref(Audio_Medium),frame:core.Frame_Time,reverb:^Mixer_Reverb,m:^Mixer,
) {
    if m==nil || reverb==nil {return}
    bus:=BUS_MASTER
    if settings.ptr!=nil {bus=settings.reverb_bus}
    hearing:=Hearing{worlds=worlds,listeners=listeners,view=view}
    room:Audio_Reverb
    if position,_,_,found:=listener_pose(&hearing);found {room=volume.at(volumes,worlds,reverbs,position,Audio_Reverb{},reverb_mix)}
    target:=transmute(Reverb)room
    if medium.ptr!=nil {
        if weight:=clamp(medium.weight,0,1);weight>0 {
            target=transmute(Reverb)((transmute([4]f32)target)*(1-weight)+(transmute([4]f32)reverb_clamp(medium.reverb))*weight)
        }
    }
    if !bus_ready(m,bus) {bus=BUS_MASTER}
    now:=target
    if reverb.set && reverb.bus==bus && frame.dt>0 {
        from:=transmute([4]f32)reverb.reverb
        to:=transmute([4]f32)target
        next:=from+(to-from)*(1-math.exp(-3*frame.dt/REVERB_FADE))
        for value,i in next {
            if abs(to[i]-value)<1e-3 {next[i]=to[i]}
        }
        now=transmute(Reverb)next
    }
    if reverb.set && reverb.reverb==now && reverb.bus==bus {return}
    if mixer.reverb_set(m,now,mixer.Bus(bus)) {reverb^={now,bus,true}}
}

reverb_mix :: proc(value:^Audio_Reverb,by:Audio_Reverb,weight:f32,add:bool) {
    v:=transmute([4]f32)value^
    volume.mix_linear(&v,transmute([4]f32)by,weight,add)
    value^=transmute(Audio_Reverb)v
}

// The buses of the mixer as the settings and the medium of the listener say;
// only what differs is sent.
@(step="late",stage="end")
audio_buses :: proc(settings:core.Ref(Audio_Settings),volumes:core.Ref(Audio_Volumes),medium:core.Ref(Audio_Medium),m:^Mixer) {
    buses_apply(m,settings.ptr,volumes.ptr,medium.ptr)
}

// Gives the buses of the mixer what the settings say, and the master the
// lowpass of the medium: what audio_buses does each frame of a game, and the
// editor before it plays a sound to be heard.
buses_apply :: proc(m:^Mixer,settings:^Audio_Settings,volumes:^Audio_Volumes=nil,medium:^Audio_Medium=nil) {
    if m==nil || settings==nil && medium==nil {return}
    if settings!=nil {
        for setting in settings.buses {
            if setting=={} {continue}
            _=bus_ready(m,setting.bus)
            if setting.duck_amount>0 {_=bus_ready(m,setting.duck_by)}
        }
    }
    for index in 0..<min(mixer.bus_count(m),AUDIO_BUS_CAPACITY) {
        bus:=Audio_Bus(index)
        setting:=audio_bus_setting(settings,bus)
        if volume:=db_volume(setting.gain)*audio_volume(volumes,bus);mixer.bus_volume(m,mixer.Bus(bus))!=volume {mixer.bus_set_volume(m,mixer.Bus(bus),volume)}
        lowpass:=max(setting.lowpass,0)
        if bus==BUS_MASTER && medium!=nil {lowpass=lowpass_lower(lowpass,medium.lowpass)}
        if mixer.bus_lowpass(m,mixer.Bus(bus))!=lowpass {mixer.bus_set_lowpass(m,mixer.Bus(bus),lowpass)}
        if reverb:=reverb_clamp(setting.reverb);mixer.bus_reverb(m,mixer.Bus(bus))!=reverb {mixer.bus_set_reverb(m,mixer.Bus(bus),reverb)}
        if bus==BUS_MASTER {continue}
        duck:mixer.Duck
        if amount:=clamp(setting.duck_amount,0,1);amount>0 && setting.duck_by!=bus && int(setting.duck_by)<mixer.bus_count(m) {
            duck={mixer.Bus(setting.duck_by),max(setting.duck_threshold,0),amount,max(setting.duck_attack,0),max(setting.duck_release,0)}
        }
        if mixer.bus_duck(m,mixer.Bus(bus))!=duck {mixer.bus_set_duck(m,mixer.Bus(bus),duck)}
    }
}

// Plays the mixer on the output of the settings when they change. The mixer
// keeps its voices and its clock. An application whose mixer the system does
// not play (headless, or one nobody plays) has no output to change.
@(step="late",stage="end",loops="game editor")
audio_output :: proc(output:Audio_Output,applied:^Mixer_Output,app:^host.App,problems:^core.Problems) {
    if app.mixer==nil {return}
    kind:=output.kind if output.kind<=max(Output_Kind) else .Headphones
    if mixer.mixer_output(app.mixer)!=kind {mixer.mixer_set_output(app.mixer,kind)}
    if !platform.audio_device_is_open(app.platform) || applied.set && applied.device==output.device {return}
    first:=!applied.set
    applied.device,applied.set=output.device,true
    device:=output.device
    name:=base.text_get(device[:])
    // The application opened the default.
    if first && name=="" {return}
    p:=app.platform
    if error,found:=platform.audio_device_switch(p,name);error!=.None {
        // The default, which the application opened, opens again.
        reopened:=platform.audio_device_open(p,app.mixer)==.None
        core.report(problems,core.NONE,"audio.output","the output \"%s\" did not open (%v): %s; choose another in Audio_Output.device, or leave it empty for the default",name,error,reopened?"the sound plays on the default one":"the game plays no sound")
    } else if !found {
        core.report(problems,core.NONE,"audio.output","Audio_Output.device \"%s\" is not an output of this machine, so the sound plays on the default one; give it one of %v, or leave it empty",name,platform.audio_device_names(p,context.temp_allocator))
    }
}

// The voices of a World that is freed stop with it.
@(step="release")
audio_release :: proc(voices:^Voices,m:^Mixer) {
    if voices==nil {return}
    if m!=nil {for entry in voices.entries.values {mixer.voice_stop(m,entry.voice)}}
    core.entity_map_clear(&voices.entries)
}

// The setting of a bus: its entry, or one that plays it as it comes.
audio_bus_setting :: proc "contextless" (settings:^Audio_Settings,bus:Audio_Bus) -> Audio_Bus_Setting {
    if settings!=nil {
        for entry in settings.buses {
            if entry!={} && entry.bus==bus {return entry}
        }
    }
    return {bus=bus}
}

// Writes the setting of a bus in its entry or in a free one, or takes its
// entry out when it plays the bus as it comes. False when no entry is free.
audio_bus_setting_set :: proc "contextless" (settings:^Audio_Settings,setting:Audio_Bus_Setting) -> bool {
    if settings==nil {return false}
    next:=setting
    if next==(Audio_Bus_Setting{bus=setting.bus}) {next={}}
    free:=-1
    for &entry,i in settings.buses {
        if entry!={} && entry.bus==setting.bus {entry=next;return true}
        if entry=={} && free<0 {free=i}
    }
    if next=={} {return true}
    if free<0 {return false}
    settings.buses[free]=next
    return true
}

// The volume the player chose for a bus, 0 to 1; 1 without a choice.
audio_volume :: proc "contextless" (volumes:^Audio_Volumes,bus:Audio_Bus) -> f32 {
    if volumes==nil || int(bus)>=AUDIO_BUS_CAPACITY {return 1}
    volume:=(^[AUDIO_BUS_CAPACITY]f32)(volumes)[int(bus)]
    return volume>=0?min(volume,1):0
}

// The gain of a level in dB, as the mixer takes it.
@(private)
db_volume :: proc "contextless" (gain:f32) -> f32 {
    if gain<=AUDIO_SILENCE_DB {return 0}
    return math.pow(10,gain/20)
}

// The lower of two cutoffs, where 0 is none.
@(private)
lowpass_lower :: proc "contextless" (a,b:f32) -> f32 {
    if !(b>0) {return a}
    if !(a>0) {return b}
    return min(a,b)
}

// A reverb as the mixer keeps it.
@(private)
reverb_clamp :: proc "contextless" (r:Reverb) -> Reverb {
    return {clamp(r.room_size,0,1),clamp(r.damping,0,1),max(r.wet,0),clamp(r.width,0,1)}
}

// The bus of the mixer for a bus, reserved the first time one is named.
@(private)
bus_ready :: proc(m:^Mixer,bus:Audio_Bus) -> bool {
    if int(bus)>=AUDIO_BUS_CAPACITY {return false}
    for mixer.bus_count(m)<=int(bus) {
        if _,ok:=mixer.bus_create(m);!ok {return false}
    }
    return true
}

// Where the listener hears from: the first Audio_Listener with a world
// transform, or the View; false without either.
listener_position :: proc(worlds:core.Read(core.World_Transform),listeners:core.Read(Audio_Listener),view:core.Ref(core.View)) -> (position:[3]f32,found:bool) {
    hearing:=Hearing{worlds=worlds,listeners=listeners,view=view}
    position,_,_,found=listener_pose(&hearing)
    return
}

// Where the listener is: the first Audio_Listener with a world transform, or
// the View. cut: the View jumped.
@(private)
listener_pose :: proc(h:^Hearing) -> (position:[3]f32,rotation:quaternion128,cut,found:bool) {
    for row in 0..<core.count(h.listeners) {
        world,placed:=core.get(h.worlds,core.entity_at(h.listeners,row))
        if !placed {continue}
        return world.position,world.rotation,false,true
    }
    if h.view.ptr==nil {return {},1,false,false}
    return h.view.position,h.view.rotation,h.view.cut,true
}

@(private)
listener_update :: proc(listener:^Mixer_Listener,m:^Mixer,h:^Hearing,dt:f32) {
    position,rotation,cut,found:=listener_pose(h)
    if !found {return}
    velocity:[3]f32
    if listener.set && dt>0 && !cut {velocity=(position-listener.position)/dt}
    if listener.set && listener.position==position && listener.rotation==rotation && listener.velocity==velocity {return}
    if mixer.listener_set(m,position,rotation,velocity) {listener^={position,rotation,velocity,true}}
}

// Whether what collides stands between two points, short of clearance before
// the second.
@(private)
blocked :: proc(query:core.World_Query,source:core.Entity,from,to:[3]f32,clearance:f32) -> bool {
    offset:=to-from
    distance:=linalg.length(offset)
    if query.probe==nil || !(distance>clearance) {return false}
    _,hit:=query.probe(query.user,from,offset/distance,distance-clearance,0,source,~u32(0))
    return hit
}

// The part of a source out of the listener's sight, 0 to 1. A point source
// is in sight or not; one with a radius is as hidden as the points of its
// sphere the source reaches and the listener does not see (Steam Audio's
// volumetric occlusion), OCCLUSION_SAMPLES_PER_FRAME of them tested again each
// frame, or all of them when every is true.
@(private)
occlusion_amount :: proc(query:core.World_Query,source:core.Entity,from,listener:[3]f32,radius:f32,state:^Audio_Source_State,every:bool) -> f32 {
    if !(radius>0) {
        state.rays_valid,state.rays_open,state.ray_next=0,0,0
        return 1 if blocked(query,source,from,listener,OCCLUSION_CLEARANCE) else 0
    }
    for _ in 0..<(OCCLUSION_SAMPLES if every else OCCLUSION_SAMPLES_PER_FRAME) {
        i:=int(state.ray_next)%OCCLUSION_SAMPLES
        state.ray_next=u8((i+1)%OCCLUSION_SAMPLES)
        bit:=u16(1)<<uint(i)
        state.rays_valid&~=bit
        state.rays_open&~=bit
        // Point i spread through the sphere by Halton sequences (Steam Audio's
        // Sampling::generateSphereVolumeSamples).
        radical_inverse :: proc "contextless" (base,i:int) -> f32 {
            inverse,reversed,scale,n:=1/f32(base),0,f32(1),i
            for n>0 {
                next:=n/base
                reversed=reversed*base+(n-next*base)
                scale*=inverse
                n=next
            }
            return min(f32(reversed)*scale,1)
        }
        phi,theta,r:=2*math.PI*radical_inverse(2,i),math.acos(2*radical_inverse(3,i)-1),math.cbrt(radical_inverse(5,i))
        point:=from+[3]f32{r*math.sin(theta)*math.cos(phi),r*math.sin(theta)*math.sin(phi),r*math.cos(theta)}*radius
        if blocked(query,source,from,point,0) {continue}
        state.rays_valid|=bit
        if !blocked(query,source,point,listener,OCCLUSION_CLEARANCE) {state.rays_open|=bit}
    }
    valid:=intrinsics.count_ones(state.rays_valid)
    if valid==0 {return 1}
    return 1-f32(intrinsics.count_ones(state.rays_open))/f32(valid)
}

// What the bodies between a source and the listener let through, per band
// (Steam Audio's DirectSimulator::transmission): rays from the listener and
// from the source take turns, each from past the last body it crossed, until
// they meet or TRANSMISSION_SURFACES bodies were crossed. Past one body, two
// surfaces are taken as the two sides of one: the root of the product.
@(private)
transmission_through :: proc(h:^Hearing,source:core.Entity,from,listener:[3]f32) -> (through:[mixer.BANDS]f32) {
    through={1,1,1}
    offset:=from-listener
    total:=linalg.length(offset)
    if h.query.probe==nil || !(total>OCCLUSION_CLEARANCE) {return}
    origins:=[2][3]f32{listener,from}
    directions:=[2][3]f32{offset/total,-offset/total}
    reached:=[2]f32{OCCLUSION_CLEARANCE,0}
    limits:=[2]f32{total,total-OCCLUSION_CLEARANCE}
    hits,ray:=0,0
    for _ in 0..<TRANSMISSION_SURFACES {
        length:=limits[ray]-reached[ray]
        if !(length>0) {break}
        hit,found:=h.query.probe(h.query.user,origins[ray]+directions[ray]*reached[ray],directions[ray],length,0,source,~u32(0))
        if !found {break}
        hits+=1
        material:=AUDIO_MATERIAL_DEFAULT
        if m,has:=core.get(h.materials,hit.entity);has {material=m}
        for band in 0..<mixer.BANDS {
            t:=material.transmission[band]
            through[band]*=clamp(t,0,1) if t==t else 0
        }
        reached[ray]+=max(hit.distance,0)+TRANSMISSION_RAY_OFFSET
        if reached[ray]>=limits[ray] || reached[0]+reached[1]>=total {break}
        ray=1-ray
    }
    if hits>1 {
        for &t in through {t=math.sqrt(t)}
    }
    return
}

@(private)
attenuation_of :: proc "contextless" (source:Audio_Source) -> mixer.Attenuation {
    a:=mixer.ATTENUATION_DEFAULT
    a.model,a.rolloff=source.attenuation,source.rolloff
    if source.min_distance>0 {a.min_distance=source.min_distance}
    if source.max_distance>0 {a.max_distance=source.max_distance}
    return a
}

@(private)
voice_update :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,listener:[3]f32,source:Audio_Source,e:core.Entity,dt:f32,state:^Audio_Source_State,problems:^core.Problems) {
    entry:=core.entity_map_get(&voices.entries,e)
    if !source.playing {
        if entry!=nil {
            mixer.voice_stop(m,entry.voice)
            core.entity_map_remove(&voices.entries,e)
        }
        state.voice,state.ended,state.occlusion={},false,0
        return
    }
    if state.ended {return}
    generation:=host.content_sound_generation(app,source.sound)
    pitch:=source.pitch>0?source.pitch:1
    world,placed:=core.get(h.worlds,e)
    spatial:=source.spatial && placed
    attenuation:=attenuation_of(source)
    directivity:=mixer.Directivity{clamp(source.directivity,0,1),max(source.directivity_power,0)}
    rotation:=world.rotation if spatial && directivity.weight>0 else 1
    occlusion,hides:=core.get(h.occlusions,e)
    transmission:=mixer.TRANSMISSION_DEFAULT
    if hides && spatial {
        // A voice that starts takes how hidden it is at once.
        target:=occlusion_amount(h.query,e,world.position,listener,occlusion.radius,state,entry==nil)
        if entry==nil || !(occlusion.fade>0) || dt<=0 {
            state.occlusion=target
        } else {
            step:=dt/occlusion.fade
            state.occlusion+=clamp(target-state.occlusion,-step,step)
        }
        if state.occlusion>0 {transmission=transmission_through(h,e,world.position,listener)}
    } else {
        state.occlusion=0
        state.rays_valid,state.rays_open,state.ray_next=0,0,0
    }
    if entry!=nil {
        if entry.sound!=source.sound || entry.generation!=generation || entry.bus!=source.bus || entry.spatial!=spatial || entry.attenuation!=attenuation || entry.doppler!=source.doppler || entry.directivity!=directivity {
            mixer.voice_stop(m,entry.voice)
            core.entity_map_remove(&voices.entries,e)
        } else if mixer.voice_valid(m,entry.voice) {
            if volume:=source.volume*entry.pick[0];entry.volume!=volume {mixer.voice_set_volume(m,entry.voice,volume);entry.volume=volume}
            if entry.pitch!=pitch {mixer.voice_set_pitch(m,entry.voice,pitch*entry.pick[1]);entry.pitch=pitch}
            if entry.loop!=source.loop {mixer.voice_set_loop(m,entry.voice,source.loop);entry.loop=source.loop}
            if !spatial && entry.pan!=source.pan {mixer.voice_set_pan(m,entry.voice,source.pan);entry.pan=source.pan}
            if entry.reverb!=source.reverb {mixer.voice_set_reverb(m,entry.voice,source.reverb);entry.reverb=source.reverb}
            if spatial && (entry.occlusion!=state.occlusion || entry.transmission!=transmission) {
                mixer.voice_set_occlusion(m,entry.voice,state.occlusion,transmission)
                entry.occlusion,entry.transmission=state.occlusion,transmission
            }
            if spatial && (entry.position!=world.position || entry.moving || entry.rotation!=rotation) {
                velocity:[3]f32
                if source.doppler>0 && dt>0 {velocity=(world.position-entry.position)/dt}
                mixer.voice_set_position(m,entry.voice,world.position,velocity,rotation)
                entry.position,entry.moving,entry.rotation=world.position,velocity!={},rotation
            }
            state.voice=entry.voice
            return
        } else {
            core.entity_map_remove(&voices.entries,e)
            state.voice={}
            if !source.loop {
                state.ended=true
                voices.stats.ended+=1
                return
            }
        }
    }
    if !bus_ready(m,source.bus) {
        core.report(problems,e,"audio.bus","its Audio_Source plays nothing: Audio_Source.bus %d is not a bus of the mixer, which has %d; give it a bus below that",int(source.bus),AUDIO_BUS_CAPACITY)
        return
    }
    pick:=host.content_sound_pick(app,source.sound)
    if !mixer.sound_valid(m,pick.sound) {
        if source.sound!={} {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,e,"audio.sound","its Audio_Source plays nothing: Audio_Source.sound %s does not load as a sound (it is missing, damaged, not a .sound or a .sound_set, or a set none of whose sounds load); give it a .sound or a .sound_set of the assets",host.assets_name(app.assets,source.sound,&name))
        } else {
            core.report(problems,e,"audio.sound","its Audio_Source plays nothing: it has no sound; give Audio_Source.sound a .sound or a .sound_set of the assets")
        }
        return
    }
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.loop=mixer.Bus(source.bus),source.volume*pick.volume,pitch*pick.pitch,source.loop
    desc.reverb=source.reverb
    position:[3]f32
    if spatial {
        position=world.position
        desc.spatial,desc.position,desc.rotation,desc.attenuation,desc.directivity,desc.doppler=true,position,rotation,attenuation,directivity,source.doppler
        desc.occlusion,desc.transmission=state.occlusion,transmission
    } else {
        desc.pan=source.pan
    }
    voice:=mixer.voice_play(m,pick.sound,desc)
    if voice=={} {
        core.report(problems,e,"audio.voices","its Audio_Source did not start: every voice of the mixer plays a sound of the same or a higher priority; play fewer sounds at once, or raise the voices of the mixer")
        return
    }
    // Without memory to keep it the voice cannot be followed: it does not play.
    kept_entry:=Voice_Entry{voice=voice,sound=source.sound,generation=generation,pick={pick.volume,pick.pitch},volume=desc.volume,pitch=pitch,pan=source.pan,reverb=source.reverb,bus=source.bus,loop=source.loop,spatial=spatial,attenuation=attenuation,directivity=directivity,doppler=source.doppler,occlusion=desc.occlusion,transmission=transmission,position=position,rotation=rotation}
    if _,kept:=core.entity_map_put(&voices.entries,e,kept_entry);!kept {
        mixer.voice_stop(m,voice)
        core.report(problems,e,"audio.memory","its Audio_Source did not start: out of memory to follow its voice; free memory")
        return
    }
    state.voice=voice
    voices.stats.started+=1
}

@(private)
voice_start :: proc(app:^host.App,time:core.Time,asset:base.Asset_Id,desc:mixer.Voice_Desc) -> Voice {
    if app.mixer==nil || time.resimulating || !bus_ready(app.mixer,Audio_Bus(desc.bus)) {return {}}
    pick:=host.content_sound_pick(app,asset)
    if pick.sound=={} {return {}}
    desc:=desc
    desc.volume*=pick.volume
    desc.pitch=(desc.pitch>0?desc.pitch:1)*pick.pitch
    return mixer.voice_play(app.mixer,pick.sound,desc)
}

// Plays a .sound, or one of a .sound_set, once, not placed in the world.
// Zero when the application has no mixer, the asset does not load as a
// sound, no voice is free or the tick runs again (time.resimulating): it
// played the first time.
play_asset :: proc(app:^host.App,time:core.Time,asset:base.Asset_Id,volume:f32=1,pitch:f32=1,pan:f32=0,bus:=BUS_EFFECTS) -> Voice {
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.pan=mixer.Bus(bus),volume,pitch,pan
    return voice_start(app,time,asset,desc)
}

// Plays a .sound, or one of a .sound_set, once at a point of the world,
// sending reverb of it to the room of the listener.
play_asset_at :: proc(app:^host.App,time:core.Time,asset:base.Asset_Id,position:[3]f32,volume:f32=1,pitch:f32=1,bus:=BUS_EFFECTS,reverb:f32=1) -> Voice {
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.spatial,desc.position,desc.reverb=mixer.Bus(bus),volume,pitch,true,position,reverb
    return voice_start(app,time,asset,desc)
}

// Plays a source once as it is set, in no place: its sound, bus, volume,
// pitch, pan, loop and what it sends to the room; spatial or not, as a
// sound that is not spatial.
play_source :: proc(app:^host.App,time:core.Time,source:Audio_Source) -> Voice {
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.pan,desc.loop,desc.reverb=mixer.Bus(source.bus),source.volume,source.pitch,source.pan,source.loop,source.reverb
    return voice_start(app,time,source.sound,desc)
}

// Plays a source once at a point of the world as it is set: its sound, bus,
// volume, pitch, loop, send and the curve it falls by (attenuation,
// min_distance, max_distance, rolloff), heard from the listener whatever its
// spatial says. source_place moves it, as a loop that follows something.
play_source_at :: proc(app:^host.App,time:core.Time,source:Audio_Source,position:[3]f32) -> Voice {
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.loop,desc.reverb=mixer.Bus(source.bus),source.volume,source.pitch,source.loop,source.reverb
    desc.spatial,desc.position,desc.attenuation=true,position,attenuation_of(source)
    desc.directivity={clamp(source.directivity,0,1),max(source.directivity_power,0)}
    return voice_start(app,time,source.sound,desc)
}

// Moves a voice that play_source_at or play_asset_at started to another point
// of the world.
source_place :: proc(m:^Mixer,voice:Voice,position:[3]f32) {
    if m==nil || !mixer.voice_valid(m,voice) {return}
    mixer.voice_set_position(m,voice,position)
}

// Gives a voice play_source started the volume, pitch, pan, loop and send of
// a source that changed while it plays; a set keeps the sound it chose.
source_tune :: proc(m:^Mixer,voice:Voice,source:Audio_Source) {
    if m==nil || !mixer.voice_valid(m,voice) {return}
    mixer.voice_set_volume(m,voice,source.volume)
    mixer.voice_set_pitch(m,voice,source.pitch>0?source.pitch:1)
    mixer.voice_set_pan(m,voice,source.pan)
    mixer.voice_set_loop(m,voice,source.loop)
    mixer.voice_set_reverb(m,voice,source.reverb)
}

// Ends a voice play_asset started, after fading out for fade seconds.
stop :: proc(m:^Mixer,voice:Voice,fade:f32=0) -> bool {
    return m!=nil && mixer.voice_stop(m,voice,fade)
}

// Whether a voice still plays, as of the last frame.
playing :: proc(m:^Mixer,voice:Voice) -> bool {
    return m!=nil && mixer.voice_valid(m,voice)
}
