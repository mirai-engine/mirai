package anim

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

// What a slot of the stack of a state plays by itself in a test that poses the state without an
// action set: the layer an action set would ask for, written where layers_advance reads it.
@(private)
test_layer :: proc(state:^Playing,slot:int,clip:string,fade:f32=0,over:="",sync:=false,weight:f32=1,speed:f32=1,loop:=true,mode:Layer_Mode=.Override,reference:f32=0,curves:Curve_Blend=.Override,mesh_space:=false,reference_clip:="") -> bool {
    if state==nil || slot<1 || slot>=STACK_SLOTS {return false}
    state.asked[slot]={
        clip=base.name_hash(clip),over=base.name_hash(over) if over!="" else 0,weight=mm.saturate(weight),speed=speed,fade=fade,loop=loop,sync=sync,
        mode=mode,reference=reference,reference_clip=base.name_hash(reference_clip) if reference_clip!="" else 0,curves=curves,mesh_space=mesh_space,
    }
    state.stack=max(state.stack,u8(slot+1))
    return true
}
@(private)
test_layer_weight :: proc(state:^Playing,slot:int,weight:f32) -> bool {
    if state==nil || slot<1 || slot>=STACK_SLOTS {return false}
    state.asked[slot].weight=mm.saturate(weight)
    return true
}
// The layer of a slot stops playing its clip and fades out over fade seconds.
@(private)
test_layer_stop :: proc(state:^Playing,slot:int,fade:f32) -> bool {
    if state==nil || slot<1 || slot>=STACK_SLOTS {return false}
    state.asked[slot].clip,state.asked[slot].fade=0,fade
    return true
}

// A layer of an action set that plays clip by itself, named as its clip.
@(private)
test_stack_layer :: proc(clip:string,over:="",weight:f32=1,fade:f32=0,sync:=false,speed:f32=1,loop:=true,mode:Layer_Mode=.Override,reference:f32=0,reference_clip:="",curves:Curve_Blend=.Override,mesh_space:=false,name:="") -> Stack_Layer {
    layer:=STACK_LAYER_DEFAULT
    base.text_set(layer.name[:],name if name!="" else clip);base.text_set(layer.clip[:],clip);base.text_set(layer.reference_clip[:],reference_clip)
    layer.over=bone_ref(over) if over!="" else {}
    layer.weight,layer.fade,layer.sync,layer.speed,layer.loop,layer.mode,layer.reference,layer.curves,layer.mesh_space=weight,fade,sync,speed,loop,mode,reference,curves,mesh_space
    return layer
}

// Saves the action set of layers and actions over animation as <directory>/<name>.action, where a
// host.Assets opened on the directory finds it under id.
@(private)
test_action_set_save :: proc(t:^testing.T,directory,name:string,types:^asset.Types,id,animation:base.Asset_Id,layers:[]Stack_Layer,actions:[]Action_Definition=nil,sections:[]Action_Section=nil,windows:[]Action_Window=nil) -> bool {
    profile:=Action_Profile{info={animation=animation},layers=layers,actions=actions,sections=sections,windows=windows}
    return testing.expect_value(t,action_profile_save(fmt.tprintf("%s/%s.action",directory,name),types,id,profile),asset.Error.None)
}
