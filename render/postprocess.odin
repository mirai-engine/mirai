package mirai_render

import "core:fmt"
import "mirai:rhi"

POSTPROCESS_CAPACITY :: 8
// fade: the share of the image the effect leaves as it read it, 0 to 1 (0: the whole effect; 1:
// it does not run, though a limited inspection still counts it).
Postprocess_Desc :: struct {program:u32,params:[16]Vec4,fade:f32,after_tonemap,enabled:bool}
Postprocess_List :: struct {count:u32,entries:[POSTPROCESS_CAPACITY]Postprocess_Desc}

// The effects of each side of the tonemap a view runs, the first ones of
// its list: [0] before, [1] after. All of them while not limited.
Postprocess_Inspect :: struct {limited:bool,effects:[2]u8}

@(private)
postprocess_limit :: proc "contextless" (inspection:View_Inspection,after:bool)->int {
    if !inspection.postprocess.limited {return POSTPROCESS_CAPACITY}
    return int(inspection.postprocess.effects[1 if after else 0])
}

renderer_set_postprocesses :: proc(r:^Renderer,list:Postprocess_List)->bool {
    if list.count>POSTPROCESS_CAPACITY {return false}
    r.postprocesses=list;return true
}
// The effects of the local view slot (Camera.slot is slot + 1).
renderer_set_view_postprocesses :: proc(r:^Renderer,slot:int,list:Postprocess_List)->bool {
    if list.count>POSTPROCESS_CAPACITY || slot<0 || slot>=len(r.view_postprocesses) {return false}
    r.view_postprocesses[slot]=list;return true
}
// The effects a view of camera is drawn with.
postprocess_list :: proc "contextless" (r:^Renderer,camera:Camera)->^Postprocess_List {
    if camera.slot>0 && int(camera.slot)<=len(r.view_postprocesses) {return &r.view_postprocesses[camera.slot-1]}
    return &r.postprocesses
}
// Whether the stack of the view has an effect to run before (false) or after the tonemap.
postprocess_active :: proc(p:^Pass,after:bool)->bool {
    list:=postprocess_list(p.r,p.camera)
    for &effect in list.entries[:list.count] {
        if effect.enabled && effect.after_tonemap==after && effect.program!=0 && effect.fade<1 {return true}
    }
    return false
}
// The two targets effects alternate between, made when the stack or the Post
// stage of extensions (pass_image_write) first uses them.
@(private="file")
postprocess_target :: proc(r:^Renderer,t:^Targets,after:bool,index:int)->rhi.Texture {
    target:=&t.post_ldr[index] if after else &t.post_hdr[index]
    if target^==0 {
        usage:=rhi.Texture_Usage{.Color_Target,.Sampled} if after else {.Color_Target,.Sampled,.Storage}
        target^=rhi.texture_create(r.device,{width=t.output_width,height=t.output_height,format=.RGBA8_Unorm if after else .RGBA16_Float,usage=usage,name="post LDR" if after else "post HDR"})
        if target^==0 {set_error(r,"postprocess target: %s",rhi.device_error(r.device))}
    }
    return target^
}
// The target an effect over current writes: the one of the two that is not it.
@(private)
postprocess_next :: proc(r:^Renderer,t:^Targets,current:rhi.Texture,after:bool)->rhi.Texture {
    first:=t.post_ldr[0] if after else t.post_hdr[0]
    return postprocess_target(r,t,after,1 if current!=0 && current==first else 0)
}
// The effects at one side of the tonemap, each over the image the one before
// left. Besides that image they read what the Output stage declares it reads
// (stage_contract): the linear depth, the normal and the outline mask. Each
// records its GPU time by its side and its place in the list ("postprocess hdr 1").
postprocess_passes :: proc(p:^Pass,source:rhi.Texture,after:bool)->rhi.Texture {
    r,cmd,t:=p.r,p.cmd,p.t
    depth,_:=pass_resource_of(p,.Linear_Depth,false)
    normal,_:=pass_resource_of(p,.Normal,false)
    mask,_:=pass_resource_of(p,.Highlight,false)
    // The mask holds this frame only when the frame outlined something.
    outlined:=highlight_drawn_in(p)
    if !outlined {mask=r.dummy_texture}
    current:=source
    counted:=0
    limit:=postprocess_limit(p.inspection,after)
    list:=postprocess_list(r,p.camera)
    for &effect,index in list.entries[:list.count] {
        if !effect.enabled || effect.after_tonemap!=after || effect.program==0 {continue}
        if counted>=limit {break}
        counted+=1
        if !(effect.fade<1) {continue}
        target:=postprocess_next(r,t,current,after)
        if target==0 {break}
        name:[32]u8
        rhi.cmd_timestamp(cmd,fmt.bprintf(name[:],"postprocess %s %d","display" if after else "hdr",index+1))
        pass:=rhi.Render_Pass_Desc{color_count=1,name="postprocess"}
        pass.colors[0]={texture=target,load=.Dont_Care,store=.Store}
        rhi.cmd_begin_render_pass(cmd,&pass)
        rhi.cmd_bind_pipeline(cmd,r.pipelines[.Postprocess_Ldr if after else .Postprocess_Hdr])
        // Before the tonemap an effect sees the image exposed (postprocess.frag).
        params:=Gpu_Post_Parameters{program=effect.program,exposed=0 if after else 1,outlined=1 if outlined else 0,fade=max(effect.fade,0),values=effect.params}
        set_params(cmd,&params)
        rhi.cmd_bind_texture(cmd,SLOT_PASS0,current)
        rhi.cmd_bind_texture(cmd,SLOT_PASS1,depth)
        rhi.cmd_bind_texture(cmd,SLOT_PASS2,normal)
        rhi.cmd_bind_buffer(cmd,SLOT_PASS3,p.view.exposure)
        rhi.cmd_bind_texture(cmd,SLOT_PASS4,mask)
        rhi.cmd_draw(cmd,3)
        rhi.cmd_end_render_pass(cmd)
        current=target
    }
    return current
}
