package fsr

import "core:math"
import render "mirai:engine/render"

// AMD FidelityFX FSR 3.1.4 frame generation (MIT): while the graphics settings
// ask for it (Graphics_Settings.frame_generation), the passes of
// ffx_opticalflow.cpp and of ffxFrameInterpolationPrepare and
// ffxFrameInterpolationDispatch of ffx_frameinterpolation.cpp, in their order,
// come after the Output stage. From the final image of this frame and that of
// the frame before, the motion of the game and the optical flow between both,
// they interpolate the image the window shows between them (Generated). AMD's
// HLSL is in shaders/fsr3/opticalflow and frameinterpolation; the passes bind
// their resources at the slots their entries (shaders/fsr3_of_*.comp.slang and
// fsr3_fi_*.comp.slang) name.

Fg_Pass :: enum u8 {
    Of_Prepare_Luma,Of_Luma_Pyramid,Of_Scd_Histogram,Of_Scd_Divergence,Of_Search,Of_Filter,Of_Scale,
    Fi_Reconstruct_And_Dilate,Fi_Setup,Fi_Reconstruct_Previous_Depth,Fi_Game_Motion_Vector_Field,Fi_Game_Vector_Field_Pyramid,
    Fi_Optical_Flow_Vector_Field,Fi_Disocclusion_Mask,Fi_Interpolation,Fi_Inpainting_Pyramid,Fi_Inpainting,Fi_Copy,
}
FG_SHADERS :: [Fg_Pass]string{
    .Of_Prepare_Luma="fsr3_of_prepare_luma",.Of_Luma_Pyramid="fsr3_of_luma_pyramid",.Of_Scd_Histogram="fsr3_of_scd_histogram",
    .Of_Scd_Divergence="fsr3_of_scd_divergence",.Of_Search="fsr3_of_search",.Of_Filter="fsr3_of_filter",.Of_Scale="fsr3_of_scale",
    .Fi_Reconstruct_And_Dilate="fsr3_fi_reconstruct_and_dilate",.Fi_Setup="fsr3_fi_setup",
    .Fi_Reconstruct_Previous_Depth="fsr3_fi_reconstruct_previous_depth",.Fi_Game_Motion_Vector_Field="fsr3_fi_game_motion_vector_field",
    .Fi_Game_Vector_Field_Pyramid="fsr3_fi_game_vector_field_pyramid",.Fi_Optical_Flow_Vector_Field="fsr3_fi_optical_flow_vector_field",
    .Fi_Disocclusion_Mask="fsr3_fi_disocclusion_mask",.Fi_Interpolation="fsr3_fi_interpolation",
    .Fi_Inpainting_Pyramid="fsr3_fi_inpainting_pyramid",.Fi_Inpainting="fsr3_fi_inpainting",.Fi_Copy="fsr3_fi_copy",
}

// The resources of the passes, with the formats ffx_opticalflow.cpp and
// ffx_frameinterpolation.cpp give them; FSR 3.1 upscaling takes Custom0 to
// Custom17. The passes dispatch whole groups that store past the sizes AMD
// gives, which D3D12 drops: the sizes are rounded up so those stores land
// inside. Those the shaders sample by UV keep the size of the view.
OF_INPUT :: render.Render_Resource.Custom18                  // the luma of the image and its levels; the previous copy, that of the frame before
OF_SEARCH :: render.Render_Resource.Custom19                 // the motion of the blocks of each level, searched from what the coarser one carries down
OF_FILTERED :: render.Render_Resource.Custom20               // that motion filtered
OF_VECTOR :: render.Render_Resource.Custom21                 // the optical flow of the finest level, in pixels of the display
OF_SCD_HISTOGRAM :: render.Render_Resource.Custom22
OF_SCD_PREVIOUS_HISTOGRAM :: render.Render_Resource.Custom23
OF_SCD_TEMP :: render.Render_Resource.Custom24
OF_SCD_OUTPUT :: render.Render_Resource.Custom25             // the scene change of this frame and those of the frames before
FI_DILATED_DEPTH :: render.Render_Resource.Custom26
FI_DILATED_MOTION :: render.Render_Resource.Custom27
FI_PREVIOUS_DEPTH :: render.Render_Resource.Custom28         // the depth of the frame before, reconstructed
FI_INTERPOLATED_DEPTH :: render.Render_Resource.Custom29     // the depth of the frame in between, reconstructed
FI_GAME_X :: render.Render_Resource.Custom30                 // the field of the motion of the game at the frame in between
FI_GAME_Y :: render.Render_Resource.Custom31
FI_FLOW_X :: render.Render_Resource.Custom32                 // the field of the optical flow at the frame in between
FI_FLOW_Y :: render.Render_Resource.Custom33
FI_DISOCCLUSION :: render.Render_Resource.Custom34
FI_PYRAMID :: render.Render_Resource.Custom35                // the inpainting pyramid, of the vector field and then of the image
FI_COUNTERS :: render.Render_Resource.Custom36               // the atomic of SPD and the frames since the last reset
FI_PREVIOUS_SOURCE :: render.Render_Resource.Custom37        // the final image of the frame before
FI_DISTORTION :: render.Render_Resource.Custom38             // the default distortion field: none

