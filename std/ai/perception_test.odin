package ai

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

// The time to forget is seconds: at 60 and at 120 Hz it takes as long.
@(test)
a_memory_forgets_what_it_stops_perceiving :: proc(t:^testing.T) {
    for hz in ([]u64{60,120}) {
        dt:=1/f32(hz)
        m:Perception_Memory
        testing.expect_value(t,memory_perceive(&m,7,{1,0,0},.Sight,1,0),Memory_Change.New)
        testing.expect_value(t,memory_perceive(&m,7,{2,0,0},.Hearing,0.5,0),Memory_Change.Again)
        o:=memory_find(&m,7)
        testing.expect(t,o!=nil && o.senses=={.Sight,.Hearing} && o.confidence==1 && o.position=={2,0,0})
        gone:[4]u64
        testing.expect_value(t,memory_forget(&m,0,dt,2,gone[:]),0)
        testing.expect_value(t,memory_forget(&m,hz,dt,2,gone[:]),0)
        o=memory_find(&m,7)
        testing.expect(t,o!=nil && abs(o.confidence-0.5)<1e-4 && o.senses=={})
        // Perceived again, it is sure again; then forgotten after the time to forget.
        memory_perceive(&m,7,{3,0,0},.Sight,1,hz*3/2)
        testing.expect_value(t,memory_forget(&m,hz*7/2-1,dt,2,gone[:]),0)
        testing.expect_value(t,memory_forget(&m,hz*7/2,dt,2,gone[:]),1)
        testing.expect(t,gone[0]==7 && m.count==0 && memory_find(&m,7)==nil)
    }
}

@(test)
a_full_memory_gives_the_least_sure_place_to_a_surer_subject :: proc(t:^testing.T) {
    m:Perception_Memory
    for i in 0..<PERCEPTION_CAPACITY {memory_perceive(&m,u64(i+1),{},.Hearing,0.5+f32(i)*0.01,0)}
    testing.expect_value(t,memory_perceive(&m,100,{},.Hearing,0.2,0),Memory_Change.None)
    testing.expect_value(t,memory_perceive(&m,100,{},.Sight,1,0),Memory_Change.New)
    testing.expect(t,memory_find(&m,1)==nil && memory_find(&m,100)!=nil && m.replaced==1)
    best,ok:=memory_best(&m,{})
    testing.expect(t,ok && best.subject==100)
}

@(test)
sight_takes_points_in_its_cone_and_range :: proc(t:^testing.T) {
    eye,forward:=math.Vec3{0,1.6,0},math.Vec3{0,0,-1}
    testing.expect(t,sight_in_cone(eye,forward,{0,1.6,-5},10,0.5))
    testing.expect(t,!sight_in_cone(eye,forward,{0,1.6,-11},10,0.5))
    testing.expect(t,!sight_in_cone(eye,forward,{5,1.6,-1},10,0.5))
    testing.expect(t,sight_in_cone(eye,forward,{0,1.6,5},10,math.PI))
}

@(test)
places_are_laid_out_and_the_best_kept_in_order :: proc(t:^testing.T) {
    ring:[16]math.Vec3
    n:=places_rings({1,2,3},2,4,2,4,ring[:])
    testing.expect_value(t,n,8)
    for p in ring[:4] {testing.expect(t,abs(linalg.distance(p,math.Vec3{1,2,3})-2)<1e-4 && p.y==2)}
    for p in ring[4:8] {testing.expect(t,abs(linalg.distance(p,math.Vec3{1,2,3})-4)<1e-4)}
    // A half turn facing +z: on each ring from +x through +z to -x, ends included.
    arc:[6]math.Vec3
    testing.expect_value(t,places_rings({},2,4,2,3,arc[:],{0,0,1},math.PI),6)
    for p,i in arc {
        radius:=f32(2 if i<3 else 4)
        ends:=[3]math.Vec3{{radius,0,0},{0,0,radius},{-radius,0,0}}
        testing.expectf(t,linalg.distance(p,ends[i%3])<1e-4,"%d: %v",i,p)
    }
    testing.expect_value(t,places_rings({},2,4,1,1,arc[:],{1,0,0},1),1)
    testing.expect(t,linalg.distance(arc[0],math.Vec3{2,0,0})<1e-4,"one point faces ahead")
    testing.expect_value(t,places_rings({},2,4,1,3,arc[:],{0,1,0},1),0)
    grid:[64]math.Vec3
    testing.expect_value(t,places_grid({},2,1,grid[:]),25)
    // Nearer to a point is better; one input per candidate: its distance.
    inputs:[25]f32
    for p,i in grid[:25] {inputs[i]=linalg.distance(p,math.Vec3{1,0,1})}
    near:=[]Consideration{{input=0,min=0,max=4,response={kind=.Linear,slope=-1,shift_y=1}}}
    best:[3]Place_Score
    kept:=places_best(near,inputs[:],1,best[:])
    testing.expect(t,kept==3 && grid[best[0].index]=={1,0,1} && best[0].score>=best[1].score && best[1].score>=best[2].score)
    testing.expect_value(t,places_best(near,inputs[:],0,best[:]),0)
}
