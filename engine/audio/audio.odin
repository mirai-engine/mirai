package audio

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
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
// it crosses lets through. A step plays a sound once by pushing it to
// Sound_Requests (play), which this library starts as it starts a source.

VOICE_RESERVE :: 256
AUDIO_BUS_CAPACITY :: 8  // the buses of the mixer, the master included
AUDIO_SILENCE_DB :: -80  // a gain at or below it silences
REVERB_FADE :: f32(0.5)  // s: the reverb goes from a room to the next in about this long
OCCLUSION_CLEARANCE :: f32(0.5) // m around the listener that does not hide: its own body
OCCLUSION_SAMPLES :: 16           // points of the sphere of a source with a radius whose sight is tested
OCCLUSION_SAMPLES_PER_FRAME :: 4  // of them tested again each frame
TRANSMISSION_SURFACES :: 4        // bodies crossed whose materials are added up between a source and the listener
VOICE_KEEP :: f32(1.25) // a source that holds a voice ranks as this much louder, so two about as loud do not trade it each frame
@(private) TRANSMISSION_RAY_OFFSET :: f32(1e-2) // m past a surface where the next ray starts

Mixer :: mixer.Mixer
Voice :: mixer.Voice
Attenuation_Model :: mixer.Attenuation_Model
Output_Kind :: mixer.Output_Kind
Reverb :: mixer.Reverb

#assert(len(asset.Attenuation_Model)==len(Attenuation_Model))

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
// playing is cleared or the component goes away; a change of sound, bus, how
// it is heard or plays starts it again. A .sound_set chooses one of its sounds
// each time the voice starts, and a loop repeats the one it chose. A sound
// that ends without loop sets Audio_Source_State.ended; one more in plays
// plays it again from its start. When more sources play than the mixer has
// voices, those of higher priority and then the loudest at the listener are
// mixed; the others, and those not heard at all, keep their time without a
// voice and come back where they would be.
@(component,description="Plays a .sound or a .sound_set: placed at the entity when spatial, or as it is.")
Audio_Source :: struct {
    sound:base.Asset_Id, // a .sound or a .sound_set
    bus:Audio_Bus,
    volume:f32 `mirai:"min=0"`,
    pitch:f32 `mirai:"min=0"`, // speed it plays at, which moves its pitch with it, as a slowed song; 0 is taken as 1
    pan:f32 `mirai:"min=-1,max=1"`, // -1 left to 1 right, when not spatial
    loop:bool,
    playing:bool,
    plays:u32, // a change starts the sound again from its start, also one that ended
    spatial:bool, // placed at the entity and heard from the listener: from its direction, attenuated and dulled by the air
    attenuation:Attenuation_Model, // how it falls between min_distance and max_distance
    min_distance:f32 `mirai:"min=0,unit=m"`,
    max_distance:f32 `mirai:"min=0,unit=m"`,
    rolloff:f32 `mirai:"min=0"`, // how fast it falls: 1 is the curve as its model says it
    near_radius:f32 `mirai:"min=0,unit=m"`, // nearer, it is heard less from its direction, so passing through the listener does not jump between ears
    delay:bool, // starts later by its distance over the speed of sound, as thunder after its flash
    doppler:f32 `mirai:"min=0"`, // 0: none; 1: the physical shift of pitch as it and the listener move
    reverb:f32 `mirai:"min=0,max=1"`, // share of it the room of the listener reverberates
    directivity:f32 `mirai:"min=0,max=1"`, // 0: the same all around; 0.5: loudest toward -Z of the entity and silent behind; 1: silent at its sides
    directivity_power:f32 `mirai:"min=0"`,  // how narrow the directivity is: 1 as it is, higher narrower
    priority:u8, // when more sources play than the mixer has voices, the higher keep theirs before the louder
}

AUDIO_SOURCE_DEFAULT :: Audio_Source{bus=BUS_EFFECTS,volume=1,pitch=1,playing=true,attenuation=.Inverse,min_distance=1,max_distance=20,rolloff=1,near_radius=1,directivity_power=1}

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
    plays:u32 `mirai:"transient,readonly,local,hidden"`, // Audio_Source.plays its last voice started at
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

