package render

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"

// What a plugin extends the renderer with. Its runtime imports neither the
// renderer nor the RHI: all it does to a frame is here.
//
// In its render step of each frame it asks for the pipelines of its stages
// (stage_pipeline) and for its passes (frame_pass). The procedure of a pass
// records it with the pass_ procedures, through the Pass it is given. The
// renderer keeps the pipelines, the textures of each view a pass asks for
// (pass_texture) and the buffers of each world (pass_buffer), and the rows of
// a pass go in the memory of the frame (pass_upload, pass_rows_upload): a
// plugin owns nothing of the GPU. It lets go of the buffers of a world when
// the world goes (buffer_release).

Renderer :: gpu.Renderer // what a step or a function that reaches the renderer receives: nil without a GPU
Stage :: gpu.Frame_Stage
Stage_Proc :: gpu.Stage_Proc
Pass :: gpu.Stage_Pass
Pipeline :: rhi.Pipeline
Stage_Pipeline_Desc :: gpu.Stage_Pipeline_Desc
Pass_Texture_Desc :: gpu.Pass_Texture_Desc
EXTENSION_TEXTURE_CAPACITY :: gpu.EXTENSION_TEXTURE_CAPACITY
Buffer_Desc :: gpu.Extension_Buffer_Desc
EXTENSION_BUFFER_CAPACITY :: gpu.EXTENSION_BUFFER_CAPACITY
Pass_Rows :: gpu.Pass_Rows
Pass_Indices :: gpu.Pass_Indices
Glass_Side :: gpu.Glass_Side
Surface_Source :: gpu.Surface_Source
Blend_Mode :: rhi.Blend_Mode
Program :: gpu.Program
Program_Domain :: gpu.Program_Domain
Program_Resource :: gpu.Program_Resource
Program_Resource_Kind :: gpu.Program_Resource_Kind
PROGRAM_RESOURCES :: gpu.PROGRAM_RESOURCES
Program_Stage :: gpu.Program_Stage
PROGRAM_STAGES :: gpu.PROGRAM_STAGES
PROGRAM_STAGE_PARTICLES :: gpu.PROGRAM_STAGE_PARTICLES
PROGRAM_PARAMETER_BYTES :: gpu.PROGRAM_PARAMETER_BYTES
PARTICLE_ATTRIBUTE_BYTES :: gpu.PARTICLE_ATTRIBUTE_BYTES
Nested_View :: gpu.Nested_View
NESTED_VIEW_CAPACITY :: gpu.NESTED_VIEW_CAPACITY
Mesh_Handle :: gpu.Mesh_Handle
Texture_Handle :: gpu.Texture_Handle
Material_Handle :: gpu.Material_Handle
Instance_Desc :: gpu.Instance_Desc
Gpu_Timing :: rhi.Gpu_Timing
Gpu_Backend :: rhi.Backend
Light_Desc :: gpu.Light_Desc
LIGHT_POINT :: gpu.GPU_LIGHT_POINT
LIGHT_RECT :: gpu.GPU_LIGHT_RECT

Render_Pipeline :: gpu.Render_Pipeline_Handle
Render_Pipeline_Desc :: gpu.Render_Pipeline_Desc
Render_Pass_Desc :: gpu.Render_Pass_Desc
Render_Stage :: gpu.Render_Stage
Render_Resource :: gpu.Render_Resource
Render_Resource_Desc :: gpu.Render_Resource_Desc
Render_Use :: gpu.Render_Use
Render_Access :: gpu.Render_Access
Render_Size :: gpu.Render_Size
Render_Jitter :: gpu.Render_Jitter
RENDER_MIPS_ALL :: gpu.RENDER_MIPS_ALL
CUSTOM_PASS_SLOTS :: gpu.CUSTOM_PASS_SLOTS
Pass_Camera :: gpu.Camera // what Pass.camera holds: the camera of the view a pass is for
Direct_Mode :: gpu.Direct_Mode
Standard_Pipeline :: gpu.Standard_Pipeline
Format :: rhi.Format

// The pipeline of a description, which a view is drawn with: the stages of
// the renderer and passes of the plugin's own, in order. The renderer compiles
// it the first time it is asked for and keeps it while some frame asks for it:
// ask in each frame that uses it. 0 and the reason when it is wrong.
pipeline :: proc(renderer:^Renderer,desc:Render_Pipeline_Desc) -> (Render_Pipeline,string) {
    if renderer==nil {return 0,"render pipeline: there is no renderer"}
    return gpu.renderer_pipeline(renderer,desc)
}

