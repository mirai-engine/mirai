package fsr

import "core:math"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

// AMD FidelityFX Super Resolution 3.1.4 (MIT) as a technique of antialiasing
// (Graphics_Settings.antialiasing): while the setting names it, the views of
// the window are drawn with a pipeline whose passes, those of
// ffx_fsr3upscaler.cpp in its order, stand in place of the Resolve stage. They
// reconstruct the image of the view at the size it is shown at from the
// frames before, as the TAA does, and RCAS sharpens it. AMD's HLSL is in
// shaders/fsr3; the passes bind their resources at the slots their entries
// (shaders/fsr3_*.comp.slang) name.

FSR3_NAME :: "fsr3"
FSR3_LABEL :: "FSR 3.1"

Fsr_Sharpness :: enum u8 {Off,Low,Medium,High}
// The sharpness of RCAS, as ffxFsr3UpscalerDispatch takes it: 0 to 1.
FSR_SHARPNESS :: [Fsr_Sharpness]f32{.Off=0,.Low=0.25,.Medium=0.5,.High=0.8}

@(storage,setting="machine")
Fsr_Settings :: struct {
    sharpness:Fsr_Sharpness `mirai:"graphics=FSR sharpness"`, // RCAS over the image FSR 3.1 resolves
}

FSR_SETTINGS_DEFAULT :: Fsr_Settings{sharpness=.Medium}

Fsr_Pass :: enum u8 {Exposure,Prepare_Inputs,Luma_Pyramid,Shading_Change_Pyramid,Shading_Change,Prepare_Reactivity,Luma_Instability,Accumulate,Accumulate_Sharpen,Rcas}
FSR_SHADERS :: [Fsr_Pass]string{
    .Exposure="fsr3_exposure",.Prepare_Inputs="fsr3_prepare_inputs",.Luma_Pyramid="fsr3_luma_pyramid",
    .Shading_Change_Pyramid="fsr3_shading_change_pyramid",.Shading_Change="fsr3_shading_change",
    .Prepare_Reactivity="fsr3_prepare_reactivity",.Luma_Instability="fsr3_luma_instability",
    .Accumulate="fsr3_accumulate",.Accumulate_Sharpen="fsr3_accumulate_sharpen",.Rcas="fsr3_rcas",
}

@(storage,host)
Fsr_Runtime :: struct {
    pipelines:[Fsr_Pass]render.Pipeline, // of this frame
    sharpness:f32,                        // of this frame; 0: RCAS does not run
    framegen:[Fg_Pass]render.Pipeline,    // of this frame (framegen.odin)
}

// The resources of the pipeline: their sizes and formats are those
// ffx_fsr3upscaler.cpp gives them.
DILATED_MOTION :: render.Render_Resource.Custom0
DILATED_DEPTH :: render.Render_Resource.Custom1
RECONSTRUCTED_DEPTH :: render.Render_Resource.Custom2
FARTHEST_DEPTH :: render.Render_Resource.Custom3
LUMA :: render.Render_Resource.Custom4
SPD_MIPS :: render.Render_Resource.Custom5
SPD_ATOMIC :: render.Render_Resource.Custom6
FRAME_INFO :: render.Render_Resource.Custom7
FARTHEST_DEPTH_MIP1 :: render.Render_Resource.Custom8
SHADING_CHANGE :: render.Render_Resource.Custom9
DILATED_REACTIVE :: render.Render_Resource.Custom10
NEW_LOCKS :: render.Render_Resource.Custom11
ACCUMULATION :: render.Render_Resource.Custom12
LUMA_HISTORY :: render.Render_Resource.Custom13
LUMA_INSTABILITY :: render.Render_Resource.Custom14
INTERNAL :: render.Render_Resource.Custom15
INPUT_EXPOSURE :: render.Render_Resource.Custom16
COMPOSITION_MASK :: render.Render_Resource.Custom17

