package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:rhi"

// UI geometry drawn after the tonemap, in display colors: layers on the
// screen and panels placed in the scene. Both are triangles of the 40 byte
// Ui_Vertex and share the buffer of the frame, the font atlas and the images
// of the texture table.

// Ui_Vertex.material of an image: its texture, shown as the color it stores
// multiplied by the color of the vertex.
UI_MATERIAL_IMAGE_BIT :: u32(1) << 30
UI_MATERIAL_SHAPE_BIT :: u32(1) << 29
// Of a UI program, with the index of its Ui_Shape: its id in the bits of
// stroke.x, its first four floats in params, ctx.color in fill and its corners
// in bounds and radii.
UI_MATERIAL_PROGRAM_BIT :: u32(1) << 28
UI_SHAPE_CAPACITY :: 32768
UI_LAYER_DEPTH_CAPACITY :: 8

Ui_Shape :: struct {bounds,radii,fill,fill2,stroke,params:[4]f32}
Ui_Effect :: struct {bounds:[4]f32,radius,opacity,backdrop_blur,pad:f32}
#assert(size_of(Ui_Effect)==32)
Ui_Draw_Kind :: enum u8 {Triangles,Begin_Layer,End_Layer}
@(private)
Ui_Shape_Upload :: struct {source:rawptr,length,base,count:int}
@(private)
// Params_Block of ui.vert and ui.frag; origin, right and down are of a panel in the world.
Ui_Params :: struct {viewport:Vec2,shape_base,shape_count:u32,origin,right,down:Vec4}

// The material of the vertices that show a texture; a texture that does not
// exist gives the plain color of the vertex.
ui_image :: proc(r:^Renderer,texture:Texture_Handle) -> u32 {
    index:=texture_index(r,texture)
    return UI_MATERIAL_IMAGE_BIT|index if index!=max(u32) else 0
}

// A run of the triangles of a layer and the rectangle that clips it.
Ui_Draw :: struct {
    first,count:u32, // vertices of the layer
    scissor:    [4]f32, // x, y, width and height in window points; no width or height: not clipped
    kind:Ui_Draw_Kind,
    layer:u16,
}

// One draw list. The layers of a frame are drawn in order: the UI of the game
// first, that of the editor over it.
Ui_Layer :: struct {
    vertices:[]Ui_Vertex, // in window points, three per triangle
    draws:   []Ui_Draw,   // nil: every vertex, not clipped
    shapes:  []Ui_Shape,
    effects: []Ui_Effect,
}

// UI placed in the scene. Its vertices are in points of the panel; `pivot` is
// the point that sits at `origin`, and `right` and `down` are the world
// vectors of one point along x and y. Scissors do not apply to it.
World_Panel :: struct {
    vertices:  []Ui_Vertex,
    shapes:    []Ui_Shape,
    origin:    Vec3,
    right,down:Vec3,
    pivot:     Vec2,
    billboard: bool, // turned to face the camera, keeping the lengths of right and down
    depth_test:bool, // hidden where an opaque surface of the scene is in front of it
    view:      u8,   // 0: seen in every view of the window; n: only in its view n-1 (a local player of a split screen)
}

// Copies vertices into the buffer of the frame; what does not fit is dropped
// and counted. Returns where they start and how many whole triangles went in.
@(private)
ui_upload :: proc(r:^Renderer,slot:int,written:^int,vertices:[]Ui_Vertex) -> (base,count:int) {
    source:=rawptr(raw_data(vertices))
    for entry in r.ui_vertex_cache[:r.ui_vertex_cache_count] {if entry.source==source && entry.length==len(vertices) {return entry.base,entry.count}}
    defer if r.ui_vertex_cache_count<len(r.ui_vertex_cache) && len(vertices)>0 {
        r.ui_vertex_cache[r.ui_vertex_cache_count]={source,len(vertices),base,count}
        r.ui_vertex_cache_count+=1
    }
    base=written^
    count=min(len(vertices),r.ui_capacity-base)/3*3
    r.stats.ui_vertices_dropped+=u32(len(vertices)-count)
    if count<=0 {return base,0}
    target:=cast([^]Ui_Vertex)rhi.buffer_mapped(r.device,r.ui_buffers[slot])
    mem.copy(&target[base],raw_data(vertices),count*size_of(Ui_Vertex))
    written^+=count
    return
}