// The passes of a standard pipeline, to build one of a plugin's own from.
standard_pipeline_passes :: gpu.standard_pipeline_passes

// One of the pipelines the renderer always has.
pipeline_standard :: proc(renderer:^Renderer,kind:Standard_Pipeline) -> Render_Pipeline {
    return renderer!=nil?gpu.renderer_standard_pipeline(renderer,kind):0
}

// The pipeline of the views of the window in the next frame. False for a
// pipeline the renderer does not have.
pipeline_main :: proc(renderer:^Renderer,pipeline:Render_Pipeline) -> bool {
    return renderer!=nil && gpu.renderer_main_pipeline(renderer,pipeline)
}

// Places of the world for the GPU of a pass, relative to its origin
// (Pass.origin), in f64: a point, a plane or a row of a transform out of the
// world, the rows of one out of it or into it, a matrix into it, a rigid
// transform of the world into itself, and the lowest corner of a cell of a
// grid of the world. What a shader makes of a place of the world itself (a
// wave, a pattern) takes what the origin adds from origin.slang.
ORIGIN_STEP :: gpu.ORIGIN_STEP
origin_point :: gpu.origin_point
origin_plane :: gpu.origin_plane
origin_from_world :: gpu.origin_from_world
origin_to_world :: gpu.origin_to_world
origin_matrix :: gpu.origin_matrix
origin_transform :: gpu.origin_transform
origin_cell :: gpu.origin_cell

// A plane through a place of the world, or a row of a transform out of the
// world whose zero is that place (a box, a face): what the origin adds is
// found again from where the place is from the origin, so far from the centre
// of the world it keeps what the f32 of the row lost.
origin_plane_through :: proc "contextless" (plane:[4]f32,place,origin:[3]f32) -> [4]f32 {
    at:=origin_point(place,origin)
    return {plane.x,plane.y,plane.z,-(plane.x*at.x+plane.y*at.y+plane.z*at.z)}
}

// The rows of a transform out of the world whose zero is place, as origin_plane_through.
origin_from_place :: proc "contextless" (rows:[3][4]f32,place,origin:[3]f32) -> (moved:[3][4]f32) {
    for row,i in rows {moved[i]=origin_plane_through(row,place,origin)}
    return
}

pass_resource :: gpu.pass_resource
pass_constants :: gpu.pass_constants
pass_clear :: gpu.pass_clear
pass_resource_write :: gpu.pass_resource_write

Antialiasing_Desc :: gpu.Antialiasing_Desc
ANTIALIASING_NAME_BYTES :: gpu.ANTIALIASING_NAME_BYTES
ANTIALIASING_OFF :: gpu.ANTIALIASING_OFF
ANTIALIASING_TAA :: gpu.ANTIALIASING_TAA

// Offers a technique of antialiasing for the next frame, a choice of
// Graphics_Settings.antialiasing: a plugin offers it in every frame it can
// resolve it, and draws the views of the window with a pipeline whose pass
// stands in place of the Resolve stage while the setting names it. False
// without room, or for a name the renderer has or another plugin offered.
antialiasing_offer :: proc(renderer:^Renderer,name,label:string) -> bool {
    return renderer!=nil && gpu.antialiasing_offer(renderer,name,label)
}

// The techniques plugins offered for the last frame, besides Off and TAA.
antialiasing_offered :: proc(renderer:^Renderer) -> []Antialiasing_Desc {
    return renderer!=nil?gpu.renderer_antialiasing(renderer):nil
}

// Asks the next frame to call `record` at a stage: every view for Mask,
// Surface and Lit, once for Geometry. False without room for another pass, and for
// Inspect: the pass of a mode of inspection goes in the view that shows it,
// which the editor names (editor.view_mode_declare).
frame_pass :: proc(renderer:^Renderer,stage:Stage,record:Stage_Proc,user:rawptr=nil) -> bool {
    return renderer!=nil && gpu.frame_pass(renderer,stage,record,user)
}

// The pipeline of a stage, from the shaders in use; the renderer keeps it. 0
// while those shaders do not have its stages: ask again in each frame.
stage_pipeline :: proc(renderer:^Renderer,desc:Stage_Pipeline_Desc) -> Pipeline {
    return renderer!=nil?gpu.stage_pipeline(renderer,desc):0
}