// How a bus sounds. A bus without an entry plays as its voices come into the
// master; an entry of zeros says nothing.
Audio_Bus_Setting :: struct {
    bus:Audio_Bus,
    send:Audio_Bus, // the bus it plays into, with its gain, filter and ducking: the master, or one of a lower number (ambience into effects)
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
    missing:bool, // device is not connected: the default plays until it is
}

Audio_Stats :: struct {
    started,ended:u64,
}

// A source that plays: mixed by its voice, or virtual (voice 0) while it is
// not heard or louder ones hold the voices of the mixer.
Voice_Entry :: struct {
    voice:mixer.Voice,
    fading:mixer.Voice, // the voice it held last, while it goes quiet
    kind:Voice_Kind,
    generation:u32, // of what the content loaded for sound
    sound:mixer.Sound, // what its set drew; 0: nothing of it loads yet
    pick:[2]f32,    // volume and pitch its variation takes over those of the source
    length:f32,     // s of sound
    // Its time: cursor seconds into sound at mixer clock `clock`, going on at speed, its pitch.
    cursor:f64,
    clock:u64,
    speed:f32,
    // Of a spatial voice: where it was placed last, how it faces and what hides it.
    moving:bool,
    position:[3]f32,
    rotation:quaternion128,
    transmission:[mixer.BANDS]f32,
}

// What a voice starts with and cannot change while it sounds: another starts it again.
Voice_Kind :: struct {
    sound:base.Asset_Id,
    bus:Audio_Bus,
    spatial:bool,
    attenuation:mixer.Attenuation,
    directivity:mixer.Directivity,
    doppler:f32,
    plays:u32,
}

// The voices of the sources of a world, which the mixer of the application
// plays: each world keeps its own, never copied.
@(storage,host,by_world)
Voices :: struct {
    entries:core.Entity_Map(Voice_Entry),
    seen:core.Seen, // of the sources: the voices of those that went stop
    stats:Audio_Stats,
    paused:bool,    // the voices of the sources were paused with the clock of the world
    ranks:[dynamic]Voice_Rank, // of a frame: the entries that are heard, which voices_assign orders
}

