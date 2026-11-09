package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:rhi"
import mm "mirai:std/math"

// World-space triangles from the common asset/scene extraction. Materials
// address a request-local table, whose textures use the device's shared table.
Thumbnail_Vertex :: struct {
    position, normal: Vec3,
    uv0, uv1: Vec2,
    tint, emission: Vec3,
    material: u32,
    tangent: Vec4, // as Mesh_Vertex.tangent
}
Gpu_Thumbnail_Vertex :: struct {vertex:Gpu_Vertex, emission:Vec3}

Thumbnail_GPU :: struct {
    vertices, materials, frame: rhi.Buffer,
    color, depth: rhi.Texture,
    width, height: u32,
}

thumbnail_destroy :: proc(device:^rhi.Device,state:^Thumbnail_GPU) {
    if device!=nil {
        for buffer in ([]rhi.Buffer{state.vertices,state.materials,state.frame}) {if buffer!=0 {rhi.buffer_destroy(device,buffer)}}
        for texture in ([]rhi.Texture{state.color,state.depth}) {if texture!=0 {rhi.texture_destroy(device,texture)}}
    }
    state^={}
}

// The view of a studio image: the triangles and, when given, a box of the
// world, seen whole from the direction of the studio or that of the view,
// through a parallel projection or the lens of the previews, and lit as light
// says. False for vertices that name a material out of the table of the
// request, or that span nothing.
@(private)
thumbnail_view :: proc(r:^Renderer,vertices:[]Thumbnail_Vertex,materials:int,width,height:u32,fit:[2]Vec3,view:=Preview_View{},light:=Preview_Light{},perspective:=false) -> (constants:Gpu_Frame,ok:bool) {
    toward:=linalg.normalize(Vec3{-0.55,0.5,-0.75})
    if view.zoom>0 {
        yaw,elevation:=view.orbit.x,clamp(view.orbit.y,-PREVIEW_ELEVATION,PREVIEW_ELEVATION)
        toward=Vec3{-math.cos(elevation)*math.sin(yaw),math.sin(elevation),-math.cos(elevation)*math.cos(yaw)}
    }
    right:=linalg.normalize(linalg.cross(Vec3{0,1,0},toward))
    up:=linalg.cross(toward,right)
    lo,hi:=Vec3{math.F32_MAX,math.F32_MAX,math.F32_MAX},Vec3{-math.F32_MAX,-math.F32_MAX,-math.F32_MAX}
    for vertex in vertices {
        if int(vertex.material)>=materials {return {},false}
        projection:=Vec3{linalg.dot(vertex.position,right),linalg.dot(vertex.position,up),linalg.dot(vertex.position,toward)}
        lo=linalg.min(lo,projection);hi=linalg.max(hi,projection)
    }
    if fit[0].x<=fit[1].x && fit[0].y<=fit[1].y && fit[0].z<=fit[1].z && fit[0]!=fit[1] {
        for corner in 0..<8 {
            point:=Vec3{fit[corner&1].x,fit[corner>>1&1].y,fit[corner>>2&1].z}
            projection:=Vec3{linalg.dot(point,right),linalg.dot(point,up),linalg.dot(point,toward)}
            lo=linalg.min(lo,projection);hi=linalg.max(hi,projection)
        }
    }
    extent:=max(hi.x-lo.x,hi.y-lo.y)
    if !(extent>1e-6) || math.is_inf(extent) || math.is_nan(extent) {return {},false}
    // The height the image shows: the nearest face of the box spans 0.88 of
    // it, across or up, whichever it fills first.
    seen:=max(hi.y-lo.y,(hi.x-lo.x)*f32(height)/f32(width))/0.88
    center:=(lo+hi)*0.5
    // The view: closer, and what is framed moved across by heights of the image.
    if view.zoom>0 && !math.is_nan(view.zoom) {
        center.x-=view.pan.x*seen
        center.y+=view.pan.y*seen
        seen/=view.zoom
    }
    half:=seen*0.5
    front:=hi.z-center.z
    middle:=right*center.x+up*center.y+toward*center.z
    camera:=Camera{forward=-toward,up={0,1,0},projection=.Orthographic,height=2*half}
    distance:=front+extent
    if perspective {
        camera.projection,camera.fov_y=.Perspective,PREVIEW_FOV
        distance=front+half/math.tan(PREVIEW_FOV*math.PI/360)
    }
    camera.position=middle+toward*distance
    camera.near=(distance-front)*0.5
    camera.far=distance+(center.z-lo.z)+extent
    world_view,projection,forward:=camera_matrices(camera,f32(width)/f32(height))
    world_view=matrix_from_eye(world_view)
    view_projection:=projection*world_view
    constants={
        view=world_view,proj=projection,view_proj=view_projection,view_proj_unjittered=view_projection,prev_view_proj=view_projection,inv_view_proj=linalg.inverse(view_projection),
        camera_position={camera.position.x,camera.position.y,camera.position.z,camera.near},camera_forward={forward.x,forward.y,forward.z,camera.far},
        prev_eye={camera.position.x,camera.position.y,camera.position.z,0},
        resolution={f32(width),f32(height)},inv_resolution={1/f32(width),1/f32(height)},time={r.time,r.previous_time,r.delta_time,0},
    }
    frame_view_constants(&constants,camera,world_view,projection,projection,forward,f32(height))
    preview_lighting(&constants,light)
    constants.flags|=display_frame_flags(r)
    return constants,true
}

