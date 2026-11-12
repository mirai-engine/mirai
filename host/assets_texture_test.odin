package host

import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
loaded_textures_take_the_limits_the_renderer_changes_to :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer);defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)

    root:=base.test_folder(t,"host-textures")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 512
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        level:=make([]u8,side*side*4,context.temp_allocator)
        for &value in level {value=200}
        append(&mips,level)
        if side==1 {break}
    }
    id:=base.Asset_Id{7,7}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/stone.tex",root),&types,{id=id,width=SIZE,height=SIZE,format=.RGBA8,flags={.Srgb},mips=mips[:]}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8,renderer=r})) {return}
    defer assets_destroy(&a)

    width :: proc(r:^render.Renderer,texture:^Assets_Texture) -> u32 {
        return rhi.texture_desc(r.device,r.textures.textures[texture.handle-1]).width
    }
    texture:=assets_texture(&a,id)
    if !testing.expect(t,texture!=nil && !texture.failed && texture.handle!=0) {return}
    testing.expect_value(t,width(r,texture),u32(SIZE))

    // The renderer alone does not reach what is loaded: the texture keeps its levels until it loads again.
    settings:=r.settings
    before:=r.settings
    settings.texture_max_size=128
    testing.expect(t,render.renderer_apply_settings(r,settings))
    testing.expect_value(t,width(r,texture),u32(SIZE))
    structure:=a.structure
    assets_textures_reload(&a,before)
    testing.expect(t,!texture.failed && texture.handle!=0)
    testing.expect_value(t,width(r,texture),u32(128))
    testing.expect(t,a.structure!=structure,"whoever holds the old handle extracts the scene again")

    before=r.settings
    settings.texture_max_size=4096
    testing.expect(t,render.renderer_apply_settings(r,settings))
    assets_textures_reload(&a,before)
    testing.expect_value(t,width(r,texture),u32(SIZE))
    _,reduced:=render.texture_stored(r,texture.handle)
    testing.expect(t,!reduced,"the pool holds every level again")

    // A texture no larger than either size keeps what it holds.
    before=r.settings
    settings.texture_max_size=8192
    testing.expect(t,render.renderer_apply_settings(r,settings))
    handle,structure_now:=texture.handle,a.structure
    assets_textures_reload(&a,before)
    testing.expect(t,texture.handle==handle && a.structure==structure_now,"what the change does not reach is not loaded again")
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// A texture an instance shows holds the levels the frames sample: far away,
// those of side render.TEXTURE_TAIL; near, all of them, read again from its
// file. Its handle stays, and the materials that name it with it.
@(test)
a_texture_holds_the_levels_the_frames_sample :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer)
    defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)

    root:=base.test_folder(t,"host-residency")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 512
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        level:=make([]u8,side*side*4,context.temp_allocator)
        for &value in level {value=200}
        append(&mips,level)
        if side==1 {break}
    }
    id:=base.Asset_Id{9,9}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/stone.tex",root),&types,{id=id,width=SIZE,height=SIZE,format=.RGBA8,flags={.Srgb},mips=mips[:]}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8,renderer=r})) {return}
    defer assets_destroy(&a)
    width :: proc(r:^render.Renderer,texture:^Assets_Texture) -> u32 {
        return rhi.texture_desc(r.device,r.textures.textures[texture.handle-1]).width
    }
    texture:=assets_texture(&a,id)
    if !testing.expect(t,texture!=nil && !texture.failed && texture.handle!=0) {return}
    handle:=texture.handle
    testing.expect_value(t,width(r,texture),u32(SIZE))

    material:=render.DEFAULT_MATERIAL
    material.textures[.Base_Color]=handle
    render.materials_set(r,{material})
    corners:=[4]render.Vec3{{-0.5,0,-0.5},{0.5,0,-0.5},{0.5,0,0.5},{-0.5,0,0.5}}
    vertices:[4]render.Mesh_Vertex
    for c,i in corners {vertices[i]={position=c,normal={0,1,0},tangent={1,0,0,1},uv={c.x+0.5,c.z+0.5},color={1,1,1},material=1}}
    indices:=[6]u32{0,2,1,0,3,2}
    quad,added:=render.mesh_add(r,vertices[:],indices[:])
    if !testing.expect(t,added) {return}
    render.scene_set_environment(r,{},{})
    render.scene_update(r,0,{{object_id=1,mesh=quad,transform=render.Mat4(1),tint={1,1,1}}},true)

    // What the streamer of the application does between frames, at once,
    // over the frames the feedback of a view takes to come back.
    settle :: proc(t:^testing.T,a:^Assets,r:^render.Renderer,types:^asset.Types,id:base.Asset_Id,camera:render.Camera,loc:=#caller_location) {
        for _ in 0..<16 {
            testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error,loc=loc)
            if render.textures_update(r)==0 {return}
            requests:[1]render.Texture_Request
            if render.texture_requests(r,requests[:],nil)!=1 {continue}
            prepared:=Assets_Prepared{level=requests[0].level}
            found:bool
            prepared.source,found=assets_source(a,id,context.allocator)
            if !testing.expect(t,found,loc=loc) {return}
            assets_prepare(&prepared,assets_limits(a),types)
            defer assets_prepared_free(&prepared)
            testing.expect_value(t,render.texture_levels_queue(r,requests[0],prepared.levels.data),render.Texture_Levels_Result.Set,loc=loc)
            for render.texture_upload_pending(r,requests[0]) {testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error,loc=loc)}
        }
        testing.fail_now(t,"the levels did not settle",loc=loc)
    }
    // A view of 64 pixels samples every level only a few centimetres away.
    look :: proc(height:f32) -> render.Camera {
        return {position={0,height,0},forward={0,-1,0},up={0,0,-1},fov_y=60,near=0.05,exposure=render.UNIT_EXPOSURE}
    }
    settle(t,&a,r,&types,id,look(10))
    testing.expect_value(t,width(r,texture),u32(render.TEXTURE_TAIL))
    testing.expect(t,texture.handle==handle,"the handle stays")
    settle(t,&a,r,&types,id,look(0.06))
    testing.expect_value(t,width(r,texture),u32(SIZE))
    testing.expect_value(t,render.textures_update(r),0)

    // Fewer levels, once a window of frames sampled it coarser, the renderer
    // copies from those it holds: nothing is read.
    requests:[1]render.Texture_Request
    for frames:=0;frames<2*render.TEXTURE_FEEDBACK_FRAMES && width(r,texture)!=u32(render.TEXTURE_TAIL);frames+=1 {
        testing.expect(t,render.renderer_frame(r,{camera=look(10)}),r.error)
        render.textures_update(r)
        testing.expect_value(t,render.texture_requests(r,requests[:],nil),0)
    }
    testing.expect_value(t,width(r,texture),u32(render.TEXTURE_TAIL))
    testing.expect(t,texture.handle==handle,"the handle stays")

    // Queued, the levels it lacks go with the frames that follow, and the
    // texture takes them once they went.
    for frames:=0;frames<16;frames+=1 {
        testing.expect(t,render.renderer_frame(r,{camera=look(0.06)}),r.error)
        if render.textures_update(r)>0 && render.texture_requests(r,requests[:],nil)==1 {break}
    }
    if !testing.expect(t,requests[0].handle==handle) {return}
    prepared:=Assets_Prepared{level=requests[0].level}
    found:bool
    prepared.source,found=assets_source(&a,id,context.allocator)
    if !testing.expect(t,found) {return}
    assets_prepare(&prepared,assets_limits(&a),&types)
    defer assets_prepared_free(&prepared)
    testing.expect_value(t,render.texture_levels_queue(r,requests[0],prepared.levels.data),render.Texture_Levels_Result.Set)
    testing.expect_value(t,render.texture_levels_queue(r,requests[0],prepared.levels.data),render.Texture_Levels_Result.Busy)
    testing.expect(t,render.texture_upload_pending(r,requests[0]) && width(r,texture)==u32(render.TEXTURE_TAIL),"the levels have not gone yet")
    for frames:=0;frames<8 && render.texture_upload_pending(r,requests[0]);frames+=1 {testing.expect(t,render.renderer_frame(r,{camera=look(0.06)}),r.error)}
    testing.expect(t,!render.texture_upload_pending(r,requests[0]),"they went")
    testing.expect_value(t,width(r,texture),u32(SIZE))
    testing.expect(t,render.renderer_frame(r,{camera=look(0.06)}),r.error)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// A load that takes a texture larger than the bytes of a frame over frames