pass_extension_data :: gpu.pass_extension_data
pass_nested_add :: gpu.pass_nested_add
pass_mask_begin :: gpu.pass_mask_begin
pass_surface_begin :: gpu.pass_surface_begin
pass_surface_read :: gpu.pass_surface_read
pass_image_bind :: gpu.pass_image_bind
pass_image_write :: gpu.pass_image_write
pass_texture :: gpu.pass_texture
pass_texture_sample :: gpu.pass_texture_sample
pass_vertices_begin :: gpu.pass_vertices_begin
pass_deformable :: gpu.pass_deformable
pass_end :: gpu.pass_end
pass_pipeline :: gpu.pass_pipeline
pass_params :: gpu.pass_params
pass_upload :: gpu.pass_upload
pass_scissor :: gpu.pass_scissor
pass_draw :: gpu.pass_draw
pass_dispatch :: gpu.pass_dispatch
pass_timestamp :: gpu.pass_timestamp
pass_buffer :: gpu.pass_buffer
Pass_Lights :: gpu.Pass_Lights
Pass_Light_Part :: gpu.Pass_Light_Part
Table_Texture_Desc :: gpu.Table_Texture_Desc
EXTENSION_TABLE_TEXTURE_CAPACITY :: gpu.EXTENSION_TABLE_TEXTURE_CAPACITY
pass_table_texture_copy :: gpu.pass_table_texture_copy
LIGHTS_ASKED_MAX :: gpu.LIGHT_REGION_MAX
pass_lights :: gpu.pass_lights
pass_buffer_ready :: gpu.pass_buffer_ready
pass_buffer_write :: gpu.pass_buffer_write
pass_buffer_fill :: gpu.pass_buffer_fill
pass_dispatch_indirect :: gpu.pass_dispatch_indirect
pass_draw_indexed_indirect :: gpu.pass_draw_indexed_indirect
pass_draw_indirect :: gpu.pass_draw_indirect
pass_indices :: gpu.pass_indices
pass_rows_upload :: gpu.pass_rows_upload
pass_rows :: gpu.pass_rows
pass_counters :: gpu.pass_counters
pass_readback :: gpu.pass_readback
pass_gbuffer_begin :: gpu.pass_gbuffer_begin
// The next frame draws a mesh with a material (0: those of the mesh) in its
// Gbuffer stage: each view keeps what they reflect and their layers.
frame_gbuffer_mesh :: proc(renderer:^Renderer,mesh:Mesh_Handle,material:Material_Handle) {
    if renderer!=nil {gpu.frame_gbuffer_mesh(renderer,mesh,material)}
}
// Tells the frame that the plugin draws every cluster of level 0 of a mesh
// (the meshes of particles): a mesh that streams loads its pages and keeps
// them. Ask in each frame that draws it.
frame_mesh_whole :: proc(renderer:^Renderer,mesh:Mesh_Handle) {
    if renderer!=nil {gpu.frame_mesh_whole(renderer,mesh)}
}
pass_gbuffer_pipeline :: gpu.pass_gbuffer_pipeline
pass_material_program :: gpu.pass_material_program
pass_stage_pipeline :: gpu.pass_stage_pipeline
pass_mesh_programs :: gpu.pass_mesh_programs
pass_blend_begin :: gpu.pass_blend_begin

// Lets go of a buffer of the plugin in a world (pass_buffer): the world goes,
// or will not be drawn again. False when the renderer had none of that name.
buffer_release :: proc(renderer:^Renderer,world:core.World_Id,name:string) -> bool {
    return renderer!=nil && gpu.buffer_release(renderer,world_key(world),name)
}

// A texture of the table of the plugin in a world (world_key) that its passes
// write (pass_table_texture) and materials read by index; made the first
// time and with another size, a load transaction between frames.
table_texture :: proc(renderer:^Renderer,world:u64,desc:Table_Texture_Desc) -> (index:u32,made,ok:bool) {
    if renderer==nil {return}
    return gpu.table_texture(renderer,world,desc)
}

// Releases the table texture of the plugin in a world (pass_table_texture),
// in the release of the world or when it is no longer drawn.
table_texture_release :: proc(renderer:^Renderer,world:core.World_Id,name:string) -> bool {
    return renderer!=nil && gpu.table_texture_release(renderer,world_key(world),name)
}

// What a readback of the plugin in a world (pass_readback) brought back
// last, and the frame it is of; none until a frame that copied it is done.
// Valid until the next frame.
readback :: proc(renderer:^Renderer,world:core.World_Id,name:string) -> (data:[]u8,frame:u64,ok:bool) {
    if renderer==nil {return}
    return gpu.readback(renderer,world_key(world),name)
}

readback_release :: proc(renderer:^Renderer,world:core.World_Id,name:string) -> bool {
    return renderer!=nil && gpu.readback_release(renderer,world_key(world),name)
}