@(private)
ui_shapes_upload :: proc(r:^Renderer,slot:int,shapes:[]Ui_Shape) -> (base,count:int) {
    if len(shapes)==0 {return}
    source:=rawptr(raw_data(shapes))
    for entry in r.ui_shape_cache[:r.ui_shape_cache_count] {if entry.source==source && entry.length==len(shapes) {return entry.base,entry.count}}
    base=r.ui_shape_written
    if r.ui_shape_cache_count==len(r.ui_shape_cache) {r.stats.ui_shapes_dropped+=u32(len(shapes));return base,0}
    count=min(len(shapes),r.ui_shape_capacity-base)
    r.stats.ui_shapes_dropped+=u32(len(shapes)-count)
    if count>0 {
        target:=cast([^]Ui_Shape)rhi.buffer_mapped(r.device,r.ui_shape_buffers[slot])
        mem.copy(&target[base],raw_data(shapes),count*size_of(Ui_Shape))
        r.ui_shape_written+=count
    }
    r.ui_shape_cache[r.ui_shape_cache_count]={source,len(shapes),base,count}
    r.ui_shape_cache_count+=1
    return
}

@(private)
ui_target_begin :: proc(r:^Renderer,cmd:^rhi.Command_List,target:rhi.Texture,clear:bool) {
    pass:=rhi.Render_Pass_Desc{color_count=1,name="UI composition"}
    pass.colors[0]={texture=target,load=.Clear if clear else .Load,store=.Store}
    rhi.cmd_begin_render_pass(cmd,&pass)
}

// Where layers of UI are drawn: an image, with the isolated layers and the
// blur scratch of its size. Of the targets of the window, or of a UI texture.
@(private)
Ui_Surface :: struct {ldr:rhi.Texture,layers,blur:[]rhi.Texture,width,height:u32}

@(private)
ui_surface_of :: proc(t:^Targets) -> Ui_Surface {return {t.ldr,t.ui_layers[:],t.ui_blur[:],t.output_width,t.output_height}}

@(private)
ui_scissor :: proc(r:^Renderer,cmd:^rhi.Command_List,s:Ui_Surface,scissor:[4]f32,scale:f32) -> bool {
    if scissor[2]<0 || scissor[3]<0 {return false}
    if scissor[2]<=0 || scissor[3]<=0 {rhi.cmd_set_scissor(cmd,0,0,s.width,s.height);return true}
    x0:=clamp(math.floor(scissor[0]*scale),0,f32(s.width))
    y0:=clamp(math.floor(scissor[1]*scale),0,f32(s.height))
    x1:=clamp(math.ceil((scissor[0]+scissor[2])*scale),0,f32(s.width))
    y1:=clamp(math.ceil((scissor[1]+scissor[3])*scale),0,f32(s.height))
    if x1<=x0 || y1<=y0 {return false}
    rhi.cmd_set_scissor(cmd,i32(x0),i32(y0),u32(x1-x0),u32(y1-y0))
    return true
}

@(private)
ui_composite :: proc(r:^Renderer,cmd:^rhi.Command_List,s:Ui_Surface,source:rhi.Texture,effect:Ui_Effect,points:Vec2,scissor:[4]f32,scale:f32) {
    if !ui_scissor(r,cmd,s,scissor,scale) {return}
    Params :: struct {bounds,values:Vec4,viewport,pad:Vec2}
    params:=Params{bounds=effect.bounds,values={effect.radius,effect.opacity,0,0},viewport=points}
    rhi.cmd_bind_pipeline(cmd,r.pipelines[.Ui_Composite])
    set_params(cmd,&params)
    rhi.cmd_bind_texture(cmd,SLOT_PASS0,source)
    rhi.cmd_draw(cmd,3)
}

@(private)
ui_backdrop :: proc(r:^Renderer,cmd:^rhi.Command_List,s:Ui_Surface,input:rhi.Texture,blur:f32,scale:f32) -> rhi.Texture {
    source:=input
    for i in 0..<2 {
        pass:=rhi.Render_Pass_Desc{color_count=1,name="UI backdrop blur"}
        pass.colors[0]={texture=s.blur[i],load=.Dont_Care,store=.Store}
        rhi.cmd_begin_render_pass(cmd,&pass)
        rhi.cmd_bind_pipeline(cmd,r.pipelines[.Ui_Blur])
        Params :: struct {direction:Vec2,sigma,pad:f32}
        params:=Params{direction={1/f32(s.width),0} if i==0 else Vec2{0,1/f32(s.height)},sigma=clamp(blur,0.5,64)*scale}
        set_params(cmd,&params)
        rhi.cmd_bind_texture(cmd,SLOT_PASS0,source)
        rhi.cmd_draw(cmd,3)
        rhi.cmd_end_render_pass(cmd)
        source=s.blur[i]
    }
    return source
}

