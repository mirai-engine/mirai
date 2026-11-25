package abilities_editor

import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import mm "mirai:std/math"
import ab "plugins:abilities/runtime"

// The hitboxes of the open windows of the abilities the users of a world run, over the image
// capture takes with debug hitboxes: each where abilities.inspect places it, in another color
// once its window hit something.
@(storage)
Hitboxes_Capture :: struct {provider:editor.Capture_Overlay_Provider}

HITBOXES_CAPTURE_DEFAULT :: Hitboxes_Capture{provider={name="hitboxes",draw=hitboxes_capture_draw}}

HITBOXES_CAPTURE_OPEN :: [4]f32{1,0.9,0.2,1}
HITBOXES_CAPTURE_HIT :: [4]f32{1,0.25,0.2,1}
HITBOXES_CAPTURE_SEGMENTS :: 16 // of each circle of a sphere or a capsule

@(private)
hitboxes_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines) {
    if s.app!=nil {hitboxes_draw(lines,w,sets(s))}
}

// The hitboxes of the open windows of what the users of w run, by the rows of data.
@(private)
hitboxes_draw :: proc(lines:^erender.Debug_Lines,w:core.World_Ref,data:ab.Ability_Data) {
    users,states:=core.world_table_of(w,ab.Ability_User),core.world_table_of(w,ab.Ability_State)
    if users==nil || states==nil {return}
    locals:=core.world_table_of(w,ab.Ability_Local)
    time,dt:=world_clock(w)
    for row in 0..<core.count(users) {
        e:=core.entity_at(users,row)
        state,found:=core.get(states,e)
        active:=ab.record_sheet(data.abilities,state.ability)
        if !found || active==nil {continue}
        local:ab.Ability_Local
        if locals!=nil {local,_=core.get(locals,e)}
        at:=running_at(time,&state,&local)
        pose:=user_pose(w,e)
        for &win,i in active.windows {
            if !ab.ability_window_open(win,dt,at,i) {continue}
            h:=ab.record_sheet(data.hitboxes,win.hitbox)
            if h==nil {continue}
            hitbox_draw(lines,h,pose,HITBOXES_CAPTURE_HIT if len(window_targets(&local,i))>0 else HITBOXES_CAPTURE_OPEN)
        }
    }
}

// A hitbox of a user at pose as lines: the edges of a box, three circles of a sphere, the
// outline of a capsule along its Y axis.
@(private)
hitbox_draw :: proc(lines:^erender.Debug_Lines,h:^ab.Ability_Hitbox,pose:mm.Transform,color:[4]f32) {
    center,rotation:=ab.hitbox_world(h,pose)
    switch h.shape {
    case .None:
    case .Box: erender.debug_box_transformed(lines,mm.transform_matrix({center,rotation,{1,1,1}}),-h.size,h.size,color)
    case .Sphere: erender.debug_sphere(lines,center,h.size.x,color,HITBOXES_CAPTURE_SEGMENTS)
    case .Capsule:
        up:=mm.quat_rotate(rotation,mm.Vec3{0,h.size.y,0})
        erender.debug_sphere(lines,center+up,h.size.x,color,HITBOXES_CAPTURE_SEGMENTS)
        erender.debug_sphere(lines,center-up,h.size.x,color,HITBOXES_CAPTURE_SEGMENTS)
        for side in ([4]mm.Vec3{{1,0,0},{-1,0,0},{0,0,1},{0,0,-1}}) {
            offset:=mm.quat_rotate(rotation,side*h.size.x)
            erender.debug_line(lines,center+up+offset,center-up+offset,color)
        }
    }
}
