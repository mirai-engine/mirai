package asset

// BC6H without sign (BC6H_UF16): 4x4 texels of rgb half floats in 16 bytes,
// in one of 14 modes (D3D11 functional specification, 19.5.13). A mode has one
// subset or two (those of the first 32 partitions of BC7), endpoints of 6 to
// 16 bits, and the endpoints after the first may be deltas from it. Each
// mode has its own endpoint bit layout. An index
// interpolates in the 16-bit range the endpoints unquantize to, and that
// value times 31/64 is the bits of its half float. A reserved mode decodes to
// black.

// A mode, with the field names of the specification.
Bc6h_Mode :: struct {
    ns:u8,  // subsets
    pb:u8,  // partition bits
    epb:u8, // endpoint bits
    db:u8,  // delta bits; 0: the endpoints are not deltas from the first
    bc:u8,  // the channel whose deltas have one more bit; 3: none
    ib:u8,  // index bits
}

// By the value of the mode bits, 2 for the first two and 5 for the others,
// in the order of the specification: modes 1 to 10, then 11 to 14.
BC6H_MODES :: [14]Bc6h_Mode{
    {2,5,10,5,3,3},{2,5,7,6,3,3},{2,5,11,4,0,3},{2,5,11,4,1,3},{2,5,11,4,2,3},
    {2,5,9,5,3,3},{2,5,8,5,0,3},{2,5,8,5,1,3},{2,5,8,5,2,3},{2,5,6,0,3,3},
    {1,0,10,0,3,4},{1,0,11,9,3,4},{1,0,12,8,3,4},{1,0,16,4,3,4},
}

