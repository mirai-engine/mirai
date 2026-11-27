package audio

import "core:math"
import "mirai:asset"
import "mirai:core"
import mixer "mirai:audio"
import "mirai:std/base"

// Snapshots: named states of the mix in Audio_Settings (a pause menu, a
// cutscene, under water), each saying, for some buses, what their gain, the
// frequencies of their filters and the wet of their reverb become. Two things
// name them and their weights add up, as rooms do for the reverb: the game, in
// Audio_Mix, the one it wants whole, which audio_buses blends to over
// blend_seconds (an empty name goes back to the settings); and the medium of
// the listeners (Medium.snapshot: the water's "underwater"), by its weight and
// the share of the listeners under it, blended over REVERB_FADE. Code never
// names a snapshot for what the engine knows of where the listeners are.

AUDIO_SNAPSHOT_CAPACITY :: 4
AUDIO_SNAPSHOT_NAME :: 24

// What a snapshot changes of a bus; an entry of zeros changes nothing.
Audio_Snapshot_Bus :: struct {
    bus:Audio_Bus,
    gain:f32 `mirai:"min=-80,max=24,unit=dB"`,      // added to the gain of the bus
    cutoffs:[mixer.BUS_FILTERS]f32 `mirai:"min=0,unit=Hz"`, // frequency of each of its filters; 0: as the settings say
    reverb:f32 `mirai:"min=-80,max=24,unit=dB"`,    // added to the wet of its reverb; AUDIO_SILENCE_DB or below takes it out
}

Audio_Snapshot :: struct {
    name:[AUDIO_SNAPSHOT_NAME]u8 `mirai:"text"`, // empty: unused
    buses:[AUDIO_BUS_CAPACITY]Audio_Snapshot_Bus `mirai:"trim"`,
}

// The snapshot of its own the game wants the buses at and in how long: what
// the game writes (snapshot_blend); empty, none.
@(storage)
Audio_Mix :: struct {
    snapshot:[AUDIO_SNAPSHOT_NAME]u8 `mirai:"text"`,
    blend_seconds:f32 `mirai:"min=0,unit=s"`,
}

// The levels of a bus a snapshot blends: its gain in dB, the frequency of
// each of its filters in Hz and the wet of its reverb.
Bus_Levels :: struct {
    gain:f32,
    cutoffs:[mixer.BUS_FILTERS]f32,
    wet:f32,
}
Mix_Levels :: struct {buses:[AUDIO_BUS_CAPACITY]Bus_Levels}

// The weight of each snapshot of the settings, by its index: 0 to 1.
Mix_Weights :: [AUDIO_SNAPSHOT_CAPACITY]f32

// The levels of the buses on their way from where they were to the snapshots.
Mix_Blend :: struct {
    from,now:Mix_Levels,
    snapshot:int,       // of the game: index in Audio_Settings.snapshots; -1: none
    medium:Mix_Weights, // of the medium of the listeners (medium_snapshots)
    t:f32,              // 0 where it started to 1 there
    seconds:f32,
    set:bool,
}

// Blends the buses to the snapshot of that name over seconds; "" goes back
// to the settings. False for a name longer than AUDIO_SNAPSHOT_NAME or seconds
// that are not a number of 0 or more.
snapshot_blend :: proc(mix:^Audio_Mix,name:string,seconds:f32) -> bool {
    if mix==nil || len(name)>=AUDIO_SNAPSHOT_NAME || !(seconds>=0 && seconds<=max(f32)) {return false}
    base.text_set(mix.snapshot[:],name)
    mix.blend_seconds=seconds
    return true
}

// The index of the snapshot of a name in the settings: -1 for "", false when
// they have none of it.
snapshot_index :: proc(settings:^Audio_Settings,name:string) -> (index:int,found:bool) {
    if name=="" {return -1,true}
    if settings==nil {return -1,false}
    for &snapshot,i in settings.snapshots {
        if base.text_get(snapshot.name[:])==name {return i,true}
    }
    return -1,false
}

