package editor

import "core:fmt"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:editor/api"
import eaudio "mirai:engine/audio"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// What the editor plays to be heard, out of every world: a .sound or a
// .sound_set from the content browser or audio.play, one at a time, on the
// master bus. And the methods of sound: audio.status, audio.play,
// audio.stop, and sound sets by code (sound_set.inspect, create and set).

// Whether the editor plays this asset to be heard now.
sound_heard :: proc(s:^Session,id:base.Asset_Id) -> bool {
    return s.heard_sound.sound==id && eaudio.playing(s.app.mixer,s.heard)
}

// Plays an asset to be heard, at its own volume and pitch on the master bus,
// in place of what played; false when it does not play.
sound_hear :: proc(s:^Session,id:base.Asset_Id,volume:f32=1,pitch:f32=1) -> bool {
    return sound_hear_source(s,{sound=id,bus=eaudio.BUS_MASTER,volume=volume,pitch=pitch})
}

// Plays the sound of a source as it is set (eaudio.play_source), with the
// buses as the settings of the project say.
sound_hear_source :: proc(s:^Session,source:eaudio.Audio_Source) -> bool {
    sound_hear_stop(s)
    content_used(s,source.sound)
    eaudio.buses_apply(s.app.mixer,core.world_storage_of(edited_world(s),eaudio.Audio_Settings),core.world_storage_of(edited_world(s),eaudio.Audio_Volumes))
    s.heard=eaudio.play_source(s.app,{},source)
    if s.heard=={} {return false}
    s.heard_sound=source
    return true
}

// What plays to be heard takes the values of its source as they change.
sound_hear_tune :: proc(s:^Session,source:eaudio.Audio_Source) {
    if !sound_heard(s,source.sound) || s.heard_sound==source {return}
    if source.bus!=s.heard_sound.bus {
        sound_hear_source(s,source)
        return
    }
    eaudio.source_tune(s.app.mixer,s.heard,source)
    s.heard_sound=source
}

sound_hear_stop :: proc(s:^Session) {
    if s.heard!={} {eaudio.stop(s.app.mixer,s.heard)}
    s.heard,s.heard_sound={},{}
}

@(private)
Api_Audio_Bus :: struct {
    bus:[NAME_CAPACITY]u8 `mirai:"text"`,
    volume:f32,
    muted:bool,
    lowpass:f32 `mirai:"label=Cutoff in Hz; 0: none"`,
    duck_by:[NAME_CAPACITY]u8 `mirai:"text"`,
    duck_amount:f32,
    reverb_wet:f32 `mirai:"label=Of the reverb of the bus; 0: none"`,
}

@(private)
Api_Audio_Status :: struct {
    mixer:bool `mirai:"label=The editor has a mixer; without one nothing plays"`,
    voices_active,sounds:int,
    sound_bytes:int `mirai:"label=Memory the sounds hold: decoded samples, encoded bytes and the decoders of streams"`,
    voices_played,voices_stolen,voices_rejected,commands_dropped,underruns,streams_busy,feeds_busy:u64,
    buses:[eaudio.AUDIO_BUS_CAPACITY]Api_Audio_Bus `mirai:"trim"`,
    heard:[API_PATH_BYTES]u8 `mirai:"text,label=The asset audio.play or the content browser plays while it plays"`,
}

@(private)
Api_Audio_Play_Params :: struct {
    sound:[API_PATH_BYTES]u8 `mirai:"text,label=A .sound or a .sound_set: its path under the assets folder (with or without its extension) or its id"`,
    volume:f32 `mirai:"optional,min=0,label=Linear gain"`,
    pitch:f32 `mirai:"optional,min=0,label=Rate of playback"`,
}

@(private)
Api_Audio_Play_Result :: struct {
    sound:[API_PATH_BYTES]u8 `mirai:"text"`,
    seconds:f32 `mirai:"label=Of the sound that plays; a set chose one of its sounds"`,
}

@(private)
Api_Audio_Stop_Result :: struct {
    stopped:bool `mirai:"label=Something played"`,
}

@(private)
Api_Sound_Set_Result :: struct {
    sound_set:base.Asset_Id,
    path:string `mirai:"optional,label=Under the assets folder"`,
    values:asset.Sound_Set_Info `mirai:"label=Its sounds by id with their weights; the ranges of volume and pitch it draws from and whether it repeats a sound; as sound_set.set takes them"`,
    sounds:[]string `mirai:"label=The path of each of its sounds; empty for one the assets do not have"`,
}

Api_Sound_Set_Params :: struct {
    sound_set:string `mirai:"optional,label=A sound set: its path under the assets folder, or its id"`,
    path:string `mirai:"optional,label=sound_set.set: in place of sound_set, a new sound set at this path under the assets folder, made over the defaults; it fails when that file exists"`,
    values:serial.Json `mirai:"optional,label=Fields of the sound set to change, as sound_set.inspect shows them; sounds holds .sound paths or ids, as asset.list gives them"`,
}