// BC6H wire-order endpoint spans (Direct3D 11.3, §19.5.13.5).
// Each span gives the channel, endpoint, endpoint bit, wire bit and width.
BC6H_ENDPOINT_SPANS :: [14][][5]u8{
    {
        {1,2,4,2,1},{2,2,4,3,1},{2,3,4,4,1},{0,0,0,5,10},{1,0,0,15,10},
        {2,0,0,25,10},{0,1,0,35,5},{1,3,4,40,1},{1,2,0,41,4},{1,1,0,45,5},
        {2,3,0,50,1},{1,3,0,51,4},{2,1,0,55,5},{2,3,1,60,1},{2,2,0,61,4},
        {0,2,0,65,5},{2,3,2,70,1},{0,3,0,71,5},{2,3,3,76,1},
    },
    {
        {1,2,5,2,1},{1,3,4,3,2},{0,0,0,5,7},{2,3,0,12,2},{2,2,4,14,1},
        {1,0,0,15,7},{2,2,5,22,1},{2,3,2,23,1},{1,2,4,24,1},{2,0,0,25,7},
        {2,3,3,32,1},{2,3,5,33,1},{2,3,4,34,1},{0,1,0,35,6},{1,2,0,41,4},
        {1,1,0,45,6},{1,3,0,51,4},{2,1,0,55,6},{2,2,0,61,4},{0,2,0,65,6},
        {0,3,0,71,6},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,5},{0,0,10,40,1},
        {1,2,0,41,4},{1,1,0,45,4},{1,0,10,49,1},{2,3,0,50,1},{1,3,0,51,4},
        {2,1,0,55,4},{2,0,10,59,1},{2,3,1,60,1},{2,2,0,61,4},{0,2,0,65,5},
        {2,3,2,70,1},{0,3,0,71,5},{2,3,3,76,1},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,4},{0,0,10,39,1},
        {1,3,4,40,1},{1,2,0,41,4},{1,1,0,45,5},{1,0,10,50,1},{1,3,0,51,4},
        {2,1,0,55,4},{2,0,10,59,1},{2,3,1,60,1},{2,2,0,61,4},{0,2,0,65,4},
        {2,3,0,69,1},{2,3,2,70,1},{0,3,0,71,4},{1,2,4,75,1},{2,3,3,76,1},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,4},{0,0,10,39,1},
        {2,2,4,40,1},{1,2,0,41,4},{1,1,0,45,4},{1,0,10,49,1},{2,3,0,50,1},
        {1,3,0,51,4},{2,1,0,55,5},{2,0,10,60,1},{2,2,0,61,4},{0,2,0,65,4},
        {2,3,1,69,2},{0,3,0,71,4},{2,3,4,75,1},{2,3,3,76,1},
    },
    {
        {0,0,0,5,9},{2,2,4,14,1},{1,0,0,15,9},{1,2,4,24,1},{2,0,0,25,9},
        {2,3,4,34,1},{0,1,0,35,5},{1,3,4,40,1},{1,2,0,41,4},{1,1,0,45,5},
        {2,3,0,50,1},{1,3,0,51,4},{2,1,0,55,5},{2,3,1,60,1},{2,2,0,61,4},
        {0,2,0,65,5},{2,3,2,70,1},{0,3,0,71,5},{2,3,3,76,1},
    },
    {
        {0,0,0,5,8},{1,3,4,13,1},{2,2,4,14,1},{1,0,0,15,8},{2,3,2,23,1},
        {1,2,4,24,1},{2,0,0,25,8},{2,3,3,33,2},{0,1,0,35,6},{1,2,0,41,4},
        {1,1,0,45,5},{2,3,0,50,1},{1,3,0,51,4},{2,1,0,55,5},{2,3,1,60,1},
        {2,2,0,61,4},{0,2,0,65,6},{0,3,0,71,6},
    },
    {
        {0,0,0,5,8},{2,3,0,13,1},{2,2,4,14,1},{1,0,0,15,8},{1,2,5,23,1},
        {1,2,4,24,1},{2,0,0,25,8},{1,3,5,33,1},{2,3,4,34,1},{0,1,0,35,5},
        {1,3,4,40,1},{1,2,0,41,4},{1,1,0,45,6},{1,3,0,51,4},{2,1,0,55,5},
        {2,3,1,60,1},{2,2,0,61,4},{0,2,0,65,5},{2,3,2,70,1},{0,3,0,71,5},
        {2,3,3,76,1},
    },
    {
        {0,0,0,5,8},{2,3,1,13,1},{2,2,4,14,1},{1,0,0,15,8},{2,2,5,23,1},
        {1,2,4,24,1},{2,0,0,25,8},{2,3,5,33,1},{2,3,4,34,1},{0,1,0,35,5},
        {1,3,4,40,1},{1,2,0,41,4},{1,1,0,45,5},{2,3,0,50,1},{1,3,0,51,4},
        {2,1,0,55,6},{2,2,0,61,4},{0,2,0,65,5},{2,3,2,70,1},{0,3,0,71,5},
        {2,3,3,76,1},
    },
    {
        {0,0,0,5,6},{1,3,4,11,1},{2,3,0,12,2},{2,2,4,14,1},{1,0,0,15,6},
        {1,2,5,21,1},{2,2,5,22,1},{2,3,2,23,1},{1,2,4,24,1},{2,0,0,25,6},
        {1,3,5,31,1},{2,3,3,32,1},{2,3,5,33,1},{2,3,4,34,1},{0,1,0,35,6},
        {1,2,0,41,4},{1,1,0,45,6},{1,3,0,51,4},{2,1,0,55,6},{2,2,0,61,4},
        {0,2,0,65,6},{0,3,0,71,6},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,10},{1,1,0,45,10},
        {2,1,0,55,10},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,9},{0,0,10,44,1},
        {1,1,0,45,9},{1,0,10,54,1},{2,1,0,55,9},{2,0,10,64,1},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,8},{0,0,11,43,1},
        {0,0,10,44,1},{1,1,0,45,8},{1,0,11,53,1},{1,0,10,54,1},{2,1,0,55,8},
        {2,0,11,63,1},{2,0,10,64,1},
    },
    {
        {0,0,0,5,10},{1,0,0,15,10},{2,0,0,25,10},{0,1,0,35,4},{0,0,15,39,1},
        {0,0,14,40,1},{0,0,13,41,1},{0,0,12,42,1},{0,0,11,43,1},{0,0,10,44,1},
        {1,1,0,45,4},{1,0,15,49,1},{1,0,14,50,1},{1,0,13,51,1},{1,0,12,52,1},
        {1,0,11,53,1},{1,0,10,54,1},{2,1,0,55,4},{2,0,15,59,1},{2,0,14,60,1},
        {2,0,13,61,1},{2,0,12,62,1},{2,0,11,63,1},{2,0,10,64,1},
    },
}

