package mirai_pcg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:simd"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
Tile :: struct {
    x,y,z,height,slope,occupancy,mask0,eco0,eco1:[TILE]f32,
    masks:[1][]f32,
    ecotopes:[2][]f32,
}

// Coordinates over a few lattice cells, negative and positive, and inputs that differ per sample.
@(private="file")
tile_fill :: proc(t:^Tile) {
    for i in 0..<TILE {
        t.x[i]=f32(i%16)*0.37-3.1
        t.z[i]=f32(i/16)*0.41+1.3
        t.y[i]=f32(i)*0.05-6.2
        t.height[i]=f32(i)*0.5
        t.slope[i]=f32(i%7)*0.125
        t.occupancy[i]=f32(i%2)
        t.mask0[i]=f32(i%5)*0.25
        t.eco0[i]=-1
        t.eco1[i]=f32(i%3)
    }
}
@(private="file")
tile_inputs :: proc(t:^Tile) -> Field_Inputs {
    t.masks[0]=t.mask0[:]
    t.ecotopes[0],t.ecotopes[1]=t.eco0[:],t.eco1[:]
    return {x=t.x[:],y=t.y[:],z=t.z[:],height=t.height[:],slope=t.slope[:],occupancy=t.occupancy[:],masks=t.masks[:],ecotopes=t.ecotopes[:]}
}

@(private="file")
compile_ok :: proc(t:^testing.T,source:string,loc:=#caller_location) -> (Field_Program,bool) {
    program,err:=field_compile(source,context.allocator)
    if !testing.expectf(t,err.kind==.None,"%q does not compile: %v at %d (%s)",source,err.kind,err.offset,err.message,loc=loc) {return {},false}
    return program,true
}

@(private="file")
lane0 :: proc(v:V4) -> f32 {return simd.to_array(v)[0]}

@(private="file")
count_op :: proc(program:Field_Program,op:Field_Op) -> int {
    n:=0
    for instr in program.code {if instr.op==op {n+=1}}
    return n
}

@(private="file")
Reference :: struct {source:string,expected:proc(x,y,z:f32,i:int,t:^Tile) -> f32}

