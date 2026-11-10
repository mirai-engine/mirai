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
// that. One queue asks any of them to play, pause, resume, stop or seek.

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

// Asks the clip of an entity for a command in the next tick: Animation.playing follows Play,
// Pause, Resume and Stop. The editor, which does not play, takes only Seek.
animation_command :: proc(requests:^Animation_Requests,entity:core.Entity,command:Timeline_Command,time:f32=0) {
    if requests==nil {return}
    if entity==core.NONE || command>max(Timeline_Command) || !finite(time) {core.refuse(&requests.timeline);return}
    core.offer(&requests.timeline,Animation_Command{entity,time,command})
}

// Asks for the entity to be at a time of its clip in the next tick, without firing the markers it skips.
animation_seek :: proc(requests:^Animation_Requests,entity:core.Entity,time:f32) {animation_command(requests,entity,.Seek,time)}

// Turns the commands of the tick into what animation_sample reads: whether each Animation plays,
// and the seeks left in the queue.
@(step="fixed",loops="game editor",stage="apply",before="animation_sample")
animation_timeline :: proc(animations:^core.Table(Animation),requests:^Animation_Requests,time:core.Time,problems:^core.Problems) {
    for &asked in requests.timeline.items {
        if asked.command==.Seek {continue}
        e,command:=asked.entity,asked.command
        asked.entity=core.NONE
        if !time.playing {continue}
        animation,animated:=core.get(core.read(animations),e)
        if !animated {
            core.report(problems,e,"animation.command","a %v was asked of this entity, and it has no Animation; give it one whose asset is the .anim of the clip, or ask the entity that has it",command)
            continue
        }
        playing:=command==.Play || command==.Resume
        if animation.playing!=playing {core.get(animations,e).playing=playing}
        if command==.Play || command==.Stop {asked={e,0,.Seek}}
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
            _,table:=core.world_table_named(world,component)
            if table==nil {
                core.report(problems,state.entity,"animation.field_component","a track of its clip writes %s.%s, and the game has no component %s; name a component of the game in the target of the track, as @field/Point_Light.intensity",component,path,component)
                continue
            }
            type,added:=serial.schema_add_type_info(&schema,table.info)
            target,error,_:=serial.path_resolve(&schema,type,path)
            if !added || error!=.None {
                core.report(problems,state.entity,"animation.field_path","a track of its clip writes %s.%s, which is not a field of %s (%v); name one of its fields, with a dot for a field inside another and [n] for an element",component,path,component,error)
                continue
            }
            bound:=Field_Bound{player=state.entity,entity=e,curve=field.curve,property=field.property,slot=field.slot,table=table,offset=u32(target.offset),count=1}
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
            valid&&=(bound.count==1)==(field.property==.Float)
            if !valid {
                core.report(problems,state.entity,"animation.field_type","a track of its clip writes %s.%s, which a %v track cannot write; a Float track writes a number, a flag or a member of a bit set, and a Vector track a vector or a color of 2 to 4 numbers",component,path,field.property)
                continue
            }
            if append(&fields.fields,bound)!=1 {return false}
        }
    }
    return true
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
@(step="fixed",loops="game editor",stage="apply",after="animation_sample")
animation_fields :: proc(world:core.World_Ref,playback:^Playback,fields:^Field_Playback,sources:^Source_Assets,app:^host.App,problems:^core.Problems) {
    if app==nil || app.assets==nil {return}
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