// The counters a pass bound under a name (pass_counters), as the frame two
// frames ago left them. False while no pass bound them.
counters :: proc(renderer:^Renderer,name:string) -> (values:[4]u32,ok:bool) {
    if renderer==nil {return}
    return gpu.renderer_counters(renderer,name)
}

// Bytes a buffer of a pass may span at most on this device.
max_storage_range :: proc(app:^host.App) -> u64 {return app.device!=nil?rhi.device_info(app.device).max_storage_range:0}

// How many vertices a draw (pass_draw_indirect) gives the clusters of level 0
// of a mesh: CLUSTER_DRAW_VERTICES a cluster, which a vertex shader reads
// with geometry.slang. False for a mesh the renderer does not have.
mesh_draw_range :: proc(renderer:^Renderer,mesh:Mesh_Handle) -> (vertex_count:u32,ok:bool) {
    if renderer==nil {return}
    return gpu.mesh_draw_range(renderer,mesh)
}

// A program of a domain in the shaders in use, by name; nil without it.
program_find :: proc(a:^host.Assets,name:string,domain:Program_Domain) -> ^Program {
    if a==nil || a.renderer==nil {return nil}
    return gpu.program_find(a.renderer,name,domain)
}

program_defaults :: gpu.program_defaults
program_parameter :: gpu.program_parameter

// Where a quad of the world is in the view of a pass: the pixels its corners
// enclose, as x, y, width, height, or none (zero) when some corner is behind
// the eye and some is not: it may be anywhere. False when none of it is inside.
pass_quad_rect :: proc(pass:^Pass,corners:[4][3]f32) -> (rect:[4]i32,visible:bool) {
    low,high:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
    behind:=0
    for corner in corners {
        at:=origin_point(corner,pass.origin)-pass.camera.position
        clip:=pass.view_projection*[4]f32{at.x,at.y,at.z,1}
        if clip.w<=1e-3 {behind+=1;continue}
        ndc:=clip.xy/clip.w
        low,high=linalg.min(low,ndc),linalg.max(high,ndc)
    }
    if behind==len(corners) {return {},false}
    if behind>0 {return {},true}
    if high.x<-1 || low.x>1 || high.y<-1 || low.y>1 {return {},false}
    width,height:=f32(pass.width),f32(pass.height)
    // The jitter of the view moves it by up to a pixel.
    x0,x1:=clamp((low.x*0.5+0.5)*width-2,0,width),clamp((high.x*0.5+0.5)*width+2,0,width)
    y0,y1:=clamp((0.5-high.y*0.5)*height-2,0,height),clamp((0.5-low.y*0.5)*height+2,0,height)
    rect={i32(x0),i32(y0),i32(math.ceil(x1))-i32(x0),i32(math.ceil(y1))-i32(y0)}
    return rect,rect.z>0 && rect.w>0
}

// A face a view looks into through a nested view (a mirror, the opening of a
// portal): the item it is of, its nested view and the pixels it covers.
Nested_Face :: struct {item:int,index:u32,rect:[4]i32}

// The faces of items the view of a pass looks into from their front, the
// nearest first, each with its nested view, as many as the view has room
// for. face gives the plane of an item relative to the origin of the pass,
// its corners in the world and the view it opens. The masks that give them
// their pixels are of the plugin.
pass_nested_faces :: proc(pass:^Pass,items:[]$T,face:proc(item:^T,origin:[3]f32) -> (plane:[4]f32,corners:[4][3]f32,view:Nested_View),faces:^[NESTED_VIEW_CAPACITY]Nested_Face) -> []Nested_Face {
    count:=nested_faces_nearest(pass,items,face,faces)
    for &f,i in faces[:count] {
        _,_,view:=face(&items[f.item],pass.origin)
        view.rect=f.rect
        if f.index=pass_nested_add(pass,view);f.index==0 {return faces[:i]}
    }
    return faces[:count]
}

