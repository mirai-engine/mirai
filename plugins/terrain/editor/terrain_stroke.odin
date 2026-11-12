package terrain_editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// Raise and Lower lift the middle of the brush by this part of its radius in
// one pass at full strength.
RAISE_PER_PASS :: f32(0.5)
// A held brush passes over its spot this many times a second.
PASSES_PER_SECOND :: f32(2)
// A drag touches at least every this part of the radius: a fast one leaves no gaps.
STROKE_SPACING :: f32(0.25)
STROKE_TOUCHES_MAX :: 64 // of a frame along a fast drag
RADIUS_MIN :: f32(0.1)
RADIUS_MAX :: f32(500)
RADIUS_STEP :: f32(1.15) // what [ and ] multiply the radius by

// The shapes of Shapes; Selected is a closed mesh of the scene, which a Volume takes as samples.
Shape_Kind :: enum u8 {Sphere,Capsule,Box,Selected}
// What a stroke over a Heightfield keeps of its press: nothing, its Z (it runs along X) or its X.
Stroke_Axis :: enum u8 {Free,X,Z}

// A brush of the Sculpt list; Set height is Flatten to a typed height.
Sculpt_Brush :: struct {kind:terrain.Brush_Kind,level:bool,name:string}

@(rodata) HEIGHTFIELD_BRUSHES := [?]Sculpt_Brush{{.Raise,false,"Raise"},{.Lower,false,"Lower"},{.Smooth,false,"Smooth"},{.Flatten,false,"Flatten"},{.Ramp,false,"Ramp"},{.Flatten,true,"Set height"},{.Terrace,false,"Terrace"},{.Noise,false,"Noise"},{.Erode,false,"Erode"},{.Thermal,false,"Thermal"}}
@(rodata) VOLUME_BRUSHES := [?]Sculpt_Brush{{.Add,false,"Add"},{.Carve,false,"Remove"},{.Raise,false,"Raise"},{.Lower,false,"Lower"},{.Smooth,false,"Smooth"},{.Flatten,false,"Flatten"},{.Flatten,true,"Set height"},{.Noise,false,"Noise"}}
@(rodata) BRUSH_KEYS := [9]core.Key{.One,.Two,.Three,.Four,.Five,.Six,.Seven,.Eight,.Nine}
// The keys the tool takes from the shortcuts of the editor while it is on.
TOOL_KEYS :: core.Keys{.F,.Left_Bracket,.Right_Bracket,.One,.Two,.Three,.Four,.Five,.Six,.Seven,.Eight,.Nine}


@(private)
sculpt_brushes :: proc(kind:terrain.Source_Kind) -> []Sculpt_Brush {
    switch kind {
    case .Heightfield: return HEIGHTFIELD_BRUSHES[:]
    case .Volume:      return VOLUME_BRUSHES[:]
    }
    return nil
}
@(private)
tool_shaping :: proc "contextless" (t:^Terrain_Tool) -> bool {return t.shaping && (t.brush==.Add || t.brush==.Carve)}
@(private)
tool_sculpting :: proc "contextless" (t:^Terrain_Tool) -> bool {return !tool_painting(t) && !tool_holing(t) && !tool_shaping(t)}

// Keeps the brush one the source has: the first of its list otherwise.
@(private)
brush_fit :: proc(tool:^Terrain_Tool,kind:terrain.Source_Kind) {
    switch {
    case tool_painting(tool): return
    case tool_holing(tool): if kind==.Heightfield {return}
    case tool_shaping(tool): if kind==.Volume {return}
    case: for brush in sculpt_brushes(kind) {if brush.kind==tool.brush && brush.level==tool.level {return}}
    }
    tool.brush,tool.level,tool.shaping=sculpt_brushes(kind)[0].kind,false,false
}

// The brush with the key index+1 of the mode it is in, which takes back the
// scene the tool lent to the gizmo.
@(private)
brush_choose :: proc(s:^editor.Session,tool:^Terrain_Tool,index:int) {
    editor.tool_take(s,"terrain")
    switch {
    case tool_painting(tool): if index<2 {tool.brush=index==0?.Paint:.Erase}
    case tool_holing(tool):   if index<2 {tool.brush=index==0?.Hole:.Fill}
    case tool_shaping(tool):  if index<len(Shape_Kind) {tool.shape=Shape_Kind(index)}
    case:
        brushes:=sculpt_brushes(tool.stroke.source.kind)
        if index<len(brushes) {tool.brush,tool.level=brushes[index].kind,brushes[index].level}
    }
}

