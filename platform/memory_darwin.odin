#+build darwin
package platform

import "core:sys/darwin"

// TASK_VM_INFO up to phys_footprint, its first revision, as mach/task_info.h lays it out.
@(private="file")
Task_Vm_Info :: struct {
    virtual_size:u64,
    region_count,page_size:i32,
    resident_size,resident_size_peak:u64,
    device,device_peak,internal,internal_peak,external,external_peak:u64,
    reusable,reusable_peak:u64,
    purgeable_volatile_pmap,purgeable_volatile_resident,purgeable_volatile_virtual:u64,
    compressed,compressed_peak,compressed_lifetime:u64,
    phys_footprint:u64,
}
@(private="file") TASK_VM_INFO :: 22

process_memory :: proc() -> (m:Process_Memory) {
    info:Task_Vm_Info
    count:=u32(size_of(info)/size_of(i32))
    if darwin.task_info(darwin.mach_task_self(),TASK_VM_INFO,darwin.task_info_t(&info),&count)!=.Success {return}
    return {info.resident_size,info.phys_footprint}
}