// The light of a preview in the constants of its frame. The studio takes
// render units as nits and exposes them itself.
@(private)
preview_lighting :: proc(f:^Gpu_Frame,light:Preview_Light) {
    if !light.outdoor {
        f.flags|=FRAME_FLAG_STUDIO
        f.exposure,f.sky_color.w=1,1
        return
    }
    sun:=light.sun
    key:=luminance_of(light.environment.sky)
    if sun.enabled && linalg.length(sun.direction)>1e-6 {
        sun.direction=linalg.normalize(sun.direction)
        key=max(key,sun.illuminance*luminance_of(sun.color)/math.PI)
    } else {sun.enabled=false}
    scale:=light_scale_of(0,key)
    frame_sun_sky(f,sun,light.environment,scale,SUN_RADIUS,false,true)
    if light.environment.ground_grid {f.flags|=FRAME_FLAG_GRID}
    // As the meter of a scene exposes an image half of its background and half
    // a middle gray card under its strongest light: their geometric mean.
    environment:=light.environment
    behind:=luminance_of(environment.background if environment.use_background else environment.sky)
    metered:=math.sqrt(max(behind,1e-3)*max(MIDDLE_GRAY*key,1e-3))
    ev100:=clamp(math.log2(metered*100/LIGHT_METER_K),AUTO_EXPOSURE_RANGE[0],AUTO_EXPOSURE_RANGE[1])
    f.exposure=exposure_of_ev100(ev100,display_exposure_bias(.Neutral))/scale
}

@(private)
thumbnail_vertex :: #force_inline proc "contextless" (vertex:Thumbnail_Vertex) -> Gpu_Thumbnail_Vertex {
    packed:=gpu_vertex({position=vertex.position,normal=vertex.normal,uv=vertex.uv0,uv1=vertex.uv1,color=vertex.tint,material=Material_Handle(vertex.material),tangent=vertex.tangent})
    return {vertex=packed,emission=vertex.emission}
}

