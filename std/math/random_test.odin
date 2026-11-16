package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
random_values_repeat_for_a_seed :: proc(t:^testing.T) {
    // Pinned values: any change of platform, compiler or code that alters the sequence fails here.
    rng:=rng_make(2026)
    testing.expect_value(t,rng_u32(&rng),u32(3150398388))
    testing.expect_value(t,random_f32(&rng),f32(0.9138802))
    testing.expect_value(t,random_range(&rng,-10,10),f32(-6.862587))
    testing.expect_value(t,random_below(&rng,1000),u32(377))
    testing.expect_value(t,random_int(&rng,-50,50),-11)
    testing.expect_value(t,random_gaussian(&rng),f32(1.2713554))
    testing.expect_value(t,random_unit_vec3(&rng),Vec3{-0.8311806,-0.11480167,-0.5440215})
    testing.expect_value(t,random_in_cone(&rng,{0,1,0},0.5),Vec3{-0.45845976,0.88667876,-0.060128454})
    a,b:=rng_make(77),rng_make(77)
    for _ in 0..<200 {
        testing.expect_value(t,random_f32(&a),random_f32(&b))
        testing.expect_value(t,random_gaussian(&a),random_gaussian(&b))
        testing.expect_value(t,random_quat(&a),random_quat(&b))
    }
}

@(test)
random_ranges_stay_in_bounds_and_cover_them :: proc(t:^testing.T) {
    rng:=rng_make(1)
    buckets:[10]int
    for _ in 0..<20000 {
        value:=random_f32(&rng)
        if value<0 || value>=1 {testing.expectf(t,false,"random_f32 returned %v",value);break}
        buckets[int(value*10)]+=1
        ranged:=random_range(&rng,-3,5)
        if ranged<-3 || ranged>=5 {testing.expectf(t,false,"random_range returned %v",ranged);break}
    }
    for count in buckets {testing.expect(t,count>1800 && count<2200)}
    faces:[6]int
    for _ in 0..<12000 {
        face:=random_int(&rng,1,7)
        if face<1 || face>6 {testing.expectf(t,false,"random_int returned %v",face);break}
        faces[face-1]+=1
    }
    for count in faces {testing.expect(t,count>1800 && count<2200)}
    testing.expect_value(t,random_below(&rng,0),u32(0))
    testing.expect_value(t,random_below(&rng,1),u32(0))
    testing.expect_value(t,random_int(&rng,5,5),5)
    testing.expect_value(t,random_int(&rng,5,2),5)
    wide:=random_int(&rng,-1<<40,1<<40)
    testing.expect(t,wide>=-1<<40 && wide<1<<40)
    heads,positive:=0,0
    for _ in 0..<10000 {
        if random_bool(&rng,0.25) {heads+=1}
        sign:=random_sign(&rng)
        testing.expect(t,sign==1 || sign==-1)
        if sign>0 {positive+=1}
    }
    testing.expect(t,heads>2300 && heads<2700 && positive>4700 && positive<5300)
    testing.expect(t,!random_bool(&rng,0) && random_bool(&rng,1))
}