// An entry that is heard, by what keeps a voice first.
Voice_Rank :: struct {
    at:u32, // in entries
    priority:u8,
    gain:f32, // at the listener
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

@(step="late",stage="end",after="camera_view")
audio_sources :: proc(
    world:core.World_Ref,sources:^core.Table(Audio_Source,.Read),states:^core.Table(Audio_Source_State),worlds:^core.Table(core.World_Transform,.Read),
    occlusions:^core.Table(Audio_Occlusion,.Read),materials:^core.Table(Audio_Material,.Read),listeners:^core.Table(Audio_Listener,.Read),view:core.Ref(core.View),queries:core.Ref(core.World_Queries),
    frame:core.Frame_Time,clock:core.Clock,voices:^Voices,listener:^Mixer_Listener,app:^host.App,problems:^core.Problems,
) {
    if voices!=nil && app.mixer!=nil && clock.paused!=voices.paused {
        voices.paused=clock.paused
        now:=mixer.mixer_clock(app.mixer)
        for &entry in voices.entries.values {
            mixer.voice_set_paused(app.mixer,entry.voice,clock.paused)
            if clock.paused {entry.cursor=entry_time(&entry,now)}
            entry.clock=now
        }
    }
    if voices!=nil && voices.paused {return}
    sources_update(sources,states,{worlds,occlusions,materials,listeners,view,core.world_query(world,queries)},frame.dt,voices,listener,app,problems)
}

// What the voices of a frame look at besides their sources.
@(private)
Hearing :: struct {
    worlds:^core.Table(core.World_Transform,.Read),
    occlusions:^core.Table(Audio_Occlusion,.Read),
    materials:^core.Table(Audio_Material,.Read),
    listeners:^core.Table(Audio_Listener,.Read),
    view:core.Ref(core.View),
    query:core.World_Query, // what hides a source
}

@(private)
sources_update :: proc(sources:^core.Table(Audio_Source,$A),states:^core.Table(Audio_Source_State),hearing:Hearing,dt:f32,voices:^Voices,listener:^Mixer_Listener,app:^host.App,problems:^core.Problems) {
    m:=app.mixer
    if m==nil || voices==nil {return}
    if cap(voices.ranks)==0 && (!core.entity_map_reserve(&voices.entries,VOICE_RESERVE) || reserve(&voices.ranks,VOICE_RESERVE)!=nil) {
        core.report(problems,core.NONE,"audio.memory","the Audio_Sources play nothing: out of memory to follow their voices; free memory")
        return
    }
    hearing:=hearing
    listener_update(listener,m,&hearing,dt)
    // The voices of the sources that went stop.
    changes,at,left:=core.changes(sources,&voices.seen),0,Voice_Entry{}
    for _ in core.entity_map_left(&voices.entries,sources,changes,&at,&left) {mixer.voice_stop(m,left.voice)}
    // A source written starts, stops or tunes its own; then each follows its entity.
    for row in core.each_changed(sources,&changes) {
        e:=core.entity_at(sources,row)
        state,_:=core.get(states,e)
        source_set(voices,m,app,&hearing,core.at(sources,row),e,&state,problems)
        state_put(states,e,state)
    }
    for i:=len(voices.entries.entities)-1;i>=0;i-=1 {
        e:=voices.entries.entities[i]
        source,_:=core.get(sources,e)
        state,_:=core.get(states,e)
        voice_follow(voices,m,app,&hearing,listener.position,source,e,dt,&state,problems)
        state_put(states,e,state)
    }
    voices_assign(voices,m,&hearing,listener.position,sources,states)
}

// The voices of the mixer go to the entries heard most, by priority first: as
// many as the mixer has free and the entries hold. One that falls out goes
// virtual, and one that comes in plays where its time is, on a voice that is
// free: none is stolen, so a steady scene starts and stops nothing.
@(private)
voices_assign :: proc(voices:^Voices,m:^Mixer,h:^Hearing,listener:[3]f32,sources:^core.Table(Audio_Source,.Read),states:^core.Table(Audio_Source_State)) {
    free:=mixer.voices_free(m)
    budget:=free
    clear(&voices.ranks)
    for &entry,at in voices.entries.values {
        if entry.fading!={} && !mixer.voice_valid(m,entry.fading) {entry.fading={}}
        source,_:=core.get(sources,voices.entries.entities[at])
        gain:=source.volume*entry.pick[0]*mixer.bus_volume(m,mixer.Bus(entry.kind.bus))
        if entry.kind.spatial {gain*=mixer.attenuation_gain(entry.kind.attenuation,linalg.distance(entry.position,listener))}
        if entry.voice!={} {gain*=VOICE_KEEP}
        if gain>0 && mixer.sound_valid(m,entry.sound) {
            if _,failed:=append(&voices.ranks,Voice_Rank{u32(at),source.priority,gain});failed!=nil {gain=0}
        } else {
            gain=0
        }
        if entry.voice!={} && gain==0 {voice_virtual(voices,m,at,states)}
        budget+=int(entry.voice!={})+int(entry.fading!={})
    }
    slice.sort_by(voices.ranks[:],proc(a,b:Voice_Rank) -> bool {return a.priority>b.priority || a.priority==b.priority && a.gain>b.gain})
    for rank,i in voices.ranks {
        entry:=&voices.entries.values[rank.at]
        if i>=budget {
            if entry.voice!={} {voice_virtual(voices,m,int(rank.at),states)}
        } else if entry.voice=={} && free>0 {
            if voice_real(voices,m,h,listener,sources,states,int(rank.at)) {free-=1}
        }
    }
}

// The entry at goes on without its voice, which fades out.
@(private)
voice_virtual :: proc(voices:^Voices,m:^Mixer,at:int,states:^core.Table(Audio_Source_State)) {
    entry:=&voices.entries.values[at]
    mixer.voice_stop(m,entry.voice)
    entry.fading,entry.voice=entry.voice,{}
    e:=voices.entries.entities[at]
    if state,has:=core.get(states,e);has {
        state.voice={}
        state_put(states,e,state)
    }
}

// The entry at plays again where its time is; false when the mixer refused it.
@(private)
voice_real :: proc(voices:^Voices,m:^Mixer,h:^Hearing,listener:[3]f32,sources:^core.Table(Audio_Source,.Read),states:^core.Table(Audio_Source_State),at:int) -> bool {
    entry:=&voices.entries.values[at]
    e:=voices.entries.entities[at]
    source,_:=core.get(sources,e)
    state,_:=core.get(states,e)
    offset:=entry_time(entry,mixer.mixer_clock(m))
    if source.loop && entry.length>0 {offset=math.mod(offset,f64(entry.length))}
    heard:=source
    heard.spatial=entry.kind.spatial
    if heard.spatial {
        world,_:=core.get(h.worlds,e)
        entry.transmission=hidden(h,listener,e,world,0,&state,true)
    }
    desc:=voice_desc(heard,entry.pick,entry.position,entry.rotation,state.occlusion,entry.transmission)
    desc.offset=f32(offset)
    if entry.voice=mixer.voice_play(m,entry.sound,desc);entry.voice=={} {return false}
    state.voice=entry.voice
    state_put(states,e,state)
    return true
}

// Seconds into its sound the voice of an entry is, or would be, at mixer clock now.
@(private)
entry_time :: proc "contextless" (entry:^Voice_Entry,now:u64) -> f64 {
    return entry.cursor+f64(now-min(now,entry.clock))/mixer.MIXER_RATE*f64(entry.speed)
}

// The state of a source, written only when it is another.
@(private)
state_put :: proc(states:^core.Table(Audio_Source_State),e:core.Entity,state:Audio_Source_State) {
    if held,has:=core.get(states,e);!has {core.add(states,e,state)} else if held!=state {core.edit(states,e)^=state}
}

// The reverb of the mixer goes to that of the volumes where the listener is
// over about REVERB_FADE.
@(step="late",stage="end",after="camera_view")
audio_reverb :: proc(
    reverbs:^core.Table(Audio_Reverb,.Read),volumes:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),listeners:^core.Table(Audio_Listener,.Read),
    view:core.Ref(core.View),settings:core.Ref(Audio_Settings),medium:core.Ref(Audio_Medium),frame:core.Frame_Time,reverb:^Mixer_Reverb,m:^Mixer,
) {
    if m==nil || reverb==nil {return}
    bus:=BUS_MASTER
    if settings.ptr!=nil {bus=settings.reverb_bus}
    hearing:=Hearing{worlds=worlds,listeners=listeners,view=view}
    room,silent:Audio_Reverb
    if position,_,_,found:=listener_pose(&hearing);found {room=volume.at(volumes,worlds,reverbs,position,silent,reverb_mix)}
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
audio_buses :: proc(settings:core.Ref(Audio_Settings),volumes:core.Ref(Audio_Volumes),medium:core.Ref(Audio_Medium),m:^Mixer,problems:^core.Problems) {
    buses_apply(m,settings.ptr,volumes.ptr,medium.ptr,problems)
}

// Gives the buses of the mixer what the settings say, and the master the
// lowpass of the medium: what audio_buses does each frame of a game, and the
// editor before it plays a sound to be heard.
buses_apply :: proc(m:^Mixer,settings:^Audio_Settings,volumes:^Audio_Volumes=nil,medium:^Audio_Medium=nil,problems:^core.Problems=nil) {
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
        send:=setting.send
        if send>=bus {
            if send!=BUS_MASTER {core.report(problems,core.NONE,"audio.send","Audio_Settings: bus %d sends to bus %d, which does not come before it, so it plays into the master; send it to BUS_MASTER or a bus of a lower number",int(bus),int(send))}
            send=BUS_MASTER
        }
        if mixer.bus_send(m,mixer.Bus(bus))!=mixer.Bus(send) {mixer.bus_set_send(m,mixer.Bus(bus),mixer.Bus(send))}
        duck:mixer.Duck
        if amount:=clamp(setting.duck_amount,0,1);amount>0 && setting.duck_by!=bus && int(setting.duck_by)<mixer.bus_count(m) {
            duck={mixer.Bus(setting.duck_by),max(setting.duck_threshold,0),amount,max(setting.duck_attack,0),max(setting.duck_release,0)}
        }
        if mixer.bus_duck(m,mixer.Bus(bus))!=duck {mixer.bus_set_duck(m,mixer.Bus(bus),duck)}
    }
}