// What a block stores, field by field: what an encoder reads back from a block it changes.
Bc6h_Fields :: struct {
    mode:int,            // in BC6H_MODES
    partition:u32,
    quant:[3][4]i32,     // [channel][endpoint] as stored, the deltas added
    endpoints:[3][4]i32, // in the 16-bit range the indices interpolate in
    indices:[16]u8,
}

@(private)
texture_bc6h_mode :: proc "contextless" (first:u8) -> int {
    low:=int(first&3)
    return low if low<2 else 2+(low-2)*8+int(first>>2&7)
}

@(private)
texture_bc6h_mode_prefix :: proc "contextless" (mode:int) -> u32 {
    return u32(mode) if mode<2 else u32(2+(mode-2)/8+((mode-2)%8)*4)
}

@(private)
bc6h_index_start :: proc "contextless" (mode:Bc6h_Mode) -> int {
    return 128-16*int(mode.ib)+int(mode.ns)
}

// The fields of a block; false for a reserved mode.
texture_bc6h_block_fields :: proc "contextless" (block:[16]u8) -> (f:Bc6h_Fields,ok:bool) {
    bits:=transmute(u128)block
    at:uint
    read :: proc "contextless" (bits:u128,at:^uint,count:uint) -> i32 {
        value:=i32((bits>>at^)&(u128(1)<<count-1))
        at^+=count
        return value
    }
    mode:=texture_bc6h_mode(block[0])
    if mode>=len(BC6H_MODES) {return}
    modes:=BC6H_MODES
    m:=modes[mode]
    e:[3][4]i32
    layouts:=BC6H_ENDPOINT_SPANS
    spans:=layouts[mode]
    for span in spans {
        c,i,bit,wire,width:=span[0],span[1],span[2],span[3],span[4]
        e[c][i]|=i32((bits>>wire)&(u128(1)<<width-1))<<bit
    }
    at=uint(bc6h_index_start(m))-uint(m.pb)
    endpoints:=int(m.ns)*2
    if m.db>0 {
        for c in 0..<3 {
            sign:=i32(1)<<(u32(m.db)-1+u32(c==int(m.bc)))
            for i in 1..<endpoints {e[c][i]=e[c][0]+(e[c][i]&(sign-1))-(e[c][i]&sign)}
        }
    }
    top:=i32(1)<<m.epb-1
    for c in 0..<3 {
        for i in 0..<endpoints {
            v:=e[c][i]&top
            f.quant[c][i]=v
            switch {
            case m.epb>=16:
            case v==0:
            case v==top: v=0xffff
            case: v=((v<<16)+0x8000)>>m.epb
            }
            f.endpoints[c][i]=v
        }
    }
    f.mode=int(mode)
    f.partition=u32(read(bits,&at,uint(m.pb)))
    for &index,i in f.indices {
        anchor:=i==0 || m.ns==2 && i==int(BC7_ANCHORS_2[f.partition])
        index=u8(read(bits,&at,uint(m.ib)-uint(anchor)))
    }
    return f,true
}

// The half floats of a block, in rows from the top.
texture_bc6h_block_decode :: proc "contextless" (block:[16]u8) -> (texels:[16][3]u16) {
    f,ok:=texture_bc6h_block_fields(block)
    if !ok {return}
    modes:=BC6H_MODES
    m:=modes[f.mode]
    for &texel,i in texels {
        weight:=i32(BC7_WEIGHTS[m.ib][f.indices[i]])
        s:=int(BC7_PARTITIONS_2[f.partition][i])*2 if m.ns==2 else 0
        for c in 0..<3 {
            value:=((64-weight)*f.endpoints[c][s]+weight*f.endpoints[c][s+1]+32)>>6
            texel[c]=u16((value*31)>>6)
        }
    }
    return
}
