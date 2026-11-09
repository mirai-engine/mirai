package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file") DEG :: f32(RAD_PER_DEG)

test_close :: proc(a,b:f32,tolerance:f32=1e-4) -> bool {return abs(a-b)<=tolerance}
test_close3 :: proc(a,b:Vec3,tolerance:f32=1e-4) -> bool {return linalg.length(a-b)<=tolerance}
test_close_mat4 :: proc(a,b:Mat4,tolerance:f32=1e-4) -> bool {
    for row in 0..<4 {for column in 0..<4 {if abs(a[row,column]-b[row,column])>tolerance {return false}}}
    return true
}
test_close_mat3 :: proc(a,b:Mat3,tolerance:f32=1e-4) -> bool {
    for row in 0..<3 {for column in 0..<3 {if abs(a[row,column]-b[row,column])>tolerance {return false}}}
    return true
}
// Two quaternions are the same rotation when they are equal or opposite.
test_same_rotation :: proc(a,b:Quat,tolerance:f32=1e-4) -> bool {return abs(abs(linalg.dot(a,b))-1)<=tolerance}
// A rotation must preserve edge lengths and right angles.
test_shape :: proc(t:^testing.T,m:Mat4,size:Vec3,loc:=#caller_location) {
    axes:[3]Vec3
    for k in 0..<3 {
        unit:Vec3;unit[k]=1
        axes[k]=mat4_vector(m,unit)
        testing.expectf(t,abs(linalg.length(axes[k])-abs(size[k]))<2e-3,"edge %d: %v, expected %v",k,linalg.length(axes[k]),abs(size[k]),loc=loc)
        axes[k]=linalg.normalize0(axes[k])
    }
    for k in 0..<3 {testing.expect(t,abs(linalg.dot(axes[k],axes[(k+1)%3]))<1e-4,"Edges stay perpendicular",loc=loc)}
}
// The rotation matrix of the previous engine, from Euler angles in degrees.
test_legacy_rotation :: proc(degrees:Vec3) -> Mat3 {
    r:=degrees*DEG
    sx,cx:=math.sin(r.x),math.cos(r.x)
    sy,cy:=math.sin(r.y),math.cos(r.y)
    sz,cz:=math.sin(r.z),math.cos(r.z)
    m:Mat3
    m[0,0]=cz*cy;m[0,1]=cz*sy*sx-sz*cx;m[0,2]=cz*sy*cx+sz*sx
    m[1,0]=sz*cy;m[1,1]=sz*sy*sx+cz*cx;m[1,2]=sz*sy*cx-cz*sx
    m[2,0]=-sy;m[2,1]=cy*sx;m[2,2]=cy*cx
    return m
}
test_trs :: proc(position,degrees,scale:Vec3) -> Transform {return transform_from_euler(position,degrees*DEG,scale)}

@(test)
transform_matrix_is_translation_times_rotation_z_y_x_times_scale :: proc(t:^testing.T) {
    angles:=[?]Vec3{{},{90,0,0},{0,90,0},{0,0,90},{33,-71,128},{-190,45,720},{12.5,0.25,-0.75}}
    for degrees in angles {
        position,scale:=Vec3{1.5,-2,3},Vec3{2,0.5,-3}
        r:=degrees*DEG
        x:=linalg.matrix4_rotate_f32(r.x,{1,0,0});y:=linalg.matrix4_rotate_f32(r.y,{0,1,0});z:=linalg.matrix4_rotate_f32(r.z,{0,0,1})
        expected:=linalg.matrix4_translate_f32(position)*z*y*x*linalg.matrix4_scale_f32(scale)
        actual:=transform_matrix(test_trs(position,degrees,scale))
        for row in 0..<4 {for column in 0..<4 {
            testing.expectf(t,abs(expected[row,column]-actual[row,column])<1e-4,"rotation %v: element %d,%d is %v, expected %v",degrees,row,column,actual[row,column],expected[row,column])
        }}
        testing.expect(t,test_close_mat3(quat_to_mat3(quat_from_euler(r)),test_legacy_rotation(degrees)),"The rotation matches the legacy matrix")
    }
}

