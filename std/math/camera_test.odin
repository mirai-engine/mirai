package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file") DEG :: f32(RAD_PER_DEG)

@(test)
projection_matches_picking :: proc(t:^testing.T) {
    viewport:=Vec2{800,600}
    view:=look_at({0,0,10},{},{0,1,0})
    projection:=perspective(50*DEG,viewport.x/viewport.y,0.05,500)
    projected,_,ok:=world_to_screen({},viewport,projection*view)
    testing.expect(t,ok)
    testing.expect(t,linalg.length(projected-Vec2{400,300})<1e-3)
    ray:=screen_ray(projected,viewport,view,projection)
    testing.expect(t,test_close3(ray.origin,{0,0,10}),"A perspective ray starts at the eye")
    distance,_,hit:=ray_aabb(ray,{{-0.5,-0.5,-0.5},{0.5,0.5,0.5}})
    testing.expect(t,hit && distance>9.49 && distance<9.51)
    behind,_,front:=world_to_screen({0,0,20},viewport,projection*view)
    testing.expect(t,!front,"Points behind the camera are reported")
    testing.expect(t,behind.x<-1000 && behind.y<-1000)
}

@(test)
perspective_is_reversed_with_y_up :: proc(t:^testing.T) {
    fov,aspect,near,far:=f32(60*DEG),f32(16.0/9.0),f32(0.05),f32(500)
    p:=perspective(fov,aspect,near,far)
    f:=1/math.tan(fov*0.5)
    expected:Mat4
    expected[0,0]=f/aspect;expected[1,1]=f;expected[2,2]=near/(far-near);expected[2,3]=far*near/(far-near);expected[3,2]=-1
    testing.expect(t,test_close_mat4(p,expected,1e-6))
    depth :: proc(p:Mat4,z:f32) -> f32 {clip:=p*Vec4{0,0,z,1};return clip.z/clip.w}
    testing.expect(t,test_close(depth(p,-near),1,1e-5),"The near plane is at depth 1")
    testing.expect(t,test_close(depth(p,-far),0,1e-5),"The far plane is at depth 0")
    testing.expect(t,depth(p,-1)>depth(p,-2),"Depth decreases with distance")
    above:=p*Vec4{0,1,-5,1}
    testing.expect(t,above.y/above.w>0,"Y is up in clip space")
    right:=p*Vec4{1,0,-5,1}
    testing.expect(t,right.x/right.w>0)
    // The edge of the field of view lands on the edge of clip space.
    edge:=p*Vec4{0,math.tan(fov*0.5)*5,-5,1}
    testing.expect(t,test_close(edge.y/edge.w,1,1e-5))
    infinite:=perspective_infinite(fov,aspect,near)
    testing.expect(t,test_close(depth(infinite,-near),1,1e-5))
    testing.expect(t,depth(infinite,-1e6)>0 && depth(infinite,-1e6)<1e-6)
    testing.expect_value(t,infinite[0,0],p[0,0])
}

@(test)
look_at_builds_the_view_of_the_previous_engine :: proc(t:^testing.T) {
    eye,target,up:=Vec3{3,4,5},Vec3{0,1,-2},Vec3{0,1,0}
    forward:=linalg.normalize(target-eye)
    right:=linalg.normalize(linalg.cross(forward,up))
    camera_up:=linalg.cross(right,forward)
    expected:Mat4=1
    for i in 0..<3 {expected[0,i]=right[i];expected[1,i]=camera_up[i];expected[2,i]=-forward[i]}
    expected[0,3]=-linalg.dot(right,eye);expected[1,3]=-linalg.dot(camera_up,eye);expected[2,3]=linalg.dot(forward,eye)
    view:=look_at(eye,target,up)
    testing.expect(t,test_close_mat4(view,expected,1e-5))
    testing.expect(t,test_close3(mat4_point(view,eye),{}))
    testing.expect(t,test_close3(mat4_point(view,target),{0,0,-linalg.length(target-eye)}),"The target is straight ahead, down -Z")
    testing.expect(t,test_close_mat4(view_matrix(eye,quat_look(target-eye,up)),view,1e-4))
    // Degenerate cameras still give finite matrices.
    for m in ([3]Mat4{look_at(eye,eye,up),look_at(eye,eye+{0,-3,0},up),look_at(eye,target,{})}) {
        for row in 0..<4 {for column in 0..<4 {testing.expect(t,!math.is_nan(m[row,column]) && !math.is_inf(m[row,column]))}}
    }
    testing.expect(t,test_close_mat4(look_at({},{},{}),MAT4_IDENTITY))
}

