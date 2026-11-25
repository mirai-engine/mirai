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
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:std/base"

// Sound. The mixer belongs to the application, which hands it to the
// function that asks for a ^Mixer (nil without audio); this library
// keeps its voices equal to the Audio_Source components of the world, its
// listeners at the Audio_Listener entities or, without one, at the View, its
// buses as Audio_Settings says and its reverb as the Audio_Reverb volumes
// where the listeners are.
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
AUDIO_LISTENERS_MAX :: mixer.LISTENERS_MAX // the players of a split screen that hear at once
// A spatial source goes to another listener once that one is nearer than this
// share of the distance to its own: crossing the middle between two players
// does not throw it from ear to ear.
LISTENER_SWITCH :: f32(0.88)
LAYER_ENDED :: f64(0.05) // s: a voice that ends this close to the end of its sound ended, else it was stolen
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
// it is heard or plays starts it again. A Random .sound_set chooses one of its
// sounds each time the voice starts, and a loop repeats the one it chose; a
// Layered one plays all of its sounds in step, a voice each, and its curves
// shape them by parameters, which glide to new values as the set says. A sound
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
    spread:f32 `mirai:"min=0,unit=m"`, // of a stereo sound: how far apart its channels are heard across it, wide up close and a point far away; 0: one source
    delay:bool, // starts later by its distance over the speed of sound, as thunder after its flash
    doppler:f32 `mirai:"min=0"`, // 0: none; 1: the physical shift of pitch as it and the listener move
    reverb:f32 `mirai:"min=0,max=1"`, // share of it the room of the listener reverberates
    directivity:f32 `mirai:"min=0,max=1"`, // 0: the same all around; 0.5: loudest toward -Z of the entity and silent behind; 1: silent at its sides
    directivity_power:f32 `mirai:"min=0"`,  // how narrow the directivity is: 1 as it is, higher narrower
    priority:u8, // when more sources play than the mixer has voices, the higher keep theirs before the louder
    parameters:[PARAMETERS]f32, // values of the parameters of its .sound_set, in their order; parameter_set sets one by its name
}

AUDIO_SOURCE_DEFAULT :: Audio_Source{bus=BUS_EFFECTS,volume=1,pitch=1,playing=true,attenuation=.Inverse,min_distance=1,max_distance=20,rolloff=1,near_radius=1,spread=2,directivity_power=1}

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
    zone:volume.Zone,
}

AUDIO_REVERB_DEFAULT :: Audio_Reverb{room_size=0.6,damping=0.4,wet=1,width=1,zone=volume.ZONE_DEFAULT}

#assert(offset_of(Audio_Reverb,zone)==size_of(Reverb))

// What the library derived from the source. Only audio_sources writes it.
@(component,derived)
Audio_Source_State :: struct {
    voice:mixer.Voice `mirai:"transient,readonly,local,hidden"`, // of its first sound
    ended:bool `mirai:"transient,readonly,local"`,
    plays:u32 `mirai:"transient,readonly,local,hidden"`, // Audio_Source.plays its last voice started at
    occlusion:f32 `mirai:"transient,readonly,local"`, // 0 in sight to 1 hidden, of a source with an Audio_Occlusion
    // Of the OCCLUSION_SAMPLES points of its sphere: those the source reaches,
    // those the listener sees, and the next to test.
    rays_valid,rays_open:u16 `mirai:"transient,readonly,local,hidden"`,
    ray_next:u8 `mirai:"transient,readonly,local,hidden"`,
}

// An entity that hears, as the camera of a player of a split screen: the
// first AUDIO_LISTENERS_MAX with a world transform, in the order of their
// rows, are the slots of the listeners. Each spatial source is heard from the
// nearest (LISTENER_SWITCH). Without one, the View hears.
@(component)
Audio_Listener :: struct {}

// What surrounds a listener besides the air, as the water it is under.
Medium :: struct {
    lowpass:f32 `mirai:"min=0,unit=Hz"`, // cutoff of the low-pass filter of what the listener hears; 0: none
    reverb:Reverb,
    weight:f32 `mirai:"min=0,max=1"`,    // of its reverb over that of the room
}

// The medium of each listener, by its slot (listener_positions). While every
// listener is under one, audio_buses filters the master bus by the highest of
// their lowpasses too, the lower of that and its own; while only some are,
// the voices heard from those lose their highs through their EQ
// (mixer.lowpass_bands). audio_reverb mixes the reverb of each by weight over
// that of its room. One plugin writes it (water), before audio_reverb,
// audio_buses and audio_sources; zero: the air.
@(storage)
Audio_Medium :: struct {
    listeners:[AUDIO_LISTENERS_MAX]Medium,
}

// How a bus sounds. A bus without an entry plays as its voices come into the
// master; an entry of zeros says nothing. What plays into it goes through its
// reverb, its filters in order, its delay and its gain.
Audio_Bus_Setting :: struct {
    bus:Audio_Bus,
    send:Audio_Bus, // the bus it plays into, with its gain, filter and ducking: the master, or one of a lower number (ambience into effects)
    gain:f32 `mirai:"min=-80,max=24,unit=dB"`, // 0: as it comes; AUDIO_SILENCE_DB or below: silent
    filters:[mixer.BUS_FILTERS]mixer.Filter,   // low-pass, high-pass, band-pass or peak bands; Off: none
    delay:mixer.Delay,                         // an echo of all it plays; wet 0: none
    duck_by:Audio_Bus,                         // while it is louder than duck_threshold, this bus goes down by duck_amount
    duck_amount:f32 `mirai:"min=0,max=1"`,     // 0: not ducked
    duck_threshold:f32 `mirai:"min=0"`,        // linear peak
    duck_attack:f32 `mirai:"min=0,unit=s"`,
    duck_release:f32 `mirai:"min=0,unit=s"`,
    reverb:Reverb, // on all it plays, as a song made to sound in a hall; wet 0: none
}