@(test)
random_directions_are_unit_and_unbiased :: proc(t:^testing.T) {
    rng:=rng_make(5)
    COUNT :: 20000
    sum2:Vec2
    sum3,sum_ball:Vec3
    inside_half:=0
    for _ in 0..<COUNT {
        circle:=random_unit_vec2(&rng)
        sphere:=random_unit_vec3(&rng)
        disc:=random_in_disc(&rng)
        ball:=random_in_sphere(&rng)
        if !test_close(linalg.length(circle),1,1e-5) || !test_close(linalg.length(sphere),1,1e-5) || linalg.length(disc)>1 || linalg.length(ball)>1 {
            testing.expect(t,false,"A vector left its shape");break
        }
        sum2+=circle;sum3+=sphere;sum_ball+=ball
        // Half of the volume of a ball lies within 0.794 of its radius.
        if linalg.length(ball)<0.7937 {inside_half+=1}
    }
    testing.expect(t,linalg.length(sum2)/COUNT<0.02 && linalg.length(sum3)/COUNT<0.02 && linalg.length(sum_ball)/COUNT<0.02)
    testing.expect(t,inside_half>COUNT/2-400 && inside_half<COUNT/2+400)
    // A cone keeps every direction within its angle, and fills it evenly by solid angle.
    axis:=linalg.normalize(Vec3{1,-2,0.5})
    half_angle:=f32(0.6)
    inner:=0
    for _ in 0..<COUNT {
        direction:=random_in_cone(&rng,axis*3,half_angle)
        cosine:=linalg.dot(direction,axis)
        if !test_close(linalg.length(direction),1,1e-5) || cosine<math.cos(half_angle)-1e-4 {testing.expectf(t,false,"%v is outside the cone",direction);break}
        if cosine>(1+math.cos(half_angle))*0.5 {inner+=1}
    }
    testing.expect(t,inner>COUNT/2-400 && inner<COUNT/2+400)
    testing.expect(t,test_close3(random_in_cone(&rng,{0,0,-1},0),{0,0,-1}))
    testing.expect(t,test_close(linalg.length(random_in_cone(&rng,{},PI)),1,1e-5))
    // Uniform rotations move a fixed vector to a uniform direction.
    turned:Vec3
    for _ in 0..<COUNT {
        q:=random_quat(&rng)
        if !test_close(abs(q),1,1e-5) {testing.expect(t,false,"A rotation is not unit");break}
        turned+=quat_rotate(q,{1,0,0})
    }
    testing.expect(t,linalg.length(turned)/COUNT<0.02)
}

@(test)
random_gaussian_has_the_mean_and_deviation_asked :: proc(t:^testing.T) {
    rng:=rng_make(9)
    COUNT :: 40000
    sum,squares:f64
    within:=0
    for _ in 0..<COUNT {
        value:=f64(random_gaussian(&rng,3,2))
        sum+=value;squares+=value*value
        if abs(value-3)<2 {within+=1}
    }
    mean:=sum/COUNT
    deviation:=math.sqrt(squares/COUNT-mean*mean)
    testing.expect(t,abs(mean-3)<0.05 && abs(deviation-2)<0.05)
    testing.expect(t,abs(f64(within)/COUNT-0.6827)<0.01,"68% of the values fall within one deviation")
}

@(test)
random_weighted_and_shuffle_respect_their_inputs :: proc(t:^testing.T) {
    rng:=rng_make(3)
    weights:=[5]f32{1,0,3,-2,4}
    picks:[5]int
    for _ in 0..<16000 {picks[random_weighted(&rng,weights[:])]+=1}
    testing.expect(t,picks[1]==0 && picks[3]==0,"Weights of 0 or less are never picked")
    testing.expect(t,picks[0]>1800 && picks[0]<2200 && picks[2]>5700 && picks[2]<6300 && picks[4]>7700 && picks[4]<8300)
    testing.expect_value(t,random_weighted(&rng,nil),-1)
    none:=[2]f32{0,-1}
    testing.expect_value(t,random_weighted(&rng,none[:]),-1)
    one:=[3]f32{0,2,0}
    testing.expect_value(t,random_weighted(&rng,one[:]),1)
    items:[8]int
    first:[8]int
    for _ in 0..<4000 {
        for &item,i in items {item=i}
        random_shuffle(&rng,items[:])
        seen:u32
        for item in items {seen|=1<<uint(item)}
        if seen!=0xff {testing.expect(t,false,"The shuffle lost an item");break}
        first[items[0]]+=1
    }
    for count in first {testing.expect(t,count>400 && count<600,"Every item is as likely to end up first")}
    empty:[]int
    random_shuffle(&rng,empty)
}

