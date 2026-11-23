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
// Seek skips markers before the destination. Stop rewinds the base or releases the clip of a slot.
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

// A clip a command plays in a slot of the stack, over the base: the layer of the slot keeps its
// branches, curves and reference, the clip gives what it plays and its mode. seek and restart are
// what the commands asked since the slot last played; it takes them as it plays (layers_advance).
Slot_Clip :: struct {
    selection:Clip_Selection, // weight: that of its layer
    speed:f32,
    seek:Maybe(f32),
    playing,additive,restart,active,finished:bool,
    waits:bool, // an action of its slot that ended in this tick chained it: it starts in the next
    event:Animation_Event,
}

Clip_Edit :: struct {seek:f32,restart,stop:bool}

@(private)
clip_handle :: proc "contextless" (content:^host.Content_Animation,selection:Clip_Selection) -> lib.Clip {
    if content==nil {return 0}
    if selection.clip==0 {return 1 if content.clip_count>0 else 0}
    return lib.clip_find(&content.lib,source_clip_name(content.id,selection.asset,selection.clip))
}

// The .anim a state plays besides its Animation: that of its base clip, those of the clips of
// its stack by slot, and the one its base fades from.
playing_extras :: proc "contextless" (state:^Playing) -> (extras:Source_Extras) {
    extras[0],extras[SOURCE_EXTRAS-1]=state.selection.asset,state.fading_asset
    if state.stack!=nil {for &c,i in state.stack.clips {if c.active {extras[1+i]=c.selection.asset}}}
    return
}

// The fade and the loop a command gives a clip.
@(private)
clip_settings :: proc "contextless" (asked:Animation_Command,selection:^Clip_Selection) {
    if fade:=asked.fade;fade>=0 {selection.fade=fade}
    if loop,given:=asked.loop.?;given {
        selection.loop=loop
    } else if asked.next_clip!=0 {
        selection.loop=false
    }
}

// What a command does to the clock of a clip: seek is where it puts it, -1 nowhere.
@(private)
clip_command_apply :: proc "contextless" (asked:Animation_Command,selection:^Clip_Selection,
    playing:^bool,speed:^f32) -> (seek:f32,restart:bool) {
    seek=-1
    if value,given:=asked.speed.?;given {speed^=value}
    switch asked.command {
    case .Play:
        playing^=true
        restart=asked.restart
        if at,given:=asked.time.?;given {seek=at}
    case .Resume: playing^=true
    case .Pause: playing^=false
    case .Stop: playing^=false;seek=0;selection.next_clip=0
    case .Seek: seek=asked.time.? or_else 0
    }
    return
}

