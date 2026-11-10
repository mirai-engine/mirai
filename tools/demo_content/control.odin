package main

import "mirai:asset"
import game "mirai:demo/game"
import lib "mirai:std/anim"

// The intro of the control scene: it moves the room camera, narrows the lens of the dog camera
// and marks the bark. The cameras are its actors by name.
write_control_intro :: proc(o:^Out) {
    ROOM,DOG :: "Intro room camera","Intro dog camera"
    CUT :: f32(50)/60
    dolly:=[]lib.Keyframe{{time=0,value={5,5,9,0}},{time=CUT,value={4,4.5,8,0},ease=.Cubic_In_Out}}
    zoom:=[]lib.Keyframe{{time=CUT,value={game.VIEW_FOV,0,0,0}},{time=2*CUT,value={0.9,0,0,0},ease=.Cubic_In_Out}}
    clips:=[]asset.Animation_Clip_Desc{{name="intro",tracks={{target=ROOM,property=.Position,keys=dolly},{target=DOG+"/"+asset.ANIMATION_FIELD_PATH+"Camera.fov",property=.Float,keys=zoom}},markers={{time=CUT/2,name="intro.bark"}}}}
    id:=asset.content_id(PROJECT,"animation","control_intro")
    asset.content_check(&o.content,"assets/control/intro.anim",asset.animation_save(path(o,"assets/control/intro.anim"),&o.content.types,{id=id,clips=clips}))
}
