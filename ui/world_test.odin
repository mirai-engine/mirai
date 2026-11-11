package ui

import "core:math"
import "core:math/linalg"
import "core:testing"

test_world_point :: proc(placement:World_Placement,x,y:f32) -> [3]f32 {
    p:=placement.transform*[4]f32{x,y,0,1}
    return p.xyz
}
test_vec_near :: proc(a,b:[3]f32,tolerance:f32=0.0001) -> bool {
    return test_near(a.x,b.x,tolerance)&&test_near(a.y,b.y,tolerance)&&test_near(a.z,b.z,tolerance)
}

Test_World :: struct {
    panel:World_Panel,
    second:World_Panel,
    two:bool,
    clicks:[2]int,
    value:f64,
    result:Number_Result,
    scroll:[2]f32,
    screen_button:bool,
    screen_clicks:int,
    opened:[2]bool,
    reached:Id,
}
test_world_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_World)user
    s.reached=world_panel_reached(ctx)
    if s.opened[0]=world_panel_begin(ctx,id(ctx,"panel"),s.panel);s.opened[0] {
        if button(ctx,id(ctx,"use"),{label="Use",variant="accent",width=80,height=30}).clicked {s.clicks[0]+=1}
        s.result=number_field(ctx,id(ctx,"amount"),&s.value,{width=fixed(80),speed=1})
        if scroll_area(ctx,id(ctx,"list"),&s.scroll,{width=fixed(80),height=fixed(20)}) {
            for i in 0..<4 {
                box_begin(ctx,{id=id(ctx,"line",i+1),width=GROW,height=fixed(16),fill={255,255,255,255}});box_end(ctx,{id=id(ctx,"line",i+1)})
            }
        }
        world_panel_end(ctx)
    }
    if s.two {
        if world_panel(ctx,id(ctx,"second"),s.second) {
            if button(ctx,id(ctx,"other"),{label="Other",variant="accent",width=-1,height=100}).clicked {s.clicks[1]+=1}
        }
    }
    if s.screen_button {
        if panel(ctx,id(ctx,"screen"),{width=fixed(800),height=fixed(600)}) {
            if button(ctx,id(ctx,"over"),{label="Over",width=-1,height=600}).clicked {s.screen_clicks+=1}
        }
    }
}
// A panel of 200 by 100 units, 2 m by 1 m, centered 2 m up with its face toward +Z,
// seen by a camera at (0, 2, 5) that looks down -Z.
test_world_default :: proc() -> (Test_World,Input) {
    s:=Test_World{panel={position={0,2,0},size={200,100},unit=0.01,pivot=.Center,direction=.Column,padding=padding_all(10),gap=4,fill={10,10,10,255}}}
    input:=test_input(1000,1000)
    input.pointer_absent=true
    input.view={position={0,2,5},fov_y=math.PI/2,viewport_height=1000}
    return s,input
}

@(test)
a_world_panel_is_placed_by_its_position_rotation_and_pivot :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,len(frame.placements),1)
    p:=frame.placements[0]
    testing.expect(t,p.id==id(&ctx,"panel") && p.size==[2]f32{200,100} && p.visible && !p.depth_test)
    testing.expect(t,test_vec_near(test_world_point(p,0,0),{-1,2.5,0}))
    testing.expect(t,test_vec_near(test_world_point(p,200,100),{1,1.5,0}))
    testing.expect(t,test_vec_near(test_world_point(p,100,50),{0,2,0}))
    out:=p.transform*[4]f32{0,0,1,0}
    testing.expect(t,test_vec_near(out.xyz,{0,0,0.01}),"Its face looks along +Z")
    // The pivot chooses the point that sits at the position.
    s.panel.pivot=.Top_Left
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,test_vec_near(test_world_point(frame.placements[0],0,0),{0,2,0}))
    s.panel.pivot=.Bottom_Center
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,test_vec_near(test_world_point(frame.placements[0],100,100),{0,2,0}))
    testing.expect(t,test_vec_near(test_world_point(frame.placements[0],0,0),{-1,3,0}))
    // Turned a quarter around Y, its right is -Z and its front +X.
    s.panel.pivot=.Center
    s.panel.rotation=linalg.quaternion_angle_axis_f32(math.PI/2,{0,1,0})
    s.panel.depth_test=true
    frame=test_frame(&ctx,&input,test_world_build,&s)
    p=frame.placements[0]
    testing.expect(t,p.depth_test)
    testing.expect(t,test_vec_near(test_world_point(p,0,0),{0,2.5,1}))
    testing.expect(t,test_vec_near(test_world_point(p,200,100),{0,1.5,-1}))
    out=p.transform*[4]f32{0,0,1,0}
    testing.expect(t,test_vec_near(out.xyz,{0.01,0,0}))
}

