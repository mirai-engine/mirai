package rdo

import "base:runtime"
import "core:slice"
import "mirai:std/jobs"
import "../bc7enc"
import "../rgbcx"

Format :: enum u8 {BC1,BC3,BC4,BC5,BC7}

Params :: struct {
    bc7_uber_level:int,
    bc7enc_max_partitions_to_scan:int,
    perceptual:bool,
    bc45_channel0,bc45_channel1:u32,
    bc1_mode:rgbcx.Bc1_Approx_Mode,
    use_bc1_3color_mode:bool,
    use_bc1_3color_mode_for_black:bool,
    bc1_quality_level:int,
    rdo_lambda:f32,
    rdo_smooth_block_error_scale:f32,
    custom_rdo_smooth_block_error_scale:bool,
    lookback_window_size:u32,
    custom_lookback_window_size:bool,
    bc7enc_rdo_bc7_quant_mode6_endpoints:bool,
    bc7enc_rdo_bc7_weight_modes:bool,
    bc7enc_rdo_bc7_weight_low_frequency_partitions:bool,
    bc7enc_rdo_bc7_pbit1_weighting:bool,
    rdo_max_smooth_block_std_dev:f32,
    rdo_allow_relative_movement:bool,
    rdo_try_2_matches:bool,
    rdo_ultrasmooth_block_handling:bool,
    use_hq_bc345:bool,
    bc345_search_rad:int,
    bc345_mode_mask:u32,
    bc7enc_mode6_only:bool,
    bc7enc_reduce_entropy:bool,
}

params_default :: proc() -> Params {
    return {
        bc7_uber_level=6,
        bc7enc_max_partitions_to_scan=bc7enc.MAX_PARTITIONS,
        bc45_channel1=1,
        bc1_mode=.Ideal,
        use_bc1_3color_mode=true,
        use_bc1_3color_mode_for_black=true,
        bc1_quality_level=rgbcx.MAX_LEVEL,
        rdo_smooth_block_error_scale=15,
        lookback_window_size=128,
        bc7enc_rdo_bc7_quant_mode6_endpoints=true,
        bc7enc_rdo_bc7_weight_modes=true,
        bc7enc_rdo_bc7_weight_low_frequency_partitions=true,
        bc7enc_rdo_bc7_pbit1_weighting=true,
        rdo_max_smooth_block_std_dev=18,
        rdo_try_2_matches=true,
        rdo_ultrasmooth_block_handling=true,
        use_hq_bc345=true,
        bc345_search_rad=5,
        bc345_mode_mask=rgbcx.BC4_USE_ALL_MODES,
    }
}

@(private="file") MIN_RDO_CHUNKED_BLOCKS :: 4096
@(private="file") RDO_CHUNKS :: 128 // upstream's default m_rdo_max_threads; never the core count, so the output does not depend on it

@(private="file")
Source :: struct {
    texels:[]Color_Rgba,
    width,height,blocks_x,blocks_y:int,
}

@(private="file")
source_block :: #force_inline proc(s:^Source,bx,by:int,block:^[16]Color_Rgba) {
    #no_bounds_check for y in 0..<4 {
        row:=min(by*4+y,s.height-1)*s.width
        for x in 0..<4 {
            block[x+y*4]=s.texels[row+min(bx*4+x,s.width-1)]
        }
    }
}

@(private="file")
Encode_Work :: struct {
    format:Format,
    source:Source,
    params:^Params,
    bc7_params:^bc7enc.Params,
    bc1_tables:^rgbcx.Tables,
    bc7_tables:^bc7enc.Tables,
    out:[]u8,
    bytes_per_block:int,
}

@(private="file")
encode_rows :: proc(data:rawptr,first,last,worker:int) {
    w:=cast(^Encode_Work)data
    p:=w.params
    level:=u32(p.bc1_quality_level)
    search_rad:=u32(p.bc345_search_rad)
    for by in first..<last {
        for bx in 0..<w.source.blocks_x {
            block:[16]Color_Rgba=---
            source_block(&w.source,bx,by,&block)
            texels:=([^]u8)(&block[0][0])
            dst:=([^]u8)(&w.out[(bx+by*w.source.blocks_x)*w.bytes_per_block])
            switch w.format {
            case .BC1:
                rgbcx.encode_bc1(w.bc1_tables,level,dst,texels,p.use_bc1_3color_mode,p.use_bc1_3color_mode_for_black)
            case .BC3:
                if p.use_hq_bc345 {
                    rgbcx.encode_bc3_hq(w.bc1_tables,level,dst,texels,search_rad,p.bc345_mode_mask)
                } else {
                    rgbcx.encode_bc3(w.bc1_tables,level,dst,texels)
                }
            case .BC4:
                channel:=texels[p.bc45_channel0:]
                if p.use_hq_bc345 {
                    rgbcx.encode_bc4_hq(dst,channel,4,search_rad,p.bc345_mode_mask)
                } else {
                    rgbcx.encode_bc4(dst,channel,4)
                }
            case .BC5:
                if p.use_hq_bc345 {
                    rgbcx.encode_bc5_hq(dst,texels,p.bc45_channel0,p.bc45_channel1,4,search_rad,p.bc345_mode_mask)
                } else {
                    rgbcx.encode_bc5(dst,texels,p.bc45_channel0,p.bc45_channel1,4)
                }
            case .BC7:
                _=bc7enc.compress_block(w.bc7_tables,dst,texels,w.bc7_params)
            }
        }
    }
}