// advancedAlgorithmIterations, OpticalFlowMaxPyramidLevels and the scene
// change histograms of ffx_opticalflow.cpp.
OF_LEVELS :: 7
OF_SPD_MIPS :: 4
OF_SCD_STRATA :: 3
OF_SCD_SHIFTS :: 3
OF_SCD_BINS :: 256*OF_SCD_STRATA*OF_SCD_STRATA
// opticalFlowBlockSize of ffx_provider_framegeneration.cpp.
FG_OF_BLOCK :: 8
// The inpainting pyramid the passes bind: thirteen levels.
FI_PYRAMID_MIPS :: 13
// FFX_BACKBUFFER_TRANSFER_FUNCTION_SRGB: the final image is sRGB encoded.
FG_TRANSFER_SRGB :: 0

FG_RESOURCES :: [?]render.Render_Resource_Desc{
    {id=OF_INPUT,format=.R8_Uint,size=.Output,align=64,mips=OF_LEVELS,history=true},
    {id=OF_SEARCH,format=.RG16_Sint,size=.Output,shift=3,align=128,mips=OF_LEVELS},
    {id=OF_FILTERED,format=.RG16_Sint,size=.Output,shift=3,align=128,mips=OF_LEVELS},
    {id=OF_VECTOR,format=.RG16_Sint,size=.Output,shift=3},
    {id=OF_SCD_HISTOGRAM,format=.R32_Uint,size=.Fixed,width=OF_SCD_BINS,height=1,kept=true},
    {id=OF_SCD_PREVIOUS_HISTOGRAM,format=.R32_Float,size=.Fixed,width=OF_SCD_BINS,height=1,kept=true},
    {id=OF_SCD_TEMP,format=.R32_Uint,size=.Fixed,width=3,height=1,kept=true},
    {id=OF_SCD_OUTPUT,format=.R32_Uint,size=.Fixed,width=3,height=1,kept=true},
    {id=FI_DILATED_DEPTH,format=.R32_Float,align=8},
    {id=FI_DILATED_MOTION,format=.RG16_Float,align=8},
    {id=FI_PREVIOUS_DEPTH,format=.R32_Uint,align=8},
    {id=FI_INTERPOLATED_DEPTH,format=.R32_Uint,align=8},
    {id=FI_GAME_X,format=.R32_Uint,align=8},
    {id=FI_GAME_Y,format=.R32_Uint,align=8},
    {id=FI_FLOW_X,format=.R32_Uint,align=8},
    {id=FI_FLOW_Y,format=.R32_Uint,align=8},
    {id=FI_DISOCCLUSION,format=.RG8_Unorm,align=8},
    {id=FI_PYRAMID,format=.RGBA16_Float,size=.Output,shift=1,align=32,mips=render.RENDER_MIPS_ALL},
    {id=FI_COUNTERS,bytes=8,kept=true},
    {id=FI_PREVIOUS_SOURCE,format=.RGBA8_Unorm,size=.Output,kept=true},
    {id=FI_DISTORTION,format=.RG8_Unorm,size=.Fixed,width=1,height=1,kept=true},
}