// One entry per bus that does not play as it comes, the first one of a bus
// being the one that counts, the bus the reverb returns in, how many streamed
// sounds (music, long ambiences) play at once, and the snapshots Audio_Mix
// blends to.
@(storage,setting)
Audio_Settings :: struct {
    buses:[AUDIO_BUS_CAPACITY]Audio_Bus_Setting `mirai:"trim"`,
    reverb_bus:Audio_Bus,
    stream_capacity:int `mirai:"min=0,max=64"`, // 0: mixer.STREAM_CAPACITY_DEFAULT; one more stream refused is a problem "audio.streams"
    snapshots:[AUDIO_SNAPSHOT_CAPACITY]Audio_Snapshot `mirai:"trim"`,
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

// A source that plays: mixed by its voices, one per sound it plays at once,
// or virtual (not real) while it is not heard or louder ones hold the voices
// of the mixer.
Voice_Entry :: struct {
    sound:Sound_Voices, // what it drew; no sounds: nothing of it loads yet
    fading:[LAYERS]mixer.Voice, // the voices it held last, while they go quiet
    real:bool,
    kind:Voice_Kind,
    generation:u32, // of what the content loaded for sound
    lengths:[LAYERS]f32, // s of each sound
    // Its parameters: where each is, where it goes and how fast, per second.
    values,targets,rates:[PARAMETERS]f32,
    shapes:[LAYERS]asset.Sound_Shape, // what the curves of its set give each sound at values
    // Its time: each sound is times[i] seconds into it at mixer clock `clock`
    // (below 0: as many seconds before it starts), going on at speeds[i], its pitch.
    times:[LAYERS]f64,
    clock:u64,
    speeds:[LAYERS]f32,
    // Of a spatial voice: where it was placed last, how it faces, what hides it
    // and the slot of the listener it is heard from.
    moving:bool,
    position:[3]f32,
    rotation:quaternion128,
    transmission:[mixer.BANDS]f32,
    listener:u8,
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
// the mixer. The world whose listeners moved, or that runs after another,
// places them.
@(storage,host)
Mixer_Listeners :: struct {
    slots:[AUDIO_LISTENERS_MAX]Mixer_Listener,
    count:int, // 0: none was placed yet
}
Mixer_Listener :: struct {
    position:[3]f32,
    rotation:quaternion128,
    velocity:[3]f32,
    medium:[mixer.BANDS]f32, // what the mixer dulls its voices by: lowpass_bands while not every listener is under a medium
}

// The reverb of the mixer as it was told last, on its way to that of the
// room the listener is in: one per application, as the mixer.
@(storage,host)
Mixer_Reverb :: struct {
    reverb:Reverb,
    bus:Audio_Bus,
    set:bool,
    world:core.World_Id,
    seen:[5]core.Seen,
    worlds:core.Seen,
    positions:[AUDIO_LISTENERS_MAX][3]f32,
    count:int, // listeners at positions
    measured:bool,
    rooms:[AUDIO_LISTENERS_MAX]Reverb,
}

// The buses of the mixer as they were told last, and the blend of their
// levels to the snapshot of Audio_Mix: one per application, as the mixer.
@(storage,host)
Mixer_Buses :: struct {
    world:core.World_Id,
    settings,volumes:core.Seen,
    count:int,
    lowpass:f32,
    set:bool,
    streams:int,       // the stream capacity applied; 0: none yet
    streams_busy:u64,  // mixer.Mixer_Stats.streams_busy as last seen
    blend:Mix_Blend,
}

@(params)
Audio_Scene :: struct {
    world:core.World_Read,
    worlds:^core.Table(core.World_Transform,.Read),
    occlusions:^core.Table(Audio_Occlusion,.Read),
    materials:^core.Table(Audio_Material,.Read),
    listeners:^core.Table(Audio_Listener,.Read),
    view:core.Ref(core.View),
    queries:core.Ref(core.World_Queries),
    medium:core.Ref(Audio_Medium),
}

@(step="late",stage="end",after="camera_view")
audio_sources :: proc(
    sources:^core.Table(Audio_Source,.Read),states:^core.Table(Audio_Source_State),
    space:Audio_Scene,frame:core.Frame_Time,clock:core.Clock,voices:^Voices,
    listeners:^Mixer_Listeners,app:^host.App,problems:^core.Problems,
) {
    if voices!=nil && app.mixer!=nil && clock.paused!=voices.paused {
        voices.paused=clock.paused
        now:=mixer.mixer_clock(app.mixer)
        for &entry,at in voices.entries.values {
            if clock.paused {
                entry.times=entry_times(&entry,now)
                if entry.real {voice_virtual(voices,app.mixer,at,states)}
            }
            lead:=u64(LAYER_LEAD) if entry.sound.count>1 else u64(VOICE_LEAD)
            entry.clock=now if clock.paused else now+lead
        }
    }
    if voices!=nil && voices.paused {return}
    sources_update(sources,states,{space.worlds,space.occlusions,space.materials,space.listeners,space.view,space.medium,core.world_query_read(space.world,space.queries),0},frame.dt,voices,listeners,app,problems)
}

VOICE_LEAD :: mixer.CHUNK_FRAMES

// What the voices of a frame look at besides their sources.
@(private)
Hearing :: struct {
    worlds:^core.Table(core.World_Transform,.Read),
    occlusions:^core.Table(Audio_Occlusion,.Read),
    materials:^core.Table(Audio_Material,.Read),
    listeners:^core.Table(Audio_Listener,.Read),
    view:core.Ref(core.View),
    medium:core.Ref(Audio_Medium),
    query:core.World_Query, // what hides a source
    now:u64, // mixer clock read once for the pass
}

@(private)
sources_update :: proc(sources:^core.Table(Audio_Source,$A),states:^core.Table(Audio_Source_State),hearing:Hearing,dt:f32,voices:^Voices,listeners:^Mixer_Listeners,app:^host.App,problems:^core.Problems) {
    m:=app.mixer
    if m==nil || voices==nil {return}
    if cap(voices.ranks)==0 && (!core.entity_map_reserve(&voices.entries,VOICE_RESERVE) || reserve(&voices.ranks,VOICE_RESERVE)!=nil) {
        core.report(problems,core.NONE,"audio.memory","the Audio_Sources play nothing: out of memory to follow their voices; free memory")
        return
    }
    hearing:=hearing
    hearing.now=mixer.mixer_clock(m)
    listener_update(listeners,m,&hearing,dt)
    // The voices of the sources that went stop.
    changes,at,left:=core.changes(sources,&voices.seen),0,Voice_Entry{}
    for _ in core.entity_map_left(&voices.entries,sources,changes,&at,&left) {sound_voices_stop(m,&left.sound)}
    // A source written starts, stops or tunes its own; then each follows its entity.
    for row in core.each_changed(sources,&changes) {
        e:=core.entity_at(sources,row)
        state,_:=core.get(states,e)
        source_set(voices,m,app,&hearing,listeners,core.at(sources,row),e,&state,problems)
        state_put(states,e,state)
    }
    for i:=len(voices.entries.entities)-1;i>=0;i-=1 {
        e:=voices.entries.entities[i]
        source,_:=core.get(sources,e)
        state,_:=core.get(states,e)
        voice_follow(voices,m,app,&hearing,listeners,source,e,dt,&state,problems)
        state_put(states,e,state)
    }
    voices_assign(voices,m,&hearing,listeners,sources,states)
}

// The voices of the mixer go to the entries heard most, by priority first: as
// many as the mixer has free and the entries hold, all the voices of an entry
// or none. A spatial one is as loud as at its nearest listener. One that falls
// out goes virtual, and one that comes in plays where its time is, on voices
// that are free: none is stolen, so a steady scene starts and stops nothing.
@(private)
voices_assign :: proc(voices:^Voices,m:^Mixer,h:^Hearing,listeners:^Mixer_Listeners,sources:^core.Table(Audio_Source,.Read),states:^core.Table(Audio_Source_State)) {
    free:=mixer.voices_free(m)
    budget:=free
    clear(&voices.ranks)
    for &entry,at in voices.entries.values {
        for &fading in entry.fading {
            if fading!={} && !mixer.voice_valid(m,fading) {fading={}}
        }
        source,_:=core.get(sources,voices.entries.entities[at])
        gain:=entry_gain(m,source,&entry,listeners)
        if entry.real {gain*=VOICE_KEEP}
        if gain>0 && voices_sounds_valid(m,&entry.sound) {
            if _,failed:=append(&voices.ranks,Voice_Rank{u32(at),source.priority,gain});failed!=nil {gain=0}
        } else {
            gain=0
        }
        if entry.real && gain==0 {voice_virtual(voices,m,at,states)}
        for voice in entry.sound.voices[:entry.sound.count] {budget+=int(voice!={})}
        for fading in entry.fading {budget+=int(fading!={})}
    }
    slice.sort_by(voices.ranks[:],proc(a,b:Voice_Rank) -> bool {return a.priority>b.priority || a.priority==b.priority && a.gain>b.gain})
    used:=0
    for rank in voices.ranks {
        entry:=&voices.entries.values[rank.at]
        need:=entry.sound.count
        if used+need>budget {
            if entry.real {voice_virtual(voices,m,int(rank.at),states)}
            continue
        }
        used+=need
        if !entry.real && free>=need {
            if voice_real(voices,m,h,listeners,sources,states,int(rank.at)) {free-=need}
        }
    }
}

// How a source that plays is heard now, as voices_assign ranks it.
Voice_State :: enum u8 {
    Playing,        // mixed by a voice of the mixer
    Virtual_Budget, // heard, but louder ones or ones of a higher priority hold the voices
    Virtual_Silent, // not heard: silent, beyond its attenuation or on a silent bus
    Fading,         // it lost its voice, which still fades out
    Unloaded,       // its sound does not load yet
}

// The linear gain of an entry at its nearest listener: its volume by what its set drew, its bus
// and, when spatial, its attenuation; before what hides it. 0 without a mixer.
entry_gain :: proc(m:^Mixer,source:Audio_Source,entry:^Voice_Entry,listeners:^Mixer_Listeners) -> f32 {
    if m==nil {return 0}
    loudest:=f32(0)
    for i in 0..<entry.sound.count {
        g:=entry.sound.gains[i] if entry.sound.gains[i]>0 else 1
        loudest=max(loudest,g*entry.shapes[i].gain)
    }
    if entry.sound.count==0 {loudest=1}
    gain:=source.volume*entry.sound.volume*loudest*mixer.bus_volume(m,mixer.Bus(entry.kind.bus))
    if entry.kind.spatial {gain*=mixer.attenuation_gain(entry.kind.attenuation,listeners_distance(listeners,entry.position))}
    return gain
}

// How an entry with gain (entry_gain) is heard now; Unloaded without a mixer.
voice_state :: proc(m:^Mixer,entry:^Voice_Entry,gain:f32) -> Voice_State {
    if m==nil || !voices_sounds_valid(m,&entry.sound) {return .Unloaded}
    if sound_voices_valid(m,&entry.sound) {return .Playing}
    for fading in entry.fading {
        if fading!={} && mixer.voice_valid(m,fading) {return .Fading}
    }
    if !(gain>0) {return .Virtual_Silent}
    return .Virtual_Budget
}

// The entry at goes on without its voices, which fade out.
@(private)
voice_virtual :: proc(voices:^Voices,m:^Mixer,at:int,states:^core.Table(Audio_Source_State)) {
    entry_silence(m,&voices.entries.values[at])
    e:=voices.entries.entities[at]
    if state,has:=core.get(states,e);has {
        state.voice={}
        state_put(states,e,state)
    }
}

// Stops the voices of an entry, which it keeps as fading until they are quiet.
@(private)
entry_silence :: proc(m:^Mixer,entry:^Voice_Entry) {
    mixer.mixer_batch_begin(m)
    for &voice,i in entry.sound.voices[:entry.sound.count] {
        if voice=={} {continue}
        mixer.voice_stop(m,voice)
        entry.fading[i],voice=voice,{}
    }
    mixer.mixer_batch_end(m)
    entry.real=false
}

// The entry at plays again where its time is; false when the mixer refused it.
@(private)
voice_real :: proc(voices:^Voices,m:^Mixer,h:^Hearing,listeners:^Mixer_Listeners,sources:^core.Table(Audio_Source,.Read),states:^core.Table(Audio_Source_State),at:int) -> bool {
    entry:=&voices.entries.values[at]
    e:=voices.entries.entities[at]
    source,_:=core.get(sources,e)
    state,_:=core.get(states,e)
    lead:=u64(LAYER_LEAD) if entry.sound.count>1 else u64(VOICE_LEAD)
    start:=max(h.now+lead,entry.clock)
    times:=entry_times(entry,start)
    heard:=source
    heard.spatial=entry.kind.spatial
    if heard.spatial {
        world,_:=core.get(h.worlds,e)
        entry.transmission=hidden(h,listeners.slots[entry.listener].position,e,world,0,&state,true)
    }
    desc:=voice_desc(heard,{entry.sound.volume,entry.sound.pitch},entry.position,entry.rotation,state.occlusion,entry.transmission,entry.listener)
    desc.start_frame=start
    if !voices_play(m,&entry.sound,desc,&entry.shapes,&times,&entry.lengths) {return false}
    entry.real=true
    state.voice=entry.sound.voices[0]
    state_put(states,e,state)
    return true
}

// Seconds into its sound the voice of a layer of an entry is, or would be, at
// mixer clock now; below 0, seconds before its delay lets it start.
@(private)
entry_time :: proc "contextless" (entry:^Voice_Entry,layer:int,now:u64) -> f64 {
    elapsed:=f64(now-min(now,entry.clock))/mixer.MIXER_RATE
    time:=entry.times[layer]
    if time<0 {
        if elapsed<=-time {return time+elapsed}
        elapsed+=time
        time=0
    }
    return time+elapsed*f64(entry.speeds[layer])
}
@(private)
entry_times :: proc "contextless" (entry:^Voice_Entry,now:u64) -> (times:[LAYERS]f64) {
    for i in 0..<clamp(entry.sound.count,0,LAYERS) {times[i]=entry_time(entry,i,now)}
    return
}
// Whether every sound of an entry played to its end by mixer clock now.
@(private)
entry_ended :: proc "contextless" (entry:^Voice_Entry,now:u64) -> bool {
    for i in 0..<clamp(entry.sound.count,0,LAYERS) {
        if entry_time(entry,i,now)<f64(entry.lengths[i]) {return false}
    }
    return true
}

// The state of a source, written only when it is another.
@(private)
state_put :: proc(states:^core.Table(Audio_Source_State),e:core.Entity,state:Audio_Source_State) {
    if held,has:=core.get(states,e);!has {core.add(states,e,state)} else if held!=state {core.edit(states,e)^=state}
}

// The reverb of the mixer goes to that of the volumes where the listeners are
// over about REVERB_FADE: of several, their average, each with its medium.
@(step="late",stage="end",after="camera_view")
audio_reverb :: proc(
    reverbs:^core.Table(Audio_Reverb,.Read),volumes:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),sections:^core.Table(scene.Scene_Reference,.Read),splines:^core.Table(volume.Spline,.Read),listeners:^core.Table(Audio_Listener,.Read),
    view:core.Ref(core.View),settings:core.Ref(Audio_Settings),medium:core.Ref(Audio_Medium),frame:core.Frame_Time,reverb:^Mixer_Reverb,m:^Mixer,id:core.World_Id,
) {
    if m==nil || reverb==nil {return}
    bus:=BUS_MASTER
    if settings.ptr!=nil {bus=settings.reverb_bus}
    positions,count:=listener_positions(worlds,listeners,view)
    changed:=core.touched(reverbs,&reverb.seen[0]) | core.touched(volumes,&reverb.seen[1]) |
        core.touched(parents,&reverb.seen[2]) | core.touched(sections,&reverb.seen[3]) |
        core.touched(splines,&reverb.seen[4])
    changed=volume.poses_changed(worlds,reverbs,sections,&reverb.worlds) || changed
    if !reverb.measured || id!=reverb.world || changed || count!=reverb.count || positions!=reverb.positions {
        for i in 0..<count {
            silent:Audio_Reverb
            room:=volume.at({volumes,worlds,parents,sections,splines},reverbs,positions[i],silent,reverb_mix)
            reverb.rooms[i]=(^Reverb)(&room)^
        }
        reverb.world,reverb.positions,reverb.count,reverb.measured=id,positions,count,true
    }
    sum:[4]f32
    for i in 0..<count {
        heard:=transmute([4]f32)reverb.rooms[i]
        if medium.ptr!=nil {
            if weight:=clamp(medium.listeners[i].weight,0,1);weight>0 {
                heard=heard*(1-weight)+(transmute([4]f32)reverb_clamp(medium.listeners[i].reverb))*weight
            }
        }
        sum+=heard
    }
    target:=transmute(Reverb)(sum/f32(max(count,1)))
    if !bus_ready(m,bus) {bus=BUS_MASTER}
    if reverb.set && reverb.reverb==target && reverb.bus==bus {return}
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
    if mixer.reverb_set(m,now,mixer.Bus(bus)) {reverb.reverb,reverb.bus,reverb.set=now,bus,true}
}

reverb_mix :: proc(value:^Audio_Reverb,by:Audio_Reverb,weight:f32,add:bool) {
    by:=by
    volume.mix_linear((^[4]f32)(value),(^[4]f32)(&by)^,weight,add)
}

// The buses of the mixer as the settings, the snapshot Audio_Mix blends to
// and the medium of the listeners say; only what differs is sent.
@(step="late",stage="end")
audio_buses :: proc(
    settings:core.Ref(Audio_Settings),volumes:core.Ref(Audio_Volumes),medium:core.Ref(Audio_Medium),mix:core.Ref(Audio_Mix),
    worlds:^core.Table(core.World_Transform,.Read),listeners:^core.Table(Audio_Listener,.Read),view:core.Ref(core.View),
    settings_stamp:core.Stamp(Audio_Settings),volume_stamp:core.Stamp(Audio_Volumes),frame:core.Frame_Time,
    applied:^Mixer_Buses,m:^Mixer,id:core.World_Id,problems:^core.Problems,
) {
    if m==nil || applied==nil {return}
    streams_apply(m,settings.ptr,applied,problems)
    changed:=core.touched(settings_stamp,&applied.settings) | core.touched(volume_stamp,&applied.volumes)
    snapshot,seconds:=-1,f32(0)
    if mix.ptr!=nil {
        name:=base.text_get(mix.snapshot[:])
        found:bool
        if snapshot,found=snapshot_index(settings.ptr,name);!found {
            core.report(problems,core.NONE,"audio.snapshot","Audio_Mix names the snapshot \"%s\", which Audio_Settings.snapshots does not have, so the buses play as the settings say; name one of its snapshots, or leave it empty",name)
        }
        seconds=mix.blend_seconds
    }
    blend:=&applied.blend
    blended:=false
    if changed || !blend.set || snapshot!=blend.snapshot || blend.t<1 {blended=mix_blend_step(blend,settings.ptr,snapshot,seconds,frame.dt)}
    _,count:=listener_positions(worlds,listeners,view)
    lowpass:=medium_lowpass(medium.ptr,count)
    if applied.set && applied.world==id && !changed && !blended && applied.count==mixer.bus_count(m) && applied.lowpass==lowpass {return}
    applied.set=buses_apply(m,settings.ptr,volumes.ptr,lowpass,problems,&blend.now)
    applied.world,applied.count,applied.lowpass=id,mixer.bus_count(m),lowpass
}

// Gives the mixer the stream capacity of the settings, and says once per
// frame that had them how many plays of streamed sounds were refused because
// every stream played: the voices of sources and audio.play alike.
@(private)
streams_apply :: proc(m:^Mixer,settings:^Audio_Settings,applied:^Mixer_Buses,problems:^core.Problems) {
    asked:=settings.stream_capacity if settings!=nil else 0
    want:=mixer.STREAM_CAPACITY_DEFAULT if asked==0 else clamp(asked,1,mixer.STREAM_CAPACITY_MAX)
    if asked<0 || asked>mixer.STREAM_CAPACITY_MAX {
        core.report(problems,core.NONE,"audio.stream_capacity","Audio_Settings.stream_capacity %d is out of its range, so the mixer has %d streams; give it 1 to %d, or 0 for %d",asked,want,mixer.STREAM_CAPACITY_MAX,mixer.STREAM_CAPACITY_DEFAULT)
    }
    if want!=applied.streams {
        if mixer.mixer_set_stream_capacity(m,want)!=.None {
            core.report(problems,core.NONE,"audio.memory","the mixer keeps %d streams in place of the %d of Audio_Settings.stream_capacity: out of memory for their rings; free memory or ask for fewer",mixer.mixer_stats(m).stream_capacity,want)
        }
        applied.streams=want
    }
    stats:=mixer.mixer_stats(m)
    if stats.streams_busy>applied.streams_busy {
        core.report(problems,core.NONE,"audio.streams","%d plays of streamed sounds were refused: all %d streams of the mixer played; raise Audio_Settings.stream_capacity (at most %d) or stream fewer sounds at once",stats.streams_busy-applied.streams_busy,stats.stream_capacity,mixer.STREAM_CAPACITY_MAX)
    }
    applied.streams_busy=stats.streams_busy
}

// The cutoff of the master by the medium of count listeners: while every one
// is under a medium, the highest of their cutoffs, which none hears clearer
// than; else 0, and the voices of those under one are dulled one by one
// (medium_bands).
medium_lowpass :: proc "contextless" (medium:^Audio_Medium,count:int) -> f32 {
    if medium==nil || count<1 {return 0}
    highest:=f32(0)
    for i in 0..<min(count,AUDIO_LISTENERS_MAX) {
        cutoff:=medium.listeners[i].lowpass
        if !(cutoff>0) {return 0}
        highest=max(highest,cutoff)
    }
    return highest
}

// What the mixer dulls the voices heard from the listener of slot by, of
// count listeners: the lowpass of its medium as bands while not every
// listener is under one (the master filters them all when they are).
medium_bands :: proc "contextless" (medium:^Audio_Medium,count,slot:int) -> [mixer.BANDS]f32 {
    if medium==nil || slot<0 || slot>=AUDIO_LISTENERS_MAX || medium_lowpass(medium,count)>0 {return {1,1,1}}
    return mixer.lowpass_bands(medium.listeners[slot].lowpass)
}

// Gives the buses of the mixer what the settings say at levels (those of the
// settings when nil), and the master the lowpass of the medium
// (medium_lowpass; 0: none): what audio_buses applies in a game and the
// editor before it plays a sound to be heard or while it previews a snapshot.
buses_apply :: proc(m:^Mixer,settings:^Audio_Settings,volumes:^Audio_Volumes=nil,medium_lowpass:f32=0,problems:^core.Problems=nil,levels:^Mix_Levels=nil) -> bool {
    if m==nil {return false}
    if settings==nil && !(medium_lowpass>0) {return true}
    if settings!=nil {
        for setting in settings.buses {
            if setting=={} {continue}
            _=bus_ready(m,setting.bus)
            if setting.duck_amount>0 {_=bus_ready(m,setting.duck_by)}
        }
    }
    at:=levels^ if levels!=nil else mix_levels(settings,-1)
    ok:=true
    mixer.mixer_batch_begin(m)
    defer mixer.mixer_batch_end(m)
    for index in 0..<min(mixer.bus_count(m),AUDIO_BUS_CAPACITY) {
        bus:=Audio_Bus(index)
        setting:=audio_bus_setting(core.ref(settings),bus)
        level:=at.buses[index]
        if volume:=db_volume(level.gain)*audio_volume(core.ref(volumes),bus);mixer.bus_volume(m,mixer.Bus(bus))!=volume {ok=mixer.bus_set_volume(m,mixer.Bus(bus),volume) && ok}
        filters:=setting.filters
        for &f,band in filters {
            if f.kind!=.Off {f.frequency=level.cutoffs[band]}
            if !mixer.filter_valid(f) {
                core.report(problems,core.NONE,"audio.filter","Audio_Settings: filter %d of bus %d is not one (%v), so it is off; give it a frequency and a q of 0 or more and a gain within %v dB",band,int(bus),f,mixer.FILTER_GAIN_MAX)
                f={}
            }
        }
        if bus==BUS_MASTER {filters=filters_with_medium(filters,medium_lowpass)}
        for f,band in filters {
            if mixer.bus_filter(m,mixer.Bus(bus),band)!=f {ok=mixer.bus_set_filter(m,mixer.Bus(bus),band,f) && ok}
        }
        if delay:=delay_clean(setting.delay);mixer.bus_delay(m,mixer.Bus(bus))!=delay {
            if !mixer.bus_set_delay(m,mixer.Bus(bus),delay) {
                ok=false
                core.report(problems,core.NONE,"audio.delay","Audio_Settings: the delay of bus %d did not start: out of memory for its line; free memory or take it out",int(bus))
            }
        }
        reverb:=reverb_clamp(setting.reverb)
        reverb.wet=max(level.wet,0)
        if mixer.bus_reverb(m,mixer.Bus(bus))!=reverb {ok=mixer.bus_set_reverb(m,mixer.Bus(bus),reverb) && ok}
        if bus==BUS_MASTER {continue}
        send:=setting.send
        if send>=bus {
            if send!=BUS_MASTER {core.report(problems,core.NONE,"audio.send","Audio_Settings: bus %d sends to bus %d, which does not come before it, so it plays into the master; send it to BUS_MASTER or a bus of a lower number",int(bus),int(send))}
            send=BUS_MASTER
        }
        if mixer.bus_send(m,mixer.Bus(bus))!=mixer.Bus(send) {ok=mixer.bus_set_send(m,mixer.Bus(bus),mixer.Bus(send)) && ok}
        duck:mixer.Duck
        if amount:=clamp(setting.duck_amount,0,1);amount>0 && setting.duck_by!=bus && int(setting.duck_by)<mixer.bus_count(m) {
            duck={mixer.Bus(setting.duck_by),max(setting.duck_threshold,0),amount,max(setting.duck_attack,0),max(setting.duck_release,0)}
        }
        if mixer.bus_duck(m,mixer.Bus(bus))!=duck {ok=mixer.bus_set_duck(m,mixer.Bus(bus),duck) && ok}
    }
    return ok
}

// The filters of the master under a medium: its low-pass, the lower of both,
// in the first Lowpass band, else the first band that is Off, else the last.
@(private)
filters_with_medium :: proc "contextless" (filters:[mixer.BUS_FILTERS]mixer.Filter,lowpass:f32) -> [mixer.BUS_FILTERS]mixer.Filter {
    filters:=filters
    if !(lowpass>0) {return filters}
    for &f in filters {
        if f.kind==.Lowpass {f.frequency=lowpass_lower(f.frequency,lowpass);return filters}
    }
    for &f in filters {
        if f.kind==.Off {f={kind=.Lowpass,frequency=lowpass};return filters}
    }
    filters[mixer.BUS_FILTERS-1]={kind=.Lowpass,frequency=lowpass}
    return filters
}

// A delay as the mixer keeps it; one that is not a number is none.
@(private)
delay_clean :: proc "contextless" (d:mixer.Delay) -> mixer.Delay {
    if !(abs(d.seconds)<=max(f32) && abs(d.feedback)<=max(f32) && abs(d.wet)<=max(f32)) {return {}}
    return {clamp(d.seconds,0,mixer.DELAY_SECONDS_MAX),clamp(d.feedback,0,mixer.DELAY_FEEDBACK_MAX),max(d.wet,0)}
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
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    applied.device=device
    applied.set=true
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
    if m!=nil {for &entry in voices.entries.values {sound_voices_stop(m,&entry.sound)}}
    core.entity_map_clear(&voices.entries)
}

// The setting of a bus: its entry, or one that plays it as it comes.
audio_bus_setting :: proc "contextless" (settings:core.Ref(Audio_Settings),bus:Audio_Bus) -> Audio_Bus_Setting {
    if settings.ptr!=nil {
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
audio_volume :: proc "contextless" (volumes:core.Ref(Audio_Volumes),bus:Audio_Bus) -> f32 {
    if volumes.ptr==nil || int(bus)>=AUDIO_BUS_CAPACITY {return 1}
    volume:=(^[AUDIO_BUS_CAPACITY]f32)(volumes.ptr)[int(bus)]
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

// Where the listeners hear from, by slot: the first AUDIO_LISTENERS_MAX
// Audio_Listeners with a world transform, or the View; count 0 without either.
listener_positions :: proc(worlds:^core.Table(core.World_Transform,$A),listeners:^core.Table(Audio_Listener,$B),view:core.Ref(core.View)) -> (positions:[AUDIO_LISTENERS_MAX][3]f32,count:int) {
    hearing:=Hearing{worlds=worlds,listeners=listeners,view=view}
    poses,_:=listener_poses(&hearing)
    for pose,i in poses.slots[:poses.count] {positions[i]=pose.position}
    return positions,poses.count
}

// Where the listeners are: the first AUDIO_LISTENERS_MAX Audio_Listeners with
// a world transform, or the View. cut: the View jumped.
@(private)
listener_poses :: proc(h:^Hearing) -> (poses:Mixer_Listeners,cut:bool) {
    for row in 0..<core.count(h.listeners) {
        world,placed:=core.get(h.worlds,core.entity_at(h.listeners,row))
        if !placed {continue}
        poses.slots[poses.count]={position=world.position,rotation=world.rotation}
        if poses.count+=1;poses.count==AUDIO_LISTENERS_MAX {break}
    }
    if poses.count>0 || h.view.ptr==nil {return}
    poses.slots[0]={position=h.view.position,rotation=h.view.rotation}
    poses.count=1
    return poses,h.view.cut
}

// The mixer hears from where the listeners are, each at the velocity it moved
// at in the frame and dulled by its medium; only what differs is sent.
@(private)
listener_update :: proc(listeners:^Mixer_Listeners,m:^Mixer,h:^Hearing,dt:f32) {
    found,cut:=listener_poses(h)
    if found.count==0 {return}
    if found.count!=listeners.count && !mixer.listeners_set_count(m,found.count) {return}
    for &l,i in found.slots[:found.count] {
        l.medium=medium_bands(h.medium.ptr,found.count,i)
        held:=listeners.slots[i]
        if i<listeners.count && dt>0 && !cut {l.velocity=(l.position-held.position)/dt}
        if i<listeners.count && held==l {continue}
        if !mixer.listener_set(m,l.position,l.rotation,l.velocity,i,l.medium) {l=held}
    }
    listeners^=found
}

// The slot of the listener a spatial source at position is heard from, of
// those of listeners: the nearest, but current while no other is nearer than
// LISTENER_SWITCH of the distance to it. A current of none is the nearest.
listener_pick :: proc "contextless" (listeners:^Mixer_Listeners,position:[3]f32,current:u8) -> u8 {
    if listeners.count<=1 {return 0}
    nearest,best:=0,f32(max(f32))
    for l,i in listeners.slots[:listeners.count] {
        if d:=linalg.length2(l.position-position);d<best {nearest,best=i,d}
    }
    if int(current)>=listeners.count {return u8(nearest)}
    own:=linalg.length2(listeners.slots[current].position-position)
    return u8(nearest) if best<own*LISTENER_SWITCH*LISTENER_SWITCH else current
}

// The distance from position to the nearest listener, or to the origin without one.
listeners_distance :: proc "contextless" (listeners:^Mixer_Listeners,position:[3]f32) -> f32 {
    if listeners.count==0 {return linalg.length(position)}
    best:=f32(max(f32))
    for l in listeners.slots[:listeners.count] {best=min(best,linalg.length2(l.position-position))}
    return math.sqrt(best)
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
    a:=mixer.Attenuation{model=source.attenuation,min_distance=source.min_distance,max_distance=source.max_distance,rolloff=source.rolloff,spread=source.spread,delay=source.delay}
    a.near_radius=source.near_radius>0?source.near_radius:mixer.ATTENUATION_DEFAULT.near_radius
    return a
}

// Why a source cannot play, as how to correct it; "" when it can.
@(private)
source_problem :: proc "contextless" (s:Audio_Source) -> string {
    for x in ([?]f32{s.volume,s.pitch,s.reverb,s.doppler,s.directivity,s.directivity_power,s.rolloff,s.near_radius,s.spread}) {
        if !(x>=0 && x<=max(f32)) {return "volume, pitch, reverb, doppler, directivity, directivity_power, rolloff, near_radius and spread are numbers of 0 or more"}
    }
    for x in s.parameters {
        if !(abs(x)<=max(f32)) {return "the parameters are numbers"}
    }
    if s.spatial && !(s.min_distance>0 && s.max_distance>s.min_distance && s.max_distance<=max(f32)) {
        return "a spatial one is heard from min_distance, above 0, to max_distance, above it"
    }
    return ""
}

// A source as it was written: its voices stop, start again when its kind is
// another, or take its volume, pitch, loop, pan, send and parameters.
@(private)
source_set :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,listeners:^Mixer_Listeners,source:Audio_Source,e:core.Entity,state:^Audio_Source_State,problems:^core.Problems) {
    entry:=core.entity_map_get(&voices.entries,e)
    if !source.playing {
        if entry!=nil {
            sound_voices_stop(m,&entry.sound)
            core.entity_map_remove(&voices.entries,e)
        }
        state^={}
        return
    }
    _,placed:=core.get(h.worlds,e)
    if entry!=nil && voices_sounds_valid(m,&entry.sound) && entry.kind==kind_of(source,placed) && source_problem(source)=="" {
        set:=host.content_sound_set_info(app,source.sound)
        parameters_aim(entry,set,source.parameters)
        entry.shapes=shapes_of(set,&entry.sound,entry.values)
        entry_speed(entry,source,h.now)
        if source.loop {
            for &time,i in entry.times[:entry.sound.count] {
                if time>0 && entry.lengths[i]>0 {time=math.mod(time,f64(entry.lengths[i]))}
            }
        }
        if entry.real {voices_tune(m,&entry.sound,source,&entry.shapes,entry.kind.spatial,true)}
        return
    }
    if entry!=nil {
        sound_voices_stop(m,&entry.sound)
        core.entity_map_remove(&voices.entries,e)
    }
    if state.ended && state.plays==source.plays {return}
    state.ended,state.plays,state.voice=false,source.plays,{}
    source_start(voices,m,app,h,listeners,source,e,problems)
}

// The time of each sound of an entry goes on from now at the pitch its voice
// plays at: of its source, its set, its entry and its shape.
@(private)
entry_speed :: proc "contextless" (entry:^Voice_Entry,source:Audio_Source,now:u64) {
    if now>entry.clock {
        entry.times,entry.clock=entry_times(entry,now),now
    }
    pitch:=(source.pitch>0?source.pitch:1)*entry.sound.pitch
    for i in 0..<clamp(entry.sound.count,0,LAYERS) {
        entry_pitch:=entry.sound.pitches[i] if entry.sound.pitches[i]>0 else 1
        entry.speeds[i]=clamp(pitch*entry_pitch*entry.shapes[i].pitch,mixer.PITCH_MIN,mixer.PITCH_MAX)
    }
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
// voices_assign gives it voices; one whose sound does not load yet waits in
// it for a later frame.
@(private)
source_start :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,listeners:^Mixer_Listeners,source:Audio_Source,e:core.Entity,problems:^core.Problems) {
    if problem:=source_problem(source);problem!="" {
        core.report(problems,e,"audio.source","its Audio_Source plays nothing: %s",problem)
        return
    }
    world,placed:=core.get(h.worlds,e)
    entry:=Voice_Entry{kind=kind_of(source,placed),clock=h.now+VOICE_LEAD,rotation=1,transmission=mixer.TRANSMISSION_DEFAULT}
    pick,picked:=sound_pick(m,app,source,e,problems)
    if !picked && !bus_ready(m,source.bus) {return}
    entry.generation=host.content_sound_generation(app,source.sound)
    entry.sound=voices_of(pick)
    if entry.sound.count>1 {entry.clock=h.now+LAYER_LEAD}
    for sound,i in entry.sound.sounds[:entry.sound.count] {entry.lengths[i]=mixer.sound_seconds(m,sound)}
    entry.times=layers_start(&entry.sound)
    entry.values=parameters_clean(source.parameters)
    entry.targets=entry.values
    entry.shapes=shapes_of(host.content_sound_set_info(app,source.sound),&entry.sound,entry.values)
    entry_speed(&entry,source,h.now)
    if entry.kind.spatial {
        entry.position=world.position
        entry.listener=listener_pick(listeners,world.position,AUDIO_LISTENERS_MAX)
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
// load, starts again; one whose voices ended or one of them was stolen goes
// virtual, and ends when its time passes its longest sound without loop; its
// parameters glide; a spatial one follows its entity and its nearest listener,
// and with voices what hides it from that listener, all of it tested again at
// once when it goes to another.
@(private)
voice_follow :: proc(voices:^Voices,m:^Mixer,app:^host.App,h:^Hearing,listeners:^Mixer_Listeners,source:Audio_Source,e:core.Entity,dt:f32,state:^Audio_Source_State,problems:^core.Problems) {
    entry:=core.entity_map_get(&voices.entries,e)
    world,placed:=core.get(h.worlds,e)
    if !voices_sounds_valid(m,&entry.sound) || entry.generation!=host.content_sound_generation(app,source.sound) || entry.kind.spatial!=(source.spatial && placed) {
        sound_voices_stop(m,&entry.sound)
        core.entity_map_remove(&voices.entries,e)
        state.voice={}
        source_start(voices,m,app,h,listeners,source,e,problems)
        return
    }
    if entry.real {
        // A voice that ended before its sound did was stolen: the others stop
        // too, to start again in step with it.
        stolen,left:=false,0
        for &voice,i in entry.sound.voices[:entry.sound.count] {
            if voice=={} {continue}
            if mixer.voice_valid(m,voice) {left+=1;continue}
            voice={}
            stolen||=source.loop || entry_time(entry,i,h.now)<f64(entry.lengths[i])-LAYER_ENDED
        }
        if stolen {entry_silence(m,entry)} else if left==0 {entry.real=false}
        state.voice=entry.sound.voices[0] if entry.real else {}
    }
    if !entry.real && !source.loop && entry_ended(entry,h.now) {
        core.entity_map_remove(&voices.entries,e)
        state.voice,state.ended={},true
        voices.stats.ended+=1
        return
    }
    if parameters_glide(entry,dt) {
        entry.shapes=shapes_of(host.content_sound_set_info(app,source.sound),&entry.sound,entry.values)
        entry_speed(entry,source,h.now)
        if entry.real {voices_tune(m,&entry.sound,source,&entry.shapes,entry.kind.spatial,false)}
    }
    if !entry.kind.spatial {return}
    rotation:=world.rotation if entry.kind.directivity.weight>0 else 1
    slot:=listener_pick(listeners,world.position,entry.listener)
    switched:=slot!=entry.listener
    entry.listener=slot
    if !entry.real {
        entry.position,entry.rotation,entry.moving=world.position,rotation,false
        return
    }
    mixer.mixer_batch_begin(m)
    defer mixer.mixer_batch_end(m)
    if switched {
        for voice in entry.sound.voices[:entry.sound.count] {
            if voice!={} {mixer.voice_set_listener(m,voice,int(slot))}
        }
    }
    occlusion:=state.occlusion
    if transmission:=hidden(h,listeners.slots[slot].position,e,world,dt,state,switched);state.occlusion!=occlusion || transmission!=entry.transmission {
        for voice in entry.sound.voices[:entry.sound.count] {
            if voice!={} {mixer.voice_set_occlusion(m,voice,state.occlusion,transmission)}
        }
        entry.transmission=transmission
    }
    if entry.position!=world.position || entry.moving || entry.rotation!=rotation {
        velocity:[3]f32
        if entry.kind.doppler>0 && dt>0 {velocity=(world.position-entry.position)/dt}
        for voice in entry.sound.voices[:entry.sound.count] {
            if voice!={} {mixer.voice_set_position(m,voice,world.position,velocity,rotation)}
        }
        entry.position,entry.moving,entry.rotation=world.position,velocity!={},rotation
    }
}

// What plays for the sound of a source: one of a Random set, or every layer
// of a Layered set. False, with the problem of e (NONE: of a request), when
// nothing of it can play.
@(private)
sound_pick :: proc(m:^Mixer,app:^host.App,source:Audio_Source,e:core.Entity,problems:^core.Problems) -> (pick:host.Sound_Pick,ok:bool) {
    who:=e==core.NONE?"audio.play":"its Audio_Source"
    if !bus_heard(m,source.bus,e,problems) {return}
    pick=host.content_sound_pick(app,source.sound)
    if pick.count>0 && mixer.sound_valid(m,pick.sounds[0]) {return pick,true}
    name:[base.ASSET_ID_TEXT]u8
    if source.sound=={} {
        core.report(problems,e,"audio.sound","%s plays nothing: it has no sound; give it a .sound or a .sound_set of the assets",who)
    } else {
        core.report(problems,e,"audio.sound","%s plays nothing: sound %s does not load as a sound (it is missing, damaged, not a .sound or a .sound_set, or a set none of whose sounds load); give it a .sound or a .sound_set of the assets",who,host.assets_name(app.assets,source.sound,&name))
    }
    return
}

// Whether the mixer has the bus of a source; else the problem of e (NONE: of a request).
@(private)
bus_heard :: proc(m:^Mixer,bus:Audio_Bus,e:core.Entity,problems:^core.Problems) -> bool {
    if bus_ready(m,bus) {return true}
    core.report(problems,e,"audio.bus","%s plays nothing: bus %d is not a bus of the mixer, which has %d; give it a bus below that",e==core.NONE?"audio.play":"its Audio_Source",int(bus),AUDIO_BUS_CAPACITY)
    return false
}

// The voice of a source as it is set, with the volume and pitch its set drew:
// at position, facing rotation and as hidden as occlusion says when spatial,
// panned when not.
@(private)
voice_desc :: proc "contextless" (source:Audio_Source,pick:[2]f32,position:[3]f32,rotation:quaternion128,occlusion:f32,transmission:[mixer.BANDS]f32,listener:u8) -> mixer.Voice_Desc {
    desc:=mixer.VOICE_DEFAULT
    desc.bus,desc.volume,desc.pitch,desc.loop=mixer.Bus(source.bus),source.volume*pick[0],(source.pitch>0?source.pitch:1)*pick[1],source.loop
    desc.reverb,desc.priority=source.reverb,source.priority
    if source.spatial {
        desc.spatial,desc.position,desc.rotation,desc.attenuation,desc.doppler=true,position,rotation,attenuation_of(source),source.doppler
        desc.directivity={clamp(source.directivity,0,1),max(source.directivity_power,0)}
        desc.occlusion,desc.transmission,desc.listener=occlusion,transmission,listener
    } else {
        desc.pan=source.pan
    }
    return desc
}

// Starts the voices of a source as it is set, at position when spatial and
// heard from the listener of slot, its parameters as the source holds them:
// what a request of Sound_Requests and what the editor plays to be heard
// start. The layers of a Layered set reach the mixer together, so their
// delays are exact to the sample. None, with the problem of e (NONE: of a
// request), when it does not start.
voice_start :: proc(m:^Mixer,app:^host.App,source:Audio_Source,e:core.Entity,problems:^core.Problems,position:[3]f32={},listener:u8=0) -> Sound_Voices {
    pick,ok:=sound_pick(m,app,source,e,problems)
    if !ok {return {}}
    return voices_picked(m,app,source,pick,e,problems,position,listener)
}

@(private)
voices_picked :: proc(m:^Mixer,app:^host.App,source:Audio_Source,pick:host.Sound_Pick,e:core.Entity,problems:^core.Problems,position:[3]f32,listener:u8) -> (v:Sound_Voices) {
    v=voices_of(pick)
    lengths:[LAYERS]f32
    for sound,i in v.sounds[:v.count] {lengths[i]=mixer.sound_seconds(m,sound)}
    shapes:=shapes_of(host.content_sound_set_info(app,source.sound),&v,parameters_clean(source.parameters))
    times:=layers_start(&v)
    busy:=mixer.mixer_stats(m).streams_busy
    if !voices_play(m,&v,voice_desc(source,{pick.volume,pick.pitch},position,1,0,mixer.TRANSMISSION_DEFAULT,listener),&shapes,&times,&lengths) {
        // A refused stream is said by audio_buses, with the capacity that refused it.
        if mixer.mixer_stats(m).streams_busy==busy {
            core.report(problems,e,"audio.voices","%s did not start: every voice of the mixer plays a sound of the same or a higher priority; play fewer sounds at once, raise its priority, or raise the voices of the mixer",e==core.NONE?"audio.play":"its Audio_Source")
        }
        return {}
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
    by:core.Entity, // what plays it: one sound of it per tick; NONE: one per tick within SOUND_SAME_DISTANCE
}

// Requests: any step pushes with play; audio_requests starts them at the end
// of the tick that asked and at the end of every frame, and keeps room for
// SOUND_REQUESTS of them: what does not fit is dropped and reported.
SOUND_REQUESTS :: 256

@(storage,queue)
Sound_Requests :: struct {using queue:core.Queue(Sound_Request)}

// Plays a .sound, one of a .sound_set or all its layers, once: by its path in
// the assets ("arena/crash.sound") or its id; at a point of the world, or not
// placed; by the entity that makes it (its hit, its shot), which tells it
// apart from the same sound of another in the same tick. What must stop, loop
// or follow a thing is an Audio_Source.
play :: proc{play_path,play_id}

play_id :: proc(sounds:^Sound_Requests,sound:base.Asset_Id,at:Maybe([3]f32)=nil,bus:=BUS_EFFECTS,volume:f32=1,pitch:f32=1,by:=core.NONE) {
    position,placed:=at.?
    core.offer(&sounds.queue,Sound_Request{sound=sound,at=position,placed=placed,bus=bus,volume=volume,pitch=pitch,by=by})
}

// A path that does not fit SOUND_PATH_CAPACITY plays as one the assets do not have.
play_path :: proc(sounds:^Sound_Requests,path:string,at:Maybe([3]f32)=nil,bus:=BUS_EFFECTS,volume:f32=1,pitch:f32=1,by:=core.NONE) {
    position,placed:=at.?
    r:=Sound_Request{at=position,placed=placed,bus=bus,volume=volume,pitch=pitch,by=by}
    if len(path)<SOUND_PATH_CAPACITY {base.text_set(r.path[:],path)}
    core.offer(&sounds.queue,r)
}

SOUNDS_PLAYED_CAPACITY :: 512
SOUND_SAME_DISTANCE :: f32(1) // m: a request of no entity this near one of the same tick and sound is that one

// What became of a sound a request asked for.
One_Shot_Outcome :: enum u8 {
    Played,
    Culled_Distance, // placed beyond where every listener hears it
    Rejected_Mixer,  // the mixer started no voice of it, or has not its bus
    Missing_Asset,   // its path is not of the assets, or it does not load as a sound
    Deduped,         // a tick that ran again asked for what that tick played already
}

// A sound a request asked for: what tells it apart from another and what became of it.
Sound_Played :: struct {
    tick:u64,
    sound:base.Asset_Id, // zero for a path the assets do not have
    by:core.Entity,
    at:[3]f32,
    placed:bool,
    keyed:bool,      // a fixed tick of the game asked for it: a tick that runs again finds it
    outcome:One_Shot_Outcome,
    distance:f32,    // m from a placed one to the nearest listener; 0 when not placed
}

// The sounds the requests of a world asked for lately, newest last, over a
// ring: what a tool reads of the one-shot sounds of a game, and what keeps a
// tick that runs again (a rollback corrects it) from playing one of them
// twice, while it plays what only the corrected tick asks. One per world,
// never copied with it, so a rollback does not take it back.
@(storage,host,by_world)
Sounds_Played :: struct {
    keys:[SOUNDS_PLAYED_CAPACITY]Sound_Played,
    count:u64,
}

// The sounds kept, oldest first: at most SOUNDS_PLAYED_CAPACITY, in two runs of the ring.
sounds_played :: proc "contextless" (played:^Sounds_Played) -> (older,newer:[]Sound_Played) {
    if played.count<=SOUNDS_PLAYED_CAPACITY {return nil,played.keys[:played.count]}
    at:=int(played.count%SOUNDS_PLAYED_CAPACITY)
    return played.keys[at:],played.keys[:at]
}

// Whether a fixed tick asked for this sound already.
@(private)
played_found :: proc "contextless" (played:^Sounds_Played,key:Sound_Played) -> bool {
    for k in played.keys[:min(played.count,SOUNDS_PLAYED_CAPACITY)] {
        if !k.keyed || k.tick!=key.tick || k.sound!=key.sound || k.by!=key.by || k.placed!=key.placed {continue}
        if key.by!=core.NONE || linalg.length2(k.at-key.at)<=SOUND_SAME_DISTANCE*SOUND_SAME_DISTANCE {return true}
    }
    return false
}

@(private)
played_add :: proc "contextless" (played:^Sounds_Played,key:Sound_Played) {
    if played==nil {return}
    played.keys[played.count%SOUNDS_PLAYED_CAPACITY]=key
    played.count+=1
}

// Starts what was asked since the last time, once, and keeps what became of
// each in Sounds_Played. A fixed tick plays a sound of an entity
// (Sound_Request.by), or of none near a place, once: a tick that runs again
// (time.resimulating) asks again what it asked the first time, which is not
// played twice, and what only the corrected tick asks (the server says a shot
// hit) plays then. No copy of the world holds a request it played, since
// copies are made between ticks.
@(step="fixed late",stage="end",loops="game editor")
audio_requests :: proc(sounds:^Sound_Requests,time:core.Time,frame:core.Frame_Time,played:^Sounds_Played,listeners:^Mixer_Listeners,app:^host.App,problems:^core.Problems) {
    requests:=core.take(&sounds.queue)
    // After the requests are read: making room may move them.
    defer core.queue_serve(&sounds.queue,SOUND_REQUESTS,problems,"audio.requests","sound requests","audio.SOUND_REQUESTS")
    if app.mixer==nil {return}
    // The ticks of the game; those of the editor loop do not advance.
    keyed:=played!=nil && frame.phase==.Fixed && time.playing
    // The clock went back, as a save loads: the ticks kept are of another run.
    if keyed && !time.resimulating && played.count>0 && played.keys[(played.count-1)%SOUNDS_PLAYED_CAPACITY].tick>time.tick {played.count=0}
    for &r in requests {
        if !(r.volume>=0 && r.volume<=max(f32) && r.pitch>=0 && r.pitch<=max(f32) && abs(r.at.x)<=max(f32) && abs(r.at.y)<=max(f32) && abs(r.at.z)<=max(f32)) {
            core.report(problems,core.NONE,"audio.request","audio.play was refused: volume %v, pitch %v, at %v; give it a volume and a pitch of 0 or more and a place of finite numbers",r.volume,r.pitch,r.at)
            continue
        }
        key:=Sound_Played{tick=time.tick,sound=r.sound,by=r.by,at=r.at,placed=r.placed}
        if r.placed && listeners!=nil && listeners.count>0 {key.distance=listeners_distance(listeners,r.at)}
        source:=AUDIO_SOURCE_DEFAULT
        source.sound,source.bus,source.volume,source.pitch,source.spatial=r.sound,r.bus,r.volume,r.pitch,r.placed
        if r.sound=={} {
            path:=base.text_get(r.path[:])
            if source.sound,_=host.assets_id(app.assets,path);source.sound=={} {
                core.report(problems,core.NONE,"audio.sound","audio.play plays nothing: \"%s\" is not a path of the assets; give it the path of a .sound or a .sound_set under the assets folder, shorter than SOUND_PATH_CAPACITY",path)
                key.outcome=.Missing_Asset
                played_add(played,key)
                continue
            }
            key.sound=source.sound
        }
        key.keyed=keyed
        if keyed && played_found(played,key) {
            key.outcome=.Deduped
            played_add(played,key)
            continue
        }
        key.outcome=request_play(app,source,r,listeners,problems)
        played_add(played,key)
    }
}

// Plays a request with the sound of source; what became of it.
@(private)
request_play :: proc(app:^host.App,source:Audio_Source,r:Sound_Request,listeners:^Mixer_Listeners,problems:^core.Problems) -> One_Shot_Outcome {
    source:=source
    pick,picked:=sound_pick(app.mixer,app,source,core.NONE,problems)
    if !picked {return .Missing_Asset if bus_ready(app.mixer,source.bus) else .Rejected_Mixer}
    hearing:=pick.hearing
    source.attenuation,source.min_distance,source.max_distance=Attenuation_Model(hearing.attenuation),hearing.min_distance,hearing.max_distance
    source.rolloff,source.reverb,source.priority=hearing.rolloff,hearing.reverb,hearing.priority
    // Placed beyond where every listener hears it, it does not start; it is heard from the nearest.
    slot:=u8(0)
    if r.placed && listeners!=nil && listeners.count>0 {
        if !(listeners_distance(listeners,r.at)<hearing.max_distance) {return .Culled_Distance}
        slot=listener_pick(listeners,r.at,AUDIO_LISTENERS_MAX)
    }
    v:=voices_picked(app.mixer,app,source,pick,core.NONE,problems,r.at,slot)
    return .Played if v.count>0 else .Rejected_Mixer
}