@(private="file")
init_bc7_params :: proc(bc7:^bc7enc.Params,params:Params,format:Format) {
    bc7enc.params_init(bc7)
    if !params.perceptual {bc7enc.params_init_linear_weights(bc7)}
    bc7.max_partitions=u32(params.bc7enc_max_partitions_to_scan)
    bc7.uber_level=u32(min(int(bc7enc.MAX_UBER_LEVEL),params.bc7_uber_level))

    if params.bc7enc_mode6_only {bc7.mode_mask=1<<6}

    if format==.BC7 && params.rdo_lambda>0 {
        // RDO measures linear error only.
        bc7.perceptual=false
        bc7enc.params_init_linear_weights(bc7)
    }

    if format==.BC7 && params.bc7enc_reduce_entropy {
        bc7.mode17_partition_estimation_filterbank=false
        // Upstream never sets m_has_alpha, so its weights for textures with alpha are unreachable.
        if params.bc7enc_rdo_bc7_weight_modes {bc7.mode6_error_weight=.4}
        if params.bc7enc_rdo_bc7_weight_low_frequency_partitions {bc7.low_frequency_partition_weight=.9999}
        if params.bc7enc_rdo_bc7_quant_mode6_endpoints {bc7.quant_mode6_endpoints=true}
        if params.bc7enc_rdo_bc7_pbit1_weighting {bc7.pbit1_weight=1.3}
    }
}

@(private="file")
Unpackers :: struct {
    mode:rgbcx.Bc1_Approx_Mode,
    allow_3color_mode:bool,
    use_bc1_3color_mode_for_black:bool,
}

@(private="file")
unpack_bc1_block :: proc(block:[^]u8,pixels:[^]Color_Rgba,block_index:u32,user:rawptr) -> bool {
    state:=cast(^Unpackers)user
    used_3color_mode:=rgbcx.unpack_bc1(block,([^]u8)(pixels),true,state.mode)
    if used_3color_mode {
        if !state.allow_3color_mode {return false}
        if !state.use_bc1_3color_mode_for_black {
            for y in 0..<4 {
                for x in 0..<4 {
                    if (block[4+y]>>(2*uint(x)))&3==3 {return false}
                }
            }
        }
    }
    return true
}

@(private="file")
unpack_bc4_block :: proc(block:[^]u8,pixels:[^]Color_Rgba,block_index:u32,user:rawptr) -> bool {
    slice.zero(pixels[:16])
    rgbcx.unpack_bc4(block,([^]u8)(pixels),4)
    return true
}

@(private="file")
unpack_bc7_block :: proc(block:[^]u8,pixels:[^]Color_Rgba,block_index:u32,user:rawptr) -> bool {
    return bc7enc.unpack_bc7(block,([^]u8)(pixels))
}