// The passes that generate a frame after the Output stage, and their resources.
fg_append :: proc(passes:^[dynamic]render.Render_Pass_Desc,resources:^[dynamic]render.Render_Resource_Desc,state:^Fsr_Runtime) {
    @(static,rodata) optical_flow_uses:=[?]Use{
        {.Ldr,.Read,false},{OF_INPUT,.Read,true},{OF_INPUT,.Write,false},{OF_SEARCH,.Write,false},{OF_FILTERED,.Write,false},{OF_VECTOR,.Write,false},
        {OF_SCD_HISTOGRAM,.Write,false},{OF_SCD_PREVIOUS_HISTOGRAM,.Write,false},{OF_SCD_TEMP,.Write,false},{OF_SCD_OUTPUT,.Write,false},
    }
    @(static,rodata) prepare_uses:=[?]Use{
        {.Motion,.Read,false},{.Depth,.Read,false},{FI_PREVIOUS_DEPTH,.Write,false},{FI_DILATED_MOTION,.Write,false},{FI_DILATED_DEPTH,.Write,false},
    }
    @(static,rodata) fields_uses:=[?]Use{
        {OF_SCD_OUTPUT,.Read,false},{OF_VECTOR,.Read,false},{FI_DILATED_MOTION,.Read,false},{FI_DILATED_DEPTH,.Read,false},
        {FI_PREVIOUS_DEPTH,.Read,false},{.Ldr,.Read,false},{FI_PREVIOUS_SOURCE,.Read,false},{FI_DISTORTION,.Read,false},
        {FI_GAME_X,.Write,false},{FI_GAME_Y,.Write,false},{FI_FLOW_X,.Write,false},{FI_FLOW_Y,.Write,false},
        {FI_DISOCCLUSION,.Write,false},{FI_COUNTERS,.Write,false},{FI_INTERPOLATED_DEPTH,.Write,false},{FI_PYRAMID,.Write,false},
    }
    @(static,rodata) interpolate_uses:=[?]Use{
        {FI_GAME_X,.Read,false},{FI_GAME_Y,.Read,false},{FI_FLOW_X,.Read,false},{FI_FLOW_Y,.Read,false},{FI_DISOCCLUSION,.Read,false},
        {OF_SCD_OUTPUT,.Read,false},{.Ldr,.Read,false},{FI_COUNTERS,.Write,false},{FI_PYRAMID,.Write,false},{.Generated,.Write,false},
        {FI_PREVIOUS_SOURCE,.Write,false},
    }
    @(static,rodata) fg_resources:=FG_RESOURCES
    append(resources,..fg_resources[:])
    append(passes,
        render.Render_Pass_Desc{stage=.Custom,name="fsr3 optical flow",uses=optical_flow_uses[:],record=fg_optical_flow_record,user=state},
        render.Render_Pass_Desc{stage=.Custom,name="fsr3 fi prepare",uses=prepare_uses[:],record=fg_prepare_record,user=state},
        render.Render_Pass_Desc{stage=.Custom,name="fsr3 fi fields",uses=fields_uses[:],record=fg_fields_record,user=state},
        render.Render_Pass_Desc{stage=.Custom,name="fsr3 fi interpolate",uses=interpolate_uses[:],record=fg_interpolate_record,user=state},
    )
}

// OpticalflowConstants of ffx_opticalflow_private.h, as cbOF of
// ffx_opticalflow_callbacks_hlsl.h lays it out.
Of_Constants :: struct {
    input_luma_resolution:        [2]i32,
    pyramid_level:                u32,
    pyramid_level_count:          u32,
    frame_index:                  i32,
    backbuffer_transfer_function: u32,
    min_max_luminance:            [2]f32, // nits of the display, which only PQ and scRGB read
}
#assert(size_of(Of_Constants)==32)

// OpticalFlowSpdConstants of ffx_opticalflow.cpp, as cbOF_SPD.
Of_Spd_Constants :: struct {
    mips:                    u32,
    work_groups:             u32,
    work_group_offset:       [2]u32,
    work_groups_input_pyramid:u32,
    pad:                     [3]u32,
}
#assert(size_of(Of_Spd_Constants)==32)

