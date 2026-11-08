package mirai_render

import "mirai:rhi"

@(private)
view_state_destroy :: proc(r:^Renderer,view:^View_State) {
    destroy_targets(r,&view.targets)
    view_resources_free(r,view)
    extension_textures_release(r,view,all=true)
    if view.glass_dispatch!=0 {rhi.buffer_destroy(r.device,view.glass_dispatch)}
    if view.glass_seen!=0 {rhi.buffer_destroy(r.device,view.glass_seen)}
    if view.copy!=0 {rhi.buffer_destroy(r.device,view.copy)}
    if view.wide!=0 {rhi.texture_destroy(r.device,view.wide)}
    view_exposure_release(r,view)
    view^={}
}

@(private)
view_exposure_release :: proc(r:^Renderer,view:^View_State) {
    for b in view.exposure_readback {if b!=0 {rhi.buffer_destroy(r.device,b)}}
    if view.exposure!=0 {rhi.buffer_destroy(r.device,view.exposure)}
    if view.exposure_histogram!=0 {rhi.buffer_destroy(r.device,view.exposure_histogram)}
}

// An entry of the texture table for what a camera sees: a view of a frame
// draws into it (Frame_View.texture, with the same size in its rect) and a
// material shows it as any other color texture. Black until a frame draws
// it. A load transaction between frames.
view_texture_add :: proc(r:^Renderer,width,height:u32,name:string) -> (Texture_Handle,bool) {
    if width==0 || height==0 || width>8192 || height>8192 {return 0,false}
    blank,error:=make([]u8,int(width)*int(height)*4,r.allocator)
    if error!=nil {return 0,false}
    defer delete(blank,r.allocator)
    r.view_textures_made+=1
    return texture_image(r,VIEW_TEXTURE_KEY|r.view_textures_made,blank,int(width),int(height),name)
}

// Removes an entry of view_texture_add, with the targets of the view drawn
// into it. Between frames. False for a handle that names no texture.
view_texture_remove :: proc(r:^Renderer,texture:Texture_Handle) -> bool {
    for &view in r.texture_views {
        if view.texture!=texture {continue}
        rhi.device_wait_idle(r.device)
        view_state_destroy(r,&view)
    }
    readback_release(r,VIEW_TEXTURE_KEY|u64(texture),VIEW_READBACK)
    return texture_remove(r,texture)
}

// What the last frame done brought back of a view drawn into a texture with
// Frame_View.readback (RGBA8, the size of the texture), and that frame + 1;
// none until such a frame is done. It does not wait for the GPU. Valid until
// the next frame.
view_texture_pixels :: proc(r:^Renderer,texture:Texture_Handle) -> (pixels:[]u8,frame:u64,ok:bool) {
    return readback(r,VIEW_TEXTURE_KEY|u64(texture),VIEW_READBACK)
}

@(private)
VIEW_READBACK :: "view texture"

// Reads back the image a view last drew into a texture of view_texture_add
// (RGBA8, its size). Blocks until the GPU is idle; between frames. The
// caller owns the pixels. False while no frame has drawn it.
view_texture_capture :: proc(r:^Renderer,texture:Texture_Handle,allocator:=context.allocator) -> (pixels:[]u8,width,height:int,ok:bool) {
    state:=texture_view_find(r,texture)
    if state==nil || state.frames==0 {return}
    return targets_capture(r,&state.targets,allocator)
}

// Reads back the wide image the last frame kept of a view drawn into a
// texture with Frame_View.wide: RGBA 32-bit float, the size of the texture,
// rows from the top. Blocks until the GPU is idle; between frames. False
// while no frame kept one, or for an out of another size.
view_texture_wide :: proc(r:^Renderer,texture:Texture_Handle,out:[]f32) -> bool {
    state:=texture_view_find(r,texture)
    if state==nil || state.wide==0 || state.frames==0 {return false}
    size:=r.textures.sizes[texture-1]
    if len(out)!=size[0]*size[1]*4 {return false}
    if !rhi.texture_read(r.device,state.wide,([^]u8)(raw_data(out))[:len(out)*4]) {
        set_error(r,"wide capture: %s",rhi.device_error(r.device))
        return false
    }
    return true
}

@(private)
VIEW_TEXTURE_KEY :: u64(0x7669657700000000)

// The view that is drawn into a texture, with its targets; nil for a texture that is not there.
@(private)
texture_view_find :: proc(r:^Renderer,texture:Texture_Handle) -> ^View_State {
    for &view in r.texture_views {if view.texture==texture && view.targets.ldr!=0 {return &view}}
    return nil
}

