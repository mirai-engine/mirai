package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
remap_and_steps_map_ranges :: proc(t:^testing.T) {
    testing.expect_value(t,remap(5,0,10,100,200),f32(150))
    testing.expect_value(t,remap(15,0,10,100,200),f32(250))
    testing.expect_value(t,remap(2,4,0,0,1),f32(0.5))
    testing.expect_value(t,remap(7,3,3,5,9),f32(5))
    testing.expect_value(t,remap_clamped(15,0,10,100,200),f32(200))
    testing.expect_value(t,remap_clamped(-3,0,10,100,200),f32(100))
    testing.expect_value(t,remap_clamped(7,3,3,5,9),f32(5))
    testing.expect_value(t,saturate(1.5),f32(1))
    testing.expect_value(t,saturate(-0.5),f32(0))
    testing.expect_value(t,saturate(0.25),f32(0.25))
    testing.expect_value(t,lerp(f32(2),f32(4),f32(0.25)),f32(2.5))
    testing.expect_value(t,lerp(Vec2{0,10},Vec2{10,0},f32(0.5)),Vec2{5,5})
    testing.expect_value(t,smoothstep(0,1,-1),f32(0))
    testing.expect_value(t,smoothstep(0,1,2),f32(1))
    testing.expect_value(t,smoothstep(2,4,3),f32(0.5))
    testing.expect_value(t,smoothstep(0,1,0.25),f32(0.15625))
    testing.expect_value(t,smoothstep(1,1,0.5),f32(0))
    testing.expect_value(t,smoothstep(1,1,1),f32(1))
    testing.expect_value(t,smootherstep(0,1,0.5),f32(0.5))
    testing.expect(t,smootherstep(0,1,0.25)<smoothstep(0,1,0.25))
    testing.expect_value(t,smootherstep(3,3,4),f32(1))
}

@(test)
approach_never_passes_the_target :: proc(t:^testing.T) {
    testing.expect_value(t,approach(0,10,3),f32(3))
    testing.expect_value(t,approach(9,10,3),f32(10))
    testing.expect_value(t,approach(0,-10,3),f32(-3))
    testing.expect_value(t,approach(5,5,3),f32(5))
    testing.expect(t,test_close3(approach_point(Vec3{0,0,0},Vec3{3,4,0},1),{0.6,0.8,0}))
    testing.expect_value(t,approach_point(Vec3{0,0,0},Vec3{3,4,0},6),Vec3{3,4,0})
    testing.expect_value(t,approach_point(Vec2{1,1},Vec2{1,1},1),Vec2{1,1})
}

@(test)
angles_wrap_and_take_the_short_way :: proc(t:^testing.T) {
    DEG :: f32(RAD_PER_DEG)
    testing.expect(t,test_close(angle_wrap(190*DEG),-170*DEG,1e-5))
    testing.expect(t,test_close(angle_wrap(-190*DEG),170*DEG,1e-5))
    testing.expect(t,test_close(angle_wrap(725*DEG),5*DEG,1e-4))
    testing.expect_value(t,angle_wrap(0),f32(0))
    testing.expect(t,angle_wrap(PI)<0,"The range is closed below and open above")
    for turns in -3..=3 {
        wrapped:=angle_wrap(1+f32(turns)*TAU)
        testing.expect(t,wrapped>=-PI && wrapped<PI && test_close(wrapped,1,1e-4))
    }
    testing.expect(t,test_close(angle_delta(350*DEG,10*DEG),20*DEG,1e-5))
    testing.expect(t,test_close(angle_delta(10*DEG,350*DEG),-20*DEG,1e-5))
    testing.expect(t,test_close(angle_delta(0,90*DEG),90*DEG,1e-5))
    testing.expect(t,test_close(angle_lerp(350*DEG,10*DEG,0.5),360*DEG,1e-4))
    testing.expect(t,test_close(angle_approach(350*DEG,10*DEG,5*DEG),355*DEG,1e-5))
    testing.expect_value(t,angle_approach(350*DEG,10*DEG,30*DEG),10*DEG)
    testing.expect(t,test_close(angle_approach(10*DEG,350*DEG,5*DEG),5*DEG,1e-5))
}