@(private)
audio_api_register :: proc(s:^Session,st:^Api_State) {
    play:=Api_Audio_Play_Params{volume=1,pitch=1}
    api_register(s,st,{name="audio.status",summary="The mixer of the editor with its counters and its buses, and what audio.play plays.",result=Api_Audio_Status,flags={.Read_Only},run=api_audio_status})
    api_register(s,st,{name="audio.play",params=Api_Audio_Play_Params,defaults=&play,result=Api_Audio_Play_Result,summary="Plays a .sound, or one sound of a .sound_set with its ranges, to be heard in the editor out of every world in place of what played, as Play sound of the content browser does.",run=api_audio_play})
    api_register(s,st,{name="audio.stop",result=Api_Audio_Stop_Result,summary="Stops what audio.play or the content browser plays.",flags={.Idempotent},run=api_audio_stop})
    api_register(s,st,{name="sound_set.inspect",params=Api_Sound_Set_Params,summary="The values of a sound set (.sound_set) and the paths of its sounds.",result=Api_Sound_Set_Result,flags={.Read_Only},run=api_sound_set_inspect})
    api_register(s,st,{name="sound_set.set",params=Api_Sound_Set_Params,summary="Changes the sounds, weights and ranges of a sound set (.sound_set) for every source and call that plays it, or makes a new one at path over the defaults.",result=Api_Sound_Set_Result,run=api_sound_set_set})
}

@(private)
api_audio_status :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Audio_Status)
    m:=s.app.mixer
    if m==nil {return}
    stats:=mixer.mixer_stats(m)
    r.mixer=true
    r.voices_active,r.sounds,r.sound_bytes=stats.voices_active,stats.sounds,stats.sound_bytes
    r.voices_played,r.voices_stolen,r.voices_rejected=stats.voices_played,stats.voices_stolen,stats.voices_rejected
    r.commands_dropped,r.underruns,r.streams_busy,r.feeds_busy=stats.commands_dropped,stats.underruns,stats.streams_busy,stats.feeds_busy
    name :: proc(s:^Session,bus:mixer.Bus,out:[]u8) {
        if named,found:=core.name_of(s.info,eaudio.Audio_Bus,i64(bus));found {base.text_set(out,named)} else {base.text_set(out,fmt.tprintf("%d",int(bus)))}
    }
    for index in 0..<min(mixer.bus_count(m),len(r.buses)) {
        bus:=mixer.Bus(index)
        entry:=&r.buses[index]
        name(s,bus,entry.bus[:])
        entry.volume,entry.muted,entry.lowpass=mixer.bus_volume(m,bus),mixer.bus_muted(m,bus),mixer.bus_lowpass(m,bus)
        entry.reverb_wet=mixer.bus_reverb(m,bus).wet
        if duck:=mixer.bus_duck(m,bus);duck.amount>0 {
            name(s,duck.source,entry.duck_by[:])
            entry.duck_amount=duck.amount
        }
    }
    if sound_heard(s,s.heard_sound.sound) {base.text_set(r.heard[:],asset_path(s,s.heard_sound.sound))}
}

// A .sound or a .sound_set the params name: its path under the assets
// folder, with or without its extension, or its id.
@(private)
sound_named :: proc(s:^Session,call:^api.Call,name:string) -> (id:base.Asset_Id,ok:bool) {
    a:=s.app.assets
    if a==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no assets")
        return
    }
    host.assets_scan(a)
    playable :: proc(kind:asset.Fourcc) -> bool {return kind==asset.KIND_SOUND || kind==asset.KIND_SOUND_SET}
    if parsed,is_id:=serial.text_parse_asset_id(name);is_id {
        if file,found:=asset.registry_find(&a.registry,parsed);found && playable(file.kind) {return parsed,true}
    }
    for candidate in ([3]string{name,fmt.tprintf("%s.sound",name),fmt.tprintf("%s.sound_set",name)}) {
        if file,found:=asset.registry_find_path(&a.registry,candidate);found && playable(file.kind) {return file.id,true}
    }
    api.call_failf(call,api.INVALID_PARAMS,"%q is not a .sound or a .sound_set of the assets: asset.list with kind Sound or Sound_Set lists them",name)
    return
}

@(private)
api_audio_play :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Audio_Play_Params)
    if s.app.mixer==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no mixer: it runs without a window or its audio device did not open")
        return
    }
    id,found:=sound_named(s,call,base.text_get(p.sound[:]))
    if !found {return}
    if !sound_hear(s,id,p.volume,p.pitch) {
        api.call_fail(call,api.SERVER_ERROR,"It did not play: the sound does not load (sound_set.inspect shows the sounds of a set), or every voice of the mixer plays something; audio.status shows them")
        return
    }
    r:=api.call_result(call,Api_Audio_Play_Result)
    base.text_set(r.sound[:],asset_path(s,id))
    r.seconds=sound_seconds_of(s,id)
}

