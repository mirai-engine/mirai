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
        for signed in ([]bool{false,true}) {
            r6:BC6H_Block_Raw_Desc
            v6:=bc6h_analyze_block_raw(&r6,signed,&block)
            testing.expect_value(t,r6.mode!=nil,v6)
        }
    }
}

@(test)
partition_tables_match_their_anchors :: proc(t:^testing.T) {
    // Every subset of every partition is non-empty and its anchor texel belongs to it.
    for p in 0..<64 {
        part2:=BC67_PARTITIONS[1+p]
        testing.expect_value(t,(part2.subset_mask>>(2*u32(part2.anchor0)))&3,u32(1))
        part3:=BC67_PARTITIONS[65+p]
        s:=[2]u32{(part3.subset_mask>>(2*u32(part3.anchor0)))&3,
            (part3.subset_mask>>(2*u32(part3.anchor1)))&3}
        testing.expect(t,s[0]!=0 && s[1]!=0 && s[0]!=s[1])
        counts:[3]int
        for i in 0..<16 {counts[(part3.subset_mask>>(2*u32(i)))&3]+=1}
        for k in 0..<3 {testing.expect_value(t,u8(counts[k]),NUM_PIXELS_PER_SUBSET[3][p][k])}
    }
}
