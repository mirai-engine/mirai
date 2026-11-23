package anim

import "base:intrinsics"
import "core:math"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

Timeline_Command :: enum u8 {Seek,Play,Pause,Resume,Stop}

Clip_Selection :: struct {
    clip,next_clip:u64,
    asset:base.Asset_Id `mirai:"kind=.anim"`,
    fade:f32,
    weight:f32,
    loop:bool,
}

Animation_Command :: struct {
    entity:core.Entity,
    command:Timeline_Command,
    time,speed:Maybe(f32),
    clip,layer,next_clip:u64,
    asset:base.Asset_Id,
    fade:f32,
    weight:f32,
    loop:Maybe(bool),
    restart,additive,pending,handled:bool,
}

// Controls the current clip. Play can select a clip and restart it; Resume preserves its time.
// Seek skips markers before the destination. Stop rewinds the base or releases an overlay.
animation_command :: proc(requests:^Animation_Requests,entity:core.Entity,command:Timeline_Command,
    time:Maybe(f32)=nil,speed:Maybe(f32)=nil,restart:bool=true,clip:string="",fade:f32=-1,
    loop:Maybe(bool)=nil,layer:string="",additive:bool=false,weight:f32=1,asset:base.Asset_Id={},
    next_clip:string="") {
    if requests==nil {return}
    if entity==core.NONE || command>max(Timeline_Command) ||
        len(clip)>=CLIP_CAPACITY || len(layer)>=CLIP_CAPACITY || len(next_clip)>=CLIP_CAPACITY ||
        time!=nil && (!finite(time.?) || time.?<0) || speed!=nil && !finite(speed.?) ||
        !finite(fade) || fade< -1 || !profile_weight(weight) ||
        clip=="" && (asset!={} || next_clip!="" || additive) ||
        clip!="" && command!=.Play || next_clip!="" && (loop.? or_else false) {
        core.refuse(&requests.timeline)
        return
    }
    hash :: proc "contextless" (name:string) -> u64 {return base.name_hash(name) if name!="" else 0}
    core.offer(&requests.timeline,{entity=entity,command=command,time=time,speed=speed,
        clip=hash(clip),layer=hash(layer),next_clip=hash(next_clip),asset=asset,fade=fade,
        weight=weight,loop=loop,restart=restart,additive=additive})
}

// Plays a clip of the entity's library or an explicit .anim. On a .character, its clip plays
// over the base. A named layer keeps its mask. The next clip starts after a natural end.
play_clip :: proc(requests:^Animation_Requests,entity:core.Entity,clip:string,
    fade:f32=-1,loop:Maybe(bool)=nil,speed:f32=1,restart:bool=false,layer:string="",
    additive:bool=false,weight:f32=1,asset:base.Asset_Id={},next_clip:string="",at:Maybe(f32)=nil) {
    animation_command(requests,entity,.Play,at,speed,restart,clip,fade,loop,layer,additive,
        weight,asset,next_clip)
}

// Whether the clip of an entity plays in this tick. False for an entity that plays nothing.
animation_playing :: proc(playback:core.Ref(Playback),entity:core.Entity) -> bool {
    state:=constraint_playing(playback,entity)
    return state!=nil && state.seen==playback.frame && state.playing
}

// The rate and loop policy of the base clip, including changes requested in Play.
animation_clip_clock :: proc(playback:core.Ref(Playback),entity:core.Entity) -> (speed:f32,loop:bool) {
    state:=constraint_playing(playback,entity)
    if state!=nil {return state.speed,state.selection.loop}
    return
}

