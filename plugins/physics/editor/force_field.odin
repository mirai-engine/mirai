package physics_editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

FORCE_PREVIEW_CAPACITY :: 2048
FORCE_ARROW_LENGTH :: f32(2) // m, in a volume without a size: a plane, the whole world

// Where the selected Force_Field rows push: arrows over the scene, in Edit
// and in Simulate. The region is the Volume of the entity, which the editor
// draws for whatever is in it.
@(storage)
Force_Field_Preview :: struct {
    vertices:[FORCE_PREVIEW_CAPACITY]erender.Debug_Vertex,
    source:core.World_Id, // the World it was drawn from
    selection_serial:u64,
    versions:[8]u64,
    count,dropped:int,
    ready:bool,
}

@(private)
force_arrow :: proc(lines:^erender.Debug_Lines,from,to:mm.Vec3,color:mm.Vec4) {
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

// The arrows of a field in a volume placed at pose: one along its direction,
// or along the up of a plane, or six away from the center of a box or a
// sphere; reversed by a negative force. on: the field is turned on; off, or
// without force, they are gray. Arrows that do not fit are counted whole.
@(private)
force_field_arrows :: proc(lines:^erender.Debug_Lines,field:phys.Force_Field,area:volume.Volume,pose:mm.Transform,on:=true) {
    if !volume.valid(area,pose) {return}
    scale:=linalg.abs(pose.scale)
    reach:=mm.Vec3{FORCE_ARROW_LENGTH,FORCE_ARROW_LENGTH,FORCE_ARROW_LENGTH}
    #partial switch area.shape {
    case .Sphere: reach=area.extents.x*max(scale.x,scale.y,scale.z)
    case .Box:    reach=area.extents*scale
    }
    along:=linalg.normalize0(field.along)
    radial:=along=={} && (area.shape==.Sphere || area.shape==.Box)
    needed:=60 if radial else 10
    if len(lines.vertices)-lines.count<needed {lines.dropped+=needed/2;return}
    color:=mm.Vec4{1,.9,.3,1} if on && field.force!=0 else mm.Vec4{.65,.65,.65,.8}
    sign:=f32(-1) if field.force<0 else f32(1)
    if !radial {
        if along=={} {along={0,1,0}}
        length:=max(reach.x,reach.y,reach.z)*2
        for extent,axis in reach {if abs(along[axis])>1e-6 {length=min(length,extent/abs(along[axis]))}}
        force_arrow(lines,pose.position,pose.position+mm.quat_rotate(pose.rotation,along)*sign*length,color)
        return
    }
    for axis in 0..<3 {
        for side in ([2]f32{-1,1}) {
            local:mm.Vec3;local[axis]=side
            direction:=mm.quat_rotate(pose.rotation,local)
            inner:=pose.position+direction*reach[axis]*.25
            outer:=pose.position+direction*reach[axis]*.75
            force_arrow(lines,inner if sign>0 else outer,outer if sign>0 else inner,color)
        }
    }
}

@(step="frame",after="editor_tools")
force_field_preview :: proc(
    s:^editor.Session,preview:^Force_Field_Preview,id:core.World_Id,
    fields:core.Read(phys.Force_Field),volumes:core.Read(volume.Volume),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),extras:^host.Frame_Extras,
) {
    if editor.playing(s) && !editor.simulating(s) || s.selection==nil || len(s.selection.entities)==0 || fields.table==nil {
        preview.ready=false
        preview.count,preview.dropped=0,0
        return
    }
    versions:=[8]u64{core.version(fields),core.layout(fields),core.version(volumes),core.layout(volumes),core.version(transforms),core.layout(transforms),core.version(parents),core.layout(parents)}
    lines:=erender.debug_lines_make(preview.vertices[:],depth_test=false)
    if !preview.ready || preview.source!=id || preview.selection_serial!=s.selection.serial || preview.versions!=versions {
        for entity in s.selection.entities {
            on,_,present:=core.raw_state(core.raw(fields.table),entity)
            if !present {continue}
            field:=fields.table.values[core.raw_row(core.raw(fields.table),entity)]
            pose,placed:=core.world_of(transforms,parents,entity)
            area,_:=core.get(volumes,entity)
            if placed {force_field_arrows(&lines,field,area,pose,on)}
        }
        preview.source,preview.selection_serial,preview.versions=id,s.selection.serial,versions
        preview.count,preview.dropped,preview.ready=lines.count,lines.dropped,true
    }
    lines.count,lines.dropped=preview.count,preview.dropped
    if lines.count>0 {host.extras_debug_lines_add(extras,lines)}
}