// The faces of items in front of the eye of a pass and inside its view, the
// nearest first: from the eye to their middle, or along it for an orthographic one.
@(private)
nested_faces_nearest :: proc(pass:^Pass,items:[]$T,face:proc(item:^T,origin:[3]f32) -> (plane:[4]f32,corners:[4][3]f32,view:Nested_View),faces:^[NESTED_VIEW_CAPACITY]Nested_Face) -> (count:int) {
    distances:[NESTED_VIEW_CAPACITY]f32
    eye:=pass.eye
    for &item,at in items {
        plane,corners,_:=face(&item,pass.origin)
        height:=linalg.dot(plane.xyz,eye.xyz)+plane.w*eye.w
        if height<=0 {continue}
        rect,visible:=pass_quad_rect(pass,corners)
        if !visible {continue}
        center:=origin_point(0.25*(corners[0]+corners[1]+corners[2]+corners[3]),pass.origin)
        distance:=eye.w>0.5?linalg.length(center-eye.xyz):height
        place:=count
        for place>0 && distances[place-1]>distance {place-=1}
        if place>=len(faces) {continue}
        count=min(count+1,len(faces))
        for i:=count-1;i>place;i-=1 {faces[i],distances[i]=faces[i-1],distances[i-1]}
        faces[place],distances[place]=Nested_Face{item=at,rect=rect},distance
    }
    return
}

// The angular radius of the sun, radians, which gives its shadows their penumbra.
sun_radius :: proc(renderer:^Renderer) -> f32 {
    if renderer==nil {return 0}
    return renderer.settings.sun_radius
}

// The mesh an instance of the renderer shows and where it draws it, a
// transform into the world, by its index (instance_object). False for an
// index the renderer does not have.
instance_placed :: proc(renderer:^Renderer,index:int) -> (mesh:Mesh_Handle,transform:matrix[4,4]f32,ok:bool) {
    if renderer==nil || index<0 {return}
    return gpu.scene_instance_placed(renderer,u32(index))
}
// How wet an instance of the renderer is, by its index (instance_object): 0 dry to 1
// soaked. Every material darkens and smooths by it what is not metal, glass
// or unlit, and a program reads it in Mirai_Surface_Context.wet. It stays
// while the instance keeps its identity and changes neither its light nor
// its rays; one plugin gives it (water). False for an index the renderer does
// not have or a value that is not finite.
instance_wet_set :: proc(renderer:^Renderer,index:int,wet:f32) -> bool {
    return renderer!=nil && index>=0 && gpu.scene_set_instance_wet(renderer,u32(index),wet)
}
// A visual instance for this frame, without an entity of its own in the renderer.
instance_add :: proc(extras:^host.Frame_Extras,instance:Instance_Desc) -> bool {return host.extras_instance_add(extras,instance)}

// The box of a mesh, in its own space.
mesh_bounds :: proc(renderer:^Renderer,mesh:Mesh_Handle) -> (bounds_min,bounds_max:[3]f32,ok:bool) {
    if renderer==nil {return}
    return gpu.mesh_bounds(renderer,mesh)
}

mesh_remove :: proc(renderer:^Renderer,mesh:Mesh_Handle) -> bool {
    return renderer!=nil && gpu.mesh_remove(renderer,mesh)
}

// Whether a mesh is not drawn yet because its geometry still goes to the GPU
// over frames: a large pose of skin_create, or a mesh a load took.
mesh_uploading :: proc(renderer:^Renderer,mesh:Mesh_Handle) -> bool {
    return renderer!=nil && gpu.mesh_uploading(renderer,mesh)
}

// A copy of a mesh whose vertices the plugin writes in its Geometry stage, in
// each frame it asked deformable_update for. levels: it keeps the levels of
// detail of the mesh, whose vertices the plugin writes too (pass_deformable
// counts them); rays meet the first. A load transaction.
deformable_create :: proc(renderer:^Renderer,source:Mesh_Handle,levels:=false) -> (Mesh_Handle,bool) {
    if renderer==nil {return 0,false}
    return gpu.deformable_create(renderer,source,levels)
}

// Says that the next frame writes the vertices of a deformable, and the box
// they stay in, in the space of the mesh.
deformable_update :: proc(renderer:^Renderer,mesh:Mesh_Handle,bounds_min,bounds_max:[3]f32) -> bool {
    return renderer!=nil && gpu.deformable_update(renderer,mesh,bounds_min,bounds_max)
}

Skin_Influence :: gpu.Skin_Influence
Morph_Data :: gpu.Morph_Data
Morph_Range :: gpu.Morph_Range
Morph_Delta :: gpu.Morph_Delta
Skin_Part_Pose :: gpu.Skin_Part_Pose

