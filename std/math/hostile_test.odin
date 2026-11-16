package mirai_math

import "base:intrinsics"
import "core:math/linalg"
import "core:testing"
import "mirai:std/base"

// Every public procedure is handed NaN, infinities and huge or tiny numbers,
// zero-length vectors, degenerate matrices and shapes, curves and tables that
// are empty or unsorted, slices of other lengths, and bit counts and ranges
// out of range. Each family returns the contract its results broke, or "".
// Half of the rounds are calm: finite, moderate numbers and well-formed
// shapes, for the contracts that only hold then.

@(private="file") HOSTILE_ROUNDS :: #config(MATH_HOSTILE_ROUNDS,400)

@(private="file")
Hostile_Numbers :: struct {source:base.Hostile,calm:bool}

@(private="file")
Hostile_Family :: struct {name:string,contract:proc(n:^Hostile_Numbers) -> string}

@(private="file")
pick :: proc(n:^Hostile_Numbers,below:int) -> int {return base.hostile_int(&n.source,below)}

@(private="file")
number :: proc(n:^Hostile_Numbers) -> f32 {
    return f32(pick(n,2001)-1000)/100 if n.calm else base.hostile_f32(&n.source)
}
// From low to high in a calm round.
@(private="file")
number_in :: proc(n:^Hostile_Numbers,low,high:f32) -> f32 {
    return low+(high-low)*f32(pick(n,1001))/1000 if n.calm else base.hostile_f32(&n.source)
}
@(private="file")
vec2 :: proc(n:^Hostile_Numbers) -> Vec2 {return {number(n),number(n)}}
@(private="file")
vec3 :: proc(n:^Hostile_Numbers) -> Vec3 {
    if pick(n,6)==0 {return {}}
    return {number(n),number(n),number(n)}
}
@(private="file")
vec4 :: proc(n:^Hostile_Numbers) -> Vec4 {return {number(n),number(n),number(n),number(n)}}
// Not zero in a calm round.
@(private="file")
direction :: proc(n:^Hostile_Numbers) -> Vec3 {
    v:=vec3(n)
    return {0.6,-0.3,1} if n.calm && linalg.length(v)<0.1 else v
}
// Unit in a calm round.
@(private="file")
quat :: proc(n:^Hostile_Numbers) -> Quat {
    v:=vec4(n)
    if !n.calm {return 0 if pick(n,6)==0 else quaternion(w=v.w,x=v.x,y=v.y,z=v.z)}
    length:=linalg.length(v)
    if length<0.1 {return QUAT_IDENTITY}
    v/=length
    return quaternion(w=v.w,x=v.x,y=v.y,z=v.z)
}
@(private="file")
mat4 :: proc(n:^Hostile_Numbers) -> Mat4 {
    if pick(n,6)==0 {return Mat4(0)}
    m:Mat4
    for column in 0..<4 {for row in 0..<4 {m[row,column]=number(n)}}
    return m
}
// With no axis of its scale near zero in a calm round.
@(private="file")
transform :: proc(n:^Hostile_Numbers) -> Transform {
    if !n.calm {return {vec3(n),quat(n),vec3(n)}}
    scale:Vec3
    for &axis in scale {axis=number_in(n,0.5,2.5)*(1 if pick(n,4)!=0 else -1)}
    return {vec3(n),quat(n),scale}
}
// With min below max in a calm round.
@(private="file")
aabb :: proc(n:^Hostile_Numbers) -> Aabb {
    if n.calm {return aabb_from_points({vec3(n),vec3(n)})}
    if pick(n,8)==0 {return AABB_EMPTY}
    return {vec3(n),vec3(n)}
}
@(private="file")
plane :: proc(n:^Hostile_Numbers) -> Plane {return {vec3(n),number(n)}}
@(private="file")
obb :: proc(n:^Hostile_Numbers) -> Obb {return {vec3(n),quat(n),vec3(n)}}
@(private="file")
sphere :: proc(n:^Hostile_Numbers) -> Sphere {return {vec3(n),number(n)}}
@(private="file")
capsule :: proc(n:^Hostile_Numbers) -> Capsule {return {vec3(n),vec3(n),number(n)}}
@(private="file")
triangle :: proc(n:^Hostile_Numbers) -> Triangle {return {vec3(n),vec3(n),vec3(n)}}
@(private="file")
frustum :: proc(n:^Hostile_Numbers) -> Frustum {
    if pick(n,2)==0 {return frustum_from_matrix(mat4(n))}
    f:Frustum
    for &p in f.planes {p=plane(n)}
    return f
}