// The source and name of the clip sampled by the base clock.
animation_clip_identity :: proc(playback:core.Ref(Playback),sources:core.Ref(Source_Assets),app:^host.App,
    entity:core.Entity) -> (id:base.Asset_Id,name:[asset.ANIMATION_NAME_CAPACITY]u8,ok:bool) {
    state:=constraint_playing(playback,entity)
    if state==nil || state.clip<0 {return}
    content:=animation_playing_content(sources,app,state)
    clip:=lib.Clip(state.clip+1)
    if content==nil || !lib.clip_valid(&content.lib,clip) {return}
    return source_clip_source(sources,state,clip),source_clip_label(content,clip),true
}

// The markers of the clip an entity plays, in time order, which content.markers names by their
// id; none while it plays no clip.
animation_markers :: proc(playback:core.Ref(Playback),sources:core.Ref(Source_Assets),app:^host.App,entity:core.Entity) -> (markers:[]lib.Marker,content:^host.Content_Animation) {
    state:=constraint_playing(playback,entity)
    if state==nil || state.clip<0 {return}
    content=animation_playing_content(sources,app,state)
    if content==nil || state.clip>=content.clip_count {return nil,nil}
    return lib.clip_markers(&content.lib,lib.Clip(state.clip+1)),content
}

// The entity the clip of an animated entity calls target as its tracks bind it: itself for 0, none
// when nothing it animates has that name.
animation_bound :: proc(playback:core.Ref(Playback),entity:core.Entity,target:u64) -> core.Entity {
    state:=constraint_playing(playback,entity)
    return field_entity(state,target) if state!=nil else core.NONE
}

Clip_Overlay :: struct {
    selection:Clip_Selection,
    slot:u8, // 1 + slot in the stack
    speed,weight:f32,
    playing,additive,finished:bool,
    event:Animation_Event,
}

Clip_Edit :: struct {seek:f32,overlay_seek:f32,restart,overlay_restart,stop:bool}

@(private)
clip_handle :: proc "contextless" (content:^host.Content_Animation,selection:Clip_Selection) -> lib.Clip {
    if content==nil {return 0}
    if selection.clip==0 {return 1 if content.clip_count>0 else 0}
    return lib.clip_find(&content.lib,source_clip_name(content.id,selection.asset,selection.clip))
}

