package mirai_render

import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:rhi"
import mm "mirai:std/math"
import "mirai:render/abi"

// What the UI of a game asks of the renderer besides the screen and the
// panels of the scene: world panels drawn into textures that materials show
// (Frame_Desc.ui_textures), effects the extensions draw into textures that
// the UI shows (Frame_Desc.effect_views), and the depth of the scene around a
// few pixels, read back for the CPU (Frame_Desc.probes): whether the scene
// hides a point a ray of a player meets.

UI_TEXTURE_CAPACITY :: 32
DEPTH_PROBE_CAPACITY :: abi.DEPTH_PROBE_CAPACITY
DEPTH_PROBE_CELLS :: abi.DEPTH_PROBE_CELLS // along each side of the patch a probe reads around its pixel
DEPTH_PROBE_CELL :: abi.DEPTH_PROBE_CELL   // pixels of the drawable along each side of a cell
// Triangles mesh_ray meets of a pose, or of a mesh without a tree, at most.
MESH_RAY_TRIANGLES :: 65536

// UI into a texture of ui_texture_add, before the views of the frame: a world
// panel on a mesh, or an interface captured alone. Its layer is drawn as the
// screen draws its own, isolated layers and scissors included, in layout
// units of size, which spans the texture.
Ui_Texture_Draw :: struct {
    texture:Texture_Handle,
    layer:Ui_Layer,
    size:Vec2,
    clear:Vec4, // display color under it; a later draw into the same texture in the frame draws over the one before
}

// What the extensions draw at the Effect stage into a texture of
// ui_texture_add(effects=true), seen by camera over nothing: its alpha is
// what they cover. The particles a Particles node of an interface plays.
Effect_View :: struct {
    texture:Texture_Handle,
    camera:Camera,
}

// A pixel of a view of the window around which the frame reads the depth of
// the scene back: a patch of DEPTH_PROBE_CELLS cells a side centered on it.
Depth_Probe :: struct {
    pixel:Vec2,    // from the top left corner of the view, in pixels of the drawable
    view:int,      // of the views of the window, in the order of Frame_Desc.views; 0 for a frame of one
    camera:Camera, // the view is drawn with: what places a point in the patch
    size:Vec2,     // of the view, in pixels of the drawable
}

// What a probe read: of each cell of its patch, by rows from the top, the
// depth along the view of the farthest opaque surface it holds, metres; 0
// where a pixel of it shows none, and not a number outside the view or for a
// view the frame did not draw.
Depth_Probe_Result :: struct {
    probe:Depth_Probe,
    cells:[DEPTH_PROBE_CELLS*DEPTH_PROBE_CELLS]f32,
}

@(private)
Ui_Texture_Target :: struct {
    texture:Texture_Handle,
    size:[2]u32,
    ldr:rhi.Texture,              // drawn, then copied into the entry
    hdr,coverage,depth:rhi.Texture, // of an effect view
    empty:rhi.Texture,            // the scene depth its effects fade against: none
    ui_layers:[UI_LAYER_DEPTH_CAPACITY]rhi.Texture, // made the first time its UI composes a layer
    ui_blur:[2]rhi.Texture,
    cleared:bool,
}