// Plays the mixer on the output of the settings when they change; while that
// output is not connected, on the default, until it comes back. The mixer
// keeps its voices and its clock. An application whose mixer the system does
// not play (headless, or one nobody plays) has no output to change.
@(step="late",stage="end",loops="game editor")
audio_output :: proc(output:Audio_Output,applied:^Mixer_Output,app:^host.App,problems:^core.Problems) {
    if app.mixer==nil {return}
    kind:=output.kind if output.kind<=max(Output_Kind) else .Speakers
    if mixer.mixer_output(app.mixer)!=kind {mixer.mixer_set_output(app.mixer,kind)}
    p:=app.platform
    if !platform.audio_device_is_open(p) {return}
    changes:=platform.audio_device_changes(p)
    device:=output.device
    name:=base.text_get(device[:])
    lost:bool
    if applied.set && applied.device==device {
        // The chosen output left, or one came that may be it coming back.
        lost=.Lost in changes && !applied.missing
        back:=.Added in changes && applied.missing && slice.contains(platform.audio_device_names(p,context.temp_allocator),name)
        if !lost && !back {return}
    }
    first:=!applied.set
    applied.device,applied.set=device,true
    // The application opened the default.
    if first && name=="" {return}
    error,found:=platform.audio_device_switch(p,"" if lost else name)
    applied.missing=error!=.None || lost || !found
    if error!=.None {
        // The default, which the application opened, opens again.
        reopened:=platform.audio_device_open(p,app.mixer)==.None
        core.report(problems,core.NONE,"audio.output","the output \"%s\" did not open (%v): %s; choose another in Audio_Output.device, or leave it empty for the default",name,error,reopened?"the sound plays on the default one":"the game plays no sound")
    } else if applied.missing {
        core.report(problems,core.NONE,"audio.output","the output \"%s\" is not connected, so the sound plays on the default one until it is; give Audio_Output.device one of %v, or leave it empty",name,platform.audio_device_names(p,context.temp_allocator))
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
listener_position :: proc(worlds:^core.Table(core.World_Transform,$A),listeners:^core.Table(Audio_Listener,$B),view:core.Ref(core.View)) -> (position:[3]f32,found:bool) {
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
    a:=mixer.Attenuation{model=source.attenuation,min_distance=source.min_distance,max_distance=source.max_distance,rolloff=source.rolloff,delay=source.delay}
    a.near_radius=source.near_radius>0?source.near_radius:mixer.ATTENUATION_DEFAULT.near_radius
    return a
}

// Why a source cannot play, as how to correct it; "" when it can.
@(private)
source_problem :: proc "contextless" (s:Audio_Source) -> string {
    for x in ([?]f32{s.volume,s.pitch,s.reverb,s.doppler,s.directivity,s.directivity_power,s.rolloff,s.near_radius}) {
        if !(x>=0 && x<=max(f32)) {return "volume, pitch, reverb, doppler, directivity, directivity_power, rolloff and near_radius are numbers of 0 or more"}
    }
    if s.spatial && !(s.min_distance>0 && s.max_distance>s.min_distance && s.max_distance<=max(f32)) {
        return "a spatial one is heard from min_distance, above 0, to max_distance, above it"
    }
    return ""
}

// A source as it was written: its voice stops, starts again when its kind is
// another, or takes its volume, pitch, loop, pan and send.
@(private)
source_set :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,source:Audio_Source,e:core.Entity,state:^Audio_Source_State,problems:^core.Problems) {
    entry:=core.entity_map_get(&voices.entries,e)
    if !source.playing {
        if entry!=nil {
            mixer.voice_stop(m,entry.voice)
            core.entity_map_remove(&voices.entries,e)
        }
        state^={}
        return
    }
    _,placed:=core.get(h.worlds,e)
    if entry!=nil && mixer.sound_valid(m,entry.sound) && entry.kind==kind_of(source,placed) && source_problem(source)=="" {
        now:=mixer.mixer_clock(m)
        entry.cursor,entry.clock,entry.speed=entry_time(entry,now),now,(source.pitch>0?source.pitch:1)*entry.pick[1]
        if source.loop && entry.length>0 {entry.cursor=math.mod(entry.cursor,f64(entry.length))}
        if entry.voice=={} {return}
        mixer.voice_set_volume(m,entry.voice,source.volume*entry.pick[0])
        mixer.voice_set_pitch(m,entry.voice,entry.speed)
        mixer.voice_set_loop(m,entry.voice,source.loop)
        mixer.voice_set_reverb(m,entry.voice,source.reverb)
        if !entry.kind.spatial {mixer.voice_set_pan(m,entry.voice,source.pan)}
        return
    }
    if entry!=nil {
        mixer.voice_stop(m,entry.voice)
        core.entity_map_remove(&voices.entries,e)
    }
    if state.ended && state.plays==source.plays {return}
    state.ended,state.plays,state.voice=false,source.plays,{}
    source_start(voices,m,app,h,source,e,problems)
}

// What the voice of a source is started as, placed or not.
@(private)
kind_of :: proc "contextless" (source:Audio_Source,placed:bool) -> Voice_Kind {
    return {
        sound=source.sound,bus=source.bus,spatial=source.spatial && placed,attenuation=attenuation_of(source),
        directivity={clamp(source.directivity,0,1),max(source.directivity_power,0)},doppler=source.doppler,plays=source.plays,
    }
}

// The entry of a source that starts, virtual at the start of its sound until
// voices_assign gives it a voice; one whose sound does not load yet waits in
// it for a later frame.
@(private)
source_start :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,source:Audio_Source,e:core.Entity,problems:^core.Problems) {
    if problem:=source_problem(source);problem!="" {
        core.report(problems,e,"audio.source","its Audio_Source plays nothing: %s",problem)
        return
    }
    world,placed:=core.get(h.worlds,e)
    entry:=Voice_Entry{kind=kind_of(source,placed),generation=host.content_sound_generation(app,source.sound),clock=mixer.mixer_clock(m),rotation=1,transmission=mixer.TRANSMISSION_DEFAULT}
    pick,picked:=sound_pick(m,app,source,e,problems)
    if !picked && !bus_ready(m,source.bus) {return}
    entry.sound,entry.pick,entry.length=pick.sound,{pick.volume,pick.pitch},mixer.sound_seconds(m,pick.sound)
    entry.speed=(source.pitch>0?source.pitch:1)*pick.pitch
    if entry.kind.spatial {
        entry.position=world.position
        if entry.kind.directivity.weight>0 {entry.rotation=world.rotation}
    }
    // Without memory to keep it the source cannot be followed: it does not play.
    if _,kept:=core.entity_map_put(&voices.entries,e,entry);!kept {
        core.report(problems,e,"audio.memory","its Audio_Source did not start: out of memory to follow its voice; free memory")
        return
    }
    if picked {voices.stats.started+=1}
}