// gives the renderer its levels of side render.TEXTURE_TAIL at once, which it
// samples until the others went with the frames that follow; then the
// texture has them all, with the same handle.
@(test)
a_texture_a_load_takes_over_frames_shows_its_small_levels_until_the_rest_went :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer)
    defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)

    root:=base.test_folder(t,"host-over-frames")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 2048
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        level:=make([]u8,side*side*4,context.temp_allocator)
        for &value in level {value=120}
        append(&mips,level)
        if side==1 {break}
    }
    id:=base.Asset_Id{11,11}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/wall.tex",root),&types,{id=id,width=SIZE,height=SIZE,format=.RGBA8,flags={.Srgb},mips=mips[:]}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8,renderer=r})) {return}
    defer assets_destroy(&a)
    width :: proc(r:^render.Renderer,texture:^Assets_Texture) -> u32 {
        return rhi.texture_desc(r.device,r.textures.textures[texture.handle-1]).width
    }
    prepared:Assets_Prepared
    found:bool
    prepared.source,found=assets_source(&a,id,context.allocator)
    if !testing.expect(t,found) {return}
    assets_prepare(&prepared,assets_limits(&a),&types)
    defer assets_prepared_free(&prepared)
    if !testing.expect(t,assets_prepared_split(&prepared)) {return}
    if !testing.expect_value(t,assets_take(&a,&prepared,over_frames=true),Assets_Take.Uploading) {return}
    texture:=assets_texture(&a,id)
    if !testing.expect(t,texture!=nil && !texture.failed && texture.handle==prepared.upload.handle) {return}
    handle:=texture.handle
    testing.expect_value(t,width(r,texture),u32(render.TEXTURE_TAIL))
    camera:=render.Camera{position={0,1000,0},forward={0,-1,0},up={0,0,-1},fov_y=60,near=0.05,exposure=render.UNIT_EXPOSURE}
    frames:=0
    for ;frames<16 && render.texture_upload_pending(r,prepared.upload);frames+=1 {
        testing.expect_value(t,width(r,texture),u32(render.TEXTURE_TAIL))
        testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)
    }
    testing.expect(t,frames>1 && !render.texture_upload_pending(r,prepared.upload),"over frames, and they went")
    testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,texture.handle==handle,"the handle stays")
    testing.expect_value(t,width(r,texture),u32(SIZE))
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// The words of the vertex block (its first vertex_words) and of the index
// block of a mesh the GPU holds are those of the pools of the CPU.
@(private="file")
pools_hold :: proc(device:^rhi.Device,r:^render.Renderer,m:render.Mesh_Record,vertex_words:u32) -> bool {
    s:=&r.scene
    if !rhi.device_wait_idle(device) {return false}
    vertices:=make([]u8,int(vertex_words)*4,context.temp_allocator)
    indices:=make([]u8,int(m.index_span)*4,context.temp_allocator)
    if !rhi.buffer_read(device,s.vertex_buffer,u64(m.vertex_word)*4,vertices) || !rhi.buffer_read(device,s.index_buffer,u64(m.index_word)*4,indices) {return false}
    return mem.compare(vertices,mem.slice_to_bytes(s.vertices[m.vertex_word:][:vertex_words]))==0 && mem.compare(indices,mem.slice_to_bytes(s.indices[m.index_word:][:m.index_span]))==0
}