@(private="file")
finite :: proc(values:..f32) -> bool {
    for value in values {if value-value!=0 {return false}}
    return true
}
@(private="file")
near :: proc(a,b:f32,tolerance:f32=1e-3) -> bool {return abs(a-b)<=tolerance*max(1,abs(a),abs(b))}
@(private="file")
near3 :: proc(a,b:Vec3,tolerance:f32=1e-3) -> bool {return linalg.length(a-b)<=tolerance*max(1,linalg.length(a),linalg.length(b))}
// Between a and b, whichever is larger.
@(private="file")
within :: proc(value,a,b:f32,slack:f32=1e-3) -> bool {
    room:=slack*max(1,abs(a),abs(b))
    return value>=min(a,b)-room && value<=max(a,b)+room
}
@(private="file")
unit :: proc(q:Quat) -> bool {return near(abs(q),1)}
// Equal, or both NaN.
@(private="file")
same :: proc(a,b:f32) -> bool {return a==b || (a!=a && b!=b)}

@(private="file")
hostile_scalars :: proc(n:^Hostile_Numbers) -> string {
    a,b,c,d,e:=number(n),number(n),number(n),number(n),number(n)
    v,w:=vec3(n),vec3(n)
    velocity:f32
    velocity3:Vec3
    step:=abs(c)
    wrapped,turn:=angle_wrap(a),angle_delta(a,b)
    moved,pulled:=approach(a,b,step),approach_point(v,w,step)
    damped:=damp(a,b,abs(c),abs(d))
    sprung,_:=spring_critical(a,f32(0),b,abs(c),abs(d))
    smoothed:=smooth_damp(a,b,&velocity,abs(c),abs(d),abs(e))
    snapped:=snap(a,b)
    sine,cosine:=sincos_det(a)
    _=remap(a,b,c,d,e);_=angle_lerp(a,b,c);_=angle_approach(a,b,c);_=damp(v,w,c,d);_=damp_angle(a,b,c,d)
    _,_=spring_critical(v,w,vec3(n),d,e);_=spring_omega(a);_=snap(v,b);_=snap_from(a,b,c)
    _=smooth_damp(v,w,&velocity3,c,d,e);_=smooth_damp_angle(a,b,&velocity,c,d,e);_=sin_det(b);_=cos_det(c)
    if a==a && (saturate(a)<0 || saturate(a)>1) {return "saturate left 0..1"}
    if !same(ln_det(-abs(a)-1),a-a+f32(0h7fc00000)) && a==a {return "the logarithm of a negative number is not NaN"}
    if !n.calm {return ""}
    switch {
    case !within(remap_clamped(a,b,c,d,e),d,e): return "remap_clamped left its target range"
    case !within(smoothstep(b,c,a),0,1) || !within(smootherstep(b,c,a),0,1): return "a smoothstep left 0..1"
    case wrapped< -PI || wrapped>=PI || turn< -PI || turn>=PI: return "a wrapped angle left [-PI,PI)"
    case !within(moved,a,b) || abs(moved-a)>step*1.001+1e-5: return "approach passed its target or its step"
    case linalg.length(pulled-v)>step*1.001+1e-3 || linalg.length(pulled-w)>linalg.length(v-w)+1e-3: return "approach_point passed its target or its step"
    case !within(damped,a,b): return "damp left the gap it closes"
    case !within(sprung,a,b): return "a spring at rest overshot"
    case !within(smoothed,a,b): return "smooth_damp passed its target"
    case b==0 && snapped!=a: return "a step of 0 moved the value"
    case b!=0 && abs(snapped-a)>abs(b)*0.501+1e-4: return "snap is not the nearest multiple"
    case !near(sine*sine+cosine*cosine,1): return "sine and cosine are not of one angle"
    case !(exp_det(a)>0) || !finite(exp_det(a)): return "the exponential of a moderate number is not positive"
    }
    return ""
}

@(private="file")
hostile_easing :: proc(n:^Hostile_Numbers) -> string {
    for kind in 0..<256 {
        _=ease_apply(Ease(kind),number(n))
        if !near(ease_apply(Ease(kind),0),0) || !near(ease_apply(Ease(kind),1),1) {return "an easing, or the number of none, does not start at 0 and end at 1"}
    }
    return ""
}