@(test)
billboards_face_the_camera :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    // A camera at +X that looks back at the origin, tilted down.
    yaw:=linalg.quaternion_angle_axis_f32(math.PI/2,{0,1,0})
    pitch:=linalg.quaternion_angle_axis_f32(-math.PI/6,{1,0,0})
    input.view={position={8,6,0},rotation=yaw*pitch,fov_y=math.PI/2,viewport_height=1000}
    s.panel.facing=.Billboard
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    p:=frame.placements[0]
    right:=test_world_point(p,200,50)-test_world_point(p,0,50)
    down:=test_world_point(p,100,100)-test_world_point(p,100,0)
    camera_right:=linalg.quaternion_mul_vector3(input.view.rotation,[3]f32{1,0,0})
    camera_up:=linalg.quaternion_mul_vector3(input.view.rotation,[3]f32{0,1,0})
    testing.expect(t,test_vec_near(right,camera_right*2) && test_vec_near(down,camera_up*-1),"It lies in the plane of the screen")
    testing.expect(t,test_vec_near(test_world_point(p,100,50),{0,2,0}))
    // Upright: it turns to the camera around the world's up and stays vertical.
    s.panel.facing=.Billboard_Upright
    frame=test_frame(&ctx,&input,test_world_build,&s)
    p=frame.placements[0]
    down=test_world_point(p,100,100)-test_world_point(p,100,0)
    out:=p.transform*[4]f32{0,0,1,0}
    testing.expect(t,test_vec_near(down,{0,-1,0}) && test_vec_near(out.xyz,{0.01,0,0}))
}

@(test)
a_screen_sized_panel_keeps_its_size_on_screen_at_any_distance :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.panel.sizing=.Screen;s.panel.unit=1;s.panel.facing=.Billboard
    // With a field of view of 90 degrees a 1000 point screen spans twice the distance.
    s.panel.position={0,2,-5}
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    width:=test_world_point(frame.placements[0],200,0)-test_world_point(frame.placements[0],0,0)
    testing.expect(t,test_vec_near(width,{200*0.02,0,0}))
    s.panel.position={0,2,-15}
    frame=test_frame(&ctx,&input,test_world_build,&s)
    width=test_world_point(frame.placements[0],200,0)-test_world_point(frame.placements[0],0,0)
    testing.expect(t,test_vec_near(width,{200*0.04,0,0}),"Twice as far, twice as large in the world")
    s.panel.unit=0.5
    frame=test_frame(&ctx,&input,test_world_build,&s)
    width=test_world_point(frame.placements[0],200,0)-test_world_point(frame.placements[0],0,0)
    testing.expect(t,test_vec_near(width,{200*0.02,0,0}))
    // Behind the camera there is nothing to show.
    s.panel.position={0,2,9}
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,!frame.placements[0].visible)
}

@(test)
a_world_panel_draws_into_commands_of_its_own_surface :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.screen_button=true
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,len(frame.commands),2)
    world,screen:=frame.commands[0],frame.commands[1]
    testing.expect(t,world.surface==1 && screen.surface==0)
    testing.expect_value(t,world.scissor,Rect{0,0,200,100})
    testing.expect_value(t,screen.scissor,Rect{0,0,1000,1000})
    testing.expect(t,world.count>0 && world.first+world.count==screen.first && screen.first+screen.count==u32(len(frame.vertices)))
    vertices:=frame.vertices[world.first:][:world.count]
    testing.expect(t,test_rect_near(test_bounds(vertices),{0,0,200,100}),"Its vertices are in its own units, from its top-left corner")
    for v in vertices {testing.expect_value(t,v.position.z,f32(0))}
    // Its widgets are laid out inside it.
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"use")),{10,10,80,30}))
    row:=metric(&ctx,"row")
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"amount")),{10,44,80,row}))
    list:=test_rect(t,&ctx,id(&ctx,"list"))
    testing.expect(t,test_rect_near(list,{10,44+row+4,80,20}))
    // What a clip of the panel hides is cut from the geometry: no scissor crosses the 3D world.
    white:=0
    for v in vertices {
        if quad_kind(v.quad)==.Shape && frame.shapes[quad_data(v.quad)].fill=={1,1,1,1} {
            white+=1
            testing.expect(t,v.position.y>=list.y-0.001 && v.position.y<=list.y+list.h+0.001)
        }
    }
    testing.expect_value(t,white,12)
    // Scrolled: the end of the second line, the third whole and the start of the fourth.
    s.scroll.y=30
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,len(frame.commands),2)
    white=0
    for v in frame.vertices[frame.commands[0].first:][:frame.commands[0].count] {
        if quad_kind(v.quad)==.Shape && frame.shapes[quad_data(v.quad)].fill=={1,1,1,1} {
            white+=1
            testing.expect(t,v.position.y>=list.y-0.001 && v.position.y<=list.y+list.h+0.001)
        }
    }
    testing.expect_value(t,white,18)
    // Nothing leaves the rectangle of the panel, whatever it holds.
    s.panel.size={200,60}
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,test_rect_near(test_bounds(frame.vertices[frame.commands[0].first:][:frame.commands[0].count]),{0,0,200,60}))
    testing.expect_value(t,frame.commands[0].scissor,Rect{0,0,200,60})
}