// What Ctrl turns a brush into.
@(private)
brush_inverse :: proc "contextless" (kind:terrain.Brush_Kind) -> terrain.Brush_Kind {
    #partial switch kind {
    case .Raise:    return .Lower
    case .Lower:    return .Raise
    case .Add:      return .Carve
    case .Carve:    return .Add
    case .Paint:    return .Erase
    case .Erase:    return .Paint
    case .Hole:     return .Fill
    case .Fill:     return .Hole
    }
    return kind
}

// The brush a touch uses: Shift smooths in place of a sculpting brush, Ctrl
// or the eraser of a pen inverts it, and Alt has Raise and Lower of a
// Heightfield stop at the height of the press.
@(private)
brush_held :: proc(tool:^Terrain_Tool,modifiers:ui.Modifiers,eraser:=false) -> (kind:terrain.Brush_Kind,level,capped:bool) {
    kind,level=tool.brush,tool.level
    if tool_sculpting(tool) && kind!=.Ramp && .Shift in modifiers {return .Smooth,false,false}
    if (.Primary in modifiers || eraser) && !level {kind=brush_inverse(kind)}
    capped=(kind==.Raise || kind==.Lower) && tool.stroke.source.kind==.Heightfield && (tool.capped!=(.Alt in modifiers))
    return
}

// Whether strength changes what a touch of the brush does.
@(private)
brush_strong :: proc "contextless" (kind:terrain.Brush_Kind) -> bool {
    #partial switch kind {
    case .Hole,.Fill,.Ramp: return false
    }
    return true
}

// The source as it was before the stroke: touches find the surface on it, so
// what a stroke raises does not move where its next touches land.
@(private)
stroke_original :: proc(tool:^Terrain_Tool) -> ^terrain.Source {
    stroke:=&tool.stroke
    if head:=editor.revision_head(&tool.history,stroke.id,stroke.revision);head!=nil {return head}
    return &stroke.source
}

// A press on the selected terrain: a stroke, or the ramp or shape it
// places. Ctrl and a press with Set height take the height under it instead.
@(private)
stroke_begin :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,input:core.Input,view:core.View) -> bool {
    stroke:=&tool.stroke
    if !stroke_baseline(tool) {stroke_free(tool);editor.notify(s,"The terrain history could not be stored");return false}
    local,normal,ok:=stroke_point(stroke,s.viewport,input.mouse_position)
    if !ok {return false}
    if tool.level && tool_sculpting(tool) && (.Primary in s.gui.ctx.input.modifiers || tool.picking) {tool.height,tool.picking=local.y,false;return false}
    if tool_shaping(tool) && tool.shape==.Selected {return false}
    _,forward:=core.view_ray(view,view.size*0.5)
    stroke.view=-linalg.normalize0((stroke.to_local*[4]f32{forward.x,forward.y,forward.z,0}).xyz)
    stroke.first,stroke.last,stroke.normal=local,local,normal
    // Flatten keeps the height of the press, or the one of Set height.
    stroke.target=local.y
    if tool.level {stroke.target=tool.height}
    if tool_shaping(tool) || tool.brush==.Ramp {pending_begin(tool,local)}
    stroke.active=true
    if editor.revision_applied(&tool.history,stroke.id)==nil {append(&tool.applied,Applied{source=stroke.id,revision=stroke.revision,stamp=stroke.stamp})}
    return true
}

