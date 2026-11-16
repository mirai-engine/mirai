package prefab

import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

// The components of the animation plugin as a game declares them: around the
// fields the import sets, fields it does not, which start at their default.
Game_Animation :: struct {
    asset,library:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    speed:f32,
    loop,mirror,playing,preview:bool,
    weight,fade:f32,
    event_threshold:f32,
}
Game_Animation_Target :: struct {path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`,animation:core.Entity}
Game_Pose_Source :: struct {rig:core.Entity,stage:u8}
Game_Bone_Attachment :: struct {rig:core.Entity,socket:[64]u8 `mirai:"text"`,offset:mm.Transform,enabled:bool}
GAME_BONE_ATTACHMENT_DEFAULT :: Game_Bone_Attachment{offset=mm.TRANSFORM_IDENTITY,enabled=true}
Game_Morph_Weights :: struct {
    source:core.Entity,
    path:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    names:[asset.MORPH_WEIGHTS]u64,
    values:[asset.MORPH_WEIGHTS]f32,
    modes:[asset.MORPH_WEIGHTS]Morph_Weight_Mode,
}

// The Collider of the physics plugin as a game declares it: the import sets its kind by name.
Game_Collider_Kind :: enum u8 {Box,Sphere,Capsule,Cylinder,Hull,Mesh,Heightfield,External,Auto}
Game_Collider :: struct {kind:Game_Collider_Kind,size:[3]f32,friction:f32}
GAME_COLLIDER_DEFAULT :: Game_Collider{size={0.5,0.5,0.5},friction=0.6}

GAME_ANIMATION_DEFAULT :: Game_Animation{speed=1,weight=1,loop=true,playing=true,fade=0.2,event_threshold=.01}

// The world of a game with the animation plugin, whose types the prefab of an
// import is written in.
@(test_world)
Import_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
    disabled:core.Table(core.Disabled),
    transforms:core.Table(core.Transform),
    meshes:core.Table(render.Mesh_Renderer),
    hidden:core.Table(render.Hidden),
    suns:core.Table(render.Sun),
    points:core.Table(render.Point_Light),
    spots:core.Table(render.Spot_Light),
    rects:core.Table(render.Rect_Light),
    animations:core.Table(Game_Animation) `mirai:"name=Animation"`,
    targets:core.Table(Game_Animation_Target) `mirai:"name=Animation_Target"`,
    poses:core.Table(Game_Pose_Source) `mirai:"name=Pose_Source"`,
    attachments:core.Table(Game_Bone_Attachment) `mirai:"name=Bone_Attachment"`,
    morphs:core.Table(Game_Morph_Weights) `mirai:"name=Morph_Weights"`,
    colliders:core.Table(Game_Collider) `mirai:"name=Collider"`,
}

// Without the animation plugin: its components are left out of a prefab.
@(test_world)
Static_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
    disabled:core.Table(core.Disabled),
    transforms:core.Table(core.Transform),
    meshes:core.Table(render.Mesh_Renderer),
    hidden:core.Table(render.Hidden),
}

// The World_Info of the game of a test import, in the temp allocator; nil,
// with the test failed, when it cannot be made.
import_world :: proc(t:^testing.T,animated:=true,loc:=#caller_location) -> ^core.World_Info {
    info:=new(core.World_Info,context.temp_allocator)
    ok:bool
    if animated {info^,ok=test_info(t,Import_World,context.temp_allocator,loc)} else {info^,ok=test_info(t,Static_World,context.temp_allocator,loc)}
    return info if ok else nil
}