// Records the screen layers into the pass of the LDR target: points span the
// target, and scale is its pixels per point.
@(private)
ui_layers_pass :: proc(r:^Renderer,cmd:^rhi.Command_List,s:Ui_Surface,slot:int,written:^int,layers:[]Ui_Layer,points:Vec2,scale:f32,thumbnails:rhi.Texture) {
    bound:=false
    pipeline:rhi.Pipeline
    for layer in layers {
        if len(layer.vertices)==0 && len(layer.draws)==0 {continue}
        base,count:=ui_upload(r,slot,written,layer.vertices)
        shape_base,shape_count:=ui_shapes_upload(r,slot,layer.shapes)
        params:=Ui_Params{viewport=points,shape_base=u32(shape_base),shape_count=u32(shape_count)}
        depth,skipped:=0,0
        Stack :: struct {effect:u16,scissor:[4]f32}
        stack:[UI_LAYER_DEPTH_CAPACITY]Stack
        if layer.draws==nil {
            if count<3 {continue}
            rhi.cmd_set_scissor(cmd,0,0,s.width,s.height)
            rhi.cmd_bind_pipeline(cmd,r.pipelines[.Ui])
            set_params(cmd,&params)
            rhi.cmd_bind_buffer(cmd,SLOT_PASS0,r.ui_buffers[slot])
            rhi.cmd_bind_buffer(cmd,SLOT_PASS4,r.ui_shape_buffers[slot])
            rhi.cmd_bind_texture(cmd,SLOT_PASS1,r.font)
            rhi.cmd_bind_texture(cmd,SLOT_PASS2,thumbnails)
            // The depth of the scene and the views of its pixels, which only a panel in the world reads.
            rhi.cmd_bind_texture(cmd,SLOT_PASS3,r.font)
            rhi.cmd_bind_texture(cmd,SLOT_VIEWS,r.dummy_texture)
            rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
            pipeline=r.pipelines[.Ui]
            ui_programs_draw(r,cmd,&r.pipelines[.Ui],layer.vertices,base,0,count,&pipeline)
            bound=false
            continue
        }
        for draw in layer.draws {
            switch draw.kind {
            case .Begin_Layer:
                if skipped>0 {skipped+=1;continue}
                valid:=int(draw.layer)<len(layer.effects) && depth<r.ui_layer_depth && s.layers[depth]!=0
                effect:Ui_Effect
                if valid {
                    effect=layer.effects[draw.layer]
                    for value in effect.bounds {valid=valid && !math.is_nan(value) && !math.is_inf(value)}
                    valid=valid && effect.bounds[2]>0 && effect.bounds[3]>0 && effect.radius>=0 && effect.opacity>=0 && effect.opacity<=1 && effect.backdrop_blur>=0 && effect.backdrop_blur<=64
                }
                if !valid {r.stats.ui_layers_dropped+=1;skipped=1;continue}
                parent:=s.ldr if depth==0 else s.layers[depth-1]
                rhi.cmd_end_render_pass(cmd)
                backdrop:rhi.Texture
                if effect.backdrop_blur>0 {backdrop=ui_backdrop(r,cmd,s,parent,effect.backdrop_blur,scale)}
                ui_target_begin(r,cmd,s.layers[depth],true)
                if backdrop!=0 {
                    background:=Ui_Effect{bounds={0,0,points.x,points.y},opacity=1}
                    ui_composite(r,cmd,s,backdrop,background,points,{},scale)
                }
                stack[depth]={draw.layer,draw.scissor}
                depth+=1
                bound=false
            case .End_Layer:
                if skipped>0 {skipped-=1;continue}
                if depth==0 || stack[depth-1].effect!=draw.layer {r.stats.ui_layers_dropped+=1;continue}
                depth-=1
                source:=s.layers[depth]
                parent:=s.ldr if depth==0 else s.layers[depth-1]
                rhi.cmd_end_render_pass(cmd)
                ui_target_begin(r,cmd,parent,false)
                ui_composite(r,cmd,s,source,layer.effects[draw.layer],points,stack[depth].scissor,scale)
                bound=false
            case .Triangles:
                if skipped>0 {continue}
                first:=int(draw.first)
                vertices:=min(int(draw.count),count-first)/3*3
                if first>=count || vertices<3 || !ui_scissor(r,cmd,s,draw.scissor,scale) {continue}
                if !bound {
                    rhi.cmd_bind_pipeline(cmd,r.pipelines[.Ui])
                    pipeline=r.pipelines[.Ui]
                    rhi.cmd_bind_buffer(cmd,SLOT_PASS0,r.ui_buffers[slot])
                    rhi.cmd_bind_buffer(cmd,SLOT_PASS4,r.ui_shape_buffers[slot])
                    rhi.cmd_bind_texture(cmd,SLOT_PASS1,r.font)
                    rhi.cmd_bind_texture(cmd,SLOT_PASS2,thumbnails)
                    rhi.cmd_bind_texture(cmd,SLOT_PASS3,r.font)
                    rhi.cmd_bind_texture(cmd,SLOT_VIEWS,r.dummy_texture)
                    rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
                    bound=true
                }
                set_params(cmd,&params)
                ui_programs_draw(r,cmd,&r.pipelines[.Ui],layer.vertices,base,first,vertices,&pipeline)
            }
        }
        // Invalid external lists must not leave the frame in an intermediate target.
        for depth>0 {
            depth-=1
            r.stats.ui_layers_dropped+=1
            rhi.cmd_end_render_pass(cmd)
            ui_target_begin(r,cmd,s.ldr if depth==0 else s.layers[depth-1],false)
            bound=false
        }
    }
    rhi.cmd_set_scissor(cmd,0,0,s.width,s.height)
}

