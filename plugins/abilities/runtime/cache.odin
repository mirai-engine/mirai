package abilities

import "core:fmt"
import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import "mirai:std/base"

@(params)
Ability_Data :: struct {
    abilities:core.Records(Ability),
    kits:core.Records(Ability_Kit),
    hitboxes:core.Records(Ability_Hitbox),
}

Sheet_Problem :: [core.PROBLEM_TEXT]u8

Kit_Input :: struct {
    row:int,
    action:inp.Action_Mask,
}

Kit_Cache :: struct {
    problem:Sheet_Problem,
    invalid_ability:int,
    actions:[Ability_Trigger]inp.Action_Mask,
    inputs:[KIT_ABILITIES]Kit_Input,
    count:int,
}

Ability_Span_Cache :: struct {
    action:u64,
    windows:[ABILITY_WINDOWS]u64,
    channels:[ABILITY_WINDOWS]core.Birth_Channel, // of the on_begin of each window
    any:bool,
}

@(storage,host)
Ability_Sheets :: struct {
    generation:[3]u32,
    ready:bool,
    abilities,hitboxes:[dynamic]Sheet_Problem,
    ability_spans:[dynamic]Ability_Span_Cache,
    kits:[dynamic]Kit_Cache,
    hit_channels:[dynamic][1+len(Ability_Hitbox{}.target_effects)]core.Birth_Channel, // of the on_hit of each effect of a hitbox: effect, then target_effects
}

Attribute_Check :: struct {
    stamp,write:u64,
    problem:Attribute_Problem,
    index:int,
}

@(storage,copy=false)
Ability_Attributes :: struct {
    seen:core.Seen,
    shape:core.Shape,
    entries:core.Entity_Map(Attribute_Check),
}

sheets_refresh :: proc(cache:^Ability_Sheets,data:Ability_Data) -> bool {
    generation:=[3]u32{
        core.records_generation(data.abilities),core.records_generation(data.kits),
        core.records_generation(data.hitboxes),
    }
    if cache.ready && cache.generation==generation {return true}
    cache.ready=false
    if resize(&cache.abilities,core.records_count(data.abilities))!=nil ||
       resize(&cache.ability_spans,core.records_count(data.abilities))!=nil ||
       resize(&cache.kits,core.records_count(data.kits))!=nil ||
       resize(&cache.hitboxes,core.records_count(data.hitboxes))!=nil ||
       resize(&cache.hit_channels,core.records_count(data.hitboxes))!=nil {return false}
    for &channels,i in cache.hit_channels {
        channels={}
        h:=record_at(data.hitboxes,i)
        if h==nil {continue}
        channels[0]=audio.cue_channel(h.effect.on_hit)
        for te,j in h.target_effects {channels[1+j]=audio.cue_channel(te.on_hit)}
    }
    text:[512]u8
    for &problem,i in cache.hitboxes {
        h:=record_at(data.hitboxes,i)
        message:=hitbox_check(h,text[:]) if h!=nil else "hitbox row could not be read"
        if message=="" && ref_missing(data.abilities,h.effect.use) {
            message="effect.use names a missing Ability row: pick another row or none"
        }
        if message=="" {
            for te,j in h.target_effects {
                if ref_missing(data.abilities,te.use) {
                    message=fmt.bprintf(text[:],"target_effects[%d].use names a missing Ability row: pick another row or none",j)
                    break
                }
            }
        }
        base.text_set(problem[:],message)
    }
    for &problem,i in cache.abilities {
        a:=record_at(data.abilities,i)
        spans:Ability_Span_Cache
        if a!=nil {
            if name:=ability_name_text(&a.action);name!="" {spans.action=base.name_hash(name)}
            for &w,j in a.windows {
                if text:=base.text_get(w.span[:]);text!="" {
                    spans.windows[j]=base.name_hash(text)
                    spans.any=true
                }
                spans.channels[j]=audio.cue_channel(w.on_begin)
            }
        }
        cache.ability_spans[i]=spans
        message:=ability_check(a,text[:]) if a!=nil else "ability row could not be read"
        if message=="" {message=ability_links(a,data,cache,text[:])}
        base.text_set(problem[:],message)
    }
    for &cached,i in cache.kits {
        cached={}
        cached.invalid_ability=-1
        k:=record_at(data.kits,i)
        message:=kit_check(k,text[:]) if k!=nil else "kit row could not be read"
        if message=="" {
            for ref,j in k.abilities {
                if ref=={} {continue}
                row:=record_row(data.abilities,ref)
                a:=record_at(data.abilities,row)
                if a==nil {
                    message=fmt.bprintf(text[:],"abilities[%d] names a missing Ability row: pick another row or none",j)
                    break
                }
                if cache.abilities[row][0]!=0 {
                    if cached.invalid_ability<0 {cached.invalid_ability=row}
                    continue
                }
                if a.input.on==.None {continue}
                bit:=inp.action_bit(a.input.action)
                cached.actions[a.input.on]|=bit
                cached.inputs[cached.count]={row,bit}
                cached.count+=1
            }
        }
        base.text_set(cached.problem[:],message)
    }
    cache.generation,cache.ready=generation,true
    return true
}

@(private)
ref_missing :: proc(rows:core.Records($T),ref:core.Record(T)) -> bool {
    return ref!={} && record_sheet(rows,ref)==nil
}

@(private)
ability_links :: proc(a:^Ability,data:Ability_Data,cache:^Ability_Sheets,out:[]u8) -> string {
    if ref_missing(data.abilities,a.next) {
        return "next names a missing Ability row: pick another row or none"
    }
    for &w,i in a.windows {
        if w.hitbox!={} {
            row:=record_row(data.hitboxes,w.hitbox)
            if record_at(data.hitboxes,row)==nil {return fmt.bprintf(out,"windows[%d].hitbox names a missing Ability_Hitbox row",i)}
            if problem:=base.text_get(cache.hitboxes[row][:]);problem!="" {
                return fmt.bprintf(out,"windows[%d].hitbox %s",i,problem)
            }
        }
    }
    return ""
}