@(test)
orthographic_maps_its_box_to_clip_space :: proc(t:^testing.T) {
    p:=orthographic(8,6,1,101)
    near_corner:=p*Vec4{4,3,-1,1}
    far_corner:=p*Vec4{-4,-3,-101,1}
    testing.expect(t,test_close3(near_corner.xyz,{1,1,1},1e-5) && near_corner.w==1)
    testing.expect(t,test_close3(far_corner.xyz,{-1,-1,0},1e-5))
    off:=orthographic_off_center(0,10,0,5,0,1)
    testing.expect(t,test_close3((off*Vec4{0,0,0,1}).xyz,{-1,-1,1},1e-5))
    testing.expect(t,test_close3((off*Vec4{10,5,-1,1}).xyz,{1,1,0},1e-5))
}

@(test)
screen_rays_round_trip_through_world_to_screen :: proc(t:^testing.T) {
    viewport:=Vec2{1280,720}
    view:=look_at({4,3,9},{1,0,-2},{0,1,0})
    for projection in ([3]Mat4{perspective(50*DEG,viewport.x/viewport.y,0.1,200),orthographic(16,9,0.1,200),orthographic_off_center(-2,10,-1,3,0.5,50)}) {
        for pixel in ([4]Vec2{{640,360},{0,0},{1279,719},{200,650}}) {
            ray:=screen_ray(pixel,viewport,view,projection)
            testing.expect(t,test_close(linalg.length(ray.direction),1,1e-5))
            for distance in ([2]f32{1,37.5}) {
                back,depth,ok:=world_to_screen(ray_at(ray,distance),viewport,projection*view)
                testing.expect(t,ok && depth>0 && depth<=1.0001)
                testing.expectf(t,linalg.length(back-pixel)<0.05,"pixel %v came back as %v",pixel,back)
            }
        }
    }
    // An orthographic ray starts on the near plane and runs along the view.
    orthographic_ray:=screen_ray({640,360},viewport,view,orthographic(16,9,0.1,200))
    forward:=linalg.normalize(Vec3{1,0,-2}-Vec3{4,3,9})
    testing.expect(t,test_close3(orthographic_ray.direction,forward,1e-5))
    testing.expect(t,test_close3(orthographic_ray.origin,Vec3{4,3,9}+forward*0.1,1e-4))
    // The top left pixel is up and to the left of the view axis.
    centered:=look_at({0,0,0},{0,0,-1},{0,1,0})
    corner:=screen_ray({0,0},viewport,centered,perspective(90*DEG,1,0.1,10))
    testing.expect(t,corner.direction.x<0 && corner.direction.y>0 && corner.direction.z<0)
    testing.expect(t,test_close(perspective_world_per_pixel(10,50*DEG,600),2*math.tan(f32(25*DEG))*10/600))
}

@(test)
frustum_planes_bound_the_view_volume :: proc(t:^testing.T) {
    view:=look_at({0,0,0},{0,0,-1},{0,1,0})
    projection:=perspective(90*DEG,1,1,100)
    frustum:=frustum_from_matrix(projection*view)
    for plane in frustum.planes {testing.expect(t,test_close(linalg.length(plane.normal),1,1e-5))}
    inside :: proc(frustum:Frustum,point:Vec3) -> bool {
        for plane in frustum.planes {if plane_distance(plane,point)<0 {return false}}
        return true
    }
    testing.expect(t,inside(frustum,{0,0,-50}))
    testing.expect(t,!inside(frustum,{0,0,-0.5}),"Closer than the near plane")
    testing.expect(t,!inside(frustum,{0,0,-150}),"Beyond the far plane")
    testing.expect(t,!inside(frustum,{0,0,10}),"Behind the camera")
    testing.expect(t,inside(frustum,{-49,0,-50}) && !inside(frustum,{-51,0,-50}))
    testing.expect(t,inside(frustum,{49,0,-50}) && !inside(frustum,{51,0,-50}))
    testing.expect(t,inside(frustum,{0,49,-50}) && !inside(frustum,{0,51,-50}))
    testing.expect(t,inside(frustum,{0,-49,-50}) && !inside(frustum,{0,-51,-50}))
    // With reversed depth the plane of depth 0 is the far one.
    testing.expect(t,test_close(plane_distance(frustum.planes[.Far],{0,0,-100}),0,1e-3))
    testing.expect(t,test_close(plane_distance(frustum.planes[.Near],{0,0,-1}),0,1e-3))
    testing.expect(t,test_close(plane_distance(frustum.planes[.Left],{-50,0,-50}),0,1e-3))
    testing.expect(t,test_close(plane_distance(frustum.planes[.Top],{0,50,-50}),0,1e-3))
    box:=orthographic(4,2,0,10)
    ortho:=frustum_from_matrix(box)
    testing.expect(t,inside(ortho,{1.9,0.9,-5}) && !inside(ortho,{2.1,0,-5}) && !inside(ortho,{0,1.1,-5}) && !inside(ortho,{0,0,-11}) && !inside(ortho,{0,0,1}))
}