// Records the panels of the scene into the pass of the LDR target. They are
// projected without the jitter of the scene and tested against its depth in
// the shader (overlay.slang).
@(private)
world_panels_pass :: proc(r:^Renderer,cmd:^rhi.Command_List,t:^Targets,slot:int,written:^int,panels:[]World_Panel,view:Mat4,thumbnails:rhi.Texture,index:int) {
    bound:=false
    pipeline:rhi.Pipeline
    camera_right:=Vec3{view[0,0],view[0,1],view[0,2]}
    camera_up:=Vec3{view[1,0],view[1,1],view[1,2]}
    for panel in panels {
        if panel.view!=0 && int(panel.view)-1!=index {continue}
        base,count:=ui_upload(r,slot,written,panel.vertices)
        if count<3 {continue}
        shape_base,shape_count:=ui_shapes_upload(r,slot,panel.shapes)
        if !bound {
            rhi.cmd_bind_pipeline(cmd,r.pipelines[.Ui_World])
            pipeline=r.pipelines[.Ui_World]
            rhi.cmd_bind_buffer(cmd,SLOT_PASS0,r.ui_buffers[slot])
            rhi.cmd_bind_buffer(cmd,SLOT_PASS4,r.ui_shape_buffers[slot])
            rhi.cmd_bind_texture(cmd,SLOT_PASS1,r.font)
            rhi.cmd_bind_texture(cmd,SLOT_PASS2,thumbnails)
            rhi.cmd_bind_texture(cmd,SLOT_PASS5,r.display_lut)
            rhi.cmd_bind_texture(cmd,SLOT_PASS3,t.linear_depth)
            rhi.cmd_bind_texture(cmd,SLOT_VIEWS,t.motion)
            bound=true
        }
        right,down:=panel.right,panel.down
        if panel.billboard {
            right=camera_right*linalg.length(panel.right)
            down=-camera_up*linalg.length(panel.down)
        }
        place:=origin_point(panel.origin,r.origin)
        params:=Ui_Params{
            viewport={f32(t.output_width),f32(t.output_height)},shape_base=u32(shape_base),shape_count=u32(shape_count),
            origin={place.x,place.y,place.z,1 if panel.depth_test else 0},
            right={right.x,right.y,right.z,panel.pivot.x},
            down={down.x,down.y,down.z,panel.pivot.y},
        }
        set_params(cmd,&params)
        ui_programs_draw(r,cmd,&r.pipelines[.Ui_World],panel.vertices,base,0,count,&pipeline)
    }
}
