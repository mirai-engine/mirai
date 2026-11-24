package audio

import "core:math"
import "mirai:asset"
import "mirai:core"
import mixer "mirai:audio"
import "mirai:std/base"

// Snapshots: named moments of the mix in Audio_Settings (underwater, a pause
// menu, a cutscene), each saying, for some buses, what their gain, the
// frequencies of their filters and the wet of their reverb become. The game
// names the one it wants in Audio_Mix and audio_buses blends the buses from
// where they are to it over blend_seconds; an empty name goes back to the
// settings as they are.

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

// The snapshot the buses go to and in how long: what the game writes
// (snapshot_blend); empty, the settings as they are.
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

// The levels of the buses on their way from where they were to a snapshot.
Mix_Blend :: struct {
    from,now:Mix_Levels,
    snapshot:int, // index in Audio_Settings.snapshots; -1: none
    t:f32,        // 0 where it started to 1 there
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

// The levels of the buses as the settings say, under a snapshot (-1: none).
mix_levels :: proc(settings:^Audio_Settings,snapshot:int) -> (levels:Mix_Levels) {
    for &l,index in levels.buses {
        bus:=Audio_Bus(index)
        setting:=audio_bus_setting(core.ref(settings),bus)
        l.gain,l.wet=setting.gain,max(setting.reverb.wet,0)
        for f,band in setting.filters {l.cutoffs[band]=f.frequency}
        if settings==nil || snapshot<0 || snapshot>=AUDIO_SNAPSHOT_CAPACITY {continue}
        for change in settings.snapshots[snapshot].buses {
            if change=={} || change.bus!=bus {continue}
            l.gain+=change.gain
            for cutoff,band in change.cutoffs {
                if cutoff>0 {l.cutoffs[band]=cutoff}
            }
            l.wet*=db_volume(change.reverb)
            break
        }
    }
    return
}

// Levels t of the way from one to the other: gains in dB and wets linearly,
// cutoffs by octaves.
mix_levels_blend :: proc "contextless" (from,to:Mix_Levels,t:f32) -> (levels:Mix_Levels) {
    t:=clamp(t,0,1)
    for &l,i in levels.buses {
        a,b:=from.buses[i],to.buses[i]
        l.gain=a.gain+(b.gain-a.gain)*t
        l.wet=a.wet+(b.wet-a.wet)*t
        for &cutoff,band in l.cutoffs {
            x,y:=a.cutoffs[band],b.cutoffs[band]
            switch {
            case t<=0:cutoff=x
            case t>=1:cutoff=y
            case x>0 || y>0:
                from_hz:=x if x>0 else asset.SOUND_LOWPASS_MAX
                to_hz:=y if y>0 else asset.SOUND_LOWPASS_MAX
                cutoff=from_hz*math.pow(to_hz/from_hz,t)
            case:cutoff=0
            }
        }
    }
    return
}

// Goes on blending toward a snapshot (-1: the settings) over seconds, after
// dt more seconds; another snapshot starts from where the buses are. True
// when the levels changed.
mix_blend_step :: proc(b:^Mix_Blend,settings:^Audio_Settings,snapshot:int,seconds,dt:f32) -> bool {
    to:=mix_levels(settings,snapshot)
    if !b.set {
        b^={from=to,now=to,snapshot=snapshot,t=1,set=true}
        return true
    }
    if snapshot!=b.snapshot {
        b.from,b.snapshot,b.t=b.now,snapshot,0
        b.seconds=seconds if seconds>=0 && seconds<=max(f32) else 0
    }
    if b.t<1 {b.t=min(b.t+max(dt,0)/b.seconds,1) if b.seconds>0 else 1}
    now:=mix_levels_blend(b.from,to,b.t)
    changed:=now!=b.now
    b.now=now
    return changed
}
