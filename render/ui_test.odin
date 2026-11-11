package mirai_render

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"

// A renderer without lighting effects that move from frame to frame: what is
// drawn over the image is read exactly.
@(private)
Overlay_Fixture :: struct {
    using base:Fixture,
    tracking:mem.Tracking_Allocator, // of everything the renderer allocates
    cube:    Mesh_Handle,
}

@(private)
overlay_fixture :: proc(t:^testing.T,f:^Overlay_Fixture,width,height:u32,taa:=false,ui_capacity:=0,debug_capacity:=0,ui_shape_capacity:=0,ui_layer_depth:=0,loc:=#caller_location) -> bool {
    mem.tracking_allocator_init(&f.tracking,context.allocator)
    settings:=DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,taa
    settings.trace_mode=.Software if SOFTWARE_TRACER else .Auto
    if !fixture_init(t,f,width,height,settings,hardware_rt=false,desc={allocator=mem.tracking_allocator(&f.tracking),ui_vertex_capacity=ui_capacity,debug_vertex_capacity=debug_capacity,ui_shape_capacity=ui_shape_capacity,ui_layer_depth=ui_layer_depth},loc=loc) {
        mem.tracking_allocator_destroy(&f.tracking)
        return false
    }
    vertices:[24]Mesh_Vertex
    indices:[36]u32
    normals:=[6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
    for n,face in normals {
        u:=Vec3{n.y,n.z,n.x}
        v:=Vec3{n.y*u.z-n.z*u.y,n.z*u.x-n.x*u.z,n.x*u.y-n.y*u.x}
        corners:=[4]Vec3{n-u-v,n+u-v,n+u+v,n-u+v}
        for c,i in corners {vertices[face*4+i]={position=c*0.5,normal=n,color={1,1,1}}}
        base:=u32(face*4)
        quad:=[6]u32{base,base+1,base+2,base,base+2,base+3}
        for q,i in quad {indices[face*6+i]=q}
    }
    added:bool
    f.cube,added=mesh_add(f.renderer,vertices[:],indices[:])
    testing.expect(t,added)
    return true
}

@(private)
overlay_fixture_destroy :: proc(t:^testing.T,f:^Overlay_Fixture) {
    testing.expectf(t,rhi.device_validation_errors(f.device)==0,"validation: %s",rhi.device_validation_message(f.device))
    fixture_destroy(f)
    testing.expect_value(t,len(f.tracking.allocation_map),0)
    mem.tracking_allocator_destroy(&f.tracking)
}

// Two triangles covering a rectangle of points.
@(private)
quad :: proc(x,y,w,h:f32,color:Vec4,material:u32=0) -> [6]Ui_Vertex {
    corners:=[4]Ui_Vertex{
        {position={x,y,0},color=color,material=material,uv={0,0}},{position={x+w,y,0},color=color,material=material,uv={1,0}},
        {position={x+w,y+h,0},color=color,material=material,uv={1,1}},{position={x,y+h,0},color=color,material=material,uv={0,1}},
    }
    return {corners[0],corners[1],corners[2],corners[0],corners[2],corners[3]}
}

@(private)
EMPTY_CAMERA :: Camera{position={0,0,5},forward={0,0,-5},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}

@(private)
captured :: proc(t:^testing.T,f:^Overlay_Fixture,frame:Frame_Desc,frames:=2) -> []u8 {
    for _ in 0..<frames {testing.expect(t,renderer_frame(f.renderer,frame),f.renderer.error)}
    rhi.device_wait_idle(f.device)
    pixels,_,_,ok:=renderer_capture(f.renderer)
    testing.expect(t,ok,f.renderer.error)
    return pixels
}

@(private)
at :: proc(pixels:[]u8,width,x,y:int) -> [4]u8 {
    i:=(y*width+x)*4
    return {pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]}
}

@(private)
near_color :: proc(a,b:[4]u8,tolerance:=2) -> bool {
    for i in 0..<3 {if abs(int(a[i])-int(b[i]))>tolerance {return false}}
    return true
}