@(test)
euler_angles_round_trip_through_a_rotation :: proc(t:^testing.T) {
    for degrees in ([3]Vec3{{10,20,30},{-45,80,170},{90,-30,0}}) {
        q:=quat_from_euler(degrees*DEG)
        back:=quat_to_euler(q)
        testing.expect(t,test_close_mat3(quat_to_mat3(q),quat_to_mat3(quat_from_euler(back))))
        testing.expect(t,test_close3(back,degrees*DEG),"Angles within a quarter turn of Y come back as they were")
    }
    near:=euler_near(Vec3{0,0,-170}*DEG,Vec3{0,0,175}*DEG)
    testing.expect(t,test_close(near.z,190*DEG),"Angles stay continuous across half a turn")
}

@(test)
euler_closest_reads_back_the_angle_that_was_typed :: proc(t:^testing.T) {
    // A Y of 100 degrees is also written 180, 80, 180: that is the triple the conversion returns.
    typed:=Vec3{0,100,0}*DEG
    raw:=quat_to_euler(quat_from_euler(typed))
    testing.expectf(t,test_close3(raw,Vec3{180,80,180}*DEG,1e-3),"raw angles: %v",raw*f32(DEG_PER_RAD))
    testing.expect(t,test_close3(euler_closest(raw,typed),typed,1e-3))
    // Dragging Y from 80 to 110 never jumps to the other triple.
    shown:=Vec3{0,80,0}*DEG
    for degrees:=f32(81);degrees<=110;degrees+=1 {
        shown=euler_closest(quat_to_euler(quat_from_euler({0,degrees*DEG,0})),shown)
        if !test_close3(shown,{0,degrees*DEG,0},1e-3) {testing.expectf(t,false,"%v degrees shown as %v",degrees,shown*f32(DEG_PER_RAD));break}
    }
    // With Y at a quarter turn X and Z merge: X comes back as 0 and the rotation is the same.
    gimbal:=quat_from_euler(Vec3{25,90,40}*DEG)
    angles:=quat_to_euler(gimbal)
    testing.expect_value(t,angles.x,f32(0))
    testing.expect(t,test_same_rotation(quat_from_euler(angles),gimbal,1e-3))
}

@(test)
transform_compose_places_children_through_parent_rotation_and_scale :: proc(t:^testing.T) {
    parent:=test_trs({5,0,0},{0,90,0},{2,2,2})
    world:=transform_compose(parent,test_trs({1,2,3},{},{1,1,1}))
    testing.expectf(t,test_close3(world.position,{11,4,-2}),"world position: %v",world.position)
    testing.expect(t,test_close3(quat_to_euler(world.rotation),Vec3{0,90,0}*DEG))
    testing.expect(t,test_close3(world.scale,{2,2,2}))
    // Three levels: a scaled root, a middle and a leaf.
    root:=test_trs({3,0,0},{},{2,2,2})
    middle:=test_trs({0,2,0},{},{1,1,1})
    leaf:=test_trs({0,0,1},{},{1,1,1})
    testing.expect(t,test_close3(transform_compose(transform_compose(root,middle),leaf).position,{3,4,2}))
    middle.position={0,3,0}
    testing.expect(t,test_close3(transform_compose(transform_compose(root,middle),leaf).position,{3,6,2}))
    chain:=transform_compose(transform_compose(test_trs({1,0,0},{},{2,2,2}),test_trs({0,1,0},{},{1,1,1})),test_trs({0,0,3},{},{1,1,1}))
    testing.expect(t,test_close3(chain.position,{1,2,6}))
    testing.expect_value(t,transform_compose(TRANSFORM_IDENTITY,parent),parent)
    relative:=test_trs({2,1,-3},{10,20,30},{0.5,2,1})
    composed:=transform_compose(parent,relative)
    testing.expect(t,test_close3(composed.scale,{1,4,2}))
    testing.expect(t,test_close3(composed.position,transform_point(parent,relative.position)))
    testing.expect(t,test_close_mat3(quat_to_mat3(composed.rotation),test_legacy_rotation({0,90,0})*test_legacy_rotation({10,20,30})))
}