@(test)
damp_does_not_depend_on_the_frame_rate :: proc(t:^testing.T) {
    once:=damp(f32(0),f32(10),4,0.5)
    stepped:=f32(0)
    for _ in 0..<50 {stepped=damp(stepped,f32(10),4,0.01)}
    testing.expect(t,test_close(once,stepped,1e-3))
    testing.expect(t,test_close(once,10*(1-math.exp(f32(-2))),1e-5))
    testing.expect_value(t,damp(f32(3),f32(10),4,0),f32(3))
    testing.expect(t,test_close(damp(f32(0),f32(10),1,1),10*0.6321206,1e-4),"63% of the gap closes in 1/rate seconds")
    vector:=damp(Vec3{0,0,0},Vec3{10,20,30},4,0.5)
    testing.expect(t,test_close3(vector,Vec3{10,20,30}*(once/10),1e-3))
    DEG :: f32(RAD_PER_DEG)
    turned:=damp_angle(350*DEG,10*DEG,4,0.5)
    testing.expect(t,turned>350*DEG && turned<370*DEG,"Angles damp along the short way")
    testing.expect(t,test_close(turned,350*DEG+20*DEG*(once/10),1e-4))
}

@(test)
critical_spring_reaches_the_target_without_overshoot :: proc(t:^testing.T) {
    omega:=spring_omega(0.25)
    value,velocity:=spring_critical(f32(0),f32(0),f32(1),omega,0.25)
    testing.expect(t,test_close(value,0.5,1e-4),"Half of the gap closes in the half life")
    // Any split of the time gives the same state.
    stepped,stepped_velocity:=f32(0),f32(0)
    for _ in 0..<25 {stepped,stepped_velocity=spring_critical(stepped,stepped_velocity,f32(1),omega,0.01)}
    testing.expect(t,test_close(stepped,value,1e-4) && test_close(stepped_velocity,velocity,1e-3))
    position,speed:=f32(0),f32(0)
    highest:=f32(0)
    for _ in 0..<600 {
        position,speed=spring_critical(position,speed,f32(1),omega,1.0/60)
        highest=max(highest,position)
        testing.expect(t,speed>=-1e-5,"From rest it never turns back")
    }
    testing.expect(t,highest<=1.00001 && test_close(position,1,1e-4) && test_close(speed,0,1e-3))
    // A huge step is stable: it lands on the target.
    far,far_speed:=spring_critical(f32(-50),f32(1000),f32(1),omega,100)
    testing.expect(t,test_close(far,1) && test_close(far_speed,0))
    still,still_speed:=spring_critical(f32(3),f32(2),f32(1),omega,0)
    testing.expect_value(t,still,f32(3))
    testing.expect(t,test_close(still_speed,2,1e-5))
    point,point_velocity:=spring_critical(Vec3{0,0,0},Vec3{0,0,0},Vec3{1,2,3},omega,0.25)
    testing.expect(t,test_close3(point,{0.5,1,1.5},1e-4) && test_close3(point_velocity,Vec3{1,2,3}*velocity,1e-3))
    // With velocity toward the target it overshoots, as a real spring would.
    thrown,_:=spring_critical(f32(0.9),f32(20),f32(1),omega,0.05)
    testing.expect(t,thrown>1)
}

@(test)
snap_rounds_to_a_grid :: proc(t:^testing.T) {
    testing.expect_value(t,snap(f32(0.74),0.5),f32(0.5))
    testing.expect_value(t,snap(f32(0.76),0.5),f32(1))
    testing.expect_value(t,snap(f32(-0.76),0.5),f32(-1))
    testing.expect_value(t,snap(f32(0.74),0),f32(0.74))
    testing.expect_value(t,snap(Vec3{0.2,0.3,-1.9},0.5),Vec3{0,0.5,-2})
    testing.expect_value(t,snap(Vec2{0.2,0.3},0),Vec2{0.2,0.3})
    testing.expect_value(t,snap_from(1.3,0.25,1),f32(1.25))
    testing.expect_value(t,snap_from(1.9,0.25,1),f32(2.25))
    DEG :: f32(RAD_PER_DEG)
    testing.expect(t,test_close(snap(52*DEG,15*DEG),45*DEG,1e-5))
}