@(test)
every_operation_noise_and_input_matches_its_kernel :: proc(t:^testing.T) {
    tile:Tile
    tile_fill(&tile)
    inputs:=tile_inputs(&tile)
    scratch:=new(Field_Scratch)
    defer free(scratch)
    cases:=[?]Reference{
        {"x",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x}},
        {"y",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return y}},
        {"z",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return z}},
        {"height",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return t.height[i]}},
        {"slope",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return t.slope[i]}},
        {"occupancy",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return t.occupancy[i]}},
        {"mask(0)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return t.mask0[i]}},
        {"mask(3)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return 0}},
        {"ecotope(1)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return t.eco1[i]}},
        {"ecotope(0)*2",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return t.eco0[i]*2}},
        {"ecotope(7)+1",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return 1}},
        {"-x",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return -x}},
        {"x+y",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x+y}},
        {"x-y",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x-y}},
        {"x*y",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x*y}},
        {"x/y",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x/y}},
        {"1-x*2",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return 1-x*2}},
        {"min(x,y)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x<y ? x : y}},
        {"max(x,y)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return y<x ? x : y}},
        {"abs(y)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return abs(y)}},
        {"sqrt(z)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(simd.sqrt(V4(z)))}},
        {"pow2(x)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x*x}},
        {"clamp(x,-1,0.5)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(vmin(vmax(V4(x),-1),0.5))}},
        {"lerp(x,y,z)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x+(y-x)*z}},
        {"smoothstep(-2,2,x)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(vsmoothstep(-2,2,V4(x)))}},
        {"select(x,y,z)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return x>0 ? y : z}},
        {"remap(x,-3,3,10,20)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return 10+(x+3)*(f32(10)/f32(6))}},
        {"value2(x,z)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(kernel_value2(V4(x),V4(z),0))}},
        {"value3(x,y,z,9)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(kernel_value3(V4(x),V4(y),V4(z),9))}},
        {"perlin2(x,z,3)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(kernel_perlin2(V4(x),V4(z),3))}},
        {"perlin3(x,y,z)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(kernel_perlin3(V4(x),V4(y),V4(z),0))}},
        {"cellular2(x,z,-1)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(kernel_cellular2(V4(x),V4(z),0xffffffff))}},
        {"cellular3(x,y,z)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(kernel_cellular3(V4(x),V4(y),V4(z),0))}},
        {"fbm2(x,z,3,2,0.5,4)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {
            sum:=kernel_perlin2(V4(x),V4(z),4)+kernel_perlin2(V4(x)*2,V4(z)*2,5)*0.5
            return lane0((sum+kernel_perlin2(V4(x)*4,V4(z)*4,6)*0.25)/1.75)
        }},
        {"ridged2(x,z,2,3,0.25)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {
            a:=1-vabs(kernel_perlin2(V4(x),V4(z),0))
            b:=1-vabs(kernel_perlin2(V4(x)*3,V4(z)*3,1))
            return lane0((a*a+b*b*0.25)/1.25)
        }},
        {"turbulence2(x,z,2,2,0.5)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {
            return lane0((vabs(kernel_perlin2(V4(x),V4(z),0))+vabs(kernel_perlin2(V4(x)*2,V4(z)*2,1))*0.5)/1.5)
        }},
        {"fbm3(x,y,z,2,2,0.5)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {
            return lane0((kernel_perlin3(V4(x),V4(y),V4(z),0)+kernel_perlin3(V4(x)*2,V4(y)*2,V4(z)*2,1)*0.5)/1.5)
        }},
        {"ridged3(x,y,z,1,2,0.5)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {
            a:=1-vabs(kernel_perlin3(V4(x),V4(y),V4(z),0))
            return lane0(a*a)
        }},
        {"turbulence3(x,y,z,1,2,0.5,8)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(vabs(kernel_perlin3(V4(x),V4(y),V4(z),8)))}},
        {"warp2x(x,z,4,0.5,2)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(V4(x)+4*kernel_perlin2(V4(x)*0.5,V4(z)*0.5,2))}},
        {"warp2z(x,z,4,0.5,2)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(V4(z)+4*kernel_perlin2(V4(x)*0.5,V4(z)*0.5,3))}},
        {"warp3x(x,y,z,2,0.25)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(V4(x)+2*kernel_perlin3(V4(x)*0.25,V4(y)*0.25,V4(z)*0.25,0))}},
        {"warp3y(x,y,z,2,0.25)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(V4(y)+2*kernel_perlin3(V4(x)*0.25,V4(y)*0.25,V4(z)*0.25,1))}},
        {"warp3z(x,y,z,2,0.25)",proc(x,y,z:f32,i:int,t:^Tile) -> f32 {return lane0(V4(z)+2*kernel_perlin3(V4(x)*0.25,V4(y)*0.25,V4(z)*0.25,2))}},
    }
    out:[TILE]f32
    for c in cases {
        program,ok:=compile_ok(t,c.source)
        if !ok {continue}
        defer field_program_destroy(&program)
        testing.expect_value(t,field_eval_tile(&program,inputs,out[:],scratch),Field_Eval_Error.None)
        wrong:=0
        for i in 0..<TILE {
            expected:=c.expected(tile.x[i],tile.y[i],tile.z[i],i,&tile)
            if transmute(u32)out[i]!=transmute(u32)expected {
                if wrong==0 {log.errorf("%q at %d: %v, expected %v",c.source,i,out[i],expected)}
                wrong+=1
            }
        }
        testing.expectf(t,wrong==0,"%q differs from its kernel in %d samples",c.source,wrong)
    }
}

@(test)
noises_stay_in_their_ranges_and_vary :: proc(t:^testing.T) {
    scratch:=new(Field_Scratch)
    defer free(scratch)
    Range :: struct {source:string,low,high:f32}
    ranges:=[?]Range{
        {"value2(x,z)",-1,1},{"value3(x,y,z)",-1,1},{"perlin2(x,z)",-1.5,1.5},{"perlin3(x,y,z)",-1.5,1.5},
        {"cellular2(x,z)",0,1.2},{"cellular3(x,y,z)",0,1.5},{"fbm2(x,z,8,2,0.5)",-1.5,1.5},
        {"ridged3(x,y,z,6,2,0.5)",0,1},{"turbulence2(x,z,5,2,0.5)",0,1.5},
    }
    // A wide grid of points over many cells, 16 tiles.
    x,y,z,out:[TILE]f32
    for r in ranges {
        program,ok:=compile_ok(t,r.source)
        if !ok {continue}
        defer field_program_destroy(&program)
        low,high:=f32(1e9),f32(-1e9)
        for tile_index in 0..<16 {
            for i in 0..<TILE {
                x[i]=f32(i%16)*0.731+f32(tile_index)*11.3-50
                z[i]=f32(i/16)*0.677-f32(tile_index)*7.1
                y[i]=f32(i)*0.093+f32(tile_index)
            }
            testing.expect_value(t,field_eval_tile(&program,{x=x[:],y=y[:],z=z[:]},out[:],scratch),Field_Eval_Error.None)
            for v in out {low,high=min(low,v),max(high,v)}
        }
        testing.expectf(t,low>=r.low && high<=r.high,"%q spans %v to %v, outside %v to %v",r.source,low,high,r.low,r.high)
        testing.expectf(t,high-low>(r.high-r.low)*0.25,"%q barely varies: %v to %v",r.source,low,high)
    }
    // Lattice points: gradient noise is 0 there.
    program,_:=compile_ok(t,"perlin2(x,z,7)+perlin3(x,y,z,7)")
    defer field_program_destroy(&program)
    for i in 0..<TILE {x[i],y[i],z[i]=f32(i%16-8),f32(i%3),f32(i/16-8)}
    field_eval_tile(&program,{x=x[:],y=y[:],z=z[:]},out[:],scratch)
    for v in out {testing.expect(t,v==0,"Perlin noise is 0 on the lattice")}
}

@(test)
equal_operations_merge_and_constants_fold :: proc(t:^testing.T) {
    Shape :: struct {source:string,instructions:int,op:Field_Op,op_count:int}
    shapes:=[?]Shape{
        {"perlin2(x,z)+perlin2(x,z)",4,.Perlin2,1},       // x, z, noise, sum
        {"x*y+y*x",4,.Mul,1},                              // products commute
        {"min(x,y)+min(y,x)",5,.Min,2},                    // min does not commute with NaN or -0
        {"fbm2(x,z,4,2,0.5)+ridged2(x,z,4,2,0.5)",0,.Perlin2,4}, // the octaves are shared
        {"1+2*3",1,.Const,1},
        {"sqrt(16)+remap(5,0,10,0,1)",1,.Const,1},
        {"x*(2+2)",2,.Mul,1},
        {"x*1+0*0",2,.Add,1},                              // x*1 is x; x+0 is kept: -0+0 is +0
        {"x/1-0",1,.Input,1},
        {"-(-x)",1,.Input,1},
        {"let a = x*3; let b = y; a*a",3,.Mul,2},            // the unused binding is dropped
        {"perlin2(0.3,0.7,5)*x",2,.Mul,1},                 // a noise of constants is a constant
    }
    for s in shapes {
        program,ok:=compile_ok(t,s.source)
        if !ok {continue}
        defer field_program_destroy(&program)
        if s.instructions>0 {testing.expectf(t,len(program.code)==s.instructions,"%q has %d instructions, expected %d",s.source,len(program.code),s.instructions)}
        testing.expectf(t,count_op(program,s.op)==s.op_count,"%q has %d %v, expected %d",s.source,count_op(program,s.op),s.op,s.op_count)
    }
    // A folded constant has the bits the evaluator gives the same operation.
    scratch:=new(Field_Scratch)
    defer free(scratch)
    for source in ([?][2]string{{"perlin2(0.3,0.7,5)","perlin2(x,z,5)"},{"cellular3(-1.6,0.7,2.2)","cellular3(x,y,z)"},
        {"smoothstep(0,1,0.3)","smoothstep(0,1,x)"},{"fbm2(0.3,0.7,6,2.1,0.45)","fbm2(x,z,6,2.1,0.45)"}}) {
        folded,_:=compile_ok(t,source[0])
        live,_:=compile_ok(t,source[1])
        defer {field_program_destroy(&folded);field_program_destroy(&live)}
        testing.expectf(t,len(folded.code)==1 && folded.code[0].op==.Const,"%q folds to one constant",source[0])
        coords:=[?]f32{0.3,0.7,2.2}
        if source[0][0]=='c' {coords={-1.6,0.7,2.2}}
        if source[0][0]=='s' {coords={0.3,0,0}}
        x,y,z:=[1]f32{coords[0]},[1]f32{coords[1]},[1]f32{coords[2]}
        if source[0][0]=='p' || source[0][0]=='f' {z[0]=coords[1]}
        a,_:=field_eval_point(&folded,{},0,scratch)
        b,_:=field_eval_point(&live,{x=x[:],y=y[:],z=z[:]},0,scratch)
        testing.expectf(t,transmute(u32)a==transmute(u32)b,"%q folds to %v, the evaluator gives %v",source[0],a,b)
    }
}

@(test)
slots_are_reused_from_the_last_use :: proc(t:^testing.T) {
    // Twelve noises summed one after another need the two coordinates, the sum and one noise.
    builder:=strings.builder_make(context.temp_allocator)
    for i in 0..<12 {fmt.sbprintf(&builder,"%sperlin2(x,z,%d)",i>0 ? "+" : "",i)}
    program,ok:=compile_ok(t,strings.to_string(builder))
    if !ok {return}
    defer field_program_destroy(&program)
    testing.expect_value(t,len(program.code),2+12+11)
    testing.expectf(t,program.slots<=4,"12 noises summed in turn use %d slots",program.slots)
    // Values that are alive together need one slot each: n bindings read by one sum at the end.
    bound :: proc(n:int) -> string {
        b:=strings.builder_make(context.temp_allocator)
        for i in 0..<n {fmt.sbprintf(&b,"let n%d = perlin2(x,z,%d);\n",i,i)}
        for i in 0..<n {fmt.sbprintf(&b,"%sn%d",i>0 ? "+" : "",i)}
        return strings.to_string(b)
    }
    // The coordinates stay alive until the last noise, so 15 noises fill the 16 slots.
    wide,wide_ok:=compile_ok(t,bound(15))
    if wide_ok {
        testing.expect_value(t,wide.slots,u8(MAX_SLOTS))
        field_program_destroy(&wide)
    }
    _,err:=field_compile(bound(16),context.allocator)
    testing.expect_value(t,err.kind,Field_Error_Kind.Slot_Overflow)
    testing.expect(t,err.length>0 && err.offset+err.length<=len(bound(16)),"the overflow points at the value that found no slot")
}

@(private="file")
COMPLEX :: [?]string{
    `let wx = warp2x(x, z, 3, 0.15, 11);
     let wz = warp2z(x, z, 3, 0.15, 11);
     let ground = fbm2(wx*0.2, wz*0.2, 5, 2, 0.5, 3)*12 + height;   # terrain
     let rock = ridged2(x*0.3, z*0.3, 4, 2.2, 0.45)*mask(0);
     select(occupancy, ground, lerp(ground, rock, smoothstep(0.2, 0.8, slope))) + ecotope(1)*0.5`,
    `remap(cellular3(x, y*0.5, z, 4), 0, 1, -1, 1) * turbulence3(x, y, z, 3, 2, 0.6, 9)
     + clamp(value3(x*2, y, z*2), -0.5, 0.5) - min(abs(perlin3(z, x, y)), 0.25)
     + max(value2(x, z, -5), cellular2(z, x)) / (2 + pow2(sqrt(abs(y))))`,
    `fbm3(warp3x(x,y,z,1,0.5), warp3y(x,y,z,1,0.5), warp3z(x,y,z,1,0.5), 8, 1.9, 0.55, 1)
     * -ridged3(x, y, z, 3, 2, 0.5) + turbulence2(x, z, 6, 2, 0.5, 2)`,
}

@(test)
a_point_has_the_bits_of_its_sample_in_a_tile :: proc(t:^testing.T) {
    tile:Tile
    tile_fill(&tile)
    inputs:=tile_inputs(&tile)
    scratch:=new(Field_Scratch)
    defer free(scratch)
    sources:=COMPLEX
    for source in sources {
        program,ok:=compile_ok(t,source)
        if !ok {continue}
        defer field_program_destroy(&program)
        full,part:[TILE]f32
        testing.expect_value(t,field_eval_tile(&program,inputs,full[:],scratch),Field_Eval_Error.None)
        // A partial tile (not a multiple of W) has the bits of the full one.
        testing.expect_value(t,field_eval_tile(&program,inputs,part[:37],scratch),Field_Eval_Error.None)
        wrong:=0
        for i in 0..<TILE {
            point,err:=field_eval_point(&program,inputs,i,scratch)
            testing.expect_value(t,err,Field_Eval_Error.None)
            if transmute(u32)point!=transmute(u32)full[i] {wrong+=1}
            if i<37 && transmute(u32)part[i]!=transmute(u32)full[i] {wrong+=1}
        }
        testing.expectf(t,wrong==0,"%d samples of a point or a partial tile differ from the tile",wrong)
    }
}

@(test)
evaluation_does_not_allocate :: proc(t:^testing.T) {
    tile:Tile
    tile_fill(&tile)
    inputs:=tile_inputs(&tile)
    scratch:=new(Field_Scratch)
    defer free(scratch)
    sources:=COMPLEX
    programs:[len(COMPLEX)]Field_Program
    for source,i in sources {programs[i],_=compile_ok(t,source)}
    defer for &p in programs {field_program_destroy(&p)}
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    out:[TILE]f32
    {
        saved:=context
        defer context=saved
        context.allocator=mem.tracking_allocator(&track)
        context.temp_allocator=context.allocator
        for round in 0..<20 {
            for &p in programs {
                field_eval_tile(&p,inputs,out[:],scratch)
                field_eval_point(&p,inputs,round,scratch)
            }
        }
        context.allocator=runtime.nil_allocator()
        context.temp_allocator=runtime.nil_allocator()
        for &p in programs {
            testing.expect_value(t,field_eval_tile(&p,inputs,out[:],scratch),Field_Eval_Error.None)
        }
    }
    testing.expect_value(t,track.total_allocation_count,i64(0))
}

@(test)
hostile_coordinates_give_finite_noise_and_one_nan :: proc(t:^testing.T) {
    scratch:=new(Field_Scratch)
    defer free(scratch)
    source:base.Hostile={0x70c9}
    x,y,z,out:[TILE]f32
    for i in 0..<TILE {x[i],y[i],z[i]=base.hostile_f32(&source),base.hostile_f32(&source),base.hostile_f32(&source)}
    x[0],x[1],x[2],x[3]=f32(0h7fc00000),f32(0h7f800000),f32(0hff800000),f32(0hffc00001)
    noises:=[?]string{"value2(x,z)","value3(x,y,z)","perlin2(x,z)","perlin3(x,y,z)","cellular2(x,z)","cellular3(x,y,z)",
        "fbm2(x,z,8,2,0.5)","ridged3(x,y,z,8,2,0.5)","turbulence3(x,y,z,8,2,0.5)"}
    for n in noises {
        program,ok:=compile_ok(t,n)
        if !ok {continue}
        defer field_program_destroy(&program)
        field_eval_tile(&program,{x=x[:],y=y[:],z=z[:]},out[:],scratch)
        for v in out {testing.expectf(t,v-v==0,"%q gives %v for a hostile coordinate",n,v)}
    }
    // Arithmetic keeps IEEE results; every NaN comes out with the same bits.
    program,_:=compile_ok(t,"x/y + sqrt(z) + x*y")
    defer field_program_destroy(&program)
    field_eval_tile(&program,{x=x[:],y=y[:],z=z[:]},out[:],scratch)
    for v in out {
        bits:=transmute(u32)v
        testing.expect(t,v-v==0 || v==v && bits&0x7fffffff==0x7f800000 || bits==CANONICAL_NAN,"a NaN is canonical")
    }
}

@(test)
malformed_expressions_are_refused_with_their_place :: proc(t:^testing.T) {
    Refusal :: struct {source:string,kind:Field_Error_Kind,offset:int}
    deep:=strings.concatenate({strings.repeat("(",100,context.temp_allocator),"x",strings.repeat(")",100,context.temp_allocator)},context.temp_allocator)
    calls:=strings.concatenate({strings.repeat("abs(",40,context.temp_allocator),"x",strings.repeat(")",40,context.temp_allocator)},context.temp_allocator)
    huge:=strings.repeat("x",MAX_SOURCE+1,context.temp_allocator)
    flat:=strings.builder_make(context.temp_allocator)
    for i in 0..<3000 {fmt.sbprintf(&flat,"%sx*%d",i>0 ? "+" : "",i+2)}
    refusals:=[?]Refusal{
        {"",.Syntax,0},{"   # only a comment",.Syntax,19},{"1+",.Syntax,2},{"(x",.Syntax,2},{"x)",.Syntax,1},
        {"x y",.Syntax,2},{"x+@",.Syntax,2},{"x + foo(1)",.Unknown_Function,4},{"q*2",.Unknown_Identifier,0},
        {"perlin2",.Syntax,7},{"min(x)",.Arity,0},{"abs(x,y)",.Arity,0},{"perlin2(x,z,1,2)",.Arity,0},
        {"perlin2(x,z,y)",.Not_Constant,12},{"perlin2(x,z,0.5)",.Out_Of_Range,12},{"value2(x,z,5e9)",.Out_Of_Range,11},
        {"fbm2(x,z,9,2,0.5)",.Out_Of_Range,9},{"fbm2(x,z,0,2,0.5)",.Out_Of_Range,9},{"fbm2(x,z,x,2,0.5)",.Not_Constant,9},
        {"fbm2(x,z,3,y,0.5)",.Not_Constant,11},{"fbm2(x,z,2,2,-1)",.Out_Of_Range,0},{"fbm2(x,z,8,1e30,0.5)",.Non_Finite,0},
        {"1e39",.Non_Finite,0},{"1/0",.Non_Finite,0},{"sqrt(-1)",.Non_Finite,0},{"x+remap(x,1,1,0,1)",.Non_Finite,2},
        {"mask(-1)",.Out_Of_Range,5},{"mask(256)",.Out_Of_Range,5},{"mask(1.5)",.Out_Of_Range,5},{"ecotope(x)",.Not_Constant,8},
        {"let x = 1; x",.Syntax,4},{"let a = 1; let a = 2; a",.Syntax,15},{"let a = 1 a",.Syntax,10},
        {"let = 1; x",.Syntax,4},{"let abs = 1; x",.Syntax,4},{"a; let a = 1",.Unknown_Identifier,0},
        {deep,.Too_Large,64},{calls,.Too_Large,0},{huge,.Too_Large,MAX_SOURCE},{strings.to_string(flat),.Too_Large,0},
    }
    for r in refusals {
        memory:base.Hostile_Memory
        _,err:=field_compile(r.source,base.hostile_memory_begin(&memory))
        leaked,bad:=base.hostile_memory_end(&memory)
        label:=r.source[:min(len(r.source),40)]
        testing.expectf(t,err.kind==r.kind,"%q: %v, expected %v (%s)",label,err.kind,r.kind,err.message)
        if r.offset>0 || r.kind==.Unknown_Function {testing.expectf(t,err.offset==r.offset,"%q: offset %d, expected %d",label,err.offset,r.offset)}
        testing.expectf(t,err.message!="" && err.offset>=0 && err.offset+err.length<=max(len(r.source),err.offset),"%q: the error has a message and a place in the source",label)
        testing.expectf(t,leaked==0 && bad==0,"%q leaves %d allocations and %d bad frees",label,leaked,bad)
    }
}

@(test)
random_sources_compile_or_refuse_without_crashing :: proc(t:^testing.T) {
    scratch:=new(Field_Scratch)
    defer free(scratch)
    tile:Tile
    tile_fill(&tile)
    inputs:=tile_inputs(&tile)
    pieces:=[?]string{"x","y","z","height","mask(0)","ecotope(1)","1","0.5","-","+","*","/","(",")",",",";",
        "perlin2(","fbm2(","min(","clamp(","let a =","a","1e40","3",")","select(","#\n","@","  "}
    source:base.Hostile={0xf1e1d}
    builder:=strings.builder_make(context.temp_allocator)
    compiled:=0
    out:[TILE]f32
    for _ in 0..<3000 {
        strings.builder_reset(&builder)
        for _ in 0..<base.hostile_int(&source,24) {strings.write_string(&builder,pieces[base.hostile_int(&source,len(pieces))])}
        text:=strings.to_string(builder)
        memory:base.Hostile_Memory
        program,err:=field_compile(text,base.hostile_memory_begin(&memory))
        if err.kind==.None {
            compiled+=1
            testing.expectf(t,field_eval_tile(&program,inputs,out[:],scratch)==.None,"%q compiles but does not evaluate",text)
            field_program_destroy(&program)
        } else {
            testing.expectf(t,err.offset>=0 && err.offset<=len(text) && err.message!="","%q: error out of the source",text)
        }
        leaked,bad:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad==0,"%q leaks",text)
    }
    testing.expectf(t,compiled>50,"only %d random sources compiled",compiled)
}

@(private="file")
Budget :: struct {left:int,backing:runtime.Allocator}
@(private="file")
budget_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    b:=(^Budget)(data)
    #partial switch mode {
    case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
        if b.left<=0 {return nil,.Out_Of_Memory}
        b.left-=1
    }
    return b.backing.procedure(b.backing.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
compilation_without_memory_fails_cleanly :: proc(t:^testing.T) {
    sources:=COMPLEX
    for allowed in 0..<8 {
        memory:base.Hostile_Memory
        budget:=Budget{allowed,base.hostile_memory_begin(&memory)}
        program,err:=field_compile(sources[0],{budget_proc,&budget})
        if allowed<3 {
            testing.expectf(t,err.kind==.Out_Of_Memory,"with %d allocations: %v",allowed,err.kind)
        } else {
            testing.expectf(t,err.kind==.None,"with %d allocations: %v",allowed,err.kind)
            field_program_destroy(&program)
        }
        leaked,bad:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad==0,"with %d allocations it leaks %d",allowed,leaked)
    }
    _,err:=field_compile("x",runtime.nil_allocator())
    testing.expect_value(t,err.kind,Field_Error_Kind.Out_Of_Memory)
}

@(test)
invalid_programs_and_arguments_are_refused :: proc(t:^testing.T) {
    scratch:=new(Field_Scratch)
    defer free(scratch)
    tile:Tile
    tile_fill(&tile)
    inputs:=tile_inputs(&tile)
    out:[TILE]f32
    program,_:=compile_ok(t,"x+perlin2(x,z)")
    defer field_program_destroy(&program)
    testing.expect_value(t,field_eval_tile(&program,inputs,out[:0],scratch),Field_Eval_Error.Bad_Count)
    big:[TILE+1]f32
    testing.expect_value(t,field_eval_tile(&program,inputs,big[:],scratch),Field_Eval_Error.Bad_Count)
    _,err:=field_eval_point(&program,inputs,-1,scratch)
    testing.expect_value(t,err,Field_Eval_Error.Bad_Count)
    _,err=field_eval_point(&program,inputs,TILE,scratch)
    testing.expect_value(t,err,Field_Eval_Error.Input_Too_Short)
    _,err=field_eval_point(&program,{},TILE*1000,scratch)
    testing.expect_value(t,err,Field_Eval_Error.None) // absent inputs are 0 everywhere
    short:=inputs
    short.z=tile.z[:10]
    testing.expect_value(t,field_eval_tile(&program,short,out[:],scratch),Field_Eval_Error.Input_Too_Short)
    testing.expect_value(t,field_eval_tile(&program,short,out[:10],scratch),Field_Eval_Error.None)
    testing.expect_value(t,field_eval_tile(&program,inputs,out[:],nil),Field_Eval_Error.Scratch_Misaligned)
    unaligned:=(^Field_Scratch)(uintptr(scratch)+4)
    testing.expect_value(t,field_eval_tile(&program,inputs,out[:1],unaligned),Field_Eval_Error.Scratch_Misaligned)
    testing.expect_value(t,field_eval_tile(nil,inputs,out[:],scratch),Field_Eval_Error.Invalid_Program)
    // Bytecode changed by hand.
    code:[8]Field_Instr
    Corrupt :: struct {name:string,change:proc(c:^Field_Instr,p:^Field_Program)}
    corruptions:=[?]Corrupt{
        {"empty",proc(c:^Field_Instr,p:^Field_Program) {p.code=p.code[:0]}},
        {"destination",proc(c:^Field_Instr,p:^Field_Program) {c.dst=MAX_SLOTS}},
        {"argument",proc(c:^Field_Instr,p:^Field_Program) {c.args[0]=200;c.imm_mask=0}},
        {"unwritten",proc(c:^Field_Instr,p:^Field_Program) {c.args[1]=15;c.imm_mask=0}},
        {"operation",proc(c:^Field_Instr,p:^Field_Program) {c.op=Field_Op(200)}},
        {"input",proc(c:^Field_Instr,p:^Field_Program) {p.code[0].input=Field_Input(99)}},
        {"output",proc(c:^Field_Instr,p:^Field_Program) {p.output=14}},
        {"output range",proc(c:^Field_Instr,p:^Field_Program) {p.output=99}},
    }
    for corruption in corruptions {
        copy(code[:],program.code)
        bad:=program
        bad.code=code[:len(program.code)]
        corruption.change(&code[len(program.code)-1],&bad)
        testing.expectf(t,field_eval_tile(&bad,inputs,out[:],scratch)==.Invalid_Program,"a program with a bad %s is refused",corruption.name)
    }
}

// The bits of these programs and of their results are the same on every platform; a change
// here is a change of the field language or its noises and needs new golden values.
@(test)
golden_hashes_of_complex_programs :: proc(t:^testing.T) {
    GOLDEN_PROGRAM :: [len(COMPLEX)]u64{0xeca1783d7a03dfa4,0x832da5c9af99f217,0x401f8c7c5fcc8791}
    GOLDEN_RESULT :: [len(COMPLEX)]u64{0x190997aef2b6bcd5,0xbb9d7d72df2e3e10,0x62bf70d03b78059a}
    tile:Tile
    tile_fill(&tile)
    inputs:=tile_inputs(&tile)
    scratch:=new(Field_Scratch)
    defer free(scratch)
    sources:=COMPLEX
    programs,results:=GOLDEN_PROGRAM,GOLDEN_RESULT
    for source,i in sources {
        program,ok:=compile_ok(t,source)
        if !ok {continue}
        defer field_program_destroy(&program)
        out:[TILE]f32
        field_eval_tile(&program,inputs,out[:],scratch)
        result:=base.hash64(([^]byte)(&out)[:size_of(out)])
        log.infof("program %d: %d instructions, %d slots, hash 0x%16x, result 0x%16x",i,len(program.code),program.slots,program.hash,result)
        testing.expectf(t,program.hash==programs[i],"program %d hash 0x%16x, golden 0x%16x",i,program.hash,programs[i])
        testing.expectf(t,result==results[i],"program %d result 0x%16x, golden 0x%16x",i,result,results[i])
        again,_:=compile_ok(t,source)
        testing.expect_value(t,again.hash,program.hash)
        field_program_destroy(&again)
    }
}