@(test)
a_ray_points_at_the_widgets_of_a_world_panel :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    test_frame(&ctx,&input,test_world_build,&s)
    // The button spans x -0.9 to -0.1 and y 2.4 to 2.1 in the world.
    aim :: proc(input:^Input,x,y:f32) {input.ray={origin={x,y,5},direction={0,0,-1},valid=true}}
    aim(&input,-0.5,2.25)
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"use"))
    testing.expect(t,frame.pointer_consumed)
    point,distance,inside:=world_panel_point(&ctx,id(&ctx,"panel"),input.ray)
    testing.expect(t,inside && test_near(point.x,50) && test_near(point.y,25) && test_near(distance,5))
    test_press(&input)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,s.clicks[0],1)
    test_release(&input)
    test_frame(&ctx,&input,test_world_build,&s)
    // Beside the button the panel itself takes the ray; beside the panel, nothing.
    aim(&input,0.8,2.25)
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,ctx.hot==id(&ctx,"panel") && frame.pointer_consumed)
    aim(&input,1.5,2.25)
    frame=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,ctx.hot==0 && !frame.pointer_consumed)
    // From behind, and away from it, the panel is not reached.
    input.ray={origin={-0.5,2.25,-5},direction={0,0,1},valid=true}
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,Id(0))
    input.ray={origin={-0.5,2.25,5},direction={0,0,1},valid=true}
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,Id(0))
    // At an angle the ray lands where it crosses the plane.
    input.ray={origin={-5.5,2.25,5},direction=linalg.normalize([3]f32{1,0,-1}),valid=true}
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"use"))
    // A passive panel lets the ray through.
    s.panel.passive=true
    aim(&input,-0.5,2.25)
    test_frame(&ctx,&input,test_world_build,&s)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,Id(0))
}

@(test)
the_scene_in_front_of_a_panel_hides_it_from_the_ray :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.panel.depth_test=true
    test_frame(&ctx,&input,test_world_build,&s)
    // A wall 3 m along the ray, in front of the panel 5 m away.
    wall:=f32(3)
    hides:=proc(user:rawptr,point:[3]f32,share,metres:f32) -> bool {return 5-point.z>(cast(^f32)user)^*share+metres}
    input.ray={origin={-0.5,2.25,5},direction={0,0,-1},valid=true,scene={hides,&wall}}
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,ctx.hot==0 && s.reached==0)
    // What the scene shows there is the panel itself.
    wall=5
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,ctx.hot==id(&ctx,"use") && s.reached==id(&ctx,"panel"))
    // Drawn over the scene, it is reached through the wall.
    s.panel.depth_test=false
    wall=3
    test_frame(&ctx,&input,test_world_build,&s)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"use"))
}

@(test)
a_panel_drawn_on_a_surface_takes_the_ray_where_the_host_aims :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.panel.offscreen=true
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,!frame.placements[0].visible && frame.placements[0].offscreen)
    // A ray that misses its plane meets the surface where the host says.
    input.ray={origin={5,5,5},direction={0,0,-1},valid=true}
    world_panel_aim(&ctx,id(&ctx,"panel"),{50,25},4,true)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"use"))
    // Told the ray misses the surface, it is not reached, even through its plane.
    input.ray={origin={-0.5,2.25,5},direction={0,0,-1},valid=true}
    world_panel_aim(&ctx,id(&ctx,"panel"),{},0,false)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,Id(0))
    // Without an aim, its plane.
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"use"))
}