@(test)
transform_relative_keeps_the_world_transform_when_reparenting :: proc(t:^testing.T) {
    parent:=test_trs({5,0,0},{0,90,0},{2,2,2})
    local,ok:=transform_relative(test_trs({0,4,-2},{0,90,0},{2,2,2}),parent)
    testing.expect(t,ok)
    testing.expectf(t,test_close3(local.position,{1,2,-2.5}),"stored position: %v",local.position)
    testing.expect(t,test_close3(local.scale,{1,1,1}))
    testing.expect(t,test_same_rotation(local.rotation,QUAT_IDENTITY))
    // An absolute Y of 100 degrees under a parent turned 30 is stored as 70.
    turned:=test_trs({5,0,0},{0,30,0},{1,1,1})
    local,ok=transform_relative(test_trs({1,2,3},{0,100,0},{1,1,1}),turned)
    testing.expect(t,ok)
    testing.expectf(t,test_close3(quat_to_euler(local.rotation),Vec3{0,70,0}*DEG,1e-3),"stored rotation: %v",quat_to_euler(local.rotation)*f32(DEG_PER_RAD))
    // A wall with uneven scale and a lamp that keeps its complete world transform under it.
    wall:=test_trs({5,0,0},{15,30,10},{0.25,8,3})
    lamp:=test_trs({1,2,3},{10,20,30},{0.4,0.6,0.8})
    local,ok=transform_relative(lamp,wall)
    testing.expect(t,ok)
    after:=transform_compose(wall,local)
    testing.expect(t,test_close_mat4(transform_matrix(after),transform_matrix(lamp)),"Parenting keeps the complete world transform")
    testing.expect(t,test_close3(after.position,{1,2,3}))
}

@(test)
transform_relative_rejects_a_parent_with_a_collapsed_axis :: proc(t:^testing.T) {
    child:=test_trs({1,2,3},{10,20,30},{1,1,1})
    for scale in ([3]Vec3{{0,1,1},{1,0,1},{1,1,0}}) {
        local,ok:=transform_relative(child,test_trs({},{},scale))
        testing.expect(t,!ok)
        testing.expect_value(t,local,TRANSFORM_IDENTITY)
        _,ok=transform_inverse(test_trs({},{},scale))
        testing.expect(t,!ok)
        _,ok=transform_inverse_matrix(test_trs({},{},scale))
        testing.expect(t,!ok)
    }
    _,ok:=transform_relative(child,test_trs({},{},{-1,1e-3,5}))
    testing.expect(t,ok,"Negative and small scales are fine")
}

@(test)
transform_compose_keeps_shape_under_uneven_scale :: proc(t:^testing.T) {
    // 70 levels, each turned one degree, under a root with uneven, mirrored scale.
    world:=test_trs({0.1,0.2,-0.1},{},{-2,3,0.5})
    for level in 1..<70 {
        scale:=Vec3{0.2,0.4,0.8} if level==69 else Vec3{1,1,1}
        world=transform_compose(world,test_trs({0.1,0.2,-0.1},{0,1,0},scale))
    }
    test_shape(t,transform_matrix(world),{0.4,1.2,0.4})
    testing.expect(t,test_close3(world.scale,{-0.4,1.2,0.4}))
    // Under the wall, any rotation of the lamp keeps its dimensions and right angles.
    wall:=test_trs({5,0,0},{15,30,10},{0.25,8,3})
    lamp,_:=transform_relative(test_trs({1,2,3},{10,20,30},{0.4,0.6,0.8}),wall)
    for degrees in ([4]Vec3{{130,0,0},{0,130,0},{0,0,130},{-75,200,33}}) {
        lamp.rotation=quat_from_euler(degrees*DEG)
        placed:=transform_compose(wall,lamp)
        test_shape(t,transform_matrix(placed),{0.4,0.6,0.8})
        testing.expect(t,test_close3(placed.position,{1,2,3}),"Rotation keeps the origin")
    }
    // The product of the two affine matrices shears the same lamp.
    sheared:=transform_matrix(wall)*transform_matrix(lamp)
    x,y:=linalg.normalize(mat4_vector(sheared,{1,0,0})),linalg.normalize(mat4_vector(sheared,{0,1,0}))
    testing.expect(t,abs(linalg.dot(x,y))>0.05,"The affine product is what the composition avoids")
}