@(test)
ui_layers_are_drawn_in_order_and_clipped_by_their_scissors :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,48) {return}
    defer overlay_fixture_destroy(t,&f)
    red,green,blue:=[4]u8{255,0,0,255},[4]u8{0,255,0,255},[4]u8{0,0,255,255}
    game:=quad(0,0,64,48,{1,0,0,1})
    // The editor layer: a green quad over everything, clipped to a rectangle,
    // and a blue one that is not clipped.
    editor:[12]Ui_Vertex
    covering,corner:=quad(0,0,64,48,{0,1,0,1}),quad(48,32,16,16,{0,0,1,1})
    copy(editor[:6],covering[:])
    copy(editor[6:],corner[:])
    draws:=[]Ui_Draw{{first=0,count=6,scissor={8,4,16,20}},{first=6,count=6}}
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=game[:]},{vertices=editor[:],draws=draws}}})
    defer delete(pixels)
    testing.expect_value(t,at(pixels,64,2,2),red)
    testing.expect_value(t,at(pixels,64,8,4),green)
    testing.expect_value(t,at(pixels,64,23,23),green)
    testing.expect_value(t,at(pixels,64,24,23),red)
    testing.expect_value(t,at(pixels,64,23,24),red)
    testing.expect_value(t,at(pixels,64,7,10),red)
    testing.expect_value(t,at(pixels,64,10,3),red)
    testing.expect_value(t,at(pixels,64,50,34),blue)
    testing.expect_value(t,at(pixels,64,40,40),red)
    // The other order: the game layer covers the editor's.
    swapped:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=editor[:],draws=draws},{vertices=game[:]}}})
    defer delete(swapped)
    testing.expect_value(t,at(swapped,64,10,10),red)
    testing.expect_value(t,at(swapped,64,50,34),red)
    // A scissor is in window points: on a 2x drawable it covers twice the pixels.
    renderer_resize(f.renderer,128,96,2,2)
    dense:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=game[:]},{vertices=editor[:],draws=draws}}})
    defer delete(dense)
    testing.expect_value(t,at(dense,128,16,8),green)
    testing.expect_value(t,at(dense,128,47,47),green)
    testing.expect_value(t,at(dense,128,48,47),red)
    testing.expect_value(t,at(dense,128,15,20),red)
    testing.expect_value(t,at(dense,128,100,70),blue)
    // Draws that name no whole triangle, or vertices the layer does not have, draw nothing.
    broken:=[]Ui_Draw{{first=0,count=2},{first=12,count=6},{first=10,count=30},{first=0,count=6,scissor={200,200,10,10}}}
    nothing:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=game[:]},{vertices=editor[:],draws=broken}}})
    defer delete(nothing)
    testing.expect_value(t,at(nothing,128,20,20),red)
    testing.expect_value(t,at(nothing,128,120,90),red)
    // Into a UI texture the layers draw the same, in units of the size of the
    // draw that span the texture: one pixel each here, whatever the scale of
    // the window. A later draw into the texture goes over the one before.
    texture,made:=ui_texture_add(f.renderer,64,48,"ui capture")
    if !testing.expect(t,made,f.renderer.error) {return}
    defer ui_texture_remove(f.renderer,texture)
    into:=[]Ui_Texture_Draw{{texture=texture,layer={vertices=game[:]},size={64,48}},{texture=texture,layer={vertices=editor[:],draws=draws},size={64,48}}}
    testing.expect(t,renderer_frame(f.renderer,{offscreen=true,ui_only=true,ui_textures=into}),f.renderer.error)
    viewed,_,_,read:=ui_texture_capture(f.renderer,texture)
    if !testing.expect(t,read,f.renderer.error) {return}
    defer delete(viewed)
    testing.expect_value(t,at(viewed,64,8,4),green)
    testing.expect_value(t,at(viewed,64,23,23),green)
    testing.expect_value(t,at(viewed,64,24,23),red)
    testing.expect_value(t,at(viewed,64,7,10),red)
    testing.expect_value(t,at(viewed,64,50,34),blue)
}