// FrameInterpolationConstants of ffx_frameinterpolation_private.h, as cbFI of
// ffx_frameinterpolation_callbacks_hlsl.h lays it out.
Fi_Constants :: struct {
    render_size:                   [2]i32,
    display_size:                  [2]i32,
    display_size_rcp:              [2]f32,
    camera_near:                   f32,
    camera_far:                    f32,
    upscaler_target_size:          [2]i32,
    mode:                          i32,
    reset:                         i32,
    device_to_view_depth:          [4]f32,
    delta_time:                    f32, // milliseconds
    hud_less_attached_factor:      i32,
    distortion_field_size:         [2]i32,
    optical_flow_scale:            [2]f32,
    optical_flow_block_size:       i32,
    dispatch_flags:                u32,
    max_render_size:               [2]i32,
    optical_flow_half_res_mode:    i32,
    num_instances:                 i32,
    interpolation_rect_base:       [2]i32,
    interpolation_rect_size:       [2]i32,
    debug_bar_color:               [3]f32,
    back_buffer_transfer_function: u32,
    min_max_luminance:             [2]f32, // nits of the display, which only PQ and scRGB read
    tan_half_fov:                  f32,
    pad:                           i32,
    jitter:                        [2]f32,
    motion_vector_scale:           [2]f32,
}
#assert(size_of(Fi_Constants)==176)

// InpaintingPyramidConstants of ffx_frameinterpolation_private.h, as cbInpaintingPyramid.
Fi_Pyramid_Constants :: struct {
    mips:              u32,
    work_groups:       u32,
    work_group_offset: [2]u32,
}
#assert(size_of(Fi_Pyramid_Constants)==16)

// The constants of the frame, as ffxFrameInterpolationPrepare and
// ffxFrameInterpolationDispatch fill them for the whole display, without the
// image without the interface (HUDLessAttachedFactor 0) nor a distortion
// field. The motion of the G-buffer is an offset in UV already.
fi_constants :: proc(s:^render.Pass) -> Fi_Constants {
    depth,tan_half_fov:=fsr3_view_depth(s)
    size:=[2]i32{i32(s.width),i32(s.height)}
    display:=[2]i32{i32(s.output_width),i32(s.output_height)}
    return {
        render_size=size,display_size=display,display_size_rcp={1/f32(display.x),1/f32(display.y)},
        camera_near=s.camera.near,camera_far=s.camera.far if s.camera.far>0 else math.F32_MAX,
        upscaler_target_size=display,reset=0 if s.history else 1,
        device_to_view_depth=depth,delta_time=s.delta_time*1000,distortion_field_size={1,1},
        optical_flow_scale={1/f32(display.x),1/f32(display.y)},optical_flow_block_size=FG_OF_BLOCK,
        // The size of the resources at the render size.
        max_render_size={(size.x+7)/8*8,(size.y+7)/8*8},
        interpolation_rect_size=display,back_buffer_transfer_function=FG_TRANSFER_SRGB,
        tan_half_fov=tan_half_fov,jitter={s.jitter.x,s.jitter.y},motion_vector_scale={1,1},
    }
}

// ffxSpdSetup of ffx_spd.h over a rectangle at the corner: its groups and its levels.
fg_spd :: proc(width,height:u32) -> (groups_x,groups_y,levels:u32) {
    groups_x,groups_y=(max(width,1)-1)/64+1,(max(height,1)-1)/64+1
    levels=u32(min(math.floor(math.log2(f32(max(width,height,1)))),12))
    return
}

// The levels FI_PYRAMID has: half the display rounded up to 32, as
// FG_RESOURCES declares it, down to one texel.
fi_pyramid_levels :: proc(s:^render.Pass) -> i32 {
    width,height:=((s.output_width+1)/2+31)/32*32,((s.output_height+1)/2+31)/32*32
    levels:=i32(1)
    for max(width,height)>>u32(levels)>0 && levels<FI_PYRAMID_MIPS {levels+=1}
    return levels
}

// The thirteen levels a pass of SPD writes, from a slot on: those past the
// last of the pyramid take the last, which SPD does not reach.
@(private="file")
fi_pyramid_bind :: proc(s:^render.Pass,first:u32) {
    levels:=fi_pyramid_levels(s)
    for mip in 0..<i32(FI_PYRAMID_MIPS) {render.pass_resource(s,first+u32(mip),FI_PYRAMID,mip=min(mip,levels-1))}
}

