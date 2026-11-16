package importer

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

GRIP_PARTS :: [2]anim.Body_Part{.Hand_L,.Hand_R}
GRIP_NAMES :: [2]string{"grip_left","grip_right"}
GRIP_MIN_POINTS :: 16
GRIP_SLICE :: 0.1 // half the width of a slice across the palm, of the length from wrist to fingertips

// Where a hand holds, in the space of its bone, from its vertices in that space: on the palm,
// across it where it is lowest between a quarter and a half of the way from the wrist (the bone
// origin) to the fingertips. X runs along the hand toward the fingertips, Y across the palm (the
// held axis) and Z out of the palm, so what is held of radius r goes at z=r.
hand_grip :: proc(points:[]mm.Vec3,allocator:=context.temp_allocator) -> (grip:mm.Transform,ok:bool) {
    if len(points)<GRIP_MIN_POINTS {return}
    center:mm.Vec3
    for p in points {center+=p}
    center/=f32(len(points))
    spread:matrix[3,3]f32
    for p in points {spread+=linalg.outer_product(p-center,p-center)}
    // The length of the hand is the main axis of its spread, away from the wrist.
    along:=linalg.normalize0(mm.Vec3{1,.7,.4})
    for _ in 0..<128 {along=linalg.normalize0(spread*along)}
    if along=={} {return}
    if linalg.dot(along,center)<0 {along=-along}
    hi:=-f32(math.F32_MAX)
    for p in points {hi=max(hi,linalg.dot(p-center,along))}
    wrist:=-linalg.dot(center,along)
    length:=hi-wrist
    if !(length>0) {return}
    // The palm is the stretch from a fifth to a half of the way to the fingertips. A principal axis
    // of the whole hand does not find its normal (with bent fingers width and thickness spread
    // alike), nor does the offset of the fingertips (it leans toward the long fingers): the normal
    // is the direction across the hand in which the palm is thinnest.
    in_palm :: proc(u,wrist,length:f32) -> bool {return u>wrist+.2*length && u<wrist+.5*length}
    first:=linalg.normalize0(linalg.cross(along,mm.Vec3{0,0,1} if abs(along.z)<.9 else mm.Vec3{1,0,0}))
    second:=linalg.cross(along,first)
    values,error:=make([dynamic]f32,0,len(points),allocator)
    if error!=nil {return}
    defer delete(values)
    normal:mm.Vec3
    thinnest:=f32(math.F32_MAX)
    for step in 0..<180 {
        angle:=f32(step)*math.PI/180
        direction:=first*math.cos(angle)+second*math.sin(angle)
        clear(&values)
        for p in points {if in_palm(linalg.dot(p-center,along),wrist,length) {append(&values,linalg.dot(p-center,direction))}}
        if len(values)<GRIP_MIN_POINTS {return}
        slice.sort(values[:])
        // Between the tenth and ninetieth percentiles, so that the thumb does not count.
        thickness:=values[len(values)*9/10]-values[len(values)/10]
        if thickness<thinnest {normal,thinnest=direction,thickness}
    }
    // The normal points to the side the fingers droop toward.
    palm,fingers:f32
    palm_count,finger_count:int
    for p in points {
        u:=linalg.dot(p-center,along)
        if in_palm(u,wrist,length) {palm+=linalg.dot(p-center,normal);palm_count+=1}
        if u>wrist+.75*length {fingers+=linalg.dot(p-center,normal);finger_count+=1}
    }
    if palm_count==0 || finger_count==0 || normal=={} {return}
    if fingers/f32(finger_count)<palm/f32(palm_count) {normal=-normal}
    across:=linalg.cross(normal,along)
    radius:=GRIP_SLICE*length
    slot,height:=f32(0),f32(math.F32_MAX)
    for step in 0..=24 {
        u:=wrist+length*(.25+.25*f32(step)/24)
        top:=-f32(math.F32_MAX)
        for p in points {if abs(linalg.dot(p-center,along)-u)<radius {top=max(top,linalg.dot(p-center,normal))}}
        if top> -f32(math.F32_MAX) && top<height {slot,height=u,top}
    }
    if height==f32(math.F32_MAX) {return}
    position:=center+along*slot+normal*height
    basis:=matrix[3,3]f32{along.x,across.x,normal.x,along.y,across.y,normal.y,along.z,across.z,normal.z}
    return {position,mm.quat_from_mat3(basis),{1,1,1}},true
}