// The passes dispatch whole groups of 8, so the targets at the size of the
// view are a multiple of 8 on each side; the shaders clamp to the render size.
// The pyramid of the luma starts at half the render size, a multiple of 32
// so that its six levels exist and every group of SPD writes inside it.
FSR_RESOURCES :: [?]render.Render_Resource_Desc{
    {id=DILATED_MOTION,format=.RG16_Float,align=8},
    {id=DILATED_DEPTH,format=.R16_Float,align=8},
    {id=RECONSTRUCTED_DEPTH,format=.R32_Uint,align=8},
    {id=FARTHEST_DEPTH,format=.R16_Float,align=8},
    {id=LUMA,format=.R16_Float,align=8,history=true},
    {id=SPD_MIPS,format=.RG16_Float,shift=1,align=32,mips=render.RENDER_MIPS_ALL},
    {id=SPD_ATOMIC,format=.R32_Uint,size=.Fixed,width=1,height=1},
    {id=FRAME_INFO,format=.RGBA32_Float,size=.Fixed,width=1,height=1,kept=true},
    {id=FARTHEST_DEPTH_MIP1,format=.R16_Float,shift=1},
    {id=SHADING_CHANGE,format=.R8_Unorm,shift=1},
    {id=DILATED_REACTIVE,format=.RGBA8_Unorm,align=8},
    {id=NEW_LOCKS,format=.R32_Float,size=.Output,kept=true},
    {id=ACCUMULATION,format=.R8_Unorm,align=8,history=true},
    {id=LUMA_HISTORY,format=.RGBA16_Float,align=8,history=true},
    {id=LUMA_INSTABILITY,format=.R16_Float,align=8},
    {id=INTERNAL,format=.RGBA16_Float,size=.Output,history=true},
    {id=INPUT_EXPOSURE,format=.RG32_Float,size=.Fixed,width=1,height=1},
    {id=COMPOSITION_MASK,format=.R8_Unorm,align=8,kept=true}, // FSR's transparency and composition mask, which stays zero
}

// Offers FSR 3.1 in each frame, and while the graphics settings name it draws
// the views of the window with its pipeline, which also generates frames
// while they ask for it. Until the shaders have its stages the views keep
// the TAA.
@(step="render",loops="game editor",after="render_sync")
fsr_render :: proc(state:^Fsr_Runtime,graphics:render.Graphics_Settings,settings:Fsr_Settings,app:^host.App) {
    if app.renderer==nil {return}
    render.antialiasing_offer(app.renderer,FSR3_NAME,FSR3_LABEL)
    technique:=graphics.antialiasing
    if base.text_get(technique[:])!=FSR3_NAME {return}
    shaders:=FSR_SHADERS
    for &pipeline,pass in state.pipelines {
        pipeline=render.stage_pipeline(app.renderer,{stage=.Custom,shader=shaders[pass],name=shaders[pass]})
        if pipeline==0 {return}
    }
    generate:=render.graphics_generates(graphics,app)
    if generate {
        shaders:=FG_SHADERS
        for &pipeline,pass in state.framegen {
            pipeline=render.stage_pipeline(app.renderer,{stage=.Custom,shader=shaders[pass],name=shaders[pass]})
            generate&&=pipeline!=0
        }
    }
    sharpness:=FSR_SHARPNESS
    state.sharpness=sharpness[settings.sharpness] if settings.sharpness<=max(Fsr_Sharpness) else 0
    handle,_:=render.pipeline(app.renderer,fsr_pipeline(state,generate))
    if handle!=0 {render.pipeline_main(app.renderer,handle)}
}

Use :: render.Render_Use

