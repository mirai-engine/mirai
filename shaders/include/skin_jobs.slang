// The batched passes of the skinned poses: jobs[first..first+count) cover the
// threads [0, total), each from its start on (render.Skin_Job).
struct Skin_Job { uint x; uint y; uint z; uint start; };
struct Params_Block { uint first; uint count; uint total; uint pad; };
[[vk::binding(SLOT_PARAMS,0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b,SLOT_PARAMS),space0);
[[vk::binding(SLOT_PASS0,0)]] StructuredBuffer<Skin_Job> jobs : register(MIRAI_REGISTER(t,SLOT_PASS0),space0);

// The job of a thread: the last one that starts at it or before.
Skin_Job skin_job(uint thread) {
    uint low=params.first;
    uint high=params.first+params.count-1u;
    while (low<high) {
        uint middle=(low+high+1u)>>1u;
        if (jobs[middle].start<=thread) low=middle; else high=middle-1u;
    }
    return jobs[low];
}