@(private)
Ui_Offscreen_State :: struct {
    targets:[UI_TEXTURE_CAPACITY]Ui_Texture_Target,
    made:u64,
    probes:rhi.Buffer,                                    // f32 per probe of the frame recorded
    probe_readback:[rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
    asked:[rhi.MAX_FRAMES_IN_FLIGHT][DEPTH_PROBE_CAPACITY]Depth_Probe, // of the frame each slot holds
    asked_count:[rhi.MAX_FRAMES_IN_FLIGHT]int,
    results:[DEPTH_PROBE_CAPACITY]Depth_Probe_Result,
    result_count:int,
    trees:[dynamic]Mesh_Ray_Tree, // a slot whose rays have no cuts is free
}

@(private)
DEPTH_PROBE_BYTES :: DEPTH_PROBE_CAPACITY*DEPTH_PROBE_CELLS*DEPTH_PROBE_CELLS*size_of(f32)

@(private)
UI_TEXTURE_KEY :: u64(0x7569746500000000)

@(private)
ui_offscreen_init :: proc(r:^Renderer) -> bool {
    o:=&r.ui_offscreen
    o.probes=rhi.buffer_create(r.device,{size=DEPTH_PROBE_BYTES,usage={.Storage,.Transfer_Src,.Transfer_Dst},name="depth probes"})
    for &b in o.probe_readback {b=rhi.buffer_create(r.device,{size=DEPTH_PROBE_BYTES,memory=.Readback,name="depth probe readback"})}
    if o.probes==0 || o.probe_readback[0]==0 || o.probe_readback[1]==0 {
        set_error(r,"depth probes: %s",rhi.device_error(r.device))
        return false
    }
    return true
}

@(private)
ui_offscreen_destroy :: proc(r:^Renderer) {
    o:=&r.ui_offscreen
    for &target in o.targets {ui_texture_target_destroy(r,&target)}
    if o.probes!=0 {rhi.buffer_destroy(r.device,o.probes)}
    for b in o.probe_readback {if b!=0 {rhi.buffer_destroy(r.device,b)}}
    for &tree in o.trees {mesh_rays_destroy(&tree.rays)}
    delete(o.trees)
    o^={}
}

@(private)
ui_texture_target_destroy :: proc(r:^Renderer,target:^Ui_Texture_Target) {
    for t in ([]rhi.Texture{target.ldr,target.hdr,target.coverage,target.depth,target.empty}) {if t!=0 {rhi.texture_destroy(r.device,t)}}
    for t in target.ui_layers {if t!=0 {rhi.texture_destroy(r.device,t)}}
    for t in target.ui_blur {if t!=0 {rhi.texture_destroy(r.device,t)}}
    target^={}
}

// Reads back what the last frame drew into an entry of ui_texture_add: RGBA8
// display values, rows from the top; the caller frees them. Waits for the
// GPU; between frames. False for a handle that names none.
ui_texture_capture :: proc(r:^Renderer,texture:Texture_Handle,allocator:=context.allocator) -> (pixels:[]u8,width,height:int,ok:bool) {
    target:=ui_texture_target(r,texture)
    if target==nil {return}
    width,height=int(target.size.x),int(target.size.y)
    memory:mem.Allocator_Error
    pixels,memory=make([]u8,width*height*4,allocator)
    if memory!=nil {set_error(r,"ui texture capture: no memory for %dx%d pixels",width,height);return nil,0,0,false}
    if !rhi.texture_read(r.device,target.ldr,pixels) {
        delete(pixels,allocator)
        set_error(r,"ui texture capture: %s",rhi.device_error(r.device))
        return nil,0,0,false
    }
    return pixels,width,height,true
}

// An entry of the texture table that frames draw UI into (Ui_Texture_Draw),
// or with effects an effect view (Effect_View): a material, or the UI,
// shows it as any color texture. Transparent black until a frame draws it.
// A load transaction between frames; false past UI_TEXTURE_CAPACITY, for a
// size the table does not take, or without memory.
ui_texture_add :: proc(r:^Renderer,width,height:u32,name:string,effects:=false) -> (texture:Texture_Handle,ok:bool) {
    if width==0 || height==0 || width>8192 || height>8192 {return}
    o:=&r.ui_offscreen
    target:^Ui_Texture_Target
    for &candidate in o.targets {if candidate.texture==0 {target=&candidate;break}}
    if target==nil {return}
    blank,error:=make([]u8,int(width)*int(height)*4,r.allocator)
    if error!=nil {return}
    defer delete(blank,r.allocator)
    o.made+=1
    texture=texture_image(r,UI_TEXTURE_KEY|o.made,blank,int(width),int(height),name) or_return
    d:=r.device
    target^={texture=texture,size={width,height}}
    target.ldr=rhi.texture_create(d,{width=width,height=height,format=.RGBA8_Unorm,usage={.Color_Target,.Sampled,.Transfer_Src},name="ui texture"})
    made:=target.ldr!=0
    if effects {
        target.hdr=rhi.texture_create(d,{width=width,height=height,format=.RGBA16_Float,usage={.Color_Target,.Sampled},name="effect view"})
        target.coverage=rhi.texture_create(d,{width=width,height=height,format=.R8_Unorm,usage={.Color_Target,.Sampled},name="effect view coverage"})
        target.depth=rhi.texture_create(d,{width=width,height=height,format=.D32_Float,usage={.Depth_Target},name="effect view depth"})
        target.empty=rhi.texture_create(d,{width=width,height=height,format=.R32_Float,usage={.Color_Target,.Sampled},name="effect view scene depth"})
        made&&=target.hdr!=0 && target.coverage!=0 && target.depth!=0 && target.empty!=0
    }
    if !made {
        set_error(r,"ui texture %s: %s",name,rhi.device_error(d))
        ui_texture_target_destroy(r,target)
        texture_remove(r,texture)
        return 0,false
    }
    return texture,true
}

// Removes an entry of ui_texture_add with what draws it. Between frames.
// False for a handle that names none.
ui_texture_remove :: proc(r:^Renderer,texture:Texture_Handle) -> bool {
    target:=ui_texture_target(r,texture)
    if target==nil {return false}
    rhi.device_wait_idle(r.device)
    ui_texture_target_destroy(r,target)
    return texture_remove(r,texture)
}

@(private)
ui_texture_target :: proc(r:^Renderer,texture:Texture_Handle) -> ^Ui_Texture_Target {
    if texture==0 {return nil}
    for &target in r.ui_offscreen.targets {if target.texture==texture {return &target}}
    return nil
}

// What a target drew, into its entry of the texture table.
@(private)
ui_texture_show :: proc(r:^Renderer,cmd:^rhi.Command_List,target:^Ui_Texture_Target) {
    image:=r.textures.textures[target.texture-1]
    rhi.cmd_copy_texture(cmd,target.ldr,image)
    rhi.cmd_barrier_texture(cmd,image,.Shader_Read)
}

// The world panels of the frame that go into textures, before the views
// that show them.
@(private)
ui_textures_record :: proc(r:^Renderer,cmd:^rhi.Command_List,slot:int,written:^int,draws:[]Ui_Texture_Draw) {
    if len(draws)==0 {return}
    rhi.cmd_timestamp(cmd,"ui textures")
    thumbnails:=r.thumbnails if r.thumbnails!=0 else r.dummy_texture
    rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler)
    rhi.cmd_bind_sampler(cmd,SLOT_POINT_SAMPLER,r.point_sampler)
    rhi.cmd_bind_sampler(cmd,SLOT_MATERIAL_SAMPLER,r.material_sampler)
    materials:=or_dummy(r,r.scene.material_buffer)
    rhi.cmd_bind_buffer(cmd,SLOT_MATERIALS,materials)
    rhi.cmd_bind_transient(cmd,SLOT_FRAME,frame_constants(r,{time={r.time,r.previous_time,r.delta_time,0},resolution={f32(r.window_width),f32(r.window_height)}}))
    // A texture drawn twice in the frame is shown once, after its last draw.
    shown:[UI_TEXTURE_CAPACITY]bool
    for draw,i in draws {
        target:=ui_texture_target(r,draw.texture)
        if target==nil || draw.size.x<=0 || draw.size.y<=0 {continue}
        at:=mem.ptr_sub(target,&r.ui_offscreen.targets[0])
        first:=true
        for earlier in draws[:i] {if earlier.texture==draw.texture {first=false;break}}
        for d in draw.layer.draws {
            if d.kind==.Begin_Layer {ui_layer_targets(r,target.ui_layers[:],target.ui_blur[:],target.size.x,target.size.y);break}
        }
        pass:=rhi.Render_Pass_Desc{color_count=1,name="ui texture"}
        pass.colors[0]={texture=target.ldr,load=.Clear if first else .Load,store=.Store,clear=draw.clear}
        rhi.cmd_begin_render_pass(cmd,&pass)
        rhi.cmd_set_viewport(cmd,0,0,f32(target.size.x),f32(target.size.y))
        surface:=Ui_Surface{target.ldr,target.ui_layers[:],target.ui_blur[:],target.size.x,target.size.y}
        layers:=[1]Ui_Layer{draw.layer}
        ui_layers_pass(r,cmd,surface,slot,written,layers[:],draw.size,f32(target.size.x)/draw.size.x,thumbnails)
        rhi.cmd_end_render_pass(cmd)
        shown[at]=true
    }
    for &target,at in r.ui_offscreen.targets {
        if shown[at] {ui_texture_show(r,cmd,&target)}
    }
}