// The standard Full pipeline, with the passes of FSR 3.1 in place of the
// Resolve stage and, with generate, those that generate a frame after the
// Output stage.
fsr_pipeline :: proc(state:^Fsr_Runtime,generate:bool) -> render.Render_Pipeline_Desc {
    @(static,rodata) exposure_uses:=[?]Use{{.Exposure,.Read,false},{INPUT_EXPOSURE,.Write,false},{FRAME_INFO,.Write,false},{RECONSTRUCTED_DEPTH,.Write,false},{SPD_ATOMIC,.Write,false}}
    @(static,rodata) prepare_inputs_uses:=[?]Use{
        {.Motion,.Read,false},{.Depth,.Read,false},{.Display,.Read,false},
        {DILATED_MOTION,.Write,false},{DILATED_DEPTH,.Write,false},{RECONSTRUCTED_DEPTH,.Write,false},{FARTHEST_DEPTH,.Write,false},{LUMA,.Write,false},
    }
    @(static,rodata) luma_pyramid_uses:=[?]Use{
        {LUMA,.Read,false},{FARTHEST_DEPTH,.Read,false},
        {SPD_ATOMIC,.Write,false},{FRAME_INFO,.Write,false},{SPD_MIPS,.Write,false},{FARTHEST_DEPTH_MIP1,.Write,false},
    }
    @(static,rodata) shading_change_pyramid_uses:=[?]Use{
        {LUMA,.Read,false},{LUMA,.Read,true},{DILATED_MOTION,.Read,false},{INPUT_EXPOSURE,.Read,false},
        {SPD_ATOMIC,.Write,false},{SPD_MIPS,.Write,false},
    }
    @(static,rodata) shading_change_uses:=[?]Use{{SPD_MIPS,.Read,false},{SHADING_CHANGE,.Write,false}}
    @(static,rodata) prepare_reactivity_uses:=[?]Use{
        {RECONSTRUCTED_DEPTH,.Read,false},{DILATED_MOTION,.Read,false},{DILATED_DEPTH,.Read,false},{.Reactive,.Read,false},
        {COMPOSITION_MASK,.Read,false},{ACCUMULATION,.Read,true},{SHADING_CHANGE,.Read,false},{LUMA,.Read,false},{INPUT_EXPOSURE,.Read,false},
        {DILATED_REACTIVE,.Write,false},{NEW_LOCKS,.Write,false},{ACCUMULATION,.Write,false},
    }
    @(static,rodata) luma_instability_uses:=[?]Use{
        {INPUT_EXPOSURE,.Read,false},{DILATED_REACTIVE,.Read,false},{DILATED_MOTION,.Read,false},{FRAME_INFO,.Read,false},
        {LUMA_HISTORY,.Read,true},{FARTHEST_DEPTH_MIP1,.Read,false},{LUMA,.Read,false},
        {LUMA_HISTORY,.Write,false},{LUMA_INSTABILITY,.Write,false},
    }
    @(static,rodata) accumulate_uses:=[?]Use{
        {INPUT_EXPOSURE,.Read,false},{DILATED_REACTIVE,.Read,false},{DILATED_MOTION,.Read,false},{INTERNAL,.Read,true},
        {FARTHEST_DEPTH_MIP1,.Read,false},{LUMA,.Read,false},{LUMA_INSTABILITY,.Read,false},{.Display,.Read,false},
        {INTERNAL,.Write,false},{NEW_LOCKS,.Write,false},{.Taa,.Write,false},
    }
    @(static,rodata) accumulate_sharpen_uses:=[?]Use{
        {INPUT_EXPOSURE,.Read,false},{DILATED_REACTIVE,.Read,false},{DILATED_MOTION,.Read,false},{INTERNAL,.Read,true},
        {FARTHEST_DEPTH_MIP1,.Read,false},{LUMA,.Read,false},{LUMA_INSTABILITY,.Read,false},{.Display,.Read,false},
        {INTERNAL,.Write,false},{NEW_LOCKS,.Write,false},
    }
    @(static,rodata) rcas_uses:=[?]Use{{INPUT_EXPOSURE,.Read,false},{INTERNAL,.Read,false},{.Taa,.Write,false}}
    @(static,rodata) resources:=FSR_RESOURCES

    passes:=make([dynamic]render.Render_Pass_Desc,context.temp_allocator)
    sharpen:=state.sharpness>0
    for pass in render.standard_pipeline_passes(.Full) {
        if pass.stage!=.Resolve {append(&passes,pass);continue}
        append(&passes,
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 exposure",uses=exposure_uses[:],record=fsr_exposure_record,user=state},
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 prepare inputs",uses=prepare_inputs_uses[:],record=fsr_prepare_inputs_record,user=state},
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 luma pyramid",uses=luma_pyramid_uses[:],record=fsr_luma_pyramid_record,user=state},
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 shading change pyramid",uses=shading_change_pyramid_uses[:],record=fsr_shading_change_pyramid_record,user=state},
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 shading change",uses=shading_change_uses[:],record=fsr_shading_change_record,user=state},
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 prepare reactivity",uses=prepare_reactivity_uses[:],record=fsr_prepare_reactivity_record,user=state},
            render.Render_Pass_Desc{stage=.Custom,name="fsr3 luma instability",uses=luma_instability_uses[:],record=fsr_luma_instability_record,user=state},
        )
        if sharpen {
            append(&passes,
                render.Render_Pass_Desc{stage=.Custom,name="fsr3 accumulate",uses=accumulate_sharpen_uses[:],record=fsr_accumulate_record,user=state},
                render.Render_Pass_Desc{stage=.Custom,name="fsr3 rcas",uses=rcas_uses[:],record=fsr_rcas_record,user=state},
            )
        } else {
            append(&passes,render.Render_Pass_Desc{stage=.Custom,name="fsr3 accumulate",uses=accumulate_uses[:],record=fsr_accumulate_record,user=state})
        }
    }
    if !generate {return {passes=passes[:],resources=resources[:],jitter=.Upscale}}
    all:=make([dynamic]render.Render_Resource_Desc,context.temp_allocator)
    append(&all,..resources[:])
    fg_append(&passes,&all,state)
    return {passes=passes[:],resources=all[:],jitter=.Upscale}
}