@(test)
ui_draws_images_of_the_texture_table :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,48) {return}
    defer overlay_fixture_destroy(t,&f)
    r:=f.renderer
    // Left half orange, right half a half transparent blue; stored as display color.
    image:[4*4*4]u8
    for i in 0..<16 {
        left:=i%4<2
        copy(image[i*4:],[]u8{255,128,0,255} if left else []u8{0,0,255,128})
    }
    texture,loaded:=texture_add(r,{pixels=image[:],width=4,height=4,srgb=true,name="ui image"})
    testing.expect(t,loaded,r.error)
    material:=ui_image(r,texture)
    testing.expect(t,material&UI_MATERIAL_IMAGE_BIT!=0)
    testing.expect_value(t,ui_image(r,0),u32(0))
    testing.expect_value(t,ui_image(r,Texture_Handle(texture_count(r)+1)),u32(0))
    background:=quad(0,0,64,48,{1,1,1,1})
    picture:=quad(16,8,32,32,{1,1,1,1},material)
    vertices:[12]Ui_Vertex
    copy(vertices[:6],background[:])
    copy(vertices[6:],picture[:])
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=vertices[:]}}})
    defer delete(pixels)
    testing.expect(t,near_color(at(pixels,64,20,24),{255,128,0,255}),fmt.tprintf("the image shows the color it stores: %v",at(pixels,64,20,24)))
    testing.expect(t,near_color(at(pixels,64,40,24),{127,127,255,255},3),fmt.tprintf("its alpha blends it over what is under it: %v",at(pixels,64,40,24)))
    testing.expect_value(t,at(pixels,64,4,4),[4]u8{255,255,255,255})
    // The color of the vertices tints the image.
    for &vertex in vertices[6:] {vertex.color={0.5,1,1,1}}
    tinted:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=vertices[:]}}})
    defer delete(tinted)
    testing.expect(t,near_color(at(tinted,64,20,24),{128,128,0,255},2),fmt.tprintf("tinted: %v",at(tinted,64,20,24)))
}

@(test)
ui_vertices_beyond_the_capacity_are_dropped_and_counted :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,32,32,ui_capacity=9) {return}
    defer overlay_fixture_destroy(t,&f)
    first,second:=quad(0,0,16,32,{1,0,0,1}),quad(16,0,16,32,{0,1,0,1})
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=first[:]},{vertices=second[:]}}})
    defer delete(pixels)
    testing.expect_value(t,at(pixels,32,4,16),[4]u8{255,0,0,255})
    // One whole triangle of the second quad fits: its upper right half.
    testing.expect_value(t,at(pixels,32,28,4),[4]u8{0,255,0,255})
    testing.expect(t,at(pixels,32,18,28)!=[4]u8{0,255,0,255},"the triangle that did not fit is not drawn")
    testing.expect_value(t,renderer_stats(f.renderer).ui_vertices_dropped,u32(3))
    whole:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=first[:]}}})
    defer delete(whole)
    testing.expect_value(t,renderer_stats(f.renderer).ui_vertices_dropped,u32(0))
}

@(private)
place :: proc(position,scale:Vec3) -> Mat4 {
    m:=Mat4(1)
    m[0,0],m[1,1],m[2,2]=scale.x,scale.y,scale.z
    m[0,3],m[1,3],m[2,3]=position.x,position.y,position.z
    return m
}

// A wall across the left half of the view, two metres from the origin towards the camera's far side.
@(private)
wall_scene :: proc(f:^Overlay_Fixture) {
    scene_given(f.renderer,{{object_id=1,mesh=f.cube,transform=place({-2,0,0},{4,6,0.2}),tint={0.2,0.2,0.2}}},nil,{direction={0,0.3,1},color={1,1,1},illuminance=1 * math.PI,enabled=true},{background={0,0,0},use_background=true})
}

@(private)
PANEL_CAMERA :: Camera{position={0,0,6},forward={0,0,-6},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}

// A 100 x 100 point panel of one colour, a centimetre per point, centred on `origin`.
@(private)
panel :: proc(vertices:[]Ui_Vertex,origin:Vec3,depth_test:=true,billboard:=false) -> World_Panel {
    return {vertices=vertices,origin=origin,right={0.01,0,0},down={0,-0.01,0},pivot={50,50},depth_test=depth_test,billboard=billboard}
}

