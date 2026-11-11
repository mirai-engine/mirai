package anim

import "base:intrinsics"
import "core:math"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A timeline is the clip of an Animation: the keys of std/anim on tracks that
// move the transforms of entities and the fields of their components. A door,
// a lift, the cameras and actors of a cinematic and a light that dims are all
// that. One queue asks any of them to play, pause, resume, stop or seek; the
// game, the one writer of Animation, may also write its playing.

Timeline_Command :: enum u8 {
    Seek,   // jumps to time, without firing the markers it skips
    Play,   // from its start
    Pause,  // stays where it is
    Resume, // goes on from where it is
    Stop,   // goes back to its start and waits there
}

Animation_Command :: struct {
    entity:core.Entity,
    time:f32, // Seek: seconds into the clip
    command:Timeline_Command,
}

// What the last command left a clip doing, in place of Animation.playing, until the game changes
// that field: the component is the game's, and what others ask is kept here.
Timeline_Transport :: enum u8 {Component,Play,Pause}

// Asks the clip of an entity for a command in the next tick. Play, Pause, Resume and Stop hold
// until the game changes Animation.playing. The editor, which does not play, takes only Seek.
animation_command :: proc(requests:^Animation_Requests,entity:core.Entity,command:Timeline_Command,time:f32=0) {
    if requests==nil {return}
    if entity==core.NONE || command>max(Timeline_Command) || !finite(time) {core.refuse(&requests.timeline);return}
    core.offer(&requests.timeline,Animation_Command{entity,time,command})
}

// Asks for the entity to be at a time of its clip in the next tick, without firing the markers it skips.
animation_seek :: proc(requests:^Animation_Requests,entity:core.Entity,time:f32) {animation_command(requests,entity,.Seek,time)}

// Whether the clip of an entity plays in this tick: what its Animation says, or the last command
// since. False for an entity that plays nothing.
animation_playing :: proc(playback:^Playback,entity:core.Entity) -> bool {
    if playback==nil {return false}
    state:=constraint_playing(playback,entity)
    return state!=nil && state.seen==playback.frame && state.playing
}

// The markers of the clip an entity plays, in time order, which content.markers names by their
// id; none while it plays no clip.
animation_markers :: proc(playback:^Playback,sources:^Source_Assets,app:^host.App,entity:core.Entity) -> (markers:[]lib.Marker,content:^host.Content_Animation) {
    if playback==nil {return}
    state:=constraint_playing(playback,entity)
    if state==nil || state.clip<0 {return}
    content=animation_playing_content(sources,app,state)
    if content==nil || state.clip>=content.clip_count {return nil,nil}
    return lib.clip_markers(&content.lib,lib.Clip(state.clip+1)),content
}

// The entity the clip of an animated entity calls target as its tracks bind it: itself for 0, none
// when nothing it animates has that name.
animation_bound :: proc(playback:^Playback,entity:core.Entity,target:u64) -> core.Entity {
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    return field_entity(state,target) if state!=nil else core.NONE
}

// Takes the commands of the tick for a state: whether its clip plays, in animation, and the seeks
// they leave in the queue for the tick to read.
@(private)
timeline_transport :: proc(state:^Playing,animation:^Animation,commands:[]Animation_Command,running:bool) {
    if running {
        if animation.playing!=state.component_playing {state.transport=.Component}
        state.component_playing=animation.playing
    }
    for &asked in commands {
        if asked.entity!=state.entity || asked.command==.Seek {continue}
        command:=asked.command
        asked.entity=core.NONE
        if !running {continue}
        state.transport=.Play if command==.Play || command==.Resume else .Pause
        if command==.Play || command==.Stop {asked={state.entity,0,.Seek}}
    }
    if running {
        switch state.transport {
        case .Component:
        case .Play: animation.playing=true
        case .Pause: animation.playing=false
        }
    }
    state.playing=animation.playing
}

// The commands no state took were asked of entities that play nothing.
@(private)
timeline_unclaimed :: proc(commands:[]Animation_Command,running:bool,problems:^core.Problems) {
    if !running {return}
    for asked in commands {
        if asked.command==.Seek || asked.entity==core.NONE {continue}
        core.report(problems,asked.entity,"animation.command","a %v was asked of this entity, and it plays no clip: it has no Animation, or no Transform, or its Animation is not valid; give it an Animation whose asset is the .anim of the clip, or ask the entity that has it",asked.command)
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
fields_stamp :: proc "contextless" (playback:^Playback) -> u64 {
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
fields_bind :: proc(fields:^Field_Playback,world:core.World_Ref,playback:^Playback,sources:^Source_Assets,app:^host.App,problems:^core.Problems) -> bool {
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
@(step="fixed",loops="game editor",stage="apply")
animation_fields :: proc(world:core.World_Ref,playing:core.Ref(Playback),fields:^Field_Playback,content_sources:core.Ref(Source_Assets),app:^host.App,problems:^core.Problems) {
    if app==nil || app.assets==nil {return}
    playback,sources:=playing.ptr,content_sources.ptr
    if stamp:=fields_stamp(playback);stamp!=fields.stamp || fields.info!=world.info {
        if !fields_bind(fields,world,playback,sources,app,problems) {
            clear(&fields.fields);fields.stamp=0
            memory_problem(problems,core.NONE,"the fields the clips write, so none is written in this tick")
            return
        }
        fields.stamp,fields.info=stamp,world.info
    }
    state:^Playing
    for bound in fields.fields {
        if state==nil || state.entity!=bound.player {state=constraint_playing(playback,bound.player)}
        if state==nil || state.seen!=playback.frame || state.held {continue}
        for curve in playing_curves(state) {
            if curve.target!=bound.curve || curve.property!=bound.property || curve.slot!=bound.slot {continue}
            if curve.weight<=0 {break}
            table:=core.world_table_at(world,bound.table)
            row:=core.raw_row(table,bound.entity)
            if row<0 {break}
            if field_write(bound,([^]u8)(core.raw_value(table,bound.table.info,row)),curve.value/curve.weight) {core.raw_touch(table,bound.entity)}
            break
        }
    }
}