// How hidden a spatial source is from the listener, which state follows over
// the fade of its Audio_Occlusion (at once when start), and what lets it
// through. In sight without one.
@(private)
hidden :: proc(h:^Hearing,listener:[3]f32,e:core.Entity,world:core.World_Transform,dt:f32,state:^Audio_Source_State,start:bool) -> (transmission:[mixer.BANDS]f32) {
    transmission=mixer.TRANSMISSION_DEFAULT
    occlusion,hides:=core.get(h.occlusions,e)
    if !hides {
        state.occlusion,state.rays_valid,state.rays_open,state.ray_next=0,0,0,0
        return
    }
    target:=occlusion_amount(h.query,e,world.position,listener,occlusion.radius,state,start)
    if start || !(occlusion.fade>0) || dt<=0 {
        state.occlusion=target
    } else {
        step:=dt/occlusion.fade
        state.occlusion+=clamp(target-state.occlusion,-step,step)
    }
    if state.occlusion>0 {transmission=transmission_through(h,e,world.position,listener)}
    return
}

// An entry in the frame: one whose sound was loaded again, or is still to
// load, starts again; one whose voice ended or was stolen goes virtual, and
// ends when its time passes its sound without loop; a spatial one follows its
// entity, and with a voice what hides it.
@(private)
voice_follow :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,listener:[3]f32,source:Audio_Source,e:core.Entity,dt:f32,state:^Audio_Source_State,problems:^core.Problems) {
    entry:=core.entity_map_get(&voices.entries,e)
    world,placed:=core.get(h.worlds,e)
    if !mixer.sound_valid(m,entry.sound) || entry.generation!=host.content_sound_generation(app,source.sound) || entry.kind.spatial!=(source.spatial && placed) {
        mixer.voice_stop(m,entry.voice)
        core.entity_map_remove(&voices.entries,e)
        state.voice={}
        source_start(voices,m,app,h,source,e,problems)
        return
    }
    if entry.voice!={} && !mixer.voice_valid(m,entry.voice) {entry.voice,state.voice={},{}}
    if entry.voice=={} && !source.loop && entry_time(entry,mixer.mixer_clock(m))>=f64(entry.length) {
        core.entity_map_remove(&voices.entries,e)
        state.voice,state.ended={},true
        voices.stats.ended+=1
        return
    }
    if !entry.kind.spatial {return}
    rotation:=world.rotation if entry.kind.directivity.weight>0 else 1
    if entry.voice=={} {
        entry.position,entry.rotation,entry.moving=world.position,rotation,false
        return
    }
    occlusion:=state.occlusion
    if transmission:=hidden(h,listener,e,world,dt,state,false);state.occlusion!=occlusion || transmission!=entry.transmission {
        mixer.voice_set_occlusion(m,entry.voice,state.occlusion,transmission)
        entry.transmission=transmission
    }
    if entry.position!=world.position || entry.moving || entry.rotation!=rotation {
        velocity:[3]f32
        if entry.kind.doppler>0 && dt>0 {velocity=(world.position-entry.position)/dt}
        mixer.voice_set_position(m,entry.voice,world.position,velocity,rotation)
        entry.position,entry.moving,entry.rotation=world.position,velocity!={},rotation
    }
}

