package asset

// The fields of the blocks of a level as planes: every block's bytes of one
// field, then those of the next. Endpoints and indices are each alike among
// neighbors, and apart they give LZ longer matches and simpler
// statistics. BC1: endpoints | indices. BC5: the endpoints of both channels |
// the indices of both.

// Whether a format can store its levels as planes of fields.
texture_fields_format :: proc "contextless" (format:Texture_Format) -> bool {
    return texture_block_bytes(format)>0
}

// Splits a mip into a buffer of texture_fields_size bytes.
texture_fields_split :: proc "contextless" (format:Texture_Format,blocks,planes:[]u8) -> bool {
    if format==.BC6H || format==.BC7 {return fields_modes_move(format,blocks,planes,false)}
    return fields_move(format,blocks,planes,false)
}

// The blocks of a level from the planes texture_fields_split wrote: a gather
// of bytes at the speed of memory.
texture_fields_join :: proc "contextless" (format:Texture_Format,planes,blocks:[]u8) -> bool {
    if format==.BC6H || format==.BC7 {return fields_modes_move(format,blocks,planes,true)}
    return fields_move(format,blocks,planes,true)
}

@(private)
BC1_FIELD_AT :: [4]int{0,4,0,0}
@(private)
BC1_FIELD_SIZE :: [4]int{4,4,0,0}
@(private)
BC5_FIELD_AT :: [4]int{0,8,2,10}
@(private)
BC5_FIELD_SIZE :: [4]int{2,2,6,6}

@(private="file")
fields_move :: proc "contextless" (format:Texture_Format,blocks,planes:[]u8,join:bool) -> bool {
    stride:=8 if format==.BC1 else 16
    if !texture_fields_format(format) || len(blocks)!=len(planes) || len(blocks)%stride!=0 {return false}
    count:=len(blocks)/stride
    b,p:=raw_data(blocks),raw_data(planes)
    switch format {
    case .BC1:
        if join {fields_copy(b,p,count,true,8,BC1_FIELD_AT,BC1_FIELD_SIZE)}
        else {fields_copy(b,p,count,false,8,BC1_FIELD_AT,BC1_FIELD_SIZE)}
    case .BC5:
        if join {fields_copy(b,p,count,true,16,BC5_FIELD_AT,BC5_FIELD_SIZE)}
        else {fields_copy(b,p,count,false,16,BC5_FIELD_AT,BC5_FIELD_SIZE)}
    case .RGBA8,.BC7,.RGBA16,.RGBA16F,.BC6H:
    }
    return true
}

// Between count blocks of STRIDE bytes and the planes of their fields, which
// start at AT in a block and take SIZE bytes (0: no field), in one pass: the
// blocks are read or written once.
@(private="file")
fields_copy :: #force_inline proc "contextless" (blocks,planes:[^]u8,count:int,$JOIN:bool,$STRIDE:int,$AT:[4]int,$SIZE:[4]int) #no_bounds_check {
    p0:=planes
    p1:=p0[count*SIZE[0]:]
    p2:=p1[count*SIZE[1]:]
    p3:=p2[count*SIZE[2]:]
    for i in 0..<count {
        block:=blocks[i*STRIDE:]
        when JOIN {
            (^[SIZE[0]]u8)(block[AT[0]:])^=(^[SIZE[0]]u8)(p0[i*SIZE[0]:])^
            (^[SIZE[1]]u8)(block[AT[1]:])^=(^[SIZE[1]]u8)(p1[i*SIZE[1]:])^
            when SIZE[2]>0 {(^[SIZE[2]]u8)(block[AT[2]:])^=(^[SIZE[2]]u8)(p2[i*SIZE[2]:])^}
            when SIZE[3]>0 {(^[SIZE[3]]u8)(block[AT[3]:])^=(^[SIZE[3]]u8)(p3[i*SIZE[3]:])^}
        } else {
            (^[SIZE[0]]u8)(p0[i*SIZE[0]:])^=(^[SIZE[0]]u8)(block[AT[0]:])^
            (^[SIZE[1]]u8)(p1[i*SIZE[1]:])^=(^[SIZE[1]]u8)(block[AT[1]:])^
            when SIZE[2]>0 {(^[SIZE[2]]u8)(p2[i*SIZE[2]:])^=(^[SIZE[2]]u8)(block[AT[2]:])^}
            when SIZE[3]>0 {(^[SIZE[3]]u8)(p3[i*SIZE[3]:])^=(^[SIZE[3]]u8)(block[AT[3]:])^}
        }
    }
}
