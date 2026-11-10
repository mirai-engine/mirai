package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Preview_Parameter :: struct {name:[32]u8 `mirai:"text"`,value:f32}
Preview_Control :: struct {kind:anim.Modifier_Kind,name:[256]u8 `mirai:"text"`,weight:f32 `mirai:"optional,min=0,max=1"`,enabled:bool `mirai:"optional"`,fade:f32 `mirai:"optional,min=0"`}
// A play of an action of the action set of the entity, or with stop its end. A section named while
// the action plays moves it there.
Preview_Action :: struct {name:[64]u8 `mirai:"text"`,stop:bool `mirai:"optional"`,section:[64]u8 `mirai:"text,optional"`,tick:u32 `mirai:"optional,max=3600,label=In animation.preview and animation.pose.bake: the tick it is asked at"`}
Preview_Goal :: struct {
    kind:Modifier_Goal_Kind,
    name:[256]u8 `mirai:"text"`,
    effector:[64]u8 `mirai:"text,optional"`,
    target:Spatial_Target_Params `mirai:"optional"`,
    position,normal:mm.Vec3 `mirai:"optional"`,
    contact:f32 `mirai:"optional,min=0,max=1"`,
    grounded:bool `mirai:"optional"`,
}

@(private)
// The .anim whose clips an asset plays: itself, or the source of a .match unless library replaces it.
program_source :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,library:base.Asset_Id={}) -> (base.Asset_Id,bool) {
    if s.app==nil || s.app.assets==nil {authoring_failure(call,"assets","Unavailable","an asset registry","missing registry","Assets are unavailable",api.SERVER_ERROR);return {},false}
    record,found:=asset.registry_find(&s.app.assets.registry,id)
    if !found {authoring_failure(call,"asset","Missing_Asset","an animation asset in the registry",fmt.tprintf("%v",id),"The animation asset is missing");return {},false}
    file:Authoring_File;defer asset.asset_close(&file.file)
    source:base.Asset_Id;ok:bool
    switch record.kind {
    case asset.KIND_ANIMATION:
        if library!={} {authoring_failure(call,"library","Unsupported_Policy","no library for an .anim asset","a library","A library replaces the clips of a .match");return {},false}
        return id,true
    case anim.MATCH_KIND:
        profile:anim.Match_Profile;profile,ok=program_match_open(s,call,id,&file);source=profile.info.animation
    case anim.BLEND_KIND:
        authoring_failure(call,"asset","Layer_Space","an .anim or .match asset","a .blend","A .blend plays only as the space of a layer of an action set",fix="Name it in the space of a layer with animation.action.set, and play locomotion with a .match (animation.character.setup writes one)");return {},false
    case:
        authoring_failure(call,"asset","Invalid_Kind","an .anim or .match asset",fmt.tprintf("%v",record.kind),"Expected an .anim or .match asset");return {},false
    }
    if !ok || library=={} {return source,ok}
    if found,exists:=asset.registry_find(&s.app.assets.registry,library);!exists || found.kind!=asset.KIND_ANIMATION {authoring_failure(call,"library","Invalid_Kind","an .anim asset in the registry",fmt.tprintf("%v",library),"The library must be an .anim asset");return {},false}
    return library,true
}