// The targets of the views of the frame that are drawn into a texture: those
// of each texture are made the first time a view names it and kept, so that
// going back to one costs nothing. A view of a texture that is not there, or
// of another size, is left out of the frame.
@(private)
texture_views_prepare :: proc(r:^Renderer,views:[]Frame_View) -> bool {
    for &state in r.texture_views {
        if state.texture!=0 && (int(state.texture)>r.textures.count || r.textures.textures[state.texture-1]==0) {view_state_destroy(r,&state)}
    }
    for view in views {
        if view.texture==0 || view.disabled {continue}
        index:=int(view.texture)-1
        if index>=r.textures.count || r.textures.textures[index]==0 {continue}
        size:=r.textures.sizes[index]
        if int(view.rect.z)!=size[0] || int(view.rect.w)!=size[1] || texture_view_find(r,view.texture)!=nil {continue}
        // A place without a view, or the view drawn longest ago.
        state:=&r.texture_views[0]
        for &candidate in r.texture_views {
            if candidate.texture==0 {state=&candidate;break}
            if candidate.last_frame<state.last_frame {state=&candidate}
        }
        if state.texture!=0 {
            if state.last_frame+1>=r.frame {continue}
            view_state_destroy(r,state)
        }
        state.texture=view.texture
        ok:=create_targets(r,state,u32(size[0]),u32(size[1]),1)
        state.copy=rhi.buffer_create(r.device,{size=u64(size[0])*u64(size[1])*4,usage={.Transfer_Src,.Transfer_Dst},memory=.GPU,name="view texture copy"})
        if !ok || state.copy==0 || !view_glass_buffers(r,state) {
            set_error(r,"view texture targets: %s",rhi.device_error(r.device))
            view_state_destroy(r,state)
            return false
        }
    }
    for &state in r.texture_views {
        if state.texture!=0 && !ensure_glass_targets(r,&state.targets) {return false}
    }
    for view in views {
        if view.texture==0 || view.disabled || view.wide==.None {continue}
        state:=texture_view_find(r,view.texture)
        if state==nil || state.wide!=0 {continue}
        state.wide=rhi.texture_create(r.device,{width=state.targets.output_width,height=state.targets.output_height,format=.RGBA32_Float,usage={.Color_Target,.Transfer_Src},name="view wide"})
        if state.wide==0 {
            set_error(r,"view wide target: %s",rhi.device_error(r.device))
            return false
        }
    }
    return true
}

// The image a view drew, into its entry of the texture table and, with
// readback, into the readback of the texture (view_texture_pixels).
@(private)
texture_view_show :: proc(r:^Renderer,cmd:^rhi.Command_List,state:^View_State,slot:int,readback:bool) {
    image:=r.textures.textures[state.texture-1]
    rhi.cmd_copy_texture_to_buffer(cmd,state.targets.ldr,state.copy,0)
    rhi.cmd_copy_buffer_to_texture(cmd,state.copy,0,image)
    rhi.cmd_barrier_texture(cmd,image,.Shader_Read)
    if !readback {return}
    size:=r.textures.sizes[state.texture-1]
    entry:=extension_readback(r,VIEW_TEXTURE_KEY|u64(state.texture),{name=VIEW_READBACK,size=u64(size[0])*u64(size[1])*4})
    if entry==nil {return}
    rhi.cmd_copy_buffer(cmd,state.copy,0,entry.buffers[slot],0,entry.size)
    rhi.cmd_barrier_buffer(cmd,entry.buffers[slot],.Host_Read)
    entry.copied[slot]=r.frame+1
}

// The views of a frame that has several; the one of a frame with one stays.
@(private)
destroy_view_targets :: proc(r:^Renderer) {
    for &view in r.views {view_state_destroy(r,&view)}
}

@(private)
view_glass_buffers :: proc(r:^Renderer,view:^View_State) -> bool {
    if view.glass_dispatch==0 {view.glass_dispatch=rhi.buffer_create(r.device,{size=size_of(Gpu_Glass_Dispatch),usage={.Storage,.Indirect},name="glass dispatch"})}
    if view.glass_seen==0 {view.glass_seen=rhi.buffer_create(r.device,{size=16,usage={.Storage},name="glass seen"})}
    return view.glass_dispatch!=0 && view.glass_seen!=0
}

