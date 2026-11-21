package abilities

import "core:fmt"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:std/base"

@(params)
Ability_Data :: struct {
    abilities:core.Records(Ability),
    kits:core.Records(Ability_Kit),
    hitboxes:core.Records(Ability_Hitbox),
    feedback:core.Records(Ability_Feedback),
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

@(storage,host)
Ability_Sheets :: struct {
    generation:[4]u32,
    ready:bool,
    abilities,hitboxes:[dynamic]Sheet_Problem,
    kits:[dynamic]Kit_Cache,
    channels:[dynamic]core.Birth_Channel,
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
    generation:=[4]u32{
        core.records_generation(data.abilities),core.records_generation(data.kits),
        core.records_generation(data.hitboxes),core.records_generation(data.feedback),
    }
    if cache.ready && cache.generation==generation {return true}
    cache.ready=false
    if resize(&cache.abilities,core.records_count(data.abilities))!=nil ||
       resize(&cache.kits,core.records_count(data.kits))!=nil ||
       resize(&cache.hitboxes,core.records_count(data.hitboxes))!=nil ||
       resize(&cache.channels,core.records_count(data.feedback))!=nil {return false}
    for &channel,i in cache.channels {
        f:=record_at(data.feedback,i)
        channel=0
        if f!=nil {channel=core.birth_channel(base.text_get(f.channel[:]))}
    }
    text:[512]u8
    for &problem,i in cache.hitboxes {
        h:=record_at(data.hitboxes,i)
        message:=hitbox_check(h,text[:]) if h!=nil else "hitbox row could not be read"
        if message=="" && ref_missing(data.abilities,h.effect.use) {
            message="effect.use names a missing Ability row: pick another row or none"
        }
        if message=="" && ref_missing(data.feedback,h.on_hit) {
            message="on_hit names a missing Ability_Feedback row: pick another row or none"
        }
        base.text_set(problem[:],message)
    }
    for &problem,i in cache.abilities {
        a:=record_at(data.abilities,i)
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
    if ref_missing(data.feedback,a.on_start) {
        return "on_start names a missing Ability_Feedback row: pick another row or none"
    }
    for &w,i in a.windows {
        if w.hitbox!={} {
            row:=record_row(data.hitboxes,w.hitbox)
            if record_at(data.hitboxes,row)==nil {return fmt.bprintf(out,"windows[%d].hitbox names a missing Ability_Hitbox row",i)}
            if problem:=base.text_get(cache.hitboxes[row][:]);problem!="" {
                return fmt.bprintf(out,"windows[%d].hitbox %s",i,problem)
            }
        }
        if ref_missing(data.feedback,w.on_begin) {
            return fmt.bprintf(out,"windows[%d].on_begin names a missing Ability_Feedback row",i)
        }
    }
    return ""
}