// The effect views of the frame, after the Simulate stage and before the UI
// that shows them: what the extensions draw at the Effect stage over nothing,
// then its light, exposed at 1, through the display transform, with what it
// covers as alpha. The pass stands for the view while the stage runs: its
// targets are those of the texture, and its constants those of the camera.
// Binds again the constants of the view.
@(private)
effect_views_record :: proc(p:^Pass,views:[]Effect_View) {
    r,cmd:=p.r,p.cmd
    if len(views)==0 || !stage_asked(r,.Effect) {return}
    rhi.cmd_timestamp(cmd,"effect views")
    frame:=p.frame
    view_t,constants,glass,blended:=p.t,p.constants,p.glass,p.blended
    defer {p.frame=frame;p.t,p.constants,p.glass,p.blended=view_t,constants,glass,blended}
    for view in views {
        target:=ui_texture_target(r,view.texture)
        if target==nil || target.hdr==0 {continue}
        size:=Vec2{f32(target.size.x),f32(target.size.y)}
        camera:=view.camera
        matrix_view,proj,forward:=camera_matrices(camera,size.x/size.y)
        matrix_view=matrix_from_eye(matrix_view)
        view_proj:=proj*matrix_view
        f:=Gpu_Frame{
            view=matrix_view,proj=proj,view_proj=view_proj,inv_view_proj=linalg.inverse(view_proj),view_proj_unjittered=view_proj,prev_view_proj=view_proj,
            camera_position={camera.position.x,camera.position.y,camera.position.z,max(camera.near,0.001)},
            camera_forward={forward.x,forward.y,forward.z,camera_reach(camera,1,-1)},
            scene_box={{1,1,1,0},{-1,-1,-1,0}}, // its own space, without the scene
            prev_eye={camera.position.x,camera.position.y,camera.position.z,0},
            frustum=frustum_from_eye(view_proj,camera.position),resolution=size,inv_resolution=1/size,
            time={r.time,r.previous_time,r.delta_time,0},exposure=1,
        }
        frame_view_constants(&f,camera,matrix_view,proj,proj,forward,size.y)
        p.constants=frame_constants(r,f)
        p.frame=f
        rhi.cmd_bind_transient(cmd,SLOT_FRAME,p.constants)
        if !target.cleared {
            clear_textures(cmd,target.empty)
            target.cleared=true
        }
        clear:=rhi.Render_Pass_Desc{color_count=2,name="effect view clear"}
        clear.colors[0]={texture=target.hdr,load=.Clear,store=.Store}
        clear.colors[1]={texture=target.coverage,load=.Clear,store=.Store}
        clear.depth={texture=target.depth,load=.Clear,store=.Store}
        rhi.cmd_begin_render_pass(cmd,&clear)
        rhi.cmd_end_render_pass(cmd)
        t:=Targets{width=target.size.x,height=target.size.y,display=target.hdr,reactive=target.coverage,depth=target.depth,linear_depth=target.empty}
        p.t,p.glass,p.blended=&t,.All,true
        s:=Stage_Pass{stage=.Effect,width=t.width,height=t.height,eye=f.eye,view_projection=view_proj,camera=camera,world=r.world_key,frame=r.frame,time=r.time,pass=p,texture=view.texture}
        for pass in r.passes[:r.pass_count] {
            if pass.stage==.Effect {pass.record(&s,pass.user)}
        }
        resolve:=rhi.Render_Pass_Desc{color_count=1,name="effect view resolve"}
        resolve.colors[0]={texture=target.ldr,load=.Dont_Care,store=.Store}
        rhi.cmd_begin_render_pass(cmd,&resolve)
        rhi.cmd_bind_pipeline(cmd,r.pipelines[.Ui_Particles])
        params:=[4]u32{}
        set_params(cmd,&params)
        rhi.cmd_bind_texture(cmd,SLOT_PASS0,target.hdr)
        rhi.cmd_bind_texture(cmd,SLOT_PASS1,target.coverage)
        rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
        rhi.cmd_draw(cmd,3)
        rhi.cmd_end_render_pass(cmd)
        ui_texture_show(r,cmd,target)
    }
    p.t,p.constants=view_t,constants
    rhi.cmd_bind_transient(cmd,SLOT_FRAME,p.constants)
    bind_scene_table(p)
}

