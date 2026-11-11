package water

import "core:math"
import "mirai:core"
import render "mirai:engine/render"

// How wet the instances of the bodies of Water_Wet are, given to the
// renderer (render.instance_wet_set): those of a body and of the entities
// under it in the hierarchy. The list of them is made again when the
// instances of the renderer, the hierarchy or which bodies are wet change;
// in between, each frame sends only the instances whose wetness moved by a
// step of WET_LEVELS.

WET_INSTANCES :: 1024 // instances of wet bodies the renderer is told of; more stay dry
WET_LEVELS :: f32(64) // steps of wetness: a body drying sends one every WET_SECONDS/WET_LEVELS

@(private)
Wet_Given :: struct {
    index:int,          // of the renderer (render.instance_object)
    entity:core.Entity, // the body of Water_Wet it takes its wetness from
    hint:int,           // where that body was in Water_Wet.marks
    wet:f32,            // as the renderer was told
}

@(storage,host)
Water_Wet_Render :: struct {
    given:[WET_INSTANCES]Wet_Given,
    count:int,
    seen:[5]u64,
    world:core.World_Id,
}

// The wetness the renderer is told: in steps of WET_LEVELS.
wet_level :: proc "contextless" (wet:f32) -> f32 {
    return math.round(clamp(wet,0,1)*WET_LEVELS)/WET_LEVELS
}

// The body of Water_Wet an entity takes its wetness from: itself or the
// nearest of its ancestors that is wet, and where it is in the marks.
@(private)
wet_owner :: proc(wet:^Water_Wet,parents:core.Read(core.Parent),entity:core.Entity) -> (owner:core.Entity,at:int,ok:bool) {
    e:=entity
    for _ in 0..=core.count(parents) {
        for mark,i in wet.marks[:wet.count] {
            if mark.entity==e && wet_level(mark.wet)>0 {return e,i,true}
        }
        parent,known:=core.get(parents,e)
        if !known || parent.entity==core.NONE {return}
        e=parent.entity
    }
    return
}

// Which bodies are wet, as a sum that changes when one comes or goes.
@(private)
wet_members :: proc "contextless" (wet:^Water_Wet) -> (sum:u64) {
    for mark in wet.marks[:wet.count] {
        if wet_level(mark.wet)>0 {sum+=(u64(mark.entity)+1)*0x9e3779b97f4a7c15}
    }
    return
}

@(step="render",loops="game editor")
water_wet_render :: proc(state:^Water_Wet_Render,wet:core.Ref(Water_Wet),synced:core.Ref(render.Render_Sync),parents:core.Read(core.Parent),renderer:^render.Renderer) {
    if renderer==nil || wet.ptr==nil || synced.ptr==nil {return}
    sync:=synced.ptr
    seen:=[5]u64{render.instance_revision(renderer),u64(render.instance_count(renderer)),core.layout(parents),core.version(parents),wet_members(wet.ptr)}
    if seen!=state.seen || sync.world!=state.world {
        // What it gave before, or another world the renderer drew, may have left wet instances: all are told.
        held:=state.count>0 || sync.world!=state.world
        state.seen,state.world,state.count=seen,sync.world,0
        if seen[4]==0 && !held {return}
        for i in 0..<render.instance_count(renderer) {
            level:f32
            if owner,at,ok:=wet_owner(wet.ptr,parents,core.Entity(render.instance_object(renderer,i)));ok && state.count<WET_INSTANCES {
                level=wet_level(wet.marks[at].wet)
                state.given[state.count]={index=i,entity=owner,hint=at,wet=level}
                state.count+=1
            }
            render.instance_wet_set(renderer,i,level)
        }
        return
    }
    for &given in state.given[:state.count] {
        at:=given.hint
        if at>=wet.count || wet.marks[at].entity!=given.entity {
            at=-1
            for mark,i in wet.marks[:wet.count] {
                if mark.entity==given.entity {at=i;break}
            }
        }
        level:=at>=0?wet_level(wet.marks[at].wet):0
        given.hint=max(at,0)
        if level!=given.wet && render.instance_wet_set(renderer,given.index,level) {given.wet=level}
    }
}