// A copy of a skinned mesh, posed on its own, that the renderer deforms by
// joints on the GPU: the influences of its vertices name joints of the
// palettes skin_update gives it. Influences for the vertices of level 0 pose
// that level; for every vertex of the mesh, every level. morph: the targets
// of those vertices, which move them before the joints do. part: it has a
// part that a view which does not draw its layers draws collapsed
// (Skin_Part_Pose). A load transaction; mesh_remove frees it. One larger than
// what a frame uploads goes over frames: an instance of it, and the mesh it
// replaces (Instance_Desc.replace_source), are drawn once all of it went
// (mesh_uploading).
skin_create :: proc(renderer:^Renderer,source:Mesh_Handle,influences:[]Skin_Influence,joint_count:u32,morph:Morph_Data={},part:=false) -> (Mesh_Handle,bool) {
    if renderer==nil {return 0,false}
    return gpu.skin_create(renderer,source,influences,joint_count,morph,part)
}

// The palette the next frame deforms a skin with: by joint, from the bind
// pose to the space of the mesh, and the weights of its morph targets (none:
// those it had). reset_motion: no motion since the frame before is drawn, as
// after a cut. part: the palette that collapses its part and its layers.
// Unchanged ones cost nothing.
skin_update :: proc(renderer:^Renderer,mesh:Mesh_Handle,palette:[]matrix[4,4]f32,reset_motion:=false,morph_weights:[]f32=nil,part:Skin_Part_Pose={}) -> bool {
    return renderer!=nil && gpu.skin_update(renderer,mesh,palette,reset_motion,morph_weights,part)
}

// The palette of a skin for the next frame and the one of the frame before,
// as rows of 3x4 matrices by joint, into current and previous as many as fit;
// count: its joints. False for a mesh without a skin of joints.
skin_palette :: proc(renderer:^Renderer,mesh:Mesh_Handle,current,previous:[][3][4]f32) -> (count:int,ok:bool) {
    if renderer==nil {return}
    return gpu.skin_palette(renderer,mesh,current,previous)
}

Batch_Handle :: gpu.Batch_Handle
Batch_Desc :: gpu.Batch_Desc
Batch_Instance :: gpu.Batch_Instance
Batch_Flag :: gpu.Batch_Flag
Batch_Flags :: gpu.Batch_Flags
BATCH_INDICES_MAX :: gpu.BATCH_INDICES_MAX
batch_instance :: gpu.batch_instance
batch_instance_unpack :: gpu.batch_instance_unpack

// The key the renderer knows a world by (gpu.scene_world): the frames draw
// the batches of the world shown.
world_key :: proc "contextless" (id:core.World_Id) -> u64 {return u64(id.generation)<<32|u64(id.index)}

// Gives a batch of the world `world` its mesh, materials, how it is drawn and
// traced, and its instances (Batch_Instance, 20 bytes each): a new one for
// handle 0, or the one handle names, which keeps it. A load transaction; the
// error says what is wrong and how to fix it, and changes nothing. A batch
// stays until batch_remove, or until the renderer forgets every batch
// (batches_epoch).
batch_set :: proc(renderer:^Renderer,world:core.World_Id,handle:Batch_Handle,desc:Batch_Desc,instances:[]Batch_Instance) -> (Batch_Handle,string) {
    if renderer==nil {return handle,"batch_set: there is no renderer"}
    return gpu.batch_set(renderer,handle,world_key(world),desc,instances)
}

// False for a handle that names no batch.
batch_remove :: proc(renderer:^Renderer,handle:Batch_Handle) -> bool {
    return renderer!=nil && gpu.batch_remove(renderer,handle)
}

// Changes when the renderer forgets every batch, along with every mesh (a
// scene loaded again): those who keep batches set them again.
batches_epoch :: proc(renderer:^Renderer) -> u64 {return renderer!=nil?gpu.batches_epoch(renderer):0}

Batch_Info :: gpu.Batch_Info
Batch_Hit :: gpu.Batch_Hit

// Changes when a batch comes, goes or is set again: what an extension that
// goes through the batches compares to know when to go through them again.
batches_revision :: proc(renderer:^Renderer) -> u64 {return renderer!=nil?gpu.batches_revision(renderer):0}

// The records of the batches, to go through them with batch_info.
batch_records :: proc(renderer:^Renderer) -> int {return renderer!=nil?gpu.batch_records(renderer):0}

// The batch of a record: its handle, world, object id, mesh and
// instances. False for a record that holds none.
batch_info :: proc(renderer:^Renderer,index:int) -> (info:Batch_Info,ok:bool) {
    if renderer==nil {return}
    return gpu.batch_info(renderer,index)
}

// The instance of a batch of a world a ray of the world meets first within
// max_distance, on the triangles of its mesh at rest.
batch_ray :: proc(renderer:^Renderer,world:core.World_Id,origin,direction:[3]f32,max_distance:f32) -> (hit:Batch_Hit,found:bool) {
    if renderer==nil {return}
    return gpu.batch_ray(renderer,world_key(world),origin,direction,max_distance)
}