// What the probes of the frame a slot held read, once the GPU finished it,
// and the probes of this frame in its place.
@(private)
depth_probes_begin :: proc(r:^Renderer,cmd:^rhi.Command_List,slot:int,probes:[]Depth_Probe) {
    o:=&r.ui_offscreen
    if o.asked_count[slot]>0 {
        if mapped:=rhi.buffer_mapped(r.device,o.probe_readback[slot]);mapped!=nil {
            cells:=cast([^][DEPTH_PROBE_CELLS*DEPTH_PROBE_CELLS]f32)mapped
            o.result_count=o.asked_count[slot]
            for i in 0..<o.result_count {o.results[i]={o.asked[slot][i],cells[i]}}
        }
    }
    count:=min(len(probes),DEPTH_PROBE_CAPACITY)
    copy(o.asked[slot][:],probes[:count])
    o.asked_count[slot]=count
    // Bytes of 0xff are not a number: what no view writes.
    if count>0 {rhi.cmd_fill_buffer(cmd,o.probes,0,DEPTH_PROBE_BYTES,0xff)}
}

// The probes of the window view a pass draws, from its linear depth.
@(private)
depth_probes_record :: proc(p:^Pass) {
    r,cmd,t:=p.r,p.cmd,p.t
    o:=&r.ui_offscreen
    count:=o.asked_count[p.slot]
    if count==0 || p.texture {return}
    Params :: struct {count,view:u32,scale:Vec2,pixels:[DEPTH_PROBE_CAPACITY]Vec4}
    params:=Params{count=u32(count),view=u32(p.index),scale={f32(t.width)/f32(max(t.output_width,1)),f32(t.height)/f32(max(t.output_height,1))}}
    for probe,i in o.asked[p.slot][:count] {params.pixels[i]={probe.pixel.x,probe.pixel.y,f32(probe.view),0}}
    rhi.cmd_bind_pipeline(cmd,r.pipelines[.Depth_Probe])
    set_params(cmd,&params)
    rhi.cmd_bind_texture(cmd,SLOT_PASS0,t.linear_depth)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS1,o.probes)
    rhi.cmd_dispatch(cmd,DEPTH_PROBE_CELLS/8,DEPTH_PROBE_CELLS/8,u32(count))
}

