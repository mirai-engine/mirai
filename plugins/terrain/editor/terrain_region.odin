package terrain_editor

import "core:math"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/kit"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:ui"

// Regions of a Heightfield from the tool and the API: a box copied onto the
// same or another terrain (terrain.region), and one half mirrored onto the
// other (terrain.mirror and Mirror in Sculpt), each one step of undo.

Mirror_Settings :: struct {
    axis:int,       // 0: across x, 1: across z
    keep_high:bool, // the half along +axis is kept
    rotate:bool,
    blend:f32,      // metres on each side of the plane
}

Region_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The Heightfield Terrain it copies from"`,
    from:[3]f32 `mirai:"label=A corner of the box it copies, in the world; its x and z"`,
    to:[3]f32 `mirai:"label=The other corner"`,
    at:[3]f32 `mirai:"label=Where the middle of the box goes, in the world; its x and z"`,
    target:editor.Api_Entity_Text `mirai:"text,entity,optional,label=The Heightfield Terrain it goes onto; omitted: the one it copies from"`,
    turn:f32 `mirai:"optional,unit=deg,label=Around y, after mirror"`,
    mirror:bool `mirai:"optional,label=Flips it along its x first"`,
    offset:f32 `mirai:"optional,unit=m,label=Added to its heights"`,
    blend:f32 `mirai:"optional,min=0,unit=m,label=Inside its edges over which it fades into the ground"`,
    way:[8]u8 `mirai:"text,optional,label=both, raise (only raises the ground) or lower (only lowers it)"`,
    layers:bool `mirai:"optional,label=Its painted layers too, onto a terrain with as many"`,
}

Mirror_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Heightfield Terrain"`,
    axis:[4]u8 `mirai:"text,label=x (a plane across x, the half at lower x kept) or z"`,
    at:[3]f32 `mirai:"optional,label=A point of the plane in the world; omitted: the center of the terrain"`,
    keep_high:bool `mirai:"optional,label=Keeps the half at higher x or z and mirrors it onto the other"`,
    rotate:bool `mirai:"optional,label=Turns the kept half around the center instead of mirroring it"`,
    blend:f32 `mirai:"optional,min=0,unit=m,label=On each side of the plane, where both halves mix"`,
}

// The sample of a Heightfield nearest a point of its space, clamped to it.
@(private)
sample_of :: proc(s:^terrain.Source,local:[3]f32) -> [2]int {
    origin:=terrain.source_origin(s)
    return {
        clamp(int(math.round((local.x-origin.x)/s.cell)),0,int(s.samples.x)-1),
        clamp(int(math.round((local.z-origin.z)/s.cell)),0,int(s.samples.z)-1),
    }
}

@(private)
local_of :: proc(tool:^Terrain_Tool,p:[3]f32) -> [3]f32 {return (tool.stroke.to_local*[4]f32{p.x,p.y,p.z,1}).xyz}

// Keeps a change of the source of the stroke as one step of undo.
@(private)
region_commit :: proc(s:^editor.Session,call:^api.Call,tool:^Terrain_Tool,world:core.World_Ref,change:terrain.Change,label:string) {
    stroke:=&tool.stroke
    if change.error!=.None {
        stroke_cancel(tool)
        api.call_failf(call,api.INVALID_PARAMS,"The terrain was not edited: %s",terrain.edit_error_fix(change.error,.Flatten))
        return
    }
    if !change.changed {stroke_cancel(tool);api_changed_write(call,false,0);return}
    stroke.active=true
    stroke_changed(stroke,change)
    stroke_end(s,tool,world,s.app.assets,label=label)
    if stroke.active || stroke.changed {editor.tool_call_fail(s,call,"The change could not be kept");return}
    api_changed_write(call,true,1)
}