@(test)
dragging_with_the_ray_scrubs_a_number_of_a_world_panel :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.value=10
    test_frame(&ctx,&input,test_world_build,&s)
    // The field spans 10 to 90 units, -0.9 to -0.1 m, at y 2.06 to 1.8.
    input.ray={origin={-0.5,1.9,5},direction={0,0,-1},valid=true}
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"amount"))
    test_press(&input)
    test_frame(&ctx,&input,test_world_build,&s)
    input.ray.origin.x=-0.3
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,s.result.scrubbing && test_near(f32(s.value),30,0.01),"20 units of the panel, one per unit")
    // The ray may leave the panel: its plane still gives the pointer a place.
    input.ray.origin.x=2
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,test_near(f32(s.value),260,0.01))
    test_release(&input)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,s.result.ended && ctx.active==0)
}

@(test)
the_nearest_panel_and_the_screen_come_first :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.two=true
    s.second={position={0,2,2},size={100,100},unit=0.01,pivot=.Center}
    test_frame(&ctx,&input,test_world_build,&s)
    input.ray={origin={-0.2,2.2,5},direction={0,0,-1},valid=true}
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,len(frame.placements),2)
    testing.expect_value(t,ctx.hot,id(&ctx,"other"))
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,s.clicks,[2]int{0,1})
    // Outside the near panel the ray reaches the far one.
    input.ray.origin={-0.8,2.25,5}
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"use"))
    // A widget of the screen under the pointer hides the world.
    s.screen_button=true
    input.pointer_absent=false;input.pointer={500,300}
    test_frame(&ctx,&input,test_world_build,&s)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"over"))
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,s.screen_clicks==1 && s.clicks==[2]int{0,1})
}

@(test)
world_panels_beyond_the_capacity_are_refused_and_counted :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_panels=1
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    s,input:=test_world_default()
    s.two=true
    s.second={position={0,2,2},size={100,100},unit=0.01}
    frame:=test_frame(&ctx,&input,test_world_build,&s)
    testing.expect(t,frame.overflow && s.opened[0])
    testing.expect_value(t,len(frame.placements),1)
    testing.expect_value(t,ctx.stats.dropped_panels,u32(1))
    testing.expect_value(t,ctx.stats.panels,u32(1))
    _,found:=widget_rect(&ctx,id(&ctx,"other"))
    testing.expect(t,!found,"What the refused panel held is not built")
}

@(test)
a_popup_opened_in_a_world_panel_belongs_to_its_surface :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    State :: struct {selected:int}
    s:State
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^State)user
        if world_panel(ctx,id(ctx,"panel"),{position={0,2,0},size={200,160},unit=0.01,pivot=.Center,padding=padding_all(10)}) {
            dropdown(ctx,id(ctx,"kind"),{list={"Point","Spot","Sun"}},&s.selected,{width=96})
        }
    }
    input:=test_input(1000,1000)
    input.pointer_absent=true
    input.view={position={0,2,5},fov_y=math.PI/2,viewport_height=1000}
    test_frame(&ctx,&input,build,&s)
    // The button spans 10 to 106 units by 10 to 32: around x -0.5, y 2.6 in the world.
    input.ray={origin={-0.5,2.6,5},direction={0,0,-1},valid=true}
    test_frame(&ctx,&input,build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,build,&s)
    frame:=test_frame(&ctx,&input,build,&s)
    list:=id_derive(&ctx,id(&ctx,"kind"),"list")
    testing.expect(t,popup_is_open(&ctx,list))
    // Under its button and inside the margin of the panel, three rows tall inside 4 of padding.
    testing.expect(t,test_rect_near(test_rect(t,&ctx,list),{metric(&ctx,"margin"),10+metric(&ctx,"row")+4,180,3*metric(&ctx,"row")+8}),"It hangs under its button, inside the panel")
    for command in frame.commands {testing.expect_value(t,command.surface,u32(1))}
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    // The third row, through the ray.
    input.ray.origin={-0.5,2.8-(10+metric(&ctx,"row")+8+2.5*metric(&ctx,"row"))/100,5}
    test_frame(&ctx,&input,build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.selected==2 && !popup_is_open(&ctx,list))
}