// The mesh and materials of a batch from what a Mesh_Renderer shows, as an
// entity with it would be drawn. False while its mesh is not loaded.
batch_desc :: proc(a:^host.Assets,static:Mesh_Renderer) -> (desc:Batch_Desc,ok:bool) {
    instance:=mesh_instance(a,static,1) or_return
    return {mesh=instance.mesh,material=instance.material,slot_materials=instance.slot_materials,tint=instance.tint},true
}

Impostor_Part :: gpu.Impostor_Part
Impostor_Images :: gpu.Impostor_Images
IMPOSTOR_GRID_MAX :: gpu.IMPOSTOR_GRID_MAX
IMPOSTOR_SIDE_MAX :: gpu.IMPOSTOR_SIDE_MAX
impostor_direction :: gpu.impostor_direction
impostor_fold :: gpu.impostor_fold
impostor_unfold :: gpu.impostor_unfold
impostor_axes :: gpu.impostor_axes
impostor_images_destroy :: gpu.impostor_images_destroy
impostor_dilate :: gpu.impostor_dilate

// The frames of an octahedral impostor of some meshes (gpu.impostor_capture),
// read back: a blocking transaction between frames. impostor_dilate fills
// what they do not cover, anywhere, as a job does.
impostor_capture :: proc(renderer:^Renderer,parts:[]Impostor_Part,grid,frame:u32,allocator:=context.allocator) -> (images:Impostor_Images,ok:bool) {
    if renderer==nil {return}
    return gpu.impostor_capture(renderer,parts,grid,frame,allocator)
}

// The triangles of the first level of a mesh, in its space, appended:
// positions, and three indices into them a triangle. False for a mesh the
// renderer does not have.
mesh_triangles :: proc(renderer:^Renderer,mesh:Mesh_Handle,positions:^[dynamic][3]f32,indices:^[dynamic]u32) -> bool {
    return renderer!=nil && gpu.mesh_triangles(renderer,mesh,positions,indices)
}

Texture_Desc :: gpu.Texture_Desc
Texture_Data :: gpu.Texture_Data
texture_data_destroy :: gpu.texture_data_destroy

// The levels texture_add would give an image, built apart from the renderer,
// as a job does: max_size is texture_max_size, read before on the main thread.
texture_build :: gpu.texture_build

// The side of the first level of the textures the renderer takes now.
texture_max_size :: proc(renderer:^Renderer) -> int {return renderer!=nil?gpu.texture_limits(renderer).max_size:0}

// Gives the renderer the levels texture_build built: the second half of
// texture_add. A load transaction; texture_remove frees it.
texture_add_built :: proc(renderer:^Renderer,data:Texture_Data,name:string) -> (Texture_Handle,bool) {
    if renderer==nil {return 0,false}
    return gpu.texture_add_data(renderer,data,name)
}

// An image of the texture table from RGBA8 pixels, with its levels: what
// shaders read at texture_index. A load transaction; texture_remove frees it.
texture_add :: proc(renderer:^Renderer,desc:Texture_Desc) -> (Texture_Handle,bool) {
    if renderer==nil {return 0,false}
    return gpu.texture_add(renderer,desc)
}

texture_remove :: proc(renderer:^Renderer,texture:Texture_Handle) -> bool {
    return renderer!=nil && gpu.texture_remove(renderer,texture)
}

// Where shaders read a texture of the table (material_textures of scene.slang).
texture_index :: proc "contextless" (texture:Texture_Handle) -> u32 {return u32(gpu.TEXTURE_RESERVED)+u32(texture)-1 if texture!=0 else max(u32)}

// How many times the vertices of the scene were made again: what was written
// in a deformable before is gone, and it is to be written again.
vertices_made :: proc(renderer:^Renderer) -> u64 {return renderer!=nil?gpu.vertices_made(renderer):0}

// Room for lights that a pass writes in the Simulate stage (pass_lights),
// which light the scene as its lights do: count that cast shadows within
// its budgets, and shadowless that light whatever stands in their way and
// trace no rays. From the next frame, up to LIGHTS_ASKED_MAX of each. Ask in
// each frame that uses it.
lights_ask :: proc(renderer:^Renderer,count,shadowless:u32) {if renderer!=nil {gpu.lights_ask(renderer,count,shadowless)}}

// An entry of the texture table for what a camera sees, which a material
// shows as any other color texture. Black until view_texture_draw draws it.
// A load transaction between frames.
view_texture_add :: proc(renderer:^Renderer,width,height:u32,name:string) -> (Texture_Handle,bool) {
    if renderer==nil {return 0,false}
    return gpu.view_texture_add(renderer,width,height,name)
}

