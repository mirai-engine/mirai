package mirai_render

import "mirai:asset"
import "mirai:rhi"

// Layers are camera effects on the opaque/masked base, before transparency
// and TAA. Each one draws the clusters of its instance the cut of the view
// takes, as the G-buffer did, without a second geometry or acceleration instance.
@(private)
overlay_pipelines_list :: proc(r:^Renderer,list:^Pipeline_List) {
    for mode in asset.Overlay_Blend {
        blend:rhi.Blend_Mode
        switch mode {case .Alpha:blend=.Alpha;case .Additive:blend=.Additive;case .Multiply:blend=.Multiply}
        descriptor:=rhi.Graphics_Pipeline_Desc{
            vertex=&r.shader_codes[.Gbuffer_Vert],fragment=&r.shader_codes[.Overlay_Frag],
            color_formats={0=.RGBA16_Float},color_count=1,blend={0=blend},
            depth_format=.D32_Float,depth_test=true,depth_write=false,depth_compare=.Equal,cull=.None,
            name="surface overlay",
        }
        pipeline_listed(list,{target=&r.overlay_pipelines[mode],shaders={.Gbuffer_Vert,.Overlay_Frag},rays=.Software,required=true,graphics=true,desc=descriptor})
        descriptor.fragment=&r.shader_codes[.Overlay_Hw_Frag]
        descriptor.name="surface overlay hardware"
        pipeline_listed(list,{target=&r.overlay_hw_pipelines[mode],shaders={.Gbuffer_Vert,.Overlay_Hw_Frag},rays=.Hardware,required=true,graphics=true,desc=descriptor})
    }
}
overlay_pass :: proc(p:^Pass) {
    r,cmd,instance_count:=p.r,p.cmd,p.instance_count
    s,t:=&r.scene,p.t
    if s.overlay_count==0 {return}
    rhi.cmd_timestamp(cmd,"overlays")
    pass:=rhi.Render_Pass_Desc{color_count=1,name="surface overlays"}
    pass.colors[0]={texture=t.display,load=.Load,store=.Store}
    pass.depth={texture=t.depth,load=.Load,store=.Store}
    rhi.cmd_begin_render_pass(cmd,&pass)
    Params :: struct {material,blend,light_budget,pad:u32}
    for layers,index in s.overlays {
        if index>=int(instance_count) {break}
        inst:=&s.instances[index]
        // Mixed transparent meshes are currently excluded too: they require
        // interleaving overlays with the glass layer resolve rather than Equal.
        if inst.meta.w & (INSTANCE_FLAG_HIDDEN|INSTANCE_FLAG_TRANSLUCENT)!=0 {continue}
        for layer_index in 0..<int(layers.count) {layer:=layers.entries[layer_index]
            if !layer.enabled || int(layer.blend)>int(max(asset.Overlay_Blend)) {continue}
            params:=Params{material=u32(layer.material),blend=u32(layer.blend),light_budget=r.settings.light_budget}
            // The stage of the program of the material of the overlay, over every cluster.
            target:=&r.overlay_hw_pipelines[layer.blend] if r.hardware_rt else &r.overlay_pipelines[layer.blend]
            program:=s.materials[layer.material].program_id if int(layer.material)<len(s.materials) else 0
            rhi.cmd_bind_pipeline(cmd,program_graphics(r,target,program));set_params(cmd,&params)
            // The clusters of the cut the G-buffer drew: the vertex shader takes the same as the cull.
            instance_clusters_draw(r,cmd,u32(index),false,GPU_NONE)
        }
    }
    rhi.cmd_end_render_pass(cmd)
}

// Material edits can move the base between opaque and transparent without
// replacing instances; the eligible camera-layer count follows those flags.
overlay_count_update :: proc(s:^Scene_State) {
    s.overlay_count=0
    for layers,index in s.overlays {
        if index>=len(s.instances) {break}
        if s.instances[index].meta.w&(INSTANCE_FLAG_HIDDEN|INSTANCE_FLAG_TRANSLUCENT)!=0 {continue}
        for layer_index in 0..<int(layers.count) {layer:=layers.entries[layer_index];if layer.enabled {s.overlay_count+=1}}
    }
}