@(test)
world_panel_is_hidden_behind_the_scene_and_drawn_in_front_of_it :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,128,96) {return}
    defer overlay_fixture_destroy(t,&f)
    r:=f.renderer
    wall_scene(&f)
    magenta,cyan,yellow:=quad(0,0,100,100,{1,0,1,1}),quad(0,0,100,100,{0,1,1,1}),quad(0,0,100,100,{1,1,0,1})
    behind_wall,before_wall,beside:=Vec3{-1.5,0,-2},Vec3{-1.5,1.2,1},Vec3{1.5,0,-2}
    panels:=[]World_Panel{panel(magenta[:],behind_wall),panel(cyan[:],before_wall),panel(yellow[:],beside)}
    pixels:=captured(t,&f,{camera=PANEL_CAMERA,panels=panels},4)
    defer delete(pixels)
    project :: proc(r:^Renderer,p:Vec3) -> (x,y:int) {
        view,proj,_:=camera_matrices(PANEL_CAMERA,f32(r.targets.width)/f32(r.targets.height))
        clip:=(proj*view)*Vec4{p.x,p.y,p.z,1}
        return int((clip.x/clip.w*0.5+0.5)*f32(r.targets.output_width)),int((0.5-clip.y/clip.w*0.5)*f32(r.targets.output_height))
    }
    x,y:=project(r,behind_wall)
    hidden:=at(pixels,128,x,y)
    testing.expect(t,abs(int(hidden[0])-int(hidden[1]))<8 && abs(int(hidden[0])-int(hidden[2]))<8 && hidden[0]>0,fmt.tprintf("a panel behind the wall is hidden, the wall shows: %v",hidden))
    x,y=project(r,before_wall)
    testing.expect_value(t,at(pixels,128,x,y),[4]u8{0,255,255,255})
    x,y=project(r,beside)
    testing.expect_value(t,at(pixels,128,x,y),[4]u8{255,255,0,255})
    // Without the depth test the panel behind the wall shows through it.
    panels[0].depth_test=false
    through:=captured(t,&f,{camera=PANEL_CAMERA,panels=panels},2)
    defer delete(through)
    x,y=project(r,behind_wall)
    testing.expect_value(t,at(through,128,x,y),[4]u8{255,0,255,255})
    // A screen layer covers the panels.
    cover:=quad(0,0,128,96,{1,1,1,1})
    covered:=captured(t,&f,{camera=PANEL_CAMERA,panels=panels,ui={{vertices=cover[:]}}},2)
    defer delete(covered)
    x,y=project(r,beside)
    testing.expect_value(t,at(covered,128,x,y),[4]u8{255,255,255,255})
}

@(test)
world_panel_as_billboard_faces_the_camera :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,96,96) {return}
    defer overlay_fixture_destroy(t,&f)
    scene_given(f.renderer,nil,nil,{},{background={0,0,0},use_background=true})
    yellow:=quad(0,0,100,100,{1,1,0,1})
    // Seen from the side, a panel in the XY plane is edge on.
    side:=Camera{position={6,0,0},forward={-6,0,0},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    count_yellow :: proc(pixels:[]u8) -> (count:int) {
        for i:=0;i<len(pixels);i+=4 {if pixels[i]>200 && pixels[i+1]>200 && pixels[i+2]<60 {count+=1}}
        return
    }
    fixed:=captured(t,&f,{camera=side,panels={panel(yellow[:],{0,0,0})}})
    defer delete(fixed)
    testing.expect(t,count_yellow(fixed)<20,fmt.tprintf("a fixed panel seen edge on covers almost nothing: %d pixels",count_yellow(fixed)))
    facing:=captured(t,&f,{camera=side,panels={panel(yellow[:],{0,0,0},billboard=true)}})
    defer delete(facing)
    front:=captured(t,&f,{camera=PANEL_CAMERA,panels={panel(yellow[:],{0,0,0})}})
    defer delete(front)
    testing.expect(t,count_yellow(facing)>150,fmt.tprintf("a billboard faces the camera: %d pixels",count_yellow(facing)))
    testing.expect_value(t,count_yellow(facing),count_yellow(front))
    testing.expect_value(t,at(facing,96,48,48),[4]u8{255,255,0,255})
}