@(test)
transform_from_matrix_recovers_position_rotation_and_scale :: proc(t:^testing.T) {
    for source in ([4]Transform{test_trs({1,2,3},{10,20,30},{2,3,4}),test_trs({-4,0,9},{-45,80,170},{0.5,0.5,0.5}),test_trs({},{90,-30,0},{1,7,1}),test_trs({0,1,0},{12,95,-200},{3,1,2})}) {
        m:=transform_matrix(source)
        back,ok:=transform_from_matrix(m)
        testing.expect(t,ok)
        testing.expect(t,test_close_mat4(transform_matrix(back),m))
        testing.expect(t,test_close3(back.position,source.position) && test_close3(back.scale,source.scale))
        testing.expect(t,test_same_rotation(back.rotation,source.rotation))
    }
    // A mirror is a negative X scale, whichever axis was mirrored.
    mirrored:=transform_matrix(test_trs({1,2,3},{10,20,30},{2,-3,4}))
    back,ok:=transform_from_matrix(mirrored)
    testing.expect(t,ok && back.scale.x<0 && back.scale.y>0 && back.scale.z>0)
    testing.expect(t,test_close_mat4(transform_matrix(back),mirrored))
    sheared:=transform_matrix(test_trs({},{15,30,10},{0.25,8,3}))*transform_matrix(test_trs({},{10,20,30},{1,1,1}))
    _,ok=transform_from_matrix(sheared)
    testing.expect(t,!ok,"A matrix with shear has no position, rotation and scale")
    _,ok=transform_from_matrix(transform_matrix(test_trs({},{},{1,0,1})))
    testing.expect(t,!ok,"Nor one with a collapsed axis")
}

@(test)
transform_inverses_undo_the_transform :: proc(t:^testing.T) {
    source:=test_trs({1,-2,3},{33,-71,128},{2,0.5,-3})
    m:=transform_matrix(source)
    inverse_matrix,ok:=transform_inverse_matrix(source)
    testing.expect(t,ok)
    testing.expect(t,test_close_mat4(inverse_matrix,linalg.inverse(m)))
    testing.expect(t,test_close_mat4(inverse_matrix*m,MAT4_IDENTITY))
    inverse,inverse_ok:=transform_inverse(source)
    testing.expect(t,inverse_ok)
    identity:=transform_compose(source,inverse)
    testing.expect(t,test_close3(identity.position,{}) && test_close3(identity.scale,{1,1,1}) && test_same_rotation(identity.rotation,QUAT_IDENTITY))
    point:=Vec3{0.3,7,-2}
    moved:=transform_point(source,point)
    testing.expect(t,test_close3(moved,mat4_point(m,point)))
    testing.expect(t,test_close3(transform_inverse_point(source,moved),point))
    testing.expect(t,test_close3(transform_vector(source,point),mat4_vector(m,point)))
    testing.expect(t,test_close3(transform_inverse_vector(source,transform_vector(source,point)),point))
    testing.expect(t,test_close(linalg.length(transform_direction(source,{0,0,1})),1))
    testing.expect(t,test_close3(transform_point(TRANSFORM_IDENTITY,point),point))
    testing.expect(t,test_close_mat4(transform_matrix(TRANSFORM_IDENTITY),MAT4_IDENTITY))
}

