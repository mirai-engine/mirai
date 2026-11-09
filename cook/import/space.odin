package importer

import "core:math"
import "core:math/linalg"
import "mirai:asset"
import mm "mirai:std/math"

// The coordinates a source is written in. A reader keeps positions,
// transforms and texture coordinates as the source states them and declares
// the space they are in; the import turns everything into the engine's space
// once, so that what it writes is in meters and in the engine's axes:
//
//   each corner a builder takes        position, normal, texture coordinates,
//                                      and the winding of a mirrored space
//   nodes, bones, inverse binds        conjugated by the change of basis
//   clips and lights                   keys, tangents, ranges, sizes
//   the mapping of every material map  conjugated by the flip of v
//
// The engine's space: meters, right-handed, +Y up, +X right, -Z forward for
// every entity and model, v from the top of the image. A change of basis is a
// signed permutation of the axes, so transforms stay exact TRS and a
// mirrored source turns its triangles instead of leaving a negative scale.

Axis :: enum u8 {X,Y,Z,Negative_X,Negative_Y,Negative_Z}

V_Origin :: enum u8 {
    Top,    // v = 0 is the top row of the image
    Bottom, // v = 0 is the bottom row
}

Source_Space :: struct {
    meters_per_unit:f32,
    axes:[3]Axis,      // the axis of the source along the engine's +X, +Y (up) and +Z (the back of a model); distinct
    v_origin:V_Origin,
}

ENGINE_SPACE :: Source_Space{meters_per_unit=1,axes={.X,.Y,.Z},v_origin=.Top}

// The axes of a source that is right-handed, +Y up and whose models face its +Z: half a turn about +Y.
FACING_PLUS_Z :: [3]Axis{.Negative_X,.Y,.Negative_Z}
GLTF_SPACE :: Source_Space{meters_per_unit=1,axes=FACING_PLUS_Z,v_origin=.Top}

axis_opposite :: #force_inline proc "contextless" (axis:Axis) -> Axis {return Axis((int(axis)+3)%6)}

// The change of basis of a space: engine axis i is sign[i] times source axis
// source[i], in meters.
Basis :: struct {
    source:[3]int,
    sign:[3]f32,
    units:f32,
    mirrored:bool, // a reflection: triangles turn and rotations change the sense of their angle
    identity:bool, // nothing to change: what the source states is what the engine reads
}

// The basis of a space; false for axes that repeat or units that are not a positive number.
space_basis :: proc "contextless" (space:Source_Space) -> (b:Basis,ok:bool) {
    units:=space.meters_per_unit
    if !(units>0) || units-units!=0 {return {},false}
    used:[3]bool
    for axis,i in space.axes {
        if axis>max(Axis) {return {},false}
        b.source[i]=int(axis)%3
        b.sign[i]=1 if axis<=.Z else -1
        if used[b.source[i]] {return {},false}
        used[b.source[i]]=true
    }
    b.units=units
    // The sign of the determinant: the parity of the permutation (one axis in
    // place is a swap, none a cycle of three) times the product of the signs.
    kept:=0
    for i in 0..<3 {if b.source[i]==i {kept+=1}}
    b.mirrored=(kept==1)~(b.sign[0]*b.sign[1]*b.sign[2]<0)
    b.identity=units==1 && b.source=={0,1,2} && b.sign=={1,1,1}
    return b,true
}

@(private) FACING_BACK :: [3]f32{0,0,1}
@(private) FACING_RIGHT :: [3]f32{1,0,0}
@(private) FACING_LEFT :: [3]f32{-1,0,0}

// The axes of a source whose rig stands facing an axis other than -Z, turned
// about +Y so that it faces -Z: facing is what the read of those axes found;
// zero leaves them as they are.
space_faced :: proc "contextless" (axes:[3]Axis,facing:[3]f32) -> [3]Axis {
    turned:=axes
    switch facing {
    case FACING_BACK:  turned[0],turned[2]=axis_opposite(axes[0]),axis_opposite(axes[2])
    case FACING_RIGHT: turned[0],turned[2]=axes[2],axis_opposite(axes[0])
    case FACING_LEFT:  turned[0],turned[2]=axis_opposite(axes[2]),axes[0]
    }
    return turned
}