@(test)
every_ease_starts_at_zero_and_ends_at_one :: proc(t:^testing.T) {
    for kind in Ease {
        testing.expectf(t,test_close(ease_apply(kind,0),0,1e-3),"%v at 0 is %v",kind,ease_apply(kind,0))
        testing.expectf(t,test_close(ease_apply(kind,1),1,1e-3),"%v at 1 is %v",kind,ease_apply(kind,1))
        for step in 0..=100 {
            value:=ease_apply(kind,f32(step)/100)
            if math.is_nan(value) || value<-0.5 || value>1.5 {testing.expectf(t,false,"%v at %d%% is %v",kind,step,value);break}
        }
    }
    testing.expect_value(t,len(Ease),31)
    testing.expect_value(t,Ease.Bounce_In_Out,Ease(30))
    testing.expect_value(t,ease_apply(.Linear,0.3),f32(0.3))
}

@(test)
ease_families_mirror_in_and_out :: proc(t:^testing.T) {
    // The enum lists every family as In, Out, In_Out.
    for family:=int(Ease.Quad_In);family<=int(Ease.Bounce_In);family+=3 {
        ease_in,ease_out,ease_in_out:=Ease(family),Ease(family+1),Ease(family+2)
        for step in 0..=20 {
            x:=f32(step)/20
            mirrored:=1-ease_apply(ease_in,1-x)
            if !test_close(ease_apply(ease_out,x),mirrored,1e-3) {testing.expectf(t,false,"%v at %v is %v, the mirror of In is %v",ease_out,x,ease_apply(ease_out,x),mirrored);break}
            first_half:=ease_apply(ease_in,x)*0.5
            second_half:=0.5+ease_apply(ease_out,x)*0.5
            if !test_close(ease_apply(ease_in_out,x*0.5),first_half,2e-3) || !test_close(ease_apply(ease_in_out,0.5+x*0.5),second_half,2e-3) {
                // Back and elastic use their own constants for the combined curve.
                if family!=int(Ease.Back_In) && family!=int(Ease.Elastic_In) {testing.expectf(t,false,"%v does not join its two halves at %v",ease_in_out,x);break}
            }
        }
        testing.expect(t,test_close(ease_apply(ease_in_out,0.5),0.5,1e-3))
    }
}

@(test)
eases_match_their_reference_values :: proc(t:^testing.T) {
    testing.expect_value(t,ease_quad_in(0.5),f32(0.25))
    testing.expect_value(t,ease_quad_out(0.5),f32(0.75))
    testing.expect_value(t,ease_cubic_in(0.5),f32(0.125))
    testing.expect_value(t,ease_cubic_out(0.5),f32(0.875))
    testing.expect_value(t,ease_quart_in(0.5),f32(0.0625))
    testing.expect_value(t,ease_quint_in(0.5),f32(0.03125))
    testing.expect(t,test_close(ease_sine_in(0.5),1-math.cos(f32(PI/4)),1e-5))
    testing.expect(t,test_close(ease_expo_in(0.5),0.03125,1e-5))
    testing.expect(t,test_close(ease_circ_in(0.6),0.2,1e-5))
    testing.expect(t,test_close(ease_bounce_out(0.5),0.765625,1e-5))
    testing.expect(t,test_close(ease_bounce_out(0.2),0.3025,1e-5))
    // Penner's back with the classic overshoot of 1.70158.
    testing.expect(t,test_close(ease_back_in(0.5),-0.0876975,1e-5))
    testing.expect(t,test_close(ease_back_out(0.5),1.0876975,1e-5))
    lowest:=f32(0)
    for step in 0..=100 {lowest=min(lowest,ease_back_in(f32(step)/100))}
    testing.expect(t,test_close(lowest,-0.1,2e-3),"Back pulls back about a tenth before going")
    testing.expect(t,test_close(ease_back_in_out(0.25),-0.0996818,1e-4))
    // Penner's elastic with a period of 0.3.
    testing.expect(t,test_close(ease_elastic_out(0.5),1.015625,1e-4))
    testing.expect(t,test_close(ease_elastic_in(0.5),-0.015625,1e-4))
    testing.expect(t,test_close(ease_elastic_out(0.15),1.3535534,1e-3),"The first swing goes well past the target")
    for kind in ([?]Ease{.Quad_In,.Cubic_Out,.Sine_In_Out,.Expo_In,.Circ_Out,.Quint_In_Out}) {
        previous:=f32(0)
        for step in 1..=100 {
            value:=ease_apply(kind,f32(step)/100)
            if value<previous-1e-6 {testing.expectf(t,false,"%v goes back at %d%%",kind,step);break}
            previous=value
        }
    }
}