@(private)
stroke_apply :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,input:core.Input,view:core.View,frame:core.Frame_Time) {
    stroke:=&tool.stroke
    kind,level,capped:=brush_held(tool,s.gui.ctx.input.modifiers,input.eraser)
    // As TerraBrush: while held it touches at most BRUSH_RATE times a second
    // with the time it waited, so a second held does the same at any rate.
    stroke.waited+=frame.dt
    if stroke.touched && stroke.waited<1.0/BRUSH_RATE {return}
    share:=(stroke.touched?stroke.waited:1.0/BRUSH_RATE)*PASSES_PER_SECOND
    local,normal,ok:=stroke_aim(tool,s.viewport,input.mouse_position)
    if !ok {stroke.waited=0;return}
    from:=stroke.touched?stroke.last:local
    stroke.touched,stroke.waited=true,0
    stroke.last,stroke.last_normal,stroke.pointer=local,normal,input.mouse_position
    // A fast drag also touches between the last touch and this one, on the
    // surface under each point, and they share the time.
    step:=local-from
    count:=clamp(int(math.ceil(linalg.length(step)/(brush_of(tool).radius/stroke.scale*STROKE_SPACING))),1,STROKE_TOUCHES_MAX)
    for i in 1..<count {
        point:=from+step*(f32(i)/f32(count))
        at,seen:=pending_screen(s,stroke,point)
        if !seen {continue}
        if hit,hit_normal,on:=stroke_under(tool,s.viewport,at);on {
            if stroke.source.kind==.Heightfield {hit.xz=point.xz;hit.y=terrain.source_height(&stroke.source,hit.x,hit.z)}
            stroke_touch(s,tool,world,kind,level,capped,hit,hit_normal,share/f32(count),input.pressure)
        }
    }
    stroke_touch(s,tool,world,kind,level,capped,local,normal,share/f32(count),input.pressure)
}

// Where a held brush touches: under the pointer on the surface as it was
// before the stroke, as Blender's sculpt finds it, carried along its normal
// onto what the stroke raised or lowered. What it raises does not move the
// point toward the view when the pointer moves a little; while it rests, the
// brush keeps working where it last touched. A grid stroke can keep to the X
// or the Z of its press.
@(private)
stroke_aim :: proc(tool:^Terrain_Tool,v:^editor.Viewport,at:[2]f32) -> (point,normal:[3]f32,ok:bool) {
    stroke:=&tool.stroke
    if stroke.touched && at==stroke.pointer {return stroke_carry(tool,stroke.last,stroke.last_normal)}
    point,normal,ok=stroke_under(tool,v,at)
    if !ok || stroke.source.kind!=.Heightfield || !stroke.active {return}
    #partial switch tool.axis {
    case .X: point.z=stroke.first.z
    case .Z: point.x=stroke.first.x
    }
    point.y=terrain.source_height(&stroke.source,point.x,point.z)
    return
}

// The point under a point of the window on the source before the stroke,
// carried onto the surface as it is now.
@(private)
stroke_under :: proc(tool:^Terrain_Tool,v:^editor.Viewport,at:[2]f32) -> (point,normal:[3]f32,ok:bool) {
    point,normal,ok=stroke_point(&tool.stroke,v,at,stroke_original(tool))
    if !ok {return}
    return stroke_carry(tool,point,normal)
}

// A point of the terrain carried along its normal onto the surface as it is
// now: on a grid, its height there.
@(private)
stroke_carry :: proc(tool:^Terrain_Tool,point,normal:[3]f32) -> ([3]f32,[3]f32,bool) {
    point,normal:=terrain.source_carry(&tool.stroke.source,point,normal,brush_of(tool).radius/tool.stroke.scale)
    return point,normal,true
}

// One touch at a point of the terrain with the normal under it: share is the
// part of a pass it makes, pressure that of a pen (1 without one).
@(private)
stroke_touch :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,kind:terrain.Brush_Kind,level,capped:bool,point,normal:[3]f32,share:f32,pressure:f32=1) {
    stroke:=&tool.stroke
    tool.touches+=1
    b:=brush_of(tool)
    radius:=b.radius/stroke.scale
    strength:=clamp(b.strength,0,1)
    if b.pressure {strength*=clamp(pressure,0,1)}
    brush:=brush_make(tool,kind,point,normal)
    brush.capped=capped
    #partial switch kind {
    case .Raise,.Lower,.Noise: brush.amount=strength*radius*RAISE_PER_PASS*share
    case .Erode:               brush.amount=strength*clamp(share*BRUSH_RATE/PASSES_PER_SECOND,0,1)
    case:                      brush.amount=strength>=1?1:1-math.pow(1-strength,share)
    }
    if !(brush.amount>0) {return}
    // Each touch of a spinning alpha takes another turn.
    if b.spin && brush.alpha!=nil {
        r:=mm.rng_make(base.hash_u64(tool.touches))
        brush.turn=mm.random_f32(&r)*math.TAU
    }
    change:=terrain.source_edit(&stroke.source,brush)
    if change.error!=.None {edit_error(s,change.error,brush.kind);return}
    stroke_changed(stroke,change)
}