@(private)
clip_control :: proc(state:^Playing,animation:^Animation,commands:[]Animation_Command,
    running:bool,app:^host.App,sources:^Source_Assets,characters:^Character_Assets,
    actions:^Action_Runtime,problems:^core.Problems,kept:Maybe(Animation_Progress)=nil) -> (edit:Clip_Edit) {
    edit.seek,edit.overlay_seek=-1,-1
    if !running || !state.started {
        state.playing,state.speed=animation.playing,animation.speed
        name:=base.text_get(animation.clip[:])
        state.selection={clip=base.name_hash(name) if name!="" else 0,
            fade=animation.fade,loop=animation.loop,weight=1}
        if saved,ok:=kept.?;ok {
            state.playing,state.speed=saved.playing,saved.speed
            state.selection=saved.selection
            state.restore_time=saved.time
        }
    }
    if at,restoring:=state.restore_time.?;restoring {edit.seek=at}
    state.started=running
    if running && state.ended && state.selection.next_clip!=0 {
        state.selection.clip,state.selection.next_clip=state.selection.next_clip,0
        edit.restart=true
    }
    if state.overlay_next.slot>0 {
        previous:=state.overlay.event
        state.overlay=state.overlay_next
        state.overlay.event=previous
        state.overlay_next={}
        edit.overlay_restart=true
    }
    if state.overlay.finished && state.overlay.selection.next_clip!=0 {
        state.overlay.selection.clip,state.overlay.selection.next_clip=state.overlay.selection.next_clip,0
        state.overlay.finished,state.overlay.playing=false,true
        edit.overlay_restart=true
    }
    pending:=false
    sampled_asset:=state.selection.asset
    for &asked in commands {
        if asked.entity!=state.entity {continue}
        if pending {asked.pending=true;continue}
        if !running && asked.command!=.Seek {asked.handled=true;continue}
        matching:=false
        if asked.clip!=0 {
            id:=animation_character(app.assets,animation^)
            if character:=character_content(characters,app.assets,app.allocator,id);character!=nil {
                matching=len(character.set.match.clips)>0
            }
        }
        overlay:=asked.layer!=0 || asked.clip!=0 && (asked.additive || matching) ||
            asked.clip==0 && state.overlay.slot>0 && running
        slot:=0
        if asked.layer!=0 {
            slot=-1
            if plan:=action_plan(actions,state.entity);plan!=nil {
                for name,i in plan.layer_names {if name==asked.layer {slot=i+1;break}}
            }
        }
        selection:=state.overlay.selection if overlay else state.selection
        playing,speed:=state.playing,state.speed
        if overlay {playing,speed=state.overlay.playing,state.overlay.speed}
        if asked.command==.Play && asked.clip!=0 {
            selection.clip,selection.asset,selection.next_clip=asked.clip,asked.asset,asked.next_clip
            if !overlay {selection.weight=asked.weight}
            if overlay && int(state.overlay.slot)!=slot+1 {selection.fade,selection.loop=animation.fade,false}
        }
        if fade:=asked.fade;fade>=0 {selection.fade=fade}
        if loop,given:=asked.loop.?;given {
            selection.loop=loop
        } else if asked.next_clip!=0 {
            selection.loop=false
        }
        fading:=state.fading_asset
        if !overlay && selection.asset!=sampled_asset {fading=sampled_asset if selection.fade>0 else {}}
        extras:=[3]base.Asset_Id{state.selection.asset,state.overlay.selection.asset,fading}
        extras[1 if overlay else 0]=selection.asset
        prior:=state.source_plan
        content,error:=animation_content(sources,app,state,animation^,characters,extras)
        if error==.Pending {asked.pending=true;pending=true;continue}
        if slot<0 {
            core.report(problems,state.entity,"animation.clip_layer",
                "this clip request names a layer the character does not have; name a layer of its set")
            asked.handled=true
            continue
        }
        if asked.clip!=0 && selection.asset=={} && clip_handle(content,selection)==0 &&
            animation_character(app.assets,animation^)!={} {
            selection.asset=source_find_clip(sources,state.source_plan,content,asked.clip)
        }
        if error!=.None || asked.clip!=0 && (clip_handle(content,selection)==0 ||
            selection.next_clip!=0 && clip_handle(content,{clip=selection.next_clip,asset=selection.asset})==0) {
            state.source_plan=prior
            core.report(problems,state.entity,"animation.clip_command",
                "the clip request cannot find its source or clip; name an .anim when several sources share the name")
            asked.handled=true
            continue
        }
        if overlay && asked.clip!=0 {
            active:=action_state(actions,state.entity)
            if active!=nil && active.slots[slot].active && !active.slots[slot].finishing {
                state.source_plan=prior
                core.report(problems,state.entity,"animation.clip_layer_busy",
                    "the clip cannot take a layer with an active action; wait for the action to end")
                asked.handled=true
                continue
            }
        }
        if overlay && asked.clip==0 && state.overlay.slot==0 {asked.handled=true;continue}
        if overlay && asked.layer!=0 && asked.clip==0 && int(state.overlay.slot)!=slot+1 {
            asked.handled=true
            continue
        }
        asked.handled=true
        seek:=f32(-1)
        restart:=false
        if value,given:=asked.speed.?;given {speed=value}
        switch asked.command {
        case .Play:
            playing=true
            restart=asked.restart
            if at,given:=asked.time.?;given {seek=at}
        case .Resume: playing=true
        case .Pause: playing=false
        case .Stop: playing=false;seek=0
        case .Seek: seek=asked.time.? or_else 0
        }
        if overlay {
            o:=&state.overlay
            if asked.clip!=0 {
                restart ||= o.slot!=u8(slot+1) || o.selection.clip!=selection.clip ||
                    o.selection.asset!=selection.asset
                o.slot,o.additive,o.weight=u8(slot+1),asked.additive,asked.weight
                o.finished=false
            }
            o.selection=selection
            o.playing,o.speed=playing,speed
            o.finished ||= asked.command==.Stop
            if asked.command==.Stop {o.selection.next_clip=0}
            if seek>=0 || restart {edit.overlay_seek=seek}
            edit.overlay_restart ||= restart
        } else {
            state.selection=selection
            state.fading_asset=fading
            state.playing,state.speed=playing,speed
            if asked.command==.Stop {state.selection.next_clip=0;edit.stop=true}
            if seek>=0 || restart {edit.seek=seek}
            edit.restart ||= restart
        }
    }
    animation.playing,animation.speed=state.playing,state.speed
    animation.fade,animation.loop=state.selection.fade,state.selection.loop
    animation.weight*=state.selection.weight
    return
}

