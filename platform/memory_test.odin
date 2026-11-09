package platform

import "core:testing"

// What the system says this process holds grows with memory it writes to.
@(test)
process_memory_counts_what_the_process_touches :: proc(t:^testing.T) {
    before:=process_memory()
    testing.expect(t,before.resident>0,"the system says how much of the process is resident")
    testing.expect(t,before.private>0,"and how much is its own")
    block:=make([]u8,64<<20)
    defer delete(block)
    for i:=0;i<len(block);i+=4096 {block[i]=1}
    after:=process_memory()
    testing.expectf(t,after.private>=before.private+32<<20,"64 MB written raise the private memory: %d -> %d",before.private,after.private)
}