// ffxOpticalflowContextDispatch over the final image at the size of the
// display: the luma and its levels, the scene change, and the search of the
// motion from the coarsest level to the finest.
@(private)
fg_optical_flow_record :: proc(s:^render.Pass,user:rawptr) {
    pipelines:=&(cast(^Fsr_Runtime)user).framegen
    width,height:=s.output_width,s.output_height
    constants:=Of_Constants{
        input_luma_resolution={i32(width),i32(height)},pyramid_level_count=OF_LEVELS,
        frame_index=i32(s.history_frames),backbuffer_transfer_function=FG_TRANSFER_SRGB,
    }
    groups_x,groups_y,_:=fg_spd(width,height)
    spd:=Of_Spd_Constants{mips=OF_SPD_MIPS,work_groups=groups_x*groups_y,work_groups_input_pyramid=groups_x*groups_y}
    if !render.pass_constants(s,0,&constants,size_of(constants)) || !render.pass_constants(s,1,&spd,size_of(spd)) {return}

    render.pass_pipeline(s,pipelines[.Of_Prepare_Luma])
    render.pass_resource(s,2,.Ldr)
    render.pass_resource(s,3,OF_INPUT,mip=0)
    render.pass_dispatch(s,groups((width+1)/2,16),groups((height+1)/2,16))

    render.pass_pipeline(s,pipelines[.Of_Luma_Pyramid])
    for level in 0..<OF_LEVELS {render.pass_resource(s,2+u32(level),OF_INPUT,mip=i32(level))}
    render.pass_dispatch(s,groups_x,groups_y)

    render.pass_pipeline(s,pipelines[.Of_Scd_Histogram])
    render.pass_resource(s,2,OF_INPUT,mip=0)
    render.pass_resource(s,3,OF_SCD_HISTOGRAM)
    render.pass_dispatch(s,groups(width/4/OF_SCD_STRATA,32),16,OF_SCD_STRATA*OF_SCD_STRATA)

    render.pass_pipeline(s,pipelines[.Of_Scd_Divergence])
    render.pass_resource(s,2,OF_SCD_HISTOGRAM)
    render.pass_resource(s,3,OF_SCD_PREVIOUS_HISTOGRAM)
    render.pass_resource(s,4,OF_SCD_TEMP)
    render.pass_resource(s,5,OF_SCD_OUTPUT)
    render.pass_dispatch(s,OF_SCD_STRATA*OF_SCD_STRATA,OF_SCD_SHIFTS)

    // Each level searches from the motion the coarser one carries down to it,
    // filters it and carries it to the finer one; the finest leaves it in OF_VECTOR.
    sizes:[OF_LEVELS][2]u32
    sizes[0]={groups(width,FG_OF_BLOCK),groups(height,FG_OF_BLOCK)}
    for level in 1..<OF_LEVELS {sizes[level]=(sizes[level-1]+1)/2}
    for level:=OF_LEVELS-1;level>=0;level-=1 {
        constants.pyramid_level=u32(level)
        if !render.pass_constants(s,0,&constants,size_of(constants)) {return}
        mip:=i32(level)
        luma:=[2]u32{max(width>>u32(level),1),max(height>>u32(level),1)}
        render.pass_pipeline(s,pipelines[.Of_Search])
        render.pass_resource(s,2,OF_INPUT,mip=mip)
        render.pass_resource(s,3,OF_INPUT,previous=true,mip=mip)
        render.pass_resource(s,4,OF_SEARCH,mip=mip)
        render.pass_resource(s,5,OF_SCD_OUTPUT)
        render.pass_dispatch(s,groups((luma.x+3)/4*16,64),groups(luma.y,16))

        render.pass_pipeline(s,pipelines[.Of_Filter])
        render.pass_resource(s,2,OF_SEARCH,mip=mip)
        if level==0 {render.pass_resource(s,3,OF_VECTOR)} else {render.pass_resource(s,3,OF_FILTERED,mip=mip)}
        render.pass_dispatch(s,groups(sizes[level].x,16),groups(sizes[level].y,4))
        if level==0 {break}

        render.pass_pipeline(s,pipelines[.Of_Scale])
        render.pass_resource(s,2,OF_INPUT,mip=mip)
        render.pass_resource(s,3,OF_INPUT,previous=true,mip=mip)
        render.pass_resource(s,4,OF_FILTERED,mip=mip)
        render.pass_resource(s,5,OF_SEARCH,mip=mip-1)
        render.pass_resource(s,6,OF_SCD_OUTPUT)
        render.pass_dispatch(s,groups(sizes[level-1].x,4),groups(sizes[level-1].y,4))
    }
}