// The brush of the tool as it stands, for a kind at a point: its shape, its
// filter and what the kind takes besides; amount is the caller's.
@(private)
brush_make :: proc(tool:^Terrain_Tool,kind:terrain.Brush_Kind,point,normal:[3]f32) -> terrain.Brush {
    stroke:=&tool.stroke
    b:=brush_of(tool)
    brush:=terrain.Brush{
        kind=kind,center=point,radius=b.radius/stroke.scale,target=stroke.target,
        layer=u32(tool.layer),falloff=b.falloff,hardness=clamp(b.hardness,0,0.95),
        way=tool.way,interval=max(tool.interval,0.01)/stroke.scale,riser=clamp(tool.riser,0,1),scale=max(tool.noise_scale,0.1)/stroke.scale,
        talus=clamp(tool.talus,math.to_radians(f32(1)),math.to_radians(f32(89))),
        seed=u32(stroke.id[0]),turn=b.turn,
    }
    brush.alpha=alpha_of(tool,b)
    if b.slope_filter {
        low,high:=clamp(min(b.slope.x,b.slope.y),0,math.PI/2),clamp(max(b.slope.x,b.slope.y),0,math.PI/2)
        // A zero slope is no filter for the runtime: the flat alone is a range a little above it.
        brush.slope,brush.slope_invert={low,max(high,low+1e-6)},b.slope_invert
    }
    if kind==.Paint && tool.toward {brush.toward,brush.target=true,clamp(tool.target,0,1)}
    // Noise keeps the seed of its source, so a pass deepens one pattern; the
    // drops of Erode start elsewhere at each touch.
    if kind==.Erode {brush.seed=u32(base.hash_u64(tool.touches))}
    return brush
}

// The number keys choose a brush of the mode and with Shift the mode, [ and ]
// change the radius.
@(private)
terrain_keys :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,input:core.Input) {
    ctx:=s.gui.ctx
    if ctx.edit.id!=0 || s.gui.modal!=.None || ctx.popup.count!=0 {return}
    if ctx.input.modifiers=={.Shift} {
        for key,index in BRUSH_KEYS[:3] {if core.key_pressed(input,key) {mode_set(s,tool,world,assets,index)}}
        return
    }
    if ctx.input.modifiers!={} {return}
    if core.key_pressed(input,.Left_Bracket) {brush_of(tool).radius=max(brush_of(tool).radius/RADIUS_STEP,RADIUS_MIN)}
    if core.key_pressed(input,.Right_Bracket) {brush_of(tool).radius=min(brush_of(tool).radius*RADIUS_STEP,RADIUS_MAX)}
    for key,index in BRUSH_KEYS {if core.key_pressed(input,key) {brush_choose(s,tool,index)}}
}

// F over the terrain begins to drag the radius and Shift F the strength, on
// the plane of the surface under the pointer (level on a grid).
@(private)
adjust_key :: proc(s:^editor.Session,tool:^Terrain_Tool,input:core.Input) -> bool {
    stroke:=&tool.stroke
    point,normal,ok:=stroke_point(stroke,s.viewport,input.mouse_position)
    if !ok {return false}
    if stroke.source.kind==.Heightfield {normal={0,1,0}}
    world:=(stroke.to_world*[4]f32{point.x,point.y,point.z,1}).xyz
    up:=linalg.normalize0((stroke.to_world*[4]f32{normal.x,normal.y,normal.z,0}).xyz)
    b:=brush_of(tool)
    return editor.brush_adjust_key(s,&tool.adjust,input,world,up,b.radius,b.strength)
}

@(private)
adjust_frame :: proc(s:^editor.Session,tool:^Terrain_Tool,input:core.Input) {
    b:=brush_of(tool)
    if tool.stroke.id=={} {tool.adjust={};return}
    editor.brush_adjust_frame(s,&tool.adjust,input,&b.radius,&b.strength,RADIUS_MIN,RADIUS_MAX)
}