// cbFSR3Upscaler of ffx_fsr3upscaler_callbacks_hlsl.h, as Fsr3UpscalerConstants
// in ffx_fsr3upscaler_private.h. The block ends at 148 bytes; the binding
// covers 160 so that a layout that rounds the block up finds the range it asks for.
Fsr3_Constants :: struct {
    render_size:                       [2]i32,
    previous_frame_render_size:        [2]i32,
    upscale_size:                      [2]i32,
    previous_frame_upscale_size:       [2]i32,
    max_render_size:                   [2]i32,
    max_upscale_size:                  [2]i32,
    device_to_view_depth:              [4]f32,
    jitter:                            [2]f32,
    previous_frame_jitter:             [2]f32,
    motion_vector_scale:               [2]f32,
    downscale_factor:                  [2]f32,
    motion_vector_jitter_cancellation: [2]f32,
    tan_half_fov:                      f32,
    jitter_phase_count:                f32,
    delta_time:                        f32,
    delta_pre_exposure:                f32,
    view_space_to_meters_factor:       f32,
    frame_index:                       f32,
    velocity_factor:                   f32,
    reactiveness_scale:                f32,
    shading_change_scale:              f32,
    accumulation_added_per_frame:      f32,
    min_disocclusion_accumulation:     f32,
    reserved:                          [3]u32,
}
#assert(size_of(Fsr3_Constants)==160)

// cbSPD of ffx_fsr3upscaler_callbacks_hlsl.h, rounded the same way.
Fsr3_Spd_Constants :: struct {
    mips:              u32,
    work_groups:       u32,
    work_group_offset: [2]u32,
    render_size:       [2]u32,
    reserved:          [2]u32,
}
#assert(size_of(Fsr3_Spd_Constants)==32)

// The defaults of ffxFsr3UpscalerDispatch.
FSR3_ACCUMULATION_ADDED_PER_FRAME :: f32(1.0/3.0)
FSR3_MIN_DISOCCLUSION_ACCUMULATION :: f32(-1.0/3.0)
// SPD keeps at least the six levels the reduction reads, and at most twelve.
FSR3_SPD_MIN_MIPS :: 6
FSR3_SPD_MAX_MIPS :: 12