@(private="file")
hostile_rotations :: proc(n:^Hostile_Numbers) -> string {
    a,b:=quat(n),quat(n)
    v,w:=vec3(n),vec3(n)
    angle,t:=number(n),number(n)
    turned,looked,euler:=quat_axis_angle(v,angle),quat_look(v,w),quat_from_euler(v)
    back,right,forward:=look_basis(v,w)
    axis:=direction(n)
    swing,twist:=quat_swing_twist(a,axis)
    blended,arc:=quat_nlerp(a,b,t),quat_slerp(a,b,t)
    _=quat_rotate(a,v);_=quat_inverse(a);_=quat_to_mat3(a);_=quat_from_mat3(Mat3(number(n)));_=quat_between(v,w)
    _=quat_angle(a,b);_=quat_to_euler(a);_=euler_near(v,w);_=euler_closest(v,w)
    if finite(v.x,v.y,v.z,w.x,w.y,w.z) {
        orthonormal:=near(linalg.length(back),1) && near(linalg.length(right),1) && near(linalg.length(forward),1)
        orthonormal&&=abs(linalg.dot(back,right))<1e-3 && near3(back,-forward)
        if !orthonormal {return "look_basis is not orthonormal for finite directions"}
    }
    if !n.calm {return ""}
    switch {
    case !unit(turned) || (v=={} && turned!=QUAT_IDENTITY): return "quat_axis_angle is not a rotation, or not the identity without an axis"
    case !unit(looked) || !unit(euler): return "quat_look or quat_from_euler is not a unit quaternion"
    case !unit(blended) || !unit(arc): return "an interpolated rotation is not a unit quaternion"
    case !near(abs(linalg.dot(swing*twist,a)),1): return "swing and twist do not compose back into the rotation"
    }
    return ""
}

@(private="file")
hostile_transforms :: proc(n:^Hostile_Numbers) -> string {
    a,b:=transform(n),transform(n)
    v,w:=vec3(n),vec3(n)
    m:=mat4(n)
    local,relative:=transform_relative(a,b)
    inverse,inverted:=transform_inverse(a)
    inverse_matrix,matrix_inverted:=transform_inverse_matrix(a)
    _=mat4_point(m,v);_=mat4_vector(m,w);_=transform_compose(a,b)
    _=transform_point(a,v);_=transform_vector(a,v);_=transform_direction(a,v)
    _=transform_inverse_point(a,v);_=transform_inverse_vector(a,v)
    _,_=transform_from_matrix(m)
    _=transform_from_euler(v,w,vec3(n));_=transform_interpolate(a,b,number(n));_=aabb_transform(aabb(n),m)
    if (!relative && local!=TRANSFORM_IDENTITY) || (!inverted && inverse!=TRANSFORM_IDENTITY) || (!matrix_inverted && inverse_matrix!=MAT4_IDENTITY) {
        return "a transform that cannot be inverted did not give the identity"
    }
    if !n.calm {return ""}
    if !relative || !inverted || !matrix_inverted {return "a transform with a scale away from zero was not inverted"}
    round,world:=transform_compose(a,inverse),transform_compose(b,local)
    if !near3(round.position,0,1e-2) || !near3(round.scale,1,1e-2) || !near(abs(round.rotation.w),1,1e-2) {return "a transform composed with its inverse is not the identity"}
    if !near3(world.position,a.position,1e-2) || !near3(world.scale,a.scale,1e-2) {return "a relative transform composed with its parent is not the world one"}
    back,ok:=transform_from_matrix(transform_matrix(a))
    if !ok || !near3(back.position,a.position) {return "the matrix of a transform does not read back"}
    return ""
}

@(private="file")
hostile_cameras :: proc(n:^Hostile_Numbers) -> string {
    eye,target,up:=vec3(n),vec3(n),vec3(n)
    m:=mat4(n)
    view:=look_at(eye,target,up)
    _=view_matrix(eye,quat(n))
    _=perspective(number(n),number(n),number(n),number(n))
    _=perspective_infinite(number(n),number(n),number(n))
    _=orthographic(number(n),number(n),number(n),number(n))
    _=orthographic_off_center(number(n),number(n),number(n),number(n),number(n),number(n))
    _,_,_=world_to_screen(eye,vec2(n),m)
    _=screen_ray(vec2(n),vec2(n),m,mat4(n))
    _=perspective_world_per_pixel(number(n),number(n),number(n))
    if !n.calm {return ""}
    for column in 0..<4 {for row in 0..<4 {
        if !finite(view[row,column]) {return "look_at is not finite for a degenerate view"}
    }}
    near_plane:=number_in(n,0.05,1)
    projection:=perspective(number_in(n,0.2,2.5),number_in(n,0.5,2),near_plane,near_plane+number_in(n,1,100))
    ray:=screen_ray({number_in(n,0,1000),number_in(n,0,1000)},{1000,1000},view,projection)
    if !near(linalg.length(ray.direction),1) {return "the ray through a pixel has no unit direction"}
    return ""
}