@(test)
transform_interpolate_takes_the_shortest_arc :: proc(t:^testing.T) {
    a:=test_trs({0,0,0},{0,10,0},{1,1,1})
    b:=test_trs({2,4,6},{0,50,0},{3,3,3})
    start:=transform_interpolate(a,b,0)
    testing.expect(t,test_close3(start.position,a.position) && test_close3(start.scale,a.scale) && test_same_rotation(start.rotation,a.rotation))
    end:=transform_interpolate(a,b,1)
    testing.expect(t,test_close3(end.position,b.position) && test_same_rotation(end.rotation,b.rotation))
    half:=transform_interpolate(a,b,0.5)
    testing.expect(t,test_close3(half.position,{1,2,3}) && test_close3(half.scale,{2,2,2}))
    testing.expect(t,test_close3(quat_to_euler(half.rotation),Vec3{0,30,0}*DEG,1e-3))
    testing.expect(t,test_close(abs(half.rotation),1))
    // The opposite quaternion is the same rotation: the path through it is no longer.
    b.rotation=-b.rotation
    testing.expect(t,test_close3(quat_to_euler(transform_interpolate(a,b,0.5).rotation),Vec3{0,30,0}*DEG,1e-3))
    // 350 to 10 degrees goes through 0, not through 180.
    from,to:=quat_from_euler(Vec3{0,350,0}*DEG),quat_from_euler(Vec3{0,10,0}*DEG)
    testing.expect(t,test_same_rotation(quat_nlerp(from,to,0.5),QUAT_IDENTITY,1e-3))
    testing.expect(t,test_same_rotation(quat_slerp(from,to,0.5),QUAT_IDENTITY,1e-3))
    testing.expect(t,test_close3(quat_to_euler(quat_slerp(from,to,0.25)),Vec3{0,-5,0}*DEG,1e-3))
    testing.expect(t,test_close(quat_angle(from,to),20*DEG,1e-3))
}

@(test)
quat_helpers_follow_the_right_hand_rule :: proc(t:^testing.T) {
    quarter:=quat_axis_angle({0,2,0},90*DEG)
    testing.expect(t,test_close3(quat_rotate(quarter,{1,0,0}),{0,0,-1}),"A positive turn around Y takes X to -Z")
    testing.expect(t,test_close3(quat_rotate(quat_axis_angle({0,0,1},90*DEG),{1,0,0}),{0,1,0}))
    testing.expect(t,test_close3(quat_rotate(quat_axis_angle({1,0,0},90*DEG),{0,1,0}),{0,0,1}))
    testing.expect_value(t,quat_axis_angle({},1),QUAT_IDENTITY)
    testing.expect(t,test_close3(quat_rotate(quat_inverse(quarter),quat_rotate(quarter,{1,2,3})),{1,2,3}))
    // The axis-angle matrix of the previous engine.
    axis,angle:=linalg.normalize(Vec3{1,2,-0.5}),f32(0.7)
    s,c:=math.sin(angle),math.cos(angle);k:=1-c
    expected:=Mat3{
        k*axis.x*axis.x+c,       k*axis.x*axis.y-s*axis.z,k*axis.x*axis.z+s*axis.y,
        k*axis.x*axis.y+s*axis.z,k*axis.y*axis.y+c,       k*axis.y*axis.z-s*axis.x,
        k*axis.x*axis.z-s*axis.y,k*axis.y*axis.z+s*axis.x,k*axis.z*axis.z+c,
    }
    testing.expect(t,test_close_mat3(quat_to_mat3(quat_axis_angle(axis,angle)),expected))
    testing.expect(t,test_same_rotation(quat_from_mat3(expected),quat_axis_angle(axis,angle)))
    between:=quat_between({1,0,0},{0,0,-3})
    testing.expect(t,test_close3(quat_rotate(between,{1,0,0}),{0,0,-1}))
    opposite:=quat_between({0,1,0},{0,-1,0})
    testing.expect(t,test_close3(quat_rotate(opposite,{0,1,0}),{0,-1,0}))
    look:=quat_look({1,0,0},{0,1,0})
    testing.expect(t,test_close3(quat_forward(look),{1,0,0}) && test_close3(quat_rotate(look,{0,1,0}),{0,1,0}))
    tilted:=quat_look({0,-1,-1},{0,1,0})
    testing.expect(t,test_close3(quat_forward(tilted),linalg.normalize(Vec3{0,-1,-1})))
    testing.expect(t,quat_rotate(tilted,{0,1,0}).y>0)
    down:=quat_look({0,-1,0},{0,1,0})
    testing.expect(t,test_close3(quat_forward(down),{0,-1,0}),"An up parallel to the view is replaced")
    testing.expect(t,test_same_rotation(quat_look({},{}),QUAT_IDENTITY))
}
