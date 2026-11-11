package main

import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

WAVES_FILE :: "assets/ai/horde_waves.records"

// The waves of the horde of the AI level: three of ten, so the horde ends as many as it had
// before it had waves. Which zombie comes out is the prefab of its spawn point.
write_horde_records :: proc(o:^Out) {
    next :: proc(name:string) -> core.Record(game.Horde_Wave) {return record_ref(game.Horde_Wave,WAVES_FILE,name)}
    waves:=[]Row_Out(game.Horde_Wave){
        {"first",{delay=10,interval=0.5,count=10,next=next("second")}},
        {"second",{delay=20,interval=0.4,count=10,next=next("last")}},
        {"last",{delay=30,interval=0.5,count=10}},
    }
    write_records(o,WAVES_FILE,"game.Horde_Wave",game.Horde_Wave,waves)
}

// The moves of the agents of the arenas, which turn the body that shows them, and the .character
// their minds play them by name with: a bite and a slam lean it forward, a summon spins it and a
// roar throws it back; its Look turns it toward what it bites.
write_arena_agent :: proc(o:^Out) {
    turn :: proc(times:[]f32,axis:mm.Vec3,angles:[]f32) -> []lib.Keyframe {
        keys:=make([]lib.Keyframe,len(times),context.temp_allocator)
        for &key,i in keys {key={time=times[i],value=lib.quat_vec4(mm.quat_axis_angle(axis,angles[i])),ease=.Sine_In_Out}}
        return keys
    }
    side,up:=mm.Vec3{1,0,0},mm.Vec3{0,1,0}
    clips:=[]asset.Animation_Clip_Desc{
        {name="idle",tracks={{target="Body",property=.Rotation,keys=turn({0},side,{0})}}},
        {name="bite",tracks={{target="Body",property=.Rotation,keys=turn({0,.2,.5},side,{0,-.6,0})}}},
        {name="slam",tracks={{target="Body",property=.Rotation,keys=turn({0,.3,.45,1},side,{0,.4,-.9,0})}}},
        {name="summon",tracks={{target="Body",property=.Rotation,keys=turn({0,.5,1},up,{0,3.14,6.28})}}},
        {name="roar",tracks={{target="Body",property=.Rotation,keys=turn({0,.3,1},side,{0,.5,0})}}},
    }
    library:=asset.content_id(PROJECT,"animation","arena_agent")
    asset.content_check(&o.content,"assets/ai/arena_agent.anim",asset.animation_save(path(o,"assets/ai/arena_agent.anim"),&o.content.types,{id=library,clips=clips}))
    actions:=make([]anim.Action_Definition,4,context.temp_allocator)
    for &action,i in actions {
        names:=[4]string{"Bite","Slam","Summon","Roar"}
        action=anim.ACTION_DEFINITION_DEFAULT
        base.text_set(action.name[:],names[i]);base.text_set(action.clip[:],clips[i+1].name)
    }
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.bone=anim.bone_ref("Body");look.enabled=false
    set:=anim.character_set_make(library);set.actions.actions=actions;set.pose.look={look}
    asset.content_check(&o.content,"assets/ai/arena_agent.character",anim.character_save(path(o,"assets/ai/arena_agent.character"),&o.content.types,game.ARENA_AGENT,set))
}