// The constants of the frame, as ffxFsr3UpscalerDispatch computes them. The
// depth of the view is reversed (near 1, far 0), and infinite for a camera
// without a far plane; the color is in render units and the passes tonemap it
// with the exposure of the view.
fsr3_constants :: proc(s:^render.Pass) -> Fsr3_Constants {
    depth,tan_half_fov:=fsr3_view_depth(s)
    size:=[2]i32{i32(s.width),i32(s.height)}
    output:=[2]i32{i32(s.output_width),i32(s.output_height)}
    return {
        render_size=size,previous_frame_render_size=size,
        upscale_size=output,previous_frame_upscale_size=output,
        max_render_size={(size.x+7)/8*8,(size.y+7)/8*8},max_upscale_size=output,
        device_to_view_depth=depth,
        jitter={s.jitter.x,s.jitter.y},previous_frame_jitter={s.previous_jitter.x,s.previous_jitter.y},
        // The motion of the G-buffer is an offset in UV already.
        motion_vector_scale={1,1},
        downscale_factor={f32(s.width)/f32(s.output_width),f32(s.height)/f32(s.output_height)},
        tan_half_fov=tan_half_fov,
        jitter_phase_count=f32(max(s.jitter_phases,1)),
        delta_time=clamp(s.delta_time,0,1),
        delta_pre_exposure=1,view_space_to_meters_factor=1,
        frame_index=f32(s.history_frames),
        velocity_factor=1,reactiveness_scale=1,shading_change_scale=1,
        accumulation_added_per_frame=FSR3_ACCUMULATION_ADDED_PER_FRAME,
        min_disocclusion_accumulation=FSR3_MIN_DISOCCLUSION_ACCUMULATION,
    }
}

// setupDeviceDepthToViewSpaceDepthParams of ffx_fsr3upscaler.cpp and
// ffx_frameinterpolation.cpp, the same in both: the elements c and e of the
// projection, reversed and finite or infinite, and the scale of x and y; and
// the tangent of half the horizontal field of view.
fsr3_view_depth :: proc(s:^render.Pass) -> (device_to_view_depth:[4]f32,tan_half_fov:f32) {
    camera:=s.camera
    near:=max(camera.near,0.001)
    far:=max(camera.far,near+1)
    f_min,f_max:=far,near
    f_q:=f_max/(f_min-f_max)
    depth:=[2]f32{-f_q,f_q*f_min} if camera.far>0 else [2]f32{-math.F32_EPSILON,f_max}
    fov_y:=camera.fov_y if camera.fov_y>0 else 60
    aspect:=f32(s.width)/f32(s.height)
    cot_half_fov:=1/math.tan(fov_y*math.PI/360)
    a,b:=cot_half_fov/aspect,cot_half_fov
    return {depth.x,depth.y,1/a,1/b},math.tan(fov_y*math.PI/360)*aspect
}

// ffxSpdSetup of ffx_spd.h: the groups over the render size and the levels
// the pyramid keeps.
fsr3_spd_constants :: proc(s:^render.Pass) -> (params:Fsr3_Spd_Constants,groups_x,groups_y:u32) {
    groups_x,groups_y=(s.width+63)/64,(s.height+63)/64
    mips:=u32(min(math.floor(math.log2(f32(max(s.width,s.height,1)))),f32(FSR3_SPD_MAX_MIPS)))
    params={mips=max(mips,FSR3_SPD_MIN_MIPS),work_groups=groups_x*groups_y,render_size={s.width,s.height}}
    return
}

// FsrRcasCon of ffx_fsr1.h over the sharpness ffxFsr3UpscalerDispatch remaps:
// stops of attenuation, 0 the sharpest.
fsr3_rcas_constants :: proc(sharpness:f32) -> [4]u32 {
    stops:=math.pow(f32(2),-(2-2*clamp(sharpness,0,1)))
    half:=u32(transmute(u16)f16(stops))
    return {transmute(u32)stops,half|half<<16,0,0}
}