@(private="file")
hostile_shapes :: proc(n:^Hostile_Numbers) -> string {
    points:[6]Vec3
    count:=pick(n,len(points)+1)
    for &point in points[:count] {point=vec3(n)}
    box,other:=aabb(n),aabb(n)
    v,normal:=vec3(n),direction(n)
    merged,hull:=aabb_merge(box,other),aabb_from_points(points[:count])
    closest:=closest_point_aabb(v,box)
    segment:=Segment{vec3(n),vec3(n)}
    on_segment,t:=closest_point_segment(v,segment)
    through:=plane_from_point(v,normal)
    view:=frustum(n)
    ray:=Ray{vec3(n),vec3(n)}
    _=aabb_from_center(v,vec3(n));_=aabb_center(box);_=aabb_half(box);_=aabb_size(box)
    _=aabb_add_point(box,v);_=aabb_expand(box,number(n));_=aabb_contains_point(box,v);_=aabb_contains(box,other)
    _=aabb_from_obb(obb(n));_=aabb_from_sphere(sphere(n));_=aabb_from_capsule(capsule(n))
    _=plane_from_points(v,vec3(n),vec3(n));_=plane_distance(plane(n),v)
    _=aabb_overlaps(box,other);_=sphere_overlaps(sphere(n),sphere(n));_=sphere_overlaps_aabb(sphere(n),box)
    _=frustum_overlaps_aabb(view,box);_=frustum_overlaps_sphere(view,sphere(n))
    _=obb_overlaps(obb(n),obb(n));_=obb_separation(obb(n),obb(n))
    _=ray_at(ray,number(n));_,_=ray_plane(ray,plane(n));_,_,_=ray_aabb(ray,box)
    _,_=ray_aabb_fast(ray.origin,ray.direction,box,number(n))
    _,_,_=ray_obb(ray,obb(n));_,_,_=ray_sphere(ray,sphere(n));_,_,_=ray_capsule(ray,capsule(n))
    _,_,_=ray_triangle(ray,triangle(n));_=triangle_normal(triangle(n));_,_,_=ray_frustum(ray,view)
    _,_,_=line_line_closest(v,vec3(n),vec3(n),vec3(n))
    _=closest_point_plane(v,plane(n));_=closest_point_obb(v,obb(n))
    _,_,_,_=closest_segment_segment(segment,Segment{vec3(n),vec3(n)})
    _=closest_point_triangle(v,triangle(n))
    if aabb_is_empty(box) && (aabb_surface_area(box)!=0 || aabb_volume(box)!=0) {return "an empty box has area or volume"}
    if !n.calm {return ""}
    switch {
    case !aabb_contains(merged,box) || !aabb_contains(merged,other) || !aabb_overlaps(merged,box): return "a merged box does not contain its parts"
    case aabb_surface_area(box)<0 || aabb_volume(box)<0: return "a box has negative area or volume"
    case !aabb_contains_point(box,closest) || (aabb_contains_point(box,v) && closest!=v): return "the closest point of a box is not in it, or moved a point inside"
    case !(t>=0 && t<=1) || !near3(on_segment,segment.a+(segment.b-segment.a)*t): return "the closest point of a segment is not on it"
    case abs(plane_distance(through,v))>1e-3*(1+linalg.length(v)): return "a plane through a point does not hold it"
    }
    for point in points[:count] {
        if !aabb_contains_point(hull,point) {return "the box of some points leaves one out"}
    }
    return ""
}

// Whether the set bits of the first `words` are `passed` boxes below `count`, and the rest of `visible` is as it was.
@(private="file")
hostile_culled :: proc(visible:[]u64,untouched:u64,count,passed:int) -> bool {
    words:=(count+63)>>6
    set:=0
    for word,i in visible {
        if i>=words {
            if word!=untouched {return false}
            continue
        }
        set+=int(intrinsics.count_ones(word))
        if i==words-1 && count&63!=0 && word>>uint(count&63)!=0 {return false}
    }
    return set==passed
}

@(private="file")
hostile_culling :: proc(n:^Hostile_Numbers) -> string {
    UNTOUCHED :: 0xa5a5a5a5a5a5a5a5
    boxes:[130]Aabb
    count:=pick(n,len(boxes)+1)
    for &box in boxes[:count] {box=aabb(n)}
    view:=frustum(n)
    for scalar in ([2]bool{false,true}) {
        visible:=[4]u64{0..<4=UNTOUCHED}
        given:=pick(n,len(visible)+1)
        passed:=frustum_cull_aabbs_scalar(view,boxes[:count],visible[:given]) if scalar else frustum_cull_aabbs(view,boxes[:count],visible[:given])
        if given<(count+63)>>6 {
            if passed!=0 || visible!=UNTOUCHED {return "a cull without a bit for every box wrote or counted"}
        } else if !hostile_culled(visible[:],UNTOUCHED,count,passed) {
            return "a cull counted other than the bits it set, or set bits that are of no box"
        }
    }
    return ""
}

