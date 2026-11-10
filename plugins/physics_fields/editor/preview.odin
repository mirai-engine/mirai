package physics_fields_editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import mm "mirai:std/math"
import fields "plugins:physics_fields/runtime"

FIELD_PREVIEW_CAPACITY :: 8192
FIELD_PREVIEW_SEGMENTS :: 32

@(storage)
Physics_Field_Preview :: struct {
    vertices:[FIELD_PREVIEW_CAPACITY]erender.Debug_Vertex,
    source:core.World_Id, // the World it was drawn from
    selection_serial:u64,
    versions:[6]u64,
    count,dropped:int,
    ready:bool,
}

@(private)
field_preview_arrow :: proc(lines:^erender.Debug_Lines,from,to:mm.Vec3,color:mm.Vec4) {
    span:=to-from
    length:=linalg.length(span)
    if !(length>1e-5) || math.is_inf(length) {return}
    direction:=span/length
    side:=linalg.normalize0(linalg.cross(direction,mm.Vec3{0,1,0} if abs(direction.y)<.9 else mm.Vec3{1,0,0}))
    up:=linalg.cross(direction,side)
    head:=length*.2
    base:=to-direction*head
    erender.debug_line(lines,from,to,color)
    for offset in ([4]mm.Vec3{side,-side,up,-up}) {erender.debug_line(lines,to,base+offset*head*.5,color)}
}

@(private)
// on: the field is turned on; off, it is drawn gray.
field_preview_draw :: proc(lines:^erender.Debug_Lines,field:fields.Physics_Field,pose:mm.Transform,on:=true) {
    if field.shape>.Plane || field.direction>.Directional {return}
    scale:=linalg.abs(pose.scale)
    radius:=field.radius*max(scale.x,scale.y,scale.z)
    half:=field.half_extents*scale
    switch field.shape {
    case .Sphere:
        if !(radius>0) || math.is_inf(radius) {return}
    case .Box,.Plane:
        for extent in half {if !(extent>0) || math.is_inf(extent) {return}}
    }
    needed:=FIELD_PREVIEW_SEGMENTS*6 if field.shape==.Sphere else 24
    if field.shape==.Plane {needed+=4}
    needed+=60 if field.direction==.Radial && field.shape!=.Plane else 10
    if len(lines.vertices)-lines.count<needed {lines.dropped+=needed/2;return}
    region_color:=mm.Vec4{1,.65,.15,.9} if on else mm.Vec4{.55,.55,.55,.7}
    arrow_color:=mm.Vec4{1,.9,.3,1} if on && field.force!=0 else mm.Vec4{.65,.65,.65,.8}
    if field.shape==.Sphere {erender.debug_sphere(lines,pose.position,radius,region_color,FIELD_PREVIEW_SEGMENTS)}
    else {erender.debug_box_transformed(lines,mm.transform_matrix({pose.position,pose.rotation,{1,1,1}}),-half,half,region_color)}
    sign:=f32(-1) if field.force<0 else f32(1)
    // The plane is the +Y face: crossed, with the arrow of a radial field along its normal up to it.
    if field.shape==.Plane {
        corner :: proc(pose:mm.Transform,half:mm.Vec3,x,z:f32) -> mm.Vec3 {return pose.position+mm.quat_rotate(pose.rotation,mm.Vec3{x*half.x,half.y,z*half.z})}
        erender.debug_line(lines,corner(pose,half,-1,-1),corner(pose,half,1,1),region_color)
        erender.debug_line(lines,corner(pose,half,-1,1),corner(pose,half,1,-1),region_color)
        if field.direction==.Radial {
            face:=corner(pose,half,0,0)
            field_preview_arrow(lines,pose.position if sign>0 else face,face if sign>0 else pose.position,arrow_color)
            return
        }
    }
    if field.direction==.Directional {
        local:=linalg.normalize0(field.vector)
        direction:=mm.quat_rotate(pose.rotation,local)*sign
        length:=radius
        if field.shape!=.Sphere {
            length=max(half.x,half.y,half.z)*2
            for extent,axis in half {if abs(local[axis])>1e-6 {length=min(length,extent/abs(local[axis]))}}
        }
        field_preview_arrow(lines,pose.position,pose.position+direction*length,arrow_color)
        return
    }
    for axis in 0..<3 {
        extent:=radius if field.shape==.Sphere else half[axis]
        for side in ([2]f32{-1,1}) {
            local:mm.Vec3;local[axis]=side
            direction:=mm.quat_rotate(pose.rotation,local)
            inner:=pose.position+direction*extent*.25
            outer:=pose.position+direction*extent*.75
            field_preview_arrow(lines,inner if sign>0 else outer,outer if sign>0 else inner,arrow_color)
        }
    }
}

@(step="frame")
physics_fields_preview :: proc(
    s:^editor.Session,preview:^Physics_Field_Preview,id:core.World_Id,
    regions:core.Read(fields.Physics_Field),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),extras:^host.Frame_Extras,
) {
    if editor.playing(s) && !editor.simulating(s) || s.selection==nil || len(s.selection.entities)==0 {
        preview.ready=false
        preview.count,preview.dropped=0,0
        return
    }
    versions:=[6]u64{core.version(regions),core.layout(regions),core.version(transforms),core.layout(transforms),core.version(parents),core.layout(parents)}
    lines:=erender.debug_lines_make(preview.vertices[:],depth_test=false)
    if !preview.ready || preview.source!=id || preview.selection_serial!=s.selection.serial || preview.versions!=versions {
        for entity in s.selection.entities {
            on,_,present:=core.raw_state(core.raw(regions.table),entity)
            if !present {continue}
            field:=regions.table.values[core.raw_row(core.raw(regions.table),entity)]
            pose,placed:=core.world_of(transforms,parents,entity)
            if placed {field_preview_draw(&lines,field,pose,on)}
        }
        preview.source,preview.selection_serial,preview.versions=id,s.selection.serial,versions
        preview.count,preview.dropped,preview.ready=lines.count,lines.dropped,true
    }
    lines.count,lines.dropped=preview.count,preview.dropped
    if lines.count>0 {host.extras_debug_lines_add(extras,lines)}
}