@(test)
curves_pass_through_their_points :: proc(t:^testing.T) {
    a,b,c,d:=Vec3{0,0,0},Vec3{1,2,0},Vec3{3,2,1},Vec3{4,0,1}
    testing.expect_value(t,bezier_quadratic(a,b,c,0),a)
    testing.expect_value(t,bezier_quadratic(a,b,c,1),c)
    testing.expect(t,test_close3(bezier_quadratic(a,b,c,0.5),a*0.25+b*0.5+c*0.25))
    testing.expect_value(t,bezier_cubic(a,b,c,d,0),a)
    testing.expect_value(t,bezier_cubic(a,b,c,d,1),d)
    testing.expect(t,test_close3(bezier_cubic(a,b,c,d,0.5),(a+b*3+c*3+d)/8))
    testing.expect(t,test_close3(bezier_cubic_tangent(a,b,c,d,0),(b-a)*3) && test_close3(bezier_cubic_tangent(a,b,c,d,1),(d-c)*3))
    testing.expect(t,test_close3(bezier_quadratic_tangent(a,b,c,0),(b-a)*2) && test_close3(bezier_quadratic_tangent(a,b,c,1),(c-b)*2))
    testing.expect_value(t,bezier_cubic(f32(0),f32(0),f32(1),f32(1),0.5),f32(0.5))
    // Tangents agree with finite differences.
    for x in ([3]f32{0.2,0.5,0.9}) {
        STEP :: 1e-3
        numeric:=(bezier_cubic(a,b,c,d,x+STEP)-bezier_cubic(a,b,c,d,x-STEP))/(2*STEP)
        testing.expect(t,test_close3(bezier_cubic_tangent(a,b,c,d,x),numeric,1e-2))
        numeric=(catmull_rom(a,b,c,d,x+STEP)-catmull_rom(a,b,c,d,x-STEP))/(2*STEP)
        testing.expect(t,test_close3(catmull_rom_tangent(a,b,c,d,x),numeric,1e-2))
    }
    testing.expect_value(t,hermite(a,b,c,d,0),a)
    testing.expect(t,test_close3(hermite(a,b,c,d,1),c))
    testing.expect(t,test_close3((hermite(a,b,c,d,1e-3)-a)/1e-3,b,2e-2),"It leaves with the first derivative")
    testing.expect(t,test_close3((c-hermite(a,b,c,d,1-1e-3))/1e-3,d,2e-2),"It arrives with the second")
    testing.expect_value(t,catmull_rom(a,b,c,d,0),b)
    testing.expect(t,test_close3(catmull_rom(a,b,c,d,1),c))
    testing.expect(t,test_close3(catmull_rom_tangent(a,b,c,d,0),(c-a)*0.5) && test_close3(catmull_rom_tangent(a,b,c,d,1),(d-b)*0.5))
    // Four points on a line, evenly spaced: every spline stays on it at even speed.
    p0,p1,p2,p3:=Vec2{0,0},Vec2{1,1},Vec2{2,2},Vec2{3,3}
    testing.expect(t,linalg.length(catmull_rom(p0,p1,p2,p3,0.25)-Vec2{1.25,1.25})<1e-5)
    testing.expect(t,linalg.length(b_spline(p0,p1,p2,p3,0.25)-Vec2{1.25,1.25})<1e-5)
    testing.expect(t,test_close3(b_spline(a,b,c,d,0),(a+b*4+c)/6),"A B-spline starts near its second point, not on it")
    testing.expect(t,test_close3(b_spline(a,b,c,d,1),(b+c*4+d)/6))
    // Consecutive B-spline segments join.
    e:=Vec3{5,1,0}
    testing.expect(t,test_close3(b_spline(a,b,c,d,1),b_spline(b,c,d,e,0)))
}