@(private="file")
hostile_box_packets :: proc(n:^Hostile_Numbers) -> string {
    boxes:Aabb4
    singles:[4]Aabb
    for &box,lane in singles {
        box=aabb(n)
        aabb4_set(&boxes,lane,box)
    }
    before:=boxes
    aabb4_set(&boxes,4+pick(n,1000) if pick(n,2)==0 else -1-pick(n,1000),aabb(n))
    if transmute([24]u32)boxes!=transmute([24]u32)before {return "a lane out of range changed the packet"}
    origin,inverse_direction,reach:=vec3(n),vec3(n),number(n)
    t,hits:=ray_aabb4(origin,inverse_direction,&boxes,reach)
    if !n.calm {return ""}
    for box,lane in singles {
        single,hit:=ray_aabb_fast(origin,inverse_direction,box,reach)
        if hit!=(lane in hits) || (hit && single!=t[lane]) {return "a lane of the packet differs from the ray against its box alone"}
    }
    return ""
}

@(private="file")
hostile_curves :: proc(n:^Hostile_Numbers) -> string {
    a,b,c,d:=vec3(n),vec3(n),vec3(n),vec3(n)
    s:=number(n)
    _=bezier_quadratic(a,b,c,s);_=bezier_quadratic_tangent(a,b,c,s);_=bezier_cubic(a,b,c,d,s);_=bezier_cubic_tangent(a,b,c,d,s)
    _=hermite(a,b,c,d,s);_=catmull_rom(a,b,c,d,s);_=catmull_rom_tangent(a,b,c,d,s);_=b_spline(a,b,c,d,s)
    _=bezier_cubic(number(n),number(n),number(n),number(n),s)
    if !n.calm {return ""}
    switch {
    case !near3(bezier_quadratic(a,b,c,0),a) || !near3(bezier_quadratic(a,b,c,1),c): return "a quadratic Bezier does not join its end points"
    case !near3(bezier_cubic(a,b,c,d,0),a) || !near3(bezier_cubic(a,b,c,d,1),d): return "a cubic Bezier does not join its end points"
    case !near3(hermite(a,b,c,d,0),a) || !near3(hermite(a,b,c,d,1),c): return "a Hermite segment does not join its end points"
    case !near3(catmull_rom(a,b,c,d,0),b) || !near3(catmull_rom(a,b,c,d,1),c): return "a Catmull-Rom segment does not join its middle points"
    }
    return ""
}

@(private="file")
hostile_arc_tables :: proc(n:^Hostile_Numbers) -> string {
    UNTOUCHED :: -7
    points:[8]Vec3
    lengths:=[10]f32{0..<10=UNTOUCHED}
    count:=pick(n,len(points)+1)
    for &point in points[:count] {point=vec3(n)}
    room:=clamp(count+pick(n,3)-1,0,len(lengths))
    total:=arc_table_build(points[:count],lengths[:room])
    shared:=min(count,room)
    table:=lengths[:shared]
    for length in lengths[shared:] {
        if length!=UNTOUCHED {return "an arc table was written past its points"}
    }
    if !same(total,table[shared-1] if shared>0 else 0) {return "the total of an arc table is not its last length"}
    distance:=number(n)
    parameter:=arc_table_parameter(table,distance)
    _=arc_table_distance(table,number(n))
    if arc_table_distance(table,f32(0h7fc00000))!=0 {return "the length at a NaN parameter is not 0"}
    if !n.calm {return ""}
    for i in 1..<shared {
        if table[i]<table[i-1] {return "the lengths of an arc table decrease"}
    }
    if !(parameter>=0 && parameter<=1) {return "the parameter of a distance left 0..1"}
    if shared>=2 && distance>=0 && distance<=total && !near(arc_table_distance(table,parameter),distance,1e-3*(1+total)) {return "the parameter of a distance does not run that distance"}
    return ""
}