@(private)
api_region :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Region_Params)
    way:=terrain.Brush_Way.Both
    switch strings.to_lower(base.text_get(p.way[:]),context.temp_allocator) {
    case "","both":
    case "raise": way=.Up
    case "lower": way=.Down
    case: api.call_fail(call,api.INVALID_PARAMS,"way is both, raise or lower");return
    }
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    if tool.stroke.source.kind!=.Heightfield {api.call_fail(call,api.INVALID_PARAMS,"A region is of a Heightfield Terrain: on a Volume use terrain.edit with add and carve");return}
    from,to:=sample_of(&tool.stroke.source,local_of(tool,p.from)),sample_of(&tool.stroke.source,local_of(tool,p.to))
    region:terrain.Region
    defer terrain.region_destroy(&region)
    if !terrain.source_region_copy(&tool.stroke.source,from,to,&region,context.temp_allocator) {api.call_fail(call,api.INVALID_PARAMS,"The box from from to to holds no sample of the terrain: give corners over it");return}
    copied_scale:=tool.stroke.scale
    if editor.tool_call_given(call,"target") {
        if tool,world,ok=api_terrain(s,call,p.target[:]);!ok {return}
        if tool.stroke.source.kind!=.Heightfield {api.call_fail(call,api.INVALID_PARAMS,"target is not a Heightfield Terrain: a region goes onto a Heightfield");return}
    }
    scale:=tool.stroke.scale
    at:=local_of(tool,p.at)
    // The region keeps its metres in the world on a terrain of another scale.
    region.cell*=copied_scale/scale
    paste:=terrain.Region_Paste{center=at.xz,turn=math.to_radians(p.turn),mirror=p.mirror,offset=p.offset/scale,blend=max(p.blend,0)/scale,way=way,weights=p.layers}
    region_commit(s,call,tool,world,terrain.source_region_paste(&tool.stroke.source,&region,paste),"Paste region")
}

@(private)
api_mirror :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Mirror_Params)
    axis:=-1
    switch strings.to_lower(base.text_get(p.axis[:]),context.temp_allocator) {
    case "x": axis=0
    case "z": axis=1
    case: api.call_fail(call,api.INVALID_PARAMS,"axis is x or z");return
    }
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.stroke.source
    if source.kind!=.Heightfield {api.call_fail(call,api.INVALID_PARAMS,"A mirror is of a Heightfield Terrain");return}
    at:=[2]int{int(source.samples.x)/2,int(source.samples.z)/2}
    if editor.tool_call_given(call,"at") {at=sample_of(source,local_of(tool,p.at))}
    blend:=int(math.round(max(p.blend,0)/tool.stroke.scale/source.cell))
    region_commit(s,call,tool,world,terrain.source_mirror(source,axis,at[axis],p.keep_high,p.rotate,blend),"Mirror terrain")
}

// Mirror in Sculpt of a Heightfield: through its center, as terrain.mirror.
@(private)
mirror_fields :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) {
    ctx:=s.gui.ctx
    m:=&tool.mirror
    kit.section(ctx,"Mirror","",80)
    if kit.property(ctx,"Plane") {kit.tabs(ctx,ui.id(ctx,"mirror_axis"),{"X","Z"},&m.axis)}
    keep:=m.keep_high?1:0
    if kit.property(ctx,"Keep") {if kit.tabs(ctx,ui.id(ctx,"mirror_keep"),{"Lower half","Upper half"},&keep) {m.keep_high=keep==1}}
    if kit.property(ctx,"Turn it") {ui.checkbox(ctx,ui.id(ctx,"mirror_rotate"),&m.rotate)}
    blend:=f64(m.blend)
    if kit.property(ctx,"Blend") {if ui.number_field(ctx,ui.id(ctx,"mirror_blend"),&blend,{width=ui.fixed(FIELD_WIDTH),min=0,max=1000,has_min=true,has_max=true,speed=0.1,unit="m"}).changed {m.blend=f32(blend)}}
    if !ui.button(ctx,ui.id(ctx,"mirror"),{label="Mirror",variant="field",width=-1,center=true}).clicked {return}
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield {return}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return}
    source:=&stroke.source
    at:=[2]int{int(source.samples.x)/2,int(source.samples.z)/2}
    change:=terrain.source_mirror(source,m.axis,at[m.axis],m.keep_high,m.rotate,int(math.round(max(m.blend,0)/stroke.scale/source.cell)))
    if change.error!=.None {edit_error(s,change.error,.Flatten);return}
    if !change.changed {return}
    stroke.active=true
    stroke_changed(stroke,change)
    stroke_end(s,tool,world,assets,label="Mirror terrain")
}
