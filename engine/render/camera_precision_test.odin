package render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import gpu "mirai:render"
import mm "mirai:std/math"

// What a child of a camera 0.4 m in front of it shows of f32, 16 km from the
// centre of the world, as the camera walks and turns at 60 frames a second:
// how far the place it is drawn at, relative to the eye, is from where it
// is, in pixels of a view 1440 pixels high with a vertical field of 70
// degrees. Composed in the world as World_Transform is (mm.transform_compose
// in f32) the step of f32 at 16 km lands on it and changes from frame to
// frame; composed from the camera (camera_carried), it keeps the precision of
// the distance to the origin of the render. Both go through what the
// renderer and its vertex shader do: the place relative to the origin in f64,
// the vertex in f32, and the eye taken away (view_clip).
@(test)
a_child_of_the_camera_far_from_the_centre_stays_still_when_drawn_from_the_camera :: proc(t:^testing.T) {
    PIXELS :: 1440
    FOV :: 70*math.PI/180
    start:=[3]f32{16350.37,31.5,-16340.81}
    origin:=[3]f32{15360,0,-15360} // a multiple of ORIGIN_STEP the eye has not left the reach of
    local:=mm.Transform{position={0.15,-0.2,-0.4},rotation=mm.quat_axis_angle({0,1,0},0.1),scale=1}
    vertex:=[3]f32{0.03,0.02,-0.12} // of the mesh of the child
    // The pixels a gap of the place relative to the eye covers at the depth of the child.
    pixels :: proc(gap:[3]f64,depth:f64) -> f64 {return linalg.length(gap)/(2*depth*math.tan(f64(FOV)/2)/PIXELS)}
    // As the GPU places a vertex: the rows of the instance in f32, and the eye taken away.
    drawn :: proc(m:mm.Mat4,vertex,eye:[3]f32) -> [3]f32 {
        world:[3]f32
        for row in 0..<3 {world[row]=m[row,0]*vertex.x+m[row,1]*vertex.y+m[row,2]*vertex.z+m[row,3]}
        return world-eye
    }
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    camera_entity,child:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.cameras,camera_entity,Camera{})
    core.add(&w.locals,camera_entity,core.TRANSFORM_IDENTITY)
    core.add(&w.locals,child,core.from_math(local))
    core.add(&w.parents,child,core.Parent{entity=camera_entity})
    test_world_settle(&w)
    worst_world,worst_carried:f64
    for frame in 0..<600 {
        time:=f32(frame)/60
        camera:=mm.Transform{
            position=start+[3]f32{1.4*time,0.04*math.sin(time*9),-0.9*time},
            rotation=mm.quat_axis_angle({0,1,0},0.3*time)*mm.quat_axis_angle({1,0,0},0.1*math.sin(time*1.3)),
            scale=1,
        }
        // Where it is: the camera as f32 holds it, and the child from there in f64.
        exact:=rotate64(camera.rotation,linalg.array_cast(local.position,f64)+rotate64(local.rotation,linalg.array_cast(vertex,f64)))
        depth:=-rotate64(conj(camera.rotation),exact).z
        eye:=gpu.origin_point(camera.position,origin)
        // Composed in the world.
        world:=mm.transform_compose(camera,local)
        seen:=drawn(gpu.origin_matrix(mm.transform_matrix(world),origin),vertex,eye)
        worst_world=max(worst_world,pixels(linalg.array_cast(seen,f64)-exact,depth))
        // Composed from the camera, as render_sync does it.
        core.add(&w.worlds,camera_entity,core.World_Transform{camera,camera})
        test_world_settle(&w)
        anchor,carried,ok:=camera_carried(core.FRAME_TIME_DEFAULT,core.read(&w.offsets),core.read(&w.parents),core.read(&w.worlds),core.read(&w.locals),core.read(&w.cameras),child)
        if !testing.expect(t,ok && anchor==camera.position) {return}
        seen=drawn(gpu.origin_matrix(mm.transform_matrix(carried),origin-anchor),vertex,eye)
        worst_carried=max(worst_carried,pixels(linalg.array_cast(seen,f64)-exact,depth))
    }
    fmt.printfln("a child of the camera 0.4 m ahead, 16 km out, 1440 px at 70 deg: composed in the world %.2f px, from the camera %.3f px",worst_world,worst_carried)
    testing.expectf(t,worst_world>0.5,"composed in the world it shakes by more than half a pixel: %v",worst_world)
    testing.expectf(t,worst_carried<0.5,"composed from the camera it stays within half a pixel: %v",worst_carried)
}