// The probes of the frame on their way to the CPU.
@(private)
depth_probes_end :: proc(r:^Renderer,cmd:^rhi.Command_List,slot:int) {
    o:=&r.ui_offscreen
    if o.asked_count[slot]==0 {return}
    rhi.cmd_copy_buffer(cmd,o.probes,0,o.probe_readback[slot],0,DEPTH_PROBE_BYTES)
    rhi.cmd_barrier_buffer(cmd,o.probe_readback[slot],.Host_Read)
}

// What the probes of the last frame the GPU finished read: a frame or two
// after they were asked for. Valid until the next frame.
renderer_depth_probes :: proc(r:^Renderer) -> []Depth_Probe_Result {
    return r.ui_offscreen.results[:r.ui_offscreen.result_count]
}

// Whether the scene a probe read hides point: farther along the view of its
// camera than the farthest surface of the cell it falls in, by more than
// share of that depth plus metres. known false where the probe cannot say:
// out of its patch, out of the view, or behind its camera.
depth_probe_hides :: proc(result:^Depth_Probe_Result,point:Vec3,share,metres:f32) -> (hidden,known:bool) {
    probe:=&result.probe
    if probe.size.x<=0 || probe.size.y<=0 {return}
    view,proj,forward:=camera_matrices(probe.camera,probe.size.x/probe.size.y)
    clip:=proj*view*Vec4{point.x,point.y,point.z,1}
    if clip.w<=1e-6 {return}
    pixel:=Vec2{(clip.x/clip.w*0.5+0.5)*probe.size.x,(0.5-clip.y/clip.w*0.5)*probe.size.y}
    cell:=linalg.floor((pixel-probe.pixel)/DEPTH_PROBE_CELL+DEPTH_PROBE_CELLS*0.5)
    if cell.x<0 || cell.y<0 || cell.x>=DEPTH_PROBE_CELLS || cell.y>=DEPTH_PROBE_CELLS {return}
    depth:=result.cells[int(cell.y)*DEPTH_PROBE_CELLS+int(cell.x)]
    if depth!=depth || depth<0 {return}
    return depth>0 && linalg.dot(point-probe.camera.position,forward)>depth*share+metres,true
}