// The pass of a studio image, over the tables bound for it: its view, its
// vertices and its materials; backdrop: what a preview lit as a scene shows
// behind them, else the clear color. size: the texels it draws from the top
// left corner; zero: all of them.
@(private)
thumbnail_record :: proc(r:^Renderer,cmd:^rhi.Command_List,color,depth:rhi.Texture,count:u32,rows:[]Gpu_Material_Row,clear:[4]f32={},backdrop:=false,size:=[2]u32{},now:=false) {
    rhi.cmd_bind_sampler(cmd,SLOT_MATERIAL_SAMPLER,r.material_sampler)
    rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler)
    pass:=rhi.Render_Pass_Desc{color_count=1,name="asset thumbnail"}
    pass.colors[0]={texture=color,load=.Clear,store=.Store,clear=clear}
    pass.depth={texture=depth,load=.Clear,store=.Dont_Care,clear=0}
    rhi.cmd_begin_render_pass(cmd,&pass)
    if size!={} {
        rhi.cmd_set_viewport(cmd,0,0,f32(size.x),f32(size.y))
        rhi.cmd_set_scissor(cmd,0,0,size.x,size.y)
    }
    if backdrop {
        rhi.cmd_bind_pipeline(cmd,r.pipelines[.Preview_Backdrop])
        rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
        rhi.cmd_draw(cmd,3)
    }
    rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
    rows_programs_draw(r,cmd,&r.pipelines[.Thumbnail],rows,count,now)
    rhi.cmd_end_render_pass(cmd)
}

// A blocking preview transaction between frames. The main scene, histories,
// and camera remain untouched; GPU capacities are reused by the next request.
// pixels: width*height RGBA8 texels of the caller, filled when it succeeds.
// fit: a box of the world the view frames together with the triangles, so
// that the images of a subject that moves share one view; none when empty.
renderer_thumbnail :: proc(r:^Renderer,state:^Thumbnail_GPU,vertices:[]Thumbnail_Vertex,materials:[]Material_Desc,width,height:u32,pixels:[]u8,fit:=[2]Vec3{})->bool {
    if r==nil || r.device==nil || len(vertices)==0 || len(vertices)%3!=0 || len(materials)==0 || width==0 || height==0 || len(pixels)!=int(width)*int(height)*4 {return false}
    constants,framed:=thumbnail_view(r,vertices,len(materials),width,height,fit)
    if !framed {return false}
    gpu_vertices:=make([]Gpu_Thumbnail_Vertex,len(vertices),context.temp_allocator)
    for vertex,index in vertices {gpu_vertices[index]=thumbnail_vertex(vertex)}
    gpu_materials:=make([]Gpu_Material_Row,len(materials),context.temp_allocator)
    for material,index in materials {gpu_materials[index]=gpu_material(r,material)}
    device:=r.device
    good,_:=ensure_buffer(r,&state.vertices,u64(len(gpu_vertices)*size_of(Gpu_Thumbnail_Vertex)),{.Storage,.Transfer_Dst},"thumbnail vertices")
    if !good {return false}
    good,_=ensure_buffer(r,&state.materials,u64(len(gpu_materials)*size_of(Gpu_Material_Row)),{.Storage,.Transfer_Dst},"thumbnail materials")
    if !good {return false}
    good,_=ensure_buffer(r,&state.frame,u64(r.frame_layout.size),{.Uniform,.Transfer_Dst},"thumbnail frame")
    if !good {return false}
    if state.width!=width || state.height!=height || state.color==0 || state.depth==0 {
        for texture in ([]rhi.Texture{state.color,state.depth}) {if texture!=0 {rhi.texture_destroy(device,texture)}}
        state.color=rhi.texture_create(device,{width=width,height=height,format=.RGBA8_Unorm,usage={.Color_Target,.Transfer_Src},name="thumbnail studio"})
        state.depth=rhi.texture_create(device,{width=width,height=height,format=.D32_Float,usage={.Depth_Target},name="thumbnail depth"})
        state.width=width;state.height=height
    }
    if state.color==0 || state.depth==0 {return false}
    frame_data:=[1]Gpu_Frame{constants}
    if !rhi.buffer_upload(device,state.vertices,0,slice_bytes(gpu_vertices)) || !rhi.buffer_upload(device,state.materials,0,slice_bytes(gpu_materials)) || !rhi.buffer_upload(device,state.frame,0,slice_bytes(frame_data[:])) {return false}
    cmd:=rhi.immediate_begin(device)
    for buffer in ([]rhi.Buffer{state.vertices,state.materials,state.frame}) {rhi.cmd_barrier_buffer(cmd,buffer,.Shader_Read)}
    rhi.cmd_bind_buffer(cmd,SLOT_FRAME,state.frame)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS0,state.vertices)
    rhi.cmd_bind_buffer(cmd,SLOT_MATERIALS,state.materials)
    thumbnail_record(r,cmd,state.color,state.depth,u32(len(gpu_vertices)),gpu_materials,now=true)
    if !rhi.immediate_end(device,cmd) {return false}
    return rhi.texture_read(device,state.color,pixels)
}