@(private="file")
hostile_random :: proc(n:^Hostile_Numbers) -> string {
    rng:=rng_make(base.hostile_next(&n.source),base.hostile_next(&n.source))
    low:=min(int) if pick(n,3)==0 else pick(n,100)-50
    high:=(max(int) if pick(n,2)==0 else min(int)) if pick(n,3)==0 else pick(n,100)-50
    bound:=u32(base.hostile_next(&n.source)) if pick(n,2)==0 else u32(pick(n,5))
    a,b:=number(n),number(n)
    axis,spread:=direction(n),number(n)
    integer,below,ranged:=random_int(&rng,low,high),random_below(&rng,bound),random_range(&rng,a,b)
    in_cone:=random_in_cone(&rng,axis,spread)
    likely:=random_bool(&rng,a)
    _=random_gaussian(&rng,number(n),number(n))
    weights:[8]f32
    count:=pick(n,len(weights)+1)
    positive,ordered:=false,true
    for &weight in weights[:count] {
        weight=number(n)
        positive||=weight>0;ordered&&=weight==weight
    }
    chosen:=random_weighted(&rng,weights[:count])
    items:[8]u32
    for &item,i in items {item=u32(i)}
    shuffled:=items[:pick(n,len(items)+1)]
    random_shuffle(&rng,shuffled)
    seen:u32
    for item in shuffled {seen|=1<<item}
    nothing:[]u32
    random_shuffle(&rng,nothing)
    unit_value:=random_f32(&rng)
    switch {
    case !(unit_value>=0 && unit_value<1): return "random_f32 left [0,1)"
    case below>=bound && !(bound==0 && below==0): return "random_below reached its bound"
    case high<=low && integer!=low: return "random_int of an empty range is not its low end"
    case high>low && (integer<low || integer>=high): return "random_int left its range"
    case abs(random_sign(&rng))!=1: return "random_sign is not -1 or 1"
    case linalg.length(random_in_disc(&rng))>1.001 || linalg.length(random_in_sphere(&rng))>1.001: return "a random point left the unit disc or ball"
    case !near(linalg.length(random_unit_vec2(&rng)),1) || !near(linalg.length(random_unit_vec3(&rng)),1) || !unit(random_quat(&rng)): return "a random direction or rotation is not unit"
    case a==a && ((a<=0 && likely) || (a>=1 && !likely)): return "random_bool ignored a certain probability"
    case ordered && (chosen>=0)!=positive: return "random_weighted has an index exactly when a weight is positive"
    case chosen>=count || (chosen>=0 && ordered && !(weights[chosen]>0)): return "random_weighted chose a weight that is not positive"
    case int(intrinsics.count_ones(seen))!=len(shuffled) || (len(shuffled)>0 && seen>>uint(len(shuffled))!=0): return "a shuffle lost or repeated an item"
    }
    if !n.calm {return ""}
    if !within(ranged,a,b) {return "random_range left its range"}
    if !near(linalg.length(in_cone),1) || linalg.dot(in_cone,linalg.normalize(axis))<linalg.cos(clamp(spread,0,PI))-1e-3 {return "random_in_cone left its cone"}
    return ""
}

@(private="file")
hostile_noise :: proc(n:^Hostile_Numbers) -> string {
    p2,p3:=vec2(n),vec3(n)
    seed:=u32(base.hostile_next(&n.source))
    value2,value3:=noise_value2(p2,seed),noise_value3(p3,seed)
    perlin2,perlin3:=noise_perlin2(p2,seed),noise_perlin3(p3,seed)
    with_slope2,_:=noise_perlin2_gradient(p2,seed)
    with_slope3,_:=noise_perlin3_gradient(p3,seed)
    near2,far2:=noise_worley2(p2,seed)
    near3_,far3:=noise_worley3(p3,seed)
    kind:=Noise_Kind(pick(n,4))
    any2,any3:=noise2(kind,p2,seed),noise3(kind,p3,seed)
    fractal:=Fractal{Noise_Kind(pick(n,2)),u8(base.hostile_next(&n.source)),number(n),number(n),seed}
    if n.calm {fractal.octaves=u8(1+pick(n,8));fractal.lacunarity=number_in(n,1.5,2.5);fractal.gain=number_in(n,0.3,0.7)}
    ridged2,ridged3:=noise_ridged2(p2,fractal),noise_ridged3(p3,fractal)
    billow2,billow3:=noise_turbulence2(p2,fractal),noise_turbulence3(p3,fractal)
    fbm2,fbm3:=noise_fbm2(p2,fractal),noise_fbm3(p3,fractal)
    _=noise_hash(i32(base.hostile_next(&n.source)),i32(base.hostile_next(&n.source)),i32(base.hostile_next(&n.source)),seed)
    _=noise_fade(p2.x);_=noise_fade_slope(p2.y);_=noise_simplex2(p2,seed);_=noise_simplex3(p3,seed)
    _=noise_curl2(p2,seed);_=noise_curl3(p3,seed)
    if unit_value:=noise_unit(u32(base.hostile_next(&n.source)));!(unit_value>=0 && unit_value<1) {return "noise_unit left [0,1)"}
    if !n.calm {return ""}
    switch {
    case !finite(value2,value3,perlin2,perlin3,any2,any3,fbm2,fbm3): return "noise is not finite at a moderate point"
    case abs(value2)>1.001 || abs(value3)>1.001 || abs(perlin2)>1.001 || abs(perlin3)>1.001: return "lattice noise left -1..1"
    case !near(with_slope2,perlin2,1e-5) || !near(with_slope3,perlin3,1e-5): return "Perlin noise with its gradient has another value"
    case !(near2>=0 && near2<=far2) || !(near3_>=0 && near3_<=far3): return "the nearest Worley point is farther than the second"
    case !within(ridged2,0,1,0.05) || !within(ridged3,0,1,0.05) || !within(billow2,0,1,0.05) || !within(billow3,0,1,0.05): return "ridged or turbulent noise left 0..1"
    }
    return ""
}