// Where a ray meets a mesh placed by transform, the first texture
// coordinates of the mesh there and the normal of its triangle in the world,
// unit and against the ray: the nearest triangle of level 0, from what
// the renderer keeps of the mesh on the CPU, its software BVH or the one
// mesh_ray_prepare made. A pose of skin_create is met as its palette and
// morph weights of the next frame pose it, triangle by triangle. ok false
// for a miss, a mesh that is not there, a pose with more than
// MESH_RAY_TRIANGLES triangles, or a mesh with as many and no tree. A pose
// an extension deforms is met at rest.
mesh_ray :: proc(r:^Renderer,mesh:Mesh_Handle,transform:Mat4,origin,direction:Vec3,limit:f32=max(f32)) -> (distance:f32,uv:Vec2,normal:Vec3,ok:bool) {
    s:=&r.scene
    if int(mesh)>=len(s.meshes) {return}
    m:=&s.meshes[mesh]
    if m.vertex_count==0 {return}
    mesh_filled(s,u32(mesh))
    inverse:=linalg.inverse(transform)
    from:=(inverse*Vec4{origin.x,origin.y,origin.z,1}).xyz
    along:=(inverse*Vec4{direction.x,direction.y,direction.z,0}).xyz
    // x-x is zero only for a finite x: a transform without an inverse meets nothing.
    if from-from!={} || along-along!={} {return}
    p:=record_pooled(s,m^)
    primitive:=-1
    distance=limit
    ray:=m.rays[0]
    skin:=m.skin if m.skin!=nil && !m.skin.external && m.skin.binding!=nil else nil
    tree:=mesh_ray_tree(r,mesh)
    switch {
    case skin==nil && ray.bvh_node_count>0:
        t,hit:=bvh_ray_triangles(s.blas_nodes[ray.bvh_root:][:ray.bvh_node_count],s.blas_triangles[ray.triangle_offset:][:ray.triangle_count],from,along,limit)
        if hit>=0 {distance,primitive=t,hit}
    case skin==nil && tree!=nil:
        cut:=&tree.rays.cuts[0]
        t,hit:=bvh_ray_triangles(cut.nodes,cut.triangles,from,along,limit)
        if hit>=0 {distance,primitive=t,hit}
    case:
        if m.triangle_count>MESH_RAY_TRIANGLES {return}
        _,level0:=record_level(s,m^,0)
        for ordinal in 0..<level0 {
            g,c,resident:=pooled_cluster(p,ordinal)
            if !resident {continue}
            first:=p.clusters[ordinal].vertex_first
            for t in 0..<asset.cluster_triangle_count(c) {
                a,b,d:=cluster_triangle_positions(g,c,t)
                if skin!=nil {
                    corners:=asset.cluster_triangle(g.triangles,c,t)
                    a,b,d=posed_position(skin,a,first+u32(corners[0])),posed_position(skin,b,first+u32(corners[1])),posed_position(skin,d,first+u32(corners[2]))
                }
                if hit,_,crossed:=mm.ray_triangle({from,along},{a,b,d});crossed && hit>0 && hit<distance {distance,primitive=hit,int(u32(ordinal)<<PRIMITIVE_TRIANGLE_BITS|t)}
            }
        }
    }
    if primitive<0 {return}
    g,c,resident:=pooled_cluster(p,u32(primitive)>>PRIMITIVE_TRIANGLE_BITS)
    if !resident {return}
    t:=u32(primitive)&(1<<PRIMITIVE_TRIANGLE_BITS-1)
    corners:=asset.cluster_triangle(g.triangles,c,t)
    va,vb,vc:=asset.cluster_vertex(g,c,corners[0]),asset.cluster_vertex(g,c,corners[1]),asset.cluster_vertex(g,c,corners[2])
    a,b,d:=va.position,vb.position,vc.position
    if skin!=nil {
        first:=p.clusters[u32(primitive)>>PRIMITIVE_TRIANGLE_BITS].vertex_first
        a,b,d=posed_position(skin,a,first+u32(corners[0])),posed_position(skin,b,first+u32(corners[1])),posed_position(skin,d,first+u32(corners[2]))
    }
    _,weights,_:=mm.ray_triangle({from,along},{a,b,d})
    local:=linalg.cross(b-a,d-a)
    normal=linalg.normalize0((linalg.transpose(inverse)*Vec4{local.x,local.y,local.z,0}).xyz)
    if linalg.dot(normal,direction)>0 {normal=-normal}
    return distance,va.uv*(1-weights.x-weights.y)+vb.uv*weights.x+vc.uv*weights.y,normal,true
}

