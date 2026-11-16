#+build darwin
package base

import "core:c"

foreign import system "system:System.framework"

@(private="file")
Vm_Statistics64 :: struct {
    free_count,active_count,inactive_count,wire_count:u32,
    zero_fill_count,reactivations,pageins,pageouts,faults,cow_faults,lookups,hits,purges:u64,
    purgeable_count,speculative_count:u32,
    decompressions,compressions,swapins,swapouts:u64,
    compressor_page_count,throttled_count,external_page_count,internal_page_count:u32,
    total_uncompressed_pages_in_compressor:u64,
}

@(private="file")
HOST_VM_INFO64 :: 4

@(default_calling_convention="c",private="file")
foreign system {
    mach_host_self :: proc() -> u32 ---
    host_statistics64 :: proc(host:u32,flavor:c.int,info:rawptr,count:^u32) -> c.int ---
    sysctlbyname :: proc(name:cstring,oldp:rawptr,oldlenp:^c.size_t,newp:rawptr,newlen:c.size_t) -> c.int ---
}

// hw.memsize, and the pages that are free, inactive, purgeable or
// speculative: what Activity Monitor counts as available.
@(private)
_memory_stats :: proc "contextless" () -> (total,available:i64,ok:bool) {
    memsize:u64
    size:=c.size_t(size_of(memsize))
    if sysctlbyname("hw.memsize",&memsize,&size,nil,0)!=0 {return}
    page:u64
    size=c.size_t(size_of(page))
    if sysctlbyname("hw.pagesize",&page,&size,nil,0)!=0 {return}
    stats:Vm_Statistics64
    count:=u32(size_of(stats)/size_of(i32))
    if host_statistics64(mach_host_self(),HOST_VM_INFO64,&stats,&count)!=0 {return}
    pages:=u64(stats.free_count)+u64(stats.inactive_count)+u64(stats.purgeable_count)+u64(stats.speculative_count)
    return i64(memsize),i64(pages*page),true
}