@(private)
groups :: proc "contextless" (size,group:u32) -> u32 {return (size+group-1)/group}

@(private="file")
fsr_begin :: proc(s:^render.Pass,state:^Fsr_Runtime,pass:Fsr_Pass) -> bool {
    render.pass_pipeline(s,state.pipelines[pass])
    constants:=fsr3_constants(s)
    return render.pass_constants(s,0,&constants,size_of(constants))
}

@(private)
fsr_exposure_record :: proc(s:^render.Pass,user:rawptr) {
    state:=cast(^Fsr_Runtime)user
    // The depth the frame reconstructs starts at the far plane, and SPD counts its groups from zero.
    render.pass_clear(s,RECONSTRUCTED_DEPTH)
    render.pass_clear(s,SPD_ATOMIC)
    render.pass_pipeline(s,state.pipelines[.Exposure])
    Params :: struct {reset:u32,pad:[3]u32}
    params:=Params{reset=0 if s.history else 1}
    if !render.pass_params(s,&params,size_of(params)) {return}
    render.pass_resource(s,2,.Exposure)
    render.pass_resource(s,3,INPUT_EXPOSURE)
    render.pass_resource(s,4,FRAME_INFO)
    render.pass_dispatch(s,1,1)
}

@(private)
fsr_prepare_inputs_record :: proc(s:^render.Pass,user:rawptr) {
    if !fsr_begin(s,cast(^Fsr_Runtime)user,.Prepare_Inputs) {return}
    render.pass_resource(s,2,.Motion)
    render.pass_resource(s,3,.Depth)
    render.pass_resource(s,4,.Display)
    render.pass_resource(s,5,DILATED_MOTION)
    render.pass_resource(s,6,DILATED_DEPTH)
    render.pass_resource(s,7,RECONSTRUCTED_DEPTH)
    render.pass_resource(s,8,FARTHEST_DEPTH)
    render.pass_resource(s,9,LUMA)
    render.pass_dispatch(s,groups(s.width,8),groups(s.height,8))
}

@(private)
fsr_luma_pyramid_record :: proc(s:^render.Pass,user:rawptr) {
    if !fsr_begin(s,cast(^Fsr_Runtime)user,.Luma_Pyramid) {return}
    spd,groups_x,groups_y:=fsr3_spd_constants(s)
    if !render.pass_constants(s,1,&spd,size_of(spd)) {return}
    render.pass_resource(s,2,LUMA)
    render.pass_resource(s,3,FARTHEST_DEPTH)
    render.pass_resource(s,4,SPD_ATOMIC)
    render.pass_resource(s,5,FRAME_INFO)
    for mip in 0..<6 {render.pass_resource(s,6+u32(mip),SPD_MIPS,mip=i32(mip))}
    render.pass_resource(s,12,FARTHEST_DEPTH_MIP1)
    render.pass_dispatch(s,groups_x,groups_y)
}

@(private)
fsr_shading_change_pyramid_record :: proc(s:^render.Pass,user:rawptr) {
    if !fsr_begin(s,cast(^Fsr_Runtime)user,.Shading_Change_Pyramid) {return}
    spd,groups_x,groups_y:=fsr3_spd_constants(s)
    if !render.pass_constants(s,1,&spd,size_of(spd)) {return}
    render.pass_resource(s,2,LUMA)
    render.pass_resource(s,3,LUMA,previous=true)
    render.pass_resource(s,4,DILATED_MOTION)
    render.pass_resource(s,5,INPUT_EXPOSURE)
    render.pass_resource(s,6,SPD_ATOMIC)
    for mip in 0..<6 {render.pass_resource(s,7+u32(mip),SPD_MIPS,mip=i32(mip))}
    render.pass_dispatch(s,groups_x,groups_y)
}