// The grip socket of a hand bone of a skeleton of the model, measured on the vertices its meshes
// skin at least half to the hand and the bones under it (its fingers). Its scale undoes that of
// the bone at rest, so what hangs from it is in meters. found is false, with no error, when no
// mesh skins the skeleton.
hand_grip_socket :: proc(model:^Imported_Model,skeleton,hand:int,name:string) -> (socket:asset.Skeleton_Socket,found:bool,error:Error) {
    if skeleton<0 || skeleton>=len(model.skeletons) {return {},false,error_make(.Malformed,"%s: there is no skeleton %d",model.source,skeleton)}
    bones:=model.skeletons[skeleton].bones
    if hand<0 || hand>=len(bones) {return {},false,error_make(.Malformed,"%s: skeleton %s has no bone %d",model.source,model.skeletons[skeleton].name,hand)}
    bone_name:=base.text_get(bones[hand].name[:])
    out_of_memory :: proc(model:^Imported_Model,name,bone:string) -> Error {return error_make(.Limit,"%s: there is no memory left to measure %s on hand %s",model.source,name,bone)}
    under,under_error:=make([]bool,len(bones),context.temp_allocator)
    if under_error!=nil {return {},false,out_of_memory(model,name,bone_name)}
    under[hand]=true
    for &bone,i in bones[hand+1:] {if bone.parent>=0 && int(bone.parent)<hand+1+i {under[hand+1+i]=under[bone.parent]}}
    points:=make([dynamic]mm.Vec3,context.temp_allocator)
    skinned:=false
    for &mesh in model.meshes {
        if mesh.skeleton!=skeleton || len(mesh.joints)==0 || len(mesh.skin)!=len(mesh.vertices) {continue}
        skinned=true
        held,held_error:=make([]bool,len(mesh.joints),context.temp_allocator)
        if held_error!=nil {return {},false,out_of_memory(model,name,bone_name)}
        bind:=-1
        for joint,j in mesh.joints {
            if int(joint.node)>=len(bones) {continue}
            held[j]=under[joint.node]
            if int(joint.node)==hand {bind=j}
        }
        if bind<0 {continue}
        inverse_bind:=mesh.joints[bind].inverse_bind
        for skin,v in mesh.skin {
            weight:=0
            for k in 0..<8 {if int(skin.joints[k])<len(held) && held[skin.joints[k]] {weight+=int(skin.weights[k])}}
            if weight<128 {continue}
            p:=mesh.vertices[v].position
            local:=(inverse_bind*[4]f32{p.x,p.y,p.z,1}).xyz
            if math.is_nan(local.x+local.y+local.z) || math.is_inf(local.x+local.y+local.z) {continue}
            if _,appended:=append(&points,local);appended!=nil {return {},false,out_of_memory(model,name,bone_name)}
        }
    }
    if !skinned {return {},false,{}}
    if len(points)<GRIP_MIN_POINTS {return {},false,error_make(.Unsupported,"%s: hand %s has %d vertices skinned at least half to it or its fingers, and %s needs %d; skin the hand to its bone, or add the socket to the .skeleton by hand",model.source,bone_name,len(points),name,GRIP_MIN_POINTS)}
    grip,measured:=hand_grip(points[:])
    if !measured {return {},false,error_make(.Unsupported,"%s: the vertices of hand %s do not show a palm to place %s on; add the socket to the .skeleton by hand",model.source,bone_name,name)}
    rest:=mm.TRANSFORM_IDENTITY
    for at:=i32(hand);at>=0;at=bones[at].parent {
        b:=bones[at]
        rest=mm.transform_compose({b.translation,b.rotation,b.scale},rest)
        if b.parent>=at {break}
    }
    scale:=rest.scale
    if scale.x==0 || scale.y==0 || scale.z==0 {return {},false,error_make(.Malformed,"%s: hand %s has a zero scale at rest",model.source,bone_name)}
    socket={bone=bones[hand].path,offset={grip.position,grip.rotation,{1/scale.x,1/scale.y,1/scale.z}}}
    base.text_set(socket.name[:],name)
    return socket,true,{}
}