// What plays for the sound of a source: one of its set when it is one. False,
// with the problem of e (NONE: of a request), when nothing of it can play.
@(private)
sound_pick :: proc(m:^Mixer,app:^host.App,source:Audio_Source,e:core.Entity,problems:^core.Problems) -> (pick:host.Sound_Pick,ok:bool) {
    who:=e==core.NONE?"audio.play":"its Audio_Source"
    if !bus_ready(m,source.bus) {
        core.report(problems,e,"audio.bus","%s plays nothing: bus %d is not a bus of the mixer, which has %d; give it a bus below that",who,int(source.bus),AUDIO_BUS_CAPACITY)
        return
    }
    pick=host.content_sound_pick(app,source.sound)
    if mixer.sound_valid(m,pick.sound) {return pick,true}
    name:[base.ASSET_ID_TEXT]u8
    if source.sound=={} {
        core.report(problems,e,"audio.sound","%s plays nothing: it has no sound; give it a .sound or a .sound_set of the assets",who)
    } else {
        core.report(problems,e,"audio.sound","%s plays nothing: sound %s does not load as a sound (it is missing, damaged, not a .sound or a .sound_set, or a set none of whose sounds load); give it a .sound or a .sound_set of the assets",who,host.assets_name(app.assets,source.sound,&name))
    }
    return
}