// A load that takes a mesh larger than the bytes of a frame over frames gives
// the pools its geometry with the frames that follow: its instance is not
// drawn until all of it went, and then it is, with the pools of the GPU
// holding what those of the CPU hold. A skinned copy of it with a morph
// target, larger than what a frame uploads, goes the same way with its
// influences and targets: while it goes, the entity it replaces the mesh of
// is not drawn at all, outlined or met by rays, and then it shows posed.
@(test)
a_mesh_a_load_takes_over_frames_and_its_skinned_copy_are_drawn_once_all_of_them_went :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer)
    defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)

    root:=base.test_folder(t,"host-mesh-over-frames")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    COUNT :: LOAD_FRAME_BYTES/size_of(asset.Cluster_Vertex)+1024
    vertices:=make([]asset.Vertex,COUNT)
    defer delete(vertices)
    indices:=make([]u32,COUNT-COUNT%3)
    defer delete(indices)
    // Small triangles in rows, three vertices each.
    for &v,i in vertices {
        corner:=i%3
        x:=f32(i/3%1000)*0.01+(0.008 if corner==1 else 0)
        y:=f32(i/3/1000)*0.01+(0.008 if corner==2 else 0)
        v={position={x,y,0},normal=mm.normal_pack({0,0,1})}
    }
    for &index,i in indices {index=u32(i)}
    id:=base.Asset_Id{12,12}
    testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/sheet.mesh",root),&types,id,vertices,indices),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8,renderer=r})) {return}
    defer assets_destroy(&a)
    prepared:Assets_Prepared
    found:bool
    prepared.source,found=assets_source(&a,id,context.allocator)
    if !testing.expect(t,found) {return}
    assets_prepare(&prepared,assets_limits(&a),&types)
    defer assets_prepared_free(&prepared)
    if !testing.expect(t,assets_prepared_split(&prepared)) {return}
    if !testing.expect_value(t,assets_take(&a,&prepared,over_frames=true),Assets_Take.Uploading) {return}
    mesh:=assets_mesh(&a,id)
    if !testing.expect(t,mesh!=nil && !mesh.failed) {return}
    handle:=mesh.handle
    testing.expect(t,render.mesh_uploading(r,handle) && render.mesh_upload_pending(r,prepared.mesh_upload))

    camera:=render.Camera{position={5,5,8},forward={0,0,-1},up={0,1,0},fov_y=60,near=0.05,exposure=render.UNIT_EXPOSURE}
    // The statistics of a frame come back MAX_FRAMES_IN_FLIGHT frames after it.
    settle :: proc(t:^testing.T,r:^render.Renderer,camera:render.Camera) {
        for _ in 0..=rhi.MAX_FRAMES_IN_FLIGHT {testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)}
    }
    instances:=[1]render.Instance_Desc{{object_id=1,mesh=handle,transform=1}}
    render.scene_set_environment(r,{},{})
    render.scene_update(r,0,instances[:],true)
    drawn :: proc(r:^render.Renderer) -> bool {return r.scene.instances[0].meta.w&render.INSTANCE_FLAG_HIDDEN==0}
    frames:=0
    for ;frames<64 && render.mesh_upload_pending(r,prepared.mesh_upload);frames+=1 {
        testing.expect(t,!drawn(r),"not drawn before all of it went")
        testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)
    }
    testing.expectf(t,frames>1 && !render.mesh_upload_pending(r,prepared.mesh_upload),"over frames, and it went (%d frames)",frames)
    testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,drawn(r),"drawn at once once it went")
    settle(t,r,camera)
    testing.expect(t,r.stats.visible_instances>0,"the sheet is in view")
    record:=r.scene.meshes[handle]
    testing.expect(t,pools_hold(device,r,record,record.vertex_span),"the GPU holds its geometry")

    influences:=make([]render.Skin_Influence,record.vertex_count)
    defer delete(influences)
    ranges:=make([]render.Morph_Range,record.vertex_count)
    defer delete(ranges)
    deltas:=make([dynamic]render.Morph_Delta)
    defer delete(deltas)
    for &influence,i in influences {
        influence.joints[1]=1
        influence.weights[0]=255 if i%2==0 else 128
        influence.weights[1]=255-influence.weights[0]
        ranges[i].first=u32(len(deltas))
        if i%7==0 {
            append(&deltas,render.Morph_Delta{position={0,0,100},target=0})
            ranges[i].count=1
        }
    }
    pose,made:=render.skin_create(r,handle,influences,2,{ranges=ranges,deltas=deltas[:],count=1,step=0.001})
    if !testing.expect(t,made,r.error) {return}
    testing.expect(t,render.mesh_uploading(r,pose),"more than a frame uploads goes over frames")
    // As engine/render shows a copy that replaces the mesh of an entity: that mesh hidden, the copy outlined.
    entity:=[2]render.Instance_Desc{{object_id=1,mesh=handle,transform=1,hidden=true},{object_id=1,copy_owner=1,mesh=pose,transform=1,highlight=1}}
    render.scene_set_environment(r,{},{})
    render.scene_update(r,0,entity[:],true)
    copied :: proc(r:^render.Renderer) -> bool {return r.scene.instances[1].meta.w&render.INSTANCE_FLAG_HIDDEN==0}
    lifted:=mm.Mat4(1)
    lifted[1,3]=0.5
    testing.expect(t,render.skin_update(r,pose,{1,lifted},false,{0.5}))
    for frames=0;frames<128 && render.mesh_uploading(r,pose);frames+=1 {
        testing.expect(t,!copied(r) && !render.highlight_drawn(r.scene.instances[1].meta.w) && r.scene.hw_instances[1].mask_flags==0,"its copy is not drawn, outlined or met by rays before all of it went")
        testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)
        if frames>=rhi.MAX_FRAMES_IN_FLIGHT {testing.expect_value(t,r.stats.visible_instances,u32(0))}
    }
    testing.expectf(t,frames>rhi.MAX_FRAMES_IN_FLIGHT && !render.mesh_uploading(r,pose),"over frames, and it went (%d frames)",frames)
    testing.expect(t,render.renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,copied(r) && render.highlight_drawn(r.scene.instances[1].meta.w),"its copy is drawn once it went, outlined")
    settle(t,r,camera)
    testing.expect(t,r.stats.visible_instances>0,"and the frame shows it")
    posed:=r.scene.meshes[pose]
    testing.expect(t,pools_hold(device,r,posed,posed.posed_word-posed.vertex_word),"the GPU holds the blocks of the copy, before what skinning writes")
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// A cube in BC6H loads whole with its six faces, out of the table of 2D
// textures; a material that names it gets nothing, and an Unsupported error.
@(test)
a_cube_loads_whole_and_a_material_does_not_sample_it :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer);defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)

    root:=base.test_folder(t,"host-cube")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 16
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        level:=make([]u8,asset.texture_level_size(.BC6H,side,side)*6,context.temp_allocator)
        for at:=0;at<len(level);at+=16 {level[at]=0b00011} // mode 11
        append(&mips,level)
        if side==1 {break}
    }
    id:=base.Asset_Id{9,9}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/sky.tex",root),&types,{id=id,width=SIZE,height=SIZE,layers=6,format=.BC6H,flags={.Cube},mips=mips[:]}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8,renderer=r})) {return}
    defer assets_destroy(&a)
    texture:=assets_texture(&a,id)
    if !testing.expect(t,texture!=nil && !texture.failed && texture.handle!=0 && texture.layers==6) {return}
    desc:=rhi.texture_desc(r.device,r.textures.textures[texture.handle-1])
    testing.expect(t,desc.layers==6 && desc.cube && desc.width==SIZE && int(desc.mip_levels)==len(mips),"every level of every face")
    testing.expect(t,assets_texture_image(&a,id)==nil,"a material samples 2D images")
    unsupported:=false
    for e in a.errors {unsupported||=e.id==id && e.problem==.Unsupported}
    testing.expect(t,unsupported)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}