// A rotation of f32 turning a vector in f64.
@(private="file")
rotate64 :: proc "contextless" (q:mm.Quat,v:[3]f64) -> [3]f64 {
    u:=[3]f64{f64(imag(q)),f64(jmag(q)),f64(kmag(q))}
    w:=f64(real(q))
    return v+2*w*linalg.cross(u,v)+2*linalg.cross(u,linalg.cross(u,v))
}

@(test)
camera_carried_uses_live_camera_transform :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    cam_ent,child:=core.create(&w.entities),core.create(&w.entities)
    prev:=mm.Transform{position={0,1.6,0},rotation=1,scale={1,1,1}}
    live:=mm.Transform{position={0.08,1.6,0},rotation=mm.quat_axis_angle({0,1,0},0.15),scale={1,1,1}}
    core.add(&w.cameras,cam_ent,Camera{})
    core.add(&w.worlds,cam_ent,core.World_Transform{transform=live,previous=prev})
    core.add(&w.locals,cam_ent,core.from_math(live))
    core.add(&w.parents,child,core.Parent{entity=cam_ent})
    core.add(&w.locals,child,core.Transform{position={0,0,-0.4},rotation=1,scale={1,1,1}})
    test_world_settle(&w)
    anchor,carried,ok:=camera_carried({alpha=0.5},core.read(&w.offsets),core.read(&w.parents),core.read(&w.worlds),core.read(&w.locals),core.read(&w.cameras),child)
    testing.expect(t,ok)
    testing.expect_value(t,anchor,live.position)
    expected:=mm.transform_compose({rotation=live.rotation,scale={1,1,1}},{position={0,0,-0.4},rotation=1,scale={1,1,1}})
    testing.expect(t,linalg.length(carried.position-expected.position)<1e-5)
}

// A Camera.fov the schema refuses (degrees given as radians, from pi, below 0,
// NaN) is drawn at the default 60° rather than as a view that shows nothing;
// one inside the range is drawn as it is and 0 is the default.
@(test)
a_camera_draws_only_a_field_of_view_inside_its_range :: proc(t:^testing.T) {
    cases:=[]struct{fov,drawn:f32}{
        {1.187,1.187},
        {CAMERA_FOV_MAX,CAMERA_FOV_MAX},
        {0,CAMERA_DEFAULT.fov},
        {68,CAMERA_DEFAULT.fov},
        {math.PI,CAMERA_DEFAULT.fov},
        {-0.5,CAMERA_DEFAULT.fov},
        {math.nan_f32(),CAMERA_DEFAULT.fov},
        {math.inf_f32(1),CAMERA_DEFAULT.fov},
    }
    for c in cases {
        pose:=camera_pose(Camera{fov=c.fov},mm.TRANSFORM_IDENTITY)
        testing.expectf(t,pose.fov==c.drawn,"%v: drawn at %v",c.fov,pose.fov)
        testing.expectf(t,camera_fov_valid(c.fov)==(c.fov==c.drawn || c.fov==0),"%v: valid is %v",c.fov,camera_fov_valid(c.fov))
    }
}

// A Viewmodel.fov the schema refuses is drawn at that of VIEWMODEL_DEFAULT,
// as a Camera draws one at its default, so the place of its muzzle in the
// world stays finite and on the ray of its pixel; 0 draws it as the world is.
@(test)
a_viewmodel_draws_only_a_field_of_view_inside_its_range :: proc(t:^testing.T) {
    view:=core.VIEW_DEFAULT
    view.fov=90*mm.RAD_PER_DEG
    muzzle:=[3]f32{0.1,-0.05,-0.5}
    cases:=[]struct{fov,drawn:f32}{
        {1,1},
        {CAMERA_FOV_MAX,CAMERA_FOV_MAX},
        {0,0},
        {55,VIEWMODEL_DEFAULT.fov},
        {3.1,VIEWMODEL_DEFAULT.fov},
        {-0.5,VIEWMODEL_DEFAULT.fov},
        {math.nan_f32(),VIEWMODEL_DEFAULT.fov},
        {math.inf_f32(1),VIEWMODEL_DEFAULT.fov},
    }
    for c in cases {
        testing.expectf(t,viewmodel_fov({fov=c.fov})==c.drawn,"%v: drawn at %v",c.fov,viewmodel_fov({fov=c.fov}))
        placed:=viewmodel_world_place(view,{fov=c.fov},muzzle)
        want:=viewmodel_world_place(view,{fov=c.drawn},muzzle)
        testing.expectf(t,placed==want && !math.is_nan(placed.x) && !math.is_inf(placed.x) && !math.is_nan(placed.y) && !math.is_inf(placed.y),"%v: its muzzle is placed at %v",c.fov,placed)
    }
}