@(test)
world_panel_and_debug_lines_do_not_move_with_the_jitter_of_taa :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,128,96,taa=true) {return}
    defer overlay_fixture_destroy(t,&f)
    wall_scene(&f)
    yellow:=quad(0,0,100,100,{1,1,0,1})
    storage:[64]Debug_Vertex
    lines:=debug_lines_make(storage[:])
    debug_box(&lines,{0.5,-1.5,-1},{2.5,-0.5,0},{0,1,0,1})
    // The panel hangs a metre in front of the wall, whose depth moves with the jitter.
    frame:=Frame_Desc{camera=PANEL_CAMERA,panels={panel(yellow[:],{-1.5,1.2,1})},debug={lines}}
    // The marks of the overlay, in a frame: yellow and green pixels.
    marks :: proc(pixels:[]u8,out:[]bool) {
        for i:=0;i<len(pixels);i+=4 {
            out[i/4]=(pixels[i]>200 && pixels[i+1]>200 && pixels[i+2]<60) || (pixels[i]<60 && pixels[i+1]>200 && pixels[i+2]<60)
        }
    }
    reference:=captured(t,&f,frame,6)
    defer delete(reference)
    expected:=make([]bool,128*96)
    defer delete(expected)
    marks(reference,expected)
    marked:=0
    for mark in expected {marked+=int(mark)}
    testing.expect(t,marked>300,fmt.tprintf("panel and lines are drawn: %d pixels",marked))
    found:=make([]bool,128*96)
    defer delete(found)
    // Sixteen frames: every offset of the jitter sequence.
    for _ in 0..<16 {
        pixels:=captured(t,&f,frame,1)
        marks(pixels,found)
        delete(pixels)
        different:=0
        for mark,i in found {different+=int(mark!=expected[i])}
        testing.expect_value(t,different,0)
    }
}

@(test)
debug_lines_are_hidden_behind_the_scene_only_when_depth_tested :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,128,96) {return}
    defer overlay_fixture_destroy(t,&f)
    r:=f.renderer
    wall_scene(&f)
    storage_tested,storage_overlay:[8]Debug_Vertex
    tested,overlay:=debug_lines_make(storage_tested[:]),debug_lines_make(storage_overlay[:],depth_test=false)
    // Two lines across the whole view, behind the wall on its left half.
    debug_line(&tested,{-4,1,-2},{4,1,-2},{0,1,0,1})
    debug_line(&overlay,{-4,-1,-2},{4,-1,-2},{1,0,1,1})
    pixels:=captured(t,&f,{camera=PANEL_CAMERA,debug={tested,overlay}},4)
    defer delete(pixels)
    // Whether a line of this colour crosses the column x within three rows of y.
    crosses :: proc(pixels:[]u8,x,y:int,color:[4]u8) -> bool {
        for row in y-3..=y+3 {if at(pixels,128,x,row)==color {return true}}
        return false
    }
    row :: proc(r:^Renderer,height:f32) -> int {
        view,proj,_:=camera_matrices(PANEL_CAMERA,f32(r.targets.width)/f32(r.targets.height))
        clip:=(proj*view)*Vec4{0,height,-2,1}
        return int((0.5-clip.y/clip.w*0.5)*f32(r.targets.output_height))
    }
    green,magenta:=[4]u8{0,255,0,255},[4]u8{255,0,255,255}
    testing.expect(t,crosses(pixels,100,row(r,1),green),"the tested line shows beside the wall")
    testing.expect(t,!crosses(pixels,30,row(r,1),green),"and is hidden behind it")
    testing.expect(t,crosses(pixels,100,row(r,-1),magenta),"the overlay line shows beside the wall")
    testing.expect(t,crosses(pixels,30,row(r,-1),magenta),"and through it")
    // In front of the wall a tested line is visible over it.
    debug_lines_clear(&tested)
    debug_line(&tested,{-4,1,1},{4,1,1},{0,1,0,1})
    front:=captured(t,&f,{camera=PANEL_CAMERA,debug={tested}},2)
    defer delete(front)
    view,proj,_:=camera_matrices(PANEL_CAMERA,f32(r.targets.width)/f32(r.targets.height))
    clip:=(proj*view)*Vec4{0,1,1,1}
    testing.expect(t,crosses(front,30,int((0.5-clip.y/clip.w*0.5)*f32(r.targets.output_height)),green),"a line in front of the wall is drawn over it")
}