// ffxFrameInterpolationPrepare: the depth and the motion dilated, and the
// depth of the frame before reconstructed from them.
@(private)
fg_prepare_record :: proc(s:^render.Pass,user:rawptr) {
    pipelines:=&(cast(^Fsr_Runtime)user).framegen
    // The reversed depth reconstructed starts at the far plane.
    render.pass_clear(s,FI_PREVIOUS_DEPTH)
    render.pass_pipeline(s,pipelines[.Fi_Reconstruct_And_Dilate])
    constants:=fi_constants(s)
    if !render.pass_constants(s,0,&constants,size_of(constants)) {return}
    render.pass_resource(s,2,.Motion)
    render.pass_resource(s,3,.Depth)
    render.pass_resource(s,4,FI_PREVIOUS_DEPTH)
    render.pass_resource(s,5,FI_DILATED_MOTION)
    render.pass_resource(s,6,FI_DILATED_DEPTH)
    render.pass_dispatch(s,groups(s.width,8),groups(s.height,8))
}

// The passes of ffxFrameInterpolationDispatch before the interpolation: the
// setup and, unless the history starts again, the fields of the motion of the
// game and of the optical flow at the frame in between and its disocclusion.
@(private)
fg_fields_record :: proc(s:^render.Pass,user:rawptr) {
    pipelines:=&(cast(^Fsr_Runtime)user).framegen
    if s.history {render.pass_clear(s,FI_INTERPOLATED_DEPTH)}
    constants:=fi_constants(s)
    render.pass_pipeline(s,pipelines[.Fi_Setup])
    if !render.pass_constants(s,0,&constants,size_of(constants)) {return}
    render.pass_resource(s,2,OF_SCD_OUTPUT)
    render.pass_resource(s,3,FI_GAME_X)
    render.pass_resource(s,4,FI_GAME_Y)
    render.pass_resource(s,5,FI_FLOW_X)
    render.pass_resource(s,6,FI_FLOW_Y)
    render.pass_resource(s,7,FI_DISOCCLUSION)
    render.pass_resource(s,8,FI_COUNTERS)
    groups_x,groups_y:=groups(s.width,8),groups(s.height,8)
    render.pass_dispatch(s,groups_x,groups_y)
    if !s.history {return}

    render.pass_pipeline(s,pipelines[.Fi_Reconstruct_Previous_Depth])
    render.pass_resource(s,2,FI_DILATED_MOTION)
    render.pass_resource(s,3,FI_DILATED_DEPTH)
    render.pass_resource(s,4,.Ldr)
    render.pass_resource(s,5,FI_DISTORTION)
    render.pass_resource(s,6,FI_INTERPOLATED_DEPTH)
    render.pass_dispatch(s,groups_x,groups_y)

    render.pass_pipeline(s,pipelines[.Fi_Game_Motion_Vector_Field])
    render.pass_resource(s,2,FI_DILATED_MOTION)
    render.pass_resource(s,3,FI_DILATED_DEPTH)
    render.pass_resource(s,4,FI_PREVIOUS_SOURCE)
    render.pass_resource(s,5,.Ldr)
    render.pass_resource(s,6,FI_DISTORTION)
    render.pass_resource(s,7,FI_GAME_X)
    render.pass_resource(s,8,FI_GAME_Y)
    render.pass_dispatch(s,groups_x,groups_y)

    spd_x,spd_y,levels:=fg_spd(s.width,s.height)
    pyramid:=Fi_Pyramid_Constants{mips=levels,work_groups=spd_x*spd_y}
    if !render.pass_constants(s,1,&pyramid,size_of(pyramid)) {return}
    render.pass_pipeline(s,pipelines[.Fi_Game_Vector_Field_Pyramid])
    render.pass_resource(s,2,FI_GAME_X)
    render.pass_resource(s,3,FI_GAME_Y)
    render.pass_resource(s,4,FI_COUNTERS)
    fi_pyramid_bind(s,5)
    render.pass_dispatch(s,spd_x,spd_y)

    // The optical flow has no confidence (FFX_FRAMEINTERPOLATION_RESOURCE_IDENTIFIER_OPTICAL_FLOW_CONFIDENCE
    // is not registered and the pass does not use what it reads): its slot takes a texture of uints.
    render.pass_pipeline(s,pipelines[.Fi_Optical_Flow_Vector_Field])
    render.pass_resource(s,2,OF_VECTOR)
    render.pass_resource(s,3,FI_GAME_X)
    render.pass_resource(s,4,FI_DILATED_DEPTH)
    render.pass_resource(s,5,FI_PREVIOUS_SOURCE)
    render.pass_resource(s,6,.Ldr)
    render.pass_resource(s,7,FI_FLOW_X)
    render.pass_resource(s,8,FI_FLOW_Y)
    render.pass_dispatch(s,groups(s.output_width/FG_OF_BLOCK,8),groups(s.output_height/FG_OF_BLOCK,8))

    render.pass_pipeline(s,pipelines[.Fi_Disocclusion_Mask])
    render.pass_resource(s,2,FI_GAME_X)
    render.pass_resource(s,3,FI_GAME_Y)
    render.pass_resource(s,4,FI_PREVIOUS_DEPTH)
    render.pass_resource(s,5,FI_DILATED_DEPTH)
    render.pass_resource(s,6,FI_INTERPOLATED_DEPTH)
    render.pass_resource(s,7,FI_PYRAMID)
    render.pass_resource(s,8,FI_DISTORTION)
    render.pass_resource(s,9,FI_DISOCCLUSION)
    render.pass_dispatch(s,groups_x,groups_y)
}