@(private)
clip_commands_finish :: proc(commands:^core.Queue(Animation_Command),running:bool,
    problems:^core.Problems) {
    kept:=0
    for asked in commands.items {
        if asked.handled {continue}
        if asked.pending {
            commands.items[kept]=asked;commands.items[kept].pending=false;kept+=1
        } else if running && asked.command!=.Seek {
            core.report(problems,asked.entity,"animation.command",
                "this clip request needs an entity with Animation and Transform")
        }
    }
    base.truncate(&commands.items,kept)
}

@(private)
clip_lifecycle :: proc(playback:^Playback,events:^Animation_Events,event:^Animation_Event,
    kind:Animation_Event_Kind,time:f32,problems:^core.Problems) {
    event.kind,event.time=kind,time
    if !event_push(playback,events,event^) {
        core.report(problems,event.entity,"animation.events_lost",
            "a clip's %v event did not fit in Animation_Events",kind)
    }
    if kind==.Ended || kind==.Interrupted {event^={}}
}

@(private)
clip_overlay_sample :: proc(state:^Playing,content:^host.Content_Animation,animation:Animation,
    edit:Clip_Edit,actions:^Action_Runtime,playback:^Playback,events:^Animation_Events,
    dt:f32,problems:^core.Problems) {
    overlay:=&state.overlay
    stack:=state.stack
    if overlay.slot==0 || stack==nil {return}
    i:=int(overlay.slot)-1
    layer:=&stack.layers[i]
    selection:=overlay.selection
    active:=action_state(actions,state.entity)
    occupied:=active!=nil && active.slots[i].active && !active.slots[i].finishing
    clip:=clip_handle(content,selection)
    if overlay.finished || occupied || clip==0 {
        if overlay.event.clip!=0 {clip_lifecycle(playback,events,&overlay.event,.Interrupted,
            overlay.event.time,problems)}
        if !occupied {stack_blend(stack,i,selection.fade);layer^={}}
        overlay.slot,overlay.playing,overlay.finished=0,false,false
        return
    }
    library:=&content.lib
    handle:=clip+lib.Clip(content.clip_count if selection.loop else 0)
    name:=lib.clip_data(library,clip).name
    if layer.clip!=name || edit.overlay_restart || layer.player.clip==0 {
        if selection.fade<=0 || layer.clip!=0 {stack_blend(stack,i,selection.fade)}
        if overlay.event.clip!=0 {clip_lifecycle(playback,events,&overlay.event,.Interrupted,
            overlay.event.time,problems)}
        layer.player=lib.player_make(handle,overlay.speed)
        lib.player_restart(library,&layer.player)
    }
    layer.clip,layer.space,layer.leaf_count=name,0,0
    weight_step:=dt/selection.fade if selection.fade>0 else 1
    layer.weight+=clamp(overlay.weight-layer.weight,-weight_step,weight_step)
    if stack.blend.slots&(u16(1)<<u16(i))!=0 {layer.weight=overlay.weight}
    layer.player.clip,layer.player.speed=handle,overlay.speed
    layer.root_motion,layer.body,layer.body_vertical=.None,.None,false
    if edit.overlay_seek>=0 {
        layer.player.time=clamp(edit.overlay_seek,0,lib.clip_duration(library,handle))
        layer.player.done,layer.player.fresh=false,false
    }
    layer.from=layer.player.time
    asked:=&stack.asked[i]
    asked.clip,asked.space,asked.weight,asked.sync=name,0,overlay.weight,false
    if overlay.additive {asked.mode=.Additive}
    if !overlay.playing {return}
    if layer.player.done {
        duration:=lib.clip_duration(library,handle)
        reverses:=overlay.speed>0 && layer.player.time<=0 ||
            overlay.speed<0 && layer.player.time>=duration
        if !reverses && !selection.loop {overlay.finished=true;return}
        layer.player.done=false
    }
    if overlay.event.clip==0 {
        overlay.event={entity=state.entity,clip=selection.clip,weight=layer.weight,
            animation=selection.asset if selection.asset!={} else content.id}
        clip_lifecycle(playback,events,&overlay.event,.Started,layer.from,problems)
    }
    batch:[EVENT_BATCH]lib.Event
    written,dropped:=lib.player_advance(library,&layer.player,dt,batch[:])
    emit_events(playback,events,state.entity,content,batch[:written],dropped,problems,
        layer.weight*animation.weight,u32(handle),u16(i+1),animation)
    overlay.event.time=layer.player.time
    if layer.player.done {
        clip_lifecycle(playback,events,&overlay.event,.Ended,layer.player.time,problems)
        overlay.finished=true
    }
}