@(private="file")
compute_block_mse_scales :: proc(block_pixels:[]Color_Rgba,blocks_x,blocks_y:int,allocator:runtime.Allocator) -> (scales:[]f32,ok:bool) {
    ULTRASMOOTH_BLOCK_STD_DEV_THRESHOLD:f32:2.9
    DARK_THRESHOLD:f32:13
    BRIGHT_THRESHOLD:f32:222
    ULTRASMOOTH_BLOCK_MSE_SCALE:f32:120
    ULTRASMOOTH_REGION_TOO_SMALL_THRESHOLD :: 64
    GROW_PASSES :: 32

    total_blocks:=blocks_x*blocks_y
    err:runtime.Allocator_Error
    vis,next,orig:[]u8
    queue:[]int
    defer delete(vis,allocator)
    defer delete(next,allocator)
    defer delete(orig,allocator)
    defer delete(queue,allocator)
    if vis,err=make([]u8,total_blocks,allocator);err!=nil {return}
    if next,err=make([]u8,total_blocks,allocator);err!=nil {return}
    if orig,err=make([]u8,total_blocks,allocator);err!=nil {return}
    if queue,err=make([]int,total_blocks,allocator);err!=nil {return}
    if scales,err=make([]f32,total_blocks,allocator);err!=nil {return}

    neighbors_set :: #force_inline proc(vis:[]u8,blocks_x,blocks_y,x,y:int) -> (count:int) {
        for dy in -1..=1 {
            for dx in -1..=1 {
                if vis[clamp(x+dx,0,blocks_x-1)+clamp(y+dy,0,blocks_y-1)*blocks_x]==255 {count+=1}
            }
        }
        return
    }

    for cell in 0..<total_blocks {
        pixels:=([^]Color_Rgba)(&block_pixels[cell*16])
        total_luma:u32
        for i in 0..<16 {
            c:=pixels[i]
            total_luma+=(13938*u32(c[0])+46869*u32(c[1])+4729*u32(c[2])+32768)>>16
        }
        yl:=block_max_std_dev(pixels,16,3)/ULTRASMOOTH_BLOCK_STD_DEV_THRESHOLD
        yl=clamp(yl,0,1)
        yl*=yl
        y_avg:=f32(total_luma)/16
        if y_avg<DARK_THRESHOLD || y_avg>=BRIGHT_THRESHOLD {yl=1}
        vis[cell]=u8(min(int(yl*255+.5),255))
    }

    for y in 0..<blocks_y {
        for x in 0..<blocks_x {
            next[x+y*blocks_x]=neighbors_set(vis,blocks_x,blocks_y,x,y)>0?255:0
        }
    }
    vis,next=next,vis

    for _ in 0..<GROW_PASSES {
        copy(next,vis)
        changed:=false
        for y in 0..<blocks_y {
            for x in 0..<blocks_x {
                if vis[x+y*blocks_x]<255 && neighbors_set(vis,blocks_x,blocks_y,x,y)>=5 {
                    next[x+y*blocks_x]=255
                    changed=true
                }
            }
        }
        vis,next=next,vis
        if !changed {break}
    }

    copy(orig,vis)

    for start in 0..<total_blocks {
        if vis[start]!=0 {continue}
        vis[start]=255
        queue[0]=start
        tail:=1
        for head:=0;head<tail;head+=1 {
            cell:=queue[head]
            x:=cell%blocks_x
            if x>0 && vis[cell-1]==0 {vis[cell-1]=255;queue[tail]=cell-1;tail+=1}
            if x<blocks_x-1 && vis[cell+1]==0 {vis[cell+1]=255;queue[tail]=cell+1;tail+=1}
            if cell>=blocks_x && vis[cell-blocks_x]==0 {vis[cell-blocks_x]=255;queue[tail]=cell-blocks_x;tail+=1}
            if cell<total_blocks-blocks_x && vis[cell+blocks_x]==0 {vis[cell+blocks_x]=255;queue[tail]=cell+blocks_x;tail+=1}
        }
        if tail<ULTRASMOOTH_REGION_TOO_SMALL_THRESHOLD {
            for cell in queue[:tail] {orig[cell]=255}
        }
    }

    for cell in 0..<total_blocks {
        scales[cell]=orig[cell]==0?ULTRASMOOTH_BLOCK_MSE_SCALE:-1
    }
    return scales,true
}

@(private="file")
Rdo_Pass :: struct {
    offset,block_size,num_comps:int,
    pixels:[]Color_Rgba,
    params:Reduce_Entropy_Params,
    unpack:Unpack_Block_Proc,
    mse_scales:[]f32,
}

@(private="file")
Rdo_Work :: struct {
    blocks:[]u8,
    stride,total_blocks,chunk_count:int,
    passes:[2]Rdo_Pass,
    pass_count:int,
    unpackers:Unpackers,
}

@(private="file")
rdo_chunks :: proc(data:rawptr,first,last,worker:int) {
    w:=cast(^Rdo_Work)data
    chunk_blocks:=w.total_blocks/w.chunk_count
    for chunk in first..<last {
        start:=chunk*chunk_blocks
        count:=chunk==w.chunk_count-1?w.total_blocks-start:chunk_blocks
        if count==0 {continue}
        for &pass in w.passes[:w.pass_count] {
            scales:=pass.mse_scales
            if scales!=nil {scales=scales[start:][:count]}
            // A block the unpacker rejects ends its chunk, as upstream: the rest keeps its plain encoding.
            _,_=reduce_entropy(
                w.blocks[start*w.stride+pass.offset:(start+count)*w.stride],count,w.stride,pass.block_size,4,4,pass.num_comps,
                pass.pixels[start*16:(start+count)*16],pass.params,pass.unpack,&w.unpackers,scales,
            )
        }
    }
}