@(test)
lattice_noise_is_bounded_smooth_and_repeatable :: proc(t:^testing.T) {
    rng:=rng_make(12)
    low,high:=f32(1),f32(-1)
    for _ in 0..<20000 {
        p:=Vec3{random_range(&rng,-50,50),random_range(&rng,-50,50),random_range(&rng,-50,50)}
        values:=[6]f32{noise_value2(p.xy),noise_value3(p),noise_perlin2(p.xy),noise_perlin3(p),noise_simplex2(p.xy),noise_simplex3(p)}
        for value in values {
            if math.is_nan(value) || abs(value)>1.001 {testing.expectf(t,false,"%v at %v",values,p);return}
        }
        low=min(low,values[2],values[3]);high=max(high,values[2],values[3])
    }
    testing.expect(t,low<-0.7 && high>0.7,"Perlin noise uses most of its range")
    // Pinned values: the lattice noises are part of what a seed reproduces.
    testing.expect_value(t,noise_value2({1.5,2.25}),f32(0.43333778))
    testing.expect_value(t,noise_value3({1.5,2.25,-3.75},7),f32(0.019131072))
    testing.expect_value(t,noise_perlin2({1.5,2.25}),f32(0.24999997))
    testing.expect_value(t,noise_perlin3({1.5,2.25,-3.75},7),f32(0.33090258))
    // Gradient noise is 0 on the lattice; value noise is not.
    testing.expect_value(t,noise_perlin2({3,-7}),f32(0))
    testing.expect_value(t,noise_perlin3({3,-7,11}),f32(0))
    testing.expect(t,noise_value2({3,-7})!=0)
    // Smooth: a small step changes the value a little; a seed changes it a lot.
    different:=0
    for _ in 0..<200 {
        p:=Vec3{random_range(&rng,-50,50),random_range(&rng,-50,50),random_range(&rng,-50,50)}
        step:=Vec3{1e-3,1e-3,1e-3}
        testing.expect(t,abs(noise_perlin3(p+step)-noise_perlin3(p))<0.02 && abs(noise_value3(p+step)-noise_value3(p))<0.02)
        testing.expect(t,abs(noise_perlin2(p.xy+step.xy)-noise_perlin2(p.xy))<0.02 && abs(noise_simplex3(p+step)-noise_simplex3(p))<0.05)
        if abs(noise_perlin3(p,1)-noise_perlin3(p,2))>0.05 {different+=1}
    }
    testing.expect(t,different>120)
}

@(test)
worley_noise_measures_distance_to_feature_points :: proc(t:^testing.T) {
    rng:=rng_make(14)
    for _ in 0..<5000 {
        p:=Vec3{random_range(&rng,-20,20),random_range(&rng,-20,20),random_range(&rng,-20,20)}
        near2,far2:=noise_worley2(p.xy,3)
        near3,far3:=noise_worley3(p,3)
        // With a point in every cell, no place is farther than the diagonal of a cell from one.
        if near2<0 || near2>far2 || near2>1.4143 || near3<0 || near3>far3 || near3>1.7321 {testing.expectf(t,false,"%v %v %v %v at %v",near2,far2,near3,far3,p);return}
    }
    // Walking away from a feature point, the distance grows at the speed of the walk.
    p:=Vec2{4.3,-2.6}
    near,_:=noise_worley2(p)
    best:=near
    position:=p
    for _ in 0..<200 {
        for step in ([4]Vec2{{0.01,0},{-0.01,0},{0,0.01},{0,-0.01}}) {
            candidate,_:=noise_worley2(position+step)
            if candidate<best {best=candidate;position+=step;break}
        }
    }
    testing.expect(t,best<0.02,"Following the slope down ends on a feature point")
}

@(test)
fractal_noise_adds_detail_within_its_range :: proc(t:^testing.T) {
    rng:=rng_make(15)
    for kind in Noise_Kind {
        fractal:=Fractal{kind,6,2,0.5,11}
        rough:f32
        smooth:f32
        for _ in 0..<2000 {
            p:=Vec3{random_range(&rng,-30,30),random_range(&rng,-30,30),random_range(&rng,-30,30)}
            fbm2,fbm3:=noise_fbm2(p.xy,fractal),noise_fbm3(p,fractal)
            ridged2,ridged3:=noise_ridged2(p.xy,fractal),noise_ridged3(p,fractal)
            turbulence2,turbulence3:=noise_turbulence2(p.xy,fractal),noise_turbulence3(p,fractal)
            if abs(fbm2)>1.001 || abs(fbm3)>1.001 {testing.expectf(t,false,"%v fbm: %v %v",kind,fbm2,fbm3);return}
            if ridged2<0 || ridged2>1.001 || ridged3<0 || ridged3>1.001 {testing.expectf(t,false,"%v ridged: %v %v",kind,ridged2,ridged3);return}
            if turbulence2<0 || turbulence2>1.001 || turbulence3<0 || turbulence3>1.001 {testing.expectf(t,false,"%v turbulence: %v %v",kind,turbulence2,turbulence3);return}
            // More octaves change more over a short distance.
            step:=Vec3{0.02,0.02,0.02}
            one:=Fractal{kind,1,2,0.5,11}
            rough+=abs(noise_fbm3(p+step,fractal)-fbm3)*1.96875
            smooth+=abs(noise_fbm3(p+step,one)-noise_fbm3(p,one))
        }
        testing.expectf(t,rough>smooth*1.5,"%v: %v against %v",kind,rough,smooth)
    }
    single:=Fractal{.Perlin,1,2,0.5,4}
    testing.expect_value(t,noise_fbm3({1.3,2.7,-0.4},single),noise_perlin3({1.3,2.7,-0.4},4))
    testing.expect_value(t,noise_fbm2({1.3,2.7},{kind=.Value,seed=4}),noise_value2({1.3,2.7},4))
    testing.expect_value(t,noise_fbm2({1.3,2.7}),noise_fbm2({1.3,2.7},FRACTAL_DEFAULT))
}