// The length of a .sound, or of the longest sound of a set.
@(private)
sound_seconds_of :: proc(s:^Session,id:base.Asset_Id) -> f32 {
    m:=s.app.mixer
    if info,ok:=sound_set_file(s,id);ok {
        longest:=f32(0)
        for variation in info.sounds {
            if variation.sound!={} {longest=max(longest,mixer.sound_seconds(m,host.content_sound(s.app,variation.sound)))}
        }
        return longest
    }
    return mixer.sound_seconds(m,host.content_sound(s.app,id))
}

@(private)
api_audio_stop :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Audio_Stop_Result)
    r.stopped=sound_heard(s,s.heard_sound.sound)
    sound_hear_stop(s)
}

// ---------------------------------------------------------------- sound sets

// The values a set has in its file, as it is now: unsaved in memory, or on disk.
sound_set_file :: proc(s:^Session,id:base.Asset_Id) -> (info:asset.Sound_Set_Info,ok:bool) {
    a:=s.app.assets
    if a==nil {return}
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.kind!=asset.KIND_SOUND_SET {return}
    file:asset.Asset
    if !asset_read(s,record.path,&file) {return}
    defer asset.asset_close(&file)
    view,error:=asset.sound_set_view(&file,&a.types)
    if error!=.None {return}
    return view.info^,true
}

// Why the values of a set cannot be written, as how to correct them; "" when they can.
sound_set_refusal :: proc(s:^Session,info:asset.Sound_Set_Info) -> string {
    if field,message:=asset.sound_set_problem(info);message!="" {return fmt.tprintf("values.%s: %s",field,message)}
    a:=s.app.assets
    for variation,i in info.sounds {
        if variation.sound=={} {continue}
        if file,found:=asset.registry_find(&a.registry,variation.sound);!found || file.kind!=asset.KIND_SOUND {
            text:[base.ASSET_ID_TEXT]u8
            return fmt.tprintf("values.sounds[%d].sound %s is not a .sound of the assets: asset.list with kind Sound lists them",i,host.assets_name(a,variation.sound,&text))
        }
    }
    return ""
}

// Writes the file of a set at its path as an edit, in the open gesture or in a step named label.
sound_set_publish :: proc(s:^Session,id:base.Asset_Id,path:string,info:asset.Sound_Set_Info,label:string) -> string {
    a:=s.app.assets
    if a==nil {return "The editor has no assets"}
    if refusal:=sound_set_refusal(s,info);refusal!="" {return refusal}
    bytes,error:=asset.sound_set_bytes(&a.types,{id=id,info=info},context.temp_allocator)
    if error!=.None || !file_write(s,path,bytes,label) {return "The sound set could not be written"}
    return ""
}

// Writes the values of a set of the project into its file, as an edit; what
// it refuses is told in a toast.
sound_set_write :: proc(s:^Session,id:base.Asset_Id,info:asset.Sound_Set_Info) -> bool {
    a:=s.app.assets
    if a==nil || id=={} {return false}
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return false}
    if problem:=sound_set_publish(s,id,asset.registry_file_path(&a.registry,record.path,context.temp_allocator),info,"Sound set");problem!="" {
        notify(s,problem)
        return false
    }
    return true
}

@(private)
api_sound_set_write :: proc(s:^Session,call:^api.Call,id:base.Asset_Id) {
    info,read:=sound_set_file(s,id)
    if !read {
        api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,id,"sound set"))
        return
    }
    r:=api.call_result(call,Api_Sound_Set_Result)
    r.sound_set,r.path,r.values=id,asset_path(s,id),info
    sounds:=make([dynamic]string,call.allocator)
    for variation in info.sounds {
        if variation.sound!={} {append(&sounds,asset_path(s,variation.sound))}
    }
    r.sounds=sounds[:]
}

@(private)
api_sound_set_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Sound_Set_Params)
    id,found:=asset_named(s,call,p.sound_set,asset.KIND_SOUND_SET,".sound_set","a sound set")
    if !found {return}
    api_sound_set_write(s,call,id)
}

@(private)
api_sound_set_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Sound_Set_Params)
    t,found:=asset_target(s,call,p.sound_set,p.path,"sound_set",asset.KIND_SOUND_SET,".sound_set","a sound set")
    if !found {return}
    info:=asset.SOUND_SET_DEFAULTS
    if !t.created {
        loaded:bool
        if info,loaded=sound_set_file(s,t.id);!loaded {
            api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,t.id,"sound set"))
            return
        }
    }
    if !asset_values_read(call,string(p.values),&info) {return}
    if refusal:=sound_set_refusal(s,info);refusal!="" {
        api.call_fail(call,api.INVALID_PARAMS,refusal)
        return
    }
    label:=t.created?"Create sound set":"Sound set"
    if !api_edit_begin(s,call,label) {return}
    problem:=sound_set_publish(s,t.id,t.file,info,label)
    if problem!="" {api.call_fail(call,api.SERVER_ERROR,problem)}
    if !api_edit_end(s,call,problem=="") {return}
    if t.created {host.assets_scan(s.app.assets)}
    api_sound_set_write(s,call,t.id)
}
