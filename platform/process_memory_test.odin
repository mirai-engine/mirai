package platform

import "core:testing"

// What the system says this process holds includes memory it writes to and
// keeps, whatever other threads allocate or free meanwhile.
@(test)
process_memory_counts_what_the_process_touches :: proc(t:^testing.T) {
    block:=make([]u8,64<<20)
    defer delete(block)
    for i:=0;i<len(block);i+=4096 {block[i]=1}
    held:=process_memory()
    testing.expect(t,held.resident>0,"the system says how much of the process is resident")
    testing.expectf(t,held.private>=u64(len(block)),"the private memory holds the %d bytes written: %d",len(block),held.private)
}