Field_Kind :: enum u8 {Float,Bool,Signed,Unsigned,Bit}

// A field of a component that a curve of the clip of an entity writes.
Field_Bound :: struct {
    player:core.Entity, // the animated entity whose clip has the curve
    entity:core.Entity, // the one the field is of
    curve:u64,
    property:lib.Property,
    slot:u8,
    kind:Field_Kind,
    size:u8,   // bytes of one number
    count:u8,  // numbers written: those of a vector or a color
    bit:u8,    // Bit: the member of the bit set
    table:^core.Table_Info,
    offset:u32,
    row:i32,   // where the curve was among those of the player in the last tick (curve_find)
}

// What the "@field" tracks of the playing clips write: derived from Playback, made again when
// what plays or what it is bound to changes.
@(storage,free="field_playback_free")
Field_Playback :: struct {
    fields:[dynamic]Field_Bound,
    stamp:u64,
    info:^core.World_Info,
}

field_playback_free :: proc(fields:^Field_Playback) {delete(fields.fields);fields^={}}

@(private)
fields_stamp :: proc "contextless" (playback:core.Ref(Playback)) -> u64 {
    stamp:=base.hash_combine(playback.binding_revision,u64(len(playback.states)))
    for &state in playback.states {
        stamp=base.hash_combine(stamp,u64(state.entity))
        stamp=base.hash_combine(stamp,state.asset[0]~state.asset[1])
        stamp=base.hash_combine(stamp,u64(state.generation)<<32|u64(state.source_plan))
        stamp=base.hash_combine(stamp,state.bound)
    }
    return stamp|1
}

// The entity a field track of a state names: the animated one for no path, else what it bound by that name.
@(private)
field_entity :: proc "contextless" (state:^Playing,node:u64) -> core.Entity {
    if node==0 {return state.entity}
    for binding in state.bindings {if binding.target==node && binding.entity!=core.NONE {return binding.entity}}
    return core.NONE
}

Field_Problem :: enum u8 {None,Component,Path,Type}