@(private="file")
channel_pixels :: proc(block_pixels:[]Color_Rgba,channel:u32,allocator:runtime.Allocator) -> (pixels:[]Color_Rgba,ok:bool) {
    err:runtime.Allocator_Error
    if pixels,err=make([]Color_Rgba,len(block_pixels),allocator);err!=nil {return}
    for c,i in block_pixels {pixels[i]={c[channel],0,0,0}}
    return pixels,true
}

@(private="file")
run_ranges :: proc(worker:jobs.Worker_Ref,count:int,procedure:jobs.Range_Proc,data:rawptr) {
    if worker.system!=nil {
        jobs.parallel_for(worker.system,worker.worker,count,1,procedure,data)
    } else {
        procedure(data,0,count,0)
    }
}

@(private="file")
postprocess_rdo :: proc(format:Format,source:^Source,params:^Params,out:[]u8,stride:int,worker:jobs.Worker_Ref,allocator:runtime.Allocator) -> bool {
    if !(params.rdo_lambda>0) {return true}
    total_blocks:=source.blocks_x*source.blocks_y

    ert:=reduce_entropy_params_default()
    ert.lambda=params.rdo_lambda
    ert.lookback_window_size=params.lookback_window_size
    ert.smooth_block_max_mse_scale=params.rdo_smooth_block_error_scale
    ert.max_smooth_block_std_dev=params.rdo_max_smooth_block_std_dev
    ert.try_two_matches=params.rdo_try_2_matches
    ert.allow_relative_movement=params.rdo_allow_relative_movement

    block_pixels,err:=make([]Color_Rgba,total_blocks*16,allocator)
    if err!=nil {return false}
    defer delete(block_pixels,allocator)
    for by in 0..<source.blocks_y {
        for bx in 0..<source.blocks_x {
            source_block(source,bx,by,cast(^[16]Color_Rgba)&block_pixels[(bx+by*source.blocks_x)*16])
        }
    }

    work:=Rdo_Work{
        blocks=out,
        stride=stride,
        total_blocks=total_blocks,
        chunk_count=total_blocks>=MIN_RDO_CHUNKED_BLOCKS?RDO_CHUNKS:1,
        unpackers={params.bc1_mode,params.use_bc1_3color_mode,params.use_bc1_3color_mode_for_black},
    }

    lambda:=params.rdo_lambda
    custom_scale:=params.custom_rdo_smooth_block_error_scale
    if format==.BC3 || format==.BC5 || format==.BC7 {ert.lookback_window_size=max(16,params.lookback_window_size)}

    // Upstream measures BC4 and BC5 against red and green whatever bc45_channel selects; here, the selected channels.
    first_channel,second_channel:[]Color_Rgba
    mse_scales:[]f32
    defer delete(first_channel,allocator)
    defer delete(second_channel,allocator)
    defer delete(mse_scales,allocator)
    ok:bool

    if params.rdo_ultrasmooth_block_handling && (format==.BC1 || format==.BC3 || format==.BC7) {
        if mse_scales,ok=compute_block_mse_scales(block_pixels,source.blocks_x,source.blocks_y,allocator);!ok {return false}
    }

    switch format {
    case .BC7:
        if !custom_scale {ert.smooth_block_max_mse_scale=lerpf(15,50,min(1,lambda/4))}
        ert.keep_extremes={3}
        work.passes[0]={0,16,4,block_pixels,ert,unpack_bc7_block,mse_scales}
        work.pass_count=1
    case .BC5:
        ert.color_weights={1,0,0,0}
        if !custom_scale {ert.smooth_block_max_mse_scale=lerpf(10,30,min(1,lambda/4))}
        if first_channel,ok=channel_pixels(block_pixels,params.bc45_channel0,allocator);!ok {return false}
        if second_channel,ok=channel_pixels(block_pixels,params.bc45_channel1,allocator);!ok {return false}
        work.passes[0]={0,8,1,first_channel,ert,unpack_bc4_block,nil}
        work.passes[1]={8,8,1,second_channel,ert,unpack_bc4_block,nil}
        work.pass_count=2
    case .BC4:
        ert.color_weights={1,0,0,0}
        if !custom_scale {ert.smooth_block_max_mse_scale=lerpf(10,30,min(1,lambda/4))}
        if first_channel,ok=channel_pixels(block_pixels,params.bc45_channel0,allocator);!ok {return false}
        work.passes[0]={0,8,1,first_channel,ert,unpack_bc4_block,nil}
        work.pass_count=1
    case .BC1:
        ert.color_weights[3]=0
        if !custom_scale {ert.smooth_block_max_mse_scale=lerpf(15,50,min(1,lambda/8))}
        work.passes[0]={0,8,3,block_pixels,ert,unpack_bc1_block,mse_scales}
        work.pass_count=1
    case .BC3:
        ert.color_weights[3]=0
        alpha:=ert
        alpha.color_weights={1,0,0,0}
        alpha.keep_extremes={0}
        if !custom_scale {
            ert.smooth_block_max_mse_scale=lerpf(15,50,min(1,lambda/8))
            alpha.smooth_block_max_mse_scale=lerpf(10,30,min(1,lambda/4))
        }
        if first_channel,ok=channel_pixels(block_pixels,3,allocator);!ok {return false}
        work.unpackers.allow_3color_mode=false
        work.unpackers.use_bc1_3color_mode_for_black=false
        work.passes[0]={0,8,1,first_channel,alpha,unpack_bc4_block,nil}
        work.passes[1]={8,8,3,block_pixels,ert,unpack_bc1_block,mse_scales}
        work.pass_count=2
    }

    for &s in mse_scales {
        if s>0 {s=max(ert.smooth_block_max_mse_scale,s*min(lambda,3))}
    }

    run_ranges(worker,work.chunk_count,rdo_chunks,&work)
    return true
}

