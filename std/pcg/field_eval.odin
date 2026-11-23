package mirai_pcg

import "core:simd"

// Evaluates the program over the first len(out) samples of the inputs (1 to TILE). It does not
// allocate: the registers live in the scratch.
field_eval_tile :: proc "contextless" (program:^Field_Program,inputs:Field_Inputs,out:[]f32,scratch:^Field_Scratch) -> Field_Eval_Error {
    if len(out)<1 || len(out)>TILE {return .Bad_Count}
    return field_run(program,inputs,0,out,scratch)
}

// Evaluates sample `index` of the inputs alone: a tile of W lanes padded with zeros goes through
// the same code as field_eval_tile, so the result has the same bits as out[index] of a tile.
field_eval_point :: proc "contextless" (program:^Field_Program,inputs:Field_Inputs,index:int,scratch:^Field_Scratch) -> (f32,Field_Eval_Error) {
    if index<0 {return 0,.Bad_Count}
    out:[1]f32
    err:=field_run(program,inputs,index,out[:],scratch)
    return out[0],err
}

@(private)
field_input_slice :: #force_inline proc "contextless" (inputs:^Field_Inputs,kind:Field_Input,index:u8) -> []f32 {
    switch kind {
    case .X:         return inputs.x
    case .Y:         return inputs.y
    case .Z:         return inputs.z
    case .Height:    return inputs.height
    case .Slope:     return inputs.slope
    case .Occupancy: return inputs.occupancy
    case .Mask:      return inputs.masks[index] if int(index)<len(inputs.masks) else nil
    case .Ecotope:   return inputs.ecotopes[index] if int(index)<len(inputs.ecotopes) else nil
    }
    return nil
}

// Checks what the code reads and writes before running it unchecked.
@(private)
field_validate :: proc "contextless" (program:^Field_Program,inputs:^Field_Inputs,end:int) -> Field_Eval_Error {
    if program==nil || len(program.code)==0 || len(program.code)>MAX_CODE || program.output>=MAX_SLOTS {return .Invalid_Program}
    written:u32
    for instr in program.code {
        if instr.op>max(Field_Op) || instr.dst>=MAX_SLOTS || instr.input>max(Field_Input) {return .Invalid_Program}
        arity:=op_arity(instr.op)
        for i in 0..<arity {
            if instr.imm_mask&(1<<u32(i))!=0 {continue}
            if instr.args[i]>=MAX_SLOTS || written&(1<<u32(instr.args[i]))==0 {return .Invalid_Program}
        }
        if instr.op==.Input {
            source:=field_input_slice(inputs,instr.input,instr.index)
            if len(source)!=0 && len(source)<end {return .Input_Too_Short}
        }
        written|=1<<instr.dst
    }
    if written&(1<<program.output)==0 {return .Invalid_Program}
    return .None
}

@(private)
field_run :: proc "contextless" (program:^Field_Program,inputs:Field_Inputs,first:int,out:[]f32,scratch:^Field_Scratch) -> Field_Eval_Error {
    if scratch==nil || uintptr(scratch)%64!=0 {return .Scratch_Misaligned}
    count:=len(out)
    if first>max(int)-count {return .Bad_Count}
    inputs:=inputs
    if err:=field_validate(program,&inputs,first+count);err!=.None {return err}
    vectors:=(count+W-1)/W
    #no_bounds_check for instr in program.code {
        dst:=&scratch.slots[instr.dst]
        src:[3][^]V4
        step:[3]int
        for i in 0..<3 {
            if instr.imm_mask&(1<<u32(i))!=0 {
                scratch.imm[i]=V4(instr.imm[i])
                src[i]=&scratch.imm[i]
            } else {
                src[i]=&scratch.slots[instr.args[i]][0]
                step[i]=1
            }
        }
        a,b,c:=src[0],src[1],src[2]
        sa,sb,sc:=step[0],step[1],step[2]
        switch instr.op {
        case .Const:
            for v in 0..<vectors {dst[v]=V4(instr.imm[0])}
        case .Input:
            lanes:=([^]f32)(dst)
            source:=field_input_slice(&inputs,instr.input,instr.index)
            if len(source)==0 {
                for i in 0..<vectors*W {lanes[i]=0}
            } else {
                for i in 0..<count {lanes[i]=source[first+i]}
                for i in count..<vectors*W {lanes[i]=0}
            }
        case .Add: for v in 0..<vectors {dst[v]=a[v*sa]+b[v*sb]}
        case .Sub: for v in 0..<vectors {dst[v]=a[v*sa]-b[v*sb]}
        case .Mul: for v in 0..<vectors {dst[v]=a[v*sa]*b[v*sb]}
        case .Div: for v in 0..<vectors {dst[v]=a[v*sa]/b[v*sb]}
        case .Min: for v in 0..<vectors {dst[v]=vmin(a[v*sa],b[v*sb])}
        case .Max: for v in 0..<vectors {dst[v]=vmax(a[v*sa],b[v*sb])}
        case .Neg: for v in 0..<vectors {dst[v]=-a[v*sa]}
        case .Abs: for v in 0..<vectors {dst[v]=vabs(a[v*sa])}
        case .Sqrt: for v in 0..<vectors {dst[v]=simd.sqrt(a[v*sa])}
        case .Clamp: for v in 0..<vectors {dst[v]=vmin(vmax(a[v*sa],b[v*sb]),c[v*sc])}
        case .Lerp: for v in 0..<vectors {dst[v]=vlerp(a[v*sa],b[v*sb],c[v*sc])}
        case .Smoothstep, .Select, .Value2, .Value3, .Perlin2, .Perlin3, .Cellular2, .Cellular3:
            for v in 0..<vectors {dst[v]=kernel_apply(instr.op,a[v*sa],b[v*sb],c[v*sc],instr.seed)}
        }
    }
    result:=&scratch.slots[program.output]
    #no_bounds_check {
        for v in 0..<vectors {result[v]=vcanonical(result[v])}
        lanes:=([^]f32)(result)
        for i in 0..<count {out[i]=lanes[i]}
    }
    return .None
}