// Where the field a "@field" track names is in a row of its component, and how a number of the
// track goes in: what makes it unwritable otherwise. The editor reads with it what a key takes.
field_resolve :: proc(world:core.World_Ref,schema:^serial.Schema,component,path:string,property:lib.Property) -> (bound:Field_Bound,problem:Field_Problem,error:serial.Path_Error) {
    _,table:=core.world_table_named(world,component)
    if table==nil {return bound,.Component,.None}
    type,added:=serial.schema_add_type_info(schema,table.info)
    target:serial.Path_Target
    target,error,_=serial.path_resolve(schema,type,path)
    if !added || error!=.None {return bound,.Path,error}
    bound={property=property,table=table,offset=u32(target.offset),count=1}
    part:=schema.types[target.type]
    valid:=!target.text
    if target.bit>=0 {
        bound.kind,bound.bit,bound.size=.Bit,u8(target.bit&7),1
        bound.offset+=u32(target.bit>>3)
    } else {
        if part.kind==.Array && part.count>=2 && part.count<=4 {
            bound.count=u8(part.count)
            part=schema.types[part.elem]
            valid&&=part.kind==.Float
        }
        // An enum or a bit set is an integer with names: a curve does not write it whole.
        valid&&=part.named==.None
        #partial switch part.kind {
        case .Float: bound.kind=.Float;valid&&=part.size==4 || part.size==8
        case .Bool: bound.kind=.Bool;valid&&=part.size==1
        case .Int: bound.kind=.Signed;valid&&=part.size<=8
        case .Uint: bound.kind=.Unsigned;valid&&=part.size<=8
        case: valid=false
        }
        bound.size=u8(min(part.size,8))
    }
    valid&&=(bound.count==1)==(property==.Float)
    return bound,.None if valid else .Type,.None
}

// Finds the component and the field each "@field" curve of what plays writes. What cannot be
// written is a problem of the animated entity and is left out.
@(private)
fields_bind :: proc(fields:^Field_Playback,world:core.World_Ref,playback:core.Ref(Playback),sources:core.Ref(Source_Assets),app:^host.App,problems:^core.Problems) -> bool {
    clear(&fields.fields)
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    for &state in playback.states {
        content:=animation_playing_content(sources,app,&state)
        if content==nil {continue}
        for &field in content.fields {
            component,path:=base.text_get(field.component[:]),base.text_get(field.field[:])
            e:=field_entity(&state,field.node)
            if e==core.NONE {
                core.report(problems,state.entity,"animation.field_target","a track of its clip writes %s.%s of an entity this one does not animate: none below it has the name of the track, and none names it in Animation_Target.animation; name the entity as the track does, or give it an Animation_Target with this entity and that name",component,path)
                continue
            }
            bound,problem,error:=field_resolve(world,&schema,component,path,field.property)
            switch problem {
            case .None:
            case .Component:
                core.report(problems,state.entity,"animation.field_component","a track of its clip writes %s.%s, and the game has no component %s; name a component of the game in the target of the track, as @field/Point_Light.intensity",component,path,component)
                continue
            case .Path:
                core.report(problems,state.entity,"animation.field_path","a track of its clip writes %s.%s, which is not a field of %s (%v); name one of its fields, with a dot for a field inside another and [n] for an element",component,path,component,error)
                continue
            case .Type:
                core.report(problems,state.entity,"animation.field_type","a track of its clip writes %s.%s, which a %v track cannot write; a Float track writes a number, a flag or a member of a bit set, and a Vector track a vector or a color of 2 to 4 numbers",component,path,field.property)
                continue
            }
            bound.player,bound.entity,bound.curve,bound.slot=state.entity,e,field.curve,field.slot
            if append(&fields.fields,bound)!=1 {return false}
        }
    }
    return true
}

