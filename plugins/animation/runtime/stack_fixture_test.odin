package anim

import "core:fmt"
import "mirai:core"
import "core:testing"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// What a slot of the stack of a state plays by itself in a test that poses the state without a
// .character: the layer a .character would ask for, written where layers_advance reads it.
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

// A layer of a .character that plays clip by itself, named as its clip.
@(private)
test_stack_layer :: proc(clip:string,over:="",weight:f32=1,fade:f32=0,sync:=false,speed:f32=1,loop:=true,mode:Layer_Mode=.Override,reference:f32=0,reference_clip:="",curves:Curve_Blend=.Override,mesh_space:=false,name:="") -> Stack_Layer {
    layer:=STACK_LAYER_DEFAULT
    base.text_set(layer.name[:],name if name!="" else clip);base.text_set(layer.clip[:],clip);base.text_set(layer.reference_clip[:],reference_clip)
    layer.over=bone_ref(over) if over!="" else {}
    layer.weight,layer.fade,layer.sync,layer.speed,layer.loop,layer.mode,layer.reference,layer.curves,layer.mesh_space=weight,fade,sync,speed,loop,mode,reference,curves,mesh_space
    return layer
}

// Saves set as <directory>/<name>.character, where a host.Assets opened on the directory finds it
// under id; its locomotion and warping, when it leaves them out, take their defaults.
@(private)
test_character_save :: proc(t:^testing.T,directory,name:string,types:^asset.Types,id:base.Asset_Id,set:Character_Set) -> bool {
    set:=set
    if set.match.info==({}) {set.match.info=MATCH_INFO_DEFAULT}
    if set.motion.warp==({}) {set.motion.warp=POSE_WARP_PROFILE_DEFAULT}
    return testing.expect_value(t,character_save(fmt.tprintf("%s/%s.character",directory,name),types,id,set),asset.Error.None)
}
// Saves the .character of layers and actions over animation.
@(private)
test_action_set_save :: proc(t:^testing.T,directory,name:string,types:^asset.Types,id,animation:base.Asset_Id,layers:[]Stack_Layer,actions:[]Action_Definition=nil,sections:[]Action_Section=nil) -> bool {
    return test_character_save(t,directory,name,types,id,{info={animation=animation},actions={layers=layers,actions=actions,sections=sections}})
}

// Lets assets know ids as .character sets, as a scan of their files would, for a test that seeds
// their content by hand (test_character_seed).
@(private)
test_character_register :: proc(assets:^host.Assets,ids:..base.Asset_Id) {
    if assets.registry.by_id==nil {assets.registry.by_id=make(map[base.Asset_Id]u32)}
    for id in ids {assets.registry.by_id[id]=u32(len(assets.registry.files));append(&assets.registry.files,asset.Registry_File{id=id,kind=CHARACTER_KIND,state=.Asset})}
}
@(private)
test_registry_free :: proc(assets:^host.Assets) {delete(assets.registry.by_id);delete(assets.registry.files)}
// The content of a set read, as character_content leaves it, without its file: the caller keeps
// the rows of set.
@(private)
test_character_seed :: proc(cache:^Character_Assets,id:base.Asset_Id,set:Character_Set) {
    if cache.allocator.procedure==nil {cache.allocator=context.allocator}
    append(&cache.contents,Character_Content{id=id,checked=1,revision=1,set=set,valid=true})
}

// What a tick of a test needs beside its tables: the storages it does not give are those of extra.
@(private)
Test_Storages :: struct {characters:Character_Assets,actions:Action_Runtime,motion:Motion_Runtime,sources:Source_Assets,played:core.Table(Animation_Played),remotes:core.Table(core.Remote)}
@(private)
test_storages_free :: proc(s:^Test_Storages) {character_assets_free(&s.characters);actions_runtime_free(&s.actions);motion_runtime_free(&s.motion);source_assets_free(&s.sources);core.table_destroy(&s.played);core.table_destroy(&s.remotes)}
@(private)
test_tick :: proc(animations:^core.Table(Animation,.Read),transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),names:^core.Table(core.Name,.Read),requests:^Animation_Requests,events:^Animation_Events,targets:^core.Table(Animation_Target,.Read),playback:^Playback,app:^host.App,time:core.Time,frame:core.Frame_Time,skeletons:^Skeleton_Assets,problems:^core.Problems,extra:^Test_Storages,characters:^Character_Assets=nil,actions:^Action_Runtime=nil,motion:^Motion_Runtime=nil,sources:^Source_Assets=nil,remotes:^core.Table(core.Remote,.Read)={},played:^core.Table(Animation_Played)=nil) {
    animation_tick(animations,transforms,parents,hierarchy,names,requests,events,targets,playback,app,time,frame,skeletons,problems,
        characters if characters!=nil else &extra.characters,actions if actions!=nil else &extra.actions,motion if motion!=nil else &extra.motion,sources if sources!=nil else &extra.sources,
        remotes if remotes!=nil else core.read(&extra.remotes),played if played!=nil else &extra.played,{},core.CLOCK_DEFAULT,ANIMATION_BUDGET_CONFIG_DEFAULT)
}