// The rest of ffxFrameInterpolationDispatch: the interpolation into
// Generated, its inpainting, and the copy of the final image the next frame
// interpolates from.
@(private)
fg_interpolate_record :: proc(s:^render.Pass,user:rawptr) {
    pipelines:=&(cast(^Fsr_Runtime)user).framegen
    constants:=fi_constants(s)
    render.pass_pipeline(s,pipelines[.Fi_Interpolation])
    if !render.pass_constants(s,0,&constants,size_of(constants)) {return}
    render.pass_resource(s,2,FI_GAME_X)
    render.pass_resource(s,3,FI_GAME_Y)
    render.pass_resource(s,4,FI_FLOW_X)
    render.pass_resource(s,5,FI_FLOW_Y)
    render.pass_resource(s,6,FI_PREVIOUS_SOURCE)
    render.pass_resource(s,7,.Ldr)
    render.pass_resource(s,8,FI_DISOCCLUSION)
    render.pass_resource(s,9,FI_PYRAMID)
    render.pass_resource(s,10,FI_COUNTERS)
    render.pass_resource(s,11,.Generated)
    groups_x,groups_y:=groups(s.output_width,8),groups(s.output_height,8)
    render.pass_dispatch(s,groups_x,groups_y)

    spd_x,spd_y,levels:=fg_spd(s.output_width,s.output_height)
    pyramid:=Fi_Pyramid_Constants{mips=levels,work_groups=spd_x*spd_y}
    if !render.pass_constants(s,1,&pyramid,size_of(pyramid)) {return}
    render.pass_pipeline(s,pipelines[.Fi_Inpainting_Pyramid])
    render.pass_resource(s,2,.Generated)
    render.pass_resource(s,3,FI_COUNTERS)
    fi_pyramid_bind(s,4)
    render.pass_dispatch(s,spd_x,spd_y)

    render.pass_pipeline(s,pipelines[.Fi_Inpainting])
    render.pass_resource(s,2,OF_SCD_OUTPUT)
    render.pass_resource(s,3,FI_PYRAMID)
    render.pass_resource(s,4,.Ldr)
    render.pass_resource(s,5,.Ldr)
    render.pass_resource(s,6,.Generated)
    render.pass_dispatch(s,groups_x,groups_y)

    render.pass_pipeline(s,pipelines[.Fi_Copy])
    render.pass_resource(s,2,.Ldr)
    render.pass_resource(s,3,FI_PREVIOUS_SOURCE)
    render.pass_dispatch(s,groups_x,groups_y)
}