// The value a field holds as its track would key it: what field_write writes, read back.
field_read :: proc "contextless" (bound:Field_Bound,data:[^]u8) -> (value:mm.Vec4) {
    for i in 0..<int(bound.count) {
        at:=data[int(bound.offset)+i*int(bound.size):]
        switch bound.kind {
        case .Float: value[i]=intrinsics.unaligned_load((^f32)(at)) if bound.size==4 else f32(intrinsics.unaligned_load((^f64)(at)))
        case .Bool: value[i]=1 if at[0]!=0 else 0
        case .Bit: value[i]=1 if at[0]&(u8(1)<<bound.bit)!=0 else 0
        case .Signed,.Unsigned:
            number:u64
            intrinsics.mem_copy_non_overlapping(&number,at,int(bound.size))
            shift:=64-uint(bound.size)*8
            value[i]=f32(i64(number<<shift)>>shift) if bound.kind==.Signed else f32(number)
        }
    }
    return
}

@(private)
field_write :: proc "contextless" (bound:Field_Bound,data:[^]u8,value:mm.Vec4) -> (changed:bool) {
    for i in 0..<int(bound.count) {
        x:=value[i]
        if !finite(x) {continue}
        at:=data[int(bound.offset)+i*int(bound.size):]
        switch bound.kind {
        case .Float:
            if bound.size==4 {
                if intrinsics.unaligned_load((^f32)(at))!=x {intrinsics.unaligned_store((^f32)(at),x);changed=true}
            } else if intrinsics.unaligned_load((^f64)(at))!=f64(x) {intrinsics.unaligned_store((^f64)(at),f64(x));changed=true}
        case .Bool:
            on:=u8(x>=0.5)
            if at[0]!=on {at[0]=on;changed=true}
        case .Bit:
            mask:=u8(1)<<bound.bit
            now:=at[0]|mask if x>=0.5 else at[0]&~mask
            if at[0]!=now {at[0]=now;changed=true}
        case .Signed,.Unsigned:
            bits:=uint(bound.size)*8
            low,high:=f64(0),math.pow(2,f64(bits))-1
            if bound.kind==.Signed {low,high=-math.pow(2,f64(bits-1)),math.pow(2,f64(bits-1))-1}
            rounded:=clamp(math.round(f64(x)),low,high)
            number:=u64(i64(rounded)) if bound.kind==.Signed else u64(rounded)
            now:u64
            intrinsics.mem_copy_non_overlapping(&now,at,int(bound.size))
            if bits<64 {number&=(u64(1)<<bits)-1}
            if now!=number {intrinsics.mem_copy_non_overlapping(at,&number,int(bound.size));changed=true}
        }
    }
    return
}

// Writes the fields the "@field" curves of the playing clips drive, on the ticks their clip moves.
@(step="fixed",loops="game editor",stage="simulate",after="animation_sample")
animation_fields :: proc(world:core.World_Ref,playback:core.Ref(Playback),fields:^Field_Playback,sources:core.Ref(Source_Assets),app:^host.App,problems:^core.Problems) {
    if app==nil || app.assets==nil || playback.ptr==nil {return}
    if stamp:=fields_stamp(playback);stamp!=fields.stamp || fields.info!=world.info {
        if !fields_bind(fields,world,playback,sources,app,problems) {
            clear(&fields.fields);fields.stamp=0
            memory_problem(problems,core.NONE,"the fields the clips write, so none is written in this tick")
            return
        }
        fields.stamp,fields.info=stamp,world.info
    }
    state:^Playing
    for &bound in fields.fields {
        if state==nil || state.entity!=bound.player {state=constraint_playing(playback,bound.player)}
        if state==nil || state.seen!=playback.frame || state.held {continue}
        curve:=curve_find(playing_curves(state),{target=bound.curve,property=bound.property,slot=bound.slot},&bound.row)
        if curve==nil || curve.weight<=0 {continue}
        table:=core.world_table_at(world,bound.table)
        row:=core.raw_row(table,bound.entity)
        if row<0 {continue}
        if field_write(bound,([^]u8)(core.raw_value(table,bound.table.info,row)),curve.value/curve.weight) {core.raw_touch(table,bound.entity)}
    }
}