@(private="file")
hostile_colors :: proc(n:^Hostile_Numbers) -> string {
    v3,v4:=vec3(n),vec4(n)
    a:=number(n)
    unpacked:=rgba8_unpack(rgba8_pack(v4))
    linear:=rgba8_to_linear(u32(base.hostile_next(&n.source)))
    _=srgb_to_linear(a);_=linear_to_srgb(a);_=srgb_to_linear(v3);_=linear_to_srgb(v3);_=srgb_to_linear(v4);_=linear_to_srgb(v4)
    _=hsv_to_rgb(v3);_=rgb_to_hsv(v3);_=hsl_to_rgb(v3);_=rgb_to_hsl(v3);_=linear_to_oklab(v3);_=oklab_to_linear(v3)
    _=color_mix_oklab(v4,vec4(n),a);_=rgba8_from_linear(v4)
    for channel,i in unpacked {
        if v4[i]==v4[i] && abs(channel-saturate(v4[i]))>0.5/255+1e-6 {return "a color packed in 8 bits is farther than half a step from its clamped value"}
        if !(linear[i]>=0 && linear[i]<=1) {return "a packed color left 0..1"}
    }
    if !n.calm {return ""}
    color:=Vec3{number_in(n,0,1),number_in(n,0,1),number_in(n,0,1)}
    switch {
    case !near3(hsv_to_rgb(rgb_to_hsv(color)),color): return "a color does not come back from HSV"
    case !near3(hsl_to_rgb(rgb_to_hsl(color)),color): return "a color does not come back from HSL"
    case !near3(oklab_to_linear(linear_to_oklab(color)),color): return "a color does not come back from Oklab"
    case !near3(srgb_to_linear(linear_to_srgb(color)),color): return "a color does not come back from sRGB"
    }
    return ""
}

@(private="file")
hostile_gradients :: proc(n:^Hostile_Numbers) -> string {
    stops:[6]Gradient_Stop
    count:=pick(n,len(stops)+1)
    position:f32
    low,high:=Vec4(max(f32)),Vec4(min(f32))
    for &stop in stops[:count] {
        position=number(n) if !n.calm && pick(n,5)==0 else position+f32(pick(n,3))
        stop={position,vec4(n)}
        low,high=linalg.min(low,stop.color),linalg.max(high,stop.color)
    }
    gradient:=stops[:count]
    for _ in 0..<4 {
        at:=number(n)
        color:=gradient_evaluate(gradient,at,Gradient_Space(pick(n,3)))
        mixed:=gradient_evaluate(gradient,at)
        if count==0 {
            if color!={} {return "a gradient without stops has a color"}
            continue
        }
        if !n.calm {continue}
        switch {
        case at<=gradient[0].position && mixed!=gradient[0].color: return "a gradient before its first stop is not that stop"
        case at>=gradient[count-1].position && at>gradient[0].position && mixed!=gradient[count-1].color: return "a gradient after its last stop is not that stop"
        }
        for channel,i in mixed {
            if !within(channel,low[i],high[i]) {return "a gradient left the colors of its stops"}
        }
    }
    return ""
}

@(private="file")
hostile_hex_colors :: proc(n:^Hostile_Numbers) -> string {
    digit:="0123456789abcdefABCDEF"
    UNTOUCHED :: '?'
    bytes:[16]u8
    for &b in bytes {
        switch pick(n,5) {
        case 0: b=u8(base.hostile_next(&n.source))
        case 1: b='#'
        case 2: b=digit[pick(n,22)]
        case: b=digit[pick(n,16)]
        }
    }
    lengths:=[?]int{3,4,6,8,pick(n,17),pick(n,17)}
    text:=string(bytes[:lengths[pick(n,len(lengths))]])
    digits:=text[1:] if len(text)>0 && text[0]=='#' else text
    valid:=len(digits)==3 || len(digits)==4 || len(digits)==6 || len(digits)==8
    for i in 0..<len(digits) {
        switch digits[i] {
        case '0'..='9','a'..='f','A'..='F':
        case: valid=false
        }
    }
    color,ok:=color_parse_hex(text)
    if ok!=valid {return "only 3, 4, 6 or 8 hex digits, with or without #, are a color"}
    for channel in color {
        if !(channel>=0 && channel<=1) {return "a parsed color left 0..1"}
    }
    if len(digits)==3 && ok && color.a!=1 {return "a color without alpha digits is not opaque"}
    out,again:=[16]u8{0..<16=UNTOUCHED},[16]u8{}
    room:=pick(n,len(out)+1)
    written:=color_format_hex(vec4(n) if pick(n,2)==0 else color,out[:room])
    for b in out[len(written):] {
        if b!=UNTOUCHED {return "a color was written past its text"}
    }
    if len(written)!=(9 if room>=9 else 0) {return "a color is written whole in 9 bytes, or not at all"}
    if room<9 {return ""}
    reread,reads:=color_parse_hex(written)
    if !reads || color_format_hex(reread,again[:])!=written {return "a written color does not read back as itself"}
    return ""
}