@(test)
debug_lines_beyond_the_capacity_of_the_frame_are_dropped_and_counted :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,32,32,debug_capacity=6) {return}
    defer overlay_fixture_destroy(t,&f)
    storage:[10]Debug_Vertex
    lines:=debug_lines_make(storage[:],depth_test=false)
    for i in 0..<5 {debug_line(&lines,{-1,f32(i)*0.2,0},{1,f32(i)*0.2,0},{1,1,1,1})}
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,debug={lines}})
    defer delete(pixels)
    testing.expect_value(t,renderer_stats(f.renderer).debug_vertices_dropped,u32(4))
    lit:=0
    for i:=0;i<len(pixels);i+=4 {lit+=int(pixels[i]==255)}
    testing.expect(t,lit>0,"the lines that fit are drawn")
}

@(test)
frames_with_layers_panels_and_lines_allocate_nothing_and_make_no_resources :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,96,64) {return}
    defer overlay_fixture_destroy(t,&f)
    r:=f.renderer
    wall_scene(&f)
    game,editor,sign:=quad(0,0,40,40,{1,0,0,0.5}),quad(20,20,40,40,{0,1,0,1}),quad(0,0,100,100,{1,1,0,1})
    draws:=[]Ui_Draw{{first=0,count=6,scissor={24,24,10,10}}}
    storage:[256]Debug_Vertex
    lines:=debug_lines_make(storage[:])
    frame:=Frame_Desc{camera=PANEL_CAMERA,ui={{vertices=game[:]},{vertices=editor[:],draws=draws}},panels={panel(sign[:],{1.5,0,-2}),panel(sign[:],{-1.5,1,1},billboard=true)},debug={lines}}
    for _ in 0..<4 {
        debug_lines_clear(&lines)
        debug_sphere(&lines,{1,0,0},1,{0,1,1,1})
        frame.debug[0]=lines
        testing.expect(t,renderer_frame(r,frame),r.error)
    }
    allocations:=f.tracking.total_allocation_count
    resources:=rhi.device_stats(f.device)
    caller:mem.Tracking_Allocator
    mem.tracking_allocator_init(&caller,context.allocator)
    defer mem.tracking_allocator_destroy(&caller)
    {
        context.allocator=mem.tracking_allocator(&caller)
        for i in 0..<8 {
            debug_lines_clear(&lines)
            debug_sphere(&lines,{1,f32(i)*0.1,0},1,{0,1,1,1})
            debug_axes(&lines,place({0,0,1},{1,1,1}))
            frame.debug[0]=lines
            testing.expect(t,renderer_frame(r,frame),r.error)
        }
    }
    testing.expect_value(t,f.tracking.total_allocation_count,allocations)
    testing.expect_value(t,caller.total_allocation_count,0)
    after:=rhi.device_stats(f.device)
    testing.expect_value(t,after.buffers,resources.buffers)
    testing.expect_value(t,after.textures,resources.textures)
    testing.expect_value(t,after.pipelines,resources.pipelines)
    testing.expect_value(t,after.exhausted,0)
}

// The atlas takes the texels that changed in the frame that records next,
// without a wait for the GPU, and a new size takes a new texture.
@(test)
the_font_atlas_takes_the_texels_that_changed_with_the_next_frame :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,32,16) {return}
    defer overlay_fixture_destroy(t,&f)
    r:=f.renderer
    pixels:=make([]u8,64*16)
    defer delete(pixels)
    testing.expect(t,renderer_set_font(r,pixels,64,16),r.error)
    texture:=r.font
    for y in 4..<8 {for x in 10..<20 {pixels[y*64+x]=200}}
    pixels[0]=99
    testing.expect(t,renderer_set_font(r,pixels,64,16,{10,4,10,4}),r.error)
    testing.expect(t,r.font==texture && r.font_pending==rhi.Texture_Region{10,4,10,4},"The region waits for the frame")
    testing.expect(t,renderer_frame(r,{camera=EMPTY_CAMERA}),r.error)
    rhi.device_wait_idle(f.device)
    texels:=make([]u8,64*16)
    defer delete(texels)
    testing.expect(t,rhi.texture_read(f.device,r.font,texels),rhi.device_error(f.device))
    testing.expect_value(t,texels[5*64+12],u8(200))
    testing.expect_value(t,texels[0],u8(0))
    testing.expect_value(t,texels[3*64+12],u8(0))
    bigger:=make([]u8,64*32)
    defer delete(bigger)
    testing.expect(t,renderer_set_font(r,bigger,64,32),r.error)
    testing.expect(t,r.font!=texture && r.font_pending==rhi.Texture_Region{})
}