// Encodes width*height RGBA8 texels as BC blocks, repeating the border where a
// block falls off the edge, then rewrites them for LZ rate when
// params.rdo_lambda>0. out holds ceil(width/4)*ceil(height/4) blocks. The
// output does not depend on the number of threads of worker. False, with out
// unspecified, for invalid sizes or parameters and out of memory.
encode :: proc(format:Format,pixels:[]u8,width,height:int,params:Params,out:[]u8,worker:=jobs.Worker_Ref{},allocator:=context.allocator) -> bool {
    bytes_per_block:int
    switch format {
    case .BC1,.BC4:
        bytes_per_block=8
    case .BC3,.BC5,.BC7:
        bytes_per_block=16
    case:
        return false
    }

    if width<=0 || height<=0 || width>max(int)/4/height || width*height*4!=len(pixels) {return false}
    blocks_x:=(width+3)/4
    blocks_y:=(height+3)/4
    total_blocks:=blocks_x*blocks_y
    if total_blocks>max(int)/bytes_per_block || total_blocks*bytes_per_block!=len(out) {return false}

    if params.bc7_uber_level<0 || params.bc1_quality_level<0 || params.bc1_quality_level>int(rgbcx.MAX_LEVEL) {return false}
    if params.bc7enc_max_partitions_to_scan<0 || params.bc7enc_max_partitions_to_scan>int(bc7enc.MAX_PARTITIONS) {return false}
    if params.bc45_channel0>3 || params.bc45_channel1>3 {return false}
    if params.bc345_search_rad<0 || params.bc345_search_rad>int(max(u32)) {return false}
    if params.bc1_mode<min(rgbcx.Bc1_Approx_Mode) || params.bc1_mode>max(rgbcx.Bc1_Approx_Mode) {return false}
    if worker.system!=nil && (worker.worker<0 || worker.worker>=jobs.worker_count(worker.system)) {return false}

    params:=params
    source:=Source{slice.reinterpret([]Color_Rgba,pixels),width,height,blocks_x,blocks_y}

    bc7_params:bc7enc.Params
    init_bc7_params(&bc7_params,params,format)

    work:=Encode_Work{
        format=format,
        source=source,
        params=&params,
        bc7_params=&bc7_params,
        out=out,
        bytes_per_block=bytes_per_block,
    }

    err:runtime.Allocator_Error
    if format==.BC7 {
        if work.bc7_tables,err=new(bc7enc.Tables,allocator);err!=nil {return false}
        bc7enc.tables_init(work.bc7_tables)
    } else if format==.BC1 || format==.BC3 {
        if work.bc1_tables,err=new(rgbcx.Tables,allocator);err!=nil {return false}
        rgbcx.tables_init(work.bc1_tables,params.bc1_mode)
    }
    defer if work.bc7_tables!=nil {free(work.bc7_tables,allocator)}
    defer if work.bc1_tables!=nil {free(work.bc1_tables,allocator)}

    run_ranges(worker,blocks_y,encode_rows,&work)

    return postprocess_rdo(format,&source,&params,out,bytes_per_block,worker,allocator)
}