@(test)
curl_noise_has_no_divergence :: proc(t:^testing.T) {
    rng:=rng_make(16)
    STEP :: 1e-2
    moving:=0
    for _ in 0..<300 {
        p:=Vec3{random_range(&rng,-20,20),random_range(&rng,-20,20),random_range(&rng,-20,20)}
        // The same centered differences the field is built from cancel exactly, up to rounding.
        divergence2:=(noise_curl2({p.x+STEP,p.y}).x-noise_curl2({p.x-STEP,p.y}).x+noise_curl2({p.x,p.y+STEP}).y-noise_curl2({p.x,p.y-STEP}).y)/(2*STEP)
        divergence3:=(noise_curl3(p+{STEP,0,0}).x-noise_curl3(p-{STEP,0,0}).x+noise_curl3(p+{0,STEP,0}).y-noise_curl3(p-{0,STEP,0}).y+noise_curl3(p+{0,0,STEP}).z-noise_curl3(p-{0,0,STEP}).z)/(2*STEP)
        if abs(divergence2)>0.05 || abs(divergence3)>0.05 {testing.expectf(t,false,"divergence %v and %v at %v",divergence2,divergence3,p);return}
        if linalg.length(noise_curl3(p))>0.3 && linalg.length(noise_curl2(p.xy))>0.1 {moving+=1}
    }
    testing.expect(t,moving>100,"The field is not at rest")
    testing.expect_value(t,noise_curl3({1.3,2.7,-0.4},5),noise_curl3({1.3,2.7,-0.4},5))
    testing.expect(t,noise_curl3({1.3,2.7,-0.4},5)!=noise_curl3({1.3,2.7,-0.4},6))
}

@(test)
perlin_gradient_is_the_slope_of_the_noise :: proc(t:^testing.T) {
    rng:=rng_make(18)
    STEP :: 2e-3
    for _ in 0..<500 {
        p:=Vec3{random_range(&rng,-30,30),random_range(&rng,-30,30),random_range(&rng,-30,30)}
        value3,gradient3:=noise_perlin3_gradient(p,9)
        value2,gradient2:=noise_perlin2_gradient(p.xy,9)
        if !test_close(value3,noise_perlin3(p,9),1e-6) || !test_close(value2,noise_perlin2(p.xy,9),1e-6) {testing.expectf(t,false,"The value differs at %v",p);return}
        numeric3:Vec3
        for axis in 0..<3 {
            offset:Vec3
            offset[axis]=STEP
            numeric3[axis]=(noise_perlin3(p+offset,9)-noise_perlin3(p-offset,9))/(2*STEP)
        }
        numeric2:=Vec2{noise_perlin2({p.x+STEP,p.y},9)-noise_perlin2({p.x-STEP,p.y},9),noise_perlin2({p.x,p.y+STEP},9)-noise_perlin2({p.x,p.y-STEP},9)}/(2*STEP)
        if !test_close3(gradient3,numeric3,0.02) || linalg.length(gradient2-numeric2)>0.02 {testing.expectf(t,false,"gradient %v %v, measured %v %v at %v",gradient3,gradient2,numeric3,numeric2,p);return}
    }
    // On the lattice the value is 0 and the gradient is the direction of that lattice point.
    value,gradient:=noise_perlin3_gradient({4,-2,7},9)
    testing.expect_value(t,value,f32(0))
    testing.expect(t,test_close(linalg.length(gradient),math.SQRT_TWO,1e-5))
}