@(private="file")
hostile_quantization :: proc(n:^Hostile_Numbers) -> string {
    a,low,high:=number(n),number(n),number(n)
    bits:uint
    switch pick(n,6) {
    case 0: bits=0
    case 1: bits=64
    case 2: bits=200
    case 3: bits=max(uint)
    case 4: bits=1
    case: bits=uint(pick(n,33))
    }
    quantized:=quantize(a,low,high,bits)
    q:=quat(n)
    raw:=base.hostile_next(&n.source)
    _=dequantize(u32(raw),low,high,bits)
    _=half_unpack(u16(raw));_=octahedral_encode(vec3(n));_=octahedral_decode(vec2(n));_=normal_pack(vec3(n))
    _=quat_pack(q,bits);_=quat_unpack(raw,bits);_=quat_pack(q)
    in_range:=bits>=1 && bits<=32
    if in_range && u64(quantized)>u64(1)<<bits-1 {return "a quantized value does not fit its bits"}
    if a==a {
        switch {
        case abs(unorm8_unpack(unorm8_pack(a))-saturate(a))>0.5/255+1e-6: return "unorm8 is farther than half a step from the clamped value"
        case abs(unorm16_unpack(unorm16_pack(a))-saturate(a))>0.5/65535+1e-6: return "unorm16 is farther than half a step from the clamped value"
        case abs(snorm8_unpack(snorm8_pack(a))-clamp(a,-1,1))>0.5/127+1e-6: return "snorm8 is farther than half a step from the clamped value"
        case abs(snorm16_unpack(snorm16_pack(a))-clamp(a,-1,1))>0.5/32767+1e-6: return "snorm16 is farther than half a step from the clamped value"
        }
    }
    if abs(snorm8_unpack(i8(raw)))>1 || abs(snorm16_unpack(i16(raw>>8)))>1 {return "a signed normalized value left -1..1"}
    if !near(linalg.length(normal_unpack(u32(raw))),1) {return "an unpacked normal is not unit"}
    if bits>=2 && bits<=20 && !unit(quat_unpack(raw,bits)) {return "an unpacked rotation is not unit"}
    if !n.calm {return ""}
    if in_range && high>low {
        back:=dequantize(quantized,low,high,bits)
        step:=f64(high-low)/f64(u64(1)<<bits-1)
        if !within(back,low,high) || f64(abs(back-clamp(a,low,high)))>step/2+1e-5*f64(high-low) {return "a quantized value comes back farther than half a step"}
    }
    normal:=linalg.normalize(direction(n))
    if !near3(octahedral_decode(octahedral_encode(normal)),normal) || !near3(normal_unpack(normal_pack(normal)),normal) {return "a unit vector does not come back from its octahedral form"}
    if abs(a)>=0.01 && !near(half_unpack(half_pack(a)),a) {return "a half float lost more than its precision"}
    if !near(abs(linalg.dot(quat_unpack(quat_pack(q)),q)),1,1e-4) {return "a packed rotation is not the rotation"}
    return ""
}

@(test)
hostile_numbers_keep_the_contracts_of_the_package :: proc(t:^testing.T) {
    families:=[?]Hostile_Family{
        {"scalars",hostile_scalars},
        {"easing",hostile_easing},
        {"rotations",hostile_rotations},
        {"transforms",hostile_transforms},
        {"cameras",hostile_cameras},
        {"shapes",hostile_shapes},
        {"frustum culling",hostile_culling},
        {"box packets",hostile_box_packets},
        {"curves",hostile_curves},
        {"arc tables",hostile_arc_tables},
        {"random",hostile_random},
        {"noise",hostile_noise},
        {"colors",hostile_colors},
        {"gradients",hostile_gradients},
        {"hex colors",hostile_hex_colors},
        {"quantization",hostile_quantization},
    }
    for family,seed in families {
        n:=Hostile_Numbers{source={u64(seed)+1}}
        for round in 0..<HOSTILE_ROUNDS {
            n.calm=round&1==0
            if broken:=family.contract(&n);!testing.expectf(t,broken=="","%s, round %d: %s",family.name,round,broken) {break}
        }
    }
}
