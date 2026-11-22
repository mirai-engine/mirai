package render

import "core:math/linalg"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import mm "mirai:std/math"

ARROW_RADIUS :: f32(0.04) // of its length, the radius of its shaft
ARROW_DRAW_CAPACITY :: 64 // arrows the game draws in a frame

@(component,description="Shows a direction of its entity, as where a sun shines or where a spawn point faces, with a solid arrow from its place. The editor draws it, always or while the entity is selected; the game only with In game on.")
Arrow :: struct {
    color:[3]f32 `mirai:"color"`,
    length:f32 `mirai:"min=0,unit=m"`, // at a scale of 1 along its direction
    direction:[3]f32, // in the space of the entity, whose scale stretches the arrow as it does a mesh
    selected:bool,    // the editor draws it only while its entity is selected
    arrives:bool,     // it ends at the place of its entity, as what comes onto it, instead of starting there
    in_game:bool,     // the game draws it too
}

ARROW_DEFAULT :: Arrow{color={1,0.84,0.47},length=1,direction={0,0,-1}}

// The solid of an arrow at the pose of its entity, into a batch of triangles.
arrow_draw :: proc(lines:^Debug_Lines,pose:mm.Transform,arrow:Arrow) {
    along:=linalg.length(arrow.direction)
    if !(along>1e-6) || !(arrow.length>0) {return}
    span:=mm.quat_rotate(pose.rotation,arrow.direction*pose.scale)*(arrow.length/along)
    length:=linalg.length(span)
    color:=[4]f32{arrow.color.r,arrow.color.g,arrow.color.b,1}
    from:=pose.position-span if arrow.arrives else pose.position
    gpu.debug_arrow_solid(lines,from,from+span,color,length*ARROW_RADIUS)
}

@(storage,copy=false)
Arrows_Drawn :: struct {vertices:[]Debug_Vertex}

// The arrows with in_game on that are not hidden.
@(step="render",stage="end",loops="game")
arrows_draw_game :: proc(
    drawn:^Arrows_Drawn,arrows:^core.Table(Arrow,.Read),worlds:^core.Table(core.World_Transform,.Read),
    hidden:^core.Table(Hidden,.Read),parents:^core.Table(core.Parent,.Read),extras:^host.Frame_Extras,problems:^core.Problems,
) {
    lines:Debug_Lines
    for row in 0..<core.count(arrows) {
        arrow:=core.at(arrows,row)
        e:=core.entity_at(arrows,row)
        if !arrow.in_game || is_hidden(hidden,parents,e) {continue}
        world,ok:=core.get(worlds,e)
        if !ok {continue}
        if drawn.vertices==nil {
            vertices,error:=make([]Debug_Vertex,ARROW_DRAW_CAPACITY*gpu.DEBUG_ARROW_VERTICES)
            if error!=nil {
                core.report(problems,e,"render.arrow_memory","out of memory for the vertices of arrows")
                return
            }
            drawn.vertices=vertices
        }
        if lines.vertices==nil {lines=debug_lines_make(drawn.vertices,true,true)}
        arrow_draw(&lines,world.transform,arrow)
    }
    if lines.count>0 {_=host.extras_debug_lines_add(extras,lines)}
    if lines.dropped>0 {
        core.report(problems,core.NONE,"render.arrow_capacity","more arrows are drawn in game than fit in a frame; turn In game off on some")
    }
}