// The voice of a source as it is set, with the volume and pitch its set drew:
// at position, facing rotation and as hidden as occlusion says when spatial,
// panned when not.
@(private)
voice_desc :: proc "contextless" (source:Audio_Source,pick:[2]f32,position:[3]f32,rotation:quaternion128,occlusion:f32,transmission:[mixer.BANDS]f32) -> mixer.Voice_Desc {
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.loop=mixer.Bus(source.bus),source.volume*pick[0],(source.pitch>0?source.pitch:1)*pick[1],source.loop
    desc.reverb,desc.priority=source.reverb,source.priority
    if source.spatial {
        desc.spatial,desc.position,desc.rotation,desc.attenuation,desc.doppler=true,position,rotation,attenuation_of(source),source.doppler
        desc.directivity={clamp(source.directivity,0,1),max(source.directivity_power,0)}
        desc.occlusion,desc.transmission=occlusion,transmission
    } else {
        desc.pan=source.pan
    }
    return desc
}

// Starts a voice of a source as it is set, at position when spatial: what a
// request of Sound_Requests and what the editor plays to be heard start.
// Zero, with the problem of e (NONE: of a request), when it does not start.
voice_start :: proc(m:^Mixer,app:^host.App,source:Audio_Source,e:core.Entity,problems:^core.Problems,position:[3]f32={}) -> Voice {
    pick,ok:=sound_pick(m,app,source,e,problems)
    if !ok {return 0}
    return voice_picked(m,source,pick,e,problems,position)
}

@(private)
voice_picked :: proc(m:^Mixer,source:Audio_Source,pick:host.Sound_Pick,e:core.Entity,problems:^core.Problems,position:[3]f32) -> (voice:Voice) {
    if voice=mixer.voice_play(m,pick.sound,voice_desc(source,{pick.volume,pick.pitch},position,1,0,mixer.TRANSMISSION_DEFAULT));voice=={} {
        core.report(problems,e,"audio.voices","%s did not start: every voice of the mixer plays a sound of the same or a higher priority; play fewer sounds at once, raise its priority, or raise the voices of the mixer",e==core.NONE?"audio.play":"its Audio_Source")
    }
    return
}

