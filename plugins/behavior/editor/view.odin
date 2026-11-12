package behavior_editor

import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/ai"
import mm "mirai:std/math"
import behavior "plugins:behavior/runtime"

// The Perception mode of the viewport, over the lit image: for each selected
// Perceiver its cone of sight, the reach within which it keeps what it saw,
// its `aware` around its eyes, and a line from its eyes to each subject it
// remembers, as bright as it is sure. Nothing is drawn while the mode is off.

PERCEPTION_VIEW_MODE :: "behavior.perception"
PERCEPTION_VIEW_LINES :: 8192 // the most lines drawn; the rest are counted
PERCEPTION_VIEW_ARC :: 24     // segments of a whole circle
CONE_COLOR :: mm.Vec4{1,0.85,0.3,0.9}
KEEP_COLOR :: mm.Vec4{1,0.85,0.3,0.3}
AWARE_COLOR :: mm.Vec4{0.4,0.9,1,0.8}
SEEN_COLOR :: mm.Vec4{1,0.35,0.25,1}
HEARD_COLOR :: mm.Vec4{0.5,0.6,1,1}

@(storage,free="perception_view_free")
Perception_View :: struct {
    vertices:[dynamic]erender.Debug_Vertex, // made the first time the mode is shown
    shown:bool,
}

perception_view_free :: proc(v:^Perception_View) {
    delete(v.vertices)
    v^={}
}

@(step="frame")
perception_view_mode :: proc(s:^editor.Session,view:^Perception_View) {
    w:=editor.shown_world(s)
    reason:=""
    if w.data==nil || core.world_table_of(w,behavior.Perceiver)==nil {reason="The world shown has no Perceivers"}
    editor.view_mode_declare(s,{name=PERCEPTION_VIEW_MODE,label="Perception",title="Perception of the selected",group="Advanced",submenu="Behavior",icon=.Eye,reason=reason,record=perception_view_record})
    view.shown=reason=="" && strings.equal_fold(editor.view_mode_current(s.viewport),PERCEPTION_VIEW_MODE)
}

@(step="render",after="render_sync")
perception_view_lines :: proc(s:^editor.Session,view:^Perception_View,extras:^host.Frame_Extras) {
    if !view.shown || s.selection==nil || len(s.selection.entities)==0 {return}
    w:=editor.shown_world(s)
    perceivers:=core.world_table_of(w,behavior.Perceiver)
    worlds:=core.world_table_of(w,core.World_Transform)
    perceptions:=core.world_table_of(w,behavior.Perception)
    if perceivers==nil || worlds==nil {return}
    if len(view.vertices)==0 && resize(&view.vertices,2*PERCEPTION_VIEW_LINES)!=nil {return}
    lines:=erender.debug_lines_make(view.vertices[:],depth_test=false)
    for e in s.selection.entities {
        p,found:=core.get(perceivers,e)
        pose,placed:=core.get(worlds,e)
        if !found || !placed {continue}
        eye:=pose.position+mm.Vec3{0,p.eyes,0}
        forward:=mm.quat_forward(pose.rotation)
        forward.y=0
        if !(linalg.length(forward)>1e-4) {forward={0,0,-1}}
        forward=linalg.normalize(forward)
        draw_cone(&lines,eye,forward,p.sight,p.angle,CONE_COLOR,true)
        draw_cone(&lines,eye,forward,p.sight*behavior.SIGHT_KEEP,p.angle*behavior.SIGHT_KEEP,KEEP_COLOR,false)
        if p.aware>0 {erender.debug_circle(&lines,eye,{0,1,0},min(p.aware,p.sight),AWARE_COLOR,PERCEPTION_VIEW_ARC)}
        if perceptions==nil {continue}
        mine,remembers:=core.get(perceptions,e)
        if !remembers {continue}
        for o in mine.memory.items[:clamp(mine.memory.count,0,ai.PERCEPTION_CAPACITY)] {
            color:=SEEN_COLOR if .Sight in o.senses else HEARD_COLOR
            color.a=clamp(o.confidence,0.1,1)
            at:=o.position+mm.Vec3{0,0.1,0}
            erender.debug_line(&lines,eye,at,color)
            erender.debug_circle(&lines,at,{0,1,0},0.3,color,8)
        }
    }
    if lines.count>0 {host.extras_debug_lines_add(extras,lines)}
}

// A cone of sight on the level of the eyes: its edges with the arc between
// them, or a circle when it sees all around.
@(private)
draw_cone :: proc(lines:^erender.Debug_Lines,eye,forward:mm.Vec3,reach,angle:f32,color:mm.Vec4,edges:bool) {
    if !(reach>0 && reach<1e6) {return}
    if angle>=math.PI {
        erender.debug_circle(lines,eye,{0,1,0},reach,color,PERCEPTION_VIEW_ARC)
        return
    }
    side:=mm.Vec3{-forward.z,0,forward.x}
    at :: proc(eye,forward,side:mm.Vec3,reach,a:f32) -> mm.Vec3 {return eye+(forward*math.cos(a)+side*math.sin(a))*reach}
    half:=angle if angle>0 else 0
    segments:=max(2,int(f32(PERCEPTION_VIEW_ARC)*half/math.PI))
    previous:=at(eye,forward,side,reach,-half)
    if edges {erender.debug_line(lines,eye,previous,color)}
    for i in 1..=segments {
        next:=at(eye,forward,side,reach,-half+2*half*f32(i)/f32(segments))
        erender.debug_line(lines,previous,next,color)
        previous=next
    }
    if edges {erender.debug_line(lines,eye,previous,color)}
}

// The lines go over the lit image: the pass of the mode draws nothing.
@(private)
perception_view_record :: proc(pass:^erender.Pass,user:rawptr) {}
