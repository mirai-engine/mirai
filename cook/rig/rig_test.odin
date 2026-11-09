package rig

import "core:math"
import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// A person of boxes 1.8 m tall facing -Z: legs, torso, head and two arms of
// six segments that leave the shoulders at `down` radians below the
// horizontal. A skirt joins the legs from the hips to the knees.
@(private="file")
boxes :: proc(down:f32,skirt:bool) -> Mesh {
    positions:=make([dynamic][3]f32,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    box :: proc(positions:^[dynamic][3]f32,indices:^[dynamic]u32,center,half:mm.Vec3,turn:mm.Quat=1) {
        first:=u32(len(positions))
        for i in 0..<8 {
            corner:=mm.Vec3{half.x if i&1!=0 else -half.x,half.y if i&2!=0 else -half.y,half.z if i&4!=0 else -half.z}
            append(positions,center+mm.quat_rotate(turn,corner))
        }
        FACES :: [?]u32{0,2,1,1,2,3,4,5,6,5,7,6,0,1,4,1,5,4,2,6,3,3,6,7,0,4,2,2,4,6,1,3,5,3,7,5}
        for k in FACES {append(indices,first+k)}
    }
    box(&positions,&indices,{0.1,0.43,0},{0.07,0.43,0.08})
    box(&positions,&indices,{-0.1,0.43,0},{0.07,0.43,0.08})
    box(&positions,&indices,{0,0.03,-0.12},{0.18,0.03,0.04})
    box(&positions,&indices,{0,1.12,0},{0.17,0.27,0.11})
    box(&positions,&indices,{0,1.44,0},{0.05,0.05,0.05})
    box(&positions,&indices,{0,1.62,0},{0.1,0.13,0.11})
    if skirt {box(&positions,&indices,{0,0.68,0},{0.2,0.2,0.12})}
    for side in ([2]f32{1,-1}) {
        turn:=mm.quat_axis_angle({0,0,1},-side*down)
        for k in 0..<6 {box(&positions,&indices,{side*0.17,1.35,0}+mm.quat_rotate(turn,{side*(0.06+0.12*f32(k)),0,0}),{0.06,0.045,0.045},turn)}
    }
    return {positions=positions[:],indices=indices[:]}
}

@(test)
the_fit_finds_the_parts_of_a_person_in_any_arm_pose_and_says_what_it_assumed :: proc(t:^testing.T) {
    Case :: struct {down:f32,skirt:bool,arm_plane:bool,crotch:f32}
    cases:=[?]Case{{0,false,false,0},{math.PI/4,false,true,0},{0,true,false,0},{0,true,false,0.86}}
    for c in cases {
        mesh:=boxes(c.down,c.skirt)
        meshes:=[1]Mesh{mesh}
        made,error:=humanoid(meshes[:],{crotch=c.crotch},context.temp_allocator)
        if !testing.expect_value(t,error,Error.None) {continue}
        f:=made.fit
        testing.expectf(t,f.confidence[.Arm_L]==1 && f.confidence[.Arm_R]==1,"%v: both arms stand out",c)
        testing.expectf(t,(f.arms_down>ARM_PLANE_ANGLE)==c.arm_plane,"%v: arms hang %.2f rad",c,f.arms_down)
        switch {
        case c.crotch>0:
            testing.expectf(t,f.crotch==c.crotch && f.confidence[.Crotch]==1 && len(made.warnings)==0,"%v: the crotch given is the crotch",c)
        case c.skirt:
            testing.expectf(t,f.confidence[.Crotch]<1 && len(made.warnings)>0,"%v: a skirt hides the crotch and the fit says so",c)
        case:
            testing.expectf(t,f.confidence[.Crotch]==1 && abs(f.crotch-0.86)<0.04,"%v: the crotch is where the legs part: %.3f",c,f.crotch)
        }
        hand:=f.joints[bone_index("hand_l")]
        tip:=mm.Vec3{-0.17,1.35,0}+mm.quat_rotate(mm.quat_axis_angle({0,0,1},c.down),{-0.72,0,0})
        testing.expectf(t,linalg.length(hand-tip)<0.3 && hand.x< -0.4,"%v: the left hand is toward the end of the left arm: %v",c,hand)
        foot:=f.joints[bone_index("foot_r")]
        testing.expectf(t,foot.x>0 && foot.y<0.2,"%v: the right foot is low on the right: %v",c,foot)
        testing.expect_value(t,len(made.skins),1)
        for skin in made.skins[0] {
            sum:=0
            for w in skin.weights {sum+=int(w)}
            testing.expect_value(t,sum,255)
        }
    }
}

@(test)
meshes_that_are_no_person_are_refused_or_rigged_with_warnings_without_crashing :: proc(t:^testing.T) {
    Case :: struct {name:string,positions:[][3]f32,indices:[]u32,empty:bool}
    flat:=[?][3]f32{{0,0,0},{1,0,0},{0,0,1},{1,0,1}}
    point:=[?][3]f32{{2,3,4},{2,3,4},{2,3,4}}
    far:=[?][3]f32{{1e6,0,1e6},{1e6+1,0,1e6},{1e6,2,1e6}}
    quad:=[?]u32{0,1,2,1,3,2}
    triangle:=[?]u32{0,1,2}
    blob:=make([dynamic][3]f32,context.temp_allocator)
    faces:=make([dynamic]u32,context.temp_allocator)
    // A sphere 1.8 m tall: no legs part, no arm stands out.
    for i in 0..=12 {
        for j in 0..<16 {
            a,b:=f32(i)/12*math.PI,f32(j)/16*2*math.PI
            append(&blob,[3]f32{0.4*math.sin(a)*math.cos(b),0.9-0.9*math.cos(a),0.4*math.sin(a)*math.sin(b)})
        }
    }
    for i in 0..<12 {
        for j in 0..<16 {
            k:=u32(i*16+j);n:=u32(i*16+(j+1)%16)
            append(&faces,k,n,k+16,n,n+16,k+16)
        }
    }
    cases:=[?]Case{
        {"flat",flat[:],quad[:],true},
        {"a point",point[:],triangle[:],true},
        {"no triangles",flat[:],nil,true},
        {"far away",far[:],triangle[:],false},
        {"a sphere",blob[:],faces[:],false},
    }
    for c in cases {
        meshes:=[1]Mesh{{positions=c.positions,indices=c.indices}}
        made,error:=humanoid(meshes[:],{},context.temp_allocator)
        if c.empty {
            testing.expectf(t,error==.Empty,"%s: refused as Empty, got %v",c.name,error)
            continue
        }
        if !testing.expectf(t,error==.None,"%s: rigged, got %v",c.name,error) {continue}
        testing.expectf(t,len(made.warnings)>0,"%s: says what it assumed",c.name)
        for joint in made.fit.joints {
            testing.expectf(t,joint.x-joint.x==0 && joint.y-joint.y==0 && joint.z-joint.z==0,"%s: joints are finite: %v",c.name,joint)
        }
        for skin in made.skins[0] {
            sum:=0
            for w in skin.weights {sum+=int(w)}
            testing.expect_value(t,sum,255)
        }
    }
}