// What a capture of a material reads at each pixel besides the image: the
// targets of thumbnail_values.frag, RGBA32F, in this order. Lit: radiance by
// the exposure of the studio, a 1 where the subject covers the pixel. Albedo:
// base color and alpha. Surface: roughness, metallic and occlusion. Normal:
// the normal the material writes and its length. Emission: in nits, or
// relative to the exposure. A Surface program's values are as it writes them,
// before the renderer clamps them.
Thumbnail_Target :: enum u8 {Lit,Albedo,Surface,Normal,Emission}

Thumbnail_Values_GPU :: struct {
    using thumbnail:Thumbnail_GPU,
    targets:[Thumbnail_Target]rhi.Texture,
}

thumbnail_values_destroy :: proc(device:^rhi.Device,state:^Thumbnail_Values_GPU) {
    if device!=nil {for texture in state.targets {if texture!=0 {rhi.texture_destroy(device,texture)}}}
    thumbnail_destroy(device,&state.thumbnail)
    state^={}
}

// A studio image as renderer_thumbnail draws it, and the values of its
// materials at each pixel. pixels: width*height RGBA8; values: width*height
// RGBA32F texels per target. A blocking transaction between frames.
renderer_thumbnail_values :: proc(r:^Renderer,state:^Thumbnail_Values_GPU,vertices:[]Thumbnail_Vertex,materials:[]Material_Desc,width,height:u32,pixels:[]u8,values:[Thumbnail_Target][][4]f32,fit:=[2]Vec3{})->bool {
    if r==nil || r.device==nil || r.pipelines[.Thumbnail_Values]==0 || len(vertices)==0 || len(vertices)%3!=0 || len(materials)==0 || width==0 || height==0 || len(pixels)!=int(width)*int(height)*4 {return false}
    for target in values {if len(target)!=int(width)*int(height) {return false}}
    constants,framed:=thumbnail_view(r,vertices,len(materials),width,height,fit)
    if !framed {return false}
    gpu_vertices:=make([]Gpu_Thumbnail_Vertex,len(vertices),context.temp_allocator)
    for vertex,index in vertices {gpu_vertices[index]=thumbnail_vertex(vertex)}
    gpu_materials:=make([]Gpu_Material_Row,len(materials),context.temp_allocator)
    for material,index in materials {gpu_materials[index]=gpu_material(r,material)}
    device:=r.device
    for target in ([]struct{buffer:^rhi.Buffer,size:u64,usage:rhi.Buffer_Usage,name:string}{
        {&state.vertices,u64(len(gpu_vertices)*size_of(Gpu_Thumbnail_Vertex)),{.Storage,.Transfer_Dst},"thumbnail vertices"},
        {&state.materials,u64(len(gpu_materials)*size_of(Gpu_Material_Row)),{.Storage,.Transfer_Dst},"thumbnail materials"},
        {&state.frame,u64(r.frame_layout.size),{.Uniform,.Transfer_Dst},"thumbnail frame"},
    }) {
        if good,_:=ensure_buffer(r,target.buffer,target.size,target.usage,target.name);!good {return false}
    }
    if state.width!=width || state.height!=height || state.color==0 || state.depth==0 {
        for texture in ([]rhi.Texture{state.color,state.depth}) {if texture!=0 {rhi.texture_destroy(device,texture)}}
        for &texture in state.targets {if texture!=0 {rhi.texture_destroy(device,texture)};texture=0}
        state.color=rhi.texture_create(device,{width=width,height=height,format=.RGBA8_Unorm,usage={.Color_Target,.Transfer_Src},name="thumbnail studio"})
        state.depth=rhi.texture_create(device,{width=width,height=height,format=.D32_Float,usage={.Depth_Target},name="thumbnail depth"})
        for &texture in state.targets {texture=rhi.texture_create(device,{width=width,height=height,format=.RGBA32_Float,usage={.Color_Target,.Transfer_Src},name="thumbnail values"})}
        state.width=width;state.height=height
    }
    if state.color==0 || state.depth==0 {return false}
    for texture in state.targets {if texture==0 {return false}}
    frame_data:=[1]Gpu_Frame{constants}
    if !rhi.buffer_upload(device,state.vertices,0,slice_bytes(gpu_vertices)) || !rhi.buffer_upload(device,state.materials,0,slice_bytes(gpu_materials)) || !rhi.buffer_upload(device,state.frame,0,slice_bytes(frame_data[:])) {return false}
    cmd:=rhi.immediate_begin(device)
    for buffer in ([]rhi.Buffer{state.vertices,state.materials,state.frame}) {rhi.cmd_barrier_buffer(cmd,buffer,.Shader_Read)}
    rhi.cmd_bind_buffer(cmd,SLOT_FRAME,state.frame)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS0,state.vertices)
    rhi.cmd_bind_buffer(cmd,SLOT_MATERIALS,state.materials)
    rhi.cmd_bind_sampler(cmd,SLOT_MATERIAL_SAMPLER,r.material_sampler)
    rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler)
    pass:=rhi.Render_Pass_Desc{color_count=1+len(Thumbnail_Target),name="material capture"}
    pass.colors[0]={texture=state.color,load=.Clear,store=.Store}
    for texture,target in state.targets {pass.colors[1+int(target)]={texture=texture,load=.Clear,store=.Store}}
    pass.depth={texture=state.depth,load=.Clear,store=.Dont_Care,clear=0}
    rhi.cmd_begin_render_pass(cmd,&pass)
    rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
    rows_programs_draw(r,cmd,&r.pipelines[.Thumbnail_Values],gpu_materials,u32(len(gpu_vertices)),now=true)
    rhi.cmd_end_render_pass(cmd)
    if !rhi.immediate_end(device,cmd) {return false}
    if !rhi.texture_read(device,state.color,pixels) {return false}
    for texture,target in state.targets {
        if !rhi.texture_read(device,texture,slice_bytes(values[target])) {return false}
    }
    return true
}