// A path sampled by length goes through its points, its samples about a piece
// apart, and fits what holds them, whatever the points are.
@(test)
a_sampled_path_goes_through_its_points_and_fits :: proc(t:^testing.T) {
    points:=[]Path_Point{{{0,0,0},2,1},{{0,0,-10},4,1},{{10,0,-10},4,3}}
    out:[64]Path_Point
    count:=path_sample(points,1,out[:])
    testing.expect(t,count>=21 && count<=23,"about a piece apart")
    testing.expect(t,out[0]==points[0] && out[count-1]==points[2])
    through:=false
    for p in out[:count] {through||=p==points[1]}
    testing.expect(t,through,"through every point")
    for i in 1..<count {
        gap:=linalg.length(out[i].position-out[i-1].position)
        testing.expectf(t,gap>0.5 && gap<1.3,"a gap of %v",gap)
    }
    testing.expect(t,abs(out[5].width-3)<1e-5 && out[5].height==1,"width and height in proportion")
    // Too few samples for a piece: they spread out, and the ends stay.
    short:[8]Path_Point
    count=path_sample(points,1,short[:])
    testing.expect(t,count>=3 && count<=8 && short[count-1]==points[2])
    nan:=math.nan_f32()
    for c in ([]struct{points:[]Path_Point,piece:f32,room:int}{
        {points[:1],1,64},{points,0,64},{points,nan,64},{points,1,3},
        {{{{nan,0,0},1,1},{{0,0,1},1,1}},1,64},{{{{0,0,0},1,1},{{1e38,0,0},1,1}},1,64},{{{{0,0,0},1,1},{{0,0,0},1,1}},1,64},
    }) {
        written:=path_sample(c.points,c.piece,out[:c.room])
        testing.expect(t,written==0 || written>=len(c.points) && written<=c.room)
    }
}

@(test)
arc_table_gives_constant_speed :: proc(t:^testing.T) {
    SAMPLES :: 65
    // A quarter of a circle of radius 2, sampled unevenly along its length by a squared parameter.
    points:[SAMPLES]Vec2
    lengths:[SAMPLES]f32
    for &point,i in points {
        s:=f32(i)/(SAMPLES-1)
        angle:=s*s*(PI/2)
        point={2*math.cos(angle),2*math.sin(angle)}
    }
    total:=arc_table_build(points[:],lengths[:])
    testing.expect(t,test_close(total,PI,2e-3))
    testing.expect_value(t,lengths[0],f32(0))
    testing.expect_value(t,lengths[SAMPLES-1],total)
    testing.expect_value(t,arc_table_parameter(lengths[:],0),f32(0))
    testing.expect_value(t,arc_table_parameter(lengths[:],-1),f32(0))
    testing.expect_value(t,arc_table_parameter(lengths[:],total+1),f32(1))
    // Half of the length is half of the angle, which the squared parameter reaches at sqrt(0.5).
    halfway:=arc_table_parameter(lengths[:],total*0.5)
    testing.expect(t,test_close(halfway,math.sqrt(f32(0.5)),2e-3))
    for step in 0..=10 {
        distance:=total*f32(step)/10
        parameter:=arc_table_parameter(lengths[:],distance)
        testing.expect(t,test_close(arc_table_distance(lengths[:],parameter),distance,1e-3))
    }
    testing.expect_value(t,arc_table_distance(lengths[:],0),f32(0))
    testing.expect_value(t,arc_table_distance(lengths[:],2),total)
    testing.expect_value(t,arc_table_parameter(nil,1),f32(0))
    testing.expect_value(t,arc_table_distance(lengths[:1],0.5),f32(0))
    flat:=[3]Vec3{{1,1,1},{1,1,1},{1,1,1}}
    testing.expect_value(t,arc_table_build(flat[:],lengths[:3]),f32(0))
    testing.expect_value(t,arc_table_parameter(lengths[:3],0.5),f32(1))
}