// A facing space_faced can turn to -Z: an axis of the ground other than -Z.
body_turnable :: proc "contextless" (facing:[3]f32) -> bool {
    return facing==FACING_BACK || facing==FACING_RIGHT || facing==FACING_LEFT
}

// The space a file states of itself, for a format whose files each say theirs
// (USD): it replaces Format.space. Before the first builder_triangle.
source_space :: proc(r:^Reader,space:Source_Space) -> bool {
    space:=space
    space.axes=space_faced(space.axes,r.facing)
    basis,ok:=space_basis(space)
    if !ok {return fail(r,.Malformed,"%s: the space of the source needs positive units and three distinct axes",r.file_name)}
    r.space,r.basis=space,basis
    return true
}

space_point :: #force_inline proc "contextless" (b:Basis,p:[3]f32) -> (q:[3]f32) {
    for i in 0..<3 {q[i]=b.sign[i]*p[b.source[i]]*b.units}
    return
}

space_direction :: #force_inline proc "contextless" (b:Basis,d:[3]f32) -> (q:[3]f32) {
    for i in 0..<3 {q[i]=b.sign[i]*d[b.source[i]]}
    return
}

space_scale :: #force_inline proc "contextless" (b:Basis,s:[3]f32) -> (q:[3]f32) {
    for i in 0..<3 {q[i]=s[b.source[i]]}
    return
}

// R' = P R Pᵀ: the axis turned with the basis, the sense of the angle kept unless it mirrors.
space_rotation :: #force_inline proc "contextless" (b:Basis,q:quaternion128) -> quaternion128 {
    v:=space_direction(b,{q.x,q.y,q.z})
    if b.mirrored {v=-v}
    return quaternion(w=q.w,x=v.x,y=v.y,z=v.z)
}

space_transform :: proc "contextless" (b:Basis,t:mm.Transform) -> mm.Transform {
    return {position=space_point(b,t.position),rotation=space_rotation(b,t.rotation),scale=space_scale(b,t.scale)}
}

// C M C⁻¹ of an affine matrix, with C the change of basis.
@(private)
space_matrix :: proc "contextless" (b:Basis,m:matrix[4,4]f32) -> (out:matrix[4,4]f32) {
    for i in 0..<3 {
        for j in 0..<3 {out[i,j]=b.sign[i]*b.sign[j]*m[b.source[i],b.source[j]]}
        out[i,3]=b.sign[i]*m[b.source[i],3]*b.units
        out[3,i]=b.sign[i]*m[3,b.source[i]]
    }
    out[3,3]=m[3,3]
    return
}

// The turn, in the source, that the node of a light takes on the right: every
// format's lights shine toward -Z of their node, and once the node is
// conjugated this one shines toward -Z of the engine. It is the basis itself,
// with x reversed in a mirror. Its children take its transpose on the left.
// x and y of the light stay its x and y, up to their sign.
light_frame :: proc "contextless" (b:Basis) -> (m:matrix[4,4]f32) {
    for i in 0..<3 {m[i,b.source[i]]=b.sign[i]*(-1 if i==0 && b.mirrored else 1)}
    m[3,3]=1
    return
}

// A texture coordinate of the source with v from the top of the image.
@(private)
space_uv :: #force_inline proc "contextless" (space:Source_Space,uv:[2]f32) -> [2]f32 {
    if space.v_origin==.Bottom {return {uv.x,1-uv.y}}
    return uv
}

