package bc67

import "core:testing"

@(test)
analyzers_take_any_bits :: proc(t:^testing.T) {
    seed:=u32(7)
    for n in 0..<4096 {
        block:[16]u8
        for i in 0..<16 {
            seed=seed*1664525+1013904223
            block[i]=u8(seed>>24)
        }
        if n<256 {block[0]=u8(n)}
        raw:Block_Raw_Desc
        valid:=bc7_analyze_block_raw(&raw,&block)
        testing.expect_value(t,valid,block[0]!=0)
    }
}

// The tables the encoders index by partition are those of the format in another shape: the
// subset of each texel, the texels of each subset, and anchors that belong to their subsets.
@(test)
the_tables_of_the_encoders_follow_the_partitions_of_the_format :: proc(t:^testing.T) {
    for ns in u8(2)..=3 {
        for p in 0..<64 {
            part:=partition_of(ns,u32(p))
            testing.expect_value(t,SECTION_TBL[ns][p],part.subset_mask)
            anchors:=[2]u32{(part.subset_mask>>(2*u32(part.anchor0)))&3,(part.subset_mask>>(2*u32(part.anchor1)))&3}
            if ns==2 {
                testing.expect(t,anchors[0]==1 && part.anchor1==0)
            } else {
                testing.expect(t,anchors[0]!=0 && anchors[1]!=0 && anchors[0]!=anchors[1] && part.anchor0<part.anchor1)
            }
            counts:[3]int
            for i in 0..<16 {counts[(part.subset_mask>>(2*u32(i)))&3]+=1}
            for k in 0..<int(ns) {
                testing.expect(t,counts[k]>0)
                testing.expect_value(t,NUM_PIXELS_PER_SUBSET[ns][p][k],u8(counts[k]))
            }
        }
    }
}