// Applies the commands of an entity to its base clip and to the clips of the slots of its stack.
// A command that names a layer, or plays an additive clip or one over the locomotion of its
// .character, is for a slot; one without clip or layer controls the clips its stack plays, else
// the base.
@(private)
clip_control :: proc(state:^Playing,animation:^Animation,commands:[]Animation_Command,
    running:bool,app:^host.App,sources:^Source_Assets,characters:^Character_Assets,
    actions:^Action_Runtime,problems:^core.Problems,kept:Maybe(Animation_Progress)=nil) -> (edit:Clip_Edit) {
    edit.seek=-1
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
        // The slot it plays a clip in or controls; -1: the base; -2: a layer the set lacks.
        slot:=-1
        if asked.layer!=0 {
            slot=-2
            if plan:=action_plan(actions,state.entity);plan!=nil {
                for name,i in plan.layer_names {if name==asked.layer {slot=i+1;break}}
            }
        } else if asked.clip!=0 && (asked.additive || matching) {slot=0}
        playing_clips,targets:u16
        if state.stack!=nil {
            for &c,i in state.stack.clips {if c.active {playing_clips|=u16(1)<<u16(i)}}
        }
        if slot>=0 {
            targets=u16(1)<<u16(slot)
        } else if slot==-1 && asked.clip==0 && running {targets=playing_clips}
        slotted:=slot!=-1 || targets!=0
        current:Slot_Clip
        if state.stack!=nil && targets!=0 {
            current=state.stack.clips[slot if slot>=0 else int(intrinsics.count_trailing_zeros(targets))]
        }
        selection:=current.selection if slotted else state.selection
        if asked.command==.Play && asked.clip!=0 {
            selection.clip,selection.asset,selection.next_clip=asked.clip,asked.asset,asked.next_clip
            selection.weight=asked.weight
            if slotted && !current.active {selection.fade,selection.loop=animation.fade,false}
        }
        clip_settings(asked,&selection)
        fading:=state.fading_asset
        if !slotted && selection.asset!=sampled_asset {fading=sampled_asset if selection.fade>0 else {}}
        extras:=playing_extras(state)
        if !slotted {
            extras[0],extras[SOURCE_EXTRAS-1]=selection.asset,fading
        } else if slot>=0 {extras[1+slot]=selection.asset}
        prior:=state.source_plan
        content,error:=animation_content(sources,app,state,animation^,characters,extras)
        if error==.Pending {asked.pending=true;pending=true;continue}
        if slot==-2 {
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
        if slot>=0 && asked.clip!=0 {
            active:=action_state(actions,state.entity)
            if active!=nil && active.slots[slot].active && !active.slots[slot].finishing {
                state.source_plan=prior
                core.report(problems,state.entity,"animation.clip_layer_busy",
                    "the clip cannot take a layer with an active action; wait for the action to end")
                asked.handled=true
                continue
            }
        }
        asked.handled=true
        // A layer named without a clip controls the clip of its slot, which plays none.
        if slotted && asked.clip==0 && targets&playing_clips==0 {continue}
        if !slotted {
            playing,speed:=state.playing,state.speed
            seek,restart:=clip_command_apply(asked,&selection,&playing,&speed)
            state.selection=selection
            state.fading_asset=fading
            state.playing,state.speed=playing,speed
            if asked.command==.Stop {edit.stop=true}
            if seek>=0 || restart {edit.seek=seek}
            edit.restart ||= restart
            continue
        }
        stack:=stack_make(state)
        if stack==nil {memory_problem(problems,state.entity,"the clips of its stack");continue}
        for &c,i in stack.clips {
            if targets&(u16(1)<<u16(i))==0 {continue}
            chosen:=selection if asked.clip!=0 else c.selection
            clip_settings(asked,&chosen)
            playing,speed:=c.playing,c.speed
            seek,restart:=clip_command_apply(asked,&chosen,&playing,&speed)
            if asked.clip!=0 {
                restart ||= !c.active || c.selection.clip!=chosen.clip || c.selection.asset!=chosen.asset
                c.additive,c.active,c.finished,c.waits=asked.additive,true,false,false
            }
            c.selection,c.playing,c.speed=chosen,playing,speed
            c.finished ||= asked.command==.Stop
            if seek>=0 {c.seek=seek} else if restart {c.seek=nil}
            c.restart ||= restart
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

// Ends the clips of the stack of state, telling those that started they were interrupted;
// release frees their slots.
@(private)
clips_interrupt :: proc(playback:^Playback,events:^Animation_Events,state:^Playing,
    problems:^core.Problems,release:bool) {
    if state.stack==nil {return}
    for &c in state.stack.clips {
        if c.event.clip!=0 {clip_lifecycle(playback,events,&c.event,.Interrupted,c.event.time,problems)}
        if release {c={}}
    }
}

// Plays the clip of slot i of the stack of state in the layer of the slot, over what that asks by
// itself: false when it plays none in this tick. A clip that stopped, ended or lost its clip
// leaves the layer; one that ends with a next clip chains it.
@(private)
clip_slot_advance :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,
    animation:Animation,events:^Animation_Events,dt:f32,problems:^core.Problems,i:int) -> bool {
    stack:=state.stack
    c:=&stack.clips[i]
    if !c.active {return false}
    if c.waits {c.waits=false;return false}
    layer:=&stack.layers[i]
    clip:=clip_handle(content,c.selection)
    if c.finished || clip==0 {
        if c.event.clip!=0 {clip_lifecycle(playback,events,&c.event,.Interrupted,c.event.time,problems)}
        stack_blend(stack,i,c.selection.fade)
        layer^={}
        c^={}
        return false
    }
    ended :: proc "contextless" (c:^Slot_Clip) {
        if c.selection.next_clip==0 {c.finished=true;return}
        c.selection.clip,c.selection.next_clip,c.restart=c.selection.next_clip,0,true
    }
    library:=&content.lib
    selection:=c.selection
    handle:=clip+lib.Clip(content.clip_count if selection.loop else 0)
    name:=lib.clip_data(library,clip).name
    if layer.clip!=name || c.restart || layer.player.clip==0 {
        if selection.fade<=0 || layer.clip!=0 {stack_blend(stack,i,selection.fade)}
        if c.event.clip!=0 {clip_lifecycle(playback,events,&c.event,.Interrupted,c.event.time,problems)}
        layer.player=lib.player_make(handle,c.speed)
        lib.player_restart(library,&layer.player)
    }
    c.restart=false
    layer.clip,layer.space,layer.leaf_count=name,0,0
    weight_step:=dt/selection.fade if selection.fade>0 else 1
    layer.weight+=clamp(selection.weight-layer.weight,-weight_step,weight_step)
    if stack.blend.slots&(u16(1)<<u16(i))!=0 {layer.weight=selection.weight}
    layer.player.clip,layer.player.speed=handle,c.speed
    layer.root_motion,layer.body,layer.body_vertical=.None,.None,false
    if seek,sought:=c.seek.?;sought {
        layer.player.time=clamp(seek,0,lib.clip_duration(library,handle))
        layer.player.done,layer.player.fresh=false,false
    }
    c.seek=nil
    layer.from=layer.player.time
    asked:=&stack.asked[i]
    asked.clip,asked.space,asked.weight,asked.sync=name,0,selection.weight,false
    if c.additive {asked.mode=.Additive}
    if !c.playing {return true}
    if layer.player.done {
        duration:=lib.clip_duration(library,handle)
        reverses:=c.speed>0 && layer.player.time<=0 || c.speed<0 && layer.player.time>=duration
        if !reverses && !selection.loop {ended(c);return true}
        layer.player.done=false
    }
    if c.event.clip==0 {
        c.event={entity=state.entity,clip=selection.clip,weight=layer.weight,group=u16(i+1),
            animation=selection.asset if selection.asset!={} else content.id}
        clip_lifecycle(playback,events,&c.event,.Started,layer.from,problems)
    }
    batch:[EVENT_BATCH]lib.Event
    written,dropped:=lib.player_advance(library,&layer.player,dt,batch[:])
    emit_events(playback,events,state.entity,content,batch[:written],dropped,problems,
        layer.weight*animation.weight,u32(handle),u16(i+1),animation)
    c.event.time=layer.player.time
    if layer.player.done {
        clip_lifecycle(playback,events,&c.event,.Ended,layer.player.time,problems)
        ended(c)
    }
    return true
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
            // A look the render phase gives the meshes of the rig (animation_skin).
            if component==MATERIAL_LIVE {continue}
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
        curve:=curve_find(state.curves[:],{target=bound.curve,property=bound.property,slot=bound.slot},&bound.row)
        if curve==nil || curve.weight<=0 {continue}
        table:=core.world_table_at(world,bound.table)
        row:=core.raw_row(table,bound.entity)
        if row<0 {continue}
        if field_write(bound,([^]u8)(core.raw_value(table,bound.table.info,row)),curve.value/curve.weight) {core.raw_touch(table,bound.entity)}
    }
}