// Where a vertex of a pose is in the next frame: at rest, with what its
// morph targets add at their weights, taken by its joints, as skin.comp does.
// vertex: of those of the mesh.
@(private)
posed_position :: proc(skin:^Skin_State,rest:Vec3,vertex:u32) -> Vec3 {
    b:=skin.binding
    position:=rest
    if b.morph.count>0 && int(vertex)<len(b.morph.ranges) {
        span:=b.morph.ranges[vertex]
        for delta in b.morph.deltas[span.first:][:span.count] {
            if int(delta.target)<len(skin.morph_weights) {position+=asset.morph_position(delta.position,b.morph.step)*skin.morph_weights[delta.target].x}
        }
    }
    if int(vertex)>=len(b.influences) {return position}
    influence:=b.influences[vertex]
    rows:[3]Vec4
    for weight,i in influence.weights {
        if weight==0 || int(influence.joints[i])>=len(skin.joints) {continue}
        joint:=&skin.joints[influence.joints[i]].current
        w:=f32(weight)/255
        rows[0]+=joint[0]*w;rows[1]+=joint[1]*w;rows[2]+=joint[2]*w
    }
    q:=Vec4{position.x,position.y,position.z,1}
    return {linalg.dot(rows[0],q),linalg.dot(rows[1],q),linalg.dot(rows[2],q)}
}

// A software tree of level 0 of a mesh that the renderer does not keep one
// of, as while rays are traced by hardware, for mesh_ray.
@(private)
Mesh_Ray_Tree :: struct {
    mesh:Mesh_Handle,
    cluster_word:u32, // of the mesh it was made of: another mesh in the handle is another one
    rays:Mesh_Rays,
}

@(private)
mesh_ray_tree :: proc(r:^Renderer,mesh:Mesh_Handle) -> ^Mesh_Ray_Tree {
    m:=&r.scene.meshes[mesh]
    for &tree in r.ui_offscreen.trees {
        if tree.rays.count>0 && tree.mesh==mesh && tree.cluster_word==m.cluster_word {return &tree}
    }
    return nil
}

// Makes what mesh_ray meets a mesh with when the renderer keeps no software
// tree of it: a transaction, for a mesh a ray will meet in many frames, as
// one a widget is drawn on or the editor picks. A pose needs none. The tree
// stays until mesh_ray_release or the mesh goes. False without memory for it
// or while the mesh is not all there yet.
mesh_ray_prepare :: proc(r:^Renderer,mesh:Mesh_Handle) -> bool {
    s:=&r.scene
    if int(mesh)>=len(s.meshes) {return false}
    m:=&s.meshes[mesh]
    if m.vertex_count==0 {return false}
    if m.skin!=nil || m.rays[0].bvh_node_count>0 || mesh_ray_tree(r,mesh)!=nil {return true}
    trees:=&r.ui_offscreen.trees
    free:^Mesh_Ray_Tree
    for &tree in trees {
        if tree.rays.count==0 {free=&tree;break}
    }
    if free==nil {
        if trees.allocator.procedure==nil {trees.allocator=r.allocator}
        if _,error:=append(trees,Mesh_Ray_Tree{});error!=nil {return false}
        free=&trees[len(trees)-1]
    }
    g,decoded:=record_decode(s,m^,r.allocator)
    if !decoded {return false}
    defer geometry_decoded_free(&g,r.allocator)
    g.ray_errors={}
    rays,built:=mesh_rays_build(g,true,r.allocator)
    if !built {return false}
    free^={mesh=mesh,cluster_word=m.cluster_word,rays=rays}
    return true
}

// Lets go of what mesh_ray_prepare made for a mesh.
mesh_ray_release :: proc(r:^Renderer,mesh:Mesh_Handle) {
    if int(mesh)>=len(r.scene.meshes) {return}
    if tree:=mesh_ray_tree(r,mesh);tree!=nil {
        mesh_rays_destroy(&tree.rays)
        tree^={}
    }
}
