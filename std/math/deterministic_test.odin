package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"

// How many representable f32 lie between a and b.
@(private="file")
ulps :: proc(a,b:f32) -> i64 {
    order :: proc(x:f32) -> i64 {
        bits:=i64(transmute(i32)x)
        return bits if bits>=0 else i64(min(i32))-bits
    }
    return abs(order(a)-order(b))
}

@(test)
deterministic_exp_ln_sin_and_cos_stay_within_a_unit_in_the_last_place :: proc(t:^testing.T) {
    worst_exp,worst_ln,worst_sin,worst_cos:i64
    for i in 0..<20000 {
        x:=f32(i)/20000*174-87
        worst_exp=max(worst_exp,ulps(exp_det(x),f32(math.exp(f64(x)))))
        y:=math.pow(f32(10),f32(i)/20000*60-30)
        worst_ln=max(worst_ln,ulps(ln_det(y),f32(math.ln(f64(y)))))
        z:=f32(i)/20000*2000-1000
        s,c:=sincos_det(z)
        // Near a zero of sin or cos the result is tiny and an ulp of it is not the error that matters.
        if abs(math.sin(f64(z)))>1e-3 {worst_sin=max(worst_sin,ulps(s,f32(math.sin(f64(z)))))}
        if abs(math.cos(f64(z)))>1e-3 {worst_cos=max(worst_cos,ulps(c,f32(math.cos(f64(z)))))}
        testing.expect(t,abs(f64(s)-math.sin(f64(z)))<2e-7 && abs(f64(c)-math.cos(f64(z)))<2e-7)
    }
    testing.expectf(t,worst_exp<=1 && worst_ln<=1 && worst_sin<=1 && worst_cos<=1,"ulps: exp %d, ln %d, sin %d, cos %d",worst_exp,worst_ln,worst_sin,worst_cos)
    testing.expect(t,exp_det(0)==1 && exp_det(-200)==0 && exp_det(100)>3e38 && ln_det(1)==0)
    testing.expect(t,ln_det(-1)!=ln_det(-1) && ln_det(0)< -3e38 && ulps(exp_det(ln_det(f32(7))),7)<=1)
    s,c:=sincos_det(0)
    testing.expect(t,s==0 && c==1 && sin_det(math.PI/2)==1 && cos_det(math.PI)== -1)
    // The simulation helpers keep their answers: a damp of rate 1 for 1 s leaves 1/e of the gap.
    testing.expect(t,abs(damp(f32(1),0,1,1)-0.36787944)<1e-6)
}

@(test)
ray_against_four_boxes_agrees_with_the_test_of_one :: proc(t:^testing.T) {
    r:=rng_make(31,1)
    for _ in 0..<500 {
        boxes:Aabb4
        single:[4]Aabb
        for lane in 0..<4 {
            center:=random_in_sphere(&r)*10
            half:=Vec3{random_range(&r,0.1,2),random_range(&r,0.1,2),random_range(&r,0.1,2)}
            single[lane]=aabb_from_center(center,half)
            aabb4_set(&boxes,lane,single[lane])
        }
        origin:=random_in_sphere(&r)*12
        direction:=linalg.normalize(random_in_sphere(&r)+{0.01,0,0})
        inverse:=Vec3{1,1,1}/direction
        far,hits:=ray_aabb4(origin,inverse,&boxes,30)
        for lane in 0..<4 {
            near,hit:=ray_aabb_fast(origin,inverse,single[lane],30)
            testing.expect(t,hit==(lane in hits))
            if hit {testing.expect(t,near==far[lane])}
        }
    }
}

@(test)
swing_and_twist_split_a_rotation_about_an_axis :: proc(t:^testing.T) {
    axis:=Vec3{0,1,0}
    q:=quat_axis_angle({1,0,0},0.7)*quat_axis_angle(axis,1.1)
    swing,twist:=quat_swing_twist(q,axis)
    testing.expect(t,abs(linalg.dot(q4(swing*twist),q4(q)))>0.99999)
    testing.expect(t,abs(imag(twist))<1e-6 && abs(kmag(twist))<1e-6,"the twist turns about the axis only")
    testing.expect(t,abs(linalg.dot(quat_rotate(swing,axis),quat_rotate(q,axis))-1)<1e-5,"the swing points the axis where q does")
    testing.expect(t,abs(quat_angle(1,twist)-1.1)<1e-4)
    swing,twist=quat_swing_twist(quat_axis_angle({1,0,0},math.PI),axis)
    testing.expect(t,twist==1)
}

@(test)
smooth_damp_arrives_without_passing_and_within_its_speed :: proc(t:^testing.T) {
    velocity:f32
    value:=f32(0)
    for _ in 0..<600 {
        previous:=value
        value=smooth_damp(value,10,&velocity,0.5,1.0/60,max_speed=8)
        testing.expect(t,value<=10 && (value-previous)*60<=8.001)
    }
    testing.expect(t,abs(value-10)<1e-3)
    moving:Vec3
    point:=Vec3{0,0,0}
    for _ in 0..<600 {point=smooth_damp(point,Vec3{3,4,0},&moving,0.3,1.0/60)}
    testing.expect(t,linalg.distance(point,Vec3{3,4,0})<1e-3)
    // An angle goes the short way across the wrap.
    turning:f32
    angle:=f32(3)
    angle=smooth_damp_angle(angle,-3,&turning,0.2,1.0/60)
    testing.expect(t,angle>3,"from 3 to -3 radians is forward across pi")
}

@(test)
obb_separation_measures_the_gap_and_the_overlap :: proc(t:^testing.T) {
    a:=Obb{{0,0,0},1,{1,1,1}}
    b:=Obb{{5,0,0},1,{1,1,1}}
    testing.expect(t,abs(obb_separation(a,b)-3)<1e-5)
    b.center={1.5,0,0}
    testing.expect(t,abs(obb_separation(a,b)+0.5)<1e-5)
    r:=rng_make(5,2)
    for _ in 0..<500 {
        c:=Obb{random_in_sphere(&r)*3,random_quat(&r),{random_range(&r,0.2,1.5),random_range(&r,0.2,1.5),random_range(&r,0.2,1.5)}}
        d:=Obb{random_in_sphere(&r)*3,random_quat(&r),{random_range(&r,0.2,1.5),random_range(&r,0.2,1.5),random_range(&r,0.2,1.5)}}
        gap:=obb_separation(c,d)
        if abs(gap)>1e-3 {testing.expect(t,(gap>0)==!obb_overlaps(c,d))}
        if gap>0 {testing.expect(t,gap<=linalg.distance(c.center,d.center),"a lower bound of the distance")}
    }
}

@(private="file")
q4 :: proc(q:Quat) -> Vec4 {return {imag(q),jmag(q),kmag(q),real(q)}}
