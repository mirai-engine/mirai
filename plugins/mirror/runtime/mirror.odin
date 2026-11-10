package mirror

import "core:math"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// Mirrors: a flat face that reflects what is in front of it. Each view that
// looks into one from its front gets a nested view for it: the scene from the
// camera of the view mirrored in the plane of the face, drawn in the pixels of
// the face. What the mirror shows is lit, shadowed and filtered once, with the
// rest of the view, instead of by a ray for each of its pixels. Just behind
// the face there is a thin body that reflects: rays, and the views that have
// no nested view left for it, see the mirror through that body.

CAPACITY :: 16
// How far behind the face its body is, so that the mask of the face covers it, and how thick.
BODY_BEHIND :: 0.002
BODY_DEPTH :: 0.01

@(component,description="A flat mirror: the unit square of this entity seen from its +Z; its scale is its size.")
Mirror :: struct {
    ellipse:bool, // the mirror is the ellipse inside the square
    layers:u32,   // the layers of meshes it reflects; 0: every one
}

@(private)
Face :: struct {
    entity:core.Entity,
    to_local:[3][4]f32,        // rows: the world into the space of the face, where it is 1 wide and z is metres in front of it
    place:[3]f32,              // the middle of the face, which to_local moves to zero and the plane goes through
    reflect,previous:mm.Mat4,  // mirrors the world in its plane, in this frame and in the last
    plane:[4]f32,              // facing its front
    corners:[4][3]f32,
    layers:u32,
    ellipse:bool,
}

@(storage,host)
Mirrors_Gpu :: struct {
    pipeline:render.Pipeline, // of the masks, of this frame
    faces:[CAPACITY]Face,
    count:int,
    last:[CAPACITY]Face, // of the last frame
    last_count:int,
}

// The transform that mirrors the world in a plane: xyz its unit normal, w its offset.
reflection :: proc "contextless" (plane:[4]f32) -> (m:mm.Mat4) {
    m=1
    for row in 0..<3 {
        for column in 0..<3 {m[row,column]-=2*plane[row]*plane[column]}
        m[row,3]=-2*plane.w*plane[row]
    }
    return
}

// The mirrors of the world into the frame: the body of each one, and the
// pass that gives every view a nested view for those it looks into.
@(step="render",loops="game editor",after="render_sync")
mirrors_render :: proc(
    state:^Mirrors_Gpu,mirrors:core.Read(Mirror),worlds:core.Read(core.World_Transform),layers:core.Read(render.Layers),
    highlights:core.Read(render.Highlight),outlines:core.Read(render.Outline),hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),assets:^host.Assets,renderer:^render.Renderer,extras:^host.Frame_Extras,frame:core.Frame_Time,
) {
    state.last,state.last_count=state.faces,state.count
    state.count=0
    if renderer==nil || assets==nil || core.count(mirrors)==0 {return}
    // 0 while the shaders in use have no mirrors: the bodies reflect by themselves.
    state.pipeline=render.stage_pipeline(renderer,{stage=.Mask,shader="mirror_mask",name="mirror masks"})
    surface:=host.assets_material_values(assets,0)
    surface.base_color,surface.metallic,surface.roughness={1,1,1},1,0
    material,has_material:=host.assets_material_derive(assets,surface)
    for row in 0..<core.count(mirrors) {
        if state.count>=CAPACITY {break}
        e:=core.entity_at(mirrors,row)
        mirror:=core.at(mirrors,row)
        world,placed:=core.get(worlds,e)
        if !placed || render.is_hidden(hidden,parents,e) {continue}
        shown:=render.drawn_transform(world,frame)
        size:=[2]f32{abs(shown.scale.x),abs(shown.scale.y)}
        to_local,invertible:=mm.transform_inverse_matrix({shown.position,shown.rotation,{size.x,size.y,1}})
        if size.x<1e-5 || size.y<1e-5 || !invertible {continue}
        normal:=mm.quat_rotate(shown.rotation,[3]f32{0,0,1})

        // The cylinder stands along its Y: lying down, its caps are the ellipse.
        behind:=shown.position-normal*(BODY_BEHIND+0.5*BODY_DEPTH)
        body:=mm.Transform{behind,shown.rotation,{size.x,size.y,BODY_DEPTH}}
        if mirror.ellipse {body={behind,shown.rotation*mm.quat_axis_angle({1,0,0},0.5*math.PI),{size.x,BODY_DEPTH,size.y}}}
        if instance,usable:=render.mesh_instance(assets,{shape=mirror.ellipse?.Cylinder:.Cube},mm.transform_matrix(body));usable && has_material {
            instance.material=render.Material_Handle(material)
            instance.object_id,instance.copy_owner=u64(e),base.name_hash("mirror")
            instance.highlight=render.instance_outline(highlights,outlines,e)
            if in_layers,exists:=core.get(layers,e);exists {instance.layers=in_layers.mask}
            render.instance_add(extras,instance)
        }

        face:=&state.faces[state.count]
        face^={entity=e,to_local=mm.mat4_rows(to_local),place=shown.position,layers=mirror.layers,ellipse=mirror.ellipse}
        face.plane={normal.x,normal.y,normal.z,f32(-(f64(normal.x)*f64(shown.position.x)+f64(normal.y)*f64(shown.position.y)+f64(normal.z)*f64(shown.position.z)))}
        face.reflect=reflection(face.plane)
        face.previous=face.reflect
        for last in state.last[:state.last_count] {if last.entity==e {face.previous=last.reflect}}
        for &corner,i in face.corners {
            corner=shown.position+mm.quat_rotate(shown.rotation,[3]f32{(i&1!=0?0.5:-0.5)*size.x,(i&2!=0?0.5:-0.5)*size.y,0})
        }
        state.count+=1
    }
    host.assets_commit(assets)
    if state.count>0 && state.pipeline!=0 {render.frame_pass(renderer,.Mask,mirrors_record,state)}
}

// The space and the plane of a face for a view whose places are relative to
// origin, as the eye of a pass and its shaders are.
@(private)
face_relative :: proc "contextless" (face:^Face,origin:[3]f32) -> (to_local:[3][4]f32,plane:[4]f32) {
    return render.origin_from_place(face.to_local,face.place,origin),render.origin_plane_through(face.plane,face.place,origin)
}

@(private)
mirrors_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Mirrors_Gpu)user
    of :: proc(face:^Face,origin:[3]f32) -> (plane:[4]f32,corners:[4][3]f32,view:render.Nested_View) {
        _,plane=face_relative(face,origin)
        return plane,face.corners,{to_world=face.reflect,previous=face.previous,clip_plane=face.plane,layers=face.layers,opening=face.plane}
    }
    faces:[render.NESTED_VIEW_CAPACITY]render.Nested_Face
    drawn:=render.pass_nested_faces(pass,state.faces[:state.count],of,&faces)
    if len(drawn)==0 {return}
    render.pass_mask_begin(pass,"mirror masks")
    render.pass_pipeline(pass,state.pipeline)
    for item in drawn {
        face:=&state.faces[item.item]
        Params :: struct {to_local:[3][4]f32,index,ellipse,pad0,pad1:u32}
        to_local,_:=face_relative(face,pass.origin)
        params:=Params{to_local=to_local,index=item.index,ellipse=u32(face.ellipse)}
        render.pass_scissor(pass,item.rect)
        if render.pass_params(pass,&params,size_of(Params)) {render.pass_draw(pass,3)}
    }
    render.pass_scissor(pass,{})
    render.pass_end(pass)
}