PREVIEW_CAPACITY :: 4 // images a frame draws for its UI
// What a preview shows of its materials: the lit image, or a value of them as
// they write it (thumbnail.frag).
PREVIEW_CHANNELS :: bit_set[Debug_View]{.None,.Albedo,.Normal,.Roughness,.Metallic,.Emission}

// What an image drawn inside the frame keeps on the GPU. Its buffers are
// written while the frame is recorded: one set per frame in flight.
Preview_GPU :: struct {
    vertices,materials:[rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
    color,depth:rhi.Texture,
    copy:rhi.Buffer, // the texels on their way from the target to the image of the table
    width,height:u32,
}

@(private)
Preview_Request :: struct {
    gpu:^Preview_GPU,
    texture:Texture_Handle,
    vertices:[]Thumbnail_Vertex,
    materials:[]Material_Desc,
    background:Vec3,
    fit:[2]Vec3,
    view:Preview_View,
    light:Preview_Light,
    size:[2]u32, // texels drawn from the top left corner
    channel:Debug_View,
}

// The light a preview is drawn with: the analytic studio of the thumbnails
// (the zero value), or a sun and a sky as they light a scene, without
// shadows, over its background or its sky and its ground grid, exposed as
// the meter of a scene would (preview_lighting).
Preview_Light :: struct {
    outdoor:bool,
    sun:Sun_Desc,
    environment:Environment, // without its sky image
}
PREVIEW_FOV :: f32(30) // degrees, vertical: the lens of the previews

// How a preview looks at what it frames: zoom above 1 comes closer, pan moves
// what is shown by heights of the image (x to the right, y down) and orbit
// is the direction of the camera. The zero value frames it whole from the
// direction of the studio.
Preview_View :: struct {
    zoom:f32,
    pan:[2]f32,
    orbit:[2]f32, // radians: yaw about +Y from -Z, and elevation within ±PREVIEW_ELEVATION
}
PREVIEW_ORBIT :: [2]f32{0.6327488,0.4932758} // the direction of the studio
PREVIEW_ELEVATION :: f32(1.45)

preview_destroy :: proc(device:^rhi.Device,gpu:^Preview_GPU) {
    if device!=nil {
        for buffer in gpu.vertices {if buffer!=0 {rhi.buffer_destroy(device,buffer)}}
        for buffer in gpu.materials {if buffer!=0 {rhi.buffer_destroy(device,buffer)}}
        if gpu.copy!=0 {rhi.buffer_destroy(device,gpu.copy)}
        for texture in ([]rhi.Texture{gpu.color,gpu.depth}) {if texture!=0 {rhi.texture_destroy(device,texture)}}
    }
    gpu^={}
}

// Asks the next frame to draw triangles into an image of the texture table
// before its UI, which shows it with ui_image: nothing is submitted apart
// and nothing is read back. The image is the entry of the table with that
// key, added the first time, side texels square. The frame draws size texels
// of it from its top left corner, which a view of that shape shows. vertices
// and materials must stay as they are until that frame is drawn. The image is
// seen through the lens of the previews. background: the display color
// behind the triangles in the studio. False without room for another image in
// the frame, when the entry has another side, or when the request can show
// nothing. channel: what of its materials it shows instead of the lit image,
// one of PREVIEW_CHANNELS.
renderer_preview :: proc(r:^Renderer,gpu:^Preview_GPU,key:u64,name:string,vertices:[]Thumbnail_Vertex,materials:[]Material_Desc,side:u32,size:[2]u32,background:Vec3,fit:=[2]Vec3{},view:=Preview_View{},light:=Preview_Light{},channel:=Debug_View.None) -> (texture:Texture_Handle,ok:bool) {
    if r==nil || r.device==nil || r.preview_count>=PREVIEW_CAPACITY || len(vertices)==0 || len(vertices)%3!=0 || len(materials)==0 || side==0 || size.x==0 || size.y==0 || size.x>side || size.y>side || channel not_in PREVIEW_CHANNELS {return 0,false}
    device:=r.device
    width,height:=side,side
    w,h:int
    found:bool
    if texture,w,h,found=texture_find(r,key);found {
        if w!=int(width) || h!=int(height) {return 0,false}
    } else {
        blank:=make([]u8,int(width)*int(height)*4,context.temp_allocator)
        texture=texture_image(r,key,blank,int(width),int(height),name) or_return
    }
    if gpu.width!=width || gpu.height!=height || gpu.color==0 || gpu.depth==0 || gpu.copy==0 {
        for old in ([]rhi.Texture{gpu.color,gpu.depth}) {if old!=0 {rhi.texture_destroy(device,old)}}
        if gpu.copy!=0 {rhi.buffer_destroy(device,gpu.copy)}
        gpu.color=rhi.texture_create(device,{width=width,height=height,format=.RGBA8_Unorm,usage={.Color_Target,.Transfer_Src},name="preview studio"})
        gpu.depth=rhi.texture_create(device,{width=width,height=height,format=.D32_Float,usage={.Depth_Target},name="preview depth"})
        gpu.copy=rhi.buffer_create(device,{size=u64(width)*u64(height)*4,usage={.Transfer_Src,.Transfer_Dst},memory=.GPU,name="preview copy"})
        gpu.width,gpu.height=width,height
    }
    if gpu.color==0 || gpu.depth==0 || gpu.copy==0 {return 0,false}
    r.previews[r.preview_count]={gpu,texture,vertices,materials,background,fit,view,light,size,channel}
    r.preview_count+=1
    return texture,true
}

// Draws the images asked for since the last frame and leaves each in its
// entry of the table. It binds tables of its own: the caller binds those of
// the scene again.
@(private)
previews_pass :: proc(r:^Renderer,cmd:^rhi.Command_List,slot:int) {
    device:=r.device
    count:=r.preview_count
    r.preview_count=0
    for &request in r.previews[:count] {
        gpu:=request.gpu
        if int(request.texture)>r.textures.count || r.textures.textures[request.texture-1]==0 {continue}
        constants,framed:=thumbnail_view(r,request.vertices,len(request.materials),request.size.x,request.size.y,request.fit,request.view,request.light,true)
        if !framed {continue}
        constants.debug_view=u32(request.channel)
        sizes:=[2]u64{u64(len(request.vertices)*size_of(Gpu_Thumbnail_Vertex)),u64(len(request.materials)*size_of(Gpu_Material_Row))}
        buffers:=[2]^rhi.Buffer{&gpu.vertices[slot],&gpu.materials[slot]}
        ready:=true
        for buffer,index in buffers {
            if buffer^!=0 && rhi.buffer_size(device,buffer^)>=sizes[index] {continue}
            if buffer^!=0 {rhi.buffer_destroy(device,buffer^)}
            buffer^=rhi.buffer_create(device,{size=sizes[index]+sizes[index]/2,usage={.Storage},memory=.Upload,name="preview table"})
            ready&&=buffer^!=0
        }
        view:=frame_constants(r,constants)
        if !ready || view.ptr==nil {continue}
        packed:=([^]Gpu_Thumbnail_Vertex)(rhi.buffer_mapped(device,gpu.vertices[slot]))
        for vertex,index in request.vertices {packed[index]=thumbnail_vertex(vertex)}
        rows:=([^]Gpu_Material_Row)(rhi.buffer_mapped(device,gpu.materials[slot]))
        for material,index in request.materials {rows[index]=gpu_material(r,material)}
        rhi.cmd_bind_transient(cmd,SLOT_FRAME,view)
        rhi.cmd_bind_buffer(cmd,SLOT_PASS0,gpu.vertices[slot])
        rhi.cmd_bind_buffer(cmd,SLOT_MATERIALS,gpu.materials[slot])
        thumbnail_record(r,cmd,gpu.color,gpu.depth,u32(len(request.vertices)),rows[:len(request.materials)],{request.background.x,request.background.y,request.background.z,1},request.light.outdoor,request.size)
        image:=r.textures.textures[request.texture-1]
        rhi.cmd_copy_texture_to_buffer(cmd,gpu.color,gpu.copy,0)
        rhi.cmd_copy_buffer_to_texture(cmd,gpu.copy,0,image)
        rhi.cmd_barrier_texture(cmd,image,.Shader_Read)
    }
}

// A vertex as a thumbnail uploads it: whole, with the row of its material.
@(private)
gpu_vertex :: proc "contextless" (v: Mesh_Vertex) -> Gpu_Vertex {
	return {position = v.position, normal = mm.normal_pack(v.normal), uv = v.uv, uv1 = v.uv1, color = mm.rgba8_pack({v.color.x, v.color.y, v.color.z, 1}), material = u32(v.material) | (v.slot << 24), tangent = mm.tangent_pack(v.tangent.xyz, v.tangent.w)}
}