// Everything the builder did not see, in the engine's space: nodes, bones,
// sockets, inverse binds, clips and lights.
@(private)
space_bake :: proc(r:^Reader) {
    b:=r.basis
    if b.identity {return}
    frame:=light_frame(b)
    for &node in r.nodes {
        _,is_light:=node.light.?
        under_light:=false
        if node.parent>=0 {_,under_light=r.nodes[node.parent].light.?}
        if is_light || under_light {
            local:=mm.transform_matrix(node.transform)
            if is_light {local=local*frame}
            if under_light {local=linalg.transpose(frame)*local}
            if turned,decomposed:=mm.transform_from_matrix(local);decomposed {node.transform=turned}
        }
        node.transform=space_transform(b,node.transform)
        if light,has:=&node.light.?;has {
            light.range*=b.units
            light.size*=b.units
            if radius,sized:=&light.radius.?;sized {radius^*=b.units}
        }
    }
    for &skeleton in r.skeletons {
        for &bone in skeleton.bones {
            bone.translation=space_point(b,bone.translation)
            bone.rotation=space_rotation(b,bone.rotation)
            bone.scale=space_scale(b,bone.scale)
        }
        for &socket in skeleton.sockets {socket.offset=space_transform(b,socket.offset)}
    }
    for &mesh in r.meshes {
        for &joint in mesh.joints {joint.inverse_bind=space_matrix(b,joint.inverse_bind)}
        space_collision(b,&mesh.collision)
    }
    for &clip in r.animations {
        for &track in clip.tracks {
            for &key in track.keys {
                #partial switch track.property {
                case .Position:
                    key.value.xyz=space_point(b,key.value.xyz)
                    key.in_slope.xyz=space_point(b,key.in_slope.xyz)
                    key.out_slope.xyz=space_point(b,key.out_slope.xyz)
                case .Rotation:
                    key.value=space_quaternion_vector(b,key.value)
                    key.in_slope=space_quaternion_vector(b,key.in_slope)
                    key.out_slope=space_quaternion_vector(b,key.out_slope)
                case .Scale:
                    key.value.xyz=space_scale(b,key.value.xyz)
                    key.in_slope.xyz=space_scale(b,key.in_slope.xyz)
                    key.out_slope.xyz=space_scale(b,key.out_slope.xyz)
                }
            }
        }
    }
}

// Colliders of a source in the engine's space. A box keeps its axes, each
// with the size of the source axis it becomes; a capsule, which lies along
// its local Y, turns so that it still lies along the source axis it did.
space_collision :: proc(b:Basis,collision:^Mesh_Collision) {
    if b.identity {return}
    along:=0
    for i in 0..<3 {if b.source[i]==1 {along=i}}
    for &collider in collision.colliders {
        collider.center=space_point(b,collider.center)
        collider.rotation=space_rotation(b,collider.rotation)
        switch collider.kind {
        case .Box: collider.size=space_scale(b,collider.size)*b.units
        case .Sphere: collider.size*=b.units
        case .Capsule:
            collider.size*=b.units
            axis:[3]f32
            axis[along]=1
            collider.rotation=collider.rotation*mm.quat_between({0,1,0},axis)
        case .Hull,.Mesh:
        }
    }
    for &point in collision.points {point=space_point(b,point)}
    if b.mirrored {
        for t in 0..<len(collision.indices)/3 {collision.indices[t*3+1],collision.indices[t*3+2]=collision.indices[t*3+2],collision.indices[t*3+1]}
    }
}

// A rotation key (x, y, z, w), or its tangent: the map of space_rotation is linear in the components.
@(private="file")
space_quaternion_vector :: proc "contextless" (b:Basis,q:[4]f32) -> [4]f32 {
    v:=space_direction(b,q.xyz)
    if b.mirrored {v=-v}
    return {v.x,v.y,v.z,q.w}
}

// The mapping of a map of a source whose v starts at the bottom, as the
// engine reads it: the same transform conjugated by the flip of v, so that
// offset, rotation and uneven scale stay exact. The identity stays the
// identity, with no negative zero.
@(private)
space_map :: proc(space:Source_Space,mapping:^asset.Material_Map) {
    if space.v_origin==.Top {return}
    angle:=mapping.rotation
    mapping.rotation=0-angle
    mapping.offset={mapping.offset.x-mapping.scale.y*math.sin(angle),1-mapping.scale.y*math.cos(angle)-mapping.offset.y}
}

// The scale and offset of a material, applied before its maps, with v from the top.
@(private)
space_material :: proc(space:Source_Space,info:^asset.Material_Info) {
    if space.v_origin==.Top {return}
    info.uv_offset.y=1-info.uv_scale.y-info.uv_offset.y
    for slot in asset.Material_Map_Kind {space_map(space,material_map(info,slot))}
}