SOUND_PATH_CAPACITY :: 128

// A sound played once, as an Audio_Source with these values and the hearing of
// its .sound_set (SOUND_HEARING_DEFAULT for a .sound) plays it: by id, or by
// path when the id is zero.
Sound_Request :: struct {
    sound:base.Asset_Id,
    path:[SOUND_PATH_CAPACITY]u8 `mirai:"text"`,
    at:[3]f32,
    placed:bool, // spatial at `at`; else not placed
    bus:Audio_Bus,
    volume,pitch:f32,
}

// Requests: any step pushes with play; audio_requests starts them at the end
// of the tick that asked and at the end of every frame.
@(storage,queue)
Sound_Requests :: struct {using queue:core.Queue(Sound_Request)}

// Plays a .sound, or one of a .sound_set, once: by its path in the assets
// ("arena/crash.sound") or its id; at a point of the world, or not placed.
// What must stop, loop or follow a thing is an Audio_Source.
play :: proc{play_path,play_id}

play_id :: proc(sounds:^Sound_Requests,sound:base.Asset_Id,at:Maybe([3]f32)=nil,bus:=BUS_EFFECTS,volume:f32=1,pitch:f32=1) {
    position,placed:=at.?
    core.push(&sounds.queue,Sound_Request{sound=sound,at=position,placed=placed,bus=bus,volume=volume,pitch=pitch})
}

// A path that does not fit SOUND_PATH_CAPACITY plays as one the assets do not have.
play_path :: proc(sounds:^Sound_Requests,path:string,at:Maybe([3]f32)=nil,bus:=BUS_EFFECTS,volume:f32=1,pitch:f32=1) {
    position,placed:=at.?
    r:=Sound_Request{at=position,placed=placed,bus=bus,volume=volume,pitch=pitch}
    if len(path)<SOUND_PATH_CAPACITY {base.text_set(r.path[:],path)}
    core.push(&sounds.queue,r)
}

// Starts what was asked since the last time, once. A tick that runs again
// (time.resimulating) asked for it the first time, when this step played it
// at its end: what it asks again is dropped, and no copy of the world holds a
// request it played, since copies are made between ticks.
@(step="fixed late",stage="end",loops="game editor")
audio_requests :: proc(sounds:^Sound_Requests,time:core.Time,listener:^Mixer_Listener,app:^host.App,problems:^core.Problems) {
    requests:=core.take(&sounds.queue)
    if app.mixer==nil || time.resimulating {return}
    for &r in requests {
        if !(r.volume>=0 && r.volume<=max(f32) && r.pitch>=0 && r.pitch<=max(f32) && abs(r.at.x)<=max(f32) && abs(r.at.y)<=max(f32) && abs(r.at.z)<=max(f32)) {
            core.report(problems,core.NONE,"audio.request","audio.play was refused: volume %v, pitch %v, at %v; give it a volume and a pitch of 0 or more and a place of finite numbers",r.volume,r.pitch,r.at)
            continue
        }
        source:=AUDIO_SOURCE_DEFAULT
        source.sound,source.bus,source.volume,source.pitch,source.spatial=r.sound,r.bus,r.volume,r.pitch,r.placed
        if r.sound=={} {
            path:=base.text_get(r.path[:])
            if source.sound,_=host.assets_id(app.assets,path);source.sound=={} {
                core.report(problems,core.NONE,"audio.sound","audio.play plays nothing: \"%s\" is not a path of the assets; give it the path of a .sound or a .sound_set under the assets folder, shorter than SOUND_PATH_CAPACITY",path)
                continue
            }
        }
        pick,picked:=sound_pick(app.mixer,app,source,core.NONE,problems)
        if !picked {continue}
        hearing:=pick.hearing
        source.attenuation,source.min_distance,source.max_distance=Attenuation_Model(hearing.attenuation),hearing.min_distance,hearing.max_distance
        source.rolloff,source.reverb,source.priority=hearing.rolloff,hearing.reverb,hearing.priority
        // Placed beyond where it is heard, it does not start.
        if r.placed && listener!=nil && listener.set && !(linalg.distance(r.at,listener.position)<hearing.max_distance) {continue}
        voice_picked(app.mixer,source,pick,core.NONE,problems,r.at)
    }
}