// A texture a material names arrives: the material loads without reading it,
// its row leaves it out, and once a job read its levels of side
// render.TEXTURE_TAIL and the assets took them, the row takes the texture.
// Asked for directly while it arrives, it loads whole in the call.
@(test)
a_texture_a_material_names_arrives_with_its_small_levels :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer);defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)

    root:=base.test_folder(t,"host-arrivals")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    SIZE :: 512
    mips:=make([dynamic][]u8,context.temp_allocator)
    for side:=SIZE;;side/=2 {
        level:=make([]u8,side*side*4,context.temp_allocator)
        for &value in level {value=200}
        append(&mips,level)
        if side==1 {break}
    }
    stone,bark,material:=base.Asset_Id{9,9},base.Asset_Id{8,8},base.Asset_Id{7,7}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/stone.tex",root),&types,{id=stone,width=SIZE,height=SIZE,format=.RGBA8,flags={.Srgb},mips=mips[:]}),asset.Error.None)
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/bark.tex",root),&types,{id=bark,width=SIZE,height=SIZE,format=.RGBA8,flags={.Srgb},mips=mips[:]}),asset.Error.None)
    info:=asset.MATERIAL_DEFAULTS
    info.maps.base_color.texture=stone
    info.maps.normal.texture=bark
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",root),&types,{id=material,info=info}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8,renderer=r})) {return}
    defer assets_destroy(&a)
    a.arrive=true

    row:=assets_material_row(&a,material)
    testing.expect(t,row!=0 && assets_texture_arriving(&a,stone) && assets_texture_arriving(&a,bark),"the material loads, its textures arrive")
    testing.expect(t,!assets_loaded(&a,stone) && len(a.arrivals)==2)
    testing.expect_value(t,assets_material_values(&a,row).textures[.Base_Color],render.Texture_Handle(0))

    // What a job of app_textures_stream reads, and the frame takes.
    prepared:Assets_Prepared
    found:bool
    prepared.source,found=assets_source(&a,stone,context.allocator)
    if !testing.expect(t,found) {return}
    assets_prepare(&prepared,assets_limits(&a,tail=true),&types)
    defer assets_prepared_free(&prepared)
    testing.expect_value(t,assets_take(&a,&prepared),Assets_Take.Taken)
    texture:=assets_texture(&a,stone)
    if !testing.expect(t,texture!=nil && !texture.failed && texture.handle!=0 && !assets_texture_arriving(&a,stone)) {return}
    testing.expect_value(t,rhi.texture_desc(r.device,r.textures.textures[texture.handle-1]).width,u32(render.TEXTURE_TAIL))
    testing.expect(t,assets_arrivals_settle(&a),"the row that waited changes")
    testing.expect_value(t,assets_material_values(&a,row).textures[.Base_Color],texture.handle)
    testing.expect(t,assets_material(&a,material).waiting,"it still waits for the other")

    // Asked for directly, an arriving texture loads whole now.
    whole:=assets_texture(&a,bark)
    if !testing.expect(t,whole!=nil && whole.handle!=0 && !assets_texture_arriving(&a,bark)) {return}
    testing.expect_value(t,rhi.texture_desc(r.device,r.textures.textures[whole.handle-1]).width,u32(SIZE))
    testing.expect(t,assets_arrivals_settle(&a))
    testing.expect_value(t,assets_material_values(&a,row).textures[.Normal],whole.handle)
    testing.expect(t,!assets_material(&a,material).waiting)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