@(private)
fsr_shading_change_record :: proc(s:^render.Pass,user:rawptr) {
    if !fsr_begin(s,cast(^Fsr_Runtime)user,.Shading_Change) {return}
    render.pass_resource(s,2,SPD_MIPS)
    render.pass_resource(s,3,SHADING_CHANGE)
    render.pass_dispatch(s,groups((s.width+1)/2,8),groups((s.height+1)/2,8))
}

@(private)
fsr_prepare_reactivity_record :: proc(s:^render.Pass,user:rawptr) {
    if !fsr_begin(s,cast(^Fsr_Runtime)user,.Prepare_Reactivity) {return}
    render.pass_resource(s,2,RECONSTRUCTED_DEPTH)
    render.pass_resource(s,3,DILATED_MOTION)
    render.pass_resource(s,4,DILATED_DEPTH)
    render.pass_resource(s,5,.Reactive)
    render.pass_resource(s,6,COMPOSITION_MASK)
    render.pass_resource(s,7,ACCUMULATION,previous=true)
    render.pass_resource(s,8,SHADING_CHANGE)
    render.pass_resource(s,9,LUMA)
    render.pass_resource(s,10,INPUT_EXPOSURE)
    render.pass_resource(s,11,DILATED_REACTIVE)
    render.pass_resource(s,12,NEW_LOCKS)
    render.pass_resource(s,13,ACCUMULATION)
    render.pass_dispatch(s,groups(s.width,8),groups(s.height,8))
}

@(private)
fsr_luma_instability_record :: proc(s:^render.Pass,user:rawptr) {
    if !fsr_begin(s,cast(^Fsr_Runtime)user,.Luma_Instability) {return}
    render.pass_resource(s,2,INPUT_EXPOSURE)
    render.pass_resource(s,3,DILATED_REACTIVE)
    render.pass_resource(s,4,DILATED_MOTION)
    render.pass_resource(s,5,FRAME_INFO)
    render.pass_resource(s,6,LUMA_HISTORY,previous=true)
    render.pass_resource(s,7,FARTHEST_DEPTH_MIP1)
    render.pass_resource(s,8,LUMA)
    render.pass_resource(s,9,LUMA_HISTORY)
    render.pass_resource(s,10,LUMA_INSTABILITY)
    render.pass_dispatch(s,groups(s.width,8),groups(s.height,8))
}

@(private)
fsr_accumulate_record :: proc(s:^render.Pass,user:rawptr) {
    state:=cast(^Fsr_Runtime)user
    if !fsr_begin(s,state,.Accumulate_Sharpen if state.sharpness>0 else .Accumulate) {return}
    render.pass_resource(s,2,INPUT_EXPOSURE)
    render.pass_resource(s,3,DILATED_REACTIVE)
    render.pass_resource(s,4,DILATED_MOTION)
    render.pass_resource(s,5,INTERNAL,previous=true)
    render.pass_resource(s,7,FARTHEST_DEPTH_MIP1)
    render.pass_resource(s,8,LUMA)
    render.pass_resource(s,9,LUMA_INSTABILITY)
    render.pass_resource(s,10,.Display)
    render.pass_resource(s,11,INTERNAL)
    if state.sharpness<=0 {render.pass_resource(s,12,.Taa)}
    render.pass_resource(s,13,NEW_LOCKS)
    render.pass_dispatch(s,groups(s.output_width,8),groups(s.output_height,8))
}

@(private)
fsr_rcas_record :: proc(s:^render.Pass,user:rawptr) {
    state:=cast(^Fsr_Runtime)user
    if !fsr_begin(s,state,.Rcas) {return}
    config:=fsr3_rcas_constants(state.sharpness)
    if !render.pass_constants(s,1,&config,size_of(config)) {return}
    render.pass_resource(s,2,INPUT_EXPOSURE)
    render.pass_resource(s,3,INTERNAL)
    render.pass_resource(s,4,.Taa)
    render.pass_dispatch(s,groups(s.output_width,16),groups(s.output_height,16))
}