// The levels of the buses as the settings say under the snapshot of the game
// (-1: none), whole, and those of the medium by their weights, in the order of
// the settings: gains and reverbs in dB by the weight, cutoffs that far by
// octaves. A snapshot both name counts whole, once.
mix_levels :: proc(settings:^Audio_Settings,snapshot:int,medium:Mix_Weights={}) -> (levels:Mix_Levels) {
    for &l,index in levels.buses {
        setting:=audio_bus_setting(core.ref(settings),Audio_Bus(index))
        l.gain,l.wet=setting.gain,max(setting.reverb.wet,0)
        for f,band in setting.filters {l.cutoffs[band]=f.frequency}
    }
    if settings==nil {return}
    weights:=medium
    if snapshot>=0 && snapshot<AUDIO_SNAPSHOT_CAPACITY {weights[snapshot]=1}
    for weight,i in weights {
        if !(weight>0) {continue}
        w:=min(weight,1)
        for &l,index in levels.buses {
            for change in settings.snapshots[i].buses {
                if change=={} || int(change.bus)!=index {continue}
                l.gain+=change.gain*w
                for cutoff,band in change.cutoffs {
                    if cutoff>0 {l.cutoffs[band]=cutoff_blend(l.cutoffs[band],cutoff,w)}
                }
                l.wet*=db_volume(change.reverb*w)
                break
            }
        }
    }
    return
}

// The weight of each snapshot the media of count listeners name: the weight
// of each medium over the share of the listeners it holds. A name the
// settings do not have weighs nothing: the medium still filters and rings.
medium_snapshots :: proc(settings:^Audio_Settings,medium:^Audio_Medium,count:int) -> (weights:Mix_Weights) {
    if settings==nil || medium==nil || count<1 {return}
    listeners:=min(count,AUDIO_LISTENERS_MAX)
    for &l in medium.listeners[:listeners] {
        name:=base.text_get(l.snapshot[:])
        if name=="" || !(l.weight>0) {continue}
        if index,found:=snapshot_index(settings,name);found && index>=0 {weights[index]+=min(l.weight,1)/f32(listeners)}
    }
    return
}

// A cutoff t of the way from x to y by octaves, 0 being none (SOUND_LOWPASS_MAX).
@(private)
cutoff_blend :: proc "contextless" (x,y,t:f32) -> f32 {
    switch {
    case t<=0:return x
    case t>=1:return y
    case x>0 || y>0:
        from_hz:=x if x>0 else asset.SOUND_LOWPASS_MAX
        to_hz:=y if y>0 else asset.SOUND_LOWPASS_MAX
        return from_hz*math.pow(to_hz/from_hz,t)
    }
    return 0
}

// Levels t of the way from one to the other: gains in dB and wets linearly,
// cutoffs by octaves.
mix_levels_blend :: proc "contextless" (from,to:Mix_Levels,t:f32) -> (levels:Mix_Levels) {
    t:=clamp(t,0,1)
    for &l,i in levels.buses {
        a,b:=from.buses[i],to.buses[i]
        l.gain=a.gain+(b.gain-a.gain)*t
        l.wet=a.wet+(b.wet-a.wet)*t
        for &cutoff,band in l.cutoffs {cutoff=cutoff_blend(a.cutoffs[band],b.cutoffs[band],t)}
    }
    return
}

// Goes on blending toward the snapshot of the game (-1: none) and those of
// the medium (mix_levels), after dt more seconds; another snapshot of the
// game starts from where the buses are over seconds, other weights of the
// medium over REVERB_FADE. True when the levels changed.
mix_blend_step :: proc(b:^Mix_Blend,settings:^Audio_Settings,snapshot:int,seconds,dt:f32,medium:Mix_Weights={}) -> bool {
    to:=mix_levels(settings,snapshot,medium)
    if !b.set {
        b^={from=to,now=to,snapshot=snapshot,medium=medium,t=1,set=true}
        return true
    }
    if snapshot!=b.snapshot {
        b.from=b.now
        b.t=0
        b.seconds=seconds if seconds>=0 && seconds<=max(f32) else 0
    } else if medium!=b.medium {
        b.from=b.now
        b.t,b.seconds=0,REVERB_FADE
    }
    b.snapshot,b.medium=snapshot,medium
    if b.t<1 {b.t=min(b.t+max(dt,0)/b.seconds,1) if b.seconds>0 else 1}
    now:=mix_levels_blend(b.from,to,b.t)
    changed:=now!=b.now
    b.now=now
    return changed
}