view_texture_remove :: proc(renderer:^Renderer,texture:Texture_Handle) -> bool {
    return renderer!=nil && gpu.view_texture_remove(renderer,texture)
}

// An entry of the texture table that frames draw UI into
// (host.extras_ui_texture_draw), or with effects what extensions draw at the
// Effect stage (host.extras_effect_view_add); a material or the UI shows it as
// any color texture. A load transaction between frames.
ui_texture_add :: proc(renderer:^Renderer,width,height:u32,name:string,effects:=false) -> (Texture_Handle,bool) {
    if renderer==nil {return 0,false}
    return gpu.ui_texture_add(renderer,width,height,name,effects)
}

ui_texture_remove :: proc(renderer:^Renderer,texture:Texture_Handle) -> bool {
    return renderer!=nil && gpu.ui_texture_remove(renderer,texture)
}

// Where a ray meets a mesh placed by transform, its first texture
// coordinates there and the normal it meets, against the ray (gpu.mesh_ray).
// ok false for a miss or without a renderer.
mesh_ray :: proc(renderer:^Renderer,mesh:Mesh_Handle,transform:matrix[4,4]f32,origin,direction:[3]f32,limit:=max(f32)) -> (distance:f32,uv:[2]f32,normal:[3]f32,ok:bool) {
    if renderer==nil {return}
    return gpu.mesh_ray(renderer,mesh,transform,origin,direction,limit)
}

// Makes what mesh_ray meets a mesh with when the renderer keeps no software
// tree of it, for a mesh a ray meets in many frames (gpu.mesh_ray_prepare).
mesh_ray_prepare :: proc(renderer:^Renderer,mesh:Mesh_Handle) -> bool {
    return renderer!=nil && gpu.mesh_ray_prepare(renderer,mesh)
}

mesh_ray_release :: proc(renderer:^Renderer,mesh:Mesh_Handle) {
    if renderer!=nil {gpu.mesh_ray_release(renderer,mesh)}
}

// What the depth probes of the last frame the GPU finished read (host.extras_depth_probe_add).
depth_probes :: proc(renderer:^Renderer) -> []gpu.Depth_Probe_Result {
    return renderer!=nil?gpu.renderer_depth_probes(renderer):nil
}

// Reads back the image a frame last drew into a texture of view_texture_add
// (RGBA8, its size; the caller frees it). Blocks until the GPU is idle;
// between frames. False while no frame has drawn it.
view_texture_capture :: proc(renderer:^Renderer,texture:Texture_Handle,allocator:=context.allocator) -> (pixels:[]u8,width,height:int,ok:bool) {
    if renderer==nil {return}
    return gpu.view_texture_capture(renderer,texture,allocator)
}

// Draws a view into a texture of view_texture_add in this frame, before the
// views of the window, with a pipeline (0: Full). cut: what it kept from its
// last image does not belong to this one. readback: the image comes back to
// the CPU (view_texture_pixels). False without room for another view.
view_texture_draw :: proc(extras:^host.Frame_Extras,texture:Texture_Handle,view:core.View,width,height:u32,cut:=false,pipeline:=Render_Pipeline(0),readback:=false) -> bool {
    return host.extras_texture_view_add(extras,{
        camera=host.camera_from_view(view),camera_cut=cut,rect={0,0,i32(width),i32(height)},texture=texture,pipeline=pipeline,readback=readback,
    })
}

// The image the last frame done drew into a texture with view_texture_draw
// and readback (RGBA8, the size of the texture), and that frame + 1 of the
// renderer; none until such a frame is done, which takes a few frames. It
// does not wait for the GPU. Valid until the next frame.
view_texture_pixels :: proc(renderer:^Renderer,texture:Texture_Handle) -> (pixels:[]u8,frame:u64,ok:bool) {
    if renderer==nil {return}
    return gpu.view_texture_pixels(renderer,texture)
}

// The GPU time of the last frame the GPU finished, on the clock of
// time.tick_now: one interval per pass while host.profile_request (or a
// recording) asks for them, else one "frame" interval. Valid until the next frame.
gpu_timings :: proc(renderer:^Renderer) -> []Gpu_Timing {return renderer!=nil?gpu.renderer_stats(renderer).timings:nil}

gpu_backend :: proc(app:^host.App) -> (backend:Gpu_Backend,ok:bool) {
    if app.device==nil {return}
    return rhi.device_info(app.device).backend,true
}
