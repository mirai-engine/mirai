package editor

import "core:strings"
import "mirai:editor/api"
import "mirai:rhi"

Api_Profile_Gpu_Memory_Params :: struct {
    top:int `mirai:"optional,min=1,max=256,clamp,label=Groups in the answer, the largest first; those past it are summed in others"`,
}
Api_Profile_Gpu_Memory_Group :: struct {
    name:string `mirai:"label=The name its resources were made with; those made without one, by their kind"`,
    kind:rhi.Resource_Kind,
    format:rhi.Format `mirai:"label=Of textures that all have it; Undefined otherwise"`,
    count:int,
    bytes:u64 `mirai:"label=Of the memory of the GPU they hold; an acceleration structure, its range of the blocks"`,
    host_bytes:u64 `mirai:"label=Of system memory they hold"`,
}
Api_Profile_Gpu_Memory_Total :: struct {count:int,bytes,host_bytes:u64}
Api_Profile_Gpu_Memory :: struct {
    driver_bytes:u64 `mirai:"label=What the driver says the editor holds of the memory of the GPU; 0 when it does not say"`,
    budget_bytes:u64 `mirai:"label=What the system lets it hold before it pages some out; 0 when the driver does not say"`,
    held_bytes:u64 `mirai:"label=What the device took of that memory: resource_bytes, free_bytes and deleting_bytes"`,
    outside_bytes:u64 `mirai:"label=What the driver holds past held_bytes: its own objects (pipelines, descriptors, the images of the window) and what the device does not ask for; 0 when the driver does not say"`,
    resource_bytes:u64 `mirai:"label=What the buffers, textures and acceleration structures hold: the groups summed"`,
    free_bytes:u64 `mirai:"label=Of the blocks of memory the device took, what no resource holds"`,
    deleting_bytes:u64 `mirai:"label=Of resources destroyed, what waits for the frames the GPU may still run"`,
    unnamed_bytes:u64 `mirai:"label=Of resources made without a name"`,
    buffers,textures,accels:Api_Profile_Gpu_Memory_Total,
    groups:[]Api_Profile_Gpu_Memory_Group `mirai:"label=The resources of each kind and name, the largest first"`,
    other_groups:int `mirai:"label=Groups past top"`,
    others:Api_Profile_Gpu_Memory_Total `mirai:"label=What the groups past top hold"`,
}

@(private)
api_profile_gpu_memory :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Gpu_Memory_Params)
    d:=s.app.device
    if d==nil {api.call_fail(call,api.SERVER_ERROR,"This editor has no GPU device: it runs without a GPU");return}
    groups:=make([]rhi.Memory_Group,p.top,context.temp_allocator)
    report,ok:=rhi.device_memory_report(d,groups)
    if !ok {api.call_fail(call,api.SERVER_ERROR,"Out of memory for the report of the GPU memory");return}
    out:Api_Profile_Gpu_Memory
    out.driver_bytes,out.budget_bytes,out.held_bytes=report.driver_bytes,report.budget_bytes,report.held_bytes
    if report.driver_bytes>report.held_bytes {out.outside_bytes=report.driver_bytes-report.held_bytes}
    out.resource_bytes,out.free_bytes,out.deleting_bytes,out.unnamed_bytes=report.resource_bytes,report.free_bytes,report.deleting_bytes,report.unnamed_bytes
    total::proc(t:rhi.Memory_Kind_Total) -> Api_Profile_Gpu_Memory_Total {return {t.count,t.bytes,t.host_bytes}}
    out.buffers,out.textures,out.accels=total(report.kinds[.Buffer]),total(report.kinds[.Texture]),total(report.kinds[.Accel])
    out.groups=make([]Api_Profile_Gpu_Memory_Group,len(report.groups),call.allocator)
    for g,i in report.groups {
        out.groups[i]={strings.clone(g.name,call.allocator),g.kind,g.format,g.count,g.bytes,g.host_bytes}
    }
    out.other_groups,out.others=report.group_count-len(report.groups),total(report.others)
    api.call_result(call,Api_Profile_Gpu_Memory)^=out
}