// The views of the window are those that name no texture: one is drawn with
// the targets of the renderer, several each with its own. alone: the frame
// draws only into textures, and those of the window stay as they are.
@(private)
prepare_views :: proc(r:^Renderer,views:[]Frame_View,alone:=false) -> bool {
    if alone {return texture_views_prepare(r,views)}
    // One view of the window that is the whole drawable is the frame itself; one
    // that is a part of it is drawn and composed as several are.
    windows:=0
    whole:=false
    top,bottom:=max(i32),min(i32)
    for view in views {
        if view.texture!=0 {continue}
        windows+=1
        whole=view.rect=={0,0,i32(r.window_width),i32(r.window_height)}
        top,bottom=min(top,view.rect.y),max(bottom,view.rect.y+view.rect.w)
    }
    count:=windows if windows>1 || windows==1 && !whole else 0
    if count>VIEW_CAPACITY {set_error(r,"too many views: %d",count);return false}
    for view in views {
        if view.texture!=0 {continue}
        if view.rect.x<0 || view.rect.y<0 || view.rect.z<=0 || view.rect.w<=0 ||
           i64(view.rect.x)+i64(view.rect.z)>i64(r.window_width) || i64(view.rect.y)+i64(view.rect.w)>i64(r.window_height) {
            set_error(r,"view rectangle is outside the drawable")
            return false
        }
    }
    if count!=r.view_count {
        rhi.device_wait_idle(r.device)
        destroy_view_targets(r)
        renderer_camera_cut(r)
        r.view_count=count
    }
    // All take one scale, from what they span together.
    scale:=window_render_scale(r,f32(bottom-top))
    index:=0
    for view in views {
        if view.texture!=0 || count==0 {continue}
        state:=&r.views[index]
        index+=1
        t:=&state.targets
        width,height:=u32(view.rect.z),u32(view.rect.w)
        if t.output_width!=width || t.output_height!=height || t.width!=render_extent(width,scale) || t.height!=render_extent(height,scale) {
            rhi.device_wait_idle(r.device)
            destroy_targets(r,t)
        }
        if t.ldr==0 && !create_targets(r,state,width,height,scale) {return false}
        if !ensure_glass_targets(r,t) {return false}
        if !view_glass_buffers(r,state) {set_error(r,"view buffers: %s",rhi.device_error(r.device));return false}
    }
    return texture_views_prepare(r,views)
}

@(private)
// generated: the images shown before those of the frame, into Targets.generated
// of the main view; a view that did not generate one shows its own.
compose_views :: proc(r:^Renderer,cmd:^rhi.Command_List,frame:Frame_Desc,slot:int,ui_written:^int,generated:=false) {
    shown :: proc(r:^Renderer,index:int,generated:bool) -> rhi.Texture {
        t:=&r.views[index].targets
        return t.generated if generated && r.views[index].generated else t.ldr
    }
    index:=0
    for view in frame.views {
        if view.texture!=0 {continue}
        if !view.disabled {rhi.cmd_barrier_texture(cmd,shown(r,index,generated),.Shader_Read)}
        index+=1
    }
    thumbnails:=r.thumbnails if r.thumbnails!=0 else r.dummy_texture
    rhi.cmd_barrier_texture(cmd,r.font,.Shader_Read)
    rhi.cmd_barrier_texture(cmd,thumbnails,.Shader_Read)
    rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler)
    rhi.cmd_bind_sampler(cmd,SLOT_POINT_SAMPLER,r.point_sampler)
    rhi.cmd_bind_sampler(cmd,SLOT_MATERIAL_SAMPLER,r.material_sampler)
    materials:=or_dummy(r,r.scene.material_buffer)
    rhi.cmd_barrier_buffer(cmd,materials,.Shader_Read)
    rhi.cmd_bind_buffer(cmd,SLOT_MATERIALS,materials)
    rhi.cmd_bind_transient(cmd,SLOT_FRAME,frame_constants(r,{time={r.time,r.previous_time,r.delta_time,0},resolution={f32(r.window_width),f32(r.window_height)}}))
    t:=&r.main.targets
    // The layers of the screen draw into t.ldr: the generated image takes its place.
    if generated {t.ldr,t.generated=t.generated,t.ldr}
    defer if generated {t.ldr,t.generated=t.generated,t.ldr}
    pass:=rhi.Render_Pass_Desc{color_count=1,name="split screen"}
    pass.colors[0]={texture=t.ldr,load=.Clear,store=.Store,clear={0,0,0,1}}
    rhi.cmd_begin_render_pass(cmd,&pass)
    rhi.cmd_bind_pipeline(cmd,r.pipelines[.Postprocess_Copy])
    params:=[4]u32{}
    set_params(cmd,&params)
    index=0
    for view in frame.views {
        if view.texture!=0 {continue}
        index+=1
        if view.disabled {continue}
        rect:=view.rect
        rhi.cmd_set_viewport(cmd,f32(rect.x),f32(rect.y),f32(rect.z),f32(rect.w))
        rhi.cmd_set_scissor(cmd,rect.x,rect.y,u32(rect.z),u32(rect.w))
        rhi.cmd_bind_texture(cmd,SLOT_PASS0,shown(r,index-1,generated))
        rhi.cmd_draw(cmd,3)
    }
    rhi.cmd_set_viewport(cmd,0,0,f32(r.window_width),f32(r.window_height))
    rhi.cmd_set_scissor(cmd,0,0,r.window_width,r.window_height)
    points:=Vec2{f32(r.window_width),f32(r.window_height)}/ui_scale(r)
    ui_layers_pass(r,cmd,ui_surface_of(t),slot,ui_written,frame.ui,points,ui_scale(r),thumbnails)
    rhi.cmd_end_render_pass(cmd)
}
